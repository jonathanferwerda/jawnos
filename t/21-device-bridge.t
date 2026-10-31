use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use JSON::PP;
use Time::HiRes qw(time);
use JawnOSTest;
use MIME::Base64 ();

# M1 device bridge (docs/leaving-termux.md): subs::device_call speaks one JSON
# line to the host app and returns its `result`; on every failure it returns
# undef so the caller can fall back to the termux command. The fake app below is
# the protocol contract, and DeviceService.java implements the same lines.

my $TOKEN = 'spike-token-123';
# A stand-in for a PNG: the point is that the bytes survive base64, not that
# they decode as an image.
my $PNG = "\x89PNG\r\n\x1a\n" . 'thumbnail-bytes';
my $dir = tempdir(CLEANUP => 1);
my $token_file = "$dir/device.token";
open(my $tf, '>', $token_file) or die $!;
print $tf "$TOKEN\n";
close $tf;
chmod 0600, $token_file;

my $listen = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 8, ReuseAddr => 1,
) or die "listen: $!";
my $port = $listen->sockport;
my $pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) {
	$SIG{TERM} = sub { exit 0 };
	while (my $c = $listen->accept) {
		my $line;
		while (defined($line = <$c>)) {
			my $req = eval { decode_json($line) } || {};
			my %reply = (id => $req->{'id'} // 0, ok => JSON::PP::false);
			if (($req->{'token'} // '') ne $TOKEN) {
				$reply{'error'} = 'denied';
			}
			elsif (($req->{'method'} // '') eq 'ping') {
				$reply{'ok'} = JSON::PP::true;
				$reply{'result'} = { app => 'fake', sdk => 36 };
			}
			elsif (($req->{'method'} // '') eq 'battery.status') {
				$reply{'ok'} = JSON::PP::true;
				$reply{'result'} = {
					present => 1, percentage => 42, voltage => 4300,
					temperature => 31.2, current => -350000,
					current_average => -300000, status => 'DISCHARGING',
					health => 'GOOD', plugged => 'UNPLUGGED',
				};
			}
			elsif (($req->{'method'} // '') eq 'media.thumbnail') {
				my $args = $req->{'args'} || {};
				if (($args->{'path'} // '') =~ /refuse/) {
					$reply{'error'} = 'no thumbnail';
				}
				else {
					$reply{'ok'} = JSON::PP::true;
					$reply{'result'} = {
						data => MIME::Base64::encode_base64($PNG, ''),
						width => 200, height => 150, kind => 'video',
					};
				}
			}
			else {
				$reply{'error'} = 'unknown method';
			}
			print $c encode_json(\%reply) . "\n";
		}
		close $c;
	}
	exit 0;
}
close $listen;   # the parent needs no listener of its own

$ENV{'JAWNOS_DEVICE_TOKEN'} = $token_file;
$ENV{'JAWNOS_DEVICE_BRIDGE_PORT'} = $port;
$subs::device_bridge_memo = undef;
$subs::device_bridge_sock = undef;

my $ping = subs::device_call('ping');
ok(ref $ping eq 'HASH' && ($ping->{'app'} // '') eq 'fake',
	'a bridge call returns the app result');

my $battery = subs::device_call('battery.status');
is(ref $battery, 'HASH', 'battery.status returns a hash');
is($battery->{'percentage'}, 42, 'the result carries the app numbers');

# The app can hand back a thumbnail (M3): the route asks for one before it
# spawns ffmpeg | magick, and a desktop - with no bridge - gets undef and keeps
# the pipeline.
my $thumb = subs::device_thumbnail('/some/film.mp4', 200);
ok(defined $thumb && length $thumb, 'a thumbnail comes back from the app');
is($thumb, $PNG, 'and it is the bytes the app sent, not a re-encoded copy');
is(subs::device_thumbnail('/some/refuse.mp4', 200), undef, 'a refusal falls back to the pipeline');
is(subs::device_thumbnail('', 200), undef, 'an empty path asks nobody');

# A refusal is not a transport failure: undef now, and the bridge stays usable.
open(my $wrong, '>', $token_file) or die $!;
print $wrong "not-the-token\n";
close $wrong;
is(subs::device_call('ping'), undef, 'a wrong token is refused');

open(my $right, '>', $token_file) or die $!;
print $right "$TOKEN\n";
close $right;
ok(ref subs::device_call('ping') eq 'HASH', 'the bridge stays usable after a refusal');

is(subs::device_call('no.such.method'), undef, 'an unknown method falls back');

# No bridge at all: undef, quickly, and then without even trying for a while.
kill 'TERM', $pid;
waitpid($pid, 0);
$subs::device_bridge_sock = undef;
$subs::device_bridge_memo = undef;

my $t0 = time();
is(subs::device_call('battery.status'), undef, 'no bridge returns undef');
ok(time() - $t0 < 2, 'the failure is quick');

my $memo_start = time();
is(subs::device_call('battery.status'), undef, 'the next call is refused from the memo');
ok(time() - $memo_start < 0.2, 'the memo answers without a connect');

unlink $token_file;
$subs::device_bridge_memo = undef;
is(subs::device_call('ping'), undef, 'no token file means no bridge');

done_testing();
