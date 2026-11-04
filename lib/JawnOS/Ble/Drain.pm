package JawnOS::Ble::Drain;

# Both sides of the BLE bridge read JSON lines into a buffer: the client
# (scripts/jawn-bt) and the manager (Ble2.pm). The tail of an incomplete line
# has to stay buffered, but it must not be copied on every read.
#
# Splitting the whole buffer on every read copies the unterminated tail every
# time, and Perl's string grow is not amortised, so appending to a large tail
# copies it again too. A bridge that streamed one long line (a runaway event,
# no newline for megabytes) therefore made the reader do O(buffer) work per
# 64 KB read: a phone pinned a core at 100%, almost all of it in page faults,
# while the socket queue grew. Here a chunk with no newline is kept as a list
# entry and is only joined when a newline finally arrives.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(drain_new drain_feed);

# drain_new() -> state
sub drain_new {
	return { tail => '', parts => [], bytes => 0 };
}

# drain_feed($state, $chunk, $cap) -> (\@complete_lines, $dropped_bytes)
# Appends a read, returns every line it completed, and leaves the unterminated
# tail in the state. Nothing is concatenated, split, or scanned when the chunk
# carries no newline. When the incomplete data passes $cap it is dropped and
# its size is returned (the caller logs it); complete lines in the same read
# are still returned.
sub drain_feed {
	my ($b, $chunk, $cap) = @_;
	push @{ $b->{parts} }, $chunk;
	$b->{bytes} += length $chunk;
	my @lines;
	if (index($chunk, "\n") >= 0) {
		my $buf = $b->{tail} . join('', @{ $b->{parts} });
		$b->{tail} = '';
		$b->{parts} = [];
		$b->{bytes} = 0;
		# The chunk had a newline, so there is at least one complete line. The
		# part after the last newline is all that stays buffered.
		my $cut = rindex($buf, "\n");
		my $complete = substr($buf, 0, $cut + 1);
		$b->{tail} = substr($buf, $cut + 1);
		@lines = split /\n/, $complete, -1;
		# $complete ends with a newline, so -1 leaves one empty element.
		pop @lines if @lines && $lines[-1] eq '';
	}
	my $pending = length($b->{tail}) + $b->{bytes};
	my $dropped = 0;
	if ($cap && $pending > $cap) {
		$dropped = $pending;
		$b->{tail} = '';
		$b->{parts} = [];
		$b->{bytes} = 0;
	}
	return (\@lines, $dropped);
}

1;
