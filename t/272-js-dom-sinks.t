# tests-for: public/js/manager/websocket/02_heartbeat_and_reload.js public/js/manager/windows.js public/js/manager/budget.js public/js/manager/configure/02_remote_devices.js lib/JawnOS/Controller/manager_ws.pm
# covers:    The controller, the taskbar and a budget tooltip paint text the
#           client chose: a heartbeat's pathname/room/user agent and the names
#           of its windows, a window's label, an account name and a pseudonym.
#           Each sink now escapes or builds text, and the neighbour window
#           button carries data attributes instead of an onClick call.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource qw(repo_root);

my $root = repo_root();

sub source {
	my ($rel) = @_;
	return read_file("$root/$rel");
}

my $heartbeat = source('public/js/manager/websocket/02_heartbeat_and_reload.js');
my $windows   = source('public/js/manager/windows.js');
my $budget    = source('public/js/manager/budget.js');
my $remote    = source('public/js/manager/configure/02_remote_devices.js');
my $ws        = source('lib/JawnOS/Controller/manager_ws.pm');

# --- the heartbeat escapes every field it paints ----------------------------
like($heartbeat, qr{function hbEscape\(value\)},
	'the heartbeat has one escape helper');
like($heartbeat, qr{\.replace\(/"\/g, '&quot;'\)},
	'and it escapes a double quote, because the fields ride attributes too');

for my $field (qw(pathname room user_agent local_address remote_address browser_tab_id)) {
	like($heartbeat, qr{hbEscape\(n\.$field\)},
		"a neighbour's $field is escaped");
}

like($heartbeat, qr{hbEscape\(value\['app'\]\)}, "a neighbour window's app is escaped");
like($heartbeat, qr{hbEscape\(value\['formatted_name'\]\)},
	"a neighbour window's formatted name is escaped");
like($heartbeat, qr{hbEscape\(value\['shorthand_name'\]\)},
	"a neighbour window's shorthand name is escaped");

for my $field ('title.image', 'file', 'title.artist', 'title.album', 'title.song', 'title.playing') {
	like($heartbeat, qr{hbEscape\(md\.\Q$field\E\)},
		"the music beat's $field is escaped");
}
like($heartbeat, qr{hbEscape\(jv\.image\)}, "the server beat's preview image is escaped");
like($heartbeat, qr{hbEscape\(data\.app\)}, "the everything bar's app is escaped");
like($heartbeat, qr{hbEscape\(format_name\(data\.app\)\)},
	"the everything bar's label is escaped after format_name");

# The app and the timestamp travel as attributes; a delegated handler reads
# them. No call is written into markup any more.
like($heartbeat, qr{data-app="' \+ hbEscape},
	'a neighbour window carries its app as a data attribute');
like($heartbeat, qr{'\.neighbour_window, \.heartbeating\.everything'},
	'one delegated handler answers both neighbour buttons');
unlike($heartbeat, qr{onClick=}, 'no inline appointment call is written into markup');

unlike($heartbeat, qr{\+\s*n\.pathname\s*\+}, 'no raw pathname reaches the neighbour markup');
unlike($heartbeat, qr{\+\s*n\.room\s*\+}, 'no raw room reaches the neighbour markup');
unlike($heartbeat, qr{\+\s*value\['app'\]\s*\+}, 'no raw window app reaches the markup');
unlike($heartbeat, qr{\+\s*value\['shorthand_name'\]},
	'no raw window name reaches the markup');
unlike($heartbeat, qr{\+\s*format_name\(data\.app\)\s*\+},
	'no raw formatted app name reaches the markup');

# The server template is server-rendered markup; it stays as it was.
like($heartbeat, qr{\+\s*data\['template'\]\s*\+},
	'the server-rendered template still rides as HTML');

# --- the taskbar does not re-inject decoded text ----------------------------
like($windows, qr{\.text\(windows\[id\]\['formatted_name'\] \|\| ''\)},
	'a window top bar is built as text');
unlike($windows, qr{wind\.html\(top_bar\)}, 'the top bar is no longer parsed from a string');

like($windows, qr{\.attr\('formatted_name', named\)},
	'a taskbar tile takes its name as an attribute');
like($windows, qr{\.text\(named\)}, 'and paints its label as text');
like($windows, qr{\.text\(shorthand_name\(named, 5\)\)},
	'and its shorthand as text');
like($windows, qr{\.text\(\$\(v\)\.attr\('formatted_name'\) \|\| ''\)},
	'the start menu label is text too');

unlike($windows, qr{formatted_name="' \+ named}, 'no name is concatenated into an attribute');
unlike($windows, qr{window_toggle_name_text">' \+ named}, 'no name is concatenated into a label');
unlike($windows, qr{<b>' \+ \$\(v\)\.attr\('formatted_name'\)},
	'the start menu does not concatenate the name into markup');

# --- the budget tooltip escapes the account name ----------------------------
like($budget, qr{function budgetTipEscape\(value\)}, 'the tooltip has an escape helper');
like($budget, qr{budgetTipEscape\(format_name\(name\)\)},
	'the account name is escaped before it joins the tooltip');
unlike($budget, qr{format_name\(name\) \+ '<b>'}, 'no raw account name reaches the tooltip');
like($budget, qr{budgetMoneyFull\(value\) \+ '</b></div>'},
	'the money formatting is unchanged');

# --- the pseudonym confirmation is text and an attribute --------------------
like($remote, qr{\.text\('Are you sure you want to change the pseudonym: ' \+ name},
	'the confirmation sentence is built as text');
like($remote, qr{\.attr\('pseudonym_name', name\)},
	'the submit button carries the pseudonym as an attribute');
like($remote, qr{\.empty\(\)\.append\(message, }, 'the confirmation is appended as DOM');
unlike($remote, qr{\$\('#alert_message'\)\.html\('Are you sure},
	'the confirmation is not built by concatenating HTML');
unlike($remote, qr{pseudonym_name="' \+ name}, 'no raw pseudonym reaches an attribute');

# --- the server drops angle brackets from what it stores and relays ---------
like($ws, qr{my \$pathname = \$data->\{'pathname'\}; \$pathname =~ s/\[<>\]//g if defined \$pathname},
	'a stored pathname loses the two angle brackets');
like($ws, qr{pathname => \$pathname\n}, 'the stored row uses the sanitized pathname');
like($ws, qr{\$n->\{'pathname'\} =~ s/\[<>\]//g if defined \$n->\{'pathname'\}},
	'a relayed pathname loses the two angle brackets');
like($ws, qr{\$n->\{'room'\} =~ s/\[<>\]//g if defined \$n->\{'room'\}},
	'a relayed room loses the two angle brackets');
unlike($ws, qr{ws_plain_name}, 'no file-scoped sanitizer remains above the actions');

# The device action's route row pins it to a line of this file; the helper that
# used to sit above it is what broke the push. Keep the line honest here too.
my @ws_lines = split /\n/, $ws;
like($ws_lines[765] || '', qr{^sub action_766\b},
	'the device action still sits on its route row line');

# --- the escape helper really escapes, when node is here --------------------
my ($node) = map { "$_/node" } grep { -x "$_/node" } split /:/, ($ENV{'PATH'} // '');
my ($hb_fn) = $heartbeat =~ /(function hbEscape\(value\) \{.*?\n\})/s;
ok($hb_fn, 'the heartbeat escape helper can be read out of the source');

SKIP: {
	skip 'node is not installed', 1 unless $node && $hb_fn;

	my ($fh, $file) = tempfile(SUFFIX => '.js', UNLINK => 1);
	my $script = 'var $ = function () {'
		. ' var v = "";'
		. ' var api = {'
		. '  text: function (x) { v = String(x); return api; },'
		. '  html: function () { return v.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }'
		. ' };'
		. ' return api;'
		. ' };'
		. "\n" . $hb_fn . "\n"
		. 'var out = hbEscape("<svg/onload=\"alert(1)\">");'
		. 'var ok = out.indexOf("<") === -1 && out.indexOf(">") === -1 && out.indexOf("\"") === -1;'
		. 'if (!ok) { console.log("BAD " + out); process.exit(1); }'
		. 'console.log("OK " + out);';
	print {$fh} $script;
	close $fh;

	my $out = '';
	if (open(my $pipe, '-|', $node, $file)) {
		local $/;
		$out = <$pipe> // '';
		close $pipe;
	}
	chomp $out;
	like($out, qr{\AOK }, 'the helper escapes markup and quotes');
}

done_testing();
