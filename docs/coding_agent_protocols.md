# Coding agent protocols

GENERATED — do not edit by hand. Built from AGENTS.md (gitignored, so it cannot
ride the repo) by scripts/bake_agents_rules.pl; the pre-commit hook refreshes it
whenever AGENTS.md changes. This is what the Coding agent is told to follow on
every machine.

## RULE 1 — Stop and ask after 3 attempts

If you cannot find a file (or the right place for one) after **3 attempts** (searches, globs, path
guesses), **STOP**. Do not keep grepping, globbing, or invent paths. Report what you tried and ask the
user for the exact file/folder/name. A wrong guess costs far more tokens than a question.

---


## Run & restart

- **Entry:** `./jawn` (master) → `President.pl` in a PTY → workers keyed by `$ENV{PURPOSE}`
  (`manager`, `websocket`, …) running `Manager.pl`, `Websocket.pl`.
- **Log:** `~/manager.log`. **DB:** `./database/jawnos.db` (SQLite, WAL) — the live house DB; query that
  one, never another file that looks like a database.
- **Restart:** `perl scripts/restart.pl --reason "v<version> - <summary>"` — it asks the master over
  `~/.president/control` and waits for the verdict: 0 accepted, 1 refused (report names the file),
  2 no master / no answer, 3 no verdict. `--status` shows what the master is doing; `--verify` runs the
  guard and changes nothing. Never start `./jawn` yourself; never leave a detached process.
- **Restart needed?** `.ep` **no** (mtime checked per request) · `.pl` **yes**
  (`perl -c perl/Manager.pl` first) · `public/js/*.js` **no** (static assets revalidate; the bundle
  rebuilds from mtimes).
- **Tests:** while iterating `perl scripts/tests_for.pl --staged --run`; before a commit
  `perl scripts/run_tests.pl`. Never bare `prove -l t`.
- Master plumbing, the verify manifest, the restart record and the socket rules: `docs/AGENTS-restart.md`.


## Crash-resilient agent work

The Zed panel retains every byte it is shown and can grow the editor into the GBs; zram + earlyoom turn
that into a slow patch instead of a frozen machine. Protect the work, not the chat:

- **One thread = one task**, closed when done; fresh thread when the task changes or an approach fails —
  long history degrades answers as well as memory. Keep output small (`grep`/`sed -n`, `read_file`
  ranges, `--quiet`, `cmd > /tmp/x.log 2>&1; tail -40`), never a whole 1 MB file for a pointed question.
- **Split large files — a `413 payload too large` means the request was the problem, not the tool.**
  Never retry it unchanged. Read source/JSON/logs by line range or with `sed -n`; read a log by its
  tail. Never pull a raw screenshot, PDF, audio or video into context: downscale first
  (`magick in.png -resize 1024x1024\> -quality 82 /tmp/small.webp` — aim under ~150 KB), then look at the
  small one. **Write screenshots as WebP, not PNG:** a WebP capture is typically 3–10× smaller than the
  same PNG and the image reader accepts it, so it is far less likely to hit the payload limit; prefer
  `.webp` for every `.shots` capture you create. A capture PNG is 0.2–2.7 MB and its base64 is larger
  still; that is what a 413 is made of. For a
  large write, generate it with a script (`write_file`/heredoc in sections), not by echoing the whole
  body through the model. If an HTTP upload answers 413, send one file per request or in parts. Compress,
  crop and thumbnail as its own step (see `scripts/gallery/`), then inspect the contact sheet.
- **Delegate** builds, test suites, `logcat` and repo-wide searches to a sub-agent returning finding +
  `file:line` + reproduce command, no raw logs; keep edits in the main thread so the diff is visible.
- **Checkpoint** each step in `.shots/AGENT-CHECKPOINT.md` (goal, done + paths, next action, last commit)
  and **commit** it (`git add -p`, `v<version> - <summary>`). After a crash start a *fresh* thread that
  reads it first; delete it when the task is done.
- **The checkpoint file may be shared.** More than one agent can be writing `.shots/AGENT-CHECKPOINT.md`
  at the same time, so **identify yourself** — put an agent id/model and a timestamp on your section,
  re-read before you write, and only replace your own entry. Never overwrite another agent's section or
  delete the file while someone else's work is still in it; if you are unsure who owns a line, leave it.


## Rules

