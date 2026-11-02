# tests-for: lib/JawnOS/Domain/Ai2.pm

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# ai_stream_feed is the pure half of streaming: it takes one chunk of bytes as
# the provider sent it, keeps the incomplete tail, and returns the deltas the
# chunk completed. These fixtures pin the framing of every provider shape the
# transport can meet - SSE with its blank-line frames, Ollama's NDJSON, and the
# [DONE] sentinel - without a network call.

subs::preload('ai_stream_feed');

# ---- SSE: two complete frames, one partial ----------------------------------
{
	my $buf = '';
	my $chunk = "data: {\"choices\":[{\"delta\":{\"content\":\"He\"}}]}\n\n"
		. "data: {\"choices\":[{\"delta\":{\"content\":\"llo\"}}]}\n\n"
		. "data: {\"choices\":[{\"delta\":{\"content\":";
	my @d = subs::ai_stream_feed('openai', \$buf, $chunk);
	is_deeply(\@d, [ [ 'text', 'He' ], [ 'text', 'llo' ] ],
		'two complete SSE frames yield their deltas');
	is($buf, 'data: {"choices":[{"delta":{"content":',
		'the incomplete frame stays in the buffer');
	@d = subs::ai_stream_feed('openai', \$buf, "\"!\"}}]}\n\n");
	is_deeply(\@d, [ [ 'text', '!' ] ], 'the next chunk completes it');
	is($buf, '', 'and leaves nothing behind');
}

# ---- OpenAI-compatible: text and reasoning ---------------------------------
{
	my $buf = '';
	my @d = subs::ai_stream_feed('openai', \$buf,
		"data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hmm\"}}]}\n\n"
		. "data: {\"choices\":[{\"delta\":{\"content\":\"answer\"}}]}\n\n");
	is_deeply(\@d, [ [ 'reasoning', 'hmm' ], [ 'text', 'answer' ] ],
		'OpenAI reasoning_content and content are kept apart');
}

# ---- Anthropic: thinking, text, and an ignored tool-argument delta ----------
{
	my $buf = '';
	my $chunk = join "\n\n",
		'event: content_block_delta' . "\n"
			. 'data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"step"}}',
		'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"reply"}}',
		'data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"a\":"}}',
		'';
	my @d = subs::ai_stream_feed('anthropic', \$buf, $chunk);
	is_deeply(\@d, [ [ 'reasoning', 'step' ], [ 'text', 'reply' ] ],
		'Anthropic thinking_delta and text_delta stream; input_json_delta is ignored');
}

# ---- Gemini: a thought part and a text part --------------------------------
{
	my $buf = '';
	my @d = subs::ai_stream_feed('google', \$buf,
		"data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"working\",\"thought\":true},{\"text\":\"done\"}]}}]}\n\n");
	is_deeply(\@d, [ [ 'reasoning', 'working' ], [ 'text', 'done' ] ],
		'Gemini thought parts are reasoning, the rest is text');
}

# ---- Ollama: NDJSON, two lines in a chunk and one split across two ----------
{
	my $buf = '';
	my @d = subs::ai_stream_feed('ollama', \$buf,
		'{"message":{"content":"A"}}' . "\n"
		. '{"message":{"content":"B"}}' . "\n"
		. '{"message":{"co');
	is_deeply(\@d, [ [ 'text', 'A' ], [ 'text', 'B' ] ],
		'two NDJSON lines in one chunk');
	is($buf, '{"message":{"co', 'the split line stays buffered');
	@d = subs::ai_stream_feed('ollama', \$buf, 'ntent":"C"}}' . "\n");
	is_deeply(\@d, [ [ 'text', 'C' ] ], 'the split line completes on the next chunk');
	is($buf, '', 'and leaves nothing behind');

	$buf = '';
	@d = subs::ai_stream_feed('ollama', \$buf, '{"message":{"thinking":"why"}}' . "\n");
	is_deeply(\@d, [ [ 'reasoning', 'why' ] ], 'Ollama thinking is reasoning');
}

# ---- the [DONE] sentinel ----------------------------------------------------
{
	my $buf = '';
	my @d = subs::ai_stream_feed('openai', \$buf, "data: [DONE]\n\n");
	is_deeply(\@d, [], '[DONE] produces no deltas');
	is($buf, '', 'and is consumed');
}

# ---- a malformed frame is skipped, not fatal -------------------------------
{
	my $buf = '';
	my @d = eval { subs::ai_stream_feed('openai', \$buf, "data: {not json}\n\n") };
	is($@, '', 'a malformed frame does not die');
	is_deeply(\@d, [], 'and produces no deltas');
}

done_testing();
