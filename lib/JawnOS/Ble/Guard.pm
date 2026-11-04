package JawnOS::Ble::Guard;

# The BLE listener is a long-lived child. The client already stops itself when
# its select goes bad, but a reader can also get stuck inside one event (a
# runaway line, a pathological value): it stays alive, reads nothing, and holds
# a core while the bridge queue grows. Nothing replaces a child that is hung but
# not dead, so the parent watches its CPU time and restarts it when it sustains
# a core without progress.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(cpu_ticks cpu_hog);

# cpu_ticks($pid) -> utime + stime, or undef when /proc is not available.
sub cpu_ticks {
	my ($pid) = @_;
	return unless defined $pid && $pid =~ /^\d+$/;
	open(my $fh, '<', "/proc/$pid/stat") or return;
	my $line = <$fh>;
	close $fh;
	return unless defined $line;
	# comm can contain spaces and parens; fields after the last ')' are fixed.
	my $close = rindex($line, ')');
	return if $close < 0;
	my @f = split ' ', substr($line, $close + 2);
	return $f[11] + $f[12];
}

# cpu_hog($delta_ticks, $seconds, $hz) -> true when that is >= 80% of a core.
# $hz is CLK_TCK (100 on Linux and Android).
sub cpu_hog {
	my ($delta, $seconds, $hz) = @_;
	return 0 unless defined $delta && defined $seconds && defined $hz;
	return 0 unless $seconds > 0 && $hz > 0 && $delta >= 0;
	return ($delta / $hz) / $seconds >= 0.8 ? 1 : 0;
}

1;
