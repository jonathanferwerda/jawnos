# tests-for: templates/manager.html.ep public/js/manager/manager/01_assistant_conversation.js perl/help/topics_mail.pl perl/help/topics_devices.pl
# covers:    The Guide's floating associate makes the same microphone choice as
#           the Guide's main composer: when the Guide's transcription role
#           resolves to android:oem and the WebView carries the app bridge, the
#           phone's own recogniser answers: its interim words fill the question
#           box while the person speaks (no recording is kept), and the final
#           phrase reaches assistantConversationHeard exactly as the
#           recorder's transcript does. Every other service, an absent bridge,
#           and a bridge error all keep the record-and-POST recorder. The
#           keyboard's and the Guide's help topics say the same in words.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);

use JawnOSTest;

my $root = root();

# ------------------------------------------------------------ the server-rendered attribute
# The associate's panel is server-rendered (templates/manager.html.ep), so the
# Guide's resolved service rides on its own .assistant_question textarea, the
# same value the main Guide composer renders. Spawned panels clone it, so every
# associate inherits the attribute.
my $manager = read_file("$root/templates/manager.html.ep");
like($manager,
	qr/<textarea class="assistant_question"[^>]*data-transcribe-service="<%= &subs::transcription_service_for\('guide'\) %>"/,
	'the associate composer renders the Guide\'s resolved service');
unlike($manager,
	qr/<textarea class="assistant_question"[^>]*data-transcribe-service="android:oem"/,
	'the attribute is the resolved service, never a hard-coded OEM value');

# ------------------------------------------------------------ the JavaScript shape
my $assoc = read_file("$root/public/js/manager/manager/01_assistant_conversation.js");

like($assoc, qr/function assistantTranscriptionService\(panel\)[\s\S]*?data-transcribe-service/,
	'the associate reads its rendered transcription service');
like($assoc, qr/jawnSpeechOemReady\(service\)/,
	'the associate asks the shared dispatcher whether the bridge may answer');
like($assoc, qr/if \(jawnSpeechOemStart\(owner\)\) \{ return; \}/,
	'and starts the phone recogniser when it may');
