# CPAN module roadmap

Status: proposal, 2026-11-02. No code has been extracted yet.

The goal is a set of standalone CPAN distributions that **JawnOS consumes**, not copies of
JawnOS code. A module is only worth publishing if it is useful without JawnOS, has a clean seam
here, and can be tested without the hardware.

Two facts make this practical:

- `./jawn:15-33` already resolves `~/perl5/lib/perl5` into `PERL5LIB`, and `cpanm` is installed.
  An installed module needs no vendoring.
- The candidates below are **less** coupled than their file sizes suggest. `perl/tunnel.pl` has
  zero `subs::` calls; `Domain/Article.pm` has zero; the phone bridge, the lock marker and the
  LoRaWAN uplink decoder are each a handful of pure functions over injected state.

## Rules of engagement

1. **One dist per module.** Own `Makefile.PL`/`cpanfile`, `Changes`, `README.md`, `t/`, and a
   version independent of `VERSION`.
2. **Delete the source here** in the same change that switches JawnOS to `use`. A module with two
   copies is worse than no module.
3. **Tests move with the module.** JawnOS keeps only integration tests that claim the thin
   adapter. The extracted file leaves `t/99-untested.t`'s debt list as it gains real tests.
4. **Generic names.** `JawnOS::*` only where the noun is genuinely house-specific (crest, vouch).
   Everything else gets a searchable name.
5. **No insecure default ships.** `$ua->insecure(1)` (`perl/tunnel.pl:40`) is a JawnOS choice, not
   a library default.
6. **Hardware tests use a fake transport.** A module that needs the deck, the watch or the Pico to
   pass is not testable and will rot.
7. **Eleven is the cap.** Each dist is a version to bump, a PAUSE release, and a security surface.
   The bench exists so the cap can be enforced without losing the ideas. Reserves: `#31`
   `Business::POS::Register`, then `#35` `Geometry::Coverage`.

## The zero-friction contract

A module that needs a technical document before it can be wired up has failed, whatever its
quality. Every entry must pass this before release:

| Rule | Test |
|---|---|
| Installs in seconds | `cpanm Module` with no mandatory compiler step beyond deps already present (CryptX, HTML::Parser). No Moose/Mouse/Type::Tiny. |
| One obvious entry point | `Module->new(%opts)` with no required argument where a sane default exists; environment variables (`OPENAI_API_KEY`, `DEVICE_TOKEN`) fill the rest. |
| Three lines to first success | the SYNOPSIS is a working example, not a sketch. If it cannot be wired in three lines, the API is wrong. |
| Errors say the fix | `"pass rp_id => 'example.com' (or set WEBAUTHN_RP_ID)"`, never `"invalid argument"`. |
| Heavy work is lazy | `require` an optional dependency only on the path that needs it, so the install stays small. |
| No hidden state | no cwd dependency, no `$HOME` writes, no globals; every default is documented and overridable. |
| A demo ships | `eg/` or `bin/` runs offline against `127.0.0.1` or fixtures. |
| Docs lead with the answer | SYNOPSIS, a ten-line **Quick start**, then the reference. Theory goes in NOTES, which nobody is required to read. |

### The three-line wire-up (target SYNOPSIS)

| Module | First success |
|---|---|
| `Mojo::Tunnel` | `my $hub = Mojo::Tunnel->hub($ws, listen => { ssh => { source => 2222, dest => 22 } });` |
| `WebAuthn::Verify` | `my ($ok, $cred) = WebAuthn::Verify::registration($json, rp_id => 'example.com');` |
| `Crypt::Sealed` | `my $blob = Crypt::Sealed::seal($secret, $recipient_pub);` |
| `LoRaWAN::Uplink` | `my $up = LoRaWAN::Uplink::decode($webhook_json);` |
| `Device::Fleet` | `my $fleet = Device::Fleet->new(send => sub { ... }); $fleet->register(%device);` |
| `AI::Transport` | `my $t = AI::Transport->new(provider => 'openai'); my $req = $t->encode(\@messages);` |
| `HTML::Allowlist` | `my $safe = HTML::Allowlist::clean($html);` |
| `Device::Bridge` | `my $battery = Device::Bridge->new->call('battery.status');` |
| `Lock::SingleFlight` | `Lock::SingleFlight->new(store => $db)->claim('pull') or die "busy";` |
| `App::TestsFor` | `my @tests = App::TestsFor->new->tests_for(@changed);` |
| `Log::Ring` | `my $ring = Log::Ring->new(max => 2_000_000); $ring->append($bytes);` |

If a module cannot reach that shape, it is not ready — the fix is the API, not a longer README.

## How JawnOS consumes one

For a module `Foo::Bar` extracted from `lib/JawnOS/Domain/Baz.pm`:

- replace `&subs::bar(...)` with `Foo::Bar::bar(...)` (or an object), and `use Foo::Bar;` at the
  top of the consuming part;
- remove `bar` from the `%DOMAIN_MODULE` map in `lib/JawnOS/Domain/Loader.pm` (or `%SUB` in
  `lib/JawnOS/Manager/Index.pm` for a Manager helper) — `t/91` and `t/54` fail on drift;
