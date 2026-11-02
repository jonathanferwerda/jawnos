# AGENTS.md — JawnOS map

A low-token index of where things live. Read this before searching, then search narrowly. Keep it short.

> Deep reference (data model, store/mail flows, firmware, history) lives in `docs/AGENTS-notes.md`.
> The notes are **gitignored — never commit them** (they carry fixtures and a login token). This map
> is tracked and published; it names files, never credentials.

---

## Next up (deferred)

- **House key — operational finish (no code left)**: Phase 2 shipped in v0.1.940–v0.1.959. The
  password is login-only (a bootstrap session never resolves the data key), `K_house` is wrapped to
  each device's key, and recovery is the paper code or 3-of-5 Shamir shares — there is no
  password-sealed copy of the key in the database. Two operational items remain (`docs/house-key-phase2.md`,
  "What remains"): run the lost-key drill on a physical spare machine with three shares the person
  actually holds, and resolve the two keyless Desktop window rows (bridge them or remove them).

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

  The master re-verifies the tree before it kills anything, and caches the verdict per file **content**
  in `~/.president/verify-manifest`: a restart with nothing new to judge is ~0.4s, a cold sweep (no
  manifest, new manifest version, `node` newly installed, or the last run failed) is ~2 min. Delete that
  file to force a full re-check; a failing run never updates it.

  The two sockets in `~/.president`/`~` are the master's: `control` (above) and the watch socket. Both are
  bound with `FD_CLOEXEC` and their `MOJO_REUSE` entry is dropped (`private_unix_listener` in `./jawn`) —
  Mojo otherwise expects a re-exec to inherit the fd, and with the fd closed but the entry kept, the next
  reload dies in `listen()` and the socket silently never comes back.
- Status values: `good` / `restart` / `frozen`.
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

- Built JawnOS Android APKs live in **`releases/`** at the repo root (gitignored: a ~35 MB binary per
  version would bloat git history forever, so the file rides the mesh as a **blob, not through git**).
  Names: `releases/jawnos-<product>-<versionCode>-<versionName>.apk` (`product` = `app` | `api`).
- **Stage a build:** `perl scripts/app_release.pl <apk>` reads its `versionCode`/`versionName` (via
  `aapt`) and copies it in, replacing older builds of the same product. It prints a note when a build
  does not out-number the staged one (devices would not see an update).
- **Build the next one:** `perl scripts/app_build.pl` bumps the app repo's versionCode and the
  versionName patch, builds the debug APK and stages it — so the next release is always the current
  number + 1 (1258 shipped; the next is 1259). `--no-build` stops after the bump.
