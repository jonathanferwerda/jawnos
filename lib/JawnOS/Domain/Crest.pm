package subs;

# Crest: extracted from subroutines.pl (package subs). Loaded on
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

our %M;
our $crest_peer_list_cache;
our $crest_peer_list_raw;
our $device;
our %tier_rank;
our $tier_required;

sub crest_image_file {
	my ($record, $kind) = @_;
	return undef unless ref $record eq 'HASH';
	my $name = $record->{$kind} || '';
	return undef unless $name =~ /^[\w.\-]+$/;
	my @devices = ($record->{'device'}, &device_setter());
	my %seen;
	@devices = grep { defined $_ && length $_ && !$seen{$_}++ } @devices;
	foreach my $dev (@devices) {
		my $folder = &setting_grabber({ app => 'misc', setting => 'photo_location', device => $dev }) || 'Pictures';
		my $file = &home($folder) . '/me/' . $name;
		return $file if -e $file;
	}
	return undef;
}

sub crest_peer_image_file {
	my ($entry) = @_;
	return undef unless ref $entry eq 'HASH';
	my $name = $entry->{'image_file'} || '';
	return undef unless $name =~ /^[\w.\-]+$/;
	my @devices = ($entry->{'device'}, &device_setter());
	my %seen;
	@devices = grep { defined $_ && length $_ && !$seen{$_}++ } @devices;
	foreach my $dev (@devices) {
		my $folder = &setting_grabber({ app => 'misc', setting => 'photo_location', device => $dev }) || 'Pictures';
		my $file = &home($folder) . '/me/' . $name;
		return $file if -e $file;
	}
	return undef;
}

sub crest_vouch_sign {
	my ($vouch, $priv) = @_;
	return undef unless ref $vouch eq 'HASH' && defined $priv && length $priv == 32;
	my $json = &crest_canonical_json($vouch);
	return undef unless defined $json;
	require Crypt::PK::Ed25519;
	my $key = Crypt::PK::Ed25519->new;
	$key->import_key_raw($priv, 'private');
	my $sig = $key->sign_message($json);
	return undef unless defined $sig && length $sig == 64;
	return { %$vouch, sig => encode_base64($sig, '') };
}

sub crest_vouch_verify {
	my ($vouch) = @_;
	return 0 unless ref $vouch eq 'HASH';
	my $pub = eval { decode_base64($vouch->{'from_pubkey'} || '') };
	my $sig = eval { decode_base64($vouch->{'sig'} || '') };
	return 0 unless defined $pub && length $pub == 32 && defined $sig && length $sig == 64;
	my $json = &crest_canonical_json($vouch);
	return 0 unless defined $json;
	require Crypt::PK::Ed25519;
	my $key = Crypt::PK::Ed25519->new;
	$key->import_key_raw($pub, 'public');
	return $key->verify_message($sig, $json) ? 1 : 0;
}

sub crest_peer_list_read {
	my $raw = &setting_grabber({ app => '__president', setting => 'peer_crests', device => 'all' });
	return [] unless defined $raw && length $raw;
	return $crest_peer_list_cache if defined $crest_peer_list_cache && defined $crest_peer_list_raw && $crest_peer_list_raw eq $raw;
	my $list = eval { decode_json($raw) };
	$crest_peer_list_raw = $raw;
	$crest_peer_list_cache = ref $list eq 'ARRAY' ? $list : [];
	return $crest_peer_list_cache;
}

sub crest_peer_list_write {
	my ($list) = @_;
	return 0 unless ref $list eq 'ARRAY';
	&setting_setter({ app => '__president', setting => 'peer_crests', device => 'all', value => encode_json($list) });
	undef $crest_peer_list_cache;
	undef $crest_peer_list_raw;
	return 1;
}

sub crest_peer_find {
	my ($uuid) = @_;
	return undef unless defined $uuid && length $uuid;
	foreach my $entry ( @{ &crest_peer_list_read() } ) {
		next unless ref $entry eq 'HASH';
		return $entry if (($entry->{'crest'}->{'uuid'} || '') eq $uuid);
	}
	return undef;
}

