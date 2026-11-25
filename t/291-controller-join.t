# tests-for: lib/JawnOS/Controller/manager_device.pm lib/JawnOS/Routes/manager_device.pm lib/JawnOS/Controller/manager_controllers.pm lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/Loader.pm scripts/gou_first_boot.pl scripts/gou_provision.pl scripts/gou_wifi_reset.sh public/js/manager/controllers.js templates/controllers/body.html.ep
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
like($provision, qr{could not copy \$name}, 'the board scripts are copied into the image, not assumed there');
like($provision, qr/for my \$name \(qw\(gou_first_boot\.pl gou_recovery\.pl gou_splash\.pl gou_first_run\.py jawnos_game_openssl\.pl\)\)/, 'the board scripts the flash needs, including the splash, the first-run dialog and the OpenSSL helper');
like($provision, qr{/gou_first_boot\.pl}, 'from this tree\'s own scripts directory');
like($provision, qr{/gou_splash\.pl}, 'and the splash script travels with the flash');
# A copied desktop ticket outranks the fresh one the first boot writes, so the
# source machine's ticket store has to go before the board introduces itself.
like($provision, qr{\$home/\.config/jawnos}, 'the copier removes the source desktop ticket store');
like($provision, qr{\$home/\.local/share/jawnos/\.shots/ticket\.txt}, 'and the installed shell\'s copy');
like($provision, qr/'recovery-image=s'/, 'the flash takes a recovery image');
like($provision, qr/sdcard_recovery\.img/, 'and copies it onto the flashed rootfs');
like($provision, qr/push \@done, 'recovery'/, 'reporting it as filled in on the board');
my $first_boot = slurp('scripts/gou_first_boot.pl');
like($first_boot, qr/sub _identity_ensure/, 'the first boot mints an identity when none is there');
like($first_boot, qr/_identity_ensure\(\) unless \$token->\{'absent'\};.*?my \$card = undef/s,
	'a flashed board is itself before anything is written under its name');
like($first_boot, qr{sub _ticket_share}, 'the board shares its fresh ticket with the installed shell');
like($first_boot, qr{\.local/share/jawnos}, 'at the installed shell\'s root, not only the tree');
like($first_boot, qr{\$root/\.shots}, 'in the .shots directory that root reads');

