#!/usr/bin/env perl

# moon_backfill.pl - fill the moon's history from arithmetic, not a scrape.
#
#   perl scripts/moon_backfill.pl --dry-run
#   perl scripts/moon_backfill.pl --days 365
#   perl scripts/moon_backfill.pl --from 2025-01-01 --to 2026-11-23
#
# The moon app used to read moongiant. A new house has no scraper and no saved
# URL, so the moon is now computed locally (the same Meeus series that finds
# full moons for schedules). This script writes that history into the moon app
# as ordinary measure appointments, one row a day, merging into a row that is
# already there. It never deletes a row and never overwrites another measure.
#
# Run it from this tree. To write into the live house's database while running
# a worktree's copy of the code, point the store at the house:
#
#   JAWNOS_STORE_DIR=/home/jawn/jawnos perl scripts/moon_backfill.pl --days 365
#
# --dry-run reads and counts only. The daily astronomy utility keeps the
# current day up to date after this.
use strict;
use warnings;

use FindBin;
use POSIX ();
use Time::Local qw(timelocal);

my ($days, $from, $to, $dry, $help, $app) = (365, undef, undef, 0, 0, 'moon');
for (my $i = 0; $i < @ARGV; $i++) {
	my $a = $ARGV[$i];
	my $next = $ARGV[$i + 1];
	if ($a eq '--days' && defined $next && $next =~ /^[0-9]+$/) { $days = $next + 0; $i++; }
	elsif ($a eq '--from' && defined $next) { $from = $next; $i++; }
	elsif ($a eq '--to' && defined $next) { $to = $next; $i++; }
	elsif ($a eq '--app' && defined $next) { $app = $next; $i++; }
	elsif ($a eq '--dry-run') { $dry = 1; }
	elsif ($a eq '--help' || $a eq '-h') { $help = 1; }
}
if ($help) {
	print <<'USAGE';
moon_backfill.pl - computed moon history for the moon app

  perl scripts/moon_backfill.pl [--days N] [--from YYYY-MM-DD] [--to YYYY-MM-DD]
                                [--app NAME] [--dry-run]

  --days N         how many days back when --from is not given (default 365)
  --from DATE      first local day to write
  --to DATE        last local day to write (default today)
  --app NAME       the app to write (default moon)
  --dry-run        count the days; write nothing

Writes illumination, moon_phase, moon_age_days and lunar_phase as a measure
row a day, merging by day. Existing measures on a row are kept. Sets the app's
local_source fact so the old web scraper stops fetching it.
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
if (defined $from && !defined $from_ms) { die "moon_backfill: --from must be YYYY-MM-DD\n"; }
if (defined $to && !defined $to_ms) { die "moon_backfill: --to must be YYYY-MM-DD\n"; }

chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

# Name the database this run will touch. A worktree has no live database, and
# a silent "0 rows" from the wrong file would look like a healthy backfill.
my $db_path = eval { &subs::database_path() } || '';
unless (length $db_path && -e $db_path) {
	print STDERR 'moon backfill: no database at ' . ($db_path || '(unknown path)')
		. " - run from the house's tree, or set JAWNOS_STORE_DIR\n";
	exit 2;
}

my $result = &subs::astronomy_backfill({
	app => $app,
	from => $from_ms,
	to => $to_ms,
	days => $days,
	dry_run => $dry,
});

printf "moon backfill: %s\n", $dry ? 'DRY RUN (nothing written)' : 'writing';
printf "  database: %s\n", $db_path;
printf "  app:      %s\n", $app;
printf "  days:     %d\n", $result->{'days'} || 0;
printf "  written:  %d\n", $result->{'written'} || 0;
exit 0;
