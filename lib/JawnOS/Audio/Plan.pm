package JawnOS::Audio::Plan;

# The saved routing plan: what the patchbay draws, the UI stores and the engine
# consumes. It is decoded JSON held in a setting, not a table, so it follows the
# same idiom as Power's plan: a default, a normaliser for the read path and a
# validity check for the write path. Nothing here touches the database, the
# network or the engine; a plan is data, and this module is the shape it is
# allowed to have.
#
# Why normalise instead of trusting: a plan arrives from a browser, from an
# older version of the UI, or from a hand-edited setting. A missing field is an
# old plan, not an error; an unknown kind or a route to nothing is a mistake
# that must never reach the graph. So the read path fills and clamps, and the
# write path refuses the same mistakes instead of repairing them silently.
#
# The four lists are §7 of docs/studio-audio-roadmap.md: sources make samples,
# buses mix them (and may feed one another as a send), sinks take them, and a
# route is the edge between any two named things.

use strict;
use warnings;
use Scalar::Util qw(blessed looks_like_number);

# A source is anything that makes samples; a sink is anything that takes them.
# Anything else is either a bus or a typo, and neither belongs in these lists.
our @audio_plan_source_kinds = qw(input player peer handset device);
our @audio_plan_sink_kinds   = qw(interface speakers zone peer);

# A bus may feed a bus (a send), but only so far. The limit is the number of
# consecutive sends a plan may nest: enough for a monitor mix off the house bus
# and a zone off the monitor, not enough for a mistaken chain to make the
# engine's work unbounded. A cycle is impossible by construction (below), so
# this limit only bounds a legitimate chain's length.
our $audio_plan_max_send_depth = 6;

# The house's default rate when a declaration omits one. A node that does not
# say is far more likely to be a 48 kHz house device than to be mute.
our $audio_plan_default_rate = 48_000;

# A local `input` may name the capture node it listens to instead of taking the
# machine's default source. The value is a PipeWire/Pulse source name, so it
# uses the same discipline the Sound app's device ids use: one bare word, never
# a path, and never starting with `-` (which `parec` would read as an option).
# It is passed to the engine as an argument, never joined into a path.
our $audio_plan_node_max = 200;
our $audio_plan_node_pattern = qr/\A[A-Za-z0-9][A-Za-z0-9_.:@+\-]*\z/;

our $audio_plan_gain_min = 0;
our $audio_plan_gain_max = 1;
our $audio_plan_pan_min  = -1;
our $audio_plan_pan_max  = 1;

# A source's own trim runs before its inserts and every route, so it is the
# engine's +12 dB recording gain rather than a mix level: `docs/studio-effects.md`
# says `0..=4`. The route gain above stays the 0..1 mix fader it always was.
our $audio_plan_source_gain_max = 4;

# The engine refuses a peer source whose declared latency is above 2 000 ms;
# the bound is a sanity limit, not a placement guarantee. Keep the read path's
# clamp and the write path's refusal on this one number.
our $audio_plan_max_peer_latency = 2_000;

# A peer's read buffer: how far behind the clock the master reads its audio. It
# has the same sanity bound as the latency, and the engine's floor is one jitter
# window, 85 ms at 48 kHz. The default is written into the plan so the Sound
# page shows what the engine will do instead of an empty field.
our $audio_plan_peer_buffer_default = 85;
our $audio_plan_max_peer_buffer = 2_000;

# A `player` source is a Studio app's own audio, carried to the engine by this
# machine's local audio input instead of the uplink. `lead_ms` is how far ahead
# of its arrival the first frame is placed on the master timeline: enough that
# the sender's own jitter never starves the reader, small enough to feel live.
# `buffer_ms` is the same read-head fact a peer declares. Both keep the peer
# sanity bound, and both are written into the plan so the page shows what the
# engine will do instead of an empty field.
our $audio_plan_player_lead_default = 100;
our $audio_plan_max_player_lead = 2_000;
our $audio_plan_player_buffer_default = $audio_plan_peer_buffer_default;
our $audio_plan_max_player_buffer = 2_000;

