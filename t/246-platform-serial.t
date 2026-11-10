# tests-for: lib/JawnOS/Platform/Serial.pm lib/JawnOS/Platform.pm lib/JawnOS/Manager/Part34.pm lib/JawnOS/Controller/manager_embedded.pm lib/JawnOS/Domain/Boardpins.pm
# covers:    the serial seam: the device set and its order (ttyACM before
#            ttyUSB, each sorted, an empty tree is []), the shape check a port
#            must pass, the exact stty argv, the open's read-write handle, the
#            64-byte/4 ms paced write, the 8 s deadline read, and that Part34,
#            manager_embedded and Boardpins now use the seam while the pio
#            upload argv stays what it was.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use Time::HiRes ();

use JawnOS::Platform::Serial qw(
	devices valid_port prepare open_read write_paced read_until baud
);
use JawnOS::Platform ();

my $scratch = tempdir(CLEANUP => 1);
my $root = "$FindBin::Bin/..";

# --- the one baud, the pacing and the deadline ------------------------------
is(baud(), 115200, 'the shared default speed is 115200');
is($JawnOS::Platform::Serial::PACING_CHUNK, 64, 'a paced write uses 64-byte pieces by default');
is($JawnOS::Platform::Serial::PACING_DELAY_MS, 4, 'and pauses 4 ms between them');
is($JawnOS::Platform::Serial::READ_DEADLINE_SECONDS, 8, 'a reader waits 8 seconds by default');

# --- the device set and its order -------------------------------------------
my $dev = "$scratch/root/dev";
make_path($dev);
write_file("$dev/$_", '') for qw(ttyUSB2 ttyACM10 ttyACM0 ttyUSB10);

is_deeply(devices("$scratch/root"), [
	"$dev/ttyACM0", "$dev/ttyACM10",
	"$dev/ttyUSB10", "$dev/ttyUSB2",
], 'ttyACM comes first, and each pattern is sorted lexicographically');

is_deeply(devices("$scratch/no-such-tree"), [], 'a tree with no device is an empty list');
is_deeply(devices(), JawnOS::Platform::serial_devices(),
	'Platform::serial_devices is the seam, not a second enumeration');

is_deeply([ JawnOS::Platform::Serial::_device_patterns('linux', '') ],
	[ '/dev/ttyACM*', '/dev/ttyUSB*' ], 'Linux keeps the two tty patterns');
is_deeply([ JawnOS::Platform::Serial::_device_patterns('darwin', '') ],
	[ '/dev/cu.usbmodem*', '/dev/cu.usbserial*' ], 'macOS keeps its cu patterns');
is_deeply([ JawnOS::Platform::Serial::_device_patterns('MSWin32', '') ],
	[], 'Windows answers no devices until its backend lands');
is_deeply([ JawnOS::Platform::Serial::_device_patterns('linux', "$scratch/root/") ],
	[ "$scratch/root/dev/ttyACM*", "$scratch/root/dev/ttyUSB*" ],
	'a root makes the patterns testable without a serial device');

# --- valid_port -------------------------------------------------------------
for my $good (qw(/dev/ttyACM0 /dev/ttyACM12 /dev/ttyUSB0 /dev/ttyUSB9)) {
	ok(valid_port($good), "$good is a port we can drive");
}
for my $bad (undef, '', '/dev/ttyACM', '/dev/ttyUSB', '/dev/ttyS0',
	'/dev/ttyACM0x', '/dev/cu.usbmodem1101', 'COM3',
	'/dev/../dev/ttyACM0', "/dev/ttyACM0\n") {
	ok(!valid_port($bad), defined $bad ? "'$bad' is refused" : 'an undef port is refused');
}

# --- prepare runs the exact stty argv ---------------------------------------
sub write_exe {
	my ($path, $body) = @_;
	write_file($path, "#!/bin/sh\n$body\n");
	chmod 0755, $path;
}
my $stty_log = "$scratch/stty.log";
write_file($stty_log, '');
my $ok_bin = "$scratch/bin-ok";
my $fail_bin = "$scratch/bin-fail";
make_path($ok_bin, $fail_bin);
write_exe("$ok_bin/stty", 'printf "%s\n" "$*" >> "$SERIAL_STTY_LOG"; exit 0');
write_exe("$fail_bin/stty", 'printf "%s\n" "$*" >> "$SERIAL_STTY_LOG"; exit 1');

{
	local $ENV{'PATH'} = "$ok_bin:$ENV{'PATH'}";
	local $ENV{'SERIAL_STTY_LOG'} = $stty_log;
	ok(prepare('/dev/ttyACM0'), 'prepare succeeds when stty does');
	ok(prepare('/dev/ttyUSB7', 57600), 'and takes an explicit speed');
}
is(read_file($stty_log),
	"-F /dev/ttyACM0 raw 115200 -echo\n-F /dev/ttyUSB7 raw 57600 -echo\n",
	'stty got the same argv both readers ran');

{
	local $ENV{'PATH'} = "$fail_bin:$ENV{'PATH'}";
	local $ENV{'SERIAL_STTY_LOG'} = $stty_log;
	ok(!prepare('/dev/ttyACM0'), 'a failing stty is false, not a die');
}

