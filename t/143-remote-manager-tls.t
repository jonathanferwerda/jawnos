# tests-for: desktop/jawnos_desktop/webview.py desktop/jawnos_desktop/browser.py
# covers:    A peer Manager window trusts its paired self-signed certificate; the general browser stays strict.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A peer's Manager ships the image's CN=localhost certificate, which does not
# name the peer. WebKit's per-host TLS allowance cannot rescue a hostname
# mismatch, so the peer window's load finished with an empty URI (a white
# window) even though allow_tls_certificate_for_host had been called. A peer
# Manager opened by a signed Go gets its own context with TLS errors ignored;
# the local Manager and the Internet app's external browser keep FAIL.

my $root = repo_root();
my $web = read_file("$root/desktop/jawnos_desktop/webview.py");
my $browser = read_file("$root/desktop/jawnos_desktop/browser.py");

like($web, qr/def _window_context\(manager_url_override\)/,
	'the panel chooses its context from the manager override');

like($web, qr/if not manager_url_override:\s*\n\s*return _context_get\(\)/,
	'a local Manager window keeps the app default context');

like($web, qr/context\.set_tls_errors_policy\(WebKit2\.TLSErrorsPolicy\.IGNORE\)/,
	'a peer Manager context ignores its paired self-signed certificate');

like($web, qr/self\._window_context\(manager_url_override\)/,
	'the panel view is built in that context');

like($web, qr/view\.get_context\(\)\.allow_tls_certificate_for_host/,
	'the TLS allowance follows the view, not a hard-wired default context');

like($browser, qr/TLSErrorsPolicy\.FAIL/,
	'the general browser still fails TLS errors');
unlike($browser, qr/TLSErrorsPolicy\.IGNORE/,
	'and never turns that policy off');

done_testing();
