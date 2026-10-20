# Roles (per-person keys) and Shamir recovery

**Status:** 2026-10-20 (v0.1.958). **Part 1:** the `people` table, the
`paired_devices.person_uuid` link, the owner migration, person-aware app and
recovered-device login, assignment in the Devices view, and ticket logins that
mint or resume a person. Revoking a person revokes their devices, deletes the
shares those devices hold, stops their invitations and ends their sessions at
the next request. **Shamir:** the GF(256) split/combine core is implemented and
probed (`shamir_split`, `shamir_combine`, share encode/decode). Paper shares
print once; device shares are wrapped to a device's X25519 key, stored in
`house_key_shares`, released through the gate's share request, and combined by
the recovering machine. A machine with no `~/.house.key` has been drilled on a
fresh live snapshot with a fresh machine key, and the password share is retired
(v0.1.959). A physical spare-machine run remains.
**Read with:** `docs/house-key-phase2.md`, `docs/app-only-access.md`, `help.pl` → `security`.

Phase 2 made the password a recovery share and stopped it resolving the data key.
This note is the next phase: **people instead of one password**, and **a threshold
instead of one recovery secret**.

---

## What exists today (facts from the code)

- **A device is an identity.** `paired_devices` (uuid, name, pubkey, app_pubkey,
  bio_pubkey, kind, privilege, status) is the only durable credential. There is
  no person table.
- **Any paired device is a citizen.** `post '/manager/device/app_login'` sets
  `privilege => 'citizen'` for every active device. `paired_devices.privilege`
  exists but is uniformly `citizen` today.
- **Authorization is the session string.** 17 routes test
  `$c->session('privilege') eq 'citizen'`; residents/visitors/guests/peers come
  from the ticket and peer rails. That contract is fine — the question is where
  the value comes from.
- **Tickets already mint citizens.** A ticket with `privilege = citizen`
  (`tickets.privilege`) logs in as one (Manager.pl ~10888), but the ticket is a
  link, not a person.
- **The key is server-side.** `session_suds` resolves `K_house` (the suds) for a
  proved device session; `house_key_wrap` can seal it to a device key but is not
  wired to any route yet.
- **One recovery secret today.** The paper code, and the password share
  (`__president/password_share`, Argon2id). Either one recovers the house.

---

## Part 1 — per-person keys

The goal is not new cryptography; it is **attribution and revocation**. Each
person gets an identity, and devices belong to people.

### Model

New table `people`:

```
uuid, name, privilege (citizen|resident|guest), status, created, server_time
```

New column `paired_devices.person_uuid` (nullable). A device with no person is
`unassigned` and should not be a citizen; during migration every current device
is attached to the owner.

### Flows

1. **Login** (`app_login`, `device_login`, ticket login): resolve
   `paired_devices.person_uuid` → person → `session('person_uuid', privilege)`.
   No person means no citizen session (fail closed), except during migration.
2. **Devices view**: each row shows its person; a citizen can create a person,
   assign a device, or move a device between people. Revoking a person revokes
   their devices and sessions in one move.
3. **Tickets**: a ticket login maps to a person (or mints a guest/resident
   person). The ticket stays the invitation; the person is the identity that
   survives it.
4. **Key custody**: unchanged. `K_house` stays server-side for proved device
   sessions. Per-person keys authenticate; they do not need to hold the key for
   the app to work.

### What changes

- `posts '/manager/device/app_login'` — stop hard-coding `citizen`; look up the
  person. This is the single most important edit.
