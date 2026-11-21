# tests-for: templates/apps/music/files.html.ep templates/apps/music/track_rows.html.ep templates/apps/music/track_description.html.ep public/js/music.js public/css/music.css perl/Music/05_library_and_queue.pl perl/Music/07_song_maker.pl perl/Music/08_music_routes.pl
# covers:    The Music list is a window over a manifest queue: the server draws
#            only a slice, the player reads the whole queue from the manifest,
#            and the details panel is fetched on first press instead of being
#            inlined in every row.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use Mojo::JSON qw(encode_json);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JawnOSTest;

require "$FindBin::Bin/../perl/Music/05_library_and_queue.pl";
require "$FindBin::Bin/../perl/Music/06_track_naming.pl";
require "$FindBin::Bin/../perl/Music/07_song_maker.pl";

my $root = root();
my $js   = read_file("$root/public/js/music.js");
my $css  = read_file("$root/public/css/music.css");
my $files_tpl = read_file("$root/templates/apps/music/files.html.ep");
my $rows_tpl  = read_file("$root/templates/apps/music/track_rows.html.ep");
my $desc_tpl  = read_file("$root/templates/apps/music/track_description.html.ep");
my $routes    = read_file("$root/perl/Music/08_music_routes.pl");
my $library   = read_file("$root/perl/Music/05_library_and_queue.pl");

