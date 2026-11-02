# `t/` — the regression suite

JawnOS is a single-tree Perl application, so this suite is plain `Test::More`
plus a small harness (`t/lib/JawnOSTest.pm`). It runs without the app, without
the live database, and without mail or network access.

## Run it

```sh
perl scripts/run_tests.pl          # everything, in parallel (fork engine)
perl scripts/run_tests.pl -v t/01-names.t   # one file, verbose
perl scripts/run_tests.pl --prove  # the old prove path
prove -l t                         # serial, if you want it
make test                          # after `perl Makefile.PL`

perl scripts/tests_for.pl --staged        # only the tests a change touches
perl scripts/tests_for.pl --staged --run  # the same, run in parallel
```

While iterating, `tests_for.pl` is the fast path: it maps the paths in a diff
(working tree, `--staged`, `--range`, or `--files a b`) to the tests that
claim them and runs just those. Anything no test claims selects the full
suite, so a missing header costs time, never coverage. The pre-push hook
still runs everything.

`scripts/run_tests.pl` uses `scripts/run_tests_fork.pl`, which boots
`subroutines.pl` **once** and forks one child per test file. Under `prove`,
every file starts a fresh Perl and re-loads the app (~0.5 s, ~50 s of CPU
across the suite); the fork engine pays that once and the child inherits the
loaded code copy-on-write. A test still gets its own process, temp sandbox and
`$0`/`$FindBin::Bin`, so `use lib "$FindBin::Bin/lib"` in a test is unchanged.

Jobs default to one per core, capped at 8, and `--jobs N` is honoured up to the
core count. The engine starts the tests that took longest last run first (a
scratch cache in `/tmp`, not repo state), so the 10-second QA tests do not set
the wall time from the end of the queue. A prove switch the engine does not
know (`--timer`, `--failures`, ...) falls back to prove automatically, as does
`--prove`. The runner is what `.githooks/pre-push` calls.

Measured on the 12-core house box while it was also running a build: 27 s for
`prove -l -j8 t`, 20 s for the fork engine at `-j12`. On an idle box the
difference is the boot CPU (~50 s), so expect a larger gap.

Concurrent files are safe because every one of them gets a private temp
sandbox (below) and the socket tests bind ephemeral ports. Nothing in `t/`
writes to the live database, the repo, or a fixed port.

`Makefile.PL` already declares `TESTS => 't/*.t'`. `scripts/verify_change.pl`
still owns the "does every file compile" gate on `git push`; this suite covers
behaviour that a syntax check cannot.

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

## Files

| File | Covers |
| --- | --- |
| `00-load.t` | core module loads, `VERSION` shape, `config.json.example`, help registry loads |
| `01-names.t` | `format_name`, `unformat_name`, `path_name`, `html_name`, `http_name`, short names, escaping |
| `02-formatters.t` | prices, percentages, numbers, number words, durations, `time_abbrev_translator` |
| `03-calendar.t` | leap years, month lengths, `calendar_shift`, nth weekday, Easter, `day_key` |
| `04-schedule.t` | `interval_parse`, `schedule_parse`/`schedule_next`, the `time_span` vocabulary |
| `05-network.t` | `ip_is_private`, `same_net_test`, `subnet_cidr` |
| `10-language.t` | 16 languages, every label resolves, placeholders survive, `translate` |
| `11-help.t` | every help topic is well-formed, its `related` links and `templates` resolve |
| `12-schema.t` | `database/schema.sql` executes in SQLite, core tables, `ost`/`server_time` |
| `15-tier.t` | `tier_needed`/`tier_denied`/`privilege_is_house`/`guest_browser_session`: tiers, anchoring, unknown privilege |
| `16-sync-lock.t` | the pull marker: claim vs live pid bounds, dead/legacy markers, idle values |
| `17-utility-runtime.t` | utility adoption: `lasted_run` is process state, and the tunnels stall bound |
| `22-peer-address.t` | peer manager candidates: stale LAN/loopback managers fall back to the fqdn, tunnel rows keep theirs |
| `43-test-runner.t` | `scripts/run_tests.pl` builds a parallel `prove` command: core-derived job cap, clamping, pass-through, serial mode |

## What a test declares

Every `t/*.t` opens with two comment lines:

```perl
# tests-for: perl/subroutines.pl lib/JawnOS/Domain/*.pm
# covers:    name formatting and path safety
```

`tests-for:` lists repo-relative globs (`*` within one path segment, `**`
across segments, a trailing `/` for a whole directory). `tests_for.pl` matches
a change against them, and also selects a test whose body spells the changed
path out. `covers:` is the human sentence, and `--list-for` prints it.

A change no test claims runs the full suite, so an unmapped file is slow
rather than silently under-tested. `t/93-test-map.t` fails when a test has no
header or a glob matches nothing; that is what keeps the map from rotting as
files move.

## Rules for a new test

- Open the file with a `# tests-for:` line naming the source it pins (and a
  `# covers:` sentence), then the normal `use` block. Globs that match nothing
  fail `t/93-test-map.t`.
- Pure functions first. Call a helper through its real door (`subs::…`,
  `language::…`, `help::…`) rather than reimplementing it.
- No writes to the live database, no `./jawn`, no mail, no outbound network.
  Fixture records go through the app's routes, never straight into a table.
- Pin time: pass an explicit timestamp (`ts(...)`) to anything that accepts one;
  never assert against `right_now`.
- If a test finds a real defect, pin it as a `TODO` test naming the file and
  line, rather than asserting the broken behaviour. Add it to the file that
  covers the area, and remove the `TODO` when the fix lands.
- The probes used to establish expected values live in `.shots/` (gitignored).

## Fixed from the first probe run

`time_abbrev_translator` (`subroutines.pl`) used to read a unit only when it was
written as a no-space shorthand. `2d` was two days, but `2 days` read as two
minutes, `2days` as two seconds, and `1 hour 30 minutes` as thirty-one minutes.
The reader now splits compact, joined and spaced forms into number/unit tokens,
and `t/02-formatters.t` covers each spelling. `interval_parse` was already
correct and is unchanged.
