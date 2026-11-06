# tests-for: lib/JawnOS/Domain/Render.pm lib/JawnOS/Domain/Edt.pm lib/JawnOS/Domain/Lan.pm
# covers:    A watch pin's named destination is dialled even when the roster
#            marks it inactive; a miss is handed to the headless relay queue
#            (retried while the peer is away) instead of running on the watch's
#            homebase, and the press reports ok/all/sent/expected back to the
#            device for its red or green flash.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);
use RepoSource;
use JawnOSTest;

# --- a stand-in peer agent ---------------------------------------------------
# Only the chain destination_relay uses: connect_timeout(...)->inactivity_timeout
# (...), then insecure(1)->post(url => form => {...})->result.
{
	package FakeUA;
	sub new {
		my ($class, %arg) = @_;
		return bless {
			posted     => [],
			ok_queue   => $arg{'ok_queue'} || [],
			ok_default => $arg{'ok'} ? 1 : 0,
		}, $class;
	}
	sub connect_timeout    { return $_[0] }
	sub inactivity_timeout { return $_[0] }
	sub insecure           { return $_[0] }
	sub post {
		my ($self, $url, $how, $form) = @_;
		my $ok = @{$self->{'ok_queue'}} ? shift @{$self->{'ok_queue'}} : $self->{'ok_default'};
		push @{$self->{'posted'}}, { url => $url, form => { %{$form || {}} }, ok => $ok };
		return FakeTx->new($ok);
	}
}
{
	package FakeTx;
	sub new { return bless { ok => $_[1] }, $_[0] }
	sub result { return FakeRes->new($_[0]->{'ok'}) }
}
{
	package FakeRes;
	sub new { return bless { ok => $_[1] }, $_[0] }
	sub is_success { return $_[0]->{'ok'} ? 1 : 0 }
	sub code       { return $_[0]->{'ok'} ? 200 : 500 }
}

my $PEER_SIG  = 'peer-sig-0001';
my $PEER_UUID = 'peer-uuid-0001';
my $ua;
my @lister_calls;
my @roster;
my @queued;

