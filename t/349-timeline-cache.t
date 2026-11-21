# tests-for: public/js/manager/manager/07_timeshift.js public/js/manager/windows/00_store.js public/js/manager/clothesline/01_timeline.js
# covers:    a reload paints the last view before the first appointment_viewer
#            answer, but only when it is honestly the same view: the request's
#            inputs must still match, and a "now" view must be younger than its
#            own scope (5m scope -> five minutes, 10m -> ten, capped); an
#            anchored view (time machine or timeshift) is not aged; a now view
#            is re-centred through the drag path's own positions. An open private
#            grant and the desk never paint or write; a private place is the
#            safest place and keeps the view. It rides the sealed windows store,
#            and a server answer always wins.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource;

my $root     = repo_root();
my $timeshift = read_file("$root/public/js/manager/manager/07_timeshift.js");
my $store     = js_source('public/js/manager/windows/00_store.js');
my $timeline  = js_source('public/js/manager/clothesline/01_timeline.js');

# --- the record and the freshness policy ------------------------------------
like($timeshift, qr/var JAWNOS_TIMELINE_CACHE_IDENTITY = 'timeline_view';/,
	'the view has a reserved identity in the one sealed store');
like($timeshift, qr/var JAWNOS_TIMELINE_CACHE_TTL_FLOOR = 60000;/,
	'a scope shorter than a minute still gets a minute');
like($timeshift, qr/var JAWNOS_TIMELINE_CACHE_TTL_CAP = 600000;/,
	'and a long scope is capped at ten');
like($timeshift, qr/function jawnosTimelineCacheTTL\(record\)/,
	'the TTL is the view\'s own half-window');
like($timeshift, qr/var JAWNOS_TIMELINE_CACHE_MAX_BYTES = 4000000;/,
	'one view, with a ceiling on what is worth writing');
like($timeshift, qr/var JAWNOS_TIMELINE_CACHE_SAVE_WAIT = 2000;/,
	'and a debounce, so the poll does not write every second');
like($timeshift, qr/function jawnosTimelineCacheSignature\(data\)/,
	'the inputs signature is its own function');
like($timeshift, qr/var fields = \['scope', 'sorts', 'layout', 'filter', 'timeshift', 'time_machine', 'account', 'project', 'appt_view_toggle', 'appts'\];/,
	'it names every input that changes the payload, layout included');
like($timeshift, qr/function jawnosTimelineCacheAnchored\(data\)/,
	'and anchoring is its own question');
like($timeshift, qr/!\/\(\^\|\\s\)0s\$\/\.test\(machine\)/,
	'the machine saying now anchors nothing');
like($timeshift, qr/return isFinite\(value\) && value !== 0;/,
	'while any non-zero timeshift does');
like($timeshift, qr/function jawnosTimelineCacheEligible\(record, data, now\)/,
	'eligibility joins both halves of the rule');
like($timeshift, qr/if \(jawnosTimelineCacheAnchored\(data\)\) \{ return true; \}/,
	'an anchored view is not aged');
like($timeshift, qr/return age <= jawnosTimelineCacheTTL\(record\);/,
	'a now view is held to its scope');
like($timeshift, qr/if \(age < 0\) \{ age = 0; \}/,
	'a clock that stepped back does not make a view look newer than the page');

# --- the paint and the drag path --------------------------------------------
like($timeshift, qr/function jawnosTimelineCachePaint\(data\)/,
	'the paint is callable by name, so the layout chunk can trigger it');
like($timeshift, qr/if \(!jawnosWindowsPublicNow\(null, \{ allow_private_place: true \}\)\) \{ return false; \}/,
	'a private place keeps the timeline too');
like($timeshift, qr/if \(!layout \|\| layout == 'desk'\) \{ return false; \}/,
	'the desk has no timeline to restore');
like($timeshift, qr/function jawnosTimelineCachePrinterReady\(layout\)/,
	'and the paint waits for the layout printer to exist');
like($timeshift, qr/if \(name && typeof window\[name\] !== 'function'\) \{ return false; \}/,
	'a chunk that has not arrived leaves the canvas to the server');
like($timeshift, qr/if \(!jawnosTimelineCacheRecentre\(view, Date\.now\(\)\)\) \{ return; \}/,
	'a now view must be re-centred before it is drawn');
like($timeshift, qr/if \(typeof timelinePositions == 'function'\) \{ timelinePositions\(view\['appts'\]\); \}/,
	'through the drag path\'s own positions');
like($timeshift, qr/var fields = \['timestamp', 'start', 'end', 'fetch_start'\];/,
	'the specs move with the clock');
like($timeshift, qr/server_time and stats are left alone on purpose/,
	'but the freshness markers do not');
like($timeshift, qr/graphicalize\(\{ appts: view\['appts'\], clothesline: view\['clothesline'\] \|\| \[\] \}\);/,
	'and the printers are handed the restored payload');

