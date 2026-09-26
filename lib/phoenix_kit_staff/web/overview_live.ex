defmodule PhoenixKitStaff.Web.OverviewLive do
  @moduledoc "Staff org overview — departments, teams, and people."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  require Logger

  alias PhoenixKitStaff.{Departments, L10n, Paths, Staff, Teams}
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.{Department, Person, Team}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      StaffPubSub.subscribe(StaffPubSub.topic_departments())
      StaffPubSub.subscribe(StaffPubSub.topic_teams())
      StaffPubSub.subscribe(StaffPubSub.topic_people())
    end

    {:ok,
     assign(socket,
       page_title: gettext("Staff"),
       page_subtitle: gettext("Departments, teams, and the people in them.")
     )
     |> reload()}
  end

  defp reload(socket) do
    assign(socket,
      dept_count: Departments.count(),
      team_count: Teams.count(),
      person_count: Staff.count_people(),
      org_tree: Staff.org_tree(),
      upcoming_birthdays: Staff.upcoming_birthdays()
    )
  end

  @impl true
  def handle_info({:staff, _event, _payload}, socket), do: {:noreply, reload(socket)}

  def handle_info(msg, socket) do
    Logger.debug("[Staff] OverviewLive: unexpected handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

  defp person_label(%Person{} = person), do: Person.display_name(person)
  defp person_label(_), do: "—"

  defp person_tooltip(%Person{} = person, lang) do
    case Person.localized_job_title(person, lang) do
      t when is_binary(t) and t != "" -> t
      _ -> nil
    end
  end

  defp person_tooltip(_, _), do: nil

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :lang, L10n.current_content_lang())

    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-6">
      <.admin_page_header>
        <:actions>
          <.link navigate={Paths.new_department()} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Department")}
          </.link>
          <.link navigate={Paths.new_team()} class="btn btn-ghost btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Team")}
          </.link>
          <.link navigate={Paths.new_person()} class="btn btn-ghost btn-sm">
            <.icon name="hero-plus" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Staff")}
          </.link>
        </:actions>
      </.admin_page_header>

      <%!-- Stats --%>
      <div class="grid grid-cols-3 gap-3">
        <.link navigate={Paths.departments()} class="card bg-base-100 shadow-sm border border-base-200 hover:shadow-md transition">
          <div class="card-body p-4">
            <div class="flex items-center gap-2 text-base-content/60 text-xs">
              <.icon name="hero-building-office-2" class="w-4 h-4" /> {gettext("Departments")}
            </div>
            <div class="text-2xl font-bold">{@dept_count}</div>
          </div>
        </.link>
        <.link navigate={Paths.teams()} class="card bg-base-100 shadow-sm border border-base-200 hover:shadow-md transition">
          <div class="card-body p-4">
            <div class="flex items-center gap-2 text-base-content/60 text-xs">
              <.icon name="hero-user-group" class="w-4 h-4" /> {gettext("Teams")}
            </div>
            <div class="text-2xl font-bold">{@team_count}</div>
          </div>
        </.link>
        <.link navigate={Paths.people()} class="card bg-base-100 shadow-sm border border-base-200 hover:shadow-md transition">
          <div class="card-body p-4">
            <div class="flex items-center gap-2 text-base-content/60 text-xs">
              <.icon name="hero-identification" class="w-4 h-4" /> {Gettext.gettext(PhoenixKitWeb.Gettext, "Staff")}
            </div>
            <div class="text-2xl font-bold">{@person_count}</div>
          </div>
        </.link>
      </div>

      <%!-- Upcoming birthdays --%>
      <%= if @upcoming_birthdays != [] do %>
        <div class="card bg-base-100 shadow">
          <div class="card-body py-4">
            <h2 class="card-title text-base">
              <.icon name="hero-cake" class="w-5 h-5 text-primary" /> {gettext("Upcoming birthdays")}
            </h2>
            <div class="flex flex-wrap gap-2 mt-1">
              <.link
                :for={b <- @upcoming_birthdays}
                navigate={Paths.person(b.person.uuid)}
                class={"badge gap-1 py-3 cursor-pointer hover:bg-primary hover:text-primary-content hover:border-primary transition-colors #{if b.days_until == 0, do: "badge-primary", else: "badge-outline"}"}
              >
                <span class="font-medium">{person_label(b.person)}</span>
                <span class="text-xs opacity-70">
                  <%= cond do %>
                    <% b.days_until == 0 -> %>
                      {gettext("🎂 today!")}
                    <% b.days_until == 1 -> %>
                      {gettext("tomorrow")}
                    <% true -> %>
                      {gettext("in %{days}d (%{date})", days: b.days_until, date: L10n.format_month_day(b.next_birthday))}
                  <% end %>
                </span>
              </.link>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Org tree --%>
      <%= if @org_tree.departments == [] do %>
        <.empty_state
          variant="card"
          icon="hero-building-office-2"
          title={gettext("No departments yet.")}
        >
          <:cta>
            <.link navigate={Paths.new_department()} class="link link-primary text-sm">
              {gettext("Create your first department")}
            </.link>
          </:cta>
        </.empty_state>
      <% else %>
        <div class="flex flex-col gap-4">
          <div :for={node <- @org_tree.departments} class="card bg-base-100 shadow">
            <div class="card-body">
              <%!-- Department header --%>
              <div class="flex items-center justify-between">
                <.link navigate={Paths.department(node.department.uuid)} class="flex items-center gap-2 group">
                  <.icon name="hero-building-office-2" class="w-5 h-5 text-primary" />
                  <h2 class="text-lg font-bold group-hover:underline">{Department.localized_name(node.department, @lang)}</h2>
                  <span class="badge badge-ghost badge-sm">
                    {ngettext("1 team", "%{count} teams", length(node.teams))}
                  </span>
                </.link>
                <.table_row_menu id={"dept-tree-menu-#{node.department.uuid}"}>
                  <.table_row_menu_link
                    navigate={Paths.department(node.department.uuid)}
                    icon="hero-eye"
                    label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                  />
                  <.table_row_menu_link
                    navigate={Paths.edit_department(node.department.uuid)}
                    icon="hero-pencil"
                    label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                    variant="secondary"
                  />
                </.table_row_menu>
              </div>
              <p :if={node.department.description} class="text-sm text-base-content/60 mt-1">
                {Department.localized_description(node.department, @lang)}
              </p>

              <%!-- Teams --%>
              <%= if node.teams == [] and node.dept_only_people == [] do %>
                <div class="text-sm text-base-content/50 italic pl-7 pt-2">
                  {gettext("No teams or staff yet.")}
                  <.link navigate={Paths.new_team()} class="link link-primary">{gettext("Add a team")}</.link>.
                </div>
              <% end %>

              <div :for={t <- node.teams} class="pl-6 border-l-2 border-base-200 ml-2 mt-3">
                <div class="flex items-center justify-between">
                  <.link navigate={Paths.team(t.team.uuid)} class="flex items-center gap-2 group">
                    <.icon name="hero-user-group" class="w-4 h-4 text-base-content/60" />
                    <span class="font-medium group-hover:underline">{Team.localized_name(t.team, @lang)}</span>
                    <span class="badge badge-ghost badge-xs">
                      {length(t.people)}
                    </span>
                  </.link>
                  <.table_row_menu id={"team-tree-menu-#{t.team.uuid}"}>
                    <.table_row_menu_link
                      navigate={Paths.team(t.team.uuid)}
                      icon="hero-eye"
                      label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                    />
                    <.table_row_menu_link
                      navigate={Paths.edit_team(t.team.uuid)}
                      icon="hero-pencil"
                      label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                      variant="secondary"
                    />
                  </.table_row_menu>
                </div>

                <%= if t.people == [] do %>
                  <div class="pl-6 text-xs text-base-content/40 italic mt-1">{gettext("No staff on this team.")}</div>
                <% else %>
                  <div class="flex flex-wrap gap-1.5 pl-6 mt-2">
                    <.link
                      :for={m <- t.people}
                      navigate={Paths.person(m.uuid)}
                      title={person_tooltip(m, @lang)}
                      class="badge badge-outline badge-sm gap-1 cursor-pointer hover:bg-primary hover:text-primary-content hover:border-primary transition-colors"
                    >
                      <.icon name="hero-user-circle" class="w-3 h-3" />
                      {person_label(m)}
                    </.link>
                  </div>
                <% end %>
              </div>

              <%!-- Dept-only people (no team) --%>
              <%= if node.dept_only_people != [] do %>
                <div class="pl-6 border-l-2 border-dashed border-base-200 ml-2 mt-3">
                  <div class="flex items-center gap-2 text-xs text-base-content/50 uppercase tracking-wide">
                    <.icon name="hero-user" class="w-3.5 h-3.5" />
                    {gettext("In department, not on any team")}
                  </div>
                  <div class="flex flex-wrap gap-1.5 pl-6 mt-2">
                    <.link
                      :for={m <- node.dept_only_people}
                      navigate={Paths.person(m.uuid)}
                      class="badge badge-ghost badge-sm gap-1 cursor-pointer hover:bg-primary hover:text-primary-content hover:border-primary transition-colors"
                    >
                      <.icon name="hero-user-circle" class="w-3 h-3" />
                      {person_label(m)}
                    </.link>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Unassigned people --%>
          <%= if @org_tree.unassigned_people != [] do %>
            <div class="card bg-base-100 shadow border-dashed border-2 border-base-300">
              <div class="card-body">
                <h2 class="card-title text-base text-base-content/70">
                  <.icon name="hero-question-mark-circle" class="w-5 h-5" />
                  {gettext("Unassigned staff")}
                </h2>
                <p class="text-xs text-base-content/50">
                  {gettext("These staff have no primary department and aren't on any team.")}
                </p>
                <div class="flex flex-wrap gap-1.5 mt-2">
                  <.link
                    :for={m <- @org_tree.unassigned_people}
                    navigate={Paths.person(m.uuid)}
                    class="badge badge-warning badge-sm gap-1 cursor-pointer hover:bg-primary hover:text-primary-content hover:border-primary transition-colors"
                  >
                    <.icon name="hero-user-circle" class="w-3 h-3" />
                    {person_label(m)}
                  </.link>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
