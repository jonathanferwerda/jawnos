# Deferred operational items

Moved out of `AGENTS.md` (a per-task reference, not an every-request map).

## Next up (deferred)

- **House key — operational finish (no code left)**: Phase 2 shipped in v0.1.940–v0.1.959. The
  password is login-only (a bootstrap session never resolves the data key), `K_house` is wrapped to
  each device's key, and recovery is the paper code or 3-of-5 Shamir shares — there is no
  password-sealed copy of the key in the database. Two operational items remain (`docs/house-key-phase2.md`,
  "What remains"): run the lost-key drill on a physical spare machine with three shares the person
  actually holds, and resolve the two keyless Desktop window rows (bridge them or remove them).
- **Dev box offload — not started**: move the suite, the builds and the programming load to the
  Kimsufi box in an LXC, and the exit node with them. **Headscale moves too** (decided
  2026-11-02) and takes a name under the house wildcard — `headscale.jonathanferwerda.com`, not a
  bare IP (Tailscale validates the control certificate) — which frees `thejunderground.com` for
  the Elixir app on the VPS. The cutover (P5) is the phase that can lock people out, so it is
  scheduled, with `/var/lib/headscale/` copied and every node re-pointed while devices are in
  reach. Two constraints: the embedded devices are hardwired to a **LAN** manager (`192.168.1.3`
  in the Pico 2 W, `192.168.2.3:45547` on the ESP32s), so firmware is **compiled on the KS-5 and
  staged/uploaded on the laptop** (USB flashing may also happen from the table); and the wildcard
  renewal (`tls_issue.pl`) must move before **2027-01-01**. The VPS's mail stack is not a mail
  server — IMAP/SMTP go straight to Gmail; rspamd and valkey are unreferenced. Phases, measured
  baseline and open questions: `docs/infrastructure-roadmap.md`.
