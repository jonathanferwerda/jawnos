package subs;

# Render: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $config;
our $database;
our $device;
our $gb;
our $log;

sub render_signature {
	my $device = &device_setter();
	my $config = &config_reader();
	# The active theme's own dressing belongs in the signature: two themes can
	# share an icon set and still paint their surfaces from different ramps, and
	# a window rendered under the old ramp must not come back from the cache.
	# theme_state() is memoised on the same short TTL as icon_set(), so this adds
	# no query to a warm render.
	my ( $theme_dark, undef, $theme_bg, $theme_bundle ) = &theme_state();
	my @theme_parts = ( $theme_dark, $theme_bg );
	if (ref $theme_bundle eq 'HASH') {
		push @theme_parts, map { $theme_bundle->{$_} } qw/scheme texture font corner accent/;
	}
	# the version is part of the signature so every release (each push bumps it)
	# discards cached appointment renders - without it a template change to an
	# appointment window would sit behind a cache row that matched forever
	my @parts = ( &icon_set() || '', &jawn_version(), join '|', map { defined $_ ? $_ : '' } @theme_parts );
	foreach my $k ( @gb::misc_settings ) {
		push @parts, $k . '=' . ($config->{$device}->{$k}->{'background_colour'} || '');
	}
	return join '|', @parts;
}

sub typesetter {
	my $app = shift;
	my $save = shift;
	my $type = 'idea';
	my $movement = '';
	my $last_word = (split '_', $app)[-1];
	my $first_word = (split '_', $app)[0];
	my $type_saved = 0;
	$last_word =~ s/[0-9]$//gi;
	$first_word =~ s/[0-9]$//gi;
	if ($last_word !~ /^!/ && grep { lc $last_word eq $_ } keys %{$gb::pos}) {
		my @app = split '_', $app;
		pop @app unless scalar @app == 1;
		$app = join '_', @app;
		$type = $last_word;
		$type_saved = 1;
	}
	elsif ($last_word =~ /^!/) {
		my @app = split '_', $app;
		$last_word = pop @app;
		$last_word =~ s/^!//gi;
		push @app, $last_word;
		$app = join '_', @app;
	}
	elsif ( my $default_pos = &subs::setting_grabber({ app => 'me', setting => 'pos' }) ) {
		$type = $default_pos;
	}
	if ($first_word !~ /^!/ && grep { lc $first_word eq $_ } @gb::movements) {
		my @app = split '_', $app;
		shift @app unless scalar @app == 1;
		$app = join '_', @app;
		$movement = $first_word;
	}
	elsif ($first_word =~ /^!/) {
		my @app = split '_', $app;
		$first_word = shift @app;
		$first_word =~ s/^!//gi;
		unshift @app, $first_word;
		$app = join '_', @app;
	}
	if ($type_saved == 1 && $save ne 'no') {
		&subs::setting_setter({ app => $app, setting => 'pos', value => $type });
	}
	return ($app,$type,$movement);
}

