use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

# Prices, percentages, durations and the number words people type.

# -------------------------------------------------------------- price_formatter
is(&subs::price_formatter('12.3'),  '$12.30', 'a price gets a currency mark and two places');
is(&subs::price_formatter('-5'),    '-$5.00', 'a negative price keeps its sign outside the mark');
is(&subs::price_formatter('0.999'), '$1.00',  'a price rounds to two places');
is(&subs::price_formatter('abc'),   '0.00',   'text is not a price and reads as zero');
is(&subs::price_formatter(''),      '0.00',   'an empty price reads as zero');

# ------------------------------------------------------------ percent_formatter
is(&subs::percent_formatter(0.1234), '12.340%', 'a fraction becomes a percentage with three places');
is(&subs::percent_formatter(1),      '100.000%', 'one is one hundred percent');
is(&subs::percent_formatter(0),      '0.000%',  'zero is zero percent');

# ------------------------------------------------------------ numeric_formatter
is(&subs::numeric_formatter('70'),          '70',      'a plain number is unchanged');
is(&subs::numeric_formatter('4700'),        '4700',    'a leading digit is not stripped');
is(&subs::numeric_formatter('$1,234.50'),   '1234.50', 'currency and thousands separators are removed');
is(&subs::numeric_formatter('  42 '),       '42',      'surrounding space is removed');
is(&subs::numeric_formatter(''),            0,         'an empty value is zero');
is(&subs::numeric_formatter('abc'),         0,         'text is zero');
is(&subs::numeric_formatter('-'),           0,         'a bare minus is zero');
is(&subs::numeric_formatter('١٢٣'),          '123',     'Arabic-Indic digits are transliterated');

# ------------------------------------------------------- number_words_to_digits
is(&subs::number_words_to_digits('five minutes'),           '5 minutes',  'a small number word becomes digits');
is(&subs::number_words_to_digits('twenty-one days'),        '21 days',    'a hyphenated compound is read');
is(&subs::number_words_to_digits('one hundred and five'),   '105',        'hundreds and "and" are read');
is(&subs::number_words_to_digits('two thousand five hundred'), '2500',    'thousands compose');
is(&subs::number_words_to_digits('a week'),                 '1 week',     'an article reads as one');
is(&subs::number_words_to_digits('an hour'),                '1 hour',     '"an" reads as one');
is(&subs::number_words_to_digits('twelve'),                 '12',         'a teen is read');
is(&subs::number_words_to_digits('hello'),                  'hello',      'text without a number is unchanged');

# --------------------------------------------------------------- duration_sayer
is(&subs::duration_sayer(3661),   '1h 1m',      'an hour and a minute use short units');
is(&subs::duration_sayer(90),     '1m 30s',     'a minute and a half');
is(&subs::duration_sayer(-90),    '-1m 30s',    'a negative duration keeps one minus');
is(&subs::duration_sayer(0),      '0s',         'zero is zero seconds');
is(&subs::duration_sayer(0.5),    '500.00ms',   'a sub-second duration reads in milliseconds');
is(&subs::duration_sayer(86400),  '1d',         'a day collapses to one unit');
is(&subs::duration_sayer(604800), '7d',         'a week reads as seven days');

# -------------------------------------------------------------- duration_readout
is(&subs::duration_readout(90000),
	'<span class="jawnos_duration" duration="90000">1m 30s</span>',
	'a readout carries the absolute span and its text');
is(&subs::duration_readout(-90000, class => 'small', hint => 'x'),
	'<span class="jawnos_duration small" duration="90000" sign="-" hint="x">-1m 30s</span>',
	'a negative readout carries sign="-" and its options');
is(&subs::duration_readout('abc'), '', 'a non-numeric span renders nothing');

# ------------------------------------------------------- time_abbrev_translator
# Deterministic only: months and years follow the calendar, so a fixed $from
# makes February and a leap year assertable.
my $jan2024 = ts(2024, 1, 1);
is(&subs::time_abbrev_translator('1h'),          3600000,   'one hour in milliseconds');
is(&subs::time_abbrev_translator('30m'),         1800000,   'thirty minutes in milliseconds');
is(&subs::time_abbrev_translator('1d'),          86400000,  'one day in milliseconds');
is(&subs::time_abbrev_translator('1w'),          604800000, 'one week in milliseconds');
is(&subs::time_abbrev_translator('1h 30m'),      5400000,   'a compound shorthand adds up');
is(&subs::time_abbrev_translator('1y', $jan2024), 31622400000, 'a year across leap February is 366 days');
is(&subs::time_abbrev_translator('1y', ts(2023, 1, 1)), 31536000000, 'a common year is 365 days');
is(&subs::time_abbrev_translator('1M', $jan2024), 2678400000, 'a January month is 31 days');
is(&subs::time_abbrev_translator('1M', ts(2024, 2, 1)), 2505600000, 'a leap February is 29 days');
is(&subs::time_abbrev_translator('Infinity'),    '1',       'a non-finite timing is one millisecond');
ok(!defined &subs::time_abbrev_translator(''),             'an empty timing has no value');

done_testing();
