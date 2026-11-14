# tests-for: lib/JawnOS/Domain/Note.pm lib/JawnOS/Domain/Network.pm lib/JawnOS/Domain/Embedded2.pm lib/JawnOS/Domain/Loader.pm scripts/note_reseal.pl
# covers:    Legacy notes are rewritten as the authenticated JS1 seal without
#           changing their words: appointment note fields, the OCR inside an
#           appointment's file JSON, and mailbox subject/body. A value that
#           already opens as JS1 is left alone, an unreadable value is reported
#           and untouched, and a write only lands if the row still holds what the
#           sweep read. The watch/LoRa token readers use the strict reader, so
#           an empty-key token is refused there.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use MIME::Base64;
use Mojo::JSON ();
use Mojo::Util qw(url_escape url_unescape);
use File::Slurp qw(read_file);
use JawnOSTest;

subs::preload('note_reseal note_reseal_value note_decrypter note_decrypter_strict note_encrypter note_seal_container encrypter encrypter_legacy decrypter_strict shorthand_name note_legacy_candidates legacy_keys_mesh');

my $root = root();

package FakeRows;
sub new { return bless { hashes => $_[1] || [] }, $_[0] }
sub hashes { return $_[0]->{'hashes'} }

package main;

# The shape an older upload wrote: an inner container keyed to the real secret,
# wrapped in a Crypt::Simple outer layer that may be under the real key or the
# empty passphrase.
sub legacy_note {
	my ($secret, $plain, $outer) = @_;
	my $container = subs::note_seal_container($plain, $secret, 'aes-256-ctr');
	my $md5 = subs::shorthand_name(subs::md5_sum($plain), 5);
	my $payload = encode_base64($container, '') . ':::---:::' . 'aes-256-ctr' . ':::---:::' . $md5;
	return subs::encrypter_legacy($outer, $payload);
}

my $K = 'test-house-key';

# The oldest stored shape: an inner container keyed to a house key the security
# history no longer holds, an empty-key outer layer, and no md5 marker. The
# plaintext is the only thing that can vouch for a recovery key.
sub old_key_note {
	my ($secret, $plain) = @_;
	my $container = subs::note_seal_container($plain, $secret, 'aes-256-cbc');
	my $payload = encode_base64($container, '') . ':::---:::' . 'aes-256-cbc';
	return subs::encrypter_legacy(undef, $payload);
}
my $plain_real  = 'legacy note under the real key';
my $plain_empty = 'legacy note from an upload with no session';
my $plain_ocr   = 'text read off a scanned page';
my $legacy_real  = legacy_note($K, $plain_real, $K);
my $legacy_empty = legacy_note($K, $plain_empty, undef);
my $legacy_ocr   = legacy_note($K, $plain_ocr, undef);
my $js1 = subs::note_encrypter($K, 'already in the authenticated format');
my $bad = 'plain text that is not a note';

my @appts = (
	{ rowid => 11, notes => $legacy_real, start_notes => $js1, end_notes => '', file => undef, ost => 1000, server_time => 1001 },
	{ rowid => 12, notes => $legacy_empty, start_notes => undef, end_notes => $bad,
	  file => Mojo::JSON::encode_json([{ f => '/tmp/scan.png', ocr => $legacy_ocr }]), ost => 2000, server_time => 1002 },
);
my @mail = (
	{ rowid => 21, subject => $legacy_real, body => $js1, ost => 1000, server_time => 1001 },
	{ rowid => 22, subject => $bad, body => '', ost => 1000, server_time => 1002 },
);

my @updates;
my ($dry, $applied);
{
	no warnings 'redefine';
	local *subs::suds_grabber = sub { return $K };
	local *subs::db_query = sub {
		my ($sql) = @_;
		return FakeRows->new($sql =~ /from appointments/ ? \@appts : $sql =~ /from mailbox/ ? \@mail : []);
	};
	local *subs::db_update = sub { push @updates, [@_]; return 1; };
	$dry = subs::note_reseal(0);
	$applied = subs::note_reseal(1);
}

