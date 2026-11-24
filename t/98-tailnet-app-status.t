# tests-for: lib/JawnOS/Domain/Warehouse.pm scripts/jawnos_network.pl perl/gb/01_state_and_defaults.pl perl/utility_jobs.pl
# covers:    the Android app's tailnet status file: Warehouse::tailnet_status
#           reports the app's state from it and falls back to
#           `tailscale status --json` when it is missing, and the network
#           helper never calls an app-held tailnet "not installed".

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::JSON qw(decode_json encode_json);
use Symbol qw(gensym);

use JawnOSTest;

# The app writes <filesDir>/tailnet/status.json; this tree's HOME is
# <filesDir>/home, so the fixture lives one level up. Nothing here reads a real
# tailnet: the app cases point HOME at a temp directory holding the fixture, and
# the fallback cases point TAILSCALE_BIN at a fake CLI (or at nothing).
my $script = "$FindBin::Bin/../scripts/jawnos_network.pl";
my $scratch = tempdir(CLEANUP => 1);
my $files   = "$scratch/files";
my $home    = "$files/home";
my $status  = "$files/tailnet/status.json";
my $empty   = "$scratch/empty";
make_path($home, "$files/tailnet", $empty);

sub write_file {
	my ($path, $body) = @_;
	open my $fh, '>', $path or die "cannot write $path: $!";
	print $fh $body;
	close $fh;
}

sub write_exe {
	my ($path, $body) = @_;
	write_file($path, "#!/bin/sh\n$body\n");
	chmod 0755, $path or die "cannot chmod $path: $!";
}

# tailnet_status memoises for three seconds; each case starts clean.
sub reset_memo {
	undef $subs::_TAILNET_STATUS;
	undef $subs::_TAILNET_STATUS_AT;
}

# ---------------------------------------------------- the app's own report ----
# "key" is not part of the documented file, and is here to prove the sub
# whitelists its fields instead of passing the file through.
my $connected = '{"state":"connected","online":true,"has_key":true,'
	. '"attempts":0,"at":1750000000000,"backend":"Running",'
	. '"key":"TAILNET-SECRET-MUST-NOT-LEAVE"}';
write_file($status, $connected);

{
	local $ENV{'HOME'} = $home;
	local $ENV{'TAILSCALE_BIN'} = "$scratch/no-tailscale-here";
	reset_memo();
	my $s = subs::tailnet_status();
	is ref $s, 'HASH', 'a status file yields a hash';
	is $s->{'available'}, 1, 'the app tailnet is available';
	is $s->{'source'}, 'app', 'the answer says it came from the app';
	is $s->{'state'}, 'connected', 'the connected state is reported';
	is $s->{'online'}, 1, 'online is a 1/0 flag';
	is $s->{'has_key'}, 1, 'has_key is a 1/0 flag';
	is $s->{'attempts'}, 0, 'attempts is kept';
	is $s->{'at'}, 1750000000000, 'the timestamp is kept in epoch milliseconds';
	is $s->{'backend'}, 'Running', 'the backend label is kept';
	is $s->{'exit'}, '', 'the app file claims no exit node';
	is_deeply $s->{'peers'}, [], 'the app file supplies no peers';
	unlike encode_json($s), qr/TAILNET-SECRET/, 'a key in the file never leaves the sub';
}

write_file($status,
	'{"state":"needs_key","online":false,"has_key":false,'
	. '"attempts":2,"at":1750000001000,"backend":"NeedsLogin"}');

{
	local $ENV{'HOME'} = $home;
	local $ENV{'TAILSCALE_BIN'} = "$scratch/no-tailscale-here";
	reset_memo();
	my $s = subs::tailnet_status();
	is $s->{'source'}, 'app', 'needs_key also comes from the app';
	is $s->{'state'}, 'needs_key', 'the needs_key state is reported';
	is $s->{'online'}, 0, 'offline is 0, not a missing field';
	is $s->{'has_key'}, 0, 'a missing key is 0';
	is $s->{'attempts'}, 2, 'the attempt count is kept';
	is $s->{'at'}, 1750000001000, 'the newer timestamp is kept';
}

# ------------------------------------- a missing file falls back to the CLI ----
my $fake = "$scratch/bin";
make_path($fake);
write_exe("$fake/tailscale", q{printf '%s' '{"BackendState":"Running","Peer":{"n1":{"HostName":"peer-one","TailscaleIPs":["100.64.0.9","fd7a::9"],"Online":true,"ExitNodeOption":true}}}'});

{
	unlink $status;
	local $ENV{'HOME'} = $home;
	local $ENV{'TAILSCALE_BIN'} = "$fake/tailscale";
	reset_memo();
	my $s = subs::tailnet_status();
	is ref $s, 'HASH', 'a missing status file still yields a hash';
	ok !exists $s->{'source'}, 'the fallback is the CLI path, not the app';
	is $s->{'available'}, 1, 'the CLI answer is available';
	my $peers = $s->{'peers'} || [];
	is scalar @$peers, 1, 'the CLI peer is reported';
	is $peers->[0]->{'ip'}, '100.64.0.9', 'the address comes from TailscaleIPs';
	is $peers->[0]->{'online'}, 1, 'the peer is online';
	is $peers->[0]->{'exit'}, 1, 'the peer offers an exit node';
}

