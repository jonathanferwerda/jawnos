package Manager;

# manager_phone: route actions moved out of Manager.pl, one sub per route so a
# route can be read and changed without opening the whole file. The package
# is still Manager, so unqualified calls to its helpers and its package
# state work exactly as they did in the single file.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use strict;
use warnings ;#'uninitialized';
use Mojo::Promise;
use Mojo::UserAgent;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Clone qw(clone);
use Mojolicious::Static;
use Mojo::Log;
use Mojo::Transaction::WebSocket;
use Mojo::Parameters;
use Mojo::DOM;
use Mojo::URL;
use Mojo::JSON qw(decode_json encode_json);
use URI::Encode qw(uri_encode uri_decode);
use List::Util qw(shuffle);
use Data::Dumper;
use Mojo::Util qw/md5_sum html_unescape xml_escape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use File::Find;
use File::Slurp;
use File::Type;
use File::Copy;
use POSIX ();
use Fcntl qw(:flock O_CREAT O_EXCL O_WRONLY);
use Number::Format qw/:subs/;
use SQL::Abstract;
use Mojo::SQLite;
use Mojo::IOLoop;

use Mojolicious::Sessions;
use Mojo::Server::Daemon;
use Mojolicious::Renderer;
use Crypt::Simple;
use CryptX;
use HTML::Strip;
use HTML::Parser;
use Data::UUID;
use Storable;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use MIME::Base64;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
use Minion;

use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# GET /manager/phone
sub action_23201 {
	my $c = shift;
	# The Phone app: the house's numbers (known, and the numbers that are only
	# numbers), recent calls (the appointments whose subtype is 'phone'), the desk's
	# blocked numbers, and the dial pad. The pad places a call on a phone
	# (termux-telephony-call); the app's own address book and live call state ride
	# the native JawnContacts bridge.
	my $directory = &phone_directory();
	my $blocked = &phone_blocked();
	# Recent leaves the blacklist out: a refused call is filed as a cancelled
	# appointment so the house keeps the record, but the pane is for calls to
	# read, and a number the desk blocks is not one of them.
	my $calls = &phone_recent_unblocked(
		&subs::db_query('select app,uuid,timestamp,type,duration,account from appointments where subtype=? order by timestamp desc limit 60', 'phone')->hashes,
		[ map { $_->{'number'} } @{$blocked} ],
	);
	# a row carries its own route (the number's own, or '' for the person's
	# relationship) so the routing sheet opens on the right choice
	my $number_routes = &phone_routes_read();
	foreach my $call ( @{$calls} ) {
		$call->{'route'} = $number_routes->{ &ticket_contact_clean('phone', $call->{'account'} || '') } || '';
	}
	my %blocked_number = map { $_->{'number'} => 1 } @{$blocked};
	my $ivr = &phone_ivr_settings();
	my $ivr_machine = &phone_ivr_machine($ivr->{'machine'});
	$ivr->{'machine_available'} = ($ivr_machine && (($ivr_machine->{'connection'} || '') eq 'active')) ? 1 : 0;
	$ivr->{'machine_label'} = $ivr_machine ? ($ivr_machine->{'hostname'} || $ivr_machine->{'ip'} || '') : '';
	$ivr->{'away_active'} = &subs::vacation_active(&subs::rightNow()) ? 1 : 0;
	# The pane's status line says which audio backend carries the gateway's call
	# and whether it is ready; a not-ready gateway says why instead of pretending.
	&_ivr_audio_state($ivr, $ivr->{'machine'});
	# a row says so itself when any of its lines is on the desk's list, and each
	# line carries its own reading (the number, its type, whether it is blocked) so
	# the template joins them without walking the tuples itself
	foreach my $r ( @{ $directory->{'known'} }, @{ $directory->{'numbers'} } ) {
		$r->{'route'} = $number_routes->{ &ticket_contact_clean('phone', $r->{'value'} || '') } || '';
		my $any = 0;
		foreach my $l ( @{ $r->{'numbers'} } ) {
			$l->{'blocked'} = $blocked_number{ &ticket_contact_clean('phone', $l->{'value'}) } ? 1 : 0;
			$l->{'display'} = &subs::contact_line_label($l);
			$any = 1 if $l->{'blocked'};
		}
		$r->{'blocked'} = $any;
	}
	my $content = $c->render_to_string(
		template => 'apps/phone',
		calls => $calls,
		known => $directory->{'known'},
		numbers => $directory->{'numbers'},
		blocked => $blocked,
		ivr => $ivr,
		ringtone => &phone_ringtone(),
		own_lines => &subs::own_phone_lines(&subs::own_phone_host()),
		ivr_machines => &phone_ivr_machines(),
		ivr_candidates => &phone_ivr_candidates(),
		routes => &phone_routes_read(),
		ivr_voices => [ &subs::say_voices() ],
		caller_choices => &phone_caller_choices(),
	);
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'phone', title => 'Phone', contents => $content }, $c->param('timestamp'));
	$c->render(text => $contents);
}

