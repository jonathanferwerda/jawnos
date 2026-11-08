package subs;

# Devicews: the device output bus behind /device/ws. A board authenticates with
# the same rotated Now Me pair as /watch and /teletype/ws, holds one WebSocket
# open to the manager's websocket worker, and receives relay/led/servo frames
# there instead of over HTTP. Inputs (buttons, switches, pots) stay on their
# existing HTTP routes; this file carries outputs only.
#
# The registry is per process on purpose: the websocket worker is the one worker
# that does not recycle (keep_alive), so the sockets it holds live exactly as
# long as its registry does. %DEVICE_CONN is the authority for delivery.
#
# A main or watch worker has no socket of its own, so attach() mirrors the
# connected chips into tiny presence files beside the ws sockets. That mirror is
# what lets embedded_toggle() decide, without a live socket and without adding a
# table, whether to use the bus or fall back to HTTP and then BLE.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use File::Slurp;
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);

our $log;

# chip_id => { chip_id, edt, ip, name, since, ws, last_ack }
our %DEVICE_CONN;

sub device_ws_registry {
	return \%DEVICE_CONN;
}

sub device_ws_presence_file {
	my ($chip_id) = @_;
	return undef unless defined $chip_id && length $chip_id;
	my $dir = ($gb::tmp_dir || '.') . '/device_ws';
	return $dir . '/' . &path_name($chip_id) . '.json';
}

sub device_ws_attach {
	my ($data) = @_;
	$data = {} unless ref $data eq 'HASH';
	my $chip_id = $data->{'chip_id'} || '';
	return undef unless length $chip_id;
	my $entry = {
		chip_id => $chip_id,
		edt     => $data->{'edt'} || '',
		ip      => $data->{'ip'} || '',
		name    => $data->{'name'} || '',
		since   => time(),
		ws      => $data->{'ws'},
	};
	# A reconnecting board replaces its old entry; the old socket's finish
	# handler is guarded by the same ws reference so it cannot drop the new one.
	$DEVICE_CONN{$chip_id} = $entry;
	my $file = &device_ws_presence_file($chip_id);
	if ($file) {
		my $dir = $file;
		$dir =~ s{/[^/]+$}{};
		eval {
			mkdir $dir unless -d $dir;
			my %row = map { $_ => $entry->{$_} } qw(chip_id edt ip name since);
			$row{'pid'} = $$;
			write_file($file, encode_json(\%row));
			1;
		};
	}
	return $entry;
}

sub device_ws_detach {
	my ($chip_id, $ws) = @_;
	return 0 unless defined $chip_id && length $chip_id;
	my $current = $DEVICE_CONN{$chip_id};
	# A finish frame from a socket a reconnect already replaced must not remove
	# the newer connection.
	return 0 if $current && defined $ws && $current->{'ws'} && $current->{'ws'} != $ws;
	delete $DEVICE_CONN{$chip_id};
	my $file = &device_ws_presence_file($chip_id);
	unlink $file if $file && -e $file;
	return 1;
}

sub device_ws_peer {
	my ($chip_id) = @_;
	return undef unless defined $chip_id && length $chip_id;
	return $DEVICE_CONN{$chip_id};
}

sub device_ws_connected {
	# True when this process holds the socket, or when the websocket worker that
	# holds it is still alive. The presence file names the worker's pid: a
	# restarted (or crashed) worker leaves a file whose pid is gone, so a stale
	# mirror cannot send a command to a socket that is not there.
	my ($chip_id) = @_;
	return 0 unless defined $chip_id && length $chip_id;
	return 1 if $DEVICE_CONN{$chip_id};
	my $file = &device_ws_presence_file($chip_id);
	return 0 unless $file && -e $file;
	my $row = eval { decode_json(scalar read_file($file)) } || {};
	my $pid = $row->{'pid'} || 0;
	return 0 unless $pid && kill(0, $pid);
	return 1;
}

sub device_ws_command_frame {
	# The same fields the device's HTTP output query carries, in a frame. The
	# device's own Now Me token is deliberately absent: the socket was already
	# authenticated, so no secret rides the wire again.
	my ($data) = @_;
	$data = {} unless ref $data eq 'HASH';
	my $frame = { t => 'cmd' };
	foreach my $field (qw(appt_uuid uuid when pin state component timestamp measure)) {
		$frame->{$field} = $data->{$field} if defined $data->{$field};
	}
	return $frame;
}

