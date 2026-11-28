# tests-for: lib/JawnOS/Manager/Part29.pm lib/JawnOS/Domain/Ai.pm lib/JawnOS/Domain/VoiceFunnel.pm lib/JawnOS/Controller/manager_help.pm
# covers:    The Guide's media make is one path: guide_generate_media normalises the
#           kind and prompt, sends the mail agent settings to generate_ai_media and
#           reports where the file landed; a spoken "make an image of ..." runs the
#           same helper and speaks the outcome; the media apps are offered the verb.

use strict;
use warnings;
use utf8;
$| = 1;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

require './perl/help.pl';
require 'JawnOS/Manager/Part29.pm';
require 'JawnOS/Domain/Ai.pm';
require 'JawnOS/Domain/VoiceFunnel.pm';
&subs::preload($_) for qw(voice_brain voice_card_show voice_funnel_enabled
	voice_funnel_verbs ai_role_models ai_role_thinking_effective
	evaluation_model_call_role guide_resolve_action controller_builder watch_reply
	setting_grabber rightNow unformat_name format_name settings_grabber
	generate_ai_media);

package TestLog;
sub info { }
sub warn { }
sub error { }
package main;

my @media;
my $media_url = '/media/made.png';
my $settings = { text_to_image_assistant => 'img-model', text_to_audio_assistant => 'audio-model', text_to_video_assistant => 'video-model' };
local *subs::settings_grabber = sub { return $settings };
local *subs::generate_ai_media = sub { push @media, { %{ $_[0] } }; return ($media_url, undef) };
local *subs::rightNow = sub { return 1_800_000_000_000 };

# ------------------------------------------------------------ the helper
my $r = Manager::guide_generate_media('image', '  a red barn at dawn  ', 'Kitchen Renovation');
ok($r->{'ok'}, 'the helper makes an image');
is($media[0]{'kind'}, 'image', 'the kind reaches generate_ai_media');
is($media[0]{'prompt'}, 'a red barn at dawn', 'the prompt is trimmed');
is($media[0]{'mail_contact'}, 'kitchen_renovation', 'the app is normalised for filing');
is($media[0]{'unclaimed'}, 0, 'a named app is not left unclaimed');
is($r->{'model'}, 'img-model', 'the image model is reported');
is($r->{'app'}, 'Kitchen Renovation', 'the filed app is reported in its display name');
is($r->{'unclaimed'}, 0, 'and the answer is not unclaimed');

@media = ();
$r = Manager::guide_generate_media('video', 'a leaf falling', '');
ok($r->{'ok'}, 'the helper makes a video with no app');
is($media[0]{'unclaimed'}, 1, 'with no app the media waits in the Camera pool');
is($r->{'model'}, 'video-model', 'the video model is reported');

@media = ();
$r = Manager::guide_generate_media('nonsense', 'a sound of rain', '');
is($media[0]{'kind'}, 'image', 'an unknown kind falls back to image');

@media = ();
$r = Manager::guide_generate_media('audio', '   ', '');
ok(!$r->{'ok'}, 'an empty prompt is refused');
like($r->{'error'}, qr/tell me what to make/, 'and says what is missing');
is(scalar @media, 0, 'nothing is generated');

$media_url = undef;
$r = Manager::guide_generate_media('image', 'a red barn', '');
ok(!$r->{'ok'}, 'a missing result is an error');
like($r->{'error'}, qr/image agent could not make that/, 'and names the agent');
$media_url = '/media/made.png';

# ------------------------------------------------------------ the spoken branch
my @replied;
my $next_action = '{"action":"generate","kind":"image","prompt":"a red barn at dawn"}';
my $made = { ok => 1, kind => 'image', app => '', unclaimed => 1 };
local $subs::log = bless {}, 'TestLog';
local *subs::voice_card_show = sub { };
local *subs::voice_funnel_enabled = sub { 0 };
local *subs::ai_role_models = sub { return ('test-model', '') };
local *subs::ai_role_thinking_effective = sub { 'off' };
local *subs::evaluation_model_call_role = sub { return ($next_action, undef) };
local *subs::guide_resolve_action = sub { return $_[0] };
local *subs::controller_builder = sub { return undef };
local *subs::watch_reply = sub { push @replied, $_[1]; return 1 };
local *Manager::guide_generate_media = sub { return $made };

sub turn {
	my ($text) = @_;
	@replied = ();
	return subs::voice_brain($text, { chip_id => 'watch-gen', ts => &subs::rightNow() });
}

my $v = turn('make an image of a red barn at dawn');
ok($v && $v->{'handled'}, 'a spoken generate is claimed');
is($v->{'action'}, 'generate', 'the turn is a generate');
is($v->{'media'}{'kind'}, 'image', 'the media result is carried');
is($replied[0] // '', 'I made the image and left it in the Camera pool.',
	'an unclaimed image says it waits in the Camera pool');

$made = { ok => 1, kind => 'image', app => 'Kitchen Renovation', unclaimed => 0 };
$v = turn('make a picture for the kitchen renovation');
is($replied[0] // '', 'I made the image and filed it on Kitchen Renovation.',
	'a filed image names its appointment');

$made = { ok => 0, error => 'the image agent could not make that (is a image model set?)' };
$v = turn('make an image of a red barn');
ok($v && $v->{'handled'}, 'a failed generate still claims the turn');
like($replied[0] // '', qr/^I could not make the image: the image agent could not make that/,
	'and speaks the reason');

# ------------------------------------------------------------ the offered verbs
my $camera = subs::voice_funnel_verbs({ app => 'camera', id => 'camera' });
ok($camera->{'generate'}, 'a camera turn is offered generate');
my $gallery = subs::voice_funnel_verbs({ app => 'gallery', id => 'gallery' });
ok($gallery->{'generate'}, 'a gallery turn is offered generate');
my $clock = subs::voice_funnel_verbs({ app => 'clock', id => 'clock' });
ok(!$clock->{'generate'}, 'a clock turn is not offered generate');

done_testing();
