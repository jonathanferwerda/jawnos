# Help as live docs

A small first slice of the DolDoc idea: a help page can carry a value read when
the page is drawn, and a line that opens the thing it describes. The registry is
still data; nothing here makes help executable beyond the two fixed shapes below.

## What is implemented now

- **Live values.** Body text, steps and the summary may contain
  `{{live:name}}`. `help::render_live($text)` escapes the whole string first and
  then replaces a token only when `name` is a key in `%live_token` (`help.pl`).
  An unknown name is left verbatim, so a typo is visible and harmless.
- **Runnable examples.** A topic may carry
  `examples => [ { open => 'app', app => 'music' }, { configure => 'plat' } ]`.
  `help::example($spec)` validates the shape and returns the app name or the
  Configure tab id; `templates/apps/help.html.ep` draws each one as a button.
  Opening an app uses the existing `.help_open_app` path
  (`appWindowOpener`). Opening Configure uses `appWindowOpener('configure', …)`
  and then presses the real `.configure_toggle` tab, so both share the paths a
  person already uses.
- **The `live_docs` topic** (category `functions`) explains the syntax, lists the
  tokens and carries two working examples, so the mechanism is demonstrably used.

## Tokens

| Token | What it shows | Source |
| --- | --- | --- |
| `version` | the installed JawnOS version | `subs::jawn_version` |
| `machine` | this machine's printed name | `subs::machine_name` |
| `now` | this machine's clock at draw time | `subs::rightNow` |
| `ollama` | `running` / `not running` | a memoised TCP probe of `127.0.0.1:11434` |
| `models` | how many assistant roles have a model set | `subs::settings_grabber` for the eight roles |
| `languages` | languages the translator offers | `language::translation_languages` |
| `topics` | topics in this registry | `scalar keys %topic` |
| `crew` | crew abilities, where the module is loaded | `crew::abilities`, guarded by `defined &` |

### Adding a token

1. Add one no-argument sub returning a string to `%live_token` in `help.pl`.
   Keep it cheap: a token is read on every render of a topic that uses it.
   Memoise anything that probes the network or shells out.
2. Add the name to the list in the `live_docs` topic.
3. Use `{{live:name}}` in a topic where the value genuinely helps. Do not
   sprinkle tokens through prose.

## The escaping rule

The template prints the helper's result with `<%== %>`, not `<%= %>`. That is
deliberate: `help::render_live` has already escaped the surrounding text exactly
as `%=` used to, then inserted the token values. The values are escaped too, so
even a machine name containing `<` stays text. The helper's output is therefore
HTML-ready and must never be escaped a second time.

There is no second rendering path: the search rail and the Guide's briefing
still read the raw registry, which is why tokens belong in body/steps/summary,
not in summaries used as hover hints or in prose the Guide is told to quote.

## Why there is no arbitrary evaluation

A token name is looked up in a fixed hash and its value comes from a sub written
in this file. The syntax cannot name a Perl sub, a file, a setting or a shell
command, and `render_live` never calls `eval` on the text. The same rule applies
to examples: only `{ open => 'app', app => … }` and `{ configure => … }` are
accepted, both reduced to an existing app/tab id. This keeps a help page from
becoming a script with a document wrapped around it.

## Next three steps

1. **Per-topic live probes with a "check now" button.** Let a topic name a small
   probe (Ollama reachable, the deck on the network, a backup younger than a
   day) and re-run it on a press, instead of only at page draw.
2. **Embedded live app state.** A block that renders a read-only fragment of an
   app's current state — the next alarm, the running appointment, the queue —
   through the same route the app already uses, so a help page shows the thing
   rather than describing it.
3. **Versioned docs with a diff view.** Store a topic's vetted revision and show
   what changed since the copy the reader is running, so a stale topic becomes a
   visible delta rather than an auditor warning.
