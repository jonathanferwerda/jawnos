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
| Drop-in (media) | `/etc/systemd/system/junderground.service.d/turn.conf` (`EnvironmentFile` + `JG_TURN_URLS`) |
| Data | `/var/lib/junderground`, mode `700`, `jg:jg` |
| Backup | `/usr/local/sbin/junderground-backup.sh`; `junderground-backup.{service,timer}`, 03:20 UTC |
| Off-box copy | `vivotop` pulls nightly to `~/jawnos-backups/junderground`, 04:20 local |
| Front door | `/etc/caddy/Caddyfile`, Caddy 2.6.2, ports 80/443 |
| Public name | `thejunderground.com` A `148.113.181.210`; `www` redirects |
| TURN | `coturn` 4.6.1-2, `/etc/turnserver.conf`, `3478/udp` and `3478/tcp`, relay `49160–49260/udp` |
| TURN secret | `/etc/junderground/turn.env` (`0600 root:root`), loaded only by the `turn.conf` drop-in |
| SFU | `livekit-server` 1.13.11 at `/usr/local/bin`, `/etc/livekit.yaml`, `livekit.service` |
| SFU env | `/etc/junderground/sfu.env` (`0600 root:root`), loaded by the `sfu.conf` drop-in |
| SFU drop-in | `junderground.service.d/sfu.conf` (`EnvironmentFile` + `JG_SFU_*`) |
| SFU path | Caddy `handle_path /sfu/*` → `127.0.0.1:7880`; public base `wss://thejunderground.com/sfu` |
| SFU ports | `7881/tcp` and `50000–60000/udp` public; `7880/tcp` only behind Caddy |

The unit is `Type=simple`, `User=jg`, `Group=jg`,
`WorkingDirectory=/opt/junderground`, and starts the release in the foreground:

```
ExecStart=/opt/junderground/_build/prod/rel/junderground/bin/junderground start
```

Environment from the unit: `PORT=4100`, `JG_DATA_DIR=/var/lib/junderground`,
`JG_PUBLIC_URL=https://thejunderground.com`, `JG_ADMIN_KEYS=` (empty; the
drop-in overrides it), `JG_AUTO_APPROVE=0`, `HOME=/var/lib/junderground`,
`LANG=C.UTF-8`, `RELEASE_DISTRIBUTION=none`.

The media drop-in `turn.conf` adds `EnvironmentFile=/etc/junderground/turn.env`
and `JG_TURN_URLS`. The secret lives only in that `0600` file, never in the
unit: `systemctl show` exposes `Environment=`, not `EnvironmentFile=`.

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

### Media (TURN)

coturn 4.6.1-2 is the switch's TURN relay. It listens on `3478/udp` and
`3478/tcp`, relays from `49160–49260/udp`, and advertises the public address
`148.113.181.210` (`external-ip`). Its configuration is
`/etc/turnserver.conf` (`root:turnserver`, `0640`) with `use-auth-secret`,
`realm=thejunderground.com`, `fingerprint`, `stale-nonce=600`, `user-quota=12`,
`total-quota=1200`, and `denied-peer-ip` ranges that keep the relay out of
loopback, link-local and private networks (this build takes hyphen ranges, not
CIDR). The service runs as `turnserver` and is enabled.

The shared secret is a 32-byte value (`openssl rand -hex 32`) held in two
root-only places: `static-auth-secret` in `/etc/turnserver.conf` and
`JG_TURN_SECRET` in `/etc/junderground/turn.env` (`0600 root:root`). The
`turn.conf` drop-in loads the env file and sets:

```
JG_TURN_URLS=turn:thejunderground.com:3478?transport=udp,turn:thejunderground.com:3478?transport=tcp
```

`/v1/meta.turn.urls` now returns both URLs. The switch mints coturn's
`use-auth-secret` credentials in `lib/junderground/turn.ex`: username
`<expiry>:<subject>`, credential `base64(HMAC-SHA1(secret, username))`. They
ride on a room token (`lib/junderground/rooms.ex:234`) and the signaling
socket's `hello` (`lib/junderground/signaling/socket.ex:40`).

Firewall: UFW allows `3478/udp`, `3478/tcp` and `49160:49260/udp`. If the OVH
network firewall is enabled it must allow the same; UFW alone is not enough
behind it.

### Media (SFU)

