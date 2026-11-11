# tests-for: lib/JawnOS/Domain/Note.pm
# covers:    A note written by an older build can carry its outer Crypt::Simple
#           layer sealed under the empty passphrase while its inner cipher is
#           keyed to the real secret (an upload that ran without a resolved
#           session wrote those). The reader must still open that shape, while a
#           note in the authenticated AEAD format stays closed to a changed byte.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use MIME::Base64;
use File::Slurp qw(read_file);
use JawnOSTest;

subs::preload('note_encrypter note_decrypter note_unseal note_seal_container encrypter_legacy decrypter decrypter_strict shorthand_name');

# The domain layer is lazy; preloading above pulls in the real definitions.
my $root = root();

package FakeRows;
sub new { return bless { hashes => $_[1] || [] }, $_[0] }
sub hashes { return $_[0]->{'hashes'} }

package main;

# note_decrypter walks the security history when the first key misses; the
# sandbox database is real, but this test needs no credential rows.
sub _no_credentials {
	local *subs::db_query = sub { FakeRows->new([]) };
	return $_[0]->();
}

my $secret = 'house-unlock-code';
my $plain  = "an old appointment note\nsecond line";

# The shape an upload with no resolved session wrote: the inner container is
# keyed to the real secret, the outer layer to the empty passphrase.
my $container = subs::note_seal_container($plain, $secret, 'aes-256-ctr');
ok(defined $container && length $container, 'the inner container seals under the real secret');
my $md5 = subs::shorthand_name(subs::md5_sum($plain), 5);
my $payload = encode_base64($container, '') . ':::---:::' . 'aes-256-ctr' . ':::---:::' . $md5;
my $legacy = subs::encrypter_legacy(undef, $payload);
ok(defined $legacy && length $legacy, 'the outer layer seals under the empty passphrase');

is(subs::decrypter_strict($secret, $legacy), undef, 'the strict reader refuses the empty-key outer layer');
is(_no_credentials(sub { subs::note_decrypter($secret, $legacy) }), $plain,
	'the note reader still opens it');
is(_no_credentials(sub { subs::note_unseal($secret, $legacy) }), $plain,
	'and note_unseal is where the compatible read happens');

# The authenticated format is unchanged: a fresh note round-trips, and a changed
# byte is refused rather than handed back as garbage.
my $fresh = _no_credentials(sub { subs::note_encrypter($secret, $plain) });
like($fresh, qr/\AJS1:/, 'a new note names the AEAD format');
is(_no_credentials(sub { subs::note_decrypter($secret, $fresh) }), $plain, 'and round-trips');
my $tampered = $fresh;
substr($tampered, int(length($tampered) / 2), 1) = 'A';
is(_no_credentials(sub { subs::note_decrypter($secret, $tampered) }), '',
	'a changed byte does not come back as a note');

# The fix is the reader choice: the strict reader would lose the legacy shape.
my $note = read_file("$root/lib/JawnOS/Domain/Note.pm");
like($note, qr/: &subs::decrypter\(\$key, \$contented\)/,
	'note_unseal reads through the legacy-compatible reader by default');
like($note, qr/\$strict \? &subs::decrypter_strict\(\$key, \$contented\)/,
	'a strict caller gets the strict reader');
like($note, qr/sub note_decrypter_strict/,
	'and the strict reader is a named path');

done_testing();
