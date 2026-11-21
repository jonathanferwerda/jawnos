# tests-for: lib/JawnOS/Domain/File.pm lib/JawnOS/Domain/Archive.pm perl/Music/05_library_and_queue.pl
# covers:    the Music player/queue cache resolves a missing path to its archive copy

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(write_file);
use JawnOSTest;

# A track that moves to the archive drive keeps its old home path in the Music
# cache. cache_get repairs only app=music player/queue rows on read, so the
# restored player and the replayed queue name a file that still exists. This
# pins the resolver, the two repaired contexts, the saved-stamp bump and the
# untouched rows, all against a temp drive and a fixture manifest.

# The domain layer is lazy: load the real definitions before the local stubs
# below, or a later module load would replace them.
subs::preload($_) for qw(
	archive_file_path archive_file_lookup archive_location_for archive_machines
	archive_manifest_append cache_get cache_set misc_setting_list device_setter
	machine_name signatorial_designer remote_machine_lister setting_grabber
);

my $real_lookup = \&subs::archive_file_lookup;

my $tmp     = tempdir(CLEANUP => 1);
my $house   = "$tmp/house";
my $archive = "$tmp/archive_drive";
make_path("$house/Music", "$archive/Music");

my $existing = "$house/Music/still-here.mp3";
my $moved    = "$house/Music/moved.mp3";
my $moved2   = "$house/Music/moved-too.mp3";
my $gone     = "$house/Music/no-copy.mp3";
write_file($existing, 'x');
write_file("$archive/Music/moved.mp3", 'x');
write_file("$archive/Music/moved-too.mp3", 'x');

my $self = {
	self => 1,
	uuid => 'self',
	signatorial => 'testsig',
	hostname => 'Test',
	connection => 'active',
	archive_dir => $archive,
	archive => { dir => $archive },
};

my $lookup_calls = 0;

{
	local $subs::device = 'computer';
	local $subs::config = { archive_dir => $archive };
	local *subs::device_setter = sub { return 'computer' };
	local *subs::misc_setting_list = sub {
		return { computer => { music_location => "$house/Music" } };
	};
	local *subs::archive_machines = sub { return [ $self ] };
	local *subs::remote_machine_lister = sub { return [] };
	local *subs::machine_name = sub { return 'Test' };
	local *subs::signatorial_designer = sub { return 'testsig' };
	local *subs::setting_grabber = sub { return undef };
	local *subs::archive_file_lookup = sub {
		$lookup_calls++;
		return $real_lookup->(@_);
	};

	my $appended = subs::archive_manifest_append({
		location => 'music',
		rows => [
			{ relative => 'moved.mp3',     size => 1, mtime => 123, type => 'audio' },
			{ relative => 'moved-too.mp3', size => 1, mtime => 123, type => 'audio' },
		],
	});
	is($appended->{'error'}, undef, 'the fixture manifest is written');

	# ---- the resolver --------------------------------------------------------

	is(subs::archive_file_path($existing), $existing,
		'a file still on this disk is returned unchanged');
	is(subs::archive_file_path($moved), "$archive/Music/moved.mp3",
		'a missing file resolves to its archive copy');
	is(subs::archive_file_path($gone), $gone,
		'a missing file with no archive copy keeps its path');

	# ---- the queue repairs itself on read ------------------------------------

	my $stamp = 1_700_000_000_000;
	subs::cache_set({ app => 'music', context => 'queue', warranty => '-6M' }, {
		files => [ $existing, $moved, $moved2, $gone ],
		library => 'local',
		permissive => 1,
		saved => $stamp,
	});

	$lookup_calls = 0;
	my $queue = subs::cache_get({ app => 'music', context => 'queue' });
	is_deeply($queue->{'files'}, [ $existing, "$archive/Music/moved.mp3", "$archive/Music/moved-too.mp3", $gone ],
		'the queue resolves every moved file and leaves the rest alone');
	isnt($queue->{'saved'}, $stamp,
		'a repaired queue bumps saved so a stale rendered shell is not replayed');
	is($lookup_calls, 1,
		'one manifest lookup serves every file in the same location, not one per file');

	my $saved = $queue->{'saved'};
	my $again = subs::cache_get({ app => 'music', context => 'queue' });
	is($again->{'saved'}, $saved,
		'a queue with nothing left to repair keeps its stamp, so the shell is not invalidated');
	is_deeply($again->{'files'}, $queue->{'files'}, 'and its repaired files are stable');

	# ---- the player repairs its file and persists it -------------------------

	subs::cache_set({ app => 'music', context => 'player', warranty => '-6M' }, {
		file => $moved,
		key => 'track-key',
		currentTime => 12,
	});
	my $player = subs::cache_get({ app => 'music', context => 'player' });
	is($player->{'file'}, "$archive/Music/moved.mp3",
		'the player cache file is repaired to the archive copy');
	is($player->{'key'}, 'track-key', 'the rest of the player cache is kept');

	my $row = subs::db_query(
		'select data from cache where app = ? and context = ? and device = ?',
		'music', 'player', 'computer'
	)->hashes->[0];
	my $stored = eval { subs::decode_sereal($row->{'data'}) };
	is($stored->{'file'}, "$archive/Music/moved.mp3",
		'the repaired player row is written back, not just returned');

	# ---- a non-Music row is untouched ----------------------------------------

	subs::cache_set({ app => 'gallery', context => 'player', warranty => '-6M' }, {
		file => $moved,
	});
	my $other = subs::cache_get({ app => 'gallery', context => 'player' });
	is($other->{'file'}, $moved,
		'a non-Music cache row keeps the path it was written with');
}

done_testing();
