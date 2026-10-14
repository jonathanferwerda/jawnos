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
| `ai_jobs` | one per job | `owner`, `at` — who last ran the job, for the review list |
| `ai_budget` | one per machine per day | `tokens` — that machine's spend today |

`ai_budget` is keyed by `(machine, day)` on purpose: each machine owns and
rewrites only its own row, so two machines' increments never clobber each other
and the sync simply adds them up. The house total is `sum(tokens)` for the day.

### Eligibility

A machine is in the house when its `ai_house` row says it has a model and its
`seen` is fresh (ten minutes). A machine with nothing synced yet sees only
itself, so a lone or freshly-provisioned machine still works. Publishing is a
heartbeat: `ai_house_publish()` writes this machine's row (throttled to a couple
of minutes) from the watch tick.

### Ownership

For a job `J` (a named unit of work — `fix:<source>:<signature>` for a repair,
`eval:<app>` for an evaluation) every machine ranks the house by a stable hash:

```
rank(J, m) = djb2(J . '|' . m)
home(J)    = the member with the smallest rank
```

The home is computed, not stored, so **every machine derives the same owner from
the same roster** — no claim to write, nothing to race, and it works across the
sync latency that a lock would stumble on. A machine runs `J` only when it is
`home(J)`. `ai_job_note(J)` records the run in `ai_jobs` for the review list.

Where a machine must be named by hand (the existing Configure → Sys "Nightly
machine" for evaluations), the named machine still wins; `home(J)` is the
fallback when it is left blank, which turns "Any machine" from *once per queue*
into *once for the house*.

### The shared purse

`watch_tokens_spent()` now reads the house total (`ai_house_budget_spent`, the
sum of the day's `ai_budget` rows) and falls back to the local cache as a floor.
`watch_tokens_add()` writes both the local cache and the shared ledger. The
`error_watch_budget` setting is therefore the **house's** daily ceiling, shared
by every machine, rather than a private allowance each machine can exhaust.

## What it does not do

- **No automatic failover.** A job waits for its home. If the home is off, the
  evaluation for that scope does not run that night. That is the safe direction —
  better a night skipped than the house paying twice — and the home can be named
  by hand. A lapsed-claim hand-off can be added later if it is wanted.
- **Eventual, not instant.** Until a machine's rows sync, it may count itself in
  a smaller house (worst case: itself) and run a job another machine also runs.
  The rows converge and the next round de-dupes.

## Where it lives

- **Helpers** — `subroutines.pl`: `ai_house_members`, `ai_job_rank`,
  `ai_job_owner`, `ai_job_may_run`, `ai_job_note`, `ai_house_publish`,
  `ai_house_budget_spent`, `ai_house_budget_add`, and the rewired
  `watch_tokens_spent` / `watch_tokens_add`.
- **Schema** — `Manager.pl` `update_database` (and the watch creates them too, so
  the watch works before a login migrates).
- **Gates** — `coding_propose_fix` (error and guide fixes) and
  `appointment_evaluation_job` (evaluations).
