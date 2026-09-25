defmodule PhoenixKitStaff.Web.TeamShowLive do
  @moduledoc "Show a team and manage its memberships."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Activity, L10n, Paths, Staff, Teams}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.{Department, Person, Team}
  alias PhoenixKitStaff.Web.Helpers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # Subscribe BEFORE the DB read so a broadcast between fetch and
    # subscribe doesn't get dropped. URL `id` is the UUID; same topic.
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_team(id))

    case Teams.get(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Team not found."))
         |> push_navigate(to: Paths.teams())}

      team ->
        {:ok,
         socket
         |> assign(team_header_assigns(team))
         |> assign(team: team)
         |> load_memberships()}
    end
  end

  # Team name/department/description are all translatable, so the header
  # assigns are derived together and refreshed on every broadcast alongside
  # `team` itself — otherwise a rename via PubSub would leave the breadcrumb
  # title stale.
  defp team_header_assigns(team) do
    lang = L10n.current_content_lang()

    Helpers.section_assigns() ++
      [
        page_crumbs: [%{label: gettext("Teams"), path: Paths.teams()}],
        page_title: Team.localized_name(team, lang),
        page_subtitle: Team.localized_description(team, lang),
        page_action: %{
          icon: "hero-pencil",
          label: Gettext.gettext(PhoenixKitWeb.Gettext, "Edit"),
          navigate: Paths.edit_team(team.uuid)
        }
      ]
  end

  @impl true
  def handle_info({:staff, :team_deleted, _}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, gettext("This team was deleted."))
     |> push_navigate(to: Paths.teams())}
  end

  def handle_info({:staff, _event, _payload}, socket) do
    case Teams.get(socket.assigns.team.uuid) do
      nil ->
        {:noreply, push_navigate(socket, to: Paths.teams())}

      team ->
        {:noreply,
         socket
         |> assign(team_header_assigns(team))
         |> assign(team: team)
         |> load_memberships()}
    end
  end

  def handle_info(msg, socket) do
    Logger.debug("[Staff] TeamShowLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_memberships(socket) do
    team_uuid = socket.assigns.team.uuid

    assign(socket,
      memberships: Staff.list_team_memberships(team_uuid),
      available_people: Staff.people_not_on_team(team_uuid),
      add_form: to_form(%{"staff_person_uuid" => ""})
    )
  end

  @impl true
  def handle_event("add_person", %{"staff_person_uuid" => person_uuid}, socket)
      when person_uuid != "" do
    case Staff.add_team_person(socket.assigns.team.uuid, person_uuid) do
      {:ok, tm} ->
        Activity.log("staff.team_person_added",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "team",
          resource_uuid: socket.assigns.team.uuid,
          target_uuid: person_uuid,
          metadata: %{"team_membership_uuid" => tm.uuid}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Staff added."))
         |> load_memberships()}

      {:error, reason} ->
        Helpers.log_operation_error("staff.team_person_added", socket,
          reason: reason,
          resource_type: "team",
          resource_uuid: socket.assigns.team.uuid,
          target_uuid: person_uuid
        )

        {:noreply, put_flash(socket, :error, gettext("Could not add staff."))}
    end
  end

  def handle_event("add_person", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Pick someone first."))}
  end

  def handle_event("remove_person", %{"uuid" => tm_uuid}, socket) do
    case Enum.find(socket.assigns.memberships, &(&1.uuid == tm_uuid)) do
      nil ->
        {:noreply, socket}

      tm ->
        case Staff.remove_team_person(tm) do
          {:ok, _} ->
            Activity.log("staff.team_person_removed",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "team",
              resource_uuid: socket.assigns.team.uuid,
              target_uuid: tm.staff_person_uuid,
              metadata: %{}
            )

            {:noreply, load_memberships(socket) |> put_flash(:info, gettext("Staff removed."))}

          {:error, reason} ->
            Helpers.log_operation_error("staff.team_person_removed", socket,
              reason: reason,
              resource_type: "team",
              resource_uuid: socket.assigns.team.uuid,
              target_uuid: tm.staff_person_uuid
            )

            {:noreply, put_flash(socket, :error, gettext("Could not remove staff from team."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :lang, L10n.current_content_lang())

    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <%!-- The department is not a level of this page's URL, so it is not a
           crumb (the trail is Staff / Teams / <team>); it is shown here. --%>
      <p class="text-sm text-base-content/70">
        {gettext("Department")}:
        <.link navigate={Paths.department(@team.department.uuid)} class="link link-primary">
          {Department.localized_name(@team.department, @lang)}
        </.link>
      </p>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-lg">{gettext("Add staff")}</h2>
          <%= if @available_people == [] do %>
            <p class="text-sm text-base-content/60">
              {gettext("Everyone is already on this team (or there are no staff yet —")} <.link navigate={Paths.new_person()} class="link link-primary">{gettext("create one")}</.link>).
            </p>
          <% else %>
            <.form for={@add_form} phx-submit="add_person" class="flex flex-wrap gap-2 items-end">
              <.select
                field={@add_form[:staff_person_uuid]}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Staff")}
                options={Enum.map(@available_people, &{person_label(&1), &1.uuid})}
                prompt={gettext("Select staff")}
              />
              <button type="submit" phx-disable-with={gettext("Adding…")} class="btn btn-primary btn-sm">
                <.icon name="hero-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Add")}
              </button>
            </.form>
          <% end %>
        </div>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <h2 class="card-title text-lg">{Gettext.gettext(PhoenixKitWeb.Gettext, "Staff")} ({length(@memberships)})</h2>
          <%= if @memberships == [] do %>
            <.empty_state
              icon="hero-identification"
              title={gettext("No staff on this team yet.")}
              class="py-6"
            />
          <% else %>
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>{Gettext.gettext(PhoenixKitWeb.Gettext, "Staff")}</th>
                  <th class="text-right w-px whitespace-nowrap">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={tm <- @memberships}>
                  <td>
                    <.link navigate={Paths.person(tm.staff_person.uuid)} class="link link-hover">
                      {person_label(tm.staff_person)}
                    </.link>
                  </td>
                  <td class="text-right w-px whitespace-nowrap">
                    <.table_row_menu id={"membership-menu-#{tm.uuid}"}>
                      <.table_row_menu_link
                        navigate={Paths.person(tm.staff_person.uuid)}
                        icon="hero-eye"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="remove_person"
                        phx-value-uuid={tm.uuid}
                        phx-disable-with={gettext("Removing…")}
                        data-confirm={gettext("Remove this staff from the team?")}
                        icon="hero-x-mark"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
                        variant="error"
                      />
                    </.table_row_menu>
                  </td>
                </tr>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp person_label(%Person{} = person), do: Person.display_name(person)
  defp person_label(_), do: "—"
end
