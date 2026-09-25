defmodule PhoenixKitStaff.Web.SkillsLive do
  @moduledoc "List skills."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Activity, L10n, Paths, Skills}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Skill
  alias PhoenixKitStaff.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: StaffPubSub.subscribe(StaffPubSub.topic_skills())

    {:ok,
     socket
     |> assign(Helpers.section_assigns())
     |> assign(
       page_title: gettext("Skills"),
       page_subtitle: gettext("Skills you can assign to staff."),
       page_action: %{
         icon: "hero-plus",
         label: gettext("New skill"),
         navigate: Paths.new_skill()
       }
     )
     |> load_skills()}
  end

  defp load_skills(socket) do
    assign(socket, skills: Skills.list(), person_counts: Skills.person_counts())
  end

  @impl true
  def handle_info({:staff, _event, _payload}, socket) do
    {:noreply, load_skills(socket)}
  end

  def handle_info(msg, socket) do
    Logger.debug("[Staff] SkillsLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    case Skills.get(uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Skill not found."))}

      skill ->
        case Skills.delete(skill) do
          {:ok, _} ->
            Activity.log("staff.skill_deleted",
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "skill",
              resource_uuid: skill.uuid,
              metadata: %{"name" => skill.name}
            )

            {:noreply, socket |> put_flash(:info, gettext("Skill deleted.")) |> load_skills()}

          {:error, reason} ->
            Helpers.log_operation_error("staff.skill_deleted", socket,
              reason: reason,
              resource_type: "skill",
              resource_uuid: skill.uuid,
              metadata: %{"name" => skill.name}
            )

            {:noreply, put_flash(socket, :error, gettext("Could not delete skill."))}
        end
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :lang, L10n.current_content_lang())

    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <%= if @skills == [] do %>
        <.empty_state icon="hero-academic-cap" title={gettext("No skills yet.")}>
          <:cta>
            <.link navigate={Paths.new_skill()} class="link link-primary text-sm">
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
                  <th>{gettext("People")}</th>
                  <th class="text-right w-px whitespace-nowrap">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={skill <- @skills} class="hover">
                  <td>
                    <.link navigate={Paths.skill(skill.uuid)} class="link link-hover font-medium">
                      {Skill.localized_name(skill, @lang)}
                    </.link>
                  </td>
                  <td>{Map.get(@person_counts, skill.uuid, 0)}</td>
                  <td class="text-right w-px whitespace-nowrap">
                    <.table_row_menu id={"skill-menu-#{skill.uuid}"}>
                      <.table_row_menu_link
                        navigate={Paths.skill(skill.uuid)}
                        icon="hero-eye"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                      />
                      <.table_row_menu_link
                        navigate={Paths.edit_skill(skill.uuid)}
                        icon="hero-pencil"
                        label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                        variant="secondary"
                      />
                      <.table_row_menu_divider />
                      <.table_row_menu_button
                        phx-click="delete"
                        phx-value-uuid={skill.uuid}
                        phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Deleting…")}
                        data-confirm={
                          gettext("Delete skill %{name}? It will be removed from %{count} people.",
                            name: Skill.localized_name(skill, @lang),
                            count: Map.get(@person_counts, skill.uuid, 0)
                          )
                        }
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