- if a route disappears or an app page changes, update the help topic (`t/11`);
- the file itself is deleted, so `t/99-untested.t` shrinks and `t/49-cross-package-subs.t` sees a
  new require edge;
- install on this box with `cpanm .` in the dist, then restart the tree (a new `.pm` is only read
  at process start). A dist upgrade is a normal restart, not an OTA;
- `perl scripts/where.pl <name>` must stop reporting the old part after the change; the locator is
  the acceptance test that the seam was cut cleanly.

## Whole apps: the contract question

Could Music, Travel, Gallery or Embedded become a CPAN distribution of its own? **Yes — but not by
copying an app out.** An app here is not a module; it is eight registrations that happen to agree
on a name:

| Where | What it registers |
|---|---|
| `lib/JawnOS/Routes/*.pm` (and sometimes `perl/*.pl`) | routes |
| `lib/JawnOS/Controller/*.pm` | actions |
| `lib/JawnOS/Manager/*.pm`, `lib/JawnOS/Domain/*.pm` | helpers |
| `templates/apps/…`, `templates/<app>/…` | pages |
| `public/js/manager/<app>.js`, `public/js/manager/<app>/` | the lazy chunk |
| `%manager_app_scripts`, `%manager_app_entry`, `%manager_toggle_apps` (`Manager/Core1_tables_hooks.pm:648-714`) | the bundle, entries and start-menu toggle |
| `perl/help/topics_*.pl` | the help topic (`t/11`) |
| rows keyed by `app` in `appointments`, `settings`, `cache`, … | the data |

Measured today:

| App | Perl | JS | Templates | Routes | Coupling |
|---|---|---|---|---|---|
| **Embedded** | 685 (controller) + Manager helpers | 1,089 | 612 | 19 | devices, BLE bridge, OTA, settings |
| **Folders** | 2,123 (domain + 2 controllers) | 1,868 | 172 page + partials | 22 | files, crypto, jobs, archive machines |
| **Gallery** | 331 (controller) | template-driven, no app chunk | 224 | 4 | files, thumbnails, encryption, private albums |
| **Travel** | 596 (controller) + helpers | 1,657 | 110 | 8 | files, measures, Gallery, maps, georef |
| **Music** | 2,882 (`Music.pl` + 8 parts) | 6,076 | ~690 | 9 (registered inside `Music.pl`, not the route map) | archive, folders, encryption, WebSocket, remote audio/video |

Two facts decide the feasibility:

1. **Every app uses host powers it does not own**: the database and its `app`-scoped rows, settings,
   sessions and principals, encrypted files, the WebSocket channel, i18n, theme, the lazy JS bundle
   and the sync/watermark machinery. A CPAN dist that “works on its own” is impossible for these;
   a dist that **plugs into a JawnOS host** is possible.
2. **There is no app contract today**, only conventions. Music even registers its routes directly on
   `Manager::app` (`perl/Music.pl:126`, `:256`), so there are two route registries to unify before
   anything can be mounted.

### What a real extraction needs

1. **A host SDK** — `JawnOS::App` with a manifest (`name`, `title`, `icon`, `requires`, `tables`,
   `settings`) and a context object that hands an app: db, settings, cache, principal/permissions,
   crypto, files/media, WebSocket send, i18n, theme, jobs and logging. Nothing global, nothing
   `subs::`.
2. **Three registration calls** — `routes($r)`, `assets` (templates/JS/CSS from `File::ShareDir`),
   `help` (topic text). Plus `schema` (ordered migrations) and `tests` (a harness that boots a
   minimal host).
3. **One line at the host** — `plugin 'JawnOS::App::Gallery'` (or a `%apps` manifest) so the
   zero-friction rule still holds: `cpanm JawnOS::App::Gallery`, add the plugin, open the app.
4. **The data stays where it is** — apps are rows keyed by app name, not their own schemas. An app
   dist still writes into the host's tables; that is the price of portability here. The next step
   after the contract is per-app databases: `docs/app-databases.md` keeps the core shared, gives
   each app its own attached schema, and makes backup/sync carry `{ db, table }` descriptors.

### Order, if it is done

1. **Gallery** — pilot for the SDK, per `docs/app-sdk.md`. Smallest controller, no app JS chunk,
   server-rendered; it proves the host contract (db, files, crypto, auth, assets) with the least
   surface. It is the app to make stand alone first.
2. **Embedded** — the hardware proof: optional capabilities (BLE, OTA, device registry) and the
   first app that is not pure request/response.
3. **Travel** — depends on Gallery, files and measures being reachable through the host context; the
   map engine is 1.6k lines of browser code that has to ship as an asset.
4. **Music** — last, and plausibly never. 6k lines of player JS, remote audio/video, WebSockets,
   archives and sealed media. The valuable parts are already on the eleven (`Audio::Stream::Sync`,
   `Media::Name`), and the player is a browser application, not a library.