sub crest_peer_upsert {
	my ($entry) = @_;
	return 0 unless ref $entry eq 'HASH';
	my $uuid = $entry->{'crest'}->{'uuid'} || '';
	return 0 unless length $uuid;
	my $list = &crest_peer_list_read();
	my $replaced = 0;
	for my $i ( 0 .. $#$list ) {
		next unless ref $list->[$i] eq 'HASH';
		next unless (($list->[$i]->{'crest'}->{'uuid'} || '') eq $uuid);
		$list->[$i] = $entry;
		$replaced = 1;
		last;
	}
	push @$list, $entry unless $replaced;
	return &crest_peer_list_write($list);
}

sub crest_peer_update {
	my ($uuid, $changes) = @_;
	return undef unless defined $uuid && length $uuid && ref $changes eq 'HASH';
	my $list = &crest_peer_list_read();
	foreach my $entry ( @$list ) {
		next unless ref $entry eq 'HASH';
		next unless (($entry->{'crest'}->{'uuid'} || '') eq $uuid);
		$entry->{$_} = $changes->{$_} for keys %$changes;
		return &crest_peer_list_write($list) ? $entry : undef;
	}
	return undef;
}

sub crest_contact_links_read {
	my $raw = &setting_grabber({ app => '__president', setting => 'crest_contacts', device => 'all' });
	return {} unless defined $raw && length $raw;
	my $map = eval { decode_json($raw) };
	return ref $map eq 'HASH' ? $map : {};
}

sub crest_contact_links_write {
	my ($map) = @_;
	return 0 unless ref $map eq 'HASH';
	&setting_setter({ app => '__president', setting => 'crest_contacts', device => 'all', value => encode_json($map) });
	return 1;
}

sub crest_contact_link_set {
	my ($app, $uuid) = @_;
	$app = &unformat_name($app) if defined $app;
	my $map = &crest_contact_links_read();
	if (defined $app && length $app && defined $uuid && length $uuid) {
		$map->{$app} = $uuid;
		$map->{lc($app)} = $uuid if lc($app) ne $app;
	}
	elsif (defined $uuid && length $uuid) {
		foreach my $key ( keys %$map ) {
			delete $map->{$key} if (($map->{$key} || '') eq $uuid);
		}
	}
	return &crest_contact_links_write($map);
}

sub crest_contact_entry {
	my ($app) = @_;
	return undef unless defined $app && length $app;
	my $map = &crest_contact_links_read();
	my $uuid = $map->{$app} || $map->{lc($app)} || '';
	return undef unless length $uuid;
	return &crest_peer_find($uuid);
}

sub crest_contact_app_for_uuid {
	my ($uuid) = @_;
	return '' unless defined $uuid && length $uuid;
	my $map = &crest_contact_links_read();
	foreach my $app ( keys %$map ) {
		return $app if (($map->{$app} || '') eq $uuid);
	}
	return '';
}

sub crest_incoming_vouch_list_read {
	my $raw = &setting_grabber({ app => '__president', setting => 'crest_vouches', device => 'all' });
	return [] unless defined $raw && length $raw;
	my $list = eval { decode_json($raw) };
	return ref $list eq 'ARRAY' ? $list : [];
}

sub crest_incoming_vouch_list_write {
	my ($list) = @_;
	return 0 unless ref $list eq 'ARRAY';
	&setting_setter({ app => '__president', setting => 'crest_vouches', device => 'all', value => encode_json($list) });
	return 1;
}

sub crest_incoming_vouch_add {
	my ($vouch) = @_;
	return 0 unless ref $vouch eq 'HASH';
	my $sig = $vouch->{'sig'} || '';
	return 0 unless length $sig;
	my $list = &crest_incoming_vouch_list_read();
	foreach my $existing ( @$list ) {
		return 1 if (($existing->{'sig'} || '') eq $sig);
	}
	push @$list, $vouch;
	return &crest_incoming_vouch_list_write($list);
}

