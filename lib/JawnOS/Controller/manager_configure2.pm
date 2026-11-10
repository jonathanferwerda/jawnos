package Manager;

# manager_configure2: route actions moved out of Manager.pl, one sub per route so a
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

# GET /manager/configure/ping
sub action_9562 {
	my $c = shift;
	my $ip = $c->param('host');
	my $timestamp = $c->param('timestamp');

	my ($db,$database) = &subs::database_grabber();
	my $timeout = .2;
	my $returner = {};
	&subs::setting_setter({ app => 'misc', setting => 'ping', value => $ip });
	# The box can record what is typed without pinging anything: clearing it and
	# reloading must stick, so the box saves itself on change and asks for no run.
	if ($c->param('save_only')) {
		$c->render(json => { saved => 1, host => $ip // '' });
		return;
	}
	if ($ip) {
		# Only an address, a range or a comma list may reach the shell. The
		# derived addresses are interpolated into ping below; this keeps a
		# request such as 1.1.1.$(id) out of it.
		unless ($ip =~ /\A[0-9., ]+\z/) {
			$c->render(json => { saved => 0, host => $ip, error => 'not an address' });
			return;
		}

		my @ip = split '\.', $ip;
		if (scalar @ip == 4) {

			$returner->{$ip}->{'ip'} = $ip;
			$returner->{$ip}->{'result'} = `timeout $timeout ping -c 1 ` . quote($ip);
		}
		else {
			require JawnOS::Platform::Net; my $interfaces = JawnOS::Platform::Net::interfaces();
			foreach my $nic ( sort keys %{$interfaces} ) {
				my $ip = $interfaces->{$nic}->{'ip'} || '';

				my @routes = $ip ? ( 'inet ' . $ip ) : ();
				foreach my $route (@routes) {
					my @inet = split " ", $route;
					if ($route =~ /inet /) {


						my @items = split " ", $route;
						my $sip = $ip;
						$sip =~ s/[0-9]//gi;

						my $gw = $items[1];
						my @gw = split /\./, $gw;

						my @csv = split ',', $ip;
						if (scalar @csv > 1) {
							foreach my $csv (@csv) {
								pop @gw;
								push @gw, $csv;
								my $ip_address = join '.', @gw;
								$returner->{$ip_address}->{ip} = $ip_address;
								$returner->{$ip_address}->{'result'} = `timeout $timeout ping -c 1 ` . quote($ip_address);
							}
						}
						elsif ($sip eq '..' ) {
							my @sips = split '\.\.', $ip;

							foreach my $csv ( $sips[0] .. $sips[1] ) {

								pop @gw;
								push @gw, $csv;
								my $ip_address = join '.', @gw;

								$returner->{$ip_address}->{ip} = $ip_address;
								$returner->{$ip_address}->{'result'} = `timeout $timeout ping -c 1 ` . quote($ip_address);
							}
						}
						else {
							pop @gw;
							push @gw, $ip;
							my $ip_address = join '.', @gw;
							$returner->{$ip_address}->{ip} = $ip_address;
							$returner->{$ip_address}->{'result'} = `timeout $timeout ping -c 1 ` . quote($ip_address);
						}
					}
				}
			}
		}
	}
	my $html = $c->render_to_string(
		template => 'configure/ping',
		ping => $returner
	);


	$c->render(text => $html);
}

# The puller's window into an asynchronous export: the build's state, its
# per-table row counts, and - once ready - the same reply backup_now used to
# return synchronously. The caller is the peer that asked for the snapshot, so
# the job is scoped to its signatorial and cannot be read by anyone else.
# GET /manager/configure/backup_status
sub action_9798 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($c->session('authentication') eq 'approved' || ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm))) {
		$c->rendered(403);
		return;
	}
	&subs::sync_pull_touch();
	my $job = $c->param('job') || '';
	my $snap = ($job && &subs::db_select('sync_snapshots', undef, { uuid => $job, caller => $signatorial })->hashes->[0]);
	unless ($snap) {
		$c->render(json => { status => 'unknown', job => $job });
		return;
	}
	# A worker the kernel killed leaves the row 'building' forever; age it out
	# rather than let the puller poll a dead snapshot until its own bound.
	if (($snap->{'state'} || '') eq 'building' && int($snap->{'updated'} || 0) + 1800000 < &subs::rightNow()) {
		&subs::db_update('sync_snapshots', { state => 'failed', error => 'stale build', updated => &subs::rightNow() }, { uuid => $job });
		$snap->{'state'} = 'failed';
		$snap->{'error'} = 'stale build';
	}
	my $steps = [];
	if ($snap->{'job'}) {
		my $sj = &subs::db_select('sync_jobs', undef, { uuid => $snap->{'job'} })->hashes->[0];
		$steps = eval { decode_json($sj->{'steps'} || '[]') } || [] if $sj;
	}
	my $result = eval { decode_json($snap->{'result'} || '') } || undef;
	$c->render(json => {
		status => ($snap->{'state'} || 'unknown'),
		job => $job,
		steps => $steps,
		size => $snap->{'size'},
		sha256 => $snap->{'sha256'},
		error => $snap->{'error'},
		($result ? (result => $result) : ()),
	});
}