LiveKit 1.13.11 is the switch's SFU, added after the adapter landed in
`junderground` v0.1.15 (`c6199b9`, implementing `docs/SFU.md` §6). The binary is
`/usr/local/bin/livekit-server`, installed from the release tarball whose
published `sha256` was checked; it runs as the system user `livekit` under
`livekit.service` from `/etc/livekit.yaml` (`root:livekit`, `0640`). The config
uses `port: 7880`, `rtc.tcp_port: 7881`, `50000–60000/udp` and
`use_external_ip: true`; STUN found `148.113.181.210` and `2607:5300:229:171::1`,
so no `node_ip` is set. `7880/tcp` is not exposed: UFW allows `7881/tcp` and
`50000:60000/udp`, and Caddy is the only door to 7880.

There is no `sfu.` hostname. Caddy proxies the apex path instead, before the
static root:

```
handle_path /sfu/* {
    reverse_proxy 127.0.0.1:7880
}
```

`handle_path` strips `/sfu`, so the switch's base `wss://thejunderground.com/sfu`
becomes LiveKit's `/rtc` and `/twirp/*`; the health probe and the Twirp client
append to that base rather than assuming a host. A plain `GET /sfu/rtc` answers
404 from LiveKit (it expects a WebSocket upgrade); `GET /sfu/` answers 200. The
switch's unit has `IPAddressDeny=any`, so the `sfu.conf` drop-in also allows
the public address it probes (`IPAddressAllow=148.113.181.210/32` and the IPv6
counterpart, beside the loopback allows).

The env file sets `JG_SFU_URL=wss://thejunderground.com/sfu`, `JG_SFU_KEY`,
`JG_SFU_SECRET` (32 bytes), `JG_SFU_THRESHOLD=5` and `JG_SFU_TOKEN_TTL=300`.
`/v1/meta` then carries:

```json
"sfu": {"adapter": "livekit", "available": true, "threshold": 5,
        "token_ttl": 300, "url": "wss://thejunderground.com/sfu"}
```

and `"sfu"` in `features` only while the health probe is up. The adapter stores
the minted grants and the opaque room map in `data/sfu.dets`; `POST
/v1/rooms/:handle/:room/sfu/token` mints the HS256 JWT, and
`.../sfu/revoke` (owner only) revokes the grant and best-effort removes the
participant. The health and reconciler processes were initially crashing on
every timer tick (a `handle_info` return bug); v0.1.15 fixes it, and the live
proof is that stopping LiveKit for 100 s flips `available` to false and drops
`"sfu"` from `features`, then flips back within ~35 s of a restart.

Smoke test of the keys and path (no room is left behind): mint an HS256 admin
JWT with `iss` = the API key, `video.roomAdmin` and `video.roomList`, and
`POST https://thejunderground.com/sfu/twirp/livekit.RoomService/ListRooms` with
`Authorization: Bearer`. `roomAdmin` alone gets 401 for `ListRooms` (it needs
`roomList`); `ListParticipants` and `RemoveParticipant` accept the switch's
`roomAdmin` token. The SFU terminates SRTP, so an SFU call is chat-room class and
not end-to-end encrypted.

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
`admission.admins: 1`, `requires_approval: true`, and `public_url:
https://thejunderground.com`. `turn.urls` was empty then; since the coturn
install it lists the UDP and TCP TURN URLs (see §1). The one house is
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

`JG_ADMIN_KEYS` is a comma-separated list of **public** Ed25519 keys. The unit
sets it empty; the drop-in is the effective value and holds one key today: the
public half of a dedicated admin key, not a house crest. `Admin.keys/0` trims
the list and drops empty entries, and `/v1/meta.admission.admins` is
`Admin.count/0`, the number of configured keys (not the number of decisions).

The admin private key lives only on the laptop, at `~/.junderground/admin.key`
(mode `0600`); its public half is `~/.junderground/admin.pub` (`0644`) and is the
value in the drop-in. It is a standalone Ed25519 key, never derived from or
shared with a house crest. The switch holds only the public half and never sees
the private one.

The house crest is **not** an admin key, so the house does not auto-approve its
own (re-)registration; "Jawn's Homebase" is approved because that decision is
stored, and its crest still signs its normal house requests. The code path is
unchanged — `Admission.pending/2` checks `Admin.admin_key?(pubkey)` before
`JG_AUTO_APPROVE`, and a house registering with an admin key is created
`approved` with reason `crest is an administrator key` — but no house holds an
admin key now, so that path is empty by design.

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

### Rotate the admin key

Rotation is a new keypair, the new public half in the drop-in, and a restart.
Generate the keypair on the laptop; the private half is written `0600` and never
leaves the machine, and only the public half is printed. On the laptop, put the
JawnOS local::lib on `@INC` first (`eval $(perl -Mlocal::lib)` is one way), then:

