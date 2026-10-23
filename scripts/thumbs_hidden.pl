#!/usr/bin/env perl
# thumbs_hidden.pl - move every thumbnail folder to a hidden .thumbs and
# rewrite the paths this machine's database holds.
#
#   perl scripts/thumbs_hidden.pl                 dry run: list the folders and rows
#   perl scripts/thumbs_hidden.pl --apply         rename the folders, rewrite the rows
#   perl scripts/thumbs_hidden.pl --root /media   wider than $HOME (repeatable)
#
# Why: a thumbnail is a cache, but it was written to a visible "thumbs" folder
# inside every media folder, so the gallery, a file manager and the video apps
# all showed it. ".thumbs" keeps it out of sight, and the code writes there
# from now on.
#
# The paths in the database are absolute and belong to this machine, so every
# machine runs this against its own database after its own folders move. The
# rows that changed get a fresh server_time, so the change reaches the other
# machines on the next sync instead of sitting under the old digest.
#
# A backup of the database is taken first (--no-backup skips it).
use strict;
use warnings;
use FindBin;
use File::Find;
use DBI;

chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";

my ($apply, $no_backup, $files_only, $db_only, $quiet) = (0, 0, 0, 0, 0);
my @roots;
for (my $i = 0; $i < @ARGV; $i++) {
	my $a = $ARGV[$i];
	$apply = 1 if $a eq '--apply';
	$no_backup = 1 if $a eq '--no-backup';
	$files_only = 1 if $a eq '--files-only';
	$db_only = 1 if $a eq '--db-only';
	$quiet = 1 if $a eq '--quiet';
	if ($a eq '--root' && defined $ARGV[$i + 1]) { push @roots, $ARGV[++$i]; }
	elsif ($a eq '--help' || $a eq '-h') {
		print "usage: perl scripts/thumbs_hidden.pl [--apply] [--root DIR] [--files-only|--db-only] [--no-backup] [--quiet]\n";
		exit 0;
	}
}
@roots = ($ENV{'HOME'} || '.') unless scalar @roots;

my $db_file = 'database/jawnos.db';
die "no database at $db_file\n" unless -f $db_file;

# --- the folders -----------------------------------------------------------
# Every directory named thumbs becomes .thumbs beside it. Directories that are
# not ours (a checkout, a trash can, a build tree) are left alone: renaming a
# tool's cache folder would be a surprise, not a fix.
my @moves;
unless ($db_only) {
	find({
		no_chdir => 1,
		wanted => sub {
			my $path = $File::Find::name;
			return unless -d $path && !-l $path;
			my $base = $path;
			$base =~ s{.*/}{};
			if ($base =~ /^(?:\.git|node_modules|\.pio|\.cache|Trash|\.Trash|releases|\.shots)$/) {
				$File::Find::prune = 1;
				return;
			}
			return unless $base eq 'thumbs';
			push @moves, $path;
			$File::Find::prune = 1;
		}
	}, @roots);
}

my ($moved, $merged, $failed) = (0, 0, 0);
foreach my $src ( sort @moves ) {
	my $parent = $src;
	$parent =~ s{/[^/]+$}{};
	my $dst = $parent . '/.thumbs';
	if (!$apply) {
		print((-e $dst ? "merge " : "move  ") . "$src -> $dst\n");
		next;
	}
	if (!-e $dst) {
		if (rename $src, $dst) {
			$moved++;
			print "move  $src -> $dst\n" unless $quiet;
		}
		else {
			$failed++;
			print "FAIL  $src: $!\n";
		}
		next;
	}
	# Both names exist (a run that was interrupted, or a thumb made by the new
	# code already): fold the old folder into the hidden one, never overwrite.
	my $kept = 0;
	opendir(my $dh, $src) or do { $failed++; print "FAIL  $src: $!\n"; next };
	foreach my $entry ( sort grep { $_ ne '.' && $_ ne '..' } readdir $dh ) {
		my $to = "$dst/$entry";
		if (-e $to) {
			# A thumbnail regenerated into the old folder after the move: the hidden
			# folder already has a cache file under the same name (the sealed copy
			# can differ in size - each seal has its own container). Drop the old one.
			if (!unlink "$src/$entry") {
				$failed++;
				print "FAIL  $src/$entry: $!\n";
			}
			$kept++;
			next;
		}
		if (!rename "$src/$entry", $to) { $failed++; print "FAIL  $src/$entry: $!\n"; }
	}
	closedir $dh;
	if (rmdir $src) { $merged++; print "merge $src -> $dst\n" unless $quiet; }
	else { print "NOTE  $src still holds files that could not be moved\n"; }
}
if ($apply && !$db_only) {
	printf "folders: %d moved, %d merged, %d failed\n", $moved, $merged, $failed;
}

