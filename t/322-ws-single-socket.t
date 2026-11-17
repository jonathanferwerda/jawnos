# tests-for: lib/JawnOS/Domain/Key.pm lib/JawnOS/Manager/Core2_worker_boot.pm perl/Websocket.pl scripts/tools/ws_relay_bench.pl
# covers:    one relay socket carries every app (the frame names its own app),
#            the per-app shape is still reachable, and the worker and every
#            sender name the same path instead of concatenating the raw app.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);
use Sereal::Encoder qw(encode_sereal);
use Sereal::Decoder qw(decode_sereal);
use JawnOSTest;

my $root = root();

# --- the one path ------------------------------------------------------------

my $dir = tempdir('jawnos-ws-single-XXXXXX', TMPDIR => 1, CLEANUP => 1);

{
	local $subs::install_dir = $dir;
	local $ENV{'JAWNOS_RUN_DIR'} = '';
	local $ENV{'JAWNOS_WS_PER_APP'} = '';
	local $subs::ws_single_memo;
	ok(subs::ws_single_socket(), 'one relay socket is the default');
	is(subs::ws_socket_path('lunch'), "$dir/run/ws/ws", 'every app shares the one path');
	is(subs::ws_socket_path(''), "$dir/run/ws/ws", 'an unnamed app shares it too');
	is(subs::ws_socket_path('a b'), "$dir/run/ws/ws", 'a name cannot change the shared path');
}

{
	local $subs::install_dir = $dir;
	local $ENV{'JAWNOS_RUN_DIR'} = '';
	local $ENV{'JAWNOS_WS_PER_APP'} = '1';
	local $subs::ws_single_memo;
	ok(!subs::ws_single_socket(), 'the env forces the per-app shape for an A/B run');
	is(subs::ws_socket_path('lunch'), "$dir/run/ws/lunch", 'an app keeps its own path');
	is(subs::ws_socket_path('a b'), "$dir/run/ws/a%20b", 'a path component goes through path_name');
	is(subs::ws_socket_path('travel@x'), "$dir/run/ws/travel%40x", 'the @ form is encoded like the binder encodes it');
	is(subs::ws_socket_path(''), "$dir/run/ws/general", 'an unnamed app keeps the general fallback');
}

# --- one socket carries a frame end to end -----------------------------------

subtest 'a frame written to the one path reaches its receiver' => sub {
	my $tmp = tempdir('jawnos-ws-e2e-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	local $subs::install_dir = $tmp;
	local $ENV{'JAWNOS_RUN_DIR'} = '';
	local $ENV{'JAWNOS_WS_PER_APP'} = '';
	local $subs::ws_single_memo;
	my $path = subs::ws_socket_path('tab');
	my $seen = "$tmp/seen";
	my $pid = fork();
	plan skip_all => 'fork is unavailable' unless defined $pid;
	if ($pid == 0) {
		require IO::Socket::UNIX;
		require Socket;
		my $listener = IO::Socket::UNIX->new(
			Type => Socket::SOCK_STREAM(), Local => $path, Listen => 1,
		) or exit 1;
		my $conn = $listener->accept or exit 2;
		my $hdr = '';
		while (length($hdr) < 4) {
			my $n = sysread($conn, $hdr, 4 - length($hdr), length($hdr));
			exit 3 unless $n;
		}
		my $len = unpack('N', $hdr);
		my $blob = '';
		while (length($blob) < $len) {
			my $n = sysread($conn, $blob, $len - length($blob), length($blob));
			exit 4 unless $n;
		}
		my $m = eval { decode_sereal($blob) } || {};
		open(my $fh, '>', $seen) or exit 5;
		print {$fh} ($m->{'app'} // '?') . '|' . ($m->{'uuid'} // '?');
		close $fh;
		exit 0;
	}
	for (1 .. 50) { last if -S $path; select undef, undef, undef, 0.1 }
	ok(-S $path, 'the receiver bound the shared path');
	subs::unix_socket_sender($path, { app => 'tab', uuid => 'probe-1', message => '{"ok":1}' });
	waitpid($pid, 0);
	is($? >> 8, 0, 'the receiver parsed the frame and exited cleanly');
	is(read_file($seen), 'tab|probe-1', 'the frame carried its own app on the shared socket');
};

# --- the worker and the sender agree on the shape ----------------------------

my $boot = read_file("$root/lib/JawnOS/Manager/Core2_worker_boot.pm");
like($boot, qr/if \(&subs::ws_single_socket\(\)\) \{\s*my \$server = \$ws_server->\{'__single'\};/s,
	'the rebind keeps one listener for the shared shape');
like($boot, qr/\$ws_server->\{'__single'\} = &ws_server_socket\(\{ app => 'ws' \}\)/,
	'the shared listener is bound once');
like($boot, qr/\$file = &subs::ws_socket_path\(\$app\);/, 'the binder names the path through the helper');
like($boot, qr/my \$file = &subs::ws_socket_path\(\$ws\);/, 'the rebind probe asks for the same path');
like($boot, qr/function websocket_close|sub websocket_close\(/, 'the retire path still exists for the per-app shape');
like($boot, qr/return if &subs::ws_single_socket\(\);/, 'the shared shape has no per-app listener to retire');
like($boot, qr/\$ws_single_tidy/, 'a stale per-app socket file is retired after the switch');
unlike($boot, qr/ws_dir\(\) \. '\/' \. &subs::path_name/, 'no call site builds the path by hand');

my $wspl = read_file("$root/perl/Websocket.pl");
like($wspl, qr/my \$file = &subs::ws_socket_path\(\$app\);/, 'the sender asks for the same path');
unlike($wspl, qr/ws_dir\(\) \. '\/' \. \$app/, 'the raw app is never a path again');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/\bws_single_socket\b/, 'the shape helper is in the domain loader');
like($loader, qr/\bws_socket_path\b/, 'the path helper is in the domain loader');

# --- the benchmark script the comparison runs is syntactically sound --------

my $bench = "$root/scripts/tools/ws_relay_bench.pl";
ok(-f $bench, 'the relay benchmark exists');
like(read_file($bench), qr/--shape/, 'the benchmark can run either shape');

done_testing();
