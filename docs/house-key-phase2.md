# Phase 2 — the house key (`K_house`) and the password as a recovery share

**Status:** implemented and drilled 2026-10-20 (v0.1.940–v0.1.959). The
password no longer resolves the data key and, since v0.1.959, no longer seals a
recovery share of it: the stored `__president/password_share` row is deleted by
a backfill and no login or password change mints another. Threshold shares
(paper or device) are the way back in. The lost-key drill passes on a scratch
copy and on a stand-in spare machine (fresh `HOME`, fresh snapshot, no key
file, three released shares, vault re-seeded).
**Read with:** `docs/house-key-roles-and-shamir.md`, `docs/app-only-access.md`, `help.pl` → `security`.

## Why

Today the house password is both the login and the data key:

```
sesh_check(password) -> login_gate -> session_suds -> note/file encryption
```

v0.1.938 removed the password from the citizen login — a password login is now a
`guest` + `bootstrap` session, and the app key is the citizen door — but the
password still unwraps the vault. Possessing it can still recover the house and
re-enrol a device. Phase 2 separates **authentication** from **key custody**.

## Current state after v0.1.938

- `sesh_check`: password -> `guest` + `bootstrap=1`; only the peer rail
  (`neighbour`/`remote_timestamp`) -> `resident` + `peer=1`. A browser Gate login
  no longer borrows the peer flag from `president`/`backup`.
- `app_login` promotes a paired app to `citizen` and clears `bootstrap`.
- `authentication_passer` denies a bootstrap session every manager path except the
  public pairing/recovery rail (`/manager/device/*`, `/sesh_check`, `/gate`,
  `/manager/health`, public assets), **even when `app_access=off`**.
- No loopback app-gate bypass: a tunnel proxy can make a remote browser look local.
- `app_access = enforce`. Enrolled: Chrome - Linux (app), Browser - Linux (app),
  two Android devices (phone). Two WebKit **Desktop window** rows have no app key
  and are denied `/manager`; they can pair, not open.
- Peer leases: `remote_machines.privilege` / `grant_scope` / `grant_expires`,
  `peer_allows`, action and message gates, rate limits (30 messages/min, 120
  actions/hour).
- The recovery code (`__president/recovery`) is sealed to the suds;
  `/manager/device/recover` unwraps it and pairs a device. A browser pairing key
  alone is not an app session under enforce.
- The password no longer rides URLs: `sesh_check` uses a POST body plus a
  `body_sha256` bound to the signed query.

## Target

- **`K_house`** — a random 32-byte data key, never derived from the password.
  Notes, files, backups and the vault use it.
- **Device-wrapped copies** — each authorised device gets `K_house` wrapped to its
  key. Prefer an ephemeral X25519 key per login (forward secrecy). P-256 phones can
  ECDH; Ed25519 device keys need conversion to X25519 (libsodium
  `crypto_sign_ed25519_pk_to_curve25519`) or a device-generated X25519 key.
- **Password = recovery share** — `wrap(K_house, Argon2id(password, salt))`, stored
  offline or as Shamir shares. It recovers the house; it does not log in.
  **Retired (v0.1.959):** the password is a login; it is not a recovery share.
- `session_suds` returns `K_house` (unwrapped for the session), not the password.
- Citizen sessions: app/device key challenge (+ biometric on phones). Password-only:
  bootstrap.
- Residents/guests: peer cards/tickets, never `K_house`.

## Decision recorded (2026-10-20) — the wrap curve

The device keys in `paired_devices` are not one kind:

| Column | Format | Can agree (ECDH)? |
| --- | --- | --- |
| `pubkey`, `app_pubkey` | Ed25519, PEM | no — signing only |
| `bio_pubkey` (phones) | P-256 SPKI, base64 DER | yes |

This box has libsodium, but nothing here depends on it: `Crypt::PK::X25519`
cannot import an Ed25519 key, so the conversion is done in plain Perl and
checked against libsodium (see below). Decision:

- the wrap takes any CryptX key object that can agree: **X25519** (a key the
  device generates for transport) or **P-256** (the phone's bio key);
- a bare Ed25519 object is **refused** by `house_key_wrap`; conversion is an
  explicit step (`house_key_ed25519_x25519_public`), never silent;
- the blob records the algorithm (`JHKY1`; alg 1 = X25519, alg 2 = P-256), so a
  later route can add one without ambiguity.

Implemented in `subroutines.pl` as `house_key_wrap` / `house_key_unwrap`, with
`house_key_wrap_alg`. Every wrap mints a fresh sender key pair, so **nothing is
stored: no wrapped copies and no `house_keys` table.** A leaked blob is useless
once the throwaway half is gone.

### Implemented 2026-10-20 (v0.1.940–v0.1.941)

- `house_key_wrap` / `house_key_unwrap` — ephemeral ECDH + AES-256-GCM; X25519
  (alg 1) and P-256 (alg 2). No stored copies, no `house_keys` table.
- `house_key_ed25519_x25519_public` / `_private` — the birational map and the
  SHA-512 + clamp, in pure Perl. Checked against libsodium on four random keys,
  public and private, byte for byte. **So an app key needs no new key type:**
  convert its public half to wrap, and its seed to unwrap.
- `house_key_password_seal` / `_open` — the recovery share: Argon2id from
  OpenSSL 3.2+, or from the `argon2` tool with the same parameters and the
  same bytes where OpenSSL is older (the probe asserts the two agree). The
  salt is printable base64 so both providers hash identical bytes. Only when
  neither provider exists does a new share fall back to `scrypt`, then
  `pbkdf2,600000`; the descriptor and salt are stored in the blob, so a share
  sealed by an older machine still opens.
- The password share (`settings` `__president/password_share`) was minted by the
  first password login and rewritten on a password change. **v0.1.959 removes
  it:** `password_share_store` is no longer called, the recovery route's
  password branch is gone, and the `password_share_retired` backfill deletes the
  stored row once per database. A lost key needs the paper code or three shares.
- `session_suds` refuses a bootstrap session outright: a password login never
  resolves the data key, even when the worker already holds it in `$gb::suds`.
  Proved device/app sessions and internal work (no `$c`) are unchanged.

**Termux:** all of it uses CryptX and OpenSSL, both already present in the
app's Perl; no libsodium, no `Crypt::NaCl::Sodium`, no compiler. Where a Termux
OpenSSL lacks Argon2, the seal records `scrypt` instead and still opens.

## Migration order (do not reorder)

1. **Prove recovery first.** Keep the current password-wrapped suds. Add the
   `K_house` wrapper alongside it and test a full restore on a spare machine. Do
   not remove the old path until the drill passes.
2. **Introduce `K_house`.** Generate it; decrypt the current vault with the suds;
   re-encrypt with `K_house`; store `K_house` wrapped for every active
   `paired_devices` row that has an app or biometric key.
3. **Unwrap at login.** After a successful app/device challenge, the device sends
   an ephemeral public key; the server wraps `K_house` to it; the session holds
   `K_house`. `session_suds` returns it.
4. **Password becomes recovery only.** ~~Re-wrap `K_house` under
   `Argon2id(password)`; store the recovery blob. Change `/manager/device/recover`
   to unwrap `K_house` (not the suds), then require a device key challenge before
   minting a citizen session.~~ Retired in v0.1.959: the password is a login,
   never a recovery share.
5. **Per-person roles.** Citizens get their own credentials/keys; residents and
   guests get tickets/peer cards. Stop sharing the password.
6. **KDF and attempts.** Argon2id, or PBKDF2 at >= 600k (the note KDF is 10k, too
   weak for a password); per-IP/house backoff; audit; short sessions; rotation.
7. **Threshold recovery.** Shamir 3-of-5 for `K_house`; no single password.

## Code touchpoints

- `Manager.pl`: `post '/sesh_check'`, `post '/manager/device/app_login'`,
  `app_session_ok`, `app_public_path`, `authentication_passer` (bootstrap gate),
  `post '/manager/device/recover'`, `security_initializer`,
  `post '/manager/security/recovery/create'`.
- `subroutines.pl`: `login_gate`, `suds_grabber`, `session_suds`, `vault_seed`,
  `vault_read`, `note_encrypter` / `note_decrypter`, `seal_file` / `open_file`,
  `rotate_house_key`, `recovery_code_*`, `peer_*` lease helpers.
- `database/schema.sql`: `paired_devices` (`pubkey`, `app_pubkey`, `bio_pubkey`,
  `kind`, `share_pubkey`), and `house_key_shares` / `house_key_share_requests` /
  `house_key_share_releases` for threshold recovery. A stored share is always
  wrapped to a device's X25519 key; the server never holds one in the clear.
- Backup/sync: `backup_now`, `rsync_*`, `vault_share`, `key_push`, and the
  "newest wins" rule for the recovery blob.
- Help: `security`, `devices_and_mesh`, `sealing_files`; add labels in all sixteen
  languages for anything new.

## Risks and guardrails

- **Never demote the password before a tested `K_house` recovery path exists.** A
  lost device must not mean a lost house. *Done in v0.1.959:* the threshold drill
  passes and the password share is gone.
- ~~Keep the old password-wrapped suds until the new path has been drilled on a
  spare machine.~~ Done: the stand-in spare-machine drill passes.
- **No loopback app-gate bypass.** A tunnel proxy can make a remote browser look
  local.
- The database carries no password-sealed copy of the house key: v0.1.959 removed
  the row and no login mints another. It carries the recovery code's sealed blob
  and the shares wrapped to device X25519 keys; a copy of the database alone opens
  neither.
- Do not share app/device keys; they are per-device. A stored share is wrapped to
  one device key, so revoking a device deletes its share as well as its row.
- Backups carry the recovery blob and the wrapped device shares (they are settings
  and table rows). The paper shares and the paper code are the pieces that must not
  live only beside the backup.
- ~~Decide the Ed25519 -> X25519 route~~ — **resolved 2026-10-20**: the
  conversion is pure Perl, checked against libsodium, so no native module is
  required on the server or on Termux.
- ~~The two Desktop window rows~~ — still keyless and denied `/manager` under
  enforce; they can pair but not open. Tracked under What remains.

## What remains

Steps 1–7 of the migration order are done. The password is a login and never a
recovery share; three paper or device shares recover the house. A stand-in
spare-machine drill (fresh `HOME`, fresh snapshot, no key file) passes. What is
left is operational, not a phase:

1. Run the same drill on a physical spare machine with three shares the person
   actually holds, before relying on it.
2. The two **Desktop window** rows still hold no app key and are denied
   `/manager` under enforce. Add the bridge or remove them.
