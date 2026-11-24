# tests-for: public/js/manager/studio/03_editing.js public/js/manager/studio/16_bounce.js public/js/manager/studio.js public/js/manager/studio/01_transport.js public/js/manager/studio/04_knobs.js public/js/manager/studio/06_controls.js public/js/manager/studio/12_export.js public/js/manager/studio/17_tools.js
# covers:    The Studio bounce: Delete and Bounce rows in the take menu; an
#            explicit loop range ({start, end} seconds) that the transport
#            repeats and the Select tool can set; a take printed through its
#            channel's Out pedals and played dry afterwards on a second bus;
#            the selection bounce that renders before it edits; and the channel
#            fader that moves both buses together.

use strict;
use warnings;

use FindBin;
use Test::More;

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or die "cannot read $path: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

my $root = $FindBin::Bin;
$root =~ s{/t$}{};

my $edit      = slurp("$root/public/js/manager/studio/03_editing.js");
my $bounce    = slurp("$root/public/js/manager/studio/16_bounce.js");
my $studio    = slurp("$root/public/js/manager/studio.js");
my $transport = slurp("$root/public/js/manager/studio/01_transport.js");
my $knobs     = slurp("$root/public/js/manager/studio/04_knobs.js");
my $load      = slurp("$root/public/js/manager/studio/06_controls.js");
my $export    = slurp("$root/public/js/manager/studio/12_export.js");
my $tools     = slurp("$root/public/js/manager/studio/17_tools.js");

