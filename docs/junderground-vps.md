# The junderground switch on the VPS

The switch is a headless Elixir service at `thejunderground.com`. Houses register
with signed records and call through it; it does not run JawnOS. This is the
deploy, backup and restore runbook for that host, written against the live host
on **2026-11-13** (git `c68a4b2`, tag `v0.1.13`), not against the upstream
README's defaults.

Host `cloud` (`vps-7c120a57`, OVH VPS, Debian 13, `148.113.181.210`), reached
with `ssh cloud` as `debian` with passwordless sudo. The service runs as `jg`.

## 1. What runs where

| Piece | Location |
| --- | --- |
| App tree | `/opt/junderground`, owned `jg:jg`, git `origin` = `https://github.com/jonathanferwerda/junderground`, branch `master` |
| Release | `/opt/junderground/_build/prod/rel/junderground` (27 MB under `_build`; `deps` is 1.9 MB more) |
| Unit | `/etc/systemd/system/junderground.service` |
| Drop-in | `/etc/systemd/system/junderground.service.d/admin.conf` |
| Data | `/var/lib/junderground`, mode `700`, `jg:jg` |
| Front door | `/etc/caddy/Caddyfile`, Caddy 2.6.2, ports 80/443 |
| Public name | `thejunderground.com` A `148.113.181.210`; `www` redirects |

The unit is `Type=simple`, `User=jg`, `Group=jg`,
`WorkingDirectory=/opt/junderground`, and starts the release in the foreground:

```
ExecStart=/opt/junderground/_build/prod/rel/junderground/bin/junderground start
```

Environment from the unit: `PORT=4100`, `JG_DATA_DIR=/var/lib/junderground`,
`JG_PUBLIC_URL=https://thejunderground.com`, `JG_ADMIN_KEYS=` (empty; the
drop-in overrides it), `JG_AUTO_APPROVE=0`, `HOME=/var/lib/junderground`,
`LANG=C.UTF-8`, `RELEASE_DISTRIBUTION=none`.

Hardening: `Restart=always`, `RestartSec=5`, `UMask=0077`,
`NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`,
`PrivateTmp=true`, `PrivateDevices=true`, `ProtectKernelTunables=true`,
`ProtectKernelModules=true`, `ProtectControlGroups=true`,
`RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`,
`ReadWritePaths=/var/lib/junderground`, and `IPAddressDeny=any` with
`IPAddressAllow=127.0.0.1/32` and `::1/128`.

Bandit is configured with only a port, so it binds `0.0.0.0:4100`; the unit's
IP filter (`IPAddressDeny=any` with the two loopback allows) is what keeps that
private. Port 4100 is not reachable from outside (a connection to
`148.113.181.210:4100` times out); Caddy is the only public listener.
`RELEASE_DISTRIBUTION=none` means there is no remote IEx — inspect through the
journal and `/v1/meta`.

### The front door

`/etc/caddy/Caddyfile` is one block per name:

```
thejunderground.com {
    header Strict-Transport-Security "max-age=31536000"
    @jg path /v1/*
    reverse_proxy @jg 127.0.0.1:4100

    root * /var/www/thejunderground
    file_server
}

www.thejunderground.com {
    redir https://thejunderground.com{uri} permanent
}
```

Only `/v1/*` reaches the switch; everything else is the static `index.html` in
`/var/www/thejunderground`. The room signaling WebSocket is also under `/v1/*`,
so the same proxy rule carries it. Caddy holds a Let's Encrypt certificate for
the apex (issued 2026-11-11, expires **2027-02-09**) and renews it itself; there
is no certbot on this host.

### Data

`/var/lib/junderground` is the whole state:

| File | Contents |
| --- | --- |
| `admission.dets` | admission statuses, audit decisions, reports, reviews, epochs |
| `houses.dets` | the signed house records |
| `lexicon.dets` | canonical room-name seed |
| `peers.dets` | other jundergrounds |
| `rentals.dets` | rental windows and fee data |
| `rooms.dets` | rooms, tickets, grants |
| `server.key` | the switch's Ed25519 identity, mode `0600` |

`server.key` is not a table. It signs grants and tickets and is advertised as
`/v1/meta.pubkey`; clients pin it. It must be backed up with the tables.