```
mkdir -p ~/.junderground && chmod 0700 ~/.junderground
perl -MCrypt::PK::Ed25519 -MMIME::Base64=encode_base64 -e '
  my $k = Crypt::PK::Ed25519->new; $k->generate_key;
  open my $f, ">", "$ENV{HOME}/.junderground/admin.key" or die $!;
  binmode $f; print $f $k->export_key_raw("private"); close $f;
  chmod 0600, "$ENV{HOME}/.junderground/admin.key";
  open my $p, ">", "$ENV{HOME}/.junderground/admin.pub" or die $!;
  print $p encode_base64($k->export_key_raw("public"), ""), "\n"; close $p;
  chmod 0644, "$ENV{HOME}/.junderground/admin.pub";
  print encode_base64($k->export_key_raw("public"), ""), "\n";'
```

Edit the drop-in on the VPS as root, keeping its syntax and replacing the value:

```
sudoedit /etc/systemd/system/junderground.service.d/admin.conf
```

```
[Service]
Environment="JG_ADMIN_KEYS=<new-public-key>"
```

Then reload and restart only the switch, and read the count:

```
sudo systemctl daemon-reload
sudo systemctl restart junderground
curl -sS http://127.0.0.1:4100/v1/meta | grep -o '"admins":[0-9]*'
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4100/v1/admin/queue
```

The first prints the configured count (one for one key); the second must be
`401` without a signature, proving the admin route is live but closed.

Prove the separation from the laptop. The operator tool signs one request with
`~/.junderground/admin.key` and prints the status and response:

```
perl ~/.junderground/jg_admin.pl GET /v1/admin/queue
```

`200 OK` with the queue is the proof the new key works. Signing the same request
with the house crest is a `403` with `{"error":{"code":"not_admin"}}` — the
crest is no longer an administrator.

Removing a key does not change a house's stored admission status; it only
removes that key's ability to sign admin requests. A removed key's own house
stays approved.

The private half never goes on the VPS: the switch needs only public keys. Do
not paste `server.key`, an admin private key, or secrets into a record, a log, a
commit or this doc.

### Recovery if the laptop is lost

The admin private key exists only at `~/.junderground/admin.key` on the laptop.
Losing that machine does not lock the switch: log in to the VPS as `debian` (or
any root-capable account), generate a new keypair, and replace the value in the
drop-in as root. This is the same edit as a rotation, done from the VPS side:

```
sudoedit /etc/systemd/system/junderground.service.d/admin.conf
```

```
[Service]
Environment="JG_ADMIN_KEYS=<new-public-key>"
```

```
sudo systemctl daemon-reload
sudo systemctl restart junderground
curl -sS http://127.0.0.1:4100/v1/meta | grep -o '"admins":[0-9]*'
```

Take the new public half from wherever you generated it and keep the private
half off the VPS. The lost private half is not needed for recovery.

## 4. Backup

The switch is backed up nightly on the host and pulled to the laptop. Both
halves are installed and enabled — a timer that only writes to the same disk is
not yet a backup.

| Piece | Where |
| --- | --- |
| Backup script | `/usr/local/sbin/junderground-backup.sh`, root, mode `0700` |
| Backup unit | `/etc/systemd/system/junderground-backup.service` (`Type=oneshot`) |
| Backup timer | `/etc/systemd/system/junderground-backup.timer`, `OnCalendar=*-*-* 03:20:00 UTC`, `Persistent=true`, `RandomizedDelaySec=5m` |
| Local stage | `/var/backups/junderground/`, `root:debian`, mode `0750` |
| Archive | `junderground-<YYYYMMDDTHHMMSSZ>.tar.gz`, `root:debian`, mode `0640` |
| Sidecar | the same name plus `.sha256`, `root:debian`, mode `0640` |
| Retention | tarballs and sidecars older than 14 days are deleted each run |
| Laptop pull | `~/.config/systemd/user/junderground-backup-pull.{service,timer}` on `vivotop` |
| Laptop copy | `/home/jawn/jawnos-backups/junderground/`, mode `0700` |

The script runs as root (it stops the unit and writes `/var/backups`) with
`umask 027`. Each run:

1. takes a UTC timestamp from `date -u +%Y%m%dT%H%M%SZ`, naming
   `/var/backups/junderground/junderground-<ts>.tar.gz`;
2. installs `trap 'systemctl start junderground || true' EXIT` first, so the
   switch comes back even if `tar` fails;
