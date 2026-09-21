defmodule PhoenixKitStaff.Web.Helpers do
  @moduledoc """
  Cross-LV helpers shared by the staff admin LiveViews.

  ## `log_operation_error/3` — failure-side audit rows

  Staff's documented architectural choice is that **`PhoenixKitStaff.Activity`
  is success-only at the call site** (see `CLAUDE.md` "Activity logging").
  The post-Apr pipeline expects every user-driven mutation to leave an
  audit row on BOTH `:ok` AND `:error` branches so a DB outage / FK
  violation / constraint failure can't silently erase admin clicks
  from the activity feed.

  The catalogue module's Batch 4 (canonical reference at
  `phoenix_kit_catalogue/lib/phoenix_kit_catalogue/web/helpers.ex`)
  resolves the tension by writing the failure-side row at the
  **LiveView layer**, not in the context. Same intent here:

  - One edit point in this helper instead of ~10 LV mutation sites
  - Same action atom the success path would have used
    (e.g. `staff.person_deleted`)
  - `metadata.db_pending: true` so audit-feed readers can distinguish
    attempted-but-failed from completed actions
  - PII-safe metadata: changeset reasons land error-key field names
    only (no values), atom reasons land the atom string, other shapes
    get `error_kind: "other"`

  Helper only fires from `handle_event` `{:error, _}` branches —
  validate cycles never reach it (they're handled by the form's
  `assign_form/2` cycle, no audit row needed for keystrokes).
  """

  alias PhoenixKitStaff.Activity

  @doc """
  Writes a failure-side activity row for a destructive/mutating operation.

  ## Required opts

    * `:resource_type` — string, e.g. `"staff_person"` / `"department"`
    * `:reason` — the `{:error, reason}` value from the context call

  ## Optional opts

    * `:resource_uuid` — uuid of the record the operation targeted.
      Optional because failed CREATE submissions have no uuid yet — in
      that case the audit row records intent without a target.
    * `:target_uuid` — second-party uuid for membership operations
      (the user being added/removed, etc.)
    * `:metadata` — extra metadata (must be PII-safe). Merged UNDER
      the helper's own `db_pending` / `error_kind` / `error_keys` /
      `error_atom` keys — caller-supplied collisions on those keys are
      ignored so the audit-feed contract stays stable.

  Returns the underlying `Activity.log/2` return value (`{:ok, _entry}`
  or `{:error, _}`); never raises.
  """
  @spec log_operation_error(String.t(), Phoenix.LiveView.Socket.t(), keyword()) ::
          {:ok, struct()} | {:error, any()}
  def log_operation_error(action, socket, opts) when is_binary(action) and is_list(opts) do
    reason = Keyword.fetch!(opts, :reason)
    resource_type = Keyword.fetch!(opts, :resource_type)
    resource_uuid = Keyword.get(opts, :resource_uuid)
    target_uuid = Keyword.get(opts, :target_uuid)
    extra_metadata = Keyword.get(opts, :metadata, %{})

    helper_metadata = Map.put(reason_metadata(reason), "db_pending", true)

    # Caller metadata first; helper-owned keys win. Audit-feed readers
    # rely on `db_pending` / `error_kind` so callers must not override.
    metadata =
      extra_metadata
      |> stringify_keys()
      |> Map.merge(helper_metadata)

    Activity.log(action,
      actor_uuid: Activity.actor_uuid(socket),
      resource_type: resource_type,
      resource_uuid: resource_uuid,
      target_uuid: target_uuid,
      metadata: metadata
    )
  end

  # PII-safe reason summarisation. Changeset error keys are field
  # names (safe); changeset error MESSAGES often interpolate user
  # input (unsafe — never logged). Atom reasons get stringified.
  # Anything else lands as "other".
  defp reason_metadata(%Ecto.Changeset{errors: errors}) do
    %{
      "error_kind" => "changeset",
      "error_keys" => Enum.map(errors, fn {field, _err} -> Atom.to_string(field) end)
    }
  end

  defp reason_metadata(reason) when is_atom(reason) do
    %{"error_kind" => "atom", "error_atom" => Atom.to_string(reason)}
  end

  defp reason_metadata(_other), do: %{"error_kind" => "other"}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_keys(other), do: other

  # ─────────────────────────────────────────────────────────────────
  # Multilang form helpers
  # ─────────────────────────────────────────────────────────────────
  #
  # Shared by `DepartmentFormLive`, `TeamFormLive`, and `PersonFormLive`.
  # Same shape as `PhoenixKitProjects.Web.Helpers` — the projects
  # module is the workspace's canonical reference for the
  # settings-translations multilang pattern.

  @doc """
  Reads the `translations` field off the current form's changeset and
  returns the sub-map for `current_lang` (or `%{}`).

  Used as the `lang_data` attr on `<.translatable_field>` so secondary
  tabs see in-flight overrides — without this, switching between two
  secondary tabs would lose unsaved edits.
  """
  @spec lang_data(Phoenix.HTML.Form.t(), String.t() | nil) :: map()
  def lang_data(form, current_lang) do
    case form.source do
      %Ecto.Changeset{} = cs ->
        cs
        |> Ecto.Changeset.get_field(:translations)
        |> case do
          %{} = m -> Map.get(m, current_lang) || %{}
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  @doc """
  Folds secondary-language form params into the in-flight record's
  `translations` JSONB and preserves primary-language column values
  that the current secondary-tab DOM didn't render.

  `primary_fields` is the list of DB column names (as strings) that are
  translatable — e.g. `["name", "description"]` for Department,
  `["job_title", "bio", "skills", "notes"]` for Person.
  """
  @spec merge_translations_attrs(map(), struct(), [String.t()]) :: map()
  def merge_translations_attrs(attrs, record, primary_fields) do
    attrs
    |> merge_translations_map(record)
    |> preserve_primary_fields(record, primary_fields)
  end

  defp merge_translations_map(attrs, record) do
    case Map.get(attrs, "translations") do
      submitted when is_map(submitted) and submitted != %{} ->
        cleaned = clean_submitted_translations(submitted)
        existing = Map.get(record, :translations) || %{}
        merged = deep_merge_translations(existing, cleaned)
        Map.put(attrs, "translations", merged)

      _ ->
        Map.delete(attrs, "translations")
    end
  end

  # Strips Phoenix LV's `_unused_*` sentinel keys and drops
  # empty-string overrides so that clearing a secondary-tab field
  # falls back cleanly to the primary value at render time, rather
  # than persisting a `""` that the localized-read helpers would
  # have to special-case.
  defp clean_submitted_translations(submitted) when is_map(submitted) do
    submitted
    |> Enum.map(fn {lang, fields} -> {lang, clean_lang_fields(fields)} end)
    |> Enum.reject(fn {_lang, fields} -> fields == %{} end)
    |> Map.new()
  end

  defp clean_lang_fields(fields) when is_map(fields) do
    fields
    |> Enum.reject(fn
      {"_unused_" <> _, _} -> true
      {_k, ""} -> true
      {_k, nil} -> true
      _ -> false
    end)
    |> Map.new()
  end

  defp clean_lang_fields(_), do: %{}

  defp deep_merge_translations(existing, submitted) do
    Map.merge(existing, submitted, fn _lang, old_lang_map, new_lang_map ->
      Map.merge(old_lang_map || %{}, new_lang_map || %{})
    end)
  end

  defp preserve_primary_fields(attrs, record, primary_fields) do
    Enum.reduce(primary_fields, attrs, fn field, acc ->
      if Map.has_key?(acc, field) do
        acc
      else
        existing = Map.get(record, String.to_existing_atom(field))
        if is_nil(existing), do: acc, else: Map.put(acc, field, existing)
      end
    end)
  end

  @doc """
  Returns the user's in-flight record by applying the current changeset.

  When the user has been typing in a primary-tab field and switches to a
  secondary tab, the server-side changeset already captures those primary
  values from prior `validate` events. Re-using the pristine assign
  would lose them because that struct is the pre-form-edit version.
  Apply the changeset to get the baseline that has both the primary
  fields AND the existing translations the user has already typed.
  """
  @spec in_flight_record(Phoenix.LiveView.Socket.t(), atom(), atom()) :: struct()
  def in_flight_record(socket, form_assign, fallback_assign) do
    case socket.assigns[form_assign] do
      %Phoenix.HTML.Form{source: %Ecto.Changeset{} = cs} ->
        Ecto.Changeset.apply_changes(cs)

      _ ->
        socket.assigns[fallback_assign]
    end
  end

  @doc """
  Flips `:current_lang` back to `:primary_language` when a save fails
  with errors on translatable primary fields submitted from a
  secondary tab. Without this, the inline error renders on the
  primary tab (where the user can't see it) and the form re-renders
  with no visible change after submit. `translatable_fields` is the
  list of DB column names (atoms) from `Schema.translatable_fields/0`.
  """
  @spec maybe_switch_to_primary_on_error(
          Phoenix.LiveView.Socket.t(),
          Ecto.Changeset.t(),
          [atom()]
        ) :: Phoenix.LiveView.Socket.t()
  def maybe_switch_to_primary_on_error(
        socket,
        %Ecto.Changeset{errors: errors},
        translatable_fields
      ) do
    on_secondary? =
      socket.assigns[:multilang_enabled] == true and
        socket.assigns[:current_lang] != socket.assigns[:primary_language]

    has_primary_error? = Enum.any?(errors, fn {field, _} -> field in translatable_fields end)

    if on_secondary? and has_primary_error? do
      Phoenix.Component.assign(socket, :current_lang, socket.assigns[:primary_language])
    else
      socket
    end
  end

  def maybe_switch_to_primary_on_error(socket, _other, _fields), do: socket
end
