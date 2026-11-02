#!/usr/bin/perl
# Clean the relational membership arrays (settings setting LIKE 'sc\_%').
#
# The arrays name other apps by their uuid rows. They are sets, but two write
# paths used to push without a guard: the pos hook in setting_setter appended
# the app's uuid on every construct change, and a list that already held a uuid
# grew by another copy each time. One coffee row carried 8,192 copies of its own
# uuid, and the rows across the house held 22,501 entries that resolve to 783
# drawable apps.
#
# The rule is the one the relational window already applies when it reads them
# (people_index): a uuid names a member only when a uuid row still maps it to a
# different, non-hidden app. Keep the first appearance of each such uuid, in
# order. Nothing else is touched: the row keeps its app/setting/device, and the
# update stamps server_time so the sync rail carries the smaller list.
#
# Dry-run by default. --apply takes a verified backup first and writes a report
# beside it. --vacuum reclaims the freed pages.
#
#   perl scripts/relational_sc_clean.pl
#   perl scripts/relational_sc_clean.pl --apply --vacuum

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
	if ($arg eq '--apply')        { $apply = 1 }
	elsif ($arg eq '--vacuum')     { $vacuum = 1 }
	elsif ($arg eq '--no-backup')  { $no_backup = 1 }
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

# The clean itself is a domain function, so the runtime write paths and this
# migration share one rule; t/113 pins it.
require "$root/lib/JawnOS/Domain/Name.pm";

my $dbh = DBI->connect("dbi:SQLite:dbname=$database", '', '', {
	RaiseError => 1,
	PrintError => 0,
	AutoCommit => 1,
	sqlite_busy_timeout => 15000,
	sqlite_unicode => 1,
});
$dbh->do('PRAGMA journal_mode=WAL');
$dbh->do('PRAGMA synchronous=NORMAL');

# What settings_grabber({ uuid => ... }) resolves, and therefore what the
# relational window can draw. A quarantined __orphan_ app is hidden, so a uuid
# that names one draws nothing.
my %uuid_app;
my %uuid_any;
my %uuid_by_device;
for my $r ( @{ $dbh->selectall_arrayref(q{select app, device, value from settings where setting = 'uuid' and value is not null and value != ''}) } ) {
	my ($app, $device, $uuid) = @{$r};
	next unless defined $app && length $app;
	next unless defined $uuid && length $uuid;
	next if $app =~ /^__orphan_/;
	$uuid_app{$uuid} = $app;
	$uuid_any{$app} ||= $uuid;
	$uuid_by_device{$device . "\0" . $app} ||= $uuid;
}

my @plan;
my %skipped;
my ($rows, $before_entries, $after_entries, $before_bytes, $after_bytes) = (0, 0, 0, 0, 0);
my $json = JSON::PP->new->utf8;

for my $r ( @{ $dbh->selectall_arrayref(q{select uuid, app, setting, device, value from settings where setting like ? escape ?}, undef, 'sc\_%', '\\') } ) {
	my ($row_id, $app, $setting, $device, $value) = @{$r};
	$rows++;
	$before_bytes += length($value || '');
	if (!defined $app || !length $app) {
		$skipped{'empty app key'}++;
		$after_bytes += length($value || '');
		next;
	}
	if ($app =~ /^__orphan_/) {
		$skipped{'quarantined app'}++;
		$after_bytes += length($value || '');
		next;
	}
	my $list = eval { $json->decode($value || '') };
	unless (ref $list eq 'ARRAY') {
		$skipped{'not a JSON array'}++;
		$after_bytes += length($value || '');
		next;
	}
	$before_entries += scalar @{$list};
	my $self = $uuid_by_device{$device . "\0" . $app} || $uuid_any{$app};
	my $clean = subs::sc_list_clean($list, $self, \%uuid_app);
	my $new_value = $json->encode($clean);
	$after_entries += scalar @{$clean};
	$after_bytes += length $new_value;
	my $changed = scalar(@{$clean}) != scalar(@{$list});
	unless ($changed) {
		for (my $i = 0; $i < scalar @{$clean}; $i++) {
			$changed = 1, last if $clean->[$i] ne $list->[$i];
		}
	}
	next unless $changed;
	push @plan, {
		uuid => $row_id,
		app => $app,
		setting => $setting,
		device => $device,
		before => scalar @{$list},
		after => scalar @{$clean},
		value => $new_value,
	};
}

printf "rows scanned: %d; rows to rewrite: %d\n", $rows, scalar @plan;
printf "membership entries: %d -> %d (dropped %d)\n", $before_entries, $after_entries, $before_entries - $after_entries;
printf "value bytes: %d -> %d (freed %d)\n", $before_bytes, $after_bytes, $before_bytes - $after_bytes;
printf "skipped rows: %s\n", join(', ', map { "$_=$skipped{$_}" } sort keys %skipped) if %skipped;

my @top = sort { $b->{'before'} <=> $a->{'before'} } @plan;
splice @top, 20 if scalar @top > 20;
for my $p ( @top ) {
	printf "  %-18s %-11s %-9s %6d -> %-4d\n", $p->{'app'}, $p->{'setting'}, $p->{'device'}, $p->{'before'}, $p->{'after'};
}

unless ($apply) {
	print "\ndry run: nothing changed (pass --apply)\n";
	exit 0;
}

my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
my $backup_dir = "$root/database/backups";
make_path($backup_dir) unless -d $backup_dir;
my $backup = "$backup_dir/relational_sc_$stamp.db";
my $report = "$backup_dir/relational_sc_$stamp.tsv";

unless ($no_backup) {
	my $ok = eval { $dbh->sqlite_backup_to_file($backup); 1 };
	die "backup failed: $@\n" unless $ok;
	my $size = -s $backup || 0;
	die "backup is only $size bytes; refusing to write\n" unless $size > 1_000_000;
	print "backup: $backup ($size bytes)\n";
}

open my $rep, '>', $report or die "cannot write $report: $!";
print $rep "# relational membership cleanup $stamp\n# app\tsetting\tdevice\tbefore\tafter\n";
printf $rep "%s\t%s\t%s\t%d\t%d\n", $_->{'app'}, $_->{'setting'}, $_->{'device'}, $_->{'before'}, $_->{'after'} for @plan;
close $rep;
print "report: $report\n";

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
