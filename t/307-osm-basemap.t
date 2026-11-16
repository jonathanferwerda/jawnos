# tests-for: scripts/osm_basemap.pl lib/JawnOS/Domain/File.pm lib/JawnOS/Domain/Key.pm lib/JawnOS/Platform/Paths.pm lib/JawnOS/Controller/manager_travel.pm lib/JawnOS/Routes/manager_travel.pm .gitignore
# covers:    the house's own vector basemap: the exact byte ranges a PMTiles
#            reader asks for, the archive's store path, the route that serves it,
#            and the script that builds one from an OpenStreetMap extract

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JSON::PP ();
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use JawnOSTest;

require JawnOS::Platform::Paths;
require JawnOS::Domain::File;

my $root = root();

# ---- the range plan: exact bytes, or a refusal ---------------------------
# A PMTiles reader opens the archive by asking for the header, then a directory,
# then one tile. Rounding a range (as the media path deliberately does, to keep
# a player from holding a whole file open) hands the reader the wrong bytes, so
# this planner never caps and never rounds.
my $size = 1000;

is_deeply( [ subs::basemap_range_plan( undef, $size ) ], [ 0, 1000 ],
	'no Range header is the whole archive' );
is_deeply( [ subs::basemap_range_plan( 'bytes=0-126', $size ) ], [ 0, 127 ],
	'the 127-byte PMTiles header is an exact slice' );
is_deeply( [ subs::basemap_range_plan( 'bytes=500-', $size ) ], [ 500, 500 ],
	'an open-ended range runs to the end' );
is_deeply( [ subs::basemap_range_plan( 'bytes=-100', $size ) ], [ 900, 100 ],
	'a suffix range is the last N bytes' );
is_deeply( [ subs::basemap_range_plan( 'bytes=900-5000', $size ) ], [ 900, 100 ],
	'an end past the file clamps to it' );
is_deeply( [ subs::basemap_range_plan( 'bytes=-5000', $size ) ], [ 0, 1000 ],
	'a suffix longer than the file is the whole file' );

my $plan = sub { [ subs::basemap_range_plan(@_) ] };

ok( !defined $plan->( 'bytes=500-400', $size )->[0],
	'a backwards range is refused' );
ok( !defined $plan->( 'bytes=1000-', $size )->[0],
	'a start at the end of the file is refused' );
ok( !defined $plan->( 'bytes=9999-', $size )->[0],
	'a start past the end is refused' );
ok( !defined $plan->( 'bytes=-', $size )->[0],
	'an empty range is refused' );
ok( !defined $plan->( 'bytes=-0', $size )->[0],
	'a zero-length suffix is refused' );
ok( !defined $plan->( 'items=0-10', $size )->[0],
	'a non-byte unit is refused' );
ok( !defined $plan->( 'bytes=0-10', 0 )->[0],
	'an empty archive has nothing to serve' );

# ---- the archive lives in the store, beside releases/ -------------------
# A built basemap is tens of megabytes and is regenerated from OpenStreetMap, so
# it is a build artifact like releases/ and voices/: never in git history.
is( JawnOS::Platform::Paths::basemaps_dir( root => '/tmp/tree' ), '/tmp/tree/basemaps',
	'the basemaps directory sits in the store root' );
is( JawnOS::Platform::Paths::basemaps_dir( env => { JAWNOS_STORE_DIR => '/tmp/store' } ), '/tmp/store/basemaps',
	'and follows JAWNOS_STORE_DIR, so a package keeps its own' );

