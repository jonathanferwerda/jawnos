#!/usr/bin/perl
# Migrate an Android phone/tablet to a new com.jawnos APK without losing the house.
#
#   perl scripts/app_migrate.pl --device SERIAL [--apk FILE] [--backup-dir DIR]
#                               [--adb PATH] [--dry-run] [--apply]
#
# Why this exists
# ---------------
# A build that drops android:sharedUserId cannot upgrade over the installed
# app: Android refuses with INSTALL_FAILED_UID_CHANGED, because the data
# directory's owner uid changes. The only path is uninstall (the app's data is
# wiped), install the new build, let its first run unpack the pinned runtime and
# clone the tree, then put the house back.
#
# That restore is not just the database. A migration must carry the machine's
# identity too (docs/leaving-termux.md, "M4 - Identity"):
#
#   files/home/.house.key                          unseals __president/vault
#   files/home/.peer.key, files/home/.peer.pub     the signed peer rail
#   files/home/.jawnos_signatorial_id              the machine's own name
#   files/home/jawnos/database/.jawnos_signatorial_id   its mirror
#
# Miss one and the tablet's failure repeats: suds_grabber() returns nothing,
# every box_office ticket renders the denial page, peers answer 403, and the
# machine gets a new identity while its database still carries the old one.
#
# Safety
# ------
# Nothing destructive happens without --apply. With no flags (or --dry-run) the
# script inspects the device read-only, prints the whole plan and exits.
#   --apply and --dry-run together are refused.
#   Required files are checked BEFORE force-stop/uninstall, so a missing key
#   file fails safely.
#   Keys are copied, never echoed. No token is printed or backed up.
#
# What it does under --apply
# --------------------------
#   1. inspect the device (serial, model, installed version, tree VERSION/status)
#   2. force-stop com.jawnos
#   3. back up the house, keys and identity to a timestamped directory; write
#      MANIFEST (size + sha256) and run PRAGMA integrity_check on the host copy
#   4. adb uninstall com.jawnos
#   5. adb install the newest releases/jawnos-app-*.apk (or --apk)
#   6. launch the app, wait for the first run to unpack files/usr and clone the
#      tree, then FORCE-STOP again
#   7. restore the keys first, then config and the database; delete stale
#      -wal/-shm; chmod 600
#   8. rewrite /data/data/com.termux/files paths in `settings` (idempotent,
#      skipped when there is nothing to rewrite)
#   9. start the app, poll status=good, verify tree VERSION, appointment count
#      and that the device identity did not change
#
# A fresh clone has no .shots/ticket.txt (gitignored, a real credential). This
# script does not carry it: mint one on the device after the migration with
# `perl scripts/app_ticket.pl <client> --save`.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Find qw(find);
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);
use Symbol qw(gensym);
use IPC::Open3 qw(open3);
use POSIX qw(strftime);

my $root = abs_path("$FindBin::Bin/..");

my $PKG            = 'com.jawnos';
my $HOME_REMOTE    = 'files/home';
my $TREE_REMOTE    = 'files/home/jawnos';
my $DB_REMOTE      = 'files/home/jawnos/database/jawnos.db';
my $CONFIG_REMOTE  = 'files/home/jawnos/config.json';
my $STATUS_REMOTE  = 'files/home/.president/status';
my $VERSION_REMOTE = 'files/home/jawnos/VERSION';
my $RUNTIME_REMOTE = 'files/usr/etc/jawnos-runtime.json';
my $SQLITE_REMOTE  = 'files/usr/bin/sqlite3';
my $PKILL_REMOTE   = 'files/usr/bin/pkill';
my $PGREP_REMOTE   = 'files/usr/bin/pgrep';
my $PERL_PATTERN   = 'files/usr/bin/perl';

# Required identity files. Losing any of these costs the house its vault, its
# peer rail or its name; refuse to skip one.
my @KEYS = (
	{ remote => 'files/home/.house.key',               label => 'house key' },
	{ remote => 'files/home/.peer.key',                label => 'peer key' },
	{ remote => 'files/home/.peer.pub',                label => 'peer public key' },
	{ remote => 'files/home/.jawnos_signatorial_id',   label => 'signatorial identity' },
	{ remote => 'files/home/jawnos/database/.jawnos_signatorial_id',
	  label => 'signatorial identity mirror' },
);

# Backed up when present, never required.
my @OPTIONAL = (
	{ remote => 'files/home/jawnos/database/schema.sql',  label => 'schema' },
	{ remote => 'files/home/jawnos/database/initial.enc', label => 'initial database' },
);

my %opt = (
	adb        => 'adb',
	apply      => 0,
	dry_run    => 0,
	first_run_timeout => 900,
	status_timeout    => 300,
);

my ($serial, $apk, $backup_dir, $model, $installed_vc, $installed_vn);
my ($identity_before, $tree_before, $status_before);
my $restore_seq = 0;
my $disabled = 0;
my (@failures, @passes);