sub crest_vouch_introducer {
	my ($vouch, $own, $peers) = @_;
	return undef unless ref $vouch eq 'HASH' && &crest_vouch_verify($vouch);
	my $from = $vouch->{'from_uuid'} || '';
	my $pub = $vouch->{'from_pubkey'} || '';
	return undef unless length $from && length $pub;
	if (ref $own eq 'HASH' && $from eq ($own->{'uuid'} || '') && $pub eq ($own->{'pubkey'} || '')) {
		return $own;
	}
	foreach my $entry ( @{ $peers || [] } ) {
		next unless ref $entry eq 'HASH';
		my $crest = $entry->{'crest'} || {};
		next unless $from eq ($crest->{'uuid'} || '');
		return $crest if $pub eq ($crest->{'pubkey'} || '');
	}
	return undef;
}

sub crest_data_uri_bytes {
	my ($uri) = @_;
	return undef unless defined $uri && $uri =~ /^data:image\/[A-Za-z0-9.+-]+;base64,(.*)$/s;
	my $b64 = $1;
	$b64 =~ s/\s+//g;
	my $bytes = eval { decode_base64($b64) };
	return (defined $bytes && length $bytes) ? $bytes : undef;
}

sub crest_image_data_uri {
	my ($file, $suds, $standard, $max) = @_;
	return undef unless $file && -e $file && defined $suds && length $suds;
	my $bytes = &openssl_file_read($standard, $suds, $file, 0, 1);
	return undef unless defined $bytes && length $bytes;
	require File::Temp;
	my ($fh, $tmp) = File::Temp::tempfile('jawnos-crest-card-XXXXXX', TMPDIR => 1, UNLINK => 0);
	return undef unless $fh && $tmp;
	binmode $fh;
	print $fh $bytes;
	close $fh;
	$max ||= 512;
	my $jpg = $tmp . '.jpg';
	my $resized = &image_bridge_resize($tmp, $max, $max, $jpg);
	system('magick', $tmp, '-resize', "${max}x${max}>", '-quality', '86', $jpg) unless $resized;
	my $out = (-e $jpg && -s $jpg > 0) ? read_file($jpg) : undef;
	unlink $tmp; unlink $jpg;
	return undef unless defined $out && length $out;
	return 'data:image/jpeg;base64,' . encode_base64($out, '');
}

sub crest_code_build {
	my ($record, $priv) = @_;
	return undef unless ref $record eq 'HASH' && defined $priv && length $priv == 32;
	my $compact = {
		uuid => $record->{'uuid'} || '',
		name => $record->{'name'} || '',
		pubkey => $record->{'pubkey'} || '',
		fingerprint => $record->{'fingerprint'} || '',
		dhash => $record->{'dhash'} || '',
		version => $record->{'version'} || 1,
		issued => $record->{'issued'} || '',
	};
	if (length($record->{'construct'} || '')) {
		# A construct crest is written to a tag, not looked up, so it carries its
		# kind instead of the house address; the address would not fit the code.
		# The dHash stays with the drawing on the house that made it; the tag has
		# no picture, and dropping it leaves room for the house id.
		delete $compact->{'dhash'};
		$compact->{'construct'} = $record->{'construct'};
		$compact->{'construct_type'} = $record->{'construct_type'} || '';
		# The signing key is the house key, so house_pubkey is redundant; the
		# house uuid is what binds the construct to a known house.
		$compact->{'house_uuid'} = $record->{'house_uuid'} || '';
	}
	else {
		$compact->{'origin'} = $record->{'origin'} || &crest_origin();
	}
	my $signed = &crest_sign_record($compact, $priv);
	return undef unless $signed && $signed->{'sig'};
	my $json = JSON::PP->new->canonical(1)->encode($signed);
	require Compress::Zlib;
	my $packed = Compress::Zlib::compress($json);
	return undef unless defined $packed && length $packed;
	return 'CREST1Z:' . encode_base64($packed, '');
}

