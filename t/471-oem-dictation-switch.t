# tests-for: lib/JawnOS/Domain/Ai.pm templates/soft_keyboard.html.ep templates/apps/help.html.ep public/js/manager/soft_keyboard/01_scroll_dictate.js public/js/manager/help/02_converse_coding_wiring.js
# covers:    When a microphone's transcription role names android:oem, the page
#           uses the app's own recogniser (window.JawnSpeech), fills the field
#           with each interim guess and settles the final text through the
#           surface's ordinary path; every other
#           value - and every WebView without the bridge - keeps the
#           record-and-POST recorder. The concrete service is resolved from the
#           role (transcription_keyboard / transcription_guide, or the shared
#           role) and rendered as a data attribute, never the role's name.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::Template;

use JawnOSTest;

my $root = root();

# ------------------------------------------------------------ the resolution
# The helper reads the surface's own row through ai_role_models, so what the
# page receives is the model value ('android:oem'), not 'transcription_keyboard'.
&subs::setting_setter({ app => 'mail', setting => 'transcription_assistant', value => 'local:whisper.cpp' });
&subs::setting_setter({ app => 'mail', setting => 'transcription_assistant_fallback', value => '' });
&subs::setting_setter({ app => 'mail', setting => 'transcription_keyboard', value => 'android:oem' });
&subs::setting_setter({ app => 'mail', setting => 'transcription_keyboard_fallback', value => '' });

is(&subs::transcription_service_for('keyboard'), 'android:oem',
	'the keyboard role resolves to the concrete OEM service');
is(&subs::transcription_service_for('guide'), 'local:whisper.cpp',
	'an unset Guide row follows the shared transcription role');

&subs::setting_setter({ app => 'mail', setting => 'transcription_guide', value => 'android:oem' });
is(&subs::transcription_service_for('guide'), 'android:oem',
	'the Guide row resolves to the OEM service when it is set');

# A surface row that is cleared hands the surface back to the shared role.
&subs::setting_setter({ app => 'mail', setting => 'transcription_keyboard', value => '' });
is(&subs::transcription_service_for('keyboard'), 'local:whisper.cpp',
	'a cleared surface row resolves through the shared role, not the role name');

# ------------------------------------------------------------ the rendered attribute
# Render the real fragments with the unit/currency registry stubbed, so the
# assertion is about the attribute the controller/fragment actually emits.
my $kb_src   = read_file("$root/templates/soft_keyboard.html.ep");
my $help_src = read_file("$root/templates/apps/help.html.ep");

sub render_keyboard {
	local *Manager::measures_all        = sub { {} };
	local *subs::kb_symbol_map          = sub { {} };
	local *subs::crypto_report_currency = sub { 'USD' };
	local *subs::crypto_enabled         = sub { 0 };
	local *subs::crypto_assets          = sub { [] };
	local *subs::crypto_fiat_table      = sub { [] };
	local *subs::icon_for               = sub { '/images/x.png' };
	local *subs::ui                     = sub { $_[0] };
	local *subs::lang                   = sub { $_[0] };
	local *subs::json_chars             = sub { '{}' };
	return Mojo::Template->new(vars => 1, auto_escape => 1)->render($kb_src, {});
}

sub render_guide {
	local *help::get              = sub { undef };
	local *help::key              = sub { '' };
	local *help::search           = sub { () };
	local *help::catalogue        = sub { () };
	local *help::render_live      = sub { '' };
	local *help::example          = sub { undef };
	local *help::shortcut_sheet   = sub { [] };
	local *help::shortcuts_for    = sub { () };
	local *subs::icon_for         = sub { '/images/x.png' };
	local *subs::ui               = sub { $_[0] };
	return Mojo::Template->new(vars => 1, auto_escape => 1)->render($help_src, {
		topic => '', search => '', selected_model => '', models => undef,
	});
}

# The keyboard fragment: android:oem while the role names it.
&subs::setting_setter({ app => 'mail', setting => 'transcription_keyboard', value => 'android:oem' });
my $kb_oem = render_keyboard();
like($kb_oem, qr/data-transcribe-service="android:oem"/,
	'the keyboard fragment renders the concrete android:oem service');
unlike($kb_oem, qr/data-transcribe-service="transcription_keyboard"/,
	'the rendered value is the service, never the role name');

# And the value follows the role: whisper.cpp does not look like the OEM.
&subs::setting_setter({ app => 'mail', setting => 'transcription_keyboard', value => 'local:whisper.cpp' });
my $kb_local = render_keyboard();
like($kb_local, qr/data-transcribe-service="local:whisper\.cpp"/,
	'the keyboard fragment renders the role\'s whisper.cpp service');
unlike($kb_local, qr/data-transcribe-service="android:oem"/,
	'a non-OEM role does not render the OEM service');

# The Guide's own box carries the same resolved value.
&subs::setting_setter({ app => 'mail', setting => 'transcription_guide', value => 'android:oem' });
my $guide_oem = render_guide();
like($guide_oem, qr/id="help_question"[^>]*data-transcribe-service="android:oem"/,
	'the Guide box renders the concrete android:oem service');
&subs::setting_setter({ app => 'mail', setting => 'transcription_guide', value => 'local:whisper.cpp' });
my $guide_local = render_guide();
like($guide_local, qr/id="help_question"[^>]*data-transcribe-service="local:whisper\.cpp"/,
	'and the role\'s whisper.cpp service when it is chosen');
