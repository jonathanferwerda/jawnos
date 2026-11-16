# tests-for: lib/JawnOS/Manager/Part02.pm lib/JawnOS/Manager/Core1_tables_hooks.pm
# covers:    A picture the virtual world loads as a texture goes through three,
#           whose ImageLoader asks for crossOrigin "anonymous" - a CORS-mode
#           image. The house served every file as application/x-download with
#           "Content-Disposition: attachment" (the extension ends .enc, so
#           nothing guessed better), and Chromium refuses a CORS image served
#           that way: the map plates and photo prints came through blank while
#           the same URL drew fine in a plain <img>. Audio and video left this
#           road earlier for the same reason; images now follow them out.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Slurp qw(read_file);

my $root = abs_path("$FindBin::Bin/..");
my $core = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");
my $part = read_file("$root/lib/JawnOS/Manager/Part02.pm");

# --- the table names the pictures the camera and maps write ------------------
for my $pair (qw(jpg:image/jpeg png:image/png webp:image/webp gif:image/gif avif:image/avif)) {
	my ($ext, $type) = split /:/, $pair;
	like( $core, qr/\b\Q$ext\E => '\Q$type\E'/, "a .$ext file is known as $type" );
}

# --- a picture is inline, and the .enc wrapper does not hide it --------------
like( $part, qr/\$name =~ s\/\\\.enc\$\/\/i;/, 'the .enc wrapper is stripped before the extension is read' );
like( $part, qr/media_type_for_ext\{\$ext\}/, 'and the table answers for it' );

# --- audio and video keep working, and nothing else changes ------------------
like( $part, qr/return \$verdict if defined \$verdict && \$verdict =~ m\{\^\(\?:audio\|video\|image\)\/\}/,
	'a sniffer verdict of an image is accepted too' );
like( $part, qr/return \(\) unless defined \$type && \$type =~ m\{\^\(\?:audio\|video\|image\)\/\}/,
	'media_render_args is inline for a picture' );
like( $part, qr/\$disposition = \$content_type =~ m\{\^\(\?:audio\|video\|image\)\/\} \? 'inline' : 'attachment'/,
	'and the streamed path says inline for one as well' );
unlike( $part, qr/m\{\^\(\?:audio\|video\)\/\} \? 'inline'/,
	'nothing still sends a picture down as an attachment' );

done_testing();
