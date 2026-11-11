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
use Fcntl qw(:flock O_CREAT O_EXCL O_WRONLY);
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

# The legacy bootstrap read these with `cat`, which contributed nothing when a
# path was a directory or unreadable. Keep that tolerance: the identity
# migration runs at boot, and File::Slurp::read_file can die where the shell
# returned ''.
sub _slurp_or_empty {
	my ($path) = @_;
	return '' unless defined $path && length $path;
	my $text = eval { read_file($path) };
	return defined $text ? $text : '';
}

# The cache policy for a static asset. A window draws about fifty icons,
# template pictures and cursors, and a blanket no-cache made every open
# revalidate every one: a phone paid a round trip per icon before the window felt
# painted. These files change only with a release or a replaced file, so a short
# max-age serves a session's opens from cache while a replacement still reaches
# the screen on the next page. Scripts and styles keep the deliberate
# revalidation - the bundle rebuilds from their mtimes, so they must be checked.
sub static_cache_control {
	my ($path) = @_;
	return 'private, max-age=300, must-revalidate'
		if defined $path && $path =~ m{^/(?:icons|images|cursors)/};
	return 'no-cache, max-age=0, must-revalidate';
}

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
	my $context = shift // '';
	my $designer = ($context eq 'designer');

	# One session key for the whole tree, chosen once and kept. A Mojolicious
	# session cookie is signed with this key, so a key that differs between
	# workers - or between boots - makes every existing cookie invalid and sends
	# the person back to the sign-in screen.
	#
	# ~/.president/session_secret is the choice the first boot made. It is
	# consulted before anything is derived, so a later boot never reads the image
	# or the config at all: the key cannot drift when the signatorial image comes
	# and goes (it lives on external storage on Android, which is not readable at
	# every worker boot, and deriving per boot flipped the key between the image's
	# md5 and the deterministic fallback - the daily sign-in).
	my $pinned = &session_secret_read();
	if (defined $pinned && !$designer) {
		# A key written by an older build is the public derivation; rotate it
		# once, now, so a known signatorial cannot sign a session.
		$pinned = &session_secret_rotate_legacy($pinned);
		$gb::secret_maker = [ $pinned ];
		return $pinned;
	}

	# The derivation is unchanged: the signatorial image's bytes when the image is
	# readable, else the deterministic fallback (the configured path). This runs
	# once in the tree's life; every boot after the first reads the file above.
	my ($derived, $from_image);
	if ($config->{'signatorial'} && -e $config->{'signatorial'}) {
		my $j = &subs::home($config->{'signatorial'});
		my $checksum = encode_base64(&_slurp_or_empty($j));
		$derived = md5_sum $checksum;
		$from_image = 1;
	}
	else {
		$derived = md5_sum('signatorial:' . ($config->{'signatorial'} || 'jawnos'));
	}

	# The designer asks for the ingredient a legacy identity migration hashed,
	# not for the session key; that caller keeps exactly what it counted on
	# (the image's md5, or nothing when the image is unreadable).
	my $ingredient = $from_image ? $derived : undef;

	my $secret = &session_secret_pin($derived);
	if (defined $secret && length $secret) {
		$gb::secret_maker = [ $secret ];
		return $designer ? $ingredient : $secret;
	}

	# A home that cannot hold the file (read-only, permissions) must never make
	# the tree unbootable. It must not fall back to a key derived from public
	# data either: anyone who knows the signatorial could then forge a session.
	# Use a private key in this boot's temp dir - shared by its workers, 0600,
	# and gone on a reboot, which only asks people to sign in again.
	my $boot_key = &session_secret_boot_key();
	$gb::secret_maker = [ $boot_key ];
	return $designer ? $ingredient : $boot_key;
}

