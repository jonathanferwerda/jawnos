# tests-for: lib/JawnOS/Domain/Ai3.pm lib/JawnOS/Domain/Run.pm lib/JawnOS/Domain/Ai2.pm lib/JawnOS/Domain/Migrations.pm lib/JawnOS/Domain/Crypto.pm lib/JawnOS/Domain/Git.pm lib/JawnOS/Domain/Loader.pm
# covers:    Window spans, clock-aligned bars, the token ledger's place beside them, and the chart assembly.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# The domain layer is lazy: load the real definitions before the local *subs::
# stubs below, or a later module load would replace them.
subs::preload($_) for qw(crypto_rates_read crypto_report_currency exchange_rate);
subs::preload($_) for qw(ai_spend_since ai_spend_buckets ai_spend_roles ai_balance_role_label);

# The Sys panel's "Balance drop" chart. These tests pin the four windows (Last
# Hour in two-minute bars, Last Day in hours, Last Week and Last Month in days),
# the window arithmetic behind them, the spread of a fall across the bars it
# covers, the token ledger's place beside a bar, and the SVG the template draws.

my $H = 3600 * 1000;
my $M = 60 * 1000;
my $now = 1_700_000_000_000;          # 2023-11-14 22:13:20 UTC
my $aligned = $now - ($now % $H);     # the top of that hour, for clean edges

my @points = (
	{ t => $now - 48 * $H, v => 100, c => 'USD' },
	{ t => $now - 25 * $H, v => 90,  c => 'USD' },
	{ t => $now - 12 * $H, v => 80,  c => 'USD' },
	{ t => $now,           v => 70,  c => 'USD' },
);

# ---- the windows ------------------------------------------------------------
is &subs::ai_window_span_ms('1h'), $H, 'the hour window spans an hour';
is &subs::ai_window_span_ms('1d'), 24 * $H, 'the day window spans twenty-four hours';
is &subs::ai_window_span_ms('1w'), 7 * 24 * $H, 'the week window spans seven days';
is &subs::ai_window_span_ms('1m', $now), 30 * 24 * $H,
	'the month window is as long as November';
is &subs::ai_window_span_ms('nonsense', $now), 24 * $H, 'an unknown window is the day';
is &subs::ai_window_bucket_count('1h'), 30, 'the hour draws thirty two-minute bars';
is &subs::ai_window_bucket_count('1d'), 24, 'the day draws twenty-four hourly bars';
is &subs::ai_window_bucket_count('1w'), 7, 'the week draws seven daily bars';
is &subs::ai_window_bucket_count('1m', $now), 30, 'and the month one per day of November';
is &subs::ai_window_bucket_count('1m', ts(2026, 12, 3, 9)), 31, 'December has thirty-one';
is &subs::ai_window_bucket_count('1m', ts(2028, 2, 3, 9)), 29, 'a leap February has twenty-nine';

my $day = &subs::ai_balance_window(\@points, '1d', $now);
is scalar @{ $day->{'points'} }, 3,
	'the day window adds an interpolated point at its left edge';
is $day->{'points'}->[0]->{'t'}, $now - 24 * $H,
	'and that point sits at the start of the window';
cmp_ok abs($day->{'points'}->[0]->{'v'} - (90 - 10 / 13)), '<', 0.001,
	'its value is the line between the sample before and the first inside';
is $day->{'hours'}, 24, 'the span runs the whole 24 hours';
cmp_ok abs($day->{'change'} - (90 - 10 / 13 - 70)), '<', 0.001,
	'the change is the fall from the window start to the last sample';
cmp_ok abs($day->{'per_day'} - $day->{'change'}), '<', 0.001,
	'and a 24 hour window reads that change as the daily pace';

my $week = &subs::ai_balance_window(\@points, '1w', $now);
is scalar @{ $week->{'points'} }, 4, 'the week window keeps every sample in the week';
is $week->{'hours'}, 48, 'over the span the samples actually cover';
cmp_ok abs($week->{'change'} - 30), '<', 0.001, 'the change is the fall over the week';
cmp_ok abs($week->{'per_day'} - 15), '<', 0.001, 'and the pace is scaled to a day';

