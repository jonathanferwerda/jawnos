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
use File::Slurp qw(read_file);
use JawnOSTest;

subs::preload('note_reseal note_reseal_value note_decrypter note_decrypter_strict note_encrypter note_seal_container encrypter_legacy decrypter_strict shorthand_name');

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
my $plain_real  = 'legacy note under the real key';
my $plain_empty = 'legacy note from an upload with no session';
my $plain_ocr   = 'text read off a scanned page';
my $legacy_real  = legacy_note($K, $plain_real, $K);
my $legacy_empty = legacy_note($K, $plain_empty, undef);
my $legacy_ocr   = legacy_note($K, $plain_ocr, undef);
my $js1 = subs::note_encrypter($K, 'already in the authenticated format');
my $bad = 'plain text that is not a note';

my @appts = (
	{ rowid => 11, notes => $legacy_real, start_notes => $js1, end_notes => '', file => undef, ost => 1000 },
	{ rowid => 12, notes => $legacy_empty, start_notes => undef, end_notes => $bad,
	  file => Mojo::JSON::encode_json([{ f => '/tmp/scan.png', ocr => $legacy_ocr }]), ost => 2000 },
);
my @mail = (
	{ rowid => 21, subject => $legacy_real, body => $js1, ost => 1000 },
	{ rowid => 22, subject => $bad, body => '', ost => 1000 },
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

# --- the token readers and the map name the strict one ---------------------
like(read_file("$root/lib/JawnOS/Domain/Network.pm"), qr/note_decrypter_strict\(\$patience/,
	'the watch authorizer reads its token strictly');
like(read_file("$root/lib/JawnOS/Domain/Embedded2.pm"), qr/note_decrypter_strict\(\$watch_settings/,
	'and the embedded wigi check does too');
like(read_file("$root/lib/JawnOS/Domain/Loader.pm"), qr/note_decrypter note_decrypter_strict note_reseal/,
	'the domain map carries the strict reader and the sweep');
like(read_file("$root/scripts/note_reseal.pl"), qr/subs::note_reseal\(\$apply, \{/,
	'the script runs the shared sweep with its apply flag');

done_testing();
