# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.9.0 - 2026-09-26

### Changed

- Requires `phoenix_kit` `>= 2.38.0 and < 3.0.0`. The module now runs on core's shared toolkits: activity logging goes through `PhoenixKit.Activity.log/3` and the actor through `PhoenixKitWeb.Actor` (the scope first, then the current user); person media folders, attach/detach, listing and purge go through `Storage.ResourceFolders`; the media reorganizer is a `Reorganizer.ResourceSource` spec (it never proposes host folder names); file icons and sizes come from `Utils.Format`.
- Edit forms open on the language the page is viewed in; new-record forms still open on the main language.
- Every staff page shows the standard admin header trail (Staff / list / record). A team's department is shown as a link on the team page instead of as the header section.
- `Attachments.set_avatar/3` takes the acting user, and `Attachments.clear_avatar/2` takes the file uuid to clear.

### Fixed

- A person's avatar only accepts a live image in that person's own `Images` folder. The media tab's "set as avatar" sends a client-side uuid, which could point the avatar at any file in storage.
- Setting or clearing the avatar writes only the avatar key, under the file's row lock, and re-checks the person was not trashed meanwhile. It no longer replaces the metadata map from a stale struct, which dropped keys written since (such as `trashed_from_status`).
- Removing an image no longer clears an avatar another session set since; the header refreshes only when the avatar actually changed.
- Trash and restore read and write the stashed status in the row itself, so a key written in between survives, and two sessions trashing at once get one success and one `:already_trashed`. Both still bump `updated_at`, like their bulk variants.
- The person form ignores a `metadata` param, and the person changeset keeps `avatar_uuid` and `trashed_from_status` as the row holds them whatever metadata map it is given.
- A failed avatar set is logged as `staff.person_avatar_set` on the failure side.

## 0.8.6 - 2026-09-16

### Added

- `PhoenixKitStaff.MediaReorganizer`, staff's plan source for core's media reorganizer (core 2.24+), registered via `media_reorganizer/0`. It plans moves of each person's `staff-person-<uuid>` folder under the `:attachments_parent_folder` hook's answer and reports duplicates, relocated copies, hook failures, root answers for parented folders, and orphaned folders of missing or trashed people. With no hook configured it only reports.

### Fixed

- Person folder lookups skip trashed folders. A trashed `staff-person-<uuid>` (or its `Images` subfolder) was still resolved, and as the older twin it won over a live folder beside it, so the Files/Images tabs showed the trashed folder and new uploads went into it.
- The parent-folder hook's answer is cast and downcased. An upper-cased uuid no longer loses to a root twin, and a non-uuid answer falls back to the root with a warning instead of failing every first upload.

## 0.8.5 - 2026-09-15

### Added

- Attachment folders can be created under a host-configured parent folder (`config :phoenix_kit_staff, :attachments_parent_folder, {Mod, :fun}`, called as `fun(:person, actor_uuid, person_uuid)` or `fun(:person, actor_uuid)`). Folders created at the root before the setting are still found and reused.

### Fixed

- Folder lookups no longer depend on the hook's answer. The Files/Images tabs resolved the folder without the actor while uploads created it with one, so a hook that varies by actor left uploaded media invisible after a reload, and a second admin got a twin folder. The person's root folder is now resolved by its person-unique name (configured parent, then root, then any parent).
- Permanent person delete purges every `staff-person-<uuid>` folder wherever it sits, instead of only the one under the parent the hook returned for a `nil` actor.
- The parent-folder hook now receives the person uuid as its subject (it was always `nil`) and a hook that exits falls back to the root like one that raises.

## 0.8.4 - 2026-09-13

### Fixed

