package Manager;

# manager_misc: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/take_picture
sub action_832 {
	my $c = shift;
	my $timestamp = &timestamp_adjuster($c);
	my $camera = $c->param('camera');
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my ($file,$ocr);
	# A native capture (window.JawnCamera) is handed over as a small reference to
	# a file the app already wrote; the bytes never travel through the WebView.
	my $native_path = $c->param('native_path') || '';
	my $data = {
		app => $app,
		timestamp => $timestamp,
		camera => $camera,
		uuid => $uuid,
		native_path => $native_path,
		native_kind => $c->param('native_kind'),
		native_name => $c->param('native_name'),
		native_mime => $c->param('native_mime'),
		duty => 'image',
		duuid => &subs::random_string_creator()
	};
	# A capture that has already happened cannot be deferred as a future duty:
	# the staged file must be claimed now or the app's cache may clear it.
	if (!length $native_path && $timestamp >= &subs::rightNow() + 1000) {
		my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid })->hashes->[0];
		my $duties = eval { return decode_json $appt->{'duties'} } || [];
		push @{$duties}, $data;
		@{$duties} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$duties};
		my $next_duty = $duties->[0]->{'timestamp'};
		my $jduties = encode_json $duties;
		&subs::db_update('appointments', { duties => $jduties, next_duty => $next_duty, server_time => &subs::rightNow() }, { app => $app, uuid => $uuid });
		&subs::appt_alarm_setter(&subs::db_select('appointments', undef, { app => $app, uuid => $uuid })->hashes->[0]);
	}
	else {
		($file,$ocr) = &take_picture($c,$data);
	}
	&Websocket::send('server', { console => 'appointmentDetailGrabber(' . encode_json($app) . ',' . encode_json($data->{'uuid'} || $uuid) . ');'});
	$c->render(json => { files => $file, ocr => $ocr, uuid => $data->{'uuid'} || $uuid });
}

# Claim unclaimed media onto an appointment: each named file row moves from its
# Camera-app holder onto the chosen appointment, and a holder emptied by the move
# is deleted. The media itself stays where it was sealed; only the row moves.
# POST /manager/unclaimed/claim
sub action_875 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app') || '');
	my $uuid = $c->param('uuid') || '';
	my @file_uuids = grep { $_ } split /,/, ($c->param('file_uuids') || '');
	unless ($app && @file_uuids) { $c->render(json => { ok => 0, error => 'need app and file_uuids' }); return; }
	# the claim box hands over an app name; when no specific appointment was chosen,
	# file onto that app's most recent appointment row
	if (!$uuid) {
		my $latest = &subs::db_query('select uuid from appointments where app=? and uuid is not null order by server_time desc limit 1', $app)->hash;
		$uuid = $latest->{'uuid'};
	}
	unless ($uuid) { $c->render(json => { ok => 0, error => 'no such appointment to claim onto' }); return; }
	my $target = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid })->hashes->[0];
	unless ($target) { $c->render(json => { ok => 0, error => 'no such appointment to claim onto' }); return; }

	my $holders = &subs::db_select('appointments', undef, { app => 'camera', source => 'unclaimed' })->hashes || [];
	my %taken = map { $_ => 1 } @file_uuids;
	my %owner;   # file_uuid -> 1 when it is really unclaimed here
	foreach my $h ( @{$holders} ) {
		my $of = eval { return decode_json $h->{'file'} } || [];
		foreach my $f ( @{$of} ) {
			$owner{ $f->{'uuid'} } = 1;
		}
	}

	my $tf = eval { return decode_json $target->{'file'} } || [];
	my @target_files = @{$tf};
	my $claimed = 0;
	foreach my $h ( @{$holders} ) {
		my $of = eval { return decode_json $h->{'file'} } || [];
		my @orig = @{$of};
		my @move = grep { $taken{ $_->{'uuid'} } && $owner{ $_->{'uuid'} } } @orig;
		foreach my $f ( @move ) {
			$f->{'appt_uuid'} = $uuid;
			push @target_files, $f;
			$claimed++;
		}
		my @left = grep { !$taken{ $_->{'uuid'} } } @orig;
		if (@move) {
			if (@left) {
				&subs::db_update('appointments', { file => encode_json(\@left), server_time => &subs::rightNow() }, { app => 'camera', uuid => $h->{'uuid'} });
			}
			else {
				&delete_app('camera', $h->{'uuid'}, $h->{'server_time'}, 'claimed');
			}
		}
	}

	unless ($claimed) { $c->render(json => { ok => 0, error => 'none of those files are unclaimed' }); return; }
	&subs::db_update('appointments', { file => encode_json(\@target_files), server_time => &subs::rightNow() }, { app => $app, uuid => $uuid });
	# Two new windows from one request: their timestamps are their ids, and
	# rightNow() is second-precision, so the second must not repeat the first.
	my $win_stamp = &subs::rightNow();
	&centre_view_grabber({ c => $c, app => $app, timestamp => $win_stamp, cached => 'no' });
	&centre_view_grabber({ c => $c, app => 'camera', timestamp => $win_stamp + 1, cached => 'no' });
	$c->render(json => { ok => 1, claimed => $claimed });
}

