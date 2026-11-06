# tests-for: lib/JawnOS/Manager/Part34.pm lib/JawnOS/Manager/Part05.pm lib/JawnOS/Domain/Edt.pm lib/JawnOS/Domain/Render.pm lib/JawnOS/Controller/manager_watch.pm templates/embedded/component.html.ep
# covers:    An embedded input pin can be a Video or Audio movement: the pin editor
#            offers the kind and the recording machine, the press writes a record row
#            that only the chosen machine claims, and a second press stops it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root   = repo_root();
my $part34 = read_file("$root/lib/JawnOS/Manager/Part34.pm");
my $part05 = read_file("$root/lib/JawnOS/Manager/Part05.pm");
my $edt    = read_file("$root/lib/JawnOS/Domain/Edt.pm");
my $render = read_file("$root/lib/JawnOS/Domain/Render.pm");
my $watch  = read_file("$root/lib/JawnOS/Controller/manager_watch.pm");
my $tpl    = read_file("$root/templates/embedded/component.html.ep");

# --- the movement catalogue ---------------------------------------------------

my @catalogues = $part34 =~ /^(.*qw\/usual command kill record start toggle measure.*)$/mg;
is(scalar @catalogues, 2, 'both embedded movement catalogues are present');
like($_, qr/\bvideo\b/, "a catalogue offers video: $_") foreach @catalogues;
like($_, qr/\baudio\b/, "a catalogue offers audio: $_") foreach @catalogues;

# --- the pin editor's second dropdowns ---------------------------------------

like($tpl, qr/setting="media_kind"/, 'the pin editor has a media kind select');
like($tpl, qr/setting="media_machine"/, 'the pin editor has a recording machine select');
like($tpl, qr/\$media_movement eq 'video' \|\| \$media_movement eq 'audio'/,
	'both controls are rendered only for the video/audio movements');
like($tpl, qr/&subs::ui\('Camera \(rear\)'\)/, 'the video kind offers the rear camera');
like($tpl, qr/&subs::ui\('Camera \(front\)'\)/, 'the video kind offers the front camera');
like($tpl, qr/&subs::ui\('Microphone'\)/, 'the audio kind offers the microphone');
like($tpl, qr/&subs::ui\('System audio'\)/, 'the audio kind offers system audio');
like($tpl, qr/&subs::ui\('This machine'\)/, 'the machine select keeps this machine');
like($tpl, qr/\$settings->\{\$syl \. \$n\}->\{'media_kind'\}/, 'the stored kind is selected');
like($tpl, qr/\$settings->\{\$syl \. \$n\}->\{'media_machine'\}/, 'the stored machine is selected');

# --- assigning an app keeps the media choices --------------------------------

my ($assign) = $watch =~ /(sub action_43926 \{.*?\n\})/s;
ok($assign, 'the pin assign action is still one sub');
my @kept = $assign =~ /media_kind => \$op_d->\{\$syl \. \$numero\}->\{'media_kind'\}/g;
is(scalar @kept, 2, 'the rebuilt pin entry and ia entry both keep media_kind');
@kept = $assign =~ /media_machine => \$op_d->\{\$syl \. \$numero\}->\{'media_machine'\}/g;
is(scalar @kept, 2, 'the rebuilt pin entry and ia entry both keep media_machine');

# --- the press: video/audio are record presses -------------------------------

my ($press) = $edt =~ /(sub edt_button_presser \{.*?\n\})/s;
ok($press, 'edt_button_presser is still one sub');
like($press, qr/\$movement eq 'video' \|\| \$movement eq 'audio'.*?\$movement = 'stop'/s,
	'a second video/audio press flips to stop');
like($press, qr/\$db_data->\{'type'\} = 'record'/, 'video/audio writes a record row');
like($press, qr/\$db_data->\{'recorder'\} = &Manager::record_source_param\(\$kind\)/,
	'the row recorder is the chosen media kind, within the known sources');
like($press, qr/\$db_data->\{'machine'\} = \$b->\{'media_machine'\} \|\| &subs::signatorial_designer\(\)/,
	'the row names the chosen machine, or this one when none is set');
like($press, qr/\$db_data->\{'camera'\} = \$kind eq 'video_front' \? 1 : 0/,
	'a video kind records which camera');
like($press, qr/delete \$db_data->\{'uuid'\}/,
	'a stop carries no invented session uuid');

# --- the writer: machine/camera in the data, media rows unseen ---------------

my ($writer) = $part05 =~ /(sub appointment_writer\(.*?\n\})/s;
ok($writer, 'appointment_writer is still one sub');
my @dat = $writer =~ /my \$dat = \{ recorder => \$recording_type, machine => \(\$pressed_machine \|\| ''\) \};/g;
is(scalar @dat, 2, 'both record branches write the machine into the row data');
my @front = $writer =~ /elsif \(\$recording_type eq 'video_front'\)/g;
is(scalar @front, 2, 'both record branches know the front camera source');
my @camera = $writer =~ /\$dat->\{'camera'\} = /g;
is(scalar @camera, 4, 'both record branches carry the camera for video sources');
like($writer, qr/my \$capture_source = .*?record_source_param\(\$pressed_recorder\)/s,
	'the writer reads the source the press named');
like($writer, qr/\$capture_source =~ \/\^\(\?:video\|video_front\|audio\|screen\)\$\//,
	'a capture row is left for the Alarm loop to claim');
like($writer, qr/\$named_source && \$named_source eq 'system'/,
	'a press naming system audio is claimed by the chosen machine too');
like($writer, qr/my \$preset = \{ recorder => \$named_source, machine => \(\$pressed_machine \|\| ''\) \};/,
	'the media row is complete before it is inserted, so a sync cannot expose a data-less row');
like($writer, qr/elsif \(\$app->\{'timestamp'\} <= \$app->\{'server_time'\} \+ 1000\) \{\n\t\t\$app->\{'seen'\} = 'yes';/,
	'only a non-capture row is stamped seen');
like($writer, qr/movement => 'stop'.*?uuid => \$appt->\{'uuid'\}/s,
	'a remote capture is stopped on the machine that owns it');

# --- the relay carries the stop's own session --------------------------------

my ($relay) = $render =~ /(sub destination_relay \{.*?\n\})/s;
ok($relay, 'destination_relay is still one sub');
like($relay, qr/foreach my \$field \( qw\/uuid recorder camera machine\/ \)/,
	'the relay forwards the stop\'s session id and source');
like($relay, qr/\$form->\{'remote_signatorial'\} = \$destination/,
	'the relay names the machine it is sent to');

done_testing();
