# tests-for: lib/JawnOS/Domain/Lan.pm perl/President.pl
use strict;
use warnings;

use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root = "$FindBin::Bin/..";
my $lan  = read_file("$root/lib/JawnOS/Domain/Lan.pm");

like($lan, qr/our %lan_presence_applied_at;/, 'the listener keeps a per-source stamp');
like($lan, qr/sub lan_presence_due \{/, 'the rate gate is its own sub');
like($lan, qr/\$lan_presence_applied_at\{\$ip\}/, 'the stamp is keyed by source address');
like($lan, qr/next unless &lan_presence_due\(\$ip, time\(\), 1\);/,
	'the listener applies at most one datagram per source per second');

my $pres = read_file("$root/perl/President.pl");
my ($levels) = $pres =~ /(my \$fast = &subs::cache_get\(\{ app => '__president', context => 'levels', subcontext => 'fast' \}.*?name => 'house levels')/s;
ok($levels, 'the house levels loop is still one block');
like($levels, qr/\bsleep 5;/, 'the fast levels slice waits five seconds');
unlike($levels, qr/\bsleep 2;/, 'and no longer wakes every two seconds');

done_testing();
