# tests-for: lib/JawnOS/Controller/manager_travel.pm lib/JawnOS/Routes/manager_travel.pm lib/JawnOS/Domain/Plates.pm
# covers:    The Find branches route (one Overpass query, escaped and deduped) and the plate helpers it relies on.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = root();

# --- the route and its handler -------------------------------------------------
my $routes = read_file("$root/lib/JawnOS/Routes/manager_travel.pm");
my @row = $routes =~ /\[\s*(\d+)\s*,\s*'(post)'\s*,\s*'\/manager\/travel\/branches'\s*,\s*'(action_\d+)'\s*\]/;
is(scalar @row, 3, 'the branches route is registered as a POST row')
	or diag("rows found: " . scalar(@row));
my ($id, $method, $action) = @row;
is($method, 'post', 'Find branches is a POST') if $method;
is($action, "action_$id", 'the row names the action for its own index') if $action;

my $controller = read_file("$root/lib/JawnOS/Controller/manager_travel.pm");
my $action_name = defined $action ? $action : '';
like($controller, qr/^\s*sub\s+\Q$action_name\E\b/m, 'the route action exists in the controller')
	if $action;

# Scoped to the action, so a cache call or a query in another handler cannot
# stand in for this one.
my ($body) = $controller =~ /^sub\s+\Q$action_name\E\b(.*?)(?=^sub\s|\z)/ms;
ok(defined $body && length $body, 'the action body was found') if $action;
$body //= '';

# --- the contract the route has to keep ----------------------------------------
like($body, qr/\bsubs::plate_branch_escape\b/, 'the brand is escaped before it reaches the query');
like($body, qr/\bsubs::plate_branch_dedupe\b/, 'the branches are deduped before they are returned');
like($body, qr/\["brand"~/, 'the Overpass query asks the brand tag');
like($body, qr/\["name"~/, 'the Overpass query asks the name tag');
like($body, qr{overpass-api\.de/api/interpreter}, 'the query goes to the Overpass interpreter');
like($body, qr/form\s*=>\s*\{\s*data\s*=>\s*\$query\s*\}/, 'the query is POSTed as the data form field');

# The radius never leaves the 1 km .. 200 km contract.
like($body, qr/\$radius\s*=\s*1000\s+if\s+\$radius\s*<\s*1000/, 'the radius has a floor');
like($body, qr/\$radius\s*=\s*200000\s+if\s+\$radius\s*>\s*200000/, 'the radius has a ceiling');

# A hit is answered before the network is reached.
my $cache_at = index($body, 'cache_get');
my $net_at   = index($body, 'overpass-api.de');
ok($cache_at >= 0 && $net_at >= 0 && $cache_at < $net_at,
	'a cache hit is answered before the network is asked');
like($body, qr/context\s*=>\s*'home_plate_branches'/, 'the answer is cached under its own context');
like($body, qr/subcontext\s*=>\s*\$key/, 'the cache key carries the place');
like($body, qr/warranty\s*=>\s*'-7d'/, 'the answer is kept for a week');

# Validation: an empty or oversized brand, and an out-of-range coordinate.
like($body, qr/length\(\$brand\)\s*<=\s*80/, 'the brand is held to 80 characters');
like($body, qr/\$lat\s*>=\s*-90\s*&&\s*\$lat\s*<=\s*90/, 'latitude is range-checked');
like($body, qr/\$lon\s*>=\s*-180\s*&&\s*\$lon\s*<=\s*180/, 'longitude is range-checked');
ok(index($body, '[\x00-\x1f') >= 0, 'control characters are trimmed from the brand');

# --- the plate helpers ---------------------------------------------------------
my $escaped = subs::plate_branch_escape('Walmart (Supercentre)');
like($escaped, qr/\\\(Supercentre\\\)/, 'the parentheses are escaped for the regex');
unlike($escaped, qr/(?<!\\)[()]/, 'no bare parenthesis survives');

my $quoted = subs::plate_branch_escape('Bob "Shop"');
like($quoted, qr/\\"/, 'a literal quote is backslash-escaped');
unlike($quoted, qr/(?<!\\)"/, 'no bare quote survives');

my $base = { name => 'Base', brand => 'TestMart', lat => 40.0,      lon => -74.0, id => 1 };
my $near = { name => 'Near', brand => 'TestMart', lat => 40.00045,  lon => -74.0, id => 2 };
my $far  = { name => 'Far',  brand => 'TestMart', lat => 40.00900,  lon => -74.0, id => 3 };

my $close = subs::plate_branch_dedupe([ $base, $near ], 150);
is(scalar @{$close}, 1, 'two branches about 50 m apart are one branch');

my $apart = subs::plate_branch_dedupe([ $base, $far ], 150);
is(scalar @{$apart}, 2, 'two branches about a kilometre apart are both kept');

is(scalar @{ subs::plate_branch_dedupe([], 150) }, 0, 'an empty list stays empty');

done_testing();
