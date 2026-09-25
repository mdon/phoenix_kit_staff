defmodule PhoenixKitStaff.Web.PersonMediaComponent do
  @moduledoc """
  The **Files** and **Images** tabs of a staff person's profile (one component,
  parameterized by `:kind`). Media is folder-scoped via core
  `PhoenixKit.Modules.Storage` (see `PhoenixKitStaff.Attachments`): the person's
  root `staff-person-<uuid>` folder for `:files`, the nested `Images` subfolder
  for `:images`.

  Upload/browse is delegated to core's `MediaSelectorModal` (scoped to the
  folder via `scope_folder_id`, so the modal owns its own `allow_upload` — this
  component never configures uploads itself). The modal `notify`s its result
  back here; we attach each picked/uploaded file to the folder and refresh.
  Removal soft-trashes a sole-owner file or unlinks a shared one. Every add/
  remove is activity-logged (`staff.person_file_added/removed`,
  `staff.person_image_added/removed`) so it surfaces on the Events tab.
  """

  use PhoenixKitWeb, :live_component
  use Gettext, backend: PhoenixKitStaff.Gettext

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitStaff.{Activity, Attachments}
  alias PhoenixKitStaff.Schemas.Person
  alias PhoenixKitStaff.Web.Helpers
  alias PhoenixKitWeb.Live.Components.MediaSelectorModal

  # ── Updates ────────────────────────────────────────────────────────

  # Modal results delivered via `notify: {__MODULE__, id}`.
  @impl true
  def update(%{media_selected: uuids}, socket) when is_list(uuids) do
    {:ok, socket |> attach_selected(uuids) |> close_picker() |> reload()}
  end

  def update(%{media_selector_closed: true}, socket), do: {:ok, close_picker(socket)}

  def update(assigns, socket) do
    socket = assign(socket, assigns)
    kind = socket.assigns.kind

    {:ok,
     socket
     |> assign_new(:show_picker, fn -> false end)
     |> assign(
       :folder_uuid,
       Attachments.folder_uuid(socket.assigns.person.uuid, kind, Activity.actor_uuid(socket))
     )
     |> assign(:avatar_uuid, Attachments.avatar_uuid(socket.assigns.person))
     |> reload()}
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_picker", _params, socket) do
    case ensure_folder(socket) do
      {:ok, folder_uuid} ->
        {:noreply, assign(socket, folder_uuid: folder_uuid, show_picker: true)}

      {:error, _reason} ->
        {:noreply, put_flash_safe(socket, :error, gettext("Could not prepare the media folder."))}
    end
  end

  def handle_event("close_picker", _params, socket), do: {:noreply, close_picker(socket)}

  # Set one of the person's images as the avatar. The host (PersonShowLive)
  # owns the header avatar, so notify it to reload after the metadata write.
  def handle_event("set_as_avatar", %{"uuid" => uuid}, socket) do
    case Attachments.set_avatar(socket.assigns.person, uuid, PhoenixKitWeb.Actor.uuid(socket)) do
      {:ok, _} ->
        Activity.log("staff.person_avatar_set",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "staff_person",
          resource_uuid: socket.assigns.person.uuid,
          metadata: %{}
        )

        send(self(), {:avatar_changed})

        {:noreply,
         socket
         |> assign(:avatar_uuid, uuid)
         |> put_flash_safe(:info, gettext("Profile photo updated."))}

      {:error, reason} ->
        Helpers.log_operation_error("staff.person_avatar_set", socket,
          reason: reason,
          resource_type: "staff_person",
          resource_uuid: socket.assigns.person.uuid,
          metadata: %{"file_uuid" => uuid}
        )

        {:noreply, put_flash_safe(socket, :error, gettext("Could not set the photo."))}
    end
  end

  def handle_event("remove_file", %{"uuid" => uuid}, socket) do
    if storage_enabled?() do
      case Attachments.detach(uuid, socket.assigns.folder_uuid) do
        :ok ->
          log(socket, "removed", %{"file_uuid" => uuid})
          {:noreply, socket |> maybe_clear_avatar(uuid) |> reload()}

        {:error, reason} ->
          Helpers.log_operation_error("staff.person_#{noun(socket)}_removed", socket,
            reason: reason,
            resource_type: "staff_person",
            resource_uuid: socket.assigns.person.uuid,
            metadata: %{"file_uuid" => uuid}
          )

          {:noreply, put_flash_safe(socket, :error, gettext("Could not remove the file."))}
      end
    else
      {:noreply, reload(socket)}
    end
  end

  # If the removed image was the avatar, clear the pointer so the header
  # doesn't reference a removed file — decided by the row, not this tab's
  # copy, which another session may have outdated — and tell the host when
  # it changed.
  defp maybe_clear_avatar(socket, uuid) do
    case Attachments.clear_avatar(socket.assigns.person, uuid) do
      {:ok, fresh} ->
        avatar = Attachments.avatar_uuid(fresh)
        if avatar != socket.assigns[:avatar_uuid], do: send(self(), {:avatar_changed})
        assign(socket, :avatar_uuid, avatar)

      {:error, _} ->
        socket
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp ensure_folder(socket) do
    Attachments.ensure_folder(
      socket.assigns.person.uuid,
      socket.assigns.kind,
      Activity.actor_uuid(socket)
    )
  end

  # Attach each selected/uploaded file to the folder (uploads are already home
  # there; library-picks get linked). Gated on storage being enabled so a
  # stale client can't act after the module is turned off. Each tab enforces
  # its type here — Images keeps only images, Files keeps only non-images —
  # rejecting (and sweeping out of the folder) anything of the wrong type, so a
  # collection can never hold the other kind. (The picker also restricts image
  # uploads upfront via core's file_type_filter; this is the server-side
  # backstop and the only enforcement for the all-types Files picker.)
  defp attach_selected(socket, []), do: socket

  defp attach_selected(socket, uuids) do
    if storage_enabled?() do
      case ensure_folder(socket) do
        {:ok, folder_uuid} -> do_attach(socket, folder_uuid, uuids)
        {:error, _} -> socket
      end
    else
      socket
    end
  end

  defp do_attach(socket, folder_uuid, uuids) do
    # Don't add media to a trashed person (the soft-delete contract — mirrors
    # the create-path guards on employment/skills). UI-reachable because the
    # tab stays interactive on a trashed profile; this is the backstop.
    if Person.trashed?(socket.assigns.person) do
      put_flash_safe(
        socket,
        :error,
        gettext("This person is in the trash — restore them before adding media.")
      )
    else
      {accepted, rejected} = partition_for_kind(socket.assigns.kind, uuids)

      Enum.each(accepted, &Attachments.attach(&1, folder_uuid))
      # A non-image uploaded via the picker lands in the folder as home; drop it.
      Enum.each(rejected, &Attachments.detach(&1, folder_uuid))

      if accepted != [], do: log(socket, "added", %{"count" => length(accepted)})

      socket
      |> assign(:folder_uuid, folder_uuid)
      |> flash_rejected(rejected)
    end
  end

  defp partition_for_kind(:images, uuids), do: Enum.split_with(uuids, &Attachments.image?/1)

  defp partition_for_kind(:files, uuids),
    do: Enum.split_with(uuids, &(not Attachments.image?(&1)))

  defp partition_for_kind(_kind, uuids), do: {uuids, []}

  defp flash_rejected(socket, []), do: socket

  defp flash_rejected(socket, rejected) do
    put_flash_safe(socket, :error, reject_message(socket.assigns.kind, length(rejected)))
  end

  defp reject_message(:images, count) do
    ngettext(
      "Only images can be added here — skipped %{count} non-image file.",
      "Only images can be added here — skipped %{count} non-image files.",
      count
    )
  end

  defp reject_message(_files, count) do
    ngettext(
      "Images belong in the Images tab — skipped %{count} image.",
      "Images belong in the Images tab — skipped %{count} images.",
      count
    )
  end

  defp close_picker(socket), do: assign(socket, :show_picker, false)

  defp reload(socket) do
    files =
      Attachments.list_files(socket.assigns.folder_uuid, only: only_for(socket.assigns.kind))

    assign(socket, :files, files)
  end

  defp only_for(:images), do: :images
  defp only_for(_files), do: :non_images

  defp log(socket, verb, metadata) do
    Activity.log("staff.person_#{noun(socket)}_#{verb}",
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: "staff_person",
      resource_uuid: socket.assigns.person.uuid,
      metadata: metadata
    )
  end

  defp noun(%{assigns: %{kind: :images}}), do: "image"
  defp noun(_), do: "file"

  defp storage_enabled? do
    Storage.enabled?()
  rescue
    _ -> false
  end

  defp put_flash_safe(socket, kind, msg) do
    send(self(), {:put_flash, kind, msg})
    socket
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-4">
      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <div class="flex items-center justify-between gap-2">
            <h2 class="card-title text-lg">
              <.icon name={if @kind == :images, do: "hero-photo", else: "hero-document"} class="w-5 h-5" />
              {if @kind == :images, do: gettext("Images"), else: gettext("Files")} ({length(@files)})
            </h2>
            <button
              type="button"
              phx-target={@myself}
              phx-click="open_picker"
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-plus" class="w-4 h-4" />
              {if @kind == :images, do: gettext("Add images"), else: gettext("Add files")}
            </button>
          </div>

          <p :if={@files == []} class="text-sm text-base-content/60 py-2">
            {if @kind == :images,
              do: gettext("No images yet."),
              else: gettext("No files yet.")}
          </p>

          <%!-- Images: thumbnail grid --%>
          <div
            :if={@kind == :images and @files != []}
            class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-3"
          >
            <div :for={f <- @files} class="relative group rounded-box overflow-hidden border border-base-300">
              <a href={Attachments.download_url(f)} target="_blank" rel="noopener" class="block aspect-square bg-base-200">
                <img
                  src={Attachments.thumb_url(f)}
                  alt={f.original_file_name || f.file_name}
                  loading="lazy"
                  class="w-full h-full object-cover"
                />
              </a>
              <button
                type="button"
                phx-target={@myself}
                phx-click="remove_file"
                phx-value-uuid={f.uuid}
                phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting…")}
                data-confirm={gettext("Remove this image?")}
                class="btn btn-xs btn-circle btn-error absolute top-1 right-1 opacity-0 group-hover:opacity-100 transition"
                aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
              >
                <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
              </button>
              <%!-- Set as / current avatar --%>
              <button
                type="button"
                phx-target={@myself}
                phx-click="set_as_avatar"
                phx-value-uuid={f.uuid}
                disabled={f.uuid == @avatar_uuid}
                class={[
                  "btn btn-xs btn-circle absolute top-1 left-1 border-0 bg-base-100/80 transition",
                  if(f.uuid == @avatar_uuid,
                    do: "opacity-100 text-warning",
                    else: "opacity-0 group-hover:opacity-100")
                ]}
                title={
                  if(f.uuid == @avatar_uuid,
                    do: gettext("Current profile photo"),
                    else: gettext("Set as profile photo"))
                }
                aria-label={gettext("Set as profile photo")}
              >
                <.icon name="hero-star" class="w-3.5 h-3.5" />
              </button>
              <span
                :if={f.uuid == @avatar_uuid}
                class="badge badge-xs badge-primary absolute bottom-1 left-1"
              >
                {gettext("Avatar")}
              </span>
            </div>
          </div>

          <%!-- Files: list --%>
          <ul :if={@kind == :files and @files != []} class="flex flex-col divide-y divide-base-200">
            <li :for={f <- @files} class="flex items-center gap-3 py-2">
              <.icon name={Attachments.file_icon(f)} class="w-5 h-5 text-base-content/60 shrink-0" />
              <div class="flex-1 min-w-0">
                <a
                  href={Attachments.download_url(f)}
                  target="_blank"
                  rel="noopener"
                  class="link link-hover font-medium block truncate"
                >
                  {f.original_file_name || f.file_name}
                </a>
                <div class="text-xs text-base-content/50">{Attachments.format_file_size(f.size)}</div>
              </div>
              <button
                type="button"
                phx-target={@myself}
                phx-click="remove_file"
                phx-value-uuid={f.uuid}
                phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting…")}
                data-confirm={gettext("Remove this file?")}
                class="btn btn-ghost btn-xs btn-square text-error shrink-0"
                aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </li>
          </ul>
        </div>
      </div>

      <%!-- Core picker: uploads land in / browse is scoped to the folder.
           It owns its own upload channel and notifies results back here. --%>
      <.live_component
        module={MediaSelectorModal}
        id={"#{@id}-selector"}
        show={@show_picker}
        mode={:multiple}
        file_type_filter={if @kind == :images, do: :image, else: :all}
        browse={false}
        selected_uuids={[]}
        scope_folder_id={@folder_uuid}
        phoenix_kit_current_user={@phoenix_kit_current_user}
        notify={{__MODULE__, @id}}
      />
    </div>
    """
  end
end
