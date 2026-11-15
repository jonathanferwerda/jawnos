# tests-for: scripts/jawnos_network.pl
# covers:    the Wi-Fi keyring (systemd-creds), the private files iwd and
#           NetworkManager are handed, the transparent scrubbing of a stack's
#           own copy, and the legacy path when systemd-creds is not installed
#
# The passphrase in this file is a fixture, not a secret. Every command is a
# fake that logs its argv; the test asserts the fixture appears in none of those
# logs, and only on the stdin/systemd-creds channel or in a 0600 file that is
# removed immediately.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;

use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::JSON qw(decode_json);
use Symbol qw(gensym);
use Digest::SHA qw(sha1_hex sha256_hex);

my $script = "$FindBin::Bin/../scripts/jawnos_network.pl";
my $scratch = tempdir(CLEANUP => 1);
my $iwdbin  = "$scratch/iwdbin";
my $nmbindir = "$scratch/nmbindir";
my $iwd     = "$scratch/iwd";
my $nm_dir  = "$scratch/nm";
my $secrets = "$scratch/secrets";
my $networkd = "$scratch/networkd";
my $nosudo = "$scratch/nosudo";
mkdir $_ or die "cannot make $_: $!"
	for $iwdbin, $nmbindir, $iwd, $nm_dir, $secrets, $networkd, $nosudo;
chmod 0700, $secrets;

my $iwd_state = "$scratch/iwctl-state";
my $iwctl_log = "$scratch/iwctl.log";
my $nm_log    = "$scratch/nm.log";
my $nm_passwd = "$scratch/nm-passwd";
my $creds_argv = "$scratch/creds-argv.log";
my $creds_stdin = "$scratch/creds-stdin.log";
my $creds_root = "$scratch/creds-root.log";
my $sudo_log = "$scratch/sudo.log";
my $creds = "$iwdbin/systemd-creds";

sub write_exe {
	my ($path, $body) = @_;
	open my $fh, '>', $path or die "cannot write $path: $!";
	print $fh "#!/bin/sh\n$body\n";
	close $fh;
	chmod 0755, $path or die "cannot chmod $path: $!";
}

write_exe("$iwdbin/test", <<'FAKE_TEST');
if [ "$1" = "-s" ]; then [ -s "$2" ]; exit $?; fi
if [ "$1" = "-e" ]; then [ -e "$2" ]; exit $?; fi
exit 1
FAKE_TEST

write_exe($creds, <<'FAKE_CREDS');
# The real tool needs root (or a polkit agent) for the host key. This fixture
# refuses an unprivileged call, so a test can prove the helper asked sudo first
# instead of leaving the person - or a headless machine - to a password prompt.
if [ "$1" = "encrypt" ] || [ "$1" = "decrypt" ]; then
    [ "$JAWNOS_FAKE_ROOT" = "1" ] || { echo 'Interactive authentication required.' >&2; exit 1; }
    printf '1' > "$CREDS_ROOT"
fi
if [ "$1" = "encrypt" ]; then
	printf '%s\n' "$*" >> "$CREDS_ARGV"
	/bin/cat > "$CREDS_STDIN"
	printf 'RkFLRUVOQ1JZUFQ=\n'
	exit 0
fi
if [ "$1" = "decrypt" ]; then
	printf '%s\n' "$*" >> "$CREDS_ARGV"
	printf 'correcthorse\n'
	exit 0
fi
exit 1
FAKE_CREDS

# A passwordless sudo, as the image has. It only marks the environment so the
# creds fixture can tell a privileged call from a direct one.
write_exe("$iwdbin/sudo", <<'FAKE_SUDO');
[ "$1" = "-n" ] && shift
printf '%s\n' "$*" >> "$SUDO_LOG"
JAWNOS_FAKE_ROOT=1
export JAWNOS_FAKE_ROOT
exec "$@"
FAKE_SUDO

write_exe("$nmbindir/sudo", <<'FAKE_SUDO');
[ "$1" = "-n" ] && shift
printf '%s\n' "$*" >> "$SUDO_LOG"
JAWNOS_FAKE_ROOT=1
export JAWNOS_FAKE_ROOT
exec "$@"
FAKE_SUDO

