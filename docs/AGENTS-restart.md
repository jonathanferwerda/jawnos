# Run & restart (master plumbing)

Moved out of `AGENTS.md` (a per-task reference, not an every-request map).

## Run & restart

- **Entry:** `./jawn` (master) → `President.pl` in a PTY → workers keyed by `$ENV{PURPOSE}`
  (`manager`, `websocket`, …) running `Manager.pl`, `Websocket.pl`.
- **Log:** `~/manager.log`. **DB:** `./database/jawnos.db` (SQLite, WAL) — the live house
  DB; query that one, never another file that looks like a database.
- **Restart:** `perl scripts/restart.pl --reason "v<version> - <summary>"` — it asks the master over
  `~/.president/control` and **waits for the verdict**: exit 0 accepted (and verified), 1 refused with the
  report naming the file, 2 no master / no answer, 3 asked through the status file with no verdict.
  `--status` shows what the master is doing and why it last restarted; `--verify` runs the guard and
  changes nothing. Never restart blind: the old channel (`printf 'restart' > ~/.president/status`) still
  works and carries a reason (`restart: <reason>`), but it cannot tell you it was refused, and an agent
  that waits it out loses minutes on a tree that was never coming. Every restart writes

  `~/.president/restart.json` (the last one: reason, source, who asked, guard verdict, version) and
  appends to `~/.president/restart.log`; master-watchdog recoveries land there too, so "why did it
  restart at 3am" is a file read, not a guess. Don't start `./jawn` yourself; never leave a detached
  process.

  **A restart is two frames and then a record.** The master acknowledges the request the moment it
  reads it (`{"ack":1,"state":"verifying"}`) and sends the verdict when the guard lands, on the same
  connection. A cold guard is minutes, so a caller that gives up hears *accepted, still verifying*
  (exit 2) instead of silence. The record is written **before** the tree is swapped and before the
  verdict is sent, so it also answers when the reply itself is lost (a master re-exec, a stream that
  stopped being read): `control::send` returns the record with `from => 'record'`. If the control
  socket does not answer at all, `restart.pl` orders the restart through the status file — which the
  master's own tick reads every second and which needs no listener — then waits for the record (exit 0
  accepted / 1 refused by the guard / 3 ordered, no verdict yet). `--no-fallback` keeps the strict
  reading: a silent socket is an error, exit 2.

  **The master publishes the truth.** `~/.president/status` said `good` through a Windows afternoon in
  which only the master was left: the tree writes `good` for itself at boot and nothing took it back.
  The master now writes `good` only while the tree answers and `frozen: <why>` otherwise (the restart
  sequence, the watchdog's verdict, the boot watch's give-up). A boot that never comes up is retried
  three times (~4.5 min bound), each attempt recorded as `refused: boot` with the reason in
  `restart.json`, and then the master stands down so a launcher starts a fresh one.

  The master re-verifies the tree before it kills anything, and caches the verdict per file **content**
  in `~/.president/verify-manifest`: a restart with nothing new to judge is ~0.4s, a cold sweep (no
  manifest, new manifest version, `node` newly installed, or the last run failed) is ~2 min. Delete that
  file to force a full re-check; a failing run never updates it.

  The two sockets in `~/.president`/`~` are the master's: `control` (above) and the watch socket. Both are
  bound with `FD_CLOEXEC` and their `MOJO_REUSE` entry is dropped (`private_unix_listener` in `./jawn`) —
  Mojo otherwise expects a re-exec to inherit the fd, and with the fd closed but the entry kept, the next
  reload dies in `listen()` and the socket silently never comes back.
- Status values: `good` / `restart` / `frozen` (`frozen: <why>` when the master knows the reason).
- Restart needed? `.ep` **no** (mtime checked per request) · `.pl` **yes** (`perl -c perl/Manager.pl` first)
  · `public/js/*.js` **no restart, plain refresh** — static assets revalidate (`no-cache` + ETag/Last-Modified),
  and the manager's scripts come from `/js/manager/bundle.js`, which the app rebuilds from the files' mtimes
  and the browser revalidates by ETag. The `?string=` buster still only moves on restart, but nothing depends
  on it for freshness.
- **Tests:** while iterating run `perl scripts/tests_for.pl --staged --run` — it maps the change to the
  tests that claim it (a path no test claims runs the full suite). Before the commit run
  `perl scripts/run_tests.pl`: it boots `subroutines.pl` once and forks one child per test, which is
  faster than prove; `-v t/foo.t` shows one file's TAP and `--prove` is the old path. Never run bare
  `prove -l t` — it is serial and several times slower.
