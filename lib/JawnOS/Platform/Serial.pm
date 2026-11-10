package JawnOS::Platform::Serial;

# Serial devices and the USB console protocol behind one interface: which ports
# this machine has, whether a port is one we can drive, the stty setup, the
# open, and the paced write / deadline read the two board readers share.
#
# Linux keeps today's behaviour exactly. The port set, its order (ttyACM
# before ttyUSB, each sorted) and the stty argv are the ones Part34.pm,
# manager_embedded.pm and Boardpins.pm used before they asked here. A machine
# with no serial device answers [] or '' and never dies.
#
# macOS (/dev/cu.usbmodem*, /dev/cu.usbserial*) and Windows (COM*) are the P2/P3
# branch points (docs/platform-roadmap.md): the device patterns already know
# macOS, and Windows answers [], but port validation still accepts only the
# Linux names those backends will add.

use strict;
use warnings;

use IO::Handle ();
use Exporter 'import';
our @EXPORT_OK = qw(
	devices valid_port prepare open_read write_paced read_until baud
);

BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}

# The one speed both console readers agreed on.
our $BAUD = 115200;

# Pacing for a board whose USB CDC receive ring is small: 64-byte pieces with a
# 4 ms pause, the numbers the Pico provisioning path already used. The reader
# deadline was 8 seconds in both places.
our $PACING_CHUNK      = 64;
our $PACING_DELAY_MS   = 4;
our $READ_DEADLINE_SECONDS = 8;

# The Linux port set, in the order the callers enumerate it. macOS grew its own
# two patterns in the original Platform.pm; Windows has no answer yet.
my %PATTERNS = (
	darwin => [ '/dev/cu.usbmodem*', '/dev/cu.usbserial*' ],
	default => [ '/dev/ttyACM*', '/dev/ttyUSB*' ],
);

sub baud { return $BAUD }

# The patterns for one platform, with an optional directory prefix. The prefix
# is how a test builds a fake /dev tree without a serial device present.
sub _device_patterns {
	my ($os, $root) = @_;
	return () if defined $os && $os eq 'MSWin32';
	$root = '' unless defined $root;
	$root =~ s{/$}{};
	my $key = (defined $os && $os eq 'darwin') ? 'darwin' : 'default';
	return map { $root . $_ } @{ $PATTERNS{$key} };
}

# Every serial device this machine offers. Each pattern is sorted on its own,
# so ttyACM comes before ttyUSB exactly as the two glob calls did.
sub devices {
	my ($root) = @_;
	my @found;
	foreach my $pattern (_device_patterns($^O, $root)) {
		push @found, sort glob($pattern);
	}
	return [ @found ];
}

# A port this platform can drive today. A shape check only: the device may be
# gone by the time we open it, and the open's error is the better message.
# macOS cu.* and Windows COM* are added with their backends.
my $PORT_RE = qr{\A/dev/(?:ttyACM|ttyUSB)\d+\z};

sub valid_port {
	my ($port) = @_;
	return 0 unless defined $port && length $port;
	return $port =~ $PORT_RE ? 1 : 0;
}

# stty raw <speed> -echo: the exact argv both console readers ran. A missing
# device or stty answers false; the caller names the port and the failure.
sub prepare {
	my ($port, $speed) = @_;
	$speed = baud() unless defined $speed && length $speed;
	return 0 unless defined $port && length $port;
	return system('stty', '-F', $port, 'raw', "$speed", '-echo') == 0 ? 1 : 0;
}

# Open a port read-write: both console protocols write a command and then read
# the reply. autoflush keeps a small line out of perl's buffer. Returns the
# handle, or undef with $! set, which is what open itself would have left.
sub open_read {
	my ($port, %opt) = @_;
	return undef unless defined $port && length $port;
	my $mode = $opt{'mode'} || '+<';
	open(my $fh, $mode, $port) or return undef;
	my $flush = exists $opt{"autoflush"} ? $opt{"autoflush"} : 1;
	$fh->autoflush($flush ? 1 : 0);
	return $fh;
}

# Feed a line in small pieces, pausing between them so the sketch's loop drains
# each one before the next. Returns the number of bytes written, or 0 when a
# piece could not be written.
sub write_paced {
	my ($fh, $line, $chunk, $delay_ms) = @_;
	return 0 unless $fh && defined $line;
	$chunk = $PACING_CHUNK unless defined $chunk && $chunk > 0;
	$delay_ms = $PACING_DELAY_MS unless defined $delay_ms;
	for (my $off = 0; $off < length($line); $off += $chunk) {
		return 0 unless print {$fh} substr($line, $off, $chunk);
		select(undef, undef, undef, $delay_ms / 1000) if $delay_ms > 0;
	}
	return length($line);
}

# Read until the reply matches $re or the deadline passes, whichever comes
# first. The whole buffer is returned, so the caller can still inspect an error
# line, an echoed command or boot noise. A closed handle returns what arrived
# before EOF; a deadline that is already past returns ''.
sub read_until {
	my ($fh, $re, $deadline) = @_;
	return '' unless $fh;
	$re = qr/$re/ unless ref $re eq 'Regexp';
	$deadline = time() + $READ_DEADLINE_SECONDS unless defined $deadline;
	require IO::Select;
	my $sel = IO::Select->new($fh);
	my $buf = '';
	while (time() < $deadline) {
		my @ready = $sel->can_read(0.25);
		next unless @ready;
		my $chunk = '';
		my $n = sysread($fh, $chunk, 4096);
		last unless defined $n && $n > 0;
		$buf .= $chunk;
		last if $buf =~ $re;
	}
	return $buf;
}

1;
