#!/usr/bin/env perl
# silence_probe.pl - why an app does (or does not) quiet the house, read-only.
#
#   perl scripts/silence_probe.pl [app] [--json] [--help]
#
# Prints the two answers the silence code keeps apart: what the start hook asks
# (sound_app_level, which honours an app's own device row) and what the alarm
# pass sees (sound_profile_rows, the bulk read). When they disagree, a start can
# engage silence and the next pass cannot confirm it - or silence never engages.
# Also names this machine's device, the house state, the open sessions that
# would own silence, and whether the native bridge is reachable.
#
# Strictly read-only: every getter is benign, no tick runs, no state is written
# and no device command is sent. Safe to run beside the live manager.
use strict;
use warnings;
use utf8;

my ($app, $json, $help);
for (my $i = 0; $i < @ARGV; $i++) {
	my $a = $ARGV[$i];
	$json = 1 if $a eq '--json';
	$help = 1 if $a eq '--help' || $a eq '-h';
	$app = $a if $a !~ /^-/ && !defined $app;
}
if ($help) {
	print <<'USAGE';
silence_probe.pl - why an app does (or does not) quiet the house (read-only)

  perl scripts/silence_probe.pl [app] [--json]

  app     the app to explain (default: every app with a profile or a session)
  --json  print the same facts as one JSON object
  --help  this text

Reads the house silence state, the app's profile rows on this device and the
house row, the open sessions, and the levels the start hook and the alarm pass
compute. Writes nothing and sends no device command.
USAGE
	exit 0;
}

use FindBin;
my $root = -e 'perl/subroutines.pl' ? '.' : "$FindBin::Bin/..";
chdir $root or die "silence probe: cannot enter the tree at $root: $!\n";
require './perl/subroutines.pl';

my $db_path = eval { &subs::database_path() } || '';
unless (length $db_path && -e $db_path) {
	print STDERR 'silence probe: no database at ' . ($db_path || '(unknown path)')
		. " - run this from the house's own tree\n";
	exit 2;
}

my $device = eval { &subs::device_setter() } || '';
my $state = eval { &subs::silence_state() } || {};
my $house_level = eval { &subs::sound_house_setting_level() } || '?';
my $house_silence = ($house_level eq 'silence') ? 1 : 0;
my $now = eval { &subs::rightNow() } || (time * 1000);

# The open sessions, and the level the alarm pass reads for each (the bulk
# answer, not the per-app one). A row of type start/record with no stop_seen is
# an owner candidate; only a Silence level makes it an owner.
my $open = eval {
	&subs::db_query(
		"select uuid, app, type, timestamp, stop_seen from appointments "
		. "where stop_seen is null and type in ('start','record') and timestamp <= ?",
		$now
	)->hashes;
} || [];
my $rows = eval { &subs::sound_profile_rows() } || { profile => {}, legacy => {} };
my (@open, %by_app);
foreach my $row ( @{$open} ) {
	next unless ref $row eq 'HASH';
	my $name = $row->{'app'} // '';
	my $level = &subs::sound_profile_rows_level($rows, $name);
	my $entry = {
		uuid => $row->{'uuid'} // '',
		app => $name,
		type => $row->{'type'} // '',
		timestamp => $row->{'timestamp'},
		bulk_level => $level,
		owns => ($level eq 'silence') ? 1 : 0,
	};
	push @open, $entry;
	$by_app{$name} = $entry;
}

my @apps;
if (defined $app && length $app) {
	@apps = ($app);
}
else {
	my %seen;
	@apps = grep { defined $_ && length $_ && !$seen{$_}++ }
		(map { $_->{'app'} } @open),
		sort keys %{ $rows->{'profile'} || {} },
		sort keys %{ $rows->{'legacy'} || {} };
}

# The held owners and whether their rows have already closed here. This is the
# check silence_tick uses to decide between the sync-window hold and a release.
my $owners = ref $state->{'owners'} eq 'ARRAY' ? $state->{'owners'} : [];
my $owners_closed = @{$owners} ? eval { &subs::silence_tick_owners_closed($owners) } : 0;

my $token_file = eval { &subs::device_bridge_token_file() } || '';
my $bridge = 0;
if ($device eq 'mobile') {
	my $sock = eval { &subs::device_bridge_connect() };
	if ($sock) { $bridge = 1; close $sock; }
}

my %report = (
	ok => 1,
	database => $db_path,
	device => $device,
	house_level => $house_level,
	house_silence => $house_silence ? 1 : 0,
	state => $state,
	owners_closed => $owners_closed ? 1 : 0,
	native => {
		mobile => ($device eq 'mobile') ? 1 : 0,
		token => (length $token_file && -e $token_file) ? 1 : 0,
		bridge => $bridge ? 1 : 0,
	},
	apps => [ map { {
		app => $_,
		app_level => scalar eval { &subs::sound_app_level($_) },
		legacy_setting => scalar eval { &subs::silence_app_setting($_) },
		hook_on => scalar eval { &subs::silence_app_setting_on($_) },
		bulk_level => &subs::sound_profile_rows_level($rows, $_),
		open => $by_app{$_} ? $by_app{$_} : undef,
	} } @apps ],
);

if ($json) {
	require Mojo::JSON;
	print Mojo::JSON::encode_json(\%report), "\n";
	exit 0;
}

print 'silence probe - ' . (defined $app && length $app ? $app : 'house') . "\n";
print "database: $db_path\n";
print "device: $device   (native push is a no-op off a phone)\n";
print 'house level: ' . $house_level . '   state: '
	. ($state->{'active'} ? 'ACTIVE' : 'inactive')
	. ' owners=[' . join(',', @{$owners}) . ']'
	. ($state->{'house'} ? ' house=1' : '') . "\n";
if ($state->{'active'}) {
	print 'held owners: ' . (@{$owners} ? join(',', @{$owners}) : '(none)')
		. ' -> ' . ($owners_closed ? 'rows closed here (tick releases)' : 'row absent or still open (tick holds)') . "\n";
}
print 'native: mobile=' . $report{'native'}->{'mobile'}
	. ' token=' . $report{'native'}->{'token'}
	. ' bridge=' . $report{'native'}->{'bridge'} . "\n";
print "\n";

my $diverged = 0;
foreach my $a ( @{ $report{'apps'} } ) {
	print $a->{'app'} . ":\n";
	print '  start hook (sound_app_level): ' . $a->{'app_level'}
		. '   legacy box=' . ($a->{'legacy_setting'} eq '' ? '(none)' : $a->{'legacy_setting'})
		. '   hook_on=' . $a->{'hook_on'} . "\n";
	print '  alarm pass (bulk):            ' . $a->{'bulk_level'} . "\n";
	$diverged++ if $a->{'app_level'} ne $a->{'bulk_level'};
	if ($a->{'open'}) {
		print '  open session: ' . $a->{'open'}->{'uuid'} . ' (' . $a->{'open'}->{'type'} . ")\n";
		print '  -> ' . ($a->{'open'}->{'owns'} ? 'owns silence' : 'does NOT own silence (bulk level is not Silence)') . "\n";
	}
	else {
		print "  open session: none\n";
	}
	print "\n";
}

if ($diverged) {
	print "DIVERGENCE: the start hook and the alarm pass disagree.\n"
		. "  A start hook can engage, but the next pass cannot confirm the owner,\n"
		. "  so the state is held for the sync window and then released; or the\n"
		. "  press path never calls the hook and silence never engages at all.\n";
}
exit 0;
