# `t/` — the regression suite

JawnOS is a single-tree Perl application, so this suite is plain `Test::More`
plus a small harness (`t/lib/JawnOSTest.pm`). It runs without the app, without
the live database, and without mail or network access. Most files are
regressions named for the defect that prompted them; the number is a label, not
an index.

## Run it

```sh
perl scripts/run_tests.pl                   # everything, in parallel (fork engine)
perl scripts/run_tests.pl -v t/01-names.t   # one file, verbose
perl scripts/run_tests.pl --jobs 4          # cap the workers (never above the cores)
perl scripts/run_tests.pl --serial          # one file at a time
perl scripts/run_tests.pl --dry-run         # print the command, run nothing
perl scripts/run_tests.pl --prove           # the old prove path

perl scripts/tests_for.pl --staged          # only the tests a change touches
perl scripts/tests_for.pl --staged --run    # the same, run in parallel
perl scripts/tests_for.pl --list-for PATH   # which tests claim this path
```

Never iterate with bare `prove -l t`: every file starts a fresh Perl and
re-loads the app. `scripts/run_tests.pl` boots the app once and forks, and
`tests_for.pl` narrows even that. While iterating, `tests_for.pl` is the fast
path: it maps the paths in a diff (working tree, `--staged`, `--range`, or
`--files a b`) to the tests that claim them and runs just those. The
`--list-for PATH` form prints that mapping for one path, `--json` prints one
machine-readable line, and `--strict` exits 2 instead of falling back. Anything
no test claims selects the full suite, so a missing header costs time, never
coverage. The pre-push hook still runs everything.

`make test` works after `perl Makefile.PL` (`TESTS => 't/*.t'`), but it runs
prove serially and is not the house path. `scripts/verify_change.pl` owns the
"does every file compile" gate on `git push`; this suite covers behaviour that
a syntax check cannot.

## The runner

`scripts/run_tests.pl` uses `scripts/run_tests_fork.pl`, which boots
`subroutines.pl` **once** and forks one child per test file. Under `prove`,
every file starts a fresh Perl and re-loads the app (~0.5 s, ~50 s of CPU
across the suite); the fork engine pays that once and the child inherits the
loaded code copy-on-write. A test still gets its own process, temp sandbox and
`$0`/`$FindBin::Bin`, so `use lib "$FindBin::Bin/lib"` in a test is unchanged.

Jobs default to one per core, capped at 8, and `--jobs N` is honoured up to the
core count; `--serial` is `--jobs 1`. The engine starts the tests that took
longest last run first (a scratch cache in `/tmp`, not repo state), so the
10-second QA tests do not set the wall time from the end of the queue. A prove
switch the engine does not know (`--timer`, `--failures`, ...) falls back to
prove automatically, as does `--prove`. The runner is what `.githooks/pre-push`
calls, with a `prove -l t` fallback when it is absent.

Concurrent files are safe because every one of them gets a private temp
sandbox (below) and the socket tests bind ephemeral ports. Nothing in `t/`
writes to the live database, the repo, or a fixed port; a test that needs a git
repository builds one in its temp directory.

On the 12-core house box the fork engine finishes the suite in ~12-20 s,
`prove -l -j8 t` in ~15 s idle, and `prove -l t` serial in ~46 s. Timings drift
with load; the engine's advantage is the single boot, not parallelism alone.

## What the harness does

`use JawnOSTest;` loads `subroutines.pl` **once**, from a throwaway temp
directory containing symlinks to the real source and a minimal `config.json`.
`subroutines.pl` reads `./config.json` and requires `gb.pl`, `Websocket.pl` and
`language.pl` by relative path at boot, so it has to be loaded from a directory
shaped like the repo. The sandbox keeps a clean checkout runnable (the live
`config.json` is gitignored and install-local) and keeps `~/manager.log`,
`~/.president/` and `database/jawnos.db` out of the tests.

After loading, the process is back in the repo root and `TZ` is pinned to UTC, so
calendar assertions are civil dates rather than local-time accidents.

Exports: `root()`, `sandbox()`, `ts(year, month, day[, hour, minute, second])`
(epoch milliseconds), `ymd(ms)` (`YYYY-MM-DD`).

Two more fixtures sit beside it. `t/lib/RepoSource.pm` concatenates the files
`Manager.pl` was split into — the launcher, `lib/JawnOS.pm`, `lib/JawnOS/Manager.pm`
with its helper parts, the route table and its manifests, and the route actions —
so a test that pins a helper keeps reading all of it; it also exports the
template, JS, language, help and music sources. `t/lib/*.js` are `node`
harnesses that evaluate one browser function from `public/js/` (the behavioural
checks are skipped with a diagnostic when `node` is absent), and
`t/fixtures/packages/` holds captured package-manager metadata for the
installers' tests.

## The map — where a test lives

A test is found by what it claims, not by a central list. Every `t/*.t` carries
a `# tests-for:` header, usually with a `# covers:` sentence beside it:

```perl
# tests-for: perl/subroutines.pl lib/JawnOS/Domain/*.pm
# covers:    name formatting and path safety
```

`tests-for:` is required. It lists repo-relative globs (`*` within one path
segment, `**` across segments, a trailing `/` for a whole directory).
`scripts/tests_for.pl` matches a change against them, and also selects a test
whose body spells the changed path out. `covers:` is the human sentence shown by
`--list-for PATH` and `--json`; a few older files have only `tests-for:`, so
do not rely on `covers:` being present.

