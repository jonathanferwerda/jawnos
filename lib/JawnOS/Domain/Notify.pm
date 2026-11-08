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

# File-scope state owned by subroutines.pl, in this same package.
our $config;
our $device;
our $log;
our $logfile;

sub notification_sender($m,$db) {
	my $origin = &subs::format_name(&subs::config_reader()->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'computer_name' })) ||&subs::shorthand_name(`hostname`);

	my $message = $m->{'message'};
	my ($database,$sql);
	($db,$database,$sql) = &subs::database_grabber();
	my $app = &subs::unformat_name($m->{'app'} || '');
	$m->{'settings'} = &subs::settings_grabber({ app => $app, settings => [
		'start_notification_text', 'stop_notification_text', 'budget_notification_text', 'notification_text',
		'start_notification_sound', 'stop_notification_sound', 'budget_notification_sound', 'notification_sound'
	] }) unless $m->{'settings'};
	my $title = ($origin) . ': ' . $m->{'title'};

	$m->{'timestamp'} = &subs::rightNow();
	# the uuid has to exist before the live notification is rendered: the X button
	# carries it and the stored row is keyed by it, and they have to match. Callers
	# that do not supply one used to land here with uuid "", so the rendered X had
	# nothing to remove and the row could not be cleared
	$m->{'uuid'} ||= &subs::random_string_creator(20);
	my $sound = $m->{'sound'} || 'ding.mp3';
	my $sound_file = $m->{'settings'}->{$m->{'type'} . '_notification_sound'} || './public/sounds/notifications/' . $sound;
	my $words = $m->{'words'} || $m->{'message'} || $m->{'settings'}->{$m->{'type'} ? $m->{'type'} . '_notification_text' : 'notification_text'};
	if ($m->{'silent'}) {
		# the caller already sounds this (the phone's alarm channel); the
		# notification must not play a second sound over it
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
				my $co = 'play -q ' . $sound_file;
				`$co`;
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
	if ($device eq 'mobile') {
		my $id = &subs::random_string_creator();
		my $url = 'https://127.0.0.1:' . $ENV{PORT_AHOY} . '/manager?app=' . $m->{'app'} . '&timestamp=' . $m->{'timestamp'};
		# The app posts it (JawnNotifyReceiver), so the badge lands on the app's
		# own launcher icon. Native first: the app builds and posts it through the
		# device bridge, so the caller controls the small icon, the large picture,
		# the actions, the progress and the group. The app's own receiver (a
		# broadcast) stays as the fallback for a build older than the bridge.
		my $image_path = $image;
		$image_path =~ s/\\ / /g;
		my %nargs = (
			id => $id,
			title => $title,
			text => $message,
			silent => ($m->{'silent'} ? 1 : 0),
			url => $url,
			large_icon => $image_path,
			small_icon => ($m->{'small_icon'} || $m->{'app'} || ''),
			vibrate => ($m->{'silent'} ? '' : '200,150,200,150'),
			actions => $m->{'actions'},
			progress => $m->{'progress'},
			group => $m->{'group'},
			color => $m->{'color'},
			ongoing => ($m->{'ongoing'} ? 1 : 0),
		);
		delete $nargs{$_} for grep { !defined $nargs{$_} } keys %nargs;
		my $posted = &subs::device_call('notification.post', \%nargs);
		unless ($posted) {
			my ($t, $b) = ($title, $message);
			$t =~ s/"/'/g;
			$b =~ s/"/'/g;
			my $silent = $m->{'silent'} ? ' --ez silent true' : '';
			my $notify = &subs::app_component('JawnNotifyReceiver');
			my $notify_action = &subs::app_action('JAWN_NOTIFY');
			my $bc = `am broadcast -n $notify -a $notify_action --es title "$t" --es message "$b" --es tag "$id"$silent 2>&1`;
			$log->info("notification broadcast failed: $bc") unless $bc =~ /Broadcast completed/;
		}
	}
	elsif ( eval { $sql->db } && $sql->dsn !~ /:$/) {

		my $c = &subs::controller_builder();
		my $content = $c->render_to_string(
			n => $m,
			template => 'notification',
		);
		if ($m->{'role'} ne '0') {
			&Websocket::send('server', {
				app => $m->{'app'},
				type => 'notification',
				title => $m->{'title'},
				role => $m->{'role'} || 'guest',
				message => $m->{'message'},
				icon => $m->{'image'},
				timestamp => $m->{'timestamp'},
				html => $content
			});
		}

	}
	foreach my $embedded (qw/ watch teletype /) {
		my $watch = &subs::device_lister($m->{'timestamp'},$embedded);
		if (eval {$watch->{'ip'}}) {

			my $ping = 'timeout .2 ping -c 1 ' . $watch->{'ip'};
			my $ping_test = `$ping`;
			if ($ping_test =~ /ttl/gi) {
				my $ua = Mojo::UserAgent->new();
				$ua->connect_timeout(1);
				my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/notification?title=' . $title .
					'&notification=' . $message . '&sound=/' . $sound . '&sound_file=' . $sound_file;
				&subs::subprocessor(sub {
					my $res = eval { return $ua->insecure(1)->get($watch_home)->result };
				}, { name => "Watch notification sender" });
			}
		}
	}
	if (eval { $sql->db } && $sql->dsn !~ /:$/) {
		my $db = $sql->db;

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

sub device_command_lock {
	# One output command at a time per board. A Pico's WebServer services one
	# client, and two overlapping relay requests leave the first half-answered
	# while the second is lost - the board looks wedged until something else (a
	# physical switch) wakes the link. The lock is a file in the house's tmp dir,
	# so it serializes every forked sender - the panel, an appointment, the
	# automation fan-out - across workers. The OS releases it when the child
	# exits, so a killed sender cannot wedge the queue. A bounded wait, then
	# proceed: a dropped press is worse than one more try.
	my ($chip_id) = @_;
	return undef unless defined $chip_id && length $chip_id;
	my $dir = ($gb::tmp_dir || '/tmp') . '/device_cmd';
	eval { mkdir $dir unless -d $dir; 1 };
	my $file = $dir . '/' . &subs::path_name($chip_id) . '.lock';
	sysopen(my $fh, $file, O_CREAT | O_RDWR, 0600) or return undef;
	my $deadline = time() + 15;
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
		# A board holding a /device/ws socket takes the command there. The same
		# fields the HTTP query below carries ride the frame; the helper answers 0
		# when no socket is attached. A successful write is NOT a board ack: a
		# half-open link, or a peer's cached socket, can swallow it and the board
		# never clicks. Keep the board's own route below even after a write - the
		# uuid is the same on both roads, so the board's command manifest drops
		# the duplicate instead of clicking twice.
		# The block below is the only road to the hardware, so say when it is taken:
		# a press whose log jumps from the toggle write straight to nothing is a
		# press the fan-out never handed to a board.
		$log->info('device command: ' . ($chip_id || '?') . ' ' . ($component || '?')
			. ' ' . ($pin // '?') . ' ' . ($state || '?') . ' @' . $timestamp . ' (send)') if $log;
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
		# A board with a live LAN address answers its own route at once. The
		# bridge can spend the client's full connect timeout when its link is
		# asleep, which is the 20-second delay on a relay press. Try HTTP first;
		# keep the bridge for a device with no address or a failed HTTP send.
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);
			my $watch_ip = (ref $watch eq 'HASH' && $watch->{'ip'}) ? $watch->{'ip'} : $ip;
			# One command at a time per board. A Pico services one HTTP client, so
			# overlapping presses are what make the third and fourth look lost.
			# The lock covers the bridge fallback too: the radio is shared with
			# WiFi, and a burst of writes is what wedges the board.
			my $lock = &subs::device_command_lock($chip_id);
			my $send_http = sub {
				my $watch_home = 'http://' . $watch_ip . ':' . $config->{'port'} . '/' . $component . '?appt_uuid=' . $appt_uuid . '&uuid=' . $uuid . '&when=' . $when . '&pin=' . $pin . '&state=' . $state . '&component=' . $component . '&authorization=' . $op_d->{'__specs'}->{'authorization'} . '&timestamp=' . $timestamp . '&measure=' . $measure;
				my $ua = Mojo::UserAgent->new(connect_timeout => 2, inactivity_timeout => 3);
				my $res = $ua->insecure(1)->get($watch_home)->result;
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
		}, { name => 'embedded toggle sender', fork => 1 });
		return { state => $number_state, formatted_state => $state };
	}

  &subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		eval {
			my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);

			my $watch_home = 'http://' . $watch->{'ip'} . ':' . $config->{'port'} . '/' . $component . '?appt_uuid=' . $appt_uuid . '&uuid=' . $uuid . '&when=' . $when . '&pin=' . $pin . '&state=' . $state . '&component=' . $component . '&authorization=' . $op_d->{'__specs'}->{'authorization'} . '&timestamp=' . $timestamp . '&measure=' . $measure;
			my $ua = Mojo::UserAgent->new();

			my $res = $ua->insecure(1)->get($watch_home)->result;
			if (eval { $res->result->body }) {
				if (eval { decode_json $res->result->body }) {
					my $rb = decode_json $res->result->body;
					$state = $rb->{'state'};
					$pin = $rb->{'pin'};
				}
			}
			my $number_state = $state eq 'on' ? 1 : 0;
		};
	}, { name => 'embedded toggle sender', fork => 1 });
	my $number_state = $state eq 'on' ? 1 : 0;
	my $returner = { 'state' => $number_state, formatted_state => $state };

	return $returner;
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

