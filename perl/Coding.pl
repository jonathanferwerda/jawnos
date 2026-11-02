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
# Only the queue a coding run is enqueued on. The tree's own Minion worker
# keeps the default queue, so neither can pick up the other's work.
$worker->status->{queues} = ['coding'];
$worker->run;
