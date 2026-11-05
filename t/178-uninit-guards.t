# tests-for: lib/JawnOS/Domain/Log.pm lib/JawnOS/Controller/manager_misc3.pm lib/JawnOS/Domain/Remote.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Budget.pm lib/JawnOS/Domain/Headless.pm lib/JawnOS/Domain/Name.pm lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Generate.pm lib/JawnOS/Domain/File.pm lib/JawnOS/Controller/Root_misc.pm lib/JawnOS/Domain/Warehouse.pm public/js/manager/websocket/03_watchdog.js
# covers:    every optional row field these warnings came from is compared
#            with a defined default. A row that lacks the column used to write
#            a warning per call (26,662 in one phone log); the comparison now
#            treats the missing value as the empty string or zero, which is
#            what it already evaluated to without the warning. The watchdog
#            also probes twice before it rebuilds the sockets.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Slurp qw(read_file);

my $root = abs_path("$FindBin::Bin/..");

my %src;
foreach my $f (qw(
	lib/JawnOS/Domain/Log.pm
	lib/JawnOS/Controller/manager_misc3.pm
	lib/JawnOS/Domain/Remote.pm
	lib/JawnOS/Domain/Calendar.pm
	lib/JawnOS/Domain/Budget.pm
	lib/JawnOS/Domain/Headless.pm
	lib/JawnOS/Domain/Name.pm
	lib/JawnOS/Domain/Appointment.pm
	lib/JawnOS/Domain/Generate.pm
	lib/JawnOS/Domain/File.pm
	lib/JawnOS/Controller/Root_misc.pm
	lib/JawnOS/Domain/Warehouse.pm
	public/js/manager/websocket/03_watchdog.js
)) {
	$src{$f} = read_file("$root/$f");
}

sub has     { my ($f, $n) = @_; return index($src{$f}, $n) >= 0 ? 1 : 0 }
sub has_not { my ($f, $n) = @_; return index($src{$f}, $n) < 0  ? 1 : 0 }

# Log: the sort selector, a duration that was never computed, and 'NaN'
ok(has('lib/JawnOS/Domain/Log.pm', "(\$sorts || '') eq 'server_time'"),
	'the log sort selector defaults to an empty string');
ok(has_not('lib/JawnOS/Domain/Log.pm', "\$sorts eq 'server_time'"),
	'and the bare comparison is gone');
ok(has('lib/JawnOS/Domain/Log.pm', "abs((\$a->{'duration'} || 0)) / 1000"),
	'a missing duration is formatted as zero, not as undef');
ok(has('lib/JawnOS/Domain/Log.pm', "(\$a->{'duration'} || '') eq 'NaN'"),
	'the NaN check tolerates a missing duration');

# The sync rail: a peer request carries no session
ok(has('lib/JawnOS/Controller/manager_misc3.pm', "(\$c->session('authentication') || '') eq 'approved'"),
	'the sync routes treat a session-less peer request as not approved');
ok(has_not('lib/JawnOS/Controller/manager_misc3.pm', "\$c->session('authentication') eq 'approved'"),
	'and no sync route compares the raw session');

# Remote: a relay that names no override, and a probe that names no auth test
ok(has('lib/JawnOS/Domain/Remote.pm', "(\$c->param('remoted') || '') eq 'yes'"),
	'a missing remoted flag is not a warning');
ok(has('lib/JawnOS/Domain/Remote.pm', "(\$extra_params->{'override'} || '') eq 'manual'"),
	'a missing override is not a warning');
ok(has('lib/JawnOS/Domain/Remote.pm', "my \$auth_test = \$data->{'auth_test'} || '';"),
	'a missing auth test names the empty string');

# Calendar: the optional stop and duty times
ok(has('lib/JawnOS/Domain/Calendar.pm', "defined \$next_appt->{'stop_timestamp'} && \$next_appt->{'stop_timestamp'} >= \$last_moment"),
	'a row with no stop time is skipped by the next-values scan');