# --- the database ----------------------------------------------------------
# Only the three path shapes a stored file reference takes: JSON with escaped
# slashes, JSON with plain slashes, and a value ending at a quote. The replace
# is idempotent, so a second run changes nothing.
my @pairs = (
	[ '\\/thumbs\\/', '\\/.thumbs\\/' ],
	[ '/thumbs/',     '/.thumbs/' ],
	[ '/thumbs"',     '/.thumbs"' ],
);

my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
}) or die "cannot open $db_file: $DBI::errstr\n";
$dbh->do('PRAGMA busy_timeout = 30000');

if ($apply && !$files_only && !$no_backup) {
	my $stamp = time;
	my $backup = ($ENV{'HOME'} || '.') . "/jawnos-thumbs-hidden-$stamp.db";
	my $ok = eval { $dbh->sqlite_backup_to_file($backup); 1 };
	if (!$ok) { system('sqlite3', $db_file, ".backup '$backup'"); }
	die "could not take a database backup at $backup\n" unless -s $backup;
	print "backup: $backup\n";
}

my @tables = map { $_->[0] } @{ $dbh->selectall_arrayref(
	"select name from sqlite_master where type = 'table' and name not like 'sqlite_%' order by name"
) };
my $now = int(time * 1000);
# cache and websockets use server_time as an expiry, not as a version: bumping
# them would extend a backoff or a remembered tab. No thumbnail path lives there.
my %no_bump = map { $_ => 1 } qw/cache websockets/;
my ($rows_changed, $cells) = (0, 0);

unless ($files_only) {
	$dbh->begin_work if $apply;
	foreach my $table ( @tables ) {
		my $info = $dbh->selectall_arrayref("pragma table_info(\"$table\")");
		my %col = map { $_->[1] => 1 } @{ $info };
		my $has_server_time = $col{'server_time'} && !$no_bump{$table};
		foreach my $column ( sort keys %col ) {
			my $expr = "\"$column\"";
			foreach my $pair ( @pairs ) {
				my ($from, $to) = @{$pair};
				(my $f = $from) =~ s/'/''/g;
				(my $t = $to) =~ s/'/''/g;
				$expr = "replace($expr, '$f', '$t')";
			}
			my $like = join ' or ', map {
				(my $p = $_->[0]) =~ s/'/''/g;
				"\"$column\" like '%$p%'"
			} @pairs;
			my $set = "\"$column\" = $expr" . ($has_server_time ? ", \"server_time\" = $now" : '');
			my $sql = "update \"$table\" set $set where $like";
			if (!$apply) {
				my $n = $dbh->selectrow_array("select count(*) from \"$table\" where $like");
				if ($n) { print "db    $table.$column: $n row(s)\n"; $rows_changed += $n; }
				next;
			}
			my $n = $dbh->do($sql);
			if ($n > 0) {
				print "db    $table.$column: $n row(s)\n" unless $quiet;
				$rows_changed += $n;
				$cells++;
			}
		}
	}
	if ($apply) { $dbh->commit; }
	printf "database: %d cell(s) rewritten across %d row(s)\n", $cells, $rows_changed if $apply;
}

$dbh->disconnect;
print "\ndry run - nothing changed; add --apply\n" unless $apply;