- `paired_devices.privilege` — either drop it or keep it as the device's ceiling
  (a device may not exceed its person's privilege).
- The 17 `privilege eq 'citizen'` checks — unchanged. The session still carries
  a privilege string.
- Ticket login — set `person_uuid` alongside `privilege`.
- Devices UI + help topic `security` + labels in all sixteen catalogs.

### Effort

About **1.5–2 days**: schema and migration (~2 h), login/authorization (~3 h),
Devices UI (~4 h), ticket mapping (~2 h), help/labels (~1 h), probes (~2 h).

### Risk

The only real one: `app_login` currently promotes **any** active device to
citizen. The moment person lookup lands, a device with no person stops being a
citizen — so the migration must attach every current device first, and the code
must refuse to start the strict path if `people` is empty.

### Implemented 2026-10-20 — person revoke

- Security → Devices now lists the people. Revoke (two presses) marks the person
  revoked, revokes every device attached to them, deletes the wrapped shares
  those devices hold (and any row naming the person), and revokes their active
  tickets. The owner and the person using the current device cannot be revoked.
- Sessions end at the next request, not at cookie expiry: the authentication
  fast path now checks the session's person and device are still active, and the
  full pass refuses a revoked person as well as a revoked device.
- Probe: `.shots/person_revoke_probe.pl` (19 checks).

---

## Part 2 — Shamir for the house key

The goal: no single secret (password, paper code, or device) recovers the house.

### The decision that matters: where the shares live

| Placement | Good | Bad |
| --- | --- | --- |
| Wrapped to each **person's** device key | no paper; revocation is per person | needs ≥5 holders; one person with 5 devices is no threshold |
| **Paper** shares (words/QR) | survives dead devices; true separation | can be lost or photographed together |
| Hybrid (3 devices + 2 paper) | practical for a small house | two kinds of recovery to drill |

**Recommendation: hybrid, 3-of-5.** Two shares on paper, held apart from the
house; three wrapped to person devices. A stolen database holds at most the
wrapped ones, and the server must never hold more than **one** share — two plus
a stolen phone would meet the threshold.

Note the honest limit: with one person and one set of devices, Shamir does not
add much over the paper code. It starts paying off with **two or more people**,
or with paper kept off-site. Do Part 1 first for that reason.

### Implemented 2026-10-20 — paper shares

- `/manager/security/shares/create` splits the house key 3-of-5 and shows the
  five codes once. The gate's recovery field accepts any three pasted on
  separate lines, or separated by commas. Nothing is stored but the public
  policy (`__president/shamir` = `3:5`).
- A paper share is a **PS1** Crockford base32 code: uppercase, grouped in fives,
  with I/L/O read as 1/1/0. It is longer than the old base64 but can be written
  without case or `+/=`; the gate still accepts the old base64 so an existing
  set keeps working. Do not mix codes from different sets.
- The view also writes a **QR image per share** under
  `~/.jawnos_paper_shares/<stamp>/` (folder 0700, files 0600, README, not in the
  repo and not synced). The QR carries the PS1 code. `scripts/paper_share_qr.pl
  shares.txt` does the same for a set already written down. QR needs the
  `qrencode` binary; the text codes still show if it is missing.
- The share still carries the full 40-byte suds, so it is long; the QR is the
  practical paper form. A 2-of-3 set would mean three codes instead of five,
  and splitting the suds's 200-bit entropy rather than its 40 ASCII bytes would
  shorten each code, but neither is done yet.

### Implemented 2026-10-20 — device shares

- `paired_devices.share_pubkey` is an X25519 key the device generates for this
  alone and keeps non-extractable. A browser's login key is Ed25519 and cannot
  agree, so a separate key is not a convenience: it is the only way a browser
  can hold a share.
- `house_key_shares` stores each share wrapped to that key
  (`house_key_share_wrap`). The server never sees a share in the clear; a copy
  of the database carries only blobs.
- `house_key_share_create_set` wraps one share per chosen device, at most one
  per person, and returns the rest as paper codes. The older `/shares/create`
  remains the paper-only path.
- A keyless machine mints an ephemeral X25519 key, posts it to
  `/manager/device/shares/request`, and shows a code. Holders see open requests
  in Security → Recovery and press Release; the holder unwraps its share and
  re-wraps it to the asker's key (`house_key_share_release_add` stores the
  opaque blob). The asker polls `/manager/device/shares/status`, opens three
  answers, and posts the three share codes to `/manager/device/recover`, which
  checks `suds_current` and seeds the vault.
