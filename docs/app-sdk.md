# JawnOS App SDK

Status: design, 2026-11-03. Decision: pivot to a standard host API, then move apps onto it.

The goal is not "extract the apps" — it is to make an app a **thing with a contract**, so the same
app can run:

1. **embedded** in the monolith (today's JawnOS),
2. **standalone** as its own Mojolicious app with a local SQLite database,
3. **fleet** — several apps mounted on `JawnOS::Server`, or an app mounted in someone else's
   Mojolicious app with one `plugin` line.

The eleven library modules in `docs/cpan-roadmap.md` stay as they are. They are the components;
the SDK is the product; the apps are the proof.

## Why the current shape blocks it

An app today is eight registrations that share a name (`docs/cpan-roadmap.md:85`): routes scattered
between `lib/JawnOS/Routes/*.pm` and `perl/*.pl`, actions in `Controller/*.pm`, helpers in
`Manager/*` and `Domain/*`, templates, a lazy JS chunk in three maps, a help topic, and rows keyed
by `app` in shared tables. Nothing declares that set, so nothing can load it.

Worse, every app reaches into the same engine through package globals: `&db_query`, `&setting_grabber`,
`&note_encrypter`, `&session_suds`, `Websocket::send`, `subs::home`, `subs::lang`. That is why a
"copy the app out" extraction cannot work: the app would carry the monolith with it.

## The three modes

| Mode | What runs | Host | Database | Auth |
|---|---|---|---|---|
| Embedded | JawnOS (President → workers) | `JawnOS::Host::Local` — thin delegation to today's `subs::` | the house DB | house sessions/peers |
| Standalone | one app + `JawnOS::Server` | `JawnOS::Host::Solo` | its own SQLite file | local user (or `--no-auth`) |
| Fleet | `JawnOS::Server` with N apps | `JawnOS::Host::Solo` (or a shared remote host) | one SQLite per server | local user |

`JawnOS::Host::Local` is the compatibility layer. It changes no behaviour: it is the same functions,
behind methods, so the monolith keeps its current performance and the app stops calling globals.

## The host API (versioned)

```perl
package JawnOS::Host;
use Mojo::Base -base;

sub api_version { 1 }          # integer; additive changes bump the minor, never the shape
sub supports    { }            # supports('sync'), 'ble', 'ota', 'ai', 'mesh', 'pdf'

sub db       { }               # JawnOS::Host::DB
sub settings { }               # JawnOS::Host::Settings
sub auth     { }               # JawnOS::Host::Auth
sub crypto   { }               # JawnOS::Host::Crypto
sub files    { }               # JawnOS::Host::Files
sub events   { }               # JawnOS::Host::Events
sub jobs     { }               # JawnOS::Host::Jobs
sub sync     { }               # JawnOS::Host::Sync (optional)
sub clock    { }               # epoch milliseconds
sub ids      { }               # uuid / random string
sub i18n     { }               # t / ui
sub theme    { }               # palette, classes
sub log      { }               # structured log
sub http     { }               # base URL, peer user agent
sub app      { }               # cross-app capability: $host->app('gallery')
sub assets   { }               # this app's share dir
```

### What each service promises

| Service | Contract |
|---|---|
| `db` | `select($table, \@cols, \%where, \%opt)`, `insert`, `update`, `delete`, `tx(sub {...})`. An app may **read** shared tables and may **write** only rows scoped to its own `app` name, plus tables it declared in its manifest. DDL only through migrations. |
| `settings` | `get($key, default => …)`, `set($key, $value)`, `all`, `forget`. The host encrypts transparently; the app never sees ciphertext or the house key. Device-scoped values via `scope => 'device'`. |
| `auth` | `principal` → `{ id, name, admin }` or undef; `can($permission)`; `require($permission)`; `login`/`logout` in solo mode. |
| `crypto` | `seal($bytes)` / `open($bytes)` (house key); `wrap($secret, $public)` / `unwrap($blob, $private)`; `sign` / `verify`. Standalone generates a local key on first boot. |
| `files` | Virtual paths only: `root`, `put`, `get`, `stat`, `list`, `delete`, `thumb`, `seal`, `open`. The host resolves them to the house tree (embedded) or a sandbox directory (solo). **No app ever concatenates an absolute path.** |
| `events` | `emit($topic, \%data)`, `on($topic, sub {...})`, `to_client(\%payload)`. Embedded maps `to_client` to the WebSocket; solo maps it to an in-process bus (and optionally SSE). |
| `jobs` | `enqueue($kind, \%args)`, `status($id)`, `cancel($id)`, progress callbacks. Embedded uses the existing job rows; solo uses a fork/in-process queue. |
| `sync` | `tables`, `watermark`, `tombstone`, `apply`. **Optional**: `supports('sync')` is false in solo; an app must degrade, not fail. |
| `clock` | `now` (epoch ms), `format`, `parse`. Replaces `rightNow()` and `Time::Local` reach-arounds. |
| `ids` | `uuid`, `token($bytes)`. |
| `i18n` | `t('core_key')`, `ui('English sentence')`. Core labels resolve in the host catalog; app labels travel with the app. |
| `theme` | `class('panel')`, `palette`, `dark`. Keeps app CSS on the house's material without importing the theme. |
| `app` | `$host->app('gallery')` returns the declared capability object, or undef. This is the only legal way one app calls another. |

## The app contract

```perl
package JawnOS::App::Gallery;
use JawnOS::App -base;

sub manifest {
  {
    name        => 'gallery',
    title       => 'Gallery',
    icon        => 'gallery',
    category    => 'apps',
    requires    => [qw(files)],                  # host capabilities, not other apps
    provides    => { photos => 'JawnOS::App::Gallery::API' },
    tables      => [qw(gallery_album gallery_photo gallery_tag)],
    settings    => [qw(sort per_page)],
    permissions => [qw(read write delete)],
    host        => [qw(db settings auth crypto files events i18n theme clock ids)],
    host_optional => [qw(sync jobs)],
  }
}

sub routes {
  my ($self, $r) = @_;
  $r->get('/gallery' => sub {
    my $c = shift;
    return $c->render(text => 'no library', status => 404) unless $c->jawnos->auth->can('gallery.read');
    $c->render(gallery => $self->library->page);
  });
}

sub schema {
  my ($self, $m) = @_;
  $m->add(1, 'create table gallery_album (id text primary key, name text not null)');
}

sub assets { +{ templates => 'templates', js => 'js', css => 'css' } }
sub help   { +{ topic => 'gallery', category => 'apps' } }
sub jobs   { +{ 'gallery.reindex' => sub { ... } } }
```

Rules an app must satisfy:

1. No `subs::`, no `Manager::`, no `require './…'`, no `$main::`/package globals.
2. Every path through `files`; every key through `crypto`; every clock read through `clock`.
3. Every user-visible string through `i18n`.
4. Writes carry `app => $self->name`; shared tables are read-only unless the manifest declares them.
5. Another app is reached only through `$host->app(...)` or `events`.
6. Every table has a migration; no `create table if not exists` at request time.
7. The app runs with `supports('sync')` false and no network.

## Data: one database per app

A UI split is not a module boundary. `docs/app-databases.md` defines the data half:

- **core stays shared** — appointments, `continent`, settings, devices, credentials, `sync_*`;
- **each app owns `database/apps/<name>.db`** for its own normalized tables;
- **one connection, many schemas** — `database_grabber($app)` attaches the schema; the handle shape
  and every existing core query stay unchanged;
- **backup and sync carry a descriptor** — `{ db, table }`, one encrypted bundle with a manifest,
  and `sync_version = 4`;
- **cross-app reads** go through core `continent` or a declared capability, never another app's
  schema handle.

The empty-database trap matters: most app data lives in `appointments` today, so the value starts
when an app's own tables are normalized out, not when the file is created.

## App-to-app communication

Two mechanisms, both declared:

- **Capabilities** — `provides => { photos => 'JawnOS::App::Gallery::API' }`; a consumer declares
  `requires_app => [qw(photos)]` and calls `$host->app('photos')->near($lat, $lon, $when)`. The host
  resolves names, refuses cycles, and reports a missing provider at boot rather than at click time.
- **Events** — `emit('gallery.photo.added', {...})`; consumers subscribe. Embedded broadcasts to the
  WebSocket and the mesh; solo keeps them in-process and optionally re-emits over SSE.

No app reads another app's tables. That is the difference between a fleet and a monolith with
separate folders.

## Standalone mode

An app dist ships one executable:

```sh
cpanm JawnOS::Server JawnOS::App::Gallery
jawnos-app --app Gallery --port 3000 --db ./gallery.db --files ./files
```

or, in any Mojolicious application:

```perl
plugin 'JawnOS::App::Gallery' => host => JawnOS::Host::Solo->new(
  db      => './gallery.db',
  files   => './files',
  auth    => 'local',        # or 'none'
);
```

`JawnOS::Host::Solo` provides: SQLite with WAL and migrations, a local user (first boot prompts, or
`--no-auth`), a file sandbox, a generated data key, in-process events, a fork queue, the shipped i18n
catalog and a default theme. It does **not** provide mesh sync, BLE, OTA or AI; those are optional
capabilities of a different host, and `supports()` says so.

## Lifecycle and generated apps

`docs/app-lifecycle.md` is the operations half: the `apps` registry, `jawnos-app
install|uninstall|enable|disable|upgrade|doctor`, manifest validation, trust tiers (`core`,
`reviewed`, `agent`, `untrusted`), the Coding agent's generation pipeline (scaffold → tests →
canary → promote/rollback), per-app health and guarded auto-tuning.

