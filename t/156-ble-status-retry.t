# tests-for: lib/JawnOS/Domain/Network.pm
# covers:    a bridge status event for a link that is waiting out its retry
#           reads as "reconnecting", the same as the disconnected event. The
#           daemon reports the raw state plus next_retry_ms; reading it as
#           "disconnected" made ble_enforce_hosts issue a fresh connect every
#           minute, resetting the daemon's backoff and attempt count (339
#           attempts on an absent board).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

subs::preload('ble_link_apply_event');

my $watch = '64:E8:33:4B:38:39';
my $key   = subs::ble_link_key($watch);

# A link in the daemon's backoff window.
$gb::ble_links = {};
subs::ble_link_apply_event({
	event    => 'status',
	protocol => 2,
	connected => 0,
	links    => [ {
		mac           => $watch,
		connected     => 0,
		state         => 'disconnected',
		next_retry_ms => 4058,
		attempt       => 339,
	} ],
});
is( $gb::ble_links->{$key}{'state'}, 'reconnecting',
	'a status link waiting out its retry reads as reconnecting' );
is( $gb::ble_links->{$key}{'next_retry_ms'}, 4058,
	'the retry delay is kept for the host pass' );
is( $gb::ble_links->{$key}{'attempt'}, 339, 'the attempt count is kept' );

# Idle: nothing pending, so the host pass may connect.
$gb::ble_links = {};
subs::ble_link_apply_event({
	event    => 'status',
	protocol => 2,
	connected => 0,
	links    => [ { mac => $watch, connected => 0, state => 'disconnected', next_retry_ms => 0 } ],
});
is( $gb::ble_links->{$key}{'state'}, 'idle', 'a link with no pending retry is idle' );

# A live link stays connected, whatever the retry field says.
$gb::ble_links = {};
subs::ble_link_apply_event({
	event    => 'status',
	protocol => 2,
	connected => 1,
	links    => [ { mac => $watch, connected => 1, state => 'connected', next_retry_ms => 0 } ],
});
is( $gb::ble_links->{$key}{'state'}, 'connected', 'a connected link stays connected' );

# v1 daemon: no links[], the top-level fields are the one link.
$gb::ble_links = {};
subs::ble_link_apply_event({ event => 'status', connected => 1, mac => $watch, mtu => 23 });
is( $gb::ble_links->{$key}{'state'}, 'connected', 'a v1 status still maps its primary link' );

# A disconnected event already carried this reading; keep it.
$gb::ble_links = { $key => { mac => $key, connected => 1, state => 'connected' } };
subs::ble_link_apply_event({ event => 'disconnected', mac => $watch, status => 147, next_retry_ms => 30000 });
is( $gb::ble_links->{$key}{'state'}, 'reconnecting', 'a disconnected event with a retry is reconnecting' );
is( $gb::ble_links->{$key}{'connected'}, 0, 'and the link is down' );

done_testing();