# --- the dry run reports and writes nothing --------------------------------
is($dry->{'ok'}, 1, 'the sweep answers');
is($dry->{'apply'}, 0, 'a dry run says so');
is($dry->{'appointments'}, 2, 'both appointment rows have a legacy value');
is($dry->{'notes'}, 2, 'one note field in each row');
is($dry->{'ocr'}, 1, 'the scan OCR is counted');
is($dry->{'mailbox'}, 1, 'one mailbox row has a legacy value');
is($dry->{'already'}, 2, 'the two values already in JS1 are left alone');
is($dry->{'failed'}, 2, 'the two plain values are unreadable and reported');
is($applied->{'apply'}, 1, 'the apply pass says so');

# --- only the rows that changed are written --------------------------------
is(scalar @updates, 3, 'three rows are written');
my %by_row = map { $_->[2]->{'rowid'} => $_ } @updates;
ok($by_row{11} && $by_row{12} && $by_row{21}, 'the two appointment rows and the mailbox row');
ok(!$by_row{22}, 'the row with only an unreadable value is not written');

# --- the written values are JS1 and read back to the same words ------------
my $appt11 = $by_row{11};
ok($appt11->[1]->{'server_time'}, 'the write moves server_time so a peer pulls it');
is($appt11->[2]->{'server_time'}, 1001, 'and is guarded by the old server_time');
is($appt11->[0], 'appointments', 'an appointment notes write');
like($appt11->[1]->{'notes'}, qr/\AJS1:/, 'the note is now JS1');
is(subs::note_decrypter_strict($K, $appt11->[1]->{'notes'}), $plain_real, 'and opens strictly to the same words');
ok(!exists $appt11->[1]->{'start_notes'}, 'the value already in JS1 is not rewritten');
is($appt11->[2]->{'notes'}, $legacy_real, 'the write is guarded by the value that was read');

my $appt12 = $by_row{12};
like($appt12->[1]->{'notes'}, qr/\AJS1:/, 'the empty-key legacy note is now JS1');
is(subs::note_decrypter_strict($K, $appt12->[1]->{'notes'}), $plain_empty, 'and opens strictly to its words');
ok(!exists $appt12->[1]->{'end_notes'}, 'the unreadable end note is untouched');
my $files = eval { Mojo::JSON::decode_json($appt12->[1]->{'file'}) } || [];
is(scalar @{$files}, 1, 'the file JSON keeps its one entry');
like($files->[0]->{'ocr'}, qr/\AJS1:/, 'the OCR text is now JS1');
is(subs::note_decrypter_strict($K, $files->[0]->{'ocr'}), $plain_ocr, 'and opens strictly to the scanned words');
is($appt12->[2]->{'file'}, $appts[1]{'file'}, 'the file write is guarded by the JSON read');

my $mail21 = $by_row{21};
is($mail21->[0], 'mailbox', 'a mailbox write');
like($mail21->[1]->{'subject'}, qr/\AJS1:/, 'the subject is now JS1');
is(subs::note_decrypter_strict($K, $mail21->[1]->{'subject'}), $plain_real, 'and opens strictly to the subject');
ok(!exists $mail21->[1]->{'body'}, 'the body already in JS1 is not rewritten');

# --- the sweep is idempotent ----------------------------------------------
is(subs::note_reseal_value($appt11->[1]->{'notes'}, $K), $appt11->[1]->{'notes'},
	'a value that is already JS1 under the key is returned unchanged');

# A note that ends in two newlines keeps every byte: the first write already
# dropped one, and a re-seal must not drop the other.
my $two_newlines = "line one\n\n";
my $sealed_two = subs::note_reseal_value(legacy_note($K, $two_newlines, undef), $K);
like($sealed_two, qr/\AJS1:/, 'a note with a trailing newline is re-sealed');
is(subs::note_decrypter_strict($K, $sealed_two), $two_newlines,
	'and its trailing newline survives the re-seal');

