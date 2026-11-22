package subs;

# Notify half of the domain layer: functions subroutines.pl calls that used
# to live in Manager.pl. Same package (subs) so every call site and the
# Manager:: aliases keep working; the Loader in lib/JawnOS/Domain/Loader.pm
# requires this file on the first call that needs it.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';

use Mojo::JSON qw(decode_json encode_json);
use Mojo::IOLoop;
use Mojo::UserAgent;
use Fcntl qw(:flock O_CREAT O_RDWR);
use JawnOS::Platform::Audio ();
use JawnOS::Platform::Paths ();

# File-scope state owned by subroutines.pl, in this same package.
our $config;
our $device;
our $log;
our $logfile;

# The one name a house-wide event has on every machine. A notice that every
# device announces at once - an appointment's start or stop, a budget crossing,
# an alarm's fire - used to be rendered with a fresh random uuid on each
# machine, so the sync carried every copy into every list. A caller that can
# name the event passes it as `dedupe`; each machine derives the same uuid, the
# unique index drops the duplicate insert, and the sync keys the rest onto the
# one row. A per-press or per-person notice passes no seed and keeps its random
# uuid.
sub notification_event_uuid($seed) {
	return undef unless defined $seed && length $seed;
	require Mojo::Util;
	# A name or an appointment payload can carry any printable character; the
	# digest is over bytes, so encode the copy rather than the caller's string.
	my $bytes = $seed;
	utf8::encode($bytes) if utf8::is_utf8($bytes);
	return 'notevent-' . Mojo::Util::md5_sum($bytes);
}

