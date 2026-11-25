# tests-for: engine/src/playback.rs engine/src/socket.rs lib/JawnOS/Audio/Engine.pm lib/JawnOS/Controller/manager_misc9.pm
# covers:    the Studio note clips play on the engine's clock with the engine's own
#            voices, one synth patch per clip. The transport plan carries a
#            `synth_clips` object: a patch, notes in beats (`t`/`d`), the clip's
#            timeline `start`, its `beats` length, loop, channel, gain, pan and
#            inserts. The engine builds one `jawn_synth::Synth` per clip at the
#            plan edge, schedules each note on/off sample-accurately by rendering
#            in segments between events, restretches with the transport's BPM,
#            routes each clip through its own AppStrip to its channel or the
#            pre-master bus, releases every clip voice on a seek or a loop wrap
#            (a note already under the playhead is not retriggered), and rebuilds
#            the clips at a block edge on a plan replacement. The socket parses,
#            bounds, reports and refuses the wire shape by field; the manager
#            forwards it through `@audio_engine_transport_fields` and validates
#            it at the route.

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

ok( length $playback,   'the transport source is found' );
ok( length $socket,     'the engine socket is found' );
ok( length $engine_pm,  'the engine client is found' );
ok( length $controller, 'the manager route is found' );

# --- the plan carries scheduled clips ---------------------------------------
like( $playback, qr/pub struct SynthClip/, 'the transport plan has a scheduled clip' );
like( $playback, qr/pub struct SynthNote/, 'a clip has notes in beats' );
like( $playback, qr/pub synth_clips: Option<Vec<SynthClip>>/,
	'the replacement plan carries the clips' );
like( $playback, qr/pub looped: bool/, 'a clip says whether it repeats' );
like( $playback, qr/pub channel: Option<usize>/, 'and which channel it follows' );
like( $playback, qr/pub fn with_synth_clips/, 'the source can be built with a clip plan' );

# --- one synth per clip, rendered between events ----------------------------
like( $playback, qr/fn render_synth_clips\(/, 'the block renders the scheduled clips' );
like( $playback, qr/Synth::new\(clip\.patch, rate as f32\)/,
	'one synth is built per clip, from that clip\'s patch' );
like( $playback, qr/fn render_seg\(/, 'the synth renders in segments between events' );
like( $playback, qr/partition_point\(\|entry\| entry\.0 < local\)/,
	'a seek skips onsets already behind the playhead' );
like( $playback, qr/A note already under the playhead is not retriggered/,
	'and that rule is documented in the source' );
like( $playback, qr/fn local_at\(/, 'the clip cursor is derived from the song frame' );
like( $playback, qr/\(note\.d\.max\(0\.0\) \* fpb\)\.round\(\)/,
	'note lengths convert from beats to frames' );
like( $playback, qr/frames_per_beat\(bpm_bits, self\.rate\)/,
	'a tempo change restretches the notes' );
like( $playback, qr/AppStrip::new\(&route, rate, period\)/,
	'each clip gets its own app strip' );
like( $playback, qr/for render in clip_renders\.iter_mut\(\)/,
	'each clip routes through the app router' );
like( $playback, qr/render\.synth\.all_notes_off\(\)/,
	'a plan edge releases the outgoing clip voices' );
like( $playback, qr/retired_clips/, 'a retired clip keeps its release tail' );

# --- the tests pin the behaviour -------------------------------------------
like( $playback, qr/fn a_scheduled_clip_sounds_at_its_note_and_stops_at_its_end/,
	'a clip sounds on its beat and stops at its end' );
like( $playback, qr/fn a_looped_clip_repeats_every_clip_length/, 'a loop repeats' );
like( $playback, qr/fn a_seek_releases_a_clip_and_does_not_retrigger_a_note_under_the_playhead/,
	'a seek releases without retriggering' );
like( $playback, qr/fn a_scheduled_clip_follows_its_channel_or_the_master_bus/,
	'a clip follows its channel or the master bus' );
like( $playback, qr/fn a_plan_replaces_scheduled_clips_without_reopening_the_device/,
	'an update replaces the clips with the device open' );

# --- the socket accepts, bounds, reports and refuses the shape --------------
like( $socket, qr/fn parse_synth_clips\(/, 'the socket parses a synth-clip plan' );
like( $socket, qr/const MAX_SYNTH_CLIPS: usize = 64/, 'the clip count is bounded' );
like( $socket, qr/const MAX_SYNTH_CLIP_NOTES: usize = 4096/, 'the note count is bounded' );
like( $socket, qr/parse_synth_patch\(get\(fields, "patch"\)\)/,
	'a clip patch reuses the synth patch reader' );
like( $socket, qr/\{label\}\.notes\[\{slot\}\]/, 'a note error names its clip and slot' );
like( $socket, qr/\.n must be a whole MIDI note from 0 to 127/,
	'a note number outside 0..127 is refused by name' );
like( $socket, qr/\.d must be a finite number of beats greater than zero/,
	'a zero note length is refused by name' );
like( $socket, qr/\.beats must be a finite number of beats greater than zero/,
	'a clip needs a positive length' );
like( $socket, qr/\.channel must be a whole number from 1 to 32/,
	'and a channel in range' );
like( $socket, qr/\.inserts\[\{slot\}\]: no such insert/, 'and an insert the engine knows' );
like( $socket, qr/\\"synth_clips\\":\{\}/, 'status reports the scheduled clip count' );
like( $socket, qr/\\"synth_clips\\":0/, 'the resting transport reports no clips' );
like( $socket, qr/Ok\(SynthClipsField::Touch\)/, 'an object with no clips array leaves the plan alone' );
like( $socket, qr/synth_clips_requested/, 'a playing start accepts the clip plan' );
like( $socket, qr/update needs \\"clips\\", \\"master\\", \\"master_values\\", \\"drums\\", \\"sends\\" or \\"synth_clips\\"/,
	'a clip plan alone is a valid update' );
like( $socket, qr/with_synth_clips\(synth_clips\)/, 'the start hands the clips to the render source' );

# --- the manager forwards and validates it ----------------------------------
like( $engine_pm, qr/our \@audio_engine_transport_fields = qw\([^)]*\bsynth_clips\b/s,
	'the engine transport helper forwards synth_clips' );
like( $controller, qr/sub studio_transport_synth_clips/, 'the route validates the clip plan' );
like( $controller, qr/synth_clips_json/, 'and reads the JSON field the page sends' );
like( $controller, qr/carries more than 64 clips/, 'the clip count is bounded at the route' );
like( $controller, qr/has more than 4096 notes/, 'and the note count' );
like( $controller, qr/n must be a whole MIDI note from 0 to 127/,
	'a note number is checked at the route' );
like( $controller, qr/d must be a number of beats greater than zero/,
	'and the note length' );
like( $controller, qr/pan must be a number from -1 to 1/,
	'and the pan range' );
like( $controller, qr/\$fields\{'synth_clips'\} = \$synth_clips/, 'the route forwards the cleaned plan' );
like( $controller, qr/update needs "clips", "sends", "master", "master_values", "drums" or "synth_clips"/,
	'and a clip-only update is a real update' );

done_testing();