An empty DETS file is 5,464 bytes. `admission.dets` and `houses.dets` were
6,783 and 8,704 bytes at verification because one house is registered; the other
four were still 5,464. Do not use byte size as a health check. `server.key` is
89 bytes.

### Version and current state

| Fact | Value |
| --- | --- |
| Git | `c68a4b27823b542c713cb3da8983521d77673b5e`, `master`, tag `v0.1.13` |
| Advertised | `/v1/meta.version` = `0.1.13` from `lib/junderground.ex` `@version` |
| Release directory | `releases/0.1.0/` from `mix.exs` `version: "0.1.0"` |
| Runtime | Elixir 1.18.3 on Erlang/OTP 27 (erts 15.2.7) |

`0.1.0` is the Mix project version and only names the release directory; it is
not the app version. Compare the git tag and `/v1/meta.version`.

At verification `/v1/meta` reported `houses: 1`, `peers: 0`,
`admission.admins: 1`, `requires_approval: true`, `public_url:
https://thejunderground.com`, and an empty `turn.urls`. The one house is
`jawn_s_homebase` ("Jawn's Homebase"), `admission.status: approved`.

`JG_PUBLIC_URL` is the `iss` written into room grants. Do not change it casually;
existing grants name it.

## 2. Deploy and upgrade

The release is built on the host, as `jg`, from `master`. There is no container
and no image: `/opt` is the deployment.

First record the rollback point and look at the tree:

```
sudo -u jg -H git -C /opt/junderground rev-parse HEAD
sudo -u jg -H git -C /opt/junderground status --short --branch
```

The tree is expected to show `M mix.lock`: `mix deps.get` moves bandit from
1.14.0 to 1.14.1 on this host. The deploy resets it rather than merging it.

Fetch master and build:

```
sudo -u jg -H git -C /opt/junderground fetch origin
sudo -u jg -H git -C /opt/junderground reset --hard origin/master
sudo -u jg -H sh -c 'cd /opt/junderground && MIX_ENV=prod mix deps.get'
sudo -u jg -H sh -c 'cd /opt/junderground && MIX_ENV=prod mix release --overwrite'
sudo systemctl restart junderground
```

`mix.exs` has no `releases:` section, so `mix release` assembles the single
default release named `junderground`; `mix help release` documents `--overwrite`
as "overwrite existing files instead of prompting the user for action". That is
the task that built `_build/prod/rel/junderground/releases/0.1.0`. `MIX_ENV=prod`
is required for the path the unit starts, and `mix release` compiles, so no
separate `mix compile` is needed.

Run the build as `jg`, not root: the tree, `deps` and `_build` belong to `jg`,
and `-H` gives Mix jg's own home (`/home/jg`) for its caches. A root build leaves
root-owned files that the next `jg` build cannot overwrite.

Verify:

```
systemctl is-active junderground
curl -sS http://127.0.0.1:4100/v1/meta
curl -sS https://thejunderground.com/v1/meta
```

`/v1/meta.version` should match the tag (or the source's `@version` when the tag
did not move). `houses` and `admission.admins` should be unchanged.

### Rollback

The unit starts a fixed path, so rollback is a rebuild, not a symlink flip:

```
sudo systemctl stop junderground
sudo -u jg -H git -C /opt/junderground reset --hard <previous-sha>
sudo -u jg -H sh -c 'cd /opt/junderground && MIX_ENV=prod mix deps.get'
sudo -u jg -H sh -c 'cd /opt/junderground && MIX_ENV=prod mix release --overwrite'
sudo systemctl start junderground
```

If the failed release changed a DETS table shape, restoring the code does not
revert the data: take the §4 backup before deploying a data-changing release.
For a faster code rollback, copy `_build/prod/rel/junderground` to
`.../junderground.prev` before building; with the service stopped, move it back
over the new directory. The copy holds the old code, not the old data.

## 3. Admin keys

`JG_ADMIN_KEYS` is a comma-separated list of **public** Ed25519 keys, one per
administrator crest. The unit sets it empty; the drop-in is the effective value
and holds one key today — the crest key of "Jawn's Homebase". `Admin.keys/0`
trims the list and drops empty entries, and `/v1/meta.admission.admins` is
`Admin.count/0`, the number of configured keys (not the number of decisions).

