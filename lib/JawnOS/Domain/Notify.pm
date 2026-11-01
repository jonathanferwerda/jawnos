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

sub embedded_toggle($data) {
	my $app = $data->{'app'};
	my $pin = $data->{'pin'};
	my $ip = $data->{'ip'};
	my $edt = $data->{'edt'};
	my $state = $data->{'state'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
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
		&Websocket::send('tab', { console => '$(\'.appointment[app="' . $app . '"]\').find(\'.enabler[type="toggle"\').attr(\'status\',\'' .$save_state . '\').attr(\'src\', \'' . $toggle_src . '\');' });
		&subs::setting_setter({ app => $app, setting => 'toggle', value => $save_state, source => 'toggle' }) if $data->{'counted'} == 0 || !$data->{'counted'};
	}

	# A board on the bridge - or one with no LAN address at all - takes the
	# output command as a BLE `set` message. The state above is already the
	# physical one (the inversion was folded in), so the board applies it
	# directly and answers with a `state` ack. This is what lets a crashed board
	# resume its relays before it has rejoined WiFi.
	if ($chip_id && ($component eq 'led' || $component eq 'relay' || $component eq 'servo')) {
		my $number_state = $state eq 'on' ? 1 : ($state eq 'off' ? 0 : $state);
		# A bridge connect waits for the link (the client gives it 30 seconds), so
		# the send must never run in the request. The worker picks the road: the
		# bridge when the device is BLE or has no LAN address, the HTTP send when
		# it has one and the bridge did not answer.
		&subs::subprocessor(sub {
			Mojo::IOLoop->reset;
			my $watch = &subs::device_lister($timestamp, $edt, undef, $chip_id);
			my $watch_ip = (ref $watch eq 'HASH' && $watch->{'ip'}) ? $watch->{'ip'} : $ip;
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
				return if $sent || !$watch_ip;
			}
			return unless $watch_ip;
			eval {
				my $watch_home = 'http://' . $watch_ip . ':' . $config->{'port'} . '/' . $component . '?appt_uuid=' . $appt_uuid . '&uuid=' . $uuid . '&when=' . $when . '&pin=' . $pin . '&state=' . $state . '&component=' . $component . '&authorization=' . $op_d->{'__specs'}->{'authorization'} . '&timestamp=' . $timestamp . '&measure=' . $measure;
				my $ua = Mojo::UserAgent->new();

				my $res = $ua->insecure(1)->get($watch_home)->result;
				if (eval { $res->result->body }) {
					if (eval { decode_json $res->result->body }) {
						my $rb = decode_json $res->result->body;
						$state = $rb->{'state'};
						$pin = $rb->{'pin'};
					}
				}
			};
		}, { name => 'embedded toggle sender' });
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
	}, { name => 'embedded toggle sender' });
	my $number_state = $state eq 'on' ? 1 : 0;
	my $returner = { 'state' => $number_state, formatted_state => $state };

	return $returner;
}

sub deletion_registration($data) {
	# Record one durable tombstone. It stays in sync_log until every remote
	# machine has confirmed reading past it, so an offline machine still learns
	# of the deletion whenever it next connects.
	my $additional = $data->{'additional'};
	# A file deletion must name the file it removes: a peer applies it by uuid,
	# and without one the tombstone reached the other machines and did nothing.
	$additional = encode_json({ file_uuid => $data->{'file_uuid'} }) if !$additional && $data->{'file_uuid'};
	&subs::tombstone_writer({
		table => $data->{'table'}, app => $data->{'app'},
		uuid => $data->{'uuid'}, scope => $data->{'scope'},
		additional => $additional,
	});
	my $app = $data->{'app'};
	my $uuid = $data->{'uuid'};
	my $scope = $data->{'scope'};
	my $table = $data->{'table'};
	my $server_time = $data->{'server_time'};
	my $remote_machines = &subs::db_select('remote_machines')->hashes;
	foreach my $rm ( @{$remote_machines} ) {
		my $deletions = eval { return decode_json $rm->{'deletions'} } || [];
		push @{$deletions}, { table => $table, app => $app, uuid => $uuid, scope => $scope, initialization => &subs::rightNow(), server_time => $server_time, additional => $additional };
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
