#!/usr/bin/env perl
# The domain layer: the functions subroutines.pl calls that used to live in
# Manager.pl. They are in package subs, so a caller has them as subs::name and
# needs neither Mojolicious nor this tree's routes. Manager.pl aliases the old
# Manager::name for the routes, the templates and the Music/Alarm callers that
# still spell it that way.
#
# Only functions with no dependency on Manager's own subs, its $c and its
# file-scope state belong here. Everything in this file is reached from
# subroutines.pl, which is loaded by the watch, teletype, alarm and utility
# processes as well as by every script.
package subs;

use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';

use Date::Parse qw(str2time);
use File::Slurp qw(read_file);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::URL;
use Number::Format qw(unformat_number);
use Mojo::UserAgent;
use Time::Local qw(timegm timelocal);

# File-scope state owned by subroutines.pl, in this same package.
our $config;
our $device;
our $log;
our $logfile;
# log_reader used to share Manager.pl's write-only scratch array. It was never
# populated (Manager.pl only ever read it as an empty fallback), so the domain
# copy lives here and the two stay independent.
our (@appointments, @results);

sub ocr_reader($c,$filename) {
	my $text_file = $filename;
	# OCR is a convenience, never a condition of the capture. A device without
	# tesseract (the Android app's Termux image has none) used to run the shell
	# command, get no .txt, and then read_file() died - turning a successful
	# photo into HTTP 500 after the image was already on disk. Missing engine or
	# empty output means "no text", not "the capture failed".
	my $engine = `command -v tesseract 2>/dev/null`;
	return undef unless $engine =~ /\S/;
	my $src = &subs::shell_quote($filename);
	my $out = &subs::shell_quote($text_file);
	`tesseract $src $out 2>/dev/null`;
	$text_file = $text_file . '.txt';
	unless (-e $text_file) {
		return undef;
	}
	my $ocr = eval { read_file($text_file) };
	# Keep every printable character, including accented letters and CJK text.
	# Only the control bytes that OCR engines emit are removed; the old ASCII
	# filter silently erased whole languages from a scanned document.
	$ocr =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]+//g if defined $ocr;
	$ocr = &subs::note_encrypter(&subs::session_suds($c),$ocr);
	my $tn_txt = &subs::shell_quote($text_file);
	`shred -u $tn_txt 2>/dev/null`;

	return $ocr;
}

sub misc_setting_list() {
    my ($db, $database, $sql) = &subs::database_grabber();
		my @locations = &subs::location_types();
    my @settings = qw/max_files thumbnail_size photo_size max_backups scan_size encryption_standard archive_dir say_voice language/;
		foreach my $l ( @locations ) {
			push @settings, $l . '_location';
			push @settings, $l . '_archive';
		}
    my $settings = {};
    my $signatorial = &subs::signatorial_designer();
    my $device = &subs::device_setter();

    # 1. Collect all target devices into a single list. 'all' carries the
    # house-wide choices (the interface language), which every machine and
    # every device tab reads.
    my @devices = ( 'all', @gb::device_types, $signatorial );

    # 2. Fetch ALL matching records in a single database call
    # This assumes db_select supports array references for IN clauses
    my $results = eval {
        &subs::db_select('settings', ['device', 'setting', 'value'], {
            app    => 'misc',
            setting => \@settings,
            device  => \@devices
        })->hashes || [];
    };
    if ($@) {
        $log->error("Database error in misc_setting_list: $@");
    }

    # 3. Map the flat database rows into your nested $settings hash
    foreach my $row (@{$results}) {
        # Check for lowercase 'null' or undef from your previous database quirk
        my $val = (defined $row->{value} && lc($row->{value}) ne 'null') ? $row->{value} : undef;
        $settings->{$row->{device}}->{$row->{setting}} = $val;
    }

    # 4. Apply fallback defaults for missing settings, ensuring structure exists
    foreach my $dt (@devices) {
        foreach my $s (@settings) {
            my $res = $settings->{$dt}->{$s};

            if ($dt eq $signatorial && !$res) {
                $settings->{$dt}->{$s} = $settings->{$device}->{$s};
            }
        }
    }

    return $settings;
}

sub remote_useragent_maker($data) {
	my $ip = $data->{'ip'};
	my $signatorial = $data->{'signatorial'};
	my $rm = $data->{'rm'};
	my $uuid = $data->{'uuid'};
	my $auth_test = $data->{'auth_test'};
	my $ua = Mojo::UserAgent->new();
	$ua = $ua->max_response_size(0);
	# every request on the peer rail names this machine and carries a signature
	$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req); });
	unless ($rm) {
		if ($uuid) {
			$rm = &subs::remote_machine_lister({ uuid => $uuid, limit => 1 });
		} elsif ( $ip && $signatorial ) {
			$rm = &subs::remote_machine_lister({ signatorial => $signatorial, limit => 1 });
		} else {
			$rm = &subs::remote_machine_lister({ signatorial => $signatorial, limit => 1 });
		}
	}
	else {
		$rm = &subs::remote_machine_tunnel_processor($rm);
	}
	my $remote_address = $rm->{'ip'};
	my $port_dock = $rm->{'port_dock'} || 3000;
	my $port = $rm->{'port'};

	my $manager = $rm->{'manager'};
	# A retired tunnel leaves 127.0.0.1 behind, and a name is the only route
	# left. Resolve it before the cookie is scoped and every url is built.
	my $live_manager = &subs::peer_live_manager($rm);
	if (($manager || '') ne $live_manager) {
		$manager = $live_manager;
		$rm->{'manager'} = $manager;
	}
	if ($rm->{'cookie'}) {
		my $cookie_jar = decode_json $rm->{'cookie'};
		# The cookie was stored with the address the peer was reached on (often a
		# LAN ip), but the manager url is usually its fqdn: a cookie scoped to the
		# ip is never sent to the fqdn host. Scope it to whatever host we are about
		# to call, so the stored session actually rides along.
		my $host = eval { Mojo::URL->new($manager)->host };
		foreach my $cookie ( @{$cookie_jar} ) {
			$ua->cookie_jar->add(
				Mojo::Cookie::Response->new(
					name => $cookie->{'name'},
					value => $cookie->{'value'},
					domain => ($host || $cookie->{'domain'}),
					path => $cookie->{'path'}
				)
			);
		}
		$rm->{'ua'} = $ua;
		$rm->{'ua'}->inactivity_timeout(3000);
		$rm->{'ua'}->insecure(1);
		my $domain = $config->{'domain'} || $ip;
		if ($auth_test eq 'yes' || $data->{'chip_chyea'}) {
			my $url = $rm->{'manager'} . '/manager/remote_auth_test?signatorial=' . &subs::signatorial_designer() . '&auth_test=' . $auth_test;
			if ($data->{'chip_chyea'}) {
				$rm->{'ua'}->inactivity_timeout(2);
				$url .= '&chip_chyea=' . $data->{'chip_chyea'};
			}
			$url .= '&domain=' . $config->{'domain'};
			if ($auth_test eq 'yes' && defined $data->{'since'}) {
				$url .= '&since=' . int($data->{'since'});
			}
			if ($auth_test eq 'yes' && ref $data->{'digest'} eq 'HASH') {
				my %cuts = map { $_ => ($data->{'digest'}->{$_}->{'max'} || 0) } keys %{$data->{'digest'}};
				$url .= '&cuts=' . Mojo::Util::url_escape(&subs::sync_map_encode(\%cuts));
			}
			$url .= '&tombstone_cursor=' . int($data->{'tombstone_cursor'} || 0) if $auth_test eq 'yes';
			# The handshake is a cheap route that must answer quickly. The UA's other
			# timeout (3000s) exists so a snapshot pull can wait on a peer building a
			# large export; inheriting it here meant one stuck peer froze the whole
			# reconnector for fifty minutes, and every later peer in the roster waited
			# behind it. Bound this one request and put the long timeout back for the
			# requests that need it.
			my $long_timeout = $rm->{'ua'}->inactivity_timeout;
			$rm->{'ua'}->inactivity_timeout(15);
			my $res = eval { return $rm->{'ua'}->insecure(1)->get($url => {Accept => '*/*'} => 'Content!')->result };
			$rm->{'ua'}->inactivity_timeout($long_timeout);
			if (eval { $res->is_success }) {
				$rm->{'res'} = $res;
			} else {
				$rm->{'ua'} = undef;
			}
		}
	}
	else {
		# No stored session. The signed rail is what authenticates a peer request
		# (peer_sign_request rides every request this agent makes), so the agent is
		# usable anyway. Leaving it undef made every caller that checks for one -
		# the destination relay among them - treat the peer as unreachable and
		# silently do the work here instead of there.
		$rm->{'ua'} = $ua;
		$rm->{'ua'}->insecure(1);
		$rm->{'ua'}->inactivity_timeout(60);
	}
	$rm->{'data'} = eval { return decode_json $rm->{'data'} };

	return $rm;
}

