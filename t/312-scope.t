# tests-for: lib/JawnOS/Domain/Access.pm lib/JawnOS/Domain/Roles.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Manager/Part20.pm perl/hooks.pl templates/manager.html.ep public/css/manager.css
# covers:    A resident's scope: a path maps to a permission key, a role grants
#            that key, and the session gate refuses a surface the role does not
#            name. Citizens are never scoped, core rails stay open, and the
#            taskbar shows the roles the resident is wearing.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

my $root = repo_root();

package FakeC;
sub new { my ($class, $session) = @_; return bless { session => $session || {}, stash => {} }, $class; }
sub session { my ($self, $key) = @_; return $self->{'session'}->{$key}; }
sub stash {
	my ($self, $key, $value) = @_;
	if (@_ >= 3) { $self->{'stash'}->{$key} = $value; }
	return $self->{'stash'}->{$key};
}
package main;

foreach my $name (qw(access_scope_missing session_role_keys session_role_names)) {
	ok(subs::provides($name), "$name is mapped");
}

my $catalog = subs::role_presets();
my %by = map { $_->{'uuid'} => $_ } @{$catalog};

# --- the scope answer ------------------------------------------------------
is(subs::access_scope_missing('/manager/store/register', 'resident', ['sales'], $catalog), undef,
	'a sales role reaches the register');
is(subs::access_scope_missing('/manager/people', 'resident', ['sales'], $catalog), 'people',
	'a sales role does not reach People');
is(subs::access_scope_missing('/manager/transaction/record', 'resident', ['bookkeeper'], $catalog), undef,
	'a bookkeeper reaches the accounting routes');
is(subs::access_scope_missing('/manager/store', 'resident', ['web'], $catalog), 'store',
	'a web editor does not reach the store');
is(subs::access_scope_missing('/manager/setting_setter', 'resident', [], $catalog), undef,
	'a core rail is open with no roles');
is(subs::access_scope_missing('/manager', 'resident', [], $catalog), undef,
	'the bare desk is open');
is(subs::access_scope_missing('/manager/nothing_here', 'resident', ['manager'], $catalog), 'unclassified',
	'an unclassified surface is refused by name');
is(subs::access_scope_missing('/manager/store', 'citizen', [], $catalog), undef,
	'a citizen is never scoped');
is(subs::access_scope_missing('/manager/store', 'guest', [], $catalog), undef,
	'a guest is the tier gate\'s problem, not a role\'s');
is(subs::access_scope_missing('/sesh_check', 'resident', ['sales'], $catalog), undef,
	'a public rail is not a manager surface');
is(subs::access_scope_missing('/manager/store', 'resident', [qw(web sales)], $catalog), undef,
	'two roles expand to their union');

# --- the session's own roles ----------------------------------------------
{
	local *subs::person_role_keys = sub { return ['sales'] };
	my $c = FakeC->new({ person_uuid => 'p1' });
	is_deeply(subs::session_role_keys($c), ['sales'], 'the session reads the person row');
	my $none = FakeC->new({});
	is_deeply(subs::session_role_keys($none), [], 'a session with no person holds no roles');
}
{
	local *subs::person_role_keys = sub { return ['sales', 'hr'] };
	local *subs::role_catalog = sub { return subs::role_presets() };
	local *subs::role_permissions_keyed = sub { return [] };
	my $c = FakeC->new({ person_uuid => 'p1' });
	is_deeply(subs::session_role_names($c), ['Sales Associate', 'Human Resources'], 'the names come from the catalog');
}

# --- the gate and the chip are wired --------------------------------------
my $hooks = read_file("$root/perl/hooks.pl");
like($hooks, qr/access_scope_missing/, 'the session gate asks the scope map');
like($hooks, qr/this pass does not include/, 'and its denial names the missing surface');
my $gate_at = index($hooks, 'access_scope_missing');
my $tier_at = index($hooks, 'tier_denied');
ok($tier_at >= 0 && $gate_at > $tier_at, 'the scope check follows the tier check');
# `$c->stash('key') ||= ...` parses but dies at runtime - "Can't modify
# non-lvalue subroutine call" - on the first resident request, and every peer
# rail that carried a stored resident session then answered 500. The roles are
# cached through the setter form instead, so pin that no call is an lvalue.
unlike($hooks, qr/\$c->stash\([^)]*\)\s*(?:\|\|=|(?<![=!<>~])=(?![=>~]))/,
	'no stash() call is used as an assignment target');
like($hooks, qr/\$c->stash\('session_roles' => \$roles\)/, 'the resident roles are cached through the setter form');
my $layout = read_file("$root/templates/manager.html.ep");
like($layout, qr/taskbar_identity/, 'the taskbar carries the resident identity');
like($layout, qr/session_role_names/, 'with the roles the person is wearing');
my $css = read_file("$root/public/css/manager.css");
like($css, qr/#taskbar_identity/, 'and the chip has its own plate');
ok(!(grep { $_ eq 'box_office' } @{ $by{'hr'}->{'permissions'} }), 'the HR role leaves the pass desk to a citizen');
ok(!(grep { $_ eq 'box_office' } @{ $by{'manager'}->{'permissions'} }), 'so does the manager role');
my $people_guard = read_file("$root/lib/JawnOS/Manager/Part20.pm");
like($people_guard, qr/access_scope_missing\('\/manager\/people'/, 'the People guard asks the resident scope');
my $people_controller = read_file("$root/lib/JawnOS/Controller/manager_people.pm");
like($people_controller, qr/Role administration is a citizen's act/, 'role administration stays a citizen act');
my $people_body = read_file("$root/templates/apps/people/body.html.ep");
like($people_body, qr/citizen.*people_roles_card|people_roles_card/s, 'the staff roles card is rendered for citizens');
my $person_card = read_file("$root/templates/apps/people_person.html.ep");
like($person_card, qr/people_person_roles/, 'the person card carries the roles block');

done_testing();
