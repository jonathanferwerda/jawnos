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
  Kimsufi box in an LXC, and the exit node with them. The sequencing is the point: `cloud` is the
  tailnet's Headscale control plane *and* its exit node, so it is wiped last, never first.
  Phases, verified baseline and open questions: `docs/infrastructure-roadmap.md`.
