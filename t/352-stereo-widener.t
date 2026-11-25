# tests-for: perl/gb/05_abilities_and_studio.pl public/js/manager/studio/08_effects.js public/js/manager/studio/10_master.js engine/src/effect.rs t/352-stereo-widener.t
# covers:    Stereo Widener is one effect in the browser's pedalboard and master
#            rack and nothing in the native engine: the contract names it and its
#            two controls, the palette offers it with the default drawn body, and
#            the master rack holds it after the equaliser and before the reverb.
#            The builder is a real mid/side matrix (mid = (L+R)/2, side =
#            (L-R)/2, Width 0..2 at 50 = 1, Mix 0..1 at 50 = 0.5) with two sums
#            back to L and R, wired into the same shell as every other pedal. Its
#            graph is run under node, so a mono source is pinned as finite,
#            centred and unchanged, and a stereo one widens by Width. The engine
#            documents the omission instead of faking a mono widener, and no
#            knob of it is ever posted to a take.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $studio = read_file("$root/perl/gb/05_abilities_and_studio.pl");
my $fx     = read_file("$root/public/js/manager/studio/08_effects.js");
my $master = read_file("$root/public/js/manager/studio/10_master.js");
my $engine = read_file("$root/engine/src/effect.rs");

# --- the contract: one effect, two controls ---------------------------------
my ($effects) = $studio =~ /effects\s*=>\s*\{(.*?)\n\t\},\n\t#/s;
ok(defined $effects, 'the studio data carries the effect contract');
like($effects // '', qr/\bstereowidener\s*=>\s*\{\s*label\s*=>\s*'Stereo Widener',/,
	'the contract names the Stereo Widener');
