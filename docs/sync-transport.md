# Sync transport

Normal deltas between peers use the **v3 row stream**. The encrypted SQLite
snapshot remains the **full-migration / deep-gimme / v2 / archive** path.

## v3 (default when a peer advertises `sync_version >= 3`)

- The handshake (`/manager/remote_auth_test`) returns the per-table digest
  (`count`, `sum(server_time)`, `max`) and `sync_version: 3`.
- `sync_plan` turns the digest difference into a per-table cut. A table whose
  picture matches is not pulled; `continent`, `ai_budget`, `ai_jobs`, `ai_house`
  and `notifications` are **carry-only** (always ride a pull, never trigger one).
- `Manager::sync_rows_pull` asks `GET /manager/sync_rows` for one table at a time,
  500 rows per batch, cursor = the last rowid received. A dropped link retries the
  batch; a 4xx is the peer's answer and is not retried.
- Each batch is Sereal+zstd, sealed with the level-1 security credential (the same
  secret the snapshot container uses). The peer rail is TLS with `insecure(1)`, so
  transport TLS alone is not trusted for rows.
- The consumer runs the shared `merge_table_rows` / `merge_finish`, then writes its
  local `backups` watermark and `sync_seen`. If a pull is short, the watermark does
  not move and the next tick retries.
- Settings ride with an appointment pull and merge first, so an appointment window
  never opens against an app with no configuration. A machine with no settings at
  all gets the whole table once.

## Snapshot (fallback, unchanged)

- `full=1` migrations, windowed `gimme` deep pulls, and v2 peers use
  `backup_now` / `backup_serve` / `merge_database`: build a temp SQLite, encrypt,
  transfer, decrypt, merge.
- Backups (`database/backups/`) use the same container.

## Topology

`sync/topology` is house-wide (Configure -> Dev -> Sync topology; the `sync` app is
not protected, so the settings merge carries it). Values: `auto`, `mesh`, `hub`.

- `auto`: a spoke dials the hub and any peer on its own LAN while the hub's last
  handshake is under 6 minutes old and, if the hub is tunnelled, the tunnel has a
  fresh pong. Otherwise it falls back to the full mesh.
- The hub always walks the whole roster.
- `sync_hub` (local `__president`) remembers the chosen server signatorial.
- On mobile data there are no LAN peers, so `auto` is effectively hub-only.

## Measuring

- `sync_jobs.note` distinguishes `rows merged` (v3) from `snapshot merged` /
  `snapshot served` (file path).
- `backups.size` records the sealed wire bytes of a v3 pull.
- The digest is a per-table `count/sum/max` scan. `sync_digest_map` caches it for
  30s per worker; on a 37k-row settings table a raw scan is a few tens of
  milliseconds on a phone.