# A source may carry a pedal board of its own: the effects the engine builds on
# the source before any route, so a voice or a deck can be coloured without
# owning a Studio track. The names are the engine's `InsertKind` vocabulary
# (engine/src/effect.rs, docs/studio-effects.md); `stereowidener` is deliberately
# absent because the native engine has no such effect, and the `master_` names
# belong to the master rack rather than a source. Chain order is array order.
#
# One insert is `{ name, bypass, controls }`. `bypass` keeps the insert in the
# chain but passes the signal through. `controls` is a sparse map of the
# effect's own control names to native units (the contract's dB, milliseconds,
# 0..1 mixes and whole indexes), never the UI's 0..100 slider; an absent control
# means the effect's own default, and the engine clamps a value it receives.
# The read path keeps only a known name and its known controls, while the write
# path refuses either mistake instead of dropping it.
our @audio_plan_insert_names = qw(
	tone distortion delay compressor reverb flanger
	fuzz amp limiter autotune equalizer maximizer
);

our %audio_plan_insert_controls = (
	tone       => [qw(bass mid treble gain)],
	distortion => [qw(drive)],
	delay      => [qw(time feedback vol)],
	compressor => [qw(thresh attack ratio release knee mix)],
	reverb     => [qw(mix volume model)],
	flanger    => [qw(rate depth feedback mix)],
	fuzz       => [qw(gain tone level)],
	amp        => [qw(gain bass mid treble cabinet)],
	limiter    => [qw(ceiling release)],
	autotune   => [qw(speed amount key scale)],
	equalizer  => [qw(low mid high)],
	maximizer  => [qw(ceiling loudness)],
);

# These controls are an index, not a level: a fractional reverb model or amp
# cabinet has no meaning. The read path truncates one, the write path refuses it.
our %audio_plan_insert_whole = (
	reverb   => { model   => 1 },
	amp      => { cabinet => 1 },
	autotune => { key     => 1, scale => 1 },
);

# A source's board is a chain, not a rack: enough pedals for a treated voice
# without letting a hand-edited plan make the engine's work unbounded.
our $audio_plan_max_inserts = 16;

# An empty plan is valid and means "nothing routed", which is not the same as
# "no plan": the engine sees four empty lists and leaves the interface alone
# until a person draws something. A missing plan is the caller's problem.
sub audio_plan_default {
	return {
		sources => [],
		buses   => [],
		sinks   => [],
		routes  => [],
	};
}

# ---- small readers ---------------------------------------------------------
# Each one answers "is this a usable value", never dies. A plan from a browser
# is untrusted input even when the person is trusted.

sub _audio_plan_list {
	my ($value) = @_;
	return ref $value eq 'ARRAY' ? $value : [];
}

sub _audio_plan_text {
	my ($value) = @_;
	return undef unless defined $value && !ref $value;
	$value = "$value";
	return length $value ? $value : undef;
}

sub _audio_plan_number {
	my ($value) = @_;
	return undef unless defined $value && !ref $value && looks_like_number($value);
	my $number = $value + 0;
	return undef unless $number == $number;    # NaN is not a position
	return undef if abs($number) > 1_000_000_000_000;
	return $number;
}

sub _audio_plan_count {
	my ($value, $fallback) = @_;
	my $number = _audio_plan_number($value);
	return $fallback unless defined $number;
	$number = int($number);
	return $number > 0 ? $number : $fallback;
}

sub _audio_plan_nonnegative {
	my ($value, $fallback) = @_;
	my $number = _audio_plan_number($value);
	return $fallback unless defined $number;
	return $number < 0 ? 0 : $number;
}

sub _audio_plan_clamp {
	my ($value, $low, $high) = @_;
	$value = $low  if $value < $low;
	$value = $high if $value > $high;
	return $value;
}

sub _audio_plan_kind {
	my ($kind, $allowed) = @_;
	return 0 unless defined $kind;
	return (grep { $_ eq $kind } @$allowed) ? 1 : 0;
}

# Is this one of the engine's source-effect names? Exported so the page can
# offer the same list the write path accepts, and the engine agent has one
# stable vocabulary to compile.
sub audio_plan_insert_valid {
	my ($name) = @_;
	return 0 unless defined $name && !ref $name;
	return (grep { $_ eq $name } @audio_plan_insert_names) ? 1 : 0;
}

