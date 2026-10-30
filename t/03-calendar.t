use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# Calendar arithmetic. The suite pins TZ=UTC in JawnOSTest, so every assertion
# here is a civil date and never a local-time accident.

# ---------------------------------------------------------------- is_leap_year
is(&subs::is_leap_year(2000), 1, '2000 is a leap year (divisible by 400)');
is(&subs::is_leap_year(1900), 0, '1900 is not a leap year (century, not 400)');
is(&subs::is_leap_year(2100), 0, '2100 is not a leap year');
is(&subs::is_leap_year(2024), 1, '2024 is a leap year');
is(&subs::is_leap_year(2023), 0, '2023 is not a leap year');

# --------------------------------------------------------------- days_in_month
is(&subs::days_in_month(2024, 2),  29, 'a leap February has 29 days');
is(&subs::days_in_month(2023, 2),  28, 'a common February has 28 days');
is(&subs::days_in_month(2024, 4),  30, 'April has 30 days');
is(&subs::days_in_month(2024, 12), 31, 'December has 31 days');
is(&subs::days_in_month(2024, 13),  0, 'a thirteenth month does not exist');
is(&subs::days_in_month(2024, 0),   0, 'a zeroth month does not exist');

# --------------------------------------------------------------- calendar_shift
is(ymd(&subs::calendar_shift(ts(2024, 1, 31), 1, 'month')),
	'2024-02-29', '31 January + 1 month clamps to the leap month');
is(ymd(&subs::calendar_shift(ts(2023, 1, 31), 1, 'month')),
	'2023-02-28', '31 January + 1 month clamps to a common February');
is(ymd(&subs::calendar_shift(ts(2024, 2, 29), 1, 'year')),
	'2025-02-28', '29 February + 1 year clamps to the 28th');
is(ymd(&subs::calendar_shift(ts(2024, 1, 31), 2, 'month', 31)),
	'2024-03-31', 'an anchor day returns to the 31st after a short month');
is(ymd(&subs::calendar_shift(ts(2024, 3, 9), 1, 'day')),
	'2024-03-10', 'a day step walks the calendar');
is(ymd(&subs::calendar_shift(ts(2024, 3, 9), -1, 'day')),
	'2024-03-08', 'a negative day step walks backwards');
is(ymd(&subs::calendar_shift(ts(2024, 3, 9), 1, 'week')),
	'2024-03-16', 'a week is seven calendar days');
is(ymd(&subs::calendar_shift(ts(2024, 3, 9), 0, 'day')),
	'2024-03-09', 'a zero count returns the moment unchanged');
is(&subs::calendar_shift(ts(2024, 3, 9, 12, 34), 2, 'hour'),
	ts(2024, 3, 9, 14, 34), 'hours are a plain multiple');

# --------------------------------------------------------- nth_weekday_of_month
is(&subs::nth_weekday_of_month(2024, 1, 1, 1),   1, 'the first Monday of January 2024 is the 1st');
is(&subs::nth_weekday_of_month(2024, 1, 1, -1), 29, 'the last Monday of January 2024 is the 29th');
is(&subs::nth_weekday_of_month(2024, 2, 4, 5),  29, 'the fifth Thursday of February 2024 is the 29th');
is(&subs::nth_weekday_of_month(2024, 2, 4, 6),   0, 'February 2024 has no sixth Thursday');
is(&subs::nth_weekday_of_month(2024, 2, 1, 1),   5, 'the first Monday of February 2024 is the 5th');

# ------------------------------------------------------------------ easter
is(join('-', &subs::easter_sunday(2024)), '3-31', 'Easter 2024 is 31 March');
is(join('-', &subs::easter_sunday(2025)), '4-20', 'Easter 2025 is 20 April');
is(join('-', &subs::easter_sunday(2026)), '4-5',  'Easter 2026 is 5 April');
is(join('-', &subs::easter_sunday(2000)), '4-23', 'Easter 2000 is 23 April');

# ------------------------------------------------------------------ day_key
is(&subs::day_key(ts(2024, 1, 15)), '2024-01-15', 'a moment has a civil day key');
is(&subs::day_key(ts(2024, 1, 15, 23, 59)), '2024-01-15', 'the late evening still belongs to its day');
is(&subs::day_key(ts(2024, 1, 16, 0, 0)), '2024-01-16', 'midnight starts the next day');
is(&subs::day_key(undef), '', 'no moment has no day key');

done_testing();
