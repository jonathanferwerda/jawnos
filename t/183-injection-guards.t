# tests-for: perl/watch.pl perl/Music.pl lib/JawnOS/Controller/box_office_misc.pm public/js/gate.js lib/JawnOS/Controller/manager_configure2.pm
# covers:    Request data never reaches a shell or eval sink.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);

# A security audit found five places where request data was interpolated into a
# shell command (or, in gate.js, into eval). The assertions below are source
# guards: they fail if the dangerous shape comes back. They do not start the app.

my $root = abs_path("$FindBin::Bin/..");

sub source {
	my ($rel) = @_;
	open(my $fh, '<', "$root/$rel") or die "open $rel: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

my $watch = source('perl/watch.pl');
unlike($watch, qr/`\s*\(echo \$secret\)/,
	'watch chat_grabber does not pipe the request secret through a shell');
like($watch, qr/MIME::Base64::decode_base64\(\$secret\)/,
	'watch decodes the request secret in Perl');

my $box = source('lib/JawnOS/Controller/box_office_misc.pm');
unlike($box, qr/`\s*echo "\$secret"/,
	'box office does not put the ticket token in a double-quoted shell string');
like($box, qr/decode_base64\(\$secret/,
	'box office decodes the ticket token in Perl');

my $music = source('perl/Music.pl');
unlike($music, qr/`vlc \$track`/,
	'music does not interpolate the track into a vlc shell command');
unlike($music, qr/`play \$track`/,
	'music does not interpolate the track into a play shell command');
like($music, qr/system\('vlc', \$track_name\)/,
	'music runs vlc in list form with the raw name');
like($music, qr/system\('play', \$track_name\)/,
	'music runs play in list form with the raw name');

my $gate = source('public/js/gate.js');
unlike($gate, qr/\beval\s*\(\s*JSON\.parse/,
	'gateKeeper parses the debriefer without eval');
like($gate, qr/var d = JSON\.parse\(response\.debriefer\)/,
	'gateKeeper uses JSON.parse directly');

my $conf = source('lib/JawnOS/Controller/manager_configure2.pm');
unlike($conf, qr/`timeout \$timeout ping -c 1 \$ip`/,
	'ping does not interpolate a raw host');
unlike($conf, qr/`timeout \$timeout ping -c 1 \$ip_address`/,
	'ping does not interpolate a raw derived address');
like($conf, qr/"timeout \$timeout ping -c 1 " \. &subs::shell_quote\(\$ip\)/,
	'ping quotes the host');
like($conf, qr/"timeout \$timeout ping -c 1 " \. &subs::shell_quote\(\$ip_address\)/,
	'ping quotes the derived address');
like($conf, qr/\Q[0-9., ]+\E/,
	'ping accepts only address/range/list characters');

done_testing();
