# tests-for: engine/src/socket.rs engine/src/playback.rs engine/src/lib.rs lib/JawnOS/Audio/Engine.pm lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm public/js/manager/studio/01_transport.js public/js/manager/studio/04_knobs.js public/js/manager/studio/06_controls.js public/js/manager/studio/09_pedals.js public/js/manager/studio/10_master.js public/js/manager/studio.js templates/studio/markup.html.ep perl/help/topics_apps.pl
# covers:    The engine owns the browser transport's clock, metronome and take
#            audio: a `transport` socket command (start/stop/seek/status), an
#            absolute bar phase that starts on the song's own grid, a loop that
#            wraps the position and the phase together, a `clips` plan that
#            renders recorded takes on the same timeline (decoded once and
#            cached by path), a master rack whose set and knob values ride the
#            plan, a route and staging route that carry the plan and its WAVs,
#            and JS that stages takes, suppresses the browser copies while the
#            engine runs and falls back to the browser clock and audio when the
#            engine refuses.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use Cwd qw(abs_path);

my $root = abs_path("$FindBin::Bin/..");

# The page's take start is read beside the engine sources: arming the monitor
# there is how the transport change is observed from this side.
my $studio_js = read_file("$root/public/js/manager/studio.js");

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
like($socket, qr/fn transport_update/, 'update replaces a running transport plan');
like($socket, qr/fn transport_stop/, 'stop is handled');
like($socket, qr/fn transport_status/, 'status has a dedicated line');
like(
	$socket,
	qr/"update"\s*=>\s*self\.transport_update\(object\)/,
	'update is dispatched from the transport command'
);
like(
	$socket,
	qr/the transport is not playing; start it before updating its clips/,
	'an update with no running transport is refused clearly'
);
like(
	$socket,
	qr/plan_tx\.send\(plan\)/,
	'an update hands the plan to the render thread instead of rebuilding it here'
);
like(
	$socket,
	qr/with_plan_rx\(plans\)/,
	'the render source receives plans without a lock'
);
like($socket, qr/fn run_transport/, 'the transport worker is one function');
like($socket, qr/\\"transport\\":\{/, 'the status line nests a transport object');
like(
	$socket,
	qr/loop_end > 0 && loop_end <= loop_start/,
	'an end not past its start is refused before a thread exists'
);
like(
	$studio_js,
	qr/var monitor = \(typeof studioMonitoredChannel[\s\S]{0,200}monitor'\]\s*==\s*'yes'\)/,
	'a monitored track or the Monitor setting arms the take while the transport plays'
);
unlike(
	$studio_js,
	qr/var monitor = !transportRunning/,
	'the take start does not gate its monitor on the transport'
);
like(
	$studio_js,
	qr/monitor_input: monitor \? 'true' : 'false'/,
	'the take start sends monitor_input whether or not the transport runs'
);
like(
	$socket,
	qr/the take's monitor is using the output; stop the take before starting the transport/,
	'a take with a monitor still owns the output'
);
unlike(
	$socket,
	qr/a take is recording; stop it before starting the transport/,
	'the transport starts beside a recording take'
);
like(
	$socket,
	qr/line_with_roles/,
	'the take line can carry a transport role'
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
like(
	$playback,
	qr/a_transport_gain_change_silences_the_next_block/,
	'a gain change silences the next transport block (unit test)'
);
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
	qr/pub struct TransportPlan/,
	'a replacement plan is its own type'
);
like(
	$playback,
	qr/pub samples: Arc<\[f32\]>/,
	'a decoded take is shared rather than copied between plans'
);
like(
	$playback,
	qr/pub fn from_samples/,
	'a clip is placed from samples the control thread already decoded'
);
like(
	$playback,
	qr/pub fn decode_take/,
	'one function decodes a take WAV for the transport and its cache'
);
like(
	$playback,
	qr/master_values: Option<Vec<\(String, f32\)>>/,
	'a plan can carry master knob values without a clip plan'
);
like(
	$playback,
	qr/a_transport_master_knob_change_is_heard_at_the_next_block/,
	'a master knob change is heard at the next block (unit test)'
);
like(
	$playback,
	qr/pub fn with_plan_rx/,
	'the render source takes a plan channel from the control thread'
);
like(
	$playback,
	qr/fn apply_plan/,
	'a plan is applied at a block edge'
);
like(
	$playback,
	qr/placement_only/,
	'a placement-only change swaps without rebuilding voices'
);
like(
	$playback,
	qr/track\.channel\.set\("gain", clip\.gain\)/,
	'a fader change moves the strip without a rebuild'
);
like(
	$playback,
	qr/plans\.try_recv\(\)/,
	'the render thread never blocks waiting for a plan'
);
like(
	$playback,
	qr/a_transport_plan_update_moves_and_trims_a_clip_without_reopening/,
	'moving and trimming a clip is heard without reopening (unit test)'
);
like(
	$playback,
	qr/a_transport_plan_update_that_removes_a_clip_silences_it_next_block/,
	'a removed clip stops at the next block (unit test)'
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
	qr/for kind in master \{\s*mixer\.push_master\(\*kind\);\s*\}/,
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
	qr/run_transport\([\s\S]{0,500}plan_rx,[\s\S]{0,160}live_rx,[\s\S]{0,160}note_rx,[\s\S]{0,160}hit_rx,?\s*\)/,
	'the master rack, the plan, live-input, note and hit channels reach the transport worker'
);
like(
	$socket,
	qr/with_master_values\(master_values\)/,
	'the render source takes the rack\'s knob values'
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
	'a clip change on `start` still needs a stop; `update` is the live path'
);
like(
	$socket,
	qr/a_transport_update_is_refused_when_nothing_is_playing/,
	'an update with no transport has a socket test'
);
like(
	$socket,
	qr/a_transport_update_reaches_a_running_transport/,
	'an update reaches a running transport (socket test)'
);
like(
	$socket,
	qr/\\"clips\\":\{\}/,
	'the transport status carries how many takes it renders'
);
like($socket, qr/struct TakeCache/, 'the control thread caches decoded takes');
like(
	$socket,
	qr/fn decode\(&mut self, path: &str\)/,
	'a decode is looked up by the absolute path'
);
like(
	$socket,
	qr/fn retain\(&mut self, live/,
	'a plan evicts the takes it no longer names'
);
like(
	$socket,
	qr/a_repeated_plan_reuses_the_decoded_take/,
	'a repeated plan reuses the decode (socket test)'
);
like(
	$socket,
	qr/fn parse_master_values/,
	'the engine parses live master knob values'
);
like(
	$socket,
	qr/a_master_values_update_reaches_a_running_transport/,
	'a value-only update reaches a running transport (socket test)'
);
like(
	$socket,
	qr/a_master_values_update_refuses_unknown_names_and_shapes/,
	'a bad master value is refused (socket test)'
);
like(
	$socket,
	qr/a_master_toggle_update_changes_the_armed_rack/,
	'adding and removing a master insert reaches a running transport (socket test)'
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
	qr/choose a transport action: start, stop, seek, update or status/,
	'an unknown action is a refusal'
);
like(
	$controller,
	qr/\$action eq 'update'/,
	'the route accepts the live plan action'
);
like(
	$controller,
	qr/update needs "clips", "master", "master_values" or "drums": the change for the running transport/,
	'an update must carry a change, and a knob turn need not re-send the clips'
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
	qr/sub studio_master_values/,
	'the route validates the master rack\'s knob values'
);
like(
	$controller,
	qr/\$fields\{'master_values'\} = \$values/,
	'the validated master values ride the transport fields'
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
	qr/qw\(\s*position bpm beats_per_bar gain loop_start loop_end clips master master_values drums\s*\)/,
	'only the promised fields, including the clip plan, master rack and values, are forwarded'
);
like(
	$engine_pm,
	qr/sub audio_engine_record_stop[\s\S]{0,220}cmd => 'record', action => 'stop'/,
	'the client sends the record-specific stop'
);
like(
	$controller,
	qr/\$action eq 'stop'[\s\S]{0,220}audio_engine_record_stop/,
	'Stop take uses it so the engine transport keeps playing'
);
like(
	$controller,
	qr/\$action eq 'listen_stop'[\s\S]{0,220}audio_engine_stop/,
	'Listen stop keeps the global stop'
);

# --- the browser follows the engine clock and never doubles the click --------
my $transport_js = read_file("$root/public/js/manager/studio/01_transport.js");
ok(length $transport_js, 'the transport JS is found');
like($transport_js, qr/function studioEngineTransportReady/, 'the engine path is availability-gated');
like($transport_js, qr/\['status'\] == 'record'\) \{ return false; \}/,
	'a browser recording keeps its own clock and count-in click');
unlike(
	$transport_js,
	qr/engine_take'\]\) \{ return false; \}/,
	'an engine take no longer blocks the transport'
);
like($transport_js, qr/function studioEngineTransportStart/, 'the browser can start the engine transport');
like(
	$transport_js,
	qr/function studioEngineTransportStart[\s\S]{0,700}!studioEngineTransportReady\(\)[\s\S]{0,500}engine_transport'\]\)[\s\S]{0,300}studioEngineTransportStop\(\)/,
	'a browser recording stops a running engine transport instead of leaving it playing'
);
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
	qr/function studioEngineTransportGainKey[\s\S]{0,400}volume/,
	'the engine gain key reads the metronome volume'
);
like(
	$transport_js,
	qr/function studioScheduleTick[\s\S]{0,900}studioEngineTransportGainKey[\s\S]{0,900}studioEngineTransportSync/,
	'a volume or metronome on/off change retunes the running transport'
);
like(
	$transport_js,
	qr/engine_count_in/,
	'the browser tracks an engine take\'s count-in'
);
like(
	$transport_js,
	qr/pos >= engineCountIn\.punch/,
	'the count-in click stops at the punch-in beat'
);
like(
	$transport_js,
	qr/function studioScheduleTakes[\s\S]{0,600}\['engine_count_in'\]\) \{ return; \}/,
	'the count-in places no browser take audio'
);

