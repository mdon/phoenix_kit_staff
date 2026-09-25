# AGENTS.md

Guidance for AI agents working on `phoenix_kit_staff`.

## Overview

Org-structure backbone for a PhoenixKit host: departments, teams, people (each linked 1:1 to a `PhoenixKit.Users.Auth.User`), a translatable skill taxonomy with per-person assignments, and a per-person employment history. Implements the `PhoenixKit.Module` behaviour for auto-discovery.

- **Depends on:** `phoenix_kit` `>= 2.38.0 and < 3.0.0` (Hex — the release that carries `PhoenixKitWeb.Actor`, `Activity.log/3`, `Storage.ResourceFolders` and the reorganizer's `ResourceSource`; the compound form keeps the ceiling open across later 2.x minors); `phoenix_kit_comments` `~> 0.3` (hard, compile-time: `PersonShowLive` does `use PhoenixKitComments.Embed` and embeds the comment thread). Soft, runtime-only: `phoenix_kit_locations` (resolved with `Code.ensure_loaded/1`; never a mix dep).
- **Consumed by:** `phoenix_kit_projects` (optional dep; reads the staff tables through its own read-only shadow schemas `PhoenixKitProjects.People.*` and calls only `PhoenixKitStaff.enabled?/0`, for admin-UI affordances) and `phoenix_kit_crm` (`StaffLink`; no mix dep; `apply/3` into `enabled?/0`, `Paths.person/1`, `Staff.list_people/1`, `Staff.get_person/1`, `Schemas.Person.display_name/1` when the module is loaded and enabled).
- **Admin surface:** one tab `Staff` at `/admin/staff` with visible subtabs Overview (`/admin/staff`; org tree, upcoming birthdays), Departments (`/admin/staff/departments`), Teams (`/admin/staff/teams`), Staff (`/admin/staff/people`), Skills (`/admin/staff/skills`); hidden `…/new`, `…/:id`, `…/:id/edit` subtabs per resource.
- **Module key** `"staff"`; settings prefix `staff_`.

## What this module does NOT do

- No leave/PTO tracking, performance reviews, payroll, compensation or contract data. Employment **history** spans are tracked (org/role history, not compensation). Build such features as sibling modules over Staff's public API.
- No org-chart visualization beyond the Overview's plain nested list.
- No bulk import: single-record forms only; scripted imports go through the context API (`Staff.create_person/1`, …).
- No public-facing pages (admin-only) and no external HRIS integrations.
- No audit history beyond the `PhoenixKit.Activity` feed.
- No skill categories or grouping (deliberate v1 cut). A span's team is a history snapshot, not membership management. Span `job_title` is edited in the primary language only.
- No `deleted_at` column: soft-delete is the `status = "trashed"` sentinel (see Conventions).
- No migrations and no DDL of its own: every table is core-owned (see Database & migrations).
- No module-owned media table: Files/Images ride on core Storage folders.

## Commands

```bash
mix deps.get
createdb phoenix_kit_staff_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
PHOENIX_KIT_COMMENTS_PATH=../phoenix_kit_comments mix test
```

`mix precommit` here also runs `deps.unlock --check-unused` and `mix hex.audit`. `mix test.setup` / `mix test.reset` create / drop the test database through the test Repo.

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.

## Conventions

- Module key `"staff"`; tab ids are prefixed `:admin_staff_`; URL segments live under `/admin/staff/` (`departments`, `teams`, `people`, `skills`; a multi-word segment uses hyphens).
- Paths: always `PhoenixKitStaff.Paths.*` (wraps `PhoenixKit.Utils.Routes.path/1`). Never hardcode a path.
- Routing: every page is a `live_view:` on a `%Tab{}` in `admin_tabs/0`; there is no `route_module/0`. Never hand-register plugin routes in a host router.
- LiveViews `use PhoenixKitWeb, :live_view` (components `use PhoenixKitWeb, :live_component`). The admin live_session injects the layout, so templates never wrap in `LayoutWrapper`. Core's on_mount hooks provide `@phoenix_kit_current_scope`, `@phoenix_kit_current_user`, `@current_locale`, `@url_path`.
- `PeopleLive` keeps search and status filter in the URL through `PhoenixKitWeb.Live.UrlState` (`q`, `status` in `["", "active", "inactive", "trashed"]`); the list loads in `handle_url_state/2`, not `mount/3`.
- Gettext: hybrid backends. Staff-domain strings use `use Gettext, backend: PhoenixKitStaff.Gettext` (catalogs in `priv/gettext/`, `et` and `ru`; `mix gettext.extract` + `mix gettext.merge priv/gettext`). Generic strings core already ships (`Save`, `Cancel`, `Edit`, …) and the `L10n` date/month helpers stay on `PhoenixKitWeb.Gettext`: if core has it, call core. `%Tab{}` labels carry `gettext_backend: PhoenixKitStaff.Gettext` and stay extractable through the `gettext_noop` anchors in `PhoenixKitStaff.__tab_label_strings__/0`; add a label there when adding a tab. User-entered names (skill selectors, options) live in `translations` maps, never in gettext. Context functions never call gettext: they return `{:error, atom}` and `PhoenixKitStaff.Errors.message/1` turns the atom into copy at the LiveView boundary (a fallback firing in production means a missing branch).
- JS hooks: none. `css_sources/0` returns `[:phoenix_kit_staff]`.
- `enabled?/0` reads `staff_enabled` through `Settings.get_boolean_setting/2`, rescues, catches `:exit`, and returns `false`.
- Every table-backed schema has `@primary_key {:uuid, UUIDv7, autogenerate: true}`, `@foreign_key_type UUIDv7`, `timestamps(type: :utc_datetime)` and `use PhoenixKit.SchemaPrefix` (a conformance test enforces the last one).
- Every mutation broadcasts through `PhoenixKitStaff.PubSub`; list views reload from the broadcast (delivered to self), so mutation handlers do not reload on their own.
- Email validation: `Staff.email_regex/0` + `Staff.valid_email?/1`.
- Cross-module contract. Projects maps its own schemas over the staff tables, so these are what siblings depend on, not only the function API:

| Contract | Rule |
|---|---|
| `phoenix_kit_staff_people` | columns `name`, `status`, `user_uuid`, `primary_department_uuid`; `status = "trashed"` means soft-deleted and is excluded from listings by default |
| `phoenix_kit_staff_teams` / `_departments` | `name` + `translations[lang]["name"]` override; teams carry `department_uuid` |
| `phoenix_kit_staff_team_memberships` | `team_uuid` + `staff_person_uuid` |
| Function API kept stable | `enabled?/0`, `Paths.person/1`, `Staff.list_people/1`, `Staff.get_person/1`, `Staff.get_person_by_user_uuid/2`, `Schemas.Person.display_name/1`, `Teams.list/1`, `Departments.list/1` |
| Person deletion | sibling FKs target `Person.uuid` with `ON DELETE SET NULL`, which is why people are trashed rather than deleted |

### Activity logging

- Every mutation logs through the `PhoenixKitStaff.Activity` wrapper (`log/2`), which is core's never-raising `PhoenixKit.Activity.log/3` under the `"staff"` module key.
- Logging happens at the **LiveView layer** on success: the LiveView owns `actor_uuid` (`Activity.actor_uuid(socket)` is core's `PhoenixKitWeb.Actor` — the scope first, then the bare current user) and user intent; contexts stay pure.
- The failure side is logged too: `{:error, _}` branches of `handle_event` call `Web.Helpers.log_operation_error/3` with the same action string, `metadata.db_pending: true`, and PII-safe metadata (changeset error **keys** only, atom reasons as strings, everything else `error_kind: "other"`). Validate cycles never log.
- Action strings follow `"staff.<resource>_<verb>"`:
  - `staff.person_created/updated/deleted`, `staff.person_trashed/restored`, `staff.people_bulk_trashed/restored/deleted`
  - `staff.department_created/updated/deleted`, `staff.team_created/updated/deleted`, `staff.team_person_added/removed`
  - `staff.skill_created/updated/deleted`, `staff.person_skill_added/removed/updated`
  - `staff.person_employment_added/updated/ended/removed`
  - `staff.person_file_added/removed`, `staff.person_image_added/removed`, `staff.person_avatar_set/removed`
- `PersonEventsComponent` renders the person's feed read-only and offset-paginated (`Activity.list(resource_type: "staff_person", resource_uuid: …)`); labels and icons come from `PhoenixKitStaff.ActivityLabels` (humanized fallback), badge colour from core `Activity.action_badge_color/1`. No live prepend.

### Multilang translations

- Department, Team, Person, Skill and Employment carry a `translations` JSONB holding **non-primary-language overrides only** (`%{"es-ES" => %{"name" => "…"}}`); primary values stay in their columns.
- Translatable fields: Department/Team/Skill `name` + `description`; Person `job_title`, `bio`, `notes` (not `name`, not `work_location`); Employment `job_title`.
- Reads go through `<Schema>.localized_<field>/2` (primary fallback). Changesets validate the shape with `L10n.valid_translations_shape?/1`.
- Forms use core `PhoenixKitWeb.Components.MultilangForm` (`<.multilang_tabs>`, `<.multilang_fields_wrapper>`, `<.translatable_field>`); `Web.Helpers.merge_translations_attrs/3` folds the per-language params back into `translations`. An `:edit` form opens on the viewing language (`mount_multilang(open_on: :viewing_language)`); `:new` opens on the main language, which holds the required fields.

### Skills

- `Skill.levels` JSONB is an ordered list of named **selectors**: `%{"id", "name", "translations", "allow_multiple", "options" => [%{"id", "name", "translations"}]}`. `Skill.level_groups/1` wraps the legacy flat-list shape (plus the legacy `allow_multiple_levels` column) into one default selector on read; per-selector `allow_multiple` is authoritative. `normalize_levels/1` validates the nested shape strictly. Helpers: `group_options/1`, `all_option_ids/1`, `find_option/2`, `localized_group_name/3`, `localized_option_name/3`, `option_choices/3`, `selected_by_group/2`, `toggle_option/3`, `gen_level_id/0`.
- `PersonSkill.proficiency_levels` JSONB holds the selected **option** ids across all of the skill's selectors (`[]` = none). The changeset only normalises; semantic validation (ids ⊆ options, ≤ 1 per single-select selector, canonical order) lives in `Skills`.
- `Skills` is the **sole write path** for assignments (`assign_skill`, `unassign_skill`, `update_assignment_levels`, `validate_level_ids`, `prune_level_ids`, rosters); `Staff` keeps thin delegators. `Skills.update/2` reconciles existing assignments in one transaction (strips removed option ids; prunes to ≤ 1 on a multiple→single flip).
- Two UI directions: skill show persists per-selector toggle chips immediately; the person form stages a type-to-search multi-select and writes it on save (`PersonFormLive.sync_skills/2` after the upsert; `phx-window-focus` re-queries the taxonomy). Person show renders assignments read-only.
- Skill delete cascades assignments (FK `ON DELETE CASCADE`); the UI shows the "removed from N people" count.

### Employment history

- A person's employment is a history of spans on the **Employment tab** of person show, never fields on the person form. Each span records `employment_type`, translatable `job_title`, an org snapshot (`primary_department_uuid` + `primary_team_uuid`), a date range (`employment_end_date nil` = open/current), `work_location`, `notes`.
- **One open span per person**, backstopped by a partial unique index (`WHERE employment_end_date IS NULL`). `Employments` is the sole write path; `create/2` closes the prior open span at the new span's start.
- The open span is **mirrored onto Person** (`employment_type`, `job_title` + its translations, dates, `primary_department_uuid`, `work_location`) by `Employments.sync_current/1` in the same transaction, without clobbering the person's other translated fields. These columns are server-owned: the person form never casts them and has no department picker (only `status` and the team picker, which lists all teams).
- A span's `primary_team_uuid` is a snapshot; it never changes `TeamMembership`.
- `PersonEmploymentComponent` hosts the timeline and the add/edit form, persists immediately, logs `staff.person_employment_*`, and the `:person_employment_changed` broadcast refreshes the host.
- `Person.work_location` is a soft FK to a `phoenix_kit_locations` row (UUID stored as a string; no type-changing migration). The span form's picker is sourced from `PhoenixKitLocations.Locations.list_locations(status: "active")` only when the module is loaded and enabled, and is hidden otherwise; the stored value renders as-is on person show and in the timeline.

### Media attachments and avatar

- Backed by core `PhoenixKit.Modules.Storage` folders (helper `PhoenixKitStaff.Attachments`). Root folder `staff-person-<uuid>` plus a nested `Images` folder, **resolved by name on every read** (never cached on Person), created lazily on first upload; core's `[:name, :parent_uuid]` unique index makes find-or-create race-safe.
- Optional host hook `config :phoenix_kit_staff, :attachments_parent_folder, {Mod, :fun}` (`fun(:person, actor_uuid, person_uuid)` or `fun(:person, actor_uuid)` → `{:ok, parent_uuid}` | `nil`) places **new** root folders under a parent. Lookups never depend on the hook's answer: the root folder is resolved by its person-unique name (configured parent, then root, then any parent), and purge removes every folder with that name, so an actor-dependent hook can't strand or twin-leak media.
- `PersonMediaComponent` (`kind: :files | :images`) opens core's `MediaSelectorModal` scoped to the folder. Both tabs are gated on `Storage.enabled?()` (rescued) at the tab and in every mutation handler; `valid_tabs/2` clamps deep links.
- Removal is non-destructive: soft-trash a sole-owner file, unlink a shared one, never hard delete. Permanent person delete purges the folder subtree (`Attachments.purge_person_media/1`); soft-trash keeps the files.
- Avatar is a single pointer in `Person.metadata["avatar_uuid"]` (no column) via `Attachments.{avatar_uuid, avatar_file, avatar_url, set_avatar, clear_avatar}`; the pointer is written as one key through core's `ResourceFolders.point_at/6` / `write_pointer/4`, never by replacing the metadata map from a struct (a stale one drops keys written since, such as `trashed_from_status`); `set_avatar/2` refuses a trashed person and any file that is not a live image in the person's own `Images` folder (the media tab's "set as avatar" sends a client-side uuid), checked and written under the file's row lock. `PersonShowLive` hosts the picker and logs `staff.person_avatar_set/removed`.

### Soft-delete (people)

- Sentinel `status = "trashed"` on the existing status column (`Person.soft_delete_status/0`), kept out of `Person.statuses/0` so the form dropdown stays `active`/`inactive`.
- `Staff` API: `trash_person/1` stashes the prior status in `metadata["trashed_from_status"]` (`{:error, :already_trashed}`); `restore_person/1` restores it (validated, else `"active"`; `{:error, :not_trashed}`); `delete_person/1` is the permanent delete, allowed only from the trashed state, and returns `{:error, :referenced_by_external}` on an FK or NOT NULL violation; `bulk_trash/1`, `bulk_restore/1`, `bulk_delete/1` are set-based; `create_person/1` returns `{:error, {:trashed_person_exists, person}}` on a trashed 1:1 match so the form can offer Restore.
- Scoping: `list_people/1` excludes trashed by default (`status: "trashed"` for the Trash view, `include_trashed: true` for all); `count_people/0` excludes trashed (`count_trashed/0` is separate); `org_tree/0`, `people_not_on_team/1`, `upcoming_birthdays/1` and team rosters exclude trashed; `eligible_users/1` still excludes trashed people's users (they come back through Restore, not re-create). Membership and assignment rows survive a trash.
- UI: `PeopleLive` "Trashed (N)" filter, per-row kebab (Restore / Delete permanently in the Trash view), core bulk-select with permanent delete behind `<.confirm_modal>`; `PersonShowLive` trashed banner with Restore / Delete permanently.

### Placeholder users

- The person form accepts any email. `Staff.find_or_create_user_by_email/1` creates a placeholder user (unconfirmed, random password, `custom_fields.source = "staff_placeholder"`); later registration or OAuth with the same email auto-links through core's email lookup.
- `Staff.create_person_with_user/2` rolls back a freshly created placeholder if the profile insert fails. `Staff.rename_placeholder_email/2` renames until claimed and refuses confirmed or non-placeholder users (`:placeholder_already_claimed`, `:email_already_taken`, `:blank_email`).

### Comments tab

- `PersonShowLive` does `use PhoenixKitComments.Embed`, which installs the hook forwarding the composer's `{:leaf_changed, …}` into `CommentsComponent.forward_leaf_event/2`; `{:comments_updated, _}` has an explicit no-op `handle_info/2`.
- Thread bound by `resource_type = "staff_person"` + `resource_uuid = person.uuid`.
- Gated at runtime on `PhoenixKitComments.enabled?()` (rescued); `valid_tabs/2` drops the tab when disabled and deep links fall back to Overview.

### Landmines

- `UrlState` assigns `:search` / `:status` before `mount/3`; re-assigning them in `mount` overwrites a shared link's state → leave them out of `mount` and load in `handle_url_state/2`.
- `<.multilang_fields_wrapper>` re-mounts on language switch, so a non-translatable field rendered inside it loses its value → render such fields as siblings outside the wrapper.
- `Ecto.Query.update/2` shadows `Employments.update/2` → the context imports `Ecto.Query, except: [update: 2]` and writes through `repo().update/1`; keep both when editing it.
- Dropping `use PhoenixKitComments.Embed` from `PersonShowLive` makes "Post comment" silently no-op (the Leaf event never reaches the component) → keep the `use` and its no-op `handle_info`.
- Person creation goes through `PhoenixKit.Users.Auth.register_user/2`, which calls the Hammer rate limiter → `test_helper.exs` starts `PhoenixKit.Users.RateLimiter.Backend`; without it every person-creating integration test fails at registration.

## Architecture

```
lib/phoenix_kit_staff.ex                # PhoenixKit.Module: key, enabled?, tabs, __tab_label_strings__
lib/phoenix_kit_staff/
├── activity.ex                         # Activity wrapper (log/2 under "staff", actor_uuid/1)
├── activity_labels.ex                  # Events-tab humanizer (action → {icon, label})
├── attachments.ex                      # Folder-scoped person media + avatar pointer
├── departments.ex / teams.ex           # CRUD contexts (list/1, get/1, create/1, update/2, delete/1)
├── skills.ex                           # Skill CRUD + person↔skill assignment (sole write path)
├── employments.ex                      # Employment spans + sync_current/1 (sole write path)
├── staff.ex                            # People CRUD, soft-delete, placeholder users, delegators
├── staff/memberships.ex                # Team ↔ person join (delegated from Staff)
├── staff/org.ex                        # org_tree/0, upcoming_birthdays/1 (delegated from Staff)
├── errors.ex                           # {:error, atom} → translated flash copy
├── gettext.ex / l10n.ex                # Own backend; dates, months, translations shape + lookup
├── paths.ex / pub_sub.ex               # /admin/staff/* paths; topics + broadcast helpers
├── schemas/                            # department, team, person, team_membership, skill,
│                                       #   person_skill, employment
└── web/                                # Live / FormLive / ShowLive trios per resource, OverviewLive,
                                        #   helpers.ex, person tab components (employment/media/events)
```

### Data model

| Schema (`PhoenixKitStaff.Schemas.*`) | Table | Notes |
|---|---|---|
| `Department` | `phoenix_kit_staff_departments` | top-level org unit; `name` unique case-insensitively |
| `Team` | `phoenix_kit_staff_teams` | belongs to exactly one Department |
| `Person` | `phoenix_kit_staff_people` | 1:1 `user_uuid` (unique); `status`; `primary_department_uuid` independent of memberships; `translations`, `metadata` JSONB; mirrored employment columns |
| `TeamMembership` | `phoenix_kit_staff_team_memberships` | person ↔ team, unique per pair |
| `Skill` | `phoenix_kit_staff_skills` | flat, translatable; `levels` JSONB selectors |
| `PersonSkill` | `phoenix_kit_staff_person_skills` | person ↔ skill; `proficiency_levels` JSONB; cascades on either delete |
| `Employment` | `phoenix_kit_staff_employments` | per-person span; one open span per person |

`Person.name` is a single nullable `VARCHAR(255)` display name on Person, not User: staff profiles have their own lifecycle and placeholder users are anonymous until claimed. No first/middle/last split (per-culture name parsing is out of scope).

### Contexts

- `Departments`, `Teams`: CRUD.
- `Skills`: skill CRUD and person↔skill assignment.
- `Employments`: span CRUD, the one-open-span invariant, `sync_current/1`.
- `Staff`: people CRUD and soft-delete, `eligible_users/1`, placeholder-user helpers, delegators to `Staff.Memberships` (`add_team_person/2`, `remove_team_person/1,2`, `list_team_memberships/1`, `list_memberships_for_person/1`, `people_not_on_team/1`), `Staff.Org` (`org_tree/0`, `upcoming_birthdays/1`) and `Skills`.

### LiveViews

`PhoenixKitStaff.Web.OverviewLive`, plus `Departments|Teams|People|Skills` × `Live`, `FormLive`, `ShowLive`. `PersonShowLive` hosts the tab components `PersonEmploymentComponent`, `PersonMediaComponent`, `PersonEventsComponent` and the comments thread; `Web.Helpers` holds the cross-LV helpers (failure-side logging, multilang form plumbing).

### PubSub

`PhoenixKitStaff.PubSub` on `PhoenixKit.PubSub.Manager`. Messages are `{:staff, event, payload}`; payload carries `:uuid` (bulk events carry `%{bulk: true}` on the collection topic only).

| Topic | Fan-out |
|---|---|
| `staff:departments`, `staff:department:<uuid>` | department events; team events also reach the parent department topic |
| `staff:teams`, `staff:team:<uuid>` | team events; team-membership events reach team **and** person topics |
| `staff:people`, `staff:person:<uuid>` | person events (`:person_employment_changed` included); bulk trash/restore/delete on `staff:people` only |
| `staff:skills`, `staff:skill:<uuid>` | skill events; person-skill events reach skill **and** person topics |

### Permissions and settings

- Permission key `"staff"` (`permission_metadata/0`: label Staff, icon `hero-users`) on every tab; LiveView events trust the mount-level check.
- Setting `staff_enabled` (boolean), toggled from Admin → Modules; read by `enabled?/0`.

## Database & migrations

None. Tables `phoenix_kit_staff_{departments, teams, people, team_memberships, skills, person_skills}` ship in core's V135 baseline and `phoenix_kit_staff_employments` in core's V136; `migration_module/0` is unset. A schema change is a core migration first, then schema edits here (run against `PHOENIX_KIT_PATH` until that core release is published). UUIDv7 PKs, `use PhoenixKit.SchemaPrefix` on every table-backed schema.

## Testing

Test DB `phoenix_kit_staff_test`. Three levels: unit (`test/phoenix_kit_staff/`, schemas, pure functions, module callbacks; always run), integration (`test/phoenix_kit_staff/integration/`, real PostgreSQL through the Ecto sandbox via `PhoenixKitStaff.DataCase`, tagged `:integration`), LiveView (`test/phoenix_kit_staff/web/`, `PhoenixKitStaff.LiveCase` against the test Endpoint + Router, also `:integration`).

- `test/test_helper.exs` starts the test Repo and builds the schema with `PhoenixKit.Migration.ensure_current/2` on every boot, so newly shipped core migrations apply without a setup step; then starts `PhoenixKit.PubSub.Manager`, `PhoenixKit.Users.RateLimiter.Backend`, pins the URL prefix to `/` and starts the test Endpoint (`server: false`). When `psql` reports no database or the Repo cannot start, `:integration` is excluded and `mix test` still passes. `mix test --exclude integration` runs unit only.
- Support (`test/support/`): `data_case.ex` (sandbox; `fixture_department/team/person/skill/skill_with_levels/skill_with_selectors/employment`; `errors_on/1`), `live_case.ex` (`fake_scope/1`, `put_test_scope/2`; reuses the fixtures), `activity_log_assertions.ex` (`assert_activity_logged/2`, `refute_activity_logged/2`, imported into both cases), a minimal `Test.Repo`, `Test.Endpoint`, `Test.Router` (scope `/en/admin/staff`, live_session `:staff_test`), `Test.Layouts`, and `Test.Hooks` (`:assign_scope` on_mount).
- Rules kept as tests: `test/core_pin_conformance_test.exs` (the `:phoenix_kit` pin keeps the compound `>= 2.38.0 and < 3.0.0` form — patch-precise floor, open ceiling; a three-segment pin excludes the next core minor and breaks hosts' `mix deps.get`; a committed `path:` dep fails it too) and `test/schema_prefix_conformance_test.exs` (every table-backed schema uses `PhoenixKit.SchemaPrefix`).
- Env honoured (`config/test.exs`): `PGUSER` / `PGPASSWORD` (default `postgres` / `postgres`), `PGHOST`, `PGDATABASE` (overrides the DB name), `PGPOOL` (pool size), `MIX_TEST_PARTITION`. On a brew Postgres without a `postgres` role, run `PGUSER=<your role> mix test`.
- Known noise: `redefining module PhoenixKitStaff.Test.*` warnings at boot; the support files are compiled through `elixirc_paths` and `Code.require_file`d again by `test_helper.exs` (needed because the test runner no longer auto-loads them at helper time).

## Feature notes

None. Feature rules live under Conventions; behaviour detail is in the `@moduledoc`s of `Staff`, `Employments`, `Skills`, `Attachments`, `PubSub` and `Web.Helpers`.

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.
- Every review leaves a paper trail: if feedback was applied before the review file was written, backfill `{AGENT}_REVIEW.md` from the review-fix commits; an "apply review fixes" commit message is not a substitute.

## TODOs

- `Person.work_schedule` JSONB (planned, not built): weekly Mon–Sun windows `%{"monday" => %{"start" => "09:00", "end" => "17:00"}}`, string keys and `HH:MM` strings; an absent key is a non-working day (writers omit, readers tolerate nil/empty); `%{}` means no override and consumers fall back to the projects module default. Availability metadata only, not a PTO/leave subsystem. Build it when a consumer needs per-person availability.
- `work_location` is displayed as the stored Location UUID on person show and in the employment timeline; resolve it to the location's name (when `phoenix_kit_locations` is loaded and enabled) the next time that surface is touched.