sub deletion_registration($data) {
	# Record one durable tombstone. It stays in sync_log until every remote
	# machine has confirmed reading past it, so an offline machine still learns
	# of the deletion whenever it next connects.
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
	&subs::tombstone_writer({
		table => $data->{'table'}, app => $data->{'app'},
		uuid => $data->{'uuid'}, scope => $data->{'scope'},
		additional => $additional,
	});
	my $app = $data->{'app'};
	my $uuid = $data->{'uuid'};
	my $scope = $data->{'scope'};
	my $table = $data->{'table'};
	my $remote_machines = &subs::db_select('remote_machines')->hashes;
	foreach my $rm ( @{$remote_machines} ) {
		my $deletions = eval { return decode_json $rm->{'deletions'} } || [];
		my $record = { table => $table, app => $app, uuid => $uuid, scope => $scope, initialization => &subs::rightNow(), server_time => $server_time, additional => $additional };
		if ($settings_record) {
			$record->{'setting'} = $data->{'setting'} if defined $data->{'setting'};
			$record->{'subsetting'} = $data->{'subsetting'} if defined $data->{'subsetting'};
			$record->{'device'} = $data->{'device'} if defined $data->{'device'};
		}
		push @{$deletions}, $record;
		my $del = encode_json $deletions;
		&subs::db_update('remote_machines', { deletions => $del }, { uuid => $rm->{'uuid'}, signatorial => $rm->{'signatorial'} });
	}
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

1;
