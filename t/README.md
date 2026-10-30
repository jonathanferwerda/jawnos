# `t/` — the regression suite

JawnOS is a single-tree Perl application, so this suite is plain `Test::More`
plus a small harness (`t/lib/JawnOSTest.pm`). It runs without the app, without
the live database, and without mail or network access.

## Run it

```sh
prove -l t                 # everything
prove -lv t/01-names.t     # one file, verbose
make test                  # after `perl Makefile.PL`
```

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
| `15-tier.t` | `tier_needed`/`tier_denied`: citizen/resident/guest paths, anchoring, unknown privilege |
| `16-sync-lock.t` | the pull marker: claim vs live pid bounds, dead/legacy markers, idle values |

## Rules for a new test

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
