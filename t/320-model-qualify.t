# tests-for: lib/JawnOS/Domain/Ai2.pm lib/JawnOS/Domain/Hang.pm lib/JawnOS/Controller/manager_configure.pm templates/configure/plat_setting_list.html.ep public/js/manager/configure/03_platform_misc.js
# covers:    A model is not trusted before it is checked: the intelligence test
#            sends one short turn and grades seven things an agent here has to
#            do, and the Plat panel runs it when a language model is picked. A
#            clothesline phrase in a language the house reader does not know is
#            handed to the Guide whole, not half-read.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest ();
use RepoSource;

require JawnOS::Domain::Ai2;
require JawnOS::Domain::Hang;

# --- grading an answer ------------------------------------------------------
my $perfect = '{"sum":40,"product":391,"weekday":"Saturday","thursday_es":"jueves",'
	. '"schedule":{"weekdays":["thu"],"hours":[15,16],"until":"2027-07-24"}}';
my $good = subs::ai_qualify_grade($perfect);
is($good->{'score'}, 7, 'a perfect answer passes every check');
is($good->{'total'}, 7, 'out of seven');
is_deeply($good->{'missed'}, [], 'and misses nothing');
like($good->{'message'}, qr/good fit/, 'and reads as a good fit');

my $weak = '{"sum":40,"product":400,"weekday":"Friday","thursday_es":"thursday",'
	. '"schedule":{"weekdays":["thu"],"hours":[16],"until":"2027-07-24"}}';
my $w = subs::ai_qualify_grade($weak);
is($w->{'score'}, 3, 'a weak answer keeps only what it got right');
is_deeply($w->{'missed'}, [qw(product weekday Spanish hours)], 'and names what it missed');

my $fenced = "Here is the JSON:\n```json\n$perfect\n```";
is(subs::ai_qualify_grade($fenced)->{'score'}, 7, 'a code fence around the object is tolerated');

my $prose = subs::ai_qualify_grade('I am sorry, I cannot answer that.');
is($prose->{'score'}, 0, 'prose fails every check');
like($prose->{'message'}, qr/too weak/, 'and says the model is too weak');

# --- a phrase in another language goes to the Guide -------------------------
my $now = JawnOSTest::ts(2026, 11, 16, 12, 0);
my $fr = subs::clothesline_schedule_parse('tous les jeudis de 15h a 18h', now => $now);
ok($fr->{'ask'} || $fr->{'unread'}, 'a French phrase is handed to the Guide');
my $es = subs::clothesline_schedule_parse('todos los domingos por la manana', now => $now);
ok($es->{'ask'} || $es->{'unread'}, 'and so is a Spanish one');
my $en = subs::clothesline_schedule_parse('every thursday from 3pm to 6pm', now => $now);
ok(!$en->{'unread'}, 'an English phrase the reader knows stays here');

# a sentence the Guide wrote in the phrase's language is what the card shows
my $cards = subs::clothesline_schedule_cards({ schedules => [ {
	text => 'tous les jeudis', say => 'Chaque jeudi de 15h a 18h',
	days => { '2026-11-19' => 1 }, hours => [15, 16, 17], minutes => [],
	plan => { plans => [ { kind => 'weekdays', weekdays => ['thu'] } ] } } ] });
is($cards->[0]{'say'}, 'Chaque jeudi de 15h a 18h', 'the Guide-read sentence keeps its own language');

# --- the wiring -------------------------------------------------------------
my $ai2 = read_file(repo_root() . '/lib/JawnOS/Domain/Ai2.pm');
like($ai2, qr/sub ai_model_qualify/, 'the intelligence test exists');
like($ai2, qr/sub ai_qualify_grade/, 'and grades an answer');
like($ai2, qr/sub ai_qualify_cached/, 'the day\'s result is kept');
like($ai2, qr/2027-07-24/, 'the test names a fixed date to reason about');
like($ai2, qr/thursday_es/, 'and a word in another language');

my $hang = read_file(repo_root() . '/lib/JawnOS/Domain/Hang.pm');
like($hang, qr/The phrase may be written in any language/,
	'the Guide fallback is told the phrase may be in any language');
like($hang, qr/clothesline_stop_word/, 'a clause with words the reader did not use goes to the Guide');

my $configure = read_file(repo_root() . '/lib/JawnOS/Controller/manager_configure.pm');
like($configure, qr/ai_model_qualify/, 'the Test route runs the intelligence test');
like($configure, qr/ai_qualify_cached/, 'and answers from the cache without another call');

my $plat = read_file(repo_root() . '/templates/configure/plat_setting_list.html.ep');
like($plat, qr/data-qualify="1"/, 'a language role carries the qualify flag');
like($plat, qr/ai_qualify_badge/, 'and shows the score beside the model');
like($plat, qr/Run the intelligence test on this model/, 'the Test hint says what it does');

my $js = read_file(repo_root() . '/public/js/manager/configure/03_platform_misc.js');
like($js, qr/function aiQualify/, 'the panel runs the test');
like($js, qr/aiQualify\(role, \{ force: 0 \}\)/, 'on a new pick');
like($js, qr/qualify: 1/, 'through the Test route');

done_testing();
