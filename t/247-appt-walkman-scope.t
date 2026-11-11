# tests-for: public/js/manager/manager.js public/js/manager/manager/10_appointment_edit.js public/js/manager/keyboard/02_music_and_handlers.js templates/apps/clock/machine.html.ep templates/layouts/manager.html.ep perl/help/topics_features.pl
# covers:    An appointment window's reverse/forward walkman walks only the app
#            whose record it sits under: the app's details are read at that
#            moment and the house's time machine is left where it stands. The
#            walkman's Configure carries a tick that brings the old behaviour
#            back and carries the whole view there.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $manager = read_file("$root/public/js/manager/manager.js");
my $edit    = read_file("$root/public/js/manager/manager/10_appointment_edit.js");
my $maker   = read_file("$root/public/js/manager/keyboard/02_music_and_handlers.js");
my $config  = read_file("$root/templates/apps/clock/machine.html.ep");
my $layout  = read_file("$root/templates/layouts/manager.html.ep");
my $help    = read_file("$root/perl/help/topics_features.pl");

# --- the walkman's default is the app alone ---------------------------------
like($manager, qr/function jawnosApptWalkmanGlobal\(\) \{/,
	'the walkman asks one helper whether it owns the global clock');
like($manager, qr/jawnos_bar_settings\['appt_walkman_global'\] === 'checked'/,
	'the helper reads the keyboard setting seeded by the layout');
like($manager, qr/if \(jawnosApptWalkmanGlobal\(\)\) \{\s*\$\('#time_machine'\)\.val\(response\.date\);\s*localStorage\.setItem\('time_machine',response\.date\);/s,
	'the global clock moves only in the ticked branch');
like($manager, qr/appointmentDetailsGrabber\(j, undefined, response\.date\);/,
	'unticked, only this app reads its details at that moment');
like($manager, qr/j\.attr\('timestamp',response\.new_timestamp\);\s*j\.closest\('\.walkman_controls'\)\.find\('\.time_jump'\)\.attr\('timestamp',response\.new_timestamp\);\s*if \(jawnosApptWalkmanGlobal\(\)\)/s,
	'both branches walk the buttons on to the next record first');

# --- the details reader can take a moment of its own ------------------------
like($edit, qr/function appointmentDetailsGrabber\(a,source,time_machine_override\)/,
	'the details reader takes an optional time machine');
like($edit, qr/typeof time_machine_override == 'undefined' \|\| time_machine_override === null\) \? localStorage\.getItem\('time_machine'\) : time_machine_override/,
	'it falls back to the house clock only when the walkman names no moment');

# --- the tick in the walkman's Configure ------------------------------------
like($config, qr/setting_grabber\(\{ app => 'keyboard', setting => 'appt_walkman_global' \}\)/,
	'the tick reads its own setting');
like($config, qr/<input type="checkbox" id="appt_walkman_global"/,
	'the panel carries the tick');
like($config, qr/&subs::ui\('Appt walkman controls global time'\)/,
	'and says what the tick does in the on-screen words');
like($maker, qr/\$\(document\)\.on\('change', '#appt_walkman_global'/,
	'the tick saves on change');
like($maker, qr/settingSetter\(\{ 'app': 'keyboard', 'setting': 'appt_walkman_global', 'value': value \}\)/,
	'it keeps the choice for this device');
like($maker, qr/jawnos_bar_settings\['appt_walkman_global'\] = value;/,
	'and the next press obeys before the panel is rebuilt');
like($layout, qr/appt_walkman_global: '<%= &subs::setting_grabber\(\{ app => 'keyboard', setting => 'appt_walkman_global' \}\) \|\| 'unchecked' %>'/,
	'the page seeds the tick, unticked on a fresh install');

# --- the guide says so ------------------------------------------------------
like($help, qr/walk that app alone: its details are read at the previous or next record while the house\\'s time machine stays where it is/,
	'the guide describes the app-alone walk');
like($help, qr/Tick Appt walkman controls global time in the walkman\\'s Configure/,
	'and names the tick that restores the global walk');

# --- the scripts still parse ------------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	for my $file (qw(
		public/js/manager/manager.js
		public/js/manager/manager/10_appointment_edit.js
		public/js/manager/keyboard/02_music_and_handlers.js
	)) {
		my $out = `$node --check "$root/$file" 2>&1`;
		is($? >> 8, 0, "$file parses") or diag($out);
	}
}
else {
	diag('node is not on this machine; skipped the parse check');
}

done_testing();
