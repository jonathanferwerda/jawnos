#!/usr/bin/perl
# Build the house its own vector basemap: OpenStreetMap -> PMTiles.
#
# The Travel map's providers are other people's tile servers, and the measured
# plates only cover the places someone stood. This builds a real street map of
# the county the house lives in, from an OpenStreetMap extract, into one
# .pmtiles archive the app serves itself at /manager/travel/basemap.
#
#   perl scripts/osm_basemap.pl --status      # what is staged, and its extent
#   perl scripts/osm_basemap.pl --all         # download, cut, build, stage
#   perl scripts/osm_basemap.pl --build       # again from the cut extract
#   perl scripts/osm_basemap.pl --bbox=-82.4,42.6,-81.7,43.4 --name=lambton
#   perl scripts/osm_basemap.pl --build --maxzoom=16   # deeper than the profile
#
# The chain is Geofabrik's regional extract (1 GB for Ontario, fetched once into
# the cache and resumed if interrupted), `osmium extract` to cut the county out
# of it, then tilemaker with its OpenMapTiles profile into .mbtiles, and the
# reference pmtiles converter to write the .pmtiles a browser can read. The
# result is staged in basemaps/ in the store - a build artifact like releases/
# and voices/, gitignored, never in the tree's history.
#
# Requires: osmium (osmium-tool), tilemaker and curl. The pmtiles CLI is fetched
# into the cache automatically. Vector tiles are what a 3D view needs later:
# buildings carry their height and level tags, which a picture of a map never
# can.
#
# The packaged OpenMapTiles profile pins every layer to z14, so --maxzoom writes
# a patched copy of its config into the cache (never /usr/share) with the top
# level and each layer raised to the zoom asked for. The Lua processor stays as
# the package ships it.
#
# The default bbox is the county plate measured in Travel (the widest measured
# map that covers the house), and the default name is the county it sits in.
use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Path qw(make_path);
use File::Basename qw(basename);
use File::Spec;
use Cwd qw(abs_path);

use JawnOS::Platform::Paths ();

my $PMTILES_RELEASE = 'v1.31.2';
# The OpenMapTiles profile stops at z14; a PMTiles reader addresses no deeper
# than z17 in practice, and the packaged config has no layer above z14 to raise.
my $MAXZOOM = 17;

my %opt = (
	region  => 'north-america/canada/ontario',
	name    => 'lambton',
	bbox    => '-82.24519,42.67353,-81.82710,43.33643',
	cache   => File::Spec->catdir( JawnOS::Platform::Paths::home(), '.cache', 'jawnos-basemap' ),
	maxzoom => 14,
);
my %want;
# A flag this script does not know is a typo, and silently doing nothing is the
# worst answer: --fetc would build nothing and exit 0.
my %is_flag  = map { $_ => 1 } qw( fetch extract build all status help force dry-run );
my %is_option = map { $_ => 1 } qw( region name bbox cache maxzoom );

foreach my $arg ( @ARGV ) {
	if ( $arg =~ /^--([a-z][a-z-]*)=(.*)$/ ) {
		die "osm_basemap: unknown option '--$1' (try --help)\n" unless $is_option{$1};
		$opt{$1} = $2;
		next;
	}
	if ( $arg =~ /^--([a-z][a-z-]*)$/ ) {
		die "osm_basemap: unknown argument '--$1' (try --help)\n" unless $is_flag{$1};
		$want{$1} = 1;
		next;
	}
	die "osm_basemap: unknown argument '$arg' (try --help)\n";
}

my $cache = $opt{'cache'};

if ( $want{'help'} ) {
	print <<'USAGE';
perl scripts/osm_basemap.pl --status          what is staged, with its extent
perl scripts/osm_basemap.pl --all             fetch + extract + build
perl scripts/osm_basemap.pl --fetch           the regional extract, into the cache
perl scripts/osm_basemap.pl --extract         cut the county out of it
perl scripts/osm_basemap.pl --build           tile the cut extract into basemaps/
  --region=north-america/canada/ontario   Geofabrik path of the regional extract
  --name=lambton                          the archive's name (and the route's ?name=)
  --bbox=minlon,minlat,maxlon,maxlat      the ground to tile
  --maxzoom=N                             tile up to zoom N (default 14; the
                                          profile stops at 14, so raise it;
                                          z15+ needs tilemaker 3.1.0+)
  --cache=DIR                             where extracts and tools are kept
  --dry-run                               write the patched profile, tile nothing
USAGE
	print 'tilemaker: ', tilemaker_label(), "\n";
	print "  lookup: $cache/tilemaker-bin/tilemaker, then PATH\n";
	exit 0;
}

