# The house AI ledger

*One machine runs each AI job, and the day's budget is one pot for the whole
house.* This is how JawnOS keeps several machines from each paying to do the same
work.

## The problem it answers

Every machine runs its own error watch, its own guide watch, and its own
evaluation queue. Left alone they all notice the same error and each spends a
model call proposing the same fix, and every "Any machine" evaluation runs on
every queue. The token figures said as much: a single machine showed
`day 1025354/1000000`, and that was only its own tally — the other machines were
spending in parallel against their own copies of the ceiling.

## The design

Two ideas, both carried by tables that **already sync between machines**.

The database is synced peer to peer: every table that carries a `server_time`
column and is not in `gb`'s forbidden list rides the ordinary sync
(`merge_database`, `sync_cursors`, tombstones). `staged_fixes` is deliberately
*not* synced — it names this repo's files — but the ledger below is, so the whole
house converges on the same picture with no lock service and nothing to race.

### The tables

| Table | Row | Meaning |
| --- | --- | --- |
| `ai_house` | one per machine | `has_model` (does this machine have an AI model configured), `seen` (last heartbeat) |
| `ai_jobs` | one per job | `owner`, `at` — who last ran the job, and when (the review list and the cover) |
| `ai_budget` | one per machine per day | `tokens` — that machine's spend today |

`ai_budget` is keyed by `(machine, day)` on purpose: each machine owns and
rewrites only its own row, so two machines' increments never clobber each other
and the sync simply adds them up. The house total is `sum(tokens)` for the day.

### Eligibility

A machine is in the house when its `ai_house` row says it has a model and its
`seen` is fresh (ten minutes). A machine with nothing synced yet sees only
itself, so a lone or freshly-provisioned machine still works. Publishing is a
heartbeat: `ai_house_publish()` writes this machine's row (throttled to a couple
of minutes) from the watch tick, and it runs **whatever the watch toggles say** —
the ledger gates evaluations and the shared budget too, so a machine announces
itself even with both watches off. `ai_house_heartbeat()` creates the tables and
publishes, so the ledger works from the first boot after an update.

### Ownership and failover

For a job `J` (a named unit of work — `fix:<source>:<signature>` for a repair,
`eval:<app>` for an evaluation) every machine ranks the *present* house by a
stable hash:

```
rank(J, m) = djb2(J . '|' . m)
runner(J)  = the member with the smallest rank
```

The runner is computed, not stored, so **every machine derives the same runner
from the same roster** — no claim to write, nothing to race, and it works across
the sync latency that a lock would stumble on.

Two rules make it a failover rather than a fixed home:

- **Cover.** If `ai_jobs` holds a row for `J` whose `at` is within the job's ttl,
  the job has been run and **nobody** reruns it — `ai_job_runner` returns
  `undef`, so `ai_job_may_run` is false everywhere. A machine that runs a job and
  then goes quiet does not cause a second run.
- **The live house.** The house holds only machines whose model heartbeat is
  fresh (ten minutes). A runner that goes quiet drops out of the roster, and the
  job falls to the next-ranked member — the hand-off. The ttl is generous per
  job: `eval:<app>` is an hour (a nightly evaluation should not repeat if the
  runner is briefly quiet), a `fix:` is a week (once a repair is proposed, the
  others stay off it while a person decides).

A machine runs `J` only when it is `runner(J)`; `ai_job_note(J)` records the run
in `ai_jobs` (who, when) — that row is both the review list and the cover that
keeps the rest of the house off.

Where a machine must be named by hand (the existing Configure → Sys "Nightly
machine" for evaluations), the named machine still wins and the ledger is not
consulted; `runner(J)` is the fallback when it is left blank, which turns "Any
machine" from *once per queue* into *once for the house*.

### The shared purse

`watch_tokens_spent()` now reads the house total (`ai_house_budget_spent`, the
sum of the day's `ai_budget` rows) and falls back to the local cache as a floor.
`watch_tokens_add()` writes both the local cache and the shared ledger. The
`error_watch_budget` setting is therefore the **house's** daily ceiling, shared
by every machine, rather than a private allowance each machine can exhaust.

## What it does not do

- **Not a strict lock.** It is a rumour, not a mutex. Two machines that have not
  yet synced each other both see a one-machine house and may both run a cold job.
  The cover rule de-dupes as soon as `ai_jobs` syncs; the rare overlap costs one
  extra call, against the certainty that a silent house never leaves a job unrun.
  The rows converge and the next round de-dupes.

## Where it lives

- **Helpers** — `subroutines.pl`: `ai_house_members`, `ai_job_rank`,
  `ai_job_runner`, `ai_job_may_run`, `ai_job_note`, `ai_house_publish`,
  `ai_house_heartbeat`, `ai_house_report`, `ai_balance_report`,
  `ai_balance_refresh`, `ai_house_budget_spent`, `ai_house_budget_add`, and the
  rewired `watch_tokens_spent` / `watch_tokens_add`.
- **Schema** — `Manager.pl` `update_database` (and the watch creates them too, so
  the watch works before a login migrates).
- **Gates** — `coding_propose_fix` (error and guide fixes) and
  `appointment_evaluation_job` (evaluations).
