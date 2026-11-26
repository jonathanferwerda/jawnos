# tests-for: engine/src/usb_device.rs engine/src/lib.rs engine/src/oboe_device.rs engine/src/control.rs
# covers:    the direct-USB (usbfs) backend: the kernel structs and ioctl numbers
#            match arm64, the pure monitor/histogram/report helpers and their Rust
#            unit tests run on a host with no phone, the shallow OUT depth and its
#            priming threshold, the direct on-thread monitor fifo (no cross-thread
#            ring) with its high-water trim and observed fill counters, the OUT
#            pipeline's two-URB floor so a refill never leaves the device unfed,
#            the absorb-before-refill ordering, the cadence counters (out_frames,
#            capture_ms, out_ms, out_lag_ms), the poll-driven reap, the configurable
#            1..=8 depth and its two ABIs (`jawn_audio_set_usb_depth`,
#            `jawn_audio_roundtrip_usb`), the bus-frame segment table and click
#            placement of the latency probe, the playback GET_CUR rate probe,
#            the SET_CUR/GET_CUR playback-rate sequence (endpoint recipient, an
#            interface fallback, and no success without a readback), the 48 -> 32
#            monitor resample when the endpoint refuses 48 kHz while the capture
#            stays at 48 kHz, the
#            C ABI `jawn_audio_start_usb` is additive, the take owns one
#            process-wide control slot shared with the Oboe take, and the driver
#            leaks (never frees) an URB the kernel still owns and never closes
#            Java's fd. The real device path is proven on the UM2 gate, so this
#            test is the host half.

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
	skip 'no cargo toolchain on this machine', 18 unless cargo_available();

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
	like(
		$out,
		qr/usb_device::tests::the_out_depth_is_its_own_and_the_monitor_runway_is_eight_ms/,
		'the monitor keeps its own shallow OUT depth'
	);
	like(
		$out,
		qr/usb_device::tests::the_monitor_priming_threshold_is_the_whole_out_depth/,
		'and is primed before the first OUT submit'
	);
	like(
		$out,
		qr/usb_device::tests::the_depth_clamps_to_one_through_eight_and_keeps_the_default/,
		'the depth clamps to 1..=8 and the landed default is kept'
	);
	like(
		$out,
		qr/usb_device::tests::the_priming_threshold_follows_the_configured_depth/,
		'priming and the fifo scale with every configured depth'
	);
	like(
		$out,
		qr/usb_device::tests::the_segment_table_maps_an_offset_to_a_fractional_bus_frame/,
		'the bus-frame segment table counts a 49-frame packet'
	);
	like(
		$out,
		qr/usb_device::tests::the_click_fills_six_packets_and_the_rest_is_silence/,
		'and the chirp lands in six packets with silence after it'
	);
	like(
		$out,
		qr/usb_device::tests::the_roundtrip_report_carries_the_bus_frame_measurement/,
		'the round-trip report names its method and precision'
	);
	like(
		$out,
		qr/usb_device::tests::the_monitor_fifo_trims_at_its_high_water_at_every_depth/,
		'the direct monitor fifo trims at its high water at every depth'
	);
	like(
		$out,
		qr/usb_device::tests::absorbing_the_completed_capture_before_refilling_removes_the_start_underrun/,
		'absorbing the capture before refilling removes the start underrun'
	);
	like(
		$out,
		qr/usb_device::tests::the_out_pipeline_primes_and_refills_two_urbs/,
		'two OUT URBs are primed and the second stays in flight during a refill'
	);
	like(
		$out,
		qr/usb_device::tests::the_cadence_counters_expose_a_starved_out_stream/,
		'and the cadence counters show a starved OUT stream as lag'
	);
	like(
		$out,
		qr/usb_device::tests::the_rate_target_comes_from_the_packet_and_is_encoded_little_endian/,
		'the rate target follows the packet and is encoded little-endian'
	);
	like(
		$out,
		qr/usb_device::tests::the_monitor_resampler_turns_48k_into_32k_without_a_shortfall/,
		'the monitor is resampled 48 kHz -> 32 kHz without a shortfall'
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
like(
	$usb,
	qr/pub unsafe extern "C" fn jawn_audio_set_usb_depth\(/,
	'the depth is process-wide and settable through its own ABI'
);
like(
	$usb,
	qr/pub unsafe extern "C" fn jawn_audio_roundtrip_usb\(/,
	'and the direct-USB round trip has its own blocking ABI'
);
like( $usb, qr/const DEPTH_MIN: i32 = 1;/, 'the depth floor is one packet' );
like( $usb, qr/const OUT_URBS_MIN: i32 = 2;/, 'but the OUT pipeline never runs with one URB in flight' );
like( $usb, qr/out_urbs: out_urbs\.clamp\(OUT_URBS_MIN, DEPTH_MAX\)/, 'the setter clamps out_urbs to the floor' );
like( $usb, qr/out_urbs_effective/, 'the setter reports the effective OUT URBs' );
like( $usb, qr/fn cadence\(/, 'the take measures its OUT cadence' );
like( $usb, qr/out_lag_ms: capture_ms as i64 - out_ms as i64/, 'as capture time minus playback time' );
like( $usb, qr/const DEPTH_MAX: i32 = 8;/, 'and its ceiling eight' );
like( $usb, qr/fn current_depth\(\) -> UsbDepth/, 'a take reads the process-wide depth once at start' );
like( $usb, qr/fn prime_frames\(self, frames_per_packet: usize\) -> usize/, 'priming follows the configured depth' );
like( $usb, qr/\\"in_depth\\":/, 'the take report gains in_depth' );
like( $usb, qr/\\"out_depth\\":/, 'and out_depth' );
like( $usb, qr/\\"in_delivery_ms\\":/, 'and the IN delivery window' );
like( $usb, qr/fn frame_at_offset\(/, 'the probe maps a capture offset to a bus frame' );
like( $usb, qr/\\"probe\\":\\"roundtrip\\"/, 'its report names the probe' );
like( $usb, qr/\\"heard_frame\\":/, 'with both bus frames' );
like( $usb, qr/MIN_SCORE/, 'a missed click still reports the correlation floor' );
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
like( $usb, qr/const OUT_URB_COUNT: usize = 2;/, 'the monitor keeps two URBs of its own' );
like( $usb, qr/const OUT_PACKETS_PER_URB: usize = 4;/, 'four packets each: 8 ms of runway' );
like( $usb, qr/const PRIME_TIMEOUT_MS: u64 = 100;/, 'the warm-up is bounded' );
like( $usb, qr/sys::control_in\(/, 'the playback rate is probed with a class GET_CUR' );
like( $usb, qr/sys::control_out\(/, 'and set with a class SET_CUR, not only read' );
like( $usb, qr/fn set_playback_rate\(/, 'the take brings the endpoint to the packet\'s rate' );
like( $usb, qr/fn monitor_fallback_rate\(/, 'a refused rate falls back to the rate the endpoint can carry' );
like( $usb, qr/struct MonitorResampler/, 'the monitor is resampled, not the capture' );
like( $usb, qr/fn fill_packet_resampled\(/, 'each OUT packet reads the fifo at 48 kHz and writes the device rate' );
like( $usb, qr/fn fill_out_urb_with\(/, 'the take fills OUT through the resampler' );
like( $usb, qr/0x22u8, ep_out as u16, "endpoint"/, 'UAC1\'s endpoint recipient is tried first' );
like( $usb, qr/0x21u8, iface_out as u16, "interface"/, 'with the interface recipient as a fallback' );
like( $usb, qr/verified: false/, 'and a refusal is reported without claiming success' );
like( $usb, qr/\\"rate_set\\":\{\{\\"target\\":/, 'the take report carries the rate attempt' );
like( $usb, qr/\\"monitor_off\\":\{\}/, 'and why the monitor was left off' );
like( $usb, qr/monitor_runway_ms\(/, 'the report carries the monitor runway' );
like( $usb, qr/const OUT_BACKLOG_FRAMES: usize = 96;/, 'the monitor backlog is bounded at 96 frames' );
like( $usb, qr/record\.push\(/, 'capture feeds the record ring' );
like( $usb, qr/fifo\.push\(/, 'the monitor frames go straight into the loop\'s own fifo' );
unlike( $usb, qr/MONITOR_RING_FRAMES|monitor_producer/, 'there is no cross-thread monitor ring' );
like( $usb, qr/fn monitor_high_water\(/, 'the fifo trims at a high water, not its capacity' );
like( $usb, qr/fn monitor_fifo_capacity\(/, 'and is sized for the prime plus both bursts' );
like( $usb, qr/fn wait_for_reap\(/, 'the loop waits with poll rather than a fixed sleep' );
like( $usb, qr/sys::wait_reap\(/, 'and reaps as soon as the fd signals' );
like( $usb, qr/monitor_fill_max_ms/, 'the report carries the observed maximum fill' );
like( $usb, qr/monitor_fill_avg_ms/, 'and the average fill' );
like( $usb, qr/fifo_capacity_ms/, 'the fifo capacity in ms' );
like( $usb, qr/high_water_ms/, 'and its high water in ms' );
like( $usb, qr/out_frames/, 'the report carries the OUT frames submitted' );
like( $usb, qr/capture_ms/, 'the capture duration' );
like( $usb, qr/out_ms/, 'the playback duration' );
like( $usb, qr/out_lag_ms/, 'and the continuity gap between them' );
like( $usb, qr/\\"packets_in\\":\{\}/, 'the report carries the packet-length histogram' );
like( $usb, qr/\\"missed_in\\":\{\}/, 'the missed-frame count' );
like( $usb, qr/\\"underruns_out\\":\{\}/, 'the playback underruns' );
like( $usb, qr/\\"underruns_out_start\\":\{\}/, 'split into warm-up and starvation' );
like( $usb, qr/\\"dropped_out\\":\{\}/, 'the playback drops' );
like( $usb, qr/\\"out_packets\\":\{\}/, 'the monitor packets' );
like( $usb, qr/\\"out_bytes\\":\{\}/, 'and their bytes' );
like( $usb, qr/\\"monitor_ms\\":\{\}/, 'the monitor runway' );
like( $usb, qr/\\"out_rate\\":\{\{\\"ret\\":\{\},\\"errno\\":\{\},\\"raw\\":\\"\{\}\\",\\"hz\\":\{\}\}\}/, 'and the endpoint rate probe' );
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
