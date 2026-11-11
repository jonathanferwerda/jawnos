package subs;

# People: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Crypt::PK::ECC;
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

our %H;
our $device;
our $gb;
our %m;

sub people_list {
	my $q = eval { &db_select('people', undef, { status => 'active' }) };
	my $rows = $q ? $q->hashes : [];
	# a person construct is a social person, not a house account: it has its own
	# window and must not appear in Security's device-assignment lists
	@{$rows} = grep { !(defined $_->{'app'} && length $_->{'app'}) } @{$rows};
	return [ sort { lc($a->{'name'} || '') cmp lc($b->{'name'} || '') } @{$rows} ];
}

# Whether an assignment may be made. The device in the hand is the one thing an
# assignment must not quietly demote: the live session keeps its privilege until
# the next login, and the next login would read the lower one.
sub person_assign_check {
	my ($device_uuid, $person_uuid, $current_device_uuid) = @_;
	return (0, 'no device') unless defined $device_uuid && length $device_uuid;
	my $device = eval { &db_select('paired_devices', ['uuid'], { uuid => $device_uuid })->hash };
	return (0, 'no device') unless $device;
	if (defined $person_uuid && length $person_uuid) {
		my $person = eval { &db_select('people', ['uuid', 'privilege'], { uuid => $person_uuid, status => 'active' })->hash };
		return (0, 'no person') unless $person;
		if (defined $current_device_uuid && length $current_device_uuid && $device_uuid eq $current_device_uuid) {
			return (0, 'you cannot demote the device you are using') unless ($person->{'privilege'} || '') eq 'citizen';
		}
	}
	return (1, '');
}

# A ticket is an invitation; the person it admits is the identity that outlives
# the link. The first login mints one from the ticket's name and privilege and
# writes the link back, so a resumed ticket keeps the same person. The ticket's
# own privilege remains the session's grant - this is attribution, not a second
# source of privilege.
sub person_for_ticket {
	my ($ticket) = @_;
	return undef unless $ticket && ref $ticket eq 'HASH';
	my $uuid = $ticket->{'person_uuid'} || '';
	if ($uuid) {
		my $known = eval { &db_select('people', undef, { uuid => $uuid, status => 'active' })->hash };
		return $known if $known;
	}
	# blacklisted is the deny, not a person
	return undef if (($ticket->{'privilege'} || '') eq 'blacklisted');
	my $name = $ticket->{'name'};
	return undef unless defined $name && length $name;
	my $privilege = $ticket->{'privilege'} || 'guest';
	$privilege = 'guest' unless $privilege =~ /^(?:citizen|resident|guest)$/;
	my $now = &rightNow();
	my $new = &random_string_creator(25);
	my $made = eval {
		&db_insert('people', {
			uuid => $new,
			name => $name,
			privilege => $privilege,
			status => 'active',
			created => $now,
			server_time => $now,
		});
	};
	return undef unless $made;
	eval { &db_update('tickets', { person_uuid => $new }, { uuid => $ticket->{'uuid'} }) } if $ticket->{'uuid'};
	$ticket->{'person_uuid'} = $new;
	return { uuid => $new, name => $name, privilege => $privilege, status => 'active' };
}

