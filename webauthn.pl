# webauthn.pl - the relying party for passkeys.
#
# Loaded by Manager.pl after subroutines.pl. It owns the two things a WebAuthn
# server must do and nothing else:
#
#   1. verify a registration (attestation) and return the credential's public
#      key, so it can be stored;
#   2. verify an assertion against that stored key.
#
# No attestation trust chain is checked: this is a house, not a bank, and the
# platform authenticator's "none"/"packed" attestation says little a household
# can act on. What matters is that the credential's private key never leaves the
# device and that every assertion is bound to a challenge this server issued and
# to this house's origin.
#
# The RP ID is the house domain (Configure -> Plat -> DNS), so every machine's
# origin - laptop.jonathanferwerda.com, cloud.jonathanferwerda.com - shares one
# set of credentials.

package webauthn;

use strict;
use warnings;
no warnings 'uninitialized';

use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::SHA qw(sha256);
use Crypt::PK::ECC;
use Crypt::PK::Ed25519;
use Mojo::JSON qw(decode_json encode_json);

# ---- base64url --------------------------------------------------------------
sub b64u_encode {
	my $d = shift;
	my $s = encode_base64($d, '');
	$s =~ tr{+/}{-_};
	$s =~ s/=+$//;
	return $s;
}

sub b64u_decode {
	my $s = shift;
	return '' unless defined $s && length $s;
	$s =~ tr{-_}{+/};
	$s .= '=' x ((4 - length($s) % 4) % 4);
	return decode_base64($s);
}

# 32 bytes from the kernel, not Perl's rand (which a forked worker inherits).
sub random_bytes {
	my ($n) = @_;
	$n ||= 32;
	open my $fh, '<', '/dev/urandom' or die "cannot read /dev/urandom: $!\n";
	binmode $fh;
	my $buf = '';
	while (length($buf) < $n) {
		my $got = read($fh, $buf, $n - length($buf), length($buf));
		last unless $got;
	}
	close $fh;
	die "short read from /dev/urandom\n" unless length($buf) == $n;
	return $buf;
}

# ---- the relying party ------------------------------------------------------
sub rp_id {
	my $id = &subs::house_domain();
	$id =~ s/^\s+|\s+$//g;
	return lc $id;
}

# The origin the browser used, which is what the clientData must name.
sub origin_of {
	my ($c) = @_;
	my $url = $c->req->url->base;
	my $scheme = lc($url->scheme || 'https');
	my $host = lc($url->host || '');
	my $port = $url->port;
	my $default = ($scheme eq 'https') ? 443 : 80;
	my $suffix = (defined $port && $port ne '' && $port != $default) ? ':' . $port : '';
	return $scheme . '://' . $host . $suffix;
}

