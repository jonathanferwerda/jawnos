# tests-for: lib/JawnOS/Domain/Ai2.pm lib/JawnOS/Domain/Budget2.pm lib/JawnOS/Domain/Evaluation.pm lib/JawnOS/Controller/manager_misc5.pm
# covers:    The attribution half of the Intelligence evaluation work: the
#            caller's opt (app, run) is threaded from the evaluation agent
#            through the role call into ai_spend_note on both the provider and
#            the peer-Ollama path; a streamed reply's usage is read from each
#            provider's frames (OpenAI, Anthropic, Google, Ollama) and merged;
#            the report carries its run id and token totals; and both the
#            nightly job and the manual route file the same run entry, with the
#            30-entry window kept.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(encode_json decode_json);
use JawnOSTest;

# The domain layer is lazy; load the real definitions before the local stubs
# below, or a later AUTOLOAD would replace a stub mid-test.
require JawnOS::Domain::Ai2;
subs::preload('evaluation_run_record');

my $root = root();

# ---- streaming usage: one helper reads every provider's own shape -----------
{
	my ($in, $out) = subs::ai_stream_usage('openai',
		{ choices => [], usage => { prompt_tokens => 11, completion_tokens => 7 } });
	is $in, 11, 'OpenAI: the final chunk states the prompt tokens';
	is $out, 7, 'and the completion tokens';
	is_deeply [ subs::ai_stream_frame('openai', { choices => [], usage => { prompt_tokens => 11 } }) ], [],
		'a usage-only chunk adds no text, so the sink is untouched';

	# Anthropic splits the pair: message_start carries the input, message_delta
	# the final output.
	($in, $out) = subs::ai_stream_usage('anthropic', {
		type => 'message_start',
		message => { usage => {
			input_tokens => 100,
			cache_creation_input_tokens => 5,
			cache_read_input_tokens => 20,
			output_tokens => 1,
		} },
	});
	is $in, 125, 'Anthropic: message_start counts the cached prompt as input';
	is $out, 1, 'and its opening output count';
	($in, $out) = subs::ai_stream_usage('anthropic', {
		type => 'message_delta', usage => { output_tokens => 42 },
	});
	ok !defined $in, 'message_delta says nothing about the input';
	is $out, 42, 'but carries the final output count';
	is_deeply [ subs::ai_stream_usage('anthropic', { type => 'content_block_delta', delta => {} }) ], [],
		'a delta frame carries no usage';

	# Gemini repeats usageMetadata as the counts grow; the cached content is
	# already inside promptTokenCount, so it is never added twice.
	($in, $out) = subs::ai_stream_usage('google', {
		usageMetadata => { promptTokenCount => 30, candidatesTokenCount => 12, cachedContentTokenCount => 8 },
	});
	is $in, 30, 'Google: promptTokenCount is the input';
	is $out, 12, 'candidatesTokenCount is the output';
	($in, $out) = subs::ai_stream_usage('google', { usageMetadata => { cachedContentTokenCount => 8 } });
	is $in, 8, 'a reply that reports only cached prompt work still counts it';

	# Ollama stamps its counters on the last chunk.
	($in, $out) = subs::ai_stream_usage('ollama', { message => { content => '' }, prompt_eval_count => 9, eval_count => 4 });
	is $in, 9, 'Ollama: prompt_eval_count is the input';
	is $out, 4, 'eval_count is the output';
	is_deeply [ subs::ai_stream_usage('ollama', { message => { content => 'still writing' } }) ], [],
		'a chunk with no counters yields nothing';
	is_deeply [ subs::ai_stream_usage('openai', 'not a frame') ], [], 'a non-hash frame yields nothing';
}

# ---- the frame callback: a streamed body's usage is collected on the way ----
{
	my @seen;
	my $buf = '';
	my @d = subs::ai_stream_feed('openai', \$buf,
		"data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n"
		. "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\n\n",
		sub { push @seen, $_[0] });
	is_deeply \@d, [ [ 'text', 'Hi' ] ], 'the deltas are unchanged by the new callback';
	is scalar @seen, 2, 'and every decoded frame is handed over, usage-only included';
	my ($in, $out) = subs::ai_stream_usage('openai', $seen[1]);
	is $in, 3, 'the callback sees the final usage chunk';
	is $out, 2, 'with both halves';

	# Ollama's NDJSON goes through the same hook
	@seen = ();
	$buf = '';
	subs::ai_stream_feed('ollama', \$buf,
		'{"message":{"content":"A"},"eval_count":1}' . "\n"
		. '{"done":true,"prompt_eval_count":5,"eval_count":6}' . "\n",
		sub { push @seen, $_[0] });
	($in, $out) = subs::ai_stream_usage('ollama', $seen[1]);
	is $in, 5, 'the Ollama final line carries the prompt count';
	is $out, 6, 'and the eval count';

	# the callback stays optional: the old call shape still returns deltas
	$buf = '';
	@d = subs::ai_stream_feed('openai', \$buf, "data: {\"choices\":[{\"delta\":{\"content\":\"Z\"}}]}\n\n");
	is_deeply \@d, [ [ 'text', 'Z' ] ], 'ai_stream_feed without a callback is unchanged';
}

