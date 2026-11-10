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
use File::Path qw(remove_tree);
use File::Spec ();
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

# --- scratch dirs -------------------------------------------------------------

# Every sandbox and isolated install dir belongs to the process that created it.
# File::Temp's own CLEANUP already skips a dir registered before a fork (the key
# is the creating $$), but it never runs when a process is killed, and one full
# copy of the house database per test file then sits in tmpfs until the box is
# rebooted. Track the owner here so the removal is explicit, recursive, and still
# safe across the fork: a child removes only its own isolated dir, never the
# sandbox its siblings share.
#
# The owner is also written into the dir (`_OWNER_STAMP`), so a later run can
# tell a live dir from an abandoned one. A killed process leaves no END, but its
# pid is dead, and the sweep below removes what it left at once instead of
# waiting out the age threshold.
my @SCRATCH;
my $OWNER_STAMP = '.jawnos-owner';

sub _scratch_new {
	my ($template, $what) = @_;
	my $dir = tempdir($template, TMPDIR => 1, CLEANUP => 0);
	die "JawnOSTest: cannot create $what\n" unless defined $dir;
	_stamp_owner($dir);
	return _track_scratch($dir);
}

# The stamp is `<pid> <starttime>`. /proc's starttime (field 22) is what tells a
# recycled pid apart from the owner. It is written before the database copy, so a
# concurrent sweep never sees an unstamped live dir for more than an instant.
sub _stamp_owner {
	my ($dir, $pid, $start) = @_;
	$pid = $$ unless defined $pid;
	$start = _proc_starttime($pid) unless defined $start;
	$start = 0 unless defined $start;
	open(my $fh, '>', File::Spec->catfile($dir, $OWNER_STAMP)) or return 0;
	print $fh "$pid $start\n";
	close $fh;
	return 1;
}

sub _owner_stamp {
	my ($dir) = @_;
	my $file = File::Spec->catfile($dir, $OWNER_STAMP);
	return unless -f $file;
	open(my $fh, '<', $file) or return;
	my $line = <$fh>;
	close $fh;
	return unless defined $line && $line =~ /\A(\d+)\s+(\d+)\s*\z/;
	return ($1, $2);
}

# starttime from /proc/<pid>/stat. The comm field is parenthesised and may hold
# spaces, so split only what follows the last ')' (starttime is field 22 overall,
# index 19 after the comm).
sub _proc_starttime {
	my ($pid) = @_;
	return unless defined $pid && $pid =~ /\A\d+\z/ && $pid > 0;
	open(my $fh, '<', "/proc/$pid/stat") or return;
	my $line = <$fh>;
	close $fh;
	return unless defined $line;
	my $i = rindex($line, ')');
	return unless $i >= 0;
	my @field = split ' ', substr($line, $i + 1);
	return unless @field > 19;
	return $field[19];
}

# Without a recorded starttime fall back to a plain pid probe (no /proc).
sub _owner_alive {
	my ($pid, $start) = @_;
	return 0 unless defined $pid && $pid =~ /\A\d+\z/ && $pid > 0;
	return kill(0, $pid) ? 1 : 0 unless $start;
	my $now = _proc_starttime($pid);
	return defined $now && $now eq $start;
}

# Owner defaults to the creating pid. The tests pass a sentinel owner so they
# can exercise the cleanup without touching the sandbox this process is using.
sub _track_scratch {
	my ($dir, $owner) = @_;
	$owner = $$ unless defined $owner;
	push @SCRATCH, [$dir, $owner];
	return $dir;
}

sub _scratch_cleanup {
	my ($owner) = @_;
	$owner = $$ unless defined $owner;
	my @keep;
	for my $entry (@SCRATCH) {
		my ($dir, $pid) = @$entry;
		if ($pid != $owner) {
			push @keep, $entry;
			next;
		}
		next unless defined $dir && -d $dir;
		remove_tree($dir, { error => \my $err });
	}
	@SCRATCH = @keep;
	return;
}

END { _scratch_cleanup() }

# END does not run when a process is terminated by a signal (a timeout kills the
# suite with TERM, Ctrl-C sends INT). Clean up first, then leave by the signal so
# the exit status still says how the run ended.
sub _install_scratch_signals {
	for my $sig (qw(INT TERM HUP)) {
		$SIG{$sig} = sub {
			_scratch_cleanup();
			$SIG{$sig} = 'DEFAULT';
			kill($sig, $$);
			exit 1;      # the signal is blocked: still leave through END
		};
	}
	return;
}

