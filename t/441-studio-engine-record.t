# tests-for: lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm public/js/manager/studio.js public/js/manager/studio/01_transport.js public/js/manager/studio/04_knobs.js public/js/manager/studio/05_inputs.js public/js/manager/studio/06_controls.js templates/studio/markup.html.ep templates/studio/style.html.ep perl/help/topics_apps.pl
# covers:    The transport's Record button records an interface channel on the
#            engine whenever the engine is available: the armed device tracks
#            become one engine take, a running Listen hands the capture over,
#            and the WAV the engine closes becomes a normal Studio take on each
#            channel when Stop (or the engine's own length bound) ends it. Apps,
#            screen shares, channel sends and loop takes stay on the browser
#            recorder, and an engine refusal falls back to it. The Configure
#            Engine take block also carries the engine output picker (Sound's
#            own choice), and the transport's badge names Engine or Browser for
#            recording and playback. The take file route serves only the
#            engine-named WAV directly inside the recording folder.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root = abs_path("$FindBin::Bin/..");

my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my $routes     = read_file("$root/lib/JawnOS/Routes/manager_misc9.pm");
my $studio     = read_file("$root/public/js/manager/studio.js");
my $transport  = read_file("$root/public/js/manager/studio/01_transport.js");
my $knobs      = read_file("$root/public/js/manager/studio/04_knobs.js");
my $inputs     = read_file("$root/public/js/manager/studio/05_inputs.js");
my $controls   = read_file("$root/public/js/manager/studio/06_controls.js");
my $markup     = read_file("$root/templates/studio/markup.html.ep");
my $help       = read_file("$root/perl/help/topics_apps.pl");

sub body {
	my ($src, $name) = @_;
	my ($b) = $src =~ /^(?:async )?function \Q$name\E\([^)]*\) \{(.*?)^\}/ms;
	return defined $b ? $b : '';
}

sub sub_body {
	my ($src, $name) = @_;
	my ($b) = $src =~ /^sub \Q$name\E \{(.*?)^\}/ms;
	return defined $b ? $b : '';
}

# --- the take file route -----------------------------------------------------
like($routes, qr/\[44045, 'get', '\/manager\/studio\/take_file', 'action_44045'\]/,
	'the engine take file has a GET route');
my $serve = sub_body($controller, 'action_44045');
ok(length $serve, 'the route is one action');
like($serve, qr/studio_take_folder\(\)/, 'the recording folder is the route\'s own boundary');
like($serve, qr/\\Astudio-take-\\d\+-\\d\+\(\?:-ch\\d\+\)\?\\\.wav\\z/,
	'only the engine take name is served');
like($serve, qr/content_type\('audio\/wav'\)/, 'the answer is a WAV');
like($serve, qr/reply->file\(\$path\)/, 'the route hands the file to the reply');
unlike($serve, qr/reply->file\(\$asked\)/, 'the request path is never the file handed to the reply');

