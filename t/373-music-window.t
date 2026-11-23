# tests-for: templates/apps/music/files.html.ep templates/apps/music/track_rows.html.ep templates/apps/music/track_description.html.ep public/js/music.js public/css/music.css perl/Music/05_library_and_queue.pl perl/Music/07_song_maker.pl perl/Music/08_music_routes.pl perl/Music.pl lib/JawnOS/Manager/Part28.pm public/js/manager/help/01_music_speech.js
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
use File::Temp qw(tempdir tempfile);
use JawnOSTest;

require "$FindBin::Bin/../perl/Music/05_library_and_queue.pl";
require "$FindBin::Bin/../perl/Music/06_track_naming.pl";
require "$FindBin::Bin/../perl/Music/07_song_maker.pl";
require JawnOS::Manager::Part28;

my $root = root();
my $js   = read_file("$root/public/js/music.js");
my $css  = read_file("$root/public/css/music.css");
my $files_tpl = read_file("$root/templates/apps/music/files.html.ep");
my $rows_tpl  = read_file("$root/templates/apps/music/track_rows.html.ep");
my $desc_tpl  = read_file("$root/templates/apps/music/track_description.html.ep");
my $routes    = read_file("$root/perl/Music/08_music_routes.pl");
my $musicpl   = read_file("$root/perl/Music.pl");
my $library   = read_file("$root/perl/Music/05_library_and_queue.pl");
my $part28    = read_file("$root/lib/JawnOS/Manager/Part28.pm");
my $help_js   = read_file("$root/public/js/manager/help/01_music_speech.js");

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

# ---------------------------------------------- the playing track comes back
# A refresh can rebuild the list from a queue or a saved search that does not
# hold the track that is playing. The open route hands that rebuild the live
# player cache, so song_maker adds the track (and marks its row) instead of
# leaving the player without a row for what it is playing.
{
	my @files = map { "Videos/Show/Episode $_ .mp4" } (0 .. 9);
	my $playing = 'Videos/Show/Bonus.mp4';
	my %archive = map { $_ => {
		type => 'video', info => { duration => '60', tags => {} },
		remote_uuid => '', remote_hostname => '',
	} } (@files, $playing);
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
			c => bless({}, 'MusicWindowFakeC'), config => {}, port => 443,
			files => \@files, archive => \%archive,
			settings => { shuffle => 'off', all_albums => 'no', all_artists => 'no',
				artist => [], album => [], library => 'local', normalize => 'off' },
			now_playing => { file => $playing }, same_order => 1,
			window => { offset => 0, limit => 60 },
		});
	};
	is($crate->{'queue'}->[0], $playing, 'a queue that did not hold the playing track gains it first');
	is($crate->{'queue_total'}, scalar(@files) + 1, 'and the rest of the queue is kept');
	is($crate->{'songs'}->[0]->{'filename'}, $playing, 'its row is drawn in the first window');
	is($crate->{'songs'}->[0]->{'playing'}, 'yes', 'and marked as playing');
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
like($js, qr/function musicWindowFetch\(start, end, force, done\)/, 'the client can fetch a slice');
like($js, qr/if \(seq !== s\.seq\) \{ finish\(\); return; \}/,
	'a late reply is discarded by sequence number, settling its waiter');
