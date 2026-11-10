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

# ---- how often the watchdog may ask ------------------------------------------
# serving() is one question: did this port answer just now? A single stalled
# request, a database lock held for a second, or a phone coming out of doze can
# each swallow one probe. Two such misses thirty seconds apart used to add up to
# "the tree is dead", and the master restarted a tree that was answering: the
# wedge dumps it wrote show every process idle in the event loop.
#
# So the pace is a policy, not a constant. The poll is slow while the tree
# answers and tight once one probe has failed; three failures in a row, seconds
# apart, is a tree that is not serving. One miss costs an extra probe and no
# restart.
#
#   rest     seconds between probes while the tree answers (the phone's cost)
#   confirm  seconds between probes once one has failed
#   strikes  consecutive failures that mean the tree is down
#   timeout  seconds a single port gets before the probe counts it a miss
sub watch_policy {
	return (
		rest    => 30,
		confirm => 3,
		strikes => 3,
		timeout => 2,
	);
}

# Seconds to wait before the next probe, given how many have failed in a row.
# Zero misses means the tree answered: go back to the resting pace, so a healthy
# phone pays for one probe a half-minute rather than a confirmation burst.
sub watch_delay {
	my ($misses) = @_;
	my %policy = watch_policy();
	return $policy{'rest'} unless $misses;
	return $policy{'confirm'};
}

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
	my %policy  = watch_policy();
	my $timeout = $option{'timeout'} || $policy{'timeout'} || 2;
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