sub setting_initializer {
	my ($app,$timestamp) = @_;
	my $returner;
	$app = &unformat_name($app);
	my ($db,$database) = &database_grabber();
	my $server_time = &rightNow();
	my $type;
	($app,$type) = &typesetter($app);
	my $counter = &subs::db_query('select count(*) from appointments where app=?', $app);
	my $count = $counter->hash->{'count(*)'};
	my $res = &db_query('select * from settings where app=? and device = ? order by server_time desc',$app,$device);
	my $re = $res->hashes;

	my $aka = &db_query('select * from settings where setting = ? and value like ?', 'aka', '%' . $app . '%')->hashes;

	if ( $count == 0 && scalar @{$aka} > 0 ) {
		foreach my $ak ( @{$aka} ) {
			if (exists $ak->{'value'}) {
				my @a = split ',', $ak->{'value'};
				foreach my $o ( @a ) {
					$o = &subs::unformat_name($o);
					if ($o eq $app) {
						$app = &subs::unformat_name($ak->{'app'});
						$res = &db_query('select * from settings where app=?',$app);
						$re = $res->hashes;
						last;
					}
				}
			}
		}
	}
	my $me_settings = &subs::settings_grabber({ app => 'me' });

	my $colour = '#' . &random_colour_grabber();

	$returner->{'app'} = $app;
	my $settings = {
		'colour' => $colour,
		'dark_colour' => &dark_colour_for($colour),
		'worth' => $me_settings->{'worth'},
		'visible' => 'public',
		'permanent' => 'checked',
		'pos' => $type,
		'duration' => $me_settings->{'duration'},
		'currency' => $me_settings->{'currency'},
		'unit' => $me_settings->{'unit'},
		'cost' => 0,
		'enc' => 'on',
		'public' => 'off',
		'warranty' => $me_settings->{'warranty'},
		'notification_text' => &subs::format_name($app),
		'schedule' => 'once',
		'uuid' => &random_string_creator(25),
		'navigation' => 'none'
	};

	foreach my $s (keys %{$settings}) {
		# A warranty is one value for the house, so what matters is whether the
		# house row exists. When it does not, an older build's per-device row is
		# adopted as the value instead of seeding the 'me' default over it.
		my $house_warranty = ($s eq 'warranty');
		my @seen = $house_warranty
			? @{ &db_query('select * from settings where app = ? and setting = ? and device = ?', $app, 'warranty', &warranty_device())->hashes || [] }
			: grep { $_->{'setting'} eq $s } @{$re};

		unless ( scalar @seen > 0 ) {
			my $value = $settings->{$s};
			if ($house_warranty) {
				my $legacy = &db_query('select value from settings where app = ? and setting = ? and device = ? order by server_time desc limit 1', $app, 'warranty', $device)->hashes || [];
				$value = $legacy->[0]->{'value'} if scalar @{$legacy} && defined $legacy->[0]->{'value'} && length $legacy->[0]->{'value'};
			}
			my $pen = {
				app => $app,
				timestamp => &subs::rightNow(),
				setting => $s,
				value => $value,
				server_time => &subs::rightNow(),
				device => ($house_warranty ? &warranty_device() : $device),
				uuid => &random_string_creator(20)
			};
			&db_insert('settings', $pen);
			$returner->{$s} = $value;
		}
		else {
			my $set = $seen[0];
			$returner->{$s} = $set->{'value'};
			if (scalar @seen > 1) {
				#unshift @seen;
				foreach my $s ( @seen ) {
					&subs::db_delete('settings', { app => $app, uuid => $s->{'uuid'} });
					&subs::deletion_registration({ table => 'settings', app => $app, uuid => $s->{'uuid'}, scope => 'single', server_time => $s->{'server_time'} });
				}
			}
		}
	}
	return $returner;
};

sub signatorial_establisher {
	my $context = shift;
	# Pin the session secret even when the signatorial image is missing. Left
	# unpinned, each Mojolicious worker signs sessions with its own random key, so
	# a session the dock mints (a ticket) will not verify at the manager - the
	# Gate a client lands on holding a perfectly good ticket. The fallback is
	# deterministic (the configured path), so the tree's workers share it.
	$gb::secret_maker ||= [ md5_sum('signatorial:' . ($config->{'signatorial'} || 'jawnos')) ];
	if ($config->{'signatorial'} && -e $config->{'signatorial'}) {

		my $j = &subs::terminal_name(&subs::home($config->{'signatorial'}));
		my $checksum = `base64 $j`;
		my $md5 = md5_sum $checksum;
		$gb::secret_maker = [ $md5 ];
		return $md5;
	}
	elsif ($context ne 'designer') {
		return &random_string_creator(12);
	}
}

sub signatorial_identity_file {
	return &home('~/.jawnos_signatorial_id');
}

sub signatorial_identity_mirror {
	return './database/.jawnos_signatorial_id';
}

sub signatorial_identity_write {
	my $id = shift;
	for my $file ( &signatorial_identity_file(), &signatorial_identity_mirror() ) {
		next unless defined $file && length $file;
		if (open my $fh, '>', $file) {
			chmod 0600, $file;
			print $fh $id, "\n";
			close $fh;
		}
	}
	return $id;
}