- The 0.8.3 header rewrite pushed every page's title/subtitle/section/action into layout assigns core's admin layout renders in its breadcrumb bar, but the test layout never rendered them — 22 LiveView tests were asserting on text the page no longer emitted anywhere the test harness could see, and had been failing since 0.8.3 shipped. The test layout now renders stand-ins for those assigns.
- The `phoenix_kit_comments` 0.4.x admin check pattern-matches on a real `PhoenixKit.Users.Auth.User` struct; the test suite's fake scope wrapped a bare map, crashing the Comments tab test with a `FunctionClauseError`. The fake scope now wraps a real (in-memory) `User` struct.
- `test/test_helper.exs`'s Postgres-preflight fallback messages had `The reason is printed above. && mix test.setup` mashed onto the previous line with no line break; each path now prints a coherent message, and the header comment matches the current V135/V136 migration baseline instead of the pre-squash V40/V90/V100 chain.
- `mix.exs`'s core-pin comment still explained a `~> 1.7.231` floor that moved to `~> 2.0` in 0.8.0.
- `OverviewLive`'s birthday test accepted the page's ever-present subtitle text as a pass, so it never actually exercised the upcoming-birthdays branch; it now asserts the section's own heading.

## 0.8.3 - 2026-09-07

### Fixed

- Removed duplicate page headings across Staff admin pages (overview, people, departments, teams, skills, and every show/form page) — each repeated the page title already shown in the top breadcrumb bar.
- Fixed department/skill/team show pages' breadcrumb title not re-deriving after a rename.

## 0.8.2 - 2026-08-21

### Changed