# List the unclaimed media waiting on the Camera app: a flat, newest-first list of
# every file row held by a source=unclaimed Camera appointment, with the id pair
# /file_open needs (appt_uuid + file_uuid) and the warranty it expires on.
# GET /manager/unclaimed
sub action_933 {
	my $c = shift;
	my $holders = &subs::db_select('appointments', undef, { app => 'camera', source => 'unclaimed' })->hashes || [];
	my @items;
	foreach my $h ( @{$holders} ) {
		my $files = eval { return decode_json $h->{'file'} } || [];
		foreach my $f ( @{$files} ) {
			next unless $f && $f->{'uuid'};
			my $name = $f->{'f'} || '';
			$name =~ s{.*/}{};
			push @items, {
				file_uuid  => $f->{'uuid'},
				appt_uuid  => $h->{'uuid'},
				type       => $f->{'type'} || &file_type_recognizer($f->{'f'} || '')->{'type'} || 'file',
				name       => $name,
				server_time => $f->{'server_time'} || $h->{'server_time'} || $h->{'timestamp'} || 0,
				warranty   => $h->{'warranty'} || 0,
			};
		}
	}
	@items = sort { ($b->{'server_time'} || 0) <=> ($a->{'server_time'} || 0) } @items;
	$c->render(json => { ok => 1, items => \@items });
}

# Search appointments by the name typed in the claim box: returns the distinct
# apps whose slug matches, bounded for the dropdown, so the claim route can file
# straight onto one (the claim route resolves the newest appointment row itself).
# GET /manager/unclaimed/appointments
sub action_959 {
	my $c = shift;
	my $search = &subs::unformat_name($c->param('search') || '');
	my @out;
	if (length $search) {
		my $rows = &subs::db_query('select distinct app from appointments where app is not null and app != ? and app like ? limit 50', '', '%' . $search . '%')->hashes || [];
		foreach my $r ( @{$rows} ) {
			next unless $r->{'app'};
			push @out, { app => $r->{'app'}, name => &subs::format_name($r->{'app'}) };
		}
	}
	$c->render(json => { ok => 1, appointments => \@out });
}

# POST /manager/scan_document
sub action_1141 {
	my $c = shift;
	my $timestamp = &timestamp_adjuster($c);
	my $feed = $c->param('feed');
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $scandata = {
		timestamp => $timestamp,
		feed => $feed,
		uuid => $uuid,
		app => $app,
		source => 'existing',
		duty => 'scan',
		duuid => &subs::random_string_creator()
	};
	my $file;
	if ($timestamp >= &subs::rightNow() + 1000) {
		my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid })->hashes->[0];
		my $duties = eval { return decode_json $appt->{'duties'} } || [];
		push @{$duties}, $scandata;
		@{$duties} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$duties};
		my $next_duty = $duties->[0]->{'timestamp'};
		my $jduties = encode_json $duties;
		&subs::db_update('appointments', { duties => $jduties, next_duty => $next_duty, server_time => &subs::rightNow() }, { app => $app, uuid => $uuid });
		&subs::appt_alarm_setter(&subs::db_select('appointments', undef, { app => $app, uuid => $uuid })->hashes->[0]);
	}
	else {
		$file = &scan($c, $scandata);
	}


	&Websocket::send('server', { console => 'appointmentDetailGrabber(' . encode_json($app) . ',' . encode_json($uuid) . ');'});
	$c->render(json => { files => $file });
}

