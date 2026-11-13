# tests-for: scripts/offline_check.pl
# covers:    the offline readiness report - LAN-first route ranking, the hub/WAN
#           distinction, the presence-listener blocker, and no secret in the output

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use DBI;
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;

use JawnOSTest;

require "$FindBin::Bin/../scripts/offline_check.pl";

sub write_text {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or die "write $path: $!";
	print $fh $text;
	close $fh;
}

my $dir = tempdir(CLEANUP => 1);
my $db = "$dir/jawnos.db";
my $config = "$dir/config.json";
write_text($config, JSON::PP->new->canonical->encode({
	name => 'Test Box',
	device => 'computer',
	domain => '127.0.0.1',
	working_port => 45545,
	loopback_manager => 1,
}));

my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', {
	RaiseError => 1, PrintError => 0, AutoCommit => 1,
});
$dbh->do(<<'SQL');
CREATE TABLE remote_machines (
	uuid TEXT, ip TEXT, signatorial TEXT, hostname TEXT, fqdn TEXT, port TEXT,
	manager TEXT, connection TEXT, tunnel TEXT, network TEXT, tailnet_ip TEXT,
	device TEXT, pubkey TEXT, pseudonyms TEXT, lan_ip TEXT, vip TEXT,
	cookie TEXT, ws_auth TEXT, version TEXT, dock_port TEXT
)
SQL
$dbh->do('CREATE TABLE settings (app TEXT, setting TEXT, value TEXT, device TEXT, server_time TEXT)');

my $add_peer = sub {
	my (%peer) = @_;
	my @cols = sort keys %peer;
	my $sql = 'INSERT INTO remote_machines (' . join(',', @cols) . ') VALUES ('
		. join(',', ('?') x @cols) . ')';
	$dbh->do($sql, undef, @peer{@cols});
};

# A same-LAN peer, a tailnet-only peer, the hub, an inactive peer, and a peer
# with no literal address at all.
$add_peer->(uuid => 'u1', hostname => 'Laptop', signatorial => 'a1a1a1a1',
	ip => '192.168.1.50', port => '45545', manager => 'https://192.168.1.50:45545',
	connection => 'active', tunnel => 'no', device => 'computer',
	fqdn => 'laptop.example', pubkey => 'key-laptop',
	network => '{"lan":{"ip":"192.168.1.50","port":"45545"}}');
$add_peer->(uuid => 'u2', hostname => 'Phone', signatorial => 'b2b2b2b2',
	ip => '100.64.0.9', port => '45545', manager => 'https://100.64.0.9:45545',
	connection => 'active', tunnel => 'no', device => 'mobile',
	fqdn => 'phone.example', pubkey => 'key-phone',
	network => '{"lan":{"ip":"100.64.0.9","port":"45545"}}');
$add_peer->(uuid => 'u3', hostname => 'hub', signatorial => 'c3c3c3c3',
	ip => '10.20.0.20', port => '45545', manager => 'https://10.20.0.20:45545',
	connection => 'active', tunnel => 'no', device => 'server',
	fqdn => 'hub.example', pubkey => 'key-hub', network => '{}');
$add_peer->(uuid => 'u4', hostname => 'Tablet', signatorial => 'd4d4d4d4',
	ip => '192.168.1.103', port => '45545', manager => 'https://192.168.1.103:45545',
	connection => 'inactive', tunnel => 'no', device => 'mobile',
	fqdn => 'tablet.example', pubkey => 'key-tablet',
	network => '{"lan":{"ip":"192.168.1.103","port":"45545"}}');
$add_peer->(uuid => 'u5', hostname => 'Ghost', signatorial => 'e5e5e5e5',
	port => '45545', manager => 'https://ghost.example:45545',
	connection => 'active', tunnel => 'no', device => 'computer',
	fqdn => 'ghost.example', pubkey => 'key-ghost', network => '{}');

