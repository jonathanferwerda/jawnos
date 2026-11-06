package subs;

# Crypt: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Crypt::Simple;
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
use Scalar::Util qw(reftype);
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our %H;
our $config;
our $database;
our $device;
our $gb;
our %m;

# --- rotation -----------------------------------------------------------------
# Replace the house key with a fresh random one. Everything the database seals is
# re-sealed in place: the vault, the level-1 canary, the security history (earlier
# oldkey wraps included), note-shaped and binary-shaped settings values, and the
# neighbour-link credentials. The old key is wrapped under the new one as an
# 'oldkey' security row, which the file and note paths consult when deriving
# candidate secrets - so content sealed before the rotation still opens. The
# recovery code sealed the old key and is set aside (recovery_stale). Sessions do
# not survive: every suds_id changes, so browsers re-admit themselves through
# their device keys. $target lets a caller supply the key instead of generating
# one: probes rotate back with it, and /manager/key_push adopts a peer's new
# key with it; the local rotation route never passes it.
# One stored value, re-sealed from one house key to another. Returns undef when
# the value is sealed with neither the current key nor the legacy empty
# passphrase; the new sealed value otherwise. The unwrap is exact - Crypt::Simple
# checks its own digest and refuses a key that did not seal the value - so a
# value's bytes are proven, not guessed (its output is base64, so a shape test
# would say nothing). A note carries ':::---:::' inside that outer layer, and its
# own openssl layer is keyed to the real secret: it is remade whole, since
# re-wrapping only the outer layer would not open later. Values from the era when
# encrypter sealed under the empty passphrase are upgraded too - that key is
# public knowledge, so leaving them is leaving them readable to anyone holding a
# copy of the database.
sub crypt_simple_unwrap {
	my ($secret, $v) = @_;
	local *encrypt;
	local *decrypt;
	Crypt::Simple->import(passphrase => $secret);
	my $plain = eval { decrypt($v) };
	return $plain;
}

sub rotation_reseal_value {
	my ($v, $K, $Knew) = @_;
	return unless defined $v && length $v && $K && $Knew;
	my $inner = &crypt_simple_unwrap($K, $v);
	$inner = &crypt_simple_unwrap('', $v) unless defined $inner;
	return unless defined $inner;
	return &reseal_unwrapped_value($inner, $v, $K, $Knew);
}

# The half both re-seal sweeps share: the outer layer is already unwrapped, so
# this decides note or plain blob and hands back the value sealed under $Knew.
# A note carries ':::---:::' inside that outer layer, and its own openssl layer
# is keyed to the real secret ($K reaches a legacy note's inner layer through
# note_decrypter's own fallback), so it is remade whole - re-wrapping only the
# outer layer would not open later.
sub reseal_unwrapped_value {
	my ($inner, $v, $K, $Knew) = @_;
	if (index($inner, ':::---:::') >= 0) {
		my $plain = &note_decrypter($K, $v);
		return unless defined $plain && length $plain;
		my $re = &note_encrypter($Knew, $plain);
		return unless $re && &note_decrypter($Knew, $re) eq $plain;
		return $re;
	}
	my $re = &encrypter($Knew, $inner);
	return unless $re && &decrypter($Knew, $re) eq $inner;
	return $re;
}

# The standalone form of the rotation's legacy side effect: re-seal one value
# still locked by the empty-passphrase era and leave everything else exactly
# alone (a value already under $K reports back as undefined, so nothing is ever
# rewritten for nothing).
sub legacy_reseal_value {
	my ($v, $K) = @_;
	return unless defined $v && length $v && $K;
	return if defined &crypt_simple_unwrap($K, $v);
	my $inner = &crypt_simple_unwrap('', $v);
	return unless defined $inner;
	return &reseal_unwrapped_value($inner, $v, $K, $K);
}

