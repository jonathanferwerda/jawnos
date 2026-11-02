#!/usr/bin/perl
# Clean the cache table's leftovers for one app.
#
# A cache row carries a warranty but nothing ever enforced it, and the music app
# keys its caches in ways that make an old row permanently dead:
#
#   content         the rendered window shell is keyed by the code revision
#                   (and the queue it was built for), so every push leaves the
#                   previous version's shell behind and no read can reach it;
#   loudness        keyed by path + size + mtime, so a re-encoded or edited file
#                   leaves the old key behind forever;
#   file_information keyed by the folder path, so a library folder that moved or
#                   was deleted leaves its listing behind.
#
# The rules mirror what the app reads: a content shell is live only for this
# code revision; a loudness key is live only when a file in the library still
# hashes to it; a local path listing is live only while the path exists. Expired
# rows (warranty in the past) go in every context.
#
# Dry-run by default. --apply takes a backup and deletes the planned rows.
#
#   perl scripts/cache_clean.pl
#   perl scripts/cache_clean.pl --prune-paths --prune-loudness
#   perl scripts/cache_clean.pl --apply --prune-paths --prune-loudness

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use DBI;
use Digest::MD5;
use File::Find;
use File::Path qw(make_path);
use POSIX qw(strftime);
use Time::HiRes qw(time);
use JSON::PP ();

my ($app, $apply, $vacuum, $no_backup, $database) = ('music', 0, 0, 0, '');
my ($prune_paths, $prune_loudness) = (0, 0);
for my $arg (@ARGV) {
	if ($arg eq '--apply')        { $apply = 1 }
	elsif ($arg eq '--vacuum')     { $vacuum = 1 }
	elsif ($arg eq '--no-backup')  { $no_backup = 1 }
	elsif ($arg eq '--prune-paths') { $prune_paths = 1 }
	elsif ($arg eq '--prune-loudness') { $prune_loudness = 1 }
	elsif ($arg eq '--help' || $arg eq '-h') {
		print "usage: $0 [--app NAME] [--apply] [--vacuum] [--no-backup] [--prune-paths] [--prune-loudness] [--database PATH]\n";
		exit 0;
	}
	elsif ($arg =~ /^--app=(.+)$/) { $app = $1 }
	elsif ($arg =~ /^--database=(.+)$/) { $database = $1 }
	else { die "unknown argument: $arg\n" }
}

my $root = "$FindBin::Bin/..";
$database ||= "$root/database/jawnos.db";
die "no database at $database\n" unless -f $database;

my $version = do { local $/; open my $fh, '<', "$root/VERSION" or die "no VERSION: $!"; <$fh> };
$version = '' unless defined $version;
$version =~ s/\s+$//;
die "no version in VERSION\n" unless length $version;

my $dbh = DBI->connect("dbi:SQLite:dbname=$database", '', '', {
	RaiseError => 1,
	PrintError => 0,
	AutoCommit => 1,
	sqlite_busy_timeout => 15000,
});
$dbh->do('PRAGMA journal_mode=WAL');
$dbh->do('PRAGMA synchronous=NORMAL');

# The folders the music walk reads. A path listing outside them (a peer's
# /sdcard, a relayed library) is not ours to judge and is left alone.
my @folders;
my $config = "$root/config.json";
if (-f $config) {
	my $bytes = do { local $/; open my $fh, '<', $config or die "cannot read $config: $!"; <$fh> };
	my $cfg = eval { JSON::PP->new->utf8->decode($bytes) };
	@folders = @{ $cfg->{'folders'} || [] } if ref $cfg eq 'HASH';
}
my $home = $ENV{HOME} || '';
my @roots = grep { length && -d } map {
	my $p = $_; $p =~ s{^~(?=/|$)}{$home}; $p;
} @folders;
my %under_root;
for my $r ( @roots ) {
	$under_root{$r} = 1;
}

