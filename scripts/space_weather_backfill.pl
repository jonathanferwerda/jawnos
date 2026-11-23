#!/usr/bin/env perl

# space_weather_backfill.pl - historical Kp, Ap, F10.7, sunspot number and Dst.
#
#   perl scripts/space_weather_backfill.pl --dry-run
#   perl scripts/space_weather_backfill.pl --days 365
#   perl scripts/space_weather_backfill.pl --from 2025-01-01 --to 2026-11-23
#
# GFZ Potsdam publishes the daily Kp, Ap, international sunspot number and
# F10.7 series since 1932. Kyoto's World Data Center publishes Dst, provisional
# by month and realtime for the current month. This writes one space_weather
# measure row a day, merging into rows that already exist; it never deletes a
# reading.
#
# Run it from this tree. To write into the live house's database while running
# a worktree's copy of the code, point the store at the house:
#
#   JAWNOS_STORE_DIR=/home/jawn/jawnos perl scripts/space_weather_backfill.pl --days 365
#
# --dry-run reads and counts only. The hourly astronomy utility keeps the
# current day up to date after this.
use strict;
use warnings;

use FindBin;
use Time::Local qw(timelocal);

my ($days, $from, $to, $dry, $help) = (365, undef, undef, 0, 0);
for (my $i = 0; $i < @ARGV; $i++) {
	my $a = $ARGV[$i];
	my $next = $ARGV[$i + 1];
	if ($a eq '--days' && defined $next && $next =~ /^[0-9]+$/) { $days = $next + 0; $i++; }
	elsif ($a eq '--from' && defined $next) { $from = $next; $i++; }
	elsif ($a eq '--to' && defined $next) { $to = $next; $i++; }
	elsif ($a eq '--dry-run') { $dry = 1; }
	elsif ($a eq '--help' || $a eq '-h') { $help = 1; }
}
if ($help) {
	print <<'USAGE';
space_weather_backfill.pl - historical geomagnetic and solar indices

  perl scripts/space_weather_backfill.pl [--days N] [--from YYYY-MM-DD]
                                         [--to YYYY-MM-DD] [--dry-run]

  --days N         how many days back when --from is not given (default 365)
  --from DATE      first local day to write
  --to DATE        last local day to write (default today)
  --dry-run        count the days; write nothing

Writes kp (the day's highest three-hour value), ap, f107, sunspot_number,
dst (the day's mean) and dst_min. Existing measures on a row are kept.
USAGE
	exit 0;
}

sub day_ms {
	my ($text) = @_;
	return undef unless defined $text && $text =~ /^(\d{4})-(\d{2})-(\d{2})$/;
	my ($y, $mo, $d) = ($1, $2, $3);
	return undef unless $mo >= 1 && $mo <= 12 && $d >= 1 && $d <= 31;
	return timelocal(0, 0, 12, $d, $mo - 1, $y) * 1000;
}

my $from_ms = defined $from ? day_ms($from) : undef;
my $to_ms = defined $to ? day_ms($to) : undef;
if (defined $from && !defined $from_ms) { die "space_weather_backfill: --from must be YYYY-MM-DD\n"; }
if (defined $to && !defined $to_ms) { die "space_weather_backfill: --to must be YYYY-MM-DD\n"; }

chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $db_path = eval { &subs::database_path() } || '';
unless (length $db_path && -e $db_path) {
	print STDERR 'space weather backfill: no database at ' . ($db_path || '(unknown path)')
		. " - run from the house's tree, or set JAWNOS_STORE_DIR\n";
	exit 2;
}

my $result = &subs::space_weather_backfill({
	from => $from_ms,
	to => $to_ms,
	days => $days,
	dry_run => $dry,
});

printf "space weather backfill: %s\n", $dry ? 'DRY RUN (nothing written)' : 'writing';
printf "  database: %s\n", $db_path;
printf "  days:     %d\n", $result->{'days'} || 0;
printf "  written:  %d\n", $result->{'written'} || 0;
printf "  months:   %d\n", $result->{'months'} || 0;
exit 0;
