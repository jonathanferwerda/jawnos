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
BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}
use JawnOS::Platform::Process ();
our @EXPORT_OK = qw(cpu_ticks cpu_hog);

# cpu_ticks($pid) -> utime + stime, or undef when the platform cannot read
# them. /proc parsing lives in JawnOS::Platform::Process.
sub cpu_ticks {
	return JawnOS::Platform::Process::cpu_ticks($_[0]);
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
