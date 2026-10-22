#!/usr/bin/perl
# Print the monthly GitHub Sponsors goal for JawnOS from the real bill.
#
# The GitHub Sponsors goal is a monthly USD amount, and there is no GraphQL
# mutation to set it, so this script only does the arithmetic and prints the
# description to paste into the dashboard.
#
# Defaults are the running costs given in October 2026:
#   tokens  $80.00 USD/week   (billed by the AI providers, in USD)
#   VPS     $9.00 CAD/month
#   phone   $29.38 CAD/month
#
# The CAD bills are converted at the current ECB reference rate (Frankfurter).
# Override anything on the command line; --rate skips the network.
#
#   perl scripts/sponsors_goal.pl
#   perl scripts/sponsors_goal.pl --tokens-usd-week 95 --vps-cad 12
#   perl scripts/sponsors_goal.pl --rate 0.71196
#   perl scripts/sponsors_goal.pl --json

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use JSON::PP qw(decode_json encode_json);
use HTTP::Tiny;
use POSIX qw(ceil);

my %opt = (
	tokens_usd_week => 80,
	vps_cad         => 9,
	phone_cad       => 29.38,
	round           => 5,
	rate_url        => 'https://api.frankfurter.app/latest?from=CAD&to=USD',
);

GetOptions(
	'tokens-usd-week=f' => \$opt{'tokens_usd_week'},
	'vps-cad=f'         => \$opt{'vps_cad'},
	'phone-cad=f'       => \$opt{'phone_cad'},
	'rate=f'            => \$opt{'rate'},
	'rate-date=s'       => \$opt{'rate_date'},
	'round=f'           => \$opt{'round'},
	'rate-url=s'        => \$opt{'rate_url'},
	'json'              => \$opt{'json'},
	'help|?'            => \$opt{'help'},
) or usage(1);

usage(0) if $opt{'help'};

foreach my $key (qw(tokens_usd_week vps_cad phone_cad)) {
	die "--$key must be a number\n" unless defined $opt{$key} && $opt{$key} =~ /^\d+(?:\.\d+)?$/;
}
die "--round must be greater than zero\n" unless $opt{'round'} > 0;

# The providers bill in USD, so only the two CAD lines need converting.
my ($rate, $rate_date) = rate_lookup();

my $tokens_usd = $opt{'tokens_usd_week'} * 52 / 12;
my $cad_usd    = ($opt{'vps_cad'} + $opt{'phone_cad'}) * $rate;
my $total      = $tokens_usd + $cad_usd;

# Round up so the goal covers the bill; an exact multiple stays put.
my $goal = $opt{'round'} * ceil(($total - 0.000001) / $opt{'round'});
$goal = 0 if $goal < 0;

my $annual = $total * 12;
my $weekly = $annual / 52;

my $description = sprintf(
	'$%s USD a week in AI tokens, $%s CAD for the VPS and $%s CAD for the phone that runs it: about $%s a month. Sponsorship pays that bill directly, and the code stays BSD-licensed and free.',
	money($opt{'tokens_usd_week'}),
	money($opt{'vps_cad'}),
	money($opt{'phone_cad'}),
	money($goal),
);

if ($opt{'json'}) {
	print encode_json({
		tokens_usd_per_week        => 0 + $opt{'tokens_usd_week'},
		vps_cad_per_month          => 0 + $opt{'vps_cad'},
		phone_cad_per_month        => 0 + $opt{'phone_cad'},
		rate_cad_usd               => 0 + $rate,
		rate_date                  => $rate_date,
		rate_source                => $opt{'rate_url'},
		tokens_usd_per_month       => round2($tokens_usd),
		cad_usd_per_month          => round2($cad_usd),
		total_usd_per_month        => round2($total),
		annual_usd                 => round2($annual),
		weekly_usd                 => round2($weekly),
		suggested_goal_usd_per_month => 0 + $goal,
		goal_rounding_usd          => 0 + $opt{'round'},
		description                => $description,
	}), "\n";
	exit 0;
}

printf "Monthly costs (1 CAD = %.5f USD, %s)\n", $rate, $rate_date;
printf "  tokens   \$%s USD/week   ->  \$%.2f\n", money($opt{'tokens_usd_week'}), $tokens_usd;
printf "  VPS      \$%s CAD/month  ->  \$%.2f\n", money($opt{'vps_cad'}), $opt{'vps_cad'} * $rate;
printf "  phone    \$%s CAD/month  ->  \$%.2f\n", money($opt{'phone_cad'}), $opt{'phone_cad'} * $rate;
print  "  ---------------------------------------------\n";
printf "  total                       \$%.2f USD/month\n\n", $total;

printf "Suggested goal: \$%s / month (rounded up to the next \$%s)\n", money($goal), money($opt{'round'});
printf "  annual: \$%.2f   weekly equivalent: \$%.2f\n\n", $annual, $weekly;

print "Paste this into the Sponsors dashboard (Goals):\n\n  $description\n";

exit 0;

sub rate_lookup {
	if (defined $opt{'rate'}) {
		die "--rate must be greater than zero\n" unless $opt{'rate'} > 0;
		return ($opt{'rate'}, $opt{'rate_date'} || 'given on the command line');
	}

	my $ua = HTTP::Tiny->new(
		timeout => 10,
		agent   => 'jawnos-sponsors-goal/1.0',
	);
	my $res = $ua->get($opt{'rate_url'});
	unless ($res->{'success'}) {
		die "could not fetch the CAD->USD rate ($res->{'status'} $res->{'reason'})\n"
			. "pass --rate <CAD in USD> to use a known rate instead\n";
	}

	my $data = eval { decode_json($res->{'content'}) };
	die "could not read the rate response from $opt{'rate_url'}\n" unless ref $data eq 'HASH';
	my $rate = $data->{'rates'} && $data->{'rates'}{'USD'};
	die "the rate response has no USD rate\n" unless defined $rate && $rate > 0;

	return ($rate, $data->{'date'} || 'unknown date');
}

# Trim trailing zeroes so 80.00 prints as 80 and 29.38 stays 29.38.
sub money {
	my ($value) = @_;
	my $text = sprintf('%.2f', $value);
	$text =~ s/\.00$//;
	$text =~ s/(\.\d)0$/$1/;
	return $text;
}

sub round2 {
	my ($value) = @_;
	return 0 + sprintf('%.2f', $value);
}

sub usage {
	my ($code) = @_;
	my $out = $code ? \*STDERR : \*STDOUT;
	print $out <<'USAGE';
Usage: perl scripts/sponsors_goal.pl [options]

Prints the monthly USD target for the GitHub Sponsors goal, converting the
CAD bills at the current reference rate and rounding up to the next $5.

  --tokens-usd-week N   AI token cost per week in USD          (default 80)
  --vps-cad N           VPS cost per month in CAD              (default 9)
  --phone-cad N         phone cost per month in CAD            (default 29.38)
  --rate N              CAD->USD rate; skips the network
  --rate-date TEXT      label for a rate given with --rate
  --round N             round the goal up to a multiple of N   (default 5)
  --rate-url URL        rate endpoint                          (default Frankfurter)
  --json                machine-readable output
  --help                this message

The GitHub Sponsors API has no mutation for the goal: set it by hand in the
dashboard and paste the printed description.
USAGE
	exit $code;
}
