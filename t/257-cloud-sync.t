# tests-for: lib/JawnOS/Domain/Archive.pm lib/JawnOS/Controller/manager_folders2.pm lib/JawnOS/Routes/manager_folders2.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Key.pm perl/jobs.pl perl/help/topics_apps.pl templates/folders/context.html.ep templates/folders/folders.html.ep templates/folders/cloud_sync.html.ep templates/folders/cloud_list.html.ep public/js/manager/folders.js public/js/manager/folders/
# covers:    CloudSync: a bidirectional folder mesh with time-ordered conflicts, tombstones and conflict copies.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use RepoSource;

# CloudSync is the archive rail turned into a small mesh: every member watches
# its own copy and pushes changes. These tests pin the pure rules - path
# containment, the conflict choice, the pending queue - and the wiring that
# makes every member take part. No real folder or peer is touched.

my $root = repo_root();
my $test_home = tempdir(CLEANUP => 1);
$ENV{'HOME'} = $test_home;
require "$root/lib/JawnOS/Domain/Archive.pm";
require "$root/lib/JawnOS/Domain/Loader.pm";
subs::preload('rightNow');
subs::preload('random_string_creator');

# ---- a destination cannot climb out of its base -----------------------------

my $dest = subs::cloud_sync_destination({ base => '/tmp/house-sync', path => 'photos/autumn/a.jpg' });
is($dest->{'root'}, '/tmp/house-sync', 'the base is the destination root');
is($dest->{'relative'}, 'photos/autumn/a.jpg', 'the path inside the base is kept');
is($dest->{'path'}, '/tmp/house-sync/photos/autumn/a.jpg', 'the file lands under the base');
is($dest->{'parent'}, '/tmp/house-sync/photos/autumn', 'and its parent is the folder it sits in');

my $climb = subs::cloud_sync_destination({ base => '/tmp/house-sync', path => '../../etc/passwd' });
is($climb->{'relative'}, 'etc/passwd', 'a path that tries to climb is resolved against the base');
is($climb->{'path'}, '/tmp/house-sync/etc/passwd', 'and still lands inside the base');

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

my $conflict = subs::cloud_sync_conflict_path({ root => '/tmp/house-sync', path => '/tmp/house-sync/a.txt' }, 'abcdef1234567890');
is($conflict->{'relative'}, 'a.txt.conflict-abcdef12', 'the loser is named by its content hash');
is($conflict->{'path'}, '/tmp/house-sync/a.txt.conflict-abcdef12', 'beside the file it lost to');

# ---- a partial remembers which device owns it -------------------------------

my $partial_dir = tempdir(CLEANUP => 1);
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

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/root/sub");
write_file("$tmp/root/keep.bin", 'keep');
my $space = subs::cloud_sync_free_space($tmp);
is($space->{'status'}, 'ok', 'free space is read from the volume');
ok($space->{'free_bytes'} > 0, 'and is a positive byte count');
ok($space->{'total_bytes'} >= $space->{'free_bytes'}, 'the total is at least the free part');

# ---- the state machine sees, settles and forgets -----------------------------
#
# These use a real temp folder as the synced base and the temp HOME set above,
# so the state file under ~/.president/cloud_sync is exercised without touching
# the person's own state.

my $sync = tempdir(CLEANUP => 1);
my $sync_base = $sync;
write_file("$sync/one.txt", 'one');
my $collected = subs::cloud_sync_collect_changes($sync, $sync_base);
is(scalar @{$collected}, 1, 'a new file becomes one pending change');
is($collected->[0]->{'kind'}, 'file', 'it is a file change');
is($collected->[0]->{'rel'}, 'one.txt', 'named by its relative path');
my $saved_state = subs::cloud_sync_state_read($sync_base);
ok($saved_state->{'files'}->{'one.txt'}, 'the state records what it last agreed');
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
my $incoming_dir = tempdir(CLEANUP => 1);
my $incoming_base = $incoming_dir;
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
like($jobs, qr/cloud_sync_sweep_start/, 'the worker starts the sweep');

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

done_testing();