sub notification_sender($m,$db) {
	my $origin = &subs::format_name(&subs::config_reader()->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'computer_name' })) ||&subs::shorthand_name(&subs::machine_hostname());

	my $message = $m->{'message'};
	my ($database,$sql);
	($db,$database,$sql) = &subs::database_grabber();
	my $app = &subs::unformat_name($m->{'app'} || '');
	# While the person is away, a non-urgent notice is still stored, so the return
	# digest can show it, but it does not sound, buzz, push or draw a live card.
	# Security, calls and access pass (see subs::vacation_notify_allowed).
	my $hold = 0;
	if (!$m->{'urgent'} && eval { &subs::vacation_active($m->{'timestamp'} || &subs::rightNow()) }) {
		$hold = eval { &subs::vacation_notify_allowed($app, $m->{'type'} || '', 0, $m->{'timestamp'} || &subs::rightNow()) } ? 0 : 1;
	}
	$m->{'silent'} = 1 if $hold;
	$m->{'settings'} = &subs::settings_grabber({ app => $app, settings => [
		'start_notification_text', 'stop_notification_text', 'budget_notification_text', 'notification_text',
		'start_notification_sound', 'stop_notification_sound', 'budget_notification_sound', 'notification_sound'
	] }) unless $m->{'settings'};
	my $title = ($origin) . ': ' . $m->{'title'};

	$m->{'timestamp'} = &subs::rightNow();
	# the uuid has to exist before the live notification is rendered: the X button
	# carries it and the stored row is keyed by it, and they have to match. Callers
	# that do not supply one used to land here with uuid "", so the rendered X had
	# nothing to remove and the row could not be cleared. An event-named notice
	# (see notification_event_uuid) keeps that name; the live card is still this
	# machine's own, so an alarm rings where it is heard, while the insert below
	# writes the house's one row.
	my $event_uuid;
	unless (defined $m->{'uuid'} && length $m->{'uuid'}) {
		$event_uuid = &notification_event_uuid($m->{'dedupe'});
		$m->{'uuid'} = $event_uuid if $event_uuid;
	}
	$m->{'uuid'} ||= &subs::random_string_creator(20);
	# An update is the same notice with a new reading. It keeps the row's own
	# timestamp: the taskbar counts a notice as new by it, and a fresh stamp
	# would make old news unread.
	my $update_row;
	if ($m->{'update'}) {
		$update_row = eval { &subs::db_query('select * from notifications where uuid = ? limit 1', $m->{'uuid'})->hashes->[0] };
		$m->{'timestamp'} = $update_row->{'timestamp'} if $update_row && defined $update_row->{'timestamp'} && length $update_row->{'timestamp'};
	}
	my $sound = $m->{'sound'} || 'ding.mp3';
	# A silenced house keeps the notice on the screen but plays nothing.
	my $silenced = eval { &subs::sound_muted_for('notification', $app) } || 0;
	my $sound_file = $m->{'settings'}->{$m->{'type'} . '_notification_sound'} || './public/sounds/notifications/' . $sound;
	my $words = $m->{'words'} || $m->{'message'} || $m->{'settings'}->{$m->{'type'} ? $m->{'type'} . '_notification_text' : 'notification_text'};
	# Which machines may play this appointment's chime: a house-wide list of
	# signatorials, or "all". A missing or unreadable list keeps the old answer,
	# every machine. The card is still drawn everywhere; this gates the sound and
	# the phone's own notification, not the record in the house list.
	my $chime_here = 1;
	my $chime_raw = eval { &subs::setting_grabber({ app => $app, setting => 'notification_devices', device => 'all' }) };
	if (defined $chime_raw && length $chime_raw) {
		my $chime_list = eval { decode_json($chime_raw) };
		if (ref $chime_list eq 'ARRAY') {
			my $signatorial = &subs::signatorial_designer();
			my $device_type = &subs::device_setter();
			$chime_here = grep { defined $_ && ($_ eq 'all' || $_ eq $signatorial || $_ eq $device_type) } @{$chime_list} ? 1 : 0;
		}
	}
	if ($m->{'update'} || $silenced || $m->{'silent'} || $hold || !$chime_here) {
		# an update only changes a card already on screen; silence, or the
		# caller already sounds this (the phone's alarm channel), must not play
		# a second sound over it
	}
	elsif ($m->{'synth'}) {
		&subs::subprocessor(sub {
			&subs::run_command($app, $m->{'synth'} . ' &');
			if ($m->{'words'}) {
				&subs::say_it($m->{'words'});
			}
		}, { name => "Audio file player" });
	}
	else {
		&subs::subprocessor(sub {
			if ($sound) {
				my @argv = JawnOS::Platform::Audio::player_argv($sound_file);
				system(@argv) if @argv;
			}
			if ($words) {
				&subs::say_it($words);
			}
		}, { name => "Synth player" });
	}

	my $image;
	my $pwd = `pwd`;
	chomp $pwd;
	if ($m->{'image'}) {
		$image = $pwd . '/public' . $m->{'image'};
	}
	else {
		$image = &subs::setting_grabber({ app => &subs::unformat_name($m->{'title'}), setting => 'main_image' });
		unless (-e $image) {
			$image = $pwd . '/public/images/jonathans/logo red yellow.png';
		}
	}
	$image =~ s/ /\\ /gi;
	if (!$hold && $device eq 'mobile' && $chime_here) {
		# An update must land on the same Android notification the first press
		# built; the event uuid is that handle.
		# The event uuid is the handle a later reading updates: the same id makes
		# Android replace its own notification instead of stacking a second one.
		my $id = $m->{'uuid'};
		my $url = 'https://127.0.0.1:' . $ENV{PORT_AHOY} . '/manager?app=' . $m->{'app'} . '&timestamp=' . $m->{'timestamp'};
		# The app posts it (JawnNotifyReceiver), so the badge lands on the app's
		# own launcher icon. Native first: the app builds and posts it through the
		# device bridge, so the caller controls the small icon, the large picture,
		# the actions, the progress and the group. The app's own receiver (a
		# broadcast) stays as the fallback for a build older than the bridge.
		my $image_path = $image;
		$image_path =~ s/\\ / /g;
		# The Android large icon cannot read a sealed .enc. Ask for an
		# in-memory JPEG when the notice has no picture of its own; the bytes
		# cross the bridge as base64 and are never written to disk.
		my $inline_b64;
		$inline_b64 = eval { &subs::main_image_inline_b64({ app => $app, max => 512 }) }
			unless defined $m->{'image'};
		my %nargs = (
			id => $id,
			title => $title,
			text => $message,
			silent => (($m->{'update'} || $m->{'silent'}) ? 1 : 0),
			url => $url,
			# The app and the moment the notice is about: a tap opens that app's
			# own full-screen window on the phone instead of the manager desk.
			app => $m->{'app'},
			timestamp => $m->{'timestamp'},
			large_icon => $image_path,
			large_icon_b64 => $inline_b64,
			small_icon => ($m->{'small_icon'} || $m->{'app'} || ''),
			vibrate => (($m->{'update'} || $m->{'silent'}) ? '' : '200,150,200,150'),
			actions => $m->{'actions'},
			progress => $m->{'progress'},
			group => $m->{'group'},
			color => $m->{'color'},
			ongoing => ($m->{'ongoing'} ? 1 : 0),
		);
		# Android replaces the notification whose id it has seen; asking for it
		# only once keeps an update from sounding or buzzing again.
		$nargs{'only_alert_once'} = 1 if $m->{'update'};
		delete $nargs{$_} for grep { !defined $nargs{$_} } keys %nargs;
		my $posted = &subs::device_call('notification.post', \%nargs);
		unless ($posted) {
			my $notify = &subs::app_component('JawnNotifyReceiver');
			my $notify_action = &subs::app_action('JAWN_NOTIFY');
			# List form: the title and message are arbitrary text and must never
			# be parsed by a shell.
			my @am = ('am', 'broadcast', '-n', $notify, '-a', $notify_action,
				'--es', 'title', $title, '--es', 'message', $message, '--es', 'tag', $id);
			push @am, '--ez', 'silent', 'true' if ($m->{'silent'} || $m->{'update'});
			# The same app, moment and address the native poster carries, so the
			# broadcast fallback opens the same window on a build older than the
			# bridge.
			push @am, '--es', 'url', $url if defined $url && length $url;
			push @am, '--es', 'app', $m->{'app'} if defined $m->{'app'} && length $m->{'app'};
			push @am, '--es', 'timestamp', $m->{'timestamp'} if defined $m->{'timestamp'} && length $m->{'timestamp'};
			my $bc = '';
			my $am_ok = open(my $am_fh, '-|', @am);
			if ($am_ok) {
				local $/;
				$bc = <$am_fh> // '';
				close $am_fh;
			}
			$log->info('notification broadcast failed: ' . ($bc || 'not run')) if !$am_ok || $? != 0;
		}
	}
	elsif ( !$hold && eval { $sql->db } && $sql->dsn !~ /:$/) {

		my $c = &subs::controller_builder();
		my $content = $c->render_to_string(
			n => $m,
			template => 'notification',
		);
		if ($m->{'role'} ne '0') {
			if ($m->{'update'}) {
				# The row is already on the desk: replace it by the same uuid rather
				# than prepending a second copy.
				&Websocket::send('server', {
					type => 'notification_update',
					uuid => $m->{'uuid'},
					app => $m->{'app'},
					title => $m->{'title'},
					message => $m->{'message'},
					icon => $m->{'image'},
					timestamp => $m->{'timestamp'},
					html => $content
				});
			}
			else {
				&Websocket::send('server', {
					app => $m->{'app'},
					type => 'notification',
					uuid => $m->{'uuid'},
					title => $m->{'title'},
					role => $m->{'role'} || 'guest',
					message => $m->{'message'},
					icon => $m->{'image'},
					timestamp => $m->{'timestamp'},
					html => $content
				});
			}
		}

	}
	foreach my $embedded (qw/ watch teletype /) {
		next if $m->{'update'} || $hold || !$chime_here;
		my $watch = &subs::device_lister($m->{'timestamp'},$embedded);
		if (eval {$watch->{'ip'}}) {

			my $ping_ip = $watch->{'ip'};
			my $ping_test = '';
			if (&subs::peer_host_is_literal($ping_ip) && open(my $ping_fh, '-|', 'timeout', '.2', 'ping', '-c', '1', $ping_ip)) {
				local $/;
				$ping_test = <$ping_fh> // '';
				close $ping_fh;
			}
			if ($ping_test =~ /ttl/gi) {
				my $ua = Mojo::UserAgent->new();
				$ua->connect_timeout(1);
				my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/notification?title=' . $title .
					'&notification=' . $message . '&sound=/' . $sound . '&sound_file=' . $sound_file;
				&subs::subprocessor(sub {
					my $res = eval { return $ua->get($watch_home)->result };
				}, { name => "Watch notification sender" });
			}
		}
	}
	if (eval { $sql->db } && $sql->dsn !~ /:$/) {
		my $db = $sql->db;

		if ($m->{'update'}) {
			# No new row: this notice already exists and only its reading moved.
			# server_time advances so the sync carries the edit; timestamp stays
			# put (see above).
			&subs::db_update('notifications', {
				app => $m->{'app'},
				role => $m->{'role'} || 3,
				title => $m->{'title'},
				image => $m->{'image'},
				message => $m->{'message'},
				server_time => &subs::rightNow(),
			}, { uuid => $m->{'uuid'} }) if $update_row;
		}
		else {
			# An event the sync already carried here needs no second row. The live
			# card above belongs to this machine; the stored row belongs to the house.
			my $already = $event_uuid
				? eval { &subs::db_query('select 1 from notifications where uuid = ? limit 1', $event_uuid)->hashes->[0] }
				: 0;
			unless ($already) {
				&subs::db_insert('notifications', {
					app => $m->{'app'},
					role => $m->{'role'} || 3,
					title => $m->{'title'},
					image => $m->{'image'},
					message => $m->{'message'},
					timestamp => $m->{'timestamp'},
					uuid => $m->{'uuid'}
				});
			}
		}
	}

}