# ------------------------------------------------------------------ the window
{
	# The queue is described from paths and the archive manifest only; nothing
	# here probes. Five thousand rows are cheap to describe but must not be
	# drawn: the initial render carries one window.
	my @files = map { "Music/Album" . int($_ / 100) . "/Track $_.mp3" } (0 .. 4999);
	my %archive = map { $_ => {
		type => 'audio',
		info => { duration => '180', tags => {} },
		remote_uuid => 'peer-machine',
		remote_hostname => 'peer',
	} } @files;
	my $c = bless {}, 'MusicWindowFakeC';
	my $settings = {
		shuffle => 'off', all_albums => 'no', all_artists => 'no',
		artist => [], album => [], library => 'local', normalize => 'off',
	};
	my $crate = do {
		no warnings 'redefine';
		local *subs::config_reader = sub { { manager => { background_colour => 'white' }, name => 'Test', folders => [] } };
		local *subs::setting_grabber = sub {
			my $q = shift;
			return 'Test' if ($q->{'setting'} // '') eq 'computer_name';
			return '';
		};
		local *subs::dark_colour_for = sub { return 'black' };
		local *subs::inventory_grabber = sub { return {} };
		local *subs::cache_get = sub { return undef };
		local *subs::cache_set = sub { return 1 };
		local *subs::file_media_information = sub { die 'a manifest must not probe' };
		&Manager::song_maker({
			c => $c, config => {}, port => 443, files => \@files,
			archive => \%archive, settings => $settings, now_playing => {},
			same_order => 1, window => { offset => 0, limit => 60 },
		});
	};

	is(scalar @{ $crate->{'songs'} }, 60,
		'the initial render draws one window, not all 5,000 rows');
	is(scalar @{ $crate->{'manifest'} }, 5000, 'the manifest describes the whole queue');
	is($crate->{'queue_total'}, 5000, 'and reports the queue total');
	is(scalar @{ $crate->{'queue'} }, 5000, 'the queue saver gets every file');
	is($crate->{'window_offset'}, 0, 'the first window starts at the top');
	is($crate->{'songs'}->[0]->{'filename'}, $files[0],
		'and its rows are the head of the queue in order');

	my $entry = $crate->{'manifest'}->[0];
	ok(length $entry->{'key'}, 'a manifest row carries its queue key');
	is($entry->{'file'}, $files[0], 'and the file the player opens');
	ok(length $entry->{'file_uuid'}, 'the uuid the row was drawn with is preserved');
	is($entry->{'type'}, 'audio', 'the type');
	is($entry->{'remote_uuid'}, 'peer-machine', 'the machine the bytes come from');
	is($entry->{'archive'}, 1, 'an archived row says so');
	ok(exists $entry->{'display_track'}, 'the settled track label');
	ok(exists $entry->{'display_artist'}, 'the settled artist label');
	is($entry->{'duration'}, '180', 'the duration the archive manifest carried');
	is(ref $entry->{'chapters'}, 'ARRAY', 'chapters are always a list');

	# A late slice is the same shape and only the rows asked for.
	my @late = @{ $crate->{'manifest'} }[4990 .. 4999];
	my $slice = do {
		no warnings 'redefine';
		local *subs::cache_get = sub { return undef };
		local *subs::cache_set = sub { return 1 };
		local *subs::app_private_now = sub { return 0 };
		local *Manager::help_app_hidden = sub { return 0 };
		local *Manager::music_app_private = sub { return 0 };
		local *Manager::music_app_visible = sub { return 1 };
		local *Manager::playable_name = sub { return 1 };
		local *Manager::playable_enc_name = sub { return 1 };
		&Manager::music_window_songs(\@late, {
			permissive => 1, now_playing => {}, remote_uuid => '',
		});
	};
	is(scalar @{ $slice->{'songs'} }, 10, 'a window request returns exactly its slice');
	is($slice->{'songs'}->[0]->{'filename'}, $files[4990],
		'and starts at the requested queue position');
	is(scalar @{ $slice->{'rows'} }, 10, 'with one enriched manifest row per card');

	my ($off, $lim) = &Manager::music_window_window({});
	is($off, 0, 'the default window starts at zero');
	is($lim, $Manager::music_window_limit, 'and carries one configured window');
	($off, $lim) = &Manager::music_window_window({ window => { offset => '12', limit => '3' } });
	is($off, 12, 'an offset is taken as given');
	is($lim, 3, 'and so is a limit');
}

# Only the drawn window is probed. 200 local tracks, one window: ffprobe runs
# for the rows that are drawn, not for the queue.
{
	my $tmp = tempdir(CLEANUP => 1);
	make_path("$tmp/Music/Album");
	my @files = map { "$tmp/Music/Album/Track $_.mp3" } (0 .. 199);
	write_file($_, '') for @files;
	# the domain layer autoloads these on first use, which would overwrite the
	# local stubs below; load the real definitions first (t/370 does the same)
	subs::preload('file_media_information');
	my $probes = 0;
	my $crate = do {
		no warnings 'redefine';
		local *subs::config_reader = sub { { manager => { background_colour => 'white' }, name => 'Test', folders => [] } };
		local *subs::setting_grabber = sub {
			my $q = shift;
			return 'Test' if ($q->{'setting'} // '') eq 'computer_name';
			return '';
		};
		local *subs::dark_colour_for = sub { return 'black' };
		local *subs::inventory_grabber = sub { return {} };
		local *subs::cache_get = sub { return {} };
		local *subs::cache_set = sub { return 1 };
		# the probe is the thing being counted; a folder scan of an empty
		# fixture folder need not do anything
		local *Manager::process_thumbfile = sub { };
		local *subs::file_media_information = sub {
			$probes++;
			my $f = shift;
			$f->{'info'} = { duration => '100', tags => {} };
			return $f;
		};
		&Manager::song_maker({
			c => bless({}, 'MusicWindowFakeC'), config => {}, port => 443,
			files => \@files, settings => {
				shuffle => 'off', all_albums => 'no', all_artists => 'no',
				artist => [], album => [], library => 'local', normalize => 'off',
			}, now_playing => {}, same_order => 1,
			window => { offset => 0, limit => 60 },
		});
	};
	is(scalar @{ $crate->{'manifest'} }, 200, 'all 200 local tracks are in the manifest');
	is(scalar @{ $crate->{'songs'} }, 60, 'but only 60 are drawn');
	is($probes, 60, 'and ffprobe runs 60 times, once per drawn row');
	ok(!$crate->{'manifest'}->[100]->{'probed'}, 'a row outside the window is not probed');
}

# ------------------------------------------------------ the player reads the queue
my ($tree) = $js =~ /(function treeMaker\(\)\s*\{.*?\n\}\s*\ntreeMaker\(\);)/s;
ok(defined $tree, 'treeMaker is found');
like($tree // '', qr/musicManifestRead\(\)/, 'it builds from the manifest');
like($tree // '', qr/\$\.each\(entries,/,
	'whose entries, not the mounted .file rows, are the queue');
like($tree // '', qr/var keys = \[\];\s*for \(var k = 0; k < all\.length; k\+\+\) \{ keys\.push\(musicSongKey\(all\[k\]\)\); \}/,
	'the signature is built from the queue keys');
like($tree // '', qr/var signature = keys\.join\('\\u0001'\);/,
	'as a join of those keys');
unlike($tree // '', qr/keys\.push\(musicKey\(this\)\)/,
	'never from the mounted rows, so a scroll cannot change the signature');

my ($restore) = $js =~ /(if \(method != 'files'\) \{.*?\n\t\t\})/s;
ok(defined $restore, 'the restore block is found');
like($restore // '', qr/musicEntryByKey\(pd\.key\)/,
	'restore resolves the saved key from the queue manifest');
like($restore // '', qr/musicEntryByFile\(pd\.file\)/,
	'and the saved file only as a fallback');
unlike($restore // '', qr/\$\(\x27\.playing\x27\)/,
	'restore no longer reads the .playing row');

my ($title) = $js =~ /(function musicTitleMaker\(object\)\s*\{.*?\n\}\n)/s;
ok(defined $title, 'musicTitleMaker is found');
like($title // '', qr/musicCurrentEntry\(\)/, 'the title reads the current queue entry');
unlike($title // '', qr/\$\(\x27\.playing\x27\)/, 'not the .playing row');

my ($theatre) = $js =~ /(function theatreModeOn\(\)\s*\{.*?\n\}\n)/s;
ok(defined $theatre, 'theatreModeOn is found');
like($theatre // '', qr/musicCurrentEntry\(\)/, 'the theatre cover reads the queue entry');
like($theatre // '', qr/entry\.thumb/, 'and uses its thumb');
unlike($theatre // '', qr/\$\(\x27\.playing\x27\)/, 'not the mounted row');

my ($appointment) = $js =~ /(function musicAppointmentWriter\(type,mute\)\s*\{.*?\n\}\n)/s;
ok(defined $appointment, 'musicAppointmentWriter is found');
like($appointment // '', qr/musicCurrentEntry\(\)/, 'the appointment reads the queue entry');
unlike($appointment // '', qr/\$\(\x27\.track_item\.playing\x27\)/, 'not the playing row');

like($js, qr/musicCurrentEntry\(\) \|\| \{\};\s*\n\s*var chapter_list = chapter_song\.chapters/,
	'mediaMaker takes chapters from the queue entry');
like($js, qr/musicTrackEnrich\(musicSongKey\(chapter_song\)\)/,
	'and asks for the one row when the queue has no chapters yet');

# ---------------------------------------------------------------- the details
like($files_tpl, qr/include \x27apps\/music\/track_rows\x27/,
	'the list renders the shared row partial');
unlike($rows_tpl, qr/include \x27apps\/music\/track_description\x27/,
	'the row partial does not inline the details panel');
like($desc_tpl, qr/class="track_description"/, 'the details partial is still the one card source');
like($routes, qr/template => \x27apps\/music\/track_description\x27/,
	'and the details route renders it on demand');
like($js, qr/var musicDetailCache = \{\};/, 'the client caches a rendered panel by key');
like($js, qr/url: \x27\/music\/details\x27/, 'and fetches it the first time Details is pressed');
like($js, qr/class="track_description music_detail_pending"/, 'with a small waiting state');

# ----------------------------------------------------------- the scroll route
like($routes, qr/post\(\x27\/music\/window\x27/, 'there is a window route');
like($routes, qr/template => \x27apps\/music\/track_rows\x27/, 'which renders the same row partial');
like($routes, qr/&music_window_songs\(/, 'and only the rows it was handed');
my ($window_route) = $routes =~ /(post\(\x27\/music\/window\x27.*?)(?=post\(\x27\/music\/details\x27)/s;
ok(defined $window_route, 'the window route body is found');
unlike($window_route // '', qr/cache_delete|cache_set|setting_setter/,
	'a scroll never rewrites the content cache or the saved settings');
my ($remember) = $library =~ /(sub music_queue_remember\(.*?\n\})/s;
ok(defined $remember, 'music_queue_remember is found');
like($remember // '', qr/\$crate->\{\x27queue\x27\}/,
	'the queue saver stores the whole manifest queue, not the drawn slice');

# A form value arrives as text and Mojo::JSON reads bytes: a track name with an
# accent in the slice made decode_json die, so the window answered no rows and
# the client mounted the empty slice on the first scroll.
{
	my $title = "Caf\x{e9}";
	my $entry = { key => 'k1', file => "Music/$title/Track One.mp3", display_track => $title };
	my $raw = encode_json([$entry]);
	utf8::decode($raw);
	my $c = bless { rows => $raw }, 'MusicWindowParamC';
	my $rows = &Manager::music_json_param($c, 'rows');
	is(ref $rows, 'ARRAY', 'a JSON form value with a non-ASCII title still decodes');
	is($rows->[0]->{'display_track'}, $title, 'and keeps the title intact');
	ok(!defined &Manager::music_json_param($c, 'missing'), 'a missing param decodes to undef');
}
like($window_route // '', qr/&music_json_param\(\$c, \x27rows\x27\)/,
	'the window decodes its rows through the text-safe helper');
like($window_route // '', qr/&music_json_param\(\$c, \x27now_playing\x27\)/,
	'and its now-playing row too');
my ($details_route) = $routes =~ /(post\(\x27\/music\/details\x27.*?)(?=post\(\x27\/music\/folder_toggle\x27)/s;
like($details_route // '', qr/&music_json_param\(\$c, \x27row\x27\)/,
	'the details press decodes its row the same way');

# ---------------------------------------------------------- the client window
like($js, qr/function musicWindowFetch\(start, end, force\)/, 'the client can fetch a slice');
like($js, qr/if \(seq !== s\.seq\) \{ return; \}/,
	'a late reply is discarded by sequence number');
like($js, qr/type: \x27POST\x27,\s*\n\s*dataType: \x27json\x27,\s*\n\s*data: \{\s*\n\s*rows: JSON\.stringify\(rows\)/,
	'it sends the manifest rows it wants drawn');
like($js, qr/new ResizeObserver/, 'and re-measures when the window resizes');
like($js, qr/off\('scroll\.musicwindow'\)\.on\('scroll\.musicwindow'/, 'and follows the list scroll on the scroller itself');
like($js, qr/offset: start,/, 'and tells the server where the slice starts');
like($js, qr/scrollTop\(0\)/, 'a search returns the list to the top');

# the cached shell carries the initial slice and the manifest, never a stale view
my ($cache) = $js =~ /(function musicContentCache\(html\)\s*\{.*?\n\}\n)/s;
ok(defined $cache, 'musicContentCache is found');
like($cache // '', qr/#music_window/, 'it looks at the window');
like($cache // '', qr/window_shell\.empty\(\)/,
	'and drops a slice that was scrolled away before storing it');
like($cache // '', qr/track_description\x27\)\.remove\(\)/,
	'so an open details panel is not frozen into the shell');

like($css, qr/#music \.music_track \{[^}]*content-visibility: auto;/s,
	'a mounted but off-screen row skips its own layout');
like($css, qr/contain-intrinsic-size: auto 74px/, 'with a row-sized placeholder');

done_testing();

package MusicWindowFakeC;
sub param { return undef; }

package MusicWindowParamC;
sub param { my ($self, $name) = @_; return $self->{$name}; }

1;
