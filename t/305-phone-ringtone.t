# tests-for: lib/JawnOS/Manager/Part12.pm lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Routes/manager_phone.pm templates/apps/phone.html.ep public/js/manager/phone.js public/js/manager/manager/02_web_nfc.js perl/help/topics_web.pl perl/Alarm.pl
# covers:    the Phone app's ringtone choice, its sync fact, and the live-call alarm path

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);

my $root = abs_path("$FindBin::Bin/..");

sub source {
	my ($rel) = @_;
	open(my $fh, '<', "$root/$rel") or die "open $rel: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

require("$root/lib/JawnOS/Manager/Part12.pm");

{
	local *subs::setting_grabber = sub { return 'notifications/chime.mp3' };
	is Manager::phone_ringtone(), 'notifications/chime.mp3', 'a chosen ringtone is read back';
}
{
	local *subs::setting_grabber = sub { return 'notifications/sonar.mp3' };
	is Manager::phone_ringtone(), 'notifications/sonar.mp3', 'sonar is one of the three';
}
{
	local *subs::setting_grabber = sub { return 'notifications/not-one.mp3' };
	is Manager::phone_ringtone(), 'notifications/ring.mp3', 'an unknown value falls back to the classic ring';
}
{
	local *subs::setting_grabber = sub { return undef };
	is Manager::phone_ringtone(), 'notifications/ring.mp3', 'an unset value falls back to the classic ring';
}

my $template = source('templates/apps/phone.html.ep');
like($template, qr/pane="ringtone"/, 'the Phone app has a Ringtone pane');
like($template, qr/id="phone_ringtone"/, 'the pane carries the chooser');
like($template, qr{value="notifications/ring[.]mp3"}, 'Ring is offered');
like($template, qr{value="notifications/chime[.]mp3"}, 'Chime is offered');
like($template, qr{value="notifications/sonar[.]mp3"}, 'Sonar is offered');
like($template, qr/id="phone_ringtone_preview"/, 'the pane can play the choice');
like($template, qr/id="phone_ringtone_save"/, 'the pane saves the choice');

my $routes = source('lib/JawnOS/Routes/manager_phone.pm');
like($routes, qr{\[24765, 'post', '/manager/phone/ringtone', 'action_24765'\]}, 'the ringtone save route is registered');

my $controller = source('lib/JawnOS/Controller/manager_phone.pm');
like($controller, qr/sub action_24765/, 'the save action exists');
like($controller, qr/notifications\/chime[.]mp3/, 'the action accepts the three sounds');
like($controller, qr/setting_setter\(\{ app => 'phone', setting => 'ringtone'/, 'the choice is stored on the phone app');
like($controller, qr/ringtone => &phone_ringtone\(\)/, 'the page and the sync carry the choice');
like($controller, qr/seen => undef/, 'a live ring is left for the Alarm loop to claim');
like($controller, qr/live => 1/, 'the live ring is marked as a live call');
like($controller, qr/stop_seen is null/, 'the hangup closes the ring appointment instead of writing a second');

my $js = source('public/js/manager/phone.js');
like($js, qr{/manager/phone/ringtone}, 'the page posts the choice to the save route');
like($js, qr/new Audio\('/, 'Play hears the chosen file');
like($js, qr/ringtone:\s*1/, 'the pane is remembered like the others');

my $sync = source('public/js/manager/manager/02_web_nfc.js');
like($sync, qr/ringtone:\s*\(response && response[.]ringtone\)/, 'the native facts carry the ringtone');

my $help = source('perl/help/topics_web.pl');
like($help, qr/'Ringtone'/, 'the Phone help topic names the pane');
like($help, qr/Ring, Chime or Sonar/, 'the help names the three sounds');

my $alarm = source('perl/Alarm.pl');
like($alarm, qr/live_ring/, 'the Alarm loop knows a live ring');
like($alarm, qr/silent => \$live_ring/, 'the live ring notice stays quiet for the phone ringer');
like($alarm, qr/\|\| \$live_ring/, 'a live ring fires even with the caller app\'s notification off');
like($alarm, qr/Incoming call/, 'a live ring has words when the caller app has none');

done_testing();
