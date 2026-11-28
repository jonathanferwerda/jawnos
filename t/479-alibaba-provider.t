# tests-for: lib/JawnOS/Domain/Device2.pm lib/JawnOS/Domain/Ai2.pm lib/JawnOS/Domain/Sent.pm lib/JawnOS/Domain/Remote.pm lib/JawnOS/Controller/manager_misc7.pm perl/crew.pl templates/apps/help.html.ep templates/mail/pen_sections.html.ep templates/configure/plat_setting_list.html.ep perl/help/topics_functions.pl
# covers: the Alibaba (Qwen) provider — its key setting, its model prefix, the
#         DashScope wire, its new-user free-trial models — and the
#         provider-grouped model pickers it joins.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);

require JawnOS::Domain::Device2;
require JawnOS::Domain::Sent;
require JawnOS::Domain::Ai2;

# The catalogue probes Ollama and Cloudflare and reads remote machines; this
# test only checks how the fixed providers are stamped, so keep it offline.
{ package TestRows; sub hashes { return [] } }

my $root = "$FindBin::Bin/..";
my %provider = map { $_->{'id'} => $_ } @{ subs::ai_providers() };

ok($provider{'alibaba'}, 'Alibaba is offered as a provider');
is_deeply([ map { $_->[0] } @{ $provider{'alibaba'}{'keys'} } ], ['alibaba_key'],
	'it takes one API key');
ok(( grep { $_ eq 'alibaba_key' } subs::ai_key_settings() ),
	'the key is saved as a secret');
is(subs::ai_model_provider('alibaba:qwen4-max'), 'alibaba',
	'an Alibaba model routes to Alibaba');
is(subs::ai_model_provider('alibaba:qwen3.7-plus'), 'alibaba',
	'and so does a balanced model');
is(subs::ai_model_paid('alibaba:qwen4-max'), 1, 'a Qwen model is billed');
is(subs::ai_model_bucket('alibaba:qwen4-max'), 'alibaba', 'on its own bucket');

# Only the ids that still carry Alibaba's new-user free trial are offered. The
# older ids lost their free quota on 2026-10-29 / 2026-11-19, so a new account
# gets nothing from them and a picker must not imply otherwise.
my %offered = map { $_ => 1 } @{ $provider{'alibaba'}{'models'} || [] };
ok($offered{'qwen4-max'}, 'the flagship trial model is offered');
ok($offered{'qwen3.7-plus'}, 'the balanced trial model is offered');
ok($offered{'qwen3.8-flash'}, 'the fast trial model is offered');
ok($offered{'qwen3.8-omni-flash'}, 'the omni trial model is offered');
ok(!$offered{'qwen-max'}, 'a model whose free quota was removed is no longer offered');
ok(!$offered{'qwen3-max'}, 'nor the old flagship');
ok(!$offered{'qwen-vl-max'}, 'nor the old vision model');

# Every offered Alibaba model is a trial model, and nothing else is.
my %trial = map { $_ => 1 } @{ $provider{'alibaba'}{'trial_models'} || [] };
is_deeply([ sort keys %trial ], [ sort keys %offered ],
	'the trial list is exactly the models offered');
is(subs::ai_model_trial('alibaba:qwen4-max'), 1, 'a Qwen model is on the free trial');
is(subs::ai_model_trial('alibaba:qwen-max'), 0, 'a model whose quota was removed is not');
is(subs::ai_model_trial('openai:gpt-4o'), 0, 'a model from another provider is not');

# The catalogue stamps the trial flag on each row so a picker can say it.
my $catalogue;
{
	no warnings 'redefine', 'once';
	local *subs::pen_model_list = sub { [] };
	local *subs::cloudflare_model_list = sub { [] };
	local *subs::db_select = sub { bless {}, 'TestRows' };
	$catalogue = subs::ai_model_catalogue('chat');
}
my ($alibaba) = grep { ($_->{'id'} || '') eq 'alibaba' } @{ $catalogue };
ok($alibaba, 'the Alibaba group is in the chat catalogue');
for my $m ( @{ $alibaba->{'models'} || [] } ) {
	is($m->{'trial'}, 1, $m->{'name'} . ' is marked as a free trial');
}
my ($openai) = grep { ($_->{'id'} || '') eq 'openai' } @{ $catalogue };
ok(!grep({ $_->{'trial'} } @{ $openai->{'models'} || [] }),
	'another provider has no trial rows');