- **`PersonShowLive` uses core's `<.nav_tabs>`.** The local `TabsStrip`
  (a copy of the component, including daisyUI 4's `tabs-boxed`) is
  deleted. Tab definitions are maps rather than `{value, label, icon}`
  tuples (#16).

## 0.8.1 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## 0.8.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

- `phoenix_kit_comments` raised to `~> 0.3` in step, for the same resolution
  reason as the core pin. Its 0.3.0 is a **security release** (stored XSS in
  comment bodies); see its CHANGELOG.

## [0.7.0] - 2026-08-05

The staff list's search and status filter now live in the **query string**, so
a filtered list is a real URL — shareable, reload-proof, and Back returns to
the previous query instead of leaving the page. Merged as PR #14, with a
post-merge review that raised the core requirement and added the test coverage
the PR shipped without.

**Requires `phoenix_kit ~> 1.7.231`** (raised from `~> 1.7.189`) for
`PhoenixKitWeb.Live.UrlState`, which `PeopleLive` now uses at compile time.
The previous pin allowed cores back to 1.7.189, none of which carry that
module — resolving one would have failed to compile the package. The hard dep
on `phoenix_kit_comments ~> 0.2` is unchanged.

### Added
- **URL-backed staff list state.** `PhoenixKitStaff.Web.PeopleLive` adopts core's
  `PhoenixKitWeb.Live.UrlState`: the search box publishes as `?q=` and the
  status filter as `?status=`, both omitted when unset so an unfiltered list
  stays at the bare path. Debounced typing collapses into a single history
  entry (`replace: true`); picking a status pushes a real one. `?status=` is
  whitelisted to the values the form offers and `Staff.scope_status/3`
  understands (`""`, `active`, `inactive`, `trashed`), so a crafted link falls
  back to the unfiltered list. Deep links to the Trash view now work.
- **Tests for the above** — 9 database-free tests pinning the declared spec and
  core's codec (including that the status whitelist stays in sync with
  `Person.statuses/0` + `Person.soft_delete_status/0`), plus 5 LiveView tests
  covering shared links, crafted input, and the patch written on filter/clear.

### Changed
- `PeopleLive` no longer queries in `mount/3`. The list load moved to
  `handle_url_state/2`, so the first render, a shared link and a Back press all
  take one path. The filter form gained the explicit `id` LiveView needs for
  form recovery.
- Raised the `phoenix_kit` requirement to `~> 1.7.231` (see above).

### Fixed
- Pruned eight stale `mix.lock` entries (`igniter` and its transitive closure —
  an *optional* dep of core) left behind by the dependency refresh; they were
  failing `mix precommit`'s `deps.unlock --check-unused` step.

## [0.6.0] - 2026-06-18

Post-0.5.0 person-profile features — a full **employment history**, person
**media** (Files / Images tabs + avatars), a read-only **Events** activity
feed, and a reshape of skill proficiency into **multiple named, translatable
level selectors** — plus a multilang-display restoration and soft-delete /
async hardening. Merged as PR #12, with a follow-up skills-localization fix.

**Requires `phoenix_kit ~> 1.7 and >= 1.7.159`** (raised from `>= 1.7.132`)
for the `phoenix_kit_staff_employments` table (V136), the `Activity.list/1`
`resource_uuid` filter (Events tab scoping), and the `MediaSelectorModal`
`browse` / filter-aware accept (Files / Images tabs). The hard dep on
`phoenix_kit_comments ~> 0.2` (person Comments tab) is unchanged.

### Added
- **Employment history (V136).** A per-person timeline of employment spans
  (`PhoenixKitStaff.Schemas.Employment`, `phoenix_kit_staff_employments`),
  surfaced as a dedicated **Employment tab** with add / edit / end / remove.
  Each span records `employment_type`, a translatable `job_title`, the org
  placement (`primary_department_uuid` + a `primary_team_uuid` snapshot), the
  date range (`employment_end_date` `nil` = the open/current span),
  `work_location`, and `notes`. A partial unique index enforces one open span
  per person; `PhoenixKitStaff.Employments` is the sole write path and
  denormalizes the current span onto `Person` via `sync_current/1`. New actions
  `staff.person_employment_added/updated/ended/removed`.
- **Files & Images tabs.** Folder-scoped person media via core
  `PhoenixKit.Modules.Storage` (no module table): a per-person
  `staff-person-<uuid>` root folder with a nested `Images` subfolder.
  `PhoenixKitStaff.Attachments` + `Web.PersonMediaComponent`; per-tab type
  enforcement (Images keep only images, Files only non-images), non-destructive
  removal (soft-trash a sole owner, unlink a shared file). New actions
  `staff.person_file_added/removed`, `staff.person_image_added/removed`.
- **Avatars.** A circular profile photo in the show header (initials
  fallback), backed by an image pointer in `Person.metadata["avatar_uuid"]`,
  settable from the Images tab; new actions `staff.person_avatar_set/removed`.
- **Events tab.** A read-only, paginated `PhoenixKit.Activity` feed scoped to
  the person (`Web.PersonEventsComponent` + `ActivityLabels`), with an
  "Open in Activity log" deep link.

### Changed
- **Skill levels → multiple named selectors.** A skill's `levels` reshapes from
  a single flat option list (+ a skill-wide `allow_multiple_levels` flag) into
  an ordered list of named **selectors**, each with its own translatable name,
  single-vs-multiple toggle, and ordered translatable options (e.g. a "Driving
  licence" skill can carry "Licence category" B/C/D alongside a "Proficiency"
  ladder). JSONB-only — no migration; `Skill.level_groups/1` read-wraps any
  legacy flat list into one default selector, so existing rows and assignments
  keep working until re-saved. The skill form gains a staged selector editor
  with per-language name inputs, per-selector single/multiple toggles, and
  drag-and-drop reordering.
- **Person edit form simplified.** The employment fields, department picker,
  and `job_title` move to the Employment tab (the open span drives the
  denormalized `Person` mirror); only `status` + the single team-membership
  picker remain on the form.

### Fixed
- **Multilang display restored and completed.** The 0.5.0 reshape had silently
  dropped the `localized_*/2` read path (per-language overrides went
  write-only); restored `L10n.current_content_lang/0` and re-wired the
  department / team / person read LVs + the employment component. Extended the
  same wiring to the **Skills list and Skill show pages**, which still rendered
  the primary `Skill.name` / `description` even though both are translatable —
  so skill names now localize consistently with the person profile.
- **Soft-delete create-path guards.** `Employments.create/2`,
  `Attachments.set_avatar/2`, and the media-attach path now refuse a trashed
  person, mirroring the existing skills / team-membership guards (update /
  remove paths stay open for cleanup).

## [0.5.0] - 2026-06-15

Structured skills taxonomy with per-skill dynamic proficiency levels,
soft-delete for people, a Comments tab on the person profile, and an
admin-UI quality sweep (kebab row menus + core empty-states). Merged as
PR #10.

**Requires `phoenix_kit ~> 1.7 and >= 1.7.132`** for the `metadata` JSONB
column (V131, soft-delete stash) and the `phoenix_kit_staff_skills` /
`phoenix_kit_staff_person_skills` tables (V135). Adds a hard dep on
`phoenix_kit_comments ~> 0.2` for the person Comments tab.

### Added
- **Structured skills.** A first-class, translatable `Skill` taxonomy
  (`phoenix_kit_staff_skills`, globally unique `lower(name)`) replacing
  the old free-text `Person.skills` (V135 migrates + drops it). Each
  skill defines its **own** proficiency levels — a `levels` JSONB array
  of translatable `%{"id", "name", "translations"}` maps with stable ids
  plus an `allow_multiple_levels` boolean. New context
  `PhoenixKitStaff.Skills` (skill CRUD + person↔skill assignment), new
  schemas `Skill` + `PersonSkill` (join carrying a `proficiency_levels`
  array of selected level ids), and thin `Staff` delegators.
- **Skills admin subtab** with `SkillsLive` / `SkillFormLive` /
  `SkillShowLive`. Assignment works from two directions: the skill show
  (skill → people, event-driven level toggle chips persisted
  immediately) and the person edit form (person → skills, staged
  multi-select reconciled to the DB on save).
- **Soft-delete (people).** `trash_person` / `restore_person` (sentinel
  `status = "trashed"`, prior status stashed in
  `metadata["trashed_from_status"]`), permanent `delete_person` (Trash
  view only), and set-based `bulk_trash` / `bulk_restore` /
  `bulk_delete`. `list_people/1` excludes trashed by default;
  `count_trashed/0` is separate. `PeopleLive` gains a "Trashed (N)"
  filter, core bulk-select, and a per-row kebab; `PersonShowLive` shows
  a trashed banner with Restore / Delete-permanently.
- **Comments tab** on `PersonShowLive` via the `phoenix_kit_comments`
  embed (`use PhoenixKitComments.Embed` for Leaf-event forwarding).
- New activity actions: `staff.person_trashed/restored`,
  `staff.people_bulk_trashed/restored/deleted`,
  `staff.skill_created/updated/deleted`,
  `staff.person_skill_added/removed/updated`.

### Changed
- **Admin-UI sweep.** Row actions across Departments / Teams / People /
  team-show / overview moved to the core `<.table_row_menu>` kebab; the
  seven hand-rolled empty-state blocks now use the core `<.empty_state>`
  component. `staff.person_deleted` now means the **permanent** delete.
- `Staff` context split: team-membership and org-tree logic extracted to
  `PhoenixKitStaff.Staff.Memberships` and `PhoenixKitStaff.Staff.Org`.
- `mix.exs`: `phoenix_kit` constraint widened to
  `~> 1.7 and >= 1.7.132`; added `phoenix_kit_comments ~> 0.2`; deps now
  resolve through the `pk_dep/3` `<APP>_PATH` cross-repo override helper.
- People-list search input is now debounced (`phx-debounce="300"`), and
  the soft-delete handlers no longer reload the list twice per action
  (the PubSub broadcast already drives a single reload).
- Refreshed the dependency lock: `phoenix_kit` 1.7.146,
  `phoenix_live_view` 1.2.1, `phoenix_kit_comments` 0.2.8 (plus
  transitives — `phoenix` 1.8.8, `bandit` 1.12, `req` 0.6.1,
  `tesla` 1.20, `tessera` 0.3.1, `credo` 1.7.19). `mix.exs` re-adds
  `priv` to the package `files:` list (ships the `priv/gettext`
  catalogs) and re-wires `.dialyzer_ignore.exs` via `ignore_warnings:`.

## [0.4.0] - 2026-06-04

Internationalization release — the staff module now owns a Gettext
backend with Estonian + Russian translations, and the multilang
free-text overrides finally render in the UI.

### Added
- **`PhoenixKitStaff.Gettext` backend** for staff-specific (domain) UI
  strings, with full **Estonian (et)** and **Russian (ru)** catalogs in
  `priv/gettext` (146 msgids each, plurals included). Generic strings
  already translated workspace-wide stay routed to core's
  `PhoenixKitWeb.Gettext` (the hybrid-backend pattern). Admin `%Tab{}`
  labels carry `gettext_backend:` and stay extractable via
  `PhoenixKitStaff.__tab_label_strings__/0`.
- **`PhoenixKitStaff.L10n.current_content_lang/0`** — resolves the active
  content language (`Gettext.get_locale/1`) for read-path translation
  lookups, mirroring `phoenix_kit_projects`.

### Changed
- **Localized read paths.** The overview, list, and show LiveViews now
  render Department/Team names + descriptions and Person job titles, bios,
  skills, and notes through their `localized_*/2` helpers (primary-column
  fallback), so the `translations` JSONB overrides entered in the forms
  are actually displayed in the browsing locale. Previously these helpers
  had no callers and the overrides were write-only.

### Fixed
- **Hex packaging:** `priv` is now included in the package `files:` list,
  so published builds ship the `priv/gettext` catalogs. Without it the
  compiled Gettext backend had an empty catalog for Hex consumers and
  every staff string fell back to English.
- Dropped a dead `preload: [:teams]` in `DepartmentShowLive`.
- `mix.exs` now wires `.dialyzer_ignore.exs` explicitly via
  `ignore_warnings:` (matching `phoenix_kit_projects`).

## [0.3.0] - 2026-05-29

Feature release — multilingual free-text fields, a single full-name
column, and a soft dependency on `phoenix_kit_locations` for the work
location. All changes are additive and backward-compatible with the
documented public API (`Staff.list_people/1`,
`Staff.get_person_by_user_uuid/2`, `Teams.list/1`, `Departments.list/1`).

**Requires `phoenix_kit ~> 1.7.125`** for the V122 migration that ships
the `translations` JSONB columns and `phoenix_kit_staff_people.name`.

### Added
- **Multilang translations** on Department, Team, and Person. Each
  schema carries a `translations` JSONB column for non-primary-language
  overrides on a subset of free-text fields (Department/Team: `name`,
  `description`; Person: `job_title`, `bio`, `skills`, `notes`).
  `<Schema>.localized_<field>/2` read helpers apply primary-fallback
  semantics; forms use the shared `<.multilang_tabs>` /
  `<.multilang_fields_wrapper>` / `<.translatable_field>` components.
- **`Person.name`** — a single nullable `VARCHAR(255)` full display
  name, consistent with `Department.name` / `Team.name`. Owned by the
  staff profile so placeholder users stay anonymous until claimed.
- **`Person.display_name/1`** — canonical people label (name → linked
  user's first/last → email → "Unnamed"), used across the people list,
  org overview, birthdays, person show, and team show.
- **`PhoenixKitStaff.L10n.validate_translations/1` and
  `localized_field/3`** — shared translation read/validate helpers
  (the schemas now delegate instead of carrying private copies).
- `Staff.list_people/1` search now matches `name` in addition to the
  linked user's email.

### Changed
- **`Person.work_location` is now a soft dependency on
  `phoenix_kit_locations`.** The form renders a Location picker sourced
  via a runtime guard (`Code.ensure_loaded?/1` + `function_exported?/3`
  + variable-module dispatch, so the optional dep is never referenced at
  compile time) and hides the field entirely when the locations module
  isn't installed or is disabled. The column stays `VARCHAR` (UUID
  stored as a string) to avoid a type-changing migration.
- `Person.skills` is now a free-form textarea (was single-line).
- **Style sweep** across all 10 admin LiveViews: full-width
  (`w-full px-4 py-N`) layout with `<.admin_page_header>` + `<:actions>`,
  forms capped at `max-w-3xl mx-auto`; fixed an invisible
  hover-badge bug on the Overview page on light themes.
- Tightened the `phoenix_kit` constraint to `~> 1.7.125` (was `~> 1.7`)
  so installs can't resolve a pre-V122 core; refreshed the dependency
  lock (`phoenix_kit` 1.7.125, `phoenix_live_view` 1.1.31,
  `ecto_sql` 3.14.0).

### Fixed
- Overview / Person show now display the person's name rather than
  always falling back to the linked user's email.

## [0.2.1] - 2026-05-12

Maintenance release — dep bumps, migration-shim cleanup, test repair,
and a documented heads-up for the upcoming `Person.work_schedule`
JSONB column. No public-API changes.

### Changed
- Bumped `phoenix_kit` to `~> 1.7.108` (from `1.7.106`); refreshed
  transitive deps (`postgrex` 0.22.2, `finch` 0.22.0, `ex_ast` 0.11.2,
  `swoosh` 1.25.2, `telemetry` 1.4.2, plus new transitives
  `tessera`/`fresco`).
- Test infra: `test/test_helper.exs` and `config/test.exs` now lean on
  `PhoenixKit.Migration.ensure_current/2` directly — no module-owned
  DDL or hybrid migration shim.

### Removed
- `priv/repo/migrations/20260427000000_setup_phoenix_kit.exs` — the
  hybrid migration shim is gone. Test setup applies core's versioned
  migrations on every boot.

### Fixed
- `PersonFormLive` audit-row tests realigned for LiveView 1.1.29.

### Docs
- `AGENTS.md`: documented the planned `Person.work_schedule` JSONB
  column (shape, canonical "non-working day" representation, default
  empty map) as a heads-up for the cross-module `phoenix_kit_projects`
  follow-up. No schema change in this release.

## [0.2.0] - 2026-04-30

Quality sweep + re-validation pipeline (PRs #2 and #3) plus the
post-merge follow-up: form-Save audit rows, Errors fallback warning,
Helpers merge-precedence fix.

### Added
- `PhoenixKitStaff.Errors` — atom → translated-string dispatcher.
  Context functions now return `{:error, atom}`; LiveViews call
  `Errors.message/1` at the presentation boundary. Unknown-atom
  fallback emits a `Logger.warning` so drift is loud in dev/staging.
- `PhoenixKitStaff.Web.Helpers` — `log_operation_error/3` writes a
  failure-side activity row with `db_pending: true` and PII-safe
  reason metadata. Resolves the tension between the module's
  documented success-only `Activity` invariant at the call site and
  the post-Apr pipeline's both-branch audit-row requirement. Wired
  into all 5 destructive listing actions plus all 6 form Save error
  branches (department / team / person × create + edit).
- `@type t` on every Ecto schema; 41 new `@spec`s across the public
  context and helper modules.
- Test infrastructure under `test/support/`: `Test.Endpoint`,
  `Test.Router`, `Test.Layouts`, `DataCase`, `LiveCase`, `Hooks`,
  `ActivityLogAssertions`. `lazy_html` test-only dep for
  `Phoenix.LiveViewTest` HTML parsing.
- `mix test.setup` / `mix test.reset` aliases for local DB bootstrap.

### Changed
- **BREAKING (return-shape):** `Staff.rename_placeholder_email/2`
  now returns `{:error, atom}` (`:blank_email`,
  `:placeholder_already_claimed`, `:email_already_taken`) instead of
  `{:error, binary_message}`. Callers must route through
  `PhoenixKitStaff.Errors.message/1` at the presentation boundary.
- `Helpers.log_operation_error/3` metadata-merge precedence: caller-
  supplied metadata is now merged UNDER the helper-owned keys
  (`db_pending` / `error_kind` / `error_keys` / `error_atom`) so
  audit-feed readers can rely on those keys being authoritative.
  `:resource_uuid` opt is now optional (failed CREATE submissions
  have no uuid yet).
- `PhoenixKitStaff.Activity.log/2` rescue widened to canonical
  post-Apr shape: explicit `Postgrex.Error -> :ok` and
  `DBConnection.OwnershipError -> :ok` ahead of the generic
  `Logger.warning` branch, plus `catch :exit, _ -> :ok`.
- `PhoenixKitStaff.enabled?/0` adds `catch :exit, _ -> false` for
  sandbox-shutdown safety.
- `handle_info/2` catch-all in all 7 admin LVs promoted from silent
  `{:noreply, socket}` to `Logger.debug(...)`.
- `Staff.next_birthday_and_days/2` extracted shared
  `anniversary_in_year/2` helper that mirrors Postgres `INTERVAL '1
  year'` arithmetic.
- `Staff.org_tree/0` collapses `MapSet` build via `MapSet.new/2`.

### Fixed
- **Schema constraint name mismatch in `Schemas.Person.changeset/2`**
  (HIGH). The DB index is `phoenix_kit_staff_people_user_index`,
  but the changeset registered the Ecto-default
  `phoenix_kit_staff_people_user_uuid_index`, so duplicate
  `user_uuid` inserts raised `Ecto.ConstraintError` instead of
  returning `{:error, %Ecto.Changeset{}}`. Changeset now passes
  `name: :phoenix_kit_staff_people_user_index` explicitly.
- **`PersonShowLive.handle_info/2` had no catch-all** (MEDIUM). Any
  non-`{:staff, ...}` message reaching the LV's mailbox would have
  raised `FunctionClauseError`. Catch-all clause added.
- **Subscribe-after-fetch race on the 3 show pages** (LOW).
  `department_show_live` / `team_show_live` / `person_show_live`
  now subscribe BEFORE the DB read so a broadcast in the gap
  doesn't get silently dropped.
- **Leap-day display drift in `next_birthday_and_days/2`** (LOW).
  Wrap-to-next-year branch was unconditionally clamping Feb 29 →
  Feb 28 even when the target year was a leap year. Display now
  matches the Postgres SQL window filter exactly.
- **`Schemas.Team.changeset/2`** changes `unique_constraint` from
  `[:department_uuid, :name]` (composite list — error attached to
  the first field) to `unique_constraint(:name, name: ...)` so
  inline form errors render below the field the user actually edits.

### Performance
- `Staff.org_tree/0`: `MapSet.new(list, mapper)` skips an
  intermediate list allocation.

### Tests
- 49 → 302 tests, 0 failures, 5/5 stable.
- `mix test --cover`: 62.64% → **95.07%** line coverage.
- New test files cover: per-atom `Errors.message/1` pins, helpers
  unit tests with PII-safety assertions, error-branch logging,
  per-LV `handle_info` catch-all `Logger.debug` pins,
  subscribe-before-fetch source-pairing meta-test, edge-case
  Unicode/SQL-metacharacter inputs, all listing LVs, all form LVs
  with both happy-path AND failure-side audit-row pins.

### Internal
- `mix.exs` `test_coverage [ignore_modules]` filter so
  `mix test --cover` reports production-only coverage.
- `test_helper.exs` rescues `ErlangError` from `System.cmd("psql",
  ...)` so `mix test --exclude integration` works in environments
  without `psql` on PATH.

## [0.1.0] - 2026-04-20

Initial release.

### Added
- `Departments` context: list/create/update/delete with PubSub broadcasts.
- `Teams` context: list/create/update/delete with department scoping and
  PubSub broadcasts.
- `Staff` context: people CRUD (`Person` schema), team membership
  management, `upcoming_birthdays/1`, `org_tree/0`, and placeholder-user
  flow with transactional rollback.
- Activity logging via safe wrapper pattern, called at the LiveView layer.
- PubSub topic scoping for departments, teams, and people.
- Integration test suite (auto-excluded when `phoenix_kit_staff_test` DB
  is unavailable), including coverage of `upcoming_birthdays/1` (window
  boundaries, today / leap-day / wrap-around DOBs, inactive / nil-DOB
  exclusion, sort order) and `org_tree/0` (team-grouped, dept-only, and
  fully-unassigned buckets).
- `AGENTS.md` with project overview, conventions, testing, and PR policy.

### Performance
- `Staff.upcoming_birthdays/1` filters the day window in Postgres via
  interval arithmetic; only rows inside the window come back.
- `Staff.org_tree/0` loads `TeamMembership` once and derives both the
  team-grouped and unassigned shapes in memory.
