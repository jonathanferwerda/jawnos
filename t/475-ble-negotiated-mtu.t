# tests-for: desktop/jawnos_desktop/ble.py
# covers:    The desktop bridge reports the MTU the peer actually agreed to,
#            not the 512 it asked for. Framing a notify at the request when the
#            ATT link settled at 23 is what silently drops parts; reading
#            BlueZ's GattCharacteristic1.MTU makes status and framing honest,
#            and an older BlueZ without the property keeps the old fallback.
#            Measured on the watch/phone link: the request of 512 is granted,
#            so the phone's bridge reports 512 and BLE audio keeps up.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $ble = read_file("$FindBin::Bin/../desktop/jawnos_desktop/ble.py");

like($ble, qr/def _char_prop\(self, path, name\):/,
	'a characteristic property reader exists');
like($ble, qr/Get\(GATT_CHAR_IFACE, name\)/,
	'and reads the characteristic interface, not Device1');
like($ble, qr/negotiated = int\(self\._char_prop\(notify_char, "MTU"\)\)/,
	'the connected link asks BlueZ for the negotiated MTU');
like($ble, qr/if negotiated >= 23:\s*\n\s*link\.mtu = negotiated/,
	'and frames at that value when the stack reports one');
like($ble, qr/link\.mtu = int\(link\.target\.get\("mtu"\) or DEFAULT_MTU\)/,
	'the request is still the fallback when the property is absent');
like($ble, qr/except \(dbus\.exceptions\.DBusException, TypeError, ValueError\)/,
	'an older BlueZ without MTU does not break the connect');

done_testing();
