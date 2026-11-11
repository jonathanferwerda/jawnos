# tests-for: lib/JawnOS/Domain/Records.pm lib/JawnOS/Domain/Sync.pm lib/JawnOS/Domain/Loader.pm scripts/mail_orphan_cleanup.pl
# covers:    the init demo mailbox rows are tombstoned (so peers drop them too)
#           and removed locally; the SMS sync stores the sealed note, never the
#           phone's plain body, and skips a message it could not seal.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

subs::preload('mailbox_tombstone_orphans');

my $root = root();

package FakeRows;
sub new { return bless { hashes => $_[1] || [] }, $_[0] }
sub hashes { return $_[0]->{'hashes'} }

package main;

my $mf = 'jawn@init.note9 pro';
my @rows = (
	{ uuid => 'orphan-one', manager_file => $mf, app => undef },
	{ uuid => 'orphan-two', manager_file => $mf, app => undef },
);
my (@tombstones, @deletes);
{
	no warnings 'redefine';
	local *subs::db_query = sub { return FakeRows->new(\@rows) };
	local *subs::tombstone_writer = sub { push @tombstones, $_[0]; return 1 };
	local *subs::db_delete = sub { push @deletes, $_[1]; return 1 };

	my $dry = subs::mailbox_tombstone_orphans({ manager_file => $mf, apply => 0 });
	is($dry->{'rows'}, 2, 'the dry run counts both orphan rows');
	is($dry->{'applied'}, 0, 'and says it wrote nothing');
	is(scalar @tombstones, 0, 'no tombstone on a dry run');
	is(scalar @deletes, 0, 'no delete on a dry run');

	my $applied = subs::mailbox_tombstone_orphans({ manager_file => $mf, apply => 1 });
	is($applied->{'rows'}, 2, 'the apply run counts both rows');
	is($applied->{'applied'}, 1, 'and says it applied');
	is(scalar @tombstones, 2, 'one tombstone per row');
	is($tombstones[0]->{'table'}, 'mailbox', 'the tombstone names the mailbox table');
	is($tombstones[0]->{'app'}, $mf, 'and the manager_file it was filed under');
	is($tombstones[0]->{'uuid'}, 'orphan-one', 'with the row uuid');
	is($tombstones[0]->{'scope'}, 'single', 'as a single-row deletion');
	is(scalar @deletes, 2, 'one local delete per row');
	is($deletes[0]->{'uuid'}, 'orphan-one', 'the right row is removed');
}

# --- the SMS sync stores the sealed note ------------------------------------
my $sync = read_file("$root/lib/JawnOS/Domain/Sync.pm");
like($sync, qr/db_insert\('mailbox', \{[^}]*body => \$message,/s,
	'the SMS mailbox row carries the sealed note');
unlike($sync, qr/db_insert\('mailbox', \{[^}]*body => \$l->\{'body'\}/s,
	'not the phone\'s plain body in the stored row');
like($sync, qr/next unless defined \$message && length \$message/,
	'a body that could not be sealed is not written raw');

# --- the sweep is reachable by name and the script runs it -------------------
like(read_file("$root/lib/JawnOS/Domain/Loader.pm"), qr/records_mailbox_tombstone mailbox_tombstone_orphans/,
	'the domain map carries the orphan cleanup');
like(read_file("$root/scripts/mail_orphan_cleanup.pl"), qr/subs::mailbox_tombstone_orphans\(\{ manager_file => \$manager_file, apply => \$apply \}\)/,
	'the script passes its manager_file and apply flag');

done_testing();
