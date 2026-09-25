defmodule PhoenixKitStaff.Integration.AttachmentsAvatarTest do
  @moduledoc """
  The avatar pointer round-trips through `Person.metadata`, and points only
  at one of the person's own images.
  """
  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitStaff.Attachments
  alias PhoenixKitStaff.Staff

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp image!(person, folder_uuid, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    repo().insert!(
      struct(
        %StorageFile{
          original_file_name: "photo-#{n}.jpg",
          file_name: "photo-#{n}.jpg",
          mime_type: "image/jpeg",
          file_type: "image",
          ext: "jpg",
          file_checksum: "staff-#{n}",
          user_file_checksum: "staff-u-#{n}",
          size: 1,
          status: "active",
          folder_uuid: folder_uuid,
          user_uuid: person.user.uuid
        },
        attrs
      )
    )
  end

  defp own_image!(person) do
    {:ok, images} = Attachments.ensure_folder(person.uuid, :images, nil)
    image!(person, images)
  end

  test "set/clear avatar round-trips and avatar_uuid reads it back" do
    person = fixture_person()
    assert Attachments.avatar_uuid(person) == nil

    photo = own_image!(person)
    {:ok, updated} = Attachments.set_avatar(person, photo.uuid)
    assert Attachments.avatar_uuid(updated) == photo.uuid
    assert Attachments.avatar_file(updated).uuid == photo.uuid

    {:ok, cleared} = Attachments.clear_avatar(updated)
    assert Attachments.avatar_uuid(cleared) == nil
  end

  test "setting the avatar preserves other metadata keys" do
    person = fixture_person()

    {:ok, person} =
      person
      |> Ecto.Changeset.change(metadata: %{"trashed_from_status" => "active"})
      |> repo().update()

    photo = own_image!(person)
    {:ok, updated} = Attachments.set_avatar(person, photo.uuid)

    assert updated.metadata["avatar_uuid"] == photo.uuid
    assert updated.metadata["trashed_from_status"] == "active"
  end

  test "an avatar change from a stale copy of the person keeps keys written since" do
    person = fixture_person()
    photo = own_image!(person)

    # Another session writes a metadata key after this copy was loaded.
    {:ok, _} =
      person
      |> Ecto.Changeset.change(metadata: %{"trashed_from_status" => "active"})
      |> repo().update()

    {:ok, updated} = Attachments.set_avatar(person, photo.uuid)
    assert updated.metadata == %{"trashed_from_status" => "active", "avatar_uuid" => photo.uuid}
    assert repo().reload(person).metadata == updated.metadata

    {:ok, cleared} = Attachments.clear_avatar(person, photo.uuid)
    assert cleared.metadata == %{"trashed_from_status" => "active"}
  end

  test "refuses when the person was trashed after they were loaded, and leaves no avatar" do
    person = fixture_person()
    photo = own_image!(person)
    # Another session trashes them; `person` still reads active.
    {:ok, _} = Staff.trash_person(Repo.reload(person))

    assert {:error, :person_trashed} = Attachments.set_avatar(person, photo.uuid)
    assert Attachments.avatar_uuid(Repo.reload(person)) == nil
  end

  test "a metadata map from params can neither set nor clear the avatar pointer" do
    person = fixture_person()
    photo = own_image!(person)
    {:ok, _} = Attachments.set_avatar(person, photo.uuid)
    other = own_image!(person)

    # Spoof it in both key spellings alongside a legitimate host key.
    assert {:ok, updated} =
             Staff.update_person(Repo.reload(person), %{
               "metadata" => %{
                 "avatar_uuid" => other.uuid,
                 :avatar_uuid => other.uuid,
                 "hr" => "x"
               }
             })

    assert updated.metadata == %{"avatar_uuid" => photo.uuid, "hr" => "x"}

    # Leaving the key out does not clear it either.
    assert {:ok, updated} = Staff.update_person(updated, %{"metadata" => %{"hr" => "y"}})
    assert Repo.reload(updated).metadata == %{"avatar_uuid" => photo.uuid, "hr" => "y"}
  end

  test "only one of the person's own images can become the avatar" do
    person = fixture_person()
    other = fixture_person()
    {:ok, elsewhere} = Storage.create_folder(%{name: "Elsewhere #{System.unique_integer()}"})

    theirs = own_image!(other)
    loose = image!(person, elsewhere.uuid)

    document =
      own_image!(person) |> Ecto.Changeset.change(file_type: "document") |> repo().update!()

    for uuid <- [theirs.uuid, loose.uuid, document.uuid, Ecto.UUID.generate()] do
      assert Attachments.set_avatar(person, uuid) == {:error, :not_person_image}
    end

    assert Attachments.avatar_uuid(repo().reload(person)) == nil
  end

  test "avatar_file is nil when the pointer names a missing or trashed file" do
    person = fixture_person()
    photo = own_image!(person)
    {:ok, updated} = Attachments.set_avatar(person, photo.uuid)

    photo |> Ecto.Changeset.change(status: "trashed") |> repo().update!()
    assert Attachments.avatar_file(updated) == nil
    assert Attachments.avatar_url(updated) == nil
  end
end
