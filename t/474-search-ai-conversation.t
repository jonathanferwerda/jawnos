# tests-for: public/js/manager/search.js templates/apps/search.html.ep lib/JawnOS/Controller/manager_misc7.pm lib/JawnOS/Controller/manager_misc8.pm perl/help/topics_features.pl
# covers: the AI tab chooses its chat model (grouped by provider) and keeps a
#         conversation, sending the earlier turns with each new question.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $js   = read_file("$root/public/js/manager/search.js");
my $tpl  = read_file("$root/templates/apps/search.html.ep");
my $open = read_file("$root/lib/JawnOS/Controller/manager_misc7.pm");
my $ai   = read_file("$root/lib/JawnOS/Controller/manager_misc8.pm");
my $help = read_file("$root/perl/help/topics_features.pl");

# --- the picker -------------------------------------------------------------
# The AI tab's own row carries the model, every chat model the house can reach,
# grouped under its provider, and a New chat control.
like($tpl, qr/id="search_app_ai_model"/, 'the AI tab has a model picker');
like($tpl, qr/<optgroup label=/, 'the models are grouped by provider');
like($tpl, qr/id="search_app_ai_new"/, 'a New chat control is there');
like($open, qr/ai_model_catalogue\('chat'\)/, 'the window is drawn with the chat catalogue');
like($open, qr/context => 'ai_models'/, 'the provider probe is cached for the open');
like($js, qr/localStorage\.setItem\(AI_MODEL_KEY/, 'the chosen model is remembered');

# --- the conversation -------------------------------------------------------
like($js, qr/messages: JSON\.stringify\(prior\)/, 'each turn sends the earlier turns');
like($js, qr/model: model/, 'and the chosen model');
like($js, qr/search_app_msg_user/, 'the thread draws the person\'s turns');
like($js, qr/search_app_msg_ai/, 'and the model\'s turns');
like($js, qr/#search_app_ai_new/, 'New chat clears the thread');
unlike($js, qr/Press Enter to ask/, 'typing no longer wipes the thread under the question');

# --- the route --------------------------------------------------------------
like($ai, qr/param\('messages'\)/, 'the route reads the earlier turns');
like($ai, qr/param\('model'\)/, 'and the chosen model');
like($ai, qr/ai_chat_with_fallback/, 'an explicit pick is called as chosen');
like($ai, qr/ai_chat_role/, 'the default keeps the role placement');
like($ai, qr/\$role eq 'user' \|\| \$role eq 'assistant'/, 'only user and assistant turns are kept');
like($ai, qr/substr\(\$text, 0, 8000\)/, 'one turn is bounded');
like($ai, qr/substr\(\$m->\{'content'\}, 0, \$room\)/, 'the whole history is bounded');

# --- the guide stays true ---------------------------------------------------
like($help, qr/opens Search on the Apps tab/, 'the topic names the magnifier\'s Apps hand-off');
like($help, qr/It is a conversation/, 'and the AI conversation');
like($help, qr/New chat/, 'and the New chat control');
like($help, qr/verified => '2026-11-27'/, 'the topic is re-vetted with the change');

done_testing();