my $last_hour = &subs::ai_balance_window(\@points, '1h', $now);
is $last_hour->{'window'}, '1h', 'the hour window names itself';
is $last_hour->{'hours'}, 1, 'and covers an hour';
is scalar @{ $last_hour->{'points'} }, 2, 'with the sample and its interpolated edge';
my $unknown_window = &subs::ai_balance_window(\@points, 'nonsense', $now);
is $unknown_window->{'window'}, '1d', 'an unknown window reads as the day';

# A rise is money put in, not a negative burn. Consumption counts only the
# falls, so the pace stays at zero and there is no runway to promise.
my $rise = [ { t => $now - 12 * $H, v => 10 }, { t => $now, v => 20 } ];
my $up = &subs::ai_balance_window($rise, '1d', $now);
is $up->{'consumption'}, 0, 'a top-up adds no consumption';
is $up->{'per_day'}, 0, 'and never reads as a negative rate';
ok !defined $up->{'runway_hours'}, 'a balance that is not falling has no runway';
is scalar @{ $up->{'topups'} }, 1, 'but the top-up is named';
cmp_ok abs($up->{'topups'}->[0]->{'amount'} - 10), '<', 0.001, 'with what was put in';
like $up->{'topups'}->[0]->{'label'}, qr/^\d\d:\d\d$/, 'and when, on the clock';

# The same burn either side of a top-up: one series jumps up 50 and settles,
# one holds level. Both spent 30 over the same 48 hours, so both must report
# 30/48 h - the top-up neither dilutes the rate nor turns it into a rise.
my $topup = [
	{ t => $now - 48 * $H, v => 100 },
	{ t => $now - 36 * $H, v => 90 },
	{ t => $now - 24 * $H, v => 140 },
	{ t => $now - 12 * $H, v => 130 },
	{ t => $now,           v => 120 },
];
my $steady = [
	{ t => $now - 48 * $H, v => 100 },
	{ t => $now - 36 * $H, v => 90 },
	{ t => $now - 24 * $H, v => 90 },
	{ t => $now - 12 * $H, v => 80 },
	{ t => $now,           v => 70 },
];
my $with_topup = &subs::ai_balance_window($topup, '1w', $now);
my $without = &subs::ai_balance_window($steady, '1w', $now);
cmp_ok abs($with_topup->{'consumption'} - 30), '<', 0.001, 'only the falls count as consumption';
cmp_ok abs($with_topup->{'per_day'} - $without->{'per_day'}), '<', 0.001,
	'a top-up does not change the drop rate the window saw';
cmp_ok abs($with_topup->{'per_day'} - 15), '<', 0.001, 'and that rate is the real burn';
is scalar @{ $with_topup->{'topups'} }, 1, 'the jump is still reported as a top-up';

# Runway is what is left over what is burning, and the expense is that burn
# carried over the usual spans.
cmp_ok abs($with_topup->{'runway_hours'} - 192), '<', 0.001,
	'runway is the balance divided by the burn (120 / 0.625 per hour)';
cmp_ok abs($with_topup->{'runway_days'} - 8), '<', 0.001, 'the same runway in days';
cmp_ok abs($with_topup->{'expense_day'} - 15), '<', 0.001, 'the daily spend is the burn';
cmp_ok abs($with_topup->{'expense_week'} - 105), '<', 0.001, 'weekly spend is seven days of it';
cmp_ok abs($with_topup->{'expense_month'} - 450), '<', 0.001, 'monthly spend is thirty days of it';

# Provider rounding is not a spend: a re-read a hair lower is not a fall.
my $rounding = &subs::ai_balance_window([
	{ t => $now - 12 * $H, v => 80 },
	{ t => $now,           v => 79.9999995 },
], '1d', $now);
is $rounding->{'consumption'}, 0, 'a sub-micro-unit wobble is not consumption';

