# tests-for: lib/JawnOS/Domain/Archive.pm lib/JawnOS/Controller/manager_folders2.pm lib/JawnOS/Routes/manager_folders2.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Key.pm perl/jobs.pl perl/help/topics_apps.pl templates/folders/context.html.ep templates/folders/folders.html.ep templates/folders/cloud_sync.html.ep templates/folders/cloud_list.html.ep public/js/manager/folders.js public/js/manager/folders/
# covers:    CloudSync: a folder is checked for room, registered, mirrored to chosen devices, and watched for changes.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use Mojo::JSON qw(decode_json);
use RepoSource;

# CloudSync is the archive rail with a different destination: the same partial
# and resume rule, the same job note, and the same progress drawer. Everything
# here runs in a tempdir. No real folder or peer is touched.

my $root = repo_root();
require "$root/lib/JawnOS/Domain/Archive.pm";

# ---- a destination cannot climb out of its base -----------------------------

my $dest = subs::cloud_sync_destination({ base => '/tmp/house-sync', path => 'photos/autumn/a.jpg' });
is($dest->{'root'}, '/tmp/house-sync', 'the base is the destination root');
is($dest->{'relative'}, 'photos/autumn/a.jpg', 'the path inside the base is kept');
is($dest->{'path'}, '/tmp/house-sync/photos/autumn/a.jpg', 'the file lands under the base');
is($dest->{'parent'}, '/tmp/house-sync/photos/autumn', 'and its parent is the folder it sits in');

my $climb = subs::cloud_sync_destination({ base => '/tmp/house-sync', path => '../../etc/passwd' });
is($climb->{'relative'}, 'etc/passwd', 'a path that tries to climb is resolved against the base');
is($climb->{'path'}, '/tmp/house-sync/etc/passwd', 'and still lands inside the base');

# ---- deletion only touches what CloudSync recorded --------------------------

is_deeply(
	subs::cloud_sync_prune_list([ 'a.txt', 'b.txt', 'c/d.txt' ], [ 'b.txt' ]),
	[ 'a.txt', 'c/d.txt' ],
	'a tracked file the source dropped is the only thing offered for removal'
);
is_deeply(subs::cloud_sync_prune_list([], [ 'a.txt' ]), [], 'nothing tracked means nothing to remove');

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/root/sub");
write_file("$tmp/root/keep.bin", 'keep');
write_file("$tmp/root/gone.bin", 'gone');
write_file("$tmp/root/sub/also.bin", 'also');
write_file("$tmp/root/.cloudsync.json", '["keep.bin","gone.bin","sub/also.bin"]');

my $pruned = subs::cloud_sync_prune_files("$tmp/root", [ 'keep.bin' ]);
is($pruned->{'removed'}, 2, 'the two files the source dropped are removed');
ok(-e "$tmp/root/keep.bin", 'the file the source still has stays');
ok(!-e "$tmp/root/gone.bin", 'a dropped file goes');
ok(!-e "$tmp/root/sub/also.bin", 'a dropped file in a subfolder goes too');
is_deeply(decode_json(read_file("$tmp/root/.cloudsync.json")), [ 'keep.bin' ], 'the manifest now names only what was kept');

my $untracked = tempdir(CLEANUP => 1);
write_file("$untracked/precious.bin", 'not ours');
my $safe = subs::cloud_sync_prune_files($untracked, []);
is($safe->{'removed'}, 0, 'a folder with no manifest has nothing proved as CloudSync\'s');
ok(-e "$untracked/precious.bin", 'so nothing is deleted there');

# ---- the room question answers in bytes -------------------------------------

my $space = subs::cloud_sync_free_space($tmp);
is($space->{'status'}, 'ok', 'free space is read from the volume');
ok($space->{'free_bytes'} > 0, 'and is a positive byte count');
ok($space->{'total_bytes'} >= $space->{'free_bytes'}, 'the total is at least the free part');

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
like($archive, qr/sub cloud_sync_prune_files/, 'the destination applies a tracked manifest');
like($archive, qr/cloud_sync_prune_list\(\$tracked, \$incoming\)/, 'and only removes what the manifest names');
like($archive, qr/sub cloud_sync_sweep/, 'a sweep queues a changed folder');
like($archive, qr/sub cloud_sync_job/, 'the worker task is defined');
like($archive, qr/discard_url => '\/manager\/folders\/cloud\/discard'/, 'a cancelled upload discards its partial');

like($routes, qr{'\/manager\/folders\/cloud', 'action_30700'}, 'the check route is registered');
like($routes, qr{'\/manager\/folders\/cloud\/start', 'action_30701'}, 'the start route is registered');
like($routes, qr{'\/manager\/folders\/cloud\/receive', 'action_30712'}, 'the peer receive route is registered');

like($controller, qr/sub action_30700/, 'the check action exists');
like($controller, qr/sub action_30701/, 'the start action exists');
like($controller, qr/sub action_30714/, 'the prune action exists');
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
like($help, qr/CloudSync/, 'the help topic explains it');

done_testing();
