# tests-for: desktop/jawnos_desktop/browser.py
# covers:    The Browse window accepts the house's self-signed certificate through
#            the shared Qt helper; the GTK/WebKitGTK TLS path is gone.

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

like($browser, qr/from \.qt_shell import _accept_certificate/,
	'Browse borrows the Qt shell\'s certificate rule');
like($browser, qr/certificateError\.connect\(_accept_certificate\)/,
	'and accepts the house certificate on every page');
unlike($browser, qr/TLSErrorsPolicy/,
	'the WebKit TLS policy is gone from Browse');
unlike($browser, qr/allow_tls_certificate_for_host/,
	'and it never makes a per-host WebKit allowance');

done_testing();
