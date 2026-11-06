# tests-for: jt/jt_05_loop.ino jt/jt_06_ui_lora_keypad.ino jt/jt_08_display_touch_rooms.ino
# covers:    The deck's room is rebuilt, never stacked. Every push from the panel
#            - a room, a toggle, a watch press - used to add another set of
#            widgets to the screen without deleting the last one, and the room's
#            touch branch rebuilt its bottom row on every touch. The redraw grew
#            with every press until the deck froze and crashed. A toggle push now
#            repaints the one button whose app changed.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root    = repo_root();
my $jt_loop = read_file("$root/jt/jt_05_loop.ino");
my $jt_key  = read_file("$root/jt/jt_06_ui_lora_keypad.ino");
my $jt_face = read_file("$root/jt/jt_08_display_touch_rooms.ino");

# --- the room is built on a clean screen -------------------------------------
my ($room) = $jt_face =~ /(void presidents_buttons\(\).*?\n\}\n)/s;
ok($room, 'the room builder was found');

# The flash holds a widget pointer: it has to be forgotten before those widgets
# are deleted, or the next tick paints freed memory.
like($room, qr/button_feedback_forget\(\);\s*lv_obj_clean\(lv_scr_act\(\)\);/,
	'the room rebuild forgets the flash, then clears the screen before it builds');
like($room, qr/for \(int i = 0; i < ROOM_BUTTON_SLOTS; i\+\+\) \{ room_button_obj\[i\] = nullptr; \}/,
	'and drops the pointers to the buttons it just deleted');
like($room, qr/deck_nav_row_reset\(\);\s*button_writer\(\);/,
	'and rebuilds the bottom row it swept away');

# Rendering from inside the builder re-entered LVGL when a click handler
# (when_i_get_in) reached it; loop() renders right after now.
unlike($room, qr/^\s*lv_task_handler\(\);$/m,
	'the builder does not render from inside a click handler');

# --- the bottom row belongs to the screen, not to every touch ------------------
my ($writer) = $jt_face =~ /(void button_writer\(\) \{.*?\n\}\n)/s;
ok($writer, 'the bottom row builder was found');
like($writer, qr/if \(btn1\) \{ return; \}/,
	'the bottom row is built once per screen');
unlike($writer, qr/lv_task_handler/, 'and does not render by itself');

like($jt_key, qr/lv_obj_clean \( lv_scr_act\(\) \);[^\n]*\n\s*deck_nav_row_reset\(\);/,
	'a screen wipe forgets the bottom row pointers it deleted');

# --- one render pass per loop -------------------------------------------------
like($jt_loop, qr/if \(troom != "typewriter" \|\| jw_room != "typewriter"\) \{\s*lv_task_handler\(\);\s*\}/,
	'loop() services LVGL once, not twice in a row');
unlike($jt_loop, qr/if \(troom != "typewriter"\) \{\s*lv_task_handler\(\);\s*\}\s*if \(jw_room != "typewriter"\)/,
	'the duplicate pass is gone');

# --- a local toggle repaints its button too -----------------------------------
like($jt_face, qr/if \(b\) \{ deck_button_face\(b, bm\["b" \+ roomings\]\); \}/,
	'a failed tap repaints its button without rebuilding the room');
unlike($jt_face, qr/before_me = JSON\.stringify\(bm\);\s*presidents_buttons\(\);/,
	'and never rebuilds from inside a click handler');

# --- a toggle push repaints its button, it does not rebuild the room ----------
my $presidents_calls = () = $jt_loop =~ /presidents_buttons\(\);/g;
is($presidents_calls, 1, 'only the room push rebuilds the room');
like($jt_loop, qr/deck_button_face\(b, bm\["b" \+ String\(key\)\]\)/,
	'a toggle push repaints the button whose app changed');
like($jt_loop, qr/key < ROOM_BUTTON_SLOTS\s*&& !\(flashing && key == button_flash_key\)/,
	'and leaves a button that is still flashing to the flash tick');

done_testing();