# POST /manager/configure/remote_rsync
sub action_9974 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $direction = $c->param('direction');
	my $signatorial = $c->param('signatorial');
	my $uuid = $c->param('uuid');
	my $hostname = `hostname`;
	chomp $hostname;
	my $folder = $c->param('home') || 'jawnos';
	$folder =~ s{.*/}{};
	my $home = &subs::home('~/');
	my $me = &subs::signatorial_designer();
	my $rm = &subs::db_select('remote_machines', undef, { uuid => $uuid, signatorial => $signatorial })->hashes->[0];
	my @result;
	my $summary;
	if ($rm->{'signatorial'}) {
		$rm = &Manager::remote_useragent_maker({ signatorial => $signatorial, rm => $rm });
		$rm->{'ua'}->inactivity_timeout(300);
		if ($direction eq 'from') {
			# pull the peer's tree down over http, unpack it into ~, restart
			my $url = $rm->{'manager'} . '/manager/rsync_pack?signatorial=' . $me . '&folder=' . $folder;
			my $res = eval { $rm->{'ua'}->get($url)->result };
			if ($res && $res->is_success && length $res->body) {
				my $tmp = &subs::home('~/.president/rsync_pull_' . &subs::random_string_creator(8) . '.tgz');
				write_file($tmp, $res->body);
				my $ok = &code_sync_unpack($tmp, $home);
				unlink $tmp;
				if ($ok) {
					$summary = 'Pulled ' . &subs::data_size(length $res->body);
					&subs::restart_request('pulled a peer tree over http (' . $summary . ')');
					push @result, 'Triggered Local Restart';
				}
				else { $summary = 'Pull refused (unsafe archive)'; }
			}
			else { $summary = 'Pull failed'; }
		}
		elsif ($direction eq 'to') {
			# pack our tree and push it to the peer, then ask it to restart
			my $tar = &code_sync_tar($home);
			my $url = $rm->{'manager'} . '/manager/rsync_unpack?signatorial=' . $me . '&folder=' . $folder;
			my $res = eval { $rm->{'ua'}->post($url => { 'Content-Type' => 'application/x-gtar' } => $tar)->result };
			if ($res && $res->is_success) {
				$summary = 'Pushed ' . &subs::data_size(length $tar);
				my $rurl = $rm->{'manager'} . '/manager/president';
				eval { $rm->{'ua'}->inactivity_timeout(23)->post($rurl => form => { signatorial => $me, command => 'restart' })->result };
				push @result, 'Triggered Remote Restart';
			}
			else { $summary = 'Push failed'; }
		}
	}
	else { $summary = 'No such remote machine'; }

	my $result = ($summary ? $summary . '<br>' : '') . join('<br>', @result) . "\n";
	my $whoami = `whoami`;
	chomp $whoami;
	my $json = { type => 'command', whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(), command => 'remote_rsync ' . ($direction || ''), 'return' => $result, timestamp => $timestamp };

	&Websocket::send('server', $json);
	&subs::db_update('remote_machines', { server_time => &subs::rightNow(), connection => 'inactive' }, { uuid => $uuid, signatorial => $signatorial });
	$c->render('text' => $result);
}

# POST /manager/configure/remote_upgrade
sub action_10035 {
	my $c = shift;
	# The marker is either a forked pull's pid or the short-lived claim made by
	# the caller just before forking one. Only a real owner holds the button;
	# a claim whose fork never started (a restart took the tick) expires in two
	# minutes instead of reading as "already running" for half an hour.
	my $up = &subs::remote_upgrade_lock_state();
	if ($up->{'busy'}) {
		$c->render('text' => 'already running');
		$c->rendered;
		return;
	}
	# The UI uses its session; a peer calling this as the signed pull-now lever
	# (the target names the machine it should pull from) verifies against the
	# roster instead, so a lapsed cookie cannot wedge the sync again.
	my $requester = $c->param('signatorial');
	my $requester_rm = ($requester && &subs::db_select('remote_machines', undef, { signatorial => $requester })->hashes->[0]);
	unless ($c->session('authentication') eq 'approved' || ($requester_rm && $requester_rm->{'pubkey'} && &subs::peer_verify($c, $requester_rm))) {
		$c->rendered(403);
		return;
	}
	my $timestamp = $c->param('timestamp');
	my $ip = $c->param('ip');
	my $ssh_port = $c->param('ssh_port');
	my $hostname = $c->param('hostname');
	my $database = $c->param('database');
	my $direction = $c->param('direction');
	my $gimme = $c->param('gimme');
	my $full = $c->param('full');
	my $remote_signatorial = $c->param('signatorial');
	my $remote_device = $c->param('device');
	# A local caller (the CLI, or the Dev panel) may name the manager that just
	# answered when the roster's stored address is stale - a phone that moved to a
	# new LAN or tailnet address leaves the old ip behind, and the pull then dials
	# a dead host. Only a session may do this; a peer lever already knows its own
	# address and must not be able to make this machine fetch an arbitrary URL.
	my $manager_override = ($c->session('authentication') eq 'approved') ? $c->param('manager') : undef;
	my $params = {
		timestamp => $timestamp,
		ip => $ip,
		ssh_port => $ssh_port,
		hostname => $hostname,
		database => $database,
		gimme => $gimme,
		full => $full,
		remote_signatorial => $remote_signatorial,
		remote_device => $remote_device,
		manager => $manager_override,
		marker => 'running:claim'
	};
	# Claim the marker here, not in the child: the reconnector can walk several
	# peers in one tick, and a child that has not run yet leaves the next one
	# free to fork. The child adopts this claim and replaces it with its own pid.
	&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => 'running:claim' });
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		&remote_upgrade($c,$params);
	}, { name => 'remote upgrade', fork => 1 });
	$c->render('text' => 'ok');
}

