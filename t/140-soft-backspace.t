# tests-for: public/js/manager/soft_keyboard/02_ime_input.js
# covers:    The on-screen keyboard's backspace used to treat a second tap within 380 ms as "take the
#            whole word", and a hold after that double tap kept taking words. A tap now always deletes
#            one character; only a held key repeats, and it repeats characters too.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;

my $src = js_source('public/js/manager/soft_keyboard/02_ime_input.js');

# --- the double tap no longer takes a word -----------------------------------
unlike($src, qr/softKbDeleteWord/, 'the word-delete routine is gone');
unlike($src, qr/softKbDeleteGranularity/, 'the contenteditable word granularity is gone');
unlike($src, qr/softKbDeleteSpan/, 'the word-span helper is gone');
unlike($src, qr/JAWN_SOFT_DOUBLE/, 'there is no double-tap window');
unlike($src, qr/jawnSoftBackspaceAt/, 'taps are not timed against each other');
unlike($src, qr/'word'/, 'no repeat mode still means a word');

# --- a tap deletes exactly one character -------------------------------------
like(
	$src,
	qr/function softKbBackspaceDown\(el\) \{\s*var now = Date\.now\(\);\s*softKbRepeatStop\(\);\s*softKbBackspaceOnce\(\);/s,
	'every press deletes one character, however soon it follows the last'
);
like(
	$src,
	qr/mode: \(jawnSoftMode == 'calc'\) \? 'calc' : 'char'/,
	'a held backspace is armed in character mode'
);
like(
	$src,
	qr/function softKbBackspaceOnce\(\) \{\s*if \(jawnSoftMode == 'calc'\) \{ softKbCalcKey\('backspace'\); \}\s*else \{ softKbBackspace\(\); \}/s,
	'the press deletes once through the normal (or calculator) path'
);

# --- the IME tap commits one backspace --------------------------------------
like(
	$src,
	qr/function softKbImeBackspace\(\) \{\s*if \(window\.JawnIme && typeof window\.JawnIme\.backspace === 'function'\) \{ window\.JawnIme\.backspace\(\); \}/s,
	'an Android editor gets one backspace per tap'
);
unlike($src, qr/softKbImeDeleteBack/, 'the batch delete loop is gone with the word delete');

# --- hold-to-repeat still repeats characters --------------------------------
like($src, qr/JAWN_SOFT_CHAR_FIRST/, 'a hold still repeats, starting after the first delay');
like($src, qr/JAWN_SOFT_CHAR_MIN/, 'the repeat still speeds up to its character floor');
like(
	$src,
	qr/softKbRepeatStart\(hold, JAWN_SOFT_CHAR_FIRST, JAWN_SOFT_CHAR_MIN, softKbBackspace\)/,
	'the repeat step deletes single characters'
);

done_testing;
