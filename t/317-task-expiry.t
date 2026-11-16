# tests-for: lib/JawnOS/Domain/Warehouse.pm lib/JawnOS/Domain/Budget2.pm templates/apps/tasks.html.ep perl/language/en.pl
# covers:    A task the routine leaves behind expires after four runs the other
#            tasks were ticked in; ticking it revives it, and Filter offers Expired.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JSON::PP qw(encode_json);
use JawnOSTest;
use RepoSource;

# The tasks page is rendered through Manager's one application object, which a
# test boots itself so task_grabber can build a controller and render.
require Mojolicious;
my $mojo = Mojolicious->new;
$mojo->renderer->paths([ repo_root() . '/templates' ]);
{
	no warnings 'once';
	$Manager::APP = $mojo;
}

my $app = 'task_expiry_probe';
my $now = &subs::rightNow();
my $day = 86400000;
my $seq = 0;

&subs::db_query('delete from appointments where app = ?', $app);
&subs::db_query('delete from settings where app = ?', $app);

sub reset_runs {
	&subs::db_query('delete from appointments where app = ?', $app);
	$seq = 0;
}

sub add_run {
	my ($at, $type) = @_;
	$type ||= 'stop';
	&subs::db_query(
		'insert into appointments (app, timestamp, type, uuid, server_time) values (?,?,?,?,?)',
		$app, $at, $type, $app . '-' . (++$seq), $at
	);
}

sub task {
	my (%over) = @_;
	return {
		uuid           => $over{'uuid'} || 'u',
		task           => $over{'task'} || 't',
		timestamp      => defined $over{'timestamp'} ? $over{'timestamp'} : $now - 30 * $day,
		completed      => defined $over{'completed'} ? $over{'completed'} : 'off',
		last_completed => defined $over{'last_completed'} ? $over{'last_completed'} : $now - 10 * $day,
		renew_freq     => defined $over{'renew_freq'} ? $over{'renew_freq'} : 7200000,
		duration       => 0,
		occurences     => 0,
		colour         => '#000000',
	};
}

sub scan {
	my (@tasks) = @_;
	&subs::task_expiry_scan($app, \@tasks);
	return \@tasks;
}

# --------------------------------------------------------------- four runs
reset_runs();
add_run($now - 1 * $day);
add_run($now - 2 * $day);
add_run($now - 4 * $day);
add_run($now - 5 * $day);

my $tasks = scan(
	task(uuid => 'target', task => 'brushing_beard'),
	task(uuid => 'other', task => 'washing', completed => 'on', last_completed => $now - 3600000),
);
is($tasks->[0]{'expired'}, 1, 'four runs that ticked every other task expire the skipped one');
is($tasks->[1]{'expired'}, undef, 'the task that was ticked is not expired');

# -------------------------------------------------- more than three, not three
reset_runs();
add_run($now - 1 * $day);
add_run($now - 2 * $day);
add_run($now - 4 * $day);
$tasks = scan(
	task(uuid => 'target', task => 'brushing_beard'),
	task(uuid => 'other', task => 'washing', completed => 'on', last_completed => $now - 3600000),
);
is($tasks->[0]{'expired'}, undef, 'three runs are not more than three');

add_run($now - 5 * $day);
$tasks = scan(
	task(uuid => 'target', task => 'brushing_beard'),
	task(uuid => 'other', task => 'washing', completed => 'on', last_completed => $now - 3600000),
);
is($tasks->[0]{'expired'}, 1, 'the fourth run expires it');

# -------------------------------------------------- every other task ticked
reset_runs();
add_run($now - 1 * $day);
add_run($now - 2 * $day);
add_run($now - 4 * $day);
add_run($now - 5 * $day);
$tasks = scan(
	task(uuid => 'target', task => 'brushing_beard'),
	task(uuid => 'other', task => 'washing', completed => 'on', last_completed => $now - 10 * $day),
);
is($tasks->[0]{'expired'}, undef, 'a task whose sibling was also skipped stays open');

# a sibling still inside a long renewal was checked off, not skipped
$tasks = scan(
	task(uuid => 'target', task => 'brushing_beard'),
	task(uuid => 'other', task => 'washing', completed => 'on', last_completed => $now - 20 * $day, renew_freq => 30 * $day),
);
is($tasks->[0]{'expired'}, 1, 'a sibling still inside its renewal does not block expiry');

# --------------------------------------------------------- the revived task
$tasks = scan(
	task(uuid => 'target', task => 'brushing_beard', completed => 'on', last_completed => $now - 12 * 3600000),
	task(uuid => 'other', task => 'washing', completed => 'on', last_completed => $now - 3600000),
);
is($tasks->[0]{'expired'}, undef, 'a task ticked after the last run is not expired then');

# a task created after the runs did not skip them
$tasks = scan(
	task(uuid => 'target', task => 'brushing_beard', timestamp => $now - 2 * 3600000, last_completed => 0),
	task(uuid => 'other', task => 'washing', completed => 'on', last_completed => $now - 3600000),
);
is($tasks->[0]{'expired'}, undef, 'runs before the task existed do not count');

# a usual appointment is a run too
reset_runs();
add_run($now - 1 * $day);
add_run($now - 2 * $day);
add_run($now - 4 * $day, 'usual');
add_run($now - 5 * $day);
$tasks = scan(
	task(uuid => 'target', task => 'brushing_beard'),
	task(uuid => 'other', task => 'washing', completed => 'on', last_completed => $now - 3600000),
);
is($tasks->[0]{'expired'}, 1, 'a usual appointment counts as a run');

# --------------------------------------------------------------- the filter
my @rows = (
	task(uuid => 'target', task => 'brushing_beard'),
	task(uuid => 'other', task => 'washing', completed => 'on', last_completed => $now - 3600000),
);
&subs::db_query(
	'insert into settings (app, setting, value, device, timestamp, server_time) values (?,?,?,?,?,?)',
	$app, 'tasks', encode_json(\@rows), 'computer', $now, $now
);
&subs::db_query(
	'insert into settings (app, setting, value, device, timestamp, server_time) values (?,?,?,?,?,?)',
	$app, 'tasks_filter', 'expired', 'computer', $now, $now
);
my $grab = eval { &subs::task_grabber($app) };
if ($grab) {
	my @shown = grep { ($_->{'uuid'} || '') ne 'new' } @{$grab->{'tasks'}};
	is_deeply([ map { $_->{'uuid'} } @shown ], ['target'], 'the Expired filter shows the expired task');
	is($shown[0]{'completed'}, 'expired', 'the task reads as expired, not open');
}
else {
	fail('task_grabber rendered the expired filter') or diag($@);
}

# ------------------------------------------------------- the option and label
my $root = repo_root();
like(read_file("$root/templates/apps/tasks.html.ep"), qr/qw\/all open done expired\//,
	'Filter offers Expired beside All, Open and Done');
like(read_file("$root/lib/JawnOS/Domain/Warehouse.pm"), qr/tasks_filter eq 'expired'/,
	'the expired filter has its own branch');
like(read_file("$root/lib/JawnOS/Domain/Budget2.pm"), qr/!\$_->\{'expired'\} && \$_->\{'task'\}/,
	'the evaluation prompt does not call an expired task open');

my @missing = grep { !defined $language::catalog{$_}{'expired'} || $language::catalog{$_}{'expired'} eq 'expired' }
	map { $_->{'code'} } @language::languages;
is_deeply(\@missing, [], 'Expired is a core label in all sixteen languages')
	or diag('missing: ' . join(', ', @missing));

done_testing();
