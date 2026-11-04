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

- **Entry:** `./jawn` → `President.pl` in a PTY → workers keyed by `$ENV{PURPOSE}` (`manager`,
  `websocket`, …) running `Manager.pl`, `Websocket.pl`.
- **Log:** `~/manager.log`. **DB:** `./database/jawnos.db` (SQLite, WAL) — the live house DB; query that
  one, never another file that looks like a database.
- **Restart:** `perl scripts/restart.pl --reason "v<version> - <summary>"` — it asks the master over
  `~/.president/control` and waits for the verdict: 0 accepted, 1 refused (report names the file),
  2 no master / no answer, 3 no verdict. `--status` shows what the master is doing; `--verify` runs the
  guard and changes nothing. Never start `./jawn` yourself; never leave a detached process.
- **Restart needed?** `.ep` **no** (mtime checked per request) · `.pl` **yes**
  (`perl -c perl/Manager.pl` first) · `public/js/*.js` **no** (static assets revalidate; the bundle
  rebuilds from mtimes).
- **Docker:** `docker compose up -d --build` runs this same tree from `Dockerfile`; the entry point
  seeds `config.json` and the database on first boot. Ports, volumes and what is deliberately absent
  (desktop app, firmware, SSH, hardware passthrough): `docs/docker.md`. The nightly smoke
  (`qa/docker/smoke.sh`, `jawnos-qa-docker.timer` at 04:30) builds HEAD, runs it loopback-only and
  removes its volumes: testing only, and a missing Docker is a skip.
- **Packages:** `qa/installers/run.sh` (`jawnos-qa-installers.timer`, 03:45) checks CPAN, Debian, Arch
  and the Android SDK index still offer what we install; metadata only. `missing` fails, `STRICT=1`
  fails `outdated`.
- **Tests:** while iterating `perl scripts/tests_for.pl --staged --run`; before a commit
  `perl scripts/run_tests.pl`. Never bare `prove -l t`.
- Master plumbing, verify manifest, restart record, socket rules: `docs/AGENTS-restart.md`.


## Crash-resilient agent work

The Zed panel keeps every byte it is shown; zram + earlyoom only slow the crash. Protect the work, not the chat.

- **One thread = one task**; fresh thread when the task changes or an approach fails. Keep output small
  (`grep`/`sed -n`, `--quiet`, `cmd > /tmp/x.log 2>&1; tail -40`).
- **A `413 payload too large` is the request, not the tool.** Never retry it unchanged; read by range or
  log tail. Downscale images before context; write `.shots` captures as **WebP**
  (`magick in.png -resize 1024x1024\> -quality 82 /tmp/small.webp`).
- **Delegate** builds, suites, `logcat` and repo-wide searches to a sub-agent returning finding +
  `file:line` + reproduce command, no raw logs; keep edits in the main thread.
- **Checkpoint** each step in `.shots/AGENT-CHECKPOINT.md` and commit it. It may be shared: identify
  yourself, re-read, replace only your own entry.
- **Ask for the hunk** (`where.pl --outline`, `--body`), not the file; keep the prefix stable. Full
  rules: `docs/AGENTS-agent-work.md`.


## Rules

- **Maintain the locator from its ledger.** Before changing `scripts/where.pl` or its maps, run
  `perl scripts/where_audit.pl --prompt` and fix what it names: misses, wrong reports, map drift.
  Confirm each case in the source, add a test for each new shape, and report a hit you acted on.
- **Look it up before grepping.** `perl scripts/where.pl <name>` for a symbol, a route, a help topic
  or a file; `perl scripts/agent_help.pl <app>` for an app's facts. `grep` is for free text, literals
  and comments only.
- **Reply budget.** A final message must let a reviewer understand the change without opening every file: what changed and why, grouped by area, with the paths (`file:line`); how it was verified (command → result); any behaviour, migration or follow-up the person must know; one realistic risk; and the obvious next step as a question. Quote only failing lines or a small hunk that carries a decision — never a whole file or a diff dump, never a tool-by-tool narration, and never a restatement of the request. The commit message carries the rationale; the chat carries the explanation, not just the pointer.
- **Test fixtures only:** `email_test`, `email_tester`, `testing`, `testings`, `testingser`, plus the one
  sanctioned phone/email in `docs/AGENTS-notes.md`. Every other number/address is prohibited; only the
  sanctioned email may receive mail.
- **Never open an appointment or centre view just to look** — it fans out to every tab and pops windows
  on the user's screen. Verify UI behaviour by asking, not by curling a route.
- **Writes go through the app's routes**; standalone writes to `appointments` can be overwritten — re-read.
- **The database is per device — never restore one machine's `jawnos.db` onto another.** Restore only
  onto the same machine; after a cross-machine restore, repair the identity before trusting the panel
  (its own `devices` row, direct `remote_machines` peers, no source rows). The incident and the exact
  repair: `docs/AGENTS-records.md`.
- **Appointments that do not match what the person remembers** (still open from hours ago, far longer
  than usual, or cut short) are checked before anything is edited: `perl scripts/records_audit.pl`
  (dry run; `--all` for full history). Repair rules and `records_recover.pl`: `docs/AGENTS-records.md`.
- **Every behaviour change ships with a test.** Add or update the matching `t/` file when you change a
  function, route, template, prompt or shared setting. Give it a `# tests-for:` header naming the source.
  While iterating run `perl scripts/tests_for.pl --staged --run`; before the commit run
  `perl scripts/run_tests.pl` (never bare `prove -l t`). A defect you do not fix gets a `TODO` test
  naming the file and line — never a test asserting the broken behaviour. The pre-push hook runs the suite.
- **A file no test claims is debt.** `t/99-untested.t` lists every tracked source file no `tests-for:`
  claims; a new one fails the push. Its `%owed` list may shrink — remove an entry when its test lands.
- **A new Manager helper goes in the map in the same change** — its name in
  `lib/JawnOS/Manager/Index.pm` (`%SUB`, name → part) and a forward declaration in
  `lib/JawnOS/Manager/Declarations.pm`. `AUTOLOAD` reads the map, not the part file; `t/54` checks both
  directions and the pre-push hook blocks the drift.
- **The name indexes are checked, not just trusted.** A new domain sub needs its `qw(...)` in
  `lib/JawnOS/Domain/Loader.pm` (`t/91`), a route action its row in `lib/JawnOS/Routes/` (`t/58`), and
  a new app page a help topic with `app => <name>` (`t/11`).
- **Cap parallel jobs on this shared box:** `pio run -j 4`, `gradle --max-workers=4`, `make -j4`.
- **Bump the version on every push.** Run `perl scripts/version_bump.pl` and prefix the commit subject
  with it: `v<version> - <summary>`. Verify with `cat VERSION` before `git push`.
- **Commit as you go**, staging only your own hunks (`git add -p`).
- **Finishing routine — ALWAYS run it: bump → commit → push → restart.** Every piece of work ends this
  way, without being asked: `perl scripts/version_bump.pl`, stage only your own hunks, commit as
  `v<version> - <summary>`, `git push`, then `perl scripts/restart.pl --reason "v<version> - <summary>"`.
  Do it at the end of every task unless the user explicitly says not to.

---
