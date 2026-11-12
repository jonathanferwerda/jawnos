# tests-for: lib/JawnOS/Manager/Part25.pm templates/apps/pen.html.ep
# covers:    The Pen window's render data carries the device its panel reads, and
#            its conversation partial carries the chat_ui flag it requires.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

my $root = repo_root();
my $part = read_file("$root/lib/JawnOS/Manager/Part25.pm");
my $pen  = read_file("$root/templates/apps/pen.html.ep");

# Pen used to 500 on every open: the panel reads $device from the stash, which
# mail_checker never supplied, and the conversation partial requires chat_ui,
# which the pen include never passed. A missing key is a template compile
# error, not a blank value, so these two wirings are load-bearing.
like($pen,  qr/\$config->\{\$device\}/, 'the Pen panel reads the device from the stash');
like($part, qr/\bdevice\s*=>\s*\$device\b/, 'mail_checker hands the panel its device');
like($pen,  qr/include\s+'mail\/conversation'[^%]*\bchat_ui\s*=>\s*0/, 'the Pen conversation is included with chat_ui');

done_testing();