{
	local $ENV{'HOME'} = $home;
	local $ENV{'TAILSCALE_BIN'} = "$scratch/no-tailscale-here";
	reset_memo();
	my $s = eval { subs::tailnet_status() };
	is $@, '', 'a missing CLI does not die';
	is ref $s, 'HASH', 'a missing CLI still yields a hash';
	is $s->{'available'}, 0, 'and reports itself unavailable';
	is_deeply $s->{'peers'}, [], 'with no peers';
}

# ----------------------------------- the helper speaks for the app's tailnet ----
sub run_net {
	my (%opt) = @_;
	local $ENV{'PATH'} = defined $opt{'path'} ? $opt{'path'} : $empty;
	local $ENV{'HOME'} = defined $opt{'home'} ? $opt{'home'} : $home;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $script, @{ $opt{'args'} || [] });
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
}

write_file($status, $connected);
{
	my ($rc, $out) = run_net(args => ['vpn_tailscale', 'up']);
	my $data = eval { decode_json($out) } || {};
	is $rc, 0, 'vpn_tailscale answers without a process failure';
	is $data->{'ok'}, 0, 'the request is refused, not acted on';
	is $data->{'error'},
		'The Android app holds the tailnet: turn on Auto-connect in the dashboard.',
		'an app-held tailnet is named, not called missing';
	unlike($data->{'error'} // '', qr/not installed/i,
		'and it never says Tailscale is not installed');
}


# ---------------------------------------- the watcher revives a lost TUN ----
# A connected app status with no 100.64/10 interface is the shape a lost TUN
# leaves; the watcher asks the app to start it again, at most once per five
# minutes.
subs::preload(qw(network_interface_reporter cache_get cache_set));

write_file($status, $connected);
{
	local $ENV{'HOME'} = $home;
	local $ENV{'TAILSCALE_BIN'} = "$scratch/no-tailscale-here";
	reset_memo();
	my %cache;
	local *subs::cache_get = sub {
		my ($k) = @_;
		return $cache{($k->{'context'} || '') . '|' . ($k->{'subcontext'} || '')};
	};
	local *subs::cache_set = sub {
		my ($k, $v) = @_;
		$cache{($k->{'context'} || '') . '|' . ($k->{'subcontext'} || '')} = $v;
		return 1;
	};
	local *subs::network_interface_reporter = sub { return { wlan0 => { ip => '192.168.1.84' } } };
	my @sent;
	my $notify = sub { push @sent, $_[0]; return 1 };
	my $now = 1750000100000;
	my $r = subs::tailnet_watch({ notify => $notify, now => $now });
	is $r->{'action'}, 'revive', 'connected with no tailnet address asks for a restart';
	is_deeply \@sent, ['com.jawnos.app.JAWN_TAILNET'], 'through the app tailnet receiver action';
	my $again = subs::tailnet_watch({ notify => $notify, now => $now + 60_000 });
	is $again->{'action'}, 'throttled', 'a second ask within five minutes waits';
	is scalar @sent, 1, 'and does not broadcast again';
	my $later = subs::tailnet_watch({ notify => $notify, now => $now + 6 * 60_000 });
	is $later->{'action'}, 'revive', 'after five minutes it tries again';
	is scalar @sent, 2, 'with another broadcast';
}
{
	local $ENV{'HOME'} = $home;
	reset_memo();
	local *subs::network_interface_reporter = sub { return { tun1 => { ip => '100.64.0.8' } } };
	my @sent;
	my $r = subs::tailnet_watch({ notify => sub { push @sent, $_[0]; return 1 }, now => 1750000200000 });
	is $r->{'action'}, 'none', 'a tun address is not a lost tunnel';
	is scalar @sent, 0, 'and nothing is broadcast';
}
write_file($status, '{"state":"needs_key","online":false,"has_key":false,"attempts":2,"at":1750000001000,"backend":"NeedsLogin"}');
{
	local $ENV{'HOME'} = $home;
	reset_memo();
	my @sent;
	my $r = subs::tailnet_watch({ notify => sub { push @sent, $_[0]; return 1 }, now => 1750000300000 });
	is $r->{'action'}, 'none', 'a needs_key state is left to the app';
	is scalar @sent, 0, 'and nothing is broadcast';
}
{
	unlink $status;
	local $ENV{'HOME'} = $home;
	local $ENV{'TAILSCALE_BIN'} = "$scratch/no-tailscale-here";
	reset_memo();
	my @sent;
	my $r = subs::tailnet_watch({ notify => sub { push @sent, $_[0]; return 1 }, now => 1750000400000 });
	is $r->{'action'}, 'none', 'a machine with no app status is a no-op';
	is scalar @sent, 0, 'and nothing is broadcast';
}
like(read_file("$FindBin::Bin/../perl/gb/01_state_and_defaults.pl"),
	qr/'tailnet_watch'\s*=>\s*\{[^}]*toggle\s*=>\s*'on'/, 'the tailnet watch is an on-by-default job');
like(read_file("$FindBin::Bin/../perl/utility_jobs.pl"),
	qr/timeouts->\{'tailnet_watch'\}->\{'subroutine'\}/, 'the utility runner defines the tailnet watch');

done_testing();
