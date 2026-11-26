# tests-for: engine/src/usb_device.rs engine/src/lib.rs engine/src/oboe_device.rs engine/src/control.rs
# covers:    the direct-USB (usbfs) backend: the kernel structs and ioctl numbers
#            match arm64, the pure monitor/histogram/report helpers and their Rust
#            unit tests run on a host with no phone, the C ABI `jawn_audio_start_usb`
#            is additive, the take owns one process-wide control slot shared with
#            the Oboe take, and the driver leaks (never frees) an URB the kernel
#            still owns and never closes Java's fd. The real device path is proven
#            on the UM2 gate, so this test is the host half.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use FindBin;
use IO::Select;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

my $root = abs_path("$FindBin::Bin/..");

# Run a command, capturing both streams together so a chatty child cannot fill
# one pipe and block.
sub capture {
	my @cmd = @_;
	my $err = gensym;
	my $pid = open3( my $in, my $out, $err, @cmd );
	close $in;
	my $select = IO::Select->new( $out, $err );
	my $stdout = '';
	my $stderr = '';
	while ( $select->count ) {
		my @ready = $select->can_read(240);
		last unless @ready;
		for my $handle (@ready) {
			my $read = sysread( $handle, my $chunk, 65536 );
			if ( !defined $read || $read == 0 ) { $select->remove($handle); next }
			if ( fileno($handle) == fileno($out) ) { $stdout .= $chunk }
			else { $stderr .= $chunk }
		}
	}
	close $out;
	close $err;
	waitpid( $pid, 0 );
	return ( $? >> 8, $stdout, $stderr );
}

sub cargo_available {
	my $pid = open( my $fh, '-|', 'cargo', '--version' );
	return 0 unless $pid;
	<$fh>;
	close $fh;
	return $? == 0 ? 1 : 0;
}

# --- the pure logic runs on a machine with no phone --------------------------
SKIP: {
	skip 'no cargo toolchain on this machine', 5 unless cargo_available();

	my $target = tempdir( CLEANUP => 1 );
	local $ENV{'CARGO_TARGET_DIR'} = $target;

	my ( $status, $out, $err ) = capture(
		'cargo', 'test', '--offline', '--manifest-path', "$root/engine/Cargo.toml",
		'--lib', 'usb_device::tests'
	);
	is( $status, 0, 'the usb_device unit tests pass with no feature and no phone' )
		or diag( $out . $err );
	like( $out . $err, qr/test result: ok/, 'the harness reports a clean run' );
	like(
		$out,
		qr/usb_device::tests::the_ioctl_numbers_match_the_ioc_derivation/,
		'ioctl numbers are checked against the _IOC derivation'
	);
	like(
		$out,
		qr/usb_device::tests::the_out_fifo_drops_the_oldest_and_pads_an_underrun/,
		'the monitor pad/drop helper is exercised'
	);
	like(
		$out,
		qr/usb_device::tests::the_report_json_escapes_the_take_and_plan/,
		'and the report JSON escaping'
	);
}

# --- the source carries the device contract --------------------------------
my $usb = do {
	open( my $fh, '<', "$root/engine/src/usb_device.rs" ) or die "usb_device.rs: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	$text;
};

my $oboe = do {
	open( my $fh, '<', "$root/engine/src/oboe_device.rs" ) or die "oboe_device.rs: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	$text;
};

my $lib = do {
	open( my $fh, '<', "$root/engine/src/lib.rs" ) or die "lib.rs: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	$text;
};

my $control = do {
	open( my $fh, '<', "$root/engine/src/control.rs" ) or die "control.rs: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	$text;
};

