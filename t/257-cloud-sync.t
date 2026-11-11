# tests-for: lib/JawnOS/Domain/Archive.pm lib/JawnOS/Controller/manager_folders2.pm lib/JawnOS/Routes/manager_folders2.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Key.pm perl/jobs.pl perl/help/topics_apps.pl templates/folders/context.html.ep templates/folders/folders.html.ep templates/folders/cloud_sync.html.ep templates/folders/cloud_list.html.ep public/js/manager/folders.js public/js/manager/folders/
# covers:    CloudSync: a bidirectional folder mesh with time-ordered conflicts, tombstones and conflict copies.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use Mojo::JSON qw(encode_json);
use RepoSource;
use JawnOSTest;

# CloudSync is the archive rail turned into a small mesh: every member watches
# its own copy and pushes changes. These tests pin the pure rules - path
# containment, the conflict choice, the pending queue - and the wiring that
# makes every member take part. No real folder or peer is touched.

my $root = repo_root();
my $test_home = tempdir(CLEANUP => 1);
$ENV{'HOME'} = $test_home;
my $house_sync = "$test_home/house-sync";
# run_tests may have asked for home() before this file set HOME, so point the
# cached root at the test home: the destination policy is checked with it.
$subs::home_dir = $test_home;

# This machine's view is a cache row. The sandbox database is a copy of the
# machine's, so start from no row at all: the migration below is only exercised
# when there is nothing to read.
subs::cache_delete({ app => 'folders', context => 'cloud_sync' });
subs::cache_delete({ app => 'folders', context => 'cloud_sync_state' });

# ---- a destination cannot climb out of its base -----------------------------

my $dest = subs::cloud_sync_destination({ base => 'house-sync', path => 'photos/autumn/a.jpg' });
is($dest->{'root'}, $house_sync, 'the home-relative base is the destination root');
is($dest->{'relative'}, 'photos/autumn/a.jpg', 'the path inside the base is kept');
is($dest->{'path'}, "$house_sync/photos/autumn/a.jpg", 'the file lands under the base');
is($dest->{'parent'}, "$house_sync/photos/autumn", 'and its parent is the folder it sits in');

my $climb = subs::cloud_sync_destination({ base => 'house-sync', path => '../../etc/passwd' });
is($climb->{'relative'}, 'etc/passwd', 'a path that tries to climb is resolved against the base');
is($climb->{'path'}, "$house_sync/etc/passwd", 'and still lands inside the base');

# ---- CloudSync is home-only -------------------------------------------------

is(subs::cloud_sync_base_for($house_sync), 'house-sync', 'a folder under home has a home-relative base');
is(subs::cloud_sync_base_for('/etc'), '', 'a folder outside home has no shared base');
is(subs::cloud_sync_base_for($test_home), '', 'home itself is not a CloudSync folder');

my $absolute = subs::cloud_sync_destination({ base => $house_sync, path => 'a.txt' });
ok($absolute->{'error'}, 'an absolute base is refused');
my $escape = subs::cloud_sync_destination({ base => '../../etc', path => 'passwd' });
ok($escape->{'error'}, 'a base that climbs out of home is refused');
my $sdcard = subs::cloud_sync_destination({ base => '/sdcard/Pictures', path => 'a.jpg' });
ok($sdcard->{'error'}, 'the old /sdcard allowance is gone for CloudSync');

# ---- the newer time wins, and a tie is settled by content -------------------

is(subs::cloud_sync_conflict_choice(100, 200, 'aaaa', 'bbbb'), 'incoming', 'a newer incoming copy wins');
is(subs::cloud_sync_conflict_choice(200, 100, 'aaaa', 'bbbb'), 'local', 'a newer local copy wins');
is(subs::cloud_sync_conflict_choice(100, 100, 'abcd', 'abcd'), 'same', 'equal bytes at an equal time are the same file');
is(subs::cloud_sync_conflict_choice(100, 100, 'aaaa', 'bbbb'), 'incoming', 'an equal time is decided by the higher hash');
is(subs::cloud_sync_conflict_choice(100, 100, 'bbbb', 'aaaa'), 'local', 'and both devices choose the same winner');
is(subs::cloud_sync_conflict_choice(100, 100, undef, 'bbbb'), 'incoming', 'an unknown local hash lets the incoming copy win');

# ---- the pending queue keeps one change per path ----------------------------

my $state = subs::cloud_sync_state_empty();
my $first = subs::cloud_sync_pending_add($state, { kind => 'file', rel => 'a.txt', size => 1, mtime => 10 });
is(scalar @{ $state->{'pending'} }, 1, 'a change is queued');
ok($first->{'id'}, 'with an id so a job can remove exactly it');
my $second = subs::cloud_sync_pending_add($state, { kind => 'delete', rel => 'a.txt', deleted_at => 20 });
is(scalar @{ $state->{'pending'} }, 1, 'a later change for the same path replaces the earlier one');
is($state->{'pending'}->[0]->{'kind'}, 'delete', 'and is the one that will be sent');
isnt($first->{'id'}, $second->{'id'}, 'the replacement has its own id');
subs::cloud_sync_pending_clear($state, 'a.txt');
is(scalar @{ $state->{'pending'} }, 0, 'a path can be cleared when a peer settles it');
subs::cloud_sync_pending_add($state, { kind => 'file', rel => 'b.txt', size => 2, mtime => 30 });
subs::cloud_sync_pending_add($state, { kind => 'file', rel => 'c.txt', size => 3, mtime => 40 });
my @ids = map { $_->{'id'} } @{ $state->{'pending'} };
subs::cloud_sync_pending_remove($state, [ $ids[0] ]);
is(scalar @{ $state->{'pending'} }, 1, 'removing one delivered change keeps the rest');
is($state->{'pending'}->[0]->{'rel'}, 'c.txt', 'and keeps the right one');

# ---- a losing copy gets a stable conflict name ------------------------------

my $conflict = subs::cloud_sync_conflict_path({ root => $house_sync, path => "$house_sync/a.txt" }, 'abcdef1234567890');
is($conflict->{'relative'}, 'a.txt.conflict-abcdef12', 'the loser is named by its content hash');
is($conflict->{'path'}, "$house_sync/a.txt.conflict-abcdef12", 'beside the file it lost to');

