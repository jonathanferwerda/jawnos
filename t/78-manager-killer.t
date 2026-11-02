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

# The killer used to shell out to pkill/pgrep four times per name, and a match
# was anything whose command line mentioned the name. A real worker and an
# editor with Manager.pl open were the same thing to it. It now reads /proc
# once and signals exact pids whose executable is perl. This pins both: the
# selection, and the fact that decoys survive while the tree does not.

my $root = repo_root();
my $script = "$root/scripts/manager_killer.pl";
my $src = read_file($script);

like($src, qr/sub scan_processes/, 'the killer scans /proc once');
unlike($src, qr/`\s*(?:pkill|pgrep)/, 'no pkill/pgrep in the code path');
like($src, qr/sub is_tree/, 'the tree is identified by executable and command line');
like($src, qr/--scope/, 'a scope keeps a test run away from the live tree');

my $tmp = tempdir(CLEANUP => 1);

# A real worker-shaped process: perl running a script named President.pl.
write_file("$tmp/President.pl", "sleep 60;\n");
my $fake = fork();
die "fork fake: $!\n" unless defined $fake;
if ($fake == 0) {
	exec($^X, "$tmp/President.pl");
	exit 127;
}

# Decoys: a shell that mentions Manager.pl, and a perl compile probe (which is
# exactly what an agent runs while editing).
my $shell = fork();
die "fork shell: $!\n" unless defined $shell;
if ($shell == 0) {
	exec('sh', '-c', 'sleep 60', "$tmp/Manager.pl");
	exit 127;
}
my $probe = fork();
die "fork probe: $!\n" unless defined $probe;
if ($probe == 0) {
	exec($^X, '-e', 'sleep 60', "$tmp/Manager.pl");
	exit 127;
}

sleep 0.5;

my $list = `$^X $script --list --scope=$tmp 2>&1`;
like($list, qr/^\Q$fake\E\t/m, 'the perl worker is selected');
unlike($list, qr/^\Q$shell\E\t/m, 'a shell that merely mentions Manager.pl is not');
unlike($list, qr/^\Q$probe\E\t/m, 'a perl -e probe is not');

system($^X, $script, "--scope=$tmp") == 0 or fail('the killer exited non-zero');

my $deadline = time + 3;
my $reaped = 0;
while (time < $deadline) {
	if (waitpid($fake, WNOHANG) == $fake) { $reaped = 1; last }
	sleep 0.05;
}
ok($reaped, 'the worker is stopped');
ok(kill(0, $shell), 'the shell decoy survives');
ok(kill(0, $probe), 'the compile probe survives');

kill 'KILL', $shell, $probe;
waitpid($shell, 0);
waitpid($probe, 0);

# The master is only taken when it is named, because ./jawn calls the killer
# with no argument and must not stop itself.
write_file("$tmp/jawn", "sleep 60;\n");
my $master = fork();
die "fork master: $!\n" unless defined $master;
if ($master == 0) {
	exec($^X, "$tmp/jawn");
	exit 127;
}
sleep 0.4;

my $without = `$^X $script --list --scope=$tmp 2>&1`;
unlike($without, qr/^\Q$master\E\t/m, 'the master is left alone by default');
my $with = `$^X $script --list master --scope=$tmp 2>&1`;
like($with, qr/^\Q$master\E\tmaster/m, 'master mode names it');

system($^X, $script, 'master', "--scope=$tmp") == 0 or fail('master kill exited non-zero');
my $master_deadline = time + 3;
my $master_gone = 0;
while (time < $master_deadline) {
	if (waitpid($master, WNOHANG) == $master) { $master_gone = 1; last }
	sleep 0.05;
}
ok($master_gone, 'the master is stopped in master mode');

kill 'KILL', $master if kill(0, $master);

done_testing();
