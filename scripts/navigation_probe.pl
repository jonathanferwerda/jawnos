#!/usr/bin/env perl
# navigation_probe.pl - watch the navigation utility for a while and say whether
# each machine kept the pace its utility row was given.
#
#   perl scripts/navigation_probe.pl --minutes 180
#   perl scripts/navigation_probe.pl --once                 # one sample (already a probe)
#   perl scripts/navigation_probe.pl --report [FILE]        # judge what was logged
#   perl scripts/navigation_probe.pl --report --device e397 # one machine only
#
# Read-only. What it watches:
#   * the utility controller's own per-machine row (scripts read the persisted
#     copy): navigation toggle, the pace it was given, last_run/last_attempt,
#     last_effect and status - a job that ran leaves a new last_run;
#   * the one `temporary` place row the navigator rewrites on every capture, by
#     timestamp and accuracy only. No coordinates are written to the log, so it
#     can be read out without exposing where the house was.
#
# The pace a machine actually keeps is the only thing that answers "is it
# checking every four minutes": the controller can say "on, 240s" while a phone
# that sleeps between wakes never gets a turn. A gap longer than 1.75 paces is
# reported as a missed slot; a window shorter than two paces is not judged.
#
# The log is .shots/navigation_probe.log (gitignored) unless --out names another.
use strict;
use warnings;

use FindBin;
use Getopt::Long qw(GetOptions);
require Mojo::JSON;

chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $minutes = 180;
my $every   = 60;
my $out     = '.shots/navigation_probe.log';
my $report;
my $once    = 0;
my $device  = '';

GetOptions(
	'minutes=i' => \$minutes,
	'every=i'   => \$every,
	'out=s'     => \$out,
	'report:s'  => \$report,
	'once'      => \$once,
	'device=s'  => \$device,
) or die "usage: perl scripts/navigation_probe.pl [--minutes N] [--every S] [--out FILE] [--report [FILE]] [--once] [--device SIG]\n";
$every = 10 if $every < 10;

# One look at every machine the controller or the place rows know about.
sub sample {
	my $now = &subs::rightNow();
	my $controls = eval { Mojo::JSON::decode_json( &subs::setting_grabber({ app => '__president', setting => 'utility_controller' }) // '' ) } || {};
	my %temp;
	my $rows = eval { &subs::db_query('select signatorial, timestamp, server_time, accuracy from continent where type = ?', 'temporary') };
	foreach my $r ( $rows ? @{ $rows->hashes } : () ) {
		next unless defined $r->{'signatorial'} && length $r->{'signatorial'};
		$temp{ $r->{'signatorial'} } = $r;
	}
	my $want = lc $device;
	my (@devices, %seen);
	foreach my $sig ( sort keys %{$controls} ) {
		next if $sig =~ /^__/;
		my $row = $controls->{$sig};
		next unless ref $row eq 'HASH';
		my $job = ref $row->{'navigation'} eq 'HASH' ? $row->{'navigation'} : {};
		next if length $want && index( lc($sig), $want ) < 0;
		# a machine with the job off and no place row has nothing to see
		next unless ( ( $job->{'toggle'} || '' ) eq 'on' ) || $temp{$sig};
		my $pace = &subs::batch_interval( $row, 'navigation' ) || $job->{'interval'} || 0;
		$seen{$sig} = 1;
		push @devices, {
			sig          => $sig,
			toggle       => $job->{'toggle'} || '',
			pace         => $pace,
			last_run     => $job->{'last_run'},
			last_attempt => $job->{'last_attempt'},
			effect       => $job->{'last_effect'},
			status       => $job->{'status'},
			temp_ts      => $temp{$sig} ? $temp{$sig}->{'timestamp'} : undef,
			temp_accuracy => $temp{$sig} ? $temp{$sig}->{'accuracy'} : undef,
			temp_written => $temp{$sig} ? $temp{$sig}->{'server_time'} : undef,
		};
	}
	# a machine whose place row synced in but whose controller row has not
	foreach my $sig ( sort keys %temp ) {
		next if $seen{$sig};
		next if length $want && index( lc($sig), $want ) < 0;
		push @devices, {
			sig          => $sig,
			toggle       => '',
			pace         => 0,
			temp_ts      => $temp{$sig}->{'timestamp'},
			temp_accuracy => $temp{$sig}->{'accuracy'},
			temp_written => $temp{$sig}->{'server_time'},
		};
	}
	return { at => $now, devices => \@devices };
}

sub append_sample {
	my ($path, $sample) = @_;
	open( my $fh, '>>', $path ) or do { warn "cannot write $path: $!\n"; return; };
	print $fh Mojo::JSON::encode_json($sample), "\n";
	close $fh;
}

sub read_samples {
	my ($path) = @_;
	return [] unless -e $path;
	open( my $fh, '<', $path ) or return [];
	my @samples;
	while ( my $line = <$fh> ) {
		next unless $line =~ /\S/;
		my $sample = eval { Mojo::JSON::decode_json($line) };
		push @samples, $sample if ref $sample eq 'HASH';
	}
	close $fh;
	return \@samples;
}

sub print_summary {
	my ($path) = @_;
	my $samples = read_samples($path);
	my $summary = &subs::navigation_probe_summary( $samples, { device => $device } );
	print 'navigation probe: ', $summary->{'samples'}, ' sample(s) over ',
		int( $summary->{'span_ms'} / 60000 ), " minute(s) from $path\n";
	print "  $_\n" for @{ $summary->{'lines'} };
	print "  (no machines to judge - is the navigation utility on?)\n" unless @{ $summary->{'lines'} };
}

if ( defined $report ) {
	my $path = length($report) ? $report : $out;
	print_summary($path);
	exit 0;
}

mkdir '.shots' unless -d '.shots';
my $sample = sample();
append_sample( $out, $sample );
printf "%s: sampled %d machine(s), log %s\n", scalar( localtime(time) ), scalar @{ $sample->{'devices'} }, $out;
exit 0 if $once;

my $deadline = time() + ( $minutes * 60 );
local $SIG{INT}  = sub { $deadline = 0 };
local $SIG{TERM} = sub { $deadline = 0 };
while ( $deadline > time() ) {
	my $wake = time() + $every;
	while ( time() < $wake && $deadline > time() ) { sleep 1; }
	last unless $deadline > time();
	my $next = sample();
	append_sample( $out, $next );
	printf "%s: sampled %d machine(s)\n", scalar( localtime(time) ), scalar @{ $next->{'devices'} };
}
print_summary($out);
