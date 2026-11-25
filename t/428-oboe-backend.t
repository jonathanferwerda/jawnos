# tests-for: engine/src/backends.rs engine/src/main.rs engine/src/lib.rs engine/src/oboe_device.rs engine/Cargo.toml scripts/build_engine.pl
# covers:    docs/studio-oboe-slice.md §2.8: the no-feature contract. `--backends --json`
#            names all five backends and says `oboe:false` when the feature is off; the
#            prose says why; `--backend oboe --run` exits 2 with the rebuild sentence;
#            `--help` and `--check` name Oboe; and the Android path of the build script
#            refuses a missing NDK in a sentence instead of a shell error. The real Oboe
#            stream cannot open on Linux, so §9's on-device checks stand in for it.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Select;
use IPC::Open3 qw(open3);
use JSON::PP qw(decode_json);
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
		my @ready = $select->can_read(120);
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

# --- the no-feature binary ---------------------------------------------------
my $bin;
SKIP: {
	skip 'no cargo toolchain on this machine', 1 unless cargo_available();

	my $target = tempdir( CLEANUP => 1 );
	local $ENV{'CARGO_TARGET_DIR'} = $target;

	my ( $status, $out, $err ) =
		capture( 'cargo', 'build', '--offline', '--manifest-path', "$root/engine/Cargo.toml" );
	is( $status, 0, 'the no-feature engine builds offline' ) or diag( $out . $err );
	$bin = File::Spec->catfile( $target, 'debug', 'jawn-audio' );
}

SKIP: {
	skip 'the no-feature binary was not built', 16
		unless defined $bin && -x $bin;

	my ( $json_status, $json_line, $json_err ) = capture( $bin, '--backends', '--json' );
	is( $json_status, 0, '--backends --json exits 0' ) or diag($json_err);

	my $doc = eval { decode_json($json_line) };
	ok( $doc, 'the one line parses as JSON' ) or diag("json: $json_line / error: $@");
	if ($doc) {
		is_deeply(
			[ sort keys %$doc ],
			[ sort qw(alsa pipewire jack oboe null) ],
			'exactly the five backend keys'
		);
		ok( $doc->{null}, 'null is true on every machine' );
		ok( !$doc->{oboe}, 'oboe is false in a build without the feature' );
		like( $json_line, qr/"oboe":false/, 'and the JSON says so in words' );
		like( $json_line, qr/"null":true/, 'null is true in words too' );
	}

	my ( $prose_status, $prose ) = capture( $bin, '--backends' );
	is( $prose_status, 0, '--backends exits 0' );
	like(
		$prose,
		qr/^oboe: no \(built without --features oboe\)$/m,
		'the prose explains the missing feature'
	);

	my ( $check_status, $check ) = capture( $bin, '--check' );
	is( $check_status, 0, '--check exits 0' );
	like( $check, qr/\boboe no\b/, '--check and --backends agree about oboe' );

	my ( $help_status, $help ) = capture( $bin, '--help' );
	is( $help_status, 0, '--help exits 0' );
	like(
		$help,
		qr/--backend N\s+null \(default\), alsa, pipewire, jack or oboe/,
		'--help names oboe in the backend list'
	);

	my ( $run_status, $run_out, $run_err ) =
		capture( $bin, '--backend', 'oboe', '--run', '--seconds', '0.1' );
	is( $run_status, 2, '--backend oboe --run is a usage refusal' );
	like( $run_err, qr/rebuild with --features oboe/, 'and says how to get the backend' );
	is( $run_out, '', 'nothing is printed on stdout' );
}

# --- the Android path refuses a missing NDK in a sentence --------------------
{
	my $dir = tempdir( CLEANUP => 1 );
	make_path( "$dir/scripts", "$dir/engine" );
	copy( "$root/scripts/build_engine.pl", "$dir/scripts/build_engine.pl" )
		or die "copy: $!";
	open( my $man, '>', "$dir/engine/Cargo.toml" ) or die $!;
	print {$man} "[package]\nname = \"fixture\"\nversion = \"0.0.0\"\n";
	close $man;

	my $cargo = "$dir/fake-cargo";
	open( my $fh, '>', $cargo ) or die $!;
	print {$fh} "#!/bin/sh\necho 'cargo 0.0.0 (fake)'\nexit 0\n";
	close $fh;
	chmod( 0755, $cargo ) or die "chmod: $!";

	my $missing = File::Spec->catdir( $dir, 'no-such-ndk' );
	local $ENV{'CARGO'} = $cargo;
	my ( $status, $out, $err ) = capture(
		$^X, "$dir/scripts/build_engine.pl",
		'--android', '--ndk', $missing, '--out-dir', "$dir/jniLibs"
	);
	isnt( $status, 0, '--android without an NDK fails' );
	like( $out . $err, qr/no Android NDK at \Q$missing\E/, 'and names the NDK path' );
	like( $out . $err, qr/engine is optional/, 'and says the engine is optional' );
	ok( !-e "$dir/jniLibs/arm64-v8a/libjawn_audio.so", 'and stages nothing' );
}

