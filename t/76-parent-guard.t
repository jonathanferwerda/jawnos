use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use Time::HiRes qw(time sleep);
use POSIX qw(WNOHANG);
use RepoSource;

# A master that is SIGKILLed cannot run its shutdown, so the tree and every
# worker under it used to survive as orphans - the tablet's Stop/update did
# exactly that. The guard is a child of the tree that watches the master and
# takes the tree down the normal SIGTERM way when the master is gone. This pins
# both the wiring and the behaviour.

my $root = repo_root();
my $jawn = read_file("$root/jawn");
my $president = read_file("$root/perl/President.pl");
my $guard = read_file("$root/perl/parent_guard.pl");

like($jawn, qr/\$SIG\{TERM\} = sub \{\s*&shut_down\(\);/, 'the master handles SIGTERM');
like($jawn, qr/\$SIG\{HUP\} = sub \{\s*&shut_down\(\);/, 'the master handles SIGHUP');
like($jawn, qr/sub sweep_orphans/, 'the master can sweep a dead predecessor');
like($jawn, qr/&sweep_orphans\(\)/, 'it sweeps at boot, after the one-master check');
like($president, qr{require './perl/parent_guard\.pl'}, 'the tree loads the guard');
like($president, qr/&parent_guard::start\(tree => \$\$, master => getppid\(\)\)/,
	'the tree watches the master that forked it');
like($guard, qr/sub alive/, 'the guard can tell a dead or reused pid from a live master');
like($guard, qr/kill 'TERM', \$tree/, 'the guard stops the tree with SIGTERM, the normal path');

my $tmp = tempdir(CLEANUP => 1);
my $marker = "$tmp/stopped";
my $script = "$tmp/fake_tree.pl";
write_file($script, <<'PERL');
use strict;
use warnings;
my ($marker, $master, $guard) = @ARGV;
require $guard;
$SIG{TERM} = sub {
	open(my $fh, '>', $marker) or die "marker: $!";
	print $fh "term\n";
	close $fh;
	exit 0;
};
parent_guard::start(tree => $$, master => $master, interval => 0.1);
select(undef, undef, undef, 0.2) while 1;
PERL

my $master = fork();
die "fork master: $!\n" unless defined $master;
if ($master == 0) {
	$SIG{TERM} = 'DEFAULT';
	# the guard checks that the pid still runs the master, not a reused pid
	$0 = 'jawn';
	sleep 30;
	exit 0;
}

my $tree = fork();
die "fork tree: $!\n" unless defined $tree;
if ($tree == 0) {
	exec($^X, $script, $marker, $master, "$root/perl/parent_guard.pl");
	exit 127;
}

sleep 0.6;
ok(!-e $marker, 'the tree stays up while its master lives');
ok(kill(0, $tree), 'and the tree itself is alive');

kill 'KILL', $master;
waitpid($master, 0);

my $deadline = time + 5;
my $exited = 0;
while (time < $deadline) {
	if (waitpid($tree, WNOHANG) == $tree) { $exited = 1; last }
	sleep 0.1;
}
ok($exited, 'the tree leaves when its master is SIGKILLed');
like(-e $marker ? read_file($marker) : '', qr/term/,
	'it took the SIGTERM path, so Prefork stops the workers');

kill 'KILL', $tree if kill(0, $tree);
waitpid($tree, 0) if $tree;

done_testing();