# --- the watch/LoRa token reader is strict ---------------------------------
my $patience = 'per-device-patience';
my $token = legacy_note($patience, 'the device token', $patience);
is(subs::note_decrypter_strict($patience, $token), 'the device token',
	'a legacy token under the real patience still opens strictly');
my $empty_token = legacy_note($patience, 'the device token', undef);
is(subs::note_decrypter_strict($patience, $empty_token), '',
	'an empty-key token is refused by the strict reader');
is(subs::note_decrypter($patience, $empty_token), 'the device token',
	'while the ordinary note reader still opens it for at-rest data');

# --- a note from before the retained key history --------------------------
# The same rows the live sweep reports as `failed`: sealed under a passphrase
# that no security row carries any more. A caller that has the old passphrase
# hands it in, and the sweep re-seals under the key in use now.
my $old_key = 'the-key-before-the-rotation';
my $old_plain = 'a note written before the house key changed, long enough to be judged text';
my $old_note = old_key_note($old_key, $old_plain);
is(subs::note_decrypter($K, $old_note), '', 'without the old passphrase the lost-key note does not open');
is(subs::note_decrypter($K, $old_note, undef, 0, [$old_key]), $old_plain,
	'the old passphrase opens it when it is handed in');
is(subs::note_reseal_value($old_note, $K, undef, ['the-wrong-passphrase']), undef,
	'a wrong old passphrase leaves the note untouched');
my $old_resealed = subs::note_reseal_value($old_note, $K, undef, [$old_key]);
like($old_resealed, qr/\AJS1:/, 'a recovered note is rewritten as JS1');
is(subs::note_decrypter_strict($K, $old_resealed), $old_plain, 'and reads back strictly to the same words');

