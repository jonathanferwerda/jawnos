# tests-for: jw/jw_01_globals.ino jw/jw_04_loop.ino jw/jw_06_net_face.ino jw/jw_07_house_audio.ino
# covers:    The watch's room is rebuilt, never stacked, and a toggle push repaints
#            its buttons instead of rebuilding the room. The rebuild used to run on
#            every toggle the bridge pushed (a held volume key sends a run of them)
#            and left the previous six buttons and their labels on the screen, and
#            remote_room() built the bottom row a second time after display_exit()
#            had already built it. The redraw and the heap grew with every press.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root    = repo_root();
my $jw_loop = read_file("$root/jw/jw_04_loop.ino");
my $jw_ui   = read_file("$root/jw/jw_06_net_face.ino");
my $jw_face = read_file("$root/jw/jw_07_house_audio.ino");

# --- the room is rebuilt, not stacked ----------------------------------------
my ($room) = $jw_face =~ /(void presidents_buttons\(\).*?\n\}\n)/s;
ok($room, 'the room builder was found');
like($room, qr/button_feedback_forget\(\);\s*for \(int i = 0; i < ROOM_BUTTON_SLOTS; i\+\+\) \{\s*if \(room_button_obj\[i\]\) \{/,
	'the rebuild forgets the flash, then deletes the buttons it made last time');
like($room, qr/lv_obj_delete\(room_button_obj\[i\]\);/,
	'and actually deletes them, rather than only dropping the pointers');

# --- one bottom row per screen ------------------------------------------------
my ($writer) = $jw_ui =~ /(void button_writer\(\) \{.*?\n\}\n)/s;
ok($writer, 'the bottom row builder was found');
like($writer, qr/if \(btn1\) \{ return; \}/, 'the bottom row is built once per screen');
unlike($writer, qr/lv_task_handler/, 'and does not render by itself');

my ($remote) = $jw_face =~ /(void remote_room\(\) \{.*?\n\}\n)/s;
ok($remote, 'the room entry point was found');
like($remote, qr/display_exit\(\);/, 'entering the room wipes the screen first');
unlike($remote, qr/button_writer\(\);/,
	'and does not build a second bottom row on top of the one display_exit() built');

# --- a clean forgets every widget pointer it deleted --------------------------
my ($exit) = $jw_ui =~ /(void display_exit\( void \) \{.*?\n\}\n)/s;
ok($exit, 'the screen wipe was found');
like($exit, qr/lv_obj_clean \( lv_scr_act\(\) \);/, 'it clears the screen');
like($exit, qr/btn1 = btn2 = btn3 = btn4 = btn5 = btn6 = nullptr;/,
	'and forgets the bottom row it deleted');
like($exit, qr/for \(int i = 0; i < ROOM_BUTTON_SLOTS; i\+\+\) \{ room_button_obj\[i\] = nullptr; \}/,
	'and the room buttons');
like($exit, qr/button_feedback_forget\(\);/, 'and any flash still painting one of them');

# --- a toggle push repaints, it does not rebuild the room --------------------
my $rebuilds_in_loop = () = $jw_loop =~ /presidents_buttons\(\);/g;
is($rebuilds_in_loop, 0, 'the loop does not rebuild the room for a toggle');
like($jw_loop, qr/room_repaint\(\);\s*full_refresh\(\);/, 'it repaints the buttons instead');

my ($repaint) = $jw_face =~ /(static void room_repaint\(\) \{.*?\n\}\n)/s;
ok($repaint, 'the button repaint was found');
like($repaint, qr/if \(flashing && i == button_flash_key\) \{ continue; \}/,
	'it leaves a button that is still flashing to the flash tick');
like($repaint, qr/if \(face\.hasOwnProperty\("rgb"\)\) \{ button_face_apply\(room_button_obj\[i\], face\); \}/,
	'and paints only the buttons this room actually has');

# The paint state has to be reachable from the screen wipe, which lives in
# another file, so it is declared where the other flash helpers are.
like(read_file("$root/jw/jw_01_globals.ino"), qr/static void button_feedback_forget\(\);/,
	'the forget helper is declared for the screen wipe');

done_testing();