3. stops `junderground` and waits for `systemctl is-active` to report
   `inactive`, so DETS closes cleanly (each table closes on termination;
   `auto_save` is 2 s);
4. runs `tar -C /var/lib -czf` over the directory, `server.key` included;
5. writes the `.sha256` sidecar over the tarball's basename, so `sha256sum -c`
   works on the laptop and not only here;
6. starts the unit again, waits for `active`, then fails loudly unless
   `curl -fsS http://127.0.0.1:4100/v1/meta` answers;
7. deletes tarballs and sidecars older than 14 days.

Nothing prints the key: the journal holds the unit's start/finish lines and the
archive path, not the archive contents. The directory stays `0750` and the files
`0640` because the tarball carries `server.key`; membership in the `debian`
group is what lets the laptop read them over SSH.

The outage is the stop/start of that one run — about two seconds at 03:20 UTC,
not a nightly window. Run a backup by hand with:

```
sudo systemctl start junderground-backup.service
sudo journalctl -u junderground-backup.service -n 20 --no-pager
```

The laptop pulls the directory at **04:20** local
(`OnCalendar=*-*-* 04:20:00`, `Persistent=true`, `RandomizedDelaySec=10m`):

```
/usr/bin/rsync -a --delete -e "ssh -p 8022 -o BatchMode=yes -o ConnectTimeout=10" \
  debian@148.113.181.210:/var/backups/junderground/ \
  /home/jawn/jawnos-backups/junderground/
```

It logs in as `debian`, so that account needs both the laptop's SSH key
authorized and the host key trusted. The stale `[148.113.181.210]:8022` line in
`~/.ssh/known_hosts` (left from before the VPS reinstall) was replaced on
**2026-11-13**. The presented key was verified three ways before the swap —
`ssh-keyscan -p 8022` from the laptop and from the dev box, and
`/etc/ssh/ssh_host_ed25519_key.pub` read on the VPS — all
`SHA256:oIywYbMQvGavI/X4BLpC6GMJuFdmugMaEc6xpUdx7k4`. Strict host checking is
never disabled; the previous file is `~/.ssh/known_hosts.bak-20261113`.

Verify the pulled copy on the laptop:

```
cd /home/jawn/jawnos-backups/junderground
ls -l
sha256sum -c junderground-<ts>.tar.gz.sha256
```

### Restore drill

The archive is restore-tested without touching the live directory: extract the
newest tarball into `/tmp/jg-restore-test` while the service keeps running,
confirm `junderground/` holds the six `*.dets` and `server.key` (89 bytes, mode
`0600`), then remove the temporary directory. The 2026-11-13 drill did exactly
that against `junderground-20261113T165612Z.tar.gz` and passed. That proves the
archive is complete and readable; it is not a restore — a real one still stops
the service (§5).

## 5. Restore

Restore only this switch's archive, and only with the service stopped. Keep the
old directory until the new one verifies:

```
sudo systemctl stop junderground
sudo mv /var/lib/junderground /var/lib/junderground.before-restore-$(date +%F-%H%M)
sudo tar -C /var/lib -xzf /var/backups/junderground/<archive>.tar.gz
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
| coturn | `systemctl is-active coturn` | `active` |
| TURN listeners | `sudo ss -lunp \| grep 3478`; `sudo ss -ltnp \| grep 3478` | `turnserver` on `3478/udp` and `3478/tcp` |
| TURN advertised | `curl -sS https://thejunderground.com/v1/meta` | `turn.urls` has the `transport=udp` and `transport=tcp` URLs |
| Backup timer | `systemctl list-timers junderground-backup.timer --no-pager` | next run about 03:20 UTC daily |
| Last backup | `sudo systemctl show junderground-backup.service -p Result` | `Result=success` |
| Archives | `sudo ls -l /var/backups/junderground/` | tarball + `.sha256`, `root:debian`, `0640` |
| Pull timer (laptop) | `systemctl --user list-timers junderground-backup-pull.timer` | next run about 04:20 local |
| Pulled copy (laptop) | `cd ~/jawnos-backups/junderground && sha256sum -c *.sha256` | `OK` |

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

### TURN relay check

Mint a probe credential exactly as `Turn.credentials/1` does, then relay a few
packets with coturn's client. The secret is read from the `0600` env file and
never printed:

