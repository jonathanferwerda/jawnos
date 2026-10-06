#!/usr/bin/perl

use File::Slurp;
use Mojo::JSON qw/decode_json encode_json/;


my $self = shift;
my $uname = `uname -r`;
print "Protecting " . $self . "\n\n\n";


my $allowed = 1;
$allowed = 0 unless $self =~ /[0-9]/gi;
$self = 000000000000 unless $self;
my @killers = ('./President.pl', './teletype.pl', './watch.pl', './Manager.pl', 'termux-tts-spea', 'sshpass');
foreach my $k (@killers) {
	my $ps = `ps -e`;
	print "running pkill ./$k\n";
	`pkill $k`;
	sleep .2;
	my @ps = grep { $_ !~ /^ $self/ } split "\n", `ps -e | grep $k`;
	until (scalar @ps <= $allowed) {
		foreach my $ps (@ps) {
			next if $ps == $self;
			my $p = $ps[$n];  
			my @n = split " ", $p;
			my $n = $n[0] . "\n" ;
			if ($ps =~ /defunct/) {
				#my $tree = 
			}
			print $p . ' ' . $n ."\n";
			# `kill -9 $n`; 
			`kill -9 $n` unless $n == $self;
			print $n;
		}
		sleep .5;
		@ps = grep { $_ !~ /^ $self/ } split "\n", `ps -e | grep $k`;
		print scalar @ps . "\n";
	}
}


my $command = 'ss -tlnp | grep :3000 | grep -oP \'pid=\K\d+\'';
my $running_pids = `$command`;
print $running_pids . "\n";
my @running_pids = split /\n/, $running_pids;

foreach my $p ( @running_pids ) {

	my $kill = `kill -9 $p`;
	print $kill . "\n";
}
if ($uname =~ /android/) {
	`pkill ssh`;
	`sshd`;
}