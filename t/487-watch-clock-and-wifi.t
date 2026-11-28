# tests-for: jw/jw_05_loop2.ino jw/jw_03_setup.ino jw/jw_06_net_face.ino jw/jw_07_house_audio.ino jw/jw_08_voice.ino jw/jw_13_serial_lowpower.ino
# covers:    A now_me that arrives late must not walk the watch's clock back, on
#            either the BLE or the HTTP path: a queued push moved it minutes into
#            the past, and every clip's stamp was then refused as older than its
#            toggle. The system clock (what TLS validates the house leaf against)
#            is copied from the RTC chip before any house connection, so a clock
#            still in 1970 cannot refuse the 2026 certificate. The WiFi clip POST
#            records its heap and TLS error and retries a refused connect once.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

use JawnOSTest;

my $ble   = read_file(root() . '/jw/jw_05_loop2.ino');
my $http  = read_file(root() . '/jw/jw_03_setup.ino');
my $net   = read_file(root() . '/jw/jw_06_net_face.ino');
my $house = read_file(root() . '/jw/jw_07_house_audio.ino');
my $voice = read_file(root() . '/jw/jw_08_voice.ino');
my $serial = read_file(root() . '/jw/jw_13_serial_lowpower.ino');

# --- the forward-only clock guard, on both now_me paths --------------------
for my $case ([ 'BLE', $ble ], [ 'HTTP', $http ]) {
	my ($name, $src) = @{$case};
	like($src, qr/long clock_now = timestamp_maker\(\);/,
		"$name now_me reads the clock before applying");
	like($src, qr/timestamp \+ 60 >= clock_now/,
		"$name now_me applies a time only when it does not go back");
	like($src, qr/stale now_me time ignored/,
		"$name now_me says when it refused one");
	my $guard = index($src, 'timestamp + 60 >= clock_now');
	my $set = index($src, 'rtc.setTime(timestamp);');
	ok($guard > 0 && $set > 0 && $guard < $set,
		"$name: the guard is tested before the clock is written");
}

# --- the C library's clock is set before TLS -------------------------------
like($house, qr/static void clock_sync_system\(\)/,
	'a helper copies the chip time into the C library’s clock');
like($house, qr/settimeofday\(&tv, NULL\)/,
	'which is what mbedTLS reads when it validates the leaf');
like($house, qr/clock_sync_system\(\);\s*\n\s*struct tm local_tm/, 
	'and it runs before clock_apply_to_face can rewrite the chip');
for my $case ([ 'the GET path', $net ], [ 'the POST path', $voice ]) {
	my ($name, $src) = @{$case};
	like($src, qr/clock_sync_system\(\);/, "$name syncs the system clock before TLS");
}
like($voice, qr/\[voice\] post mode=%s tls=%s sys=%ld/,
	'a failed POST names the TLS error and the clock it used');
like($serial, qr/offset %ld \| sys=%ld/,
	'and the console time probe shows the C library clock too');

# --- the WiFi POST: a diagnosable, retried connect -------------------------
like($voice, qr/client\.lastError\(err, sizeof\(err\)\)/,
	'a refused POST reports the TLS error');
like($voice, qr/for \(int attempt = 1; attempt <= 2/,
	'and retries a refused connect once before falling back to BLE');
like($voice, qr/f\.seek\(0, SeekSet\)/,
	'rewinding the clip for the retry');
like($voice, qr/\[voice\] post mode=%s host=%s local=%s heap free=%u max=%u/,
	'the POST records the target host and the watch\'s own address, so a split network is obvious');
like($voice, qr/\[voice\] com stream host=%s local=%s heap free=%u max=%u/,
	'and the streamed upload records the same pair');
like($voice, qr/https\.setConnectTimeout\(12000\)/,
	'the TCP connect deadline is raised too: setTimeout does not cover a busy listener');
unlike($voice, qr/setBufferSizes/,
	'no setBufferSizes: the core the watch builds against has no such call');

done_testing();
