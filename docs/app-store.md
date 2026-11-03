# The decentralized app store

Status: design, 2026-11-03. Companion to `docs/app-lifecycle.md` and `docs/app-sdk.md`.

The store is **junderground's**, not a new service: a signed record chain per publisher, content-
addressed bundles, and local trust policy. The switch (`thejunderground.com`, the Elixir app) already
does the hard part — house identity, signed requests, discovery, rooms and relationship grading. The
store adds an app record kind and a blob rail; it does not add a central gatekeeper.

## Principles

1. **Publisher-signed, content-addressed.** A bundle is named by its SHA-256, and the release record
   that names it is signed by the publisher's Ed25519 crest key. A hash without a signature is an
   anonymous file; a signature without a hash is a promise.
2. **Hash-chained history.** Releases, revocations and vouches form a per-publisher chain (`seq`,
   `prev`, `sig`), exactly like `/v1/houses` does today. A silent rewrite is visible.
3. **No central approval.** The switch stores records and optionally blobs. Each house decides what
   it will install, from its own policy and its own relationship map.
4. **Offline-first.** Everything verified and installed is cached locally. A house with no route to
   the switch can still install from a peer or a file.
5. **The agent reviews before it runs.** A store bundle is `quarantined` until the local reviewer
   agent and the checks in `docs/app-lifecycle.md` approve it.
6. **The store is not CPAN.** CPAN is the library channel; the store is the app channel. An app may
   be both, but the store carries the manifest, capabilities and review evidence CPAN does not.

## Identity and signing

Reuse `perl/junderground.pl` unchanged:

- `jg_call($c, $method, $path, $body, $auth)` signs
  `METHOD \n PATH?QUERY \n sha256hex(body) \n timestamp \n nonce` with the house crest key and sends
  `x-jg-handle`, `x-jg-timestamp`, `x-jg-nonce`, `x-jg-signature`.
- `jg_register` already posts a hash-chained record (`format`, `version`, `kind`, `handle`, `pubkey`,
  `seq`, `prev`, `sig`) at `/v1/houses`. A release record is the same shape with `kind: release`.
- The publisher is a **crest**, not an account: the same key that signs peer requests and the
  junderground house record signs the app. Losing it means revoking the chain, not resetting a
  password.

## The bundle

```
app.tar.gz                         # content address = sha256 of this file
  manifest.json                    # name, version, host_api, requires, provides,
                                   # tables, settings, permissions, capabilities
  lib/  share/  t/                 # the app, its assets and its tests
  REVIEW.jsonl                     # optional: review evidence (checks, model, diff hash)
publisher.sig                      # Ed25519 over sha256(bundle) + canonical manifest
```

The signed record carries the hash, size, mirror URLs, `host_api`, capability summary and the
dependency set. The tarball is never trusted for its own identity.

## Protocol (additions to junderground)

| Endpoint | Auth | Purpose |
|---|---|---|
| `POST /v1/apps` | signed | publish a `release`, `revoke` or `vouch` record into the publisher's chain |
| `GET /v1/apps/:publisher/:name` | none | the publisher's chain head and recent releases |
| `GET /v1/apps/:publisher/:name/:version` | none | one release record (manifest, hash, mirrors) |
| `GET /v1/apps?q=…&capability=…` | none | catalog search; capability filter is a manifest field |
| `GET /v1/blobs/:sha256` | none | the bundle, or a 302 to a mirror/publisher |
| `POST /v1/apps/:publisher/:name/revoke` | signed | revoke a version or the whole app |
| `POST /v1/apps/:publisher/:name/:version/vouch` | signed | “this house runs this version” |

Rooms stay what they are: a **storefront** is a room that pins a set of `(publisher, name, version)`
records. Presence and `jg_grade` give the shelf a local audience without the switch learning the
relationship map.

## Discovery and trust

No global score. The house answers “should I install this?” from:

- **Publisher**: the crest/handle/pubkey in the record, checked against the local People map
  (`friend` / `stranger` / `enemy` via `jg_grade`). An enemy's app is refused; a friend's gets a
  lower bar, never a free pass.
- **Vouches**: signed “I run this” records from houses the person knows. The store shows them, the
  policy weighs them.
- **Agent review**: the local reviewer's evidence and the deterministic checks
  (`docs/app-lifecycle.md`). This is the only gate that always runs.
- **Capabilities**: an app that asks for `shell`/`network` needs `human-reviewed`; an app that asks
  for nothing beyond its schema is eligible for `agent-reviewed`.
- **Reproducibility**: an optional `SOURCE.json` (repo + commit) lets a house rebuild and compare
  hashes; a bundle without it is not disqualified, just marked.