my ($sw) = ($effects // '') =~ /stereowidener\s*=>\s*\{(.*?)\n\t\t\]\s*\}/s;
ok(defined $sw, 'the widener has a control list');
like($sw // '', qr/\{\s*control\s*=>\s*'width',\s*label\s*=>\s*'Width'\s*\}/,
	'it has a Width control');
like($sw // '', qr/\{\s*control\s*=>\s*'mix',\s*label\s*=>\s*'Mix'\s*\}/,
	'it has a Mix control');

# --- the palette ------------------------------------------------------------
my ($palette) = $studio =~ /palette\s*=>\s*\[\s*qw\(([^)]*)\)\s*\]/s;
my @palette = split ' ', ($palette // '');
my $contract = [ qw(reverb flanger fuzz amp limiter tremolo stereo_panner autotune equalizer tone distortion delay compressor) ];
is_deeply(\@palette, [ @$contract, 'stereowidener' ],
	'the palette keeps every existing effect and appends the widener');
unlike($studio, qr/palette_art\s*=>\s*\{[^}]*stereowidener/s,
	'the widener takes the default drawn body rather than invented artwork');

# --- the master rack --------------------------------------------------------
my ($master_list) = $studio =~ /master\s*=>\s*\[(.*?)\n\t\]/s;
ok(defined $master_list, 'the studio data carries the master rack');
my @master_names = ($master_list // '') =~ /name\s*=>\s*'(master_[a-z0-9_]+)'/g;
is_deeply(\@master_names,
	[ qw(master_comp master_eq master_stereowidener master_reverb master_maximizer master_limiter) ],
	'the rack holds the widener after the equaliser and before the reverb');
like($master_list // '', qr/name\s*=>\s*'master_stereowidener',\s*label\s*=>\s*'Stereo Widener',/,
	'the master slot carries the label people read');
my ($master_sw) = ($master_list // '') =~ /'master_stereowidener'.*?controls\s*=>\s*\[(.*?)\]/s;
like($master_sw // '', qr/control\s*=>\s*'width'.*?control\s*=>\s*'mix'/s,
	'the master slot carries Width then Mix');

# The page's fallback order is the same table, in the same position.
my ($order_src) = $master =~ /var studioMasterOrder = \[([^\]]*)\]/;
my @order = ($order_src // '') =~ /'([^']+)'/g;
is_deeply(\@order, \@master_names, '10_master.js keeps the contract\'s master order');

# --- the builder: a real mid/side matrix ------------------------------------
like($fx, qr/^function studioEffectStereoWidener\(ctx, name\)/m,
	'the builder takes a context and a name');
like($fx, qr/\bcreateChannelSplitter\(2\)/, 'the matrix splits the stereo pair');
like($fx, qr/\bcreateChannelMerger\(2\)/, 'and merges the two sums back');
like($fx, qr/var mid = ctx\.createGain\(\);\s*\n\s*mid\.gain\.value = 0\.5;/,
	'mid is (L + R) / 2');
like($fx, qr/var side = ctx\.createGain\(\);\s*\n\s*side\.gain\.value = 0\.5;/,
	'side is (L - R) / 2');
like($fx, qr/var minus = ctx\.createGain\(\);\s*\n\s*minus\.gain\.value = -1;/,
	'the right channel is subtracted for the side signal');
like($fx, qr/fx\.setters\['width'\] = function \(v\) \{ width\.gain\.value = studioEffectNatural\(fx\.name, 'width', v\); \};/,
	'Width scales the side gain');
like($fx, qr/fx\.setters\['mix'\] = function \(v\) \{[\s\S]*?wetGain\.gain\.value = n;[\s\S]*?dryGain\.gain\.value = 1 - n;/,
	'Mix blends the matrix with the dry signal');
like($fx, qr/case 'stereowidener\.width':\s*\n\s*return amount \* 2;/,
	'Width maps the 0..100 slider to a 0..2 gain');
like($fx, qr/fx\.set\('width', 50\);\s*\n\s*fx\.set\('mix', 50\);/, 'both controls start at 50');
like($fx, qr/\bstereowidener\s*:\s*studioEffectStereoWidener/, 'the builder table registers it');
like($fx, qr/\bmaster_stereowidener\s*:\s*'stereowidener'/, 'the master alias resolves to the same kind');
like($fx, qr/\bstereowidener\s*:\s*'stereowidener'/, 'the palette name resolves to its own kind');

# --- the engine is never asked about it -------------------------------------
like($fx, qr/function studioEngineParamPost\(data, key\) \{(.*?)\n\tif \(!studioEngineIsPath/s,
	'the engine post is the one gate every knob goes through');
my ($gate) = $fx =~ /function studioEngineParamPost\(data, key\) \{(.*?)\n\tif \(!studioEngineIsPath/s;
like($gate // '', qr/\(\?:master_\)\?\(\?:stereowidener\|stereo_panner\)/, 'the gate refuses both browser-only panners');
like($gate // '', qr/return;/, 'and posts nothing for them');

# --- the engine documents the omission --------------------------------------
like($engine, qr/Stereo Widener is browser only/, 'the engine says the widener is browser only');
like($engine, qr/an \[`Effect`\] is a mono processor|insert never holds an L\/R pair/,
	'and names the reason: an insert is a mono processor');
like($engine, qr/InsertKind::parse\("stereowidener"\), None/, 'parsing the track name gives no kind');
like($engine, qr/InsertKind::parse\("master_stereowidener"\), None/, 'parsing the rack name gives no kind');

# --- every existing effect is still named the same way ----------------------
for my $name (@$contract) {
	like($effects // '', qr/\b\Q$name\E\s*=>\s*\{\s*label\s*=>\s*'/, "the contract still names $name");
	like($fx, qr/^\t\Q$name\E\s*:\s*'[a-z_]+',$/m, "the alias table still maps $name");
}

# --- the maths, under node --------------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;

SKIP: {
	skip 'node is not installed', 20 unless $node && -x $node;

	my $harness = <<'JS';
var fs = require('fs'), vm = require('vm');
var code = fs.readFileSync(process.argv[2], 'utf8');

// A tiny memoryless Web Audio stand-in: every node in the widener is a single
// gain stage, a splitter or a merger, so one sample per channel is enough to
// read the graph the builder actually wired.
var conns = [], ids = 0;
function makeNode(kind) {
	var n = {
		kind: kind, id: ids++,
		channelCount: 2, channelCountMode: 'max', channelInterpretation: 'speakers',
		connect: function (to, out, inp) {
			conns.push({ from: n, out: out || 0, to: to, inp: inp || 0 });
			return to;
		},
		disconnect: function () {}
	};
	return n;
}
var ctx = {
	createGain: function () { var n = makeNode('gain'); n.gain = { value: 1 }; return n; },
	createChannelSplitter: function (count) {
		var n = makeNode('split');
		n.count = count; n.channelCount = count;
		n.channelCountMode = 'explicit'; n.channelInterpretation = 'discrete';
		return n;
	},
	createChannelMerger: function (count) {
		var n = makeNode('merge');
		n.count = count; n.channelCount = 1; n.channelCountMode = 'explicit';
		return n;
	}
};
function fit(sig, n) {
	var want;
	if (n.channelCountMode === 'explicit') { want = n.channelCount; }
	else if (n.channelCountMode === 'clamped-max') { want = Math.min(n.channelCount, sig.length); }
	else { want = sig.length; }
	if (want === sig.length) { return sig; }
	var out = [], i;
	if (n.channelInterpretation === 'discrete') {
		for (i = 0; i < want; i++) { out.push(i < sig.length ? sig[i] : 0); }
		return out;
	}
	if (want === 1) {
		var sum = 0;
		for (i = 0; i < sig.length; i++) { sum += sig[i]; }
		return [sum / sig.length];
	}
	for (i = 0; i < want; i++) { out.push(i < sig.length ? sig[i] : sig[0]); }
	return out;
}
function inputSig(n, index, memo) {
	var sum = null;
	for (var i = 0; i < conns.length; i++) {
		var c = conns[i];
		if (c.to !== n || c.inp !== index) { continue; }
		var s = output(c.from, c.out, memo);
		if (!sum) { sum = s.slice(); continue; }
		var len = Math.max(sum.length, s.length), next = [];
		for (var j = 0; j < len; j++) {
			next.push((sum.length === 1 ? sum[0] : (sum[j] || 0))
				+ (s.length === 1 ? s[0] : (s[j] || 0)));
		}
		sum = next;
	}
	if (!sum) { return [0]; }
	return fit(sum, n);
}
function output(n, index, memo) {
	var key = n.id + ':' + index;
	if (Object.prototype.hasOwnProperty.call(memo, key)) { return memo[key]; }
	var out;
	if (n.kind === 'source') { out = n.sig; }
	else if (n.kind === 'split') {
		var inp = inputSig(n, 0, memo);
		out = [index < inp.length ? inp[index] : 0];
	}
	else if (n.kind === 'merge') {
		out = [];
		for (var c = 0; c < n.count; c++) { out.push(inputSig(n, c, memo)[0]); }
	}
	else {
		var sig = inputSig(n, 0, memo);
		out = sig.map(function (v) { return v * n.gain.value; });
	}
	memo[key] = out;
	return out;
}
function feed(fx, sig) {
	var src = makeNode('source');
	src.sig = sig;
	src.connect(fx.input);
	var out = output(fx.output, 0, {});
	conns.pop();
	return out;
}

var timers = 0;
var sandbox = {
	console: console, Math: Math, Float32Array: Float32Array, isFinite: isFinite,
	setTimeout: function () { timers++; return timers; }, clearTimeout: function () {},
	jawnosT: function (s) { return s; },
	window: {}, document: {}, $: function () { return {}; }
};
vm.createContext(sandbox);
vm.runInContext(code, sandbox);

// The engine gate: no knob of either spelling may reach a take.
sandbox.studioEngineRecording = true;
sandbox.studioEngineParamPost({ action: 'param', track: 0, name: 'stereowidener.width', value: 1 }, 'a');
console.log('guardinsert ' + (timers === 0 ? 'quiet' : 'sent'));
sandbox.studioEngineParamPost({ action: 'param', target: 'master', name: 'master_stereowidener.bypass', value: 1 }, 'b');
console.log('guardmaster ' + (timers === 0 ? 'quiet' : 'sent'));
sandbox.studioEngineParamPost({ action: 'param', track: 0, name: 'flanger.rate', value: 1 }, 'c');
console.log('guardother ' + (timers === 1 ? 'sent' : 'quiet'));

var build = sandbox.studioEffectBuilder('master_stereowidener');
console.log('builder ' + (typeof build === 'function' ? 'present' : 'missing'));
console.log('alias ' + (sandbox.studioEffectKind('master_stereowidener') === 'stereowidener' ? 'ok' : 'bad'));

var fx = build(ctx, 'master_stereowidener');
console.log('name ' + fx.name);
console.log('contract ' + (fx.input && fx.output && typeof fx.set === 'function'
	&& typeof fx.setBypass === 'function' && fx.values ? 'ok' : 'bad'));
console.log('values ' + fx.values.width + ' ' + fx.values.mix);
fx.set('width', 25);
console.log('stored ' + fx.values.width);

function run(label, sig, width, mix, bypass) {
	fx.setBypass(!!bypass);
	fx.set('width', width);
	fx.set('mix', mix);
	var out = feed(fx, sig);
	console.log(label + ' ' + out.map(function (v) { return v.toFixed(4); }).join(' ')
		+ ' ' + (out.every(function (v) { return isFinite(v); }) ? 'finite' : 'broken'));
}
run('mono', [0.5], 100, 100);
run('mono0', [0.5], 0, 100);
run('mono50', [0.5], 100, 50);
run('stereoid', [1, 0], 50, 100);
run('stereowide', [1, 0], 100, 100);
run('stereomono', [1, 0], 0, 100);
run('stereodry', [1, 0], 50, 0);
run('stereohalf', [1, 0], 50, 50);
run('stereobypass', [1, 0], 100, 100, true);
JS

	my ($hh, $harness_file) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $hh $harness;
	close $hh;
	my $part = "$root/public/js/manager/studio/08_effects.js";
	my @out = split /\n/, `"$node" "$harness_file" "$part" 2>&1`;
	my %r;
	for my $line (@out) {
		my ($name, @rest) = split ' ', $line;
		next unless defined $name;
		$r{$name} = \@rest;
	}
	ok(scalar(keys %r) >= 16, 'the harness read the builder and every case answered')
		or diag join("\n", @out);

	# The engine gate.
	is(($r{'guardinsert'} || [])->[0], 'quiet', 'a track width knob is never posted to a take');
	is(($r{'guardmaster'} || [])->[0], 'quiet', 'a rack bypass is never posted either');
	is(($r{'guardother'} || [])->[0], 'sent', 'a supported effect still reaches the engine');
	is(($r{'builder'} || [])->[0], 'present', 'the master alias builds an effect');
	is(($r{'alias'} || [])->[0], 'ok', 'master_stereowidener is the stereowidener kind');
	is(($r{'name'} || [])->[0], 'master_stereowidener', 'the insert keeps the name it was asked for');
	is(($r{'contract'} || [])->[0], 'ok', 'it is a node with input, output, values, set and setBypass');
	is(join(' ', @{ $r{'values'} || [] }), '50 50', 'Width and Mix both start at 50');
	is(($r{'stored'} || [])->[0], 25, 'values carries the value the UI passed');

	# The matrix, as numbers.
	my @mono = @{ $r{'mono'} // [] };
	is(($r{'mono'} || [])->[2], 'finite', 'a mono source stays finite at Width 100');
	ok(@mono >= 2 && abs($mono[0] - 0.5) < 1e-6 && abs($mono[1] - 0.5) < 1e-6,
		'a mono source is unchanged and centred at Width 100');
	ok(defined($r{'mono0'}) && abs($r{'mono0'}->[0] - 0.5) < 1e-6 && abs($r{'mono0'}->[1] - 0.5) < 1e-6,
		'and still centred with Width at 0');
	ok(defined($r{'mono50'}) && abs($r{'mono50'}->[0] - 0.5) < 1e-6 && abs($r{'mono50'}->[1] - 0.5) < 1e-6,
		'and with the Mix half dry');
	ok(defined($r{'stereoid'}) && abs($r{'stereoid'}->[0] - 1) < 1e-6 && abs($r{'stereoid'}->[1]) < 1e-6,
		'Width 50 leaves a stereo pair exactly as it was');
	ok(defined($r{'stereowide'}) && abs($r{'stereowide'}->[0] - 1.5) < 1e-6 && abs($r{'stereowide'}->[1] + 0.5) < 1e-6,
		'Width 100 doubles the side: L 1.5 and R -0.5 from L 1, R 0');
	ok(defined($r{'stereomono'}) && abs($r{'stereomono'}->[0] - 0.5) < 1e-6 && abs($r{'stereomono'}->[1] - 0.5) < 1e-6,
		'Width 0 folds a stereo pair to its centre');
	ok(defined($r{'stereodry'}) && abs($r{'stereodry'}->[0] - 1) < 1e-6 && abs($r{'stereodry'}->[1]) < 1e-6,
		'Mix 0 is the dry signal');
	ok(defined($r{'stereohalf'}) && abs($r{'stereohalf'}->[0] - 1) < 1e-6 && abs($r{'stereohalf'}->[1]) < 1e-6,
		'Mix 50 at Width 50 is still the untouched image');
	ok(defined($r{'stereobypass'}) && abs($r{'stereobypass'}->[0] - 1) < 1e-6
		&& abs($r{'stereobypass'}->[1]) < 1e-6 && $r{'stereobypass'}->[2] eq 'finite',
		'the footswitch opens the dry path in place');
}

done_testing();
