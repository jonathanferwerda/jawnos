# AGENTS.md — JawnOS map

A low-token index of where things live. Read this before searching, then search narrowly. Keep it short.

> Deep reference (data model, store/mail flows, firmware, history) lives in `docs/AGENTS-notes.md`.
> The notes are **gitignored — never commit them** (they carry fixtures and a login token). This map
> is tracked and published; it names files, never credentials.

---

## Look it up — do not grep for it

The tree has definitive, test-checked indexes, and two commands read them. **Reach for these before
`grep`** — a grep answers "this string appears here", not "this is where that lives".

- `perl scripts/where.pl <name>` — one line, `file:line`: a Manager helper, a domain sub, a route
action (`action_7408`), a route path (`/manager/pen`), a help topic by name, a JavaScript, firmware,
`perl/` or `scripts/` declaration, or a file (which topics cover it). A name nothing declares prints
the lines that mention it **with their text**, so a miss is still judgeable without opening the
file. A single JS/firmware declaration comes with its body (`--body`, capped); `--outline FILE`
lists a file's declarations as `line<TAB>kind name`, so read the range, not the file. `--topics`
lists the help registry, `--tech <app>` prints the technical brief. After you act on a hit,
report it: `where.pl --report <name> right --at path:line`, or `wrong --at path:line --found path:line`
when it sent you to the wrong place. `perl scripts/where_audit.pl` turns those rows, the misses and
map drift into a maintenance brief for the Coding agent. Configure → System runs it on a cadence
(off/hourly/daily/weekly/monthly/yearly) or on demand; each run reads since its last successful
minute, and the first run reads 14 days.
- `perl scripts/agent_help.pl <app>` — what an app is made of: sources, the routes that reach it,
the tables and settings it touches, the tests that claim its files, and its own comments. `--schema`
or `--schema=<table>` gives every column, its type, the indexes and the apps that use the table.
- **`grep` is for what the indexes cannot know**: free text, a string literal, a comment, a value that
  is not a name. Everything else has a faster, correct answer above. If the locator is not helpful for
  something you needed, make it better in the same change — every agent reads it, so keep its
  `file:line` output and `t/96`/`t/93` green.

The indexes are pinned by `t/54` (Manager helpers), `t/58` (routes), `t/91` (domain subs), `t/11` (help
pages) and `t/99` (files no test claims), so a stale one fails the push rather than misleading you.

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

## Web interface

- **Test the WebUI, not a Chromium-only path.** The desktop app is WebKitGTK and that is the engine
  people actually use; Chromium is for **headless automated checks only** (DOM smoke tests, route/JS
  error capture). When a change is WebUI-visible, exercise it in the real JawnOS WebUI. A feature
  that depends on an engine detail (CSS `filter: url(#…)`, `canvas.toBlob`, `createImageBitmap`,
  WebCodecs) is not proven by headless Chromium alone — say so and check the real engine.
- Log in with a ticket URL: `https://127.0.0.1:3000/box_office/<uuid>?s=<token>`. The live token is in
  `.shots/ticket.txt` (gitignored, a real credential).
- It mints the `president` session cookie and redirects to
  `https://127.0.0.1:<working_port>/manager` (`working_port` from `config.json`; ticket served on `port`).
- curl: `https://127.0.0.1:3000 -k`. Headless: `/usr/bin/chromium --headless=new --no-sandbox
  --disable-gpu --ignore-certificate-errors --remote-debugging-port=<p> --user-data-dir=/tmp/<p>`, over CDP.

## App releases (the APK store)

Built APKs are staged in `releases/` (gitignored: a ~35 MB binary per version rides the mesh as a blob,
never through git). `perl scripts/app_build.pl` bumps the app repo's versionCode/versionName, builds and
stages the next one; `perl scripts/app_publish.pl` uploads the newest staged APK **and** a matching
`app_release.json` to the GitHub release — **a build that is only staged never reaches GitHub**, so
always build **and** publish. Runtime zips ride the same release. Every jawn serves
`GET /manager/app_release` and `?product=app` for the bytes, and `subs::app_release_sync()` spreads the
newest (temp → sha256 → rename). The app repo has its own guide
(`~/jawnos-app/termux-app/AGENTS.md`): bump `versionCode` per release. Staging names and who installs
it: `docs/AGENTS-app-releases.md`.

## Firmware / OTA (stage every build)

The manager serves firmware from **hardwired paths**, not from a device's `.pio/build/` — an unstaged
build means an OTA sends the previous firmware. alarmclock (Pico 2 W): `pio run -j 4` in
`jp/alarmclock`, then `perl scripts/stage_firmware.pl` (`--build` builds first). Keep the LittleFS split
(`board_build.filesystem_size = 2M`); at 0 MB the new image boots without `config.txt` and the device
drops to its AP. ESP32 boards: the panel takes the `.bin` you pick from `.pio/build/<env>/`. LoRaWAN
(T-Deck SX1262): Chat's LoRa section owns the mode and pushes the `mail/lorawan_*` settings. Hardwired
paths, `@targets` and the LoRaWAN endpoints: `docs/AGENTS-firmware.md`.

