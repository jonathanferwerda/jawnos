# tests-for: lib/JawnOS/Domain/Access.pm lib/JawnOS/Domain/Roles.pm perl/subroutines.pl perl/gb/01_state_and_defaults.pl lib/JawnOS/Domain/Crest.pm lib/JawnOS/Domain/Loader.pm database/schema.sql lib/JawnOS/Domain/Migrations.pm lib/JawnOS/Controller/manager_people.pm lib/JawnOS/Controller/manager_people2.pm lib/JawnOS/Routes/manager_people.pm templates/apps/people_person.html.ep templates/apps/people/body.html.ep public/js/manager/people/02_roles.js perl/help/topics_people.pl
# covers:    One privilege ladder shared by sessions and peer grants, and a
#            route map that classifies every /manager path into a permission
#            key (or core) so a role can be checked against a surface.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

my $root = repo_root();

# The smallest stand-in for a Mojo::SQLite::Results: the roles layer asks for
# ->hashes (a table read) and ->hash (one person row).
package FakeRows;
sub new { my ($class, $hashes, $hash) = @_; return bless { hashes => $hashes || [], hash => $hash }, $class; }
sub hashes { $_[0]->{'hashes'} }
sub hash { $_[0]->{'hash'} }
package main;

# --- one ladder ------------------------------------------------------------
is($subs::privilege_rank{'guest'}, 1, 'a guest is the first rung');
is($subs::privilege_rank{'visitor'}, 1, 'a visitor is the same rung as a guest');
is($subs::privilege_rank{'resident'}, 2, 'a resident is the middle rung');
is($subs::privilege_rank{'member'}, 2, 'member is the peer word for resident');
is($subs::privilege_rank{'citizen'}, 3, 'a citizen is the top rung');
is($subs::privilege_rank{'trusted'}, 3, 'trusted is the peer word for citizen');
is($subs::privilege_rank{'blacklisted'}, 0, 'blacklisted is the floor');
is($subs::privilege_rank{'none'}, 0, 'none is the floor');
is($subs::privilege_rank{'revoked'}, 0, 'revoked is the floor');
is_deeply([ @subs::privilege_ladder ], [ qw(blacklisted visitor guest resident citizen trusted) ], 'the ladder names every rung once');

is($subs::tier_rank{'guest'}, 1, 'the session name still reads the same map');
is($subs::tier_rank{'citizen'}, 3, 'and the top rung did not move');

my %peer = subs::peer_scope_rank();
is($peer{'visitor'}, 1, 'a peer visitor ranks with a guest');
is($peer{'resident'}, 2, 'a peer resident ranks with a resident');
is($peer{'trusted'}, 3, 'a peer trusted ranks with a citizen');
is($peer{'none'}, 0, 'a peer with no grant ranks at the floor');
ok(!exists $peer{'citizen'}, 'a session word is not a peer grant');

# every tier a route can require is a word on the ladder
foreach my $row ( @{ $subs::tier_required || [] } ) {
	ok(exists $subs::privilege_rank{ $row->[0] }, "the gate's $row->[0] tier is on the ladder");
}

# the box office chooser reads the one map rather than a second scale
my $gb_source = read_file("$root/perl/gb/01_state_and_defaults.pl");
like($gb_source, qr/\$subs::privilege_rank\{'guest'\}/, 'the chairs rank comes from the one ladder');
unlike($gb_source, qr/guest => \{ rank => 3 \}/, 'and no inverted second scale is left behind');

# --- roles: presets, catalog and assignment ---------------------------------
foreach my $name (qw(role_catalog role_catalog_save role_catalog_delete role_find
	role_permissions_keyed role_permission_allowed person_role_keys person_roles_write
	access_permission_keys access_app_for_path)) {
	ok(subs::provides($name), "$name is mapped");
}

