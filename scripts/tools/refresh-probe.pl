#!/usr/bin/env perl
# refresh-probe - catch a WebUI page reload and say what caused it.
#
# Answers: Why did the WebUI reload, and which device did it on? The browser
#          half (public/js/probe/refresh-probe.js) posts hide/wake/socket/reload
#          events to this collector; this half tails the manager log and
#          fingerprints the code tree beside them, then reports per device.
# Usage:   perl scripts/tools/refresh-probe.pl [--port N] [--listen ADDR]
#              [--cert FILE --key FILE] [--out FILE] [--hours N] [--pid FILE]
#          perl scripts/tools/refresh-probe.pl --report [--last 24h]
#              [--browser dump.json] [--watch SECONDS]
# Example: perl scripts/tools/refresh-probe.pl --listen '*' --port 45997 \
#              --cert server/fullchain.pem --key server/privkey.pem --hours 24
# Reads:   ~/manager.log, the code tree; with --browser, that file.
# Writes:  the --out JSONL (default ~/.refresh-probe/events.jsonl) and its
#          rotations; --pid writes the daemon's pid. Nothing in the tree.
#
# The browser half is served by the app at /js/probe/refresh-probe.js and the
# manager layout includes it only when the browser carries the jawnos_probe
# cookie (or asks for ?probe=1 once). That is what lets it survive a reload: a
# pasted console snippet does not. Install once per device:
#
#   /manager?probe=1&probe_device=phone
#          &probe_endpoint=https%3A%2F%2Fdev.example.com%3A45997%2Fevent
#
# A page on https cannot beacon to plain-http (mixed content), so the collector
# presents the app's own certificate and the endpoint is the host the browser
# already trusts. `?probe=0` removes the probe from that browser.
#
# A page that cannot reach the collector still keeps its last events in
# localStorage; the next page_load carries them in prev_events, so a miss is
# recovered rather than lost.
use strict;
use warnings;
use Mojolicious::Lite;
use JSON::PP;
use Getopt::Long qw(GetOptionsFromArray);
use Time::HiRes qw(time);
use Time::Local qw(timegm);
use File::Find qw(find);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Path qw(make_path);
use POSIX qw(strftime);

my %o = (
	port          => 45997,
	listen        => '127.0.0.1',
	cert          => '',
	key           => '',
	log           => (($ENV{HOME} || '.') . '/manager.log'),
	out           => (($ENV{HOME} || '.') . '/.refresh-probe/events.jsonl'),
	tree          => (($ENV{HOME} || '.') . '/jawnos'),
	tree_interval => 60,
	hours         => 0,
	pid           => '',
	max_mb        => 32,
	keep          => 4,
	browser       => '',
	report        => 0,
	watch         => 0,
	last          => '',
	since         => 0,
	until         => 0,
	quiet         => 0,
);
GetOptionsFromArray(\@ARGV, \%o,
	'port=i', 'listen=s', 'cert=s', 'key=s', 'log=s', 'out=s', 'tree=s',
	'tree-interval=i', 'hours=f', 'pid=s', 'max-mb=i', 'keep=i',
	'browser=s', 'report', 'watch=i', 'last=s', 'since=i',
	'until=i', 'quiet')
	or die "usage: $0 [--port N] [--listen ADDR] [--cert FILE --key FILE] "
	. "[--out FILE] [--hours H] [--pid FILE] | --report [--last 24h] [--browser FILE] [--watch S]\n";
@ARGV = ();

die "refresh-probe: --cert and --key go together\n"
	if (length($o{cert}) ? !length($o{key}) : length($o{key}));
die "refresh-probe: --listen '*' needs --cert and --key, or the page's https cannot reach it\n"
	if $o{listen} ne '127.0.0.1' && $o{listen} ne 'localhost' && !length $o{cert};
