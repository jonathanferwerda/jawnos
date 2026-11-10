# tests-for: lib/JawnOS/Platform/Runner/Windows.pm
# covers:    the Windows child runner: start, read both streams, see the exit,
#            and stop a live child. The socket-mode helper and the shape of the
#            registration are pure, so they are checked on every platform; the
#            live child is Windows only.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file read_file);
use Time::HiRes qw(sleep);

use Mojo::IOLoop;
require JawnOS::Platform::Runner::Windows;

# --- the pure part ----------------------------------------------------------
# A handle the caller supplies is never made non-blocking by Mojo
# (Mojo::IOLoop::Stream::new only stores it), so start() must do it. The fake
# records the call and answers with the previous mode, the way blocking() does.
{
	package FakeSocket;
	sub new { bless { calls => [], mode => $_[1] }, $_[0] }
	sub blocking {
		my ($self, $mode) = @_;
		push @{ $self->{'calls'} }, $mode;
		my $previous = $self->{'mode'};
		$self->{'mode'} = $mode if @_ > 1;
		return $previous;
	}
}

my $fake = FakeSocket->new(1);
is(JawnOS::Platform::Runner::Windows::_nonblocking($fake), 1,
	'the socket helper reports success');
is_deeply($fake->{'calls'}, [0], 'and asks for non-blocking mode exactly once');
is($fake->{'mode'}, 0, 'the socket is left non-blocking');
ok(!JawnOS::Platform::Runner::Windows::_nonblocking(undef),
	'no socket is not an error');

# The parent end is a Mojo stream, not a raw reactor->io watcher. A raw watcher
# watches read and write together, so it fires forever on a writable socket with
# no data and starves the rest of the loop's streams.
{
	my $source = read_file("$FindBin::Bin/../lib/JawnOS/Platform/Runner/Windows.pm");
	like($source, qr/Mojo::IOLoop::Stream->new/, 'the parent end is a Mojo stream');
	like($source, qr/\$stream->timeout\(0\)/, 'the stream timeout is disabled');
	unlike($source, qr/->reactor->io\s*\(/, 'and no raw reactor->io registration remains');
	like($source, qr/Mojo::IOLoop->stream\(\$stream\)/, 'the stream is registered with the loop');

	my $switch = index $source, '&_nonblocking($mine)';
	my $stream = index $source, 'Mojo::IOLoop::Stream->new($mine)';
	ok($switch >= 0, 'start makes the parent end non-blocking');
	ok($stream >= 0 && $switch < $stream, 'and does so before the stream holds it');
}

# --- the live child, Windows only -------------------------------------------
SKIP: {
	skip 'the socket child is Windows only', 8 unless $^O eq 'MSWin32';

	my $tmp = tempdir(CLEANUP => 1);
	my $child = "$tmp/child.pl";
	write_file($child, "print qq(one\\n); print STDERR qq(two\\n); sleep 1; exit 3;\n");

	my $seen = '';
	my $exit;
	my $runner = JawnOS::Platform::Runner::Windows->new;
	$runner->conduit({ type => 'pipe' });
	$runner->on(read => sub { $seen .= $_[1] });
	$runner->on(close => sub { $exit = $_[1]; Mojo::IOLoop->stop });

	my $pid = $runner->start({ program => $^X, program_args => [$child] });
	ok($pid, 'the child starts') or diag($runner->{'error'});
	is($runner->pid, $pid, 'and its pid is known');
	Mojo::IOLoop->timer(15 => sub { Mojo::IOLoop->stop });
	Mojo::IOLoop->start;

	like($seen, qr/^one\r?$/m, 'stdout arrives through the reader');
	like($seen, qr/^two\r?$/m, 'stderr arrives through the reader');
	is($exit, 3, 'the exit code is seen');

	# a live child is stopped, and stopping is not a wait for a clean exit
	my $long = "$tmp/long.pl";
	write_file($long, "sleep 60;\n");
	my $second = JawnOS::Platform::Runner::Windows->new;
	my $pid2 = $second->start({ program => $^X, program_args => [$long] });
	ok($pid2, 'the second child starts');
	sleep 1;
	ok($second->alive, 'and is alive');
	$second->stop;
	ok(!$second->alive, 'stop takes it down');
}

done_testing();
