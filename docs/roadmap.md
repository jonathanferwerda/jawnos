# Roadmap — read this first

**Status:** the single entry point. Deep plans are linked by status below; you do not need to read
them to know what is happening this season.
**Settled:** 2026-11-09 · **Baseline:** measured on the running tree at v0.1.2491 (35–36 processes,
899 routes, 335 test files).

## The direction

1. **Perl stays the server.** No full rewrite. The measured reasons: regex is a wash, the request
   floor is irrelevant at house volume, the monolith is already split (`Manager.pl` is 24 lines),
   and 335 test files already guard behaviour.
2. **The Windows/macOS work continues in parallel** (`docs/platform-roadmap.md`). It is active and
   is not blocked by anything here.
3. **The SDK is the next architectural seam**, not a language change. Freeze the contract first;
   UI and server can then move independently.
4. **Native UI is a later project.** The web UI stays as the fallback until one native surface
   reaches parity.
5. **This season is installation and idle cost**, because those are felt daily.

## This season — four finishable steps

| # | Step | Done when |
|---|---|---|
| 1 | Define "great" with numbers | the table below has targets and a review date |
| 2 | Battery/process experiment | idle CPU < 3% of one core, PSS < 800 MB, one feature shipped while doing it |
| 3 | Desktop install on a clean VM | one command; no manual distro packages |
| 4 | SDK schema frozen | schema, auth, events and one generated client in the tree |

Step 4 is deliberately last: it is the on-ramp to native UI, not a prerequisite for it to be
useful.

## What great looks like

| Metric | Measured 2026-11-09 | Target |
|---|---|---|
| Idle CPU, whole tree | 4.0–6.3% of one core | < 3% |
| PSS, whole tree | ~1.08 GB (private ~650 MB) | < 800 MB PSS |
| `/manager/health` p50 | 32 ms new connection, ~15 ms keep-alive | < 10 ms |
| Process start | ~0.25 s | < 0.1 s |
| Desktop install | 4–6 prerequisites across distros | one command |
| Phone UI cost | WebView + 223k JS + 24 pollers | one native screen pilot |

Summed RSS overstates fork-shared pages, which PSS counts once and splits between their mappers. The
earlier 10.8% CPU sample was taken while the box was busy.

**Battery experiment — 2026-11-09.** From v0.1.2505 to v0.1.2511 the LAN presence listener
(`lib/JawnOS/Domain/Lan.pm`, with the per-peer fingerprint in `lib/JawnOS/Domain/House.pm`) fell from
1.4–1.8% of one core and 10–16 wakeups a second to 0.4–0.8% and 5.5–6.6. Three changes did it: a
non-blocking drain once a second, a per-peer fingerprint that ignores the changing signature, and
navigation applied at most every five seconds.

## Decisions

| Decision | State |
|---|---|
| Perl server | **kept** — no rewrite this season |
| Full rewrite (Go or Rust) | **deferred**; revisit only on the triggers below |
| Per-worker port behind the SDK | allowed later, one worker at a time |
| Windows/macOS roadmap | **active** (`docs/platform-roadmap.md`) |
| Native UI + SDK | direction agreed; toolkit open (platform D7 stands until a decision) |
| OS image (`desktop/mkosi`) | seed exists; not this season |

Revisit the rewrite if: third parties install it, Windows/macOS parity stays unmaintainable even
bundled, or one worker is a measured bottleneck. Not because the code is Perl.

## Documents, by status

| Doc | Status | Read it for |
|---|---|---|
| `docs/platform-roadmap.md` | **active** | Windows/macOS native install (current work) |
| `docs/roadmap-handoff.md` | **active** | the remaining feature plan (long; sections listed there) |
| `docs/AGENTS-roadmap.md` | **active** | deferred operational items |
| `docs/migration-roadmap.md` | **paused** | per-worker port reference; §3 baseline is stale |
| `docs/infrastructure-roadmap.md` | **active but off-path** | hub/VPS/tailnet move |
| `docs/it-strip-roadmap.md` | **deferred** | the USB strip idea |
| `docs/platform-p0.md`, `docs/platform-go-no-go.md` | **historical** | the measured P0 record |

## Not this season

No full rewrite · no server language change · no template or web-UI deletion · no native UI until
the SDK and one pilot screen exist · no OS-image work beyond keeping `mkosi` building.
