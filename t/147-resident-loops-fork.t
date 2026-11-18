# tests-for: lib/JawnOS/Domain/Lan.pm perl/President.pl perl/jobs.pl
# covers:    Resident loops must be real children. subprocessor() runs inline
#            when another job is already running, and an inline forever loop
#            never returns: it pins a prefork main worker, the autoscaler adds
#            more, and the phone heats up. The tunnel holder and the LAN/BLE
#            resident loops ask for a child.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

my $root = root();

my $lan = read_file("$root/lib/JawnOS/Domain/Lan.pm");
like( $lan, qr/name => 'tunnel holder wss ' \. scalar\(\@uuids\) \. ' ports', warranty => 'forever', fork => 1/,
	'the tunnel holder is a real child' );

my $pres = read_file("$root/perl/President.pl");
for my $name ( 'lan presence beacon', 'lan presence listener', 'lan mesh wake', 'ble adopt scan', 'audio supervisor' ) {
	my $q = quotemeta($name);
	like( $pres, qr/name => '$q', fork => 1/,
		"the resident loop '$name' is a real child" );
}

my $jobs = read_file("$root/perl/jobs.pl");
like( $jobs, qr/^sub job_audio_supervisor\b/m, 'the audio supervisor job exists' );
like( $jobs, qr/'audio supervisor' => \\&job_audio_supervisor/,
	'it is registered by name for a box without fork' );
like( $pres, qr/perl\/audio\/jawn-audio/,
	'the master starts the audio supervisor only when the engine is staged' );
like( $pres, qr/job_audio_supervisor/,
	'and the job it starts is the one jobs.pl registers' );

done_testing();
