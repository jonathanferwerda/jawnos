# tests-for: public/js/manager/transaction.js public/js/manager/transaction/ lib/JawnOS/Controller/manager_market.pm perl/help/topics_functions.pl
# covers:    An expense filled from a receipt was stored positive. Accounting reads a positive expense as a refund, so the money left the account backwards. The form now writes an expense negative unless Refund marks the line.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $js = js_source('public/js/manager/transaction.js');
my $market = read_file("$root/lib/JawnOS/Controller/manager_market.pm");
my $help = help_source();

# --- the form owns the sign: an expense is money out -----------------------
like($js, qr/\.purchase_details \.amount, \.purchase_details \.tax, \.purchase_details \.aux, \.purchase_details \.total/,
	'one handler watches the money fields');
like($js, qr/if \(ad\.find\('\.movement'\)\.val\(\) != 'expense'\) \{ return; \}/,
	'it acts only on an expense line');
like($js, qr/if \(line\.attr\('refund'\) == 'on'\) \{ return; \}/,
	'a refund is the exception and is left alone');
like($js, qr/if \(value > 0\) \{ input\.val\(numeral\(-value\)\.format\('0\.00'\)\); \}/,
	'a positive figure typed into an expense is stored negative');
like($js, qr/block\.attr\('refund', numeral\(block\.find\('\.total'\)\.val\(\)\)\.value\(\) > 0 \? 'on' : 'off'\);/,
	'a line brought back from history carries the mark its stored sign implies');
like($js, qr/iq\.attr\('refund', numeral\(iq\.find\('\.total'\)\.val\(\)\)\.value\(\) > 0 \? 'on' : 'off'\);/,
	'the Refund button sets the mark from the sign it just wrote');

# --- checkout hands over the same signed figure ----------------------------
like($market, qr/my \$sign = -1;/, 'checkout names the expense sign');
like($market, qr/amount => \$price \* \$sign,/, 'each line amount is signed');
like($market, qr/total => \$price \* \$sign,/, 'each line total is signed');
like($market, qr/amount => \$total \* \$sign, tax => 0, aux => 0, total => \$total \* \$sign/,
	'the line totals are signed');
like($market, qr/total => \$total \* \$sign, storage => \$storage/,
	'the returned transaction total is signed too');

# --- and the guide says it in the on-screen words --------------------------
like($help, qr/saved with a negative sign: a receipt total typed as 151\.37 is recorded as -151\.37/,
	'the transactions topic says an expense is negative');
like($help, qr/Refund, under More details, flips that line back to positive/,
	'and points at Refund for the exception');

done_testing();
