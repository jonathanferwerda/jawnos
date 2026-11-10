# Packaging

Two artifacts from one tree:

- a **`.deb`** for Debian/Ubuntu (`packaging/debian/`, built by `packaging/build_deb.sh`)
- an **Arch package** for the AUR, installed with `yay -S jawnos` (`packaging/aur/PKGBUILD`)

Both install the same layout:

| Path | What |
| --- | --- |
| `/usr/share/jawnos` | the code tree, read-only |
| `/var/lib/jawnos` | the store: database, backups, TLS (`server/`), voices, releases, config.json |
| `/usr/bin/jawn` | the launcher (wrapper: sets `JAWNOS_STORE_DIR`, cd's to the tree) |
| `/usr/bin/jawnosctl` | the CLI |
| `/usr/lib/systemd/system/jawnos.service` | the server unit |
| `/etc/jawnos/jawnos.env` | package defaults (the store) |
| `/usr/lib/tmpfiles.d/jawnos.conf` | creates the store with the `jawn` user |

The split is `JAWNOS_STORE_DIR` (`lib/JawnOS/Platform/Paths.pm`). A checkout
defaults to the tree, Docker defaults to `/app`, and these packages set
`/var/lib/jawnos`. `database/initial.enc` and `database/schema.sql` stay in the
read-only tree; the first start builds the database into the store.

## Dependencies: one manifest

`packaging/deps.json` is the only list. For each module it names the Debian
package, the Arch package, or `null` when no distro package exists; `core` and
`provided_by` entries add nothing. `render_deps.pl` derives everything else:

```sh
perl packaging/render_deps.pl --target deb      # the Depends: names
perl packaging/render_deps.pl --target arch     # the depends=() names
perl packaging/render_deps.pl --vendor deb      # CPAN dists to vendor
perl packaging/render_deps.pl --check           # control/PKGBUILD still match
```

**OS packages first.** On Debian trixie every module but two is packaged, and
the versions match the Dockerfile's tested pins (Mojolicious 9.39, Mojo::SQLite
3.009, Minion 10.31, Sereal 5.004, CryptX 0.085, DBD::SQLite 1.76). Only
`Mojo::IOLoop::ReadWriteFork` and `WebService::Ollama` are fetched from CPAN.

On Arch the official repos cover most non-Mojo modules and the AUR covers
Mojolicious and a few others. Six have no package at all (Mojo::SQLite, Minion,
Minion::Backend::SQLite, Mojo::IOLoop::ReadWriteFork, Net::IMAP::Client,
WebService::Ollama), so `prepare()` fetches those with `cpanm --no-deps`. The
fetched modules land in `/usr/share/jawnos/lib/`, which every entry point
already puts on `@INC`; that is why no code change is needed for a packaged
vendor module.

Adding or changing a module:

1. edit `packaging/deps.json`;
2. `perl packaging/render_deps.pl --target deb` / `--target arch` and update the
   `Depends:` line in `packaging/debian/control` and the `depends=()` array in
   `packaging/aur/PKGBUILD`;
3. `perl packaging/render_deps.pl --check` and `t/255-packaging.t`.

The suite runs the same check, so the two manifests cannot drift.

### Verified in clean guests

Tested on two throwaway Proxmox guests on ks5 (Debian 13 cloud image and Arch
cloud image, minimal install, no local Perl beyond the distro packages):

- **Debian:** `build_deb.sh` built `jawnos_<version>-1_all.deb`; `apt install
  --no-install-recommends` resolved the manifest; first start seeded
  `config.json` and the database in `/var/lib/jawnos`, printed one unlock code,
  and served `/manager/health` (`device: server`, working port 45545); restart
  and `jawnosctl status` worked; `apt purge` left the store and removed the
  tree.
- **Arch:** `yay -Bi` resolved the AUR dependencies, `makepkg -sif` built and
  installed; sysusers/tmpfiles created `jawn` and `/var/lib/jawnos`; the service
  served `/manager/health`; `pacman -Rns` removed the tree and left the store.

The clean Arch install found dependencies that the CPAN metadata does not
declare. They are in `deps.json` now because the app dies without them:

- `Mojo::SQLite` needs `SQL::Abstract::Pg` and `URI::db`;
- `Minion` needs `YAML::XS`;
- `Crypt::Simple` needs `Crypt::Blowfish` and `FreezeThaw`.

It also found `President.pl` doing `use Minion` before it put the tree's `lib/`
on `@INC`; that only worked where the distro or a local::lib already had
Minion. The `BEGIN` now precedes every `use`, and `t/255` pins the order.

## Build the `.deb`

```sh
sudo apt install debhelper dpkg-dev cpanminus
sh packaging/build_deb.sh          # artifacts in packaging/out/
```

The script extracts `git archive HEAD`, puts `packaging/debian` in place as
`debian/`, follows `VERSION` in the changelog, fetches the two vendored dists,
and runs `dpkg-buildpackage -us -uc -b`. Then:

```sh
sudo apt install ./packaging/out/jawnos_*.deb
sudo systemctl enable --now jawnos
sudo journalctl -u jawnos -n 40     # the one unlock code
```

It is deliberately **not** enabled on install: the first start seeds the
database and prints the only key to it.

## Publish to the AUR

`yay` is a client; the package lives in the AUR. One-time setup: an AUR
account, an SSH key registered there, then:

```sh
# a release tag, because source= fetches v<version>
git tag -a "v$(cat VERSION)" -m "v$(cat VERSION)"
git push origin "v$(cat VERSION)"

cd packaging/aur
updpkgsums                         # replaces sha256sums=('SKIP')
makepkg --printsrcinfo > .SRCINFO
git clone ssh://aur@aur.archlinux.org/jawnos.git
cp PKGBUILD .SRCINFO jawnos.git/
cd jawnos.git && git add PKGBUILD .SRCINFO && git commit -m "$(cat ../../VERSION)-1" && git push
```

Users then run `yay -S jawnos` (or `paru -S jawnos`). Test locally with
`makepkg -si`; `namcap PKGBUILD jawnos-*.pkg.tar.zst` before pushing.

## Known gaps, deliberately left for the next pass

- **The Qt desktop is not a second binary package yet.** The tree ships
  `desktop/`, and a user can run `/usr/share/jawnos/desktop/install.sh` to put
  the window and BLE bridge in `~/.local`; a `jawnos-desktop` package with the
  PySide6/BlueZ dependencies is the clean split.
- **The input udev rule is not active.** `desktop/udev/99-jawnos-input.rules.in`
  is still the opt-in path; a package should ship a `uaccess` rule rather than
  widen a group by default.
- **No auto-start/auto-enable.** The unit is installed stopped so the unlock
  code is seen once.
- **AUR sums are a placeholder.** `sha256sums=('SKIP')` is for local `makepkg`;
  `updpkgsums` before the AUR push.
- **`debian/copyright` is a starting point.** The sound clips, Piper binaries
  and voice models have their own licences; `docs/THIRD-PARTY.md` is the
  authoritative list and a Debian-proper upload would need each stanza.
- **Lintian will warn** about the bundled JavaScript and missing man pages; the
  overrides cover the man pages only.
