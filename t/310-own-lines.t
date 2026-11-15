# tests-for: lib/JawnOS/Domain/Web.pm lib/JawnOS/Domain/Sync.pm lib/JawnOS/Manager/Part37.pm lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Routes/manager_phone.pm templates/apps/phone.html.ep public/js/manager/phone.js perl/help/topics_web.pl perl/utility_jobs.pl
# covers:    the house knows its own numbers - a phone's SIMs from the radio, a
#           VoIP line typed in - and never counts one as a member of a group.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

require "$FindBin::Bin/../lib/JawnOS/Manager/Part37.pm";

my $root = repo_root();

{ package FakeRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
  sub hashes { return $_[0]->{'rows'}; }
}

my $rows = sub {
	return FakeRows->new([
		{ app => 'sim1',    value => '15199188319',      device => 'Phone' },
		{ app => 'textnow', value => '(519) 918-8320',   device => 'Tablet' },
		{ app => 'sim1',    value => '15199188319',      device => 'Phone' },
		{ app => 'sim2',    value => '',                 device => 'Phone' },
	]);
};

# ---------------------------------------------------------------- the lines
{
	local *subs::db_query = sub { return $rows->() };
	my $all = subs::own_phone_lines();
	is_deeply( [ map { $_->{'number'} } @{$all} ], [ '5199188319', '5199188320' ],
		'every line is read once, as the digits the house keys a thread by' );
	is_deeply( [ map { $_->{'label'} } @{$all} ], [ 'sim1', 'textnow' ], 'each line wears its own name' );
	my $phone = subs::own_phone_lines('Phone');
	is_deeply( [ map { $_->{'label'} } @{$phone} ], [ 'sim1' ], 'a device sees only its own lines' );
}

{
	local *subs::machine_hostname = sub { return 'Phone' };
	local *subs::db_query = sub { return $rows->() };
	ok( subs::own_phone_number('+1 (519) 918-8319'), 'the phone\'s own SIM is its own, however it is written' );
	ok( !subs::own_phone_number('5199188320'), 'the tablet\'s line is not this device\'s' );
	ok( !subs::own_phone_number('5551234567'), 'a stranger is not the house' );
	ok( !subs::own_phone_number(''), 'nothing is not a number' );
}

# ---------------------------------------------------------------- the radio
{
	my @writes;
	local $subs::device = 'mobile';
	local *subs::device_call = sub { return { lines => [
		{ slot => 0, number => '+1 519 918 8319', carrier => 'Rogers' },
		{ slot => 1, number => '', carrier => 'Telus' },
	] } };
	local *subs::machine_hostname = sub { return 'Phone' };
	local *subs::db_select = sub { return FakeRows->new([]) };
	local *subs::db_query = sub { return FakeRows->new([]) };
	local *subs::setting_setter = sub { push @writes, $_[0]; return 1 };
	my $n = subs::telephone_own_number_check();
	is( $n, 1, 'the SIM with a number is filed, the one without is not' );
	is( $writes[0]->{'app'}, 'sim1', 'the line is named for its slot' );
	is( $writes[0]->{'setting'}, 'own_phone', 'and kept as an own line' );
	is( $writes[0]->{'value'}, '5199188319', 'the number is stored as bare digits' );
	is( $writes[0]->{'device'}, 'Phone', 'the row belongs to this machine' );
}

{
	my @writes;
	local $subs::device = 'mobile';
	local *subs::device_call = sub { return { lines => [ { slot => 0, number => '5199188319' } ] } };
	local *subs::machine_hostname = sub { return 'Phone' };
	local *subs::db_select = sub {
		my (undef, undef, $where) = @_;
		return FakeRows->new( ($where->{'app'} // '') eq 'sim1' ? [ { value => '5199188319' } ] : [] );
	};
	local *subs::db_query = sub { return FakeRows->new([ { app => 'sim1' }, { app => 'sim2' }, { app => 'textnow' } ]) };
	local *subs::setting_setter = sub { push @writes, $_[0]; return 1 };
	my $n = subs::telephone_own_number_check();
	is( $n, 1, 'an unchanged line is not rewritten' );
	is( $writes[0]->{'app'}, 'sim2', 'only the pulled SIM is cleared' );
	is( $writes[0]->{'value'}, '', 'and the typed VoIP line is left alone' );
}

# ---------------------------------------------------------------- the group
{
	local *subs::db_query = sub { return FakeRows->new([ { phone => '5199188319', cc => '5199188319, 5199188322' } ]) };
	local *subs::own_phone_number = sub { return (($_[0] // '') eq '5199188319') ? 1 : 0 };
	my $people = Manager::mailws_group_addresses('mms:42');
	is_deeply( $people, ['5199188322'], 'the house\'s own line is not one of the people to reply to' );
}

my $sync = read_file("$root/lib/JawnOS/Domain/Sync.pm");
like( $sync, qr/next if &subs::own_phone_number\(\$peer\);/, 'an inbound group leaves the house\'s own line out of its cc' );

# ---------------------------------------------------------------- the app page
my $route = read_file("$root/lib/JawnOS/Routes/manager_phone.pm");
like( $route, qr{post', '/manager/phone/lines', 'action_91842'}, 'the Lines pane has a route' );

my $controller = read_file("$root/lib/JawnOS/Controller/manager_phone.pm");
like( $controller, qr/sub action_91842 \{/, 'and an action' );
like( $controller, qr/own_lines => &subs::own_phone_lines\(&subs::machine_hostname\(\)\)/, 'the page hands its own lines to the pane' );

my $template = read_file("$root/templates/apps/phone.html.ep");
like( $template, qr/pane="lines"/, 'the Phone app has a Lines pane' );
like( $template, qr/id="phone_line_add"/, 'with an Add button' );

my $js = read_file("$root/public/js/manager/phone.js");
like( $js, qr{url: '/manager/phone/lines'}, 'the page saves a line through the route' );

my $help = read_file("$root/perl/help/topics_web.pl");
like( $help, qr/The Lines pane is the other side of that/, 'the help topic explains the Lines pane' );

my $jobs = read_file("$root/perl/utility_jobs.pl");
like( $jobs, qr/telephone_own_number_check/, 'the telephone poll keeps the SIM lines current' );

done_testing();