sub crest_code_parse {
	my ($code) = @_;
	return undef unless defined $code;
	$code =~ s/^\s+|\s+$//g;
	my ($packed, $compressed);
	if ($code =~ /^CREST1Z:(.*)$/is) {
		$packed = $1;
		$compressed = 1;
	}
	elsif ($code =~ /^CREST1:(.*)$/is) {
		$packed = $1;
	}
	else {
		return undef;
	}
	$packed =~ s/\s+//g;
	my $bytes = eval { decode_base64($packed) };
	return undef unless defined $bytes && length $bytes;
	if ($compressed) {
		require Compress::Zlib;
		$bytes = Compress::Zlib::uncompress($bytes);
		return undef unless defined $bytes && length $bytes;
	}
	my $record = eval { decode_json($bytes) };
	return ref $record eq 'HASH' ? $record : undef;
}

sub crest_qr_png {
	my ($code) = @_;
	return undef unless defined $code && length $code;
	require File::Temp;
	my ($fh, $tmp) = File::Temp::tempfile('jawnos-crest-qr-XXXXXX', TMPDIR => 1, UNLINK => 0);
	return undef unless $fh && $tmp;
	binmode $fh;
	print $fh $code;
	close $fh;
	open(my $qr, '-|', 'qrencode', '-t', 'PNG', '-o', '-', '-s', '6', '-l', 'M', '-r', $tmp) or do { unlink $tmp; return undef; };
	binmode $qr;
	my $png = do { local $/; <$qr> };
	close $qr;
	unlink $tmp;
	return (defined $png && length $png) ? $png : undef;
}

sub crest_image_sync_store {
	my ($crest, $uri) = @_;
	return 0 unless ref $crest eq 'HASH' && ($crest->{'uuid'} || '') ne '' && defined $uri && length $uri;
	my $payload = encode_json({
		uuid => $crest->{'uuid'},
		dhash => $crest->{'dhash'} || '',
		image => $uri,
		at => &rightNow(),
	});
	&setting_setter({ app => '__president', setting => 'crest_image', device => 'all', value => $payload });
	return 1;
}

sub crest_image_sync_read {
	my $raw = &setting_grabber({ app => '__president', setting => 'crest_image', device => 'all' });
	return {} unless defined $raw && length $raw;
	my $payload = eval { decode_json($raw) };
	return ref $payload eq 'HASH' ? $payload : {};
}

sub crest_image_sync_seed {
	my ($c) = @_;
	my $crest = &crest_record_read();
	return 0 unless $crest->{'uuid'};
	my $sync = &crest_image_sync_read();
	return 1 if ($sync->{'uuid'} || '') eq ($crest->{'uuid'} || '') && ($sync->{'image'} || '') ne '';
	my $file = &crest_image_file($crest, 'image');
	return 0 unless $file;
	my $suds = &session_suds($c);
	return 0 unless $suds;
	my $device = $crest->{'device'} || &device_setter();
	my $standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard', device => $device }) || 'aes-256-ctr';
	my $uri = &crest_image_data_uri($file, $suds, $standard, 512);
	unless (defined $uri) {
		$device = &device_setter();
		$standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard', device => $device }) || 'aes-256-ctr';
		$uri = &crest_image_data_uri($file, $suds, $standard, 512);
	}
	return 0 unless defined $uri;
	return &crest_image_sync_store($crest, $uri);
}

