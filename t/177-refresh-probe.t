# tests-for: scripts/tools/refresh-probe.pl public/js/probe/refresh-probe.js templates/layouts/manager.html.ep
# covers:    the two halves of the WebUI refresh probe. The browser half is
#            served by the app and reloaded from a cookie, so a reload (the
#            event being measured) does not lose it; the Perl half collects a
#            long multi-device run and reports each device's reloads beside
#            the server events in the same window.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Mojo::Template;
use Encode qw(decode);

my $root = abs_path("$FindBin::Bin/..");
my $pl   = "$root/scripts/tools/refresh-probe.pl";
my $js   = "$root/public/js/probe/refresh-probe.js";
my $layout = "$root/templates/layouts/manager.html.ep";

ok(-r $pl, 'the perl half is present');
ok(-r $js, 'the browser half is served by the app');
ok(!-e "$root/scripts/tools/refresh-probe.js",
	'the console-only copy moved beside the app');

my $src = do { local $/; open(my $fh, '<', $js) or die "$js: $!"; <$fh> };
like($src, qr/jawnosRefreshProbe/, 'the browser half exposes a dump handle');
like($src, qr/jawnosUpdateQuietReload/, 'it watches the quiet-reload path');
like($src, qr/jawnosRevisionArrived/, 'and the revision handler');
like($src, qr/probe_endpoint/, 'the collector endpoint is installable per device');
like($src, qr/probe_device/, 'and so is the device label');
like($src, qr/setInterval\(heartbeat, 60000\)/, 'it sends a heartbeat over a long run');
like($src, qr/document\.cookie = COOKIE/, 'it renews the cookie that reloads it');
like($src, qr/window\.jawnos_probe_endpoint/, 'the injected collector is the default');
like($src, qr/window\.jawnos_probe_host/, 'so is the injected host name');

my $node = `command -v node 2>/dev/null`;
chomp $node;
SKIP: {
	skip 'node is not installed', 1 unless length $node;
	is(system($node, '--check', $js), 0, 'the browser half parses');
}

my $layout_src = decode('UTF-8', do { local $/; open(my $fh, '<', $layout) or die "$layout: $!"; <$fh> });
like($layout_src, qr{/js/probe/refresh-probe\.js}, 'the layout includes the probe');
like($layout_src, qr{jawnos_probe_endpoint}, 'it injects the collector endpoint');
like($layout_src, qr{jawnos_probe_host}, 'and the device host name');
like($layout_src, qr{\$probe_default}, 'the temporary default is a named switch');
like($layout_src, qr{jawnos_probe=0}, '?probe=0 records a lasting opt-out');

# Reading the source is not enough: a bad if/elsif split across separate
# <% %> tags is valid text and invalid Perl (it broke the manager page on
# 2026-11-14). Compile the layout the way the manager does, with the escape
# sub and stash vars the renderer would install.
my $compiled = eval {
	my $mt = Mojo::Template->new->parse($layout_src);
	my $code = $mt->_wrap($mt->_compile->code, {});
	$code =~ s/use Mojo::Base -strict;/use Mojo::Base; no strict;/;
	my $ns = $mt->namespace;
	{
		no warnings 'redefine';
		no strict 'refs';
		*{"${ns}::_escape"} = sub { $_[0] };
	}
	eval $code;
};
is($@, '', 'the manager layout compiles');
ok(ref $compiled eq 'CODE', 'and yields a template');

sub write_file {
	my ($dir, $name, $text) = @_;
	my $path = "$dir/$name";
	open(my $fh, '>', $path) or die "$path: $!";
	print {$fh} $text;
	close $fh;
	return $path;
}

my $dir = tempdir(CLEANUP => 1);
my $empty_log = write_file($dir, 'empty.log', '');