**Recommendation.** Do not put whole apps on CPAN in this roadmap's first year. The eleven modules
are the reusable core of these apps; extracting them makes each app thinner and is the prerequisite
work either way. Revisit whole apps only if a third-party app ecosystem or a headless app runtime is
actually wanted — then build the host SDK and ship `JawnOS::App::Gallery` as the proof.
`docs/app-sdk.md` is that design. The operations half — the `apps` registry, install/uninstall and
upgrade, agent-built apps, per-app health and the v1 fork criteria — is `docs/app-lifecycle.md`.

## The 41 candidates

Thirty from the first pass, four from the store/handbook/marker/music pass, four from the
travel/soft-keyboard pass, three from the folders pass. Gap = what CPAN lacks today (checked on MetaCPAN 2026-11-02). Effort: S ≈ 1–3 days, M ≈ 1–2 weeks, L ≈ 2–4 weeks
including tests. PICK = the eleven; RESERVE = first to replace a slip; BENCH = keep, do not start;
DROP = no.

### Transport, presence, local IPC

| # | Candidate | Source | Gap | Effort | Verdict |
|---|---|---|---|---|---|
| 1 | `Mojo::Tunnel` | `perl/tunnel.pl` (412) | multiplexed TCP over one WS with a rendezvous hub; no Perl equivalent surfaced | M | **PICK** |
| 2 | `Log::Ring` | `lib/JawnOS/LogBus.pm` (196) | sequence-numbered byte ring over a Unix socket with a cursor; `Data::RingBuffer` is only an array | S | **PICK** |
| 3 | `Device::Bridge` | `Domain/Say.pm:600-690` | token-auth JSON-line loopback RPC with soft failure and cooldown; nothing generic | S | **PICK** |
| 4 | `Input::Inject` | `perl/remote_input.pl` (328) | backend-agnostic wtype/ydotool/X11/Wayland injection + clipboard; name free | M | BENCH |
| 5 | `Net::Discovery` | `Domain/Device.pm:489` (`device_lister`, `device_scan`) | neighbourhood/vendor discovery with de-duplication by address; `Net::Bonjour` doesn't cover it | M | BENCH |

### Crypto, identity, records

| # | Candidate | Source | Gap | Effort | Verdict |
|---|---|---|---|---|---|
| 6 | `WebAuthn::Verify` | `perl/webauthn.pl` (456) | `Authen::WebAuthn` exists but pulls CBOR::XS/Mouse/X509; no dependency-light, no-attestation, storage-injected verifier | M | **PICK** |
| 7 | `Crypt::Sealed` | `Domain/Tunnel.pm` (`house_key_wrap`) | X25519 + HKDF + AES-256-GCM sealed key delivery; no age-style Perl module | S | **PICK** |
| 8 | `HTTP::Sig::Peer` | `Domain/Crypt.pm` (`peer_sign_*`) | Ed25519 detached request signing with canonicalisation; `HTTP::Signature` is HMAC-oriented | M | BENCH |
| 9 | `Crest::Record` | `Domain/Crest.pm` | signed identity record + member co-signatures + vouches; novel but house-shaped | L | BENCH |
| 10 | `Payment::Proof` | `Domain/Crypto.pm` (`payment_proof_*`) | payer/payee signed statement with counter-signature; nothing on CPAN | M | BENCH |
| 11 | `Bitcoin::BIP32::Watch` | `Domain/Crypto.pm:60-140` | watch-only xpub child + address encoding | M | DROP — `Bitcoin::Crypto` 4.005 covers it |

### Devices, IoT, hardware (watch · Pico · T-Deck · LoRa)

| # | Candidate | Source | Gap | Effort | Verdict |
|---|---|---|---|---|---|
| 12 | `LoRaWAN::Uplink` | `Manager/Part31.pm`, `Part32.pm`, `Controller/watch_misc.pm` | TTN/ChirpStack uplink normalisation + credential/document validation in Perl; nothing on CPAN | M | **PICK** |
| 13 | `Device::Fleet` | `Domain/Network.pm:600-680`, `Manager/Part35.pm` (`now_me`, board config), `Domain/Device.pm`, `Domain/Ble.pm:383` | capability registry + homebase ownership + relay envelope (hop budget, dedupe) + board documents; no Perl fleet/automation protocol | L | **PICK** |
| 14 | `Mesh::Relay` | `Domain/Network.pm:600-680` | transport-agnostic relay routing; could split from #13 if the surface stays clean | S | BENCH |
| 15 | `Firmware::OTA::Stage` | `scripts/stage_firmware.pl`, `Controller/manager_embedded.pm:295` | stage a PlatformIO/Arduino build at a stable path with product/version/sha256 manifest; nothing on CPAN | S | BENCH |
| 16 | `Net::Bluetooth::NUS` | `Domain/Ble.pm`, `bluetooth_sender_async` | BLE Nordic UART framing over an app bridge; fragmented JSON envelopes | M | BENCH |
| 17 | `Termux::API::Typed` | `Domain/Say.pm:511-557` | typed, decoded Termux calls + `am` intents + injectable runner; `Termux::API` 1.01 is a string wrapper | M | BENCH |
| 18 | `App::APK::Release` | `scripts/app_release.pl`, `app_build.pl`, `app_publish.pl`, `subs::app_release_sync` | stage/versionCode bump/publish APK + manifest as release assets; nothing in Perl | M | BENCH |
| 19 | `Device::Battery::Curve` | `Domain/Pph.pm` | paired battery-sample comparison, gauge ETA, robust slope/hour | S | BENCH |