# Dev's migration action: this machine (the donor) asks a linked new device to
# pull the whole house from here. The device keeps its own session and key; the
# request rides the signed pull-now lever, so a lapsed cookie cannot wedge it.
# The key itself is given by Connect (house key seeds the vault) or a ticket; a
# device that already has it takes this pull straight away.
# POST /manager/configure/migrate
sub action_10100 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved' && $c->session('privilege') eq 'citizen') {
		$c->render(json => { ok => 0, error => 'citizen only' });
		return;
	}
	my $device_sig = $c->param('signatorial') || '';
	my $rm = ($device_sig && &subs::db_select('remote_machines', undef, { signatorial => $device_sig })->hashes->[0]);
	unless ($rm) {
		$c->render(json => { ok => 0, error => 'device is not linked to this machine yet' });
		return;
	}
	my ($db,$database) = &subs::database_grabber();
	my $donor_sig = &subs::signatorial_designer();
	my $now = &subs::rightNow();
	my $hostname = `hostname`;
	chomp $hostname;
	my $donor_ip = $config->{'domain'} || '127.0.0.1';
	my $ua = &remote_useragent_maker({ signatorial => $device_sig });
	my $res;
	if ($ua->{'manager'}) {
		my $url = $ua->{'manager'} . '/manager/configure/remote_upgrade';
		$res = eval { $ua->{'ua'}->inactivity_timeout(30)->request_timeout(60)->post($url => form => {
			signatorial => $donor_sig,
			ip => $donor_ip,
			ssh_port => $config->{'ssh_port'},
			hostname => $hostname,
			database => $database,
			device => &subs::device_setter(),
			full => 1,
			timestamp => $now,
		})->result };
	}
	my $why = $@ ? $@ : ($res ? '' : 'the device did not answer');
	$why =~ s/\s+/ /g if $why;
	if ($res && !$res->is_success) {
		$why = 'the device answered ' . $res->code . ': ' . substr(($res->body // ''), 0, 160);
	}
	my $started = ($res && $res->is_success) ? 1 : 0;
	my $migration = &subs::random_string_creator(24);
	&subs::db_insert('migrations', {
		uuid => $migration,
		device_signatorial => $device_sig,
		device_name => $rm->{'hostname'},
		donor_signatorial => $donor_sig,
		state => ($started ? 'started' : 'failed'),
		note => ($started ? substr(($res->body // ''), 0, 200) : substr($why, 0, 200)),
		started => $now,
		updated => $now,
		server_time => $now,
	});
	$c->render(json => {
		ok => ($started ? 1 : 0),
		migration => $migration,
		($started ? () : (error => $why)),
	});
}

# GET /manager/configure/migrate/status
sub action_10157 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') {
		$c->render(json => { ok => 0 });
		return;
	}
	my $m = &subs::db_select('migrations', undef, { uuid => $c->param('uuid') || '' })->hashes->[0];
	unless ($m) { $c->render(json => { ok => 0, error => 'no such migration' }); return; }
	my $snap = &subs::db_query('select * from sync_snapshots where caller = ? order by cast(updated as integer) desc limit 1', $m->{'device_signatorial'})->hashes->[0] || {};
	my $steps = [];
	if ($snap->{'job'}) {
		my $sj = &subs::db_select('sync_jobs', undef, { uuid => $snap->{'job'} })->hashes->[0];
		$steps = eval { decode_json($sj->{'steps'} || '[]') } || [] if $sj;
	}
	my $state = $m->{'state'} || 'started';
	$state = 'done' if (($snap->{'state'} || '') eq 'done');
	$state = 'failed' if (($snap->{'state'} || '') eq 'failed');
	if ($state ne ($m->{'state'} || '')) {
		&subs::db_update('migrations', { state => $state, updated => &subs::rightNow() }, { uuid => $m->{'uuid'} });
		$m->{'state'} = $state;
	}
	$c->render(json => {
		ok => 1,
		migration => { uuid => $m->{'uuid'}, state => $state, device => $m->{'device_name'}, note => $m->{'note'} },
		snapshot => { state => ($snap->{'state'} || ''), size => $snap->{'size'}, steps => $steps },
	});
}

# POST /manager/configure/deploy_neighbours
sub action_10205 {
	my $c = shift;
	# Ask every neighbour to pull + restart (the http deploy route). Each device
	# also pulls on its own (git_watcher_check); this is the force-it-now lever.
	my $rms = &subs::db_select('remote_machines')->hashes;
	my @results;
	foreach my $rm ( @{$rms} ) {
		my $res = &subs::remote_deploy($rm);
		push @results, ($rm->{'hostname'} || $rm->{'fqdn'} || $rm->{'ip'}) . ': ' . $res->{'message'};
	}
	$c->render(json => { results => \@results });
}

# The Dev panel's Update now button. Unlike the boot-time watcher this is an
# explicit instruction: it uses the method's source (GitHub, a peer, or GitHub
# then a peer for None/Any) even when automatic updates are off. A dirty tree is
# reported, not clobbered, unless the person confirms the force path; a
# successful pull restarts after the reply is on the wire.
# POST /manager/configure/update_now
sub action_10222 {
	my $c = shift;
	$c->inactivity_timeout(180);
	my $result = &subs::update_now({ force => ($c->param('force') ? 1 : 0) });
	my $restart = 0;
	if ($result->{'status'} eq 'updated' || $result->{'status'} eq 'reset' || $result->{'status'} eq 'peer/updated') {
		my $repo = &subs::home('~/jawnos');
		if (-d &subs::home('~/.local/share/jawnos/desktop') && -x "$repo/desktop/install.sh") {
			`cd "$repo" && ./desktop/install.sh >/dev/null 2>&1`;
		}
		&subs::install_extras();
		$restart = 1;
	}
	$result->{'restart'} = $restart;
	$result->{'version'} = &subs::jawn_version();
	if ($restart) {
		my $how = $result->{'status'} || 'updated';
		$c->on(finish => sub { &subs::restart_request('Update now from the Dev panel (' . $how . ')') });
	}
	$c->render(json => $result);
}

# A code update that needs a system package leaves this request when sudo asks
# for a password. The manager reads it on start (and the Dev panel asks again),
# lists the packages that would be installed, and takes the password there.
# GET /manager/configure/deps_pending
sub action_50009 {
	my $c = shift;
	$c->render(json => {
		pending => &subs::deps_pending_read() || undef,
		local   => &deps_request_is_local($c) ? 1 : 0,
	});
}

# POST /manager/configure/deps_install
# sudo -v spends the password to refresh the sudo timestamp; it travels on
# stdin, never in an argument and never into a log. The same --after-update the
# watcher ran then installs with sudo -n, so there is one implementation.
sub action_50010 {
	my $c = shift;
	$c->inactivity_timeout(600);
	unless (&deps_request_is_local($c)) {
		$c->render(json => { ok => 0, error => 'Only this machine can install its own packages.' });
		return;
	}
	my $password = $c->param('password');
	unless (defined $password && length $password) {
		$c->render(json => { ok => 0, error => 'Enter the root password.' });
		return;
	}
	my $verified = 0;
	{
		# sudo may exit before it reads the line when its timestamp is still
		# valid; a SIGPIPE on our write must not become a server error.
		local $SIG{'PIPE'} = 'IGNORE';
		if (open(my $fh, '|-', 'sudo', '-S', '-p', '', '-v')) {
			print $fh $password, "\n";
			close $fh;
			$verified = ($? == 0) ? 1 : 0;
		}
	}
	$password = '';
	unless ($verified) {
		$c->render(json => { ok => 0, error => 'That password was not accepted.' });
		return;
	}
	my $result = &subs::install_system_dependencies(&subs::home('~/jawnos'));
	$result->{'pending'} = &subs::deps_pending_read();
	$result->{'local'} = 1;
	$c->render(json => $result);
}

# GET /manager/configure/release_schedule
# The release timer is the authority's own: this answers for the machine the
# Manager runs on, and the schedule is written there.
sub action_50011 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') {
		$c->render(json => { ok => 0, error => 'not signed in' }, status => 403);
		return;
	}
	$c->render(json => &subs::release_schedule_state());
}