# Two devices in one capture, one rotated file, and the laptop's own events
# just before its reload.
my $old = '{"t":1700000000000,"src":"browser","device":"phone","ev":"page_load","nav":"navigate"}';
my $out = "$dir/probe.jsonl";
write_file($dir, 'probe.jsonl.1', "$old\n");
write_file($dir, 'probe.jsonl',
	'{"t":1700000000100,"src":"browser","device":"laptop","ev":"page_load","nav":"navigate","ua":"Mozilla/5.0 laptop"}' . "\n"
	. '{"t":1700000000200,"src":"browser","device":"laptop","ev":"hidden"}' . "\n"
	. '{"t":1700000000300,"src":"browser","device":"laptop","ev":"page_load","nav":"reload","since_prev_ms":200,"autoreload":"on","prev_events":[{"t":1700000000200,"ev":"hidden"}]}' . "\n"
	. '{"t":1700000000400,"src":"browser","device":"phone","ev":"page_load","nav":"reload","autoreload":"off"}' . "\n"
	. '{"t":1700000000500,"src":"browser","device":"phone","ev":"heartbeat"}' . "\n"
	. '{"t":1700000000600,"src":"browser","device":"phone","ev":"heartbeat"}' . "\n");

my $report = `"$^X" "$pl" --report --out "$out" --log "$empty_log" 2>&1`;
is($? >> 8, 0, 'the report exits 0');
like($report, qr/devices:.*laptop=3.*phone=4/, 'it groups the capture by device');
like($report, qr/^laptop \(laptop\)$/m, 'it names the laptop');
like($report, qr/^phone$/m, 'and the phone');
like($report, qr/reloads=1/, 'it counts each device\'s reload');
like($report, qr/gap=0s/, 'it prints the gap since the previous event');
like($report, qr/auto=on/, 'it carries the auto-reload setting');
like($report, qr/cause: hidden/, 'and the event before the reload');
like($report, qr/auto=off/, 'the other device is not confused with the first');
like($report, qr/browser remembered/, 'it shows the previous page\'s remembered events');
like($report, qr{phone/browser:page_load = 2}, 'a rotated file is part of the capture');

my $browser = write_file($dir, 'browser.json',
	'[{"t":1700000000700,"src":"browser","device":"tablet","ev":"page_load","nav":"reload"}]');
my $merged = `"$^X" "$pl" --report --out "$out" --log "$empty_log" --browser "$browser" 2>&1`;
like($merged, qr/tablet/, 'a saved browser dump joins the report');

my $quiet = write_file($dir, 'navigate.json',
	'[{"t":1700000000800,"src":"browser","device":"phone","ev":"page_load","nav":"navigate"}]');
my $quiet_report = `"$^X" "$pl" --report --out "$dir/none.jsonl" --log "$empty_log" --browser "$quiet" 2>&1`;
like($quiet_report, qr/no page reloads/, 'a navigating load is not called a reload');

# The collector opens the manager log at its end. A buffered handle that has
# seen EOF keeps that flag when the file grows, so the live half recorded only
# its tree fingerprints; this proves a line appended after open is seen.
SKIP: {
	my $probe = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1);
	skip 'no loopback socket for the live-tail test', 3 unless $probe;
	my $port = $probe->sockport;
	close $probe;

	my $live_log = write_file($dir, 'live.log', "before\n");
	my $live_out = "$dir/live.jsonl";
	my $pid = fork();
	skip 'fork failed', 1 unless defined $pid;
	if (!$pid) {
		open(STDOUT, '>', '/dev/null');
		open(STDERR, '>', '/dev/null');
		exec($^X, $pl, '--port', $port, '--listen', '127.0.0.1',
			'--log', $live_log, '--out', $live_out, '--hours', '0.001',
			'--tree', $dir, '--tree-interval', '3600', '--quiet');
		exit 1;
	}
	sleep 1;
	open(my $lf, '>>', $live_log) or die "$live_log: $!";
	print {$lf} "worker spawn live-tail-test\n";
	close $lf;

	my $timed_out = 0;
	eval {
		local $SIG{ALRM} = sub { die "timeout\n" };
		alarm 15;
		waitpid($pid, 0);
		alarm 0;
	};
	if ($@) {
		$timed_out = 1;
		kill 'TERM', $pid;
		waitpid($pid, 0);
	}
	ok(!$timed_out, 'the collector stopped after --hours');
	my $raw = '';
	if (-r $live_out) {
		local $/;
		open(my $fh, '<', $live_out) or die "$live_out: $!";
		$raw = <$fh>;
		close $fh;
	}
	like($raw, qr/"kind":"worker_spawn"/, 'the live tail sees a line appended after it opened');
	like($raw, qr/live-tail-test/, 'and keeps the line text');
}

done_testing();
