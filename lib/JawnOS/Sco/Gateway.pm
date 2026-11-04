package JawnOS::Sco::Gateway;

# One call at a time, held by one Bluetooth SCO link.
#
# The helper (perl/sco/sco_helper) owns the audio socket and speaks JSON lines
# on its stdin/stdout; this object owns the policy: which prompts to play, when
# to start recording the caller, and what the rest of the house is allowed to
# see while the call is up. It is deliberately one-call-at-a-time - an HFP
# Hands-Free link carries one eSCO stream, and a second caller while the first
# is leaving a name is exactly what voicemail is for.
#
# State moves: idle -> armed (helper listening) -> in_call (link accepted) ->
# done/idle. Every move is written to ~/.president/sco.json, so a status page
# that arrives between events reads the same answer the socket would give.
use strict;
use warnings;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::JSON qw(decode_json encode_json);
use File::Path qw(make_path);
use POSIX qw(:sys_wait_h);
use IPC::Open2 ();

my $KEEP_RECORDINGS = 40;

sub new {
	my ($class, %args) = @_;
	my $dir = $args{'dir'} || &subs::home('~/.president/sco');
	make_path($dir) unless -d $dir;
	my $self = bless {
		dir => $dir,
		helper => $args{'helper'} || './perl/sco/sco_helper',
		status_path => $args{'status_path'} || &subs::home('~/.president/sco.json'),
		state => 'idle',
		peer => '',
		since => 0,
		call_id => '',
		steps => [],
		step_at => 0,
		next_id => 1,
		last_event => '',
		last_error => '',
		recordings => [],
		buffer => '',
		pid => 0,
	}, $class;
	Mojo::IOLoop->recurring(3 => sub { $self->write_status });
	return $self;
}

# The helper binary is built by scripts/build_sco.pl on the machine with the
# adapter. No binary means no gateway, which is a normal state on a laptop
# that has not been set up yet.
sub helper_command {
	my ($self) = @_;
	my $helper = $self->{'helper'};
	my @cmd = ref $helper eq 'ARRAY' ? @{$helper} : ($helper);
	return () unless @cmd && -x $cmd[0];
	return @cmd;
}

# The BlueALSA PCM this machine's Hands-Free stack exposes, when it has one.
sub pcm_device {
	my ($self) = @_;
	my $pcm = eval { &subs::misc_setting('sco_pcm') };
	return $pcm || '';
}

sub local_address {
	my ($self) = @_;
	return $self->{'local'} if defined $self->{'local'};
	my $addr = eval { &subs::misc_setting('sco_local') } || '';
	return $addr;
}

# ---- status -------------------------------------------------------------

sub status {
	my ($self) = @_;
	my $state = $self->{'state'};
	# an armed gateway whose helper is gone is idle, whatever the last event said
	$state = 'idle' if ($state eq 'armed' || $state eq 'starting') && !$self->{'pid'};
	return {
		ok => 1,
		state => $state,
		peer => $self->{'peer'},
		since => $self->{'since'},
		call_id => $self->{'call_id'},
		last_event => $self->{'last_event'},
		last_error => $self->{'last_error'},
		helper => ($self->helper_command() ? 1 : 0),
		recordings => $self->{'recordings'},
		plan => [ map { $_->{'key'} || ($_->{'tone'} ? 'tone' : 'step') } @{ $self->{'steps'} || [] } ],
		local => $self->{'local'} || '',
	};
}

sub write_status {
	my ($self) = @_;
	my $path = $self->{'status_path'};
	return 0 unless $path;
	my $body = encode_json({
		%{ $self->status() },
		pid => $$,
		helper_pid => $self->{'pid'} || 0,
		updated => time,
	});
	my $tmp = "$path.tmp.$$";
	my $ok = eval {
		open(my $fh, '>', $tmp) or die "open $tmp: $!";
		print {$fh} $body;
		close $fh;
		rename $tmp, $path or die "rename: $!";
		1;
	};
	unlink $tmp unless $ok;
	return $ok ? 1 : 0;
}

# ---- arming -------------------------------------------------------------

