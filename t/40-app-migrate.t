use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use Digest::SHA qw(sha256_hex);

# scripts/app_migrate.pl (docs/leaving-termux.md, M4). The destructive path is
# driven entirely by one adb helper, so a fake adb on --adb lets these tests
# prove the order and the backup without a device:
#   - dry-run (and no --apply) prints the plan and destroys nothing;
#   - the backup MANIFEST has correct sha256s;
#   - a missing key file is a hard failure before force-stop;
#   - force-stop happens before any restore push;
#   - --apk and the newest-release default both resolve;
#   - the settings rewrite is skipped when nothing names the old prefix.
# It also covers the "apk must be the post-sharedUserId build" warning being
# non-fatal (the current staged build still declares it).

my $tmp    = tempdir( CLEANUP => 1 );
my $script = "$FindBin::Bin/../scripts/app_migrate.pl";
my $SERIAL = 'fakeserial';
my $run    = 0;

my $fake = <<'FAKE';
#!/bin/sh
log="${FAKE_ADB_LOG:?}"
root="${FAKE_ADB_ROOT:?}"
state="${FAKE_ADB_STATE:?}"
push="${FAKE_ADB_PUSH:?}"
trace="${FAKE_ADB_TRACE:?}"

printf '%s\n' "$*" >> "$log"

if [ "$1" = "-s" ]; then shift 2; fi
cmd="$1"; shift

runas() {
	pkg="$1"; shift
	sub="$1"; shift
	case "$sub" in
		pwd) echo "/data/user/0/$pkg" ;;
		test)
			flag="$1"; shift
			if [ -f "$root/$1" ]; then exit 0; else exit 1; fi ;;
		cat) cat "$root/$1" ;;
		ls) [ -e "$root/$1" ] || exit 1; echo "$1" ;;
		rm)
			while [ $# -gt 0 ]; do
				case "$1" in -f) shift; continue;; esac
				rm -f "$root/$1"
				shift
			done ;;
		chmod)
			shift
			[ $# -gt 0 ] && shift
			exit 0 ;;
		sha256sum)
			[ -f "$root/$1" ] || exit 1
			sha256sum "$root/$1" ;;
		files/usr/bin/pkill)
			rm -f "$state/tree_alive"
			exit 0 ;;
		files/usr/bin/pgrep)
			if [ -f "$state/tree_alive" ]; then echo "1234"; exit 0; fi
			exit 1 ;;
		cp)
			src="$1"; dst="$2"
			if [ "$dst" = "files/home/jawnos/database/jawnos.db" ] && [ -f "$state/corrupt_restore" ]; then
				echo "not the backup" > "$root/$dst"
			else
				cp "$push/$(basename "$src")" "$root/$dst"
			fi ;;
		files/usr/bin/sqlite3)
			db="$root/$1"; shift
			/usr/bin/sqlite3 "$db" "$@" ;;
		*) exit 1 ;;
	esac
}

case "$cmd" in
	devices) echo "List of devices attached" ;;
	shell)
		if [ $# -eq 1 ]; then eval "set -- $1"; fi
		sub="$1"; shift
		case "$sub" in
			getprop) echo "SM-X400" ;;
			dumpsys)
				if [ -f "$state/installed" ]; then
					echo "    versionCode=1215 minSdk=26"
					echo "    versionName=0.118.216"
				fi ;;
			am)
				action="$1"; shift
				while [ "$1" = "-W" ]; do shift; done
				case "$action" in
					force-stop) echo "force-stop $*" >> "$trace" ;;
					start)
						echo "start $*" >> "$trace"
						mkdir -p "$root/files/home/.president"
						echo "good" > "$root/files/home/.president/status" ;;
				esac ;;
			pm)
				action="$1"; shift
				case "$action" in
					disable-user) echo "disable-user $*" >> "$trace"; : > "$state/tree_alive"; : > "$state/disabled" ;;
					enable) echo "enable $*" >> "$trace"; rm -f "$state/disabled" ;;
				esac ;;
			cmd)
				echo "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false"
				echo "com.jawnos/.JawnUiLauncher" ;;
			run-as) runas "$@" ;;
			rm) exit 0 ;;
			*) exit 0 ;;
		esac ;;
	exec-out)
		shift; shift; shift
		cat "$root/$1" ;;
	push)
		cp "$1" "$push/$(basename "$2")" ;;
	uninstall)
		rm -f "$state/installed"
		echo "uninstall $*" >> "$trace" ;;
	install)
		echo "install $*" >> "$trace"
		: > "$state/installed" ;;
	*) exit 1 ;;
