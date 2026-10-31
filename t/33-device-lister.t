use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Mojo::JSON qw(encode_json);
use JawnOSTest;

# The Dev panel's two blind spots:
#   - a peer the house knows (remote_machines) but no neighbour table lists, so
#     a tailnet or other-subnet machine never appeared at all; and
#   - a router row that is only history, which a roaming laptop piled up as an
#     unnamed "Router" per network it had left.
# Both are read-only listings; neither test touches the live database.

# db_select returns a Mojo::Collection in the app, and the callers only ask it
# for ->hashes.
{
	package FakeRows;
	sub new   { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
}

# ---------------------------------------------------------------- router_list
{
	my $now = &subs::rightNow();
	my $H   = 3600 * 1000;
	my @rows = (
		{ uuid => 'r-current', ip => '192.168.1.1', name => 'Linksys Smart Wi-Fi', last_seen => $now - 60 * 1000 },
		{ uuid => 'r-fresh',   ip => '10.0.0.1',    name => 'Fresh',              last_seen => $now - 2 * $H },
		{ uuid => 'r-stale',   ip => '172.16.0.1',  name => '',                   last_seen => $now - 3 * 86400000 },
		{ uuid => 'r-live-old', ip => '10.9.9.9',   name => 'Still the gateway',  last_seen => $now - 5 * 86400000 },
	);
	local *subs::db_select = sub {
		is $_[0], 'routers', 'router_list reads the routers table';
		return FakeRows->new([ map { { %{$_} } } @rows ]);
	};
	local *subs::network_interface_reporter = sub {
		return { eth0 => { gw => '192.168.1.1' }, eth1 => { gw => '10.9.9.9' } };
	};
	my $list = &subs::router_list();
	is_deeply [ map { $_->{'ip'} } @{$list} ],
		[ '192.168.1.1', '10.0.0.1', '10.9.9.9' ],
		'newest sighting first, a stale router dropped, a live gateway kept';
	ok !grep({ $_->{'ip'} eq '172.16.0.1' } @{$list}),
		'a router seen three days ago on no live NIC is not shown';
	is $list->[0]->{'online'}, 1, 'a router seen a minute ago is online';
	is $list->[1]->{'online'}, 0, 'one seen two hours ago is greyed, not dropped';
}

# -------------------------------------------------------- remote_machine_orphans
{
	my $devices = [
		{
			uuid     => 'self',
			hostname => 'me',
			address  => encode_json({
				wlo1 => {
					ip    => '192.168.1.10',
					neigh => [
						{ signatorial => 'peer-lan', ip => '192.168.1.50' },
						{ ip => '192.168.1.60' },
					],
				},
			}),
		},
	];
	my @remote = (
		{
			uuid => 'rm-a', signatorial => 'peer-tailnet', ip => '100.64.0.5',
			fqdn => 'tablet.tailnet.ts.net', hostname => 'Tablet', port => 45545,
			privilege => 'trusted', grant_scope => 'trusted',
			grant_expires => time() * 1000 + 86400000,
			manager => 'http://127.0.0.1:45545/manager',
			buttons => '<button manager="http://127.0.0.1:45545/manager">Go</button>',
		},
		{ uuid => 'rm-lan',   signatorial => 'peer-lan', ip => '192.168.1.50', hostname => 'Laptop' },
		{ uuid => 'rm-ip',    signatorial => '',         ip => '192.168.1.60', hostname => 'Printer' },
		{ uuid => 'rm-self',  signatorial => 'self-sign', ip => '127.0.0.1',   hostname => 'me' },
		{ uuid => 'rm-dup',   signatorial => 'peer-tailnet', ip => '100.64.0.5', hostname => 'Tablet again' },
	);
	local *subs::db_select = sub {
		is $_[0], 'remote_machines', 'the orphan list reads remote_machines';
		return FakeRows->new([ map { { %{$_} } } @remote ]);
	};
	local *subs::signatorial_designer = sub { return 'self-sign' };
	my $orphans = &subs::remote_machine_orphans($devices);
	is scalar @{$orphans}, 1, 'only the machine no neighbour table shows is listed';
	is $orphans->[0]->{'signatorial'}, 'peer-tailnet', 'and it is the tailnet peer';
	is $orphans->[0]->{'hostname'}, 'Tablet', 'with the name the picker uses';
	like $orphans->[0]->{'buttons'},
		qr{manager="https://tablet\.tailnet\.ts\.net:45545/manager"},
		'its Go button is moved off loopback onto the peer name';
	is $orphans->[0]->{'manager'}, 'https://tablet.tailnet.ts.net:45545/manager',
		'and the row carries that manager';
	is $orphans->[0]->{'grant_scope'}, 'trusted', 'the grant scope comes along';
	is $orphans->[0]->{'privilege'}, 'trusted', 'so does the privilege';
	ok $orphans->[0]->{'grant_expires'}, 'and the grant expiry';
}

# The helper only matters if the route passes its rows and the template draws
# the card; pin that wiring too, so a later rename cannot quietly hide them.
{
	my $root = root();
	my $read = sub {
		open(my $fh, '<', $_[0]) or die "$_[0]: $!";
		local $/;
		my $text = <$fh>;
		close $fh;
		return $text;
	};
	my $template = $read->("$root/templates/configure/device_lister.html.ep");
	like $template, qr/id="remote_machines_card"/, 'the Dev panel draws the unlisted-machines card';
	like $template, qr/\@\{\$remote_machines\}/, 'from the stash list the route passes';
	like $template, qr/class="remote_migrate"/, 'with the Migrate control';
	my $manager = $read->("$root/Manager.pl");
	like $manager, qr/remote_machines => \$remote_machines/, 'and the route passes the orphans in';
}

done_testing();