# %args: peer => BDADDR (optional pin), greeting/prompt/voicemail/thanks =>
# clip text or '' (voicemail replaced the old one and is not played here),
# record => { ms, silence_ms, min_ms }, clips => { key => raw path }.
# The plan is greeting, name prompt, record the name, thanks - in that order.
sub arm {
	my ($self, %args) = @_;
	return { ok => 0, error => 'a call is already up' }
		if $self->{'state'} eq 'in_call';
	# a second arm while one is starting would leave the first helper holding the
	# SCO listener and its parent's pipe gone: the helper then exits unreaped and
	# the next call finds a gateway that only looks armed
	return { ok => 1, state => 'starting' } if $self->{'state'} eq 'starting';
	$self->cancel() if $self->{'state'} ne 'idle' || $self->{'pid'};
	my @cmd = $self->helper_command();
	return { ok => 0, error => 'the SCO helper is not built on this machine' } unless @cmd;
	# A Hands-Free stack (BlueALSA) owning the link leaves us as a plain audio
	# client of its PCM; without one, the helper takes the raw SCO socket itself.
	my $pcm = defined $args{'pcm'} && length $args{'pcm'} ? $args{'pcm'} : $self->pcm_device();
	if ($pcm) {
		push @cmd, '--pcm', $pcm;
	}
	else {
		$self->{'local'} = $args{'local'} if defined $args{'local'};
		my $local = $self->local_address();
		push @cmd, '--local', $local if $local;
		push @cmd, '--peer', $args{'peer'} if $args{'peer'};
	}

	my $clips = $args{'clips'} || {};
	my @steps;
	# a diagnostic tone: proof that the uplink reaches the caller, with nothing
	# else in the way
	my $tone = $args{'tone'};
	if (ref $tone eq 'HASH') {
		push @steps, {
			tone => 1,
			hz => ($tone->{'hz'} && $tone->{'hz'} =~ /^\d+$/) ? int($tone->{'hz'}) : 660,
			ms => ($tone->{'ms'} && $tone->{'ms'} =~ /^\d+$/) ? int($tone->{'ms'}) : 1200,
		};
	}
	foreach my $key (qw(greeting prompt)) {
		my $path = $clips->{$key} || '';
		push @steps, { play => $path, key => $key } if $path;
	}
	push @steps, { record => 1, key => 'name' };
	my $thanks = $clips->{'thanks'} || '';
	push @steps, { play => $thanks, key => 'thanks' } if $thanks;

	$self->{'steps'} = \@steps;
	$self->{'step_at'} = 0;
	$self->{'peer'} = $args{'peer'} || '';
	$self->{'call_id'} = $args{'call_id'} || &call_id();
	$self->{'last_error'} = '';
	$self->{'last_event'} = '';
	$self->{'record_opts'} = $args{'record'} || {};
	$self->{'state'} = 'starting';

	return { ok => 0, error => 'the SCO helper would not start' } unless $self->_spawn(@cmd);
	$self->{'state'} = 'armed';
	$self->{'since'} = time;
	$self->write_status();
	return { ok => 1, state => $self->{'state'}, call_id => $self->{'call_id'} };
}

sub call_id {
	my ($self) = @_;
	return sprintf('%d-%04x', time, int(rand(65536)));
}

sub _spawn {
	my ($self, @cmd) = @_;
	my $out;
	my $in;
	my $pid = eval { IPC::Open2::open2($out, $in, @cmd) };
	unless ($pid) {
		$self->{'last_error'} = "spawn: $@" || 'spawn failed';
		return 0;
	}
	$self->{'pid'} = $pid;
	$self->{'in'} = $in;
	$self->{'out'} = $out;
	$self->{'buffer'} = '';
	$in->autoflush(1);
	my $ok = eval {
		$out->blocking(0);
		my $stream = Mojo::IOLoop::Stream->new($out)->timeout(0);
		$stream->on(read => sub {
			my ($stream, $bytes) = @_;
			$self->{'buffer'} .= $bytes;
			while ($self->{'buffer'} =~ s/^(.*?)\n//) {
				my $line = $1;
				next unless $line =~ /\S/;
				my $event = eval { decode_json($line) };
				next unless ref $event eq 'HASH';
				$self->event($event);
			}
		});
		$stream->on(close => sub {
			return if $self->{'reaping'};
			$self->event({ event => 'closed', reason => 'helper went away' });
		});
		$stream->start;
		$self->{'stream'} = $stream;
		1;
	};
	unless ($ok) {
		$self->{'last_error'} = "stream: $@";
		$self->_reap();
		return 0;
	}
	return 1;
}

# ---- the plan -----------------------------------------------------------

sub _send {
	my ($self, %request) = @_;
	my $in = $self->{'in'} or return 0;
	my $ok = eval {
		print {$in} encode_json(\%request) . "\n";
		$in->flush;
		1;
	};
	return $ok ? 1 : 0;
}