sub crest_image_materialize {
	my ($c, $crest, $sync) = @_;
	$crest ||= &crest_record_read();
	return 0 unless $crest->{'uuid'};
	return 1 if &crest_image_file($crest, 'image');
	$sync ||= &crest_image_sync_read();
	return 0 unless ($sync->{'uuid'} || '') eq ($crest->{'uuid'} || '');
	my $bytes = &crest_data_uri_bytes($sync->{'image'});
	return 0 unless $bytes;
	my $suds = &session_suds($c);
	return 0 unless $suds;
	my $device = &device_setter();
	my $folder = &setting_grabber({ app => 'misc', setting => 'photo_location', device => $device }) || 'Pictures';
	my $dir = &home($folder) . '/me';
	eval { require File::Path; File::Path::make_path($dir) } unless -d $dir;
	require File::Temp;
	my ($fh, $tmp) = File::Temp::tempfile('jawnos-crest-sync-XXXXXX', TMPDIR => 1, UNLINK => 0);
	return 0 unless $fh && $tmp;
	binmode $fh;
	print $fh $bytes;
	close $fh;
	my $ref = $tmp . '.ref.png';
	unless (&crest_normalize_image($tmp, $ref)) {
		unlink $tmp; unlink $ref;
		return 0;
	}
	my $distance = &crest_hamming($crest->{'dhash'}, &crest_dhash($ref));
	unless (defined $distance && $distance <= 16) {
		unlink $tmp; unlink $ref;
		return 0;
	}
	my $standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard', device => $device }) || 'aes-256-ctr';
	my $name = $crest->{'image'} || 'crest.sync.jpg.enc';
	$name = 'crest.sync.jpg.enc' unless $name =~ /^[\w.\-]+$/;
	my $enc = "$dir/$name";
	unless (&openssl_file_crypt('e', $standard, $suds, $tmp, $enc, 0, 1)) {
		unlink $tmp; unlink $ref;
		return 0;
	}
	my $ref_name = $crest->{'reference'} || '';
	if ($ref_name =~ /^[\w.\-]+$/) {
		my $ref_enc = "$dir/$ref_name";
		&openssl_file_crypt('e', $standard, $suds, $ref, $ref_enc, 0, 1);
	}
	unlink $tmp; unlink $ref;
	return 1;
}

sub construct_crest_record_read {
	my ($app) = @_;
	return {} unless defined $app && length $app;
	my $raw = &setting_grabber({ app => $app, setting => 'crest', device => 'all' });
	return {} unless defined $raw && length $raw;
	my $record = eval { decode_json($raw) };
	return ref $record eq 'HASH' ? $record : {};
}

sub construct_crest_record_write {
	my ($app, $record) = @_;
	return 0 unless defined $app && length $app && ref $record eq 'HASH';
	&setting_setter({ app => $app, setting => 'crest', device => 'all', value => encode_json($record) });
	return 1;
}

sub construct_crest_fingerprint {
	my ($record) = @_;
	return undef unless ref $record eq 'HASH';
	my $seed = join "\x1f", ($record->{'house_uuid'} || ''), ($record->{'construct'} || ''),
		($record->{'uuid'} || ''), ($record->{'dhash'} || ''), ($record->{'pubkey'} || '');
	my $hex = uc(&sha256_hex($seed));
	$hex =~ s/(.{4})(?=.)/$1 /g;
	return $hex;
}

sub construct_crest_image_sync_read {
	my ($app) = @_;
	return {} unless defined $app && length $app;
	my $raw = &setting_grabber({ app => $app, setting => 'crest_image', device => 'all' });
	return {} unless defined $raw && length $raw;
	my $payload = eval { decode_json($raw) };
	return ref $payload eq 'HASH' ? $payload : {};
}

sub construct_crest_image_sync_store {
	my ($app, $crest, $uri) = @_;
	return 0 unless defined $app && length $app && ref $crest eq 'HASH'
		&& ($crest->{'uuid'} || '') ne '' && defined $uri && length $uri;
	my $payload = encode_json({
		uuid => $crest->{'uuid'},
		dhash => $crest->{'dhash'} || '',
		image => $uri,
		at => &rightNow(),
	});
	&setting_setter({ app => $app, setting => 'crest_image', device => 'all', value => $payload });
	return 1;
}

sub construct_crest_image_materialize {
	my ($c, $app) = @_;
	my $crest = &construct_crest_record_read($app);
	return 0 unless $crest->{'uuid'};
	return &crest_image_materialize($c, $crest, &construct_crest_image_sync_read($app));
}

sub construct_crest_image_src {
	my ($app) = @_;
	my $crest = &construct_crest_record_read($app);
	return '' unless $crest->{'uuid'} && &crest_image_file($crest, 'image');
	return '/manager/people/crest_image?app=' . &http_name($app) . '&stamp=' . &rightNow();
}

sub peer_scope_rank {
	return ( none => 0, revoked => 0, visitor => 1, resident => 2, member => 2, trusted => 3 );
}