# The picker caches are keyed by the provider lists, not just the provider ids,
# so a changed list is seen at once rather than after the ten-minute cache.
like(subs::ai_catalogue_signature(), qr/^[0-9a-f]{32}$/,
	'the catalogue signature is a short digest');

# A used-up trial reads as one model's quota, not the account's credit: tell
# the person to pick another trial model instead of standing the provider down.
ok(subs::ai_trial_exhausted('{"code":"AllocationQuota.FreeTierOnly","message":"..."}'),
	'the Free Quota Only answer is recognised');
ok(!subs::ai_trial_exhausted('{"error":{"message":"invalid api key"}}'),
	'a bad key is not a used-up trial');
ok(!subs::ai_trial_exhausted(''), 'an empty error is not a used-up trial');

# The wire: Alibaba speaks the OpenAI-compatible shape at DashScope's
# international compatible-mode endpoint, reached as alibaba:<id>.
my $ai2 = read_file("$root/lib/JawnOS/Domain/Ai2.pm");
like($ai2, qr/alibaba => 'https:\/\/dashscope-intl\.aliyuncs\.com\/compatible-mode\/v1\/chat\/completions'/,
	'the DashScope compatible endpoint is wired');
like($ai2, qr/alibaba => 'alibaba_key'/, 'and its key reaches the call');
like($ai2, qr/qw\/openai anthropic google xai mistral cohere groq openrouter deepseek opencode alibaba\//,
	'the alibaba: prefix is parsed');
like($ai2, qr/ai_trial_exhausted\(\$body\)/,
	'a used-up trial short-circuits the credit stand-down');
like($ai2, qr/free trial is used up/,
	'with a message that says what to do');

my $crew = read_file("$root/perl/crew.pl");
like($crew, qr/alibaba\s*=> 'alibaba_key'/,
	'the Crew checks an Alibaba model against its key before placing it');

# The choosers: each choice carries the provider group so every model picker can
# draw a provider header, and the Guide's list is the ready chat catalogue.
my $sent = read_file("$root/lib/JawnOS/Domain/Sent.pm");
like($sent, qr/short => \$name, group => \$label, trial =>/,
	'each picker row carries its provider group and trial flag');
like($sent, qr/ai_model_catalogue\('chat'\)/,
	'the Guide list is built from the chat catalogue');
like($sent, qr/ai_catalogue_signature/,
	'and its cache is keyed by the provider model lists');
like($sent, qr/ai_provider_ready/,
	'and only providers that can answer are offered');

my $search = read_file("$root/lib/JawnOS/Controller/manager_misc7.pm");
like($search, qr/ai_catalogue_signature/,
	'the Search cache is keyed by the provider model lists');
like($search, qr/ai_models_/,
	'the Search catalogue cache is still keyed by the provider set');

my $help_tpl = read_file("$root/templates/apps/help.html.ep");
like($help_tpl, qr/<optgroup label=/, 'the Guide picker groups models by provider');
like($help_tpl, qr/\$cm->\{'trial'\}/, 'and marks a free-trial row');
my $pen_tpl = read_file("$root/templates/mail/pen_sections.html.ep");
like($pen_tpl, qr/<optgroup label=/, 'the Pen picker groups models by provider');
like($pen_tpl, qr/\$cm->\{'trial'\}/, 'and marks a free-trial row');
my $plat_tpl = read_file("$root/templates/configure/plat_setting_list.html.ep");
like($plat_tpl, qr/ai_role_fallback.*<optgroup label=/s,
	'the Plat fallback picker groups models by provider');
like($plat_tpl, qr/free trial/, 'and names a free-trial row');
my $search_tpl = read_file("$root/templates/apps/search.html.ep");
like($search_tpl, qr/\$m->\{'trial'\}/, 'the Search picker marks a free-trial row');
my $remote = read_file("$root/lib/JawnOS/Domain/Remote.pm");
like($remote, qr/trial => \(\$_->\{'trial'\}/, 'the QA picker carries the trial flag');

done_testing();
