defmodule PhoenixKitStaff.Web.DepartmentsLive do
  @moduledoc "List departments."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Activity, Departments, L10n, Paths}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Department
  alias PhoenixKitStaff.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_departments())

    {:ok,
     socket
     |> assign(Helpers.section_assigns())
     |> assign(
       page_title: gettext("Departments"),
       page_subtitle: gettext("Top-level organizational units."),
       page_action: %{
         icon: "hero-plus",
         label: gettext("New department"),
         navigate: Paths.new_department()
       }
     )
     |> load_departments()}
  end

  defp load_departments(socket) do
    assign(socket, departments: Departments.list(preload: [:teams]))
  end

  @impl true
  def handle_info({:staff, _event, _payload}, socket) do
    {:noreply, load_departments(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[Staff] DepartmentsLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Departments.get(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Department not found."))}

      dept ->
        case Departments.delete(dept) do
          {:ok, _} ->
            Activity.log("staff.department_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "department",
              resource_uuid: dept.uuid,
              metadata: %{"name" => dept.name}
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Department deleted."))
             |> load_departments()}

          {:error, reason} ->
            Helpers.log_operation_error("staff.department_deleted", socket,
              reason: reason,
              resource_type: "department",
              resource_uuid: dept.uuid,
              metadata: %{"name" => dept.name}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not delete department."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :lang, L10n.current_content_lang())

    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <%= if @departments == [] do %>
        <.empty_state icon="hero-building-office-2" title={gettext("No departments yet.")}>
          <:cta>
            <.link navigate={Paths.new_department()} class="link link-primary text-sm">
              {gettext("Create your first")}
            </.link>
          </:cta>
        </.empty_state>
      <% else %>
        <div class="card bg-base-100 shadow">
          <div class="card-body p-0">
            <table class="table">
              <thead>
                <tr>
                  <th>{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}</th>
                  <th>{gettext("Teams")}</th>
                  <th class="text-right w-px whitespace-nowrap">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={dept <- @departments} class="hover">
                  <td>
                    <.link navigate={Paths.department(dept.uuid)} class="link link-hover font-medium">
                      {Department.localized_name(dept, @lang)}
                    </.link>
                    <div :if={dept.description} class="text-xs text-base-content/60 truncate max-w-md">
                      {Department.localized_description(dept, @lang)}
                    </div>
                  </td>
                  <td>{length(dept.teams)}</td>
                  <td class="text-right w-px whitespace-nowrap">
                    <.table_row_menu id={"dept-menu-#{dept.uuid}"}>
                      <.table_row_menu_link
                        navigate={Paths.department(dept.uuid)}
                        icon="hero-eye"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                      />
                      <.table_row_menu_link
                        navigate={Paths.edit_department(dept.uuid)}
                        icon="hero-pencil"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                        variant="secondary"
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="delete"
                        phx-value-uuid={dept.uuid}
                        phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting…")}
                        data-confirm={gettext("Delete department %{name}? This will also delete its teams and memberships.", name: Department.localized_name(dept, @lang))}
                        icon="hero-trash"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
                        variant="error"
                      />
                    </.table_row_menu>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
