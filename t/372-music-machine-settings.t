# tests-for: lib/JawnOS/Domain/Name.pm lib/JawnOS/Domain/Accounting.pm lib/JawnOS/Manager/Part17.pm perl/Music.pl perl/Music/05_library_and_queue.pl perl/Music/07_song_maker.pl perl/Music/08_music_routes.pl perl/gb/01_state_and_defaults.pl

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use File::Slurp qw(read_file);
use Mojo::SQLite;

require "$FindBin::Bin/../perl/Music/05_library_and_queue.pl";
require "$FindBin::Bin/../perl/Music/07_song_maker.pl";
$Manager::music_device = 'computer';

# Music's remembered view belongs to the machine, not its device class. A
# laptop and a table are both 'computer', so sharing a row made the table's
# layout, shuffle, search and repeat the laptop's. These are the pieces the
# settings gate and the music routes share.
#
# The database tests write only to a throwaway SQLite file this test creates,
# so they never touch the live database.

my $machine = 'aaaabbbbccccddddeeeeffff00001111';
$gb::signatorial = $machine;

ok(&subs::setting_app_is_machine('music'), 'music settings are the machine\'s');
ok(&subs::setting_app_is_machine('music_folder_toggle'), 'the lit folder buttons are too');
ok(!&subs::setting_app_is_machine('gallery'), 'other apps still follow the device class');
is(&subs::setting_machine_device(), $machine, 'the machine key is the signatorial');

ok(&subs::setting_device_is_signatorial($machine), 'a signatorial is a machine key');
ok(!&subs::setting_device_is_signatorial('computer'), 'a device class is not');
ok(!&subs::setting_device_is_signatorial('all'), 'the house row is not');

# ------------------------------------------------ local first, archive fallback
my @house_folders = ( '~/Music', '~/Downloads', '~/Videos', '~/Pictures', '~/Documents' );
my $roots = &Manager::music_location_roots({ computer => { music_location => '~/Music' } }, \@house_folders);
is($roots->{'music'}, &subs::home('~/Music'), 'a configured location is the root');
is($roots->{'video'}, &subs::home('~/Videos'), 'an unset location falls back to the house folder named Videos');
ok(!defined $roots->{'rec'}, 'a location with no configured or conventional folder has no root');

my $parts = &Manager::music_local_parts(&subs::home('~/Videos/Friends/S01E01.mkv'), $roots);
is($parts->{'location'}, 'video', 'a local file resolves to its location');
is($parts->{'relative'}, 'Friends/S01E01.mkv', 'and its path inside the location');
$parts = &Manager::music_local_parts(&subs::home('~/Documents/Scans/a.pdf'),
	{ document => &subs::home('~/Documents'), scan => &subs::home('~/Documents/Scans') });
is($parts->{'location'}, 'scan', 'the longest matching local root wins');

my $arch = &Manager::music_archive_parts('/mnt/archive_drive/Videos/Friends', [ { archive_dir => '/mnt/archive_drive' } ]);
is($arch->{'location'}, 'video', 'an archive path names its location');
is($arch->{'relative'}, 'Friends', 'and the path inside it');
ok(!&Manager::music_archive_parts('/mnt/other/Videos/Friends', [ { archive_dir => '/mnt/archive_drive' } ]),
	'a path under no advertised drive does not resolve');

my $plan = &Manager::music_selection_plan([ { path => '/mnt/archive_drive/Videos/Friends' } ], $roots,
	[ { archive_dir => '/mnt/archive_drive' } ]);
is($plan->{'walk'}->[0], &subs::home('~/Videos/Friends'), 'an archive pick walks the local counterpart');
is($plan->{'archive'}->[0]->{'location'}, 'video', 'and asks the archive for the same location');
is($plan->{'archive'}->[0]->{'relative'}, 'Friends', 'down to the same folder');

$plan = &Manager::music_selection_plan([ { path => &subs::home('~/Videos/Friends') } ], $roots,
	[ { archive_dir => '/mnt/archive_drive' } ]);
is($plan->{'walk'}->[0], &subs::home('~/Videos/Friends'), 'a local pick walks the local folder');
is($plan->{'archive'}->[0]->{'relative'}, 'Friends', 'and still asks the archive for what is missing');

my @budget = &Manager::music_budget_files([ 'local/a', 'archive/b', 'local/c' ], { 'archive/b' => 1 }, 2);
is_deeply(\@budget, [ 'local/a', 'local/c' ], 'the budget is spent on local files first');
@budget = &Manager::music_budget_files([ 'local/a', 'archive/b', 'local/c' ], { 'archive/b' => 1 }, 3);
is_deeply(\@budget, [ 'local/a', 'local/c', 'archive/b' ], 'a free slot then takes the archived fallback');

# ---------------------------------------------------------------- a scratch DB
my ($fh, $dbfile) = tempfile('jawnos-music-machine-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text, seed text)');
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;

my $now = &subs::rightNow();
my $put = sub {
	my ($app, $setting, $value, $device, $when, $uuid, $seed) = @_;
	&subs::db_insert('settings', {
		app => $app, setting => $setting, value => $value, device => $device,
		timestamp => $when, server_time => $when,
		uuid => ($uuid || &subs::random_string_creator(20)),
		(defined $seed ? (seed => $seed) : ()),
	});
};
my $get = sub {
	my ($app, $setting, $device) = @_;
	my $rows = $db->query('select value, device, server_time from settings where app = ? and setting = ? and device = ? order by id',
		$app, $setting, $device)->hashes;
	return $rows->[-1];
};