# ---- a partial remembers which device owns it -------------------------------

my $partial_dir = tempdir(DIR => $test_home, CLEANUP => 1);
my $owned = "$partial_dir/owned.bin";
write_file(subs::archive_partial_path($owned), 'abc');
subs::archive_partial_meta_write($owned, {
	source => 'owned.bin',
	sender => 'device-signature',
	total => 3,
	mtime => 1,
	started => subs::rightNow(),
});
my $owned_state = subs::archive_partial_state({ path => $owned });
is($owned_state->{'sender'}, 'device-signature', 'a partial records the sender that owns it');
ok($owned_state->{'started'} > 0, 'and when it started, so a stale one can be taken over');

# ---- the room question answers in bytes -------------------------------------

my $tmp = tempdir(DIR => $test_home, CLEANUP => 1);
make_path("$tmp/root/sub");
write_file("$tmp/root/keep.bin", 'keep');
my $space = subs::cloud_sync_free_space($tmp);
is($space->{'status'}, 'ok', 'free space is read from the volume');
ok($space->{'free_bytes'} > 0, 'and is a positive byte count');
ok($space->{'total_bytes'} >= $space->{'free_bytes'}, 'the total is at least the free part');

# ---- the state machine sees, settles and forgets -----------------------------
#
# These use a real temp folder as the synced base and the temp HOME set above,
# so the per-base state in the cache table is exercised without touching the
# person's own state.

my $sync = tempdir(DIR => $test_home, CLEANUP => 1);
my $sync_base = substr($sync, length($test_home) + 1);
write_file("$sync/one.txt", 'one');
my $collected = subs::cloud_sync_collect_changes($sync, $sync_base);
is(scalar @{$collected}, 1, 'a new file becomes one pending change');
is($collected->[0]->{'kind'}, 'file', 'it is a file change');
is($collected->[0]->{'rel'}, 'one.txt', 'named by its relative path');
my $saved_state = subs::cloud_sync_state_read($sync_base);
ok($saved_state->{'files'}->{'one.txt'}, 'the state records what it last agreed');
ok(subs::cache_get({ app => 'folders', context => 'cloud_sync_state', subcontext => sha256_hex($sync_base) }),
	'and the state is stored in the cache table');
ok(!-e $subs::home_dir . '/.president/cloud_sync/' . sha256_hex($sync_base) . '.json',
	'not in the old per-base state file');
subs::cloud_sync_state_modify($sync_base, sub { my $st = shift; $st->{'pending'} = []; return 1 });
is(scalar @{ subs::cloud_sync_collect_changes($sync, $sync_base) }, 0,
	'an unchanged file is not queued again after its change was delivered');

sleep 1;
write_file("$sync/one.txt", 'one changed');
my $edited = subs::cloud_sync_collect_changes($sync, $sync_base);
is(scalar @{$edited}, 1, 'an edit is queued');
is($edited->[0]->{'kind'}, 'file', 'as a file change');
subs::cloud_sync_state_modify($sync_base, sub { my $st = shift; $st->{'pending'} = []; return 1 });
unlink "$sync/one.txt";
my $gone = subs::cloud_sync_collect_changes($sync, $sync_base);
is(scalar @{$gone}, 1, 'a deletion is queued');
is($gone->[0]->{'kind'}, 'delete', 'as a delete change');
ok($gone->[0]->{'deleted_at'}, 'with the time it was noticed');
my $after_delete = subs::cloud_sync_state_read($sync_base);
ok($after_delete->{'deleted'}->{'one.txt'}, 'and a tombstone in the state');
ok(!$after_delete->{'files'}->{'one.txt'}, 'the file entry is gone');

# A receive whose copy is newer takes the name and keeps the local copy as a
# conflict file; one whose copy is older leaves the local copy in place.
my $incoming_dir = tempdir(DIR => $test_home, CLEANUP => 1);
my $incoming_base = substr($incoming_dir, length($test_home) + 1);
write_file("$incoming_dir/one.txt", 'local bytes');
utime 3000, 3000, "$incoming_dir/one.txt";
my $dest_file = subs::cloud_sync_destination({ base => $incoming_base, path => 'one.txt' });
my $part = "$incoming_dir/one.txt.part";
write_file($part, 'incoming bytes');
my $incoming_hash = subs::archive_file_digest($part);
my $newer = subs::cloud_sync_finalize_upload({
	base => $incoming_base,
	dest => $dest_file,
	part => $part,
	mtime => 4000,
	hash => $incoming_hash,
});
is($newer->{'accepted'}, 1, 'a newer incoming copy is accepted');
is(read_file("$incoming_dir/one.txt"), 'incoming bytes', 'and takes the original name');
is((stat("$incoming_dir/one.txt"))[9], 4000, 'with the incoming time');
ok($newer->{'saved'}, 'the older local copy is kept');
ok(-e "$incoming_dir/$newer->{'saved'}", 'as a conflict file beside it');

write_file("$incoming_dir/one.txt", 'newer local bytes');
utime 5000, 5000, "$incoming_dir/one.txt";
write_file($part, 'older incoming bytes');
my $older_hash = subs::archive_file_digest($part);
my $older = subs::cloud_sync_finalize_upload({
	base => $incoming_base,
	dest => $dest_file,
	part => $part,
	mtime => 4500,
	hash => $older_hash,
});
is($older->{'accepted'}, 0, 'an older incoming copy is refused');
is($older->{'kept'}, 'local', 'the local copy wins');
is(read_file("$incoming_dir/one.txt"), 'newer local bytes', 'and stays at the name');
ok($older->{'saved'} && -e "$incoming_dir/$older->{'saved'}", 'the incoming copy is kept as a conflict file');

# A deletion older than the local edit keeps it; a newer one removes it.
my $kept = subs::cloud_sync_apply_delete($incoming_base, $dest_file, 4600);
is($kept->{'kept'}, 1, 'a deletion older than the local edit is refused');
ok(-e "$incoming_dir/one.txt", 'the edited file stays');
my $deleted = subs::cloud_sync_apply_delete($incoming_base, $dest_file, 6000);
is($deleted->{'deleted'}, 1, 'a newer deletion removes it');
ok(!-e "$incoming_dir/one.txt", 'the file is gone');
my $deleted_state = subs::cloud_sync_state_read($incoming_base);
ok($deleted_state->{'deleted'}->{'one.txt'}, 'and the state remembers the deletion');