# --- the Android link carries the C++ runtime -------------------------------
{
	open( my $script, '<', "$root/scripts/build_engine.pl" ) or die "build_engine.pl: $!";
	local $/;
	my $build = <$script>;
	close $script;
	my ($android_block) = $build =~ /^if \(\$android\) \{\n(.*?)^\}/ms;
	ok( $android_block, 'the build has an Android block' );
	like( $android_block, qr/CARGO_ENCODED_RUSTFLAGS/, 'the Android build sets encoded rustflags' );
	like( $android_block, qr/link-arg=-Wl,--no-as-needed/, 'and forces the C++ runtime into the link' );
	like( $android_block, qr/link-arg=-lc\+\+_shared/, 'and names libc++_shared' );
}

# --- the source keeps the feature out of the default build -------------------
{
	open( my $man, '<', "$root/engine/Cargo.toml" ) or die "Cargo.toml: $!";
	local $/;
	my $toml = <$man>;
	close $man;
	like( $toml, qr/crate-type\s*=\s*\["lib",\s*"cdylib"\]/, 'the crate is also a cdylib' );
	like(
		$toml,
		qr/^oboe\s*=\s*\{ version = "0\.6\.1", optional = true \}$/m,
		'oboe is pinned and optional'
	);
	like( $toml, qr/^oboe\s*=\s*\["dep:oboe"\]$/m, 'the feature turns the dependency on' );
	like( $toml, qr/^default\s*=\s*\[\]$/m, 'and the default build still carries no dependency' );

	open( my $jni, '<', "$root/engine/src/oboe_device.rs" ) or die "oboe_device.rs: $!";
	my $device = <$jni>;
	close $jni;
	like( $device, qr/extern "C" fn jawn_audio_start/, 'the C ABI has a start' );
	like( $device, qr/extern "C" fn jawn_audio_stop/, 'a stop' );
	like( $device, qr/extern "C" fn jawn_audio_status/, 'and a status' );
	like( $device, qr/extern "C" fn jawn_audio_backends/, 'and a backends report for the app page' );
	# Finding (a) of the first device gate: a take could be short of
	# frames_captured with nothing in the report saying so. The report now carries
	# both ends of the accounting and the honest overflow split.
	like( $device, qr/pub frames_written: u64/, 'the report carries the frames the WAV wrote' );
	like( $device, qr/pub dropped: u64/, 'and the total frames it did not write' );
	like( $device, qr/pub dropped_ring: u64/, 'split into ring overflow' );
	like( $device, qr/pub dropped_disk: u64/, 'and disk-queue overflow' );
	like(
		$device,
		qr/\\"frames_written\\":\{\}/,
		'report_json emits frames_written for the status line and sidecar'
	);
	like( $device, qr/\\"dropped\\":\{\}/, 'report_json emits the total dropped' );
	like( $device, qr/\\"dropped_ring\\":\{\}/, 'report_json emits the ring split' );
	like( $device, qr/\\"dropped_disk\\":\{\}/, 'report_json emits the disk split' );
	unlike( $device, qr/^\s*use jni/m, 'no jni dependency is needed' );
	like( $device, qr/set_direction::<Input>\(\)/, 'the first slice opens an input stream' );
	like(
		$device,
		qr/set_performance_mode\(PerformanceMode::LowLatency\)/,
		'low latency is requested'
	);
	like( $device, qr/set_channel_count::<Mono>\(\)/, 'mono is requested' );
	like( $device, qr/SharingMode::Exclusive/, 'exclusive is tried first' );
	like( $device, qr/SharingMode::Shared/, 'with a shared fallback' );
}

done_testing();
