# tests-for: lib/JawnOS/Manager/Part14.pm
# covers:    a resumed session's children are reopened completely, not left as type=start with stop_seen set; a resume only considers sessions that had started by the press

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

# --- a resume is bounded by the press ---------------------------------------
# The selection is the newest stop/cancel by its START timestamp, but only a
# session that had already started at the press can be the one this press is
# reopening. Both the pre-relay resolution (whose uuid travels to every peer)
# and the older fallback apply the bound; a press that carries no timestamp
# means now.

my ($resolve_block) = $part14 =~ /(if \(\$type eq 'resume' && !\$target_uuid\) \{.*?&remote_relay_request)/s;
ok($resolve_block, 'manager_reset resolves a resume before the relay');
like($resolve_block, qr/my \$resume_at = \$timestamp \|\| &subs::rightNow\(\);/,
	'a resume with no timestamp treats the press as now');
like($resolve_block, qr/and timestamp <= \? order by timestamp DESC LIMIT 1/,
	'the pre-relay resolution takes the newest start at or before the press');

like($resume_branch, qr/and timestamp <= \? order by timestamp DESC LIMIT 1/,
	'the resume branch fallback applies the same bound');

done_testing();
