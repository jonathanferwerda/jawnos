# tests-for: lib/JawnOS/Domain/File.pm lib/JawnOS/Domain/Note.pm lib/JawnOS/Manager/Part17.pm
# covers:    A /file_open refusal ("no", "none", "not found") is not a file body.
#            The old sync merge decoded that word as base64 and wrote the result
#            over the media path: decode_base64("no") is the one byte 0x9e and
#            decode_base64("none") is 0x9e 0x89 0xde, which is exactly the stub
#            an agent found in the gallery and an icon drew as a blank picture.
#            The merge now refuses those words and an already circulated stub,
#            and a failed seal no longer destroys the only plaintext copy.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use MIME::Base64 qw(encode_base64 decode_base64);

my $sandbox = JawnOSTest::sandbox();
$subs::say_quiet = 1;

my $dir = "$sandbox/media-stub";
make_path($dir);

# --- the words decode to the stubs agents have been finding -----------------
is( unpack('H*', decode_base64('no==')), '9e',
	'decode_base64("no") is the one-byte 0x9e stub' );
is( unpack('H*', decode_base64('none')), '9e89de',
	'decode_base64("none") is the three-byte 0x9e 0x89 0xde stub' );
ok( subs::file_sentinel_stub_bytes(''), 'an empty body is a stub, not a file' );
ok( subs::file_sentinel_stub_bytes("\x9e"), 'the one-byte sentinel is a stub' );
ok( subs::file_sentinel_stub_bytes("\x9e\x89\xde"), 'the three-byte sentinel is a stub' );
ok( !subs::file_sentinel_stub_bytes("\xff\xd8\xff\xe0jpeg-picture"),
	'a real picture is not a stub' );
ok( !subs::file_sentinel_stub_bytes('x' x 4), 'four bytes or more is a file' );

# --- the same test on disk --------------------------------------------------
my $one = "$dir/one.jpg.enc";
my $three = "$dir/three.jpg.enc";
my $empty = "$dir/empty.jpg.enc";
my $real = "$dir/real.jpg.enc";
write_file($one, "\x9e");
write_file($three, "\x9e\x89\xde");
write_file($empty, '');
write_file($real, 'Salted__' . ('x' x 32));
ok( subs::file_sentinel_stub($one), 'a one-byte file on disk is a stub' );
ok( subs::file_sentinel_stub($three), 'a three-byte file on disk is a stub' );
ok( subs::file_sentinel_stub($empty), 'an empty file on disk is a stub' );
ok( !subs::file_sentinel_stub($real), 'a sealed container on disk is not a stub' );
ok( !subs::file_sentinel_stub("$dir/not-there"), 'a missing path is not a stub' );

# --- a refusal word is never payload ---------------------------------------
is( subs::synced_file_payload('no', $one), undef, '"no" is not file bytes' );
is( subs::synced_file_payload('none', $one), undef, '"none" is not file bytes' );
is( subs::synced_file_payload('not found', $one), undef, '"not found" is not file bytes' );
is( subs::synced_file_payload("  NO \n", $one), undef, 'the refusal is case- and space-tolerant' );
is( subs::synced_file_payload('', $one), undef, 'an empty answer is not file bytes' );
is( subs::synced_file_payload('ng==', "$dir/x.jpg.enc"), undef,
	'a stub that already circulated as base64 is refused' );
is( subs::synced_file_payload('<html><body>locked</body></html>', "$dir/x.png"), undef,
	'an HTML lock page is not file bytes' );

# --- the real answers still land -------------------------------------------
my $sealed = 'Salted__' . ('s' x 8) . ('c' x 40);
is( subs::synced_file_payload(encode_base64($sealed, ''), "$dir/x.jpg.enc"), $sealed,
	'a sealed container is accepted for a .enc path' );
my $short = 'Salted__' . ('s' x 8);
is( subs::synced_file_payload(encode_base64($short, ''), "$dir/x.jpg.enc"), undef,
	'a container with no ciphertext is refused' );
my $jpeg = "\xff\xd8\xff\xe0jpeg-picture";
is( subs::synced_file_payload(encode_base64($jpeg, ''), "$dir/x.jpg"), $jpeg,
	'an open picture is accepted for a plain path' );
like( encode_base64($sealed), qr{\n},
	'encode_base64 (as /file_open uses it) may carry the newlines this accepts' );
is( subs::synced_file_payload(encode_base64($sealed), "$dir/x.jpg.enc"), $sealed,
	'and a newline-wrapped container is still accepted' );

# --- a failed seal leaves the plaintext alone -------------------------------
my $plain = "$dir/picture.jpg";
write_file($plain, $jpeg);
my $sealed_out = "$dir/picture.jpg.enc";
ok( subs::seal_file($plain, $sealed_out, 'secret', 'aes-256-ctr'), 'a real seal succeeds' );
ok( -e $sealed_out && (-s $sealed_out) > 16, 'and writes a container' );
is( substr(read_file($sealed_out), 0, 8), 'Salted__', 'the house container names itself' );

my $blank = "$dir/blank.jpg";
write_file($blank, '');
my $blank_out = "$dir/blank.jpg.enc";
ok( !subs::seal_file($blank, $blank_out, 'secret', 'aes-256-ctr'),
	'an empty plaintext is not sealed' );
ok( !-e $blank_out, 'and no empty container is left behind' );
ok( !subs::seal_file($plain, "$dir/no-secret.jpg.enc", '', 'aes-256-ctr'),
	'a seal with no secret fails' );

done_testing();