sub signatorial_designer {
	my $designation = shift;
	if (!$designation && $gb::signatorial) {
		return $gb::signatorial;
	}

	# A persisted identity is the point: it must not change when a picture is
	# added or removed, and every container or clone must have its own. The
	# file is written once - by setup for a new install, or by the legacy
	# migration below for a machine that predates it - and is never recomputed.
	my @identity_files = ( &signatorial_identity_file(), &signatorial_identity_mirror() );
	for my $file ( @identity_files ) {
		next unless defined $file && length $file && -e $file;
		my $id = `cat $file`;
		chomp $id;
		if ($id =~ /^[0-9a-f]{16,64}$/i) {
			$gb::signatorial = lc $id;
			# heal the other copy if it is missing (a wrong HOME, a new mirror)
			&signatorial_identity_write($gb::signatorial);
			return $gb::signatorial;
		}
	}

	# A restored database arrives with the donor's settings, and the donor's
	# remote_machines roster lists THIS machine as a peer. The most-used device
	# id in those settings is then the donor's own identity, not ours (ours is
	# excluded below because the roster names it as a peer). The configured
	# domain is local - it lives in config.json, not the database - so it
	# survives a restore and names exactly one roster row. Trust that first.
	my $domain = $config->{'domain'} || '';
	if ($domain) {
		my $row = eval {
			&db_query(
				"select signatorial from remote_machines"
				. " where fqdn = ? and signatorial is not null and signatorial != ''"
				. " order by server_time desc limit 1", $domain
			)->hash;
		};
		my $mine = ($row && $row->{'signatorial'}) ? lc $row->{'signatorial'} : '';
		if ($mine =~ /^[0-9a-f]{16,64}$/) {
			&signatorial_identity_write($mine);
			$gb::signatorial = $mine;
			return $gb::signatorial;
		}
	}

	# A machine that predates the identity file: its current signatorial is
	# already the key on its settings, continent and sync rows. Take the most
	# used long device value that is not a peer's signatorial, and pin that -
	# never recompute it, since the picture folder may have drifted since.
	#
	# A database restored from another machine also has a most-used id - the
	# donor's - and its vault row is sealed with the donor's house key, which
	# this machine's key cannot open. So a candidate whose vault will not open
	# is a foreign database's identity, not ours; skip it rather than adopt it.
	my $candidates = eval {
		&db_query(
			"select device from settings"
			. " where device is not null and length(device) >= 16"
			. " and device not in (select signatorial from remote_machines where signatorial is not null)"
			. " group by device order by count(*) desc limit 5"
		)->hashes;
	} || [];
	my $stored;
	for my $candidate ( @{$candidates} ) {
		my $id = $candidate->{'device'} || '';
		next unless $id =~ /^[0-9a-f]{16,64}$/i;
		$id = lc $id;
		my $vault = eval {
			&db_query(
				"select value from settings where app = ? and setting = ? and device = ?"
				. " order by server_time desc limit 1", '__president', 'vault', $id
			)->hash;
		};
		if ($vault && $vault->{'value'}) {
			my $plain = eval { &note_decrypter(&house_key(), $vault->{'value'}) };
			next unless defined $plain && length $plain;
		}
		$stored = $id;
		last;
	}
	if ($stored) {
		&signatorial_identity_write($stored);
		$gb::signatorial = $stored;
		return $gb::signatorial;
	}

	# Legacy migration: compute exactly what this machine announced before the
	# identity was persisted, then pin it. Every remote_machines.signatorial,
	# settings.device and JSON reference keeps pointing at the same value.
	my $folder = './public/images/jonathans';
	my $jonathans = `ls $folder`;
	my @jonathans = split /\n/, $jonathans;
	my $checksum = $database;
	foreach my $j ( @jonathans ) {
		$j = &terminal_name($folder . '/' . $j);
		$checksum .= encode_base64 `cat $j`;
	}
	my $md5 = md5_sum &signatorial_establisher('designer') . $checksum;
	&signatorial_identity_write($md5);
	$gb::signatorial = $md5;

	return $gb::signatorial;
}

sub runner_label {
	# the machine a command ran on, for the appointment details
	my $hostname = `hostname`;
	chomp $hostname;
	return $hostname;
}