# ---- a deletion is delivered, never silently dropped ------------------------
#
# The deletion time used to come from the hi-res time() this package imports,
# so it travelled as a fraction (1794376135.87). The receiver only accepted
# digits, read that as 0, and then every file looked newer than the deletion:
# it answered "kept", the sender took that as success and cleared its pending
# list. The queued time must be whole seconds, a kept file must keep the change
# pending until the newer edit comes back, and an unreachable device must keep
# it pending too. A fake agent stands in for the peer, so nothing touches the
# network.

{
	package CloudSyncFakeRes;
	sub new { my ($class, $json) = @_; return bless { json => $json }, $class }
	sub json { return $_[0]->{'json'} }
	sub code { return 200 }
	sub body { return '' }

	package CloudSyncFakeTx;
	sub new { my ($class, $json) = @_; return bless { res => CloudSyncFakeRes->new($json) }, $class }
	sub res { return $_[0]->{'res'} }

	package CloudSyncFakeUA;
	sub new { my ($class, $reply) = @_; return bless { reply => $reply, calls => [] }, $class }
	sub calls { return $_[0]->{'calls'} }
	sub post {
		my ($self, $url, %rest) = @_;
		my $form = $rest{'form'} || {};
		push @{ $self->{'calls'} }, { url => $url, form => $form };
		my $reply = ref $self->{'reply'} eq 'CODE' ? $self->{'reply'}->($url, $form) : $self->{'reply'};
		return undef unless defined $reply;
		return CloudSyncFakeTx->new($reply);
	}

	package CloudSyncFakeJob;
	sub new { return bless { notes => {} }, shift }
	sub info { return { notes => {} } }
	sub note { return 1 }
	sub finish { my ($self, $result) = @_; $self->{'finished'} = $result; return 1 }
	sub fail { my ($self, $result) = @_; $self->{'failed'} = $result; return 1 }
	sub finished { return $_[0]->{'finished'} }
	sub failed { return $_[0]->{'failed'} }
}

sub cloud_delete_sender {
	my $dir = tempdir(DIR => $test_home, CLEANUP => 1);
	my $base = substr($dir, length($test_home) + 1);
	write_file("$dir/gone.txt", 'gone');
	subs::cloud_sync_collect_changes($dir, $base);
	subs::cloud_sync_state_modify($base, sub { $_[0]->{'pending'} = []; return 1 });
	unlink "$dir/gone.txt";
	my $changes = subs::cloud_sync_collect_changes($dir, $base);
	return ($dir, $base, $changes);
}

sub cloud_delete_job {
	my ($dir, $base, $changes, $reply) = @_;
	my $ua = CloudSyncFakeUA->new($reply);
	local *subs::remote_agent_for = sub { return { ua => $ua, manager => 'https://peer.invalid' } };
	my $job = CloudSyncFakeJob->new();
	subs::cloud_sync_job($job, {
		path => $dir,
		base => $base,
		devices => [ { uuid => 'peer-uuid', hostname => 'Peer' } ],
		changes => [ map { { %{$_} } } @{$changes} ]
	});
	return ($job, $ua);
}

my ($del_dir, $del_base, $del_changes) = cloud_delete_sender();
is(scalar @{$del_changes}, 1, 'a disappeared file is one collected change');
is($del_changes->[0]->{'kind'}, 'delete', 'a delete change');
like($del_changes->[0]->{'deleted_at'}, qr/^\d+$/, 'its time is whole epoch seconds the peer can read');

my ($del_job, $del_ua) = cloud_delete_job($del_dir, $del_base, $del_changes,
	{ status => 'ok', deleted => 1, kept => 0, deleted_at => $del_changes->[0]->{'deleted_at'} });
ok($del_job->finished, 'a deletion every device took finishes');
ok(!$del_job->failed, 'without an error');
is(scalar @{ subs::cloud_sync_state_read($del_base)->{'pending'} }, 0,
	'and the delivered deletion leaves the pending list');
ok(subs::cloud_sync_state_read($del_base)->{'deleted'}->{'gone.txt'},
	'the tombstone stays, so a stale copy cannot come back');

# A peer that kept a newer local copy has not taken the deletion. Its edit
# travels back and supersedes the delete on arrival; until then the change is
# still pending, and the sender does not treat "kept" as a delivery.
my ($kept_dir, $kept_base, $kept_changes) = cloud_delete_sender();
my $kept_reply_for = $kept_changes->[0]->{'deleted_at'};
my ($kept_job) = cloud_delete_job($kept_dir, $kept_base, $kept_changes,
	{ status => 'ok', deleted => 0, kept => 1, mtime => $kept_reply_for + 5 });
ok($kept_job->finished, 'a peer that kept a newer copy still answers the job');
ok(!$kept_job->failed, 'and it is not a transport failure');
my $kept_pending = subs::cloud_sync_state_read($kept_base)->{'pending'};
is(scalar @{$kept_pending}, 1, 'but the deletion stays pending until the newer copy returns');
is($kept_pending->[0]->{'kind'}, 'delete', 'still the deletion');
ok(subs::cloud_sync_state_read($kept_base)->{'deleted'}->{'gone.txt'},
	'and the tombstone is not dropped');
ok(!-e "$kept_dir/gone.txt", 'the sender does not bring the file back for itself');

# A device that never answers is the retry the pending list exists for.
my ($down_dir, $down_base, $down_changes) = cloud_delete_sender();
my ($down_job) = cloud_delete_job($down_dir, $down_base, $down_changes, sub { return undef });
ok($down_job->failed, 'an unreachable device fails the job');
is(scalar @{ subs::cloud_sync_state_read($down_base)->{'pending'} }, 1,
	'and the deletion is kept for the next sweep');