# ---- the opt reaches the role call -----------------------------------------
{
	no warnings 'redefine';
	my $seen;
	local *subs::ai_chat_parts_role = sub {
		my ($role, $messages, $thinking, $opt) = @_;
		$seen = $opt;
		return ([ { type => 'text', text => 'hello' } ], undef);
	};
	my ($text, $err) = subs::ai_chat_role('eval_assistant', [ { role => 'user', content => 'hi' } ], '',
		{ app => 'budget', run => 'eval_abc' });
	is $text, 'hello', 'ai_chat_role still answers with the text';
	ok !defined $err, 'and no error';
	is_deeply $seen, { app => 'budget', run => 'eval_abc' }, 'ai_chat_role passes the opt through';

	$seen = 'unset';
	($text, $err) = subs::ai_chat_role('eval_assistant', [], '');
	is $text, 'hello', 'the three-argument call still works';
	ok !defined $seen, 'and passes no opt';
}
{
	no warnings 'redefine';
	my $got;
	local *subs::ai_chat_role = sub {
		my ($role, $messages, $thinking, $opt) = @_;
		$got = { role => $role, messages => $messages, thinking => $thinking, opt => $opt };
		return ('ok', undef);
	};
	my ($text, $err) = subs::evaluation_model_call_role('eval_assistant', 'SYS', 'USER', '',
		{ app => 'chores', run => 'eval_def' });
	is $text, 'ok', 'evaluation_model_call_role returns what the role call did';
	is $got->{'role'}, 'eval_assistant', 'with the role';
	is $got->{'messages'}->[0]->{'content'}, 'SYS', 'the system prompt';
	is $got->{'messages'}->[1]->{'content'}, 'USER', 'and the user prompt';
	is $got->{'thinking'}, '', 'the thinking level';
	is $got->{'opt'}->{'run'}, 'eval_def', 'and hands the opt on';

	($text, $err) = subs::evaluation_model_call_role('help_assistant', 'S', 'U', '');
	is $text, 'ok', 'the four-argument call still works';
	ok !defined $got->{'opt'}, 'and passes no opt';
}

# ---- a run entry keeps its keys and the 30-entry window --------------------
{
	no warnings 'redefine';
	my $stored = encode_json([ { timestamp => 1, machine => 'old', model => 'm', outcome => 'ran' } ]);
	my $last;
	local *subs::setting_grabber = sub { return $stored };
	local *subs::setting_setter = sub { my ($args) = @_; $stored = $args->{'value'}; $last = $args; return 1 };

	my $log = subs::evaluation_run_record('budget', {
		timestamp => 2, machine => 'here', model => 'ollama:qwen3', outcome => 'ran',
		run => 'eval_abc', tokens => 30, tokens_in => 20, tokens_out => 10,
	});
	is scalar @{$log}, 2, 'a new entry is unshifted onto the log';
	is $log->[0]->{'run'}, 'eval_abc', 'the run id is kept';
	is $log->[0]->{'tokens'}, 30, 'with the token total';
	is $log->[0]->{'tokens_in'}, 20, 'and both halves';
	is $log->[0]->{'outcome'}, 'ran', 'the existing keys stay as given';
	is $log->[1]->{'outcome'}, 'ran', 'and the older entry is untouched';
	is $last->{'app'}, 'budget', 'written under the asking scope';

	# the window is 30: a full log drops its oldest, never its newest
	$stored = encode_json([ map { { timestamp => $_, outcome => 'ran' } } 1 .. 30 ]);
	$log = subs::evaluation_run_record('budget', { timestamp => 99, outcome => 'failed', note => 'no model' });
	is scalar @{$log}, 30, 'the log is trimmed to 30';
	is $log->[0]->{'timestamp'}, 99, 'the newest entry is first';
	is $log->[-1]->{'timestamp'}, 29, 'and the oldest fell off';
	is $log->[0]->{'note'}, 'no model', 'a failure note rides along';

	# an unreadable log reads as empty rather than dying
	$stored = 'not json';
	$log = subs::evaluation_run_record('', { timestamp => 1, outcome => 'ran' });
	is scalar @{$log}, 1, 'a malformed setting starts a fresh log';
	is $last->{'app'}, '__president', 'no scope means the global one';
}

