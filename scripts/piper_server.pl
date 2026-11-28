#!/usr/bin/perl
# A resident, demand-started Piper voice for spoken replies.
#
# piper the CLI loads its voice model on every invocation: a short reply pays
# that load again each time (about 3 s on an ARM homebase; ~0.5 s of model load
# on a desktop). This daemon starts once, keeps one piper process - so the model
# is loaded once - and answers POST /render with 8 kHz mono s16le PCM, exactly
# what the reply paths already stream.
#
# It is loopback-only, started by demand (President's 'piper server' loop, or a
# say.warm Crew job on a peer), and stops itself after ten quiet minutes or a
# hard maximum age, so a machine that stops talking pays nothing. A machine with
# no piper never starts it: the caller checks the binary and the model first.
#
#   perl scripts/piper_server.pl --piper BIN --model FILE --port 8179 \
#        [--runner BIN] [--espeak-data DIR] [--idle 600] [--max-age 3600] \
#        [--timeout 30] [--log FILE]
#
#   GET  /health   -> {"ok":1,"pid":...,"model":...,"port":...,"started":...}
#   POST /render   -> 8 kHz mono s16le PCM (body is UTF-8 text)
#   POST /shutdown -> stop after replying
#
# The protocol with piper is the CLI's own: one text line in, a WAV written into
# the spool. The output path is not a reliable signal - the C++ bundle prints it
# on stdout, while the Python wheel logs "Wrote ..." on stderr and buffers it
# when stderr is a pipe - so the new file in the spool is the signal. One line in
# and one file out keeps requests in lockstep, and the process keeps the model.
use strict;
use warnings;

use File::Spec ();
use File::Temp qw(tempdir);
use Getopt::Long qw(GetOptions);
use IO::Select;
use IO::Socket::INET;
use IPC::Open3;
use JSON::PP qw(encode_json);
use POSIX ();
use Symbol qw(gensym);
use Time::HiRes qw(time);

my %opt = (
	port    => 8179,
	idle    => 600,
	max_age => 3600,
	timeout => 30,
	log     => '',
);

GetOptions(\%opt,
	'piper=s', 'runner=s', 'model=s', 'espeak-data=s',
	'port=i', 'idle=i', 'max-age=i', 'timeout=i', 'log=s',
) or usage(2);

usage(2) unless defined $opt{'piper'} && length $opt{'piper'} && -x $opt{'piper'};
usage(2) unless defined $opt{'model'} && length $opt{'model'};

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
usage: piper_server.pl --piper BIN --model FILE [--runner BIN]
       [--espeak-data DIR] [--port 8179] [--idle 600] [--max-age 3600]
       [--timeout 30] [--log FILE]
USAGE
	exit $code;
}

my $logfh;
if (length $opt{'log'}) {
	open($logfh, '>>', $opt{'log'}) or undef $logfh;
}
sub saylog {
	return unless $logfh;
	my $line = join('', map { defined $_ ? $_ : '' } @_);
	$line =~ s/\s+$//;
	print {$logfh} '[' . scalar(POSIX::strftime('%Y-%m-%d %H:%M:%S', localtime)) . '] '
		. $line . "\n";
	$logfh->flush;
}

my $port    = $opt{'port'};
my $model   = $opt{'model'};
my $started = time;
my $spool   = tempdir('piper-warm-XXXXXX', TMPDIR => 1, CLEANUP => 1);

my @piper_argv = ();
push @piper_argv, $opt{'runner'} if defined $opt{'runner'} && length $opt{'runner'};
push @piper_argv, $opt{'piper'};
push @piper_argv, ('--espeak_data', $opt{'espeak-data'})
	if defined $opt{'espeak-data'} && length $opt{'espeak-data'};
push @piper_argv, ('-m', $model, '-d', $spool);

# Piper's own log is noise here; keep it beside ours when we have one, and
# discard it otherwise. It must never be a pipe nobody reads: a full stderr
# pipe would wedge the synthesis.
my $errfh;
if ($logfh) {
	open($errfh, '>>&', $logfh) or undef $errfh;
}
if (!$errfh) {
	open($errfh, '>', File::Spec->devnull) or undef $errfh;
}

# Bind the port BEFORE loading the model. The demand loop and a say.warm can
# both ask for a server at the same moment; the loser then exits here without
# paying a second piper start (which is exactly the model load we are avoiding).
my $listen = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1',
	LocalPort => $port,
	Proto     => 'tcp',
	Listen    => 8,
	ReuseAddr => 1,
);
unless ($listen) {
	saylog("could not listen on 127.0.0.1:$port: $!");
	exit 1;
}

