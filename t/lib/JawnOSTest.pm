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

# A temp copy of a test (scripts/verify_change.pl --range does this for the
# pre-push hook) makes FindBin point at the temp directory, not the checkout;
# the process still runs with the repo as its working directory, so fall back to
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
		return $dir if -f "$dir/subroutines.pl" && -f "$dir/gb.pl";
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

	# The four files subroutines.pl reaches for by relative path at load time.
	for my $file (qw(subroutines.pl gb.pl Websocket.pl language.pl)) {
		symlink("$ROOT/$file", "$SANDBOX/$file")
			or die "JawnOSTest: symlink $file: $!\n";
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
	require './subroutines.pl';
	chdir $cwd or die "JawnOSTest: chdir $cwd: $!\n";

	if (defined $home) { $ENV{HOME} = $home }
	else               { delete $ENV{HOME} }

	$_READY = 1;
}

_setup();

1;
