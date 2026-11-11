# tests-for: scripts/house_ca.pl lib/JawnOS/Domain/Remote.pm lib/JawnOS/Domain/Git.pm lib/JawnOS/Domain/Loader.pm perl/President.pl perl/Music/02_remote_audio_stream.pl perl/Music/03_remote_video.pl lib/JawnOS/Domain/Network.pm
# covers:    The house CA issues a leaf with IP and DNS SANs, the peer listener
#           is a second listener, and a peer URL moves to it only when the peer
#           answers there and this machine holds the CA.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file slurp);
use File::Temp qw(tempdir);
use IO::Socket::INET;

my $root = abs_path("$FindBin::Bin/..");

require JawnOS::Domain::Remote;
require JawnOS::Domain::Git;

my $openssl = `command -v openssl 2>/dev/null`;
chomp $openssl;
my $perl = $^X;

# --- the CA tool ------------------------------------------------------------
SKIP: {
	skip 'openssl is not installed', 22 unless $openssl && length $openssl && -x $openssl;
	my $tmp = tempdir(CLEANUP => 1);
	make_path("$tmp/scripts");
	copy("$root/scripts/house_ca.pl", "$tmp/scripts/house_ca.pl") or die $!;

	my $init = `cd '$tmp' && $perl scripts/house_ca.pl init 2>&1`;
	is($? >> 8, 0, 'init creates the CA') or diag($init);
	ok(-s "$tmp/server/house-ca.pem", 'the CA certificate is written');
	ok(-s "$tmp/server/house-ca.key", 'the CA key is written');
	is((stat("$tmp/server/house-ca.key"))[2] & 07777, 0600, 'and the CA key is 0600');

	my $twice = `cd '$tmp' && $perl scripts/house_ca.pl init 2>&1`;
	is($? >> 8, 0, 'init twice is a no-op, not an overwrite');
	like($twice, qr/already exists/, 'and says so');

	my $issue = `cd '$tmp' && $perl scripts/house_ca.pl issue --name dev --ip 10.20.0.10 --ip 100.64.0.4 --dns dev.jonathanferwerda.com 2>&1`;
	is($? >> 8, 0, 'issue creates a leaf') or diag($issue);
	ok(-s "$tmp/server/peer-fullchain.pem", 'the leaf chain is written');
	is((stat("$tmp/server/peer-privkey.pem"))[2] & 07777, 0600, 'and the leaf key is 0600');

	my $text = slurp("$tmp/server/peer-fullchain.pem");
	my $leaf = do {
		my ($first) = $text =~ /(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)/s;
		my $f = "$tmp/leaf.pem";
		write_file($f, $first);
		$f;
	};
	my $sans = `$openssl x509 -in '$leaf' -noout -ext subjectAltName 2>&1`;
	like($sans, qr/IP Address:10\.20\.0\.10/, 'the leaf carries the LAN address');
	like($sans, qr/IP Address:100\.64\.0\.4/, 'and the tailnet address');
	like($sans, qr/DNS:dev\.jonathanferwerda\.com/, 'and the name');

	my $verify = `cd '$tmp' && $perl scripts/house_ca.pl verify 2>&1`;
	is($? >> 8, 0, 'verify accepts the chain') or diag($verify);

	my $again = `cd '$tmp' && $perl scripts/house_ca.pl issue --name dev --ip 10.20.0.10 2>&1`;
	isnt($? >> 8, 0, 'a second leaf in the same directory is refused');
	my $badname = `cd '$tmp' && $perl scripts/house_ca.pl issue --name 'bad name' --ip 10.0.0.1 2>&1`;
	isnt($? >> 8, 0, 'a name with a space is refused');
	my $nosan = `cd '$tmp' && $perl scripts/house_ca.pl issue --name dev2 --force 2>&1`;
	isnt($? >> 8, 0, 'a leaf with no address or name is refused');

	# The leaf is not signed by a public CA: prove it fails that check, which
	# is exactly why the peer listener and the house CA have to travel together.
	my $public = `$openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt '$leaf' 2>&1`;
	isnt($? >> 8, 0, 'the leaf is not trusted by the public roots');
}