sub origin_ok {
	my ($client_origin, $expected) = @_;
	return 0 unless defined $client_origin && defined $expected;
	my $c = lc $client_origin;
	my $e = lc $expected;
	$c =~ s{/+$}{};
	$e =~ s{/+$}{};
	return 0 unless $c eq $e;
	my ($chost) = $c =~ m{^[a-z]+://([^/:]+)};
	my $rp = &rp_id();
	return 0 unless length $rp;
	return 1 if $chost eq $rp || $chost =~ /\.\Q$rp\E$/;
	return 0;
}

# ---- a minimal CBOR reader --------------------------------------------------
# WebAuthn needs only maps, arrays, strings, byte strings and small integers.
# Indefinite lengths and tags are accepted because an authenticator may use
# them, but nothing here is a general CBOR implementation.
sub cbor_decode {
	my ($buf, $start) = @_;
	my $pos = defined $start ? $start : 0;
	my $val = _cbor_item($buf, \$pos);
	return ($val, $pos);
}

sub _cbor_item {
	my ($buf, $posref) = @_;
	my $p = $$posref;
	die "cbor: short read\n" if $p >= length $buf;
	my $ib = ord(substr($buf, $p, 1));
	$p++;
	my $major = $ib >> 5;
	my $ai = $ib & 0x1f;
	my $n = 0;
	if ($ai < 24) { $n = $ai; }
	elsif ($ai == 24) { $n = ord(substr($buf, $p, 1)); $p += 1; }
	elsif ($ai == 25) { $n = unpack('n', substr($buf, $p, 2)); $p += 2; }
	elsif ($ai == 26) { $n = unpack('N', substr($buf, $p, 4)); $p += 4; }
	elsif ($ai == 27) { my ($hi, $lo) = unpack('NN', substr($buf, $p, 8)); $n = $hi * 4294967296 + $lo; $p += 8; }
	elsif ($ai == 31) { return _cbor_indef($buf, $posref, $major); }
	else { die "cbor: reserved length\n"; }

	if ($major == 0) { $$posref = $p; return $n; }
	if ($major == 1) { $$posref = $p; return -1 - $n; }
	if ($major == 2 || $major == 3) {
		die "cbor: short string\n" if $p + $n > length $buf;
		my $s = substr($buf, $p, $n);
		$$posref = $p + $n;
		return $s;
	}
	if ($major == 4) {
		my @a;
		for (my $i = 0; $i < $n; $i++) { push @a, _cbor_item($buf, \$p); }
		$$posref = $p;
		return \@a;
	}
	if ($major == 5) {
		my %h;
		for (my $i = 0; $i < $n; $i++) {
			my $k = _cbor_item($buf, \$p);
			my $v = _cbor_item($buf, \$p);
			$h{$k} = $v;
		}
		$$posref = $p;
		return \%h;
	}
	if ($major == 6) {
		my $v = _cbor_item($buf, \$p);
		$$posref = $p;
		return $v;
	}
	# major 7: simple values and floats. WebAuthn does not use floats in a COSE
	# key or authData, so their payload is skipped and they read as undef.
	if ($major == 7) {
		$$posref = $p;
		if ($ai == 20) { return 0; }
		if ($ai == 21) { return 1; }
		if ($ai == 22 || $ai == 23) { return undef; }
		if ($ai == 26) { $$posref = $p + 4; }
		if ($ai == 27) { $$posref = $p + 8; }
		return undef;
	}
	die "cbor: unsupported major $major\n";
}

sub _cbor_indef {
	my ($buf, $posref, $major) = @_;
	my $p = $$posref;
	if ($major == 2 || $major == 3) {
		my $out = '';
		while (1) {
			die "cbor: short indef string\n" if $p >= length $buf;
			my $b = ord(substr($buf, $p, 1));
			if ($b == 0xff) { $p++; last; }
			my $chunk = _cbor_item($buf, \$p);
			$out .= $chunk;
		}
		$$posref = $p;
		return $out;
	}
	if ($major == 4) {
		my @a;
		while (1) {
			die "cbor: short indef array\n" if $p >= length $buf;
			my $b = ord(substr($buf, $p, 1));
			if ($b == 0xff) { $p++; last; }
			push @a, _cbor_item($buf, \$p);
		}
		$$posref = $p;
		return \@a;
	}
	if ($major == 5) {
		my %h;
		while (1) {
			die "cbor: short indef map\n" if $p >= length $buf;
			my $b = ord(substr($buf, $p, 1));
			if ($b == 0xff) { $p++; last; }
			my $k = _cbor_item($buf, \$p);
			my $v = _cbor_item($buf, \$p);
			$h{$k} = $v;
		}
		$$posref = $p;
		return \%h;
	}
	die "cbor: unsupported indefinite type\n";
}

# ---- COSE keys --------------------------------------------------------------
# EC2/P-256 and OKP/Ed25519 are the two the platforms offer. RSA (alg -257) is
# deliberately not accepted: nothing in this house needs it, and P-256 is the
# shape the rest of the code already verifies.
sub cose_public_key {
	my ($cose) = @_;
	return undef unless ref $cose eq 'HASH';
	my $kty = $cose->{1};
	my $alg = $cose->{3};
	if (defined $kty && $kty == 2) {
		return undef unless defined $cose->{-1} && $cose->{-1} == 1;    # P-256
		my ($x, $y) = ($cose->{-2}, $cose->{-3});
		return undef unless defined $x && defined $y && length($x) == 32 && length($y) == 32;
		return { alg => -7, x => &b64u_encode($x), y => &b64u_encode($y) };
	}
	if (defined $kty && $kty == 1) {
		return undef unless defined $cose->{-1} && $cose->{-1} == 6;    # Ed25519
		my $x = $cose->{-2};
		return undef unless defined $x && length($x) == 32;
		return { alg => -8, x => &b64u_encode($x) };
	}
	return undef;
}

sub cose_verify {
	my ($key, $sig, $msg) = @_;
	return 0 unless ref $key eq 'HASH' && defined $sig && defined $msg;
	if (($key->{'alg'} // 0) == -7) {
		my $x = &b64u_decode($key->{'x'});
		my $y = &b64u_decode($key->{'y'});
		return 0 unless length($x) == 32 && length($y) == 32;
		# SubjectPublicKeyInfo for an uncompressed P-256 point.
		my $der = pack('H*', '3059301306072a8648ce3d020106082a8648ce3d030107034200') . "\x04" . $x . $y;
		return &subs::ecdsa_verify(encode_base64($der, ''), $msg, encode_base64($sig, ''));
	}
	if (($key->{'alg'} // 0) == -8) {
		my $raw = &b64u_decode($key->{'x'});
		return 0 unless length($raw) == 32;
		my $pk = eval { Crypt::PK::Ed25519->new };
		return 0 unless $pk && eval { $pk->import_key_raw($raw, 'public') };
		my $ok = eval { $pk->verify_message($sig, $msg) };
		return $ok ? 1 : 0;
	}
	return 0;
}

# ---- challenges -------------------------------------------------------------
# A challenge is a row in cache, keyed by its own value and single-use. The
# payload binds it to a purpose, so a login challenge cannot be spent on a
# registration.
sub challenge_put {
	my ($kind, $payload) = @_;
	my $challenge = &b64u_encode(&random_bytes(32));
	my $now = &subs::rightNow();
	&subs::db_query('delete from cache where context like ? and server_time < ?', 'webauthn_%', $now - 300000);
	&subs::db_insert('cache', {
		uuid        => $challenge,
		context     => 'webauthn_' . $kind,
		app         => '__president',
		server_time => $now,
		timestamp   => $now,
		data        => &subs::encode_sereal({ %{$payload || {}}, kind => $kind, at => $now }),
	});
	return $challenge;
}

sub challenge_take {
	my ($kind, $challenge) = @_;
	return undef unless defined $challenge && length $challenge && $challenge =~ /^[A-Za-z0-9_-]{20,128}$/;
	my $row = &subs::db_query('select server_time, data from cache where context = ? and uuid = ? limit 1', 'webauthn_' . $kind, $challenge)->hashes->[0];
	return undef unless $row && $row->{'server_time'} && $row->{'server_time'} > &subs::rightNow() - 300000;
	&subs::db_query('delete from cache where context = ? and uuid = ?', 'webauthn_' . $kind, $challenge);
	my $data = eval { &subs::decode_sereal($row->{'data'}) } || {};
	return $data;
}

# ---- the credential store ---------------------------------------------------
# Credentials are public keys, so they live in a synced setting: every peer can
# verify an assertion without a new table and without a sync registration.
sub credentials {
	my $raw = &subs::setting_grabber({ app => 'webauthn', setting => 'credentials', device => 'all' });
	my $list = eval { decode_json($raw) } || [];
	return [ grep { ref $_ eq 'HASH' } @{$list} ];
}

sub credentials_store {
	my ($list) = @_;
	&subs::setting_setter({ app => 'webauthn', setting => 'credentials', device => 'all', value => encode_json($list) });
}

sub credential_by_id {
	my ($id) = @_;
	return undef unless defined $id && length $id;
	my ($c) = grep { ($_->{'id'} || '') eq $id } @{ &credentials() };
	return $c;
}

# ---- enrollment links --------------------------------------------------------
# A one-time link lets the installed app hand enrollment to a real browser on
# the house name, where WebAuthn can actually run. It carries only the person
# and a five-minute life; it creates no session and is spent by the first
# successful registration.
sub enroll_new {
	my ($payload) = @_;
	my $token = &b64u_encode(&random_bytes(32));
	my $now = &subs::rightNow();
	&subs::db_query('delete from cache where context = ? and server_time < ?', 'webauthn_enroll', $now - 600000);
	&subs::db_insert('cache', {
		uuid        => $token,
		context     => 'webauthn_enroll',
		app         => '__president',
		server_time => $now,
		timestamp   => $now,
		data        => &subs::encode_sereal({ %{$payload || {}}, at => $now }),
	});
	return $token;
}

sub enroll_peek {
	my ($token) = @_;
	return undef unless defined $token && $token =~ /^[A-Za-z0-9_-]{20,128}$/;
	my $row = &subs::db_query('select server_time, data from cache where context = ? and uuid = ? limit 1', 'webauthn_enroll', $token)->hashes->[0];
	return undef unless $row && $row->{'server_time'} && $row->{'server_time'} > &subs::rightNow() - 300000;
	return eval { &subs::decode_sereal($row->{'data'}) } || undef;
}

sub enroll_take {
	my ($token) = @_;
	my $payload = &enroll_peek($token);
	return undef unless $payload;
	&subs::db_query('delete from cache where context = ? and uuid = ?', 'webauthn_enroll', $token);
	return $payload;
}

# ---- verification -----------------------------------------------------------
sub _client_data {
	my ($b64u) = @_;
	my $raw = &b64u_decode($b64u);
	my $cd = eval { decode_json($raw) } || {};
	return ($raw, $cd);
}

sub verify_registration {
	my ($client_data_b64, $attestation_b64, $expected_challenge, $expected_origin) = @_;
	my ($client_raw, $cd) = &_client_data($client_data_b64);
	return (0, 'client data is not readable') unless ref $cd eq 'HASH' && ($cd->{'type'} || '') eq 'webauthn.create';
	return (0, 'the challenge did not come from this house') unless ($cd->{'challenge'} || '') eq $expected_challenge;
	return (0, 'the origin does not match this house') unless &origin_ok($cd->{'origin'}, $expected_origin);
	my $rp = &rp_id();
	return (0, 'set the house domain first') unless length $rp;
	my $att_raw = &b64u_decode($attestation_b64);
	my $att = eval { my ($v) = &cbor_decode($att_raw); $v };
	return (0, 'the attestation is not readable') unless ref $att eq 'HASH' && defined $att->{'authData'};
	my $ad = $att->{'authData'};
	return (0, 'authData is short') unless length($ad) >= 55;
	return (0, 'the credential is for another house') unless substr($ad, 0, 32) eq sha256($rp);
	my $flags = ord(substr($ad, 32, 1));
	return (0, 'the authenticator did not confirm a person') unless $flags & 0x01;
	return (0, 'the registration carries no credential') unless $flags & 0x40;
	my $sign_count = unpack('N', substr($ad, 33, 4));
	my $aaguid = unpack('H*', substr($ad, 37, 16));
	my $idlen = unpack('n', substr($ad, 53, 2));
	return (0, 'the credential id is missing') unless $idlen > 0 && length($ad) >= 55 + $idlen;
	my $cred_id = substr($ad, 55, $idlen);
	my $cose = eval { my ($v) = &cbor_decode($ad, 55 + $idlen); $v };
	my $key = &cose_public_key($cose);
	return (0, 'the credential key is not P-256 or Ed25519') unless $key;
	return ({
		ok          => 1,
		id          => &b64u_encode($cred_id),
		key         => $key,
		sign_count  => $sign_count,
		aaguid      => $aaguid,
		uv          => ($flags & 0x04) ? 1 : 0,
		user_id     => $cd->{'userVerification'} ? 1 : 0,
	}, '');
}

sub verify_assertion {
	my ($cred, $client_data_b64, $auth_data_b64, $signature_b64, $expected_challenge, $expected_origin) = @_;
	return (0, 'no such credential') unless ref $cred eq 'HASH' && ref $cred->{'key'} eq 'HASH';
	my ($client_raw, $cd) = &_client_data($client_data_b64);
	return (0, 'client data is not readable') unless ref $cd eq 'HASH' && ($cd->{'type'} || '') eq 'webauthn.get';
	return (0, 'the challenge did not come from this house') unless ($cd->{'challenge'} || '') eq $expected_challenge;
	return (0, 'the origin does not match this house') unless &origin_ok($cd->{'origin'}, $expected_origin);
	my $rp = &rp_id();
	return (0, 'set the house domain first') unless length $rp;
	my $ad = &b64u_decode($auth_data_b64);
	return (0, 'authData is short') unless length($ad) >= 37;
	return (0, 'the credential is for another house') unless substr($ad, 0, 32) eq sha256($rp);
	my $flags = ord(substr($ad, 32, 1));
	return (0, 'the authenticator did not confirm a person') unless $flags & 0x01;
	my $count = unpack('N', substr($ad, 33, 4));
	my $sig = &b64u_decode($signature_b64);
	return (0, 'the signature is missing') unless length $sig;
	# The signed bytes are authData followed by SHA-256(clientDataJSON).
	my $signed = $ad . sha256($client_raw);
	return (0, 'the assertion did not verify') unless &cose_verify($cred->{'key'}, $sig, $signed);
	my $stored = $cred->{'sign_count'} || 0;
	my $clone = ($count > 0 && $stored > 0 && $count <= $stored) ? 1 : 0;
	return ({
		ok         => 1,
		sign_count => $count,
		clone      => $clone,
		uv         => ($flags & 0x04) ? 1 : 0,
	}, '');
}

# A stable, opaque user handle for the authenticator: the person's uuid bytes.
sub user_handle {
	my ($person_uuid) = @_;
	my $id = defined $person_uuid && length $person_uuid ? $person_uuid : 'owner';
	return &b64u_encode($id);
}

1;
