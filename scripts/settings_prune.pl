#!/usr/bin/perl
# settings_prune.pl - take the weight out of the settings table.
#
#   perl scripts/settings_prune.pl            (dry run: report only)
#   perl scripts/settings_prune.pl --apply    (delete, strip, vacuum)
#
# Every request reads settings, and every index copies every key. Three kinds of
# row had grown the table to 1.06 GB on the phone (2026-11): keys that are
# payloads (one `app` was 6.3 MB, the average key 2 KB), __orphan_* rows a rename
# left behind, and the cards draw list, which kept a `stream` of card images in
# every entry after the app stopped storing images. This deletes the first two,
# strips the stream from the third (the draws stay), then vacuums the file so the
# indexes are rebuilt without the gaps.
#
# VACUUM wants the file to itself: stop the tree first when you can. The busy
# timeout below is the fallback for a tree that is still writing.
#
# The prune is a dry run unless --apply; --json prints the report as one object.
use strict;
use warnings;
use FindBin;
require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $NAME_LIMIT = 100;

# The cards draw list is a JSON array of entries; `stream` was the card image
# data. Pure, so a test can drive it without a database. Returns the new value
# and the bytes it saved, or (undef, 0) when there is nothing to strip.
sub strip_card_streams {
	my ($value) = @_;
	return (undef, 0) unless defined $value && length $value;
	my $list = eval { Mojo::JSON::decode_json($value) };
	return (undef, 0) unless ref $list eq 'ARRAY';
	my $saved = 0;
	foreach my $entry ( @{$list} ) {
		next unless ref $entry eq 'HASH';
		next unless exists $entry->{'stream'};
		my $stream = $entry->{'stream'};
		$saved += length(ref $stream ? Mojo::JSON::encode_json($stream) : ($stream // ''));
		delete $entry->{'stream'};
	}
	return (undef, 0) unless $saved;
	my $json = eval { Mojo::JSON::encode_json($list) };
	return (undef, 0) unless defined $json;
	return ($json, $saved);
}

# VACUUM through the sqlite3 binary. Both in-process routes (Mojo::SQLite's
# query and the raw dbh do) returned success without doing anything: the phone's
# file stayed at 1.06 GB and the tablet's at 231 MB until the CLI ran the same
# statement. The binary is in the runtime on every machine; fall back to the
# handle when it is not, and report the sizes either way.
sub vacuum_file {
	my ($db, $database) = @_;
	my $size = sub {
		return 0 unless defined $database && -e $database;
		my @st = stat($database);   # a fresh stat: -s can answer from a cached one
		return $st[7] || 0;
	};
	my $before = $size->();
	my $tool = `command -v sqlite3 2>/dev/null`;
	chomp $tool;
	my $ok = 0;
	if (length $tool && defined $database) {
		# This script's own connection makes VACUUM's exclusive lock wait: the
		# laptop's file stayed at 1002 MB until the same statement ran in a
		# process that had no handle open. Close this one first.
		eval { $db->dbh->disconnect } if $db && $db->dbh;
		# .timeout is the CLI's dot-command; the pragma form prints its value.
		$ok = 1 if system($tool, '-cmd', '.timeout 30000', $database, 'vacuum') == 0;
	}
	else {
		$ok = eval { $db->dbh->do('vacuum'); 1 } ? 1 : 0;
	}
	my $after = $size->();
	$ok = 0 if $after > $before;
	return ($ok, $before, $after);
}

sub main {
	my (@argv) = @_;
	my $apply = grep { $_ eq '--apply' } @argv;
	my $json  = grep { $_ eq '--json' } @argv;
	my ($db, $database) = &subs::database_grabber();
	unless ($db) {
		print "settings_prune: no database to read\n";
		return 1;
	}
	$db->dbh->do('PRAGMA busy_timeout = 30000');
	my $limit = int($NAME_LIMIT);

	# The limit is interpolated, not bound: SQLite orders an integer below every
	# text value, so `length(app) > ?` with a text-bound 100 is never true.
	my $big = $db->query(
		'select count(*) as n, coalesce(sum(length(app)),0) as a, coalesce(sum(length(setting)),0) as s '
		. "from settings where length(app) > $limit or length(setting) > $limit")->hash || {};
	my $orphans = $db->query("select count(*) as n from settings where app like '__orphan%'")->hash || {};
	my $cards = $db->query("select id, value from settings where app = 'cards'")->hashes || [];

	my ($stripped, $saved) = (0, 0);
	my @rewrites;
	foreach my $row ( @{$cards} ) {
		my ($value, $bytes) = strip_card_streams($row->{'value'});
		next unless defined $value;
		push @rewrites, [ $row->{'id'}, $value ];
		$stripped++;
		$saved += $bytes;
	}

	my $report = {
		big_keys => $big->{'n'} + 0,
		orphans => $orphans->{'n'} + 0,
		cards_rows => scalar @{$cards},
		streams_stripped => $stripped,
		bytes_saved => $saved,
		applied => $apply ? 1 : 0,
	};

	if ($json) {
		print Mojo::JSON::encode_json($report), "\n";
	}
	else {
		printf "settings_prune: %d key(s) over %d chars, %d __orphan_* row(s)\n",
			$report->{'big_keys'}, $limit, $report->{'orphans'};
		printf "settings_prune: %d card row(s), %d stream(s), %.1f MB of images\n",
			$report->{'cards_rows'}, $stripped, $saved / 1048576;
	}

	unless ($apply) {
		print "settings_prune: nothing written; re-run with --apply\n" unless $json;
		return 0;
	}

	my $deleted = $db->query(
		"delete from settings where length(app) > $limit or length(setting) > $limit"
		. " or app like '__orphan%'")->rows;
	my $now = &subs::rightNow();
	foreach my $r ( @rewrites ) {
		$db->query('update settings set value = ?, server_time = ? where id = ?', $r->[1], $now, $r->[0]);
	}
	my ($vacuumed, $before, $after) = &vacuum_file($db, $database);
	printf("settings_prune: deleted %d row(s), rewrote %d, file %.0f MB -> %.0f MB%s\n",
		$deleted, $stripped, $before / 1048576, $after / 1048576,
		$vacuumed ? '' : ' (vacuum did not run - stop the tree and retry)') unless $json;
	return 0;
}

exit(main(@ARGV)) unless caller;
