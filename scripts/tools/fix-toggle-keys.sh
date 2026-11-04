#!/bin/sh
# Repair toggle rows whose app key is a mojibake cascade.
#
# Answers: "which `setting='toggle'` rows carry a doubled app key, and can they
#           be removed without losing a real toggle?"
# Usage:   fix-toggle-keys.sh [--apply] [--backup PATH] [--root DIR]
# Example: scripts/tools/fix-toggle-keys.sh
#          scripts/tools/fix-toggle-keys.sh --apply
#
# A byte-string name handed to the settings layer was stored as Latin-1 and
# re-encoded by SQLite, so one UTF-8 mark became two bytes and the key gained a
# layer on every save or merge (the house saw 108, 204, ... 786444-byte toggle
# keys). The writer now decodes once (subs::text_chars in setting_setter), but
# the rows it already made are stale duplicates of a valid key.
#
# This never deletes blindly: a row is repaired only when unwrapping the key
# yields a shorter name that already has exactly one toggle row with the same
# device, subsetting and value. Removal goes through subs::setting_deleter, the
# same write path the app uses, so the settings memo is cleared and the delete
# is scoped exactly like an app delete. Any row without a verified sibling is
# reported and left alone.
#
# Dry run by default. --apply first writes the exact rows (one JSON object per
# line, with the unwrapped key) to database/backups/fix-toggle-keys_<stamp>.jsonl,
# then deletes them, then verifies that every valid key survived.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT" || { echo "cannot enter the jawnos root: $ROOT" >&2; exit 1; }
FIX_ROOT=$ROOT
export FIX_ROOT

exec perl - "$@" <<'PERL'
use strict;
use warnings;
use Encode ();
use File::Path qw(make_path);
use Mojo::JSON qw(encode_json);
use POSIX ();

my ($apply, $backup_path, $root, $limit) = (0, '', ($ENV{'FIX_ROOT'} || '.'), 0);
for (my $i = 0; $i < @ARGV; $i++) {
	my $a = $ARGV[$i];
	if ($a eq '--apply') { $apply = 1 }
	elsif ($a eq '--backup' && defined $ARGV[$i + 1]) { $backup_path = $ARGV[++$i] }
	elsif ($a eq '--root' && defined $ARGV[$i + 1]) { $root = $ARGV[++$i] }
	elsif ($a eq '--limit' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^\d+$/) { $limit = $ARGV[++$i] }
	elsif ($a eq '--help' || $a eq '-h') {
		print "usage: scripts/tools/fix-toggle-keys.sh [--apply] [--backup PATH] [--root DIR] [--limit N]\n";
		exit 0;
	}
	else { die "unknown argument: $a\n" }
}

chdir $root or die "cannot enter $root: $!\n";
# The app's own boot: config.json, the domain loader, the database handle.
require './perl/subroutines.pl';

# The same length rule as Format.pm's name_overlong: no valid app key is longer
# than 100 characters, so anything longer is corruption.
my $LONG = 100;

# A doubled key, read as characters, is a Latin-1 rendering of the previous
# layer: encode those code points as bytes, decode as UTF-8, repeat while it
# shrinks. A clean name either cannot be encoded (a mark above 255) or decodes
# to itself, so the loop stops.
sub unwrap_key {
	my ($app) = @_;
	my $cur = $app;
	if (!utf8::is_utf8($cur)) {
		my $decoded = eval { Encode::decode('UTF-8', $cur, Encode::FB_CROAK) };
		$cur = $decoded if defined $decoded;
	}
	for (1 .. 24) {
		# Encode::encode/decode take the source in place, so hand them a copy:
		# without it a failed final round left $cur empty.
		my $source = $cur;
		my $bytes = eval { Encode::encode('ISO-8859-1', $source, Encode::FB_CROAK) };
		return $cur unless defined $bytes;
		my $next = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK) };
		return $cur unless defined $next;
		return $cur if length($next) >= length($cur);
		$cur = $next;
	}
	return $cur;
}

sub toggle_keys {
	my %keys;
	my $rows = &subs::db_query("select app from settings where setting = ? and app is not null", 'toggle')->hashes || [];
	$keys{$_->{'app'}} = 1 for @{$rows};
	return \%keys;
}

my %before = %{ toggle_keys() };
my $rows = &subs::db_query(
	"select app, device, subsetting, value, server_time, uuid from settings "
	. "where setting = ? and length(app) > cast(? as integer) order by length(app)",
	'toggle', $LONG
)->hashes || [];

