# Help workflow (audits, bindings, probes)

Moved out of `AGENTS.md` (a per-task reference, not an every-request map).

## Help system (keep it accurate)

The in-app guide lives in `help.pl` (a `%topic` registry) and is served by the `help` app
(`templates/apps/help.html.ep`, `public/js/manager/help.js`, routes `/manager/help`, `/manager/help/body`,
`/manager/help/ask`). The guide agent answers through `subs::evaluation_model_call`.

**Help has two tiers, and only tier 1 is written by hand.**

- **Tier 1 — the user.** `perl/help/topics_*.pl`: plain-language prose for navigating the program.
  Translated on demand, audited by `t/11-help.t` and `scripts/help_audit.pl`.
- **Tier 2 — the agent.** Generated from the tree: `perl scripts/agent_help.pl <app>` prints the
  technical brief (sources, routes, tables, settings, the tests that claim them, and the source
  files' own notes), `--schema[=table]` prints every column, its type, the indexes and the apps that
  use the table, and `qa/coding_night/agent-index.md` is the compact index the nightly agent reads
  (`--write-index`; the pre-commit hook refreshes it, `t/97-agent-help.t` pins it). **Never
  hand-write a tier-2 fact and never translate it** — anything derivable from code is derived, or it
  becomes a lie with a date on it. Rationale (“why it is this way”) stays in the source comments and
  `docs/AGENTS-notes.md`, which the brief surfaces rather than restates.

**When you change an app's UI, update its topic in the same commit.** Then:

- `perl scripts/help_audit.pl` — checks every topic against the tree: broken `related` links, listed
  templates that have moved, `controls` a topic names that are no longer on-screen hints, and topics
  whose app's files changed since `verified` (a date; a global default lives at the top of `help.pl`).
  `--quiet` shows errors+stale; `--all` also lists fragment templates with no topic.
- The audit runs on `git push` via `.githooks/pre-push` (enable once: `git config core.hooksPath .githooks`).
  Hard errors block; stale topics print as a to-do. Bypass with `git push --no-verify`.
- The reverse question — **which topic explains this file** — is
  `perl scripts/where.pl templates/apps/<app>.html.ep`. It answers from a topic's `templates` list and
  from its `app` field, so a topic with `app => <name>` covers its page without a list entry.
  `t/11-help.t` pins the app pages that have neither (`%known_gap`): the gap may shrink, never grow.
- The guide is also handed a **generated inventory** (`help::inventory`) built from each topic's
  `templates` (plus the conventional `templates/apps/<app>.html.ep` / `public/js/manager/<app>.js`),
  listing the real on-screen hints. Keep button labels and the topic's words identical so the two agree.
- To bind a topic to files the convention misses (e.g. `handbook`, `process_monitor`, `web`), give it a
  `templates => [ ... ]` list; give a topic a `controls => [ ... ]` list to have the auditor verify the
  names it mentions still exist.
- Vetting a topic for real: run a fixture-only probe (see `.shots/help_probe*.js`, `.shots/gallery_probe.js`)
  — create a fixture appointment of an allowed type, drive the app, then clean up and restore every
  setting you touched. Fixture rules above still apply.
- **Translation is part of a help change.** A new or renamed topic title, summary, step or paragraph must
  be written in English and left translatable; the Guide's `translate`/`translate_page` engine handles the
  rest on demand. If the change adds a core interface label, add all sixteen translations in `language.pl`
  in the same commit. Run `perl scripts/help_audit.pl`; run `perl scripts/i18n_audit.pl` if you maintain
  the optional bulk catalogs.