while ( defined( my $arg = shift @ARGV ) ) {
	if ($arg eq '--device')     { $serial = shift @ARGV; next; }
	if ($arg eq '--apk')        { $apk = shift @ARGV; next; }
	if ($arg eq '--backup-dir') { $backup_dir = shift @ARGV; next; }
	if ($arg eq '--adb')        { $opt{adb} = shift @ARGV; next; }
	if ($arg eq '--dry-run')    { $opt{dry_run} = 1; next; }
	if ($arg eq '--apply')      { $opt{apply} = 1; next; }
	if ($arg eq '--first-run-timeout') { $opt{first_run_timeout} = shift @ARGV; next; }
	if ($arg eq '--status-timeout')    { $opt{status_timeout} = shift @ARGV; next; }
	if ($arg eq '--help' || $arg eq '-h') { usage(0); }
	die "app_migrate.pl: unknown option $arg\n" . usage_text();
}
usage(1) unless defined $serial && length $serial;
if ($opt{apply} && $opt{dry_run}) {
	die "app_migrate.pl: --apply and --dry-run are mutually exclusive\n" . usage_text();
}
my $execute = $opt{apply} ? 1 : 0;

my $ok = eval { main(); 1 };
unless ($ok) {
	my $err = $@ || "unknown error\n";
	$err =~ s/\s+\z//;
	# A disabled app is deliberate on failure: enabling it lets the system
	# rebind the IME/notification listener and the app starts the tree again
	# against a half-restored database. Say how to undo it instead.
	print STDERR "\napp_migrate: FAIL\n$err\n";
	print STDERR "backup: $backup_dir\n" if defined $backup_dir && -d $backup_dir;
	print STDERR "$PKG is left disabled; re-enable it with:\n"
		. "  adb -s $serial shell pm enable $PKG\n" if $disabled;
	exit 1;
}
exit 0;

sub usage_text {
	return "usage: app_migrate.pl --device SERIAL [--apk FILE] [--backup-dir DIR]\n"
		. "                      [--adb PATH] [--first-run-timeout SECONDS]\n"
		. "                      [--status-timeout SECONDS] [--dry-run] [--apply]\n"
		. "\n"
		. "  --device SERIAL   adb serial (run `adb devices -l`)\n"
		. "  --apk FILE        APK to install (default: newest releases/jawnos-app-*.apk)\n"
		. "  --backup-dir DIR  default: ~/.jawnos-backups/<model>-<serial>-<YYYY-MM-DD-HHMM>/\n"
		. "  --adb PATH        adb executable (default: adb)\n"
		. "  --first-run-timeout SECONDS  wait for the first run to finish (default 900)\n"
		. "  --status-timeout SECONDS     wait for status=good after the restore (default 300)\n"
		. "  --dry-run         print the plan and change nothing (the default)\n"
		. "  --apply           actually migrate the device\n";
}

sub usage {
	my ($code) = @_;
	my $text = usage_text();
	$code ? die $text : print $text;
	exit $code;
}