write_exe("$iwdbin/iwctl", <<'FAKE_IWCTL');
printf '%s\n' "$*" >> "$IWCTL_LOG"
case "$*" in
	*"station wlan0 connect "*)
		printf '%s' "${*#*station wlan0 connect }" > "$IWCTL_STATE"
		if [ -n "$IWCTL_SNAPSHOT" ]; then
			: > "$IWCTL_SNAPSHOT"
			for f in "$JAWNOS_IWD_DIR"/*; do
				[ -f "$f" ] || continue
				printf '== %s\n' "${f##*/}" >> "$IWCTL_SNAPSHOT"
				/bin/cat "$f" >> "$IWCTL_SNAPSHOT"
			done
		fi
		exit 0 ;;
	"station wlan0 show")
		ssid=$(/bin/cat "$IWCTL_STATE" 2>/dev/null)
		printf 'Station: wlan0\n  State                     connected\n  Connected network         %s\n' "$ssid" ;;
	"known-networks list")
		ssid=$(/bin/cat "$IWCTL_STATE" 2>/dev/null)
		[ -n "$ssid" ] && printf '  %s\n' "$ssid"
		exit 0 ;;
	"adapter list") printf 'Name  Powered\nphy0  on\n' ;;
	*) exit 0 ;;
esac
FAKE_IWCTL

write_exe("$iwdbin/ip", <<'FAKE_IP');
if [ "$*" = "-j address show" ]; then
	printf '[{"ifname":"wlan0","address":"00:11:22:33:44:55","operstate":"up","addr_info":[{"family":"inet","local":"192.0.2.10","prefixlen":24}]}]'
	exit 0
fi
exit 0
FAKE_IP

write_exe("$nmbindir/nmcli", <<'FAKE_NMCLI');
printf '%s\n' "$*" >> "$NM_LOG"
case "$*" in
	*"passwd-file"*)
		for a in "$@"; do last="$a"; done
		/bin/cat "$last" > "$NM_PASSWD" 2>/dev/null
		exit 0 ;;
	*"--fields NAME,TYPE connection show"*) exit 0 ;;
	*"--get-values 802-11-wireless.ssid"*) printf '\n'; exit 0 ;;
	*"connection add"*) exit 0 ;;
	*"connection modify"*) exit 0 ;;
	*"connection up"*) exit 0 ;;
	*"connection delete"*) exit 0 ;;
	*) exit 0 ;;
esac
FAKE_NMCLI

write_exe("$nmbindir/ip", <<'FAKE_IP');
if [ "$*" = "-j address show" ]; then
	printf '[{"ifname":"wlan0","address":"00:11:22:33:44:55","operstate":"up","addr_info":[{"family":"inet","local":"192.0.2.10","prefixlen":24}]}]'
	exit 0
fi
exit 0
FAKE_IP

sub run_net {
	my %opt = @_;
	my $tools = defined $opt{'tools'} ? $opt{'tools'} : 'iwd';
	local $ENV{'PATH'} = defined $opt{'path'} ? $opt{'path'} : ($tools eq 'nm' ? $nmbindir : $iwdbin);
	local $ENV{'HOME'} = $scratch;
	local $ENV{'JAWNOS_IWD_DIR'} = $iwd;
	local $ENV{'JAWNOS_NM_DIR'} = $nm_dir;
	local $ENV{'JAWNOS_NETWORKD_DIR'} = $networkd;
	local $ENV{'JAWNOS_CREDS'} = defined $opt{'creds'} ? $opt{'creds'} : $creds;
	local $ENV{'IWCTL_STATE'} = $iwd_state;
	local $ENV{'IWCTL_LOG'} = $iwctl_log;
	local $ENV{'IWCTL_SNAPSHOT'} = defined $opt{'snapshot'} ? $opt{'snapshot'} : '';
	local $ENV{'NM_LOG'} = $nm_log;
	local $ENV{'NM_PASSWD'} = $nm_passwd;
	local $ENV{'CREDS_ARGV'} = $creds_argv;
	local $ENV{'CREDS_STDIN'} = $creds_stdin;
	local $ENV{'CREDS_ROOT'} = $creds_root;
	local $ENV{'SUDO_LOG'} = $sudo_log;
	local $ENV{'JAWNOS_SECRET_DIR'} = defined $opt{'secrets'} ? $opt{'secrets'} : $secrets;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $script, @{ $opt{'args'} || [] });
	print {$in} $opt{'stdin'} if defined $opt{'stdin'};
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

