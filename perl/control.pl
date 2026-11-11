package control;

# The master's control socket, and the record every restart leaves behind.
#
# Until now a restart was a word written into ~/.president/status: no verdict, no
# reason kept, and a refusal indistinguishable from a slow restart (the guard
# silently rewrote "good"). This module is the other half - ~/.president/control
# answers one JSON line with one JSON line, so a caller learns what happened and
# why, and every restart writes ~/.president/restart.json (the last one) plus
# restart.log (all of them) naming its reason, who asked, and what the guard said.
#
# It is deliberately a plain module with no Mojo::IOLoop in it: ./jawn wires the
# socket, scripts/restart.pl is the client, and t/57-control-socket.t drives both
# ends without a master. The protocol is one request object in, one reply object
# out:
#
#   {"cmd":"restart","reason":"v0.1.1734 - the fix","source":"agent"}
#   {"cmd":"status"}
#   {"cmd":"verify"}
#
# A restart is answered by the master after its guard has run, so the reply is
# the verdict, not an acknowledgement:
#
#   {"ok":1,"cmd":"restart","accepted":1,"verified":1,"reason":"...","verify":"744 file(s) pass"}
#   {"ok":0,"cmd":"restart","accepted":0,"refused":"verify","report":"FAIL perl/..."}

use strict;
use warnings;

BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../lib" if $dir && -d "$dir/../lib";
}
use JawnOS::Transport;
use File::Path ();
use IO::Select;
use Mojo::JSON qw(decode_json encode_json);
use Time::HiRes qw(time);

# A reason travels into a log line and a socket frame, so it is one line whatever
# was handed in - a pasted stack trace must not become the protocol.
sub clean_text {
	my ($text, $max) = @_;
	$text = '' if !defined $text || ref $text;
	$text =~ s/[\x00-\x1f\x7f]+/ /g;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	$max ||= 400;
	$text = substr($text, 0, $max) . '...' if length $text > $max;
	return $text;
}

sub _president_dir {
	my %opt = @_;
	return $opt{'dir'} if defined $opt{'dir'} && length $opt{'dir'};
	my $home = JawnOS::Platform::home();
	$home =~ s{/+$}{};
	return length $home ? "$home/.president" : '.president';
}

sub socket_path { my %opt = @_; return &_president_dir(%opt) . '/control' }
sub record_file { my %opt = @_; return &_president_dir(%opt) . '/restart.json' }
sub log_file    { my %opt = @_; return &_president_dir(%opt) . '/restart.log' }
# The old channel, and the one file that survives a master that cannot answer:
# ./jawn reads it every second, President.pl writes it at boot.
sub status_file { my %opt = @_; return &_president_dir(%opt) . '/status' }

# Does the last recorded restart already boot the tree now on disk? A request is
# redundant when it does, and every caller that moves the tree and then asks in
# a second step can race itself that way: the git watcher fast-forwards, then
# installs extras, Perl modules and system packages before it asks, and a
# landing's own restart can be accepted and booted inside that gap. Honouring
# the late request then stops and boots the same tree again - the double restart
# a connected tab follows as two reconnects. `$since` is when the caller's pass
# began (an epoch second): a record older than that booted a tree this pass has
# not moved yet, so it cannot cover the move.
sub restart_covers {
	my ($record, $version, $since) = @_;
	return 0 unless ref $record eq 'HASH';
	return 0 unless $record->{'ok'};
	return 0 unless defined $version && length $version;
	return 0 unless defined $record->{'version'} && $record->{'version'} eq $version;
	return 0 unless defined $record->{'epoch'} && $record->{'epoch'} >= ($since || 0);
	return 1;
}

# The status file has said exactly "restart" since the beginning, so that keeps
# working; anything after a colon (or a dash) is the reason the caller gave, and
# it travels into the record. Returns (is_restart, reason).
sub status_reason {
	my $text = shift;
	$text = '' unless defined $text;
	$text =~ s/^\s+|\s+$//g;
	return (0, '') unless $text =~ /^restart\b/i;
	(my $reason = $text) =~ s{^restart\b[:\s-]*}{}i;
	return (1, &clean_text($reason, 400));
}

