# tests-for: lib/JawnOS/Domain/Format.pm perl/Music.pl perl/Music/ perl/help.pl perl/help/ perl/language.pl perl/language/ public/css/music.css public/js/music.js templates/
# covers:    A remote output that is down used to stay enabled forever: the saved setting still said on, so the stream kept...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource;

# A remote output that is down used to stay enabled forever: the saved setting
# still said on, so the stream kept reopening a peer that would never answer and
# the user was stuck broadcasting to a dead room. This test pins the bounded
# auto-off decision (a momentary stall must not trip it, the local 'me' output
# must never be turned off, and the save must go through the Audio drawer's own
# endpoint) and the live broadcasting indicator under the search box.

my $root = repo_root();
my $js = read_file("$root/public/js/music.js");
my $template = read_file("$root/templates/apps/music/music.html.ep");
my $css = read_file("$root/public/css/music.css");
my $music = music_source();
my $language = language_source();
my $help = help_source();

# --- the decision is a pure function a test can pin -------------------------
my ($cfg) = $js =~ /(var musicOutputOff = \{[^\n]*\};)/;
ok(defined $cfg, 'the auto-off thresholds are a named constant');
my ($fn) = $js =~ /(function musicOutputAutoOff\(key, rec, now\) \{.*?\n\})/s;
ok(defined $fn, 'the auto-off decision is a pure function');

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
my $have_node = ($node && -x $node) ? 1 : 0;

if ($have_node && $cfg && $fn) {
	my ($fh, $tmp) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh "$cfg\n$fn\n";
	print $fh <<'JS';
var now = 1000000;
var cases = [
	['me',                    { fails: 9, first: 0, hard: 9 }, false],
	['srv',                   { fails: 9, first: 0, hard: 9 }, false],
	['127.0.0.1',             { fails: 9, first: 0, hard: 9 }, false],
	['plainhost',             { fails: 9, first: 0, hard: 9 }, false],
	['kitchen.home',          null, false],
	['kitchen.home',          { fails: 1, first: now - 60000, hard: 0 }, false],
	['kitchen.home',          { fails: 3, first: now - 5000, hard: 0 }, false],
	['kitchen.home',          { fails: 3, first: now - 15000, hard: 0 }, true],
	['kitchen.home',          { fails: 2, first: now - 1000, hard: 1 }, false],
	['kitchen.home',          { fails: 2, first: now - 1000, hard: 2 }, true]
];
var out = cases.map(function (c) { return musicOutputAutoOff(c[0], c[1], now); });
process.stdout.write(JSON.stringify(out));
JS
	close $fh;
	my $got = `$node "$tmp" 2>&1`;
	chomp $got if defined $got;
	is($got, '[false,false,false,false,false,false,false,true,false,true]',
		'auto-off: a stall needs 3 tries over 15s, a definitive refusal 2, and Me/Srv never');
}
else {
	SKIP: { skip 'node or the pure function is not available', 1; }
}

# --- the rest of the auto-off path ------------------------------------------
like($js, qr/if \(musicOutputAutoOff\(key, rec, now\)\) \{ musicOutputTurnOff\(key, rec, why\); return; \}/,
	'a failed output is handed to the turn-off path');
like($js, qr/url: '\/music\/audio_output_select',\s*\n\s*type: 'POST',\s*\n\s*data: \{ state: 'off', output: key \}/,
	'the output is saved through the Audio drawer\'s own endpoint, not the database');
like($music, qr{post\('/music/audio_output_select'},
	'that endpoint is the one the manager serves');
like($js, qr/musicStreamSendJson\(\{ type: 'sync_report', event: 'output_off'/, 
	'the turn-off is written to the stream log');
like($js, qr/if \(rec\) \{ rec\.off = 1; musicStream\.links\[key\] = rec; \}/,
	'the turn-off keeps the reason on the drawer pill');
like($js, qr/if \(!musicOutputOn\(mao\[key\]\)\) \{ return \(rec && rec\.off\) \? 'unreachable' : 'off'; \}/,
	'a turned-off output keeps showing as unreachable, not as a plain off');
like($js, qr/delete musicStream\.links\[output\]/,
	'a person turning an output on clears the old failure evidence');
like($js, qr/if \(!musicStreamOutputStillOn\(key\)\) \{ musicStreamPaint\(\); return; \}/,
	'only an output that is still enabled collects failures');
like($js, qr/if \(!musicStream\.active \|\| musicStream\.paused\) \{ musicStreamPaint\(\); return; \}/,
	'a paused stream does not collect evidence that could turn an output off');
like($js, qr/function musicStreamOutputReady\(key\) \{\s*\n\s*delete musicStream\.retry\[key\];\s*\n\s*delete musicStream\.links\[key\];/,
	'a successful start clears the failure record, so a stall does not accumulate');

# --- the live broadcasting indicator ----------------------------------------
like($template, qr/id="music_broadcast"/, 'the Music window carries a broadcasting pill');
like($template, qr/#music_search_wrap|<span id="music_search_wrap">/, 'the search box is present');
like($template, qr/<span id="music_library_name"[^\n]*\n[\s\S]{0,400}?id="music_broadcast"/,
	'the pill sits under the search box, beside the library name');
like($template, qr/&subs::lang\('music\.broadcasting'\)/,
	'its label is a translatable core label');
like($js, qr/function musicBroadcastPaint\(\)/, 'the pill is painted from JS');
like($js, qr/var on = !!\(musicStream\.active && !musicStream\.paused && outs\.length\);/,
	'it is shown only while a remote stream is actually being sent');
like($js, qr/if \(musicStream\.ready\[outs\[i\]\]\) \{ live\+\+; \}/,
	'live means at least one output has answered');
like($js, qr/badge\.find\('\.music_broadcast_text'\)\.text\(' ' \+ outs\.length \+ ': ' \+ names\.join\(', '\)\);/,
	'the pill names the outputs it is sending to');
like($js, qr/if \(!on\) \{ badge\.hide\(\); return; \}/,
	'it disappears as soon as broadcasting stops');
like($js, qr/musicSyncWatchStart\(\);\s*\n\s*musicStreamPaint\(\);/, 'starting the stream paints it');
like($js, qr/musicSyncWatchStop\(\);\s*\n\s*musicStreamRetryClear\(\);\s*\n\s*musicStreamPaint\(\);/, 'stopping the stream clears it');
like($js, qr/musicBarIntervalArm\(\);\s*\n[\s\S]{0,220}?musicStreamPaint\(\);/, 'a search re-render repaints it');
like($css, qr/#music #music_broadcast\[state="live"\]/, 'the live pill is highlighted');
like($css, qr/#music #music_broadcast\[state="connecting"\]/, 'a pill that is still connecting has its own state');
like($css, qr/\.music_output_group\[link="unreachable"\]/, 'an unreachable output is marked in the drawer');

# --- the core labels exist in every interface language ----------------------
my $broadcasting_keys = () = $language =~ /'music\.broadcasting' =>/g;
my $unreachable_keys = () = $language =~ /'music\.unreachable' =>/g;
is($broadcasting_keys, 16, 'music.broadcasting has all sixteen interface translations');
is($unreachable_keys, 16, 'music.unreachable has all sixteen interface translations');

# --- the help topic explains it ---------------------------------------------
like($help, qr/\$topic\{'music'\} = \{[\s\S]{0,60000}?broadcasting[\s\S]{0,60000}?turns that output off/i,
	'the Music topic explains the broadcast pill and the automatic turn-off');

done_testing();