# A screenful of pictures, answered in one request.
#
# A music library or a photo grid asks for one picture per card. Every one of
# those used to be its own /file_open: the session check, the appointment read,
# the key walk and (on a phone) two prefork workers shared between them. A burst
# of covers could therefore hold the whole pool until the last image answered,
# and every other route - even a button press - queued behind it. This route does
# the shared work once and returns the pictures as data URIs.
#
# It deliberately serves only what it can answer without side effects. A picture
# that needs generating (no stored thumb), lives on a peer, or is not a plain
# /file_open comes back in `defer`; the client asks /file_open for those few
# through the existing single-flight and relay paths, at a small concurrency.
# The caller is an approved session, exactly as /file_open requires.
# POST /manager/thumbs
sub action_1360 {
	my $c = shift;
	my $payload = eval { $c->req->json } || {};
	$payload = {} unless ref $payload eq 'HASH';
	my $urls = $payload->{'urls'};
	unless (ref $urls eq 'ARRAY') {
		$urls = eval { decode_json($c->param('urls') // '') } || [];
	}
	$urls = [] unless ref $urls eq 'ARRAY';
	unless (($c->session('authentication') || '') eq 'approved'
		&& &authentication_passer($c) eq 'approved') {
		return $c->render(status => 403, json => { error => 'denied', items => {}, defer => [] });
	}
	# A batch is bounded in both items and bytes: it is one worker answering,
	# and a tablet should not have a 30 MB JSON body decoded in its browser.
	my $max_items = 80;
	my $max_bytes = 8 * 1024 * 1024;
	my $max_file  = 2 * 1024 * 1024;
	my %items;
	my @defer;
	my %appt_cache;
	my %secrets_cache;
	my %standard_cache;
	my $suds;
	my ($bytes, $count) = (0, 0);
	for my $i (0 .. $#$urls) {
		if ($count >= $max_items || $bytes >= $max_bytes) {
			push @defer, $i;
			next;
		}
		my ($src, $size) = &thumbs_bundle_one($c, $urls->[$i], \%appt_cache, \%secrets_cache, \%standard_cache, \$suds, $max_file);
		if (defined $src && length $src && $bytes + $size <= $max_bytes) {
			$items{$i} = $src;
			$bytes += $size;
			$count++;
		}
		else {
			push @defer, $i;
		}
	}
	# A batch is content, not a session answer: the pictures themselves keep the
	# long-lived cache header /file_open gives a thumb.
	$c->res->headers->cache_control('private, max-age=3600');
	$c->render(json => { items => \%items, defer => \@defer });
}

# POST /manager/appointment/writer
sub action_2946 {
	my $c = shift;
	my $parameters = $c->req->body_params->to_hash;
	my $movement = $parameters->{'type'} || $parameters->{'movement'} || '';
	unless (&peer_action_gate($c, &subs::peer_movement_action($movement))) {
		return $c->rendered(403);
	}
	my $peer = &peer_row_for_request($c);
	if ($peer && !&subs::peer_rate_ok($peer, 'action')) {
		return $c->rendered(429);
	}
	&appointment_writer($c,$parameters);
	$c->render(json => $parameters);
}

# GET /manager/home
sub action_3017 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $homepage = &homepage_maker($c);
	$homepage = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'home', contents => $homepage }, $timestamp);
	$c->render('text' => $homepage);
}

# GET /manager/register_grabber
sub action_3083 {
	my $c = shift;
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $returner = &register_grabber($app);
	$c->render(json => $returner);
}

# GET /manager/measures
sub action_3104 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	# the live rate snapshot fills the PV column without waiting for the half-hour
	eval { &subs::crypto_measures_sync(); };
	my $settings = &subs::settings_grabber({ app => 'measures' });
	my $measures = eval { return decode_json $settings->{'measures'} } || $gb::measures;
	if ( scalar keys %{$measures} == 0 ) { $measures = $gb::measures; }
	my $written = 0;
	foreach my $m ( keys %{$measures} ) {
		unless ($measures->{$m}->{'uuid'}) {
			$measures->{$m}->{'uuid'} = &subs::random_string_creator(25);
			delete $measures->{$m}->{'symbol'};
			$written = 1;
		}
	}
	if ($written == 1) {
		my $jmeasures = encode_json $measures;
		&subs::setting_setter({ app => 'measures', setting => 'measures', value => $jmeasures });
	}
	my $contents = $c->render_to_string(
		template => '/measures/measures',
		timestamp => $timestamp,
		settings => $settings,
		measures => $measures
	);
	my $window = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'measures', contents => $contents }, $timestamp);

	$c->render(json => { window => $window });
}

