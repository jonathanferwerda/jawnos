# tests-for: public/js/music.js
# covers:    A film's last subtitle line was left painted after the film
#            ended. The <track> keeps its cues and its showing mode across a
#            music_search (which shows the stopped picture again in the
#            theatre) and a page reload (which restores it at the end
#            position), so the last thing watched came back on screen. A new
#            load now resets the track, only a video asks for subtitles, the
#            one-second tick only shows a cue that has actually parsed (and
#            never for an ended film), and the end of a film hides the cue.

use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);

my $music = read_file("$FindBin::Bin/../public/js/music.js");

# --- the helpers ------------------------------------------------------------
my ($hide) = $music =~ /(function musicSubtitleHide\(\)\s*\{.*?\n\})/s;
my ($reset) = $music =~ /(function musicSubtitleReset\(\)\s*\{.*?\n\})/s;
ok(defined $hide && defined $reset, 'the subtitle helpers are found');
like($hide // '', qr/track\.track\.mode = 'hidden'/,
	'hiding the cue is a mode switch, so a seek back can re-arm it');
like($reset // '', qr/musicSubtitleHide\(\);.*?removeAttribute\('src'\)/s,
	'a new track hides the old cue and drops its source with it');

# --- a new load starts from a bare track and only a film asks for subs ------
my ($load) = $music =~ /(musicSubtitleReset\(\);\s*if \(tree\.songs\[0\].*?\n\t+\})/s;
ok(defined $load, 'the load path resets the subtitle track');
like($load // '', qr/if \(tree\.songs\[0\] && tree\.songs\[0\]\.type == 'video'\)/,
	'only a film is asked for subtitles, never a song');
like($load // '', qr/subtitle_track\.src = url \+ '&subtitle=yes';/,
	'the film gets its own subtitle source');
unlike($music, qr/document\.getElementById\('video_subtitles'\)\.src = st_url;/,
	'the old unconditional assignment is gone');

# --- the tick only shows a parsed cue, and never for an ended film ----------
like($music, qr/var subtitle_loaded = !!\(subtitle_text && subtitle_text\.readyState == 2 && subtitle_cues && subtitle_cues\.length\);/,
	'a cue is shown only once the track has actually parsed');
like($music, qr/if \(\(subtitle_loading \|\| subtitle_loaded\) && !tree\.sound\.ended\) \{/,
	'an ended film has no line to show, whichever picture returns');
like($music, qr/tree\.sound\.onended = function\(\) \{\s*\n\s*clearInterval\(interval\);\s*\n\s*musicVideoStop\(\);\s*\n\s*musicSubtitleHide\(\);/,
	'the end of the film hides the cue');
like($music, qr/if \(tree\.sound\.ended\) \{ musicSubtitleHide\(\); \}/,
	'a restore that lands at the end hides the restored cue');

# --- the helpers themselves, run in node ------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node;
SKIP: {
	skip 'node is not installed', 3 unless length $node;
	skip 'the helpers were not found', 3 unless defined $hide && defined $reset;

	my $code = "var track = {\n"
		. "\ttrack: { mode: 'showing' },\n"
		. "\tremoved: [],\n"
		. "\tremoveAttribute: function(n) { this.removed.push(n); }\n"
		. "};\n"
		. "global.document = { getElementById: function(id) { return id == 'video_subtitles' ? track : null; } };\n"
		. $hide . "\n" . $reset . "\n"
		. "musicSubtitleHide();\n"
		. "console.log(JSON.stringify({ step: 'hide', mode: track.track.mode, removed: track.removed }));\n"
		. "musicSubtitleReset();\n"
		. "console.log(JSON.stringify({ step: 'reset', mode: track.track.mode, removed: track.removed }));\n";
	my $dir = tempdir(CLEANUP => 1);
	my $tmp = "$dir/music-subtitle.js";
	open(my $fh, '>', $tmp) or die "$tmp: $!";
	print {$fh} $code;
	close $fh;
	my @out = split /\n/, `$node "$tmp" 2>&1`;
	is_deeply(eval { decode_json($out[0] // '') } || {},
		{ step => 'hide', mode => 'hidden', removed => [] },
		'hiding a showing cue switches the mode and leaves the source alone');
	is_deeply(eval { decode_json($out[1] // '') } || {},
		{ step => 'reset', mode => 'hidden', removed => ['src'] },
		'a reset removes the source as well');
	is(scalar @out, 2, 'the helpers run without throwing');
}

done_testing();
