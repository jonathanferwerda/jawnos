#!/usr/bin/env perl
# records_recover.pl - put back the appointments a repair shortened.
#
#   perl scripts/records_recover.pl [--backup <path>] [--apps a,b,c] [--older-than 1d] [--apply] [--json]
#
# A repair writes a session's end in place, so a genuinely long appointment that a
# sweep swept up can be lost from the live table. This compares an older sealed
# snapshot to the live table and lists the rows the live table made shorter (or
# dropped), then - with --apply - writes the old ends back, stamped with a current
# server_time so every machine takes them on its next sync.
#
# The snapshot defaults to the newest one; name an older one with --backup to reach
# past a repair that has already run. --apply refuses to write unless the newest
# snapshot is younger than ten minutes, taking a fresh one if it is not.
#
# Writes nothing without --apply. This is the tool the Coding agent runs when a
# person reports numbers that do not match what they remember.
use strict;
use warnings;
use FindBin;
require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

# The body is a function, not the file's top level, so a test can call it with
# the domain subs stubbed: this is the one tool that writes records back, and the
# refusal it must never skip (no fresh snapshot, no write) is worth pinning
# without touching a live database.
sub main {
	my (@argv) = @_;
	my ($backup, $apply, $json, $older, $any) = (undef, 0, 0, 86400000, 0);
	my @apps = ('home', 'alone', 'urbaniak', 'eczema', 'snow', 'winter', 'autumn');
	for (my $i = 0; $i < @argv; $i++) {
		$backup = $argv[$i + 1] if $argv[$i] eq '--backup' && defined $argv[$i + 1];
		$apply = 1 if $argv[$i] eq '--apply';
		$json = 1 if $argv[$i] eq '--json';
		$any = 1 if $argv[$i] eq '--any';
		@apps = split /,/, $argv[$i + 1] if $argv[$i] eq '--apps' && defined $argv[$i + 1];
		if ($argv[$i] eq '--older-than' && defined $argv[$i + 1]) {
			my $v = $argv[$i + 1];
			$older = ($v =~ /^(\d+)d$/) ? $1 * 86400000 : ($v =~ /^(\d+)h$/) ? $1 * 3600000 : ($v =~ /^(\d+)$/ ? $1 : 86400000);
		}
	}

	my $scan = subs::records_recover_scan({ backup => $backup, apps => \@apps, older_than_ms => $older });

	if ($scan->{'error'}) { print "records recovery: $scan->{'error'}\n"; return 1; }

	if ($json && !$apply) { print Mojo::JSON::encode_json($scan), "\n"; return 0; }

	my $hrs = sub { my $ms = shift; return defined $ms ? sprintf('%.1fh', $ms / 3600000) : '-'; };
	printf "records recovery - snapshot %s (%s), %d old row(s), apps %s, longer than %s\n\n",
		$scan->{'backup'}, subs::iso_local($scan->{'snapshot_time'}), $scan->{'summary'}{'old_rows'}, join(',', @apps), $hrs->($older);
	printf "%d candidate(s): %d shortened, %d dropped\n\n", $scan->{'summary'}{'candidates'}, $scan->{'summary'}{'shortened'}, $scan->{'summary'}{'missing'};
	foreach my $c ( @{ $scan->{'candidates'} } ) {
		my $flag = '';
		if ($c->{'live_span_ms'} && $c->{'app_duration'}) {
			my $gap = abs($c->{'live_span_ms'} - $c->{'app_duration'});
			$flag = ' <-- live matches the app length; the shorter value is the correct repair' if $gap < 120000;
		}
		printf "%-10s %-16s start %s  was %s now %s  %s%s%s\n",
			$c->{'action'}, $c->{'app'}, subs::iso_local($c->{'start'}),
			$hrs->($c->{'old_span_ms'}), (defined $c->{'live_span_ms'} ? $hrs->($c->{'live_span_ms'}) : 'gone'),
			$c->{'status'}, ($c->{'named'} ? ' (named)' : ''), $flag;
	}

	if (!$apply) { print "\ndone - nothing written. A shorter live value is usually the *correct* repair; only the apps you --apps (or a --uuid you name) are restored unless you pass --any. Use --apply to write them (the tool takes a fresh snapshot first).\n"; return 0; }

	my $fresh = subs::records_backup_ensure_fresh(600000);
	unless ($fresh->{'fresh'}) { print "\nrefusing to apply: no snapshot younger than ten minutes could be taken\n"; return 1; }
	print "\nsafety snapshot: " . ($fresh->{'made'} ? "taken now - $fresh->{'path'}" : "using $fresh->{'path'}") . "\n";

	my $res = subs::records_recover_apply($scan, { any => $any });
	printf "recovery APPLIED: %d restored, %d reinstated%s%s\n", $res->{'restored'}, $res->{'reinstated'},
		($res->{'skipped'} ? ", $res->{'skipped'} left (apps you did not name; pass --any to include)" : ''),
		($res->{'failed'} ? ", $res->{'failed'} failed" : '');
	printf "left alone by the audit from now on: %s\n", (scalar @{ $res->{'exempted'} } ? join(', ', @{ $res->{'exempted'} }) : '(none)');
	return 0;
}

exit(main(@ARGV)) unless caller;
1;