sub destination_relay {
	# Run an app's command on other machines: a POST to the machine's
	# /manager/reset, which runs that machine's own command for the app and
	# records its own appointment (exactly what a press there does). The
	# destination is a signatorial from the remote machine list; 'all' fans out
	# to every active machine. Returns a label for the machine that took it, or
	# undef when nobody did.
	my $data = shift;
	my $destination = $data->{'destination'};
	my $app = $data->{'app'};
	my $movement = $data->{'movement'} || 'command';
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $me = &subs::signatorial_designer();
	my $rms;
	if (!$destination || $destination eq 'all') {
		$rms = &subs::remote_machine_lister({ connection => 'active' });
	}
	else {
		$rms = &subs::remote_machine_lister({ signatorial => $destination, connection => 'active' });
	}
	$rms = [] unless ref $rms eq 'ARRAY';
	my $sent = 0;
	my $label;
	my $considered = 0;
	foreach my $rm ( @{$rms} ) {
		next unless ref $rm eq 'HASH';
		my $sig = $rm->{'signatorial'};
		next unless $sig && $sig ne $me;   # this machine's own copy is run by the caller
		$considered++;
		unless ($rm->{'ip'}) {
			$log->error('destination relay to ' . $sig . ' skipped: no address on its row') if $log;
			next;
		}
		my $hop = &subs::remote_useragent_maker({ rm => $rm, signatorial => $sig });
		unless ($hop && $hop->{'ua'} && $hop->{'manager'}) {
			$log->error('destination relay to ' . $sig . ' skipped: no signed agent for ' . ($rm->{'manager'} || '?')) if $log;
			next;
		}
		# A button press is waiting on this, and an unreachable machine must fall
		# back to running here promptly: the peer agent carries the long snapshot
		# inactivity timeout (3000 s), which is far too long to hold a tap.
		$hop->{'ua'}->connect_timeout(4)->inactivity_timeout(12);
		my $res = eval {
			$hop->{'ua'}->insecure(1)->post($hop->{'manager'} . '/manager/reset' => form => {
				app => $app,
				type => $movement,
				timestamp => $timestamp,
				notes => 'sent from ' . $me
			})->result;
		};
		if ($res && eval { $res->is_success }) {
			$sent++;
			$label = $rm->{'hostname'} . ' (' . $rm->{'ip'} . ')' unless $label;
		}
		else {
			my $why = $@ || ($res ? ('HTTP ' . $res->code) : 'no answer');
			$why =~ s/\s+/ /g;
			$log->error('destination relay to ' . $sig . ' failed: ' . $why) if $log;
		}
	}
	unless ($considered) {
		$log->error('destination relay: no active machine matches ' . ($destination || 'all')) if $log;
	}
	if (!$destination || $destination eq 'all') {
		return $sent ? 'every machine (' . $sent . ')' : undef;
	}
	return $label;
}

sub run_command {
	my $app = shift;
	my $command = shift;
	my $timestamp = shift;
	my $exec = 'none';
	my $whoami = `whoami`;
	chomp $whoami;
	my $hostname = `hostname`;
	chomp $hostname;
  &subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		if ($command =~ /^&/) {
			$exec = eval { $command };
			my $json = { type => 'command', whoami => 'President', hostname => $hostname, uuid => &subs::random_string_creator(), command => $command, 'return' => $exec, timestamp => $timestamp };

			&Websocket::send('server', $json);
		}
		else {
			$exec = eval { return `$command` };
			my $json = { type => 'command', whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(), command => $command, 'return' => $exec, timestamp => $timestamp };

			&Websocket::send('server', $json);
			sleep(.3);
			my $msg = { app => $app, whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(25), console => $command };
			&Websocket::send('server', $msg);
		}
		return 'done';
	}, { name => 'run command' });
}

sub rightNow {
	my $precision = shift;
	my $time = time() * 1000;

	unless ($precision) {
		$time = sprintf("%.0f",$time);
	}

	return $time;
}

sub navigation_gps_present {
	my $c = &cache_get({ app => '__president', context => 'navigation', subcontext => 'gps' });
	return (ref $c eq 'HASH' && $c->{'present'}) ? 1 : 0;
}