In the SDK this appears as `JawnOS::App::Manager`, the `jawnos-app` CLI, `Host::Health`, and a
canary route prefix/schema used only while a candidate is being measured. The registry, not the
three hand-maintained JS maps, becomes the source of the route, asset, start-menu and help lists.

## Compatibility

- `api_version` is an integer. A host answers `$host->api_version`; an app declares the minimum it
  needs in `manifest->{host_api}`.
- Services are additive: a new method may appear, an existing one may not change meaning within a
  major version. Removed behaviour gets a deprecation cycle in `Changes`.
- Optional capabilities are queried, never assumed: `if ($host->supports('sync')) { ... }`.

## Migration plan

| Phase | Work | Acceptance |
|---|---|---|
| A | Introduce `JawnOS::Host::Local` as a thin delegation to today's functions; convert **Gallery** only. No route or UI change. Add the DB registry + `ATTACH` (`docs/app-databases.md` Phase 0). | The full suite is green; Gallery's actions no longer call `subs::`/`Manager::`. |
| B | Add `JawnOS::App` + manifest and a plugin loader; mount Gallery through it inside the monolith. | Gallery loads via `plugin`, the three JS maps are generated from manifests, and nothing else moves. |
| C | Add `JawnOS::Host::Solo` and `JawnOS::Server`; ship Gallery standalone. | `jawnos-app --app Gallery` serves the same page from a temp DB; its tests use the SDK harness. |
| D | Convert **Embedded**; formalize BLE/OTA/devices as optional capabilities. | Embedded runs embedded and standalone (hardware capabilities absent in solo). |
| E | Convert **Travel**, declaring its Gallery dependency as a capability. | Travel boots only when the photos capability resolves. |
| F | Convert **Music** last, or keep it host-only and extract `Audio::Stream::Sync` / `Media::Name`. | A decision, not an obligation. |
| G | Publish `JawnOS::Host`, `JawnOS::App`, `JawnOS::Server` and the app dists. | `cpanm` install, three-line plugin, standalone run. |

