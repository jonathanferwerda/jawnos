# App lifecycle, agent-built apps, and the v1 fork

Status: design, 2026-11-03. Companion to `docs/app-sdk.md` and `docs/app-databases.md`.

This is the layer that turns the SDK from a contract into a product: apps can be installed, disabled,
upgraded and removed without hand-editing the tree; the Coding agent can build one on the fly; and
the host watches each app's health and tunes it — or rolls it back.

It also records the **jawnos-v1 fork** as a roadmap item, not work to start now.

## Today

- There is **no installer**. A new app is added by the Coding agent the way a person would: a
  template, a route, a registry entry (`docs/AGENTS-agents.md`, "New apps"). That already works, but
  it edits the running tree and has no version, state or rollback.
- The registry is implicit: help topic, three JS maps, routes, templates. Nothing records what is
  installed, at what version, or whether it is healthy.
- Health exists at the **host** level: `/manager/health` and `/manager/health_report`
  (`Controller/manager_misc13.pm:539`), the process warranty/heartbeat (`Domain/Process.pm`), the
  nightly Evaluation jobs (`Domain/Evaluation.pm`) and the error watch. Nothing is per app.
- The Coding agent is already a durable runner: a Minion `coding` queue on its own SQLite file,
  resumable run state, subagents, path-checked writes, a review step, diff bundles and push
  (`Domain/Coding.pm`). It is the right engine for generated apps; it needs a lifecycle to hand its
  output to.

## The registry

One core table, `apps` (in `jawnos.db`, synced like any other):

```sql
create table apps (
  name        text primary key,
  version     text not null,
  source      text not null,          -- cpan | local | builtin | agent
  manifest    text not null,          -- canonical JSON
  state       text not null,          -- discovered|validated|installed|enabled|disabled|degraded|uninstalled
  enabled     integer not null default 0,
  trust       text not null,          -- core|reviewed|agent|untrusted
  checksum    text,                   -- tarball sha256
  installed_at text,
  updated_at  text,
  health      text,                   -- last JSON reading
  last_error  text
);
```

The registry drives four things that are hand-maintained today: route mounting, asset inclusion (the
lazy JS maps), the start menu, and the help topic. A manifest becomes the only place an app declares
itself; the three maps and the menu are generated from it at boot.

## States and commands

```
discovered → validated → installed → enabled ⇄ disabled
                              │           └→ degraded (health) → rollback/disable
                              └→ uninstalled (data kept or purged)
```

`jawnos-app` (CLI and `JawnOS::App::Manager` methods):

| Command | What it does |
|---|---|
| `install <dist\|dir\|tarball>` | validate manifest → resolve capabilities → check table/settings/permission conflicts → snapshot → create schema + run migrations → register → optional health check → enable |
| `uninstall NAME --keep-data\|--purge` | disable → stop jobs → tombstone the app's sync rows → detach → drop schema (purge only) → remove assets → deregister. A backup is taken before a purge. |
| `enable` / `disable` | no file movement; routes 404, jobs pause, sync stops advertising the app |
| `upgrade <dist>` | snapshot code + schema → migrate in a transaction → smoke test → health sample → keep or roll back |
| `list` / `info` / `doctor` | version, source, trust, dependencies, pending migrations, last health |
| `new <name> --prompt "..."` | scaffold a local app for the Coding agent (below) |

Install sources: a CPAN dist, a local directory or tarball (agent output), or a built-in shipped
with core. All three go through the same validator.

## Manifest validation

Before a single file is copied:

1. **Shape** — required keys, types, API version (`host_api`), asset paths inside the app root.
2. **Capabilities** — every `host` entry must be one the host offers; `host_optional` may be absent.
3. **Tables** — each declared table is unowned; no collision with core, another app, or a view.
   Writes are limited to the declared set (the per-app DB registry, `docs/app-databases.md`).
