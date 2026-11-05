# tests-for: lib/JawnOS/Manager/Part14.pm
# covers:    a resumed session's children are reopened completely, not left as type=start with stop_seen set

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A resume reopens the session a stop closed. The parent is reopened with
# stop_seen and stop_timestamp cleared; its model/option children must be too.
# Flipping only type to 'start' left a child reading as running (type=start) yet
# closed (stop_seen=yes, old stop_timestamp), which is the half-reopened state
# Renew produced on BzTWNDws's radio/cbc_radio/programming/vibe_coding rows.

my $root   = repo_root();
my $part14 = read_file("$root/lib/JawnOS/Manager/Part14.pm");

# manager_reset's renew branch closes its elsif at column 0, so a regex that
# stops at the first \n}\n truncates the sub before resume. Read the branch
# straight out of the file instead.
my ($resume_branch) = $part14 =~ /(\telsif \(\$type eq 'resume'\) \{.*?\n\t\}\n\telsif \(\$type eq 'add'\) \{)/s;
ok($resume_branch, 'the resume branch is one block');

like($resume_branch, qr/stop_seen => undef/,
	'the resumed parent clears its own stop flag');

like($resume_branch, qr/&subs::db_update\('appointments', \{ type => 'start', stop_seen => undef, stop_timestamp => undef, server_time => \$server_time \}, \{ source_uuid => \$so->\{'source_uuid'\}, uuid => \$so->\{'uuid'\}, app => \$so->\{'app'\} \}\);/,
	'the resumed children clear stop_seen and stop_timestamp too');

unlike($resume_branch, qr/&subs::db_update\('appointments', \{ type => 'start', server_time => \$server_time \}, \{ source_uuid => \$so->\{'source_uuid'\}/,
	'no child is reopened by type alone');

done_testing();
