#!/usr/bin/env perl
# sync_trace_report.pl - summarize this machine's sync trace (~/sync.log).
#
#   perl scripts/sync_trace_report.pl [--hours N] [--since <ms>] [--json]
#
# The trace is one JSON object per line, written by subs::sync_trace from a pull.
# A trace id ties a peer's pull decision to the table decision and the merge, so
# this rolls them up by peer and table and answers the two questions a watch
# cares about: did this pull read the whole table, and how much did it merge.
#
#   quiet     the map matched the baseline; nothing was read
#   bands     only the moved hourly/weekly bands were walked
#   whole     the pull read the whole table (the row count is under rows)
#   wmark     a watermark read (rows newer than ours)
#   back      a peer's settings row older than the one we held was written
#
use strict;
use warnings;
use FindBin;
use Mojo::JSON qw(decode_json);
use File::Slurp qw(read_file);

my ($hours, $since, $json) = (24, undef, 0);
for (my $i = 0; $i < @ARGV; $i++) {
	my $a = $ARGV[$i];
	if ($a eq '--hours' && defined $ARGV[$i + 1]) { $hours = 0 + $ARGV[$i + 1]; }
	elsif ($a eq '--since' && defined $ARGV[$i + 1]) { $since = 0 + $ARGV[$i + 1]; }
	elsif ($a eq '--json') { $json = 1; }
}
my $home = $ENV{'HOME'} || '.';
my $cut = defined $since ? $since : (time() * 1000) - ($hours * 3600 * 1000);

my %trace;
my @files = grep { -e $_ } map { $home . '/sync.log' . ($_ ? ".$_" : '') } (0, 1, 2, 3, 4);
foreach my $file (@files) {
	my @lines = eval { read_file($file) } or next;
	foreach my $line (@lines) {
		next unless $line =~ /^\s*\{/;
		my $r = eval { decode_json($line) } or next;
		next unless (($r->{'at'} || 0) + 0) >= $cut;
		my $id = $r->{'trace'} || '';
		next unless length $id;
		my $t = $trace{$id} ||= { at => ($r->{'at'} || 0) + 0, peer => '', host => ($r->{'host'} || ''), tables => {}, back => 0 };
		$t->{'peer'} = $r->{'peer'} if defined $r->{'peer'} && length $r->{'peer'};
		my $event = $r->{'event'} || '';
		if ($event eq 'table') {
			my $tb = $t->{'tables'}->{ $r->{'table'} || '?' } ||= {};
			$tb->{'pulls'}++;
			$tb->{'quiet'}++ if ($r->{'path'} || '') eq 'quiet';
			$tb->{'bands'}++ if ($r->{'path'} || '') eq 'band-walk';
			$tb->{'whole'}++ if ($r->{'path'} || '') eq 'whole-table';
			$tb->{'moved'} += ($r->{'moved'} || 0) + 0;
		}
		elsif ($event eq 'read') {
			my $tb = $t->{'tables'}->{ $r->{'table'} || '?' } ||= {};
			$tb->{'wmark'}++ if ($r->{'mode'} || '') eq 'watermark';
			$tb->{'whole_read'}++ if ($r->{'mode'} || '') eq 'whole';
			$tb->{'cut'} = $r->{'cut'} if defined $r->{'cut'};
		}
		elsif ($event eq 'merged') {
			my $tb = $t->{'tables'}->{ $r->{'table'} || '?' } ||= {};
			$tb->{'read'} += ($r->{'read'} || 0) + 0;
			$tb->{'inserted'} += ($r->{'inserted'} || 0) + 0;
			$tb->{'updated'} += ($r->{'updated'} || 0) + 0;
			$tb->{'errors'} += ($r->{'errors'} || 0) + 0;
			$tb->{'short'}++ if $r->{'short'};
		}
		elsif ($event eq 'settings-backward') {
			$t->{'back'}++;
		}
	}
}

# Roll the traces up by peer and table. A peer is named by its short
# signatorial in the pull; the table is the pull's own key.
my %roll;
foreach my $id (keys %trace) {
	my $t = $trace{$id};
	my $peer = length $t->{'peer'} ? $t->{'peer'} : '-';
	foreach my $table (keys %{ $t->{'tables'} }) {
		my $src = $t->{'tables'}->{$table};
		my $dst = $roll{$peer}->{$table} ||= { pulls => 0, quiet => 0, bands => 0, whole => 0, whole_read => 0, wmark => 0, moved => 0, read => 0, inserted => 0, updated => 0, errors => 0, short => 0, back => 0 };
		foreach my $k (qw(pulls quiet bands whole whole_read wmark moved read inserted updated errors short)) {
			$dst->{$k} += ($src->{$k} || 0) + 0;
		}
	}
	$roll{$peer}->{'-'}->{'back'} += $t->{'back'} if $t->{'back'};
}

my @rows;
foreach my $peer (sort keys %roll) {
	foreach my $table (sort keys %{ $roll{$peer} }) {
		my $r = $roll{$peer}->{$table};
		push @rows, { peer => $peer, table => $table, %{$r} };
	}
}

if ($json) {
	print Mojo::JSON::encode_json({ since => $cut, hours => $hours, rows => \@rows }), "\n";
	exit 0;
}

if (!@rows) {
	print "no sync trace for the last " . $hours . "h (looked for " . ($home . '/sync.log') . ")\n";
	exit 0;
}

printf "%-10s %-14s %5s %5s %5s %5s %5s %7s %7s %6s %5s %5s\n",
	'peer', 'table', 'pulls', 'quiet', 'bands', 'whole', 'wmark', 'rows', 'insert', 'update', 'err', 'back';
foreach my $r (@rows) {
	printf "%-10s %-14s %5d %5d %5d %5d %5d %7d %7d %6d %5d %5d\n",
		$r->{'peer'}, $r->{'table'}, $r->{'pulls'}, $r->{'quiet'}, $r->{'bands'},
		$r->{'whole'}, $r->{'wmark'}, $r->{'read'}, $r->{'inserted'}, $r->{'updated'},
		$r->{'errors'}, $r->{'back'};
}