# --- the take menu grows Delete and Bounce ----------------------------------
like($edit, qr/studioClipMenuRow\(menu, 'delete', studioLayoutText\('Delete'\)/,
	'the take menu offers Delete');
like($edit, qr/studioClipMenuRow\(menu, 'bounce', studioLayoutText\('Bounce'\)/,
	'the take menu offers Bounce');
like($edit, qr/command == 'delete'[\s\S]{0,120}studioRemoveTake\(hit\.ch, hit\.take\)/,
	'Delete removes the clicked take');
like($edit, qr/command == 'bounce'[\s\S]{0,120}studioBounceTake\(hit\.ch, hit\.take\)/,
	'Bounce prints the clicked take');

# --- an explicit loop range wins over the bar count -------------------------
my ($region) = $edit =~ /function studioLoopRegion\(\) \{(.*?)\n\}/s;
ok(defined $region, 'the loop region reader is found');
$region = '' unless defined $region;
like($region, qr/var end = studioKnobNumber\(r\.end, 0\);/,
	'the reader takes the saved end');
like($region, qr/if \(end > start\) \{ return \{ start: r\.start, bars: r\.bars, end: r\.end \}; \}/,
	'an explicit end is returned as-is');
like($region, qr/end: r\.start \+ \(r\.bars \* bar\)/,
	'a bar-only region still ends on the bar');

like($edit, qr/function studioSetLoopRange\(start, end\)/,
	'the Select tool has a loop-range hook');
my ($set) = $edit =~ /function studioSetLoopRange\(start, end\) \{(.*?)\n\}/s;
ok(defined $set, 'the loop-range setter is found');
$set = '' unless defined $set;
like($set, qr/from = Math\.max\(0, from\);/, 'the start is clamped at zero');
like($set, qr/if \(!\(to > from\)\) \{ return false; \}/, 'an empty or reversed range is refused');
like($set, qr/mixer\['time'\]\['loop_region'\] = \{/,
	'the range is stored on the transport');
like($set, qr/start: from,/, 'the stored range keeps its start');
like($set, qr/end: to,/, 'the stored range keeps its explicit end');
like($set, qr/bars: Math\.max\(1, Math\.round\(\(to - from\) \/ studioBarSeconds\(\)\)\)/,
	'the bar count is kept as a snap hint');
like($set, qr/mixer\['time'\]\['loop'\] = 'ongoing';/, 'setting a range starts the loop');
like($set, qr/#studio_loop'\)\.attr\('enabled', 'ongoing'\)/, 'the loop button shows ongoing');
like($set, qr/css\(\{ 'background-color': 'red' \}\)/, 'the loop button shows the range is live');
like($set, qr/studioSaver\(\);[\s\S]{0,40}studioDrawTracks\(\);/, 'the range is saved and drawn');

# --- a printed take carries its own chain -----------------------------------
like($bounce, qr/function studioBounceChain\(off, c\)/, 'the bounce builds an offline chain');
my ($chain) = $bounce =~ /function studioBounceChain\(off, c\) \{(.*?)\n\}/s;
ok(defined $chain, 'the chain builder is found');
$chain = '' unless defined $chain;
like($chain, qr/studioInsert\(off, ins\.name\)/, 'each insert is built on the offline context');
like($chain, qr/var values = ins\.values \|\| \{\};/, 'the live insert values are read');
like($chain, qr/built\.set\(control, values\[control\]\)/, 'each control value is applied');
like($chain, qr/built\.setBypass\(!!ins\.bypassed\)/, 'the footswitch travels with the insert');

like($bounce, qr/async function studioBounceTake\(ch, take\)/, 'a take can be printed');
my ($take) = $bounce =~ /async function studioBounceTake\(ch, take\) \{(.*?)\n\}/s;
ok(defined $take, 'the per-take bounce is found');
$take = '' unless defined $take;
like($take, qr/!c\.outInserts \|\| !c\.outInserts\.length[\s\S]{0,180}There is no pedal chain to print on this track\./,
	'an empty chain is refused with a sentence');
like($take, qr/var chain = studioBounceChain\(off, c\);/, 'the take renders through the chain');
like($take, qr/src\.start\(0, offset, span\);/, 'the take starts at its own in-point');
like($take, qr/var rendered = await off\.startRendering\(\);/, 'the render is offline');
like($take, qr/var data = studioBufferToWav\(rendered\);/, 'the render becomes a WAV');
like($take, qr/take\.offset = 0;/, 'the printed take starts at its own beginning');
like($take, qr/take\.buffer = rendered;/, 'the printed buffer replaces the source');
like($take, qr/take\.data = data;/, 'the WAV blob is kept for saving');
like($take, qr/take\.src = null;/, 'the old URL is dropped');
like($take, qr/take\.uuid = null;/, 'the printed take is a fresh file');
like($take, qr/take\.encoding = 'audio\/wav';/, 'the printed take is encoded as WAV');
like($take, qr/take\.printed = true;/, 'the take is marked printed');
like($take, qr/indexOf\('video'\) !== -1[\s\S]{0,120}no pedal chain to print/,
	'a video take is refused by name');
like($take, qr/delete take\.engine_file;/, 'the old staged engine file is forgotten');
like($take, qr/take\.waveform = null;/, 'the old waveform is forgotten');
unlike($take, qr/take\.startTime =/, 'the timeline slot is left alone');
unlike($take, qr/take\.duration =/, 'the take length is left alone');
like($take, qr/studioReindexTakes\(ch\);[\s\S]{0,80}studioSaver\(\);[\s\S]{0,40}studioTakesChanged\(\)/,
	'the printed take is reindexed, saved and re-scheduled');

# --- the dry playback bus ---------------------------------------------------
like($studio, qr/printBus: ctx\.createGain\(\)/, 'the channel engine owns a print bus');
like($studio, qr/c\.printBus\.connect\(c\.playPan\);/, 'the print bus skips the Out chain');
like($transport, qr/var bus = \(take\.printed && c\.printBus\) \? c\.printBus : c\.playBus;/,
	'the scheduler sends a printed take to the print bus');
like($transport, qr/inserts: take\.printed \? \[\] : inserts/,
	'the engine clip plan leaves a printed take dry');

like($studio, qr/function studioChannelFader\(ch, value\)/, 'one helper moves the fader');
my ($fader) = $studio =~ /function studioChannelFader\(ch, value\) \{(.*?)\n\}/s;
ok(defined $fader, 'the fader helper is found');
$fader = '' unless defined $fader;
like($fader, qr/\[c\.playBus, c\.printBus\]\.forEach/, 'both take buses move together');
like($transport, qr/studioChannelFader\(ch, c\.playBus\.gain\.value\)/,
	'the playback mix mirrors the fader onto the print bus');
like($transport, qr/c\.playBus\.gain\.value = studioVolumeFraction\([\s\S]*?\) \* \(silent \? 0 : 1\);/,
	'the play bus still carries the mute and solo factor');
like($knobs, qr/studioChannelFader\(ch, value\)/, 'the volume setter writes both buses');

# --- bouncing a selection ---------------------------------------------------
like($bounce, qr/async function studioBounceSelection\(start, end, channels\)/,
	'a selected range can be bounced');
my ($sel) = $bounce =~ /async function studioBounceSelection\(start, end, channels\) \{(.*?)\n\}/s;
ok(defined $sel, 'the selection bounce is found');
$sel = '' unless defined $sel;
like($sel, qr/var keys = Object\.keys\(map\)/, 'the channel map is walked');
like($sel, qr/!c\.outInserts \|\| !c\.outInserts\.length\) \{ continue; \}/,
	'a channel with no chain is skipped');
like($sel, qr/await studioBounceSpan\(c, takes, from, to\)/, 'each channel is rendered over the span');
my $render_at = index($sel, 'await studioBounceSpan');
my $clear_at = index($sel, 'studioBounceClearSpan');
ok($render_at >= 0 && $clear_at > $render_at, 'the render happens before the timeline is edited');
like($sel, qr/m\.media\.out\.push\(printed\);/, 'one printed take joins the channel');
like($sel, qr/printed: true/, 'the new take is marked printed');
like($sel, qr/startTime: from,/, 'the new take starts at the range start');
like($sel, qr/duration: to - from,/, 'the new take spans the range');
like($sel, qr/buffer: render\.buffer,/, 'the new take carries the rendered buffer');
like($sel, qr/data: render\.data,/, 'the new take carries its WAV blob');
like($sel, qr/encoding: 'audio\/wav',/, 'the new take is encoded as WAV');
like($sel, qr/uuid: null,/, 'the new take is a fresh file');
like($sel, qr/return bounced;/, 'the channel count is returned');

my ($clear) = $bounce =~ /function studioBounceClearSpan\(ch, start, end\) \{(.*?)\n\}/s;
ok(defined $clear, 'the span clearing helper is found');
$clear = '' unless defined $clear;
like($clear, qr/studioSplitTake\(ch, hit\.take, hit\.at\)/, 'straddling takes are split at the edge');
like($clear, qr/studioRemoveTake\(ch, take\)/, 'takes wholly inside the range are removed');

# --- the parts are in the split manifest ------------------------------------
like($studio, qr/16_bounce\.js\s+-\s+print a take or a selection/,
	'the bounce part is named in the [[js-split]] manifest');

# --- printed survives a save and a reload -----------------------------------
like($knobs, qr/printed: take\.printed \? 1 : 0/, 'the song record saves the printed flag');
like($load, qr/printed: vr\['printed'\] \? true : false/, 'a loaded take restores the printed flag');
like($bounce, qr/if \(take\.printed\) \{[\s\S]{0,120}already printed/,
	'a printed take is not printed a second time');

# --- printed is mixed dry by the exporter -----------------------------------
like($export, qr/\(entry\.takes \|\| \[\]\)\.some\(function \(take\) \{ return take && take\.printed; \}\)/,
	'the exporter creates a dry path only when a printed take is present');
like($export, qr/var destination = \(take\.printed && input\.dry\) \? input\.dry : input\.input;/,
	'the mix schedules a printed take dry');
like($tools, qr/var destination = \(take\.printed && input\.dry\) \? input\.dry : input\.input;/,
	'the selection export schedules a printed take dry');
like($studio, qr/if \(c\.printBus\) \{ c\.printBus\.connect\(sink\); \}/,
	'a printed take still reaches the channel\'s output send');

done_testing();