# A request line in, a decision out:
#   { reply => {...} }                                    answer now
#   { action => 'restart', reason => ..., source => ... } the master owns the
#                                                         answer: it has to run
#                                                         the guard first
# $ctx carries what only the master knows: status, pid, version, why (the reason
# it is already down, if it is), pending (a restart already waiting), last (the
# previous record) and verify (a coderef running the guard).
sub handle {
	my ($line, $ctx) = @_;
	$ctx ||= {};
	my $req = eval { decode_json(defined $line ? $line : '') };
	unless (ref $req eq 'HASH') {
		return { reply => &_fail('bad-request', 'the request is not a JSON object: ' . &clean_text($@, 200)) };
	}
	if (($ctx->{'transport'} || '') eq 'tcp') {
		unless (JawnOS::Transport::token_ok($req->{'token'})) {
			return { reply => &_fail('unauthorized', 'a transport token is required') };
		}
	}
	my $cmd = lc(&clean_text($req->{'cmd'} // '', 40));
	if ($cmd eq 'status') {
		return { reply => {
			ok => 1,
			cmd => 'status',
			status => $ctx->{'status'} // 'unknown',
			why => $ctx->{'why'} // '',
			pid => $ctx->{'pid'} || 0,
			version => $ctx->{'version'} // '',
			pending => $ctx->{'pending'} ? 1 : 0,
			last_restart => $ctx->{'last'} || undef,
		} };
	}
	if ($cmd eq 'verify') {
		my $proof = $ctx->{'verify'} ? eval { $ctx->{'verify'}->() } : { ok => 1 };
		$proof = { ok => 0, report => 'the guard failed: ' . &clean_text($@, 400) } if $@;
		$proof ||= { ok => 0, report => 'the guard returned nothing' };
		return { reply => {
			ok => $proof->{'ok'} ? 1 : 0,
			cmd => 'verify',
			verified => $proof->{'ok'} ? 1 : 0,
			verify => &clean_text($proof->{'summary'} // '', 300),
			report => &clean_text($proof->{'report'} // '', 2000),
		} };
	}
	if ($cmd eq 'restart') {
		my $reason = &clean_text($req->{'reason'} // $req->{'why'} // '', 400);
		$reason = 'asked over the control socket' unless length $reason;
		my $source = &clean_text($req->{'source'} // '', 60);
		$source = 'control-socket' unless length $source;
		my $by = ($req->{'pid'} // '') =~ /^([0-9]+)$/ ? $1 + 0 : 0;
		return {
			action => 'restart',
			reason => $reason,
			source => $source,
			requested_by => $by,
			# Written at once, so the caller hears that the request landed before
			# the sweep begins.
			ack => &ack_reply({
				reason => $reason,
				source => $source,
				pid => $ctx->{'pid'},
				version => $ctx->{'version'},
				status_before => $ctx->{'status'},
			}),
		};
	}
	return { reply => &_fail('unknown-command',
		"unknown command '" . &clean_text($cmd, 40) . "'; try restart, status or verify") };
}

sub _fail {
	my ($error, $message) = @_;
	return { ok => 0, error => $error, message => &clean_text($message, 400) };
}

# The master's first word to a caller: the request has arrived and the guard is
# running. Without it the socket said nothing for the whole sweep - minutes on a
# cold tree - so a caller that bounded its wait could only report "no answer",
# and could not tell a master that was verifying from one that never read the
# line. It is an acknowledgement, never a verdict: `ack` marks it, and the
# verdict is the frame that follows.
sub ack_reply {
	my ($opt) = @_;
	$opt ||= {};
	return {
		ok => 1,
		ack => 1,
		cmd => 'restart',
		state => 'verifying',
		pending => 1,
		reason => &clean_text($opt->{'reason'} // '', 400),
		source => &clean_text($opt->{'source'} // '', 60),
		version => $opt->{'version'} // '',
		pid => $opt->{'pid'} || 0,
		status_before => $opt->{'status_before'} // '',
		epoch => int(time),
	};
}

# The verdict for a restart, built by the master once its guard has run. A
# refusal is not an error in the protocol - it is the answer, and the report is
# what a coding agent needs to fix the file instead of waiting for a tree that
# is never coming.
sub restart_reply {
	my ($opt) = @_;
	$opt ||= {};
	my $proof = $opt->{'proof'} || { ok => 1 };
	my %base = (
		cmd => 'restart',
		reason => &clean_text($opt->{'reason'} // '', 400),
		source => &clean_text($opt->{'source'} // '', 60),
		version => $opt->{'version'} // '',
		pid => $opt->{'pid'} || 0,
		status_before => $opt->{'status_before'} // '',
	);
	if ($proof->{'ok'}) {
		return {
			ok => 1,
			%base,
			accepted => 1,
			verified => $proof->{'skipped'} ? 0 : 1,
			verify => &clean_text($proof->{'summary'} // $proof->{'skipped'} // '', 300),
		};
	}
	return {
		ok => 0,
		%base,
		accepted => 0,
		verified => 0,
		refused => 'verify',
		report => &clean_text($proof->{'report'} // '', 2000),
	};
}

# ---------------------------------------------------------------- the record

sub _stamp {
	my @t = localtime;
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
		$t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# restart.json is replaced atomically (a reader never sees half a record) and
# restart.log gets one line per restart, rotated by size so a long-lived house
# keeps a decade of them without a growing file nobody reads.
sub write_record {
	my ($fields, %opt) = @_;
	$fields ||= {};
	my $dir = &_president_dir(%opt);
	File::Path::make_path($dir) unless -d $dir;
	my %record = %$fields;
	# a field the master had nothing to say about is left out, not written as null
	delete @record{ grep { !defined $record{$_} } keys %record };
	$record{'at'} ||= &_stamp();
	$record{'epoch'} ||= int(time);
	my $json = eval { encode_json(\%record) };
	return 0 unless defined $json && length $json;

	my $path = "$dir/restart.json";
	my $tmp = "$path.tmp.$$";
	if (open(my $fh, '>', $tmp)) {
		print $fh $json;
		close $fh;
		rename($tmp, $path) or unlink $tmp;
	}
	my $log = "$dir/restart.log";
	rename($log, "$log.1") if -e $log && (-s $log) > 262144;
	if (open(my $fh, '>>', $log)) {
		print $fh $json, "\n";
		close $fh;
	}
	return 1;
}

sub read_record {
	my %opt = @_;
	my $text = &read_text(&record_file(%opt));
	return undef unless length $text;
	my $record = eval { decode_json($text) };
	return ref $record eq 'HASH' ? $record : undef;
}

# One small file, read whole. Shared by the record and the status file, which
# are both a handful of bytes a reader must never see half written.
sub read_text {
	my ($path) = @_;
	return '' unless defined $path && -f $path;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

# What the status file must say, given what the master knows. That file is what
# a person and a script read when nothing else answers, and the tree writes it
# `good` for itself at boot - so a tree that never came back left a `good`
# behind it. The master is the only party that knows the tree is not serving, so
# it says so, with the reason. `status_reason` reads only a leading `restart` as
# a command, so this value is inert to the request channel.
sub watch_status {
	my (%arg) = @_;
	return 'good' if $arg{'serving'};
	my $why = &clean_text($arg{'why'} // '', 300);
	$why = 'the tree is not answering' unless length $why;
	return 'frozen: ' . $why;
}

# Publish that state, unless the file is a request the master has not read yet:
# a leading `restart` in that file is the one word that means "do something",
# and a publisher must never eat it. Replaced atomically, so a reader never sees
# half a line.
sub publish_status {
	my ($path, $value, %opt) = @_;
	return 0 unless defined $path && length $path;
	return 0 unless defined $value && length $value;
	my $now = &read_text($path);
	return 0 if (&status_reason($now))[0];
	return 0 if !$opt{'force'} && $now eq $value;
	my $dir = $path =~ m{^(.*)/[^/]*$} ? $1 : '';
	require File::Path;
	File::Path::make_path($dir) if length $dir && !-d $dir;
	my $tmp = "$path.tmp.$$";
	return 0 unless open(my $fh, '>', $tmp);
	print $fh $value;
	close $fh or do { unlink $tmp; return 0 };
	rename($tmp, $path) or do { unlink $tmp; return 0 };
	return 1;
}

# ----------------------------------------------------------------- the client

# Ask, and wait for the answer. A restart is answered by two frames: the ack
# (the request arrived, the guard is running) and then the verdict. The wait for
# the verdict is long on purpose - a cold guard is minutes - but a caller that
# would rather not wait can pass a short timeout and gets `pending` back, which
# says the request landed and the tree is still serving.
#
# There is a third way to learn the answer, and it is the one that survives a
# reply lost to a re-exec, a wedged stream or a listener that stopped being
# read: every restart writes ~/.president/restart.json before it swaps the tree
# and before it answers. So a caller whose own deadline passed reads the record
# instead of giving up, and reports the verdict from there.
sub send {
	my ($request, %opt) = @_;
	my $req = ref $request eq 'HASH' ? { %$request } : { cmd => 'status' };
	$req->{'pid'} ||= $$;
	my $path = $opt{'socket'} || &socket_path(%opt);
	my $timeout = $opt{'timeout'} || 150;
	my $started = time;

	my $sock;
	if ($opt{'socket'}) {
		require IO::Socket::UNIX;
		$sock = IO::Socket::UNIX->new(Peer => $path);
	}
	else {
		$sock = JawnOS::Transport::client_socket('control', timeout => 3, path => $path);
		$req->{'token'} = JawnOS::Transport::token() if JawnOS::Transport::tcp();
	}
	unless ($sock) {
		my $where = $opt{'socket'} ? $path : JawnOS::Transport::label('control');
		return { ok => 0, error => 'no-master', message => "no jawn master is listening on $where ($!)" };
	}
	$sock->autoflush(1);
	my $line = eval { encode_json($req) };
	unless (defined $line && length $line) {
		close $sock;
		return { ok => 0, error => 'bad-request', message => 'the request could not be encoded' };
	}
	my $deadline = $started + $timeout;
	unless (print $sock "$line\n") {
		close $sock;
		return { ok => 0, error => 'no-reply', message => 'the master closed the connection without reading the request' };
	}
	# The reason is the record's identity, so a request that gave none still has
	# one: the master substitutes the socket's own wording (see control::handle).
	# Without it, "newest record" would read a watchdog restart as this caller's.
	my $expect_reason = '';
	if (($req->{'cmd'} || '') eq 'restart') {
		$expect_reason = length($req->{'reason'} // '') ? $req->{'reason'} : 'asked over the control socket';
	}
	my ($buf, $ack) = ('', undef);
	my $reply;
	my $select = IO::Select->new($sock);
	while (time < $deadline) {
		while ($buf =~ s/^([^\n]*)\n//) {
			my $frame = eval { decode_json($1) };
			if (ref $frame ne 'HASH') {
				$reply = { ok => 0, error => 'bad-reply', message => 'the master answered something that is not JSON' };
				last;
			}
			if ($frame->{'ack'}) { $ack = $frame; next }
			$reply = $frame;
			last;
		}
		last if $reply;
		my $wait = $deadline - time;
		$wait = 0.5 if $wait > 0.5;
		next unless $select->can_read($wait);
		my $read = sysread($sock, my $chunk, 65536);
		last unless defined $read && $read > 0;
		$buf .= $chunk;
	}
	close $sock;
	if ($reply) {
		$reply->{'ok'} = 0 unless defined $reply->{'ok'};
		return $reply;
	}
	# No verdict frame. The record is written before the swap and before the
	# answer, so if the restart did finish while this caller waited, it is here -
	# and this is the only path that still answers when the reply itself is lost.
	my $record = $expect_reason ne ''
		? &await_record(%opt, since => $started, reason => $expect_reason, timeout => 0)
		: undef;
	return { %$record, 'from' => 'record' } if $record;
	if ($ack) {
		my $waited = int(time - $started);
		return { ok => 0, error => 'pending', ack => $ack, from => 'ack', state => 'verifying',
			cmd => ($req->{'cmd'} || ''), reason => $req->{'reason'} // '',
			message => "the master accepted the restart ($waited s) and is still verifying;"
				. ' the tree is still serving, and the verdict lands in ~/.president/restart.json' };
	}
	return { ok => 0, error => 'timeout',
		message => "the master did not answer within ${timeout}s; check ~/.president/restart.json" };
}

# Wait for the record of THIS request: its epoch is not older than the caller's
# pass, and when the caller gave a reason the record names it. A reason is the
# tightest identity the protocol has - two restarts with one reason are the same
# errand - and a caller that gave none falls back to the stamp alone.
# timeout => 0 asks once, for the caller that has already waited.
sub await_record {
	my (%opt) = @_;
	my $deadline = time + ($opt{'timeout'} || 0);
	while (1) {
		my $record = &read_record(%opt);
		return $record if &record_is_ours($record, %opt);
		last if time >= $deadline;
		select(undef, undef, undef, 0.25);
	}
	return undef;
}

sub record_is_ours {
	my ($record, %opt) = @_;
	return 0 unless ref $record eq 'HASH';
	my $epoch = $record->{'epoch'};
	return 0 unless defined $epoch && $epoch =~ /^[0-9]+$/;
	# a whole-second stamp can round below the caller's fractional start
	return 0 unless $epoch >= ($opt{'since'} || 0) - 1;
	my $reason = defined $opt{'reason'} ? &clean_text($opt{'reason'}, 400) : '';
	return 1 unless length $reason;
	return (($record->{'reason'} // '') eq $reason) ? 1 : 0;
}

# ------------------------------------------------------------------- the tree
# The master cannot signal a Windows child: the runner's stop is
# TerminateProcess, which gives the tree no chance to leave. So the tree serves
# one more channel - ~/.president/tree - and the master asks before it falls
# back to a kill. Same protocol as the master's own socket: one JSON line in,
# one JSON line out.
#
#   {"cmd":"stop","reason":"the master is shutting down"}
#   {"ok":1,"cmd":"stop"}
#   {"cmd":"status"}

sub tree_handle {
	my ($line, $ctx) = @_;
	$ctx ||= {};
	my $req = eval { decode_json(defined $line ? $line : '') };
	unless (ref $req eq 'HASH') {
		return { reply => &_fail('bad-request', 'the request is not a JSON object: ' . &clean_text($@, 200)) };
	}
	if (($ctx->{'transport'} || '') eq 'tcp') {
		unless (JawnOS::Transport::token_ok($req->{'token'})) {
			return { reply => &_fail('unauthorized', 'a transport token is required') };
		}
	}
	my $cmd = lc(&clean_text($req->{'cmd'} // '', 40));
	if ($cmd eq 'status') {
		return { reply => {
			ok => 1,
			cmd => 'status',
			pid => $ctx->{'pid'} || 0,
			version => $ctx->{'version'} // '',
			status => $ctx->{'status'} // 'running',
		} };
	}
	if ($cmd eq 'stop') {
		my $reason = &clean_text($req->{'reason'} // $req->{'why'} // '', 400);
		$reason = 'asked over the tree control socket' unless length $reason;
		return { action => 'stop', reason => $reason };
	}
	return { reply => &_fail('unknown-command',
		"unknown command '" . &clean_text($cmd, 40) . "'; try stop or status") };
}

# The master's side. Delivered is not the same as stopped: the caller still
# waits for the pid to go and falls back to the platform stop if it does not.
sub ask_tree_stop {
	my (%opt) = @_;
	my $timeout = $opt{'timeout'} || 2;
	my %where = $opt{'socket'} ? (path => $opt{'socket'}) : ();
	my $sock = JawnOS::Transport::client_socket('tree', timeout => $timeout, %where);
	return 0 unless $sock;
	$sock->autoflush(1);
	my %req = (cmd => 'stop');
	$req{'reason'} = &clean_text($opt{'reason'} || '', 400) if $opt{'reason'};
	$req{'token'} = JawnOS::Transport::token() if JawnOS::Transport::tcp();
	my $line = eval { encode_json(\%req) };
	unless (defined $line && length $line) { close $sock; return 0 }
	my $sent = print $sock "$line\n";
	# Read the acknowledgement, but never hold the shutdown on it: a tree still
	# booting may not reach the line before the caller's grace expires.
	if ($sent) {
		my $select = IO::Select->new($sock);
		if ($select->can_read(0.5)) {
			sysread($sock, my $junk, 65536);
		}
	}
	close $sock;
	return $sent ? 1 : 0;
}

1;
