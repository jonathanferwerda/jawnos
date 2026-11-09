package JawnOS::Platform::Runner;

# The one place the master names its tree process. On Unix the seam delegates
# to Mojo::IOLoop::ReadWriteFork, so Linux behaviour is unchanged; Windows has
# its own backend because that module cannot exist there (it needs IO::Pty and a
# real fork).
#
# Both backends provide:
#   new, conduit(\%spec), on(read|close|spawn|drain => $cb),
#   start(\%spec) -> pid, pid, alive, stop($signal), close
#
# Callbacks receive the runner first, which is what ReadWriteFork already emits
# and what the master's handlers read:
#   read  ($runner, $bytes)
#   close ($runner, $exit_value, $signal)
#   spawn, drain ($runner)

use strict;
use warnings;

sub new {
	my ($class, %opt) = @_;
	if ($^O eq 'MSWin32') {
		require JawnOS::Platform::Runner::Windows;
		return JawnOS::Platform::Runner::Windows->new(%opt);
	}
	require JawnOS::Platform::Runner::Unix;
	return JawnOS::Platform::Runner::Unix->new(%opt);
}

1;