# No name in the URL is the newest archive: the renderer must not need to know
# which county the house built last, and a rebuild must not need a client edit.
my $bm = tempdir( CLEANUP => 1 );
is( subs::basemap_newest($bm), '', 'an empty store has no newest basemap' );
is( subs::basemap_newest('/nonexistent/basemaps'), '', 'and neither has a missing one' );
write_file( "$bm/older.pmtiles", 'x' );
write_file( "$bm/notes.txt", 'x' );
utime( time - 3600, time - 3600, "$bm/older.pmtiles" );
write_file( "$bm/newer.pmtiles", 'x' );
is( subs::basemap_newest($bm), 'newer', 'the newest .pmtiles wins, and only .pmtiles counts' );
utime( time - 7200, time - 7200, "$bm/older.pmtiles" );
is( subs::basemap_newest($bm), 'newer', 'an older file does not displace it' );
like( read_file("$root/.gitignore"), qr{^basemaps/$}m, 'the built archives are gitignored' );

my $key = read_file("$root/lib/JawnOS/Domain/Key.pm");
like( $key, qr/^sub basemaps_dir \{ return JawnOS::Platform::Paths::basemaps_dir\(root => \$install_dir\) \}$/m,
	'subs::basemaps_dir answers from the worker\'s own install dir' );
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like( $loader, qr/releases_dir basemaps_dir/, 'and the domain loader knows the name' );
like( $loader, qr/media_range_plan basemap_range_plan/, 'as it does the range planner' );

# ---- the route that serves it -------------------------------------------
my $routes = read_file("$root/lib/JawnOS/Routes/manager_travel.pm");
like( $routes, qr/\[34017, 'get', '\/manager\/travel\/basemap', 'action_34017'\]/,
	'/manager/travel/basemap is a GET route' );

