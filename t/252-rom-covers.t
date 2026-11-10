# tests-for: lib/JawnOS/RomCovers.pm scripts/rom_covers.pl
# covers:    The cover lookup: libretro's folder names, the listing parse, the
#            canonical title key that survives regions and revisions, the
#            matcher that prefers a USA box art, and the atomic PNG write.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use RepoSource;
use JawnOS::Games;
use JawnOS::RomCovers;

my $root = repo_root();

# --- the folder map -----------------------------------------------------------
my %systems = %{ JawnOS::Games::systems() };
my @mapped = grep { defined JawnOS::RomCovers::folder_for($_) } sort keys %systems;
ok(scalar(@mapped) >= 20, 'most known systems have a thumbnail folder');
foreach my $system (@mapped) {
	ok(length JawnOS::RomCovers::folder_for($system), "$system maps to a folder name");
}
is(JawnOS::RomCovers::folder_for('n64'), 'Nintendo - Nintendo 64', 'the N64 folder is libretro\'s own');
is(JawnOS::RomCovers::folder_for('psx'), 'Sony - PlayStation', 'and the PlayStation folder');
is(JawnOS::RomCovers::folder_for('megadrive'), 'Sega - Mega Drive - Genesis', 'Mega Drive and Genesis share one folder');
ok(!defined JawnOS::RomCovers::folder_for('weird_system'), 'an unknown system has no folder');
ok(!defined JawnOS::RomCovers::thumbnail_url('weird_system', 'x'), 'and no thumbnail URL');

# --- URLs ---------------------------------------------------------------------
is(JawnOS::RomCovers::thumbnail_url('snes', 'Super Mario World (USA)'),
	'https://thumbnails.libretro.com/Nintendo%20-%20Super%20Nintendo%20Entertainment%20System'
	. '/Named_Boxarts/Super%20Mario%20World%20%28USA%29.png',
	'the folder, kind and title are URL-encoded and the box art is the default');
is(JawnOS::RomCovers::thumbnail_url('psx', "Tony Hawk's Pro Skater", 'Named_Titles'),
	'https://thumbnails.libretro.com/Sony%20-%20PlayStation/Named_Titles'
	. '/Tony%20Hawk%27s%20Pro%20Skater.png',
	'an apostrophe and the requested kind are encoded');
like(JawnOS::RomCovers::thumbnail_url('nes', 'Pac-Man & Ms. Pac-Man'),
	qr{/Nintendo%20-%20Nintendo%20Entertainment%20System/Named_Boxarts/Pac-Man%20%26%20Ms\.%20Pac-Man\.png\z},
	'an ampersand is encoded and an inner full stop is kept');
is(JawnOS::RomCovers::listing_url('n64'),
	'https://thumbnails.libretro.com/Nintendo%20-%20Nintendo%2064/Named_Boxarts/',
	'a listing URL ends in a slash so a relative href resolves');

# --- the Apache listing -------------------------------------------------------
my $base = 'https://thumbnails.libretro.com/Nintendo%20-%20Nintendo%2064/Named_Boxarts/';
my $html = <<'HTML';
<a href="Super%20Mario%2064%20(USA).png">Super Mario 64 (USA).png</a>
<a href="Tony%20Hawk%27s%20Pro%20Skater%20(USA).png">Tony Hawk's Pro Skater (USA).png</a>
<a href="Dungeons%20&amp;%20Dragons.png">Dungeons &amp; Dragons.png</a>
<a href="../">Parent Directory</a>
HTML
my $listing = JawnOS::RomCovers::listing_parse($html, $base);
is($listing->{'Super Mario 64 (USA)'}, $base . 'Super%20Mario%2064%20(USA).png',
	'a png href is keyed by its decoded name and valued by its URL');
ok(exists $listing->{"Tony Hawk's Pro Skater (USA)"}, 'a percent-encoded apostrophe is decoded');
is($listing->{'Dungeons & Dragons'}, $base . 'Dungeons%20&%20Dragons.png',
	'&amp; is decoded, so the key and the URL agree');
ok(!exists $listing->{'../'}, 'a parent-directory link is not a cover');

# --- canonical titles ---------------------------------------------------------
my $groups = JawnOS::RomCovers::title_groups('Super Mario 64 (USA) (Rev 1)');
is($groups->{'base'}, 'Super Mario 64', 'the title keeps its name');
is($groups->{'base_key'}, 'super mario 64', 'and its canonical base');
is_deeply($groups->{'regions'}, ['usa'], 'the region becomes one tag');
is_deeply($groups->{'revisions'}, ['rev1'], 'the revision becomes one tag');
is(JawnOS::RomCovers::name_key('Super Mario 64 (USA) (Rev 1)'), 'super mario 64 usa rev1',
	'the key carries region and revision');

$groups = JawnOS::RomCovers::title_groups('Legend of Zelda, The - Ocarina of Time (U) [!]');
is($groups->{'base'}, 'The Legend of Zelda - Ocarina of Time', '"Name, The" moves The to the front');
is_deeply($groups->{'regions'}, ['usa'], '(U) and (USA) normalise to the same region');

$groups = JawnOS::RomCovers::title_groups("Tony Hawk's Pro Skater (U)");
is($groups->{'base_key'}, "tony hawk's pro skater", 'an apostrophe and spaces survive');

$groups = JawnOS::RomCovers::title_groups('Spyro the Dragon (USA)');
is($groups->{'base_key'}, 'spyro the dragon', 'a region is not part of the title');

