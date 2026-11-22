# tests-for: lib/JawnOS/Domain/VacationKeep.pm templates/configure/away_keep.html.ep public/js/manager/configure/12_vacation_keep.js lib/JawnOS/Routes/manager_vacation_keep.pm lib/JawnOS/Controller/manager_vacation_keep.pm
# covers:    the keep list on the Away card: which apps the card offers for
#            budgets, routines and notices; that an app can be put into and out
#            of a list; that the saved policy is what the budget, alarm and
#            notification readers will see; and that the partial and its script
#            name the route that saves the choice.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempfile);
use File::Slurp qw(read_file);
use Mojo::SQLite;
use JawnOSTest;

my $now = ts(2026, 11, 15, 12, 0, 0);

my ($fh, $dbfile) = tempfile('jawnos-vacation-keep-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, id integer primary key autoincrement, app text, server_time text, device text, browser_tab_id text, uuid text, ost text, subsetting text)');
$db->query('create table appointments (app text, timestamp text, stop_timestamp text, type text, duration text, total text, quantity text, measures text, source text, uuid text, server_time text, stop_seen text, seen text)');
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;

# Loaded directly: the Loader row is wired by the main change that includes the
# partial, and these subs must work before that row exists.
require 'JawnOS/Domain/VacationKeep.pm';

# --- the house the card reads -----------------------------------------------
$db->query('insert into settings (setting, value, app, device, server_time) values (?,?,?,?,?)',
	'budget', '10h/week', 'walk', 'all', $now);
$db->query('insert into settings (setting, value, app, device, server_time) values (?,?,?,?,?)',
	'tasks', 'dishes|laundry', 'chores', 'all', $now);
$db->query('insert into settings (setting, value, app, device, server_time) values (?,?,?,?,?)',
	'notification', 'on', 'market', 'all', $now);
$db->query('insert into settings (setting, value, app, device, server_time) values (?,?,?,?,?)',
	'notification', 'off', 'library', 'all', $now);
$db->query('insert into appointments (app, timestamp, type, source, uuid, server_time) values (?,?,?,?,?,?)',
	'garden', $now, 'start', 'schedule', 'schedule-1', $now);

# --- candidates -------------------------------------------------------------
is_deeply(&subs::vacation_keep_candidates('budgets'), ['walk'],
	'a budgeted app is offered for the budget keep list');

is_deeply(&subs::vacation_keep_candidates('routines'), [ 'chores', 'garden' ],
	'a scheduled app and a task list are both routines');

is_deeply(
	&subs::vacation_keep_candidates('notifications'),
	[ 'access', 'box_office', 'customs', 'gate', 'market', 'phone', 'security' ],
	'the on-notice apps and the default notices are offered; an off one is not',
);
ok(!grep({ $_ eq 'library' } @{ &subs::vacation_keep_candidates('notifications') }),
	'a notice switched off is not offered');

is_deeply(&subs::vacation_keep_candidates('unknown'), [], 'an unknown kind offers nothing');

# --- rows -------------------------------------------------------------------
my $rows = &subs::vacation_keep_rows();
my %row = map { $_->{'app'} => $_ } @{$rows};
is(scalar @{$rows}, 10, 'the rows are the union of every candidate list');
is($row{'box_office'}->{'formatted_name'}, 'Box Office', 'a row carries the name a person reads');
is($row{'box_office'}->{'notifications'}, 1, 'a default notice starts kept');
is($row{'market'}->{'notifications'}, 0, 'a saved notice is not kept until it is ticked');
is($row{'walk'}->{'budgets'}, 0, 'a budget starts outside the list');
is($row{'garden'}->{'routines'}, 0, 'a routine starts outside the list');

# --- budgets ----------------------------------------------------------------
my $lists = &subs::vacation_keep_toggle('walk', 'budgets', 'on');
is_deeply($lists->{'budgets'}, ['walk'], 'ticking a budget puts it on the keep list');
my $saved = &subs::vacation_settings();
is_deeply($saved->{'policy'}->{'keep_apps'}->{'budgets'}, ['walk'],
	'the keep list is saved under policy.keep_apps');
is(&subs::vacation_policy_for('walk', 'duration', 'floor', 0), 'count',
	'a kept budget keeps counting while away');

$lists = &subs::vacation_keep_toggle('walk', 'budgets', 'off');
is_deeply($lists->{'budgets'}, [], 'unticking a budget takes it off the keep list');
is(&subs::vacation_policy_for('walk', 'duration', 'floor', 0), 'prorate',
	'a budget off the list is prorated again');

# --- routines ---------------------------------------------------------------
$lists = &subs::vacation_keep_toggle('garden', 'routines', 'on');
is_deeply($lists->{'routines'}, ['garden'], 'ticking a routine puts it on the keep list');
$saved = &subs::vacation_settings();
is_deeply($saved->{'policy'}->{'keep_apps'}->{'routines'}, ['garden'],
	'the routine keep list is saved');
$lists = &subs::vacation_keep_toggle('garden', 'routines', 'off');
is_deeply($lists->{'routines'}, [], 'unticking a routine takes it off the keep list');

# --- notices ----------------------------------------------------------------
my @defaults = qw(security customs phone access gate box_office);
$lists = &subs::vacation_keep_toggle('market', 'notifications', 'on');
ok(grep({ $_ eq 'market' } @{ $lists->{'notifications'} }), 'ticking a notice adds it to the keep list');
$saved = &subs::vacation_settings();
ok(grep({ $_ eq 'market' } @{ $saved->{'policy'}->{'keep_apps'}->{'notifications'} }),
	'the notice keep list is saved');
$lists = &subs::vacation_keep_toggle('market', 'notifications', 'off');
is_deeply($lists->{'notifications'}, \@defaults,
	'unticking a notice removes only that app and leaves the defaults');

# --- a duplicate tick does not double the row -------------------------------
&subs::vacation_keep_toggle('walk', 'budgets', 'on');
$lists = &subs::vacation_keep_toggle('walk', 'budgets', 'on');
is_deeply($lists->{'budgets'}, ['walk'], 'a repeated tick is deduplicated');
&subs::vacation_keep_toggle('walk', 'budgets', 'off');

# --- refusals ---------------------------------------------------------------
ok(!defined &subs::vacation_keep_toggle('__president', 'budgets', 'on'),
	'the house itself is never put on a keep list');
ok(!defined &subs::vacation_keep_toggle('walk', 'unknown', 'on'),
	'an unknown kind is refused');
ok(!defined &subs::vacation_keep_toggle('', 'budgets', 'on'),
	'an empty app is refused');

# --- the partial and its script --------------------------------------------
my $root = $FindBin::Bin . '/..';
my $partial = read_file("$root/templates/configure/away_keep.html.ep");
like($partial, qr/class="away_keep_toggle"/, 'the partial renders keep toggles');
like($partial, qr/kind="budgets"/, 'the partial has the budget group');
like($partial, qr/kind="routines"/, 'the partial has the routine group');
like($partial, qr/kind="notifications"/, 'the partial has the notice group');
like($partial, qr/Keep running while away/, 'the partial names the section');

my $js = read_file("$root/public/js/manager/configure/12_vacation_keep.js");
like($js, qr{/manager/vacation/keep}, 'the script posts to the keep route');
like($js, qr/away_keep_toggle/, 'the script watches the keep toggles');
like($js, qr/jawnosAwayReload/, 'the script reloads the Away card through the shared helper');

done_testing();