# POST /manager/measures/assign
sub action_3134 {
	my $c = shift;
	my $mc_measure = $c->param('mc_measure');
	my $mc_app = $c->param('mc_app');
	my $ms_measure = $c->param('ms_measure');
	my $ms_uuid = $c->param('ms_uuid');
	my $ms_name = $c->param('ms_name');

	my $measures = eval { return decode_json &subs::setting_grabber({ app => 'measures', setting => 'measures' }) };
	foreach my $m ( grep { $_ eq $ms_measure } keys %{$measures} ) {
		if ($measures->{$m}->{'uuid'} eq $ms_uuid) {

			my $ameasure = eval { return decode_json &subs::setting_grabber({ app => $mc_app, setting => 'app_measures' }) };

			if ($ameasure->{$mc_measure}) {
				$measures->{$m}->{'app'} = &subs::unformat_name($mc_app);
				$measures->{$m}->{'app_measure'} = &subs::unformat_name($mc_measure);
				$measures->{$m}->{'pv'} = $ameasure->{$measures->{$m}->{'app_measure'}}->{'value'} if $ameasure->{$measures->{$m}->{'app_measure'}}->{'value'};
			}
		}
	}
	my $jmeasures = encode_json $measures;
	&subs::setting_setter({ app => 'measures', setting => 'measures', value => $jmeasures });

	$c->render(json => $measures);
}

# POST /manager/measures/edit
sub action_3160 {
	my $c = shift;
	my $measure = eval { return decode_json $c->param('measure') } || {};
	my $measures = eval { return decode_json &subs::setting_grabber({ app => 'measures', setting => 'measures' }) };
	foreach my $t ( qw/formulas types/ ) {
 		my @t = $measure->{$t} ? split ',', $measure->{$t} : ();

		$measure->{$t} = \@t;
	}
	if ($measure->{'m'}) {
		if ($measure->{'uuid'} eq 'new') {
			$measure->{'uuid'} = &subs::random_string_creator(26);
			until ( !$measures->{$measure->{'m'}} ) {
				$measure->{'m'} = '_' . $measure->{'m'};
			}
			$measures->{$measure->{'m'}} = $measure;
		} else {

		}

		my $jmeasures = encode_json $measures;
		&subs::setting_setter({ app => 'measures', setting => 'measures', value => $jmeasures });
	}

	$c->render(json => $measure);
}

# POST /manager/measures/delete
sub action_3186 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $measures = eval { return decode_json &subs::setting_grabber({ app => 'measures', setting => 'measures' }) } || {};
	foreach my $m ( keys %{$measures} ) {
		if ($measures->{$m}->{'uuid'} eq $uuid) {
			delete $measures->{$m};
		}
	}

	my $jmeasures = encode_json $measures;
	&subs::setting_setter({ app => 'measures', setting => 'measures', value => $jmeasures });
	$c->render(json => { measures => $measures });

}

# A process viewer for the machine (the Monitor app): CPU/memory graphs plus the
# process list, read straight from /proc. The old start-menu htop figure came
# from `times` inside a prefork master that spent its life blocked in run(), so
# its numbers were nonsense; cumulative jiffies per pid plus a difference taken
# in the browser are correct no matter which prefork worker answers. On Termux
# the same reads work for JawnOS's own processes (shared UID); other apps'
# states are hidden and are simply skipped.
# GET /manager/process_monitor
sub action_4940 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = $c->render_to_string(
		template => 'monitor/monitor',
		timestamp => $timestamp
	);
	my $window = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'process_monitor', contents => $contents }, $timestamp);
	$c->render(json => { window => $window });
}