# --- a real handshake: the CA leaf verifies by IP ---------------------------
SKIP: {
	skip 'openssl is not installed', 2 unless $openssl && length $openssl && -x $openssl;
	my $tmp = tempdir(CLEANUP => 1);
	make_path("$tmp/scripts", "$tmp/local");
	copy("$root/scripts/house_ca.pl", "$tmp/scripts/house_ca.pl") or die $!;
	`cd '$tmp' && $perl scripts/house_ca.pl init >/dev/null 2>&1`;
	`cd '$tmp' && $perl scripts/house_ca.pl issue --name local --ip 127.0.0.1 --out local >/dev/null 2>&1`;
	my $cert = "$tmp/local/peer-fullchain.pem";
	my $key  = "$tmp/local/peer-privkey.pem";
	my $ca   = "$tmp/server/house-ca.pem";
	SKIP: {
		skip 'the local leaf was not issued', 2 unless -s $cert && -s $key;
		my $probe = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
			Listen => 1, ReuseAddr => 1);
		skip 'could not find a free port', 2 unless $probe;
		my $port = $probe->sockport;
		close $probe;
		my $pid = fork();
		if (!defined $pid) { fail('fork failed'); }
		if (!$pid) {
			open(STDOUT, '>', '/dev/null');
			open(STDERR, '>', '/dev/null');
			exec($openssl, 's_server', '-quiet', '-www', '-accept', "127.0.0.1:$port",
				'-cert', $cert, '-key', $key);
			exit 1;
		}
		my $up = 0;
		for (1 .. 30) {
			my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
				Proto => 'tcp', Timeout => 1);
			if ($s) { $up = 1; close $s; last }
			select(undef, undef, undef, 0.1);
		}
		my $tx = Mojo::UserAgent->new(connect_timeout => 3)->tls_options({ SSL_ca_file => $ca })
			->get("https://127.0.0.1:$port/");
		ok($up && !$tx->error, 'a client trusting the house CA verifies the leaf by IP')
			or diag(($tx->error && $tx->error->{'message'}) || 'server did not start');
		my $tx2 = Mojo::UserAgent->new(connect_timeout => 3)->get("https://127.0.0.1:$port/");
		ok($tx2->error, 'the same leaf is refused without the house CA');
		kill 'TERM', $pid;
		waitpid($pid, 0);
	}
}

# --- a client machine: the certificate without the signing key -------------
SKIP: {
	skip 'openssl is not installed', 5 unless $openssl && length $openssl && -x $openssl;
	my $tmp = tempdir(CLEANUP => 1);
	make_path("$tmp/scripts");
	copy("$root/scripts/house_ca.pl", "$tmp/scripts/house_ca.pl") or die $!;
	`cd '$tmp' && $perl scripts/house_ca.pl init >/dev/null 2>&1`;
	`cd '$tmp' && $perl scripts/house_ca.pl issue --name client --ip 127.0.0.1 >/dev/null 2>&1`;
	my $before = slurp("$tmp/server/house-ca.pem");
	unlink "$tmp/server/house-ca.key";
	my $verify = `cd '$tmp' && $perl scripts/house_ca.pl verify 2>&1`;
	is($? >> 8, 0, 'a client can verify without the signing key') or diag($verify);
	my $show = `cd '$tmp' && $perl scripts/house_ca.pl show 2>&1`;
	is($? >> 8, 0, 'and show still works');
	like($show, qr/absent \(this machine is a client\)/, 'show says this machine is a client');

	my $init = `cd '$tmp' && $perl scripts/house_ca.pl init 2>&1`;
	is($? >> 8, 0, 'init on a client is a no-op');
	is(slurp("$tmp/server/house-ca.pem"), $before, 'and never replaces the house CA');
}

