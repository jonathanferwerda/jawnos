#!/usr/bin/perl
#
# Write the report a QA job leaves for Configure -> Plat -> QA.
#
#   perl scripts/qa_report.pl --kind=build --schedule=weekly --status=ok \
#        --title='Weekly build' --note='2 steps, no download' \
#        --table="Steps:$QA_ROOT/build/20261108T030000Z-steps.tsv" \
#        --metrics="$QA_ROOT/build/device.json"
#
# One directory per run under $QA_ROOT/reports/<kind>/<stamp>/:
#   report.json   the document the panel renders
#   status.txt    the one word the panel falls back to
# and the same kind is pruned to the last --keep-days (14) on every write, so a
# job that never runs again still ages out.
#
# A table is a TAB-separated file whose first line is the column headings:
#   Step	Result	Time
#   qemu	ok	21m
# The panel prints one table per --table. --metrics takes a JSON object (the
# device metrics qa/android/run.sh already writes) and shows it as key/value.
#
# --prune-only writes nothing and only ages the kind's directory out; a shell
# job that writes its own report.json (the installer check) calls it so its
# retention matches every other kind's.

use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use JSON::PP ();

my ($kind, $schedule, $status, $title, $note, $stamp, $root, $keep_days, $prune_only, $base);
my (@tables, @metrics);
GetOptions(
	'kind=s'       => \$kind,
	'schedule=s'   => \$schedule,
	'status=s'     => \$status,
	'title=s'      => \$title,
	'note=s'       => \$note,
	'stamp=s'      => \$stamp,
	'table=s@'     => \@tables,
	'metrics=s@'   => \@metrics,
	'base=s'       => \$base,
	'root=s'       => \$root,
	'keep-days=i'  => \$keep_days,
	'prune-only'   => \$prune_only,
) or usage();

sub usage {
	print STDERR "usage: qa_report.pl --kind=KIND [--schedule=nightly|weekly|manual]\n"
		. "       --status=ok|failed|skipped [--title=TEXT] [--note=TEXT] [--stamp=STAMP]\n"
		. "       [--table=TITLE:FILE]... [--metrics=FILE]... [--base=FILE]... [--prune-only]\n";
	exit 2;
}

usage() unless defined $kind && length $kind;
usage() unless $prune_only || (defined $status && length $status);

$root = (defined $root && length $root) ? $root
	: (defined $ENV{'QA_ROOT'} && length $ENV{'QA_ROOT'}) ? $ENV{'QA_ROOT'}
	: (($ENV{'HOME'} || '') . '/jawnos-qa');
$keep_days = 14 unless defined $keep_days && $keep_days > 0;
$schedule = 'manual' unless defined $schedule && length $schedule;

my $kind_dir = "$root/reports/$kind";

# --- prune ------------------------------------------------------------------
# By age, like the installer check: 14 days of reports, whatever the cadence.
sub prune {
	my ($dir) = @_;
	opendir(my $dh, $dir) or return;
	my @stamps = grep { /^\d{8}T\d{6}Z$/ && -d "$dir/$_" } readdir $dh;
	closedir $dh;
	require File::Path;
	my $cutoff = time - $keep_days * 24 * 60 * 60;
	for my $stamp (@stamps) {
		my ($y, $mo, $d, $h, $mi, $s) = $stamp =~ /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$/;
		# gmtime-based epoch, no Time::Local in core-only scripts
		my $epoch = eval { require Time::Local; Time::Local::timegm($s, $mi, $h, $d, $mo - 1, $y) };
		next unless defined $epoch;
		File::Path::remove_tree("$dir/$stamp") if $epoch < $cutoff;
	}
	return;
}

prune($kind_dir);
exit 0 if $prune_only;

# --- the document -----------------------------------------------------------
sub read_tsv {
	my ($path) = @_;
	my (@columns, @rows);
	open(my $fh, '<', $path) or return undef;
	while (my $line = <$fh>) {
		chomp $line;
		next unless length $line;
		my @cells = map { my $c = $_; $c =~ s/\s+$//; $c } split /\t/, $line, -1;
		if (!@columns) {
			@columns = @cells;
			next;
		}
		push @rows, \@cells;
	}
	close $fh;
	return undef unless @columns;
	return { columns => \@columns, rows => \@rows };
}

sub read_json_object {
	my ($path) = @_;
	open(my $fh, '<', $path) or return undef;
	local $/;
	my $text = <$fh>;
	close $fh;
	my $data = eval { JSON::PP::decode_json($text) };
	return ref $data eq 'HASH' ? $data : undef;
}

my @t = gmtime;
$stamp = sprintf('%04d%02d%02dT%02d%02d%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0])
	unless defined $stamp && length $stamp;

my @sections;
for my $spec (@tables) {
	my ($name, $path) = split /:/, $spec, 2;
	next unless defined $path;
	my $table = read_tsv($path);
	next unless $table;
	push @sections, {
		title   => (defined $name && length $name) ? $name : 'Steps',
		columns => $table->{'columns'},
		rows    => $table->{'rows'},
	};
}

my %metrics;
for my $path (@metrics) {
	my $object = read_json_object($path);
	next unless $object;
	$metrics{$_} = $object->{$_} for keys %$object;
}

my $doc = {
	ok        => ($status eq 'ok' ? 1 : 0),
	kind      => $kind,
	schedule  => $schedule,
	status    => $status,
	stamp     => $stamp,
	generated => time,
	title     => ((defined $title && length $title) ? $title : $kind),
};
# A job that writes its own document (the installer check does, with its rows)
# hands it over as --base; the generic fields are stamped on top rather than
# rebuilt, so the panel gets the same shape from every kind.
if (defined $base && length $base) {
	my $carried = read_json_object($base);
	die "qa_report: cannot read --base $base\n" unless $carried;
	$doc = { %$carried, %$doc };
}
$doc->{'note'} = $note if defined $note && length $note;
$doc->{'sections'} = \@sections if @sections;
$doc->{'metrics'} = \%metrics if %metrics;

my $dir = "$kind_dir/$stamp";
require File::Path;
File::Path::make_path($dir);
open(my $rf, '>', "$dir/report.json") or die "qa_report: $dir/report.json: $!\n";
print {$rf} JSON::PP->new->canonical->pretty->encode($doc);
close $rf;
open(my $sf, '>', "$dir/status.txt") or die "qa_report: $dir/status.txt: $!\n";
print {$sf} "$status\n";
close $sf;

print "qa_report: $kind $status $dir/report.json\n";
exit 0;