An admin key is a crest public key — the same Ed25519 key a house registers as
its crest. `Admission.pending/2` checks `Admin.admin_key?(pubkey)` before
`JG_AUTO_APPROVE`: a house registering with an admin crest is created `approved`
with reason `crest is an administrator key`. Everything else stays `pending`
because `JG_AUTO_APPROVE=0`. That is why the current house is approved with one
admin.

Admin requests are signed exactly like house requests, but name the key in
`X-JG-Admin` instead of `X-JG-Handle`; only keys listed in `JG_ADMIN_KEYS` are
accepted. The signed message is:

```
<METHOD>
<path[?query]>
<lower-case hex sha256 of the raw body>
<timestamp>
<nonce>
```

The query string is part of the path when present (for example
`/v1/admin/audit?since=0`). A `GET` body is empty, so its hash is the SHA-256 of
the empty string. Headers:

```
X-JG-Admin:     <base64 Ed25519 public key>
X-JG-Timestamp: 1760000000
X-JG-Nonce:     <at least 16 characters>
X-JG-Signature: <base64 Ed25519>
```

The timestamp must be within ±300 s of the switch's clock (`max_skew` in
`/v1/meta`); a nonce is remembered for the window and reuse is `409 replay`.
Sign the path as the switch sees it (`/v1/...`), not the full public URL. The
contract is `docs/API.md` §5 and §6b in the upstream repo; the screen contract is
`docs/CHAT-ADMIN.md`.

### Add or rotate a key

Edit the drop-in, keeping the key that is already there when adding:

```
sudoedit /etc/systemd/system/junderground.service.d/admin.conf
```

```
[Service]
Environment="JG_ADMIN_KEYS=<existing-key>,<new-key>"
```

Then reload and restart, and read the count:

```
sudo systemctl daemon-reload
sudo systemctl restart junderground
curl -sS http://127.0.0.1:4100/v1/meta | grep -o '"admins":[0-9]*'
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4100/v1/admin/queue
```

The first prints the configured count; the second must be `401` without a
signature, proving the admin route is live but closed. A real admin read must be
signed.

Rotation is two restarts: add the new key, verify it works, then remove the old
one. Removing a key does not change a house's stored admission status; it only
removes that key's ability to sign admin requests. A removed key's own house
stays approved.

The private half never goes on the VPS: the switch needs only public keys. The
house's crest key signs on the house side (`perl/junderground.pl`; the browser
never holds it). Do not paste `server.key`, an admin private key, or secrets into
a record, a log, a commit or this doc.

## 4. Backup

There is **no backup timer** for this switch. `systemctl list-timers --all` has
no junderground unit, `crontab -l` is empty for root and `jg`, and nothing else
copies `/var/lib/junderground`. The live directory is the only copy on the host,
including `server.key`: losing it changes the switch's public identity and
breaks every client that pinned `/v1/meta.pubkey`.

Stop the service for the copy so DETS closes cleanly (each table closes on
termination; `auto_save` is 2 s), then tar the directory:

```
sudo install -d -m 0700 /var/backups/junderground
f=/var/backups/junderground/junderground-$(date +%F-%H%M).tgz
sudo systemctl stop junderground
sudo tar -C /var/lib -czf "$f" junderground
sudo chmod 0600 "$f"
sudo systemctl start junderground
```

If `tar` fails, start the service again before investigating. A copy of an open
DETS file is not a consistent restore.

Check the archive (this lists names; it does not print the key):

```
sudo tar -tzf "$f"
```

Expect `junderground/`, the six `*.dets`, and `server.key`. The archive is `0600`
because of `server.key`; copy it off the host — a file on the same disk is not a
backup of the disk.

### Suggested timer shape — not installed

Decide the off-box destination and retention first. A local stage plus a nightly
stop is short, but it is still an outage, so do not enable this blindly.

`/usr/local/sbin/junderground-backup.sh`:

```sh
#!/bin/sh
set -eu
dir=/var/backups/junderground
mkdir -p "$dir"
out="$dir/junderground-$(date +%F).tgz"
systemctl stop junderground
trap 'systemctl start junderground' EXIT
tar -C /var/lib -czf "$out" junderground
chmod 0600 "$out"
find "$dir" -name 'junderground-*.tgz' -mtime +14 -delete
```

