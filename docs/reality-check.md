# Reality check: the plan that delivers the three outcomes

Status: decision, 2026-11-03. **This is the build plan.** The other documents are the north star and
the reference; none of them is a queue.

The three outcomes:

1. **Publish parts to CPAN** — small, standalone, install-in-seconds modules that JawnOS uses.
2. **Write apps with AI and share them** — a small app format, a one-command install, a tarball you
   can hand to another house.
3. **It actually helps** — the apps replace real work, the house keeps running, and Music keeps
   playing.

Everything below is judged by those three, not by the elegance of the platform.

## What we designed, and what it is for

| Initiative | What it buys | Needed now? | Verdict |
|---|---|---|---|
| 11 CPAN modules | reusable libraries | 4 of them | **Track A** |
| App SDK (`Host`, manifest) | apps that do not touch `subs::` | yes, minimal | **Track B** |
| App lifecycle (install/enable/uninstall) | shareable, removable apps | yes, minimal | **Track B** |
| Per-app databases + broker | isolation and encrypted data | no | defer |
| DB encryption | secrets at rest | no | defer |
| Router (streams, peers, video) | app↔app, media | no | defer |
| Sandbox | containment for untrusted apps | no | defer (local trust) |
| Decentralized store | sharing at scale | no | defer (tarball) |
| Music port | proves the contract | no | later; Music is the invariant |
| v1 transition | removing the legacy path | no | after the first apps |
| The design docs | direction and constraints | reference only | keep |

The rule that keeps this honest: **do not build the platform for the second app until the first app
works.**

## The minimum that delivers outcome 2

An app is a directory:

```
apps/reading/
  manifest.json        name, version, host_api, tables, settings, permissions
  lib/App.pm           package JawnOS::App::Reading; use JawnOS::App -base;
  templates/           .ep pages the app owns
  public/              its JS/CSS
  migrations/          001.sql, 002.sql
  t/                   its tests (JawnOS::SDK::Test)
```

Installed by copying it under `apps/`, then:

```
perl scripts/app_check.pl reading          # manifest + forbidden calls + tests
perl scripts/app_install.pl apps/reading   # validate, copy, migrate, register
perl scripts/app_enable.pl reading         # mount routes, show in the app list
perl scripts/app_uninstall.pl reading --keep-data|--purge
```

What the first version deliberately does **not** have:

- no per-app database: the app gets tables in the core DB with `server_time`, so the existing sync
  and backup pick them up for free;
- no router, no sockets, no streams: `Host::Local` is an in-process delegation, as designed;
- no sandbox: local trust only — you or your agent wrote it; do not install someone else's app yet;
- no store: sharing is a `.tar.gz`;
- no change to the three JS bundle maps: the app serves its own assets under `/app-assets/<name>/`;
- no help/i18n requirement to start; the manifest has a title and an icon, the app list shows it.

The host surface for the MVP is small: `db`, `settings`, `clock`, `ids`, `i18n`, `files` (optional).
That is enough for a real app and small enough to keep stable.

## The proof app

Pick a small, real thing you will actually use for a week. Suggested: a **Reading list** (title,
author, status, rating, notes) or a **Pantry** (item, quantity, location, expiry). It must:

- have one list page and one edit form;
- store rows in its own table with `server_time`;
- survive a restart, a backup/restore and a sync to a second machine;
- uninstall cleanly (rows and table removed on `--purge`);
- never touch Music.

The second app is written by the AI from a prompt, using the template, to prove the loop. If the
second app needs a new host service, that is the signal to extend the host — not to build the router.

## Track A — CPAN (parallel, independent)

Four modules first, in this order. They do not depend on the SDK and cannot break the house.

| Order | Module | Source | Why this one | Acceptance |
|---|---|---|---|---|
| 1 | `HTML::Allowlist` | `Domain/Article.pm` | 180 lines, no coupling, already tested, a real gap (CSS allowlist) | `cpanm`, 3-line synopsis, XSS corpus, JawnOS uses it |
| 2 | `Log::Ring` | `lib/JawnOS/LogBus.pm` | 196 lines, no coupling, one test | install, append/since/drop tests, JawnOS uses it |
| 3 | `Mojo::Tunnel` | `perl/tunnel.pl` | 412 lines, no coupling, real gap | loopback hub/peer test, close-drain, JawnOS uses it |
| 4 | `App::TestsFor` | `scripts/tests_for.pl` + `run_tests_fork.pl` | no CPAN equivalent, useful to anyone | header parsing, fail-safe-to-all, CLI |