# The TLS listener resolves the pair from the server's own cwd, not ours.
foreach my $k (qw(cert key)) {
	next unless length $o{$k};
	my $abs = abs_path($o{$k});
	die "refresh-probe: $o{$k}: $!\n" unless defined $abs;
	$o{$k} = $abs;
}

my @KIND = (
	[qr/session gate:/                  => 'session_gate'],
	[qr/BLE listener closed/                => 'ble_listener_closed'],
	[qr/BLE listener (?:error|held)/        => 'ble_listener_error'],
	[qr/worker spawn/                       => 'worker_spawn'],
	[qr/sync pull/                          => 'sync_pull'],
	[qr/remote sync:/                       => 'remote_sync'],
	[qr/\[error\]/                          => 'log_error'],
	[qr/\[warn\]/                           => 'log_warn'],
	[qr/revision|code sync|git sync/i       => 'revision'],
	[qr/restart|shutting down|watchdog|starting .* server/i => 'restart'],
);

sub classify {
	my ($line) = @_;
	foreach my $k (@KIND) {
		return $k->[1] if $line =~ $k->[0];
	}
	return undef;
}

sub time_ms { return int(time() * 1000) }

sub parse_span {
	my ($s) = @_;
	return 0 unless defined $s && $s =~ /^\s*(\d+(?:\.\d+)?)\s*([smhd]?)\s*$/i;
	my ($n, $u) = ($1, lc($2 || 's'));
	my %mult = (s => 1, m => 60, h => 3600, d => 86400);
	return int($n * $mult{$u});
}

my $READING = 0;
sub append {
	my ($rec) = @_;
	$rec->{'t'} = time_ms() unless defined $rec->{'t'};
	make_path(dirname($o{'out'})) unless -d dirname($o{'out'});
	if ($o{'max_mb'} > 0 && -s $o{'out'} && (stat(_))[7] > $o{'max_mb'} * 1024 * 1024) {
		my $last = "$o{out}.$o{keep}";
		unlink $last if -e $last;
		for (my $i = $o{'keep'} - 1; $i >= 1; $i--) {
			rename "$o{out}.$i", "$o{out}." . ($i + 1) if -e "$o{out}.$i";
		}
		rename $o{'out'}, "$o{out}.1";
	}
	open(my $fh, '>>', $o{'out'}) or die "$o{out}: $!";
	flock($fh, 2);
	print {$fh} JSON::PP->new->canonical->encode($rec), "\n";
	flock($fh, 8);
	close $fh;
	print STDERR strftime('%H:%M:%S', localtime), " "
		. ($rec->{'device'} ? "[$rec->{device}] " : '')
		. "$rec->{'src'} $rec->{'ev'}"
		. (defined $rec->{'kind'} ? " $rec->{'kind'}" : '') . "\n" unless $o{'quiet'};
}

# ---- the report ------------------------------------------------------------
sub load_rows {
	my @files = ($o{'out'});
	push @files, map { "$o{out}.$_" } 1 .. $o{'keep'} if $o{'keep'} > 0;
	my @rows;
	foreach my $file (@files) {
		next unless -r $file;
		open(my $fh, '<', $file) or next;
		while (defined(my $line = <$fh>)) {
			chomp $line;
			next unless length $line;
			my $e = eval { JSON::PP->new->decode($line) };
			push @rows, $e if $e && ref $e eq 'HASH' && defined $e->{'t'};
		}
		close $fh;
	}
	return @rows;
}

sub load_browser_dump {
	my ($file) = @_;
	return () unless length($file || '') && -r $file;
	local $/;
	open(my $fh, '<', $file) or return ();
	my $raw = <$fh>;
	close $fh;
	my $arr = eval { JSON::PP->new->decode($raw) };
	return () unless $arr && ref $arr eq 'ARRAY';
	return grep { ref $_ eq 'HASH' && defined $_->{'t'} } @{$arr};
}