`/etc/systemd/system/junderground-backup.service`:

```ini
[Unit]
Description=junderground data backup
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/junderground-backup.sh
```

`/etc/systemd/system/junderground-backup.timer`:

```ini
[Unit]
Description=Nightly junderground data backup

[Timer]
OnCalendar=*-*-* 03:20:00
Persistent=true

[Install]
WantedBy=timers.target
```

The service runs as root because it stops the unit and writes `/var/backups`.
The script stages the archive locally; a pull from another machine (`rsync`,
`scp`) is what makes it a backup, and that step is not installed either.

## 5. Restore

Restore only this switch's archive, and only with the service stopped. Keep the
old directory until the new one verifies:

```
sudo systemctl stop junderground
sudo mv /var/lib/junderground /var/lib/junderground.before-restore-$(date +%F-%H%M)
sudo tar -C /var/lib -xzf /var/backups/junderground/<archive>.tgz
sudo chown -R jg:jg /var/lib/junderground
sudo chmod 700 /var/lib/junderground
sudo chmod 600 /var/lib/junderground/server.key
sudo find /var/lib/junderground -name '*.dets' -exec chmod 600 {} +
sudo systemctl start junderground
```

The tar was made as root and preserves owner and mode; the `chown`/`chmod` are
the belt-and-braces for an archive made another way. The unit's `UMask=0077`
would create new files `0600` anyway.

Verify:

```
curl -sS http://127.0.0.1:4100/v1/meta
curl -sS http://127.0.0.1:4100/v1/houses/jawn_s_homebase
curl -sS https://thejunderground.com/v1/meta
```

`houses` should match the archive's state, and `admission.admins` should still
match the configured keys. `/v1/meta.pubkey` must equal the value clients pinned
before. If `server.key` was missing from the archive, the switch generated a new
one: the public key changed, grants and tickets signed by the old key no longer
verify, and every client must re-pin.

An old backup is a rollback, not a merge. A house that registered after the
backup is gone from the directory unless it re-registers with its crest. Do not
put another switch's directory here: the records are signed and portable, but the
switch identity and the admission/audit tables are this switch's.

## 6. Verification and health

| Check | Command | Expected |
| --- | --- | --- |
| Service | `systemctl is-active junderground` | `active` |
| Enabled | `systemctl is-enabled junderground` | `enabled` |
| Unit state | `systemctl status junderground --no-pager` | `active (running)`, one main BEAM process |
| Log | `sudo journalctl -u junderground -n 100 --no-pager` | boot lines, no crash loop |
| Warnings | `sudo journalctl -u junderground -p warning --since '1 hour ago' --no-pager` | empty or explained |
| Local API | `curl -sS http://127.0.0.1:4100/v1/meta` | JSON, `version`, `houses`, `admins` |
| Public API | `curl -sS https://thejunderground.com/v1/meta` | same version and counts |
| House | `curl -sS https://thejunderground.com/v1/houses/jawn_s_homebase` | `admission.status: approved` |
| Front door | `curl -sSI https://thejunderground.com/` | `200`, `server: Caddy`, HSTS |
| Caddy | `systemctl is-active caddy`; `sudo caddy validate --config /etc/caddy/Caddyfile` | `active`; `Valid configuration` |
| Private bind | `curl -m 5 http://148.113.181.210:4100/v1/meta` from outside the VPS | must time out |

Certificate expiry and renewal are two commands of their own:

```
echo | openssl s_client -connect thejunderground.com:443 \
  -servername thejunderground.com 2>/dev/null | openssl x509 -noout -dates
```

```
sudo journalctl -u caddy --since '7 days ago' --no-pager | grep -i certificate
```

The first prints `notBefore` and `notAfter` (currently **2027-02-09**); the
second shows the renewal lines when Caddy runs them.

The journal is at debug level, so every successful request appears
(`GET /v1/...`, `Sent 200`). That is expected; it is not a fault.

## 7. Known gaps and cautions

