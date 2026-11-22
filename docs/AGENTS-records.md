# Records and database integrity (moved from AGENTS.md)

Read this before repairing appointments or restoring a database.

## A database is per device

- **The database is per device — never restore one machine's `jawnos.db` onto another.**
  `devices`, `remote_machines`, `tunnels`, `tickets`, `backups`, the per-device `settings`, the sync
  cursors and the session rows are that machine's own view, not shared house data. A cross-machine
  restore leaves the target wearing the source's self row and peer list — on 2026-10-20 the phone was
  restored from the laptop's database, so its `devices` table held the laptop's `vivotop` row with no
  `localhost` row and its `remote_machines` was the laptop's list minus the laptop itself; Scan then
  silently added nothing. Restore only onto the same machine. After a cross-machine restore, repair
  the identity before trusting the panel: keep exactly the machine's own `devices` row, add every
  other machine as a **direct** `remote_machines` peer from the target's own LAN view, drop the
  source's stale rows, and review `tickets`, `backups` and `tunnels` for the source's paths. The
  missing-self-row scan bug is fixed in v0.1.1006; the identity repair is still manual.

## A backfill re-stamped server_time

- **A sync band is a server_time range; one bad write can collapse it.** On 2026-11-21 the settings
  backfill that matched every row also re-stamped 41k appointments to two server_time values, so the
  current week's band held 42k rows and every change read it again. `perl
  scripts/appointments_time_repair.pl` is a dry run by default; `--apply --backup <older snapshot>`
  restores only server_time, for rows whose every other column still matches the snapshot, and refuses
  to guess without an older snapshot and a fresh safety snapshot. `--window-start <ms>` names the
  incident's first stamp when the automatic burst is ambiguous. **Run it on every machine in the same
  window**: the merge keeps the newer server_time, so an un-repaired peer puts the incident stamp back.
  A phone or tablet should use `--sql`: it keeps the 121k-row comparison inside SQLite instead of loading
  it as Perl hashes (the first house-wide run OOM'd on the phone). `--include-changed` also restores the
  snapshot time for rows whose other columns changed; use it when those changed rows are themselves the
  reservoir that keeps re-stamping the repaired ones (the 2026-11-21 appointments incident needed it). It
  moves the write time; the data itself is not touched. The settings half of the same incident is
  `scripts/settings_time_repair.pl`.

## SMS direction in the mailbox

- **A phone row's status is its direction.** `scripts/mail_direction_repair.pl` reads the type the
  phone's own message store wrote into each sms appointment note and restores the mailbox row: dry run
  by default, `--apply` writes. `--duplicates` also runs the records audit's mailbox half, tombstoning
  the bad-date import copies and repairing the two dates; `--seal-plain` seals a legacy public body so
  the thread and its recent preview can read it; `--thread-duplicates` collapses a message the chat
  send and the phone import both filed, keeping one row per direction within `--same-window` (default
  5s). A number kept with a leading country code is normalized against the bare mailbox number, and an
  appointment window (`--window MS`) only borrows a row whose own note does not name the other
  direction. A screened call transcript, filed with no author and a `Call from:` header, is incoming.
  Never touches a row a person marked `ignored`. Run it from a worktree with
  `JAWNOS_STORE_DIR=<live tree>` so the tool uses the live database, or with `JAWNOS_ROOT=<live tree>`
  to load that tree's code.

## Appointments that do not match what the person remembers

- **Appointments that do not match what the person remembers** (still open from hours ago, far longer
  than the app's usual, or cut short) are checked before anything is edited.
  `perl scripts/records_audit.pl` (dry run; `--all` for full history) finds **SWEEP** (one press closed
  more than one session), **WRONG-END** (an older session left open while a newer one of the same app
  began, so it took its end from a press that was not its own), **DUPES**, **ORPHANS**, **IMPOSSIBLE**.
  That is the class a stop bug makes: `subs::stop_target_row` closes the session a stop names, so a stale
  open session must never stand (fixed in v0.1.591: a named stop is a hard match and the header never
  names a stale session). `--apply` tombstones dupes and repairs a sweep; repair a WRONG-END to its own
  start + the app's `duration` and stamp a current `server_time`. The watch (Configure -> Plat -> Watch
  records) stages findings for a person; auto-apply covers exact duplicates only. Mark a genuinely long
  app leave-alone. `perl scripts/records_recover.pl` compares an older sealed snapshot with the live
  table and lists every session a repair shortened or dropped (`--backup <path>`, `--apps a,b`,
  `--older-than 1d`). A *shorter* live value is usually the **correct** repair, so nothing is restored
  unless named: `--backup <path> --apps home,eczema --apply` restores only those, stamps `server_time`,
  and is left alone by the audit. It refuses to write without a snapshot younger than ten minutes; a
  repair is otherwise permanent, and a bulk restore would undo the good fixes.
