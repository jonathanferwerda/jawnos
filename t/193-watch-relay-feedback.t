# tests-for: jw/jw_01_globals.ino jw/jw_04_loop.ino jw/jw_05_loop2.ino jw/jw_07_house_audio.ino jw/jw_10_playback.ino jt/jt_01_globals_ble_house.ino jt/jt_05_loop.ino jt/jt_08_display_touch_rooms.ino jt/jt_09_mb_buttons_config.ino
# covers:    A watch or deck button shows a press's relay outcome for two seconds
#            - red when a named command did not land or an every-machine command
#            missed a machine, green when every machine took it - and a running
#            toggle is a yellow ring, not a yellow fill.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $jw_globals = read_file("$root/jw/jw_01_globals.ino");
my $jw_loop    = read_file("$root/jw/jw_04_loop.ino");
my $jw_ble     = read_file("$root/jw/jw_05_loop2.ino");
my $jw_face    = read_file("$root/jw/jw_07_house_audio.ino");
my $jw_press   = read_file("$root/jw/jw_10_playback.ino");
my $jt_globals = read_file("$root/jt/jt_01_globals_ble_house.ino");
my $jt_loop    = read_file("$root/jt/jt_05_loop.ino");
my $jt_face    = read_file("$root/jt/jt_08_display_touch_rooms.ino");
my $jt_press   = read_file("$root/jt/jt_09_mb_buttons_config.ino");

# --- the outcome the server sends is read on both devices --------------------
like($jw_ble, qr/button_flash_from_result\(button, btMsg\["data"\]\)/,
	'the watch starts the flash from the result the manager sends back');
like($jt_loop, qr/button_flash_from_result\(button, btMsg\["data"\]\)/,
	'the deck does the same');
like($jw_face, qr/static void button_flash_from_result\(int key, JSONVar result\)/,
	'the watch has the shared outcome reader');
like($jt_face, qr/static void button_flash_from_result\(int key, JSONVar result\)/,
	'the deck has it too');
for my $source ( [ watch => $jw_face ], [ deck => $jt_face ] ) {
	like($source->[1], qr/result\.hasOwnProperty\("relay_ok"\)/,
		"the $source->[0] reads relay_ok");
	like($source->[1], qr/result\.hasOwnProperty\("relay_all"\)/,
		"the $source->[0] reads relay_all");
	like($source->[1], qr/button_flash_colour = ok \? 0x27de16 : 0xde2716/,
		"the $source->[0] flashes green on success and red on a miss");
	like($source->[1], qr/button_flash_until = millis\(\) \+ 2000/,
		"the $source->[0] holds the colour for two seconds");
}

# --- the flash is painted on the UI thread, then taken off -------------------
like($jw_loop, qr/button_feedback_tick\(\)/, 'the watch loop paints the flash');
like($jt_loop, qr/button_feedback_tick\(\)/, 'the deck loop paints it');
for my $source ( [ watch => $jw_face ], [ deck => $jt_face ] ) {
	like($source->[1], qr/lv_obj_set_style_bg_color\(b, lv_color_hex\(button_flash_colour\)/,
		"the $source->[0] paints the flash colour");
	like($source->[1], qr/deck_button_face_from_before|button_face_from_before/,
		"the $source->[0] puts the real face back after it");
}

# --- a running toggle is a yellow ring, not a fill ---------------------------
like($jw_face, qr/lv_obj_set_style_border_width\(b, tog == 1 \? 5 : 0, LV_PART_MAIN\)/,
	'the watch marks a running toggle with a border');
like($jw_face, qr/lv_obj_set_style_border_color\(b, lv_color_make\(255, 255, 0\), LV_PART_MAIN\)/,
	'and that border is yellow');
like($jt_face, qr/lv_obj_set_style_border_width\(b, tog == 1 \? 5 : 0, LV_PART_MAIN\)/,
	'the deck does the same');
like($jt_face, qr/lv_obj_set_style_border_color\(b, lv_color_make\(255, 255, 0\), LV_PART_MAIN\)/,
	'with a yellow border');

# The six/eight press handlers use the shared face, so a press no longer paints
# the whole button yellow while its toggle is on.
my @watch_faces = $jw_press =~ /button_face_apply\(b, result\)/g;
is(scalar @watch_faces, 6, 'every watch room button uses the shared face');
my @watch_flash = $jw_press =~ /button_flash_from_result\(\(int\)result\["button"\], result\)/g;
is(scalar @watch_flash, 6, 'and reports its outcome to the flash helper');
my @deck_faces = $jt_press =~ /deck_button_face\(b, result\)/g;
is(scalar @deck_faces, 8, 'every deck room button uses the shared face');
my @deck_flash = $jt_press =~ /button_flash_from_result\(\(int\)result\["button"\], result\)/g;
is(scalar @deck_flash, 8, 'and reports its outcome too');

# A press carries its own id so a delayed second delivery is not run twice.
like($jw_press, qr/static String press_id\(int button\)/, 'the watch names each press');
like($jt_press, qr/static String press_id\(int button\)/, 'the deck names each press');
my @watch_ids = $jw_press =~ /"&id=" \+ press_id\(\d\)/g;
is(scalar @watch_ids, 6, 'every watch button tap carries the id');
my @deck_ids = $jt_press =~ /"&id=" \+ press_id\(\d\)/g;
is(scalar @deck_ids, 8, 'every deck button tap carries the id');

done_testing();
