defmodule PhoenixKitStaff.Web.TeamFormLive do
  @moduledoc "Create or edit a team."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKitStaff.{Activity, Departments, Paths, Teams}
  alias PhoenixKitStaff.Schemas.Team
  alias PhoenixKitStaff.Web.Helpers

  @impl true
  def mount(params, _session, socket) do
    departments = Departments.list()

    socket =
      socket
      |> mount_multilang(
        open_on: if(socket.assigns.live_action == :edit, do: :viewing_language, else: :primary)
      )
      |> assign(dept_options: Enum.map(departments, &{&1.name, &1.uuid}))
      |> apply_action(socket.assigns.live_action, params)

    {:ok, socket}
  end

  defp apply_action(socket, :new, _params) do
    team = %Team{}

    socket
    |> assign(
      page_title: gettext("New team"),
      page_subtitle: gettext("Create a new team within a department."),
      team: team,
      live_action: :new
    )
    |> assign_form(Teams.change(team))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Teams.get(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Team not found."))
        |> push_navigate(to: Paths.teams())

      team ->
        socket
        |> assign(
          page_title: gettext("Edit %{name}", name: team.name),
          page_subtitle: gettext("Update team details."),
          team: team,
          live_action: :edit
        )
        |> assign_form(Teams.change(team))
    end
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
  def handle_event("switch_language", %{"lang" => lang}, socket) do
    {:noreply, handle_switch_language(socket, lang)}
  end

  def handle_event("validate", %{"team" => attrs}, socket) do
    attrs = merge_attrs(attrs, socket)

    cs =
      socket.assigns.team
      |> Teams.change(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, cs)}
  end

  def handle_event("save", %{"team" => attrs}, socket) do
    save(socket, socket.assigns.live_action, merge_attrs(attrs, socket))
  end

  defp merge_attrs(attrs, socket) do
    in_flight = Helpers.in_flight_record(socket, :form, :team)
    Helpers.merge_translations_attrs(attrs, in_flight, Team.translatable_fields())
  end

  defp save(socket, :new, attrs) do
    case Teams.create(attrs) do
      {:ok, team} ->
        Activity.log("staff.team_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "team",
          resource_uuid: team.uuid,
          metadata: %{"name" => team.name, "department_uuid" => team.department_uuid}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Team created."))
         |> push_navigate(to: Paths.team(team.uuid))}

      {:error, cs} ->
        Helpers.log_operation_error("staff.team_created", socket,
          reason: cs,
          resource_type: "team",
          metadata: %{
            "attempted_name" => attrs["name"],
            "department_uuid" => attrs["department_uuid"]
          }
        )

        {:noreply,
         socket
         |> Helpers.maybe_switch_to_primary_on_error(cs, [:name, :description])
         |> assign_form(cs)}
    end
  end

  defp save(socket, :edit, attrs) do
    case Teams.update(socket.assigns.team, attrs) do
      {:ok, team} ->
        Activity.log("staff.team_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "team",
          resource_uuid: team.uuid,
          metadata: %{"name" => team.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Team updated."))
         |> push_navigate(to: Paths.team(team.uuid))}

      {:error, cs} ->
        Helpers.log_operation_error("staff.team_updated", socket,
          reason: cs,
          resource_type: "team",
          resource_uuid: socket.assigns.team.uuid,
          metadata: %{"attempted_name" => attrs["name"]}
        )

        {:noreply,
         socket
         |> Helpers.maybe_switch_to_primary_on_error(cs, [:name, :description])
         |> assign_form(cs)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <%= if @dept_options == [] do %>
        <div class="alert alert-warning max-w-3xl mx-auto w-full">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>
            {gettext("You need at least one department first.")}
            <.link navigate={Paths.new_department()} class="link">{gettext("Create one")}</.link>.
          </span>
        </div>
      <% else %>
        <div class="card bg-base-100 shadow max-w-3xl mx-auto w-full">
          <.form
            for={@form}
            id="team-form"
            phx-change="validate"
            phx-submit="save"
            phx-debounce="300"
          >
            <%!-- Department picker is NOT translatable — stays
                 outside the multilang_fields_wrapper so it doesn't
                 re-mount on language switch and lose unsaved state. --%>
            <div class="card-body pb-0">
              <.select
                field={@form[:department_uuid]}
                label={gettext("Department")}
                options={@dept_options}
                prompt={gettext("Select department")}
                required
              />
            </div>

            <.multilang_tabs
              multilang_enabled={@multilang_enabled}
              language_tabs={@language_tabs}
              current_lang={@current_lang}
            />

            <.multilang_fields_wrapper
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
            >
              <div class="card-body pt-3 flex flex-col gap-3">
                <.translatable_field
                  field_name="name"
                  form_prefix="team"
                  changeset={@form.source}
                  schema_field={:name}
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                  primary_language={@primary_language}
                  lang_data={Helpers.lang_data(@form, @current_lang)}
                  secondary_name={"team[translations][#{@current_lang}][name]"}
                  lang_data_key="name"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}
                  required
                />

                <.translatable_field
                  field_name="description"
                  form_prefix="team"
                  changeset={@form.source}
                  schema_field={:description}
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                  primary_language={@primary_language}
                  lang_data={Helpers.lang_data(@form, @current_lang)}
                  secondary_name={"team[translations][#{@current_lang}][description]"}
                  lang_data_key="description"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Description")}
                  type="textarea"
                />
              </div>
            </.multilang_fields_wrapper>

            <div class="card-body pt-0">
              <div class="flex justify-end gap-2 mt-2">
                <.link navigate={Paths.teams()} class="btn btn-ghost btn-sm">
                  {Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}
                </.link>
                <button
                  type="submit"
                  phx-disable-with={Gettext.gettext(PhoenixKitWeb.Gettext, "Saving…")}
                  class="btn btn-primary btn-sm"
                >
                  <%= if @live_action == :new, do: gettext("Create"), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Save") %>
                </button>
              </div>
            </div>
          </.form>
        </div>
      <% end %>
    </div>
    """
  end
end