$dbh->do("INSERT INTO settings (app,setting,value,device,server_time) VALUES ('__president','sync_hub','c3c3c3c3',NULL,'1000')");
$dbh->do("INSERT INTO settings (app,setting,value,device,server_time) VALUES ('sync','topology','auto','all','1000')");
$dbh->disconnect;

my $nics = [ { nic => 'wlan0', ip => '192.168.1.5', prefix => 24, kind => 'lan' } ];

sub run_report {
	my (%override) = @_;
	return JawnOS::OfflineCheck::report(
		root => $dir,
		db => $db,
		config => $config,
		nics => $nics,
		listeners => { tcp => { 45545 => 1 }, udp => { 45552 => 1 } },
		mdns => 'avahi',
		house_ca => '',
		probe => 0,
		now => 1760000000,
		%override,
	);
}

# --- the ranking matches the peer rail ---------------------------------------
{
	my $one = [ { nic => 'wlan0', ip => '192.168.1.5', prefix => 24 } ];
	is(JawnOS::OfflineCheck::address_rank('192.168.1.50', $one), 0, 'a same-LAN literal is first');
	is(JawnOS::OfflineCheck::address_rank('10.1.2.3', $one), 2, 'a private literal off this LAN is third');
	is(JawnOS::OfflineCheck::address_rank('100.64.0.9', $one), 1, 'the tailnet is second');
	is(JawnOS::OfflineCheck::address_rank('8.8.8.8', $one), 3, 'a public literal is after that');
	is(JawnOS::OfflineCheck::address_rank('127.0.0.1', $one), 4, 'a tunnel loopback is last');
	ok(JawnOS::OfflineCheck::same_net('192.168.1.99', $one->[0]), 'a /24 neighbour shares the subnet');
	ok(!JawnOS::OfflineCheck::same_net('192.168.2.99', $one->[0]), 'another /24 does not');

	for my $ip (qw(10.1.2.3 192.168.1.50 172.16.0.1 169.254.1.1 100.64.0.9 100.127.255.254 8.8.8.8 127.0.0.1)) {
		is(JawnOS::OfflineCheck::base_address_rank($ip), subs::peer_address_rank($ip),
			"the base rank for $ip matches subs::peer_address_rank");
	}

	is(JawnOS::OfflineCheck::peer_port_for(45545), 45551, 'the peer listener is the main port + 6');
	is(JawnOS::OfflineCheck::peer_port_for(65533), 65527, 'a port whose + 6 would overflow wraps back');
	is(JawnOS::OfflineCheck::peer_port_for(65535), 65529, 'the top port wraps the same way');

	my $map_row = { network => '{"eth0":{"ip":"192.168.1.50","port":"45545"}}' };
	my $map_net = { eth0 => { ip => '192.168.1.50', port => '45545' } };
	my @client = JawnOS::OfflineCheck::literal_candidates($map_row, $map_net, $one, 45545, 'computer');
	my @server = JawnOS::OfflineCheck::literal_candidates($map_row, $map_net, $one, 45545, 'server');
	is(scalar @client, 1, 'a client may dial an address from the peer network map');
	is(scalar @server, 0, 'the hub does not dial a home address from the peer network map');
}