unlike($guide_local, qr/data-transcribe-service="android:oem"/,
	'a non-OEM Guide role renders no OEM service');

# ------------------------------------------------------------ the JavaScript
my $kb_js   = read_file("$root/public/js/manager/soft_keyboard/01_scroll_dictate.js");
my $help_js = read_file("$root/public/js/manager/help/02_converse_coding_wiring.js");

# The keyboard: the OEM branch exists, it reads the rendered service, and it
# inserts the final phrase through the same append path the recorder uses.
like($kb_js, qr/service != 'android:oem'/, 'the keyboard names the OEM service explicitly');
like($kb_js, qr/window\.JawnSpeech/, 'the keyboard reads the app bridge');
like($kb_js, qr/jawnSpeechOemReady\(softKbTranscriptionService\(\)\)/,
	'the toggle decides from the rendered service');
like($kb_js, qr/if \(jawnSpeechOemReady\(softKbTranscriptionService\(\)\)\) \{ softKbDictateOemStart\(\); return; \}/,
	'and takes the OEM path only when that decision is true');
like($kb_js, qr/if \(!jawnSpeechOemStart\(owner\)\) \{[\s\S]*?softKbDictateBrowserStart\(\);/,
	'a bridge that cannot start hands the press to the recorder');
like($kb_js, qr/onError: function \(\) \{[\s\S]*?softKbDictateBrowserStart\(\);/,
	'a bridge error hands the press to the recorder');
like($kb_js, qr/onFinal: function \(text\) \{[\s\S]*?softKbDictationAppend\(target, text\);/,
	'the final phrase joins the field through the recorder\'s append path');
like($kb_js, qr/window\.jawnSpeechResult = function \(text, isFinal\) \{[\s\S]*?o\.onPartial\(words\)/,
	'the dispatcher hands an interim phrase to onPartial');
like($kb_js, qr/onPartial: function \(text\) \{[\s\S]*?softKbDictationPartial\(target, text\);/,
	'the keyboard shows interim words while the person speaks');
like($kb_js, qr/audio clip for Plat, no punctuation pass and no clip kept/,
	'the OEM path records that it returns text only');

# The Guide: same decision, and the recorder stays the fallback.
like($help_js, qr/jawnSpeechOemReady\(service\)/, 'the Guide decides from its rendered service');
like($help_js, qr/if \(jawnSpeechOemStart\(owner\)\) \{ \$\('#help_ask'\)\.text\('Stop'\); return; \}/,
	'the Guide uses the bridge when it starts');
like($help_js, qr/onError: function \(\) \{[\s\S]*?listen_browser\(\);/,
	'a bridge error finishes the press with the recorder');
like($help_js, qr/onFinal: function \(text\) \{[\s\S]*?jawnEchoCheck\(text, self_words\)[\s\S]*?fill\(verdict\.text\);/,
	'the final phrase reaches the callback the recorder would fill');
like($help_js, qr/onPartial: function \(text\) \{[\s\S]*?\$\('#help_question'\)\.val\(text\)/,
	'the Guide fills the box as the words arrive');
like($help_js, qr/jawnClipListen\(\{/, 'the record-and-POST listener is still there');

# (c) The decision itself, run in node: a non-OEM service and an unavailable
# bridge both keep the recorder, so a press can never be swallowed.
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is not installed; the OEM readiness harness is skipped', 7
		unless $node && -x $node;

	my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh <<'JS';
var fs = require('fs'), vm = require('vm'), path = process.argv[2];
var ctx = {
	console: console,
	window: null,
	document: {},
	$: function () { return { on: function () { return this; } }; }
};
ctx.window = ctx;
vm.createContext(ctx);
vm.runInContext(fs.readFileSync(path, 'utf8'), ctx);
var fail = 0;
function ok(cond, label) { console.log((cond ? 'ok   ' : 'FAIL ') + label); if (!cond) { fail++; } }
ctx.window.JawnSpeech = { available: function () { return true; }, start: function () {}, stop: function () {} };
ok(ctx.jawnSpeechOemReady('android:oem'), 'the OEM service with a bridge is ready');
ok(!ctx.jawnSpeechOemReady('local:whisper.cpp'), 'a non-OEM service never uses the bridge');
ok(!ctx.jawnSpeechOemReady(''), 'an empty service never uses the bridge');
ctx.window.JawnSpeech.available = function () { return false; };
ok(!ctx.jawnSpeechOemReady('android:oem'), 'a bridge reporting no recogniser is not ready');
delete ctx.window.JawnSpeech;
ok(!ctx.jawnSpeechOemReady('android:oem'), 'no bridge means the recorder answers');
process.exit(fail ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness" "$root/public/js/manager/soft_keyboard/01_scroll_dictate.js" 2>&1`;
	my $status = $? >> 8;
	my @lines = grep { /^(?:ok|FAIL)\s/ } split /\n/, $out;
	ok(scalar @lines >= 5, 'the OEM readiness harness ran')
		or diag($out);
	for my $line (@lines) {
		my ($verdict, $name) = $line =~ /^(ok|FAIL)\s+(.*)$/;
		ok($verdict eq 'ok', $name);
	}
	is($status, 0, 'the OEM readiness harness exits clean');
}

done_testing();
