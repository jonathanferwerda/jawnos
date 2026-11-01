#!/usr/bin/perl
#
# "Is the tree actually answering?" — the master's liveness question.
#
# A connect() is not that question. A tree whose event loop is blocked (a wedged
# SQLite write, a handler waiting on a lock, a process stopped in the kernel)
# still holds its listening socket, and the kernel completes the handshake into
# the accept queue: connect() succeeds while nothing is being served. The
# watchdog in ./jawn used a bare connect, so it read exactly the failure it
# exists to catch as healthy and never recovered the tree.
#
# serving() asks for an HTTP answer instead, and the route it asks by default
# (/manager/health) reads the database, so a lock that wedges the handlers is a
# failed probe too. The route is loopback-open, and the probe only ever talks to
# 127.0.0.1, so it needs no credential.
#
# It tries TLS first (the tree serves HTTPS) and then plain HTTP, so an install
# with TLS off probes rather than flapping. Both are bounded by one timeout.

package probe;

use strict;
use warnings;

# serving($port, %options) -> 1 when the tree on $port answers, 0 when it does
# not. Options: timeout (seconds, default 2), path (default /manager/health).
#
# "Answers" means an HTTP response with a status below 500: a 401 or a 404 is
# still a live event loop, but a 5xx is a handler that failed — the health route
# returns 5xx when the database read behind it cannot complete, which is the
# wedge this probe is for. No response at all (refused, timeout, TLS failure)
# is HTTP::Tiny's 599.
sub serving {
	my ($port, %option) = @_;
	return 0 unless defined $port && $port =~ /^[0-9]+$/ && $port > 0;
	my $timeout = $option{'timeout'} || 2;
	my $path    = $option{'path'} || '/manager/health';

	require HTTP::Tiny;
	my $ua = HTTP::Tiny->new(
		timeout      => $timeout,
		verify_SSL   => 0,
		max_redirect => 0,
		keep_alive   => 0,
		agent        => 'jawnos-watchdog'
	);

	foreach my $scheme (qw(https http)) {
		my $url = $scheme . '://127.0.0.1:' . $port . $path;
		my $res = eval { $ua->get($url) };
		next unless $res && ref $res eq 'HASH';
		my $status = $res->{'status'} || 0;
		return 1 if $status >= 200 && $status < 500;
	}
	return 0;
}

1;
