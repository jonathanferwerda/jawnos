# tests-for: lib/JawnOS/Domain/Device.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Manager/Part34.pm templates/embedded/body.html.ep templates/embedded/watch.html.ep public/js/manager/embedded.js
# covers:    The Embedded panel says which machine a device is paired to, and a
#            scan's results can be pressed instead of retyped. A board names its
#            homebase as ip:port in its own settings row; the panel resolves that
#            to the machine's name so nobody has to remember which address is the
#            Table. Scan results are drawn as buttons because a datalist does not
#            open on its own in every engine this desktop runs on.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $read = sub { scalar read_file("$root/$_[0]") };

# --- the address resolves to a machine name -------------------------------
my $device = $read->('lib/JawnOS/Domain/Device.pm');
my ($resolver) = $device =~ /(sub machine_name_for_ip \{.*?\n\})/s;
ok($resolver, 'machine_name_for_ip is one function');
like($resolver, qr/\\d\{1,3\}/, 'it only takes an address');
like($resolver, qr/db_select\('devices'\)/, 'it reads the machine rows');
like($resolver, qr/\$a->\{'ip'\}.*eq \$ip/, 'and matches the address map');
like($resolver, qr/return \$d->\{'hostname'\}/, 'answering with the machine name');
like($resolver, qr/return \$ip;/, 'and with the address itself when nobody claims it');

my $loader = $read->('lib/JawnOS/Domain/Loader.pm');
like($loader, qr/JawnOS::Domain::Device' for qw\([^)]*\bmachine_name_for_ip\b/, 'the loader maps it');

# --- the panel is given the machine, by name ------------------------------
my $part34 = $read->('lib/JawnOS/Manager/Part34.pm');
like($part34, qr/my \$homebase = \$op_d->\{'__specs'\}->\{'homebase'\}/, 'the panel reads the paired machine');
like($part34, qr/\$homebase =~ s\{:\\d\+\$\}\{\}/, 'dropping the port from ip:port');
like($part34, qr/name => \(\$homebase ne '' \? &subs::machine_name_for_ip\(\$homebase\) : ''\)/, 'and resolves the name');
like($part34, qr/\n\t\tbridge => \$bridge,/, 'which is handed to the template');

# --- and the template says it near the top --------------------------------
my $body = $read->('templates/embedded/body.html.ep');
like($body, qr/id="embedded_bridge"/, 'the panel has a bridge line');
like($body, qr/&subs::format_name\(\$bridge->\{'name'\}\)/, 'naming the machine');
like($body, qr/\$bridge->\{'ip'\}/, 'with the address beside it');
my $bridge_at = index($body, 'id="embedded_bridge"');
my $homebase_at = index($body, 'id="teletype_homebase"');
ok($bridge_at >= 0 && $homebase_at > $bridge_at, 'the line sits above the rest of the panel');

# --- a scan result can be pressed ----------------------------------------
like($body, qr/id="teletype_wifi_picks"/, 'the panel has a place for scan results');
my $watch = $read->('templates/embedded/watch.html.ep');
like($watch, qr/id="teletype_wifi_picks"/, 'so does the watch layout');

my $js = $read->('public/js/manager/embedded.js');
like($js, qr/var picks = \$\('#teletype_wifi_picks'\)\.empty\(\)/, 'a scan refreshes the results');
like($js, qr/addClass\('teletype_wifi_pick'\)/, 'each network is drawn as a button');
like($js, qr/\.attr\('data-ssid', ssid\)/, 'carrying the name exactly');
like($js, qr/\$\('#teletype_wifi_ssid'\)\.val\(ssid\)\.trigger\('change'\)/, 'pressing one fills in and saves the name');
like($js, qr/\$\('#teletype_wifi_picks'\)\.empty\(\);/, 'and a fresh scan clears the old results');

done_testing();
