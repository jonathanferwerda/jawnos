use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# The Sys panel's "Balance drop" chart. The AI balance job keeps a rolling week
# of samples in its cache row; these tests pin the window arithmetic (the
# synthetic point at the left edge, the change, the pace per day) and the SVG
# the template draws from it, so a wrong sign or a division by zero cannot ship.

my $H = 3600 * 1000;
my $now = 1_700_000_000_000;

my @points = (
	{ t => $now - 48 * $H, v => 100, c => 'USD' },
	{ t => $now - 25 * $H, v => 90,  c => 'USD' },
	{ t => $now - 12 * $H, v => 80,  c => 'USD' },
	{ t => $now,           v => 70,  c => 'USD' },
);

my $day = &subs::ai_balance_window(\@points, '24h', $now);
is scalar @{ $day->{'points'} }, 3,
	'the 24h window adds an interpolated point at its left edge';
is $day->{'points'}->[0]->{'t'}, $now - 24 * $H,
	'and that point sits at the start of the window';
cmp_ok abs($day->{'points'}->[0]->{'v'} - (90 - 10 / 13)), '<', 0.001,
	'its value is the line between the sample before and the first inside';
is $day->{'hours'}, 24, 'the span runs the whole 24 hours';
cmp_ok abs($day->{'change'} - (90 - 10 / 13 - 70)), '<', 0.001,
	'the change is the fall from the window start to the last sample';
cmp_ok abs($day->{'per_day'} - $day->{'change'}), '<', 0.001,
	'and a 24 hour window reads that change as the daily pace';

my $week = &subs::ai_balance_window(\@points, '7d', $now);
is scalar @{ $week->{'points'} }, 4, 'the 7d window keeps every sample in the week';
is $week->{'hours'}, 48, 'over the span the samples actually cover';
cmp_ok abs($week->{'change'} - 30), '<', 0.001, 'the change is the fall over the week';
cmp_ok abs($week->{'per_day'} - 15), '<', 0.001, 'and the pace is scaled to a day';

# A rising balance is a negative change, so the template can say Rise.
my $rise = [ { t => $now - 12 * $H, v => 10 }, { t => $now, v => 20 } ];
my $up = &subs::ai_balance_window($rise, '24h', $now);
cmp_ok $up->{'per_day'}, '<', 0, 'a top-up makes the pace negative';

# Nothing in the window is empty, not a flat line at zero.
my $old = &subs::ai_balance_window([ { t => $now - 8 * 24 * $H, v => 5 } ], '24h', $now);
is scalar @{ $old->{'points'} }, 0, 'a sample older than the window draws nothing';
ok !defined $old->{'per_day'}, 'and has no pace';

# A failed read is absent, not zero, and a future point cannot leak in.
my $noisy = [
	{ t => $now - 12 * $H, v => 80 },
	{ t => $now - 2 * $H,  v => undef },
	{ t => $now + 1 * $H,  v => 1 },
	{ t => $now,           v => 70 },
];
my $clean = &subs::ai_balance_window($noisy, '24h', $now);
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

is &subs::ai_balance_money(12.345), '12.35', 'normal money keeps two decimals';
is &subs::ai_balance_money(0.0042), '0.0042', 'a slow spend keeps four';
is &subs::ai_balance_money(0), '0.00', 'zero reads as zero';
is &subs::ai_balance_money(undef), '', 'an unread balance has no number';
is &subs::currency_money(12.345), '12.35', 'currency_money is the general formatter';
is &subs::currency_money(0.0042), '0.0042', 'and keeps four decimals for a slow spend';

# The currency picker: the house currency first, the amount's own currency
# second, then the fiat table. Rates are target units per one house unit, so a
# base amount times the option rate is the amount in that currency.
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

# The assembled chart follows the rows, so a provider that left the settings
# cannot leave a ghost line behind. It converts to the house currency at the
# rate snapshot; the functions are pinned here so the assertion does not move
# with the machine's real exchange rate.
my $report = {
	at => $now,
	rows => [ { provider => 'deepseek', label => 'DeepSeek', available => 70, currency => 'USD' } ],
	history => { deepseek => \@points, openrouter => \@points },
};
{
	local *subs::crypto_report_currency = sub { 'CAD' };
	local *subs::exchange_rate = sub { return ($_[0] eq 'USD' && $_[1] eq 'CAD') ? 1.5 : undef };
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
	cmp_ok abs($chart->{'series'}->[0]->{'windows'}->{'24h'}->{'per_day'} - (90 - 10 / 13 - 70) * 1.5), '<', 0.001,
		'and the pace is converted by the same rate';
}
{
	local *subs::crypto_report_currency = sub { 'CAD' };
	local *subs::exchange_rate = sub { undef };
	my $chart = &subs::ai_balance_chart($report, $now);
	is $chart->{'series'}->[0]->{'currency'}, 'USD', 'no rate keeps the provider currency';
	ok !$chart->{'converted'}, 'and does not claim a conversion';
	is_deeply $chart->{'unconverted'}, ['USD'], 'the missing rate is named';
}
{
	local *subs::crypto_report_currency = sub { 'USD' };
	local *subs::exchange_rate = sub { die 'no rate is needed when both are USD' };
	my $chart = &subs::ai_balance_chart($report, $now);
	is $chart->{'series'}->[0]->{'currency'}, 'USD', 'a provider already in house currency stays as it is';
	ok !$chart->{'converted'}, 'with no conversion claimed';
	is_deeply $chart->{'unconverted'}, [], 'and no missing rate';
}

my $no_rows = &subs::ai_balance_chart({ at => $now, rows => [], history => { deepseek => \@points } }, $now);
is scalar @{ $no_rows->{'series'} }, 0, 'history without a registered row draws nothing';

done_testing();