my $presets = subs::role_presets();
is(scalar @{$presets}, 6, 'six role presets follow the master plan');
my %preset = map { $_->{'uuid'} => $_ } @{$presets};
is($preset{'sales'}->{'name'}, 'Sales Associate', 'the sales role is named');
ok((grep { $_ eq 'store' } @{ $preset{'sales'}->{'permissions'} }), 'sales may use the store');
ok((grep { $_ eq 'phone' } @{ $preset{'reception'}->{'permissions'} }), 'reception may use the phone');
ok((grep { $_ eq 'accounting' } @{ $preset{'bookkeeper'}->{'permissions'} }), 'the bookkeeper may use accounting');
ok((grep { $_ eq 'people' } @{ $preset{'hr'}->{'permissions'} }), 'human resources may use people');
ok(!(grep { $_ eq 'configure' } @{ $preset{'manager'}->{'permissions'} }), 'even a manager role never grants configure');
ok(!(grep { $_ eq 'security' } @{ $preset{'manager'}->{'permissions'} }), 'or security');

my $night = subs::role_normalize({ name => 'Night Shift', department => ' Sales ', permissions => [qw(store core nonsense store)] });
is($night->{'uuid'}, 'night_shift', 'a new role takes a slug from its name');
is($night->{'department'}, 'Sales', 'the department is trimmed');
is_deeply($night->{'permissions'}, ['store'], 'unknown and core keys are dropped, and repeats fold');
ok(!subs::role_normalize({ name => '' }), 'a role with no name is refused');

{
	local *subs::db_select = sub { return FakeRows->new([]) };
	is(scalar @{ subs::role_catalog() }, 6, 'an empty roles table offers the presets');
}
{
	local *subs::db_select = sub {
		return FakeRows->new([ { uuid => 'night_shift', name => 'Night Shift', department => 'Sales', permissions => '["store"]', builtin => 0 } ]);
	};
	my $stored = subs::role_catalog();
	is(scalar @{$stored}, 1, 'a saved catalog is read instead of the presets');
	is($stored->[0]->{'name'}, 'Night Shift', 'with its own name');
	is_deeply($stored->[0]->{'permissions'}, ['store'], 'and its permissions decoded');
}
{
	my (@inserted, @updated);
	local *subs::db_query = sub {
		my ($sql, $uuid) = @_;
		return FakeRows->new($uuid eq 'sales' ? [ { 1 => 1 } ] : []);
	};
	local *subs::db_insert = sub { push @inserted, [ @_ ]; return FakeRows->new([]) };
	local *subs::db_update = sub { push @updated, [ @_ ]; return FakeRows->new([]) };
	local *subs::rightNow = sub { 'T' };
	my $out = subs::role_catalog_save([
		{ uuid => 'sales', name => 'Sales', permissions => ['store'] },
		{ uuid => 'night_shift', name => 'Night Shift', permissions => ['store'] },
	]);
	is(scalar @{$out}, 2, 'the save returns the normalized list');
	is(scalar @updated, 1, 'an existing role is updated');
	is($updated[0]->[1]->{'uuid'}, 'sales', 'and it is the one that was there');
	is(scalar @inserted, 1, 'a new role is inserted');
	is($inserted[0]->[1]->{'uuid'}, 'night_shift', 'under its slug');
}
{
	local *subs::db_select = sub {
		my ($table, $cols, $where) = @_;
		return FakeRows->new([], { uuid => 'p1', roles => '["sales","gone"]' });
	};
	is_deeply(subs::person_role_keys('p1'), [qw(sales gone)], 'the roles a person holds are read');
}
{
	my ($wrote, $where);
	local *subs::db_update = sub { my ($table, $data, $w) = @_; $wrote = $data; $where = $w; return FakeRows->new([]) };
	local *subs::db_select = sub { return FakeRows->new([]) };  # roles table empty -> presets
	my $kept = subs::person_roles_write('p1', [qw(sales ghost sales)], subs::role_presets());
	is_deeply($kept, ['sales'], 'an unknown role is not written to the person');
	is($where->{'uuid'}, 'p1', 'the write names the person');
	is_deeply(eval { require Mojo::JSON; Mojo::JSON::decode_json($wrote->{'roles'}) }, ['sales'], 'the stored value is a JSON list');
}
{
	my $catalog = subs::role_presets();
	my $keys = subs::role_permissions_keyed($catalog, [qw(sales reception)]);
	my %has = map { $_ => 1 } @{$keys};
	ok($has{'store'}, 'two roles expand to a union: store');
	ok($has{'phone'}, 'and phone');
	ok($has{'records'}, 'and the appointment records');
	ok(!$has{'configure'}, 'and never a desk no role was given');
	ok(subs::role_permission_allowed($catalog, ['sales'], 'store'), 'the sales role allows the store');
	ok(!subs::role_permission_allowed($catalog, ['sales'], 'people'), 'and does not allow people');
}

