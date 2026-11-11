# tests-for: firmware/house_ca.h perl/President.pl jp/alarmclock/platformio.ini jp/alarmclock/alarmclock.ino jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_04_jobs_clock_config_net.ino jp/alarmclock/alarmclock_05_device_ws.ino jt/platformio.ini jt/jt.ino jt/jt_01_globals_ble_house.ino jt/jt_03_setup.ino jt/jt_07_lorawan_house_net.ino jt/jt_10_remote_auth.ino jt/jt_14_voice_notes_clips.ino jw/platformio.ini jw/jw.ino jw/jw_06_net_face.ino jw/jw_07_house_audio.ino jw/jw_08_voice.ino
# covers:    Every board verifies the manager's house-CA peer leaf instead of
#           accepting any peer: the Pico through BearSSL trust anchors, the two
#           ESP32s through setCACert, all pinned to the same embedded CA. The
#           watch and socket listeners present that leaf, with the public
#           certificate as the fallback when no peer pair exists.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use MIME::Base64 qw(decode_base64);
use RepoSource;

my $root = repo_root();

sub slurp_path {
	my ($rel) = @_;
	return undef unless -e "$root/$rel";
	return scalar read_file("$root/$rel");
}

# --- 1. no board turns verification off ------------------------------------
my @firmware;
for my $dir (glob("$root/jp/*/"), "$root/jt/", "$root/jw/") {
	push @firmware, glob("$dir*.ino");
}
is(scalar @firmware, 39, 'the three firmware trees were read');

my @insecure = grep {
	my $text = scalar read_file($_);
	$text =~ /setInsecure\s*\(/ || $text =~ /InsecureDeckTcpClient/
} @firmware;
is_deeply(\@insecure, [], 'no board disables certificate verification')
	or diag("still insecure: " . join(', ', map { my $p = $_; $p =~ s{^\Q$root\E/+}{}; $p } @insecure));

# --- 2. the same house CA is embedded for all three boards -----------------
my @projects = (
	{ dir => 'jp/alarmclock', index => 'jp/alarmclock/alarmclock.ino', board => 'pico' },
	{ dir => 'jt',            index => 'jt/jt.ino',                    board => 'esp32' },
	{ dir => 'jw',            index => 'jw/jw.ino',                    board => 'esp32' },
);

my %header_for;
for my $project (@projects) {
	my $index = slurp_path($project->{'index'});
	like($index, qr/^\s*#include\s*[<"]house_ca\.h[>"]/m,
		"$project->{'dir'} includes the house CA header");

	my $ini = slurp_path("$project->{'dir'}/platformio.ini");
	my ($flag) = $ini =~ /^\s*-I(\S*firmware)\s*$/m;
	ok($flag, "$project->{'dir'} puts the header's directory on the include path") or next;
	my $dir = abs_path("$root/$project->{'dir'}/$flag");
	ok($dir && -e "$dir/house_ca.h", "$project->{'dir'} resolves to firmware/house_ca.h");
	$header_for{$project->{'dir'}} = "$dir/house_ca.h" if $dir;
}
is(scalar keys %header_for, 3, 'all three projects resolve a CA header');

my @paths = sort values %header_for;
my $header = @paths ? slurp_path_abs($paths[0]) : '';
for my $path (@paths[1 .. $#paths]) {
	is(slurp_path_abs($path), $header, 'the CA header is identical across projects');
}

sub slurp_path_abs {
	my ($path) = @_;
	return scalar read_file($path);
}

# --- 3. the PEM parses as the house CA -------------------------------------
my ($macro) = $header =~ /#define\s+HOUSE_CA_PEM\s*(.*?)\n#endif/s;
ok($macro, 'HOUSE_CA_PEM is defined');

my @chunks = $macro =~ /"((?:[^"\\]|\\.)*)"/g;
ok(scalar @chunks > 3, 'the macro is a C string across several lines');
is_deeply([ grep { $_ ne 'n' } $macro =~ /\\(.)/g ], [],
	'every escape in the macro is a literal newline');