like($assoc, qr/onFinal: function \(text\) \{[\s\S]*?assistantConversationHeard\(panel, verdict\.text\);/,
	'the final phrase joins the turn through the recorder\'s own callback');
like($assoc, qr/onError: function \(\) \{[\s\S]*?listen_browser\(\);/,
	'a bridge error finishes the turn with the recorder');
like($assoc, qr/if \(typeof jawnClipListen !== 'function'\) \{ return; \}[\s\S]*?jawnClipListen\(\{/,
	'the record-and-POST listener is still there as the fallback');
like($assoc, qr/jawnEchoCheck\(text, self_words\)/,
	'the OEM text is checked for the Guide\'s own spoken reply, like the recorder path');
like($assoc, qr/jawnSpeechOemStop\(oem\)/,
	'ending the conversation stops the associate\'s OEM turn');

# One dispatcher, not two: the associate must reuse the callbacks installed by
# the soft keyboard, and installing a second pair would clobber the first.
unlike($assoc, qr/window\.jawnSpeechState\s*=/, 'the associate installs no second state callback');
unlike($assoc, qr/window\.jawnSpeechResult\s*=/, 'the associate installs no second result callback');
unlike($assoc, qr/function jawnSpeechOemInstall/, 'the associate does not re-install the dispatcher');

# ------------------------------------------------------------ the decision, run in node
# A small harness: the real file is loaded with the bridge stubbed, then each
# service/bridge combination is asked which path it takes.
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is not installed; the associate OEM harness is skipped', 9
		unless $node && -x $node;

	my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh <<'JS';
var fs = require('fs'), vm = require('vm');
var path = process.argv[2];
var fail = 0;
function ok(cond, label) { console.log((cond ? 'ok   ' : 'FAIL ') + label); if (!cond) { fail++; } }

function jq() { return { on: function () { return this; } }; }
jq.trim = function (s) { return String(s == null ? '' : s).trim(); };

var ctx = {
	console: console,
	window: null,
	document: {},
	setTimeout: function (fn) { fn(); return 0; },
	jawnos_lang_code: 'en-US',
	$: jq,
	__service: '', __ready: true, __start: true,
	__startedWith: null, __recorder: 0, __heard: null, __stopped: null
};
ctx.window = ctx;
ctx.jawnSpeechOemReady = function (service) { return ctx.__ready && service === 'android:oem'; };
ctx.jawnSpeechOemStart = function (owner) { if (!ctx.__start) { return false; } ctx.__startedWith = owner; return true; };
ctx.jawnSpeechOemStop = function (owner) { ctx.__stopped = owner; };
ctx.jawnClipListen = function (opts) { ctx.__recorder += 1; ctx.__recorderOpts = opts; return true; };
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path, 'utf8'), ctx);

// capture only the insertion path; the real one calls into manager.js
ctx.assistantConversationHeard = function (panel, text) { ctx.__heard = text; };

var store = {};
var box = {
	length: 1,
	attr: function (n) { return n === 'data-transcribe-service' ? ctx.__service : undefined; },
	val: function (v) { if (arguments.length) { ctx.__partial = v; return this; } return ctx.__partial; }
};
var empty = { length: 0, attr: function () { return undefined; } };
var panel = {
	0: {},
	attr: function (n) { return n === 'talking' ? 'yes' : undefined; },
	find: function (sel) { return sel === '.assistant_question' ? box : empty; },
	data: function (n, v) { if (arguments.length > 1) { store[n] = v; return this; } return store[n]; },
	removeData: function (n) { delete store[n]; return this; }
};

// 1. android:oem with a bridge starts the phone recogniser, not the recorder.
ctx.__service = 'android:oem'; ctx.__ready = true; ctx.__start = true;
ctx.__startedWith = null; ctx.__recorder = 0; ctx.__heard = null; ctx.__stopped = null;
ctx.assistantConversationListen(panel);
ok(ctx.__startedWith && ctx.__recorder === 0, 'android:oem with a bridge starts the phone recogniser');

// 2. its final phrase goes through the recorder's own insertion callback.
ctx.__partial = null;
ctx.__startedWith.onPartial('hello');
ok(ctx.__partial === 'hello', 'interim words fill the composer as they arrive');
ctx.__startedWith.onFinal('hello there');
ok(ctx.__heard === 'hello there', 'the final phrase reaches the recorder\'s insertion path');
ok(ctx.__stopped === ctx.__startedWith, 'the OEM turn is stopped before the phrase is handled');

// 3. a bridge error hands this turn to the recorder.
ctx.__recorder = 0;
ctx.__startedWith.onError();
ok(ctx.__recorder === 1, 'a bridge error hands the turn to the recorder');

// 4. a non-OEM role keeps the recorder.
ctx.__service = 'local:whisper.cpp'; ctx.__startedWith = null; ctx.__recorder = 0;
ctx.assistantConversationListen(panel);
ok(ctx.__startedWith === null && ctx.__recorder === 1, 'a non-OEM service uses the recorder');

// 5. an unavailable recogniser keeps the recorder.
ctx.__service = 'android:oem'; ctx.__ready = false; ctx.__startedWith = null; ctx.__recorder = 0;
ctx.assistantConversationListen(panel);
ok(ctx.__startedWith === null && ctx.__recorder === 1, 'an unavailable bridge uses the recorder');

// 6. a bridge that cannot start keeps the recorder.
ctx.__service = 'android:oem'; ctx.__ready = true; ctx.__start = false; ctx.__startedWith = null; ctx.__recorder = 0;
ctx.assistantConversationListen(panel);
ok(ctx.__recorder === 1, 'a bridge that cannot start hands the turn to the recorder');

process.exit(fail ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness" "$root/public/js/manager/manager/01_assistant_conversation.js" 2>&1`;
	my $status = $? >> 8;
	my @lines = grep { /^(?:ok|FAIL)\s/ } split /\n/, $out;
	ok(scalar @lines >= 7, 'the associate OEM harness ran') or diag($out);
	for my $line (@lines) {
		my ($verdict, $name) = $line =~ /^(ok|FAIL)\s+(.*)$/;
		ok($verdict eq 'ok', $name);
	}
	is($status, 0, 'the associate OEM harness exits clean');
}

# ------------------------------------------------------------ the help topics
# The rule: a microphone change updates its topic in the same change. Both
# surfaces say the phone's recogniser may answer, that its words fill the field
# as the person speaks, and that every other choice records and sends the clip.
my $mail_help    = read_file("$root/perl/help/topics_mail.pl");
my $devices_help = read_file("$root/perl/help/topics_devices.pl");

ok(index($mail_help, "When the keyboard\\'s transcription role is set to Android on-device") >= 0,
	'the keyboard topic names the Android on-device choice');
ok(index($mail_help, 'the words appear in the field as you speak and settle on the final phrase, so no recording is kept') >= 0,
	'and says the phone recogniser fills the field as you speak and keeps no recording');
ok(index($mail_help, "any other choice, or a machine without the phone\\'s recogniser, records the phrase and sends the clip to the house as above") >= 0,
	'and that every other choice still records and sends the clip');
ok(index($mail_help, "When the keyboard\\'s role is set to Android on-device under Configure -> Plat, the phone\\'s own recogniser answers instead - the words fill the field as you speak and settle on the final phrase, with no recording kept") >= 0,
	'the keyboard step says the same in the on-screen words');

ok(index($devices_help, "the phone\\'s own recogniser answers the microphone instead: the words appear in the box as you speak and settle on the final transcript, and no recording is kept") >= 0,
	'the Guide topic says the phone recogniser fills the box as you speak and keeps no recording');
ok(index($devices_help, "Any other choice, or a machine without the phone\\'s recogniser, records the clip and sends it to the house as before") >= 0,
	'and that every other choice still records and sends the clip');
like($devices_help, qr/app => 'help',[\s\S]{0,600}?verified => '2026-11-27'/,
	'the Guide topic was re-vetted with the change');

done_testing();
