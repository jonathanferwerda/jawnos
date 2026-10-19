# i18n

This folder is for **optional** bulk translation catalogs. The running app does
not need them.

## On demand (the normal path)

`language.pl` holds the sixteen hand-written interface languages and the list of
107 languages the Guide's translation engine offers. The engine translates text
or the visible window on request through the Guide's model:

- `translate.js` collects the visible English strings and calls
  `/manager/translate`.
- `subs::translate_engine()` caches each result in the `cache` table
  (`app='translation'`), so a repeated label is not paid for twice.
- The browser also keeps the map in `localStorage`, so a re-opened page keeps
  its on-demand translation.
- The Guide tools are `translate`, `translate_page` and `translate_languages`.
- Configure -> Misc shows the language list and a Translate this window button.

## Bulk catalogs (optional)

If you want a pre-generated catalog for a language, run:

```sh
perl scripts/i18n_extract.pl
perl scripts/i18n_translate.pl --langs fr,de
perl scripts/i18n_audit.pl
```

`i18n/ui-<code>.json` is then served as `/i18n/ui-<code>.js` and loaded by the
layouts. Commit a catalog only after review; machine translations are a
starting point, not a substitute for a speaker on legal or sensitive text.

The extractor's snapshot (`i18n/strings.json`) and the generated catalogs are
not required for the on-demand engine.