like($chunks[-1] // '', qr/\\n\z/, 'the macro ends with a newline');

my $pem = join '', @chunks;
$pem =~ s/\\n/\n/g;
like($pem, qr/\A-----BEGIN CERTIFICATE-----\n/, 'the macro starts a PEM certificate');
like($pem, qr/\n-----END CERTIFICATE-----\n\z/, 'and closes it');
unlike($pem, qr/\n\n/, 'no line was concatenated without its newline');

my ($body) = $pem =~ /-----BEGIN CERTIFICATE-----\n(.*?)-----END CERTIFICATE-----/s;
my $der = decode_base64($body // '');
ok(length $der > 300, 'the PEM body decodes to certificate bytes');
is(ord(substr($der, 0, 1)), 0x30, 'and starts with an ASN.1 SEQUENCE');

my $openssl = `command -v openssl 2>/dev/null`;
chomp $openssl;
my $tmp = tempdir(CLEANUP => 1);
my $pem_file = "$tmp/house-ca.pem";
write_file($pem_file, $pem);

SKIP: {
	skip 'openssl is not installed', 2 unless length $openssl && -x $openssl;
	my $subject = `$openssl x509 -in '$pem_file' -noout -subject 2>&1`;
	is($? >> 8, 0, 'the embedded PEM parses as a certificate') or diag($subject);
	like($subject, qr/CN\s*=\s*JawnOS House CA/, 'and it is the JawnOS house CA');
}

# The checkout's own CA is the strongest check, but a worktree has no server/
# directory (it is gitignored), so it is compared only where it exists.
my $live_ca = "$root/server/house-ca.pem";
if (-e $live_ca) {
	SKIP: {
		skip 'openssl is not installed', 1 unless length $openssl && -x $openssl;
		my $want = `$openssl x509 -in '$live_ca' -outform DER 2>/dev/null`;
		is($der, $want, 'the embedded CA is server/house-ca.pem');
	}
}
else {
	ok(1, 'no server/house-ca.pem here; the PEM shape and the three copies are checked instead');
}

# --- 4. the right API per board --------------------------------------------
my $pico = join '', map { slurp_path("jp/alarmclock/$_") }
	qw(alarmclock.ino alarmclock_01_globals_clock_ble.ino
	   alarmclock_04_jobs_clock_config_net.ino alarmclock_05_device_ws.ino);
like($pico, qr/BearSSL::X509List\s+house_ca_list\s*\(\s*HOUSE_CA_PEM\s*\)/,
	'the Pico builds a BearSSL anchor list from the embedded CA');
my $anchors = () = $pico =~ /setTrustAnchors\s*\(\s*&house_ca_list\s*\)/g;
is($anchors, 3, 'and applies it to all three Pico house clients');
unlike($pico, qr/setCACert/, 'the Pico uses BearSSL anchors, not the ESP32 API');

for my $pair (['jt', 6], ['jw', 4]) {
	my ($name, $want) = @$pair;
	my $src = join '', map { scalar read_file($_) } glob("$root/$name/*.ino");
	my $calls = () = $src =~ /setCACert\s*\(\s*HOUSE_CA_PEM\s*\)/g;
	is($calls, $want, "$name pins the house CA at every house client");
	unlike($src, qr/setTrustAnchors/, "$name uses setCACert, not the BearSSL API");
}

my $deck = slurp_path('jt/jt_01_globals_ble_house.ino');
like($deck, qr/class\s+HouseCaDeckTcpClient\s*:\s*public\s+websockets::network::SecuredEsp32TcpClient/,
	'the deck socket client is named for CA verification');
like($deck, qr/std::make_shared<HouseCaDeckTcpClient>\(\)/,
	'and the socket is built over it');
unlike($deck, qr/InsecureDeckTcpClient/, 'the old insecure client is gone');

# The diagnostic follows the configured homebase and still verifies TLS.
my $setup = slurp_path('jt/jt_03_setup.ino');
like($setup, qr/tls\.setCACert\(HOUSE_CA_PEM\)/, 'the netcheck TLS probe verifies the house CA');
like($setup, qr/probe_host = homebaseIP\.substring\(0, home_split\)/,
	'and probes the configured homebase, not only the old LAN');

# --- 5. the listeners present the house-CA leaf ----------------------------
my $president = slurp_path('perl/President.pl');
like($president, qr/my \$device_certs = \$peer_certs ne '' \? \$peer_certs : \$certs;/,
	'the device doors use the peer pair with the main certificate as fallback');

my ($expr) = $president =~ /my \$device_certs = (.+?);/;
my $pick = sub {
	my ($peer_certs, $certs) = @_;
	return eval $expr;
};
is($pick->('', 'MAIN'), 'MAIN', 'no peer pair falls back to the main certificate');
is($pick->('PEER', 'MAIN'), 'PEER', 'a peer pair is served on the device doors');

my $watch_doors = () = $president =~ /'https:\/\/\*:' \. \$watch_port \. \$device_certs/g;
is($watch_doors, 2, 'both watch listeners (development and production) use the device pair');
my $ws_doors = () = $president =~ /'https:\/\/\*:' \. \$ws_port \. \$device_certs/g;
is($ws_doors, 2, 'both socket listeners (development and production) use the device pair');
my $teletype_doors = () = $president =~ /'https:\/\/\*:' \. \$tty_port \. \$device_certs/g;
is($teletype_doors, 2, 'both teletype listeners use the device pair (the deck reads its Info room there)');
my $ws_teletype_doors = () = $president =~ /'https:\/\/\*:' \. \$ws_tty_port \. \$device_certs/g;
is($ws_teletype_doors, 2, 'both teletype socket listeners use the device pair');

like($president, qr/my \@dev_main_listeners = \('https:\/\/\*:' \. \$port \. \$certs,/,
	'the development main listener keeps the public certificate');
like($president, qr/\[ 'https:\/\/\*:' \. \$port \. \$certs \],\s*purpose => 'main', name => 'Pro Main Server'/s,
	'the production main listener keeps the public certificate');
my $dock_doors = () = $president =~ /'https:\/\/\*:' \. \$dock_port \. \$certs/g;
is($dock_doors, 2, 'the dock/ticket listeners keep the public certificate');
like($president, qr/'https:\/\/\*:' \. \$alarm_port \. \$certs/,
	'the alarm listener keeps the public certificate');
my $peer_doors = () = $president =~ /'https:\/\/\*:' \. \$peer_port \. \$peer_certs/g;
is($peer_doors, 2, 'the peer listeners still serve the peer pair directly');

done_testing();
