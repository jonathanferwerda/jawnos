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
		is(scalar @sender, 1, 'a socket write is one sender job, not two');
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

# --- the peer relay does not die on its own request -------------------------
# Mojo::Parameters::merge takes pairs; handed a single hashref it calls to_hash
# on it and dies. That bug sat in the relay's form body, so every output command
# that fell through to the peer relay died with it and no board was ever told.
# The body has to be a rendered form. Merging into body_params alone leaves the
# content type unset, so Mojo sends an empty body: the homebase saw no
# chip_id and answered "not sent" while everything else looked right.
like($devws, qr/=> form => \{ chip_id => \$chip_id, frame => encode_json\(\$frame\) \}/,
	'the relay sends its fields as a form body');
unlike($devws, qr/body_params->merge/, 'never a merge that leaves the content type unset');

{
	no warnings 'redefine';
	my $door = encode_json({ __specs => { homebase => '127.0.0.1:45547' } });
	*subs::embedded_operator_door = sub { return $door };
}
my $relayed = eval { subs::device_ws_peer_relay('chip1', { t => 'cmd', state => 'on' }) };
ok(!$@, 'a machine with a homebase answers instead of dying') or diag("died with: $@");
ok(!$relayed, 'and reports no delivery, so the caller keeps its own road');

my $bare = eval { subs::device_ws_peer_relay('chip1', { t => 'cmd' }) };
ok(!$@ && !$bare, 'a chip with no homebase is a plain no');

# The board roads are dials, and a dial in the request path is what made a burst
# queue behind a peer that could not answer. They all run in the sender now.
my $device_ws_at = index($notify_src, 'my $ws_sent = &subs::device_ws_command({');
my $sender_at   = index($notify_src, '&subs::subprocessor(sub {');
ok($sender_at >= 0 && $device_ws_at > $sender_at,
	'the socket road runs inside the sender, not in the request');
like($devws, qr/connect_timeout => 1,/, 'a peer that will not answer cannot hold a press for long');
like(read_file(root() . '/lib/JawnOS/Domain/Notify.pm'), qr/my \$deadline = time\(\) \+ 5;/,
	'the per-chip lock waits seconds, not a quarter of a minute');


# The board reports the homebase address its own network sees. Another machine
# may not be able to route to it (the Table reports 192.168.1.x; this machine is
# on 10.20.x plus Tailscale), so the same machine's recorded addresses are tried
# after it instead of the press dying on a connect timeout.
{
	package FakeRows204;
	sub hashes { return $_[0]->{'rows'} }
}

subtest 'the relay resolves the homebase it is told about' => sub {
	ok(subs::provides('device_ws_relay_hosts'), 'the loader maps the resolver');
	no warnings 'redefine';
	local *subs::db_select = sub {
		return bless { rows => [
			{ hostname => 'Table', ip => '100.64.0.1', tailnet_ip => '100.64.0.1', network => '' },
			{ hostname => 'hub', ip => '10.20.0.20', tailnet_ip => '', network => '{"lan":{"ip":"192.168.1.147"}}' },
		] }, 'FakeRows204';
	};
	is_deeply(subs::device_ws_relay_hosts({ __specs => { name => 'Table' } }, '192.168.1.102'),
		[ '192.168.1.102', '100.64.0.1' ],
		'the address the board named, then the machine the board names');
	is_deeply(subs::device_ws_relay_hosts({ __specs => {} }, '192.168.1.147'),
		[ '192.168.1.147', '10.20.0.20' ],
		'a payload with no name is recognised by the machine\'s own report');
	is_deeply(subs::device_ws_relay_hosts({ __specs => { name => 'Nobody' } }, '192.168.1.9'),
		[ '192.168.1.9' ], 'an unknown homebase keeps the board\'s address alone');
	is_deeply(subs::device_ws_relay_hosts({ __specs => { name => 'Table' } }, '100.64.0.1'),
		[ '100.64.0.1' ], 'an address already right is not dialled twice');
};


# A relayed frame has to reach the worker that holds the socket. Writing into the
# requesting process's registry found nothing and answered "not sent" while the
# socket sat open one worker away, so a peer's command never reached a board.
{
	package FakeWs204;
	sub send { push @{ $_[0]->{'sent'} }, $_[1]; return 1 }
}
subtest 'a relayed frame reaches the worker holding the socket' => sub {
	ok(subs::provides('device_ws_write_frame'), 'the loader maps the helper');
	is(subs::device_ws_write_frame('nobody', { t => 'cmd' }), 0,
		'no socket for the chip is a plain no');
	my $ws = bless { sent => [] }, 'FakeWs204';
	subs::device_ws_attach({ chip_id => 'writeme', edt => 'microcontroller', ws => $ws });
	is(subs::device_ws_write_frame('writeme', { t => 'cmd', pin => 28 }), 1,
		'a frame goes to a socket this process holds');
	is(scalar @{$ws->{'sent'}}, 1, 'exactly once');
	subs::device_ws_detach('writeme', $ws);
};

subtest 'the relay route uses it' => sub {
	require JawnOS::Controller::manager_ws;
	my $src = read_file(root() . '/lib/JawnOS/Controller/manager_ws.pm');
	like($src, qr/device_ws_write_frame\(\$chip_id, \$frame\)/,
		'a peer command is handed to the worker, not written into this process');
	unlike($src, qr/\$sent = &subs::device_ws_send_local\(\$chip_id, \$frame\);/,
		'and not by the local registry alone');
};


# A socket that has proved itself alive can put its presence mirror back: the file
# is what another worker or another machine reads to find the socket, and it can
# be gone while the socket is open (a failed write detaches, a stale finish
# unlinks, a full /tmp drops the write). Without it a relay takes the slow road.
{
	package FakeWsTouch;
	sub send { return 1 }
}
subtest 'the presence mirror heals' => sub {
	ok(subs::provides('device_ws_touch'), 'the loader maps the touch helper');
	my $ws = bless {}, 'FakeWsTouch';
	subs::device_ws_attach({ chip_id => 'touchme', edt => 'microcontroller', ws => $ws });
	my $file = subs::device_ws_presence_file('touchme');
	ok(-e $file, 'attaching writes the mirror');
	unlink $file;
	ok(!-e $file, 'the mirror can go missing while the socket lives');
	is(subs::device_ws_touch('touchme'), 1, 'a touch puts it back');
	ok(-e $file, 'and the mirror is there again');
	is(subs::device_ws_send_local('touchme', { t => 'cmd' }), 1, 'a frame goes to the socket');
	unlink $file;
	is(subs::device_ws_deliver({ message => Mojo::JSON::encode_json({ chip_id => 'touchme', frame => { t => 'cmd' } }) }), 1,
		'a delivered frame is written');
	ok(-e $file, 'and that delivery refreshes the mirror too');
	subs::device_ws_detach('touchme', $ws);
	is(subs::device_ws_touch('touchme'), 0, 'a chip with no socket has no mirror to write');
};

# And a delivered write ends the command: the fallback roads are for a board
# without a socket, not a second attempt at a board that already has the frame.
my $notify_now = read_file(root() . '/lib/JawnOS/Domain/Notify.pm');
my $ws_at = index($notify_now, 'my $ws_sent = &subs::device_ws_command({');
my $stop_at = index($notify_now, 'return if $ws_sent;');
my $lock_at = index($notify_now, 'my $lock = &subs::device_command_lock($chip_id);');
ok($ws_at >= 0 && $stop_at > $ws_at && $lock_at > $stop_at,
	'a socket write returns before the lock and the fallback roads');

done_testing();
