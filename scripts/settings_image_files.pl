#!/usr/bin/perl
# Move an image setting that is still a data URI onto the file it duplicates.
#
# A phone can save a picture as a data URI in a settings row when the server
# cannot read the phone's own disk. When the same bytes are already sealed in
# the photo location - because another device row names that file, or the phone
# has since written it - the row is carrying a second copy.
#
# Only one transplant is safe: a row whose value is an ABSOLUTE path. That path
# names the same file on every machine that resolves it through its own photo
# location, so the phone keeps working. A bare filename is relative to the
# device's own photo folder and is not transplanted. The replacement happens
# only when the local sealed (or plain) file hashes to exactly the same bytes.
#
# Dry-run by default. --apply takes a backup and rewrites only the matching rows.
#
#   perl scripts/settings_image_files.pl
#   perl scripts/settings_image_files.pl --apply --vacuum

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use DBI;
use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename);
use File::Path qw(make_path);
use MIME::Base64 qw(decode_base64);
use POSIX qw(strftime);
use Time::HiRes qw(time);

my ($apply, $vacuum, $no_backup, $database, $device) = (0, 0, 0, '', 'computer');
for my $arg (@ARGV) {
	if ($arg eq '--apply')       { $apply = 1 }
	elsif ($arg eq '--vacuum')    { $vacuum = 1 }
	elsif ($arg eq '--no-backup') { $no_backup = 1 }
	elsif ($arg eq '--help' || $arg eq '-h') {
		print "usage: $0 [--device NAME] [--apply] [--vacuum] [--no-backup] [--database PATH]\n";
		exit 0;
	}
	elsif ($arg =~ /^--device=(.+)$/) { $device = $1 }
	elsif ($arg =~ /^--database=(.+)$/) { $database = $1 }
	else { die "unknown argument: $arg\n" }
}

my $root = "$FindBin::Bin/..";
$database ||= "$root/database/jawnos.db";
die "no database at $database\n" unless -f $database;
chdir $root or die "cannot enter $root: $!\n";
require './perl/gb.pl';
require './perl/subroutines.pl';

my $dbh = DBI->connect("dbi:SQLite:dbname=$database", '', '', {
	RaiseError => 1,
	PrintError => 0,
	AutoCommit => 1,
	sqlite_busy_timeout => 15000,
});
$dbh->do('PRAGMA journal_mode=WAL');
$dbh->do('PRAGMA synchronous=NORMAL');

# The photo folder each device keeps; a path is resolved through the folder of
# the device it came from, which is what the app does.
my %photo;
for my $r ( @{ $dbh->selectall_arrayref(q{select device, value from settings where app = 'misc' and setting = 'photo_location'}) } ) {
	$photo{$r->[0]} = $r->[1] if defined $r->[1] && length $r->[1];
}
my $home = $ENV{HOME} || '';
my $expand = sub {
	my $p = shift;
	$p =~ s{^~(?=/|$)}{$home} if defined $p;
	return $p;
};

# Only decode the sealed bytes when a candidate is actually sealed.
my ($secret, $standard);
my $picture_bytes = sub {
	my $path = shift;
	if ($path =~ /\.enc$/i) {
		$standard ||= &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
		$secret ||= &subs::suds_grabber();
		return undef unless defined $secret && length $secret;
		return &subs::openssl_file_read($standard, $secret, $path, 0, 1);
	}
	open(my $fh, '<', $path) or return undef;
	binmode $fh;
	local $/;
	my $bytes = <$fh>;
	close $fh;
	return $bytes;
};

my @data_rows = @{ $dbh->selectall_arrayref(q{select uuid, app, setting, device, value from settings where value like 'data:image/%'}) };
my %pairs;
for my $r ( @data_rows ) {
	$pairs{$r->[1] . "\0" . $r->[2]} = 1 if defined $r->[1] && defined $r->[2];
}

my %paths;
for my $key ( keys %pairs ) {
	my ($app, $setting) = split /\0/, $key, 2;
	my $rows = $dbh->selectall_arrayref(q{select uuid, device, value from settings where app = ? and setting = ? and value like '/%'}, undef, $app, $setting);
	$paths{$key} = $rows || [];
}

my @plan;
my ($freed, $ambiguous) = (0, 0);
for my $r ( @data_rows ) {
	my ($uuid, $app, $setting, $dev, $value) = @{$r};
	my ($b64) = $value =~ /^data:image\/[a-z0-9.+-]+;base64,(.*)$/si;
	next unless defined $b64;
	(my $clean = $b64) =~ s/\s+//g;
	my $bytes = eval { decode_base64($clean) };
	next unless defined $bytes && length $bytes;
	my $digest = sha256_hex($bytes);
	my @same;
	for my $candidate ( @{ $paths{$app . "\0" . $setting} || [] } ) {
		my ($cid, $cdev, $cpath) = @{$candidate};
		next if $cid eq $uuid;
		next unless defined $cpath && $cpath =~ m{^/};
		my $folder = $photo{$cdev} || $photo{$device} || '~/Pictures';
		my $local = &$expand($folder) . '/' . &subs::path_name($app) . '/' . basename($cpath);
		next unless -e $local;
		my $file_bytes = &$picture_bytes($local);
		next unless defined $file_bytes && length $file_bytes;
		push @same, $cpath if sha256_hex($file_bytes) eq $digest;
	}
	my %unique = map { $_ => 1 } @same;
	my @unique = sort keys %unique;
	unless (@unique) {
		next;
	}
	if (scalar @unique > 1) {
		# two paths claim the same picture; leave the choice to a person
		$ambiguous++;
		printf "  ambiguous %s/%s (%s): %s\n", $app, $setting, $dev, join(', ', @unique);
		next;
	}
	push @plan, {
		uuid => $uuid, app => $app, setting => $setting, device => $dev,
		before => length $value, after => length $unique[0], value => $unique[0],
	};
	$freed += length($value) - length($unique[0]);
}

printf "image data URIs: %d; rows to point at their file: %d; ambiguous: %d\n",
	scalar @data_rows, scalar @plan, $ambiguous;
printf "value bytes freed: %d\n", $freed;
for my $p ( @plan ) {
	printf "  %-18s %-12s %-9s %8d -> %-4d  %s\n", $p->{'app'}, $p->{'setting'}, $p->{'device'}, $p->{'before'}, $p->{'after'}, $p->{'value'};
}

unless ($apply) {
	print "\ndry run: nothing changed (pass --apply)\n";
	exit 0;
}
die "nothing to change\n" unless @plan;

my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
my $backup_dir = "$root/database/backups";
make_path($backup_dir) unless -d $backup_dir;
my $backup = "$backup_dir/settings_image_files_$stamp.db";

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
	$sth->execute($_->{'value'}, $now, $_->{'uuid'}) for @plan;
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
