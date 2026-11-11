# tests-for: lib/JawnOS/Domain/File.pm lib/JawnOS/Manager/Part04.pm perl/Music.pl
# covers:    a media element asks /play for the whole file, reads a couple of
#            megabytes, aborts that response and asks for the next range. The
#            server used to keep the whole file open on the first response, so a
#            browser's per-host connections stayed held and the next range
#            queued. /play now answers in a bounded slice, and the plan for that
#            slice is a pure function.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $cap = 2 * 1024 * 1024;

# --- the slice plan ---------------------------------------------------------
is_deeply( subs::media_range_plan(undef, 100_000_000), [ 0, $cap ],
	'no Range is the first slice' );
is_deeply( subs::media_range_plan('bytes=0-', 100_000_000), [ 0, $cap ],
	'a whole-file range is capped' );
is_deeply( subs::media_range_plan('bytes=1000-', 100_000_000), [ 1000, $cap ],
	'an open range is capped from its start' );
is_deeply( subs::media_range_plan('bytes=1000-1999', 100_000_000), [ 1000, 1000 ],
	'a short range is exact' );
is_deeply( subs::media_range_plan('bytes=-500', 100_000_000), [ 99_999_500, 500 ],
	'a suffix range is the tail' );
is_deeply( subs::media_range_plan('bytes=99999999-', 100_000_000), [ 99_999_999, 1 ],
	'the last byte is a one-byte slice' );
is( subs::media_range_plan('bytes=100000000-', 100_000_000), undef,
	'a start past the end is unsatisfiable' );
is_deeply( subs::media_range_plan('bytes=0-', 1000), [ 0, 1000 ],
	'a file smaller than the cap is served whole' );
is_deeply( subs::media_range_plan('bytes=-1000', 100), [ 0, 100 ],
	'a suffix longer than the file starts at 0' );
is_deeply( subs::media_range_plan('bytes=-100000000', 200_000_000), [ 197_902_848, $cap ],
	'a long suffix is the last cap, not its first bytes' );

# --- the route uses the plan, and does not hold the body forever -------------
my $root = JawnOSTest::root();
my $rock = read_file("$root/lib/JawnOS/Manager/Part04.pm");
my $music = read_file("$root/perl/Music.pl");
like($rock, qr/&subs::media_range_plan\(\$c->req->headers->range, \$play_total\)/,
	'/play asks for the bounded slice plan');
like($rock, qr/if \(\$file && \$is_play && \$play_range\)/,
	'the plain media path answers that slice');
like($rock, qr/content_range\('bytes ' \. \$start/,
	'and sends a 206 with its own Content-Range');
like($rock, qr/remove\('Range'\);[\s\S]{0,300}?render_file\(data => \$data, status => 206/,
	'the slice is not sliced a second time by render_file');
like($rock, qr/stream_fuse_media\(\$c, \$file, \$play_range\)/,
	'the FUSE media path gets the same bounded slice');
like($rock, qr/\$c->req->url->path ne '\/play' && \$file && -e \$file/,
	'a no-Range /play request is not answered 304');
like($rock, qr/\(\$c->param\('remoted'\) \/\/ ''\) ne 'yes'/,
	'a peer relay keeps the whole range its own player asked for');
unlike($music, qr/inactivity_timeout\(0\)/,
	'a held media body still has a connection timeout');

done_testing();
