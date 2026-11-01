package subs;

# House2: extracted from subroutines.pl (package subs). Loaded on
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

our $crockford_alphabet;
our $database;
our $device;
our $gb;
our $house_key_password_context;
our $house_key_password_magic;
our $shamir_paper_prefix;

sub house_key_password_open {
	my ($blob64, $password) = @_;
	return undef unless defined $blob64 && length $blob64;
	return undef unless defined $password && length $password;
	my $blob = eval { decode_base64($blob64) };
	return undef unless defined $blob && length $blob;
	return undef unless length($blob) > 5 + 1 + 1 + 12 + 16;
	return undef unless substr($blob, 0, 5) eq $house_key_password_magic;
	my $dlen = unpack('C', substr($blob, 5, 1));
	return undef unless $dlen > 0 && length($blob) > 6 + $dlen + 1 + 12 + 16;
	my $desc = substr($blob, 6, $dlen);
	my $off = 6 + $dlen;
	my $slen = unpack('C', substr($blob, $off, 1)); $off += 1;
	return undef unless $slen > 0 && length($blob) > $off + $slen + 12 + 16;
	my $salt = substr($blob, $off, $slen); $off += $slen;
	my $iv = substr($blob, $off, 12); $off += 12;
	my $tag = substr($blob, $off, 16); $off += 16;
	my $ct = substr($blob, $off);
	return undef unless length $ct;
	my ($aes) = &house_key_password_kdf($password, $salt, 32, $desc);
	return undef unless $aes;
	my $K = eval { Crypt::AuthEnc::GCM::gcm_decrypt_verify('AES', $aes, $iv, $house_key_password_context, $ct, $tag) };
	return (defined $K && length $K) ? $K : undef;
}

sub password_share_store {
	my ($password, $suds, $force) = @_;
	return 0 unless defined $password && length $password;
	return 0 unless defined $suds && length $suds;
	my $q = &db_query('select uuid, value from settings where app = ? and setting = ? order by server_time desc limit 1', '__president', 'password_share');
	my $row = $q ? $q->hashes->[0] : undef;
	return 1 if $row && $row->{'value'} && !$force;
	my $sealed = &house_key_password_seal($suds, $password);
	return 0 unless $sealed;
	my $now = &rightNow();
	if ($row) {
		&db_update('settings', { value => $sealed, server_time => $now }, { uuid => $row->{'uuid'} });
	}
	else {
		&db_insert('settings', { app => '__president', setting => 'password_share', device => 'all', value => $sealed, timestamp => $now, server_time => $now });
	}
	return 1;
}

sub shamir_gf_mul {
	my ($a, $b) = @_;
	my $p = 0;
	for (1 .. 8) {
		$p ^= $a if $b & 1;
		my $carry = $a & 0x80;
		$a = ($a << 1) & 0xff;
		$a ^= 0x1b if $carry;
		$b >>= 1;
	}
	return $p;
}

sub shamir_gf_pow {
	my ($a, $n) = @_;
	my $r = 1;
	while ($n > 0) {
		$r = &shamir_gf_mul($r, $a) if $n & 1;
		$a = &shamir_gf_mul($a, $a);
		$n >>= 1;
	}
	return $r;
}

sub shamir_gf_inv {
	my ($a) = @_;
	return 0 if $a == 0;
	return &shamir_gf_pow($a, 254);
}

sub shamir_split {
	my ($secret, $k, $n) = @_;
	return undef unless defined $secret && length $secret;
	$k ||= 3;
	$n ||= 5;
	return undef unless $k >= 2 && $k <= $n && $n <= 255;
	require Crypt::PRNG;
	my $len = length $secret;
	my @coeff = ($secret);
	push @coeff, Crypt::PRNG::random_bytes($len) for 2 .. $k;
	my @shares;
	foreach my $x (1 .. $n) {
		my $y = "\0" x $len;
		foreach my $b (0 .. $len - 1) {
			my $v = 0;
			foreach my $d (0 .. $k - 1) {
				my $c = ord(substr($coeff[$d], $b, 1));
				$v ^= &shamir_gf_mul($c, &shamir_gf_pow($x, $d)) if $c;
			}
			substr($y, $b, 1) = chr($v);
		}
		push @shares, { x => $x, y => $y };
	}
	return \@shares;
}

