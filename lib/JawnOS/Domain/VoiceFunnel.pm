package subs;

# Voice funnel: turn one spoken request into a small, scoped prompt instead of
# handing the Guide every app and every tool on every turn.
#
# The funnel has four jobs:
#   1. a fast path for data questions that need no model at all (weather first);
#   2. a deterministic match from the words to one help topic, using the same
#      tier-1 registry the Help window reads (perl/help/topics_*.pl);
#   3. a scoped prompt: one topic's briefing and inventory, plus only the verbs
#      the voice executor can actually run;
#   4. a router agent, called only when the deterministic match is weak or tied,
#      which picks a topic from a compact catalogue.
#
# The help registry is the source of truth for what an app does. A change that
# updates the help topic therefore updates what voice can find, without adding a
# second hand-written catalogue.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Mojo::JSON qw(decode_json encode_json);

our $CATALOG;
our %STOP = map { $_ => 1 } qw(
	a an the and or but if then than that this these those there here
	i me my mine we us our you your he she it they them their
	is are was were be been being am do does did done doing
	have has had having can could would should will shall may might must
	to of in on at for from by with about into over after before under
	what whats when where who whom why how which whose
	please tell show give get got make made let
	not no yes ok okay just only also very really
	time times thing things stuff something anything
);

# ---- catalogue -------------------------------------------------------------

sub _voice_funnel_help {
	return 1 if defined &help::catalogue;
	eval { require './perl/help.pl'; 1 } ? 1 : 0;
}

sub voice_funnel_words($text) {
	my $s = lc(defined $text ? $text : '');
	$s =~ s/[^\p{L}\p{N}]+/ /g;
	my %w;
	foreach my $word (split /\s+/, $s) {
		next unless length($word) >= 3;
		next if $STOP{$word};
		$w{$word} = 1;
	}
	return \%w;
}

