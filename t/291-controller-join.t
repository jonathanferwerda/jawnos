# tests-for: lib/JawnOS/Controller/manager_device.pm lib/JawnOS/Routes/manager_device.pm lib/JawnOS/Controller/manager_controllers.pm lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/Loader.pm scripts/gou_first_boot.pl scripts/gou_provision.pl public/js/manager/controllers.js templates/controllers/body.html.ep
# covers:    The join token New writes into a board's image: minted by the press,
#            redeemed once by the board's first boot, and the card rules that boot
#            applies before it syncs.

use strict;
use warnings;
use utf8;
no warnings 'once';	# $Manager::log is set once, for the app's logger

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use JSON::PP ();
use Mojo::Log;
use Mojo::URL;

my $JSON = JSON::PP->new->canonical(1);

sub slurp {
	my ($file) = @_;
	return read_file(root() . '/' . $file);
}

# --------------------------------------------------------------- the house side

# The address a joining machine is told to call: the one the person's browser is
# using, since that is an address on the house's own network.
is(subs::house_manager_address('https://192.168.2.10:45545'), 'https://192.168.2.10:45545/manager',
	'the browser address is the one the board is told to call');
is(subs::house_manager_address('https://192.168.2.10:45545/'), 'https://192.168.2.10:45545/manager',
	'a trailing slash is dropped');
is(subs::house_manager_address('https://192.168.2.10:45545/manager'), 'https://192.168.2.10:45545/manager',
	'a manager path is not doubled');
like(subs::house_manager_address('https://127.0.0.1:45545'), qr{/manager$},
	'a loopback address still answers with a manager route');

# The manager side: minting a token, and the flighty bits around it.
my $controllers = slurp('lib/JawnOS/Controller/manager_controllers.pm');
like($controllers, qr/sub _controller_join_token/, 'the flash mints a join token');
like($controllers, qr/context => 'controller_join'/, 'the secret waits in the local cache');
like($controllers, qr/'--join-token'/, 'the provisioner is given the token file');
like($controllers, qr/_controller_join_forget\(\$token->\{'secret'\}\)/, 'a flash that wrote nothing spends the token');

