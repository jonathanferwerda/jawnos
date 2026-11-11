# tests-for: lib/JawnOS.pm lib/JawnOS/Controller/ lib/JawnOS/Manager.pm lib/JawnOS/Manager/ lib/JawnOS/Routes.pm lib/JawnOS/Routes/ perl/Manager.pl perl/President.pl public/js/mailbox.js public/js/manager/websocket.js public/js/manager/websocket/ public/js/paperboy.js
# covers:    The app's WebView trusts the house certificate for page loads - JawnWebViewActivity.onReceivedSslError proceed...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The app's WebView trusts the house certificate for page loads -
# JawnWebViewActivity.onReceivedSslError proceeds for 127.0.0.1 - but a
# WebSocket handshake never reaches that callback, so every wss:// socket from
# the app died with ERR_CERT_AUTHORITY_INVALID (-202). A boot logged 12,089
# handshake failures in four minutes.
#
# The socket server now also listens plainly on loopback. Chromium treats
# 127.0.0.1 as trustworthy, so the https page may open ws:// there (verified in
# Chromium: a ws://127.0.0.1 socket from an https://127.0.0.1 page opens). The
# Secure session cookie is not sent on a ws:// handshake, so the page carries a
# short-lived token that restores the session for the socket.

my $president = read_file("$FindBin::Bin/../perl/President.pl");
my $manager   = manager_source();

# 1. the plain listener exists, on loopback, and only with the socket server
like($president, qr/JawnOS::Platform::Ports::port_for\(\s*'ws_plain', base => \$port, ws_port => \$ws_port,\s*\)/s,
	'the plain socket port is derived from the socket port');
like($president, qr/\$ENV\{PORT_WS_PLAIN\} = \$ws_plain_port if \$config->\{'environment'\} eq 'production';/,
	'the plain port is exported in production');
like($president, qr/my \@ws_listeners = \( 'https:\/\/\*:' \. \$ws_port \. \$certs, 'http:\/\/127\.0\.0\.1:' \. \$ws_plain_port \);/,
	'the socket server listens on https and on plain loopback');
like($president, qr/&server_process\('\.\/perl\/Manager\.pl', \\\@ws_listeners,/,
	'the socket server is handed both listeners');

# 2. the URL helper and the token
like($manager, qr/^sub ws_url_for \{/m, 'the page has one socket URL builder');
like($manager, qr/^sub ws_plain_token \{/m, 'a loopback token is minted');
like($manager, qr/^sub ws_plain_auth \{/m, 'a token restores the session');
like($manager, qr/warranty => '\+12h'/,
	'the token is a working day, not a week');
like($manager, qr/\$auth{'_ws_remote'}/,
	'and is bound to the address that minted it');
like($manager, qr/\$c->session\(%\{\$auth\}\);/,
	'the socket session is restored from the token');
like($manager, qr/\$host eq '127\.0\.0\.1' \|\| \$host eq 'localhost' \|\| \$host eq '::1'/,
	'only loopback uses the plain listener');
like($manager, qr/return 'ws:\/\/' \. \$shown \. ':' \. \$plain \. \$path \. '\?ws_token='/,
	'the plain URL carries its token');
like($manager, qr/return 'wss:\/\/' \. \$host \. ':' \. \$ENV\{'PORT_MSG'\} \. \$path;/,
	'every other host stays on wss');

# 3. every local socket URL goes through the helper
my @local = ($manager =~ /'wss:\/\/' \. \$c->req->url->base->host/g);
is(scalar @local, 0, 'no page builds a wss URL by hand for itself');
my @calls = ($manager =~ /&ws_url_for\(\$c, '\/(?:manager|mail|observer)\/ws'\)/g);
is(scalar @calls, 10, 'the three socket URLs are built at all five pages');
my @auths = ($manager =~ /^\t&ws_plain_auth\(\$c\);/mg);
is(scalar @auths, 3, 'the mail, manager and observer sockets accept the token');

# The app gate runs before the route and reads the session, so the token must
# be restored there first; otherwise the handshake gets the Gate page (200)
# instead of 101 Switching Protocols.
my ($gate) = $manager =~ /sub authentication_passer\(\$c\) \{(.*?)\n\}/s;
ok(defined $gate, 'the app gate is found');
like($gate // '', qr/if \(\$app_path =~ m\{\/\(\?:mail\|manager\|observer\)\/ws\\z\}\) \{\s*\n\s*&ws_plain_auth\(\$c\);\s*\n\s*\}/,
	'the gate restores the ws token session before it reads it');

# 4. the JS appends its query after a token, not after a bare '?'
my $mailbox = read_file("$FindBin::Bin/../public/js/mailbox.js");
my $socket  = js_source('public/js/manager/websocket.js');
my $paper   = read_file("$FindBin::Bin/../public/js/paperboy.js");
like($mailbox, qr/var mailws_sep = \(mail_ws_url\.indexOf\('\?'\) >= 0\) \? '&' : '\?';/,
	'the mail socket resolves its query separator');
like($socket, qr/var sep = \(base\.indexOf\('\?'\) >= 0\) \? '&' : '\?';/,
	'the manager socket resolves its query separator (in the URL helper now)');
like($paper, qr/var paperboy_sep = \(paperboy_url\.indexOf\('\?'\) >= 0\) \? '&' : '\?';/,
	'the observer socket resolves its query separator');

done_testing();
