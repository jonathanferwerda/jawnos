# tests-for: engine/src/playback.rs engine/src/socket.rs lib/JawnOS/Audio/Engine.pm lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm public/js/manager/studio/01_transport.js public/js/manager/studio/11_drums.js public/js/manager/synth/01_engine.js templates/studio/drums.html.ep templates/synth.html.ep perl/help/topics_apps.pl
# covers:    the choice between the engine's voices and the browser's, so a
#            person can audition what the transport will play. The drum panel
#            carries a Sound list saved with the song; the synth app carries its
#            own Sound list in localStorage. Chosen for the engine, the synth
#            hands its patch and its notes to the running transport, the drum
#            pads hit the engine's kit, and the browser copies are muted. Chosen
#            for the browser, the chart is silenced on the engine and the
#            browser plays; with no transport the browser always sounds, so a
#            pad or a key is never silent. The engine refuses all of these
#            commands while no transport plays, because the output is the song's.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root = abs_path("$FindBin::Bin/..");

my $playback   = read_file("$root/engine/src/playback.rs");
my $socket     = read_file("$root/engine/src/socket.rs");
my $engine_pm  = read_file("$root/lib/JawnOS/Audio/Engine.pm");
my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my $routes     = read_file("$root/lib/JawnOS/Routes/manager_misc9.pm");
my $transport  = read_file("$root/public/js/manager/studio/01_transport.js");
my $drums      = read_file("$root/public/js/manager/studio/11_drums.js");
my $synth      = read_file("$root/public/js/manager/synth/01_engine.js");
my $drums_tpl  = read_file("$root/templates/studio/drums.html.ep");
my $synth_tpl  = read_file("$root/templates/synth.html.ep");
my $help       = read_file("$root/perl/help/topics_apps.pl");

# --- the engine renders the synth on the running transport ------------------
like( $playback, qr/pub synth: Option<SynthPlan>/, 'the transport plan carries a synth' );
like( $playback, qr/fn apply_synth_plan\(/, 'a patch is applied at the plan edge' );
like( $playback, qr/render\.synth|self\.synth/, 'the synth renders on the transport' );
like( $playback, qr/fn render_synth\(/, 'one block of synth audio' );
like( $playback, qr/app_stereo/, 'drums and synth share one pre-master bus' );
like( $playback, qr/set_patch/, 'a live patch keeps the sounding voices' );
like( $playback, qr/fn apply_note\(/, 'note events reach the synth' );
like( $playback, qr/fn apply_hit\(/, 'an auditioned drum hit reaches the machine' );
like( $playback, qr/let relength = render\.chart\.length != chart\.length/,
	'a chart switch restarts the engine cursor' );

# --- the socket has the voice commands --------------------------------------
like( $socket, qr/fn synth_command\(/, 'the synth command exists' );
like( $socket, qr/fn drums_command\(/, 'the drums command exists' );
like( $socket, qr/fn parse_synth_patch\(/, 'the browser patch is parsed, not passed through' );
like( $socket, qr/\\"drums\\":\{\},\\"drum_kit\\":\\"\{\}\\",\\"synth\\":\{\}/, 'status reports the synth beside the drums' );
like( $socket, qr/\\"synth\\":0,\\"monitor_input\\"/, 'a resting transport reports no synth' );

# --- the manager forwards them through one helper ---------------------------
like( $engine_pm, qr/sub audio_engine_synth/, 'the Perl client speaks the synth command' );
like( $engine_pm, qr/sub audio_engine_drum_hit/, 'and the one-shot drum hit' );
like( $engine_pm, qr/our \@audio_engine_synth_fields = qw\([^)]*\bpatch\b[^)]*\bnote\b/s,
	'only the promised synth fields are forwarded' );
like( $routes, qr/\[44035, 'post', '\/manager\/studio\/synth', 'action_44035'\]/,
	'the synth route is registered' );
like( $routes, qr/\[44036, 'post', '\/manager\/studio\/drums', 'action_44036'\]/,
	'and the drum hit route' );
like( $controller, qr/sub action_44035/, 'the synth action exists' );
like( $controller, qr/sub action_44036/, 'the drums action exists' );
like( $controller, qr/a synth note needs "note": a whole number from 0 to 127/,
	'a note is validated' );
like( $controller, qr/a synth patch must be a JSON object/, 'a patch must be an object' );
like( $controller, qr/a drum hit "velocity" must be a whole number from 1 to 100/,
	'a hit velocity is validated' );

# --- the drum panel chooses the engine or the browser -----------------------
like( $drums, qr/sound: 'engine'/, 'the chart defaults to the engine' );
like( $drums, qr/sound: studioDrums\.sound === 'browser' \? 'browser' : 'engine'/,
	'the choice is saved with the song' );
like( $drums, qr/function studioDrumsEngineChosen\(\)/, 'one question names the choice' );
like( $drums, qr/function studioDrumsEngineHit\(/, 'a pad can hit the engine kit' );
like( $drums, qr#url: '/manager/studio/drums'#, 'through the drums route' );
like( $drums, qr/studioDrums\.sound === 'engine' && mixer/, 'the engine is used only when chosen' );
like( $drums, qr/studioDrumsEngineChosen\(\)\) \{\s*\n\s*studioDrumsHighlightEngineStep/,
	'with the engine chosen the browser scheduler stays quiet' );
like( $drums, qr/studioDrumsTransport\(false\);\s*\n\s*if \(studioDrums\.sound === 'browser'\)/,
	'a live switch re-anchors the browser chart' );
like( $drums_tpl, qr/id="studio_drums_sound"/, 'the panel has a Sound list' );
like( $drums_tpl, qr/<option value="engine">.*<option value="browser">/s,
	'with the two voices' );

# --- the synth app chooses too, and hands the engine its patch ---------------
like( $synth, qr/S\.post = ctx\.createGain\(\)/, 'the synth has one mute point' );
like( $synth, qr/outputNode: function \(\) \{ return S\.post/, 'every consumer taps it' );
like( $synth, qr/mute: function \(on\)/, 'mute is part of the app API' );
like( $synth, qr/jawnos_synth_sound/, 'the choice is remembered' );
like( $synth, qr#url: '/manager/studio/synth'#, 'notes and the patch go to the engine route' );
like( $synth, qr#url: '/manager/studio/transport'#, 'the app watches the transport state' );
like( $synth, qr/engineSendPatch|action: 'patch'/, 'the patch is sent once per change' );
like( $synth, qr/engineApi\('note'/, 'a key event is one note' );
like( $synth, qr/engineApi\('all_off'/, 'letting go releases every engine voice' );
like( $synth, qr/engineFallback/, 'a refused note falls back to the browser' );
like( $synth_tpl, qr/id="synth_sound"/, 'the synth toolbar has a Sound list' );
like( $synth_tpl, qr/<option value="engine" selected>.*<option value="browser">/s,
	'with the engine first' );

# --- the transport silences the engine chart for the browser choice ---------
like( $transport, qr/typeof studioDrumsEngineChosen === 'function' && !studioDrumsEngineChosen\(\)/, 'the plan asks the choice' );
like( $transport, qr/return \{ kit: studioDrums\.kit, length: 1, loop: 0, steps: \{\} \}/,
	'a silent chart turns the engine kit off' );

# --- the guide explains the choice ------------------------------------------
like( $help, qr/Play the kit on the engine or in the browser/, 'the Studio guide names the drum choice' );
like( $help, qr/Choose where the synth plays|Where the notes are made/, 'and the synth choice' );

done_testing();
