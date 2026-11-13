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
like($first_boot, qr/\$report->\{'identity'\} = &_identity_ensure\(\);\s*\n\s*my \$joined = &_join\(\$token\)/, 'and only then introduces itself');

my $routes = slurp('lib/JawnOS/Routes/manager_device.pm');
like($routes, qr#\[38590, 'post', '/manager/device/join', 'action_38590'\]#, 'the join route is registered');

# ---------------------------------------------------------------- the join action

require 'JawnOS/Manager/Part30.pm';
require 'JawnOS/Controller/manager_device.pm';
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
			tx => JoinProbeTx->new($p{'remote_address'} || '192.0.2.50'),
			req => JoinProbeReq->new(Mojo::URL->new('https://192.0.2.10:45545/manager/device/join')),
		}, $class;
	}
	sub param { my ($s, $k) = @_; return $s->{'params'}->{$k} }
	sub render { my ($s, %o) = @_; $s->{'answer'} = $o{'json'}; return $s }
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

# The manager page asks for the name that goes on the board.
my $body = slurp('templates/controllers/body.html.ep');
like($body, qr/id="controllers_hostname"[^>]*value="gou"/, 'the New section carries the board name');
like($body, qr/for="controllers_hostname"/, 'with a label of its own');
my $js = slurp('public/js/manager/controllers.js');
like($js, qr/function controllerNewHostname/, 'the page reads the name itself');
like($js, qr/hostname: name,/, 'and sends it with the flash');
like($js, qr/#controllers_hostname, #controllers_wifi_ssid, #controllers_wifi_psk/, 'the fields are held still while it runs');

done_testing();
