# tests-for: public/js/manager/windows/ public/js/manager/windows.js public/js/manager/websocket/01_message_handler.js public/js/universal/03_unlock_requests_media_locks.js lib/JawnOS/Manager/Part22.pm templates/layouts/manager.html.ep
# covers:    The window store is one encrypted IndexedDB database. A private place keeps public app windows; a private app, a live private grant and a media app with a fingerprint-unlocked album are refused. The build is not in the scope, a theme change reaps the shells, and the disk store is bounded by its fifty-megabyte ceiling.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
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

# --- private apps, grants and media unlocks are never written --------------

like($store, qr/data-private/, 'the capture reads the server private mark');
like($store, qr/function jawnosWindowsPublicNow/, 'the public check decides what may be written');
like($store, qr/allow_private_place/, 'a window capture opts into a private place');
like($store, qr/!allow_private_place && body\.getAttribute\('data-private-place'\) === 'yes'/, 'a caller without the opt still refuses a private place');
like($store, qr/body\.getAttribute\('data-private-mode'\) === 'yes'/, 'a live private grant still refuses');
like($store, qr/el\.getAttribute\('data-private'\) === 'yes'/, 'a private app still refuses');
like($store, qr/\[unlock\]/, 'a fingerprint-unlocked media app still refuses');
like($store, qr/jawnosWindowsPublicNow\(el, \{ allow_private_place: true \}\)/, 'the shell capture keeps a private place');
like($store, qr/jawnosWindowsDelete\(jawnosWindowsIdentityOf\(el\)\)/, 'a refused shell is removed');
like($emerge, qr/function jawnosEmergePreviewSave\(record, el\) \{.*?jawnosWindowsPublicNow\(el, \{ allow_private_place: true \}\)/s,
	'the preview keeps a private place but refuses a private app or media grant');
like($emerge, qr/jawnosWindowsDelete\(jawnosWindowsIdentity\(record\.app, \{\}\)\)/, 'a refused preview is removed');
like($emerge, qr/delete jawnosEmergePreviews\[app\]/, 'a refused picture never becomes the next press');
like($emerge, qr/!app \|\| app == 'Denied'/, 'a denial is not kept as a picture');
like($manager, qr/my \$private_mode_attr = &subs::private_revealed\(\)/,
	'only a live grant marks the window, not a private place');
like($manager, qr/\$private_attr \. \$private_mode_attr/, 'the mark is on the .wind the capture reads');
like($layout, qr/data-private-place="yes"/, 'the page carries the private place');
like($layout, qr/data-private-mode="yes"/, 'and the grant state at load');
like($unlock, qr/setAttribute\('data-private-mode', 'yes'\)/, 'a grant opening turns private mode on at once');
like($unlock, qr/removeAttribute\('data-private-mode'\)/, 'and closing it turns the store back on');
like($unlock, qr/\$\('\.wind'\)\.removeAttr\('data-private-mode'\)/, 'and clears the mark from windows rendered under it');
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
like($websocket, qr/data\['type'\] == 'clothesline'/, 'a pushed clothesline redraws the rail');
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
unlike($store, qr/window\.jawnos_version/, 'the store scope no longer names the build, so an update keeps the shells');
like($store, qr/return machine \+ '\|' \+ person;/, 'the scope is the machine and the person');
like($windows, qr/00_store\.js/, 'the split manifest names the new part');

# --- a theme change reaps; the byte budget bounds the disk -------------------

like($store, qr/function jawnosWindowsReapTheme\(theme\)/, 'a theme change reaps the window records');
like($store, qr/if \(typeof value\.theme == 'string'\) \{ row\.theme = value\.theme; \}/, 'the row keeps its theme for the reap');
like($store, qr/row\.kind = 'view'/, 'and the timeline view is named so the reap leaves it alone');
like($store, qr/if \(held <= JAWNOS_WINDOWS_MAX_BYTES\) \{ continue; \}/, 'the disk store is held to the fifty megabytes');
like($emerge, qr/jawnosWindowsReapTheme\(theme\)/, 'the preview load reaps another theme before it reads');
like($emerge, qr/loaded >= JAWNOS_EMERGE_PREVIEW_APPS/, 'the memory map loads the newest desk of apps');

# --- the policy played in a bare context ------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is needed to play the store policy', 1 unless $node && -x $node;

	my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh <<'JS';
'use strict';
const fs = require('fs');
const vm = require('vm');

let failures = 0;
function check(name, ok) {
	if (!ok) { failures++; console.log('not ok: ' + name); }
}

function el(attrs, children) {
	return {
		nodeType: 1,
		attrs: attrs || {},
		children: children || [],
		getAttribute: function (n) {
			return Object.prototype.hasOwnProperty.call(this.attrs, n) ? this.attrs[n] : null;
		},
		setAttribute: function (n, v) { this.attrs[n] = String(v); },
		removeAttribute: function (n) { delete this.attrs[n]; }
	};
}
function coll(nodes) {
	const list = Array.prototype.slice.call(nodes || []);
	const out = {
		length: list.length,
		find: function (sel) {
			const found = [];
			if (sel === '[unlock]') {
				const walk = function (node) {
					if (node && node.getAttribute && node.getAttribute('unlock') !== null) { found.push(node); }
					const kids = (node && node.children) || [];
					for (let i = 0; i < kids.length; i++) { walk(kids[i]); }
				};
				for (let i = 0; i < list.length; i++) { walk(list[i]); }
			}
			return coll(found);
		},
		each: function (fn) {
			for (let i = 0; i < list.length; i++) {
				if (fn.call(list[i], i, list[i]) === false) { break; }
			}
			return out;
		},
		attr: function (n) {
			return list[0] && list[0].getAttribute ? list[0].getAttribute(n) : undefined;
		}
	};
	for (let i = 0; i < list.length; i++) { out[i] = list[i]; }
	return out;
}
function jq(value) { return coll([value]); }

const body = el({});
const sandbox = {
	$: jq,
	document: { body: body },
	window: null,
	crypto: globalThis.crypto,
	TextEncoder: TextEncoder,
	TextDecoder: TextDecoder,
	console: console
};
sandbox.window = sandbox;
const ctx = vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), ctx, { filename: '00_store.js' });

