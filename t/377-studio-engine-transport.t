# tests-for: engine/src/socket.rs engine/src/playback.rs engine/src/lib.rs lib/JawnOS/Audio/Engine.pm lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm public/js/manager/studio/01_transport.js public/js/manager/studio/06_controls.js
# covers:    The engine owns the browser transport's clock, metronome and take
#            audio: a `transport` socket command (start/stop/seek/status), an
#            absolute bar phase that starts on the song's own grid, a loop that
#            wraps the position and the phase together, a `clips` plan that
#            renders recorded takes on the same timeline, a route and staging
#            route that carry the plan and its WAVs, and JS that stages takes,
#            suppresses the browser copies while the engine runs and falls back
#            to the browser clock and audio when the engine refuses.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use Cwd qw(abs_path);

my $root = abs_path("$FindBin::Bin/..");

# --- the engine's command, status and absolute grid ---------------------------
my $socket = read_file("$root/engine/src/socket.rs");
ok(length $socket, 'the engine socket source is found');

like(
	$socket,
	qr/"transport"\s*=>\s*Action::Reply\(self\.transport_command/,
	'the transport command is dispatched beside record/play/listen/patch'
);
like($socket, qr/fn transport_command/, 'the transport has one command function');
like($socket, qr/fn transport_start/, 'start is handled');
like($socket, qr/fn transport_seek/, 'seek is handled');
like($socket, qr/fn transport_stop/, 'stop is handled');
like($socket, qr/fn transport_status/, 'status has a dedicated line');
like($socket, qr/\\"transport\\":\{/, 'the status line nests a transport object');
like(
	$socket,
	qr/loop_end > 0 && loop_end <= loop_start/,
	'an end not past its start is refused before a thread exists'
);
like(
	$socket,
	qr/the transport is playing; stop it before recording/,
	'a take refuses while the transport owns the output'
);
like(
	$socket,
	qr/a take is recording; stop it before starting the transport/,
	'the transport refuses while a take records'
);
like(
	$socket,
	qr/a playback is running; stop it before starting the transport/,
	'the transport refuses while a playback runs'
);
like(
	$socket,
	qr/session\.control\.set_tempo\(bpm, beats_per_bar, gain\)/,
	'a running transport retunes in place instead of reopening the device'
);
like(
	$socket,
	qr/session\.control\.seek\(position\)/,
	'a running transport seeks in place'
);

my $playback = read_file("$root/engine/src/playback.rs");
ok(length $playback, 'the click/playback source is found');
like($playback, qr/fn build_absolute/, 'the click has an absolute-grid constructor');
like($playback, qr/fn render_absolute_into/, 'the absolute grid renders a whole block');
like(
	$playback,
	qr/rem_euclid\(self\.beats_per_bar as i64\)/,
	'the accent is the absolute beat modulo the bar'
);
like(
	$playback,
	qr/self\.loop_end > self\.loop_start/,
	'the click wraps at the loop end'
);
like(
	$playback,
	qr/pub struct TransportControl/,
	'the mutable transport controls are shared by socket and render thread'
);
like($playback, qr/pub fn seek/, 'the control exposes a seek');
like($playback, qr/pub fn set_tempo/, 'the control exposes a tempo change');
like($playback, qr/pub fn set_loop/, 'the control exposes a loop change');
like(
	$playback,
	qr/a_transport_started_mid_bar_waits_for_the_next_absolute_beat/,
	'the absolute bar phase has a unit test'
);
like(
	$playback,
	qr/a_transport_loop_wraps_the_position_and_the_bar_phase/,
	'the loop wrap and phase have a unit test'
);
like(
	$playback,
	qr/pub struct TransportClip/,
	'the transport carries recorded takes as clips'
);
like(
	$playback,
	qr/fn source_at/,
	'a clip maps a timeline position to its own source frame'
);
like(
	$playback,
	qr/fn edge_gain/,
	'a clip applies the browser\'s crossfade edges'
);
like(
	$playback,
	qr/pub fn with_clips/,
	'the render source takes its clip plan'
);
like(
	$playback,
	qr/pub fn with_master/,
	'the render source takes the master rack'
);
like(
	$playback,
	qr/for kind in &self\.master \{\s*mixer\.push_master\(\*kind\);\s*\}/,
	'the master rack is armed on the clip mix before prepare'
);
like(
	$playback,
	qr/a_transport_clip_runs_through_its_output_insert/,
	'a clip plays through its own Out insert (unit test)'
);
like(
	$playback,
	qr/a_transport_master_insert_masters_the_clip_mix/,
	'the master rack masters the clip mix (unit test)'
);
like(
	$playback,
	qr/a_transport_clip_plays_at_its_timeline_start/,
	'clip placement has a unit test'
);
like(
	$playback,
	qr/a_looping_transport_clip_repeats_every_duration/,
	'a looping clip repeats'
);
like(
	$playback,
	qr/a_transport_loop_restarts_the_clip_inside_the_region/,
	'the transport loop carries the clips with the click'
);

my $lib = read_file("$root/engine/src/lib.rs");
like($lib, qr/TransportControl,?\s*\n?\s*TransportSource|TransportControl/, 'the transport types are exported');
like($lib, qr/TransportSource/, 'the render source is exported');
like($lib, qr/TransportClip/, 'the clip type is exported');

like(
	$socket,
	qr/fn transport_clips/,
	'the transport reads a clip plan before it opens a device'
);
like(
	$socket,
	qr/fn transport_clip/,
	'one clip object is validated'
);
like(
	$socket,
	qr/fn transport_start[\s\S]{0,5000}parse_master\(get\(object, "master"\)\)/,
	'start reads the optional master rack'
);
like(
	$socket,
	qr/run_transport\(config, control, error, clips, master\)/,
	'the master rack reaches the transport worker'
);
like(
	$socket,
	qr/with_master\(master\)/,
	'the render source arms the master rack'
);
like(
	$socket,
	qr/\\"master\\":\{\}/,
	'the transport status reports the armed master count'
);
like(
	$socket,
	qr/the transport is playing; stop it before changing its clips/,
	'a clip change needs a stop, because strips belong to the render thread'
);
like(
	$socket,
	qr/\\"clips\\":\{\}/,
	'the transport status carries how many takes it renders'
);

# --- the Perl route and the client -------------------------------------------
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc9.pm");
like(
	$routes,
	qr/\[44033,\s*'post',\s*'\/manager\/studio\/transport',\s*'action_44033'\]/,
	'the transport has a route row'
);
like(
	$routes,
	qr/\[44034,\s*'post',\s*'\/manager\/studio\/clip',\s*'action_44034'\]/,
	'staging a take for the engine has its own route'
);

my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
like($controller, qr/sub action_44033/, 'the route action exists');
like($controller, qr/sub studio_transport_fields/, 'the route validates the six fields');
like(
	$controller,
	qr/transport loop_end must be greater than loop_start/,
	'the route refuses a loop whose end is not past its start'
);
like(
	$controller,
	qr/transport beats_per_bar must be a whole number from 1 to 32/,
	'the route refuses a signature the engine could not represent'
);
like(
	$controller,
	qr/choose a transport action: start, stop, seek or status/,
	'an unknown action is a refusal'
);
like($controller, qr/sub action_44034/, 'the clip staging action exists');
like($controller, qr/sub studio_transport_clips/, 'the route validates a clip plan');
like(
	$controller,
	qr/a transport clip needs an absolute \"file\" WAV path/,
	'a clip names an absolute file the engine can read'
);
like(
	$controller,
	qr/transport clips may name at most 64 takes/,
	'the plan is bounded'
);
like(
	$controller,
	qr/a clip must be a WAV file/,
	'only WAVs are staged for the engine'
);
like(
	$controller,
	qr/master_json/,
	'the transport route reads a master rack'
);
like(
	$controller,
	qr/&studio_master_plan\(\$raw_master\)/,
	'the transport master rack reuses the take plan validator'
);
like(
	$controller,
	qr/\$fields\{'master'\} = \$master if \@\{\$master\}/,
	'the validated master rack rides the transport fields'
);
like(
	$controller,
	qr/never encrypted/,
	'a staged take stays readable by the engine'
);

my $engine_pm = read_file("$root/lib/JawnOS/Audio/Engine.pm");
like($engine_pm, qr/sub audio_engine_transport/, 'the Perl client speaks the command');
like($engine_pm, qr/audio_engine_transport_fields/, 'the client has a field whitelist');
like(
	$engine_pm,
	qr/qw\(\s*position bpm beats_per_bar gain loop_start loop_end clips master\s*\)/,
	'only the promised fields, including the clip plan and master rack, are forwarded'
);

# --- the browser follows the engine clock and never doubles the click --------
my $transport_js = read_file("$root/public/js/manager/studio/01_transport.js");
ok(length $transport_js, 'the transport JS is found');
like($transport_js, qr/function studioEngineTransportReady/, 'the engine path is availability-gated');
like($transport_js, qr/\['status'\] == 'record'\) \{ return false; \}/,
	'a browser recording keeps its own clock and count-in click');
like($transport_js, qr/function studioEngineTransportStart/, 'the browser can start the engine transport');
like($transport_js, qr/function studioEngineTransportSeek|studioEngineTransportPost\('seek'/, 'the browser can seek it');
like($transport_js, qr/function studioEngineTransportStop/, 'the browser can stop it');
like($transport_js, qr/function studioEngineTransportPoll/, 'the browser polls its position');
like(
	$transport_js,
	qr/mixer\['time'\]\['engine_transport'\] = true/,
	'the engine path raises the engine_transport flag'
);
like(
	$transport_js,
	qr/function studioEngineTransportDrop/,
	'a refusal or dead socket has one fallback path'
);
like(
	$transport_js,
	qr/function studioEngineTransportDrop[\s\S]{0,250}mixer\['time'\]\['engine_transport'\] = false/,
	'the fallback clears the engine_transport flag'
);
like(
	$transport_js,
	qr/function studioEngineTransportAnswer[\s\S]{0,300}studioEngineTransportDrop\(\)/,
	'a refused start/seek falls back to the browser clock'
);
like(
	$transport_js,
	qr/engine_take'\] \|\| mixer\['time'\]\['engine_transport'\]/,
	'the browser click is suppressed while the engine owns it'
);
like(
	$transport_js,
	qr/mixer\['time'\]\['position'\] = pos;/,
	'the playhead is updated from the engine position'
);
like($transport_js, qr/studioEngineTransportDrift/, 'drift has a small threshold');
like(
	$transport_js,
	qr/studioClockStart\(pos, true\)/,
	'a drifted browser segment re-anchors to the engine position without re-commanding it'
);
like(
	$transport_js,
	qr/studioClockStart\(pos, fromEngine\)/,
	'the browser anchor can be told it came from the engine'
);
like(
	$transport_js,
	qr/loop_start: loop\.start/,
	'the loop bounds ride the start request in seconds'
);
like(
	$transport_js,
	qr{'/manager/studio/transport'},
	'the page calls the transport route, not the take route'
);

like(
	$transport_js,
	qr{function studioEngineClipPlan},
	'the page builds the engine clip plan from its takes'
);
like(
	$transport_js,
	qr{function studioEngineClipStage},
	'a take is staged as a WAV once'
);
like(
	$transport_js,
	qr{'/manager/studio/clip'},
	'staging calls the clip route'
);
like(
	$transport_js,
	qr{fields\.clips_json = JSON\.stringify\(clips\)},
	'the plan rides as one JSON string'
);
like(
	$transport_js,
	qr/function studioScheduleTakes[\s\S]{0,500}\['engine_transport'\]\) \{ return; \}/,
	'the browser schedules no second copy while the engine owns the takes'
);
like(
	$transport_js,
	qr/fade_in: fIn/,
	'the clip plan carries the browser crossfade edges'
);
like(
	$transport_js,
	qr/var strip = studioAudio\.channels\[ch\]/,
	'a clip reads the channel it is drawn from'
);
like(
	$transport_js,
	qr/strip\.outInserts\.forEach/,
	'a clip takes its inserts from the channel Out chain'
);
like(
	$transport_js,
	qr/if \(!ins \|\| ins\.bypassed \|\| !ins\.name\) \{ return; \}/,
	'only enabled Out inserts travel'
);
like(
	$transport_js,
	qr/studioEffectKind\(ins\.name\) === 'stereowidener'/,
	'the browser-only Stereo Widener is left out'
);
like(
	$transport_js,
	qr/inserts: inserts/,
	'the clip object carries its insert names'
);
like(
	$transport_js,
	qr/inserts: clip\.inserts/,
	'the staged plan keeps the clip inserts'
);
like(
	$transport_js,
	qr/fields\.master_json = JSON\.stringify\(master\)/,
	'the enabled master rack rides the transport start'
);
like(
	$transport_js,
	qr/studioEngineMasterList\(\)/,
	'the transport uses the same master plan helper as an engine take'
);
like(
	$transport_js,
	qr{studioFlushSources\(\);\s*\n\s*studioEngineTransportPollStart},
	'a successful start drops the browser take sources'
);

my $controls = read_file("$root/public/js/manager/studio/06_controls.js");
like(
	$controls,
	qr/studioStop[\s\S]{0,200}studioEngineTransportStop\(\)/,
	'the browser stop stops the engine transport too'
);
like(
	$controls,
	qr/studioTeardown[\s\S]{0,300}studioEngineTransportStop\(\)/,
	'closing the window stops it as well'
);

done_testing();
