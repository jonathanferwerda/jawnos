# tests-for: lib/JawnOS/Platform/Runner.pm lib/JawnOS/Platform/Runner/Unix.pm
# covers:    the runner seam picks the platform backend, every backend starts a
#            child and reports its output and exit, and nothing outside the Unix
#            backend names ReadWriteFork.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file read_file);
use RepoSource;
use Mojo::IOLoop;
use JawnOS::Platform::Runner;

my $root = repo_root();

# The seam exists so a Windows tree never loads Mojo::IOLoop::ReadWriteFork.
# Only the Unix backend may name it.
for my $file (qw(
	jawn
	lib/JawnOS/Manager.pm
	lib/JawnOS/Manager/Part25.pm
	lib/JawnOS/Domain/Ble2.pm
)) {
	my $text = read_file("$root/$file");
	unlike($text, qr/Mojo::IOLoop::ReadWriteFork/,
		"$file no longer names ReadWriteFork");
}

my $backend = $^O eq 'MSWin32'
	? 'JawnOS::Platform::Runner::Windows'
	: 'JawnOS::Platform::Runner::Unix';
my $runner = JawnOS::Platform::Runner->new;
is(ref $runner, $backend, "the seam picks $backend here");

my $tmp = tempdir(CLEANUP => 1);
my $child = "$tmp/child.pl";
write_file($child, "print qq(seam-one\\n); print STDERR qq(seam-two\\n); exit 4;\n");

# ReadWriteFork forks on the loop's next tick, so the pid arrives with the
# spawn event rather than from start()'s return value.
my $pid;
my $seen = '';
my ($exit, $signal);
$runner->conduit({ type => 'pipe' });
$runner->on(spawn => sub { $pid = $_[0]->pid });
$runner->on(read => sub { $seen .= $_[1] });
$runner->on(close => sub { ($exit, $signal) = @_[1, 2]; Mojo::IOLoop->stop });

$runner->start({ program => $^X, program_args => [$child] });
Mojo::IOLoop->timer(20 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

ok($pid, 'the seam starts a child');
is($runner->pid, $pid, 'and reports its pid');
like($seen, qr/^seam-one\r?$/m, 'stdout arrives through the seam');
like($seen, qr/^seam-two\r?$/m, 'stderr arrives through the seam');
is($exit, 4, 'the exit value arrives as the second argument');
ok(!defined $signal || $signal == 0, 'and the signal as the third');

# stop takes a live child down through the same seam
my $long = "$tmp/long.pl";
write_file($long, "sleep 60;\n");
my ($pid2, $was_alive, $now_dead);
my $second = JawnOS::Platform::Runner->new;
$second->on(spawn => sub { $pid2 = $_[0]->pid });
$second->start({ program => $^X, program_args => [$long] });
Mojo::IOLoop->timer(1 => sub {
	$was_alive = $second->alive;
	$second->stop;
	for (1 .. 20) {
		last unless $second->alive;
		select(undef, undef, undef, 0.1);
	}
	$now_dead = !$second->alive;
	Mojo::IOLoop->stop;
});
Mojo::IOLoop->start;

ok($pid2, 'a second child starts');
ok($was_alive, 'and is alive');
ok($now_dead, 'stop takes it down');

done_testing();