# The manager log is the server half. Reading it at report time means the
# capture does not depend on the collector having tailed every line live.
sub load_server_rows {
	my ($from, $to) = @_;
	return () unless -r $o{'log'};
	open(my $fh, '<', $o{'log'}) or return ();
	my %seen;
	my @rows;
	while (defined(my $line = <$fh>)) {
		next unless $line =~ /^\[(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)\]/;
		my $kind = classify($line) or next;
		my $t = timegm($6, $5, $4, $3, $2 - 1, $1) * 1000
			+ int(substr($7 . '000', 0, 3));
		next if $t < $from || $t > $to;
		next if $seen{$kind . ':' . int($t / 1000)}++;
		push @rows, { t => $t, src => 'perl', ev => 'log', kind => $kind,
			text => substr($line, 0, 220) };
	}
	close $fh;
	return @rows;
}

sub in_window {
	my ($r, $from, $to) = @_;
	return $r->{'t'} >= $from && $r->{'t'} <= $to;
}

sub fmt_t {
	my ($t) = @_;
	return '?' unless defined $t;
	return strftime('%Y-%m-%d %H:%M:%S', localtime($t / 1000));
}

sub gap_text {
	my ($ms) = @_;
	return '?' unless defined $ms;
	$ms = int($ms / 1000);
	return "${ms}s" if $ms < 120;
	my $m = int($ms / 60);
	return "${m}m " . ($ms % 60) . 's' if $m < 120;
	my $h = int($m / 60);
	return "${h}h " . ($m % 60) . 'm';
}

sub preceding {
	my ($rows, $i, $ms) = @_;
	return () if $i <= 0;
	my @before = grep { $_->{'t'} >= $rows->[$i]{'t'} - $ms }
		@{$rows}[0 .. $i - 1];
	@before = @before[-10 .. -1] if @before > 10;
	return @before;
}