A default policy might read: install if the local reviewer passed **and** the publisher is a friend
**or** two friends vouched **and** the requested capabilities are in the house's allowlist. That
policy is a setting, not a protocol rule.

## Install

```
search / dial → release record + manifest
  → fetch bundle by sha256 (switch → mirror → publisher → peer over the tunnel)
  → verify sha256, signature, seq/prev chain, host_api
  → quarantine
  → independent reviewer agent + deterministic checks
  → canary install (trust=agent-reviewed, own schema)
  → health sample → promote or quarantine/roll back
```

Nothing is unpacked into the tree before the hash verifies. Nothing runs before the review passes.
The install row records `publisher`, `pubkey`, `version`, `sha256`, `seq` and the review evidence.

## Publish

`jawnos-app publish --to junderground` builds the bundle, runs the SDK tests, signs it with the crest
key, uploads the blob (or announces mirrors) and posts a `release` record. The agent may prepare a
publish, but a person approves the first release under a handle; later versions can be agent-published
under a policy the house sets. A `revoke` is a signed record too: no deletion, just a tombstone the
chain shows.

## Decentralization details

- The switch holds **records** (small) and may hold **blobs**; a publisher may host its own, and any
  house may mirror. The content hash makes every mirror equivalent.
- Blob fetch rides the existing tunnel/mesh when the switch is unreachable; a LAN peer is preferred
  over the CDN.
- The catalog is readable without an account. Publishing and vouching are signed and therefore
  attributable.
- A house keeps an **offline cache**: every installed bundle and its record, so a reinstall or a
  rollback needs no network.

## Versioning, downgrade and revocation

- `seq` is monotonic per publisher/app; a lower `seq` is a rollback attempt unless the operator pins
  it deliberately.
- Installs are **pinned by hash**: an app does not silently follow the latest release. `upgrade`
  moves the pin after review.
- `revoke` is checked before every install/upgrade and cached with a short TTL; an offline house
  warns rather than pretending the world has not moved.
- A compromised crest is rotated by publishing a new chain with a signed handover; the old chain is
  marked superseded, not erased.

## Security

| Threat | Answer |
|---|---|
| Malicious update | per-version review, pinned hash, canary, rollback |
| Downgrade / replay | monotonic `seq`, `prev` chain, pinned versions |
| Blob poisoning | SHA-256 is the address; the signature covers the hash |
| Typosquatting | show publisher handle **and** pubkey; friend/vouch graph; warn on a handle whose pubkey changed |
| Dependency confusion | lockfile with hashes, dependency-diff review, allowlist, vendored deps where possible |
| Spam | local blocklist (`jg_grade`), room moderation, switch rate limits |
| Metadata leak | catalog reads are anonymous; signed records reveal only the publisher handle, which is already public |
| Key compromise | signed revocation, chain rotation, pinning lets a house stay put while it decides |
| Agent review miss | capability limits make most misses inert; canary measures behaviour; `quarantined` is the default |

## Phases

| Phase | Work | Acceptance |
|---|---|---|
| S0 | `jawnos-app pack` / `verify`: bundle format, signature, content address | Pack, corrupt, verify, reject — all offline |
| S1 | Publish and consume release records through junderground (no blob rail) | A second house fetches, verifies and quarantines a release |
| S2 | Blob rail + mirrors + tunnel fetch + offline cache | Install with the switch unreachable, from a LAN peer |
| S3 | Vouches, local policy, revocation, pinning | An enemy's app is refused; a revoked version is warned/refused |
| S4 | Store UI + review integration + canary promotion | Search → review → canary → promote without a shell |
| S5 | v1: the store is the default app channel | A generated app is published, reviewed and installed on another house |

## Risks

1. **Agent review is a filter, not a proof.** The capability model and the canary are the actual
   containment; do not let a passed review widen powers without human sign-off.
2. **Supply chain.** Dependencies move after the review. Pin hashes, review the dependency diff, and
   re-verify at install.
3. **Switch availability.** The store must work from cache and peers; a dead switch is an
   inconvenience, not an outage.
4. **Revocation latency.** An offline house can run a revoked version; it must show that it cannot
   know, not pretend it is current.
5. **Key management.** The crest key is the publisher identity, the peer identity and the store
   identity. Its loss is a house event, not a store event; the recovery path must be rehearsed.
6. **Licensing and provenance.** A bundle without a repo/commit is harder to audit. Mark it, do not
   silently trust it.
7. **Store spam and social pressure.** Distrust is local and explicit; no global score to game.
