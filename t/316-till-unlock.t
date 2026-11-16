# tests-for: lib/JawnOS/Domain/Shifts.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_store.pm lib/JawnOS/Controller/manager_people.pm lib/JawnOS/Controller/manager_misc4.pm lib/JawnOS/Routes/manager_store.pm lib/JawnOS/Routes/manager_people.pm lib/JawnOS/Domain/Migrations.pm database/schema.sql templates/store/register.html.ep public/js/store/register.js templates/apps/people_person.html.ep public/js/manager/people/01_crest_tabs.js perl/help/topics_business.pl perl/help/topics_people.pl
# covers:    A person proves who they are at the till with a PIN, an NFC tag
#            token or a person-bound passkey, and the shift remembers that
#            person for a short time instead of trusting a typed name.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);
use Digest::SHA qw(sha256_hex);
use JawnOSTest;
use RepoSource;

my $root = root();
require "$root/lib/JawnOS/Domain/Shifts.pm";
require "$root/lib/JawnOS/Controller/manager_store.pm";
require "$root/lib/JawnOS/Controller/manager_people.pm";
require "$root/lib/JawnOS/Controller/manager_misc4.pm";

{ package FakeRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
  sub hashes { return $_[0]->{'rows'}; }
  sub hash { return $_[0]->{'rows'}->[0]; }
}

{ package FakeController;
  sub new {
    my ($class, %params) = @_;
    return bless { params => \%params, session => {}, rendered => undef }, $class;
  }
  sub param {
    my ($s, $k, $v) = @_;
    if (@_ > 2) { $s->{'params'}{$k} = $v; return $v; }
    return $s->{'params'}{$k};
  }
  sub session {
    my ($s, @args) = @_;
    if (@args >= 2) { $s->{'session'}{$args[0]} = $args[1]; return $args[1]; }
    return $s->{'session'}{$args[0]};
  }
  sub render { my ($s, %o) = @_; $s->{'rendered'} = \%o; return 1; }
}

my $person = { uuid => 'p1', name => 'Ada', status => 'active', app => 'Ada' };
my $salt = 'salt-value';
my $pin_hash = sha256_hex($salt . "\0" . '4321');

# --- the map ----------------------------------------------------------------
ok(subs::provides('till_pin_set'), 'PIN set is mapped in the domain loader');
ok(subs::provides('till_pin_check'), 'PIN check is mapped in the domain loader');
ok(subs::provides('till_token_mint'), 'tag token mint is mapped in the domain loader');
ok(subs::provides('till_unlock_current'), 'the session unlock is mapped in the domain loader');

# --- schema and migration ---------------------------------------------------
my $schema = read_file("$root/database/schema.sql");
like($schema, qr/pin_hash VARCHAR\(255\).*till_token_hash VARCHAR\(255\)/s,
	'the people table has a PIN hash and a tag token hash');
like($schema, qr/closed_by VARCHAR\(500\)/, 'the shift records who closed it');
my $migrations = read_file("$root/lib/JawnOS/Domain/Migrations.pm");
like($migrations, qr/alter table people add column pin_hash/, 'an existing house gains the PIN column by migration');

# --- setting a PIN ----------------------------------------------------------
{
	my ($updated, $where);
	local *subs::db_select = sub { return FakeRows->new([ { %{$person} } ]) };
	local *subs::db_update = sub { $updated = $_[1]; $where = $_[2]; return 1 };
	local *subs::db_query = sub { return FakeRows->new([]) };
	local *subs::random_string_creator = sub { return $salt };
	local *subs::rightNow = sub { return 1000 };
	ok(subs::till_pin_set('p1', '4321')->{'ok'}, 'a four to eight digit PIN is accepted');
	is($updated->{'pin_hash'}, $pin_hash, 'only a salted hash is written');
	isnt($updated->{'pin_hash'}, '4321', 'the PIN itself is never stored');
	ok(!subs::till_pin_set('p1', '12ab')->{'ok'}, 'a non-numeric PIN is refused');
}

