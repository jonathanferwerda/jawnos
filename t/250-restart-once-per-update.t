# tests-for: perl/control.pl lib/JawnOS/Domain/Git.pm perl/Manager.pl
# covers:    One landing restarts the tree once. The git watcher fast-forwards
#            the tree and then installs extras, Perl modules and system packages
#            before it asks for the restart; a landing's own restart can be
#            accepted and booted in that gap. Asking again stops and boots the
#            same tree a second time, which a connected tab sees as two
#            reconnects (and, on a script change, two reloads). The watcher asks
#            only when no accepted restart already booted the version on disk.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Spec;
use File::Slurp qw(read_file);
use RepoSource;

require File::Spec->rel2abs("$FindBin::Bin/../perl/control.pl");

my $root = repo_root();
my $now  = 1_800_000_000;

# An accepted restart that booted v0.1.2600 at $now.
my $booted = { ok => 1, version => '0.1.2600', epoch => $now, source => 'scripts/restart.pl' };

# --- the decision -----------------------------------------------------------
ok( &control::restart_covers($booted, '0.1.2600', $now),
	'a restart that booted this exact tree covers it' );
ok( &control::restart_covers($booted, '0.1.2600', $now - 30),
	'and still covers it when the pass began before that restart' );
is( &control::restart_covers($booted, '0.1.2600', $now + 30), 0,
	'a record older than the pass cannot cover a move the pass has not made' );

is( &control::restart_covers($booted, '0.1.2601', $now), 0,
	'a newer tree on disk is not covered by the old restart' );
is( &control::restart_covers({ %$booted, ok => 0 }, '0.1.2600', $now), 0,
	'a refused restart booted nothing, so it covers nothing' );
is( &control::restart_covers({ %$booted, ok => undef }, '0.1.2600', $now), 0,
	'a record that does not say it was accepted is not trusted' );
is( &control::restart_covers({ %$booted, epoch => $now - 1 }, '0.1.2600', $now), 0,
	'a restart from before the pass began does not cover the move' );
is( &control::restart_covers({ %$booted, version => undef }, '0.1.2600', $now), 0,
	'a record with no version covers nothing' );
is( &control::restart_covers({ %$booted, epoch => undef }, '0.1.2600', $now), 0,
	'a record with no epoch covers nothing' );
is( &control::restart_covers($booted, '', $now), 0,
	'an unknown tree version is never called covered' );
is( &control::restart_covers($booted, undef, $now), 0,
	'and neither is an undefined one' );
is( &control::restart_covers(undef, '0.1.2600', $now), 0,
	'no record, no coverage' );
is( &control::restart_covers('not a record', '0.1.2600', $now), 0,
	'garbage reads as uncovered, not as an error' );


# --- the watcher uses it ----------------------------------------------------
my $git = read_file("$root/lib/JawnOS/Domain/Git.pm");
my $manager = read_file("$root/perl/Manager.pl");

like($manager, qr/require '\.\/perl\/control\.pl';/,
	'the app loads the restart record reader, so a lazy domain module may call it');

like($git, qr/my \$watch_started = int\(time\);/,
	'the watcher records when the pass began');
like($git, qr/require '\.\/perl\/control\.pl';/,
	'and reads the restart record through the control module');
like($git, qr/restart_covers\(\$last_restart, \$tree_version, \$watch_started\)/,
	'it asks the one decision whether an accepted restart already covers the tree');
like($git, qr/my \$tree_version = '';.*?open\(my \$vfh, '<', '\.\/VERSION'\)/s,
	'and compares against the VERSION now on disk, not a cached one');
like($git, qr/is already running \(v\$tree_version, restart recorded by \$by\); not asking again/,
	'a covered move is logged, naming the restart that covered it');

my $guard_at = index($git, 'restart_covers(');
my $ask_at   = index($git, "restart_request('the git watcher moved the tree");
ok($guard_at >= 0, 'the guard is in the watcher');
ok($ask_at > $guard_at, 'and it runs before the restart is requested');

# The guard sits after the installs: those are the slow step the race lives in.
my $installs_at = index($git, "install_system_dependencies('.')");
ok($installs_at >= 0 && $guard_at > $installs_at,
	'and after the installs that open the race window');

unlike($git, qr/, restarting\\n/, 'the move no longer promises a restart it may not ask for');

# --- syntax -----------------------------------------------------------------
my $control_syntax = `$^X -c "$root/perl/control.pl" 2>&1`;
like($control_syntax, qr/syntax OK/, 'control.pl compiles');
my $git_syntax = `cd "$root" && $^X -Ilib -c lib/JawnOS/Domain/Git.pm 2>&1`;
like($git_syntax, qr/syntax OK/, 'Git.pm compiles');

done_testing();
