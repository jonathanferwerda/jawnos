use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# Repeating intervals and the "span" vocabulary. interval_parse is the door the
# appointment input and the payable scheduler share; time_span is the door the
# pickers use. They are deliberately separate vocabularies ("1d" vs "1day").

# ---------------------------------------------------------------- interval_parse
sub parsed {
	my ($text) = @_;
	my @got = &subs::interval_parse($text);
	return [ map { $_ } @got ];
}

is_deeply(parsed('1d'),           [ 1, 'day' ],    'one day');
is_deeply(parsed('2 weeks'),      [ 2, 'week' ],   'two weeks, with a space');
is_deeply(parsed('5 yrs'),        [ 5, 'year' ],   'a plural abbreviation');
is_deeply(parsed('monthly'),      [ 1, 'month' ],  'a named interval');
is_deeply(parsed('quarterly'),    [ 3, 'month' ],  'a quarter is three months');
is_deeply(parsed('biweekly'),     [ 2, 'week' ],   'biweekly is two weeks');
is_deeply(parsed('fortnightly'),  [ 2, 'week' ],   'a fortnight is two weeks');
is_deeply(parsed('annually'),     [ 1, 'year' ],   'annually is a year');
is_deeply(parsed('hourly'),       [ 1, 'hour' ],   'hourly is an hour');
is_deeply(parsed('every 3 days'), [ 3, 'day' ],    '"every" is optional');
is_deeply(parsed('once'),         [ 0, 'once' ],   'once is not a repeat');
is_deeply(parsed('1M'),           [ 1, 'month' ],  'a capital M is a month');
is_deeply(parsed('1m'),           [ 1, 'minute' ], 'a lower-case m is a minute');
is_deeply(parsed(''),             [],             'an empty interval does not parse');
is_deeply(parsed('nonsense'),     [],             'an unknown word does not parse');

# ---------------------------------------------------------------- schedule_parse
my $s = &subs::schedule_parse('1d for 2w');
is($s->{count},   1,   'schedule: one day');
is($s->{unit},    'day', 'schedule: day unit');
is($s->{horizon}, '2w',  'schedule: the horizon is kept as written');
ok(!$s->{once}, 'schedule: a repeat is not once');

$s = &subs::schedule_parse('monthly for 1y');
is($s->{count}, 1, 'monthly schedule: count');
is($s->{unit}, 'month', 'monthly schedule: unit');
is($s->{horizon}, '1y', 'monthly schedule: horizon');

$s = &subs::schedule_parse('');
ok($s->{once}, 'empty schedule is once');
is($s->{every}, 'once', 'empty schedule names once');

$s = &subs::schedule_parse('once');
ok($s->{once}, 'the word once is once');

$s = &subs::schedule_parse('not a schedule');
ok($s->{error}, 'an unreadable schedule reports an error');

$s = &subs::schedule_parse('1d until 2024-12-31');
is($s->{horizon}, '2024-12-31', '"until" is a horizon separator');

# ------------------------------------------------------------------ schedule_next
is(ymd(&subs::schedule_next(ts(2024, 1, 31), '1M')),
	'2024-02-29', 'the next month from 31 January is the leap 29th');
is(ymd(&subs::schedule_next(ts(2024, 1, 31), '1month')),
	'2024-02-29', 'a written month steps the calendar too');
is(ymd(&subs::schedule_next(ts(2024, 2, 29), '1y')),
	'2025-02-28', 'the next year from 29 February is the 28th');
ok(!defined &subs::schedule_next(ts(2024, 1, 1), 'once'), '"once" has no next occurrence');

# --------------------------------------------------------- time_span vocabulary
is(&subs::time_span_length('1day'),     86400000,   'one day span');
is(&subs::time_span_length('2week'),    1209600000, 'two week span');
is(&subs::time_span_length('1month'),   30 * 86400000, 'a span month is 30 days');
is(&subs::time_span_length('15second'), 15000,      'an offered odd span');
is(&subs::time_span_length('57day'),    57 * 86400000, 'a count beyond the named words still resolves');
ok(!defined &subs::time_span_length('1d'), 'the span door does not take the interval spelling');
ok(!defined &subs::time_span_length('nonsense'), 'an unknown span has no length');

is(ymd(&subs::time_span('1day', ts(2024, 1, 15), 3)),
	'2024-01-12', 'a span can be multiplied');
is(ymd(&subs::time_span('1week', ts(2024, 1, 15))),
	'2024-01-08', 'a span without a multiplier is one span');

{
	my $died = eval { &subs::time_span('bogus', ts(2024, 1, 15)); 1 };
	ok(!$died, 'an unknown span dies');
	like($@, qr/unknown time span: bogus/, 'and the error names the span');
}

my $spans = &subs::time_spans();
ok(exists $spans->{'day'},     'the span table has the one-day span');
ok(exists $spans->{'twoweek'}, 'the span table has the two-week span, spelled out');
ok(exists $spans->{'moon'},    'the span table keeps the odd spans');

done_testing();