# One point is a sample, not a pace: nothing to divide by yet.
my $one = &subs::ai_balance_window([ { t => $now - 2 * $H, v => 5 } ], '1d', $now);
is scalar @{ $one->{'points'} }, 1, 'a single sample is drawn on its own';
ok !defined $one->{'per_day'}, 'with no pace to report';
ok !defined $one->{'runway_hours'}, 'and no runway';
ok !defined $one->{'expense_day'}, 'and no expense';

# Nothing in the window is empty, not a flat line at zero.
my $old = &subs::ai_balance_window([ { t => $now - 40 * 24 * $H, v => 5 } ], '1d', $now);
is scalar @{ $old->{'points'} }, 0, 'a sample older than the window draws nothing';
ok !defined $old->{'per_day'}, 'and has no pace';

# A failed read is absent, not zero, and a future point cannot leak in.
my $noisy = [
	{ t => $now - 12 * $H, v => 80 },
	{ t => $now - 2 * $H,  v => undef },
	{ t => $now + 1 * $H,  v => 1 },
	{ t => $now,           v => 70 },
];
my $clean = &subs::ai_balance_window($noisy, '1d', $now);
is scalar @{ $clean->{'points'} }, 2, 'undef and future samples are ignored';

# The line itself: no NaN, no unescaped text, and one point still draws.
my $svg = &subs::ai_balance_sparkline($day->{'points'}, $day->{'start'}, $now, 320, 80);
like $svg, qr/^<svg class="balance_spark"/, 'the sparkline is an svg';
like $svg, qr/<polyline points="[\d., ]+"/, 'with a polyline of numbers';
unlike $svg, qr/NaN|undef/, 'and nothing unrenderable';
my $single = &subs::ai_balance_sparkline([ { t => $now, v => 3 } ], $now - $H, $now, 320, 80);
like $single, qr/<svg/, 'one point still draws';

is &subs::ai_balance_span_label(0.5), '30 min', 'a short span reads in minutes';
is &subs::ai_balance_span_label(5), '5 h', 'a day span reads in hours';
is &subs::ai_balance_span_label(24), '24 h', '24 hours keeps hours';
is &subs::ai_balance_span_label(48), '2 d', 'two days crosses to days';
is &subs::ai_balance_span_label(168), '7 d', 'a week reads in days';

is &subs::currency_money(12.345), '12.35', 'normal money keeps two decimals';
is &subs::currency_money(0.0042), '0.0042', 'a slow spend keeps four';

# ---- the bars' clock --------------------------------------------------------
my $hour_edges = &subs::ai_balance_edges('1h', $aligned);
is scalar @{$hour_edges}, 30, 'the hour window has thirty bars';
is $hour_edges->[1]{'start'} - $hour_edges->[0]{'start'}, 2 * $M, 'each bar is two minutes';
is $hour_edges->[-1]{'end'} - $hour_edges->[0]{'start'}, $H, 'and together they span the hour';
is $hour_edges->[-1]{'start'}, $aligned, 'the last bar starts on the aligned clock';
is $hour_edges->[-1]{'end'}, $aligned + 2 * $M, 'and is the two minutes in progress';
like $hour_edges->[-1]{'key'}, qr/^\d{4}-\d\d-\d\d \d\d:[0-5]\d$/, 'with a minute key';
is substr($hour_edges->[-1]{'key'}, 14, 2) % 2, 0, 'that starts on an even minute';
like $hour_edges->[-1]{'label'}, qr/^\d\d:[0-5]\d$/, 'and a clock label';

my $day_edges = &subs::ai_balance_edges('1d', $now);
is scalar @{$day_edges}, 24, 'the day window has twenty-four bars';
is $day_edges->[1]{'start'} - $day_edges->[0]{'start'}, $H, 'each bar is an hour';
is $day_edges->[-1]{'end'}, $aligned + $H, 'the last bar is the hour in progress... and its end';
cmp_ok $day_edges->[-1]{'start'}, '<=', $now, 'started already';
cmp_ok $day_edges->[-1]{'end'}, '>', $now, 'and has not ended';
like $day_edges->[-1]{'label'}, qr/^\d\d:00$/, 'labelled on the hour';

