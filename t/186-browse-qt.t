# tests-for: desktop/jawnos_desktop/browser.py desktop/jawnos_desktop/errorpage.py desktop/jawnos-browse
# covers:    Browse is Qt WebEngine (no GTK): a named on-disk profile of its
#            own, the house certificate and capture permissions, the page
#            bridge and media keep-awake, the ad-block picker in an isolated
#            world, tabs/popups, downloads, find, history and the address
#            bar; plus a real offscreen construction and bridge round trip.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use RepoSource;

my $root = repo_root();
my $src = read_file("$root/desktop/jawnos_desktop/browser.py");
my $launcher = read_file("$root/desktop/jawnos-browse");

# ---- the engine and the profile ------------------------------------------

like($src, qr/from PySide6\.QtWebEngineWidgets import QWebEngineView/,
	'the window is Qt WebEngine');
like($src, qr/errorpage\.dark_page/,
	'and a failed load shows the shared dark error page');
like($src, qr/from PySide6\.QtWebEngineCore import \(\s*\n\s*QWebEngineDownloadRequest,/,
	'and uses the WebEngine core types');
like($src, qr/PROFILE_NAME = "jawnos-browse"/,
	'the profile has a name of its own');
like($src, qr/QWebEngineProfile\(PROFILE_NAME, self\)/,
	'and is constructed by that name');
like($src, qr/def profile_store_dir\(\):\n(?:.*\n)*?    return os\.path\.join\(core\.config_dir\(\), PROFILE_DIR_NAME\)/,
	'the store is under the house config directory');
like($src, qr/PROFILE_DIR_NAME = "browse-webengine"/,
	'with a fixed directory beside the manager profile');
like($src, qr/ForcePersistentCookies/,
	'so cookies survive a restart');
like($src, qr/setPersistentStoragePath\(os\.path\.join\(store, "storage"\)\)/,
	'storage is the profile\'s own');
unlike($src, qr/QWebEngineProfile\("jawnos"/,
	'never the manager view\'s profile');

# ---- no GTK in the code path ---------------------------------------------

unlike($src, qr/import\s+gi\b|gi\.repository|from gi\.repository/,
	'no PyGObject import remains');
unlike($src, qr/WebKit2\.|Gtk\.|Gdk\.|Gio\.|GLib\.|from gi\.repository/,
	'and no WebKitGTK or GTK API symbol is left');
unlike($src, qr/from \. import webview|import webview/,
	'Browse no longer imports the WebKitGTK fallback');

# ---- the shared helpers, imported not edited ------------------------------

like($src, qr/from \.qt_shell import _accept_certificate, black_page, prepare_wayland_env/,
	'the certificate rule and black page are shared with qt_shell');
like($src, qr/self\.certificateError\.connect\(_accept_certificate\)/,
	'every page accepts the house self-signed certificate');
like($src, qr/black_page\(self\.page, self\.view\)/,
	'and the empty page is painted black');
like($src, qr/def grant_media_permissions\(page\):/,
	'capture permissions are granted');
like($src, qr/"MediaAudioCapture", "MediaVideoCapture",/,
	'microphone and camera named explicitly');
like($src, qr/permission\.grant\(\)/,
	'through the Qt 6.8 permission object');
like($src, qr/featurePermissionRequested/,
	'with the older feature request path kept');

# ---- the bridge, media and keep-awake ------------------------------------

like($src, qr/bridge\.BROWSE_BRIDGE_JS/,
	'the Browse shim is installed');
like($src, qr/bridge\.MEDIA_MONITOR_JS/,
	'and the page media monitor');
like($src, qr/keepawake\.ScreensaverInhibitor\(\)/,
	'media holds the screen awake');
like($src, qr/def on_media_message\(self, raw, tab\):/,
	'the media message is handled locally');
like($src, qr/def on_browse_message\(self, raw\):/,
	'JawnBrowse.open opens a tab in this window');
unlike($src, qr/app_public_pem|app_sign_b64/,
	'the app-key and manager-window actions are absent');

# ---- isolated ad-block picker --------------------------------------------

like($src, qr/ScriptWorldId\.UserWorld/,
	'the picker runs in an isolated script world');
like($src, qr/__jawnos_adblock_message/,
	'and reaches the bridge over a DOM event');
like($src, qr/class _AdInterceptor\(_InterceptorBase\)/,
	'the baseline is enforced by a request interceptor');
like($src, qr/def is_ad_host\(host\):/,
	'subdomain matching is a checked helper');
like($src, qr/info\.block\(True\)/,
	'a baseline ad request is blocked');

# ---- the features the GTK window had -------------------------------------

like($src, qr/def createWindow\(self, _window_type\):/,
	'popups and target=_blank become tabs');
like($src, qr/profile\.downloadRequested\.connect\(self\.on_download_requested\)/,
	'downloads are prompted for and saved');
like($src, qr/tab\.page\.findText\(/, 'find-in-page uses the engine');
like($src, qr/class History:/, 'the local history is kept');
like($src, qr/class SiteUsage:/, 'and site time is still accounted');
like($src, qr/self\.tabs = QTabWidget\(\)/, 'the window has tabs');
like($src, qr/setCornerWidget\(tab_actions, Qt\.Corner\.TopRightCorner\)/,
	'the bug controls sit at the end of the tab row');
like($src, qr/def _set_fullscreen_chrome\(self, on\):/,
	'a page fullscreen takes the window chrome off');
like($src, qr/self\.tabs\.tabBar\(\)\.setVisible\(False\)/,
	'including the tab strip');
like($src, qr/self\.toolbar\.setVisible\(False\)/,
	'and the tool bar');
like($src, qr/\("Ctrl\+L", self\.focus_address\)/,
	'Ctrl+L focuses the address bar');
like($src, qr/\("Ctrl\+T", lambda: self\.new_tab\(\)\)/,
	'Ctrl+T opens a tab');
like($src, qr/\("Alt\+Left", self\.go_back\)/,
	'Alt+Left goes back');
like($src, qr/SEARCH_PREFIX = "https:\/\/duckduckgo\.com\/\?q="/,
	'a phrase is searched');
like($src, qr/gpu\.prepare_env\(\)/,
	'the Chromium GPU flags are applied before the QApplication');
like($src, qr/prepare_wayland_env\(\)/,
	'and the Wayland hint when the session needs it');

like($launcher, qr/from jawnos_desktop\.browser import main/,
	'the same launcher entry still starts Browse');

# ---- pure helpers, on the machine's python -------------------------------

my $python = qx{python3 --version 2>/dev/null};
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

print('search:' + str(browser.address_url('how do magnets work')))
print('addr:' + str(browser.address_url('example.com')))
print('ftp:' + repr(browser.normalise_url('ftp://example.com/x')))
print('searchftp:' + repr(browser.search_url('ftp://example.com/x')))
print('private:' + str(browser.blocked_host('http://127.0.0.1:3000/')))
print('public:' + str(browser.blocked_host('https://example.com/')))
print('domain:' + browser.registrable_domain('https://www.tubitv.com/x'))
print('adsub:' + str(browser.is_ad_host('securepubads.g.doubleclick.net')))
print('adroot:' + str(browser.is_ad_host('doubleclick.net')))
print('adlook:' + str(browser.is_ad_host('doubleclick.net.example.com')))
print('adplain:' + str(browser.is_ad_host('example.com')))

path = os.path.join(tempfile.mkdtemp(), 'adblock.json')
store = browser.AdBlockStore(path)
print('enabled:' + str(store.enabled))
print('valid:' + browser._valid_selector('div.ad-slot:nth-of-type(2)'))
print('bad:' + repr(browser._valid_selector('div}body')))
uri = 'https://www.tubitv.com/watch/abc'
print('add:' + str(len(store.add(uri, 'div.ad-slot') or [])))
print('add2:' + str(len(store.add(uri, "iframe[src*='doubleclick.net']") or [])))
print('key:' + browser.registrable_domain(uri) + ':' +
      str(len(store.site_selectors('https://tubitv.com/other'))))
reloaded = browser.AdBlockStore(path)
print('reload:' + str(len(reloaded.site_selectors(uri))))
print('remove:' + str(len(reloaded.remove(uri, 'div.ad-slot'))))
print('clear:' + str(len(reloaded.clear(uri))))
PY

	my $out = qx{python3 "$py" "$root" 2>&1};
	like($out, qr/^search:https:\/\/duckduckgo\.com\/\?q=how\+do\+magnets\+work$/m,
		'a phrase becomes a search');
	like($out, qr/^addr:https:\/\/example\.com$/m,
		'a bare host becomes https');
	like($out, qr/^ftp:None$/m, 'a non-http scheme is not an address');
	like($out, qr/^searchftp:None$/m,
		'and is not searched either');
	like($out, qr/^private:True$/m, 'loopback is private');
	like($out, qr/^public:False$/m, 'a public host is not');
	like($out, qr/^domain:tubitv\.com$/m, 'the usage key is eTLD+1');
	like($out, qr/^adsub:True$/m, 'an ad subdomain matches');
	like($out, qr/^adroot:True$/m, 'the ad root matches');
	like($out, qr/^adlook:False$/m, 'a look-alike suffix does not');
	like($out, qr/^adplain:False$/m, 'an ordinary host does not');
	like($out, qr/^enabled:True$/m, 'blocking starts on');
	like($out, qr/^valid:div\.ad-slot:nth-of-type\(2\)$/m,
		'a selector survives validation');
	like($out, qr/^bad:''$/m, 'a brace cannot escape the sheet');
	like($out, qr/^add:1$/m, 'the first pick is stored');
	like($out, qr/^add2:2$/m, 'a second pick adds to the same site');
	like($out, qr/^key:tubitv\.com:2$/m,
		'www and the bare domain share one entry');
	like($out, qr/^reload:2$/m, 'the list survives a restart');
	like($out, qr/^remove:1$/m, 'one entry can be removed');
	like($out, qr/^clear:0$/m, 'and the site can be cleared');
}

# ---- a real, offscreen window --------------------------------------------

my $xvfb = $python && qx{command -v xvfb-run 2>/dev/null};
my $have_qt = 0;
if ($python) {
	$have_qt = system('python3', '-c',
		'import PySide6.QtWebEngineWidgets') == 0 ? 1 : 0;
}

SKIP: {
	skip 'xvfb-run is not installed', 2 unless $xvfb;
	skip 'PySide6 with Qt WebEngine is not installed', 2 unless $have_qt;

	my $dir = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	mkdir $home;
	my @cmd = ('xvfb-run', '-a', 'python3', "$root/desktop/jawnos-browse",
		'--check');
	my $out = qx{cd "$root" && HOME="$home" XDG_CONFIG_HOME="$home/.config" \
		XDG_CACHE_HOME="$home/.cache" XDG_DATA_HOME="$home/.local/share" \
		QTWEBENGINE_CHROMIUM_FLAGS='--disable-gpu --no-sandbox' \
		timeout 40 @cmd 2>&1};
	like($out, qr/jawnos-browse: window constructed/,
		'the Qt window constructs offscreen');
	ok(-d "$home/.config/jawnos/browse-webengine/storage",
		'under its own named profile directory');
}

# ---- a loaded page: bridge, ad blocker, media, popup ---------------------

SKIP: {
	skip 'xvfb-run is not installed', 7 unless $xvfb;
	skip 'PySide6 with Qt WebEngine is not installed', 7 unless $have_qt;

	my $dir = tempdir(CLEANUP => 1);
	my $home = "$dir/home";
	mkdir $home;
	my $py = "$dir/roundtrip.py";
	write_file($py, <<'PY');
import http.server
import json
import os
import sys
import tempfile
import threading

home = sys.argv[2]
os.environ['HOME'] = home
os.environ['XDG_CONFIG_HOME'] = home + '/.config'
os.environ['XDG_CACHE_HOME'] = home + '/.cache'
os.environ['XDG_DATA_HOME'] = home + '/.local/share'
os.environ['JAWNOS_BROWSE_ALLOW_PRIVATE'] = '1'
os.environ['QTWEBENGINE_CHROMIUM_FLAGS'] = '--disable-gpu --no-sandbox'
sys.path.insert(0, sys.argv[1] + '/desktop')
from jawnos_desktop import browser
from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/two':
            body = b'<html><head><title>Two</title></head><body>two</body></html>'
        else:
            body = (b'<html><head><title>Probe Page</title></head><body>'
                    b'<ins class="adsbygoogle adbox">ad</ins>'
                    b'<a id="blank" href="/two" target="_blank">two</a>'
                    b'</body></html>')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
port = server.server_port
threading.Thread(target=server.serve_forever, daemon=True).start()
app = QApplication([])
window = browser.BrowserWindow(browser._parser().parse_args(
    ['--url', 'http://127.0.0.1:%d/' % port]))
window.show()
out = {}


def check():
    tab = window.current_tab()
    page = tab.page

    def got_world(value):
        out['adblock_object'] = 'object' in (value or '')
        page.runJavaScript(
            "document.getElementById('__jawnos_adblock_style') ?"
            " document.getElementById('__jawnos_adblock_style').textContent.length"
            " : -1", after_style)

    def after_style(length):
        out['cosmetic'] = bool(length and length > 0)
        page.runJavaScript(
            "window.webkit.messageHandlers.jawnos.postMessage("
            "JSON.stringify({action:'media_state',audio:true,video:false}));")
        window.bug_button.setChecked(True)
        page.runJavaScript(
            "window.webkit.messageHandlers.jawnos_adblock.postMessage("
            "JSON.stringify({action:'block',selector:'.adbox'}));", 2)
        page.runJavaScript(
            "document.getElementById('blank').click()")
        QTimer.singleShot(1600, finish)

    page.runJavaScript(
        "JSON.stringify({a: typeof window.__jawnosAdblock})", 2, got_world)


def finish():
    out['media'] = any(window._media.values())
    out['blocked'] = window.adblock.site_selectors(
        'http://127.0.0.1:%d/' % port)
    out['tabs'] = window.tabs.count()
    out['title'] = window.current_tab().page.title()
    out['profile'] = os.path.isdir(
        home + '/.config/jawnos/browse-webengine/storage')
    print('RESULT ' + json.dumps(out))
    window.close()
    app.quit()


QTimer.singleShot(3000, check)
QTimer.singleShot(12000, app.quit)
app.exec()
PY
	my $out = qx{HOME="$home" timeout 40 xvfb-run -a python3 "$py" "$root" "$home" 2>&1};
	like($out, qr/"adblock_object": true/,
		'the isolated ad-block object reaches the page world');
	like($out, qr/"cosmetic": true/,
		'and its cosmetic sheet is installed');
	like($out, qr/"media": true/, 'the media monitor reaches Python');
	like($out, qr/"blocked": \["\.adbox"\]/,
		'a bug-mode pick is stored for the site');
	like($out, qr/"tabs": 2/, 'target=_blank opened a tab');
	like($out, qr/"title": "Two"/, 'and the popup loaded there');
	like($out, qr/"profile": true/,
		'the profile lives under the house config directory');
}

done_testing();
