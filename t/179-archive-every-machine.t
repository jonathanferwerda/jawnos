# tests-for: lib/JawnOS/Domain/Archive.pm lib/JawnOS/Domain/File.pm lib/JawnOS/Domain/Log.pm lib/JawnOS/Manager/Part23.pm lib/JawnOS/Controller/manager_folders.pm lib/JawnOS/Controller/manager_folders2.pm lib/JawnOS/Controller/manager_gallery.pm lib/JawnOS/Controller/sesh_check.pm perl/Music/05_library_and_queue.pl templates/folders/folders.html.ep templates/apps/app_file.html.ep templates/apps/gallery_album.html.ep templates/configure/misc_setting_list.html.ep public/js/manager/folders/02_archive_and_keyboard.js
# covers:    The archive machine is not in its own peer list, so every archive
#            lookup used to skip the one machine holding the drive. Resolution
#            now includes this machine, reads its manifest from the drive and
#            writes a transfer locally; the same rows reach Folders, Music,
#            Gallery and an appointment's files from every machine.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use JawnOSTest;

# Pure type rules first: a sealed name keeps its original extension under .enc,
# and rows written before that was read still answer as their real kind.
is(subs::archive_media_type('a/b/photo.jpg.enc'), 'image', 'a sealed photo is an image');
is(subs::archive_media_type('a/b/track.mp3.enc'), 'audio', 'a sealed track is audio');
is(subs::archive_media_type('a/b/clip.mp4.enc'), 'video', 'a sealed clip is video');
is(subs::archive_media_type('a/b/notes.txt'), 'document', 'an open document keeps its kind');
is(subs::archive_media_type('a/b/thing.bin'), 'other', 'an unknown file is other');

is(subs::archive_row_type({ type => 'other', relative => 'album/x.jpg.enc' }), 'image',
	'a legacy row derives its type from the sealed name');
is(subs::archive_row_type({ type => 'audio', relative => 'track.bin' }), 'audio',
	'a stored media type wins over the name');
is(subs::archive_row_type({ type => 'other', relative => '.thumbs/x.png.enc' }), 'image',
	'a sealed thumbnail is an image too');

# A self row is a candidate; a configured location can choose it by signatorial.
my $self = {
	self => 1,
	uuid => 'self',
	signatorial => 'testsig',
	hostname => 'Test',
	connection => 'active',
	archive_dir => '/tmp/archive',
	archive => { dir => '/tmp/archive' },
};
my $peer = { uuid => 'peer-uuid', signatorial => 'peersig', hostname => 'Peer', archive_dir => '/mnt/archive' };
is(scalar(subs::archive_machine_candidates([ $self, $peer ])), 2, 'both the local and peer archives are candidates');
is(subs::archive_machine_for('music', {}, [ $self ])->{'self'}, 1,
	'the archive machine resolves itself when it is the only candidate');
is(subs::archive_machine_for('music', { music_archive => 'testsig' }, [ $self, $peer ])->{'hostname'}, 'Test',
	'a configured signatorial picks the local machine');

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/Music");
make_path("$tmp/archive");

# The archive machine reads its own drive: no peer request, same shape as a
# remote answer.
{
	local *subs::setting_grabber = sub { return undef };
	local *subs::machine_name = sub { return 'Test' };
	local *subs::signatorial_designer = sub { return 'testsig' };
	local *subs::device_setter = sub { return 'computer' };
	local *subs::remote_machine_lister = sub { return [] };
	local $subs::config = { archive_dir => "$tmp/archive" };

	my $local_self = { %{$self}, archive_dir => "$tmp/archive", archive => { dir => "$tmp/archive" } };
	my $appended = subs::archive_manifest_append({
		location => 'music',
		rows => [ { relative => 'song.mp3', size => 3, mtime => 123, type => 'audio' } ],
	});
	is($appended->{'error'}, undef, 'a local append succeeds');
	is($appended->{'rows'}, 1, 'one row is written');
	ok(-e "$tmp/archive/Music/manifest.jsonl", 'the journal lives in the location folder');

	my $manifest = subs::archive_manifest_for({ rm => $local_self, location => 'music' });
	is($manifest->{'error'}, undef, 'the local manifest is read');
	is($manifest->{'folder'}, "$tmp/archive/Music", 'with the drive folder it sits in');
	is(scalar @{$manifest->{'rows'}}, 1, 'and the row just appended');
	is($manifest->{'rows'}[0]{'relative'}, 'song.mp3', 'named by its place inside the location');

	my $lookup = subs::archive_file_lookup({
		misc_settings => { computer => { music_location => "$tmp/Music" } },
		location => 'music',
		base => "$tmp/Music",
		machines => [ $local_self ],
	});
	ok($lookup->{'locate'}, 'a file lookup is built');
	my $found = $lookup->{'locate'}->("$tmp/Music/song.mp3");
	ok($found, 'a path inside the location is found');
	is($found->{'path'}, "$tmp/archive/Music/song.mp3", 'and points at the drive copy');
	is($found->{'remote_uuid'}, '', 'a local drive needs no relay');
	is($found->{'type'}, 'audio', 'the row keeps its kind');

	# an appointment's file entry learns the archive path without a relay
	write_file("$tmp/archive/Music/song.mp3", 'abc');
	my $files = [ { file => "$tmp/Music/song.mp3", file_type => 'snd' } ];
	subs::archive_file_attach($files, { misc_settings => { computer => { music_location => "$tmp/Music" } } });
	is($files->[0]{'file'}, "$tmp/archive/Music/song.mp3", 'the missing local file is replaced by the archived one');
	ok($files->[0]{'archived'}, 'and is marked archived');
	is($files->[0]{'remote_uuid'}, undef, 'a local archive leaves the file URL local');

	# a path from another device (a phone's /sdcard/DCIM seen on a computer)
	# matches that device's location, so the archive is found from here too
	make_path("$tmp/phone/DCIM/Camera");
	subs::archive_manifest_append({
		location => 'photo',
		rows => [ { relative => 'Camera/p.jpg', size => 4, mtime => 123, type => 'image' } ],
	});
	my $phone_files = [ { file => "$tmp/phone/DCIM/Camera/p.jpg", file_type => 'img' } ];
	subs::archive_file_attach($phone_files, {
		misc_settings => {
			computer => { photo_location => "$tmp/computer/Pictures" },
			mobile => { photo_location => "$tmp/phone/DCIM" },
		}
	});
	is($phone_files->[0]{'file'}, "$tmp/archive/Photos/Camera/p.jpg",
		'a phone path on a computer resolves to the shared archive');
	ok($phone_files->[0]{'archived'}, 'and is marked archived');

	# the plan marks a self destination as a local copy, not a peer upload
	my $plan = subs::archive_plan({
		items => [ { path => "$tmp/Music/song.mp3", type => 'file' } ],
		settings => { music_location => "$tmp/Music" },
		machines => [ $local_self ],
	});
	is(scalar @{$plan->{'refused'}}, 0, 'the item is not refused');
	is(scalar @{$plan->{'jobs'}}, 1, 'one job is planned');
	is($plan->{'jobs'}[0]{'local'}, 1, 'a self destination is a local copy');
	is($plan->{'jobs'}[0]{'remote_uuid'}, '', 'and carries no peer uuid');
	is($plan->{'jobs'}[0]{'location'}, 'music', 'the location is kept');
}

