# tests-for: perl/President.pl perl/President/prefork_autoscale.pl
# covers:    A phone starts no dock listener, no tty listeners, and never grows its main pool.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A handheld carried four listeners nothing on it can use: the dock door (no
# boards, no guest on its LAN, and a peer reaches it on PORT_AHOY since
# v0.1.2168) and the two teletype doors (a session needs a shell on the machine
# it runs on, and Android offers none). Each listener was a whole app - a
# prefork manager plus a worker - in a tree Android's low-memory killer is
# already watching. The main pool also stops growing: every extra worker was a
# fork of a 100 MB+ process, and that spike is what tripped the killer.

my $root = repo_root();
my $src = read_file("$root/perl/President.pl");
my $autoscale = read_file("$root/perl/President/prefork_autoscale.pl");

my @guards;
while ($src =~ /if \(\$device ne 'mobile'\) \{/g) {
	push @guards, pos($src);
}
is(scalar @guards, 2, 'a phone skips exactly two groups of listeners');

like($src, qr/if \(\$device ne 'mobile'\) \{\s*&subs::subprocessor\(sub \{.*?name => 'Pro Locker Server' \}\);\s*\}/s,
	'the dock listener is the first skip');

my $rest = $src;
$rest =~ s/if \(\$device ne 'mobile'\) \{\s*&subs::subprocessor\(sub \{.*?name => 'Pro Locker Server' \}\);\s*\}//s;
like($rest, qr/if \(\$device ne 'mobile'\) \{\s*&subs::subprocessor\(sub \{.*?name => 'TTY WS Server' \}\);\s*\}/s,
	'both teletype listeners are the second skip');

$rest =~ s/if \(\$device ne 'mobile'\) \{\s*&subs::subprocessor\(sub \{.*?name => 'TTY WS Server' \}\);\s*\}//s;
for my $keep ('Pro WS Server', 'Pro Main Server', 'Pro Alarm Server', 'Watch Server') {
	like($rest, qr/name => '\Q$keep\E'/, "$keep still starts on a phone");
}

like($src, qr/&prefork_autoscale\(\$prefork, min => \$main_workers, max => \$device eq 'mobile' \? \$main_workers : \$main_workers \+ 2\);/,
	'a phone rests at its worker count while a desktop still grows by two');
like($autoscale, qr/return \$prefork if \$max <= \$min;/,
	'a cap equal to the pool never even starts the supervisor');

done_testing();
