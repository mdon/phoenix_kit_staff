defmodule PhoenixKitStaff.Integration.SoftDeleteTest do
  @moduledoc """
  Soft-delete (trash / restore / permanent delete) for staff people:
  status-sentinel behavior, prior-status preservation via the V130
  `metadata` column, default-scope exclusion, the bulk set-based
  variants, and the `trashed_person_exists` re-onboarding guard.
  """

  use PhoenixKitStaff.DataCase, async: false

  alias PhoenixKitStaff.Schemas.Person
  alias PhoenixKitStaff.Staff

  describe "trash_person/1" do
    test "sets status to trashed and stashes the prior status" do
      person = fixture_person(%{"status" => "inactive"})

      assert {:ok, trashed} = Staff.trash_person(person)
      assert trashed.status == "trashed"
      assert trashed.metadata["trashed_from_status"] == "inactive"
      assert Person.trashed?(trashed)
    end

    test "trash and restore both bump updated_at, like their bulk variants" do
      person = fixture_person()
      stale = DateTime.add(person.updated_at, -3600, :second)

      Repo.update_all(
        from(p in Person, where: p.uuid == ^person.uuid),
        set: [updated_at: stale]
      )

      assert {:ok, trashed} = Staff.trash_person(%{person | updated_at: stale})
      assert DateTime.compare(trashed.updated_at, stale) == :gt
      assert Staff.get_person(person.uuid).updated_at == trashed.updated_at

      Repo.update_all(
        from(p in Person, where: p.uuid == ^person.uuid),
        set: [updated_at: stale]
      )

      assert {:ok, restored} = Staff.restore_person(%{trashed | updated_at: stale})
      assert DateTime.compare(restored.updated_at, stale) == :gt
      assert Staff.get_person(person.uuid).updated_at == restored.updated_at
    end

    test "is idempotent-safe: already-trashed returns an error" do
      person = fixture_person()
      {:ok, trashed} = Staff.trash_person(person)
      assert {:error, :already_trashed} = Staff.trash_person(trashed)
    end

    test "keeps a key another session wrote after the person was loaded" do
      person = fixture_person()
      # Another session sets the avatar behind this struct's back.
      Repo.update!(Ecto.Changeset.change(person, metadata: %{"avatar_uuid" => "abc"}))

      assert {:ok, trashed} = Staff.trash_person(person)
      assert trashed.metadata == %{"avatar_uuid" => "abc", "trashed_from_status" => "active"}
      assert Repo.reload(person).metadata == trashed.metadata
    end

    test "the second of two sessions trashing the same person is told so" do
      person = fixture_person()
      assert {:ok, _} = Staff.trash_person(person)
      # This copy still reads active — the guard is in the UPDATE.
      assert {:error, :already_trashed} = Staff.trash_person(person)
    end
  end

  describe "restore_person/1" do
    test "returns to the stashed prior status and clears the stash" do
      person = fixture_person(%{"status" => "inactive"})
      {:ok, trashed} = Staff.trash_person(person)

      assert {:ok, restored} = Staff.restore_person(trashed)
      assert restored.status == "inactive"
      refute Map.has_key?(restored.metadata, "trashed_from_status")
    end

    test "keeps a key another session wrote while the person sat in the trash" do
      person = fixture_person()
      {:ok, trashed} = Staff.trash_person(person)

      Repo.update!(
        Ecto.Changeset.change(trashed, metadata: Map.put(trashed.metadata, "avatar_uuid", "abc"))
      )

      assert {:ok, restored} = Staff.restore_person(trashed)
      assert restored.status == "active"
      assert restored.metadata == %{"avatar_uuid" => "abc"}
    end

    test "defaults to active when the stash is missing or garbage" do
      person = fixture_person(%{"status" => "active"})
      # Simulate a row trashed with a junk stash value.
      {:ok, trashed} = Staff.trash_person(person)

      {:ok, junk} =
        Staff.update_person(trashed, %{"metadata" => %{"trashed_from_status" => "bogus"}})

      assert {:ok, restored} = Staff.restore_person(junk)
      assert restored.status == "active"
    end

    test "non-trashed person returns an error" do
      person = fixture_person()
      assert {:error, :not_trashed} = Staff.restore_person(person)
    end
  end

  describe "delete_person/1 (permanent)" do
    test "hard-deletes a trashed row" do
      person = fixture_person()
      {:ok, trashed} = Staff.trash_person(person)

      assert {:ok, _} = Staff.delete_person(trashed)
      assert Staff.get_person(person.uuid) == nil
    end

    test "refuses to permanently delete a non-trashed person" do
      person = fixture_person()
      assert {:error, :not_trashed} = Staff.delete_person(person)
      assert Staff.get_person(person.uuid) != nil
    end

    test "refuses a stale trashed struct whose DB row is now active (TOCTOU)" do
      person = fixture_person()
      {:ok, trashed} = Staff.trash_person(person)
      {:ok, _restored} = Staff.restore_person(trashed)

      # `trashed` still says status: "trashed", but the row is active now.
      assert {:error, :not_trashed} = Staff.delete_person(trashed)
      assert Staff.get_person(person.uuid).status == "active"
    end
  end

  describe "changeset hardening" do
    test "the public changeset rejects the trashed sentinel from params" do
      person = fixture_person()
      cs = Staff.change_person(person, %{"status" => "trashed"})
      refute cs.valid?
      assert %{status: _} = errors_on(cs)

      # Editing via the public update path can't soft-delete out-of-band.
      assert {:error, _} = Staff.update_person(person, %{"status" => "trashed"})
      assert Staff.get_person(person.uuid).status == "active"
    end
  end

  describe "list_people/1 scoping" do
    test "excludes trashed by default; status: \"trashed\" returns only trashed" do
      active = fixture_person(%{"status" => "active"})
      to_trash = fixture_person()
      {:ok, trashed} = Staff.trash_person(to_trash)

      default_uuids = Staff.list_people() |> Enum.map(& &1.uuid)
      assert active.uuid in default_uuids
      refute trashed.uuid in default_uuids

      trash_uuids = Staff.list_people(status: "trashed") |> Enum.map(& &1.uuid)
      assert trash_uuids == [trashed.uuid]

      all_uuids = Staff.list_people(include_trashed: true) |> Enum.map(& &1.uuid)
      assert active.uuid in all_uuids
      assert trashed.uuid in all_uuids
    end
  end

  describe "count_people/0 and count_trashed/0" do
    test "count_people excludes trashed; count_trashed counts only trashed" do
      _a = fixture_person()
      b = fixture_person()
      {:ok, _} = Staff.trash_person(b)

      assert Staff.count_people() == 1
      assert Staff.count_trashed() == 1
    end
  end

  describe "create_person/1 trashed-profile guard" do
    test "returns trashed_person_exists when the user already has a trashed profile" do
      person = fixture_person()
      {:ok, _trashed} = Staff.trash_person(person)

      assert {:error, {:trashed_person_exists, existing}} =
               Staff.create_person(%{"user_uuid" => person.user_uuid, "status" => "active"})

      assert existing.uuid == person.uuid
    end
  end

  describe "bulk operations" do
    test "bulk_trash stashes per-row prior status and skips already-trashed" do
      a = fixture_person(%{"status" => "active"})
      b = fixture_person(%{"status" => "inactive"})
      {:ok, already} = Staff.trash_person(fixture_person())

      assert {:ok, 2} = Staff.bulk_trash([a.uuid, b.uuid, already.uuid])

      assert Staff.get_person(a.uuid).metadata["trashed_from_status"] == "active"
      assert Staff.get_person(b.uuid).metadata["trashed_from_status"] == "inactive"
      assert Staff.count_trashed() == 3
    end

    test "bulk_restore returns each row to its stashed status" do
      a = fixture_person(%{"status" => "active"})
      b = fixture_person(%{"status" => "inactive"})
      {:ok, 2} = Staff.bulk_trash([a.uuid, b.uuid])

      assert {:ok, 2} = Staff.bulk_restore([a.uuid, b.uuid])
      assert Staff.get_person(a.uuid).status == "active"
      assert Staff.get_person(b.uuid).status == "inactive"
      assert Staff.count_trashed() == 0
    end

    test "bulk_delete permanently removes trashed rows only" do
      a = fixture_person()
      b = fixture_person()
      active = fixture_person()
      {:ok, 2} = Staff.bulk_trash([a.uuid, b.uuid])

      # active row in the selection is left untouched; only the 2 trashed go.
      assert {:ok, 2} = Staff.bulk_delete([a.uuid, b.uuid, active.uuid])
      assert Staff.get_person(a.uuid) == nil
      assert Staff.get_person(b.uuid) == nil
      assert Staff.get_person(active.uuid) != nil
    end
  end

  describe "org_tree/0 and people_not_on_team/1 exclude trashed" do
    test "a trashed member drops out of the team roster and the add-picker" do
      team = fixture_team()
      person = fixture_person()
      {:ok, _} = Staff.add_team_person(team.uuid, person.uuid)

      # On the team before trashing; not in the add-picker.
      refute person.uuid in (Staff.people_not_on_team(team.uuid) |> Enum.map(& &1.uuid))

      {:ok, _} = Staff.trash_person(person)

      roster_uuids =
        Staff.org_tree().departments
        |> Enum.flat_map(fn d ->
          Enum.flat_map(d.teams, fn t -> Enum.map(t.people, & &1.uuid) end)
        end)

      refute person.uuid in roster_uuids
      # Still excluded from the picker (trashed, not "available").
      refute person.uuid in (Staff.people_not_on_team(team.uuid) |> Enum.map(& &1.uuid))
    end

    test "list_team_memberships excludes a trashed member from the team roster" do
      team = fixture_team()
      person = fixture_person()
      {:ok, _} = Staff.add_team_person(team.uuid, person.uuid)
      assert [_] = Staff.list_team_memberships(team.uuid)

      {:ok, _} = Staff.trash_person(person)
      assert [] = Staff.list_team_memberships(team.uuid)
    end
  end

  describe "context create-paths reject a trashed person (direct-API guard)" do
    test "assign_skill/3 refuses a trashed person and inserts nothing" do
      skill = fixture_skill()
      {:ok, trashed} = Staff.trash_person(fixture_person())

      assert {:error, :person_trashed} = Staff.assign_skill(trashed.uuid, skill.uuid, [])
      # `list_skills_for_person/1` is keyed on the person (no trashed filter), so
      # an empty result proves the rolled-back transaction left no row behind.
      assert Staff.list_skills_for_person(trashed.uuid) == []
    end

    test "add_team_person/2 refuses a trashed person and inserts nothing" do
      team = fixture_team()
      {:ok, trashed} = Staff.trash_person(fixture_person())

      assert {:error, :person_trashed} = Staff.add_team_person(team.uuid, trashed.uuid)
      # `list_memberships_for_person/1` is keyed on the person (no trashed
      # filter), so an empty result proves no membership row was inserted.
      assert Staff.list_memberships_for_person(trashed.uuid) == []
    end

    test "Employments.create/2 refuses a trashed person and inserts nothing" do
      {:ok, trashed} = Staff.trash_person(fixture_person())

      assert {:error, :person_trashed} =
               PhoenixKitStaff.Employments.create(trashed.uuid, %{
                 "employment_type" => "full_time",
                 "job_title" => "Engineer",
                 "employment_start_date" => "2024-01-01"
               })

      # Keyed on the person (no trashed filter) — empty proves the
      # transaction rolled back before the insert.
      assert PhoenixKitStaff.Employments.list_for_person(trashed.uuid) == []
    end

    test "Attachments.set_avatar/2 refuses a trashed person (clear stays allowed)" do
      {:ok, trashed} = Staff.trash_person(fixture_person())

      assert {:error, :person_trashed} =
               PhoenixKitStaff.Attachments.set_avatar(trashed, Ecto.UUID.generate())
    end
  end
end