# ---- the callers all ask the same list --------------------------------------

my $file = read_file("$FindBin::Bin/../lib/JawnOS/Domain/File.pm");
my $archive = read_file("$FindBin::Bin/../lib/JawnOS/Domain/Archive.pm");
my $folders = read_file("$FindBin::Bin/../lib/JawnOS/Manager/Part23.pm");
my $folders_ctl = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_folders2.pm");
my $music = read_file("$FindBin::Bin/../perl/Music/05_library_and_queue.pl");
my $gallery = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_gallery.pm");
my $album = read_file("$FindBin::Bin/../templates/apps/gallery_album.html.ep");
my $sesh = read_file("$FindBin::Bin/../lib/JawnOS/Controller/sesh_check.pm");
my $app_file = read_file("$FindBin::Bin/../templates/apps/app_file.html.ep");
my $folders_page = read_file("$FindBin::Bin/../templates/folders/folders.html.ep");
my $configure = read_file("$FindBin::Bin/../templates/configure/misc_setting_list.html.ep");
my $folders_js = read_file("$FindBin::Bin/../public/js/manager/folders/02_archive_and_keyboard.js");

like($file, qr/sub archive_self_machine/, 'the archive machine can describe itself');
like($file, qr/sub archive_machines/, 'and the peer list plus itself is one helper');
like($file, qr/local => \(\$rm->\{'self'\} \? 1 : 0\)/, 'a plan marks the local destination');
like($archive, qr/sub archive_manifest_for/, 'manifests have one local-or-peer reader');
like($archive, qr/sub archive_file_lookup/, 'one lookup answers for any location');
like($archive, qr/sub archive_file_attach/, 'appointment files can learn the archive copy');
like($archive, qr/sub archive_local_transfer_job/, 'a transfer to the local drive has a path');
like($archive, qr/return &archive_local_transfer_job/, 'the job chooses it from the plan');
like($folders, qr/subs::archive_machines/, 'Folders badges ask the full list');
like($folders, qr/subs::archive_manifest_for/, 'and read the local drive when it is this machine');
like($folders_ctl, qr/subs::archive_machines/, 'the archive queue names the local locations');
like($music, qr/subs::archive_manifest_for/, 'Music lists the local archive too');
like($gallery, qr/\(\$settings->\{'archive'\} \/\/ 'on'\) ne 'off'/, 'the Gallery looks in the archive unless told not to');
like($album, qr/\(\$settings->\{'archive'\} \/\/ 'on'\) ne 'off'/, 'and so does the album page');
like($sesh, qr/subs::archive_root\(\)/, 'peers are told the effective root, not config alone');
like($app_file, qr/remote_uuid/, 'an appointment file carries the machine that holds it');
like($folders_page, qr/remote_uuid/, 'the Folders sidebar can point at the archive machine');
like($folders_page, qr/subs::archive_house_machine/, 'and finds the house archive on a machine without one');
like($configure, qr/subs::archive_self_machine/, 'Configure offers the local drive as an archive machine');
like($configure, qr/effective_archive_dir/, 'and shows the effective root even outside config folders');
like($folders_js, qr/data\.remote_uuid = remote/, 'a place click switches to the machine that holds it');

done_testing();
