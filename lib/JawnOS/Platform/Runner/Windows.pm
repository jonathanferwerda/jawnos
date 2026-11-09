package JawnOS::Platform::Runner::Windows;

# The master's child-process runner for Windows, where
# Mojo::IOLoop::ReadWriteFork cannot exist: it requires IO::Pty, which is Unix
# only, and a real fork.
#
# Windows has no fork, no pty, and select() works only on sockets. Rather than
# poll a pipe, the child's standard handles ARE a loopback socket: a listener on
# 127.0.0.1 is connected to itself, the accepted end is made inheritable and
# handed to the child as stdin/stdout/stderr through STARTF_USESTDHANDLES, and
# the parent end is given to Mojo's reactor. Output therefore arrives as an
# event, exactly as it does from ReadWriteFork's pipe on Unix.
#
# Win32::Process cannot set STARTF_USESTDHANDLES, so the spawn is CreateProcessA
# with a hand-packed STARTUPINFO. The x64 layout is 104 bytes:
#   DWORD cb; pad; 3 pointers; 8 DWORDs; 2 WORDs; pad; pointer; 3 handles.
# It was verified in the Windows 11 VM: the socket delivers both streams and the
# process handle reports the exit code.
#
# Exit is not polled either: the socket's EOF is the event. The process handle is
# waited on (bounded) at that point to read the code, which is the one place a
# wait blocks, and it happens once when the child is already going away.
#
# The interface is the one jawn already speaks to ReadWriteFork: conduit,
# on(read|close|spawn), start({program, program_args, cwd}), pid, close. The
# Windows modules are required lazily, so this file still compiles on Linux.

use strict;
use warnings;

use Mojo::IOLoop ();

my $WAIT_OBJECT_0 = 0;
my $WAIT_TIMEOUT = 258;
my %API;

sub _api {
	my ($name) = @_;
	return $API{$name} if $API{$name};
	require Win32::API;
	my %bind = (
		'CreateProcessA'      => [ 'PPPPNNPPPP', 'N' ],
		'WaitForSingleObject' => [ 'NN', 'N' ],
		'GetExitCodeProcess'  => [ 'NP', 'N' ],
		'TerminateProcess'    => [ 'NN', 'N' ],
	);
	my $spec = $bind{$name} or die "unknown Win32 call $name\n";
	$API{$name} = Win32::API->new('kernel32', $name, $spec->[0], $spec->[1])
		or die "Win32::API could not bind $name: $^E\n";
	return $API{$name};
}

# A command line argument the way CreateProcess reads it back.
sub _quote_arg {
	my ($arg) = @_;
	$arg = '' unless defined $arg;
	return '""' unless length $arg;
	return $arg unless $arg =~ /[\s"]/;
	(my $quoted = $arg) =~ s/"/\\"/g;
	return qq{"$quoted"};
}

sub new {
	my ($class, %opt) = @_;
	return bless {
		events => {},
		%opt,
	}, $class;
}

# The master asks for a pty natively and a pipe in portable mode. Windows has
# one answer, and it is the socket.
sub conduit {
	my ($self, $spec) = @_;
	$self->{'conduit'} = { type => 'pipe' };
	return $self;
}

sub on {
	my ($self, $event, $cb) = @_;
	$self->{'events'}{$event} = $cb if defined $cb;
	return $self;
}

sub pid { return $_[0]->{'pid'} }

sub start {
	my ($self, $spec) = @_;
	$spec ||= {};
	return $self->{'pid'} if $self->{'pid'};
	require Win32API::File;
	require IO::Socket::INET;

	my $program = $spec->{'program'} || $^X;
	my @args = @{ $spec->{'program_args'} || [] };
	my $cwd = $spec->{'cwd'} || '.';

	# The child's end: a loopback pair. The accepted socket is the one the child
	# inherits; the connecting end is what the reactor watches.
	my $listener = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0,
		Proto => 'tcp', Listen => 1, ReuseAddr => 1,
	) or do { $self->{'error'} = "listen: $!"; return undef };
	my $port = $listener->sockport;
	my $mine = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp',
	) or do { $self->{'error'} = "connect: $!"; return undef };
	my $child_end = $listener->accept
		or do { $self->{'error'} = "accept: $!"; return undef };
	CORE::close($listener);
	binmode $mine;
	binmode $child_end;

	my $handle = Win32API::File::FdGetOsFHandle(fileno $child_end);
	Win32API::File::SetHandleInformation($handle, 1, 1);   # HANDLE_FLAG_INHERIT

	my $startup = pack('L x4 Q Q Q L8 S S x4 Q Q Q Q',
		104,
		0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 0x00000100,    # dwFlags: STARTF_USESTDHANDLES
		0, 0,
		0,
		$handle, $handle, $handle);
	my $process = "\0" x 24;    # PROCESS_INFORMATION

	# The child cannot call getppid on Windows; the master knows the answer.
	local $ENV{'JAWNOS_PARENT_PID'} = $$;
	my $command = join ' ', &_quote_arg($program), map { &_quote_arg($_) } @args;
	my $ok = &_api('CreateProcessA')->Call(
		$program, $command, 0, 0, 1, 0, 0, $cwd, $startup, $process,
	);
	CORE::close($child_end);    # the child holds its own copy
	unless ($ok) {
		CORE::close($mine);
		$self->{'error'} = 'CreateProcess failed: ' . Win32::GetLastError();
		return undef;
	}

	$self->{'thread'} = unpack('Q', substr($process, 8, 8));
	$self->{'handle'} = unpack('Q', substr($process, 0, 8));
	$self->{'pid'} = unpack('L', substr($process, 16, 4));
	$self->{'sock'} = $mine;
	$self->{'reactor'} = Mojo::IOLoop->singleton->reactor;
	$self->{'reactor'}->io($mine => sub { $self->pump });
	$self->{'events'}{'spawn'}->($self) if $self->{'events'}{'spawn'};
	return $self->{'pid'};
}

