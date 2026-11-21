# tests-for: lib/JawnOS/Domain/Device2.pm lib/JawnOS/Domain/Ai3.pm lib/JawnOS/Domain/Loader.pm
# covers:    the OpenCode provider — its key setting and its model prefix — and the
#           Go allowance windows the balance read shows as the time available.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

require JawnOS::Domain::Device2;
require JawnOS::Domain::Ai3;

my %provider = map { $_->{'id'} => $_ } @{ subs::ai_providers() };
ok( $provider{'opencode'}, 'OpenCode is offered as a provider' );
is_deeply( [ map { $_->[0] } @{ $provider{'opencode'}{'keys'} } ], ['opencode_key'],
	'it takes one API key' );
ok( ( grep { $_ eq 'opencode_key' } subs::ai_key_settings() ),
	'the key is saved as a secret' );
is( subs::ai_model_provider('opencode:deepseek-v4.1-flash'), 'opencode',
	'an opencode model routes to opencode' );
is( subs::ai_model_provider('opencode:claude-sonnet-5-5'), 'opencode',
	'and so does a model of another family' );

# The hosted usage document: three meters, each with a percent used and the clock
# it resets. 2023-11-14T22:13:20Z, so the reset clocks below are ordinary ones.
my $now = 1_700_000_000_000;
my $doc = {
	usage => {
		rolling => { status => 'ok', percent => 12, resetsAt => '2023-11-15T00:26:38Z' },
		weekly  => { status => 'ok', percent => 34, resetsAt => '2023-11-18T02:13:20Z' },
		monthly => { status => 'ok', percent => 56, resetsAt => '2023-11-26T22:13:20Z' },
	},
};
my $note = subs::ai_balance_opencode_note($doc, $now);
like( $note, qr/5h 88% left/,    'the five-hour window shows what is left' );
like( $note, qr/week 66% left/,  'the weekly window shows what is left' );
like( $note, qr/month 44% left/, 'the monthly window shows what is left' );
like( $note, qr/5h 88% left \(resets in 2h 13m\)/, 'and when the five-hour window resets' );
like( $note, qr/week 66% left \(resets in 3d 4h\)/, 'and when the week resets' );

# A limited window is empty even when its percent is over 100.
my $limited = subs::ai_balance_opencode_note(
	{ usage => { rolling => { status => 'limited', percent => 132 } } }, $now );
is( $limited, '5h 0% left', 'a limited window reads empty' );

# used/limit is the other shape, and a numeric resetsAt is milliseconds.
my $ms = subs::ai_balance_opencode_note(
	{ usage => { weekly => { used => 25, limit => 100, resetsAt => $now + 3 * 86400000 } } },
	$now );
is( $ms, 'week 75% left (resets in 3d 0h)', 'used/limit and a millisecond reset read too' );

# The local server nests the meters under go; the hosted one may nest them under
# data. Both are accepted.
my $nested = subs::ai_balance_opencode_note(
	{ data => { go => { monthly => { percent => 90 } } } }, $now );
is( $nested, 'month 10% left', 'a nested report reads too' );

is( subs::ai_balance_opencode_note({}, $now), '', 'a report with no meter has no note' );

done_testing();