# POST /manager/configure/release_schedule_save
sub action_50012 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') {
		$c->render(json => { ok => 0, error => 'not signed in' }, status => 403);
		return;
	}
	my $saved = &subs::release_schedule_save($c->param('phrase'), {
		dry_run => $c->param('dry_run') ? 1 : 0,
	});
	$c->render(json => $saved);
}

# A root password may only be entered at this machine's own console. A phone or
# a peer that reached the Manager over the mesh must not be able to install
# packages here, so the same loopback/local-address rule the padlock uses.
sub deps_request_is_local {
	my ($c) = @_;
	my $local = $c->tx->local_address || '';
	my $remote = $c->tx->remote_address || '';
	return 1 if $local && $remote && $local eq $remote;
	return 1 if $remote =~ /^(?:127\.|::1$|::ffff:127\.)/;
	return 0;
}

# POST /manager/configure/remote_device_disconnect
sub action_11684 {
	my $c = shift;
	my $ip = $c->param('ip');
	my $signatorial = $c->param('signatorial');
	my ($db,$database,$sql) = &subs::database_grabber();
#	&subs::db_delete('remote_machines', { ip => $ip });
	&subs::db_delete('remote_machines', { signatorial => $signatorial });
	$c->render('text' => 'ok');
}

# GET /manager/configure/remote_device_connect
sub action_11695 {
	my $c = shift;
	my $manager = $c->param('manager');
	my $filename = $c->param('filename');
	my $timestamp = $c->param('timestamp');
	my $ip = $c->param('ip');
	my $port = $c->param('port');
	my $password = &subs::session_suds($c);
	my $browser_tab_id = $c->param('browser_tab_id');
	my $browser_tab = $c->param('browser_tab');
	my $name = $c->session('name');
	my $signatorial = $c->param('signatorial');
	my $tunnel = $c->param('tunnel');
	my $uuid = $c->param('uuid');
	my $nic = $c->param('nic');
	my $returner = &remote_device_connect({
		manager => $manager,
		filename => $filename,
		timestamp => $timestamp,
		ip => $ip,
		password => $password,
		name => $name,
		browser_tab_id => $browser_tab_id,
		browser_tab => $browser_tab,
		signatorial => $signatorial,
		nic => $nic,
		privilege => 'citizen',
		tunnel => $tunnel
	});
	my $device = &subs::db_select('devices', undef, { uuid => $uuid })->hash;
	my $address = decode_json $device->{'address'};
	my $neighbour = [];
	@{$neighbour} = grep { $ip eq $_->{'ip'} || $_->{'signatorial'} eq $returner->{'body'}->{'signatorial'} } @{$address->{$nic}->{'neigh'}};
	$neighbour->[0]->{'signatorial'} = $returner->{'body'}->{'signatorial'};
	$neighbour->[0]->{'fqdn'} = $returner->{'body'}->{'fqdn'};
	$neighbour->[0]->{'purpose'} = $returner->{'body'}->{'device'};
	$address = encode_json $address;
	&subs::db_update('devices', { address => $address }, { uuid => $uuid });
	$c->render(json => $returner);
}

# POST /manager/configure/remote_machine_input
sub action_12141 {
	my $c = shift;
	my $signatorial = $c->param('signatorial');
	my $uuid = $c->param('uuid');
	my $value = $c->param('value');
	my $name = $c->param('name');
	# ssh credentials are gone - only benign fields ride this route now
	if ($name && $name ne 'username' && $name ne 'password') {
		&subs::db_update('remote_machines', { $name => $value }, { signatorial => $signatorial, uuid => $uuid });
	}

	$c->render(text => 'ok');
}

# A peer's signing key can outlive the row it was pinned to: a replaced row, a
# re-imaged machine, or a duplicate discovery leaves the old key on file and
# every signed request from the real machine comes back 403 (which reads as
# "not a known peer", not "wrong key"). A person logged in here can re-pin the
# key the machine actually holds. Session-gated (not in the peer allowlist), and
# it only accepts a PEM public key.
# POST /manager/configure/remote_machine_key_reset
sub action_12160 {
	my $c = shift;
	my $signatorial = $c->param('signatorial') || '';
	my $pubkey = $c->param('pubkey') || '';
	return $c->render(json => { ok => 0, error => 'no machine named' }) unless $signatorial =~ /^[0-9a-fA-F]{16,64}$/;
	$pubkey =~ s/\r//g;
	$pubkey =~ s/\s+$//;
	unless ($pubkey eq '' || index($pubkey, '-----BEGIN PUBLIC KEY-----') == 0) {
		return $c->render(json => { ok => 0, error => 'that is not a public key' });
	}
	my $known = &subs::db_select('remote_machines', ['signatorial'], { signatorial => $signatorial })->hashes->[0];
	return $c->render(json => { ok => 0, error => 'no such machine' }) unless $known;
	&subs::db_update('remote_machines', { pubkey => $pubkey }, { signatorial => $signatorial });
	$c->render(json => { ok => 1, cleared => ($pubkey eq '' ? 1 : 0) });
}

# A citizen sets what a peer house may do here: a lease, not a name. The ladder
# is none < visitor < resident < trusted. A resident may start and stop
# appointments, toggle things, press Go and open a Manager; configuration stays
# citizen-only at the session gate and is never a peer grant. expires is epoch
# milliseconds; days is a convenience for a lease in whole days. The route
# refuses a citizen row, and refuses to grant citizenship to anyone.
# POST /manager/configure/remote_machine_grant
sub action_12181 {
	my $c = shift;
	unless (($c->session('authentication') || '') eq 'approved' && ($c->session('privilege') || '') eq 'citizen') {
		return $c->render(json => { ok => 0, error => 'citizen only' });
	}
	my $uuid = $c->param('uuid') || '';
	my $signatorial = $c->param('signatorial') || '';
	my $rm = $uuid ? &subs::db_select('remote_machines', undef, { uuid => $uuid })->hash
		: $signatorial ? &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hash
		: undef;
	return $c->render(json => { ok => 0, error => 'no machine named' }) unless $rm;
	return $c->render(json => { ok => 0, error => 'that machine is a citizen' }) if ($rm->{'privilege'} || '') eq 'citizen';
	my $privilege = $c->param('privilege') || '';
	return $c->render(json => { ok => 0, error => 'citizen is not a peer grant' }) if $privilege eq 'citizen';
	# a peer that was never classified becomes a peer when it is granted a scope
	$privilege = 'peer' if $privilege eq '' && ($rm->{'privilege'} || '') eq '';
	my $expires = $c->param('expires') || '';
	my $days = $c->param('days');
	if (defined $days && $days ne '' && $days !~ /^\d+$/) {
		return $c->render(json => { ok => 0, error => 'days must be a whole number' });
	}
	$expires = &subs::rightNow() + $days * 86400000 if $expires eq '' && defined $days && $days ne '';
	if ($expires ne '' && $expires !~ /^\d+$/) {
		return $c->render(json => { ok => 0, error => 'expires must be epoch milliseconds' });
	}
	my $ok = &subs::peer_grant_setter({
		uuid => $rm->{'uuid'},
		scope => $c->param('scope') || '',
		privilege => ($privilege eq '' ? undef : $privilege),
		expires => $expires,
	});
	return $c->render(json => { ok => 0, error => 'that is not a grant' }) unless $ok;
	my $row = &subs::db_select('remote_machines', undef, { uuid => $rm->{'uuid'} })->hash || {};
	return $c->render(json => {
		ok => 1,
		uuid => $row->{'uuid'},
		signatorial => $row->{'signatorial'},
		hostname => $row->{'hostname'},
		privilege => $row->{'privilege'},
		scope => $row->{'grant_scope'},
		expires => $row->{'grant_expires'},
	});
}

