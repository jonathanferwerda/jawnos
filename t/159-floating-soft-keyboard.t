# tests-for: public/js/manager/soft_keyboard.js public/css/soft_keyboard.css templates/soft_keyboard.html.ep perl/help/topics_mail.pl
# covers:    On a desk the soft keyboard and calculator were the full width of
#            the screen. They are now a floating panel with its own frame and
#            shadow, moved by the bar above the keys and remembered on the
#            device. A phone or tablet keeps the full-width dock, and the
#            Android input method page is never floated.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $kb = js_source('public/js/manager/soft_keyboard.js');
my $css = read_file(repo_root() . '/public/css/soft_keyboard.css');
my $tpl = read_file(repo_root() . '/templates/soft_keyboard.html.ep');
my $help = help_source();

# --- place applies the desk-only floating class -----------------------------
like($kb, qr/function softKbFloatApply\(dock\)/, 'the dock has one floating-layout pass');
like($kb, qr/function softKbPlace\(el\) \{[\s\S]*?softKbFloatApply\(dock\);/, 'placing the dock applies it');
like($kb, qr/var floating = softKbDesk\(\);/, 'only a desk floats the dock');
like($kb, qr/dock\.toggleClass\('soft_kb_floating', floating\);/, 'the class is the floating layout');
like($kb, qr/if \(!floating\) \{[\s\S]*?dock\.draggable\('destroy'\);[\s\S]*?left: '', top: '', bottom: ''/,
	'a phone or the IME page is put back full width');

# --- the panel is dragged, clamped and remembered ---------------------------
like($kb, qr/function softKbFloatDraggable\(dock\)/, 'the floating panel is made draggable');
like($kb, qr/handle: '\.soft_kb_bar'/, 'the bar above the keys is the handle');
like($kb, qr/distance: 4/, 'a tap on the bar does not start a move');
like($kb, qr/if \(panel\.css\('bottom'\) != 'auto'\)/, 'a moved panel is not stretched by top and bottom together');
like($kb, qr/panel\.css\(\{ 'left': rect\.left \+ 'px', 'top': rect\.top \+ 'px', 'bottom': 'auto' \}\)/,
	'the move keeps the visual spot while it takes the top edge');
like($kb, qr/function softKbFloatSave\(panel\)/, 'one save keeps the panel spot and size');
like($kb, qr/localStorage\.setItem\('jawn_soft_place'/, 'the place is kept on the device');
like($kb, qr/function softKbFloatRestore\(dock\)/, 'the place is restored on the next open');
like($kb, qr/localStorage\.getItem\('jawn_soft_place'\)/, 'from the same device setting');
like($kb, qr/Math\.min\(saved\.left, Math\.max\(0, vw - width\)\)/,
	'a saved place is kept inside the screen');
like($kb, qr/var top = Math\.max\(limit, Math\.min\(saved\.top, Math\.max\(limit, vh - height - bar\)\)\);/,
	'a saved place never starts above the clothesline');
like($kb, qr/ui\.position\.top = Math\.max\(limit, Math\.min\(ui\.position\.top/,
	'a drag is held under the same ceiling');
like($kb, qr/if \(typeof softKbReserve == 'function'\) \{ softKbReserve\(\); \}/,
	'the field reserve follows the moved panel');

# --- the floating panel is resized too --------------------------------------
like($kb, qr/dock\.resizable\(\{[\s\S]*?handles: 'e, s, se'/, 'the floating panel is resizable');
like($kb, qr/minWidth: 320,\s*minHeight: 180,/, 'it keeps a usable minimum');
like($kb, qr/box\.width = Math\.round\(w\)/, 'a resized width is kept');
like($kb, qr/box\.height = Math\.round\(h\)/, 'a resized height is kept');
like($kb, qr/dock\.css\('width', Math\.min\(saved\.width/, 'the width is restored');
like($kb, qr/dock\.css\('height', Math\.min\(saved\.height/, 'the height is restored');
like($kb, qr/dock\.resizable\('destroy'\)/, 'a phone\'s dock has no resize handles');

# --- the stylesheet gives the floating dock a panel look --------------------
my ($float) = $css =~ /\.soft_kb\.soft_kb_floating \{([^}]*)\}/s;
ok(defined $float && length $float, 'the floating rule exists');
like($float, qr/width: min\(760px, calc\(100vw - 24px\)\)/, 'the panel has a fixed width, not the screen width');
like($float, qr/left: max\(12px, calc\(50% - 380px\)\)/, 'it opens centred, clear of both edges');
like($float, qr/right: auto;/, 'the full-width right anchor is released');
like($float, qr/border: var\(--window_border, 3px\) solid var\(--window_border_colour, var\(--line\)\)/,
	'the panel wears the same frame as every window');
like($float, qr/border-radius: var\(--window_radius, var\(--jawnos-corner, 12px\)\)/, 'and the house corner');
like($float, qr/box-shadow:/, 'and a floating shadow');
like($css, qr/\.soft_kb\.soft_kb_floating \.soft_kb_bar \{ cursor: move; \}/, 'the bar reads as the move handle');

# --- the bar says what it is, and the guide says so -------------------------
like($tpl, qr/class="soft_kb_bar" hint="<%=\s*&subs::ui\('Drag here to move the keyboard'\)\s*%>"/,
	'the bar carries the move hint');
like($help, qr/On a desk the dock is a floating panel: drag the bar above the keys/,
	'the keyboard topic explains the floating panel');


# --- a desk is the device, not the pointer ----------------------------------
like($kb, qr/if \(typeof device != 'undefined' && device\) \{/,
	'the house\'s own device name decides what a desk is');
like($kb, qr/if \(device == 'mobile'\) \{ return false; \}/,
	'a phone or tablet keeps the full-width dock');
like($kb, qr/if \(window\.matchMedia\('\(hover: hover\)'\)\.matches\) \{ return true; \}/,
	'a page without the device name falls back to a hovering pointer');
unlike($kb, qr/\(any-pointer: coarse\)'\)\.matches\) \{ return false; \}/,
	'a coarse pointer beside a trackpad no longer disqualifies a desk');

# --- a desk's dock keeps the input, and the keypad feeds the calculator -----
like($kb, qr/function softKbHardwareKey\(e\)/, 'a real key while the dock is up is routed to it');
like($kb, qr/if \(jawnSoftIme \|\| jawnSoftMode != 'calc'\) \{ return false; \}/,
	'the calculator is the page that reads the keypad');
like($kb, qr/if \(softKbEditable\(e\.target\)\) \{ return false; \}/,
	'a focused field keeps the keypad until the calculator is pressed');
like($kb, qr/if \(\/\^\[0-9\]\$\/\.test\(key\) \|\| key == '\.'\) \{ softKbCalcKey\(key\); return true; \}/,
	'the numeric keypad types into the calculator');
like($kb, qr/var map = \{ 'Enter': '=', '=': '=', 'Backspace': 'backspace', 'Delete': 'clear', 'Escape': 'clear', ',': '\.' \};/,
	'Enter, backspace, escape and the decimal comma are mapped');
like($kb, qr/if \(softKbVisible\(\) && \(jawnSoftSticky \|\| jawnSoftForced\) && softKbDesk\(\)\) \{/,
	'an explicitly opened desk dock holds the input');
like($kb, qr/if \(softKbHardwareKey\(e\)\) \{ e\.preventDefault\(\); \}/,
	'and the calculator key does not reach the page');

# --- the guide says the dock keeps the keys ----------------------------------
like($help, qr/instead of putting the dock away/,
	'the keyboard topic says a real key no longer puts the dock away');
like($help, qr/the numeric keypad\\'s digits/,
	'and names the numeric keypad it feeds');
like($help, qr/press the calculator\\'s display or frame/,
	'and says how to take the keypad back after typing in a field');

# --- pressing the calculator takes the keypad back ---------------------------
like($kb, qr/if \(jawnSoftMode == 'calc' && softKbDesk\(\) && document\.activeElement !== this\) \{/,
	'pressing the calculator takes the keypad back from a field');
like($kb, qr/this\.focus\(\{ preventScroll: true \}\)/,
	'by focusing the dock itself');
like($tpl, qr/id="jawn_soft_keyboard"[^>]*tabindex="-1"/,
	'the dock is focusable so it can take the keypad back');
like($kb, qr/var on_dock = !!\(target && target\.closest && target\.closest\('#jawn_soft_keyboard, #jawn_measure_pop'\)\);/,
	'the keydown knows when the keys themselves have focus');
like($kb, qr/if \(key == 'Enter' && e\.target && e\.target\.closest && e\.target\.closest\('#jawn_soft_keyboard button'\)\) \{ return false; \}/,
	'a focused on-screen key keeps the Enter that presses it');
like($kb, qr/if \(on_dock\) \{ return; \}/,
	'a phone key on the keys does not dismiss them');


# --- the calculator shows where the next hardware key will go ----------------
like($kb, qr/dock\.toggleClass\('soft_kb_calc', mode == 'calc'\);/,
	'the dock marks the calculator mode');
like($css, qr/#jawn_soft_keyboard:focus \{ outline: none; \}/,
	'the dock does not draw the browser\'s default focus box');
like($css, qr/#jawn_soft_keyboard\.soft_kb_calc\.soft_kb_floating:focus-within \{[^}]*outline: 3px solid var\(--accent/,
	'the calculator wears a focus ring while it owns the keypad');
like($help, qr/wears the accent ring while it owns the keypad/,
	'and the keyboard topic says so');

# --- the bar can actually start a drag ---------------------------------------
like($kb, qr/if \(\$\(e\.target\)\.closest\('\.soft_kb_bar, button, \.soft_kb_convert_rows'\)\.length\) \{ return; \}/,
	'the keys\' pointerdown stands down on the drag bar');
like($kb, qr/dock\.css\('position', 'fixed'\);/,
	'the floating panel is pinned fixed before the draggable reads it');
like($kb, qr/css\(\{ position: '', left: '', top: '', bottom: '', width: '', height: '', 'max-height': '' \}\)/,
	'a phone dock drops the fixed pin again');

done_testing();
