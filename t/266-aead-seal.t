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
use File::Temp qw(tempdir tempfile);
use JawnOSTest;

subs::preload('encrypter encrypter_legacy decrypter decrypter_strict backup_standard openssl_file_crypt openssl_file_read');

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

# --- a backup container's footer is public, and every shape opens ----------
# The footer names the cipher, so backup_now seals it with the empty key. The
# reader must accept the legacy Crypt::Simple shape, the JS1 shape v0.1.2691
# wrote under the empty-secret placeholder, and (defensively) a real-key seal.
my $house_key = 'the-house-key';
my $legacy_footer = subs::encrypter_legacy(undef, 'aes-256-ctr');
is(subs::backup_standard($house_key, $legacy_footer), 'aes-256-ctr',
	'a legacy empty-key footer opens under the real credential');
my $js1_footer = subs::encrypter(undef, 'aes-256-ctr');
like($js1_footer, qr/\AJS1:/, 'v0.1.2691 wrote a JS1 footer');
is(subs::backup_standard($house_key, $js1_footer), 'aes-256-ctr',
	'a JS1 footer under the empty placeholder opens too (a backup from that build still restores)');
my $real_footer = subs::encrypter($house_key, 'aes-256-ctr');
is(subs::backup_standard($house_key, $real_footer), 'aes-256-ctr',
	'a footer sealed with the real credential still opens');
is(subs::backup_standard($house_key, 'not a footer'), undef,
	'garbage is still refused');

# --- a forged cipher name cannot ride in on a peer's snapshot --------------
# The footer is under the public empty key, so a peer controls it. `none` and
# `null` are openssl passthroughs and would turn a plaintext file into the
# "decrypted" snapshot; an unknown name is no better.
is(subs::backup_standard($house_key, subs::encrypter_legacy(undef, 'none')), undef,
	'a footer naming `none` is refused');
is(subs::backup_standard($house_key, subs::encrypter_legacy(undef, 'null')), undef,
	'a footer naming `null` is refused');
is(subs::backup_standard($house_key, subs::encrypter_legacy(undef, 'made-up-cipher')), undef,
	'a cipher this build does not offer is refused');
is(subs::backup_standard($house_key, subs::encrypter_legacy(undef, '')), undef,
	'an empty standard is refused');
is(subs::backup_standard($house_key, $real_footer), 'aes-256-ctr',
	'a legitimate standard still opens');

# The file helpers refuse an unvetted standard before they touch openssl.
my $tmpdir = tempdir(CLEANUP => 1);
my ($ifh, $in_file) = tempfile('jawnos-plain-XXXXXX', DIR => $tmpdir);
print $ifh 'a plaintext snapshot';
close $ifh;
my $out_file = "$tmpdir/out.db";
is(subs::openssl_file_crypt('d', 'none', $house_key, $in_file, $out_file, 1, 1), 0,
	'openssl_file_crypt refuses `none`');
ok(!-e $out_file, 'and writes nothing');
is(subs::openssl_file_read('none', $house_key, $in_file, 1, 1), undef,
	'openssl_file_read refuses it too');

# A real standard still passes the allow-list and round-trips.
SKIP: {
	my $openssl = grep { -x "$_/openssl" } split /:/, ($ENV{PATH} || '');
	skip 'no openssl binary', 2 unless $openssl;
	ok(subs::openssl_file_crypt('e', 'aes-256-ctr', $house_key, $in_file, "$tmpdir/sealed", 0, 1),
		'a real standard still encrypts');
	is(subs::openssl_file_read('aes-256-ctr', $house_key, "$tmpdir/sealed", 0, 1), 'a plaintext snapshot',
		'and reads back');
}

done_testing();