sub rotate_house_key {
	my ($target) = @_;
	my $K = &suds_grabber();
	return { ok => 0, error => 'no key on this machine' } unless $K;
	my $Knew = $target || &code_chars_make(40);
	return { ok => 0, error => 'the new key is the old key' } if $Knew eq $K;
	my $canary = &encrypter($Knew, $Knew);
	my $wrapped = &encrypter($Knew, $K);
	my $sealed = &note_encrypter(&house_key(), $Knew);
	return { ok => 0, error => 'the new key would not seal' } unless $canary && $wrapped && $sealed;
	my ($db,$database) = &database_grabber();
	return { ok => 0, error => 'no database' } unless $db;
	my $now = &rightNow();
	my $counts = { settings => 0, security => 0, links => 0 };

	# The key material moves first, and remote_duty with it: every worker
	# re-resolves on its next settings write, so a write during the sweep below
	# seals under the new key instead of landing in the old one. The old key is
	# wrapped under the new one before anything is swept, so even a sweep cut
	# short leaves every pre-rotation value one way or another reachable.
	&vault_seed($Knew, 1);
	&db_query('update security set credential = ? where level = 1', $canary);
	&db_insert('security', { level => 'oldkey', credential => $wrapped, database => $database, timestamp => $now, server_time => $now });
	$gb::suds = $Knew;
	&setting_setter({ app => '__president', setting => 'remote_duty', value => $now });

	# settings: every value that proves its seal is re-sealed (see
	# rotation_reseal_value); a handful of API keys and blobs usually pass, but
	# the sweep must find them all
	my $settings = &db_select('settings', ['rowid','setting','value'], {})->hashes;
	foreach my $row ( @{$settings} ) {
		my $re = &rotation_reseal_value($row->{'value'}, $K, $Knew);
		next unless defined $re;
		&db_update('settings', { value => $re }, { rowid => $row->{'rowid'} });
		$counts->{settings}++;
	}

	# security: apart from the canary and the door, every credential that
	# proves its seal is re-sealed; the history keeps each layer one decrypt
	# away from the live key. Padlock and door hold no key material.
	my $secs = &db_select('security', ['rowid','level','credential'], {})->hashes;
	foreach my $row ( @{$secs} ) {
		next if $row->{'level'} eq 'padlock' || $row->{'level'} eq 'door' || $row->{'level'} eq '1';
		my $re = &rotation_reseal_value($row->{'credential'}, $K, $Knew);
		next unless defined $re;
		&db_update('security', { credential => $re }, { rowid => $row->{'rowid'} });
		$counts->{security}++;
	}

	# neighbour-link credentials (the mesh's stored secrets)
	my $links = &db_select('neighbour_link', ['rowid','credential'], {})->hashes;
	foreach my $row ( @{$links} ) {
		my $re = &rotation_reseal_value($row->{'credential'}, $K, $Knew);
		next unless defined $re;
		&db_update('neighbour_link', { credential => $re }, { rowid => $row->{'rowid'} });
		$counts->{links}++;
	}

	# the recovery code sealed the old key; it is set aside with the note to
	# write down a new one
	my $recovery = &db_select('settings', ['rowid'], { app => '__president', setting => 'recovery' })->hashes;
	if (scalar @{$recovery}) {
		&db_delete('settings', { app => '__president', setting => 'recovery' });
		&db_delete('settings', { app => '__president', setting => 'recovery_stale' });
		&db_insert('settings', { app => '__president', setting => 'recovery_stale', device => 'all', value => 'key_rotation', timestamp => $now, server_time => $now });
	}
	# every wrapped share opens the old key; a copy of the database must not keep
	# one that still names it. Paper shares are not here to clear.
	&house_key_share_clear();
	return { ok => 1, at => $now, key_id => &suds_id($Knew), old_key_id => &suds_id($K), settings => $counts->{settings}, security => $counts->{security}, links => $counts->{links} };
}

# --- legacy seals -------------------------------------------------------------
# A sweep for values left from the era when encrypter sealed the outer layer
# under the empty passphrase (md5(''), public knowledge): out in the open to
# anyone holding a copy of the database. Unlike rotation this changes no key -
# each value is upgraded to the key this machine already holds - so it is safe
# on any machine at any time, idempotent, and cheap where none are left. The
# mesh form asks every linked machine to run its own, over the signed peer
# rail: nothing secret crosses, only signatures.
sub legacy_reseal {
	my $K = &suds_grabber();
	return { ok => 0, error => 'no key on this machine' } unless $K;
	my $counts = { settings => 0, security => 0, links => 0 };
	my $settings = &db_select('settings', ['rowid','setting','value'], {})->hashes;
	foreach my $row ( @{$settings} ) {
		my $re = &legacy_reseal_value($row->{'value'}, $K);
		next unless defined $re;
		&db_update('settings', { value => $re }, { rowid => $row->{'rowid'} });
		$counts->{settings}++;
	}
	# padlock and door hold no key material (upgrading the door would break it:
	# it must keep opening with the typed password alone); level 1 is the canary,
	# which has its own reseal - the same filter rotation uses
	my $secs = &db_select('security', ['rowid','level','credential'], {})->hashes;
	foreach my $row ( @{$secs} ) {
		next if $row->{'level'} eq 'padlock' || $row->{'level'} eq 'door' || $row->{'level'} eq '1';
		my $re = &legacy_reseal_value($row->{'credential'}, $K);
		next unless defined $re;
		&db_update('security', { credential => $re }, { rowid => $row->{'rowid'} });
		$counts->{security}++;
	}
	my $links = &db_select('neighbour_link', ['rowid','credential'], {})->hashes;
	foreach my $row ( @{$links} ) {
		my $re = &legacy_reseal_value($row->{'credential'}, $K);
		next unless defined $re;
		&db_update('neighbour_link', { credential => $re }, { rowid => $row->{'rowid'} });
		$counts->{links}++;
	}
	return { ok => 1, settings => $counts->{settings}, security => $counts->{security}, links => $counts->{links} };
}

