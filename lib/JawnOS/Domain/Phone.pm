package subs;

# The phone's reception settings, read the same way everywhere.
#
# These live in the domain layer rather than on the Manager because a worker
# needs them without loading the whole panel: perl/Reception.pl arms the
# gateway from them with no request in flight. The IVR belongs to the house,
# not to the device that happened to save it - the phone turns it on, the
# gateway machine plays it - so the rows are read and written house-wide, with
# the older per-device rows still answering as a fallback.
use strict;
use warnings;
use Data::UUID;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json);

sub phone_ivr_defaults {
	return {
		enabled   => 'no',
		machine   => '',
		route     => 'unknown',
		voice     => &subs::say_default_voice(),
		# the adapter the phone must send call audio to, by Bluetooth name
		bluetooth => 'jawn-gateway',
		greeting  => &subs::ui('This automated system records calls.'),
		prompt    => &subs::ui('Please say your name after the tone.'),
		voicemail => &subs::ui('Please leave a message after the tone.'),
		thanks    => &subs::ui('Thank you.'),
		# what the caller hears after the thanks while somebody decides to pick
		# up: '' (none), 'shuffle' for the whole library, or one track's path
		hold      => '',
		flows     => &subs::phone_ivr_flow_defaults('unknown'),
	};
}

# The six call-flow buckets. `route` is the older three-way knob; when a phone
# has no saved matrix, the matrix is derived from it so an existing phone keeps
# behaving the same way.
sub phone_ivr_flow_defaults {
	my ($route) = @_;
	my %flow = (
		unknown     => 'ivr',
		blacklisted => 'reject',
		enemy       => 'reject',
		stranger    => 'ivr',
		friend      => 'ring',
		self        => 'ring',
	);
	if (($route || '') eq 'off') {
		$flow{$_} = 'ring' for qw(unknown stranger friend self);
	}
	elsif (($route || '') eq 'all') {
		$flow{$_} = 'ivr' for qw(unknown stranger friend self);
	}
	return \%flow;
}

# ---- named flows -----------------------------------------------------------
#
# A house may keep several named receptions instead of one set of prompts: a
# receptionist, a plain voicemail line, and any of its own. Each flow carries
# its own voice and words, its own hold music, and what happens after the
# thanks. A caller bucket names one of them, so two kinds of caller can hear two
# different receptions.
#
# The flows are one house-wide JSON setting so the phone and the gateway read
# the same words. The older ivr_greeting/prompt/... rows stay written and read:
# an older build on another machine still speaks from them, and the
# receptionist flow is what those rows mean.
my @PHONE_IVR_FLOW_TEXTS = qw(greeting prompt voicemail thanks);
my @PHONE_IVR_FLOW_AFTER = qw(hold voicemail end);

# A flow is spoken as an ordered list of steps. Before steps existed every flow
# spoke the same sequence - greeting, ask for a name, thanks, then whatever the
# after choice says - and a flow with no steps still does. The list is capped so
# a payload from a browser or a peer cannot make the gateway speak forever.
my @PHONE_IVR_STEP_TYPES = qw(say ask keypad hold voicemail after);
my @PHONE_IVR_STEP_TEXT_KEYS = qw(greeting prompt thanks voicemail);
my $PHONE_IVR_STEP_MAX = 20;
my $step_clamp = sub {
	my ($value, $min, $max, $default) = @_;
	return $default unless defined $value && $value =~ /^\d+$/;
	$value = int($value);
	return $min if $value < $min;
	return $max if $value > $max;
	return $value;
};

# The sequence a flow really speaks: its own steps when it has any, else the
# legacy order. A copy, so a caller may reorder it without editing the def.
sub phone_ivr_flow_steps {
	my ($flow) = @_;
	my $steps = ref $flow eq 'HASH' ? $flow->{'steps'} : undef;
	my @copy;
	if (ref $steps eq 'ARRAY') {
		foreach my $step ( @{$steps} ) {
			next unless ref $step eq 'HASH';
			my %one = %{$step};
			$one{'digits'} = { %{ $step->{'digits'} } } if ref $step->{'digits'} eq 'HASH';
			push @copy, \%one;
		}
	}
	return \@copy if @copy;
	return [
		{ type => 'say', text_key => 'greeting' },
		{ type => 'ask' },
		{ type => 'say', text_key => 'thanks' },
		{ type => 'after' },
	];
}

