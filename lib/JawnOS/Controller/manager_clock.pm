package Manager;

# manager_clock: route actions moved out of Manager.pl, one sub per route so a
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

# --- Clock: alarms, stopwatch, timers and world clocks ----------------------
# The four faces share one window. Alarms and timers are stored server-side so
# they fire, and can start and stop appointments, even when no browser is open;
# the stopwatch and the world clock list are the browser's own.
# GET /manager/clock
sub action_22718 {
	my $c = shift;
	my $tab = $c->param('tab') || 'alarm';
	$tab = 'alarm' unless $tab =~ /^(?:alarm|stopwatch|timer|world)$/;
	my $state = &subs::clock_state();
	my $content = $c->render_to_string(
		template => 'apps/clock',
		tab => $tab,
		alarms => $state->{'alarms'},
		timers => $state->{'timers'},
		apps => $state->{'apps'},
		sounds => $state->{'sounds'},
		alarm_sounds => $state->{'alarm_sounds'},
		machines => $state->{'machines'},
		nfc_apps => $state->{'nfc_apps'},
		max => $state->{'max'},
	);
	my $contents = &window_maker({ user_agent => $c->param('user_agent'), app => 'clock', title => &subs::lang('clock'), contents => $content }, $c->param('timestamp'));
	$c->render(text => $contents);
}

# GET /manager/clock/state
sub action_22738 {
	my $c = shift;
	$c->render(json => &subs::clock_state());
}