# POST /manager/phone/dial
sub action_24603 {
	my $c = shift;
	my $number = $c->param('number') || '';
	$number =~ s/[^\d+#*]//g;
	unless ($number) { $c->render(json => { ok => 0, error => 'No number.' }); return; }
	if (&subs::device_setter() eq 'mobile') {
		# The caller reports a dial only when the app really placed it: a wifi
		# tablet answers this same route, so a caller can fall through to the next
		# mobile peer.
		my $dial = &subs::device_call('telephony.dial', { number => $number });
		my $ok = ($dial && $dial->{'dialed'}) ? 1 : 0;
		my $out = $ok ? 'dialed (bridge)' : 'the app could not place the call';
		$c->render(json => { ok => $ok, number => $number, out => $out });
		return;
	}
	# Not a phone: hand the call to one through remote_machines, the way an SMS is
	# handed over, so the pad dials for real from the laptop. The phone's own copy
	# of this route is what knows to run the command.
	my $dialled;
	foreach my $rm ( @{ &subs::db_query('select * from remote_machines where connection=? and device=?', 'active', 'mobile')->hashes } ) {
		last if $dialled;
		my $ru = eval { &remote_useragent_maker({ ip => $rm->{'ip'}, signatorial => $rm->{'signatorial'}, rm => $rm }) };
		next unless $ru && $ru->{'ua'} && $ru->{'manager'};
		my $res = eval { $ru->{'ua'}->inactivity_timeout(20)->post($ru->{'manager'} . '/manager/phone/dial?number=' . $number) };
		my $body = eval { decode_json $res->body } || {};
		$dialled = $rm if $body->{'ok'};
	}
	if ($dialled) {
		$c->render(json => { ok => 1, number => $number, via => ($dialled->{'hostname'} || $dialled->{'name'} || $dialled->{'ip'}) });
		return;
	}
	$c->render(json => { ok => 0, error => 'No phone is reachable to dial from.' });
}

# POST /manager/phone/call
sub action_24636 {
	my $c = shift;
	# The live half of the phone app: 'ring' starts the call's appointment (on the
	# caller's own app when the number is known - the Call screening role supplies
	# it at ring - else the fallback 'phone' app), 'end' stops it and 'miss'
	# cancels it. The house's own call-log poll skips what this wrote, so a live
	# call and its call-log trail are one appointment, not two.
	my $event = $c->param('event') || '';
	my $number = $c->param('number') || '';
	$number =~ s/[^\d+#*]//g;
	my $uuid = $c->param('uuid') || '';
	my $timestamp = &timestamp_adjuster($c);

	my $app = 'phone';
	if ($number) {
		# the caller's own app: their name when the house knows the number, else the
		# number's own app (phone_number_app makes it known), the way the call-log
		# check files an unknown caller - so a stranger's call is an app to rename
		# later rather than a drop on the floor
		$app = &subs::phone_number_app($number) || 'phone';
	}

	if ($event eq 'ring') {
		my $wrote = &appointment_writer($c, {
			app => $app,
			type => 'start',
			subtype => 'phone',
			timestamp => $timestamp,
			account => $number,
			data => encode_json({ direction => ($c->param('direction') || 'incoming'), number => $number, live => 1 }),
		});
		unless ($wrote && $wrote->{'uuid'}) {
			$c->render(json => { ok => 0, error => 'no appointment' });
			return;
		}
		# appointment_writer stamps a row at or before now as seen; a live ring is
		# the one appointment the Alarm loop must still claim, so put it back.
		&subs::db_update('appointments', { seen => undef, server_time => &subs::rightNow() }, { uuid => $wrote->{'uuid'} });
		$c->render(json => { ok => 1, app => $app, uuid => $wrote->{'uuid'} });
		return;
	}

	if ($event eq 'ignore') {
		# a call the desk's blacklist turned away: it never rang, so there is no
		# ring to stop - the appointment is written and closed at once, as a
		# cancelled call on the caller's own app. Filing it here also tells the
		# call-log poll (which skips a phone appointment within minutes of a log
		# entry) that this call is already accounted for.
		my $wrote = &appointment_writer($c, {
			app => $app,
			type => 'start',
			subtype => 'phone',
			timestamp => $timestamp,
			account => $number,
			data => encode_json({ direction => 'incoming', number => $number, blocked => 'yes' }),
		});
		unless ($wrote && $wrote->{'uuid'}) {
			$c->render(json => { ok => 0, error => 'no appointment' });
			return;
		}
		&subs::db_update('appointments', {
			type => 'cancel',
			stop_seen => 'yes',
			stop_timestamp => $timestamp,
			server_time => &subs::rightNow(),
		}, { uuid => $wrote->{'uuid'} });
		$c->render(json => { ok => 1, app => $app, uuid => $wrote->{'uuid'} });
		return;
	}

	if ($event eq 'log') {
		# A whole call, filed from the app's own record of it. The dialer role's
		# service sees every call whatever else is running, so this is what makes a
		# call taken with no page up leave an appointment behind (it used to be
		# written only by the page, and a call with the app in the background left
		# nothing). The appointment opens at the ring and closes at the hangup, or
		# cancels when nobody ever answered - a call that went out and was not
		# picked up counts the same way.
		my $started = $c->param('started') || $timestamp;
		my $ended = $c->param('ended') || $started;
		my $answered = ($c->param('answered') || '') eq 'yes';
		my $direction = $c->param('direction') || 'incoming';
		# The ranked list means the gateway that answered may not be this machine.
		# The app names it on the call record, and the transcript is asked of that
		# gateway instead of this machine's own directory.
		my $gateway = $c->param('gateway') || '';
		$gateway =~ s/^\s+|\s+$//g;
		$gateway = substr($gateway, 0, 128);
		# A call that rang through already wrote its appointment from the ring
		# event; close that row rather than writing a second one for the same
		# call. The ring and the call's own start are seconds apart.
		my $open = &subs::db_query(
			'select uuid from appointments where subtype = ? and account = ? and timestamp between ? and ? and stop_seen is null order by timestamp desc limit 1',
			'phone', $number, $started - 60000, $started + 60000
		)->hashes->[0];
		my $wrote = $open ? { uuid => $open->{'uuid'} } : &appointment_writer($c, {
			app => $app,
			type => 'start',
			subtype => 'phone',
			timestamp => $started,
			account => $number,
			data => encode_json({ direction => $direction, number => $number }),
		});
		unless ($wrote && $wrote->{'uuid'}) {
			$c->render(json => { ok => 0, error => 'no appointment' });
			return;
		}
		my %closing = ( stop_seen => 'yes', stop_timestamp => $ended, server_time => &subs::rightNow() );
		if ($answered) {
			$closing{'type'} = 'stop';
			$closing{'duration'} = $ended - $started;
		}
		else {
			$closing{'type'} = 'cancel';
		}
		&subs::db_update('appointments', \%closing, { uuid => $wrote->{'uuid'} });
		# the reception's own words for this call, into the number's Chat thread.
		# A screened call is answered, so only those carry a transcript.
		&subs::phone_call_transcript_note($number, $started, $ended, $gateway) if $answered;
		$c->render(json => { ok => 1, app => $app, uuid => $wrote->{'uuid'} });
		return;
	}

	if (($event eq 'end' || $event eq 'miss') && $uuid) {
		my $row = &subs::db_select('appointments', undef, { uuid => $uuid })->hashes->[0];
		if ($row && $row->{'app'}) {
			my $data = { stop_seen => 'yes', stop_timestamp => $timestamp, server_time => &subs::rightNow() };
			if ($event eq 'miss') {
				$data->{'type'} = 'cancel';
			}
			else {
				$data->{'type'} = 'stop';
				$data->{'duration'} = $timestamp - $row->{'timestamp'};
			}
			&subs::db_update('appointments', $data, { uuid => $uuid });
		}
		$c->render(json => { ok => 1, event => $event });
		return;
	}

	$c->render(json => { ok => 0, error => 'unknown event' });
}

# POST /manager/phone/ivr
sub action_24760 {
	my $c = shift;
	# The IVR pane's save. The settings are ordinary phone settings, so the
	# selected remote_machine, the routing choice and the three prompts all ride
	# the same setting rows the phone otherwise owns.
	my $saved = &phone_ivr_save({
		enabled   => $c->param('enabled'),
		machine   => $c->param('machine'),
		route     => $c->param('route'),
		voice     => $c->param('voice'),
		greeting  => $c->param('greeting'),
		prompt    => $c->param('prompt'),
		voicemail => $c->param('voicemail'),
		thanks    => $c->param('thanks'),
		hold      => $c->param('hold'),
		away      => $c->param('away'),
		away_greeting => $c->param('away_greeting'),
		flows     => $c->param('flows'),
		flow_defs => $c->param('flow_defs'),
		flow_order => $c->param('flow_order'),
		machines  => $c->param('machines'),
	});
	# The reception is the house's: hand the same save to the peers now, so the
	# gateway machine and the phone hold it immediately instead of waiting for
	# the next sync. A relayed copy does not relay again.
	unless (($c->param('remoted') || '') eq 'yes') {
		eval { &subs::remote_relay_request($c, { dissemination => 'yes' }); };
	}
	$c->render(json => { ok => 1, ivr => $saved });
}

# POST /manager/phone/greeting
#
# A flow's voicemail greeting, recorded in the pane and uploaded as the bytes
# the browser's recorder produced. It is converted once to a mono WAV and kept
# in the house's media folder, sealed with the rest of that tree; the flow then
# names the path. The body is the audio itself, so the size cap is checked
# before and after reading it, and the type is one the house can play.
sub action_24763 {
	my $c = shift;
	my $limit = 2 * 1024 * 1024;
	my $length = $c->req->headers->content_length || 0;
	if ($length > $limit) {
		$c->render(json => { ok => 0, error => 'too large' });
		return;
	}
	my $body = $c->req->body;
	$body = $body->slurp if ref $body;
	unless (defined $body && length $body) {
		$c->render(json => { ok => 0, error => 'no audio' });
		return;
	}
	if (length $body > $limit) {
		$c->render(json => { ok => 0, error => 'too large' });
		return;
	}
	my $type = lc($c->req->headers->content_type || '');
	$type =~ s/\s*;.*$//;
	unless (!length $type || $type =~ m{^audio/} || $type eq 'application/octet-stream') {
		$c->render(json => { ok => 0, error => 'not audio' });
		return;
	}
	my ($wav, $seconds) = &subs::phone_ivr_greeting_wav($body);
	unless (defined $wav && length $wav) {
		$c->render(json => { ok => 0, error => 'unreadable' });
		return;
	}
	# a minute, with room for the encoder's tail
	if ($seconds > 61) {
		$c->render(json => { ok => 0, error => 'too long' });
		return;
	}
	my $flow = $c->param('flow') || '';
	$flow = '' unless $flow =~ /^[a-z0-9_]{1,30}$/;
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $path = &subs::phone_ivr_greeting_store($wav, timestamp => $timestamp);
	unless (length $path) {
		$c->render(json => { ok => 0, error => 'could not save' });
		return;
	}
	$c->render(json => { ok => 1, path => $path, seconds => $seconds, flow => $flow });
}

# GET /manager/phone/greeting
#
# Play a recorded greeting. The bytes come from the path the flow names (or,
# for a pane that has just recorded one and not saved yet, the path it holds),
# opened from the house's own media tree and unsealed here when the tree is
# sealed. Nothing outside that tree is readable through this route.
sub action_24764 {
	my $c = shift;
	my $path = $c->param('path') || '';
	if (!length $path) {
		my $flow = $c->param('flow') || '';
		$flow = '' unless $flow =~ /^[a-z0-9_]{1,30}$/;
		if (length $flow) {
			my $defs = &subs::phone_ivr_flow_defs();
			my $def = $defs->{$flow};
			$path = ref $def eq 'HASH' ? ($def->{'voicemail_greeting'} || '') : '';
		}
	}
	require JawnOS::Sco::Audio;
	my $bytes = length $path ? &JawnOS::Sco::Audio::bytes($path) : '';
	unless (length $bytes) {
		$c->rendered(404);
		return;
	}
	$c->res->headers->content_type('audio/wav');
	$c->res->headers->cache_control('no-store');
	$c->render(data => $bytes);
}

# POST /manager/phone/route
#
# One number's own route, set from the routing sheet the Phone app opens. The
# answer carries the resolved route so the sheet never has to guess what the
# person's relationship would have done.
sub action_24761 {
	my $c = shift;
	my $number = $c->param('number') || '';
	my $saved = &phone_route_set($number, $c->param('flow'));
	$saved->{'resolved'} = &phone_route_for($number) if $saved->{'ok'};
	# a number's route decides what the phone does before it rings, so it has to
	# reach the phone now rather than at the next sync
	unless (($c->param('remoted') || '') eq 'yes') {
		eval { &subs::remote_relay_request($c, { dissemination => 'yes' }); };
	}
	$c->render(json => $saved);
}

# GET /manager/phone/route
sub action_24762 {
	my $c = shift;
	$c->render(json => &phone_route_for($c->param('number') || ''));
}

# GET /manager/phone/sync
sub action_24755 {
	my $c = shift;
	# What the app's native phone half needs, handed over in one fetch: the desk's
	# blacklist (the CallScreeningService refuses a listed caller before the phone
	# rings), the house's numbers by name (the in-call screen names the caller, and
	# the app's contact list shows the house's own names), and a small picture per
	# person, as a data URI, for the call screen - who is calling, before the phone
	# has finished ringing. The app wears its own logo for anyone without one.
	my %names = %{ &phone_names() };
	my %avatars;
	foreach my $number ( keys %names ) {
		my $picture = &phone_avatar_data($names{$number});
		$avatars{$number} = $picture if $picture;
	}
	my $ivr = &subs::phone_ivr_broadcast_settings();
	my $ivr_machine = &phone_ivr_machine($ivr->{'machine'});
	$ivr->{'machine_available'} = ($ivr_machine && (($ivr_machine->{'connection'} || '') eq 'active')) ? 1 : 0;
	$ivr->{'machine_host'} = $ivr_machine ? ($ivr_machine->{'hostname'} || $ivr_machine->{'ip'} || '') : '';
	$ivr->{'machine_ip'} = $ivr_machine ? ($ivr_machine->{'ip'} || '') : '';
	&_ivr_audio_state($ivr, $ivr->{'machine'});
	$ivr->{'machine_manager'} = $ivr_machine ? ($ivr_machine->{'manager'} || '') : '';
	# The ordered gateways: each entry carries its own Bluetooth name, online and
	# able flags from the mesh and the crew's ability, and its rank. The scalar
	# machine/bluetooth above remain the first entry for an older app build.
	$ivr->{'machines'} = &phone_ivr_candidates();
	# The app resolves a caller's flow before it rings. It has the numbers and the
	# names, never the house's settings rows, so each entry's lines are resolved
	# here: number -> { flow, kind, label }. The flow keys ride the defs beside it.
	$ivr->{'flow_callers'} = &subs::phone_ivr_caller_index($ivr->{'flow_defs'});
	# Silence is the one rule above the phone's own: every caller hears the
	# receptionist and no number's saved route is offered to the app.
	my $silenced = &subs::silence_active() ? 1 : 0;
	if ($silenced) {
		$ivr->{'silence'} = 1;
		$ivr->{'enabled'} = 'yes';
		$ivr->{'flows'} = { map { $_ => 'ivr' } qw(unknown blacklisted self friend stranger enemy) };
		$ivr->{'flow_callers'} = {};
	}
	$c->render(json => {
		blocked => &ticket_blacklist_numbers(),
		names => \%names,
		relationships => &phone_relationships(),
		routes => $silenced ? {} : &phone_routes_read(),
		avatars => \%avatars,
		ivr => $ivr,
		silence => $silenced,
		ringtone => &phone_ringtone(),
	});
}

# What the pane says about the chosen gateway's audio: the backend word, its own
# readiness, and the reason when it is not ready. A remote gateway is described
# by its advert, which is the only truthful source this machine has; this
# machine answers for itself through JawnOS::Sco::Backend. A gateway that has
# not advertised is not-ready with a plain note rather than an invented stack.
sub _ivr_audio_state {
	my ($ivr, $machine) = @_;
	return $ivr unless ref $ivr eq 'HASH';
	my $self = eval { &phone_self_signatorial() } || '';
	if (length($machine || '') && !(length $self && $machine eq $self)) {
		my $advert_get = eval { UNIVERSAL::can('crew', 'advert_get') };
		my $advert = $advert_get ? eval { $advert_get->($machine) } : undef;
		my $adv = (ref $advert eq 'HASH' && ref $advert->{'abilities'} eq 'HASH'
			&& ref $advert->{'abilities'}{'ivr'} eq 'HASH')
			? $advert->{'abilities'}{'ivr'} : undef;
		my $audio = $adv ? ($adv->{'audio'} || '') : '';
		my $ready = ($adv && $adv->{'ready'}) ? 1 : 0;
		$ivr->{'audio'} = $audio;
		$ivr->{'backend'} = $audio eq 'engine' ? 'engine' : ($adv ? 'pactl' : '');
		$ivr->{'ready'} = $ready;
		$ivr->{'ready_note'} = $ready ? ''
			: ($adv && length($adv->{'ready_note'} || '') ? $adv->{'ready_note'}
				: ($adv ? 'the gateway did not report a reason' : 'the gateway has not reported its audio'));
		return $ivr;
	}
	unless (eval { require JawnOS::Sco::Backend; 1 }) {
		$ivr->{'audio'} = '';
		$ivr->{'backend'} = '';
		$ivr->{'ready'} = 0;
		$ivr->{'ready_note'} = 'the audio backend is not available';
		return $ivr;
	}
	# Ask the way the crew advert does, so the pane and the advert cannot
	# disagree: the engine first when it can carry the gateway, else pactl.
	my $pactl_backend = JawnOS::Sco::Backend->new(backend => 'pactl');
	my $engine_backend = JawnOS::Sco::Backend->new(backend => 'engine');
	# Ask the engine once: a ready engine needs no second probe, and a refused or
	# slow one is not asked again for the same pane.
	my ($engine_ready) = eval { $engine_backend->ready() };
	my ($backend, $ready, $why) = $engine_ready
		? ($engine_backend, 1, '')
		: ($pactl_backend, ($pactl_backend->ready())[0, 1]);
	$ivr->{'audio'} = $backend->audio();
	$ivr->{'backend'} = $backend->name();
	$ivr->{'ready'} = $ready ? 1 : 0;
	$ivr->{'ready_note'} = $ready ? '' : ($why || 'the audio backend is not ready');
	return $ivr;
}

# POST /manager/phone/lines
# The Lines pane: the numbers this machine answers on. The phone's own SIMs are
# written by the telephone poll (`telephone_own_number_check`), so this is how a
# VoIP line is named - Fongo and TextNow keep their number inside their own app,
# which nothing here may read, so the only way to know one is to be told. A line
# is keyed by its label, so saving the same label again replaces that number.
sub action_91842 {
	my $c = shift;
	my $action = $c->param('action') || 'add';
	my $label = $c->param('label') || '';
	my $host = &subs::own_phone_host();
	$label = lc($label);
	$label =~ s/[^a-z0-9_-]+//g;
	if ($action eq 'remove') {
		if (length $label) {
			&subs::setting_setter({ app => $label, setting => 'own_phone', value => '', device => $host });
		}
		$c->render(json => { ok => 1, lines => &subs::own_phone_lines($host) });
		return;
	}
	my $number = $c->param('number') || '';
	$number =~ s/\D+//g;
	$number =~ s/^1//;
	unless (length $number >= 7 && length $number <= 15) {
		$c->render(json => { ok => 0, error => 'not a phone number', lines => &subs::own_phone_lines($host) });
		return;
	}
	# a number cannot be its own line twice under two names
	foreach my $line ( @{ &subs::own_phone_lines($host) } ) {
		next if $line->{'number'} ne $number;
		next if $label && $line->{'label'} eq $label;
		&subs::setting_setter({ app => $line->{'label'}, setting => 'own_phone', value => '', device => $host });
	}
	$label = 'line' unless length $label;
	&subs::setting_setter({ app => $label, setting => 'own_phone', value => $number, device => $host });
	$c->render(json => { ok => 1, lines => &subs::own_phone_lines($host) });
}

# POST /manager/phone/ringtone
sub action_24765 {
	my $c = shift;
	# The Ringtone pane's save. The value is the house's notifications/ path; the
	# per-device setting is what /manager/phone/sync hands the phone, and the app
	# plays that file under public/sounds/.
	my $ringtone = $c->param('ringtone') || '';
	my %allowed = map { $_ => 1 } qw( notifications/ring.mp3 notifications/chime.mp3 notifications/sonar.mp3 );
	unless ($allowed{$ringtone}) {
		$c->render(json => { ok => 0, error => 'unknown ringtone' });
		return;
	}
	&subs::setting_setter({ app => 'phone', setting => 'ringtone', device => &subs::device_setter(), value => $ringtone });
	$c->render(json => { ok => 1, ringtone => $ringtone });
}

1;