my ($pin, $pout);
my $piper_pid = eval {
	IPC::Open3::open3($pin, $pout, $errfh, @piper_argv);
};
# Do not close $errfh here: piper writes its startup log to stderr immediately,
# and closing the parent's copy made the child die on SIGPIPE before it ever
# waited for a line (measured). The handle costs one fd for the daemon's life.
unless ($piper_pid) {
	saylog('piper did not start: ' . ($@ || 'no pid'));
	close($listen);
	exit 1;
}
binmode($pin);
binmode($pout);
$pin->autoflush(1);

# A client that hangs up mid-response must not take the daemon with it.
local $SIG{'PIPE'} = 'IGNORE';
my $stop = 0;
local $SIG{'TERM'} = sub { $stop = 1 };
local $SIG{'INT'}  = sub { $stop = 1 };

saylog("started pid=$$ port=$port model=$model piper=$piper_pid");

my $last_use = time;
sub _write_all {
	my ($sock, $bytes) = @_;
	my $off = 0;
	while ($off < length $bytes) {
		my $n = syswrite($sock, $bytes, length($bytes) - $off, $off);
		return 0 unless defined $n && $n > 0;
		$off += $n;
	}
	return 1;
}

sub _respond {
	my ($sock, $code, $type, $body, %extra) = @_;
	$body = '' unless defined $body;
	my %reason = (200 => 'OK', 400 => 'Bad Request', 404 => 'Not Found',
		405 => 'Method Not Allowed', 411 => 'Length Required', 503 => 'Service Unavailable');
	my $head = 'HTTP/1.1 ' . $code . ' ' . ($reason{$code} || 'Response') . "\r\n"
		. 'Content-Type: ' . $type . "\r\n"
		. 'Content-Length: ' . length($body) . "\r\n"
		. "Connection: close\r\n";
	foreach my $key (sort keys %extra) {
		$head .= $key . ': ' . $extra{$key} . "\r\n";
	}
	_write_all($sock, $head . "\r\n" . $body);
}

# A minimal request: the client is this tree's own loopback call, so one request
# per connection with Content-Length framing is all that has to work.
sub _read_request {
	my ($sock) = @_;
	my $sel = IO::Select->new($sock);
	my $buf = '';
	my $deadline = time + 5;
	until ($buf =~ /\r?\n\r?\n/) {
		my $left = $deadline - time;
		return undef if $left <= 0;
		return undef unless $sel->can_read($left);
		my $n = sysread($sock, my $chunk, 8192);
		return undef unless defined $n && $n > 0;
		$buf .= $chunk;
		return undef if length($buf) > 65536;
	}
	my ($head, $rest) = split(/\r?\n\r?\n/, $buf, 2);
	my @lines = split(/\r?\n/, $head);
	my $request = shift(@lines) // '';
	my ($method, $path) = $request =~ m{^(\S+)\s+(\S+)};
	return undef unless defined $method && defined $path;
	my %h;
	foreach my $line (@lines) {
		my ($k, $v) = $line =~ /^([^:]+):\s*(.*)$/ or next;
		$h{lc $k} = $v;
	}
	my $len = defined $h{'content-length'} ? $h{'content-length'} + 0 : 0;
	return undef if $len < 0 || $len > 4_000_000;
	$rest = '' unless defined $rest;
	my $body_deadline = time + 10;
	while (length($rest) < $len) {
		my $left = $body_deadline - time;
		return undef if $left <= 0;
		return undef unless $sel->can_read($left);
		my $n = sysread($sock, my $chunk, 65536);
		return undef unless defined $n && $n > 0;
		$rest .= $chunk;
	}
	$rest = substr($rest, 0, $len);
	return ($method, $path, $rest);
}

