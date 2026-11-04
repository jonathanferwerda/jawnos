# tests-for: lib/JawnOS/Manager/Part21.pm lib/JawnOS/Controller/manager_ws.pm
# covers:    The phone asks its notification bridge once per grab (the duplicate
#            call doubled the bridge traffic and the masked-declaration warning),
#            and the dead remote-websocket builder no longer runs or warns on
#            every socket connect.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

my $root = root();

my $part21 = read_file("$root/lib/JawnOS/Manager/Part21.pm");
my @calls = ( $part21 =~ /device_call\('notification\.list'\)/g );
is( scalar @calls, 1, 'the notification bridge is asked once per grab' );
my @decl = ( $part21 =~ /my \$bridge_nl\b/g );
is( scalar @decl, 1, 'one $bridge_nl declaration, so the mask warning is gone' );

my $ws = read_file("$root/lib/JawnOS/Controller/manager_ws.pm");
unlike( $ws, qr/unless \(1 == 0 && \$c->param\('remote'\)/, 'the always-true remote builder is gone' );
unlike( $ws, qr/\$rm->\{'ws_port'\}/, 'the dead ws_port command is gone' );
unlike( $ws, qr/\$rm->\{'ws_auth'\}/, 'the dead ws_auth command is gone' );

done_testing();
