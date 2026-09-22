defmodule PhoenixKitStaff.Integration.AttachmentsAvatarTest do
  @moduledoc """
  The avatar pointer round-trips through `Person.metadata`, and points only
  at one of the person's own images.
  """
  use PhoenixKitStaff.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitStaff.Attachments

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
