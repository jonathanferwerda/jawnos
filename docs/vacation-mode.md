# Away / vacation mode

Away periods are a house-wide lens on time. Vacation is the first kind, but the
same span covers a hospital stay, a work trip or a dead machine. The house keeps
recording; the period is excluded from expectations, learned routines, forecasts
and routine actions.

## What is implemented

- `lib/JawnOS/Domain/Vacation.pm`: the model (`vacation_settings`,
  `vacation_overlap`, `vacation_active_ms`, `vacation_day_mask`,
  `vacation_policy_for`, `vacation_notify_allowed`, `vacation_routine_skip`,
  `vacation_start/end/extend/cancel`, `vacation_close_open_sessions`).
- The setting is `__president` / `vacation` / `all`, a JSON list of periods. A
  missing or malformed row reads as the defaults. Proposed periods never pause a
  budget; only accepted ones do.
- Budgets: a floor rate is prorated to the time the person was here. A ceiling or
  a fixed level keeps its target. A whole away window reads `paused`, not
  `abandoned`. A measure with no readings reads `no data`, not zero (a zero made
  a ceiling look accomplished).
- `budget_holding` and `budget_autocalc` use active time.
- The stock runway uses active days.
- Runway excludes away days and their transactions from the pace.
- Clothesline home history drops home days that were away; a stay at another
  place still teaches that place's routine.
- Notifications are held (stored, not sounded, pushed or drawn live) except
  security, customs, phone/access, gate and box office. A live call passes.
- Scheduled repeats do not run during an away period; one-off appointments and
  an app on the routine keep list still run. An open start/record is closed at
  the boundary.
- `evaluation` scheduled runs skip while away; an `each_run` report from real
  activity still runs.
- A small Away card in Configure -> Me starts, ends or cancels a period, and shows a short return digest (days away and notices that arrived).
- The card carries the opt-in detector: a checkbox and a quiet length (24 hours by default). A server or computer runs the pass every ten minutes; a quiet gap longer than the setting becomes a proposal on the card. Accepting an ongoing gap opens an away period, accepting a finished one records history, and dismissing it keeps the same gap from being asked again. A proposal never pauses a budget.

## Policy

| Surface | Default |
| --- | --- |
| Floor rate budget | prorate |
| Ceiling rate budget | freeze (target unchanged) |
| Fixed level | freeze; no reading is `no data` |
| Per-app override | `prorate`, `freeze`, `pause`, `count` |
| Scheduled repeats | skip unless the app is on the routine keep list |
| Notifications | hold non-urgent; security, calls and access pass |
| Analytics | active days; away days named in the report |
| Bills, sync, backups, security | unchanged |

## Not yet built

- A per-machine detector setting: the detector is house-wide today, and only a
  server or computer runs the pass.
- A fuller "while you were away" review: a list of held notices with one press to open them, and the skipped routines named.
- A task renewal shift, a Calendar band, an away phone greeting and presence
  simulation.

## Tests

`t/387-vacation-budget.t` covers the model, the budget modes, the notification
allowlist, the stock runway, the open-session boundary and the opt-in detector. The existing budget,
runway, clothesline, notification, route, help and untested-file tests are run
with it.
