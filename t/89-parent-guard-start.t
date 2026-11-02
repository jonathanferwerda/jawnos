use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# parent_guard's alive() used to judge the master by its command line alone. The
# QA harness runs the tree under script(1), whose cmdline never says "jawn", so a
# live master read as dead and the guard took the tree down. A recycled pid has
# the opposite problem: the name matches, the process does not. start_time()
# (field 22 of /proc/<pid>/stat) identifies the process itself, and alive() now
# compares it when it has one. This pins both halves and the wiring.

my $root = repo_root();
require "$root/perl/parent_guard.pl";

sub proc_start {
	my ($pid) = @_;
	open(my $fh, '<', "/proc/$pid/stat") or return '';
	my $line = <$fh>;
	close $fh;
	return '' unless defined $line;
	$line =~ s/^.*\)\s+//;    # cut through "(comm)", which may hold spaces
	my @field = split /\s+/, $line;
	return $field[19] // '';
}

my $pid = fork();
die "fork: $!\n" unless defined $pid;
if ( $pid == 0 ) {
	$SIG{TERM} = 'DEFAULT';
	sleep 20;
	exit 0;
}

my $start  = parent_guard::start_time($pid);
my $direct = proc_start($pid);

ok( length $start, 'start_time returns a value for a live pid' );
is( $start, $direct, 'and it is field 22 of /proc/<pid>/stat' );
ok( parent_guard::alive( $pid, $start ), 'a pid with its own start time is alive' );
ok( !parent_guard::alive( $pid, '1' ), 'a different start time is dead (a recycled pid)' );

# A pid that has been reaped has no /proc entry, so it has no start time; the
# guard then falls back to the command-line test rather than declaring it live.
my $gone = fork();
die "fork: $!\n" unless defined $gone;
if ( $gone == 0 ) { exit 0 }
waitpid( $gone, 0 );
is( parent_guard::start_time($gone), '', 'a reaped pid has no start time' );

# The value has to be captured once (at guard start) and compared on every poll,
# or the guard is back to the name test it had before.
my $guard = read_file("$root/perl/parent_guard.pl");
like( $guard, qr/my \$master_start = &start_time\(\$master\)/,
	'the guard captures the master start once' );
like( $guard, qr/next if &alive\(\$master, \$master_start\)/,
	'and compares it on every poll' );

kill 'TERM', $pid;
waitpid( $pid, 0 );

done_testing();
