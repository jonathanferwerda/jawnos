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
   The bench exists so the cap can be enforced without losing the ideas.

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

## The 30 candidates

Gap = what CPAN lacks today (checked on MetaCPAN 2026-11-02). Effort: S ≈ 1–3 days, M ≈ 1–2 weeks,
L ≈ 2–4 weeks including tests. PICK = the eleven; BENCH = keep, do not start; DROP = no.

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
1.27, June 2026, is active), `Business::Change` (`Domain/Store.pm` — too small), `Server::Control`
shim (`perl/control.pl` — an older module exists and this one is verdict-shaped), `Where`
(`scripts/where.pl`) and `Agent::Help` (`scripts/agent_help.pl`) — both read JawnOS's own maps and
have no meaning elsewhere.

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

Phase 0 pilot should be `HTML::Allowlist`: smallest seam, zero coupling, already tested.

## Per-module checklist

- [ ] the seam is a callback/argument, not a global or a settings table
- [ ] no `require './…'`, no cwd-relative path, no `$HOME` assumption
- [ ] no insecure default; TLS verification is opt-out only
- [ ] tests pass with no hardware and no network (`127.0.0.1` allowed)
- [ ] POD: NAME, SYNOPSIS, DESCRIPTION, METHODS, DIAGNOSTICS, LICENSE
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
