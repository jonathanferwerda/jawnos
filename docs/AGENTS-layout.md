# Layout

Moved out of `AGENTS.md` (a per-task reference, not an every-request map).

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