4. **Settings/permissions** — namespaced; a new permission must be grantable.
5. **Dependencies** — `requires_app` resolves to a provider (`provides`), with a version range and
   no cycle. Missing providers fail at install, not at first click.
6. **Assets** — no `..`, no absolute paths, template names do not shadow core.
7. **Trust** — the source decides the initial tier (below); a `core` app cannot be installed from a
   local path.

## Trust tiers for generated code

The critical risk is arbitrary code in the house. Four tiers, enforced by the host, not by convention:

| Tier | Source | Powers |
|---|---|---|
| `core` | shipped/signed | everything declared |
| `reviewed` | a human approved the diff | everything declared |
| `agent` | the Coding agent, not reviewed | own schema only; **no shell, no network, no core writes**, no secrets beyond host crypto, resource quotas, canary slot only |
| `untrusted` | third party | as `agent`, plus a required signature |

A manifest that asks for `shell` or `network` is only valid at `reviewed`/`core`. The same path checks
the Coding agent already uses for its own writes (`coding_child_norm_path`, `coding_child_write_ok`)
become the app's file sandbox. An `agent` app may be promoted to `reviewed` by an explicit command
after a human reads the diff; promotion is a registry change, not a reinstall.

## Agent-built apps on the fly

The Coding agent already writes, tests, reviews, commits and pushes. The lifecycle adds a
**generation pipeline** around it:

```
prompt → scaffold (manifest, route, template, test, migration)
       → SDK tests (JawnOS::SDK::Test, App::TestsFor)
       → manifest validation
       → install into the canary slot (trust=agent, own DB)
       → health sample (N real requests + jobs)
       → promote (reviewed) or roll back
```

- `jawnos-app new Foo --prompt "..."` writes a minimal, passing app to a temp directory. The agent
  fills it in; nothing touches the live tree until the pipeline installs it.
- The canary slot runs the app beside the enabled one (a second route prefix and a separate schema),
  so a generated change is measured against the current version, not in the dark.
- The agent's iteration loop is: failing test or health reading → patch → rerun. It is allowed to
  edit **only** the app's own files and schema. Core edits go through the normal Coding agent flow
  and a human review.
- Guardrails: token/budget cap per app, no secrets in generated source (scan), no new CPAN
  dependency without approval, automatic rollback on an SLO breach, and an audit row per generation.
- Output is a local dist. Publishing to CPAN is a separate, human decision.

## Health and performance

Every app reports a small, comparable set of facts; the host stores the last reading and a short
history in a ring (the `Log::Ring` module is the model, not necessarily the store):