# --- Record splits engine and browser --------------------------------------
my $record = body($inputs, 'studioRecord');
ok(length $record, 'the Record button has one function');
like($record, qr/studioAudioBackend\(\) === 'engine'/, 'the house engine is the only native backend Record hands over to');
like($record, qr/studioEngineAvailable !== false/, 'a socket the page has already lost keeps the browser recorder');
like($record, qr/studioEngineTakeChannel\(a\.ch\)/, 'only an interface channel is handed to the engine');
like($record, qr/studioEngineTakeStart\(engine_takes, punch/, 'the engine take starts at the punch');
like($record, qr/studioStartTake\(a\.ch, a\.loop, punch\)/, 'the remaining takes stay on the browser recorder');
like($record, qr/studioEngineTakeBrowserFallback\(engine_takes, punch\)/,
	'a refused engine take hands the channels back to the browser');
like($record, qr/engine_pending: \{ takes: engine_takes, punch: punch \}|engine_pending'\] = engine_takes\.length/,
	'a count-in holds the engine take until the punch-in beat');

my $pending = body($inputs, 'studioStartPendingTakes');
like($pending, qr/engine_pending/, 'the pending takes include the engine\'s share');
like($pending, qr/studioEngineTakeStart\(engine_pending\.takes, punch/,
	'they start on the same punch-in beat');

# --- the engine take's plan, report and import ------------------------------
like($studio, qr/function studioEngineTakeChannel/, 'one function decides what the engine can take');
my $take_channel = body($studio, 'studioEngineTakeChannel');
like($take_channel, qr/studioInputIsDevice\(plug\)/, 'a real interface input is engine-recordable');
unlike($take_channel, qr/studioInputIsApp\(plug\)\) \{ return true/, 'an app input is not');

my $start = body($studio, 'studioEngineTakeStart');
ok(length $start, 'the engine take start is one function');
like($start, qr/studioEngineTakeListenRelease/, 'a running Listen is released before the take opens the input');
like($start, qr/tracks_json: JSON\.stringify\(built\.plan\)/, 'the per-track plan rides the take');
like($start, qr/seconds: 3600/, 'a Record take is not cut off by the ten-second default');
like($start, qr/monitor_input: monitor \? 'true' : 'false'/, 'the monitored channel arms the take\'s live input');
like($start, qr/click_json: click \? JSON\.stringify\(click\) : ''/, 'the take owns the click when no transport does');
like($start, qr/studioEngineTakeArmed = \{/, 'the start remembers which channel each track records');

my $finish = body($studio, 'studioEngineTakeFinish');
ok(length $finish, 'closing the take has one finish path');
like($finish, qr/manager\/studio\/take_file\?file=/, 'the closed WAV is served back to the page');
like($finish, qr/frames \/ rate/, 'its frame count becomes the take\'s duration');
like($finish, qr/mixer\[ch\]\.media\.out\[ir\] = take/, 'the WAV becomes a normal take on its channel');
like($finish, qr/studioTakeRequestBuffer\(take\)/, 'the ordinary waveform path decodes it');

like($studio, qr/var wasRecording = studioEngineRecording;[\s\S]{0,1200}studioEngineTakeFinish\(data\)/,
	'a take that ends on its own is imported too');

# --- the badge and the output picker ---------------------------------------
like($studio, qr/function studioAudioPathRender/, 'the transport has one badge renderer');
like($studio, qr/'Engine recording' : 'Browser recording'/, 'recording names its side');
like($studio, qr/'Engine playback' : 'Browser playback'/, 'playback names its side');
like($transport, qr/studioAudioPathRender\(\)/, 'the engine transport updates the badge');
like($knobs, qr/studioAudioPathRender\(\)/, 'the first frame paints it too');

like($controls, qr/function studioOutputLoad/, 'the output picker has one loader');
like($controls, qr#url: '/manager/sound/plan'#, 'it reads the Sound plan\'s device list');
like($controls, qr/function studioOutputApply/, 'and one apply');
like($controls, qr#url: '/manager/sound/device'#, 'the write is Sound\'s own device route');
like($controls, qr/studioAudioPathRender\(\)/, 'a device choice repaints the badge');

like($markup, qr/id="studio_output_device"/, 'Configure carries the output dropdown');
like($markup, qr/id="studio_output_apply"/, 'with its own apply button');
like($markup, qr/id="studio_audio_path"/, 'the transport carries the Engine/Browser badge');

# --- Stop closes the engine take -------------------------------------------
my $stop = body($controls, 'studioStop');
like($stop, qr/studioEngineTakeArmed[\s\S]{0,120}studioEngineStop\(\)/,
	'Stop closes the Record take on the engine');

# --- the help topic describes the new path ---------------------------------
like($help, qr/Output chooses the interface the engine plays and records through/,
	'the help topic names the output picker');
like($help, qr/Record button uses the engine whenever it is available/,
	'and says Record prefers the engine');
like($help, qr/Engine recording or Browser recording/, 'and names the badge\'s two words');
like($help, qr/pressing Record while Listen is on hands the capture to the take/,
	'and says Listen hands the capture to a take');

done_testing();