esac
exit 0
FAKE

sub slurp {
	my ($file) = @_;
	open( my $fh, '<', $file ) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text // '';
}

sub spew {
	my ( $file, $text ) = @_;
	my $dir = $file;
	$dir =~ s{/[^/]+$}{};
	make_path($dir) unless -d $dir;
	open( my $fh, '>', $file ) or die "$file: $!";
	print $fh $text;
	close $fh;
}

# A scenario is one fake device: its own rooted file tree, state and adb log.
sub scenario {
	my (%o) = @_;
	$run++;
	my $base = "$tmp/s$run";
	make_path( $base, "$base/bin", "$base/state", "$base/push", "$base/root" );
	my $adb = "$base/bin/adb";
	spew( $adb, $fake );
	chmod 0755, $adb or die $!;

	my $root  = "$base/root";
	my $state = "$base/state";
	my $push  = "$base/push";
	my $log   = "$base/adb.log";
	my $trace = "$base/adb.trace";
	open( my $lf, '>', $log ) or die $!;
	close $lf;
	open( my $tf, '>', $trace ) or die $!;
	close $tf;

	my @required = (
		'files/home/.house.key',
		'files/home/.peer.key',
		'files/home/.peer.pub',
		'files/home/.jawnos_signatorial_id',
		'files/home/jawnos/database/.jawnos_signatorial_id',
		'files/home/jawnos/config.json',
	);
	my %content = (
		'files/home/.house.key'                              => 'house-key-bytes',
		'files/home/.peer.key'                               => 'peer-key-bytes',
		'files/home/.peer.pub'                               => 'peer-pub-bytes',
		'files/home/.jawnos_signatorial_id'                  => 'e397332d0123456789abcdef01234567',
		'files/home/jawnos/database/.jawnos_signatorial_id'  => 'e397332d0123456789abcdef01234567',
		'files/home/jawnos/config.json'                      => '{"port":3000}',
		'files/home/jawnos/VERSION'                          => "0.1.1680\n",
		'files/home/jawnos/subroutines.pl'                   => 'subs',
		'files/home/jawnos/gb.pl'                            => 'gb',
		'files/home/jawnos/President.pl'                     => 'pres',
		'files/home/jawnos/Manager.pl'                       => 'mgr',
		'files/home/.president/status'                       => 'good',
		'files/usr/etc/jawnos-runtime.json'                  => '{"product":"runtime"}',
		'files/home/jawnos/database/schema.sql'              => 'CREATE TABLE x;',
		'files/home/jawnos/database/initial.enc'             => 'encrypted',
	);
	for my $rel (@required) {
		spew( "$root/$rel", $content{$rel} );
	}
	for my $rel (qw(
		files/home/jawnos/VERSION
		files/home/jawnos/subroutines.pl
		files/home/jawnos/gb.pl
		files/home/jawnos/President.pl
		files/home/jawnos/Manager.pl
		files/home/.president/status
		files/usr/etc/jawnos-runtime.json
		files/home/jawnos/database/schema.sql
		files/home/jawnos/database/initial.enc
	)) {
		spew( "$root/$rel", $content{$rel} );
	}
	unlink "$root/files/home/.house.key" if $o{missing_house_key};
	unlink "$root/files/home/jawnos/subroutines.pl" if $o{incomplete_tree};
	spew( "$state/tree_alive", '' ) unless $o{tree_down};
	spew( "$state/corrupt_restore", '' ) if $o{corrupt_restore};

	my @settings = @{ $o{settings} || [ '/data/data/com.jawnos/files/home', 'plain' ] };
	my $db = "$root/files/home/jawnos/database/jawnos.db";
	unlink $db;
	system(
		'sqlite3', $db,
		'CREATE TABLE appointments (id INTEGER PRIMARY KEY, app TEXT);'
		. 'CREATE TABLE settings (key TEXT, value TEXT);'
		. "INSERT INTO appointments (app) VALUES ('home'),('eczema'),('home');"
	) == 0 or die "sqlite3 create failed";
	for my $v (@settings) {
		$v =~ s/'/''/g;
		system( 'sqlite3', $db,
			"INSERT INTO settings (key,value) VALUES ('s','$v');" ) == 0
			or die "sqlite3 insert failed";
	}

	# The install is simulated: the fake writes this marker.
	spew( "$state/installed", '' ) unless $o{not_installed};

	return {
		base  => $base,
		adb   => $adb,
		root  => $root,
		state => $state,
		push  => $push,
		log   => $log,
		trace => $trace,
		db    => $db,
	};
}