# Called by the reactor when the socket is readable, and only then.
sub pump {
	my ($self) = @_;
	return if $self->{'closed'};
	my $sock = $self->{'sock'} or return;

	my $n = sysread($sock, my $bytes, 65536);
	if (defined $n && $n > 0) {
		$self->{'events'}{'read'}->($self, $bytes) if $self->{'events'}{'read'};
		return;
	}
	return if !defined $n && $!{EAGAIN};

	# EOF: the child (and anything it handed the socket to) is gone.
	$self->{'reactor'}->remove($sock);
	CORE::close($sock);
	delete $self->{'sock'};
	$self->_reap;
	return;
}

sub _reap {
	my ($self) = @_;
	return if defined $self->{'exit'};
	# The socket closes as the process goes away; the one bounded wait reads the
	# code without turning the reader into a poll.
	&_api('WaitForSingleObject')->Call($self->{'handle'}, 5000);
	my $code = pack('L', 0);
	&_api('GetExitCodeProcess')->Call($self->{'handle'}, $code);
	$self->{'exit'} = unpack('L', $code);
	$self->{'events'}{'close'}->($self, $self->{'exit'}, 0) if $self->{'events'}{'close'};
	return;
}

sub alive {
	my ($self) = @_;
	return 0 unless $self->{'handle'};
	return 0 if defined $self->{'exit'};
	return &_api('WaitForSingleObject')->Call($self->{'handle'}, 0) == $WAIT_TIMEOUT ? 1 : 0;
}

# TerminateProcess. Windows gives a parent no way to ask for the tree's own
# shutdown, so the master's stop is a kill; a graceful stop has to travel over
# the transport as a message the tree honours.
sub stop {
	my ($self) = @_;
	return 1 unless $self->{'handle'};
	unless (defined $self->{'exit'}) {
		&_api('TerminateProcess')->Call($self->{'handle'}, 1);
		&_api('WaitForSingleObject')->Call($self->{'handle'}, 5000);
		my $code = pack('L', 0);
		&_api('GetExitCodeProcess')->Call($self->{'handle'}, $code);
		$self->{'exit'} = unpack('L', $code);
	}
	$self->_finish;
	return 1;
}

sub close {
	my ($self) = @_;
	return $self->stop if $self->{'handle'} && !defined $self->{'exit'} && !$self->{'closed'};
	$self->_finish;
	return 1;
}

sub _finish {
	my ($self) = @_;
	$self->{'closed'} = 1;
	if ($self->{'sock'} && $self->{'reactor'}) {
		$self->{'reactor'}->remove($self->{'sock'});
	}
	CORE::close($self->{'sock'}) if $self->{'sock'};
	delete $self->{'sock'};
	return;
}

# The terminal's write side. There is no pty here, so read_handle is undef and
# terminal_session_resize - which guards on it - is a no-op; a resize cannot
# reach a shell that has no terminal.
sub write {
	my ($self, $bytes) = @_;
	my $sock = $self->{'sock'} or return 0;
	return 0 unless defined $bytes && length $bytes;
	my $left = $bytes;
	while (length $left) {
		my $n = syswrite($sock, $left);
		return 0 unless defined $n && $n > 0;
		substr($left, 0, $n, '');
	}
	return 1;
}

sub read_handle { return undef }

1;
