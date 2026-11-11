# tests-for: lib/JawnOS/Controller/manager_transaction.pm lib/JawnOS/Controller/store_misc.pm lib/JawnOS/Domain/Pay.pm lib/JawnOS/Controller/manager_configure2.pm
# covers:    The seventh pass, data scope: a column name is checked before it
#           becomes SQL, a quote is read or changed only by its customer or the
#           house, a payment token that matches nothing scopes nothing, and a
#           join code cannot be moved to another machine.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

sub source { return read_file(root() . '/' . $_[0]) }

# --- the autofill name is a column, not SQL ---------------------------------
my $tx = source('lib/JawnOS/Controller/manager_transaction.pm');
like($tx, qr/pragma_table_info\(\?\).*'appointments', \$name/,
	'autofill checks the name against the appointments columns');
like($tx, qr/unless \(\$is_column\) \{/,
	'and refuses a name that is not a column');

# --- a quote belongs to a customer or to the house ---------------------------
my $store = source('lib/JawnOS/Controller/store_misc.pm');
like($store, qr/my \$query = \{ uuid => \$uuid \};/,
	'quote/load starts from the uuid');
like($store, qr/\$query->\{'app'\} = \$customer->\{'app'\};/,
	'and narrows to the token customer app');
like($store, qr/return \$c->render\(json => \{\}\);/,
	'and answers nothing for a uuid with no customer and no house');
my ($delete_block) = $store =~ /(# POST \/store\/quote\/delete\b.*?)(?=\n# (?:GET|POST) )/s;
like($delete_block, qr/guest_browser_session/,
	'quote/delete refuses a guest browser');
my ($move_block) = $store =~ /(# POST \/store\/quote\/move\b.*?)(?=\n# (?:GET|POST) )/s;
like($move_block, qr/guest_browser_session/,
	'quote/move refuses a guest browser');
like($store, qr/my \$customer_app = &subs::printer_customer_app\(/,
	'print derives the customer app from the document');
like($store, qr/&& !&subs::guest_browser_session/,
	'and only a house session may override it');

# --- an unknown customer token scopes nothing -------------------------------
my $now = &subs::rightNow();
&subs::db_insert('appointments', {
	uuid => 'inv-scope-1', app => 'CxScope', type => 'invoice',
	data => '{"numbers":{"total":10,"balance":10}}',
	server_time => $now, timestamp => $now,
});
&subs::db_insert('appointments', {
	uuid => 'inv-scope-2', app => 'CxOther', type => 'invoice',
	data => '{"numbers":{"total":20,"balance":20}}',
	server_time => $now, timestamp => $now,
});
&subs::db_insert('settings', {
	app => 'CxScope', setting => 'uuid', value => 'cx-scope-1',
	server_time => $now, timestamp => $now,
});
my ($found_inv) = &subs::pay_invoice_lookup('inv-scope-1', '');
ok($found_inv, 'a link with no token still finds its invoice');
my @wrong = &subs::pay_invoice_lookup('inv-scope-1', 'cx-does-not-exist');
is(scalar @wrong, 0, 'a token that matches nothing scopes nothing');
my ($scoped_inv) = &subs::pay_invoice_lookup('inv-scope-1', 'cx-scope-1');
ok($scoped_inv, 'the matching customer token finds its own invoice');
my @crossed = &subs::pay_invoice_lookup('inv-scope-2', 'cx-scope-1');
is(scalar @crossed, 0, 'and cannot reach another customer invoice');

# --- a pending join code cannot be moved to another machine -----------------
my $conf = source('lib/JawnOS/Controller/manager_configure2.pm');
like($conf, qr/'join_request_rate'/, 'the forward rail has a per-address budget');
like($conf, qr/my \$same_machine = \(\$old_sig ne '' \|\| \$old_key ne ''\)/,
	'and only the identity that made a code may replace it');
like($conf, qr/that code is already pending/,
	'and a stranger is refused');

done_testing();
