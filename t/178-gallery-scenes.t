# tests-for: scripts/gallery/scenes.json scripts/gallery/capture.mjs scripts/gallery/publish.py scripts/gallery/run.sh
# covers:    the website gallery's manifest stays shape-correct, the Travel shot
#           keeps its Esri satellite basemap and measured maps, the Cards shot
#           keeps mahjong, the capture still opens on the desk default, and a
#           desktop publish never sweeps the phone screenshots away.

use strict;
use warnings;

use FindBin;
use File::Slurp qw(read_file);
use JSON::PP qw(decode_json);
use Test::More;

my $root     = "$FindBin::Bin/..";
my $manifest = decode_json( scalar read_file("$root/scripts/gallery/scenes.json") );
my $scenes   = $manifest->{scenes};

my ( %id, %slug, @included );
for my $scene (@$scenes) {
	ok( !$id{ $scene->{id} }++, 'scene id ' . $scene->{id} . ' is unique' );
	next unless ( $scene->{site} || {} )->{include};
	push @included, $scene;
	my $site = $scene->{site};
	like( $site->{slug}, qr/^[a-z0-9-]+$/, "$scene->{id} has a URL slug" );
	ok( !$slug{ $site->{slug} }++, "$scene->{id} slug is unique" );
	ok( length $site->{title},       "$scene->{id} has a title" );
	ok( length $site->{description}, "$scene->{id} has a description" );
	ok( length $site->{alt},         "$scene->{id} has alt text" );
	like( $site->{crop}, qr/^(?:window|full)$/, "$scene->{id} crops to a window or the full frame" );
}
is( scalar( grep { $_->{site}->{lead} } @included ), 1,
	'exactly one included scene is the lead' );

my ($travel) = grep { ( $_->{site} || {} )->{slug} && $_->{site}->{slug} eq 'travel' } @$scenes;
ok( $travel, 'the gallery has a Travel shot' );
like( $travel->{after}, qr/'esri'/, 'Travel picks the Esri satellite basemap' );
like( $travel->{after}, qr/fitToMaps\(\)/, 'Travel frames its measured maps' );

my ($cards) = grep { ( $_->{site} || {} )->{slug} && $_->{site}->{slug} eq 'cards-mahjong' } @$scenes;
ok( $cards, 'the gallery has a Cards shot' );
like( $cards->{after}, qr/cardsShowVariant\('mahjong'/, 'Cards opens on mahjong' );

my $capture = read_file("$root/scripts/gallery/capture.mjs");
like( $capture, qr/#desk_layer \.folders_file/,
	'the capture accepts the desk default, which draws no appointment view' );
like( $capture, qr/response\.appts && response\.appts\.__specs/,
	'and still treats the appointment view as the ready signal' );

my $publish = read_file("$root/scripts/gallery/publish.py");
like( $publish, qr/startswith\("android-"\)/,
	'a desktop publish leaves the phone screenshots alone' );

my $run = read_file("$root/scripts/gallery/run.sh");
like( $run, qr/where app in \('t-watch','t-deck','studio','plein_air','portraits'\)/,
	'the seed summary query is quoted the way the guest shell parses it' );

done_testing();