my $week_edges = &subs::ai_balance_edges('1w', $now);
is scalar @{$week_edges}, 7, 'the week window has seven bars';
is $week_edges->[1]{'start'} - $week_edges->[0]{'start'}, 24 * $H, 'each bar is a day';
like $week_edges->[-1]{'key'}, qr/^\d{4}-\d\d-\d\d$/, 'with a date key';
is $week_edges->[-1]{'key'}, '2023-11-14', 'the last bar is today';
cmp_ok $week_edges->[-1]{'end'}, '>', $now, 'and runs to tomorrow midnight';
cmp_ok $week_edges->[0]{'start'}, '<=', $now - 6 * 24 * $H, 'the first starts six days back';

my $month_edges = &subs::ai_balance_edges('1m', $now);
is scalar @{$month_edges}, 30, 'the month window has a bar per day of November';
is $month_edges->[-1]{'key'}, '2023-11-14', 'ending today';

# ---- a fall spread across the bars it covers --------------------------------
my $spread_points = [
	{ t => $aligned - 5 * $H, v => 100 },
	{ t => $aligned - 4 * $H, v => 90 },   # 10 over that hour
	{ t => $aligned - 3 * $H, v => 90 },
	{ t => $aligned - 2 * $H, v => 95 },   # a top-up
	{ t => $aligned - 1 * $H, v => 90 },   # 5 over that hour
	{ t => $aligned,          v => 90 },
];
my $spread = &subs::ai_balance_buckets($spread_points, '1d', $aligned, {});
is $spread->{'count'}, 24, 'twenty-four hourly bars';
is $spread->{'samples'}, 6, 'six readings inside the day';
cmp_ok abs($spread->{'total'} - 15), '<', 0.001, 'the day spent the two falls';
cmp_ok abs($spread->{'buckets'}->[18]->{'spend'} - 10), '<', 0.001,
	'a fall wholly inside an hour lands in that hour';
cmp_ok abs($spread->{'buckets'}->[20]->{'spend'}), '<', 0.001,
	'the hour before the top-up holds no spend of its own';
cmp_ok abs($spread->{'buckets'}->[21]->{'spend'} - 5), '<', 0.001,
	'the later fall lands in the hour it covers';
cmp_ok abs($spread->{'buckets'}->[22]->{'spend'}), '<', 0.001,
	'and not in the one after it';
my $spend_sum = 0;
$spend_sum += $_->{'spend'} for @{ $spread->{'buckets'} };
cmp_ok abs($spend_sum - $spread->{'total'}), '<', 0.001, 'the bars add up to the day';
my $share_sum = 0;
$share_sum += $_->{'share'} for @{ $spread->{'buckets'} };
cmp_ok abs($share_sum - 100), '<', 0.001, 'and the shares add up to the whole';
cmp_ok abs($spread->{'max'} - 10), '<', 0.001, 'the busiest hour sets the scale';
is $spread->{'peak'}->{'key'}, $spread->{'buckets'}->[18]->{'key'}, 'and is named as the peak';

# A fall between two readings that straddle bars is split by time, so a
# two-minute window reads the same way as an hourly one. The thirty bars are
# clock-aligned two-minute slices, so the oldest slice of the hour's elapsed
# time (up to one bar) sits before the first bar.
my $fine = &subs::ai_balance_buckets([
	{ t => $aligned - $H, v => 90 },
	{ t => $aligned,      v => 80 },
], '1h', $aligned, {});
cmp_ok abs($fine->{'total'} - (10 * 58 / 60)), '<', 0.001,
	'the hour spent ten, less the slice before the first bar';
cmp_ok abs($fine->{'buckets'}->[0]->{'spend'} - ($fine->{'total'} / 29)), '<', 0.001,
	'spread evenly over the twenty-nine bars the fall covers';
cmp_ok abs($fine->{'buckets'}->[28]->{'spend'} - ($fine->{'total'} / 29)), '<', 0.001,
	'with none of it lost in the middle';
cmp_ok abs($fine->{'buckets'}->[-1]->{'spend'}), '<', 0.001,
	'and the bar in progress has not spent yet';

