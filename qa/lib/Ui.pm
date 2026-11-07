package Ui;

# The UI layer's two engines.
#
# Chromium (CDP) is the breadth check: visit every page, collect console
# errors, failed requests, 4xx assets, and a small accessibility/layout probe.
# It is not the Qt WebEngine view the desktop defaults to (different build and
# flags); that view has its own --probe in desktop/jawnos-qt.
#
# WebKitGTK 4.1 is the desktop's fallback view (desktop/jawnos_desktop/webview.py),
# so the manager page is also loaded there under Xvfb and probed. A page that
# only works in Chromium is not proven in the fallback.

use strict;
use warnings;

use File::Basename qw(dirname);
use Cwd qw(abs_path);
use JSON::PP;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use Time::HiRes qw(time sleep);
use POSIX ();
use IO::Socket::INET;

our $VERSION = "1";

sub _ui_dir { return abs_path(dirname(__FILE__) . "/../ui") }

sub _which {
	my ($name) = @_;
	my $p = `command -v $name 2>/dev/null`;
	chomp $p if defined $p;
	return (defined $p && length $p && -x $p) ? $p : undef;
}

sub chromium { return _which('chromium') || _which('chromium-browser') || _which('google-chrome') }
sub xvfb     { return _which('xvfb-run') }

sub webkit_available {
	return 0 unless xvfb();
	my $rc = system('python3', '-c',
		'import gi; gi.require_version("Gtk","3.0"); gi.require_version("WebKit2","4.1"); from gi.repository import Gtk, WebKit2');
	return $rc == 0 ? 1 : 0;
}

sub _free_port {
	my $s = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, ReuseAddr => 1)
		or return 0;
	my $port = $s->sockport;
	close $s;
	return $port;
}

sub probe {
	my ($class, %opt) = @_;
	my $urls = $opt{'urls'} or return { error => 'no urls' };
	my $out  = $opt{'out'}  or return { error => 'no output dir' };
	make_path($out);

	my $chrome = chromium();
	return { error => 'chromium is not installed', engine => 'chromium' } unless $chrome;

	my $port = _free_port();
	return { error => 'no free debug port', engine => 'chromium' } unless $port;
	my $log = "$out/chrome.log";
	open(my $logfh, '>>', $log) or return { error => "$log: $!", engine => 'chromium' };
	close $logfh;

	my $pid = fork();
	return { error => "fork: $!", engine => 'chromium' } unless defined $pid;
	if (!$pid) {
		POSIX::setsid();
		$ENV{'HOME'} = $out;
		open(STDOUT, '>>', $log) or POSIX::_exit(126);
		open(STDERR, '>&', \*STDOUT) or POSIX::_exit(126);
		exec $chrome,
			'--headless=new', '--no-sandbox', '--disable-gpu',
			'--disable-dev-shm-usage', '--ignore-certificate-errors',
			'--disable-background-networking', '--no-first-run',
			'--disable-sync', '--disable-extensions',
			"--user-data-dir=$out/chrome", "--remote-debugging-port=$port",
			'about:blank';
		POSIX::_exit(127);
	}

	# Wait for the DevTools endpoint, not just for the process.
	require HTTP::Tiny;
	my $tiny = HTTP::Tiny->new(timeout => 2, keep_alive => 0);
	my $ready = 0;
	for (1 .. 60) {
		my $r = $tiny->get("http://127.0.0.1:$port/json/version");
		if (($r->{'status'} || 0) == 200) { $ready = 1; last }
		sleep 0.25;
	}
	unless ($ready) {
		kill 'KILL', -$pid;
		waitpid($pid, 0);
		return { error => 'chromium did not expose CDP', engine => 'chromium' };
	}

	my $urls_file = "$out/urls.json";
	write_file($urls_file, JSON::PP->new->canonical->encode($urls));
	my $rc = system('timeout', '150', 'node', _ui_dir() . "/probe.js", $port, $urls_file, $out);

	kill 'KILL', -$pid;
	waitpid($pid, 0);

	# A page that hangs must not discard the pages already captured: probe.js
	# writes ui.json after every page, so read what exists before judging rc.
	my $json;
	my $read_err = '';
	for (1 .. 20) {
		my $text = '';
		if (open(my $fh, '<', "$out/ui.json")) {
			local $/;
			$text = <$fh> // '';
			close $fh;
		}
		$json = eval { JSON::PP->new->utf8->decode($text) };
		last if ref $json eq 'HASH';
		$read_err = ($@ || 'missing') . ' [' . length($text) . ' bytes]';
		sleep 0.2;
	}
	if (ref $json eq 'HASH') {
		$json->{'partial'} = 1 if $rc != 0;
		return $json;
	}
	return { error => "probe.js exited " . ($rc >> 8) . " and wrote no readable ui.json ($read_err)",
		engine => 'chromium' };
}

sub webkit {
	my ($class, %opt) = @_;
	my $url = $opt{'url'} or return { error => 'no url', engine => 'webkit' };
	my $out = $opt{'out'} or return { error => 'no output', engine => 'webkit' };

	my $xvfb = xvfb();
	return { error => 'xvfb-run is not installed', engine => 'webkit' } unless $xvfb;
	return { error => 'python3 gi/WebKit2 4.1 is not available', engine => 'webkit' }
		unless webkit_available();

	# WebKit keys its profile by program name under XDG_DATA_HOME and keeps
	# service-worker registrations there. The QA tree always answers on the same
	# loopback origin, so a profile shared between runs resurrects the previous
	# run's service worker and the next navigation fails in its fetch handler
	# ("FetchEvent.respondWith received an error"). Give each run its own
	# profile, the way chromium gets --user-data-dir=$out/chrome below.
	my $profile = dirname($out) . '/webkit-profile';
	make_path("$profile/data", "$profile/cache", "$profile/config");

	my @cmd = ($xvfb, '-a', '-s', '-screen 0 1280x900x24');
	my $dbus = _which('dbus-run-session');
	push @cmd, $dbus, '--' if $dbus;
	push @cmd, 'env',
		'WEBKIT_DISABLE_COMPOSITING_MODE=1',
		'WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1',
		'GDK_BACKEND=x11',
		"XDG_DATA_HOME=$profile/data",
		"XDG_CACHE_HOME=$profile/cache",
		"XDG_CONFIG_HOME=$profile/config";
	push @cmd, 'python3', _ui_dir() . "/webkit_probe.py", $url, $out;
	my $rc = system('timeout', '120', @cmd);

	# The probe writes a report even when it gives up (timeout, no load), so
	# read it first: its reason is more useful than the wrapper's exit code.
	my $json = eval { JSON::PP->new->utf8->decode(read_file($out)) };
	unless (ref $json eq 'HASH') {
		return { engine => 'webkit', error => 'webkit_probe.py exited '
			. ($rc >> 8) . " and wrote no readable report" . ($@ ? " ($@)" : '') };
	}
	if ($json->{'error'}) {
		my $reason = $json->{'reason'} || $json->{'error'};
		my $events = join('; ', @{ $json->{'events'} || [] });
		$reason .= " [$events]" if length $events;
		return { %$json, engine => 'webkit', error => "probe failed: $reason" };
	}
	return $json;
}

1;