sub run_report {
	my (%arg) = @_;
	my $now = time_ms();
	my $from = $o{'since'} ? $o{'since'} * 1000
		: $o{'last'} ? $now - parse_span($o{'last'}) * 1000 : 0;
	my $to = $o{'until'} ? $o{'until'} * 1000 : $now + 86400000;

	my @rows = load_rows();
	push @rows, load_browser_dump($o{'browser'});
	my @browser = grep { in_window($_, $from, $to) } @rows;
	my @server = $arg{'compact'} ? () : load_server_rows($from, $to);
	# The live collector already stamped the lines it tailed; do not count the
	# same server line twice when the report also reads the log.
	my %have = map { ($_->{'kind'} || '') . ':' . int($_->{'t'} / 1000) => 1 }
		grep { ($_->{'src'} || '') eq 'perl' && ($_->{'kind'} || '') } @browser;
	@server = grep { !$have{($_->{'kind'} || '') . ':' . int($_->{'t'} / 1000)} } @server;
	push @browser, @server;

	unless (@browser) {
		die "refresh-probe: no events (looked at $o{out} and rotations"
			. (length $o{browser} ? ", $o{browser}" : '') . ")\n";
	}
	@browser = sort { $a->{'t'} <=> $b->{'t'} } @browser;

	if ($arg{'compact'}) {
		my %dev;
		foreach my $r (@browser) {
			next unless ($r->{'src'} || '') eq 'browser';
			my $d = $r->{'device'} || 'unlabeled';
			$dev{$d}{'events'}++;
			$dev{$d}{'reloads'}++ if ($r->{'ev'} || '') eq 'page_load' && ($r->{'nav'} || '') eq 'reload';
			$dev{$d}{'loads'}++   if ($r->{'ev'} || '') eq 'page_load';
			$dev{$d}{'beats'}++   if ($r->{'ev'} || '') eq 'heartbeat';
			$dev{$d}{'last'} = $r->{'t'};
		}
		print "refresh-probe ", fmt_t($now), "  (", scalar(@browser), " events, "
			. ($o{'last'} ? "last $o{last}" : 'all') . ")\n";
		foreach my $d (sort keys %dev) {
			my $v = $dev{$d};
			my $age = defined $v->{'last'} ? gap_text($now - $v->{'last'}) : 'never';
			printf "  %-10s reloads=%-4d loads=%-4d beats=%-5d last=%s\n",
				$d, $v->{'reloads'} || 0, $v->{'loads'} || 0, $v->{'beats'} || 0, $age;
		}
		my %kind;
		$kind{ $_->{'kind'} }++ foreach grep { ($_->{'src'} || '') eq 'perl' && $_->{'kind'} } @browser;
		print "  server: ", (join ' ', map { "$_=$kind{$_}" } sort keys %kind) || 'none', "\n" if %kind;
		return;
	}

	my %dev;
	my @perl = grep { ($_->{'src'} || '') ne 'browser' } @browser;
	foreach my $r (grep { ($_->{'src'} || '') eq 'browser' } @browser) {
		push @{ $dev{$r->{'device'} || 'unlabeled'} }, $r;
	}
	my %by;
	foreach my $r (@browser) {
		my $key = ($r->{'device'} ? "$r->{device}/" : '') . ($r->{'src'} || '?') . ':' . ($r->{'ev'} || '?');
		$by{$key}++;
	}

	print "refresh-probe report over ", scalar(@browser), " events\n";
	print "  window: ", fmt_t($browser[0]{'t'}), " .. ", fmt_t($browser[-1]{'t'}), "\n";
	print "  devices: ", join(' ', map { "$_=" . scalar(@{ $dev{$_} }) } sort keys %dev), "\n" if %dev;
	print "  events:\n";
	print "    $_ = $by{$_}\n" foreach sort { $by{$b} <=> $by{$a} } keys %by;

	foreach my $d (sort keys %dev) {
		my @r = @{ $dev{$d} };
		my @loads = grep { ($_->{'ev'} || '') eq 'page_load' } @r;
		my @reloads = grep { ($_->{'ev'} || '') eq 'page_load' && ($_->{'nav'} || '') eq 'reload' } @r;
		my @beats = grep { ($_->{'ev'} || '') eq 'heartbeat' } @r;
		my $ua = '';
		foreach my $l (@loads) { if ($l->{'ua'}) { $ua = $l->{'ua'}; last; } }
		$ua =~ s/^Mozilla\/5\.0\s*//;
		print "\n$d", (length $ua ? " ($ua)" : ''), "\n";
		print "  loads:", (join ' ', map {
			my $n = $_;
			$n =~ s/[^a-z_]//g;
			my $c = grep { ($_->{'nav'} || '') eq $n } @loads;
			" $n=$c";
		} sort keys %{ { map { ($_->{'nav'} || 'navigate') => 1 } @loads } }), "\n";
		printf "  reloads=%d heartbeats=%d\n", scalar(@reloads), scalar(@beats);
		if (@beats > 1) {
			my $largest = 0;
			for my $i (1 .. $#beats) {
				my $gap = $beats[$i]{'t'} - $beats[$i - 1]{'t'};
				$largest = $gap if $gap > $largest;
			}
			print "  largest heartbeat gap: ", gap_text($largest),
				" (a hidden tab throttles these; a dead probe shows the same)\n"
				if $largest > 150000;
		}
		my $n = 0;
		for my $i (0 .. $#r) {
			my $x = $r[$i];
			next unless ($x->{'ev'} || '') eq 'page_load' && ($x->{'nav'} || '') eq 'reload';
			$n++;
			my @before = preceding(\@r, $i, 15000);
			my %cause;
			foreach my $b (@before) {
				my $ev = $b->{'ev'} || '';
				$cause{'revision'}++ if $ev eq 'call:jawnosRevisionArrived';
				$cause{'update'}++   if $ev eq 'call:jawnosUpdateQuietReload'
					|| $ev eq 'call:jawnosReloadWhenReady';
				$cause{'socket'}++   if $ev eq 'ws_close' || $ev eq 'ws_error';
				$cause{'hidden'}++   if $ev eq 'hidden';
				$cause{'unload'}++   if $ev eq 'beforeunload' || $ev eq 'pagehide';
			}
			printf "  reload #%d at %s gap=%s auto=%s", $n, fmt_t($x->{'t'}),
				(defined $x->{'since_prev_ms'} ? gap_text($x->{'since_prev_ms'}) : '?'),
				(defined $x->{'autoreload'} ? $x->{'autoreload'} : '?');
			print "  cause: ", join(',', sort keys %cause) if %cause;
			print "\n";
			foreach my $b (@before) {
				printf "    -%5.1fs %s %s%s\n", ($x->{'t'} - $b->{'t'}) / 1000,
					($b->{'src'} || '?'), ($b->{'ev'} || '?'),
					(defined $b->{'kind'} ? " ($b->{'kind'})" : '');
			}
			my @near = grep { $_->{'kind'} && abs($_->{'t'} - $x->{'t'}) <= 15000 } @perl;
			foreach my $s (@near) {
				printf "    server %+5.1fs %s\n", ($s->{'t'} - $x->{'t'}) / 1000, $s->{'kind'};
			}
			if ($x->{'prev_events'} && ref $x->{'prev_events'} eq 'ARRAY') {
				print "    browser remembered (older session):\n";
				foreach my $p (@{ $x->{'prev_events'} }) {
					printf "      %s %s\n",
						($p->{'t'} ? strftime('%H:%M:%S', localtime($p->{'t'} / 1000)) : '?'),
						($p->{'ev'} || '?');
				}
			}
		}
		print "  no page reloads for $d\n" unless $n;
	}

	my @server_kinds = grep { $_->{'kind'} } @perl;
	if (@server_kinds) {
		print "\nserver events in the window:\n";
		my %count;
		$count{ $_->{'kind'} }++ foreach @server_kinds;
		print "  ", join(' ', map { "$_=$count{$_}" } sort keys %count), "\n";
		foreach my $s (@server_kinds) {
			next unless $s->{'kind'} =~ /^(?:restart|revision|log_error|session_gate)$/;
			printf "  %s %s %s\n", fmt_t($s->{'t'}), $s->{'kind'},
				substr($s->{'text'} || '', 0, 140);
		}
	}
	print "\nno page reloads in the capture\n"
		unless grep { ($_->{'ev'} || '') eq 'page_load' && ($_->{'nav'} || '') eq 'reload' } @browser;
}