sub read_text {
	my ($path) = @_;
	open my $fh, '<', $path or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

sub answer {
	my ($rc, $out, $err, $what) = @_;
	is($rc, 0, "$what exits 0");
	my $data = eval { decode_json($out) };
	unless (ref $data eq 'HASH') {
		BAIL_OUT("$what did not print one JSON object: " . ($err || $out));
	}
	return $data;
}

sub reset_logs {
	unlink $iwctl_log, $nm_log, $nm_passwd, $creds_argv, $creds_stdin;
}

# --- the tool and the store --------------------------------------------------
{
	reset_logs();
	my ($rc, $out) = run_net(args => ['secret_status']);
	my $data = answer($rc, $out, '', 'secret_status');
	is($data->{'ok'}, 1, 'secret_status answers');
	is($data->{'available'}, 1, 'the fake systemd-creds is available');
	is($data->{'backend'}, 'systemd-creds', 'and is named');
	is($data->{'tpm'}, 0, 'there is no TPM on this test machine');
	is($data->{'dir'}, $secrets, 'and the store directory is the test one');
}

my $hash = sha256_hex('jawn-test-net');
my $cred = "$secrets/$hash.cred";

{
	reset_logs();
	unlink $cred;
	my ($rc, $out) = run_net(args => ['secret_set', 'jawn-test-net'], stdin => "correcthorse\n");
	my $data = answer($rc, $out, '', 'secret_set');
	is($data->{'ok'}, 1, 'the passphrase is stored');
	is($data->{'stored'}, 1, 'and reported as stored');
	is($data->{'changed'}, 1, 'because the file was written');
	ok(-s $cred, 'the ciphertext file exists');
	is((stat($cred))[2] & 07777, 0600, 'and is private');
	my $argv = read_text($creds_argv);
	like($argv, qr/--with-key=auto/, 'the tool is asked for an automatic key');
	like($argv, qr/--name=jawnos-wifi-\Q$hash\E/, 'with the SSID hash in the credential name');
	unlike($argv, qr/correcthorse/, 'the passphrase never reaches argv');
	is(read_text($creds_stdin), 'correcthorse', 'it reaches the tool on stdin, without the newline');
	# The host key is root-only, and a manager session has no polkit agent to
	# answer for it, so the helper asks sudo before it asks the person.
	is(read_text($creds_root), '1', 'systemd-creds is run through sudo, not as the person');

	my $before = read_text($cred);
	my @encrypted = read_text($creds_argv) =~ /^encrypt /mg;
	($rc, $out) = run_net(args => ['secret_set', 'jawn-test-net'], stdin => "correcthorse\n");
	$data = answer($rc, $out, '', 'secret_set again');
	is($data->{'stored'}, 1, 'a second set is still stored');
	is($data->{'changed'}, 0, 'but rewrites nothing');
	is(read_text($cred), $before, 'the ciphertext is unchanged');
	my @after = read_text($creds_argv) =~ /^encrypt /mg;
	is(scalar @after, scalar @encrypted, 'and the tool is not asked to encrypt again');

	($rc, $out) = run_net(args => ['secret_present', 'jawn-test-net']);
	$data = answer($rc, $out, '', 'secret_present');
	is_deeply($data, { ok => 1, present => 1 }, 'the stored passphrase is present');
}

{
	# No sudo on PATH: the direct call is the fallback, and its refusal is what
	# the person sees rather than a silent failure.
	unlink "$secrets/" . sha256_hex('no-sudo-net') . '.cred';
	my ($rc, $out) = run_net(path => $nosudo, args => ['secret_set', 'no-sudo-net'], stdin => "correcthorse\n");
	my $data = answer($rc, $out, '', 'secret_set without sudo');
	is($data->{'ok'}, 0, 'without sudo the store fails instead of pretending');
	like($data->{'error'}, qr/Interactive authentication required/, 'and the refusal is reported');
}

{
	# The real store is root-only, so -s cannot see into it. A directory without
	# search permission models that; the helper must ask sudo rather than trust
	# the failed stat. This fixture's sudo is not really root, so the answer is
	# asserted live on the VM; here the call itself is the point.
	my $locked = "$scratch/locked";
	mkdir $locked or die "cannot make $locked: $!";
	my $locked_cred = "$locked/" . sha256_hex('locked-net') . '.cred';
	open my $lfh, '>', $locked_cred or die "cannot write $locked_cred: $!";
	print $lfh 'ciphertext';
	close $lfh;
	chmod 0000, $locked;
	open my $slfh, '>', $sudo_log or die "cannot write $sudo_log: $!";
	close $slfh;
	my ($rc, $out) = run_net(secrets => $locked, args => ['secret_present', 'locked-net']);
	my $data = answer($rc, $out, '', 'secret_present in a root-only store');
	is($data->{'ok'}, 1, 'a root-only store is still answered');
	like(read_text($sudo_log), qr/^test -s /m, 'and the helper asks sudo to look inside');
	chmod 0700, $locked;
}

{
	my ($rc, $out) = run_net(args => ['secret_clear', 'jawn-test-net']);
	my $data = answer($rc, $out, '', 'secret_clear');
	is($data->{'ok'}, 1, 'secret_clear answers');
	is($data->{'cleared'}, 1, 'the file is removed');
	ok(!-e $cred, 'and gone');
	($rc, $out) = run_net(args => ['secret_clear', 'jawn-test-net']);
	$data = answer($rc, $out, '', 'secret_clear twice');
	is($data->{'cleared'}, 0, 'a second clear removes nothing');
	($rc, $out) = run_net(args => ['secret_present', 'jawn-test-net']);
	$data = answer($rc, $out, '', 'secret_present after clear');
	is($data->{'present'}, 0, 'and nothing is present');
}

# --- iwd: a private transient file, then the stack is scrubbed ---------------
{
	reset_logs();
	unlink glob("$iwd/*");
	unlink $iwd_state;
	my $snapshot = "$scratch/iwd-snapshot";
	my ($rc, $out) = run_net(tools => 'iwd', snapshot => $snapshot,
		args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'dhcp', '', '', '', '', 'store'],
		stdin => "correcthorse\n");
	my $data = answer($rc, $out, '', 'iwd store connect');
	is($data->{'ok'}, 1, 'the connection succeeds');
	is($data->{'secret_stored'}, 1, 'and the passphrase is in the keyring');
	is($data->{'secret_source'}, 'store', 'which is the reported source');

	my $seen = read_text($snapshot);
	like($seen, qr/\[Settings\]/m, 'the transient profile was written before the connect');
	like($seen, qr/^AutoConnect=false$/m, 'with auto-connect off');
	like($seen, qr/^\[Security\]$/m, 'and a security group');
	like($seen, qr/^Passphrase=correcthorse$/m, 'carrying the key the stack needed');

	my $path = "$iwd/jawn-test-net.psk";
	ok(-e $path, 'the network file remains');
	my $final = read_text($path);
	like($final, qr/^AutoConnect=false$/m, 'auto-connect stays off');
	unlike($final, qr/Passphrase|PreSharedKey/, 'and the key is gone after the store');
	unlike(read_text($iwctl_log), qr/correcthorse/, 'iwctl never saw the key in argv');
	ok(-s $cred, 'the ciphertext exists for the network');
}

