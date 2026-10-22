# Scope — a fresh receive address for every invoice

**Status:** Phase 1 is built (v0.1.1084): a Bitcoin account xpub issues one fresh
address per invoice, and an unpaid invoice's QR is a BIP21 payment request.
The chain read (phase 2) and other chains (phase 3) are **not** built.
**Written:** 2026-10-21.
**Question it answers:** "I thought an invoice made a new address." It does now, for
Bitcoin wallets that carry an account xpub. This is what is shipped and what is
still open, without JawnOS ever holding a key.

## What shipped

- `wallet_xpub` on the wallet account (house-wide, `device = all`), validated on
  save; private keys, seed phrases and testnet keys are refused.
- `crypto_address` (synced) reserves one external-chain address per invoice;
  re-saving or re-opening an invoice returns the same row.
- Derivation is BIP32 public derivation at `/0/index` from the account xpub,
  for `xpub`/`ypub`/`zpub` (P2PKH, P2SH-P2WPKH, P2WPKH) and their testnet forms.
- An unpaid invoice's single QR is `bitcoin:address?amount=…`; the crypto panel's
  QR carries the amount too.
- A wallet without an xpub keeps the one saved address, as before.
- An overpayment is recorded (the invoice closes at zero) and reported, not
  silently clamped; a second payment on a paid invoice is refused.

---

## 1. Why

A wallet today stores **one static address** per account and every invoice shows it
again. That is safe (funds still arrive) but it links every payment to one address,
so anyone who sees one invoice can see the wallet's whole public history. Fresh
addresses are the normal privacy practice, and they are what a hardware wallet's
companion app already does when you press "Receive".

Related gap: the **holding** column is the sum of the transactions recorded in
JawnOS (`subs::crypto_wallets_report()`), not a live chain balance. If a payment is
missed, the panel is quietly wrong. A watch-only chain read fixes that too.

Neither gap requires a private key. An **xpub** (or a descriptor) is public: it can
derive addresses, and cannot spend.

---

## 2. Current shape (so the change stays small)

| Concern | Where it lives now |
|---|---|
| Wallet fields (`crypto_asset`, `crypto_network`, `wallet_address`, `wallet_label`) | `settings` rows; entered in `templates/configure/appointment_list.html.ep` (App tab, crypto wallet card) |
| Wallet list and coin | `subs::crypto_accounts()` in `subroutines.pl` |
| Holding / cost / market | `subs::crypto_wallets_report()` — sums `appointments` of `type = 'transaction'` |
| Address sanity | `subs::crypto_address_valid()`, `subs::crypto_looks_like_secret()` |
| Invoice payment panel | `templates/store/crypto_payment.html.ep`, filled by `public/js/store.js` (`cryptoPayAddress()`) |
| Invoice panel route | `POST /manager/store/crypto_panel` (`Manager.pl`) |
| Payment request + approval | `POST /manager/crypto/payment_request`; stored in `cache` (`context = 'crypto_payment_request'`) |
| QR | `GET /manager/crypto/qr?text=…` → `subs::crest_qr_png()` (qrencode) |
| New tables | `update_database()` in `Manager.pl` (`create table if not exists …`) |
| Sync | every table rides the peer sync unless named in `gb.pl` `$forbidden{tables}` |

**Key constraint:** the Store invoice panel and the wallet account already sync
between machines. A new address table must sync too, or two machines will disagree
about which invoice owns which address.

---

## 3. What "fresh address per invoice" requires

1. A **watch-only key** stored once per wallet: an xpub (or descriptor).
2. **Derivation** of child addresses from it, on this server, with no network.
3. An **allocation** rule so an invoice keeps its address and two invoices never
   get the same one.
4. A **fallback**: wallets without an xpub keep working exactly as they do now.

Then, separately and optionally:

5. A **chain read** (a public explorer) to show what the address actually holds.

Items 1–4 are the feature. Item 5 is a second, independent phase.

---

## 4. Design

### 4.1 What we store

New settings on the wallet account app (same mechanism as `wallet_address`):

