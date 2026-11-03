# Deferred operational items

Moved out of `AGENTS.md` (a per-task reference, not an every-request map).

## Next up (deferred)

- **Current plan: `docs/reality-check.md`.** The v1 transition below is the north star, not the
  queue. Near term: publish four CPAN modules (`HTML::Allowlist`, `Log::Ring`, `Mojo::Tunnel`,
  `App::TestsFor`), ship a minimal app format with `app_check`/`app_install`/`app_enable`/
  `app_uninstall`, and write, use and share two real AI-written apps — all while Music stays green.
  No router, sandbox, store, per-app DB or Music port until two apps have worked for a week.

- **v1 transition — phased, in place; no fork; deferred.** `main` stays v0 (the house) while the App
  SDK, per-app databases, lifecycle, store and sandbox are built behind `JawnOS::Host`. No `v1`
  branch, no `release/v1`: features land behind a flag, and the legacy path is removed only when the
  new one passes the **Music invariant** (library, playback, queue, remote outputs over PCM/Opus,
  video and subtitles, padlock/sealed tracks, archive fetch, screen-off playback) plus the
  conformance corpus. Complete when: host API 1.0 and `Host::Solo` runs an app alone; Music's vertical
  slice and Gallery's contract are on the SDK; Embedded and Travel follow; per-app DBs at Phase 2+
  with sync v4 and the multi-DB backup; lifecycle L3; store S2; sandbox SB1/SB2; and the suite plus a
  canary house green for a week. Then `VERSION` becomes 1.0 and the legacy path is deleted. Build
  order: `docs/v1-strategy.md`; criteria: `docs/app-lifecycle.md`.

- **House key — operational finish (no code left)**: Phase 2 shipped in v0.1.940–v0.1.959. The
  password is login-only (a bootstrap session never resolves the data key), `K_house` is wrapped to
  each device's key, and recovery is the paper code or 3-of-5 Shamir shares — there is no
  password-sealed copy of the key in the database. Two operational items remain (`docs/house-key-phase2.md`,
  "What remains"): run the lost-key drill on a physical spare machine with three shares the person
  actually holds, and resolve the two keyless Desktop window rows (bridge them or remove them).
- **Dev box offload — not started**: move the suite, the builds and the programming load to the
  Kimsufi box in an LXC, and the exit node with them. **Headscale moves too** (decided
  2026-11-02) and takes a name under the house wildcard — `headscale.jonathanferwerda.com`, not a
  bare IP (Tailscale validates the control certificate). **The VPS is retired** once that proves
  out; the KS-5 then runs `headscale`, `house` and `dev` as containers, with off-box, rehearsed
  backups replacing the VPS as the insurance. Buy the **32 GB** KS-5; the SYS-1 was costed and
  rejected (more expensive at equal memory, and the extra cores buy seconds). The cutover (P5) is
  the phase that can lock people out, so it is scheduled, with `/var/lib/headscale/` copied and
  every node re-pointed while devices are in reach. Two constraints: the embedded devices are
  hardwired to a **LAN** manager (`192.168.1.3` in the Pico 2 W, `192.168.2.3:45547` on the
  ESP32s), so firmware is **compiled on the KS-5 and staged/uploaded on the laptop** (USB flashing
  may also happen from the table); and the wildcard renewal (`tls_issue.pl`) must move before
  **2027-01-01**. The VPS's mail stack is not a mail server — IMAP/SMTP go straight to Gmail;
  rspamd and valkey are unreferenced. Phases, measured baseline and open questions:
  `docs/infrastructure-roadmap.md`.
