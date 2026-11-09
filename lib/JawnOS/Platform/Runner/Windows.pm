package JawnOS::Platform::Runner::Windows;

# The master's child-process runner for Windows, where
# Mojo::IOLoop::ReadWriteFork cannot exist: it requires IO::Pty, which is Unix
# only, and a real fork.
#
# Windows has no fork, no pty, and select() works only on sockets. The shapes
# the master relies on are built here from three primitives that do work:
#
#   - IPC::Open3 starts the child and hands back its stdin/stdout/stderr pipes;
#   - Win32API::File::FdGetOsFHandle names a pipe's handle, and Win32::API's
#     WaitForSingleObject waits on it - a pipe is not selectable, but it is
#     waitable, so the reader is woken only when there are bytes;
#   - waitpid($pid, WNOHANG) reports the exit and kill terminates the child
#     (on Windows kill is TerminateProcess, whatever the signal name).
#
# The Windows modules are required lazily: this file still compiles - and the
# suite still loads it on Linux - so the portability of the tree does not
# depend on a module that only exists on one platform.
#
# The interface is the one jawn already speaks to ReadWriteFork: conduit,
# on(read|close|spawn), start({program, program_args}), pid, close. A pty
# conduit is not available here and is recorded as a pipe.

use strict;
use warnings;

use IPC::Open3 ();
use Symbol qw(gensym);
use POSIX qw(WNOHANG);
use Mojo::IOLoop ();

my $WAIT_OBJECT_0 = 0;
my $WaitForSingleObject;

sub _wait_api {
	return $WaitForSingleObject if $WaitForSingleObject;
	require Win32::API;
	$WaitForSingleObject = Win32::API->new('kernel32', 'WaitForSingleObject', 'NN', 'N')
		or die "Win32::API could not bind WaitForSingleObject: $^E\n";
	return $WaitForSingleObject;
}

sub new {
	my ($class, %opt) = @_;
	return bless {
		events => {},
		%opt,
	}, $class;
}

# The master asks for a pty natively and a pipe in portable mode. Windows has
# one answer, and it is the pipe.
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
	my $program = $spec->{'program'} || $^X;
	my @args = @{ $spec->{'program_args'} || [] };

	my ($in, $out);
	my $err = gensym;
	my $pid = eval { IPC::Open3::open3($in, $out, $err, $program, @args) };
	unless ($pid) {
		$self->{'error'} = $@ || 'the child could not be started';
		return undef;
	}
	CORE::close($in);    # the tree reads no stdin
	binmode $out;
	binmode $err;

	$self->{'pid'} = $pid;
	$self->{'out'} = $out;
	$self->{'err'} = $err;
	$self->{'out_handle'} = Win32API::File::FdGetOsFHandle(fileno $out);
	$self->{'err_handle'} = Win32API::File::FdGetOsFHandle(fileno $err);

	# 150ms is the smallest interval that keeps line-oriented output prompt
	# without a busy loop; the wait answers immediately when bytes arrive.
	$self->{'timer'} = Mojo::IOLoop->recurring(0.15 => sub { $self->pump });
	$self->{'events'}{'spawn'}->($self) if $self->{'events'}{'spawn'};
	return $pid;
}

# One wait per stream per tick. A sysread after a signalled wait returns what is
# buffered; the next tick drains the rest, so a chatty child cannot block the
# master inside this loop.
sub pump {
	my ($self) = @_;
	return if $self->{'closed'};
	my $wait = &_wait_api();

	my $data = '';
	for my $slot ([$self->{'out'}, $self->{'out_handle'}],
	              [$self->{'err'}, $self->{'err_handle'}]) {
		my ($fh, $handle) = @$slot;
		next unless $fh && $handle;
		next if $self->{'drained'}{$handle};
		next unless $wait->Call($handle, 0) == $WAIT_OBJECT_0;
		my $n = sysread($fh, my $chunk, 65536);
		if (defined $n && $n > 0) {
			$data .= $chunk;
		}
		elsif (defined $n) {
			$self->{'drained'}{$handle} = 1;    # 0 bytes: end of stream
		}
	}
	if (length $data && $self->{'events'}{'read'}) {
		$self->{'events'}{'read'}->($self, $data);
	}

	return if defined $self->{'exit'};
	if (waitpid($self->{'pid'}, WNOHANG) == $self->{'pid'}) {
		$self->{'exit'} = $? >> 8;
		$self->{'events'}{'close'}->($self->{'exit'}, 0) if $self->{'events'}{'close'};
		Mojo::IOLoop->remove($self->{'timer'}) if $self->{'timer'};
	}
	return;
}

sub alive {
	my ($self) = @_;
	return 0 unless $self->{'pid'};
	return 0 if defined $self->{'exit'};
	return waitpid($self->{'pid'}, WNOHANG) == 0 ? 1 : 0;
}

# TerminateProcess under the signal's name. Terminating is the only stop Windows
# offers a parent; the tree's own cleanup on the way out is a shutdown this
# runner cannot ask for.
sub stop {
	my ($self) = @_;
	return 1 unless $self->{'pid'};
	unless (defined $self->{'exit'}) {
		kill 'KILL', $self->{'pid'};
		waitpid($self->{'pid'}, 0);
		$self->{'exit'} = $? >> 8;
	}
	$self->_finish;
	return 1;
}

sub close {
	my ($self) = @_;
	return $self->stop if $self->{'pid'} && !defined $self->{'exit'} && !$self->{'closed'};
	$self->_finish;
	return 1;
}

sub _finish {
	my ($self) = @_;
	$self->{'closed'} = 1;
	Mojo::IOLoop->remove($self->{'timer'}) if $self->{'timer'};
	for my $key (qw(out err)) {
		CORE::close($self->{$key}) if $self->{$key};
		delete $self->{$key};
	}
	return;
}

1;