# One insert, repaired for the read path. An unknown effect is dropped whole;
# a control the effect does not have is dropped from the map; a fractional
# index control is truncated. A missing bypass is the inserted state.
sub _audio_plan_insert {
	my ($entry) = @_;
	return undef unless ref $entry eq 'HASH';
	my $name = _audio_plan_text($entry->{name});
	return undef unless defined $name && audio_plan_insert_valid($name);

	my %allowed = map { $_ => 1 } @{ $audio_plan_insert_controls{$name} || [] };
	my $given = ref $entry->{controls} eq 'HASH' ? $entry->{controls} : {};
	my %controls;
	foreach my $control (sort keys %$given) {
		next unless $allowed{$control};
		my $value = _audio_plan_number($given->{$control});
		next unless defined $value;
		$value = int($value) if $audio_plan_insert_whole{$name}{$control};
		$controls{$control} = $value;
	}

	return {
		name     => $name,
		bypass   => $entry->{bypass} ? 1 : 0,
		controls => \%controls,
	};
}

# Is this a capture node name a plan may carry? Exported because the picker and
# the write path ask the same question, and a value the engine would hand to
# `parec` as an option is not a name.
sub audio_plan_node_valid {
	my ($node) = @_;
	return 0 unless defined $node && !ref $node;
	$node = "$node";
	return 0 unless length $node && length $node <= $audio_plan_node_max;
	return $node =~ $audio_plan_node_pattern ? 1 : 0;
}

# Does this node belong to the machine that is asking? A plan's `machine` names
# the machine that owns a source or sink. A blank one is the older spelling of
# "this machine", and Sound's source form and the engine both write the
# hostname into the field, so an explicit name that is this host means the same
# thing. A name that is another machine is not this machine's node: the picker
# does not list it and the write path refuses it. The comparison folds case,
# and a caller that already read the host (SystemMix) passes it in.
sub audio_plan_on_this_machine {
	my ($machine, $host) = @_;
	$machine = '' unless defined $machine && !ref $machine;
	return 1 if $machine eq '';
	unless (@_ > 1) {
		require Sys::Hostname;
		$host = eval { Sys::Hostname::hostname() } || '';
	}
	$host = '' unless defined $host && !ref $host;
	return 0 unless length $host;
	return lc($machine) eq lc($host) ? 1 : 0;
}

# One source or sink entry, with the optional facts filled in. The identity
# (`id` and `kind`) is the entry; a missing rate or channel count is an older
# declaration, so it takes the default rather than removing the node.
sub _audio_plan_node {
	my ($entry, $id, $kind, $type) = @_;
	my $label = _audio_plan_text($entry->{label});
	$label = $id unless defined $label;
	# Which device channel the node binds to on the machine that runs it: an
	# input index for a source, the first channel of a stereo pair for a sink.
	# A missing value is channel 0, which is what every plan written before the
	# engine could bind one meant.
	my $channel = _audio_plan_number($entry->{channel});
	$channel = defined $channel && $channel >= 0 ? int($channel) : 0;
	# The capture node a local `input` listens to. Only an `input` has one: a
	# `device` source is the system mix, captured from the sink it was made
	# for, and a `handset` is the reception mixer's call monitor. A name that
	# fails the charset is dropped rather than carried to the engine, where it
	# would be a command option rather than a source.
	my $node = _audio_plan_text($entry->{node});
	$node = undef unless defined $node && $kind eq 'input' && audio_plan_node_valid($node);
	# A peer's placement is bounded by what the engine accepts: the non-negative
	# rule below, plus the engine's sanity limit. A local input keeps the whole
	# non-negative range; the engine does not place that declaration on this path.
	my $latency = _audio_plan_nonnegative($entry->{latency_ms}, 0);
	$latency = $audio_plan_max_peer_latency
		if $type eq 'source' && $kind eq 'peer'
			&& $latency > $audio_plan_max_peer_latency;
	# How far behind the clock the reader reads a stream of its own. A peer is
	# read by the uplink and a player by the local audio input, so those two
	# carry the field; anything shorter than one jitter window is raised to it
	# by the engine, whose report says which buffer it actually ran.
	my $buffer;
	if ($type eq 'source' && $kind eq 'peer') {
		$buffer = _audio_plan_nonnegative($entry->{buffer_ms}, $audio_plan_peer_buffer_default);
		$buffer = $audio_plan_max_peer_buffer
			if $buffer > $audio_plan_max_peer_buffer;
	}
	elsif ($type eq 'source' && $kind eq 'player') {
		$buffer = _audio_plan_nonnegative($entry->{buffer_ms}, $audio_plan_player_buffer_default);
		$buffer = $audio_plan_max_player_buffer
			if $buffer > $audio_plan_max_player_buffer;
	}
	# A player's lead: how far ahead of arrival the local reader anchors its
	# first frame. No other kind declares one.
	my $lead;
	if ($type eq 'source' && $kind eq 'player') {
		$lead = _audio_plan_nonnegative($entry->{lead_ms}, $audio_plan_player_lead_default);
		$lead = $audio_plan_max_player_lead
			if $lead > $audio_plan_max_player_lead;
	}
	# The source's own pedal board, in chain order. Only a source has one: a
	# sink takes what the buses send it, and inserts on that edge belong to the
	# route, not the sink. A plan from before this field has an empty board.
	my $inserts;
	if ($type eq 'source') {
		$inserts = [];
		foreach my $insert (@{ _audio_plan_list($entry->{inserts}) }) {
			last if scalar(@$inserts) >= $audio_plan_max_inserts;
			my $clean = _audio_plan_insert($insert);
			push @$inserts, $clean if $clean;
		}
	}
	# The source's own trim, before its inserts. A plan from before this field
	# is a wire; a value past the engine's +12 dB range is clamped here and
	# refused on the write path, exactly as a route gain is.
	my $source_gain;
	if ($type eq 'source') {
		$source_gain = _audio_plan_number($entry->{gain});
		$source_gain = 1 unless defined $source_gain;
		$source_gain = _audio_plan_clamp($source_gain, 0, $audio_plan_source_gain_max);
	}
	return {
		id         => $id,
		label      => $label,
		kind       => $kind,
		machine    => _audio_plan_text($entry->{machine}) || '',
		rate       => _audio_plan_count($entry->{rate}, $audio_plan_default_rate),
		channels   => _audio_plan_count($entry->{channels}, 1),
		channel    => $channel,
		node       => defined $node ? $node : '',
		latency_ms => $latency,
		(defined $buffer ? (buffer_ms => $buffer) : ()),
		(defined $lead ? (lead_ms => $lead) : ()),
		(defined $source_gain ? (gain => $source_gain) : ()),
		(defined $inserts ? (inserts => $inserts) : ()),
	};
}

