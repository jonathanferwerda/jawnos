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
use List::Util qw(shuffle);

my $KEEP_RECORDINGS = 40;

sub new {
	my ($class, %args) = @_;
	my $dir = $args{'dir'} || &subs::home('~/.president/sco');
	make_path($dir) unless -d $dir;
	my $self = bless {
		dir => $dir,
		helper => $args{'helper'} || './perl/sco/sco_helper',
		status_path => $args{'status_path'} || &subs::home('~/.president/sco.json'),
		(defined $args{'pipe'} ? (pipe => ($args{'pipe'} ? 1 : 0)) : ()),
		state => 'idle',
		peer => '',
		since => 0,
		call_id => '',
		steps => [],
		step_at => 0,
		flows => {},
		flow => '',
		flow_started => 0,
		default_flow => '',
		hold_until => 0,
		keypad_open => 0,
		next_id => 1,
		last_event => '',
		last_error => '',
		recordings => [],
		transcript => [],
		partial => '',
		transcript_engine => '',
		transcript_note => '',
		caller => {},
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

# The virtual-handset mode: PipeWire carries the call, and two null sinks plus
# a remapped source let the gateway own the audio without touching the defaults.
sub pipe_mode {
	my ($self) = @_;
	# a caller (a test) may say outright which transport it means
	return $self->{'pipe'} ? 1 : 0 if exists $self->{'pipe'};
	my $on = eval { &subs::misc_setting('sco_pipe') } || '';
	return $on eq 'yes';
}

sub peer_address {
	my ($self) = @_;
	my $addr = eval { &subs::misc_setting('sco_peer') } || '';
	return $addr;
}

# # The BlueALSA PCM this machine's Hands-Free stack exposes, when it has one.
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

# ---- the radio the machine's WiFi is on ---------------------------------
#
# A combo card's Bluetooth and WiFi share one antenna, and a 2.4 GHz connection
# starves the eSCO link: the caller's voice arrives as "corrupted SCO packet" and
# every name is recorded silent (367 of them in 500 kernel lines on the dev box;
# none after it moved to 5 GHz). The pane is told the band so that failure looks
# like what it is. The parse is separate from the command so it can be tested
# without a radio.
sub wifi_band_of {
	my ($link) = @_;
	return '' unless defined $link && $link =~ /freq:\s*([0-9.]+)/;
	my $mhz = $1;
	return ($mhz >= 2400 && $mhz < 2500) ? '2.4' : '5';
}

# `iw dev` indents its lines - the interface name sits under a tab - so an
# anchored parse that expects column zero finds nothing and the pane reports no
# band on a machine that is plainly on WiFi.
sub wifi_interfaces_of {
	my ($list) = @_;
	return () unless defined $list;
	return ($list =~ /^[ \t]*Interface[ \t]+(\S+)/mg);
}

# '' when this machine has no wireless or is not associated: a machine on a wire
# has no band to warn about.
sub wifi_band {
	my ($self) = @_;
	my $now = time;
	return $self->{'wifi'} if defined $self->{'wifi'} && $now - ($self->{'wifi_at'} || 0) < 30;
	$self->{'wifi_at'} = $now;
	$self->{'wifi'} = '';
	my $list = '';
	if (open(my $iw, '-|', 'iw', 'dev')) {
		local $/;
		$list = <$iw> // '';
		close $iw;
	}
	foreach my $if (&wifi_interfaces_of($list)) {
		next unless $if =~ /^[A-Za-z0-9_.-]+$/;
		my $link = '';
		if (open(my $lh, '-|', 'iw', 'dev', $if, 'link')) {
			local $/;
			$link = <$lh> // '';
			close $lh;
		}
		my $band = &wifi_band_of($link);
		if (length $band) { $self->{'wifi'} = $band; last; }
	}
	return $self->{'wifi'};
}

# ---- status -------------------------------------------------------------

sub status {
	my ($self) = @_;
	my $state = $self->{'state'};
	# an armed gateway whose helper is gone is idle, whatever the last event said
	$state = 'idle' if ($state eq 'armed' || $state eq 'starting') && !$self->{'pid'};
	# the band the machine's WiFi is on, and the warning it earns
	my $wifi = $self->wifi_band();
	my $warning = $wifi eq '2.4'
		? "This gateway machine's WiFi is on 2.4 GHz, which shares its antenna with Bluetooth: the caller will break up. Move it to 5 GHz or wired."
		: '';
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
		# the messages a voicemail flow left, newest first: the kept index is
		# the durable list, the recordings above are this process's own
		voicemail => $self->voicemail_list(),
		# the caller's words while the call is up, and the sentence being said:
		# the Phone pane and the card draw these, and the Chat app keeps them
		transcript => $self->{'transcript'} || [],
		partial => $self->{'partial'} || '',
		transcript_engine => $self->{'transcript_engine'} || '',
		transcript_note => $self->{'transcript_note'} || '',
		# who the phone says is calling; this side only sees the Bluetooth link
		caller => $self->{'caller'} || {},
		# the flow this call belongs to, and where in it the plan has got to: a
		# menu jumps to another flow, so both the key and the step are the plan's
		# own answer, not something the pane can work out for itself
		flow => $self->{'flow'} || '',
		step_index => (defined $self->{'step_at'} && $self->{'step_at'} >= 0) ? $self->{'step_at'} : -1,
		step_type => do {
			my $at = $self->{'step_at'};
			my $step = (defined $at && $at >= 0) ? ($self->{'steps'} || [])->[$at] : undef;
			($step && $step->{'type'}) ? $step->{'type'} : '';
		},
		# a timed hold says how long the caller waits on the music
		hold_seconds_left => do {
			my $until = $self->{'hold_until'} || 0;
			my $left = 0;
			if ($self->{'holding'} && $until) {
				$left = int($until - time + 0.999);
				$left = 0 if $left < 0;
			}
			$left;
		},
		# the WebRTC bridge, when someone pressed Connect me
		rtc => $self->{'rtc'} || { state => 'idle', error => '' },
		plan => [ map { $_->{'key'} || ($_->{'tone'} ? 'tone' : 'step') } @{ $self->{'steps'} || [] } ],
		# the hold: whether the caller is waiting on music, and the tracks this
		# gateway can play, which is what the IVR pane's dropdown offers
		hold => $self->{'holding'} ? 1 : 0,
		# the caller was left listening after a typed message: the music is
		# stopped on purpose, and the pane offers to put them back on it
		hold_paused => $self->{'hold_paused'} ? 1 : 0,
		hold_tracks => do {
			require JawnOS::Sco::Hold;
			[ map { { id => $_, label => &JawnOS::Sco::Hold::label($_) } } @{ &JawnOS::Sco::Hold::tracks() } ]
		},
		local => $self->{'local'} || '',
		# where the call's own two streams were on the last look: the pane and a
		# person debugging a silent call both need to know whether they are ours
		streams => ($self->{'mixer'} ? ($self->{'mixer'}->{'attached'} || {}) : {}),
		wifi => $wifi,
		warning => $warning,
	};
}

# The phone knows who is calling; the gateway only sees the Bluetooth link.
# Its status poll carries the number while the phone's caller id is fresh, and
# this side resolves the house's name for it. A number the house does not know
# is shown as the number the phone received.
sub note_caller {
	my ($self, $number) = @_;
	$number = '' unless defined $number;
	# an empty poll keeps the last caller: the phone's caller id goes stale
	# after fifteen seconds, and clearing here would erase the header
	return 0 unless length $number;
	my $was = $self->{'caller'} || {};
	return 1 if ($was->{'number'} // '') eq $number;
	my $digits = $number;
	$digits =~ s/\D+//g;
	$digits =~ s/^1//;
	return 0 unless length $digits;
	my $app = eval { &subs::phone_number_app($digits) } || '';
	my $name = (length $app && $app ne $digits) ? (eval { &subs::format_name($app) } || '') : '';
	$self->{'caller'} = { number => $number, name => $name, at => time };
	$self->write_status();
	return 1;
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

# One flow's authored steps, in the engine's shape.
#
# A flow def carries `steps` (an array) or the legacy words; when it carries
# neither, the old plan is derived from them so a house that never opened the
# flow editor keeps the sequence it always had: greeting, ask for a name,
# thanks, and then whatever `after` says.
#
# The result is a flat list of steps, because the engine only ever needs to know
# what to do next: `say` is one clip, `ask` is a prompt, a cue and a recording,
# `voicemail` is a greeting and a recording. A keypad step keeps its digits so a
# press can jump to another flow, and a hold step keeps its seconds so a timed
# hold can end on its own.
sub flow_steps {
	my ($def) = @_;
	$def ||= {};
	my $clips = ref $def->{'clips'} eq 'HASH' ? $def->{'clips'} : {};
	my $voice = defined $def->{'voice'} ? $def->{'voice'} : '';
	my $hold = defined $def->{'hold'} ? $def->{'hold'} : '';
	my $after = lc(defined $def->{'after'} ? $def->{'after'} : 'hold');
	my $voicemail_seconds = &_voicemail_seconds($def->{'voicemail_seconds'});
	my @authored;
	if (ref $def->{'steps'} eq 'ARRAY' && @{ $def->{'steps'} }) {
		@authored = @{ $def->{'steps'} };
	}
	else {
		@authored = (
			{ type => 'say', text_key => 'greeting' },
			{ type => 'ask' },
			{ type => 'say', text_key => 'thanks' },
			{ type => 'after' },
		);
	}
	my @steps;
	for my $i (0 .. $#authored) {
		my $raw = $authored[$i];
		next unless ref $raw eq 'HASH';
		my $type = lc($raw->{'type'} || '');
		$type = 'say' unless length $type || !defined $raw->{'text_key'};
		if ($type eq 'say') {
			my $key = $raw->{'text_key'} || '';
			next unless $key =~ /^(?:greeting|prompt|thanks|voicemail)$/;
			my $path = $clips->{$key} || '';
			# a line with no words is not spoken, and not a step either
			next unless length $path;
			push @steps, { type => 'say', key => $key, play => $path };
		}
		elsif ($type eq 'ask') {
			# The prompt says "after the tone", so there is one. A flow with no
			# prompt asked nothing: it neither beeps nor records a name, which is
			# what a flow seeded before the editor existed has always done.
			my $path = $clips->{'prompt'} || '';
			next unless length $path;
			push @steps, { type => 'ask', key => 'prompt', play => $path };
			push @steps, { type => 'ask', key => 'cue', tone => 1, hz => 660, ms => 400 };
			push @steps, { type => 'ask', key => 'name', record => 1 };
		}
		elsif ($type eq 'keypad') {
			my $text = defined $raw->{'text'} ? $raw->{'text'} : '';
			$text =~ s/^\s+|\s+$//g;
			$text = substr($text, 0, 400);
			# the machine with the voice renders the menu, once, at arm time
			my $path = $clips->{ 'keypad:' . $i } || '';
			if (!length $path && length $text) {
				$path = eval {
					require JawnOS::Sco::Render;
					&JawnOS::Sco::Render::render($text, $voice);
				} || '';
			}
			my %digits;
			if (ref $raw->{'digits'} eq 'HASH') {
				foreach my $digit (keys %{ $raw->{'digits'} }) {
					next unless defined $digit && $digit =~ /^[0-9*#]$/;
					my $target = $raw->{'digits'}->{$digit};
					next unless defined $target && $target =~ /^[a-z0-9_]{1,30}$/;
					$digits{$digit} = $target;
				}
			}
			my $timeout = $raw->{'timeout_ms'};
			$timeout = 5000
				unless defined $timeout && $timeout =~ /^\d+$/ && $timeout >= 200 && $timeout <= 60000;
			push @steps, {
				type => 'keypad',
				key => 'keypad',
				play => $path,
				text => $text,
				timeout_ms => int($timeout),
				digits => \%digits,
			};
		}
		elsif ($type eq 'hold') {
			my $seconds = $raw->{'seconds'};
			$seconds = (defined $seconds && $seconds =~ /^\d+$/) ? int($seconds) : 0;
			my $step = &_hold_step($hold, $seconds);
			push @steps, $step if $step;
		}
		elsif ($type eq 'voicemail') {
			push @steps, &_voicemail_steps($clips->{'voicemail'} || '', $voicemail_seconds);
		}
		elsif ($type eq 'after') {
			# the legacy tail: the music, the house's voicemail, or nothing
			if ($after eq 'voicemail') {
				push @steps, &_voicemail_steps($clips->{'voicemail'} || '', $voicemail_seconds);
			}
			elsif ($after eq 'hold') {
				my $step = &_hold_step($hold, 0);
				push @steps, $step if $step;
			}
		}
	}
	return \@steps;
}

# A hold step, or nothing when the house has music to play. A timed hold with
# no music is still a hold: the caller waits the seconds it says and the plan
# moves on, rather than skipping the wait.
sub _hold_step {
	my ($choice, $seconds) = @_;
	$seconds ||= 0;
	return unless defined $choice && length $choice && lc($choice) ne 'none';
	require JawnOS::Sco::Hold;
	my $list = &JawnOS::Sco::Hold::playlist($choice);
	return unless @{$list} || $seconds > 0;
	return {
		type => 'hold',
		key => 'hold',
		hold => 1,
		list => $list,
		shuffle => (lc($choice) eq 'shuffle' ? 1 : 0),
		seconds => $seconds,
	};
}

# The greeting (when the flow has one) and a recorded message. A message is
# longer than a name: the flow's own length (five minutes unless it says
# otherwise), ended by a pause, and it does not need a name's short speech floor.
sub _voicemail_seconds {
	my ($value) = @_;
	return 300 unless defined $value && $value =~ /^\d+$/;
	$value = int($value);
	return 15 if $value < 15;
	return 1800 if $value > 1800;
	return $value;
}

sub _voicemail_steps {
	my ($greeting, $seconds) = @_;
	$seconds = &_voicemail_seconds($seconds);
	my @out;
	push @out, { type => 'voicemail', key => 'voicemail', play => $greeting }
		if defined $greeting && length $greeting;
	push @out, {
		type => 'voicemail',
		key => 'message',
		record => 1,
		kind => 'voicemail',
		opts => { ms => $seconds * 1000, silence_ms => 3000, min_ms => 1000 },
	};
	return @out;
}

# One flow, ready to run: its words resolved to clips, its steps compiled.
sub _flow {
	my ($key, $def, $prefix) = @_;
	my %flow = (
		key => $key,
		name => (defined $def->{'name'} && length $def->{'name'}) ? $def->{'name'} : $key,
		voice => (defined $def->{'voice'} ? $def->{'voice'} : ''),
		hold => (defined $def->{'hold'} ? $def->{'hold'} : ''),
		after => lc(defined $def->{'after'} ? $def->{'after'} : 'hold'),
		voicemail_seconds => &_voicemail_seconds($def->{'voicemail_seconds'}),
		clips => (ref $def->{'clips'} eq 'HASH' ? { %{ $def->{'clips'} } } : {}),
	);
	$flow{'steps'} = [
		(ref $prefix eq 'ARRAY' ? @{$prefix} : ()),
		@{ &flow_steps({ %flow, steps => $def->{'steps'} }) },
	];
	return \%flow;
}

# %args: peer => BDADDR (optional pin), flows => { key => def }, words/clips/
# voice/hold/after for the older single-flow arm, record => { ms,
# silence_ms, min_ms }.
# `ms` is the ceiling for the whole clip (including the wait for the caller), and
# the helper keeps the clip open until it hears a name and then a pause;
# `min_ms` is how much speech has to have been heard before a pause may end it.
# The legacy plan is greeting, name prompt, record the name, thanks, then the
# hold music while somebody decides to pick up - in that order; a flow with
# `steps` says what it wants in its own words.
sub arm {
	my ($self, %args) = @_;
	return { ok => 0, error => 'a call is already up' }
		if $self->{'state'} eq 'in_call';
	# a second arm while one is starting would leave the first helper holding the
	# SCO listener and its parent's pipe gone: the helper then exits unreaped and
	# the next call finds a gateway that only looks armed
	return { ok => 1, state => 'starting' } if $self->{'state'} eq 'starting';
	$self->cancel() if $self->{'state'} ne 'idle' || $self->{'pid'};
	$self->{'caller'} = {};
	# a call whose line dropped ends through the `closed` event, which does not
	# pass through end_call; the next arm must not inherit its hold
	$self->{'holding'} = 0;
	$self->{'hold_at'} = 0;
	$self->{'hold_paused'} = 0;
	$self->{'stopping_hold'} = 0;
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
	# a diagnostic tone: proof that the uplink reaches the caller, with nothing
	# else in the way
	my @prefix;
	my $tone = $args{'tone'};
	if (ref $tone eq 'HASH') {
		push @prefix, {
			tone => 1,
			hz => ($tone->{'hz'} && $tone->{'hz'} =~ /^\d+$/) ? int($tone->{'hz'}) : 660,
			ms => ($tone->{'ms'} && $tone->{'ms'} =~ /^\d+$/) ? int($tone->{'ms'}) : 1200,
		};
	}

	# One step list per flow. The caller's flow is chosen when the link is
	# accepted (a `flow` line names it); the default here is what a call with no
	# word from the phone hears.
	my %flows;
	my $given = (ref $args{'flows'} eq 'HASH' && %{ $args{'flows'} }) ? $args{'flows'} : undef;
	if ($given) {
		foreach my $key (sort keys %{$given}) {
			next unless defined $key && $key =~ /^[a-z0-9_]{1,30}$/;
			my $def = $given->{$key};
			next unless ref $def eq 'HASH';
			$flows{$key} = &_flow($key, $def, \@prefix);
		}
	}
	if (!%flows) {
		# the older arm: one plan spoken from the words it was given
		my $words = ref $args{'words'} eq 'HASH' ? $args{'words'} : {};
		my %def = (
			name => 'Receptionist',
			voice => $args{'voice'} || '',
			steps => $args{'steps'},
			clips => $clips,
			hold => (defined $args{'hold'} ? $args{'hold'} : ''),
			after => (defined $args{'after'} ? $args{'after'} : 'hold'),
			map { $_ => ($words->{$_} || '') } qw(greeting prompt thanks voicemail),
		);
		$flows{'receptionist'} = &_flow('receptionist', \%def, \@prefix);
	}

	# Which flow a call that names none belongs to. The phone resolves the
	# caller's bucket to a flow key and says so; when it could not, the gateway
	# falls back to what it has, preferring the unknown bucket's flow.
	my $default;
	if (exists $args{'default_flow'} || defined $args{'flow'}) {
		$default = exists $args{'default_flow'} ? $args{'default_flow'} : $args{'flow'};
		$default = '' unless defined $default;
		# a house that named a flow it did not arm still hears the receptionist
		$default = ($flows{'receptionist'} ? 'receptionist' : '')
			if length $default && !$flows{$default};
	}
	else {
		$default = $flows{'unknown'} ? 'unknown'
			: $flows{'receptionist'} ? 'receptionist'
			: ((sort keys %flows)[0] || '');
	}

	$self->{'flows'} = \%flows;
	$self->{'default_flow'} = $default;
	$self->{'flow'} = $default;
	$self->{'flow_started'} = 0;
	$self->{'steps'} = $default ? [ map { { %$_ } } @{ $flows{$default}->{'steps'} } ] : [];
	$self->{'step_at'} = -1;
	$self->{'hold_until'} = 0;
	$self->{'keypad_open'} = 0;
	$self->_clear_keypad_timer();
	$self->_clear_hold_timer();
	# the record options belong to the plan, not to one transport: pipe mode
	# returns below, and used to leave them unset, so a screened call ran the
	# helper's 30 s / 1.8 s defaults instead of what the phone asked for
	$self->{'record_opts'} = $args{'record'} || {};
	if ($self->pipe_mode()) {
		require JawnOS::Sco::Mixer;
		$self->{'mixer'} = JawnOS::Sco::Mixer->new();
		$self->{'peer'} = $args{'peer'} || $self->peer_address();
		$self->{'call_id'} = $args{'call_id'} || &call_id();
		$self->_start_transcript();
		# A pair that is already up when we arm belongs to a call that has
		# already had its plan. The phone's Hands-Free streams outlive the plan,
		# and Reception arms again as soon as a finished plan lets go of its
		# line - so the pair this arm sees is the call that just heard its
		# thanks, not a new caller. Hold it until it goes.
		my $up = $self->{'mixer'}->call_streams($self->{'peer'});
		$self->{'held'} = ($up->{'sink_input'} && $up->{'source_output'}) ? 1 : 0;
		$self->{'last_error'} = '';
		$self->{'last_event'} = 'waiting for a call';
		$self->{'state'} = 'waiting';
		$self->{'gone'} = 0;
		$self->{'accepted_at'} = 0;
		$self->{'done_at'} = 0;
		$self->write_status();
		$self->watch_streams();
		$self->watch_call();
		return { ok => 1, state => 'waiting', call_id => $self->{'call_id'} };
	}
	$self->{'peer'} = $args{'peer'} || '';
	$self->{'call_id'} = $args{'call_id'} || &call_id();
	$self->_start_transcript();
	$self->{'last_error'} = '';
	$self->{'last_event'} = '';
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

# ---- which flow this call belongs to ------------------------------------
#
# The phone knows the caller (a contact, a stranger, a blocked number) and the
# house maps that to a flow; this side only hears the result. The word can
# arrive before the link is accepted - the phone posts it just before it
# answers - so it is held as pending and consumed at `accepted`. A word that
# arrives after the plan has started changes nothing, because a caller is
# halfway through the old flow and starting again would repeat a greeting; a
# late one still picks the flow if no step has run yet.
sub set_flow {
	my ($self, $key) = @_;
	$key = defined $key ? $key : '';
	$key =~ s/^\s+|\s+$//g;
	$key = '' unless $key =~ /^[a-z0-9_]{1,30}$/;
	if (($self->{'state'} || '') eq 'in_call' && $self->{'flow_started'}) {
		return { ok => 1, flow => $self->{'flow'}, ignored => 'the plan has started' };
	}
	$self->{'pending_flow'} = $key;
	# a call that is up with no plan yet (no flow was armed for it) can still
	# be given the flow the phone means
	$self->start_flow($key)
		if ($self->{'state'} || '') eq 'in_call' && !$self->{'flow_started'};
	$self->write_status();
	return { ok => 1, flow => $key, state => $self->{'state'} || 'idle' };
}

# Start (or restart) a flow: its steps from the top, and no timers left over
# from the one the call was in. An empty or unknown key runs no plan at all,
# which is what a bucket mapped to `ring` or `reject` means.
sub start_flow {
	my ($self, $key) = @_;
	$key = '' unless defined $key;
	my $flow = length $key ? $self->{'flows'}->{$key} : undef;
	$self->_clear_keypad_timer();
	$self->_clear_hold_timer();
	$self->{'keypad_open'} = 0;
	$self->{'flow'} = $flow ? $key : '';
	$self->{'flow_started'} = 0;
	$self->{'steps'} = $flow ? [ map { { %$_ } } @{ $flow->{'steps'} } ] : [];
	$self->{'step_at'} = -1;
	$self->{'holding'} = 0;
	$self->{'hold_at'} = 0;
	$self->{'hold_until'} = 0;
	$self->{'hold_paused'} = 0;
	$self->{'stopping_hold'} = 0;
	$self->write_status();
	$self->_advance() if @{ $self->{'steps'} };
	return $flow ? 1 : 0;
}

# `{cmd:'voicemail'}` - the panel's Send to voicemail. The music stops, the
# flow's greeting (or the words the person typed) plays, and the message is
# recorded now instead of after the rest of the flow.
sub to_voicemail {
	my ($self, %args) = @_;
	return { ok => 0, error => 'no call is up' } unless ($self->{'state'} || '') eq 'in_call';
	my $flow = length($self->{'flow'} || '') ? $self->{'flows'}->{ $self->{'flow'} } : undef;
	my $greeting = ($flow && $flow->{'clips'}) ? ($flow->{'clips'}->{'voicemail'} || '') : '';
	my $text = defined $args{'text'} ? $args{'text'} : '';
	$text =~ s/^\s+|\s+$//g;
	if (length $text) {
		$text = substr($text, 0, 400);
		my $raw = eval {
			require JawnOS::Sco::Render;
			&JawnOS::Sco::Render::render($text, ($flow && $flow->{'voice'}) || '');
		} || '';
		$greeting = $raw if $raw;
	}
	# the words are the house's, so they join the transcript both sides read
	if (length $text) {
		my $line = { who => 'house', text => $text, at => time, ms => 0 };
		push @{ $self->{'transcript'} }, $line;
		shift @{ $self->{'transcript'} } while @{ $self->{'transcript'} } > 200;
		$self->_write_transcript_line($line);
		$self->_push_transcript({ line => $line });
	}
	$self->_clear_keypad_timer();
	$self->_clear_hold_timer();
	$self->{'keypad_open'} = 0;
	if ($self->{'holding'}) {
		# a stop the house asked for is not the end of the call
		$self->{'stopping_hold'} = 1;
		$self->_send(cmd => 'stop');
	}
	$self->{'holding'} = 0;
	$self->{'hold_at'} = 0;
	$self->{'hold_until'} = 0;
	$self->{'hold_paused'} = 0;
	$self->{'steps'} = [ &_voicemail_steps($greeting, ($flow ? $flow->{'voicemail_seconds'} : undef)) ];
	$self->{'step_at'} = -1;
	$self->{'flow_started'} = 0;
	$self->{'last_event'} = 'voicemail';
	$self->write_status();
	$self->_advance();
	return { ok => 1, flow => $self->{'flow'}, step => 'voicemail' };
}

# `{cmd:'hangup'}` - the plan and the call are over.
sub hangup {
	my ($self) = @_;
	return { ok => 0, error => 'no call is up' } if ($self->{'state'} || '') eq 'idle';
	my $call = $self->{'call_id'};
	$self->end_call('hung up');
	return { ok => 1, call_id => $call };
}

sub _clear_keypad_timer {
	my ($self) = @_;
	if (my $timer = delete $self->{'keypad_timer'}) {
		eval { Mojo::IOLoop->remove($timer) };
	}
	return 1;
}

sub _clear_hold_timer {
	my ($self) = @_;
	if (my $timer = delete $self->{'hold_timer'}) {
		eval { Mojo::IOLoop->remove($timer) };
	}
	return 1;
}

# Wait until the gateway's own two streams appear (the call has started), move
# them onto our devices, and only then start the audio helper.
#
# The pair is moved whether or not it is new. A phone's Hands-Free nodes
# outlive the call they were made for, and PipeWire remembers the device an
# application used last, so the pair can come back sitting on the laptop's own
# sink and microphone - which is the room on the caller's ear and silence in
# our recording. Moving them again costs nothing.
sub watch_streams {
	my ($self) = @_;
	return if $self->{'watcher'};
	$self->{'watcher'} = Mojo::IOLoop->recurring(0.3 => sub {
		return unless $self->{'state'} eq 'waiting';
		my $mixer = $self->{'mixer'} or return;
		my $streams = $mixer->call_streams($self->{'peer'});
		unless ($streams->{'sink_input'} && $streams->{'source_output'}) {
			# the pair has gone: what appears next is a new call
			$self->{'held'} = 0;
			return;
		}
		# ...and a pair that was already there when we armed has had its plan,
		# so it is not greeted again. The `line` word speaks to a silent caller
		# the moment the pair appears, so waiting for audio is no longer a
		# guard against a second plan.
		return if $self->{'held'};
		$mixer->attach($self->{'peer'});
		my @cmd = ( $self->helper_command(), '--pipe-in', $mixer->capture_command(),
			'--pipe-out', $mixer->playback_command() );
		unless ($self->_spawn(@cmd)) {
			$self->{'last_error'} = 'the audio helper would not start';
			return;
		}
		# the pair is the call: say so, so the plan can start before the
		# caller speaks (the helper's own gate waits for a frame that carries
		# signal, which someone waiting to be greeted never sends)
		$self->_send({ cmd => 'line' });
		$self->{'last_event'} = 'attached';
		$self->{'state'} = 'armed';
		$self->{'since'} = time;
		$self->write_status();
	});
	return 1;
}

# One more piece of state a call has: whether it is still being fed. While it
# is, the pair is moved onto our devices again once a second (a stream the
# phone replaces, or one PipeWire re-routes, does not take the old move with
# it). When a *finished* plan's line stops being fed, the call is over: the
# helper is put down and the gateway goes idle, which is what lets Reception
# arm for the next call without ever speaking a second plan into a dying one.
	sub watch_call {
	my ($self) = @_;
	return if $self->{'call_watcher'};
	$self->{'call_watcher'} = Mojo::IOLoop->recurring(1 => sub {
		my $state = $self->{'state'} || '';
		return unless $state eq 'armed' || $state eq 'in_call' || $state eq 'done';
		my $mixer = $self->{'mixer'} or return;
		my $streams = $mixer->call_streams($self->{'peer'});
		if (!$streams->{'sink_input'} || !$streams->{'source_output'}) {
			# a call that re-routes its Bluetooth audio drops the pair for a
			# moment, so only a gap that lasts is the end of the call
			$self->{'gone'} = ($self->{'gone'} || 0) + 1;
			$self->end_call('streams gone') if $self->{'gone'} >= 3;
			return;
		}
		$self->{'gone'} = 0;
		# The pair arrives in pieces - the phone's capture before its playback,
		# or a stream re-created when the link re-establishes - so move again
		# every second rather than trusting the one move made at attach.
		$mixer->attach($self->{'peer'});
		my $why = &call_over(
			$state,
			($self->{'done_at'} ? time - $self->{'done_at'} : undef),
			($self->{'accepted_at'} ? time - $self->{'accepted_at'} : undef),
			$self->{'holding'},
		);
		# a bridged call belongs to the person, not to the plan's timer
		$self->end_call($why) if length $why && !$self->{'rtc_up'};
	});
	return 1;
}

# The plan is over and the line it was spoken into is quiet: end the call.
	sub end_call {
	my ($self, $why) = @_;
	$self->{'quiet'} = 0;
	$self->{'gone'} = 0;
	$self->{'held'} = 0;
	$self->{'holding'} = 0;
	$self->{'hold_at'} = 0;
	$self->{'hold_paused'} = 0;
	$self->{'stopping_hold'} = 0;
	$self->{'hold_until'} = 0;
	$self->{'accepted_at'} = 0;
	$self->{'done_at'} = 0;
	$self->{'steps'} = [];
	$self->{'step_at'} = -1;
	$self->{'flow'} = '';
	$self->{'flow_started'} = 0;
	$self->{'keypad_open'} = 0;
	$self->_clear_keypad_timer();
	$self->_clear_hold_timer();
	return 1 if $self->{'state'} eq 'idle';
	$self->{'state'} = 'idle';
	$self->{'since'} = time;
	$self->{'last_event'} = $why || 'line idle';
	$self->_push_screen('ended');
	$self->_send(cmd => 'quit');
	$self->_reap();
	$self->_stop_transcript();
	$self->_stop_rtc();
	$self->write_status();
	return 1;
}

## A plan that has finished is done with the line
##
## The caller has heard the thanks; the phone is only holding the call until its
## own forty-second limit, so the gateway can be free for the next call a few
## seconds later. It used to wait for that limit, and a call arriving in the
## three-quarters of a minute that followed found a gateway still busy - the
## caller heard silence until the next arm. Arming over the finished call cannot
## greet it twice: a pair that is already up when the gateway arms is held (see
## arm/watch_streams), because the `line` word greets a silent caller as soon as
## the pair appears and the helper no longer waits for audio.
sub call_over {
	my ($state, $since_done, $since_accepted, $holding) = @_;
	return 'plan done' if $state eq 'done'
		&& defined $since_done && $since_done >= 4;
	if ($holding) {
		# The house's own music keeps the line up while somebody decides. The
		# phone's limit is what ends a hold nobody answers; this is the backstop
		# for a phone that never lets go, so a stuck line cannot hold forever.
		# the phone's own limit ends a hold nobody answers; this only outlives it
		return 'hold limit' if defined $since_accepted && $since_accepted >= 660;
		return '';
	}
	# a step that never ends must not hold the line forever either
	return 'call limit' if defined $since_accepted && $since_accepted >= 42;
	return '';
}

sub stop_watch {
	my ($self) = @_;
	foreach my $key (qw(watcher call_watcher)) {
		if (my $w = delete $self->{$key}) {
			Mojo::IOLoop->remove($w);
		}
	}
	return 1;
}

sub _spawn {
	my ($self, @cmd) = @_;
	push @cmd, '--tee', $self->{'tee'} if $self->{'tee'};
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

# ---- the live transcript ------------------------------------------------
#
# The caller's words are the other half of a screening, and a person watching
# the Phone pane should read them while the call is up, not after. The helper
# copies every frame of the caller's voice into a FIFO (--tee); a Python child
# segments it and asks Vosk for a sentence at a time. This side only routes:
# it keeps the lines in the status (so a pane that opens late catches up), in a
# JSONL file beside the gateway (so the Chat app can file them later), and on
# the phone's websocket (so the bubbles appear as they are said).
#
# A transcript is never required for a call: no Vosk, no model, or a streamer
# that dies leaves the plan running and the pane saying why there is no text.

sub _start_transcript {
	my ($self) = @_;
	$self->{'transcript'} = [];
	$self->{'partial'} = '';
	$self->{'transcript_engine'} = '';
	$self->{'transcript_note'} = '';
	unless (eval { &subs::vosk_available() }) {
		$self->{'transcript_note'} = 'Vosk is not installed on this machine';
		return 0;
	}
	my $python   = eval { &subs::vosk_python() } || '';
	my $model    = eval { &subs::vosk_model_dir() } || '';
	my $streamer = eval { &subs::vosk_streamer() } || '';
	unless (-x $python && length $model && -f $streamer) {
		$self->{'transcript_note'} = 'Vosk is installed but its streamer or model is missing';
		return 0;
	}
	my $dir = $self->{'dir'} . '/transcripts';
	make_path($dir) unless -d $dir;
	my $fifo = $dir . '/' . $self->{'call_id'} . '.fifo';
	unlink $fifo;
	my $made = POSIX::mkfifo($fifo, 0600);
	if ($made != 0) {
		$self->{'transcript_note'} = "could not make the transcript FIFO: $!";
		return 0;
	}
	$self->{'tee'} = $fifo;
	$self->{'transcript_file'} = $dir . '/' . $self->{'call_id'} . '.jsonl';
	return 1 if $self->_spawn_transcript(
		$python, $streamer, '--fifo', $fifo, '--model', $model, '--rate', 8000
	);
	unlink $fifo;
	delete $self->{'tee'};
	return 0;
}

sub _spawn_transcript {
	my ($self, @cmd) = @_;
	my ($out, $in);
	my $pid = eval { IPC::Open2::open2($out, $in, @cmd) };
	unless ($pid) {
		$self->{'transcript_note'} = 'the transcript reader would not start';
		return 0;
	}
	$self->{'transcript_pid'} = $pid;
	$self->{'transcript_in'} = $in;
	$self->{'transcript_out'} = $out;
	$self->{'transcript_buffer'} = '';
	$in->autoflush(1);
	my $ok = eval {
		$out->blocking(0);
		my $stream = Mojo::IOLoop::Stream->new($out)->timeout(0);
		$stream->on(read => sub {
			my ($stream, $bytes) = @_;
			$self->{'transcript_buffer'} .= $bytes;
			while ($self->{'transcript_buffer'} =~ s/^(.*?)\n//) {
				my $line = $1;
				next unless $line =~ /\S/;
				my $event = eval { decode_json($line) };
				next unless ref $event eq 'HASH';
				$self->_transcript_event($event);
			}
		});
		$stream->on(close => sub { delete $self->{'transcript_stream'} });
		$stream->start;
		$self->{'transcript_stream'} = $stream;
		1;
	};
	unless ($ok) {
		$self->{'transcript_note'} = "the transcript reader could not be read: $@";
		$self->_stop_transcript();
		return 0;
	}
	return 1;
}

sub _transcript_event {
	my ($self, $event) = @_;
	my $name = $event->{'event'} || '';
	if ($name eq 'ready') {
		$self->{'transcript_engine'} = 'vosk';
		$self->write_status();
		return 1;
	}
	if ($name eq 'partial') {
		my $text = $event->{'text'} || '';
		return 1 unless length $text;
		$self->{'partial'} = $text;
		$self->write_status();
		$self->_push_transcript({ partial => $text });
		return 1;
	}
	if ($name eq 'line') {
		my $text = $event->{'text'} || '';
		return 1 unless length $text;
		$self->{'partial'} = '';
		my $line = {
			who => 'caller',
			text => $text,
			at => time,
			ms => 0 + ($event->{'ms'} || 0),
		};
		push @{ $self->{'transcript'} }, $line;
		shift @{ $self->{'transcript'} } while @{ $self->{'transcript'} } > 200;
		$self->_write_transcript_line($line);
		$self->write_status();
		$self->_push_transcript({ line => $line });
		return 1;
	}
	if ($name eq 'error') {
		$self->{'transcript_note'} = $event->{'message'} || 'the transcript reader failed';
		$self->write_status();
	}
	return 1;
}

sub _write_transcript_line {
	my ($self, $line) = @_;
	my $file = $self->{'transcript_file'} or return 0;
	my $ok = eval {
		open(my $fh, '>>', $file) or die "open $file: $!";
		print {$fh} encode_json($line) . "\n";
		close $fh;
		1;
	};
	$self->{'transcript_note'} = "could not save the transcript: $@" unless $ok;
	return $ok ? 1 : 0;
}

# # A screening is the house's business, not one pane's: every open window hears
# that the line was picked up and that it is free again, and draws the floating
# panel from the status. The tab channel is the one every window keeps open and
# the one the padlock gate does not hold back.
sub _push_screen {
	my ($self, $state) = @_;
	return 0 unless defined &Websocket::send;
	eval { &Websocket::send('tab', {
		type => 'sco_screen',
		state => $state,
		call_id => $self->{'call_id'},
		peer => $self->{'peer'},
		caller => $self->{'caller'} || {},
	}) };
	return 1;
}

sub _push_transcript {
	my ($self, $what) = @_;
	return 0 unless defined &Websocket::send;
	my $msg = {
		type => 'sco_transcript',
		call_id => $self->{'call_id'},
		peer => $self->{'peer'},
		%{ $what || {} },
	};
	eval { &Websocket::send('phone', $msg) };
	return 1;
}

sub _stop_transcript {
	my ($self) = @_;
	my $pid = delete $self->{'transcript_pid'};
	foreach my $key (qw(transcript_stream transcript_in transcript_out)) {
		my $thing = delete $self->{$key};
		next unless $thing;
		eval { $thing->close };
	}
	$self->{'transcript_buffer'} = '';
	if (my $fifo = delete $self->{'tee'}) { unlink $fifo; }
	return 1 unless $pid;
	my $tries = 0;
	my $gone = 0;
	while ($tries++ < 10) {
		my $done = waitpid($pid, WNOHANG);
		if ($done == $pid) { $gone = 1; last; }
		select(undef, undef, undef, 0.02);
	}
	unless ($gone) {
		kill 'TERM', $pid;
		waitpid($pid, 0);
	}
	return 1;
}


# ---- the WebRTC bridge ---------------------------------------------------
#
# "Connect me" hands the call to the device that pressed it: the caller's voice
# goes out as an Opus track, and the person's microphone comes back into
# jawn_prompt, which is the caller's ear. The media is one process
# (scripts/rtc_bridge.py, aiortc) spawned per bridge; this side only routes the
# offer/answer/ICE lines between that process and the phone's websocket.
#
# Signalling comes back through the same manager: the browser posts to
# /manager/sco/rtc, the route calls this daemon on its socket, and the bridge's
# answer and candidates are pushed to the phone channel. One port, one session.
#
# A bridged call is not the plan's to end: the four-second "plan done" rule and
# the forty-two-second ceiling describe a screening nobody joined.

sub rtc {
	my ($self, $request) = @_;
	my $action = ref $request eq 'HASH' ? ($request->{'action'} || '') : '';
	return $self->_start_rtc() if $action eq 'start';
	return $self->_rtc_signal($request->{'message'}) if $action eq 'signal';
	return $self->_stop_rtc() if $action eq 'stop';
	return { ok => 0, error => 'unknown bridge action' };
}

sub _start_rtc {
	my ($self) = @_;
	return { ok => 0, error => 'the WebRTC bridge needs the virtual handset (sco_pipe)' }
		unless $self->pipe_mode();
	return { ok => 0, error => 'no call is up' }
		unless $self->{'state'} =~ /^(?:armed|in_call|done)$/;
	return { ok => 1, state => $self->{'rtc'}->{'state'} } if $self->{'rtc_pid'};
	my $python = eval { &subs::vosk_python() } || '';
	my $script = eval { &subs::rtc_bridge() } || '';
	unless ($python && -x $python && $script && -f $script) {
		$self->{'rtc'} = { state => 'unavailable', error => 'the WebRTC bridge is not installed on this machine' };
		$self->write_status();
		return { ok => 0, error => $self->{'rtc'}->{'error'} };
	}
	require JawnOS::Sco::Mixer;
	my $mixer = $self->{'mixer'} || JawnOS::Sco::Mixer->new();
	# the plan must not talk over the person who just joined
	$self->_send(cmd => 'stop');
	$self->{'rtc'} = { state => 'starting', error => '' };
	$self->{'rtc_up'} = 1;
	unless ($self->_spawn_rtc($python, $script,
		'--in-cmd', $mixer->bridge_capture_command(),
		'--out-cmd', $mixer->bridge_playback_command())) {
		$self->{'rtc'} = { state => 'failed', error => $self->{'rtc_note'} || 'the bridge would not start' };
		$self->{'rtc_up'} = 0;
		$self->write_status();
		return { ok => 0, error => $self->{'rtc'}->{'error'} };
	}
	$self->write_status();
	return { ok => 1, state => 'starting' };
}

sub _spawn_rtc {
	my ($self, @cmd) = @_;
	my ($out, $in);
	my $pid = eval { IPC::Open2::open2($out, $in, @cmd) };
	unless ($pid) {
		$self->{'rtc_note'} = 'the bridge would not start';
		return 0;
	}
	$self->{'rtc_pid'} = $pid;
	$self->{'rtc_in'} = $in;
	$self->{'rtc_out'} = $out;
	$self->{'rtc_buffer'} = '';
	$in->autoflush(1);
	my $ok = eval {
		$out->blocking(0);
		my $stream = Mojo::IOLoop::Stream->new($out)->timeout(0);
		$stream->on(read => sub {
			my ($stream, $bytes) = @_;
			$self->{'rtc_buffer'} .= $bytes;
			while ($self->{'rtc_buffer'} =~ s/^(.*?)\n//) {
				my $line = $1;
				next unless $line =~ /\S/;
				my $event = eval { decode_json($line) };
				next unless ref $event eq 'HASH';
				$self->_rtc_event($event);
			}
		});
		$stream->on(close => sub {
			my $state = $self->{'rtc'}->{'state'} || '';
			$self->{'rtc'}->{'state'} = 'closed' unless $state =~ /^(?:failed|closed)$/;
			$self->{'rtc_up'} = 0;
		});
		$stream->start;
		$self->{'rtc_stream'} = $stream;
		1;
	};
	unless ($ok) {
		$self->{'rtc_note'} = "the bridge could not be read: $@";
		$self->_stop_rtc();
		return 0;
	}
	return 1;
}

sub _rtc_signal {
	my ($self, $message) = @_;
	return { ok => 0, error => 'no bridge is up' } unless $self->{'rtc_in'};
	my $json = eval { encode_json($message || {}) };
	return { ok => 0, error => 'bad signalling message' } unless defined $json;
	my $ok = eval {
		print { $self->{'rtc_in'} } $json . "\n";
		$self->{'rtc_in'}->flush;
		1;
	};
	return { ok => $ok ? 1 : 0, error => $ok ? '' : 'the bridge is gone' };
}

sub _rtc_event {
	my ($self, $event) = @_;
	my $name = $event->{'event'} || '';
	if ($name eq 'ready') {
		$self->{'rtc'}->{'state'} = 'ready';
		$self->write_status();
		return 1;
	}
	if ($name eq 'answer') {
		$self->{'rtc'}->{'state'} = 'answering';
		$self->write_status();
		$self->_push_rtc({ answer => $event->{'sdp'}, sdp_type => $event->{'type'} });
		return 1;
	}
	if ($name eq 'ice') {
		$self->_push_rtc({ ice => $event->{'candidate'} }) if ref $event->{'candidate'} eq 'HASH';
		return 1;
	}
	if ($name eq 'state') {
		my $state = $event->{'state'} || '';
		$self->{'rtc'}->{'state'} = $state;
		$self->{'rtc_up'} = ($state eq 'connected' || $state eq 'connecting') ? 1 : 0;
		$self->write_status();
		$self->_push_rtc({ state => $state });
		return 1;
	}
	if ($name eq 'error') {
		$self->{'rtc'}->{'error'} = $event->{'error'} || 'the bridge failed';
		$self->{'rtc'}->{'state'} = 'failed';
		$self->write_status();
		$self->_push_rtc({ error => $self->{'rtc'}->{'error'} });
	}
	return 1;
}

sub _push_rtc {
	my ($self, $what) = @_;
	return 0 unless defined &Websocket::send;
	my $msg = {
		type => 'sco_rtc',
		call_id => $self->{'call_id'},
		%{ $what || {} },
	};
	eval { &Websocket::send('phone', $msg) };
	return 1;
}

sub _stop_rtc {
	my ($self) = @_;
	my $pid = delete $self->{'rtc_pid'};
	if ($self->{'rtc_in'}) {
		eval { print { $self->{'rtc_in'} } "{\"cmd\":\"quit\"}\n"; $self->{'rtc_in'}->flush; };
	}
	foreach my $key (qw(rtc_stream rtc_in rtc_out)) {
		my $thing = delete $self->{$key};
		next unless $thing;
		eval { $thing->close };
	}
	$self->{'rtc_buffer'} = '';
	$self->{'rtc_up'} = 0;
	$self->{'rtc'}->{'state'} = 'closed' if $self->{'rtc'};
	return 1 unless $pid;
	my $tries = 0;
	my $gone = 0;
	while ($tries++ < 10) {
		my $done = waitpid($pid, WNOHANG);
		if ($done == $pid) { $gone = 1; last; }
		select(undef, undef, undef, 0.02);
	}
	unless ($gone) {
		kill 'TERM', $pid;
		waitpid($pid, 0);
	}
	return 1;
}

# ---- the messages a voicemail flow left ----------------------------------
# The index beside the kept recordings is the list that outlives a restart; the
# pane asks the gateway for it, because the files are on this machine.
sub voicemail_list {
	my ($self) = @_;
	my $index = $self->{'dir'} . '/kept/index.jsonl';
	return [] unless -s $index;
	my @out;
	if (open(my $fh, '<', $index)) {
		while (my $line = <$fh>) {
			my $e = eval { decode_json($line) };
			next unless ref $e eq 'HASH' && ($e->{'kind'} || '') eq 'voicemail';
			next unless length($e->{'file'} || '');
			push @out, {
				at => $e->{'at'} || 0,
				ms => $e->{'ms'} || 0,
				file => $e->{'file'},
				name => ($e->{'file'} =~ m{([^/]+)$} ? $1 : $e->{'file'}),
				call_id => $e->{'call_id'} || '',
				# the Chat note the call's words were filed into, so the pane can
				# open the transcript beside the recording
				note_uuid => $e->{'note_uuid'} || '',
				appt_uuid => $e->{'appt_uuid'} || '',
			};
		}
		close $fh;
	}
	@out = sort { ($b->{'at'} || 0) <=> ($a->{'at'} || 0) } @out;
	splice(@out, 30) if @out > 30;
	return \@out;
}

# ---- the hold, on demand -------------------------------------------------
# The app's call screen has a Hold button: the caller hears the house's music
# while the person does something else, and the same button takes them off it.
# A stop the house asked for is not the end of the call (the helper's `stopped`
# is read that way elsewhere), and the call stays a held call so the plan's own
# limit does not end it while the person is thinking.
sub set_hold {
	my ($self, %args) = @_;
	return { ok => 0, error => 'no call is up' } unless ($self->{'state'} || '') eq 'in_call';
	my $on = $args{'on'} ? 1 : 0;
	unless ($on) {
		$self->{'hold_paused'} = 1;
		if ($self->{'holding'}) { $self->{'stopping_hold'} = 1; $self->_send(cmd => 'stop'); }
		$self->{'last_event'} = 'hold off';
		$self->write_status();
		return { ok => 1, hold => 0 };
	}
	my $step = $self->{'steps'}->[ $self->{'step_at'} ] || {};
	my $list = $step->{'hold'} ? ($step->{'list'} || []) : [];
	return { ok => 0, error => 'this call has no hold music' } unless @{$list};
	$self->{'holding'} = 1;
	$self->{'hold_paused'} = 0;
	$self->{'hold_at'} = 0;
	$self->_hold_play_next();
	return { ok => 1, hold => 1 };
}

# ---- the house speaks to the caller -------------------------------------
# A person watching a screening can type while the caller waits on the music.
# The message is rendered here (this is the machine with the voice) and plays
# over whatever was playing; its own `played` makes the hold move on, so the
# music resumes by itself. The words join the transcript, so both sides see
# what was said.
sub say_to_caller {
	my ($self, %args) = @_;
	my $text = $args{'text'} || '';
	$text =~ s/^\s+|\s+$//g;
	return { ok => 0, error => 'nothing to say' } unless length $text;
	$text = substr($text, 0, 400);
	return { ok => 0, error => 'no call is up' } unless ($self->{'state'} || '') eq 'in_call';
	require JawnOS::Sco::Render;
	my $raw = &JawnOS::Sco::Render::render($text, $args{'voice'} || '');
	return { ok => 0, error => 'this machine cannot speak' } unless $raw;
	my $id = $self->{'next_id'}++;
	$self->_send(cmd => 'play', id => $id, file => $raw);
	# After the words, leave the line to the caller: they may answer. The music
	# does not resume by itself - the pane offers Back on hold - and the call
	# stays a held call, so the plan's own limit does not end it.
	$self->{'hold_paused'} = 1 if $self->{'holding'};
	# the clip that was playing is replaced, so its `played` never arrives; this
	# message's id is the step the guard must accept
	$self->{'step_id'} = $id;
	$self->{'last_event'} = 'said';
	my $line = { who => 'house', text => $text, at => time, ms => 0 };
	push @{ $self->{'transcript'} }, $line;
	shift @{ $self->{'transcript'} } while @{ $self->{'transcript'} } > 200;
	$self->_write_transcript_line($line);
	$self->write_status();
	$self->_push_transcript({ line => $line });
	return { ok => 1, said => $text };
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
		# the flow is over; a timed hold's clock and a menu's wait go with it
		$self->{'flow_started'} = 1;
		$self->{'keypad_open'} = 0;
		$self->_clear_keypad_timer();
		$self->_clear_hold_timer();
		$self->{'holding'} = 0;
		$self->{'hold_until'} = 0;
		$self->{'state'} = 'done';
		$self->{'since'} = time;
		$self->{'done_at'} = time;
		$self->write_status();
		return;
	}
	# a step has been dispatched: a late `flow` may no longer change the plan
	$self->{'flow_started'} = 1;
	if ($step->{'tone'}) {
		$self->_send(cmd => 'tone', id => $self->{'next_id'}, hz => $step->{'hz'}, ms => $step->{'ms'});
	}
	elsif ($step->{'record'}) {
		my $opts = $step->{'opts'} || $self->{'record_opts'} || {};
		my $kind = $step->{'kind'} || 'name';
		my $prefix = $kind eq 'voicemail' ? 'message-' : 'name-';
		my $file = $self->{'dir'} . '/' . $prefix . $self->{'call_id'} . '.wav';
		$self->{'pending_record'} = $file;
		$self->{'pending_kind'} = $kind;
		$self->_send(
			cmd => 'record',
			id => $self->{'next_id'},
			file => $file,
			ms => $opts->{'ms'} || 30000,
			silence_ms => $opts->{'silence_ms'} || 1800,
			min_ms => $opts->{'min_ms'} || 400,
		);
	}
	elsif ($step->{'hold'}) {
		# The hold plays one track and, when the helper says that one is done,
		# plays the next. A timed hold also has a clock: when it runs out the plan
		# moves on and the music is stopped. An untimed one never advances, which
		# is the house holding the line for a person.
		my $seconds = $step->{'seconds'} || 0;
		$self->{'holding'} = 1;
		$self->{'hold_at'} = 0;
		$self->{'hold_paused'} = 0;
		$self->{'hold_until'} = $seconds > 0 ? time + $seconds : 0;
		$self->_clear_hold_timer();
		if ($seconds > 0) {
			$self->{'hold_timer'} = Mojo::IOLoop->timer($seconds => sub {
				return unless $self->{'holding'};
				$self->_hold_finish();
			});
		}
		$self->_hold_play_next();
		return;
	}
	elsif (($step->{'type'} || '') eq 'keypad') {
		# The menu is spoken and the keypad is open from now until the timeout:
		# a caller may press while the menu is still playing, so the press is
		# taken at once and only the clock waits for the words.
		$self->_clear_keypad_timer();
		$self->{'keypad_open'} = 1;
		if ($step->{'play'}) {
			$self->_send(cmd => 'play', id => $self->{'next_id'}, file => $step->{'play'});
		}
		$self->{'step_id'} = $self->{'next_id'}++;
		$self->{'last_event'} = 'step:keypad';
		$self->write_status();
		$self->_keypad_listen() unless $step->{'play'};
		return;
	}
	else {
		$self->_send(cmd => 'play', id => $self->{'next_id'}, file => $step->{'play'});
	}
	$self->{'step_id'} = $self->{'next_id'}++;
	$self->{'last_event'} = 'step:' . ($step->{'key'} || 'play');
	$self->write_status();
}

# The hold's next track. A shuffled list is reshuffled when it is used up, so a
# long wait is not the same rotation twice; a single chosen track simply repeats.
sub _hold_play_next {
	my ($self) = @_;
	my $step = $self->{'steps'}->[ $self->{'step_at'} ] || {};
	my $list = $step->{'list'} || [];
	unless (@{$list}) {
		# no music: an untimed hold is over, a timed one waits out its clock in
		# silence and the timer moves the plan on
		unless ($step->{'seconds'} || 0) {
			$self->{'holding'} = 0;
			$self->_advance();
		}
		return;
	}
	my $at = $self->{'hold_at'} || 0;
	if ($at >= @{$list}) {
		$list = [ shuffle(@{$list}) ] if $step->{'shuffle'};
		$step->{'list'} = $list;
		$self->{'steps'}->[ $self->{'step_at'} ] = $step;
		$at = 0;
	}
	my $path = $list->[$at];
	$self->{'hold_at'} = $at + 1;
	$self->_send(cmd => 'play', id => $self->{'next_id'}, file => $path);
	$self->{'step_id'} = $self->{'next_id'}++;
	$self->{'last_event'} = 'step:hold';
	$self->write_status();
}

# A timed hold reaching its end: the music goes, and the plan takes its next
# step. The stop is ours, so the helper's `stopped` must not end the call.
sub _hold_finish {
	my ($self) = @_;
	$self->_clear_hold_timer();
	$self->{'holding'} = 0;
	$self->{'hold_at'} = 0;
	$self->{'hold_until'} = 0;
	$self->{'hold_paused'} = 0;
	$self->{'stopping_hold'} = 1;
	$self->_send(cmd => 'stop');
	$self->_advance();
	return 1;
}

# Listen for a menu digit. The clock starts when the menu has finished being
# spoken (the play's own `played`), or at once when the flow has no words for
# it. Any press made meanwhile arrives as a `digit` event.
sub _keypad_listen {
	my ($self) = @_;
	$self->_clear_keypad_timer();
	my $step = $self->{'steps'}->[ $self->{'step_at'} ] || {};
	return 0 unless ($step->{'type'} || '') eq 'keypad';
	my $at = $self->{'step_at'};
	my $ms = $step->{'timeout_ms'} || 5000;
	$self->{'keypad_open'} = 1;
	$self->{'keypad_timer'} = Mojo::IOLoop->timer($ms / 1000 => sub {
		delete $self->{'keypad_timer'};
		return unless $self->{'keypad_open'};
		my $now = defined $self->{'step_at'} ? $self->{'step_at'} : -1;
		return unless $now == $at;
		$self->{'keypad_open'} = 0;
		$self->_advance();
	});
	$self->write_status();
	return 1;
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
		$self->{'accepted_at'} = time;
		# The helper's pipe mode labels its transport "pcm" and sends that as
		# the peer. Taking it replaced the phone's address, so every later mixer
		# lookup searched for a stream called "pcm" - and every block contains
		# `Format: pcm`, so the caller capture was moved onto our own prompt.
		# Only an address may replace the address the arm pinned.
		my $peer = $event->{'peer'} || '';
		$self->{'peer'} = $peer if $peer =~ /^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$/i;
		$self->_push_screen('started');
		$self->{'step_at'} = -1;
		# The flow the phone named while answering; with no word from it, the
		# default the arm resolved (the unknown bucket's flow). A key naming no
		# armed flow runs no plan.
		my $key;
		if (exists $self->{'pending_flow'}) {
			$key = delete $self->{'pending_flow'};
		}
		else {
			$key = $self->{'default_flow'};
		}
		$self->start_flow($key);
	}
	elsif ($name eq 'played' || $name eq 'recorded') {
		if ($name eq 'recorded' && $self->{'pending_record'}) {
			my $file = $event->{'file'} || $self->{'pending_record'};
			$self->{'pending_record'} = '';
			my %recording = (
				kind => ($self->{'pending_kind'} || 'name'),
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
			my $at = $self->{'step_at'};
			my $step = (defined $at && $at >= 0) ? ($self->{'steps'}->[$at] || {}) : {};
			if (($step->{'type'} || '') eq 'keypad') {
				# the menu has been spoken, now the caller's keypad is open
				$self->_keypad_listen();
			}
			elsif ($step->{'hold'}) {
				if ($self->{'hold_until'} && time >= $self->{'hold_until'}) {
					$self->_hold_finish();
				}
				elsif ($self->{'hold_paused'}) {
					# a pause is the caller's turn: no track follows until the
					# pane asks for the music again
				}
				else { $self->_hold_play_next(); }
			}
			else { $self->_advance(); }
		}
	}
	elsif ($name eq 'digit') {
		# the caller's keypad, from the helper's tone reader: one line per press
		my $d = $event->{'digit'} || '';
		if ($d =~ /^[0-9*#]$/) {
			my $line = { who => 'caller', text => 'pressed ' . $d, at => time, ms => 0 + ($event->{'ms'} || 0), digit => $d };
			push @{ $self->{'transcript'} }, $line;
			shift @{ $self->{'transcript'} } while @{ $self->{'transcript'} } > 200;
			$self->_write_transcript_line($line);
			$self->write_status();
			$self->_push_transcript({ line => $line });
			# a menu is waiting for this press: a mapped digit jumps to its
			# flow from the top, an unmapped one just moves the menu on
			my $at = $self->{'step_at'};
			my $step = (defined $at && $at >= 0) ? ($self->{'steps'}->[$at] || {}) : {};
			if ($self->{'keypad_open'} && ($step->{'type'} || '') eq 'keypad') {
				$self->{'keypad_open'} = 0;
				$self->_clear_keypad_timer();
				my $target = $step->{'digits'} ? ($step->{'digits'}->{$d} || '') : '';
				if (length $target && $self->{'flows'}->{$target}) {
					$self->{'last_event'} = 'digit:' . $d;
					$self->start_flow($target);
				}
				else { $self->_advance(); }
			}
		}
	}
	elsif ($name eq 'closed' || $name eq 'stopped') {
		$self->{'last_event'} = $name;
		# A stopped clip while somebody is bridged is the plan getting out of the
		# person's way - rtc() sends the stop before it joins, and that is exactly
		# how the hold music steps aside. The call is not over: taking the gateway
		# idle would let Reception arm again and cancel the helper under a live
		# call. Only a closed line ends a bridged call.
		if ($name eq 'stopped' && ($self->{'rtc_up'} || $self->{'stopping_hold'})) {
			# the stop we asked for: the music off, the call still up
			$self->{'stopping_hold'} = 0;
			$self->write_status();
			return 1;
		}
		$self->{'state'} = $self->{'state'} eq 'done' ? 'done' : 'idle';
		$self->{'holding'} = 0;
		$self->{'hold_at'} = 0;
		$self->_push_screen('ended');
		$self->{'since'} = time;
		$self->_reap();
		$self->_stop_transcript();
		$self->_stop_rtc();
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
	$self->{'caller'} = {};
	$self->stop_watch();
	# a plan that is put down takes its timers (a menu's wait, a timed hold's
	# clock) and the flow it was in with it
	$self->{'flow'} = '';
	$self->{'flow_started'} = 0;
	$self->{'steps'} = [];
	$self->{'step_at'} = -1;
	$self->{'hold_until'} = 0;
	$self->{'keypad_open'} = 0;
	$self->_clear_keypad_timer();
	$self->_clear_hold_timer();
	# Put the call's streams back only when no call is up. Cancelling also
	# happens at every re-arm, while the line is still breathing, and moving a
	# live call to the laptop's own sink and microphone is exactly what made
	# the caller hear the room and left our recording silent.
	if ($self->{'mixer'} && $self->{'mixer'}->{'attached'} && !$self->{'mixer'}->call_active()) {
		$self->{'mixer'}->detach();
	}
	return { ok => 1, state => $self->{'state'} } if $self->{'state'} eq 'idle';
	$self->_push_screen('ended');
	$self->_send(cmd => 'quit');
	$self->_reap();
	$self->_stop_transcript();
	$self->_stop_rtc();
	$self->{'state'} = 'idle';
	$self->{'since'} = time;
	$self->{'last_event'} = 'cancelled';
	$self->{'held'} = 0;
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
