defmodule PhoenixKitStaff.Web.TeamsLive do
  @moduledoc "List teams across all departments."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Activity, L10n, Paths, Teams}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.{Department, Team}
  alias PhoenixKitStaff.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_teams())

    {:ok,
     socket
     |> assign(Helpers.section_assigns())
     |> assign(
       page_title: gettext("Teams"),
       page_subtitle: gettext("Teams across all departments."),
       page_action: %{
         icon: "hero-plus",
         label: gettext("New team"),
         navigate: Paths.new_team()
       }
     )
     |> load_teams()}
  end

  defp load_teams(socket), do: assign(socket, teams: Teams.list())

  @impl true
  def handle_info({:staff, _event, _payload}, socket) do
    {:noreply, load_teams(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[Staff] TeamsLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Teams.get(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Team not found."))}

      team ->
        case Teams.delete(team) do
          {:ok, _} ->
            Activity.log("staff.team_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "team",
              resource_uuid: team.uuid,
              metadata: %{"name" => team.name}
            )

            {:noreply,
             socket
             |> put_flash(:info, gettext("Team deleted."))
             |> load_teams()}

          {:error, reason} ->
            Helpers.log_operation_error("staff.team_deleted", socket,
              reason: reason,
              resource_type: "team",
              resource_uuid: team.uuid,
              metadata: %{"name" => team.name}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not delete team."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :lang, L10n.current_content_lang())

    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <%= if @teams == [] do %>
        <.empty_state icon="hero-user-group" title={gettext("No teams yet.")}>
          <:cta>
            <.link navigate={Paths.new_team()} class="link link-primary text-sm">
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
                  <th>{gettext("Department")}</th>
                  <th class="text-right w-px whitespace-nowrap">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={team <- @teams} class="hover">
                  <td>
                    <.link navigate={Paths.team(team.uuid)} class="link link-hover font-medium">
                      {Team.localized_name(team, @lang)}
                    </.link>
                  </td>
                  <td>
                    <.link navigate={Paths.department(team.department.uuid)} class="text-sm">
                      {Department.localized_name(team.department, @lang)}
                    </.link>
                  </td>
                  <td class="text-right w-px whitespace-nowrap">
                    <.table_row_menu id={"team-menu-#{team.uuid}"}>
                      <.table_row_menu_link
                        navigate={Paths.team(team.uuid)}
                        icon="hero-eye"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                      />
                      <.table_row_menu_link
                        navigate={Paths.edit_team(team.uuid)}
                        icon="hero-pencil"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                        variant="secondary"
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="delete"
                        phx-value-uuid={team.uuid}
                        phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting…")}
                        data-confirm={gettext("Delete team %{name}? This removes all memberships.", name: Team.localized_name(team, @lang))}
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