# GET /manager/process_monitor/data
sub action_4950 {
	my $c = shift;
	my $clk = 100;   # CLK_TCK

	# memory (KB)
	my ($mem_total, $mem_avail) = (0, 0);
	if (open(my $mf, '<', '/proc/meminfo')) {
		while (my $l = <$mf>) {
			$mem_total = $1 if $l =~ /^MemTotal:\s+(\d+)/;
			$mem_avail = $1 if $l =~ /^MemAvailable:\s+(\d+)/;
			last if $mem_total && $mem_avail;
		}
		close $mf;
	}

	# uptime, to turn each pid's starttime into an age. Android denies
	# /proc/uptime to apps, so the age is simply unknown there (-1).
	my $uptime;
	if (open(my $uf, '<', '/proc/uptime')) {
		my $ul = <$uf>;
		close $uf;
		$uptime = $1 if $ul && $ul =~ /^([\d.]+)/;
	}

	# per-core CPU: cumulative total and idle jiffies
	my @cpus;
	if (open(my $st, '<', '/proc/stat')) {
		while (my $l = <$st>) {
			next if $l =~ /^cpu\s/;               # the aggregate line
			last unless $l =~ /^cpu(\d+)\s+(.*)$/;
			my @v = split ' ', $2;
			my $idle = ($v[3] // 0) + ($v[4] // 0);   # idle + iowait
			my $total = 0;
			$total += ($_ // 0) for @v;
			push @cpus, { t => $total, i => $idle };
		}
		close $st;
	}

	my @procs;
	for my $d (glob('/proc/[0-9]*')) {
		(my $pid = $d) =~ s{.*/}{};
		open(my $sf, '<', "$d/stat") or next;
		my $line = <$sf>;
		close $sf;
		next unless defined $line;
		my $open = index($line, '(');
		my $close = rindex($line, ')');
		next if $open < 0 || $close < 0;
		my $comm = substr($line, $open + 1, $close - $open - 1);
		my @f = split ' ', substr($line, $close + 2);
		my $cmd = '';
		if (open(my $cf, '<', "$d/cmdline")) {
			local $/;
			$cmd = <$cf>;
			close $cf;
			$cmd =~ s/\0/ /g;
			$cmd =~ s/\s+$//;
		}
		$cmd = $comm if !defined $cmd || $cmd eq '';
		$cmd = substr($cmd, 0, 90);
		my $age = -1;
		if (defined $uptime && defined $f[19]) {
			$age = int($uptime - $f[19] / $clk);
			$age = 0 if $age < 0;
		}
		push @procs, { p => $pid, pp => $f[1], t => ($f[11] + $f[12]), r => $f[21], a => $age, n => $cmd };
	}
	# The Monitor's headline: what this machine is running and how it is doing.
	# The battery comes through the shared sampler so a two-second poll does not
	# spawn termux-battery-status each tick; everything else is read here.
	my ($dbm, $database) = &subs::database_grabber();
	my $load = '';
	if (open(my $lf, '<', '/proc/loadavg')) {
		my $l = <$lf>;
		close $lf;
		$load = $1 if $l && $l =~ /^([\d.]+ [\d.]+ [\d.]+)/;
	}
	my $running_jobs = &subs::db_query('select count(*) as c from sync_jobs where state = ?', 'running')->hashes->[0]->{'c'} || 0;
	my $last_job = &subs::db_query('select note, updated from sync_jobs order by cast(updated as integer) desc limit 1')->hashes->[0] || {};
	my $active_peers = &subs::db_query('select count(*) as c from remote_machines where connection = ?', 'active')->hashes->[0]->{'c'} || 0;
	# Include the ./jawn master, which health_process_count leaves out: this is the
	# number a person reads as "how many processes jawn is running".
	my $jawn_procs = scalar grep { ($_->{'n'} || '') =~ m{(?:^|/)(?:jawn|President\.pl|Manager\.pl|Websocket\.pl|teletype\.pl|watch\.pl|Music\.pl|Alarm\.pl|pen\.pl)\b} } @procs;
	my $health = {
		version => &subs::jawn_version(),
		processes => $jawn_procs,
		load => $load,
		uptime => $uptime,
		database => {
			bytes => ($database && -e $database) ? (-s $database) : 0,
			wal_bytes => ($database && -e $database . '-wal') ? (-s $database . '-wal') : 0,
		},
		running_jobs => $running_jobs + 0,
		last_job => { note => $last_job->{'note'} || '', updated => $last_job->{'updated'} || '' },
		peers_active => $active_peers + 0,
		battery => &subs::battery_sample(),
	};
	$c->render(json => { at => &subs::rightNow(), clk => $clk, mem_total => $mem_total, mem_avail => $mem_avail, cpus => \@cpus, procs => \@procs, health => $health });
}

# GET /manager/warehouse
sub action_5391 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $settings = &subs::settings_grabber({ app => 'warehouse' });
	my $chosen = eval { return decode_json $settings->{'place'} } || ['all'];
	my $places = [ @{$chosen} ];
	# default the levels view to wherever we currently are; the moves ledger
	# reads the places the user actually picked, so it does not hide older stock
	unless (grep { $_ ne 'all' } @{$places}) {
		my $current = &subs::current_place();
		$places = [ $current ] if $current;
	}
	$settings->{'place'} = $places;
	my $warehouse = &warehouse_grabber({ places => $places });
	# the ledger's other face: Moves lists every move (stock and money), Levels
	# the current sums; the window opens on whichever the setting names
	my $moves = (($settings->{'display'} || 'levels') eq 'moves') ? &warehouse_moves({ places => [ grep { $_ ne 'all' } @{$chosen} ], limit => 300 }) : undef;
	my $contents = $c->render_to_string(
		template => 'warehouse/warehouse',
		timestamp => $timestamp,
		settings => $settings,
		warehouse => $warehouse,
		moves => $moves,
		search => ''
	);
	my $window = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'warehouse', contents => $contents }, $timestamp);
	$c->render(json => { window => $window });
}