if ($o{'report'} || $o{'watch'}) {
	$o{'report'} = 1;
	my $span = $o{'last'} ? " (last $o{last})" : '';
	while (1) {
		if ($o{'watch'}) {
			print "\e[H\e[2J" if -t STDOUT;
			eval { run_report(compact => 1) };
			print "  waiting for the first event: $@" if $@;
			print "  (every ${o{watch}}s; Ctrl-C to stop)\n";
			sleep $o{'watch'};
		} else {
			run_report();
			last;
		}
	}
	exit 0;
}

# ---- collector -------------------------------------------------------------
make_path(dirname($o{'out'})) unless -d dirname($o{'out'});

post '/event' => sub {
	my $c = shift;
	my $raw = $c->req->body || '';
	# A listener on the LAN is not a private mailbox: bound the record and the
	# file (rotation below), so a broken page cannot fill the disk.
	return $c->rendered(413) if length $raw > 16384;
	my $rec = length $raw ? eval { JSON::PP->new->decode($raw) } : undef;
	if ($rec && ref $rec eq 'HASH') {
		$rec->{'recv'} = time_ms();
		$rec->{'src'} ||= 'browser';
		$rec->{'device'} = substr($rec->{'device'}, 0, 40)
			if defined $rec->{'device'} && !ref $rec->{'device'};
		append($rec);
	}
	$c->rendered(204);
};
get '/' => { text => "refresh-probe collecting to $o{out}\n" };