# --- the People UI and its routes ------------------------------------------
my $people_body = read_file("$root/templates/apps/people/body.html.ep");
like($people_body, qr/people_roles_card/, 'the People tab carries the staff roles card');
like($people_body, qr/data-permission-keys/, 'the card offers the permission keys');
my $person_ui = read_file("$root/templates/apps/people_person.html.ep");
like($person_ui, qr/people_person_role_save/, 'a person card can save their roles');
like($person_ui, qr/data-person-uuid/, 'and names the person it is saving');
my $roles_js = read_file("$root/public/js/manager/people/02_roles.js");
like($roles_js, qr{/manager/people/person/roles}, 'the script writes a person roles');
like($roles_js, qr{/manager/people/roles/save}, 'and the role catalog');
my $people_routes = read_file("$root/lib/JawnOS/Routes/manager_people.pm");
like($people_routes, qr{/manager/people/roles/save}, 'the role save route is registered');
like($people_routes, qr{/manager/people/person/roles}, 'the person roles route is registered');
my $people_help = read_file("$root/perl/help/topics_people.pl");
like($people_help, qr/Staff roles/, 'the help topic explains the staff roles card');

# --- the route map ---------------------------------------------------------
my $keys = subs::access_permission_keys();
my %key = map { $_ => 1 } @{$keys};
ok($key{'store'}, 'store is a permission');
ok($key{'people'}, 'people is a permission');
ok($key{'accounting'}, 'accounting is a permission');
ok($key{'reception'}, 'reception is a permission');
ok($key{'configure'}, 'configure is a permission');
ok(!$key{'core'}, 'core is not a grant a role can name');

is(subs::access_app_for_path('/manager/store/register'), 'store', 'the register is store');
is(subs::access_app_for_path('/manager/store'), 'store', 'the store page is store');
is(subs::access_app_for_path('/manager/people/person?uuid=x'), 'people', 'a query string does not hide the app');
is(subs::access_app_for_path('/manager/configure/theme_save'), 'configure', 'configure is configure');
is(subs::access_app_for_path('/manager/webauthn/register/begin'), 'security', 'a passkey belongs to security');
is(subs::access_app_for_path('/manager/appointment/writer'), 'records', 'an appointment write is records');
is(subs::access_app_for_path('/manager/transaction/record'), 'accounting', 'a transaction is accounting');
is(subs::access_app_for_path('/manager/mail/email/send'), 'mail', 'mail is mail');
is(subs::access_app_for_path('/manager/sco/arm'), 'reception', 'the phone reception is reception');
is(subs::access_app_for_path('/manager/setting_setter'), 'core', 'a settings write is a shared rail');
is(subs::access_app_for_path('/manager/ws'), 'core', 'the websocket is a shared rail');
is(subs::access_app_for_path('/manager'), 'core', 'the bare desk is core');
is(subs::access_app_for_path('/manager/not_a_real_surface'), undef, 'an unclassified path is not waved through');
is(subs::access_app_for_path('/sesh_check'), undef, 'a public rail is not a manager surface');

ok(subs::access_permission_known('core'), 'core is a known word');
ok(subs::access_permission_known('store'), 'a real key is known');
ok(!subs::access_permission_known('not_a_key'), 'an invented key is refused');

# Every /manager route in the tree must land on a key or an explicit core
# prefix. This is the audit that keeps a new surface from inheriting the door.
my %seen_key;
my @unclassified;
foreach my $file ( glob("$root/lib/JawnOS/Routes/*.pm") ) {
	my $source = read_file($file);
	while ($source =~ m{'((?:/)?manager(?:/[^']*)?)'}g) {
		my $path = $1;
		$path = "/$path" unless $path =~ m{^/};
		my $app = subs::access_app_for_path($path);
		if (defined $app && length $app && $app ne 'core') { $seen_key{$app} = 1; }
		push @unclassified, $path unless defined $app;
	}
}
is_deeply(\@unclassified, [], 'every manager route is classified as an app or an explicit core prefix') or diag("unclassified: @unclassified");
foreach my $k ( sort keys %{ $subs::ACCESS_APP } ) {
	ok($seen_key{$k}, "the $k permission names at least one route");
}

done_testing();