sub device_command_lock {
	# One output command at a time per board. A Pico's WebServer services one
	# client, and two overlapping relay requests leave the first half-answered
	# while the second is lost - the board looks wedged until something else (a
	# physical switch) wakes the link. The lock is a file in the house's tmp dir,
	# so it serializes every forked sender - the panel, an appointment, the
	# automation fan-out - across workers. The OS releases it when the child
	# exits, so a killed sender cannot wedge the queue. A short bounded wait, then
	# proceed: a dropped press is worse than one more try, and a long wait is what
	# made the fifth press of a burst arrive as a stale one.
	my ($chip_id) = @_;
	return undef unless defined $chip_id && length $chip_id;
	my $dir = ($gb::tmp_dir || JawnOS::Platform::Paths::tmp_dir()) . '/device_cmd';
	eval { mkdir $dir unless -d $dir; 1 };
	my $file = $dir . '/' . &subs::path_name($chip_id) . '.lock';
	sysopen(my $fh, $file, O_CREAT | O_RDWR, 0600) or return undef;
	my $deadline = time() + 5;
	my $locked = 1;
	while (!flock($fh, LOCK_EX | LOCK_NB)) {
		if (time() >= $deadline) { $locked = 0; last; }
		select(undef, undef, undef, 0.05);
	}
	$log->info('device command lock timed out for ' . $chip_id) if $log && !$locked;
	return $fh;
}