# One route for every alarm edit. The client asks for the state back, so a save
# and the list it lands in can never disagree.
# POST /manager/clock/alarm
sub action_22744 {
	my $c = shift;
	my $action = $c->param('action') || 'save';
	my $now = &subs::rightNow();
	# The route is on the peer rail too: a machine has no session cookie, so the
	# signed request (or its pinned key) is what authorizes an incoming edit.
	my $peer_sig = $c->param('signatorial') || '';
	my $peer_rm = $peer_sig ? &subs::db_select('remote_machines', undef, { signatorial => $peer_sig })->hash : undef;
	unless (($c->session('authentication') eq 'approved'
			&& !&subs::guest_browser_session($c->session('privilege'), $c->session('source')))
		|| ($peer_rm && $peer_rm->{'pubkey'} && &subs::peer_verify($c, $peer_rm)) || &app_peer_ok($c)) {
		return $c->rendered(403);
	}
	# A machine that is ringing tells the rest of the house, so a Manager window
	# on any of them can draw the ring card. This is a display notice, not an
	# edit: the shared row stays the source for ringing and stop_at.
	if ($action eq 'ring_notice') {
		my $uuid = $c->param('uuid') || '';
		my $alarms = &subs::clock_alarms_read();
		my ($alarm) = grep { ($_->{'uuid'} || '') eq $uuid } @{$alarms};
		if (!$alarm) {
			$c->render(json => { ok => 0, error => 'missing', server_time => $now });
			return;
		}
		my $at = $c->param('at');
		$at = $now unless defined $at && "$at" =~ /^\d+$/ && $at > 0;
		&subs::clock_alarm_cmd($alarm, $at, $now);
		$c->render(json => { ok => 1, server_time => $now });
		return;
	}
	# An edit a peer hands over is applied here and, when it names a third
	# machine, forwarded once. It never writes through the UI branches below.
	if ($action eq 'remote_apply') {
		my $op = ($c->param('op') || '') eq 'delete' ? 'delete' : 'upsert';
		my $uuid = $c->param('uuid') || '';
		my $alarm = {};
		if ($op eq 'upsert') {
			my $raw = $c->param('alarm') || '';
			$alarm = eval { decode_json($raw) } || {};
			$alarm = {} unless ref $alarm eq 'HASH';
			$alarm->{'uuid'} = $uuid if length $uuid;
			$alarm->{'updated'} = int($c->param('updated') || $alarm->{'updated'} || $now);
		}
		else {
			$alarm = { uuid => $uuid, updated => int($c->param('updated') || $now) };
		}
		my $applied = &subs::clock_apply_remote_alarm($alarm, $op, $now);
		my $forwarded = [];
		my $forward_to = $c->param('forward_to') || '';
		if (length $forward_to) {
			my @targets = grep { defined $_ && length $_ } split /,/, $forward_to;
			if (scalar @targets) {
				my $res = &subs::clock_alarm_push($alarm, $op, \@targets, $now, 0);
				$forwarded = $res->{'delivered'} || [];
			}
		}
		$c->render(json => { ok => 1, applied => $applied, forwarded => $forwarded, server_time => $now });
		return;
	}
	my $lock = &subs::clock_lock_take();
	my $alarms = &subs::clock_alarms_read();
	my $error = '';
	# What changed, so the same edit can be pushed to the named machines at once.
	my $changed_alarm;
	my $changed_op = '';
	my $push_machines = [];
	# The machines that carry the alarm this request names, kept before a delete
	# can remove the row. Everyone named gets the stop, so one person's Dismiss
	# ends it on every machine.
	my $relay_uuid = $c->param('uuid') || '';
	my $relay_machines = [];
	if (length $relay_uuid) {
		my ($found) = grep { ($_->{'uuid'} || '') eq $relay_uuid } @{$alarms};
		$relay_machines = $found->{'machines'} || [] if $found;
	}

	if ($action eq 'add') {
		if (scalar @{$alarms} >= 10) {
			$error = 'full';
		}
		else {
			my @lt = localtime(int($now / 1000));
			my $hour = ($lt[2] + 1) % 24;
			push @{$alarms}, &subs::clock_normalize_alarm({
				uuid => &subs::random_string_creator(24),
				hour => $hour,
				minute => 0,
				days => [],
				enabled => 1,
				label => &subs::lang('alarm'),
				sound => 'notifications/ring.mp3',
				volume => 70,
				ramp => 60,
				snooze => 5,
				machines => [ &subs::signatorial_designer() || '' ],
				updated => $now,
				created => $now,
			});
			$changed_alarm = $alarms->[-1];
			$changed_op = 'upsert';
			$push_machines = $changed_alarm->{'machines'} || [];
		}
	}
	elsif ($action eq 'delete') {
		my $uuid = $c->param('uuid') || '';
		@{$alarms} = grep { ($_->{'uuid'} || '') ne $uuid } @{$alarms};
		$changed_alarm = { uuid => $uuid, updated => $now };
		$changed_op = 'delete';
		$push_machines = $relay_machines;
	}
	elsif ($action eq 'stop_all') {
		foreach my $a (@{$alarms}) {
			$a->{'snooze_until'} = 0;
			$a->{'ringing'} = 0;
			$a->{'ring_started'} = 0;
			$a->{'ring_last'} = 0;
			$a->{'stop_at'} = $now;
			$a->{'updated'} = $now;
		}
		$changed_op = 'stop_all';
		$push_machines = [ map { $_->{'value'} } @{ &subs::clock_machines() } ];
	}
	elsif ($action eq 'dismiss' || $action eq 'snooze') {
		my $uuid = $c->param('uuid') || '';
		my ($alarm) = grep { ($_->{'uuid'} || '') eq $uuid } @{$alarms};
		if (!$alarm) {
			$error = 'missing';
		}
		elsif ($action eq 'dismiss') {
			$alarm->{'snooze_until'} = 0;
			$alarm->{'ringing'} = 0;
			$alarm->{'ring_started'} = 0;
			$alarm->{'ring_last'} = 0;
			$alarm->{'stop_at'} = $now;
			$alarm->{'updated'} = $now;
		}
		else {
			my $minutes = $c->param('minutes');
			$minutes = $alarm->{'snooze'} unless defined $minutes && "$minutes" =~ /^\d+$/;
			$minutes = 5 unless defined $minutes && "$minutes" =~ /^\d+$/;
			$minutes = 1 if $minutes < 1;
			$minutes = 60 if $minutes > 60;
			$alarm->{'snooze_until'} = $now + ($minutes * 60000);
			$alarm->{'ringing'} = 0;
			$alarm->{'ring_started'} = 0;
			$alarm->{'ring_last'} = 0;
			$alarm->{'stop_at'} = $now;
			$alarm->{'updated'} = $now;
		}
		$changed_alarm = $alarm;
		$changed_op = 'upsert';
		$push_machines = $alarm->{'machines'} || $relay_machines;
	}
	elsif ($action eq 'skip') {
		my $uuid = $c->param('uuid') || '';
		my ($alarm) = grep { ($_->{'uuid'} || '') eq $uuid } @{$alarms};
		if (!$alarm) {
			$error = 'missing';
		}
		else {
			# Skip the occurrence that is coming (or the snooze that stands in
			# for it) without touching the days or the switch. An alarm already
			# ringing is today's; stopping it is the skip, so tomorrow stays.
			my $next;
			if ($alarm->{'snooze_until'} && $alarm->{'snooze_until'} > $now) {
				$next = $alarm->{'snooze_until'};
			}
			elsif ($alarm->{'ringing'}) {
				$next = $now;
			}
			else {
				$next = &subs::clock_alarm_next_ms($alarm, $now);
			}
			$alarm->{'skip_fire'} = $next || 0;
			$alarm->{'snooze_until'} = 0;
			$alarm->{'ringing'} = 0;
			$alarm->{'ring_started'} = 0;
			$alarm->{'ring_last'} = 0;
			$alarm->{'stop_at'} = $now;
			$alarm->{'updated'} = $now;
			$changed_alarm = $alarm;
			$changed_op = 'upsert';
			$push_machines = $alarm->{'machines'} || $relay_machines;
		}
	}
	elsif ($action eq 'toggle') {
		my $uuid = $c->param('uuid') || '';
		my ($alarm) = grep { ($_->{'uuid'} || '') eq $uuid } @{$alarms};
		if (!$alarm) {
			$error = 'missing';
		}
		else {
			$alarm->{'enabled'} = ($c->param('enabled') && $c->param('enabled') ne '0' && $c->param('enabled') ne 'off') ? 1 : 0;
			$alarm->{'last_fire'} = 0 unless $alarm->{'enabled'};
			if (!$alarm->{'enabled'}) {
				$alarm->{'ringing'} = 0;
				$alarm->{'ring_started'} = 0;
				$alarm->{'ring_last'} = 0;
				$alarm->{'stop_at'} = $now;
			}
			$alarm->{'updated'} = $now;
			$changed_alarm = $alarm;
			$changed_op = 'upsert';
			$push_machines = $alarm->{'machines'} || $relay_machines;
		}
	}
	elsif ($action eq 'save') {
		my $uuid = $c->param('uuid') || '';
		my ($alarm) = grep { ($_->{'uuid'} || '') eq $uuid } @{$alarms};
		if (!$alarm) {
			$error = 'missing';
		}
		else {
			$alarm->{'hour'} = $c->param('hour') if defined $c->param('hour') && $c->param('hour') =~ /^\d+$/;
			$alarm->{'minute'} = $c->param('minute') if defined $c->param('minute') && $c->param('minute') =~ /^\d+$/;
			$alarm->{'label'} = $c->param('label') if defined $c->param('label');
			if (defined $c->param('days')) {
				$alarm->{'days'} = [ split /,/, $c->param('days') ];
			}
			if (defined $c->param('app')) {
				my $app = $c->param('app');
				$app =~ s/^\s+//; $app =~ s/\s+$//;
				$alarm->{'app'} = length $app ? &subs::unformat_name($app) : '';
			}
			if (defined $c->param('machines') && length $c->param('machines')) {
				$alarm->{'machines'} = [ split /,/, $c->param('machines') ];
			}
			$alarm->{'sound'} = $c->param('sound') if defined $c->param('sound') && length &subs::clock_valid_alarm_sound($c->param('sound'));
			$alarm->{'volume'} = $c->param('volume') if defined $c->param('volume') && $c->param('volume') =~ /^\d+$/;
			$alarm->{'ramp'} = $c->param('ramp') if defined $c->param('ramp') && $c->param('ramp') =~ /^\d+$/;
			$alarm->{'snooze'} = $c->param('snooze') if defined $c->param('snooze') && $c->param('snooze') =~ /^\d+$/;
			$alarm->{'play'} = (($c->param('play') // '') eq 'math') ? 'math' : '' if defined $c->param('play');
			$alarm->{'nfc'} = ($c->param('nfc') && $c->param('nfc') ne '0' && $c->param('nfc') ne 'off') ? 1 : 0 if defined $c->param('nfc');
			$alarm->{'nfc_action'} = (($c->param('nfc_action') // '') eq 'dismiss') ? 'dismiss' : 'snooze' if defined $c->param('nfc_action');
			$alarm->{'enabled'} = ($c->param('enabled') && $c->param('enabled') ne '0' && $c->param('enabled') ne 'off') ? 1 : 0 if defined $c->param('enabled');
			$alarm->{'updated'} = $now;
			$alarm = &subs::clock_normalize_alarm($alarm);
			$alarm->{'updated'} = $now;
			if (!$alarm->{'enabled'}) {
				$alarm->{'ringing'} = 0;
				$alarm->{'ring_started'} = 0;
				$alarm->{'ring_last'} = 0;
				$alarm->{'stop_at'} = $now;
			}
			for my $i (0 .. $#{$alarms}) {
				if (($alarms->[$i]->{'uuid'} || '') eq $uuid) { $alarms->[$i] = $alarm; last; }
			}
			$changed_alarm = $alarm;
			$changed_op = 'upsert';
			# A save can remove a machine as well as add one, and the machine taken
			# off still has the alarm armed (or ringing) until the row sync reaches
			# it. Push to both the old and the new selection so every affected
			# machine hears about the change now.
			my %push_to = map { $_ => 1 } (@{ $alarm->{'machines'} || [] }, @{ $relay_machines || [] });
			$push_machines = [ keys %push_to ];
		}
	}

	&subs::clock_alarms_write($alarms) unless length $error;
	&subs::clock_lock_drop($lock);
	&subs::clock_write_device_alarm($alarms, $now) unless length $error;
	if ($action eq 'stop_all') {
		foreach my $a (@{$alarms}) { &subs::clock_alarm_stop_sound($a->{'uuid'}); }
	}
	elsif ($action =~ /^(?:dismiss|snooze|skip|toggle|save|delete)$/) {
		&subs::clock_alarm_stop_sound($c->param('uuid') || '');
	}
	&subs::clock_poke($now);
	my $rings_stopped = ($action =~ /^(?:dismiss|snooze|skip|delete|stop_all)$/) ? 1 : 0;
	if (!$rings_stopped && ($action eq 'toggle' || $action eq 'save') && defined $c->param('enabled') && !$c->param('enabled')) {
		$rings_stopped = 1;
	}
	&subs::clock_send_console(&Websocket::console_command('jawnosClockAlarmStop')) if $rings_stopped;
	&subs::clock_device_dismissed($action eq 'stop_all' ? '' : ($c->param('uuid') || '')) if $rings_stopped;
	# The shared settings row carries the stop to every machine in time; this
	# relay is what ends the sound now rather than at the next sync. A request
	# that arrived this way does not relay again. Dismiss and Snooze also go to
	# the machines that are only showing the ring card, so every open Manager
	# window closes with the sound instead of waiting for the row to sync.
	if ($rings_stopped && !$c->param('relayed')) {
		my $everywhere = ($action eq 'stop_all' || $action eq 'dismiss' || $action eq 'snooze');
		my $machines = $everywhere
			? [ map { $_->{'value'} } @{ &subs::clock_machines() } ]
			: $relay_machines;
		my %extra;
		$extra{'minutes'} = $c->param('minutes') if $action eq 'snooze';
		&subs::clock_relay($action eq 'snooze' ? 'snooze' : 'dismiss', ($action eq 'stop_all' ? '' : $relay_uuid), $machines, %extra);
	}
	# The row sync is eventual; this is the immediate, confirmed push. It runs in
	# the background so a slow peer never holds the person's save open, and each
	# answer lands in the alarm's delivered map for the next state read.
	if (!length $error && !$c->param('relayed') && $changed_op) {
		my @jobs;
		if ($changed_op eq 'stop_all') {
			@jobs = map { [ $_, 'upsert' ] } @{$alarms};
		}
		elsif ($changed_alarm) {
			@jobs = ( [ $changed_alarm, $changed_op ] );
		}
		my $wanted = scalar @{$push_machines}
			? $push_machines
			: [ map { $_->{'value'} } @{ &subs::clock_machines() } ];
		my $machines = [ grep { defined $_ && length $_ } @{$wanted} ];
		if (scalar @jobs) {
			&subs::subprocessor(sub {
				foreach my $job (@jobs) {
					eval { &subs::clock_alarm_push($job->[0], $job->[1], $machines, $now); };
				}
			}, { name => 'clock alarm push' });
		}
	}
	my $state = &subs::clock_state();
	$state->{'ok'} = length $error ? 0 : 1;
	$state->{'error'} = $error;
	$c->render(json => $state);
}

# Hear the alarm's chosen sound on this machine, or stop it. The sound belongs
# to the operating system, as the ring itself does; the browser only asks.
# POST /manager/clock/preview
sub action_23042 {
	my $c = shift;
	my $action = $c->param('action') || 'play';
	if ($action eq 'stop') {
		&subs::clock_preview_stop();
		$c->render(json => { ok => 1 });
		return;
	}
	my $sound = &subs::clock_valid_alarm_sound($c->param('sound')) || 'notifications/ring.mp3';
	my $volume = $c->param('volume');
	&subs::clock_preview_play($sound, $volume);
	$c->render(json => { ok => 1, sound => $sound });
}

# One route for every timer change. A timer that names an appointment starts it
# on the way in and stops that very session on the way out; the timer row keeps
# the appointment's uuid so the stop names its own session and never another.
# POST /manager/clock/timer
sub action_23058 {
	my $c = shift;
	my $action = $c->param('action') || 'start';
	my $now = &subs::rightNow();
	my $lock = &subs::clock_lock_take();
	my $timers = &subs::clock_timers_read();
	my $error = '';
	my $poke;

	if ($action eq 'start') {
		my $running = scalar grep { ($_->{'state'} || '') eq 'running' } @{$timers};
		my $hours = ($c->param('hours') || 0) =~ /^\d+$/ ? int($c->param('hours') || 0) : 0;
		my $minutes = ($c->param('minutes') || 0) =~ /^\d+$/ ? int($c->param('minutes') || 0) : 0;
		my $seconds = ($c->param('seconds') || 0) =~ /^\d+$/ ? int($c->param('seconds') || 0) : 0;
		my $length = ($hours * 3600) + ($minutes * 60) + $seconds;
		if ($running >= 10) {
			$error = 'full';
		}
		elsif ($length < 1 || $length > 359999) {
			$error = 'time';
		}
		else {
			my $label = $c->param('label') || &subs::lang('timer');
			$label =~ s/^\s+//; $label =~ s/\s+$//;
			my $app = $c->param('app') || '';
			$app =~ s/^\s+//; $app =~ s/\s+$//;
			$app = length $app ? &subs::unformat_name($app) : '';
			my $sound = &subs::clock_valid_timer_sound($c->param('sound'));
			my $timer = &subs::clock_normalize_timer({
				uuid => &subs::random_string_creator(24),
				label => $label,
				seconds => $length,
				started_at => $now,
				ends_at => $now + ($length * 1000),
				state => 'running',
				app => $app,
				sound => $sound,
				volume => $c->param('volume'),
				created => $now,
			});
			if ($app) {
				my $open = &subs::open_session_uuid($app);
				if ($open) {
					$timer->{'appt_uuid'} = $open;
				}
				else {
					my $started = &appointment_writer($c, {
						app => $app,
						type => 'start',
						timestamp => $now,
						server_time => $now,
					});
					$timer->{'appt_uuid'} = $started->{'uuid'} if $started->{'uuid'};
				}
			}
			push @{$timers}, $timer;
			$poke = $timer->{'ends_at'};
		}
	}
	elsif ($action eq 'stop' || $action eq 'delete') {
		my $uuid = $c->param('uuid') || '';
		my ($timer) = grep { ($_->{'uuid'} || '') eq $uuid } @{$timers};
		if (!$timer) {
			$error = 'missing';
		}
		elsif (($timer->{'state'} || '') eq 'running') {
			$timer->{'state'} = 'cancelled';
			$timer->{'ended_at'} = $now;
			if ($timer->{'app'} && $timer->{'appt_uuid'}) {
				&appointment_writer($c, {
					app => $timer->{'app'},
					type => 'stop',
					uuid => $timer->{'appt_uuid'},
					timestamp => $now,
					server_time => $now,
				});
			}
			if ($action eq 'delete') {
				@{$timers} = grep { ($_->{'uuid'} || '') ne $uuid } @{$timers};
			}
		}
		elsif ($action eq 'delete') {
			@{$timers} = grep { ($_->{'uuid'} || '') ne $uuid } @{$timers};
		}
	}
	elsif ($action eq 'restore') {
		my $uuid = $c->param('uuid') || '';
		my ($timer) = grep { ($_->{'uuid'} || '') eq $uuid } @{$timers};
		my $running = scalar grep { ($_->{'state'} || '') eq 'running' } @{$timers};
		if (!$timer) {
			$error = 'missing';
		}
		elsif (($timer->{'state'} || '') eq 'running') {
			$error = 'running';
		}
		elsif ($running >= 10) {
			$error = 'full';
		}
		else {
			# A finished timer is a recipe: restore puts the same length, name and
			# link back on the clock, and the appointment it names starts again.
			$timer->{'state'} = 'running';
			$timer->{'started_at'} = $now;
			$timer->{'ends_at'} = $now + (($timer->{'seconds'} || 1) * 1000);
			$timer->{'ended_at'} = 0;
			$timer->{'appt_uuid'} = '';
			if ($timer->{'app'}) {
				my $open = &subs::open_session_uuid($timer->{'app'});
				if ($open) {
					$timer->{'appt_uuid'} = $open;
				}
				else {
					my $started = &appointment_writer($c, {
						app => $timer->{'app'},
						type => 'start',
						timestamp => $now,
						server_time => $now,
					});
					$timer->{'appt_uuid'} = $started->{'uuid'} if $started->{'uuid'};
				}
			}
			$poke = $timer->{'ends_at'};
		}
	}
	elsif ($action eq 'clear_finished') {
		@{$timers} = grep { ($_->{'state'} || '') eq 'running' } @{$timers};
	}

	&subs::clock_timers_write($timers) unless length $error;
	&subs::clock_lock_drop($lock);
	&subs::clock_poke($now);
	my $state = &subs::clock_state();
	$state->{'ok'} = length $error ? 0 : 1;
	$state->{'error'} = $error;
	$c->render(json => $state);
}

1;
