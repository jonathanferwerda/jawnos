# tests-for: public/js/music.js
# covers:    The music player cache names the file the element is actually
#            playing, and the restore resolves the saved key before the saved
#            file. The cache used to write tree.songs[0] - the first row of the
#            current list - and a search re-renders that list under a track that
#            keeps playing, so the first row became a stranger while the element
#            still held the old file. The next open then restored that stranger
#            at the old track's position (3:12 of a song nobody chose). A cache
#            already written that way still names the right track in `key`, so
#            the restore now looks that up first and plays the row it finds.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

my $music = read_file("$FindBin::Bin/../public/js/music.js");

# --- the cache saver names the playing file --------------------------------
my ($saver) = $music =~ /(function playerCacheSaver\(type, force\)\s*\{.*?\n\})/s;
ok(defined $saver, 'playerCacheSaver is found');
like($saver // '', qr/\bfile: playerCacheFile\(\)/,
	'the saved file comes from the element, not the first row of the list');
unlike($saver // '', qr/tree\.songs\[0\]/,
	'the saver no longer reads tree.songs[0] at all');

# --- the restore resolves the saved KEY first -------------------------------
# A cache written before the saver read the element can name a stranger in
# `file` while `key` still names the track the person was on, so the restore
# resolves the key and plays the row it finds.
my ($restore) = $music =~ /(if \(method != 'files'\) \{.*?\n\t\t\})/s;
ok(defined $restore, 'the restore block is found');
like($restore // '', qr/musicCardByKey\(pd\.key\)/,
	'the saved key is resolved through musicCardByKey');
like($restore // '', qr/if \(!mf\.length && pd\.file\)/,
	'and the saved file is only the fallback');
like($restore // '', qr/var saved_file = mf\.length \? \(mf\.attr\('file'\) \|\| ''\) : '';/,
	'the file played is the resolved row\'s own');
like($restore // '', qr/mediaMaker\(\{ file: saved_file,/,
	'and that is what mediaMaker is handed');
unlike($restore // '', qr/mediaMaker\(\{ file: pd\.file,/,
	'the possibly-stale cache file is never played directly');

# --- the traversal mediaMaker sets is the one the saver reads --------------
like($music, qr{var url = '/play\?track=' \+ uri_track;},
	'the player URL carries the track as /play?track=');
like($music, qr/tree\.sound\.src = url/,
	'and that URL is what the element is given');

# --- the helper itself, run in node ----------------------------------------
my ($from_src) = $music =~ /(function playerCacheTrackFromSrc\(src\)\s*\{.*?\n\})/s;
my ($cache_file) = $music =~ /(function playerCacheFile\(\)\s*\{.*?\n\})/s;
ok(defined $from_src && defined $cache_file, 'both helpers are found');

my $node = `command -v node 2>/dev/null`;
chomp $node;
SKIP: {
	skip 'node is not installed', 4 unless length $node;
	skip 'the helpers were not found', 4 unless defined $from_src && defined $cache_file;

	my $call = sub {
		my ($src, $first) = @_;
		my $code = 'var tree = { sound: { src: ' . encode_json($src)
			. ' }, songs: [{ file: ' . encode_json($first) . ' }] };' . "\n"
			. $from_src . "\n" . $cache_file . "\n"
			. 'console.log(playerCacheFile());' . "\n";
		my $dir = tempdir(CLEANUP => 1);
		my $tmp = "$dir/player-cache-track.js";
		open(my $fh, '>', $tmp) or die "$tmp: $!";
		print {$fh} $code;
		close $fh;
		my $out = `$node "$tmp" 2>&1`;
		chomp $out;
		return $out;
	};

	is($call->('/play?track=My%20Song.mp3&remote_uuid=abc', 'first.mp3'), 'My Song.mp3',
		'the playing element decides the file, even when the list starts elsewhere');
	is($call->('/play?track=Song.mp3', 'first.mp3'), 'Song.mp3',
		'a plain track name comes back whole');
	is($call->('', 'first.mp3'), 'first.mp3',
		'an element with no src falls back to the song it was handed');
	is($call->('/play?track=bad%ZZ.mp3', 'first.mp3'), 'bad%ZZ.mp3',
		'a malformed escape is kept raw rather than throwing');
}

done_testing();
