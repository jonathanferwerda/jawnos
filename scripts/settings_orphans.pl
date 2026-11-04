#!/usr/bin/perl
# Quarantine settings rows whose app name is a repetition or a mojibake cascade.
#
# The names came from a byte/character boundary (SQLite returns text as bytes,
# and the formatters ran NFC on them) and from a few apps born with a repeated
# name. The rows themselves are real settings, so this never deletes one: it
# renames the app key to __orphan_<digest>. The start menu already hides keys
# starting with two underscores, every settings index stops carrying a key of up
# to 1.5 MB, and the rename is an ordinary update the sync rail carries - unlike
# a delete, which a peer could hand back on the next pull.
#
# Dry-run by default. --apply takes a verified backup first, writes a mapping
# file beside it, and reindexes. --vacuum reclaims the freed pages.
#
#   perl scripts/settings_orphans.pl
#   perl scripts/settings_orphans.pl --apply --vacuum

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use DBI;
use File::Path qw(make_path);
use POSIX qw(strftime);
use Time::HiRes qw(time);

my ($apply, $vacuum, $no_backup, $database) = (0, 0, 0, '');
for my $arg (@ARGV) {
	if ($arg eq '--apply')     { $apply = 1 }
	elsif ($arg eq '--vacuum')  { $vacuum = 1 }
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

# The plan itself is a pure domain function, so the same rule is used by the
# app and pinned by t/112-name-encoding.t.
# The plan shares Format.pm's overlong-name rule; require it beside Name.pm so
# a standalone run resolves the call without the manager's lazy loader.
require "$root/lib/JawnOS/Domain/Name.pm";
require "$root/lib/JawnOS/Domain/Format.pm";

my $dbh = DBI->connect("dbi:SQLite:dbname=$database", '', '', {
	RaiseError => 1,
	PrintError => 0,
	AutoCommit => 1,
	sqlite_busy_timeout => 15000,
});
$dbh->do('PRAGMA journal_mode=WAL');
$dbh->do('PRAGMA synchronous=NORMAL');

# Every table that names an app, and whether it can stamp the update for sync.
my @tables;
my $all_tables = $dbh->selectcol_arrayref(q{select name from sqlite_master where type='table'});
my %apps;
for my $table (@{$all_tables}) {
	next if $table eq 'sync_log';   # the deletion/update history keeps its own names
	my $cols = $dbh->selectcol_arrayref('select name from pragma_table_info(?)', undef, $table) || [];
	next unless grep { $_ eq 'app' } @{$cols};
	push @tables, {
		name => $table,
		server_time => (scalar(grep { $_ eq 'server_time' } @{$cols}) ? 1 : 0),
	};
	my $rows = $dbh->selectcol_arrayref(qq{select distinct app from "$table" where app is not null and app != ''}) || [];
	$apps{$_}++ for @{$rows};
}

my $plan = subs::settings_orphan_plan([ sort keys %apps ]);
my @rename = @{ $plan->{'rename'} };
my $bytes = 0;
$bytes += $_->{'length'} for @rename;

printf "database: %s\n", $database;
printf "apps: %d, corrupt: %d, key bytes: %d\n", scalar(keys %apps), scalar(@rename), $bytes;
for my $r ((sort { $b->{'length'} <=> $a->{'length'} } @rename)[0 .. ($#rename > 4 ? 4 : $#rename)]) {
	printf "  %7d -> %s\n", $r->{'length'}, $r->{'to'};
}

unless ($apply) {
	print "dry run: nothing written. Re-run with --apply (and optionally --vacuum).\n";
	exit 0;
}
die "nothing to do\n" unless @rename;

# A corrupted name with real appointment rows is not a shell: leave it for a
# person. The long-name set on this house has none, but a future one might.
my @with_records;
for my $r (@rename) {
	my $n = $dbh->selectrow_array('select count(*) from appointments where app = ?', undef, $r->{'from'}) || 0;
	push @with_records, $r if $n;
}
if (@with_records) {
	printf "refusing %d app(s) with appointment rows; review them first:\n", scalar(@with_records);
	printf "  %7d -> %s\n", $_->{'length'}, $_->{'to'} for @with_records;
	die "nothing changed\n";
}

my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
my $backup_dir = "$root/database/backups";
make_path($backup_dir) unless -d $backup_dir;
my $backup = "$backup_dir/settings_orphans_$stamp.db";
my $mapping = "$backup_dir/settings_orphans_$stamp.tsv";

unless ($no_backup) {
	my $ok = eval { $dbh->sqlite_backup_to_file($backup); 1 };
	die "backup failed: $@\n" unless $ok;
	my $size = -s $backup || 0;
	die "backup is only $size bytes; refusing to write\n" unless $size > 5_000_000;
	print "backup: $backup ($size bytes)\n";
}

open my $map, '>', $mapping or die "cannot write $mapping: $!";
print $map "# orphan mapping $stamp\n# to\tlength\tsha256\tfirst 120 bytes\n";
require Digest::SHA;
for my $r (@rename) {
	my $head = substr($r->{'from'}, 0, 120);
	$head =~ s/\s+/ /g;
	print $map join("\t", $r->{'to'}, $r->{'length'}, Digest::SHA::sha256_hex($r->{'from'}), $head), "\n";
}
close $map;
print "mapping: $mapping\n";

my $now = int(time() * 1000);
my %updated;
$dbh->begin_work;
eval {
	for my $r (@rename) {
		for my $t (@tables) {
			my $sql = $t->{'server_time'}
				? qq{update "$t->{'name'}" set app = ?, server_time = ? where app = ?}
				: qq{update "$t->{'name'}" set app = ? where app = ?};
			my $sth = $dbh->prepare($sql);
			if ($t->{'server_time'}) {
				$sth->execute($r->{'to'}, $now, $r->{'from'});
			}
			else {
				$sth->execute($r->{'to'}, $r->{'from'});
			}
			$updated{$t->{'name'}} += $sth->rows;
			$sth->finish;
		}
	}
	$dbh->commit;
	1;
} or do {
	my $err = $@;
	eval { $dbh->rollback };
	die "rolled back: $err\n";
};

printf "renamed %d app(s), %s\n", scalar(@rename),
	join(', ', map { "$_=$updated{$_}" } sort keys %updated);

$dbh->do('reindex settings');
print "reindexed settings\n";

if ($vacuum) {
	$dbh->do('VACUUM');
	print "vacuumed\n";
}

my $left = $dbh->selectrow_array('select count(*) from settings where length(app) > 100') || 0;
my $key_bytes = $dbh->selectrow_array('select coalesce(sum(length(app)),0) from settings') || 0;
printf "remaining long names: %d; total app-key bytes: %d\n", $left, $key_bytes;

my $check = $dbh->selectrow_array('pragma integrity_check') || '';
die "integrity check failed: $check\n" unless $check eq 'ok';
print "integrity: ok\n";
