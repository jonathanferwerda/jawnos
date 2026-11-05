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

# The browser blocks a curated baseline of ad hosts (a declarative
# WebKit2.UserContentFilter) and hides an element the person taps in bug mode.
# The tapped selector is keyed by the view's own registrable domain and kept in
# adblock.json. A page's fullscreen request must also take the title bar, tab
# strip and status line off screen.

my $root = repo_root();
my $src = read_file("$root/desktop/jawnos_desktop/browser.py");

like($src, qr/class AdBlockStore/,
	'the block list has its own store');
like($src, qr/"doubleclick\.net"/,
	'the baseline names the display-ad hosts');
like($src, qr/def adblock_rules\(/,
	'the baseline is built as declarative rules');
like($src, qr/"if-domain"/,
	'a site\'s own picks are scoped in the declarative filter too');
like($src, qr/UserContentFilterStore/,
	'and attached with a WebKit content filter');
like($src, qr/register_script_message_handler_in_world\(\s*"jawnos_adblock",\s*ADBLOCK_WORLD\)/,
	'the picker bridge lives in its own isolated world');
like($src, qr/set_action_widget\(\s*tab_actions/,
	'the bug controls sit in the tab row');
like($src, qr/def _set_fullscreen_chrome\(/,
	'a page fullscreen drives the window chrome');
like($src, qr/self\.notebook\.set_show_tabs\(False\)/,
	'and takes the tab strip off screen');
like($src, qr/self\.set_titlebar\(None\)/,
	'and the title bar with it');
like($src, qr/ADBLOCK_FILE = "adblock\.json"/,
	'the person\'s list has a stable file name');
like($src, qr/Key on the view's own URI/,
	'the write is keyed on the view, not on the page\'s claimed URL');

my $python = qx{python3 --version 2>/dev/null};
SKIP: {
	skip 'python3 is not installed', 18 unless $python;

	my $dir = tempdir(CLEANUP => 1);
	my $py = "$dir/probe.py";
	write_file($py, <<'PY');
import os
import re
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

rules = browser.adblock_rules()
rule = next(r for r in rules
            if 'doubleclick\\.net' in r['trigger']['url-filter'])
pattern = rule['trigger']['url-filter']
print('block:' + rule['action']['type'])
print('hostmatch:' + str(bool(re.search(
    pattern, 'https://securepubads.g.doubleclick.net/tag/js/gpt.js'))))
print('hostnomatch:' + str(bool(re.search(
    pattern, 'https://example.com/page'))))
print('suffixnomatch:' + str(bool(re.search(
    pattern, 'https://doubleclick.net.example.com/page'))))
print('cosmetic:' + str(any(
    rule['action']['type'] == 'css-display-none' for rule in rules)))
site_rules = browser.adblock_rules({'tubitv.com': ['.ad-slot']})
site_rule = next(rule for rule in site_rules
                 if 'if-domain' in rule['trigger'])
print('sitefilter:' + site_rule['trigger']['if-domain'][0] + ':' +
      site_rule['action']['selector'])
ip_rules = browser.adblock_rules({'127.0.0.1': ['.x']})
print('ipfilter:' + str(any(
    'if-domain' in rule['trigger'] for rule in ip_rules)))
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
	like($out, qr/^block:block$/m, 'the baseline has a blocking rule');
	like($out, qr/^hostmatch:True$/m, 'an ad subdomain matches the filter');
	like($out, qr/^hostnomatch:False$/m, 'an ordinary page does not');
	like($out, qr/^suffixnomatch:False$/m,
		'a look-alike suffix is not an ad host');
	like($out, qr/^cosmetic:True$/m, 'and the baseline hides containers too');
	like($out, qr/^sitefilter:tubitv\.com:\.ad-slot$/m,
		'a picked selector is scoped to its site');
	like($out, qr/^ipfilter:False$/m,
		'an IP site stays out of the domain-scoped rules');
}

done_testing();