my @plan;
my @skipped;
foreach my $row ( @{$rows} ) {
	my $app = $row->{'app'} // '';
	my $base = unwrap_key($app);
	if ($base eq $app || length($base) >= length($app)) {
		push @skipped, { row => $row, reason => 'the key does not unwrap to a shorter name' };
		next;
	}
	my $sub = defined $row->{'subsetting'} ? $row->{'subsetting'} : '';
	my $siblings = &subs::db_query(
		"select app, value from settings where setting = ? and app = ? and device is ? "
		. "and coalesce(subsetting, '') = ?",
		'toggle', $base, $row->{'device'}, $sub
	)->hashes || [];
	if (scalar @{$siblings} != 1) {
		push @skipped, { row => $row, base => $base,
			reason => (@{$siblings} ? 'the valid key has ' . scalar(@{$siblings}) . ' sibling rows' : 'no valid sibling row exists') };
		next;
	}
	if (($siblings->[0]->{'value'} // '') ne ($row->{'value'} // '')) {
		push @skipped, { row => $row, base => $base, reason => 'the valid sibling holds a different value' };
		next;
	}
	# setting_deleter keys on (app, setting, device) when subsetting is empty,
	# so require the corrupt key to name exactly one row.
	my $count = &subs::db_query(
		"select count(*) as c from settings where setting = ? and app = ? and device is ? "
		. "and coalesce(subsetting, '') = ?",
		'toggle', $app, $row->{'device'}, $sub
	)->hashes->[0]->{'c'} || 0;
	if ($count != 1) {
		push @skipped, { row => $row, base => $base, reason => 'the corrupt key names ' . $count . ' rows' };
		next;
	}
	push @plan, { %{$row}, base => $base };
	last if $limit && scalar(@plan) >= $limit;
}

printf "database: %s\n", &subs::database_path();
my $row_total = &subs::db_query("select count(*) as c from settings where setting = ?", 'toggle')->hashes->[0]->{'c'} || 0;
printf "toggle rows: %d; distinct app keys: %d\n", $row_total, scalar(keys %before);
printf "corrupt keys (longer than %d): %d\n", $LONG, scalar(@{$rows});
foreach my $p ( @plan ) {
	printf "  repair  %7d  device=%s  value=%s  -> %s\n",
		length($p->{'app'}), ($p->{'device'} // ''), ($p->{'value'} // ''), $p->{'base'};
}
foreach my $s ( @skipped ) {
	printf "  skip    %7d  device=%s  (%s%s)\n",
		length($s->{'row'}->{'app'} // ''), ($s->{'row'}->{'device'} // ''), $s->{'reason'},
		(defined $s->{'base'} ? '; base=' . substr($s->{'base'}, 0, 60) : '');
}

unless ($apply) {
	print "dry run: nothing written. Re-run with --apply to remove the repaired rows.\n";
	exit 0;
}
die "nothing to repair\n" unless @plan;

my %planned = map { $_->{'app'} => 1 } @plan;
if (!$backup_path) {
	my $stamp = POSIX::strftime('%Y%m%d-%H%M%S', localtime);
	$backup_path = &subs::database_path();
	$backup_path =~ s{/[^/]+$}{};
	$backup_path .= "/backups/fix-toggle-keys_$stamp.jsonl";
}
my ($backup_dir) = $backup_path =~ m{^(.*)/[^/]+$};
make_path($backup_dir) if defined $backup_dir && length $backup_dir && !-d $backup_dir;
open(my $bfh, '>:raw', $backup_path) or die "cannot write $backup_path: $!\n";
my $backup_bytes = 0;
foreach my $p ( @plan ) {
	my $line = encode_json($p) . "\n";
	print $bfh $line;
	$backup_bytes += length $line;
}
close $bfh;
printf "backup: %s (%d rows, %d bytes)\n", $backup_path, scalar(@plan), $backup_bytes;

my ($deleted, $failed) = (0, 0);
foreach my $p ( @plan ) {
	my $ok = eval {
		&subs::setting_deleter({
			app => $p->{'app'},
			setting => 'toggle',
			device => $p->{'device'},
			subsetting => $p->{'subsetting'},
		});
		1;
	};
	if ($ok) { $deleted++ }
	else { $failed++; print STDERR "failed: " . substr($p->{'app'}, 0, 40) . "...: $@\n" }
}

my %after = %{ toggle_keys() };
my @unexpected = grep { !$before{$_} } keys %after;
my @lost = grep { !$planned{$_} && !$after{$_} } keys %before;
my $remaining = &subs::db_query(
	"select count(*) as c from settings where setting = ? and length(app) > cast(? as integer)", 'toggle', $LONG
)->hashes->[0]->{'c'} || 0;
my $row_count = &subs::db_query("select count(*) as c from settings where setting = ?", 'toggle')->hashes->[0]->{'c'} || 0;

printf "deleted %d corrupt row(s), %d failed\n", $deleted, $failed;
printf "toggle rows: %d; distinct app keys: %d\n", $row_count, scalar(keys %after);
printf "corrupt keys remaining: %d\n", $remaining;
if (@unexpected || @lost) {
	print "VALID KEYS CHANGED: unexpected keys: " . join(', ', map { substr($_, 0, 40) } @unexpected)
		. "; lost keys: " . join(', ', map { substr($_, 0, 40) } @lost) . "\n";
	exit 2;
}
printf "valid keys unchanged: yes (%d valid key(s) still present)\n", scalar(keys %after);
exit($failed ? 1 : 0);
PERL
