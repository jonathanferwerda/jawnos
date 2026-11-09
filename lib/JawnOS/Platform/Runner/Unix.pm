package JawnOS::Platform::Runner::Unix;

# The Unix side of the runner seam: Mojo::IOLoop::ReadWriteFork, unchanged, with
# its callbacks normalised to the runner-first shape the seam documents.
#
# ReadWriteFork calls close handlers itself, as
#   $self->$cb(@$self{qw(exit_value signal)})
# which passes the fork as the first argument. The master read the first
# argument as the exit value, so its restart records said
# "exit=Mojo::IOLoop::ReadWriteFork=HASH(...)". Forwarding through the runner
# fixes that without touching the module.

use strict;
use warnings;

use Mojo::IOLoop::ReadWriteFork ();
use JawnOS::Platform::Process ();

sub new {
	my ($class, %opt) = @_;
	my $self = bless { events => {}, %opt }, $class;
	$self->{'fork'} = Mojo::IOLoop::ReadWriteFork->new;
	return $self;
}

sub conduit {
	my ($self, $spec) = @_;
	$self->{'fork'}->conduit($spec) if defined $spec;
	return $self;
}

sub pid { return $_[0]->{'fork'}->pid }

# Every ReadWriteFork event arrives as ($emitter, @rest); the seam's handlers
# want ($runner, @rest), whatever the event.
sub on {
	my ($self, $event, $cb) = @_;
	return $self unless defined $cb;
	$self->{'events'}{$event} = $cb;
	$self->{'fork'}->on($event => sub {
		my $handler = $self->{'events'}{$event} or return;
		my (undef, @rest) = @_;
		$handler->($self, @rest);
	});
	return $self;
}

sub start {
	my ($self, $spec) = @_;
	$self->{'fork'}->start($spec);
	return $self->{'fork'}->pid;
}

sub alive {
	my ($self) = @_;
	my $pid = $self->{'fork'}->pid or return 0;
	# A killed child answers kill(0) until its parent reaps it, and reaping here
	# would steal the close event from ReadWriteFork. The platform's state reader
	# is the test that knows a zombie is not working.
	return JawnOS::Platform::Process::running($pid) ? 1 : 0;
}

sub stop {
	my ($self, $signal) = @_;
	my $pid = $self->{'fork'}->pid or return 1;
	kill($signal || 'INT', $pid);
	return 1;
}

sub close {
	my ($self) = @_;
	$self->{'fork'}->close;
	return 1;
}

# The terminal session writes keystrokes to the child and resizes its pty. Both
# exist natively here; Windows answers them differently (see Runner::Windows).
sub write {
	my ($self, $bytes) = @_;
	return $self->{'fork'}->write($bytes);
}

sub read_handle {
	my ($self) = @_;
	return $self->{'fork'}->read_handle;
}

1;