sub _audio_plan_bus {
	my ($entry, $id) = @_;
	my $label = _audio_plan_text($entry->{label});
	$label = $id unless defined $label;
	return { id => $id, label => $label };
}

# Is $target already reachable from $start along accepted routes? A new route
# in the other direction would close a loop, and a loop is a node that sums its
# own output: with a delay it grows without bound, and without one it never
# settles. The plan is declarative, so the answer has to be acyclic before it is
# written, not caught by the engine afterwards.
sub _audio_plan_reaches {
	my ($start, $target, $edges) = @_;
	return 1 if $start eq $target;
	my %seen;
	my @stack = ($start);
	while (@stack) {
		my $node = pop @stack;
		next if $seen{$node}++;
		my $next = $edges->{$node} or next;
		foreach my $to (@$next) {
			return 1 if $to eq $target;
			push @stack, $to;
		}
	}
	return 0;
}

# The longest chain of bus sends ending at each bus. The accepted graph is
# acyclic, so relaxing the edges to a fixed point terminates; `@$routes + 1`
# passes is more than a chain can need.
sub _audio_plan_depths {
	my ($routes) = @_;
	my %depth;
	my $passes = scalar(@$routes) + 1;
	my $changed = 1;
	while ($changed && $passes-- > 0) {
		$changed = 0;
		foreach my $route (@$routes) {
			my $candidate = ($depth{ $route->{from} } || 0) + 1;
			next if $candidate <= ($depth{ $route->{to} } || 0);
			$depth{ $route->{to} } = $candidate;
			$changed = 1;
		}
	}
	return \%depth;
}

sub _audio_plan_is_bus_route {
	my ($route, $kind_of) = @_;
	return $kind_of->{ $route->{from} } eq 'bus' && $kind_of->{ $route->{to} } eq 'bus';
}

# ---- the read path ---------------------------------------------------------