sub _pcm_8k {
	my ($wav) = @_;
	open(my $fh, '-|', 'ffmpeg', '-nostdin', '-loglevel', 'error',
		'-i', $wav, '-f', 's16le', '-ar', '8000', '-ac', '1', '-')
		or return undef;
	binmode($fh);
	my $pcm = do { local $/; <$fh> // '' };
	my $ok = close($fh);
	return (($ok && length $pcm) ? $pcm : undef);
}

# One text line in; the new WAV in the spool is the signal that the sentence is
# done (the file's size settles). Undef means piper did not answer in time; the
# caller stops the daemon so the demand loop starts a fresh one rather than
# serving failures.
sub _synthesize {
	my ($text) = @_;
	return undef unless defined $text && length $text;
	$text =~ s/[\r\n]+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return undef unless length $text;
	return undef if length($text) > 4000;
	my %before = map { $_ => 1 } glob("$spool/*.wav");
	my $wrote = eval {
		print {$pin} $text . "\n";
		1;
	};
	return undef unless $wrote;
	my $deadline = time + $opt{'timeout'};
	my $sel = IO::Select->new($pout);
	my ($path, $last_size, $stable_at) = ('', -1, 0);
	while (time < $deadline) {
		# Drain stdout: the C++ bundle prints the path there, the Python wheel
		# does not. It is discarded either way; the file is the signal, so an
		# unread pipe can never fill and wedge the synthesis.
		while ($sel->can_read(0)) {
			my $n = sysread($pout, my $buf, 65536);
			last unless defined $n && $n > 0;
		}
		if (!length $path) {
			foreach my $candidate (glob("$spool/*.wav")) {
				next if $before{$candidate};
				$path = $candidate;
				last;
			}
		}
		if (length $path) {
			my $size = -s $path || 0;
			if ($size > 44) {
				if ($size == $last_size) {
					last if $stable_at && time - $stable_at >= 0.1;
					$stable_at = time unless $stable_at;
				}
				else {
					$last_size = $size;
					$stable_at = 0;
				}
			}
		}
		select(undef, undef, undef, 0.02);
	}
	return undef unless length $path && -f $path;
	my $pcm = _pcm_8k($path);
	unlink $path;
	return $pcm;
}

sub _handle_client {
	my ($sock) = @_;
	my ($method, $path, $body) = _read_request($sock);
	unless (defined $method) {
		close($sock);
		return;
	}
	$path =~ s/\?.*//;
	$path = '/' unless defined $path && length $path;
	if ($method eq 'GET' && $path eq '/health') {
		_respond($sock, 200, 'application/json', encode_json({
			ok      => 1,
			pid     => $$,
			piper   => $piper_pid,
			model   => $model,
			port    => $port,
			started => int($started),
		}));
	}
	elsif ($path eq '/shutdown' && ($method eq 'GET' || $method eq 'POST')) {
		_respond($sock, 200, 'text/plain', "bye\n");
		$stop = 1;
	}
	elsif ($method eq 'POST' && $path eq '/render') {
		if (!defined $body || !length $body) {
			_respond($sock, 400, 'text/plain', "render needs text\n");
		}
		else {
			my $t0 = time;
			my $pcm = _synthesize($body);
			if (defined $pcm && length $pcm) {
				_respond($sock, 200, 'application/octet-stream', $pcm,
					'X-Piper-Model' => $model);
				$last_use = time;
				saylog(sprintf('render %d bytes in %dms', length($pcm), (time - $t0) * 1000));
			}
			else {
				saylog('render failed: piper produced nothing');
				_respond($sock, 503, 'text/plain', "piper produced nothing\n");
				$stop = 1;
			}
		}
	}
	elsif ($method eq 'GET' || $method eq 'POST') {
		_respond($sock, 404, 'text/plain', "unknown path\n");
	}
	else {
		_respond($sock, 405, 'text/plain', "only GET and POST\n");
	}
	close($sock);
}

# The accept loop also owns the daemon's life: a second of sleep between looks
# is enough to notice an idle minute, a hard-age limit, or a piper that died.
while (!$stop) {
	my $reaped = waitpid($piper_pid, POSIX::WNOHANG());
	if ($reaped == $piper_pid) {
		saylog('piper exited on its own');
		$piper_pid = 0;
		last;
	}
	if (time - $last_use > $opt{'idle'}) {
		saylog('stopping after ' . $opt{'idle'} . 's idle');
		last;
	}
	if ($opt{'max_age'} && time - $started > $opt{'max_age'}) {
		saylog('stopping at the hard maximum age');
		last;
	}
	my $sel = IO::Select->new($listen);
	next unless $sel->can_read(1);
	my $client = $listen->accept();
	next unless $client;
	_handle_client($client);
}

close($listen);

if ($piper_pid) {
	kill 'TERM', $piper_pid;
	my $gone = 0;
	for (1 .. 30) {
		$gone = 1 if waitpid($piper_pid, POSIX::WNOHANG()) != 0;
		last if $gone;
		select(undef, undef, undef, 0.1);
	}
	if (!$gone) {
		kill 'KILL', $piper_pid;
		waitpid($piper_pid, 0);
	}
}

saylog('stopped');
exit 0;