sub peer_allows {
	my ($c, $rm, $required) = @_;
	return 0 unless $rm && ref $rm eq 'HASH';
	my $row_key = $rm->{'uuid'} || $rm->{'signatorial'};
	return 0 unless $row_key;
	my $verified = $c ? $c->stash('peer_verified_key') : undef;
	return 0 unless $verified && $verified eq $row_key;
	my %rank = &peer_scope_rank();
	my $grant = lc($rm->{'grant_scope'} // '');
	# An empty grant is not trust. A machine is visitor until someone grants
	# more; the one-time migration grandfathers the peers that predate this rule.
	$grant = 'visitor' if $grant eq '';
	$grant = 'none' unless exists $rank{$grant};
	my $need = lc($required // 'member');
	$need = 'member' unless exists $rank{$need};
	my $expires = $rm->{'grant_expires'};
	if (defined $expires && $expires =~ /^\d+$/ && $expires > 0 && $expires < &rightNow()) {
		return 0;
	}
	return $rank{$grant} >= $rank{$need} ? 1 : 0;
}

# Validate a grant before it is written. Kept pure so a probe can exercise the
# policy without a database. Returns a normalized hashref, or undef when the
# scope is missing or unknown (a typo must never become a permission).
#
# privilege is the relationship, not the capability: citizen is the owner's own
# machine, peer is another house, visitor is an introduced house not yet a peer,
# and guest is a one-off device. grant_scope still decides what the row may do.
sub peer_grant_normalize {
	my ($opts) = @_;
	return undef unless $opts && ref $opts eq 'HASH';
	my %rank = &peer_scope_rank();
	my $scope = lc($opts->{'scope'} // '');
	return undef unless exists $rank{$scope};
	# write the house's word, not the older spelling
	$scope = 'resident' if $scope eq 'member';
	my $priv = lc($opts->{'privilege'} // '');
	return undef if length $priv && $priv !~ /^(?:citizen|peer|visitor|guest)$/;
	my $expires = $opts->{'expires'};
	$expires = '' unless defined $expires && $expires =~ /^\d+$/;
	return { scope => $scope, expires => $expires, privilege => (length $priv ? $priv : undef) };
}

# Write a grant to a roster row. The caller decides who may set one (a citizen
# route, or a house acting on its own roster); this only refuses garbage and
# keeps privilege untouched unless it was named.
sub peer_grant_setter {
	my ($opts) = @_;
	my $grant = &peer_grant_normalize($opts);
	return 0 unless $grant;
	my $where = $opts->{'uuid'} ? { uuid => $opts->{'uuid'} }
		: $opts->{'signatorial'} ? { signatorial => $opts->{'signatorial'} }
		: undef;
	return 0 unless $where;
	my $update = { grant_scope => $grant->{'scope'}, grant_expires => $grant->{'expires'} };
	$update->{'privilege'} = $grant->{'privilege'} if defined $grant->{'privilege'};
	&db_update('remote_machines', $update, $where);
	return 1;
}

# Verify an Ed25519 signature (base64) over a message against a PEM public key.
# The shared primitive behind peer_verify and the paired-device challenge.
sub signature_verify {
	my ($pubkey, $msg, $b64sig) = @_;
	return 0 unless $pubkey && index($pubkey, '-----BEGIN PUBLIC KEY-----') == 0;
	my $sig = eval { decode_base64 $b64sig } || '';
	return 0 unless length $sig;
	my $msg_file = &peer_temp_file('device_msg');
	my $sig_file = &peer_temp_file('device_sig');
	my $key_file = &peer_temp_file('device_pub');
	write_file($msg_file, $msg);
	write_file($sig_file, $sig);
	write_file($key_file, $pubkey);
	my $ok = system('openssl pkeyutl -verify -pubin -inkey ' . &quote($key_file) . ' -rawin -in ' . &quote($msg_file) . ' -sigfile ' . &quote($sig_file) . ' >/dev/null 2>&1') == 0;
	unlink $msg_file, $sig_file, $key_file;
	return $ok ? 1 : 0;
}

# Verify an ECDSA P-256 signature (base64 DER) over a message against an SPKI
# DER public key (base64). The phone's biometric key is an Android Keystore EC
# key: the OS releases it only after the person authenticates, so a valid
# signature is a real factor rather than a client-side confirmation.
sub ecdsa_verify {
	my ($pubkey_b64, $msg, $sig_b64) = @_;
	return 0 unless defined $pubkey_b64 && length $pubkey_b64;
	my $der = eval { decode_base64($pubkey_b64) } || '';
	my $sig = eval { decode_base64($sig_b64) } || '';
	return 0 unless length $der && length $sig;
	my $pk = eval { Crypt::PK::ECC->new(\$der, 'DER') };
	return 0 unless $pk;
	my $ok = eval { $pk->verify_message($sig, $msg, 'SHA256') };
	return $ok ? 1 : 0;
}

# The public half is accepted only if it is an EC key on P-256, the curve the
# Android Keystore key is made on.
sub ecdsa_public_key_ok {
	my ($pubkey_b64) = @_;
	return 0 unless defined $pubkey_b64 && length $pubkey_b64;
	my $der = eval { decode_base64($pubkey_b64) } || '';
	return 0 unless length $der;
	# Android Keystore and WebCrypto both export an uncompressed P-256
	# SubjectPublicKeyInfo. Check that shape directly: CryptX on the phone is
	# built without its JSON module, so export_key_jwk() dies there with
	# "FATAL: cannot find JSON module" and every real key was refused as
	# "bad key" - the thumb was blamed for a backend gap.
	my $p256_prefix = pack('H*', '3059301306072a8648ce3d020106082a8648ce3d030107034200');
	return 1 if length($der) == 91
		&& substr($der, 0, 26) eq $p256_prefix
		&& substr($der, 26, 1) eq "\x04";
	# fall back to the JWK check for an encoding whose parameters are explicit
	my $pk = eval { Crypt::PK::ECC->new(\$der, 'DER') };
	return 0 unless $pk;
	my $jwk = eval { decode_json($pk->export_key_jwk('public')) } || {};
	return (($jwk->{'kty'} // '') eq 'EC' && ($jwk->{'crv'} // '') eq 'P-256') ? 1 : 0;
}

# --- the recovery code --------------------------------------------------------
# The paper code: eight groups of five from Crockford's alphabet (no I, L, O or
# U to mistype). Verification is the decryption itself - the code unwraps a copy
# of the suds sealed to it - so the house keeps no hash, only the sealed blob.
# n characters from Crockford's alphabet, straight from /dev/urandom: the house
# key material of the recovery code, and the short codes humans compare. Perl's
# rand (predictable, and inherited by forked workers) is not good enough. Each
# byte mod 32 is uniform: 256 divides by 32.
sub code_chars_make {
	my ($n) = @_;
	my $chars = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
	my $raw = '';
	if (open my $fh, '<', '/dev/urandom') {
		binmode $fh;
		my $bytes = '';
		read($fh, $bytes, $n);
		close $fh;
		$raw = join '', map { substr($chars, ord($_) % 32, 1) } split '', $bytes if length($bytes) == $n;
	}
	unless (length($raw) == $n) {
		# a last resort only: stretch everything weak we have through md5
		my $seed = join '|', ($$, time, &random_string_creator($n));
		my $hex = '';
		$hex .= md5_sum($seed . $hex) for (1 .. int($n / 8) + 1);
		$raw = join '', map { substr($chars, hex($_), 1) } split '', substr($hex, 0, $n);
	}
	return $raw;
}

sub recovery_code_make {
	my $raw = &code_chars_make(40);
	my @groups = $raw =~ /.{5}/g;
	return join '-', @groups;
}

# the approval code: short enough to compare across two screens
sub device_request_code {
	my $raw = &code_chars_make(6);
	return substr($raw, 0, 3) . '-' . substr($raw, 3, 3);
}

sub recovery_code_clean {
	my ($code) = @_;
	return '' unless defined $code;
	$code = uc $code;
	$code =~ s/[^0-9A-Z]+//gi;
	$code =~ tr/ILO/110/;
	return $code;
}

sub c_maker {
	my $c = &subs::controller_builder();
	&subs::suds_grabber();

	$c->session('server_time' => &subs::rightNow());
	$c->session('authentication' => 'approved');

	return $c;
}

# ---- OAuth2 for mail accounts ------------------------------------------------
# Outlook and Gmail no longer accept a plain password over IMAP or SMTP. An
# account can be marked auth=oauth2 instead: the house runs the OAuth 2.0 device
# authorization grant - it shows a short code, the person approves it at the
# provider, and the refresh token is kept (sealed) to mint access tokens after.
# The access token rides XOAUTH2 for both IMAP and SMTP. A plain-password account
# is untouched: every branch below only fires when auth is exactly 'oauth2'.

# The OAuth2 clients the house can sign in with: one entry per app registration
# (a name, a provider, a client id and secret, a tenant and scopes), kept as a
# setting so it syncs and so several accounts can share the one registration. The
# secret is sealed like a mail password.
sub oauth_clients {
	my $raw = &setting_grabber({ app => 'mail', setting => 'oauth_clients' });
	my $list = eval { &decode_json($raw) } || [];
	return [ grep { ref $_ eq 'HASH' } @{$list} ];
}

sub oauth_clients_store {
	my ($list) = @_;
	&setting_setter({ app => 'mail', setting => 'oauth_clients', value => encode_json($list) });
}

sub oauth_client {
	my ($uuid) = @_;
	return {} unless length($uuid || '');
	my ($cli) = grep { ($_->{'uuid'} || '') eq $uuid } @{ &oauth_clients() };
	return $cli || {};
}

# An account may name a registered client instead of carrying its own id/secret/
# tenant; this lays the client's fields over the account's, so every caller goes
# on reading the same keys.
sub email_oauth_overlay {
	my ($es) = @_;
	my $cli = &oauth_client($es->{'oauth_client'});
	return $es unless %{$cli};
	my %x = %{$es};
	$x{'oauth_provider'} = $cli->{'provider'} if length($cli->{'provider'} || '');
	$x{'oauth_client_id'} = $cli->{'client_id'} if length($cli->{'client_id'} || '');
	$x{'oauth_client_secret'} = $cli->{'client_secret'} if length($cli->{'client_secret'} || '');
	$x{'oauth_tenant'} = $cli->{'tenant'} if length($cli->{'tenant'} || '');
	$x{'oauth_scope'} = $cli->{'scope'} if length($cli->{'scope'} || '');
	return \%x;
}

sub email_oauth_endpoints {
	my ($es) = @_;
	my $provider = $es->{'oauth_provider'} || 'microsoft';
	my $tenant = $es->{'oauth_tenant'} || 'common';
	if ($provider eq 'google') {
		return {
			device => 'https://oauth2.googleapis.com/device/code',
			token  => 'https://oauth2.googleapis.com/token',
			scope  => ($es->{'oauth_scope'} || 'https://mail.google.com/'),
			secret => 1,
		};
	}
	return {
		device => "https://login.microsoftonline.com/$tenant/oauth2/v2.0/devicecode",
		token  => "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token",
		scope  => ($es->{'oauth_scope'} || 'offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send'),
		secret => 0,
	};
}

sub email_oauth_plain {
	my ($es, $key, $suds) = @_;
	return '' unless length($es->{$key} || '');
	return &note_decrypter($suds || &suds_grabber(), $es->{$key});
}

sub email_oauth_http {
	my ($url, $form) = @_;
	require HTTP::Tiny;
	my $ua = HTTP::Tiny->new(timeout => 30);
	my $res = eval { $ua->post_form($url, $form) };
	return { error => 'http', error_description => 'request failed: ' . ($@ || '') } unless $res;
	my $json = eval { decode_json $res->{'content'} };
	return $json if ref $json eq 'HASH';
	return { error => 'http', error_description => ($res->{'status'} || '') . ' ' . ($res->{'reason'} || '') };
}

# Write fields back onto one account in the email_config setting.
sub email_server_update {
	my ($uuid, $fields) = @_;
	my $servers = eval { &decode_json(&setting_grabber({ app => 'mailbox', setting => 'email_config' })) } || [];
	foreach my $es ( @{$servers} ) {
		next unless ($es->{'uuid'} || '') eq $uuid;
		$es->{$_} = $fields->{$_} for keys %{$fields};
	}
	&setting_setter({ app => 'mailbox', setting => 'email_config', value => encode_json($servers) });
	return $servers;
}

sub email_oauth_store {
	my ($es, $r, $suds) = @_;
	return unless $es->{'uuid'};
	my %up = ( oauth_expires => time() + (($r->{'expires_in'} || 3600) - 30) );
	$up{'oauth_access_token'} = &note_encrypter($suds, $r->{'access_token'}) if length($r->{'access_token'} || '');
	$up{'oauth_refresh_token'} = &note_encrypter($suds, $r->{'refresh_token'}) if length($r->{'refresh_token'} || '');
	&email_server_update($es->{'uuid'}, \%up);
	$es->{$_} = $up{$_} for keys %up;
	return 1;
}

# A live access token for the account: the one held if it is still good, else a
# fresh one minted from the refresh token.
sub email_oauth_token {
	my ($es, $suds) = @_;
	$es = &email_oauth_overlay($es);
	$suds = &suds_grabber() unless $suds;
	my $end = &email_oauth_endpoints($es);
	my $access = &note_decrypter($suds, $es->{'oauth_access_token'} || '');
	return $access if length $access && ($es->{'oauth_expires'} || 0) > time() + 60;
	my $refresh = &note_decrypter($suds, $es->{'oauth_refresh_token'} || '');
	return '' unless length $refresh;
	my %form = ( grant_type => 'refresh_token', refresh_token => $refresh, client_id => ($es->{'oauth_client_id'} || '') );
	my $secret = &email_oauth_plain($es, 'oauth_client_secret', $suds);
	$form{'client_secret'} = $secret if length $secret;
	my $r = &email_oauth_http($end->{'token'}, \%form);
	return '' unless length($r->{'access_token'} || '');
	&email_oauth_store($es, $r, $suds);
	return $r->{'access_token'};
}

# Log an IMAP connection in, by XOAUTH2 for an oauth2 account or by password
# otherwise. The SASL initial response rides as an IMAP literal, which is what the
# continuation the server answers is for.
sub email_imap_login {
	my ($imap, $es, $token) = @_;
	if (($es->{'auth'} || '') eq 'oauth2') {
		my $ir = 'user=' . $es->{'email'} . "\x01auth=Bearer $token\x01\x01";
		my ($ok) = $imap->_tell_imap('AUTHENTICATE', [ 'XOAUTH2 ', \$ir ]);
		return $ok ? 1 : 0;
	}
	return $imap->login;
}

sub email_receiver {
	my $receive_type = shift;
	if ($receive_type eq 'auto') {
		my $signatorial = &subs::signatorial_designer();
		my $auto_receive = &subs::setting_grabber({ app => 'mailbox', setting => 'email_auto_receive' });
		if ($auto_receive ne &subs::device_setter() && $auto_receive ne $signatorial) {
			return;
		}
	}

	require Net::IMAP::Client;
	require MIME::Parser;
	require Authen::SASL;

	my $c = &subs::controller_builder();
	my $email_servers = eval { return decode_json &subs::setting_grabber({ app => 'mailbox', setting => 'email_config' }) } || [];
	@{$email_servers} = grep { $_->{'active'} eq 'on' } @{$email_servers};

	foreach my $es ( @{$email_servers} ) {

		my $oauth2 = (($es->{'auth'} || '') eq 'oauth2') ? 1 : 0;
		my $password = $oauth2 ? '' : &subs::note_decrypter(&subs::suds_grabber(), $es->{'password'});
		$es->{'status'} = 'failed';
		my $imap = Net::IMAP::Client->new(
			server => $es->{'imap_server'},
			user   => $es->{'email'},
			pass   => $password,
			ssl    => $es->{'imap_encryption'} eq 'SSL' ? 1 : 0,
			tls    => 0,
			ssl_verify_peer => 1,                     # (use ca to verify server, default yes)
#		  ssl_ca_file => '/etc/ssl/certs/certa.pm', # (CA file used for verify server) or
			ssl_ca_path => '/etc/ssl/certs/',         # (CA path used for SSL)
			port   => $es->{'imap_port'}                             # (but defaults are sane)
		) or next;
		if ($oauth2) {
			my $token = &subs::email_oauth_token($es);
			next unless length $token;
			&subs::email_imap_login($imap, $es, $token) or next;
		}
		else {
			$imap->login or next;
		}

		$es->{'status'} = 'success';
		$es->{'last_login'} = &subs::rightNow();
		my @folders = $imap->folders;
		$es->{'folders'} = {} unless $es->{'folders'};
		foreach my $f ( @folders ) {
			next if $es->{'folders'}->{$f};
			$es->{'folders'}->{$f} = {};
		}
		foreach my $f ( keys %{$es->{'folders'}} ) {
			delete $es->{'folders'}->{$f} unless grep { $f eq $_ } @folders;
			if ($es->{'folders'}->{$f}->{'retrieve'} eq 'on') {
				$imap->select($f);
				my $status = $imap->status($f); # hash ref!

				my $sep = $imap->separator;
				my $messages = $imap->search('ALL');
				my $summaries = $imap->get_summaries([ @{$messages} ]);
				foreach my $sum (@$summaries) {

					my $from = $sum->from->[-1];
					my @ea1 = split ' ', $from;
					$from = $ea1[-1];
					$from =~ /<([^>]+)>/;
					$from = $1;
					my $to = $sum->to->[-1];
					my @ea = split ' ', $to;
					$to = $ea[-1];
					$to =~ /<([^>]+)>/;
					$to = $1;
					# carbon copies, so a letter that was copied to others can show it
					my @cc;
					if ($sum->can('cc')) {
						foreach my $c ( @{ $sum->cc || [] } ) {
							my $addr = $c;
							$addr = $1 if $addr =~ /<([^>]+)>/;
							push @cc, $addr if $addr;
						}
					}
					my $cc = join(', ', @cc);
					my $subject = $sum->subject;
					my $checked_addresses = &subs::db_query('select * from settings where setting=? and (value=? or value=? and value != ?) and device=?', 'email', $from, $to, $es->{'email'}, $device)->hashes;
					# an address a person keeps in the typed list (their work mailbox, say)
					# names them too: fold those apps in before the loop, once each
					my %known_recipient = map { $_->{'app'} => 1 } @{$checked_addresses};
					foreach my $address ( $from, $to ) {
						next unless $address;
						foreach my $ca_app ( &subs::contact_apps('email', $address) ) {
							next if $known_recipient{$ca_app}++;
							push @{$checked_addresses}, { app => $ca_app };
						}
					}
					# Nobody the house knows sent this: the letter still comes in, and its
					# attachments wait in the unclaimed pool (a month to claim) rather than
					# being dropped with the parse.
					if (!scalar @{$checked_addresses} && $to eq $es->{'email'} && lc $f ne 'drafts') {
						push @{$checked_addresses}, { app => 'camera', unclaimed => 1 };
					}
					foreach my $ca ( @{$checked_addresses} ) {
						# check for appointments
						my $timestamp = &subs::ago_calc($sum->date,&subs::rightNow());
						my $appts = &subs::db_query('select * from appointments where app=? and timestamp=? and type=?', $ca->{'app'}, $timestamp, 'email')->hashes;
						next if scalar @{$appts} > 0;


						my $body;
						my $part_ref = $imap->get_part_body($sum->uid, '1.3');
						my $parts = $imap->get_parts_bodies($sum->uid, [ '1.1', '1.2', '2.1' ]);
						my $msg_string = $imap->get_rfc822_body($sum->uid);

						my $parser = MIME::Parser->new;
						$parser->output_dir($gb::tmp_dir);
						my $entity = $parser->parse_data($msg_string);
						my $bodyfile = $entity->bodyhandle;
						# the message headers a real thread is built from
						my $hdr = sub { my $v = $entity->head->get($_[0]); $v = '' unless defined $v; $v =~ s/^\s+|\s+$//g; return $v; };
						my $h_message_id = $hdr->('Message-ID');
						my $h_in_reply_to = $hdr->('In-Reply-To');
						my $h_references = $hdr->('References');
						# the chain's root id names the thread: the first id it references, else
						# what it answers, else its own id
						my $h_thread = '';
						my @chain = ($h_references =~ /(<[^>]+>)/g);
						$h_thread = $chain[0] if @chain;
						$h_thread = $h_in_reply_to unless length $h_thread;
						$h_thread = $h_message_id unless length $h_thread;

						my ($plain_text,$html_text) = ("","");
						foreach my $part ($entity->parts_DFS) {
							# Get the MIME type (e.g., 'text/plain', 'text/html')
							my $content_type = $part->effective_type;

							# Check if a body exists for this part
							if (my $body_handle = $part->bodyhandle) {
								if ($content_type eq 'text/plain') {
									$plain_text .= $body_handle->as_string;
								}
								elsif ($content_type eq 'text/html') {
									$html_text .= $body_handle->as_string;
									my $hs = HTML::Strip->new(
										striptags   => [ 'iframe','script' ],
										emit_spaces => 0
									);
									$body = $hs->parse( $html_text );

								}
							}
						}

						$body = $html_text ne "" ? &subs::article_html_clean($html_text) : do {
							my $plain = &subs::html_text($plain_text);
							$plain =~ s/\r?\n/<br>/g;
							$plain;
						};


						my $files = [];
						# the uuid the mailbox row will wear, so the appointment and its
						# files can point back at the very message
						my $mailbox_uuid = &subs::random_string_creator(44);
						foreach my $part ($entity->parts) {

							my $filename = $part->head->recommended_filename;
							if ($filename) {


								my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $filename, app => $ca->{'app'}, is_thumb => 0 });
								copy($gb::tmp_dir . '/' . $filename, $destination . $asset);
								my $u_data = { server_time => &subs::rightNow(), f => $destination . $asset, uuid => &subs::random_string_creator(28), type => $type, mail_uuid => $mailbox_uuid };
								my $thumb = $destination . '/.thumbs';
								if ($type eq 'image') {
									`mkdir -p $thumb` unless -e $thumb;
									$u_data->{'thumb'} = $thumb . '/' . $asset;

								}
								push @{$files}, $u_data;

							}
						}
						my $status = 'inbox';
						my $email = $from;
						if ($to ne $es->{'email'}) {
							$status = 'sent';
							$email = $to;
						} elsif (lc $f eq 'drafts') {
							$status = 'draft';
						}
						my $app_uuid = &subs::random_string_creator(31);
						my $jfile = scalar @{$files} > 0 ? encode_json $files : undef;
						# the appointment wears the mailbox row's uuid and the address the
						# conversation is with, so the envelope in the details can open the
						# very message
						my $appt_data = {
							app => $ca->{'app'},
							type => 'email',
							timestamp => $timestamp,
							notes => &subs::note_encrypter(&subs::suds_grabber(), $body),
							file => $jfile,
							data => encode_json({ mail_uuid => $mailbox_uuid, email => $email })
						};
						# an unknown sender's letter lands in the unclaimed pool, which expires
						# after a month if nobody claims it onto an appointment
						if ($ca->{'unclaimed'}) {
							$appt_data->{'source'} = 'unclaimed';
							$appt_data->{'warranty'} = &subs::rightNow() + (30 * 24 * 60 * 60 * 1000);
						}
						&Manager::appointment_writer($c,$appt_data);

						my $email_data = {
							uuid => $mailbox_uuid,
							timestamp => $timestamp,
							server_time => &subs::rightNow(),
							body => &subs::note_encrypter(&subs::suds_grabber(), $body),
							manager_file => $es->{'email'},
							subject => &subs::note_encrypter(&subs::suds_grabber(), $subject),
							status => $status,
							email => $email,
							cc => $cc,
							thread => ($h_thread || $h_message_id || undef),
							message_id => $h_message_id,
							in_reply_to => $h_in_reply_to,
							thread_refs => $h_references,
							email_server => $es->{'uuid'},
							attachments => $jfile
						};
						&subs::db_insert('mailbox', $email_data);
						# a letter the server accepted goes out to the browsers at once;
						# only what lands in the inbox is news
						if ($status eq 'inbox') {
							&subs::mail_arrival({
								c => $c,
								uuid => $email_data->{'uuid'},
								email => $email,
								manager_file => $from,
								subject => $subject,
								status => 'inbox',
								body => $body
							});
						}
						foreach my $u_data ( @{$files} ) {
							$u_data->{'app_uuid'} = $app_uuid;
							$u_data = &thumbnail_creator($u_data);
						}
						&subs::file_encrypter({ app => $ca->{'app'}, timestamp => $timestamp, suds => &subs::suds_grabber() });
						&subs::appt_header_printer({ app => $ca->{'app'} });
						&Websocket::send('server', { console => &Websocket::console_command('appointmentDetailGrabber', $ca->{'app'}, $app_uuid)});
						$entity->purge;

					}
				}
			}
		}

	}
#	});
	my $jemail_servers = encode_json $email_servers;
	&subs::setting_setter({ app => 'mailbox', setting => 'email_config', value => $jemail_servers });

	my $html = $c->render_to_string(
		template => 'mail/email_configure'
	);
	return { email_servers => $email_servers, html => $html };
}

# Send what waits in the outbox. A uuid picks one letter and sends it on the
# spot - the compose side calls it the moment a letter is written, so nothing
# waits for the sweep. The uuid-less form is the utility's, and it keeps the
# old manners: only this device's letters, and never ahead of their timestamp.
sub email_sender {
	my ($uuid, $c) = @_;
	my $query;
	if ($uuid) {
		$query = &subs::db_query('select * from mailbox where status = ? and uuid = ?', 'outbox', $uuid);
	}
	else {
		$query = &subs::db_query('select * from mailbox where status = ? and timestamp <= ? and sender = ?', 'outbox', &subs::rightNow(), &subs::device_setter());
	}
	# hashes hands back one collection, so the rows are taken off it by hand:
	# assigning it straight to an array wrapped it in a single-element list
	my $waiting = $query ? $query->hashes : [];
	my $returner;
	foreach my $o ( @{$waiting} ) {
		&subs::db_update('mailbox', { status => 'sending', server_time => &subs::rightNow() }, { uuid => $o->{'uuid'} });
		my $result = eval {
			&email_send({
				c => $c,
				from => $o->{'from_email'},
				email => $o->{'email'},
				subject => $o->{'subject'},
				body => $o->{'body'},
				attachments => $o->{'attachments'},
				uuid => $o->{'uuid'},
			});
		};
		if ($@) {
			# an smtp server that refuses the connection dies inside the transport:
			# the letter goes back to the outbox like any other failure
			warn "email_sender: send failed for $o->{'uuid'}: $@";
			$result = { result => 'fail' };
		}
		$returner = ref $result eq 'HASH' ? $result->{'result'} : $result;
		if ($returner ne 'success') {
			# a letter that failed goes back to the outbox: it stays visible and
			# the sweep retries it, instead of sitting in 'sending' forever
			&subs::db_update('mailbox', { status => 'outbox', server_time => &subs::rightNow() }, { uuid => $o->{'uuid'} });
		}
	}
	return $returner;
}

# Letters the server accepts all come through here: the imap reader, the
# telephone's sms list, a watch, a neighbour posting one over. The message
# travels to the websocket daemon over the mail socket, which matches it to
# open mailboxes, dots the start menus' mail icons, and lets the regular
# notification speak when no mailbox is watching the thread. The envelope is
# rendered here because a controller is what reads the words back out.
sub mail_arrival {
	my $m = shift;
	my $c = delete $m->{'c'} || &subs::c_maker();
	$m->{'uuid'} ||= &subs::random_string_creator(44);
	$m->{'type'} ||= 'message';
	if (!$m->{'picker'}) {
		# a row that carries the social constructs as columns is addressed to
		# that thread; one with none is addressed by phone, email or contact.
		# The columns come from the registry, so a new construct needs no change
		# here and a retired one simply stops being read.
		my %picker;
		my $addressed = 0;
		foreach my $scons ( values %{$gb::social_constructs} ) {
			my $sing = $scons->{'sing'};
			next unless defined $m->{$sing} && length $m->{$sing};
			$addressed = 1;
			$picker{$scons->{'name'}} = $m->{$sing};
		}
		$m->{'picker'} = \%picker if $addressed;
	}
	$m->{'decrypted'} = 'yes' unless exists $m->{'decrypted'};
	unless ($m->{'envelope'}) {
		$m->{'envelope'} = $c->render_to_string(
			template => 'mail/message',
			'm' => $m,
			'me' => ''
		);
	}
	unless ($m->{'arrival_message'}) {
		my $who = $m->{'manager_file'} || $m->{'email'} || $m->{'phone'} || 'someone';
		my $what = $m->{'arrival_subject'} || $m->{'subject'} || '';
		$m->{'arrival_message'} = 'Mail from ' . $who . ($what ? ': ' . $what : '');
	}
	$m->{'arrival'} = 'yes';
	&Websocket::mail_send($m);
	return $m;
}

1;
