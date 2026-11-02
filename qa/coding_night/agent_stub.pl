#!/usr/bin/perl

# qa/coding_night/agent_stub.pl - the hook with no model behind it.
#
# Point JAWNOS_CODING_AGENT at this file to test the whole pipeline end to end:
# the runner fetches, adds a worktree, calls this with the note in the
# environment, and this says "there is no coding model here" with exit 3. The
# runner then leaves the worktree, deletes the branch and leaves the note open,
# exactly as it would for any agent that failed.
#
# It never edits the tree, so a test can run the runner against a throwaway
# checkout without a model, a key or a network.

use strict;
use warnings;

my $id    = $ENV{'JAWNOS_NOTE_ID'}    // '';
my $title = $ENV{'JAWNOS_NOTE_TITLE'} // '';

print STDERR "agent_stub: no coding model is configured (note $id: $title)\n";
print STDERR "agent_stub: this stub always exits 3 so the pipeline can be tested\n";
exit 3;