my $controller = read_file("$root/lib/JawnOS/Controller/manager_travel.pm");
my ($action) = $controller =~ /(sub action_34017 \{.*?\n\}\n)/s;
ok( $action, 'the action is there' );
like( $action, qr/&subs::basemap_range_plan\(\s*\$c->req->headers->range/, 'it plans from the request Range' );
like( $action, qr/&subs::basemaps_dir\(\);/, 'it reads the store\'s basemaps directory' );
like( $action, qr/&subs::basemap_newest\(\$dir\)/, 'and with no name serves the newest archive staged' );
like( $action, qr/\$dir \. '\/' \. \$name \. '\.pmtiles'/, 'the archive is the named file in it' );
like( $action, qr/&subs::path_name\(/, 'the name is a filesystem component, not a path' );
like( $action, qr/content_type\('application\/vnd\.pmtiles'\)/, 'it names the PMTiles type' );
like( $action, qr/accept_ranges\('bytes'\)/, 'and says ranges are welcome' );
like( $action, qr/content_range\('bytes ' \. \$start/, 'answering a range with its Content-Range' );
like( $action, qr/\$c->res->code\(416\)/, 'and a range it cannot meet with a 416' );
like( $action, qr/scripts\/osm_basemap\.pl/, 'a missing archive says how to build one' );
unlike( $action, qr/http:\/\/|https:\/\//, 'nothing here reaches another host' );

# ---- the build script ---------------------------------------------------
my $script = "$root/scripts/osm_basemap.pl";
ok( -f $script, 'scripts/osm_basemap.pl exists' );
my $text = read_file($script);
like( $text, qr/^#!\/usr\/bin\/perl/m, 'it is a Perl script' );
like( $text, qr/download\.geofabrik\.de/, 'it fetches the regional extract from Geofabrik' );
like( $text, qr/'extract', '--overwrite', '--strategy', 'complete_ways'/, 'osmium cuts the county whole' );
like( $text, qr/'--bbox=' \. \$opt\{'bbox'\}/, 'tilemaker gets the bounding box its profile needs' );
like( $text, qr/\$pmtiles, 'convert'/, 'and the reference converter writes the archive' );
like( $text, qr/"\$pmtiles" verify "\$staged"/, 'which is then verified, not assumed' );
like( $text, qr{/usr/share/doc/tilemaker/examples}, 'the profile comes from the installed package' );
like( $text, qr/apt-get install \$package/, 'a missing tool names the package that provides it' );
like( $text, qr/basemaps_dir/, 'it stages into the store\'s basemaps directory' );
like( $text, qr/^my %is_option = map \{ \$_ => 1 \} qw\( region name bbox cache maxzoom \);$/m,
	'--maxzoom is a known option' );
like( $text, qr/my \$config = patched_config\(/, 'the profile config is patched before the build' );
like( $text, qr/'--config', \$config/, 'tilemaker gets the patched copy, not /usr/share' );
like( $text, qr/'--process', \$process/, 'while the packaged Lua processor is passed unchanged' );
like( $text, qr/asked for z\$opt\{'maxzoom'\} but the archive stops at z\$1/,
	'an archive that stops short of --maxzoom is refused, not staged' );
like( $text, qr/--maxzoom=\$opt\{'maxzoom'\} needs tilemaker 3\.1\.0 or newer/,
	'and a tilemaker too old for the zoom asked for is refused before the build' );
like( $text, qr/\$cache\/tilemaker-bin\/tilemaker/,
	'a tilemaker built into the cache is preferred over the one in PATH' );

# The default is the house's Sarnia-London corridor, not the old county plate:
# both city centres, and so the 402 between them, must fall inside it. Read the
# corners from the script's own default rather than restating them here.
my ($default_bbox) = $text =~ /^\s*bbox\s*=>\s*'([^']+)'/m;
ok( $default_bbox, 'the script has a default bbox' );
my ($w, $s, $e, $n) = split /,/, $default_bbox // '';
is( scalar( split /,/, $default_bbox // '' ), 4,
	'the default bbox is minlon,minlat,maxlon,maxlat' );
my $inside = sub {
	my ( $lon, $lat ) = @_;
	return defined $lon && defined $w && $w <= $lon && $lon <= $e && $s <= $lat && $lat <= $n;
};
ok( $inside->( -82.4066, 42.9745 ), 'Sarnia (42.9745,-82.4066) is inside the default corridor' );
ok( $inside->( -81.2453, 42.9849 ), 'London (42.9849,-81.2453) is inside the default corridor' );
ok( $inside->( ( -82.4066 + -81.2453 ) / 2, ( 42.9745 + 42.9849 ) / 2 ),
	'the 402 midpoint between the cities is inside too' );
cmp_ok( $n, '<=', 43.2, 'the north edge stops short of Lake Huron' );

# ---- --status, run for real on a fixture -------------------------------
# A stand-in pmtiles CLI keeps this test off the network: the script only runs
# it when one is present in the cache.
my $tmp = tempdir( CLEANUP => 1 );
my $cache = "$tmp/cache";
my $store = "$tmp/store";
make_path($cache);
write_file( "$cache/pmtiles", "#!/bin/sh\necho '  min zoom: 6'\necho '  max zoom: 14'\n" );
chmod 0755, "$cache/pmtiles";

my $run = sub {
	my @args = @_;
	local $ENV{'JAWNOS_STORE_DIR'} = $store;
	my $cmd = join ' ', map { "'$_'" } ( $^X, $script, @args );
	my $out = `$cmd 2>&1`;
	return ( $? >> 8, $out );
};

my ( $code, $out ) = $run->( '--status', "--cache=$cache" );
is( $code, 1, '--status with nothing staged exits 1' );
like( $out, qr/nothing staged/, 'and says so' );
like( $out, qr/osm_basemap\.pl --all/, 'naming the command that builds one' );

make_path("$store/basemaps");
write_file( "$store/basemaps/lambton.pmtiles", 'x' x 2048 );
( $code, $out ) = $run->( '--status', "--cache=$cache" );
is( $code, 0, '--status with an archive staged exits 0' );
like( $out, qr/basemap: lambton\.pmtiles/, 'it names the archive' );
like( $out, qr/2 KB/, 'with its size' );
like( $out, qr/min zoom: 6/, 'and the pmtiles CLI\'s own zoom lines' );

# ---- which tilemaker: the cache build wins over PATH --------------------
# Debian's packaged 3.0.0 cannot tile above z14, so a newer one built in the
# cache is used when it exists; --help and --status say which one that is.
my $tmb = "$cache/tilemaker-bin/tilemaker";
make_path("$cache/tilemaker-bin");
write_file( $tmb, "#!/bin/sh\necho 'tilemaker v3.2.0'\n" );
chmod 0755, $tmb;
( $code, $out ) = $run->( '--help', "--cache=$cache" );
is( $code, 0, '--help exits 0' );
like( $out, qr{^tilemaker: \Q$tmb\E$}m, '--help names the cache tilemaker when one is built' );
unlink $tmb;
make_path("$tmp/path");
my $shim = "$tmp/path/tilemaker";
write_file( $shim, "#!/bin/sh\nexit 0\n" );
chmod 0755, $shim;
{
	local $ENV{'PATH'} = "$tmp/path:$ENV{'PATH'}";
	( $code, $out ) = $run->( '--status', "--cache=$cache" );
}
like( $out, qr{^tilemaker: \Q$shim\E$}m, 'and falls back to PATH when the cache has none' );

( $code, $out ) = $run->( '--nonsense' );
isnt( $code, 0, 'an unknown flag is refused' );
like( $out, qr/unknown argument '--nonsense'/, 'by name' );
( $code, $out ) = $run->( '--bboxx=1,2,3,4' );
isnt( $code, 0, 'an unknown --option=value is refused' );
like( $out, qr/unknown option '--bboxx'/, 'by name too, not silently ignored' );

# ---- --maxzoom: refused when wrong, patched when right ------------------
( $code, $out ) = $run->( '--maxzoom=banana', "--cache=$cache" );
isnt( $code, 0, 'a non-numeric --maxzoom is refused rather than ignored' );
like( $out, qr/--maxzoom needs a whole number from 0 to 17/, 'naming the option and its range' );
( $code, $out ) = $run->( '--maxzoom=18', "--cache=$cache" );
isnt( $code, 0, 'a --maxzoom deeper than 17 is refused' );
( $code, $out ) = $run->( '--maxzoom=16', "--cache=$cache" );
is( $code, 0, 'and --maxzoom=16 alone still only parses and builds nothing' );

# --dry-run reaches the config patch without tilemaker, the extract or the net.
SKIP: {
	my $packaged = '/usr/share/doc/tilemaker/examples/config-openmaptiles.json';
	skip 'the packaged tilemaker profile is not installed', 11 unless -f $packaged;

	( $code, $out ) = $run->( '--dry-run', "--cache=$cache" );
	is( $code, 0, '--dry-run writes the profile and stops' );
	my $patched = "$cache/config-lambton-z14.json";
	ok( -f $patched, 'the default copy lands in the cache, never /usr/share' );
	my $cfg = JSON::PP->new->decode( scalar read_file($patched) );
	is( $cfg->{settings}{maxzoom}, 14, 'the default leaves the top-level zoom at 14' );
	unlike( $out, qr/^build:/m, 'and tiles nothing' );

	( $code, $out ) = $run->( '--dry-run', '--maxzoom=16', "--cache=$cache" );
	is( $code, 0, '--dry-run at z16 succeeds' );
	$patched = "$cache/config-lambton-z16.json";
	ok( -f $patched, 'the patched profile is named for the zoom asked for' );
	$cfg = JSON::PP->new->decode( scalar read_file($patched) );
	is( $cfg->{settings}{maxzoom}, 16, 'the top-level maxzoom is raised to N' );
	is( $cfg->{layers}{building}{maxzoom}, 16, 'and a layer pinned at 14 is raised too' );
	is( $cfg->{settings}{basezoom}, 16, 'basezoom rises with it, as tilemaker requires' );
	like( scalar read_file($patched), qr/"landcover".*"glacier"/s,
		'the profile order survives: a write_to layer follows its target' );
	my @above = grep { $_->{'maxzoom'} > 16 }
		grep { ref $_ eq 'HASH' && defined $_->{'maxzoom'} } values %{ $cfg->{layers} };
	is( scalar @above, 0, 'no layer is left above N' );
}

done_testing();