# The receiving half: a local edit newer than the deletion wins, and the
# winning copy is queued so it travels back to the device that deleted it.
my $edited_dir = tempdir(DIR => $test_home, CLEANUP => 1);
my $edited_base = substr($edited_dir, length($test_home) + 1);
write_file("$edited_dir/edited.txt", 'edited');
utime 2200, 2200, "$edited_dir/edited.txt";
my $edited_dest = subs::cloud_sync_destination({ base => $edited_base, path => 'edited.txt' });
my $edited_kept = subs::cloud_sync_apply_delete($edited_base, $edited_dest, 2100);
is($edited_kept->{'kept'}, 1, 'a deletion older than the local edit is refused');
ok(-e "$edited_dir/edited.txt", 'the edited file stays');
my $edited_state = subs::cloud_sync_state_read($edited_base);
my ($edited_queued) = grep { ($_->{'rel'} || '') eq 'edited.txt' && ($_->{'kind'} || '') eq 'file' }
	@{ $edited_state->{'pending'} || [] };
ok($edited_queued, 'and the winning edit is queued to travel back');

# A fractional time from a peer that still sends one is floored, not read as 0.
my $fractional_dir = tempdir(DIR => $test_home, CLEANUP => 1);
my $fractional_base = substr($fractional_dir, length($test_home) + 1);
write_file("$fractional_dir/fractional.txt", 'x');
utime 2000, 2000, "$fractional_dir/fractional.txt";
my $fractional_dest = subs::cloud_sync_destination({ base => $fractional_base, path => 'fractional.txt' });
my $fractional = subs::cloud_sync_apply_delete($fractional_base, $fractional_dest, '2100.75');
is($fractional->{'kept'}, 0, 'a fractional deletion time is not read as "nothing is newer"');
is($fractional->{'deleted'}, 1, 'so the deletion still removes the file');
ok(!-e "$fractional_dir/fractional.txt", 'and the file is gone');
is(subs::cloud_sync_state_read($fractional_base)->{'deleted'}->{'fractional.txt'}, 2100,
	'with a whole-second tombstone');

# A deletion with no readable time is refused so the sender retries; treating it
# as epoch 0 is what made every existing file win.
my $timeless = subs::cloud_sync_apply_delete($fractional_base, $fractional_dest, undef);
ok($timeless->{'error'}, 'a deletion with no time is refused rather than applied as 0');

# ---- a seed pass carries the tombstones, not only the files -----------------
#
# "Start syncing" and "Sync now" seed every member with the local folder. The
# seed listed the files on disk only, so a file the person deleted was never
# offered as a deletion, and a device that still held a copy could offer it
# back. A tombstone whose file is gone must travel as a delete, and a copy that
# is not newer than its own tombstone must not travel at all.

sub cloud_state_at {
	my ($base, $rel) = @_;
	my $state = subs::cloud_sync_state_read($base);
	return $state->{'deleted'}->{$rel};
}

sub cloud_seed_job {
	my ($dir, $base, $reply) = @_;
	my $ua = CloudSyncFakeUA->new($reply);
	local *subs::remote_agent_for = sub { return { ua => $ua, manager => 'https://peer.invalid' } };
	my $job = CloudSyncFakeJob->new();
	subs::cloud_sync_job($job, {
		path => $dir,
		base => $base,
		seed => 1,
		devices => [ { uuid => 'peer-uuid', hostname => 'Peer' } ]
	});
	return ($job, $ua);
}

my $seed_dir = tempdir(DIR => $test_home, CLEANUP => 1);
my $seed_base = substr($seed_dir, length($test_home) + 1);
write_file("$seed_dir/gone.txt", 'gone');
utime 1000, 1000, "$seed_dir/gone.txt";
subs::cloud_sync_collect_changes($seed_dir, $seed_base);
subs::cloud_sync_state_modify($seed_base, sub { $_[0]->{'pending'} = []; return 1 });
unlink "$seed_dir/gone.txt";
my $seed_collected = subs::cloud_sync_collect_changes($seed_dir, $seed_base);
is(scalar @{$seed_collected}, 1, 'the deletion is collected before the seed');
my $seed_tomb = cloud_state_at($seed_base, 'gone.txt');
ok($seed_tomb, 'with a tombstone');
subs::cloud_sync_state_modify($seed_base, sub { $_[0]->{'pending'} = []; return 1 });
my $seed_changes = subs::cloud_sync_full_changes($seed_dir, $seed_base);
my ($seed_delete) = grep { ($_->{'kind'} || '') eq 'delete' } @{$seed_changes};
ok($seed_delete, 'a seed carries the tombstone as a delete');
is($seed_delete->{'rel'}, 'gone.txt', 'for the path that is gone');
is($seed_delete->{'deleted_at'}, $seed_tomb, 'with the time the deletion was recorded');

# A stale copy that sits in the folder again must not be offered: its time does
# not beat the tombstone, so the deletion is still the truth.
write_file("$seed_dir/gone.txt", 'back again');
utime 900, 900, "$seed_dir/gone.txt";
my $seed_stale = subs::cloud_sync_full_changes($seed_dir, $seed_base);
is(scalar @{$seed_stale}, 0, 'a copy older than its own tombstone is never offered by a seed');

# An edit after the delete is newer than the tombstone, so it does travel - as
# the file, exactly as the conflict rule says.
my $seed_edit_at = $seed_tomb + 10;
write_file("$seed_dir/gone.txt", 'edited after the delete');
utime $seed_edit_at, $seed_edit_at, "$seed_dir/gone.txt";
my $seed_edit = subs::cloud_sync_full_changes($seed_dir, $seed_base);
is(scalar @{$seed_edit}, 1, 'a copy newer than the tombstone is offered');
is($seed_edit->[0]->{'kind'}, 'file', 'as a file, so the edit wins');
is($seed_edit->[0]->{'rel'}, 'gone.txt', 'at the path it was deleted from');