sub main {
	resolve_apk();

	# ---- inspect (read-only) -------------------------------------------------
	inspect_device();
	preflight_required();

	my $stamp = strftime('%Y-%m-%d-%H%M', localtime);
	unless (defined $backup_dir && length $backup_dir) {
		my $safe_model  = sanitise_component($model);
		my $safe_serial = sanitise_component($serial);
		my $base = "$ENV{'HOME'}/.jawnos-backups/$safe_model-$safe_serial-$stamp";
		$backup_dir = unique_dir($base);
	}

	print_header();

	unless ($execute) {
		print_plan();
		return;
	}

	# ---- destructive path ----------------------------------------------------
	step('force-stop the running app');
	stop_app();

	step('back up the house and identity');
	backup_house();

	step("uninstall $PKG");
	adb( args => [ 'uninstall', $PKG ] );
	adb_report_install_state();

	step('install the new APK');
	adb( args => [ 'install', $apk ] );
	my $installed = installed_version();
	die "app_migrate.pl: $PKG was not installed by the APK; dumpsys still has no version\n"
		unless defined $installed->{versionCode};
	print "installed: versionCode=$installed->{versionCode} versionName="
		. ($installed->{versionName} // '?') . "\n";

	step('launch once and wait for the first run (runtime + tree)');
	my $component = launcher_component();
	start_app($component);
	wait_for_first_run();

	step('force-stop before touching the vault');
	stop_app();

	step('restore the identity files first');
	restore_identity();

	step('restore config and the database');
	restore_house();

	step('verify the restored database before it is opened');
	verify_restored_database();

	step('rewrite old com.termux paths in settings');
	rewrite_settings();

	step('verify the restored files');
	verify_restored_files();

	step('start the app and wait for status=good');
	adb( args => [ 'shell', 'run-as', $PKG, 'rm', '-f', $STATUS_REMOTE ] );
	start_app($component);
	wait_for_status();

	step('verify the house and identity');
	verify_after();

	print_summary();
	if (@failures) {
		# Do not leave a tree writing into a database the checks do not trust.
		eval { stop_app() };
		die "migration checks failed; $PKG is stopped\n";
	}
	return;
}

# ---------------------------------------------------------------------------
# apk resolution

sub resolve_apk {
	if (defined $apk && length $apk) {
		die "app_migrate.pl: $apk: no such file\n" unless -f $apk;
		return;
	}
	my @apks = glob("$root/releases/jawnos-app-*.apk");
	die "app_migrate.pl: no releases/jawnos-app-*.apk; pass --apk FILE\n"
		unless @apks;
	@apks = sort {
		my ($av) = ( basename($a) =~ /-(\d+)-/ );
		my ($bv) = ( basename($b) =~ /-(\d+)-/ );
		($bv || 0) <=> ($av || 0) || $b cmp $a
	} @apks;
	$apk = $apks[0];
}

# ---------------------------------------------------------------------------
# device inspection

sub inspect_device {
	$model = trim( adb( args => [ 'shell', 'getprop', 'ro.product.model' ] )->{out} );
	$model = $serial unless defined $model && length $model;

	my $d = adb( args => [ 'shell', 'dumpsys', 'package', $PKG ], allow_fail => 1 );
	if ( $d->{rc} == 0 ) {
		($installed_vc) = $d->{out} =~ /versionCode=(\d+)/;
		($installed_vn) = $d->{out} =~ /versionName=(\S+)/;
	}

	$tree_before   = remote_read_trim($VERSION_REMOTE);
	$status_before = remote_read_trim($STATUS_REMOTE);
	$identity_before = remote_read_trim('files/home/.jawnos_signatorial_id');
}

sub preflight_required {
	# The app must be debuggable: every read and restore goes through run-as.
	my $pwd = adb( args => [ 'shell', 'run-as', $PKG, 'pwd' ], allow_fail => 1 );
	unless ( $pwd->{rc} == 0 && $pwd->{out} =~ m{/data/} ) {
		my $err = trim( $pwd->{err} // '' );
		die "app_migrate.pl: run-as $PKG failed; is the app installed and debuggable?\n"
			. ($err ne '' ? "$err\n" : '');
	}

	for my $f ( { remote => $DB_REMOTE, label => 'database' },
	            { remote => $CONFIG_REMOTE, label => 'config' },
	            @KEYS ) {
		next if remote_test( $f->{remote} );
		die "app_migrate.pl: missing required $f->{label}: $f->{remote}\n"
			. "Refusing to migrate: a fresh file cannot replace it.\n";
	}
}

sub installed_version {
	my $d = adb( args => [ 'shell', 'dumpsys', 'package', $PKG ], allow_fail => 1 );
	return {} unless $d->{rc} == 0;
	my ($vc) = $d->{out} =~ /versionCode=(\d+)/;
	my ($vn) = $d->{out} =~ /versionName=(\S+)/;
	return { versionCode => $vc, versionName => $vn };
}

# ---------------------------------------------------------------------------
# the plan

sub print_header {
	print "app_migrate: device $serial ($model)\n";
	print "  adb:       $opt{adb}\n";
	print "  installed: " . (defined $installed_vc
		? "$PKG versionCode=$installed_vc versionName=" . ($installed_vn // '?')
		: "$PKG not installed") . "\n";
	print "  tree:      " . (defined $tree_before && length $tree_before
		? "VERSION $tree_before" : 'not readable') . "\n";
	print "  status:    " . (defined $status_before && length $status_before
		? $status_before : 'not readable') . "\n";
	print "  identity:  " . (defined $identity_before && length $identity_before
		? 'device=' . substr($identity_before, 0, 8) . '...' : 'not readable') . "\n";
	print "  apk:       $apk\n";
	print "  backup:    $backup_dir\n";
	warn_about_apk($apk);
}

sub warn_about_apk {
	my ($file) = @_;
	my $aapt = find_aapt();
	unless ($aapt) {
		print "  note: no aapt found; cannot inspect the APK manifest\n";
		return;
	}
	my $b = run_command( cmd => [ $aapt, 'dump', 'badging', $file ], allow_fail => 1 );
	return unless $b->{rc} == 0;
	my ($pkg) = $b->{out} =~ /package: name='([^']+)'/;
	my ($vc)  = $b->{out} =~ /versionCode='([^']+)'/;
	my ($vn)  = $b->{out} =~ /versionName='([^']+)'/;
	if ( defined $pkg && $pkg ne $PKG ) {
		die "app_migrate.pl: $file installs package '$pkg', not $PKG\n";
	}
	print "  apk build: $pkg versionCode=$vc versionName=$vn\n" if defined $pkg;

	my $t = run_command( cmd => [ $aapt, 'dump', 'xmltree', $file, 'AndroidManifest.xml' ],
		allow_fail => 1 );
	if ( $t->{rc} == 0 && $t->{out} =~ /sharedUserId/ ) {
		print "  WARNING: this APK still declares android:sharedUserId.\n"
			. "           It is not the build that dropped it; the migration is safe,\n"
			. "           but future in-place upgrades over this build will still fail.\n";
	}
}

sub print_plan {
	print "\nMODE: PLAN (read-only; pass --apply to execute)\n";
	print "steps that WOULD run:\n";
	my $n = 0;
	for my $line (
		"force-stop $PKG, disable it so Android cannot rebind it, and kill the exec'd perl tree",
		"back up the house and identity to $backup_dir (MANIFEST, sha256, integrity_check)",
		"uninstall $PKG",
		"install $apk",
		"launch the launcher and wait for files/usr + the tree to appear (<= $opt{first_run_timeout}s)",
		"force-stop + disable $PKG and kill the tree before it touches the vault",
		"restore " . join(', ', map { $_->{remote} } @KEYS),
		"restore $CONFIG_REMOTE",
		"delete stale jawnos.db-wal/-shm and restore $DB_REMOTE",
		"verify the restored database's sha256, integrity and appointment count",
		"rewrite /data/data/com.termux/files in settings (skipped when there is nothing to rewrite)",
		"re-enable the app, start it, poll $STATUS_REMOTE for good (<= $opt{status_timeout}s)",
		"verify tree VERSION, appointment count and device identity",
	) {
		$n++;
		print sprintf("  %2d. %s\n", $n, $line);
	}
	print "\nbackup contents:\n";
	for my $f ( { remote => $DB_REMOTE }, { remote => $CONFIG_REMOTE }, @KEYS, @OPTIONAL ) {
		my $state = remote_test( $f->{remote} ) ? 'present' : 'absent';
		printf "  %-58s %s\n", $f->{remote}, $state;
	}
	print "\nnote: .shots/ticket.txt is not carried (it is a gitignored credential);\n"
		. "      mint one on the device with: perl scripts/app_ticket.pl <client> --save\n";
}