# A bad --maxzoom must stop the build: silently tiling at the profile's own 14
# would look like the option was honoured.
die "osm_basemap: --maxzoom needs a whole number from 0 to $MAXZOOM (got '$opt{'maxzoom'}')\n"
	unless $opt{'maxzoom'} =~ /^\d+$/ && $opt{'maxzoom'} <= $MAXZOOM;

my $stage = JawnOS::Platform::Paths::basemaps_dir( root => abs_path("$RealBin/..") );
my $out   = "$stage/$opt{'name'}.pmtiles";
my $slug  = $opt{'region'};
$slug =~ s{.*/}{};
my $region_file = "$cache/$slug-latest.osm.pbf";
my $county_pbf  = "$cache/$opt{'name'}.osm.pbf";

# A missing tool is the common failure, and the fix belongs in the message: the
# person should not have to read this file to learn what to install.
sub need_tool {
	my ( $tool, $package ) = @_;
	my $path = `command -v $tool 2>/dev/null`;
	$path =~ s/\s+$//;
	return $path if length $path;
	die "osm_basemap: '$tool' is not installed.\n"
		. "  Debian/Ubuntu: sudo apt-get install $package\n";
}

# A tilemaker built into the cache is preferred: Debian's packaged 3.0.0 is
# compiled without FAT_TILE_INDEX and cannot write tiles above z14. The lookup
# order is the cache binary, then PATH, and --help/--status name the one used.
sub tilemaker_bin {
	my $local = "$cache/tilemaker-bin/tilemaker";
	return $local if -x $local;
	my $path = `command -v tilemaker 2>/dev/null`;
	$path =~ s/\s+$//;
	return $path;
}

sub tilemaker_label {
	my $bin = tilemaker_bin();
	return length $bin ? $bin : 'not installed';
}

sub staged_files {
	return () unless -d $stage;
	opendir my $dh, $stage or return ();
	my @files = sort grep { /\.pmtiles$/ && -f "$stage/$_" } readdir $dh;
	closedir $dh;
	return map { "$stage/$_" } @files;
}

sub human_size {
	my $bytes = shift || 0;
	return sprintf( '%.1f MB', $bytes / ( 1024 * 1024 ) ) if $bytes >= 1024 * 1024;
	return sprintf( '%.0f KB', $bytes / 1024 ) if $bytes >= 1024;
	return "$bytes B";
}

# --status reads what is staged and says what it covers. The pmtiles CLI prints
# the header and one JSON directory summary; the zoom range and tile count are
# the two lines a person checks against what they asked for.
sub status {
	print 'tilemaker: ', tilemaker_label(), "\n";
	my @files = staged_files();
	unless ( @files ) {
		print "basemap: nothing staged in $stage\n";
		print "  build one with: perl scripts/osm_basemap.pl --all\n";
		return 1;
	}
	my $show = -x "$cache/pmtiles" ? "$cache/pmtiles" : '';
	foreach my $file ( @files ) {
		my $size = -s $file;
		my $when = scalar localtime( ( stat $file )[9] );
		print 'basemap: ', basename($file), '  ', human_size($size), ', built ', $when, "\n";
		next unless length $show;
		my $text = `"$show" show "$file" 2>&1`;
		foreach my $line ( split /\n/, $text ) {
			next unless $line =~ /(tile|zoom|bounds|address|version)/i;
			$line =~ s/^\s+|\s+$//g;
			print "  $line\n";
		}
	}
	return 0;
}

# The Debian package ships the OpenMapTiles config and Lua beside the binary.
# A build with another profile's files would tile the wrong tags, so use the
# installed pair and refuse rather than fetch a copy the binary may not match.
sub profile_assets {
	my @dirs = ( '/usr/share/doc/tilemaker/examples', '/usr/share/tilemaker',
		'/usr/local/share/tilemaker' );
	foreach my $dir (@dirs) {
		my $config  = "$dir/config-openmaptiles.json";
		my $process = "$dir/process-openmaptiles.lua";
		return ( $config, $process ) if -f $config && -f $process;
	}
	die "osm_basemap: tilemaker's OpenMapTiles profile is missing.\n"
		. '  the examples ship with the package: sudo apt-get install --reinstall tilemaker' . "\n"
		. '  looked in: ' . join( ', ', @dirs ) . "\n";
}

