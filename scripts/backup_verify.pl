#!/usr/bin/perl
# backup_verify.pl - prove sealed snapshots still open and pass the Doctor.
#
#   perl scripts/backup_verify.pl
#   perl scripts/backup_verify.pl --all
#   perl scripts/backup_verify.pl --file /path/to/jawnos_....enc
#   perl scripts/backup_verify.pl --json
#
# Read-only: each snapshot is decrypted to a scratch file under ~/.president,
# checked with the same Doctor as Configure, then removed. Exit 0 when every
# checked snapshot passed, 1 when one failed, 2 on a usage or credential error.
use strict;
use warnings;
use FindBin;
use JSON::PP ();

chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";

my ($help, $json, $all, $file) = (0, 0, 0, undef);
for (my $i = 0; $i < @ARGV; $i++) {
	my $arg = $ARGV[$i];
	if ($arg eq '--help' || $arg eq '-h') { $help = 1; }
	elsif ($arg eq '--json') { $json = 1; }
	elsif ($arg eq '--all') { $all = 1; }
	elsif ($arg eq '--file' && defined $ARGV[$i + 1] && length $ARGV[$i + 1]) { $file = $ARGV[++$i]; }
	else { print STDERR "backup_verify: unknown argument $arg\n"; exit 2; }
}
if ($help) {
	print <<'USAGE';
usage: backup_verify.pl [--all] [--file PATH] [--json]

  (no flags)   verify the newest and oldest local snapshots and the newest card copy
  --all        verify every local and card snapshot
  --file PATH  verify one sealed file
  --json       print the report as JSON
USAGE
	exit 0;
}

require './perl/subroutines.pl';

my $secret = eval { subs::suds_grabber() } || '';
unless (length $secret) {
	print STDERR "backup_verify: no house credential; nothing was checked\n";
	exit 2;
}

my $report;
if (defined $file) {
	$report = { ok => 0, checked => 0, reports => [] };
	if (!-e $file) {
		$report->{'error'} = "no such file: $file";
	}
	else {
		my $one = subs::backup_verify_file($file, $secret);
		$report->{'reports'} = [ $one ];
		$report->{'checked'} = 1;
		$report->{'ok'} = $one->{'ok'} ? 1 : 0;
	}
}
elsif ($all) {
	my @files;
	foreach my $dir (subs::backups_dir(), subs::backup_archive_dir()) {
		next unless defined $dir && length $dir;
		push @files, grep { -f $_ } glob($dir . '/jawnos_*.enc');
	}
	my %seen;
	@files = grep { !$seen{$_}++ } @files;
	my @reports = map { subs::backup_verify_file($_, $secret) } @files;
	$report = {
		ok => (scalar(grep { !$_->{'ok'} } @reports) ? 0 : 1),
		checked => scalar @reports,
		reports => \@reports,
		error => (scalar @reports ? undef : 'no snapshots to verify'),
	};
}
else {
	$report = subs::backup_verify_retained();
}

if ($json) {
	print JSON::PP::encode_json($report), "\n";
}
else {
	my $checked = $report->{'checked'} || 0;
	print "backup verify: ", ($report->{'ok'} ? 'ok' : 'FAILED'), " ($checked checked)\n";
	print "  ", $report->{'error'}, "\n" if $report->{'error'};
	foreach my $one (@{ $report->{'reports'} || [] }) {
		if ($one->{'ok'}) {
			print "  ok   ", $one->{'path'}, " (", ($one->{'size'} || 0), " bytes)\n";
		}
		else {
			print "  FAIL ", $one->{'path'}, ": ", ($one->{'error'} || 'integrity check failed'), "\n";
			foreach my $line (@{ $one->{'integrity'} || [] }) { print "       $line\n"; }
		}
	}
}
exit(($report->{'ok'} ? 0 : 1));
