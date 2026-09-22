defmodule PhoenixKitStaff.Attachments do
  @moduledoc """
  Folder-scoped media attachments for a staff person, backed by core
  `PhoenixKit.Modules.Storage` (the same per-resource-folder convention
  `phoenix_kit_catalogue`/`phoenix_kit_locations` use — no module-owned
  table, no migration).

  Each person owns a deterministic root folder `staff-person-<uuid>` for
  generic files, with a nested **`Images`** subfolder (`parent_uuid` = the
  root) for images — i.e. all of a person's files in one folder, images in a
  folder inside it. Folders are resolved **by name** on every read (never
  cached on `Person`, so an admin renaming/deleting the folder in
  `/admin/media` can't strand a dangling uuid) and created lazily on first
  upload. The `[:name, :parent_uuid]` unique index in core makes
  find-or-create race-safe.

  Files live in core `phoenix_kit_files` under the folder; uploading/browsing
  is done by `MediaSelectorModal` (scoped to the folder), so this module only
  resolves folders, lists their files, (un)links picked files, and removes
  them — mirroring `PhoenixKitCatalogue.Attachments`' write semantics
  (soft-trash a sole-owner file, unlink a shared one). It never hard-deletes
  a possibly-shared asset.

  ## Parent folder

  By default a person's folder is created at the storage root. A host can
  group them:

      config :phoenix_kit_staff, :attachments_parent_folder, {MyApp.Media, :parent_for}

  called as `parent_for(:person, actor_uuid, person_uuid)` (or
  `parent_for(:person, actor_uuid)`), returning `{:ok, parent_folder_uuid}` or
  `nil` (root). The hook only decides where a **new** root folder is created.
  Lookups don't depend on its answer: the root folder name embeds the person
  uuid, so it is resolved by name — under the configured parent first, then at
  the root (folders that predate the setting), then under any other parent
  (the hook's answer changed, e.g. it varies by actor). Purge removes every
  folder carrying the name.
  """

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, Folder, ResourceFolders}
  alias PhoenixKit.Utils.Format
  alias PhoenixKitStaff.Schemas.Person

  @images_folder_name "Images"
  @avatar_key "avatar_uuid"
  # Inline grid is unpaginated; cap the query so a pathological folder can't
  # freeze the tab. The picker uploads ≤20/submit, so this is generous.
  @list_limit 200

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "Deterministic root folder name for a person's files."
  @spec root_folder_name(binary()) :: binary()
  def root_folder_name(person_uuid), do: "staff-person-#{person_uuid}"

  # ── Folder resolution ──────────────────────────────────────────────

  @doc """
  Resolves the folder uuid for `kind` (`:files` → root, `:images` → the
  nested `Images` subfolder) **without creating** it. Returns the uuid or
  `nil` (used on render so viewing a tab doesn't spawn empty folders).
  """
  @spec folder_uuid(binary(), :files | :images, binary() | nil) :: binary() | nil
  def folder_uuid(person_uuid, kind, actor_uuid \\ nil)

  def folder_uuid(person_uuid, :files, actor_uuid),
    do: uuid_of(get_root_folder(person_uuid, actor_uuid))

  def folder_uuid(person_uuid, :images, actor_uuid) do
    case get_root_folder(person_uuid, actor_uuid) do
      %Folder{uuid: root} ->
        uuid_of(
          quietly("get_folder", nil, fn ->
            ResourceFolders.find_under(@images_folder_name, root)
          end)
        )

      _ ->
        nil
    end
  end

  @doc """
  Find-or-create the folder for `kind`, returning `{:ok, uuid}` or
  `{:error, :folder_unavailable}`. Race-safe: a lost create (unique
  `[:name, :parent_uuid]`) re-resolves the winner. Call when an action needs
  the folder to exist (opening the picker / handling a selection).
  """
  @spec ensure_folder(binary(), :files | :images, binary() | nil) ::
          {:ok, binary()} | {:error, term()}
  def ensure_folder(person_uuid, :files, actor_uuid) do
    name = root_folder_name(person_uuid)
    parent_uuid = parent_folder_uuid(:person, actor_uuid, person_uuid)

    name
    |> ResourceFolders.ensure(parent_uuid, actor_uuid,
      lookup: fn -> find_root_folder(name, parent_uuid) end
    )
    |> ensured()
  end

  # "Images" is not a unique name, so it is only ever looked up inside the
  # person's folder — never at the storage root, where a host's own "Images"
  # folder may live.
  def ensure_folder(person_uuid, :images, actor_uuid) do
    with {:ok, root} <- ensure_folder(person_uuid, :files, actor_uuid) do
      @images_folder_name |> ResourceFolders.ensure(root, actor_uuid) |> ensured()
    end
  end

  defp ensured({:ok, %Folder{uuid: uuid}}), do: {:ok, uuid}
  defp ensured({:error, _reason}), do: {:error, :folder_unavailable}

  @doc false
  # Host-configured parent folder for `:person`; `nil` = storage root (default).
  # Contract: `fun(:person, actor_uuid, subject)` (preferred) or `fun(:person, actor_uuid)`;
  # `subject` is the person uuid. A failing hook or a non-uuid answer falls back
  # to the root, logged (`ResourceFolders.parent_uuid/4`).
  def parent_folder_uuid(kind, actor_uuid, subject \\ nil),
    do: ResourceFolders.parent_uuid(:phoenix_kit_staff, kind, actor_uuid, subject)

  defp get_root_folder(person_uuid, actor_uuid) do
    find_root_folder(
      root_folder_name(person_uuid),
      parent_folder_uuid(:person, actor_uuid, person_uuid)
    )
  end

  # The root name embeds the person uuid, so every folder carrying it is this
  # person's wherever it sits: the configured parent first, then the root
  # (folders that predate the hook), then any other parent (the hook's answer
  # changed, e.g. it varies by actor). Live folders only.
  defp find_root_folder(name, parent_uuid) do
    quietly("get_folder", nil, fn ->
      ResourceFolders.find_named(name, parent_uuid, anywhere: true)
    end)
  end

  defp uuid_of(%Folder{uuid: uuid}), do: uuid
  defp uuid_of(_), do: nil

  # A read on a render path: a failure is logged and answers `default`.
  defp quietly(what, default, fun) do
    fun.()
  rescue
    error ->
      Logger.warning("[Staff] #{what} failed: #{inspect(error)}")
      default
  catch
    :exit, reason ->
      Logger.warning(
        "[Staff] #{what} failed: #{ResourceFolders.describe_failure({:exit, reason})}"
      )

      default
  end

  # ── Listing ────────────────────────────────────────────────────────

  @doc """
  Files attached to `folder_uuid` (home-folder files plus those linked in via
  `FolderLink`), newest first, excluding trashed and system-managed ones.
  `:only` narrows by type: `:images` (file_type == "image"), `:non_images`
  (everything else), or `:all` (default). Defensive — keeps a tab showing only
  its own kind even if a stray file of the other kind landed in the folder.
  """
  @spec list_files(binary() | nil, keyword()) :: [File.t()]
  def list_files(nil, _opts), do: []

  def list_files(folder_uuid, opts) do
    quietly("list_files #{folder_uuid}", [], fn ->
      ResourceFolders.list_files(folder_uuid,
        only: Keyword.get(opts, :only, :all),
        limit: @list_limit
      )
    end)
  end

  @doc "Whether the file with this uuid is an image (by Storage `file_type`)."
  @spec image?(binary()) :: boolean()
  def image?(file_uuid) do
    match?(%File{file_type: "image"}, Storage.get_file(file_uuid))
  rescue
    _ -> false
  end

  # ── Attach / detach ────────────────────────────────────────────────

  @doc """
  Ensures `file_uuid` is attached to `folder_uuid` by core's rule: a no-op if
  already there (the modal's scoped uploads land here directly); adopts an
  orphan file as home; otherwise adds a `FolderLink` so a file picked from
  elsewhere appears here without being moved from its owner. Always `:ok`; a
  failure is logged.
  """
  @spec attach(binary(), binary()) :: :ok
  def attach(file_uuid, folder_uuid) do
    case ResourceFolders.attach(file_uuid, folder_uuid) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Staff] attach #{file_uuid} failed: #{ResourceFolders.describe_failure(reason)}"
        )

        :ok
    end
  end

  @doc """
  Removes a file from `folder_uuid` by core's rule: a link is dropped; a file
  homed here moves to a live folder that also links it, or is soft-trashed
  (recoverable in the media trash) when nothing else holds it. Never
  hard-deletes a shared asset, never touches a file that is not here.
  """
  @spec detach(binary(), binary() | nil) :: :ok | {:error, term()}
  def detach(file_uuid, folder_uuid) do
    case ResourceFolders.detach(file_uuid, folder_uuid) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Lifecycle ──────────────────────────────────────────────────────

  @doc """
  Permanently purges a person's media — deletes the root folder and its whole
  subtree (the nested `Images` folder + every file, including bucket copies;
  a file another folder links survives there) via core's cascading
  `delete_folder_completely/1`. Every folder named `staff-person-<uuid>`
  goes, wherever it sits and trashed or not, so it neither consults the
  parent-folder hook nor misses a folder created under an earlier answer.
  Best-effort: logs and returns `:ok` on any failure so it never blocks a
  person deletion. Call only on a **permanent** delete (soft-trash keeps the
  files).
  """
  @spec purge_person_media(binary()) :: :ok
  def purge_person_media(person_uuid),
    do: ResourceFolders.purge_named(root_folder_name(person_uuid))

  # ── Template helpers ───────────────────────────────────────────────

  @doc "Heroicon name for a file based on its Storage type / mime (`Format.file_icon/1`)."
  @spec file_icon(map()) :: String.t()
  defdelegate file_icon(file), to: Format

  @doc "Human-readable byte count (decimal units). Nil-safe."
  @spec format_file_size(integer() | nil) :: String.t()
  def format_file_size(bytes), do: Format.bytes(bytes, base: 1000, unknown: "—")

  @doc "Public download URL for a file (nil-safe)."
  @spec download_url(map()) :: String.t() | nil
  def download_url(%File{} = file), do: safe_url(fn -> Storage.get_public_url(file) end)
  def download_url(_), do: nil

  @doc "Thumbnail URL for an image file, falling back to the original (nil-safe)."
  @spec thumb_url(map()) :: String.t() | nil
  def thumb_url(%File{} = file),
    do: safe_url(fn -> Storage.get_public_url_by_variant(file, "thumbnail") end)

  def thumb_url(_), do: nil

  defp safe_url(fun) do
    fun.()
  rescue
    _ -> nil
  end

  # ── Avatar ─────────────────────────────────────────────────────────
  #
  # A person's avatar is a single image-file pointer kept in `Person.metadata`
  # (`"avatar_uuid"`) — no new column, mirroring catalogue's featured-image
  # pointer. The image is one of the person's Images-folder files (the avatar
  # picker is scoped to that folder), so uploads/picks stay in sync with the
  # Images tab. Server-owned: written only via `set_avatar/2` / `clear_avatar/1`.

  @doc "The person's avatar file uuid (from metadata), or nil."
  @spec avatar_uuid(Person.t()) :: binary() | nil
  def avatar_uuid(%Person{metadata: m}) when is_map(m) do
    case Map.get(m, @avatar_key) do
      uuid when is_binary(uuid) and uuid != "" -> uuid
      _ -> nil
    end
  end

  def avatar_uuid(_), do: nil

  @doc "The person's avatar `File` struct, or nil if unset / missing / trashed."
  @spec avatar_file(Person.t()) :: File.t() | nil
  def avatar_file(person) do
    case avatar_uuid(person) do
      nil ->
        nil

      uuid ->
        case Storage.get_file(uuid) do
          %File{status: "trashed"} -> nil
          %File{} = file -> file
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  @doc "Thumbnail URL for the person's avatar (or nil)."
  @spec avatar_url(Person.t()) :: String.t() | nil
  def avatar_url(person), do: person |> avatar_file() |> thumb_url()

  @doc """
  Points the person's avatar at `file_uuid` (server-owned metadata write).
  Refuses a trashed person (`{:error, :person_trashed}`) — a removed person
  shouldn't gain a new profile photo; clearing the avatar stays unguarded.
  """
  @spec set_avatar(Person.t(), binary()) :: {:ok, Person.t()} | {:error, term()}
  def set_avatar(%Person{} = person, file_uuid) when is_binary(file_uuid) and file_uuid != "" do
    if Person.trashed?(person),
      do: {:error, :person_trashed},
      else: put_metadata(person, @avatar_key, file_uuid)
  end

  @doc "Clears the person's avatar pointer."
  @spec clear_avatar(Person.t()) :: {:ok, Person.t()} | {:error, term()}
  def clear_avatar(%Person{} = person), do: put_metadata(person, @avatar_key, nil)

  defp put_metadata(person, key, value) do
    metadata = person.metadata || %{}

    metadata =
      if is_nil(value), do: Map.delete(metadata, key), else: Map.put(metadata, key, value)

    person |> Ecto.Changeset.change(metadata: metadata) |> repo().update()
  end
end