# tilemaker ships an OpenMapTiles profile pinned to z14. A deeper archive needs
# the top-level maxzoom raised and every layer that stops below it raised too.
# Only those numbers change, in the text: re-encoding the JSON would scramble the
# order of the layers, and tilemaker resolves a layer's write_to (glacier ->
# landcover) against a layer defined earlier in the file. The .lua processor is
# passed through untouched and nothing under /usr/share is ever written.
#
# tilemaker also insists maxzoom <= basezoom ("maxzoom must be the same or
# smaller than basezoom"), so basezoom rises with the top level.
sub patched_config {
	my ( $src, $maxzoom ) = @_;
	open my $in, '<', $src
		or die "osm_basemap: cannot read the profile config $src: $!\n";
	my $patched = do { local $/; <$in> };
	close $in;
	# every layer that stops below N, and basezoom if the top level passes it
	$patched =~ s/("(?:maxzoom|basezoom)"\s*:\s*)(\d+)/$1 . ($2 < $maxzoom ? $maxzoom : $2)/ge;
	# the top-level setting is the archive's own ceiling, so it is exactly N even
	# when N is shallower than the profile's 14
	my $settings_at = index( $patched, '"settings"' );
	die "osm_basemap: the profile config $src has no settings block\n"
		if $settings_at < 0;
	substr( $patched, $settings_at ) =~ s/("maxzoom"\s*:\s*)\d+/$1$maxzoom/;
	make_path($cache);
	my $dest = "$cache/config-$opt{'name'}-z$maxzoom.json";
	open my $out, '>', $dest or die "osm_basemap: cannot write $dest: $!\n";
	print $out $patched;
	close $out or die "osm_basemap: cannot write $dest: $!\n";
	return $dest;
}

sub fetch {
	make_path($cache);
	&need_tool( 'curl', 'curl' );
	my $url = 'https://download.geofabrik.de/' . $opt{'region'} . '-latest.osm.pbf';
	if ( -f $region_file && !$want{'force'} ) {
		print 'fetch: cached ', basename($region_file), ' (', human_size( -s $region_file ), ")\n";
		return 0;
	}
	print 'fetch: ', $url, "\n";
	print "  a regional extract runs to hundreds of MB (Ontario is ~1 GB); it resumes\n";
	system( 'curl', '--fail', '--location', '--continue-at', '-', '--output', $region_file, $url ) == 0
		or die "osm_basemap: the download failed; run this again to resume it\n";
	return 0;
}

sub extract_county {
	my $osmium = &need_tool( 'osmium', 'osmium-tool' );
	die "osm_basemap: no regional extract at $region_file; run --fetch first\n"
		unless -f $region_file;
	die "osm_basemap: --bbox needs minlon,minlat,maxlon,maxlat\n"
		unless $opt{'bbox'} =~ /^-?[\d.]+\s*,\s*-?[\d.]+\s*,\s*-?[\d.]+\s*,\s*-?[\d.]+$/;
	# The cut file must never be the extract it reads: osmium truncates its
	# output first, so one path would eat the download (as --name=monaco did).
	die "osm_basemap: the cut extract would overwrite the regional extract ($region_file); choose another --name\n"
		if abs_path($county_pbf) eq abs_path($region_file);
	print 'extract: ', $opt{'bbox'}, ' out of ', basename($region_file), "\n";
	# complete_ways keeps a road or a building whole when it crosses the edge:
	# a cut building is a broken outline in the tiles.
	system( $osmium, 'extract', '--overwrite', '--strategy', 'complete_ways',
		'--bbox', $opt{'bbox'}, '--output', $county_pbf, $region_file ) == 0
		or die "osm_basemap: osmium extract failed\n";
	print 'extract: ', basename($county_pbf), ' ', human_size( -s $county_pbf ), "\n";
	return 0;
}

