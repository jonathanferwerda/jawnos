# tests-for: lib/JawnOS/Ble/Payload.pm lib/JawnOS/Domain/Ble2.pm
# covers:    the toggles reply a watch asks for with state_request. A corrupt
#           `app` key doubled from 108 to 786,444 bytes and the whole map was
#           1,626,591 bytes against a 64 KB bridge queue, so the reply was
#           dropped and the watch asked again forever. The guard drops keys
#           that cannot be names, and the map is paged into messages that fit.

use strict;
use warnings;
use utf8;

use Encode qw(encode_utf8);
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP ();
use Test::More;
use JawnOS::Ble::Payload qw(key_ok toggle_map toggle_chunks);

my $json = JSON::PP->new->utf8;
my $encode = sub { $json->encode($_[0]) };

# ---- the shipped shape ------------------------------------------------------
# The guard is what Ble2's state_request builds the map with, and the send is a
# loop over chunks from one child, never the whole map in one message.
open( my $fh, '<', "$FindBin::Bin/../lib/JawnOS/Domain/Ble2.pm" ) or die "$!";
my $src = do { local $/; <$fh> };
close $fh;
like( $src, qr/JawnOS::Ble::Payload/, 'state_request loads the payload module' );
like( $src, qr/toggle_map\(\$rows\)/, 'the toggle map is built through the guard' );
like( $src, qr/toggle_chunks\(\$toggles/, 'the reply is chunked before it is sent' );
like( $src, qr/foreach my \$chunk \( \@\{\$chunks\} \)/, 'one blocking send per chunk in one child' );
unlike( $src, qr/message => \{ type => 'toggles', data => \$toggles \}/,
	'the whole map is never handed to one message' );

is( $JawnOS::Ble::Payload::MAX_KEY_BYTES, 128, 'the name cap is 128 bytes' );
is( $JawnOS::Ble::Payload::MAX_CHUNK_BYTES, 24 * 1024, 'a chunk carries at most 24 KiB of JSON' );
is( $JawnOS::Ble::Payload::MAX_CHUNK_ENTRIES, 200, 'a chunk carries at most 200 entries' );

# ---- the guard accepts real names ------------------------------------------
# Shapes taken from the live settings table: a leading digit, apostrophes,
# ampersands, percent, commas, a plus, the __orphan prefix, and non-ASCII.
foreach my $good (
	'12_grain_bread', '2%_milk', 'a&w', 'london,_ontario', 'vol_+',
	"i'm_confident", "never_thought_i'd_see_africa", 'you’re_unsafe',
	'__orphan_03afafd1bfe2', '中文', 'café_au_lait', '9v_bettery',
	'x' x 128, 'é' x 64,
) {
	ok( key_ok($good), "a name survives: " . ( length($good) > 40 ? substr($good, 0, 12) . '...' : $good ) );
}

# ---- the guard rejects what the corruption left ----------------------------
ok( !key_ok(undef), 'undef is not a name' );
ok( !key_ok(''), 'the empty key is not a name' );
ok( !key_ok({}), 'a reference is not a name' );
ok( !key_ok('   '), 'whitespace only is not a name' );
ok( !key_ok(' padded'), 'leading whitespace is not a name' );
ok( !key_ok('padded '), 'trailing whitespace is not a name' );
ok( !key_ok('{'), 'a lone brace is not a name' );
ok( !key_ok('{"name":"budget"}'), 'a serialized blob is not a name' );
ok( !key_ok('[1,2,3]'), 'a serialized list is not a name' );
ok( !key_ok('"quoted"'), 'a quoted literal is not a name' );
ok( !key_ok("line\nbreak"), 'a control character is not a name' );
ok( !key_ok("nul\0key"), 'an embedded NUL is not a name' );
ok( !key_ok('x' x 129), '129 bytes is over the name cap' );
ok( !key_ok('é' x 65), 'the cap counts bytes, not characters' );
ok( !key_ok("\xC3\x28"), 'invalid UTF-8 is not a name' );

# The 108-byte original that doubles on every sync: under the byte cap, so the
# double-encoding signature is what has to catch it.
{
	my $small = 'i' . ( 'ÃÂ' x 27 );
	cmp_ok( length( encode_utf8($small) ), '<', 128, 'the smallest corrupt row is under the byte cap' );
	ok( !key_ok($small), 'the double-encoding signature is not a name' );
	ok( !key_ok('iÃ¢ÂÂm_confident'), 'a once-doubled name is not a name' );
}
{
	my $big = 'i' . ( 'ÃÂ' x 196611 );
	cmp_ok( length( encode_utf8($big) ), '>', 786_000, 'the largest corrupt row is the measured 786 KB shape' );
	ok( !key_ok($big), 'the largest corrupt row is dropped' );
}

# ---- toggle_map -------------------------------------------------------------
my $map = toggle_map([
	{ app => 'kitchen_light',      value => 'on' },
	{ app => 'porch_light',        value => 'off' },
	{ app => 'i' . ( 'ÃÂ' x 27 ),  value => 'on' },
	{ app => '{"name":"budget"}',  value => 'on' },
	{ app => '{',                  value => 'on' },
	{ app => '',                   value => 'on' },
	{ app => undef,                value => 'on' },
	{ app => 'porch_light',        value => 'on' },
	{ app => 'no_value' },
]);
is_deeply(
	$map,
	{ kitchen_light => 'on', porch_light => 'on', no_value => 'off' },
	'the map skips corrupt keys, normalises values, and a later row wins'
);
is_deeply( toggle_map([]), {}, 'no rows makes an empty map' );
is_deeply( toggle_map(undef), {}, 'no rows at all is still an empty map' );

# ---- toggle_chunks: shape and limits ---------------------------------------
is_deeply( toggle_chunks({}), [], 'an empty map is no chunks' );

my $one = toggle_chunks({ kitchen_light => 'on', porch_light => 'off' }, encode => $encode);
is( scalar @{$one}, 1, 'a small map is one chunk' );
is_deeply( $one->[0], { kitchen_light => 'on', porch_light => 'off' }, 'a small map keeps every key' );

my $norm = toggle_chunks({ a => 'ON', b => 'on', c => 'off', d => 'maybe' }, encode => $encode);
is_deeply( $norm->[0], { a => 'off', b => 'on', c => 'off', d => 'off' },
	'values are normalised to the on/off shape the watch reads' );

my $guarded = toggle_chunks(
	{ good_app => 'on', '{' => 'on', '{"name":"budget"}' => 'on', 'iÃ¢ÂÂm_confident' => 'on' },
	encode => $encode
);
is_deeply( $guarded, [ { good_app => 'on' } ], 'the chunker enforces the key guard too' );

# ---- toggle_chunks: a realistic house ---------------------------------------
# 1,318 clean keys is what the phone carries in the non-ASCII clear; short
# names mean the entry cap binds, so this is the page size the watch will see.
my %house;
$house{ sprintf('app_%04d', $_) } = ( $_ % 2 ? 'on' : 'off' ) for 1 .. 1318;
my $pages = toggle_chunks(\%house, encode => $encode);
is( scalar @{$pages}, 7, '1,318 short names split into seven pages' );

my %seen;
foreach my $i ( 0 .. $#{$pages} ) {
	my $chunk = $pages->[$i];
	my $keys = scalar keys %{$chunk};
	cmp_ok( $keys, '<=', 200, "page $i holds at most 200 entries" );
	cmp_ok( length( $encode->($chunk) ), '<=', 24 * 1024, "page $i is within 24 KiB of JSON" );
	my $message = $encode->( { type => 'toggles', data => $chunk } );
	cmp_ok( length($message), '<', 64 * 1024, "page $i fits the 64 KB bridge queue" );
	$seen{$_}++ for keys %{$chunk};
}
is( scalar keys %seen, 1318, 'every clean key is sent' );
is( scalar( grep { $_ != 1 } values %seen ), 0, 'no key is sent twice' );
is_deeply( [ sort keys %seen ], [ sort keys %house ], 'the pages carry exactly the input keys' );

my $again = toggle_chunks(\%house, encode => $encode);
is_deeply(
	[ map { [ sort keys %{$_} ] } @{$again} ],
	[ map { [ sort keys %{$_} ] } @{$pages} ],
	'a chunk boundary is reproducible'
);

# ---- toggle_chunks: the byte cap binds before the entry cap ----------------
# Names at the 128-byte cap: 200 of them would be over 24 KiB, so the byte
# limit has to end the page early.
my %long;
$long{ sprintf('%04d', $_) . ( 'x' x 124 ) } = 'off' for 1 .. 1318;
my $long_pages = toggle_chunks(\%long, encode => $encode);
cmp_ok( scalar @{$long_pages}, '>', 7, 'long names need more than the entry cap alone would' );
my $byte_bound = 0;
foreach my $chunk ( @{$long_pages} ) {
	my $keys = scalar keys %{$chunk};
	cmp_ok( $keys, '<=', 200, 'a long-name page still respects the entry cap' );
	cmp_ok( length( $encode->($chunk) ), '<=', 24 * 1024, 'a long-name page respects the byte cap' );
	$byte_bound++ if $keys < 200;
}
cmp_ok( $byte_bound, '>', 0, 'the byte cap is what ends these pages' );

# A single entry is far under the cap even at the name limit, so the loop can
# never emit a chunk that does not fit.
{
	my $alone = toggle_chunks( { ( 'y' x 128 ) => 'off' }, encode => $encode );
	is( scalar @{$alone}, 1, 'a single long name is one chunk' );
	cmp_ok( length( $encode->( $alone->[0] ) ), '<=', 24 * 1024, 'a single entry fits comfortably' );
}

done_testing();
