# tests-for: lib/JawnOS/Domain/Ai2.pm lib/JawnOS/Domain/Loader.pm
# covers:    Cloudflare chat asks for a real output budget; the API default of
#           256 truncated every full evaluation report and starved reasoning
#           models of a final answer.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

subs::preload('ai_cloudflare_payload');

my $wire = [ { role => 'user', content => 'Summarise the week.' } ];
my $p = subs::ai_cloudflare_payload(
	'@cf/meta/llama-3.3-70b-instruct-fp8-fast',
	'You are the evaluator.',
	$wire,
);

is $p->{'max_tokens'}, 2048, 'Cloudflare asks for 2048 output tokens, not the API default 256';
is $p->{'model'}, '@cf/meta/llama-3.3-70b-instruct-fp8-fast', 'the model is carried';
is $p->{'messages'}[0]{'role'}, 'system', 'the system prompt leads';
is $p->{'messages'}[0]{'content'}, 'You are the evaluator.', 'the system prompt is unchanged';
is $p->{'messages'}[1]{'role'}, 'user', 'the wire message follows';
is $p->{'messages'}[1]{'content'}, 'Summarise the week.', 'and its content is carried';
ok !${ $p->{'stream'} }, 'the call is not streamed';

my $empty = subs::ai_cloudflare_payload('@cf/meta/llama-3.3-70b-instruct-fp8-fast', 'sys', undef);
is scalar @{ $empty->{'messages'} }, 1, 'a call with no wire messages still carries its system prompt';

done_testing();