sub device_ws_snapshot {
	# The board's current picture, built by the same helper the /watch route and
	# the BLE bridge use (watch_room_payload), so a socket connect cannot drift
	# from a Now Me. Only the component entries leave here; __specs/__shutup are
	# the manager's own bookkeeping.
	my ($data) = @_;
	$data = {} unless ref $data eq 'HASH';
	my $chip_id = $data->{'chip_id'} || '';
	my $edt = $data->{'edt'} || '';
	my $role = eval { &watch_room_payload({ edt => $edt, chip_id => $chip_id }) } || {};
	my @components;
	foreach my $name (sort keys %{$role}) {
		next if $name =~ /^__/;
		my $entry = $role->{$name};
		next unless ref $entry eq 'HASH';
		push @components, { name => $name, %{$entry} };
	}
	return {
		t          => 'snap',
		chip       => $chip_id,
		components => \@components,
	};
}

sub device_ws_send_local {
	# The socket is in this process: write the frame and say whether it went. A
	# failed write detaches so the caller can fall back.
	my ($chip_id, $frame) = @_;
	return 0 unless defined $chip_id && length $chip_id && ref $frame eq 'HASH';
	my $conn = $DEVICE_CONN{$chip_id} or return 0;
	my $sent = eval { $conn->{'ws'}->send(encode_json($frame)); 1 };
	unless ($sent) {
		&device_ws_detach($chip_id);
		return 0;
	}
	return 1;
}

sub device_ws_time_frame {
	# The house clock, offered to a board on the socket it already holds. A board
	# keeps time with its own crystal between /watch/time calls, and a 40 s drift
	# made a switch write its session in the past - and, once the socket carries
	# commands, made "now" look far enough off that the board's own ordering had
	# to guess. The frame is plain milliseconds since the epoch, UTC, so it needs
	# no token: the socket was already authenticated.
	my ($house_ms) = @_;
	return { t => 'time', ms => ($house_ms || &rightNow()) };
}

sub device_ws_clock_note {
	# The board answers a time frame with its millis() and the epoch it now
	# believes. Say the difference: a board minutes behind is the reason an
	# appointment written from a switch lands in the past, and a board that never
	# answers is the reason to look at the firmware it is running.
	my ($chip_id, $m) = @_;
	return 0 unless ref $m eq 'HASH';
	my $board = eval { $m->{'epoch_ms'} + 0 } || 0;
	return 0 unless $board > 0;
	my $skew = int(($board - &rightNow()) / 1000);
	$log->info('device clock: ' . ($chip_id || '?') . ' board and house differ by '
		. $skew . 's') if $log;
	return 1;
}

sub device_ws_write_frame {
	# Write an already-built frame to a board's socket. The socket is held by the
	# websocket worker, so a request handled anywhere else must hand the frame
	# over: a peer relaying a command to this homebase wrote into its own
	# process, found no registry entry, and answered "not sent" while the socket
	# sat open one worker away. 1 only when the frame actually went.
	my ($chip_id, $frame) = @_;
	return 0 unless defined $chip_id && length $chip_id && ref $frame eq 'HASH';
	return 1 if &device_ws_send_local($chip_id, $frame);
	return 0 unless &device_ws_connected($chip_id);
	my $socket = ($gb::tmp_dir || '.') . '/ws/device';
	return 0 unless -e $socket;
	return &Websocket::send('device', { chip_id => $chip_id, frame => $frame }) ? 1 : 0;
}

sub device_ws_deliver {
	# Called in the websocket worker for a Websocket::send('device', ...) frame.
	# 1 when the chip had a socket and the frame went out, 0 when it did not: the
	# caller's HTTP path then runs unchanged.
	my ($wsm) = @_;
	return 0 unless ref $wsm eq 'HASH';
	my $message = eval { decode_json($wsm->{'message'} || '') } || {};
	my $chip_id = $message->{'chip_id'} || '';
	my $frame = $message->{'frame'};
	return 0 unless length $chip_id && ref $frame eq 'HASH';
	return &device_ws_send_local($chip_id, $frame);
}

sub device_ws_relay_hosts {
	# Where to dial for a board's homebase, in order. A board reports the address
	# its own network sees, which another machine may not be able to route to at
	# all: the board's Table reports 192.168.1.x while this machine sits on
	# 10.20.x plus Tailscale, so every relay died on a connect timeout. The
	# homebase is a machine this house knows, so answer with the addresses it is
	# recorded under and let the caller try them in turn.
	my ($od, $host) = @_;
	my @hosts = (defined $host && length $host) ? ($host) : ();
	my $name = $od->{'__specs'}->{'name'} || '';
	my $rows = eval { &subs::db_select('remote_machines')->hashes } || [];
	my @rows = grep { ref $_ eq 'HASH' } @{$rows};
	# The board names its homebase; a machine's own network report is the second
	# way to recognise it when the name is missing (an older payload).
	my @match = length $name ? grep { lc($_->{'hostname'} || '') eq lc $name } @rows : ();
	@match = grep { ($_->{'network'} || '') =~ /\Q$host\E/ } @rows unless @match;
	foreach my $rm ( @match ) {
		foreach my $h ( $rm->{'tailnet_ip'}, $rm->{'ip'} ) {
			push @hosts, $h if defined $h && length $h;
		}
	}
	my %seen;
	return [ grep { !$seen{$_}++ } @hosts ];
}