# POST /manager/configure/remote_machine/tunnel/toggle
sub action_12224 {
	my $c = shift;
	my $ssh_port = $c->param('ssh_port');
	my $ip = $c->param('ip');
	my $signatorial = $c->param('signatorial');
	my $uuid = $c->param('uuid');
	my $status = $c->param('status');
	my $nic = $c->param('nic');
	my $domain = $config->{'domain'} || $c->req->url->to_abs->host;
	my $device = &subs::db_select('devices', undef, { uuid => $uuid })->hashes->[0];
	my $address = eval { return decode_json $device->{'address'} };
	my @remote_device = grep { $_->{'ip'} eq $ip } @{$address->{$nic}->{'neigh'}};
	my $rd = $remote_device[0];
	if ($status eq 'active') {
		$status = 'off';
	} else {
		$status = 'active';
	}
	$rd->{'tunnel'} = $status;

	@{$address->{$nic}->{'neigh'}} = grep { $_->{'ip'} ne $ip } @{$address->{$nic}->{'neigh'}};
	push @{$address->{$nic}->{'neigh'}}, $rd;
	@{$address->{$nic}->{'neigh'}} = sort { $a->{'ip'} cmp $b->{'ip'} } @{$address->{$nic}->{'neigh'}};
	my $jaddress = encode_json $address;
	&subs::db_update('devices', { address => $jaddress }, { uuid => $uuid });

	my $tun = { ip => $ip, signatorial => $signatorial, domain => $domain };
	if ($status eq 'active') {
		&subs::tunnel_starter($tun);
	} else {
		&subs::tunnel_stopper($tun);
	}
	$c->render(json => $rd);
}

# GET /manager/configure/tunnel/list
sub action_12258 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $returner = {
		html => $c->render_to_string(
			template => 'configure/tunnels',
		)
	};

	$c->render(json => $returner);

}

# POST /manager/configure/remote_machine/tunnel/request
sub action_12285 {
	my $c = shift;
	unless (&tunnel_rail_allowed($c)) { $c->rendered(403); return; }
	my $signatorial = $c->param('signatorial');
	my $status = $c->param('status');
	my $ports = eval { return decode_json $c->param('ports') } || {};
	my $batch_uuid = $c->param('batch_uuid');
	my $returner = { status => $status, batch_uuid => $batch_uuid, signatorial => $signatorial };
	require JawnOS::Platform::Ports;
	&subs::db_query('delete from tunnels where signatorial = ? and batch_uuid != ?', $signatorial, $batch_uuid);
	&subs::db_query('delete from tunnels where status=? and server_time < ?', 'reserved', &subs::rightNow() - 60000);
	# Every port a live or half-built tunnel still owns, in one query. The old
	# per-candidate select was the same rule, and rows outside the configured
	# range stay readable here so a live tunnel is not stranded after a restart.
	my %tunnel_taken;
	foreach my $row (&subs::db_query(
		'select in_port from tunnels where status = ? or status = ?',
		'reserved', 'active',
	)->hashes) {
		$tunnel_taken{ int($row->{'in_port'}) } = 1
			if defined $row->{'in_port'} && $row->{'in_port'} =~ /^[0-9]+$/;
	}
	my ($new_ports, $port_error) = JawnOS::Platform::Ports::reserve_tunnel_ports(
		scalar(@gb::ports),
		config => $config || {},
		held   => [ map { $ENV{$_} } @gb::ports ],
		taken  => sub { $tunnel_taken{ $_[0] } ? 1 : 0 },
	);
	if ($port_error) {
		$returner->{'error'} = $port_error;
		$c->render(json => $returner, status => 503);
		return;
	}
	my $port_index = 0;
	foreach my $p ( @gb::ports ) {
		my $reservation_uuid = &subs::random_string_creator(29);
		my $new_port = $new_ports->[$port_index++];
		$returner->{$p} = { dest => $ports->{$p}, source => $new_port, reservation_uuid => $reservation_uuid };
		&subs::db_insert('tunnels', { in_port => $new_port, uuid => $reservation_uuid, status => 'reserved' });

	}

	$c->render(json => $returner);
}

# POST /manager/configure/remote_machine/tunnel/confirm
sub action_12334 {
	my $c = shift;
	unless (&tunnel_rail_allowed($c)) { $c->rendered(403); return; }
	my $remote_address = $c->tx->remote_address;
	my $tunnel = eval { return decode_json $c->param('tunnel') } || {};
	my $signatorial = $c->param('signatorial');
	my $uuid = $c->param('uuid');
	my $returner = { tunnel => $tunnel };
	my $tun = &subs::db_select('tunnels', undef, { uuid => $uuid })->hashes->[0];
	my $tunnel_duties = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'tunnel_duties' }) } || [];
	my $tunnel_duty_count = scalar @{$tunnel_duties};
	if ($tun->{'uuid'}) {
		$tunnel->{'status'} = 'active';
		$tunnel->{'signatorial'} = $signatorial;
		$tunnel->{'direction'} = 'out';
		$tunnel->{'ip'} = $remote_address;
		&subs::db_update('tunnels', $tunnel, { uuid => $uuid, status => 'reserved' });
		push @{$tunnel_duties}, $tunnel unless grep { $_->{'batch_uuid'} eq $tunnel->{'batch_uuid'} } @{$tunnel_duties};
	}
	if (scalar @{$tunnel_duties} != $tunnel_duty_count) {
		my $jtd = encode_json $tunnel_duties;

		&subs::setting_setter({ app => '__president', setting => 'tunnel_duties', value => $jtd });
	}
	&Websocket::send('server', { console => &Websocket::console_command('tunnelLister')});
	# and the Dev panel: a tunnel coming up adds the peer to this hub's addresses,
	# so refresh it live rather than wait for a manual Scan
	&Websocket::send('server', { console => &Websocket::console_command('deviceLister')});
	$c->render(json => $returner);
}

