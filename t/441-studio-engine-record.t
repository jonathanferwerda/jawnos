# tests-for: lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm public/js/manager/studio.js public/js/manager/studio/01_transport.js public/js/manager/studio/04_knobs.js public/js/manager/studio/05_inputs.js public/js/manager/studio/06_controls.js templates/studio/markup.html.ep templates/studio/style.html.ep perl/help/topics_apps.pl
# covers:    The transport's Record button records an interface channel on the
#            engine whenever the engine is available: the armed device tracks
#            become one engine take, a running Listen hands the capture over,
#            and the WAV the engine closes becomes a normal Studio take on each
#            channel when Stop (or the engine's own length bound) ends it. A
#            device channel and a send that ends at one go to the engine; apps,
#            screen shares, loop takes and sends with no engine-fed source stay
#            on the browser recorder, and an engine refusal falls back to it.
#            The Configure
#            Engine take block also carries the engine output picker (Sound's
#            own choice), and the transport's badge names Engine or Browser for
#            recording and playback. The take file route serves only the
#            engine-named WAV directly inside the recording folder.

use strict;
use warnings;
no warnings 'once';

use Cwd qw(abs_path);
use FindBin;
use File::Basename qw(basename);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec ();
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
like($record, qr/studioEngineTakeCanTake\(a\.ch/, 'a device channel or an engine-fed send is handed to the engine');
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
like($start, qr/request\.monitor_track = monitor_track/, 'and names the one track the monitor carries');
like($studio, qr/plan\[index\[w\.ch\]\]\.from = index\[src\]/, 'a send travels as the source\'s plan index');
like($studio, qr/function studioEngineTakeCanTake/, 'a send chain is engine-recordable when it ends at a device input');
like($start, qr/click_json: click \? JSON\.stringify\(click\) : ''/, 'the take owns the click when no transport does');
like($start, qr/request\.align_samples = Math\.round\(pageOffset \* rate\)/,
	'the page sends its own record offset as the engine\'s align_samples');
like($start, qr/studioRecordOffset\(null\)/, 'using the same offset the browser path measures');
like($start, qr/data\.first_sample/, 'the take is placed by the engine\'s reported first sample');
like($start, qr/data\.align_from === 'measured' \|\| data\.align_from === 'given'/,
	'and only trusts that placement when the engine names a measured or given offset');
like($start, qr/studioEngineTakeArmed = \{/, 'the start remembers which channel each track records');

my $finish = body($studio, 'studioEngineTakeFinish');
ok(length $finish, 'closing the take has one finish path');
like($finish, qr/manager\/studio\/take_file\?file=/, 'the closed WAV is served back to the page');
like($finish, qr/frames \/ rate/, 'its frame count becomes the take\'s duration');
like($finish, qr/mixer\[ch\]\.media\.out\[ir\] = take/, 'the WAV becomes a normal take on its channel');
like($finish, qr/studioEngineTakeReadFile\(take, src\)/, 'the take reads its WAV for saving and decoding');
my $read = body($studio, 'studioEngineTakeReadFile');
ok(length $read, 'the read has one function');
like($read, qr/fetch\(src\)/, 'it fetches the engine\'s closed file');
like($read, qr/take\.data = blob/, 'and keeps the bytes the save uploads');
like($read, qr/take\.file_ready = read/, 'a Save can wait for the read');

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
like($help, qr/pressing Save copies that WAV into the song/,
	'and says an engine take travels with the song');

# --- Save adopts the engine's file on the server ---------------------------
# The engine take is already a file on this machine, so Save copies it into the
# song's folder itself: no browser download and upload, one copy per distinct
# source, a uuid on each take, and the temporary file queued for removal after
# the song is encrypted.
like($controller, qr/sub studio_engine_take_source_path/, 'the take-file source is recognised');
like($controller, qr/sub studio_engine_take_adopt/, 'Save has one adoption helper');
like($controller, qr{studio-take-.d\+}, 'only an engine take name is adopted');
like($controller, qr/push \@\{\$files\}, \{ f => \$target, uuid => \$take_uuid, type => 'recording' \}/,
	'the copy becomes a song file');
like($controller, qr/foreach my \$path \( \@\{ \$adopted->\{'remove'\} \|\| \[\] \} \) \{[\s\S]{0,200}unlink \$path/,
	'the originals are removed after the song is written');
like($controls, qr/mixer\[i\]\.media\.out\[ir\]\.src = take\.src/,
	'the page keeps the portable URL the server returned');

require "$root/lib/JawnOS/Controller/manager_misc9.pm";
{
	package subs;
	our $uuid_seen = 0;
	sub path_name { my $name = shift; $name =~ s/[^A-Za-z0-9_.-]+/_/g; return $name; }
	sub random_string_creator { return 'take-uuid-' . ++$uuid_seen; }
}

my $rec = tempdir(CLEANUP => 1);
my $song_dir = File::Spec->catdir($rec, 'Song');
make_path($song_dir);
my $engine_wav = File::Spec->catfile($rec, 'studio-take-1700000000-1.wav');
write_file($engine_wav, "RIFF-fake-take");
my $outside_dir = tempdir(CLEANUP => 1);
my $outside_wav = File::Spec->catfile($outside_dir, 'studio-take-1700000000-2.wav');
write_file($outside_wav, "RIFF-outside");
my $not_take = File::Spec->catfile($rec, 'not-a-take.wav');
write_file($not_take, "RIFF-other");

my $take_url = sub {
	my $path = shift;
	$path =~ s{/}{%2F}g;
	return '/manager/studio/take_file?file=' . $path;
};
my $data = {
	1 => { mixer => { out => [ { src => $take_url->($engine_wav) }, { src => $take_url->($engine_wav) } ] } },
	2 => { mixer => { out => [ { src => $take_url->($outside_wav) } ] } },
	3 => { mixer => { out => [ { src => $take_url->($not_take) } ] } },
};
my @adopted_files;
my $adopted;
{
	local *Manager::studio_take_folder = sub { $rec };
	is(Manager::studio_engine_take_source_path($take_url->($outside_wav)), undef,
		'a take name outside the recording folder is refused');
	is(Manager::studio_engine_take_source_path($take_url->($not_take)), undef,
		'a file that is not an engine take name is refused');
	$adopted = Manager::studio_engine_take_adopt($data, $song_dir, 'Song', 'STAMP', \@adopted_files);
}
is($adopted->{'adopted'}, 1, 'one distinct engine source is adopted');
is(scalar @adopted_files, 1, 'it becomes one song file');
like($adopted_files[0]{'f'}, qr{/Song/Song_STAMP_1_0\.wav\z}, 'the copy lives in the song folder');
ok(-f $adopted_files[0]{'f'}, 'the copy exists');
is($data->{1}{mixer}{out}[0]{'uuid'}, $data->{1}{mixer}{out}[1]{'uuid'},
	'both takes indexing one source share its uuid');
like($data->{1}{mixer}{out}[0]{'src'}, qr{\A/file_open\?file=}, 'the saved source is portable');
ok(!$data->{2}{mixer}{out}[0]{'uuid'}, 'a source outside the folder is not adopted');
ok(!$data->{3}{mixer}{out}[0]{'uuid'}, 'a non-take file is not adopted');
is_deeply($adopted->{'remove'}, [abs_path($engine_wav)], 'the original is queued for removal');
unlink $_ for @{ $adopted->{'remove'} };
ok(!-e $engine_wav, 'and is gone once the song is written');
ok(-e $outside_wav, 'an outside file was never touched');

# --- the take file route serves a -chN file and only inside the folder ------
{
	package TakeFileCtx;
	sub new   { return bless { params => $_[1], status => 200 }, $_[0] }
	sub param { return $_[0]->{'params'}{$_[1]} }
	sub res   { return $_[0]->{'res'} ||= bless {}, 'TakeFileRes' }
	sub reply { return $_[0]->{'reply'} ||= bless {}, 'TakeFileReply' }
	sub render {
		my ($self, @args) = @_;
		while (@args) {
			my $name  = shift @args;
			my $value = shift @args;
			$self->{$name} = $value;
		}
	}
	package TakeFileRes;
	sub headers { return $_[0] }
	sub content_type {
		my ($self, $value) = @_;
		$self->{'content_type'} = $value if @_ > 1;
		return $self->{'content_type'};
	}
	sub cache_control {
		my ($self, $value) = @_;
		$self->{'cache_control'} = $value if @_ > 1;
		return $self->{'cache_control'};
	}
	package TakeFileReply;
	sub file { $_[0]->{'file'} = $_[1]; return $_[0] }
	package main;

	my $serve_dir = tempdir(CLEANUP => 1);
	my $serve_ch = File::Spec->catfile($serve_dir, 'studio-take-1700000003-1-ch2.wav');
	write_file($serve_ch, 'RIFF-ch');
	my $outside_dir = tempdir(CLEANUP => 1);
	my $outside = File::Spec->catfile($outside_dir, 'studio-take-1700000003-2-ch1.wav');
	write_file($outside, 'RIFF-outside');

	local *Manager::studio_take_folder = sub { $serve_dir };

	my $served = TakeFileCtx->new({ file => $serve_ch });
	Manager::action_44045($served);
	is($served->{'reply'}{'file'}, abs_path($serve_ch), 'a -chN take is served by its own name');
	is($served->{'res'}{'content_type'}, 'audio/wav', 'as a WAV');
	is($served->{'res'}{'cache_control'}, 'private, no-store', 'with no browser cache');
	ok(!exists $served->{'json'}, 'and not as a refusal');

	my $cross = TakeFileCtx->new({ file => $outside });
	Manager::action_44045($cross);
	is($cross->{'status'}, 404, 'a take outside the recording folder is refused');
	ok(!exists $cross->{'reply'}{'file'}, 'and no file is handed to the reply');

	my $traversal = TakeFileCtx->new({
		file => File::Spec->catfile($serve_dir, '..', basename($outside_dir), basename($outside)),
	});
	Manager::action_44045($traversal);
	is($traversal->{'status'}, 404, 'a traversal to that same name is refused');
	ok(!exists $traversal->{'reply'}{'file'}, 'and hands back nothing');
}

done_testing();
