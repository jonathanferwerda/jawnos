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
use File::Path qw(make_path);
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);

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
# A message is five minutes by default. The floor keeps a caller from being cut
# off before they start and the ceiling keeps one call from holding the house's
# line for half an hour.
my $PHONE_VOICEMAIL_SECONDS_DEFAULT = 300;
my $PHONE_VOICEMAIL_SECONDS_MIN = 15;
my $PHONE_VOICEMAIL_SECONDS_MAX = 1800;
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
			voicemail_greeting => '',
			thanks    => $legacy->{'thanks'},
			hold      => $legacy->{'hold'},
			after     => 'hold',
			voicemail_seconds => $PHONE_VOICEMAIL_SECONDS_DEFAULT,
			builtin   => 1,
		},
		voicemail => {
			name      => 'Voicemail',
			voice     => $voice,
			greeting  => '',
			prompt    => '',
			voicemail => $legacy->{'voicemail'},
			voicemail_greeting => '',
			thanks    => '',
			hold      => '',
			after     => 'end',
			voicemail_seconds => $PHONE_VOICEMAIL_SECONDS_DEFAULT,
			# the one seed that is not the legacy order: the flow named for a
			# voicemail takes one, instead of asking for a name it has no prompt for
			steps     => [ { type => 'voicemail' } ],
			builtin   => 1,
		},
	};
}

# ---- who a flow answers ------------------------------------------------
#
# A flow may name the callers that get it, instead of relying on the bucket
# matrix alone. Each entry is one of four shapes:
#
#   { kind => 'number', value => '<the number>', label => '<as typed>' }
#   { kind => 'person', uuid => '<settings pos row uuid>', label => '<name>' }
#   { kind => 'vendor', uuid => '<settings pos row uuid>' }
#   { kind => 'corporation', uuid => '<settings pos row uuid>' }
#
# A person/vendor/corporation entry names the settings row that models the
# body - a pos (or mab) row whose value is the kind, which is what the People
# app and the address tuple already use for people, vendors and corporations.
# The numbers that body owns are the phone/phones rows kept under its app name,
# so an entry never repeats the lines.
my @PHONE_IVR_CALLER_KINDS = qw(number person vendor corporation);
my @PHONE_IVR_BODY_KINDS = qw(person vendor corporation);
# A telephone number is 7-15 digits once normalised; E.164 allows no more.
# The house's own normaliser strips everything else and a leading 1, so this
# check is about length only - never a second spelling of the same rule.
my $PHONE_IVR_CALLER_DIGITS_MIN = 7;
my $PHONE_IVR_CALLER_DIGITS_MAX = 15;

# The key a number is matched and indexed by: the house's normal form, cut to
# the last ten digits the way contact_matches cuts it.
sub phone_ivr_number_key {
	my ($number) = @_;
	my $key = &subs::contact_normalizer('phone', $number);
	return '' unless length $key;
	$key = substr($key, -10) if length $key >= 10;
	return $key;
}

# Every settings row that models a person, vendor or corporation, by uuid. One
# read answers a whole caller list, and the uuid is what the entry travels with.
sub phone_ivr_caller_bodies {
	my $rows = eval {
		&subs::db_query("select uuid, app, setting, value from settings where setting in ('pos','mab') and value in ('person','vendor','corporation')")->hashes;
	} || [];
	my %bodies;
	foreach my $row ( @{$rows} ) {
		next unless ref $row eq 'HASH';
		my $uuid = $row->{'uuid'} || '';
		my $kind = $row->{'value'} || '';
		my $app = $row->{'app'} || '';
		next unless length $uuid && length $app;
		next unless grep { $_ eq $kind } @PHONE_IVR_BODY_KINDS;
		$bodies{$uuid} = { uuid => $uuid, kind => $kind, app => $app };
	}
	return \%bodies;
}

# The app a body entry names, '' when the row is gone or no longer that kind.
sub phone_ivr_caller_body_app {
	my ($caller, $bodies) = @_;
	return '' unless ref $caller eq 'HASH';
	my $kind = $caller->{'kind'} || '';
	return '' unless grep { $_ eq $kind } @PHONE_IVR_BODY_KINDS;
	my $uuid = $caller->{'uuid'} || '';
	return '' unless length $uuid;
	$bodies = &subs::phone_ivr_caller_bodies() unless ref $bodies eq 'HASH';
	my $body = $bodies->{$uuid};
	return '' unless ref $body eq 'HASH' && $body->{'kind'} eq $kind;
	return $body->{'app'};
}

