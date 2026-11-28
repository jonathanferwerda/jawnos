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
- **Find / stop** — the spoken Guide now has a `find` branch (`Manager::help_search`) and a `stop` branch (`voice_command_apply`). These were already server-side; the funnel exposes them to the wrist.

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

## What is not done yet

The funnel scopes the Guide and gives it the app's help, but it is not yet a generic **app-action bridge**. A command that needs a route with no Guide tool still needs a resolver (the audit lists the gaps: weather is done; history/visit, mail send, store, camera and window control are next). The next big piece is one validated `app` tool that can call an app's own route with its own help page in context, behind the same visibility and confirmation gates.

## Files

- `lib/JawnOS/Domain/VoiceFunnel.pm` — catalogue, matcher, router, identity, weather.
- `lib/JawnOS/Domain/Ai.pm` — fast path, scoped prompt, `find`/`stop` branches.
- `lib/JawnOS/Manager/Part28.pm` — self-app fallback for `measure`.
- `perl/help/topics_features.pl` — the Voice topic now mentions the funnel.
- `t/483-voice-funnel.t` — matcher, scope, router contract, identity, weather, wiring.