sub run_migrate {
	my ( $s, @args ) = @_;
	local $ENV{'FAKE_ADB_LOG'}   = $s->{log};
	local $ENV{'FAKE_ADB_ROOT'}  = $s->{root};
	local $ENV{'FAKE_ADB_STATE'} = $s->{state};
	local $ENV{'FAKE_ADB_PUSH'}  = $s->{push};
	local $ENV{'FAKE_ADB_TRACE'} = $s->{trace};

	my @cmd = ( $^X, $script, '--device', $SERIAL, '--adb', $s->{adb}, @args );
	my $quoted = join ' ', map {
		my $a = $_;
		$a =~ s/'/'\\''/g;
		"'$a'"
	} @cmd;
	my $out = qx{$quoted 2>&1};
	my $rc  = $? >> 8;
	return ( $rc, $out );
}

sub destructive_lines {
	my ($s) = @_;
	my @lines = split /\n/, slurp( $s->{log} );
	my @bad;
	for my $line (@lines) {
		push @bad, $line
			if $line =~ /\buninstall\b/
			|| $line =~ /\binstall\s+\S+\.apk\b/
			|| $line =~ /\bam\s+force-stop\b/
			|| $line =~ /\bam\s+start\b/
			|| $line =~ /\bpm\s+disable-user\b/
			|| $line =~ /\bpush\s+\S+\s+\/data\/local\/tmp\b/
			|| $line =~ /\bfiles\/usr\/bin\/sqlite3\b/
			|| $line =~ /\bUPDATE\s+settings\b/;
	}
	return @bad;
}

# ---------------------------------------------------------------------------
# 1. dry-run prints the plan and runs no destructive command

{
	my $s = scenario();
	my $backup = "$s->{base}/backup-dry";
	my $apk = "$s->{base}/dry.apk";
	spew( $apk, 'fake apk bytes' );
	my ( $rc, $out ) = run_migrate( $s, '--dry-run', '--backup-dir', $backup, '--apk', $apk );
	is( $rc, 0, 'dry-run exits 0' );
	like( $out, qr/MODE: PLAN/, 'dry-run says it is a plan' );
	like( $out, qr/force-stop com\.jawnos/, 'the plan names the force-stop' );
	like( $out, qr/restore files\/home\/\.house\.key/, 'the plan names the identity restore' );
	like( $out, qr/\Q$apk\E/, 'the plan names the selected APK' );
	ok( length slurp( $s->{log} ) > 0, '--adb substituted the fake, which logged the read commands' );
	ok( !-e $backup, 'dry-run does not create the backup directory' );
	my @bad = destructive_lines($s);
	is( scalar @bad, 0, 'dry-run issued no destructive adb command' ) or diag(@bad);
}

# 2. no --apply also refuses to destroy

{
	my $s = scenario();
	my $backup = "$s->{base}/backup-none";
	my $apk = "$s->{base}/none.apk";
	spew( $apk, 'fake apk bytes' );
	my ( $rc, $out ) = run_migrate( $s, '--backup-dir', $backup, '--apk', $apk );
	is( $rc, 0, 'no --apply exits 0 (plan only)' );
	like( $out, qr/MODE: PLAN/, 'no --apply is a plan' );
	my @bad = destructive_lines($s);
	is( scalar @bad, 0, 'no --apply issued no destructive adb command' ) or diag(@bad);
	ok( !-e $backup, 'no --apply creates no backup' );
}

# 3. --apply and --dry-run together are refused

{
	my $s = scenario();
	my ( $rc, $out ) = run_migrate( $s, '--apply', '--dry-run', '--backup-dir', "$s->{base}/b" );
	isnt( $rc, 0, '--apply with --dry-run is refused' );
	like( $out, qr/mutually exclusive/, 'and says why' );
	is( slurp( $s->{log} ), '', 'refusal happens before any adb call' );
}

# 4. a real (simulated) migration: manifest, sha256, order and summary

