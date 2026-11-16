#!/usr/bin/env perl
# notifications_dedupe.pl - collapse the per-device copies of one notice.
#
# The alarm loop, the budget watcher and the clock ring on every device. Before
# the event-named uuid (lib/JawnOS/Domain/Notify.pm), each wrote its own
# notifications row, so the sync stacked the same notice on every machine. The
# guard stops new ones; this cleans up the rows already written.
#
#   perl scripts/notifications_dedupe.pl [--db PATH] [--window SECONDS] [--apply]
#
# Dry run by default: it prints each cluster and changes nothing. --apply
# deletes the spare rows in one transaction. Rows are clustered by app, title
# and message, and two rows belong to one notice when their timestamps are
# within --window seconds of the cluster's first row (60 by default) - the
# per-device fan-out lands in the same few seconds, while a genuine repeat
# later is its own cluster. A `notevent-` row is kept in preference to a random
# one, because that is the name every peer shares.
use strict;
use warnings;
use FindBin;
use Getopt::Long qw(GetOptions);
use DBI;

my $root = "$FindBin::Bin/..";
my ($db, $window, $apply);
$window = 60;
GetOptions(
	'db=s'     => \$db,
	'window=i' => \$window,
	'apply'    => \$apply,
) or die "usage: $0 [--db PATH] [--window SECONDS] [--apply]\n";
$db = "$root/database/jawnos.db" unless defined $db && length $db;
$window = 60 unless defined $window && $window >= 0;
die "no database at $db\n" unless -e $db;

my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', {
	RaiseError          => 1,
	PrintError          => 0,
	AutoCommit          => 1,
	sqlite_busy_timeout => 5000,
});

my $all = $dbh->selectall_arrayref(
	'select rowid, uuid, app, title, message, timestamp, server_time from notifications',
	{ Slice => {} },
) || [];

my %group;
foreach my $row ( @{$all} ) {
	my $name = join "\x1f", map { defined $_ ? $_ : '' } @{$row}{qw(app title message)};
	push @{ $group{$name} }, $row;
}

my $window_ms = $window * 1000;
my @plan;
my ($clusters, $removals) = (0, 0);
foreach my $name ( sort keys %group ) {
	my @rows = sort {
		($a->{'timestamp'} || 0) <=> ($b->{'timestamp'} || 0)
			|| ($a->{'uuid'} || '') cmp ($b->{'uuid'} || '')
	} @{ $group{$name} };
	my @clusters;
	foreach my $row ( @rows ) {
		my $when = ($row->{'timestamp'} || 0) + 0;
		if ( @clusters && $when - $clusters[-1]->{'anchor'} <= $window_ms ) {
			push @{ $clusters[-1]->{'rows'} }, $row;
		}
		else {
			push @clusters, { anchor => $when, rows => [ $row ] };
		}
	}
	foreach my $cluster ( @clusters ) {
		next unless scalar @{ $cluster->{'rows'} } > 1;
		my @rows = @{ $cluster->{'rows'} };
		my ($keep) = grep { ($_->{'uuid'} || '') =~ /^notevent-/ } @rows;
		$keep ||= $rows[0];
		my @drop = grep { $_->{'rowid'} != $keep->{'rowid'} } @rows;
		$clusters++;
		$removals += scalar @drop;
		push @plan, { keep => $keep, drop => \@drop };
	}
}

printf "notifications dedupe - %s, window %ds, %s\n", $db, $window, ($apply ? 'APPLY' : 'dry run (use --apply to delete)');
foreach my $step ( @plan ) {
	my $keep = $step->{'keep'};
	printf "  %s / %s: %s\n", ($keep->{'app'} // ''), ($keep->{'title'} // ''), substr(($keep->{'message'} // ''), 0, 70);
	printf "    keep row %s at %s%s\n", $keep->{'rowid'}, ($keep->{'timestamp'} // '-'),
		(($keep->{'uuid'} || '') =~ /^notevent-/ ? ' (shared name)' : '');
	printf "    drop row %s at %s\n", $_->{'rowid'}, ($_->{'timestamp'} // '-') for @{ $step->{'drop'} };
}
printf "%d notice group(s), %d duplicate row(s) %s\n", $clusters, $removals, ($apply ? 'removed' : 'to remove');

if ( $apply && @plan ) {
	my $delete = $dbh->prepare('delete from notifications where rowid = ?');
	$dbh->begin_work;
	my $ok = eval {
		foreach my $step ( @plan ) {
			$delete->execute($_->{'rowid'}) for @{ $step->{'drop'} };
		}
		1;
	};
	if (!$ok) {
		my $error = $@ || 'unknown error';
		$dbh->rollback;
		die "cleanup rolled back: $error\n";
	}
	$dbh->commit;
}
