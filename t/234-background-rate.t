# tests-for: lib/JawnOS/Domain/Lan.pm lib/JawnOS/Domain/House.pm perl/President.pl
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
like($lan, qr/\$sock->blocking\(0\);/, 'the listener socket does not block');
like($lan, qr/sleep 1;\n\s*my %pending;/, 'one drain pass a second');
like($lan, qr/\$pending\{\$ip\}\{\$data =~/, 'the newest of each kind per source is kept');
like($lan, qr/last unless defined \$peer;/, 'the drain stops at EAGAIN');
unlike($lan, qr/can_read\(15\)/, 'the per-datagram select is gone');
like($lan, qr/my \$window = \$type eq 'jawnos-nav' \? 5 : 1;/, 'navigation is applied at most every five seconds');
like($lan, qr/&lan_presence_due\(\$ip \. '\|' \. \$type, time\(\), \$window\)/, 'the gate is keyed by source and kind');

my $house = read_file("$root/lib/JawnOS/Domain/House.pm");
like($house, qr/our %lan_presence_fingerprint;/, 'presence keeps a per-peer fingerprint');
like($house, qr/my \$fingerprint = join .*?keys %\{\$msg\};/s, 'the fingerprint covers the beacon fields');
like($house, qr/return if ref \$seen eq 'ARRAY' && \$seen->\[0\] eq \$fingerprint/, 'an unchanged beacon returns before the row work');
like($house, qr/< 60000;/, 'a full pass is forced once a minute');
like($house, qr/\$lan_presence_fingerprint\{\$fingerprint_key\} = \[\$fingerprint, &rightNow\(\)\];/, 'only a verified message is remembered');
like($house, qr/nonce\|signatorial\|sig/, 'the signature is excluded from the fingerprint');

my $pres = read_file("$root/perl/President.pl");
my ($levels) = $pres =~ /(my \$fast = &subs::cache_get\(\{ app => '__president', context => 'levels', subcontext => 'fast' \}.*?name => 'house levels')/s;
ok($levels, 'the house levels loop is still one block');
like($levels, qr/\bsleep 5;/, 'the fast levels slice waits five seconds');
unlike($levels, qr/\bsleep 2;/, 'and no longer wakes every two seconds');

done_testing();
