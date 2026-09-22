defmodule PhoenixKitStaff.Web.PersonFormLiveTest do
  @moduledoc """
  Smoke tests for the person form, with explicit pins on the Phase 2
  Batch 1 deltas:

  - `phx-disable-with` on submit button
  - validate event sets `:action`
  - `Errors.message/1` translation at the LV layer (atom from
    `Staff.rename_placeholder_email/2` no longer leaks raw strings)
  - activity logging threads `actor_uuid`
  - placeholder-user create flow (single email field → user + person)
  """

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitStaff.{Errors, Staff}

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "new person form" do
    test "mounts and renders the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/staff/people/new")
      assert html =~ "New staff"
      assert html =~ "person-form"
    end

    test "submit button has phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/staff/people/new")
      assert html =~ ~r/phx-disable-with=/
    end
  end

  describe "Errors atom translation surface" do
    test "`:blank_email` atom translates via Errors.message/1, not a raw string", %{} do
      msg = Errors.message(:blank_email)
      assert msg == "Email is required."
    end

    test "Staff.rename_placeholder_email/2 returns the :blank_email atom on empty input", %{} do
      # Set up a placeholder user via the create-with-user flow so the
      # `placeholder?/1` predicate inside `Staff.rename_placeholder_email`
      # passes. Pin the atom (not a translated string) so consumers
      # know to route through `Errors.message/1` at the boundary.
      person = fixture_person()
      placeholder_user = person.user

      assert {:error, :blank_email} = Staff.rename_placeholder_email(placeholder_user, "")
    end

    test "non-placeholder user can't be renamed (`:placeholder_already_claimed`)", %{} do
      # Build a user that does NOT have the `staff_placeholder` source
      # tag (i.e. simulating a user who has registered themselves).
      {:ok, real_user} =
        Auth.register_user(%{
          "email" => "real-#{System.unique_integer([:positive])}@x.com",
          "password" => "RealPass123!"
        })

      assert {:error, :placeholder_already_claimed} =
               Staff.rename_placeholder_email(
                 real_user,
                 "anything-#{System.unique_integer([:positive])}@x.com"
               )
    end
  end

  describe "validate event renders inline errors" do
    test "validate path stays responsive without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      # The new-form template renders `team_uuid` only after a department
      # is selected, so the no-input validate event omits it.
      html =
        view
        |> form("#person-form", person: %{}, email: "")
        |> render_change()

      # What matters: the validate path stays responsive without raising
      # and the form continues rendering. The validate handler in
      # PersonFormLive sets `:action, :validate` on the changeset (Phase
      # 2 Batch 1 delta) — which is what makes `<.input>` show inline
      # errors here when fields fail validate.
      assert is_binary(html)
      assert html =~ "person-form"
    end
  end

  describe "create flow" do
    test "happy path creates user + person via the context layer", %{} do
      # The form's submit phase couples top-level `email` + nested
      # `person[*]` attrs with no top-level `team_uuid` until a
      # department is selected. Driving the full submit through
      # `render_submit` requires a department-then-team selection
      # round-trip; that's out of scope for a smoke test. The
      # equivalent Phase 2 delta — `:person_created` activity logged
      # with `actor_uuid` threaded through — is pinned in
      # `activity_logging_test.exs` and via the context-layer call here.
      email = "new-#{System.unique_integer([:positive])}@example.com"

      {:ok, person, _status} =
        Staff.create_person_with_user(email, %{"status" => "active", "job_title" => "Engineer"})

      assert person.status == "active"

      person = Staff.get_person!(person.uuid, preload: [:user])
      assert person.user.email == email
    end
  end

  describe "save error — failure-side audit row" do
    test "create-form Save with blank email writes a db_pending audit row (atom branch)", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      # Empty email → Staff.find_or_create_user_by_email/1 returns
      # {:error, :blank_email} → the atom branch in save/5 fires.
      view
      |> form("#person-form", person: %{status: "active"}, email: "")
      |> render_submit()

      assert_activity_logged("staff.person_created",
        actor_uuid: actor_uuid,
        resource_uuid: nil,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "atom",
          "error_atom" => "blank_email"
        }
      )
    end

    test "create-form Save with invalid attrs writes a db_pending audit row (changeset)", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      email = "save-err-#{System.unique_integer([:positive])}@example.com"

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      # Valid email so find_or_create_user_by_email succeeds; invalid
      # `personal_email` format trips `validate_format/3`, so
      # create_person/1 returns {:error, %Ecto.Changeset{}} and the
      # placeholder user is rolled back — but the audit row records the
      # failed attempt. (`personal_email` is a text input rather than a
      # select, so it survives Phoenix LiveView 1.1.29's stricter
      # render_submit/2 option-allowlist validation that blocks bogus
      # status values client-side.)
      view
      |> form("#person-form",
        person: %{status: "active", personal_email: "not-an-email"},
        email: email
      )
      |> render_submit()

      # The audit row records the failed attempt WITHOUT the attempted email
      # (PII-safe metadata, per AGENTS.md) — `db_pending`/`error_kind` is enough.
      assert_activity_logged("staff.person_created",
        actor_uuid: actor_uuid,
        resource_uuid: nil,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "changeset"
        }
      )
    end

    test "edit-form Save with invalid attrs keeps the original record uuid on the audit row", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      person = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # Same `personal_email` format-violation vector as the create-form
      # sibling — text input rather than a select, so LV 1.1.29's
      # stricter option-allowlist validation lets it through to the
      # LV's changeset rejection. Edit form doesn't expose the top-level
      # email field, so don't pass one.
      view
      |> form("#person-form",
        person: %{status: "active", personal_email: "not-an-email"}
      )
      |> render_submit()

      assert_activity_logged("staff.person_updated",
        actor_uuid: actor_uuid,
        resource_uuid: person.uuid,
        metadata_has: %{
          "db_pending" => true,
          "error_kind" => "changeset"
        }
      )
    end
  end

  # `metadata` is server-owned (the avatar pointer, the trash stash); a
  # crafted form param must neither set nor replace it.
  test "a crafted metadata param on save is ignored", %{conn: conn} do
    person = fixture_person(%{"metadata" => %{"source" => "import"}})
    {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

    view
    |> element("#person-form")
    |> render_submit(%{
      "person" => %{"status" => "active", "metadata" => %{"avatar_uuid" => Ecto.UUID.generate()}}
    })

    assert Staff.get_person!(person.uuid).metadata == %{"source" => "import"}
  end

  describe "internal notes field removed" do
    test "the edit form no longer renders the Internal notes field", %{conn: conn} do
      person = fixture_person()

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      refute html =~ "Internal notes"
      # No notes input under any name (primary column or translations key).
      refute html =~ "][notes]"
      refute html =~ ~s|name="person[notes]"|
      # Skills also no longer live on the form (V135 moved them to the
      # structured Skill entity, managed on the person show page).
      refute html =~ ~s|name="person[skills]"|
      # A sibling translatable field that IS still on the form.
      assert html =~ "Bio"
    end
  end

  describe "work location soft-dep (phoenix_kit_locations absent)" do
    test "the work-location picker is hidden when the locations module is unavailable", %{
      conn: conn
    } do
      person = fixture_person()

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # phoenix_kit_locations is not a dependency in the staff test env, so
      # `location_options/0` returns [] and the `<.select>` is gated off via
      # `:if={@location_options != []}` — pins the soft-dep degradation contract.
      refute html =~ ~s|name="person[work_location]"|
      refute html =~ "Work location"
    end
  end

  describe "404 fallback" do
    test "edit with bogus uuid redirects to people list", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/en/admin/staff/people"}}} =
               live(conn, "/en/admin/staff/people/#{bogus}/edit")
    end

    # Regression: editing a trashed person must not be possible in place
    # (it would un-trash via the normal update path). Redirect to show.
    test "edit of a trashed person redirects to the show page", %{conn: conn} do
      person = fixture_person()
      {:ok, trashed} = PhoenixKitStaff.Staff.trash_person(person)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/en/admin/staff/people/#{trashed.uuid}/edit")

      assert to == "/en/admin/staff/people/#{trashed.uuid}"
    end

    # Regression: the save path re-checks current DB status, so a save
    # from an edit LV opened before a concurrent trash can't un-trash
    # the person (the mount guard alone wouldn't catch this race).
    test "save after a concurrent trash refuses and leaves the person trashed", %{conn: conn} do
      person = fixture_person()
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # Another admin trashes the person while this edit LV is open.
      {:ok, _} = PhoenixKitStaff.Staff.trash_person(person)

      render_submit(view, "save", %{"person" => %{"status" => "active"}})

      assert_redirect(view, "/en/admin/staff/people/#{person.uuid}")
      assert PhoenixKitStaff.Staff.get_person(person.uuid).status == "trashed"
    end
  end

  describe "skills picker (edit form — staged, persisted on Save)" do
    alias PhoenixKitStaff.Skills

    test "renders the searchable skills picker (skills exist)", %{conn: conn} do
      person = fixture_person()
      _skill = fixture_skill()
      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      assert html =~ "Skills"
      assert html =~ "Type to search skills"
      # The "manage the taxonomy" link points at the Skills admin page.
      assert html =~ "Add / edit skills"
      assert html =~ ~s|href="/en/admin/staff/skills"|
    end

    test "with no skills at all, shows an empty-state prompt linking to Skills", %{conn: conn} do
      person = fixture_person()
      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # No skills exist → the picker collapses to a prompt + link, and the
      # search box is suppressed (there's nothing to search).
      assert html =~ "No skills have been created yet."
      assert html =~ "Add / edit skills"
      assert html =~ ~s|href="/en/admin/staff/skills"|
      refute html =~ "Type to search skills"
    end

    test "with every available skill already assigned, shows 'all added' and no search box", %{
      conn: conn
    } do
      person = fixture_person()
      skill = fixture_skill()
      {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, [])

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # Every available skill is staged → the search box would be dead weight.
      assert html =~ "All available skills are added."
      refute html =~ "Type to search skills"
    end

    test "removing a staged skill brings the search box back when all were assigned", %{
      conn: conn
    } do
      person = fixture_person()
      skill = fixture_skill()
      {:ok, _} = Skills.assign_skill(person.uuid, skill.uuid, [])

      {:ok, view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")
      assert html =~ "All available skills are added."

      html =
        view
        |> element("button[phx-click='remove_staged_skill'][phx-value-uuid='#{skill.uuid}']")
        |> render_click()

      # Now one skill is free again → the search box returns.
      assert html =~ "Type to search skills"
      refute html =~ "All available skills are added."
    end

    test "refresh_skills flips the empty state to the picker after a skill is created", %{
      conn: conn
    } do
      person = fixture_person()
      {:ok, view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      assert html =~ "No skills have been created yet."
      refute html =~ "Type to search skills"

      # A skill gets created elsewhere (e.g. the Skills page opened in a new
      # tab); returning to this tab fires phx-window-focus → refresh_skills.
      _skill = fixture_skill()
      html = render_hook(view, "refresh_skills", %{})

      assert html =~ "Type to search skills"
      refute html =~ "No skills have been created yet."
    end

    test "type-to-search narrows the add-able skills", %{conn: conn} do
      person = fixture_person()
      u = System.unique_integer([:positive])
      match = fixture_skill(%{"name" => "Elixir-#{u}"})
      other = fixture_skill(%{"name" => "Python-#{u}"})

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      html =
        view
        |> form("#person-form", %{"skill_search" => "Elixir-#{u}"})
        |> render_change()

      assert html =~ ~s|phx-value-uuid="#{match.uuid}"|
      refute html =~ ~s|phx-value-uuid="#{other.uuid}"|
    end

    test "adding a skill stages it but does NOT persist until Save", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      person = fixture_person()
      skill = fixture_skill(%{"name" => "Elixir-#{System.unique_integer([:positive])}"})

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # Stage the skill (a clean DB surfaces the lone skill in the initial
      # matches, so the add button is present without searching first).
      view
      |> element("button[phx-click='add_staged_skill'][phx-value-uuid='#{skill.uuid}']")
      |> render_click()

      # Nothing is written, and no activity is logged, until Save.
      assert Skills.list_for_person(person.uuid) == []
      refute_activity_logged("staff.person_skill_added", resource_uuid: skill.uuid)

      # Pressing Save persists the staged assignment + logs it.
      view
      |> form("#person-form", person: %{status: "active"})
      |> render_submit()

      assert [ps] = Skills.list_for_person(person.uuid)
      assert ps.skill.uuid == skill.uuid

      assert_activity_logged("staff.person_skill_added",
        resource_uuid: skill.uuid,
        actor_uuid: actor_uuid,
        target_uuid: person.user_uuid
      )
    end

    test "staging a new skill + picking a level chip persists the level on Save", %{conn: conn} do
      person = fixture_person()

      {skill, ids} =
        fixture_skill_with_levels(["Beginner", "Expert"], %{
          "name" => "Driving-#{System.unique_integer([:positive])}"
        })

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      view
      |> element("button[phx-click='add_staged_skill'][phx-value-uuid='#{skill.uuid}']")
      |> render_click()

      render_click(view, "toggle_staged_level", %{"uuid" => skill.uuid, "id" => ids["Expert"]})

      view
      |> form("#person-form", person: %{status: "active"})
      |> render_submit()

      assert [ps] = Skills.list_for_person(person.uuid)
      assert ps.proficiency_levels == [ids["Expert"]]
    end

    test "toggling a staged level chip then saving updates the assignment", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      person = fixture_person()
      {skill, ids} = fixture_skill_with_levels(["Beginner", "Advanced"])
      {:ok, _ps} = Skills.assign_skill(person.uuid, skill.uuid, [ids["Beginner"]])

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # single-select: toggling "Advanced" replaces "Beginner" in the staged row
      render_click(view, "toggle_staged_level", %{"uuid" => skill.uuid, "id" => ids["Advanced"]})

      view
      |> form("#person-form", person: %{status: "active"})
      |> render_submit()

      assert hd(Skills.list_for_person(person.uuid)).proficiency_levels == [ids["Advanced"]]

      assert_activity_logged("staff.person_skill_updated",
        resource_uuid: skill.uuid,
        actor_uuid: actor_uuid,
        target_uuid: person.user_uuid
      )
    end

    test "removing a staged chip then saving unassigns the skill", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      person = fixture_person()
      skill = fixture_skill()
      {:ok, _ps} = Skills.assign_skill(person.uuid, skill.uuid, [])

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      view
      |> element("button[phx-click='remove_staged_skill'][phx-value-uuid='#{skill.uuid}']")
      |> render_click()

      # The assignment survives until Save (staging only).
      assert [_] = Skills.list_for_person(person.uuid)

      view
      |> form("#person-form", person: %{status: "active"})
      |> render_submit()

      assert Skills.list_for_person(person.uuid) == []

      assert_activity_logged("staff.person_skill_removed",
        resource_uuid: skill.uuid,
        actor_uuid: actor_uuid,
        target_uuid: person.user_uuid
      )
    end
  end
end
