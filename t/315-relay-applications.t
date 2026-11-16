# tests-for: lib/JawnOS/Domain/Relay.pm lib/JawnOS/Domain/Loader.pm perl/junderground.pl lib/JawnOS/Controller/manager_box_office.pm lib/JawnOS/Routes/manager_box_office.pm templates/box_office/markup.html.ep public/js/manager/manager/03_box_office.js perl/help/topics_configure.pl
# covers:    An application sent through thejunderground lands as a request
#            ticket, the desk answers it with the ordinary approve/decline, and
#            the switch gets the decision so the applicant's token can read it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;
use RepoSource;

my $root = repo_root();

package FakeRows;
sub new { my ($class, $hashes) = @_; return bless { hashes => $hashes || [] }, $class; }
sub hashes { $_[0]->{'hashes'} }
package main;

foreach my $name (qw(relay_application_info relay_application_row relay_application_seen relay_application_import relay_application_ticket)) {
	ok(subs::provides($name), "$name is mapped");
}

my $app = {
	id => 'abc123def456',
	name => 'Dana Applicant',
	email => 'dana@example.test',
	phone => '555-0100',
	roles => ['sales', 'reception'],
	interview => 'Tuesday at ten',
	trial => 'A short page',
	description => 'I would like to work the counter.',
	crest => { uuid => 'crest1234', name => 'Dana' },
	created => 1_760_000_000,
};

my $info = subs::relay_application_info($app, 'jawn_house');
is($info->{'name'}, 'Dana Applicant', 'the name is kept');
is($info->{'email'}, 'dana@example.test', 'the contact is kept');
is_deeply($info->{'roles'}, ['sales', 'reception'], 'the roles applied for are kept');
is($info->{'interview'}, 'Tuesday at ten', 'the interview is kept');
is($info->{'trial'}, 'A short page', 'the trial task is kept');
is($info->{'source'}, 'relay', 'the request names its source');
is($info->{'relay_id'}, 'abc123def456', 'and the switch id');
is($info->{'relay_handle'}, 'jawn_house', 'and the house it came through');
is($info->{'consent'}, 'on', 'a relayed application carries the consent it was sent with');
ok(!subs::relay_application_info({ id => 'short', name => 'X' }), 'an id too short is refused');
ok(!subs::relay_application_info({ id => 'abc123def456', name => '' }), 'a nameless application is refused');

my $row = subs::relay_application_row($app, 'jawn_house');
is($row->{'status'}, 'request', 'the ticket waits at the desk');
is($row->{'privilege'}, 'guest', 'and is a guest, never a promotion');
is($row->{'name'}, 'Dana Applicant', 'the request carries the name');
is($row->{'timestamp'}, 1_760_000_000_000, 'the switch second becomes the house millisecond');
is($row->{'crest_uuid'}, 'crest1234', 'the crest id rides on the request');
ok(length $row->{'uuid'}, 'the request has its own uuid');
my $stored = decode_json($row->{'information'});
is($stored->{'relay_id'}, 'abc123def456', 'the relay id is inside the information');

{
	local *subs::db_select = sub { return FakeRows->new([ { information => encode_json({ relay_id => 'abc123def456' }) } ]) };
	ok(subs::relay_application_seen('abc123def456'), 'a landed relay id is seen');
	ok(!subs::relay_application_seen('other'), 'and another is not');
}
{
	my @inserted;
	local *subs::db_select = sub { return FakeRows->new([]) };
	local *subs::db_insert = sub { push @inserted, $_[1]; return FakeRows->new([]) };
	local *subs::random_string_creator = sub { 'ticket-uuid' };
	local *subs::rightNow = sub { 'NOW' };
	my $first = subs::relay_application_import($app, 'jawn_house');
	ok($first->{'imported'}, 'the first pull imports the application');
	is(scalar @inserted, 1, 'and writes one ticket');
	is($inserted[0]->{'uuid'}, 'ticket-uuid', 'under the minted uuid');
	is(subs::relay_application_ticket($inserted[0]), 'abc123def456', 'the row keeps its relay id');
	local *subs::db_select = sub { return FakeRows->new([ { information => encode_json({ relay_id => 'abc123def456' }) } ]) };
	my $again = subs::relay_application_import($app, 'jawn_house');
	ok($again->{'skipped'}, 'a second pull skips it');
	is(scalar @inserted, 1, 'without writing again');
}

my $jg = read_file("$root/perl/junderground.pl");
like($jg, qr/sub jg_applications/, 'the client reads applications');
like($jg, qr{/v1/houses/\$h/applications}, 'from the house rail');
like($jg, qr/sub jg_application_decide/, 'and writes a decision');
my $controller = read_file("$root/lib/JawnOS/Controller/manager_box_office.pm");
like($controller, qr/sub action_24781/, 'the relay action exists');
like($controller, qr/jg_applications/, 'it asks the switch');
like($controller, qr/relay_application_import/, 'and imports what it finds');
like($controller, qr/jg_application_decide/, 'the approve, decline and blacklist paths answer the switch');
my $routes = read_file("$root/lib/JawnOS/Routes/manager_box_office.pm");
like($routes, qr{/manager/box_office/relay}, 'the relay route is registered');
my $markup = read_file("$root/templates/box_office/markup.html.ep");
like($markup, qr/bo_relay_check/, 'the desk offers Check relay');
like($markup, qr/bo_ticket_name.*Relay/s, 'a relayed request is marked');
my $js = read_file("$root/public/js/manager/manager/03_box_office.js");
like($js, qr{/manager/box_office/relay}, 'the script calls the relay');
my $help = read_file("$root/perl/help/topics_configure.pl");
like($help, qr/Check relay/, 'the help explains the relay');

done_testing();