sub embedded_toggle($data) {
	my $app = $data->{'app'};
	my $pin = $data->{'pin'};
	my $ip = $data->{'ip'};
	my $edt = $data->{'edt'};
	my $state = $data->{'state'};
	my $timestamp = &subs::event_time_ms($data->{'timestamp'}) || &subs::rightNow();
	# A command that names an older moment than the toggle already holds is a
	# delayed copy: the panel pressed start, the switch was thrown after it, and
	# this relay command is only now arriving. Drop it instead of turning the
	# hardware back on; the caller gets the state that actually holds.
	if (&subs::toggle_event_is_older($app, $timestamp)) {
		my $cur = &subs::setting_grabber({ app => $app, setting => 'toggle' });
		# Silent in the log until now: a press that arrived behind a switch looked
		# exactly like a press that never reached the manager.
		$log->info('device command: ' . ($data->{'chip_id'} || '?') . ' ' . ($data->{'component'} || '?')
			. ' @' . $timestamp . ' is older than the stored toggle, output left alone') if $log;
		return { state => ($cur eq 'on' ? 1 : 0), formatted_state => $cur };
	}
	my $component = $data->{'component'};
	my $uuid = $data->{'uuid'} || &subs::random_string_creator();
	my $appt_uuid = $data->{'appt_uuid'};
	my $chip_id = $data->{'chip_id'};

	my $measure = $data->{'measure'};
	my $when = $data->{'when'} || 'now';
	my $ebc = $gb::embedded_components->{$component};



	my $syl_count = 10;
	$syl_count = 1 unless $edt eq 'microcontroller';
	my $syl = &subs::shorthand_name($component, $syl_count);
	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op_d = (eval { decode_json $od }) ? decode_json $od : {};
	my $inverted = $op_d->{$syl . $pin}->{'inverted'};
	my $save_state = $state;
	if ($inverted && $inverted == 1) {
		if ($state eq 'on') {
			$state = 'off';
			$save_state = 'on';
		}
		elsif ($state == 1) {
			$state = 'off';
			$save_state = 'on';
		}
		else {
			$state = 'on';
			$save_state = 'off';
		}
	}
	elsif (!$state && !$data->{'measure'}) {
		$state = &subs::setting_grabber({ app => $app, setting => 'toggle' });
		if ($state eq 'on') {
			$state = 'off';
			$save_state = 'off';
		}
		elsif ($state eq 'off') {
			$state = 'on';
			$save_state = 'on';
		}
		elsif ($state == 1) {
			$state = 'off';
			$save_state = 'off'
		}
		else {
			$state = 'on';
			$save_state = 'on';
		}
	}

	if ($component eq 'servo' && $appt_uuid) {
		$state = ($state / 100) * 180;
	}

	if ($state !~ /[0-9]/) {
		# the enabler is drawn through icon_path in the wrapper; use the set's own
		# glyph here too rather than the hand-drawn fallback
		my $toggle_src = &subs::icon_path($save_state, '/images/decipherable/' . $save_state . '.png');
		&Websocket::send('tab', { console => &Websocket::console_command('setToggle', $app, $save_state, $toggle_src)});
		# The direct command already drove the board we are addressing, so the
		# toggle fan-out must not echo that same state back to it over BLE.
		&subs::setting_setter({ app => $app, setting => 'toggle', value => $save_state, source => 'toggle', source_chip_id => $chip_id, timestamp => $timestamp }) if $data->{'counted'} == 0 || !$data->{'counted'};
	}

	# A board on the bridge - or one with no LAN address at all - takes the
	# output command as a BLE `set` message. The state above is already the
	# physical one (the inversion was folded in), so the board applies it
	# directly and answers with a `state` ack. This is what lets a crashed board
	# resume its relays before it has rejoined WiFi.
	if ($chip_id && ($component eq 'led' || $component eq 'relay' || $component eq 'servo')) {
		my $number_state = $state eq 'on' ? 1 : ($state eq 'off' ? 0 : $state);
		# A board with a live LAN address answers its own route at once. The
		# bridge can spend the client's full connect timeout when its link is
		# asleep, which is the 20-second delay on a relay press. Try HTTP first;
		# keep the bridge for a device with no address or a failed HTTP send.
		#
		# Every road below is a dial, and a dial in the request path is what made a
		# burst queue: each press waited on a peer relay that could not answer, so
		# the fifth press arrived twenty seconds late and was refused as older.
		# All the roads run here, in the sender, and the press returns at once.
		my $job_args = {
			chip_id => $chip_id, component => $component, pin => $pin, state => $state,
			timestamp => $timestamp, appt_uuid => $appt_uuid, uuid => $uuid, when => $when,
			measure => $measure, app => $app, edt => $edt, ip => $ip,
			port => $config->{'port'}, authorization => $op_d->{'__specs'}->{'authorization'},
		};
		&subs::subprocessor(sub { Mojo::IOLoop->reset; &subs::embedded_toggle_send($job_args) },
			{ name => 'embedded toggle sender', fork => 1, args => $job_args });
		return { state => $number_state, formatted_state => $state };
	}

	my $refresh_args = {
		timestamp => $timestamp, edt => $edt, chip_id => $chip_id, component => $component,
		appt_uuid => $appt_uuid, uuid => $uuid, when => $when, pin => $pin,
		state => $state, measure => $measure, port => $config->{'port'},
		authorization => $op_d->{'__specs'}->{'authorization'},
	};
	&subs::subprocessor(sub { Mojo::IOLoop->reset; &subs::embedded_toggle_refresh($refresh_args) },
		{ name => 'embedded toggle refresh', fork => 1, args => $refresh_args });
	my $number_state = $state eq 'on' ? 1 : 0;
	my $returner = { 'state' => $number_state, formatted_state => $state };

	return $returner;
}

