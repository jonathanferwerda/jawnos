use strict;
use warnings;

# cwd-relative, not FindBin: verify_change copies a test to /tmp for the pre-push
# parse check, and the process still runs with the repo as its working directory.
use lib "lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use Mojo::JSON qw(decode_json);
use JawnOS::LogBus;

# The error watch's console source without a pty.log file: a bounded,
# sequence-numbered ring in the master, served over a unix socket. These tests
# pin the ring's read/replay/drop/reset semantics, the wire shape, and a real
# client/server round trip.

my $ring = JawnOS::LogBus::ring_new(64);
for my $part ('alpha ', 'beta ', 'gamma') { JawnOS::LogBus::ring_append($ring, $part) }
my $all = &JawnOS::LogBus::ring_read($ring, 0, 4096);
is($all->{'bytes'}, 'alpha beta gamma', 'a fresh cursor reads the whole ring');
is($all->{'from'}, 0, 'from is the requested sequence');
is($all->{'to'}, 16, 'to advances by the bytes returned');
is($all->{'dropped'}, 0, 'nothing was dropped');

my $tail = &JawnOS::LogBus::ring_read($ring, 6, 4096);
is($tail->{'bytes'}, 'beta gamma', 'a cursor resumes at its own sequence');
is($tail->{'from'}, 6, 'from is the cursor');

my $slice = &JawnOS::LogBus::ring_read($ring, 0, 5);
is($slice->{'bytes'}, 'alpha', 'max limits a chunk');
is($slice->{'to'}, 5, 'and to stops at the limit');

# A ring that overwrites: 10 bytes of room, 15 written, so the first 5 are gone.
my $small = JawnOS::LogBus::ring_new(10);
JawnOS::LogBus::ring_append($small, 'abcdefghij');
JawnOS::LogBus::ring_append($small, 'klmno');
my $gone = &JawnOS::LogBus::ring_read($small, 0, 4096);
is($gone->{'earliest'}, 5, 'the earliest readable sequence is the surviving byte');
is($gone->{'dropped'}, 5, 'a cursor older than the ring is told what it lost');
is($gone->{'from'}, 5, 'and reads from the earliest byte');
is($gone->{'bytes'}, 'fghijklmno', 'the surviving tail is what is left');

# A cursor ahead of the master (it restarted and sequences began again).
my $ahead = &JawnOS::LogBus::ring_read($small, 999, 4096);
is($ahead->{'reset'}, 1, 'a cursor past the total asks the client to reset');
is($ahead->{'bytes'}, '', 'and there is nothing to read yet');

# The wire shape: a JSON header line, then exactly that many raw bytes.
my $wire = &JawnOS::LogBus::reply_for($ring, '{"since":6,"max":4096}');
my ($header, $body) = split /\n/, $wire, 2;
my $reply = decode_json($header);
is($reply->{'bytes'}, 10, 'the header carries the body length');
is($body, 'beta gamma', 'the body is the raw bytes, not an encoding');

# A real client/server round trip over a unix socket.
my $dir = tempdir(CLEANUP => 1);
my $path = "$dir/log";
my $listener = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => $path, Listen => 5)
	or die "listen $path: $!";
my $pid = fork // die "fork: $!";
if (!$pid) {
	my $conn = $listener->accept or exit 2;
	my $line = <$conn>;
	print $conn &JawnOS::LogBus::reply_for($ring, $line);
	close $conn;
	exit 0;
}
close $listener;
my $live = JawnOS::LogBus::client_read($path, 6, 4096, 5);
waitpid($pid, 0);
is($? >> 8, 0, 'the test server exits cleanly');
is($live->{'bytes'}, 'beta gamma', 'client_read returns the raw bytes');
is($live->{'from'}, 6, 'and the sequence window');
is($live->{'to'}, 16, 'to the end of the read');

# The same client sees a drop when its cursor fell behind a short ring.
my $listener2 = IO::Socket::UNIX->new(Type => SOCK_STREAM, Local => "$dir/log2", Listen => 5)
	or die "listen: $!";
my $pid2 = fork // die "fork: $!";
if (!$pid2) {
	my $conn = $listener2->accept or exit 2;
	my $line = <$conn>;
	print $conn &JawnOS::LogBus::reply_for($small, $line);
	close $conn;
	exit 0;
}
close $listener2;
my $late = JawnOS::LogBus::client_read("$dir/log2", 0, 4096, 5);
waitpid($pid2, 0);
is($late->{'dropped'}, 5, 'client_read reports the bytes the ring overwrote');
is($late->{'bytes'}, 'fghijklmno', 'and returns the surviving tail');

done_testing();
