defmodule PhoenixKitStaff.Staff do
  @moduledoc """
  Context for staff (people) and team memberships.

  Staff are linked 1:1 to a PhoenixKit user (decision A for MVP).
  A person can belong to multiple teams via `TeamMembership`.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  import Ecto.Query

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitStaff.PubSub, as: StaffPubSub
  alias PhoenixKitStaff.Schemas.Person
  alias PhoenixKitStaff.Skills
  alias PhoenixKitStaff.Staff.{Memberships, Org}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # Soft-delete sentinel, mirrors `Person.soft_delete_status/0`. Defined
  # here too so it's usable in guards and compile-time query pins.
  @soft_delete_status "trashed"

  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @doc "Returns the regex used to validate emails throughout the staff module."
  @spec email_regex() :: Regex.t()
  def email_regex, do: @email_regex

  @doc "Whether the given string looks like a valid email."
  @spec valid_email?(any()) :: boolean()
  def valid_email?(email) when is_binary(email), do: String.match?(email, @email_regex)
  def valid_email?(_), do: false

  # ── Rename placeholder user email ───────────────────────────────────

  @doc """
  Renames the email of an unclaimed placeholder user directly in place.
  Safe only for users we created via `find_or_create_user_by_email/1`
  that nobody has signed up for yet. Refuses if another user already
  exists with the new email.
  """
  @spec rename_placeholder_email(User.t(), String.t()) ::
          :ok
          | {:ok, User.t()}
          | {:error, PhoenixKitStaff.Errors.error_atom() | Ecto.Changeset.t()}
  def rename_placeholder_email(%User{} = user, new_email) do
    new_email = String.trim(new_email)
    current = user.email

    cond do
      new_email == "" ->
        {:error, :blank_email}

      new_email == current ->
        :ok

      not placeholder?(user) ->
        {:error, :placeholder_already_claimed}

      Auth.get_user_by_email(new_email) != nil ->
        {:error, :email_already_taken}

      true ->
        user
        |> Ecto.Changeset.cast(%{email: new_email}, [:email])
        |> Ecto.Changeset.validate_format(:email, @email_regex)
        |> Ecto.Changeset.unique_constraint(:email)
        |> repo().update()
    end
  end

  defp placeholder?(user) do
    is_nil(user.confirmed_at) and
      Map.get(user.custom_fields || %{}, "source") == "staff_placeholder"
  end

  # ── Find or create user by email ────────────────────────────────────

  @doc """
  Find-or-create a user by email, then create a staff person linked to
  that user. If the person creation fails AND we just created a brand-new
  placeholder user, delete the placeholder so we don't leave orphans.

  Returns `{:ok, person, user_status}` or `{:error, reason}`.
  """
  @spec create_person_with_user(String.t(), map()) ::
          {:ok, Person.t(), :created | :existing}
          | {:error,
             PhoenixKitStaff.Errors.error_atom()
             | Ecto.Changeset.t()
             | {:trashed_person_exists, Person.t()}}
  def create_person_with_user(email, person_attrs) do
    with {:ok, user, user_status} <- find_or_create_user_by_email(email),
         attrs = Map.put(person_attrs, "user_uuid", user.uuid),
         {:ok, person} <- create_person_or_rollback(attrs, user, user_status) do
      {:ok, person, user_status}
    end
  end

  defp create_person_or_rollback(attrs, user, user_status) do
    case create_person(attrs) do
      {:ok, person} ->
        {:ok, person}

      {:error, _} = err ->
        if user_status == :created, do: _ = repo().delete(user)
        err
    end
  end

  @doc """
  Finds an existing user by email, or creates a placeholder user with no
  usable password. When the person later registers or logs in via OAuth
  with the same email, PhoenixKit's built-in lookup links them automatically.
  """
  @spec find_or_create_user_by_email(String.t()) ::
          {:ok, User.t(), :created | :existing}
          | {:error, PhoenixKitStaff.Errors.error_atom() | Ecto.Changeset.t()}
  def find_or_create_user_by_email(email) when is_binary(email) do
    case String.trim(email) do
      "" -> {:error, :blank_email}
      trimmed -> find_or_register_placeholder(trimmed)
    end
  end

  defp find_or_register_placeholder(email) do
    case Auth.get_user_by_email(email) do
      %User{} = user -> {:ok, user, :existing}
      nil -> register_placeholder(email)
    end
  end

  defp register_placeholder(email) do
    random_password =
      :crypto.strong_rand_bytes(24) |> Base.url_encode64() |> binary_part(0, 24)

    attrs = %{
      "email" => email,
      "password" => random_password <> "Aa1!",
      "custom_fields" => %{"source" => "staff_placeholder"}
    }

    with {:ok, user} <- Auth.register_user(attrs), do: {:ok, user, :created}
  end

  # ── Eligible users (for person form) ────────────────────────────────

  @doc """
  Users who don't yet have a staff profile. When `exclude_person_uuid`
  is passed (edit mode), that person's linked user is kept in the list.
  """
  @spec eligible_users(keyword()) :: [User.t()]
  def eligible_users(opts \\ []) do
    exclude_person_uuid = Keyword.get(opts, :exclude_person_uuid)

    linked_user_uuids_query =
      from(p in Person,
        select: p.user_uuid
      )

    linked_user_uuids_query =
      if exclude_person_uuid do
        from([p] in linked_user_uuids_query, where: p.uuid != ^exclude_person_uuid)
      else
        linked_user_uuids_query
      end

    from(u in User,
      where: u.uuid not in subquery(linked_user_uuids_query),
      order_by: [asc: u.email]
    )
    |> repo().all()
  end

  # ── People ─────────────────────────────────────────────────────────

  @doc """
  Lists people. Accepts `:preload`, `:status` filter, `:search` (matches
  name or user email), and `:include_trashed` (default `false`).

  Trashed (soft-deleted) people are **excluded by default**. Pass
  `status: "trashed"` for the Trash view, or `include_trashed: true` to
  list everything regardless of status.
  """
  @spec list_people(keyword()) :: [Person.t()]
  def list_people(opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])
    status = Keyword.get(opts, :status)
    include_trashed = Keyword.get(opts, :include_trashed, false)
    search = opts |> Keyword.get(:search) |> normalize_search()

    Person
    |> scope_status(status, include_trashed)
    |> maybe_filter_search(search)
    |> order_by([p], asc: p.status, desc: p.inserted_at)
    |> preload(^preload)
    |> repo().all()
  end

  # Status scoping with trashed-exclusion by default:
  #   * "trashed"           → only trashed (the Trash view)
  #   * "active"/"inactive" → that status (inherently excludes trashed)
  #   * nil/"" + include?   → everything
  #   * nil/"" (default)    → everything except trashed
  defp scope_status(query, @soft_delete_status, _include),
    do: where(query, [p], p.status == ^@soft_delete_status)

  defp scope_status(query, status, _include) when status in ["active", "inactive"],
    do: where(query, [p], p.status == ^status)

  defp scope_status(query, _blank, true), do: query

  defp scope_status(query, _blank, false),
    do: where(query, [p], p.status != ^@soft_delete_status)

  defp maybe_filter_search(query, nil), do: query

  defp maybe_filter_search(query, term) do
    like = "%#{term}%"

    from(p in query,
      join: u in assoc(p, :user),
      where: ilike(u.email, ^like) or ilike(p.name, ^like)
    )
  end

  defp normalize_search(nil), do: nil
  defp normalize_search(""), do: nil
  defp normalize_search(s) when is_binary(s), do: String.trim(s)

  @doc "Fetches a person by the linked user's uuid, or `nil` if no staff profile exists."
  @spec get_person_by_user_uuid(UUIDv7.t() | String.t(), keyword()) :: Person.t() | nil
  def get_person_by_user_uuid(user_uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])

    Person
    |> where([p], p.user_uuid == ^user_uuid)
    |> preload(^preload)
    |> repo().one()
  end

  @doc "Fetches a person by uuid. Raises if not found."
  @spec get_person!(UUIDv7.t() | String.t(), keyword()) :: Person.t()
  def get_person!(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])

    Person
    |> preload(^preload)
    |> repo().get!(uuid)
  end

  @doc "Fetches a person by uuid, or `nil` if not found."
  @spec get_person(UUIDv7.t() | String.t(), keyword()) :: Person.t() | nil
  def get_person(uuid, opts \\ []) do
    preload = Keyword.get(opts, :preload, [:user, :primary_department])

    Person
    |> preload(^preload)
    |> repo().get(uuid)
  end

  @doc "Returns a changeset for the given person."
  @spec change_person(Person.t(), map()) :: Ecto.Changeset.t(Person.t())
  def change_person(%Person{} = p, attrs \\ %{}), do: Person.changeset(p, attrs)

  @doc """
  Inserts a person and broadcasts `:person_created` on success.

  Guards the strict 1:1 `user_uuid` unique constraint against a confusing
  failure: if the target user already has a **trashed** staff profile,
  re-adding them would trip the unique index. Instead this returns
  `{:error, {:trashed_person_exists, trashed_person}}` so the caller can
  offer to restore the existing record rather than creating a duplicate.
  """
  @spec create_person(map()) ::
          {:ok, Person.t()}
          | {:error, Ecto.Changeset.t(Person.t())}
          | {:error, {:trashed_person_exists, Person.t()}}
  def create_person(attrs) do
    case trashed_person_for_user(user_uuid_from(attrs)) do
      %Person{} = trashed ->
        {:error, {:trashed_person_exists, trashed}}

      nil ->
        with {:ok, person} <- %Person{} |> Person.changeset(attrs) |> repo().insert() do
          StaffPubSub.broadcast_person(:person_created, %{uuid: person.uuid})
          {:ok, person}
        end
    end
  end

  defp user_uuid_from(attrs), do: attrs["user_uuid"] || attrs[:user_uuid]

  defp trashed_person_for_user(nil), do: nil

  defp trashed_person_for_user(user_uuid) do
    Person
    |> where([p], p.user_uuid == ^user_uuid and p.status == ^@soft_delete_status)
    |> repo().one()
  end

  @doc "Updates a person and broadcasts `:person_updated` on success."
  @spec update_person(Person.t(), map()) ::
          {:ok, Person.t()} | {:error, Ecto.Changeset.t(Person.t())}
  def update_person(%Person{} = p, attrs) do
    with {:ok, updated} <- p |> Person.changeset(attrs) |> repo().update() do
      StaffPubSub.broadcast_person(:person_updated, %{uuid: updated.uuid})
      {:ok, updated}
    end
  end

  @doc """
  Soft-deletes a person: sets `status` to `"trashed"` and stashes the
  prior lifecycle status under `metadata["trashed_from_status"]` so
  `restore_person/1` can return them to active/inactive. Broadcasts
  `:person_updated`. Returns `{:error, :already_trashed}` if it's
  already trashed.

  Project assignments and team memberships are deliberately left intact
  (the FK rows survive), so the person — and their assignments — come
  back cleanly on restore. This is the whole point over hard delete,
  which would silently NULL out project assignments (FK is SET NULL).
  """
  @spec trash_person(Person.t()) :: {:ok, Person.t()} | {:error, :already_trashed}
  def trash_person(%Person{status: @soft_delete_status}), do: {:error, :already_trashed}

  def trash_person(%Person{uuid: uuid} = p) do
    # One UPDATE whose SET reads the row as it is now, never this copy of it:
    # a whole-map write would erase a key another session wrote since (the
    # avatar pointer, for one). The status guard sits in the WHERE, so two
    # sessions trashing at once get one {:ok, _} and one :already_trashed.
    query =
      from(x in Person,
        where: x.uuid == ^uuid and x.status != ^@soft_delete_status,
        update: [
          set: [
            status: ^@soft_delete_status,
            metadata:
              fragment(
                "jsonb_set(coalesce(?, '{}'::jsonb), '{trashed_from_status}', to_jsonb(?::text))",
                x.metadata,
                x.status
              )
          ]
        ],
        select: {x.status, x.metadata}
      )

    case repo().update_all(query, []) do
      {1, [{status, metadata}]} ->
        updated = %{p | status: status, metadata: metadata}
        StaffPubSub.broadcast_person(:person_updated, %{uuid: updated.uuid})
        {:ok, updated}

      {0, _} ->
        {:error, :already_trashed}
    end
  end

  @doc """
  Restores a trashed person to the status they had before trashing
  (read from `metadata["trashed_from_status"]`, validated against
  `Person.statuses/0`, defaulting to `"active"`). Clears the stash key
  but preserves any other metadata. Broadcasts `:person_updated`.
  Returns `{:error, :not_trashed}` if the person isn't trashed.
  """
  @spec restore_person(Person.t()) :: {:ok, Person.t()} | {:error, :not_trashed}
  def restore_person(%Person{status: @soft_delete_status, uuid: uuid} = p) do
    # Same shape as trash_person/1: the stash is read and cleared in the row,
    # so a key written while the person sat in the trash survives.
    query =
      from(x in Person,
        where: x.uuid == ^uuid and x.status == ^@soft_delete_status,
        update: [
          set: [
            status:
              fragment(
                "CASE WHEN ? ->> 'trashed_from_status' = ANY(?) THEN ? ->> 'trashed_from_status' ELSE 'active' END",
                x.metadata,
                type(^Person.statuses(), {:array, :string}),
                x.metadata
              ),
            metadata: fragment("coalesce(?, '{}'::jsonb) - 'trashed_from_status'", x.metadata)
          ]
        ],
        select: {x.status, x.metadata}
      )

    case repo().update_all(query, []) do
      {1, [{status, metadata}]} ->
        updated = %{p | status: status, metadata: metadata}
        StaffPubSub.broadcast_person(:person_updated, %{uuid: updated.uuid})
        {:ok, updated}

      {0, _} ->
        {:error, :not_trashed}
    end
  end

  def restore_person(%Person{}), do: {:error, :not_trashed}

  @doc """
  Permanently deletes a person (hard `Repo.delete`) and broadcasts
  `:person_deleted`. **Trash-only**: refuses a non-trashed person with
  `{:error, :not_trashed}` so permanent deletion is always a deliberate
  two-step (trash, then delete) — a stray direct call can't nuke an
  active person.

  The rescue clauses guard a *hypothetical* future `ON DELETE RESTRICT`
  FK into `phoenix_kit_staff_people`. Today none exist — the projects
  assignee FK is `ON DELETE SET NULL` and team memberships are
  `ON DELETE CASCADE` — so a delete won't raise; it succeeds and the
  caller is expected to have warned that project-assignment links get
  cleared. The rescue stays as cheap insurance against a future
  restricting consumer.
  """
  @spec delete_person(Person.t()) ::
          {:ok, Person.t()}
          | {:error, :not_trashed | :referenced_by_external | Ecto.Changeset.t(Person.t())}
  def delete_person(%Person{uuid: uuid} = p) do
    # DB-scoped delete keyed on the *current* status, not the in-memory
    # struct — a stale `%Person{status: "trashed"}` can't delete a row
    # that was restored to active in the meantime (TOCTOU-safe). 0 rows
    # affected ⇒ not currently trashed (or already gone) ⇒ :not_trashed.
    {count, _} =
      from(x in Person, where: x.uuid == ^uuid and x.status == ^@soft_delete_status)
      |> repo().delete_all()

    if count == 1 do
      StaffPubSub.broadcast_person(:person_deleted, %{uuid: uuid})
      {:ok, p}
    else
      {:error, :not_trashed}
    end
  rescue
    e in Ecto.ConstraintError ->
      if e.type == :foreign_key,
        do: {:error, :referenced_by_external},
        else: reraise(e, __STACKTRACE__)

    e in Postgrex.Error ->
      if fk_or_not_null_violation?(e),
        do: {:error, :referenced_by_external},
        else: reraise(e, __STACKTRACE__)
  end

  defp fk_or_not_null_violation?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in [:foreign_key_violation, :not_null_violation]

  defp fk_or_not_null_violation?(_), do: false

  # ── Bulk soft-delete operations ────────────────────────────────────

  @doc """
  Bulk-trashes the given people. Per-row stashes the prior status into
  `metadata["trashed_from_status"]` (in a single UPDATE — the SET
  expressions read the pre-update row, so `status` there is still the
  old value). Skips rows already trashed. Broadcasts one bulk event.
  Returns `{:ok, trashed_count}`.
  """
  @spec bulk_trash([UUIDv7.t() | String.t()]) :: {:ok, non_neg_integer()}
  def bulk_trash(uuids) when is_list(uuids) do
    {count, _} =
      from(p in Person,
        where: p.uuid in ^uuids and p.status != ^@soft_delete_status,
        update: [
          set: [
            status: ^@soft_delete_status,
            metadata:
              fragment(
                "jsonb_set(coalesce(?, '{}'::jsonb), '{trashed_from_status}', to_jsonb(?::text))",
                p.metadata,
                p.status
              ),
            updated_at: ^DateTime.truncate(DateTime.utc_now(), :second)
          ]
        ]
      )
      |> repo().update_all([])

    if count > 0, do: StaffPubSub.broadcast_people_bulk(:person_updated)
    {:ok, count}
  end

  @doc """
  Bulk-restores trashed people to their stashed prior status (validated
  to `active`/`inactive`, else `active`), clearing the stash key.
  Broadcasts one bulk event. Returns `{:ok, restored_count}`.
  """
  @spec bulk_restore([UUIDv7.t() | String.t()]) :: {:ok, non_neg_integer()}
  def bulk_restore(uuids) when is_list(uuids) do
    {count, _} =
      from(p in Person,
        where: p.uuid in ^uuids and p.status == ^@soft_delete_status,
        update: [
          set: [
            status:
              fragment(
                "CASE WHEN (?->>'trashed_from_status') IN ('active','inactive') THEN (?->>'trashed_from_status') ELSE 'active' END",
                p.metadata,
                p.metadata
              ),
            metadata: fragment("(? - 'trashed_from_status')", p.metadata),
            updated_at: ^DateTime.truncate(DateTime.utc_now(), :second)
          ]
        ]
      )
      |> repo().update_all([])

    if count > 0, do: StaffPubSub.broadcast_people_bulk(:person_updated)
    {:ok, count}
  end

  @doc """
  Bulk permanent-deletes people. Broadcasts one bulk event. Returns
  `{:ok, deleted_count}` or `{:error, :referenced_by_external}` if a
  (hypothetical future) RESTRICT FK blocks the delete.
  """
  @spec bulk_delete([UUIDv7.t() | String.t()]) ::
          {:ok, non_neg_integer()} | {:error, :referenced_by_external}
  def bulk_delete(uuids) when is_list(uuids) do
    # Trash-only, same contract as delete_person/1 — active rows in the
    # selection are left untouched.
    {count, _} =
      from(p in Person, where: p.uuid in ^uuids and p.status == ^@soft_delete_status)
      |> repo().delete_all()

    if count > 0, do: StaffPubSub.broadcast_people_bulk(:person_deleted)
    {:ok, count}
  rescue
    e in [Ecto.ConstraintError, Postgrex.Error] ->
      if match?(%Ecto.ConstraintError{type: :foreign_key}, e) or fk_or_not_null_violation?(e),
        do: {:error, :referenced_by_external},
        else: reraise(e, __STACKTRACE__)
  end

  @doc "Number of non-trashed people (the active roster size)."
  @spec count_people() :: non_neg_integer()
  def count_people do
    from(p in Person, where: p.status != ^@soft_delete_status)
    |> repo().aggregate(:count, :uuid)
  end

  @doc "Number of trashed (soft-deleted) people."
  @spec count_trashed() :: non_neg_integer()
  def count_trashed do
    from(p in Person, where: p.status == ^@soft_delete_status)
    |> repo().aggregate(:count, :uuid)
  end

  # ── Upcoming birthdays ─────────────────────────────────────────────

  @doc "Upcoming birthdays within `window_days` (default 30). See `PhoenixKitStaff.Staff.Org`."
  @spec upcoming_birthdays(non_neg_integer()) :: [
          %{person: Person.t(), next_birthday: Date.t(), days_until: non_neg_integer()}
        ]
  def upcoming_birthdays(window_days \\ 30), do: Org.upcoming_birthdays(window_days)

  # ── Org tree ───────────────────────────────────────────────────────

  @doc "The full department → team → people org tree. See `PhoenixKitStaff.Staff.Org`."
  defdelegate org_tree, to: Org

  # ── Team memberships ───────────────────────────────────────────────

  # Thin delegators — implementations live in `PhoenixKitStaff.Staff.Memberships`.
  @doc "See `PhoenixKitStaff.Staff.Memberships.list_team_memberships/1`."
  defdelegate list_team_memberships(team_uuid), to: Memberships

  @doc "See `PhoenixKitStaff.Staff.Memberships.list_memberships_for_person/1`."
  defdelegate list_memberships_for_person(person_uuid), to: Memberships

  @doc "See `PhoenixKitStaff.Staff.Memberships.add_team_person/2`."
  defdelegate add_team_person(team_uuid, staff_person_uuid), to: Memberships

  @doc "See `PhoenixKitStaff.Staff.Memberships.remove_team_person/1`."
  defdelegate remove_team_person(team_membership), to: Memberships

  @doc "See `PhoenixKitStaff.Staff.Memberships.remove_team_person/2`."
  defdelegate remove_team_person(team_uuid, staff_person_uuid), to: Memberships

  @doc "See `PhoenixKitStaff.Staff.Memberships.people_not_on_team/1`."
  defdelegate people_not_on_team(team_uuid), to: Memberships

  # ── Skill assignment (delegates to PhoenixKitStaff.Skills) ─────────
  # Skill CRUD + assignment live in `Skills` for cohesion; these thin
  # delegators keep the person↔skill API reachable from `Staff`, mirroring
  # how team membership lives here.

  @doc "Delegates to `PhoenixKitStaff.Skills.assign_skill/3` (level_ids list)."
  defdelegate assign_skill(person_uuid, skill_uuid, level_ids), to: Skills

  @doc "Delegates to `PhoenixKitStaff.Skills.unassign_skill/1`."
  defdelegate unassign_skill(person_skill), to: Skills

  @doc "Delegates to `PhoenixKitStaff.Skills.unassign_skill/2`."
  defdelegate unassign_skill(person_uuid, skill_uuid), to: Skills

  @doc "Delegates to `PhoenixKitStaff.Skills.list_for_person/1`."
  defdelegate list_skills_for_person(person_uuid), to: Skills, as: :list_for_person
end