ok(has('lib/JawnOS/Domain/Calendar.pm', "defined \$next_appt->{'next_duty'} && \$next_appt->{'next_duty'} >= \$last_moment"),
	'and so is a row with no next duty');

# Budget: a cached window that has not been built yet
ok(has('lib/JawnOS/Domain/Budget.pm', "->{'timestamp'} || 0) == \$timestamp"),
	'an unbuilt budget window compares as zero');

# Headless: a navigation row with no placement, and a cache flag
ok(has('lib/JawnOS/Domain/Headless.pm', "(\$hp->{'placement'} || '') eq 'within'"),
	'a home-plate row with no placement is not a warning');
ok(has('lib/JawnOS/Domain/Headless.pm', "(\$data->{'cache'} || '') eq 'yes'"),
	'a missing cache flag is not a warning');

# Name: a settings row with no source, and a row with no setting name
ok(has('lib/JawnOS/Domain/Name.pm', "(\$settings->{'source'} || '') eq 'panel'"),
	'a settings row with no source is not a warning');
ok(has('lib/JawnOS/Domain/Name.pm', "next unless defined \$s->{'setting'};"),
	'a settings row with no name is skipped, not used as a hash key');

# Appointment: the same navigation rows, and a cache that may be absent
ok(has('lib/JawnOS/Domain/Appointment.pm', "(\$hp->{'placement'} || '') eq 'without'"),
	'a trip row with no placement is not a warning');
ok(has('lib/JawnOS/Domain/Appointment.pm', "\$cache && (\$cache->{'timestamp'} || 0) + 5000"),
	'an absent navigation cache is not a warning');

# Generate: the save switches
ok(has('lib/JawnOS/Domain/Generate.pm', "(\$m->{'save_app'} || '') eq 'on'"),
	'a model with no save switch is not a warning');
ok(has('lib/JawnOS/Domain/Generate.pm', "(\$ch->{'save_appt'} || '') eq 'on'"),
	'a character with no save switch is not a warning');

# Root: a signatorial that did not decrypt
ok(has('lib/JawnOS/Controller/Root_misc.pm', 'defined $rs && $rs eq $signatorial'),
	'an undecryptable signatorial is compared only when it exists');

# File: the cache table may not exist yet
ok(has('lib/JawnOS/Domain/File.pm', 'my $results = $query ? $query->hashes : [];'),
	'cache_get tolerates a query that returned nothing');
ok(has('lib/JawnOS/Domain/File.pm', "my \$json_data = \$result ? \$result->{'data'} : undef;"),
	'and a result that is not there');

# Watchdog: two unanswered probes before a rebuild
my $watch = 'public/js/manager/websocket/03_watchdog.js';
ok(has($watch, 'var wsWatchdogProbeWait = 8000;'), 'a probe waits longer for its answer');
ok(has($watch, "socket['probeCount'] = 1;"), 'the first unanswered probe is counted');
ok(has($watch, "if ((socket['probeCount'] || 1) < 2) {"), 'a second probe is sent, not a rebuild');
ok(has($watch, "delete ws[app]['probeCount'];"), 'any heard frame clears the count');

# Log's reader is called without a scope or a timestamp too
ok(has('lib/JawnOS/Domain/Log.pm', "my \$scope = \$data->{'scope'} || '';"),
	'a log read with no scope names the empty scope');
ok(has('lib/JawnOS/Domain/Log.pm', "my \$timestamp = \$data->{'timestamp'} || 0;"),
	'a log read with no timestamp compares against zero');

# Remote: a relay parameter with no value
ok(has('lib/JawnOS/Domain/Remote.pm', "(\$extra_params->{\$ep} || '')"),
	'an empty relay parameter is the empty string');

# Warehouse: a task duration with no settings row
ok(has('lib/JawnOS/Domain/Warehouse.pm', 'defined $dur_text ? abs &subs::time_abbrev_translator($dur_text) : 0'),
	'a task with no settings duration is zero, not a warning');

done_testing();