# POST /manager/configure/remote_machine/tunnel/close
sub action_12364 {
	my $c = shift;
	unless (&tunnel_rail_allowed($c)) { $c->rendered(403); return; }
	my $tunnel = eval { return decode_json $c->param('tunnel') } || {};
	my $signatorial = $c->param('signatorial');
	my $status = $c->param('status');
	&subs::db_update('tunnels', { server_time => &subs::rightNow(), status => 'closed' }, { uuid => $tunnel->{'uuid'}, signatorial => $tunnel->{'signatorial'} });
	&Websocket::send('server', { console => &Websocket::console_command('tunnelLister')});
	&Websocket::send('server', { console => &Websocket::console_command('deviceLister')});

	$c->render(json => { tunnel => $tunnel, signatorial => $signatorial, status => $status });

}

# POST /manager/configure/join_request
# The mesh only ever refreshed a peer it already knew, so a new machine had no
# way in. This is the first half of the introduction: the machine that wants to
# join makes a short code and hands the house a pending request. The request
# lives ten minutes (JOIN_REQUEST_TTL_MS), long enough to read the code out loud
# and type it on the other machine; every read deletes an older one.
sub action_12450 {
	my $c = shift;
	my $now = &subs::rightNow();
	# A forwarded request comes from a machine the house has never met: it has no
	# session and no pinned key, so this branch records the pending request and
	# nothing else. Possession of the code still buys nothing without a citizen
	# accepting it on the house side.
	if ($c->param('forward')) {
		my $code = $c->param('code') || '';
		return $c->render(json => { ok => 0, error => 'no code' }) unless $code =~ /^\d{6}$/;
		my $address = $c->param('address') || '';
		return $c->render(json => { ok => 0, error => 'no address' }) unless length $address;
		# A repeated code replaces the earlier request rather than stacking up.
		&subs::db_query('delete from cache where context = ? and server_time < ?', 'join_request', $now - $subs::JOIN_REQUEST_TTL_MS);
		&subs::db_delete('cache', { context => 'join_request', subcontext => $code });
		my $data = {
			code => $code,
			address => $address,
			name => $c->param('name') || '',
			signatorial => $c->param('signatorial') || '',
			pubkey => $c->param('pubkey') || '',
			device => $c->param('device') || '',
			ost => $c->param('ost') || '',
			version => $c->param('version') || '',
			port => $c->param('port') || '',
		};
		&subs::db_insert('cache', {
			uuid => &subs::random_string_creator(15),
			context => 'join_request',
			subcontext => $code,
			app => '__president',
			data => encode_json($data),
			server_time => $now,
			timestamp => $now,
		});
		# This rail answers anyone, so keep the pending list bounded.
		&subs::db_query("delete from cache where context = 'join_request' and uuid not in (select uuid from cache where context = 'join_request' order by server_time desc limit 50)");
		return $c->render(json => { ok => 1, code => $code });
	}
	unless (($c->session('authentication') || '') eq 'approved' && ($c->session('privilege') || '') eq 'citizen') {
		return $c->render(json => { ok => 0, error => 'citizen only' });
	}
	my $target = $c->param('address') || '';
	$target =~ s/^\s+|\s+$//g;
	$target =~ s{/+$}{};
	return $c->render(json => { ok => 0, error => 'enter the house address' }) unless $target =~ /^[A-Za-z0-9._:-]+$/;
	my $code = &subs::random_string_creator(6, '0-9');
	my $name = &subs::machine_name() || '';
	my $signatorial = &subs::signatorial_designer() || '';
	my $pubkey = &subs::peer_pubkey() || '';
	my $port = $ENV{PORT_AHOY} || $config->{'working_port'} || $config->{'port'} || '';
	my $self_address = ($config->{'domain'} || '127.0.0.1') . (length $port ? ':' . $port : '');
	my $identity = {
		code => $code,
		name => $name,
		signatorial => $signatorial,
		pubkey => $pubkey,
		device => &subs::device_setter(),
		ost => $^O,
		version => &subs::jawn_version(),
		port => $port,
	};
	my $data = { %{$identity}, address => $target };
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'join_request', $now - $subs::JOIN_REQUEST_TTL_MS);
	&subs::db_insert('cache', {
		uuid => &subs::random_string_creator(15),
		context => 'join_request',
		subcontext => $code,
		app => '__president',
		data => encode_json($data),
		server_time => $now,
		timestamp => $now,
	});
	# The code is only useful where the person will type it, so hand the pending
	# request to the house as well. A house that cannot be reached is reported,
	# not hidden: the code is real here but cannot be accepted there.
	my $base = $target =~ m{^https?://} ? $target : 'https://' . $target;
	# The house needs this machine's address, not its own; keep the target in the
	# local row (what the person asked for) and send the self address across.
	my $forward = { %{$identity}, address => $self_address };
	my $res = eval {
		Mojo::UserAgent->new->insecure(1)->inactivity_timeout(10)->request_timeout(20)
			->post($base . '/manager/configure/join_request' => form => { forward => 1, %{$forward} })->result;
	};
	my $delivered = 0;
	if ($res) {
		my $answer = eval { decode_json $res->body } || {};
		$delivered = $answer->{'ok'} ? 1 : 0;
	}
	$c->render(json => { ok => 1, code => $code, delivered => $delivered, expires => $subs::JOIN_REQUEST_TTL_MS });
}