# The seed job then has to delete on the peer, not only add files.
unlink "$seed_dir/gone.txt";
my $seed_ua_dir = tempdir(DIR => $test_home, CLEANUP => 1);
my $seed_ua_base = substr($seed_ua_dir, length($test_home) + 1);
write_file("$seed_ua_dir/gone.txt", 'gone');
utime 1000, 1000, "$seed_ua_dir/gone.txt";
subs::cloud_sync_collect_changes($seed_ua_dir, $seed_ua_base);
subs::cloud_sync_state_modify($seed_ua_base, sub { $_[0]->{'pending'} = []; return 1 });
unlink "$seed_ua_dir/gone.txt";
subs::cloud_sync_collect_changes($seed_ua_dir, $seed_ua_base);
subs::cloud_sync_state_modify($seed_ua_base, sub { $_[0]->{'pending'} = []; return 1 });
my $seed_ua_tomb = cloud_state_at($seed_ua_base, 'gone.txt');
my ($seed_job, $seed_job_ua) = cloud_seed_job($seed_ua_dir, $seed_ua_base,
	{ status => 'ok', deleted => 0, kept => 0, deleted_at => $seed_ua_tomb });
ok($seed_job->finished, 'a seed that only has a tombstone still finishes');
my ($seed_delete_call) = grep { $_->{'url'} =~ m{/manager/folders/cloud/delete$} } @{ $seed_job_ua->calls };
ok($seed_delete_call, 'the seed sends the deletion to the peer');
is($seed_delete_call->{'form'}->{'path'}, 'gone.txt', 'for the tombstoned path');
is($seed_delete_call->{'form'}->{'deleted_at'}, $seed_ua_tomb, 'with the same whole-second time');

# ---- a receiver refuses a stale copy against its own tombstone ----------------
#
# The receive path only consulted its tombstone when the file was absent. A
# stale copy already on disk (an earlier sweep's winner, or a copy that came
# back) let the next upload win on time alone, so a deleted file reappeared on
# every sweep. The tombstone now decides before the local file does, whichever
# side still holds the copy.

my $refuse_dir = tempdir(DIR => $test_home, CLEANUP => 1);
my $refuse_base = substr($refuse_dir, length($test_home) + 1);
write_file("$refuse_dir/gone.txt", 'stale local copy');
utime 4000, 4000, "$refuse_dir/gone.txt";
subs::cloud_sync_state_modify($refuse_base, sub {
	my $st = shift;
	$st->{'deleted'}->{'gone.txt'} = 5000;
	return 1;
});
my $refuse_dest = subs::cloud_sync_destination({ base => $refuse_base, path => 'gone.txt' });
write_file("$refuse_dir/gone.txt.part", 'stale incoming bytes');
my $refuse_hash = subs::archive_file_digest("$refuse_dir/gone.txt.part");
my $refused = subs::cloud_sync_finalize_upload({
	base => $refuse_base,
	dest => $refuse_dest,
	part => "$refuse_dir/gone.txt.part",
	mtime => 4500,
	hash => $refuse_hash,
});
is($refused->{'accepted'}, 0, 'a file older than its tombstone is refused even when a copy is on disk');
is($refused->{'kept'}, 'deleted', 'the receiver says the deletion stands');
is($refused->{'deleted_at'}, 5000, 'and names the time the sender must not beat');
is(read_file("$refuse_dir/gone.txt"), 'stale local copy', 'the file on disk is not overwritten');
ok(!-e "$refuse_dir/gone.txt.part", 'the refused part is discarded');
is(cloud_state_at($refuse_base, 'gone.txt'), 5000, 'the refusal writes no new tombstone time');

# Refusing twice must not move the tombstone: a re-sent stale copy is answered
# the same, so the two sides can agree instead of renewing the deletion.
write_file("$refuse_dir/gone.txt.part", 'stale incoming bytes');
my $refused_again = subs::cloud_sync_finalize_upload({
	base => $refuse_base,
	dest => $refuse_dest,
	part => "$refuse_dir/gone.txt.part",
	mtime => 4500,
	hash => $refuse_hash,
});
is($refused_again->{'kept'}, 'deleted', 'a re-sent stale copy is refused the same way');
is($refused_again->{'deleted_at'}, 5000, 'with the same deletion time');
is(cloud_state_at($refuse_base, 'gone.txt'), 5000, 'so the tombstone is not renewed and refusing cannot loop');

# An older tombstone still lets a newer file win: an edit after the delete
# brings the file back.
my $win_dir = tempdir(DIR => $test_home, CLEANUP => 1);
my $win_base = substr($win_dir, length($test_home) + 1);
write_file("$win_dir/edited.txt", 'stale local copy');
utime 4000, 4000, "$win_dir/edited.txt";
subs::cloud_sync_state_modify($win_base, sub {
	my $st = shift;
	$st->{'deleted'}->{'edited.txt'} = 4500;
	return 1;
});
my $win_dest = subs::cloud_sync_destination({ base => $win_base, path => 'edited.txt' });
write_file("$win_dir/edited.txt.part", 'edited after the delete');
my $win_hash = subs::archive_file_digest("$win_dir/edited.txt.part");
my $won = subs::cloud_sync_finalize_upload({
	base => $win_base,
	dest => $win_dest,
	part => "$win_dir/edited.txt.part",
	mtime => 5000,
	hash => $win_hash,
});
is($won->{'accepted'}, 1, 'a file newer than the tombstone is accepted');
is(read_file("$win_dir/edited.txt"), 'edited after the delete', 'and takes the name');
ok(!cloud_state_at($win_base, 'edited.txt'), 'the superseded tombstone is gone');

# ---- the sender drops the copy a peer says was deleted ----------------------
#
# When the receiver refuses, its answer carries kept => deleted and the time.
# The sender must take that deletion locally, once, and clear the change; the
# send detail dropped those fields, so its local copy stayed and every pass
# offered it again.