sub device_ws_peer_relay {
	# The socket may be held by another House machine: the board is homed on the
	# Table and the person pressed start on the Phone. Ask the homebase over the
	# signed peer rail, which writes the frame to its own socket - one hop,
	# instead of an HTTP dial to the board. 0 when there is no homebase or it is
	# not holding the socket, so the caller's HTTP-then-BLE order is unchanged.
	my ($chip_id, $frame) = @_;
	return 0 unless defined $chip_id && length $chip_id && ref $frame eq 'HASH';
	my $od = eval { decode_json(&subs::embedded_operator_door('microcontroller', $chip_id) || '') } || {};
	my $hb = $od->{'__specs'}->{'homebase'} || '';
	my ($host, $arm) = $hb =~ /^(\d{1,3}(?:\.\d{1,3}){3}):(\d+)$/;
	return 0 unless $host && $arm;
	# President.pl: manager = port, ws = port + 1, arm = port + 2.
	my $port = $arm - 2;
	return 0 if $port <= 0;
	my @hosts = @{ &device_ws_relay_hosts($od, $host) };
	foreach my $candidate ( @hosts ) {
		# A peer that will answer answers at once (the Table answered a signed
		# frame in 0.15 s). A peer on a network this machine cannot route to must
		# not hold the press: one second, then the next address.
		my $ua = Mojo::UserAgent->new(connect_timeout => 1, inactivity_timeout => 2);
		$ua->insecure(1);
		my $tx = $ua->build_tx(POST => 'https://' . $candidate . ':' . $port . '/manager/device_ws');
		# Pairs, not a hashref: Mojo::Parameters::merge calls to_hash on a single
		# argument, and a plain hashref is not blessed - this died on every relay
		# and took the whole output command with it (every web press, silently).
		$tx->req->body_params->merge(chip_id => $chip_id, frame => encode_json($frame));
		&subs::peer_sign_request($tx->req);
		my $res = eval { $ua->start($tx)->result };
		next unless $res && $res->is_success;
		my $answer = eval { decode_json($res->body) } || {};
		next unless $answer->{'sent'};
		# Say which address carried it when it is not the one the board named:
		# that correction is the thing to see when a house has two networks.
		$log->info('device relay: ' . ($chip_id || '?') . ' via ' . $candidate . ':' . $port
			. ' (board named ' . $host . ')') if $log && $candidate ne $host;
		return 1;
	}
	return 0;
}

sub device_ws_command {
	# Hand one output command to a board if it holds a socket; 0 means the caller
	# keeps its existing HTTP-then-BLE ordering. In the websocket worker the
	# socket is local and is written directly (asking the fan-out socket from
	# inside its own event loop would deadlock). Elsewhere the presence mirror
	# says whether the worker that holds it is alive, and Websocket::send carries
	# the frame to that worker.
	my ($data) = @_;
	$data = {} unless ref $data eq 'HASH';
	my $chip_id = $data->{'chip_id'} || '';
	return 0 unless length $chip_id;
	my $frame = &device_ws_command_frame($data);
	my $conn = &device_ws_peer($chip_id);
	if ($conn) {
		my $sent = eval { $conn->{'ws'}->send(encode_json($frame)); 1 };
		return 1 if $sent;
		&device_ws_detach($chip_id);
		return 0;
	}
	# This machine's websocket worker may hold the socket: the presence mirror
	# names its pid, and the fan-out socket carries the frame there.
	if (&device_ws_connected($chip_id)) {
		my $socket = ($gb::tmp_dir || '.') . '/ws/device';
		if (-e $socket) {
			# Only a frame that reached the worker counts. A send that failed
			# (the worker between restarts, a cached socket gone) must fall
			# through to the peer relay, and then to the caller's HTTP-then-BLE
			# order, instead of being reported as delivered.
			my $sent = &Websocket::send('device', { chip_id => $chip_id, frame => $frame });
			return 1 if $sent;
		}
	}
	# Or another House machine holds it. Ask the homebase over the signed peer
	# rail; 0 keeps the caller's HTTP-then-BLE order.
	return &device_ws_peer_relay($chip_id, $frame);
}

sub device_ws_ack {
	# An ack is a delivery receipt, not a state update: the board's own state is
	# authoritative and the HTTP path never depended on this. Record it on the
	# entry and leave a log line, so a person watching manager.log can tell a
	# command that landed from one that only went out.
	my ($chip_id, $id) = @_;
	return 0 unless defined $chip_id && length $chip_id;
	if (my $conn = $DEVICE_CONN{$chip_id}) {
		$conn->{'last_ack'} = defined $id ? $id : '';
	}
	$log->info('device ws ack chip=' . $chip_id . ' id=' . (defined $id ? $id : '')) if $log;
	return 1;
}

1;
