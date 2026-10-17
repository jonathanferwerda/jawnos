#!/usr/bin/env perl
# signatorial_audit.pl - show every place this database names a machine.
#
#   perl scripts/signatorial_audit.pl [--db PATH] [--id ID] [--label NAME]
#
# A signatorial is stored in three shapes: a direct column (backups,
# continent, remote_machines, sync_cursors, sync_log, tunnels), a bare id in a
# reference column (settings.device, backups.recipient, cache.uuid, ...), and
# inside JSON or a notification (remote_machines.data, devices.address,
# settings.value, ...). This prints all three, classifies each value as this
# machine, a current peer, or unknown, and ignores NULL/empty rows. Read-only.
use strict;
use warnings;
use FindBin;
use DBI;
use Getopt::Long;

my $db_file = "$FindBin::Bin/../database/jawnos.db";
my $local_id = '';
my $label = '';
GetOptions('db=s' => \$db_file, 'id=s' => \$local_id, 'label=s' => \$label) or exit 2;

if (!$local_id) {
	my $file = "$ENV{HOME}/.jawnos_signatorial_id";
	if (open my $fh, '<', $file) {
		$local_id = <$fh>;
		chomp $local_id;
		close $fh;
	}
}
die "no local id (use --id)\n" unless $local_id =~ /^[0-9a-f]{16,64}$/i;
$local_id = lc $local_id;

my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", '', '', {
	RaiseError => 1, AutoCommit => 1, sqlite_use_immediate_transaction => 0,
});
$dbh->do('PRAGMA busy_timeout = 5000');

my %ids = ($local_id => 'this machine');
my $peers = $dbh->selectall_arrayref(
	'SELECT signatorial, hostname FROM remote_machines WHERE signatorial IS NOT NULL AND signatorial <> ""'
);
for my $p (@$peers) { $ids{$p->[0]} = 'peer ' . ($p->[1] || '?'); }

my @tables = map { $_->[0] } @{ $dbh->selectall_arrayref(
	"SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
) };
my %cols;
for my $t (@tables) {
	$cols{$t} = $dbh->selectall_arrayref(qq{PRAGMA table_info("$t")});
}

my %unknown;
sub classify {
	my ($id, $where) = @_;
	if (!$id) { return '(empty)' }
	return $ids{$id} if exists $ids{$id};
	$unknown{$id}{$where}++;
	return 'UNKNOWN';
}

print '== ', ($label || $db_file), " ==\n";
print "local id: $local_id\n";
for my $id (sort keys %ids) { print "  $id  $ids{$id}\n" }
print "\n";

print "-- direct signatorial columns --\n";
for my $t (@tables) {
	for my $c (@{ $cols{$t} || [] }) {
		my $name = $c->[1];
		next unless lc($name) eq 'signatorial';
		my $rows = $dbh->selectall_arrayref(qq{SELECT "$name", count(*) FROM "$t" GROUP BY "$name"});
		print "  $t.$name\n";
		for my $r (@$rows) {
			my $v = defined $r->[0] ? lc $r->[0] : '';
			next unless length $v;
			printf "    %-34s %6d  %s\n", $v, $r->[1], classify($v, "$t.$name");
		}
	}
}

print "\n-- bare reference columns --\n";
my @bare = qw(
	backups.recipient cache.uuid tickets.debriefer ai_house.machine
	ai_jobs.owner settings.device
);
for my $ref (@bare) {
	my ($t, $name) = split /\./, $ref, 2;
	next unless $cols{$t} && grep { $_->[1] eq $name } @{ $cols{$t} };
	my $rows = $dbh->selectall_arrayref(qq{SELECT "$name", count(*) FROM "$t" GROUP BY "$name"});
	my @hits;
	for my $r (@$rows) {
		my $v = defined $r->[0] ? lc $r->[0] : '';
		next unless $v =~ /^[0-9a-f]{32}$/;
		push @hits, [ $v, $r->[1], classify($v, $ref) ];
	}
	next unless @hits;
	print "  $ref\n";
	for my $h (@hits) { printf "    %-34s %6d  %s\n", @$h }
}

print "\n-- signatorial values inside JSON/HTML text --\n";
my @json = qw(
	devices.address remote_machines.buttons remote_machines.data
	remote_machines.mirrors settings.value
);
for my $ref (@json) {
	my ($t, $name) = split /\./, $ref, 2;
	next unless $cols{$t} && grep { $_->[1] eq $name } @{ $cols{$t} };
	my $rows = $dbh->selectall_arrayref(
		qq{SELECT "$name", count(*) FROM "$t" WHERE typeof("$name")='text' AND lower("$name") LIKE '%signatorial%' GROUP BY "$name"}
	);
	my %seen;
	for my $r (@$rows) {
		my $v = $r->[0] // '';
		while ($v =~ /signatorial\W{0,4}[:=]\W{0,4}([0-9a-f]{32})/ig) {
			$seen{lc $1} += $r->[1];
		}
	}
	next unless %seen;
	print "  $ref\n";
	for my $v (sort keys %seen) {
		printf "    %-34s %6d  %s\n", $v, $seen{$v}, classify($v, $ref);
	}
}

# A new table or message can carry the key without being on the lists above.
for my $t (@tables) {
	for my $c (@{ $cols{$t} || [] }) {
		my $name = $c->[1];
		my $type = uc($c->[2] // '');
		next if $type =~ /BLOB/;
		next if grep { $_ eq "$t.$name" } @json;
		my $n = $dbh->selectrow_array(
			qq{SELECT count(*) FROM "$t" WHERE typeof("$name")='text' AND lower("$name") LIKE '%signatorial%'}
		);
		next unless $n;
		my %seen;
		my $rows = $dbh->selectall_arrayref(
			qq{SELECT "$name" FROM "$t" WHERE typeof("$name")='text' AND lower("$name") LIKE '%signatorial%'}
		);
		for my $r (@$rows) {
			while (($r->[0] // '') =~ /signatorial\W{0,4}[:=]\W{0,4}([0-9a-f]{32})/ig) {
				$seen{lc $1}++;
			}
		}
		next unless %seen;
		print "  $t.$name\n";
		for my $v (sort keys %seen) {
			printf "    %-34s %6d  %s\n", $v, $seen{$v}, classify($v, "$t.$name");
		}
	}
}

if (%unknown) {
	print "\n-- unknown ids (not this machine and not in remote_machines) --\n";
	for my $id (sort keys %unknown) {
		my @where = map { "$_ ($unknown{$id}{$_})" } sort keys %{ $unknown{$id} };
		print "  $id  ", join(', ', @where), "\n";
	}
	print "\nHistorical backups under a pre-migration id are expected; a live\n";
	print "settings/continent/sync/remote_machines reference is not.\n";
}
