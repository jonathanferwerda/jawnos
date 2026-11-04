# tests-for: templates/start_menu/start_menu.html.ep public/js/manager/manager/10_appointment_edit.js public/css/manager.css lib/JawnOS/Domain/Misc.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_misc4.pm lib/JawnOS/Routes/manager_misc4.pm lib/JawnOS/Manager/Part33.pm perl/subroutines.pl lib/JawnOS/Domain/Crest.pm qa/lib/Probe.pm perl/language.pl perl/help/topics_features.pl
# covers:    the Leave button's power menu: Exit keeps the old leave, a computer may also restart, shut down or sleep, and a handheld offers Exit alone.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib", "$FindBin::Bin/../qa/lib", "t/lib", "qa/lib", "lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use JawnOSTest;
use Probe;

my $ROOT = root();

# The Leave button used to leave on the first press. It now opens a dialog:
# Exit is the old leave (seal the database, close the session), and a machine
# that can power itself also offers Restart, Shut down and Sleep. The phone's
# app cannot power the phone, so subs::power_actions() answers with nothing
# there and the dialog shows Exit alone.

# --- what this machine can do ------------------------------------------------
# A fake systemctl makes the probe and the command deterministic and safe: no
# real systemd is asked to do anything, and the test records the argv instead.
my $bin = tempdir(CLEANUP => 1);
my $log = "$bin/power.log";
my $tool = "$bin/systemctl";
write_file($tool, "#!/bin/sh\nprintf '%s\\n' \"\$*\" >> \"\$POWER_LOG\"\nexit 0\n");
chmod 0755, $tool;
local $ENV{PATH} = "$bin:$ENV{PATH}";
local $ENV{POWER_LOG} = $log;

{
	local $subs::config = { device => 'mobile' };
	local %subs::power_actions_cache = ();
	is_deeply([ subs::power_actions() ], [],
		'a phone app offers no power choice: it cannot power its own phone');
	my $r = subs::power_action('restart');
	is($r->{'ok'}, 0, 'a mobile action is refused even when a power tool is on the path');
	is($r->{'error'}, 'unsupported', 'and says why');
	is(-e $log ? read_file($log) : '', '', 'nothing was run for the phone');
}

{
	local $subs::config = { device => 'computer' };
	local %subs::power_actions_cache = ();
	is_deeply([ subs::power_actions() ], [ qw(restart shutdown sleep) ],
		'a computer with systemd offers restart, shut down and sleep');

	my %want = ( restart => 'reboot', shutdown => 'poweroff', sleep => 'suspend' );
	for my $action ( sort keys %want ) {
		write_file($log, '');
		my $r = subs::power_action($action);
		is($r->{'ok'}, 1, "$action is accepted");
		is($r->{'action'}, $action, "$action comes back named");
		is(read_file($log), "--no-block $want{$action}\n",
			"$action asks systemd for $want{$action} without blocking the reply");
	}

	write_file($log, '');
	my $bad = subs::power_action('exit');
	is($bad->{'ok'}, 0, 'Exit is not a power action: it is the leave route');
	is(read_file($log), '', 'and nothing reaches systemd');

	my $bogus = subs::power_action('rm -rf /');
	is($bogus->{'error'}, 'unsupported', 'the action is a whitelist, not a command');
	is(read_file($log), '', 'an unknown word runs nothing');
}

# --- the route, its action and its tier --------------------------------------
my $routes = read_file("$ROOT/lib/JawnOS/Routes/manager_misc4.pm");
like($routes, qr/\[\s*20001\s*,\s*'post'\s*,\s*'\/manager\/power'\s*,\s*'action_20001'\s*\]/,
	'the power route is in the table');
my $controller = read_file("$ROOT/lib/JawnOS/Controller/manager_misc4.pm");
like($controller, qr/^sub action_20001\b/m, 'the power route has its action');
like($controller, qr/'privilege'\) \|\| ''\) eq 'citizen'/, 'the action locks itself to a citizen');
like($controller, qr/&subs::power_action\(\$c->param\('action'\)\)/, 'it passes the fixed action word on');

is(subs::tier_needed('/manager/power'), 'citizen', 'the tier table calls the power route citizen');
is(Probe::tier_needed('/manager/power'), 'citizen', 'the QA mirror agrees');

# --- the start menu renders the choices this machine really has --------------
my $template = read_file("$ROOT/templates/start_menu/start_menu.html.ep");
like($template, qr/my \@leave_power = &subs::power_actions\(\)/, 'the menu asks what this machine can do');
like($template, qr{power="<%= join ',', \@leave_power %>"},
	'the Leave icon carries the list');
like($template, qr/hint="<%= &subs::lang\('power_leave'\) %>"/, 'the hint is a translated core label');

my $js = read_file("$ROOT/public/js/manager/manager/10_appointment_edit.js");
like($js, qr/jawnosLeaveMenu\(\$\(this\)\)/, 'a press on Leave opens the menu, it does not leave at once');
like($js, qr/data-leave-action/, 'each choice carries its action');
like($js, qr/url:\s*'\/manager\/power'/, 'the power choices post to the power route');
like($js, qr/jawnosAlert\(/, 'the menu is the house dialog, not a browser prompt');

my $css = read_file("$ROOT/public/css/manager.css");
like($css, qr/\.leave_power_menu\b/, 'the power menu has its grid');
like($css, qr/\.leave_power_button\b/, 'and its big-button face');

# --- the live image's loopback session is the house --------------------------
# Configure and Security are citizen desks. The live image's own loopback
# session was minted resident, so the wrench opened a denial page on VM 103.
my $part33 = read_file("$ROOT/lib/JawnOS/Manager/Part33.pm");
my ($live_block) = $part33 =~ /(if \(\$live_local && .*?\n\t\})/s;
ok(defined $live_block, 'the live-local session block is still where it was');
like($live_block, qr/'privilege' => 'citizen'/, 'the person at a live machine is a citizen');
unlike($live_block, qr/'privilege' => 'resident'/, 'and no longer a resident, which Configure refused');
like($part33, qr/forever warranty, so a cookie minted/, 'an existing live-local cookie is upgraded too');
like($part33, qr/\$c->session\('privilege' => 'citizen'\);/, 'the upgrade writes the same citizen privilege');

# --- the labels exist in every interface language ----------------------------
for my $lang ( @language::languages ) {
	my $code = $lang->{'code'};
	for my $key ( qw(power_leave power_exit power_restart power_shutdown power_sleep) ) {
		my $word = language::translate($code, $key);
		isnt($word, $key, "$code translates $key");
	}
}

# --- the help topic teaches the new press ------------------------------------
my $help = read_file("$ROOT/perl/help/topics_features.pl");
like($help, qr/Restart, Shut down and Sleep/, 'the start menu topic names the four choices');
like($help, qr/Exit alone/, 'and says a handheld shows Exit alone');

done_testing();