# --------------------------------------------------------------- a local write
&subs::setting_setter({ app => 'music', setting => 'shuffle', value => 'on', timestamp => $now });
my $shuffle = &$get('music', 'shuffle', $machine);
ok($shuffle, 'a local Music write lands on the machine row');
is($shuffle->{'value'}, 'on', 'carrying the value');
is(&$get('music', 'shuffle', 'computer'), undef, 'and not on the shared computer row');

# a peer replay keeps the device it arrived with, even for a machine app
&subs::setting_setter({ app => 'music', setting => 'shuffle', value => 'off', device => 'computer', sync => 1, timestamp => $now });
is(&$get('music', 'shuffle', 'computer')->{'value'}, 'off', 'a synced peer row keeps its own key');

# a plain app is still the device class
&subs::setting_setter({ app => 'gallery', setting => 'sort', value => 'name', timestamp => $now });
ok(&$get('gallery', 'sort', 'computer'), 'an unlisted app stays on the device class');

# ------------------------------------------------------- read: machine first
$put->('music', 'layout', 'grid', $machine, $now - 2000);
$put->('music', 'layout', 'list', 'computer', $now + 2000);
is(&subs::setting_grabber({ app => 'music', setting => 'layout' }), 'grid',
	'the machine row wins even when the class row is newer');

$put->('music', 'search', 'friends', 'computer', $now);
is(&subs::setting_grabber({ app => 'music', setting => 'search' }), 'friends',
	'a machine with no row of its own falls back to the class row');

# a blank machine value is an answer, not a missing row
$put->('music', 'search', '', $machine, $now + 3000);
is(&subs::setting_grabber({ app => 'music', setting => 'search' }), '',
	'an empty machine value is not replaced by the class row');

# ------------------------------------------------------ read: merged settings
$put->('music', 'uuid', 'class-uuid', 'computer', $now);
$put->('music', 'repeat', 'off', 'computer', $now);
$put->('music', 'repeat', 'on', $machine, $now + 1000);
my $settings = &subs::settings_grabber({ app => 'music' });
is($settings->{'repeat'}, 'on', 'the settings hash prefers the machine value');
is($settings->{'search'}, '', 'and keeps a blank machine value');
is($settings->{'uuid'}, 'class-uuid', 'but fills what the machine has never written');

# ------------------------------------------------------ the Music folder buttons
&subs::setting_setter({ app => 'music_folder_toggle', setting => 'video_location', value => 'on', timestamp => $now });
ok(&$get('music_folder_toggle', 'video_location', $machine), 'a lit folder button is the machine\'s');
is(&$get('music_folder_toggle', 'video_location', 'computer'), undef, 'not the class\'s');

# ------------------------------------------------------------------- backfill
$put->('music', 'normalize', 'mild', 'computer', $now - 5000);
$put->('music_folder_toggle', 'music_location', 'on', 'computer', $now - 5000);
my $backfill = &subs::backfills()->{'music_settings_per_machine'};
ok($backfill, 'the per-machine Music backfill is registered');
$backfill->();
is(&$get('music', 'normalize', $machine)->{'value'}, 'mild', 'the backfill copies the class value onto the machine');
is(&$get('music_folder_toggle', 'music_location', $machine)->{'value'}, 'on', 'and the folder buttons too');

$backfill->();
my $n = $db->query("select count(*) as n from settings where app = 'music' and setting = 'normalize' and device = ?", $machine)->hashes->[0]->{'n'};
is($n + 0, 1, 'running the backfill again does not make a second machine row');

# a machine row already present is left alone
$put->('music', 'normalize', 'aggressive', $machine, $now + 5000);
$backfill->();
is(&$get('music', 'normalize', $machine)->{'value'}, 'aggressive', 'a machine choice is not overwritten by the class copy');

# ------------------------------------- a relayed search does not save on the host
my $routes = read_file("$FindBin::Bin/../perl/Music/08_music_routes.pl");
like($routes, qr/my \$remote_render = .*'remoted'.*eq 'yes'/,
	'a relayed search is recognised as a render for another window');
like($routes, qr/unless \(\$remote_render\) \{\s*foreach my \$ns \( keys %\{\$new_settings\} \)\s*\{\s*&subs::setting_setter/s,
	'and its shuffle and layout are not written onto the library host');
unlike($routes, qr/music_folder_toggle', setting => \$location, device => \$music_device/,
	'the folder read follows the machine key rather than the device class');
like($routes, qr/music_folder_toggle', setting => \$location, value => \$status, timestamp => \$timestamp \}\) unless \$remote_render/,
	'a relayed folder click is not saved on the library host');
like($routes, qr/music', setting => 'archive', value => \$status, timestamp => \$c->param\('timestamp'\) \}\) unless \$remote_render/,
	'and neither is a relayed archive click');
my $library = read_file("$FindBin::Bin/../perl/Music/05_library_and_queue.pl");
unlike($library, qr/music_folder_toggle', setting => \$s, device => \$music_device/,
	'and so does the folder walk');
like($library, qr/my %local_keys;/, 'the listing keys the copies it found on this disk');
like($library, qr/next if \$local_keys\{/, 'and leaves the matching archive row out');
my $maker = read_file("$FindBin::Bin/../perl/Music/07_song_maker.pl");
like($maker, qr/\@local_files = &music_budget_files\(\\\@local_files, \$archive, \$max_files\);/,
	'the player budget is spent on local files before archived ones');
my $main = read_file("$FindBin::Bin/../perl/Music.pl");
like($main, qr/my \$remote_render = .*'remoted'.*eq 'yes'/,
	'a relayed open is recognised too');
like($main, qr/unless \(\$remote_render\) \{\s*&subs::cache_set/s,
	'and its shell is not cached over the host\'s own');

done_testing();
