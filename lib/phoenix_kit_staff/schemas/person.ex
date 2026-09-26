defmodule PhoenixKitStaff.Schemas.Person do
  @moduledoc """
  A person on staff. Always linked to a PhoenixKit user (decision A for MVP);
  the `user_uuid` FK is required.

  All profile fields beyond the required `user_uuid` and `status` are
  optional — fill in whatever's relevant.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  use Gettext, backend: PhoenixKitWeb.Gettext
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitStaff.L10n
  alias PhoenixKitStaff.Schemas.{Department, PersonSkill, TeamMembership}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  # User-selectable lifecycle statuses (the form's status dropdown).
  @statuses ~w(active inactive)
  # Soft-delete sentinel — set via `Staff.trash_person/2`, never offered
  # in the form. Kept out of `@statuses` so the form dropdown stays
  # active/inactive, but allowed by the changeset's status validation.
  @soft_delete_status "trashed"
  @employment_types ~w(full_time part_time contractor intern temporary)

  # Person carries a `translations` JSONB for the subset of free-text
  # profile fields where a multilingual workforce realistically wants
  # per-language overrides. Phone numbers, dates, enums, names of
  # people, etc. stay primary-only — translating them rarely makes
  # sense and the form bloat isn't worth it.
  #
  # `work_location` was originally translatable but is now a soft-FK
  # reference to a `phoenix_kit_locations` row (UUID stored as string
  # in the existing column to avoid a type-changing migration). It no
  # longer needs per-language overrides because the location row
  # owns its own translations.
  #
  # `skills` was a translatable free-text field; it was replaced (core
  # V135) by the structured `Skill` entity + `person_skills` assignments,
  # so it no longer lives here.
  @translatable_fields ~w(job_title bio notes)

  @type translations_map :: %{optional(String.t()) => %{optional(String.t()) => String.t()}}

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          user_uuid: UUIDv7.t() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t() | nil,
          primary_department_uuid: UUIDv7.t() | nil,
          primary_department: Department.t() | Ecto.Association.NotLoaded.t() | nil,
          team_memberships: [TeamMembership.t()] | Ecto.Association.NotLoaded.t(),
          person_skills: [PersonSkill.t()] | Ecto.Association.NotLoaded.t(),
          status: String.t() | nil,
          name: String.t() | nil,
          job_title: String.t() | nil,
          employment_type: String.t() | nil,
          employment_start_date: Date.t() | nil,
          employment_end_date: Date.t() | nil,
          work_location: String.t() | nil,
          work_phone: String.t() | nil,
          personal_phone: String.t() | nil,
          bio: String.t() | nil,
          notes: String.t() | nil,
          date_of_birth: Date.t() | nil,
          personal_email: String.t() | nil,
          emergency_contact_name: String.t() | nil,
          emergency_contact_phone: String.t() | nil,
          emergency_contact_relationship: String.t() | nil,
          translations: translations_map(),
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_staff_people" do
    field(:status, :string, default: "active")
    field(:name, :string)
    field(:job_title, :string)
    field(:employment_type, :string)
    field(:employment_start_date, :date)
    field(:employment_end_date, :date)
    field(:work_location, :string)
    field(:work_phone, :string)
    field(:personal_phone, :string)
    field(:bio, :string)
    field(:notes, :string)
    field(:date_of_birth, :date)
    field(:personal_email, :string)
    field(:emergency_contact_name, :string)
    field(:emergency_contact_phone, :string)
    field(:emergency_contact_relationship, :string)

    field(:translations, :map, default: %{})
    field(:metadata, :map, default: %{})

    belongs_to(:user, User, foreign_key: :user_uuid, references: :uuid)

    belongs_to(:primary_department, Department,
      foreign_key: :primary_department_uuid,
      references: :uuid
    )

    has_many(:team_memberships, TeamMembership,
      foreign_key: :staff_person_uuid,
      on_delete: :delete_all
    )

    has_many(:person_skills, PersonSkill,
      foreign_key: :staff_person_uuid,
      on_delete: :delete_all
    )

    timestamps(type: :utc_datetime)
  end

  @required ~w(user_uuid status)a
  @optional ~w(primary_department_uuid name
               job_title employment_type
               employment_start_date employment_end_date work_location
               work_phone personal_phone bio notes
               date_of_birth personal_email
               emergency_contact_name emergency_contact_phone
               emergency_contact_relationship translations metadata)a

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(person, attrs) do
    person
    |> cast(attrs, @required ++ @optional)
    |> keep_server_owned_metadata()
    |> validate_required(@required)
    # Only user-selectable statuses pass the public changeset. The
    # "trashed" sentinel is set exclusively by `Staff.trash_person/1`
    # via a controlled `Ecto.Changeset.change/2` (not cast from params),
    # so a crafted create/edit payload can't soft-delete out-of-band.
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:employment_type, @employment_types,
      message: gettext("must be one of: %{values}", values: Enum.join(@employment_types, ", "))
    )
    |> validate_length(:name, max: 255)
    |> validate_length(:job_title, max: 255)
    |> validate_length(:work_location, max: 255)
    |> validate_length(:work_phone, max: 50)
    |> validate_length(:personal_phone, max: 50)
    |> validate_length(:personal_email, max: 255)
    |> validate_format(:personal_email, PhoenixKitStaff.Staff.email_regex(),
      message: gettext("must be a valid email")
    )
    |> validate_length(:emergency_contact_name, max: 255)
    |> validate_length(:emergency_contact_phone, max: 50)
    |> validate_length(:emergency_contact_relationship, max: 100)
    |> L10n.validate_translations()
    |> assoc_constraint(:user)
    |> unique_constraint(:user_uuid,
      name: :phoenix_kit_staff_people_user_index,
      message: gettext("already linked to a person on staff")
    )
  end

  def statuses, do: @statuses
  def employment_types, do: @employment_types

  @doc "The soft-delete sentinel value stored in `status`."
  @spec soft_delete_status() :: String.t()
  def soft_delete_status, do: @soft_delete_status

  @doc "Whether the person is soft-deleted (trashed)."
  @spec trashed?(t()) :: boolean()
  def trashed?(%__MODULE__{status: @soft_delete_status}), do: true
  def trashed?(%__MODULE__{}), do: false

  @doc "DB-column field names that participate in the `translations` JSONB."
  @spec translatable_fields() :: [String.t()]
  def translatable_fields, do: @translatable_fields

  @spec localized_job_title(t(), String.t() | nil) :: String.t() | nil
  def localized_job_title(%__MODULE__{} = p, lang), do: L10n.localized_field(p, "job_title", lang)

  @spec localized_bio(t(), String.t() | nil) :: String.t() | nil
  def localized_bio(%__MODULE__{} = p, lang), do: L10n.localized_field(p, "bio", lang)

  @spec localized_notes(t(), String.t() | nil) :: String.t() | nil
  def localized_notes(%__MODULE__{} = p, lang), do: L10n.localized_field(p, "notes", lang)

  @doc """
  Best human label for a staff person, in priority order:

  1. the explicit `name` column (the staff profile owns identity),
  2. the linked user's `first_name`/`last_name`,
  3. the linked user's email,
  4. a generic `"Unnamed"` fallback.

  Used by every people-listing surface (people list, org overview,
  birthdays, show page) so the display is consistent. Expects `:user`
  to be preloaded for the email/user-name fallbacks; an unloaded
  association just skips to the generic fallback.
  """
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{user: %User{} = user}), do: user_display_name(user)
  def display_name(%__MODULE__{}), do: gettext("Unnamed")

  defp user_display_name(%User{} = user) do
    [user.first_name, user.last_name]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> user.email || gettext("Unnamed")
      full -> full
    end
  end

  @doc "Translated label for a status value (for UI display)."
  def status_label("active"), do: gettext("Active")
  def status_label("inactive"), do: gettext("Inactive")
  def status_label("trashed"), do: gettext("Trashed")
  def status_label(other), do: other

  def employment_type_label("full_time"), do: gettext("Full-time")
  def employment_type_label("part_time"), do: gettext("Part-time")
  def employment_type_label("contractor"), do: gettext("Contractor")
  def employment_type_label("intern"), do: gettext("Intern")
  def employment_type_label("temporary"), do: gettext("Temporary")
  def employment_type_label(nil), do: nil
  def employment_type_label(other), do: other

  # `metadata` is castable so a host can keep its own keys there, but two of
  # them are server-owned: `avatar_uuid`, written only by
  # `Attachments.set_avatar/3` after it has checked the file is the person's
  # own image, and `trashed_from_status`, written only by `Staff.trash_person/1`.
  # A metadata map from params — or from a stale struct — can neither set nor
  # clear them: they are re-read from the row, under its lock, inside the
  # write's own transaction. Atom keys would land under the same JSON names,
  # so both spellings are dropped.
  @server_owned_metadata ~w(avatar_uuid trashed_from_status)

  defp keep_server_owned_metadata(changeset) do
    case fetch_change(changeset, :metadata) do
      {:ok, new} when is_map(new) ->
        prepare_changes(changeset, fn cs ->
          put_change(cs, :metadata, Map.merge(without_owned(new), owned_now(cs)))
        end)

      _ ->
        changeset
    end
  end

  defp without_owned(map) do
    Map.reject(map, fn {k, _} ->
      (is_atom(k) or is_binary(k)) and to_string(k) in @server_owned_metadata
    end)
  end

  defp owned_now(%Ecto.Changeset{data: %__MODULE__{uuid: uuid}, repo: repo})
       when is_binary(uuid) do
    query = from(p in __MODULE__, where: p.uuid == ^uuid, select: p.metadata, lock: "FOR UPDATE")

    case repo.one(query) do
      %{} = metadata -> Map.take(metadata, @server_owned_metadata)
      _ -> %{}
    end
  end

  defp owned_now(_new_record), do: %{}
end