Phases A–C should land with lifecycle L0–L1 (`docs/app-lifecycle.md`): a registry and an
install/uninstall path are what make the plugin loader a product rather than a convention.

Phase A is deliberately invisible: the context object delegates to the code that exists, so the
monolith's performance and behaviour are unchanged while the seam is proven. If Phase A cannot be
done without touching every app at once, the contract is wrong and should be redrawn before B.

## Testing

`JawnOS::SDK::Test` builds a solo host in a temp directory:

```perl
use JawnOS::SDK::Test;
my $t = JawnOS::SDK::Test->new(app => 'JawnOS::App::Gallery');
$t->get_ok('/gallery')->status_is(200);
$t->post_ok('/gallery/upload' => form => { ... })->status_is(201);
```

- App tests live in the app dist and use the harness; no network, no house DB.
- The monolith keeps integration tests that mount the real host.
- A test that needs the Pico, the deck or the watch uses a fake capability object, exactly as the
  hardware modules do.
- `t/99-untested.t` shrinks as app files leave the tree; the app dist's own `t/` claims them.

## Publishing

CPAN names: `JawnOS-Host`, `JawnOS-App` (base), `JawnOS-Server`, then `JawnOS-App-Gallery`, etc.
Each app depends on the base and the host, ships templates/JS/CSS/help in a share dir
(`File::ShareDir::Install`), and documents "requires a JawnOS host or `JawnOS::Host::Solo`". Licence
stays BSD-2-Clause. The zero-friction contract in `docs/cpan-roadmap.md:35` applies: `cpanm`, one
plugin line, a working page.

## Risks

1. **API churn.** The host interface is the product now. Version it from day one and keep Phase A's
   delegation as the escape hatch.
2. **Performance.** Method calls in hot paths cost more than bare subs. `Host::Local` must stay a
   thin delegation, and hot helpers (clock, i18n) may be cached per request.
3. **Data migration.** Apps currently share tables with no prefix. The manifest's `tables` list is
   the future schema boundary; renaming should wait until the contract is stable.
4. **Auth in solo mode.** The house's principal/peer model does not map to a single-user app. Start
   with `local` and `none`; add accounts only when a second user exists.
5. **Assets and the renderer.** Today the renderer's class is `Manager`. Standalone needs an app
   namespace and share-dir templates; Phase B must prove both without breaking `.ep` includes.
6. **Optional hardware.** BLE, OTA, LoRa and mesh sync are capabilities, not guarantees. An app that
   assumes them is not portable; `supports()` is the test.
7. **Scope.** This is a 6–12 month program across six phases. The eleven modules keep shipping in
   parallel; the SDK never blocks them.

## What this changes in the roadmap

- Whole-app order: **Gallery pilot → Embedded → Travel → Music**, per the phases above.
- The 11 modules become host services where it helps: `Crypt::Sealed` (crypto), `Mojo::Tunnel`
  (transport), `Device::Bridge` (phone), `Device::Fleet` and `LoRaWAN::Uplink` (Embedded),
  `AI::Transport` (AI apps), `HTML::Allowlist` (Mail/Magazine), `Lock::SingleFlight`, `Log::Ring`
  and `App::TestsFor` (host runtime).
- `Business::POS::Register` and `Geometry::Coverage` remain reserves; they are app-level engines and
  would become the cores of Store and Travel.
