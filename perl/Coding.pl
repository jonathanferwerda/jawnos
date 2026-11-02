#!/usr/bin/perl

# The Coding agent's own process.
#
# It is not a prefork worker under President: the tree is torn down and rebuilt
# on every restart, and a coding run is minutes long. The master (./jawn) starts
# this process, keeps its pid in ~/.president/coding.pid, replaces it if it
# dies, and - deliberately - leaves it running when it restarts the tree. A run
# in flight therefore survives the restart its own "restart" step asks for, and
# the panel reattaches to it (see lib/JawnOS/Domain/Coding.pm).
#
# Its whole job is to consume the `coding` queue from the same Minion database
# the tree enqueues into. Manager is booted so the job can use the checked
# toolset and the conversation store; no listener is opened.
use strict;
use warnings;
use FindBin;
use POSIX ();
use lib "$FindBin::Bin/../lib";

$ENV{PURPOSE} = 'coding';
$ENV{MOJO_HOME} ||= "$FindBin::Bin/..";
chdir "$FindBin::Bin/.." or die "could not chdir to the tree: $!";
# keep the process list honest for ./jawn's pid-file check and for an operator
$0 = 'perl ./perl/Coding.pl';

require JawnOS;
my $app = JawnOS->new;

my $minion = &subs::coding_minion();
my $worker = $minion->worker;
# One run at a time: two agents writing the tree at once is not a race worth
# losing a commit to.
$worker->status->{jobs} = 1;
# No spare slot either, or Minion keeps capacity for a second job beside the
# first and 'wait' is never reached while a run is going.
$worker->status->{spare} = 0;
# Only the queue a coding run is enqueued on. The tree's own Minion worker
# keeps the default queue, so neither can pick up the other's work.
$worker->status->{queues} = ['coding'];

# This process outlives the tree on purpose, so it is also the one thing that
# would keep running yesterday's code after a push. Between jobs - never while
# one is active - it compares ./VERSION with what it booted under and leaves, so
# the master starts the current build. (Minion emits 'wait' only when there is
# no job in its one slot; 'busy' is the active-job state.)
my $boot_version = &subs::jawn_version();
$worker->on(wait => sub {
	&subs::jawn_version_forget();
	my $now = &subs::jawn_version();
	return unless defined $now && length $now && $now ne $boot_version;
	POSIX::_exit(0);
});

$worker->run;
