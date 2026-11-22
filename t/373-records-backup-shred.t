# tests-for: lib/JawnOS/Domain/Records.pm
# covers: a backup's plaintext temp is removed even when shred is missing (a
#         Termux image without the coreutils applet), while shred still runs
#         when the tool is present.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $src = read_file("$root/lib/JawnOS/Domain/Records.pm");
my ($block) = $src =~ /(sub records_backup_now\s*\{.*?^\})/ms;
ok(defined $block && length $block, 'records_backup_now is present');
like($block, qr/system\('shred',\s*'-u',\s*\$tmp\)/s, 'shred still runs when the tool is present');
like($block, qr/unlink \$tmp if -e \$tmp/s, 'the plaintext temp is unlinked when shred is not');

done_testing();
