# tests-for: lib/JawnOS/Domain/Sent.pm lib/JawnOS/Manager/Part25.pm templates/mail/pen_sections.html.ep
# covers:    Pen's model picker - the shared chat catalogue flattened to one row
#            per reachable model (bare Ollama, @cf/..., @device/model and
#            provider:model), deduped by value, with a readable label; the Pen
#            section builds it from ai_model_catalogue, and the template still
#            reads each row's model and name.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

# The domain layer is lazy: load Domain::Sent before calling its helper.
subs::preload('pen_model_list');

my $catalogue = [
	{ id => 'ollama', label => 'Ollama (local)', models => [
		{ value => 'qwen3:8b', name => 'qwen3:8b' },
		# the same id twice: a picker offers it once
		{ value => 'qwen3:8b', name => 'qwen3:8b' },
	] },
	{ id => 'cloudflare', label => 'Cloudflare Workers AI', models => [
		{ value => '@cf/meta/llama-3.1-8b-instruct', name => '@cf/meta/llama-3.1-8b-instruct' },
	] },
	{ id => 'openai', label => 'OpenAI', models => [
		{ value => 'openai:gpt-4o', name => 'gpt-4o' },
		{ value => 'openai:gpt-4.1', name => 'gpt-4.1' },
	] },
	{ id => 'ollama:studio', label => "Ollama \x{00b7} studio", models => [
		{ value => '@studio/qwen3:8b', name => 'qwen3:8b' },
	] },
	# Ai2 writes a peer's label with a literal escape rather than the character
	{ id => 'ollama:den', label => 'Ollama \\x{00b7} den', models => [
		{ value => '@den/llama3:8b', name => 'llama3:8b' },
	] },
	# a group with nothing usable is skipped, not fatal
	{ id => 'empty', label => 'Empty', models => [ {}, { name => 'no value' } ] },
];

my $choices = &subs::pen_model_choices($catalogue);

is_deeply(
	[ map { $_->{'model'} } @{$choices} ],
	[ 'qwen3:8b', '@cf/meta/llama-3.1-8b-instruct', 'openai:gpt-4o', 'openai:gpt-4.1', '@studio/qwen3:8b', '@den/llama3:8b' ],
	'every id shape survives, the duplicate collapses, and a value-less row is dropped'
);

my %by_model = map { $_->{'model'} => $_->{'name'} } @{$choices};
is($by_model{'openai:gpt-4o'}, "OpenAI \x{00b7} gpt-4o", 'a provider:model row is labelled with its provider');
like($by_model{'qwen3:8b'}, qr/^Ollama/, 'a bare Ollama row keeps its bare value and names the provider');
like($by_model{'@cf/meta/llama-3.1-8b-instruct'}, qr/^Cloudflare/, 'a Cloudflare row keeps its @cf/ id');
like($by_model{'@studio/qwen3:8b'}, qr/studio/, 'a peer Ollama row keeps @device/model and names the machine');
is($by_model{'@den/llama3:8b'}, "Ollama \x{00b7} den \x{00b7} llama3:8b", 'a peer label written with an escape renders as the character');
ok( !grep({ !defined $_->{'name'} || !length $_->{'name'} } @{$choices}), 'every row carries a readable label');

is_deeply(&subs::pen_model_choices(undef), [], 'no catalogue is an empty picker');
is_deeply(&subs::pen_model_choices([]), [], 'an empty catalogue is an empty picker');

# The Pen section asks the shared catalogue rather than probing Ollama and
# Cloudflare itself.
my $part = read_file(repo_root() . '/lib/JawnOS/Manager/Part25.pm');
like($part, qr/pen_model_choices\(&subs::ai_catalogue_available\(&subs::ai_model_catalogue\('chat'\)\)\)/, 'the Pen section offers the reachable chat catalogue');
unlike($part, qr/\$chatbot_models\s*=\s*&subs::pen_model_list\(\)/, 'the Pen section no longer hand-builds the list');

# The picker template reads the shape the helper produces: the value is the
# row's model, the label its short name (the provider is the group header), and
# each guard keeps a row missing either from warning or vanishing.
my $tpl = read_file(repo_root() . '/templates/mail/pen_sections.html.ep');
like($tpl, qr/my \$mid = \$cm->\{'model'\} \/\/ ''/, 'the option value is the row model');
like($tpl, qr/<%= \$cm->\{'short'\} \|\| \$cm->\{'name'\}/, 'the option label is the row short name');
like($tpl, qr/<optgroup label=/, 'the rows are grouped under their provider');
like($tpl, qr/next unless length \$mid/, 'a missing model key is guarded');

# Pen's reply goes over the shared AI wire now: no hand-rolled Ollama/Cloudflare
# request, and the unmetered contract the ledger relies on.
my $sent = read_file(repo_root() . '/lib/JawnOS/Domain/Sent.pm');
like($sent, qr/ai_chat_parts_with_fallback\(/, 'pen_message uses the shared AI wire');
like($sent, qr/on_delta\s*=>\s*\$sink/, 'the shared wire streams through the Pen sink');
like($sent, qr/count_unmetered\s*=>\s*1/, 'an unmetered provider still records the call');
unlike($sent, qr/\$ua->build_tx\(POST/, 'no direct provider request is hand-built in Sent.pm');

done_testing();