# One step list, cleaned. A step is data from a browser or a peer, so its type
# must be one the gateway knows, a say names one of the flow's own texts, a
# keypad's digits are single keypad characters naming a slug (whether that flow
# exists is checked once the whole set is known), and a hold is 0-600 seconds.
# An unknown step is dropped rather than salvaged.
sub phone_ivr_steps_clean {
	my ($steps) = @_;
	return [] unless ref $steps eq 'ARRAY';
	my @out;
	foreach my $row ( @{$steps} ) {
		last if @out >= $PHONE_IVR_STEP_MAX;
		next unless ref $row eq 'HASH';
		my $type = defined $row->{'type'} ? $row->{'type'} : '';
		next unless grep { $_ eq $type } @PHONE_IVR_STEP_TYPES;
		my %step = (type => $type);
		if ($type eq 'say') {
			my $key = defined $row->{'text_key'} ? $row->{'text_key'} : '';
			next unless grep { $_ eq $key } @PHONE_IVR_STEP_TEXT_KEYS;
			$step{'text_key'} = $key;
		}
		elsif ($type eq 'keypad') {
			my $text = defined $row->{'text'} ? $row->{'text'} : '';
			$text =~ s/^\s+|\s+$//g;
			$step{'text'} = substr($text, 0, 300);
			$step{'timeout_ms'} = $step_clamp->($row->{'timeout_ms'}, 500, 30000, 5000);
			my $given = ref $row->{'digits'} eq 'HASH' ? $row->{'digits'} : {};
			my %digits;
			foreach my $digit ( keys %{$given} ) {
				next unless defined $digit && $digit =~ /^[0-9*#]$/;
				my $target = $given->{$digit};
				next unless defined $target && $target =~ /^[a-z0-9_]{1,30}$/;
				$digits{$digit} = $target;
			}
			$step{'digits'} = \%digits;
		}
		elsif ($type eq 'hold') {
			$step{'seconds'} = $step_clamp->($row->{'seconds'}, 0, 600, 0);
		}
		push @out, \%step;
	}
	return \@out;
}

# The words a house without saved flows speaks, taken from the legacy rows so a
# house that never opened the flow editor keeps its own voice and prompts.
sub phone_ivr_flow_seed {
	my $legacy = &subs::phone_ivr_legacy_settings();
	my $voice = $legacy->{'voice'};
	return {
		receptionist => {
			name      => 'Receptionist',
			voice     => $voice,
			greeting  => $legacy->{'greeting'},
			prompt    => $legacy->{'prompt'},
			voicemail => $legacy->{'voicemail'},
			thanks    => $legacy->{'thanks'},
			hold      => $legacy->{'hold'},
			after     => 'hold',
			builtin   => 1,
		},
		voicemail => {
			name      => 'Voicemail',
			voice     => $voice,
			greeting  => '',
			prompt    => '',
			voicemail => $legacy->{'voicemail'},
			thanks    => '',
			hold      => '',
			after     => 'end',
			# the one seed that is not the legacy order: the flow named for a
			# voicemail takes one, instead of asking for a name it has no prompt for
			steps     => [ { type => 'voicemail' } ],
			builtin   => 1,
		},
	};
}

# One flow, cleaned against the flow it is allowed to fall back to. A saved row
# is data from a browser or a peer, so every field is checked here: a key is a
# slug, a voice is one the house offers, a hold choice stays in the library and
# an after step is one of the three.
sub phone_ivr_flow_def_clean {
	my ($row, $base) = @_;
	my %out = (
		name      => '',
		voice     => &subs::say_default_voice(),
		greeting  => '',
		prompt    => '',
		voicemail => '',
		thanks    => '',
		hold      => '',
		after     => 'hold',
		steps     => [],
		builtin   => 0,
	);
	%out = (%out, %{$base}) if ref $base eq 'HASH';
	$row = {} unless ref $row eq 'HASH';

	if (defined $row->{'name'}) {
		my $name = $row->{'name'};
		$name =~ s/^\s+|\s+$//g;
		$name = substr($name, 0, 60);
		$out{'name'} = $name if length $name;
	}
	my %voices = map { $_->{'value'} => 1 } &subs::say_voices();
	if (defined $row->{'voice'} && $voices{ $row->{'voice'} }) {
		$out{'voice'} = $row->{'voice'};
	}
	$out{'voice'} = &subs::say_default_voice() unless $voices{ $out{'voice'} || '' };
	foreach my $key (@PHONE_IVR_FLOW_TEXTS) {
		next unless defined $row->{$key};
		my $text = $row->{$key};
		$text =~ s/^\s+|\s+$//g;
		$out{$key} = substr($text, 0, 1000);
	}
	if (defined $row->{'hold'}) {
		require JawnOS::Sco::Hold;
		my $hold = &JawnOS::Sco::Hold::in_library($row->{'hold'});
		$hold = lc($hold) if lc($hold) eq 'shuffle';
		$out{'hold'} = $hold;
	}
	if (defined $row->{'after'} && grep { $_ eq $row->{'after'} } @PHONE_IVR_FLOW_AFTER) {
		$out{'after'} = $row->{'after'};
	}
	# An empty list is the legacy sequence, so an edited-away list falls back to
	# it rather than resurrecting the base's steps.
	if (ref $row->{'steps'} eq 'ARRAY') {
		$out{'steps'} = &subs::phone_ivr_steps_clean($row->{'steps'});
	}
	return \%out;
}

# The whole set. The two built-ins are always there - a built-in may be edited
# but not deleted - and a key that is not a slug is not a flow at all.
sub phone_ivr_flow_defs_clean {
	my ($defs) = @_;
	my $seed = &subs::phone_ivr_flow_seed();
	my %clean = %{$seed};
	if (ref $defs eq 'HASH') {
		foreach my $key ( keys %{$defs} ) {
			next unless defined $key && $key =~ /^[a-z0-9_]{1,30}$/;
			my $row = $defs->{$key};
			next unless ref $row eq 'HASH';
			$clean{$key} = &subs::phone_ivr_flow_def_clean($row, $clean{$key});
		}
	}
	$clean{$_}->{'builtin'} = 1 for keys %{$seed};
	# A keypad may jump to a flow this house still has, or to Ring/Reject. A flow
	# removed from this same save takes every digit that named it with it, so a
	# stale menu cannot point at a flow nobody answers.
	foreach my $key ( keys %clean ) {
		my $flow = $clean{$key};
		next unless ref $flow->{'steps'} eq 'ARRAY';
		foreach my $step ( @{$flow->{'steps'}} ) {
			next unless ref $step eq 'HASH' && ($step->{'type'} || '') eq 'keypad';
			my $digits = ref $step->{'digits'} eq 'HASH' ? $step->{'digits'} : {};
			foreach my $digit ( keys %{$digits} ) {
				my $target = $digits->{$digit};
				delete $digits->{$digit}
					unless defined $target && ($target eq 'ring' || $target eq 'reject' || $clean{$target});
			}
		}
	}
	return \%clean;
}

sub phone_ivr_flow_defs {
	my $stored = &subs::phone_ivr_grab('ivr_flow_defs');
	my $defs = length $stored ? eval { decode_json($stored) } : undef;
	return &subs::phone_ivr_flow_defs_clean($defs);
}

# The bucket matrix, resolved to its answers. A bucket may name one of the
# flows or the older three answers; 'ivr' still means the receptionist and
# 'voicemail' still means the voicemail flow.
sub phone_ivr_flows {
	return &subs::phone_ivr_settings()->{'flows'};
}

sub phone_ivr_flow_clean {
	my ($flows, $route, $defs) = @_;
	my $base = &subs::phone_ivr_flow_defaults($route);
	my %clean = %{$base};
	$defs = &subs::phone_ivr_flow_defs() unless ref $defs eq 'HASH';
	if (ref $flows eq 'HASH') {
		foreach my $bucket (qw(unknown blacklisted self friend stranger enemy)) {
			my $action = $flows->{$bucket};
			next unless defined $action && length $action;
			# the three older answers, or a flow this house still has
			next unless $action =~ /^(?:ring|ivr|voicemail|reject)$/ || $defs->{$action};
			$clean{$bucket} = $action;
		}
	}
	return \%clean;
}

# What a bucket resolves to, for the gateway: a flow hashref, or '' when the
# bucket is not answered at all (ring or reject). A bucket naming a flow that
# no longer exists answers the way the bucket would with nothing saved for it.
sub phone_ivr_flow_for_bucket {
	my ($bucket) = @_;
	return '' unless defined $bucket && $bucket =~ /^(?:unknown|blacklisted|self|friend|stranger|enemy)$/;
	my $settings = &subs::phone_ivr_settings();
	my $defs = $settings->{'flow_defs'};
	$defs = &subs::phone_ivr_flow_defs() unless ref $defs eq 'HASH';
	my $action = $settings->{'flows'}->{$bucket};
	$action = 'ring' unless defined $action && length $action;
	my $flow = &subs::phone_ivr_flow_resolve($action, $defs);
	return $flow if defined $flow;
	my $fallback = &subs::phone_ivr_flow_defaults($settings->{'route'})->{$bucket} || 'ring';
	my $again = &subs::phone_ivr_flow_resolve($fallback, $defs);
	return defined $again ? $again : '';
}

# The action a bucket value names: '' for ring/reject, undef for a name no flow
# owns. Kept apart from the resolution above so the fallback can reuse it.
sub phone_ivr_flow_resolve {
	my ($action, $defs) = @_;
	return undef unless defined $action && length $action;
	return '' if $action eq 'ring' || $action eq 'reject';
	my $key = $action eq 'ivr' ? 'receptionist' : $action;
	my $flow = $defs->{$key};
	return ref $flow eq 'HASH' ? $flow : undef;
}

# One setting, the house row first and this device's older row second.
sub phone_ivr_grab {
	my ($setting) = @_;
	my $value = &subs::setting_grabber({ app => 'phone', setting => $setting, device => 'all', benign => 1 });
	if (!defined $value || !length $value) {
		$value = &subs::setting_grabber({ app => 'phone', setting => $setting, benign => 1 });
	}
	return defined $value ? $value : '';
}

# The older top-level rows, before the flows are overlaid on them.
sub phone_ivr_legacy_settings {
	my $settings = &subs::phone_ivr_defaults();
	foreach my $key ( keys %{$settings} ) {
		next if $key eq 'flows';
		my $value = &subs::phone_ivr_grab('ivr_' . $key);
		$settings->{$key} = $value if length $value;
	}
	$settings->{'enabled'} = ($settings->{'enabled'} eq 'yes') ? 'yes' : 'no';
	$settings->{'route'} = 'unknown' unless $settings->{'route'} =~ /^(?:unknown|all|off)$/;
	my %voices = map { $_->{'value'} => 1 } &subs::say_voices();
	$settings->{'voice'} = &subs::say_default_voice() unless $voices{ $settings->{'voice'} };
	my $stored_flows = &subs::phone_ivr_grab('ivr_flows');
	$settings->{'flows'} = length $stored_flows ? eval { decode_json($stored_flows) } : undef;
	return $settings;
}

sub phone_ivr_settings {
	my $settings = &subs::phone_ivr_legacy_settings();
	my $defs = &subs::phone_ivr_flow_defs();
	$settings->{'flows'} = &subs::phone_ivr_flow_clean($settings->{'flows'}, $settings->{'route'}, $defs);
	# the legacy rows are the receptionist's words, so the two cannot disagree
	my $receptionist = $defs->{'receptionist'};
	if (ref $receptionist eq 'HASH') {
		foreach my $key (qw(voice greeting prompt voicemail thanks hold after)) {
			$settings->{$key} = $receptionist->{$key};
		}
	}
	$settings->{'flow_defs'} = $defs;
	return $settings;
}

# A screened call's transcript, filed into the Chat thread for the number.
#
# The gateway writes one JSONL file per call under ~/.president/sco/transcripts,
# but it never learns the caller's number: the number is the phone's, and the
# phone tells the house when it files the call. So the filing happens here, when
# the call appointment is written, and a transcript is spent once (a renamed
# .filed marker), so a retried call log cannot file the same words twice.
#
# When the gateway is another machine there is no local file; the live lines are
# still in its status, so the phone asks it for them instead. The header names
# the caller from this house's contact rows, because that is the half the
# gateway never sees.
#
# The call window picks the file: the gateway and the phone are the same house
# and a call is one at a time, but a transcript from minutes later belongs to a
# different call and is left alone. '' when there is nothing to file.
sub phone_call_transcript_note {
	my ($number, $started_ms, $ended_ms) = @_;
	my $digits = defined $number ? $number : '';
	$digits =~ s/\D+//g;
	$digits =~ s/^1//;
	return 0 unless length $digits;
	my ($file, $said) = &phone_call_transcript_lines($ended_ms);
	return 0 unless length $file && @{$said};
	# The number is the phone's, not the gateway's, so the header names the
	# caller from the house's own contact rows. An unknown number reads as the
	# number the phone received, not the digits the matching works on.
	my $app = eval { &subs::phone_number_app($digits) } || '';
	my $caller = (length $app && $app ne $digits) ? &subs::format_name($app) : '';
	$caller = $number if !length $caller && defined $number && length $number;
	$caller = $digits unless length $caller;
	my $body = 'Call from: ' . $caller . "\n\n" . join(' ', @{$said});
	$body = substr($body, 0, 4000);
	# A message the house cannot read again is not written: the key is missing
	# (a sandbox, a half-restored machine), and the transcript is left in place
	# for the next attempt.
	my $sealed = eval { &subs::note_encrypter(&subs::suds_grabber(), $body) };
	return 0 unless defined $sealed && length $sealed;
	my $msg = {
		uuid => Data::UUID->new->create_str(),
		timestamp => &phone_call_epoch($ended_ms) * 1000,
		server_time => &subs::rightNow(),
		body => $sealed,
		manager_file => '',
		status => 'sent',
		contact => $app,
		phone => $digits,
		email => undef,
		conversation_uuid => undef,
		attachments => undef,
	};
	my $ok = eval { &subs::db_insert('mailbox', $msg); 1 };
	return 0 unless $ok;
	# Only a local transcript has a file to spend. A remote status names its
	# call instead, and the next log (or a retry) asks the gateway again.
	rename $file, "$file.filed" if -f $file && $file =~ /\.jsonl$/;
	return 1;
}

# The transcript file for a call that ended at $ended_ms, and the words in it.
# A local .jsonl the gateway wrote wins; with none, the gateway's live status is
# asked, because the gateway may be another machine. Its lines carry their own
# timestamps, and a transcript from minutes later belongs to a different call
# and is left alone. A spent local transcript is renamed .filed, so a retried
# call log cannot file it twice. Returns () when there is nothing to file.
sub phone_call_transcript_lines {
	my ($ended_ms) = @_;
	my $dir = $ENV{'JAWNOS_SCO_DIR'}
		? $ENV{'JAWNOS_SCO_DIR'} . '/transcripts'
		: &subs::home('~/.president/sco/transcripts');
	my $ended = &phone_call_epoch($ended_ms);

	if (-d $dir) {
		opendir(my $dh, $dir);
		if ($dh) {
			my @files = sort grep { /\.jsonl$/ && -s "$dir/$_" } readdir $dh;
			closedir $dh;
			my ($pick, $best) = ('', undef);
			foreach my $name (@files) {
				my $mtime = (stat("$dir/$name"))[9] || 0;
				my $delta = abs($mtime - $ended);
				next if $delta > 300;   # another call's words
				if (!defined $best || $delta < $best) { $best = $delta; $pick = $name; }
			}
			if (length $pick) {
				my @said;
				foreach my $line ( split /\n/, read_file("$dir/$pick") ) {
					next unless $line =~ /\S/;
					my $row = eval { decode_json($line) };
					next unless ref $row eq 'HASH';
					my $text = $row->{'text'} // '';
					$text =~ s/^\s+|\s+$//g;
					push @said, $text if length $text;
				}
				return ("$dir/$pick", \@said) if @said;
				return ();
			}
		}
	}

	# No local transcript: the gateway is another machine's, but the phone still
	# knows when the call ended. Ask it for the lines it is holding. A missing
	# gateway (the ordinary desktop) answers { ok => 0 }, which is not an error.
	my $status = eval {
		require JawnOS::Sco::Client;
		JawnOS::Sco::Client->new()->call({ cmd => 'status' });
	};
	return () unless ref $status eq 'HASH' && $status->{'ok'};

	# A status whose call began after this one ended belongs to the next call.
	my $since = $status->{'since'};
	return () if defined $since && $since =~ /^\d+$/ && $since > $ended + 5;

	my @remote;
	my $rows = $status->{'transcript'};
	$rows = [] unless ref $rows eq 'ARRAY';
	foreach my $row ( @{$rows} ) {
		next unless ref $row eq 'HASH';
		my $at = $row->{'at'};
		next unless defined $at && $at =~ /^\d+$/;
		next if abs($at - $ended) > 300;   # another call's words
		my $text = $row->{'text'} // '';
		$text =~ s/^\s+|\s+$//g;
		push @remote, $text if length $text;
	}
	return () unless @remote;
	my $call_id = $status->{'call_id'} // '';
	# Not a path to a local file: the caller can tell this came from the
	# gateway's live status, and the note leaves it alone rather than renaming.
	return (length $call_id ? $call_id : 'remote', \@remote);
}

# A call's stamp arrives in milliseconds (the app's Date.now); an older caller
# may still send seconds. Either way, seconds out.
sub phone_call_epoch {
	my ($stamp) = @_;
	return time unless defined $stamp && $stamp =~ /^\d+(?:\.\d+)?$/ && $stamp > 0;
	return int($stamp / 1000) if $stamp > 100000000000;
	return int($stamp);
}

1;