# --- enrolling the roster from remote_machines ------------------------------
SKIP: {
	skip 'openssl is not installed', 12 unless $openssl && length $openssl && -x $openssl;
	my $tmp = tempdir(CLEANUP => 1);
	make_path("$tmp/scripts");
	copy("$root/scripts/house_ca.pl", "$tmp/scripts/house_ca.pl") or die $!;
	`cd '$tmp' && $perl scripts/house_ca.pl init >/dev/null 2>&1`;

	my $db = "$tmp/jawnos.db";
	require DBI;
	my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
	$dbh->do('create table remote_machines (hostname text, ip text, tailnet_ip text, fqdn text, manager text, network text, domain text)');
	$dbh->do("insert into remote_machines (hostname,ip,tailnet_ip,fqdn,manager,network,domain) values ('Laptop','192.168.1.123','100.64.0.3','laptop.example.com','https://192.168.1.123:45545',null,null)");
	$dbh->do("insert into remote_machines (hostname,ip,tailnet_ip,fqdn,manager,network,domain) values ('Phone','192.168.2.4','100.64.0.9','phone.example.com','https://127.0.0.1:60877',null,null)");
	# A row whose stored ip is the tailnet and whose LAN address exists only in
	# its network map, with its manager named by DNS: both must reach the leaf.
	$dbh->do("insert into remote_machines (hostname,ip,tailnet_ip,fqdn,manager,network,domain) values ('Tablet','100.64.0.8','100.64.0.8','100.64.0.8','https://tablet.example.com:45545','{\"wlan0\":{\"ip\":\"192.168.1.103\"}}',null)");
	my $local = `hostname`;
	chomp $local;
	$dbh->do('insert into remote_machines (hostname,ip,tailnet_ip,fqdn,manager,network,domain) values (?,?,?,?,?,?,?)', undef, $local, '10.0.0.9', '', "$local.example.com", '', undef, undef);
	$dbh->disconnect;

	my $run = `cd '$tmp' && $perl scripts/house_ca.pl peer --all --db '$db' --out fleet 2>&1`;
	is($? >> 8, 0, 'peer --all issues the roster') or diag($run);
	ok(-s "$tmp/fleet/Laptop/peer-fullchain.pem", 'the laptop leaf is written');
	ok(-s "$tmp/fleet/Phone/peer-fullchain.pem", 'the phone leaf is written');
	ok(!-e "$tmp/fleet/$local/peer-fullchain.pem", 'the local machine is skipped by --all');

	my $text = slurp("$tmp/fleet/Laptop/peer-fullchain.pem");
	my ($first) = $text =~ /(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)/s;
	write_file("$tmp/laptop.pem", $first);
	my $sans = `$openssl x509 -in '$tmp/laptop.pem' -noout -ext subjectAltName 2>&1`;
	like($sans, qr/IP Address:192\.168\.1\.123/, 'the row LAN address is a SAN');
	like($sans, qr/IP Address:100\.64\.0\.3/, 'the tailnet address is a SAN');
	like($sans, qr/IP Address:127\.0\.0\.1/, 'loopback is a SAN');
	like($sans, qr/DNS:laptop\.example\.com/, 'the fqdn is a SAN');

	my $tabtext = slurp("$tmp/fleet/Tablet/peer-fullchain.pem");
	my ($tabfirst) = $tabtext =~ /(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)/s;
	write_file("$tmp/tablet.pem", $tabfirst);
	my $tabsans = `$openssl x509 -in '$tmp/tablet.pem' -noout -ext subjectAltName 2>&1`;
	like($tabsans, qr/IP Address:192\.168\.1\.103/, 'the LAN address in the network map is a SAN');
	like($tabsans, qr/DNS:tablet\.example\.com/, 'and a manager named by DNS is a SAN');

	my $again = `cd '$tmp' && $perl scripts/house_ca.pl peer --host Laptop --db '$db' --out fleet 2>&1`;
	is($? >> 8, 0, 'a second run keeps the existing leaf');
	like($again, qr/already exists/, 'and says it kept it');
}

# --- the peer port and the URL rewrite --------------------------------------
is(subs::peer_port_for({ port => 45545 }), 45551, 'the peer port is the main port plus six');
is(subs::peer_port_for({ port => 3001 }), 3007, 'and follows a working_port too');
is(subs::peer_port_for({}), 45551, 'a row with no port falls back to the house port');
is(subs::peer_port_for(65534), 65528, 'a port that would overflow wraps down');

# A stored LAN route whose leaf predates that address can still be reached on
# another address the same row advertises (its tailnet), and that listener is
# verified. This is the route a same-LAN peer uses when the leaf is stale.
{
	local *subs::peer_tls_port = sub {
		my ($rm, $opts) = @_;
		return 45551 if ($opts->{'host'} || '') eq '100.64.0.1';
		return 0;
	};
	local *subs::peer_listener_port = sub { return 0 };
	my ($alt_url, $alt_verified) = subs::peer_secure_url(
		{ ip => '192.168.1.147', tailnet_ip => '100.64.0.1', port => 45545, tunnel => 'no' },
		'https://192.168.1.147:45545/manager');
	is($alt_verified, 1, 'a verified alternate address the row advertises is used');
	is($alt_url, 'https://100.64.0.1:45551/manager', 'and the URL moves to that host and listener port');
}

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/server");
write_file("$tmp/server/house-ca.pem", "not a real certificate\n");
local $ENV{'JAWNOS_ROOT'} = $tmp;
is(subs::peer_ca_file(), "$tmp/server/house-ca.pem", 'the CA is found through JAWNOS_ROOT');

require Mojo::UserAgent;
my $ua = Mojo::UserAgent->new;
ok(subs::peer_tls_verify($ua), 'peer_tls_verify reports the CA');
is($ua->tls_options->{'SSL_ca_file'}, "$tmp/server/house-ca.pem", 'and points the agent at it');

