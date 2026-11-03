# v1 strategy: new architecture, old data, one app at a time

Status: decision, 2026-11-03. **Phased, in-place transition to v1. No fork.** Supersedes the
"fork when the SDK is ready" framing with a concrete build order.

## The question

Should this be treated as a brand-new project — a total rewrite that picks parts out of JawnOS as it
goes — or as the in-place evolution already described in `docs/app-sdk.md`?

## Short answer

**Yes to a new project as an architecture. No to a big-bang rewrite.**

Build the new core greenfield — `JawnOS::Host`, `JawnOS::App`, `JawnOS::Server`, the DB/broker,
sandbox and store — with none of v0's globals or conventions. Keep the current tree as the
**behaviour oracle and data owner**, and move one app at a time onto the new core. Fork the
repository only when parity is proven, not on day one.

That gets the writing benefits of a rewrite without betting the house on a multi-year big bang. It
ships on the **same trunk** — there is no `v1` branch and no `release/v1` — with the legacy path
behind a flag until the new one passes the Music invariant.

## The Music invariant (the credit card)

Music is not a pilot that may fail; it is the acceptance test for every phase. If the player does not
work, the phase is reverted. Concretely:

- the player keeps serving from the v0 path until the v1 path passes the checklist **on the real
  WebKitGTK app**, not on a headless browser;
- `perl/Music/*` is adapted to the host API behind a per-request switch, so a regression flips back
  to the legacy path without a deploy or a restart;
- every phase ships with Music green; a red Music is a stop, not a bug to schedule;
- Music is the **last app cut over**, even though it is the first to be adapted.

The checklist, run at every gate on a real device and the real engine:

1. the library lists, plays, pauses, seeks, and the queue moves next/previous;
2. a remote output (L / name / R) works over PCM and Opus and stays in sync;
3. video shows picture and subtitles, including the remote screen;
4. a sealed track and a private album open only under the padlock;
5. an archived track fetches home and plays;
6. screen-off playback on the phone continues to the next track;
7. the appointment write path is unaffected (the house's shared invariant).

A failure here is a rollback of the phase, not a note in a backlog.

## What a rewrite actually has to re-earn

| Thing | Size / shape |
|---|---|
| Perl + `lib/` | 137,358 lines across 325 files |
| JavaScript | 99,804 lines |
| Templates | 23,731 lines |
| Scripts | 15,505 lines |
| Tests | 23,632 lines across 165 files |
| Database | 44 tables, `app`-scoped rows, sync log/tombstones, encrypted settings |
| Verified tree | 1,048 files through `verify_change` |

The hard part is not syntax. It is the invisible behaviour encoded in comments and tests: the
tunnel's close-drain that stopped truncated backups, the three-TTL upgrade marker that hid six
appointments, the LittleFS split that kept an OTA from dropping a Pico off the network, the session
cookie that made a valid peer signature answer 403. A rewrite rediscovers each one as an incident
unless the old tree is the oracle.

"Simpler" splits cleanly:

- **Simpler to write**: yes. No `subs::` globals, no `require './perl/…'`, no `AUTOLOAD` map, a real
  API, per-app databases, tests from day one.
- **Simpler to ship**: no. The data, the key hierarchy, the sync protocol and the UI are the work; a
  big-bang rewrite also puts them all at risk at once.

## Three options

| | In-place SDK | Big-bang rewrite | **Greenfield core + strangler** |
|---|---|---|---|
| Design purity | medium | highest | high |
| Risk to the live house | low | highest | low |
| Time to first useful result | medium | long | short |
| Re-earns edge cases | no | yes | no (reuses v0) |
| UI rewrite | no | very tempting | deferred until an app moves |
| Data migration | incremental | all at once | incremental |
| Final architecture | the intended one | clean | the intended one |

## Music first: the impact

Starting with Music is defensible — if the contract carries Music, it carries everything — but it
changes four things.

**The pilot becomes the largest app.** Music is 2,882 lines of Perl in nine files, 6,076 lines of
player JS, ~690 lines of templates and 16 routes. Gallery is 331 lines of controller, 4 routes and no
app JS chunk. G1 moves from weeks to months.

**The API grows before it stabilises.** Music reaches for `rightNow`, settings, db, cache, `home`,
`signatorial_designer`, peer sign/verify, `remote_relay_request`, `window_maker`, `media_unlock_open`,
`rock_and_roll` and `private_revealed`. Running it needs `media`, `peers`, `events`, `padlock`,
`archive` and `windows` in the host on day one — a superset of the other apps, with a real risk of
overfitting the contract to media.

**It cannot be the sandbox pilot.** Music needs network (WebSocket), the peer mesh, audio devices and
media files. The first sandbox must stay no-network and file-scoped; Gallery or Embedded proves that
fence. Music is the second sandbox target, with an explicit WS/media proxy.

**Its conformance corpus is thin.** Six test files reference Music today; it is the app where parity
is hardest to prove. Porting it means writing the Music suite and the port together.

**What it buys.** The hard host services (media, peers, events, padlock, archive) are designed under
real pressure, not guessed. If Music runs on the SDK, the rest is mostly UI and CRUD.

### The shape that works

Music first **as a vertical slice, not as the parity gate**:

1. Convert `perl/Music/*` to `Host::Local` — routes, library/queue, remote audio/video, padlock.
2. Keep `public/js/music.js` as an asset. Change endpoints and the host contract, not the player.
3. Add `media`, `peers`, `events`, `padlock`, `archive`, `windows` to the host as capabilities with
   local implementations.
4. Keep **Gallery** as the contract pilot: small, server-rendered, full corpus. If the API carries
   Music and Gallery without contortion, it is stable.
5. Write the Music conformance suite (playback, queue, remote output, padlock, archive) before the
   port; it is the parity proof, not an afterthought.
6. Sandbox Music after Gallery/Embedded: `userns` with a WebSocket and media proxy, or `systemd` on
   the installed OS.

## The compatibility surface (one-way doors)

These are decided once and versioned; changing any of them is a data migration, not a refactor:

- the database schema and the `app`-scoped rows (`docs/app-databases.md`);
- the key hierarchy and recovery (`K_house` → `K_app`, paper code/Shamir);
- the sync protocol, watermarks and tombstones (`sync_version`);
- the signatorial / peer identity and the house crest;
- the file-tree conventions and the URLs the UI and peers already call;
- the help registry and the translation catalog.

**No schema fork before `sync_version = 4`** and the multi-DB backup bundle. A v1 that reads the same
data is a rewrite; a v1 that reads a different data is a migration project with a house on it.

## Rules

1. **Rewrite the architecture, not the behaviour.** v0 is the spec; its tests and comments are the
   documentation.
2. **New code never calls `subs::` or `Manager::`.** If it needs a host power, the power moves into
   `JawnOS::Host`, with a `Host::Local` delegation for the old tree.
3. **No UI rewrite before the app moves.** Templates and JS ship as the app's assets; a later visual
   rewrite is a separate project.
4. **Nothing is deleted until its replacement passes the conformance corpus and a canary.**
5. **v0 stays runnable.** v1 serves copies of the house data, side by side, until cutover.
6. **Music is the first vertical slice; Gallery is the contract pilot.** Convert Music's server side
   onto `Host::Local` first and keep the player as an asset; then Embedded and Travel. The player's
   UI rewrite stays last, or never.
7. **Every new module ships with tests** (`JawnOS::SDK::Test`, `App::TestsFor`), and the low-risk CPAN
   modules (`HTML::Allowlist`, `Log::Ring`, `Mojo::Tunnel`, `App::TestsFor`) ship as they are.

## The conformance corpus

The safety net for a rewrite is not more code; it is a corpus both implementations must satisfy:

- anonymized fixtures from the live database: appointments across several apps, sync log and
  tombstones, encrypted settings, a Gallery with photos, a Travel map, an Embedded board;
- golden HTTP/HTML cases for the routes each app owns;
- sync traces (push/pull, conflict, tombstone purge) and crypto vectors (seal/open, key wrap);
- the permission/visibility matrix (Off/Private/Public/Dangerous, friend/stranger/enemy);
- the existing `t/` suite as the behaviour spec, mapped by `tests_for`.

Run v0 and v1 against the corpus; a diff is a blocker, not a discussion.

## Project shape

The "new project" is a set of packages, not necessarily a new repository on day one:

```
jawnos-core/        JawnOS::Host, ::App, ::Server, ::DB, ::Sandbox, ::Store, ::Backup
jawnos-app-*/       one dist per app (Gallery first)
jawnos-modules/     the eleven CPAN dists
jawnos/             v0, the live house (maintained, not extended)
```

A single repo with `core/`, `apps/`, `dists/` is also fine. Choose by CI/PAUSE needs, not by taste;
the important boundary is that new code has no path back into `subs::`.

## What to start now

1. `JawnOS::Host` + `Host::Local` as a thin delegation; convert **Music's server side**
   (`perl/Music/*`) to it first, with `public/js/music.js` untouched as an asset. The v0 path keeps
   serving; the new path runs beside it behind a switch.
2. Convert **Gallery's** controller as the contract pilot. `Host::Solo` + `JawnOS::Server`; run
   Gallery standalone against a **copy** of the database.
3. Build the conformance corpus in parallel — the Music suite is the first part of it.
4. Ship the low-risk modules; keep the 11-module roadmap independent.
5. Do **not** start with the player UI, a new database format, or Music in the sandbox.

## Decision gates

| Gate | Condition |
|---|---|
| G1 | Host API stable; Music's vertical slice runs on `Host::Local`; Gallery runs embedded and standalone; corpus green |
| G2 | Music parity (playback, queue, remote output, padlock, archive); Embedded and Travel on the SDK; per-app DBs at Phase 2; sandbox at SB1 |
| G3 | `sync_version = 4`, multi-DB backup bundle, lifecycle at L3, store at S2 |
| G4 | v1 parity on the corpus and the Music checklist; the legacy path removed after one clean release |

There is no fork. v1 is the same trunk and the same data: features land behind `JawnOS::Host` and a
config flag, the legacy path stays until the new one passes the Music invariant, and completion is a
release (`1.0`) that deletes the legacy path — not a branch. Autonomous work happens on the same
trunk behind flags, with the corpus and the error watch as the night shift.

## Risks

1. **Re-earning edge cases.** The old comments are a bug history; a rewrite that ignores them pays
   for each one again. The corpus and the old suite are the mitigation.
2. **Data divergence.** Two formats, one house. No schema change before sync v4; dual-run reads.
3. **UI rewrite temptation.** The UI is 124k lines (JS + templates); rewriting it alongside the core
   multiplies risk. Keep it as an asset until the app moves.
4. **Dual maintenance.** Every fix lands in v0 and v1 while both run. Budget for it; prefer fixes in
   the new core and back-port only what v0 needs.
5. **Autonomous drift.** The v1 agent can build a plausible parallel implementation. The conformance
   corpus and `App::TestsFor` are the guardrail; a green corpus is the definition of "done".
6. **CPAN vs core.** A module that is useful alone belongs on CPAN; a host power belongs in the core.
   Do not publish the core as a "framework" before its API is 1.0.

## Recommendation

Treat the work as a new project **architecturally** and as a strangler **operationally**: greenfield
core, old data, one app at a time. It is the only path that is both simpler to write and safe to
ship for a house that is already living in the software.
