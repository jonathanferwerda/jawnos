# tests-for: templates/embedded/body.html.ep public/js/manager/embedded.js public/js/manager/embedded/02_board_pins.js public/js/manager/embedded/03_remotes.js perl/help/topics_configure.pl
# covers:    the IR remotes panel under a board's GPIO view - the five routes it
#            calls, the 5000 ms learn default, naming a pending capture, the IR
#            parts offered when attaching a discovered pin, and the words the
#            help topic uses for it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $read = sub { scalar read_file("$root/$_[0]") };

my $template = $read->('templates/embedded/body.html.ep');
my $js       = $read->('public/js/manager/embedded/03_remotes.js');
my $pins     = $read->('public/js/manager/embedded/02_board_pins.js');
my $help     = $read->('perl/help/topics_configure.pl');

# --- the panel sits under the board's GPIO list -----------------------------
like($template, qr/id="embedded_ir_panel"/, 'the GPIO view carries an IR remotes panel');
like($template, qr/id="embedded_ir_list"/, 'with a place to draw the learned remotes');
like($template, qr/id="embedded_ir_status"/, 'and a line for what just happened');
like($template, qr/id="embedded_ir_learn_pin"[^>]*min="0"[^>]*max="29"/,
	'the receiver pin input is bounded to 0 to 29');
like($template, qr/id="embedded_ir_learn_ms"[^>]*min="500"[^>]*max="10000"[^>]*value="5000"/,
	'the learn window defaults to 5000 ms and is bounded');
like($template, qr/id="embedded_ir_learn_button"/, 'the panel has a Learn button');
like($template, qr/id="embedded_ir_refresh"/, 'and a Refresh button');

for my $phrase ('IR remotes', 'Receiver pin', 'Learn window (ms)', 'Learn', 'Refresh') {
	like($template, qr/&subs::ui\('\Q$phrase\E'\)/,
		"the template translates '$phrase'");
}

# --- the panel calls each of the five routes --------------------------------
for my $route (qw(remotes remote_learn remote_save remote_send remote_delete)) {
	like($js, qr{'/manager/embedded/\Q$route\E'}, "the panel calls $route");
}
like($js, qr{url: '/manager/embedded/remotes',\s*type: 'GET'}s,
	'reading the list is a GET');
for my $route (qw(remote_learn remote_save remote_send remote_delete)) {
	like($js, qr{url: '/manager/embedded/\Q$route\E',\s*type: 'POST'}s,
		"$route is a POST");
}
like($js, qr/edt: 'microcontroller'/, 'the panel speaks as the microcontroller');
like($js, qr/embeddedChipId\(\)/, "it asks the page for the board's current chip");

# --- a learn polls for the capture the board posts back ---------------------
like($js, qr/embeddedIrPoll\(before, 12, pin\)/,
	'a learn polls for about twelve seconds');
like($js, qr/\}, 1000\);/, 'once a second');
like($js, qr/ms < 500 \|\| ms > 10000/,
	'a window outside 500 to 10000 ms is refused visibly');
like($js, qr/entry\.pending/, 'a pending capture is recognised');
like($js, qr/\.embedded_ir_name/, 'a pending capture gets a box to name it');

# The pending key is dropped only after the typed name has stored the same
# capture. Read the save handler, not the whole file: remote_delete also has a
# handler of its own.
my ($save_handler) = $js =~ /(\$\(document\)\.on\('click', '\.embedded_ir_save'.*?\n\}\);)/s;
ok($save_handler, 'the Save handler is one block');
my $save_at = index($save_handler, '/manager/embedded/remote_save');
my $drop_at = index($save_handler, '/manager/embedded/remote_delete');
ok($save_at >= 0 && $drop_at > $save_at,
	'the pending key is deleted only after the typed name saves');
like($js, qr/if \(embeddedIrRemotes\[typed\]\)/,
	'saving over an existing name is refused instead of overwriting it');

# A name is user text: it rides a data attribute, never an id.
like($js, qr/\.attr\('data-name', name\)/, 'a remote name rides a data attribute');
unlike($js, qr/\.attr\('id',[^)]*name/, 'no id is built from a remote name');

# --- the attach chooser offers the IR parts ---------------------------------
like($pins, qr/var choices = \[[^\]]*'irtx'[^\]]*'irrx'\]/,
	'the component chooser offers irtx and irrx');
like($pins, qr/pin_kind === 'grounded'\) \{ preferred = 'button'; \}/,
	'a grounded input pin still prefers a button');
like($pins, qr/pin_kind === 'high'\) \{ preferred = 'switch'; \}/,
	'a tied-high pin still prefers a switch');

# --- every new user string is translatable ----------------------------------
my @strings = (
	'No remotes learned yet.', 'GPIO', 'transitions', 'Name this remote',
	'Save', 'Send', 'Delete',
	'Give the remote a name first.', 'That remote already has this name.',
	'A remote with that name already exists.',
	'Could not save the remote.', 'Saved', 'Saved, but the pending capture could not be removed.',
	'Could not send the remote.', 'Could not reach the board to send', 'Sent',
	'Could not delete the remote.', 'Deleted',
	'Choose a board first.', 'The receiver pin must be 0 to 29.',
	'The learn window must be 500 to 10000 ms.', 'for', 'ms',
	'Asking the board to listen on GPIO', 'Listening on GPIO',
	'Could not start the learn window.', 'The board did not answer.',
	'Check that it is connected.', 'Nothing arrived from the board.',
	'Press Learn again, then press a button on the remote.',
	'Learned a capture on GPIO', 'Name it, then press Save.',
	'Choose a board to see its remotes.', 'Could not read the remotes.',
);
for my $string (@strings) {
	like($js, qr/(?:embeddedBoardText|jawnosT)\(\s*'\Q$string\E'\s*\)/,
		"the panel translates '$string'");
}

# --- the help topic speaks in the same words --------------------------------
like($help, qr/\$topic\{'embedded'\} = \{/s, 'the embedded topic is still there');
like($help, qr/app => 'embedded'/, 'and still names the app');
like($help, qr/IR remotes have their own panel/, 'the topic describes the panel');
like($help, qr/Set the Receiver pin and the Learn window \(ms\), press Learn/,
	'in the labels on the screen');
like($help, qr/name the capture and press Save to keep it/,
	'and the step a person takes to keep a capture');
like($help, qr/Press Send on a learned IR remote to replay it, or Delete to remove it/,
	'including replay and delete');

done_testing();
