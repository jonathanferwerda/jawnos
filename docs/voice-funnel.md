# The voice funnel

A spoken request should reach the whole app surface without handing the Guide every app and every tool on every turn. The funnel does that in four stages.

## The path

```
watch / t-deck / Guide / associate
              |
              v
   1. start/stop grammar          (existing, unchanged)
              |
              v
   2. fast resolvers              (weather now; history/visit next)
              |
              v
   3. help-topic matcher          (deterministic, from the help registry)
              |
       weak or tied?
              |
              v
   4. router agent                (one small model call, topic id only)
              |
              v
   scoped Guide prompt             (one topic's help + a small verb set)
              |
              v
   the existing action executor
```

The key point is that the Guide is not given a bigger catalogue as the house grows. It is given **one help topic** and the verbs that topic can actually use.

## 1. The existing fast path

`lib/JawnOS/Domain/Ai.pm:826` already recognises start/stop plus an app name. The funnel leaves that alone: a watch command that reaches it behaves exactly as before.

## 2. Fast resolvers

Some questions are better answered without a model:

- **Weather** — `voice_funnel_weather_answer` reads the same forecast as the Weather app (`lib/JawnOS/Domain/Weather.pm:1139`), using the current GPS fix, the home plate, or a saved place. It answers “now”, “tomorrow”, rain chance, high/low and wind.
- **History / visit** — `voice_funnel_history_answer` resolves the named person or place through `Manager::help_search`, reads only that app's appointments, and answers last (past only), first, next, a count, or a stop's duration. A start from the last twelve hours reads as “now”; an older lone start is the last time. A mail/chat verb ("message", "call", "email") is deliberately left to the model.
- **Find / stop** — the spoken Guide now has a `find` branch (`Manager::help_search`) and a `stop` branch (`voice_command_apply`). These were already server-side; the funnel exposes them to the wrist.

The Guide window and its associate call the same weather and history answers
through `GET /manager/help/weather` and `GET /manager/help/history`, so a
typed or spoken request on a screen gets the same answer as the wrist.

A fast resolver returns `{ handled => 1, speech => '...' }`; `voice_brain` speaks it and never calls the model. Add the next one when a question has a reliable, cheap answer.

The funnel is on unless `__president/voice_funnel` is set to `off`; that is the escape hatch back to the old unscoped prompt.

## 3. The help-topic matcher

`lib/JawnOS/Domain/VoiceFunnel.pm` builds a catalogue from the same help registry the Help window reads (`help::catalogue`, `help::get`). Each entry carries the title, summary, first few body paragraphs, and any taught aliases (`guide_aka_read`).

Scoring is deliberately simple and inspectable:

- an app or title phrase in whole words;
- each app/title/summary/body word, with a small stemmer;
- everyday synonyms (`weigh` -> `weight`, `spend` -> `budget`, `mail` -> `email`, …).

Matching is **whole-word**, never a substring: “pen” must not fire inside “spend”.

## 4. The router agent

If the match is weak or tied, `voice_funnel_router` sends a compact catalogue (`id | title | summary`) to the small/fast Guide model and asks for one JSON object:

```json
{"id":"market","confidence":0.91}
```

The router never executes anything. It only chooses the topic the final Guide turn will read. That keeps the expensive/unreliable part small and makes the decision observable in the log.

## The scoped prompt

`voice_funnel_scope_for` builds:

- `help::briefing(topic)` — the hand-written page the person reads;
- `help::inventory(topic)` — the generated source files and on-screen controls;
- `voice_funnel_verbs(topic)` — seven common verbs plus only the app family's verbs;
- `voice_funnel_identity_prompt()` — who “me” is.

`voice_brain` passes that block to `help::actions_prompt($verbs, 0, $text)`. The prompt says the scoped list is the whole list, so a rule naming another action cannot lure the model into a verb the voice path has nowhere to run. The executor also refuses an action outside the scoped set.

## Identity

The person is `jon_ferwerda` (“Jonathan Ferwerda”; “Jon” is an alias). If `__president/voice_self` is set, that wins; otherwise the funnel finds the `people` row. `Manager::help_measure` now falls back to this self app when the old `me/my_name` row is absent, so “what do I weigh?” reaches the weight readings.

## Adding a resolver

A new **fast** resolver:

1. Add a `voice_funnel_*` function in `lib/JawnOS/Domain/VoiceFunnel.pm`.
2. Call it from `voice_funnel_fast` (or a new stage) and return `{ handled, speech }`.
3. Add the function name to the `JawnOS::Domain::VoiceFunnel` row in `lib/JawnOS/Domain/Loader.pm` (`t/91`).
4. Add a test to `t/483-voice-funnel.t`.

A new **Guide tool** (the long tail):

1. Declare it in `perl/gb/03_engines_and_tools.pl`.
2. Add it to `voice_funnel_verbs` only when a voice branch can run it.
3. Add the branch in `voice_brain` (`lib/JawnOS/Domain/Ai.pm`).
4. Add it to the peer allow-list in `lib/JawnOS/Manager/Part28.pm` only if it must cross machines.
5. Add the browser executor in `public/js/manager/help.js` if the Guide window can use it.
6. Add a route/action if it needs a new HTTP surface (`lib/JawnOS/Routes/`, `lib/JawnOS/Controller/`, `t/58`).
7. Update the app's help topic (`perl/help/topics_*.pl`, `t/11`) in the same change.

A new **app action** (the bridge): add one entry to `@gb::app_actions` in
`perl/gb/03_engines_and_tools.pl` naming the app, the `do`, the read/write kind,
the method and the app's own literal route, its parameter names, and a `speech`
sub that turns the JSON result into a sentence. No new route is needed if the
app already answers JSON. Add a test to `t/484-app-action-bridge.t`.

