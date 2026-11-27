# tests-for: public/js/manager/studio/09_pedals.js
# covers:    Named pedalboard presets. The library the page publishes, the
#            save name and button, the saved-board dropdown kept in
#            most-recently-used order, the load path that rebuilds a track's
#            chain from the saved inserts, the badge's read-only refusal, and
#            replaying a saved board onto a machine this Studio controls.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root = repo_root();
my $js = read_file("$root/public/js/manager/studio/09_pedals.js");

# --- the library ------------------------------------------------------------
like($js, qr/function studioBoardLibrary\(\)/, 'one reader serves every preset call');
like($js, qr/var library = window\.jawnos_studio_pedalboards;/, 'the library is the page-published array');
like($js, qr/window\.jawnos_studio_pedalboards = library;/, 'an absent setting becomes a real array');
like($js, qr/studioSaveSettings\(\[\{ setting: 'pedalboards', value: JSON\.stringify\(studioBoardLibrary\(\)\) \}\]\);/,
	'the library is persisted as the pedalboards setting');

# --- the three controls -----------------------------------------------------
like($js, qr/#studio_board_save_name/, 'the name field is read and cleared');
like($js, qr/#studio_board_save\b/, 'the Save board button is bound');
like($js, qr/#studio_board_presets/, 'the saved-board dropdown is rebuilt and handled');
like($js, qr/function studioBoardPresetsRefresh\(\)/, 'the dropdown has its own refresh');
like($js, qr/studioLayoutText\('Saved pedalboards'\)/, 'the blank option says what the list is');
like($js, qr/setTimeout\(studioBoardPresetsRefresh, 0\)/, 'a press that opens the board refreshes the list');
like($js, qr/click', '\.studio_track_fx'/,
	'the refresh follows an FX press into the board');
like($js, qr/\$\(function \(\) \{ studioBoardPresetsRefresh\(\); \}\);/, 'document ready rebuilds the list');

# --- what an entry keeps ----------------------------------------------------
like($js, qr/out\.push\(\{ name: ins\.name, bypass: !!ins\.bypassed, values: values \}\);/,
	'a saved insert keeps its name, stomp state and values');
like($js, qr/var values = \$\.extend\(\{\}, ins\.values \|\| \{\}\);/, 'the values are copied, not shared');
like($js, qr/preset\.chain = studioBoardCapture\(ch, chain\);/, 'a preset keeps the captured chain');
like($js, qr/preset\.used = Date\.now\(\);/, 'saving and loading stamp the recent-use time');

# --- recent use is the data's order ----------------------------------------
like($js, qr/function studioBoardSort\(library\)/, 'one sorter owns the order');
like($js, qr/return \(Number\(b && b\.used\) \|\| 0\) - \(Number\(a && a\.used\) \|\| 0\);/,
	'the sort is newest-used first');
like($js, qr/studioBoardSort\(library\);\s*\n\s*studioBoardPersist\(\);/, 'a save writes the sorted order back');

# --- loading rebuilds the chain --------------------------------------------
like($js, qr/list\.slice\(\)\.forEach\(function \(ins\) \{[\s\S]{0,160}?studioSetInsert\(ch, ins\.name, false, chain\);/,
	'load removes every existing insert in a copied list');
like($js, qr/studioSetInsert\(ch, item\.name, true, chain\);/, 'and adds each saved insert back');
like($js, qr/ins\.set\(control, values\[control\]\)/, 'each saved knob value is restored');
like($js, qr/setBypass\(!!item\.bypass\)/, 'and each saved stomp state');
like($js, qr/studioRackRender\(ch\);\s*\n\s*studioUpdatePedalLamps\(\);\s*\n\s*studioSaver\(\);/,
	'the board is redrawn, its lamps painted and the song saved');
like($js, qr/if \(out && typeof studioEnginePlanTouched === 'function' && studioEnginePlanTouched\(\)\) \{ studioTakesChanged\(\); \}/,
	'an Out chain touches the engine plan once');

# --- the read-only guard ----------------------------------------------------
like($js, qr/function studioBoardReadOnly\(\)/, 'one guard decides whether the board may be written');
like($js, qr/\$\('#pedalboard'\)\.hasClass\('studio_board_readonly'\)/, 'the badge class marks a read-only board');
unlike($js, qr/return \(typeof studioRemoteTarget !== 'undefined' && studioRemoteTarget\) \? true : false;/,
	'a controller is not read-only any more: it edits the peer through pedal commands');
like($js, qr/function studioBoardSave\(\) \{\s*\n\s*if \(studioBoardReadOnly\(\)\) \{ return false; \}/,
	'save refuses on a read-only board');
like($js, qr/function studioBoardLoad\(index\) \{\s*\n\s*if \(studioBoardReadOnly\(\)\) \{ return false; \}/,
	'load refuses on a read-only board');
like($js, qr/studioRemotePedalReplace\(ch, chain, preset\.chain\);/,
	'a controller replays a saved board onto the machine it drives');

# --- deleting a saved board leaves a tombstone ------------------------------
like($js, qr/function studioBoardDelete\(\)/, 'one function owns the delete');
like($js, qr/#studio_board_delete/, 'the delete button is bound');
like($js, qr/preset\.deleted = Date\.now\(\);/, 'a delete stamps the board');
like($js, qr/if \(!item \|\| !item\.name \|\| item\.deleted\) \{ return; \}/,
	'a tombstone is not offered in the dropdown');
like($js, qr/if \(!preset \|\| preset\.deleted \|\| !preset\.chain\) \{ return false; \}/,
	'a tombstone cannot be loaded');
like($js, qr/delete preset\.deleted;/, 'saving a name again revives a tombstone');
like($js, qr/studioBoardDeleteArmed = setTimeout\(studioBoardDeleteReset, 3000\);/,
	'the delete asks twice, three seconds apart');
like($js, qr/preset\.used = Math\.max\(Number\(preset\.used\) \|\| 0, preset\.deleted\);/,
	'a tombstone is as new as its delete for the merge');
like($js, qr/\$\('#studio_board_delete'\)\.addClass\('studio_board_delete_armed'\)/,
	'the armed press says so');

done_testing();
