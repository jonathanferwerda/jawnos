#!/usr/bin/perl

use File::Slurp;
use Mojo::JSON qw/decode_json encode_json/;

# Stops everything jawn runs: the master, the President/Manager/websocket tree,
# the BLE client, ollama, and whatever still holds the web port.
#
# Called two ways:
#   ./jawn Ctrl+C         no arguments -- the master is the caller and takes
#                         itself down, so it is left alone here
#   the app's Stop button "master" -- ./jawn is taken down too. The app used to
#                         only stop the terminal session, which SIGKILLs the
#                         master before its Ctrl+C handler runs; the tree
#                         survived, and a surviving master keeps
#                         ~/.process_watch answering, so the next start would
#                         see "another jawn is running" and stand down
#                         (2026-10-10: after Stop the web UI was still up and
#                         the phone ran hot for an hour).
#
# The sweeps take each program by process name and again by full command line:
# the same script runs as "President.pl" on one machine and "perl
# ./President.pl" on another, and a "perl <script>" parent has only "perl" for
# a name.

my $self = shift;
my $kill_master = 0;
if (($self || '') =~ /^master$/i) {
	$kill_master = 1;
	$self = '';
}
my $uname = `uname -r`;
print "Protecting " . $self . "\n\n\n";

my $allowed = 1;
$allowed = 0 unless $self =~ /[0-9]/gi;
$self = 000000000000 unless $self;

sub killer_sweep {
	my ($pattern, $label) = @_;
	print "killing $label\n";
	`pkill '$pattern' 2>/dev/null`;
	`pkill -f '$pattern' 2>/dev/null`;
	for my $round (1 .. 4) {
		sleep .3;
		my @pids = grep { /^[0-9]+$/ } split "\n", `pgrep '$pattern' 2>/dev/null`;
		push @pids, grep { /^[0-9]+$/ } split "\n", `pgrep -f '$pattern' 2>/dev/null`;
		last unless scalar @pids;
		foreach my $pid (@pids) {
			next if $pid == $$ || $pid == getppid();
			`kill -9 $pid` unless $pid == $self;
		}
	}
}

if ($kill_master) {
	# before anything has a chance to outlive it: the master's process name is
	# plain "perl", so only the command line finds it
	killer_sweep('perl [.]/jawn', 'the jawn master');
}

foreach my $k ( 'President[.]pl', 'teletype[.]pl', 'watch[.]pl', 'Manager[.]pl', 'Websocket[.]pl', 'termux-tts-spea', 'sshpass' ) {
	killer_sweep($k, $k);
}

# ollama: jawn spawns its own 'ollama serve' child; on the phone a runit
# service wants a second one, dies on the taken port, and runsv retries it
# forever (a process spawn a second, for as long as the phone is up). Take the
# service down first, and leave the down file: the sweep below kills runsv too
# (its command line names ollama), and the runsv that runsvdir starts in its
# place would otherwise bring the service up again. jawn starts its own ollama
# on the next Start; 'sv up ollama' brings the service back if it is wanted.
my $prefix = $ENV{PREFIX} || '/data/data/com.termux/files/usr';
my $ollama_service = "$prefix/var/service/ollama";
if (-x "$prefix/bin/sv" && -d $ollama_service) {
	print "starting the ollama service down\n";
	`export SVDIR=$prefix/var/service; $prefix/bin/sv down ollama 2>/dev/null`;
	eval { write_file("$ollama_service/down", "") };
}
killer_sweep('ollama', 'ollama');

# the BLE client daemon a jawn worker starts ('perl <home>/jawnos/scripts/
# jawn-bt listen'); its process name is plain "perl"
killer_sweep('jawn-bt listen', 'the jawn-bt client');

# the web port: whatever still answers there lost its tree, so take the pids
# the socket names. config.json knows the port; 3000 is the manager's own dock
# port on top of that. (read_file must be in scalar context: a list-returning
# read hands decode_json only the first line and the port silently defaults.)
my $working_port = 3000;
my $config_file = -e './config.json' ? './config.json' : ($ENV{HOME} ? "$ENV{HOME}/jawnos/config.json" : '');
if ($config_file && -e $config_file) {
	my $config = eval { return decode_json scalar read_file($config_file) };
	$working_port = $config->{'working_port'} if eval { $config->{'working_port'} };
}
my %seen_port;
my $running_pids = '';
foreach my $listening_port ( $working_port, 3000 ) {
	next if $seen_port{$listening_port}++;
	my $block = `ss -tlnp 2>/dev/null | grep ":$listening_port " | sed -n "s/.*pid=\\([0-9]*\\).*/\\1/p"`;
	$running_pids .= $block;
}
print "ports ($working_port, 3000): " . $running_pids . "\n";
foreach my $p ( grep { /^[0-9]+$/ } split /\n/, $running_pids ) {
	next if $p == $$ || $p == $self;
	`kill -9 $p`;
	print "killed the listener\n";
}

if ($uname =~ /android/) {
	`pkill ssh`;
	`sshd`;
}
