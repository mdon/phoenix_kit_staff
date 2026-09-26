# Claude Review — PR #21 "Run on core's shared toolkits: person media on ResourceFolders, avatar fixes, actor and activity through core"

**Merge commit:** c504184
**Author:** Dmitri Don (mdon/main)
**Files:** 39 files — `Activity`, `Attachments`, `MediaReorganizer`, `Schemas.Person`, `Staff`, every staff LiveView (header trail, `open_on: :viewing_language`), `mix.exs` (core floor `>= 2.38.0 and < 3.0.0`), gettext catalogs, tests.

## Summary of the change

Moves the module onto core 2.38's shared toolkits: `Activity.log/3` and
`PhoenixKitWeb.Actor` replace the hand-rolled activity wrapper; person media
runs on `Storage.ResourceFolders` (find/ensure/attach/detach/purge, the avatar
pointer via `point_at/6` / `clear_pointer_if/4`); the reorganizer shrinks to a
`ResourceSource` spec. Avatar hardening: `set_avatar/3` only accepts a live
image held by the person's own `Images` folder, re-checks the person is not
trashed after the write, and `clear_avatar/2` clears only the pointer the caller
saw. Trash/restore become single UPDATEs that read the row as it is (no stale
whole-map metadata write), and `Person.changeset/2` re-reads the server-owned
metadata keys under a row lock. Every page gets the standard `page_section` /
`page_crumbs` header trail.

Checked the floor: core 2.38.0 (fetched from Hex) ships every function the PR
calls — `ResourceFolders.{find_under, find_named, ensure, attach, detach,
list_files, purge_named, parent_uuid, describe_failure, pointer_value,
pointed_file, point_at/6, clear_pointer_if/4}`, `ResourceSource.plan/3` with
`name_hook`, `Activity.log/3`, `Actor.uuid/1`, `Format.{bytes, file_icon}` and
`mount_multilang(open_on:)`. Core's `detach/2` keeps the removed `(_, nil)`
clause's behaviour (`{:ok, :absent}`). The restore `CASE … = ANY(?)` binds as
intended (`->>` outranks `=`).

## Findings

### 1. BUG - MEDIUM — `trash_person/1` / `restore_person/1` stopped bumping `updated_at`

The old versions went through `Ecto.Changeset.change |> repo().update()`, which
autogenerates `updated_at`. The new single-row `update_all` sets only `status`
and `metadata`, so trashing or restoring one person left `updated_at` at the
last profile edit — while `bulk_trash/1` / `bulk_restore/1`, the same operation
set-based, do set it. Anything ordering or syncing on `updated_at` (hosts,
`phoenix_kit_projects`' shadow schemas) missed the change, and the returned
struct carried the stale timestamp.

**Fixed:** both UPDATEs set `updated_at` and return it in the `select`, so the
struct handed back matches the row. Test: `soft_delete_test.exs` "trash and
restore both bump updated_at, like their bulk variants".

### 2. BUG - MEDIUM — the merged PR fails `mix precommit` (dialyzer)

Narrowing `trash_person/1` and `restore_person/1` to
`{:error, :already_trashed}` / `{:error, :not_trashed}` left
`PeopleLive.do_trash/2` and `do_restore/2` with a `{:error, reason}` clause
(failure-side log + "Could not …" flash) after the specific one. Dialyzer
reports both as `pattern_match_cov` (unreachable), so the gate the repo
requires before every commit exits 2.

**Fixed:** removed the two dead clauses. The only error each function can
return is still handled; a DB failure raises, as it did before through
`repo().update/1`. `PersonShowLive`'s `{:error, _}` catch-alls are reachable
and stay.

### 3. NITPICK — two spellings of the actor lookup

`PersonShowLive.set_avatar/2` and `PersonMediaComponent` called
`PhoenixKitWeb.Actor.uuid(socket)` directly for the folder actor, next to
`Activity.actor_uuid(socket)` (the same function, delegated) for the log row.

**Fixed:** both use `Activity.actor_uuid/1`.

### 4. NITPICK — `remove_file` treats `:absent` as a removal (not fixed)

`Attachments.detach/2` collapses core's `{:ok, :absent}` (file not in this
folder) into `:ok`, so a `remove_file` for a file that was never in the tab's
folder still logs `staff.person_*_removed` and runs `maybe_clear_avatar/2`.
Pre-existing (the old code also answered `:ok`), harmless — the avatar clear is
conditional on the pointer still being that uuid and the file had to be the
person's image to be pointed at. Surfacing the outcome would widen
`detach/2`'s return contract for a log-row nicety; left as is.

### 5. NITPICK — avatar picker vs. `holds_file?` scope (not fixed)

`MediaSelectorModal`'s `scope_folder_id` browses the folder's whole subtree,
but `point_at/6` → `holds_file?/3` checks the `Images` folder itself. An image
in a sub-folder someone created under `Images` from the media browser shows in
the picker but is refused with "Could not set the photo." Staff never creates
such sub-folders, so this needs manual folder-making in Media; recorded rather
than widening the authorization check.

### 6. NITPICK — "Profile photo removed" when none was set (not fixed)

`remove_avatar` with no pointer set still logs `staff.person_avatar_removed`
and flashes success. The button only renders when an avatar is shown, so it
takes a forged event or a race; pre-existing behaviour.

## Verified OK

- `keep_server_owned_metadata/1`: `prepare_changes` runs inside the write's
  transaction with `cs.repo`, the `FOR UPDATE` re-read makes a stale or
  param-supplied metadata map unable to set or drop `avatar_uuid` /
  `trashed_from_status`; inserts (`uuid` nil) skip the read.
- `confirm_not_trashed/2` closes the load-then-trash race by clearing only its
  own pointer.
- Header trail: show pages refresh their header assigns on PubSub; edit forms
  use the localized record name as the last crumb.
- Mount does no new DB work beyond what each page already loaded there.
