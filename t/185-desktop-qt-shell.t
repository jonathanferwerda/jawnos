# tests-for: desktop/jawnos_desktop/qt_shell.py desktop/jawnos_desktop/browser.py desktop/jawnos_desktop/ble.py desktop/jawnos_desktop/gps.py desktop/jawnos_desktop/qt_panel.py desktop/jawnos_desktop/bridge.py desktop/jawnos_desktop/keepawake.py desktop/jawnos_desktop/gpu.py desktop/jawnos_desktop/theme.py desktop/jawnos_desktop/errorpage.py desktop/jawnos_desktop/core.py desktop/jawnos_desktop/webauthn.py desktop/jawnos-desktop desktop/jawnos-qt desktop/wayland/jawnos-session desktop/install.sh scripts/jawnos_deps.pl
# covers:    the Qt WebEngine desktop shell is the only engine: the same Manager
#           page in Chromium, which is the engine with WebRTC, the ticket cookie
#           kept on disk, microphone/camera grants, the house's own certificate
#           accepted, the page bridge, supervision, the control panel's look and
#           tray, the GPU flags that keep the embedded card in use, and a video's
#           fullscreen. The GTK dashboard and WebKitGTK view are deleted, not just
#           unreachable.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);

my $root = "$FindBin::Bin/..";
my $qt = read_file("$root/desktop/jawnos_desktop/qt_shell.py");
my $browse = read_file("$root/desktop/jawnos_desktop/browser.py");
my $ble = read_file("$root/desktop/jawnos_desktop/ble.py");
my $panel = read_file("$root/desktop/jawnos_desktop/qt_panel.py");
my $keepawake = read_file("$root/desktop/jawnos_desktop/keepawake.py");
my $bridge = read_file("$root/desktop/jawnos_desktop/bridge.py");
my $gpu = read_file("$root/desktop/jawnos_desktop/gpu.py");
my $theme = read_file("$root/desktop/jawnos_desktop/theme.py");
my $errpage = read_file("$root/desktop/jawnos_desktop/errorpage.py");
my $core = read_file("$root/desktop/jawnos_desktop/core.py");
my $core_process = read_file("$root/desktop/jawnos_desktop/core_process.py");
my $webauthn = read_file("$root/desktop/jawnos_desktop/webauthn.py");
my $package = read_file("$root/desktop/jawnos_desktop/__init__.py");
my $entry = read_file("$root/desktop/jawnos-desktop");
my $install = read_file("$root/desktop/install.sh");
my $deps = read_file("$root/scripts/jawnos_deps.pl");
my $session = read_file("$root/desktop/wayland/jawnos-session");
my $launcher = "$root/desktop/jawnos-qt";

like($qt, qr/from PySide6\.QtWebEngineWidgets import QWebEngineView/,
	'the shell is Qt WebEngine');