sub shamir_combine {
	my ($shares) = @_;
	return undef unless $shares && ref $shares eq 'ARRAY' && @{$shares} >= 2;
	my %seen;
	foreach my $s (@{$shares}) {
		return undef unless $s && ref $s eq 'HASH';
		my $x = $s->{'x'};
		my $y = $s->{'y'};
		return undef unless defined $x && $x =~ /^\d+$/ && $x >= 1 && $x <= 255;
		return undef if $seen{$x}++;
		return undef unless defined $y && length $y;
	}
	my $len = length $shares->[0]{'y'};
	foreach my $s (@{$shares}) { return undef unless length $s->{'y'} == $len; }
	my $out = "\0" x $len;
	foreach my $i (0 .. $#{$shares}) {
		my $xi = $shares->[$i]{'x'};
		my $li = 1;
		foreach my $j (0 .. $#{$shares}) {
			next if $i == $j;
			my $xj = $shares->[$j]{'x'};
			$li = &shamir_gf_mul($li, &shamir_gf_mul($xj, &shamir_gf_inv($xi ^ $xj)));
		}
		next if $li == 0;
		my $y = $shares->[$i]{'y'};
		foreach my $b (0 .. $len - 1) {
			my $v = &shamir_gf_mul($li, ord(substr($y, $b, 1)));
			substr($out, $b, 1) = chr(ord(substr($out, $b, 1)) ^ $v) if $v;
		}
	}
	return $out;
}

sub shamir_share_encode {
	my ($s) = @_;
	return undef unless $s && defined $s->{'x'} && defined $s->{'y'};
	return encode_base64(pack('C', $s->{'x'}) . $s->{'y'}, '');
}

sub crockford_encode {
	my ($bytes) = @_;
	return undef unless defined $bytes;
	my ($out, $acc, $bits) = ('', 0, 0);
	foreach my $b ( unpack('C*', $bytes) ) {
		$acc = (($acc << 8) | $b) & 0xffffffff;
		$bits += 8;
		while ($bits >= 5) {
			$bits -= 5;
			$out .= substr($crockford_alphabet, ($acc >> $bits) & 31, 1);
			$acc &= (1 << $bits) - 1;
		}
	}
	$out .= substr($crockford_alphabet, ($acc << (5 - $bits)) & 31, 1) if $bits;
	return $out;
}

sub crockford_decode {
	my ($str) = @_;
	return undef unless defined $str && length $str;
	$str = uc $str;
	$str =~ tr/ILO/110/;
	$str =~ s/[^0-9A-Z]//g;
	return undef unless length $str;
	my ($out, $acc, $bits) = ('', 0, 0);
	foreach my $ch ( split '', $str ) {
		my $v = index($crockford_alphabet, $ch);
		return undef if $v < 0;
		$acc = (($acc << 5) | $v) & 0xffffffff;
		$bits += 5;
		while ($bits >= 8) {
			$bits -= 8;
			$out .= chr(($acc >> $bits) & 255);
			$acc &= (1 << $bits) - 1;
		}
	}
	# a valid code leaves only zero padding bits
	return undef if $bits && $acc;
	return $out;
}

sub shamir_share_encode_paper {
	my ($s) = @_;
	return undef unless $s && defined $s->{'x'} && defined $s->{'y'};
	my $code = &crockford_encode(pack('C', $s->{'x'}) . $s->{'y'});
	return undef unless defined $code && length $code;
	$code =~ s/(.{5})/$1-/g;
	$code =~ s/-$//;
	return $shamir_paper_prefix . '-' . $code;
}

