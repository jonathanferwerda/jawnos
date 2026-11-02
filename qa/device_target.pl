#!/usr/bin/perl
# Which machine runs the nightly suite?
#
# The choice is Configure -> Plat -> QA, stored as the house setting
# `__president/qa_nightly_device` (device 'all'). It holds the signatorial of a
# computer or server, or '' for the local fallback. The systemd units read it
# with ExecCondition:
#
#   ExecCondition=/usr/bin/perl /home/jawn/jawnos/qa/device_target.pl
#
# Exit 0 means this machine is the chosen one (or there is no choice, or this
# machine cannot prove its own identity - the local fallback is always safe).
# Exit 1 means another machine was chosen, and systemd skips this unit without
# marking it failed. Install the unit on every machine that might be chosen;
# only the chosen one runs.
#
# No app boot and no library: this runs before the QA service, under the same
# read-only fence, so it reads the database and the identity file directly.

use strict;
use warnings;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $explain = grep { $_ eq '--explain' } @ARGV;

my $script = abs_path(__FILE__) || __FILE__;
my $repo = dirname(dirname($script));
my $db = "$repo/database/jawnos.db";

sub say_out {
	my ($line) = @_;
	print STDERR "qa/device_target: $line\n" if $explain;
}

sub read_setting {
	my ($path) = @_;
	return '' unless -e $path;
	my $sql = "select value from settings where app = '__president' and setting = 'qa_nightly_device'"
		. " order by case when device = 'all' then 0 else 1 end, cast(server_time as integer) desc limit 1";
	# -readonly keeps the QA fence intact (the repo is bind-mounted read-only,
	# and SQLite would otherwise want to create a -shm beside a WAL database).
	# It still sees rows sitting in the WAL, unlike immutable=1.
	open(my $fh, '-|', 'sqlite3', '-readonly', $path, $sql) or return '';
	my $value = <$fh>;
	close $fh;
	$value = '' unless defined $value;
	$value =~ s/\s+$//;
	$value =~ s/^\s+//;
	return $value;
}

sub read_identity {
	my @files = (
		($ENV{'HOME'} || '') . '/.jawnos_signatorial_id',
		"$repo/database/.jawnos_signatorial_id",
	);
	foreach my $file (@files) {
		next unless length $file && -e $file;
		open(my $fh, '<', $file) or next;
		my $id = <$fh>;
		close $fh;
		$id = '' unless defined $id;
		$id =~ s/\s+//g;
		return lc $id if $id =~ /^[0-9a-f]{16,64}$/i;
	}
	return '';
}

my $chosen = read_setting($db);
$chosen = lc $chosen if $chosen =~ /^[0-9a-f]{16,64}$/i;

# No choice: the local fallback keeps every machine's own suite running.
if ($chosen eq '') {
	say_out("no nightly device is chosen; running here");
	exit 0;
}

my $mine = read_identity();
# A machine that cannot prove its own identity must not silently stop running
# the suite: leave the local fallback in place.
if ($mine eq '') {
	say_out("this machine has no identity file; keeping the local fallback");
	exit 0;
}

if ($chosen eq $mine) {
	say_out("this machine ($mine) is the chosen nightly machine");
	exit 0;
}

say_out("the nightly belongs to $chosen; this machine is $mine, so skipping");
exit 1;