like($qt, qr/QWebEngineProfile\("jawnos"/, 'a named, on-disk profile');
like($qt, qr/ForcePersistentCookies/, 'so the login cookie survives a restart');
like($qt, qr/MediaAudioCapture/, 'the microphone permission is granted');
like($qt, qr/MediaAudioVideoCapture/, 'and the camera/audio pair');
like($qt, qr/certificateError/, 'the house self-signed certificate is accepted');
like($qt, qr/typeof RTCPeerConnection/, 'the probe asks the engine for WebRTC');
like($qt, qr/createOffer\(\)/, 'and proves it with a real offer');
like($qt, qr/UNMASKED_RENDERER_WEBGL/,
	'and reports which renderer paints (software, or the Intel card)');
like($qt, qr/--probe/, 'the probe is a command-line mode');
like($qt, qr/def ticket_url/, 'it reads the same stored ticket as always');
like($qt, qr/def _probe_url/, 'the probe uses a real origin for the bridge');
like($qt, qr/def manager_url/, 'and derives the manager URL from it');

like($entry, qr/JAWNOS_DESKTOP_ENGINE/, 'the engine can still be chosen by environment');
like($entry, qr/--engine/, 'and by flag');
like($entry, qr/name in \("", "auto", "default", "qt"\)/,
	'auto and qt both mean Qt WebEngine');
like($entry, qr/from jawnos_desktop\.qt_shell import main/, 'Qt is the only branch');
like($entry, qr/import PySide6\.QtWebEngineWidgets/,
	'PySide6 with Qt WebEngine is probed before launch');
ok(-x $launcher, 'jawnos-qt is directly runnable');

# The GTK/WebKitGTK path is gone, not merely unreachable.
ok(!-e "$root/desktop/jawnos_desktop/ui.py", 'the GTK dashboard is deleted');
ok(!-e "$root/desktop/jawnos_desktop/webview.py", 'the WebKitGTK view is deleted');
unlike($entry, qr/^\s*(?:from|import)\s+gi\b/m, 'the entry does not import PyGObject');
unlike($entry, qr/jawnos_desktop\.(?:ui|webview)|from gi[.]repository|Web[K]it2/,
	'and names no GTK/WebKit module');
unlike($install, qr/web[K]it2gtk|gir1[.]2-web[K]it2|gst-inspect|gstreamer1\.0/i,
	'the installer no longer checks for WebKitGTK or GStreamer packages');
like($install, qr/requires PySide6 with Qt WebEngine/,
	'it says the Qt WebEngine view is required');
unlike($deps, qr/web[K]it2gtk|have_webkit|gst-inspect|gst-plugin-va/,
	'the dependency checker no longer offers WebKitGTK or GStreamer');
like($package, qr/setdefault\("QT_QPA_PLATFORMTHEME", "generic"\)/,
	'Qt is kept off its GTK platform theme, which would map libgtk-3');

# On a desktop that normally selects Qt's GTK theme (XFCE here), importing the
# package must leave no GTK library in the process.
my $gtk = `cd "$root" && XDG_CURRENT_DESKTOP=XFCE QT_QPA_PLATFORM=offscreen PYTHONPATH=desktop python3 -c 'import jawnos_desktop; from PySide6.QtWidgets import QApplication; app = QApplication([]); print("gtk-mapped", "libgtk" in open("/proc/self/maps").read())' 2>&1`;
SKIP: {
	skip 'PySide6 is not installed here', 1
		if $gtk =~ /No module named .PySide6|ModuleNotFoundError/;
	like($gtk, qr/^gtk-mapped False$/m, 'no libgtk is mapped under a GTK desktop');
}

# The engine resolver, without starting a GUI. Auto and qt are deterministic;
# an explicit webkit request fails with a message that names the removal.
my $choose = `cd "$root" && python3 -c 'import runpy; m=runpy.run_path("desktop/jawnos-desktop"); print(m["choose_engine"]("auto"), m["choose_engine"]("qt"))' 2>&1`;
like($choose, qr/^qt qt$/m, 'the resolver returns Qt for auto and qt');
my $webkit = `cd "$root" && python3 -c 'import runpy; m=runpy.run_path("desktop/jawnos-desktop"); print(m["choose_engine"]("webkit"))' 2>&1`;
like($webkit, qr/WebKitGTK engine has been removed/,
	'and refuses webkit with a clear message');

# The page bridge: the shim the Qt shell installs gives the page the same
# handlers WebKitGTK registers, and the shared module holds the key and scripts.
like($qt, qr/__jawnQtBridge/, 'the page is given a Qt bridge object');
like($qt, qr/QWebChannel/, 'over QWebChannel');
like($qt, qr/messageHandlers\[name\]/, 'and the WebKit handler names the page checks');
like($qt, qr/window\.JawnDesktop/, 'the desktop marker universal.js keys app login off');
like($qt, qr/def handle_message\([^)]*allowed_host/,
	'the handler receives the window\'s manager host');
like($qt, qr/def _qurl_host/, 'and reads a QUrl host with the right API');
unlike($qt, qr/\.url\(\)\.hostname\(\)/, 'not the urlparse spelling');
like($qt, qr/handle_message\(name, raw, page_obj, view_obj, allowed_host,\s*\n?\s*manager_base\)/,
	'and the bridge passes the window\'s manager base through');
like($qt, qr/bridge\.app_public_pem|bridge\.app_sign_b64/,
	'the app key is answered through the shared bridge');
like($bridge, qr/def app_public_pem/, 'the app key lives in the toolkit-neutral module');
like($bridge, qr/def app_sign_b64/, 'with its signer');
like($bridge, qr/def browse_launcher/, 'and the Browse launcher');
like($bridge, qr/BROWSE_BRIDGE_JS/, 'the Browse shim');
like($bridge, qr/MEDIA_MONITOR_JS/, 'and the media monitor the keep-awake uses');

# The two capabilities WebKitGTK gave a page by default and Qt does not:
# downloads (Qt cancels one nothing accepts) and window.open/target=_blank
# (Qt drops one whose page returns no window). A same-origin Manager URL keeps
# the session cookie; everything else goes to Browse or the desktop.
like($qt, qr/class JawnPage\(QWebEnginePage\)/, 'the pages are a page subclass');
like($qt, qr/downloadRequested/, 'a download is accepted, not cancelled');
like($qt, qr/setDownloadDirectory/, 'with the save location the person picks');
like($qt, qr/setDownloadFileName/, 'and the file name they chose');
like($qt, qr/item\.accept\(\)/, 'then handed to the engine');
like($qt, qr/note\("Downloaded"/, 'the end is reported through the tray');
like($qt, qr/def createWindow/, 'a popup gets a page instead of a silent drop');
like($qt, qr/newWindowRequested/, 'Qt 6.2+ hands over the requested URL');
like($qt, qr/def acceptNavigationRequest/, 'and a non-http navigation is caught');
like($qt, qr/QDesktopServices\.openUrl/, 'a desktop scheme goes to the OS');
like($qt, qr/def open_external/, 'through one allowlisted opener');
like($qt, qr/def classify_new_window/, 'the same-origin rule is a pure helper');
like($qt, qr/def _launch_browse/, 'an outside link starts Browse');
like($qt, qr/bridge\.browse_launcher\(\)/, 'through the shared launcher');
like($qt, qr/_launch_browse\(\n\s+url, manager_base,/, 'the bridge action uses it too');
like($qt, qr/"--mode", mode/, 'with the same argv as before');

# The classifier, without Qt: same-origin (loopback and a known house host) is
# the Manager, any other http(s) is Browse, a known scheme is the desktop, and
# file:, javascript:, about:blank, an empty request and a bare relative URL are
# refused (the engine resolves relative URLs before asking).
my $kinds = `cd "$root" && PYTHONPATH=desktop python3 -c '
from jawnos_desktop.qt_shell import classify_new_window as c
hosts = {"127.0.0.1", "house.test"}
for url in (
    "https://127.0.0.1:45545/manager/x",
    "https://HOUSE.test/manager/x",
    "https://example.com/a",
    "mailto:email_test",
    "file:///etc/passwd",
    "javascript:alert(1)",
    "/store/print/pdf",
    "about:blank",
    "",
):
    print(c(url, "127.0.0.1", hosts))
' 2>&1`;
like($kinds, qr/^manager\nmanager\nbrowse\nexternal\ndeny\ndeny\ndeny\ndeny\ndeny$/m,
	'a new window is placed by origin and scheme, never by a file: link');
like($qt, qr/EXTERNAL_SCHEMES = frozenset\(\{/, 'the delegated schemes are one named list');
like($qt, qr/LOOPBACK_HOSTS/, 'and loopback is named once');

like($qt, qr/def prepare_wayland_env/, 'a Wayland session sets the Qt platform');
like($qt, qr/--ozone-platform-hint=auto/,
	'Chromium gets the Ozone hint (the Wayland platform is not in every build)');
unlike($qt, qr/flags \+ " --ozone-platform=wayland"/,
	'and never the explicit platform Arch\'s QtWebEngine lacks');

# The embedded card stays in use: a GPU environment, then Chromium flags that
# keep rasterisation off the CPU (the GTK Skylake fallback was a WebKit bug and
# is deliberately not ported).
like($gpu, qr/--ignore-gpu-blocklist/, 'the GPU blocklist does not strand an older Intel card');
like($gpu, qr/--enable-gpu-rasterization/, 'raster work stays on the card');
like($gpu, qr/LIBVA_DRIVER_NAME.*iHD|iHD.*LIBVA_DRIVER_NAME/s,
	'hardware video decode gets the iHD driver');
like($gpu, qr/startswith\("WEBKIT_"\)/,
	'webkit.env\'s WebKit-only switches are not copied into Chromium');
like($gpu, qr/qt\.env/, 'qt.env is the Qt escape hatch');
like($gpu, qr/--disable-gpu/, 'and JAWNOS_GPU=0 can ask for software rendering');
like($qt, qr/gpu\.prepare_env\(\)/, 'the shell applies it');
my $gpu_at = index($qt, 'gpu.prepare_env()');
my $app_at = index($qt, 'app = QApplication');
ok($gpu_at >= 0 && $app_at > $gpu_at,
	'before QApplication, because Qt WebEngine reads it at init');

# The tray: no browser item, and a badge that carries jawn's state.
unlike($qt, qr/"Open in browser"/, 'the tray menu does not offer a browser');
like($qt, qr/def tray_icon/, 'the tray badge is painted with a state dot');
like($qt, qr/core\.jawn_status\(jawn_up\)/, 'and follows the shared status rule');
like($theme, qr/GREEN = \(0x34, 0xC7, 0x59\)/, 'the green is the dashboard\'s green');
like($theme, qr/AMBER = \(0xFF, 0xB0, 0x20\)/, 'the amber is the same amber');
like($theme, qr/RED = \(0xFF, 0x45, 0x3A\)/, 'and the red is the same red');

like($qt, qr/setDesktopFileName\("jawnos"\)/,
	'the Wayland app id is the desktop entry, not python3');
like($qt, qr/def black_page/, 'the empty engine is painted before the page loads');
like($qt, qr/page_obj\.setBackgroundColor\(black\)/,
	'with the page background, not a white default');
like($qt, qr/black_page\(page, view\)/, 'applied to the main view');
like($qt, qr/black_page\(page_obj, win\)/, 'and to each peer Manager window');
like($qt, qr/ErrorPageEnabled, False/, 'the built-in white error page is off');
# Fullscreen: Qt WebEngine leaves the Fullscreen API off until a page is told
# it is supported, and then drops a request the app does not accept. Browse
# enables it; the Manager view and every peer window must too, or a player's
# fullscreen button only fills its own box.
like($qt, qr/FullScreenSupportEnabled/, 'a page may ask to fill the screen');
like($qt, qr/def _allow_fullscreen/, 'the shell accepts the request itself');
like($qt, qr/request\.accept\(\)/, 'and Qt is told to honour it');
like($qt, qr/_allow_fullscreen\(page, view, qt, restore_window\)/,
	'the Manager view gets it, and restores the saved window state on exit');
like($qt, qr/_allow_fullscreen\(page_obj, win, qt\)/,
	'and so does each peer Manager window');
# Scrolling feel: Qt WebEngine leaves Chromium's scroll animator off, so the
# shell turns it on for the profile and every page inherits it. This is the port
# of the removed WebKitGTK view's enable-smooth-scrolling.
like($qt, qr/ScrollAnimatorEnabled, True/,
	'scroll animation is on, so a wheel scroll glides instead of stepping');
like($qt, qr/profile\.settings\(\)\.setAttribute\b/,
	'set on the profile, so the Manager and peer windows share it');
# The animator stops when the deltas stop, and the laptop's touchpad driver
# (libinput) has no coasting, so a flick would end with the fingers. The shell
# carries the burst's velocity and keeps the container moving. The wardrobe
# canvases already glide, so they are explicitly left alone.
like($qt, qr/_MOMENTUM_JS/, 'a momentum shim is injected into the Manager');
like($qt, qr/if momentum_enabled\(\):/, 'only when it is wanted');
like($qt, qr/closest\('\.background'\)/,
	'the wardrobe canvases keep their own glide');
like($qt, qr/e\.defaultPrevented/, 'and a wheel the app handled is left alone');
like($qt, qr/requestAnimationFrame\(step\)/, 'the coast decays frame by frame');
my $moff = `cd "$root" && JAWNOS_MOMENTUM=0 PYTHONPATH=desktop python3 -c 'from jawnos_desktop.qt_shell import momentum_enabled; print(momentum_enabled())' 2>&1`;
like($moff, qr/^False$/m, 'JAWNOS_MOMENTUM=0 turns coasting off');
like($qt, qr/errorpage\.dark_page/, 'the manager shows a dark page after its retries');
like($qt, qr/LOAD_TIMEOUT_MS = 20000/, 'a navigation that never finishes has its own deadline');
like($qt, qr/page\.loadStarted\.connect\(lambda: nav_guard\.start\(LOAD_TIMEOUT_MS\)\)/,
	'the deadline is armed by every navigation');
like($qt, qr/view\.stop\(\)/, 'a stalled navigation is stopped, not left running');
like($qt, qr/this page retries by itself/, 'and the dark page says it retries by itself');
like($qt, qr/errorpage\.watch\(page_obj\)/, 'and peer windows show one at once');
like($errpage, qr/background:#000000/, 'the error page is on the black ground');
like($errpage, qr/#ffcc00/, 'with the jawn yellow for the retry');
like($qt, qr/QSystemTrayIcon/, 'the shell keeps a tray');
like($qt, qr/class Supervisor/, 'and supervises jawn');
like($qt, qr/auto_update_available/, 'including the desktop self-update');
like($qt, qr/version_mismatch/, 'and the version restart');
like($qt, qr/core\.jawn_health\(jawn_dir, timeout=3\.0\)/,
	'the supervisor asks the health route, not just the port');
like($qt, qr/restarted a manager that stopped answering/,
	'and restarts a manager whose HTTP stopped answering');
like($qt, qr/core\.game_running\(\)/, 'a game in progress is not read as a wedged manager');
like($qt, qr/permissionRequested/, 'the newer permission signal is handled');
like($qt, qr/PermissionType/, 'through QWebEnginePermission');
like($qt, qr/featurePermissionRequested/, 'with the older signal kept as a fallback');

# Permissions: Qt WebEngine starts from deny-everything, and the WebKitGTK
# view this shell replaced granted the house's features only to the house's
# own origins. The Qt handler keeps both the grant list and the origin check,
# so a public page loaded in the Manager view inherits nothing.
like($qt, qr/_HOUSE_PERMISSIONS = \(/, 'the granted features are one named list');
like($qt, qr/"MediaAudioCapture"/, 'the microphone is in it');
like($qt, qr/"DesktopVideoCapture"/, 'screen sharing is granted');
like($qt, qr/"DesktopAudioVideoCapture"/, 'including a screen with its audio');
like($qt, qr/"MouseLock"/, 'pointer lock is granted to the remote control');
like($qt, qr/"ClipboardReadWrite"/, 'and clipboard reads and writes');
like($qt, qr/"Notifications"/, 'and chat notifications');
like($qt, qr/def _feature_permission\(page, qt, allowed_hosts, gps_on=False\)/,
	'the handler is given the origin allowlist and the GPS decision');
like($qt, qr/_permission_host\(\s*permission\.origin\(\)\)\s+in allowed_hosts/,
	'a grant checks the request origin on the modern path');
like($qt, qr/_permission_host\(origin\) in allowed_hosts/,
	'and on the featurePermissionRequested path');
like($qt, qr/permission\.deny\(\)/, 'anything else is denied');
like($qt, qr/allowed_hosts = set\(LOOPBACK_HOSTS\)/,
	'the allowlist starts with loopback');
like($qt, qr/allowed_hosts\.add\(host\.lower\(\)\)/, 'the Manager host joins it');
like($qt, qr/allowed_hosts\.add\(peer_host\)/, 'and so does each peer window host');
like($qt, qr/_allow_screen_capture\(page, qt, allowed_hosts\)/,
	'the Manager page can share its screen');
like($qt, qr/_allow_screen_capture\(page_obj, qt, allowed_hosts\)/,
	'and so can a peer window');
like($qt, qr/ScreenCaptureEnabled, True/, 'Qt leaves screen capture off until asked');
like($qt, qr/desktopMediaRequested\.connect\(handle\)/, 'then hands over the request');
like($qt, qr/request\.selectScreen/, 'the shell picks a screen from the request');
like($qt, qr/request\.cancel\(\)/, 'and cancels one from an origin outside the house');
like($qt, qr/JavascriptCanAccessClipboard,\s+True/,
	'the clipboard attribute is switched on');
like($qt, qr/def _install_notifications/, 'a notification presenter is installed');
like($qt, qr/setNotificationPresenter\(presenter\)/, 'Qt has no default one');
like($qt, qr/showMessage\(title, body/, 'notifications surface through the tray');
like($qt, qr/_install_notifications\(profile, qt, allowed_hosts, tray_holder\)/,
	'installed on the shared profile in main');
like($qt, qr/gps\.has_gps\(settings\.get\("jawn_dir"\)\)/,
	'the GPS receiver decides whether location is offered');
like($qt, qr/names\.append\(_GPS_PERMISSION\)/,
	'and only then is Geolocation granted');

# Passkeys: Qt WebEngine renders no WebAuthn UX itself. A page's
# navigator.credentials call waits until the embedder draws one, so the Manager
# view and every peer window connect the signal. The wording is a pure mapping,
# checked without a display; the dialog follows Qt's state changes in place.
like($qt, qr/webauthn\.install_webauthn\(page, view\)/,
	'the Manager page answers passkey requests');
like($qt, qr/webauthn\.install_webauthn\(page_obj, win\)/,
	'and so does each peer Manager window');
like($webauthn, qr/webAuthUxRequested/,
	'the Qt 6.8+ signal is the entry point');
like($webauthn, qr/def install_webauthn\(page, window\)/,
	'through one small installer');
like($webauthn, qr/stateChanged/,
	'a request is followed across its states, not assumed');
like($webauthn, qr/setSelectedAccount\(/,
	'the chosen resident account is sent back');
like($webauthn, qr/setPin\(/,
	'and the PIN');
like($webauthn, qr/FinishTokenCollection/,
	'the touch state is shown while the key is touched');
like($webauthn, qr/requestFailureReason\(\)/,
	'a failure names its reason');
like($webauthn, qr/def request_text\(state, reason="", pin_reason="", relying_party=""\)/,
	'the wording is a Qt-free function');
unlike($webauthn, qr/^(?:from|import)\s+PySide6/m,
	'and nothing imports PySide6 at module scope');

my $passkey_text = `cd "$root" && PYTHONPATH=desktop python3 -c '
from jawnos_desktop.webauthn import request_text, pin_error_text
for state, kw in (
    ("SelectAccount", {"relying_party": "house.test"}),
    ("CollectPin", {"pin_reason": "Challenge"}),
    ("CollectPin", {"pin_reason": "Set"}),
    ("FinishTokenCollection", {}),
):
    t = request_text(state, **kw)
    print(state, "|", t["title"], "|", t["body"])
for reason in ("KeyAlreadyRegistered", "KeyNotRegistered", "Timeout", "HardPinBlock"):
    t = request_text("RequestFailed", reason=reason)
    print(reason, "|", t["title"], "|", t["body"])
print("completed-empty", request_text("Completed")["title"] == "" and request_text("Completed")["body"] == "")
print("pinretry", pin_error_text("WrongPin", 2))
' 2>&1`;
like($passkey_text, qr/^SelectAccount \| Choose a passkey \| Which passkey do you want to use for house[.]test[?]$/m,
	'the account state names the house and asks which passkey');
like($passkey_text, qr/^CollectPin \| Security key PIN \| Enter the PIN for your security key[.]$/m,
	'a challenge asks for the existing PIN');
like($passkey_text, qr/^CollectPin \| Choose a security key PIN \| Set a PIN for this security key[.]$/m,
	'a new PIN is labelled as one');
like($passkey_text, qr/^FinishTokenCollection \| Touch your security key \| Touch your security key now/m,
	'the touch state tells the person what to do');
like($passkey_text, qr/^KeyAlreadyRegistered \| Passkey request failed \| .*already registered/m,
	'a key already registered is explained');
like($passkey_text, qr/^KeyNotRegistered \| Passkey request failed \| .*not registered/m,
	'and so is a key the house does not know');
like($passkey_text, qr/^Timeout \| Passkey request failed \| .*did not answer/m,
	'and a timeout');
like($passkey_text, qr/^HardPinBlock \| Passkey request failed \| .*locked/m,
	'and a key locked by too many wrong PINs');
like($passkey_text, qr/^completed-empty True$/m,
	'a completed request needs no words');
like($passkey_text, qr/^pinretry Wrong PIN[.] 2 attempts remaining[.]$/m,
	'a wrong PIN is cleared and explained on the retry');
my $noqt = `cd "$root" && PYTHONPATH=desktop python3 -c 'import sys, jawnos_desktop.webauthn; print("qt-loaded", any(m == "PySide6" or m.startswith("PySide6.") for m in sys.modules))' 2>&1`;
like($noqt, qr/^qt-loaded False$/m,
	'the module imports on a machine with no Qt stack');

# The real page connection, offscreen: the signal exists on this binding and
# the installer reports it. No authenticator is present, so only the wiring is
# proved -- the dialog itself needs hardware to reach.
my $wa_live = `cd "$root" && QT_QPA_PLATFORM=offscreen QTWEBENGINE_CHROMIUM_FLAGS='--disable-gpu --no-sandbox' PYTHONPATH=desktop timeout 45 python3 -c '
from PySide6.QtWidgets import QApplication
from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineProfile
from jawnos_desktop import webauthn
app = QApplication([])
page = QWebEnginePage(QWebEngineProfile("webauthn-test"), None)
print("webauthn-installed", webauthn.install_webauthn(page, None))
' 2>&1`;
SKIP: {
	skip 'PySide6 is not installed here', 1
		if $wa_live =~ /No module named .PySide6|ModuleNotFoundError/;
	like($wa_live, qr/^webauthn-installed True$/m,
		'the page signal is connected on this Qt (no authenticator present)');
}

# The GPS rule, as a plain function (no Qt bindings): an explicit opt-in, a
# named device, or a receiver the USB bus names. A machine with none still
# gets the location service's coarse, ISP position, which the house disregards.
my $gps_dir = tempdir(CLEANUP => 1);
my $gps_rule = 'from jawnos_desktop import gps; import sys; '
	. 'print(gps.has_gps(sys.argv[1], sockets=(), usb=sys.argv[2]))';
sub gps_says {
	my ($config, $usb) = @_;
	write_file("$gps_dir/config.json", $config);
	return `cd "$root" && PYTHONPATH=desktop python3 -c '$gps_rule' "$gps_dir" "$usb" 2>&1`;
}
like(gps_says('{"gps": true}', ''), qr/^True$/m,
	'an explicit "gps": true in config.json offers location');
like(gps_says('{}', 'Bus 001 Device 002: ID 1546:01a7 u-blox GNSS receiver'),
	qr/^True$/m, 'a u-blox receiver on the USB bus counts as one');
like(gps_says('{}', 'Bus 001 Device 003: ID 046d:c31c Logitech USB keyboard'),
	qr/^False$/m, 'a machine with no receiver is denied');
my $gps_dev = "$gps_dir/ttyGPS0";
write_file($gps_dev, "");
like(gps_says(qq({"gps_device": "$gps_dev"}), ''), qr/^True$/m,
	'a named gps_device that exists counts too');
unlike($session, qr/--engine webkit|WebKitGTK/,
	'the Sway session no longer falls back to WebKitGTK');
like($session, qr/the Qt WebEngine view could not start/,
	'and reports a failed Qt shell instead of silently dropping to nothing');
like($qt, qr/from \.qt_panel import ControlPanel/, 'the shell loads the Qt panel');
like($qt, qr/\("Control panel", show_panel\)/, 'the tray opens it');
like($qt, qr/admin_opener\["open"\] = show_panel/, 'and the page admin icon does too');
like($panel, qr/class ControlPanel/, 'the panel is a Qt dialog');
like($panel, qr/theme\.PANEL_CSS/, 'it carries the desktop\'s shared look');
like($panel, qr/class StatusDot/, 'with painted status dots, not just coloured text');
like($panel, qr/core\.jawn_status/, 'and the shared starting/running/stopped rule');
like($theme, qr/QFrame#card/, 'the cards are rounded on the black ground');
like($theme, qr/#ffcc00/, 'with the jawn yellow as the primary accent');
like($panel, qr/Import ticket/, 'with the login ticket controls');
like($panel, qr/Start VPN/, 'the tailnet');
like($panel, qr/Start bridge/, 'the BLE bridge');
like($panel, qr/Start the BLE bridge at login/, 'the autostart setting');
like($panel, qr/update_available/, 'and the app update');
unlike($keepawake, qr/import gi|from gi\.repository/, 'the Qt keep-awake does not need PyGObject');
like($keepawake, qr/systemd-inhibit/, 'it uses logind\'s idle inhibitor');

like($qt, qr/def webkit_localstorage/, 'the shell can read the legacy WebKit localStorage store');
like($qt, qr/base = base or data_dir\(\)/, 'reading the shared XDG data root');
unlike($qt, qr/expanduser\("~\/\.local\/share"\)/, 'not a hand-built home path');
unlike($browse, qr/XDG_DATA_HOME/, 'Browse does not hand-build the XDG data path');
like($browse, qr/return os\.path\.join\(data_dir\(\), "jawnos", "browser"\)/,
	'it asks core_paths for the data root');
like($ble, qr/from \.core_paths import ble_pid_path, config_dir/,
	'the BLE daemon reads its paths from core_paths');
unlike($ble, qr/from \.core import BRIDGE_PORT, ble_pid_path, config_dir/,
	'not through the core.py facade');
for my $module ([$qt, 'the Qt shell'], [$browse, 'Browse'], [$ble, 'the BLE daemon']) {
	unlike($module->[0], qr/XDG_DATA_HOME|expanduser\("~\/\.local\/share"\)/,
		"$module->[1] does not hand-build an XDG/home data path");
}
like($qt, qr/def device_seed_js/, 'and carries the desktop device identity across');
like($qt, qr/__jawn_device_seeded/, 'seeding it once per profile');
like($qt, qr/__jawn_qt_migrated/, 'the migration is marked, so later Qt changes are kept');
like($qt, qr/background_images/, 'the layout family it copies is the one the page reads');
like($qt, qr/window_width/, 'the window geometry is restored from desktop.json');
like($qt, qr/showMaximized/, 'including maximized');
like($qt, qr/core\.save_settings/, 'and saved back on close');

# The reader, against a fixture in WebKit's shape: an ItemTable whose values
# are UTF-16LE blobs, under <base>/<app>/localstorage/https_<host>_<port>.
{
	my $tmp = tempdir(CLEANUP => 1);
	my $dir = "$tmp/base/jawnos-desktop/localstorage";
	make_path($dir);
	my $db = "$dir/https_127.0.0.1_45545.localstorage";
	my $fixture = "$tmp/fixture.py";
	open(my $fh, '>', $fixture) or die "$fixture: $!";
	print {$fh} <<'PYINNER';
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("create table ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB NOT NULL ON CONFLICT FAIL)")
for key, value in (("layout", "desk"), ("background_images", '["one"]'), ("device_uuid", "keep-me"), ("browser_tab", "tab-1")):
    c.execute("insert into ItemTable (key, value) values (?, ?)", (key, value.encode("utf-16-le")))
c.commit()
PYINNER
	close $fh;
	system("python3", $fixture, $db) == 0 or die "fixture failed";
	my $out = `cd "$root" && PYTHONPATH=desktop python3 -c 'import json,sys; from jawnos_desktop.qt_shell import webkit_localstorage; p,d = webkit_localstorage("127.0.0.1", 45545, base=sys.argv[1]); print(json.dumps(d))' "$tmp/base" 2>&1`;
	like($out, qr/"layout": "desk"/, 'the reader returns the legacy layout key');
	like($out, qr/background_images/, 'and the background list');
	like($out, qr/"device_uuid": "keep-me"/, 'and the desktop device identity');
	unlike($out, qr/browser_tab/, 'but not the live tab id');
	my $seed = `cd "$root" && PYTHONPATH=desktop python3 -c 'import sys; from jawnos_desktop.qt_shell import device_seed_js; print(device_seed_js("127.0.0.1", 45545, base=sys.argv[1]))' "$tmp/base" 2>&1`;
	like($seed, qr/__jawn_device_seeded/, 'the seed runs only once');
	like($seed, qr/keep-me/, 'and writes the legacy device identity');
}

# The real engine, when this machine has it. A machine without the PySide6
# QtWebEngine package skips: the source pins above still run everywhere. The
# probe page is a file:// URL: a data: page is an opaque origin, so the
# QWebChannel transport is absent and bridge/ping would report false.
my $probe_dir = tempdir(CLEANUP => 1);
my $blank = "$probe_dir/blank.html";
open(my $bfh, '>', $blank) or die "$blank: $!";
print {$bfh} "<!doctype html><html><body>probe</body></html>\n";
close $bfh;
my $probe = `cd "$root" && timeout 45 xvfb-run -a env QTWEBENGINE_CHROMIUM_FLAGS='--disable-gpu --no-sandbox' python3 desktop/jawnos-qt --probe --url 'file://$blank' 2>&1`;
SKIP: {
	skip 'the Qt WebEngine package is not installed here', 7
		if $probe =~ /needs PySide6|No module named .PySide6/ || $probe !~ /qt-probe /;
	my ($line) = $probe =~ /^(qt-probe .*)$/m;
	like($line, qr/"rtc":"function"/, 'the real engine has RTCPeerConnection');
	like($line, qr/"offer":"offer"/, 'and it completes an offer on the spot');
	like($line, qr/"bridge":true/, 'the QWebChannel bridge connects');
	like($line, qr/"ping":true/, 'a message round-trips through the bridge');
	like($line, qr/"desktop":true/, 'and the page sees the desktop marker');
	like($line, qr/"gpu":"[^"]+"/,
		'and the probe names the renderer it is using');
	unlike($probe, qr/NameError|Traceback/,
		'a real (origin-checked) action does not crash the handler');
}

# The panel itself, built without a display. It reads the shared core; the
# controls are the panel's own.
my $panel_run = `cd "$root" && QT_QPA_PLATFORM=offscreen PYTHONPATH=desktop python3 -c 'from PySide6.QtWidgets import QApplication; from jawnos_desktop.qt_panel import ControlPanel; app=QApplication([]); p=ControlPanel({"jawn_dir":"/tmp","ble_with_jawn":True},{"show_view":lambda:None,"show_log":lambda:None,"restart":lambda:None}); print("panel-ok", p.windowTitle())' 2>&1`;
SKIP: {
	skip 'the PySide6 panel cannot be built here', 1
		if $panel_run =~ /No module named .PySide6|ModuleNotFoundError/;
	like($panel_run, qr/panel-ok JawnOS\n/, 'the panel builds offscreen');
}

# The blank-page colour: the engine's own background plus the widget's palette
# and stylesheet, so a launch never flashes white. The text colour is set with
# the ground: the engine's own confirm/alert dialog is a QMessageBox parented to
# this view, so an unreadable black-on-black prompt is what a bare background
# produces (the AI-model Test button hit exactly that).
my $black = `cd "$root" && QT_QPA_PLATFORM=offscreen PYTHONPATH=desktop python3 -c 'from PySide6.QtGui import QPalette; from jawnos_desktop.qt_shell import black_page
class P:
  def setBackgroundColor(self, c): self.c = c.name()
class V:
  def __init__(self): self.p = QPalette()
  def palette(self): return self.p
  def setPalette(self, p): self.p = p
  def setAutoFillBackground(self, on): self.fill = on
  def setStyleSheet(self, css): self.css = css
p, v = P(), V(); black_page(p, v); print(p.c, v.fill, v.css, v.p.color(QPalette.ColorRole.Window).name())' 2>&1`;
SKIP: {
	skip 'PySide6 is not installed here', 1
		if $black =~ /No module named .PySide6|ModuleNotFoundError/;
	like($black, qr/^#000000 True background-color: #000000; color: #ffffff; #000000$/m,
		'the page, view palette and stylesheet are all black, with white text');
}
my $dialog = `cd "$root" && QT_QPA_PLATFORM=offscreen PYTHONPATH=desktop python3 -c 'from PySide6.QtGui import QPalette; from PySide6.QtWidgets import QApplication, QWidget, QMessageBox; from jawnos_desktop.qt_shell import black_page
class P:
  def setBackgroundColor(self, c): pass
app = QApplication([])
v = QWidget(); black_page(P(), v)
box = QMessageBox(QMessageBox.Icon.Question, "Confirm", "Continue?", QMessageBox.StandardButton.Ok | QMessageBox.StandardButton.Cancel, v)
box.show(); app.processEvents()
print(box.palette().color(QPalette.ColorRole.Window).name(), box.palette().color(QPalette.ColorRole.WindowText).name(), box.palette().color(QPalette.ColorRole.ButtonText).name())' 2>&1`;
SKIP: {
	skip 'PySide6 is not installed here', 1
		if $dialog =~ /No module named .PySide6|ModuleNotFoundError/;
	like($dialog, qr/^#000000 #ffffff #ffffff$/m,
		'a dialog under the view is white text on the black ground');
}

# The dark error page: escaped inputs, the retry only for a real URL, and the
# phrase the user sees instead of Chromium's white page.
my $errtest = `cd "$root" && PYTHONPATH=desktop python3 -c 'from jawnos_desktop.errorpage import dark_page; h=dark_page("<b>x</b>", "https://h/p?q=<1>"); print("err-ok", "&lt;b&gt;" in h, "Try again" in h, "background:#000000" in h, "<title>This page cannot be displayed</title>" in h)' 2>&1`;
SKIP: {
	skip 'python3 is not installed here', 1
		if $errtest =~ /command not found|No such file/;
	like($errtest, qr/^err-ok True True True True$/m,
		'the dark page escapes, retries and names the failure');
}

# The status rule the panel and the tray share: red when down, amber while a
# start this process asked for is young, green once it answers.
my $states = `cd "$root" && PYTHONPATH=desktop python3 -c 'import time; from jawnos_desktop import core; core.clear_start_requested(); a=core.jawn_status(False); core.mark_start_requested(now=time.monotonic()-5); b=core.jawn_status(False); core.mark_start_requested(now=time.monotonic()-151); c=core.jawn_status(False); print(a, b, c, core.jawn_status(True))' 2>&1`;
like($states, qr/\('not running', 'red'\) \('starting\.\.\. \(\d+s\)', 'amber'\) \('not running', 'red'\) \('running', 'green'\)/,
	'start-up reads red -> amber (with its age) -> green');
like($core, qr/STARTING_WINDOW = 150\.0/, 'the amber window is the dashboard\'s 150 s');
like($core_process, qr/mark_start_requested\(\)/, 'a start marks the clock');
like($core_process, qr/def restart_jawn[^\n]*\n(?:.*\n)*?\s+_core\.mark_start_requested\(\)/,
	'and a restart marks it before the stop, so it never flashes red');
like($core, qr/clear_start_requested\(\)/, 'a deliberate stop clears it');

# The self-update marker moved off the deleted GTK dashboard: a repo desktop
# tree counts only when it has the Qt shell.
my $ready = `cd "$root" && PYTHONPATH=desktop python3 -c '
import os, tempfile
from jawnos_desktop import core
d = tempfile.mkdtemp()
os.makedirs(os.path.join(d, "desktop", "jawnos_desktop"))
print(core.repo_desktop_ready({"jawn_dir": d}))
open(os.path.join(d, "desktop", "jawnos_desktop", "ui.py"), "w").close()
print(core.repo_desktop_ready({"jawn_dir": d}))
open(os.path.join(d, "desktop", "jawnos_desktop", "qt_shell.py"), "w").close()
print(core.repo_desktop_ready({"jawn_dir": d}))
' 2>&1`;
like($ready, qr/^False\nFalse\nTrue$/m,
	'the repo-desktop marker is qt_shell.py, not the deleted ui.py');

# The tray badge: one icon per tone, built and cached, distinct by colour.
my $icons = `cd "$root" && QT_QPA_PLATFORM=offscreen PYTHONPATH=desktop python3 -c 'from PySide6.QtWidgets import QApplication; from jawnos_desktop.qt_shell import tray_icon; from jawnos_desktop import theme; app=QApplication([]); xs=[tray_icon("desktop/icons/jawnos.png", c) for c in (theme.GREEN, theme.AMBER, theme.RED)]; print("icons-ok", len(xs), xs[0] is tray_icon("desktop/icons/jawnos.png", theme.GREEN), all(not x.isNull() for x in xs))' 2>&1`;
SKIP: {
	skip 'PySide6 is not installed here', 1
		if $icons =~ /No module named .PySide6|ModuleNotFoundError/;
	like($icons, qr/^icons-ok 3 True True$/m,
		'the three state badges build and are cached per colour');
}

my $hostkit = `cd "$root" && QT_QPA_PLATFORM=offscreen PYTHONPATH=desktop python3 -c 'from PySide6.QtCore import QUrl; from jawnos_desktop.qt_shell import _qurl_host; print(_qurl_host(QUrl("https://Example.COM:45545/x")), _qurl_host(QUrl("https://[::1]:1/")))' 2>&1`;
SKIP: {
	skip 'PySide6 is not installed here', 1
		if $hostkit =~ /No module named .PySide6|ModuleNotFoundError/;
	like($hostkit, qr/^example\.com ::1$/m,
		'the QUrl host is lower-cased and IPv6 brackets are stripped');
}

# The graphics environment: a WebKit-only switch is not copied into Chromium,
# qt.env wins over it, and the real environment always wins over both.
{
	my $tmp = tempdir(CLEANUP => 1);
	write_file("$tmp/webkit.env", "WEBKIT_DMABUF_RENDERER_FORCE_SHM=1\nLIBVA_DRIVER_NAME=i965\n");
	write_file("$tmp/qt.env", "QTWEBENGINE_CHROMIUM_FLAGS=--from-qt-env\n");
	my $out = `cd "$root" && PYTHONPATH=desktop python3 -c 'import json; from jawnos_desktop import gpu; e={"QTWEBENGINE_CHROMIUM_FLAGS":"--from-real"}; a=gpu.prepare_env(e, config_dir="$tmp", cards=[("0x8086","0x1912")], render_nodes=["/dev/dri/renderD128"], drivers={"iHD"}); print(json.dumps([a, e]))' 2>&1`;
	like($out, qr/"--from-real --ignore-gpu-blocklist --enable-gpu-rasterization"/,
		'the real flags are kept and the GPU flags appended');
	like($out, qr/"LIBVA_DRIVER_NAME": "i965"/,
		'webkit.env\'s non-WebKit keys still reach Chromium');
	unlike($out, qr/WEBKIT_DMABUF_RENDERER_FORCE_SHM|--from-qt-env/,
		'but WebKit-only switches and a shadowed qt.env value do not');
}

# The vendor matrix, without the hardware: cards, render nodes and installed
# VA-API drivers are injected. A real card with a render node keeps Chromium's
# GPU path; a virtual display GPU or a machine with no render node gets the
# software path instead of a failing GPU process.
{
	my $matrix = `cd "$root" && PYTHONPATH=desktop python3 -c '
import json
from jawnos_desktop import gpu
cases = {
    "intel": ([("0x8086", "0x1912")], ["/dev/dri/renderD128"], {"iHD", "i965"}, {}),
    "intel_i965": ([("0x8086", "0x1912")], ["/dev/dri/renderD128"], {"i965"}, {}),
    "intel_no_driver": ([("0x8086", "0x1912")], ["/dev/dri/renderD128"], set(), {}),
    "amd": ([("0x1002", "0x73ff")], ["/dev/dri/renderD128"], {"radeonsi"}, {}),
    "amd_no_driver": ([("0x1002", "0x73ff")], ["/dev/dri/renderD128"], set(), {}),
    "nvidia": ([("0x10de", "0x1c82")], ["/dev/dri/renderD128"], {"nvidia"}, {}),
    "nvidia_no_driver": ([("0x10de", "0x1c82")], ["/dev/dri/renderD128"], set(), {}),
    "virtio": ([("0x1af4", "0x1050")], ["/dev/dri/renderD128"], set(), {}),
    "bochs": ([("0x1234", "0x1111")], ["/dev/dri/renderD128"], set(), {}),
    "vmware": ([("0x15ad", "0x0405")], ["/dev/dri/renderD128"], set(), {}),
    "vbox": ([("0x80ee", "0xbeef")], ["/dev/dri/renderD128"], set(), {}),
    "qxl": ([("0x1b36", "0x0100")], ["/dev/dri/renderD128"], set(), {}),
    "no_node": ([("0x8086", "0x1912")], [], {"iHD"}, {}),
    "force_virtual": ([("0x1af4", "0x1050")], ["/dev/dri/renderD128"], set(), {"JAWNOS_GPU": "1"}),
    "gpu_zero": ([("0x8086", "0x1912")], ["/dev/dri/renderD128"], {"iHD"}, {"JAWNOS_GPU": "0"}),
    "disable_gpu": ([("0x8086", "0x1912")], ["/dev/dri/renderD128"], {"iHD"}, {"QTWEBENGINE_CHROMIUM_FLAGS": "--disable-gpu --from-real"}),
    "real_driver": ([("0x8086", "0x1912")], ["/dev/dri/renderD128"], {"iHD"}, {"LIBVA_DRIVER_NAME": "i965"}),
    "unknown": ([("0x9999", "0x0001")], ["/dev/dri/renderD128"], {"iHD"}, {}),
    "no_sysfs": ([], ["/dev/dri/renderD128"], set(), {}),
}
out = {}
for name, (cards, nodes, drivers, env) in cases.items():
    e = dict(env)
    gpu.prepare_env(e, config_dir="/nonexistent", cards=cards, render_nodes=nodes, drivers=drivers)
    out[name] = [e.get("LIBVA_DRIVER_NAME"), e.get("QTWEBENGINE_CHROMIUM_FLAGS")]
print(json.dumps(out))
' 2>&1`;
	like($matrix, qr/"intel": \["iHD", "--ignore-gpu-blocklist --enable-gpu-rasterization"\]/,
		'Intel Gen9+ picks iHD and keeps the GPU path');
	like($matrix, qr/"intel_i965": \["i965", "--ignore-gpu-blocklist/,
		'older Intel falls back to i965');
	like($matrix, qr/"intel_no_driver": \[null, "--ignore-gpu-blocklist/,
		'with no Intel VA driver the variable is left unset');
	like($matrix, qr/"amd": \["radeonsi", "--ignore-gpu-blocklist/,
		'AMD uses Mesa radeonsi');
	like($matrix, qr/"amd_no_driver": \[null, "--ignore-gpu-blocklist/,
		'and AMD without radeonsi_drv_video.so is not named');
	like($matrix, qr/"nvidia": \["nvidia", "--ignore-gpu-blocklist/,
		'NVIDIA uses libva-nvidia-driver');
	like($matrix, qr/"nvidia_no_driver": \[null, "--ignore-gpu-blocklist/,
		'and nouveau (no shim) is left unset');
	for my $virt (qw(virtio bochs vmware vbox qxl)) {
		like($matrix, qr/"$virt": \[null, "--disable-gpu --disable-gpu-compositing"\]/,
			"a virtual $virt GPU gets the software path, not a failing GPU process");
	}
	like($matrix, qr/"no_node": \[null, "--disable-gpu --disable-gpu-compositing"\]/,
		'no render node means software rendering');
	like($matrix, qr/"force_virtual": \[null, "--ignore-gpu-blocklist/,
		'JAWNOS_GPU=1 forces the GPU path even on a virtual card');
	like($matrix, qr/"gpu_zero": \["iHD", "--disable-gpu --disable-gpu-compositing"\]/,
		'JAWNOS_GPU=0 asks for software rendering');
	like($matrix, qr/"disable_gpu": \["iHD", "--disable-gpu --from-real"\]/,
		'an existing --disable-gpu is never touched');
	like($matrix, qr/"real_driver": \["i965", "--ignore-gpu-blocklist/,
		'a driver chosen by the real environment wins over auto-detection');
	like($matrix, qr/"unknown": \[null, "--ignore-gpu-blocklist/,
		'an unknown vendor is not guessed, but keeps the GPU path');
	like($matrix, qr/"no_sysfs": \[null, "--ignore-gpu-blocklist/,
		'a render node without sysfs still keeps the GPU path');
}

# Coasting, measured in the engine the shell embeds. A synthetic wheel event
# scrolls nothing by itself, so every pixel here is the shim's: a burst of small
# deltas must keep the box moving after they stop, and a single mouse-wheel
# notch must not. Skipped where the engine or a display server is missing; the
# static checks above still cover the shim's shape.
SKIP: {
	my $xvfb = `command -v xvfb-run 2>/dev/null`;
	chomp $xvfb;
	my $qt_here = `cd "$root" && PYTHONPATH=desktop python3 -c 'import PySide6.QtWebEngineWidgets' 2>&1`;
	skip 'needs xvfb-run and PySide6 with Qt WebEngine', 2
		if !$xvfb || $qt_here =~ /ModuleNotFoundError|No module named/;
	my $tmp = tempdir(CLEANUP => 1);
	my $script = "$tmp/coast.py";
	open(my $fh, '>', $script) or die "$script: $!";
	print $fh <<'PY';
import json, os, time
from PySide6.QtCore import QTimer
from PySide6.QtWidgets import QApplication
from PySide6.QtWebEngineWidgets import QWebEngineView
from jawnos_desktop.qt_shell import _MOMENTUM_JS

PAGE = """<!doctype html><html><body style="margin:0">
<div id="box" style="height:200px;overflow-y:auto"><div style="height:4000px"></div></div>
<script>%s</script>
<script>
window.__samples = null;
window.__run = function (kind) {
  var box = document.getElementById('box');
  box.scrollTop = 0;
  var t0 = performance.now(), samples = [];
  function rec() {
    var t = performance.now() - t0;
    samples.push([Math.round(t), Math.round(box.scrollTop)]);
    if (t < 1500) { requestAnimationFrame(rec); } else { window.__samples = samples; }
  }
  requestAnimationFrame(rec);
  var count = kind === 'flick' ? 12 : 1;
  var delta = kind === 'flick' ? 8 : 100;
  // Paced by the clock, not by setTimeout: a busy first paint coalesces the
  // timer callbacks, the burst then arrives with no span, and the shim has no
  // velocity to carry (correctly). Spin instead, so the gap is real.
  for (var k = 0; k < count; k++) {
    box.dispatchEvent(new WheelEvent('wheel', {
      deltaY: delta, bubbles: true, cancelable: true
    }));
    var until = performance.now() + 12;
    while (performance.now() < until) {}
  }
};
</script></body></html>""" % _MOMENTUM_JS

queue = ['flick', 'notch']
results = {}

app = QApplication([])
view = QWebEngineView()
view.resize(400, 300)
view.show()
page = view.page()
page.setHtml(PAGE, 'data:text/html,,')


def start_next():
    if not queue:
        report()
        return
    kind = queue.pop(0)
    page.runJavaScript('window.__samples = null; window.__run(%s)' % json.dumps(kind))
    poll(kind, time.time() + 8)


def poll(kind, deadline):
    def got(value):
        text = str(value or '')
        if text:
            try:
                results[kind] = json.loads(text)
            except ValueError:
                results[kind] = []
            QTimer.singleShot(150, start_next)
        elif time.time() > deadline:
            results[kind] = []
            start_next()
        else:
            QTimer.singleShot(100, lambda: poll(kind, deadline))
    page.runJavaScript("window.__samples ? JSON.stringify(window.__samples) : ''", got)


def report():
    for kind in ('flick', 'notch'):
        samples = results.get(kind) or []
        print('%s: final=%s' % (kind, samples[-1][1] if samples else -1), flush=True)
    os._exit(0)


page.loadFinished.connect(lambda ok: QTimer.singleShot(500, start_next))
QTimer.singleShot(60000, report)
app.exec()
PY
	close $fh;
	my $out;
	my ($flick, $notch);
	# A busy first paint can coalesce the synthetic burst. The shim then has no
	# velocity to carry - the right answer for that input, not a broken one - and
	# the suite's own job count decides the result. Retry the whole measurement a
	# couple of times and judge the first run that actually recorded motion,
	# with that run's own notch sample.
	for my $attempt (1 .. 3) {
		$out = `cd "$root" && PYTHONPATH=desktop QTWEBENGINE_CHROMIUM_FLAGS="--disable-gpu --no-sandbox" timeout 120 xvfb-run -a python3 -u "$script" 2>&1`;
		my %got = ($out =~ /^(flick|notch): final=([\d.]+)/mg);
		$flick = $got{flick};
		$notch = $got{notch};
		last if defined $flick && $flick > 60;
		select(undef, undef, undef, 1) if $attempt < 3;
	}
	cmp_ok($flick // 0, '>', 60,
		'a flick keeps the container moving after the wheel stops')
		or diag(substr($out // '', 0, 600));
	is($notch // -1, 0, 'a single wheel notch does not coast');
}

done_testing();