- **Publish it (don't skip this):** `perl scripts/app_publish.pl` (needs an authenticated `gh`) uploads
  the newest staged APK **and** a matching `app_release.json` manifest to the GitHub `releases`
  release, so a device can pull it from github.com as well as from a peer. **A build that is only
  staged never reaches GitHub** — peers carry it, but a device reading the GitHub manifest sees the old
  versionCode and stays "up to date". Always build **and** publish.
- **Runtime zips ride the same release.** `scripts/runtime_build.pl` assembles the Perl runtime the APK
  unpacks on first run (`jawnrt-<arch>-<version>.zip` for the core, `jawnrt-<arch>-<part>-<version>.zip`
  for the optional parts such as `video`, `media`, `ocr`), and `app_publish.pl` uploads one when the
  GitHub release is missing it (or all of them with `--runtime`; `--no-runtime` skips). `releases/`
  holds the APK, those zips, and `native-bins` (the executables the app supplies as jniLibs).
- **The app repo has its own guide:** `~/jawnos-app/termux-app/AGENTS.md` — every change to the APK
  bumps `versionCode` and is published. Keep this section and that file in step.
- **Who serves it:** every jawn serves `GET /manager/app_release` (JSON: versions + sha256) and
  `GET /manager/app_download?product=app` (the bytes), `signatorial`-gated like `self_deploy`.
- **Who carries it:** `subs::app_release_sync()` (a 5-min loop in `President.pl`) reads local
  `releases/`, asks each reachable peer, and pulls the newest APK in (temp → sha256 → rename). Every
  device ends up holding the newest and can serve it.
- **Who installs it:** the Android app (`~/jawnos-app/termux-app`, branch `jawnos`, remote `fork`) reads
  the staged APK and offers a one-tap "Update app". Bump `versionCode` in `app/build.gradle` per release.
- The whole path is "whoever has the newest is the authority" — no fixed server. The desktop app has no
  such store: it is a copy of `desktop/`, so it follows the code sync.
- **table builds both artefacts itself** (2026-11-01): mkosi + a full jdk17-openjdk are installed there.
  `qa/nightly_build.sh` builds the QEMU image and then `assembleDebug`, unattended, under
  `jawnos-qa-build.timer` (Sun 03:00 — a cold image build is 20-40 min, so not nightly). Both are dev
  builds: no versionCode bump, nothing staged into `releases/`.

## Firmware / OTA (stage every build)

The manager serves device firmware from **hardwired paths**, not from a device's `.pio/build/`. An
unstaged build means an OTA sends the previous firmware.

- **alarmclock (Pico 2 W)** — OTA reads
  `jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin`. After `pio run` in
  `jp/alarmclock`, run `perl scripts/stage_firmware.pl` (or `--build` to build first). It copies
  `.pio/build/pico2w/firmware.bin` onto that path; add an entry to its `@targets` when another
  device gains a hardwired OTA path.
- **OTA needs a LittleFS partition.** `jp/alarmclock/platformio.ini` sets
  `board_build.filesystem_size = 2M` (2 MB sketch + 2 MB filesystem). The default 0 MB filesystem
  leaves the uploaded image nowhere to live and the new firmware boots without `config.txt`, so
  the device drops to its AP. Keep the split when changing the build.
- **ESP32 boards** — the panel hands over the picked `.bin` (`ota_uploader_wifi`), so pick the build
  from that device's `.pio/build/<env>/`; `usb_upload` builds on the machine over USB.
- **LoRaWAN (T-Deck SX1262)** — Chat's **LoRa** section owns the network mode. Credentials are
  `mail/lorawan_*` settings (band, sub-band, Join/Dev EUI, App key, port, confirmed); the manager
  pushes them to the deck's `/lorawan_config` and drives `/lorawan_join`, `/lorawan_send` and
  `/lorawan_status`. A LoRaWAN network server forwards uplinks to `/watch/lorawan?token=…` (the URL
  is shown in the panel), and downlinks reach `/watch/chat_received?transport=lorawan`. While
  LoRaWAN is on, the old raw-LoRa point-to-point broadcast/receive stand down. Build and stage the
  firmware with the same `stage_firmware.pl` path before an OTA.

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

**Root — entry point and config only.** `jawn` (master), `README.md`, `LICENSE`, `VERSION`,
`config.json(.example)`, `Makefile.PL`, `AGENTS.md`, and the data directories. **The Perl service
layer is `perl/`**: `President.pl`, `Manager.pl` (**a ~24-line launcher** — `require JawnOS`, build
the app, `start` for a worker), `Websocket.pl`, `Alarm.pl`, `Music.pl`, `watch.pl`, `teletype.pl`,
`subroutines.pl`, `gb.pl`, `hooks.pl`, `help.pl`, `language.pl`, and the rest. Every `require` of
them is cwd-relative (`require './perl/Manager.pl'`), so the tree still runs from its root; the
three files that derive a path from their own location know they live one level down.

**The app is `lib/JawnOS.pm`** (`Mojo::Base 'Mojolicious'`): its `startup` publishes the app as
`$Manager::APP` (`Manager::app`), requires the bootstrap, and registers the routes. `Manager` is the
controller class — routes use `$r->namespaces(['main'])`, because a top-level package is reachable as
`main::Manager` and `->to(controller => 'Manager')` then resolves without renaming the package every
template and script calls.

- `lib/JawnOS/Controller/*.pm` — the 816 route actions, one `sub action_<line>` per route, package
  `Manager`, ~600 lines per file, each action headed by `# GET /path`. Chunked by the first two path
  segments (`manager_configure2`, `manager_misc7`, …).
- `lib/JawnOS/Routes.pm` + `lib/JawnOS/Routes/*.pm` — the route table. Registration order is the
  original line number, so first-match-wins is unchanged. `@NAMES` is the list; a new route group
  needs an entry there and a matching Controller and Routes module.
- `lib/JawnOS/Manager.pm` — the old body without routes: config, state, helpers-that-stay, the hooks,
  and the two eager `require`s of the **Core** parts. The three `$ENV{PURPOSE}` blocks a worker runs at
  load (websocket sockets, sessions/secrets) live in `Manager/Core2_worker_boot.pm`; **they must stay
  eager** — in a lazy part the worker boots deaf and cookieless. `Core1_tables_hooks.pm` is eager too:
  it holds the table hooks and the manager bundle maps.
- `lib/JawnOS/Manager/Part*.pm` — 599 helpers (~650 lines each), package `Manager`, **lazy**: the
  first call goes through `Manager::AUTOLOAD`, which `require`s the part that `Index.pm` names.
  `Declarations.pm` forward-declares every name so the eager files compile under strict and a call
  still reaches AUTOLOAD (a forward declaration does not block it).
- `lib/JawnOS/Domain/*.pm` — package `subs`, split by feature (~600 lines each), lazy via
  `Domain/Loader.pm`; `subs::provides($name)` asks without loading, `subs::preload($name)` loads
  without calling.

**Lite is gone from the app.** `Music.pl` and `hooks.pl` are compiled into package `Manager`; a
`use Mojolicious::Lite` there re-ran the import and built a second app, re-pointing
`app()`/`get()`/`new()` — which is how every later route used to land on one app. Their routes and
hooks now call `Manager::app->routes->…` / `Manager::app->hook(…)` explicitly. The domain layer keeps
its `subs::app` accessor in `Domain/Calendar.pm` for its background renderer.

Plus `config.json(.example)`, `Makefile.PL`, `README.md`, `LICENSE`, `.gitignore`, and this `AGENTS.md`.

| Folder | What lives there |
| --- | --- |
| `.shots/` | scratch/probe area + `ticket.txt` (gitignored) |
| `releases/` | staged Android APKs (gitignored blob store; see App releases above) |
| `lib/` | `JawnOS.pm` (the app), `JawnOS/Manager.pm` + `JawnOS/Manager/Part*.pm` (package `Manager`; parts lazy via `AUTOLOAD`), `JawnOS/Controller/*` (route actions), `JawnOS/Routes*` (the table), `JawnOS/Domain/*` (package `subs`, lazy via `Domain/Loader.pm`); on `@INC` via `use lib`/`prove -l` |
| `database/` | `initial.enc`, `schema.sql` |
| `desktop/` | Linux app: `jawnos_desktop/`, `icons/`, `systemd/`, `wayland/`, entry points `jawnosctl` / `jawnos-desktop` / `jawnos-bt-daemon` |
| `docs/` | docs + `screenshots/`; **`AGENTS-notes.md`** (deep notes) |
| `jp/` | only `alarmclock/` (index + `alarmclock_NN_*.ino` parts) |
| `jt/` | T-Deck firmware: `jt.ino` (index) + `jt_NN_*.ino` parts, `platformio.ini`, `lv_conf.h`, `utilities.h`, font headers, `boards/`, `data/` (`.pio/`, `build/` generated) |
| `jw/` | watch firmware: `jw.ino` (index) + `jw_NN_*.ino` parts, `platformio.ini`, `lv_conf.h`, `fonts/`, `tools/`, `boards/` (`.pio/`, `build/` generated) |
| `public/` | served assets: `css/`, `js/` (manager scripts are `foo.js` indexes + `foo/` parts), `images/`, `icons/`, `sounds/`, `service_worker.js` |
| `scripts/` | CLI/admin: `*.pl`, `jawn-bt`, `termux_runner.sh` |
| `server/` | only `inventory.jawn` |
| `signatorials/` | empty |
| `templates/` | Mojo `.ep` templates: pages at the top level + feature subfolders (`apps/`, `configure/`, `store/`, `mail/`, `pos/`, `market/`, `handbook/`, `layouts/`, `terminal/`, `warehouse/`, `web/`, `websockets/`, …). A page over ~300 lines is a short page that includes partials from a folder of its own name (`apps/video/{style,markup,script}.html.ep`); a partial inherits the stash, so only a parent `<% my %>` local is passed on the include line |
| `perl/` | the service layer (see above); `lib/` holds the app, controllers, routes and domain modules |

**Searching:** start in the most specific folder above; prefer `grep`/`find_path` scoped to a subtree;
never read or edit generated `.pio/`/`build/`; if a file isn't on this map and 3 attempts fail, invoke RULE 1.

---

## Help system (keep it accurate)

The in-app guide lives in `help.pl` (a `%topic` registry) and is served by the `help` app
(`templates/apps/help.html.ep`, `public/js/manager/help.js`, routes `/manager/help`, `/manager/help/body`,
`/manager/help/ask`). The guide agent answers through `subs::evaluation_model_call`.

**When you change an app's UI, update its topic in the same commit.** Then:

- `perl scripts/help_audit.pl` — checks every topic against the tree: broken `related` links, listed
  templates that have moved, `controls` a topic names that are no longer on-screen hints, and topics
  whose app's files changed since `verified` (a date; a global default lives at the top of `help.pl`).
  `--quiet` shows errors+stale; `--all` also lists fragment templates with no topic.
- The audit runs on `git push` via `.githooks/pre-push` (enable once: `git config core.hooksPath .githooks`).
  Hard errors block; stale topics print as a to-do. Bypass with `git push --no-verify`.
- The guide is also handed a **generated inventory** (`help::inventory`) built from each topic's
  `templates` (plus the conventional `templates/apps/<app>.html.ep` / `public/js/manager/<app>.js`),
  listing the real on-screen hints. Keep button labels and the topic's words identical so the two agree.
- To bind a topic to files the convention misses (e.g. `handbook`, `process_monitor`, `web`), give it a
  `templates => [ ... ]` list; give a topic a `controls => [ ... ]` list to have the auditor verify the
  names it mentions still exist.
- Vetting a topic for real: run a fixture-only probe (see `.shots/help_probe*.js`, `.shots/gallery_probe.js`)
  — create a fixture appointment of an allowed type, drive the app, then clean up and restore every
  setting you touched. Fixture rules above still apply.
- **Translation is part of a help change.** A new or renamed topic title, summary, step or paragraph must
  be written in English and left translatable; the Guide's `translate`/`translate_page` engine handles the
  rest on demand. If the change adds a core interface label, add all sixteen translations in `language.pl`
  in the same commit. Run `perl scripts/help_audit.pl`; run `perl scripts/i18n_audit.pl` if you maintain
  the optional bulk catalogs.

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

The bill is generated text, not stored context. Four rules that move it:

- **Ask for the hunk.** "Return only the changed lines; do not restate code you did not change."
  Whole-file rewrites are the most expensive habit available.
- **Keep the prefix stable.** Automatic prefix caching only pays when the top of the context does not
  move; editing early messages, reordering files, or re-pasting the same file invalidates it.
- **Concurrency multiplies context.** Each parallel agent re-sends the same repo context and builds its
  own cache. One main thread plus narrow sub-agents returning `file:line` beats three broad agents.
- **Cap the loop.** Plan → approve → execute; paste the failing lines instead of re-running a suite;
  `sed -n` a range instead of reading the file.
- **Ask the locator, not the map.** `perl scripts/where.pl <name>` answers "where is this function" in
  one line; reading `Index.pm` or grepping nine parts costs ~20 KB for the same answer.

**Agents (local, optional, and all on the same records).** Four, plus the generators Pen can call:

- **Guide** — `help.pl`, `POST /manager/help/ask`, `subs::evaluation_model_call`. Teaches the program
  and acts: opens apps, starts music, answers what happened, is happening, or will happen. Its memory
  is the Handbook: goals, plans and journals are records like everything else.
- **Coding** — `public/js/manager/coding.js`, `templates/apps/coding_chat.html.ep`. Edits the repo,
  compiles, bumps/commits/pushes, restarts. Doubles as the **error watch** (Configure → Plat →
  Self-healing): reads `~/pty.log`, `manager.log` and browser fatals, stages a proposed fix, and only
  writes on Apply (or auto-Apply). One watch per house; the first machine with a model takes each error.
- **Evaluation** — server-rendered rather than a client app: `templates/apps/evaluation*.ep` (the
  report block at an appointment's foot and in Configure → Misc), with `subs::evaluation_report_for`
  (`Domain/Budget2.pm`) and `subs::evaluation_model_call*` (`Domain/Ai2.pm`). Reads measures and
  the relationships between events, reports correlations and predictions; also feeds ghost appointments.
- **Pen** — `public/js/manager/pen.js` and `subs::pen_message` (`Domain/Sent.pm`); there is **no
  `pen.pl`**. General chat with memory that routes to audio, video and image generation
  (`ai_extract_generation_action`), then files the output into Studio, Marker or Music. It is the
  mailbox's assistant section as an app of its own: `pen.js` fetches `# GET /manager/pen`
  (`Controller/manager_misc10.pm`), which renders the mailbox scoped to the pen section.

**Creative apps.** Studio (`public/js/manager/studio.js`, `templates/studio`) is multitrack,
multi-input recording. Marker (`public/js/manager/marker.js`) is multilayer paint with snapshots and
playback, exports image/video, and can be dragged over a video or image as an overlay. Music
(`Music.pl`, `templates/apps/music`) plays audio and video with subtitles and streams single audio
channels, or the video, to remote machines.

**New apps.** There is no app generator. The start menu is built from the app registry (`help.pl` notes
that adding an app cannot drop it from the sheet), so the Coding agent adds one the way a person would:
a template, a route, a registry entry. Prompt it with the behaviour you want — "a new app in the start
menu that finds Bluetooth devices and adds them to Embedded so I can bind their controls to start and
stop" — and it writes, checks, bumps, and ships the code.