### AI

| # | Candidate | Source | Gap | Effort | Verdict |
|---|---|---|---|---|---|
| 20 | `AI::Transport` | `Domain/Ai2.pm` wire layer (`ai_content_*`, `ai_wire_message`, `ai_response_*`, `ai_stream_*`) | one neutral message/parts model for OpenAI + Anthropic + Google with SSE reasoning deltas; `AI::Chat` is OpenAI-only | M | **PICK** |
| 21 | `AI::Agent::Loop` | `Domain/Coding.pm`, `perl/Coding.pl` | long-lived agent run outside a web worker: protocol, checkpoints, resume | L | BENCH |
| 22 | `Job::Placement` | `perl/crew.pl` (`choose_model`, `_candidate_viable`, abilities) | place a job on the machine that can run it (cores/RAM/disk/model/tools) | M | BENCH |
| 23 | `AI::Eval` | `Domain/Evaluation.pm` | model evaluation with model-call pacing and provider limits | M | BENCH |

### Sync and reliability

| # | Candidate | Source | Gap | Effort | Verdict |
|---|---|---|---|---|---|
| 24 | `Lock::SingleFlight` | `Domain/Sync.pm:400-430` | three-TTL lease (live pid / claim / dead) with claim adoption; `File::Flock` doesn't express it | S | **PICK** |
| 25 | `Job::Progress` | `Domain/Sync.pm:150-260` | durable job with named steps + reaper for a dead owner | S | BENCH |
| 26 | `Tombstone::Log` | `Domain/Sync.pm` (`tombstone_*`, `sync_cursors`) | deletion log with per-reader cursor GC for offline replicas | M | BENCH |

### Web, text, tooling

| # | Candidate | Source | Gap | Effort | Verdict |
|---|---|---|---|---|---|
| 27 | `HTML::Allowlist` | `Domain/Article.pm` (180) | tag/attr **and CSS property** allowlist + URL scheme policy + nesting repair; `HTML::Restrict` has no CSS layer | S | **PICK** |
| 28 | `App::TestsFor` | `scripts/tests_for.pl`, `run_tests_fork.pl` | changed-path → test selection from in-file `tests-for:` claims; nothing on CPAN | M | **PICK** |
| 29 | `I18n::Llm` | `scripts/i18n_extract.pl`, `i18n_translate.pl`, `i18n_audit.pl`, `perl/language.pl` | fill missing catalog entries with a model, audit coverage; extraction overlaps Locale::Maketext | M | BENCH |
| 30 | `Schedule::Recur` | `Domain/Schedule.pm` (`schedule_next`, `nth_weekday_of_month`, `easter_sunday`) | recurrence keeping local time-of-day across months | M | DROP — Date::Calc / DateTime::Event::Recurrence cover it |

Also considered and dismissed: `Date::Human` (`Domain/Resolve.pm` — `DateTime::Format::Natural`
1.27, June 2026, is active), `Business::Change` (`Domain/Store.pm` — too small on its own),
`Server::Control` shim (`perl/control.pl` — an older module exists and this one is verdict-shaped),
`Where` (`scripts/where.pl`) and `Agent::Help` (`scripts/agent_help.pl`) — both read JawnOS's own
maps and have no meaning elsewhere.

### Second pass: store, handbook, marker, music

| # | Candidate | Source | Gap | Effort | Verdict |
|---|---|---|---|---|---|
| 31 | `Business::POS::Register` | `Domain/Store.pm` (329 lines, database-free; calls four app helpers: `lang`, `right`, `random_string_creator`, `format_name`) | order/line/quantity lifecycle, payment-method validation, denominations, change breakdown, underpayment refusal; CPAN has payment gateways but no till | S | RESERVE |
| 32 | `Media::Name` | `perl/Music.pl:63-100`, `Domain/File.pm` | artist/album/track from tags **and** episode/season from names (`S03E06`, `1x02`, `Season 3 Episode 6`), quality/codec/group stripped; `Video::Filename` is 2009, GPL and video-only | S | BENCH |
| 33 | `Audio::Stream::Sync` | `perl/Music/01_remote_audio_receiver.pl`, `public/js/music.js` | remote audio lead measurement, stale-frame drop, L/R split, Opus/PCM choice | L | BENCH |
| 34 | `Marker::Session` | `Manager/Part35.pm:334-380` | layered canvas session blobs with autosave | S | DROP — the drawing is client-side; only a blob store would ship |

- **Handbook** is an aggregation view (Today reads money, measures, notes, projects and people;
  Plant calls the Guide). Its reusable parts are `Resolve` (dates, dismissed above) and the AI
  transport. Nothing on its own.
- **Marker** is a layered paint board in the browser; the server only stores session serialisations
  (`marker_sessions`, `marker_session_store`). A module here would be a generic “JSON blob with a
  thumbnail”, which is not worth a dist.
- **Store** gave one real candidate. `Domain/Store.pm` is database-free and pure money maths; it
  calls four app helpers (i18n, the clock, a random id, name formatting) that become constructor
  arguments. It is the reserve because it is the easiest of the whole list to make excellent.