my $drop_dir = tempdir(DIR => $test_home, CLEANUP => 1);
my $drop_base = substr($drop_dir, length($test_home) + 1);
write_file("$drop_dir/stale.txt", 'stale');
utime 4000, 4000, "$drop_dir/stale.txt";
my $drop_changes = subs::cloud_sync_collect_changes($drop_dir, $drop_base);
is(scalar @{$drop_changes}, 1, 'the stale copy is a collected file change');
my ($drop_job) = cloud_delete_job($drop_dir, $drop_base, $drop_changes, sub {
	my ($url, $form) = @_;
	if ($url =~ m{/manager/folders/cloud/probe$}) {
		return { status => 'ok', exists => 1, size => 5, mtime => 3000, deleted_at => 0, partial => {} };
	}
	if ($url =~ m{/manager/folders/cloud/receive$}) {
		return { status => 'ok', kept => 'deleted', deleted_at => 5000, size => 5 };
	}
	return { status => 'error', error => 'unexpected request' };
});
ok($drop_job->finished, 'a refused upload still finishes the job');
ok(!$drop_job->failed, 'and is not a transport failure');
ok(!-e "$drop_dir/stale.txt", 'the sender drops the copy the peer says was deleted');
is(cloud_state_at($drop_base, 'stale.txt'), 5000, 'and records the peer\'s deletion time');
is(scalar @{ subs::cloud_sync_state_read($drop_base)->{'pending'} || [] }, 0,
	'and the settled file change leaves pending');
my $drop_seed = subs::cloud_sync_full_changes($drop_dir, $drop_base);
my @drop_deletes = grep { ($_->{'kind'} || '') eq 'delete' && $_->{'rel'} eq 'stale.txt' } @{$drop_seed};
is(scalar @drop_deletes, 1, 'a later seed offers the tombstone, not the file: the loop ends');
is($drop_deletes[0]->{'deleted_at'}, 5000, 'at the time the peer named');

# A peer that already agrees answers ok, without touching its tombstone.
my $drop_dest = subs::cloud_sync_destination({ base => $drop_base, path => 'stale.txt' });
my $agreed = subs::cloud_sync_apply_delete($drop_base, $drop_dest, 5000);
is($agreed->{'kept'}, 0, 'a repeat deletion is not a conflict');
is($agreed->{'deleted'}, 0, 'there is nothing left to remove');
is(cloud_state_at($drop_base, 'stale.txt'), 5000, 'and the tombstone keeps its time');

# ---- a device row stays a hash after the selected flag ----------------------

my $device_rows = [ { uuid => 'u', hostname => 'h', ok => 1, selected => 0 } ];
my $mapped_rows = [ map {
	my $d = $_;
	my $selected = $d->{'ok'} ? 1 : 0;
	+{ %{$d}, selected => $selected }
} @{$device_rows} ];
is(ref($mapped_rows->[0]), 'HASH', 'the selected flag is added to a hash row, not a bare block');
is($mapped_rows->[0]->{'selected'}, 1, 'the row carries the choice');
is($mapped_rows->[0]->{'uuid'}, 'u', 'and its uuid is still a field');

# ---- the rail, the queue and the app agree ----------------------------------

my $archive    = read_file("$root/lib/JawnOS/Domain/Archive.pm");
my $controller = read_file("$root/lib/JawnOS/Controller/manager_folders2.pm");
my $routes     = read_file("$root/lib/JawnOS/Routes/manager_folders2.pm");
my $loader     = read_file("$root/lib/JawnOS/Domain/Loader.pm");
my $key        = read_file("$root/lib/JawnOS/Domain/Key.pm");
my $jobs       = read_file("$root/perl/jobs.pl");
my $context    = template_source('folders/context');
my $folders    = template_source('folders/folders');
my $device_box = template_source('folders/cloud_sync');
my $list_box   = template_source('folders/cloud_list');
my $js         = js_source('public/js/manager/folders.js');
my $help       = help_source();