# The image carries no `hostname` binary (no inetutils). The address the board
# gives the house came out empty, so the join named the wrong machine.
unlike($first_boot, qr/\(\s*`hostname`/, 'the board name is not read by running a binary the image may not carry');
like($first_boot, qr/sub _hostname \{.*?\/etc\/hostname/s, 'it reads the name systemd reads');
like($first_boot, qr/device_hostname_better\(&_hostname\(\)/, 'and the join address is built from it');
# The reader hands back { path, token => {...}, house => {...} }. The join read
# secret and name off the wrapper, which holds neither, so every token reached
# the house as an empty secret and was refused as "no token": no board had ever
# joined from its token, the flashed ones included (2026-11-18).
like($first_boot, qr/my \$payload = ref \$token->\{'token'\} eq 'HASH' \? \$token->\{'token'\} : \{\};/,
	'the join reads the token payload, not the wrapper');
like($first_boot, qr/secret => \$payload->\{'secret'\}/, 'and sends the payload' . "'" . 's secret');
like($first_boot, qr/name => \$payload->\{'hostname'\} \|\| \$payload->\{'name'\}/, 'and the payload' . "'" . 's name');
unlike($first_boot, qr/secret => \$token->\{'secret'\}/, 'never the wrapper, which holds no secret');
# The pass runs as root with HOME on the board's own account while the manager
# runs as that account, so a root-owned log or run/ leaves the manager printing
# one server line and dying with EACCES behind a dead panel.
like($first_boot, qr/sub _hand_back_runtime \{/, 'the pass hands the runtime state back to the tree owner');
like($first_boot, qr/END \{ eval \{ .*?_hand_back_runtime\(\)/s, 'on every exit path, a failed join included');
like($first_boot, qr/^\t\tunlink \$log;$/m, 'an empty root-owned log is dropped rather than left for the manager');
like($first_boot, qr/!\$opt\{'dry_run'\}/, 'and a dry run writes nothing');

# The seed mints the unlock code, prints it once and keeps it nowhere. Without
# the file beside the house there is no candidate key, the vault is never
# seeded, and the box office refuses the kiosk's own ticket - the Gate.
like($first_boot, qr/JAWNOS_UNLOCK_CODE=\(\[0-9\]\{4,12\}\)/, 'the unlock code the seed prints is parsed');
like($first_boot, qr/\$home\/UNLOCK-CODE\.txt/, 'and written beside the house, where local_code_suds reads it');
like($provision, qr/\$home\/UNLOCK-CODE\.txt/, 'the flash scrubs the source card\'s code with its identity');
like($first_boot, qr/sub _adopt_house_key/, 'the first boot adopts the house key after the join');
like($first_boot, qr/vault_pull_one\(\$known, \$seal\)/, 'the key is pulled from the house row it joined');
like($first_boot, qr/rotate_house_key\(\$key\)/, 'and adopted with the rotation the house already uses');
like($first_boot, qr/controller-key-pending/, 'a key that did not arrive is retried on the next boot');
like($first_boot, qr/_key_done_write/, 'a completed adoption is marked');
like($first_boot, qr/!&_key_done_present\(\)/, 'so a healthy board is not asked again');
like($first_boot, qr/controller-key\.done/, 'the marker is named for the key');
like($first_boot, qr/sub _house_peers/, 'a board that joined before this pass finds its house on file');
like($first_boot, qr/my \$house = ref \$joined->\{'house'\} eq 'HASH' \? \$joined->\{'house'\} : \{\};/, 'the join keeps its house hash');
like($first_boot, qr/_adopt_house_key\(\$house\)/, 'and hands it to the adoption');

# The board files the house as an origin, not as the manager route: the sync
# rail appends /manager, and vault_pull_one appends /manager/vault_share.
my ($house_row_sub) = $first_boot =~ /^(sub _house_row \{.*?^\})/ms;
ok(length($house_row_sub // ''), 'the house-row sub is readable');
if (length $house_row_sub) {
	my $pkg = 'HouseRowProbe';
	eval "package $pkg;\n$house_row_sub\n1;\n" or die $@;
	my $house_sig = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
	subs::db_query('delete from remote_machines where signatorial = ?', $house_sig);
	my $filed = $pkg->can('_house_row')->({
		manager => 'https://192.0.2.10:45545/manager',
		signatorial => $house_sig, pubkey => 'k', name => 'house',
	});
	ok($filed->{'ok'}, 'the house row is filed');
	my $filed_row = subs::db_select('remote_machines', undef, { signatorial => $house_sig })->hash || {};
	is($filed_row->{'manager'}, 'https://192.0.2.10:45545', 'the row stores the origin, not the /manager route');
	subs::db_query('delete from remote_machines where signatorial = ?', $house_sig);
}

# A board that joined before this pass has its house row already; the house
# finder is what lets the next boot adopt the key without a token.
my ($house_peer_sub) = $first_boot =~ /^(sub _house_peers \{.*?^\})/ms;
ok(length($house_peer_sub // ''), 'the house-peers sub is readable');
if (length $house_peer_sub) {
	my $pkg = 'HousePeerProbe';
	eval "package $pkg;\n$house_peer_sub\n1;\n" or die $@;
	my $peer_sig = 'b1c2d3e4f5061728394a5b6c7d8e9f01';
	subs::db_query('delete from remote_machines where signatorial = ?', $peer_sig);
	subs::db_insert('remote_machines', {
		uuid => subs::random_string_creator(15), signatorial => $peer_sig,
		manager => 'https://192.0.2.11:45545', ip => '192.0.2.11', port => '45545',
		device => 'server', connection => 'active', server_time => subs::rightNow(),
	});
	my $peers = $pkg->can('_house_peers')->();
	ok(ref $peers eq 'ARRAY' && grep { $_ eq $peer_sig } @$peers, 'the roster server row is among the house peers');
	subs::db_query('delete from remote_machines where signatorial = ?', $peer_sig);
}

# The adoption decision: pull, then rotate; leave a key this machine already
# holds alone; carry the rail's refusal when nothing arrives.
my ($adopt_sub) = $first_boot =~ /^(sub _adopt_house_key \{.*?^\})/ms;
ok(length($adopt_sub // ''), 'the adoption sub is readable');
if (length $adopt_sub) {
	my $pkg = 'KeyAdoptProbe';
	eval "package $pkg;\n$adopt_sub\n1;\n" or die $@;
	my $adopt_sig = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
	subs::db_query('delete from remote_machines where signatorial = ?', $adopt_sig);
	subs::db_insert('remote_machines', {
		uuid => subs::random_string_creator(15), signatorial => $adopt_sig,
		manager => 'https://192.0.2.10:45545/manager', ip => '192.0.2.10', port => '45545',
		device => 'server', connection => 'active', server_time => subs::rightNow(),
	});
	{
		my ($pulled, $rotated, $current) = ('housekey', undef, 'boardkey');
		no warnings 'redefine';
		local *subs::vault_pull_one = sub { return $pulled };
		local *subs::suds_grabber = sub { return $current };
		local *subs::rotate_house_key = sub { $rotated = $_[0]; return { ok => 1, key_id => 'kid' } };
		my $r = $pkg->can('_adopt_house_key')->({ signatorial => $adopt_sig });
		ok($r->{'ok'}, 'a pulled key is adopted');
		is($rotated, 'housekey', 'the rotation receives the house key');
		is($r->{'key_id'}, 'kid', 'and reports its key id');
		my $normalized = subs::db_select('remote_machines', undef, { signatorial => $adopt_sig })->hash || {};
		is($normalized->{'manager'}, 'https://192.0.2.10:45545', 'an older house row is trimmed to its origin before the pull');
	}
	{
		my ($pulled, $rotated, $current) = ('boardkey', undef, 'boardkey');
		no warnings 'redefine';
		local *subs::vault_pull_one = sub { return $pulled };
		local *subs::suds_grabber = sub { return $current };
		local *subs::rotate_house_key = sub { $rotated = $_[0]; return { ok => 1 } };
		my $r = $pkg->can('_adopt_house_key')->({ signatorial => $adopt_sig });
		ok($r->{'ok'} && $r->{'already'}, 'a key this machine already holds is left alone');
		ok(!defined $rotated, 'and no rotation runs');
	}
	{
		my $pulled = undef;
		$gb::vault_pull_error = 'sharing off';
		no warnings 'redefine';
		local *subs::vault_pull_one = sub { return $pulled };
		my $r = $pkg->can('_adopt_house_key')->({ signatorial => $adopt_sig });
		ok(!$r->{'ok'}, 'a key that does not arrive is an error');
		is($r->{'error'}, 'sharing off', 'and carries the rail error');
		$gb::vault_pull_error = '';
	}
	subs::db_query('delete from remote_machines where signatorial = ?', $adopt_sig);
}

# With no window state the shell falls back to 1100x820, and the launcher's four
# columns then lay out 1.25x wider than this 854x480 glass: three tiles and the
# top of a second row. The scrub takes the source card's copy with its ticket.
like($first_boot, qr/sub _desktop_shell_state/, 'the pass seeds the kiosk window state');
like($first_boot, qr/return 0 if -e \$path;/, 'never over a state the shell recorded itself');
like($first_boot, qr/fullscreen => \\1/, 'fullscreen from the first start');
like($first_boot, qr/_desktop_shell_state\(\) \? 'fullscreen'/, 'and reports what it did');

# The panel guard is a oneshot the timer runs every fifteen seconds, so a pass
# that heals nothing is the common case. The image's guard ended on a window
# search, so it failed on every run and left the unit failed for the board's
# whole life.
my $guard = slurp('scripts/gou_kiosk_guard.sh');
like($provision, qr{/usr/local/sbin/gou-kiosk-guard}, 'the flash installs the panel guard');
like($provision, qr/gou-kiosk-guard\.timer/, 'with its timer');
like($provision, qr/_wants_link\(\$wants, 'gou-kiosk-guard\.timer'\)/, 'enabled, so a board that lost it gets it back');
unlike($guard, qr/exit 1/, 'no path fails the oneshot');
like($guard, qr/^exit 0$/m, 'every path ends in success');
like($guard, qr/--class JawnOS/, 'the window is looked for by class');
like($guard, qr/--name '\^JawnOS\$'/, 'and by the title the shell sets');
my $guard_syntax = system('sh', '-n', root() . '/scripts/gou_kiosk_guard.sh');
is($guard_syntax, 0, 'the guard is valid POSIX shell');

# The Realtek 8821CU combo adapter misses the USB enumeration after a warm
# reboot. The live card learned the reset by hand; the flash has to carry it, and
# a timer has to retry it, or every reimaged board loses the fix.
my $wifi = slurp('scripts/gou_wifi_reset.sh');
like($provision, qr{/usr/local/sbin/gou-wifi-reset}, 'the flash installs the WiFi guard');
like($provision, qr/gou-wifi-reset\.service/, 'with a boot service');
like($provision, qr/gou-wifi-reset\.timer/, 'and a timer that retries it');
like($provision, qr/_wants_link\(\$timer_wants, 'gou-wifi-reset\.timer'\)/, 'enabled, so a board that lost it gets it back');
like($wifi, qr/rtw88_8821cu/, 'the guard reloads the adapter driver');
like($wifi, qr/0bda/, 'and finds the combo adapter by its USB id');
like($wifi, qr/wait_link && exit 0/, 'a board whose wlan0 is up does nothing');
my $wifi_syntax = system('sh', '-n', root() . '/scripts/gou_wifi_reset.sh');
is($wifi_syntax, 0, 'the WiFi guard is valid POSIX shell');

# A fresh card already has the emulators, so nobody presses "Install emulators"
# and the install helper cannot be the only caller of the OpenSSL compat step.
like($provision, qr/sub _openssl_compat_unit/, 'the flash generates the OpenSSL compat unit');
like($provision, qr/gou-openssl-compat\.service/, 'and enables it at boot');
like($provision, qr{ExecStart=/usr/bin/perl /home/jawn/jawnos/scripts/jawnos_game_openssl\.pl},
	'which runs the compat helper');
like($provision, qr/jawnos_game_openssl\.pl/, 'the helper travels with the flash');
like($provision, qr/_wants_link\(\$wants, 'gou-openssl-compat\.service'\)/, 'with a wants link');

# The board's card slot reports itself as fixed (mmcblk0 rm=0), exactly like the
# soldered eMMC, so the removable flag cannot find the archive card. And a card
# that arrives with a stray filesystem on a small partition must be formatted as
# a card, not as that partition, or the archive is 64 MB.
like($first_boot, qr/sub _sd_card/, 'a card is recognised by what the device says it is');
like($first_boot, qr{/sys/block/\$name/device/type}, 'asking sysfs, not the removable flag');
like($first_boot, qr/_truthy\(\$disk->\{'rm'\}\) \|\| &_sd_card\(\$disk->\{'name'\}\)/,
	'an SD-type card is a candidate even when rm=0');
like($first_boot, qr/mkfs\.ext4', '-F', '-L', \$DEFAULT_LABEL, \$target/, 'the format is aimed at the card');
like($first_boot, qr/\$plan->\{'dev'\} = \$target;/, 'and the card, not the partition, is what gets mounted');
like($first_boot, qr/disk => \$card->\{'disk'\}/, 'the plan carries the card, so format can aim at it');

# A board whose SoC halts but whose panel PMIC keeps the rails up sits with its
# red light on. The flag has to land on the rk818 on the always-on bus; the
# rk817 beside it is the charger and must not hold the power-off handler.
like($provision, qr/sub _pmic_poweroff/, 'the flash makes the panel able to power off');
like($provision, qr{/soc/bus\@ff800000/i2c\@5000/pmic\@1c}, 'the always-on bus PMIC gets the flag');
like($provision, qr{/soc/bus\@ffd00000/i2c\@1c000/pmic\@20}, 'and the charger PMIC has it removed');
like($provision, qr/push \@done, 'pmic-poweroff'/, 'reported on the board');
like($provision, qr/pmic: this host has no dtc tools/, 'a step that cannot run says why, not nothing');

# A board arrives with no password anyone knows and a card nobody has answered
# for. The panel asks both questions before the launcher; the root pass applies
# them and never asks twice.
my $first_run = slurp('scripts/gou_first_run.py');
like($first_run, qr/def card_present/, 'the dialog knows when there is a card to erase');
like($first_run, qr{/sys/block/%s/device/type}, 'by the same rule the planner uses');
like($first_run, qr/def is_root_disk/, 'and it never offers the disk the system runs from');
like($first_run, qr{/sys/block/%s/%s}, 'asked of sysfs, not by trimming a device name');
like($first_run, qr/Erase the card in the slot/, 'and offers the wipe as a box that must be ticked');
# The style's own indicator is a hairline on this dark panel: the box was there
# and could not be seen, so the tick was never found. A grey square is visible
# empty and white when it is ticked.
like($first_run, qr/QCheckBox::indicator \{[^}]*background:#8a8a8a/, 'the tick box is drawn as a visible grey square');
like($first_run, qr/QCheckBox::indicator:checked \{[^}]*background:#f4f4f4/, 'and fills to white when it is ticked');
like($first_run, qr/QCheckBox::indicator:unchecked/, 'with an empty state of its own');
like($first_run, qr/def write_answers/, 'the answers are written for the root pass');
like($provision, qr/gou_first_run\.py/, 'the dialog travels with the flash');
like($provision, qr/gou-first-run\.service/, 'with a unit of its own');
like($provision, qr/After=network-online\.target gou-wifi-reset\.service gou-first-run\.service/,
	'and the pass waits for the person to answer');
like($first_boot, qr/sub _first_run_answers/, 'the pass reads the panel\'s answers');
like($first_boot, qr/sub _set_account_password/, 'the code becomes the account\'s password');
like($first_boot, qr/chpasswd/, 'through chpasswd, on stdin');
like($first_boot, qr/print \{\$fh\} "\$user:\$code\\n";/, 'never on argv');
like($first_boot, qr/\$choice = \$answers->\{'wipe'\} \? 'format' : ''/, 'the ticked box wipes and an unticked one refuses');
like($first_boot, qr/if \(!\$opt\{'dry_run'\} && %\{\$answers\}\)/, 'the panel outranks the token, which could not see the card');
like($first_boot, qr/_first_run_done\(\) unless/, 'and the questions are asked once');
like($first_boot, qr/&_first_run_done\(\) unless \$opt\{'dry_run'\} \|\| !\$password_ok;.*?if \(\$token->\{'error'\}\)/s,
	'the questions are marked done before a bad token can stop the pass');

my $py_ok = system('python3', '-m', 'py_compile', root() . '/scripts/gou_first_run.py');
is($py_ok, 0, 'the dialog is valid Python');
like($first_boot, qr/sub _first_run_forget_code/, 'the code leaves the disk once it is a password');
like($first_boot, qr/&_first_run_forget_code\(\) if \$report->\{'password'\} eq 'set'/,
	'straight after chpasswd, not at the end of the pass');
like($first_boot, qr/return unlink\(\$path\) \? 1 : 0;/, 'and a refused code keeps it, so the next boot asks again');
# The image ships no sudo grant for the tree's account, so a password the panel
# asked for is one sudo refuses until the grant is written.
like($first_boot, qr/sub _grant_sudo/, 'the account is allowed to use the code');
like($first_boot, qr{\$user ALL=\(ALL\) ALL}, 'with the one line sudoers needs');
# A token the house cleaned up mid-write was copied as an empty file and reported
# as filled in; the board then stopped before the card step, so a requested wipe
# silently never happened.
like($provision, qr/the join token at \$join is empty or not JSON/, 'an empty token fails the flash');
like($provision, qr/JSON::PP->new->decode\(\$token\)/, 'the token is parsed before it is copied');

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
	package LeafProbe;
	sub new { bless { params => $_[1] || {}, answer => undef, status => undef }, $_[0] }
	sub param { my ($s, $k) = @_; return $s->{'params'}->{$k} }
	sub render { my ($s, %o) = @_; $s->{'answer'} = $o{'json'}; return $s }
	sub rendered { my ($s, $code) = @_; $s->{'status'} = $code; return $s }
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

# A flash that found no token still leaves the file behind, empty. That is no
# token, not a broken one: the board can finish its own setup and, above all,
# must not put the first-run questions back on every boot.
{
	my $empty = "$dry/empty-token.json";
	open(my $fh, '>', $empty) or die "$empty: $!";
	close $fh;
	my $said = &run_first_boot($emmc, '--token', $empty);
	is($said->{'token'}, 'none', 'an empty join token file is no token');
	is($said->{'ok'}, 1, 'and the rest of the first boot still runs');
}

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
like($js, qr/recovery: 'Recovery image'/, 'the page names the recovery copy it found');
like(read_file(root() . '/perl/help/topics_apps.pl'), qr/copy of the recovery image/, 'the guide says the board keeps a copy');

# The flash mints its single-use token into a temp file before the provisioner
# runs. File::Temp needs the X's at the end of the template: a .json after them
# made every flash die before the write, and the page showed only "The board was
# not flashed." (2026-11-15).
{
	local $ENV{'HOME'} = $dry;
	my $mint = Manager::_controller_join_token(JoinProbe->new, 'gou2026', 'gou2026', 'adopt');
	ok(ref $mint eq 'HASH' && defined $mint->{'path'}, 'the flash mints a join token file');
	my $path = $mint->{'path'} // '';
	ok(length($path) && -f $path, 'the token file is written');
	like($path, qr{controller_join_.*\.json$}, 'named as a json file');
	is(sprintf('%04o', (stat($path))[2] & 07777), '0600', 'readable only by its owner');
	my $token = eval { $JSON->decode(read_file($path)) } || {};
	is($token->{'kind'}, 'jawnos-controller-join', 'it is a controller join token');
	is($token->{'card'}, 'adopt', 'carrying the card answer');
	is($token->{'secret'}, $mint->{'secret'}, 'and the secret the cache holds');
	ok(subs::db_select('cache', undef, { context => 'controller_join', subcontext => $mint->{'secret'} })->hash,
		'the secret waits in the local cache');
	unlink $path if length $path;
	subs::db_delete('cache', { context => 'controller_join', subcontext => $mint->{'secret'} }) if $mint->{'secret'};
}

# A joining board is named under the house domain and, when the CA is on this
# machine, given its own leaf for that name. The map is the synced one
# Configure -> Plat -> DNS shows, so the name appears there and the board reads
# its own entry back through public_host.
{
	my $openssl = `command -v openssl 2>/dev/null`;
	chomp $openssl;
	SKIP: {
	skip 'openssl is not installed', 21 unless $openssl && length $openssl && -x $openssl;
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
	# The house can issue the leaf for a peer. A laptop that flashes a board has
	# no CA key, so its join asks the CA holder over the peer rail; this route is
	# the other half of that. Only a trusted peer and a name under the domain are
	# accepted.
	{
		no warnings 'redefine';
		local *subs::peer_verify = sub { 1 };
		local *subs::peer_allows = sub { 1 };
		my $probe3 = LeafProbe->new({ signatorial => $sig2, name => 'gou2026.example.test', address => '192.168.1.50' });
		Manager::action_38591($probe3);
		my $leaf = $probe3->{'answer'} || {};
		ok($leaf->{'ok'}, 'the house issues a leaf for a peer that asks');
		is($leaf->{'tls'}->{'host'}, 'gou2026.example.test', 'for the name it asked about');
		like($leaf->{'tls'}->{'cert'}, qr/-----BEGIN CERTIFICATE-----/, 'with the chain');
		like($leaf->{'tls'}->{'key'}, qr/PRIVATE KEY-----/, 'and the key');
		my $peer_leaf = "$dry/peer-leaf.pem";
		open(my $pl, '>', $peer_leaf) or die "cannot write $peer_leaf: $!";
		print {$pl} $leaf->{'tls'}->{'cert'} // '';
		close $pl;
		my $peer_ok = `$openssl verify -CAfile '$ENV{'JAWNOS_STORE_DIR'}/server/house-ca.pem' '$peer_leaf' 2>&1`;
		like($peer_ok, qr/: OK/, 'and it chains to this house CA');

		my $outside = LeafProbe->new({ signatorial => $sig2, name => 'evil.example.org', address => '192.168.1.50' });
		Manager::action_38591($outside);
		ok(!$outside->{'answer'}->{'ok'}, 'a name outside the house domain is refused');
	}
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
like($device_source, qr/sub _controller_leaf_from_house/, 'a client asks the house for the leaf');
like($device_source, qr/sub action_38591/, 'the house can issue a leaf for a peer');
like($device_source, qr/peer_allows\(\$c, \$rm, 'trusted'\)/, 'only a trusted peer may ask');
like($device_source, qr/that name is not under this house domain/, 'and only for a name under it');
like($device_source, qr/cookie_jar->add\(Mojo::Cookie::Response/, 'the relay also presents the machine\'s peer session');
like($device_source, qr/'https:\/\/' \. \$public/, 'the relay tries the house\'s public name first');
like($device_source, qr/\(\?:\/\|\$\)\}/, 'and reads the port from a manager with or without /manager');
like(slurp('lib/JawnOS/Routes/manager_device.pm'), qr{38591.*device/leaf}, 'the leaf route is registered');
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