sub audio_plan_normalize {
	my ($decoded) = @_;
	$decoded = {} unless ref $decoded eq 'HASH';

	my (@sources, @buses, @sinks, @routes);
	my %kind_of;    # id -> source|bus|sink; an id names one thing, everywhere
	my %edges;      # from -> [to], the routes accepted so far

	foreach my $entry (@{ _audio_plan_list($decoded->{sources}) }) {
		next unless ref $entry eq 'HASH';
		my $id = _audio_plan_text($entry->{id});
		next unless defined $id && !$kind_of{$id};
		my $kind = _audio_plan_text($entry->{kind});
		next unless _audio_plan_kind($kind, \@audio_plan_source_kinds);
		$kind_of{$id} = 'source';
		push @sources, _audio_plan_node($entry, $id, $kind, 'source');
	}

	foreach my $entry (@{ _audio_plan_list($decoded->{buses}) }) {
		next unless ref $entry eq 'HASH';
		my $id = _audio_plan_text($entry->{id});
		next unless defined $id && !$kind_of{$id};
		$kind_of{$id} = 'bus';
		push @buses, _audio_plan_bus($entry, $id);
	}

	foreach my $entry (@{ _audio_plan_list($decoded->{sinks}) }) {
		next unless ref $entry eq 'HASH';
		my $id = _audio_plan_text($entry->{id});
		next unless defined $id && !$kind_of{$id};
		my $kind = _audio_plan_text($entry->{kind});
		next unless _audio_plan_kind($kind, \@audio_plan_sink_kinds);
		$kind_of{$id} = 'sink';
		push @sinks, _audio_plan_node($entry, $id, $kind, 'sink');
	}

	foreach my $entry (@{ _audio_plan_list($decoded->{routes}) }) {
		next unless ref $entry eq 'HASH';
		my $from = _audio_plan_text($entry->{from});
		my $to   = _audio_plan_text($entry->{to});
		next unless defined $from && defined $to;
		next unless $kind_of{$from} && $kind_of{$to};
		next if $from eq $to;

		# A loop is unbounded whether or not a bus is in it. The roadmap names
		# bus -> bus because that is where sends live; the check covers every
		# edge, and the depth limit below is the bus-only part.
		next if _audio_plan_reaches($to, $from, \%edges);

		# Gain and pan are the only values the engine must never receive out of
		# range: a gain of 5 is a mistake, not a louder mix, and a pan outside
		# the speakers has no position. Clamping keeps a slightly-wrong slider
		# usable; a missing value is the neutral one.
		my $gain = _audio_plan_number($entry->{gain});
		$gain = 1 unless defined $gain;
		$gain = _audio_plan_clamp($gain, $audio_plan_gain_min, $audio_plan_gain_max);

		my $pan = _audio_plan_number($entry->{pan});
		$pan = 0 unless defined $pan;
		$pan = _audio_plan_clamp($pan, $audio_plan_pan_min, $audio_plan_pan_max);

		push @routes, {
			from     => $from,
			to       => $to,
			gain     => $gain,
			pan      => $pan,
			mute     => $entry->{mute} ? 1 : 0,
			delay_ms => _audio_plan_nonnegative($entry->{delay_ms}, 0),
		};

		push @{ $edges{$from} }, $to;
	}

	# Truncate a chain that has grown past the send limit. The depths are
	# computed once, before anything is dropped: dropping only shortens the
	# chains the survivors sit on, so a route that fits now still fits after.
	my $bus_routes = [ grep { _audio_plan_is_bus_route($_, \%kind_of) } @routes ];
	my $depth = _audio_plan_depths($bus_routes);
	@routes = grep {
		_audio_plan_is_bus_route($_, \%kind_of)
			? (($depth->{ $_->{from} } || 0) + 1 <= $audio_plan_max_send_depth)
			: 1
	} @routes;

	return {
		sources => \@sources,
		buses   => \@buses,
		sinks   => \@sinks,
		routes  => \@routes,
	};
}

# ---- the write path --------------------------------------------------------

