# tests-for: lib/JawnOS/Domain/Device2.pm lib/JawnOS/Domain/Ai2.pm lib/JawnOS/Domain/Sent.pm lib/JawnOS/Controller/manager_misc7.pm perl/crew.pl templates/apps/help.html.ep templates/mail/pen_sections.html.ep templates/configure/plat_setting_list.html.ep perl/help/topics_functions.pl
# covers: the Alibaba (Qwen) provider — its key setting, its model prefix, the
#         DashScope wire — and the provider-grouped model pickers it joins.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);

require JawnOS::Domain::Device2;

my $root = "$FindBin::Bin/..";
my %provider = map { $_->{'id'} => $_ } @{ subs::ai_providers() };

ok($provider{'alibaba'}, 'Alibaba is offered as a provider');
is_deeply([ map { $_->[0] } @{ $provider{'alibaba'}{'keys'} } ], ['alibaba_key'],
	'it takes one API key');
ok(( grep { $_ eq 'alibaba_key' } subs::ai_key_settings() ),
	'the key is saved as a secret');
is(subs::ai_model_provider('alibaba:qwen3-max'), 'alibaba',
	'an Alibaba model routes to Alibaba');
is(subs::ai_model_provider('alibaba:qwen3-coder-plus'), 'alibaba',
	'and so does a coding model');
is(subs::ai_model_paid('alibaba:qwen3-max'), 1, 'a Qwen model is billed');
is(subs::ai_model_bucket('alibaba:qwen3-max'), 'alibaba', 'on its own bucket');

my %offered = map { $_ => 1 } @{ $provider{'alibaba'}{'models'} || [] };
ok($offered{'qwen3-max'}, 'a flagship chat model is offered');
ok($offered{'qwen3-coder-plus'}, 'and the coding model');
ok($offered{'qwen-vl-max'}, 'and a vision model');

# The wire: Alibaba speaks the OpenAI-compatible shape at DashScope's
# international compatible-mode endpoint, reached as alibaba:<id>.
my $ai2 = read_file("$root/lib/JawnOS/Domain/Ai2.pm");
like($ai2, qr/alibaba => 'https:\/\/dashscope-intl\.aliyuncs\.com\/compatible-mode\/v1\/chat\/completions'/,
	'the DashScope compatible endpoint is wired');
like($ai2, qr/alibaba => 'alibaba_key'/, 'and its key reaches the call');
like($ai2, qr/qw\/openai anthropic google xai mistral cohere groq openrouter deepseek opencode alibaba\//,
	'the alibaba: prefix is parsed');

my $crew = read_file("$root/perl/crew.pl");
like($crew, qr/alibaba\s*=> 'alibaba_key'/,
	'the Crew checks an Alibaba model against its key before placing it');

# The choosers: each choice carries the provider group so every model picker can
# draw a provider header, and the Guide's list is the ready chat catalogue.
my $sent = read_file("$root/lib/JawnOS/Domain/Sent.pm");
like($sent, qr/short => \$name, group => \$label/,
	'each picker row carries its provider group');
like($sent, qr/ai_model_catalogue\('chat'\)/,
	'the Guide list is built from the chat catalogue');
like($sent, qr/ai_provider_ready/,
	'and only providers that can answer are offered');

my $search = read_file("$root/lib/JawnOS/Controller/manager_misc7.pm");
like($search, qr/ai_models_/,
	'the Search catalogue cache is keyed by the provider set');

my $help_tpl = read_file("$root/templates/apps/help.html.ep");
like($help_tpl, qr/<optgroup label=/, 'the Guide picker groups models by provider');
my $pen_tpl = read_file("$root/templates/mail/pen_sections.html.ep");
like($pen_tpl, qr/<optgroup label=/, 'the Pen picker groups models by provider');
my $plat_tpl = read_file("$root/templates/configure/plat_setting_list.html.ep");
like($plat_tpl, qr/ai_role_fallback.*<optgroup label=/s,
	'the Plat fallback picker groups models by provider');

done_testing();
