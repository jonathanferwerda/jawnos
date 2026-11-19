#!/usr/bin/env perl
# clothesline_audit.pl - what the clothesline learned, over the last N days.
#
#   perl scripts/clothesline_audit.pl [--days N] [--json] [--help]
#
# Prints one block per learned day: its steps, the rest that opened it, where it
# stands (open, closed, resting or inferred), its waves, and the head the rail
# would hang now. Then the learned profiles and the night window.
#
# Strictly read-only: it reads appointments and the retained sockets, prints,
# and writes nothing to the database, a setting or a file. The day model itself
# is clothesline_rest_episodes / clothesline_day_segments, the same subs the
# rail calls; nothing here special-cases an app.
use strict;
use warnings;
use FindBin;

my ($days, $json, $help) = (7, 0, 0);
for (my $i = 0; $i < @ARGV; $i++) {
	$days = $ARGV[$i + 1] if $ARGV[$i] eq '--days' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^[0-9]+$/;
	$json = 1 if $ARGV[$i] eq '--json';
	$help = 1 if $ARGV[$i] eq '--help' || $ARGV[$i] eq '-h';
}
if ($help) {
	print <<'USAGE';
clothesline_audit.pl - the learned day, over the last N days (read-only)

  perl scripts/clothesline_audit.pl [--days N] [--json]

  --days N   how many calendar days back to report (default 7)
  --json     print the same report as a JSON structure
  --help     this text

Reads the person's own steps (appointments of type usual/stop from a press or a
tag) the way the clothesline does, then prints each learned day, the profile
summary and the night window on the house clock. Writes nothing.
USAGE
	exit 0;
}
$days = 7 unless $days > 0;

require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $now = &subs::rightNow();
my $zone = &subs::clock_zone_house();
my $unzone = &subs::clock_zone_adopt($zone);

# The database this run reads, named in the header. The script chdirs to its own
# tree, so a run from a worktree or a stale checkout reads THAT tree's database -
# and an empty one answers "no learned day" as confidently as the house would.
# Printing the path, and refusing to create one, is what keeps a hollow report
# from being read as a quiet week.
my $db_path = eval { &subs::database_path() } || '';
unless (length $db_path && -e $db_path) {
	print STDERR 'clothesline audit: no database at ' . ($db_path || '(unknown path)') . " - run this from the house's own tree\n";
	exit 2;
}

# The rows the rail itself learns from. clothesline_place_history is the read
# the line uses: at home the last two months, away every visit to that place, and
# always only the person's own press or tag (plus rows from before the source was
# kept). Going through it rather than a hand-rolled query is what makes the audit
# describe the line the person actually sees - and it keeps the model's history
# window the model's own, so --days narrows the report and never the learning.
my ($rows, $window_days, $session_days) = eval { &subs::clothesline_place_history($now) };
unless (defined $rows) {
	print STDERR "clothesline audit: the appointments could not be read\n";
	exit 2;
}
$rows = [] unless ref $rows eq 'ARRAY';
$window_days = 60 unless $window_days;
$session_days = 14 unless $session_days;

# Liveness is what tells a day that was seen from one only inferred. The same
# read clothesline_daily_hours makes; an empty result is a house whose sockets
# were never retained, which the day model treats as no sighting at all.
my $live_raw = eval { &subs::clothesline_device_liveness($now) };
my $live = (ref $live_raw eq 'HASH' && ref $live_raw->{'devices'} eq 'HASH' && %{ $live_raw->{'devices'} }) ? $live_raw : undef;
my $live_devices = $live ? scalar(keys %{ $live->{'devices'} }) : 0;

my %opt = (window_days => $window_days, session_days => $session_days);
my $model = &subs::clothesline_day_segments($rows, $live, $now, %opt);
my $scan = &subs::clothesline_routine_scan($rows, $now, live => $live, %opt);
my $anticipation = &subs::clothesline_sequence_anticipate($scan, $now, limit => 8);
my $head = ref $anticipation->{'list'} eq 'ARRAY' ? $anticipation->{'list'} : [];

# One block per day in the requested window. The segment's own day is the local
# day its wake opened, so a night that ends this morning belongs to today.
my $today = &subs::clothesline_day_index($now);
my $first_day = $today - $days + 1;
my @segments = grep {
	ref $_ eq 'HASH' && defined $_->{'day'} && $_->{'day'} >= $first_day && $_->{'day'} <= $today
} @{ $model->{'segments'} || [] };

