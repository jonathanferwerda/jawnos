# JawnOS in Docker

The image runs the same tree `./jawn` runs on a bare machine. It is a server
image: the Linux desktop app (`desktop/`), firmware and the machine's SSH
daemon are not inside it.

## Quick start

```sh
cp .env.example .env      # optional; every value has a default
docker compose up -d --build
docker compose logs -f    # watch the first boot
```

The first build compiles the CPAN modules the tree loads, so allow several
minutes. Later builds reuse the cached module layer.

## Proxmox / LXC

Docker needs a privileged LXC, or an unprivileged one with
`features: nesting=1,keyctl=1` and cgroup delegation in
`/etc/pve/lxc/<id>.conf`. This image was exercised inside the privileged `dev`
LXC; a default unprivileged `house` LXC needs those settings (or a VM). The
container itself still runs as the unprivileged `jawn` user.

On the first boot `docker/entrypoint.sh` calls
`perl scripts/jawnos_setup.pl --seed`, which writes `config.json` and builds
`database/jawnos.db` from the factory seed without a browser. The unlock code is
printed **once**. Save it: it is the only key to the database.

Then open `https://127.0.0.1:45545/` and enter the code at the gate. The
certificate is Mojolicious' built-in self-signed one, so the browser warns once.

The box office (login tickets for the web view and the Android app) is on
`https://127.0.0.1:3000/box_office/<uuid>?s=<token>`; the panel itself is on
`working_port` (45545 by default).

## What the volumes hold

| Volume | Mount | Contents |
| --- | --- | --- |
| `jawnos-database` | `/app/database` | the live database, WAL, `backups/`, and the factory seed |
| `jawnos-home` | `/home/jawn` | `config.json`, the signatorial, `manager.log`, `~/.president` |
| `jawnos-server` | `/app/server` | TLS material (`fullchain.pem`, `privkey.pem`) and the server inventory |
| `jawnos-voices` | `/app/voices` | Piper voice models |
| `jawnos-releases` | `/app/releases` | staged Android APKs |

`config.json` lives in the home volume; the entry point keeps `/app/config.json`
as a symlink to it, so rebuilding the image does not change the machine's
identity. To supply your own config, bind-mount a file at `/app/config.json` and
the entry point leaves it alone.

A named volume is filled from the image the first time it is used, so
`database/initial.enc` and `schema.sql` are available for the seed. **Do not**
bind-mount a copy of another machine's `database/` onto the container: the
database is per device. Restore only onto the machine that owns it. If you
bind-mount a database the host app also uses, stop the host tree first — SQLite
WAL must have one writer.

## Environment

Copy `.env.example` to `.env`; Compose reads it automatically. The values that
matter:

- `JAWNOS_NAME` (default `JawnOS`) — the house's display name.
- `JAWNOS_EMAIL` — optional; the setup's placeholder address is used when
  unset. It is an identity label, not an outbound mail account.
- `JAWNOS_DOMAIN` (default `127.0.0.1`) — the host used in generated links.
  Keep `127.0.0.1` when the browser is on the Docker host; use the LAN or
  tailnet name for a remote host.
- `JAWNOS_DEVICE` (default `server`) — `server` starts no watch/teletype servers
  and uses four prefork workers. `computer` and `mobile` are also accepted.
- `JAWNOS_UNLOCK_CODE` — optional 4–12 digit code. Without it the first boot
  generates one.
- `JAWNOS_SAVE_UNLOCK_CODE=1` — also write a generated code to
  `/home/jawn/unlock-code.txt` (mode 0600). Off by default: the app intends the
  code to exist only in your head.
- `JAWNOS_LOCKER_PORT`, `JAWNOS_WORKING_PORT`, `JAWNOS_WS_PORT` — published and
  listened-on ports. Keep `JAWNOS_WS_PORT` at `JAWNOS_WORKING_PORT + 1`.
- `JAWNOS_BIND_ADDR` (default `0.0.0.0`) — the host address the published ports
  bind to. Use `127.0.0.1` for a test instance that must not be reachable from
  the LAN.
- `JAWNOS_IMAGE` (default `jawnos:local`) — the image tag Compose builds and
  runs. The nightly smoke uses `jawnos:nightly` so it cannot overwrite a
  hand-built image.
- `JAWNOS_FOLDERS` — colon-separated container paths replacing the seeded
  folder list.