# The ABI is additive and exact: the app passes the fd and both endpoints.
like(
	$usb,
	qr/pub unsafe extern "C" fn jawn_audio_start_usb\(/,
	'the C ABI adds a USB start'
);
like(
	$usb,
	qr/fd: i32,\s*iface_in: i32,\s*alt_in: i32,\s*ep_in: i32,\s*packet_in: i32,\s*iface_out: i32,\s*alt_out: i32,\s*ep_out: i32,\s*packet_out: i32,\s*seconds: f64,\s*out_path: \*const c_char,\s*plan: \*const c_char,/s,
	'with the fd, both endpoints, seconds, a take path and a plan'
);
like( $usb, qr/extern "C" fn jawn_audio_start_usb/, 'and it is #[no_mangle] through that name' );
like( $usb, qr/have_out/, 'ep_out < 0 is capture-only' );
like( $usb, qr/crate::plan::parse_plan/, 'the plan is read exactly as the Oboe start reads it' );

# Only the syscall glue is gated, so the structs and pure helpers compile here.
like( $usb, qr/#\[cfg\(target_os = "android"\)\]/, 'the syscall glue is Android-only' );
like( $usb, qr/extern "C" \{\s*pub\(super\) fn ioctl\(fd: c_int, request: c_ulong, \.\.\.\) -> c_int;/s,
	'the ioctl is declared directly; no rusb dependency' );
unlike( $usb, qr/^\s*(?:pub\s+)?use\s+rusb|rusb\s*=|\brusb::/m, 'the module never depends on a libusb binding' );
unlike( $usb, qr/libc::close|fn close\(/, 'the driver never closes the fd Java owns' );
like( $usb, qr/std::mem::forget/, 'an URB the kernel still owns is leaked, never freed' );
like( $usb, qr/USBDEVFS_DISCARDURB/, 'in-flight URBs are discarded before the free' );
like( $usb, qr/USBDEVFS_REAPURBNDELAY/, 'reaping is non-blocking' );
like( $usb, qr/USBDEVFS_SUBMITURB/, 'and submission is the direct ioctl' );
like( $usb, qr/sched_setscheduler\(0, SCHED_FIFO, &param\)/, 'the USB thread asks for SCHED_FIFO' );
like( $usb, qr/priority: SCHED_PRIORITY/, 'at the documented priority' );

# The ioctl numbers and the kernel layouts, exactly as the arm64 header has them.
like( $usb, qr/pub const USBDEVFS_CONTROL: u64 = 0xC018_5500;/, 'CONTROL is 0xC0185500' );
like( $usb, qr/pub const USBDEVFS_SETINTERFACE: u64 = 0x8008_5504;/, 'SETINTERFACE is 0x80085504' );
like( $usb, qr/pub const USBDEVFS_SUBMITURB: u64 = 0x8038_550A;/, 'SUBMITURB is 0x8038550A' );
like( $usb, qr/pub const USBDEVFS_DISCARDURB: u64 = 0x0000_550B;/, 'DISCARDURB is 0x0000550B' );
like( $usb, qr/pub const USBDEVFS_REAPURBNDELAY: u64 = 0x4008_550D;/, 'REAPURBNDELAY is 0x4008550D' );
like( $usb, qr/pub const USBDEVFS_CLAIMINTERFACE: u64 = 0x8004_550F;/, 'CLAIMINTERFACE is 0x8004550F' );
like( $usb, qr/pub const USBDEVFS_RELEASEINTERFACE: u64 = 0x8004_5510;/, 'RELEASEINTERFACE is 0x80045510' );
like( $usb, qr/pub const USBDEVFS_URB_TYPE_ISO: u8 = 0;/, 'iso is type 0, not 1' );
like( $usb, qr/pub const USBDEVFS_URB_ISO_ASAP: u32 = 0x02;/, 'and ISO_ASAP is 0x02' );
like( $usb, qr/assert!\(std::mem::size_of::<UsbdevfsIsoPacketDesc>\(\) == 12\)/, 'the packet desc is 12 bytes');
like( $usb, qr/assert!\(std::mem::size_of::<UsbdevfsUrb>\(\) == 56\)/, 'the URB header is 56 bytes');
like( $usb, qr/assert!\(std::mem::size_of::<UsbdevfsCtrlTransfer>\(\) == 24\)/, 'the control transfer is 24 bytes');
like( $usb, qr/assert!\(std::mem::size_of::<UsbdevfsSetInterface>\(\) == 8\)/, 'the set-interface struct is 8 bytes');

# The driver's fixed shape: 4 URBs of 8 packets, one ring for the record and one
# for the monitor, and the report's counters.
like( $usb, qr/const URB_COUNT: usize = 4;/, 'four URBs in flight' );
like( $usb, qr/const PACKETS_PER_URB: usize = 8;/, 'eight 1 ms packets each' );
like( $usb, qr/const OUT_BACKLOG_FRAMES: usize = 96;/, 'the monitor backlog is bounded at 96 frames' );
like( $usb, qr/record\.push\(/, 'capture feeds the record ring' );
like( $usb, qr/monitor\.push\(/, 'and the monitor ring' );
like( $usb, qr/\\"packets_in\\":\{\}/, 'the report carries the packet-length histogram' );
like( $usb, qr/\\"missed_in\\":\{\}/, 'the missed-frame count' );
like( $usb, qr/\\"underruns_out\\":\{\}/, 'the playback underruns' );
like( $usb, qr/\\"dropped_out\\":\{\}/, 'the playback drops' );
like( $usb, qr/\\"setinterface\\":\{\{\\"ret\\":\{\},\\"errno\\":\{\}\}\}/, 'the set-interface result' );
like( $usb, qr/\\"sched\\":\{\{\\"policy\\":\{\},\\"priority\\":\{\},\\"errno\\":\{\}\}\}/, 'and the scheduling answer' );
like( $usb, qr/\\"frames_captured\\":\{\}/, 'the take counters' );
like( $usb, qr/\\"frames_written\\":\{\}/, 'including the WAV count' );
like( $usb, qr/\\"dropped_ring\\":\{\}/, 'the ring split' );
like( $usb, qr/\\"dropped_disk\\":\{\}/, 'and the disk split' );

# One control slot, and the USB take reuses the Oboe drain rather than copying
# the strip/disk policy.
like( $lib, qr/^pub mod usb_device;$/m, 'lib.rs exports the usb_device module' );
like( $lib, qr/^pub\(crate\) mod control;$/m, 'and one shared control module' );
like( $usb, qr/use crate::control::\{/, 'the USB ABI locks the shared control slot' );
like( $oboe, qr/use crate::control::\{/, 'the Oboe ABI locks the same slot' );
unlike( $oboe, qr/^\s*struct Control\s*\{/m, 'the Oboe module no longer keeps a second slot' );
like( $oboe, qr/^pub\(crate\) fn drain_ring\(/m, 'the Oboe drain is shared' );
like( $usb, qr/crate::oboe_device::drain_ring/, 'and the USB take calls it' );
like( $control, qr/pub\(crate\) struct Control/, 'the slot is defined once in control.rs' );

done_testing();