# One entry per help topic. The body is only the first few paragraphs: enough to
# catch a phrase like "shopping list", not so much that every generic word in a
# long page starts matching.
sub voice_funnel_catalog {
	return $CATALOG if $CATALOG;
	return [] unless &_voice_funnel_help();
	my @out;
	foreach my $row ( help::catalogue() ) {
		my $id = $row->{'id'} // '';
		next unless length $id;
		my $t = help::get($id) or next;
		my @body = @{ $t->{'body'} || [] };
		@body = @body[0 .. 2] if @body > 3;
		my $body = join ' ', @body, @{ $t->{'steps'} || [] }, ($t->{'prompt'} // '');
		my $entry = {
			id => $id,
			app => ($t->{'app'} // ''),
			title => ($t->{'title'} // $id),
			summary => ($t->{'summary'} // ''),
			category => ($t->{'category'} // ''),
			title_words => &voice_funnel_words($t->{'title'} // ''),
			summary_words => &voice_funnel_words($t->{'summary'} // ''),
			body_words => &voice_funnel_words($body),
			aliases => [],
		};
		push @out, $entry;
	}
	# A taught alias ("zzz means sleep") belongs to the app, so it also makes
	# that app easier to find by voice. guide_aka_read is the same map the name
	# resolver uses.
	my $aka = eval { &subs::guide_aka_read() } || {};
	foreach my $e (@out) {
		next unless length($e->{'app'} // '');
		my @names = @{ $aka->{ $e->{'app'} } || [] };
		$e->{'aliases'} = [ @names ];
		$e->{'title_words'}->{ &guide_name_normalize($_) } = 1 for grep { length } @names;
	}
	$CATALOG = \@out;
	return $CATALOG;
}

# ---- deterministic match ---------------------------------------------------

sub _voice_funnel_score_word($word, $set) {
	return 0 unless ref $set eq 'HASH' && %$set;
	return 12 if $set->{$word};
	# A small amount of stemming: "weigh" should find "weight", "shop" should
	# find "shopping". Only at four letters or more, so "car" cannot match
	# "career" by accident.
	return 0 unless length($word) >= 4;
	foreach my $w (keys %$set) {
		next unless length($w) >= 4;
		return 8 if index($w, $word) == 0 || index($word, $w) == 0;
	}
	return 0;
}

sub voice_funnel_match($text) {
	my $words = &voice_funnel_words($text);
	# The person's everyday word often differs from the word the help page uses.
	# Add the doc's word alongside it; the alias is only a matcher hint, never a
	# rewrite of the request sent to the Guide.
	my %synonym = (
		weigh => 'weight', weight => 'weight', weighing => 'weight',
		steps => 'walk', step => 'walk', walked => 'walk', walking => 'walk',
		spend => 'budget', spent => 'budget', spending => 'budget',
		mail => 'email', emails => 'email', calendar => 'appointments',
		visit => 'travel', visited => 'travel', trip => 'travel',
		bike => 'bicycle', shop => 'market', shopping => 'market',
	);
	foreach my $w (keys %$words) { $words->{ $synonym{$w} } = 1 if $synonym{$w}; }
	my $flat = lc(defined $text ? $text : '');
	$flat =~ s/[^\p{L}\p{N}]+/ /g;
	$flat =~ s/^\s+|\s+$//g;
	my @tword = split /\s+/, $flat;
	my %tset = map { $_ => 1 } @tword;
	# A phrase counts only as whole words. Matching the compact form let "pen"
	# fire inside "spend" and "chat" inside "chatter"; a voice router that acts
	# on a substring is worse than one that asks.
	my $phrase = sub {
		my ($p) = @_;
		my @p = split /\s+/, $p // '';
		return 0 unless @p && @p <= @tword;
		for my $i (0 .. $#tword - $#p) {
			my $ok = 1;
			for my $j (0 .. $#p) { $ok = 0 if $tword[$i + $j] ne $p[$j]; }
			return 1 if $ok;
		}
		return 0;
	};
	my @cand;
	foreach my $e ( @{ &voice_funnel_catalog() } ) {
		my $score = 0;
		my %matched;
		my $app_phrase = join ' ', grep { length } split /[_\s]+/, lc($e->{'app'} // '');
		my $id_phrase = join ' ', grep { length } split /[_\s]+/, lc($e->{'id'} // '');
		my $title_phrase = join ' ', grep { length } split /[_\s]+/, lc($e->{'title'} // '');
		$score += 45 if length($app_phrase) && $phrase->($app_phrase);
		$score += 40 if length($id_phrase) && $id_phrase ne $app_phrase && $phrase->($id_phrase);
		$score += 30 if length($title_phrase) && $title_phrase ne $app_phrase && $phrase->($title_phrase);
		foreach my $alias ( @{ $e->{'aliases'} || [] } ) {
			my $a = join ' ', grep { length } split /[_\s]+/, lc($alias);
			$score += 28 if length($a) && $phrase->($a);
		}
		# All the words of a short app/title still count when they are present in
		# any order; this catches "the email window" without a substring match.
		my @app_words = grep { length } split /\s+/, $app_phrase;
		$score += 20 if @app_words && !grep { !$tset{$_} } @app_words;
		my @title_words = grep { length } split /\s+/, $title_phrase;
		$score += 12 if @title_words && !grep { !$tset{$_} } @title_words;
		foreach my $w ( keys %$words ) {
			my $hit = 0;
			$hit = &_voice_funnel_score_word($w, $e->{'title_words'});
			$score += $hit;
			$matched{$w} = 1 if $hit;
			$hit = &_voice_funnel_score_word($w, $e->{'summary_words'});
			$score += $hit / 2;
			$matched{$w} = 1 if $hit;
			$hit = &_voice_funnel_score_word($w, $e->{'body_words'});
			$score += $hit / 6;
			$matched{$w} = 1 if $hit;
		}
		next unless $score > 0;
		push @cand, {
			id => $e->{'id'}, app => $e->{'app'}, title => $e->{'title'},
			summary => $e->{'summary'}, category => $e->{'category'},
			score => $score, matched => [ sort keys %matched ],
		};
	}
	@cand = sort {
		$b->{'score'} <=> $a->{'score'}
			|| lc($a->{'title'}) cmp lc($b->{'title'})
	} @cand;
	return @cand;
}

# ---- scoped prompt ---------------------------------------------------------

sub _voice_funnel_clip($text, $max) {
	$text = defined $text ? "$text" : '';
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return $text if length($text) <= $max;
	my $cut = substr($text, 0, $max);
	$cut =~ s/\s+\S*$//;
	return $cut . '...';
}

sub voice_funnel_scope_for($id, $opts = {}) {
	$opts ||= {};
	return { ok => 0 } unless &_voice_funnel_help();
	my $t = help::get($id) or return { ok => 0 };
	my $brief = eval { help::briefing($id) } || '';
	my $inv = eval { help::inventory($id) } || '';
	my $verbs = &voice_funnel_verbs($t);
	return {
		ok => 1,
		id => $id,
		app => ($t->{'app'} // $id),
		title => ($t->{'title'} // $id),
		summary => ($t->{'summary'} // ''),
		briefing => &_voice_funnel_clip(join("\n", grep { length } ($brief, $inv)), 3200),
		verbs => $verbs,
		score => ($opts->{'score'} // 0),
		why => ($opts->{'why'} // 'match'),
		confidence => ($opts->{'confidence'} // ''),
	};
}

sub voice_funnel_scope($text) {
	my @c = &voice_funnel_match($text);
	return { ok => 0, candidates => [] } unless @c;
	my $top = $c[0];
	return { ok => 0, candidates => \@c } unless $top->{'score'} >= 12;
	my $second = @c > 1 ? $c[1]->{'score'} : 0;
	# A near tie is exactly what the router agent is for: the deterministic
	# matcher knows two pages are plausible, so it must not guess.
	return { ok => 0, candidates => \@c, ambiguous => 1 }
		if $second && ($top->{'score'} - $second) < 4;
	return &voice_funnel_scope_for($top->{'id'}, {
		score => $top->{'score'}, why => 'match',
	});
}

# The verbs a voice turn can actually run. Keep this list honest: a verb named
# here must have a branch in voice_brain, or the model can pick something that
# has nowhere to go.
sub voice_funnel_verbs($t) {
	# Keep this list honest: a verb named here must have a branch in voice_brain.
	# The common core is seven; each app family adds only what it can act on.
	my %v = map { $_ => 1 } qw/say ask done find open_app alias unalias/;
	my $app = lc(($t->{'app'} // '') . ' ' . ($t->{'id'} // ''));
	$v{'measure'} = 1 if $app =~ /measure|budget|health|weight/;
	$v{'where_when'} = 1 if $app =~ /travel|place|weather|navigation/;
	$v{'create'} = 1 if $app =~ /appointment|clock|calendar|reminder|task/;
	$v{'stop'} = 1 if $app =~ /appointment|clock|calendar|reminder|task/;
	$v{'play_music'} = 1 if $app =~ /music|video|gallery|studio/;
	# An app with declared actions gets the bridge verb. The scoped prompt names
	# those actions, and the executor refuses a "do" that is not among them.
	$v{'app'} = 1 if eval { @{ &help::app_actions($t->{'app'} // '') } } ? 1 : 0;
	return \%v;
}

sub voice_funnel_prompt_block($scope) {
	my $identity = &voice_funnel_identity_prompt();
	return $identity unless $scope && $scope->{'ok'};
	my @lines;
	push @lines, 'MATCHED HELP TOPIC: ' . ($scope->{'title'} // '') . ' (app: ' . ($scope->{'app'} // '') . ').';
	push @lines, $scope->{'briefing'} if length($scope->{'briefing'} // '');
	# The app-action bridge: the closed list of routes this turn may call. It is
	# appended here rather than to every Guide turn, so a prompt only ever carries
	# the actions of the app the person actually asked about.
	my $acts = eval { &help::app_action_lines($scope->{'app'} // '') } || '';
	push @lines, $acts if length $acts;
	push @lines, 'Use this help as the source of truth for this app. If the request belongs to a different app, say so instead of guessing.';
	return join("\n", @lines) . "\n" . $identity;
}

sub voice_funnel_identity {
	my $explicit = eval { &subs::setting_grabber({ app => '__president', setting => 'voice_self', device => 'all' }) } || '';
	my $wanted = &subs::unformat_name($explicit);
	my $people_rs = eval { &subs::db_select('people', undef, { status => 'active' }) };
	my @rows = $people_rs ? @{ $people_rs->hashes } : ();
	my @ordered = sort {
		(($a->{'app'} // '') eq 'jon_ferwerda' ? 0 : 1)
			<=> (($b->{'app'} // '') eq 'jon_ferwerda' ? 0 : 1)
			|| (($a->{'app'} // '') cmp ($b->{'app'} // ''))
	} @rows;
	my $row;
	if (length $wanted) {
		($row) = grep { ($_->{'app'} // '') eq $wanted } @ordered;
	}
	unless ($row) {
		($row) = grep { ($_->{'app'} // '') =~ /^(?:jon|jonathan)_ferwerda$/i } @ordered;
	}
	unless ($row) {
		($row) = grep { lc($_->{'name'} // '') =~ /^(?:jon|jonathan)\s+ferwerda$/ } @ordered;
	}
	return {} unless $row;
	my $app = $row->{'app'} // '';
	my $name = $row->{'name'} // &subs::format_name($app);
	my @aliases = ('me', 'my', 'i');
	my $first = lc(($name =~ /^(\S+)/)[0] // '');
	$first =~ s/[^\p{L}\p{N}]+//g;
	push @aliases, $first if length($first) >= 3;
	push @aliases, 'jon' if $app =~ /^jon(?:[_]|$)/i;
	push @aliases, lc(join ' ', split /_/, $app);
	push @aliases, lc($name);
	return { app => $app, name => $name, aliases => [ @aliases ] };
}

sub voice_funnel_identity_prompt {
	my $id = &voice_funnel_identity();
	return '' unless $id->{'app'};
	return 'THE PERSON: ' . $id->{'name'} . ' (' . $id->{'app'} . '). "me", "my", "I", "'
		. join('", "', grep { length } @{ $id->{'aliases'} || [] })
		. '" mean them. Their own records are filed under ' . $id->{'app'} . ".\n";
}

sub voice_funnel_self_app {
	my $id = &voice_funnel_identity();
	return $id->{'app'} || '';
}

# ---- router agent ----------------------------------------------------------

sub voice_funnel_router($text, $primary, $fallback = '') {
	return { ok => 0 } unless defined $text && length $text;
	return { ok => 0 } unless &_voice_funnel_help();
	return { ok => 0 } unless defined $primary && length $primary;
	my @rows = grep { ($_->{'app'} || '') ne '' || ($_->{'title'} || '') ne '' } @{ &voice_funnel_catalog() };
	return { ok => 0 } unless @rows;
	my %seen;
	my @lines;
	foreach my $e (@rows) {
		next if $seen{ $e->{'id'} }++;
		my $summary = &_voice_funnel_clip($e->{'summary'}, 140);
		push @lines, $e->{'id'} . ' | ' . $e->{'title'} . ' | ' . $summary;
		last if @lines >= 90;
	}
	my $system = "You are the JawnOS voice router. Pick the single help topic that best matches the spoken request. "
		. "Choose only from the list. If nothing matches, use an empty id. Reply with exactly one JSON object and nothing else: "
		. "{\"id\":\"topic-id\",\"confidence\":0.0}.\n\nTOPICS:\n" . join("\n", @lines);
	my $user = 'SPOKEN: ' . $text . "\n\nReply with the JSON object.";
	my $thinking = &subs::ai_role_thinking_effective('help_assistant');
	my ($out) = $fallback && $fallback ne $primary
		? &subs::evaluation_model_call_with_fallback($primary, $fallback, $system, $user, $thinking, 'help_assistant')
		: &subs::evaluation_model_call_role('help_assistant', $system, $user, $thinking);
	my $r = eval { &subs::json_from_model($out) } || {};
	my $id = $r->{'id'} // '';
	$id = &help::key($id) if length $id;
	return { ok => 0, router => $r } unless length $id && help::get($id);
	return &voice_funnel_scope_for($id, {
		why => 'router', confidence => ($r->{'confidence'} // ''),
	});
}

# ---- switch ---------------------------------------------------------------

# The funnel is on unless the house turns it off. One synced setting is enough:
# a machine can go back to the old unscoped prompt without a code change.
sub voice_funnel_enabled {
	my $v = eval { &subs::setting_grabber({ app => '__president', setting => 'voice_funnel', device => 'all' }) };
	return 0 if defined $v && $v =~ /^(?:off|0|no|false)$/i;
	return 1;
}

# ---- fast resolvers --------------------------------------------------------

sub voice_funnel_fast($text, $meta = {}) {
	my $low = lc(defined $text ? $text : '');
	# "weather station" is an app, not the forecast; leave that to the app grammar.
	return undef if $low =~ /\bstation\b/;
	return undef unless $low =~ /\bweather\b|\bforecast\b|\brain\b|\bsnow\b/;
	return undef unless $low =~ /what|how|will|is|forecast|tomorrow|today|rain|snow|temperature|outside|high|low|wind/;
	my $when = $low =~ /tomorrow/ ? 'tomorrow' : 'now';
	my $what = $low =~ /\brain\b|\bsnow\b|shower|precip/ ? 'precip'
		: $low =~ /\bhigh\b|\blow\b/ ? 'highlow'
		: $low =~ /\bwind\b/ ? 'wind'
		: 'now';
	return &voice_funnel_weather_answer($when, $what, $low);
}

sub _voice_funnel_weather_location($text) {
	my $where = '';
	$where = $1 if $text =~ /(?:in|at|near)\s+([a-z][a-z\s'\-]{2,40})\s*$/;
	$where =~ s/^\s+|\s+$//g;
	if (length $where) {
		my $locs = eval { &subs::weather_locations() } || [];
		my @locs = ref $locs eq 'ARRAY' ? @$locs : ();
		my ($loc) = grep {
			my $name = lc($_->{'name'} // '');
			length($name) && (index($name, $where) >= 0 || index($where, $name) >= 0);
		} @locs;
		if ($loc && defined $loc->{'lat'} && defined $loc->{'lon'}) {
			return ($loc->{'lat'}, $loc->{'lon'}, ($loc->{'name'} // $where));
		}
	}
	my $fix = eval { &subs::weather_device_fix(&subs::signatorial_designer()) };
	return ($fix->{'lat'}, $fix->{'lon'}, 'here') if $fix;
	my $home = eval { &subs::weather_home_place() };
	return ($home->{'lat'}, $home->{'lon'}, ($home->{'name'} // 'home')) if $home;
	return;
}

sub voice_funnel_weather_answer($when, $what, $text = '') {
	my ($lat, $lon, $label) = &_voice_funnel_weather_location($text);
	unless (defined $lat && defined $lon) {
		return { handled => 1, kind => 'weather', speech => 'I do not have a recent location for the weather.' };
	}
	my $w = eval { &subs::weather_fetch($lat, $lon, {}) };
	unless ($w && ref $w eq 'HASH' && !$w->{'error'}) {
		return { handled => 1, kind => 'weather', speech => 'Weather is unavailable right now.' };
	}
	my $cur = $w->{'current'} || {};
	my $place = length($label) ? ' in ' . $label : '';
	my $temp = $cur->{'temperature'};
	my $cond = $cur->{'condition'} || '';
	if (($when // '') eq 'tomorrow') {
		my $key = &subs::weather_day_key(&subs::rightNow() + 86400000);
		my ($day) = grep { ($_->{'date'} // '') eq $key } @{ $w->{'daily'} || [] };
		unless ($day) {
			return { handled => 1, kind => 'weather', speech => 'I do not have a forecast for tomorrow yet.' };
		}
		my @bits;
		push @bits, 'Tomorrow' . $place . ':';
		push @bits, lc($day->{'condition'}) if length($day->{'condition'} // '');
		push @bits, 'high ' . $day->{'high'} if defined $day->{'high'} && $day->{'high'} ne '';
		push @bits, 'low ' . $day->{'low'} if defined $day->{'low'} && $day->{'low'} ne '';
		push @bits, ($day->{'precip_prob'} // 0) . '% chance of precipitation' if defined $day->{'precip_prob'};
		return { handled => 1, kind => 'weather', speech => join(', ', @bits) . '.' };
	}
	if (($what // '') eq 'precip') {
		my $now = &subs::rightNow();
		my @next = grep { ($_->{'time'} || 0) >= $now && ($_->{'time'} || 0) <= $now + 12 * 3600000 } @{ $w->{'hourly'} || [] };
		my $max = 0;
		foreach my $h (@next) { $max = $h->{'precip_prob'} if defined $h->{'precip_prob'} && $h->{'precip_prob'} > $max; }
		return { handled => 1, kind => 'weather', speech => 'There is about a ' . int($max) . '% chance of precipitation in the next 12 hours' . $place . '.' };
	}
	if (($what // '') eq 'highlow') {
		my ($day) = @{ $w->{'daily'} || [] };
		return { handled => 1, kind => 'weather', speech => 'I do not have today’s high and low.' } unless $day;
		return { handled => 1, kind => 'weather', speech => 'Today' . $place . ': high ' . ($day->{'high'} // '?') . ', low ' . ($day->{'low'} // '?') . (length($day->{'condition'} // '') ? ', ' . lc($day->{'condition'}) : '') . '.' };
	}
	if (($what // '') eq 'wind') {
		return { handled => 1, kind => 'weather', speech => 'The wind is ' . ($cur->{'wind_speed'} // '?') . ' kilometres an hour' . (length($cur->{'wind_direction'} // '') ? ' from the ' . $cur->{'wind_direction'} : '') . $place . '.' };
	}
	unless (defined $temp && $temp ne '') {
		return { handled => 1, kind => 'weather', speech => 'I have no current temperature' . $place . '.' };
	}
	my $speech = 'It is ' . $temp . ' degrees' . (length $cond ? ' and ' . lc($cond) : '') . $place;
	$speech .= ', feels like ' . $cur->{'feels_like'} if defined $cur->{'feels_like'} && $cur->{'feels_like'} ne '';
	return { handled => 1, kind => 'weather', speech => $speech . '.' };
}

1;