# Ask one linked machine to upgrade its own legacy values (its route runs the
# same local sweep) and hand back the counts. A machine that has not caught up
# with this code yet simply fails to answer.
sub legacy_reseal_peer_one {
	my ($rm) = @_;
	return unless $rm && $rm->{'signatorial'};
	my $manager = $rm->{'manager'};
	$manager = 'https://' . $rm->{'ip'} . ':' . ($rm->{'port'} || '45545') unless $manager;
	return unless $manager;
	my ($secure_manager, $verified) = &subs::peer_secure_url($rm, $manager);
	$manager = $secure_manager if $verified;
	my $ua = Mojo::UserAgent->new();
	$ua->max_response_size(0);
	if ($verified) { &subs::peer_tls_verify($ua) } else { $ua->insecure(1) }
	$ua->on(start => sub { my ($ua, $tx) = @_; &peer_sign_request($tx->req); });
	my $url = $manager . '/manager/legacy_reseal?signatorial=' . &signatorial_designer();
	my $res = eval { $ua->inactivity_timeout(15)->get($url)->result };
	return unless $res && $res->is_success;
	my $json = eval { decode_json $res->body };
	return unless $json && $json->{'ok'};
	return $json;
}

sub legacy_reseal_mesh {
	my $me = &signatorial_designer();
	my $rms = &db_select('remote_machines')->hashes || [];
	my $summary = { asked => 0, ok => 0, failed => 0, upgraded => 0 };
	foreach my $rm ( @{$rms} ) {
		my $rsig = $rm->{'signatorial'};
		next unless $rsig && $rsig ne $me;
		next unless $rm->{'manager'} || $rm->{'ip'};
		$summary->{asked}++;
		my $got = eval { &legacy_reseal_peer_one($rm) };
		if ($got) {
			$summary->{ok}++;
			$summary->{upgraded} += ($got->{'settings'} || 0) + ($got->{'security'} || 0) + ($got->{'links'} || 0);
		}
		else { $summary->{failed}++; }
	}
	return $summary;
}

sub suds_grabber {
	my $duty_time = &subs::setting_grabber({ app => '__president', setting => 'remote_duty' });
	if (( !$gb::suds || $duty_time eq '' || !$duty_time || $duty_time != $gb::duty_time || !$gb::duty_time)) {
		my ($vault) = &vault_read();
		my ($legacy) = &legacy_suds();
		my $suds;
		if ($vault && &suds_current($vault)) {
			# the steady state: this machine's vault holds the current key
			$suds = $vault;
		}
		elsif ($legacy && &suds_current($legacy)) {
			# the first boot, or a key change made elsewhere: a ticket minted
			# under the current password wins and the vault is resealed to it
			$suds = $legacy;
			&vault_seed($suds, 1);
		}
		else {
			# A live image writes its unlock code beside the house on first
			# boot. The live-local session never passes through login_gate, so
			# this file is the only thing that can seed the vault there; the
			# canary judges it, and a stale or wrong file falls through.
			my $local = &local_code_suds();
			if ($local) {
				$suds = $local;
				&vault_seed($suds, 1);
			}
			else {
				# nothing local validates: a linked machine can hand the key over
				# (sealed to a one-time secret, over the signed peer rail)
				my $pulled = eval { &vault_pull_from_peer() };
				if ($pulled && &suds_current($pulled)) {
					$suds = $pulled;
					&vault_seed($suds, 1);
				}
				elsif ($vault || $legacy) {
					# no canary to judge by: keep the best thing this machine has
					$suds = $vault || $legacy;
					&vault_seed($suds, 1) unless $vault;
				}
			}
		}
		if ($suds) {
			&subs::setting_setter({ app => '__president', setting => 'remote_duty', value => $gb::duty_time });
			$gb::suds = $suds;
			return $suds;
		}
		return $gb::suds;
	}
	return $gb::suds;
}

# --- peer keys ---------------------------------------------------------------
# Every machine gets an Ed25519 keypair at first use (~/.peer.key, 0600, never
# in the database or a code sync). Requests between machines carry a timestamp,
# a nonce and a signature over method and path; once a peer's key is on file an
# unsigned request is refused, so a leaked address, cookie or signatorial is no
# longer enough to pull a backup or push code. The first verified contact pins
# the offered key to the peer's row (trust on first use).
sub peer_key_paths {
	my $key = &home('~/.peer.key');
	my $pub = &home('~/.peer.pub');
	unless (-e $key && -s $key > 0) {
		`openssl genpkey -algorithm ED25519 -out "$key" 2>/dev/null`;
		chmod 0600, $key;
	}
	unless (-e $pub && -s $pub > 0) {
		`openssl pkey -in "$key" -pubout -out "$pub" 2>/dev/null`;
	}
	return ($key, $pub);
}

sub peer_pubkey {
	my ($key, $pub) = &peer_key_paths();
	return unless -e $pub;
	return read_file($pub);
}

