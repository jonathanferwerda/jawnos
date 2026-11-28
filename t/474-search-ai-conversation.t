# tests-for: public/js/manager/search.js templates/apps/search.html.ep lib/JawnOS/Controller/manager_misc7.pm lib/JawnOS/Controller/manager_misc8.pm lib/JawnOS/Routes/manager_misc8.pm perl/help/topics_features.pl
# covers: the AI tab chooses its chat model (grouped by provider), keeps a
#         conversation, sends the earlier turns with each new question, moves
#         the field to the bottom while conversing, clears it, and hands it to
#         the Pen as a conversation of its own.

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
like($open, qr/ai_catalogue_available/, 'and only providers this house can reach are offered');
like($open, qr/ai_models_/, 'the provider probe is cached for the open, keyed by the provider set');
like($js, qr/localStorage\.setItem\(AI_MODEL_KEY/, 'the chosen model is remembered');

# --- the conversation -------------------------------------------------------
like($js, qr/messages: JSON\.stringify\(prior\)/, 'each turn sends the earlier turns');
like($js, qr/model: model/, 'and the chosen model');
like($js, qr/search_app_msg_user/, 'the thread draws the person\'s turns');
like($js, qr/search_app_msg_ai/, 'and the model\'s turns');
like($js, qr/#search_app_ai_new/, 'New chat clears the thread');
unlike($js, qr/Press Enter to ask/, 'typing no longer wipes the thread under the question');

# --- the conversation takes the window over ---------------------------------
# It opens like a search (field at the top) and, once there are turns, the same
# field moves to a bottom composer; another tab shows the top field again, and
# coming back with a live thread restores the bottom one. Clear empties it and
# Send to Pen copies it out.
like($tpl, qr/id="search_app_ai_composer"/, 'the AI tab has a bottom composer');
like($tpl, qr/id="search_app_ai_clear"/, 'with a Clear control');
like($tpl, qr/id="search_app_ai_pen"/, 'and a Send to Pen control');
like($tpl, qr/ai_conversation/, 'the stylesheet marks the conversing layout');
like($js, qr/toggleClass\('ai_conversation'/, 'the client turns the conversing layout on');
like($js, qr/#search_app_ai_composer/, 'and moves the field into the bottom composer');
like($js, qr/state\.messages\.length/, 'the layout follows whether there are turns');
like($js, qr/#search_app_ai_new, #search_app_ai_clear/, 'both controls clear the thread');
like($js, qr{/manager/search/ai/pen}, 'Send to Pen posts the conversation');
like($js, qr/mailMaker\(null, 'pen'\)/, 'and opens the Pen on it');

# --- the route --------------------------------------------------------------
like($ai, qr/param\('messages'\)/, 'the route reads the earlier turns');
like($ai, qr/param\('model'\)/, 'and the chosen model');
like($ai, qr/ai_chat_with_fallback/, 'an explicit pick is called as chosen');
like($ai, qr/ai_chat_role/, 'the default keeps the role placement');
like($ai, qr/\$role eq 'user' \|\| \$role eq 'assistant'/, 'only user and assistant turns are kept');
like($ai, qr/substr\(\$text, 0, 8000\)/, 'one turn is bounded');
like($ai, qr/substr\(\$m->\{'content'\}, 0, \$room\)/, 'the whole history is bounded');

# --- the Pen hand-off -------------------------------------------------------
like($ai, qr{/manager/search/ai/pen}, 'the Pen route exists');
like($ai, qr/chatbot_conversations/, 'it adds a conversation to the Pen\'s list');
like($ai, qr/chatbot_conversation_name/, 'with a name taken from the first turn');
like($ai, qr/contact => 'pen'/, 'and files each turn as a Pen message');
like($ai, qr/conversation_uuid => \$uuid/, 'under the new conversation');
like($ai, qr/note_encrypter/, 'the filed words are sealed like the Pen\'s own');

# --- the guide stays true ---------------------------------------------------
like($help, qr/opens Search on the Apps tab/, 'the topic names the magnifier\'s Apps hand-off');
like($help, qr/It is a conversation/, 'and the AI conversation');
like($help, qr/New chat/, 'and the New chat control');
like($help, qr/field moves to the bottom/, 'and the conversing layout');
like($help, qr/Send to Pen/, 'and the Pen hand-off');
like($help, qr/verified => '2026-11-28'/, 'the topic is re-vetted with the change');

done_testing();
