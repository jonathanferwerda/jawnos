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


# The ports a tree is required to answer on. The manager (`working_port`) is
# the one the app opens and must always answer. The dock (`port`) is a second
# listener only a machine with a LAN door binds: since v0.1.2169 a handheld
# binds none (no board and no guest at 3000), so requiring it made the boot
# watch call a healthy phone dead and restart it every ninety seconds.
# A handheld asks for the manager alone; if it names no working_port, the dock
# is still the only port there is.
sub required_ports {
	my ($cfg) = @_;
	return () unless $cfg && ref $cfg eq 'HASH';
	my $dock = &_port($cfg->{'port'});
	my $work = &_port($cfg->{'working_port'});
	if (&is_mobile($cfg)) {
		return $work ? ($work) : $dock ? ($dock) : ();
	}
	my @ports;
	push @ports, $dock if $dock;
	push @ports, $work if $work && $work != $dock;
	return @ports;
}

sub _port {
	my $port = shift;
	return 0 unless defined $port && $port =~ /^[0-9]+$/ && $port > 0;
	return $port + 0;
}

# Whether this config belongs to a handheld. An explicit `device` wins, so a
# test (or a config copied between machines) is read as it says; only a config
# that names no device falls back to the system image. `$^O` is 'linux' on
# Android too, so the image, ANDROID_ROOT and the app's own package variable are
# the signals - the same ones House.pm's sshd_platform uses.
sub is_mobile {
	my ($cfg) = @_;
	my $device = ($cfg && ref $cfg eq 'HASH' && defined $cfg->{'device'}) ? lc($cfg->{'device'}) : '';
	return 1 if $device eq 'mobile';
	return 0 if length $device;
	return 1 if defined $ENV{'ANDROID_ROOT'} && length $ENV{'ANDROID_ROOT'};
	return 1 if defined $ENV{'JAWNOS_APP_PACKAGE'} && length $ENV{'JAWNOS_APP_PACKAGE'};
	return 1 if -e '/system/bin/init';
	return 0;
}

1;