like($archive, qr/sub cloud_sync_job/, 'the worker has a CloudSync task');
like($archive, qr/sub cloud_sync_space_rows/, 'the house is asked for room');
like($archive, qr{sub cloud_sync_free_space}, 'a destination measures the nearest existing ancestor');
like($archive, qr/sub cloud_sync_state_modify/, 'each device keeps its own state under a lock');
like($archive, qr/sub cloud_sync_collect_changes/, 'a sweep turns local changes into pending work');
like($archive, qr/sub cloud_sync_finalize_upload/, 'a receive settles a conflict on arrival');
like($archive, qr/sub cloud_sync_apply_delete/, 'a deletion is compared with the local time');
like($archive, qr/sub cloud_sync_register_peer/, 'a peer is taught the folder');
like($archive, qr/sub cloud_sync_lock_path/, 'a per-path lock keeps two senders apart');
like($archive, qr/sub cloud_sync_registrations_modify/, 'registrations are changed under one lock');
like($controller, qr/sender => \(defined \$sender/, 'the receiver records the uploader');
like($archive, qr/sub cloud_sync_delete_peer/, 'a deletion is pushed to a peer');
like($archive, qr/sub cloud_sync_sweep/, 'a sweep queues pending work');
like($key, qr/cloud_sync => \\&cloud_sync_job/, 'the task is registered in its own list');
like($archive, qr/discard_url => '\/manager\/folders\/cloud\/discard'/, 'a cancelled upload discards its partial');

like($routes, qr{'\/manager\/folders\/cloud', 'action_30700'}, 'the check route is registered');
like($routes, qr{'\/manager\/folders\/cloud\/start', 'action_30701'}, 'the start route is registered');
like($routes, qr{'\/manager\/folders\/cloud\/receive', 'action_30712'}, 'the peer receive route is registered');
like($routes, qr{'\/manager\/folders\/cloud\/register', 'action_30715'}, 'the peer register route is registered');
like($routes, qr{'\/manager\/folders\/cloud\/unregister', 'action_30716'}, 'the peer unregister route is registered');
like($routes, qr{'\/manager\/folders\/cloud\/delete', 'action_30717'}, 'the peer delete route is registered');
unlike($routes, qr{'\/manager\/folders\/cloud\/prune'}, 'the old one-way prune route is gone');

like($controller, qr/sub action_30700/, 'the check action exists');
like($controller, qr/\+\{ %\{\$d\}, selected/, 'the device row is built as a hashref');
like($controller, qr/sub action_30701/, 'the start action exists');
like($controller, qr/sub action_30715/, 'the register action exists');
like($controller, qr/sub action_30717/, 'the delete action exists');
like($controller, qr/'archive_fetch_home', 'cloud_sync'/, 'the queue lists CloudSync jobs beside archive jobs');

like($loader, qr/\bcloud_sync_job\b/, 'the loader maps the new domain helpers');
like($key, qr/cloud_sync => \\&cloud_sync_job/, 'Minion knows the task');
like($jobs, qr/cloud_sync_sweep_start/, 'the sweep is armed by a process of its own');
# Minion::Worker::run resets the event loop before it dequeues anything, so a
# timer armed just before it is dropped and the sweep never fires: a change made
# while no Folders window was open waited for ever. The sweep therefore has its
# own subprocessor, and the Minion worker must not arm it.
like($jobs, qr/sub job_cloud_sync_sweep \{[^}]*cloud_sync_sweep_start[^}]*Mojo::IOLoop->start/s,
	'the sweep process arms its timer and then runs the loop');
like($jobs, qr/'cloud sync sweep' => \\&job_cloud_sync_sweep/, 'and is registered by name');
my ($minion_worker) = $jobs =~ /(sub job_minion_worker \{.*?\n\})/s;
ok(defined $minion_worker, 'the Minion worker sub is readable');
unlike($minion_worker, qr/cloud_sync_sweep_start/,
	'the Minion worker does not arm a timer the loop reset would drop');
like($jobs, qr/Minion::Worker::run resets the event\b/,
	'and the reason is written down where the next reader will be');

like($context, qr/'cloud_sync'/, 'the folder menu offers CloudSync');
like($folders, qr/folders_cloud_open/, 'Places has a CloudSync row');
like($device_box, qr/folders_cloud_device/, 'the dialog has a checkbox per device');
like($device_box, qr/free_bytes/, 'and says how much room is free');
like($list_box, qr/folders_cloud_stop/, 'the list can stop a folder');
like($list_box, qr/folders_cloud_now/, 'and sync one now');
like($js, qr/function foldersCloudCheck/, 'the app asks for room first');
like($js, qr{/manager/folders/cloud/start}, 'the app starts the job');
like($js, qr/function foldersCloudList/, 'the Places row opens the list');
like($help, qr/later time wins/, 'the help explains the conflict rule');
like($help, qr/\.conflict-/, 'and says the losing copy is kept');

# ---- a chunked part is streamed from its asset ----------------------------
# Mojo keeps a small upload in memory (and the peer signature reads the body
# first), so asset->path is undef. Reading it back made every file answer "the
# upload has no file" after the folders had already been made (2026-11-11).
like($controller, qr/\$asset->get_chunk/, 'a chunked upload streams from its asset');
unlike($controller, qr/asset->path/, 'no receive route needs a temp path for the part');

# ---- a registration is this machine's own, not a synced setting ------------
# The settings row is synced across the house, so the source's absolute path
# landed on the phone and every receive there said "this folder is not
# registered" while the folders had already been made. It now lives in the
# cache table, which is this machine's own view and survives a restart.
{
	my $mine = "$test_home/Downloads/gptpres";
	make_path($mine) unless -d $mine;
	subs::cloud_sync_registrations_write([
		{ path => $mine, base => 'Downloads/gptpres', devices => [], added => 1 }
	]);
	my $rows = subs::cloud_sync_registrations();
	is(scalar @{$rows}, 1, 'a registration round-trips through the cache');
	is($rows->[0]->{'path'}, $mine, 'and keeps this machine\'s path');
	ok(subs::cache_get({ app => 'folders', context => 'cloud_sync' }),
		'it is stored in the cache table, not in settings');
	ok(!-e $subs::home_dir . '/.president/cloud_sync/registrations.json',
		'and not in a file under ~/.president');
}
{
	# The file written before the cache held registrations is adopted once.
	subs::cache_delete({ app => 'folders', context => 'cloud_sync' });
	my $dir = $subs::home_dir . '/.president/cloud_sync';
	make_path($dir) unless -d $dir;
	my $file = $dir . '/registrations.json';
	write_file($file, encode_json([
		{ path => "$test_home/Downloads/old", base => 'Downloads/old', devices => [] }
	]));
	my $rows = subs::cloud_sync_registrations();
	is(scalar @{$rows}, 1, 'a legacy registrations file is adopted');
	is($rows->[0]->{'path'}, "$test_home/Downloads/old", 'with the path it held');
	ok(subs::cache_get({ app => 'folders', context => 'cloud_sync' }),
		'and written into the cache');
	ok(-e $file, 'the legacy file is kept');
}
{
	subs::cache_delete({ app => 'folders', context => 'cloud_sync' });
	my $file = $subs::home_dir . '/.president/cloud_sync/registrations.json';
	unlink $file if -e $file;
	no warnings 'redefine';
	local *subs::setting_grabber = sub {
		return encode_json([
			{ path => '/home/jawn/Downloads/gptpres', base => 'Downloads/gptpres', devices => [] },
			{ path => "$test_home/Downloads/mine", base => 'Downloads/mine', devices => [] }
		]);
	};
	my $rows = subs::cloud_sync_registrations();
	is(scalar @{$rows}, 1, 'only a legacy path under this home is adopted');
	is($rows->[0]->{'path'}, "$test_home/Downloads/mine", 'the foreign registration is dropped');
	ok(subs::cache_get({ app => 'folders', context => 'cloud_sync' }),
		'and the adopted list is written into the cache');
}

# ---- a per-base state file migrates into the cache --------------------------
{
	my $base = 'legacy-state';
	subs::cache_delete({ app => 'folders', context => 'cloud_sync_state', subcontext => sha256_hex($base) });
	my $dir = $subs::home_dir . '/.president/cloud_sync';
	make_path($dir) unless -d $dir;
	my $file = $dir . '/' . sha256_hex($base) . '.json';
	write_file($file, encode_json({
		files => { 'old.txt' => { size => 3, mtime => 4, hash => 'abcd' } },
		deleted => {},
		pending => [],
	}));
	my $state = subs::cloud_sync_state_read($base);
	ok($state->{'files'}->{'old.txt'}, 'a legacy per-base state is adopted');
	ok(subs::cache_get({ app => 'folders', context => 'cloud_sync_state', subcontext => sha256_hex($base) }),
		'and written into the cache');
	ok(-e $file, 'the legacy state file is kept');
}

# ---- the badge a listing wears -----------------------------------------------
#
# A file in a CloudSync folder shows its state on the icon: a green check when
# the state agrees and nothing is pending, a blue mark while a change is still
# on its way, and a red cross when a delivery was refused. The marks are pure
# answers over the state, so they are tested without a peer or a window.

my $mark_state = subs::cloud_sync_state_empty();
$mark_state->{'files'} = { 'photos/a.jpg' => { size => 10, mtime => 100, hash => 'abcd' } };
my $listed = { path => '/home/test/photos/a.jpg', type => 'file', size => 10, stat => [ 0, 0, 0, 0, 0, 0, 0, 10, 0, 100 ] };
is(subs::cloud_sync_status_file($mark_state, 'photos/a.jpg', $listed), 'synced',
	'a file the state agrees with is synced');
$listed->{'size'} = 11;
is(subs::cloud_sync_status_file($mark_state, 'photos/a.jpg', $listed), 'syncing',
	'a size that moved since the last pass is not agreed yet');
$listed->{'size'} = 10;
my $queued = subs::cloud_sync_pending_add($mark_state, { kind => 'file', rel => 'photos/a.jpg', size => 10, mtime => 100 });
is(subs::cloud_sync_status_file($mark_state, 'photos/a.jpg', $listed), 'syncing',
	'a queued change is still on its way');
$mark_state->{'pending'}->[0]->{'error'} = 'the machine did not answer';
is(subs::cloud_sync_status_file($mark_state, 'photos/a.jpg', $listed), 'failed',
	'a refused delivery is the red cross');
is(subs::cloud_sync_status_under($mark_state, 'photos'), 'failed',
	'a folder carries the worst state of the files under it');
delete $mark_state->{'pending'}->[0]->{'error'};
is(subs::cloud_sync_status_under($mark_state, 'photos'), 'syncing',
	'with no error it is still on its way');
$mark_state->{'pending'} = [];
is(subs::cloud_sync_status_under($mark_state, 'photos'), 'synced',
	'and with nothing pending the folder is synced');
is(subs::cloud_sync_status_under($mark_state, 'nowhere'), undef,
	'a folder with nothing known has no badge at all');
is(subs::cloud_sync_status_file($mark_state, 'new.txt', { size => 1, stat => [ 0, 0, 0, 0, 0, 0, 0, 1, 0, 5 ] }), 'syncing',
	'a local file the state has not seen yet is on its way');

# The marks a listing is built from: the registered folder itself when its
# parent is read, and its entries when the folder itself is read.
{
	my $badge_dir = tempdir(DIR => $test_home, CLEANUP => 1);
	my $badge_base = substr($badge_dir, length($test_home) + 1);
	make_path("$badge_dir/younger");
	write_file("$badge_dir/a.txt", 'a');
	subs::cloud_sync_registrations_write([ { path => $badge_dir, base => $badge_base, devices => [ { uuid => 'peer-uuid' } ] } ]);
	subs::cloud_sync_collect_changes($badge_dir, $badge_base);
	subs::cloud_sync_state_modify($badge_base, sub { $_[0]->{'pending'} = []; return 1 });
	my @entries = (
		{ path => "$badge_dir/a.txt", name => 'a.txt', type => 'file', size => 1, stat => [ 0, 0, 0, 0, 0, 0, 0, 1, 0, (stat "$badge_dir/a.txt")[9] ] },
		{ path => "$badge_dir/younger", name => 'younger', type => 'folder', stat => [] }
	);
	my $marks = subs::cloud_sync_status_marks($badge_dir, \@entries);
	is($marks->{"$badge_dir/a.txt"}, 'synced', 'a listed file wears its own state');
	is($marks->{"$badge_dir/younger"}, undef, 'an empty folder has nothing to claim');
	my $parent = $badge_dir;
	$parent =~ s{/[^/]+$}{};
	my $from_parent = subs::cloud_sync_status_marks($parent, [ { path => $badge_dir, name => 'badge', type => 'folder' } ]);
	is($from_parent->{$badge_dir}, 'synced', 'the registered folder wears the whole folder state from its parent');
	is(subs::cloud_sync_status_marks("$parent/elsewhere", [ { path => "$parent/elsewhere/x", type => 'file' } ])->{"$parent/elsewhere/x"}, undef,
		'a path no registration covers has no badge');
	subs::cloud_sync_registrations_write([]);
}

# A refused file delivery leaves its reason on the pending change, so the
# listing can turn that file red cross until a later pass reaches it.
{
	my $failed_dir = tempdir(DIR => $test_home, CLEANUP => 1);
	my $failed_base = substr($failed_dir, length($test_home) + 1);
	write_file("$failed_dir/bad.txt", 'bad');
	my $failed_changes = subs::cloud_sync_collect_changes($failed_dir, $failed_base);
	is(scalar @{$failed_changes}, 1, 'a new file is queued for the failing peer');
	my $failed_job = CloudSyncFakeJob->new();
	local *subs::remote_agent_for = sub { return { ua => CloudSyncFakeUA->new(undef), manager => 'https://peer.invalid' } };
	subs::cloud_sync_job($failed_job, {
		path => $failed_dir,
		base => $failed_base,
		devices => [ { uuid => 'peer-uuid', hostname => 'Peer' } ],
		changes => $failed_changes
	});
	ok($failed_job->failed, 'a file the peer would not take fails the job');
	my $failed_state = subs::cloud_sync_state_read($failed_base);
	my ($failed_pending) = @{ $failed_state->{'pending'} || [] };
	ok($failed_pending, 'and the change stays pending for the next pass');
	ok($failed_pending->{'error'}, 'the pending change carries the reason');
	is(subs::cloud_sync_status_file($failed_state, 'bad.txt', { size => 3, stat => [ 0, 0, 0, 0, 0, 0, 0, 3, 0, 0 ] }), 'failed',
		'so the listing marks that file failed');
	# a pass that reaches it again clears the mark, so synced files do not stay red
	subs::cloud_sync_state_modify($failed_base, sub {
		my $st = shift;
		subs::cloud_sync_pending_mark($st, { $failed_pending->{'id'} => 1 }, {});
		return 1;
	});
	ok(!subs::cloud_sync_state_read($failed_base)->{'pending'}->[0]->{'error'},
		'a later pass that reaches the change clears the red mark');
	subs::cloud_sync_registrations_write([]);
}

done_testing();