| Setting | Meaning |
|---|---|
| `wallet_xpub` | Public extended key. BTC: `xpub`/`ypub`/`zpub`/`tpub`/`upub`/`vpub`. Private prefixes (`xprv`, `yprv`, `zprv`, `tprv`, WIF) are refused. |
| `wallet_derivation` | `bip44` / `bip49` / `bip84` / `bip86` (default `bip84` for BTC). |
| `wallet_next_index` | Next unused child index. |
| `wallet_gap_limit` | Default 20 — the most unissued addresses the wallet's own scan will find. |
| `wallet_explorer` | Optional Esplora base URL (phase 2). Empty = no chain read. |

`wallet_address` stays. When an xpub is present it is the **fallback** if derivation
fails, and the address shown for wallets that never had one.

Validation at entry, in `subs::crypto_wallets_set`-style code:

- reject anything `crypto_looks_like_secret()` flags;
- reject private prefixes and WIF;
- Base58Check / Bech32 checksum check for an xpub, then confirm the version bytes
  map to a known network (mainnet vs testnet);
- refuse a testnet key on a mainnet wallet and vice versa.

### 4.2 Derivation

BTC is the only sensible v1. It is well specified and every hardware wallet agrees:

- **BIP32 public child derivation**: `child = parent_point + IL·G`, where
  `(IL, IR) = HMAC-SHA512(chain_code, parent_pubkey || index)`. Only the public
  key and chain code are needed, so no secret ever touches the machine.
- **Script types**: `bip84` → P2WPKH (`bc1q…`, bech32); `bip86` → P2TR (`bc1p…`,
  bech32m); `bip49` → P2SH-P2WPKH (`3…`); `bip44` → P2PKH (`1…`).
- **Paths**: account xpub at `m/84'/0'/0'` (or the chosen purpose), then
  `/0/index` for receive, `/1/index` for change. We only allocate receive.
- **Library**: `CryptX` is already a dependency (`Crypt::PK::ECC` is imported in
  `subroutines.pl`), but its public API is signing/verification, not raw point
  addition. Decide between:
  - a small pure-Perl secp256k1 + Base58Check + bech32 (slow, ~10 ms/address,
    fine at one address per invoice), or
  - a pinned CPAN module (`Bitcoin::BIP32`, `Bitcoin::Base58`), or
  - a tiny C helper via `FFI::Platypus` linking `libsecp256k1`.
  A pure-Perl path is the easiest to audit and has no new native dependency.
- **Reference check**: BIP32 test vector 1 and the BIP84 vectors
  (`abandon abandon … about`) must produce the published addresses in a test
  before the feature is switched on for a real wallet. Also compare the first five
  derived addresses against the hardware wallet's own "Receive" list; if they do
  not match, the path or script type is wrong and **nothing is enabled**.

Some devices export **SLIP-132** keys (`zpub`, `ypub`). Accept them, and let the
prefix choose the default script type; a mismatch between prefix and
`wallet_derivation` is a warning, not a silent success.

Most devices do **not** export an ETH xpub (Ledger Live does not). So ETH/ERC-20
fresh addresses are **phase 3 at the earliest**, and may never be practical
without a per-device workaround. v1 should say "Bitcoin only" plainly.

### 4.3 Allocation

New synced table (not `cache`, which is machine-local and forbidden from sync):

```sql
create table if not exists crypto_address (
    uuid VARCHAR(255) unique,      -- the allocated row
    server_time VARCHAR(255),      -- sync
    ost VARCHAR(25),
    app VARCHAR(255),              -- wallet account
    asset VARCHAR(25),             -- BTC
    network VARCHAR(25),
    address VARCHAR(255) unique,
    derivation VARCHAR(25),
    addr_index INTEGER,
    path VARCHAR(255),
    invoice_uuid VARCHAR(255),     -- which invoice owns it, '' for a spare
    issued_at VARCHAR(25),
    used_at VARCHAR(25)
);
create index if not exists idx1_crypto_address on crypto_address (app, addr_index);
create index if not exists idx2_crypto_address on crypto_address (invoice_uuid);
```

