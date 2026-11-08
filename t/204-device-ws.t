# tests-for: lib/JawnOS/Domain/Devicews.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_ws.pm lib/JawnOS/Routes/manager_ws.pm lib/JawnOS/Manager/Core2_worker_boot.pm perl/gb/01_state_and_defaults.pl perl/watch.pl
# covers:    the /device/ws output bus: frame and snapshot shape, the per-process
#            registry and its cross-worker presence mirror, the not-connected
#            fallback in embedded_toggle, the route row, and the static promise
#            that inputs stayed on HTTP.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;

for my $name (qw(
	device_ws_registry device_ws_presence_file device_ws_attach device_ws_detach
	device_ws_peer device_ws_connected device_ws_command_frame device_ws_snapshot
	device_ws_deliver device_ws_command device_ws_ack embedded_toggle
)) {
	subs::preload($name);
}

{
	package FakeWS;
	sub new { bless { sent => [] }, shift }
	sub send {
		my ($self, $msg) = @_;
		push @{ $self->{'sent'} }, $msg;
		return 1;
	}
}

# A pid that is gone, so the presence mirror can be tested without a live
# websocket worker. Waiting on the child makes the pid reused only by a race
# that does not exist in a short test.
sub dead_pid {
	my $pid = fork();
	die "fork: $!" unless defined $pid;
	if (!$pid) { exit 0 }
	waitpid($pid, 0);
	return $pid;
}

subtest 'command frame carries the fields the HTTP query carries' => sub {
	my $frame = subs::device_ws_command_frame({
		chip_id => 'chip1',
		appt_uuid => 'apt',
		uuid => 'u',
		when => 'now',
		pin => 28,
		state => 1,
		component => 'relay',
		timestamp => 1700000000000,
		measure => 'm',
		# Neither of these belongs on the socket: the connection is already
		# authenticated, and the HTTP query never carried it.
		authorization => 'now-me-secret',
		junk => 'x',
	});
	is_deeply($frame, {
		t => 'cmd',
		appt_uuid => 'apt',
		uuid => 'u',
		when => 'now',
		pin => 28,
		state => 1,
		component => 'relay',
		timestamp => 1700000000000,
		measure => 'm',
	}, 'the command frame is exactly the HTTP output fields');
	ok(!exists $frame->{'authorization'}, 'no Now Me token rides the authenticated socket');
	ok(!exists $frame->{'junk'}, 'unknown fields are not forwarded');
	is_deeply(subs::device_ws_command_frame({ component => 'led' }),
		{ t => 'cmd', component => 'led' }, 'a partial command still frames');
	is_deeply(subs::device_ws_command_frame(undef), { t => 'cmd' }, 'no data is an empty command');
};

subtest 'snapshot reuses the /watch role builder' => sub {
	# watch_room_payload is the helper /watch and the BLE bridge already use.
	# The snapshot must be its component entries, not a second state model.
	no warnings 'redefine';
	local *subs::watch_room_payload = sub {
		my ($data) = @_;
		is($data->{'chip_id'}, 'chip1', 'the snapshot asks for this chip');
		is($data->{'edt'}, 'microcontroller', 'and this device class');
		return {
			relay28 => { component => 'relay', pin => 28, app => 'lights', toggle => 1 },
			led4    => { component => 'led',   pin => 4,  app => 'lights', toggle => 0 },
			__specs  => { name => 'Bench', authorization => 'x' },
			__shutup => { patience => 'p' },
		};
	};
	my $snap = subs::device_ws_snapshot({ chip_id => 'chip1', edt => 'microcontroller' });
	is($snap->{'t'}, 'snap', 'the snapshot frame names itself');
	is($snap->{'chip'}, 'chip1', 'and its chip');
	is(scalar @{ $snap->{'components'} }, 2, 'only component entries are components');
	is($snap->{'components'}->[0]->{'name'}, 'led4', 'components are sorted by name');
	is($snap->{'components'}->[0]->{'toggle'}, 0, 'the helper toggle rides the entry');
	is($snap->{'components'}->[1]->{'name'}, 'relay28');
	is($snap->{'components'}->[1]->{'toggle'}, 1);
	ok(!exists $snap->{'components'}->[0]->{'__specs'}, 'manager bookkeeping is not a component');
	ok(!exists $snap->{'__shutup'}, 'no pairing patience leaves the manager');

	{
		# A chip with no operator_door row has no role yet; the frame is still
		# valid, with no components.
		local *subs::watch_room_payload = sub { undef };
		my $empty = subs::device_ws_snapshot({ chip_id => 'chip2', edt => 'microcontroller' });
		is_deeply($empty->{'components'}, [], 'no role means an empty component list');
	}
};

