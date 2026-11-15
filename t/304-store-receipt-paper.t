# tests-for: lib/JawnOS/Manager/Part08.pm templates/configure/store_setting_list.html.ep perl/help/topics_business.pl
# covers:    the Store's receipt-paper switch: on unless turned off, asked
#           before a payment's papers are drawn, rendered as the same checkbox
#           as the invoice paper in Configure - Store, and named in the help.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

require './lib/JawnOS/Manager/Part08.pm';

sub source { return read_file(root() . '/' . $_[0]) }

# --- the switch is on unless the house turns it off --------------------------
{
	local *subs::setting_grabber = sub { undef };
	is(&Manager::store_receipt_paper_enabled(), 1,
		'an unset switch keeps the receipt paper');
}
{
	local *subs::setting_grabber = sub { 'off' };
	is(&Manager::store_receipt_paper_enabled(), 0,
		'off turns the receipt paper off');
}
{
	local *subs::setting_grabber = sub { '' };
	is(&Manager::store_receipt_paper_enabled(), 1,
		'a blank value is the default, not off');
}
{
	local *subs::setting_grabber = sub { 'on' };
	is(&Manager::store_receipt_paper_enabled(), 1,
		'any other value keeps it on');
}

# --- the switch is asked before a payment's papers are rendered --------------
my $part = source('lib/JawnOS/Manager/Part08.pm');
like($part, qr/invoice_paper receipt_paper payment_paper_app receipt_message/,
	'the Store settings list carries receipt_paper');
like($part, qr/setting => 'receipt_paper'/,
	'and the switch reads its own setting, not invoice_paper');

my ($receipt) = $part =~ /(sub store_payment_receipt\(\$data\) \{.*?\n\}\n)/s;
ok(defined $receipt, 'store_payment_receipt is present');
my $insert = index($receipt, "db_insert('appointments'");
my $gate = index($receipt, 'store_receipt_paper_enabled');
my $render = index($receipt, 'my $render = sub');
cmp_ok($insert, '>=', 0, 'the receipt row is written');
cmp_ok($gate, '>=', 0, 'the paper asks the switch');
cmp_ok($render, '>=', 0, 'the render is still there');
cmp_ok($insert, '<', $gate, 'the row is the record, written before the switch');
cmp_ok($gate, '<', $render, 'and the switch is read before any render starts');
like($receipt, qr/return \$receipt_uuid unless &store_receipt_paper_enabled\(\)/,
	'off keeps the receipt uuid and starts no render');

# --- Configure - Store draws it as the invoice paper's checkbox --------------
my $cfg = source('templates/configure/store_setting_list.html.ep');
like($cfg, qr/\$m eq 'receipt_paper'/,
	'Configure - Store knows receipt_paper');
like($cfg, qr/\$m eq 'invoice_paper' \|\| \$m eq 'receipt_paper'/,
	'and draws it with the invoice paper checkbox');

# --- the help names the switch in the on-screen words ------------------------
my $help = source('perl/help/topics_business.pl');
like($help, qr/Receipts have their own switch there, on by default/,
	'the Store help names the receipt paper switch');

done_testing();
