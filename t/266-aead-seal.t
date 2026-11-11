# tests-for: lib/JawnOS/Domain/Sync.pm
# covers:    The at-rest and on-the-wire seal is authenticated: a JS1 blob is
#           AES-256-GCM under a PBKDF2 key and its salt and nonce are fresh per
#           message. A wrong key, a changed byte or a named-but-broken blob is
#           refused, and the legacy Crypt::Simple layer is still readable.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

subs::preload('encrypter decrypter decrypter_strict');

# --- a new seal is authenticated, and fresh each time -----------------------
my $a = subs::encrypter('the-key', 'hello');
my $b = subs::encrypter('the-key', 'hello');
like($a, qr/\AJS1:/, 'a new seal names its format');
isnt($a, $b, 'two seals of the same text differ (fresh salt and nonce)');
is(subs::decrypter_strict('the-key', $a), 'hello', 'the key opens it');
is(subs::decrypter('the-key', $a), 'hello', 'the ordinary reader opens it too');

my $raw = MIME::Base64::decode_base64(substr($a, 4));
cmp_ok(length($raw), '>=', 44, 'the blob carries salt(16), nonce(12), tag(16), ciphertext');
my $blob_again = MIME::Base64::decode_base64(substr($b, 4));
isnt(substr($raw, 0, 28), substr($blob_again, 0, 28), 'salt and nonce are not reused');

# --- binary content survives ------------------------------------------------
my $binary = join '', map { chr } 0 .. 255;
is(subs::decrypter_strict('k2', subs::encrypter('k2', $binary)), $binary,
	'every byte value round-trips');
is(subs::decrypter_strict('k2', subs::encrypter('k2', '')), '',
	'an empty plaintext round-trips');

# --- a wrong key or a changed byte is refused -------------------------------
my $s = subs::encrypter('right', 'payload');
isnt(subs::decrypter_strict('wrong', $s), 'payload', 'a wrong key does not open it');
isnt(subs::decrypter('wrong', $s), 'payload', 'and the ordinary reader does not either');
my $ct = $s;
my $mid = int(length($ct) / 2);
substr($ct, $mid, 1) = chr(ord(substr($ct, $mid, 1)) ^ 1);
isnt(subs::decrypter_strict('right', $ct), 'payload', 'a changed ciphertext byte is refused');
isnt(subs::decrypter('right', $ct), 'payload', 'the ordinary reader refuses it too');
# Changing the tag (bytes 28..43 of the raw blob) must also fail.
my $tagged = $s;
my $raw_tagged = MIME::Base64::decode_base64(substr($tagged, 4));
substr($raw_tagged, 29, 1) = chr(ord(substr($raw_tagged, 29, 1)) ^ 1);
my $tagged_blob = 'JS1:' . MIME::Base64::encode_base64($raw_tagged, '');
isnt(subs::decrypter_strict('right', $tagged_blob), 'payload', 'a changed tag is refused');

# --- a named-but-broken blob never falls back to the legacy reader ----------
is(subs::decrypter('right', 'JS1:not really a seal'), undef,
	'a JS1 blob that does not open is refused, not handed to Crypt::Simple');
is(subs::decrypter_strict('right', 'JS1:not really a seal'), undef,
	'and the strict reader refuses it too');

# --- the legacy layer is still readable -------------------------------------
my $legacy;
{
	require Crypt::Simple;
	local *main::encrypt;
	local *main::decrypt;
	Crypt::Simple->import(passphrase => 'old-key');
	$legacy = eval { main::encrypt('old payload') };
}
is(subs::decrypter('old-key', $legacy), 'old payload', 'a legacy blob still opens');
is(subs::decrypter_strict('old-key', $legacy), 'old payload',
	'and the strict reader opens it under the real key');
isnt(subs::decrypter_strict('another-key', $legacy), 'old payload',
	'but not under a different key');

# --- an empty secret is still a seal, not a public one ----------------------
my $empty = subs::encrypter('', 'empty-key payload');
like($empty, qr/\AJS1:/, 'an empty secret gets the same format');
is(subs::decrypter_strict('', $empty), 'empty-key payload', 'and round-trips');
isnt(subs::decrypter_strict('some-key', $empty), 'empty-key payload',
	'and does not open under another key');

done_testing();