# --- sweeping what a dead run left -------------------------------------------

# A run killed by SIGKILL (or one whose runner was orphaned) never reaches END,
# so its scratch dirs never go away. The next suite sweeps what is abandoned. A
# dir is safe to remove when the pid in its stamp is dead (or has been reused:
# the starttime no longer matches), or - for a dir written before the stamp, or
# one caught between mkdir and the stamp landing - when it is older than the
# threshold (6 hours, JAWNOS_TEST_SCRATCH_MAX_AGE overrides it) AND named by no
# live process. A live run's own dir stays: its pid is alive and its stamp says
# so, even though after boot the dir is neither its cwd nor an open file. The
# duration-hint file is `jawnos-test-times-<uid>`, which is state, not scratch.
sub sweep_stale_scratch {
	my (%opt) = @_;
	my $max_age = defined $opt{'max_age'} ? $opt{'max_age'}
		: defined $ENV{'JAWNOS_TEST_SCRATCH_MAX_AGE'} ? $ENV{'JAWNOS_TEST_SCRATCH_MAX_AGE'}
		: 6 * 60 * 60;
	my $tmp = defined $opt{'dir'} ? $opt{'dir'} : File::Spec->tmpdir();
	return 0 unless defined $tmp && -d $tmp;

	opendir(my $dh, $tmp) or return 0;
	my @names = grep { _is_scratch_name($_) } readdir($dh);
	closedir $dh;
	return 0 unless @names;

	my $now = time();
	my @live = _live_paths($tmp);
	my $removed = 0;
	for my $name (@names) {
		my $path = File::Spec->catfile($tmp, $name);
		next if -l $path;                     # never follow (or remove) a link
		my @st = lstat($path);
		next unless @st;
		next if _referenced($path, \@live);

		# A stamp names the run that owns the dir: keep it while that pid is
		# alive, and remove what a killed run left without waiting out the age
		# threshold (the stamp lands before the database copy).
		my ($pid, $start) = _owner_stamp($path);
		if (defined $pid) {
			next if _owner_alive($pid, $start);
			remove_tree($path, { error => \my $err });
			$removed++;
			next;
		}

		next if $now - $st[9] < $max_age;     # a run may still be writing it
		remove_tree($path, { error => \my $err });
		$removed++;
	}
	return $removed;
}

sub _is_scratch_name {
	my ($name) = @_;
	return 0 unless $name =~ /\Ajawnos-(?:test|tap)-/;
	return 0 if $name =~ /\Ajawnos-test-times-/;
	return 1;
}

# Every path under $tmp that a live process still names: its cwd, or a file it
# has open. Its absence is what makes an old scratch dir safe to remove.
sub _live_paths {
	my ($tmp) = @_;
	my @paths;
	return @paths unless -d '/proc';
	my $prefix = $tmp =~ m{/\z} ? $tmp : "$tmp/";
	for my $proc (glob('/proc/[0-9]*')) {
		my $cwd = readlink("$proc/cwd");
		push @paths, $cwd if defined $cwd && _under($cwd, $prefix);
		for my $fd (glob("$proc/fd/*")) {
			my $target = readlink($fd);
			push @paths, $target if defined $target && _under($target, $prefix);
		}
	}
	return @paths;
}

sub _under {
	my ($path, $prefix) = @_;
	return index($path, $prefix) == 0;
}

sub _referenced {
	my ($path, $live) = @_;
	for my $named (@$live) {
		return 1 if $named eq $path || index($named, "$path/") == 0;
	}
	return 0;
}

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

	$SANDBOX = _scratch_new('jawnos-test-XXXXXX', 'a sandbox');

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

	# Calendar code is only sane in one timezone. Windows does not implement
	# POSIX::tzset (it dies with "not implemented on this architecture"), so
	# the call is a cache refresh the platform may lack: $ENV{TZ} is the answer
	# and the eval leaves the failing refresh out of every test that loads this.
	$ENV{TZ} = 'UTC';
	eval { POSIX::tzset() };

	my $cwd  = getcwd();
	my $home = $ENV{HOME};
	$ENV{HOME} = $SANDBOX;   # Websocket.pl touches the tree runtime (run/ws_watcher) at boot

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
	_install_scratch_signals();
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
	my $dir = _scratch_new('jawnos-test-run-XXXXXX', 'an isolated install dir');
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