sub shamir_share_decode {
	my ($str) = @_;
	return undef unless defined $str && length $str;
	my $s = $str;
	$s =~ s/^\s+|\s+$//g;
	if ($s =~ /^\Q$shamir_paper_prefix\E[- ]?/i) {
		my $body = $s;
		$body =~ s/^\Q$shamir_paper_prefix\E[- ]?//i;
		my $raw = &crockford_decode($body);
		return undef unless defined $raw && length $raw >= 2;
		return { x => unpack('C', substr($raw, 0, 1)), y => substr($raw, 1) };
	}
	my $raw = eval { decode_base64($str) };
	return undef unless defined $raw && length $raw >= 2;
	return { x => unpack('C', substr($raw, 0, 1)), y => substr($raw, 1) };
}

sub shamir_qr_save {
	my ($codes, $label) = @_;
	return undef unless $codes && ref $codes eq 'ARRAY' && @{$codes};
	my $base = &home('~/.jawnos_paper_shares');
	require File::Path;
	eval { File::Path::make_path($base) };
	return undef unless -d $base;
	chmod 0700, $base;
	my $dir = $base . '/' . &rightNow() . '-' . &random_string_creator(6);
	eval { File::Path::make_path($dir) };
	return undef unless -d $dir;
	chmod 0700, $dir;
	my @images;
	my $n = 0;
	foreach my $code ( @{$codes} ) {
		next unless defined $code && length $code;
		$n++;
		my $tmp = "$dir/.text-$n";
		my $png = "$dir/share-$n.png";
		my $fh;
		unless (open $fh, '>', $tmp) { next; }
		print $fh $code;
		close $fh;
		chmod 0600, $tmp;
		my $ok = system('qrencode', '-o', $png, '-s', '6', '-l', 'Q', '-r', $tmp) == 0;
		unlink $tmp;
		next unless $ok && -s $png;
		chmod 0600, $png;
		my $bytes = &read_file($png);
		next unless defined $bytes && length $bytes;
		push @images, {
			index => $n,
			file => $png,
			data => 'data:image/png;base64,' . encode_base64($bytes, ''),
		};
	}
	my $readme = "$dir/README.txt";
	if (open my $rf, '>', $readme) {
		print $rf "These are paper shares of the house key. Any three rebuild it.\n";
		print $rf "Keep them apart, do not sync this folder, and print or copy them\n";
		print $rf "to separate places. The QR codes carry the share text.\n";
		close $rf;
		chmod 0600, $readme;
	}
	return {
		dir => $dir,
		label => $label || 'paper shares',
		images => \@images,
		missing => scalar(@{$codes}) - scalar(@images),
	};
}

sub shamir_policy {
	my $raw = eval { &setting_grabber({ app => '__president', setting => 'shamir' }) };
	if (defined $raw && $raw =~ /^(\d+):(\d+)$/) {
		my ($k, $n) = ($1, $2);
		return ($k, $n) if $k >= 2 && $k <= $n && $n <= 255;
	}
	return (3, 5);
}

sub shamir_open_shares {
	my ($codes) = @_;
	return undef unless $codes && ref $codes eq 'ARRAY';
	my ($k) = &shamir_policy();
	my @decoded = grep { defined $_ } map { &shamir_share_decode($_) } @$codes;
	return undef if @decoded < $k;
	# shares of one split share a length; a stray code that decodes to another
	# length is a typo or the wrong paper, not a share
	my %by_len;
	$by_len{ length $_->{'y'} }++ for @decoded;
	my ($len) = sort { $by_len{$b} <=> $by_len{$a} } keys %by_len;
	my (@shares, %seen);
	foreach my $s (@decoded) {
		next unless length $s->{'y'} == $len;
		next unless $s->{'x'} >= 1 && $s->{'x'} <= 255;
		next if $seen{$s->{'x'}}++;
		push @shares, $s;
	}
	return undef if @shares < $k;
	@shares = @shares[0 .. $k - 1];
	my $secret = &shamir_combine(\@shares);
	return undef unless defined $secret && length $secret;
	return $secret;
}

sub house_key_share_wrap {
	my ($share, $pubkey_b64) = @_;
	return undef unless defined $share && length $share;
	return undef unless defined $pubkey_b64 && length $pubkey_b64;
	my $raw = eval { decode_base64($pubkey_b64) };
	return undef unless defined $raw && length($raw) == 32;
	require Crypt::PK::X25519;
	my $pk = Crypt::PK::X25519->new();
	return undef unless eval { $pk->import_key_raw($raw, 'public') };
	return &house_key_wrap($share, $pk);
}

