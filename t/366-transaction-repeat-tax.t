# tests-for: public/js/manager/transaction.js public/js/manager/transaction/01_record_crypto.js templates/apps/transaction/expense.html.ep perl/help/topics_functions.pl
# covers:    Repeat last keeps the tax and total it restored (the vendor trigger
#            no longer falls into the line-math catch-all), restores the
#            Price-includes-tax button, and settles a stale inclusive flag from
#            the saved figures; a new expense line is tax-exclusive, and the
#            toggle writes the has_tax/has_totes setting the form reads back

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);

my $root = "$FindBin::Bin/..";
my $js     = read_file("$root/public/js/manager/transaction.js");
my $part   = read_file("$root/public/js/manager/transaction/01_record_crypto.js");
my $expense = read_file("$root/templates/apps/transaction/expense.html.ep");
my $income  = read_file("$root/templates/apps/transaction/income.html.ep");
my $help    = read_file("$root/perl/help/topics_functions.pl");

# --- a vendor change no longer rewrites the retrieved line ------------------
like($js, qr/Only a field that moves a figure recalculates the line/,
	'the line math names the fields that own it');
like($js, qr/if \(!e\.hasClass\('amount'\) && !e\.hasClass\('tax'\) && !e\.hasClass\('aux'\)/,
	'a vendor (or item, unit, state) change returns before the math');
like($js, qr/&& !e\.hasClass\('total'\) && !e\.hasClass\('quantity'\)\s*\n\s*&& !e\.hasClass\('taxes'\) && !e\.hasClass\('tax_exemption'\)\) \{\s*\n\s*return;/,
	'while the money and quantity fields still recalculate');

# --- the retriever restores the button from `enabled`, not `value` ----------
like($js, qr/input\.is\('button\.purchase_config'\)/, 'the retriever recognises a config button');
like($js, qr/purchaseConfigPaint\(input, vr == 'on'\);/, 'and paints its enabled state');
like($js, qr/function purchaseConfigPaint/, 'one painter is shared with the click handler');
like($js, qr/purchaseConfigPaint\(block\.find\('\.purchase_config\[config="tax"\]'\), inclusive\)/,
	'the retriever settles the tax toggle from the saved figures');
like($js, qr/function transactionTaxInclusiveFromFields/,
	'a saved line can say which way its amount reads');

# --- the click handler persists the setting the template reads -------------
ok(index($part, "con.attr('attribute') || config") >= 0,
	'the toggle writes has_tax/has_totes, not the selector name');

# --- a new expense is exclusive, like income -------------------------------
like($expense, qr/attribute="has_tax"[^\n]*eq 'on'/,
	'a new expense line is tax-exclusive');
unlike($expense, qr/attribute="has_tax"[^\n]*ne 'off'/,
	'and no longer defaults to price-includes-tax');
like($income, qr/attribute="has_tax"[^\n]*eq 'on'/, 'income stays tax-exclusive');
like($help, qr/It is off on a new line, so picking a tax adds it to the total/,
	'the guide says a picked tax adds to the total');

# --- the figures settle the toggle, played out in node ---------------------
my ($fn) = $js =~ /(function transactionTaxInclusiveFromFields\(line\) \{.*?\n\})/s;
ok($fn, 'the inclusive reader is one function');
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is needed to read the figures', 4 unless $fn && $node && -x $node;
	my $harness = <<'JS';
function numeral(v) { return { value: function () { return Number(v) || 0; } }; }
function line(fields) {
	return { find: function (sel) {
		var key = (sel.match(/attribute="([^"]+)"/) || [])[1];
		return { val: function () { return fields[key]; } };
	} };
}
__FN__
var cases = [
	{ name: 'exclusive', amount: '-26.00', tax: '-3.38', total: '-29.38', want: 'false' },
	{ name: 'inclusive', amount: '118.00', tax: '18.00', total: '118.00', want: 'true' },
	{ name: 'no_tax', amount: '100.00', tax: '0.00', total: '100.00', want: 'null' },
	{ name: 'inconsistent', amount: '100.00', tax: '13.00', total: '120.00', want: 'null' }
];
cases.forEach(function (c) {
	console.log(c.name + '=' + String(transactionTaxInclusiveFromFields(line(c))));
});
JS
	$harness =~ s/__FN__/$fn/;
	my $dir = tempdir(CLEANUP => 1);
	write_file("$dir/harness.js", $harness);
	my %got = map { /^(\w+)=(\w+)$/ ? ($1 => $2) : () } `$node $dir/harness.js 2>&1`;
	is($got{'exclusive'}, 'false', 'amount + tax = total reads as net');
	is($got{'inclusive'}, 'true', 'amount = total reads as gross');
	is($got{'no_tax'}, 'null', 'a line with no tax cannot say');
	is($got{'inconsistent'}, 'null', 'figures that agree with neither flag cannot say');
}

done_testing();