like(
	$transport_js,
	qr{function studioEngineClipPlan},
	'the page builds the engine clip plan from its takes'
);
like(
	$transport_js,
	qr/function studioTakesChanged\(\).*?engine_transport'\]\) \{ studioEngineClipsChanged\(\); return; \}/s,
	'a take edit on a running engine posts a replacement plan instead of re-anchoring'
);
like(
	$transport_js,
	qr/function studioEngineClipsChanged/,
	'the live plan update has one debounced entry point'
);
like(
	$transport_js,
	qr/studioEngineClipsTimer = setTimeout\([\s\S]{0,120}\}, 120\)/,
	'the plan update debounces about a tenth of a second'
);
like(
	$transport_js,
	qr/function studioEngineClipsPost/,
	'the debounced edit stages and posts a plan'
);
like(
	$transport_js,
	qr/studioEngineClipStageAll\(plan\)/,
	'the update re-stages only through the existing per-take cache'
);
like(
	$transport_js,
	qr/studioEngineTransportPost\('update'/,
	'the plan reaches the engine through the update action'
);
like(
	$transport_js,
	qr/studio: engine clip staging failed, keeping the current plan/,
	'a staging failure keeps the running plan instead of falling back'
);
like(
	$transport_js,
	qr/studio: engine clip update refused, keeping the current plan/,
	'a refused update leaves the engine playing'
);
like(
	$transport_js,
	qr/function studioEnginePlanTouched/,
	'fader, pan and Out insert handlers can ask whether the engine owns the plan'
);
like(
	$transport_js,
	qr/studioEngineClipsCancel/,
	'stop and fallback cancel a queued plan before the flag comes down'
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
	qr/inserts: take\.printed \? \[\] : inserts/,
	'a printed take travels dry; another clip carries its insert names'
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
	qr/var values = studioEngineMasterValues\(\);\s*\n\s*if \(values\.length\) \{ fields\.master_values_json = JSON\.stringify\(values\); \}/,
	'the rack\'s control values ride the start'
);
like(
	$transport_js,
	qr/fields\.master_values_json = JSON\.stringify\(values\)/,
	'the rack\'s control values ride a plan update too'
);

my $master_js = read_file("$root/public/js/manager/studio/10_master.js");
ok(length $master_js, 'the master rack JS is found');
like(
	$master_js,
	qr/function studioEngineMasterValues/,
	'the rack can be sent as the engine\'s live control values'
);
like(
	$master_js,
	qr/function studioEngineMasterValuesChanged/,
	'a knob turn while the transport runs has one debounced entry point'
);
like(
	$master_js,
	qr/studioEngineMasterTimer = setTimeout\([\s\S]{0,120}\}, 120\)/,
	'the value update debounces about a tenth of a second'
);
like(
	$master_js,
	qr/studioEngineTransportPost\('update', \{ master_values_json: JSON\.stringify\(values\) \}/,
	'the knob update is a value-only plan post, not a clip plan'
);
like(
	$master_js,
	qr/function studioMasterSet[\s\S]{0,400}engine_transport'\]\) \{[\s\S]{0,160}studioEngineMasterValuesChanged\(\)/,
	'a transport knob uses the value path, not the engine take\'s param path'
);
like(
	$master_js,
	qr/function studioMasterToggle[\s\S]{0,600}studioEnginePlanTouched\(\)[\s\S]{0,160}studioTakesChanged\(\)/,
	'a toggle keeps the transport\'s rack set in sync through the plan'
);
unlike(
	$master_js,
	qr/function studioMasterSet[\s\S]{0,400}studioEngineMasterParam\(name, control, value\);\s*\n\s*studioEngineMasterValuesChanged/,
	'the transport knob does not call the engine take param path as well'
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
like(
	$transport_js,
	qr/var was = !!\(mixer\['time'\] && mixer\['time'\]\['engine_transport'\]\)/,
	'stopping the engine transport tolerates a first open with no mixer'
);
like(
	$transport_js,
	qr/if \(mixer\['time'\]\) \{ mixer\['time'\]\['engine_transport'\] = false; \}/,
	'stopping writes the transport only when the mixer has one'
);
unlike(
	$transport_js,
	qr/var was = !!mixer\['time'\]\['engine_transport'\];/,
	'stopping never dereferences a transport the first open has not built'
);
my $knobs_js = read_file("$root/public/js/manager/studio/04_knobs.js");
like(
	$knobs_js,
	qr/studioTeardown\(\);[\s\S]{0,300}mixer = \{/,
	'the first open tears the previous window down before replacing mixer'
);
like(
	$controls,
	qr/function studioTime\(command, fromEngine\)/,
	'the transport start can be told to leave the engine clock alone'
);
like(
	$controls,
	qr/studioEngineCountInDue\(\)/,
	'the tick starts the take at the punch-in beat'
);

# --- the engine take start path and its count-in -----------------------------
like($studio_js, qr/function studioEngineStartNow/, 'the take start is its own function');
like(
	$studio_js,
	qr/var transportRunning[\s\S]{0,300}var click = transportRunning \? null : studioEngineClick\(\)/,
	'the transport owns the click, so an engine take adds none while it runs'
);
like(
	$studio_js,
	qr/monitor_input: monitor \? 'true' : 'false'/,
	'the take start sends monitor_input for that monitor'
);
like($studio_js, qr/function studioEngineCountInStart/, 'the take starts a browser count-in');
like($studio_js, qr/function studioEngineCountInDue/, 'the punch-in starts the take');
like(
	$studio_js,
	qr/studioTime\('start', true\)/,
	'the count-in runs the browser clock without starting the engine early'
);
like(
	$studio_js,
	qr/start_at = Math\.round\(punch \* studioEngineDeviceRate\)/,
	'the punch-in position is the take\'s sample start stamp'
);
like(
	$studio_js,
	qr/studioEngineTransportStart\(pending\.punch, pending\.staged, true\)/,
	'the transport starts on the same punch-in beat as the take'
);

my $markup = read_file("$root/templates/studio/markup.html.ep");
like(
	$markup,
	qr/id="studio_engine_count_in"/,
	'the engine take panel has a count-in control'
);

my $help = read_file("$root/perl/help/topics_apps.pl");
like(
	$help,
	qr/Count in before an engine take starts/,
	'the help topic lists the count-in control'
);
like(
	$help,
	qr/Count-in, beside Tracks/,
	'the help topic describes the count-in in the on-screen words'
);
like(
	$help,
	qr/moving, trimming, splitting, deleting or adding a take while it plays is heard at the next block/,
	'the help topic says a take edit is heard without stopping the engine'
);
like(
	$help,
	qr/because the engine swaps the plan without closing the output/,
	'the help topic says the output stays open'
);

 done_testing();
