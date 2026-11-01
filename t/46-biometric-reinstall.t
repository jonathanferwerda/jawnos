use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use MIME::Base64 qw(encode_base64);
use JawnOSTest;

# After the Android app was uninstalled and reinstalled (a signature change on
# 2026-10-31) the OS had deleted the Keystore key and the WebView had lost its
# storage. The app re-paired under a new device_uuid with no bio_pubkey, the
# padlock asked for a fingerprint, `sign` answered `no key`, and nothing ever
# made or registered a key - so a good fingerprint could never open anything.
# The unlock now asks `hasKey` first (no prompt) and enrolls a fresh key when
# there is none, and it registers and retries once when the key signed but the
# house had no public half for it.
#
# These are source pins for that wiring; the server half below is the signature
# check the manager performs on the result.

my $js = read_file("$FindBin::Bin/../public/js/universal.js");

# 1. the readiness helper exists and only recovers a missing/invalidated key
like($js, qr/function jawnosBiometricKeyReady\(status\)\s*\{/,
	'there is a key-readiness helper');
my ($ready) = $js =~ /function jawnosBiometricKeyReady\(status\)\s*\{(.*?)\n\}/s;
ok(defined $ready, 'the helper body is found');
like($ready // '', qr/jawnosBiometricKeyCall\('hasKey', \[\]\)/,
	'it asks hasKey, which needs no prompt');
like($ready // '', qr/e !== 'no key' && e !== 'invalidated'/,
	'only a missing or invalidated key is recoverable');
like($ready // '', qr/jawnosBiometricEnroll\(status\)/,
	'it enrolls a fresh key when there is none');

# 2. both local signature paths make the key first
like($js, qr/function jawnosBiometricUnlock\([^)]*\)\s*\{.*?return jawnosBiometricKeyReady\(status\)/s,
	'an unlock makes the key first');
like($js, qr/function jawnosBiometricGo\([^)]*\)\s*\{.*?return jawnosBiometricKeyReady\(status\)/s,
	'a Go approval makes the key first');

# 3. a key that signed but was never registered is registered and retried once;
#    a genuinely refused signature is not
like($js, qr/if \(res\.error !== 'no biometric key'\) \{ throw/,
	'only an unregistered key is retried, never a refused signature');
like($js, qr/return jawnosBiometricEnroll\(status\)\.then\(attempt\)/,
	'the retry registers the key and attempts again');

# ---------------------------------------------------------------------------
# The manager's half: a P-256 key in the shape Android Keystore exports, and
# the exact "padlock-bio-unlock" message the app signs, must verify. A different
# target, message or key must not - that binding is what keeps a print made for
# one screen from opening another.
require Crypt::PK::ECC;
my $pk = Crypt::PK::ECC->new();
$pk->generate_key('secp256r1');
my $raw = $pk->export_key_raw('public');
my $spki = pack('H*', '3059301306072a8648ce3d020106082a8648ce3d030107034200') . $raw;
my $pub = encode_base64($spki, '');
is(length $spki, 91, 'the key is the 91-byte P-256 SPKI the app exports');
ok(&subs::ecdsa_public_key_ok($pub), 'the manager accepts that public key');
ok(!&subs::ecdsa_public_key_ok(encode_base64(substr($spki, 0, 40), '')), 'a truncated key is refused');

my $uuid = 'U1WFLRvX4HV7ue9KoarB94jiR';
my $nonce = '7x6HFYzqKrZk7kRI3kIjqGdJPcCi4hI3kCUi7Ivm';
my $target = 'GqeGPbjNPMZHZAvn7oKDgX547';
my $msg = join("\n", 'padlock-bio-unlock', $uuid, $target, $nonce);
my $sig = encode_base64($pk->sign_message($msg, 'SHA256'), '');
ok(&subs::ecdsa_verify($pub, $msg, $sig), 'a signature over the named target verifies');
ok(!&subs::ecdsa_verify($pub, join("\n", 'padlock-bio-unlock', $uuid, $uuid, $nonce), $sig),
	'the same signature does not open a different screen');
ok(!&subs::ecdsa_verify($pub, $msg . 'x', $sig), 'a changed message is refused');
my $other = Crypt::PK::ECC->new();
$other->generate_key('secp256r1');
my $other_spki = pack('H*', '3059301306072a8648ce3d020106082a8648ce3d030107034200')
	. $other->export_key_raw('public');
ok(!&subs::ecdsa_verify(encode_base64($other_spki, ''), $msg, $sig),
	'another key cannot sign for this one');

done_testing();
