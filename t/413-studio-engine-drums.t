# tests-for: engine/src/playback.rs engine/src/socket.rs engine/src/mixer.rs engine/crates/jawn-drums/ lib/JawnOS/Audio/Engine.pm lib/JawnOS/Controller/manager_misc9.pm public/js/manager/studio/01_transport.js public/js/manager/studio/11_drums.js
# covers:    the Studio drum machine plays on the engine's clock instead of the
#            browser's (docs/studio-audio-roadmap.md P5). The transport's plan
#            carries a sixteenth-note chart: eight voice rows of velocities, the
#            kit, the length and whether it repeats. The engine renders the kit
#            natively, schedules each step inside the block with `trigger_at`,
#            anchors step 0 at the transport's start (or seek) position,
#            restarts it at loop_start on a loop wrap, and sums the drum bus
#            before the master rack. The page sends the chart on `start` and on
#            every `update`, suppresses its own scheduler while the engine owns
#            the clock, and falls back to the browser scheduler when the engine
#            goes away. A retune at the playhead is not a seek, so a knob turn
#            does not restart the chart.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root = abs_path("$FindBin::Bin/..");

my $playback   = read_file("$root/engine/src/playback.rs");
my $socket     = read_file("$root/engine/src/socket.rs");
my $mixer      = read_file("$root/engine/src/mixer.rs");
my $engine_pm  = read_file("$root/lib/JawnOS/Audio/Engine.pm");
my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my $transport  = read_file("$root/public/js/manager/studio/01_transport.js");
my $drums      = read_file("$root/public/js/manager/studio/11_drums.js");

ok( length $playback,   'the transport source is found' );
ok( length $socket,     'the engine socket is found' );
ok( length $transport,  'the browser transport is found' );
ok( length $drums,      'the drum machine script is found' );

# --- the engine plays a chart on the transport grid --------------------------
like( $playback, qr/pub struct DrumChart/, 'the transport plan has a drum chart' );
like( $playback, qr/pub const MAX_STEPS: usize = 128/, 'the chart length is bounded' );
like( $playback, qr/fn render_drums\(/, 'one block renders and schedules the chart' );
like( $playback, qr/trigger_at\(voice\.index\(\), velocity, frame\)/,
	'a step lands at its own frame inside the block' );
like( $playback, qr/A transport loop always begins on chart step 0/,
	'a loop wrap restarts the chart at loop_start' );
like( $playback, qr/fn a_seek_restarts_the_drum_chart_at_the_new_position/,
	'a seek is tested as a chart restart' );
like( $playback, qr/fn a_bpm_change_keeps_the_drum_cursor_and_moves_the_next_step/,
	'a tempo change keeps the cursor' );
like( $playback, qr/fn a_retune_at_the_playhead_is_not_a_seek/,
	'and a knob turn at the playhead does not restart anything' );
like( $mixer, qr/pub fn mix_with_live_and_extra/, 'the drum bus joins the mix before the master' );
like( $mixer, qr/fn the_extra_bus_is_summed_before_the_master_chain/,
	'and the master applies to it' );

# --- the socket accepts, reports and refuses the wire shape ------------------
like( $socket, qr/fn parse_drums\(/, 'the socket parses a drum chart' );
like( $socket, qr/drums \\"length\\" is required/, 'a chart without a length is refused' );
like( $socket, qr/drums\.steps\.\{name\}\[\{index\}\] must be a whole number from 0 to 100/,
	'a velocity outside 0..100 is refused by name' );
like( $socket, qr/\\"drums\\":\{\},\\"drum_kit\\":\\"\{\}\\"/, 'status reports the chart and the loaded kit' );
like( $socket, qr/\\"drums\\":0,\\"drum_kit\\":\\"off\\"/, 'the resting transport reports no chart' );
like( $socket, qr/update needs \\"clips\\", \\"master\\", \\"master_values\\" or \\"drums\\"/,
	'a chart alone is a valid update' );

# --- the manager forwards and validates it ----------------------------------
like( $engine_pm, qr/our \@audio_engine_transport_fields = qw\([^)]*\bdrums\b/s,
	'the engine transport helper forwards drums' );
like( $controller, qr/sub studio_transport_drums/, 'the route validates the chart' );
like( $controller, qr/transport drums needs "length"/, 'a chart must name its length' );
like( $controller, qr/row \\"\$name\\" holds a value that is not a velocity 0\.\.100/,
	'a velocity is a whole number from 0 to 100' );
like( $controller, qr/update needs "clips", "master", "master_values" or "drums"/,
	'and the route accepts a chart-only update' );

# --- the page sends the chart and stops its own scheduler -------------------
like( $transport, qr/function studioEngineDrumPlan\(\)/, 'the page builds the engine chart' );
like( $transport, qr/kit: studioDrums\.kit,\s*\n\s*length: length,\s*\n\s*loop:/,
	'with the kit, length and loop the engine reads' );
is( scalar( () = $transport =~ /fields\.drums_json = JSON\.stringify\(drums\)/g ), 2,
	'the chart rides both the start and the plan update' );
like( $transport, qr/studioDrums\.engineAnchor = now/, 'the start anchors the highlight' );
like( $transport, qr/studioDrums\.engineAnchor = fields\.position/,
	'a seek moves the anchor with the chart' );
like( $transport, qr/studioDrumsTransport\(true\)/, 'a fallback hands the chart back to the browser' );

like( $drums, qr/function studioDrumsSaver\(\)/, 'a chart edit has one save path' );
like( $drums, qr/function studioDrumsSaver\(\) \{\s*\n\s*studioSaver\(\);/,
	'and it saves before it reaches the engine' );
unlike( $drums, qr/function studioDrumsSaver\(\) \{\s*\n\s*studioDrumsSaver\(\);/,
	'a save path that calls itself would recurse forever' );
like( $drums, qr/studioEngineClipsChanged\(\)/, 'and that path updates the engine while it plays' );
like( $drums, qr/if \(mixer\['time'\]\['engine_transport'\] && studioDrumsEngineChosen\(\)\) \{\s*\n\s*studioDrumsHighlightEngineStep/,
	'the browser scheduler does not play a second copy when the engine is chosen' );
like( $drums, qr/function studioDrumsHighlightEngineStep/, 'the highlight follows the engine chart' );
like( $drums, qr/studioDrumsHighlightStep\(\(step \+ steps\) % steps\)/,
	'and lands on the same step the engine is playing' );
like( $drums, qr/engineAnchor/, 'a recorded hit uses the engine grid' );

done_testing();
