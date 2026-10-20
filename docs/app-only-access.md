# App-only access

The goal: the private manager is reachable only from the installed JawnOS apps
(desktop and Android) or from the signed peer rail used by
`remote_device_connect()`. A browser gets no manager page and no manager API.
The public homepage and store stay open to everyone, including future
third-party apps.

The important move is to stop treating "a browser that logged in" as the same
thing as "the JawnOS app". A cookie or a user-agent string can be copied; a key
held by the app's native process cannot.

> **Status (v0.1.892):** the server gate (`app_access` = off / shadow /
> enforce), the challenge/login routes, the open-in-the-app page, and the
> desktop Ed25519 bridge all ship. The setting starts on **shadow**. Two steps
> remain before switching it to **enforce**: restart the desktop app so it loads
> the bridge and approve its key on the phone, and enroll a fingerprint on the
> tablet under Security -> Padlock. The phone (`vgqQ…`) already has a Keystore
> key, so it can sign in with or without a separate `app_pubkey`.

## Two surfaces

| Surface | Examples | Who may use it |
| --- | --- | --- |
| Public | `GET /`, `GET /store`, its assets, `box_office` ticket entry, the APK store (`app_release`, `app_download`), health | Anyone, including future apps |
| Private | `/manager` and every manager route, the lock page, padlock/device APIs | The JawnOS app, or a verified peer (`remote_device_connect`) |
| Bootstrap | `/manager/device/app_*`, `/manager/device/pair`, `login`, `recover`, `request*`, `sesh_check` | Needed before an app session exists; each route keeps its own signature/password check |

A request to a private path without an app session is answered with the
**open-in-the-app** page, never with the manager. A browser that happens to hold
a valid ticket still cannot pass, because a ticket only gets it to the bootstrap
routes.

## App identity: a native key

Each app holds a key the browser cannot use:

- **Android:** the existing `JawnBiometricKey` (EC P-256 in Android Keystore,
  `setUserAuthenticationRequired`). The OS releases it only after the
  fingerprint prompt. A third-party app cannot use another app's Keystore key.
  `vgqQ9…` already has one enrolled.
- **Desktop:** a new Ed25519 key in the app's keyring/config directory, exposed
  to the page through the existing `jawnos` script-message handler. A browser
  has no such handler.

The public key is stored on the paired device as `app_pubkey` + `app_kind`
(`ec` or `ed25519`). A browser cannot enroll one because the enrollment must be
approved by a device that is already trusted (see below).

## Sessions

1. **Bootstrap:** the app opens the ticket URL (or pairs from the gate). The
   ticket is the trust anchor for the first app on a machine.
2. **Enroll:** the app asks its native key for the public half and sends it with
   a signature made by the device pairing key. On a phone the already-enrolled
   biometric key is the app key. On the desktop the app key is generated on
   first launch.
3. **Approve:** an app key that is not the first one on that device waits for
   approval on an already-trusted app (the existing `device_requests` door). A
   browser can create a request; the person denies it.
4. **Login:** `POST /manager/device/app_challenge` issues a nonce;
   `POST /manager/device/app_login` verifies
   `app-login\n<device_uuid>\n<nonce>` against `app_pubkey`. Success sets
   `session app=1` and `app_until` (12 hours). The desktop signs silently; the
   phone asks for one fingerprint, then keeps the session.
5. **Renew:** the app calls `app_login` again before `app_until`; the browser
   cannot renew because it cannot sign. A stolen cookie therefore has a bounded
   life.

## Gate

`app_session_ok($c)` is true when `app_until > now` or the session is a verified
peer. `app_peer_ok($c)` is the second door: a request carrying a real
`X-Peer-Signature` from a roster row whose key is already pinned. It never uses
the trust-on-first-contact path, so a browser that quotes a signatorial cannot
ride it. A private request without either is:

- **shadow** (the migration default): logged as `app gate: would deny …`, still
  answered. This is how the allowlist is checked on a live machine.
- **enforce:** answered with the open-in-the-app page.

The peer rail is allowed by session, not by a URL allowlist: `sesh_check` (which
already requires the peer password/signature) marks the session `peer=1`, and
every later peer request rides that session. `remote_device_connect()` therefore
keeps working with no app key. If that cookie is lost after a restart or a
profile change, the route's own signature check still gets the peer in, because
the app gate now verifies the same pinned key instead of answering with the
open-in-the-app page. Tunnels ride this rail: the peer dials
`/manager/tunnel/ws` (a public route that verifies its own signature), and the
forwarded HTTP calls carry the peer session or signature.

A **raw browser opened through a tunnel is still a browser**. The tunnel is a raw
TCP proxy, so the peer sees a local HTTPS connection with no app key and no peer
signature and, under Enforce, answers it with the open-in-the-app page. The Dev
panel's **Go** is the exception: it mints a ticket on the peer over the signed
peer rail, the ticket records the minting house's `signatorial`
(`tickets.peer_signatorial`), and the ticket login sets the session `peer=1`
with that signatorial. `app_session_ok` then accepts it as that peer (visitor
scope), so a headless peer needs no local app key and no person of its own. A
ticket minted at a box office carries no `peer_signatorial` and is still
answered by the app gate under Enforce.

`jawnosctl` is a supervisor, not an installed app: it holds no app key. Its
`status`/`start`/`stop` commands read `/manager/health`, which stays public, and
its `open` command starts the installed `jawnos-desktop` app when a graphical
session is present. A headless server has no manager UI to open, which is
intentional.

## Rollout

1. Ship the server helpers, the open-in-the-app page, the native desktop bridge,
   and the app-login JS. Leave `app_access` at **shadow**.
2. Use the phone app to approve the desktop app's key (and the tablet's, after
   enrolling a fingerprint on the tablet under Security).
3. Check the shadow log: every path a browser touches that would be denied.
4. Set `app_access` to **enforce** from Security → Padlock.

Until step 2 is done, do not enforce: the current desktop app has no native key
bridge yet, and the old browser sessions would be locked out with it.

## The homepage and store

`GET /` and `GET /store` stay public and must not require an app session. Their
assets are public. When other apps are admitted, give them a versioned public
API (`/api/v1/...`) rather than the manager routes, so the private surface never
has to be exposed to them. The manager's `/manager/store` remains private.

## What this does not solve

- A copy of the app's private key (desktop file with the wrong permissions, or a
  rooted phone) defeats the app key. Store the desktop key `0600` in the user's
  keyring/config directory; Android Keystore is already app-scoped.
- A stolen ticket can bootstrap a new app key. Treat the ticket like the paper
  recovery code: short-lived and single-use where possible.
- Public pages are public. Do not put private data behind `/` or `/store`.