```
ssh cloud 'sudo cat /etc/junderground/turn.env' | python3 -c '
import sys,time,hmac,hashlib,base64,subprocess
secret=sys.stdin.readline().strip().split("=",1)[1]
u=str(int(time.time())+600)+":probe"
w=base64.b64encode(hmac.new(secret.encode(),u.encode(),hashlib.sha1).digest()).decode()
for flags in ([],["-t"]):
    print(subprocess.run(["turnutils_uclient","-y","-m","2","-n","4",
      "-u",u,"-w",w,"-p","3478"]+flags+["thejunderground.com"],
      capture_output=True,text=True).stdout)
'
```

Expected: exit 0, `tot_send_msgs=16`, `tot_recv_msgs=16`, and `Total lost
packets 0`. Verified 2026-11-13 from the dev box, outside the VPS, for both UDP
and TCP.

## 7. Known gaps and cautions

- **Media is live: coturn plus LiveKit.** coturn 4.6.1-2 relays on
  `3478/udp` and `3478/tcp` with relay ports `49160–49260/udp`, and
  `/v1/meta.turn.urls` lists both URLs (see §1). A real relay was proved with
  `turnutils_uclient`: 16/16 messages both UDP and TCP, 0 lost. LiveKit 1.13.11
  serves the SFU side (see §1 and the Media (SFU) section): `/v1/meta.sfu` is
  available, the health-down/up transition was proved, and the Twirp smoke
  passed. The mesh path still does not enforce a room's `max` (only the SFU
  route does); that is an upstream follow-up, not a deployment gap. Bandit
  1.14.0 in the switch's `mix deps` carries EEF-CVE-2026-116078 (HTTP/2 DATA
  amplification); bump it on the next upstream change.
- **The off-box copy is one laptop.** See §4. The VPS keeps 14 days of
  tarballs and `vivotop` pulls them nightly, but that laptop is the only copy
  off the host: there is no second site or object store. The pull is an
  `rsync --delete`, so it mirrors the VPS's retention — once an archive ages out
  on the VPS, the next pull removes the laptop's copy too, and a restore needs a
  tarball younger than 14 days. `Persistent=true` catches a missed 04:20 on the
  next boot, but a laptop lost or offline past the window is a real gap. Add a
  second destination before treating the data as durable.
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
- **Secrets.** `server.key` is the switch's signing identity. The admin key in
  the drop-in is a public key; its private half is a dedicated Ed25519 key that
  lives only on the laptop at `~/.junderground/admin.key` (`0600`) and stays off
  this host. The house crest is not an admin key. Never paste `server.key`, an
  admin private key, TURN/SFU secrets, or a login ticket into a record, a
  commit, the journal, or this doc. A public admin key is not a secret, but it
  is not reproduced here either.
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
the administrator's screen contract, and `docs/SFU.md` for the media design
(implemented in v0.1.15). The
signing message itself is `lib/junderground/auth.ex` (`Auth.message/4`), and the
admin verifier is `lib/junderground/admin.ex`.

The house side is `perl/junderground.pl` (requests signed with the house crest;
the browser never holds the key), loaded by `lib/JawnOS/Manager.pm`. Its settings
are `app=junderground` with `url` and `handle`; Chat → Rooms is the screen.

---

Verified 2026-11-13 on `cloud`: `systemctl cat junderground`, `ss -lntp`,
`/v1/meta`, `/v1/houses/jawn_s_homebase`, `ls -l /var/lib/junderground`,
`/etc/caddy/Caddyfile`, `openssl x509`, `caddy validate`, `mix help release`.
The backup install was verified the same day: `junderground-backup.service`
(`Result=success`), `junderground-backup.timer` enabled, a
1,607-byte `junderground-20261113T165612Z.tar.gz` whose sidecar passed
`sha256sum -c` on both hosts, and a `/tmp/jg-restore-test` drill that found all
six DETS tables and the 89-byte `server.key`.

coturn 4.6.1-2 was installed and verified the same day: `3478/udp` and
`3478/tcp` listening, relay `49160–49260/udp`, `/v1/meta.turn.urls` populated,
and `turnutils_uclient` relayed 16/16 messages on both transports with 0 lost
from the dev box.

LiveKit 1.13.11 and the SFU adapter (junderground v0.1.15) were verified the
same day: `/v1/meta.sfu` available with `"sfu"` in `features`; `livekit` and
`junderground` active with no `Sfu.Health`/`Reconciler` termination lines;
LiveKit stopped for 100 s → `available: false` and the feature gone, restarted
→ back within ~35 s; the Twirp `ListRooms`/`ListParticipants` smoke passed with
no rooms left; `7880` times out externally while `7881` and the UDP range are
open; `mix test` upstream at 116 tests, 0 failures.