{
	no warnings 'redefine';
	local *subs::remote_machine_lister = sub {
		my $args = shift || {};
		push @lister_calls, { %{$args} };
		my @rows = @roster;
		# Honour the filters the real lister applies, so an `active`-only lookup
		# really finds nothing when the row is inactive.
		@rows = grep { ($_->{'connection'} || '') eq $args->{'connection'} } @rows
			if $args->{'connection'};
		@rows = grep { ($_->{'signatorial'} || '') eq $args->{'signatorial'} } @rows
			if $args->{'signatorial'};
		return [ @rows ];
	};
	local *subs::remote_useragent_maker = sub {
		return { ua => $ua, manager => 'https://192.168.1.123:45545', ip => '192.168.1.123' };
	};
	local *subs::remote_relay_queue_push = sub {
		my ($item) = @_;
		push @queued, { %{$item} };
		return 1;
	};

	# --- a named destination is dialled while the roster says inactive --------
	@roster = ({
		signatorial => $PEER_SIG,
		hostname    => 'Laptop',
		device      => 'computer',
		connection  => 'inactive',
		ip          => '192.168.1.123',
		manager     => 'https://192.168.1.123:45545',
		port        => 45545,
		uuid        => $PEER_UUID,
		tunnel      => 'no',
	});
	$ua = FakeUA->new(ok => 1);
	@lister_calls = ();
	@queued = ();

	my $relay = subs::destination_relay({
		destination => $PEER_SIG,
		app         => 'vol_+',
		movement    => 'command',
		timestamp   => 1,
	});

	is($relay->{'ok'}, 1, 'a named destination relays even when the roster says inactive');
	is($relay->{'all'}, 0, 'a named destination is not a fan-out');
	is($relay->{'sent'}, 1, 'one machine took it');
	is($relay->{'expected'}, 1, 'and one was asked');
	is($relay->{'queued'}, 0, 'a direct delivery needs no queue');
	is($relay->{'label'}, 'Laptop (192.168.1.123)', 'the label names the machine');
	is(scalar @lister_calls, 1, 'the destination row is looked up once');
	ok(!exists $lister_calls[0]->{'connection'}, 'the named lookup does not demand an active row');
	is(scalar @{$ua->{'posted'}}, 1, 'the command reached the named machine');
	is($ua->{'posted'}[0]->{'url'}, 'https://192.168.1.123:45545/manager/reset',
		'the relay posts to the peer\'s reset route');
	is($ua->{'posted'}[0]->{'form'}{'type'}, 'command', 'the movement rides the relay');
	is($ua->{'posted'}[0]->{'form'}{'app'}, 'vol_+', 'and the app it belongs to');

	# --- a named miss is handed to the relay, not run on the homebase ---------
	$ua = FakeUA->new(ok => 0);
	@queued = ();
	$relay = subs::destination_relay({
		destination => $PEER_SIG,
		app         => 'vol_-',
		movement    => 'command',
		timestamp   => 2,
	});
	is($relay->{'sent'}, 0, 'the direct attempt failed');
	is($relay->{'queued'}, 1, 'the named miss is handed to the headless relay');
	is($relay->{'ok'}, 1, 'a queued movement still counts as handed over');
	is(scalar @queued, 1, 'exactly one queue item is left');
	is($queued[0]->{'path'}, '/manager/reset', 'the queue item posts the reset route');
	is($queued[0]->{'remote_uuid'}, $PEER_UUID, 'and targets the named machine');
	ok($queued[0]->{'expect_json'}, 'the item expects the route\'s JSON answer');
	is($queued[0]->{'params'}{'app'}, 'vol_-', 'the app rides the queued copy');
	is($queued[0]->{'params'}{'type'}, 'command', 'and the movement');

	# --- every machine: red when one missed, green only when all took it ------
	@roster = (
		{ signatorial => 'peer-a', hostname => 'Laptop', connection => 'active',
		  ip => '192.168.1.123', manager => 'https://192.168.1.123:45545',
		  port => 45545, uuid => 'uuid-a', tunnel => 'no' },
		{ signatorial => 'peer-b', hostname => 'Table', connection => 'active',
		  ip => '192.168.1.147', manager => 'https://192.168.1.147:45545',
		  port => 45545, uuid => 'uuid-b', tunnel => 'no' },
	);
	$ua = FakeUA->new(ok_queue => [ 1, 0 ]);
	$relay = subs::destination_relay({
		destination => 'all',
		app         => 'vol_+',
		movement    => 'command',
		timestamp   => 3,
	});
	is($relay->{'all'}, 1, 'an every-machine command is a fan-out');
	is($relay->{'expected'}, 2, 'both active machines are asked');
	is($relay->{'sent'}, 1, 'one took it');
	is($relay->{'ok'}, 0, 'a missed machine means failure (the button turns red)');
	is($relay->{'queued'}, 0, 'a fan-out is never queued for replay');

	$ua = FakeUA->new(ok_queue => [ 1, 1 ]);
	$relay = subs::destination_relay({
		destination => 'all',
		app         => 'vol_+',
		movement    => 'command',
		timestamp   => 4,
	});
	is($relay->{'sent'}, 2, 'both machines took it');
	is($relay->{'ok'}, 1, 'every machine reached means success (the button turns green)');

	# --- a named row with no uuid cannot be queued ----------------------------
	@roster = ({
		signatorial => $PEER_SIG, hostname => 'Laptop', connection => 'inactive',
		ip => '192.168.1.123', manager => 'https://192.168.1.123:45545', port => 45545,
		tunnel => 'no',
	});
	$ua = FakeUA->new(ok => 0);
	@queued = ();
	$relay = subs::destination_relay({
		destination => $PEER_SIG, app => 'vol_+', movement => 'command', timestamp => 5,
	});
	is($relay->{'queued'}, 0, 'without a uuid there is no queue target');
	is($relay->{'ok'}, 0, 'and the press reports the failure');
	is(scalar @queued, 0, 'nothing is queued');
}

