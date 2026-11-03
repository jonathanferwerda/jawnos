# Languages and translation (moved from AGENTS.md)

Read this when you write UI or help text, or anything that becomes a name or a path.

JawnOS ships English plus fifteen interface languages — Mandarin, French, Spanish, German, Portuguese,
Hindi, Arabic, Bengali, Russian, Japanese, Punjabi, Indonesian, Korean, Italian and Turkish — listed in
`language.pl`. Core interface labels have hand-written translations for all sixteen. Everything else is
translated **on demand** by the Guide's engine; do not pre-generate fifteen copies of every help paragraph.

**When you write help text or a UI feature, make it translatable in the same change:**

- Perl and templates: `subs::lang('key')` for a reusable core label; `subs::ui('English text')` for a
  help/printer/server-side sentence. JS: `jawnosT('English text')`. Never hardcode a second language and
  never leave a bare English label where a core label belongs.
- A **new core interface label** gets a key in `language.pl` in **all sixteen interface languages**
  (English plus the fifteen above). If it is help/body text instead, add it to the help topic; the Guide
  engine translates it on demand for the 107 languages it offers.
- The engine's language list is `language::translation_languages()` (the `translation` help topic and
  Configure -> Misc show it). The Guide can list it with `translate_languages`, translate a phrase with
  `translate`, and translate the visible window with `translate_page`. The model configured for the Guide
  under Configure -> Plat does the work — DeepSeek, Gemini, Claude, GPT, Grok and the rest are broadly
  multilingual. Legal and sensitive help text should be reviewed by a speaker before it is relied on.
- Add/rename an on-screen button or hint: update the help topic (see below) and make sure the same English
  label is in the translation pipeline. `translate.js` replaces exact English text nodes and the
  `hint`/`placeholder`/`title`/`alt`/`aria-label` attributes, so a dynamic label must go through
  `jawnosT`/`subs::ui` instead of being assembled from untranslated pieces.
- Optional bulk catalogs: `perl scripts/i18n_extract.pl`, then `perl scripts/i18n_translate.pl`, then
  `perl scripts/i18n_audit.pl`. The on-demand cache (the `cache` table with `app='translation'`, and the
  browser's `localStorage`) works without them; commit a bulk catalog only when it has been reviewed.

**Names accept every printable character.** `subs::unformat_name()` keeps them: spaces become `_`, a
straight `'` or `"` becomes the typographic mark so the hundreds of hand-built JS/SQL snippets stay safe,
and control characters are dropped. Never re-strip letters or punctuation from an input name. When a
name becomes a filesystem path use `subs::path_name()` (it percent-encodes the bytes a path or shell
cannot take safely); when it becomes a DOM id/class or a URL use `subs::html_name()`/`http_name()`. New
code that concatenates `$app` into a path without `path_name` is a bug.