$groups = JawnOS::RomCovers::title_groups('Super Mario World (USA) (En,Fr,De) (Nintendo)');
is($groups->{'base_key'}, 'super mario world', 'language lists and publishers are ignored');
is_deeply($groups->{'regions'}, ['usa'], 'while the region is still read');

$groups = JawnOS::RomCovers::title_groups('Perfect Dark (U) (V1.1) [!]');
is_deeply($groups->{'revisions'}, ['v1.1'], 'a version group is a revision tag');
is(JawnOS::RomCovers::name_key('Perfect Dark (U) (V1.1) [!]'), 'perfect dark usa v1.1',
	'and appears in the key');

$groups = JawnOS::RomCovers::title_groups('Sonic the Hedgehog! (U)');
is($groups->{'base'}, 'Sonic the Hedgehog', 'a trailing ! is dropped');

$groups = JawnOS::RomCovers::title_groups('Dungeons & Dragons (USA)');
is($groups->{'base_key'}, 'dungeons and dragons', '& reads as and');

# --- matching -----------------------------------------------------------------
is(JawnOS::RomCovers::best_match(['Super Mario 64 (USA) (Rev 1)'], 'Super Mario 64 (USA) (Rev 1)'),
	'Super Mario 64 (USA) (Rev 1)', 'an exact key wins');
is(JawnOS::RomCovers::best_match(
	['Super Mario 64 (Japan)', 'Super Mario 64 (USA) (Rev 1)'], 'Super Mario 64 (Europe)'),
	'Super Mario 64 (USA) (Rev 1)', 'the title ignoring region matches, and USA wins the tie');
is(JawnOS::RomCovers::best_match(
	['Spyro the Dragon (Europe)', 'Spyro the Dragon (USA)'], 'Spyro the Dragon'),
	'Spyro the Dragon (USA)', 'USA box art is preferred');
is(JawnOS::RomCovers::best_match(['Super Mario Bros 3 (USA)'], 'Super Mario Bros. 3'),
	'Super Mario Bros 3 (USA)', 'a title differing only by a full stop matches on its digits');
is(JawnOS::RomCovers::best_match(["Spyro the Dragon - Collector's Edition (USA)"], 'Spyro the Dragon'),
	"Spyro the Dragon - Collector's Edition (USA)", 'a conservative prefix matches an extended title');
ok(!defined JawnOS::RomCovers::best_match(['Sonic the Hedgehog (USA)'], 'Tetris'),
	'a different game never matches');
ok(!defined JawnOS::RomCovers::best_match([], 'Tetris'), 'an empty listing matches nothing');

# --- the atomic write ---------------------------------------------------------
my $dir = tempdir(CLEANUP => 1);
my $png = "\x89PNG\r\n\x1a\n" . 'payload';
my $dest = "$dir/images/cover.png";
my $seen;
my $answer = JawnOS::RomCovers::cover_fetch('http://example.test/cover.png', $dest,
	sub { $seen = $_[0]; $png });
ok($answer->{'ok'}, 'a PNG is stored');
is($seen, 'http://example.test/cover.png', 'the fetcher is handed the URL');
ok(-f $dest, 'the file exists');
is(read_file($dest), $png, 'with the bytes that were fetched');
ok(!-e "$dest.tmp.$$", 'and no temporary is left behind');

my $bad = "$dir/bad.png";
$answer = JawnOS::RomCovers::cover_fetch('http://example.test/bad', $bad, sub { 'not a png' });
ok(!$answer->{'ok'}, 'bytes that are not a PNG are refused');
ok(!-e $bad, 'and nothing is written');
ok(!-e "$bad.tmp.$$", 'no temporary is left for a refused file');

write_file($dest, 'old');
$answer = JawnOS::RomCovers::cover_fetch('http://example.test/cover.png', $dest, sub { $png });
ok($answer->{'ok'} && $answer->{'skipped'}, 'an existing cover is skipped');
is(read_file($dest), 'old', 'and the file is left alone without force');

$answer = JawnOS::RomCovers::cover_fetch('http://example.test/cover.png', $dest,
	sub { $png }, { force => 1 });
ok($answer->{'ok'} && !$answer->{'skipped'}, 'force fetches it again');
is(read_file($dest), $png, 'and replaces the bytes');
ok(!-e "$dest.tmp.$$", 'through a temporary that is gone');

$answer = JawnOS::RomCovers::cover_fetch('http://example.test/gone', "$dir/gone.png", sub { undef });
ok(!$answer->{'ok'}, 'a failed download is reported, not written');

# --- the helper ---------------------------------------------------------------
my $script = read_file("$root/scripts/rom_covers.pl");
like($script, qr{^#!/usr/bin/perl}, 'the helper has a perl shebang');
like($script, qr/JAWNOS_COVERS_STATE/, 'the status row can be moved for a test');
like($script, qr/JAWNOS_COVERS_CACHE/, 'so can the listing cache');
like($script, qr/JAWNOS_COVERS_TTL/, 'and its lifetime');
like($script, qr/state => 'running'/, 'the row starts running');
like($script, qr/finish\('failed'/, 'a fatal error still writes a state');
like($script, qr/'--silent', '--show-error', '--fail', '--location'/, 'curl runs from an argv list');
like($script, qr/which\('wget'\)/, 'wget is the fallback');
like($script, qr/'-q', '-O'/, 'and it runs without a shell');
like($script, qr/system\('chown', 'jawn:jawn'/, 'the covers and their folder go back to the person');
like($script, qr/\$STATE\.tmp\.\$\$/, 'the status row is replaced atomically');
like($script, qr/JawnOS::RomCovers::KIND/, 'box art is the first kind tried');
ok(-x "$root/scripts/rom_covers.pl", 'the helper is executable');

done_testing();
