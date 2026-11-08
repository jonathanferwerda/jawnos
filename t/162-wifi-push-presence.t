# tests-for: lib/JawnOS/Domain/Ble.pm lib/JawnOS/Controller/manager_misc13.pm
# covers:    A Pico off its WiFi only has a Bluetooth sighting, and once that
#            sighting is older than ble_presence_window() (two hours) the WiFi
#            button stopped pushing: ble_push_available() asked device_lister()
#            for the chip, got the whole device array back, and answered 0; the
#            route then dereferenced that array as a hash for the HTTP fallback.
#            Both now resolve through embedded_device(), which falls back to the
#            recorded chip (and its radio address) after the sighting lapses,
#            and the fallback refuses a non-hash instead of dying.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $ble  = read_file("$root/lib/JawnOS/Domain/Ble.pm");
my $misc = read_file("$root/lib/JawnOS/Controller/manager_misc13.pm");

my ($sender) = $ble =~ /(sub bluetooth_sender \{.*?\n\})/s;
ok($sender, 'bluetooth_sender is still one sub');
like($sender, qr/my \$embedded = &subs::embedded_device\(/,
	'the send resolves a recorded chip, not just a fresh neighbour row');
unlike($sender, qr/my \$embedded = &subs::device_lister\(/,
	'and no longer lets the presence window answer with the whole device array');

my ($available) = $ble =~ /(sub ble_push_available \{.*?\n\})/s;
ok($available, 'ble_push_available is still one sub');
like($available, qr/my \$embedded = &subs::embedded_device\(/,
	'the cheap gate accepts a recorded (lapsed) chip too');
like($available, qr/ref \$embedded eq 'HASH'/,
	'and still requires a resolved device');

my ($route) = $misc =~ /(sub action_43067 \{.*?\n\})/s;
ok($route, 'the WiFi push route is still one sub');
like($route, qr/ref \$teletype ne 'HASH'/,
	'the HTTP fallback refuses the whole device array');
like($route, qr/not reachable: no live Bluetooth link and no network address/,
	'and says why instead of dying on it');
like($route, qr/\\d\{1,3\}/,
	'only a real address is used for the HTTP pull');


# --- a board on the device socket is not pushed again over BLE ---------------

like($ble, qr/next if &subs::device_ws_connected\(\$w->\{'chip_id'\}\);/,
	'a board holding the device socket is skipped for the BLE toggle push');
my $ws_skip = index($ble, q!device_ws_connected($w->{'chip_id'})!);
my $ws_push = index($ble, q!push @targets, { chip_id => $w->{'chip_id'}, edt => $dev_edt };!);
ok($ws_skip >= 0 && $ws_push >= 0 && $ws_skip < $ws_push,
	'skipped before it is added as a BLE target, not after');

done_testing();
