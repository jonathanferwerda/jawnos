# tests-for: lib/JawnOS/Domain/Render.pm perl/President.pl
# covers:    the runner can tell which slots in a runtime table have no callable attached, so a
#           controller call that never reached the definer is healed (and named) instead of silently
#           skipping every job

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

my $root = root();
require "$root/lib/JawnOS/Domain/Render.pm";

my $attached = sub { 1 };
my $row = {
	'remote_machine_sync' => { toggle => 'on', subroutine => $attached },
	'backups'             => { toggle => 'on' },
	'sync_kick'           => { toggle => 'on', subroutine => $attached },
	'__settings'          => { last_change => 1 },
	'__batch_groups'      => {},
};

is_deeply(&subs::utility_bare_jobs($row), ['backups'], 'only the slot without a callable is reported');
is_deeply(&subs::utility_bare_jobs({ a => { subroutine => $attached } }), [], 'a fully attached table is clear');
is_deeply(&subs::utility_bare_jobs(undef), [], 'no table is not an error');
is_deeply(&subs::utility_bare_jobs({ x => 'scalar' }), [], 'a non-hash slot is not a job');

done_testing();
