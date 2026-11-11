package Manager;

# sesh_check: route actions moved out of Manager.pl, one sub per route so a
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

# POST /sesh_check
sub action_7519 {
	my $c = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	# A peer login binds its body to the signed query with a digest; the browser
	# Gate sends none, so only a login carrying one is checked.
	my $body_sha = $c->param('body_sha256') || '';
	if ($body_sha ne '') {
		my %fields = map { $_ => ($c->param($_) // '') } qw(numerics president backup remote_timestamp manager_file);
		unless (&sesh_body_digest(\%fields) eq $body_sha) {
			$log->info('sesh_check refused: body digest mismatch');
			$c->render(json => { authentication => 'denied', error => 'body digest mismatch' });
			return;
		}
	}
	my $secret = &password_maker($c);
	my $reject_count = $c->session('reject_count');
	my $start_time = &subs::rightNow();
	my $backup = $c->param('president') || $c->param('backup') || $c->param('bullshit');
	my $server_time = &subs::rightNow();
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $remote_timestamp = $c->param('remote_timestamp');
	my $me_warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'customs', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d');
	my $t = localtime;
	my $db_exists = 0;
	$backup = &subs::home($backup);
	# The backup is named by the request; keep it inside the house or refuse.
	unless (length $backup && &subs::path_is_within($backup, &subs::home('~'))) {
		$c->render(json => { authentication => 'denied', error => 'not a house backup' });
		return;
	}
	my $computer = $c->param('computer');
	my $local_address = $c->tx->local_address;
	my $remote_address = $c->tx->remote_address;
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";
	if ($backup =~ /\.enc\z/i) {
		my $backup_file = $backup;
		$backup_file =~ s/\.enc\z//i;
		$database = $backup_file . '.db';
		unless (-e $database && -s $database > 5000) {
			my $tail_command = 'tail ' . &subs::shell_quote($backup);
			my $data = `$tail_command`;
			my @split_data = split $universal_splitter, $data;
			$encryption_standard = &subs::decrypter($secret, $split_data[1]);
			&subs::openssl_file_crypt('d', $encryption_standard, $secret, $backup, $database, 0, 1);

		}
		if (-e $database && -s $database > 5000) {
			$sql = Mojo::SQLite->new('sqlite:' . $database);
			if (eval { $sql->db }) {
				$db_exists = 1;
			}
			else {
				system('shred', '-u', $database);
				$db_exists = 0;
			}
		}

	}
	elsif ($backup =~ /db$/) {
		$database = $backup;
		$sql = Mojo::SQLite->new('sqlite:' . $database);
		$db_exists = 1;
	}
	if ($db_exists == 1) {
		my ($db,$database) = &subs::database_grabber();

		&update_database($c);

	#	&subs::db_insert('appointments',{ warranty => $me_warranty, uuid => &subs::random_string_creator(40), app => "customs", type => "id", timestamp => $timestamp, server_time => $server_time }) if $db_exists == 1;
		# the password opens the door row; the key comes from this machine's
		# vault (login_gate falls back to the old password-is-the-key world
		# and migrates it on the spot)
		my ($authorized, $suds_key) = &subs::login_gate($secret);

		if ($authorized) {
			# A login that names a machine must prove the name with that machine's
			# key before the session is minted. A name already on the roster is
			# verified against its pinned key; a first contact is pinned from the key
			# it offers (the password already opened the door). A name that does not
			# verify refuses the login, so a password-holder cannot borrow another
			# machine's lease.
			my $claimed = lc($c->param('signatorial') || '');
			my $peer_row;
			my $peer_proved = 0;   # only a body-bound, signed login is a peer
			if ($claimed =~ /^[0-9a-f]{16,64}$/) {
				$peer_row = &subs::db_select('remote_machines', undef, { signatorial => $claimed })->hash;
				# Only the new body-bound login carries a digest. A caller from the
				# previous version sends the name without one; it may still log in,
				# but its name is not proved and it is not a peer session.
				if ($peer_row && $body_sha ne '') {
					# The name is proved only by a key that is already pinned and a
					# grant that still allows a house session. A keyless row is not
					# first contact here: the password is bootstrap, not a key.
					unless ($peer_row->{'pubkey'} && &subs::peer_verify_strict($c, $peer_row)
						&& &subs::peer_allows($c, $peer_row, 'resident')) {
						$log->info('sesh_check peer login refused: ' . $claimed . ' did not sign');
						$c->render(json => { authentication => 'denied', error => 'the peer did not sign' });
						return;
					}
					$peer_proved = 1;
				}
			}
			# A state-changing POST must not ride another site's page; Lax keeps
			# the ticket redirect working and blocks cross-site POST cookies.
			app->sessions->samesite('Lax');
			$c->session('authentication' => 'approved');
			# A peer logs in with the house password over the signed rail; mark
			# the session so the app gate lets remote_device_connect through
			# without a browser app key. A browser Gate login also sends
			# president/backup, so only a proved peer rail login is marked.
			if ($peer_proved) {
				$c->session('peer' => 1);
				$c->session('peer_signatorial' => $claimed);
			}
			else {
				$c->session('peer' => undef);
				$c->session('peer_signatorial' => undef);
			}
			# The password is a login, not a recovery share. It no longer seals a
			# copy of the house key: threshold shares (paper or device) are the way
			# back in when this machine's key file is gone.
			my $app_warranty = &subs::setting_grabber({ app => $c->param('app'), setting => 'warranty' });
			my $warranty = &subs::ago_calc($app_warranty || &subs::setting_grabber({ 'app' => 'me', 'setting' => 'login_warranty' } ) || '-3h',$server_time);
			$c->session('database' => $database);
			$c->session('suds_id' => &subs::suds_id($suds_key));
			$c->session('warranty' => $warranty);
			$c->session('string' => &subs::random_string_creator());
			$c->session('name') => &subs::setting_grabber({ app => 'me', setting => 'name' });
			$c->session('privilege' => ($peer_proved ? 'resident' : 'guest'));
			# A password-only login is bootstrap/recovery: it can pair a device,
			# restore a backup or recover, never open the manager. The recovery
			# code or the app key is the way in, on this console or another.
			if ($peer_proved) {
				$c->session('bootstrap' => undef);
			}
			else {
				$c->session('bootstrap' => 1);
			}
			$c->session('app' => $c->param('app'));


			my $debbie = eval { return &subs::db_select('settings', ['value'], { app => '__DEBRIEFING__', device => $device })->hash->{value} };
			my $deb = $debbie || encode_json [];
			my $duration = $start_time - &subs::rightNow();
		#	&subs::db_insert('appointments',{ warranty => $me_warranty, uuid => &subs::random_string_creator(40), app => "customs", type => "entry", timestamp => $timestamp, server_time => $server_time });
			my $d = { title => 'Your Majesty', app => 'customs', role => 'citizen', message => $remote_address, image => "/images/make believe/crown.png" };

			unless ($c->param('silence')) {
				&subs::say_it('your majesty');
				&notification_sender($d,$database);
			}
			my $hs = &subs::config_reader()->{'name'} || &subs::setting_grabber({ app => 'me', setting => 'computer_name' }) || '';
			if ($hs eq '') {
				$hs = `hostname`;
				chomp $hs;
			}
			# A phone's `hostname` is 'localhost'; give the peers a name a person
			# can pick out of a list instead of that placeholder.
			$hs = &subs::device_hostname_better($hs, '', $config->{'domain'});

			my $who = `whoami`;
			chomp $who;
		#	my $me = &me_setting_list();
			my $colour = '#' . &subs::random_colour_grabber();
			my $device_count = &subs::db_query('select count(*) from devices');
			my $bti = $c->stash('browser_tab_id');
			my $pwd = `pwd`;
			chomp $pwd;
			my $signatorial = &subs::signatorial_designer();
			my $js = {
				'authentication' => 'approved',
				hostname => $hs,
				username => $who,
				debriefer => $deb,
				port => $ENV{PORT_AHOY},
				ws_port => $ENV{PORT_MSG},
				alarm_port => $ENV{PORT_BELL},
				dock_port => $ENV{PORT_DOCK},
	#			me => $me,
				device => $device,
				database => $database,
				browser_tab_id => $bti,
				manager_file => &manager_file_maker($c->session('name')),
				signatorial => $signatorial,
				version => &subs::jawn_version(),
				pwd => $pwd,
				fqdn => (&subs::public_origin_host() || $config->{'domain'}),
				ssh_port => $config->{'ssh_port'},
				manager_colour => &subs::setting_grabber({ app => 'misc', setting => 'manager_background_colour', device => $signatorial }) || &subs::setting_grabber({ app => 'misc', setting => 'manager_background_colour' })
			};
			if (&subs::device_setter() eq 'server') {
				my $mirrors = [
					grep { defined $_ }
					map { &subs::remote_machine_mirror_row($_) }
					@{ &subs::db_select('remote_machines')->hashes || [] }
				];
				$js->{'mirrors'} = $mirrors;
			}
			my $archive;
			# the effective root, not config.json alone: the configure panel may have
			# chosen another drive, and a peer must send files where this machine
			# actually reads them
			my $archive_root = &subs::archive_root();
			if ($archive_root) {
				my $formatted_folder = $archive_root;
				$js->{'archive_dir'} = $formatted_folder;
				my $df = `df -h $formatted_folder`;
				my @df = split /\n/, $df;
				my @first_line = split(/\s+/, $df[0]);
				my @data_line = split(/\s+/, $df[1]);
				my $disk = {};
				for ( my $n = 0; $n <= scalar @first_line; $n++) {
					$disk->{$first_line[$n]} = $data_line[$n];
				}
				$js->{'archive'} = {
					dir => $archive_root,
					disk => $disk
				};
				$log->info(Dumper $js->{'archive'});
			}


			$c->render(json => $js);
		}
		elsif ($reject_count > 2) {
			my $denial = $c->render_to_string(template => 'guest_layouts/denial', message => '... access denied.');
			$c->render(json => { 'authentication' => 'denial', denial => $denial });
		}
		else {
			$reject_count = $reject_count + 1;
			$c->session('reject_count' => $reject_count);
			my $visitor = $local_address eq $remote_address ? 'Me' : $computer || 'door';
			# a caller that asked for silence (a peer reconnecting) is refused
			# quietly: speaking on every attempt turned a stale neighbour link
			# into an alarm on the machine's own speakers.
			unless ($c->param('silence')) {
				&subs::say_it('Access denied: ' . $visitor);
			}
			&subs::db_insert('appointments',{ warranty => $me_warranty, uuid => &subs::random_string_creator(40), app => "customs", type => "reject", timestamp => $timestamp, server_time => $server_time }) if $db_exists == 1;
			$c->render(json => { 'authentication' => 'rejected'});
			$c->session('authentication' => 'rejected');
			$c->stash('browser_tab_id' => undef);
			$c->session('suds_id' => undef);
			unless ($c->param('silence')) {
				&subs::say_it('I reject: ' . $remote_address);
				&notification_sender({ app => 'customs', role => 'citizen', title => 'Access', message => 'DB open', image => "/images/make believe/explosion.png" },$database);
			}

		}
	}
	else {
			my $reject_count = $c->session('reject_count') + 1;
			$c->session('reject_count' => $reject_count);
			my $visitor = $local_address eq $remote_address ? 'Me' : 'door';
			unless ($c->param('silence')) {
				&subs::say_it('Access denied: ' . $visitor);
			}
			$c->render(json => { 'authentication' => 'rejected'});
			$c->session('authentication' => 'rejected');
			$c->session('suds_id' => undef);
			$c->stash('browser_tab_id' => undef);
			unless ($c->param('silence')) {
				&notification_sender({ app => 'customs', role => 'citizen', title => 'Access', message => 'DB Closed: ' . $c->tx->remote_address . '<br>' . $c->req->url->path, image => "/images/make believe/explosion.png" },$database);
			}
	}
}

1;
