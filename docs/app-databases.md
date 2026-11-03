# Per-app databases

Status: design, 2026-11-03. Companion to `docs/app-sdk.md`.

Question: can each app own its database while a JawnOS server is running, with `database_grabber()`
able to reach them, the backup rounding them all up and sync grabbing all the data?

**Yes — with a core/app split, one connection with attached schemas, and a table registry.** It is
not "one SQLite file per app and hope"; the three rules below are what make it safe.

## Three rules

1. **Core stays shared.** `appointments`, `continent`, `settings`, `devices`, `remote_machines`,
   `credentials`, `security`, `cache`, `sync_*`, `where_*` are the substrate every app reads. They
   stay in `database/jawnos.db`.
2. **Each app owns only its own normalized tables**, in `database/apps/<name>.db`. A table lives in
   exactly one place; the registry says where.
3. **No raw cross-database access from app code.** An app reads core tables through the host and
   another app's data only through a declared capability (or a core read model such as `continent`).

Rule 2 is the one people skip. Most apps today store their data as rows in `appointments` with an
`app` column (a gallery photo is an appointment with a file, a travel map is an appointment with a
scale). Creating `gallery.db` before normalizing those rows changes nothing. The per-app database is
the *destination* of a normalization, not a new place to put the same blob.

## The handle: one connection, many schemas

`database_grabber()` (`Domain/Key.pm:377`) is already a good seam: one handle per process, an inode
check so a replaced database is not served from a dead file, abandoned statements finished before the
handle is reused. Keep all of that and add attachment:

```perl
sub database_grabber {
    my ($app) = @_;          # no argument = core, exactly as today
    ...
    # after the core handle is open (or reused):
    $sql->db->query("attach database ? as app_$app", $path) unless attached($app);
    return ($db, $database, $sql);   # unchanged shape for every existing caller
}
```

- **One connection, not one per app.** SQLite `ATTACH` gives several schemas on one connection, so a
  transaction can span them and every query sees the same snapshot. A separate connection per app
  would lose both.
- **Re-attach on the same boundaries the holder already uses**: a fork, or the core file being
  replaced. `pragma database_list` is the source of truth; keep the app paths in the holder.
- **Per-schema WAL and busy timeout** (`app_gallery.db-wal`, `-shm`). `database_tidy`
  (`Domain/Key.pm:307`) currently shreds anything under `database/` that is not `jawnos.db`,
  `schema.sql`, `initial.enc` or `backups/` — it must whitelist `database/apps/*.db` and their
  sidecars in the same change, or the first tidy deletes every app database.
- **No cross-database foreign keys.** SQLite does not enforce them. Reference `<app>.<table>.uuid`
  in code, and validate on write through the host.
- **Transactions.** `BEGIN` on the one connection covers every attached schema. SQLite's
  multi-database crash atomicity is not something to build on: assume a crash can leave one schema
  ahead. Write idempotently, and put cross-database effects on an outbox the host replays.

## Addressing tables

Raw SQL cannot be routed automatically, so the contract is explicit:

- `db_select`, `db_insert`, `db_update`, `db_delete` take a table name and consult the registry:
  core tables stay bare; an app table is rewritten to `app_<name>.<table>`.
- `db_query` is the raw escape hatch. Legacy core SQL is unchanged; new app SQL must qualify
  (`select ... from app_travel.maps`). A bare name that is not core is an error, not a guess.
- `$host->db->table_schema('maps')` returns `app_travel`; `$host->db->tables($app)` lists what the
  app may write.
- The manifest's `tables` list is the registry's input. An app may not write a table it did not
  declare; the host refuses at the API boundary.

## Backup: one file, many databases

The current backup (`Domain/Backup.pm:55`) builds a windowed copy of every table in memory, vacuums
it and exports an encrypted snapshot; the export lock already serializes remote snapshots. Per-app
databases fit that model with one addition: the bundle must carry a manifest.

- Take the existing export lock (so no writer is moving), then snapshot each schema. Per database:
  `VACUUM INTO` a temp file (or `sqlite3 .backup`), then `wal_checkpoint(TRUNCATE)`.
- Bundle them — one encrypted archive (`<snapshot>.enc`) containing `core.db`, `apps/<name>.db`,
  and `manifest.json`:
  `{ snapshot_id, created_at, schema => ..., dbs => [ { name, file, size, sha256, schema_version } ] }`.
- One row in `backups` names the bundle. The manifest is what makes a partial restore detectable;
  restore verifies every member before swapping any.
- Restore stages all members, checks the manifest, then swaps under the export lock. A failure at
  any point leaves the running set untouched.
- The nightly reconciliation and the "download a backup" path keep working because they deal with
  the bundle, not with a table list.

## Sync: a descriptor, not a filename

Sync is already table-oriented (`sync_table_list`, `sync_table_digest`, buckets, `sync_log`), which
is the right shape. It needs one dimension added:

- The unit becomes `{ db => 'core'|'travel'|..., table => 'maps' }`. `sync_table_list` walks
  `sqlite_master` per attached schema instead of only `main`.