# One source or sink declaration is valid when it has an id and a known kind,
# and every optional field it does carry is usable. Optional fields are allowed
# to be absent because the normaliser supplies the neutral value; a field that
# is present and out of range is a bug in the writer, so it is refused rather
# than quietly clamped on save.
sub _audio_plan_valid_node {
	my ($entry, $allowed, $kind_of, $type) = @_;
	return 0 unless ref $entry eq 'HASH';

	my $id = _audio_plan_text($entry->{id});
	return 0 unless defined $id && !$kind_of->{$id};

	my $kind = _audio_plan_text($entry->{kind});
	return 0 unless _audio_plan_kind($kind, $allowed);

	if (exists $entry->{label}) {
		return 0 if ref $entry->{label};
	}
	if (exists $entry->{machine}) {
		return 0 if ref $entry->{machine};
	}
	if (exists $entry->{rate}) {
		my $number = _audio_plan_number($entry->{rate});
		return 0 unless defined $number && int($number) == $number && $number > 0;
	}
	if (exists $entry->{channels}) {
		my $number = _audio_plan_number($entry->{channels});
		return 0 unless defined $number && int($number) == $number && $number > 0;
	}
	if (exists $entry->{channel}) {
		my $number = _audio_plan_number($entry->{channel});
		return 0 unless defined $number && int($number) == $number && $number >= 0;
	}
	if (exists $entry->{latency_ms}) {
		my $number = _audio_plan_number($entry->{latency_ms});
		return 0 unless defined $number && $number >= 0;
		return 0 if $type eq 'source' && $kind eq 'peer'
			&& $number > $audio_plan_max_peer_latency;
	}
	if (exists $entry->{buffer_ms}) {
		my $number = _audio_plan_number($entry->{buffer_ms});
		return 0 unless defined $number && $number >= 0;
		return 0 if $type eq 'source' && $kind eq 'peer'
			&& $number > $audio_plan_max_peer_buffer;
		return 0 if $type eq 'source' && $kind eq 'player'
			&& $number > $audio_plan_max_player_buffer;
	}
	if (exists $entry->{lead_ms}) {
		my $number = _audio_plan_number($entry->{lead_ms});
		return 0 unless defined $number && $number >= 0;
		return 0 if $type eq 'source' && $kind eq 'player'
			&& $number > $audio_plan_max_player_lead;
	}
	if (exists $entry->{node}) {
		# Only an `input` captures from a node; a node on any other kind is a
		# writer's mistake, and an empty node means "the machine's default".
		my $node = $entry->{node};
		return 0 if ref $node;
		$node = '' unless defined $node;
		if (length "$node") {
			return 0 unless $kind eq 'input' && audio_plan_node_valid($node);
		}
	}
	# The source's own trim, before its inserts. A sink has no trim of its own.
	if (exists $entry->{gain}) {
		return 0 unless $type eq 'source';
		my $number = _audio_plan_number($entry->{gain});
		return 0 unless defined $number
			&& $number >= 0 && $number <= $audio_plan_source_gain_max;
	}
	# A source's pedal board. The read path drops an unknown effect or control;
	# the write path refuses it, because a plan that names an effect the engine
	# cannot build is a writer's bug rather than an older plan.
	if (exists $entry->{inserts}) {
		return 0 unless $type eq 'source';
		return 0 unless ref $entry->{inserts} eq 'ARRAY';
		return 0 if scalar(@{ $entry->{inserts} }) > $audio_plan_max_inserts;
		foreach my $insert (@{ $entry->{inserts} }) {
			return 0 unless ref $insert eq 'HASH';
			my $name = _audio_plan_text($insert->{name});
			return 0 unless defined $name && audio_plan_insert_valid($name);

			if (exists $insert->{bypass}) {
				my $bypass = $insert->{bypass};
				if (ref $bypass) {
					return 0 unless blessed($bypass);
				}
				else {
					my $number = _audio_plan_number($bypass);
					return 0 unless defined $number && ($number == 0 || $number == 1);
				}
			}
			if (exists $insert->{controls}) {
				return 0 unless ref $insert->{controls} eq 'HASH';
				my %allowed = map { $_ => 1 } @{ $audio_plan_insert_controls{$name} || [] };
				foreach my $control (keys %{ $insert->{controls} }) {
					return 0 unless $allowed{$control};
					my $value = _audio_plan_number($insert->{controls}{$control});
					return 0 unless defined $value;
					return 0 if $audio_plan_insert_whole{$name}{$control}
						&& int($value) != $value;
				}
			}
		}
	}

	$kind_of->{$id} = $type;
	return 1;
}