# One caller entry, cleaned. A number is stored in the house's normal form and
# must be a plausible telephone number; a body must name a uuid that is really
# a person/vendor/corporation row when the save is verified (a read keeps the
# shape, because a body may come back when its app is restored).
sub phone_ivr_caller_clean {
	my ($row, $verify) = @_;
	return undef unless ref $row eq 'HASH';
	my $kind = defined $row->{'kind'} ? $row->{'kind'} : '';
	return undef unless grep { $_ eq $kind } @PHONE_IVR_CALLER_KINDS;
	my $label = defined $row->{'label'} ? $row->{'label'} : '';
	$label =~ s/^\s+|\s+$//g;
	$label = substr($label, 0, 60);
	if ($kind eq 'number') {
		my $key = &subs::phone_ivr_number_key($row->{'value'});
		return undef unless length $key >= $PHONE_IVR_CALLER_DIGITS_MIN
			&& length $key <= $PHONE_IVR_CALLER_DIGITS_MAX;
		return { kind => 'number', value => $key, label => $label };
	}
	my $uuid = defined $row->{'uuid'} ? $row->{'uuid'} : '';
	return undef unless $uuid =~ /^[A-Za-z0-9_-]{1,80}$/;
	if ($verify) {
		return undef unless length &subs::phone_ivr_caller_body_app({ kind => $kind, uuid => $uuid });
	}
	return { kind => $kind, uuid => $uuid, label => $label };
}

# A flow's caller list, most specific first. The same entry twice is one entry;
# the earliest keeps its place.
sub phone_ivr_callers_clean {
	my ($callers, $verify) = @_;
	return [] unless ref $callers eq 'ARRAY';
	my (@out, %seen);
	foreach my $row ( @{$callers} ) {
		my $clean = &subs::phone_ivr_caller_clean($row, $verify);
		next unless ref $clean eq 'HASH';
		my $key = $clean->{'kind'} eq 'number'
			? 'number:' . $clean->{'value'}
			: $clean->{'kind'} . ':' . $clean->{'uuid'};
		next if $seen{$key}++;
		push @out, $clean;
	}
	return \@out;
}

# Every number an entry stands for: the number itself, or every line kept under
# a person/vendor/corporation's app.
sub phone_ivr_caller_numbers {
	my ($caller, $bodies) = @_;
	return () unless ref $caller eq 'HASH';
	if (($caller->{'kind'} || '') eq 'number') {
		my $key = &subs::phone_ivr_number_key($caller->{'value'});
		return length $key ? ($key) : ();
	}
	my $app = &subs::phone_ivr_caller_body_app($caller, $bodies);
	return () unless length $app;
	my $lines = &subs::contact_lines('phone', $app);
	my (@numbers, %seen);
	foreach my $line ( @{ $lines->{$app} || [] } ) {
		my $key = &subs::phone_ivr_number_key($line->{'value'});
		next unless length $key;
		push @numbers, $key unless $seen{$key}++;
	}
	return @numbers;
}

