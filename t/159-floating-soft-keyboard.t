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
like($float, qr/border: 1px solid var\(--line\)/, 'the panel has its own frame');
like($float, qr/border-radius: var\(--jawnos-corner, 12px\)/, 'and the house corner');
like($float, qr/box-shadow:/, 'and a floating shadow');
like($css, qr/\.soft_kb\.soft_kb_floating \.soft_kb_bar \{ cursor: move; \}/, 'the bar reads as the move handle');

# --- the bar says what it is, and the guide says so -------------------------
like($tpl, qr/class="soft_kb_bar" hint="<%=\s*&subs::ui\('Drag here to move the keyboard'\)\s*%>"/,
	'the bar carries the move hint');
like($help, qr/On a desk the dock is a floating panel: drag the bar above the keys/,
	'the keyboard topic explains the floating panel');

done_testing();
