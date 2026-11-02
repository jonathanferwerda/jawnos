use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The boot self-update (scripts/jawnos_update.pl) is how a machine that was
# installed from an image follows origin/main without a person. Two bugs made it
# fail every time, and both were invisible on a developer box because the tree
# there is updated by hand:
#
#   1. it syntax-checked 'Manager.pl' while capture_in_repo had already cd'd to
#      the repo root, where the launcher is 'perl/Manager.pl'. Every run
#      fast-forwarded, failed the check and rolled back.
#   2. it compared &git(...) to 0 in scalar context, where git() returns its
#      *output* (the last list element), not the exit code - so the
#      --is-ancestor test always looked true.
#
# This file pins both, and proves the launcher compiles from where the updater
# actually stands.

my $root = repo_root();
my $src  = read_file("$root/scripts/jawnos_update.pl");

like( $src, qr/'perl',\s*'-c',\s*'perl\/Manager\.pl'/,
	'the compile check names the launcher with its directory' );
unlike( $src, qr/'perl',\s*'-c',\s*'Manager\.pl'/,
	'and never the bare launcher name capture_in_repo cannot find' );

unlike( $src, qr/if\s*\(\s*&git\([^\n]*\)\s*==\s*0\s*\)/,
	'no git() exit status is read in scalar context' );
unlike( $src, qr/if\s*&git\([^\n]*\)\s*==\s*0\s*;/,
	'no git() exit status is read in scalar context (postfix form)' );

# The updater's own proof, run from the same directory it uses.
my $out = `cd '$root' && perl -c perl/Manager.pl 2>&1`;
is( $?, 0, 'the launcher compiles from the repo root' ) or diag($out);

done_testing();
