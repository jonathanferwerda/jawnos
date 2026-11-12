# tests-for: lib/JawnOS/Controller/manager_misc5.pm
# covers:    The upload destination is created with the portable make_path, not an
#            external Unix mkdir, and a caller that names no timestamp writes now.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use RepoSource;

my $root = repo_root();
my $src = read_file("$root/lib/JawnOS/Controller/manager_misc5.pm");

# `system('mkdir', '-p', ...)` is a Unix tool; on Windows it answers "The syntax
# of the command is incorrect", the destination is never made, and move_to dies.
unlike($src, qr/system\s*\(\s*'mkdir'/, 'the upload action does not run an external mkdir');
like($src, qr/make_path\s*\(\s*\$location\s*\)/, 'the upload destination is made with make_path');
like($src, qr/make_path\s*\(\s*\$thumb\s*\)/, 'the thumbnail destination is made with make_path');
like($src, qr/\(\s*\$c->param\('timestamp'\)\s*\|\|\s*&subs::rightNow\(\)\s*\)\s*-\s*1/,
	'an upload with no timestamp is written now, not at 1970');

my $base = tempdir(CLEANUP => 1);
my $nested = "$base/one/two/three";
ok(make_path($nested), 'make_path creates nested directories');
ok(-d $nested, 'the nested upload directory exists');

done_testing();