- requests, errors, p50/p95 latency (from the host's request wrapper);
- job success/failure and queue depth;
- own-schema size and growth, migration version;
- sync lag (rows pending per peer) when `supports('sync')`;
- `health()` checks the app chooses to expose (a dependency reachable, a cache warm).

The host adds the cross-app view: `/manager/apps/health` (JSON) and a panel beside Configure, and each
app may be given an SLO:

```
error rate < 1%   ·   p95 < 300 ms   ·   job failures < 2%
```

`degraded` is a state, not an alert: the app keeps serving, the panel shows why, and the rollback
button is one click. The existing process warranty/heartbeat and the nightly Evaluation jobs feed the
same panel; this is a per-app projection of machinery the house already runs.

**Auto-tune, with guardrails.** The agent may propose (and, for `agent` apps, apply) changes that are
measurable and reversible: an index, a cache TTL, a batch size, a query shape, a timeout. It may not
change permissions, crypto, auth, sync policy or core tables. Every change is applied to the canary,
measured against the SLO, and promoted or reverted. A tune that cannot name its metric is a rewrite,
not a tune.

## The jawnos-v1 fork (roadmap, not now)

**Do not fork yet.** `main` stays v0 — the house — while the SDK, per-app databases and lifecycle are
built on it. The fork is a milestone with entry criteria, not a branch created in hope.

Entry criteria:

1. `JawnOS::Host` API 1.0 frozen; `Host::Local` is a thin delegation and `Host::Solo` runs an app
   alone.
2. Gallery, Embedded and Travel are on the SDK (`docs/app-sdk.md` phases A–E); Music is decided.
3. Per-app databases at Phase 2+, sync v4 and the multi-DB backup bundle (`docs/app-databases.md`).
4. The lifecycle is at L3: registry, install/uninstall/upgrade with rollback, health panel, canary.
5. A full suite and a canary house green for a week on the new server.

When it happens:

- `main` remains v0 and the running house. `v1` is developed on the new server; `release/v1` tags are
  cut from it. The autonomous agent works on `v1`, never pushes to `main`.
- v1 runs against **copies** of the house database and files, side by side with v0. Feature flags
  decide which host powers v1 uses; a machine moves to v1 one at a time.
- v0 stays runnable as the fallback for one release after cutover.
- Versioning: `VERSION` stays 0.x until the fork; v1.0 at the fork. App dists version independently.
- Autonomy rules: branch + tests + review gate before merge; token/budget caps; the error watch and
  the Evaluation jobs are the night shift; every autonomous batch must be revertible by commit.

Infrastructure (the new server, containers, off-box backups) is already tracked in
`docs/AGENTS-roadmap.md`; the fork adds the branch and release policy, not new hardware.

## Phases

| Phase | Work | Acceptance |
|---|---|---|
| L0 | `apps` registry, manifest validation, state machine; no installer yet | A built-in app appears in the registry; state transitions are tested |
| L1 | `jawnos-app install/uninstall/enable/disable/upgrade/doctor`; migrations + rollback | Install, disable, upgrade-fail-rollback and purge round-trip on a temp host |
| L2 | Per-app metrics, `/manager/apps/health`, SLOs, the panel | Injected errors mark an app degraded; the reading is JSON and survives a restart |
| L3 | `jawnos-app new`, canary slot, trust tiers, the generation pipeline | The agent produces a passing app that installs into canary and is promoted or rolled back |
| L4 | Auto-tune with canary measurement and revert | A tune improves or reverts; permissions/core are untouchable |
| L5 | v1 fork rehearsal: branch, copied DB, side-by-side run | v0 and v1 serve the same data; cutover and fallback are both rehearsed |

## Risks

1. **Arbitrary code in the house.** The trust tier, file sandbox, capability allowlist and canary are
   the answer; a missing check is a breach, not a bug. Treat `agent` as hostile.
2. **Data loss on uninstall.** Purge is irreversible; require a backup and an explicit flag, and keep
   the data by default.
3. **Dependency drift.** An installed app's `requires` can be satisfied at install and broken later
   by an upgrade. Re-resolve at boot and refuse to start a discontinuous graph.
4. **Metric noise / auto-tune harm.** An agent optimizing the wrong number can make an app worse.
   Only reversible knobs, only against a stated SLO, always measured on the canary.
5. **Autonomy without review.** The agent can generate plausible code that passes tests and still
   leaks. Promotion to `reviewed` is a human act; push rights are scoped to the v1 branch.
6. **Fork divergence.** Two source trees with different data formats is how houses get lost. v1
   reads the same schema until sync v4 is proven; no fork before the entry criteria.
7. **Secrets.** Generated code must never contain a key, token or credential; scan on generation and
   again on install.

## What this adds to the SDK

- `JawnOS::App::Manager` (registry, state machine, install/upgrade/uninstall).
- `jawnos-app` CLI and `jawnos-app new`.
- `Host::Health` (per-app counters/history) and `manifest->{health}`.
- A canary route prefix and a second schema per app, only while a candidate is being measured.
- The registry is the source of the route/asset/menu/help maps, replacing the hand-maintained ones.

The three documents now form one story: `app-sdk.md` (contract), `app-databases.md` (data boundary),
`app-lifecycle.md` (operations, generation, and the v1 fork).