sub house_key_share_set_current {
	my $row = eval { &db_query('select set_id from house_key_shares where status = ? order by server_time desc, rowid desc limit 1', 'active')->hashes->[0] };
	return $row ? $row->{'set_id'} : '';
}

sub house_key_share_set_active {
	my ($set_id) = @_;
	return [] unless defined $set_id && length $set_id;
	my $rows = eval { &db_query('select * from house_key_shares where set_id = ? and status = ? order by share_index', $set_id, 'active')->hashes };
	return $rows || [];
}

sub house_key_share_set_count {
	my ($set_id) = @_;
	my $rows = &house_key_share_set_active($set_id);
	return scalar @{$rows};
}

sub house_key_share_for_device {
	my ($device_uuid, $set_id) = @_;
	return [] unless defined $device_uuid && length $device_uuid;
	my @args = ($device_uuid, 'active');
	my $sql = 'select * from house_key_shares where holder_device = ? and status = ?';
	if (defined $set_id && length $set_id) { $sql .= ' and set_id = ?'; push @args, $set_id; }
	$sql .= ' order by server_time desc';
	my $rows = eval { &db_query($sql, @args)->hashes };
	return $rows || [];
}

sub house_key_share_create_set {
	my ($suds, $holders) = @_;
	return undef unless defined $suds && length $suds;
	$holders = [] unless $holders && ref $holders eq 'ARRAY';
	# the owner migration attaches devices that predate the people table; doing it
	# here keeps the one-share-per-person rule honest on an older house
	&people_owner_ensure();
	my ($k, $n) = &shamir_policy();
	my $shares = &shamir_split($suds, $k, $n);
	return undef unless $shares;
	my $set_id = &random_string_creator(25);
	my $now = &rightNow();
	my (@assigned, @paper, @skipped, %holder_used, %device_seen);
	my $next = 0;
	foreach my $device_uuid ( @{$holders} ) {
		next unless defined $device_uuid && length $device_uuid;
		next if $device_seen{$device_uuid}++;
		my $device = eval { &db_select('paired_devices', undef, { uuid => $device_uuid, status => 'active' })->hashes->[0] };
		unless ($device) { push @skipped, { device => $device_uuid, why => 'no device' }; next; }
		my $pubkey = $device->{'share_pubkey'} || '';
		unless (length $pubkey) { push @skipped, { device => $device_uuid, why => 'no share key' }; next; }
		my $person = $device->{'person_uuid'} || '';
		my $holder_key = length $person ? 'p:' . $person : 'd:' . $device_uuid;
		if ($holder_used{$holder_key}) { push @skipped, { device => $device_uuid, why => 'person already holds one' }; next; }
		last if $next >= scalar @{$shares};
		my $share = $shares->[$next];
		my $raw = pack('C', $share->{'x'}) . $share->{'y'};
		my $wrapped = &house_key_share_wrap($raw, $pubkey);
		unless ($wrapped) { push @skipped, { device => $device_uuid, why => 'wrap failed' }; next; }
		my $made = eval {
			&db_insert('house_key_shares', {
				uuid => &random_string_creator(25),
				set_id => $set_id,
				share_index => $share->{'x'},
				holder_person => $person,
				holder_device => $device_uuid,
				alg => 'x25519',
				wrapped => $wrapped,
				status => 'active',
				created => $now,
				server_time => $now,
			});
		};
		unless ($made) { push @skipped, { device => $device_uuid, why => 'not stored' }; next; }
		$holder_used{$holder_key} = 1;
		$next++;
		push @assigned, { device => $device_uuid, device_name => $device->{'name'}, person => $person, share_index => $share->{'x'} };
	}
	while ($next < scalar @{$shares}) {
		push @paper, &shamir_share_encode_paper($shares->[$next]);
		$next++;
	}
	# the policy is public and syncs; the shares themselves never leave wrapped
	&db_query('delete from settings where app = ? and setting = ?', '__president', 'shamir');
	&db_insert('settings', { app => '__president', setting => 'shamir', device => 'all', value => "$k:$n", timestamp => $now, server_time => $now });
	&db_query('delete from settings where app = ? and setting = ?', '__president', 'shamir_stale');
	return { set_id => $set_id, k => $k, n => $n, assigned => \@assigned, paper => \@paper, skipped => \@skipped };
}