subtest 'registry, presence mirror and delivery' => sub {
	my $dir = tempdir(CLEANUP => 1);
	local $gb::tmp_dir = $dir;
	%{ subs::device_ws_registry() } = ();

	my $ws = FakeWS->new;
	my $entry = subs::device_ws_attach({
		chip_id => 'chip1', edt => 'microcontroller',
		ip => '10.0.0.9', name => 'Bench', ws => $ws,
	});
	is(ref $entry, 'HASH', 'attach returns the registry entry');
	is(subs::device_ws_peer('chip1')->{'name'}, 'Bench', 'the peer lookup carries the name');
	ok(subs::device_ws_connected('chip1'), 'an in-process socket is connected');
	ok(!subs::device_ws_connected('nope'), 'an unknown chip is not connected');

	my $file = subs::device_ws_presence_file('chip1');
	ok(-e $file, 'attach writes the cross-worker presence mirror');

	# A main or watch worker has an empty registry; the mirror is what lets it
	# see the websocket worker's live socket.
	%{ subs::device_ws_registry() } = ();
	ok(subs::device_ws_connected('chip1'), 'a live worker pid keeps the mirror connected');

	my $row = decode_json(read_file($file));
	$row->{'pid'} = dead_pid();
	write_file($file, encode_json($row));
	ok(!subs::device_ws_connected('chip1'), 'a dead worker pid is not connected');

	# Delivery is the in-process registry, not the mirror.
	%{ subs::device_ws_registry() } = ();
	my $live = FakeWS->new;
	subs::device_ws_attach({ chip_id => 'chip1', edt => 'microcontroller', ws => $live });
	my $wire = { message => encode_json({ chip_id => 'chip1', frame => { t => 'cmd', pin => 28 } }) };
	is(subs::device_ws_deliver($wire), 1, 'a connected chip takes the frame');
	is(scalar @{ $live->{'sent'} }, 1, 'one frame went out');
	my $sent = decode_json($live->{'sent'}->[0]);
	is($sent->{'t'}, 'cmd', 'the command frame is forwarded');
	is($sent->{'pin'}, 28, 'with its pin');
	is(subs::device_ws_deliver({ message => encode_json({ chip_id => 'other', frame => { t => 'cmd' } }) }),
		0, 'an unconnected chip delivers nothing');

	is(subs::device_ws_command({ chip_id => 'chip1', component => 'relay', pin => 28, state => 1 }),
		1, 'the in-process command path writes the socket');
	is(scalar @{ $live->{'sent'} }, 2, 'the command added a frame');
	is(decode_json($live->{'sent'}->[1])->{'component'}, 'relay', 'the command names its component');

	# A reconnect wins over the old socket's finish handler.
	my $newer = FakeWS->new;
	subs::device_ws_attach({ chip_id => 'chip1', edt => 'microcontroller', ws => $newer });
	is(subs::device_ws_detach('chip1', $live), 0, 'an old finish cannot drop the new socket');
	is(subs::device_ws_peer('chip1')->{'ws'}, $newer, 'the newer socket owns the chip');
	is(subs::device_ws_detach('chip1', $newer), 1, 'its own finish drops it');
	ok(!subs::device_ws_peer('chip1'), 'and the registry is empty');
	ok(!-e $file, 'the mirror is removed with the socket');
};

subtest 'embedded_toggle falls back when no device socket is attached' => sub {
	no warnings 'redefine';
	my @sender;
	local *subs::subprocessor = sub { push @sender, 1; return };
	local *subs::toggle_event_is_older = sub { 0 };
	local *subs::event_time_ms = sub { $_[0] };
	local *subs::rightNow = sub { 1700000000000 };
	local *subs::setting_grabber = sub {
		my ($args) = @_;
		return '{}' if (($args->{'setting'} || '') eq 'operator_door');
		return '';
	};
	local *subs::setting_setter = sub { 1 };
	local *subs::shorthand_name = sub { 'relay' };
	local *subs::icon_path = sub { '/icon.png' };
	local *subs::random_string_creator = sub { 'rand' };
	local *Websocket::send = sub { 1 };

	my $command = {
		app => 'lights', pin => 28, edt => 'microcontroller', chip_id => 'chip1',
		component => 'relay', state => 'on', when => 'now',
		timestamp => 1700000000000,
		counted => 0,
	};

	{
		local *subs::device_ws_command = sub { 0 };
		my $returner = subs::embedded_toggle({ %{$command} });
		is(scalar @sender, 1, 'no socket: the existing HTTP-then-BLE sender still runs');
		is($returner->{'state'}, 1, 'and the toggle result is the usual one');
		is($returner->{'formatted_state'}, 'on', 'with the formatted state unchanged');
	}

	{
		@sender = ();
		local *subs::device_ws_command = sub { 1 };
		my $returner = subs::embedded_toggle({ %{$command} });
		is(scalar @sender, 1, 'a socket write still runs the board route as a backstop');
		is($returner->{'state'}, 1, 'the socket path reports the same state');
		is($returner->{'formatted_state'}, 'on', 'and the same formatted state');
	}
};

