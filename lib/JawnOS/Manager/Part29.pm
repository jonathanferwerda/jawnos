package Manager;

# Manager helpers, part 29 of 37. Moved out of Manager.pl so a
# helper can be read and changed without opening 24k lines. The package is
# still Manager, and lib/JawnOS/Manager/Index.pm maps every sub name here to
# this file; Manager.pm loads it on the first call.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

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
use Mojo::IOLoop::ReadWriteFork;
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
use IO::Socket::UNIX;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

sub guide_appointment_identity {
	my ($app, $app_uuid) = @_;
	$app = &subs::unformat_name($app || '');
	return ('app = ?', [ $app ]) unless defined $app_uuid && length $app_uuid;
	return ("(app_uuid = ? or (app = ? and (app_uuid is null or app_uuid = '')))", [ $app_uuid, $app ]);
}

sub guide_find_target($app, $opts) {
	$opts = {} unless ref $opts eq 'HASH';
	$app = &subs::unformat_name($app || '');
	my ($id_where, $id_args) = &guide_appointment_identity($app, $opts->{'app_uuid'});
	return undef unless length $app || @{$id_args} > 1;
	my $now = &subs::rightNow();
	my $which = lc($opts->{'which'} // '');
	if ($which =~ /^(?:upcoming|next|soon|future)$/) {
		my $r = &subs::db_query("select * from appointments where $id_where and uuid is not null and timestamp >= ? order by timestamp asc limit 1", @{$id_args}, $now)->hashes;
		return $r->[0] if scalar @{$r};
	}
	if ($which =~ /^(?:last|previous|past|latest)$/) {
		my $r = &subs::db_query("select * from appointments where $id_where and uuid is not null and timestamp <= ? order by timestamp desc limit 1", @{$id_args}, $now)->hashes;
		return $r->[0] if scalar @{$r};
	}
	if (defined $opts->{'at'} && $opts->{'at'} =~ /\S/) {
		my $ms = &guide_when_ms($opts->{'at'});
		my $r = &subs::db_query("select * from appointments where $id_where and uuid is not null order by abs(timestamp - ?) asc limit 1", @{$id_args}, $ms)->hashes;
		return $r->[0] if scalar @{$r};
	}
	if (defined $opts->{'title'} && $opts->{'title'} =~ /\S/) {
		my $by_title = &subs::db_query("select * from appointments where $id_where and uuid is not null and notes like ? order by timestamp desc limit 1", @{$id_args}, '%' . $opts->{'title'} . '%')->hashes;
		return $by_title->[0] if scalar @{$by_title};
	}
	my $rows = &subs::db_query("select * from appointments where $id_where and uuid is not null order by timestamp desc limit 1", @{$id_args})->hashes;
	return $rows->[0];
}

sub guide_update_changes($target, $p) {
	my %c;
	if (defined $p->{'delay'} && $p->{'delay'} =~ /\S/) {
		my $ms = &guide_duration_ms($p->{'delay'}, 'usual');
		$c{'timestamp'} = ($target->{'timestamp'} + 0) + $ms if defined $ms && $ms != 0;
	}
	if (defined $p->{'when'} && $p->{'when'} =~ /\S/) {
		my $w = &guide_when_ms($p->{'when'});
		$c{'timestamp'} = $w if defined $w;
	}
	if (defined $p->{'duration'} && $p->{'duration'} =~ /\S/) {
		my $d = &guide_duration_ms($p->{'duration'}, $target->{'type'});
		$c{'duration'} = $d if defined $d && $d != 0;
	}
	if (defined $p->{'notes'} && length $p->{'notes'}) {
		$c{'notes'} = $p->{'notes'};
	}
	return \%c;
}

sub guide_length_words($ms) {
	my $mins = int(abs($ms + 0) / 60000);
	return $mins . ' min' if $mins < 60;
	my $h = int($mins / 60);
	my $m = $mins % 60;
	return $h . 'h' . ($m ? (' ' . $m . 'm') : '');
}

sub guide_update_summary($target, $changes) {
	my $who = &subs::format_name($target->{'app'});
	my @parts;
	if (exists $changes->{'timestamp'}) {
		my $delta = $changes->{'timestamp'} - ($target->{'timestamp'} + 0);
		my $word = $delta >= 0 ? 'delay' : 'bring forward';
		push @parts, $word . ' "' . $who . '" by ' . &guide_length_words($delta)
			. ' (to ' . localtime($changes->{'timestamp'} / 1000)->strftime('%b %e, %I:%M%p') . ')';
	}
	if (exists $changes->{'duration'}) {
		push @parts, 'set "' . $who . '" to last ' . &guide_length_words($changes->{'duration'});
	}
	if (exists $changes->{'notes'}) {
		push @parts, 'change the note on "' . $who . '"';
	}
	return join(', and ', @parts);
}

sub guide_stage_change($target, $changes, $summary) {
	my $uuid = &subs::random_string_creator(40);
	&subs::db_insert('staged_appointments', {
		uuid => $uuid, staged_time => &subs::rightNow(), source => 'guide',
		kind => 'update', target_uuid => $target->{'uuid'},
		app => $target->{'app'}, type => ($target->{'type'} || 'usual'),
		timestamp => (exists $changes->{'timestamp'} ? $changes->{'timestamp'} : $target->{'timestamp'}),
		title => $summary, notes => '', data => '',
		changes => encode_json $changes,
		duration => (exists $changes->{'duration'} ? $changes->{'duration'} : ($target->{'duration'} || '')),
		device => &subs::device_setter(), status => 'pending'
	});
	return { staged => $uuid, app => $target->{'app'}, kind => 'update', summary => $summary, timestamp => $changes->{'timestamp'} };
}

sub guide_stage_update($c, $params) {
	my $app = $params->{'app'} || '';
	my $target = &guide_find_target($app, { title => $params->{'title'}, app_uuid => $params->{'app_uuid'} });
	return { error => 'I could not find "' . ($app || 'that') . '" to change' } unless $target;
	my $changes = &guide_update_changes($target, $params);
	return { error => 'nothing to change' } unless scalar keys %{$changes};
	return &guide_stage_change($target, $changes, &guide_update_summary($target, $changes));
}

sub guide_open_target($app, $app_uuid) {
	$app = &subs::unformat_name($app || '');
	my ($id_where, $id_args) = &guide_appointment_identity($app, $app_uuid);
	return undef unless length $app || @{$id_args} > 1;
	my $rows = &subs::db_query("select * from appointments where $id_where and uuid is not null and type in (?,?,?,?,?) and timestamp <= ? and stop_seen is null order by timestamp desc limit 1", @{$id_args}, 'start','record','video','audio','screen', &subs::rightNow())->hashes;
	return $rows->[0];
}

sub guide_stop_when($when) {
	my $now = &subs::rightNow();
	return $now unless defined $when && $when =~ /\S/;
	my $s = lc $when;
	$s =~ s/^\s+|\s+$//g;
	return $now if $s eq 'now';
	if ($s =~ /^(?:in\s+)?\d/) {
		my $ms = &guide_duration_ms($when, 'usual');
		return $now + $ms if defined $ms && $ms != 0;
	}
	return &guide_when_ms($when);
}

sub guide_stop_appointment($c, $params) {
	my $app = $params->{'app'} || '';
	my $target = &guide_open_target($app, $params->{'app_uuid'});
	return { error => 'nothing of "' . (&subs::format_name(&subs::unformat_name($app)) || $app) . '" is running to stop' } unless $target;
	my $ts = &guide_stop_when($params->{'when'});
	&guide_undo_push({
		app => $target->{'app'}, uuid => $target->{'uuid'}, title => 'stop "' . &subs::format_name($target->{'app'}) . '"',
		timestamp => $target->{'timestamp'}, duration => $target->{'duration'}, notes => $target->{'notes'},
		seen => $target->{'seen'}, stop_seen => $target->{'stop_seen'},
		type => $target->{'type'}, stop_timestamp => $target->{'stop_timestamp'},
	});
	if ($ts <= &subs::rightNow() + 1000) {
		# name the session so the writer closes exactly it - the same hard match the
		# stop button uses - and not whichever session a stale copy might fall back to
		&Manager::appointment_writer($c, { app => $target->{'app'}, uuid => $target->{'uuid'}, type => 'stop', timestamp => &subs::rightNow(), server_time => &subs::rightNow() });
	}
	else {
		&subs::db_update('appointments', { stop_timestamp => $ts, stop_seen => undef, server_time => &subs::rightNow() }, { uuid => $target->{'uuid'}, app => $target->{'app'} });
		my $fresh = &subs::db_select('appointments', undef, { uuid => $target->{'uuid'} })->hash;
		&subs::appt_alarm_setter($fresh) if $fresh;
	}
	&subs::appt_toggle_checker($target->{'app'});
	&guide_refresh_app($target->{'app'}, $target->{'uuid'});
	my $when_words = $ts <= &subs::rightNow() + 1000 ? 'now' : ('at ' . localtime($ts / 1000)->strftime('%b %e, %I:%M%p'));
	return { ok => 1, app => $target->{'app'}, summary => 'stopping "' . &subs::format_name($target->{'app'}) . '" ' . $when_words };
}

sub guide_stage_delete($c, $params) {
	my $app = $params->{'app'} || '';
	my $target = &guide_find_target($app, { title => $params->{'title'}, at => $params->{'when'}, which => $params->{'which'}, app_uuid => $params->{'app_uuid'} });
	return { error => 'I could not find that appointment' } unless $target;
	my $uuid = &subs::random_string_creator(40);
	my $when_words = localtime(($target->{'timestamp'} + 0) / 1000)->strftime('%b %e, %I:%M%p');
	my $summary = 'delete the "' . &subs::format_name($target->{'app'}) . '" appointment at ' . $when_words
		. ($target->{'notes'} ? (' (' . substr($target->{'notes'}, 0, 40) . ')') : '');
	&subs::db_insert('staged_appointments', {
		uuid => $uuid, staged_time => &subs::rightNow(), source => 'guide',
		kind => 'delete', target_uuid => $target->{'uuid'},
		app => $target->{'app'}, type => ($target->{'type'} || 'usual'),
		timestamp => $target->{'timestamp'}, title => $summary, notes => '', data => '',
		device => &subs::device_setter(), status => 'pending'
	});
	return { staged => $uuid, app => $target->{'app'}, kind => 'delete', summary => $summary, timestamp => $target->{'timestamp'} };
}

sub guide_undo_push($rec) {
	my $stack = eval { decode_json(&subs::setting_grabber({ app => 'me', setting => 'guide_undo' }) || '[]') } || [];
	$stack = [] unless ref $stack eq 'ARRAY';
	push @{$stack}, $rec;
	splice @{$stack}, 0, scalar(@{$stack}) - 10 if scalar @{$stack} > 10;
	&subs::setting_setter({ app => 'me', setting => 'guide_undo', value => encode_json $stack });
}

sub guide_undo_pop() {
	my $stack = eval { decode_json(&subs::setting_grabber({ app => 'me', setting => 'guide_undo' }) || '[]') } || [];
	$stack = [] unless ref $stack eq 'ARRAY';
	my $rec = pop @{$stack};
	&subs::setting_setter({ app => 'me', setting => 'guide_undo', value => encode_json $stack });
	return $rec;
}

sub guide_refresh_app($app, $uuid) {
	&subs::appt_header_printer({ app => $app, timestamp => &subs::rightNow() });
	my $js = 'appointmentDetailGrabber(' . encode_json($app) . ',' . encode_json($uuid) . ');';
	&Websocket::send('tab', { console => $js });
	&Websocket::send('server', { console => $js });
}

sub guide_promote_update($c, $row) {
	my $changes = eval { decode_json($row->{'changes'} || '{}') } || {};
	return { error => 'nothing to change' } unless ref $changes eq 'HASH' && scalar keys %{$changes};
	my $target = &subs::db_select('appointments', undef, { uuid => $row->{'target_uuid'} })->hash;
	return { error => 'that appointment is gone' } unless $target;
	&guide_undo_push({
		app => $target->{'app'}, uuid => $target->{'uuid'}, title => $row->{'title'},
		timestamp => $target->{'timestamp'}, duration => $target->{'duration'}, notes => $target->{'notes'},
		seen => $target->{'seen'}, stop_seen => $target->{'stop_seen'},
		type => $target->{'type'}, stop_timestamp => $target->{'stop_timestamp'},
	});
	my %set = %{$changes};
	$set{'server_time'} = &subs::rightNow();
	# a change that moves the moment of an appointment that has already happened has
	# to re-arm the alarm: the clock only runs what it has not seen, so clear the seen
	# flags the row carried, or a delayed appointment would never fire again
	if (exists $changes->{'timestamp'} && ($target->{'timestamp'} + 0) <= &subs::rightNow()) {
		$set{'seen'} = undef;
		$set{'stop_seen'} = undef;
	}
	&subs::db_update('appointments', \%set, { uuid => $target->{'uuid'}, app => $target->{'app'} });
	# the app's toggle tracks whether a start/record is open, so it is read again now
	# the moment moved
	&subs::appt_toggle_checker($target->{'app'});
	&guide_refresh_app($target->{'app'}, $target->{'uuid'});
	&subs::db_update('staged_appointments', { status => 'promoted' }, { uuid => $row->{'uuid'} });
	return { promoted => $row->{'uuid'}, uuid => $target->{'uuid'}, app => $target->{'app'}, kind => 'update', summary => $row->{'title'} };
}

sub guide_promote_delete($c, $row) {
	my $target = &subs::db_select('appointments', undef, { uuid => $row->{'target_uuid'} })->hash;
	return { error => 'that appointment is gone' } unless $target;
	# keep the whole row, so "undo that" can put the appointment back
	&guide_undo_push({
		kind => 'delete', app => $target->{'app'}, uuid => $target->{'uuid'},
		title => $row->{'title'}, row => $target,
	});
	&Manager::delete_app($target->{'app'}, $target->{'uuid'}, ($target->{'server_time'} || &subs::rightNow()), 'guide');
	&subs::appt_toggle_checker($target->{'app'});
	&guide_refresh_app($target->{'app'}, $target->{'uuid'});
	&subs::db_update('staged_appointments', { status => 'promoted' }, { uuid => $row->{'uuid'} });
	return { promoted => $row->{'uuid'}, uuid => $target->{'uuid'}, app => $target->{'app'}, kind => 'delete', summary => $row->{'title'} };
}

sub guide_apply_schedule($c, $token, $text) {
	my $row = &subs::pending_schedule_get($token);
	return { ok => 0, error => 'That schedule is no longer waiting; type it again in the form.' } unless $row;
	my $start = ($row->{'start'} || 0) + 0;
	my $result = &subs::schedule_from_text($text, $start, kind => $row->{'kind'}, max => 366);
	return { ok => 0, ask => $result->{'ask'} } if $result->{'ask'};
	my $dates = $result->{'dates'} || [];
	unless (scalar @{$dates}) {
		&subs::pending_schedule_drop($token);
		return { ok => 1, count => 0, summary => 'No more dates matched that rule.' };
	}
	if (($row->{'kind'} || '') eq 'bill') {
		my $list = &payable_schedules();
		push @{$list}, {
			uuid => &subs::random_string_creator(20), app => ($row->{'app'} || 'unknown'),
			vendor => ($row->{'vendor'} || ''), item => ($row->{'item'} || ''),
			amount => ($row->{'amount'} || 0), tax => ($row->{'tax'} || 0),
			currency => ($row->{'currency'} || ''),
			dates => [ @{$dates} ], next => $dates->[0], active => 'on'
		};
		&payable_schedules_save($list);
		my $made = &payable_schedule_run();
		&subs::pending_schedule_drop($token);
		return { ok => 1, kind => 'bill', count => scalar(@{$dates}), made => $made, dates => $dates,
			summary => 'scheduled ' . scalar(@{$dates}) . ' more bill' . (scalar(@{$dates}) == 1 ? '' : 's') };
	}
	my $app = $row->{'app'} || '';
	my $settings = &subs::settings_grabber({ app => $app });
	my $duration = &subs::time_abbrev_translator($settings->{'duration'});
	$duration = $duration * -1 if ($row->{'type'} || '') =~ /^(?:start|record)$/;
	my $base_uuid = $row->{'uuid'} || '';
	my @written;
	foreach my $next ( @{$dates} ) {
		next unless $next > $start;
		my $uuid = $base_uuid . md5_sum($next - $start) . '+' . md5_sum($app . ' ' . ($row->{'type'} || ''));
		next if &subs::db_query('select 1 from appointments where uuid = ? limit 1', $uuid)->hashes->[0];
		&appointment_writer($c, {
			app => $app, timestamp => $next, type => ($row->{'type'} || 'usual'),
			project => $settings->{'project'},
			duration => (defined $duration ? $duration : ''),
			stop_timestamp => (defined $duration && abs($duration)) ? $next + abs($duration) : undef,
			source_uuid => $base_uuid, uuid => $uuid
		});
		push @written, $next;
	}
	&subs::pending_schedule_drop($token);
	return { ok => 1, kind => 'appointment', count => scalar(@written), dates => \@written,
		summary => 'scheduled ' . scalar(@written) . ' more appointment' . (scalar(@written) == 1 ? '' : 's') };
}

sub _guide_fill {
	my ($v, $args) = @_;
	return $v if ref $v || !defined $v;
	$v =~ s/\{([a-z0-9_]+)\}/defined $args->{$1} ? $args->{$1} : ''/ge;
	return $v;
}

sub guide_verb_execute($c, $action) {
	my $name = $action->{'action'} // '';
	my ($verb) = grep { $_->{'name'} eq $name } @{ &help::learned_verbs() };
	return 'no such command: ' . $name unless $verb;
	my %p;
	foreach my $k ( keys %{ $verb->{'params'} || {} } ) {
		my $v = $verb->{'params'}->{$k};
		$p{$k} = ref $v eq 'ARRAY' ? [ map { _guide_fill($_, $action) } @{$v} ] : _guide_fill($v, $action);
	}
	# an argument the model supplied for a declared arg wins over the literal
	foreach my $k ( keys %{ $verb->{'args'} || {} } ) {
		$p{$k} = $action->{$k} if defined $action->{$k} && $action->{$k} ne '';
	}
	my $prim = $verb->{'primitive'};
	if ($prim eq 'say') {
		return $p{'text'} // $action->{'text'} // 'done';
	}
	if ($prim eq 'open_app') {
		my $app = $p{'app'} // '';
		return 'no app named' unless length $app;
		my $js = 'if (typeof appWindowOpener === "function") { appWindowOpener(' . encode_json($app) . ', Date.now(), {}); }';
		&Websocket::send('server', { console => $js });
		return 'opened the ' . $app . ' window';
	}
	if ($prim eq 'set_setting') {
		my ($app, $setting, $value) = ($p{'app'}, $p{'setting'}, $p{'value'});
		return 'no setting named' unless $app && $setting;
		&subs::setting_setter({ app => $app, setting => $setting, value => $value });
		return 'set ' . $app . ' ' . $setting . ' to ' . (defined $value && length $value ? $value : '(blank)');
	}
	if ($prim eq 'run_command') {
		my $app = $p{'app'} // '';
		my $command = $p{'command'};
		$command = &subs::setting_grabber({ app => $app, setting => 'command' }) if !defined $command || !length $command;
		return 'no command configured' unless $app && defined $command && length $command;
		&subs::run_command($app, $command, &subs::rightNow());
		return 'ran the ' . $app . ' command';
	}
	if ($prim eq 'toggle') {
		my $app = $p{'app'} // '';
		return 'no app named' unless length $app;
		my $on = (($p{'state'} // 'on') !~ /^(?:off|stop|no|0)$/i);
		&Manager::appointment_writer($c, { app => &subs::unformat_name($app), type => ($on ? 'start' : 'stop'), timestamp => &subs::rightNow(), server_time => &subs::rightNow() });
		return ($on ? 'started ' : 'stopped ') . $app;
	}
	if ($prim eq 'stage') {
		my $app = &subs::unformat_name($p{'app'} || '');
		return 'no app named' unless length $app;
		my $uuid = &subs::random_string_creator(40);
		my $type = $p{'type'} || 'usual';
		my $duration = &guide_duration_ms($p{'duration'}, $type);
		&subs::db_insert('staged_appointments', {
			uuid => $uuid, staged_time => &subs::rightNow(), source => 'guide',
			app => $app, type => $type, timestamp => &guide_when_ms($p{'when'}),
			title => ($p{'title'} || ''), notes => ($p{'notes'} || ''), data => '',
			duration => (defined $duration ? $duration : ''),
			device => &subs::device_setter(), status => 'pending'
		});
		return 'staged a "' . ($p{'title'} || $app) . '" appointment (not saved yet)';
	}
	if ($prim eq 'find') {
		my $q = $p{'query'} // '';
		return 'no search given' unless length $q;
		return &help_search_summary(&help_search($q, &media_unlock_device($c)));
	}
	if ($prim eq 'play_music') {
		my $r = help_music_file($c, $p{'query'}, $p{'shuffle'});
		return 'found nothing to play' unless $r->{'found'};
		my $list = ($r->{'files'} && scalar @{$r->{'files'}}) ? $r->{'files'} : [ $r->{'file'} ];
		my $js = 'if (typeof musicToggle === "function") { musicToggle(' . encode_json($list) . ', ' . ($r->{'same_order'} ? 1 : 0) . '); }';
		&Websocket::send('server', { console => $js });
		return scalar(@{$list}) > 1 ? ('now playing ' . scalar(@{$list}) . ' matches') : ('now playing ' . $r->{'title'});
	}
	return 'unknown primitive: ' . $prim;
}

sub coding_rel($rel) {
	$rel = '' unless defined $rel;
	$rel =~ s{^\./+}{};
	$rel =~ s{^/+}{};
	return $rel;
}

sub coding_execute($c, $action, $touched) {
	my $a = $action->{'action'} // '';
	if ($a eq 'list') {
		my $abs = coding_path($action->{'path'});
		return 'refused: that path is outside the repo or not allowed' unless $abs;
		return 'no such folder' unless -d $abs;
		opendir(my $dh, $abs) or return 'could not read that folder';
		my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
		closedir($dh);
		@names = map { -d "$abs/$_" ? "$_/" : $_ } @names;
		@names = @names[0 .. 199] if @names > 200;
		return join("\n", @names);
	}
	if ($a eq 'read') {
		my $abs = coding_path($action->{'path'});
		return 'refused: that path is outside the repo or not allowed' unless $abs;
		return 'no such file' unless -f $abs;
		my $text = eval { read_file($abs) } // '';
		$text =~ s/\x00//g;
		if (length $text > 40000) { $text = substr($text, 0, 40000) . "\n... [trimmed]"; }
		return length($text) ? $text : '(empty file)';
	}
	if ($a eq 'write') {
		my $abs = coding_path($action->{'path'});
		return 'refused: that path is outside the repo or not allowed' unless $abs;
		my $content = $action->{'content'};
		$content = '' unless defined $content;
		require File::Basename;
		my $dir = File::Basename::dirname($abs);
		if (!-d $dir) { require File::Path; File::Path::make_path($dir); }
		eval { write_file($abs, $content) };
		return 'could not write that file' if $@;
		$touched->{ coding_rel($action->{'path'}) } = 1 if $touched;
		# tell the agent at once when what it just wrote cannot parse, so it can
		# correct the file before it tries to commit (the commit action refuses a
		# change that does not verify)
		my $problem = &subs::coding_verify_text(coding_rel($action->{'path'}), $content);
		return 'wrote ' . length($content) . ' bytes to ' . ($action->{'path'} // '')
			. ($problem ? ' - IT DOES NOT PASS THE VERIFIER: ' . $problem . '; write the file whole and correct it' : '');
	}
	if ($a eq 'run') {
		my $cmd = $action->{'command'} // '';
		$cmd =~ s/^\s+|\s+$//g;
		return 'refused: only perl -c, perl scripts/*, prove and read-only git are allowed here'
			unless $cmd =~ m{^(?:perl\s+-c\s+[\w./-]+|perl\s+scripts/[\w./-]+(?:\s+[^\n;|&]*)?|prove(?:\s+[^\n;|&]*)?|git\s+(?:status|diff|log|show|rev-parse|branch|remote)(?:\s+[^\n;|&]*)?)$};
		my $repo = coding_repo();
		my $out = `cd "$repo" && $cmd 2>&1`;
		$out = '' unless defined $out;
		if (length $out > 8000) { $out = substr($out, 0, 8000) . "\n... [trimmed]"; }
		return $out =~ /\S/ ? $out : '(no output)';
	}
	if ($a eq 'bump') {
		my $repo = coding_repo();
		my $v = `cd "$repo" && perl scripts/version_bump.pl 2>&1`;
		chomp $v;
		# the commit that follows reads the version; the old number may be cached
		&subs::jawn_version_forget() if $v =~ /^\d+\.\d+\.\d+$/;
		return $v =~ /^\d+\.\d+\.\d+$/ ? "bumped to $v" : ('bump failed: ' . ($v || 'no output'));
	}
	if ($a eq 'commit') {
		my $msg = $action->{'message'} // 'coding agent change';
		$msg =~ s/["`\$\\]/ /g;
		$msg =~ s/\s+/ /g;
		$msg =~ s/^\s+|\s+$//g;
		my $v = &subs::jawn_version();
		my $repo = coding_repo();
		# the change must pass the verifier before it is committed: Perl compiles,
		# JavaScript parses, templates compile, and no file was truncated. A file that
		# fails is named back to the agent to fix, and nothing is committed.
		my @check = sort keys %{ $touched || {} };
		if (@check && -f "$repo/scripts/verify_change.pl") {
			my $list = join(' ', map { '"' . $_ . '"' } @check);
			my $vout = `cd "$repo" && perl scripts/verify_change.pl $list 2>&1`;
			my $vcode = $? >> 8;
			$vout = '' unless defined $vout;
			return 'refused: the change does not pass the verifier - fix it before committing:' . "\n" . substr($vout, 0, 1500) if $vcode != 0;
		}
		# stage only what the agent actually wrote (plus the version file), so a
		# commit it makes never sweeps in someone else's work-in-progress
		my @files = map { '"' . $_ . '"' } sort keys %{ $touched || {} };
		push @files, '"VERSION"' if -f "$repo/VERSION";
		return 'nothing to commit' unless @files;
		my $cmd = 'cd "' . $repo . '" && git add -- ' . join(' ', @files) . ' 2>&1 && git commit -m "v' . $v . ' - ' . $msg . '" 2>&1';
		my $out = `$cmd`;
		$out = '' unless defined $out;
		if (length $out > 4000) { $out = substr($out, 0, 4000); }
		return $out =~ /\S/ ? $out : '(committed)';
	}
	if ($a eq 'push') {
		my $repo = coding_repo();
		my $out = `cd "$repo" && git push 2>&1`;
		$out = '' unless defined $out;
		if (length $out > 4000) { $out = substr($out, 0, 4000); }
		return $out =~ /\S/ ? $out : '(pushed)';
	}
	if ($a eq 'restart') {
		&subs::restart_request('the coding agent asked for a restart');
		return 'asked the tree to restart';
	}
	if ($a eq 'learn') {
		# teach the Guide a runtime verb: saved to the shared setting, so every
		# machine (and the remote channel) learns it too
		my $name = $action->{'name'} // '';
		my $prim = $action->{'primitive'} // '';
		return 'refused: a command needs a lowercase name' unless $name =~ /^[a-z][a-z0-9_]{1,40}$/;
		return 'refused: unknown primitive (say, open_app, set_setting, run_command, toggle, stage, find, play_music)'
			unless $prim =~ /^(?:say|open_app|set_setting|run_command|toggle|stage|find|play_music)$/;
		my @rows = @{ &help::learned_verbs() };
		@rows = grep { $_->{'name'} ne $name } @rows;
		push @rows, {
			name => $name,
			desc => ($action->{'desc'} // 'a learned command'),
			primitive => $prim,
			args => (ref $action->{'args'} eq 'HASH' ? $action->{'args'} : {}),
			params => (ref $action->{'params'} eq 'HASH' ? $action->{'params'} : {})
		};
		&subs::setting_setter({ app => '__president', setting => 'guide_verbs', device => 'all', value => encode_json \@rows });
		return 'taught the Guide the "' . $name . '" command';
	}
	if ($a eq 'say' || $a eq 'done') {
		return $action->{'text'} // '';
	}
	return 'unknown action: ' . $a;
}

sub coding_system_prompt {
	my $system = &help::coding_prompt();
	my $repo = &subs::home('~/jawnos');
	my $path = -f "$repo/docs/coding_agent_protocols.md" ? "$repo/docs/coding_agent_protocols.md"
		: (-f "$repo/AGENTS.md" ? "$repo/AGENTS.md" : '');
	if (length $path) {
		my $mtime = (stat($path))[9] // 0;
		if (!defined $coding_protocols || ($coding_protocols_mtime // 0) != $mtime) {
			my $text = eval { read_file($path) } // '';
			if (length $text > 20000) { $text = substr($text, 0, 20000) . "\n... [trimmed]"; }
			$coding_protocols = $text;
			$coding_protocols_mtime = $mtime;
		}
		$system .= "\n\nCodebase protocols (follow these):\n" . $coding_protocols . "\n";
	}
	$system .= "\nRight now it is " . localtime(&subs::rightNow() / 1000)->strftime('%A, %B %d %Y, %I:%M%P') . '.';
	return $system;
}

sub coding_conversation_load($name) {
	my $rows = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'coding_conversation_' . $name }) } || [];
	return ref $rows eq 'ARRAY' ? $rows : [];
}

sub coding_conversation_save($name, $rows) {
	splice @{$rows}, 0, scalar(@{$rows}) - 20 if scalar @{$rows} > 20;
	&subs::setting_setter({ app => '__president', setting => 'coding_conversation_' . $name, value => encode_json $rows });
}

sub guide_message_warranty($name) {
	# The logic lives in subs so the data backfill can stamp old turns from the
	# boot process, before this Manager worker is loaded.
	return &subs::guide_message_warranty($name);
}

sub guide_conversation_load($name) {
	my $rows = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'guide_conversation_' . $name }) } || [];
	$rows = [] unless ref $rows eq 'ARRAY';
	my $now = &subs::rightNow();
	my @live = grep {
		my $w = $_->{'warranty'};
		!defined($w) || !($w + 0) || ($w + 0) >= $now
	} @{$rows};
	return \@live;
}

sub guide_conversation_save($name, $rows) {
	splice @{$rows}, 0, scalar(@{$rows}) - 40 if scalar @{$rows} > 40;
	&subs::setting_setter({ app => '__president', setting => 'guide_conversation_' . $name, value => encode_json $rows });
}

sub agent_registry {
	my $rows = eval { decode_json &subs::setting_grabber({ app => '__president', setting => 'agent_conversations' }) } || [];
	return ref $rows eq 'ARRAY' ? $rows : [];
}

sub agent_registry_write {
	my ($rows) = @_;
	&subs::setting_setter({ app => '__president', setting => 'agent_conversations', value => encode_json($rows) });
}

sub agent_title {
	my ($kind, $text) = @_;
	$text = '' unless defined $text;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return '' unless length $text;
	my $fallback = $text;
	$fallback =~ s/^(.{0,32})\b.*$/$1/;
	$fallback =~ s/\s+$//;
	my $model = &subs::setting_grabber({ app => 'mail', setting => ($kind eq 'coding' ? 'coding_assistant' : 'help_assistant') })
	|| &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' })
	|| &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
	return $fallback unless $model;
	my ($out, $err) = &subs::evaluation_model_call_with_fallback(
		$model,
		&subs::setting_grabber({ app => 'mail', setting => ($kind eq 'coding' ? 'coding_assistant_fallback' : 'help_assistant_fallback') }),
		'You name chat threads. Reply with only a short title of two to five words - no quotes, no full stop, no other words.',
		'Name this thread: ' . substr($text, 0, 400),
		&subs::ai_role_thinking($kind eq 'coding' ? 'coding_assistant' : 'help_assistant'),
		($kind eq 'coding' ? 'coding_assistant' : 'help_assistant')
	);
	return $fallback if $err || !defined $out;
	$out =~ s/[\r\n"`*]+/ /g;
	$out =~ s/\s+/ /g;
	$out =~ s/^\s+|\s+$//g;
	$out =~ s/[.\x{3002}]\s*$//;
	return (length $out && length $out <= 60) ? $out : $fallback;
}

sub agent_registry_note {
	my ($kind, $name, $turns) = @_;
	return {} unless length($name || '');
	my $list = ref $turns eq 'ARRAY' ? $turns : [];
	my @said = grep { ($_->{'role'} || '') eq 'user' && length($_->{'content'} || '') && ($_->{'content'} || '') !~ /^\(/ } @{$list};
	my $first = @said ? $said[0]->{'content'} : '';
	my $last = @said ? $said[-1]->{'content'} : '';
	my $rows = &agent_registry;
	my ($row) = grep { ($_->{'kind'} || '') eq $kind && ($_->{'name'} || '') eq $name } @{$rows};
	if (!$row) {
		$row = { kind => $kind, name => $name, title => '', created => &subs::rightNow(), turns => 0 };
		push @{$rows}, $row;
	}
	if (!length($row->{'title'} || '') && length $first) { $row->{'title'} = &agent_title($kind, $first); }
	$row->{'turns'} = scalar @{$list};
	$row->{'updated'} = &subs::rightNow();
	$row->{'preview'} = substr(($last || $first || ''), 0, 120);
	&agent_registry_write($rows);
	return $row;
}

sub agent_registry_forget {
	my ($kind, $name) = @_;
	my $rows = &agent_registry;
	my @keep = grep { !(($_->{'kind'} || '') eq $kind && ($_->{'name'} || '') eq $name) } @{$rows};
	&agent_registry_write(\@keep);
}

1;
