# tests-for: lib/JawnOS/Domain/Pay2.pm
# covers:    An e-Transfer letter names the invoice it pays. House invoice
#           numbers start at 1001, so the reference reader must accept a
#           four-character number, while the label is still what keeps a year or
#           an amount from being read as one.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

my $sent = 'INTERAC e-Transfer: Ada Example has sent you $25.00 (CAD).';
my $short = &subs::pay_interac_parse($sent, 'Reference Number: 1001');
is($short->{'reference'}, '1001', 'a four-digit invoice number is a reference');

my $plain = &subs::pay_interac_parse($sent, 'Reference: 1001');
is($plain->{'reference'}, '1001', 'the short Reference label works too');

my $fr = &subs::pay_interac_parse($sent, 'Numero de reference : 1001');
is($fr->{'reference'}, '1001', 'the French label works too');

my $old = &subs::pay_interac_parse($sent, 'Reference Number: 100123');
is($old->{'reference'}, '100123', 'a longer reference still reads whole');

my $too_short = &subs::pay_interac_parse($sent, 'Reference Number: 123');
is($too_short->{'reference'}, '', 'three characters is not a reference');

my $amount = &subs::pay_interac_parse($sent, 'Amount: $1001.00');
is($amount->{'reference'}, '', 'an amount without the label is not a reference');

done_testing();
