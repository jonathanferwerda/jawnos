package Node;

# A node that can actually open a WebSocket, for the CDP probes.
#
# qa/ux/attempt.js and qa/ui/probe.js speak to Chromium through the global
# WebSocket constructor. Debian's node (/usr/bin/node, v20) does not define it;
# the owner's own node (~/.local/opt/node/bin, v26) does. A systemd unit's PATH
# answers `node` with the Debian one, so every browser attempt died with
# "WebSocket is not defined" - an attempt that never started, recorded as if
# the page had failed.
#
# resolve() answers { command, args } for a node that passes a real capability
# check, or undef. The check is a subprocess, not a version string: a build can
# be new and still lack the constructor, and --experimental-websocket (v20+)
# is enough when it does.

use strict;
use warnings;

our $VERSION = '1';

my $PROBE = 'process.exit(typeof WebSocket === "function" ? 0 : 1)';

# The candidates in the order the owner expects them to win: an explicit
# override, the local node the desktop and IDE already use, then whatever PATH
# answers (which is what a service manager gives us).
sub candidates {
	my @out;
	push @out, $ENV{'JAWNOS_NODE'}
		if defined $ENV{'JAWNOS_NODE'} && length $ENV{'JAWNOS_NODE'};
	push @out, $ENV{'HOME'} . '/.local/opt/node/bin/node'
		if defined $ENV{'HOME'} && length $ENV{'HOME'};
	my $on_path = `command -v node 2>/dev/null`;
	chomp $on_path if defined $on_path;
	push @out, $on_path if defined $on_path && length $on_path;
	my %seen;
	return grep { !$seen{$_}++ } @out;
}

# Does this command define the global constructor, with these arguments?
sub capable {
	my ($command, @args) = @_;
	return 0 unless defined $command && length $command && -x $command;
	my $rc = system($command, @args, '-e', $PROBE);
	return (defined $rc && $rc == 0) ? 1 : 0;
}

sub resolve {
	for my $command (candidates()) {
		next unless -x $command;
		return { command => $command, args => [] } if capable($command);
		my @flag = ('--experimental-websocket');
		return { command => $command, args => \@flag } if capable($command, @flag);
	}
	return undef;
}

1;
