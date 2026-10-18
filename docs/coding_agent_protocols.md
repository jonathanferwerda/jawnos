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
- **Log:** `~/manager.log`. **DB:** `/home/jawn/initial.db` (SQLite, WAL).
- **Restart:** `printf 'restart' > ~/.president/status` — `jawn` polls every 2 s, writes `good` back,
  and reboots the tree. Don't start `./jawn` yourself; never leave a detached process.
- Status values: `good` / `restart` / `frozen`.
- Restart needed? `.ep` **no** (mtime checked per request) · `.pl` **yes** (`perl -c Manager.pl` first)
  · `public/js/*.js` **no restart, plain refresh** — static assets revalidate (`no-cache` + ETag/Last-Modified),
  and the manager's scripts come from `/js/manager/bundle.js`, which the app rebuilds from the files' mtimes
  and the browser revalidates by ETag. The `?string=` buster still only moves on restart, but nothing depends
  on it for freshness.


## Crash-resilient agent work

Zed's agent panel can grow the editor process to several GB in minutes and die mid-task; the JawnOS Coding agent can also lose a turn. Protect the work, not the chat:

- **Checkpoint before and after each step** in `.shots/AGENT-CHECKPOINT.md` (gitignored): the goal, what is done (with paths), the exact next action, and the last commit.
- **Commit each coherent step** (`git add -p`, `v<version> - <summary>`) so a crash cannot lose it. Never leave a day's work only in a buffer.
- **After a crash, start a *fresh* thread** (a new Zed thread or a new Coding-agent conversation) and tell it to read `.shots/AGENT-CHECKPOINT.md` first. Resuming a multi-MB thread makes the next request larger and is a common cause of the next balloon.
- Keep tool output small: use `grep`/`sed -n` and targeted `read_file` ranges, not whole 1 MB files; the agent panel retains every byte it is shown.
- Delete the checkpoint when the task is complete.


## Rules

- **Test fixtures only:** `email_test`, `email_tester`, `testing`, `testings`, `testingser`, plus the one
  sanctioned phone/email in `docs/AGENTS-notes.md`. Every other number/address is prohibited; only the
  sanctioned email may receive mail.
- **Never open an appointment or centre view just to look** — it fans out to every tab and pops windows
  on the user's screen. Verify UI behaviour by asking, not by curling a route.
- **Writes go through the app's routes**; standalone writes to `appointments` can be overwritten — re-read.
- **Cap parallel jobs on this shared box:** `pio run -j 4`, `gradle --max-workers=4`, `make -j4`.
- **Bump the version on every push.** Run `perl scripts/version_bump.pl` (patch bump of `./VERSION`,
  e.g. `0.1.20 → 0.1.21`) and prefix the commit subject with it: `v<version> - <summary>`. Verify with
  `cat VERSION` before `git push`. Existing pushes that skipped this were the oversight this rule fixes.
- **Commit as you go**, staging only your own hunks (`git add -p`).
- **Appointments that do not match what the person remembers - one still open from hours ago, a
  session far longer than the app's usual, or one that looks cut short - are checked before anything is
  edited.** `perl scripts/records_audit.pl` (dry run; `--all` for the whole history) is the records
  watch's audit of the appointments table: **SWEEP** (one press closed more than one session),
  **WRONG-END** (an older session left open while a newer one of the same app began, so the older row
  took its end from a press that was not its own - a run of stops that each closed the wrong session),
  **DUPES** (the same event written twice), **ORPHANS** and **IMPOSSIBLE**. This is the class a stop
  bug makes: `subs::stop_target_row` closes the session a stop names, and the header names the app's
  **running (newest)** session - a stale open session must never stand, or the next stop sweeps it.
  Fixed in v0.1.591: a named stop is a hard match (a repeated or late copy is a no-op) and the header
  never names a stale session. `perl scripts/records_audit.pl --apply` tombstones the dupes and repairs
  a sweep; repair a WRONG-END row to its own start + the app's `duration` and stamp a current
  `server_time` so every machine takes it. The watch (Configure -> Plat -> Watch records) stages
  findings for a person to review; auto-apply covers exact duplicates only. Mark a genuinely long app
  (an eight-month ailment) leave-alone rather than repairing it.
  `perl scripts/records_recover.pl` (dry run) is the other direction - it compares
  an older sealed snapshot against the live appointments table and lists every session a repair
  shortened or dropped: `--backup <path>` names the snapshot (default the newest), `--apps a,b` the app
  names that legitimately run long, `--older-than 1d` the length above which any app is listed. A
  *shorter* live value is usually the **correct** repair (an app that runs three minutes was ended at
  three minutes), so nothing is put back unless it is named: `perl scripts/records_recover.pl --backup
  <path> --apps home,eczema --apply` restores only those, stamps each with a current `server_time` so
  every machine takes it, and leaves the recovered apps alone by the audit. It refuses to write without
  a snapshot younger than ten minutes and takes one if needed; a repair is otherwise permanent, and a
  bulk restore of everything shorter would undo the good fixes.
- **Finishing routine — ALWAYS run it: bump → commit → push → restart.** This is not optional and not
  "the norm": every piece of work ends this way, without being asked. Run `perl scripts/version_bump.pl`,
  stage only your own hunks (never someone else's WIP), commit as `v<version> - <summary>`, `git push`,
  then restart (`printf 'restart' > ~/.president/status`; wait for `good`). The bump ships the version
  prefix and busts the client caches; the restart is what makes `.pl` and `public/js` changes live. Do it
  at the end of every task unless the user explicitly says not to.

---