# The sender body as a named sub: the subprocessor starts it by name on a box
# without fork, so every value it needs travels in args. It owns the per-chip
# lock, the WebSocket frame, the HTTP dial and the BLE fallback; the press that
# asked for it has already returned.
sub embedded_toggle_send {
	my ($args) = @_;
	my $chip_id = $args->{'chip_id'};
	my $component = $args->{'component'};
	my $pin = $args->{'pin'};
	my $state = $args->{'state'};
	my $timestamp = $args->{'timestamp'};
	my $appt_uuid = $args->{'appt_uuid'};
	my $uuid = $args->{'uuid'};
	my $when = $args->{'when'};
	my $measure = $args->{'measure'};
	my $app = $args->{'app'};
	my $edt = $args->{'edt'};
	my $ip = $args->{'ip'};
	my $port = $args->{'port'};
	my $authorization = $args->{'authorization'};
		# The block below is the only road to the hardware, so say when it is
		# taken: a press whose log jumps from the toggle write straight to
		# nothing is a press the fan-out never handed to a board.
		$log->info('device command: ' . ($chip_id || '?') . ' ' . ($component || '?')
			. ' ' . ($pin // '?') . ' ' . ($state || '?') . ' @' . $timestamp . ' (send)') if $log;
		# A board holding a /device/ws socket takes the command there. The same
		# fields the HTTP query below carries ride the frame; the helper answers
		# 0 when no socket is attached. A successful write is NOT a board ack: a
		# half-open link, or a peer's cached socket, can swallow it and the board
		# never clicks. Keep the board's own route below even after a write - the
		# uuid is the same on both roads, so the board's command manifest drops
		# the duplicate instead of clicking twice.
		my $ws_sent = &subs::device_ws_command({
			chip_id => $chip_id,
			component => $component,
			appt_uuid => $appt_uuid,
			uuid => $uuid,
			when => $when,
			pin => $pin,
			state => $state,
			timestamp => $timestamp,
			measure => $measure,
		});
		$log->info('device command: ' . ($chip_id || '?') . ' ' . ($component || '?') . ' '
			. ($pin // '?') . ' ' . ($state || '?') . ' @' . $timestamp . ' (ws)') if $ws_sent && $log;
		# The frame went to a socket that is up: the command is done. Running
		# the HTTP road as well spent the whole per-chip lock on a board that
		# already had the command, so the press after it queued - the switch's
		# own BLE set queued with it and a flick went missing. A socket that has
		# since died detaches itself, and the next press takes the roads below.
		return if $ws_sent;
		my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);
		my $watch_ip = (ref $watch eq 'HASH' && $watch->{'ip'}) ? $watch->{'ip'} : $ip;
		# The token rides the HTTP query below, so only a house address may be
		# dialled. A public or named row falls through to the bridge instead.
		if ($watch_ip && !&subs::board_host_allowed($watch_ip)) {
			$log->info('device command: ' . ($chip_id || '?') . ' refused board host ' . $watch_ip . ' (not a house address)') if $log;
			$watch_ip = '';
		}
		# One command at a time per board. A Pico services one HTTP client, so
		# overlapping presses are what make the third and fourth look lost.
		# The lock covers the bridge fallback too: the radio is shared with
		# WiFi, and a burst of writes is what wedges the board.
		my $lock = &subs::device_command_lock($chip_id);
		my $send_http = sub {
			# Plain HTTP: the board's WebServer has no TLS. The guard above keeps
			# the token on a house address; firmware TLS/HMAC is the follow-up.
			my $watch_home = 'http://' . $watch_ip . ':' . $port . '/' . $component . '?appt_uuid=' . $appt_uuid . '&uuid=' . $uuid . '&when=' . $when . '&pin=' . $pin . '&state=' . $state . '&component=' . $component . '&authorization=' . $authorization . '&timestamp=' . $timestamp . '&measure=' . $measure;
			my $ua = Mojo::UserAgent->new(connect_timeout => 1, inactivity_timeout => 2);
			my $res = $ua->get($watch_home)->result;
			my $body = eval { $res->result->body };
			my $rb = $body ? eval { decode_json($body) } : undef;
			if (ref $rb eq 'HASH') {
				$state = $rb->{'state'} if defined $rb->{'state'};
				$pin = $rb->{'pin'} if defined $rb->{'pin'};
				return 1;
			}
			return 0;
		};
		my $asked = $state;
		my $http_ok = 0;
		if ($watch_ip) {
			$http_ok = eval { $send_http->() } ? 1 : 0;
			# A send can still meet the connection the command before it is
			# closing. One short retry is enough now that the lock means this
			# is the only request in flight by the time it runs.
			if (!$http_ok) {
				select(undef, undef, undef, 0.15);
				$http_ok = eval { $send_http->() } ? 1 : 0;
			}
			$log->info('device command: ' . ($chip_id || '?') . ' ' . ($component || '?') . ' '
				. ($pin // '?') . ' ' . ($asked // '?') . ' @' . $timestamp
				. ' (http failed)') if $log && !$http_ok;
		}
		if ($http_ok) {
			# The board's reply is its own state after the command. An asked
			# state it did not take is the line that explains a press that
			# clicked nothing (stale, redundant, or a switch that won): the
			# asked state and the board's answer sit either side of the arrow.
			$log->info('device command: ' . ($chip_id || '?') . ' ' . ($component || '?') . ' '
				. ($pin // '?') . ' ' . ($asked || '?') . ' -> ' . ($state || '?')
				. ' @' . $timestamp . ' (http)') if $log;
			return;
		}
		if (ref $watch eq 'HASH' && ($watch->{'ble'} || !$watch->{'ip'})) {
			my $sent = eval {
				&subs::bluetooth_sender({
					intent => 'com.jawn.president.bt.connect',
					chip_id => $chip_id,
					edt => $edt,
					message => { type => 'set', data => {
						component => $component, pin => $pin, state => $state,
						when => $when, uuid => $uuid, appt_uuid => $appt_uuid,
						timestamp => $timestamp, measure => $measure, app => $app
					} }
				});
			};
			if ($sent) {
				$log->info('device command: ' . ($chip_id || '?') . ' ' . ($component || '?') . ' '
					. ($pin // '?') . ' ' . ($asked || '?') . ' @' . $timestamp . ' (bridge)') if $log;
				return;
			}
		}
		# Neither road carried it. Say so once, with the board and command, so
		# a relay that missed a press can be found in the log without a
		# reproduction.
		$log->info('device command not delivered: ' . ($chip_id || '?') . ' '
			. ($component || '?') . ' asked ' . ($asked || '?') . ' (http='
			. ($watch_ip ? 'failed' : 'no address') . ')') if $log && !$ws_sent;
	return;
}

# The read-back half of a press, also its own process. It asks the board for its
# state and answers the board's own view; on Unix the answer never reaches the
# parent, and on a box without fork a worker keeps that true.
sub embedded_toggle_refresh {
	my ($args) = @_;
	my $timestamp = $args->{'timestamp'};
	my $edt = $args->{'edt'};
	my $chip_id = $args->{'chip_id'};
	my $component = $args->{'component'};
	my $appt_uuid = $args->{'appt_uuid'};
	my $uuid = $args->{'uuid'};
	my $when = $args->{'when'};
	my $pin = $args->{'pin'};
	my $state = $args->{'state'};
	my $measure = $args->{'measure'};
	my $port = $args->{'port'};
	my $authorization = $args->{'authorization'};
	eval {
		my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);
		my $watch_ip = (ref $watch eq 'HASH' && defined $watch->{'ip'}) ? $watch->{'ip'} : '';
		# The token rides this query; a public or named host is never dialled.
		return unless $watch_ip && &subs::board_host_allowed($watch_ip);

		my $watch_home = 'http://' . $watch_ip . ':' . $port . '/' . $component . '?appt_uuid=' . $appt_uuid . '&uuid=' . $uuid . '&when=' . $when . '&pin=' . $pin . '&state=' . $state . '&component=' . $component . '&authorization=' . $authorization . '&timestamp=' . $timestamp . '&measure=' . $measure;
		my $ua = Mojo::UserAgent->new();

		my $res = $ua->get($watch_home)->result;
		if (eval { $res->result->body }) {
			if (eval { decode_json $res->result->body }) {
				my $rb = decode_json $res->result->body;
				$state = $rb->{'state'};
				$pin = $rb->{'pin'};
			}
		}
		my $number_state = $state eq 'on' ? 1 : 0;
	};
	return;
}

# A settings row has no uuid: it is identified by the key it is stored under.
# Normalise a settings row or a settings deletion into that key (app, setting,
# subsetting, device), decoding a byte-string key exactly as the settings write
# gate and the merge do - a tombstone that keeps the bytes names a different
# row. A record for any other table (a legacy uuid/table one included) answers
# undef, so the uuid path is untouched.
sub settings_deletion_record {
	my ($record) = @_;
	return undef unless ref $record eq 'HASH';
	my $table = defined $record->{'table'} ? $record->{'table'} : $record->{'tbl'};
	return undef if defined $table && $table ne 'settings';
	my $extra = {};
	if (ref $record->{'additional'} eq 'HASH') {
		$extra = $record->{'additional'};
	}
	elsif (defined $record->{'additional'} && !ref $record->{'additional'} && length $record->{'additional'}) {
		my $decoded = eval { decode_json $record->{'additional'} };
		$extra = ref $decoded eq 'HASH' ? $decoded : {};
	}
	my %part = map { $_ => (defined $record->{$_} ? $record->{$_} : $extra->{$_}) } qw(app setting subsetting device);
	$part{'app'} = &subs::text_chars($part{'app'}) if defined $part{'app'};
	$part{'setting'} = &subs::text_chars($part{'setting'}) if defined $part{'setting'};
	$part{'subsetting'} = &subs::text_chars($part{'subsetting'}) if defined $part{'subsetting'};
	$part{'device'} = &subs::text_chars($part{'device'}) if defined $part{'device'};
	# a deletion that cannot name a row must not be applied as one
	return undef unless defined $part{'app'} && length $part{'app'}
		&& defined $part{'setting'} && length $part{'setting'};
	# NULL and empty are the same key: a row written before subsetting existed,
	# and a delete that named no subsetting, must meet.
	$part{'subsetting'} = '' unless defined $part{'subsetting'};
	$part{'device'} = '' unless defined $part{'device'};
	# The durable sync_log row is stamped when the tombstone is written; the
	# deletion's own moment rides in `additional` so an echo of a peer's
	# deletion cannot move the cutoff past a deliberate re-add.
	my $time = defined $extra->{'server_time'} ? $extra->{'server_time'} : $record->{'server_time'};
	$part{'server_time'} = (defined $time && $time =~ /^\d+$/) ? $time + 0 : 0;
	return \%part;
}

# The comparable form of a settings key. Undef for anything that is not one.
sub settings_deletion_key {
	my $deletion = &settings_deletion_record(shift);
	return undef unless $deletion;
	return join "\x1f", @{$deletion}{qw(app setting subsetting device)};
}

# When a settings row was deleted, in epoch milliseconds.
sub settings_deletion_time {
	my $deletion = &settings_deletion_record(shift);
	return $deletion ? $deletion->{'server_time'} : 0;
}

# A key -> newest-deletion-time map, built once per merge instead of decoding
# every tombstone again for every incoming settings row.
sub settings_deletion_index {
	my ($deletions) = @_;
	my %index;
	return \%index unless ref $deletions eq 'ARRAY';
	foreach my $tomb ( @{$deletions} ) {
		next unless ref $tomb eq 'HASH';
		my $key = &settings_deletion_key($tomb);
		next unless defined $key;
		my $time = &settings_deletion_time($tomb);
		$index{$key} = $time if !defined $index{$key} || $time > $index{$key};
	}
	return \%index;
}

# Would a tombstone hold this incoming settings row back? Only a tombstone for
# the same key, stamped at or after the row's own server_time, does: a row
# written after the deletion is a deliberate re-add and must still land.
sub settings_deletion_blocks {
	my ($row, $deletions) = @_;
	return 0 unless ref $row eq 'HASH';
	my $key = &settings_deletion_key($row);
	return 0 unless defined $key;
	my $row_time = (defined $row->{'server_time'} && $row->{'server_time'} =~ /^\d+$/) ? $row->{'server_time'} + 0 : 0;
	my $index = ref $deletions eq 'HASH' ? $deletions : &settings_deletion_index($deletions);
	return 1 if defined $index->{$key} && $index->{$key} >= $row_time;
	return 0;
}

# The durable (sync_log) and short-lived (remote_machines.deletions) shapes of
# one deletion. Kept here so the single and bulk registrars cannot disagree.
sub deletion_record_build($data) {
	my $additional = $data->{'additional'};
	# A file deletion must name the file it removes: a peer applies it by uuid,
	# and without one the tombstone reached the other machines and did nothing.
	$additional = encode_json({ file_uuid => $data->{'file_uuid'} }) if !$additional && $data->{'file_uuid'};
	my $settings_record = (($data->{'table'} || '') eq 'settings') ? 1 : 0;
	my $server_time = $data->{'server_time'};
	$server_time = &subs::rightNow() if $settings_record && !defined $server_time;
	# sync_log's only free-form field is `additional`, so the rest of a settings
	# key rides there for the durable log; the short-lived list below also carries
	# it at the top level, where a peer on this build reads it directly.
	if ($settings_record && !$additional) {
		$additional = encode_json({
			setting => $data->{'setting'},
			subsetting => $data->{'subsetting'},
			device => $data->{'device'},
			server_time => $server_time,
		});
	}
	my $record = {
		table => $data->{'table'}, app => $data->{'app'},
		uuid => $data->{'uuid'}, scope => $data->{'scope'},
		initialization => &subs::rightNow(), server_time => $server_time,
		additional => $additional,
	};
	if ($settings_record) {
		$record->{'setting'} = $data->{'setting'} if defined $data->{'setting'};
		$record->{'subsetting'} = $data->{'subsetting'} if defined $data->{'subsetting'};
		$record->{'device'} = $data->{'device'} if defined $data->{'device'};
	}
	return ($record, $additional);
}

sub deletion_registration($data) {
	# Record one durable tombstone. It stays in sync_log until every remote
	# machine has confirmed reading past it, so an offline machine still learns
	# of the deletion whenever it next connects.
	my ($record, $additional) = &deletion_record_build($data);
	&subs::tombstone_writer({
		table => $record->{'table'}, app => $record->{'app'},
		uuid => $record->{'uuid'}, scope => $record->{'scope'},
		additional => $additional,
	});
	my $remote_machines = &subs::db_select('remote_machines')->hashes;
	foreach my $rm ( @{$remote_machines} ) {
		my $deletions = eval { return decode_json $rm->{'deletions'} } || [];
		push @{$deletions}, $record;
		my $del = encode_json $deletions;
		&subs::db_update('remote_machines', { deletions => $del }, { uuid => $rm->{'uuid'}, signatorial => $rm->{'signatorial'} });
	}
}

# The same record for many deletions. A vacuum can remove thousands of rows; the
# single path above re-reads and re-encodes the growing deletions list for every
# row and every peer, which turned a three-app clean-up into a twelve-second wait
# and would have timed out for the whole house. The durable log still gets one
# row each, but the peers are updated once.
sub deletion_registration_many($records) {
	return 0 unless ref $records eq 'ARRAY' && scalar @{$records};
	my ($db) = &subs::database_grabber();
	# One transaction for the durable rows: a vacuum can write thousands, and a
	# commit per row is what made the whole-house clean-up slow.
	my $tx = ($db && $db->dbh->{AutoCommit}) ? eval { $db->dbh->begin_work; 1 } : 0;
	my @wire;
	foreach my $data ( @{$records} ) {
		my ($record, $additional) = &deletion_record_build($data);
		push @wire, $record;
		&subs::db_insert('sync_log', {
			server_time => &subs::rightNow(),
			signatorial => &subs::signatorial_designer(),
			tbl => $record->{'table'}, app => $record->{'app'},
			uuid => $record->{'uuid'}, scope => $record->{'scope'},
			additional => $additional,
		});
	}
	eval { $db->dbh->commit } if $tx;
	my $remote_machines = &subs::db_select('remote_machines')->hashes || [];
	foreach my $rm ( @{$remote_machines} ) {
		my $deletions = eval { return decode_json $rm->{'deletions'} } || [];
		push @{$deletions}, @wire;
		&subs::db_update('remote_machines', { deletions => encode_json $deletions }, { uuid => $rm->{'uuid'}, signatorial => $rm->{'signatorial'} });
	}
	return scalar @wire;
}

sub migration_already_applied($command) {
	if ($command =~ /^\s*alter\s+table\s+(\w+)\s+add\s+column\s+(\w+)/i) {
		my ($table, $column) = ($1, $2);
		return &subs::db_query('select 1 from pragma_table_info(?) where name=?', $table, $column)->hashes->[0] ? 1 : 0;
	}
	elsif ($command =~ /^\s*alter\s+table\s+(\w+)\s+drop\s+column\s+(\w+)/i) {
		my ($table, $column) = ($1, $2);
		# dropping a column that is already gone is just as old news
		return &subs::db_query('select 1 from pragma_table_info(?) where name=?', $table, $column)->hashes->[0] ? 0 : 1;
	}
	elsif ($command =~ /^\s*create\s+(?:unique\s+)?index\s+(?:if\s+not\s+exists\s+)?(\w+)/i) {
		return &subs::db_query('select 1 from sqlite_master where type=? and name=?', 'index', $1)->hashes->[0] ? 1 : 0;
	}
	elsif ($command =~ /^\s*drop\s+table\s+(?:if\s+exists\s+)?(\w+)/i) {
		# a table that is already gone (firewall) is the same kind of old news
		return &subs::db_query('select 1 from sqlite_master where type=? and name=?', 'table', $1)->hashes->[0] ? 0 : 1;
	}
	elsif ($command =~ /^\s*drop\s+index\s+(?:if\s+exists\s+)?(\w+)/i) {
		# an index that is already gone has nothing left to drop
		return &subs::db_query('select 1 from sqlite_master where type=? and name=?', 'index', $1)->hashes->[0] ? 0 : 1;
	}
	return 0;
}

# The apps the Notifications panel may offer, and the ones already switched on
# on any device. One query names the app universe and one reads every
# notification row; the newest row for an app and a device decides that device,
# and the union of the devices that said on is the appointment's entry. Full
# settings are loaded only for the enabled apps, which are the few.
sub notification_appointments() {
	my $universe = eval {
		return &subs::db_query("select distinct app from settings where setting in ('visible','pos','mab') and app is not null and app != '' and substr(app,1,2) <> '__' order by app")->hashes;
	} || [];
	my $notes = eval {
		return &subs::db_query("select app, device, value, server_time from settings where setting = 'notification' and app is not null and app != '' order by cast(server_time as integer) desc")->hashes;
	} || [];
	# The list is the union of every device, not just the one asking: an
	# appointment announcing on the phone belongs here when it is read on the
	# laptop. The newest row for one app and one device is the one that counts,
	# and only its "on" puts that device in the entry.
	my %latest;
	foreach my $row ( @{$notes} ) {
		my $app = $row->{'app'};
		next unless defined $app && length $app;
		my $key = $app . "\x1f" . ($row->{'device'} // '');
		next if exists $latest{$key};
		$latest{$key} = $row->{'value'};
	}
	my %on;
	foreach my $key ( keys %latest ) {
		next unless (($latest{$key} // '') eq 'on');
		my ($app, $dev) = split /\x1f/, $key, 2;
		push @{$on{$app}}, $dev if defined $dev && length $dev;
	}
	$on{$_} = [ sort @{$on{$_}} ] for keys %on;
	my %protected = map { $_ => 1 } @gb::protected;
	my (%seen, @enabled, @candidates);
	foreach my $row ( @{$universe} ) {
		my $app = $row->{'app'};
		next unless defined $app && length $app;
		next if $seen{$app}++;
		# A private app is the house's own machinery, never an appointment the
		# panel should offer or announce.
		next if &subs::app_visibility_value($app) eq 'private';
		my $formatted = &subs::format_name($app);
		my $enabled = $on{$app} ? 1 : 0;
		if ($enabled) {
			push @enabled, {
				app => $app,
				formatted_name => $formatted,
				devices => $on{$app},
				settings => &subs::settings_grabber({ app => $app, benign => 1 }),
			};
		}
		# An app already announcing is listed above, not offered again below.
		next if $enabled;
		next if $protected{$app};
		push @candidates, { app => $app, formatted_name => $formatted };
	}
	# An app with no visible/pos/mab row still belongs in the list when this
	# machine already announces it: the setting is the fact, the universe is
	# only where the names come from.
	foreach my $app ( sort keys %on ) {
		next if $seen{$app}++;
		next if &subs::app_visibility_value($app) eq 'private';
		push @enabled, {
			app => $app,
			formatted_name => &subs::format_name($app),
			devices => $on{$app},
			settings => &subs::settings_grabber({ app => $app, benign => 1 }),
		};
	}
	return { enabled => \@enabled, candidates => \@candidates };
}

# The machines the Appointments view may offer as places for a chime. A
# signatorial is the machine's own name, so it survives a rename; the hostname is
# only its label here. The machine asking is included even when the roster has
# not written it yet.
sub notification_device_choices() {
	my $self = &subs::signatorial_designer();
	my $rows = eval {
		return &subs::db_query("select signatorial, hostname, name from remote_machines where signatorial is not null and signatorial != '' order by hostname, name")->hashes;
	} || [];
	my (%seen, @out);
	foreach my $row ( @{$rows} ) {
		my $sig = $row->{'signatorial'} // next;
		next if $seen{$sig}++;
		my $name = $row->{'hostname'} || $row->{'name'} || substr($sig, 0, 8);
		push @out, { signatorial => $sig, name => $name, self => ($sig eq $self ? 1 : 0) };
	}
	unless ($seen{$self}) {
		my $name = &subs::setting_grabber({ app => 'me', setting => 'computer_name' })
			|| &subs::machine_hostname() || 'this device';
		push @out, { signatorial => $self, name => $name, self => 1 };
	}
	return \@out;
}

1;