- **No media plane.** `/v1/meta.turn.urls` is `[]`, no coturn or SFU is installed
  or listening, and the `JG_SFU_*` environment is read but has no implementation.
  The upstream README marks signaling/SFU/coturn as "designed, not built"; the
  design is `docs/SFU.md`. Signaling metadata is relayed, but media cannot cross
  NAT without TURN, and a mesh above a handful of houses needs an SFU. Adding one
  means new ports (3478, 5349, 7880/7881, 50000–60000/udp) and firewall work, not
  a unit tweak.
- **No backups.** See §4. There is no timer and the live directory is the only
  copy on the host.
- **No rate limiting.** The upstream README says "TLS, rate limiting, metrics —
  not yet (run behind a proxy)". Caddy terminates TLS and routes, but this
  Caddyfile has no rate limit; signatures and nonces stop forgery and replay, not
  volume. Add an edge limit if abusive traffic appears.
- **Debug request logging.** `lib/junderground/router.ex:23` is
  `plug(Plug.Logger, log: :debug)`. Every path and status goes to the journal;
  bodies and signatures do not. Paths include handles and admin routes. Lower it
  in source and redeploy if the volume or visibility matters; there is no
  environment switch.
- **Loopback by unit, not by bind.** Bandit binds `0.0.0.0:4100`; the wall is
  `IPAddressDeny=any` plus the two loopback `IPAddressAllow` lines. Do not remove
  them without a host firewall. Caddy is the intended door; verify external 4100
  still times out after any unit change.
- **Secrets.** `server.key` is the switch's signing identity. The admin keys in
  the drop-in are public; the private half is the house's crest and stays off
  this host. Never paste `server.key`, an admin private key, TURN/SFU secrets, or
  a login ticket into a record, a commit, the journal, or this doc. A public
  admin key is not a secret, but it is not reproduced here either.
- **One writer.** DETS has no multi-writer safety. Do not start a second release,
  an `iex -S mix`, or a restore against `/var/lib/junderground` while the unit
  runs. Stop first.
- **`mix.lock` drifts on the host.** `mix deps.get` rewrites it (bandit 1.14.1
  today); the deploy resets it. Build from `master`, not from local edits in
  `/opt`.
- **The data is this switch's.** Do not restore another switch's directory here.
  The signed house records are portable; `server.key`, the admission decisions
  and the audit log are not.
- **Naming has a plan and a live fact.** The roadmap records D12 (2026-11-13):
  the VPS stays, hosts this switch and owns the apex; the KS-5 takes the dev and
  house containers. The apex resolves here. Check §8 before changing DNS, the
  certificate, or Caddy.

## 8. Cross-references

In this tree, `docs/infrastructure-roadmap.md` is the plan: §2 for the `cloud`
baseline, §4 for names and certificates, §7 P6/P7 for the retained VPS and the
switch, §11 for the *JawnOS* backups (a different backup, not this switch), and
D12 for the decision that keeps the VPS. The roadmap is the plan; this runbook
records the live host and does not edit it.

The roadmap was updated at v0.1.2860 to match this host: D11 (retire the VPS)
is superseded by D12 (keep it), P6 no longer cancels it, P7 says Elixir runs
here rather than in a KS-5 container, and the certificate table assigns the apex
to this host. If the two disagree again, re-measure the host and fix the
roadmap, not this page's facts.

Upstream (`https://github.com/jonathanferwerda/junderground`, `master`):
`README.md` for the environment table and the "what works" list, `docs/API.md`
§5 for signed requests and §6b for the admin endpoints, `docs/CHAT-ADMIN.md` for
the administrator's screen contract, and `docs/SFU.md` for the media design. The
signing message itself is `lib/junderground/auth.ex` (`Auth.message/4`), and the
admin verifier is `lib/junderground/admin.ex`.

The house side is `perl/junderground.pl` (requests signed with the house crest;
the browser never holds the key), loaded by `lib/JawnOS/Manager.pm`. Its settings
are `app=junderground` with `url` and `handle`; Chat → Rooms is the screen.

---

Verified 2026-11-13 on `cloud`: `systemctl cat junderground`, `ss -lntp`,
`/v1/meta`, `/v1/houses/jawn_s_homebase`, `ls -l /var/lib/junderground`,
`/etc/caddy/Caddyfile`, `openssl x509`, `caddy validate`, `mix help release`.