## Languages and translation

JawnOS ships English plus fifteen interface languages — Mandarin, French, Spanish, German, Portuguese,
Hindi, Arabic, Bengali, Russian, Japanese, Punjabi, Indonesian, Korean, Italian and Turkish — listed in
`language.pl`. Core interface labels have hand-written translations for all sixteen. Everything else is
translated **on demand** by the Guide's engine; do not pre-generate fifteen copies of every help paragraph.

**When you write help text or a UI feature, make it translatable in the same change:**

- Perl and templates: `subs::lang('key')` for a reusable core label; `subs::ui('English text')` for a
  help/printer/server-side sentence. JS: `jawnosT('English text')`. Never hardcode a second language and
  never leave a bare English label where a core label belongs.
- A **new core interface label** gets a key in `language.pl` in **all sixteen interface languages**
  (English plus the fifteen above). If it is help/body text instead, add it to the help topic; the Guide
  engine translates it on demand for the 107 languages it offers.
- The engine's language list is `language::translation_languages()` (the `translation` help topic and
  Configure -> Misc show it). The Guide can list it with `translate_languages`, translate a phrase with
  `translate`, and translate the visible window with `translate_page`. The model configured for the Guide
  under Configure -> Plat does the work — DeepSeek, Gemini, Claude, GPT, Grok and the rest are broadly
  multilingual. Legal and sensitive help text should be reviewed by a speaker before it is relied on.
- Add/rename an on-screen button or hint: update the help topic (see below) and make sure the same English
  label is in the translation pipeline. `translate.js` replaces exact English text nodes and the
  `hint`/`placeholder`/`title`/`alt`/`aria-label` attributes, so a dynamic label must go through
  `jawnosT`/`subs::ui` instead of being assembled from untranslated pieces.