sub audio_plan_valid {
	my ($decoded) = @_;
	return 0 unless ref $decoded eq 'HASH';
	return 0 unless ref $decoded->{sources} eq 'ARRAY'
		&& ref $decoded->{buses} eq 'ARRAY'
		&& ref $decoded->{sinks} eq 'ARRAY'
		&& ref $decoded->{routes} eq 'ARRAY';

	my %kind_of;

	foreach my $entry (@{ $decoded->{sources} }) {
		return 0 unless _audio_plan_valid_node($entry, \@audio_plan_source_kinds, \%kind_of, 'source');
	}

	foreach my $entry (@{ $decoded->{buses} }) {
		return 0 unless ref $entry eq 'HASH';
		my $id = _audio_plan_text($entry->{id});
		return 0 unless defined $id && !$kind_of{$id};
		return 0 if exists $entry->{label} && ref $entry->{label};
		$kind_of{$id} = 'bus';
	}

	foreach my $entry (@{ $decoded->{sinks} }) {
		return 0 unless _audio_plan_valid_node($entry, \@audio_plan_sink_kinds, \%kind_of, 'sink');
	}

	my %edges;
	foreach my $entry (@{ $decoded->{routes} }) {
		return 0 unless ref $entry eq 'HASH';
		my $from = _audio_plan_text($entry->{from});
		my $to   = _audio_plan_text($entry->{to});
		return 0 unless defined $from && defined $to && $kind_of{$from} && $kind_of{$to};
		return 0 if $from eq $to;

		return 0 if _audio_plan_reaches($to, $from, \%edges);

		if (exists $entry->{gain}) {
			my $gain = _audio_plan_number($entry->{gain});
			return 0 unless defined $gain
				&& $gain >= $audio_plan_gain_min && $gain <= $audio_plan_gain_max;
		}
		if (exists $entry->{pan}) {
			my $pan = _audio_plan_number($entry->{pan});
			return 0 unless defined $pan
				&& $pan >= $audio_plan_pan_min && $pan <= $audio_plan_pan_max;
		}
		if (exists $entry->{delay_ms}) {
			my $delay = _audio_plan_number($entry->{delay_ms});
			return 0 unless defined $delay && $delay >= 0;
		}
		if (exists $entry->{mute}) {
			my $mute = $entry->{mute};
			if (ref $mute) {
				return 0 unless blessed($mute);
			}
			else {
				my $number = _audio_plan_number($mute);
				return 0 unless defined $number && ($number == 0 || $number == 1);
			}
		}

		push @{ $edges{$from} }, $to;
	}

	my $bus_routes = [ grep { _audio_plan_is_bus_route($_, \%kind_of) } @{ $decoded->{routes} } ];
	my $depth = _audio_plan_depths($bus_routes);
	foreach my $route (@$bus_routes) {
		return 0 if ($depth->{ $route->{from} } || 0) + 1 > $audio_plan_max_send_depth;
	}

	return 1;
}

# ---- what the UI asks ------------------------------------------------------

# The declared latency of one sink, in milliseconds: the sink's own delay plus
# the latest arrival among everything routed into it. A mix is complete only
# when its slowest input arrives, so a bus takes the maximum over its inbound
# routes, not a sum: two sources do not arrive one after the other. The value is
# what the matrix shows beside a zone so it is never mistaken for a booth.
sub _audio_plan_arrival {
	my ($id, $nodes, $inbound, $memo) = @_;
	return $memo->{$id} if exists $memo->{$id};

	my $own = $nodes->{$id} ? ($nodes->{$id}->{latency_ms} || 0) : 0;
	my $latest = 0;
	foreach my $route (@{ $inbound->{$id} || [] }) {
		my $arrival = _audio_plan_arrival($route->{from}, $nodes, $inbound, $memo)
			+ $route->{delay_ms};
		$latest = $arrival if $arrival > $latest;
	}

	$memo->{$id} = $own + $latest;
	return $memo->{$id};
}

sub audio_plan_latency {
	my ($plan, $sink_id) = @_;
	$sink_id = _audio_plan_text($sink_id);
	return 0 unless defined $sink_id;

	my $clean = audio_plan_normalize($plan);
	my %sinks = map { $_->{id} => 1 } @{ $clean->{sinks} };
	return 0 unless $sinks{$sink_id};

	my %nodes;
	foreach my $node (@{ $clean->{sources} }, @{ $clean->{sinks} }) {
		$nodes{ $node->{id} } = { latency_ms => $node->{latency_ms} };
	}

	my %inbound;
	foreach my $route (@{ $clean->{routes} }) {
		push @{ $inbound{ $route->{to} } }, $route;
	}

	my %memo;
	return _audio_plan_arrival($sink_id, \%nodes, \%inbound, \%memo) + 0;
}

1;