# ---------------------------------------------------------------------------
# adb runner (every adb call goes through here)

sub run_command {
	my (%a) = @_;
	my @cmd = @{ $a{cmd} || [] };
	die "app_migrate.pl: empty command\n" unless @cmd;

	my $stderr = gensym;
	my ( $in, $out, $pid );
	my $out_fh;
	if ( defined $a{stdout_file} ) {
		open( $out_fh, '>', $a{stdout_file} )
			or die "app_migrate.pl: cannot write $a{stdout_file}: $!\n";
	}
	my $opened = eval {
		if ($out_fh) {
			$pid = open3( $in, [ '&', $out_fh ], $stderr, @cmd );
		}
		else {
			$pid = open3( $in, $out, $stderr, @cmd );
		}
		1;
	};
	unless ($opened) {
		my $e = $@ || 'unknown error';
		die "app_migrate.pl: cannot run $cmd[0]: $e\n";
	}
	close $in;
	close $out_fh if $out_fh;

	my $stdout = '';
	if ( defined $out ) {
		local $/;
		$stdout = <$out>;
		close $out;
	}
	local $/;
	my $err = <$stderr>;
	close $stderr;

	waitpid( $pid, 0 );
	my $rc = $? >> 8;

	my $result = { rc => $rc, out => ( $stdout // '' ), err => ( $err // '' ) };
	return $result if $a{allow_fail};
	if ( $rc != 0 ) {
		my $shown = join( ' ', map { /\s/ ? qq{"$_"} : $_ } @cmd );
		$shown =~ s/\n/ /g;
		my $e = trim( $result->{err} );
		die "app_migrate.pl: command failed (exit $rc): $shown\n"
			. ($e ne '' ? "$e\n" : '');
	}
	return $result;
}

sub adb {
	my (%a) = @_;
	my @args = @{ $a{args} || [] };
	die "app_migrate.pl: empty adb command\n" unless @args;
	my @cmd = ( $opt{adb}, '-s', $serial, @args );
	my $r = run_command(
		cmd           => \@cmd,
		stdout_file   => $a{stdout_file},
		allow_fail    => ( $a{allow_fail} ? 1 : 0 ),
	);
	return $r;
}

sub remote_test {
	my ($path) = @_;
	my $r = adb( args => [ 'shell', 'run-as', $PKG, 'test', '-f', $path ], allow_fail => 1 );
	return $r->{rc} == 0;
}

sub remote_read_trim {
	my ($path) = @_;
	my $r = adb( args => [ 'shell', 'run-as', $PKG, 'cat', $path ], allow_fail => 1 );
	return undef unless $r->{rc} == 0;
	return trim( $r->{out} );
}

sub remote_pull {
	my ( $remote, $local ) = @_;
	make_path( dirname($local) );
	adb( args => [ 'exec-out', 'run-as', $PKG, 'cat', $remote ], stdout_file => $local );
	die "app_migrate.pl: pulled $remote but $local is missing or empty\n"
		unless -f $local && -s $local;
}

# ---------------------------------------------------------------------------
# backup

sub backup_house {
	make_path($backup_dir);
	chmod 0700, $backup_dir;

	for my $f ( { remote => $DB_REMOTE, label => 'database' },
	            { remote => $CONFIG_REMOTE, label => 'config' },
	            @KEYS ) {
		die "app_migrate.pl: missing required $f->{label} at backup time: $f->{remote}\n"
			unless remote_test( $f->{remote} );
		my $local = "$backup_dir/$f->{remote}";
		print "  $f->{remote}\n";
		remote_pull( $f->{remote}, $local );
	}

	# A stopped app should have checkpointed its WAL, but copy the sidecars if
	# they are still there: they are part of the database's state.
	for my $suffix ( '-wal', '-shm' ) {
		my $remote = "$DB_REMOTE$suffix";
		next unless remote_test($remote);
		print "  $remote\n";
		remote_pull( $remote, "$backup_dir/$remote" );
	}

	for my $f (@OPTIONAL) {
		next unless remote_test( $f->{remote} );
		print "  $f->{remote} (optional)\n";
		remote_pull( $f->{remote}, "$backup_dir/$f->{remote}" );
	}

	check_backup_database();
	write_manifest();
	verify_manifest();
	print "  backup: $backup_dir\n";
}

sub check_backup_database {
	my $db = "$backup_dir/$DB_REMOTE";
	my $sqlite3 = host_sqlite3();

	# Fold a copied WAL into the copy, so the single restored file is complete.
	my $cp = run_command(
		cmd        => [ $sqlite3, $db, 'PRAGMA wal_checkpoint(TRUNCATE);' ],
		allow_fail => 1,
	);
	die "app_migrate.pl: wal_checkpoint on the backup failed:\n" . trim( $cp->{err} ) . "\n"
		if $cp->{rc} != 0;
	unlink "$db-wal", "$db-shm";

	my $int = run_command(
		cmd        => [ $sqlite3, $db, 'PRAGMA integrity_check;' ],
		allow_fail => 1,
	);
	die "app_migrate.pl: sqlite3 integrity_check failed:\n" . trim( $int->{err} ) . "\n"
		if $int->{rc} != 0;
	my $result = trim( $int->{out} );
	die "app_migrate.pl: backup database is not intact: $result\n"
		unless $result eq 'ok';
	print "  integrity_check: ok\n";

	my $count = sqlite_one( $sqlite3, $db, 'SELECT count(*) FROM appointments;' );
	die "app_migrate.pl: cannot count appointments in the backup\n"
		unless defined $count;
	print "  appointments before: $count\n";
	return $count;
}

sub write_manifest {
	my @rel;
	find(
		{
			no_chdir => 1,
			wanted   => sub {
				return unless -f $File::Find::name;
				my $rel = $File::Find::name;
				$rel =~ s{^\Q$backup_dir\E/}{};
				return if $rel eq 'MANIFEST';
				push @rel, $rel;
			},
		},
		$backup_dir,
	);
	@rel = sort @rel;

	my $created = strftime('%Y-%m-%dT%H:%M:%S', localtime);
	open( my $fh, '>', "$backup_dir/MANIFEST" )
		or die "app_migrate.pl: cannot write MANIFEST: $!\n";
	print $fh "# JawnOS app migration backup\n";
	print $fh "# device: $serial\n";
	print $fh "# model: $model\n";
	print $fh "# created: $created\n";
	print $fh "# format: sha256<TAB>size<TAB>path\n";
	for my $rel (@rel) {
		my $file = "$backup_dir/$rel";
		printf $fh "%s\t%d\t%s\n", sha256_file($file), -s $file, $rel;
	}
	close $fh;
	print "  MANIFEST: " . scalar(@rel) . " file(s)\n";
}

sub verify_manifest {
	open( my $fh, '<', "$backup_dir/MANIFEST" )
		or die "app_migrate.pl: cannot read MANIFEST: $!\n";
	while ( my $line = <$fh> ) {
		next if $line =~ /^#/;
		chomp $line;
		my ( $sha, $size, $rel ) = split /\t/, $line;
		next unless defined $rel && length $rel;
		my $file = "$backup_dir/$rel";
		die "app_migrate.pl: MANIFEST names a missing file: $rel\n" unless -f $file;
		die "app_migrate.pl: MANIFEST size mismatch for $rel\n" unless -s $file == $size;
		die "app_migrate.pl: MANIFEST sha256 mismatch for $rel\n"
			unless sha256_file($file) eq $sha;
	}
	close $fh;
}

# ---------------------------------------------------------------------------
# uninstall / install / launch

sub adb_report_install_state {
	my $installed = installed_version();
	if ( defined $installed->{versionCode} ) {
		print "  note: $PKG still reports versionCode=$installed->{versionCode}\n";
	}
	else {
		print "  $PKG uninstalled\n";
	}
}

sub stop_app {
	# force-stop alone does not stop the tree. The app carries system-bound
	# services (the IME, the notification listener, the VPN), so Android can
	# rebind the package within seconds, and SessionService then starts the
	# tree again on its 2 s backoff. The exec'd perl tree is not an
	# ActivityManager process at all, so force-stop never kills it either.
	# Disabling the package stops the rebind; pkill stops the tree. Doing only
	# force-stop is how a first-run WAL was left beside the restored database
	# (2026-10-31) and made it look corrupt.
	adb( args => [ 'shell', 'am', 'force-stop', $PKG ], allow_fail => 1 );
	adb( args => [ 'shell', 'pm', 'disable-user', '--user', '0', $PKG ], allow_fail => 1 );
	$disabled = 1;
	# The app may have restarted between the force-stop and the disable.
	adb( args => [ 'shell', 'am', 'force-stop', $PKG ], allow_fail => 1 );

	my $deadline = time + 30;
	while ( 1 ) {
		adb(
			args       => [ 'shell', 'run-as', $PKG, $PKILL_REMOTE, '-9', '-f', $PERL_PATTERN ],
			allow_fail => 1,
		);
		last if tree_is_down();
		if ( time >= $deadline ) {
			die "app_migrate.pl: the jawn tree is still running after 30s; refusing to touch the database\n";
		}
		sleep 1;
	}
	print "  $PKG disabled and the tree is down\n";
}

sub tree_is_down {
	my $r = adb(
		args       => [ 'shell', 'run-as', $PKG, $PGREP_REMOTE, '-f', $PERL_PATTERN ],
		allow_fail => 1,
	);
	return 1 if $r->{rc} != 0;   # pgrep exits 1 when nothing matches
	return trim( $r->{out} // '' ) eq '' ? 1 : 0;
}

sub enable_app {
	return unless $disabled;
	adb( args => [ 'shell', 'pm', 'enable', $PKG ], allow_fail => 1 );
	$disabled = 0;
}

sub launcher_component {
	my $r = adb(
		args       => [ 'shell', 'cmd', 'package', 'resolve-activity', '--brief', $PKG ],
		allow_fail => 1,
	);
	if ( $r->{rc} == 0 ) {
		my ($comp) = $r->{out} =~ m{^\s*([A-Za-z0-9_.]+/[A-Za-z0-9_.\$]+)\s*$}m;
		return $comp if defined $comp && length $comp;
	}
	# Older devices: let the package manager resolve the launcher intent.
	$r = adb(
		args       => [ 'shell', 'cmd', 'package', 'resolve-activity', '--brief',
		                '-c', 'android.intent.category.LAUNCHER', $PKG ],
		allow_fail => 1,
	);
	if ( $r->{rc} == 0 ) {
		my ($comp) = $r->{out} =~ m{^\s*([A-Za-z0-9_.]+/[A-Za-z0-9_.\$]+)\s*$}m;
		return $comp if defined $comp && length $comp;
	}
	die "app_migrate.pl: cannot resolve a launcher component for $PKG\n"
		. trim( $r->{out} ) . "\n";
}

sub start_app {
	my ($component) = @_;
	enable_app();
	my $r = adb(
		args       => [ 'shell', 'am', 'start', '-W', '-n', $component ],
		allow_fail => 1,
	);
	die "app_migrate.pl: am start $component failed:\n"
		. trim( $r->{err} // '' ) . "\n" . trim( $r->{out} // '' ) . "\n"
		if $r->{rc} != 0;
	print "  started $component\n";
}

sub wait_for_first_run {
	my $deadline = time + $opt{first_run_timeout};
	my $last = 0;
	my ( $ver, $rt, $missing, $status );
	# VERSION appears while git is still checking the tree out: the first
	# migration (2026-10-31) stopped here, the checkout was left half written,
	# and the restored tree could not load subroutines.pl. A complete run means
	# the files President loads are in place and jawn itself says good.
	my @needed = qw(subroutines.pl gb.pl President.pl Manager.pl);
	while (1) {
		$ver    = remote_read_trim($VERSION_REMOTE);
		$rt     = remote_read_trim($RUNTIME_REMOTE);
		$status = remote_read_trim($STATUS_REMOTE);
		$missing = undef;
		for my $f (@needed) {
			next if remote_test("$TREE_REMOTE/$f");
			$missing = $f;
			last;
		}
		if ( defined $ver && length $ver
			&& defined $rt && length $rt
			&& !defined $missing
			&& defined $status && $status eq 'good' ) {
			print "  first run ready: tree $ver, status good, runtime " . substr($rt, 0, 60) . "\n";
			return;
		}
		if ( time >= $deadline ) {
			my $why = !defined $ver || !length $ver ? 'tree VERSION absent'
				: defined $missing ? "$missing is not in the checkout yet"
				: !defined $rt || !length $rt ? 'runtime json absent'
				: 'status is ' . ( defined $status && length $status ? $status : 'absent' );
			die "app_migrate.pl: timed out after $opt{first_run_timeout}s waiting for the first run\n"
				. "  $why\n";
		}
		if ( time - $last >= 15 ) {
			my $why = defined $missing ? " ($missing not there yet)"
				: ( defined $status && length $status && $status ne 'good' ) ? " (status $status)" : '';
			print "  waiting for the first run to finish$why"
				. " (" . ( time - ( $deadline - $opt{first_run_timeout} ) ) . "s)\n";
			$last = time;
		}
		sleep 3;
	}
}

# ---------------------------------------------------------------------------
# restore

sub restore_identity {
	my $n = 0;
	for my $k (@KEYS) {
		my $local = "$backup_dir/$k->{remote}";
		die "app_migrate.pl: backup is missing $k->{remote}\n" unless -f $local;
		restore_file( $local, $k->{remote} );
		$n++;
	}
	print "  restored $n identity file(s), chmod 600\n";
}

sub restore_house {
	# The fresh app may have created its own WAL after the first run. A stale
	# sidecar beside a replaced database is worse than no sidecar at all.
	adb( args => [ 'shell', 'run-as', $PKG, 'rm', '-f',
		"$DB_REMOTE-wal", "$DB_REMOTE-shm" ] );

	for my $f ( { remote => $CONFIG_REMOTE }, { remote => $DB_REMOTE }, @OPTIONAL ) {
		my $local = "$backup_dir/$f->{remote}";
		next unless -f $local;
		restore_file( $local, $f->{remote} );
	}
	print "  config and database restored\n";
}

# Everything that could apply a WAL from the old install to the restored file
# has to be ruled out before the tree is allowed to open it: the file must be
# exactly the backup, intact, with the same row count. The first migration
# (2026-10-31) restored a good backup and then opened it beside a WAL left by
# the still-running first-run tree; SQLite reported the image as malformed and
# the appointment count as zero while the file itself was fine.
sub verify_restored_database {
	my $backup_db = "$backup_dir/$DB_REMOTE";
	my $want_sha  = sha256_file($backup_db);
	my $sqlite3   = host_sqlite3();
	my $want_count = sqlite_one( $sqlite3, $backup_db, 'SELECT count(*) FROM appointments;' );

	adb( args => [ 'shell', 'run-as', $PKG, 'rm', '-f', "$DB_REMOTE-wal", "$DB_REMOTE-shm" ] );

	my $got = adb( args => [ 'shell', 'run-as', $PKG, 'sha256sum', $DB_REMOTE ] );
	my ($got_sha) = ( $got->{out} || '' ) =~ /^\s*([0-9a-fA-F]{64})\b/;
	die "app_migrate.pl: cannot read the restored database's sha256\n"
		unless defined $got_sha;
	die "app_migrate.pl: the restored database does not match the backup on the device\n"
		. "  want $want_sha\n  got  $got_sha\n"
		unless lc($got_sha) eq lc($want_sha);

	my $sql_cmd = "run-as $PKG $SQLITE_REMOTE " . shell_quote($DB_REMOTE)
		. ' ' . shell_quote('PRAGMA integrity_check;');
	my $check = adb(
		args       => [ 'shell', $sql_cmd ],
		allow_fail => 1,
	);
	my $result = trim( $check->{out} // '' );
	die "app_migrate.pl: the restored database is not intact on the device:\n"
		. ( $result ne '' ? "$result\n" : trim( $check->{err} // '' ) . "\n" )
		unless $check->{rc} == 0 && $result eq 'ok';

	my $count = remote_sqlite_one('SELECT count(*) FROM appointments;');
	die "app_migrate.pl: the restored database has "
		. ( defined $count ? $count : 'no readable' )
		. " appointments; the backup has " . ( defined $want_count ? $want_count : '?' ) . "\n"
		if !defined $count || !defined $want_count || $count != $want_count;

	# The check itself can leave a WAL; the tree must open the database alone.
	adb( args => [ 'shell', 'run-as', $PKG, 'rm', '-f', "$DB_REMOTE-wal", "$DB_REMOTE-shm" ] );
	print "  database: sha256 matches the backup, integrity ok, $count appointments\n";
}

sub restore_file {
	my ( $local, $remote ) = @_;
	my $tmp = '/data/local/tmp/jawnos-migrate-' . $$ . '-' . ( ++$restore_seq );
	adb( args => [ 'push', $local, $tmp ] );
	adb( args => [ 'shell', 'run-as', $PKG, 'cp', $tmp, $remote ] );
	adb( args => [ 'shell', 'run-as', $PKG, 'chmod', '600', $remote ] );
	adb( args => [ 'shell', 'rm', '-f', $tmp ], allow_fail => 1 );
	print "  $remote\n";
}

sub rewrite_settings {
	my $count_sql = q{SELECT count(*) FROM settings WHERE value LIKE '%/data/data/com.termux/files%';};
	my $count = remote_sqlite_one($count_sql);
	die "app_migrate.pl: cannot read the settings table from the restored database\n"
		unless defined $count;

	if ( $count == 0 ) {
		print "  settings: no /data/data/com.termux paths; rewrite skipped\n";
		return;
	}

	print "  settings: $count row(s) name the old com.termux prefix; rewriting\n";
	my $update_sql = q{UPDATE settings SET value = replace(value, '/data/data/com.termux/files', '/data/data/com.jawnos/files') WHERE value LIKE '%/data/data/com.termux/files%';};
	remote_sqlite_one($update_sql);

	my $left = remote_sqlite_one($count_sql);
	die "app_migrate.pl: $left row(s) still name /data/data/com.termux after the rewrite\n"
		if defined $left && $left != 0;
	print "  settings: rewrite complete, 0 old paths remain\n";
}

sub verify_restored_files {
	for my $f ( { remote => $CONFIG_REMOTE, label => 'config' }, @KEYS ) {
		my $local = "$backup_dir/$f->{remote}";
		next unless -f $local;
		my ( $tmp_fh, $tmp ) = tempfile( 'jawnos-migrate-verify-XXXXXX', TMPDIR => 1 );
		close $tmp_fh;
		adb( args => [ 'exec-out', 'run-as', $PKG, 'cat', $f->{remote} ],
			stdout_file => $tmp );
		my $same = -f $tmp && sha256_file($tmp) eq sha256_file($local);
		unlink $tmp;
		if ($same) {
			push @passes, "$f->{label} restored byte-for-byte";
		}
		else {
			push @failures, "$f->{label} does not match the backup";
		}
	}
}

# ---------------------------------------------------------------------------
# verification

sub wait_for_status {
	my $deadline = time + $opt{status_timeout};
	my $last = 0;
	while ( 1 ) {
		my $status = remote_read_trim($STATUS_REMOTE);
		if ( defined $status && $status eq 'good' ) {
			print "  status: good\n";
			return;
		}
		if ( time >= $deadline ) {
			die "app_migrate.pl: timed out after $opt{status_timeout}s waiting for status=good\n"
				. "  last status: " . ( defined $status && length $status ? $status : 'absent' ) . "\n";
		}
		if ( time - $last >= 15 ) {
			print "  waiting for status=good (" . ( time - ( $deadline - $opt{status_timeout} ) ) . "s)\n";
			$last = time;
		}
		sleep 3;
	}
}

sub verify_after {
	my $version = remote_read_trim($VERSION_REMOTE);
	if ( defined $version && length $version ) {
		push @passes, "tree VERSION $version";
	}
	else {
		push @failures, 'tree VERSION is missing after the migration';
	}

	my $after = remote_sqlite_one('SELECT count(*) FROM appointments;');
	my $before = backup_appointment_count();
	if ( defined $after && defined $before ) {
		if ( $after == $before ) {
			push @passes, "appointments $before before, $after after";
		}
		else {
			push @failures, "appointment count changed: $before before, $after after";
		}
	}
	elsif ( defined $after ) {
		push @passes, "appointments $after after";
	}
	else {
		push @failures, 'cannot count appointments after the migration';
	}

	my $identity_after = remote_read_trim('files/home/.jawnos_signatorial_id');
	if ( defined $identity_before && length $identity_before
		&& defined $identity_after && length $identity_after
		&& lc($identity_after) eq lc($identity_before) ) {
		push @passes, 'device=' . substr( $identity_before, 0, 8 ) . '... unchanged';
	}
	else {
		push @failures, 'device identity changed or is unreadable';
	}

	# The mirror must agree with the home copy, or a wrong HOME can hand the
	# machine a different name later.
	my $mirror = remote_read_trim('files/home/jawnos/database/.jawnos_signatorial_id');
	if ( defined $mirror && defined $identity_after
		&& lc($mirror) eq lc($identity_after) ) {
		push @passes, 'signatorial identity mirror agrees';
	}
	else {
		push @failures, 'signatorial identity mirror does not agree';
	}
}

sub backup_appointment_count {
	my $db = "$backup_dir/$DB_REMOTE";
	return undef unless -f $db;
	my $sqlite3 = eval { host_sqlite3() };
	return undef unless $sqlite3;
	return sqlite_one( $sqlite3, $db, 'SELECT count(*) FROM appointments;' );
}

sub print_summary {
	my $verdict = @failures ? 'FAIL' : 'PASS';
	print "\n" . ( '=' x 60 ) . "\n";
	print "MIGRATION $verdict\n";
	print "  device:   $serial ($model)\n";
	print "  backup:   $backup_dir\n";
	print "  identity: device=" . ( defined $identity_before && length $identity_before
		? substr( $identity_before, 0, 8 ) . '...' : 'unknown' ) . "\n";
	print "  checks:\n";
	print "    - $_\n" for @passes;
	print "    - FAILED: $_\n" for @failures;
	print( '=' x 60 ) . "\n";
}

# ---------------------------------------------------------------------------
# helpers

sub host_sqlite3 {
	my @dirs = split /:/, ( $ENV{PATH} || '' );
	for my $d (@dirs) {
		return "$d/sqlite3" if -x "$d/sqlite3";
	}
	die "app_migrate.pl: sqlite3 not found on PATH\n";
}

sub sqlite_one {
	my ( $sqlite3, $db, $sql ) = @_;
	my $r = run_command( cmd => [ $sqlite3, $db, $sql ], allow_fail => 1 );
	return undef if $r->{rc} != 0;
	my ($v) = $r->{out} =~ /^\s*(-?\d+)\s*$/m;
	return defined $v ? $v + 0 : undef;
}

sub remote_sqlite_one {
	my ($sql) = @_;
	my $cmd = "run-as $PKG $SQLITE_REMOTE " . shell_quote($DB_REMOTE) . ' ' . shell_quote($sql);
	my $r = adb( args => [ 'shell', $cmd ], allow_fail => 1 );
	return undef if $r->{rc} != 0;
	my ($v) = $r->{out} =~ /^\s*(-?\d+)\s*$/m;
	return defined $v ? $v + 0 : undef;
}

sub shell_quote {
	my ($s) = @_;
	$s = '' unless defined $s;
	$s =~ s/'/'\\''/g;
	return "'$s'";
}

sub sha256_file {
	my ($file) = @_;
	open( my $fh, '<:raw', $file ) or die "app_migrate.pl: cannot read $file: $!\n";
	my $sha = Digest::SHA->new(256);
	$sha->addfile($fh);
	close $fh;
	return $sha->hexdigest;
}

sub trim {
	my ($s) = @_;
	return '' unless defined $s;
	$s =~ s/\s+\z//;
	$s =~ s/^\s+//;
	return $s;
}

sub sanitise_component {
	my ($s) = @_;
	$s = '' unless defined $s;
	$s =~ s/[^A-Za-z0-9._-]+/_/g;
	$s =~ s/^_+|_+$//g;
	$s = 'device' unless length $s;
	return $s;
}

sub unique_dir {
	my ($base) = @_;
	return $base unless -e $base;
	my $n = 2;
	$n++ while -e "$base-$n";
	return "$base-$n";
}

sub find_aapt {
	my $sdk = $ENV{ANDROID_SDK_ROOT} || $ENV{ANDROID_HOME} || "$ENV{HOME}/android-sdk";
	my @found = grep { -x $_ } glob("$sdk/build-tools/*/aapt");
	if (@found) {
		@found = sort {
			my ($av) = $a =~ m{/build-tools/([^/]+)/aapt$};
			my ($bv) = $b =~ m{/build-tools/([^/]+)/aapt$};
			my @a = split /\./, ( $av || '0' );
			my @b = split /\./, ( $bv || '0' );
			( $b[0] || 0 ) <=> ( $a[0] || 0 )
				|| ( $b[1] || 0 ) <=> ( $a[1] || 0 )
				|| ( $b[2] || 0 ) <=> ( $a[2] || 0 )
		} @found;
		return $found[0];
	}
	for my $dir ( split /:/, ( $ENV{PATH} || '' ) ) {
		return "$dir/aapt" if -x "$dir/aapt";
	}
	return undef;
}

sub step {
	my ($text) = @_;
	print "\n== $text ==\n";
}
