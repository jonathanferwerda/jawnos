# App sandbox

Status: design, 2026-11-03. Companion to `docs/app-lifecycle.md`.

Can a running app be contained in the Android app, the desktop app, and the installed JawnOS OS?

**Yes — with one rule: a sandboxed app must be a separate process.** In-process `$host` calls are
not a boundary; a sandbox needs a process the kernel can contain and the host can kill. The SDK
already has the shape for it: `Host::Local` in-process for core apps, and a `Host`-over-RPC for
everything else.

The primitives are not speculative — the QA harness already fences a whole JawnOS instance with
them:

- desktop/OS: `qa/lib/Harness.pm:45-52` runs
  `unshare --user --map-root-user --mount --pid --fork --mount-proc --net -- …`, probes it first,
  and refuses (or takes `--no-namespace`) when it is unavailable;
- Android: `qa/android/run.sh:185-201` uses the **same** fence on the device and refuses to boot a
  QA instance "unfenced" if `unshare` is missing. That is the proof that unprivileged user
  namespaces are the right Android answer when the kernel allows them.

## The process model

```
host (JawnOS) ── HTTP proxy ──▶ app process (Mojolicious, Unix socket)
      │                              │
      └── host API socket ◀──────────┘  JSON-line RPC, token, capability-checked
```

- Each app is its own Mojolicious app listening on `$RUNTIME/socket`. The host proxies
  `/app/<name>/*` (or a dedicated port) to that socket; embedded mode mounts the same app in-process
  instead, which is why the SDK contract must not change between the two.
- The **host API** is a second Unix socket (`host.sock`) speaking the same method set as
  `JawnOS::Host`, authenticated with a per-app token and scoped to the app's manifest. The app never
  gets a database handle, a file root, `$HOME`, or the house key.
- The app sees exactly three mounts: a read-only runtime (Perl + its dist), a writable state dir
  (its own SQLite database, cache, assets), and a tmpfs `/tmp`. Nothing else.
- Default network is **none** (a private netns with loopback down). An app that declares `network`
  gets a loopback proxy with an allowlist, not the host's namespace.
- The supervisor (`JawnOS::Sandbox`) chooses a backend, builds the fence, starts the process,
  accounts for it in a cgroup where available, restarts it on crash, and reports the **assurance
  level** it actually achieved.

## Backends and assurance

| Backend | What it is | Assurance |
|---|---|---|
| `inproc` | mounted in the host process | none — core apps only |
| `process` | separate process, same user | crash isolation only |
| `userns` | `unshare --user --map-root-user --mount --pid --ipc --uts --net`, bind mounts, `chroot`/`pivot_root` | filesystem + PID + network + IPC isolation |
| `bwrap` | `bubblewrap` (userns + seccomp + binds) when installed | as `userns`, plus seccomp |
| `systemd` | per-app unit with `DynamicUser=`, sandboxing directives, cgroups | strongest local level; accounting and lifecycle |
| `nspawn` | `systemd-nspawn --private-users=pick` | full container, still the host kernel |
| `vm` | microVM (qemu/KVM) | the only level that survives a kernel bug |
| `proot` | ptrace emulation, no namespaces | **compatibility, not containment** — never label it secure |

The UI must show the achieved level, not the requested one. A store app that requires containment is
refused when the host can only offer `process` or `proot`.

## Platform matrix

| Platform | Best available | Fallback | Notes |
|---|---|---|---|
| **Installed OS (mkosi/Arch, systemd)** | `systemd` per-app unit (`DynamicUser`, `StateDirectory`, `ProtectSystem=strict`, `PrivateNetwork`, `SystemCallFilter`, `MemoryMax`) | `userns` / `bwrap` / `nspawn` | The host owns the box; this is the strongest and simplest to operate |
| **Desktop app (Linux, user install)** | `userns` (unshare, already required by QA) or `bwrap` if present | `process` | Per-app units only in `--headless` (system service); user units cannot use `DynamicUser` |
| **Android app (no root)** | `userns` fence (the QA fence) + private mount/PID/net + `proot` only as a path shim | `process` (crash isolation), then refuse high-risk apps | chroot alone needs root; `proot` is not a boundary; every sandboxed app shares the Android UID |