like($js, qr/type: \x27POST\x27,\s*\n\s*dataType: \x27json\x27,\s*\n\s*data: \{\s*\n\s*rows: JSON\.stringify\(rows\)/,
	'it sends the manifest rows it wants drawn');
like($js, qr/new ResizeObserver/, 'and re-measures when the window resizes');
like($js, qr/off\('scroll\.musicwindow'\)\.on\('scroll\.musicwindow'/, 'and follows the list scroll on the scroller itself');
like($js, qr/offset: start,/, 'and tells the server where the slice starts');
like($js, qr/scrollTop\(0\)/, 'a search returns the list to the top');
# a scroll asks for the next batch while the last mounted titles are still on
# screen: two screens of lead, with two screens behind and four ahead so the
# next fetch is not due immediately after the reply
like($js, qr/var margin = visible \* 2 \* s\.columns;/,
	'it asks for the next slice two screens before the end');
like($js, qr/var start = Math\.max\(0, topIndex - visible \* 2 \* s\.columns\);/,
	'mounting the slice two screens behind the viewport');
like($js, qr/var end = Math\.min\(s\.total, topIndex \+ visible \* 4 \* s\.columns\);/,
	'and four screens ahead, so the next fetch has the same lead');

# ------------------------------------------------- a slice of mixed row heights
# The pitch sizes the padding over rows that are NOT mounted, so it must not
# move when a mounted row grows. It is the shortest row with no details panel
# open plus the gap, and it is only re-measured when the layout itself moves.
like($js, qr/function musicWindowPitch\(rows, gap\)/, 'the pitch has one pure helper');
like($js, qr/function musicWindowRowAt\(count, bottomAt, topY, guess\)/, 'the top row has one pure helper');
my ($measure) = $js =~ /(function musicWindowMeasure\(\)\s*\{.*?\n\})/s;
ok(defined $measure, 'musicWindowMeasure is found');
like($measure // '', qr/rows\.push\(row_open \? 0 : row_h\)/,
	'a row with an open panel is not a baseline row');
like($measure // '', qr/var candidate = musicWindowPitch\(rows, s\.gap\)/,
	'the pitch is the shortest closed row plus the gap');
like($measure // '', qr/if \(signature !== s\.measuredFor\)/,
	'it re-measures only when the layout signature moves');
like($measure // '', qr/s\.measuredFor = signature/, 'and records the layout it measured for');
unlike($measure // '', qr/cards\[s\.columns\]\.getBoundingClientRect\(\)\.top - cards\[0\]/,
	'the first-two-rows comparison is gone');
my ($sync) = $js =~ /(function musicWindowSync\(\)\s*\{.*?\n\})/s;
ok(defined $sync, 'musicWindowSync is found');
like($sync // '', qr/musicWindowRowAt\(cards\.length/,
	'scroll maps through the real card edges');
unlike($sync // '', qr/rowDelta \* s\.columns/, 'not by dividing scrollTop by the pitch');
my ($apply) = $js =~ /(function musicWindowApply\(\)\s*\{.*?\n\})/s;
ok(defined $apply, 'musicWindowApply is found');
like($apply // '', qr/before_rows \* s\.pitch/, 'the padding is offset rows at the one stable pitch');
unlike($apply // '', qr/getBoundingClientRect/, 'not the mounted rows\x27 real heights');
like($js, qr/function musicWindowAnchor\(\)/, 'a slice swap captures its top row');
like($js, qr/function musicWindowRestoreAnchor\(anchor, start\)/, 'and puts it back');
like($js, qr/musicWindowRestoreAnchor\(anchor, start\);\s*\n\s*finish\(\);\s*\n\s*\/\/ a scroll that arrived/,
	'after the new slice is padded and its rows are restored');

# A scroll fetch can be overtaken while it is in flight. The row the person is
# reading must stay put, so a reply that no longer covers it is not drawn; a
# slice centred on that row is asked for instead. A forced restore must land.
my ($fetch) = $js =~ /(function musicWindowFetch\(start, end, force, done\)\s*\{.*?\n\})/s;
ok(defined $fetch, 'musicWindowFetch is found for the restore contract');
like($fetch // '', qr/var finish = function \(\) \{/,
	'every exit path settles the restore waiter');
my $success_at = index($fetch // '', 'success: function (r)');
ok($success_at >= 0, 'its success handler is found');
my $success = substr($fetch // '', $success_at);
like($success, qr/musicWindowAnchorCovered\(anchor, start, end\)/,
	'a reply that no longer covers the row being read is not drawn');
like($success, qr/musicWindowFetch\(again_start, again_end, true, done\)/,
	'it asks again for a slice centred on that row and keeps the mounted one');
my $error_at = index($fetch // '', 'error: function');
ok($error_at >= 0, 'its error handler is found');
like(substr($fetch // '', $error_at), qr/finish\(\);/,
	'and a failed request still settles the waiter');
like($js, qr/function musicWindowAnchorCovered\(anchor, start, end\)/,
	'the coverage of a slice by the row being read is one pure helper');
# The sync is bidirectional: at a restored offset above zero, nearing the top
# requests rows below the mounted slice (topIndex - visible), not just more
# below it.
like($sync // '', qr/var nearTop = s\.offset > 0 && topIndex < s\.offset \+ margin;/,
	'a restored slice asks upward when the viewport nears its top');
like($sync // '', qr/var start = Math\.max\(0, topIndex - visible \* 2 \* s\.columns\);/,
	'and the request can reach rows above the mounted slice');
like($sync // '', qr/var visible = musicWindowVisible\(\);/,
	'the sync and a re-fetch share the visible-row count');

# ------------------------------------------------ a list hidden by the theatre
# The theatre hides #music_library. A hidden list has no heights, so every rect
# read zero and the "top row" came out as the last mounted row: the sync shrank
# the slice to a handful of rows, and the saved view pointed the next open at the
# bottom of it. Leaving the theatre then fetched and probed a whole new window -
# the list that took 20-30s - while the track being watched sat outside it. All
# of that work now waits for a list that is really on screen.
like($js, qr/function musicWindowShown\(\)/, 'the window has one "list on screen" test');
like($sync // '', qr/!musicWindowShown\(\)/, 'a sync does no work on a hidden list');
my ($hidden_anchor) = $js =~ /(function musicWindowAnchor\(\)\s*\{.*?\n\})/s;
ok(defined $hidden_anchor, 'musicWindowAnchor is found');
like($hidden_anchor // '', qr/!musicWindowShown\(\)/, 'a hidden list has no top row to name');
my ($hidden_view) = $js =~ /(function musicViewOf\(\)\s*\{.*?\n\})/s;
ok(defined $hidden_view, 'musicViewOf is found');
like($hidden_view // '', qr/!musicWindowShown\(\)/, 'a hidden list saves no view');
like($hidden_view // '', qr/musicViewLast = view;/, 'a measured view is remembered');
my ($hidden_saver) = $js =~ /(function playerCacheSaver\(type, force\)\s*\{.*?\n\})/s;
ok(defined $hidden_saver, 'playerCacheSaver is found');
like($hidden_saver // '', qr/view: \(musicViewOf\(\) \|\| musicViewLast\)/,
	'a save through a hidden list keeps the last honest view');
my ($hidden_winit) = $js =~ /(function musicWindowInit\(restore\)\s*\{.*?\n\})/s;
ok(defined $hidden_winit, 'musicWindowInit is found');
like($hidden_winit // '', qr/s\.restoreView = view;/,
	'a saved view waits for a list that can measure it');
like($sync // '', qr/if \(s\.restoreView\)/,
	'and the sync applies it once the list is shown');

# An empty rebuild must not abort the rest of the window's init
my ($hidden_init) = $js =~ /(async function musicInit\(method\)\s*\{.*?\n\})/s;
ok(defined $hidden_init, 'musicInit is found');
like($hidden_init // '', qr/!tree\.all_songs\.length && pd\.file/,
	'an empty queue is described from the player cache');
like($js, qr/var playing_row = tree\.songs\[0\] \|\| \{\};/,
	'and mediaMaker no longer dereferences a missing row');

# The open route rebuilds from the live player cache -------------------------
# A refresh that misses the shell has no list yet, and the track being watched
# must not lose its row (or its mark) to the rebuild. A relayed render is the
# host's own player, not the viewer's, so it is not passed.
like($musicpl, qr/my \$player = &subs::cache_get\(\{ app => 'music', context => 'player' \}\);/,
	'the open reads the live player cache');
like($musicpl, qr/now_playing => \$now_playing/, 'and hands it to the rebuild');
like($musicpl, qr/if \(!\$remote_render && \(\(\$settings->\{'library'\} \|\| 'local'\) eq 'local'\)/,
	'a relayed render keeps the host player out');

# The arithmetic is pure, so its two shapes are driven with plain numbers: a
# wrapped title or an open panel must not change the pitch, and a mixed slice
# must name the row that really covers the top edge.
my ($math) = $js =~ m{// \[\[music-window-math\]\](.*?)// \[\[/music-window-math\]\]}s;
ok(defined $math && $math =~ /function musicWindowPitch/, 'the window math is marked for the runtime check');
my $node = qx{command -v node 2>/dev/null};
chomp $node;
SKIP: {
	skip 'node is not installed', 1 unless $node && defined $math;
	my $script = <<"JS";
$math
function fail(message) { console.error(message); process.exit(1); }
if (musicWindowPitch([74, 74], 4) !== 78) { fail('baseline rows: ' + musicWindowPitch([74, 74], 4)); }
if (musicWindowPitch([140, 74, 74], 4) !== 78) { fail('a wrapped title raised the pitch'); }
if (musicWindowPitch([0, 74, 0], 4) !== 78) { fail('an open panel row was measured'); }
if (musicWindowPitch([0, 0], 4) !== 0) { fail('no closed row must say no measurement'); }
var bottoms = [78, 218, 296, 374];
function bottomAt(i) { return bottoms[i]; }
if (musicWindowRowAt(4, bottomAt, 0, 0) !== 0) { fail('top of the list'); }
if (musicWindowRowAt(4, bottomAt, 100, 0) !== 1) { fail('after a taller first row: ' + musicWindowRowAt(4, bottomAt, 100, 0)); }
if (musicWindowRowAt(4, bottomAt, 100, 3) !== 1) { fail('the scan did not retreat to the real row'); }
if (musicWindowRowAt(4, bottomAt, 250, 1) !== 2) { fail('the scan did not advance past a shorter row'); }
if (musicWindowRowAt(4, bottomAt, 500, 0) !== 3) { fail('past the last bottom did not name the last row'); }
if (musicWindowRowAt(0, bottomAt, 0, 0) !== 0) { fail('an empty slice'); }
process.exit(0);
JS
	my ($fh, $file) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print {$fh} $script;
	close $fh;
	my $rc = system($node, $file);
	is($rc, 0, 'a mixed-height slice keeps one pitch and names the real top row');
}

# The coverage test is pure too: a slice covers only the rows it mounts.
my ($covered) = $js =~ /(function musicWindowAnchorCovered\(anchor, start, end\)\s*\{.*?\n\})/s;
ok(defined $covered, 'the coverage helper is marked for the runtime check');
SKIP: {
	skip 'node is not installed', 1 unless $node && defined $covered;
	my $script = <<"JS";
$covered
function fail(message) { console.error(message); process.exit(1); }
if (musicWindowAnchorCovered({ index: 5, top: 0 }, 0, 10) !== true) { fail('inside the slice'); }
if (musicWindowAnchorCovered({ index: 0, top: 0 }, 0, 10) !== true) { fail('at the first row'); }
if (musicWindowAnchorCovered({ index: 10, top: 0 }, 0, 10) !== false) { fail('the end is excluded'); }
if (musicWindowAnchorCovered(null, 0, 10) !== false) { fail('no anchor'); }
if (musicWindowAnchorCovered({ index: NaN, top: 0 }, 0, 10) !== false) { fail('an unusable index'); }
process.exit(0);
JS
	my ($fh, $file) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print {$fh} $script;
	close $fh;
	my $rc = system($node, $file);
	is($rc, 0, 'a slice covers only the rows it mounts');
}

# ------------------------------------------------ the manifest walk per list
# The parsed manifest is the whole queue, so it must be parsed once per list
# and not copied per call. musicManifestRead caches on the element and its
# token; treeMaker returns on the manifest object before the per-song walk.
my ($manifest) = $js =~ /(function musicManifestRead\(\)\s*\{.*?\n\})/s;
ok(defined $manifest, 'musicManifestRead is found');
like($manifest // '', qr/if \(el === musicManifestEl && token === musicManifestToken\) \{ return musicManifestCache; \}/,
	'the manifest is parsed once per element and token');
like($manifest // '', qr/musicManifestCache = \(data && Array\.isArray\(data\.songs\)\) \? data : null;/,
	'and the parsed queue is the cache');
my ($detail_fetch) = $js =~ /(function musicDetailsFetch\(key, card\)\s*\{.*?\n\})/s;
ok(defined $detail_fetch, 'musicDetailsFetch is found');
unlike($detail_fetch // '', qr/musicManifestRead|JSON\.parse/,
	'opening a panel reads the cached queue, not the manifest again');
my ($tree_body) = $js =~ /(function treeMaker\(\)\s*\{.*?\n\}\s*\ntreeMaker\(\);)/s;
ok(defined $tree_body, 'treeMaker is found for the walk check');
my $early = index($tree_body // '', 'if (prev && entries && prev.manifest_entries === entries) {');
my $walk  = index($tree_body // '', 'var all = [];');
my $join  = index($tree_body // '', 'var signature = keys.join');
ok($early >= 0 && $walk > $early,
	'a treeMaker call returns on the manifest identity before walking the queue');
ok($join > $early, 'and before copying the keys for the signature');

# the cached shell carries the initial slice and the manifest, never a stale view
my ($cache) = $js =~ /(function musicContentCache\(html\)\s*\{.*?\n\}\n)/s;
ok(defined $cache, 'musicContentCache is found');
like($cache // '', qr/#music_window/, 'it looks at the window');
like($cache // '', qr/window_shell\.empty\(\)/,
	'and drops a slice that was scrolled away before storing it');
like($cache // '', qr/track_description\x27\)\.remove\(\)/,
	'so an open details panel is not frozen into the shell');
like($cache // '', qr/music_window_open/,
	'and the card class the pitch reader skips goes with it');

# ------------------------------------------- the guide's play-all is a queue
# "play Friends" hands the player every match, but only max_files of them: the
# list is sliced before it becomes the queue, so the UI never draws or plays an
# unbounded match set. `found` still counts every match for the answer.
my ($play) = $part28 =~ /(sub help_music_file\(.*?\n\})/s;
ok(defined $play, 'help_music_file is found');
like($play // '', qr/my \$max = .*setting_grabber\(\{ app => \x27misc\x27, setting => \x27max_files\x27 \}\) \|\| 30;/,
	'the guide clamps the handed queue to max_files');
like($play // '', qr/\@all = \@all\[0 \.\. \$max - 1\] if scalar \@all > \$max;/,
	'and hands over only that many files');
like($help_js, qr/var list = \(r\.files && r\.files\.length\) \? r\.files : \[r\.file\];/,
	'the client opens that bounded list as the queue');
{
	my @every = map { sprintf('Music/Friends/Season 1/Episode %03d.mp4', $_) } (1 .. 120);
	my $r = do {
		no warnings 'redefine';
		local *Manager::music_search = sub { return { files => [ @every ] } };
		local *Manager::misc_setting_list = sub { return { local => { local_location => '/Music' } } };
		local *Manager::help_media_revealed = sub { return 0 };
		local *Manager::media_unlock_device = sub { return 'device' };
		local *subs::settings_grabber = sub {
			my $q = shift;
			return (($q->{'app'} // '') eq 'misc' && ($q->{'setting'} // '') eq 'max_files') ? 30 : {};
		};
		local *subs::device_setter = sub { return 'local' };
		&Manager::help_music_file(bless({}, 'MusicHelpFakeC'), 'friends', 0);
	};
	is($r->{'found'}, 120, 'every match is counted');
	is(scalar @{ $r->{'files'} }, 30, 'but the queue carries max_files, not every match');
	is($r->{'files'}->[0], $every[0], 'and the best match leads');
	is($r->{'same_order'}, 0, 'an unshuffled request keeps the ranked order');
}

like($css, qr/#music_files \{[^}]*overflow-anchor: none;/s,
	'the list disables the browser\'s own scroll anchoring');
like($css, qr/#music_window \{[^}]*overflow-anchor: none;/s,
	'and so does the slice it mounts');
unlike($css, qr/#music \.music_track \{[^}]*content-visibility/s,
	'a mounted row lays out at its real height, so a new slice cannot measure short');
unlike($css, qr/contain-intrinsic-size/,
	'and no intrinsic placeholder stands in for a row that is about to render');

done_testing();

package MusicWindowFakeC;
sub param { return undef; }

package MusicWindowParamC;
sub param { my ($self, $name) = @_; return $self->{$name}; }

package MusicHelpBase;
sub new { bless {}, shift }
sub port { 443 }
package MusicHelpURL;
sub new { bless {}, shift }
sub base { MusicHelpBase->new }
package MusicHelpReq;
sub new { bless {}, shift }
sub url { MusicHelpURL->new }
package MusicHelpFakeC;
sub req { MusicHelpReq->new }

1;