sub guide_resolve_when($when) {
	my $now = &subs::rightNow();
	return $now unless defined $when && length $when;
	return $when + 0 if $when =~ /^\d{10,}$/;
	my $s = lc $when;
	$s =~ s/^\s+|\s+$//g;
	# the browser's helpResolveWhen takes "in 3 hours"; a spoken reminder uses
	# the same shape, and str2time would not read it
	if ($s =~ /^in\s+(\d+)\s*(minute|min|hour|hr|day|week)s?$/) {
		my ($n, $u) = ($1, $2);
		my $mult = ($u =~ /^min/) ? 60000 : ($u =~ /^h/) ? 3600000 : ($u =~ /^d/) ? 86400000 : 604800000;
		return $now + $n * $mult;
	}
	return $now if $s eq 'now';
	my $t = eval { str2time($when) };
	return $t ? $t * 1000 : $now;
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

sub leave($c) {
	if (!$c) {
		$c = &subs::controller_builder();
		$c->session('authentication', &subs::suds_grabber());
		$c->req->url->path('/manager/leave');
	}
	my ($db,$database,$sql) = &subs::database_grabber();
	&subs::say_it('leave');
	&remote_relay_request($c, { mode => 'emergency' });
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	$c->param('reason' => 'leave');
	my $server_time = &subs::rightNow();

	&subs::db_delete('settings',{app => '__DEBRIEFING__', device => $device});
	&subs::db_delete('settings',{app => 'keyboard'});
	&subs::db_delete('settings',{app => 'watch', setting => 'patience' });
#	&subs::db_delete('remote_machines');
	my $hostname = `hostname`;
	chomp($hostname);
	if ($c->param('debriefer')) {
		my $d = $c->param('debriefer');
		my $settings = decode_json $d;
		&subs::db_insert('settings', {
			app => '__DEBRIEFING__',
			timestamp => $timestamp,
			setting => $hostname,
			value => $d,
			device => $device,
			uuid => &subs::random_string_creator(20)
		});
	}
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'customs', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', $timestamp);
	&subs::db_insert('appointments', { warranty => $warranty, uuid => &subs::random_string_creator(40), app => "customs", type => "depart", timestamp => $timestamp, server_time => $server_time });
	&subs::backup_now($c);
	`shred -u $database`;
	`shred -u $database-shm`;
	`shred -u $database-wal`;
	`shred -u $logfile`;
	delete $c->session->{'authentication'};
	delete $c->session->{'database'};
	delete $c->session->{'suds_id'};
	delete $c->session->{'device_uuid'};
	delete $c->session->{'reject_count'};
	delete $c->session->{'browser_tab_id'};
	delete $c->session->{'browser_tab'};
	$gb::suds = undef;

	$gb::database_holder = undef;
	&subs::say_it('Goodbye');
	$sql = undef;
}

sub original_timestamp() {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $original_timestamp = &subs::db_query('select timestamp from security LIMIT 1');
	my $ts = $original_timestamp->hashes;
	return $ts->[0]->{'timestamp'} ;
}

sub appts_marker_builder {
	my $appts = shift;
	return $appts unless ref $appts eq 'HASH';
	my $settings = &subs::db_raw('select app, setting, value, server_time from settings where setting=? or setting=?', 'pos', 'mab');
	# A wallet account carries its coin beside its name, so the transaction form
	# can read an amount in that coin. One small read covers every account.
	my $crypto_rows = &subs::db_raw("select app, setting, value from settings where setting in ('payment_type','crypto_asset')");
	my %crypto;
	foreach my $c ( @{$crypto_rows} ) {
		$crypto{ $c->{'app'} }->{ $c->{'setting'} } = $c->{'value'};
	}
	foreach my $s ( @{$settings} ) {
		next unless $s->{'setting'} eq 'pos' || $s->{'setting'} eq 'mab';
		my $bucket = $s->{'value'} eq 'account' ? '__accounts'
			: $s->{'value'} eq 'project' ? '__projects' : '';
		next unless $bucket;
		my $wallet = '';
		my $cs = $crypto{ $s->{'app'} };
		if ($cs && lc($cs->{'payment_type'} || '') eq 'crypto') {
			my $asset = &subs::crypto_asset($cs->{'crypto_asset'});
			$wallet = $asset ? $asset->{'code'} : 'BTC';
		}
		push @{$appts->{$bucket}}, { formatted_name => &subs::format_name($s->{'app'}), app => $s->{'app'}, crypto_asset => $wallet, payment_type => ($bucket eq '__accounts' && $cs ? ($cs->{'payment_type'} || '') : '') }
			unless grep { $_->{'app'} eq $s->{'app'} } @{$appts->{$bucket} || []};
	}
	$appts->{'__specs'}->{'markers'} = 'yes' if ref $appts->{'__specs'} eq 'HASH';
	return $appts;
}

sub log_reader {
	my $disallowable = [];

	# Per-request memo for the pure transforms the per-row loop hammers: app names
	# repeat for every row of the same app and setting values repeat across rows.
	# None of these has side effects, so cached results are identical.
	my (%nmemo, %tmemo, %dmemo);
	my $fname = sub { my $k = $_[0] // ''; $nmemo{f}{$k} //= &subs::format_name($k) };
	my $uname = sub { my $k = $_[0] // ''; $nmemo{u}{$k} //= &subs::unformat_name($k) };
	my $hname = sub { my $k = $_[0] // ''; $nmemo{h}{$k} //= &subs::html_name($k) };
	my $pname = sub { my $k = $_[0] // ''; $nmemo{p}{$k} //= &subs::http_name($k) };
	my $sname = sub { my $k = $_[0] // ''; $nmemo{s}{$k} //= &subs::apostrophe_escape($k) };
	my $tabbr = sub { $tmemo{$_[0] // ''} //= &subs::time_abbrev_translator($_[0]) };
	my $dsay  = sub { $dmemo{$_[0] // ''} //= &subs::duration_sayer($_[0]) };
	my $data = $_[0] || {};
	my ($db,$database,$sql) = &subs::database_grabber();
	my $chosen_app = $data->{'app'};
	my $scope = $data->{'scope'};
	my $timestamp = $data->{'timestamp'};
	my $timeshift_max = $data->{'timeshift_max'};
	my $search = $data->{'search'};
	my $stats = $data->{'stats'};
	#my $misc_settings = &misc_setting_list();
	my $open_appts = $data->{'appts'};
	my $appt_toggle = $data->{'appt_view_toggle'};
	my $sorts = $data->{'sorts'};
	my $account = $data->{'account'};
	my $project = $data->{'project'};
	my $timestamp_selector = $data->{'sorts'} || 'timestamp';
	$timestamp_selector = 'timestamp' if $timestamp_selector eq 'occurrences';
	if ($sorts eq 'server_time') {
		$timestamp_selector = 'server_time';
	}
	my $time_definition = &subs::rightNow();
	my $server_time = $time_definition;
#	$time_definition = $timestamp unless $timestamp_selector eq 'server_time';
	undef @appointments;
	my ($results,$appointments);
	my $original_timestamp = &subs::db_query('select timestamp from security LIMIT 1');
	my $ts = $original_timestamp->hashes;


	my $signatorial = &subs::signatorial_designer();
	my $navigation_information = &subs::navigation_information({ signatorial => $signatorial, cache => 'yes' });
	my $birthday = &subs::duration_sayer(  ($timestamp / 1000 ) - &subs::ago_calc( $config->{'birthday'},$timestamp) / 1000) || (($timestamp / 1000 ) - (&original_timestamp() / 1000 ) );
	my $json;
	my $jdata = encode_json $data;
	my $appts = {
		'__specs' => {
			birthday => $birthday,
			timestamp => $timestamp,
			formatted_timestamp => localtime($timestamp / 1000 )->strftime('%a %D %I:%M:%S%P'),
			server_time => &subs::rightNow(),
			data => $jdata,
			site_type => $gb::site_types->{$navigation_information->{$signatorial}->{'site_type'}}
		},
		'__params' => $data,
	};

	if ($scope && $timestamp && $data->{'view'} eq 'appointment_viewer') {
		# appointment_viewer
		my $t = &subs::time_span($scope, $timestamp); #timestamp at beginning
		my $t1 = ($timestamp - $t);
		my $t2 = ($t1 + $timestamp + $t1);
		# The view is drawn from $t out to the centre and as far again, so anything
		# fetched beyond that right edge sticks to the right edge. Nothing is fetched
		# behind the left edge that could not still be seen from inside the view: a
		# row that stopped within it, which comes in with the span it ran, and a row
		# that never stopped at all - that last is pure presence: its row may be
		# older than anything else fetched, and its band is what the left half of the
		# view is holding on to. The keyboard's checkbox asks for the older view
		# instead: rows whose timestamp is inside the view, and nothing fetched
		# beyond either edge.
		my $in_view_only = (&subs::setting_grabber({ app => 'keyboard', setting => 'timestamp_in_view' }) || '') eq 'checked';
		my $fetch_end = $in_view_only ? ($timestamp + $t1) : $t2;
		# the client prunes by this; the oldest row carried settles it below
		my $fetch_start = $in_view_only ? $t : $t - $t1;
		# the column is text, so a numeric compare is lexicographic and finds nothing
		# once the window is before 1970 (a negative timestamp): cast only then, so the
		# common modern-range queries keep their index
		my $tint = (($t || 0) < 0 || ($fetch_end || 0) < 0) ? "cast($timestamp_selector as integer)" : $timestamp_selector;
		my $stopint = (($t || 0) < 0) ? 'cast(stop_timestamp as integer)' : 'stop_timestamp';
		# A finished appointment behind the view is left alone: it was over before
		# anything on screen, so its dot would pile against the edge with no band to
		# explain it. The line is "stopped inside the window" or "still running".
		# Written as one OR the planner optimizes each branch by one index, and the
		# second branch's "stop_timestamp is null" became a walk over every
		# never-stopped appointment in the table - the one query the poll could not
		# get cheap. Asked as two queries, the first rides the stop_timestamp index
		# and the second reaches the few start/record rows by type. The merge below
		# already de-duplicates and re-sorts whatever both hands back.
		my @stick_clauses = (
			[ 'appointments', "($stopint between ? and ?)", [ $t, $fetch_end ] ],
			# the still-running line wants the type index: left to choose, the planner
			# takes "stop_timestamp is null" for an equality and walks every
			# never-stopped row (tens of thousands) instead of the dozen start/record
			# rows. idx12_appts (type,app) is the one it should use.
			[ 'appointments indexed by idx12_appts', '(stop_timestamp is null and type in (?,?) and ' . $tint . ' <= ?)', [ 'start', 'record', $fetch_end ] ],
		);
		my $stick_suffix = '';
		my @stick_suffix_variables;
		if ($data->{'filter'} && $data->{'filter'} ne 'all') {
			$stick_suffix .= " and type = ?";
			push @stick_suffix_variables, $data->{'filter'};
		}
		if ($project && $project ne 'all') {
			$stick_suffix .= " and project = ?";
			push @stick_suffix_variables, $project;
		}
		if ($account && $account ne 'all') {
			$stick_suffix .= " and account = ?";
			push @stick_suffix_variables, $account;
		}
		my $stick_run = sub {
			my ($for_app, $app) = @_;
			foreach my $clause (@stick_clauses) {
				my ($from, $where, $vars) = @{$clause};
				my $q = "select * from $from where " . ($for_app ? "app = ? and " : '')
					. $where . $stick_suffix . " order by timestamp";
				$results = &subs::db_raw($q, ($for_app ? ($app) : ()), @{$vars}, @stick_suffix_variables);
				push @{$appointments}, @{$results};
			}
		};

		$appts->{'__specs'}->{'start'} = $t;
		$appts->{'__specs'}->{'end'} = $fetch_end;
		$appts->{'__specs'}->{'fetch_start'} = $fetch_start;
		if ($appt_toggle eq 'on') {
			my $temp_appointments;

			foreach my $a (@{$open_appts}) {
				my @query_variables = ( $a, $t, $fetch_end );

				my $query;
				if ($data->{'filter'} && $data->{'filter'} ne 'all') {
					$query = "select timestamp,app,server_time,type,duration from appointments where app = ? AND $tint between ? and ? and type = ?";
					push @query_variables, $data->{'filter'};
				}
				else {
					$query = "select timestamp,app,server_time,type,duration from appointments where app = ? AND $tint between ? and ?";
				}
				if ($project && $project ne 'all') {
					$query .= " and project = ? ";
					push @query_variables, $project;
				}
				if ($account && $account ne 'all') {
					$query .= " and account = ? ";
					push @query_variables, $account;
				}
				$query .=  " order by $timestamp_selector";
				$results = &subs::db_raw($query, @query_variables);
				$temp_appointments = $results;
				push @{$appointments}, @{$temp_appointments};
				unless ($in_view_only) {
					$stick_run->(1, $a);
				}
			}
		}
		else {
			my $query;
			my @query_variables = ( $t, $fetch_end );
			if ($data->{'filter'} && $data->{'filter'} ne 'all') {
				$query = "select distinct(app) as app,* from appointments where $tint between ? and ? and type = ?";
				push @query_variables, $data->{'filter'};
			}
			else {
				$query = "select distinct(app) as app,* from appointments where $tint between ? and ?";

			}
			if ($project && $project ne 'all') {
				$query .= " and project = ? ";
				push @query_variables, $project;
			}
			if ($account && $account ne 'all') {
				$query .= " and account = ? ";
				push @query_variables, $account;
			}
			$query .= " order by $timestamp_selector LIMIT 500";

			$appointments = &subs::db_raw($query, @query_variables);
			unless ($in_view_only) {
				$stick_run->();
			}
		}
		# a row inside the view can be a stop or a presence too, so both queries
		# can find it: keep the first of each row, and put the list back in time
		# order - last_event, the status and the formatted times all read off its
		# tail. The key cannot be the uuid alone: the per-appointment query does
		# not fetch one.
		$appointments = [] unless $appointments;
		my %seen_row;
		my @merged_rows;
		foreach my $row (sort { ($a->{$timestamp_selector} || 0) <=> ($b->{$timestamp_selector} || 0) } @{$appointments}) {
			my $row_key = join '|', $row->{'app'}, $row->{'timestamp'}, $row->{'type'}, $row->{'duration'};
			next if $seen_row{$row_key}++;
			push @merged_rows, $row;
		}
		$appointments = \@merged_rows;
		# the payload reaches back as far as the rows it carries, so the client
		# prunes by what it was actually handed
		foreach my $row (@merged_rows) {
			if ($row->{'timestamp'} && $row->{'timestamp'} < $appts->{'__specs'}->{'fetch_start'}) {
				$appts->{'__specs'}->{'fetch_start'} = $row->{'timestamp'};
			}
		}
#		my $resulters = &subs::db_query('select * from continent where timestamp >= ? and timestamp <= ?',$t,$t2);
		my $continent = [];#$resulters->hashes;
		my ($last,$next);
		my $n = 0;
		foreach my $con ( @{$continent }) {

			$n = $n + 1;
			my $last = $continent->[$n - 1];
			my $next = $continent->[$n + 1];

			if ($con->{'latitude'} ) {
				push @{$appts->{'__continent'}}, { latitude => $con->{'latitude'}, longitude => $con->{'longitude'} };
			}
		}
	}
	elsif ($search) {
		#search
		my @search_split = split ' ', $search;
		my $searchable = join '%', @search_split;

		my $s = "%" . $searchable . "%";
		my $temp_appointments = &subs::db_raw('select * from appointments where app like ?', $s);
		my (@n,@perfect_n);
		foreach my $a (reverse @{$temp_appointments}) {
			if ($a->{'app'} eq $searchable) {
				unshift @n, $a unless grep { $_->{'app'} eq $a->{'app'} } @n;
			}
			else {
				push @n, $a unless grep { $_->{'app'} eq $a->{'app'} } @n;
			}
		}
		push @{$appointments}, @n;

	}
	elsif ($chosen_app && $data->{'view'} eq 'centre_view') {
		#centre_view
		# The bound here is "now", which is positive, so a plain text compare keeps
		# the (app,timestamp) index and reads one row instead of sorting the app's
		# whole history - the cast in both the compare and the order forced a temp
		# B-tree over every row of the app, on every header render. Only a pre-1970
		# stamp needs the numeric cast: "-441..." reads above "-315...", so if the
		# newest candidate is negative, ask again numerically. The oldest-at-or-after-
		# now query needs no fallback, since a negative stamp can never qualify.
		$appointments = &subs::db_raw("select timestamp,stop_timestamp,file,server_time,app,duration,type,status,amount,unit,project,club,account,vendor from appointments where app is not null and app=? and $timestamp_selector <=? order by $timestamp_selector DESC limit 1", $chosen_app,$time_definition);
		if ($appointments->[0] && ($appointments->[0]->{$timestamp_selector} || '') =~ /^-/) {
			$appointments = &subs::db_raw("select timestamp,stop_timestamp,file,server_time,app,duration,type,status,amount,unit,project,club,account,vendor from appointments where app is not null and app=? and cast($timestamp_selector as integer) <=? order by cast($timestamp_selector as integer) DESC limit 1", $chosen_app,$time_definition);
		}
		push @{$appointments}, @{&subs::db_raw("select timestamp,stop_timestamp,file,server_time,app,duration,type,status,amount,unit,project,club,account,vendor from appointments where app is not null and app=? and $timestamp_selector >=? order by $timestamp_selector limit 1", $chosen_app,$time_definition)};


		@{$appointments} = grep { $_->{'app'} eq $chosen_app } @{$appointments};
		if (scalar @{$appointments} == 0) {
			push @{$appointments}, { app => $chosen_app };
		}
	}
	elsif ($chosen_app && $data->{'view'} eq 'appointment_details') {
		#appointment_details;
		# a scope is required for the window: without one the request used to
		# fall through to the final else below, whose body returns a bare 0, so
		# every row vanished and the details panel read "0 apps" when it was
		# opened without a scope in the request (the client always sends one, but
		# the watch, the boards and hand-made requests do not)
		$scope = 'hour' unless $scope;
		my $t = &subs::time_span($scope, $timestamp); #timestamp at beginning
		my $t1 = ($timestamp - $t);
		my $t2 = ($t1 + $timestamp);
		# the window is drawn from the travelled time, so it can be before 1970 (a
		# negative timestamp): the text column then compares lexicographically and
		# finds nothing. Cast only when the window is pre-epoch, so the common modern
		# range keeps its index (the same choice the appointment_viewer makes above).
		my $pre_epoch = (($t || 0) < 0 || ($t2 || 0) < 0);
		my $tint = $pre_epoch ? "cast($timestamp_selector as integer)" : $timestamp_selector;
		my $stopint = $pre_epoch ? 'cast(stop_timestamp as integer)' : 'stop_timestamp';
		# Show every appointment that has any presence in the period, using the same
		# three tests the appointment_viewer draws its bands with: its own moment
		# (its start, for a span) lands inside the period; it stopped inside it; or it
		# is a span still running (a start/record row with no stop) that had already
		# begun by the period's end. A completed span is a 'stop' row whose timestamp
		# is its start and whose stop_timestamp is its stop, so the middle test is
		# what catches a span that began before the period and was still going when it
		# opened; the old test only ever looked at start/record rows and so missed
		# them.
		my $presence = "(($tint >= ? AND $tint <= ?) OR ($stopint >= ? AND $stopint <= ?) OR (stop_timestamp IS NULL AND type IN (?,?) AND $tint <= ?))";
		my @presence = ($t, $t2, $t, $t2, 'start', 'record', $t2);
		if ($data->{'uuid'}) {
			$results = &subs::db_raw("select * from appointments where app=? and uuid=? order by server_time DESC", $chosen_app, $data->{'uuid'});
		}
		elsif ($data->{'filter'} ne 'all') {
			$results = &subs::db_raw("select * from appointments where app=? and type=? and $presence order by timestamp DESC", $chosen_app, $data->{'filter'}, @presence);
		}
		else {
			$results = &subs::db_raw("select * from appointments where app=? and $presence order by timestamp DESC", $chosen_app, @presence);
		}
		$appointments = $results;
	}
	elsif ($chosen_app && $data->{'view'} eq 'appointment_display') {
		# appointment_display (configure)
		$appointments = &subs::db_raw("select * from appointments where app=? order by $timestamp_selector limit 1", $chosen_app,$timestamp_selector);
		if (scalar @{$appointments} == 0) {
			push @{$appointments}, { app => $chosen_app };
		}

	}
	else {
		# Just give it all to me.
#		$results = &subs::db_query("select distinct(app) as app,* from appointments order by $timestamp_selector");
#		$appointments = $results->hashes;
		return 0;
	}

	# An appointment inherits the strictest visibility of its app and the
	# social constructs named on the row (project, club, account, vendor). The
	# timeline never shows a private record, even while the fingerprint grant is
	# live; every other view hides it unless this is a private place and the
	# screen holds the grant. Configure's own card is the exception below, so the
	# level can be changed.
	if (($data->{'view'} || '') ne 'appointment_display') {
		my $timeline = (($data->{'view'} || '') eq 'appointment_viewer');
		my $private_open = &subs::private_reachable_now() && &subs::private_revealed();
		@{$appointments} = grep {
			!&subs::appointment_private_now($_) || (!$timeline && $private_open);
		} @{$appointments};
	}

	# The pos/mab markers are the app's place in the world (idea, product, ...).
	# They build __accounts/__projects, which only the details/wrapper windows
	# draw: the JSON viewer never uses them, and a header-only fetch does not
	# either. Skip the ~1600-row read for those, and let the centre view build
	# them once before it renders the wrapper.
	my $settings = [];
	unless (($data->{'view'} || '') eq 'appointment_viewer' || $data->{'header'}) {
		&appts_marker_builder($appts);
	}
	my @app_names = ( &subs::device_setter() );
	my %seen_app = ( $app_names[0] => 1 );
	my $s_query = 'select * from settings where device = ? and (';
	foreach my $a ( @{$appointments} ) {
		my $an = $a->{'app'};
		unless ( $seen_app{$an} ) {
			$seen_app{$an} = 1;
			push @app_names, $an;
			$s_query .= ' or' if scalar @app_names > 2;
			$s_query .= ' app = ?';
		}
	}
	$s_query .= ')';
	# The subcategory selectors (sc_idea, sc_service, ...) belong to the POS
	# person, and every browser reads them from the POS window itself when it
	# needs them. In this window they are pure weight: two of them alone were
	# 535 KB of the payload the centre view was re-fetching every second. The
	# viewer never looks at them, so here they are neither read nor sent.
	$s_query .= " and substr(setting,1,3) <> 'sc_'" if ($data->{'view'} || '') eq 'appointment_viewer';
	if (scalar @app_names > 1) {
		my @app_settings = @{&subs::db_raw($s_query, @app_names)};

		if ($data->{'view'} eq 'appointment_viewer') {
			if (my @invisible = grep { $_->{'setting'} eq 'visible' && (&subs::app_private_now($_->{'app'}) || &help_app_hidden($_->{'app'})) } @app_settings) {
				foreach my $invisible ( @invisible ) {
					@{$appointments} = grep { $_->{'app'} ne $invisible->{'app'} } @{$appointments};
					@app_settings = grep { $_->{'app'} ne $invisible->{'app'} } @app_settings;
				}
			}
		}
		push @{$settings}, @app_settings;
	}

	my ($settings_server_first, $settings_server_last) = (0, 0);
	foreach my $s (@{$settings}) {
		my $st = $s->{'server_time'};
		next unless defined $st && $st =~ /[0-9]/;
		$settings_server_first = $st if !$settings_server_first || $st < $settings_server_first;
		$settings_server_last  = $st if $st > $settings_server_last;
	}
	$appts->{'__specs'}->{'stats'}->{'settings'}->{'first'} = $settings_server_first;
	$appts->{'__specs'}->{'stats'}->{'settings'}->{'last'}  = $settings_server_last;
	# The markers the client echoes back so an unchanged tick can be answered
	# "nothing new": how many rows the window holds and the span of server_time in
	# them. min/max rather than the first and last of the list, because a row
	# edited in the middle bumps its server_time without moving - that is a change
	# too. Zero when the window is empty, so they are always there to be echoed.
	# They are read here, after the visible filter above, because that is the set
	# the client draws: counting the raw window instead made the echoed count
	# disagree whenever an invisible appointment was in the window, so the
	# nothing-new short-circuit could never fire then.
	my ($appt_server_first, $appt_server_last) = (0, 0);
	foreach my $a (@{$appointments}) {
		my $st = $a->{'server_time'};
		next unless defined $st && $st =~ /[0-9]/;
		$appt_server_first = $st if !$appt_server_first || $st < $appt_server_first;
		$appt_server_last  = $st if $st > $appt_server_last;
	}
	$appts->{'__specs'}->{'stats'}->{'appts'}->{'first'} = $appt_server_first;
	$appts->{'__specs'}->{'stats'}->{'appts'}->{'last'}  = $appt_server_last;
	$appts->{'__specs'}->{'stats'}->{'appts'}->{'count'} = scalar @{$appointments};
	if ($stats) {
		# The client echoes the markers above while its view is fresh. When every
		# one of them still matches, the rows and settings the window draws are
		# exactly the ones it is already showing, and the whole per-app build below -
		# the work a one-second poll would otherwise redo - can be skipped. Markers
		# it did not send stay undefined, so a half-known request never reads as "no".
		my $same =
			   !&subs::private_revealed()
			&& defined $stats->{'appts'}->{'count'} && defined $stats->{'appts'}->{'first'} && defined $stats->{'appts'}->{'last'}
			&& defined $stats->{'settings'}->{'first'} && defined $stats->{'settings'}->{'last'}
			&& scalar @{$appointments} == $stats->{'appts'}->{'count'}
			&& $appt_server_last  <= $stats->{'appts'}->{'last'}
			&& $appt_server_first >= $stats->{'appts'}->{'first'}
			&& $settings_server_last  <= $stats->{'settings'}->{'last'}
			&& $settings_server_first >= $stats->{'settings'}->{'first'};
		if ($same) {
			return { updateable => 'no', '__specs' => $appts->{'__specs'} };
		}
	}

	# The three little per-app tables below (model, option, option_category) were
	# read for *every row*, and every row of the same app asked the same three
	# questions again. The centre view polls once a second, so that was ~45
	# SQL::Abstract round trips on every tick, each rebuilding its own statement -
	# the single largest cost of the view. One query per table, asked once for the
	# whole set of apps in the window, answers them all; the rows are grouped by
	# app here and handed back to the loop below.
	my %appt_table_lookup;
	{
		my (%seen_app, @lookup_apps);
		foreach my $a (@{$appointments}) {
			next unless $a->{'app'};
			my $lookup_app = $uname->($a->{'app'});
			next if $seen_app{$lookup_app}++;
			push @lookup_apps, $lookup_app;
		}
		if (@lookup_apps) {
			my $placeholders = join ',', ('?') x scalar @lookup_apps;
			foreach my $at ( qw/model option option_category/ ) {
				my $rows = &subs::db_query("select * from $at where app in ($placeholders)", @lookup_apps);
				foreach my $row ( @{ $rows->hashes } ) {
					push @{ $appt_table_lookup{$at}->{$row->{'app'}} }, $row;
				}
			}
		}
	}

	# The per-row loop below used to re-scan the whole settings list (the pos/mab
	# markers plus every app in the window - better than two thousand rows) once or
	# twice for every appointment. Bucketing by app once answers each lookup with
	# its own short list, which is what the loop actually wanted.
	my %settings_by_app;
	foreach my $s (@{$settings}) {
		push @{ $settings_by_app{$s->{'app'}} }, $s;
	}

	foreach my $a (@{$appointments}) {
		next unless $a->{'app'};
	#	$a->{'file'} = undef if $data->{'view'} eq 'appointment_viewer';
		#unless ($data->{'view'} eq 'appointment_viewer') {
		#	my $cache_check = &subs::cache_get({ app => $a->{'app'}, context => $data->{'view'} });
		#	if ($cache_check) {
		#	#	$appts->{$a->{'app'}} = $cache_check;
		#	#	next;
		#	}
		#}
		$a->{'app'} = $uname->($a->{'app'});
		my @a_settings = @{ $settings_by_app{$a->{'app'}} || [] };
		foreach my $s (@{ $settings_by_app{$a->{'app'}} || [] }) {
			if ($s->{'setting'} eq 'colour' && !length $s->{'value'}) {
				# blank only - an appointment keeps the colour it was given until the
				# user re-themes them from configure/misc_setting_list
				$s->{'value'} = &subs::theme_colour_for_app($s->{'app'}, $s->{'value'}, $s->{'device'});
			}
			$appts->{$a->{'app'}}->{'setting'}->{$s->{'setting'}} = $s->{'value'};
			foreach my $oi ( ($scope) ) {
				if ($s->{'setting'} =~ /warranty|duration/gi) {
					$appts->{$a->{'app'}}->{'setting'}->{$oi . '_' . $s->{'setting'}} = $tabbr->($s->{'value'});
					if (($a->{'type'} eq 'start' || $a->{'type'} eq 'record') && $a->{'timestamp'} < $timestamp) {# && (!$a->{'duration'} || ($a->{'duration'} >= $a->{'timestamp'} - $timestamp))) {
						$a->{'duration'} = $a->{'timestamp'} - $timestamp;
					}
					unless ($a->{'type'} =~ /record|start/) {
						if (my $dur = $a->{'duration'} || $appts->{$a->{'app'}}->{'setting'}->{$oi . '_' . $s->{'setting'}}) {
							$a->{'formatted_' . $s->{'setting'}} = $dsay->(($dur / 1000));
						}
					}
				}
			}

		}
		# an app born before dark_colour existed has no row for it: give the viewers
		# the same counterpart the settings getter would hand them
		if (!$appts->{$a->{'app'}}->{'setting'}->{'dark_colour'}) {
			$appts->{$a->{'app'}}->{'setting'}->{'dark_colour'} = &subs::dark_colour_for($appts->{$a->{'app'}}->{'setting'}->{'colour'});
		}
	# A private appointment never appears on the timeline, even while the
	# private fingerprint grant is live and even at home. Configure's own card is
	# the deliberate exception: it must stay readable so the level can be changed.
	# Every other view (a centre view, a header) reads the ordinary rule, so a
	# private app opened from the start menu in a private place still opens.
	if ($data->{'view'} ne 'appointment_display') {
		if (($data->{'view'} || '') eq 'appointment_viewer' && &subs::app_private_now($a->{'app'})) {
			push @{$disallowable}, $a->{'app'};
		}
		elsif (&subs::app_hidden_now($a->{'app'})) {
			push @{$disallowable}, $a->{'app'};
		}
	}

		foreach my $at ( qw/model option option_category/ ) {
			$appts->{$a->{'app'}}->{$at} = $appt_table_lookup{$at}->{$a->{'app'}} || [];
		}
		if ($data->{'view'} eq 'centre_view') {
			my @bm = sort keys %{$gb::budget_modes};

			$appts->{$a->{'app'}}->{'setting'}->{'budget_modes'} = \@bm;
			foreach my $br ( @bm ) {
				if (my $cache = &subs::cache_get({ app => $a->{'app'}, context => 'budget', subcontext => $br })) {
					$appts->{$a->{'app'}}->{'budget'}->{$br} = $cache;
				}
			}
		}

		if ($a->{'duration'} !~ /[0-9]/) { $a->{'duration'} = 0; }
		$appts->{$a->{'app'}}->{'timestamp'} = $a->{'timestamp'};
		$appts->{$a->{'app'}}->{'name'} = $uname->($a->{'app'});
		$appts->{$a->{'app'}}->{'html_name'} = $hname->($a->{'app'});
		$appts->{$a->{'app'}}->{'http_name'} = $pname->($a->{'app'});
		$appts->{$a->{'app'}}->{'apostrophe_escape'} = $sname->($a->{'app'});
		$appts->{$a->{'app'}}->{'setting'}->{'wiki'} = 'https://en.wikipedia.org/wiki/' . &subs::wiki_name($a->{'app'});
		unless ($data->{'notes'} && $data->{'notes'} eq 'on') {
			$a->{'start_notes'} = 'redacted' if $a->{'start_notes'};
			$a->{'notes'} = 'redacted' if $a->{'notes'};
			$a->{'end_notes'} = 'redacted' if $a->{'end_notes'};
		}
		$appts->{$a->{'app'}}->{'formatted_name'} = $fname->($a->{'app'});
		$appts->{$a->{'app'}}->{'shorthand_name'} = &subs::shorthand_name($appts->{$a->{'app'}}->{'formatted_name'});
		my $lt = localtime($a->{'timestamp'} / 1000 );
		$a->{'formatted_time'} = $lt->strftime('%a %b %d %Y - %I:%M:%S%P');
		$a->{'formatted_server_time'} = localtime($a->{'server_time'} / 1000 )->strftime('%a %b %d %Y - %I:%M:%S%P %Z');
		$appts->{$a->{'app'}}->{'just_time'} = $lt->strftime('%I:%M%P');
		$appts->{$a->{'app'}}->{'just_date'} = $lt->strftime('%a %b %d %Y');

		if (!$a->{'duration'} && grep { 'duration' eq $_->{'setting'} } @a_settings ) {
			$a->{'duration'} = $tabbr->($appts->{$a->{'app'}}->{'setting'}->{'duration'});
		}
		if ($a->{'timestamp'} < $timestamp && ($a->{'type'} eq 'start' || $a->{'type'} eq 'record')) {
			$a->{'duration'} = $a->{'timestamp'} - $timestamp;
		}
		$appts->{$a->{'app'}}->{'duration'} = $a->{'duration'};

		$a->{'formatted_duration'} = $dsay->(abs $a->{'duration'} / 1000);
		$a->{'warranty'} = $a->{'warranty'} || $appts->{$a->{'app'}}->{'setting'}->{'warranty'};
		$appts->{$a->{'app'}}->{'formatted_duration'} = $dsay->($a->{'duration'});
		$appts->{$a->{'app'}}->{'formatted_duration'} = $dsay->((time()  - $a->{'timestamp'})) unless $a->{'duration'};
		$appts->{$a->{'app'}}->{'file'} = $a->{'file'};
		if ($a->{'file'} ) {
			if ($a->{'type'} eq 'snapshot') {
				push @{$a->{'files'}}, { file => $a->{'file'}, file_type => 'img' };
			}
			else {
				my $files = eval { return decode_json $a->{'file'} } || [];
				if (eval { $files->{'f'} }) {
					$files = [ $files ];
				}
				foreach my $file (@{$files}) {
					push @{$a->{'files'}}, &subs::log_reader_file_preparer($file);
				}
			}
		}

		# the old write-only @appointments grep/unshift here grew O(n^2) per view;
		# nothing ever read it, so it is gone
		if ($appts->{$a->{'app'}}->{'total'} || $appts->{$a->{'app'}}->{'amount'}) {
			$a->{'label'} = "transaction";
			$a->{'type'} = "transaction";
			$appts->{$a->{'app'}}->{'total_amount'} += unformat_number($a->{'amount'});
			$appts->{$a->{'app'}}->{'total_tax'} += unformat_number($a->{'tax'});
			$appts->{$a->{'app'}}->{'total_total'} += unformat_number($a->{'total'});
			$appts->{$a->{'app'}}->{'total_quantity'} += unformat_number($a->{'quantity'});
			$appts->{$a->{'app'}}->{'formatted_time'} = localtime($a->{'timestamp'} / 1000 )->strftime('%a %b %d %Y - %I:%M:%S%P');
			push @{$appts->{$a->{'app'}}->{'vendors'}}, $a->{'vendor'};

			$appts->{$a->{'app'}}->{'last_transaction'} = $appts->{$a->{'app'}}->{'timestamp'};
			$appts->{$a->{'app'}}->{'vendor_list'} = encode_json $appts->{$a->{'app'}}->{'vendors'};
		}
		if ($a->{'amount'}) {
			$appts->{$a->{'app'}}->{'total_amount'} -= $a->{'amount'} if $a->{'amount'} < 0;
		}
		my $timestamp = $a->{'timestamp'};
		my $type = $a->{'type'};
		$a->{'formatted_name'} = $fname->($a->{'app'});
		push @{$appts->{$a->{'app'}}->{'list'}}, $a;
		$appts->{$a->{'app'}}->{'last_event'} = $timestamp;
		$a->{'formatted_account'} = $fname->($a->{'account'});
		$a->{'formatted_type'} = $fname->($a->{'type'});
		$a->{'formatted_project'} = $fname->($a->{'project'});
		if ($project && $project ne 'all') {
			$appts->{$a->{'app'}}->{'last_project'} = $project;
		}
		else {
			$appts->{$a->{'app'}}->{'last_project'} = $a->{'project'};
		}
		if ($account && $account ne 'all') {
			$appts->{$a->{'app'}}->{'last_account'} = $account;
		}
		else {
			$appts->{$a->{'app'}}->{'last_account'} = $a->{'account'};
		}
	#	if ($type =~ 'start|record|pause|transaction|reset|note') {
			$appts->{$a->{'app'}}->{'last_reset'} = $timestamp;
	#	}
		if ($json->{'type'} && $json->{'type'} eq 'inventory') {
			$appts->{$a->{'app'}}->{'invs'} += $json->{'inv'};
			$appts->{$a->{'app'}}->{'inv'} = $appts->{$a->{'app'}}->{'resets'} ;
		}
		$a->{'duration'} = '' if $a->{'duration'} eq 'NaN';
		if ($a->{'type'} =~ /start|record/) {
			$appts->{$a->{'app'}}->{'formatted_start_time'} = $a->{'formatted_time'};
			$appts->{$a->{'app'}}->{'formatted_end_time'} = &subs::formatted_time($a->{'timestamp'} + ($a->{'duration'} || 0));
		}
		else {
			$appts->{$a->{'app'}}->{'formatted_end_time'} = $a->{'formatted_time'};
			$appts->{$a->{'app'}}->{'formatted_start_time'} = &subs::formatted_time($a->{'timestamp'} - ($a->{'duration'} || 0));
		}
		push @{$appts->{$a->{'app'}}->{'transactions'}}, grep { $_->{'type'} eq 'transaction' && $_->{'app'} eq $a->{'app'} } @{$appointments};
		$appts->{$a->{'app'}}->{'setting'}->{'status'} = $appts->{$a->{'app'}}->{'list'}->[-1]->{'type'} unless $appts->{$a->{'app'}}->{'setting'}->{'status'} && $appts->{$a->{'app'}}->{'setting'}->{'status'} =~ /record|start|paused|resumed|completed|transaction/;

		#&subs::cache_set({app => $a->{'app'}, context => $data->{'view'} }, $appts->{$a->{'app'}});
	}

	foreach my $disallowed ( @{$disallowable} ) {
		delete $appts->{$disallowed};
	}

	return $appts;
}

sub remote_relay_request($c, $extra_params = {}) {
	unless ($c->param('remoted') eq 'yes') {
		my $remote_uuid = $c->param('remote_uuid') || $extra_params->{'remote_uuid'};
		my $signatorial = &subs::signatorial_designer();
		if (1 == 1) {
			$c->param('subprocess' => undef);

			my $path = $c->req->url->path;
			my $uuid = $c->param('uuid');
			# a caller that already stamped the request (the task checkbox does)
			# hands its server_time in, so every machine applies and records the
			# change under one clock instead of each guessing its own
			my $server_time = $extra_params->{'server_time'} || &subs::rightNow();
			my $source_signatorial = $c->param('source_signatorial');
			# Gossip id + the machine that handed us this request (never echoed
			# back to it). A broadcast mints the id here (origin); a machine that
			# received one carries it forward. Single-target proxies are neither.
			my $relay_id = $c->param('relay_id');
			my $relay_from = $c->param('relay_from') || $source_signatorial;
			unless ($remote_uuid) {
				if ($relay_id) {
					# receiver: before_dispatch already claimed the id
				}
				else {
					$relay_id = &subs::random_string_creator(30);
					&subs::relay_fresh($relay_id);
				}
			}
			my $remote_machines;
			if ($remote_uuid) {
				$remote_machines = &subs::remote_machine_lister({ connection => 'active', uuid => $remote_uuid });
			}
			else {
				# Flood: hand it to every machine we can currently reach, bar
				# ourselves and whoever handed it to us. The hub is just one peer
				# here, so the fleet still converges while the hub is down;
				# relay_id makes each machine handle the request only once.
				$remote_machines = &subs::db_query('select * from remote_machines where connection=?', 'active')->hashes;
				$remote_machines = [ grep {
						($_->{'signatorial'} || '') ne $signatorial
						&& ($_->{'signatorial'} || '') ne ($relay_from || '')
						&& ($_->{'signatorial'} || '') ne ($source_signatorial || '')
					} @{$remote_machines} ];
			}


			foreach my $rm ( @{$remote_machines} ) {
				$rm = &remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm });
				my $method = lc $c->req->method;
				my $res;
				if ($extra_params->{'override'} eq 'manual') {
	#				&remote_relay_request($c, { dissemination => 'yes', url => $url, params => $app, type => 'post', override => 'manual' });
					my $params = $extra_params->{'params'};
					if ($extra_params->{'dissemination'} || &subs::device_setter() eq 'server') {
						$params->{'dissemination'} = 'yes';
						$params->{'source_signatorial'} = $signatorial;
					} else {
						$params->{'remoted'} = 'yes';

					}
					if ($extra_params->{'type'} eq 'post') {
						my $url = $rm->{'manager'} . $extra_params->{'url'};
						my $res = $rm->{'ua'}->post($url => form => $params)->result;
					} else {
						my $params = Mojo::Parameters->new(%{$params});
						$params = $params->to_string;
						my $url = $rm->{'manager'} . $extra_params->{'url'} . '?' . $params;
						$res = $rm->{'ua'}->get($url);# => { Accept => '*/*' } => 'Content!');
					}




				}
				elsif ($method eq 'post') {
					my $params = $c->req->body_params->to_hash;
					if (scalar keys %{$params} == 0) {
						$params = $c->req->body_params->{'string'};
					}
					my $all_params = $c->req->query_params;
					my $sp = {};

					for (my $n = 0; $n < scalar @{$all_params->{'pairs'}} - 1; $n++) {
						if ($all_params->{'pairs'}->[$n] eq 'file' || $all_params->{'pairs'}->[$n] eq 'track') {
							$all_params->{'pairs'}->[$n + 1] = url_escape $all_params->{'pairs'}->[$n + 1];
						}
						$params .= '&' . $all_params->{'pairs'}->[$n] . '=' . $all_params->{'pairs'}->[$n + 1];
						$extra_params->{$all_params->{'pairs'}->[$n]} = $all_params->{'pairs'}->[$n + 1];
						$n++;
					}
					foreach my $p ( keys %{$params} ) {
						$extra_params->{$p} = $params->{$p};
					}
					if ($remote_uuid) {
						$extra_params->{'remoted'} = 'yes';
					} else {
						$extra_params->{'dissemination'} = 'yes';
						$extra_params->{'source_signatorial'} = $signatorial;
						$extra_params->{'relay_from'} = $signatorial;
						$extra_params->{'relay_id'} = $relay_id if $relay_id;
					}
					$extra_params->{'server_time'} = $server_time;
					$extra_params->{'uuid'} = $uuid;
					$extra_params->{'remote_uuid'} = $remote_uuid unless $path eq '/file_open' ;
					foreach my $ep ( keys %{$extra_params} ) {
						$params .= '&' . $ep . '=' . $extra_params->{$ep};
					}


#					my $form_data = {
#					};
#					$rm->{'ua'}->inactivity_timeout(3);
					my $url = $rm->{'manager'} . $path;
					my $body;
					eval {
						my $res = $rm->{'ua'}->post($url => form => $extra_params)->result;
						$body = $res->body;
					};




#					$res = $rm->{'ua'}->post($url)->result;
					return $body if $remote_uuid;

				}
				else {
					my $all_params = $c->req->query_params;
					my $params;
					for (my $n = 0; $n < scalar @{$all_params->{'pairs'}} - 1; $n++) {
						if ($all_params->{'pairs'}->[$n] eq 'file' || $all_params->{'pairs'}->[$n] eq 'track') {
							$all_params->{'pairs'}->[$n + 1] = url_escape $all_params->{'pairs'}->[$n + 1];
						}
						$params .= '&' . $all_params->{'pairs'}->[$n] . '=' . $all_params->{'pairs'}->[$n + 1];
						$n++;
					}
					if ($remote_uuid) {
						$extra_params->{'remoted'} = 'yes';
					} else {
						$extra_params->{'dissemination'} = 'yes';
						$extra_params->{'source_signatorial'} = $signatorial;
						$extra_params->{'relay_from'} = $signatorial;
						$extra_params->{'relay_id'} = $relay_id if $relay_id;
					}
					$extra_params->{'server_time'} = $server_time;
					$extra_params->{'uuid'} = $uuid;
					$extra_params->{'remote_uuid'} = $remote_uuid unless $path eq '/file_open' ;
					foreach my $ep ( keys %{$extra_params} ) {
						$params .= '&' . $ep . '=' . $extra_params->{$ep};
					}

					my $url = $rm->{'manager'} . $path . '?' . $params;
      			$rm->{'ua'} = $rm->{'ua'}->max_response_size(0);
					# A picture relay is a bounded errand. The peer agent's timeout is
					# generous because a snapshot pull may legitimately take minutes;
					# inheriting that for a cover meant one unreachable peer could hold a
					# worker for fifty minutes, and a grid of covers held every worker.
					my $file_fetch = ($remote_uuid && ($path eq '/file_open' || $path eq '/play')) ? 1 : 0;
					my ($old_inactive, $old_request, $old_connect);
					if ($file_fetch) {
						$old_inactive = $rm->{'ua'}->inactivity_timeout;
						$old_request = $rm->{'ua'}->request_timeout;
						$old_connect = $rm->{'ua'}->connect_timeout;
						$rm->{'ua'}->inactivity_timeout(6);
						# A picture is a bounded body; a track may legitimately be large, so
						# only the picture path gets a total-time cap.
						$rm->{'ua'}->request_timeout(20) if $path eq '/file_open';
						$rm->{'ua'}->connect_timeout(4);
					}
					$res = eval { $rm->{'ua'}->get($url) };# => { Accept => '*/*' } => 'Content!');
					if ($file_fetch) {
						$rm->{'ua'}->inactivity_timeout($old_inactive) if defined $old_inactive;
						$rm->{'ua'}->request_timeout($old_request) if defined $old_request;
						$rm->{'ua'}->connect_timeout($old_connect) if defined $old_connect;
					}
					# Told apart from an empty file: rock_and_roll uses this to stop
					# asking the same dead peer for every other picture on screen.
					unless ($res) { $c->stash('remote_relay_error' => 1); return undef; }
					if ($res->error) { $c->stash('remote_relay_error' => 1); }

					if ($path eq '/file_open' || $path eq '/play') {
						my $asset = $res->res ? $res->res->content->asset : undef;
						my $data = $asset ? $asset->slurp : undef;
						return $data if $remote_uuid && defined $data;
					}
					else {
						my $body = eval { $res->result->body };
						return $body if $remote_uuid && defined $body;
					}
				}

				my $additions = eval { return decode_json $rm->{'additions'} } || [];

		#		push @{$additions}, { app => $app, uuid => $uuid, scope => 'single', initialization => &subs::rightNow() };
				my $jadditions = encode_json $additions;
		#		&subs::db_update('remote_machines', { additions => $jadditions }, { uuid => $rm->{'uuid'}, signatorial => $rm->{'signatorial'} });


			}
		}

	}
}

sub appointment_overlap {
	my ($appt, $start, $end) = @_;
	my $from = ($appt->{'timestamp'} || 0) + 0;
	my $to = $from + abs($appt->{'duration'} || 0);
	my $lo = $from > $start ? $from : $start;
	my $hi = $to < $end ? $to : $end;
	return $hi > $lo ? $hi - $lo : 0;
}

sub father_time($data) {
	my $start_time = &subs::rightNow();

	my $scope = $data->{'scope'};
	my $ts = $data->{'ts'};
	my $lock = $data->{'lock'} || 'off';
	my $timestamp = $data->{'timestamp'};
	my ($bt, $temp_timestamp);
	# how many periods an "Nnext" window spans, zero for the other ts values
	my $reach = 0;
	# a caller can ask for a window that many periods wide instead of one,
	# keeping its far edge (the budget's multiplier)
	my $periods = $data->{'periods'} || 1;
	# Months and years are calendar periods: their length is whichever month is
	# being crossed, February included. The others keep the plain span below.
	my $widener = &subs::timespan_widener($scope) || '';
	my $calendar_unit = $widener =~ /^months?$/i ? 'month' : $widener =~ /^years?$/i ? 'year' : undef;
	my $scope_count = $scope;
	$scope_count =~ s/[^0-9.]//g;
	$scope_count = 1 unless length $scope_count;
	$scope_count += 0;

	# A window is only good for the timestamp it was built from: handing the
	# same one to a later request is what put January's month on screen just
	# after midnight on the first.
	if ($gb::father_time->{$scope}->{$ts}->{$lock}->{$periods}->{'timestamp'} == $timestamp &&
		$gb::father_time->{$scope}->{$ts}->{$lock}->{$periods}->{'st'} > $start_time - 10000) {
		$bt = $gb::father_time->{$scope}->{$ts}->{$lock}->{$periods}->{'bt'};
		$temp_timestamp = $gb::father_time->{$scope}->{$ts}->{$lock}->{$periods}->{'tt'};
		$gb::father_time->{$scope}->{$ts}->{$lock}->{$periods}->{'st'} = $start_time;
	}
	else {
		if ($ts eq 'this') {
			$temp_timestamp = $timestamp;
		}
		elsif ($ts =~ 'last') {
			if ($calendar_unit) {
				my $back = 1;
				$back = $1 if $ts =~ /^(\d+)/;
				$temp_timestamp = &subs::calendar_shift($timestamp, -$back * $scope_count, $calendar_unit);
			}
			else {
				$temp_timestamp = &subs::time_span($scope, $timestamp);
				if ($ts =~ /(^[0-9])/) {
					my $tas = $ts;
					$tas =~ s/last//gi;
					# the number itself: the words run out at forty, and the pages
					# of periods walk well past that
					$temp_timestamp = &subs::time_span($tas . $scope, $timestamp);
				}
			}
		}
		elsif ($ts =~ 'next') {
			if ($calendar_unit) {
				my $ahead = 1;
				if ($ts =~ /^(\d+)/) { $reach = $1 + 0; $ahead = $reach; }
				$temp_timestamp = &subs::calendar_shift($timestamp, $ahead * $scope_count, $calendar_unit);
			}
			else {
				# the span this scope is worth: "next" is the span after this one,
				# "Nnext" is the next N spans counting this one, so 2next in week is
				# this week plus next week
				my $span_bt = &subs::time_span($scope, $timestamp);
				my $span = $timestamp - $span_bt;
				$temp_timestamp = $span + $timestamp;
				if ($ts =~ /(^[0-9])/) {
					my $tas = $ts;
					$tas =~ s/next//gi;
					$reach = $tas + 0;
					$temp_timestamp = $timestamp + $span * $reach;
				}
			}
		}

		if ($lock eq 'on' && grep { &subs::timespan_widener($scope) =~ /\Q$_\E/i } qw/minute hour day week month year/) {
			# Locked windows are counted in whole periods off the one the request
			# is in: "last" is the period before this one, "2next" is this one and
			# the next, and the number in a scope such as "3day" widens them.  The
			# periods come off the calendar, since a day is not always 24 hours
			# long and millisecond steps drift across daylight saving.
			my $unit = lc $scope;
			$unit =~ s/[^a-zA-Z]//gi;
			my $multiplier = $scope;
			$multiplier =~ s/[^0-9.]//gi;
			$multiplier = 1 unless $multiplier;
			my $shift = 0;
			my $units = $multiplier;
			if ($ts =~ 'last') {
				$shift = -1;
				$shift = -$1 if $ts =~ /^(\d+)/;
			}
			elsif ($ts =~ 'next') {
				if ($ts =~ /^(\d+)/ && $1 > 1) { $units = $multiplier * $1 }
				else { $shift = 1 }
			}
			if ($periods > 1) {
				$shift -= ($periods - 1) * $units;
				$units *= $periods;
			}
			my $at = localtime($timestamp / 1000);
			# The local minute and second into the hour, taken off the instant, are
			# the same in both occurrences of the repeated hour when the clocks go
			# back; timelocal() cannot tell them apart and always resolves to the
			# first. Stepping back from the instant itself gives the second 01:00
			# its own hour, and the half-hour zones their own :30 start.
			my $base = int($timestamp);
			my $period_start = sub {
				my $offset = shift;
				if ($unit eq 'minute') {
					return $base - ($at->sec * 1000 + $base % 1000) + $offset * 60000;
				}
				if ($unit eq 'hour') {
					return $base - (($at->min * 60 + $at->sec) * 1000 + $base % 1000) + $offset * 3600000;
				}
				if ($unit eq 'year') {
					return timelocal(0, 0, 0, 1, 0, $at->year + $offset) * 1000;
				}
				if ($unit eq 'month') {
					my $index = $at->year * 12 + ($at->mon - 1) + $offset;
					return timelocal(0, 0, 0, 1, $index % 12, int($index / 12)) * 1000;
				}
				if ($unit eq 'week') {
					# weeks start on Sunday, so step off the Sunday of this week
					my $sunday = timegm(0, 0, 0, $at->mday, $at->mon - 1, $at->year) - $at->strftime('%w') * 86400;
					my @date = gmtime($sunday + 7 * $offset * 86400);
					return timelocal(0, 0, 0, $date[3], $date[4], $date[5]) * 1000;
				}
				my @date = gmtime(timegm(0, 0, 0, $at->mday, $at->mon - 1, $at->year) + $offset * 86400);
				return timelocal(0, 0, 0, $date[3], $date[4], $date[5]) * 1000;
			};
			$bt = $period_start->($shift);
			# A window that names periods ahead counts from the request: the part
			# of this period already spent is behind the row and belongs to "this",
			# not to the rows past it.  The far edge stays the period the name
			# counts to, and the unlocked windows already start here.
			$bt = $timestamp if ($ts =~ /next/ && $bt < $timestamp);
			$temp_timestamp = $period_start->($shift + $units);
		}
		else {
			if ($calendar_unit) {
				$bt = $reach > 1 ? $timestamp : &subs::calendar_shift($temp_timestamp, -$scope_count, $calendar_unit);
				$bt = &subs::calendar_shift($temp_timestamp, -$scope_count * $periods, $calendar_unit) if $periods > 1;
			}
			else {
				$bt = $reach > 1 ? $timestamp : &subs::time_span($scope, $temp_timestamp);
				$bt = $temp_timestamp - ($temp_timestamp - $bt) * $periods if $periods > 1;
			}
		}
	}

	$gb::father_time->{$scope}->{$ts}->{$lock}->{$periods} = { bt => $bt, tt => $temp_timestamp, st => $start_time, timestamp => $timestamp };

	return ($bt,$temp_timestamp);
}

sub measure_calc_for {
	my ($app, $measure, $fallback) = @_;
	my $calc = &subs::setting_grabber({ app => $app, setting => 'measure_calc', subsetting => $measure });
	$calc = $fallback unless (defined $calc && length $calc);
	return (defined $calc && length $calc) ? $calc : 'sum';
}

sub budget_calculator($data) {
	my $app = $data->{'app'};

	my $circumstance = $data->{'circumstance'};
	# A measure is any circumstance that is not one of the base budget modes,
	# worked out once with a key test that never autovivifies a measure into the
	# modes (which would make this very test, and later ones, read it wrong).
	my $is_measure = ( scalar grep { $_ eq $circumstance } keys %{$gb::budget_modes} ) == 0;
	my $value = $data->{'value'};
	my $scope = $data->{'scope'};
	# the window the reading is for: the caller says when it is one of the blocks
	# before or after now, so a pace is only read off the one now running
	my $ts = $data->{'ts'} || 'this';
	my $settings = $data->{'settings'} || &subs::settings_grabber({ app => $app });
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $returner = { app => $app, scope_name => &subs::timespan_widener($scope), value => $value };
	my $budget = $data->{'budget'};
	my $server_time = &subs::rightNow();
	$budget = $data->{'budget'} || &subs::setting_grabber({ 'app' => $app, setting => 'budget' }) unless $data->{'budget'} =~ /[0-9]/gi;
	my @budgets = split ',', $budget;
	foreach my $b ( @budgets ) {
		$returner->{'app'} = $app;
		$returner->{'budget'} = $b;
		# A leading "<=" or ">=" says which way the goal runs: under is good (a
		# ceiling, like a weight to hold at or below) or over is good (a floor, like
		# steps to reach). Nothing, and a bare number, is a floor.
		my $direction = 'floor';
		if ($b =~ s/^<=//) { $direction = 'ceiling'; }
		elsif ($b =~ s/^>=//) { $direction = 'floor'; }
		$returner->{'direction'} = $direction;
		my @bud = split '/', $b;
		next unless $bud[-1];
		# No "/scope" is a fixed level, not a rate: a weight sits at a target, it
		# does not accumulate, so it is read against the column's own window and is
		# never prorated (the pace is what made a 160 lb budget project 756 lb).
		my $fixed = scalar(@bud) == 1 ? 1 : 0;
		$returner->{'fixed'} = $fixed;
		if ($fixed) {
			# A fixed entry ("180weight") has no "/scope"; the only scope it can
			# honour is the caller's, and only when it names a time span. The old
			# test accepted any number+letters, so `180weight` became the window
			# `weight`; timespan_widener then stripped the digits and father_time
			# asked time_span for 'weight', which dies and killed every pull after
			# its merge.
			my $window = 'month';
			if ($scope && $scope =~ /^[0-9]*[a-zA-Z]+$/ && &subs::time_span_length($scope)) {
				$window = $scope;
			}
			$window = 1 . $window unless $window =~ /^[0-9]/;
			$returner->{'scope_name'} = &subs::timespan_widener($window);
			$returner->{'duration'} = &subs::time_abbrev_translator($window, $server_time);
			$returner->{'scope'} = $returner->{'duration'};
		}
		else {
			$bud[-1] = 1 . $bud[-1] unless $bud[-1] =~ /[0-9]/;
			# time_span_length knows the word spans; an abbreviated scope ("1w",
			# "3d", "1M") is widened to its word with its count kept first, so a
			# weekly budget is not silently read as a month. A scope that still
			# does not resolve must not reach time_span either.
			unless (&subs::time_span_length($bud[-1])) {
				my $count = $bud[-1];
				$count =~ s/[^0-9]//g;
				$count = 1 unless length $count;
				my $widened = $count . &subs::timespan_widener($bud[-1]);
				$bud[-1] = &subs::time_span_length($widened) ? $widened : '1month';
			}
			$returner->{'scope_name'} = &subs::timespan_widener($bud[-1]);
			$returner->{'duration'} = &subs::time_abbrev_translator($bud[-1],&subs::rightNow());
			# The scope is the column the caller read, not the budget's own period:
			# the value handed in is that column's total, so the target and the actual
			# are held per millisecond of that column. A bare word ("week") needs its
			# count before the translator sees it.
			my $caller_span = $scope ? (($scope =~ /[0-9]/) ? $scope : 1 . $scope) : '';
			unless ($scope) {
				$returner->{'scope'} = $returner->{'duration'} ;
			}
			else {
				$returner->{'scope'} = &subs::time_abbrev_translator($caller_span, &subs::rightNow()) || $returner->{'duration'};
			}
		}
		# A fixed quantity budget is a level to keep on hand, not a rate of the
		# appointment stream (the scoped form reads that stream): read the warehouse's
		# signed stock for the item, so its light says whether the shelf holds what it
		# should.
		my $handled;
		if ($circumstance eq 'quantity' && $fixed) {
			$value = &subs::warehouse_on_hand($app, $settings);
			$returner->{'value'} = $value;
			$handled = 1;
		}
		unless ($value || $handled) {
			my ($db) = &subs::database_grabber();
			my $appts = $data->{'appts'};
			# A duration is read over the budget's own window even when the caller
			# passed the appointments, so a session that crossed the window's edge
			# offers only the time spent inside it.
			my ($window_bt, $window_end);
			if (!$appts || $circumstance eq 'duration') {
				my $ft_data = {
					scope => $returner->{'scope_name'},
					ts => 'this',
					lock => $settings->{'s_lock'},
					timestamp => $timestamp
				};
				($window_bt, $window_end) = &father_time($ft_data);
			}
			unless ($appts) {
				my @params = ( $app, $window_end );
				my $query = 'select * from appointments where app = ? and timestamp < ? ';
				if ($circumstance eq 'duration') {
					# a session overlaps this window when it starts before the window
					# ends and stops after it begins; a running session has no stored
					# duration, so it is read to now and always overlaps a past window.
					# The ends-at test is a number against the window bound: the bound
					# must be cast, or DBD::SQLite binds it as text and SQLite ranks a
					# number below text, so every session that began before the window
					# and ran into it was dropped.
					$query .= "and (timestamp >= ? or type in ('start','record') or (cast(timestamp as integer) + abs(cast(coalesce(duration,0) as real))) > cast(? as integer)) ";
					push @params, $window_bt, $window_bt;
				}
				else {
					$query .= 'and timestamp >= ? ';
					push @params, $window_bt;
				}

				if ($settings->{'s_movement'}) {
					my $bail = 0;
					unless ($settings->{'sss_movement'}) {
						$settings->{'sss_movement'} = eval { return decode_json $settings->{'s_movement'} } || [];
					}
					$bail = 1 if grep { $_ eq 'all' } @{$settings->{'sss_movement'}};
					if ($bail == 0) {
						if (scalar @{$settings->{'sss_movement'}} > 0 ) { $query .= 'and ( '; }
						my $first_movement = 1;
						foreach my $sm ( @{$settings->{'sss_movement'}} ) {
							$query .= $first_movement ? 'type = ? ' : ' or type = ? ';
							$first_movement = 0;
							push @params, $sm;
						}
						if (scalar @{$settings->{'sss_movement'}} > 0 ) { $query .= ' ) '; }
					}
				}
				$query .= ' order by timestamp DESC';
				$appts = &subs::db_query($query, @params)->hashes;
				# a duration list is not reused for the next budget entry, since that
				# entry may name a different window; a caller's own list is left alone
				$data->{'appts'} = $appts unless $circumstance eq 'duration';
			}

			my ($m_sum, $m_count) = (0, 0);
			foreach my $appt ( @{$appts} ) {
				if ($circumstance eq 'duration') {
					if ($appt->{'type'} eq 'start' || $appt->{'type'} eq 'record') {
						$appt->{'duration'} = $server_time - $appt->{'timestamp'};
					}
					my $spent = abs($appt->{'duration'} || 0);
					if (defined $window_bt && defined $window_end) {
						$spent = &appointment_overlap($appt, $window_bt, $window_end);
					}
					$value += $spent;
				}
				elsif ($circumstance eq 'occurences') {
					$value += 1;
				}
				elsif ($circumstance eq 'total') {
					# the block above is only entered when no value was passed in, so
					# there is nothing to guard against here: starting from zero, every
					# row's total is added, the way the display reads the column
					$value += abs( $appt->{'total'} || 0 );
				}
				elsif ($circumstance eq 'quantity') {
					# the stream the app's movement filter names - beer's poured amount,
					# not its purchases - read as a magnitude, the way a total budget
					# reads the money
					$value += abs( $appt->{'quantity'} || 0 );
				}
				else {
					# a measure: sum, or average, it across the window's appointments -
					# the measure decides (steps summed, weight averaged), so its
					# budget reads right whatever the display is showing.
					next unless $appt->{'measures'};
					unless ($appt->{'measured'}) {
						$appt->{'measures'} = eval { return decode_json $appt->{'measures'} } || [];
						$appt->{'measured'} = 'yes';
					}
					foreach my $m ( @{$appt->{'measures'}} ) {
						next unless defined $m->{$circumstance};
						$m_sum += $m->{$circumstance};
						$m_count++;
					}
				}
			}
			# a measure is not a base mode: its value is the summed or averaged
			# measure, per the measure's own calc
			if ($is_measure) {
				# a fixed level (no scope) is a level, so it reads as an average whatever
				# the measure's own calc is; a rate reads with the measure's calc
				my $mcalc = $fixed ? 'average' : &measure_calc_for($app, $circumstance, $settings->{'s_calc'});
				$value = ( $mcalc eq 'average' && $m_count ) ? ($m_sum / $m_count) : $m_sum;
			}
			$value = 0 if scalar @{$appts} == 0;
			$returner->{'value'} = $value;
		}
		if ($bud[0] =~ /^\$/gi) {
			my $bu = $bud[0];
			$bu =~ s/\$//gi;
			$returner->{'budgets'}->{'total'} = $b;
			if ($circumstance eq 'total') {
				$returner->{'circumstance'} = 'total';
				$returner->{'budgeted'} = abs $bu;
				$returner->{'formatted_value'} = abs $value;
				last;
			}
		}
		elsif ($bud[0] =~ /[a-zA-Z]/gi) {

			if ($circumstance eq 'duration') {
				$returner->{'budgets'}->{'duration'} = $b;
				$returner->{'circumstance'} = 'duration';
				$bud[0] = 1 . $bud[0] unless $bud[0] =~ /[0-9]/;
				$returner->{'budgeted'} = &subs::time_abbrev_translator($bud[0],&subs::rightNow());
				if ($value != 0) {
					$returner->{'formatted_value'} = &subs::duration_sayer($value / 1000);
				}
				else {
					$returner->{'formatted_value'} = 0;
				}
				last;
			}
			elsif ($is_measure) {
				$returner->{'budget_name'} = $bud[0];
				$returner->{'budget_name'} =~ s/[0-9.]//gi;
				next unless $returner->{'budget_name'} eq $circumstance;
				$returner->{'budgeted'} = $bud[0];
				$returner->{'budgets'}->{$circumstance} = $b;
				$returner->{'circumstance'} = $circumstance;

				$returner->{'budgeted'} =~ s/[^0-9.]//gi;
				$returner->{'formatted_value'} = sprintf("%.3f", $value) . $circumstance;
				last;
			}
			elsif ($circumstance eq 'quantity') {
				# a quantity budget names itself the way a measure does
				# ("3.400quantity/week"), so a bare number stays an occurences budget
				my $quantity_name = $bud[0];
				$quantity_name =~ s/[^a-zA-Z]//gi;
				next unless $quantity_name eq 'quantity';
				$returner->{'budgets'}->{'quantity'} = $b;
				$returner->{'circumstance'} = 'quantity';
				$returner->{'budgeted'} = $bud[0];
				$returner->{'budgeted'} =~ s/[^0-9.]//gi;
				$returner->{'formatted_value'} = sprintf("%.3f", $value) . $circumstance;
				last;
			}
		}
		else {
			$returner->{'budgets'}->{'occurences'} = $b;

			if ($circumstance eq 'occurences') {
				$returner->{'circumstance'} = 'occurences';
				$returner->{'budgeted'} = $bud[0];
				$returner->{'formatted_value'} = abs $value;
				last;
			}
		}
	}

	if ($returner->{'budget'} && $returner->{'budgeted'}) {
		my $nominal_scope = $returner->{'scope'};
		my $same_width = ($returner->{'duration'} eq $nominal_scope) ? 1 : 0;
		# A locked day or week can be 25 hours or 169 hours long when the clocks
		# change. The value is already read over the real window; the rate is per
		# the nominal period, so the target for this column is that rate times the
		# real window. Only a duration: a count, a sum or a measure is not a rate of
		# time and must not grow with an hour the clock gained.
		my $actual_scope;
		if ($circumstance eq 'duration' && !$returner->{'fixed'} && ($settings->{'s_lock'} || '') eq 'on') {
			my $caller_scope = $scope || $returner->{'scope_name'};
			my $unit = &subs::timespan_widener($caller_scope) || '';
			if ($unit eq 'day' || $unit eq 'week') {
				my ($cb, $ce) = &father_time({
					scope => $caller_scope,
					ts => $ts,
					lock => $settings->{'s_lock'},
					timestamp => $timestamp
				});
				$actual_scope = $ce - $cb if defined $ce && defined $cb && $ce > $cb;
			}
		}
		if ($same_width && $returner->{'circumstance'} eq $circumstance) {
			$returner->{'is_scope'} = 'yes';
		}

		$returner->{'expected'} = sprintf("%.19f",$returner->{'budgeted'} / $returner->{'duration'});
		if ($circumstance eq 'duration') {
			# the own period wears the real window; another column keeps the nominal
			# rate as its label, while its threshold below is scaled to the column
			my $display_span = $same_width ? ($actual_scope || $returner->{'duration'}) : $returner->{'duration'};
			$returner->{'budgeted_display_ms'} = $returner->{'expected'} * $display_span;
			$returner->{'formatted_budgeted'} = &subs::duration_sayer($returner->{'expected'} * $display_span / 1000) . '/' . $returner->{'scope_name'};
		}
		else {
			$returner->{'formatted_budgeted'} = sprintf("%.3f", $returner->{'expected'} * $returner->{'scope'}) . ($is_measure ? $circumstance : '') . '/' . $returner->{'scope_name'};
		}
		if ($actual_scope) { $returner->{'scope'} = $actual_scope; }
		$returner->{'actual'} = sprintf("%.19f", $returner->{'value'} / $returner->{'scope'});
		$returner->{'threshold'} = $returner->{'expected'} * $returner->{'scope'};
		$returner->{'eval'} = $returner->{'actual'} - $returner->{'expected'};
		$returner->{'timestamp'} = $timestamp;
		if ($scope && !$returner->{'fixed'} && !$same_width && $returner->{'circumstance'} eq $circumstance) {
			# The caller read a column of another width. The reading is still held
			# against that column - the expected and the actual are rates per
			# millisecond, so they compare across windows - but it is not the
			# budget's own period, so the panel must not cache it as one.
			$returner->{'is_scope'} = 'no';
		}
		# A budget locked to the calendar is read against a period still running:
		# on Monday a week holds a seventh of its value, so holding that part against
		# the whole week's target would call an on-pace start a collapse and leave
		# nothing meaningful to read until the week is done. The pace is read
		# instead - the part of the period the moment stands at - and the target is
		# prorated by that same part, so being on track means the value has reached
		# its share of the period so far, and the projection carries the pace to the
		# period's end. An unlocked window rolls a whole period back from now, so it
		# is already run and its pace is 1, as is any block before or after now.
		# Every column is read this way, not only the one the budget is set to: a
		# weekly budget graphed over the month is still a part-run month, and its
		# column reads the same way (the target was scaled to the column above).
		#
		# The first stretch of a period carries no target, since so little is due that
		# a single blip reads as far ahead of pace, and that stretch is often spent
		# asleep or otherwise away from it. The budget is spread over what is left: a
		# day's first two fifths are the night (so its target only starts around nine
		# in the morning), an hour's first quarter, and the longer clocks their first
		# tenth. The projection keeps the exact elapsed, so it still reads the whole
		# period rather than only the part not slept through.
		my %pace_floor = ( hour => 0.25, day => 0.4, week => 0.1, month => 0.1, year => 0.1 );
		my $unit = $scope ? &subs::timespan_widener($scope) : $returner->{'scope_name'};
		my $elapsed = 1;
		if ($ts eq 'this' && ($settings->{'s_lock'} || '') eq 'on' && $unit =~ /^(?:hour|day|week|month|year)$/) {
			(undef, undef, $elapsed) = &subs::period_bounds($unit, $timestamp);
		}
		# a fixed level is not a period being run: it is not prorated, and its pace
		# is not carried anywhere
		$elapsed = 1 if $returner->{'fixed'};
		my $floor = $pace_floor{$unit} // 0.1;
		my $early = ($elapsed > 0 && $elapsed <= $floor) ? 1 : 0;
		my $pace_elapsed = $early ? 0 : (($elapsed - $floor) / (1 - $floor));
		$pace_elapsed = 0 if $pace_elapsed < 0;
		$pace_elapsed = 1 if $pace_elapsed > 1;
		# the whole target the column's value is held against - already scaled to the
		# column's own period when the budget is set to a different one
		my $full_target = $returner->{'expected'} * $returner->{'scope'};
		$returner->{'elapsed'} = $elapsed;
		$returner->{'early'} = $early;
		$returner->{'pace_floor'} = $floor;
		$returner->{'progress'} = sprintf('%.0f', $elapsed * 100);
		$returner->{'on_target'} = sprintf('%.19f', $full_target * $pace_elapsed);
		$returner->{'on_track'} = ($returner->{'value'} >= $returner->{'on_target'}) ? 'yes' : 'no';
		$returner->{'projected'} = $elapsed > 0 ? sprintf('%.19f', $returner->{'value'} / $elapsed) : $returner->{'value'};
		my $pace_format = sub {
			my $n = shift;
			return '-' unless defined $n;
			return &subs::duration_sayer($n / 1000) if $circumstance eq 'duration';
			return &subs::price_formatter($n) if $circumstance eq 'total';
			return sprintf('%.1f', $n);
		};
		$returner->{'formatted_projected'} = $pace_format->($returner->{'projected'});
		$returner->{'formatted_on_target'} = $early ? '0' : $pace_format->($returner->{'on_target'});
		# The status and the graph line are held against the share of the target due
		# by now, not the whole of it, so an on-pace start reads as on pace rather
		# than a collapse; formatted_budgeted still names the whole period.
		$returner->{'full_expected'} = $returner->{'expected'};
		$returner->{'threshold'} = $full_target * $pace_elapsed;
		if ($early) {
			$returner->{'expected'} = 0;
		}
		elsif ($elapsed > 0 && $elapsed < 1 && $returner->{'expected'} > 0) {
			$returner->{'expected'} = sprintf('%.19f', $returner->{'expected'} * $pace_elapsed);
		}
		$returner->{'eval'} = $returner->{'actual'} - $returner->{'expected'};
		$returner = &budget_status_maker($returner);
		# A ceiling reads the mirror of the floor the status table is written for:
		# at or under the target is settled, over it is the alarm. Re-read the status
		# from the value against the target, not from the ratio.
		if (($returner->{'direction'} || 'floor') eq 'ceiling') {
			# a duration target wears the same real-window widening as a floor
			my $target = ($circumstance eq 'duration' && defined $returner->{'full_expected'} && defined $returner->{'scope'})
				? $returner->{'full_expected'} * $returner->{'scope'}
				: ($returner->{'budgeted'} || 0);
			my $value = $returner->{'value'} || 0;
			# a hair of float noise either side of the target is still the target
			my $epsilon = $target * .0000000001;
			$returner->{'on_track'} = ($value <= $target + $epsilon) ? 'yes' : 'no';
			my $ceiling = 'budgeted';
			if ($target > 0 && $value > $target * 1.2) { $ceiling = 'overkill'; }
			elsif ($target > 0 && $value > $target + $epsilon) { $ceiling = 'burnt_out'; }
			# landing exactly on the target spends the whole allowance without
			# passing it - an accomplishment, not merely within budget
			elsif ($target > 0 && $value >= $target - $epsilon) { $ceiling = 'accomplished'; }
			$returner = &{$gb::budget_statuses->{$ceiling}->{'notifier'}}($returner);
		}
	}
	else {
	#	$returner = {};
	}
	return $returner;
}

sub budget_status_maker($returner) {
	# a target of nothing - a period only just opened, or a budget of zero - has
	# nothing to fall behind: the value is read as on track, rather than the
	# ratio's 0 >= 0 landing on "overkill"
	if (!defined $returner->{'expected'} || $returner->{'expected'} <= 0) {
		return &{$gb::budget_statuses->{'budgeted'}->{'notifier'}}($returner);
	}
	my $status;
	if ($returner->{'actual'} < $returner->{'expected'} - ( $returner->{'expected'} * .0000000001) && $returner->{'actual'} >= $returner->{'expected'} - ($returner->{'expected'} * .2)) {
		$status = 'budgeted';
		$returner->{'synth'} = 'play -v .3 "| sox -n -p synth .51 sine 391 && play | sox -n -p synth .51 triangle 500"';
	}
	elsif ($returner->{'actual'} >= $returner->{'expected'} * 2) {
		$status = 'overkill';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .51 pinknoise 1125 && play | sox -n -p synth .51 whitenoise 100"';
	}
	elsif ($returner->{'actual'} >= $returner->{'expected'} * 1.2) {
		$status = 'burnt_out';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .51 square 125 && play | sox -n -p synth .51 square 100"';
	}
	elsif ($returner->{'actual'} >= $returner->{'expected'}) {
		$status = 'accomplished';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .26 pluck 329.64 && play | sox -n -p synth .26 pluck 391.99 && play | sox -n -p synth .26 pluck 369.99 && play | sox -n -p synth .26 pluck 293.672"';
	}
	elsif ($returner->{'actual'} <= $returner->{'expected'} / 4) {
		$status = 'abandoned';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .51 triangle 261.64 && play | sox -n -p synth .51 triangle 261.64"';
	}
	elsif ($returner->{'actual'} <= $returner->{'expected'} / 2) {
		$status = 'neglected';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .26 saw 349.23 && play | sox -n -p synth .26 saw 329.63 && play | sox -n -p synth .26 saw 415.3 && play | sox -n -p synth .26 saw 439.99"';
	}
	elsif ($returner->{'actual'} <= $returner->{'expected'}) {
		$status = 'achievable';
		$returner->{'synth'} = 'play -v .15 "| sox -n -p synth .26 pluck 293.67 && play | sox -n -p synth .26 pluck 349.23 && play | sox -n -p synth .26 pluck 349.23 && play | sox -n -p synth .26 pluck 311.13"';
	}
	$returner = &{$gb::budget_statuses->{$status}->{'notifier'}}($returner);

	return $returner;
}

sub people_index {
	my $rows = eval {
		&subs::db_query("select app, device, setting, value, server_time from settings where setting in ('pos','mab','uuid','house_uuid','house_name','house_pubkey','peer_name','peer_construct','peer_profile','web','crest_uuid') or substr(setting,1,3) = 'sc_'")->hashes;
	} || [];
	my $current = &subs::device_setter();
	my %apps;
	my %uuid_app;
	my %effective;
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'} // '';
		next unless length $app;
		my $setting = $row->{'setting'} // '';
		$apps{$app} ||= { app => $app, uuids => {}, sc => {}, pos => '', mab => '', house_uuid => '', house_name => '', peer_name => '', web => '', crest_uuid => '' };
		if ($setting eq 'uuid') {
			my $uuid = $row->{'value'} // '';
			next unless length $uuid;
			$apps{$app}->{'uuids'}->{$uuid} = 1;
			$apps{$app}->{'uuid_rows'}->{$uuid} = {
				device => $row->{'device'} // '',
				server_time => $row->{'server_time'} // '',
			};
			$uuid_app{$uuid} = $app;
		}
		elsif ($setting eq 'pos' || $setting eq 'mab') {
			# a device keeps its own copy of a construct; the newest row on a
			# device is that device's answer, and the current device answers
			# for the whole app when it has one
			my $device = $row->{'device'} // '';
			my $stamp = $row->{'server_time'} // '';
			my $slot = $effective{$app}->{$setting}->{$device};
			unless ($slot && $slot->{'server_time'} gt $stamp) {
				$effective{$app}->{$setting}->{$device} = { value => $row->{'value'} // '', server_time => $stamp };
			}
		}
		elsif ($setting eq 'house_uuid' || $setting eq 'house_name' || $setting eq 'peer_name' || $setting eq 'web' || $setting eq 'crest_uuid') {
			# provenance of an imported construct; a local construct has none
			$apps{$app}->{$setting} = $row->{'value'} // '';
		}
		elsif ($setting =~ /^sc_(.+)$/) {
			my $sing = $1;
			my $list = eval { decode_json($row->{'value'} // '') } || [];
			next unless ref $list eq 'ARRAY';
			foreach my $uuid ( @{$list} ) {
				next unless defined $uuid && length $uuid;
				$apps{$app}->{'sc'}->{$sing}->{$uuid} = 1;
			}
		}
	}
	foreach my $app ( keys %apps ) {
		foreach my $setting ( qw/pos mab/ ) {
			my $devices = $effective{$app}->{$setting} || {};
			my $pick = $devices->{$current};
			unless ($pick) {
				foreach my $device ( keys %{$devices} ) {
					my $candidate = $devices->{$device};
					$pick = $candidate if !$pick || $candidate->{'server_time'} gt $pick->{'server_time'};
				}
			}
			$apps{$app}->{$setting} = $pick ? $pick->{'value'} : '';
		}
		# the row this machine writes to: its own device's copy when there is
		# one, otherwise the newest copy another machine made
		my $preferred = '';
		my $newest = '';
		my $newest_stamp = '';
		foreach my $uuid ( keys %{ $apps{$app}->{'uuid_rows'} || {} } ) {
			my $entry = $apps{$app}->{'uuid_rows'}->{$uuid};
			if (($entry->{'device'} || '') eq $current) { $preferred = $uuid; last; }
			if (!$newest || ($entry->{'server_time'} || '') gt $newest_stamp) {
				$newest = $uuid;
				$newest_stamp = $entry->{'server_time'} || '';
			}
		}
		$apps{$app}->{'preferred_uuid'} = $preferred || $newest || '';
	}
	# a membership array names the uuid of the construct's settings row, so
	# the reverse map is what turns "these uuids" into "these construct apps"
	my %member;
	foreach my $app ( keys %apps ) {
		my $sc = $apps{$app}->{'sc'} || {};
		foreach my $sing ( keys %{$sc} ) {
			foreach my $uuid ( keys %{$sc->{$sing}} ) {
				my $construct_app = $uuid_app{$uuid};
				next unless defined $construct_app;
				$member{$sing}->{$construct_app}->{$app} = 1;
			}
		}
	}
	my @person_apps = sort grep {
		my $entry = $apps{$_};
		(($entry->{'pos'} || '') eq 'person' || ($entry->{'mab'} || '') eq 'person') ? 1 : 0;
	} keys %apps;
	my @constructs;
	foreach my $scons ( sort { $a->{'order'} <=> $b->{'order'} } values %{$gb::social_constructs} ) {
		next if $scons->{'name'} eq 'people';
		my $sing = $scons->{'sing'};
		my @rows;
		foreach my $app ( keys %apps ) {
			my $entry = $apps{$app};
			next unless (($entry->{'pos'} || '') eq $sing || ($entry->{'mab'} || '') eq $sing);
			my @members;
			foreach my $member_app ( keys %{ $member{$sing}->{$app} || {} } ) {
				push @members, { app => $member_app, name => &subs::format_name($member_app) };
			}
			@members = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @members;
			push @rows, {
				app => $app,
				name => $entry->{'peer_name'} || &subs::format_name($app),
				foreign => ($entry->{'house_uuid'} || '') ne '' ? 1 : 0,
				house_uuid => $entry->{'house_uuid'} || '',
				house_name => $entry->{'house_name'} || '',
				web => $entry->{'web'} || '',
				crest_uuid => $entry->{'crest_uuid'} || '',
				member_count => scalar @members,
				members => \@members,
			};
		}
		@rows = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @rows;
		push @constructs, { name => $scons->{'name'}, sing => $sing, rows => \@rows };
	}
	return {
		apps => \%apps,
		uuid_app => \%uuid_app,
		member => \%member,
		person_apps => \@person_apps,
		constructs => \@constructs,
	};
}

sub people_chips {
	my ($index, $app) = @_;
	my $entry = $index->{'apps'}->{$app} || {};
	my $sc = $entry->{'sc'} || {};
	my @chips;
	foreach my $scons ( sort { $a->{'order'} <=> $b->{'order'} } values %{$gb::social_constructs} ) {
		my $sing = $scons->{'sing'};
		next unless $sc->{$sing};
		my %seen;
		my @names;
		foreach my $uuid ( keys %{ $sc->{$sing} } ) {
			my $construct_app = $index->{'uuid_app'}->{$uuid} || '';
			next unless length $construct_app;
			next if $seen{$construct_app}++;
			push @names, { app => $construct_app, name => &subs::format_name($construct_app) };
		}
		foreach my $name ( sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @names ) {
			push @chips, {
				construct => $scons->{'name'},
				sing => $sing,
				label => &subs::lang('construct.' . $scons->{'name'}),
				app => $name->{'app'},
				name => $name->{'name'},
			};
		}
	}
	return \@chips;
}

sub help_app_hidden($app) {
	return 0 unless defined $app && length $app;
	return &subs::app_hidden_now($app) ? 1 : 0;
}

sub guide_name_normalize {
	my ($text) = @_;
	my $s = lc(defined $text ? $text : '');
	$s =~ s/[^\p{L}\p{N}]+/ /g;
	$s =~ s/^\s+|\s+$//g;
	$s =~ s/^(?:the|my|a|an)\s+//;
	$s =~ s/\s+//g;
	return $s;
}

sub guide_name_distance {
	my ($a, $b) = @_;
	return 0 if $a eq $b;
	return length($a) if !length($b);
	return length($b) if !length($a);
	my @prev = (0 .. length($b));
	for my $i ( 1 .. length($a) ) {
		my @cur = ($i);
		my $ca = substr($a, $i - 1, 1);
		for my $j ( 1 .. length($b) ) {
			my $cost = $ca eq substr($b, $j - 1, 1) ? 0 : 1;
			my $v = $prev[$j] + 1;
			$v = $cur[$j - 1] + 1 if $cur[$j - 1] + 1 < $v;
			$v = $prev[$j - 1] + $cost if $prev[$j - 1] + $cost < $v;
			push @cur, $v;
		}
		@prev = @cur;
	}
	return $prev[-1];
}

sub guide_target_label {
	my ($cand) = @_;
	return '' unless ref $cand eq 'HASH';
	my $name = $cand->{'name'} || $cand->{'app'} || '';
	my $kind = $cand->{'kind'} || 'app';
	my $label = $kind eq 'app' ? 'app' : $kind;
	$label = $cand->{'construct'} if ($kind ne 'person' && ($cand->{'construct'} || '') ne '');
	# an imported construct says whose it is, so two Gardens in different houses
	# are told apart in the question rather than by an opaque local key
	$label .= ' from ' . $cand->{'house_name'} if $cand->{'foreign'} && ($cand->{'house_name'} || '') ne '';
	if ($cand->{'memberships'} && @{ $cand->{'memberships'} }) {
		return $name . ' (' . $label . ': ' . join(', ', @{ $cand->{'memberships'} }) . ')';
	}
	return $name . ' (' . $label . ')';
}

sub guide_aliases_read {
	my $raw = eval { &subs::setting_grabber({ app => '__president', setting => 'aliases', device => 'all' }) } || '';
	my $map = eval { decode_json($raw) } || {};
	return ref $map eq 'HASH' ? $map : {};
}

sub guide_aliases_write {
	my ($map) = @_;
	return 0 unless ref $map eq 'HASH';
	&subs::setting_setter({ app => '__president', setting => 'aliases', device => 'all', value => encode_json($map) });
	return 1;
}

sub guide_aka_read {
	my $rows = eval { &subs::db_query("select app, value from settings where setting='aka'")->hashes } || [];
	my %map;
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'} || '';
		next unless length $app;
		foreach my $token ( split /,/, ($row->{'value'} || '') ) {
			$token =~ s/^\s+|\s+$//g;
			next unless length $token;
			push @{ $map{$app} }, $token;
		}
	}
	return \%map;
}

sub guide_alias_add {
	my ($alias, $target, $app_key) = @_;
	my $key = &guide_name_normalize($alias);
	return { ok => 0, text => 'That alias is too short.' } unless length $key && length($key) >= 2;
	my $t;
	if (defined $app_key && length $app_key) {
		# the People window names a construct by its key, so nothing is resolved: a
		# name that is ambiguous today cannot make the alias land on the wrong one
		$app_key = &subs::unformat_name($app_key);
		my $index = &people_index();
		my $entry = $index->{'apps'}->{$app_key};
		return { ok => 0, text => 'No such construct.' } unless $entry;
		return { ok => 0, text => 'Another house keeps that construct; its names are theirs.' }
			if ($entry->{'house_uuid'} || '') ne '';
		$t = {
			kind => ($entry->{'pos'} || $entry->{'mab'} || 'app'),
			app => $app_key,
			uuid => &subs::construct_uuid($app_key),
			name => &subs::format_name($app_key),
		};
	}
	else {
		my $r = &guide_resolve_target($target, kind => '');
		unless ($r->{'ok'}) {
			return { ok => 0, text => &guide_ask_candidates($target, $r->{'candidates'} || [])->{'text'} };
		}
		$t = $r->{'target'};
	}
	my $app = $t->{'app'} || '';
	# A word another thing already answers to exactly is not an alias, it is a
	# collision: exact wins over everything, so teaching it would silently take
	# the word away. A prefix or fuzzy near-miss is not a collision - an alias is
	# an exact answer, and the person is deliberately choosing it over the guess.
	my $clash = &guide_resolve_target($alias, kind => '');
	my @clash;
	if ($clash->{'ok'} && ($clash->{'target'}->{'score'} || 0) >= 100) {
		@clash = ($clash->{'target'}) if ($clash->{'target'}->{'app'} || '') ne $app;
	}
	elsif (($clash->{'reason'} || '') eq 'ambiguous') {
		@clash = grep { ($_->{'score'} || 0) >= 100 && ($_->{'app'} || '') ne $app } @{ $clash->{'candidates'} || [] };
	}
	if (@clash) {
		my @labels = map { &guide_target_label($_) } @clash;
		@labels = @labels[0 .. 3] if scalar @labels > 4;
		return { ok => 0, text => '"' . $alias . '" already means ' . join('; ', @labels) . '.' };
	}
	if (length $app && ($t->{'kind'} || '') ne 'machine' && ($t->{'kind'} || '') ne 'house') {
		# An app or person: the aka row lives on the target itself, where the
		# existing aka convention and setting_initializer already look for it.
		my $aka = &guide_aka_read();
		my @tokens = @{ $aka->{$app} || [] };
		push @tokens, $alias unless grep { &guide_name_normalize($_) eq $key } @tokens;
		# one row per app, not one per device: old copies would otherwise keep
		# winning a removal from another machine
		&subs::db_query('delete from settings where app=? and setting=?', $app, 'aka');
		&subs::setting_setter({ app => $app, setting => 'aka', device => 'all', value => join(',', @tokens) });
		# do not leave a second copy in the map
		my $map = &guide_aliases_read();
		if (exists $map->{$key}) { delete $map->{$key}; &guide_aliases_write($map); }
	}
	else {
		my $map = &guide_aliases_read();
		$map->{$key} = {
			kind => $t->{'kind'} || 'app',
			app => $app,
			uuid => $t->{'uuid'} || '',
			name => $t->{'name'} || $app,
			construct => $t->{'construct'} || '',
			at => &subs::rightNow(),
		};
		&guide_aliases_write($map);
	}
	return { ok => 1, text => 'Remembered "' . $alias . '" for ' . ($t->{'name'} || $app) . '.', target => $t };
}

sub guide_alias_remove {
	my ($alias, $app_key) = @_;
	my $key = &guide_name_normalize($alias);
	return { ok => 0, text => 'No alias named.' } unless length $key;
	my $found = 0;
	# the People window removes a chip from one construct's row: only that row is
	# touched, so the same word on another construct survives
	my $only = (defined $app_key && length $app_key) ? &subs::unformat_name($app_key) : '';
	my $aka = &guide_aka_read();
	foreach my $app ( keys %{$aka} ) {
		next if length $only && $app ne $only;
		my @tokens = @{ $aka->{$app} || [] };
		my @keep = grep { &guide_name_normalize($_) ne $key } @tokens;
		next if scalar @keep == scalar @tokens;
		$found = 1;
		&subs::db_query('delete from settings where app=? and setting=?', $app, 'aka');
		&subs::setting_setter({ app => $app, setting => 'aka', device => 'all', value => join(',', @keep) }) if @keep;
	}
	my $map = &guide_aliases_read();
	if (exists $map->{$key} && (!length $only || ($map->{$key}->{'app'} || '') eq $only)) {
		delete $map->{$key};
		&guide_aliases_write($map);
		$found = 1;
	}
	return { ok => 0, text => 'I did not know "' . $alias . '".' } unless $found;
	return { ok => 1, text => 'Forgot "' . $alias . '".' };
}

sub guide_resolve_target {
	my ($text, %opts) = @_;
	$text = '' unless defined $text;
	# A qualifier narrows the kind before matching: app:music, person:john,
	# club:garden (a construct singular), machine:table, house:maple.
	my $want = $opts{'kind'} || '';
	my $filter_sing = '';
	if ($text =~ /^\s*([A-Za-z_]+)\s*:\s*(.+)$/s) {
		my $prefix = lc $1;
		my $rest = $2;
		my %kinds = (app => 'app', person => 'person', construct => 'construct', machine => 'machine', house => 'house');
		if ($kinds{$prefix}) {
			$want = $kinds{$prefix};
			$text = $rest;
		}
		else {
			foreach my $sc ( values %{$gb::social_constructs} ) {
				next unless lc($sc->{'sing'}) eq $prefix || lc($sc->{'name'}) eq $prefix;
				$want = 'construct';
				$filter_sing = $sc->{'sing'};
				$text = $rest;
				last;
			}
		}
	}
	# A house narrows the name to that house's constructs: maple/john. It is the
	# spoken form of a qualifier, so it is read before the name is normalized.
	my $house_filter = '';
	if ($text =~ m{^\s*([^/]+?)\s*/\s*(.+)$}s) {
		$house_filter = &guide_name_normalize($1);
		$text = $2;
	}
	# A short id pins the exact thing: john#7f3a.
	my $id_prefix = '';
	if ($text =~ s/#([A-Za-z0-9]{3,})\s*$//) { $id_prefix = $1; }
	my $query = &guide_name_normalize($text);
	return { ok => 0, reason => 'nothing named', candidates => [] } unless length $query;
	my $alias_map = &guide_aliases_read();
	my %alias_for_app;
	# aka rows live on the target app; the aliases map covers machines and houses
	# (and anything taught before this rule).
	my $aka_map = &guide_aka_read();
	foreach my $app ( keys %{$aka_map} ) {
		$alias_for_app{$app} = [ @{ $aka_map->{$app} || [] } ];
	}
	my %alias_for_key;
	foreach my $key ( keys %{$alias_map} ) {
		my $entry = $alias_map->{$key};
		next unless ref $entry eq 'HASH';
		my $kind = $entry->{'kind'} || '';
		if (($kind eq 'machine' || $kind eq 'house') && length($entry->{'uuid'} || '')) {
			push @{ $alias_for_key{ $kind . "\x1f" . $entry->{'uuid'} } }, $key;
		}
		elsif (length($entry->{'app'} || '')) {
			push @{ $alias_for_app{ $entry->{'app'} } }, $key;
		}
	}
	my $score_aliases = sub {
		my ($aliases) = @_;
		my ($score, $how) = (0, '');
		foreach my $raw ( @{$aliases} ) {
			next unless defined $raw && length $raw;
			my $alias = &guide_name_normalize($raw);
			next unless length $alias;
			return (100, 'exact') if $alias eq $query;
			if (index($alias, $query) == 0) {
				($score, $how) = (70, 'prefix') if $score < 70;
			}
			elsif (length($alias) >= 3 && length($query) >= 4 && index($query, $alias) == 0) {
				($score, $how) = (65, 'prefix') if $score < 65;
			}
			elsif (length($query) >= 4 && index($alias, $query) >= 0) {
				($score, $how) = (45, 'part') if $score < 45;
			}
			elsif (length($query) >= 4 && abs(length($alias) - length($query)) <= 2) {
				my $d = &guide_name_distance($alias, $query);
				if ($d <= 1) { ($score, $how) = (30, 'near') if $score < 30; }
				elsif ($d <= 2) { ($score, $how) = (20, 'near') if $score < 20; }
			}
		}
		return ($score, $how);
	};
	my $accept = sub {
		my ($kind, $construct) = @_;
		return 0 if length $filter_sing && $construct ne $filter_sing;
		return 1 unless length $want;
		return 1 if $want eq $kind;
		return 1 if $want eq 'app' && ($kind eq 'app' || $kind eq 'person');
		return 1 if $want eq 'construct' && ($construct || '') ne '';
		return 0;
	};
	my $index = &people_index();
	my %kind_of;
	my %display_name;
	my %house_of;
	my %house_name_of;
	foreach my $construct ( @{ $index->{'constructs'} || [] } ) {
		foreach my $row ( @{ $construct->{'rows'} || [] } ) {
			next unless defined $row->{'app'};
			$kind_of{ $row->{'app'} } = $construct->{'sing'};
			$display_name{ $row->{'app'} } = $row->{'name'} if $row->{'foreign'} && ($row->{'name'} || '') ne '';
			if (($row->{'house_uuid'} || '') ne '') {
				$house_of{ $row->{'app'} } = $row->{'house_uuid'};
				$house_name_of{ $row->{'app'} } = $row->{'house_name'} || '';
			}
		}
	}
	# this house is the provenance of its own constructs
	my $own_crest = &subs::crest_record_read();
	my $own_house_uuid = $own_crest->{'uuid'} || '';
	my $own_house_name = $own_crest->{'name'} || &subs::crest_house_name_read();
	my %person;
	my $people_rows = eval { &subs::db_select('people', undef, { status => 'active' })->hashes } || [];
	foreach my $p ( @{$people_rows} ) {
		$person{ $p->{'app'} } = $p if defined $p->{'app'} && length $p->{'app'};
	}
	my %used;
	my $used_rows = eval { &subs::db_query('select app, max(server_time) as used from appointments group by app')->hashes } || [];
	foreach my $row ( @{$used_rows} ) {
		$used{ $row->{'app'} } = $row->{'used'} if defined $row->{'app'};
	}
	my %apps;
	$apps{$_} = 1 for keys %{$gb::known_appts};
	my $construct_rows = eval { &subs::db_query("select distinct app from settings where setting in ('pos','mab')")->hashes } || [];
	$apps{ $_->{'app'} } = 1 for @{$construct_rows};
	my $appt_rows = eval { &subs::db_query('select distinct app from appointments')->hashes } || [];
	$apps{ $_->{'app'} } = 1 for @{$appt_rows};
	$apps{$_} = 1 for keys %person;
	my @candidates;
	foreach my $app ( keys %apps ) {
		next unless defined $app && length $app;
		my $is_person = $person{$app} ? 1 : 0;
		my $kind = $is_person ? 'person' : 'app';
		my $construct = $kind_of{$app} || '';
		next unless $accept->($kind, $construct);
		my @aliases = ($app, &subs::format_name($app));
		push @aliases, $display_name{$app} if ($display_name{$app} || '') ne '';
		push @aliases, @{ $alias_for_app{$app} || [] };
		push @aliases, $person{$app}->{'name'} if $is_person;
		my ($score, $how) = $score_aliases->(\@aliases);
		next unless $score;
		my $uuid = $is_person ? ($person{$app}->{'uuid'} || '') : '';
		$uuid = &subs::construct_uuid($app) unless length $uuid;
		my @memberships;
		if ($is_person) {
			foreach my $chip ( @{ &people_chips($index, $app) || [] } ) {
				push @memberships, $chip->{'label'} . ': ' . $chip->{'name'};
				last if scalar @memberships >= 3;
			}
		}
		push @candidates, {
			kind => $kind,
			app => $app,
			name => $display_name{$app} || ($is_person ? ($person{$app}->{'name'} || &subs::format_name($app)) : &subs::format_name($app)),
			uuid => $uuid,
			construct => $construct,
			foreign => (($house_of{$app} || '') ne '' ? 1 : 0),
			house_uuid => $house_of{$app} || $own_house_uuid,
			house_name => $house_name_of{$app} || $own_house_name,
			memberships => \@memberships,
			score => $score,
			how => $how,
			used => $used{$app} || 0,
		};
	}
	if (!$want || $want eq 'machine') {
		my $machine_rows = eval { &subs::db_select('remote_machines')->hashes } || [];
		foreach my $rm ( @{$machine_rows} ) {
			next unless $rm->{'signatorial'};
			my @aliases = grep { defined && length } ($rm->{'hostname'}, $rm->{'fqdn'}, $rm->{'ip'});
			push @aliases, @{ $alias_for_key{ 'machine' . "\x1f" . ($rm->{'uuid'} || '') } || [] };
			my @short = map { my $x = $_; $x =~ s/\..*$//; $x } grep { defined && length } ($rm->{'fqdn'});
			my ($score, $how) = $score_aliases->([ @aliases, @short ]);
			next unless $score;
			push @candidates, {
				kind => 'machine',
				app => $rm->{'hostname'} || $rm->{'fqdn'} || '',
				name => $rm->{'hostname'} || $rm->{'fqdn'} || $rm->{'ip'} || '',
				uuid => $rm->{'uuid'} || '',
				construct => '',
				memberships => [],
				score => $score,
				how => $how,
				used => $rm->{'server_time'} || 0,
			};
		}
	}
	if (!$want || $want eq 'house') {
		my $own = &subs::crest_record_read();
		if ($own->{'uuid'}) {
			my @aliases = ($own->{'name'}, &subs::crest_house_name_read());
			push @aliases, @{ $alias_for_key{ 'house' . "\x1f" . ($own->{'uuid'} || '') } || [] };
			my ($score, $how) = $score_aliases->(\@aliases);
			if ($score) {
				push @candidates, {
					kind => 'house', app => $own->{'name'} || '', name => $own->{'name'} || &subs::crest_house_name_read(),
					uuid => $own->{'uuid'}, construct => '', memberships => [], score => $score, how => $how, used => 0,
				};
			}
		}
		foreach my $entry ( @{ &subs::crest_peer_list_read() || [] } ) {
			next unless ref $entry eq 'HASH' && ref $entry->{'crest'} eq 'HASH';
			my $crest = $entry->{'crest'};
			next unless ($crest->{'uuid'} || '') ne '';
			my ($score, $how) = $score_aliases->([ $crest->{'name'}, @{ $alias_for_key{ 'house' . "\x1f" . ($crest->{'uuid'} || '') } || [] } ]);
			next unless $score;
			push @candidates, {
				kind => 'house', app => $crest->{'name'} || '', name => $crest->{'name'} || '',
				uuid => $crest->{'uuid'}, construct => '', memberships => [], score => $score, how => $how, used => 0,
			};
		}
	}
	@candidates = grep {
		my $hn = &guide_name_normalize($_->{'house_name'} || '');
		my $hu = lc($_->{'house_uuid'} || '');
		(length $hn && $hn eq $house_filter)
			|| (length $hu && index($hu, lc $house_filter) == 0)
	} @candidates if length $house_filter;
	@candidates = grep { index(lc($_->{'uuid'} || ''), lc($id_prefix)) == 0 } @candidates if length $id_prefix;
	@candidates = sort {
		$b->{'score'} <=> $a->{'score'}
			|| ($b->{'used'} || 0) <=> ($a->{'used'} || 0)
			|| lc($a->{'name'} || '') cmp lc($b->{'name'} || '')
	} @candidates;
	return { ok => 0, reason => 'none', candidates => [] } unless @candidates;
	splice @candidates, 12 if scalar @candidates > 12;
	my @top = grep { $_->{'score'} == $candidates[0]->{'score'} } @candidates;
	# An exact tie is ambiguous even at 100. A single prefix (70) is clear; a
	# fuzzy guess never acts on its own.
	if ($candidates[0]->{'score'} >= 60 && scalar @top == 1) {
		return { ok => 1, target => $candidates[0], candidates => \@candidates };
	}
	return { ok => 0, reason => 'ambiguous', candidates => \@candidates };
}

sub guide_resolve_action {
	my ($action) = @_;
	return $action unless ref $action eq 'HASH';
	my $a = $action->{'action'} || '';
	my %needs = map { $_ => 1 } qw/open_app update stop delete/;
	my $text = $action->{'app'} || '';
	return $action unless length $text;
	return $action unless $needs{$a} || $a eq 'create' || $a eq 'generate';
	my $r = &guide_resolve_target($text, kind => 'app');
	if ($r->{'ok'}) {
		$action->{'app'} = $r->{'target'}->{'app'};
		$action->{'app_uuid'} = $r->{'target'}->{'uuid'} if length($r->{'target'}->{'uuid'} || '');
		$action->{'app_label'} = &guide_target_label($r->{'target'});
		return $action;
	}
	if ($a eq 'create' || $a eq 'generate') {
		# create may legitimately name a new app; an ambiguous existing name is
		# still a question, and generate's app is optional.
		my $cands = $r->{'candidates'} || [];
		if ($r->{'reason'} eq 'ambiguous' && @{$cands}) {
			return &guide_ask_candidates($text, $cands);
		}
		delete $action->{'app'} if $a eq 'generate';
		return $action;
	}
	# Opening an app we have never seen is allowed to fall through: the client
	# simply does nothing, and an app may exist that the index does not list yet.
	return $action if $a eq 'open_app' && $r->{'reason'} eq 'none';
	return &guide_ask_candidates($text, $r->{'candidates'} || []);
}

sub guide_ask_candidates {
	my ($text, $candidates) = @_;
	my @all = @{ $candidates || [] };
	my $top = @all ? $all[0]->{'score'} : 0;
	# Only the real contenders: an exact tie, or the same prefix tier. A fuzzy
	# "misc" beside "music" is not something to ask the person about.
	my @labels = map { &guide_target_label($_) } grep { $_->{'score'} >= $top - 10 } @all;
	@labels = @labels[0 .. 3] if scalar @labels > 4;
	return { action => 'ask', text => 'Which one did you mean: ' . join('; ', @labels) . '?' } if @labels;
	return { action => 'ask', text => 'I do not know "' . $text . '" yet.' };
}

sub coding_repo { return &subs::home('~/jawnos'); }

sub coding_path($rel) {
	$rel = '' unless defined $rel;
	$rel =~ s{^\./+}{};
	$rel =~ s{^/+}{};
	return undef if $rel =~ /(^|\/)\.\.(\/|$)/;
	return undef if $rel =~ /[\x00-\x1f"`\\]/;
	return undef if $rel =~ m{^(?:\.git|\.president|releases|voices)(?:/|$)};
	return undef if $rel eq 'config.json';
	return &coding_repo() . ($rel eq '' ? '' : '/' . $rel);
}

sub update_database($data) {
	&subs::cache_delete({ app => 'me', context => 'pseudonyms' });
	my $commands = [
		# Watch-only receiving addresses: one row per invoice, public data only.
		# An address is never reused, and the unique index is what makes two
		# machines that allocated the same index while apart fall through to the
		# next one instead of sharing an address.
		'create table if not exists crypto_address (
			uuid VARCHAR(255) unique,
			server_time VARCHAR(255),
			ost VARCHAR(25),
			app VARCHAR(255),
			asset VARCHAR(25),
			network VARCHAR(255),
			address VARCHAR(255) unique,
			derivation VARCHAR(25),
			addr_index INTEGER,
			path VARCHAR(255),
			invoice_uuid VARCHAR(255),
			issued_at VARCHAR(25)
		)',
		'create index if not exists idx1_crypto_address on crypto_address (app, addr_index)',
		'create index if not exists idx2_crypto_address on crypto_address (invoice_uuid)',
		# Double-entry accounting: a chart of accounts and the journal that posts
		# to it. Both are derived from the money ledger, so each machine builds its
		# own (they stay out of the sync table list in gb.pl); the entries are
		# keyed by their source row so a rebuild is deterministic.
		'create table if not exists ledger_accounts (
			uuid VARCHAR(255) unique,
			code VARCHAR(20) unique,
			name VARCHAR(255),
			type VARCHAR(25),
			normal VARCHAR(10),
			app VARCHAR(500),
			parent VARCHAR(20),
			active VARCHAR(10),
			server_time VARCHAR(30),
			ost VARCHAR(25)
		)',
		'create index if not exists idx1_ledger_accounts on ledger_accounts (app)',
		'create table if not exists journal (
			uuid VARCHAR(90) unique,
			entry_uuid VARCHAR(90),
			timestamp VARCHAR(25),
			account_code VARCHAR(20),
			debit VARCHAR(30),
			credit VARCHAR(30),
			currency VARCHAR(20),
			memo VARCHAR(500),
			source_uuid VARCHAR(60),
			source_kind VARCHAR(25),
			app VARCHAR(500),
			account VARCHAR(500),
			server_time VARCHAR(30),
			ost VARCHAR(25)
		)',
		'create index if not exists idx1_journal_source on journal (source_uuid)',
		'create index if not exists idx2_journal_account on journal (account_code)',
		'create index if not exists idx3_journal_entry on journal (entry_uuid)',
		# People: a person is the identity, a device is how they carry it.
		'create table if not exists people (
			uuid VARCHAR(255) unique,
			name VARCHAR(255),
			privilege VARCHAR(25),
			status VARCHAR(25),
			created VARCHAR(255),
			ost VARCHAR(25),
			server_time VARCHAR(255)
		)',
		'create index if not exists idx1_people on people (uuid)',
		# a person construct (settings pos/mab = person) is the social person;
		# `app` links the people row to that settings app so the People window
		# and the Relational window cannot drift apart
		'alter table people add column app VARCHAR(255)',
		'create index if not exists idx2_people on people (app)',
		'alter table tickets add column person_uuid VARCHAR(255)',
		'alter table tickets add column peer_signatorial VARCHAR(255)',
		# a request may carry the crest of the house asking; the desk reads it
		# beside the known contacts, never as a grant
		'alter table tickets add column crest_uuid VARCHAR(255)',
		'alter table paired_devices add column person_uuid VARCHAR(255)',
		# A device can hold one wrapped Shamir share. The key is an X25519 key the
		# device generates for this alone (its login key may be signing-only); the
		# server wraps the share to it and never sees the share in the clear.
		'alter table paired_devices add column share_pubkey VARCHAR(255)',
		'create table if not exists house_key_shares (
			uuid VARCHAR(255) unique,
			set_id VARCHAR(255),
			share_index INTEGER,
			holder_person VARCHAR(255),
			holder_device VARCHAR(255),
			alg VARCHAR(25),
			wrapped LONGTEXT,
			status VARCHAR(25),
			created VARCHAR(255),
			server_time VARCHAR(255),
			ost VARCHAR(25)
		)',
		'create index if not exists idx1_house_key_shares on house_key_shares (set_id)',
		'create index if not exists idx2_house_key_shares on house_key_shares (holder_device)',
		# A machine with no vault asks for shares: only its ephemeral public key
		# is stored, and the holders answer with blobs the server cannot open.
		'create table if not exists house_key_share_requests (
			uuid VARCHAR(255) unique,
			code VARCHAR(25),
			asker_pubkey VARCHAR(255),
			name VARCHAR(255),
			need INTEGER,
			available INTEGER,
			set_id VARCHAR(255),
			status VARCHAR(25),
			created VARCHAR(255),
			server_time VARCHAR(255),
			ost VARCHAR(25)
		)',
		'create table if not exists house_key_share_releases (
			uuid VARCHAR(255) unique,
			request_uuid VARCHAR(255),
			set_id VARCHAR(255),
			share_index INTEGER,
			holder_device VARCHAR(255),
			wrapped LONGTEXT,
			created VARCHAR(255),
			server_time VARCHAR(255),
			ost VARCHAR(25)
		)',
		# A gateway is not a JawnOS peer: it has no manager and no session.
		# Keeping it in its own table lets the Dev panel show it after the
		# machine has left that network, with the last time it answered.
		'create table if not exists routers (
			uuid VARCHAR(255) unique,
			ip VARCHAR(64),
			mac VARCHAR(64),
			nic VARCHAR(64),
			name VARCHAR(255),
			model VARCHAR(255),
			manager VARCHAR(255),
			last_seen VARCHAR(25),
			timestamp VARCHAR(25),
			server_time VARCHAR(25),
			ost VARCHAR(25)
		)',
		'create index if not exists idx1_routers on routers (ip)',
		# Notes are their own store now, not appointments: one plain row per note.
		# The server_time column is what puts it on the generic peer sync and backup,
		# so a note still reaches every machine.
		'CREATE TABLE IF NOT EXISTS notes (uuid VARCHAR(255) unique, timestamp VARCHAR(255), server_time VARCHAR(255), app VARCHAR(255), device VARCHAR(255), text LONGTEXT, ost VARCHAR(25))',
		'CREATE INDEX IF NOT EXISTS idx1_notes on notes (timestamp)',
		'CREATE INDEX IF NOT EXISTS idx2_notes on notes (uuid)',
		'alter table appointments add column subtype VARCHAR(255)',
		# A construct's identity is its stable uuid, not its name; the label beside
		# it can change and two houses can use the same label. Filled from the
		# canonical construct_uuid setting on every new row.
		'alter table appointments add column app_uuid VARCHAR(255)',
		# The details bar can turn off the plate's automatic stop for the session
		# that is running; an unset value means on, which is every older row.
		'alter table appointments add column autostop VARCHAR(10)',
		'alter table mailbox add column sender VARCHAR(25)',
		'alter table mailbox add column email_server VARCHAR(255)',
		# schema.sql has carried these two for a while, but the migration list
		# never added them to an older database. A peer sent the columns anyway and
		# every mailbox batch failed with "table mailbox has no column named file",
		# so the same 827 rows were pulled again on every tick.
		'alter table mailbox add column from_email VARCHAR(255)',
		'alter table mailbox add column file LONGTEXT',
		# a composed letter can carry carbon copies now: cc is shown and answered
		# (reply-all), bcc travels to the smtp transport only and is never sent to
		# anyone who can see the headers. seen is the read/unread flag the list uses.
		'alter table mailbox add column cc VARCHAR(1000)',
		'alter table mailbox add column bcc VARCHAR(1000)',
		'alter table mailbox add column seen VARCHAR(10)',
		# starred is the flag the list and a Starred view read; thread is a
		# conversation key (the subject without its Re:/Fwd: plus the other party),
		# so a thread shows as one row and opens as the whole exchange.
		'alter table mailbox add column starred VARCHAR(10)',
		'alter table mailbox add column thread VARCHAR(255)',
		# the message headers a proper thread is built from: a letter's own Message-ID,
		# what it answers (In-Reply-To) and the chain it belongs to (References). The
		# thread column then holds the chain's root id rather than a subject guess.
		'alter table mailbox add column message_id VARCHAR(255)',
		'alter table mailbox add column in_reply_to VARCHAR(255)',
		'alter table mailbox add column thread_refs LONGTEXT',
		'drop table firewall',
		# ssh credentials are gone: transports, deploy and backup are all
		# password-less http/websocket now.
		'alter table remote_machines drop column username',
		'alter table remote_machines drop column password',
		'create table if not exists tunnels (
			server_time VARCHAR(255),
			ost VARCHAR(255),
			device VARCHAR(255),
			timestamp VARCHAR(255),
			ip VARCHAR(255),
			in_port VARCHAR(5),
			out_port VARCHAR(5),
			name VARCHAR(255),
			warranty VARCHAR(255),
			priority VARCHAR(5),
			status VARCHAR(25),
			process_id VARCHAR(10),
			signatorial VARCHAR(500),
			direction VARCHAR(7),
			uuid VARCHAR(50)
		)',
		'alter table tunnels add column batch_uuid VARCHAR(255)',
		'alter table tunnels add column failures INT',
		'alter table tunnels add column domain VARCHAR(255)',
		'alter table remote_machines add column tunnel VARCHAR(25)',
		'alter table remote_machines drop column tunnels',
		'alter table tunnels add column host VARCHAR(500)',
		'alter table remote_machines drop column sync_log',
		'alter table remote_machines add column mirrors LONGTEXT',
		'alter table remote_machines add column network LONGTEXT',
		'alter table remote_machines add column pseudonyms LONGTEXT',
		'alter table remote_machines add column dock_port VARCHAR(15)',
		'alter table remote_machines add column archive LONGTEXT',
		'alter table remote_machines add column archive_dir VARCHAR(255)',
		'alter table remote_machines add column sync_cursor VARCHAR(50)',
		'alter table remote_machines add column version VARCHAR(25)',
		# the peer's cached Ollama model list, so Plat can offer models by the machine
		# they live on without waiting on the network (filled by ollama_models_sync)
		'alter table remote_machines add column ollama_models LONGTEXT',
		# the records watch's staging area: a finding the fixed appointment audit
		# produced (a sweep, a duplicate, an orphan, an impossible row) and the actions
		# proposed for it, waiting for a person to Apply. Machine-local - the rowids and
		# uuids name this machine's own rows - so the table sits in gb's forbidden
		# list and never rides the peer sync, exactly like staged_fixes.
		'create table if not exists staged_records (
			uuid VARCHAR(255) unique,
			server_time VARCHAR(255),
			ost VARCHAR(25),
			kind VARCHAR(25),
			app VARCHAR(500),
			signature VARCHAR(500),
			sample LONGTEXT,
			proposed LONGTEXT,
			status VARCHAR(25),
			model VARCHAR(255),
			note LONGTEXT,
			last_seen VARCHAR(255)
		)',
		'create index if not exists idx1_staged_records on staged_records (signature)',
		'create index if not exists idx2_staged_records on staged_records (status)',
		# the Guide writes here, not into appointments: a staged row is a proposal a
		# person can look over and promote (or drop) before it becomes real
		'create table if not exists staged_appointments (
			uuid VARCHAR(255) unique,
			staged_time VARCHAR(255),
			server_time VARCHAR(255),
			ost VARCHAR(25),
			source VARCHAR(255),
			app VARCHAR(500),
			type VARCHAR(500),
			timestamp VARCHAR(25),
			title VARCHAR(500),
			notes LONGTEXT,
			data LONGTEXT,
			duration VARCHAR(25),
			device VARCHAR(255),
			status VARCHAR(25)
		)',
		'alter table staged_appointments add column server_time VARCHAR(255)',
		'alter table staged_appointments add column ost VARCHAR(25)',
		# the Guide's create now carries a length ("lasts 5 minutes") as the negative
		# accrual the tree stores; a staged row keeps it so promote writes it on
		'alter table staged_appointments add column duration VARCHAR(25)',
		# a staged row may instead be a change to an appointment that already exists:
		# "kind" tells the two apart, "target_uuid" names the appointment the change
		# edits, and "changes" is the JSON of the fields to set on promote
		'alter table staged_appointments add column kind VARCHAR(25)',
		'alter table staged_appointments add column target_uuid VARCHAR(255)',
		'alter table staged_appointments add column changes LONGTEXT',
		'create index if not exists idx1_staged on staged_appointments (status, staged_time)',
		'create table if not exists sync_log (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			server_time VARCHAR(255),
			signatorial VARCHAR(500),
			tbl VARCHAR(255),
			app VARCHAR(255),
			uuid VARCHAR(255),
			scope VARCHAR(255),
			ost VARCHAR(255),
			additional LONGTEXT
		)',
		# every insert runs through db_insert, which stamps ost; a sync_log created
		# before this column existed failed every tombstone write with "table
		# sync_log has no column named ost". This adds it to those databases.
		'alter table sync_log add column ost VARCHAR(255)',
		'create table if not exists sync_cursors (
			signatorial VARCHAR(500) PRIMARY KEY,
			cursor VARCHAR(50)
		)',
		# One row per running or recently finished sync, for the yellow dot. It is
		# machine-local (it describes this machine's socket work), so the table is
		# in gb's forbidden list and never rides the peer sync or a backup.
		'create table if not exists sync_jobs (
			uuid VARCHAR(255) PRIMARY KEY,
			direction VARCHAR(25),
			peer VARCHAR(500),
			phase VARCHAR(255),
			current INTEGER,
			total INTEGER,
			state VARCHAR(25),
			note LONGTEXT,
			steps LONGTEXT,
			started VARCHAR(25),
			updated VARCHAR(25)
		)',
		'create index if not exists idx1_sync_jobs on sync_jobs (state, updated)',
		# One row per remote snapshot this machine is building for a peer, so the
		# puller can ask how the build is going instead of holding the request
		# open for every minute of it. The result is the same reply backup_now
		# used to return synchronously. Machine-local (it names a temp file on
		# this disk and belongs to one caller), so it is in gb's forbidden list.
		'create table if not exists sync_snapshots (
			uuid VARCHAR(255) PRIMARY KEY,
			job VARCHAR(255),
			caller VARCHAR(500),
			state VARCHAR(25),
			archive_path VARCHAR(1000),
			result LONGTEXT,
			size VARCHAR(25),
			sha256 VARCHAR(100),
			error LONGTEXT,
			timestamp VARCHAR(25),
			server_time VARCHAR(25),
			updated VARCHAR(25),
			ost VARCHAR(25)
		)',
		# The first build of this table shipped without ost; db_insert always
		# stamps it, so the row never landed. Add it for machines that already
		# created the table (the guard skips the alter once the column is there).
		'alter table sync_snapshots add column ost VARCHAR(25)',
		'create index if not exists idx1_sync_snapshots on sync_snapshots (state, updated)',
		# One row per Dev migration: this machine (the donor) asked a linked new
		# device to pull the whole house from here. Machine-local - it names this
		# donor's roster and its own serve job - so it is in gb's forbidden list.
		'create table if not exists migrations (
			uuid VARCHAR(255) PRIMARY KEY,
			device_signatorial VARCHAR(500),
			device_name VARCHAR(255),
			donor_signatorial VARCHAR(500),
			state VARCHAR(25),
			note LONGTEXT,
			started VARCHAR(25),
			updated VARCHAR(25),
			server_time VARCHAR(25),
			ost VARCHAR(25)
		)',
		'create index if not exists idx1_migrations on migrations (state, updated)',
		# The error watch's catch: an error seen in the running logs, and the fix
		# the Coding agent proposed for it, staged until a person applies it.
		# Machine-local (the rows name this repo's files), so the table sits in
		# gb's forbidden list and never rides the peer sync or a backup.
		'create table if not exists staged_fixes (
			uuid VARCHAR(255) unique,
			server_time VARCHAR(255),
			ost VARCHAR(25),
			source VARCHAR(25),
			signature VARCHAR(500),
			sample LONGTEXT,
			tally INT,
			status VARCHAR(25),
			model VARCHAR(255),
			summary LONGTEXT,
			files LONGTEXT,
			steps LONGTEXT,
			note LONGTEXT,
			last_seen VARCHAR(255)
		)',
		'create index if not exists idx1_staged_fixes on staged_fixes (signature)',
		'create index if not exists idx2_staged_fixes on staged_fixes (status)',
		# The house AI ledger: which machines can take AI work and were seen
		# recently (ai_house), which machine ran which job (ai_jobs), and each
		# machine's spend for the day (ai_budget). Unlike staged_fixes these carry
		# server_time and are not in gb's forbidden list, so they ride the ordinary
		# peer sync - the house cannot pay twice for one job and the day's budget is
		# one pot, not one per machine.
		'create table if not exists ai_house (
			uuid VARCHAR(255),
			machine VARCHAR(255) unique,
			has_model INT,
			seen VARCHAR(25),
			ost VARCHAR(255),
			server_time VARCHAR(255)
		)',
		'create table if not exists ai_jobs (
			uuid VARCHAR(255),
			job VARCHAR(255) unique,
			owner VARCHAR(255),
			at VARCHAR(25),
			state VARCHAR(25),
			ost VARCHAR(255),
			server_time VARCHAR(255)
		)',
		'create table if not exists ai_budget (
			uuid VARCHAR(255),
			machine VARCHAR(255),
			day VARCHAR(25),
			tokens INT,
			ost VARCHAR(255),
			server_time VARCHAR(255)
		)',
		'create unique index if not exists idx_ai_budget on ai_budget (machine, day)',
		# db_insert always writes uuid and ost, so a ledger table built before they
		# were added refuses its own inserts; add them for existing installs.
		'alter table ai_house add column uuid VARCHAR(255)',
		'alter table ai_house add column ost VARCHAR(255)',
		'alter table ai_jobs add column uuid VARCHAR(255)',
		'alter table ai_jobs add column ost VARCHAR(255)',
		'alter table ai_budget add column uuid VARCHAR(255)',
		'alter table ai_budget add column ost VARCHAR(255)',
		'alter table continent add column signatorial VARCHAR(500)',
		'alter table continent add column speed VARCHAR(25)',
		'alter table continent add column altitude VARCHAR(25)',
		'create table if not exists warehouse (
			timestamp VARCHAR(255),
			server_time VARCHAR(255),
			item VARCHAR(500),
			model LONGTEXT,
			options LONGTEXT,
			uuid VARCHAR(500),
			ost VARCHAR(255),
			device VARCHAR(100),
			quantity VARCHAR(25),
			unit VARCHAR(255),
			data LONGTEXT,
			serial_number VARCHAR(1000),
			batch_uuid VARCHAR(255),
			app_uuid VARCHAR(255)
		)',
		'alter table mailbox add column conversation_uuid VARCHAR(255)',
		# The address tuple grew: institution, government, corporation, place,
		# vendor and event joined the social constructs, and an account stopped
		# being one. The account column stays so rows already filed under one keep
		# their record, but nothing addresses by it now. Backfill each new column
		# to its construct's default, or mail filed before this build would hide
		# behind NULL instead of joining the default dial.
		'alter table mailbox add column institution VARCHAR(255)',
		'alter table mailbox add column government VARCHAR(255)',
		'alter table mailbox add column corporation VARCHAR(255)',
		'alter table mailbox add column place VARCHAR(255)',
		'alter table mailbox add column vendor VARCHAR(255)',
		'alter table mailbox add column event VARCHAR(255)',
		"update mailbox set institution = 'house' where institution is null or institution = ''",
		"update mailbox set government = 'civic' where government is null or government = ''",
		"update mailbox set corporation = 'sole' where corporation is null or corporation = ''",
		"update mailbox set place = 'home' where place is null or place = ''",
		"update mailbox set vendor = 'market' where vendor is null or vendor = ''",
		"update mailbox set event = 'now' where event is null or event = ''",
		'alter table mailbox drop column artificial_intelligence',
		'alter table warehouse add column place VARCHAR(500)',
		'alter table warehouse add column type VARCHAR(25)',
		'alter table warehouse add column project VARCHAR(255)',
		'alter table warehouse add column account VARCHAR(255)',
		'alter table warehouse add column warranty VARCHAR(25)',
		# the warehouse is the ledger for money as well as stock now: a money move
		# carries the same fields the transaction did, so the budget can read it
		# without knowing it moved. kind names the three faces (stock/money/inventory)
		# so a row's purpose no longer rests on whether it happens to name an account.
		'alter table warehouse add column kind VARCHAR(25)',
		'alter table warehouse add column app VARCHAR(255)',
		'alter table warehouse add column movement VARCHAR(25)',
		'alter table warehouse add column vendor VARCHAR(255)',
		'alter table warehouse add column manufacturer VARCHAR(255)',
		'alter table warehouse add column currency VARCHAR(25)',
		'alter table warehouse add column amount VARCHAR(25)',
		'alter table warehouse add column tax VARCHAR(25)',
		'alter table warehouse add column aux VARCHAR(25)',
		'alter table warehouse add column total VARCHAR(25)',
		'alter table warehouse add column duration VARCHAR(25)',
		'alter table warehouse add column notes LONGTEXT',
		'alter table warehouse add column state VARCHAR(25)',
		'alter table warehouse add column source_uuid VARCHAR(255)',
		# The websocket connect writes the running code revision so a tab can reload
		# when it changes, but the column was never added to the table: every connect
		# failed with "table websockets has no column named revision", retried to the
		# driver's limit and left the tab unrecorded. Add it here for existing installs
		# (schema.sql carries it for a database built fresh).
		'alter table websockets add column revision VARCHAR(255)',
		# peers prove themselves with an Ed25519 signature now; the roster row
		# carries the public key (schema.sql has it for a fresh database).
		'alter table remote_machines add column pubkey LONGTEXT',
		# a grant is a lease, not a name: the scope a house may act at here, and
		# the epoch-ms instant it lapses. peer_allows reads them; an older row
		# with no scope keeps the trust it already had, so this is additive.
		# privilege is the relationship (citizen, peer, visitor, guest); scope is
		# what it may do here. The citizen's own machines are marked on the
		# remote_device_connect path, which only the shared house password opens.
		'alter table remote_machines add column privilege VARCHAR(25)',
		'alter table remote_machines add column grant_scope VARCHAR(25)',
		'alter table remote_machines add column grant_expires VARCHAR(25)',
		# A member machine cosigns the house crest with its peer key. crest_uuid is
		# the crest it backs and crest_cosig is its signed statement, so the roster
		# (and the card) can say which machines stand behind the crest.
		'alter table remote_machines add column crest_uuid VARCHAR(255)',
		'alter table remote_machines add column crest_cosig LONGTEXT',
		# paired devices: the browsers and phones a citizen has signed in once
		'create table if not exists paired_devices (uuid VARCHAR(255) unique, name VARCHAR(255), pubkey LONGTEXT, bio_pubkey LONGTEXT, privilege VARCHAR(25), status VARCHAR(25), timestamp VARCHAR(25), server_time VARCHAR(25), ost VARCHAR(25), last_seen VARCHAR(25), agent VARCHAR(500))',
		# a phone that has enrolled its biometric key: an EC P-256 key in the
		# Android Keystore that the OS releases only after the person authenticates
		'alter table paired_devices add column bio_pubkey LONGTEXT',
		# a readable origin for the Security page: phone, app, browser or the
		# desktop's WebKit windows
		'alter table paired_devices add column kind VARCHAR(25)',
		# device approvals: an ask that waits for a citizen, with the short code
		# shown on both screens (merges like the roster it becomes)
		'create table if not exists device_requests (uuid VARCHAR(255) unique, name VARCHAR(255), pubkey LONGTEXT, agent VARCHAR(500), code VARCHAR(25), status VARCHAR(25), device_uuid VARCHAR(255), remote_address VARCHAR(255), timestamp VARCHAR(25), server_time VARCHAR(25), ost VARCHAR(25))',
		'CREATE INDEX IF NOT EXISTS idx6_warehouse on warehouse (kind)',
		'CREATE INDEX idx1_tunnels on tunnels (signatorial)',
		'CREATE INDEX idx2_settings on settings (setting,device)',
		'CREATE INDEX idx3_settings on settings (setting,value)',
		'CREATE INDEX idx4_settings on settings (setting,device,value)',
		'CREATE INDEX idx2_appts on appointments (app,timestamp)',
		'CREATE INDEX idx7_appts on appointments (timestamp,seen)',
		'CREATE INDEX idx8_appts on appointments (timestamp, stop_timestamp, seen, stop_seen)',
		'CREATE INDEX idx9_appts on appointments (stop_timestamp,stop_seen)',
		'CREATE INDEX idx10_appts on appointments (duties,next_duty)',
		'CREATE INDEX idx11_appts on appointments (app,server_time,status)',
		'CREATE INDEX idx1_ws on websockets (app,browser_tab_id)',
		'CREATE INDEX idx3_ws on websockets (app,browser_tab_id,remote_address)',
		'CREATE INDEX idx2_ws on websockets (browser_tab_id)',
		'CREATE INDEX idx1_continent on continent (app)',
		'CREATE INDEX idx2_continent on continent (app,uuid)',
		# navigation_information asks continent for the current (type='temporary')
		# positions on every centre-view poll; with only (app) indexed that was a
		# full scan of the whole position history - 116k rows and growing - on
		# every tick. (type, signatorial, warranty) turns it into a lookup.
		'CREATE INDEX IF NOT EXISTS idx6_continent on continent (type, signatorial, warranty)',
		'CREATE INDEX idx1_security on security (level)',
		'CREATE INDEX idx2_security on security (level,server_time)',
		'CREATE INDEX idx1_cache on cache (app,device,context,subcontext)',
		'CREATE INDEX idx1_backups on backups (signatorial,recipient)',
		'CREATE INDEX idx1_mailbox on mailbox (contact)',
		'CREATE INDEX idx2_mailbox on mailbox (community,club,team,project,account,person)',
		'CREATE INDEX idx1_backups on backups (recipient,signatorial,ost)',
		'CREATE INDEX idx2_backups on backups (recipient,signatorial)',
		'CREATE INDEX idx3_backups on backups (recipient,signatorial,ost,reason)',
		'CREATE INDEX idx4_backups on backups (recipient,signatorial,reason)',
		# warehouse: stock/money lookups by item, place, source document and account
		'CREATE INDEX IF NOT EXISTS idx1_warehouse on warehouse (item)',
		'CREATE INDEX IF NOT EXISTS idx2_warehouse on warehouse (place)',
		'CREATE INDEX IF NOT EXISTS idx3_warehouse on warehouse (app_uuid)',
		'CREATE INDEX IF NOT EXISTS idx4_warehouse on warehouse (account)',
		'CREATE INDEX IF NOT EXISTS idx5_warehouse on warehouse (place,item)',
		# item catalog lookups are all "where app = ?"
		'CREATE INDEX IF NOT EXISTS idx1_model on model (app)',
		'CREATE INDEX IF NOT EXISTS idx1_option on option (app)',
		'CREATE INDEX IF NOT EXISTS idx1_option_category on option_category (app)',
		'CREATE INDEX IF NOT EXISTS idx1_subcategory on subcategory (app)',
		# settings_grabber reads by (app,device); setters read by (app,setting)
		'CREATE INDEX IF NOT EXISTS idx5_settings on settings (app,device)',
		'CREATE INDEX IF NOT EXISTS idx6_settings on settings (app,setting)',
		# transactions pull their documents by (type,app)
		'CREATE INDEX IF NOT EXISTS idx12_appts on appointments (type,app)',
		# inventory_details matches appointments by app or model; without an index
		# on model the model half of that or scans the whole table
		'CREATE INDEX IF NOT EXISTS idx13_appts on appointments (model)',
		# the peer sync check counts appointments above a watermark; server_time is
		# not a prefix of idx11 (app,server_time,status), so that count was a full
		# scan of the whole table on every two-minute tick
		'CREATE INDEX IF NOT EXISTS idx14_appts on appointments (server_time)',
		# remote machines are looked up by connection state and ip
		'CREATE INDEX IF NOT EXISTS idx1_remote_machines on remote_machines (connection)',
		'CREATE INDEX IF NOT EXISTS idx2_remote_machines on remote_machines (ip)',
		# mailbox reads by uuid, by (email,status), and by pen conversations
		'CREATE INDEX IF NOT EXISTS idx3_mailbox on mailbox (uuid)',
		'CREATE INDEX IF NOT EXISTS idx4_mailbox on mailbox (email,status)',
		'CREATE INDEX IF NOT EXISTS idx5_mailbox on mailbox (contact,conversation_uuid)',
		# Redundant indexes retired after a plans-and-usage audit: byte-for-byte
		# duplicates, prefixes of an index that is kept, or shapes the planner never
		# chose. The creates are gone from this list on purpose - leave one behind and
		# it would be recreated on the next run because migration_already_applied
		# checks sqlite_master rather than a ledger.
		'DROP INDEX IF EXISTS idx1_settings',
		'DROP INDEX IF EXISTS idx1_appts',
		'DROP INDEX IF EXISTS idx3_appts',
		'DROP INDEX IF EXISTS idx4_appts',
		'DROP INDEX IF EXISTS idx5_appts',
		'DROP INDEX IF EXISTS idx6_appts',
		'DROP INDEX IF EXISTS idx3_continent',
		'DROP INDEX IF EXISTS idx4_continent',
		'DROP INDEX IF EXISTS idx5_continent'
	];
	foreach my $t ( qw/model option option_category subcategory/) {
		foreach my $h ( qw/month day hour wday/ ) {
			push @{$commands}, 'alter table ' . $t . ' add column def_' . $h . ' VARCHAR(500)';
		}
	}
	if ($data->{'commands'}) {
		$commands = $data->{'commands'};
	}
	if ($data->{'duty'} eq 'list') {
		return $commands;
	}
	else {
		# The schema is migrated once per version, not on every call. The version
		# whose pass completed is kept in the database; while it still matches the
		# code's own version there is nothing new to apply. The commands are
		# idempotent and each carries its own guard, but that guard is a query per
		# command - and this runs at every login, every merge and every boot.
		my $current = &subs::jawn_version();
		my $local = $data->{'commands'} ? 0 : 1;
		if ($local) {
			my $applied = &subs::setting_grabber({ app => '__president', setting => 'schema_version' });
			return if $applied && $applied eq $current;
		}
		my ($db,$database,$sql) = &subs::database_grabber();
		my $failed = 0;
		foreach my $command (@{$commands}) {
			next if &migration_already_applied($command);
			my $ok = eval { &subs::db_query($command); 1 };
			$failed++ unless $ok;
		}
		# Deliberately no pragma tuning here. The handle is shared by the whole
		# process for its lifetime now, and the tuning that used to live here
		# (no busy timeout, no mmap, a 200MB page cache) ran after the commands
		# anyway - it could not have sped the migration up, it just left the
		# process failing every later contended write with "database is locked".
		# A one-off migration that wants its own settings should open its own
		# Mojo::SQLite, not borrow this one.
		# Statistics are the exception: after schema or index changes the planner's
		# numbers describe a database that no longer exists, and optimize only
		# re-runs ANALYZE where they are stale or missing. The alarm haircut carries
		# the same pair, for installs that have that utility switched on.
		eval { $db->query('PRAGMA analysis_limit=400;'); };
		eval { $db->query('PRAGMA optimize;'); };
		# data backfills ride the schema migration: any machine that receives the
		# new code runs the ones it has not recorded, at its next login / merge.
		&subs::run_backfills();
		# Only a clean pass records the version: a command that failed (a locked
		# database, say) has to be retried on the next call, never skipped because
		# the version moved on. A peer's command list is not ours to record from.
		if ($local && !$failed) {
			&subs::setting_setter({ app => '__president', setting => 'schema_version', value => $current });
		}
	}

	if (1 == 0) {
		my $settings = &subs::db_select('settings', undef, { setting => 'home_plate' })->hashes;
		foreach my $set ( grep { $_->{'app'} ne 'me' } @{$settings} ) {
			my $con = eval { return decode_json $set->{'value'} } || {};
			if ($con->{'latitude'}) {
				my $location = &subs::db_select('continent', undef, { app => $set->{'app'}, uuid => $con->{'uuid'} })->hashes->[0];
				if ($location->{'uuid'}) {
					&subs::db_update('continent', { type => 'home_plate' }, { uuid => $location->{'uuid'} });
				}
			}
		}
	}
	if ( 1 == 0 ) {
		my $settings = &subs::db_select('settings', undef, { setting => 'public' })->hashes;
		foreach my $set ( @{$settings} ) {
			&subs::db_update('settings', { value => 'on', server_time => &subs::rightNow() }, { app => $set->{'app'}, setting => $set->{'setting'}, uuid => $set->{'uuid'} });
		}
	}
	if (1 == 1) {
		my $q = &subs::db_query('select type from pragma_table_info(?) where name=?', 'cache', 'data')->hashes->[0]->{'type'};
		if ($q eq 'LONGTEXT') {
			&subs::db_query('ALTER TABLE cache ADD COLUMN s_data BLOB');
			my $caches = &subs::db_select('cache', undef, { s_data => undef })->hashes;
			foreach my $cache ( @{$caches} ) {
				my $d = eval { decode_json $cache->{'data'} };
        if ($@ || !$d) {
            next; # Skip to the next row safely
        }
				my $sd = eval { encode_sereal $d };
				&subs::db_update('cache', { s_data => $sd }, { uuid => $cache->{'uuid'}, app => $cache->{'app'} });
			}
			&subs::db_query('ALTER TABLE cache DROP COLUMN data');
			&subs::db_query('ALTER TABLE cache RENAME COLUMN s_data TO data');
		}
	}
}

1;