# One flow, cleaned against the flow it is allowed to fall back to. A saved row
# is data from a browser or a peer, so every field is checked here: a key is a
# slug, a voice is one the house offers, a hold choice stays in the library and
# an after step is one of the three.
sub phone_ivr_flow_def_clean {
	my ($row, $base, $opts) = @_;
	$opts = {} unless ref $opts eq 'HASH';
	my %out = (
		name      => '',
		voice     => &subs::say_default_voice(),
		greeting  => '',
		prompt    => '',
		voicemail => '',
		# '' means the text above; otherwise a recorded WAV the house holds
		voicemail_greeting => '',
		thanks    => '',
		hold      => '',
		after     => 'hold',
		voicemail_seconds => $PHONE_VOICEMAIL_SECONDS_DEFAULT,
		steps     => [],
		callers   => [],
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
	# A recorded greeting is a house media file, never a path a browser chose.
	# It must be in one of the media folders; the file itself may still be on its
	# way to this machine, exactly as a hold choice may name the gateway's own
	# library. The gateway falls back to the text when it is not there.
	if (defined $row->{'voicemail_greeting'}) {
		require JawnOS::Sco::Audio;
		$out{'voicemail_greeting'} = &JawnOS::Sco::Audio::in_house($row->{'voicemail_greeting'});
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
	if (defined $row->{'voicemail_seconds'}) {
		$out{'voicemail_seconds'} = $step_clamp->($row->{'voicemail_seconds'},
			$PHONE_VOICEMAIL_SECONDS_MIN, $PHONE_VOICEMAIL_SECONDS_MAX, $out{'voicemail_seconds'});
	}
	# A base saved before this field existed has no number at all, and a payload
	# that arrives with a word keeps the flow's own length rather than losing it.
	$out{'voicemail_seconds'} = $step_clamp->($out{'voicemail_seconds'},
		$PHONE_VOICEMAIL_SECONDS_MIN, $PHONE_VOICEMAIL_SECONDS_MAX, $PHONE_VOICEMAIL_SECONDS_DEFAULT);
	# An empty list is the legacy sequence, so an edited-away list falls back to
	# it rather than resurrecting the base's steps.
	if (ref $row->{'steps'} eq 'ARRAY') {
		$out{'steps'} = &subs::phone_ivr_steps_clean($row->{'steps'});
	}
	# A client that does not know about callers keeps the flow's saved list; one
	# that sends a list (including an empty one) replaces it.
	if (ref $row->{'callers'} eq 'ARRAY') {
		$out{'callers'} = &subs::phone_ivr_callers_clean($row->{'callers'}, $opts->{'verify'});
	}
	return \%out;
}

# The whole set. The two built-ins are always there - a built-in may be edited
# but not deleted - and a key that is not a slug is not a flow at all.
sub phone_ivr_flow_defs_clean {
	my ($defs, $opts) = @_;
	$opts = {} unless ref $opts eq 'HASH';
	my $seed = &subs::phone_ivr_flow_seed();
	my %clean = %{$seed};
	if (ref $defs eq 'HASH') {
		foreach my $key ( keys %{$defs} ) {
			next unless defined $key && $key =~ /^[a-z0-9_]{1,30}$/;
			my $row = $defs->{$key};
			next unless ref $row eq 'HASH';
			$clean{$key} = &subs::phone_ivr_flow_def_clean($row, $clean{$key}, $opts);
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
	&subs::phone_ivr_callers_dedupe(\%clean, $opts);
	return \%clean;
}

# One number belongs to one flow. A save that puts the same number in two flows
# keeps the later one: the flow the number is new to, or - when the payload does
# not say - the flow last in the save order. The loser says so in a warning the
# pane shows, rather than silently dropping the entry.
sub phone_ivr_callers_dedupe {
	my ($defs, $opts) = @_;
	return unless ref $defs eq 'HASH';
	$opts = {} unless ref $opts eq 'HASH';
	my @order = ref $opts->{'order'} eq 'ARRAY'
		? grep { defined $_ && $defs->{$_} } @{ $opts->{'order'} }
		: sort keys %{$defs};
	my $previous = ref $opts->{'previous'} eq 'HASH' ? $opts->{'previous'} : {};
	my $warnings = ref $opts->{'warnings'} eq 'ARRAY' ? $opts->{'warnings'} : undef;

	my %owners;
	foreach my $flow_key ( @order ) {
		my $callers = $defs->{$flow_key}->{'callers'};
		next unless ref $callers eq 'ARRAY';
		foreach my $caller ( @{$callers} ) {
			next unless ref $caller eq 'HASH' && ($caller->{'kind'} || '') eq 'number';
			push @{ $owners{ $caller->{'value'} } }, $flow_key;
		}
	}

	foreach my $number ( sort keys %owners ) {
		my @has = @{ $owners{$number} };
		next unless scalar @has > 1;
		# a flow the number is new to is the later save, so it wins
		my @fresh = grep { !&subs::phone_ivr_flow_has_number($previous->{$_}, $number) } @has;
		my $owner = @fresh ? $fresh[-1] : $has[-1];
		my $owner_name = &subs::phone_ivr_flow_label($defs->{$owner}, $owner);
		foreach my $flow_key ( @has ) {
			next if $flow_key eq $owner;
			my $callers = $defs->{$flow_key}->{'callers'};
			@{$callers} = grep { !(ref $_ eq 'HASH' && ($_->{'kind'} || '') eq 'number' && $_->{'value'} eq $number) } @{$callers};
			push @{$warnings}, {
				number => $number,
				from => &subs::phone_ivr_flow_label($defs->{$flow_key}, $flow_key),
				to => $owner_name,
				from_key => $flow_key,
				to_key => $owner,
			} if $warnings;
		}
	}
	return;
}

sub phone_ivr_flow_has_number {
	my ($flow, $number) = @_;
	return 0 unless ref $flow eq 'HASH' && ref $flow->{'callers'} eq 'ARRAY';
	foreach my $caller ( @{ $flow->{'callers'} } ) {
		next unless ref $caller eq 'HASH' && ($caller->{'kind'} || '') eq 'number';
		return 1 if ($caller->{'value'} || '') eq $number;
	}
	return 0;
}

sub phone_ivr_flow_label {
	my ($flow, $key) = @_;
	my $name = ref $flow eq 'HASH' ? ($flow->{'name'} || '') : '';
	return length $name ? $name : (defined $key ? $key : '');
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

# ---- the caller a number is ---------------------------------------------
#
# An incoming call resolves in order: an exact number named in a flow's callers,
# then the person/vendor/corporation the number belongs to, then the bucket
# matrix above. phone_ivr_caller_match answers the first two (undef when neither
# claims the number); phone_ivr_flow_for_number is the sibling of
# phone_ivr_flow_for_bucket and the one the phone's routing reads.
sub phone_ivr_caller_match {
	my ($number, $defs) = @_;
	my $key = &subs::phone_ivr_number_key($number);
	return undef unless length $key;
	$defs = &subs::phone_ivr_flow_defs() unless ref $defs eq 'HASH';
	my @flow_keys = sort keys %{$defs};

	# an exact line in a flow's callers is the most specific answer there is
	foreach my $flow_key ( @flow_keys ) {
		my $callers = $defs->{$flow_key}->{'callers'};
		next unless ref $callers eq 'ARRAY';
		foreach my $caller ( @{$callers} ) {
			next unless ref $caller eq 'HASH' && ($caller->{'kind'} || '') eq 'number';
			next unless &subs::phone_ivr_number_key($caller->{'value'}) eq $key;
			return {
				flow => $flow_key, kind => 'number', number => $key,
				label => $caller->{'label'} || '',
			};
		}
	}

	# then the body the line belongs to, in the order each caller list keeps
	my @apps = &subs::contact_apps('phone', $key);
	return undef unless scalar @apps;
	my %owns = map { $_ => 1 } @apps;
	my $bodies = &subs::phone_ivr_caller_bodies();
	foreach my $flow_key ( @flow_keys ) {
		my $callers = $defs->{$flow_key}->{'callers'};
		next unless ref $callers eq 'ARRAY';
		foreach my $caller ( @{$callers} ) {
			next unless ref $caller eq 'HASH';
			my $kind = $caller->{'kind'} || '';
			next unless grep { $_ eq $kind } @PHONE_IVR_BODY_KINDS;
			my $app = &subs::phone_ivr_caller_body_app($caller, $bodies);
			next unless length $app && $owns{$app};
			return {
				flow => $flow_key, kind => $kind, number => $key,
				uuid => $caller->{'uuid'} || '', label => $caller->{'label'} || '',
			};
		}
	}
	return undef;
}

# What a number hears: the flow a caller entry names, else the flow of the bucket
# the phone sent (the bucket matrix). The resolved flow carries its own key and
# the caller entry that chose it, so a caller that needs only the key does not
# read the defs a second time. '' means the call is not answered by a flow.
sub phone_ivr_flow_for_number {
	my ($number, $bucket, $defs) = @_;
	$defs = &subs::phone_ivr_flow_defs() unless ref $defs eq 'HASH';
	my $match = &subs::phone_ivr_caller_match($number, $defs);
	if ($match && ref $defs->{$match->{'flow'}} eq 'HASH') {
		my %flow = %{ $defs->{$match->{'flow'}} };
		$flow{'key'} = $match->{'flow'};
		$flow{'caller'} = $match;
		return \%flow;
	}
	return &subs::phone_ivr_flow_for_bucket($bucket);
}

# The same resolution as a flat number -> flow index, for the phone: the app has
# the house's numbers and names, never the settings rows, so every line an entry
# stands for is resolved here. The first claim wins, so a more specific entry
# keeps the number it named.
sub phone_ivr_caller_index {
	my ($defs) = @_;
	$defs = &subs::phone_ivr_flow_defs() unless ref $defs eq 'HASH';
	my $bodies = &subs::phone_ivr_caller_bodies();
	my %index;
	foreach my $flow_key ( sort keys %{$defs} ) {
		my $callers = $defs->{$flow_key}->{'callers'};
		next unless ref $callers eq 'ARRAY';
		foreach my $caller ( @{$callers} ) {
			next unless ref $caller eq 'HASH';
			my $kind = $caller->{'kind'} || '';
			foreach my $number ( &subs::phone_ivr_caller_numbers($caller, $bodies) ) {
				next if exists $index{$number};
				$index{$number} = {
					flow => $flow_key, kind => $kind, number => $number,
					label => $caller->{'label'} || '',
				};
			}
		}
	}
	return \%index;
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

# A recorded greeting arrives as whatever the browser recorded - webm/opus on
# a desktop, mp4/aac on a phone - and is kept as one mono WAV. ffprobe names
# its length so the route can refuse a long upload; a machine without ffprobe
# answers 0, and the route then trusts its byte cap.
sub phone_ivr_greeting_wav {
	my ($bytes) = @_;
	return (undef, 0) unless defined $bytes && length $bytes;
	require File::Temp;
	my ($in_fh, $in) = File::Temp::tempfile('jawn-greeting-XXXXXX', TMPDIR => 1, UNLINK => 0);
	return (undef, 0) unless $in_fh;
	binmode $in_fh;
	print {$in_fh} $bytes;
	close $in_fh;
	my $out = $in . '.wav';
	my $ran = system('ffmpeg', '-nostdin', '-loglevel', 'error', '-y',
		'-i', $in, '-ac', '1', '-ar', '16000', '-f', 'wav', $out);
	my $seconds = 0;
	my $wav;
	if ($ran == 0 && -s $out) {
		my $probe = '';
		if (open(my $ph, '-|', 'ffprobe', '-v', 'error', '-show_entries', 'format=duration',
			'-of', 'default=nw=1:nk=1', $out)) {
			local $/;
			$probe = <$ph> // '';
			close $ph;
		}
		$seconds = $1 + 0 if $probe =~ /^\s*(\d+(?:\.\d+)?)\s*$/;
		$wav = eval { &read_file($out) };
	}
	unlink $in, $out;
	return (defined $wav && length $wav ? $wav : undef, $seconds);
}

# Keep one recorded greeting: the WAV joins the app's own pictures, is filed on
# an appointment the way voicemail_file files a message, and the media tree is
# sealed with file_encrypter exactly as a capture is. The path returned is the
# one now on disk (a .enc when the house has encryption on), so saving the flow
# names the file the play route and the gateway will actually find.
sub phone_ivr_greeting_store {
	my ($bytes, %args) = @_;
	return '' unless defined $bytes && length $bytes;
	my $app = 'phone';
	my $app_path = &subs::path_name($app);
	my $timestamp = (defined $args{'timestamp'} && length $args{'timestamp'})
		? $args{'timestamp'} : &subs::rightNow();
	# a file name, not a path: a browser's timestamp may be anything
	$timestamp =~ s/\D+//g;
	$timestamp = substr($timestamp, 0, 20);
	$timestamp = &subs::rightNow() unless length $timestamp;
	my $folder = &subs::home(&subs::setting_grabber({ app => 'misc', setting => 'photo_location' }) || '~/Pictures');
	my $dir = $folder . '/' . $app_path;
	make_path($dir) unless -d $dir;
	my $file = $dir . '/' . $app_path . '_greeting_' . $timestamp . '.wav';
	open(my $out, '>', $file) or return '';
	binmode $out;
	print {$out} $bytes;
	close $out or return '';
	my $entry = {
		server_time => &subs::rightNow(),
		f => $file,
		uuid => &subs::random_string_creator(9),
		type => 'audio',
	};
	my $uuid = &subs::random_string_creator(20);
	my $wrote = eval {
		&subs::db_insert('appointments', {
			app => $app,
			type => 'audio',
			subtype => 'ivr_greeting',
			file => encode_json([ $entry ]),
			timestamp => $timestamp,
			server_time => &subs::rightNow(),
			uuid => $uuid,
			duration => 0,
		});
	};
	# A machine with no row still holds a playable greeting; only the sealing
	# step is skipped.
	return $file unless $wrote;
	eval { &subs::file_encrypter({ app => $app }) };
	my $sealed = eval { &subs::db_select('appointments', undef, { uuid => $uuid })->hashes->[0] };
	my $files = eval { decode_json($sealed->{'file'}) } || [];
	foreach my $one (ref $files eq 'ARRAY' ? @{$files} : ($files)) {
		next unless ref $one eq 'HASH' && ($one->{'uuid'} // '') eq $entry->{'uuid'};
		my $path = $one->{'f'} || '';
		return $path if length $path && -f $path;
	}
	# file_encrypter sealed the plaintext and something went wrong reading the
	# row back: an absent path is better than a name for a file that is gone.
	return -f $file ? $file : '';
}

# A voicemail is filed the way a capture is: the WAV is written beside the
# app's own pictures and the appointment carries one more file entry. The entry
# is the capture shape without a thumb or OCR, `type` audio, and the uuid of the
# Chat note that holds the call's words so the pane can show them together.
#
# $source is the kept WAV's path, or the bytes themselves when it is not a path.
# The caller pushes the returned hashref into the appointment's `file` column
# (and seals the tree with file_encrypter), exactly as take_picture does.
sub voicemail_file {
	my ($source, %args) = @_;
	return undef unless defined $source && length $source;
	my $bytes;
	if (-f $source) {
		open(my $in, '<', $source) or return undef;
		binmode $in;
		{
			local $/;
			$bytes = <$in>;
		}
		close $in;
	}
	else {
		$bytes = $source;
	}
	return undef unless defined $bytes && length $bytes;
	my $app = (defined $args{'app'} && length $args{'app'}) ? &subs::unformat_name($args{'app'}) : 'phone';
	my $app_path = &subs::path_name($app);
	my $timestamp = (defined $args{'timestamp'} && length $args{'timestamp'}) ? $args{'timestamp'} : &subs::rightNow();
	my $folder = &subs::home(&subs::setting_grabber({ app => 'misc', setting => 'photo_location' }) || 'Pictures');
	my $dir = $folder . '/' . $app_path;
	make_path($dir) unless -d $dir;
	my $file = $dir . '/' . $app_path . '_' . $timestamp . '.wav';
	open(my $out, '>', $file) or return undef;
	binmode $out;
	print {$out} $bytes;
	close $out;
	my %entry = (
		server_time => &subs::rightNow(),
		f => $file,
		uuid => &subs::random_string_creator(9),
		type => 'audio',
	);
	$entry{'note_uuid'} = $args{'note_uuid'}
		if defined $args{'note_uuid'} && length $args{'note_uuid'};
	return \%entry;
}

# The Chat note a screened call left for a number, by the call's end: the phone
# files the words when it logs the call, minutes after the gateway kept the WAV,
# so the voicemail finds its note by number and moment rather than by a pointer
# that does not exist yet. '' when no note is there (a call with no transcript).
sub voicemail_note_uuid {
	my ($number, $ended_ms) = @_;
	my $digits = defined $number ? $number : '';
	$digits =~ s/\D+//g;
	$digits =~ s/^1//;
	return '' unless length $digits;
	return '' unless defined $ended_ms && $ended_ms =~ /^\d+$/ && $ended_ms > 0;
	my $ended = &phone_call_epoch($ended_ms) * 1000;
	return '' unless $ended > 0;
	my $row = &subs::db_query(
		'select uuid from mailbox where phone=? and timestamp >= ? and timestamp <= ? order by timestamp desc limit 1',
		$digits, $ended - 600000, $ended + 600000,
	)->hashes->[0];
	return ($row && defined $row->{'uuid'} && length $row->{'uuid'}) ? $row->{'uuid'} : '';
}

1;