- **Test fixtures only:** `email_test`, `email_tester`, `testing`, `testings`, `testingser`, plus the one
  sanctioned phone/email in `docs/AGENTS-notes.md`. Every other number/address is prohibited; only the
  sanctioned email may receive mail.
- **Never open an appointment or centre view just to look** — it fans out to every tab and pops windows
  on the user's screen. Verify UI behaviour by asking, not by curling a route.
- **Writes go through the app's routes**; standalone writes to `appointments` can be overwritten — re-read.
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
- **Names accept every printable character**; use `subs::path_name()` for a filesystem component and
  `subs::html_name()`/`http_name()` for a DOM id/class or URL. See Languages and translation above.
- **Translate help and UI text when you write it** — `subs::lang`/`subs::ui`/`jawnosT`, all sixteen core
  languages for labels, and the Guide engine for the rest. A feature that adds untranslatable text is not
  finished.
- **Every behaviour change ships with a test.** Add or update the matching file
  in `t/` when you change a function, a route, a template, a prompt or a setting
  another part reads. Give the test a `# tests-for:` header naming the source it
  pins. While iterating run `perl scripts/tests_for.pl --staged --run` (only the
  tests the change claims); before the commit run `perl scripts/run_tests.pl`
  (the whole suite: it boots once and forks one child per test; `--prove` is the
  old path). Never run bare `prove -l t`: it is serial and several times
  slower. A defect you find but do not fix gets a `TODO` test
  naming the file and line — never a test that asserts the broken behaviour. The
  pre-push hook runs the suite, so a regression blocks the push.
- **A file no test claims is debt, and it is counted.** `t/99-untested.t` enumerates every tracked
  source file that no `tests-for:` header claims. A new one fails the push; the fix is a `tests-for:`
  line in the test that covers it, or deleting the file. The remaining debt is `%owed` in that test
  — it may shrink, so remove an entry when its test lands (`perl scripts/tests_for.pl --files <path>`
  says whether it is still unclaimed).
- **Look it up before grepping.** `perl scripts/where.pl <name>` for a symbol, a route, a help topic
  or a file; `perl scripts/agent_help.pl <app>` (and `--schema=<table>`) for an app's facts. `grep` is
  for free text, literals and comments only. The indexes behind them are test-pinned, so a stale one
  fails the push instead of misleading you.
- **A new Manager helper goes in the map in the same change** — its name in
  `lib/JawnOS/Manager/Index.pm` (`%SUB`, name → part) and a forward declaration in
  `lib/JawnOS/Manager/Declarations.pm`. The map, not the part file, is what
  `AUTOLOAD` reads, so a helper missing from it is unreachable by name and dies at
  runtime. `t/54-manager-split.t` checks both directions and the pre-push hook
  blocks the drift; `perl scripts/where.pl <name>` prints the part it is in.
- **The name indexes are checked, not just trusted.** A new domain sub needs its
  `qw(...)` in `lib/JawnOS/Domain/Loader.pm` (`t/91`), a route action needs its row
  in `lib/JawnOS/Routes/` (`t/58`), and a new app page needs a help topic with
  `app => <name>` (`t/11`). Each test fails the push rather than letting the index
  go quietly stale; `scripts/where.pl` is the lookup those tests keep honest.
- **Cap parallel jobs on this shared box:** `pio run -j 4`, `gradle --max-workers=4`, `make -j4`.
- **Bump the version on every push.** Run `perl scripts/version_bump.pl` (patch bump of `./VERSION`,
  e.g. `0.1.20 → 0.1.21`) and prefix the commit subject with it: `v<version> - <summary>`. Verify with
  `cat VERSION` before `git push`. Existing pushes that skipped this were the oversight this rule fixes.
- **Commit as you go**, staging only your own hunks (`git add -p`).
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
- **Finishing routine — ALWAYS run it: bump → commit → push → restart.** This is not optional and not
  "the norm": every piece of work ends this way, without being asked. Run `perl scripts/version_bump.pl`,
  stage only your own hunks (never someone else's WIP), commit as `v<version> - <summary>`, `git push`,
  then restart (`perl scripts/restart.pl --reason "v<version> - <summary>"`; it waits for the verdict
  and exits 1 with the report if the guard refuses). The bump ships the version
  prefix and busts the client caches; the restart is what makes `.pl` and `public/js` changes live. Do it
  at the end of every task unless the user explicitly says not to.

---
