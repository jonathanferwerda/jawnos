# tests-for: lib/JawnOS/Domain/Ai2.pm
# covers:    Reasoning beside the answer: ai_response_reasoning, ai_response_parts and ai_parts_text, and an ai_response_text that reads every answer block so thinking is never mistaken for the reply.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

require JawnOS::Domain::Ai2;

# Providers request reasoning ("thinking") with thinking / reasoning_effort /
# budget_tokens, and then put the working in a field or block of its own beside
# the answer. These are the reply shapes that were thrown away (or worse, read
# as the answer by an ai_response_text that took content[0]). The fixtures are
# plain hashes: no network, no provider.

# DeepSeek and the OpenAI-compatible crowd: reasoning_content beside content.
my $deepseek = {
	choices => [ { message => { content => '{"action":"done"}', reasoning_content => '  I should finish.  ' } } ],
};
is( subs::ai_response_text($deepseek), '{"action":"done"}', 'DeepSeek: content is the answer' );
is( subs::ai_response_reasoning($deepseek), 'I should finish.', 'DeepSeek: reasoning_content is the thinking, trimmed' );

# OpenRouter: a reasoning string, plus reasoning_details hashes carrying text
# or a summary. Pieces are joined with a blank line, reasoning first.
my $openrouter = {
	choices => [ { message => {
		content          => 'answer',
		reasoning        => 'first thought',
		reasoning_details => [
			{ text    => 'second thought' },
			{ summary => 'third thought' },
		],
	} } ],
};
is( subs::ai_response_text($openrouter), 'answer', 'OpenRouter: content is the answer' );
is( subs::ai_response_reasoning($openrouter), "first thought\n\nsecond thought\n\nthird thought", 'OpenRouter: reasoning and details are joined' );

# A wrapper that nests choices under result, as Cloudflare and others do.
my $wrapped = {
	result => { choices => [ { message => { content => 'wrapped', reasoning_content => 'wrapped thinking' } } ] },
};
is( subs::ai_response_text($wrapped), 'wrapped', 'result.choices: content is the answer' );
is( subs::ai_response_reasoning($wrapped), 'wrapped thinking', 'result.choices: reasoning is read too' );

# Anthropic: content is an array of blocks. Every text block is the answer, and
# the thinking block is skipped; a redacted_thinking block carries no readable
# text and is skipped even if a thinking field leaked into it.
my $anthropic = {
	content => [
		{ type => 'thinking',          thinking => 'weigh the options' },
		{ type => 'text',              text     => 'first' },
		{ type => 'redacted_thinking', thinking => 'hidden' },
		{ type => 'text',              text     => ' second' },
	],
};
is( subs::ai_response_text($anthropic), 'first second', 'Anthropic: every text block is the answer, thinking is skipped' );
is( subs::ai_response_reasoning($anthropic), 'weigh the options', 'Anthropic: the thinking block is the reasoning' );

# Gemini: a thought part carries text beside the answer parts.
my $gemini = {
	candidates => [ { content => { parts => [
		{ thought => 1, text => 'hmm' },
		{ text => 'answer' },
	] } } ],
};
is( subs::ai_response_text($gemini), 'answer', 'Gemini: only parts without thought are the answer' );
is( subs::ai_response_reasoning($gemini), 'hmm', 'Gemini: thought parts are the reasoning' );

# Ollama: thinking beside the message, and at the top level as a fallback.
my $ollama = { message => { content => 'answer', thinking => 'hmm' } };
is( subs::ai_response_text($ollama), 'answer', 'Ollama: message content is the answer' );
is( subs::ai_response_reasoning($ollama), 'hmm', 'Ollama: message thinking is the reasoning' );
is( subs::ai_response_reasoning({ thinking => 'top level thinking' }), 'top level thinking', 'Ollama: a top-level thinking is read as a fallback' );

# A plain reply has no reasoning and must not regress.
my $plain = { choices => [ { message => { content => 'plain answer' } } ] };
is( subs::ai_response_text($plain), 'plain answer', 'a plain OpenAI answer is unchanged' );
is( subs::ai_response_reasoning($plain), '', 'a plain reply carries no reasoning' );

# Reasoning alone is not an answer.
my $thinking_only = { content => [ { type => 'thinking', thinking => 'no answer here' } ] };
is( subs::ai_response_text($thinking_only), '', 'reasoning alone does not become the answer' );
is( subs::ai_response_reasoning($thinking_only), 'no answer here', 'reasoning alone is still readable as reasoning' );

# ai_response_parts: reasoning first, then text, and no empty parts.
is_deeply(
	subs::ai_response_parts($deepseek),
	[
		{ type => 'reasoning', text => 'I should finish.' },
		{ type => 'text',      text => '{"action":"done"}' },
	],
	'parts: reasoning comes first, then the text'
);
is_deeply(
	subs::ai_response_parts($plain),
	[ { type => 'text', text => 'plain answer' } ],
	'parts: a plain reply is just one text part'
);
is_deeply(
	subs::ai_response_parts($thinking_only),
	[ { type => 'reasoning', text => 'no answer here' } ],
	'parts: reasoning without an answer leaves no empty text part'
);
is_deeply( subs::ai_response_parts({}), [], 'parts: an empty body has no parts' );

# ai_parts_text joins one type, defaulting to the answer.
my $mixed = [
	{ type => 'reasoning', text => 'why' },
	{ type => 'text',      text => 'one' },
	{ type => 'image',     url  => 'https://example.test/i.png' },
	{ type => 'text',      text => ' two' },
];
is( subs::ai_parts_text($mixed), 'one two', 'ai_parts_text joins text parts by default' );
is( subs::ai_parts_text($mixed, 'reasoning'), 'why', 'ai_parts_text joins a named type' );
is( subs::ai_parts_text($mixed, 'image'), '', 'ai_parts_text ignores parts with no text of that type' );
is( subs::ai_parts_text(undef), '', 'ai_parts_text tolerates undef' );
is( subs::ai_parts_text({}), '', 'ai_parts_text tolerates a non-array' );

done_testing();