sub house_key_share_revoke_device {
	my ($device_uuid) = @_;
	return unless defined $device_uuid && length $device_uuid;
	eval { &db_delete('house_key_shares', { holder_device => $device_uuid }) };
}

sub house_key_share_clear {
	my $had = eval { &db_query('select count(*) as n from house_key_shares')->hashes->[0]{'n'} } || 0;
	eval { &db_query('delete from house_key_shares') };
	eval { &db_query('delete from house_key_share_releases') };
	eval { &db_query('delete from house_key_share_requests') };
	if ($had) {
		my $now = &rightNow();
		&db_query('delete from settings where app = ? and setting = ?', '__president', 'shamir_stale');
		&db_insert('settings', { app => '__president', setting => 'shamir_stale', device => 'all', value => 'key_rotation', timestamp => $now, server_time => $now });
	}
	return $had;
}

sub house_key_share_request_create {
	my ($pubkey_b64, $name) = @_;
	my $raw = eval { decode_base64($pubkey_b64 // '') };
	return undef unless defined $raw && length($raw) == 32;
	my ($k, $n) = &shamir_policy();
	my $set_id = &house_key_share_set_current();
	my $have = length $set_id ? &house_key_share_set_count($set_id) : 0;
	my $uuid = &random_string_creator(25);
	my $code = &code_chars_make(6);
	my $now = &rightNow();
	my $made = eval {
		&db_insert('house_key_share_requests', {
			uuid => $uuid,
			code => $code,
			asker_pubkey => encode_base64($raw, ''),
			name => substr(($name // 'Recovering device'), 0, 60),
			need => $k,
			available => $have,
			set_id => $set_id,
			status => 'open',
			created => $now,
			server_time => $now,
		});
	};
	return undef unless $made;
	return { uuid => $uuid, code => $code, need => $k, have => $have, set_id => $set_id };
}

sub house_key_share_request_open {
	my ($uuid) = @_;
	return undef unless defined $uuid && length $uuid;
	my $row = eval { &db_select('house_key_share_requests', undef, { uuid => $uuid })->hashes->[0] };
	return undef unless $row;
	return undef unless ($row->{'status'} || '') eq 'open';
	return undef if (($row->{'server_time'} || 0) < &rightNow() - 1800000);
	return $row;
}

sub house_key_share_requests_open {
	my $rows = eval { &db_query('select * from house_key_share_requests where status = ? and server_time >= ? order by server_time desc', 'open', &rightNow() - 1800000)->hashes };
	return $rows || [];
}

sub house_key_share_release_add {
	my ($request_uuid, $device_uuid, $share_index, $wrapped) = @_;
	my $req = &house_key_share_request_open($request_uuid);
	return (0, 'no request') unless $req;
	return (0, 'no device') unless defined $device_uuid && length $device_uuid;
	return (0, 'no share') unless defined $share_index && $share_index =~ /^\d+$/;
	return (0, 'no blob') unless defined $wrapped && length $wrapped;
	# the signed-in device must actually hold that share in the request's set
	my $row = eval { &db_select('house_key_shares', undef, { set_id => $req->{'set_id'}, holder_device => $device_uuid, share_index => $share_index, status => 'active' })->hashes->[0] };
	return (0, 'not yours') unless $row;
	my $exists = eval { &db_query('select uuid from house_key_share_releases where request_uuid = ? and share_index = ? limit 1', $request_uuid, $share_index)->hashes->[0] };
	return (1, 'already') if $exists;
	my $now = &rightNow();
	my $made = eval {
		&db_insert('house_key_share_releases', {
			uuid => &random_string_creator(25),
			request_uuid => $request_uuid,
			set_id => $req->{'set_id'},
			share_index => $share_index,
			holder_device => $device_uuid,
			wrapped => $wrapped,
			created => $now,
			server_time => $now,
		});
	};
	return $made ? (1, '') : (0, 'not stored');
}

sub house_key_share_releases {
	my ($request_uuid) = @_;
	my $rows = eval { &db_query('select * from house_key_share_releases where request_uuid = ? order by share_index', $request_uuid)->hashes };
	return $rows || [];
}

sub house_key_share_cleanup {
	my $cutoff = &rightNow() - 3600000;
	eval { &db_query('delete from house_key_share_releases where server_time < ?', $cutoff) };
	eval { &db_query('delete from house_key_share_requests where server_time < ?', $cutoff) };
}

sub vault_read {
	my $device = &signatorial_designer();
	my $q = &db_query('select value, server_time from settings where app = ? and setting = ? and device = ? order by server_time desc limit 1', '__president', 'vault', $device);
	my $row = $q ? $q->hashes->[0] : undef;
	return unless $row && $row->{'value'};
	my $suds = &note_decrypter(&house_key(), $row->{'value'});
	return unless $suds;
	$suds =~ s/\s+$//;
	return ($suds, $row->{'server_time'});
}

sub vault_seed {
	my ($suds, $force) = @_;
	return unless $suds;
	$suds =~ s/\s+$//;
	return unless length $suds;
	my $device = &signatorial_designer();
	my $q = &db_query('select uuid from settings where app = ? and setting = ? and device = ? limit 1', '__president', 'vault', $device);
	my $row = $q ? $q->hashes->[0] : undef;
	return if $row && !$force;
	my $sealed = &note_encrypter(&house_key(), $suds);
	return unless $sealed;
	my $now = &rightNow();
	if ($row) {
		&db_update('settings', { value => $sealed, server_time => $now }, { uuid => $row->{'uuid'} });
	}
	else {
		&db_insert('settings', { app => '__president', setting => 'vault', device => $device, value => $sealed, timestamp => $now, server_time => $now });
	}
	return 1;
}

sub suds_id {
	my ($suds) = @_;
	return '' unless $suds;
	$suds =~ s/\s+$//;
	return &shorthand_name(md5_sum('suds:' . $suds), 12);
}

sub suds_current {
	my ($suds) = @_;
	return 0 unless $suds;
	my $q = &db_select('security', ['credential'], { level => 1 });
	my $row = $q ? $q->hash : undef;
	my $credential = $row && $row->{'credential'};
	return 0 unless $credential;
	my $check = &subs::decrypter($suds, $credential);
	return 0 unless $check;
	return $check eq $suds ? 1 : 0;
}

sub door_row {
	my $q = &db_select('security', ['uuid','credential'], { level => 'door' });
	return $q ? $q->hash : undef;
}

sub door_check {
	my ($typed) = @_;
	return 0 unless defined $typed && length $typed;
	my $row = &door_row();
	return 0 unless $row && $row->{'credential'};
	my $stored = &decrypter($typed, $row->{'credential'});
	return ($stored && !ref $stored && $stored eq $typed) ? 1 : 0;
}

sub door_set {
	my ($password) = @_;
	return 0 unless defined $password && length $password;
	my $sealed = &encrypter($password, $password);
	return 0 unless $sealed;
	my ($db,$database) = &database_grabber();
	my $now = &rightNow();
	&db_query('delete from security where level = ?', 'door');
	&db_insert('security', {
		level => 'door',
		credential => $sealed,
		database => $database,
		timestamp => $now,
		server_time => $now,
		uuid => &random_string_creator(30)
	});
	return 1;
}

sub login_gate {
	my ($typed) = @_;
	return (0, undef) unless defined $typed && length $typed;
	my @vault = &vault_read();
	my $vault = $vault[0];
	if ($vault && &suds_current($vault)) {
		my $door = &door_row();
		if ($door) {
			return (1, $vault) if &door_check($typed);
			# the typed house key is stronger than any password: let it in and
			# leave the door exactly as it was
			return (&secure_compare($typed, $vault) ? (1, $vault) : (0, $vault));
		}
		if (&secure_compare($typed, $vault)) {
			&door_set($typed);
			return (1, $vault);
		}
		return (0, $vault);
	}
	if (&suds_current($typed)) {
		&vault_seed($typed, 1);
		&door_set($typed) unless &door_row();
		return (1, $typed);
	}
	return (0, undef);
}

sub legacy_suds {
	my $q = &db_query('select secret,password,suds,server_time from tickets where status = ? order by server_time desc limit 1', 'active');
	my $ticket = $q ? $q->hashes->[0] : undef;
	return unless $ticket && $ticket->{'suds'};
	my $secret = $ticket->{'secret'};
	my $ver = url_unescape `echo "$secret" | base64 --decode`;
	my $verification = &note_decrypter($ticket->{'password'}, $ver);
	my $vrai = eval { return decode_json $verification } || {};
	return unless $vrai->{'p'};
	my $suds = &note_decrypter($vrai->{'p'}, $ticket->{'suds'});
	return unless $suds;
	$suds =~ s/\s+$//;
	return ($suds, $ticket->{'server_time'});
}

sub session_suds {
	my ($c) = @_;
	# A bootstrap session is a password login that has not proved a device. It
	# may pair, restore or recover, but it never resolves the data key: the
	# password is a recovery share, not a way to read the house. Internal work
	# (no session) and every proved session still get the key.
	if ($c && ($c->session('bootstrap') || '') eq '1') { return undef; }
	return $gb::suds if $gb::suds;
	return eval { &suds_grabber() };
}

sub vault_pull_one {
	my ($rm, $seal) = @_;
	my $manager = $rm->{'manager'};
	$manager = 'https://' . $rm->{'ip'} . ':' . ($rm->{'port'} || '45545') unless $manager;
	return unless $manager;
	my $ua = Mojo::UserAgent->new();
	$ua->max_response_size(0);
	$ua->insecure(1);
	# every request on the peer rail names this machine and carries a signature
	$ua->on(start => sub { my ($ua, $tx) = @_; &peer_sign_request($tx->req); });
	my $url = $manager . '/manager/vault_share?signatorial=' . &signatorial_designer() . '&seal=' . url_escape($seal);
	my $res = eval { $ua->inactivity_timeout(15)->get($url)->result };
	return unless $res && $res->is_success;
	my $json = eval { decode_json $res->body } || {};
	return unless $json->{'ok'} && $json->{'sealed'};
	my $suds = &note_decrypter($seal, $json->{'sealed'});
	$suds =~ s/\s+$// if $suds;
	return $suds;
}

sub vault_pull_from_peer {
	# once per five minutes per process; a keyless machine calls this on every
	# resolution, so it must not hammer the mesh
	my $opts = shift || {};
	my $now = &rightNow();
	return if $gb::vault_pull_last && $now - $gb::vault_pull_last < 300000;
	$gb::vault_pull_last = $now;
	my ($db) = &database_grabber();
	return unless $db;
	# a driver may name the peers it wants, so a probe never pulls a key from a
	# real machine (or counts a real machine's answer as the fixture's)
	my %only = map { $_ => 1 } @{ (ref $opts->{'only'} eq 'ARRAY') ? $opts->{'only'} : [] };
	my @peers = grep { ($_->{'signatorial'} || '') && ($_->{'manager'} || $_->{'ip'}) }
		grep { !(scalar keys %only) || $only{ $_->{'signatorial'} } }
		@{ &db_select('remote_machines')->hashes || [] };
	my @active = grep { ($_->{'connection'} || '') eq 'active' } @peers;
	my @rest = grep { ($_->{'connection'} || '') ne 'active' } @peers;
	@peers = (@active, @rest);
	splice @peers, 3;
	return unless scalar @peers;
	my $seal = &code_chars_make(40);
	foreach my $rm ( @peers ) {
		my $suds = eval { &vault_pull_one($rm, $seal) };
		return $suds if $suds;
	}
	return;
}

1;
