# tests-for: lib/JawnOS/Manager/Part17.pm
# covers:    A peer file that cannot be fetched during a sync merge (a big
#            gallery page, a peer worker that closes early) must not kill the
#            whole merge; the row is kept and its file is left for a later pass.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

my $src = read_file(root() . '/lib/JawnOS/Manager/Part17.pm');

ok( index($src, 'my $file_data = eval {') >= 0,
	'the peer file fetch runs inside an eval' );
ok( index($src, '$file_data && $file_data->is_success') >= 0,
	'a failed response is skipped' );
ok( index($src, "\$file_data->body ne 'not found'") >= 0,
	'an empty answer is still skipped' );
ok( index($src, 'eval { write_file($dest,$fd) }') >= 0,
	'a file that cannot be written is skipped, the row is kept' );
ok( index($src, 'my $file_data = $configuration->{\'remote\'}->{\'ua\'}->get($url)->result;') < 0,
	'the unguarded fetch is gone' );

done_testing();