# A fall that began before the window is carried in at the left edge.
my $edge = &subs::ai_balance_buckets([
	{ t => $aligned - 30 * $H, v => 200 },
	{ t => $aligned - 12 * $H, v => 100 },
], '1d', $aligned, {});
cmp_ok $edge->{'total'}, '>', 0, 'the drop across the window edge is counted';
cmp_ok abs($edge->{'buckets'}->[0]->{'spend'} - ($edge->{'total'} / 11)), '<', 0.001,
	'and the first hour takes its share of the eleven the fall covers';
my $edge_sum = 0;
$edge_sum += $_->{'spend'} for @{ $edge->{'buckets'} };
cmp_ok abs($edge_sum - $edge->{'total'}), '<', 0.001, 'and the bars still add up';

# A flat balance is empty, not a busy bar.
my $flat = &subs::ai_balance_buckets([
	{ t => $aligned - 2 * $H, v => 5 },
	{ t => $aligned,          v => 5 },
], '1d', $aligned, {});
is $flat->{'total'}, 0, 'a balance that held steady spent nothing';
ok !$flat->{'peak'}, 'and has no busiest bar';

# ---- tokens beside the bars -------------------------------------------------
{
	my $key = $spread->{'buckets'}->[18]->{'key'};
	my $ledger_since = $aligned - 12 * $H;
	my $with_tokens = &subs::ai_balance_buckets($spread_points, '1d', $aligned, {
		$key => { tokens => 1200, calls => 4, models => { 'gpt-4o' => 800, 'deepseek-chat' => 400 } },
	}, $ledger_since);
	is $with_tokens->{'buckets'}->[18]->{'tokens'}, 1200, 'a bar carries its token count';
	is $with_tokens->{'buckets'}->[18]->{'calls'}, 4, 'and its calls';
	is $with_tokens->{'buckets'}->[18]->{'top_model'}, 'gpt-4o', 'and names the busiest model';
	like $with_tokens->{'buckets'}->[18]->{'models_text'}, qr/gpt-4o 800/,
		'with the split across models';
	is $with_tokens->{'buckets'}->[17]->{'tokens'}, 0, 'a bar with no ledger row is zero';
	is $with_tokens->{'tokens'}, 1200, 'the window totals its tokens';
	is $with_tokens->{'buckets'}->[0]->{'tracked'}, 0, 'a bar before the ledger is untracked';
	is $with_tokens->{'buckets'}->[18]->{'tracked'}, 1, 'a bar inside it is tracked';
	is $with_tokens->{'buckets'}->[17]->{'models_text'}, '', 'one model is not a split';
}

# ---- the drawing ------------------------------------------------------------
my $bar_svg = &subs::ai_balance_bars($spread, 320, 48, {
	detail => 'D {0} {1} {2} {3} {4}', untracked => 'U {0} {1} {2}',
	model => 'M {0}', models => 'S {0}',
});
like $bar_svg, qr/^<svg class="balance_bars"/, 'the bars are an svg';
is scalar(() = $bar_svg =~ /<rect class="peak"/g), 1, 'the busiest bar is marked';
is scalar(() = $bar_svg =~ /<rect class="hit"/g), 24, 'and every bar has a hit column';
is scalar(() = $bar_svg =~ /<rect(?![^>]*class="hit")/g), 24, 'with one visible bar each';
like $bar_svg, qr/data-bk="2023-11-1\d \d\d"/, 'each bar carries its key';
like $bar_svg, qr/data-amt="\d+\.\d{6}"/, 'and its amount for the line';
like $bar_svg, qr/data-detail-template="D \{0\} \{1\} \{2\} \{3\} \{4\}"/, 'with the translated line templates';
like $bar_svg, qr/data-untracked-template="U \{0\} \{1\} \{2\}"/, 'both the tracked and untracked lines';
unlike $bar_svg, qr/NaN|undef/, 'and nothing unrenderable';
is &subs::ai_balance_bars({ buckets => [] }, 320, 48), '', 'no bars draws nothing';

