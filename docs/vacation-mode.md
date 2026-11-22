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
- Task renewals age only over active time. Away time after a tick is not
  counted against the renewal, so the first morning back is not a pile of
  renewals that came due while nobody was here. The shift is derived on read;
  the stored `last_completed` is never rewritten.
- The desktop calendar shades the away days across the shown month and labels
  the first day of a run **Away**. It reads the same period list and writes
  nothing.
- Phone -> IVR carries an opt-in **Away greeting**, typed or recorded. While an
  away period is active, every flow the reception can answer speaks it and then
  offers the caller a message; Ring and Reject stay as set, so calls still
  pass. A recording wins over the typed words, and if its file has moved the
  typed words are the fallback. The stored flows are never edited, so their own
  words return when the period ends.
- The Away card carries an opt-in **Presence simulation**. While a period is
  active, a chosen learned IR remote is replayed at a jittered on time and a
  jittered off time each local day, so lights or a TV look lived in. It runs on
  the machine that saved the card (the server when a controller saved it), once
  per action per day, and only within three hours of a due time, so a machine
  that was off all evening does not fire the next morning. Nothing is sent
  until a board and a remote are chosen.
- `evaluation` scheduled runs skip while away; an `each_run` report from real
  activity still runs.
- A small Away card in Configure -> Me starts, ends or cancels a period, and shows a short return digest (days away and notices that arrived).
- The card's **Keep running while away** lists the budgets, routines and notices it can keep working: a kept budget keeps counting, a kept scheduled routine still runs, and a kept notice still speaks. It writes `policy.keep_apps` in the same house-wide setting.
- After a period ends, the card opens a **held-notice review**: the app, title, message and time of each non-urgent notice that arrived while the person was gone.
- The card carries the opt-in detector: a checkbox and a quiet length (24 hours by default). The pass reads **house-wide synced activity** - `usage_sessions`, `window_events`, appointment writes, plus this machine's own sockets - so a day on the phone and laptop is not a quiet house just because the desk or tablet was closed. A quiet gap longer than the setting becomes a proposal on the card. Accepting an ongoing gap opens an away period, accepting a finished one records history, and dismissing it keeps the same gap from being asked again. A proposal never pauses a budget.

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

## Tests

`t/387-vacation-budget.t` covers the model, the budget modes, the notification
allowlist, the stock runway, the open-session boundary and the opt-in detector.
`t/388-vacation-activity.t` covers the house-wide activity union and gaps;
`t/389-vacation-keep.t` the keep lists; `t/390-vacation-notices.t` the held
notices; `t/391-vacation-calendar.t` the calendar band; `t/392-vacation-phone-
greeting.t` the typed and recorded away greeting; and `t/393-presence-
simulation.t` the presence setting, jitter, once-a-day ledger and machine gate.
The existing budget, runway, clothesline, notification, route, help and
untested-file tests are run with them.