my $apply_scenario;
{
	my $s = scenario();
	$apply_scenario = $s;
	my $apk = "$s->{base}/chosen.apk";
	spew( $apk, 'fake apk bytes' );
	my $backup = "$s->{base}/backup-apply";
	my ( $rc, $out ) = run_migrate( $s, '--apply', '--backup-dir', $backup, '--apk', $apk );
	is( $rc, 0, 'apply exits 0' ) or diag($out);
	like( $out, qr/MIGRATION PASS/, 'the summary says PASS' );
	like( $out, qr/integrity_check: ok/, 'the backup database passed integrity_check' );
	like( $out, qr/settings: no \/data\/data\/com\.termux paths; rewrite skipped/,
		'the rewrite is skipped when there is nothing to rewrite' );
	unlike( slurp( $s->{log} ), qr/UPDATE\s+settings/, 'no UPDATE ran for the clean database' );

	ok( -f "$backup/MANIFEST", 'MANIFEST was written' );
	my $manifest = slurp("$backup/MANIFEST");
	like( $manifest, qr/# format: sha256<TAB>size<TAB>path/, 'MANIFEST declares its format' );

	my %want = map { $_ => 1 } (
		'files/home/jawnos/database/jawnos.db',
		'files/home/jawnos/config.json',
		'files/home/.house.key',
		'files/home/.peer.key',
		'files/home/.peer.pub',
		'files/home/.jawnos_signatorial_id',
		'files/home/jawnos/database/.jawnos_signatorial_id',
	);
	my $rows = 0;
	for my $line ( split /\n/, $manifest ) {
		next if $line =~ /^#/ || $line eq '';
		my ( $sha, $size, $rel ) = split /\t/, $line;
		$rows++;
		ok( exists $want{$rel}, "MANIFEST lists $rel" ) if $want{$rel};
		my $file = "$backup/$rel";
		ok( -f $file, "$rel is in the backup" );
		is( -s $file, $size, "$rel size matches MANIFEST" );
		is( sha256_hex( slurp($file) ), $sha, "$rel sha256 matches MANIFEST" );
	}
	ok( $rows >= scalar( keys %want ), 'MANIFEST carries every required file' );

	# The explicit --apk is the one installed.
	like( slurp( $s->{log} ), qr/\binstall\s+\Q$apk\E/, '--apk chose the named APK' );

	# Restore order: a force-stop after the install and before the first push.
	my @lines = split /\n/, slurp( $s->{log} );
	my ( $install_at, $push_at, @stops );
	for my $i ( 0 .. $#lines ) {
		$install_at = $i if !defined $install_at && $lines[$i] =~ /\binstall\s+\S+\.apk\b/;
		$push_at    = $i if !defined $push_at    && $lines[$i] =~ /\bpush\s+\S+\s+\/data\/local\/tmp\b/;
		push @stops, $i if $lines[$i] =~ /\bam\s+force-stop\b/;
	}
	ok( defined $install_at && defined $push_at, 'the log has both an install and a restore push' );
	ok( ( grep { defined $install_at && defined $push_at && $_ > $install_at && $_ < $push_at } @stops ),
		'a force-stop runs after install and before any restore push' );

	# The stop has to be more than force-stop: the app is rebound by its system
	# services and the exec'd tree is not an ActivityManager process.
	like( slurp( $s->{log} ), qr/\bpm\s+disable-user\b/,
		'the stop disables the package so Android cannot rebind it' );
	like( slurp( $s->{log} ), qr/files\/usr\/bin\/pkill/,
		"the stop kills the exec'd perl tree" );
	like( slurp( $s->{log} ), qr/\bpm\s+enable\b/,
		'the app is re-enabled before the tree is started' );
	like( $out, qr/disabled and the tree is down/,
		'the script reports the successful stop' );
	like( $out, qr/sha256 matches the backup, integrity ok, 3 appointments/,
		'the restored database is verified before it is opened' );

	# The restored identity is the old one.
	like( $out, qr/device=e397332d\.\.\. unchanged/, 'the device identity did not change' );
	like( $out, qr/appointments 3 before, 3 after/, 'the appointment count is preserved' );
}

# 5. a missing required key is a hard failure before force-stop

{
	my $s = scenario( missing_house_key => 1 );
	my $backup = "$s->{base}/backup-missing";
	spew( "$s->{base}/x.apk", 'apk' );
	my ( $rc, $out ) = run_migrate( $s, '--apply', '--backup-dir', $backup, '--apk', "$s->{base}/x.apk" );
	isnt( $rc, 0, 'a missing key fails the migration' );
	like( $out, qr/missing required house key: files\/home\/\.house\.key/,
		'and names the missing key' );
	unlike( slurp( $s->{log} ), qr/\bam\s+force-stop\b/,
		'it fails before force-stop, while the app is still running' );
	unlike( slurp( $s->{log} ), qr/\buninstall\b/, 'it fails before uninstall' );
	ok( !-e $backup, 'it writes no partial backup' );
}

# 6. the rewrite runs when a setting does name the old prefix

{
	my $s = scenario( settings => [ '/data/data/com.termux/files/home/jawnos', 'plain' ] );
	my $backup = "$s->{base}/backup-rewrite";
	spew( "$s->{base}/x.apk", 'apk' );
	my ( $rc, $out ) = run_migrate( $s, '--apply', '--backup-dir', $backup, '--apk', "$s->{base}/x.apk" );
	is( $rc, 0, 'apply with an old-prefix setting exits 0' ) or diag($out);
	like( $out, qr/settings: 1 row\(s\) name the old com\.termux prefix; rewriting/,
		'the script says it is rewriting' );
	like( $out, qr/settings: rewrite complete, 0 old paths remain/,
		'and confirms no old paths remain' );
	my $value = qx{sqlite3 '$s->{db}' "SELECT value FROM settings WHERE key='s' LIMIT 1;"};
	chomp $value;
	is( $value, '/data/data/com.jawnos/files/home/jawnos',
		'the settings value now names com.jawnos' );
}

# 7. default APK resolution: the newest staged versionCode

{
	my $s = scenario();
	my $base = $s->{base};
	make_path("$base/bin", "$base/releases");
	copy( $script, "$base/bin/app_migrate.pl" ) or die $!;
	spew( "$base/releases/jawnos-app-1000-1.0.apk", 'old' );
	spew( "$base/releases/jawnos-app-1002-1.2.apk", 'new' );
	my $backup = "$base/backup-default";

	local $ENV{'FAKE_ADB_LOG'}   = $s->{log};
	local $ENV{'FAKE_ADB_ROOT'}  = $s->{root};
	local $ENV{'FAKE_ADB_STATE'} = $s->{state};
	local $ENV{'FAKE_ADB_PUSH'}  = $s->{push};
	local $ENV{'FAKE_ADB_TRACE'} = $s->{trace};
	my $out = qx{"$^X" "$base/bin/app_migrate.pl" --device $SERIAL --adb "$s->{adb}" --apply --backup-dir "$backup" 2>&1};
	my $rc = $? >> 8;
	is( $rc, 0, 'default APK resolution exits 0' ) or diag($out);
	like( slurp( $s->{log} ), qr/\binstall\s+\Q$base\E\/releases\/jawnos-app-1002-1\.2\.apk/,
		'it installed the newest versionCode' );
	unlike( slurp( $s->{log} ), qr/jawnos-app-1000-/, 'it did not install the older build' );
}

# 8. a restore that does not match the backup fails before the tree starts

{
	my $s = scenario( corrupt_restore => 1 );
	my $backup = "$s->{base}/backup-corrupt";
	spew( "$s->{base}/x.apk", 'apk' );
	my ( $rc, $out ) = run_migrate( $s, '--apply', '--backup-dir', $backup, '--apk', "$s->{base}/x.apk" );
	isnt( $rc, 0, 'a restored database that differs from the backup fails' );
	like( $out, qr/does not match the backup/, 'and says the restored file differs' );
	like( $out, qr/left disabled/, 'the app is left disabled, not running on an untrusted database' );
	ok( -e "$s->{state}/disabled", 'the fake package is still disabled' );
	my $starts = () = slurp( $s->{log} ) =~ /\bam start\b/g;
	is( $starts, 1, 'only the first-run start ran; the restored tree never started' );
}

# 9. an interrupted first-run checkout fails before the restore

{
	my $s = scenario( incomplete_tree => 1 );
	my $backup = "$s->{base}/backup-incomplete";
	spew( "$s->{base}/x.apk", 'apk' );
	my ( $rc, $out ) = run_migrate(
		$s, '--apply', '--backup-dir', $backup, '--apk', "$s->{base}/x.apk",
		'--first-run-timeout', '3',
	);
	isnt( $rc, 0, 'an incomplete first-run checkout fails the migration' );
	like( $out, qr/subroutines\.pl is not in the checkout yet/,
		'and names the file that is missing' );
	unlike( slurp( $s->{log} ), qr/\bpush\s+\S+\s+\/data\/local\/tmp\b/,
		'it never restores the house into a half-written tree' );
}

done_testing();
