# tests-for: lib/JawnOS/Domain/Render.pm
# covers:    a signatorial call with no context does not print an uninitialized-value warning on
#            every render (that warning filled a small terminal and blocked the workers).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

subs::preload('signatorial_establisher random_string_creator');

my @warnings;
{
	local $SIG{__WARN__} = sub { push @warnings, @_ };
	local $subs::config = {};
	my $secret = &subs::signatorial_establisher();
	like($secret, qr/^.{12}$/, 'a house with no signatorial image gets a 12-character fallback');
}
is(scalar @warnings, 0, 'no uninitialized-value warning is printed')
	or diag(@warnings);

done_testing();