- Rotation deletes every wrapped share and leaves `__president/shamir_stale`;
  revoking a device deletes its share. Paper shares are untouched by both.
- Probes: `.shots/device_shares_probe.pl` (33 checks: one per person, wrap and
  unwrap, release, combine, revoke, rotation) and
  `.shots/share_crosscheck.pl` (browser WebCrypto opens a Perl wrap and Perl
  opens a browser wrap).

### The split

- Split the suds (40 chars) **byte-wise** with Shamir over GF(256), threshold
  `k=3`, shares `n=5`, random polynomial per byte.
- No maintained CPAN module is available, and Termux should not need one: about
  60–80 lines of GF(256) arithmetic, with test vectors checked against an
  independent implementation, plus exhaustively reconstructing from every
  3-subset and refusing every 2-subset.
- A share is `(index, k, n, bytes)`; wrapped shares use `house_key_wrap`, paper
  shares print as a base32/hyphenated code like the recovery code.

### Storage and flow

New table `house_key_shares`:

```
id, holder_person, wrapped, alg, created, server_time
```

- `paper` holders (rows with `holder_person` empty and no `wrapped`) are not
  stored at all: the paper is the store.
- **Recovery**: a machine with no vault asks three holders (or the person types
  three paper shares). Each device wraps its share to the asking machine's
  ephemeral X25519 key; three answers combine to the suds, the canary
  (`suds_current`) must accept it, and `vault_seed` heals the vault.
- Revoking a person deletes their wrapped share; the threshold must still be
  met by the remaining holders (keep at least one spare above `k`).

### What changes

- `subroutines.pl`: new `shamir_split` / `shamir_combine`; `house_key_share_*`
  helpers next to `house_key_password_*`.
- `Manager.pl`: share creation/distribution in Security; a recovery route that
  accepts combined shares; Devices view shows who holds a share.
- Backup/sync: wrapped shares ride the database; paper shares never do.
- Help: `security`, and a new paragraph on threshold recovery.

### Effort

About **2–3 days**: GF(256) + vectors (~4 h), share table and wrapping (~4 h),
recovery route and UI (~6 h), distribution UI (~4 h), drill (~3 h).

---

## Order of work

1. **People** (Part 1), with the owner as the first person and every device
   attached. Ship, use it, revoke a test device.
2. **Shamir 3-of-5** with the paper shares first (no device wrapping), so the
   split/combine and recovery route are proven without touching the roster.
3. **Device-wrapped shares** once Part 1 exists, so a share belongs to a person.
4. **Retire the password share** only after a 3-share recovery drill passes on a
   scratch copy *and* on a machine with no `~/.house.key`.

## Decisions needed before coding

1. Can one person have several devices? (Recommend yes: a person is the
   identity, devices are how they carry it.)
2. Who may create a person or move a device? (Recommend citizen only.)
3. Does the password remain as one of the five? (Recommend no: it becomes a
   paper share, or is dropped after the drill.)
4. Threshold and holders: 3-of-5 hybrid, or 2-of-3 while the house has fewer
   people?
5. What happens to a person's devices when they leave? (Recommend: revoke the
   person, delete wrapped shares, keep the threshold.)

## Guardrails

- The password share is retired (v0.1.959): the password is a login and never a
  recovery share. The paper code stays until a rotation sets it aside; three
  shares remain the threshold.
- The server stores at most **one** share.
- Revoking a person must remove their wrapped share and their devices.
- Never print or log a share; paper codes are shown once.
- Every recovery path ends with `suds_current` before `vault_seed`.

## Definition of done

- A device with no person cannot become a citizen.
- Revoking a person kills every session that person had.
- Three shares rebuild the suds; any two do not.
- A machine with no `~/.house.key` recovers with three shares and re-seeds.
  *(Stand-in drill passes: fresh live snapshot, fresh `HOME`, three released
  shares. A physical spare-machine run is still worth doing.)*
