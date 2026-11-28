# tests-for: lib/JawnOS/Domain/Web.pm lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Controller/manager_misc12.pm
# covers:    Naming a person instead of a number or an address: contact_for_name
#           resolves the person through the Guide's own lookup and reads that
#           person's saved lines (a primary line wins); the phone and SMS routes
#           use it when only a name is given and refuse a person they cannot reach.

use strict;
use warnings;
use utf8;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;
use Mojolicious;
use Mojo::Transaction::HTTP;

&subs::preload($_) for qw(contact_for_name guide_resolve_target contact_lines
	device_setter device_call);
require 'JawnOS/Controller/manager_phone.pm';
require 'JawnOS/Controller/manager_misc12.pm';

my $target = { ok => 1, target => { app => 'alice' } };
my $lines = {
	phone => { alice => [ { value => 'testings', type => 'mobile', primary => 0 },
	                      { value => 'testing', type => 'home', primary => 1 } ] },
	email => { alice => [ { value => 'email_test', type => 'home', primary => 1 } ] },
};
local *subs::guide_resolve_target = sub { return $target };
local *subs::contact_lines = sub { return $lines->{ $_[0] } || {} };

# ------------------------------------------------------------ the lookup
is(subs::contact_for_name('Alice', 'phone'), 'testing',
	'a primary phone line wins over an earlier one');
is(subs::contact_for_name('Alice', 'email'), 'email_test',
	'an email line is read by kind');
is(subs::contact_for_name('  ', 'phone'), '', 'an empty name resolves to nothing');

$lines->{'phone'}{'alice'} = [ { value => 'testings', type => 'mobile' } ];
is(subs::contact_for_name('Alice', 'phone'), 'testings',
	'with no primary the first line is used');

$lines->{'phone'}{'alice'} = [];
is(subs::contact_for_name('Alice', 'phone'), '', 'a person with no lines resolves to nothing');

$target = { ok => 0 };
is(subs::contact_for_name('Nobody', 'phone'), '', 'an unknown person resolves to nothing');
$target = { ok => 1 };   # ok but no target
is(subs::contact_for_name('Alice', 'phone'), '', 'a clear miss with no target resolves to nothing');
$target = { ok => 1, target => { app => 'alice' } };
$lines->{'phone'}{'alice'} = [ { value => '5551234', type => 'mobile', primary => 1 } ];

# ------------------------------------------------------------ the routes
my $fake_app;
my @kept;
sub fake_controller {
	my ($path, %query) = @_;
	$fake_app ||= Mojolicious->new(quiet => 1);
	my $tx = Mojo::Transaction::HTTP->new;
	$tx->req->method('GET');
	$tx->req->url->path($path);
	$tx->req->url->query(\%query);
	my $c = $fake_app->build_controller($tx);
	push @kept, $c, $tx;
	return $c;
}

# Phone: a named person becomes a number, and the mobile peer dials it.
my @dialled;
local *subs::device_setter = sub { 'mobile' };
local *subs::device_call = sub { push @dialled, $_[1]; return { dialed => 1 } };
my $c = fake_controller('/manager/phone/dial', person => 'Alice');
Manager::action_24603($c);
my $json = $c->tx->res->json;
ok($json->{'ok'}, 'the phone route dials a named person');
is($json->{'number'}, '5551234', 'the resolved number is reported');
is($dialled[0]{'number'}, '5551234', 'the resolved number reaches the dial');

# An explicit number still wins over a name.
@dialled = ();
$c = fake_controller('/manager/phone/dial', number => '5551234', person => 'Nobody');
Manager::action_24603($c);
$json = $c->tx->res->json;
ok($json->{'ok'}, 'an explicit number dials without a lookup');
is($json->{'number'}, '5551234', 'the explicit digits are normalised and used');

# An unknown person is refused, not dialled.
@dialled = ();
$target = { ok => 0 };
$c = fake_controller('/manager/phone/dial', person => 'Nobody');
Manager::action_24603($c);
$json = $c->tx->res->json;
ok(!$json->{'ok'}, 'an unknown person is refused');
like($json->{'error'} // '', qr/do not have a phone number for Nobody/, 'the refusal names the person');
is(scalar @dialled, 0, 'nothing is dialled');
$target = { ok => 1, target => { app => 'alice' } };

# SMS: a named person becomes a number.
my @sent;
local *Manager::sms_message_send = sub { push @sent, [ @_ ]; return { ok => 1, out => 'sent' } };
$c = fake_controller('/manager/sms/message', person => 'Alice', message => 'see you soon');
Manager::action_41140($c);
$json = $c->tx->res->json;
ok($json->{'ok'}, 'the SMS route texts a named person');
is($sent[0][0], '5551234', 'the resolved number reaches the sender');
is($sent[0][1], 'see you soon', 'the message reaches the sender');

@sent = ();
$target = { ok => 0 };
$c = fake_controller('/manager/sms/message', person => 'Nobody', message => 'hello');
Manager::action_41140($c);
$json = $c->tx->res->json;
ok(!$json->{'ok'}, 'an unknown person is refused');
like($json->{'error'} // '', qr/do not have a number for Nobody/, 'the refusal names the person');
is(scalar @sent, 0, 'nothing is sent');

done_testing();
