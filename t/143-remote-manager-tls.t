# tests-for: desktop/jawnos_desktop/browser.py
# covers:    The Browse window trusts only this install's own certificates through
#            the shared Qt policy; the GTK/WebKitGTK TLS path is gone.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The house ships a CN=localhost certificate. Browse is Qt WebEngine: it accepts
# that certificate through qt_shell's one helper (the same exception the Qt
# manager view makes), and never makes a per-host WebKit allowance. The WebKitGTK
# view this test used to cover is deleted.

my $root = repo_root();
my $browser = read_file("$root/desktop/jawnos_desktop/browser.py");

ok(!-e "$root/desktop/jawnos_desktop/webview.py", 'the WebKitGTK view is deleted');

like($browser, qr/from \. import [^\n]*\btrust\b/,
	'Browse uses the shared certificate policy');
like($browser, qr/certificateError\.connect\(trust\.accept_certificate\)/,
	'and applies it on every page');
like($browser, qr/trust\.set_tree\(core\.load_settings\(\)\.get\("jawn_dir"\)\)/,
	'with the tree from the same settings the shell saves');
unlike($browser, qr/TLSErrorsPolicy/,
	'the WebKit TLS policy is gone from Browse');
unlike($browser, qr/allow_tls_certificate_for_host/,
	'and it never makes a per-host WebKit allowance');

done_testing();
