# tests-for: public/js/manager/windows/ public/js/manager/windows.js public/js/manager/websocket/01_message_handler.js public/js/universal/03_unlock_requests_media_locks.js lib/JawnOS/Manager/Part22.pm templates/layouts/manager.html.ep
# covers:    The window store is one encrypted IndexedDB database, private apps are never written, a reload paints the stored shell before the server answers, and a live header writes its window back.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A reload waits on the manager's render queue for every open window. The desk's
# own copy is kept in an encrypted store now, and painted before the server is
# asked; the server's render still replaces it. These pins are what make the
# store safe and useful: one database, sealed payloads, no private app on the
# disk, and a restore path that cannot overwrite a newer render.

my $root = repo_root();
my $store = js_source('public/js/manager/windows/00_store.js');
my $emerge = js_source('public/js/manager/windows/06_emerge.js');
my $storage = js_source('public/js/manager/windows/01_storage.js');
my $windows = js_source('public/js/manager/windows.js');
my $websocket = js_source('public/js/manager/websocket/01_message_handler.js');
my $unlock = read_file("$root/public/js/universal/03_unlock_requests_media_locks.js");
my $manager = manager_source();
my $layout = read_file("$root/templates/layouts/manager.html.ep");

# --- one store, sealed ------------------------------------------------------

like($store, qr/JAWNOS_WINDOWS_DB\s*=\s*'jawnos_windows'/, 'the one store is jawnos_windows');
like($store, qr/name:\s*'AES-GCM'/, 'payloads are sealed with AES-GCM');
like($store, qr/generateKey\(\s*\{\s*name:\s*'AES-GCM'[^}]*\}\s*,\s*false\s*,\s*\[\s*'encrypt'\s*,\s*'decrypt'\s*\]\s*\)/,
	'the key is non-extractable, so a copied database cannot be opened');
like($store, qr/crypto\.subtle\.digest\(\s*'SHA-256'/, 'the record key is a hash, so the store does not name its apps');
like($store, qr/objectStore\(JAWNOS_WINDOWS_STORE\)\.put\(row\)/, 'the store writes the sealed row');
unlike($store, qr/localStorage\.(?:setItem|getItem)\([^)]*shell/,
	'no window markup is written to localStorage');
like($store, qr/k:\s*k,\s*iv:\s*sealed\.iv,\s*ct:\s*sealed\.ct/,
	'the row carries only the hash, the IV and the ciphertext');

# --- private is never written ----------------------------------------------

like($store, qr/data-private/, 'the capture reads the server private mark');
like($store, qr/function jawnosWindowsPublicNow/, 'private mode is a store-wide refusal');
like($store, qr/data-private-place/, 'a private place refuses every write');
like($store, qr/if \(!jawnosWindowsPublicNow\(el\)\) \{ return false; \}/, 'the shell capture refuses private mode');
like($emerge, qr/jawnosWindowsPublicNow\(win\)/, 'the preview capture refuses it too, before it keeps either copy');
like($manager, qr/my \$private_mode_attr = \(&subs::private_reachable_now\(\) \|\| &subs::private_revealed\(\)\)/,
	'a window rendered in private mode carries the mark');
like($manager, qr/\$private_attr \. \$private_mode_attr/, 'the mark is on the .wind the capture reads');
like($layout, qr/data-private-place="yes"/, 'the page carries the private place');
like($layout, qr/data-private-mode="yes"/, 'and the grant state at load');
like($unlock, qr/setAttribute\('data-private-mode', 'yes'\)/, 'a grant opening turns private mode on at once');
like($unlock, qr/removeAttribute\('data-private-mode'\)/, 'and closing it turns the store back on');
like($store, qr/\.lockdown_window/, 'a lockdown window is not kept');
like($store, qr/#denial_window/, 'a denial is not kept');
like($store, qr/hasClass\('lockdown'\)/, 'a capture and a restore both refuse a lockdown');
like($manager, qr/my \$private_attr = \(\$app ne 'Denied' && &subs::app_private_now\(\$app\)\)/,
	'the server marks a private app window and only a private one');
like($manager, qr/\$window_instance_attr \. \$private_attr \. \$private_mode_attr \. \$place_screen/,
	'the private marks are on the .wind the capture reads');

# --- a reload paints first --------------------------------------------------

like($storage, qr/jawnosWindowsShellRestore\(i, timestamp, v\)/,
	'a restore asks the store for its shell');
like($storage, qr/if \(\$\('#window_' \+ timestamp\)\.length\) \{ return; \}/,
	'a standing shell keeps its slot when the render fails');
like($store, qr/v\.type != 'window'/, 'only a restore paints a stored shell, not a fresh press');
like($store, qr/saved\[app\]/, 'and only for a window in this desk\'s own saved set');
like($store, qr/\$\('#window_' \+ timestamp\)\.hide\(\)/, 'a minimised restore does not flash open');
like($store, qr/jawnosWindowsHasWindow\(identity\)/, 'a shell never replaces a window that is already there');
like($store, qr/\.split\(from\)\.join\(to\)/, 'the stored stamp is moved to the new window');
like($store, qr/windowMaker\(jawnosWindowsRestamp/, 'the stored shell goes through windowMaker, so piles and slots still apply');
like($store, qr/jawnosWindowsShellSanitize\(node\);/, 'a stored shell is stripped of live sources before it is kept');
like($store, qr/jawnosWindowsSave\(identity, \{ shell: html, ts: stamp, app: app/, 'the capture writes the shell, its stamp and its app');

# --- a live update is written back ------------------------------------------

like($websocket, qr/jawnosWindowsShellCaptureSoon\(\$/, 'a pushed header writes its window back');
like($windows, qr/jawnosWindowsShellCaptureSoon\(wind_el/, 'a re-rendered window writes itself back');
like($windows, qr/jawnosWindowsShellCaptureSoon\(\$\('#' \+ window_id\), 1500\)/, 'an appended window is kept even with the motions off');
like($emerge, qr/jawnosWindowsShellCapture\(win\)/, 'the settle/close/sweep capture also keeps the shell');
like($emerge, qr/return jawnosWindowsSave\(jawnosWindowsIdentity\(record\.app, \{\}\)/, 'the press preview shares the one store');
like($emerge, qr/row\.preview/, 'the reload reads the preview from the shared record');
unlike($emerge, qr/indexedDB\.open\(|jawn_emerge/, 'the old plaintext preview store is gone');
like($store, qr/deleteDatabase\('jawn_emerge'\)/, 'the old plaintext store is removed once');

# --- the scope and the split ------------------------------------------------

like($layout, qr/jawnos_session_scope/, 'the page names the person for the store scope');
like($layout, qr/encode_json\(\$c->session\('name'\) \|\| ''\)/, 'the scope is a JSON string, so a name cannot break the script');
like($windows, qr/00_store\.js/, 'the split manifest names the new part');

done_testing();
