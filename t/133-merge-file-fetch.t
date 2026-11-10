# tests-for: lib/JawnOS/Manager/Part17.pm
# covers:    A peer file that cannot be fetched during a sync merge (a big
#            gallery page, a peer worker that closes early) must not kill the
#            whole merge; the row is kept and its file is left for a later pass.
#            /file_open answers a refusal with the words "no", "none" or "not
#            found"; decoding one as base64 wrote the one- and three-byte stubs
#            that blank a main_image, so the body now goes through
#            synced_file_payload (t/239 covers its rules).

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
ok( index($src, '&subs::synced_file_payload($file_data->body, $dest)') >= 0,
	'the body goes through the sentinel-aware payload check' );
ok( index($src, 'decode_base64 $fd') < 0,
	'no unchecked base64 decode remains to turn "no" into a stub' );
ok( index($src, 'eval { write_file($dest,$fd) }') >= 0,
	'a file that cannot be written is skipped, the row is kept' );
ok( index($src, 'my $file_data = $configuration->{\'remote\'}->{\'ua\'}->get($url)->result;') < 0,
	'the unguarded fetch is gone' );

done_testing();