# The sweep threads the candidates through to the values that need them.
my @recovered;
my $old_appt = { rowid => 13, notes => $old_note, start_notes => undef, end_notes => '', file => undef, ost => 3000, server_time => 3001 };
{
	no warnings 'redefine';
	local *subs::suds_grabber = sub { return $K };
	local *subs::db_query = sub {
		my ($sql) = @_;
		return FakeRows->new($sql =~ /from appointments/ ? [$old_appt] : []);
	};
	local *subs::db_update = sub { push @recovered, [@_]; return 1; };
	my $miss = subs::note_reseal(0, { table => 'appointments' });
	is($miss->{'failed'}, 1, 'the sweep reports a lost-key note without the old passphrase');
	is($miss->{'notes'}, 0, 'and changes nothing');
	my $dry = subs::note_reseal(0, { table => 'appointments', old_secrets => [$old_key] });
	is($dry->{'failed'}, 0, 'with the old passphrase the note is no longer a failure');
	is($dry->{'notes'}, 1, 'and the dry run counts the change');
	is(scalar @recovered, 0, 'while writing nothing');
	my $applied = subs::note_reseal(1, { table => 'appointments', old_secrets => [$old_key] });
	is($applied->{'notes'}, 1, 'the apply pass rewrites it');
	is(scalar @recovered, 1, 'one guarded write');
	like($recovered[0]->[1]->{'notes'}, qr/\AJS1:/, 'the stored value is JS1');
	is(subs::note_decrypter_strict($K, $recovered[0]->[1]->{'notes'}), $old_plain,
			'and reads back to the original words');
	}

	# --- --try-all reaches a credential whose ost was rewritten -----------------
	# A restore/import rewrites ost, so the key that wrote a note can sit after it;
	# the timestamp walk then never reaches it, but the row is still in the table.
	my $late_key = 'the-key-before-the-rotation';
	my $late_plain = 'a note from before the key changed, whose security row was imported later';
	my $late_note = old_key_note($late_key, $late_plain);
	my $wrapped_late = subs::encrypter($K, $late_key);
	my @late_updates;
	{
		no warnings 'redefine';
		local *subs::suds_grabber = sub { return $K };
		local *subs::db_query = sub {
			my ($sql) = @_;
			return FakeRows->new([{ level => 'oldkey', credential => $wrapped_late, ost => 9999999999999 }]) if $sql =~ /from security/;
			return FakeRows->new([{ rowid => 14, notes => $late_note, start_notes => undef, end_notes => '', file => undef, ost => 3000, server_time => 3002 }]) if $sql =~ /from appointments/;
			return FakeRows->new([]);
		};
		local *subs::db_update = sub { push @late_updates, [@_]; return 1; };
		$subs::note_security_memo = undef;
		my $cands = subs::note_legacy_candidates($K);
		ok((grep { defined $_ && $_ eq $late_key } @{$cands}), 'the export candidates include the late credential');
		my $miss = subs::note_reseal(0, { table => 'appointments' });
		is($miss->{'failed'}, 1, 'the timestamp walk misses a credential written after the note');
		$subs::note_security_memo = undef;
		my $dry = subs::note_reseal(0, { table => 'appointments', try_all => 1 });
		is($dry->{'failed'}, 0, '--try-all reaches the late credential');
		is($dry->{'notes'}, 1, 'and the dry run counts the change');
		is(scalar @late_updates, 0, 'while writing nothing');
		$subs::note_security_memo = undef;
		my $applied = subs::note_reseal(1, { table => 'appointments', try_all => 1 });
		is($applied->{'notes'}, 1, 'the apply pass rewrites it');
		is(scalar @late_updates, 1, 'one guarded write');
		like($late_updates[0]->[1]->{'notes'}, qr/\AJS1:/, 'the stored value is JS1');
		is(subs::note_decrypter_strict($K, $late_updates[0]->[1]->{'notes'}), $late_plain,
			'and reads back to the original words');
	}

	# --- the peer key pull ------------------------------------------------------
	# The same candidate list, asked of every linked machine over the signed rail.
	# This machine is skipped and duplicate keys from several peers are collapsed.
	{
		no warnings 'redefine';
		local *subs::db_select = sub {
			return FakeRows->new([
				{ signatorial => 'me',     manager => 'https://me', ip => '127.0.0.1' },
				{ signatorial => 'peer-a', manager => 'https://a',  ip => '10.0.0.1' },
				{ signatorial => 'peer-b', manager => 'https://b',  ip => '10.0.0.2' },
			]);
		};
		local *subs::signatorial_designer = sub { return 'me' };
		my $fetch = sub {
			my ($rm, $seal) = @_;
			return $rm->{'signatorial'} eq 'peer-a' ? ['one', 'two'] : ['two', 'three'];
		};
		is_deeply(subs::legacy_keys_mesh(undef, $fetch), ['one', 'two', 'three'],
			'the mesh pull skips this machine and dedupes the peers');
	}

	# --- the token readers and the map name the strict one ---------------------
