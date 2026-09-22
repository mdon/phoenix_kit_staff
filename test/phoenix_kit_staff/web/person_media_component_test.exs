defmodule PhoenixKitStaff.Web.PersonMediaComponentTest do
  @moduledoc """
  Smoke tests for the Files / Images tabs on the person profile.

  The attach/remove/avatar mutation paths are pinned at the context layer
  (`Attachments` + the soft-delete create-path guard in
  `integration/soft_delete_test.exs`); these cover the component's render +
  tab wiring, and the avatar clear when its image is removed. Storage is an
  always-enabled core module, so the tabs render; with no folder seeded the
  file list is empty and the empty-state copy shows.
  """
  use PhoenixKitStaff.LiveCase, async: false

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKitStaff.{Attachments, Staff}

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp open_tab(conn, person, tab) do
    {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")
    render_click(view, "switch_tab", %{"tab" => tab})
    view
  end

  test "the Files tab renders its heading, Add button, and empty state", %{conn: conn} do
    html = render(open_tab(conn, fixture_person(), "files"))

    assert html =~ "Files"
    assert html =~ "Add files"
    assert html =~ "No files yet."
  end

  test "the Images tab renders its heading, Add button, and empty state", %{conn: conn} do
    html = render(open_tab(conn, fixture_person(), "images"))

    assert html =~ "Images"
    assert html =~ "Add images"
    assert html =~ "No images yet."
  end

  describe "the avatar from the Images tab" do
    defp photo!(person) do
      {:ok, images} = Attachments.ensure_folder(person.uuid, :images, nil)
      n = System.unique_integer([:positive])

      PhoenixKit.RepoHelper.repo().insert!(%StorageFile{
        original_file_name: "p#{n}.jpg",
        file_name: "p#{n}.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: "media-#{n}",
        user_file_checksum: "media-u-#{n}",
        size: 1,
        status: "active",
        folder_uuid: images,
        user_uuid: person.user.uuid
      })
    end

    defp remove(view, file) do
      view
      |> element(~s(button[phx-click="remove_file"][phx-value-uuid="#{file.uuid}"]))
      |> render_click()
    end

    defp avatar(person), do: Attachments.avatar_uuid(Staff.get_person!(person.uuid))

    test "removing the avatar's image clears the avatar", %{conn: conn} do
      person = fixture_person()
      old = photo!(person)
      {:ok, _} = Attachments.set_avatar(person, old.uuid)

      conn |> open_tab(person, "images") |> remove(old)

      assert avatar(person) == nil
    end

    test "an avatar set by another session since the tab loaded survives", %{conn: conn} do
      person = fixture_person()
      [old, new] = [photo!(person), photo!(person)]
      {:ok, _} = Attachments.set_avatar(person, old.uuid)
      view = open_tab(conn, person, "images")

      {:ok, _} = Attachments.set_avatar(person, new.uuid)
      remove(view, old)

      assert avatar(person) == new.uuid
    end

    test "a refused avatar pick leaves an audit row", %{conn: conn} do
      person = fixture_person()
      photo!(person)
      view = open_tab(conn, person, "images")
      stranger = Ecto.UUID.generate()

      # A forged pick: the tab's own button, carrying a file that is not one
      # of the person's images.
      view
      |> element(~s(button[phx-click="set_as_avatar"]))
      |> render_click(%{"uuid" => stranger})

      assert_activity_logged("staff.person_avatar_set",
        resource_uuid: person.uuid,
        metadata_has: %{
          "db_pending" => true,
          "error_atom" => "not_person_image",
          "file_uuid" => stranger
        }
      )
    end

    test "the page's Remove photo clears only the photo it shows", %{conn: conn} do
      person = fixture_person()
      [old, new] = [photo!(person), photo!(person)]
      {:ok, _} = Attachments.set_avatar(person, old.uuid)
      {:ok, view, _html} = live(conn, "/en/admin/staff/people/#{person.uuid}")

      {:ok, _} = Attachments.set_avatar(person, new.uuid)
      render_click(view, "remove_avatar", %{})

      assert avatar(person) == new.uuid
    end
  end
end