# ---- the currency picker ----------------------------------------------------
{
	local *subs::crypto_report_currency = sub { 'CAD' };
	local *subs::crypto_rates_read = sub {
		return { base => 'CAD', at => 1, rates => { CAD => 1, USD => 1.40, EUR => 1.55, JPY => 200 } };
	};
	my ($base, $codes) = &subs::currency_options('USD');
	is $base, 'CAD', 'the picker names the house currency';
	is $codes->[0]->{'code'}, 'CAD', 'which is the first option';
	is $codes->[1]->{'code'}, 'USD', "and the amount's own currency is second";
	cmp_ok abs($codes->[0]->{'rate'} - 1), '<', 0.000001, 'the house currency is one to one';
	cmp_ok abs($codes->[1]->{'rate'} - (1 / 1.40)), '<', 0.000001, 'USD is one over the CAD-per-USD rate';
	my ($eur) = grep { $_->{'code'} eq 'EUR' } @{$codes};
	ok $eur, 'a currency with a rate is offered';
	cmp_ok abs($eur->{'rate'} - (1 / 1.55)), '<', 0.000001, 'with its own converted rate';
	my %seen;
	is scalar(grep { $seen{$_->{'code'}}++ } @{$codes}), 0, 'no currency is listed twice';
	ok !grep({ $_->{'code'} eq 'BTC' } @{$codes}), 'coins are not offered as currencies';
}
{
	local *subs::crypto_report_currency = sub { 'CAD' };
	local *subs::exchange_rate = sub { return ($_[0] eq 'USD' && $_[1] eq 'CAD') ? 1.4 : undef };
	is &subs::currency_amount_base(70, 'USD', 'CAD'), 98, '70 USD becomes 98 CAD';
	is &subs::currency_amount_base(70, 'CAD', 'CAD'), 70, 'the house currency is already itself';
	ok !defined &subs::currency_amount_base(70, 'XYZ', 'CAD'), 'an unknown currency has no base value';
	is &subs::currency_amount_base(70, 'USD'), 98, 'the house currency is the default target';
}

