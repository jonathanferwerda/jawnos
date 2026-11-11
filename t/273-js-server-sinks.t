# tests-for: lib/JawnOS/Controller/manager_misc2.pm perl/Alarm.pl lib/JawnOS/Manager/Part11.pm public/js/manager/manager/03_box_office.js public/js/manager/people.js public/js/gate.js lib/JawnOS/Domain/Article.pm public/js/translate.js templates/layouts/manager.html.ep templates/layouts/store.html.ep lib/JawnOS/Controller/manager_people.pm
# covers:    The server-side halves of the DOM sinks: a resident/peer magazine
#           publish is cleaned before storage and again before it is drawn, the
#           peer-supplied device buttons are escaped, a crest's home/store must
#           be http(s) and every crest/payment tab opens with noopener, an
#           article link with target gets a forced rel, mail/chat bodies are
#           never collected for translation, and the layouts emit a numeric tax.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);

my $ROOT = "$FindBin::Bin/..";
sub source { return read_file("$ROOT/$_[0]") }

require JawnOS::Domain::Article;

# --- 1. a received publish is cleaned like an editor save -------------------
my $misc2 = source('lib/JawnOS/Controller/manager_misc2.pm');
my ($publish) = $misc2 =~ /(# POST \/manager\/magazine\/publishing_receive.*?)(?=# POST \/manager\/editor\/save)/s;
ok($publish, 'the publishing_receive action is present');
my $clean_at = index($publish, 'article_html_clean($a->{\'content\'})');
my $insert_at = index($publish, "db_insert('magazine'");
my $update_at = index($publish, "db_update('magazine'");
ok($clean_at >= 0, 'publishing_receive cleans the article content');
ok($insert_at > $clean_at, 'the clean runs before a magazine insert');
ok($update_at > $clean_at, 'the clean runs before a magazine update');

my $alarm = source('perl/Alarm.pl');
like($alarm, qr/\$paper->\{'content'\}\s*=\s*&subs::article_html_clean\(\$paper->\{'content'\}\)/,
	'the Alarm render cleans the row again, so old rows are safe');

# --- 2. the peer's own fields are escaped before they become markup ---------
my $part11 = source('lib/JawnOS/Manager/Part11.pm');
my ($buttons) = $part11 =~ /(# The peer's own fields are untrusted.*?)my \$secret/s;
ok($buttons, 'the device buttons block is present');
for my $shape (
	qr/&subs::html_text\(\$returner->\{'body'\}->\{'version'\} \|\| '\?'\)/,
	qr/&subs::html_text\(\$returner->\{'body'\}->\{'pwd'\}\)/,
	qr/&subs::html_text\(\$returner->\{'body'\}->\{'signatorial'\}\)/,
	qr/&subs::html_text\(\$returner->\{'body'\}->\{'database'\}\)/,
	qr/&subs::html_text\(\$remote_device\)/,
	qr/&subs::html_text\(\$ssh_port\)/,
	qr/&subs::html_text\(\$ip\)/,
	qr/&subs::html_text\(\$nic\)/,
	qr/&subs::html_text\(\$b->\{'name'\}\)/,
	qr/&subs::html_text\(\$b->\{'direction'\}\)/,
	qr/&subs::html_text\(\$b->\{'class'\}\)/,
) {
	like($buttons, $shape, "a peer-supplied field is escaped: $shape");
}
unlike($buttons, qr/home="'\s*\.\s*\$returner->\{'body'\}->\{'pwd'\}/,
	'the peer pwd no longer reaches the home attribute raw');
unlike($buttons, qr/class="'\s*\.\s*\$b->\{'class'\}/,
	'the button class no longer reaches the attribute raw');

my $box = source('public/js/manager/manager/03_box_office.js');
like($box, qr/\.text\(rm\.fqdn \|\| ''\)/, 'the remote fqdn is inserted as text');
unlike($box, qr/'<b>' \+ rm\.fqdn/, 'the remote fqdn is no longer concatenated into HTML');

# --- 3. crest endpoints and payment tabs ------------------------------------
my $people = source('lib/JawnOS/Controller/manager_people.pm');
my $scheme_checks = () = $people =~ /m\{\^https\?:\/\/\}i/g;
cmp_ok($scheme_checks, '>=', 3, 'crest import and both crest returns validate the scheme');
ok(index($people, q{home => $endpoint_url->($endpoints->{'home'})}) >= 0,
	'the crest detail answers with the checked home');
ok(index($people, q{store => $endpoint_url->($endpoints->{'store'})}) >= 0,
	'the crest detail answers with the checked store');
ok(index($people, q{$home = $endpoint_url->($endpoints->{'home'})}) >= 0,
	'the person view answers with the checked home');
ok(index($people, q{$store = $endpoint_url->($endpoints->{'store'})}) >= 0,
	'the person view answers with the checked store');

my $people_js = source('public/js/manager/people.js');
like($people_js, qr/function peopleSafeUrl/, 'people.js has a scheme guard');
like($people_js, qr{\^https\?:}, 'the guard accepts only http(s)');
like($people_js, qr/peopleSafeUrl\(response\.home\)/, 'the home button uses the guard');
like($people_js, qr/peopleSafeUrl\(response\.store\)/, 'the store button uses the guard');
like($people_js, qr/window\.open\(home, '_blank', 'noopener,noreferrer'\)/,
	'the home tab opens with noopener,noreferrer');
like($people_js, qr/window\.open\(store, '_blank', 'noopener,noreferrer'\)/,
	'the store tab opens with noopener,noreferrer');
unlike($people_js, qr/window\.open\(response\.(?:home|store), '_blank'\)/,
	'no raw crest endpoint reaches window.open');

like(source('public/js/gate.js'),
	qr/window\.open\(payment\.payment_link\.url, '_blank', 'noopener,noreferrer'\)/,
	'the payment tab opens with noopener,noreferrer');

# --- 4. an article link with target cannot keep a handle on this house ------
my $clean = \&subs::article_html_clean;
my $targeted = $clean->('<a href="https://example.test" rel="opener" target="_blank">x</a>');
like($targeted, qr/rel="noopener noreferrer"/, 'target forces a safe rel');
unlike($targeted, qr/rel="opener"/, 'a supplied opener rel is replaced');
my $plain = $clean->('<a href="https://example.test" rel="nofollow">x</a>');
is($plain, '<a href="https://example.test" rel="nofollow">x</a>',
	'a link without target keeps its allowlisted rel');
is($clean->('<script>alert(1)</script><p>hi</p>'), '<p>hi</p>',
	'the same cleaner that the publish path calls drops script');

# --- 5. mail and chat bodies are never collected for translation -----------
my $translate = source('public/js/translate.js');
my ($text_skip) = $translate =~ /var TEXT_SKIP = '([^']*)'/;
ok($text_skip, 'translate.js defines TEXT_SKIP');
for my $selector (qw(#mail_body .email_message .mailbox_message_contents .chat_text .chat_messages)) {
	like($text_skip, qr/\Q$selector\E/, "TEXT_SKIP includes $selector");
}

# --- 6. the layouts emit a numeric tax, never a setting's raw text ---------
for my $layout (qw(templates/layouts/manager.html.ep templates/layouts/store.html.ep)) {
	my $t = source($layout);
	like($t, qr/\$tax = 1 unless defined \$tax && \$tax =~/, "$layout guards me_tax numerically");
	like($t, qr/\$sales_tax = 1 unless defined \$sales_tax && \$sales_tax =~/, "$layout guards sales_tax numerically");
	like($t, qr{\^\\d\+\(\?:\\\.\\d\+\)\?\$}, "$layout accepts only a plain decimal");
	like($t, qr/var me_tax = <%= \$tax %>;/, "$layout writes me_tax as a number");
	like($t, qr/var sales_tax = <%= \$sales_tax %>;/, "$layout writes sales_tax as a number");
	unlike($t, qr/var me_tax = <%= &subs::setting_grabber/, "$layout no longer prints the raw setting");
}

done_testing();