# --- the report --------------------------------------------------------------
{
	my $r = run_report();
	is($r->{'machine'}{'working_port'}, 45545, 'the working port comes from config');
	is($r->{'local'}{'manager_listener'}, 'listening', 'the manager listener is read locally');
	is($r->{'local'}{'presence_listener'}, 'listening', 'the presence listener is read locally');

	my %peer = map { $_->{'hostname'} => $_ } @{ $r->{'peers'} };
	is($peer{'Laptop'}{'route'}, 'lan', 'a same-LAN peer is LAN-ready');
	ok($peer{'Laptop'}{'lan_ready'}, 'and is not a blocker');
	is($peer{'Phone'}{'route'}, 'tailnet', 'a peer with only a tailnet address needs the WAN');
	ok(!$peer{'Phone'}{'lan_ready'}, 'and is a blocker');
	is($peer{'hub'}{'route'}, 'off-lan', 'the hub is an off-LAN literal');
	ok($peer{'hub'}{'is_hub'}, 'the hub is recognised by device=server / sync_hub');
	is($peer{'Tablet'}{'route'}, 'lan', 'an inactive peer still reports its LAN route');
	is($peer{'Ghost'}{'route'}, 'name', 'a row with no literal address is name-only');
	is($peer{'Ghost'}{'best'}, undef, 'and has no literal candidate');

	is($r->{'verdict'}{'lan_peers'}, 2, 'Laptop and Tablet have a LAN route');
	is($r->{'verdict'}{'wan_only_peers'}, 3, 'the hub, Phone and Ghost are WAN-only');
	is($r->{'verdict'}{'exit_code'}, 1, 'the report exits 1 while a LAN peer is missing');
	is(scalar @{ $r->{'verdict'}{'blockers'} }, 2, 'Phone and Ghost are blockers');
	like($r->{'verdict'}{'blockers'}[0]{'blocker'}, qr/tailnet|name/,
		'a blocker names the route that would be needed');
}

# --- after the LAN address is learned ---------------------------------------
{
	my $w = DBI->connect("dbi:SQLite:dbname=$db", '', '', {
		RaiseError => 1, PrintError => 0, AutoCommit => 1,
	});
	$w->do("UPDATE remote_machines SET ip=?, network=? WHERE hostname='Phone'",
		undef, '192.168.1.106', '{"lan":{"ip":"192.168.1.106","port":"45545"}}');
	$w->do("DELETE FROM remote_machines WHERE hostname='Ghost'");
	$w->disconnect;

	my $r = run_report();
	my %peer = map { $_->{'hostname'} => $_ } @{ $r->{'peers'} };
	is($peer{'Phone'}{'route'}, 'lan', 'the learned LAN address wins');
	is($r->{'verdict'}{'exit_code'}, 0, 'with every active peer on the LAN the report exits 0');
	is(scalar @{ $r->{'verdict'}{'blockers'} }, 0, 'and has no blockers');
}

# --- local readiness ---------------------------------------------------------
{
	my $r = run_report(listeners => { tcp => { 45545 => 1 }, udp => {} });
	is($r->{'verdict'}{'exit_code'}, 1, 'a missing presence listener is a blocker');
	ok((grep { ($_->{'blocker'} // '') =~ /presence/ } @{ $r->{'verdict'}{'blockers'} }),
		'the blocker names the presence rail');

	$r = run_report(listeners => { tcp => {}, udp => { 45552 => 1 } });
	ok((grep { ($_->{'blocker'} // '') =~ /manager/ } @{ $r->{'verdict'}{'blockers'} }),
		'a missing manager listener is a blocker');
}

# --- the report carries no secret -------------------------------------------
{
	my $w = DBI->connect("dbi:SQLite:dbname=$db", '', '', {
		RaiseError => 1, PrintError => 0, AutoCommit => 1,
	});
	$w->do("INSERT INTO remote_machines (uuid,hostname,signatorial,ip,port,manager,connection,tunnel,device,network,cookie,ws_auth,pubkey) VALUES ('u9','Secret','f6f6f6f6','192.168.1.99','45545','https://192.168.1.99:45545','active','no','computer','{}','SECRETCOOKIE','SECRETWS','SECRETPUB')");
	$w->disconnect;

	my $r = run_report();
	my $json = JSON::PP->new->canonical->encode($r);
	unlike($json, qr/SECRETCOOKIE/, 'the session cookie is not in the report');
	unlike($json, qr/SECRETWS/, 'the websocket auth is not in the report');
	unlike($json, qr/SECRETPUB/, 'the pubkey is not in the report');
	ok(ref JSON::PP->new->decode($json) eq 'HASH', 'the report survives a JSON round trip');
}

done_testing;