# ---- the assembled chart ----------------------------------------------------
my $report = {
	at => $now,
	rows => [ { provider => 'deepseek', label => 'DeepSeek', available => 70, currency => 'USD' } ],
	history => { deepseek => \@points, openrouter => \@points },
};
{
	local *subs::crypto_report_currency = sub { 'CAD' };
	local *subs::exchange_rate = sub { return ($_[0] eq 'USD' && $_[1] eq 'CAD') ? 1.5 : undef };
	local *subs::ai_spend_since = sub { undef };
	local *subs::ai_spend_buckets = sub {
		my ($granularity, $since) = @_;
		return $granularity eq 'day'
			? { deepseek => { '2023-11-14' => { tokens => 900, calls => 3, models => { 'gpt-4o' => 900 } } } }
			: {};
	};
	local *subs::ai_spend_roles = sub {
		return { deepseek => { help_assistant => 700, eval_assistant => 200 } };
	};
	my $chart = &subs::ai_balance_chart($report, $now);
	is scalar @{ $chart->{'series'} }, 1, 'only the registered provider is charted';
	is $chart->{'series'}->[0]->{'provider'}, 'deepseek', 'with its own name';
	is $chart->{'base'}, 'CAD', 'the chart names the house currency';
	is $chart->{'series'}->[0]->{'currency'}, 'CAD', 'and the balance is shown in it';
	is $chart->{'series'}->[0]->{'source_currency'}, 'USD', 'the provider currency is kept';
	is $chart->{'series'}->[0]->{'source_available'}, 70, 'and the provider figure is kept for the picker';
	ok $chart->{'converted'}, 'the chart records that it converted';
	is_deeply $chart->{'unconverted'}, [], 'and nothing was left behind';
	cmp_ok abs($chart->{'series'}->[0]->{'available'} - 105), '<', 0.001,
		'70 USD at 1.5 is 105 CAD';
	is_deeply $chart->{'windows'}, [ '1h', '1d', '1w', '1m' ], 'the chart offers the four windows';
	my $one_day = $chart->{'series'}->[0]->{'windows'}->{'1d'};
	ok $one_day->{'line'}, 'each window carries its line';
	ok $one_day->{'bars'}, 'and its bars';
	is $one_day->{'bars'}->{'count'}, 24, 'with twenty-four of them';
	my $raw_bars = &subs::ai_balance_buckets(\@points, '1d', $now, {});
	cmp_ok abs($one_day->{'line'}->{'per_day'} - (90 - 10 / 13 - 70) * 1.5), '<', 0.001,
		'and the pace is converted by the same rate';
	cmp_ok abs($one_day->{'bars'}->{'total'} - $raw_bars->{'total'} * 1.5), '<', 0.001,
		'the bars are the same day converted by the same rate';
	is scalar @{ $one_day->{'roles'} }, 2, 'and the roles the ledger recorded are listed';
	is $one_day->{'roles'}->[0]->{'label'}, 'Guide', 'largest first, by its app name';
	is $one_day->{'roles'}->[0]->{'role'}, 'help_assistant', 'with the role kept';
	cmp_ok abs($one_day->{'roles'}->[0]->{'share'} - (700 / 900 * 100)), '<', 0.001,
		'and its share of the window';
	ok !defined $one_day->{'per_k'}, 'the cost per thousand tokens needs both sides measured';
	my $week_window = $chart->{'series'}->[0]->{'windows'}->{'1w'};
	is scalar @{ $week_window->{'compare'} || [] }, 1, 'a single account has nothing to compare';
}
{
	local *subs::crypto_report_currency = sub { 'CAD' };
	local *subs::exchange_rate = sub { undef };
	local *subs::ai_spend_since = sub { undef };
	local *subs::ai_spend_buckets = sub { {} };
	local *subs::ai_spend_roles = sub { {} };
	my $chart = &subs::ai_balance_chart($report, $now);
	is $chart->{'series'}->[0]->{'currency'}, 'USD', 'no rate keeps the provider currency';
	ok !$chart->{'converted'}, 'and does not claim a conversion';
	is_deeply $chart->{'unconverted'}, ['USD'], 'the missing rate is named';
}
{
	local *subs::crypto_report_currency = sub { 'USD' };
	local *subs::exchange_rate = sub { die 'no rate is needed when both are USD' };
	local *subs::ai_spend_since = sub { undef };
	local *subs::ai_spend_buckets = sub { {} };
	local *subs::ai_spend_roles = sub { {} };
	my $chart = &subs::ai_balance_chart($report, $now);
	is $chart->{'series'}->[0]->{'currency'}, 'USD', 'a provider already in house currency stays as it is';
	ok !$chart->{'converted'}, 'with no conversion claimed';
	is_deeply $chart->{'unconverted'}, [], 'and no missing rate';
}
{
	# The cost per thousand tokens and the provider comparison show up when the
	# ledger has counted any traffic and there is a second account to compare.
	local *subs::crypto_report_currency = sub { 'USD' };
	local *subs::ai_spend_since = sub { undef };
	local *subs::ai_spend_buckets = sub {
		my ($granularity, $since) = @_;
		return $granularity eq 'day'
			? { deepseek => { '2023-11-14' => { tokens => 1000, calls => 5, models => { 'gpt-4o' => 1000 } } } }
			: {};
	};
	local *subs::ai_spend_roles = sub { {} };
	local *subs::exchange_rate = sub { 1 };
	my $two = {
		at => $now,
		rows => [
			{ provider => 'deepseek',   label => 'DeepSeek',   available => 70, currency => 'USD' },
			{ provider => 'openrouter', label => 'OpenRouter', available => 90, currency => 'USD' },
		],
		history => { deepseek => \@points, openrouter => \@points },
	};
	my $chart = &subs::ai_balance_chart($two, $now);
	is scalar @{ $chart->{'series'} }, 2, 'both accounts are charted';
	my $wd = $chart->{'series'}->[0]->{'windows'}->{'1w'};
	ok defined $wd->{'per_k'}, 'the week has a price per thousand tokens';
	cmp_ok abs($wd->{'per_k'} - (30 / 1000 * 1000)), '<', 0.001,
		'which is the spend over the tokens';
	is scalar @{ $wd->{'compare'} }, 2, 'and both accounts are compared';
	is $wd->{'compare'}->[0]->{'label'}, 'DeepSeek', 'by name';
}