my $hhmm = sub {
	my ($ms) = @_;
	return '--:--' unless defined $ms && $ms =~ /^\d/;
	return &subs::clock_zone_text($ms, $zone, '%H:%M');
};
my $date_text = sub {
	my ($ms) = @_;
	return '----------' unless defined $ms && $ms =~ /^\d/;
	return &subs::clock_zone_text($ms, $zone, '%Y-%m-%d %a');
};
my $hour_text = sub {
	my ($h) = @_;
	return '--:--' unless defined $h;
	$h -= 24 * int($h / 24);
	my $mins = int($h * 60 + 0.5) % (24 * 60);
	return sprintf('%02d:%02d', int($mins / 60), $mins % 60);
};
my $span_text = sub {
	my ($ms) = @_;
	return '--' unless defined $ms;
	my $mins = int($ms / 60000 + 0.5);
	return sprintf('%dh %02dm', int($mins / 60), $mins % 60);
};
my $gap_text = sub {
	my ($ms) = @_;
	return '--' unless defined $ms;
	return int($ms / 60000 + 0.5) . 'm';
};

my (@report, %day_out);
for my $i ( 0 .. $#segments ) {
	my $seg = $segments[$i];
	my $times = ref $seg->{'times'} eq 'ARRAY' ? $seg->{'times'} : [];
	my $newest = ($i == $#segments);
	my $opener = ref $seg->{'opened_by'} eq 'HASH' ? $seg->{'opened_by'} : undef;
	my $night = ref $seg->{'night'} eq 'HASH' ? $seg->{'night'} : undef;
	my $waves = ref $seg->{'waves'} eq 'ARRAY' ? $seg->{'waves'} : [];
	my $wave_count = @{$waves} ? $waves->[-1] + 1 : 0;
	my ($state, $closed_at);
	if ($seg->{'resting'}) { $state = 'resting'; $closed_at = $seg->{'closed_at'}; }
	elsif ($seg->{'inferred'}) { $state = 'inferred'; $closed_at = $seg->{'closed_at'}; }
	elsif (defined $seg->{'stop'}) { $state = 'closed'; }
	else { $state = 'open'; }
	if (!defined $closed_at && $night && defined $night->{'start'}) { $closed_at = $night->{'start'}; }

	my $block = {
		day_index => $seg->{'day'},
		date => $date_text->($seg->{'start'}),
		first_step => @{$times} ? &subs::clock_zone_text($times->[0], $zone, '%Y-%m-%d %H:%M') : undef,
		first_step_text => @{$times} ? $hhmm->($times->[0]) : '--:--',
		last_step => @{$times} ? &subs::clock_zone_text($times->[-1], $zone, '%Y-%m-%d %H:%M') : undef,
		last_step_text => @{$times} ? $hhmm->($times->[-1]) : '--:--',
		steps => scalar @{$times},
		rest => $opener ? {
			start_text => $hhmm->($opener->{'start'}),
			stop_text => $hhmm->($opener->{'stop'}),
			length_ms => $opener->{'length'},
			length_text => $span_text->($opener->{'length'}),
			mid_hour => $opener->{'mid_hour'},
			mid_text => $hour_text->($opener->{'mid_hour'}),
			profile_id => (ref $opener->{'profile'} eq 'HASH' ? $opener->{'profile'}{'id'} : undef),
		} : undef,
		state => $state,
		closed_at_text => defined $closed_at ? $hhmm->($closed_at) : undef,
		waves => {
			count => $wave_count,
			gap_ms => $seg->{'gap'},
			gap_text => $gap_text->($seg->{'gap'}),
		},
	};
	if ($newest) {
		$block->{'head'} = {
			list => [ map { { app => $_->{'app'}, wave => (defined $_->{'wave'} ? $_->{'wave'} : 0) } } @{$head} ],
			current_wave => $anticipation->{'current_wave'} || 0,
		};
	}
	push @report, $block;
}

my $selected = ref $model->{'profile'} eq 'HASH' ? $model->{'profile'} : undef;
my @profiles;
for my $p ( @{ $model->{'profiles'} || [] } ) {
	push @profiles, {
		id => $p->{'id'},
		count => $p->{'count'},
		start_hour => $p->{'start_hour'},
		start_text => $hour_text->($p->{'start_hour'}),
		stop_hour => $p->{'stop_hour'},
		stop_text => $hour_text->($p->{'stop_hour'}),
		opener => $p->{'start_app'},
		pause_ms => $p->{'pause'},
		selected => ($selected && defined $p->{'id'} && defined $selected->{'id'} && $p->{'id'} == $selected->{'id'}) ? 1 : 0,
	};
}
my $window = ref $model->{'window'} eq 'HASH' ? $model->{'window'} : undef;
my $night_out = $window ? {
	start_hour => $window->{'start_hour'},
	start_text => $hour_text->($window->{'start_hour'}),
	stop_hour => $window->{'stop_hour'},
	stop_text => $hour_text->($window->{'stop_hour'}),
	rests => $window->{'days'},
} : undef;

my $out = {
	generated_at_text => &subs::clock_zone_text($now, $zone, '%Y-%m-%d %H:%M'),
	database => $db_path,
	days_requested => $days,
	zone => $zone,
	liveness => { used => $live ? 1 : 0, devices => $live_devices, up => ($live ? ($live->{'up'} ? 1 : 0) : 0) },
	days => \@report,
	profiles => \@profiles,
	selected_profile => ($selected ? $selected->{'id'} : undef),
	night_window => $night_out,
	source => $model->{'source'},
};

if ($json) {
	print Mojo::JSON::encode_json($out), "\n";
	$unzone->() if $unzone;
	exit 0;
}

printf "clothesline audit - last %d day(s), house clock %s, generated %s\n",
	$days, $zone, $out->{'generated_at_text'};
printf "database: %s\n", $db_path;
if ($live) {
	printf "liveness: %d device(s), house %s; a night the house was out for is inferred\n",
		$live_devices, ($live->{'up'} ? 'up' : 'down');
}
else {
	print "liveness: none (no retained sockets) - the rests decide alone\n";
}
print "\n";

if (!@report) {
	print "no learned day in this window: too few runs to place a rest.\n";
}
else {
	print "== DAYS\n";
	foreach my $d ( @report ) {
		printf "%s  %s-%s  %d step(s)\n", $d->{'date'}, $d->{'first_step_text'}, $d->{'last_step_text'}, $d->{'steps'};
		if ($d->{'rest'}) {
			printf "  opened by rest %s->%s (%s, mid %s, profile %s)\n",
				$d->{'rest'}{'start_text'}, $d->{'rest'}{'stop_text'}, $d->{'rest'}{'length_text'},
				$d->{'rest'}{'mid_text'}, (defined $d->{'rest'}{'profile_id'} ? $d->{'rest'}{'profile_id'} : '-');
		}
		else {
			print "  opened by nothing in the window (its rest is before it)\n";
		}
		my $when = defined $d->{'closed_at_text'} ? 'at ' . $d->{'closed_at_text'} : '';
		printf "  %s%s\n", $d->{'state'}, (length $when ? " $when" : '');
		printf "  waves %d, gap %s\n", $d->{'waves'}{'count'}, $d->{'waves'}{'gap_text'};
		if ($d->{'head'}) {
			my @pills = map { $_->{'app'} } @{ $d->{'head'}{'list'} };
			my $shown = join(' -> ', @pills[0 .. (@pills > 5 ? 4 : $#pills)]);
			$shown = '(none)' unless length $shown;
			printf "  head now: %s  (wave %d)\n", $shown, $d->{'head'}{'current_wave'};
		}
		print "\n";
	}
}

print "== PROFILES\n";
if (!@profiles) {
	print "no profile learned yet (one rest is not a shape)\n";
}
else {
	printf "%d profile(s) from the rests in this window\n", scalar @profiles;
	foreach my $p ( @profiles ) {
		printf "  profile %s%s  %d rest(s)  %s->%s  opener %s\n",
			(defined $p->{'id'} ? $p->{'id'} : '-'), ($p->{'selected'} ? ' *' : '  '),
			$p->{'count'}, $p->{'start_text'}, $p->{'stop_text'},
			(defined $p->{'opener'} && length $p->{'opener'} ? $p->{'opener'} : '-');
	}
	print "  * = the profile the most recent rest selected\n";
}
if ($night_out) {
	printf "night window %s->%s over %d rest(s)\n", $night_out->{'start_text'}, $night_out->{'stop_text'}, $night_out->{'rests'};
}
else {
	print "night window: not learned yet\n";
}
print "\ndone - nothing written.\n";

$unzone->() if $unzone;
exit 0;
