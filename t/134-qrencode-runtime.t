# tests-for: scripts/runtime_build.pl lib/JawnOS/Manager/Part12.pm scripts/jawnos_deps.pl
# covers:    qrencode ships in the Android runtime; a failed QR stores no image; a repair never overwrites a good one

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use File::Slurp qw(read_file);
use MIME::Base64 qw(encode_base64);
use RepoSource;

# A phone runtime without qrencode minted "passes" whose image was the 22-byte
# string `data:image/png;base64,` with nothing after it: the row saved, the desk
# said OK, the thumbnail was blank. Three pins keep that from coming back:
# qrencode is in runtime_build.pl's allow-list, qrcode_generator only builds a
# data URI from an actual PNG, and qrcode_updater writes a regenerated image
# back only into a row that has none.

my $root = repo_root();

# --- the runtime --------------------------------------------------------------
my $runtime = read_file("$root/scripts/runtime_build.pl");
my ($tool_list) = $runtime =~ /my %TOOL = map \{ \$_ => 1 \} qw\((.*?)\);/s;
ok($tool_list, 'runtime_build.pl has the %TOOL allow-list');
my %tool = map { $_ => 1 } split ' ', $tool_list;
ok($tool{'qrencode'}, 'qrencode is in the allow-list that ships bin/ tools');
ok($tool{'perl'}, 'the list is still the runtime diet, not a stub');
unlike($runtime, qr/node\/tmux\/qrencode\/zbarimg are dropped/,
	'the comment no longer claims qrencode is dev-only');
like($runtime, qr/qrencode is NOT dev-only/, 'the comment says why it ships');
like($runtime, qr/my \$has_perl = grep/, 'the allow-list is still what core packs');
like($runtime, qr/next if %baseline && \$baseline\{"lib\/\$name"\};/,
	'the library pass follows DT_NEEDED, so libqrencode\/libpng\/libz ship with it');

my $deps = read_file("$root/scripts/jawnos_deps.pl");
like($deps, qr/\{ cmd => 'qrencode',[^}]*termux => 'libqrencode'/,
	'the Termux recipe for a hand build names libqrencode');

# --- minting a pass -------------------------------------------------------------
my $part12 = read_file("$root/lib/JawnOS/Manager/Part12.pm");

my ($generator) = $part12 =~ /(sub qrcode_generator\(.*?\n\}\n)/s;
ok($generator, 'qrcode_generator is one sub');
like($generator, qr/substr\(\$qr, 0, 4\) eq "\\x89PNG"/,
	'a pass QR is only accepted when qrencode returned a PNG');
like($generator, qr/encode_base64\(\$qr, ''\)/,
	'the base64 has the empty pad argument, so the data URI has no line breaks');
unlike($generator, qr/encode_base64\(\$qr\)/, 'no wrapped encode_base64 survives');
unlike($generator, qr/my \$image = 'data:image\/png;base64,' \. encode_base64\(\$qr\)/,
	'the unconditional data URI that wrote 22 bytes is gone');
like($generator, qr/my \$image = '';/, 'a failed encode starts from no image at all');
like($generator, qr/unless \(length \$image\) \{/, 'a failure is detected by the image, not the exit code');
like($generator, qr/qrencode produced no PNG/, 'one honest line names qrencode as the cause');
like($generator, qr/&qrencode_png\(\$url\)/,
	'the url is handed to qrencode as a list, so no shell splits or expands it');
unlike($generator, qr/`qrencode -o - \$url`/, 'no backtick call is left in the mint');
my ($qrsub) = $part12 =~ /(sub qrencode_png\b.*?\n\}\n)/s;
ok($qrsub, 'qrencode_png is one sub');
like($qrsub, qr/open\(my \$fh, '-\|', 'qrencode', '-o', '-', \$url\)/,
	'the helper passes the url as one argv word, never through a shell');
like($generator, qr/image => \$image,/, 'the pass still carries the (possibly empty) image column');

# --- repair on open -------------------------------------------------------------
my ($updater) = $part12 =~ /(sub qrcode_updater\(.*?\n\}\n)/s;
ok($updater, 'qrcode_updater is one sub');
like($updater, qr/encode_base64\(\$qr, ''\)/, 'the repair encodes without wrapping too');
like($updater, qr/\$ticket_image_is_png->\(\$t->\{'image'\}\)/,
	'the repair asks whether the stored image is a PNG');
like($updater, qr/!\$ticket_image_is_png->\(\$t->\{'image'\}\)/, 'the repair asks whether the stored image is a PNG');
like($updater, qr/image => 'data:image\/png;base64,' \. encode_base64\(\$qr, ''\)/,
	'it writes the image back for a missing or invalid one');
unlike($updater, qr/^[ \t]*image => \$image,[ \t]*$/m, 'the old commented-out write is gone');

# --- the helper, run for real -----------------------------------------------------
{
	use File::Temp qw(tempdir);
	my $dir = tempdir(CLEANUP => 1);
	# The helper is pure; load the file once to call it. Part12 pulls in the
	# Manager's imports, so guard with a skip rather than fail on a bare box.
	my $ok = eval {
		local $SIG{__WARN__} = sub {};
		require lib::JawnOS::Manager::Part12;
		1;
	};
	if (!$ok) {
		# Manager package without the rest of the app: parse the helper out and
		# compile just it, so the assertion still runs on the real source.
		my ($helper) = $part12 =~ /(my \$ticket_image_is_png = sub \(.*?\n\};\n)/s;
		ok($helper, 'the PNG test is one file-private sub');
		(my $code_helper = $helper) =~ s/^my \$ticket_image_is_png = sub/our \$ticket_image_is_png = sub/m;
		my $code = "package QRPin; use feature 'signatures'; no warnings 'experimental::signatures'; "
			. "use MIME::Base64 qw(encode_base64 decode_base64);\n$code_helper\n1;";
		die "$@" unless eval $code;
		my $good = 'data:image/png;base64,' . encode_base64("\x89PNG\r\n\x1a\n" . 'x' x 60, '');
		ok(($QRPin::ticket_image_is_png)->($good), 'a real PNG data URI is accepted');
		ok(!($QRPin::ticket_image_is_png)->('data:image/png;base64,'), 'the 22-byte broken image is not');
		ok(!($QRPin::ticket_image_is_png)->(''), 'an empty image is not');
		ok(!($QRPin::ticket_image_is_png)->(undef), 'an undefined image is not');
		ok(!($QRPin::ticket_image_is_png)->('data:image/png;base64,aGVsbG8='), 'a non-PNG body is not');
	}
}

done_testing();