# --- the fetch order --------------------------------------------------------
like($timeshift, qr/jawnosTimelineCachePaint\(data\);[\s\S]{0,300}url:'\/manager\/appointment_viewer'/,
	'the cache is painted before the first fetch is sent');
like($timeshift, qr/jawnosTimelineCacheLive = 1;[\s\S]{0,160}if \(respons\.updateable != 'no'\)/,
	'a server answer stands the cache down at once');
like($timeshift, qr/graphicalize\(respons\);[\s\S]{0,200}jawnosTimelineCacheRemember\(respons, data\);/,
	'and a payload is kept only after it has been drawn');
like($timeshift, qr/if \(jawnosTimelineCachePainted \|\| jawnosTimelineCacheLive\) \{ return false; \}/,
	'one attempt a page, never over a server answer');

# --- the disk stays sealed and budgeted -------------------------------------
like($timeshift, qr/if \(!jawnosWindowsPublicNow\(null, \{ allow_private_place: true \}\)\) \{ return; \}/,
	'a private place keeps the write too; an open grant still refuses');
like($timeshift, qr/if \(!data \|\| !data\['layout'\] \|\| data\['layout'\] == 'desk'\) \{ return; \}/,
	'and the desk is never written');
like($timeshift, qr/jawnosWindowsSave\(JAWNOS_TIMELINE_CACHE_IDENTITY, \{/,
	'the view goes through the store that seals and hashes');
unlike($timeshift, qr/localStorage\.setItem\([^)]*timeline_view/,
	'nothing of the view is written to localStorage');
like($store, qr/function jawnosWindowsSeal\(key, value\)/,
	'every stored value is sealed');
like($store, qr/name: 'AES-GCM'/,
	'with AES-GCM');
like($store, qr/\+ \(value\.view \? JSON\.stringify\(value\.view\)\.length : 0\)/,
	'the view is counted against the store\'s byte budget');
like($timeshift, qr/if \(typeof jawnosWindowsPrune === 'function'\) \{ jawnosWindowsPrune\(\); \}/,
	'and pruned after it is written');
like($timeline, qr/v\[scope \+ '_percent'\] = \(v\['timestamp'\] - start\) \/ total;/,
	'the drag path recomputes percents from the specs the paint moved');

# --- the pure functions, played in a bare context ---------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is needed to play the freshness rule', 1 unless $node && -x $node;

	my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh <<'JS';
'use strict';
const fs = require('fs');
const vm = require('vm');

let failures = 0;
function check(name, ok) {
	if (!ok) { failures++; console.log('not ok: ' + name); }
}

// The file's top level only registers jQuery handlers; the rule itself is pure
// and needs nothing else.
const chain = { on() { return chain; } };
function jq() { return chain; }
jq.each = function () {};
jq.ajax = function () {};
const sandbox = {
	$: jq,
	document: {},
	localStorage: { getItem: function () { return null; }, setItem: function () {} },
	sessionStorage: { getItem: function () { return null; }, setItem: function () {} },
	moment: function () { return { format: function () { return ''; } }; },
	console: console
};
sandbox.window = sandbox;
const ctx = vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), ctx, { filename: '07_timeshift.js' });

const signature = ctx.jawnosTimelineCacheSignature;
const anchored = ctx.jawnosTimelineCacheAnchored;
const eligible = ctx.jawnosTimelineCacheEligible;
const recentre = ctx.jawnosTimelineCacheRecentre;

// --- signature --------------------------------------------------------------
const base = {
	scope: 'fifteenminute', sorts: 'timestamp', layout: 'timeline', filter: 'all',
	timeshift: '0m', time_machine: '', account: 'all', project: 'all',
	appt_view_toggle: 'off', appts: []
};
const sig = signature(base);
check('the signature ignores the clock', sig === signature(Object.assign({}, base, { timestamp: 1, now: 2, readable: 'x' })));
check('the signature ignores the decoration', sig === signature(Object.assign({}, base, { background_images: 'on', background_images_opacity: '0.4' })));
check('a layout switch is another view', sig !== signature(Object.assign({}, base, { layout: 'calendar' })));
check('a filter change is another view', sig !== signature(Object.assign({}, base, { filter: 'start' })));
check('a time machine change is another view', sig !== signature(Object.assign({}, base, { time_machine: 'in 5m' })));
check('a visible appointment set is another view', sig !== signature(Object.assign({}, base, { appts: '["me"]' })));
check('the inputs are canonical, not the object key order',
	signature({ scope: 'a', layout: 'timeline' }) === signature({ layout: 'timeline', scope: 'a' }));
check('a missing input reads as empty, like the request that named none',
	signature({ scope: 'a' }) === signature({ scope: 'a', filter: '' }));
check('an empty appointment list is a value of its own, not a missing one',
	signature({ scope: 'a', appts: [] }) !== signature({ scope: 'a' }));

