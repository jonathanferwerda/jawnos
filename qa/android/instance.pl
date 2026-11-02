#!/usr/bin/perl
# Boot one QA instance for the Android layer, open the fence hole, mint the
# app's ticket, and wait until the layer is done.
#
#   unshare --user --map-root-user --mount --pid --fork --mount-proc --net -- \
#     perl qa/android/instance.pl --out <dir> [--stop <file>] [--root <qa root>]
#
# It writes <out>/handle.json once the tree answers and the relay sockets exist,
# then sleeps until <out>/stop appears (or the process that started it goes
# away). Teardown is SIGKILL of the instance and the relay, never the app's
# graceful path - that runs manager_killer.pl, whose sweeps are machine-wide.
#
# The relay is Harness's `relay => 1`: inside this net namespace it listens on
# <run>/relay/qa-<port>.sock and forwards to https://127.0.0.1:<port>. The
# matching host half is qa/android/run.sh's job (it must run outside the fence).
#
# The ticket is minted with the tree's own scripts/app_ticket.pl, so the hop is
# authenticated by the QA house's ticket and not by a new back door. The URL
# names 127.0.0.1 and the dock port, exactly as a real machine's does.
#
# Exit: 0 stopped cleanly, 1 the instance could not be built or booted.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib", 'qa/lib';
use Cwd qw(abs_path);
use File::Path qw(make_path);
use JSON::PP;
use POSIX ();
use Time::HiRes qw(sleep time);

use Harness;

my @args = @ARGV;

# Re-exec inside user/PID/net/mount namespaces; the second pass sees
# JAWNOS_QA_NS and falls straight through.
Harness::enter_namespace(@args);

my %opt = (root => $ENV{'JAWNOS_QA_ROOT'} || (($ENV{'HOME'} || '/tmp') . '/jawnos-qa'));
while (@args) {
	my $arg = shift @args;
	if ($arg eq '--out')  { $opt{'out'} = shift @args; next }
	if ($arg eq '--stop') { $opt{'stop'} = shift @args; next }
	if ($arg eq '--root') { $opt{'root'} = shift @args; next }
	if ($arg eq '--no-namespace') { next }
	die "instance.pl: unknown argument $arg\n";
}

my $out = $opt{'out'} or die "usage: instance.pl --out <dir> [--stop <file>] [--root <dir>]\n";
make_path($out);
my $handle = "$out/handle.json";
my $stopfile = $opt{'stop'} || "$out/stop";
unlink $handle if -e $handle;

my $repo = abs_path("$FindBin::Bin/../..");

sub write_handle {
	my (%data) = @_;
	my $tmp = "$handle.tmp";
	open(my $fh, '>', $tmp) or die "instance.pl: $tmp: $!\n";
	print $fh JSON::PP->new->canonical->pretty->encode(\%data);
	close $fh;
	rename $tmp, $handle or die "instance.pl: rename $tmp: $!\n";
	return 1;
}

# run a tree command as the instance would (its HOME, its TMPDIR), capturing
# both streams; returns (ok, text)
sub run_in_tree {
	my ($h, @cmd) = @_;
	my $log = "$h->{'logs'}/instance-cmd.log";
	my $pid = fork();
	die "instance.pl: fork: $!\n" unless defined $pid;
	if (!$pid) {
		POSIX::setsid();
		chdir $h->{'tree'} or POSIX::_exit(126);
		$ENV{'HOME'} = $h->{'home'};
		$ENV{'TMPDIR'} = $h->{'tmp'};
		$ENV{'PERL5LIB'} = $h->{'perl5lib'} if length $h->{'perl5lib'};
		open(STDOUT, '>>', $log) or POSIX::_exit(127);
		open(STDERR, '>&', \*STDOUT) or POSIX::_exit(127);
		exec @cmd;
		POSIX::_exit(127);
	}
	waitpid($pid, 0);
	my $ok = ($? == 0);
	my $text = '';
	if (open(my $fh, '<', $log)) {
		local $/;
		$text = <$fh> // '';
		close $fh;
	}
	return ($ok, $text);
}

# ---------------------------------------------------------------------------
# build and boot
# ---------------------------------------------------------------------------
my $t0 = time;
my $h;
my $booted = eval {
	$h = Harness->new(repo => $repo, root => $opt{'root'}, relay => 1);
	$h->private_tmp();
	$h->bind_live_read_only();
	$h->export_tree();
	$h->seed();
	$h->make_certificate();
	$h->pick_ports();
	# live => 0: the ticket is the login. With live => 1 any request that looks
	# local gets a resident session, which would make the hole unauthenticated.
	$h->write_config(live => 0);
	$h->boot(name => 'android', timeout => 240);
	1;
};
if (!$booted) {
	my $err = $@ || 'unknown';
	write_handle(ok => 0, error => "$err");
	$h->stop_all() if $h && $h->{'booted'};
	exit 1;
}

# ---------------------------------------------------------------------------
# the vault, then the app's ticket
# ---------------------------------------------------------------------------
# The factory seed sets the password but creates no vault; the first real login
# does that. Without it the box office ticket is refused and the app lands on
# the Gate, which is not the page l4 exists to measure.
my ($vault, $vault_error) = ('', '');
{
	my ($ok, $text) = run_in_tree($h, $^X, "$FindBin::Bin/vault_seed.pl",
		$h->{'code'} || '424242');
	if ($ok) {
		$vault = 'ok';
	}
	else {
		$vault = 'no';
		$vault_error = $text;
	}
}

my ($ticket, $ticket_error) = ('', '');
{
	my ($ok, $text) = run_in_tree($h, $^X, 'scripts/app_ticket.pl', 'android', '--save');
	my $path = "$h->{'tree'}/.shots/ticket.txt";
	if ($ok && -f $path && open(my $fh, '<', $path)) {
		$ticket = <$fh> // '';
		close $fh;
		$ticket =~ s/\s+$//;
	}
	$ticket_error = $text unless $ticket;
	$ticket_error = 'app_ticket.pl wrote no .shots/ticket.txt' if !$ticket && !length $ticket_error;
}

my $p = $h->{'ports'};
my $run = $h->run;
write_handle(
	ok         => 1,
	run        => $run,
	root       => $h->root,
	tree       => $h->tree,
	seconds    => time - $t0,
	ports      => { working => $p->{'working'}, dock => $p->{'dock'} },
	sockets    => {
		working => $h->relay_socket($p->{'working'}),
		dock    => $h->relay_socket($p->{'dock'}),
	},
	relay      => $h->relay_state(),
	ticket     => $ticket,
	ticket_error => $ticket_error,
	vault      => $vault,
	vault_error => $vault_error,
	fenced     => ($ENV{'JAWNOS_QA_NO_NS'} ? 0 : 1),
);

# ---------------------------------------------------------------------------
# hold it open until the layer says stop
# ---------------------------------------------------------------------------
my $shutdown = 0;
my $cleanup = sub {
	return if $shutdown;
	$shutdown = 1;
	eval { $h->stop_all() };
	unlink $stopfile if -e $stopfile;
};
$SIG{'TERM'} = $SIG{'INT'} = sub { $cleanup->(); exit 0 };
$SIG{'HUP'} = sub { $cleanup->(); exit 0 };

my $parent = getppid();
while (1) {
	last if -e $stopfile;
	# the layer that started us is gone (reparented to init) - never linger
	last if getppid() != $parent;
	sleep 1;
}

$cleanup->();
exit 0;