# POST /manager/configure/join_accept
# The house's half: a citizen reads the code the new machine showed, and this
# writes the peer row the mesh needs. The grant is the one the house gives its
# own phone and tablet - citizen, trusted, no expiry - and it is written through
# peer_grant_setter so the lease rules stay in one place. A code is spent by the
# accept: the pending row is deleted before the row is written, so a second press
# cannot use it again.
sub action_12451 {
	my $c = shift;
	unless (($c->session('authentication') || '') eq 'approved' && ($c->session('privilege') || '') eq 'citizen') {
		return $c->render(json => { ok => 0, error => 'citizen only' });
	}
	my $code = $c->param('code') || '';
	$code =~ s/\s+//g;
	return $c->render(json => { ok => 0, error => 'enter the six-digit code' }) unless $code =~ /^\d{6}$/;
	my $now = &subs::rightNow();
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'join_request', $now - $subs::JOIN_REQUEST_TTL_MS);
	my $pending = &subs::db_select('cache', undef, { context => 'join_request', subcontext => $code })->hash;
	return $c->render(json => { ok => 0, error => 'that code is not waiting, or it has expired' }) unless $pending;
	my $data = eval { decode_json($pending->{'data'}) } || {};
	my $address = $c->param('address') || $data->{'address'} || '';
	my $name = $c->param('name') || $data->{'name'} || '';
	return $c->render(json => { ok => 0, error => 'the request carries no address' }) unless length $address;
	# One use only: spend the code before anything else can find it.
	&subs::db_delete('cache', { uuid => $pending->{'uuid'} });
	my $addr = $address;
	$addr =~ s{^https?://}{};
	$addr =~ s{/.*$}{};
	my ($host, $addr_port) = $addr =~ /^(.+?)(?::(\d+))?$/;
	my $port = $addr_port || $data->{'port'} || '';
	my $manager = 'https://' . $host . (length $port ? ':' . $port : '') . '/manager';
	my $signatorial = $data->{'signatorial'} || '';
	# A pending request comes from a stranger, so keep only shapes the roster can
	# use: a signatorial the mesh defines and a PEM public key.
	$signatorial = '' unless $signatorial =~ /^[0-9a-fA-F]{16,64}$/;
	my $pubkey = $data->{'pubkey'} || '';
	$pubkey = '' unless index($pubkey, '-----BEGIN PUBLIC KEY-----') == 0;
	my $known = $signatorial ? &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hash : undef;
	my $uuid = ($known && $known->{'uuid'}) ? $known->{'uuid'} : &subs::random_string_creator(15);
	my $row = {
		uuid => $uuid,
		ip => $host,
		fqdn => $host,
		port => $port,
		manager => $manager,
		signatorial => $signatorial,
		pubkey => $pubkey,
		hostname => $name,
		device => $data->{'device'} || '',
		ost => $data->{'ost'} || '',
		status => 'connected',
		connection => 'active',
		server_time => $now,
		timestamp => $now,
	};
	if ($known) { &subs::db_update('remote_machines', $row, { uuid => $uuid }); }
	else { &subs::db_insert('remote_machines', $row); }
	# The same grant a citizen's own phone and tablet carry.
	&subs::peer_grant_setter({ uuid => $uuid, scope => 'trusted', privilege => 'citizen', expires => '' });
	$c->render(json => { ok => 1, uuid => $uuid, name => $name, address => $host . (length $port ? ':' . $port : '') });
}

# GET /manager/configure/qa_device_ready
sub action_50001 {
	my $c = shift;
	# The panel asks about the chosen device; a peer asks about itself. A peer
	# request names the caller in `signatorial` and rides the signed rail, so it
	# is authenticated the same way every other peer call is.
	my $caller = $c->param('signatorial');
	my $peer_ok = 0;
	if (defined $caller && length $caller) {
		# A direct roster row, or a machine the hub listed in its mirrors;
		# both are proven by the same pinned key.
		my $rm = &subs::peer_roster_row($caller);
		$peer_ok = ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) ? 1 : 0;
	}
	unless ($c->session('authentication') eq 'approved' || $peer_ok) {
		$c->render(json => { ok => 0, error => 'not signed in' }, status => 403);
		return;
	}
	my $result = &subs::qa_readiness_for($c->param('target') // '');
	$c->render(json => $result);
}