# iwd's escape rule: a byte that is not alphanumeric, '-' or '_' or a space
# makes the whole name '=' + lowercase hex.
{
	reset_logs();
	my $ssid = 'jawn/test';
	my $hex = unpack('H*', $ssid);
	my ($rc, $out) = run_net(tools => 'iwd',
		args => ['wifi_connect', 'wlan0', $ssid, 'dhcp', '', '', '', '', 'store'],
		stdin => "correcthorse\n");
	my $data = answer($rc, $out, '', 'iwd connect to a name that needs hex');
	is($data->{'ok'}, 1, 'the SSID with a slash connects');
	my $path = "$iwd/=$hex.psk";
	ok(-e $path, 'the file is named =<hex>.psk');
	unlike(read_text($path), qr/Passphrase|PreSharedKey/, 'and is scrubbed');
}

# --- use: decrypt into memory, connect, scrub again --------------------------
{
	reset_logs();
	unlink glob("$iwd/*");
	unlink $iwd_state;
	my $snapshot = "$scratch/iwd-use-snapshot";
	my ($rc, $out) = run_net(tools => 'iwd', snapshot => $snapshot,
		args => ['wifi_connect', 'wlan0', 'jawn-test-net', 'dhcp', '', '', '', '', 'use'],
		stdin => '');
	my $data = answer($rc, $out, '', 'iwd use connect');
	is($data->{'ok'}, 1, 'the connection succeeds');
	is($data->{'secret_stored'}, 1, 'from the keyring');
	is($data->{'secret_source'}, 'store', 'and says where it came from');
	like(read_text($snapshot), qr/^Passphrase=correcthorse$/m, 'the decrypted key reached the stack');
	my $path = "$iwd/jawn-test-net.psk";
	like(read_text($path), qr/^AutoConnect=false$/m, 'the final profile keeps auto-connect off');
	unlike(read_text($path), qr/Passphrase|PreSharedKey/, 'and holds no key');
	unlike(read_text($iwctl_log), qr/correcthorse/, 'iwctl never saw the key in argv');
	like(read_text($creds_argv), qr/^decrypt /m, 'the tool was asked to decrypt');
	unlike(read_text($creds_argv), qr/correcthorse/, 'and the plaintext stayed out of argv');
}

