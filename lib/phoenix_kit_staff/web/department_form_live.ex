defmodule PhoenixKitStaff.Web.DepartmentFormLive do
  @moduledoc "Create or edit a department."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKitStaff.{Activity, Departments, L10n, Paths}
  alias PhoenixKitStaff.Schemas.Department
  alias PhoenixKitStaff.Web.Helpers

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> mount_multilang(
       open_on: if(socket.assigns.live_action == :edit, do: :viewing_language, else: :primary)
     )
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    dept = %Department{}

    socket
    |> assign(Helpers.section_assigns())
    |> assign(
      page_crumbs: [%{label: gettext("Departments"), path: Paths.departments()}],
      page_title: gettext("New department"),
      page_subtitle: gettext("Create a new department."),
      dept: dept,
      live_action: :new
    )
    |> assign_form(Departments.change(dept))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Departments.get(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Department not found."))
        |> push_navigate(to: Paths.departments())

      dept ->
        lang = L10n.current_content_lang()

        socket
        |> assign(Helpers.section_assigns())
        |> assign(
          page_crumbs: [
            %{label: gettext("Departments"), path: Paths.departments()},
            %{label: Department.localized_name(dept, lang), path: Paths.department(dept.uuid)}
          ],
          page_title: Gettext.gettext(PhoenixKitWeb.Gettext, "Edit"),
          page_subtitle: gettext("Update department details."),
          dept: dept,
          live_action: :edit
        )
        |> assign_form(Departments.change(dept))
    end
  end

  defp assign_form(socket, changeset), do: assign(socket, form: to_form(changeset))

  @impl true
  def handle_event("switch_language", %{"lang" => lang}, socket) do
    {:noreply, handle_switch_language(socket, lang)}
  end

  def handle_event("validate", %{"department" => attrs}, socket) do
    attrs = merge_attrs(attrs, socket)

    cs =
      socket.assigns.dept
      |> Departments.change(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, cs)}
  end

  def handle_event("save", %{"department" => attrs}, socket) do
    save(socket, socket.assigns.live_action, merge_attrs(attrs, socket))
  end

  # Folds in-flight secondary-tab translations into attrs and
  # preserves primary-tab column values that the current secondary-tab
  # DOM didn't include. Same shape projects uses; see the helper docs
  # for the contract.
  defp merge_attrs(attrs, socket) do
    in_flight = Helpers.in_flight_record(socket, :form, :dept)
    Helpers.merge_translations_attrs(attrs, in_flight, Department.translatable_fields())
  end

  defp save(socket, :new, attrs) do
    case Departments.create(attrs) do
      {:ok, dept} ->
        Activity.log("staff.department_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "department",
          resource_uuid: dept.uuid,
          metadata: %{"name" => dept.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Department created."))
         |> push_navigate(to: Paths.department(dept.uuid))}

      {:error, cs} ->
        Helpers.log_operation_error("staff.department_created", socket,
          reason: cs,
          resource_type: "department",
          metadata: %{"attempted_name" => attrs["name"]}
        )

        {:noreply,
         socket
         |> Helpers.maybe_switch_to_primary_on_error(cs, [:name, :description])
         |> assign_form(cs)}
    end
  end

  defp save(socket, :edit, attrs) do
    case Departments.update(socket.assigns.dept, attrs) do
      {:ok, dept} ->
        Activity.log("staff.department_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "department",
          resource_uuid: dept.uuid,
          metadata: %{"name" => dept.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Department updated."))
         |> push_navigate(to: Paths.department(dept.uuid))}

      {:error, cs} ->
        Helpers.log_operation_error("staff.department_updated", socket,
          reason: cs,
          resource_type: "department",
          resource_uuid: socket.assigns.dept.uuid,
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
      <div class="card bg-base-100 shadow max-w-3xl mx-auto w-full">
        <.multilang_tabs
          multilang_enabled={@multilang_enabled}
          language_tabs={@language_tabs}
          current_lang={@current_lang}
        />

        <.multilang_fields_wrapper
          multilang_enabled={@multilang_enabled}
          current_lang={@current_lang}
        >
          <div class="card-body">
            <.form
              for={@form}
              id="department-form"
              phx-change="validate"
              phx-submit="save"
              phx-debounce="300"
              class="flex flex-col gap-3"
            >
              <.translatable_field
                field_name="name"
                form_prefix="department"
                changeset={@form.source}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={Helpers.lang_data(@form, @current_lang)}
                secondary_name={"department[translations][#{@current_lang}][name]"}
                lang_data_key="name"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}
                required
              />

              <.translatable_field
                field_name="description"
                form_prefix="department"
                changeset={@form.source}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={Helpers.lang_data(@form, @current_lang)}
                secondary_name={"department[translations][#{@current_lang}][description]"}
                lang_data_key="description"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Description")}
                type="textarea"
              />

              <div class="flex justify-end gap-2 mt-2">
                <.link navigate={Paths.departments()} class="btn btn-ghost btn-sm">
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
            </.form>
          </div>
        </.multilang_fields_wrapper>
      </div>
    </div>
    """
  end
end