Rules:

- Allocate **when an invoice is created** (or the first time its crypto panel is
  opened). Pick `addr_index = max(index) + 1` for that wallet; insert; on a unique
  conflict, retry with the next index.
- **Never reuse** a row that names an invoice. Opening the same invoice again
  returns the same address.
- An invoice keeps its address even if the payment is partial.
- The **gap limit** caps *unissued* addresses. If index would exceed
  last-issued + 20, either refuse ("open the wallet's app once to extend its
  address list") or keep a warning in the panel. Do not silently run past 20.
- `addr_index` starts at 0. `path` stores the full string for the record, so a
  future audit can re-derive and compare.
- **Offline split-brain**: two machines that have not synced can both allocate
  index 5 and get the same address for two invoices. That is address reuse, not
  loss. `address unique` prevents a duplicate row, and the next allocation takes
  `max + 1`. Acceptable for v1; note it in the UI if the panel sees a duplicate.

Writes go through a route (the Store's invoice/crypto route), never a standalone
script, matching the house rule for `appointments`.

### 4.4 Chain read (phase 2, optional)

Use an **Esplora**-compatible API (Blockstream or mempool.space; self-hosted
Esplora is the private option). Two calls per unspent address:

- `GET /address/:address` → `chain_stats` + `mempool_stats` (funded/spent totals);
- `GET /address/:address/txs` only when the panel is open, not on a loop.

Rules:

- Derive locally, query per address. Esplora has **no xpub endpoint**; the address
  set is the issued set plus the gap window, not the whole wallet.
- Cache each result for 5–10 minutes in `cache` (`app = 'crypto'`,
  `context = 'chain'`), which is already machine-local.
- **Privacy**: the explorer sees every address queried and this machine's IP.
  Disclose that in the panel, and offer a self-hosted URL in `wallet_explorer`.
- The chain figure is **reported**, never authoritative. Show it in its own
  column with an "as of" time.
- **Never auto-write** a transaction from the chain. If chain > ledger, show
  "N received not recorded" with one press to open a prefilled transaction for a
  person to confirm. This keeps `records_audit.pl` and the stop/repair rules sane.

### 4.5 UI touchpoints

| File | Change |
|---|---|
| `templates/configure/appointment_list.html.ep` | Address field label becomes "Address or xpub"; a note explains the fallback; a "Next address" preview and a small list of recent derived addresses. |
| `templates/configure/crypto_setting_list.html.ep` | Wallet table gains a **Chain** column when an explorer is set; a **Receive address** preview; an explanatory note about xpub privacy. |
| `templates/store/crypto_payment.html.ep` | Uses the invoice's allocated address; falls back to `wallet_address`. |
| `public/js/store.js` | `cryptoPayAddress()` already reads `data-address` from the selected option — pass the allocated address in the wallet JSON; no new mechanism. |
| `Manager.pl` | `/manager/store/crypto_panel` and `/manager/crypto/payment_request` allocate/return the address; `/manager/crypto/qr` is unchanged. |
| `subroutines.pl` | `crypto_accounts()`, `crypto_wallets_report()`, new `crypto_address_*` helpers. |
| `help.pl` | The `crypto` topic: replace "one address, reused" with the new behaviour and add a step. |
| `public/js/manager/configure.js` | Save/validate the xpub, show the derivation status. |

### 4.6 Translation

Every new label goes through `subs::lang` (a core label in all sixteen languages)
or `subs::ui` (help sentences, translated on demand). JS uses `jawnosT`. The
`help.pl` topic is updated in the same commit.

---

## 5. Migration and compatibility

- **Additive.** A wallet with only `wallet_address` behaves exactly as today.
  `crypto_accounts()` returns both, and the invoice panel prefers the allocated
  address when one exists.
- `wallet_next_index` is created lazily on the first allocation.
- `crypto_address` is added through `update_database()` (`create table if not
  exists`), so an existing database gains it on the next boot.
- It syncs by default because it is not in `gb.pl` `$forbidden{tables}`. Confirm
  it carries `server_time` and `ost`, or the sync/backup path will skip it.
- Existing invoices keep whatever address they showed. No backfill: issuing
  historical addresses retroactively would be wrong.

---

## 6. Security and failure modes

| Risk | Mitigation |
|---|---|
| Derivation bug sends funds to an address the device does not control | Test vectors + compare the first five addresses with the device's own Receive list before enabling. Refuse to allocate on a mismatch. |
| Wrong script type / prefix (`zpub` used as P2PKH) | Prefix chooses the default; mismatch is an error, not a guess. |
| Mainnet/testnet mix-up | Refuse a testnet key on a mainnet wallet (and the reverse). |
| User pastes a private key | `crypto_looks_like_secret()` plus an explicit `xprv`/`yprv`/`zprv`/WIF prefix check; never log the value. |
| xpub leaks privacy | It reveals every address and balance to whoever holds it. Keep it out of PAY1Z proofs, peer sync exports beyond the ordinary settings row, logs and QR codes. State this at the field. |
| Explorer lies | Label the chain figure "reported", not authoritative; keep the ledger figure for statements. |
| Gap limit exceeded | Cap unissued addresses at the gap limit and tell the person to open the wallet's app. |
| Two offline machines allocate the same index | `address unique` + retry; document it as reuse, not loss. |
| Address reused for a second invoice | Allocation is keyed by `invoice_uuid`; re-opening returns the same row. |

---

## 7. The NFC tension

A **locked** NFC tag is the safe kind: a rewritable tag can be swapped to an
attacker's address. But a locked tag cannot hold a fresh address per invoice.
Resolve it by splitting the two jobs:

- The tag carries a **stable** URI: the wallet's first receive address
  (`bitcoin:bc1q…`), or better a URL to the Store's payment page. That is the
  "tap to pay me" card with your logo.
- **Invoices** use derived addresses shown as a QR on screen, never the tag.
- If a tag must carry an invoice address, use a writable tag, rewrite it per
  invoice, and re-verify the address on the device before each send — or accept
  the swap risk knowingly.

---

## 8. Phases and rough effort

| Phase | Scope | Estimate |
|---|---|---|
| **1** | BTC xpub: settings, validation, BIP32/BIP84 derivation, `crypto_address` allocation, invoice panel, QR, help | 1–2 focused days |
| **2** | Esplora chain read, Chain column, reconciliation prompt | ~1 day |
| **3** | ETH/ERC-20 (Keccak + checksum) where the device exports an xpub; more chains only if a device supports it | 1–2 days per family |
| **4** | Descriptors/multisig, NFC tag write for the stable address, address book | open |

Phase 1 is the one that answers "does an invoice make a new address?".

---

## 9. Test plan

- **Vectors**: BIP32 vector 1; BIP84 vectors for `abandon … about`; compare
  P2WPKH/P2TR/P2PKH encodings.
- **Device check** (manual, once): import the same xpub into Sparrow (or the
  maker's app), derive five addresses, compare with JawnOS.
- **Allocation**: create invoice A → address 0; reopen A → address 0; create B →
  address 1; pay A partially → still address 0.
- **Fallback**: a wallet with no xpub shows `wallet_address` everywhere it does
  today.
- **Offline**: no explorer → Chain column shows `—`, invoice flow unaffected.
- **Sync**: allocate on machine A, sync, open the same invoice on B → same address.
- **Audit**: `perl scripts/records_audit.pl` unaffected (no direct appointment
  writes); run `perl scripts/help_audit.pl` for the topic.

---

## 10. Decisions for you

1. **Bitcoin first?** Recommended. ETH xpub support depends on the device and is
   not uniform.
2. **Allocate on invoice creation or on first panel open?** Creation is tidier;
   panel-open is lazier and avoids gaps from abandoned invoices.
3. **Chain read at all?** It is the only way the holding column becomes true. It
   costs a dependency on a public explorer unless you self-host one.
4. **Gap limit**: 20 (standard) or 50 (more spares, more scanning in the wallet's
   app)?
