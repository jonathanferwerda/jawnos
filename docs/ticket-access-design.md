# Ticket, device, and suds — access design

Status: proposal, not built. Written 2026-10-13.

## Goal

One picture + password should stop being the master key. A ticket gets the owner into the
app (the manager, the Android app, the desktop app) **once per device**; after that the device
is known and comes back on its own — on any network, with nothing to type. Losing or expiring
a ticket must never lock the owner out. The `suds` — the house's root secret that note and
file encryption hangs off — stays, but stops travelling where it shouldn't. Peers keep syncing
the way they do today (`remote_upgrade` and friends), just with a real credential.

## What happens today

- `Manager::qrcode_generator` mints a `tickets` row (`uuid`, `password`, `secret` → the `?s=`
  bearer token, `suds`, `verification`, warranty, privilege) plus a URL/QR.
- `GET /box_office/:uuid` (Manager.pl ~L6346) checks `?s=` against the row, unwraps the
  ticket's `suds`, and puts `suds`, `database`, `warranty`, `ticket_uuid`, `privilege` … into
  the Mojolicious session.
- `Manager::authentication_passer` re-checks that session on every request; `subs::suds_grabber`
  takes the suds from **the newest active ticket**. `subs::note_encrypter` / `sealed_file_bytes`
  show the suds is the root of the encryption chain.
- Sessions are **signed cookies only** (`app->sessions->encrypted(1)` is commented out), and
  `suds` is one of the session values.
- All suds use is server-side; no client JS ever reads it.
- Peer machines authorize with a `signatorial` string plus a stored session cookie
  (`remote_useragent_maker`, `remote_upgrade`, `backup_serve`, `rsync_pack/unpack`,
  `self_deploy`, `code_bundle`, `remote_auth_test`, `merge_database`).
- The `devices` table tracks physical machines on the network (scan/neighbour data); it is
  not a roster of people's devices.

## Verified weak spots

1. **The session cookie carried the suds in the clear.** Mojolicious signed cookies are
   Base64 + HMAC, not encrypted; until phase 0 below was applied the cookie value literally
   started `{"expires":…,"suds":"SUPERS…` (`.shots/session_encryption_check.pl plain`). ~100
   call sites read `session('suds')` (Manager.pl 93, subroutines.pl 6, hooks.pl 1).
2. **The ticket row is self-contained.** `password` (plaintext) + `secret` + `suds` in one row:
   anyone who reads the DB — or a copy of it shipped by `remote_upgrade` — can unwrap the suds.
