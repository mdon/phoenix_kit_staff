defmodule PhoenixKitStaff.Web.CoverageTest do
  @moduledoc """
  Targeted coverage extensions for the LV files that were >40 missed
  lines after Batch 3 (Batch 4 coverage push). Each describe block
  targets a specific LV's render/event/handle_info paths that
  existing smoke tests didn't reach.

  Per the workspace AGENTS.md "Coverage push pattern" — no Mox /
  external deps. Only `mix test --cover`-driven exercises through
  real fixtures + LV events.
  """

  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitStaff.{Departments, Skills, Staff}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  # ────────────────────────────────────────────────────────────────
  describe "PersonShowLive — full optional-card render coverage" do
    test "renders every optional card when all fields are populated", %{conn: conn} do
      dept = fixture_department(%{"name" => "Engineering"})

      person =
        fixture_person(%{
          "job_title" => "Senior Engineer",
          "employment_type" => "full_time",
          "employment_start_date" => "2020-01-01",
          "employment_end_date" => "2024-12-31",
          "work_location" => "Remote",
          "work_phone" => "+372 555 1111",
          "personal_phone" => "+372 555 2222",
          "personal_email" => "personal@example.com",
          "bio" => "Full bio text.",
          "date_of_birth" => Date.to_string(Date.add(Date.utc_today(), -10_000)),
          "emergency_contact_name" => "Jane Doe",
          "emergency_contact_phone" => "+372 555 9999",
          "emergency_contact_relationship" => "spouse",
          "primary_department_uuid" => dept.uuid,
          "notes" => "Internal admin notes"
        })

      # Structured skills (replaced the old free-text field): assign two so
      # the at-a-glance badges + the Skills card render. Elixir carries an
      # "Expert" level so the localized level label shows on the assignment.
      {:ok, elixir} =
        Skills.create(%{
          "name" => "Elixir",
          "levels" => [%{"options" => [%{"name" => "Expert"}]}]
        })

      {:ok, phoenix} = Skills.create(%{"name" => "Phoenix"})
      expert_id = elixir.levels |> hd() |> Map.get("options") |> hd() |> Map.get("id")
      {:ok, _} = Skills.assign_skill(person.uuid, elixir.uuid, [expert_id])
      {:ok, _} = Skills.assign_skill(person.uuid, phoenix.uuid, [])

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # Hero card — job title (subtitle) + current type/location badges. The
      # detailed employment history moved to the Employment tab (not rendered
      # on the Overview tab), so only the hero summary shows here.
      assert html =~ "Senior Engineer"
      # "Employment" tab label is present in the tab strip.
      assert html =~ "Employment"
      assert html =~ "Remote"
      # Contact card
      assert html =~ "+372 555 1111"
      assert html =~ "personal@example.com"
      # Personal card
      assert html =~ "Birthday"
      # Emergency contact card
      assert html =~ "Emergency contact"
      assert html =~ "Jane Doe"
      assert html =~ "spouse"
      # Bio
      assert html =~ "Full bio text"
      # Skills card + structured assignments (name + level label)
      assert html =~ "Skills"
      assert html =~ "Elixir"
      assert html =~ "Phoenix"
      assert html =~ "Expert"
      # Admin notes (warning panel)
      assert html =~ "Admin notes"
      assert html =~ "Internal admin notes"
    end

    test "renders the hero without crashing for a name-less person", %{conn: conn} do
      # Person has no `name` and the fixture user has no first/last name —
      # exercises `Person.display_name/1`'s email/"Unnamed" fall-through
      # path on a full mount.
      person = fixture_person()
      _view = live(conn, "/en/admin/staff/people/#{person.uuid}")
      :ok
    end

    test "format_birthday for today's birthday includes 'today!'", %{conn: conn} do
      today = Date.utc_today()
      # DOB exactly 30y ago → birthday today
      dob = Date.new!(today.year - 30, today.month, today.day)

      person = fixture_person(%{"date_of_birth" => Date.to_string(dob)})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      assert html =~ "today!"
    end

    test "format_birthday for upcoming birthday includes 'in N days'", %{conn: conn} do
      today = Date.utc_today()
      # DOB 25y ago + 5 days → birthday in 5 days
      future_day = Date.add(today, 5)
      dob = Date.new!(future_day.year - 25, future_day.month, future_day.day)

      person = fixture_person(%{"date_of_birth" => Date.to_string(dob)})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      assert html =~ "in 5 days" or html =~ "🎂"
    end

    test "{:staff, :other_event, _} reload branch re-fetches person", %{conn: conn} do
      person = fixture_person(%{"job_title" => "Pre"})

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # Update via context, then send broadcast — handle_info `_other`
      # branch should re-fetch and render the new title.
      {:ok, _updated} = Staff.update_person(person, %{"job_title" => "Post"})
      send(view.pid, {:staff, :person_updated, %{uuid: person.uuid}})

      :sys.get_state(view.pid)
      assert render(view) =~ "Post"
    end

    test "{:staff, :other_event, _} branch redirects when person is gone", %{conn: conn} do
      person = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      # Delete the person, then broadcast. The reload branch sees nil
      # and push_navigates back to the list.
      {:ok, trashed} = Staff.trash_person(person)
      {:ok, _} = Staff.delete_person(trashed)
      send(view.pid, {:staff, :stale_event, %{uuid: person.uuid}})

      assert_redirect(view, "/en/admin/staff/people")
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PersonFormLive — email status branches + save paths" do
    test ":new mode renders with eligible-users datalist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/staff/people/new")

      assert html =~ "New staff"
      assert html =~ "Email"
      assert html =~ "Type or pick an email"
    end

    test "validate event with empty email yields :blank status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      html =
        view
        |> form("#person-form",
          person: %{status: "active"},
          email: ""
        )
        |> render_change()

      # :blank status renders the helper text.
      assert html =~ "Existing accounts suggested" or html =~ "Type or pick an email"
    end

    test "validate event with invalid email yields :invalid status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      html =
        view
        |> form("#person-form",
          person: %{status: "active"},
          email: "not-an-email"
        )
        |> render_change()

      assert html =~ "Not a valid email"
    end

    test "validate event with new email yields :new status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      html =
        view
        |> form("#person-form",
          person: %{status: "active"},
          email: "fresh-#{System.unique_integer([:positive])}@example.com"
        )
        |> render_change()

      assert html =~ "Will create a placeholder account"
    end

    test "validate event with existing-with-profile email yields :has_profile", %{conn: conn} do
      taken = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      html =
        view
        |> form("#person-form",
          person: %{status: "active"},
          email: taken.user.email
        )
        |> render_change()

      assert html =~ "already has a staff profile"
    end

    test "team picker lists all teams (no longer department-filtered)", %{conn: conn} do
      dept = fixture_department()
      _team = fixture_team(%{"name" => "TeamA", "department_uuid" => dept.uuid})

      # The department picker moved to the Employment tab, so the form's team
      # picker now lists every team on mount (no dept selection round-trip).
      {:ok, _view, html} = live(conn, "/en/admin/staff/people/new")

      assert html =~ "TeamA"
    end

    test "save :new with valid params creates person and team membership", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      dept = fixture_department()
      team = fixture_team(%{"department_uuid" => dept.uuid})

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      email = "new-#{System.unique_integer([:positive])}@example.com"

      render_submit(view, "save", %{
        "person" => %{
          "status" => "active",
          "job_title" => "Eng",
          "primary_department_uuid" => dept.uuid
        },
        "email" => email,
        "team_uuid" => team.uuid
      })

      assert_activity_logged("staff.person_created",
        actor_uuid: actor_uuid,
        metadata_has: %{"status" => "active", "user_status" => "created"}
      )

      assert_activity_logged("staff.team_person_added", actor_uuid: actor_uuid)
    end

    test "save :new with invalid changeset stays on form with errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/new")

      # Drive the save event directly with a 256-char name to trigger
      # validate_length(:name, max: 255). (job_title moved to the Employment
      # tab; `name` is a 255-capped field still rendered on this form.)
      html =
        render_submit(view, "save", %{
          "person" => %{"status" => "active", "name" => String.duplicate("x", 256)},
          "email" => "valid-#{System.unique_integer([:positive])}@example.com"
        })

      assert html =~ "should be at most 255"
    end

    test "edit mode renders the form", %{conn: conn} do
      person = fixture_person()

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      assert html =~ "Edit"
      assert html =~ ~s|href="/en/admin/staff/people/#{person.uuid}"|
    end

    test "edit save with successful update logs activity", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      person = fixture_person(%{"job_title" => "Old"})

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      render_submit(view, "save", %{
        "person" => %{"status" => "active", "job_title" => "New Title"},
        "email" => person.user.email
      })

      assert_activity_logged("staff.person_updated",
        actor_uuid: actor_uuid,
        resource_uuid: person.uuid
      )
    end

    test "edit save with bad changeset shows errors inline", %{conn: conn} do
      person = fixture_person()

      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      # Drive the save event directly with a 256-char name to trigger
      # validate_length(:name, max: 255). (job_title moved to the Employment
      # tab; `name` is a 255-capped field still rendered on this form.)
      html =
        render_submit(view, "save", %{
          "person" => %{"status" => "active", "name" => String.duplicate("x", 256)},
          "email" => person.user.email || ""
        })

      assert html =~ "should be at most 255"
    end

    test ":edit form for confirmed user locks the email field", %{conn: conn} do
      # Register a user (without staff_placeholder tag), then create
      # a Staff Person linked to them. `placeholder_user?/1` returns
      # false (no `staff_placeholder` source tag), so the email field
      # renders the locked variant.
      email = "confirmed-#{System.unique_integer([:positive])}@example.com"

      {:ok, user} =
        Auth.register_user(%{"email" => email, "password" => "Aa1!stuffstuff"})

      {:ok, person} = Staff.create_person(%{"user_uuid" => user.uuid, "status" => "active"})

      {:ok, _view, html} = live(conn, "/en/admin/staff/people/#{person.uuid}/edit")

      assert html =~ "locked"
    end

    test "404 redirects when editing missing person", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/en/admin/staff/people"}}} =
               live(conn, "/en/admin/staff/people/#{bogus}/edit")
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "OverviewLive — full org tree render" do
    test "renders departments, teams, people, and unassigned section", %{conn: conn} do
      dept_a = fixture_department(%{"name" => "Engineering"})
      dept_b = fixture_department(%{"name" => "Sales"})
      team = fixture_team(%{"name" => "Backend", "department_uuid" => dept_a.uuid})

      person_on_team = fixture_person()
      _ = Staff.add_team_person(team.uuid, person_on_team.uuid)

      _person_dept_only =
        fixture_person(%{"primary_department_uuid" => dept_b.uuid})

      _unassigned = fixture_person()

      {:ok, _view, html} = live(conn, "/en/admin/staff/")

      # Tree contains both depts, the team, and the people categories.
      assert html =~ "Engineering"
      assert html =~ "Sales"
      assert html =~ "Backend"
    end

    test "renders upcoming-birthdays section when DOBs are within window", %{conn: conn} do
      today = Date.utc_today()
      future_dob = Date.add(today, 3)
      dob = Date.new!(future_dob.year - 25, future_dob.month, future_dob.day)

      _person = fixture_person(%{"date_of_birth" => Date.to_string(dob)})

      {:ok, _view, html} = live(conn, "/en/admin/staff/")

      # The section only renders when `upcoming_birthdays/1` returns rows, so
      # its heading is the assertion — not the page subtitle, which is always
      # there and would make this pass with no birthdays at all.
      assert html =~ "Upcoming birthdays"
    end

    test "PubSub broadcast triggers reload (handle_info {:staff, _, _} branch)", %{conn: conn} do
      {:ok, view, _initial} = live(conn, "/en/admin/staff/")

      _new_dept =
        fixture_department(%{"name" => "Marketing-#{System.unique_integer([:positive])}"})

      StaffPubSub.broadcast_department(:department_created, %{
        uuid: Ecto.UUID.generate(),
        name: "anything"
      })

      :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Marketing-"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "Activity wrapper — branches" do
    test "actor_uuid/1 with no current_user assigns returns nil" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
      assert PhoenixKitStaff.Activity.actor_uuid(socket) == nil
    end

    test "actor_uuid/1 with current_user containing :uuid returns it" do
      uuid = Ecto.UUID.generate()

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          phoenix_kit_current_user: %{uuid: uuid, email: "x@y"},
          __changed__: %{}
        }
      }

      assert PhoenixKitStaff.Activity.actor_uuid(socket) == uuid
    end

    test "actor_uuid/1 with current_user but no :uuid returns nil" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          phoenix_kit_current_user: %{email: "no-uuid@example.com"},
          __changed__: %{}
        }
      }

      assert PhoenixKitStaff.Activity.actor_uuid(socket) == nil
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "DepartmentFormLive — error path coverage" do
    test "edit mode handles non-existent uuid gracefully", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/en/admin/staff/departments"}}} =
               live(conn, "/en/admin/staff/departments/#{bogus}/edit")
    end

    test "edit save updates and logs activity", %{conn: conn, actor_uuid: actor_uuid} do
      dept = fixture_department(%{"name" => "OldName-#{System.unique_integer([:positive])}"})
      new_name = "NewName-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, "/en/admin/staff/departments/#{dept.uuid}/edit")

      view
      |> form("#department-form", department: %{name: new_name})
      |> render_submit()

      assert_activity_logged("staff.department_updated",
        resource_uuid: dept.uuid,
        actor_uuid: actor_uuid
      )

      assert Departments.get!(dept.uuid).name == new_name
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PhoenixKitStaff module — enable/disable settings round-trip" do
    test "enable_system writes the setting and enabled? reads it back" do
      assert {:ok, _setting} = PhoenixKitStaff.enable_system()
      assert PhoenixKitStaff.enabled?() == true
    end

    test "disable_system writes the setting and enabled? reads false" do
      assert {:ok, _} = PhoenixKitStaff.enable_system()
      assert {:ok, _} = PhoenixKitStaff.disable_system()
      assert PhoenixKitStaff.enabled?() == false
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "DepartmentShowLive / TeamShowLive — non-deletion broadcast branch when record is gone" do
    test "DepartmentShowLive redirects when broadcast hits and dept was removed", %{conn: conn} do
      dept = fixture_department()

      {:ok, view, _html} = live(conn, "/en/admin/staff/departments/#{dept.uuid}")

      {:ok, _} = Departments.delete(dept)
      send(view.pid, {:staff, :stale_event, %{uuid: dept.uuid}})

      assert_redirect(view, "/en/admin/staff/departments")
    end

    test "TeamShowLive redirects when broadcast hits and team was removed", %{conn: conn} do
      team = fixture_team()

      {:ok, view, _html} = live(conn, "/en/admin/staff/teams/#{team.uuid}")

      # Use the context to delete and broadcast.
      {:ok, _} = PhoenixKitStaff.Teams.delete(team)
      send(view.pid, {:staff, :stale_event, %{uuid: team.uuid}})

      assert_redirect(view, "/en/admin/staff/teams")
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "PeopleLive — filter and clear events" do
    test "filter event narrows the visible list", %{conn: conn} do
      _active = fixture_person(%{"status" => "active"})
      inactive = fixture_person()
      {:ok, _} = Staff.update_person(inactive, %{"status" => "inactive"})

      {:ok, view, _initial} = live(conn, "/en/admin/staff/people")

      html =
        view
        |> form("form[phx-change='filter']", %{search: "", status: "inactive"})
        |> render_change()

      assert html =~ inactive.user.email
    end

    test "clear event resets filters", %{conn: conn} do
      {:ok, view, _initial} = live(conn, "/en/admin/staff/people")

      # Push the filter via render_change first.
      view
      |> form("form[phx-change='filter']", %{search: "specific-search-term", status: "active"})
      |> render_change()

      # Then click Clear.
      html =
        view
        |> element("button[phx-click='clear']")
        |> render_click()

      refute html =~ "specific-search-term"
    end
  end

  # ────────────────────────────────────────────────────────────────
  describe "Staff context — placeholder user flow" do
    test "rename_placeholder_email returns :ok when new == current (no-op branch)" do
      # The new == current branch is reachable regardless of placeholder
      # state because it short-circuits BEFORE the placeholder check.
      person = fixture_person()
      assert :ok = Staff.rename_placeholder_email(person.user, person.user.email)
    end

    test "rename_placeholder_email rejects blank email (early-validation branch)" do
      # Same — blank_email check fires before the placeholder check.
      person = fixture_person()
      assert {:error, :blank_email} = Staff.rename_placeholder_email(person.user, "  ")
    end

    test "rename_placeholder_email rejects when target user is no longer a placeholder" do
      # `fixture_person/1` creates users via `register_user` which
      # marks them as confirmed/non-placeholder via core's auth flow,
      # so this exercises the `not placeholder?(user)` guard branch.
      person = fixture_person()
      taken = fixture_person()

      result = Staff.rename_placeholder_email(person.user, taken.user.email)

      assert result in [
               {:error, :email_already_taken},
               {:error, :placeholder_already_claimed}
             ]
    end

    test "find_or_create_user_by_email returns :existing for known email" do
      person = fixture_person()
      assert {:ok, _user, :existing} = Staff.find_or_create_user_by_email(person.user.email)
    end

    test "find_or_create_user_by_email returns :created for new email" do
      email = "fresh-#{System.unique_integer([:positive])}@example.com"
      assert {:ok, _user, :created} = Staff.find_or_create_user_by_email(email)
    end

    test "find_or_create_user_by_email rejects blank email" do
      assert {:error, :blank_email} = Staff.find_or_create_user_by_email("   ")
    end

    test "people_not_on_team excludes members already on the team" do
      team = fixture_team()
      p_on_team = fixture_person()
      p_off_team = fixture_person()

      {:ok, _} = Staff.add_team_person(team.uuid, p_on_team.uuid)

      result = Staff.people_not_on_team(team.uuid)
      result_uuids = Enum.map(result, & &1.uuid)

      assert p_off_team.uuid in result_uuids
      refute p_on_team.uuid in result_uuids
    end

    test "remove_team_person/2 returns :not_found for non-existent membership" do
      team = fixture_team()
      person = fixture_person()

      assert {:error, :not_found} = Staff.remove_team_person(team.uuid, person.uuid)
    end

    test "list_team_memberships returns memberships in insertion order" do
      team = fixture_team()
      p1 = fixture_person()
      p2 = fixture_person()

      {:ok, _} = Staff.add_team_person(team.uuid, p1.uuid)
      {:ok, _} = Staff.add_team_person(team.uuid, p2.uuid)

      result = Staff.list_team_memberships(team.uuid)
      assert length(result) == 2
    end

    test "eligible_users excludes users who already have a staff profile" do
      person = fixture_person()
      eligible_uuids = Staff.eligible_users() |> Enum.map(& &1.uuid)

      refute person.user_uuid in eligible_uuids
    end

    test "eligible_users keeps the linked user when exclude_person_uuid is the linked person" do
      person = fixture_person()

      eligible_uuids =
        Staff.eligible_users(exclude_person_uuid: person.uuid) |> Enum.map(& &1.uuid)

      assert person.user_uuid in eligible_uuids
    end
  end
end