Later, not now: `WebAuthn::Verify`, `Crypt::Sealed`, `Business::POS::Register`,
`Geometry::Coverage`, `Device::Fleet`, `LoRaWAN::Uplink`, `AI::Transport`, `Device::Bridge`,
`Lock::SingleFlight`. They are good; they are not the first four.

CPAN rules: a working three-line SYNOPSIS, no JawnOS dependency, no required compiler step beyond
CryptX/HTML::Parser, an `eg/` demo, tests that run offline, and a `Changes` starting at 0.001.

## Track C — keep the house alive

- Music is the invariant (`docs/v1-strategy.md`): after every change, the checklist on the real app.
- The suite runs before a push (or `--no-verify` for docs only).
- No router, sandbox, store, per-app DB or Music port in this phase.

## The 90-day order

| Weeks | Track A | Track B | Track C |
|---|---|---|---|
| 1–2 | `HTML::Allowlist`; `Log::Ring` | app template, `app_check`, `app_install`, a "hello" app | baseline Music checklist |
| 3–5 | publish the two; start `Mojo::Tunnel` | the proof app; sync/backup/restart/uninstall verified | suite green; no regression |
| 6–8 | `Mojo::Tunnel` done; start `App::TestsFor` | AI writes the second app from a prompt; fix the template | Music still green |
| 9–10 | `App::TestsFor` done | share the tarball; install on a second house; docs | suite green |
| 11–13 | (next module only if the first four are stable) | harden: migrations, app list, uninstall, minimal help | Music green |

`JawnOS::Router` R0 and the per-app database work wait until **two apps** have been written, used for
a week, shared and uninstalled. If that has not happened, the platform is not the bottleneck.

## Triggers for the deferred layers

| Deferred | Build it when |
|---|---|
| Per-app DBs + `ATTACH` | an app's data outgrows one table or must be isolated from another app's reads |
| DB broker + encryption | an app handles secrets that the house key should not expose to it |
| Sandbox | you install an app you did not write or review |
| Router R0 | two apps need to call each other, or a stream is needed |
| Router streams | Music's remote audio/video needs a second consumer |
| Store | a tarball is no longer enough to share |
| Music port | `Host::Local` is stable and the Music suite exists |
| v1 completion | the legacy path is the only thing left to remove |

## How we know it worked

**CPAN:** four modules published; JawnOS uses at least two; a stranger can install one with one
`cpanm` and wire it from the SYNOPSIS in under a minute.

**Apps:** two AI-written apps installed; one used daily for a week; both shared as tarballs and
installed on a second house; data syncs, backup/restore includes them, uninstall leaves no rows,
tables or files; Music has not regressed.

**Helps:** the proof app replaces a real manual step; the house still restarts cleanly; the suite is
green; Music passes its checklist.

## Risks in this smaller plan

1. **Local-trust code.** AI-written apps run in-process. Only install apps you generated or read;
   the sandbox is the trigger for anything else.
2. **App tables in the core DB.** They sync and back up for free because they carry `server_time`,
   but they are readable by every app. Accept that for local apps; isolate with per-app DBs when it
   matters.
3. **DDL at install.** Migrations run at install, not per request. A failed migration must leave the
   app disabled, not half-installed.
4. **Uninstall.** `--purge` must drop the table and rows; a bug here is data loss. Test it on a copy.
5. **API drift.** Every host call an app uses is a promise. Keep the MVP surface small and version it.
6. **Docs vs. build.** The design docs are seductive. This plan is the queue; if a design does not
   serve the three outcomes, it waits.
7. **CPAN scope.** Publish libraries, not the framework. The app SDK goes to CPAN only after the
   first two apps and a 1.0 API.

The measure is not how good the architecture is. It is whether a stranger can `cpanm` a module, an
app written by the agent can be installed and used, and Music still plays.