# --- open_read ---------------------------------------------------------------
my $port_file = "$scratch/port.txt";
write_file($port_file, "console\n");
my $fh = open_read($port_file);
ok($fh, 'open_read opens a port read-write');
is(scalar readline($fh), "console\n", 'the handle reads');
print {$fh} "JAWNPINS?\n";
close $fh;
is(read_file($port_file), "console\nJAWNPINS?\n", 'and the same handle writes');
ok(!defined open_read("$scratch/no-such-port"), 'a missing port is undef, not a die');

# --- write_paced keeps the chunk size and the pause -------------------------
{
	package SerialCapture;
	sub TIEHANDLE { my ($class) = @_; return bless { chunks => [] }, $class }
	sub PRINT { my ($self, @rest) = @_; push @{ $self->{'chunks'} }, join('', @rest); return 1 }
	sub CLOSE { return 1 }
}

tie *CHUNKS, 'SerialCapture';
is(write_paced(*CHUNKS, 'abcdef', 2, 0), 6, 'write_paced reports the bytes it was given');
is_deeply(tied(*CHUNKS)->{'chunks'}, [ 'ab', 'cd', 'ef' ],
	'it writes the requested 2-byte pieces in order');
untie *CHUNKS;

tie *DEFAULT_CHUNKS, 'SerialCapture';
is(write_paced(*DEFAULT_CHUNKS, 'y' x 65), 65, 'the default call writes the whole line');
is_deeply(tied(*DEFAULT_CHUNKS)->{'chunks'}, [ 'y' x 64, 'y' ],
	'the default chunk is 64 bytes');
untie *DEFAULT_CHUNKS;

tie *PACED, 'SerialCapture';
my $t0 = Time::HiRes::time();
write_paced(*PACED, 'z' x 128, 64, 50);
my $elapsed = Time::HiRes::time() - $t0;
cmp_ok($elapsed, '>=', 0.09, 'the delay is a real pause between pieces');
untie *PACED;

# --- read_until --------------------------------------------------------------
my $pins = "$scratch/pins.txt";
write_file($pins, "booting\r\nJAWNPINS {\"chip\":\"F130\"}\r\n");
my $in = open_read($pins);
my $buf = read_until($in, qr/JAWNPINS\s*\{/, time() + 2);
close $in;
like($buf, qr/JAWNPINS \{/, 'read_until stops on the reply and returns the buffer');

my $plain = "$scratch/plain.txt";
write_file($plain, "no report here\n");
$in = open_read($plain);
is(read_until($in, qr/JAWNPINS/, time() + 2), "no report here\n",
	'a reader that never matches returns what arrived before EOF');
close $in;

pipe(my $reader, my $writer);
is(read_until($reader, qr/anything/, time() - 1), '',
	'a deadline already past returns at once');
close $reader;
close $writer;

pipe(my $wait_reader, my $wait_writer);
$t0 = Time::HiRes::time();
is(read_until($wait_reader, qr/anything/, time() + 0.05), '',
	'a silent port is an empty answer at the deadline');
cmp_ok(Time::HiRes::time() - $t0, '>=', 0.2, 'the poll interval is 0.25 s, as before');
close $wait_reader;
close $wait_writer;

# --- the call sites went through the seam -----------------------------------
my $source = sub { scalar read_file("$root/$_[0]") };
my $platform = $source->('lib/JawnOS/Platform.pm');
like($platform, qr/^use JawnOS::Platform::Serial \(\);$/m,
	'Platform.pm requires the seam');
like($platform, qr/return JawnOS::Platform::Serial::devices\(\);/,
	'serial_devices delegates to it');

my $part34 = $source->('lib/JawnOS/Manager/Part34.pm');
unlike($part34, qr/ls \/dev\/ttyACM/, 'Part34 no longer shells out to ls');
unlike($part34, qr/glob\('\/dev\/tty(?:ACM|USB)\*'\)/, 'and no longer globs the ports itself');
like($part34, qr/JawnOS::Platform::Serial::devices\(\)/,
	'both the panel list and usb_ports_grabber use the seam');

my $embedded = $source->('lib/JawnOS/Controller/manager_embedded.pm');
unlike($embedded, qr/system\('stty'/, 'the provisioning action no longer runs stty itself');
unlike($embedded, qr/IO::Select->new/, 'and no longer keeps its own select loop');
for my $line (
	'JawnOS::Platform::Serial::valid_port($port)',
	'JawnOS::Platform::Serial::prepare($port)',
	'JawnOS::Platform::Serial::open_read($port)',
	'JawnOS::Platform::Serial::write_paced($fh, $line, 64, 4)',
	'JawnOS::Platform::Serial::read_until($fh, qr/JAWNCFG (?:OK|ERR)/, time() + 8)',
) {
	ok(index($embedded, $line) >= 0, "manager_embedded uses $line");
}
like($embedded, qr/run -j 4 -e ' \. \$environment \. ' -t upload --upload-port ' \. \$port/,
	'the pio upload argv is unchanged');

my $boardpins = $source->('lib/JawnOS/Domain/Boardpins.pm');
unlike($boardpins, qr/system\('stty'/, 'the pins reader no longer runs stty itself');
unlike($boardpins, qr/IO::Select->new/, 'and no longer keeps its own select loop');
for my $line (
	'JawnOS::Platform::Serial::valid_port($port)',
	'JawnOS::Platform::Serial::prepare($port)',
	'JawnOS::Platform::Serial::open_read($port)',
	'JawnOS::Platform::Serial::read_until($fh, qr/JAWNPINS\s*\{/, time() + 8)',
) {
	ok(index($boardpins, $line) >= 0, "Boardpins uses $line");
}

done_testing();