sub _advance {
	my ($self) = @_;
	my $steps = $self->{'steps'} || [];
	$self->{'step_at'}++;
	my $step = $steps->[ $self->{'step_at'} ];
	unless ($step) {
		$self->{'state'} = 'done';
		$self->{'since'} = time;
		$self->write_status();
		return;
	}
	if ($step->{'tone'}) {
		$self->_send(cmd => 'tone', id => $self->{'next_id'}, hz => $step->{'hz'}, ms => $step->{'ms'});
	}
	elsif ($step->{'record'}) {
		my $opts = $self->{'record_opts'} || {};
		my $file = $self->{'dir'} . '/name-' . $self->{'call_id'} . '.wav';
		$self->{'pending_record'} = $file;
		$self->_send(
			cmd => 'record',
			id => $self->{'next_id'},
			file => $file,
			ms => $opts->{'ms'} || 20000,
			silence_ms => $opts->{'silence_ms'} || 1200,
			min_ms => $opts->{'min_ms'} || 400,
		);
	}
	else {
		$self->_send(cmd => 'play', id => $self->{'next_id'}, file => $step->{'play'});
	}
	$self->{'step_id'} = $self->{'next_id'}++;
	$self->{'last_event'} = 'step:' . ($step->{'key'} || 'play');
	$self->write_status();
}

# ---- helper events ------------------------------------------------------

sub event {
	my ($self, $event) = @_;
	my $name = $event->{'event'} || '';
	$self->{'last_event'} = $name;
	if ($name eq 'listening') {
		$self->{'local'} = $event->{'local'} || $self->{'local'};
		$self->{'state'} = 'armed' if $self->{'state'} eq 'starting';
		$self->write_status();
	}
	elsif ($name eq 'accepted') {
		$self->{'state'} = 'in_call';
		$self->{'since'} = time;
		$self->{'peer'} = $event->{'peer'} || $self->{'peer'};
		$self->{'step_at'} = -1;
		$self->_advance();
	}
	elsif ($name eq 'played' || $name eq 'recorded') {
		if ($name eq 'recorded' && $self->{'pending_record'}) {
			my $file = $event->{'file'} || $self->{'pending_record'};
			$self->{'pending_record'} = '';
			my %recording = (
				file => $file,
				ms => $event->{'ms'} || 0,
				silence => $event->{'silence'} ? 1 : 0,
				at => time,
				call_id => $self->{'call_id'},
				peer => $self->{'peer'},
			);
			unshift @{ $self->{'recordings'} }, \%recording;
			splice(@{ $self->{'recordings'} }, $KEEP_RECORDINGS)
				if @{ $self->{'recordings'} } > $KEEP_RECORDINGS;
			$self->{'last_recording'} = \%recording;
		}
		# a stop or a dropped step must not advance the queue twice
		next_step: {
			last next_step if defined $event->{'id'}
				&& $self->{'step_id'}
				&& $event->{'id'} != $self->{'step_id'};
			$self->_advance();
		}
	}
	elsif ($name eq 'closed' || $name eq 'stopped') {
		$self->{'last_event'} = $name;
		$self->{'state'} = $self->{'state'} eq 'done' ? 'done' : 'idle';
		$self->{'since'} = time;
		$self->_reap();
		$self->write_status();
	}
	elsif ($name eq 'error') {
		# a complaint is not a death: the helper keeps trying (a PCM that is
		# not up yet, a link that was refused) and the reason is kept for the
		# pane. Only a close ends it.
		$self->{'last_error'} = $event->{'error'} || 'helper error';
		$self->write_status();
	}
	else {
		$self->write_status();
	}
	return 1;
}

# ---- teardown -----------------------------------------------------------

sub cancel {
	my ($self) = @_;
	return { ok => 1, state => $self->{'state'} } if $self->{'state'} eq 'idle';
	$self->_send(cmd => 'quit');
	$self->_reap();
	$self->{'state'} = 'idle';
	$self->{'since'} = time;
	$self->{'last_event'} = 'cancelled';
	$self->write_status();
	return { ok => 1, state => $self->{'state'} };
}

sub _reap {
	my ($self) = @_;
	$self->{'reaping'} = 1;
	my $pid = delete $self->{'pid'};
	foreach my $key (qw(stream in out)) {
		my $thing = delete $self->{$key};
		next unless $thing;
		eval { $thing->close };
	}
	return unless $pid;
	# the helper has PR_SET_PDEATHSIG, so this is belt and braces: a stuck
	# helper must not outlive the call that armed it
	my $tries = 0;
	my $gone = 0;
	while ($tries++ < 10) {
		my $done = waitpid($pid, WNOHANG);
		if ($done == $pid) { $gone = 1; last; }
		select(undef, undef, undef, 0.02);
	}
	unless ($gone) {
		# the helper has PR_SET_PDEATHSIG, so it is on its way out; wait for it
		# rather than leaving a zombie with nothing left to reap it
		kill 'TERM', $pid;
		waitpid($pid, 0);
	}
	$self->{'reaping'} = 0;
	return;
}

# ---- recordings ---------------------------------------------------------

# A recording is served only when it is one this gateway made; the name comes
# from the status, never from a caller's path.
sub recording_path {
	my ($self, $name) = @_;
	return '' unless defined $name && length $name;
	return '' if $name =~ m{[/\\]} || $name =~ /^\./;
	my $file = $self->{'dir'} . '/' . $name;
	return -s $file ? $file : '';
}

1;
