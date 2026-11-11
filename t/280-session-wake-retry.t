# tests-for: public/js/universal/02_settings_ajax_hidden.js
# covers:    the first request a woken WebView sends can beat its cookie store,
#           so the server sees no cookie and answers the Gate with a 401. The
#           page retries that request quietly (twice) instead of reloading,
#           which keeps an open window, a playing track and a drawing; only a
#           repeated 401 is a real lapse and reloads once.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempfile);
use RepoSource;

my $root = repo_root();
my $js = "$root/public/js/universal/02_settings_ajax_hidden.js";

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
plan skip_all => 'node is needed to exercise the session-wake retry'
	unless $node && -x $node;

my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
print $fh <<'JS';
const fs = require('fs');
const vm = require('vm');

const source = process.argv[2];
let fails = 0;
function ok(cond, name) {
	if (cond) { console.log('ok - ' + name); }
	else { fails++; console.log('not ok - ' + name); }
}

let errorHandler = null;
let prefilter = null;
const ajaxCalls = [];
const timers = [];
let reloads = 0;

function el() {
	const o = {};
	['on','each','is','attr','hasClass','closest','val','text','show','hide',
	 'find','removeAttr','html','css','fadeOut','trigger'].forEach(function (k) {
		o[k] = function () { return o; };
	});
	o.length = 0;
	return o;
}
function $(x) { return el(); }
$.each = function (a, f) {
	if (a && a.forEach) { a.forEach(function (v, i) { f(i, v); }); }
	return a;
};
$.extend = function (t) {
	for (let i = 1; i < arguments.length; i++) {
		const s = arguments[i] || {};
		for (const k in s) {
			if (Object.prototype.hasOwnProperty.call(s, k)) { t[k] = s[k]; }
		}
	}
	return t;
};
$.ajaxSetup = function (o) { errorHandler = o.error; };
$.ajaxPrefilter = function (f) { prefilter = f; };
$.ajax = function (o) {
	ajaxCalls.push(o);
	return { fail: function () { return this; } };
};

const store = {
	getItem: function () { return null; },
	setItem: function () {}
};
const sandbox = {
	$: $,
	console: { log: function () {} },
	document: {
		addEventListener: function () {},
		getElementById: function () { return null; },
		hidden: false
	},
	window: { __jawnSessionReloading: false },
	location: { reload: function () { reloads++; } },
	navigator: { userAgent: 'test' },
	localStorage: store,
	sessionStorage: store,
	numeral: function () { return { value: function () { return 0; } }; },
	moment: function () { return { format: function () { return ''; } }; },
	bti: 'tab',
	bt: 'tab',
	signatorial: null,
	setTimeout: function (fn, ms) { timers.push({ fn: fn, ms: ms }); return timers.length; },
	clearTimeout: function () {}
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(source, 'utf8'), sandbox);

ok(typeof prefilter === 'function', 'the request prefilter is installed');
ok(typeof errorHandler === 'function', 'the global ajax error handler is installed');

const options = { url: '/manager/poll', type: 'GET', data: 'a=1' };
const jq = {};
prefilter(options, {}, jq);
ok(jq.jawnos_url === '/manager/poll', 'the url is stashed for the error message');
ok(jq.jawnos_options && jq.jawnos_options.url === '/manager/poll',
	'the request is copied so it can be sent again');
ok((jq.jawnos_auth_retry | 0) === 0, 'a first request is not marked as a retry');
options.url = '/manager/changed';
ok(jq.jawnos_options.url === '/manager/poll',
	'the copy is taken before jQuery appends a GET or the page mutates it');

const first = {
	status: 401,
	jawnos_url: '/manager/poll',
	jawnos_options: { url: '/manager/poll', type: 'GET', data: 'a=1' },
	jawnos_auth_retry: 0
};
errorHandler(first, 'error', 'Unauthorized');
ok(timers.length === 1 && timers[0].ms === 900,
	'the first 401 waits a moment before the retry');
ok(reloads === 0, 'and does not reload the page');
timers.shift().fn();
ok(ajaxCalls.length === 1 && ajaxCalls[0].url === '/manager/poll',
	'the same request is sent again');
ok(ajaxCalls[0].jawnos_auth_retry === 1, 'the retry is marked, so it cannot loop');

const second = {
	status: 401,
	jawnos_url: '/manager/poll',
	jawnos_options: { url: '/manager/poll' },
	jawnos_auth_retry: 1
};
errorHandler(second, 'error', 'Unauthorized');
ok(timers.length === 1 && timers[0].ms === 2500,
	'a second 401 waits longer before the last retry');
timers.shift().fn();
ok(ajaxCalls.length === 2 && ajaxCalls[1].jawnos_auth_retry === 2,
	'the second retry is marked');

const third = {
	status: 401,
	jawnos_url: '/manager/poll',
	jawnos_options: { url: '/manager/poll' },
	jawnos_auth_retry: 2
};
errorHandler(third, 'error', 'Unauthorized');
ok(reloads === 0 && timers.length === 1 && timers[0].ms === 400,
	'a repeated 401 schedules the one reload');
timers.shift().fn();
ok(reloads === 1, 'and reloads once');
ok(sandbox.window.__jawnSessionReloading === true,
	'the reload cannot be scheduled twice');

errorHandler(third, 'error', 'Unauthorized');
ok(timers.length === 0 && reloads === 1,
	'a further 401 while reloading does nothing');

process.exit(fails ? 1 : 0);
JS
close $fh;

my $out = `$node "$harness" "$js" 2>&1`;
my $rc = $? >> 8;
diag($out) if $rc;
is($rc, 0, 'a woken client retries its request instead of reloading the page');

done_testing();