sub peer_action_scope {
	my ($action) = @_;
	my %need = (
		view              => 'visitor',
		chat_reply        => 'visitor',
		mail_reply        => 'visitor',
		chat_start        => 'resident',
		mail_start        => 'resident',
		go                => 'resident',
		appointment_start => 'resident',
		appointment_stop  => 'resident',
		toggle            => 'resident',
		# command runs a shell command, not an app toggle: a resident may switch
		# things, but running a command is the higher tier.
		command           => 'trusted',
		remote_control    => 'trusted',
		relay             => 'trusted',
		backup            => 'trusted',
	);
	return $need{lc($action // '')};
}

sub peer_movement_action {
	my ($type) = @_;
	$type = lc($type // '');
	return 'command' if $type eq 'command';
	return 'toggle' if $type eq 'toggle' || $type eq 'switch';
	return 'appointment_stop' if $type =~ /^(?:stop|cancel|pause|delay)$/;
	return 'appointment_start';
}

sub device_kind_label {
	my ($d) = @_;
	return '' unless $d && ref $d eq 'HASH';
	my $kind = lc($d->{'kind'} || '');
	if (!$kind) {
		$kind = 'phone' if ($d->{'bio_pubkey'} || '') ne '';
		$kind = 'app' if !$kind && ($d->{'app_pubkey'} || '') ne '';
		$kind = 'webview' if !$kind && ($d->{'agent'} || '') =~ /AppleWebKit\/605/;
		$kind = 'browser' if !$kind;
	}
	my %key = (
		app => 'device.kind_app',
		phone => 'device.kind_phone',
		webview => 'device.kind_window',
		browser => 'device.kind_browser',
	);
	return &lang($key{$kind} || 'device.kind_browser');
}

sub peer_rate_limit {
	my ($kind) = @_;
	my %limit = (
		message => [ 30,    60_000 ],   # 30 messages a minute
		action  => [ 120, 3_600_000 ],  # 120 actions an hour
	);
	return $limit{$kind};
}

sub peer_rate_ok {
	my ($rm, $kind) = @_;
	return 1 unless $rm && ref $rm eq 'HASH' && $rm->{'signatorial'};
	my $spec = &peer_rate_limit($kind);
	return 1 unless $spec;
	my ($limit, $window) = @{$spec};
	my $now = &rightNow();
	my $prefix = $rm->{'signatorial'} . ':' . $kind . ':';
	my $row = &db_query(
		'select count(*) as c from cache where context = ? and app = ? and uuid like ? and server_time > ?',
		'peer_rate', $kind, $prefix . '%', $now - $window
	)->hashes->[0];
	return 0 if $row && ($row->{'c'} || 0) >= $limit;
	&db_query(
		'delete from cache where context = ? and app = ? and uuid like ? and server_time < ?',
		'peer_rate', $kind, $prefix . '%', $now - $window
	);
	&db_insert('cache', {
		uuid => $prefix . $now . ':' . &random_string_creator(8),
		context => 'peer_rate',
		app => $kind,
		server_time => $now,
		timestamp => $now,
	});
	return 1;
}

sub people_owner_ensure {
	my $uuid = 'owner';
	my $known = eval { &db_query('select uuid from people where uuid = ? limit 1', $uuid)->hashes->[0] };
	unless ($known) {
		my $now = &rightNow();
		my $name = &setting_grabber({ app => 'me', setting => 'name' }) || 'Owner';
		my $made = eval {
			&db_insert('people', {
				uuid => $uuid,
				name => $name,
				privilege => 'citizen',
				status => 'active',
				created => $now,
				server_time => $now,
			});
			1;
		};
		# the migration: every device that has never been assigned is the
		# owner's. New devices paired later stay unassigned until someone says
		# whose they are.
		if ($made) {
			eval { &db_query('update paired_devices set person_uuid = ? where person_uuid is null or person_uuid = ?', $uuid, '') };
		}
	}
	return $uuid;
}

sub person_for_device {
	my ($device_uuid) = @_;
	return undef unless defined $device_uuid && length $device_uuid;
	&people_owner_ensure();
	my $d = eval { &db_select('paired_devices', ['person_uuid'], { uuid => $device_uuid })->hash };
	my $person_uuid = ($d && $d->{'person_uuid'}) ? $d->{'person_uuid'} : '';
	return undef unless $person_uuid;
	my $p = eval { &db_select('people', undef, { uuid => $person_uuid, status => 'active' })->hash };
	return $p || undef;
}

sub person_privilege {
	my ($person) = @_;
	return ($person && ref $person eq 'HASH' && $person->{'privilege'}) ? $person->{'privilege'} : 'guest';
}

sub tier_needed {
	my ($path) = @_;
	return '' unless defined $path && length $path;
	for my $tier ( @{$tier_required} ) {
		return $tier->[0] if $path =~ $tier->[1];
	}
	return '';
}

sub tier_denied {
	my ($path, $privilege) = @_;
	my $need = tier_needed($path);
	return 0 unless length $need;
	my $have = $tier_rank{ lc($privilege // '') } || 0;
	return $have < $tier_rank{$need} ? 1 : 0;
}

sub privilege_is_house {
	my ($privilege) = @_;
	return (( $tier_rank{ lc($privilege // '') } || 0 ) >= $tier_rank{'resident'}) ? 1 : 0;
}

sub guest_browser_session {
	my ($privilege, $source) = @_;
	return 0 if (($source || '') eq 'device');
	return &privilege_is_house($privilege) ? 0 : 1;
}

sub person_active {
	my ($person_uuid) = @_;
	return 0 unless defined $person_uuid && length $person_uuid;
	# Plain SQL, not db_select: this runs on the fast path of every request, and
	# SQL::Abstract's select costs a few hundred microseconds per call.
	my $p = eval { &db_query('select status from people where uuid = ?', $person_uuid)->hash };
	return ($p && ($p->{'status'} || '') eq 'active') ? 1 : 0;
}

sub device_active {
	my ($device_uuid) = @_;
	return 0 unless defined $device_uuid && length $device_uuid;
	my $d = eval { &db_query('select status from paired_devices where uuid = ?', $device_uuid)->hash };
	return ($d && ($d->{'status'} || '') eq 'active') ? 1 : 0;
}

sub session_principal_active {
	my ($person_uuid, $device_uuid) = @_;
	return 0 if defined $person_uuid && length $person_uuid && !&person_active($person_uuid);
	return 0 if defined $device_uuid && length $device_uuid && !&device_active($device_uuid);
	return 1;
}

sub person_revoke_check {
	my ($person_uuid, $current_device_uuid) = @_;
	return (0, 'no person') unless defined $person_uuid && length $person_uuid;
	my $person = eval { &db_select('people', undef, { uuid => $person_uuid })->hash };
	return (0, 'no person') unless $person && ($person->{'status'} || '') eq 'active';
	return (0, 'the owner cannot be revoked') if $person_uuid eq 'owner';
	if (defined $current_device_uuid && length $current_device_uuid) {
		my $d = eval { &db_select('paired_devices', ['person_uuid'], { uuid => $current_device_uuid })->hash };
		return (0, 'you cannot revoke the person you are using') if $d && ($d->{'person_uuid'} || '') eq $person_uuid;
	}
	return (1, '');
}

sub person_revoke {
	my ($person_uuid) = @_;
	return undef unless defined $person_uuid && length $person_uuid;
	my $now = &rightNow();
	my $devices = eval { &db_select('paired_devices', ['uuid'], { person_uuid => $person_uuid })->hashes } || [];
	foreach my $d ( @{$devices} ) {
		&db_update('paired_devices', { status => 'revoked', server_time => $now }, { uuid => $d->{'uuid'} });
		&house_key_share_revoke_device($d->{'uuid'});
		&db_delete('security', { level => 'padlock_device', uuid => $d->{'uuid'} });
	}
	# a share row can name the person even after a device row moved
	eval { &db_delete('house_key_shares', { holder_person => $person_uuid }) };
	# an invitation is the person's; a revoked person's tickets stop at the door
	eval { &db_query('update tickets set status = ? where person_uuid = ? and status = ?', 'revoked', $person_uuid, 'active') };
	&db_update('people', { status => 'revoked', server_time => $now }, { uuid => $person_uuid });
	return { person => $person_uuid, devices => scalar @{$devices} };
}

1;