sub build {
	my $tilemaker = tilemaker_bin();
	$tilemaker = &need_tool( 'tilemaker', 'tilemaker' ) unless length $tilemaker;
	# Debian's tilemaker 3.0.0 is built without FAT_TILE_INDEX: its tile
	# coordinates are 16-bit and its z6 offsets 8-bit ("supports up to z14"
	# in coordinates.h), so a basezoom above 14 silently truncates them.
	# Refuse before spending the build, not after it stages a degraded map.
	my $help = `"$tilemaker" --help 2>&1`;
	my ($tm_version) = $help =~ /^tilemaker\s+v?(\d+\.\d+\.\d+)/m;
	if ( $opt{'maxzoom'} > 14 && defined $tm_version && $tm_version < '3.1.0' ) {
		die "osm_basemap: --maxzoom=$opt{'maxzoom'} needs tilemaker 3.1.0 or newer;\n"
			. "  the installed $tm_version was built without FAT_TILE_INDEX and tops out at z14.\n";
	}
	die "osm_basemap: no cut extract at $county_pbf; run --extract first\n"
		unless -f $county_pbf;
	my ( $profile_config, $process ) = profile_assets();
	my $config = patched_config( $profile_config, $opt{'maxzoom'} );
	my $pmtiles = &fetch_pmtiles_cli();
	die "osm_basemap: the pmtiles CLI is required to write a valid archive;\n"
		. "  it could not be fetched into $cache\n"
		unless length $pmtiles;
	my $mbtiles = "$cache/$opt{'name'}.mbtiles";
	make_path($stage);
	print 'build: ', basename($county_pbf), ' -> ', basename($mbtiles),
		' at z', $opt{'maxzoom'}, ' (', basename($config), ")\n";
	system( $tilemaker,
		'--input', $county_pbf,
		'--output', $mbtiles,
		'--config', $config,
		'--process', $process,
		# the OpenMapTiles profile also clips Natural Earth shapefiles, and
		# tilemaker refuses them without a bounding box
		'--bbox=' . $opt{'bbox'} ) == 0
		or die "osm_basemap: tilemaker failed\n";
	# tilemaker 3.0 writes .pmtiles itself, but its leaf directory carries an
	# offset of 0, which the reference verifier and a strict reader reject. The
	# reference converter rewrites the same tiles into a clean archive, so the
	# archive is always made that way and then verified.
	#
	# It is converted beside the staged name first: a build that fails a check
	# must not replace the archive already staged.
	my $staged = "$out.part";
	print 'build: ', basename($mbtiles), ' -> ', basename($out), "\n";
	system( $pmtiles, 'convert', '--force', $mbtiles, $staged ) == 0
		or die "osm_basemap: pmtiles convert failed\n";
	my $verdict = `"$pmtiles" verify "$staged" 2>&1`;
	if ( $? != 0 ) {
		unlink $staged;
		die 'osm_basemap: the archive does not verify:' . "\n$verdict\n";
	}
	# An archive that quietly stops short of the zoom asked for is the worst
	# answer: tilemaker 3.0.0 overflows its tile bitmap at z16 and up, so it
	# writes nothing above 15. Read the archive back and refuse rather than
	# stage a shallower map under a deeper name.
	my $show = `"$pmtiles" show "$staged" 2>&1`;
	if ( $show =~ /^max zoom:\s*(\d+)/m && $1 < $opt{'maxzoom'} ) {
		unlink $staged;
		die "osm_basemap: asked for z$opt{'maxzoom'} but the archive stops at z$1;\n"
			. "  the tilemaker that built it cannot write tiles that deep.\n"
			. "  Nothing was staged.\n";
	}
	rename $staged, $out or die "osm_basemap: cannot stage $out: $!\n";
	print 'build: staged ', human_size( -s $out ), " and verified\n";
	return 0;
}

# The pmtiles CLI is the reference writer and verifier. It is not optional:
# tilemaker's own .pmtiles output fails the verifier (see build()).
sub fetch_pmtiles_cli {
	return "$cache/pmtiles" if -x "$cache/pmtiles";
	make_path($cache);
	&need_tool( 'curl', 'curl' );
	my $tar = "$cache/go-pmtiles.tar.gz";
	my $url = 'https://github.com/protomaps/go-pmtiles/releases/download/'
		. $PMTILES_RELEASE . '/go-pmtiles_' . substr( $PMTILES_RELEASE, 1 )
		. '_Linux_x86_64.tar.gz';
	print "fetch: pmtiles CLI into the cache\n";
	system( 'curl', '--fail', '--silent', '--show-error', '--location', '--output', $tar, $url ) == 0
		or return '';
	system( 'tar', '-xzf', $tar, '-C', $cache ) == 0 or return '';
	unlink $tar;
	return "$cache/pmtiles";
}

# --dry-run writes the patched profile and stops: it shows what the build would
# use without needing the extract, tilemaker or the network.
if ( $want{'dry-run'} ) {
	my ($profile_config) = profile_assets();
	my $config = patched_config( $profile_config, $opt{'maxzoom'} );
	print 'dry-run: profile z', $opt{'maxzoom'}, ' -> ', $config, "\n";
	exit 0;
}

if ( $want{'status'} ) {
	# the CLI is 57 MB; it is worth fetching only once there is something to read
	&fetch_pmtiles_cli() if staged_files() && !-x "$cache/pmtiles";
	exit status();
}

my $run = $want{'all'} ? { fetch => 1, extract => 1, build => 1 } : \%want;
fetch()             if $run->{'fetch'};
extract_county()    if $run->{'extract'};
build()             if $run->{'build'};

if ( $run->{'build'} ) {
	&fetch_pmtiles_cli();
	status();
}
exit 0;