# The loudness key is md5(path:size:mtime) over the decoded path the player
# sends, so the walk has to decode names the same way process_file does.
my %playable = map { $_ => 1 } qw/mp3 m4a wav flac mp4 mkv mov webm weba wmv/;
my %live_loudness;
if ($prune_loudness) {
	my $wanted = sub {
		my $path = $File::Find::name;
		return unless -f $path;
		(my $name = $path) =~ s/\.enc$//i;
		my $tail = lc substr($name, -4);
		my $ext = $playable{$tail} ? $tail : $playable{substr($tail, -3)} ? substr($tail, -3) : '';
		return unless $ext;
		my @st = stat($File::Find::name);
		# The player sends the path as a character string, and md5 hashes its
		# internal UTF-8 bytes - the same bytes File::Find hands back here.
		$live_loudness{'loudness-' . Digest::MD5::md5_hex($path . ':' . ($st[7] || 0) . ':' . ($st[9] || 0))} = 1;
	};
	find({ no_chdir => 1, wanted => $wanted }, @roots) if @roots;
}

my $now = int(time() * 1000);
my %current_content = map { $_ => 1 } ( "$version-locked", "$version-unlocked" );

my @plan;
my %why;
my ($seen, $bytes) = (0, 0);
for my $r ( @{ $dbh->selectall_arrayref('select uuid, context, subcontext, warranty, data from cache where app = ?', undef, $app) } ) {
	my ($uuid, $context, $subcontext, $warranty, $data) = @{$r};
	$seen++;
	$bytes += length($data || '');
	my $reason;
	if (defined $warranty && $warranty =~ /^\d+$/ && $warranty < $now) {
		$reason = 'expired';
	}
	elsif ($context eq 'content' && defined $subcontext) {
		my ($live) = grep { index($subcontext, $_) == 0 } keys %current_content;
		$reason = 'old code revision' unless $live;
	}
	elsif ($context eq 'loudness' && $prune_loudness) {
		$reason = 'no file hashes to it' unless $live_loudness{$subcontext};
	}
	elsif ($context eq 'file_information' && $prune_paths && defined $subcontext) {
		if ($subcontext =~ m{^/}) {
			my ($under) = grep { index($subcontext, $_) == 0 } @roots;
			$reason = 'path is gone' if $under && !-e $subcontext;
		}
	}
	next unless $reason;
	$why{$reason}++;
	push @plan, { uuid => $uuid, reason => $reason, context => $context, subcontext => $subcontext };
}

printf "app: %s; cache rows: %d (%d bytes); to delete: %d\n", $app, $seen, $bytes, scalar @plan;
printf "  %-22s %d\n", $_, $why{$_} for sort keys %why;
printf "  content live for: %s\n", join(', ', sort keys %current_content);
printf "  loudness keys matching a current file: %d\n", scalar keys %live_loudness if $prune_loudness;
printf "  library folders walked: %s\n", (@roots ? join(', ', @roots) : 'none') if $prune_loudness;

unless ($apply) {
	print "\ndry run: nothing changed (pass --apply)\n";
	exit 0;
}
die "nothing to delete\n" unless @plan;

my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
my $backup_dir = "$root/database/backups";
make_path($backup_dir) unless -d $backup_dir;
my $backup = "$backup_dir/cache_clean_${app}_$stamp.db";

unless ($no_backup) {
	my $ok = eval { $dbh->sqlite_backup_to_file($backup); 1 };
	die "backup failed: $@\n" unless $ok;
	my $size = -s $backup || 0;
	die "backup is only $size bytes; refusing to write\n" unless $size > 1_000_000;
	print "backup: $backup ($size bytes)\n";
}

$dbh->begin_work;
eval {
	my $sth = $dbh->prepare('delete from cache where uuid = ?');
	$sth->execute($_->{'uuid'}) for @plan;
	$sth->finish;
	$dbh->commit;
	1;
} or do {
	my $err = $@;
	eval { $dbh->rollback };
	die "rolled back: $err\n";
};
printf "deleted %d row(s)\n", scalar @plan;

$dbh->do('reindex cache');
print "reindexed cache\n";

if ($vacuum) {
	$dbh->do('VACUUM');
	print "vacuumed\n";
}

my $check = $dbh->selectrow_array('pragma integrity_check') || '';
die "integrity check failed: $check\n" unless $check eq 'ok';
print "integrity: ok\n";