# GET /manager/warehouse/listing
sub action_5419 {
	my $c = shift;
	my $search = &subs::unformat_name($c->param('search'));
	my $settings = &subs::settings_grabber({ app => 'warehouse' });
	my $places = eval { return decode_json $settings->{'place'} } || ['all'];
	# the ledger's other face: Levels is what is on hand now, Moves is every move
	# (stock and money) as it happened, signed
	if (($settings->{'display'} || 'levels') eq 'moves') {
		my @picked = grep { $_ ne 'all' } @{$places};
		my $moves = &warehouse_moves({ places => \@picked, search => $search, limit => 300 });
		my $html = $c->render_to_string(
			template => 'warehouse/moves',
			moves => $moves,
			search => $search || ''
		);
		$c->render(json => { html => $html, search => $search });
		return;
	}
	my $warehouse;
	if (defined $search && $search ne '') {
		$warehouse = &warehouse_grabber({ search => $search });
	}
	else {
		$warehouse = &warehouse_grabber({ places => $places });
	}
	my $html = $c->render_to_string(
		template => 'warehouse/listing',
		warehouse => $warehouse,
		places => $places,
		search => $search || ''
	);
	$c->render(json => { html => $html, search => $search });
}

# Add stock that arrived without a purchase: a gift, something found, or a
# transfer in. It is a stock row with no account, so it raises the shelf without
# touching the money ledger.
# POST /manager/warehouse/stock_in
sub action_5455 {
	my $c = shift;
	my $item = &subs::unformat_name($c->param('item'));
	my $place = $c->param('place');
	my $default_unit = &subs::setting_grabber({ app => $item, setting => 'unit' }) || 'each';
	my ($qty, $unit) = &subs::quantity_unit_split($c->param('quantity'), $default_unit, 1);
	my $reason = $c->param('reason') || 'gift';
	$reason = 'other' unless $reason =~ /^(?:gift|found|transfer|other)$/;
	return $c->render(json => { ok => 0, error => 'item' }) unless length $item;
	return $c->render(json => { ok => 0, error => 'place' }) unless defined $place && $place ne '';
	return $c->render(json => { ok => 0, error => 'unit' }) unless $gb::measures->{$unit};
	return $c->render(json => { ok => 0, error => 'quantity' }) unless $qty > 0;
	my $row = &subs::warehouse_movement({
		item => $item, quantity => $qty, unit => $unit, place => $place,
		timestamp => $c->param('timestamp') || &subs::rightNow(),
		type => 'stock_in', reason => $reason, source => 'warehouse',
	});
	$c->render(json => { ok => 1, uuid => $row->{'uuid'}, item => $item, quantity => $qty, unit => $unit });
}

# GET /manager/warehouse/journal
sub action_5474 {
	my $c = shift;
	my $item = &subs::unformat_name($c->param('item'));
	my $source_uuid = $c->param('source_uuid');
	my ($q,$rows);
	if ($source_uuid) {
		# movements caused by a particular document (transaction/invoice)
		$item = '';
		$q = &subs::db_query('select * from warehouse where app_uuid=? order by timestamp desc limit 200', $source_uuid);
	}
	else {
		$q = &subs::db_query('select * from warehouse where item=? order by timestamp desc limit 200', $item);
	}
	$rows = $q ? $q->hashes : [];
	foreach my $r ( @{$rows} ) {
		$r->{'journal'} = eval { return decode_json $r->{'data'} } || {};
	}
	my $html = $c->render_to_string(
		template => 'warehouse/journal',
		item => $item,
		rows => $rows
	);
	$c->render(json => { html => $html, item => $item, count => scalar @{$rows} });
}