# --- the queue retries a targeted item, and drains a broadcast once ---------
# Load the real definitions first: a module compiled inside the local scope below
# would replace the stub it is meant to be shadowing.
subs::preload('relay_headless');
subs::preload('setting_grabber');
{
	my %store;
	my $now = 1_800_000_000_000;
	my $relay_mode = 'fail';
	{
		no warnings 'redefine';
		local *subs::setting_grabber = sub { my ($a) = @_; return $store{ $a->{'setting'} }; };
		local *subs::setting_setter  = sub { my ($a) = @_; $store{ $a->{'setting'} } = $a->{'value'}; return 1; };
		local *subs::rightNow        = sub { return $now };
		local *subs::relay_headless  = sub {
			return $relay_mode eq 'ok' ? '{"ok":1}' : undef;
		};

		ok(subs::remote_relay_queue_push({
			path => '/manager/reset',
			remote_uuid => 'uuid-a',
			params => { app => 'vol_+', type => 'command' },
			expect_json => 1,
			expires => $now + 60_000,
		}), 'a targeted item is queued');
		my $q = decode_json($store{'remote_relay_queue'});
		is(scalar @{$q}, 1, 'the queue holds it');

		is(subs::remote_relay_queue_run(), 0, 'a stalled peer delivers nothing');
		$q = decode_json($store{'remote_relay_queue'});
		is(scalar @{$q}, 1, 'the targeted item is kept for the next pass');
		is($q->[0]->{'attempts'}, 1, 'and its attempt count moves');

		$relay_mode = 'ok';
		is(subs::remote_relay_queue_run(), 1, 'the next pass delivers it');
		$q = decode_json($store{'remote_relay_queue'});
		is(scalar @{$q}, 0, 'and the delivered item leaves the queue');

		$relay_mode = 'fail';
		subs::remote_relay_queue_push({
			path => '/manager/reset', remote_uuid => 'uuid-a', expect_json => 1,
			expires => $now - 1,
		});
		is(subs::remote_relay_queue_run(), 0, 'an expired item is not delivered');
		$q = decode_json($store{'remote_relay_queue'});
		is(scalar @{$q}, 0, 'and it is dropped rather than retried forever');

		subs::remote_relay_queue_push({
			path => '/manager/reset', params => { app => 'vol_+' },
		});
		# A broadcast has no per-peer answer to read, so an attempt is the most
		# the drain can report; the point is that it leaves the queue either way.
		is(subs::remote_relay_queue_run(), 1, 'a broadcast is drained once');
		$q = decode_json($store{'remote_relay_queue'});
		is(scalar @{$q}, 0, 'and is not replayed');
	}
}

# --- the press hands its pin's destination over ------------------------------
my $root = repo_root();
my $edt = read_file("$root/lib/JawnOS/Domain/Edt.pm");
my ($press) = $edt =~ /(sub edt_button_presser \{.*?\n\})/s;
ok($press, 'edt_button_presser is still one sub');
like($press, qr/my \$destination = \$b->\{'destination'\} \|\| ''/,
	'the press reads the pin\'s named machine');
like($press, qr/&subs::destination_relay\(\{ destination => \$destination/,
	'and relays the movement to it');
like($press, qr/elsif \(\$relay_outcome->\{'queued'\}\)/,
	'a named miss is taken as queued, not as a local run');
like($press, qr/relay_ok.*relay_all.*relay_sent.*relay_expected/s,
	'the device is told the outcome for its red or green flash');
like($press, qr/unless \(\$ran_away\) \{.*?run_command\(/s,
	'the local run is only the last resort');

done_testing();
