# tests-for: lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_embedded.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Embedded2.pm lib/JawnOS/Domain/Firmware.pm lib/JawnOS/Domain/Remotes.pm lib/JawnOS/Domain/Boardpins.pm lib/JawnOS/Manager/Part34.pm
# covers:    The board token rides every board request. Only a house address may
#           be dialled, no log line names the token or a token-bearing URL, and
#           the plain-HTTP hop is a firmware follow-up rather than a fix here.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

sub source { return read_file(root() . '/' . $_[0]) }

# --- the host validator ------------------------------------------------------
# A board is dialled with the operator_door token in the request. Any row that
# names a public literal or a resolver name must be refused before the dial.
for my $host (qw(127.0.0.1 ::1 192.168.1.50 10.1.2.3 172.16.5.4 169.254.1.1
		100.64.0.3 fd12:3456::1 fe80::1)) {
	ok(subs::board_host_allowed($host), "a house literal is dialled: $host");
}
for my $host ('8.8.8.8', '1.1.1.1', '203.0.113.9',
		'phone.jonathanferwerda.com', 'alarmclock.local', 'localhost', '', undef) {
	ok(!subs::board_host_allowed($host), 'a public or named host is refused: ' . ($host // 'undef'));
}
ok(subs::board_host_allowed('  [::1]  '), 'a bracketed literal is normalised before the check');

# The refusal is inside the network reader too, so a caller that forgets the
# guard cannot make it dial. It must not make a request at all.
my $pins = subs::board_pins_http_read('8.8.8.8', 80, 'token-should-not-leave');
is($pins->{'ok'}, 0, 'the pins reader refuses a public board address');
like($pins->{'error'}, qr/not a house address/, 'and says why');

# --- every token-bearing dial is guarded ------------------------------------
my %guarded = (
	'lib/JawnOS/Controller/manager_embedded.pm' => 1,
	'lib/JawnOS/Domain/Notify.pm'               => 1,
	'lib/JawnOS/Domain/Embedded2.pm'            => 1,
	'lib/JawnOS/Domain/Firmware.pm'             => 1,
	'lib/JawnOS/Domain/Remotes.pm'              => 1,
	'lib/JawnOS/Domain/Boardpins.pm'            => 1,
	'lib/JawnOS/Manager/Part34.pm'              => 1,
);
for my $file (sort keys %guarded) {
	like(source($file), qr/board_host_allowed/, "$file checks the board host before dialling");
}

# --- no log line names the token or the URL that carries it -----------------
# Log calls can span lines, so read the statement up to its semicolon.
sub log_calls {
	my ($src) = @_;
	my @calls;
	while ($src =~ /((?:\$log->\w+|&?log_writer)\s*\([^;]*;)/gs) {
		push @calls, $1;
	}
	return @calls;
}

for my $file (sort keys %guarded) {
	my @calls = log_calls(source($file));
	my @token = grep { /(?:\bauthorization\b|\$auth(?:orization)?\b|\bauthor\b)/i } @calls;
	is_deeply(\@token, [], "$file logs no board token");
	my @url = grep { /\$(?:watch_home|wigi_url|teletype_url|url|req)\b/ } @calls;
	is_deeply(\@url, [], "$file logs no token-bearing URL");
}

# The delete_file path used to Dumper the request (and its token). It must stay
# gone: the guard names only the chip and the host.
unlike(source('lib/JawnOS/Controller/manager_embedded.pm'), qr/\bDumper\s*\(/,
	'no request is Dumper-ed on the board paths');

# --- the remaining risk is firmware work ------------------------------------
# The board sketches run a plain HTTP WebServer, so the token still crosses the
# LAN in clear text. This is a marker, not a pass: it names the follow-up and
# never asserts that the insecure hop is safe.
TODO: {
	local $TODO = 'firmware follow-up: serve the board routes over TLS or sign the '
		. 'token request with HMAC (jp/, jt/, jw/)';
	ok(0, 'the board token no longer crosses the LAN in clear text');
}

done_testing();