# The fallback key when ~/.president/session_secret cannot be written: a random
# key in the boot's temp dir, created 0600 and read back by the other workers of
# this boot. It is never derived from anything public, and it does not outlive
# the boot (a restart rotates it, and people sign in again).
sub session_secret_boot_key {
	require File::Spec;
	require Fcntl;
	$gb::tmp_dir = File::Spec->tmpdir unless defined $gb::tmp_dir && length $gb::tmp_dir;
	my $file = File::Spec->catfile($gb::tmp_dir, 'jawnos_session_secret.' . ($< // 0));
	if (-e $file) {
		my $key = &_slurp_or_empty($file);
		$key =~ s/\s+\z//;
		return $key if $key =~ /^[0-9a-f]{32}$/;
	}
	require Crypt::PRNG;
	my $key = unpack 'H*', Crypt::PRNG::random_bytes(16);
	if (sysopen(my $fh, $file, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600)) {
		print $fh $key;
		close $fh;
		return $key;
	}
	# A racing worker won the create: read what it wrote.
	my $again = &_slurp_or_empty($file);
	$again =~ s/\s+\z//;
	return $again if $again =~ /^[0-9a-f]{32}$/;
	return $key;
}

sub session_secret_file {
	return &home('~/.president/session_secret');
}

# A key an older build wrote is md5 of the signatorial image (or of the public
# signatorial string). Anyone who knows that value can sign a session cookie.
# Replace such a key with a random one, once, guarded by an exclusive lock so
# the boot's workers agree on the winner.
sub session_secret_rotate_legacy {
	my ($pinned) = @_;
	my $file = &session_secret_file();
	return $pinned unless defined $pinned && defined $file && length $file;
	my @legacy;
	if ($config->{'signatorial'} && -e $config->{'signatorial'}) {
		my $j = &subs::home($config->{'signatorial'});
		push @legacy, md5_sum(encode_base64(&_slurp_or_empty($j)));
	}
	push @legacy, md5_sum('signatorial:' . ($config->{'signatorial'} || 'jawnos'));
	return $pinned unless grep { $_ eq $pinned } @legacy;

	require Fcntl;
	my $lock = $file . '.rotate';
	# A rotation killed mid-write leaves its lock; after a minute it is stale.
	unlink $lock if -e $lock && (time() - ((stat $lock)[9] // 0)) > 60;
	my $lh;
	unless (sysopen($lh, $lock, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600)) {
		# Another worker is rotating: wait for the new key it writes.
		for my $attempt (1 .. 50) {
			my $now = &session_secret_read();
			return $now if defined $now && !grep { $_ eq $now } @legacy;
			Time::HiRes::usleep(10_000);
		}
		return $pinned;
	}
	close $lh;
	# Re-read under the lock: a worker that read the old key just before another
	# rotated must not rotate again and invalidate the new one.
	my $current = &session_secret_read();
	if (defined $current && !grep { $_ eq $current } @legacy) {
		unlink $lock;
		return $current;
	}
	require Crypt::PRNG;
	my $fresh = unpack 'H*', Crypt::PRNG::random_bytes(16);
	my $tmp = $file . '.new.' . $$;
	if (open(my $th, '>', $tmp)) {
		chmod 0600, $tmp;
		print $th $fresh, "\n";
		close $th;
		rename($tmp, $file) or unlink $tmp;
	}
	unlink $lock;
	my $now = &session_secret_read();
	return defined $now ? $now : $fresh;
}

# The key the first boot wrote, or undef when it is not there yet. A writer
# creates the file before it writes into it, so a reader can catch an empty or
# half-written key: wait briefly for a complete one rather than adopt an
# incomplete value for the life of the process. A file that never yields a key
# (wrong mode, a home that cannot hold it) reads as undef, and the caller falls
# back to what it did before the key was persisted.
sub session_secret_read {
	my $file = &session_secret_file();
	return undef unless defined $file && length $file && -e $file;
	for my $attempt (1 .. 20) {
		my $key = &_slurp_or_empty($file);
		$key =~ s/\s+\z//;
		return $key if $key =~ /^[0-9a-f]{32}$/;
		Time::HiRes::usleep(10_000) if $attempt < 20;
	}
	return undef;
}

# Choose the session key once for this tree and keep it. The first process to
# boot writes a random key; every later process - and every worker that loses
# the create race - reads that file and signs with its bytes. O_CREAT|O_EXCL
# makes the choice atomic, and an existing file is never rewritten here, so the
# key cannot drift when the signatorial image comes and goes.
sub session_secret_pin {
	my ($derived) = @_;
	return undef unless defined $derived && length $derived;
	my $file = &session_secret_file();
	return undef unless defined $file && length $file;

	my $existing = &session_secret_read();
	return $existing if defined $existing;

	# ~/.president normally exists; a fresh home may not. A failure here is not
	# fatal - the sysopen below decides, and the caller falls back to memory.
	my $dir = $file;
	if ($dir =~ s{/+[^/]+\z}{} && length $dir && !-d $dir) {
		eval { File::Path::make_path($dir) };
	}

	if (sysopen my $fh, $file, O_CREAT | O_EXCL | O_WRONLY, 0600) {
		chmod 0600, $file;
		# A fresh key is random, never the derivation: the derivation is public
		# to anyone who knows the signatorial.
		require Crypt::PRNG;
		my $fresh = unpack 'H*', Crypt::PRNG::random_bytes(16);
		print $fh $fresh, "\n";
		close $fh;
		return $fresh;
	}

	# Lost the race, or the file appeared between the read and the create: the
	# winner's key is the tree's key.
	return &session_secret_read();
}

sub signatorial_identity_file {
	return &home('~/.jawnos_signatorial_id');
}

# A second copy beside the database. The home copy is the traditional one, but
# it depends on HOME, which a container, a `run-as` shell or a hand-run script
# can have wrong - and a database restored from another machine must never be
# able to change this machine's identity. The database directory is local, is
# not replaced by a restore (only jawnos.db is), and is excluded from the code
# sync, so this copy survives both.
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
		my $id = &_slurp_or_empty($file);
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
	my @jonathans;
	if (opendir my $dh, $folder) {
		@jonathans = sort grep { !/^\./ } readdir $dh;
		closedir $dh;
	}
	my $checksum = $database;
	foreach my $j ( @jonathans ) {
		$checksum .= encode_base64(&_slurp_or_empty($folder . '/' . $j));
	}
	my $md5 = md5_sum &signatorial_establisher('designer') . $checksum;
	&signatorial_identity_write($md5);
	$gb::signatorial = $md5;

	return $gb::signatorial;
}

sub runner_label {
	# the machine a command ran on, for the appointment details
	return &subs::machine_hostname();
}

sub destination_relay {
	# Run an app's command on other machines: a POST to the machine's
	# /manager/reset, which runs that machine's own command for the app and
	# records its own appointment (exactly what a press there does). The
	# destination is a signatorial from the remote machine list; 'all' fans out
	# to every active machine. A named machine that cannot be reached directly is
	# handed to the headless relay queue, which keeps trying through the mesh.
	# Returns { ok, all, sent, expected, queued, label, uuid } so the caller can
	# tell the device whether the movement landed.
	my $data = shift;
	my $destination = $data->{'destination'};
	my $app = $data->{'app'};
	my $movement = $data->{'movement'} || 'command';
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $me = &subs::signatorial_designer();
	my $rms;
	my $named = ($destination && $destination ne 'all') ? 1 : 0;
	if (!$named) {
		$rms = &subs::remote_machine_lister({ connection => 'active' });
	}
	else {
		# A named destination is an instruction, not a hint. Its row's
		# `connection` is only this machine's last guess at reachability - a
		# phone hears no LAN beacons, and the reconnector may not have run since
		# the peer rebooted - so an explicit target is still dialled while the
		# roster calls it inactive. Gating on that flag made a watch press run on
		# the machine holding the watch and never reach the machine it named.
		$rms = &subs::remote_machine_lister({ signatorial => $destination });
		# Prefer a row the roster believes is up; a mirror or a stale copy of the
		# same machine may sit beside it.
		$rms = [ sort {
			(($b->{'connection'} || '') eq 'active') <=> (($a->{'connection'} || '') eq 'active')
		} @{$rms} ] if ref $rms eq 'ARRAY';
	}
	$rms = [] unless ref $rms eq 'ARRAY';
	# The movement every machine gets. Built once: the direct POST and the relay
	# queue's later copy must carry exactly the same request.
	my $form = {
		app => $app,
		type => $movement,
		timestamp => $timestamp,
		notes => 'sent from ' . $me
	};
	# Only a media relay has a capture machine to name; a command relay is
	# unchanged (it runs the command on the peer, not on a chosen recorder).
	$form->{'remote_signatorial'} = $destination
		if $named && ($data->{'recorder'} || $data->{'machine'});
	$form->{'command_id'} = $data->{'command_id'} if defined $data->{'command_id'} && $data->{'command_id'} ne '';
	foreach my $field ( qw/uuid recorder camera machine/ ) {
		next unless defined $data->{$field} && ($data->{$field} ne '' || $field eq 'camera');
		$form->{$field} = $data->{$field};
	}
	my $sent = 0;
	my $label;
	my $considered = 0;
	my $target_uuid;
	foreach my $rm ( @{$rms} ) {
		next unless ref $rm eq 'HASH';
		my $sig = $rm->{'signatorial'};
		next unless $sig && $sig ne $me;   # this machine's own copy is run by the caller
		$considered++;
		$target_uuid ||= $rm->{'uuid'} if $rm->{'uuid'};
		unless ($rm->{'ip'}) {
			$log->error('destination relay to ' . $sig . ' skipped: no address on its row') if $log;
			next;
		}
		my $hop = &subs::remote_useragent_maker({ rm => $rm, signatorial => $sig });
		unless ($hop && $hop->{'ua'} && $hop->{'manager'}) {
			$log->error('destination relay to ' . $sig . ' skipped: no signed agent for ' . ($rm->{'manager'} || '?')) if $log;
			next;
		}
		# A button press is waiting on this, and an unreachable machine must be
		# handed over promptly: the peer agent carries the long snapshot
		# inactivity timeout (3000 s), which is far too long to hold a tap.
		$hop->{'ua'}->connect_timeout(4)->inactivity_timeout(12);
		my $res = eval {
			$hop->{'ua'}->insecure(1)->post($hop->{'manager'} . '/manager/reset' => form => $form)->result;
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
		$log->error('destination relay: no ' . ($named ? 'machine' : 'active machine') . ' matches ' . ($destination || 'all')) if $log;
	}
	# A named machine that did not take the movement directly is left with the
	# headless relay: the utility drains the queue through the mesh (often via
	# the hub) and keeps trying while the peer is away. Running the command on
	# the machine holding the watch would be the wrong machine.
	my $queued = 0;
	if ($named && !$sent && $target_uuid) {
		$queued = &subs::remote_relay_queue_push({
			path => '/manager/reset',
			method => 'post',
			remote_uuid => $target_uuid,
			params => $form,
			expect_json => 1,
			expires => &subs::rightNow() + 30 * 60 * 1000,
			attempts => 0,
		});
	}
	# A queued named movement is not a failure: the relay will deliver it. An
	# every-machine movement needs every active target to have taken it.
	my $ok = $named
		? (($sent > 0 || $queued) ? 1 : 0)
		: (($considered > 0 && $sent >= $considered) ? 1 : 0);
	return {
		ok => $ok,
		all => $named ? 0 : 1,
		sent => $sent,
		expected => $considered,
		queued => $queued,
		label => $label,
		uuid => $target_uuid,
	};
}

# A setting's `command` (and a learned verb, or a weather/clock automation)
# reaches every open manager tab, so a value stored there is script unless it
# is one of the shapes the house really uses. Only a click on a named element
# and a seek on the house music player are accepted; the rest is refused and
# stays a shell command in the worker.
my $BROWSER_COMMAND_CLICK = qr/^\$\((['"])([#.])([A-Za-z0-9_-]+)\1\)\.trigger\((['"])click\4\);?$/;
my $BROWSER_COMMAND_CURRENT = qr/^tree\.sound\.currentTime = tree\.sound\.currentTime [+-] (?:\d+(?:\.\d+)?|\.\d+);?$/;
my $BROWSER_COMMAND_UNSAFE = qr/(?:document|window|eval|Function|fetch|alert|[<>`])/;

sub browser_command_valid {
	my ($command) = @_;
	return 0 unless defined $command && !ref $command;
	my $s = $command;
	$s =~ s/^\s+|\s+$//g;
	return 0 unless length $s;
	return 0 if $s =~ /[\x00-\x1f\x7f]/;
	return 0 if $s =~ $BROWSER_COMMAND_UNSAFE;
	return 1 if $s =~ $BROWSER_COMMAND_CLICK;
	return 1 if $s =~ $BROWSER_COMMAND_CURRENT;
	return 0;
}

sub run_command {
	my $app = shift;
	my $command = shift;
	my $timestamp = shift;
	my $opts = shift || {};
	my $exec = 'none';
	my $whoami = `whoami`;
	chomp $whoami;
	my $hostname = &subs::machine_hostname();
	&subs::subprocessor(sub {
		Mojo::IOLoop->reset;
		# A leading & used to be Perl eval. Nothing calls it that way, and the
		# strings reachable here come from requests, settings and automations, so
		# the branch turned data into code inside this worker. Refuse it instead.
		if ($command =~ /^&/) {
			my $json = { type => 'command', whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(), command => $command, 'return' => 'refused: a leading & is not a command', timestamp => $timestamp };
			&Websocket::send('server', $json);
			return 'refused';
		}
		# A command is a grandchild of this wrapper. The tracked helper gives it
		# its own warranty, so a hung command is killed instead of extending this
		# wrapper's deadline forever.
		my $run = eval { &subs::subprocessor_command($command, { name => 'run command', stderr => 'inherit' }) };
		$exec = ref $run eq 'HASH' ? ($run->{'error'} // $run->{'output'} // '') : '';
		my $json = { type => 'command', whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(), command => $command, 'return' => $exec, timestamp => $timestamp };

		&Websocket::send('server', $json);
		sleep(.3);
		# The terminal is a JS console the person is using deliberately, and only
		# that path sends its line; every other caller may send one of the named
		# browser commands, or nothing at all (a shell command runs here).
		my $console;
		if ($opts->{'terminal'}) {
			$console = &Websocket::console_command('terminalJs', $command, 'terminal');
		}
		elsif (&browser_command_valid($command)) {
			$console = &Websocket::console_command('browserCommand', $command);
		}
		if ($console) {
			my $msg = { app => $app, whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(25), console => $console };
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

# Whether this machine has a real GPS. termux-location names the provider that
# answered; only a `gps` answer proves the hardware. The flag is cache, which is
# this machine's own and never syncs, so one phone cannot lend its GPS to a
# laptop. A network fix can be a cell-tower guess blocks from where the person
# stands, so it never turns the flag on by itself.
sub navigation_gps_present {
	my $c = &cache_get({ app => '__president', context => 'navigation', subcontext => 'gps' });
	return (ref $c eq 'HASH' && $c->{'present'}) ? 1 : 0;
}

# Remember that a real GPS answered here. Returns 1 once the flag is set.
sub navigation_gps_confirm {
	my $provider = lc(shift // '');
	return 0 unless $provider eq 'gps';
	return 1 if &navigation_gps_present();
	&cache_set({ app => '__president', context => 'navigation', subcontext => 'gps', warranty => '-10y' }, { present => 1, at => &rightNow() });
	return 1;
}

# The app's GPS service writes each fix to ~/.president/location.json. Only a
# record that names provider=gps may become a place: a network fix looks like a
# fix in every other field, which is how the phone was reported in places it had
# never been. Returns the fix hash (aged by the fix's own timestamp) or undef.
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

# The navigation utility's own pace, in seconds. President adopts this machine's
# Batch pools. A pool is a group of utilities that wake together on one pace;
# the pace lives on the pool, not on each job, so moving a job between pools
# (or out of all of them) changes only where it is written down. Stored in the
# machine's utility row as a list, so the order is the person's:
#   __batch_groups => [ { id, label, seconds }, ... ]
# An older row stored a plain { id => seconds } map and reads the same; a row
# that has never been edited has no pools of its own and takes gb.pl's defaults.
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

# The pool a job belongs to, or undef when it runs on its own interval.
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

# The pace a job actually keeps: its pool's seconds, or undef when it is not in
# a pool (the caller then uses the job's own interval).
sub batch_interval {
	my $row = shift;
	my $job = shift;
	my $pool = &batch_pool_of($row, $job);
	return $pool ? $pool->{'seconds'} : undef;
}

# A job table adopted from the stored utility blob becomes this process's runtime.
# `lasted_run` is process state - when this runtime last executed the job - so a
# marker written by a *previous* process (anything before this one started) is
# meaningless here: the stored value sat 103 hours old on one machine, and the
# tunnels watchdog read it as "stuck for twelve intervals" on the first tick after
# every boot, resetting every tunnel as the mesh came up. A marker this process
# wrote is kept, or the controller's periodic re-adoption would reset the clock
# every few seconds and no job's own gate would ever elapse. Everything else on
# the row (schedule, switches, network map) is carried over untouched.
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

# Does the runtime need to adopt the stored utility row? At boot, yes; after
# that only when someone else stamped it (the Configure editor, a peer merge).
# The controller writes its own row back with the same stamp it just stored
# (utility_runtime_stamped), so its periodic persist no longer looks like an
# edit and re-adoption cannot overwrite the live runtime with stale copies of
# last_run/lasted_run.
sub utility_row_needs_adoption {
	my ($adopted, $row_lc, $runtime_lc) = @_;
	return 1 unless $adopted;
	return (($row_lc || 0) > ($runtime_lc || 0)) ? 1 : 0;
}

# How many due jobs one tick may start.
#
# The variable is declared after the utility child is forked, so the child
# inherits it *undefined*. `$started >= undef` is true in Perl (undef numifies
# to 0), and the cap check then skips every due job, every tick, in silence -
# the tree looked alive while nothing synced and no job ever started. The value
# is never meaningfully zero, so an absent, zero or non-numeric cap means the
# default.
sub utility_pass_cap_value {
	my $value = shift;
	return ($value + 0) if defined $value && $value =~ /^\d+$/ && $value > 0;
	return 2;
}

# Jobs in a runtime table that have no callable attached.
#
# The definer that attaches them runs from the controller, once, on the first
# call that reaches it. A boot whose first controller call was skipped (the
# database busy under a land or a backup) leaves the whole table bare, and
# utility_runner then skips every job in silence: the tree looks alive, no job
# runs, and no line says why. The runner asks this, attaches what is missing,
# and names it once - so the state is either healed or visible.
sub utility_bare_jobs {
	my $row = shift;
	return [] unless ref $row eq 'HASH';
	return [ grep { !/^__/ && ref $row->{$_} eq 'HASH' && !$row->{$_}->{'subroutine'} } sort keys %{$row} ];
}

# Record on the runtime the last_change it just persisted, so the next tick's
# comparison sees the row it wrote rather than a newer stranger's.
sub utility_runtime_stamped {
	my ($runtime, $stamp) = @_;
	return $stamp unless ref $runtime eq 'HASH';
	$runtime->{'__settings'} ||= {};
	$runtime->{'__settings'}->{'last_change'} = $stamp;
	return $stamp;
}

# Whether the tunnels worker has been stalled long enough to justify restarting
# the tunnels on this run. No marker means this process has not run the worker
# yet (a fresh install, or the tick right after adoption), which is not a stall.
sub tunnels_stall_duty {
	my ($lasted_run, $now, $interval) = @_;
	return undef unless defined $lasted_run && $lasted_run =~ /^\d+$/;
	$interval = 120 unless defined $interval && $interval =~ /^\d+$/ && $interval > 0;
	$now = &rightNow() unless defined $now;
	return (($now - $lasted_run) > ($interval * 1000 * 12)) ? 'restart' : undef;
}

# The machine's navigation interval, in seconds. The runtime adopts the stored
# row from the utility controller at runtime, but Manager and the scripts do not
# share that process, so read the same persisted row here. A navigation job in a
# batch pool keeps the pool's pace. A caller may name another machine (a fix
# relayed from it); with no name the local one answers.
sub navigation_interval {
	my $signatorial = shift || &subs::signatorial_designer();
	my $controls = eval { return decode_json &subs::setting_grabber({ app => '__president', setting => 'utility_controller' }) } || {};
	my $interval = &batch_interval($controls->{$signatorial}, 'navigation');
	$interval = $controls->{$signatorial}->{'navigation'}->{'interval'} unless $interval && $interval > 0;
	$interval = $gb::timeouts->{'navigation'}->{'interval'} unless $interval && $interval > 0;
	return $interval || 600;
}

# The pace navigation must keep right now, in seconds. The machine's utility
# interval is the base, but a running appointment whose app asks for fixes more
# often than that (its navigation setting, say 1m) is a request to update faster
# than the slower utility slot - so the pace follows the app down to a
# battery-wise floor. Base only asks for the utility's own pace.
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

# How long a fix the browser writes stays the machine's current place. It has
# to outlive the next automatic navigation run or the place falls back to public
# between fixes - the old flat five minutes did exactly that whenever the
# navigation utility was slower than five minutes. A scheduled watcher says when
# its own next run is due; otherwise the utility's pace (or the app's, when that
# is longer) is the gap to cover. One more interval lets the place survive a run
# that could not get a fix, and two minutes of grace absorbs a late slot.
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