my $provision = slurp('scripts/gou_provision.pl');
like($provision, qr/sub _first_boot_unit/, 'the provisioner writes the first-boot unit');
like($provision, qr{mkdir.*multi-user\.target\.wants|multi-user\.target\.wants}s, 'and enables it by symlink');
like($provision, qr#ExecStart=/usr/bin/perl /home/jawn/jawnos/scripts/gou_first_boot.pl#, 'the unit runs the board script');
# The image is a copy of another card, identity included; a flashed board takes
# its own before it introduces itself.
like($provision, qr/\.jawnos_signatorial_id/, 'the provisioner clears the copied machine identity');
# The image is a copy of another card, so its tree may not carry the script the
# unit calls; the provisioner copies this tree's own alongside the unit.
like($provision, qr{could not copy the first-boot script}, 'the first-boot script is copied into the image, not assumed there');
like($provision, qr{/gou_first_boot\.pl}, 'from this tree\'s own scripts directory');
my $first_boot = slurp('scripts/gou_first_boot.pl');
like($first_boot, qr/sub _identity_ensure/, 'the first boot mints an identity when none is there');
like($first_boot, qr/_identity_ensure\(\) unless \$token->\{'absent'\};.*?my \$card = undef/s,
	'a flashed board is itself before anything is written under its name');

my $routes = slurp('lib/JawnOS/Routes/manager_device.pm');
like($routes, qr#\[38590, 'post', '/manager/device/join', 'action_38590'\]#, 'the join route is registered');

# ---------------------------------------------------------------- the join action

require 'JawnOS/Manager/Part30.pm';
require 'JawnOS/Controller/manager_device.pm';
require 'JawnOS/Controller/manager_controllers.pm';
# The app hands the package its logger; a probe run has nothing to write, so the
# level keeps the test's output to its own assertions.
$Manager::log = Mojo::Log->new(level => 'fatal');

{
	package JoinProbeTx;
	sub new { bless { remote_address => $_[1] }, $_[0] }
	sub remote_address { $_[0]->{'remote_address'} }
	package JoinProbeReq;
	sub new { bless { url => $_[1] }, $_[0] }
	sub url { $_[0]->{'url'} }
	package JoinProbe;
	sub new {
		my ($class, %p) = @_;
		return bless {
			params => $p{'params'} || {},
			answer => undef,
			session => $p{'session'} || {},
			tx => JoinProbeTx->new($p{'remote_address'} || '192.0.2.50'),
			req => JoinProbeReq->new(Mojo::URL->new('https://192.0.2.10:45545/manager/device/join')),
		}, $class;
	}
	sub param { my ($s, $k) = @_; return $s->{'params'}->{$k} }
	sub render { my ($s, %o) = @_; $s->{'answer'} = $o{'json'}; return $s }
	sub session { my ($s, $k) = @_; return $s->{'session'}->{$k} }
	sub tx { return $_[0]->{'tx'} }
	sub req { return $_[0]->{'req'} }
	package main;
}

my $PUB = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAtestkeyonly000000000000000000000000000000000\n-----END PUBLIC KEY-----\n";
my $SIG = 'abcdef0123456789abcdef0123456789';
my $secret = 'testjoinsecret0000000000000000000001';

sub pending_token {
	my ($code) = @_;
	my $now = subs::rightNow();
	subs::db_insert('cache', {
		uuid => subs::random_string_creator(18),
		context => 'controller_join',
		subcontext => $code,
		app => '__president',
		data => $JSON->encode({ name => 'gou', hostname => 'gou' }),
		timestamp => $now,
		server_time => $now,
	});
}

sub clean_join {
	my ($code, $sig) = @_;
	subs::db_query('delete from cache where context = ? and subcontext = ?', 'controller_join', $code);
	subs::db_query('delete from remote_machines where signatorial = ?', $sig);
}

clean_join($secret, $SIG);
&pending_token($secret);

my $probe = JoinProbe->new(params => {
	secret => $secret,
	pubkey => $PUB,
	signatorial => $SIG,
	name => 'gou',
	device => 'controller',
	address => '192.0.2.60:45545',
});
Manager::action_38590($probe);
my $answer = $probe->{'answer'};
ok($answer && $answer->{'ok'}, 'a token from the press is redeemed');
is($answer->{'house'}->{'manager'}, 'https://192.0.2.10:45545/manager', 'the house hands back the address it is reached on');
ok(length($answer->{'uuid'} || ''), 'the board is filed under a uuid');

my $row = subs::db_select('remote_machines', undef, { signatorial => $SIG })->hash || {};
is($row->{'pubkey'}, $PUB, 'the row pins the key the board offered');
is($row->{'hostname'}, 'gou', 'and the name the house chose');
is($row->{'grant_scope'}, 'trusted', 'a citizen press grants the scope a citizen machine carries');
is($row->{'privilege'}, 'citizen', 'and the privilege');

my $spent = subs::db_select('cache', undef, { context => 'controller_join', subcontext => $secret })->hash;
ok(!$spent, 'the token is spent by the redemption');

# A second redemption of the same token is a stranger with a used code.
my $again = JoinProbe->new(params => { secret => $secret, pubkey => $PUB, signatorial => $SIG, name => 'gou' });
Manager::action_38590($again);
ok(!$again->{'answer'}->{'ok'}, 'the same token cannot be redeemed twice');

my $short = JoinProbe->new(params => { secret => 'x', pubkey => $PUB });
Manager::action_38590($short);
is($short->{'answer'}->{'error'}, 'no token', 'a malformed secret is refused before any read');

my $keyless = JoinProbe->new(params => { secret => 'testjoinsecret0000000000000000000002', pubkey => '' });
Manager::action_38590($keyless);
is($keyless->{'answer'}->{'error'}, 'no key', 'a token without a key is refused');

# A refused request must not use up the board's one chance at the token.
pending_token('testjoinsecret0000000000000000000003');
my $nameless = JoinProbe->new(params => { secret => 'testjoinsecret0000000000000000000003', pubkey => $PUB, name => 'gou' });
Manager::action_38590($nameless);
is($nameless->{'answer'}->{'error'}, 'no name for the machine', 'a machine with no signatorial is refused');
my $still_there = subs::db_select('cache', undef, { context => 'controller_join', subcontext => 'testjoinsecret0000000000000000000003' })->hash;
ok($still_there, 'and its token is still waiting');
clean_join('testjoinsecret0000000000000000000003', '');

clean_join($secret, $SIG);

# The join also files the roster row the Controllers page draws.
my $joined_roster = subs::db_select('paired_devices', undef, { pubkey => $PUB })->hash || {};
is($joined_roster->{'name'}, 'gou', 'a joined board is on the controller roster');
subs::db_query('delete from paired_devices where uuid = ?', $joined_roster->{'uuid'});

# ------------------------------------------------------------- the card choice

# The board reports its card as a per-machine settings row; the page's answer is
# the same kind of row, and the board applies it on its next boot.
my $CARD_UUID = 'cardprobeuuid000000000001';
my $CARD_SIG = 'fedcba9876543210fedcba9876543210';

sub clean_card {
	subs::db_query('delete from paired_devices where uuid = ?', $CARD_UUID);
	subs::db_query('delete from remote_machines where uuid = ?', $CARD_UUID);
	subs::db_query('delete from settings where device = ? and app = ?', $CARD_SIG, '__president');
}

sub seed_card {
	my ($state) = @_;
	&clean_card();
	subs::db_insert('paired_devices', {
		uuid => $CARD_UUID, name => 'gou', kind => 'controller', status => 'active',
		pubkey => "-----BEGIN PUBLIC KEY-----\ncardprobe\n-----END PUBLIC KEY-----\n", privilege => 'citizen',
		timestamp => subs::rightNow(), server_time => subs::rightNow(),
	});
	# The machine row is the one that carries the signatorial; the roster row is
	# filed under the same uuid, which is how the page finds it.
	subs::db_insert('remote_machines', {
		uuid => $CARD_UUID, signatorial => $CARD_SIG, hostname => 'gou',
		ip => '192.0.2.61', status => 'connected', connection => 'active',
		timestamp => subs::rightNow(), server_time => subs::rightNow(),
	});
	subs::db_insert('settings', {
		uuid => subs::random_string_creator(25), app => '__president',
		setting => 'card_finding', device => $CARD_SIG,
		value => $JSON->encode({ state => $state, fstype => 'exfat', size => 63864569856, label => 'CARD' }),
		timestamp => subs::rightNow(), server_time => subs::rightNow(),
	});
}

sub choose_card {
	my ($choice, $session) = @_;
	my $probe = JoinProbe->new(
		session => ($session || { authentication => 'approved', privilege => 'citizen' }),
		params => { uuid => $CARD_UUID, choice => $choice },
	);
	Manager::action_54011($probe);
	return $probe->{'answer'};
}

&seed_card('foreign');
my $adopted = &choose_card('adopt');
ok($adopted->{'ok'}, 'a card with another filesystem can be adopted');
my $choice_row = subs::db_select('settings', undef, { app => '__president', setting => 'card_choice', device => $CARD_SIG })->hash || {};
is($choice_row->{'value'}, 'adopt', 'the answer is kept where the board reads it');

&seed_card('blank');
ok((&choose_card('format'))->{'ok'}, 'a card with no filesystem can be formatted');

&seed_card('blank');
is((&choose_card('adopt'))->{'error'}, 'a card with no filesystem can only be formatted',
	'a blank card cannot be adopted');

&seed_card('archive');
is((&choose_card('format'))->{'error'}, 'that card already holds the archive',
	'the card holding the archive is never formatted from here');

&seed_card('foreign');
is((&choose_card('nonsense'))->{'error'}, 'choose adopt or format', 'only the two answers are accepted');
is((&choose_card('adopt', { authentication => 'guest', privilege => 'guest' }))->{'error'}, 'not allowed',
	'a session below the house cannot answer for a card');
&clean_card();

# The board side of the same conversation: the plan honours the answer.
my $boot_js = slurp('scripts/gou_first_boot.pl');
like($boot_js, qr/sub _card_choice_read/, 'the board reads the answer');
like($boot_js, qr/sub _card_report/, 'and reports what the slot held');
like($boot_js, qr/_card_setting_write\('card_finding'/, 'the finding is a per-machine setting');
like($boot_js, qr/sub _card_setting_clear/, 'the answer is spent once applied');

# --------------------------------------------------------------- the board side

my $dry = tempdir(CLEANUP => 1);

sub run_first_boot {
	my ($lsblk, @args) = @_;
	my $tree = sprintf("{\"blockdevices\":[%s]}", $lsblk);
	my $file = "$dry/lsblk.json";
	open(my $fh, '>', $file) or die "$file: $!";
	print {$fh} $tree;
	close $fh;
	local $ENV{'JAWNOS_GOU_LSBLK_FILE'} = $file;
	local $ENV{'JAWNOS_GOU_ROOT_DISK'} = 'mmcblk1';
	my @command = ($^X, root() . '/scripts/gou_first_boot.pl', '--dry-run', '--token', '/nonexistent', '--no-join', @args);
	my $pid = open(my $out, '-|', @command);
	my $said = do { local $/; <$out> };
	close $out;
	waitpid($pid, 0);
	return $JSON->decode($said || '{}');
}

# The card answer chosen before the flash travels in the house token, because the
# card sits in the board and this computer cannot see it. A dry run reports the
# plan that answer produces.
sub run_first_boot_with_token {
	my ($lsblk, $card) = @_;
	my $token = "$dry/token.json";
	open(my $fh, '>', $token) or die "$token: $!";
	print {$fh} $JSON->encode({
		kind => 'jawnos-controller-join', v => 1,
		secret => 'testtoken000000000000000000000001',
		name => 'gou', hostname => 'gou', card => $card,
		house => { manager => 'https://192.0.2.10:45545/manager', signatorial => 'aa', pubkey => 'bb', name => 'house' },
		expires => time() * 1000 + 3600000,
	});
	close $fh;
	my $said = &run_first_boot($lsblk, '--token', $token);
	return $said;
}

my $emmc = '{"name":"mmcblk1","type":"disk","size":15634268160,"rm":false,"fstype":null,"children":[{"name":"mmcblk1p2","type":"part","size":15459762176,"fstype":"ext4","mountpoint":"/"}]}';
my $sd_ext4 = '{"name":"mmcblk0","type":"disk","size":63864569856,"rm":true,"fstype":null,"children":[{"name":"mmcblk0p1","type":"part","size":63864553472,"fstype":"ext4","mountpoint":null}]}';
my $sd_exfat = '{"name":"mmcblk0","type":"disk","size":63864569856,"rm":true,"fstype":null,"children":[{"name":"mmcblk0p1","type":"part","size":63864553472,"fstype":"exfat","mountpoint":"/media/jawn/CARD"}]}';
my $sd_blank = '{"name":"mmcblk0","type":"disk","size":63864569856,"rm":true,"fstype":null,"children":[{"name":"mmcblk0p1","type":"part","size":63864553472,"fstype":null,"mountpoint":null}]}';

{
	my $said = &run_first_boot($emmc . ',' . $sd_ext4);
	is($said->{'card'}->{'state'}, 'archive', 'an ext4 card is adopted as it stands');
	is($said->{'card'}->{'action'}, 'adopt', 'with no formatting');
	is($said->{'card'}->{'dev'}, '/dev/mmcblk0p1', 'and the card is the removable disk, not the eMMC');
}
{
	my $said = &run_first_boot($emmc . ',' . $sd_exfat);
	is($said->{'card'}->{'state'}, 'foreign', 'another filesystem is somebody else data');
	is($said->{'card'}->{'action'}, 'leave', 'so it is left alone without --format');
}
{
	my $said = &run_first_boot($emmc . ',' . $sd_exfat, '--format');
	is($said->{'card'}->{'action'}, 'format', '--format says the person meant it');
}
{
	my $said = &run_first_boot($emmc . ',' . $sd_blank);
	is($said->{'card'}->{'state'}, 'blank', 'a card with no filesystem is blank');
	is($said->{'card'}->{'action'}, 'leave', 'and is not formatted unasked');
}
{
	my $said = &run_first_boot($emmc . ',' . $sd_blank, '--format');
	is($said->{'card'}->{'action'}, 'format', 'a blank card is formatted when asked');
}
{
	my $said = &run_first_boot($emmc);
	is($said->{'card'}->{'state'}, 'none', 'no card in the slot is reported, not invented');
	is($said->{'token'}, 'none', 'and no token means the boot is a no-op');
}

# The card answer chosen before the flash, carried in the token.
{
	my $said = &run_first_boot_with_token($emmc . ',' . $sd_exfat, 'format');
	is($said->{'card'}->{'choice'}, 'format', 'the token\'s answer is the first boot\'s choice');
	is($said->{'card'}->{'action'}, 'format', 'so a foreign card is formatted on that first start');
}
{
	my $said = &run_first_boot_with_token($emmc . ',' . $sd_exfat, 'adopt');
	is($said->{'card'}->{'action'}, 'adopt', 'and keep-what-is-on-it adopts it instead');
}
{
	my $said = &run_first_boot_with_token($emmc . ',' . $sd_ext4, 'format');
	is($said->{'card'}->{'action'}, 'adopt', 'the card holding the archive is still never formatted');
}

# A blank card is not adopted even when the token says so: there is nothing to
# mount, and the desk's rule is that only a format makes one usable.
{
	my $said = &run_first_boot_with_token($emmc . ',' . $sd_blank, 'adopt');
	is($said->{'card'}->{'action'}, 'leave', 'a blank card is not adopted by the token answer');
}

# A board with no config.json (the image drops it; the config is machine
# identity) has to seed one before the tree loads, or the first boot dies at the
# require. The seed is the server's own setup script, run as the tree owner.
sub run_first_boot_seeded {
	my $store = tempdir(CLEANUP => 1);
	my $home  = tempdir(CLEANUP => 1);
	local $ENV{'JAWNOS_STORE_DIR'} = $store;
	local $ENV{'HOME'} = $home;
	my $err = "$home/seed.err";
	open(my $save, '>&', \*STDERR) or die "cannot duplicate stderr: $!";
	open(STDERR, '>', $err) or die "cannot redirect stderr: $!";
	my $pid = open(my $out, '-|', $^X, root() . '/scripts/gou_first_boot.pl',
		'--dry-run', '--no-card', '--no-join');
	my $said = do { local $/; <$out> };
	close $out;
	waitpid($pid, 0);
	open(STDERR, '>&', $save) or die "cannot restore stderr: $!";
	return ($JSON->decode($said || '{}'), $store);
}

{
	my ($said, $store) = &run_first_boot_seeded();
	is($said->{'ok'}, 1, 'a first boot with no config seeds one and continues');
	is($said->{'token'}, 'none', 'and the seed does not invent a join token');
	my $raw = -f "$store/config.json" ? read_file("$store/config.json") : '';
	my $config = length $raw ? $JSON->decode($raw) : {};
	is($config->{'device'}, 'controller', 'the board is a controller, not a computer');
	is($config->{'domain'}, '127.0.0.1', 'its own local house, not the copied card');
	ok(length($config->{'name'}), 'it carries the board name');
	ok(length($config->{'signatorial'}), 'the config is usable, so the server does not seed again');
	ok(-f "$store/database/jawnos.db", 'the seed built the board database');
}

# The join used to dial the browser's manager port and verify it against the
# house CA; that port presents the public wildcard, so the verified request
# always failed. It is routed through peer_secure_url (the port + 6 listener,
# whose leaf the CA proves), with the signed unverified rail as the fallback.
like($boot_js, qr/peer_secure_url\(\$rm, \$url\)/, 'the join is routed to the listener that proves the house CA');
like($boot_js, qr/my \$trusted = \(\$verified && &subs::peer_tls_verify\(\$ua\)\) \? 1 : 0;/,
	'and records that only when the listener proves the address');
like($boot_js, qr/if \(\$trusted\) \{ \$url = \$endpoint; \}/,
	'that verified route is the one dialled');
like($boot_js, qr/\$ua->insecure\(1\);/, 'otherwise the signed request rides the unverified rail');
like($boot_js, qr/device => 'controller',/, 'the board files itself as a controller');
like($boot_js, qr/sub _self_address.*?device_hostname_better/s,
	'the board names itself by hostname, not by a stale configured domain');

# The image is a copy of another card; the flash is the last pass that makes the
# board itself, so an image built before the builder's exclusion list still
# cannot bring the source card's identity, house or saved network with it.
like($provision, qr/sub _scrub_copied_machine/, 'the flash scrubs the copied card');
like($provision, qr{database/jawnos\.db}, 'removing the copied database');
like($provision, qr{config\.json}, 'and the copied configuration');
like($provision, qr{/etc/machine-id}, 'and the copied machine id');
like($provision, qr{usb-gadget}, 'keeping the USB gadget profile');
like($provision, qr/After=network-online\.target gou-wifi-reset\.service/,
	'the first boot waits for the Wi-Fi guard');
like($provision, qr{\.shots/ticket\.txt}, 'the copied kiosk ticket is cleared');
like($boot_js, qr/sub _kiosk_ticket/, 'the first boot mints this board a kiosk ticket');
like($boot_js, qr/'desktop', '--save'/, 'with the desktop view ticket the launcher reads');

# Root creates the card's folders and opens the database; the service runs as
# the tree's account, so both are handed over before the service starts.
like($boot_js, qr/uid=.*gid=.*umask=0077/, 'a foreign card is mounted for the service account');
like($boot_js, qr/archive_location_folder\(\$where, \$location\)/,
	'the folders it makes are given to the service account');
like($boot_js, qr/sub _own_database/, 'and the database is handed to the service account');

# The manager page asks for the name that goes on the board.
my $body = slurp('templates/controllers/body.html.ep');
like($body, qr/id="controllers_hostname"[^>]*value="gou"/, 'the New section carries the board name');
like($body, qr/for="controllers_hostname"/, 'with a label of its own');
my $js = slurp('public/js/manager/controllers.js');
like($js, qr/function controllerNewHostname/, 'the page reads the name itself');
like($js, qr/hostname: name,/, 'and sends it with the flash');
like($js, qr/#controllers_hostname, #controllers_card_choice/, 'the fields are held still while it runs');

# A joining board is named under the house domain and, when the CA is on this
# machine, given its own leaf for that name. The map is the synced one
# Configure -> Plat -> DNS shows, so the name appears there and the board reads
# its own entry back through public_host.
{
	my $openssl = `command -v openssl 2>/dev/null`;
	chomp $openssl;
	SKIP: {
	skip 'openssl is not installed', 15 unless $openssl && length $openssl && -x $openssl;
	local $ENV{'JAWNOS_STORE_DIR'} = sandbox();
	my $ca_log = "$dry/house-ca.log";
	open(my $save, '>&', \*STDOUT) or die "cannot duplicate stdout: $!";
	open(STDOUT, '>', $ca_log) or die "cannot redirect stdout: $!";
	my $ca = system($^X, root() . '/scripts/house_ca.pl', 'init');
	open(STDOUT, '>&', $save) or die "cannot restore stdout: $!";
	is($ca, 0, 'a test house CA is created');

	subs::setting_setter({ app => '__president', setting => 'house_domain', device => 'all', value => 'example.test' });
	subs::db_delete('settings', { app => '__president', setting => 'device_hosts' });
	my $secret2 = 'testjoinsecret0000000000000000000004';
	my $sig2 = '0011223344556677889900aabbccddee';
	pending_token($secret2);
	my $probe2 = JoinProbe->new(params => {
		secret => $secret2, pubkey => $PUB, signatorial => $sig2,
		name => 'gou2026', device => 'controller', address => 'gou2026:45545',
		tls_verified => 1,
	});
	Manager::action_38590($probe2);
	my $answer2 = $probe2->{'answer'} || {};
	ok($answer2->{'ok'}, 'a board with a house domain joins named');
	is($answer2->{'public_host'}, 'gou2026.example.test', 'its name is under the house domain');
	my $map = subs::device_hosts();
	is($map->{lc $sig2}, 'gou2026.example.test', 'the synced name map carries it');
	my $row2 = subs::db_select('remote_machines', undef, { signatorial => $sig2 })->hash || {};
	is($row2->{'fqdn'}, 'gou2026.example.test', 'the roster row is named');
	is($row2->{'manager'}, 'https://gou2026.example.test:45545/manager', 'and is reached by that name');
	ok($answer2->{'tls'}->{'ok'}, 'the house CA issued the board a leaf');
	is($answer2->{'tls'}->{'host'}, 'gou2026.example.test', 'for the public name');
	like($answer2->{'tls'}->{'cert'}, qr/-----BEGIN CERTIFICATE-----/, 'the certificate travels to the board');
	like($answer2->{'tls'}->{'key'}, qr/PRIVATE KEY-----/, 'with the key it needs');
	# The board already trusts server/house-ca.pem; the leaf must chain to it.
	my $leaf_file = "$dry/gou2026-leaf.pem";
	open(my $leaf_fh, '>', $leaf_file) or die "cannot write $leaf_file: $!";
	print {$leaf_fh} $answer2->{'tls'}->{'cert'} // '';
	close $leaf_fh;
	my $verify = `$openssl verify -CAfile '$ENV{'JAWNOS_STORE_DIR'}/server/house-ca.pem' '$leaf_file' 2>&1`;
	like($verify, qr/: OK/, 'and it chains to the CA the board already trusts');
	# A key is returned only to a board that proved the house's leaf: the signed
	# fallback rail is not confidential, so an unverified join gets the name and
	# no private key.
	my $secret3 = 'testjoinsecret0000000000000000000005';
	my $sig3 = 'ffeeddccbbaa00998877665544332211';
	pending_token($secret3);
	my $probe3 = JoinProbe->new(params => {
		secret => $secret3, pubkey => $PUB, signatorial => $sig3,
		name => 'gou2026', device => 'controller', address => 'gou2026:45545',
	});
	Manager::action_38590($probe3);
	my $answer3 = $probe3->{'answer'} || {};
	ok($answer3->{'ok'}, 'an unverified board still joins');
	is($answer3->{'public_host'}, 'gou2026.example.test', 'and is still named under the house domain');
	ok(!$answer3->{'tls'}->{'ok'}, 'but no leaf is issued over the unverified rail');
	ok(!defined $answer3->{'tls'}->{'key'}, 'and no private key travels');
	clean_join($secret3, $sig3);
	subs::db_delete('paired_devices', { uuid => $answer3->{'uuid'} }) if $answer3->{'uuid'};
	# The DB here is the test's copy; put the naming settings back as they were.
	clean_join($secret2, $sig2);
	subs::db_delete('paired_devices', { uuid => $answer2->{'uuid'} }) if $answer2->{'uuid'};
	subs::db_delete('settings', { app => '__president', setting => 'house_domain' });
	subs::db_delete('settings', { app => '__president', setting => 'device_hosts' });
	}
}

my $device_source = slurp('lib/JawnOS/Controller/manager_device.pm');
like($device_source, qr/sub _controller_join_certificate/, 'the join issues a leaf for the board');
like($device_source, qr/house_machine_name\(/, 'and derives the name under the house domain');
like($device_source, qr/house-ca\.key/, 'only where the house CA key is');
like($device_source, qr/tls_verified/, 'a leaf is only issued to a verified board');
like($boot_js, qr/tls_verified => \$trusted/, 'and the board says so inside the signed body');
like($boot_js, qr/sub _install_join_certificate/, 'the board installs the leaf');
like($boot_js, qr/fullchain\.pem.*?peer-privkey\.pem/s, 'as both listeners pairs');
like($boot_js, qr/_own_by_tree\(\@written\)/, 'owned by the service account');
like($provision, qr{server/house-ca\.key}, 'the copied CA key is never left on a board');
like(slurp('lib/JawnOS/Domain/Loader.pm'), qr/house_machine_name/, 'the new domain helper is mapped');

# The installer itself, taken from the script and given a leaf the way the join
# hands it over: four files, the two main names and the two peer names, the keys
# 0600, and the service account owning what root wrote.
{
	require File::Path;
	my ($installer) = $boot_js =~ /^(sub _install_join_certificate \{.*?^\})/ms;
	ok(defined $installer, 'the installer is a sub of its own');
	my $code = "package GouLeafTest; our \@owned; sub _own_by_tree { \@owned = \@_ }\n"
		. ($installer // 'sub _install_join_certificate { return "missing" }') . "\n1;\n";
	eval $code;
	is($@, '', 'the installer compiles on its own');
	my $store = tempdir(CLEANUP => 1);
	local $ENV{'JAWNOS_STORE_DIR'} = $store;
	my $status = GouLeafTest::_install_join_certificate({
		ok => 1, host => 'gou2026.example.test',
		cert => "-----BEGIN CERTIFICATE-----\nleaf\n-----END CERTIFICATE-----\n",
		key => "-----BEGIN EC PRIVATE KEY-----\nsecret\n-----END EC PRIVATE KEY-----\n",
	});
	is($status, 'installed', 'the leaf is installed as both pairs');
	foreach my $pair ([qw(fullchain.pem 0644)], [qw(peer-fullchain.pem 0644)],
		[qw(privkey.pem 0600)], [qw(peer-privkey.pem 0600)]) {
		my ($name, $mode) = @$pair;
		my $path = "$store/server/$name";
		ok(-f $path, "$name is written");
		is(sprintf('%04o', (stat($path))[2] & 07777), $mode, "$name is mode $mode");
	}
	like(read_file("$store/server/fullchain.pem"), qr/BEGIN CERTIFICATE/, 'the certificate is the leaf');
	like(read_file("$store/server/privkey.pem"), qr/BEGIN EC PRIVATE KEY/, 'the key is the leaf\'s own');
	is(scalar @GouLeafTest::owned, 4, 'all four files are handed to the service account');
	is(GouLeafTest::_install_join_certificate({ ok => 0, error => 'no CA' }), 'none',
		'a join without a leaf writes nothing');
	is(GouLeafTest::_install_join_certificate({ ok => 1, cert => 'nope', key => 'nope' }), 'invalid',
		'a malformed leaf is refused');
}

done_testing();