# What an item has on hand right now - what the warehouse Levels view shows, but
# readable by a page or an agent that is reasoning about buying more. Its
# packaging rides along, so a low figure can name the package that would cover
# it (a six-pack when two are left and the shop comes once a week).
# GET /manager/warehouse/on_hand
sub action_5502 {
	my $c = shift;
	my $item = &subs::unformat_name($c->param('item'));
	my $stock = &subs::warehouse_stock_for($item);
	my $packaging = eval { return decode_json &subs::setting_grabber({ app => $item, setting => 'app_packaging' }) }
		|| eval { return decode_json &subs::setting_grabber({ app => $item, setting => 'packaging' }) }
		|| {};
	# a target turns the reading into a restock plan (how much of which pack to buy)
	my $target = $c->param('target');
	my $restock = (defined $target && $target =~ /[0-9]/) ? &subs::warehouse_restock_for($item, $target + 0) : undef;
	$c->render(json => { item => $item, on_hand => $stock, packaging => $packaging, restock => $restock });
}

# GET /manager/editor
sub action_7071 {
	my $c = shift;
	my $editor = &editor_maker($c);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'editor', contents => $editor }, $c->param('timestamp'));
	$c->render(text => $website);
}

# GET /manager/app_section
#
# The two forms an appointment window carries but does not show - the details
# (transaction) panel and the app's measures - used to be rendered into every
# open and left hidden, which was 11 KB of the 42 KB a window costs for a form
# nobody had asked to see. They are fetched here the first time a control shows
# them. The set is read the same way the window reads it, markers and all, so the
# form is the one the window would have drawn.
sub action_18101 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $section = $c->param('section') || '';
	return $c->render(text => '', status => 400) unless length $app && $section =~ /^(?:details|measures)$/;
	return $c->render(text => '', status => 403) if &subs::app_hidden_now($app);
	my $appts = &log_reader({ app => $app, view => 'centre_view' });
	return $c->render(text => '') unless $appts->{$app};
	my $markers = (ref $appts->{'__specs'} eq 'HASH') ? ($appts->{'__specs'}->{'markers'} || '') : '';
	&appts_marker_builder($appts) if $markers ne 'yes';
	$appts->{$app}->{'setting'}->{'app_measures'} = eval { return decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
	my $html;
	if ($section eq 'details') {
		$html = $c->render_to_string(template => 'apps/app_details', appts => $appts, a => $app, app => {});
	}
	else {
		$html = $c->render_to_string(template => 'apps/app_measures', appts => $appts, settings => $appts->{$app}->{'setting'}, a => $app);
	}
	$c->render(text => $html);
}

# GET /manager/magazine/neighbour_publish
sub action_7077 {
	my $c = shift;
	my $ip = $c->param('ip');
	my $browser_tab_id = $c->param('browser_tab_id');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $remote_machine = &subs::db_select('remote_machines', undef, { uuid => $uuid, ip => $ip })->hashes->[0];
	$remote_machine = &remote_useragent_maker({ signatorial => $remote_machine->{'signatorial'}, rm => $remote_machine });
	if ($remote_machine->{'ua'}) {
		my ($db,$database,$sql) = &subs::database_grabber();
		my $q = &subs::db_query('select * from magazine where status = ?', 'publish');
		my $articles = $q->hashes;
		my $json = encode_json $articles;

		my $npq = &subs::db_query('select title,uuid from magazine where status != ?', 'publish');
		my $nparticles = $npq->hashes;
		my $npjson = encode_json $nparticles;

		my $port_quest = &subs::db_query('select * from remote_machines where ip=?', $ip);
		my $ports = $port_quest->hashes;
		my $remote = $ports->[-1];
		my $port = $remote->{'port'};
		my $string = '/manager/magazine/publishing_receive';
		my $remote_params = { articles => $json, nonpublished => $npjson };
		my $res = eval { return $remote_machine->{'ua'}->insecure(1)->post('https://' . $ip . ':' . $port . $string => form => $remote_params)->result };
		if ($res) {
			$c->render('text' => $res->body);
		}
		else { $c->render('text' => 'no good'); }

	}
	else {
		$c->render('text' => 'no idea');
	}
}

1;