3. **The suds rides the newest active ticket**, so expiry and rotation are coupled to a ticket.
4. **A leaked ticket URL is a bearer credential** until it expires (replay, subject to the
   route's host guard).
5. **Peer auth is a magic string + cookie.** A leak opens backups/code push/rsync.

## Threat model

| adversary / event | must not |
| --- | --- |
| stranger on the internet | gain a session, a backup, the suds |
| a leaked cookie | reveal the suds, or outlive its expiry |
| a stolen device | reveal the suds; the other devices keep working after revocation |
| losing a device or a ticket | lock the owner out — recovery must hold |
| a stolen DB copy (rides remote_upgrade/backups) | reveal the suds |
| a compromised peer | push code, pull backups, or open tunnels |
| a shoulder-surfed QR | be replayable, or pair a second device |

## The model

### 1. Devices hold keys; tickets become single-use pairing grants

- Every personal device generates a **non-extractable keypair** — WebCrypto in the browsers
  and the apps' webviews (the Android app's keystore, the desktop app's profile). The private
  key never leaves the device.
- The existing ticket URL is the **first contact**: the new device posts its public key with
  the one-time token; the house writes a `paired_devices` row (uuid, name, pubkey(s), privilege
  = citizen, created, last seen) and burns the token. One scan per device, ever.
- After pairing, login is a **challenge**: the house sends a nonce, the device signs it, the
  house verifies against the roster and mints a session. No password, no network sensitivity.
  CryptX is already installed (`Crypt::PK::ECC`, `Crypt::PK::Ed25519`), so verification is
  native Perl.
- A device may hold several keys (one per origin: fqdn, LAN address, localhost) so every door
  the owner uses stays open without re-pairing; the roster shows one logical device.
  Canonicalising on a single origin (the :443 work) makes this mostly moot, and gives one
  stable door.
- **Guests and residents keep ticket-only sessions** — they never get device keys.

### 2. Sessions become server-side; the suds never rides in a cookie

- Session rows keyed by a random id; the cookie carries only the id; the row points at the
  paired device (or the ticket). Revoke = delete rows.
- `suds` resolves server-side after auth — a `subs::session_suds($c)` wrapper over
  `$gb::suds` / `suds_grabber`, replacing the ~100 reads. Nothing about a client's cookie can
  reveal it.
- Expiry semantics: a guest/resident ticket ends a session; a paired device stays until
  revoked.

### 3. The suds gets a vault of its own

- Stop deriving it from "the newest active ticket". One vault row, sealed (AEAD, CryptX
  `Crypt::AuthEnc::GCM` + `Crypt::KeyDerivation`) to (a) the house key
  (`~/.president/house.key`, 0600, never in the DB or in backups) and (b) the recovery code.
- Ticket rows stop carrying a live suds (legacy rows stay readable during migration).
- Rotation becomes a command: re-seal the vault and the `security` credentials, and
  re-encrypt forward; old material stays readable from the vault until rotated.

### 4. Recovery — three independent ways in

- **Paired device**: nothing to do; it just works, even long after every ticket expired.
- **Another citizen device approves a new one**: show a short code on the new device, approve
  on an old one — the same shape as the ticket desk the house already has.
- **Recovery code**: one high-entropy word string, printed/stored offline at initialization.
  The house keeps only a hash plus the vault sealed to it. It pairs a fresh first device, and
  unlocks the boot gate when every device is gone.
- Local shell access on the machines stays the last resort (as today).

### 5. Peers: remote_upgrade and friends get real keys

- Each jawn gets a **machine keypair** at init; `remote_machines` gains a `pubkey` column, and
  `neighbour_link` stays the linking UX (pubkeys exchanged when machines link).
- Manager-to-manager requests (`backup_serve`, `rsync_pack/unpack`, `self_deploy`,
  `code_bundle`, `remote_auth_test`, `/manager/president`) carry `timestamp + nonce +
  signature`, verified against the roster with a replay window. Same routes, same HTTP and
  tunnels as today — only the check inside changes.
- Backups stay sealed to the destination house key, so a copy that rides the mesh is useless
  to any other peer, and `merge_database` never sees a plaintext secret.
- This replaces the `signatorial` + stored-cookie checks directly.

## Phases

0. **Encrypted sessions** — *(done in this build)* `app->sessions->encrypted(1)` is on for
   Manager, Alarm and watch (teletype and the internal controllers already had it), so the
   `president` cookie is opaque and every earlier cookie is invalidated once. Round-trip
   verified (`.shots/session_encryption_check.pl`).
1. **Vault + suds out of the session** — *(done in this build)* `subs::session_suds($c)`
   resolves the key server-side; the vault (`~/.house.key` + a per-machine sealed row,
   `subs::vault_seed` at login, `subs::suds_grabber` prefers it) holds the suds and the
   ticket chain remains only as the migration fallback; sessions carry a `suds_id`
   fingerprint, never the key. Ticket rows still carry a suds copy until a later pass
   retires it (legacy rows stay readable through the migration).
2. **Paired devices** — *(done in this build)* a citizen session pairs the browser it runs
   in (the ticket scan is the grant in spirit — pairing happens once the session exists):
   `public/js/device.js` keeps a non-extractable Ed25519 key in IndexedDB and stores the
   public half in `paired_devices`; the gate answers a challenge nonce with a signature and
   `/manager/device/login` mints the session. `authentication_passer` drops any session whose
   device row is gone, so revoking in the new Security → Devices view kills the device at its
   next check (~seconds) — which is why full server-side session storage is deferred, not
   needed for revocation. Notes: the gate's hook allowlist must admit `/manager/device` and
   `/js/device.js`; and the debrief local-storage snapshot can restore a stale `device_uuid`
   into a fresh browser, so pairing keys on the *keypair* being present, not the uuid.
3. **Recovery** — recovery code at initialization; second-device approval flow.
4. **Peer keys** — *(done in this build)* each machine has an Ed25519 pair (`~/.peer.key`);
   `remote_useragent_maker` signs every peer request (timestamp + nonce over method/path),
   and `subs::peer_verify` checks it against `remote_machines.pubkey`, pinning the key on
   the first verified contact; unsigned requests pass only until a key is pinned.
   Converted: rsync_pack/unpack, backup_serve, self_deploy, code_bundle, remote_command,
   remote_auth_test, `/manager/president`. Still legacy: app_release/app_download and
   voice_release/voice_download (the phone app fetches those), the tunnel websocket, and
   the `/mail/msg` neighbour path.

## What this buys

- Pair a device once — moving between wifi, LAN, and the open internet never asks again.
- A stolen cookie is worthless: no suds, no key; a stolen device is revoked with one row.
- A stolen DB or backup cannot be decrypted (the suds is sealed to keys that don't travel).
- Lost everything: one printed code, or one still-working device, gets you back in.
- Peers must prove who they are before they can pull a backup or push code.

## Non-goals

- No end-to-end encryption of notes to the devices: the house decrypts server-side for its
  automations (email, schedule, budget, evaluations). This model protects the keys and the
  doors, not the house from itself.
- The T-Deck and T-Watch keep narrow ticket/relay access; they cannot hold browser keys.

## Decisions (was: open questions)

- Recovery code: a printed word string, paper only — accepted; Phase 3.
- Peer keys: now — done in this build.
- Residents: ticket-only, never device keys.