# --- forgetting a network forgets its keyring copy ---------------------------
{
	reset_logs();
	my ($rc, $out) = run_net(tools => 'iwd', args => ['wifi_forget', 'jawn-test-net']);
	my $data = answer($rc, $out, '', 'wifi_forget');
	is($data->{'ok'}, 1, 'the network is forgotten');
	ok(!-e $cred, 'and the ciphertext is gone with it');
}

# --- NetworkManager: passwd-file, no argv secret, keyfile scrubbed -----------
{
	reset_logs();
	unlink glob("$nm_dir/*");
	unlink $nm_passwd;
	my $ssid = 'nm-test-net';
	my $name = 'jawnos-wifi-' . substr(sha1_hex($ssid), 0, 16);
	my $keyfile = "$nm_dir/$name.nmconnection";
	open my $fh, '>', $keyfile or die "cannot write $keyfile: $!";
	print $fh "[connection]\nid=$name\ntype=wifi\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=correcthorse\npsk-flags=0\n";
	close $fh;
	my ($rc, $out) = run_net(tools => 'nm',
		args => ['wifi_connect', 'wlan0', $ssid, 'dhcp', '', '', '', '', 'store'],
		stdin => "correcthorse\n");
	my $data = answer($rc, $out, '', 'nmcli store connect');
	is($data->{'ok'}, 1, 'the NetworkManager connection succeeds');
	is($data->{'secret_stored'}, 1, 'and the key is stored');
	my $log = read_text($nm_log);
	like($log, qr/wifi-sec\.psk-flags 1/, 'the profile is told the key is agent-owned');
	like($log, qr/wifi-sec\.psk  /, 'and its old stored psk is cleared');
	like($log, qr/connection\.autoconnect no/, 'auto-connect is off');
	like($log, qr/connection up \Q$name\E passwd-file /, 'the key is supplied through a passwd-file');
	unlike($log, qr/correcthorse/, 'the passphrase never reaches argv');
	like(read_text($nm_passwd), qr/^802-11-wireless-security\.psk:correcthorse$/m,
		'and the passwd-file carried it');
	my ($tmp) = $log =~ /passwd-file (\S+)/;
	ok(defined $tmp && !-e $tmp, 'the temp passwd-file is unlinked');
	my $keytext = read_text($keyfile);
	like($keytext, qr/^psk-flags=1$/m, 'the keyfile says the key is agent-owned');
	unlike($keytext, qr/^psk=/m, 'and carries no psk');
}

# --- no systemd-creds: the stack keeps its own copy and nothing is scrubbed --
{
	reset_logs();
	unlink glob("$iwd/*");
	my $legacy = "$iwd/legacy-net.psk";
	my $old = "[Settings]\nAutoConnect=true\n\n[Security]\nPassphrase=oldsecret\n";
	open my $fh, '>', $legacy or die "cannot write $legacy: $!";
	print $fh $old;
	close $fh;
	my ($rc, $out) = run_net(tools => 'iwd', creds => 'none',
		args => ['wifi_connect', 'wlan0', 'legacy-net', 'dhcp', '', '', '', '', 'store'],
		stdin => "correcthorse\n");
	my $data = answer($rc, $out, '', 'store without systemd-creds');
	is($data->{'ok'}, 1, 'the connection still succeeds');
	is($data->{'secret_stored'}, 0, 'but nothing is stored');
	like($data->{'warning'}, qr/systemd-creds/, 'and the answer says why');
	is(read_text($legacy), $old, 'the stack file is left untouched');
	ok(!-e "$secrets/" . sha256_hex('legacy-net') . '.cred', 'and no ciphertext exists');
}

# --- release puts the stored keys back into the stack ------------------------
{
	reset_logs();
	unlink glob("$iwd/*");
	unlink $iwd_state;
	my ($rc, $out) = run_net(tools => 'iwd', args => ['secret_set', 'release-net'], stdin => "correcthorse\n");
	is(answer($rc, $out, '', 'secret_set for release')->{'stored'}, 1, 'a key is stored');
	open my $state, '>', $iwd_state or die "cannot write $iwd_state: $!";
	print $state 'release-net';
	close $state;
	($rc, $out) = run_net(tools => 'iwd', args => ['secrets_release']);
	my $data = answer($rc, $out, '', 'secrets_release');
	is_deeply($data->{'restored'}, ['release-net'], 'the stored key is put back');
	is_deeply($data->{'missing'}, [], 'with nothing missing');
	my $text = read_text("$iwd/release-net.psk");
	like($text, qr/^AutoConnect=true$/m, 'auto-connect is back on');
	like($text, qr/^Passphrase=correcthorse$/m, 'and the stack has the key again');
}

done_testing();