# --- checking a PIN, and the rate limit -------------------------------------
{
	my $fail = 0;
	my $current = { %{$person}, pin_hash => $pin_hash, pin_salt => $salt };
	local *subs::db_select = sub { return FakeRows->new([$current]) };
	local *subs::db_query = sub {
		my ($sql) = @_;
		return FakeRows->new([ { n => $fail } ]) if $sql =~ /select count/;
		$fail = 0 if $sql =~ /delete from cache/ && $sql !~ /server_time/;
		return FakeRows->new([]);
	};
	local *subs::db_insert = sub { $fail++ if (($_[1]->{'context'} // '') eq 'till_pin_fail'); return 1 };
	local *subs::rightNow = sub { return 2000 };
	local *subs::random_string_creator = sub { return 'failure' };

	ok(subs::till_pin_check('p1', '4321')->{'ok'}, 'the right PIN unlocks');
	ok(!subs::till_pin_check('p1', '0000')->{'ok'}, 'a wrong PIN is refused');
	is($fail, 1, 'and is counted against the person');
	ok(subs::till_pin_check('p1', '4321')->{'ok'}, 'the right PIN still works');
	is($fail, 0, 'and clears the failure count');

	my @tries;
	push @tries, subs::till_pin_check('p1', '0000') for 1 .. 5;
	is(scalar(grep { !$_->{'ok'} } @tries), 5, 'five wrong PINs are all refused');
	my $blocked = subs::till_pin_check('p1', '4321');
	ok(!$blocked->{'ok'} && $blocked->{'rate_limited'}, 'the next try is refused even with the right PIN');
}

# --- tag tokens -------------------------------------------------------------
{
	my ($updated, $where);
	local *subs::db_select = sub { return FakeRows->new([ { %{$person} } ]) };
	local *subs::db_update = sub { $updated = $_[1]; $where = $_[2]; return 1 };
	local *subs::rightNow = sub { return 5000 };
	local *subs::random_string_creator = sub { return 'tag-token-1234567890' };
	my $minted = subs::till_token_mint('p1');
	ok($minted->{'ok'}, 'a tag token is minted');
	is($updated->{'till_token_hash'}, sha256_hex($minted->{'token'}), 'only its hash is stored');

	local *subs::db_select = sub {
		my ($table, $columns, $where) = @_;
		return FakeRows->new([ { %{$person} } ])
			if (($where->{'till_token_hash'} // '') eq sha256_hex('good-token'));
		return FakeRows->new([]);
	};
	my $good = subs::till_token_check('good-token');
	ok($good->{'ok'} && $good->{'person'}->{'uuid'} eq 'p1', 'the right token names its person');
	ok(!subs::till_token_check('bad-token')->{'ok'}, 'another token is refused');
}

# --- the short-lived unlock -------------------------------------------------
{
	my $c = FakeController->new();
	local *subs::rightNow = sub { return 100000 };
	local *subs::tax_number = sub { return $_[0] || 0 };
	my $unlock = subs::till_unlock_store($c, { uuid => 'p1', name => 'Ada' });
	is($unlock->{'expires'}, 100000 + 900000, 'the unlock lasts fifteen minutes');
	ok(subs::till_unlock_current($c)->{'person_uuid'} eq 'p1', 'the live unlock reads back');
	local *subs::rightNow = sub { return 100000 + 900001 };
	ok(!defined subs::till_unlock_current($c), 'an expired unlock reads as none');
	ok(!defined $c->{'session'}{'till_unlock'}, 'and is cleared from the session');
}

# --- the unlock route -------------------------------------------------------
{
	my $c = FakeController->new(method => 'pin', associate => 'Ada', secret => '4321');
	local *subs::till_person_find = sub { return { %{$person} } };
	local *subs::till_pin_check = sub { return { ok => 1, person => { uuid => 'p1', name => 'Ada' } } };
	local *subs::rightNow = sub { return 200000 };
	Manager::action_6982($c);
	ok($c->{'rendered'}{'json'}{'ok'}, 'the PIN unlocks the till');
	is($c->{'session'}{'till_unlock'}{'person_uuid'}, 'p1', 'and keeps the unlock in the session');
}
{
	my $c = FakeController->new(method => 'token', secret => 'good-token');
	local *subs::till_token_check = sub { return { ok => 1, person => { uuid => 'p1', name => 'Ada' } } };
	local *subs::rightNow = sub { return 210000 };
	Manager::action_6982($c);
	ok($c->{'rendered'}{'json'}{'ok'}, 'a tag token unlocks the till');
}
{
	my $c = FakeController->new(method => 'magic');
	Manager::action_6982($c);
	ok(!$c->{'rendered'}{'json'}{'ok'}, 'an unknown method is refused');
}

# --- opening and closing use that person ------------------------------------
{
	my $captured;
	my $c = FakeController->new(associate => 'Typed Name', float => '20.00');
	local *subs::till_unlock_current = sub { return { person_uuid => 'p1', name => 'Ada' } };
	local *subs::shift_open = sub {
		$captured = $_[0];
		return { ok => 1, shift => { uuid => 's1', associate => $_[0]->{'associate'}, associate_uuid => $_[0]->{'associate_uuid'} } };
	};
	local *subs::shift_report = sub { return { associate => 'Ada' } };
	local *subs::device_setter = sub { return 'register' };
	Manager::action_6979($c);
	ok($c->{'rendered'}{'json'}{'ok'}, 'the till opens for the unlocked person');
	is($captured->{'associate'}, 'Ada', 'the unlocked name replaces the typed one');
	is($captured->{'associate_uuid'}, 'p1', 'and the person uuid is recorded');
}
{
	my $captured;
	my $c = FakeController->new(associate => 'Ada', float => '0');
	local *subs::till_unlock_current = sub { return undef };
	local *subs::till_person_find = sub { return { %{$person} } };
	local *subs::shift_open = sub { $captured = $_[0]; return { ok => 1, shift => { uuid => 's1' } } };
	local *subs::shift_report = sub { return {} };
	local *subs::device_setter = sub { return 'register' };
	Manager::action_6979($c);
	is($captured->{'associate'}, 'Ada', 'with no unlock the typed name still opens the till');
}
{
	my $shift = { uuid => 's1', associate => 'Ada', associate_uuid => 'p1' };
	local *subs::shift_current = sub { return $shift };
	local *subs::device_setter = sub { return 'register' };
	local *subs::till_unlock_current = sub { return undef };
	my $c = FakeController->new(counted => '50.00');
	Manager::action_6980($c);
	ok(!$c->{'rendered'}{'json'}{'ok'} && $c->{'rendered'}{'json'}{'need_unlock'},
		'a shift opened by a person needs that unlock to close');
}
{
	my $shift = { uuid => 's1', associate => 'Ada', associate_uuid => 'p1' };
	my $closer;
	local *subs::shift_current = sub { return $shift };
	local *subs::device_setter = sub { return 'register' };
	local *subs::till_unlock_current = sub { return { person_uuid => 'p1', name => 'Ada' } };
	local *subs::shift_close = sub { $closer = $_[3]; return { ok => 1, shift => {}, report => {} } };
	my $c = FakeController->new(counted => '50.00');
	Manager::action_6980($c);
	ok($c->{'rendered'}{'json'}{'ok'}, 'the matching unlock closes the shift');
	is($closer->{'uuid'}, 'p1', 'and the closer is recorded');
}

# --- an NFC tap reaches the same unlock -------------------------------------
{
	my $c = FakeController->new(message => encode_json([ { till_token => 'good-token' } ]), timestamp => 1000);
	local *subs::till_token_check = sub { return { ok => 1, person => { uuid => 'p1', name => 'Ada' } } };
	local *subs::till_unlock_store = sub { return { person_uuid => 'p1', name => 'Ada', expires => 999999 } };
	local *subs::subprocessor = sub { return 1 };
	local *subs::random_string_creator = sub { return 'u1' };
	Manager::action_12622($c);
	is($c->{'rendered'}{'json'}{'status'}, 'Till: Ada', 'the NFC reader recognises a till tag');
}

# --- the person card mints and sets -----------------------------------------
{
	local *Manager::people_citizen = sub { return 1 };
	my $called = 0;
	local *subs::till_pin_set = sub { $called = 1; return { ok => 1, person => {} } };
	my $c = FakeController->new(uuid => 'p1', pin => '4321', confirm => '0000');
	Manager::action_24704($c);
	ok(!$c->{'rendered'}{'json'}{'ok'} && !$called, 'a PIN whose confirmation differs is never saved');
}
{
	local *Manager::people_citizen = sub { return 1 };
	local *subs::till_pin_set = sub { return { ok => 1, person => { uuid => 'p1' } } };
	my $c = FakeController->new(uuid => 'p1', pin => '4321', confirm => '4321');
	Manager::action_24704($c);
	ok($c->{'rendered'}{'json'}{'ok'}, 'a matching PIN is saved from the person card');
}
{
	local *Manager::people_citizen = sub { return 1 };
	local *subs::till_token_mint = sub { return { ok => 1, token => 'tag-token', person => { uuid => 'p1' } } };
	my $c = FakeController->new(uuid => 'p1');
	Manager::action_24705($c);
	is($c->{'rendered'}{'json'}{'token'}, 'tag-token', 'the person card can mint a tag token');
}

# --- the routes and the two screens -----------------------------------------
my $store_routes = read_file("$root/lib/JawnOS/Routes/manager_store.pm");
my $people_routes = read_file("$root/lib/JawnOS/Routes/manager_people.pm");
like($store_routes . $people_routes,
	qr{'/manager/store/shift/unlock'.*'/manager/people/till/pin'.*'/manager/people/till/tag'}s,
	'the unlock and person-card routes are registered');

my $register = read_file("$root/templates/store/register.html.ep");
like($register, qr/id="store_register_till_pin".*id="store_register_till_tag_scan".*id="store_register_till_passkey"/s,
	'the open panel asks for a PIN, a tag tap or a passkey');
like($register, qr/id="store_register_till_close_unlocked"/, 'the close panel shows who is unlocked');

my $card = read_file("$root/templates/apps/people_person.html.ep");
like($card, qr/people_till_pin_set.*people_till_tag_write/s, 'the person card sets a PIN and writes a tag');

my $register_js = read_file("$root/public/js/store/register.js");
like($register_js, qr{/manager/store/shift/unlock.*function storeRegisterTillTap.*function storeRegisterTillPasskey}s,
	'the till unlocks through the route, with a passkey or a tag tap');
my $people_js = read_file("$root/public/js/manager/people/01_crest_tabs.js");
like($people_js, qr{/manager/people/till/pin.*till_token}s, 'the person card mints and writes a till tag');

my $nfc = read_file("$root/lib/JawnOS/Controller/manager_misc4.pm");
like($nfc, qr/till_token.*till_unlock_store/s, 'the NFC reader turns a till tag into an unlock');

my $store_help = read_file("$root/perl/help/topics_business.pl");
my $people_help = read_file("$root/perl/help/topics_people.pl");
like($store_help, qr/till PIN.*tag written from their person card/, 'the Store help explains the unlock');
like($people_help, qr/Set till PIN.*Write till tag/s, 'the People help explains the person card controls');

my $store_controller = read_file("$root/lib/JawnOS/Controller/manager_store.pm");
my ($close_action) = $store_controller =~ /(sub action_6980\b.*?)(?=\nsub |\z)/s;
like($close_action, qr/citizen.*override|override.*citizen/s,
	'a citizen can close a till whose associate has gone home');

done_testing();