my $TAIL;
open($TAIL, '<', $o{'log'}) or die "$o{log}: $!";
my @tail_st = stat($TAIL);
my ($TAIL_INO, $TAIL_POS) = @tail_st[1, 7];
seek($TAIL, 0, 2);

my %seen;
app->log->level('error');
Mojo::IOLoop->recurring(0.5 => sub {
	my @st = stat($o{'log'});
	if (!@st || $st[1] != $TAIL_INO || $st[7] < $TAIL_POS) {
		close($TAIL);
		return unless open($TAIL, '<', $o{'log'});
		@tail_st = stat($TAIL);
		($TAIL_INO, $TAIL_POS) = @tail_st[1, 7];
		$TAIL_POS = 0;
	}
	# A buffered handle that ever saw EOF keeps the flag when the file grows:
	# the next readline returns undef until a no-op seek clears it. Without
	# this the tail sat at the old end for a whole 24h run (2026-11-14).
	seek($TAIL, 0, 1);
	while (defined(my $line = <$TAIL>)) {
		$TAIL_POS = tell($TAIL);
		my $kind = classify($line) or next;
		$seen{$kind}++;
		# a flood would bury the reload: keep a sample of the chatty kinds
		next if $kind =~ /^(?:ble_listener_closed|worker_spawn)$/ && $seen{$kind} % 25 != 1;
		append({ src => 'perl', ev => 'log', kind => $kind, text => substr($line, 0, 220) });
	}
});

my $TREE_AT = 0;
Mojo::IOLoop->recurring($o{'tree_interval'} => sub {
	my ($newest, $name) = (0, '');
	find({ no_chdir => 1, wanted => sub {
		my $path = $File::Find::name;
		return unless -f $path;
		return if $path =~ /\.(?:db|db-wal|db-shm|log|pyc)$/;
		my $m = (stat($path))[9] || 0;
		if ($m > $newest) { ($newest, $name) = ($m, $path); }
	} }, map { "$o{tree}/$_" } grep { -d "$o{tree}/$_" } qw(lib perl templates public/js));
	return unless $newest && $newest != $TREE_AT;
	$TREE_AT = $newest;
	(my $rel = $name) =~ s{^\Q$o{tree}\E/}{};
	append({ src => 'perl', ev => 'tree_changed', file => $rel, at => $newest });
});

my $stop_at = $o{'hours'} > 0 ? time() + $o{'hours'} * 3600 : 0;
Mojo::IOLoop->recurring(1 => sub {
	return unless $stop_at && time() >= $stop_at;
	append({ src => 'perl', ev => 'stop', reason => 'hours' });
	unlink $o{'pid'} if length $o{'pid'};
	Mojo::IOLoop->stop;
	exit 0;
});

if (length $o{'pid'}) {
	Mojo::IOLoop->timer(0.2 => sub {
		open(my $ph, '>', $o{'pid'}) or return;
		print {$ph} "$$\n";
		close $ph;
	});
	$SIG{TERM} = $SIG{INT} = sub {
		unlink $o{'pid'};
		Mojo::IOLoop->stop;
		exit 0;
	};
}

my $scheme = length($o{'cert'}) ? 'https' : 'http';
my $url = "$scheme://$o{listen}:$o{port}";
$url .= "?cert=$o{cert}&key=$o{key}" if length $o{'cert'};

print "refresh-probe: listening on $scheme://$o{listen}:$o{port}/event -> $o{out}\n";
print "  tailing $o{log}; watching $o{tree}; device endpoints must use this host name\n";
print "  stopping after $o{hours}h; pid -> $o{pid}\n" if $o{'hours'} > 0;
# `daemon` is Mojolicious' standalone server name, not a detach: this process
# stays in the foreground (run it under nohup/tmux for a long capture, and
# --hours ends it).
app->start('daemon', '-l', $url);