sub navigation_gps_confirm {
	my $provider = lc(shift // '');
	return 0 unless $provider eq 'gps';
	return 1 if &navigation_gps_present();
	&cache_set({ app => '__president', context => 'navigation', subcontext => 'gps', warranty => '-10y' }, { present => 1, at => &rightNow() });
	return 1;
}

sub native_location {
	my ($opts) = @_;
	$opts ||= {};
	my $file = &subs::home('~/.president/location.json');
	return undef unless -e $file;
	my $raw = eval { read_file($file) };
	return undef unless defined $raw && $raw =~ /\S/;
	my $loc = eval { decode_json($raw) };
	return undef unless ref $loc eq 'HASH';
	return undef unless (($loc->{'provider'} || '') eq 'gps');
	return undef unless (($loc->{'status'} || '') eq 'fix');
	return undef unless defined $loc->{'latitude'} && defined $loc->{'longitude'};
	return undef unless $loc->{'latitude'} =~ /^-?\d+(?:\.\d+)?$/ && abs($loc->{'latitude'}) <= 90;
	return undef unless $loc->{'longitude'} =~ /^-?\d+(?:\.\d+)?$/ && abs($loc->{'longitude'}) <= 180;
	my $now = &subs::rightNow();
	my $age;
	if (($loc->{'time'} || '') =~ /^\d+$/) {
		$age = $now - $loc->{'time'};
	}
	elsif (($loc->{'elapsedMs'} || '') =~ /^\d+$/) {
		$age = $loc->{'elapsedMs'};
		$age += ($now - $loc->{'sampled'}) if (($loc->{'sampled'} || '') =~ /^\d+$/);
	}
	else {
		return undef;
	}
	$age = 0 if $age < 0;
	$loc->{'age_ms'} = $age;
	my $max = defined $opts->{'max_age_ms'} ? $opts->{'max_age_ms'} : (10 * 60 * 1000);
	return undef if $age > $max;
	return $loc;
}

sub batch_pools {
	my $row = shift;
	my $stored = (ref $row eq 'HASH') ? $row->{'__batch_groups'} : undef;
	my @pools;
	if (ref $stored eq 'ARRAY') {
		my %seen;
		foreach my $pool ( @{$stored} ) {
			next unless ref $pool eq 'HASH';
			my $id = $pool->{'id'} // '';
			$id =~ s/[^a-z0-9_]//g;
			next unless $id ne '' && !$seen{$id}++;
			my $seconds = int($pool->{'seconds'} || 0);
			$seconds = $gb::batch_groups->{$id}->{'seconds'} || 900 unless $seconds > 0;
			my $label = $pool->{'label'} // '';
			$label =~ s/^\s+|\s+$//g;
			$label = $id if $label eq '';
			push @pools, { id => $id, label => $label, seconds => $seconds };
		}
	}
	elsif (ref $stored eq 'HASH') {
		foreach my $id ( sort keys %{$stored} ) {
			my $seconds = int($stored->{$id} || 0);
			$seconds = $gb::batch_groups->{$id}->{'seconds'} || 900 unless $seconds > 0;
			push @pools, { id => $id, label => ($gb::batch_groups->{$id}->{'label'} || $id), seconds => $seconds };
		}
	}
	if (!defined $stored) {
		foreach my $id ( @gb::batch_order, sort keys %{$gb::batch_groups} ) {
			next if !$gb::batch_groups->{$id} || grep { $_ eq $id } map { $_->{'id'} } @pools;
			push @pools, { id => $id, label => ($gb::batch_groups->{$id}->{'label'} || $id), seconds => $gb::batch_groups->{$id}->{'seconds'} || 900 };
		}
	}
	return \@pools;
}

sub batch_pool_of {
	my $row = shift;
	my $job = shift;
	return undef unless ref $row eq 'HASH' && ref $row->{$job} eq 'HASH';
	my $group = $row->{$job}->{'group'} // '';
	return undef if $group eq '';
	foreach my $pool ( @{ &batch_pools($row) } ) {
		return $pool if $pool->{'id'} eq $group;
	}
	return undef;
}

sub batch_interval {
	my $row = shift;
	my $job = shift;
	my $pool = &batch_pool_of($row, $job);
	return $pool ? $pool->{'seconds'} : undef;
}

sub utility_adopt_runtime {
	my ($jobs, $now, $process_start) = @_;
	return $jobs unless ref $jobs eq 'HASH';
	$now = &rightNow() unless defined $now;
	$process_start = int($^T) * 1000 unless defined $process_start;
	foreach my $t ( keys %{$jobs} ) {
		next if $t =~ /^__/;
		next unless ref $jobs->{$t} eq 'HASH';
		my $lasted = $jobs->{$t}->{'lasted_run'};
		next if defined $lasted && $lasted =~ /^\d+$/ && $lasted >= $process_start;
		$jobs->{$t}->{'lasted_run'} = $now;
	}
	return $jobs;
}

sub utility_row_needs_adoption {
	my ($adopted, $row_lc, $runtime_lc) = @_;
	return 1 unless $adopted;
	return (($row_lc || 0) > ($runtime_lc || 0)) ? 1 : 0;
}

sub utility_runtime_stamped {
	my ($runtime, $stamp) = @_;
	return $stamp unless ref $runtime eq 'HASH';
	$runtime->{'__settings'} ||= {};
	$runtime->{'__settings'}->{'last_change'} = $stamp;
	return $stamp;
}

sub tunnels_stall_duty {
	my ($lasted_run, $now, $interval) = @_;
	return undef unless defined $lasted_run && $lasted_run =~ /^\d+$/;
	$interval = 120 unless defined $interval && $interval =~ /^\d+$/ && $interval > 0;
	$now = &rightNow() unless defined $now;
	return (($now - $lasted_run) > ($interval * 1000 * 12)) ? 'restart' : undef;
}

sub navigation_interval {
	my $signatorial = &subs::signatorial_designer();
	my $controls = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'utility_controller' }) } || {};
	my $interval = &batch_interval($controls->{$signatorial}, 'navigation');
	$interval = $controls->{$signatorial}->{'navigation'}->{'interval'} unless $interval && $interval > 0;
	$interval = $gb::timeouts->{'navigation'}->{'interval'} unless $interval && $interval > 0;
	return $interval || 600;
}

