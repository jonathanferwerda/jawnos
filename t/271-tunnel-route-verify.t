#!/usr/bin/perl
# tests-for: lib/JawnOS/Domain/Remote.pm
# covers:    peer_secure_url treats a tunnel row as a loopback route and leaves
#            it exactly as it is. The flag outlived the tunnel on the hub: its
#            rows for the machines that used to dial out kept tunnel 'yes' after
#            the route moved to the tailnet, so the blanket return answered
#            "unverified" for a direct address whose house-CA leaf proves it.
#            remote_device_connect then refused the login as "the peer listener
#            is not verified", and every relay to that machine went out without
#            the session cookie it needs. Only a loopback route is the tunnel's.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;

use JawnOSTest;

require(root() . '/lib/JawnOS/Domain/Remote.pm');

{
	no warnings 'redefine';
	# Nothing here opens a socket: the probes answer from the stub, and the row
	# advertises one address.
	local *subs::peer_resolve_addresses = sub { return () };
	local *subs::peer_manager_host = sub { return ($_[0]->{'ip'} // '') };
	local *subs::peer_tls_port = sub { return 45551 };
	local *subs::peer_listener_port = sub { return 45551 };
	local *subs::peer_host_is_loopback = sub {
		my $host = shift || '';
		return 1 if $host =~ /^127\./;
		return 1 if $host =~ /^(?:localhost|::1)$/i;
		return 0;
	};

	my ($url, $verified);
	($url, $verified) = subs::peer_secure_url(
		{ ip => '127.0.0.1', tunnel => 'yes' }, 'https://127.0.0.1:45545');
	is($url, 'https://127.0.0.1:45545', 'a real tunnel keeps its loopback route');
	is($verified, 0, 'and is left unverified, as the tunnel always was');

	($url, $verified) = subs::peer_secure_url(
		{ ip => '100.64.0.9', tunnel => 'yes' }, 'https://100.64.0.9:45545');
	is($url, 'https://100.64.0.9:45551', 'a stale tunnel flag no longer hides a direct address');
	is($verified, 1, 'so the direct address is verified against the house CA');

	($url, $verified) = subs::peer_secure_url(
		{ ip => '100.64.0.9', tunnel => 'no' }, 'https://100.64.0.9:45545');
	is($verified, 1, 'an ordinary direct row still verifies');

	($url, $verified) = subs::peer_secure_url(
		{ ip => '10.0.0.5' }, 'https://198.51.100.7:45545');
	is($url, 'https://198.51.100.7:45545', 'a host the row does not advertise is untouched');
	is($verified, 0, 'and never claimed as verified');
}

done_testing();
