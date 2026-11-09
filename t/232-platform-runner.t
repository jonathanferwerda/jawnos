# tests-for: lib/JawnOS/Platform/Runner.pm lib/JawnOS/Platform/Runner/Unix.pm
# covers:    the runner seam picks the platform backend, every backend starts a
#            child and reports its output and exit, a write reaches the child,
#            and nothing outside the Unix backend names ReadWriteFork.

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
# Only the Unix backend may name it. Several dozen files carried an unused
# import of it - every Controller among them, where the line was blanked rather
# than deleted because an action's line number is its route id.
{
	require File::Find;
	my @sources;
	File::Find::find({ no_chdir => 1, wanted => sub {
		return unless -f $_ && /\.(?:pm|pl)$/;
		my $path = $File::Find::name;
		$path =~ s{^\Q$root/\E}{};
		# The Unix backend is the one place allowed to name it; the Windows
		# backend names it only in prose.
		return if $path eq 'lib/JawnOS/Platform/Runner/Unix.pm';
		return if $path eq 'lib/JawnOS/Platform/Runner/Windows.pm';
		push @sources, $path;
	} }, "$root/perl", "$root/lib");
	push @sources, 'jawn';
	my @offenders;
	for my $file (@sources) {
		my $text = read_file("$root/$file");
		push @offenders, $file
			if $text =~ /^\s*use Mojo::IOLoop::ReadWriteFork\b/m
			|| $text =~ /Mojo::IOLoop::ReadWriteFork->new/;
	}
	is_deeply(\@offenders, [], 'nothing outside the Unix backend loads ReadWriteFork');
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

# The terminal session writes keystrokes to the child, so write is part of the
# seam. A pipe proves it on both backends.
my $echo = "$tmp/echo.pl";
write_file($echo, 'while (defined(my $line = <STDIN>)) { print "got:$line"; last; }' . "\n");
my $said = '';
my $writer = JawnOS::Platform::Runner->new;
$writer->conduit({ type => 'pipe' });
$writer->on(spawn => sub { $writer->write("ping\n") });
$writer->on(read => sub { $said .= $_[1] });
$writer->on(close => sub { Mojo::IOLoop->stop });
$writer->start({ program => $^X, program_args => [$echo] });
Mojo::IOLoop->timer(10 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

like($said, qr/got:ping/, 'write reaches the child');

# A pty handle exists on Unix; Windows has none, and the resize path treats
# undef as "there is no terminal to resize".
ok($runner->can('read_handle'), 'the seam exposes a read handle');

done_testing();
