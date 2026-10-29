#!/usr/bin/env perl
# internet_appointments_repair.pl - normalise the rows the Internet site tick
# wrote before it stored the session sign the way every other close path does.
#
#   perl scripts/internet_appointments_repair.pl            # dry run
#   perl scripts/internet_appointments_repair.pl --apply    # write
#
# The tick now writes source 'internet' and a NEGATIVE accrual duration
# (start - stop). Older rows carry source 'Internet' and a positive duration,
# so the timeline paints their band backwards. This flips the sign, lowercases
# the source, and fills a missing stop_timestamp (start + abs(duration)).
# Idempotent: only rows with lower(source) = 'internet' are touched.
use strict;
use warnings;
use FindBin;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './subroutines.pl';

my $apply = grep { $_ eq '--apply' } @ARGV;

my $rows = eval {
	subs::db_query(q{
		select rowid, app, uuid, type, timestamp, stop_timestamp, duration, source
		  from appointments
		 where lower(source) = 'internet'
		 order by cast(timestamp as integer)
	})->hashes;
} || [];

my @changes;
foreach my $row ( @{$rows} ) {
	my %data;
	my @why;

	my $source = $row->{'source'} // '';
	if ($source ne 'internet') {
		$data{'source'} = 'internet';
		push @why, "source $source -> internet";
	}

	my $type = $row->{'type'} // '';
	my $raw = $row->{'duration'} // '';
	my $length;
	if ($raw =~ /^\s*([+-]?)(\d+(?:\.\d+)?)\s*$/) {
		my ($sign, $length_text) = ($1, $2);
		$length = $length_text + 0;
		# start/record/stop are the negative accrual; a positive value is the
		# old Internet sign (or a badly signed peer copy)
		if ($type =~ /^(?:start|record|stop)$/ && $length > 0 && $sign ne '-') {
			$data{'duration'} = '-' . $length_text;
			push @why, "duration $raw -> -$length_text";
		}
	}

	my $stop_ts = $row->{'stop_timestamp'} // '';
	my $timestamp = $row->{'timestamp'} // '';
	if ($type eq 'stop' && $stop_ts !~ /^-?\d+(?:\.\d+)?$/
		&& $timestamp =~ /^-?\d+(?:\.\d+)?$/ && defined $length && $length != 0) {
		my $stop = (0 + $timestamp) + abs($length);
		$data{'stop_timestamp'} = $stop;
		push @why, "stop_timestamp -> $stop";
	}

	next unless scalar @why;
	push @changes, { row => $row, data => \%data, why => \@why };
}

printf "internet appointment repair - %d row(s) from source 'Internet'/'internet'\n\n", scalar @{$rows};
foreach my $change ( @changes ) {
	my $row = $change->{'row'};
	printf "row %-8s %-18s %-6s dur %-12s stop %-14s  %s\n",
		($row->{'rowid'} // '-'), ($row->{'app'} // '-'), ($row->{'type'} // '-'),
		($row->{'duration'} // '-'), ($row->{'stop_timestamp'} // '-'),
		join('; ', @{ $change->{'why'} });
}

if (!scalar @changes) {
	print "\nnothing to repair.\n";
	exit 0;
}
if (!$apply) {
	printf "\n%d row(s) would change. Dry run - nothing written. Re-run with --apply.\n", scalar @changes;
	exit 0;
}

my ($ok, $failed) = (0, 0);
foreach my $change ( @changes ) {
	my $row = $change->{'row'};
	my $uuid = $row->{'uuid'} // '';
	if (!length $uuid) {
		warn "skipping row " . ($row->{'rowid'} // '?') . ": no uuid\n";
		$failed++;
		next;
	}
	my $done = eval { subs::db_update('appointments', $change->{'data'}, { app => $row->{'app'}, uuid => $uuid }); 1 };
	if (!$done) {
		warn "row $uuid failed: $@\n";
		$failed++;
	}
	else {
		$ok++;
	}
}
printf "\napplied: %d row(s), %d failed.\n", $ok, $failed;
exit($failed ? 1 : 0);