sub peer_sign_message {
	my ($method, $path_query, $ts, $nonce) = @_;
	return join "\n", ($method // ''), ($path_query // ''), ($ts // ''), ($nonce // '');
}

# Name this machine and sign the request it is about to make. Attached to a
# peer user agent's start event, so every request on that rail is signed.
# The signing dance writes throwaway files (a message, a signature, a public
# key). They live in the app's own state dir on fresh File::Temp names, not on
# /tmp under a pseudo-random name: a phone without shred leaves /tmp names
# behind, and a leftover file the process cannot truncate turned every signed
# request into a 500 (Fe, found over the mesh), while a world-writable /tmp
# also lets a local name be pre-made as a symlink to clobber.
sub peer_temp_file {
	my ($tag) = @_;
	my $dir = &home('~/.president');
	unless (-d $dir) {
		eval { File::Path::make_path($dir) };
	}
	$dir = '/tmp' unless -d $dir;
	require File::Temp;
	my ($fh, $path) = File::Temp::tempfile('peer_' . ($tag || 'tmp') . '_XXXXXXXX', DIR => $dir, UNLINK => 0);
	close $fh if $fh;
	return $path;
}

sub peer_sign_request {
	my ($req) = @_;
	my ($key) = &peer_key_paths();
	return unless -e $key && -s $key > 0;
	# Time::HiRes overrides time() here, so whole seconds must be asked for:
	# the verifier reads the header back with /^\d+$/ and a fractional stamp
	# (1791953166.531) was refused on every hook-signed request.
	my $ts = int(time());
	my $nonce = &random_string_creator(24);
	my $msg_file = &peer_temp_file('sign_msg');
	my $sig_file = &peer_temp_file('sign_sig');
	write_file($msg_file, &peer_sign_message($req->method, $req->url->path_query, $ts, $nonce));
	`openssl pkeyutl -sign -inkey "$key" -rawin -in "$msg_file" -out "$sig_file" 2>/dev/null`;
	my $sig = (-s $sig_file) ? read_file($sig_file) : '';
	my $pub = &peer_pubkey();
	if ($sig && $pub) {
		$req->headers->header('X-Peer-Timestamp', $ts);
		$req->headers->header('X-Peer-Nonce', $nonce);
		$req->headers->header('X-Peer-Signature', encode_base64($sig, ''));
		$req->headers->header('X-Peer-Key', encode_base64($pub, ''));
	}
	unlink $msg_file, $sig_file;
	return 1;
}

# Sign an arbitrary blob with this machine's peer key. The LAN presence beacon
# uses it: a datagram cannot carry HTTP headers, and an unsigned discovery could
# redirect a known peer's address.
sub peer_sign_blob {
	my ($msg) = @_;
	my ($key) = &peer_key_paths();
	return '' unless -e $key && -s $key > 0;
	my $msg_file = &peer_temp_file('blob_msg');
	my $sig_file = &peer_temp_file('blob_sig');
	write_file($msg_file, $msg);
	`openssl pkeyutl -sign -inkey "$key" -rawin -in "$msg_file" -out "$sig_file" 2>/dev/null`;
	my $sig = (-s $sig_file) ? read_file($sig_file) : '';
	unlink $msg_file, $sig_file;
	return $sig ? encode_base64($sig, '') : '';
}

# The server half: is this request really from the peer it claims, and has it
# not been seen before? Unsigned requests pass only while the peer has no key on
# file yet, so machines upgrade without a flag day; once pinned, only a fresh
# valid signature from the holder of the private key gets through.
sub peer_verify {
	my ($c, $rm) = @_;
	return 0 unless $rm && $rm->{'signatorial'};
	# The app gate can verify the caller before the route does. Its success has
	# already spent the nonce, so a second call for the same row answers from
	# that result instead of refusing a request the house just accepted.
	my $verified = $c->stash('peer_verified_key');
	my $row_key = $rm->{'uuid'} || $rm->{'signatorial'};
	return 1 if $verified && $row_key && $verified eq $row_key;
	my $stored = $rm->{'pubkey'} // '';
	my $ts = $c->req->headers->header('X-Peer-Timestamp');
	my $nonce = $c->req->headers->header('X-Peer-Nonce');
	my $b64sig = $c->req->headers->header('X-Peer-Signature');
	my $b64key = $c->req->headers->header('X-Peer-Key');
	# A signature is mandatory. A first contact may offer its own key in
	# X-Peer-Key (pinned below on success), so a keyless row can still enrol,
	# but an unsigned request is never proof of anything.
	return 0 unless $ts && $nonce && $b64sig;
	return 0 unless $ts =~ /^\d+$/ && abs(time() - $ts) <= 600;
	return 0 unless $nonce && $nonce =~ /^[A-Za-z0-9]{8,64}$/;
	my $pubkey = $stored;
	$pubkey = eval { decode_base64 $b64key } if (!$pubkey && $b64key);
	return 0 unless $pubkey && index($pubkey, '-----BEGIN PUBLIC KEY-----') == 0;
	my $sig = eval { decode_base64 $b64sig } || '';
	return 0 unless length $sig;
	my $stamp = $rm->{'signatorial'} . ':' . $nonce;
	my $q = &db_query('select server_time from cache where context = ? and uuid = ? limit 1', 'peer_nonce', $stamp);
	my $seen = $q ? $q->hashes->[0] : undef;
	return 0 if $seen && $seen->{'server_time'};
	my $msg_file = &peer_temp_file('verify_msg');
	my $sig_file = &peer_temp_file('verify_sig');
	my $key_file = &peer_temp_file('verify_pub');
	write_file($msg_file, &peer_sign_message($c->req->method, $c->req->url->path_query, $ts, $nonce));
	write_file($sig_file, $sig);
	write_file($key_file, $pubkey);
	my $ok = system("openssl pkeyutl -verify -pubin -inkey \"$key_file\" -rawin -in \"$msg_file\" -sigfile \"$sig_file\" >/dev/null 2>&1") == 0;
	unlink $msg_file, $sig_file, $key_file;
	return 0 unless $ok;
	# the nonce is spent; the first verified contact pins the offered key
	&db_query('delete from cache where context = ? and uuid = ?', 'peer_nonce', $stamp);
	&db_query('insert into cache (uuid, context, app, server_time, timestamp) values (?,?,?,?,?)', $stamp, 'peer_nonce', '__president', &rightNow(), &rightNow());
	unless ($stored) {
		&db_update('remote_machines', { pubkey => $pubkey }, { uuid => $rm->{'uuid'} });
	}
	$c->stash('peer_verified_key' => $row_key) if $row_key;
	return 1;
}

# Find the row a caller names, whether it is a direct roster row or a machine a
# trusted peer's hub listed in its `mirrors` blob. A machine that is not the hub
# only learns the other peers that way (the Laptop is a mirror on Dev, not a
# direct row), and the hub hands the list over the signed peer rail, so a
# signature from the key it published proves the same caller a direct row would.
# A mirror without a key is not proof and is refused: peer_verify's unsigned
# first contact is for a direct row we chose to enrol, not for a name we only
# heard about. A direct row wins, but takes a missing key from the hub's copy.
sub peer_roster_row_in {
	my ($signatorial, $rows) = @_;
	return undef unless defined $signatorial && length $signatorial;
	$rows = [] unless ref($rows) && reftype($rows) eq 'ARRAY';
	my ($direct, @mirrors);
	for my $rm ( @{$rows} ) {
		next unless ref $rm eq 'HASH';
		$direct = $rm if ($rm->{'signatorial'} || '') eq $signatorial;
		next unless $rm->{'mirrors'};
		my $list = eval { decode_json $rm->{'mirrors'} } || [];
		next unless ref $list eq 'ARRAY';
		for my $mirror ( @{$list} ) {
			next unless ref $mirror eq 'HASH';
			push @mirrors, $mirror if ($mirror->{'signatorial'} || '') eq $signatorial;
		}
	}
	if ($direct) {
		# A restore or an older sync can leave the row without its key; the hub's
		# copy still carries it, and the signature is what decides anyway.
		if (!length($direct->{'pubkey'} || '')) {
			for my $mirror (@mirrors) {
				next unless length($mirror->{'pubkey'} || '');
				$direct->{'pubkey'} = $mirror->{'pubkey'};
				last;
			}
		}
		return $direct;
	}
	for my $mirror (@mirrors) {
		return $mirror if length($mirror->{'pubkey'} || '');
	}
	return undef;
}

sub peer_roster_row {
	my ($signatorial) = @_;
	return undef unless defined $signatorial && length $signatorial;
	my $rows = eval { &db_select('remote_machines')->hashes } || [];
	return &peer_roster_row_in($signatorial, $rows);
}

# A login must prove the name it claims. peer_verify's unsigned path exists for
# a keyless row's first contact; a session that names a machine already on the
# roster is never allowed to use it.
sub peer_verify_strict {
	my ($c, $rm) = @_;
	return 0 unless $c && $rm;
	return 0 unless $c->req->headers->header('X-Peer-Signature');
	return &peer_verify($c, $rm) ? 1 : 0;
}

# --- the house crest (People) ------------------------------------------------
# A crest is the house's face: one hand-drawn picture that people recognise. The
# picture is not the proof. A house key signs a record that names the drawing's
# hashes, and the short fingerprint on that record is what another house compares.
# Everything here is pure or settings-backed; nothing writes the live roster.
sub crest_canonical_json {
	my ($record) = @_;
	return undef unless ref $record eq 'HASH';
	my $copy = { %$record };
	delete $copy->{'sig'};
	return JSON::PP->new->canonical(1)->encode($copy);
}

sub crest_fingerprint {
	my ($pub) = @_;
	return undef unless defined $pub && length $pub;
	my $hex = uc(&sha256_hex($pub));
	$hex =~ s/(.{4})(?=.)/$1 /g;
	return $hex;
}

sub crest_key_generate {
	require Crypt::PK::Ed25519;
	my $key = Crypt::PK::Ed25519->new->generate_key;
	return ($key->export_key_raw('public'), $key->export_key_raw('private'));
}

sub crest_public_from_private {
	my ($priv) = @_;
	return undef unless defined $priv && length $priv == 32;
	require Crypt::PK::Ed25519;
	my $key = Crypt::PK::Ed25519->new;
	$key->import_key_raw($priv, 'private');
	return $key->export_key_raw('public');
}

sub crest_sign_record {
	my ($record, $priv) = @_;
	return undef unless ref $record eq 'HASH' && defined $priv && length $priv == 32;
	my $json = &crest_canonical_json($record);
	return undef unless defined $json;
	require Crypt::PK::Ed25519;
	my $key = Crypt::PK::Ed25519->new;
	$key->import_key_raw($priv, 'private');
	my $sig = $key->sign_message($json);
	return undef unless defined $sig && length $sig == 64;
	return { %$record, sig => encode_base64($sig, '') };
}

sub crest_verify_record {
	my ($record) = @_;
	return 0 unless ref $record eq 'HASH';
	my $pub = eval { decode_base64($record->{'pubkey'} || '') };
	my $sig = eval { decode_base64($record->{'sig'} || '') };
	return 0 unless defined $pub && length $pub == 32 && defined $sig && length $sig == 64;
	my $json = &crest_canonical_json($record);
	return 0 unless defined $json;
	require Crypt::PK::Ed25519;
	my $key = Crypt::PK::Ed25519->new;
	$key->import_key_raw($pub, 'public');
	return $key->verify_message($sig, $json) ? 1 : 0;
}

sub crest_record_read {
	my $raw = &setting_grabber({ app => '__president', setting => 'crest', device => 'all' });
	return {} unless defined $raw && length $raw;
	my $record = eval { decode_json($raw) };
	return ref $record eq 'HASH' ? $record : {};
}

sub crest_record_write {
	my ($record) = @_;
	return 0 unless ref $record eq 'HASH';
	&setting_setter({ app => '__president', setting => 'crest', device => 'all', value => encode_json($record) });
	return 1;
}

sub crest_key_read {
	my ($suds) = @_;
	return undef unless defined $suds && length $suds;
	my $sealed = &setting_grabber({ app => '__president', setting => 'crest_key', device => 'all' });
	return undef unless defined $sealed && length $sealed;
	my $plain = &note_decrypter($suds, $sealed);
	return undef unless defined $plain && length $plain;
	my $raw = eval { decode_base64($plain) };
	return (defined $raw && length $raw == 32) ? $raw : undef;
}

sub crest_key_write {
	my ($suds, $priv) = @_;
	return 0 unless defined $suds && length $suds && defined $priv && length $priv == 32;
	my $sealed = &note_encrypter($suds, encode_base64($priv, ''));
	return 0 unless defined $sealed && length $sealed;
	&setting_setter({ app => '__president', setting => 'crest_key', device => 'all', value => $sealed });
	return 1;
}

sub crest_house_name_read {
	my $name = &setting_grabber({ app => '__president', setting => 'house_name', device => 'all' });
	$name = &setting_grabber({ app => 'me', setting => 'my_name' }) unless defined $name && length $name;
	$name = &machine_name() unless defined $name && length $name;
	return (defined $name && length $name) ? $name : 'Home';
}

# The address another house reaches this one at. A configured domain that is
# not loopback wins, since it survives the machine moving between networks;
# otherwise the machine's private LAN address on the manager's working port.
# Empty when it has neither: a crest met in person still identifies a house that
# cannot be called, it just cannot be looked up until its address is known.
sub crest_origin {
	my $config = eval { &config_reader() } || {};
	my $host = $config->{'domain'} || '';
	$host =~ s/^\s+|\s+$//g;
	$host = '' if $host =~ /^(?:127\.|0\.0\.0\.0$|localhost$)/i;
	unless (length $host) {
		foreach my $nic ( @{ &lan_presence_network() || [] } ) {
			next unless ($nic->{'ip'} // '') =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
			$host = $nic->{'ip'};
			last;
		}
	}
	return '' unless length $host;
	my $port = $config->{'working_port'} || $config->{'port'} || 45545;
	return "https://$host:$port";
}

# Where a peer crest says its house can be reached. New codes carry the origin
# in the signed record; a card from before that names the manager endpoint, and
# the origin is that endpoint without /manager.
sub crest_entry_origin {
	my ($entry) = @_;
	return '' unless ref $entry eq 'HASH';
	my $crest = ref $entry->{'crest'} eq 'HASH' ? $entry->{'crest'} : {};
	my $origin = $crest->{'origin'} || '';
	unless (length $origin) {
		my $manager = $entry->{'endpoints'}->{'manager'} || '';
		$origin = $1 if $manager =~ m{^(https?://[^/]+)};
	}
	$origin =~ s{/+$}{};
	return '' unless $origin =~ m{^https?://[A-Za-z0-9.:\[\]-]+$};
	return $origin;
}

# A member machine backs the house crest with its peer key. The house key signs
# the crest itself; a cosignature is the same crest named by a machine, signed
# by the key the rest of the house already pins to it. It is identity only -
# uuid, house key and fingerprint - so a re-scan (a new dhash or version) does
# not require every machine to sign again.
sub crest_member_cosig_statement {
	my ($crest) = @_;
	return undef unless ref $crest eq 'HASH'
		&& length($crest->{'uuid'} || '') && length($crest->{'pubkey'} || '');
	return {
		format => 'jawnos-crest-cosig',
		cosign_version => 1,
		crest_uuid => $crest->{'uuid'},
		crest_pubkey => $crest->{'pubkey'},
		fingerprint => $crest->{'fingerprint'} || '',
		dhash => $crest->{'dhash'} || '',
		signatorial => &signatorial_designer(),
		# The crest's own update time, not the moment of signing: the statement is
		# then the same on every pass, so re-posting it changes no row.
		at => $crest->{'server_time'} || $crest->{'issued'} || &rightNow(),
	};
}

sub crest_member_cosign {
	my ($crest) = @_;
	my $statement = &crest_member_cosig_statement($crest);
	return undef unless $statement;
	my $pub = &peer_pubkey();
	return undef unless $pub && index($pub, '-----BEGIN PUBLIC KEY-----') == 0;
	# The key is part of the signed statement: a verifier rebuilds the JSON from
	# the record it was handed, so every field it checks must have been signed.
	$statement->{'pubkey'} = $pub;
	my $json = JSON::PP->new->canonical(1)->encode($statement);
	my $sig = &peer_sign_blob($json);
	return undef unless length $sig;
	return { %$statement, sig => $sig };
}

sub crest_member_cosig_verify {
	my ($cosig, $pubkey) = @_;
	return 0 unless ref $cosig eq 'HASH';
	return 0 unless ($cosig->{'format'} || '') eq 'jawnos-crest-cosig';
	my $pub = $pubkey || $cosig->{'pubkey'} || '';
	return 0 unless $pub && index($pub, '-----BEGIN PUBLIC KEY-----') == 0;
	my $sig = $cosig->{'sig'} || '';
	return 0 unless length $sig;
	my $copy = { %$cosig };
	delete $copy->{'sig'};
	my $json = JSON::PP->new->canonical(1)->encode($copy);
	return &signature_verify($pub, $json, $sig) ? 1 : 0;
}

sub crest_member_cosig_matches {
	my ($cosig, $crest) = @_;
	return 0 unless ref $cosig eq 'HASH' && ref $crest eq 'HASH';
	return 0 unless ($cosig->{'crest_uuid'} || '') eq ($crest->{'uuid'} || '');
	return 0 unless ($cosig->{'crest_pubkey'} || '') eq ($crest->{'pubkey'} || '');
	my $fingerprint = $crest->{'fingerprint'} || '';
	return 0 if length $fingerprint && ($cosig->{'fingerprint'} || '') ne $fingerprint;
	return 1;
}

# The cosignatures this house can check: a roster row that names the crest, with
# its signature verified against the key pinned on that row. The local machine
# is not in its own roster, so include_local adds a fresh signature of its own.
sub crest_member_cosig_list {
	my ($crest, $opts) = @_;
	$opts ||= {};
	return [] unless ref $crest eq 'HASH' && length($crest->{'uuid'} || '');
	my @out;
	my %seen;
	foreach my $rm ( @{ &db_select('remote_machines')->hashes || [] } ) {
		next unless ($rm->{'crest_uuid'} || '') eq $crest->{'uuid'};
		my $cosig = eval { decode_json($rm->{'crest_cosig'} || '') };
		next unless ref $cosig eq 'HASH';
		next unless &crest_member_cosig_matches($cosig, $crest);
		next unless &crest_member_cosig_verify($cosig, $rm->{'pubkey'});
		next unless ($cosig->{'signatorial'} || '') eq ($rm->{'signatorial'} || '');
		next if $seen{$cosig->{'signatorial'}}++;
		push @out, {
			signatorial => $cosig->{'signatorial'},
			hostname => $rm->{'hostname'} || '',
			at => $cosig->{'at'} || '',
			cosig => $cosig,
		};
	}
	@out = sort { lc($a->{'hostname'} || $a->{'signatorial'}) cmp lc($b->{'hostname'} || $b->{'signatorial'}) } @out;
	if ($opts->{'include_local'}) {
		my $local = &crest_member_cosign($crest);
		unshift @out, {
			signatorial => $local->{'signatorial'},
			hostname => &machine_name(),
			at => $local->{'at'},
			cosig => $local,
		} if $local && !$seen{$local->{'signatorial'}};
	}
	return \@out;
}

# A peer handed this house its cosignature. It must name the crest this house
# holds and verify against the key pinned to that machine; a row with no key
# yet pins the key its signature carries, the same first-contact rule the peer
# rail uses. The statement is kept on the row, so it still verifies after the
# request itself is gone.
sub crest_member_cosig_accept {
	my ($rm, $crest, $cosig) = @_;
	return { ok => 0, error => 'no such machine' } unless ref $rm eq 'HASH' && ($rm->{'uuid'} || '');
	return { ok => 0, error => 'this house holds no crest' } unless ref $crest eq 'HASH' && ($crest->{'uuid'} || '');
	return { ok => 0, error => 'not a crest cosignature' } unless &crest_member_cosig_verify($cosig, $rm->{'pubkey'});
	return { ok => 0, error => 'the cosignature names another crest' } unless &crest_member_cosig_matches($cosig, $crest);
	my $signatorial = $cosig->{'signatorial'} || '';
	return { ok => 0, error => 'the cosignature names another machine' }
		unless length $signatorial && $signatorial eq ($rm->{'signatorial'} || '');
	# A repeated pass re-sends the same statement; keep the row's server_time still.
	my $stored = encode_json($cosig);
	if (($rm->{'crest_uuid'} || '') eq $crest->{'uuid'} && ($rm->{'crest_cosig'} || '') eq $stored) {
		return { ok => 1, signatorial => $signatorial, unchanged => 1 };
	}
	my $update = {
		crest_uuid => $crest->{'uuid'},
		crest_cosig => $stored,
		server_time => &rightNow(),
	};
	$update->{'pubkey'} = $cosig->{'pubkey'} unless ($rm->{'pubkey'} || '');
	&db_update('remote_machines', $update, { uuid => $rm->{'uuid'} });
	return { ok => 1, signatorial => $signatorial };
}

# Tell the other machines which crest this one backs. Each peer verifies the
# signature against the key it already pins for us and records it on our roster
# row. The roster is this machine's own view and does not sync, so every machine
# posts to every peer: each one gathers the backers it has heard from itself.
sub crest_member_cosig_sync {
	my $crest = &crest_record_read();
	return 0 unless $crest->{'uuid'} && $crest->{'pubkey'};
	my $cosig = &crest_member_cosign($crest);
	return 0 unless $cosig;
	my $me = &signatorial_designer();
	my $sent = 0;
	foreach my $rm ( @{ &db_select('remote_machines')->hashes || [] } ) {
		my $rsig = $rm->{'signatorial'};
		next unless $rsig && $rsig ne $me;
		my ($ua, $p) = &peer_useragent($rm);
		next unless $ua && ref $p eq 'HASH' && $p->{'manager'};
		my $res = eval { $ua->inactivity_timeout(15)->post(
			$p->{'manager'} . '/manager/crest/cosign?signatorial=' . $me
			=> json => { crest_uuid => $crest->{'uuid'}, cosig => $cosig }
		)->result };
		$sent++ if $res && $res->is_success;
	}
	return $sent;
}

sub crest_sha256_file {
	my ($file) = @_;
	return undef unless $file && -e $file;
	my $bytes = read_file($file);
	return (defined $bytes && length $bytes) ? &sha256_hex($bytes) : undef;
}

# Normalize the drawing the same way every time: grayscale, level, deskew when
# the paper allows it, trim to the ink, and cap the long side. The color original
# is kept separately for the person to look at; this is the matching reference.
sub crest_normalize_image {
	my ($src, $dst) = @_;
	return 0 unless $src && $dst && -e $src;
	# The bridge normalizes without deskew, which matches the fallback magick
	# command below (the one magick already falls back to when deskew fails).
	return 1 if &image_bridge_normalize($src, $dst, 1024);
	my @cmd = ('magick', $src, '-colorspace', 'Gray', '-normalize',
		'-deskew', '40%', '-trim', '+repage', '-resize', '1024x1024>', $dst);
	my $rc = system(@cmd);
	if ($rc != 0 || !-e $dst || -s $dst == 0) {
		@cmd = ('magick', $src, '-colorspace', 'Gray', '-normalize',
			'-trim', '+repage', '-resize', '1024x1024>', $dst);
		$rc = system(@cmd);
	}
	return ($rc == 0 && -e $dst && -s $dst > 0) ? 1 : 0;
}

# A 64-bit difference hash: resize to 9x8, compare each pixel to its right-hand
# neighbour, one bit each. Small enough to store in the record, cheap to compare.
sub crest_dhash {
	my ($file) = @_;
	return undef unless $file && -e $file;
	my $raw = &image_bridge_gray($file, 9, 8);
	if (!defined $raw || length $raw != 72) {
		open(my $fh, '-|', 'magick', $file, '-resize', '9x8!', '-colorspace', 'Gray', '-depth', '8', 'gray:-') or return undef;
		binmode $fh;
		$raw = do { local $/; <$fh> };
		close $fh;
	}
	return undef unless defined $raw && length $raw == 72;
	my $bits = 0;
	my $n = 0;
	for my $y (0..7) {
		for my $x (0..7) {
			my $a = ord(substr($raw, $y * 9 + $x, 1));
			my $b = ord(substr($raw, $y * 9 + $x + 1, 1));
			$bits |= (1 << $n) if $a > $b;
			$n++;
		}
	}
	return sprintf('%016x', $bits);
}

sub crest_hamming {
	my ($a, $b) = @_;
	return undef unless defined $a && defined $b && $a =~ /^[0-9a-f]{16}$/i && $b =~ /^[0-9a-f]{16}$/i;
	my $ba = unpack('B*', pack('H*', $a));
	my $bb = unpack('B*', pack('H*', $b));
	my $n = 0;
	$n++ for grep { substr($ba, $_, 1) ne substr($bb, $_, 1) } 0..63;
	return $n;
}

1;