## Android, honestly

- **No root.** `chroot` is unavailable directly. Inside `unshare --user --map-root-user`, the mapped
  root may `pivot_root`/`chroot`, which is why the QA fence works.
- **`proot` is not a security boundary.** It emulates `chroot` with `ptrace` on the same UID and the
  same kernel; a determined app can step out. Use it for compatibility on kernels that block
  unprivileged userns, and say so.
- **Kernel probe.** At boot, run the QA probe (`unshare --user --map-root-user -- /bin/true`). If it
  fails, the sandbox level drops to `process`; `agent`/store apps that require containment are
  refused rather than silently weakened.
- **Shared UID.** Every sandboxed app is the same Android UID as JawnOS. There is no per-app UID to
  fall back on; the mount namespace, the private netns, the capability limits and the absence of
  secrets are the boundary.
- **Seccomp.** Android already applies a zygote/Termux filter; adding `no_new_privs` and a tighter
  filter is best-effort, not guaranteed. Do not claim seccomp isolation on Android unless the
  probe proves it.
- **Isolated processes.** Android's `isolatedProcess` is for Java components, not arbitrary Linux
  processes; it is not the answer here.
- **The Android app itself** is already sandboxed from other Android apps. That protects the house
  from the rest of the phone; it does not protect the house from an app the house runs.
- **Runtime diet.** The JawnOS Android runtime is a Termux prefix with no package manager. Shipping
  `unshare` (util-linux) in it is a prerequisite for this backend; without it the Android level is
  `process`.

## Desktop, honestly

- `desktop/install.sh` installs **user** units by default. `ProtectSystem`, `PrivateTmp`,
  `NoNewPrivileges`, `MemoryMax`, `RestrictAddressFamilies` work there; `DynamicUser` does not.
- `--headless` installs a **system** service, which can use a per-app unit template
  (`jawnos-app@.service`) with `DynamicUser` and `StateDirectory`.
- `unshare` is already a QA requirement (`util-linux`); it is the baseline fence. `bwrap` is
  preferred when installed (seccomp + cleaner binds) but is not a dependency.
- The WebKitGTK sandbox protects the browser view, not the Perl tree; it is not an app sandbox.
- Flatpak is optional packaging. The app inside Flatpak is still one sandbox for the whole house;
  per-app isolation is still needed.

## Installed OS, honestly

The mkosi Arch image is the easiest place to do this properly:

- a `jawnos-app@.service` template with `DynamicUser=yes`,
  `StateDirectory=jawnos-apps/%i`, `RuntimeDirectory=jawnos-app-%i`,
  `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `PrivateDevices=yes`,
  `PrivateNetwork=yes`, `RestrictAddressFamilies=AF_UNIX`, `NoNewPrivileges=yes`,
  `CapabilityBoundingSet=`, `SystemCallFilter=@system-service`,
  `SystemCallArchitectures=native`, `MemoryMax=`, `CPUQuota=`, `TasksMax=`;
- the host proxy talks to `/run/jawnos-app-%i/app.sock`; the host API is a second socket;
- `IPAddressDeny=any` plus `IPAddressAllow=localhost` when an app is granted a network proxy;
- `systemd-nspawn` (or a microVM) for the `untrusted` tier, when the kernel-bug threat matters.

This gives cgroup accounting, automatic restart, state directories and a clean uninstall — the
systemd directives are the same contract the sandbox descriptor describes, just expressed once.

## Data, backup and sync

- The app's SQLite file lives in its state dir. The **host still reads it** for backup and sync:
  the fence hides the host from the app, not the app from the host. Snapshot under the export lock;
  WAL keeps the read consistent.
- When the database is encrypted, it lives behind a **broker** outside the fence and the app never
  sees the path or the key (`docs/app-database-encryption.md`). The host still snapshots the file;
  the app streams queries and rows over directional Unix sockets.
- The app must not hold an exclusive lock across a request; use WAL and short transactions.
- The host API is the only way an app writes core tables; the database registry
  (`docs/app-databases.md`) is enforced at that socket, not by file permissions.
- Uninstalling stops the unit/process, detaches the schema, then keeps or purges the state dir.

## Capabilities become policy

The manifest's `host`, `network`, `shell` and `fs` declarations are translated into the fence by the
supervisor:

| Declared | Fence |
|---|---|
| (nothing) | no network, no devices, read-only runtime, own state dir |
| `network` | private netns + loopback proxy with an allowlist, or a systemd `IPAddressAllow` |
| `fs => ['/x']` | one extra bind mount, read-only unless `rw` |
| `shell` | a shell inside the sandbox only; never the host |
| `crypto` | host API calls only; the house key never enters the sandbox |

A capability the manifest does not declare is not a permission the app can obtain at runtime — the
fence has no path for it.

## Phases

| Phase | Work | Acceptance |
|---|---|---|
| SB0 | Split apps into their own process; host API over a Unix socket; HTTP proxy; no security claim | Gallery runs sandboxed at `process`; the host survives a crash; embedded mode still works |
| SB1 | `userns` backend (`unshare`) on desktop and Android; three mounts; no network; assurance reported | An app cannot read the core DB/key or reach the network; a fork bomb hits `TasksMax` |
| SB2 | `systemd` backend for the installed OS and `--headless` desktop; per-app unit template | `systemctl` shows the app's cgroup; restart, stop and uninstall are clean |
| SB3 | Android: ship `unshare` in the runtime, probe userns, honest downgrade, refuse high-risk at `process`/`proot` | A userns-blocked device reports `process` and refuses a store app that needs containment |
| SB4 | `bwrap` when present; Landlock/seccomp best effort; `nspawn`/microVM for `untrusted` | The assurance level matches the probe, not the wish |
| SB5 | Store policy: minimum assurance per trust tier | An `agent-reviewed` app runs at `userns`; a `human-reviewed` app may use `systemd`/`vm` |

## Tests

- filesystem: `open` of the core DB, the house key and `$HOME` fails; the app's own state dir works;
- network: `connect` to a LAN and to the internet fails; loopback proxy works when granted;
- process: a crash restarts; a fork bomb hits `TasksMax`; memory hits `MemoryMax`; the host stays up;
- RPC: a token for app A cannot call app B's methods; a core-table write is refused;
- assurance: a device/host with no userns reports `process` and refuses what needs more;
- backup/sync: the host snapshots the sandboxed app's DB and syncs its rows;
- uninstall: stop, detach, purge/keep, no orphan process or socket.

## Risks

1. **userns availability is not universal.** Android kernels, `kernel.unprivileged_userns_clone` and
   distro policy vary. Probe at boot and degrade honestly; do not ship a silent `proot` that looks
   like isolation.
2. **`proot` is not containment.** It is a compatibility layer on kernels that block the real fence.
3. **Shared Android UID.** Every app is the same Linux user; namespaces are the only boundary. A
   namespace escape is a house-data read.
4. **Kernel attack surface.** Only a VM removes it; everything else is a hardening exercise.
5. **Performance.** `proot` is slow; a separate process per app adds cold-start and memory. Measure
   the appointment write path and the Gallery request path before and after.
6. **User units are weaker than system units.** Do not document `DynamicUser` for a desktop user
   install; the desktop level is `userns` unless `--headless`.
7. **The WebView is not the sandbox.** The browser's process isolation does not cover the Perl app.
8. **Data access.** The host must read the app's DB for backup/sync; that is a deliberate exception
   to the fence and must be documented in the manifest.
9. **Honest labels.** The UI must show `inproc`/`process`/`userns`/`systemd`/`vm` as achieved, never
   a generic "sandboxed" badge.