- `sync_log` gains a `db` column (or stores `db.table` in `tbl`). Keep one central log in core: it
  preserves the single per-peer cursor in `sync_cursors` and the tombstone purge, and avoids a new
  log per app with its own GC.
- `sync_table_digest`/buckets key on `db.table`. The row batches carry `db`; the receiver routes
  them through the same registry.
- Protocol bump: `sync_version = 4`. A peer that only knows 3 is served core tables and told the
  rest is unavailable; mixed houses keep syncing.
- App install/removal is a synced fact: a `app_manifest` setting lists `{ name, version, dbs }`, so
  peers create the schema (empty) before rows arrive, and a removed app's rows are tombstoned.
- Deletion keeps the existing rule: a row is written to `sync_log` before it is deleted; the
  tombstone names `db.table`.

## Cross-app reads

The example — Travel records its own landmarks, and also wants the location recorded for every
appointment — splits cleanly:

- **`continent` is core.** It already holds `latitude`, `longitude`, `accuracy`, `timestamp`, `type`,
  `scope`, `app`, `uuid`. Any app may read it through the host; it records through
  `$host->locations->record(...)`, not with raw SQL.
- **Travel-owned places stay in `travel.db`** (`maps`, `home_plates`, `landmarks`), joined to core by
  `continent.uuid` in code.
- **Another app's private places** are reached through a declared capability:
  `provides => { places => 'JawnOS::App::Travel::API' }`, `$host->app('places')->near($lat, $lon)`.
  No app gets a handle to another app's schema.

That keeps the modularity the user wants (uninstall Travel and its file goes; the core location log
remains) without turning every app into a consumer of every other app's internals.

## Migrations

- Each database gets its own `migrations` table (or a per-schema `schema_version`). The host runs
  core first, then apps in declared dependency order.
- Moving a table out of core is a four-step migration, never a rename:
  1. create the table in the app schema and copy rows;
  2. dual-write (or backfill on a schedule) while reads still come from core;
  3. switch reads to the app schema, keep a compatibility view in core for one release;
  4. drop the core table and its sync entries.
- `database_tidy`, backup, sync and restore learn the new schema in the same change as the first
  moved table — not later.

## Phases

| Phase | Work | Acceptance |
|---|---|---|
| 0 | Registry + `ATTACH` in `database_grabber`, `db_select` routing, `database_tidy` whitelist, no new DBs | Existing suite green; a test attaches an empty app DB and reads/writes one table |
| 1 | Gallery (the SDK pilot) gets `gallery.db` for albums/photos/tags | Gallery works embedded and standalone; core rows unchanged |
| 2 | Travel gets `travel.db` (maps, home plates, landmarks); reads core `continent` | No cross-schema FK; capability `places` resolves |
| 3 | Embedded gets `embedded.db` (boards, jobs, firmware) | BLE/OTA still work with the host capability |
| 4 | Music last (tracks/playlists), or stays host-only | Decision, not an obligation |
| 5 | Sync v4 (`db.table` descriptors, `db` in `sync_log`) and the multi-DB backup bundle | Two houses sync and restore across two schemas |

Phase 0 is invisible: attaching an empty schema changes no query. Phase 5 must land before a second
app database ships to a peer, or a peer will silently sync only core.

## Risks

1. **Cross-database atomicity.** One connection is one transaction, but a crash can leave schemas
   out of step. Idempotent writes and an outbox are cheaper than pretending otherwise.
2. **No cross-database foreign keys.** Enforce in code; a dangling `place_uuid` is a real failure
   mode.
3. **Backup consistency.** The bundle is only as good as the lock that produced it. The existing
   export lock must also cover local writers, or a backup can pair an old core with a new app.
4. **Sync protocol churn.** A version bump that half the house ignores is a split brain. Serve v3
   peers core-only and make the version explicit in the handshake.
5. **Migration cost.** Moving rows out of `appointments` touches every reader (`sync`, search,
   Guide). Compatibility views for one release are the insurance.
6. **`database_tidy` and shredding.** Every new file is a file that must be whitelisted, backed up
   and shredded on leave. A missed sidecar is either deleted data or a leaked secret.
7. **Performance.** Attached schemas are cheap, but more WAL files mean more checkpointing and more
   file handles. Measure the write path (the appointment log) before and after.
8. **The empty-database trap.** A new DB with no normalized tables buys nothing. The value starts at
   Phase 1, when Gallery's own tables exist.

## What this changes in the SDK

- `JawnOS::Host::DB` is the registry: `for($app)`, `table_schema($table)`, `tables($app)`,
  `attach($app)`, `detach($app)`.
- `manifest->{tables}` becomes load-bearing (it is the write allowlist), and `manifest->{db}` says
  whether the app owns a schema.
- `Host::Solo` simply has one schema per app and no core mesh; the same code path.
- `JawnOS::Server` can start an app whose schema is missing by running its migrations.

The app SDK remains the goal; per-app databases are how it stops being a UI split and becomes a real
modular boundary.
