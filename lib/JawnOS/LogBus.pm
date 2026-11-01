package JawnOS::LogBus;

# The tree's console stream without a pty.log file.
#
# The master (`./jawn`) already reads every byte President and its workers print
# on the pty. Instead of teeing those bytes into ~/pty.log, it appends them to a
# bounded, sequence-numbered ring and serves the ring over ~/.president/log. The
# error watch asks for "everything after sequence N", so it reads the same stream
# with no file in between. The sequence cursor rides in the existing
# ~/.president/error_watch_offsets file under its own key (`pty_seq`), so an old
# byte offset from the pty.log era can never be mistaken for a sequence.
#
# The ring lives in the master and survives a tree restart, which is why a new
# tree can still read the dying tree's last words: they are still in the ring
# when it reconnects. A tree that has never run simply asks from 0.
#
# Wire shape, one request per connection:
#
#   {"since":N,"max":N}\n
#   {"from":N,"to":N,"earliest":N,"total":N,"dropped":N,"reset":0,"bytes":N}\n
#   <N raw bytes>
#
# The header is a JSON line so a human can read it, and the body is raw bytes so
# ANSI/UTF-8 output is not inflated by base64. A `dropped` count means the ring
# overwrote bytes the client never saw; `reset` means the client's cursor is
# ahead of this master (a master restart), and it should start from 0.

use strict;
use warnings;

use IO::Select;
use IO::Socket::UNIX;
use Mojo::JSON qw(decode_json encode_json);
use Time::HiRes qw(time);

our $DEFAULT_MAX   = 4 * 1024 * 1024;
our $DEFAULT_CHUNK = 262144;
our $MAX_CHUNK     = 1024 * 1024;

# The ring is a list of [sequence, bytes] chunks rather than one string: a trim
# drops whole chunks from the front, so a chatty tree never re-copies megabytes
# just to append a few KB.
sub ring_new {
	my ($max) = @_;
	$max = $DEFAULT_MAX unless defined $max && $max =~ /^\d+$/ && $max > 0;
	return { max => $max, chunks => [], base => 0, total => 0 };
}

sub ring_append {
	my ($ring, $bytes) = @_;
	return $ring unless $ring && defined $bytes && length $bytes;
	push @{$ring->{'chunks'}}, [ $ring->{'total'}, $bytes ];
	$ring->{'total'} += length $bytes;
	# Drop exactly what no longer fits: whole chunks first, then the front of the
	# chunk that straddles the boundary. The partial trim copies one chunk (a few
	# KB), never the whole ring.
	my $excess = $ring->{'total'} - $ring->{'base'} - $ring->{'max'};
	while ($excess > 0 && @{$ring->{'chunks'}}) {
		my $first = $ring->{'chunks'}[0];
		my $len = length $first->[1];
		if ($len <= $excess) {
			shift @{$ring->{'chunks'}};
			$ring->{'base'} += $len;
			$excess -= $len;
		}
		else {
			substr($first->[1], 0, $excess, '');
			$first->[0] += $excess;
			$ring->{'base'} += $excess;
			$excess = 0;
		}
	}
	return $ring;
}

sub ring_read {
	my ($ring, $since, $max) = @_;
	$since = 0 unless defined $since && $since =~ /^\d+$/;
	$max = $DEFAULT_CHUNK unless defined $max && $max =~ /^\d+$/ && $max > 0;
	$max = $MAX_CHUNK if $max > $MAX_CHUNK;

	my $base  = $ring ? $ring->{'base'}  : 0;
	my $total = $ring ? $ring->{'total'} : 0;
	my $reset = $since > $total ? 1 : 0;
	my $from  = $reset ? $total : ($since < $base ? $base : $since);
	my $to    = $from + $max;
	$to = $total if $to > $total;

	my $bytes = '';
	if ($ring && @{$ring->{'chunks'}}) {
		my $pos = $from;
		foreach my $chunk (@{$ring->{'chunks'}}) {
			my ($seq, $data) = @$chunk;
			next if $seq + length($data) <= $pos;
			last if $pos >= $to;
			my $offset = $pos > $seq ? $pos - $seq : 0;
			my $take = length($data) - $offset;
			$take = $to - $pos if $pos + $take > $to;
			last if $take <= 0;
			$bytes .= substr($data, $offset, $take);
			$pos += $take;
		}
	}

	return {
		from     => $from,
		to       => $to,
		earliest => $base,
		total    => $total,
		dropped  => $from > $since ? $from - $since : 0,
		reset    => $reset,
		bytes    => $bytes,
	};
}

sub reply_for {
	my ($ring, $line) = @_;
	my $request = eval { decode_json($line) };
	$request = {} unless ref $request eq 'HASH';
	my $reply = &ring_read($ring, $request->{'since'}, $request->{'max'});
	my $header = encode_json({
		from     => $reply->{'from'},
		to       => $reply->{'to'},
		earliest => $reply->{'earliest'},
		total    => $reply->{'total'},
		dropped  => $reply->{'dropped'},
		reset    => $reply->{'reset'} ? 1 : 0,
		bytes    => length $reply->{'bytes'},
	});
	return $header . "\n" . $reply->{'bytes'};
}

# Blocking one-shot client. The error watch is a background child on a 60s tick,
# and the socket is local: a bounded synchronous read is simpler than keeping a
# live connection through every slow-loop iteration and every tree restart.
# Returns undef on any failure so the caller keeps its old cursor and retries.
sub client_read {
	my ($path, $since, $max, $timeout) = @_;
	return undef unless defined $path && length $path;
	$timeout = 3 unless defined $timeout && $timeout =~ /^\d+(?:\.\d+)?$/ && $timeout > 0;

	my $sock = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path);
	return undef unless $sock;
	my $select = IO::Select->new($sock);
	my $deadline = time + $timeout;

	my $request = encode_json({
		since => (defined $since && $since =~ /^\d+$/ ? $since : 0),
		max   => (defined $max && $max =~ /^\d+$/ && $max > 0 ? $max : $DEFAULT_CHUNK),
	}) . "\n";
	my $written = 0;
	while ($written < length $request) {
		my $left = $deadline - time;
		return undef if $left <= 0 || !$select->can_write($left);
		my $n = syswrite($sock, $request, length($request) - $written, $written);
		return undef unless $n;
		$written += $n;
	}

	my $buffer = '';
	my $header;
	while (1) {
		my $newline = index($buffer, "\n");
		if ($newline >= 0) { $header = substr($buffer, 0, $newline + 1, ''); last; }
		my $left = $deadline - time;
		return undef if $left <= 0 || !$select->can_read($left);
		my $n = sysread($sock, my $chunk, 8192);
		return undef unless defined $n;
		return undef if $n == 0;
		$buffer .= $chunk;
		return undef if length($buffer) > 65536;
	}

	my $reply = eval { decode_json($header) };
	unless (ref $reply eq 'HASH' && defined $reply->{'bytes'} && $reply->{'bytes'} =~ /^\d+$/) {
		close $sock;
		return undef;
	}
	my $want = $reply->{'bytes'};
	$want = $MAX_CHUNK if $want > $MAX_CHUNK;

	my $data = $buffer;
	while (length($data) < $want) {
		my $left = $deadline - time;
		return undef if $left <= 0 || !$select->can_read($left);
		my $n = sysread($sock, my $chunk, $want - length($data));
		return undef unless defined $n;
		last if $n == 0;
		$data .= $chunk;
	}
	close $sock;
	$reply->{'bytes'} = substr($data, 0, $want);
	return $reply;
}

1;