# ---- the wiring: opt to the ledger, run id and tokens to the report ---------
{
	my $ai2 = read_file($root . '/lib/JawnOS/Domain/Ai2.pm');
	like $ai2, qr/\$stream_in = \$in if defined \$in;/,
		'the streamed usage merges each defined half';
	like $ai2, qr/\(\$stream_in, \$stream_out\) = \(undef, undef\);/,
		'and is forgotten when the thinking retry replaces the attempt';
	like $ai2, qr/\{'stream_options'\} = \{ include_usage => Mojo::JSON::true\(\) \}/,
		'the streaming request asks for usage';
	like $ai2, qr/\$provider =~ \/\\A\(\?:openai\|deepseek\|openrouter\|opencode\)\\z\//,
		'only the providers known to accept it are asked';
	like $ai2, qr/ai_spend_note\(\$provider, \$in, \$out, \$real, \$role, \$opt\)/,
		'the provider path banks the call under the caller opt';
	like $ai2, qr/ai_spend_note\('ollama_remote', \$in, \$out, \$model, \$role, \$opt\)/,
		'the peer path banks under the full @device/model id and the opt';
	like $ai2, qr/ai_stream_feed\(\$provider, \\\$stream_buffer, \$bytes, \$usage_take\)/,
		'NDJSON frames feed the usage hook';
	like $ai2, qr/my \(\$stream_in, \$stream_out\);/,
		'captured usage is held beside the deltas';
	like $ai2, qr/if \(\$streamed\) \{\n\t\t\(\$in, \$out\) = \(\$stream_in, \$stream_out\);/,
		'a streamed reply takes the captured usage instead of an empty body';
	like $ai2, qr/\$in = \$body_in unless defined \$in;/,
		'and falls back to the body for a missing half';
}

{
	my $budget2 = read_file($root . '/lib/JawnOS/Domain/Budget2.pm');
	like $budget2, qr/'eval_' \. md5_sum\(\$app \. '\|' \. \$now \. '\|' \. rand\(\)\)/,
		'the evaluation mints an eval_ run id';
	like $budget2, qr/evaluation_model_call_role\('eval_assistant', \$system, \$user, [^\n]+, \{ app => \$app, run => \$run \}\)/,
		'and hands it to the model call with the app scope';
	like $budget2, qr/from ai_spend where run = \?/,
		'the report reads the ledger by that run';
	like $budget2, qr/run => \$run,/, 'the report carries the run id';
	like $budget2, qr/tokens_in => \$tokens_in,?/, 'and the input tokens';
	like $budget2, qr/tokens_out => \$tokens_out,?/, 'and the output tokens';
	like $budget2, qr/tokens => \$tokens_in \+ \$tokens_out,/, 'and their sum';
}

{
	my $eval = read_file($root . '/lib/JawnOS/Domain/Evaluation.pm');
	like $eval, qr/my %spend = map \{ defined \$report->\{\$_\} \? \(\$_ => \$report->\{\$_\}\) : \(\) \} qw\(run tokens tokens_in tokens_out\)/,
		'the nightly job takes the report\'s run and tokens when present';
	like $eval, qr/outcome => 'ran', %spend/,
		'a successful run files them';
	like $eval, qr/outcome => 'failed', note => substr\(\$report->\{'error'\}, 0, 120\), %spend/,
		'a failed run files them beside its note';
	like $eval, qr/splice\(\@\{\$log\}, 30\)/,
		'the log still keeps the last 30 entries';
}

{
	my $misc5 = read_file($root . '/lib/JawnOS/Controller/manager_misc5.pm');
	like $misc5, qr/my \$evaluation_report = &subs::evaluation_agent\(\$app \|\| '__president', \$period\);/,
		'the manual route runs the agent';
	like $misc5, qr/outcome => \$evaluation_report->\{'error'\} \? 'failed' : 'ran'/,
		'and files ran or failed exactly as the nightly job does';
	like $misc5, qr/foreach my \$k \( qw\(run tokens tokens_in tokens_out\) \)/,
		'with the run and tokens when the report carries them';
	like $misc5, qr/eval \{ &subs::evaluation_run_record\(\$app \|\| '__president', \\%run_entry\) \}/,
		'and a note that cannot be written cannot cost the report';
}

done_testing();
