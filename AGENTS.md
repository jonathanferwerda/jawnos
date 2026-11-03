# AGENTS.md — JawnOS map

A low-token index of where things live. Read this before searching, then search narrowly. Keep it short.

> Deep reference (data model, store/mail flows, firmware, history) lives in `docs/AGENTS-notes.md`.
> The notes are **gitignored — never commit them** (they carry fixtures and a login token). This map
> is tracked and published; it names files, never credentials.

---

## Look it up — do not grep for it

Two commands read the tree's test-checked indexes. **Reach for them before `grep`** — a grep answers
"this string appears here", not "this is where that lives".

- `perl scripts/where.pl <name>` — one line, `file:line`: a Manager helper, a domain sub, a route
action (`action_7408`), a route path (`/manager/pen`), a help topic by name, a JavaScript, firmware,
`perl/` or `scripts/` declaration, or a file (which topics cover it). A name nothing declares prints the mention lines **with their text**, so a miss is still judgeable
without opening the file. A single JS/firmware declaration comes with its body (`--body`, capped); `--outline FILE`
lists a file's declarations as `line<TAB>kind name`, so read the range, not the file. `--topics`
lists the help registry (`--topics PATTERN` narrows it), `--tech <app>` prints the technical brief
(routes compressed as `/a{b,c}`; `--routes` expands them). After you act on a hit,
report it: `where.pl --report <name> right --at path:line`; if it was wrong,
`wrong --at path:line --found path:line`; if it missed, `miss --found path:line` (a report must say
what did work). `perl scripts/where_audit.pl` turns those rows and misses into a maintenance brief;
Configure → System runs it on a cadence or on demand (Butler on pauses the schedule, not the ledger).
- `perl scripts/agent_help.pl <app>` — what an app is made of: sources, the routes that reach it,
the tables and settings it touches, the tests that claim its files, and its own comments. `--schema`
or `--schema=<table>` gives every column, its type, the indexes and the apps that use the table.
- **`grep` is for what the indexes cannot know**: free text, a string literal, a comment, a value that
  is not a name. Everything else has a faster, correct answer above. If the locator is not helpful for
  something you needed, make it better in the same change — every agent reads it, so keep its
  `file:line` output and `t/96`/`t/93` green.

The indexes are pinned by `t/54` (helpers), `t/58` (routes), `t/91` (domain subs), `t/11` (help),
`t/99` (untested files): a stale index fails the push.

---

## Next up (deferred)

Moved to `docs/AGENTS-roadmap.md`: the lost-key drill, the two keyless Desktop window rows.

## Credentials

SSH host/user/password pairs live in `.secrets/ssh.txt` (gitignored, `chmod 600`). Passwordless key
auth (`~/.ssh/id_ed25519`) is installed on all four hosts; they listen on port **8022**, not 22. Prefer
the key — passwords are fallback only. Never copy credentials into a commit, a log, or a tracked file.

---

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

## Web interface

- **Test the WebUI, not a Chromium-only path.** The desktop app is WebKitGTK; Chromium is for headless
  DOM/route checks only. An engine-dependent feature (CSS `filter: url(#…)`, `canvas.toBlob`,
  `createImageBitmap`, WebCodecs) is not proven by headless Chromium — say so and check the real engine.
- Log in with a ticket URL: `https://127.0.0.1:3000/box_office/<uuid>?s=<token>`. The live token is in
  `.shots/ticket.txt` (gitignored). It mints the `president` cookie and redirects to
  `https://127.0.0.1:<working_port>/manager` (`working_port` from `config.json`).
- curl: `https://127.0.0.1:3000 -k`. Headless command and CDP notes: `docs/AGENTS-web.md`.

## App releases (the APK store)

Built APKs are staged in `releases/` (gitignored). `perl scripts/app_build.pl` bumps the app repo's
versionCode/versionName and stages the next one; `perl scripts/app_publish.pl` uploads the newest staged
APK **and** a matching `app_release.json` — **a build that is only staged never reaches GitHub**, so
always build **and** publish. Bump `versionCode` per release in `~/jawnos-app/termux-app/AGENTS.md`.
Staging names, the `GET /manager/app_release` bytes and the sync: `docs/AGENTS-app-releases.md`.

## Firmware / OTA (stage every build)

The manager serves firmware from **hardwired paths**, not `.pio/build/` — an unstaged build means an OTA
sends the previous firmware. alarmclock (Pico 2 W): `pio run -j 4` in `jp/alarmclock`, then
`perl scripts/stage_firmware.pl` (`--build` does both). Keep the LittleFS split
(`board_build.filesystem_size = 2M`); at 0 MB the device boots without `config.txt` and drops to its AP.
ESP32 boards take the `.bin` picked from `.pio/build/<env>/`. Hardwired paths, `@targets` and LoRaWAN:
`docs/AGENTS-firmware.md`.

## Languages and translation

JawnOS ships English plus fifteen interface languages (listed in `language.pl`); core labels have
hand-written translations for all sixteen, everything else is translated **on demand**. Make text
translatable in the same change:

- Perl/templates: `subs::lang('key')` for a core label, `subs::ui('English text')` for a sentence; JS:
  `jawnosT('English text')`. A **new core label** gets a key in `language.pl` in **all sixteen**
  languages; help text goes in the help topic (translated on demand).
- **Names accept every printable character.** Use `subs::path_name()` for a filesystem component,
  `subs::html_name()`/`http_name()` for a DOM id/class or URL — never concatenate `$app` into a path
  without it.
- A button/hint rename updates the help topic; `translate.js` only swaps exact text and the
  `hint`/`placeholder`/`title`/`alt`/`aria-label` attributes, so dynamic labels need `jawnosT`/`subs::ui`.
- The 107-language engine, bulk catalogs and `translate_page`: `docs/AGENTS-translation.md`.

## Rules

- **Maintain the locator from its ledger.** Before changing `scripts/where.pl` or its maps, run
  `perl scripts/where_audit.pl --prompt` and fix what it names: misses, wrong reports, map drift.
  Confirm each case in the source, add a test for each new shape, and report a hit you acted on.
- **Look it up before grepping.** `perl scripts/where.pl <name>` for a symbol, a route, a help topic
  or a file; `perl scripts/agent_help.pl <app>` for an app's facts. `grep` is for free text, literals
  and comments only.
- **Reply budget.** A final message is what changed (`file:line`), what verified it (command → result),
  and one risk. No code, diff, narration or restating the request; quote only failing lines. The commit
  message carries the rationale; the chat carries the pointer.
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

## Layout

- `perl/` — the service layer (`President.pl`, the `Manager.pl` launcher, `Websocket.pl`, `Alarm.pl`,
  `Music.pl`, `watch.pl`, `teletype.pl`, `subroutines.pl`, `gb.pl`, `hooks.pl`, `help.pl`,
  `language.pl`). Every `require` is cwd-relative: run from the root.
- `lib/` — `JawnOS.pm` (the app), `Manager.pm` + lazy `Manager/Part*.pm` (`AUTOLOAD`; `Declarations.pm`
  forward-declares), `Controller/*` (one `sub action_<line>` per route), `Routes*`, `Domain/*`
  (package `subs`, lazy via `Domain/Loader.pm`).
- `templates/` Mojo `.ep` (pages at top level, partials in feature folders; a page over ~300 lines
  includes its own folder's partials) · `public/` assets (`js/` are `foo.js` indexes + `foo/` parts) ·
  `scripts/` · `database/` · `desktop/` · `docs/` · `jp/ jt/ jw/` firmware · `.shots/` · `releases/`.
- The folder table, the eager/lazy part notes and the Lite history: `docs/AGENTS-layout.md`.
  Never read or edit generated `.pio/`/`build/`.

**Searching:** start in the most specific folder above; if a file is not on this map and 3 attempts
fail, invoke RULE 1.

---

## Help system (keep it accurate)

The in-app guide is served by the `help` app (`templates/apps/help.html.ep`,
`public/js/manager/help.js`, routes `/manager/help`, `/manager/help/body`, `/manager/help/ask`).

- **Tier 1 — the user** is hand-written: `perl/help/topics_*.pl`, audited by `t/11-help.t` and
  `scripts/help_audit.pl`. **When you change an app's UI, update its topic in the same commit**, in the
  on-screen words.
- **Tier 2 — the agent** is generated: `perl scripts/agent_help.pl <app>` (sources, routes, tables, tests,
  notes; `--schema[=table]`, `--routes`). `qa/coding_night/agent-index.md` is the nightly index
  (`--write-index`; `t/97` pins it).
- **Never hand-write a tier-2 fact and never translate it.** Rationale stays in source comments. Binding
  lists and audit checks: `docs/help-workflow.md`.

---

## Splitting a file (index + parts)

A manager script over ~550 lines, a firmware sketch and a big template page take the same shape: an
index keeping the first contiguous segment and naming the parts, the rest in `NN_<slug>` files.
**Read `docs/AGENTS-splitting.md` before splitting anything** — JS boundary rules, the
`js_parts_check.pl` gate, the three lazy-app maps and the PlatformIO sketch rules. Two facts that matter
on a normal task:

- A split JS file needs **no** `@manager_bundle_files` edit; a new lazy app does need its files, entry
  functions and toggle id/class in the three maps in `lib/JawnOS/Manager/Core1_tables_hooks.pm` (`t/63`).
- `lib/JawnOS/Manager/Index.pm` and `lib/JawnOS/Domain/Loader.pm` are name → file maps. **Do not read
  them to find one function** — `perl scripts/where.pl <name>` prints `file:line`.

## Facts that save a search

Data model, journal, maps and chat: `docs/AGENTS-facts.md`. Schema: `database/schema.sql`.

## Token economy

Ask for the hunk, keep the context prefix stable, and ask the locator. Full rules: `docs/AGENTS-agent-work.md`.
The four local agents (Guide, Coding, Evaluation, Pen) and how a new app is added: `docs/AGENTS-agents.md`.
