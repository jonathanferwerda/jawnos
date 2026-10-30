use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Time::Local ();
use JawnOSTest ();

# A rate limit is not "out of credit": it clears in seconds, or at a clock time
# the provider states. ai_limit_pause() reads that statement. The regression it
# guards is the old behaviour, where only a 402 stood a bucket down - for a flat
# 30 minutes - so a 429 was retried on every call and a 20-second per-minute
# limit could have cost the model for half an hour.
#
# JawnOSTest pins TZ to UTC, so the "resets at" cases can name a local clock
# time and expect the same arithmetic on any machine.

ok defined &subs::ai_limit_pause, 'ai_limit_pause is loaded';

my $now = Time::Local::timelocal(0, 0, 10, 30, 9, 2026) * 1000;   # 30 Oct 2026, 10:00 local

sub pause {
	my ($code, $retry_after, $body) = @_;
	return &subs::ai_limit_pause($code, $retry_after, $body, $now);
}

# A 429 with nothing to go on waits a minute - long enough to stop a hot loop,
# short enough that the model comes back on its own.
my ($ms, $why) = pause(429, '', '');
is $ms, 60000, 'a bare 429 pauses for one minute';
like $why, qr/rate limiting/, 'and says why';

# OpenAI's 529 (overloaded) is the same story.
is((pause(529, '', ''))[0], 60000, 'a 529 pauses too');

# Retry-After: seconds, as every provider that sends it does.
is((pause(429, '30', ''))[0], 30000, 'Retry-After seconds are honoured');
is((pause(429, '7.5', ''))[0], 7500, 'a fractional Retry-After is honoured');

# Retry-After: an HTTP date, which RFC 7231 allows and some proxies send.
is((pause(429, 'Fri, 30 Oct 2026 20:00:00 GMT', ''))[0], 10 * 3600 * 1000,
	'a Retry-After HTTP date is honoured (ten hours out)');

# The body hint, when there is no header.
is((pause(429, '', 'Rate limit reached. Please try again in 12s'))[0], 12000,
	'"try again in 12s" is honoured');
is((pause(429, '', 'try again in 2 minutes'))[0], 120000,
	'units are read, not assumed');
is((pause(429, '', 'Please retry after 45 seconds'))[0], 45000,
	'"retry after 45 seconds" is honoured');

# A limit stated as a clock time: today if it is still ahead, tomorrow if not.
is((pause(429, '', 'You have hit your limit; resets at 3:45 PM'))[0], (5 * 3600 + 45 * 60) * 1000,
	'a reset later today is five and three quarter hours out');
is((pause(429, '', 'resets at 3:45 PM'))[1], 'the limit resets at 15:45',
	'and the reason names the clock time');
is((pause(429, '', 'limit reached, resets at 9:00 AM'))[0], 23 * 3600 * 1000,
	'a reset already past today is tomorrow');

# A hint that is too small must not become a hot loop; one too large must not
# lose the model for a week.
is((pause(429, '', 'try again in 20ms'))[0], 5000, 'a 20ms hint is raised to the 5s floor');
is((pause(429, '259200', ''))[0], 24 * 3600 * 1000, 'a three-day hint is capped at a day');

# Not every failure is a limit. A credit failure belongs to the stand-down
# branch that runs first, and a validation error is not a limit at all.
my ($credit) = pause(402, '', 'insufficient_quota');
ok !defined $credit, 'a 402 credit failure is not a limit pause';
my ($bad) = pause(400, '', 'invalid request: unknown field');
ok !defined $bad, 'a 400 is not a limit pause';
my ($generic) = pause(500, '', 'internal error');
ok !defined $generic, 'a plain 500 is not a limit pause';

# A rate limit can arrive without a 429 (a gateway rewriting the status).
is((pause(500, '', 'rate limit reached, slow down'))[0], 60000,
	'a rate-limit body is recognised at any status');

done_testing();