`t/93-test-map.t` fails when a tracked test has no `tests-for:` header or a glob
matches nothing; that is what keeps the map from rotting as files move.
`t/99-untested.t` is the other half: every tracked source under `lib/`, `perl/`,
`templates/`, `public/js/` and `scripts/` must be claimed by some test or named
in its `%owed` debt list, with shell, Python and vendored files exempt. A new
source file with no claiming test fails the push. Remove an `%owed` entry when
its test lands.

Two commands find a test from the code side:

- `perl scripts/tests_for.pl --list-for PATH` — the tests that claim one path.
- `perl scripts/agent_help.pl <app>` — an app's files, routes, tables and the
  tests that claim them.

Most of the suite is a foundation or a feature regression. Watch the file
header or ask the locator; a repeated prefix (`t/98-*`, `t/133-*`) is normal,
because the number orders the directory, it does not classify it.

### Foundations

| File | Covers |
| --- | --- |
| `00-load.t` | the suite's own smoke test: the core module loads, the pieces the other tests call exist, the install examples are well-formed |
| `01-names.t` | names accept every printable character: `format_name`, `unformat_name`, `path_name`, `html_name`, `http_name` |
| `02-formatters.t` | prices, percentages, numbers, number words, durations, `time_abbrev_translator` |
| `03-calendar.t` | leap years, month lengths, `calendar_shift`, nth weekday, Easter, `day_key` |
| `04-schedule.t` | `interval_parse`, `schedule_parse`/`schedule_next`, the `time_span` vocabulary |
| `05-network.t` | `ip_is_private`, `same_net_test`, `subnet_cidr` |
| `10-language.t` | the core interface catalog: every label resolves in every shipped language, placeholders survive |
| `11-help.t` | every help topic is well-formed, its `related` links and `templates` resolve |
| `12-schema.t` | `database/schema.sql` executes in SQLite; core tables, `ost`/`server_time` |
| `13-travel.t` | which device was with the person |
| `14-warranty.t` | a warranty is one value for the house, not one per device; a renewal re-anchors every record |
| `15-tier.t` | the privilege tiers behind `hooks.pl`'s `before_dispatch`, anchoring, the unknown privilege |
| `16-sync-lock.t` | the pull marker: claim vs live pid bounds, dead and legacy markers, idle values |
| `17-utility-runtime.t` | utility adoption: `lasted_run` is process state, and the tunnels stall bound |
| `18-serving-probe.t` | `probe.pl` answers the master's liveness question for `./jawn`'s watchdog |
| `19-ai-limits.t` | a rate limit is not "out of credit": it clears in seconds, or at a clock time the provider states |
| `22-peer-address.t` | peer manager candidates: a stale LAN/loopback manager falls back to the fqdn, tunnel rows keep theirs |

### The pins

These are the tests that keep the tree's own indexes honest, so they are worth
knowing by name when a change moves one:

| Test | Keeps honest |
| --- | --- |
| `43-test-runner.t` | `scripts/run_tests.pl`: the fork engine, its job cap and the prove fallback |
| `54-manager-split.t` | the Manager split: `lib/JawnOS*`, `Routes*`, `Controller/*` and the `Index.pm`/`Declarations.pm` name maps |
| `58-route-contract.t` | every route path has one action, and the table is registered in a fixed order |
| `63-js-parts.t` | a split browser script keeps its index and parts, and a lazy app's files, entry functions and toggle are mapped |
| `91-domain-loader-qa.t` | `lib/JawnOS/Domain/Loader.pm` maps every domain sub |
| `93-test-map.t` | every test declares its surface, and every glob resolves |
| `96-where.t` | the locator: helper, domain, route, JavaScript and firmware resolution, and its map-drift report |
| `97-agent-help.t` | the generated technical brief (`agent_help.pl`) and the nightly agent index |
| `98-js-parts-check.t` | `scripts/js_parts_check.pl` reconstructs a split script byte-identically |
| `99-untested.t` | every tracked source file is claimed by a test, or named as debt |

## Rules for a new test

- Open the file with a `# tests-for:` line naming the source it pins (and a
  `# covers:` sentence). Globs that match nothing fail `t/93-test-map.t`; a new
  tracked source file no test claims fails `t/99-untested.t`.
- Pure functions first. Call a helper through its real door (`subs::…`,
  `language::…`, `help::…`) rather than reimplementing it.
- No writes to the live database, no `./jawn`, no mail, no outbound network.
  Fixture records go through the app's routes, never straight into a table.
- Pin time: pass an explicit timestamp (`ts(...)`) to anything that accepts one;
  never assert against `right_now`.
- If a test finds a real defect, pin it as a `TODO` test naming the file and
  line, rather than asserting the broken behaviour. Add it to the file that
  covers the area, and remove the `TODO` when the fix lands. A file you cannot
  cover yet goes in `%owed` in `t/99-untested.t`, and comes out when its test
  lands.
- While iterating run `perl scripts/tests_for.pl --staged --run`; before the
  commit run `perl scripts/run_tests.pl`. The pre-push hook runs the suite once
  more.
- The probes used to establish expected values live in `.shots/` (gitignored).

## Fixed from the first probe run

`time_abbrev_translator` (`subroutines.pl`) used to read a unit only when it was
written as a no-space shorthand. `2d` was two days, but `2 days` read as two
minutes, `2days` as two seconds, and `1 hour 30 minutes` as thirty-one minutes.
The reader now splits compact, joined and spaced forms into number/unit tokens,
and `t/02-formatters.t` covers each spelling. `interval_parse` was already
correct and is unchanged.
