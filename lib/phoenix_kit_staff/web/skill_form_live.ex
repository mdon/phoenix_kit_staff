defmodule PhoenixKitStaff.Web.SkillFormLive do
  @moduledoc """
  Create or edit a skill, including its level **selectors**.

  A skill owns zero or more named selectors (level groups); each selector has a
  translatable name, its own `allow_multiple` toggle, and an ordered list of
  translatable options. The whole selector tree is **staged in `@staged_groups`**
  (the source of truth) and rendered inside `#skill-form` but **outside**
  `<.multilang_fields_wrapper>`, so it survives language switches (the wrapper
  re-mounts its subtree on switch).

  Each selector/option **name input** is keyed on `@current_lang` in its DOM id,
  so morphdom replaces it on a language switch and the value refreshes to the
  active language; `validate` merges only the active language's typed names back
  into the staged tree. Structural edits (add / remove / reorder selectors and
  options) are event-driven so a reconnect can't strand them, and reordering
  uses the core `<.draggable_list>` drag-and-drop (handle = `.pk-drag-handle`).
  On save the staged tree is injected as `attrs["levels"]` and normalised by
  `Skill.changeset/2`.
  """

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitStaff.Gettext

  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKitStaff.{Activity, L10n, Paths, Skills}
  alias PhoenixKitStaff.Schemas.Skill
  alias PhoenixKitStaff.Web.Helpers

  # Options seeded by "Add standard levels" (et/ru pre-filled, editable after).
  @standard_options [
    {"Beginner", %{"et" => "Algaja", "ru" => "Начинающий"}},
    {"Intermediate", %{"et" => "Kesktase", "ru" => "Средний"}},
    {"Advanced", %{"et" => "Edasijõudnu", "ru" => "Продвинутый"}},
    {"Expert", %{"et" => "Ekspert", "ru" => "Эксперт"}}
  ]

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> mount_multilang(
        open_on: if(socket.assigns.live_action == :edit, do: :viewing_language, else: :primary)
      )
      |> apply_action(socket.assigns.live_action, params)

    {:ok, socket}
  end

  defp apply_action(socket, :new, _params) do
    skill = %Skill{}

    socket
    |> assign(Helpers.section_assigns())
    |> assign(
      page_crumbs: [%{label: gettext("Skills"), path: Paths.skills()}],
      page_title: gettext("New skill"),
      page_subtitle: gettext("Create a new skill."),
      skill: skill,
      live_action: :new,
      staged_groups: []
    )
    |> assign_form(Skills.change(skill))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Skills.get(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Skill not found."))
        |> push_navigate(to: Paths.skills())

      skill ->
        lang = L10n.current_content_lang()

        socket
        |> assign(Helpers.section_assigns())
        |> assign(
          page_crumbs: [
            %{label: gettext("Skills"), path: Paths.skills()},
            %{label: Skill.localized_name(skill, lang), path: Paths.skill(skill.uuid)}
          ],
          page_title: Gettext.gettext(PhoenixKitWeb.Gettext, "Edit"),
          page_subtitle: gettext("Update skill details."),
          skill: skill,
          live_action: :edit,
          staged_groups: Skill.level_groups(skill)
        )
        |> assign_form(Skills.change(skill))
    end
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("switch_language", %{"lang" => lang}, socket) do
    {:noreply, handle_switch_language(socket, lang)}
  end

  def handle_event("validate", %{"skill" => attrs} = params, socket) do
    groups = merge_names(socket.assigns.staged_groups, params, socket)

    cs =
      socket.assigns.skill
      |> Skills.change(build_attrs(attrs, socket, groups))
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign(:staged_groups, groups) |> assign_form(cs)}
  end

  def handle_event("save", %{"skill" => attrs} = params, socket) do
    groups = merge_names(socket.assigns.staged_groups, params, socket)
    socket = assign(socket, :staged_groups, groups)
    save(socket, socket.assigns.live_action, build_attrs(attrs, socket, groups))
  end

  def handle_event("add_selector", _params, socket) do
    {:noreply, put_groups(socket, &(&1 ++ [new_selector()]))}
  end

  def handle_event("seed_standard_levels", _params, socket) do
    {:noreply, put_groups(socket, &(&1 ++ [seed_proficiency_selector()]))}
  end

  def handle_event("remove_selector", %{"group-id" => gid}, socket) do
    {:noreply, put_groups(socket, fn gs -> Enum.reject(gs, &(&1["id"] == gid)) end)}
  end

  def handle_event("toggle_selector_multiple", %{"group-id" => gid}, socket) do
    {:noreply,
     put_groups(socket, fn gs ->
       map_group(gs, gid, fn g -> Map.put(g, "allow_multiple", !Map.get(g, "allow_multiple")) end)
     end)}
  end

  def handle_event("add_option", %{"group-id" => gid}, socket) do
    {:noreply,
     put_groups(socket, fn gs ->
       map_group(gs, gid, fn g ->
         Map.update(g, "options", [new_option()], &(&1 ++ [new_option()]))
       end)
     end)}
  end

  def handle_event("remove_option", %{"group-id" => gid, "option-id" => oid}, socket) do
    {:noreply,
     put_groups(socket, fn gs ->
       map_group(gs, gid, fn g ->
         Map.update(g, "options", [], fn opts -> Enum.reject(opts, &(&1["id"] == oid)) end)
       end)
     end)}
  end

  def handle_event("reorder_selectors", %{"ordered_ids" => ids}, socket) when is_list(ids) do
    {:noreply, put_groups(socket, &reorder_by_id(&1, ids))}
  end

  # The reorder payload carries only this selector's option ids; locate the
  # owning selector by its option-id set (option ids are unique within a skill).
  def handle_event("reorder_options", %{"ordered_ids" => ids}, socket) when is_list(ids) do
    {:noreply,
     put_groups(socket, fn gs ->
       Enum.map(gs, fn g ->
         opt_ids = Enum.map(g["options"] || [], & &1["id"])

         if opt_ids != [] and MapSet.new(opt_ids) == MapSet.new(ids) do
           Map.put(g, "options", reorder_by_id(g["options"], ids))
         else
           g
         end
       end)
     end)}
  end

  # ── Staging helpers ────────────────────────────────────────────────

  defp put_groups(socket, fun),
    do: assign(socket, :staged_groups, fun.(socket.assigns.staged_groups))

  defp map_group(groups, gid, fun),
    do: Enum.map(groups, fn g -> if g["id"] == gid, do: fun.(g), else: g end)

  # Reorder a list of `%{"id" => ...}` maps to match `ordered_ids`; anything not
  # named is appended (defensive — keeps unknown rows rather than dropping them).
  defp reorder_by_id(list, ordered_ids) do
    by_id = Map.new(list, &{&1["id"], &1})
    ordered = ordered_ids |> Enum.map(&Map.get(by_id, &1)) |> Enum.reject(&is_nil/1)
    remaining = Enum.reject(list, &(&1["id"] in ordered_ids))
    ordered ++ remaining
  end

  defp new_selector,
    do: %{
      "id" => Skill.gen_level_id(),
      "name" => "",
      "translations" => %{},
      "allow_multiple" => false,
      "options" => []
    }

  defp new_option, do: %{"id" => Skill.gen_level_id(), "name" => "", "translations" => %{}}

  defp seed_proficiency_selector do
    %{
      "id" => Skill.gen_level_id(),
      "name" => "Proficiency",
      "translations" => %{"et" => "Oskustase", "ru" => "Уровень владения"},
      "allow_multiple" => false,
      "options" =>
        Enum.map(@standard_options, fn {name, translations} ->
          %{"id" => Skill.gen_level_id(), "name" => name, "translations" => translations}
        end)
    }
  end

  # Inject the staged selectors into the skill attrs (the editor is the source
  # of truth, not a `skill[...]` form field) and fold in-flight translations.
  defp build_attrs(attrs, socket, groups) do
    attrs
    |> merge_attrs(socket)
    |> Map.put("levels", groups)
  end

  defp merge_attrs(attrs, socket) do
    in_flight = Helpers.in_flight_record(socket, :form, :skill)
    Helpers.merge_translations_attrs(attrs, in_flight, Skill.translatable_fields())
  end

  # Merge the active language's typed selector/option names back into the staged
  # tree. Only keys present in params are touched (other languages' names stay
  # held in the staged tree, untouched).
  defp merge_names(groups, params, socket) do
    lang = socket.assigns.current_lang
    primary? = lang == socket.assigns.primary_language
    group_params = Map.get(params, "group", %{})
    option_params = Map.get(params, "option", %{})

    Enum.map(groups, fn g ->
      g
      |> merge_one_name(Map.get(group_params, g["id"]), lang, primary?)
      |> Map.update("options", [], fn opts ->
        Enum.map(opts, &merge_one_name(&1, Map.get(option_params, &1["id"]), lang, primary?))
      end)
    end)
  end

  defp merge_one_name(map, %{"name" => typed}, lang, primary?) when is_binary(typed),
    do: put_name(map, typed, lang, primary?)

  defp merge_one_name(map, _other, _lang, _primary?), do: map

  defp put_name(map, typed, _lang, true), do: Map.put(map, "name", typed)

  defp put_name(map, typed, lang, false) do
    translations =
      map
      |> Map.get("translations", %{})
      |> then(fn t ->
        if String.trim(typed) == "", do: Map.delete(t, lang), else: Map.put(t, lang, typed)
      end)

    Map.put(map, "translations", translations)
  end

  # The name input value for the active language: the primary `name` on the
  # primary tab, else the `translations[lang]` override. (`map` is a selector or
  # an option map — both carry `name` + `translations`.)
  defp name_value(map, lang, lang), do: Map.get(map, "name", "")

  defp name_value(map, lang, _primary),
    do: map |> Map.get("translations", %{}) |> Map.get(lang, "")

  # ── Save ───────────────────────────────────────────────────────────

  defp save(socket, :new, attrs) do
    case Skills.create(attrs) do
      {:ok, skill} ->
        Activity.log("staff.skill_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "skill",
          resource_uuid: skill.uuid,
          metadata: %{"name" => skill.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Skill created."))
         |> push_navigate(to: Paths.skill(skill.uuid))}

      {:error, cs} ->
        Helpers.log_operation_error("staff.skill_created", socket,
          reason: cs,
          resource_type: "skill",
          metadata: %{"attempted_name" => attrs["name"]}
        )

        {:noreply,
         socket
         |> Helpers.maybe_switch_to_primary_on_error(cs, [:name, :description])
         |> assign_form(cs)}
    end
  end

  defp save(socket, :edit, attrs) do
    case Skills.update(socket.assigns.skill, attrs) do
      {:ok, skill} ->
        Activity.log("staff.skill_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "skill",
          resource_uuid: skill.uuid,
          metadata: %{"name" => skill.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Skill updated."))
         |> push_navigate(to: Paths.skill(skill.uuid))}

      {:error, cs} ->
        Helpers.log_operation_error("staff.skill_updated", socket,
          reason: cs,
          resource_type: "skill",
          resource_uuid: socket.assigns.skill.uuid,
          metadata: %{"attempted_name" => attrs["name"]}
        )

        {:noreply,
         socket
         |> Helpers.maybe_switch_to_primary_on_error(cs, [:name, :description])
         |> assign_form(cs)}
    end
  end

  # ── Render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-4">
      <div class="card bg-base-100 shadow max-w-3xl mx-auto w-full">
        <.form for={@form} id="skill-form" phx-change="validate" phx-submit="save" phx-debounce="300">
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
          />

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
          >
            <div class="card-body flex flex-col gap-3">
              <.translatable_field
                field_name="name"
                form_prefix="skill"
                changeset={@form.source}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={Helpers.lang_data(@form, @current_lang)}
                secondary_name={"skill[translations][#{@current_lang}][name]"}
                lang_data_key="name"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}
                required
              />

              <.translatable_field
                field_name="description"
                form_prefix="skill"
                changeset={@form.source}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={Helpers.lang_data(@form, @current_lang)}
                secondary_name={"skill[translations][#{@current_lang}][description]"}
                lang_data_key="description"
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Description")}
                type="textarea"
              />
            </div>
          </.multilang_fields_wrapper>

          <%!-- Selectors editor — inside the form, OUTSIDE the multilang wrapper
               (structure is shared across languages; only selector/option names
               are translatable, edited for the active language). --%>
          <div class="card-body pt-4 flex flex-col gap-4">
            <label class="label p-0">
              <span class="fieldset-legend font-semibold">
                {gettext("Level selectors")}
                <span class="fieldset-label text-base-content/50 font-normal">{gettext("optional")}</span>
              </span>
            </label>

            <%!-- Skeleton shown instantly on language switch (the switcher's JS
                 toggles all `[data-translatable=skeletons]`/`[=fields]`); the
                 lang-keyed ids make morphdom reset both after the debounced swap.
                 Distinct id prefix avoids colliding with the name/desc wrapper. --%>
            <div
              :if={@multilang_enabled}
              id={"selector-skeletons-#{@current_lang}"}
              data-translatable="skeletons"
              class="hidden"
              aria-hidden="true"
            >
              <%!-- Mirrors the live structure: one card per selector, one bar
                   per option inside it, so the placeholder matches what's there. --%>
              <div class="flex flex-col gap-3">
                <div
                  :for={group <- @staged_groups}
                  class="border border-base-300 rounded-box p-3 flex flex-col gap-2"
                >
                  <div class="bg-base-content/15 rounded h-8 w-full animate-pulse"></div>
                  <div :if={group["options"] != []} class="pl-6 flex flex-col gap-2">
                    <div
                      :for={_opt <- group["options"]}
                      class="bg-base-content/15 rounded h-7 w-full animate-pulse"
                    >
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div
              id={if @multilang_enabled, do: "selector-fields-#{@current_lang}", else: "selector-fields"}
              data-translatable="fields"
              class="flex flex-col gap-4"
            >
              <p :if={@staged_groups == []} class="text-sm text-base-content/60">
                {gettext("No selectors — this skill is assigned with no level. Add a selector (e.g. Proficiency, Difficulty), or leave empty.")}
              </p>

              <.draggable_list
                :if={@staged_groups != []}
                id="skill-selectors"
              items={@staged_groups}
              item_id={&Map.get(&1, "id")}
              on_reorder="reorder_selectors"
              layout={:list}
              gap="gap-3"
              draggable={length(@staged_groups) > 1}
              sortable_handle=".pk-drag-handle"
              item_class="border border-base-300 rounded-box p-3 bg-base-100"
            >
              <:item :let={group}>
                <div class="flex flex-col gap-3">
                  <div class="flex items-center gap-2">
                    <span class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/30 shrink-0" aria-label={gettext("Drag to reorder")}>
                      <.icon name="hero-bars-3" class="w-4 h-4" />
                    </span>
                    <input
                      type="text"
                      id={"selector-#{group["id"]}-name-#{@current_lang}"}
                      name={"group[#{group["id"]}][name]"}
                      value={name_value(group, @current_lang, @primary_language)}
                      placeholder={
                        if @current_lang == @primary_language,
                          do: gettext("Selector name (e.g. Proficiency)"),
                          else: blank_to(Map.get(group, "name"), gettext("Selector name"))
                      }
                      autocomplete="off"
                      class="input input-sm font-medium w-full"
                    />
                    <button
                      type="button"
                      phx-click="toggle_selector_multiple"
                      phx-value-group-id={group["id"]}
                      class={["btn btn-xs shrink-0", if(group["allow_multiple"], do: "btn-primary", else: "btn-ghost")]}
                      title={gettext("On: multiple options can be selected at once. Off: a single option.")}
                    >
                      {if group["allow_multiple"], do: gettext("Multiple"), else: gettext("Single")}
                    </button>
                    <button
                      type="button"
                      phx-click="remove_selector"
                      phx-value-group-id={group["id"]}
                      class="btn btn-ghost btn-xs btn-square text-error shrink-0"
                      aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>

                  <div class="pl-6 flex flex-col gap-2">
                    <.draggable_list
                      :if={group["options"] != []}
                      id={"selector-#{group["id"]}-options"}
                      items={group["options"]}
                      item_id={&Map.get(&1, "id")}
                      on_reorder="reorder_options"
                      layout={:list}
                      gap="gap-2"
                      draggable={length(group["options"]) > 1}
                      sortable_handle=".pk-drag-handle"
                      item_class="flex items-center gap-2"
                    >
                      <:item :let={option}>
                        <span class="pk-drag-handle cursor-grab active:cursor-grabbing text-base-content/30 shrink-0" aria-label={gettext("Drag to reorder")}>
                          <.icon name="hero-bars-2" class="w-4 h-4" />
                        </span>
                        <input
                          type="text"
                          id={"option-#{option["id"]}-name-#{@current_lang}"}
                          name={"option[#{option["id"]}][name]"}
                          value={name_value(option, @current_lang, @primary_language)}
                          placeholder={
                            if @current_lang == @primary_language,
                              do: gettext("Level name"),
                              else: blank_to(Map.get(option, "name"), gettext("Level name"))
                          }
                          autocomplete="off"
                          class="input input-sm w-full"
                        />
                        <button
                          type="button"
                          phx-click="remove_option"
                          phx-value-group-id={group["id"]}
                          phx-value-option-id={option["id"]}
                          class="btn btn-ghost btn-xs btn-square text-error shrink-0"
                          aria-label={Gettext.gettext(PhoenixKitWeb.Gettext, "Remove")}
                        >
                          <.icon name="hero-x-mark" class="w-4 h-4" />
                        </button>
                      </:item>
                    </.draggable_list>

                    <button
                      type="button"
                      phx-click="add_option"
                      phx-value-group-id={group["id"]}
                      class="btn btn-ghost btn-xs self-start"
                    >
                      <.icon name="hero-plus" class="w-3.5 h-3.5" /> {gettext("Add level")}
                    </button>
                  </div>
                </div>
              </:item>
            </.draggable_list>

            <div class="flex flex-wrap gap-2">
              <button type="button" phx-click="add_selector" class="btn btn-ghost btn-sm">
                <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add selector")}
              </button>
              <button
                :if={@staged_groups == []}
                type="button"
                phx-click="seed_standard_levels"
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-sparkles" class="w-4 h-4" /> {gettext("Add standard levels")}
              </button>
            </div>
            </div>
          </div>

          <div class="card-body pt-0">
            <div class="flex justify-end gap-2 mt-2">
              <.link navigate={Paths.skills()} class="btn btn-ghost btn-sm">
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
    </div>
    """
  end

  defp blank_to(nil, fallback), do: fallback
  defp blank_to("", fallback), do: fallback
  defp blank_to(value, _fallback), do: value
end
