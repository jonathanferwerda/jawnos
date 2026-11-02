# tests-for: lib/JawnOS/Domain/Migrations.pm perl/Music.pl
# covers:    update_database is called with a hash that has no `duty` (the
#            boot hook, and several request paths that pass a controller). The
#            old bare eq warned on every call; a warning storm filled the
#            launcher's pty and blocked every worker. The music library check
#            guards its own possibly-missing setting the same way.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

subs::preload('update_database');

my @warned;
{
	local $SIG{__WARN__} = sub { push @warned, @_ };
	eval { &subs::update_database({}) };
}
my @uninit = grep { /uninitialized value in string eq/ } @warned;
is_deeply(\@uninit, [], 'update_database({}) does not warn about an undefined duty');

my $music = read_file("$FindBin::Bin/../perl/Music.pl");
like($music, qr/\(\$settings->\{'library'\} \|\| ''\) ne 'local'/,
	'the music library check guards a missing setting');

done_testing();
