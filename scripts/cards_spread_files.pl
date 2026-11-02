#!/usr/bin/perl
# Take the spread montages out of the cards settings.
#
# A spread history entry used to keep a ~200 KB montage PNG as a data URI, so
# every device's row carried the same picture and every sync and settings read
# paid for it. The montage is only a render of three deck files that ship with
# the tree, and the entry already names them in its title. Store the file names
# under "cards" instead; card_picker builds the picture for a reply, and the
# window draws the three files straight from /images/cards/.
#
# Dry-run by default. --apply takes a backup, rewrites only rows that change,
# stamps server_time so the sync rail carries the smaller rows, and reindexes.
# --vacuum reclaims the freed pages.
#
#   perl scripts/cards_spread_files.pl
#   perl scripts/cards_spread_files.pl --apply --vacuum

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use DBI;
use File::Path qw(make_path);
use POSIX qw(strftime);
use Time::HiRes qw(time);
use JSON::PP ();

my ($apply, $vacuum, $no_backup, $database) = (0, 0, 0, '');
for my $arg (@ARGV) {
	if ($arg eq '--apply')       { $apply = 1 }
	elsif ($arg eq '--vacuum')    { $vacuum = 1 }
	elsif ($arg eq '--no-backup') { $no_backup = 1 }
	elsif ($arg eq '--help' || $arg eq '-h') {
		print "usage: $0 [--apply] [--vacuum] [--no-backup] [--database PATH]\n";
		exit 0;
	}
	elsif ($arg =~ /^--database=(.+)$/) { $database = $1 }
	else { die "unknown argument: $arg\n" }
}

my $root = "$FindBin::Bin/..";
$database ||= "$root/database/jawnos.db";
die "no database at $database\n" unless -f $database;
my $deck = "$root/public/images/cards";
die "no deck at $deck\n" unless -d $deck;

my $dbh = DBI->connect("dbi:SQLite:dbname=$database", '', '', {
	RaiseError => 1,
	PrintError => 0,
	AutoCommit => 1,
	sqlite_busy_timeout => 15000,
	sqlite_unicode => 1,
});
$dbh->do('PRAGMA journal_mode=WAL');
$dbh->do('PRAGMA synchronous=NORMAL');

my $json = JSON::PP->new->utf8;
my @plan;
my ($rows, $entries, $kept, $skipped) = (0, 0, 0, 0);
my ($before_bytes, $after_bytes) = (0, 0);

for my $r ( @{ $dbh->selectall_arrayref(q{select uuid, device, value from settings where app = 'cards' and setting = 'spread'}) } ) {
	my ($row_id, $device, $value) = @{$r};
	$rows++;
	$before_bytes += length($value || '');
	my $history = eval { $json->decode($value || '') };
	unless (ref $history eq 'ARRAY') {
		$skipped++;
		$after_bytes += length($value || '');
		next;
	}
	my $changed = 0;
	for my $entry ( @{$history} ) {
		next unless ref $entry eq 'HASH';
		$entries++;
		next if ref $entry->{'cards'} eq 'ARRAY';
		next unless defined $entry->{'stream'} && $entry->{'stream'} =~ /^data:/;
		my @names = map { my $n = lc $_; $n =~ s/^\s+|\s+$//g; length $n ? "$n.png" : () }
			split /<br\s*\/?>/i, ($entry->{'title'} // '');
		if (!@names || grep { !-e "$deck/$_" } @names) {
			# a card left the deck: keep the picture rather than lose the entry
			$skipped++;
			next;
		}
		$entry->{'cards'} = \@names;
		delete $entry->{'stream'};
		$changed = 1;
		$kept++;
	}
	unless ($changed) {
		$after_bytes += length($value || '');
		next;
	}
	my $new_value = $json->encode($history);
	$after_bytes += length $new_value;
	push @plan, { uuid => $row_id, device => $device, value => $new_value };
}

printf "rows scanned: %d; entries seen: %d; montages to move: %d; entries kept as-is: %d\n",
	$rows, $entries, $kept, $skipped;
printf "rows to rewrite: %d; value bytes: %d -> %d (freed %d)\n",
	scalar @plan, $before_bytes, $after_bytes, $before_bytes - $after_bytes;

unless ($apply) {
	print "\ndry run: nothing changed (pass --apply)\n";
	exit 0;
}

my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
my $backup_dir = "$root/database/backups";
make_path($backup_dir) unless -d $backup_dir;
my $backup = "$backup_dir/cards_spread_$stamp.db";

unless ($no_backup) {
	my $ok = eval { $dbh->sqlite_backup_to_file($backup); 1 };
	die "backup failed: $@\n" unless $ok;
	my $size = -s $backup || 0;
	die "backup is only $size bytes; refusing to write\n" unless $size > 1_000_000;
	print "backup: $backup ($size bytes)\n";
}

my $now = int(time() * 1000);
$dbh->begin_work;
eval {
	my $sth = $dbh->prepare('update settings set value = ?, server_time = ? where uuid = ?');
	for my $p ( @plan ) {
		$sth->execute($p->{'value'}, $now, $p->{'uuid'});
	}
	$sth->finish;
	$dbh->commit;
	1;
} or do {
	my $err = $@;
	eval { $dbh->rollback };
	die "rolled back: $err\n";
};

printf "rewrote %d row(s)\n", scalar @plan;
$dbh->do('reindex settings');
print "reindexed settings\n";

if ($vacuum) {
	$dbh->do('VACUUM');
	print "vacuumed\n";
}

my $check = $dbh->selectrow_array('pragma integrity_check') || '';
die "integrity check failed: $check\n" unless $check eq 'ok';
print "integrity: ok\n";