# A socket write is not a board ack: a half-open link (or a peer's cached
# socket) can swallow it. The own-route sender must still run; the shared uuid
# makes the second copy a no-op on the board.
my $notify_src = read_file(root() . '/lib/JawnOS/Domain/Notify.pm');
like($notify_src, qr/my \$ws_sent = &subs::device_ws_command\(\{/, 'the socket write is recorded');
like($notify_src, qr/\(ws\)/, 'a socket write is logged');
like($notify_src, qr/if \$log && !\$ws_sent/, 'the not-delivered alarm is suppressed when the socket carried it');
my $early = () = $notify_src =~ /return \{ state => \$number_state/g;
is($early, 1, 'a socket write never returns before the board route runs');

subtest 'route row and action agree' => sub {
	require JawnOS::Routes::manager_ws;
	my @rows = JawnOS::Routes::manager_ws->routes;
	my ($row) = grep { $_->[2] eq '/device/ws' } @rows;
	ok($row, '/device/ws is registered');
	is($row->[1], 'websocket', 'as a websocket route');
	is($row->[3], 'action_' . $row->[0], 'the action name matches the row number');

	my $source = read_file('lib/JawnOS/Controller/manager_ws.pm');
	my @lines = split /\n/, $source;
	like($lines[$row->[0] - 1] || '', qr/^sub action_\Q$row->[0]\E\b/,
		'the row number is the line of the action sub');
	like($source, qr/&subs::embedded_authorizer\(\$c\)/, 'the device socket reuses the Now Me check');
	like($source, qr/\$c->rendered\(403\)/, 'a bad pair is refused with 403');
	like($source, qr/\$t eq 'ping'/, 'ping is answered');
	like($source, qr/\$t eq 'ack'/, 'acks are recorded');
	unlike($source, qr/\$t eq '(?:input|button|switch)'/, 'no input frame type is handled here');
};

subtest 'inputs stay on HTTP' => sub {
	my $watch = read_file('perl/watch.pl');
	for my $route (qw(/watch/button /watch/switch /watch/measure)) {
		like($watch, qr{^get '\Q$route\E'}m, "$route is still an HTTP GET");
	}
	# The browser's /manager/ws action writes appointments and is none of this
	# test's business: check the new device action alone.
	require JawnOS::Routes::manager_ws;
	my ($row) = grep { $_->[2] eq '/device/ws' } JawnOS::Routes::manager_ws->routes;
	my @lines = split /\n/, read_file('lib/JawnOS/Controller/manager_ws.pm');
	my $action = join "\n", @lines[ $row->[0] - 1 .. $#lines ];
	unlike($action, qr/edt_button_presser|appointment_writer/,
		'the device socket has no input writer');
};


# --- a frame that never reached the worker is not "delivered" ----------------

my $devws = read_file('lib/JawnOS/Domain/Devicews.pm');
my $cal   = read_file('lib/JawnOS/Domain/Calendar.pm');
my $wspl  = read_file('perl/Websocket.pl');

like($devws, qr/my \$sent = &Websocket::send\('device'/,
	'the device socket send is checked, not assumed');
like($devws, qr/return 1 if \$sent;/,
	'only a frame that went is reported as delivered');
my $checked = index($devws, q(return 1 if $sent;));
my $relay   = index($devws, q(return &device_ws_peer_relay($chip_id, $frame);));
ok($checked >= 0 && $relay >= 0 && $checked < $relay,
	'a failed send falls through to the peer relay instead of claiming delivery');
like($wspl, qr/\$returner = &subs::unix_socket_sender\(\$file,\$wsm\) if -e \$file;/,
	'the websocket push reports whether its frame went');
like($cal, qr/return \$rcv \? \$response_data : \(\$ok \? 1 : 0\);/,
	'the sender answers for a fire-and-forget push, where there is no reply to carry it');

done_testing();
