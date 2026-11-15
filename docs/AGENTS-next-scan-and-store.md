# Next: scan, store, receipts and packages (handoff, 2026-11-15)

Where the work stands, what is left, and the decisions still open. Read with `AGENTS.md`;
nothing here overrides it.

## Landed and in use

- v0.1.3000 - PDF: `JawnOS::PDF` embeds a **sparse TrueType subset** - only the glyphs a paper
  drew, with their composite components - instead of the whole face. The two sample store papers
  fell from ~360-388 KB to ~77-82 KB. `_ttf_subset`, `_ttf_components`, `_ttf_checksum` in
  `lib/JawnOS/PDF.pm`; `t/303-pdf-subset.t`.
- v0.1.3000 - Packages: apt and pacman plus **AUR through yay/paru**, **flatpak**, **snap**,
  **pip3** and **npm**. **Purge** (route `54030`) removes configuration while Remove keeps it.
  Every command is a literal argv and every name is validated per backend; writes are refused
  outside the JawnOS desktop window. The mobile runtime case says why it is read-only.
  `lib/JawnOS/Domain/Packages.pm`, `t/302-packages.t`.
- v0.1.3000 - Store: a **receipt paper for every payment received**, with its own
  Configure - Store switch (`receipt_paper`, on by default). Turning it off keeps the receipt row
  and draws no paper; the receipt no longer follows the invoice-paper switch.
  `store_receipt_paper_enabled` and the gate in `store_payment_receipt`, `t/304-store-receipt-paper.t`.
- This follow-up - **weasyprint is gone from the store path and the installers**. The invoice and
  receipt papers, `/store/print/pdf`, `/store/print/send` and emailed papers all use
  `JawnOS::PDF::Store`. `Platform::Print::pdf_from_html`, `printer_pdf_from_html`, the
  `weasyprint` tool probe, and the Debian, AUR, Docker and README entries are removed.
- This follow-up - **the logo and item pictures are on the papers.** Configure - Store's
  `invoice_images` dropdown chooses **None** (default), **Invoice line** (a thumbnail beside each
  line), **Single Product Picture** (one near the top) or **Both**. The invoice draws the colour
  JPEGs; the receipt carries only the logo, in grayscale. `lib/JawnOS/Domain/PaperImage.pm` caches a colour and
  a grayscale JPEG per source under `.paper-images` beside the scans, makes them on demand (image
  bridge, then magick), and forgets them when the app's `main_image` changes or the file is
  deleted. The `logo` (a PNG data URI) uses the same cache: colour on the invoice, grayscale on
  the receipt. `t/305-paper-images.t`.

Earlier in the run: receipts delete house-wide and reference their pages on the category, vendor
and every item (`market_receipt_attach`); the receipts list names the apps that use a receipt
(`market_receipt_referrers`); invoices keep a versioned paper (`store_invoice_paper`); the receipt
vendor matches the name the House already keeps (`market_vendor_resolve`).

## Left to do, in the order I would take it

1. **Close the peer render.** It was going to draw on a computer for the phone; the engine now
   draws on the phone and subsetting has landed, so the peer path is no longer needed.
2. **Packages refinements.** Snap and flatpak column parsing should be checked on a real host
   (the parsers are heuristics); pip may be refused by a PEP 668-managed Python and should say
   so; the desktop window gate is client-side, while the server still relies on the approved
   session plus `confirm=1`.
3. **Scan leftovers worth a pass** (working, not yet leaned on):
   - the phone's `computer health probe` line: after a pass,
     `grep 'computer health probe' ~/manager.log` on the phone should read
     `answered (table) - this phone stands aside`.
   - receipts expire only at 50 kept; delete works. If they should also age out by time, that
     is a small addition to `market_receipt_file`.
   - the ADF edge is the "scan to computer" trigger; the printer's own Scan button is HP's and
     cannot be hooked on this model (see the scan help topic).

## Open decisions

- `payment_paper_app` blank means "the income transaction's own app". Set it to
  `computer_repair` if that is where the stapled papers belong.
- Partial payments write a receipt with the remaining balance (implemented). Confirm the
  wording on the sheet once you see one.
- Turning `receipt_paper` off suppresses the payment's whole render, including the revised
  invoice sheet normally stapled to the receipt. Split them if the invoice paper should keep
  refreshing independently.

## Verification

- Iterate: `perl scripts/tests_for.pl --staged --run`. Before commit: `perl scripts/run_tests.pl`
  (never bare `prove`). Help: `perl scripts/help_audit.pl`.
- Land: `perl scripts/land_enqueue.pl --trunk working --wait`. Expect VERSION and
  `qa/coding_night/agent-index.md` conflicts - rebase, regenerate the index with
  `perl scripts/agent_help.pl --write-index`, retitle with the new version.
- Known parallel flakes: `t/57-control-socket`, `t/78-manager-killer`; both pass alone.
- Tests added in v0.1.3000: `t/303-pdf-subset`, `t/304-store-receipt-paper`, and this run's
  `t/305-paper-images`; `t/302-packages`, `t/302-pdf-writer`, `t/262-store-scope`, `t/196-cups-print`,
  `t/243-platform-print`, `t/219-platform-capabilities` and `t/258-shell-sinks` were updated for
  the engine-only path.

## Worktrees from this run

- `pdf-packages` - landed as v0.1.3000; safe to remove.
- `store-paper` - landed as v0.1.3005; safe to remove.
- `store-pictures` - this branch (logo and item pictures, this doc). Safe to remove once landed.

    git -C ~/jawnos worktree list
    git -C ~/jawnos worktree remove .worktrees/<name>    # then: git branch -D agent/<branch>