# A socket that answers is not enough: the leaf has to prove the address the
# peer will be dialled by, or the verified request dies in the handshake. A bare
# TCP listener serves nothing that can prove, so the stored route is kept.
my $listener = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
	Listen => 5, ReuseAddr => 1);
SKIP: {
	skip 'could not open a loopback listener', 5 unless $listener;
	my $peer_port = $listener->sockport;
	my $rm = { ip => '127.0.0.1', port => $peer_port - 6, tunnel => 'no' };
	my $manager_url = 'https://127.0.0.1:' . ($peer_port - 6) . '/manager/vault_share?x=1';
	my ($url, $verified) = subs::peer_secure_url($rm, $manager_url);
	is($verified, 0, 'a listener that cannot prove its address is chosen unverified');
	like($url, qr{^https://127\.0\.0\.1:$peer_port/manager/vault_share\?x=1$},
		'and the path and query move to the listener port');

	my ($tunnel_url, $tunnel_verified) = subs::peer_secure_url(
		{ %$rm, tunnel => 'yes' }, "https://127.0.0.1:$peer_port/manager");
	is($tunnel_verified, 0, 'a tunnel row keeps its loopback route');
	is($tunnel_url, "https://127.0.0.1:$peer_port/manager", 'unchanged');

	my ($other_url, $other_verified) = subs::peer_secure_url($rm, 'https://10.9.9.9/manager');
	is($other_verified, 0, 'a URL that is not the row address is left alone');
	is($other_url, 'https://10.9.9.9/manager', 'unchanged');
}


# --- the probe follows the leaf, not just the socket ------------------------
# The bug this proves: a phone's LAN address moved (DHCP), its leaf still named
# the old one, and every verified call to the listener failed with "hostname
# verification failed" and no response at all - CloudSync read the peer as
# "answered no status" while it was up. The probe now handshakes against the
# house CA, so only a listener whose leaf names this address is chosen.
SKIP: {
	skip 'openssl is not installed', 5 unless $openssl && length $openssl && -x $openssl;
	my $tmp = tempdir(CLEANUP => 1);
	make_path("$tmp/scripts");
	copy("$root/scripts/house_ca.pl", "$tmp/scripts/house_ca.pl") or die $!;
	`cd '$tmp' && $perl scripts/house_ca.pl init >/dev/null 2>&1`;
	`cd '$tmp' && $perl scripts/house_ca.pl issue --name here --ip 127.0.0.1 --out here >/dev/null 2>&1`;
	`cd '$tmp' && $perl scripts/house_ca.pl issue --name moved --ip 10.20.0.10 --out moved >/dev/null 2>&1`;
	my %cert = (
		here  => "$tmp/here/peer-fullchain.pem",
		moved => "$tmp/moved/peer-fullchain.pem",
	);
	my %key = (
		here  => "$tmp/here/peer-privkey.pem",
		moved => "$tmp/moved/peer-privkey.pem",
	);
	local $ENV{'JAWNOS_ROOT'} = $tmp;
	my $serve = sub {
		my ($name) = @_;
		return () unless -s $cert{$name} && -s $key{$name};
		my $probe = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0,
			Proto => 'tcp', Listen => 1, ReuseAddr => 1);
		return () unless $probe;
		my $port = $probe->sockport;
		close $probe;
		my $pid = fork();
		return () unless defined $pid;
		if (!$pid) {
			open(STDOUT, '>', '/dev/null');
			open(STDERR, '>', '/dev/null');
			exec($openssl, 's_server', '-quiet', '-www', '-accept', "127.0.0.1:$port",
				'-cert', $cert{$name}, '-key', $key{$name});
			exit 1;
		}
		for (1 .. 30) {
			my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port,
				Proto => 'tcp', Timeout => 1);
			if ($s) { close $s; last }
			select(undef, undef, undef, 0.1);
		}
		return ($pid, $port);
	};

	my ($here_pid, $here_port) = $serve->('here');
	if (!$here_pid) {
		skip 'the leaf listener did not start', 8;
	}
	else {
		my ($url, $verified) = subs::peer_secure_url(
			{ ip => '127.0.0.1', port => $here_port - 6, tunnel => 'no' },
			'https://127.0.0.1:' . ($here_port - 6) . '/manager');
		is($verified, 1, 'a listener whose leaf names this address is verified');
		like($url, qr{^https://127\.0\.0\.1:$here_port/manager$}, 'and the URL moves to its port');
		is(subs::peer_tls_port({ ip => '127.0.0.1', port => $here_port - 6 }, { host => '127.0.0.1' }),
			$here_port, 'the probe answers with the listener port');
		# A hand-entered row can carry a loopback fqdn while the house reaches
		# the machine on its advertised tailnet address. That address is the
		# same peer, so it must be a route the TLS decision will accept.
		my ($alt_url, $alt_verified) = subs::peer_secure_url(
			{ ip => '192.168.1.123', fqdn => 'dev.local',
			  tailnet_ip => '127.0.0.1',
			  network => '{"tailscale0":{"ip":"127.0.0.1"}}',
			  port => $here_port - 6, tunnel => 'no' },
			'https://127.0.0.1:' . ($here_port - 6) . '/manager');
		is($alt_verified, 1, 'an advertised tailnet address is verified even when it is neither ip nor fqdn');
		like($alt_url, qr{^https://127\.0\.0\.1:$here_port/manager$}, 'and the URL moves to that listener port');
		my ($mgr_url, $mgr_verified) = subs::peer_secure_url(
			{ ip => '192.168.1.123', fqdn => 'dev.local',
			  manager => 'https://127.0.0.1:' . ($here_port - 6),
			  port => $here_port - 6, tunnel => 'no' },
			'https://127.0.0.1:' . ($here_port - 6) . '/manager');
		is($mgr_verified, 1, 'the stored manager host is a route too');
		kill 'TERM', $here_pid;
		waitpid($here_pid, 0);
		my ($moved_pid, $moved_port) = $serve->('moved');
		if (!$moved_pid) {
			skip 'the second leaf listener did not start', 2;
		}
		else {
			my ($moved_url, $moved_verified) = subs::peer_secure_url(
				{ ip => '127.0.0.1', port => $moved_port - 6, tunnel => 'no' },
				'https://127.0.0.1:' . ($moved_port - 6) . '/manager');
			is($moved_verified, 0, 'a leaf that names another address is not trusted for it');
			like($moved_url, qr{^https://127\.0\.0\.1:$moved_port/manager$},
				'but the listener is still dialled, on the signature alone');
			kill 'TERM', $moved_pid;
			waitpid($moved_pid, 0);
		}
	}
}

# --- the listener and the advertisement -------------------------------------
my $president = read_file("$root/perl/President.pl");
like($president, qr/JawnOS::Platform::Ports::port_for\('peer', base => \$port\)/, 'President derives the peer port through the ports seam');
like($president, qr/\$ENV\{PORT_PEER\} = \$peer_port/, 'and exports it for the advertisement');
like($president, qr/peer-fullchain\.pem.*peer-privkey\.pem/s, 'the peer listener uses the house-CA leaf');
like($president, qr/jobs::job_cloud_sync_sweep/, 'the tree starts the CloudSync sweeper beside the Minion worker');
like($president, qr/push \@ws_listeners, 'https:\/\/\*:' \. \$peer_port/, 'the socket server carries the peer listener');

my $network = read_file("$root/lib/JawnOS/Domain/Network.pm");
like($network, qr/'peer=' \. \$ENV\{PORT_PEER\}/, 'mDNS advertises the peer port');

my $music = read_file("$root/perl/Music/02_remote_audio_stream.pl");
like($music, qr/peer_secure_url\(\$rm, \$uri\)/, 'the audio stream asks for the peer listener');
my $video = read_file("$root/perl/Music/03_remote_video.pl");
like($video, qr/peer_secure_url\(\$rm, \$uri\)/, 'and so does the video stream');

# --- peer_useragent uses the house CA when the peer listener is chosen -------
# The verified path used to leave the agent on the system store, which does not
# know the house CA: every call failed TLS with "no answer" while the listener
# was answering (the phone's levels card read the Dev machine as hours stale).
{
	no warnings 'redefine';
	my $rm = {
		cookie => '[]', manager => 'https://192.168.1.10:45545',
		tunnel => 'no', ip => '192.168.1.10',
	};
	my $tls = 0;
	local *subs::peer_live_manager = sub { return $_[0]->{'manager'} };
	local *subs::remote_machine_tunnel_processor = sub { return $_[0] };
	local *subs::peer_tls_verify = sub { $tls++; return 1 };
	local *subs::peer_secure_url = sub { return ('https://192.168.1.10:45551', 1) };
	my ($ua, $p) = subs::peer_useragent({ %{$rm} });
	ok($ua, 'a verified peer gets a user agent');
	is($tls, 1, 'and it is pointed at the house CA');
	is($p->{'manager'}, 'https://192.168.1.10:45551', 'through the peer listener');

	$tls = 0;
	local *subs::peer_secure_url = sub { return ('https://192.168.1.10:45545', 0) };
	my ($plain) = subs::peer_useragent({ %{$rm} });
	ok($plain, 'an unverified peer still gets a user agent');
	is($tls, 0, 'without the house CA, because it is not the peer listener');
}

done_testing();
