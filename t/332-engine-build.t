# tests-for: scripts/build_engine.pl engine/
# covers:    P1 (docs/studio-audio-roadmap.md): the engine is optional, so its build script must say
#            "missing" rather than fail, must name a missing toolchain instead of a shell error, and
#            must stage a binary that runs the null device and passes the crate's own tests.

use strict;
use warnings;

use Cwd qw(abs_path);
use Errno qw(ETXTBSY);
use Fcntl qw(O_WRONLY);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Select;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

my $root   = abs_path("$FindBin::Bin/..");
my $script = "$root/scripts/build_engine.pl";

# Run a command, capturing both streams. The third handle must be a real glob
# (an undef lexical reads as false, which makes open3 merge stderr and never
# create it), and both pipes are drained together so a chatty child cannot fill
# one and block.
sub capture {
	my @cmd = @_;
	my $err = gensym;
	my $pid = open3( my $in, my $out, $err, @cmd );
	close $in;
	my $select = IO::Select->new( $out, $err );
	my $stdout = '';
	my $stderr = '';
	while ( $select->count ) {
		my @ready = $select->can_read(60);
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

# Run a copy of the script under its own root: the script resolves the
# repository from its own path, so a tempdir copy can be asked both ways
# without ever staging into the checkout.
sub run_in {
	my ( $dir, @args ) = @_;
	return capture( $^X, "$dir/scripts/build_engine.pl", @args );
}

sub fixture {
	my $dir = tempdir( CLEANUP => 1 );
	make_path( "$dir/scripts", "$dir/engine", "$dir/perl/audio" );
	copy( $script, "$dir/scripts/build_engine.pl" ) or die "copy: $!";
	open( my $man, '>', "$dir/engine/Cargo.toml" ) or die "$dir/engine/Cargo.toml: $!";
	print {$man} "[package]\nname = \"fixture\"\nversion = \"0.0.0\"\nedition = \"2021\"\n";
	close $man;
	return $dir;
}

# A cargo stand-in: it never compiles anything. `--version` answers, and
# `build` drops a runnable shell script where cargo would put the binary, so a
# test can exercise staging without paying for a real Rust build.
sub fake_cargo {
	my ($dir) = @_;
	my $path = "$dir/fake-cargo";
	open( my $fh, '>', $path ) or die "$path: $!";
	print {$fh} <<'SH';
#!/bin/sh
if [ "$1" = "--version" ]; then
	echo "cargo 0.0.0 (fake)"
	exit 0
fi
if [ "$1" = "test" ]; then
	exit 0
fi
if [ "$1" = "build" ]; then
	profile=debug
	for arg in "$@"; do
		[ "$arg" = "--release" ] && profile=release
	done
	if [ -z "$CARGO_TARGET_DIR" ]; then
		echo "fake cargo: CARGO_TARGET_DIR is unset" >&2
		exit 1
	fi
	mkdir -p "$CARGO_TARGET_DIR/$profile" || exit 1
	bin="$CARGO_TARGET_DIR/$profile/jawn-audio"
	printf '#!/bin/sh\necho "fake-engine-%s"\n' "$profile" > "$bin" || exit 1
	chmod 0755 "$bin" || exit 1
	exit 0
fi
echo "fake cargo: unsupported: $*" >&2
exit 1
SH
	close $fh;
	chmod( 0755, $path ) or die "chmod $path: $!";
	return $path;
}

# A scratch copy of the real crate, never the checkout's own target/.
sub copy_tree {
	my ( $from, $to ) = @_;
	make_path($to);
	opendir( my $dh, $from ) or die "$from: $!";
	my @names = sort grep { $_ ne '.' && $_ ne '..' && $_ ne 'target' } readdir $dh;
	closedir $dh;
	foreach my $name (@names) {
		my $src = "$from/$name";
		my $dst = "$to/$name";
		if ( -d $src ) { copy_tree( $src, $dst ); next }
		next unless -f $src;
		copy( $src, $dst ) or die "$src: $!";
	}
	return 1;
}

sub cargo_available {
	my $pid = open( my $fh, '-|', 'cargo', '--version' );
	return 0 unless $pid;
	<$fh>;
	close $fh;
	return $? == 0 ? 1 : 0;
}

# --- --check, both ways ------------------------------------------------------
{
	my $dir = fixture();
	my ( $status, $out ) = run_in( $dir, '--check' );
	is( $status, 1, '--check says the engine is missing when it is not staged' );
	like( $out, qr/^missing: .*jawn-audio/m, 'and names the path it expects' );
	ok( !-e "$dir/perl/audio/jawn-audio", '--check builds nothing' );

	open( my $stage, '>', "$dir/perl/audio/jawn-audio" ) or die $!;
	print {$stage} "#!/bin/sh\nexit 0\n";
	close $stage;
	chmod( 0755, "$dir/perl/audio/jawn-audio" );

	( $status, $out ) = run_in( $dir, '--check' );
	is( $status, 0, '--check accepts a staged binary' );
	like( $out, qr/^built: /m, 'and reports it as built' );
}

# --- no toolchain is an ordinary answer, not a shell error -------------------
{
	my $dir  = fixture();
	my $gone = File::Spec->catfile( $dir, 'no-such-cargo' );
	my ( $status, $out, $err );
	{
		local $ENV{'CARGO'} = $gone;
		( $status, $out, $err ) = run_in($dir);
	}
	isnt( $status, 0, 'a build with no toolchain fails' );
	like( $out . $err, qr/no cargo/, 'and says the engine is optional' );
	ok( !-e "$dir/perl/audio/jawn-audio", 'and stages nothing' );
}

# --- --debug stages the unoptimised profile ---------------------------------
{
	my $dir   = fixture();
	my $cargo = fake_cargo($dir);
	my $ware  = tempdir( CLEANUP => 1 );
	local $ENV{'CARGO'}            = $cargo;
	local $ENV{'CARGO_TARGET_DIR'} = $ware;

	my ( $status, $stdout, $stderr ) = run_in( $dir, '--debug' );
	is( $status, 0, '--debug builds' ) or diag( $stdout . $stderr );
	ok( -x "$dir/perl/audio/jawn-audio", 'and stages a binary' );
	like( $stdout, qr/^built: /m, 'and says built: with the path' );

	my ( $ran, $text ) = capture("$dir/perl/audio/jawn-audio");
	is( $ran, 0, 'the staged binary runs' );
	like( $text, qr/fake-engine-debug/, 'and came from the debug profile' );
}

# --- staging over a running engine ------------------------------------------
{
	my $dir   = fixture();
	my $cargo = fake_cargo($dir);
	my $ware  = tempdir( CLEANUP => 1 );
	my $out   = "$dir/perl/audio/jawn-audio";

	# A real executable, not a shell script: exec'ing a script does not hold
	# the image's write lock, and ETXTBSY (the bug that hit `table`) needs an
	# executing image. sleep is tiny and everywhere; perl is the fallback.
	my $live = -x '/bin/sleep'   ? '/bin/sleep'
	         : -x '/usr/bin/sleep' ? '/usr/bin/sleep'
	         :                       $^X;
	copy( $live, $out ) or die "copy $live: $!";
	chmod( 0755, $out ) or die "chmod $out: $!";
	my $before = ( stat $out )[1];

	my $pid = fork();
	die "fork: $!" unless defined $pid;
	if ( !$pid ) {
		my @args = $live eq $^X ? ( '-e', 'select undef, undef, undef, 5' ) : ('5');
		exec { $out } $out, @args;
		exit 127;
	}

	# The image is executing exactly when open-for-write returns ETXTBSY, which
	# is the condition the old copy() died on.
	my $locked = 0;
	for ( 1 .. 200 ) {
		if ( sysopen( my $fh, $out, O_WRONLY ) ) {
			close $fh;
			select( undef, undef, undef, 0.01 );
			next;
		}
		$locked = $! == ETXTBSY ? 1 : 0;
		last;
	}

	SKIP: {
		skip 'could not get the destination executing here', 7 unless $locked;

		local $ENV{'CARGO'}            = $cargo;
		local $ENV{'CARGO_TARGET_DIR'} = $ware;
		my ( $status, $stdout, $stderr ) = run_in($dir);
		is( $status, 0, 'staging over a running engine succeeds' )
			or diag( $stdout . $stderr );
		like( $stdout, qr/^built: .*jawn-audio/m, 'and still prints built: with the path' );

		my @staged = stat $out;
		is( $staged[2] & 07777, 0755, 'the staged binary keeps mode 0755' );
		isnt( $staged[1], $before, 'and is a new inode, not an in-place rewrite' );
		ok( -x $out, 'and is executable' );

		my ( $ran, $text ) = capture($out);
		is( $ran, 0, 'and runs' );
		like( $text, qr/fake-engine-release/, 'as the newly staged release build' );
	}

	kill 'TERM', $pid;
	waitpid( $pid, 0 );

	# The temp is consumed by the rename, never left beside the binary.
	opendir( my $dh, "$dir/perl/audio" ) or die "$dir/perl/audio: $!";
	my @left = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
	closedir $dh;
	is_deeply( \@left, ['jawn-audio'], 'and leaves no temp file behind' );
}

# --- --if-stale builds only when engine/ moved ------------------------------
{
	my $dir   = fixture();
	my $cargo = fake_cargo($dir);
	my $ware  = tempdir( CLEANUP => 1 );
	my $out   = "$dir/perl/audio/jawn-audio";
	make_path("$dir/engine/src");
	open( my $src, '>', "$dir/engine/src/lib.rs" ) or die $!;
	print {$src} "pub fn fixture() {}\n";
	close $src;

	local $ENV{'CARGO'}            = $cargo;
	local $ENV{'CARGO_TARGET_DIR'} = $ware;

	my ( $status, $stdout, $stderr ) = run_in( $dir, '--if-stale' );
	is( $status, 0, '--if-stale builds when nothing is staged' ) or diag( $stdout . $stderr );
	like( $stdout, qr/^built: /m, 'and says built: with the path' );
	ok( -x $out, 'and stages a binary' );
	my $first = ( stat $out )[1];

	( $status, $stdout, $stderr ) = run_in( $dir, '--if-stale' );
	is( $status, 0, '--if-stale accepts the binary it just staged' ) or diag( $stdout . $stderr );
	like( $stdout, qr/^fresh: /m, 'and says fresh: rather than building again' );
	is( ( stat $out )[1], $first, 'and leaves the same binary in place' );

	my $future = time + 30;
	utime( $future, $future, "$dir/engine/src/lib.rs" ) or die "utime: $!";
	( $status, $stdout, $stderr ) = run_in( $dir, '--if-stale' );
	is( $status, 0, '--if-stale builds after an engine source changes' ) or diag( $stdout . $stderr );
	like( $stdout, qr/^built: /m, 'and reports the new build' );
	isnt( ( stat $out )[1], $first, 'and stages a new binary' );
}

# --- the real crate builds, stages and runs ---------------------------------
SKIP: {
	skip 'no cargo toolchain on this machine', 7 unless cargo_available();

	my $dir  = fixture();
	my $ware = tempdir( CLEANUP => 1 );
	copy_tree( "$root/engine", "$dir/engine" );
	local $ENV{'CARGO_TARGET_DIR'} = $ware;

	my ( $status, $out, $err ) = run_in($dir);
	is( $status, 0, 'the engine builds' ) or diag( $out . $err );
	ok( -x "$dir/perl/audio/jawn-audio", 'and the binary is staged executable' );
	like( $out, qr/^built: /m, 'and the script says where' );

	my $bin = "$dir/perl/audio/jawn-audio";
	my ( $ran, $text, $prose ) = capture(
		$bin, '--run', '--seconds', '0.1', '--rate', '48000', '--frames', '64',
		'--tone', '440', '--json'
	);
	is( $ran, 0, 'the null device runs' ) or diag($prose);
	like( $text, qr/"device":"null"/, 'and names the null device' );
	like( $text, qr/"blocks":75/, 'and counts its blocks' );

	# The crate's own tests are the only guard on the graph and the header, so
	# the suite runs them too rather than trusting a manual `cargo test`. The
	# app voices (synth, drums) are workspace members and their tests run here
	# too, so a DSP crate is never a file the suite skips.
	# One test thread: the CLI tests spawn the binary and measure timing, and
	# under the suite's own load even four let them starve each other. The
	# serial crate run is slower but deterministic; a real failure still fails.
	my ( $tcode, $ttext, $terr ) = capture(
		'cargo', 'test', '--offline', '--workspace', '--manifest-path',
		"$dir/engine/Cargo.toml", '--', '--test-threads=1'
	);
	is( $tcode, 0, q{the crate's own tests pass} ) or diag( $ttext . $terr );
}

# --- a monitor that underruns queues the lead again ------------------------
# The listen loop writes one block per capture read, so a recovery leaves the
# ring empty and the lead the open queued is gone. Without it every later block
# underruns too: `table` sat in that state on 2026-11-24 - hundreds of hw_ptr
# resets a minute, heard as a 500 Hz buzz (one 96-frame block is 2 ms) - and no
# gain, cable or headphone change touched it.
{
	open( my $alsa_fh, '<', "$root/engine/src/alsa_device.rs" ) or die "alsa_device.rs: $!";
	local $/;
	my $alsa = <$alsa_fh>;
	close $alsa_fh;

	like( $alsa, qr/fn prime_and_start_with\(\s*playback: &Stream,\s*io: &alsa::pcm::IO<'_, i16>,\s*device: &str,/s,
		'the lead can be queued through the IO a monitor already holds' );
	like( $alsa, qr/Ok\(\(\)\) => \{\s*xruns \+= 1;[\s\S]{0,900}?underrun = true;[\s\S]{0,80}?break;/,
		'a playback recovery marks the monitor starved' );
	like( $alsa, qr/if underrun \{\s*prime_and_start_with\(&playback, &playback_io, device\)\?;/,
		'and the next pass queues the lead again before it reads a block' );
}

done_testing();