# GET /manager/configure/qa_reports
# The finished nightly runs the panel shows. The chosen machine answers for its
# own disk; a peer asks the owner of the data, never a copy kept here, so the
# laptop sees the run the QA box actually did.
sub action_50008 {
	my $c = shift;
	my $caller = $c->param('signatorial');
	my $peer_ok = 0;
	if (defined $caller && length $caller) {
		# A direct roster row, or a machine the hub listed in its mirrors;
		# both are proven by the same pinned key.
		my $rm = &subs::peer_roster_row($caller);
		$peer_ok = ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) ? 1 : 0;
	}
	unless ($c->session('authentication') eq 'approved' || $peer_ok) {
		$c->render(json => { ok => 0, error => 'not signed in' }, status => 403);
		return;
	}
	$c->render(json => &subs::qa_reports_for($c->param('target') // ''));
}

# POST /manager/configure/qa_device_target
sub action_50002 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') {
		$c->render(json => { ok => 0, error => 'not signed in' }, status => 403);
		return;
	}
	# The card has several pickers. `field=note_limit` saves only the notes-per-night
	# number, so a phone (which cannot be the nightly machine) can still set the
	# house's queue length; the number is clamped 1..25 here, not in the browser.
	if (($c->param('field') // '') eq 'note_limit') {
		$c->render(json => &subs::qa_note_limit_save($c->param('note_limit')));
		return;
	}
	# `field=ux_model` saves the model the 05:30 UX loop judges with. Empty is
	# allowed (the night then skips every note); a value must look like a model
	# id, so a hand-made POST cannot store a sentence or a shell fragment.
	if (($c->param('field') // '') eq 'ux_model') {
		$c->render(json => &subs::qa_ux_model_save($c->param('ux_model')));
		return;
	}
	# `field=lanes` saves which sources the coding night draws from. The list is
	# canonicalised here, and an empty choice is refused rather than stored.
	if (($c->param('field') // '') eq 'lanes') {
		$c->render(json => &subs::qa_coding_lanes_save($c->param('lanes')));
		return;
	}
	# The warden's report switch. Only the literal off is off; a hand-made POST
	# cannot store a sentence or turn an unknown value into a new state.
	if (($c->param('field') // '') eq 'warden_report') {
		my $value = (($c->param('warden_report') // '') eq 'off') ? 'off' : 'on';
		&subs::setting_setter({ app => '__president', setting => 'qa_warden_report', device => 'all', value => $value });
		$c->render(json => { ok => 1, value => $value });
		return;
	}
	# The value is a signatorial, the literal 'none' (the whole nightly system
	# off), or '' for this machine. A phone or tablet is refused here as well as
	# at install, so a hand-made POST cannot pin the nightly to a device that
	# cannot run it; 'none' names no device, so any signed-in machine may choose it.
	my $result = &subs::qa_nightly_save($c->param('signatorial') // '');
	$c->render(json => $result);
}

# POST /manager/configure/qa_device_install
sub action_50003 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') {
		$c->render(json => { ok => 0, error => 'not signed in' }, status => 403);
		return;
	}
	my $guard = &subs::qa_install_guard($c->param('signatorial') // '');
	unless ($guard->{'ok'}) {
		$c->render(json => $guard);
		return;
	}
	my $dry = $c->param('dry_run') ? 1 : 0;
	my $result;
	if ($guard->{'target'}->{'local'}) {
		$result = &subs::qa_install_local({ dry_run => $dry });
	}
	else {
		# The target's own environment is prepared by the target, through the
		# remote-command rail every peer call already uses (signed and
		# peer-verified at the far end) - not by a new unauthenticated route.
		$result = &remote_command_send({
			uuid => $guard->{'target'}->{'uuid'},
			verb => 'qa_install',
			args => { dry_run => $dry },
		});
		# the peer wraps its work in the remote-command envelope; hand the panel
		# the same shape it would have seen locally
		$result = $result->{'observation'}
			if ref $result eq 'HASH' && $result->{'ok'} && ref $result->{'observation'} eq 'HASH';
	}
	$c->render(json => $result);
}

# GET /manager/configure/qa_schedule
sub action_50004 {
	my $c = shift;
	# The panel asks about the chosen device; a peer asks about itself. A peer
	# request names the caller in `signatorial` and rides the signed rail, so it
	# is authenticated the same way every other peer call is, and a peer is only
	# ever answered about the machine it is running on.
	my $caller = $c->param('signatorial');
	my $peer_ok = 0;
	if (defined $caller && length $caller) {
		# A direct roster row, or a machine the hub listed in its mirrors;
		# both are proven by the same pinned key.
		my $rm = &subs::peer_roster_row($caller);
		$peer_ok = ($rm && $rm->{'pubkey'} && &subs::peer_verify($c, $rm)) ? 1 : 0;
	}
	unless ($c->session('authentication') eq 'approved' || $peer_ok) {
		$c->render(json => { ok => 0, error => 'not signed in' }, status => 403);
		return;
	}
	my $result = $peer_ok ? &subs::qa_schedule_local() : &subs::qa_schedule_for($c->param('target') // '');
	$c->render(json => $result);
}

# POST /manager/configure/qa_schedule_save
sub action_50005 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') {
		$c->render(json => { ok => 0, error => 'not signed in' }, status => 403);
		return;
	}
	# All three times are validated server-side before anything is written. The
	# target is the machine the panel has chosen; a phone or a tablet is refused
	# here, so a hand-made POST cannot retime a house timer from one.
	my $dry = $c->param('dry_run') ? 1 : 0;
	my $times = {
		suite => $c->param('suite_time'),
		ux => $c->param('ux_time'),
		coding => $c->param('coding_time'),
	};
	my $saved = &subs::qa_times_save($times, {
		signatorial => $c->param('signatorial') // &subs::qa_nightly_device(),
	});
	unless ($saved->{'ok'}) { $c->render(json => $saved); return }
	my $target = $saved->{'target'};
	my $retime;
	if ($target->{'local'}) {
		$retime = &subs::qa_retime_local({ times => $saved->{'times'}, dry_run => $dry });
	}
	else {
		# The chosen machine retimes its own timers, through the same signed rail
		# the readiness and install actions use.
		$retime = &remote_command_send({
			uuid => $target->{'uuid'},
			verb => 'qa_retime',
			args => { times => $saved->{'times'}, dry_run => $dry },
		});
		$retime = $retime->{'observation'}
			if ref $retime eq 'HASH' && $retime->{'ok'} && ref $retime->{'observation'} eq 'HASH';
	}
	$c->render(json => {
		%{$saved},
		retime => $retime,
		retime_ok => (ref $retime eq 'HASH' && $retime->{'ok'}) ? 1 : 0,
	});
}

# POST /manager/configure/qa_run
sub action_50006 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') {
		$c->render(json => { ok => 0, error => 'not signed in' }, status => 403);
		return;
	}
	my $run = $c->param('run') // '';
	unless (&subs::qa_run_lookup($run)) {
		$c->render(json => { ok => 0, error => 'unknown run', run => $run });
		return;
	}
	# Run now starts a unit, so it runs the same guard as a retime: the target
	# must be a computer or server, and it must be the machine the house chose.
	my $sig = defined $c->param('signatorial') ? $c->param('signatorial') : '';
	$sig = &subs::qa_nightly_device() unless length $sig;
	my $guard = &subs::qa_run_guard($sig, {});
	unless ($guard->{'ok'}) { $c->render(json => $guard); return }
	my $dry = $c->param('dry_run') ? 1 : 0;
	my $target = $guard->{'target'};
	my $result;
	if ($target->{'local'}) {
		$result = &subs::qa_run_now_local($run, { dry_run => $dry });
	}
	else {
		$result = &remote_command_send({
			uuid => $target->{'uuid'},
			verb => 'qa_run_now',
			args => { run => $run, dry_run => $dry },
		});
		$result = $result->{'observation'}
			if ref $result eq 'HASH' && $result->{'ok'} && ref $result->{'observation'} eq 'HASH';
	}
	$c->render(json => $result);
}

# POST /manager/configure/coding_push_repo
sub action_50007 {
	my $c = shift;
	unless ($c->session('authentication') eq 'approved') {
		$c->render(json => { ok => 0, error => 'not signed in' }, status => 403);
		return;
	}
	# `field` picks the checkout: `repo` is this JawnOS tree, `app_repo` the
	# Android app. The value is `owner/name` or an https URL; empty clears it back
	# to the checkout's own remote. The helper validates before anything is
	# written, so a hand-made POST cannot store spaces or credentials.
	my $which = (($c->param('field') // '') eq 'app_repo') ? 'app' : 'repo';
	my $saved = &subs::coding_push_repo_save($which, $c->param('value'));
	$c->render(json => $saved);
}

1;
