# tests-for: perl/hooks.pl lib/JawnOS/Domain/House.pm
# covers:    A browser's state change must come from this house. The origin
#           helper accepts this box's own host (with or without a port, any
#           case, IPv6), an XHR with no source, and refuses a foreign, opaque or
#           scheme-relative source even when the caller claims XHR. The
#           dispatcher asks the helper and answers 403 when it refuses.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my @ours = ('house.example', '127.0.0.1', 'localhost', '::1');

# --- the origin decision ----------------------------------------------------
ok(subs::http_origin_ok('https://house.example', \@ours, 0), 'the house origin is accepted');
ok(subs::http_origin_ok('http://house.example:3000', \@ours, 0), 'a port on the house origin is accepted');
ok(subs::http_origin_ok('https://HOUSE.Example', \@ours, 0), 'the host comparison ignores case');
ok(subs::http_origin_ok('https://[::1]:3000', \@ours, 0), 'a bracketed IPv6 origin with a port is accepted');
ok(subs::http_origin_ok('https://127.0.0.1', \@ours, 0), 'loopback is accepted');
ok(subs::http_origin_ok('https://house.example/manager/pen', \@ours, 0), 'a Referer with a path is accepted');
ok(subs::http_origin_ok('', \@ours, 1), 'an XHR that names no source is accepted');

ok(!subs::http_origin_ok('', \@ours, 0), 'a form post that names no source is refused');
ok(!subs::http_origin_ok(undef, \@ours, 0), 'an absent source without XHR is refused');
ok(!subs::http_origin_ok('https://evil.example', \@ours, 1), 'a foreign origin is refused even with X-Requested-With');
ok(!subs::http_origin_ok('https://house.example.evil', \@ours, 0), 'a suffix look-alike is refused');
ok(!subs::http_origin_ok('https://evil.example/house.example', \@ours, 0), 'a path that names the house is not the origin');
ok(!subs::http_origin_ok('null', \@ours, 0), 'an opaque "null" origin is refused');
ok(!subs::http_origin_ok('//house.example', \@ours, 0), 'a scheme-relative source is refused');

# --- the dispatcher asks it -------------------------------------------------
my $hooks = read_file(root() . '/perl/hooks.pl');
ok(index($hooks, '&subs::http_origin_ok(') >= 0, 'the dispatcher asks the origin helper');
ok(index($hooks, 'security/media_lock') >= 0, 'the media-lock beacon stays exempt');
like($hooks, qr/\(?:debrief\|js_error\|security\/media_lock\)/, 'the three beacons are named in one place');
like($hooks, qr/\$c->res->code\(403\)/, 'a refused source answers 403');
ok(index($hooks, 'X-Peer-Signature') >= 0, 'a peer signed request is exempt');
ok(index($hooks, 'X-Jawn-Authorization') >= 0, 'an embedded board token is exempt');
like($hooks, qr/\(\?:POST\|PUT\|PATCH\|DELETE\)/, 'only state-changing methods are checked');

done_testing();