const pub = ctx.jawnosWindowsPublicNow;
const scope = ctx.jawnosWindowsScope;
const allow = { allow_private_place: true };

// A private place is the safest place for an app window, but the timeline
// view keeps the older strict rule and a live grant/private app/media album
// still refuses.
body.attrs = { 'data-private-place': 'yes' };
check('a private place refuses the timeline', pub() === false);
check('a private place keeps an app window', pub(el({ app: 'configure' }), allow) === true);
body.attrs = { 'data-private-place': 'yes', 'data-private-mode': 'yes' };
check('a live private grant refuses a window', pub(el({ app: 'configure' }), allow) === false);
body.attrs = { 'data-private-place': 'yes' };
check('a private app refuses', pub(el({ app: 'secret', 'data-private': 'yes' }), allow) === false);
check('a window marked private mode refuses', pub(el({ app: 'configure', 'data-private-mode': 'yes' }), allow) === false);
check('an unlocked gallery refuses', pub(el({ app: 'gallery' }, [el({ unlock: 'token' })]) , allow) === false);
check('a locked gallery is kept', pub(el({ app: 'gallery' }, [el({ unlock: '' })]), allow) === true);
check('an unlocked media root refuses in any app', pub(el({ app: 'configure' }, [el({ unlock: 'token' })]), allow) === false);

// The build left the scope so an update keeps the predictions.
sandbox.signatorial = 'machine';
sandbox.jawnos_session_scope = 'person';
sandbox.jawnos_version = '0.1.9999';
check('the scope is the machine and the person', scope() === 'machine|person');
check('the build is not in the scope', scope().indexOf('0.1.9999') < 0);

process.exit(failures ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness" "$root/public/js/manager/windows/00_store.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'the private-place, app, grant, media and scope rules hold in a bare context');
}


done_testing();
