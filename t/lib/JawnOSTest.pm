package JawnOSTest;

# Shared harness for the regression suite.
#
# `use JawnOSTest;` loads the app's core module (`subroutines.pl`) once, from a
# throwaway sandbox holding symlinks to the real source files and a minimal
# `config.json`. subroutines.pl reads ./config.json and requires its siblings by
# relative path, so it has to be loaded from a directory shaped like the repo;
# doing it in a temp dir keeps the suite runnable on a clean checkout that has no
# install-local config, and keeps `~/manager.log`, `~/.president/` and the live
# database out of the test's business.
#
# After loading, the process is chdir'd back to the repo root, so a test can read
# `database/schema.sql`, `templates/...` and so on with ordinary relative paths.
# TZ is pinned to UTC so calendar assertions do not depend on the machine.
#
# Exports: root()      repo root (absolute)
#          sandbox()   the throwaway directory the core was loaded from
#          ts(y,m,d[,h,mi,s])  epoch milliseconds in UTC
#          ymd(ms)     'YYYY-MM-DD' for an epoch-millisecond value
#
# No test may write to the live database, send mail, or start the app. The
# helpers here are pure reads.

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use Exporter ();
use File::Copy qw(copy);
use File::Temp qw(tempdir);
use FindBin ();
use POSIX ();

our @ISA = ('Exporter');
our @EXPORT = qw(root sandbox ts ymd);
our @EXPORT_OK = ();

our $ROOT;
our $SANDBOX;
our $_READY;

sub root    { return $ROOT }
sub sandbox { return $SANDBOX }

# Epoch milliseconds for a civil date. The suite pins TZ=UTC in _setup.
sub ts {
	my ($y, $m, $d, $h, $mi, $s) = @_;
	require Time::Local;
	return Time::Local::timelocal($s || 0, $mi || 0, $h || 0, $d, $m - 1, $y) * 1000;
}

# 'YYYY-MM-DD' for an epoch-millisecond timestamp.
sub ymd {
	my $ms = shift;
	return '' unless defined $ms;
	return POSIX::strftime('%Y-%m-%d', localtime(int($ms / 1000)));
}

# A consistent snapshot of the live house, copied outside it. `sqlite3 .backup`
# is atomic against the running app; a plain copy is the fallback when sqlite3
# is not on PATH, because most tests only need the schema and a few rows.
sub _copy_live_database {
	my ($dest) = @_;
	my $live = "$ROOT/database/jawnos.db";
	return 0 unless -f $live;
	return 1 if system('sqlite3', $live, ".backup '$dest'") == 0;
	return copy($live, $dest) ? 1 : 0;
}

# A temp copy of a test (scripts/verify_change.pl --range does this for the
# pre-push hook) makes FindBin point at the temp directory, not the checkout;
# the process still runs with the repo as the working directory, so fall back to
# that before giving up.
sub _find_root {
	my @candidates;
	push @candidates, "$FindBin::Bin/.." if defined $FindBin::Bin && length $FindBin::Bin;
	push @candidates, '.';
	push @candidates, $ENV{JAWNOS_ROOT}
		if defined $ENV{JAWNOS_ROOT} && length $ENV{JAWNOS_ROOT};
	for my $candidate (@candidates) {
		my $dir = abs_path($candidate);
		next unless defined $dir;
		return $dir if -f "$dir/perl/subroutines.pl" && -f "$dir/perl/gb.pl";
	}
	return undef;
}

sub _setup {
	return if $_READY;

	$ROOT = _find_root();
	die "JawnOSTest: cannot find the repo root from $FindBin::Bin or the working directory\n"
		unless defined $ROOT;

	$SANDBOX = tempdir('jawnos-test-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	die "JawnOSTest: cannot create a sandbox\n" unless defined $SANDBOX;

	# The files subroutines.pl reaches for by relative path at load time live in
	# perl/. The domain modules under lib/ are lazy (required on first call), and
	# subroutines.pl resolves lib/ from its own real path, so the sandbox needs
	# only the two directory links below for a `perl -c` or a stray relative lookup.
	symlink("$ROOT/perl", "$SANDBOX/perl")
		or die "JawnOSTest: symlink perl: $!\n";
	if (-d "$ROOT/lib") {
		symlink("$ROOT/lib", "$SANDBOX/lib")
			or die "JawnOSTest: symlink lib: $!\n";
	}
	mkdir "$SANDBOX/database" or die "JawnOSTest: mkdir database: $!\n";
	mkdir "$SANDBOX/.president" or die "JawnOSTest: mkdir .president: $!\n";

	# Only what boot reads: device, language, logfile. The logfile is absolute
	# so a missing ~/manager.log is never touched.
	open(my $fh, '>', "$SANDBOX/config.json")
		or die "JawnOSTest: config.json: $!\n";
	print $fh '{"device":"computer","language":"en","environment":"test",'
		. '"logfile":"' . $SANDBOX . '/manager.log",'
		. '"port":"3000","working_port":"3001","ws_port":"3001"}';
	close $fh;

	# Calendar code is only sane in one timezone.
	$ENV{TZ} = 'UTC';
	POSIX::tzset();

	my $cwd  = getcwd();
	my $home = $ENV{HOME};
	$ENV{HOME} = $SANDBOX;   # Websocket.pl touches ~/.president/ws_watcher at boot

	chdir $SANDBOX or die "JawnOSTest: chdir $SANDBOX: $!\n";
	require './perl/subroutines.pl';
	chdir $cwd or die "JawnOSTest: chdir $cwd: $!\n";

	# subroutines.pl resolves the database from its own real path. The sandbox
	# links perl/ to the checkout, so that path is the live install: without the
	# two lines below every test would open (and a writing test would change) the
	# live house database. Give the sandbox its own snapshot and point the app at
	# it before any test touches the database.
	_copy_live_database("$SANDBOX/database/jawnos.db");
	$subs::install_dir = $SANDBOX;

	if (defined $home) { $ENV{HOME} = $home }
	else               { delete $ENV{HOME} }

	$_READY = 1;
}

# The fork runner boots this harness once, so every child would otherwise share
# the parent's install dir - and one shared database. Each child calls this
# before its test runs: a private install dir with its own copy of the house
# snapshot, so two tests saving the same setting cannot race each other (or
# reach the live file).
our $_ISOLATED_PID;

sub isolate {
	return if defined $_ISOLATED_PID && $_ISOLATED_PID == $$;
	return unless defined $SANDBOX;
	my $dir = tempdir('jawnos-test-run-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	die "JawnOSTest: cannot create an isolated install dir\n" unless defined $dir;
	for my $name (qw(perl lib)) {
		next unless -e "$ROOT/$name";
		symlink("$ROOT/$name", "$dir/$name")
			or die "JawnOSTest: symlink $name: $!\n";
	}
	mkdir "$dir/database" or die "JawnOSTest: mkdir database: $!\n";
	mkdir "$dir/.president" or die "JawnOSTest: mkdir .president: $!\n";
	my $source = "$SANDBOX/database/jawnos.db";
	copy($source, "$dir/database/jawnos.db")
		or die "JawnOSTest: copy database: $!\n" if -f $source;
	$subs::install_dir = $dir;
	$_ISOLATED_PID = $$;
	return $dir;
}

_setup();

1;
