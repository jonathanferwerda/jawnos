# tests-for: lib/JawnOS.pm lib/JawnOS/Controller/ lib/JawnOS/Domain/Edt.pm lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Network.pm lib/JawnOS/Domain/Render.pm lib/JawnOS/Manager.pm lib/JawnOS/Manager/ lib/JawnOS/Routes.pm lib/JawnOS/Routes/ perl/Manager.pl templates/configure/device_lister.html.ep templates/configure/device_lister/
# covers:    The domain layer is lazy: load the real definitions before any local *subs:: stub below, or the module load wo...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;
use Mojo::JSON qw(encode_json);
use JawnOSTest;

# The domain layer is lazy: load the real definitions before any local *subs::
# stub below, or the module load would replace the stub mid-test.
subs::preload($_) for qw(db_select db_query formatted_time
	network_interface_reporter signatorial_designer
	router_discover device_scan refresh_self_address
	network_groups ip_sort_key subnet_cidr);

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

# ------------------------------------------------------ listing vs. scanning
# A view must not look at the network. The gateway probe is a bounded HTTP
# request, but a gateway that does not answer (a VPN or container NIC) costs its
# whole timeout, and a listing waited on it. Only Scan may probe; the background
# mDNS tick keeps the gateway row current the rest of the time.
{
	my @did;
	local *subs::router_discover      = sub { push @did, 'discover'; return 1 };
	local *subs::device_scan          = sub { push @did, 'scan'; return 1 };
	local *subs::refresh_self_address = sub { return 0 };
	local *subs::db_query = sub { return FakeRows->new([]) };
	local *subs::db_select = sub { return FakeRows->new([]) };

	&subs::device_lister(0, 'list');
	is_deeply \@did, [], 'a plain listing neither probes the gateway nor scans';

	&subs::device_lister(0, 'scan');
	is_deeply \@did, [ 'discover', 'scan' ], 'Scan probes the gateway and sweeps';

	@did = ();
	&subs::device_lister(0, 'ping_scan');
	is_deeply \@did, [ 'scan' ], 'a ping scan sweeps but does not probe the gateway';
}

# ---------------------------------------------------- the table's order
# A neighbour table used to be sorted by the address as text, so .5 came after
# .147 and an address that changed (DHCP) moved the row around. Name first,
# then the address numerically; an unnamed device follows the named ones.
{
	my $devices = [ {
		uuid => 'self', hostname => 'me',
		address => encode_json({ eth0 => {
			ip => '192.168.1.10', netmask => '255.255.255.0',
			neigh => [
				{ name => 'HP OfficeJet 3830 series', ip => '192.168.1.109' },
				{ name => 'Tablet', ip => '192.168.1.103' },
				{ name => 'Tablet', ip => '192.168.1.9' },
				{ name => 'Table', ip => '192.168.1.147' },
				{ name => 'laptop', ip => '192.168.1.9' },
				{ ip => '192.168.1.5' },
			],
		} }),
	} ];
	my $groups = &subs::network_groups($devices);
	is_deeply(
		[ map { (defined $_->{'name'} ? $_->{'name'} : '') . '@' . $_->{'ip'} }
			@{ $groups->[0]{'members'}[0]{'neigh'} } ],
		[ 'HP OfficeJet 3830 series@192.168.1.109', 'laptop@192.168.1.9',
		  'Table@192.168.1.147', 'Tablet@192.168.1.9', 'Tablet@192.168.1.103',
		  '@192.168.1.5' ],
		'neighbours sort by name, then by address numerically, unnamed last'
	);
}

# The Peers card is ordered the same way, so a sync does not shuffle it.
{
	my @remote = (
		{ uuid => 'a', signatorial => 'sa', ip => '100.64.0.8', hostname => 'Tablet' },
		{ uuid => 'b', signatorial => 'sb', ip => '100.64.0.1', hostname => 'Table' },
		{ uuid => 'c', signatorial => 'sc', ip => '100.64.0.3', hostname => 'Laptop' },
	);
	local *subs::db_select = sub { return FakeRows->new([ map { { %{$_} } } @remote ]) };
	local *subs::signatorial_designer = sub { return 'self-sign' };
	my $orphans = &subs::remote_machine_orphans([]);
	is_deeply [ map { $_->{'hostname'} } @{$orphans} ],
		[ 'Laptop', 'Table', 'Tablet' ],
		'the Peers card is ordered by name too';
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
	my $template = template_source('configure/device_lister');
	like $template, qr/id="remote_machines_card"/, 'the Dev panel draws the unlisted-machines card';
	like $template, qr/\@\{\$remote_machines\}/, 'from the stash list the route passes';
	like $template, qr/class="remote_migrate"/, 'with the Migrate control';
	my $manager = manager_source();
	like $manager, qr/remote_machines => \$remote_machines/, 'and the route passes the orphans in';
}

done_testing();