- **Music** gave two: the library-name parser (small, pure) and the remote-audio synchroniser
  (large, browser-shaped). The player itself is not a Perl module.

### Third pass: travel and the soft keyboard

| # | Candidate | Source | Gap | Effort | Verdict |
|---|---|---|---|---|---|
| 35 | `Geometry::Coverage` | `Manager/Part25.pm:553-660` (`travel_map_bounds`, `travel_uncovered_pocket`), `Part26.pm:63-150` (`travel_pocket_*`) | largest all-empty rectangle in a grid plus directional growth into a viewport; no CPAN equivalent surfaced | S | RESERVE 2 |
| 36 | `Geo::Georef` | `Manager/Part25.pm:553-587` (`travel_map_bounds`) | georeference a flat image from a home plate, a drawn scale bar and the image size, including a bar recorded in a different pixel space | S | BENCH |
| 37 | `Media::Geo` | `Manager/Part25.pm:387` (`travel_nearby_items`) | files counted near a position fix in space **and** time | S | DROP — the query is app-shaped; `Geo::Distance` does the maths |
| 38 | `Units::Rates` | `Manager/Part05.pm:667`, `Part32.pm:611`, `Part33.pm:125` | unit registry + live currency conversion, as used by `5jpy` in the calculator | M | DROP — `Physics::Unit` 0.60 (2024) covers units and dimensions, including Money |

**Travel** is mostly a browser app: `travel.js`, `mapengine.js`, `mapmarkers.js`,
`continentprinter.js`. The server side is georeferencing, coverage maths, track speed and nearby
media. Two of those are genuinely portable:

- `Geometry::Coverage` is a clean algorithm: rasterise the viewport, mark cells covered, find the
  largest all-zero rectangle with the histogram sweep, then grow it one empty row or column at a
  time (`travel_pocket_line`). It is pure integer/float maths with no database and no lat/lon
  policy — the geographic part is a thin wrapper.
- `Geo::Georef` turns `(home plate pixel, scale bar pixels, legend metres, image size)` into NW/SE
  bounds. Useful to anyone who has ever screenshotted a map; niche, but small and testable.
