# tests-for: templates/apps/chat.html.ep public/js/manager/chat.js public/css/chat.css perl/help/topics_mail.pl
# covers:    the Chat header's SMS role request and its graceful degradation

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

my $template = source('templates/apps/chat.html.ep');
like($template, qr/class="chat_icon_button chat_sms_role"/, 'the Chat header carries the role button');
like($template, qr/Be the messages app/, 'the button names what it does');
like($template, qr/aria-label="<%= &subs::ui\('Be the messages app'\) %>"/, 'the label is translated through ui()');

my $js = source('public/js/manager/chat.js');
like($js, qr/function jawnChatSmsRole\(\)/, 'one role check function');
like($js, qr/window\.JawnSms\.smsRole/, 'the check asks the native bridge whether the role is held');
like($js, qr/window\.JawnSms\.requestSms/, 'the click asks the native bridge for the role');
like($js, qr/\$\(window\)\.on\('focus', jawnChatSmsRole\)/, 'the check runs again when the system sheet closes');
like($js, qr/typeof window\.JawnSms\.smsRole !== 'function'/, 'a page without the bridge stays quiet');

my $css = source('public/css/chat.css');
like($css, qr/\.chat_shell \.chat_sms_role\s*\{[^}]*width:\s*auto/s, 'the label button is not forced to the icon square');

my $help = source('perl/help/topics_mail.pl');
like($help, qr/'Be the messages app'/, 'the help topic names the button');
like($help, qr/asks Android for the SMS role/, 'the help topic explains the system confirmation');

done_testing();