// --- anchoring --------------------------------------------------------------
check('nothing pinned is a now view', anchored({ time_machine: '', timeshift: '0m' }) === false);
check('the machine saying now pins nothing', anchored({ time_machine: '0s', timeshift: '0' }) === false);
check('nor does "in 0s"', anchored({ time_machine: 'in 0s', timeshift: '0s' }) === false);
check('a named moment pins the view', anchored({ time_machine: '2024-03-01 10:00', timeshift: '0m' }) === true);
check('a zero timeshift pins nothing', anchored({ time_machine: '', timeshift: '0' }) === false);
check('a timeshift pins the view', anchored({ time_machine: '', timeshift: '30m' }) === true);
check('a negative timeshift too', anchored({ time_machine: '', timeshift: '-3h' }) === true);

// --- eligibility ------------------------------------------------------------
const view = { appts: { __specs: { timestamp: 1000000, start: 100000, end: 1900000 } } };
const record = { view: view, sig: sig, fetched_at: 1000000 };
check('no record paints nothing', eligible(null, base, 1000000) === false);
check('a view with no specs paints nothing', eligible({ view: { appts: {} }, sig: sig, fetched_at: 1000000 }, base, 1000000) === false);
check('another view is refused by its signature', eligible({ view: view, sig: 'other', fetched_at: 1000000 }, base, 1000000) === false);
check('no remembered fetch time is refused', eligible({ view: view, sig: sig }, base, 1000000) === false);
check('a now view inside the TTL paints', eligible(record, base, 1000000 + 600000) === true);
check('one millisecond past the TTL does not', eligible(record, base, 1000000 + 600001) === false);
check('a clock that stepped back still paints', eligible(record, base, 999000) === true);
// The scope is the view's own half-window: a 5m scope reaches 5m from the
// centre, a 10m scope 10m. The base view's 15m half is capped at ten, which is
// why the checks above still sit at ten minutes.
const five = { appts: { __specs: { timestamp: 1000000, start: 700000, end: 1300000 } } };
const five_record = { view: five, sig: sig, fetched_at: 1000000 };
check('a 5m scope paints on its own five minutes', eligible(five_record, base, 1000000 + 300000) === true);
check('and not a millisecond more', eligible(five_record, base, 1000000 + 300001) === false);
const ten = { appts: { __specs: { timestamp: 1000000, start: 400000, end: 1600000 } } };
const ten_record = { view: ten, sig: sig, fetched_at: 1000000 };
check('a 10m scope gets ten minutes', eligible(ten_record, base, 1000000 + 600000) === true);
check('but not eleven', eligible(ten_record, base, 1000000 + 600001) === false);
const hour = { appts: { __specs: { timestamp: 1000000, start: -2600000, end: 4600000 } } };
const hour_record = { view: hour, sig: sig, fetched_at: 1000000 };
check('an hour-long scope is capped at ten', eligible(hour_record, base, 1000000 + 600001) === false);

const pinned = Object.assign({}, base, { time_machine: '2024-03-01 10:00' });
const pinned_record = { view: view, sig: signature(pinned), fetched_at: 1000000 };
check('an anchored view is not aged by the TTL', eligible(pinned_record, pinned, 1000000 + 86400000) === true);
check('but it must still be the same anchored view',
	eligible(pinned_record, Object.assign({}, pinned, { time_machine: '2024-03-02 10:00' }), 1000000) === false);

// --- recentring -------------------------------------------------------------
const old = { appts: { __specs: { timestamp: 1000, start: 500, end: 1500, fetch_start: 250, server_time: 1000, stats: { appts: { count: 1 } } } } };
check('a view with specs is re-centred', recentre(old, 4000) === true);
check('the centre moves to now', old.appts.__specs.timestamp === 4000);
check('the left edge moves with it', old.appts.__specs.start === 3500);
check('so does the fetched right edge', old.appts.__specs.end === 4500);
check('and the fetched left edge', old.appts.__specs.fetch_start === 3250);
check('the server time is left where it was', old.appts.__specs.server_time === 1000);
check('and so are the markers', old.appts.__specs.stats.appts.count === 1);
check('a view with no specs cannot be re-centred', recentre({}, 4000) === false);

const still = { appts: { __specs: { timestamp: 4000, start: 3500 } } };
check('an unchanged clock leaves the view alone', recentre(still, 4000) === true && still.appts.__specs.timestamp === 4000);

process.exit(failures ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness" "$root/public/js/manager/manager/07_timeshift.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'the signature, anchoring, TTL and recentring hold in a bare context');
}

# --- and every touched script parses ----------------------------------------
if ($node && -x $node) {
	foreach my $file (qw(
		public/js/manager/manager/07_timeshift.js
		public/js/manager/windows/00_store.js
	)) {
		my $out = `$node --check "$root/$file" 2>&1`;
		my $rc = $? >> 8;
		diag($out) if $rc;
		is($rc, 0, "node --check accepts $file");
	}
}

done_testing();
