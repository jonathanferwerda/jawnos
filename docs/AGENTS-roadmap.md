# Deferred operational items

Moved out of `AGENTS.md` (a per-task reference, not an every-request map).

## Next up (deferred)

- **jawnos-v1 fork — not yet; roadmap only.** `main` stays v0 (the house) while the App SDK,
  per-app databases and the app lifecycle are built. Fork when: the host API is 1.0 and
  `Host::Solo` runs an app alone; Gallery, Embedded and Travel are on the SDK; per-app DBs are at
  Phase 2+ with sync v4 and the multi-DB backup bundle; the lifecycle is at L3 (registry,
  install/upgrade with rollback, health panel, canary); the app store is at S2 (signed release
  records, bundle verification, peer/cache fetch) with the review gate wired to install; the sandbox
  is at SB1 (`userns` on desktop/Android) or SB2 (`systemd` on the installed OS); and the suite plus
  a canary house have been green for a week on the new server. Then `v1` is developed mostly autonomously on that server,
  against copies of the house database, with `release/v1` tags, human review before merge and v0 as
  the fallback for one release. Entry criteria, branch policy and autonomy rules:
  `docs/app-lifecycle.md`.

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
