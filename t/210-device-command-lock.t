# tests-for: lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Loader.pm
# covers:    One output command at a time per board. A Pico's WebServer services
#            one HTTP client, so two relay presses answered at once leave the
#            first half-answered and the second lost; the board looks wedged
#            until a physical switch wakes the link. Every forked sender takes a
#            per-chip file lock, and the OS releases it when the child exits.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use Fcntl qw(:flock O_RDWR);
use JawnOSTest;

my $tmp = tempdir('jawnos-device-lock-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$gb::tmp_dir = $tmp;

ok(subs::provides('device_command_lock'), 'the domain loader maps the lock helper');

my $first = subs::device_command_lock('TEST-CHIP');
ok($first, 'the first command takes the board lock');

my $file = $tmp . '/device_cmd/' . subs::path_name('TEST-CHIP') . '.lock';
ok(-f $file, 'the lock lives in the house tmp dir, named for the chip');

sysopen(my $probe, $file, O_RDWR) or die "sysopen: $!";
ok(!flock($probe, LOCK_EX | LOCK_NB),
	'a second sender cannot take the lock while the first holds it');

close $first;
ok(flock($probe, LOCK_EX | LOCK_NB),
	'closing the first handle releases the lock for the next command');
close $probe;

# A chip with no name has no lock to take: the sender still tries its roads.
ok(!defined subs::device_command_lock(''), 'an empty chip id does not lock anything');

done_testing();
