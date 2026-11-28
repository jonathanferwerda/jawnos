# tests-for: jw/jw_05_loop2.ino jw/jw_03_setup.ino jw/jw_08_voice.ino
# covers:    A now_me that arrives late must not walk the watch's clock back, on
#            either the BLE or the HTTP path: a queued push moved it minutes into
#            the past, and every clip's stamp was then refused as older than its
#            toggle. The WiFi clip POST records its heap and TLS error and retries
#            a refused connect once before the clip falls back to BLE.

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
my $voice = read_file(root() . '/jw/jw_08_voice.ino');

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

# --- the WiFi POST: a diagnosable, retried connect -------------------------
like($voice, qr/client\.lastError\(err, sizeof\(err\)\)/,
	'a refused POST reports the TLS error');
like($voice, qr/for \(int attempt = 1; attempt <= 2/,
	'and retries a refused connect once before falling back to BLE');
like($voice, qr/f\.seek\(0, SeekSet\)/,
	'rewinding the clip for the retry');
like($voice, qr/\[voice\] post mode=%s heap free=%u max=%u/,
	'the heap is on the record at the POST');
like($voice, qr/\[voice\] com stream heap free=%u max=%u/,
	'and at the streamed upload');
unlike($voice, qr/setBufferSizes/,
	'no setBufferSizes: the core the watch builds against has no such call');

done_testing();