- Optional bulk catalogs: `perl scripts/i18n_extract.pl`, then `perl scripts/i18n_translate.pl`, then
  `perl scripts/i18n_audit.pl`. The on-demand cache (the `cache` table with `app='translation'`, and the
  browser's `localStorage`) works without them; commit a bulk catalog only when it has been reviewed.

**Names accept every printable character.** `subs::unformat_name()` keeps them: spaces become `_`, a
straight `'` or `"` becomes the typographic mark so the hundreds of hand-built JS/SQL snippets stay safe,
and control characters are dropped. Never re-strip letters or punctuation from an input name. When a
name becomes a filesystem path use `subs::path_name()` (it percent-encodes the bytes a path or shell
cannot take safely); when it becomes a DOM id/class or a URL use `subs::html_name()`/`http_name()`. New
code that concatenates `$app` into a path without `path_name` is a bug.

## Rules

- **Maintain the locator from its ledger.** Before changing `scripts/where.pl` or its maps, run
  `perl scripts/where_audit.pl --prompt` and fix what it names: misses, wrong reports, map drift.
  Confirm each case in the source, add a test for each new shape, and report a hit you acted on.
- **Reply budget.** A final message is what changed (`file:line`), what verified it (command → result),
  and one risk. No code you wrote, no diff, no narration, no restating the request. Tool output is
  quoted only for the failing lines. The commit message carries the rationale; the chat carries the pointer.
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

## Layout

- `perl/` — service layer: `President.pl`, `Manager.pl` (a ~24-line launcher), `Websocket.pl`,
  `Alarm.pl`, `Music.pl`, `watch.pl`, `teletype.pl`, `subroutines.pl`, `gb.pl`, `hooks.pl`, `help.pl`,
  `language.pl`. Every `require` is cwd-relative, so the tree runs from its root.
- `lib/` — `JawnOS.pm` (the app; `startup` publishes `Manager::app`), `Manager.pm` + `Manager/Part*.pm`
  (package `Manager`, lazy via `AUTOLOAD`; `Declarations.pm` forward-declares every name),
  `Controller/*` (one `sub action_<line>` per route), `Routes*` (order = original line number),
  `Domain/*` (package `subs`, lazy via `Domain/Loader.pm`).
- `templates/` Mojo `.ep` (pages at top level, partials in feature folders; a page over ~300 lines
  includes partials from a folder of its own name) · `public/` served assets (`js/` are `foo.js` indexes
  + `foo/` parts) · `scripts/` CLI/admin · `database/` · `desktop/` · `docs/` · `jp/ jt/ jw/` firmware
  · `.shots/` scratch + `ticket.txt` · `releases/` staged APKs.
- The folder table, the eager/lazy part notes and the Lite history: `docs/AGENTS-layout.md`.
  Never read or edit generated `.pio/`/`build/`.

**Searching:** start in the most specific folder above; if a file is not on this map and 3 attempts
fail, invoke RULE 1.

---

## Help system (keep it accurate)

The in-app guide lives in `help.pl` (a `%topic` registry), served by the `help` app
(`templates/apps/help.html.ep`, `public/js/manager/help.js`, routes `/manager/help`,
`/manager/help/body`, `/manager/help/ask`); the guide agent answers through
`subs::evaluation_model_call`.

**Help has two tiers, and only tier 1 is written by hand.** Tier 1 — the user: `perl/help/topics_*.pl`,
prose for navigating the program, translated on demand, audited by `t/11-help.t` and
`scripts/help_audit.pl`. Tier 2 — the agent: generated from the tree by
`perl scripts/agent_help.pl <app>` (`--schema[=table]`), with `qa/coding_night/agent-index.md` as the
compact nightly index (`--write-index`; the pre-commit hook refreshes it, `t/97-agent-help.t` pins it).

**Never hand-write a tier-2 fact and never translate it** — anything derivable from code is derived.
Rationale stays in the source comments and `docs/AGENTS-notes.md`, which the brief surfaces.

**When you change an app's UI, update its topic in the same commit**, and keep the topic's words
identical to the on-screen labels. Binding lists, the audit's checks and the fixture probe:
`docs/help-workflow.md`.

---

## Splitting a file (index + parts)

A manager script over ~550 lines, a firmware sketch and a big template page all take the same shape: an
index keeping the first contiguous segment and naming the parts, the rest in `NN_<slug>` files in name
order. **Read `docs/AGENTS-splitting.md` before splitting anything** — it holds the JS boundary rules,
the `js_parts_check.pl` gate, the three lazy-app maps and the PlatformIO sketch rules. Nothing on a
normal task needs it. Two facts that do:

- A split JS file needs **no** `@manager_bundle_files` edit (`/js/manager/bundle.js` expands the folder
  via `subs::js_part_files()`); a new lazy app does need its files, entry functions and toggle id/class
  in the three maps in `lib/JawnOS/Manager/Core1_tables_hooks.pm` (`t/63-js-parts.t` checks they agree).
- `lib/JawnOS/Manager/Index.pm` (helpers) and `lib/JawnOS/Domain/Loader.pm` (domain subs) are name →
  file maps. **Do not read them to find one function** — `perl scripts/where.pl <name>` prints
  `file:line`, and reports a map that has drifted.

## Facts that save a search (verified 2026-11-02)

**Data model.** `appointments` is the big table; satellites: `warehouse` (signed stock moves),
`mailbox`, `notes`, `model`/`option`/`subcategory`, `continent` (lat/long), `magazine`, `credentials`,
`devices`. Sync bookkeeping: `sync_log`, `sync_cursors`, `sync_jobs`, `sync_snapshots`,
`staged_appointments`. Every synced table carries `ost` and `server_time` — add both to a new table or
the rail skips it. Schema: `database/schema.sql`; deep notes: `docs/AGENTS-notes.md`.

**Journal is a use case, not a table.** It lives in the Handbook app: a person records goals, plans and
journals, and the guide agent reads them back and stages changes. There is no `journal` table or
template — it is `notes` plus the Handbook.

**Maps are measured images.** `public/js/manager/mapengine.js` places any scanned or screenshotted map
by a `home_plate` pixel at a lat/long plus a scale bar (image px per metre), optionally over a tile
layer. `public/js/manager/travel.js` is the picker and view. Coordinates live in `continent`; there is
no `maps` table.

**Chat is a set of roads.** `templates/apps/chat.html.ep` sections: `sms, dial, list, tickets, rooms,
lora`. SMS/MMS goes through the Android app; LoRa through the T-Watch and T-Deck. **WebRTC is not a
transport yet** — `templates/mail/conversation.html.ep` records it as "webrtc joins them later"; the
only WebRTC code is the stream watcher in `public/js/manager/jp/01_watcher_webrtc.js`. The destination
is per-thread and remembered (`public/js/manager/chat.js`).

## Token economy

The bill is generated text, not stored context. **Ask for the hunk**, and for the range
(`where.pl --outline`, `--body`) rather than the file; a change is a patch, not a whole-file rewrite.
**Keep the prefix stable**
(caching only pays when the top of the context does not move); **one thread plus narrow sub-agents**
returning `file:line`, never raw logs; **cap the loop** — plan → approve → execute, paste the failing
lines, `sed -n` a range instead of reading the file. **Ask the locator, not the map:**
`perl scripts/where.pl <name>`; `--tech <app>` prints the technical brief. The four local agents
(Guide, Coding, Evaluation, Pen), the creative apps and how a new app is added: `docs/AGENTS-agents.md`.