my $no_rows = &subs::ai_balance_chart({ at => $now, rows => [], history => { deepseek => \@points } }, $now);
is scalar @{ $no_rows->{'series'} }, 0, 'history without a registered row draws nothing';

# ---- role labels ------------------------------------------------------------
is &subs::ai_balance_role_label('help_assistant'), 'Guide', 'a known role reads as its app';
is &subs::ai_balance_role_label('coding_assistant'), 'Coding', 'the coding agent keeps its name';
is &subs::ai_balance_role_label('weird_assistant'), 'Weird', 'an unknown role is tidied up';
is &subs::ai_balance_role_label(''), 'Other', 'a call that did not say who asked is Other';

# ---- the alert thresholds ---------------------------------------------------
{
	no warnings 'redefine';
	local *subs::crypto_report_currency = sub { 'USD' };
	local *subs::exchange_rate = sub { 1 };
	local *subs::ai_spend_since = sub { undef };
	local *subs::ai_spend_buckets = sub { {} };
	local *subs::ai_spend_roles = sub { {} };
	local *subs::ui = sub { return $_[0] };
	local *subs::random_string_creator = sub { 'alertuuid' };
	local *subs::ai_spend_prune = sub { return 1 };
	my $alert_report = {
		at => $now,
		rows => [ { provider => 'deepseek', label => 'DeepSeek', available => 90, currency => 'USD' } ],
		history => { deepseek => [
			{ t => $now - 3 * $H, v => 100 },
			{ t => $now - 2 * $H, v => 95 },
			{ t => $now - 1 * $H, v => 90 },
			{ t => $now,          v => 90 },
		] },
	};
	my %setting = ( ai_alert_hour => '1', ai_alert_runway => '30' );
	local *subs::setting_grabber = sub {
		my ($args) = @_;
		return $setting{ $args->{'setting'} };
	};
	my $check = &subs::ai_alert_check($alert_report, $now);
	is scalar @{ $check->{'fired'} }, 2, 'a low limit fires both the hour and the runway';
	my ($hour_alert) = grep { $_->{'kind'} eq 'hour' } @{ $check->{'fired'} };
	my ($runway_alert) = grep { $_->{'kind'} eq 'runway' } @{ $check->{'fired'} };
	ok $hour_alert, 'the hour is judged on the last complete bar';
	cmp_ok $hour_alert->{'amount'}, '>', 1, 'with the money it saw';
	ok $runway_alert, 'and the runway on the day window';
	cmp_ok $runway_alert->{'days'}, '<', 30, 'under the limit set';

	# A standing condition writes once, not on every turn.
	my (%cached, @inserted);
	local *subs::cache_get = sub { my ($args) = @_; return $cached{ $args->{'subcontext'} } };
	local *subs::cache_set = sub { my ($args) = @_; $cached{ $args->{'subcontext'} } = 1; return 1 };
	local *subs::db_insert = sub { push @inserted, $_[1]; return 1 };
	my $tick = &subs::ai_alert_tick($alert_report, $now);
	is scalar @{ $tick->{'written'} }, 2, 'both crossings write a note';
	is $inserted[0]->{'app'}, 'handbook', 'into the Handbook';
	like $inserted[0]->{'text'}, qr/DeepSeek/, 'naming the account';
	my $again = &subs::ai_alert_tick($alert_report, $now);
	is scalar @{ $again->{'written'} }, 0, 'a standing condition writes nothing more';
	is scalar @inserted, 2, 'so no duplicate notes land';

	# A blank box is off.
	%setting = ();
	my $off = &subs::ai_alert_check($alert_report, $now);
	is scalar @{ $off->{'fired'} }, 0, 'no thresholds means nothing to report';
}

done_testing();