- The map tile picker (`{z}/{x}/{y}`, ArcGIS's `{z}/{y}/{x}`) is a possible `Geo::Tile::URL`, but it
  is a string template with a switch, not a library.

**Soft keyboard** — no CPAN module, and that is the right answer. It is a self-contained browser
component: layouts, a calculator, unit conversion, a vault sheet and an IME bridge
(`soft_keyboard.js` + `soft_keyboard/`), served to the Android input method as the same page
(`templates/ime.html.ep`, `window.JawnIme`). If it is ever published, it is an npm/GitHub package,
not a Perl dist. Its only server-side piece is the conversion registry, and `Physics::Unit` already
owns that ground. The Android side (`/manager/keyboard/ime`) is a WebView over the manager's own
page — deliberately not a second implementation.

### Fourth pass: folders

| # | Candidate | Source | Gap | Effort | Verdict |
|---|---|---|---|---|---|
| 39 | `Path::Reference` | `Domain/Folders.pm:114-285` (`file_reference_*`) | index every path inside arbitrary nested JSON/Hash/Array blobs, then rewrite them on a move (including a folder-prefix handover), writing back only changed rows | M | RESERVE 3 |
| 40 | `Files::Sealed::Tree` | `Domain/Folders.pm:285-455, 471-569, 641-782` | resumable seal/open/reseal of a directory tree with progress, cancel, per-file standard tracking and reference updates | L | BENCH |
| 41 | `File::Copy::Verified` | `Domain/Folders.pm:285-396` (`folders_copy_job`) | resume a copy from bytes already there, byte-level progress, size+SHA match before the original is removed | M | BENCH |

Folders is not small — 22 routes, 2,123 lines of Perl (`Domain/Folders.pm` 796 plus two controller
parts) and 1,868 lines of JS — but three of its primitives are portable. `file_reference_index`
walks a decoded blob and records every `f`/`thumb`/bare path with the exact spot to write back;
`file_reference_apply` then handles folder prefixes and only updates rows that changed. That is a
real library in search of a home. The seal/open jobs are the house key and `openssl` welded to a
DB job object, which is why they are bench and not pick.

## The eleven

### 1. `Mojo::Tunnel`
- **Scope.** `hub` and `peer` roles, JSON control frames, binary channel frames (`N` + payload),
  15s heartbeat, redial, graceful close drain, per-channel flow control, the port-held probe.
- **Moves.** All of `perl/tunnel.pl`, plus `bin/tunnel` (the CLI block at `:365-412`).
- **Stays.** The handshake signer callback, the device lookup that names peers, the Manager route.
- **API.** `Mojo::Tunnel->hub($ws, listen => {...}, on_listen => sub {...})`;
  `Mojo::Tunnel->peer($url, sign => sub {...}, on_ready => sub {...})`.
- **Tests.** Hub+peer on `127.0.0.1`: 1 MB in both directions, close-of-large-body (the truncation
  bug), duplicate channel open, half-open watchdog with a fake clock, redial.
- **Watch out.** No behavioural test exists today (`t/49` only). `insecure`, the alive-file path and
  the debug file become options.

### 2. `WebAuthn::Verify`
- **Scope.** base64url, the minimal CBOR subset, COSE P-256/Ed25519 keys, `clientDataJSON`,
  registration and assertion verification, RP-ID/origin binding, signCount clone signal.
- **Moves.** `b64u_*`, `random_bytes`, `cbor_decode`/`_cbor_item`/`_cbor_indef`, `cose_public_key`,
  `cose_verify`, `_client_data`, `verify_registration`, `verify_assertion`, `origin_ok`.
- **Stays.** challenge storage, credential storage, `rp_id`/`origin` discovery, `user_handle`,
  enrolment routes.
- **API.** `verify_registration({ client_data, attestation, challenge, rp_id, origin })` →
  `(1, $credential)` / `(0, $reason)`; `verify_assertion({ credential, ... })` → `(1, %result)`.
- **Tests.** Known-answer vectors for both algorithms; wrong challenge, origin, RP ID; counter
  rollback; truncated authData. **Pin the ES256 signature encoding**: the current path hands a raw
  `r||s` WebAuthn signature to `Crypt::PK::ECC->verify_message` via `subs::ecdsa_verify`
  (`Domain/People.pm:189`), and CryptX documents DER. Decide raw→DER in the module and test it.
- **Differentiation.** `Authen::WebAuthn` is the incumbent (0.005, 2024, attestation chains,
  CBOR::XS + Mouse + X509 + Net::SSLeay). This one: no attestation, storage injected, Ed25519
  included, only CryptX + Digest::SHA + MIME::Base64.

### 3. `Crypt::Sealed`
- **Scope.** Throwaway X25519 pair, shared secret, HKDF context over **both** public halves,
  AES-256-GCM; optional argon2id password wrapping.
- **Moves.** `house_key_wrap`/`house_key_unwrap`, the Ed25519↔X25519 conversions, the argon2id
  helpers from `Domain/Tunnel.pm`.
- **Stays.** Where the house key lives, key rotation and the rotation record.
- **API.** `Crypt::Sealed::seal($secret, $recipient_pub, %opts)` → blob;
  `open($blob, $recipient_priv)` → secret or croak.
- **Tests.** Round trip, wrong recipient, tampered tag/ciphertext, swapped public half changes the
  key, argon2id vectors, interop with `openssl pkeyutl`.

### 4. `LoRaWAN::Uplink`
- **Scope.** Network-server webhook normalisation (TTN `uplink_message` and ChirpStack shapes),
  `frm_payload` base64 handling (JSON payload → fields, raw bytes → text), credential/document
  validation (band list, sub-band, EUI-64, 128-bit key, fport, confirmed), and a canonical
  config document for a device.
- **Moves.** `lorawan_webhook_text`, the validation half of `lorawan_settings`/
  `lorawan_public_settings`, the config-document shape from `lorawan_push_config`.
- **Stays.** HTTP fan-out to decks (`lorawan_deck_call`), the session-derived secret, settings
  storage.
- **API.** `decode_uplink($json)` → `{ text, bytes, dev_eui, fport, rssi, snr, received_at }`;
  `validate_credentials(%c)`; `config_document(%c)`.
- **Tests.** TTN and ChirpStack fixtures, JSON-in-base64, raw binary, bad EUI/key/band, missing
  payload, non-text payloads. Pure functions, no radio.

### 5. `Device::Fleet`
- **Scope.** The watch/T-Deck/Pico contract in one dist:
  - capability registry (the watch's `screen,touch,button,crown,mic,speaker,imu,steps,vibe,ble,wifi,lora`);
  - presence window and homebase ownership (one machine may serve a BLE-only device);
  - board documents: `now_me`, `board_config`, `room`, `toggles`, `toggle`, `state`;
  - relay envelope `{type:relay,to,from,id,hops,message}` with dedupe and hop budget;
  - the Pico job derivation contract (`led`, `https` with `response` = `time|switch|button|pot|measure`).
- **Moves.** `ble_relay_route` policy from `Domain/Network.pm:600-680`, document shapes from
  `Manager/Part35.pm` and `Domain/Ble.pm:558`, registry rules from `device_lister`/`embedded_device`.
- **Stays.** SQLite `devices`/`chip_ids`, the BLE sender, HTTP routes, settings, the app's UI.
- **API.** `Device::Fleet->new(store => $obj, transport => $obj)`; `register`, `may_serve`,
  `relay($envelope)`, `config_document`, `derive_jobs($config)`. Transport is a callback, so BLE,
  WiFi and LoRaWAN all fit.
- **Tests.** Hop budget (7 refused), duplicate id, addressed-back-to-sender loop, ownership denial,
  document round-trip, Pico job fixtures. No radio: a fake transport records calls.

### 6. `AI::Transport`
- **Scope.** Neutral `{ role, parts => [text|image|tool] }` message model; encode for OpenAI,
  Anthropic and Google; decode text/reasoning/tool parts and usage; SSE frame feed that survives
  chunk boundaries.
- **Moves.** `ai_content_openai`, `ai_content_anthropic`, `ai_parts_google`, `ai_wire_message`,
  `ai_response_reasoning`, `ai_response_text`, `ai_response_parts`, `ai_usage_tokens`,
  `ai_stream_frame`, `ai_stream_feed`, `ai_chat_raw`.
- **Stays.** Model catalogue, rate-limit/stand-down policy, fallback choice, database accounting.
- **API.** `encode($provider, \@messages, %opts)`, `decode($provider, $body)`,
  `feed($provider, $buffer)` → list of deltas/done.
- **Tests.** Golden request JSON per provider, stream split at every byte boundary, reasoning
  blocks, tool calls, usage.

### 7. `HTML::Allowlist`
- **Scope.** The article allowlist: tags, per-tag attributes, global `class`/`style`, CSS property
  allowlist, URL scheme policy (`/`, `./`, `#`, `http(s)`, safe `data:`, `mailto`, `tel`),
  drop-content elements, balanced end-tag repair.
- **Moves.** `Domain/Article.pm` (all three subs and the tables).
- **Stays.** The magazine store and the homepage render.
- **API.** `clean($html)`, `style($css)`, `url_ok($url)`; the tables exported read-only.
- **Tests.** The existing two test files move in, plus an XSS corpus (script, on*, `javascript:`,
  `url()`, `expression`, nested drop elements, unclosed tags).

### 8. `Device::Bridge`
- **Scope.** Token-auth, request-id, one-JSON-line-each-way RPC over a loopback socket; 5s
  memoized cooldown; **soft failure** (`undef`) so the caller can fall back; reconnect.
- **Moves.** `device_bridge_token_file`, `device_bridge_port`, `device_bridge_connect`,
  `device_call` (`Domain/Say.pm:600-690`).
- **Stays.** The Termux command fallback, app package/action/component identity, typed helpers.
- **API.** `Device::Bridge->new(token_file => ..., port => ...)`, `call($method, \%args, $wait)`.
- **Tests.** Fake server, missing token, refusal (`ok:0`), malformed line, timeout, cooldown window,
  reconnect after close.

### 9. `Lock::SingleFlight`
- **Scope.** The marker state machine: `flag:pid`, live-pid 30m, unverifiable claim 2m, dead 10m,
  claim adoption, reapability. Storage is a get/set callback.
- **Moves.** `remote_upgrade_marker_state`, `remote_upgrade_lock_state`,
  `remote_upgrade_marker_reapable` (`Domain/Sync.pm:400-430`).
- **Stays.** The sync job table and UI, the pull itself.
- **API.** `Lock::SingleFlight->new(store => $s, alive => sub {...})`; `state`, `claim`, `adopt`,
  `release`, `reapable`.
- **Tests.** Every flag/pid/age combination, clock edges at each bound, adoption race (two
  claimants, last writer wins), a dead pid becoming reapable.

### 10. `App::TestsFor`
- **Scope.** Read `# tests-for:` claims from test headers, map staged/working/range paths to the
  tests that claim them, **fail safe to the whole suite** when nothing claims a path, run the
  selection in parallel with a fork engine.
- **Moves.** `scripts/tests_for.pl` and `scripts/run_tests_fork.pl`.
- **Stays.** JawnOS's `t/` conventions and the `subroutines.pl` boot.
- **API.** `App::TestsFor->new(root =>, test_dir =>)`; `tests_for(\@paths)`, `run`, and the CLI.
- **Tests.** Header parsing (globs, dirs, multiple claims), no-claim → all, staged vs working vs
  range, JSON output.

### 11. `Log::Ring`
- **Scope.** Bounded byte ring with a monotone sequence; append; `since($seq)` with drop accounting;
  a Unix-socket server that answers a JSON header plus raw bytes.
- **Moves.** `lib/JawnOS/LogBus.pm`.
- **Stays.** Error-watch offsets, the consumer in `Ai3.pm`.
- **API.** `Log::Ring->new(max => $bytes)`, `append($bytes)`, `since($seq)`, `serve($path)`.
- **Tests.** Wrap and `dropped` count, cursor reset, ANSI/UTF-8 bytes intact, concurrent readers.

## LoRa: what a Perl module can and cannot do

The honest split is three layers, and only the first is a CPAN dist.

1. **`LoRaWAN::Uplink` — CPAN, host side.** Validates credentials and the region plan, normalises
   network-server uplinks, and emits the board's config document. Pure Perl and pure functions:
   testable with fixtures, no radio.
2. **`JawnLoRa` — a firmware library, not CPAN.** An Arduino/PlatformIO library over RadioLib with a
   deliberately tiny API: `begin($plan)`, `join()`, `send($bytes)`, `onDownlink(\&cb)`, `sleep()`.
   It owns duty-cycle pacing, the channel plan, retries and the uplink queue. Distributed through
   the PlatformIO registry and GitHub, BSD-2-Clause like the rest.
3. **The shared document.** Both sides read the same `lorawan_config` JSON
   (`{ region, subband, join_eui, dev_eui, app_key, fport, confirmed }`), which is what the manager
   already pushes to a deck's `/lorawan_config`.

**Can the module select the frequencies?** Yes, at the plan level: `LoRaWAN::Uplink::plan(region =>
'US915', subband => 2)` returns the sub-band, channel list, data-rate range and duty-cycle limit. It
must not transmit, and it must not pretend to know the radio's state. Frequency hopping, dwell time
and the join procedure stay next to the radio, where RadioLib already implements them.

**Can it operate the ESP32 in-process?** No — a CPAN module is Perl on the host. What it *can* do is
generate the plan, validate it, flash/configure the board over USB or OTA (`bin/lora`), and decode
what the board sends back. The MCU work lives in the firmware library, which is the only way to keep
RF rules testable on real hardware.

**Raw LoRa (the watch's broadcast chat)** gets the same treatment with a smaller plan:
`plan(mode => 'raw', region => 'US915', channel => 0)` → frequency, bandwidth, spreading factor,
SX126x sync word and TX power. That is enough to make two watches talk without a network server.

So: yes to frequency selection and a modular firmware library, no to “the CPAN module runs on the
ESP32”. Keeping that line clear is what makes both halves good.

## Bench (do not start yet)

Ordered by how likely they are to be promoted:

1. `Mesh::Relay` — split from `Device::Fleet` if the relay surface stays transport-free.
2. `Firmware::OTA::Stage` — small, hardware-adjacent, useful to anyone shipping PlatformIO.
3. `Job::Progress` — pairs naturally with `Lock::SingleFlight`.
4. `Termux::API::Typed` — coordinate with the `Termux::API` author before publishing.
5. `App::APK::Release` — real tooling gap, but only if the store is meant to serve others.
6. `Input::Inject` — genuine gap; the cost is testing four display servers.
7. `AI::Agent::Loop`, `Job::Placement`, `AI::Eval` — valuable, but larger and closer to JawnOS's
   own semantics.
8. `Net::Bluetooth::NUS`, `Device::Battery::Curve`, `HTTP::Sig::Peer`, `Crest::Record`,
   `Payment::Proof`, `I18n::Llm`, `Net::Discovery`, `Tombstone::Log`.

## Phases

| Phase | Work | Exit criterion |
|---|---|---|
| 0 | Dist skeleton (`Makefile.PL`, `cpanfile`, `Changes`, `README`, `t/`, CI), PAUSE identity, publish one pilot | `cpanm .` installs, `prove -l t` passes, JawnOS uses it |
| 1 | `Mojo::Tunnel`, `Log::Ring`, `Device::Bridge`, `HTML::Allowlist`, `App::TestsFor` | The five are consumed here; `t/99` shrinks by five |
| 2 | `Crypt::Sealed`, `WebAuthn::Verify` | First real WebAuthn vectors; ES256 encoding pinned |
| 3 | `Device::Fleet`, `LoRaWAN::Uplink` | Watch/T-Deck/Pico integration passes against a fake transport |
| 4 | `AI::Transport`, `Lock::SingleFlight` | Golden provider JSON + marker state-machine tests |
| 5 | `JawnLoRa` firmware library (PlatformIO), alongside `LoRaWAN::Uplink` | T-Deck, T-Watch and Pico join, send and sleep on a plan generated by the Perl module |

The reserves start when any pick slips: `Business::POS::Register` first, then `Geometry::Coverage`.
POS should be the second pilot if Phase 0 goes smoothly — it is the cheapest possible proof that
the zero-friction contract is real.

Phase 0 pilot should be `HTML::Allowlist`: smallest seam, zero coupling, already tested.

## Per-module checklist

- [ ] the seam is a callback/argument, not a global or a settings table
- [ ] no `require './…'`, no cwd-relative path, no `$HOME` assumption
- [ ] no insecure default; TLS verification is opt-out only
- [ ] tests pass with no hardware and no network (`127.0.0.1` allowed)
- [ ] three-line SYNOPSIS actually runs (copied into `eg/` and exercised by a test)
- [ ] install has no mandatory compiler step beyond CryptX/HTML::Parser; optional deps are lazy
- [ ] POD: NAME, SYNOPSIS, ten-line Quick start, DESCRIPTION, METHODS, DIAGNOSTICS, LICENSE
- [ ] `Changes` starts at 0.001; `MIN_PERL_VERSION` declared
- [ ] JawnOS's map/route/help indexes updated in the same commit
- [ ] `where.pl` no longer reports the old location
- [ ] version bumped, committed, pushed, tree restarted

## Open questions

1. **Namespace.** Generic names for generic modules, `JawnOS::*` only for crest/vouch? Or one
   `JawnOS` namespace with a note that the modules are usable alone?
2. **Repo layout.** Separate repos per dist, or `dists/<name>/` in this tree with its own
   `Makefile.PL`? Separate repos make PAUSE and CI simpler; in-tree keeps one history.
3. **Minimum Perl.** `5.40` is on this box; the modules should probably target a lower floor
   (5.20–5.26) unless signatures are dropped.
4. **CI.** GitHub Actions matrix for the dists, or rely on this box's pre-push suite?
5. **Ownership.** One PAUSE account for all eleven, or a `JAWNOS` shared namespace later.
