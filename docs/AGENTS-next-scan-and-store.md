# Next: scan, store, receipts and packages (handoff, 2026-11-15)

Where the work stands, what is left, and the decisions still open. Read with `AGENTS.md`;
nothing here overrides it.

## Landed and in use

- v0.1.2984 - Store: a receipt for every payment, stapled to the revised invoice; register
  sales keep receipts too.
- v0.1.2988 - Perl PDF writer (`lib/JawnOS/PDF.pm`, `lib/JawnOS/PDF/Store.pm`): the store's
  receipt and invoice are drawn by it; weasyprint is the fallback.
- v0.1.2990 - Packages app, first slice (apt/pacman, install/update/remove, upload a package
  file; the mobile runtime is read-only and says so).

Earlier in the same run: receipts delete house-wide and reference their pages on the category,
vendor and every item (`market_receipt_attach`); the receipts list names the apps that use a
receipt (`market_receipt_referrers`); invoices keep a versioned paper (`store_invoice_paper`);
the receipt vendor matches the name the House already keeps (`market_vendor_resolve`).

## Left to do, in the order I would take it

1. Check a printed invoice and receipt, then take weasyprint out of the store path.
   `lib/JawnOS/Manager/Part08.pm` (`store_invoice_paper`, `store_payment_receipt`) tries the
   engine first, then weasyprint. Print one of each, compare with the HTML sheet, and if they
   agree remove the weasyprint fallback for these two documents. Then the desktop installer
   can drop weasyprint too (the phone cannot have it: ~69 MiB marginal, and the runtime has no
   package manager - `JawnRuntime.java:56/380`).

2. TTF subsetting for the PDF engine. A paper with non-Latin text embeds the whole face
   (0.4-2 MB). `lib/JawnOS/PDF.pm` (CID fonts) embeds Type0 + Identity-H + CIDFontType2 with
   cmap 4/12. Subsetting brings a paper to tens of KB and is what makes keeping a paper per
   payment cheap. Papers are correct until then, just large.

3. Decide the peer render is no longer needed. It was going to draw on a computer for the
   phone; the engine now draws on the phone. Close it once step 2 lands.

4. Packages, next slice: AUR through yay/paru; Flatpak/Snap/pip/npm; purge (Remove keeps config
   today); the in-app window check on the desktop. Then refine what the mobile runtime case
   shows (it lists the shipped binaries and refuses to install).
   Key files: `lib/JawnOS/Domain/Packages.pm` (argv, validation, `packages_lock_take`, upload
   guard), `lib/JawnOS/Controller/manager_packages.pm`,
   `lib/JawnOS/Routes/manager_packages.pm` (ids 54020-54029), `templates/apps/packages.html.ep`,
   `public/js/manager/packages.js`.

5. Scan leftovers worth a pass (working, not yet leaned on):
   - the phone's `computer health probe` line: after a pass,
     `grep 'computer health probe' ~/manager.log` on the phone should read
     `answered (table) - this phone stands aside`.
   - receipts expire only at 50 kept; delete works. If they should also age out by time, that
     is a small addition to `market_receipt_file`.
   - the ADF edge is the "scan to computer" trigger; the printer's own Scan button is HP's and
     cannot be hooked on this model (see the scan help topic).

## Open decisions

- Does the Store's invoice-paper switch also govern receipt papers, or are they always kept?
  Today both follow the same render path.
- Partial payments write a receipt with the remaining balance (implemented). Confirm the
  wording on the sheet once you see one.
- `payment_paper_app` blank means "the income transaction's own app". Set it to
  `computer_repair` if that is where the stapled papers belong.

## Verification

- Iterate: `perl scripts/tests_for.pl --staged --run`. Before commit: `perl scripts/run_tests.pl`
  (never bare `prove`). Help: `perl scripts/help_audit.pl`.
- Land: `perl scripts/land_enqueue.pl --trunk working --wait`. Expect VERSION and
  `qa/coding_night/agent-index.md` conflicts - rebase, regenerate the index with
  `perl scripts/agent_help.pl --write-index`, retitle with the new version.
- Known parallel flakes: `t/57-control-socket`, `t/78-manager-killer`; both pass alone.
- New tests this run: `t/300-receipt-when-category`, `t/262-store-scope`, `t/302-pdf-writer`,
  `t/302-packages`.

## Worktrees from this run

All landed and safe to remove: scan-followup, scan-receipt-test, scan-jam,
scan-computer-first, scan-probe-log, scan-help-button, market-vendor-match, receipt-house,
receipt-ref, receipt-referrers, invoice-paper, invoice-paper-log, store-receipt, pdf-writer,
packages-app.

    git -C ~/jawnos worktree list
    git -C ~/jawnos worktree remove .worktrees/<name>    # then: git branch -D agent/<branch>
