# tests-for: lib/JawnOS/Domain/Devicews.pm lib/JawnOS/Controller/manager_ws.pm lib/JawnOS/Domain/Loader.pm jp/alarmclock/alarmclock_05_device_ws.ino
# covers:    The board's clock, taught over the socket it already holds. A Pico
#            runs on its own crystal between /watch/time calls, and a drift of
#            tens of seconds stamped a switch's session in the past and made
#            "now" a guess. The manager sends the house's epoch milliseconds on
#            attach and every two minutes; the board sets its clock from the
#            frame and answers with the millis() and epoch it now believes, which
#            the manager reports as a skew.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

use JawnOSTest;

ok(subs::provides('device_ws_time_frame'), 'the loader maps the time frame');
ok(subs::provides('device_ws_clock_note'), 'and the answer');

my $frame = subs::device_ws_time_frame(1794174000123);
is_deeply($frame, { t => 'time', ms => 1794174000123 },
	'the frame is the house clock in milliseconds');

my $now = subs::rightNow();
my $auto = subs::device_ws_time_frame();
ok(defined $auto->{'ms'} && $auto->{'ms'} >= $now, 'no argument means now');

is(subs::device_ws_clock_note('chip1', { epoch_ms => $now - 40000 }), 1,
	'a board that answers is measured');
is(subs::device_ws_clock_note('chip1', {}), 0, 'a frame with no clock is not a measurement');
is(subs::device_ws_clock_note('chip1', { epoch_ms => ' 0' }), 0, 'nor is a clockless " 0"');

my $route = read_file(root() . '/lib/JawnOS/Controller/manager_ws.pm');
like($route, qr/device_ws_time_frame/, 'the socket tells the board the time');
like($route, qr/Mojo::IOLoop->recurring\(120/, 'and again every two minutes');
like($route, qr/Mojo::IOLoop->remove\(\$clock_timer\)/, 'the timer is cancelled when the socket ends');
like($route, qr/\$t eq 'millis'/, 'the board\'s answer is handled');

my $fw = read_file(root() . '/jp/alarmclock/alarmclock_05_device_ws.ino');
like($fw, qr/else if \(t == "time"\)/, 'the board understands a time frame');
like($fw, qr/set_epoch_ms\(house \+ off \* 1000\)/, 'and sets its clock from it, timezone folded back in');
like($fw, qr/\\"millis\\"/, 'the answer is a millis frame');
like($fw, qr/\\"epoch_ms\\"/, 'carrying the clock it now believes');

done_testing();
