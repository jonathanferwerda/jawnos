# tests-for: scripts/backup_verify.pl
# covers:    the verification CLI's usage, its refusal of an unknown argument,
#            and the options the Enc panel and an operator rely on.

use strict;
use warnings;

use FindBin;
use Test::More;

my $script = "$FindBin::Bin/../scripts/backup_verify.pl";
ok(-x $script, 'the verification script is executable');

my $help = qx{$^X $script --help 2>&1};
is($? >> 8, 0, '--help exits 0');
like($help, qr/usage: backup_verify\.pl/, 'it prints its usage');
like($help, qr/--all/, 'it names --all');
like($help, qr/--file PATH/, 'it names --file');
like($help, qr/--json/, 'it names --json');

my $bad = qx{$^X $script --nonsense 2>&1};
is($? >> 8, 2, 'an unknown argument exits 2');
like($bad, qr/unknown argument/, 'and says which one');

done_testing();