like(read_file("$root/lib/JawnOS/Domain/Network.pm"), qr/note_decrypter_strict\(\$patience/,
	'the watch authorizer reads its token strictly');
like(read_file("$root/lib/JawnOS/Domain/Embedded2.pm"), qr/note_decrypter_strict\(\$watch_settings/,
	'and the embedded wigi check does too');
like(read_file("$root/lib/JawnOS/Domain/Loader.pm"), qr/note_decrypter note_decrypter_strict note_reseal/,
	'the domain map carries the strict reader and the sweep');
like(read_file("$root/scripts/note_reseal.pl"), qr/subs::note_reseal\(\$apply, \{/,
	'the script runs the shared sweep with its apply flag');
like(read_file("$root/scripts/note_reseal.pl"), qr/--old-secret-file/,
	'the script can be handed the passphrase from before the retained history');
like(read_file("$root/scripts/note_reseal.pl"), qr/--try-all/,
	'the script can try every credential in the security table');
like(read_file("$root/scripts/note_reseal.pl"), qr/--export-keys/,
	'the script can hand its candidates to another machine');
like(read_file("$root/scripts/note_reseal.pl"), qr/--from-peers/,
	'the script can pull the candidates from linked machines');

# --- the rest of the note-shaped data --------------------------------------
my $hk = 'test-house-key';
my $suds = 'test-suds';
my $wh_legacy     = legacy_note($K, 'warehouse note', undef);
my $cr_legacy     = legacy_note($K, 'termux login', $K);
my $set_legacy    = legacy_note($K, 'ollama key', $K);
my $keyboard_legacy = subs::encrypter_legacy($K, 'keyboard layout');
my $vault_legacy  = legacy_note($hk, $suds, $hk);
my $pat = 'device-patience';
my $token_current = legacy_note($pat, 'current token', $pat);
my $token_prev    = legacy_note($pat, 'previous token', $pat);
my $email_json = Mojo::JSON::encode_json([{
	email => 'a@example.test',
	password => $cr_legacy,
	oauth_access_token => $js1,
}]);
my $door_json = Mojo::JSON::encode_json({
	__shutup => { patience => $pat, previous => { patience => $pat, authorization => encode_base64($token_prev, '') } },
	__specs  => { authorization => encode_base64($token_current, '') },
});
my $ticket_pw = 'ticket-password';
my $ticket_plain = '{"p":"ticket-suds","ts":"1"}';
my $ticket_secret = url_escape(encode_base64(legacy_note($ticket_pw, $ticket_plain, $ticket_pw), ''));
my $data_note = legacy_note($K, 'sms data payload', $K);
my $data_plain = '{"mail_uuid":"x"}';

my @rest_updates;
my $rest;
{
	no warnings 'redefine';
	local *subs::suds_grabber = sub { return $K };
	local *subs::house_key = sub { return $hk };
	local *subs::db_query = sub {
		my ($sql) = @_;
		return FakeRows->new([{ rowid => 31, notes => $wh_legacy, ost => 1000, server_time => 1001 }]) if $sql =~ /from warehouse/;
		return FakeRows->new([{ rowid => 41, payload => $cr_legacy, ost => 1000, server_time => 1001 }]) if $sql =~ /from credentials/;
		return FakeRows->new([{ rowid => 51, value => $vault_legacy }]) if $sql =~ /^select rowid, value from settings where app='__president' and setting='vault'/;
		return FakeRows->new([{ rowid => 61, value => $email_json, server_time => 1001 }]) if $sql =~ /^select rowid, value, server_time from settings where app='mailbox' and setting='email_config'/;
		return FakeRows->new([{ rowid => 71, value => $door_json, server_time => 1001 }]) if $sql =~ /^select rowid, value, server_time from settings where setting='operator_door'/;
		return FakeRows->new([{ rowid => 91, password => $ticket_pw, secret => $ticket_secret, server_time => 1001 }]) if $sql =~ /from tickets/;
		return FakeRows->new([{ rowid => 101, data => $data_note, ost => 1000, server_time => 1001 }, { rowid => 102, data => $data_plain, ost => 1000, server_time => 1002 }]) if $sql =~ /^select rowid, data, ost/;
		return FakeRows->new([{ rowid => 82, value => $keyboard_legacy, server_time => 1001 }]) if $sql =~ /^select rowid, value, server_time from settings where app='keyboard'/;
		return FakeRows->new([
			{ rowid => 81, app => 'mail',     setting => 'ollama_key', value => $set_legacy, ost => 1000, server_time => 1001 },
			{ rowid => 83, app => 'me',       setting => 'plain',      value => 'just text', ost => 1000, server_time => 1002 },
		]) if $sql =~ /^select rowid, app, setting, value, ost/;
		return FakeRows->new([]);
	};
	local *subs::db_update = sub { push @rest_updates, [@_]; return 1; };
	$rest = subs::note_reseal(1, { table => 'rest' });
}

is($rest->{'warehouse'}, 1, 'a warehouse note is re-sealed');
is($rest->{'credentials'}, 1, 'a saved credential payload is re-sealed');
is($rest->{'settings'}, 1, 'a note-shaped setting is re-sealed');
is($rest->{'keyboard'}, 1, 'the keyboard blob is re-wrapped as JS1');
is($rest->{'tickets'}, 1, 'a ticket secret is re-sealed');
is($rest->{'appointments_data'}, 1, 'a sealed appointment data value is re-sealed');
is($rest->{'vault'}, 1, 'the vault is re-sealed under the house key');
is($rest->{'mail_tokens'}, 1, 'a saved mail password is re-sealed');
is($rest->{'device_tokens'}, 2, 'both device authorizations are re-sealed');
is($rest->{'failed'}, 0, 'nothing in this pass is left unreadable');
is(scalar @rest_updates, 9, 'nine rows are written');

my %rest_by = map { ($_->[0] . ':' . ($_->[2]->{'rowid'} // '')) => $_ } @rest_updates;
my $wh_up = $rest_by{'warehouse:31'};
ok($wh_up->[1]->{'server_time'}, 'a rest write moves server_time too');
is($wh_up->[2]->{'server_time'}, 1001, 'guarded by the old server_time');
ok($wh_up && index($wh_up->[1]->{'notes'}, 'JS1:') == 0, 'the warehouse note is JS1');
is(subs::note_decrypter_strict($K, $wh_up->[1]->{'notes'}), 'warehouse note', 'and reads back');

my $cr_up = $rest_by{'credentials:41'};
ok($cr_up && index($cr_up->[1]->{'payload'}, 'JS1:') == 0, 'the credential payload is JS1');
is(subs::note_decrypter_strict($K, $cr_up->[1]->{'payload'}), 'termux login', 'and reads back');

my $set_up = $rest_by{'settings:81'};
ok($set_up && index($set_up->[1]->{'value'}, 'JS1:') == 0, 'the setting is JS1');
is(subs::note_decrypter_strict($K, $set_up->[1]->{'value'}), 'ollama key', 'and reads back');
my $kb_up = $rest_by{'settings:82'};
ok($kb_up && index($kb_up->[1]->{'value'}, 'JS1:') == 0, 'the keyboard blob is JS1');
is(subs::decrypter_strict($K, $kb_up->[1]->{'value'}), 'keyboard layout', 'and reads back');
ok(!$rest_by{'settings:83'}, 'a plain setting is left alone');

my $vault_up = $rest_by{'settings:51'};
ok($vault_up && index($vault_up->[1]->{'value'}, 'JS1:') == 0, 'the vault is JS1');
is(subs::note_decrypter_strict($hk, $vault_up->[1]->{'value'}), $suds, 'and still holds the suds');

my $email_up = $rest_by{'settings:61'};
my $servers = eval { Mojo::JSON::decode_json($email_up->[1]->{'value'}) } || [];
ok(index($servers->[0]->{'password'}, 'JS1:') == 0, 'the mail password is JS1');
is(subs::note_decrypter_strict($K, $servers->[0]->{'password'}), 'termux login', 'and reads back');
is($servers->[0]->{'oauth_access_token'}, $js1, 'the JS1 oauth token is left alone');

my $door_up = $rest_by{'settings:71'};
my $door = eval { Mojo::JSON::decode_json($door_up->[1]->{'value'}) } || {};
my $cur_raw = decode_base64($door->{'__specs'}->{'authorization'});
my $prev_raw = decode_base64($door->{'__shutup'}->{'previous'}->{'authorization'});
ok(index($cur_raw, 'JS1:') == 0 && index($prev_raw, 'JS1:') == 0, 'both device authorizations are JS1');
is(subs::note_decrypter_strict($pat, $cur_raw), 'current token', 'the current token reads back');
is(subs::note_decrypter_strict($pat, $prev_raw), 'previous token', 'the previous token reads back');

my $tk_up = $rest_by{'tickets:91'};
my $tk_ver = url_unescape(decode_base64($tk_up->[1]->{'secret'}));
is(subs::note_decrypter_strict($ticket_pw, $tk_ver), $ticket_plain, 'the ticket secret is JS1 under its password');

my $ad_up = $rest_by{'appointments:101'};
ok($ad_up && index($ad_up->[1]->{'data'}, 'JS1:') == 0, 'the sealed appointment data is JS1');
is(subs::note_decrypter_strict($K, $ad_up->[1]->{'data'}), 'sms data payload', 'and reads back');
ok(!$rest_by{'appointments:102'}, 'plaintext appointment data is left alone');


done_testing();
