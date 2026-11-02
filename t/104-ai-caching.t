# tests-for: lib/JawnOS/Domain/Ai2.pm
# covers:    the system prompt as a cacheable payload - the stable prefix in an
#           ephemeral block, the dynamic "Right now it is" tail outside it, the
#           providers that need no marker, and the cached token counts.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

require JawnOS::Domain::Ai2;

# A stable prefix long enough to be worth caching (Anthropic's floor).
my $rule = "You are the coding agent. Keep the tree safe: read before you write, and never touch a generated directory.\n";
my $stable = $rule x 40;
ok length($stable) >= 4000, 'the stable fixture is over the cacheable minimum';

# Manager::coding_system_prompt closes with the changing line; keeping it out of
# the cached block is what makes the cache hit on the next turn.
my $tail = 'Right now it is Tuesday, November 2, 2026 at 17:43.';
my $long = $stable . $tail;
my $short = "You are helpful.\n" . $tail;

# ---- Anthropic: an explicit block on the stable prefix ----------------------
my $blocks = &subs::ai_system_payload('anthropic', 'claude-sonnet-4-5', $long);
is ref $blocks, 'ARRAY', 'a long Anthropic prompt is sent as blocks';
is scalar @$blocks, 2, 'the stable prefix and the dynamic tail are two blocks';
is $blocks->[0]{'type'}, 'text', 'the first block is text';
is $blocks->[0]{'text'}, $stable, 'the first block is the stable prefix';
unlike $blocks->[0]{'text'}, qr/Right now it is/, 'the cached block does not carry the date line';
is_deeply $blocks->[0]{'cache_control'}, { type => 'ephemeral' },
	'the first block carries the ephemeral cache marker';
is $blocks->[1]{'text'}, $tail, 'the second block is the dynamic tail';
ok !exists $blocks->[1]{'cache_control'}, 'the dynamic tail carries no cache marker';

my $no_tail = &subs::ai_system_payload('anthropic', 'claude-sonnet-4-5', $stable);
is ref $no_tail, 'ARRAY', 'a long prompt without a date line is still a block';
is scalar @$no_tail, 1, 'and has no empty second block';

# A short prompt is not worth a marker: it goes out exactly as it came in.
my $short_out = &subs::ai_system_payload('anthropic', 'claude-sonnet-4-5', $short);
ok !ref $short_out, 'a short Anthropic prompt stays a plain string';
is $short_out, $short, 'and is returned unchanged';

# ---- OpenRouter: the same blocks, as the system message's content -----------
my $or_blocks = &subs::ai_system_payload('openrouter', 'anthropic/claude-sonnet-4.5', $long);
is ref $or_blocks, 'ARRAY', 'a Claude model on OpenRouter gets blocks';
is_deeply $or_blocks, $blocks, 'and they are the same cached-prefix blocks';

my $or_claude = &subs::ai_system_payload('openrouter', 'claude-3.5-sonnet', $long);
is ref $or_claude, 'ARRAY', 'a bare claude model name is recognised too';

my $or_short = &subs::ai_system_payload('openrouter', 'anthropic/claude-sonnet-4.5', $short);
is $or_short, $short, 'a short Claude prompt on OpenRouter stays a string';

my $or_llama = &subs::ai_system_payload('openrouter', 'meta-llama/llama-3.3-70b-instruct', $long);
ok !ref $or_llama, 'a non-Claude OpenRouter model stays a plain string';
is $or_llama, $long, 'and is returned unchanged';

# ---- every other provider is left alone -------------------------------------
for my $provider (qw(openai deepseek xai mistral groq cohere google ollama cloudflare)) {
	my $out = &subs::ai_system_payload($provider, 'some-model', $long);
	ok !ref $out, "$provider keeps a plain string system prompt";
	is $out, $long, "${provider}'s system prompt is unchanged";
}

# ---- usage: cached input is still input -------------------------------------
my ($in, $out) = &subs::ai_usage_tokens({
	usage => {
		input_tokens => 100,
		cache_creation_input_tokens => 20,
		cache_read_input_tokens => 30,
		output_tokens => 5,
	},
});
is $in, 150, 'the input count includes cache creation and cache read';
is $out, 5, 'the output count is untouched';

my ($partial_in) = &subs::ai_usage_tokens({ usage => { input_tokens => 100, cache_read_input_tokens => 30, output_tokens => 5 } });
is $partial_in, 130, 'a missing cache field counts as zero';

my ($plain_in, $plain_out) = &subs::ai_usage_tokens({ usage => { prompt_tokens => 100, completion_tokens => 5 } });
is $plain_in, 100, 'an OpenAI usage with no cache fields is unchanged';
is $plain_out, 5, 'and its output count is unchanged';

my ($anthropic_in, $anthropic_out) = &subs::ai_usage_tokens({ usage => { input_tokens => 100, output_tokens => 5 } });
is $anthropic_in, 100, 'an Anthropic usage without cache fields is unchanged';
is $anthropic_out, 5, 'and its output count is unchanged';

done_testing();