## The app-action bridge (first slice)

A scoped turn is now offered one more verb, `app`. It runs one declared action
of the app the turn was scoped to, through the app's own route, and speaks a
summary. The registry is `@gb::app_actions` in
`perl/gb/03_engines_and_tools.pl`:

- `clock` / `timers` (read) — `GET /manager/clock/state`: the running timers and
  the next alarm.
- `email` / `count` (read) — `GET /manager/mail/email/list`: the thread count in
  one folder.
- `market` / `add_item` (write) — `POST /manager/market/item_add`: `text`,
  `list`, `vendor`.
- `store` / `find` (read) — `GET /manager/store/register/items`: find items and
  prices by `search`.
- `store` / `orders` (read) — `GET /manager/store/register/state`: the open
  register orders and their total.

The gates are in code, not only in the prompt:

- **The registry is the whole vocabulary.** An app, `do`, method, route or
  parameter not declared there is refused. The route is then looked up in
  `JawnOS::Routes`, the table the server dispatches, so a declaration cannot
  point at a path that does not exist.
- **Visible only.** `help_app_visible` is the Guide's own rule, so a hidden or
  private app is refused however the request arrived.
- **The scoped app only.** The executor receives the turn's app and refuses an
  action another app declares.
- **Confirmation.** A read runs. A write is only proposed; it runs after the
  Confirmation Requirement is off, or after the screen confirms it. A voice turn
  never honours its own `confirmed`: it has no follow-up turn, so it can only
  propose.
- **JSON only.** The route must answer JSON; HTML is not an observation the
  bridge can speak.

The action is the app's own controller action, called on a synthetic request
built from the declared parameters (and the caller's session cookie, when there
is one). The bridge never writes straight to a table.

### A spoken write is held for the next answer

A voice turn cannot certify its own confirmation, so a write that needs one is
held in the machine-local `cache` table, keyed by the speaking watch's
`chip_id` (else the device uuid), for two minutes. The reply asks the person to
say yes. The next utterance from that same watch is taken first, before the
fast resolvers or the model:

- **yes** (`yes`, `yeah`, `sure`, `ok`, `do it`, `go ahead`, `confirm`, …) —
  resume the held action and speak the result;
- **no** (`no`, `nope`, `cancel`, `don't`, `stop`) — drop it and say so;
- anything else, another watch, or an expired row — drop it and continue
  normally, so a later "yes" cannot confirm a proposal the person moved on
  from.

The cache row is never synced between machines, and the executor re-validates
the registry, visibility, parameters and scope when it resumes. With the
Confirmation Requirement off a write still runs at once.

### The Guide's held-write card

The Guide window lists the held writes for this machine in a strip above the
composer. `GET /manager/help/pending` returns the live rows (TTL, registry and
`help_app_visible` filtered); `POST /manager/help/pending/confirm` deletes the
row as its claim and runs the action through the browser path; `POST
/manager/help/pending/cancel` drops it. There is no poller: the server sends the
`helpPendingReload` console command when a row is stored, taken, confirmed or
cancelled, and the strip also loads when the Guide window opens.

The full Guide window and its associate now get the same `app`, `weather` and
`history` tools; the voice turn's scoped list is still smaller, but nothing the
watch can do is missing from the screen. Not done yet: camera and window
control still need a route or a resolver that fits the same shape (camera has
no server route today). To add an action, add one entry to `@gb::app_actions`
and a test to `t/484-app-action-bridge.t` (read/execute),
`t/487-store-actions.t` (a read family's speech) or `t/488-history-visit.t` (a
fast resolver).

## Files

- `lib/JawnOS/Domain/VoiceFunnel.pm` — catalogue, matcher, router, identity,
  weather, history/visit, app action lines.
- `lib/JawnOS/Domain/Ai.pm` — fast path, scoped prompt, `find`/`stop`/`app`
  branches, and `voice_confirmation_kind` for the held write's yes/no.
- `lib/JawnOS/Manager/Part29.pm` — `app_action_execute`: the registry gate,
  visibility, confirmation, route lookup and JSON dispatch; the held-write
  `app_action_pending_store`/`take`/`peek` and the Guide's
  `app_action_pending_list`/`confirm`/`cancel`.
- `lib/JawnOS/Routes.pm` — `table`/`lookup`, the one route table the server and
  the bridge share.
- `lib/JawnOS/Controller/manager_help.pm`, `lib/JawnOS/Routes/manager_help.pm` —
  the held-write list, confirm and cancel routes, and the weather/history
  routes the Guide uses.
- `public/js/manager/help/03_pending.js`, `public/js/manager/help.js`,
  `public/js/manager/websocket/00_console_router.js`,
  `templates/apps/help.html.ep` — the card strip and its reload command.
- `perl/gb/03_engines_and_tools.pl` — `@gb::app_actions`; the `app`, `weather`
  and `history` tools.
- `perl/help.pl` — `app_actions`, `app_action_find`, `app_action_lines`.
- `lib/JawnOS/Manager/Part28.pm` — self-app fallback for `measure`.
- `perl/help/topics_features.pl`, `perl/help/topics_business.pl`,
  `perl/help/topics_functions.pl`, `perl/help/topics_devices.pl` — the Voice,
  Store, Appointments and Help topics name the new answers and the card.
- `t/483-voice-funnel.t`, `t/484-app-action-bridge.t`, `t/487-store-actions.t`,
  `t/488-history-visit.t`, `t/489-pending-card.t`, `t/490-guide-parity.t` —
  matcher, scope, router contract, identity, weather, history/visit, the action
  gates, the held write, the Store family, the card and the Guide parity.
