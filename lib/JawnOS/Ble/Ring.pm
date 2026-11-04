package JawnOS::Ble::Ring;

# A small on-disk ring of the last BLE events. The listener writes one line per
# event *before* it prints or decodes it, so when a reader gets stuck inside one
# event (the parent's guard restarts it) the event that did it is still on disk.
# The parent logs the tail when it fires; without this the only trace of a stall
# was a process holding a core and a socket queue quietly growing.
#
# Metadata only: event name, byte length, MAC, and a short printable head. The
# ring is local runtime state (default $HOME/.jawn-bt-ring.log), never a tracked
# file, and is capped so a flood cannot grow it without bound.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(ring_path event_note ring_note ring_tail);

our $MAX_BYTES = 32 * 1024;
our $KEEP_LINES = 64;
our $HEAD_BYTES = 80;

# Under a burst (a sync or an audio stream) noting every event costs more than
# the bridge itself. A stall is caused by a large or pathological event, so note
# every event at or above $SMALL_BYTES, and small ones at most once a second.
# The normal bridge sends one event every few seconds, so nothing is lost there.
our $SMALL_BYTES = 4096;
our $SMALL_GAP = 1;
our $LAST_SMALL = 0;

sub ring_path {
	my $p = $ENV{'JAWNOS_BT_RING'};
	return $p if defined $p && length $p;
	my $home = $ENV{'HOME'};
	return unless defined $home && length $home;
	return "$home/.jawn-bt-ring.log";
}

# event_note($raw_json_line, $epoch) -> one printable line naming the event.
sub event_note {
	my ($line, $epoch) = @_;
	$line = '' unless defined $line;
	my ($event) = $line =~ /"event"\s*:\s*"([^"]{1,40})"/;
	my ($mac)   = $line =~ /"mac"\s*:\s*"([^"]{1,40})"/;
	my $head = substr($line, 0, $HEAD_BYTES);
	$head =~ s/[^\x20-\x7e]/./g;
	$head =~ s/"/'/g;
	$epoch = time() unless defined $epoch;
	return sprintf('ts=%d event=%s bytes=%d%s head=%s',
		$epoch, (defined $event ? $event : '?'), length($line),
		(defined $mac ? " mac=$mac" : ''), $head);
}

# ring_note($raw_json_line, $path?, $force?) -> the line appended (or undef).
# Never dies: a broken diagnostic file must not stop the bridge.
sub ring_note {
	my ($line, $path, $force) = @_;
	$path = ring_path() unless defined $path;
	return unless defined $path && length $path;
	my $now = time();
	my $bytes = length($line // '');
	unless ($force) {
		return if $bytes < $SMALL_BYTES && $now - $LAST_SMALL < $SMALL_GAP;
		$LAST_SMALL = $now if $bytes < $SMALL_BYTES;
	}
	my $note = event_note($line, $now);
	my $ok = eval {
		open(my $fh, '>>', $path) or return;
		print $fh $note, "\n";
		close $fh;
		1;
	};
	return unless $ok;
	eval { &_trim($path) };
	return $note;
}

# ring_tail($n?, $path?) -> the last $n lines, oldest first.
sub ring_tail {
	my ($n, $path) = @_;
	$n = $KEEP_LINES unless defined $n && $n > 0;
	$path = ring_path() unless defined $path;
	return () unless defined $path && length $path && -r $path;
	open(my $fh, '<', $path) or return ();
	my @lines;
	while (defined(my $line = <$fh>)) {
		chomp $line;
		next unless length $line;
		push @lines, $line;
	}
	close $fh;
	@lines = @lines[ -$n .. -1 ] if @lines > $n;
	return @lines;
}

sub _trim {
	my ($path) = @_;
	return unless defined $path && -s $path && -s $path > $MAX_BYTES;
	open(my $fh, '<', $path) or return;
	my @lines;
	while (defined(my $line = <$fh>)) {
		chomp $line;
		push @lines, $line if length $line;
	}
	close $fh;
	@lines = @lines[ -$KEEP_LINES .. -1 ] if @lines > $KEEP_LINES;
	my $tmp = "$path.tmp";
	open(my $out, '>', $tmp) or return;
	print $out $_, "\n" for @lines;
	close $out;
	rename($tmp, $path) or unlink($tmp);
}

1;
