# tests-for: desktop/jawnos_desktop/browser.py desktop/icons/jawnos-bug.svg
# covers:    The browse window's baseline ad filter, the per-site block list that bug mode writes,
#            and the fullscreen chrome that used to leave bars above and below a video.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use RepoSource;

# The browser blocks a curated baseline of ad hosts (a Qt request interceptor)
# and hides an element the person taps in bug mode. The tapped selector is
# keyed by the view's own registrable domain and kept in adblock.json. A page's
# fullscreen request must also take the tool bar, tab strip and status line off
# screen.

my $root = repo_root();
my $src = read_file("$root/desktop/jawnos_desktop/browser.py");

like($src, qr/class AdBlockStore/,
	'the block list has its own store');
like($src, qr/"doubleclick\.net"/,
	'the baseline names the display-ad hosts');
like($src, qr/def is_ad_host\(host\):/,
	'the baseline host match is a checked helper');
like($src, qr/class _AdInterceptor\(_InterceptorBase\)/,
	'and is enforced by a Qt request interceptor');
like($src, qr/info\.block\(True\)/,
	'an ad request is actually blocked');
like($src, qr/firstPartyUrl\(\)\.host\(\)/,
	'the interceptor keeps the third-party rule');
like($src, qr/ScriptWorldId\.UserWorld/,
	'the picker runs in an isolated script world');
like($src, qr/__jawnos_adblock_message/,
	'and reaches the bridge over a DOM event');
like($src, qr/setCornerWidget\(tab_actions, Qt\.Corner\.TopRightCorner\)/,
	'the bug controls sit in the tab row');
like($src, qr/def _set_fullscreen_chrome\(self, on\):/,
	'a page fullscreen drives the window chrome');
like($src, qr/self\.tabs\.tabBar\(\)\.setVisible\(False\)/,
	'and takes the tab strip off screen');
like($src, qr/self\.toolbar\.setVisible\(False\)/,
	'and the tool bar with it');
like($src, qr/ADBLOCK_FILE = "adblock\.json"/,
	'the person\'s list has a stable file name');
like($src, qr/Key on the page's own URI/,
	'the write is keyed on the view, not on the page\'s claimed URL');

my $python = qx{python3 --version 2>/dev/null};
SKIP: {
	skip 'python3 is not installed', 2 unless $python;

	# With no Qt installed the module still has to import: the fallback once
	# missed QLineEdit (AddressEntry's base), so the import died with NameError
	# and the clean "PySide6 with Qt WebEngine is required" path was
	# unreachable. Blocking the package is how a Qt-less box looks to Python.
	my $fallback = qx{python3 -c "import sys; sys.path.insert(0, '$root/desktop'); sys.modules['PySide6'] = None; import jawnos_desktop.browser as b; print('ok', b._QT_OK)" 2>&1};
	like($fallback, qr/^ok False$/m, 'the module imports with no Qt at all') or diag($fallback);
}

SKIP: {
	skip 'python3 is not installed', 20 unless $python;

	my $dir = tempdir(CLEANUP => 1);
	my $py = "$dir/probe.py";
	write_file($py, <<'PY');
import os
import sys
import tempfile

sys.path.insert(0, sys.argv[1] + '/desktop')
from jawnos_desktop import browser

path = os.path.join(tempfile.mkdtemp(), 'adblock.json')
store = browser.AdBlockStore(path)
print('enabled:' + str(store.enabled))
print('valid:' + browser._valid_selector('div.ad-slot:nth-of-type(2)'))
print('bad:' + repr(browser._valid_selector('div}body')))
print('badcomma:' + repr(browser._valid_selector('div,body')))

uri = 'https://www.tubitv.com/watch/abc'
print('add:' + str(len(store.add(uri, 'div.ad-slot') or [])))
print('add2:' + str(len(store.add(uri, "iframe[src*='doubleclick.net']") or [])))
print('key:' + browser.registrable_domain(uri) + ':' +
      str(len(store.site_selectors('https://tubitv.com/other'))))

reloaded = browser.AdBlockStore(path)
print('reload:' + str(len(reloaded.site_selectors(uri))))
print('remove:' + str(len(reloaded.remove(uri, 'div.ad-slot'))))
print('clear:' + str(len(reloaded.clear(uri))))
reloaded.set_enabled(False)
print('disabled:' + str(browser.AdBlockStore(path).enabled))

print('host1:' + str(browser.is_ad_host('doubleclick.net')))
print('host2:' + str(browser.is_ad_host('securepubads.g.doubleclick.net')))
print('host3:' + str(browser.is_ad_host('example.com')))
print('host4:' + str(browser.is_ad_host('doubleclick.net.example.com')))
print('host5:' + str(browser.is_ad_host('ads.tubi.io')))
print('host6:' + str(browser.is_ad_host('notads.tubi.io')))
print('empty:' + str(browser.is_ad_host('')))
print('upper:' + str(browser.is_ad_host('SECUREPUBADS.G.DOUBLECLICK.NET')))
PY

	my $out = qx{python3 "$py" "$root" 2>&1};
	like($out, qr/^enabled:True$/m, 'blocking starts on');
	like($out, qr/^valid:div\.ad-slot:nth-of-type\(2\)$/m,
		'a selector survives validation');
	like($out, qr/^bad:''$/m, 'a brace cannot escape the sheet');
	like($out, qr/^badcomma:''$/m, 'a selector list is refused');
	like($out, qr/^add:1$/m, 'the first pick is stored');
	like($out, qr/^add2:2$/m, 'a second pick adds to the same site');
	like($out, qr/^key:tubitv\.com:2$/m,
		'www and the bare domain share one entry');
	like($out, qr/^reload:2$/m, 'the list survives a restart');
	like($out, qr/^remove:1$/m, 'one entry can be removed');
	like($out, qr/^clear:0$/m, 'and the site can be cleared');
	like($out, qr/^disabled:False$/m, 'the global switch persists');
	like($out, qr/^host1:True$/m, 'the ad root matches');
	like($out, qr/^host2:True$/m, 'an ad subdomain matches');
	like($out, qr/^host3:False$/m, 'an ordinary host does not');
	like($out, qr/^host4:False$/m, 'a look-alike suffix is not an ad host');
	like($out, qr/^host5:True$/m, 'a host whose name starts with ads matches');
	like($out, qr/^host6:False$/m, 'but not one that merely contains "ads"');
	like($out, qr/^empty:False$/m, 'an empty host is never an ad host');
	like($out, qr/^upper:True$/m, 'and the match is case-insensitive');
}

done_testing();