- `JAWNOS_MAIN_WORKERS` — override the server's four resting workers on a small
  box.
- `TZ` — the container timezone; the app's schedules use local time.

`open_browser` is forced to `no`: there is no display in the container.

## Host media

Mount a host directory where the folder list expects it, then point
`JAWNOS_FOLDERS` at the container path:

```yaml
    volumes:
      - /srv/media/Music:/home/jawn/Music:ro
    environment:
      JAWNOS_FOLDERS: /home/jawn/Music
```

The container runs as uid/gid 1000 (`jawn`), so the host files must be readable
by that uid. Mount media read-only unless you deliberately want the app to
manage it.

## Operations

```sh
# Restart the tree the way the app expects (runs the change guard).
docker compose exec jawnos perl scripts/restart.pl --reason "docker: config change"

# Status and the newest manager log lines.
docker compose exec jawnos perl scripts/restart.pl --status
docker compose exec jawnos tail -n 100 /home/jawn/manager.log

# The unlock code, if you opted into saving it.
docker compose exec jawnos cat /home/jawn/unlock-code.txt

# A real certificate (Let's Encrypt or your own) goes into the server volume.
# docker compose cp writes as root, so hand the files to the app user.
docker compose cp fullchain.pem jawnos:/app/server/fullchain.pem
docker compose cp privkey.pem   jawnos:/app/server/privkey.pem
docker compose exec -u root jawnos chown jawn:jawn /app/server/fullchain.pem /app/server/privkey.pem
docker compose exec -u root jawnos chmod 600 /app/server/fullchain.pem /app/server/privkey.pem
docker compose restart jawnos
```

A Docker restart is the same as stopping the tree and starting it again. Use
`docker compose restart jawnos` for the container, or the `restart.pl` command
above when you want the app's own verdict.

## Nightly smoke (testing only)

`qa/docker/smoke.sh` is the nightly image test. It never deploys the app and
never touches the live tree, database or ports:

- it extracts the **committed tree** (`git archive HEAD`) into
  `$QA_ROOT/docker/<stamp>/tree`, builds `jawnos:nightly`, and runs it under
  the `jawnos-nightly` Compose project on free ports bound to `127.0.0.1` only;
- it checks first boot, the unlock code, the database, the manager/locker/
  websocket ports, the threaded Perl, pinned Mojolicious 9.39 and `ifconfig`;
- it restarts the container and verifies the volumes are reused, then asks the
  app's own `scripts/restart.pl` to restart its tree;
- it removes its volumes and tree, and stops Docker again if it started it.

It is driven by `qa/systemd/jawnos-qa-docker.timer` at **04:30**, on the machine
that carries Docker and passwordless sudo - like the weekly build unit, not the
machine chosen for the route suite. A missing Docker is a skip, not a pass.
Install it from `qa/README.md`; logs land in `$QA_ROOT/docker/<stamp>/smoke.log`.

## What is missing, and why

- **The desktop app, WebKitGTK, GStreamer and the VA-API drivers** are not in
  the image. Use the native app on the machine with the display.
- **Firmware builds and APK releases** are not in the image (`jp/`, `jt/`,
  `jw/`, `desktop/` and PlatformIO/Gradle are excluded). Stage those on a build
  machine; the app can still serve a `releases/` volume if you fill one.
- **Bluetooth, the BLE bridge, scanners and serial devices** need host access
  and hardware; this image does not pass them through.
- **SSH into the container** is not installed or started. Use
  `docker compose exec`.
- **The alarm server** listens on `working_port + 5` (45550 by default). Publish
  that port too if a phone pairs with this house.
- **Optional extras** (weasyprint PDF rendering, Ollama, whisper.cpp, Piper
  voices) are not in the image. Add them in a derived image or through a volume
  if you need them; the app uses its documented fallbacks until then.
- **One benign warning in the logs.** `Manager::encode_json` prints a
  `Prototype mismatch` warning from `perl/junderground.pl` and `perl/Music.pl`.
  It comes from the app's own imports under Perl 5.40; it does not stop the
  servers.
- **Systemd timers** are host concerns. Backups, records audits and the help
  index audit still run from the app's own loops, but a host timer calling
  `docker compose exec ...` is the way to add a scheduled job.

## Reset

`docker compose down` stops the container and keeps every volume.
`docker compose down -v` **deletes the database, the signatorial and the unlock
code**. Take a sealed copy out of `database/backups/` first if the data
matters.
