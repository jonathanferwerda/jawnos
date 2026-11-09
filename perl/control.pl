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
		return { action => 'restart', reason => $reason, source => $source, requested_by => $by };
	}
	return { reply => &_fail('unknown-command',
		"unknown command '" . &clean_text($cmd, 40) . "'; try restart, status or verify") };
}

sub _fail {
	my ($error, $message) = @_;
	return { ok => 0, error => $error, message => &clean_text($message, 400) };
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
	my $path = &record_file(%opt);
	return undef unless -f $path;
	open(my $fh, '<', $path) or return undef;
	my $text = do { local $/; <$fh> };
	close $fh;
	my $record = eval { decode_json(defined $text ? $text : '') };
	return ref $record eq 'HASH' ? $record : undef;
}

# ----------------------------------------------------------------- the client

# Ask, and wait for the answer. The wait is long on purpose: the master runs the
# tree guard before it replies, and a cold guard is minutes. An agent that would
# rather not wait can pass a short timeout and read the failure as "asked, not
# yet answered" - the record still exists afterwards.
sub send {
	my ($request, %opt) = @_;
	my $req = ref $request eq 'HASH' ? { %$request } : { cmd => 'status' };
	$req->{'pid'} ||= $$;
	my $path = $opt{'socket'} || &socket_path(%opt);
	my $timeout = $opt{'timeout'} || 150;

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
	my $deadline = time + $timeout;
	unless (print $sock "$line\n") {
		close $sock;
		return { ok => 0, error => 'no-reply', message => 'the master closed the connection without reading the request' };
	}
	my $buf = '';
	my $select = IO::Select->new($sock);
	while (time < $deadline) {
		my $wait = $deadline - time;
		$wait = 0.5 if $wait > 0.5;
		next unless $select->can_read($wait);
		my $read = sysread($sock, my $chunk, 65536);
		last unless defined $read && $read > 0;
		$buf .= $chunk;
		last if index($buf, "\n") >= 0;
	}
	close $sock;
	my ($reply_line) = split /\n/, $buf, 2;
	unless (defined $reply_line && length $reply_line) {
		return { ok => 0, error => 'timeout',
			message => "the master did not answer within ${timeout}s; check ~/.president/restart.json" };
	}
	my $reply = eval { decode_json($reply_line) };
	unless (ref $reply eq 'HASH') {
		return { ok => 0, error => 'bad-reply', message => 'the master answered something that is not JSON' };
	}
	$reply->{'ok'} = 0 unless defined $reply->{'ok'};
	return $reply;
}

1;
