# Splitting a large file (index + parts)

The mechanics behind the `index + numbered parts` shape. **Read this when you are about to split
something, not on a normal task** — `AGENTS.md` keeps only the summary, because its 39 KB rides in
every agent request and this file does not.

Three things are split this way: a manager script over ~550 lines, a firmware sketch, and a big
template page. All follow the same rule: an index keeps the first contiguous segment and names the
parts, and the rest live in `NN_<slug>` files in name order.

---

## Big JS files (index + parts)

A manager script over roughly 550 lines is split the same way a big template page is:

- `public/js/manager/foo.js` stays as the **index** — it keeps the first contiguous
  segment of the old file (usually the header, globals and first section).
- `public/js/manager/foo/NN_<slug>.js` holds the rest **in numeric name order**
  (`01_…`, `02_…`). The folder is the app's own name, exactly like
  `templates/apps/video/{style,markup,script}.html.ep`.
- The index starts with a `/* [[js-split]] … [[/js-split]] */` block naming each
  part. That block is the only text a split may add; every other byte is moved.
- `/js/manager/bundle.js` expands the folder automatically via
  `subs::js_part_files()` (`Domain/Format.pm`), so **no change to
  `@manager_bundle_files` is needed** when a file is split. The signature/ETag
  includes the parts, so an edited part busts the cache.
- Scripts loaded outside the bundle (`websocket`, `jp`, `soft_keyboard` in the
  IME page) are expanded in the template with `subs::js_script_urls()`.
- Source-grep tests read a split script with `js_source()` from
  `t/lib/RepoSource.pm`; help's `resolve_files`/`hints` expand parts too.
- A new split is checked with
  `perl scripts/js_parts_check.pl /tmp/foo.orig.js public/js/manager/foo.js`
  (byte-identical + `node --check` on every piece) and pinned by `t/63-js-parts.t`.
- **Boundaries are top-level statements only** (depth 0): never cut a function,
  object/array literal, template string or regex. Keep a single larger construct
  whole in one part; a one-IIFE script may therefore stay one large part.

### Lazy app chunks

The page loads only the core bundle. An app's scripts arrive the first time the
app is opened:

- `%manager_app_scripts` in `lib/JawnOS/Manager/Core1_tables_hooks.pm` names each lazy app's files in
  bundle order (`%manager_app_entry` and `%manager_toggle_apps` are defined beside it). `@manager_core_files` is the full list minus every named entry, so
  a file you forget to map stays core (costs bytes, never breaks an app).
- `%manager_app_entry` names the functions core code may call before the chunk
  is there (the Handbook's Today cards, People opening Relational). `lazy.js`
  installs a stub; the real definition replaces it when the chunk loads.
- `%manager_toggle_apps` maps a start-menu icon's id/class to its app. Each app
  used to register its own click handler, so `lazy.js` catches the first click,
  loads the chunk, then re-finds and replays the click (falling back to
  `appWindowOpener` if the menu was re-rendered).
- `GET /js/manager/app.js?files=...` (`action_7408`) serves a whitelisted,
  minified, disk-cached chunk from the same index+parts. The loader serialises
  requests, so a script shared by two apps (the synth in Studio) runs once.
- `appWindowOpener` waits for the app's chunk before `appWindowOpenerNow`, so
  `pianoInit`/`studioInit`/`travelViewer` exist when the window is built.
- Both the core bundle and a chunk gzip when the request accepts it, and the
  layout preloads the core bundle. `Cache-Control` is still no-cache (304 on a
  repeat load), so a refresh always sees the current tree.
- Add a lazy app in one place: its files, entry functions and toggle id/class in
  the three maps. `t/63-js-parts.t` checks that the maps agree, every chunk
  parses, and the core/lazy split covers the bundle.
- **JavaScript that has run cannot be unloaded.** Lazy loading keeps a script out
  of the page until first use; closing the app can release its runtime objects,
  but the parsed code stays until the page is reloaded.

## Firmware sketches (index + parts)

`jw/jw.ino`, `jt/jt.ino` and `jp/alarmclock/alarmclock.ino` are now short indexes:

- The index keeps the original top `#include` block, a parts comment, and the
  only `void setup()` / `void loop()` in the sketch. They are thin wrappers:
  `void setup() { jawn_setup(); }` and `void loop() { jawn_loop(); }`.
- The original bodies, renamed `jawn_setup()` / `jawn_loop()`, live in
  `jw_01_*.ino`, `jt_01_*.ino`, `alarmclock_01_*.ino`, … in **original order**.
  PlatformIO concatenates every top-level `.ino` in the sketch folder, puts the
  file containing `setup`/`loop` first, then the rest in sorted name order.
- Keep any custom type used by a generated prototype (e.g. a struct returned by
  value) forward-declared in the index; PlatformIO inserts prototypes before the
  wrappers. Do not rename `setup1`, `loop1`, `setupLvgl` or similar.
- A split must rebuild: `pio run -j 4` in the sketch folder
  (`~/.platformio/penv/bin/pio`). Baselines: pico ~816 KB, watch ~2.45 MB,
  deck ~3.36 MB.

---

## The Perl split (for reference)

The same shape, already done: `lib/JawnOS/Manager/Part*.pm` (599 helpers) behind `Index.pm`,
`lib/JawnOS/Domain/*.pm` behind `Domain/Loader.pm`, and `Controller`/`Routes` chunked by the first
two path segments. Two facts an agent needs while doing normal work, not splitting:

- `lib/JawnOS/Manager/Index.pm` is the name → part map (`%SUB`); `Domain/Loader.pm` holds
  `%DOMAIN_MODULE`. **Do not read either to find one function** — run
  `perl scripts/where.pl <name>` and it prints `file:line`.
- `Manager/Declarations.pm` forward-declares every helper so the eager files compile under strict; a
  forward declaration does not block `AUTOLOAD`, so a call still loads its part.
