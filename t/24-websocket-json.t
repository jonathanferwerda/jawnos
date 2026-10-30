use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

# A websocket frame is the only way a browser tells the manager "I moved to
# 3:12", "I am still here" or "send this message". Every frame is parsed at the
# top of the /manager/ws message handler, and that parse must use Mojo::JSON's
# decode_json.
#
# It used to say `from_json`, which resolved to JSON::PP's deprecated stub:
#
#   JSON::PP::from_json has been renamed to decode_json
#
# The call sat inside an eval, so it did not fail loudly - it returned undef for
# EVERY frame. The handler then fell through every branch and dropped the frame.
# The visible damage was the music player forgetting where it was (its once-a-
# second save never landed), stale websocket session rows, and a mail socket
# that never answered. This pins the parser so a future "modernise" pass cannot
# quietly reintroduce it.

my $manager = read_file("$FindBin::Bin/../Manager.pl");

# 1. the import list must not name it: an imported from_json is how JSON::PP's
#    stub became reachable in the first place
my ($import) = $manager =~ /^use\s+Mojo::JSON\s+qw\((.*?)\)\s*;/m;
ok(defined $import, 'Manager.pl imports from Mojo::JSON explicitly');
unlike($import // '', qr/\bfrom_json\b/, 'the import list does not carry from_json');

# 2. and no call may use it anywhere in the manager
my @calls = ($manager =~ /(\bfrom_json\b)/g);
is(scalar @calls, 0, 'no from_json call remains in Manager.pl');

# 3. the frame parser itself is the one under test: the message handler's first
#    statement decodes the frame
my ($handler) = $manager =~ /\$c->on\(message\s*=>\s*sub\s*\(\$ws,\s*\$msg\)\s*\{\s*\n\s*my \$data = eval \{ return (\w+) \$msg \};/;
is($handler // '', 'decode_json', 'the websocket frame is parsed with decode_json');

# 4. guard the shape that made it silent: parsing must stay inside the eval, so
#    a malformed frame cannot take the connection down with it
like($manager, qr/my \$data = eval \{ return decode_json \$msg \};/,
	'a malformed frame is still caught by the eval');

done_testing();