sub navigation_pace {
	my $data = shift || {};
	my $base = &navigation_interval();
	return $base if $data->{'base'};
	my $fastest = $base;
	my $running = &subs::db_query('select app from appointments where (type = ? or type = ?) and timestamp < ?', 'start', 'record', &subs::rightNow())->hashes;
	foreach my $appt ( @{$running} ) {
		my $navigation = eval { return &subs::setting_grabber({ app => $appt->{'app'}, setting => 'navigation' }) };
		next unless defined $navigation && $navigation =~ /\S/;
		next if $navigation =~ /^(?:none|once)$/i;
		my $ms = ($navigation =~ /^\d+$/ && $navigation > 1000) ? $navigation : &subs::time_abbrev_translator($navigation);
		next unless $ms && $ms > 0;
		my $seconds = $ms / 1000;
		$fastest = $seconds if $seconds < $fastest;
	}
	$fastest = 10 if $fastest < 10;
	return $fastest;
}

sub navigation_hold_warranty {
	my $data = shift || {};
	my $now = $data->{'server_time'} || &subs::rightNow();
	my $grace = 2 * 60 * 1000;
	my $hold = 5 * 60 * 1000;
	my $navigation = $data->{'navigation'};
	my $next = $data->{'next_navigation'};
	my $timestamp = $data->{'timestamp'};
	if ($next && $timestamp && $next > $timestamp) {
		# both came from the browser's clock, so their difference is the wait
		$hold = ($next - $timestamp) if ($next - $timestamp) > $hold;
	}
	elsif (defined $navigation && $navigation =~ /^\d+$/ && $navigation > 0) {
		$hold = $navigation if $navigation > $hold;
	}
	my $pace = &navigation_pace({ base => 1 }) * 1000;
	$hold = $pace if $pace > $hold;
	$hold += $pace;
	return $now + $hold + $grace;
}

1;
