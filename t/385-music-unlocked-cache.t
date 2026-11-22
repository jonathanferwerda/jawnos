# tests-for: public/js/music.js perl/Music.pl perl/Music/05_library_and_queue.pl perl/Music/08_music_routes.pl
# covers:    A window holding a media grant is never cached. The player cache,
#            the content shell and the remembered queue are all left untouched
#            while unlocked, because the grant dies with the window and a stored
#            view could only be replayed into a window that may no longer list
#            those tracks.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $music   = read_file("$FindBin::Bin/../public/js/music.js");
my $musicpl = read_file("$FindBin::Bin/../perl/Music.pl");
my $queue   = read_file("$FindBin::Bin/../perl/Music/05_library_and_queue.pl");
my $routes  = read_file("$FindBin::Bin/../perl/Music/08_music_routes.pl");

# --- the queue is not remembered while unlocked -----------------------------
my ($remember) = $queue =~ /(sub music_queue_remember\(.*?\n\})/s;
ok(defined $remember, 'music_queue_remember is found');
like($remember // '', qr/\breturn undef if \$permissive;/,
	'an unlocked render stores no queue, leaving the previous locked one in place');

# --- the content shell is not written while unlocked ------------------------
my $open_guard = index($musicpl, 'unless ($remote_render || $unlocked)');
my $open_set   = index($musicpl, "cache_set({ app => 'music', context => 'content'");
ok($open_guard >= 0, 'the music open conditions its shell write on !$unlocked');
ok($open_set > $open_guard, 'and the shell cache_set sits inside that guard');

# --- /music/search clears and writes no shell while unlocked ----------------
like($routes,
	qr/cache_delete\(\{ app => 'music', context => 'content' \}\) unless \$remote_render \|\| \$unlocked;/,
	'a search does not clear the content cache while the window is unlocked');
like($routes,
	qr/cache_set\(\{ app => 'music', context => 'content'.*unless \$remote_render \|\| \$unlocked;/,
	'a search does not write the content shell while the window is unlocked');

# --- the client helper and its guards ---------------------------------------
like($music,
	qr/function musicUnlocked\(\) \{ return !!\(\$\('#music'\)\.attr\('unlock'\)\); \}/,
	'the client has an unlocked test that reads the window grant');
like($music, qr/function musicContentCache\(html\) \{\n\tif \(musicUnlocked\(\)\) \{ return; \}/,
	'a content-shell save returns before doing any work while unlocked');
my ($saver) = $music =~ /(function playerCacheSaver\(type, force\)\s*\{.*?\n\})/s;
ok(defined $saver, 'playerCacheSaver is found');
my $player_guard = index($saver // '', 'if (musicUnlocked())');
my $player_set   = index($saver // '', 'cacheSet(');
ok($player_guard >= 0 && $player_set >= 0 && $player_guard < $player_set,
	'the player cache saver returns before any cacheSet while unlocked');

done_testing();
