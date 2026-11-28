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
use Time::Piece;

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
	my %v = map { $_ => 1 } qw/say ask done find open_app close_app alias unalias/;
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

# ---- history / visit resolver ---------------------------------------------

# The words that frame a question about the person's own records. They are
# stripped before the rest of the sentence is looked up, so "when did I last
# see Brian Coulbeck" names the person, not the tense.
my %voice_funnel_history_strip = map { $_ => 1 } qw(
	hey jawn please tell me when whens what whats which how long many
	time times did was were is are am be been being do does done have has had
	i we you me my our us your last first next previous latest
	see saw seen visit visited visiting visits stay stayed staying
	go went going at to with from the a an that this
	it there about of in on for
);

# A question with no named thing ("when is the next appointment") is left to the
# model: it is a real question, but it is not answerable from one app's rows.
my %voice_funnel_history_generic = map { $_ => 1 } qw(
	appointment appointments event events meeting meetings
	record records entry entries thing things stuff something
);

# "When did I last message Brian" names a person, but it is a mail question, not
# an appointment-history one. Leave it to the Guide rather than answer from the
# wrong table.
my %voice_funnel_history_not = map { $_ => 1 } qw(
	message messaged messaging call called calling email emailed emailing
	text texted texting mail mailed mailing send sent sending
);

sub _voice_funnel_when($ts) {
	my $when = localtime($ts / 1000)->strftime('%A %B %d, %Y at %I:%M%p');
	$when =~ s/\b0(\d:)/$1:/;
	$when =~ s/(\d)([AP]M)\b/$1 $2/;
	return $when;
}

sub _voice_funnel_duration($ms) {
	my $seconds = int(abs($ms) / 1000);
	my $minutes = int($seconds / 60);
	my $rest = $seconds % 60;
	my @part;
	push @part, $minutes . ($minutes == 1 ? ' minute' : ' minutes') if $minutes;
	push @part, $rest . ($rest == 1 ? ' second' : ' seconds') if $rest || !$minutes;
	return join ' ', @part;
}

# Answer a "when did I last see <name>", "how long was my last visit to
# <place>", "how many times have I been to <place>" question from the same
# appointments the Guide's find reads - without a model. It is deliberately
# conservative: an entity that does not resolve to one app returns undef, so an
# unsure question still reaches the Guide.
sub voice_funnel_history_answer($text, $meta = {}) {
	$meta ||= {};
	my $low = lc(defined $text ? $text : '');
	# A history question carries a tense or a visit/see verb, and a question word.
	# "how many times did I message Brian" is a mail question, not a history one.
	return undef if grep { $voice_funnel_history_not{$_} } split /\s+/, $low;
	my $has_tense = $low =~ /\b(?:last|first|next|previous|latest)\b/ ? 1 : 0;
	my $has_verb = $low =~ /\b(?:see|saw|seen|visit(?:ed|ing|s)?|stay(?:ed|ing|s)?|been|go|went|going|at)\b/ ? 1 : 0;
	return undef unless $has_tense || $has_verb;
	return undef unless $low =~ /\bwhen(?:'s|s)?\b|\bwhat\s+time\b|how\s+(?:long|many)/;
	# Weather has its own fast resolver; never steal its turn.
	return undef if $low =~ /\bweather\b|\bforecast\b|\brain\b|\bsnow\b|\btemperature\b|\bwind\b/;
	my $which = $low =~ /how\s+long|\blasted\b|\bstay(?:ed|ing|s)?\b/ ? 'duration'
		: $low =~ /how\s+many/ ? 'count'
		: $low =~ /\bfirst\b/ ? 'first'
		: $low =~ /\bnext\b/ ? 'next'
		: 'last';
	# A visit asks where the person was; a person question asks when they were
	# seen. The verbs decide which record type carries the moment.
	my $is_visit = $low =~ /\bvisit(?:ed|ing|s)?\b|\bstay(?:ed|ing|s)?\b|\bbeen\s+to\b|\b(?:go|went|going)\b|\bat\b/ ? 1 : 0;
	$is_visit = 1 if $which eq 'duration';
	# The entity: drop the question frame and the verbs, then require something.
	my $flat = $low;
	$flat =~ s/['\x{2019}]//g;
	$flat =~ s/[^\p{L}\p{N}]+/ /g;
	my @token = grep {
		length($_) > 1
			&& !$voice_funnel_history_strip{$_}
			&& !$voice_funnel_history_generic{$_}
	} split /\s+/, $flat;
	my $entity = join ' ', @token;
	$entity =~ s/^\s+|\s+$//g;
	return undef unless length $entity;
	my $device = $meta->{'chip_id'};
	my $found = eval { &Manager::help_search($entity, $device) };
	return undef unless ref $found eq 'HASH' && ref $found->{'apps'} eq 'ARRAY' && @{ $found->{'apps'} };
	my @apps = @{ $found->{'apps'} };
	# Two apps with the same count is a question the resolver cannot answer
	# without guessing; let the model ask.
	return undef if @apps > 1 && ($apps[0]->{'count'} // 0) == ($apps[1]->{'count'} // 0);
	my $app = $apps[0]->{'app'};
	return undef unless defined $app && length $app;
	my $visible = eval { &Manager::help_app_visible($app, $device) };
	return undef unless $visible;
	my $raw = eval { &subs::db_raw(
		'select uuid, app, type, timestamp, duration, notes from appointments where app = ? order by cast(timestamp as integer) asc',
		$app) };
	return undef unless ref $raw eq 'ARRAY';
	my $private_open = eval { (&subs::private_reachable_now() && &subs::private_revealed($device)) ? 1 : 0 } || 0;
	my @rows = grep {
		defined $_->{'timestamp'} && $_->{'timestamp'} =~ /^\d+$/
			&& !( (eval { &subs::appointment_private_now($_) } || 0) && !$private_open )
	} @{ $raw };
	return undef unless @rows;
	$_->{'ts'} = 0 + $_->{'timestamp'} for @rows;
	@rows = sort { $a->{'ts'} <=> $b->{'ts'} } @rows;
	my $now = &subs::rightNow();
	my $label = eval { &subs::format_name($app) };
	$label = $entity unless defined $label && length $label;
	# A visit prefers the stop rows (the completed visits); a person question
	# reads both moments. If the preferred kind never appears, all rows answer.
	my %prefer = map { $_ => 1 } ($is_visit ? ('stop') : ('start', 'stop'));
	my @set = grep { $prefer{ lc($_->{'type'} // '') } } @rows;
	@set = @rows unless @set;
	my $result = sub {
		my ($speech) = @_;
		return {
			handled => 1, kind => 'history', speech => $speech,
			app => $app, which => $which,
		};
	};
	if ($which eq 'count') {
		# A visit is counted by its stop rows; an app with only pictures or
		# starts cannot say how many times the person was there.
		my @counted = $is_visit
			? grep { lc($_->{'type'} // '') eq 'stop' } @rows
			: @set;
		my $n = scalar @counted;
		return undef unless $n;
		return $result->('You have ' . ($is_visit ? 'been to ' . $label : 'seen ' . $label)
			. ' ' . $n . ($n == 1 ? ' time.' : ' times.'));
	}
	if ($which eq 'next') {
		# A future start at a place is a next visit just as a future stop is.
		my @nextset = grep { lc($_->{'type'} // '') =~ /^(?:start|stop)$/ } @rows;
		@nextset = @set unless @nextset;
		my ($next) = grep { $_->{'ts'} > $now } @nextset;
		return undef unless $next;
		my $when = &_voice_funnel_when($next->{'ts'});
		return $result->($is_visit
			? 'Your next visit to ' . $label . ' is on ' . $when . '.'
			: 'You next see ' . $label . ' on ' . $when . '.');
	}
	if ($which eq 'first') {
		my $first = $set[0];
		return undef unless $first;
		my $when = &_voice_funnel_when($first->{'ts'});
		return $result->($is_visit
			? 'You first visited ' . $label . ' on ' . $when . '.'
			: 'You first saw ' . $label . ' on ' . $when . '.');
	}
	# "duration" reads every row: an open start is the latest visit, and its
	# length must not be invented.
	if ($which eq 'duration') {
		my @past = grep {
			my $row = $_;
			$row->{'ts'} <= $now
				&& (($row->{'type'} // '') eq 'start' || ($row->{'type'} // '') eq 'stop')
		} @rows;
		my $last = $past[-1];
		return undef unless $last;
		my $type = lc($last->{'type'} // '');
		my $when = &_voice_funnel_when($last->{'ts'});
		if ($type eq 'start') {
			return $result->('Your last visit to ' . $label . ' is still open, since ' . $when . '.');
		}
		my $duration = $last->{'duration'};
		return undef unless defined $duration && $duration =~ /^-?\d+$/ && $duration != 0;
		return $result->('Your last visit to ' . $label . ' lasted '
			. &_voice_funnel_duration($duration) . ', on ' . $when . '.');
	}
	# An open start is where the person is now; an older stop is not their last
	# visit. Check the presence rows before the preferred set reports a past stop.
	my @presence = grep { $_->{'ts'} <= $now && lc($_->{'type'} // '') =~ /^(?:start|stop)$/ } @rows;
	my $latest = $presence[-1];
	# A start alone can be a meeting logged only at its start, or a forgotten
	# session. Only a start from the last twelve hours is "now"; an older one is
	# read as the last time, which is the safer answer.
	if ($latest && lc($latest->{'type'} // '') eq 'start'
		&& ($now - $latest->{'ts'}) <= 12 * 60 * 60 * 1000) {
		my $since = &_voice_funnel_when($latest->{'ts'});
		return $result->($is_visit
			? 'You are at ' . $label . ' now, since ' . $since . '.'
			: 'You are with ' . $label . ' now, since ' . $since . '.');
	}
	my @past = grep { $_->{'ts'} <= $now } @set;
	my $last = $past[-1];
	return undef unless $last;
	my $when = &_voice_funnel_when($last->{'ts'});
	if ($is_visit) {
		my $duration = '';
		if (lc($last->{'type'} // '') eq 'stop'
			&& defined $last->{'duration'} && $last->{'duration'} =~ /^-?\d+$/
			&& $last->{'duration'} != 0) {
			$duration = &_voice_funnel_duration($last->{'duration'});
		}
		return $result->('You were last at ' . $label . ' on ' . $when
			. ($duration ? ', for ' . $duration : '') . '.');
	}
	return $result->('You last saw ' . $label . ' on ' . $when . '.');
}

sub voice_funnel_fast($text, $meta = {}) {
	my $low = lc(defined $text ? $text : '');
	# "weather station" is an app, not the forecast; leave that to the app grammar.
	return undef if $low =~ /\bstation\b/;
	# A weather question is answered from the forecast or the archive before the
	# history resolver can mistake the words for a visit. The time words are the
	# same set the target reader understands.
	if ($low =~ /\bweather\b|\bforecast\b|\brain\b|\bsnow\b|\btemperature\b/
		&& $low =~ /\b(?:what|how|will|was|were|did|is|forecast|tomorrow|today|yesterday|rain|snow|temperature|outside|high|low|wind|warmer|colder|compare)\b/) {
		my $what = $low =~ /\brain\b|\bsnow\b|shower|precip/ ? 'precip'
			: $low =~ /\bhigh\b|\blow\b/ ? 'highlow'
			: $low =~ /\bwind\b/ ? 'wind'
			: 'now';
		return &voice_funnel_weather_answer('', $what, $low);
	}
	# History/visit questions read the person's own appointments. The resolver
	# returns undef when the entity or the question does not resolve, so the
	# router and the model keep their turns.
	my $history = &voice_funnel_history_answer($text, $meta);
	return $history if $history;
	return undef;
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

my @VF_WEEKDAY_NAME = qw(sunday monday tuesday wednesday thursday friday saturday);
my %VF_WEEKDAY = map { $VF_WEEKDAY_NAME[$_] => $_ } 0 .. 6;
my %VF_MONTH = (
	january => 1, jan => 1, february => 2, feb => 2, march => 3, mar => 3,
	april => 4, apr => 4, may => 5, june => 6, jun => 6, july => 7, jul => 7,
	august => 8, aug => 8, september => 9, sep => 9, sept => 9,
	october => 10, oct => 10, november => 11, nov => 11, december => 12, dec => 12,
);
my @VF_MONTH_NAME = qw(_ January February March April May June July August September October November December);
my %VF_SEASON = (
	spring => [3, 1, 5, 31], summer => [6, 1, 8, 31],
	fall => [9, 1, 11, 30], autumn => [9, 1, 11, 30], winter => [12, 1, 2, 28],
);

sub _vf_leap($y) {
	return (($y % 4 == 0 && $y % 100 != 0) || $y % 400 == 0) ? 1 : 0;
}

sub _vf_day($date, $delta) {
	my $t = eval { Time::Piece->strptime($date, '%Y-%m-%d') } or return $date;
	return Time::Piece->localtime($t->epoch + $delta * 86400)->strftime('%Y-%m-%d');
}

sub _vf_month_end($year, $month) {
	my $next = $month == 12 ? sprintf('%04d-01-01', $year + 1) : sprintf('%04d-%02d-01', $year, $month + 1);
	my $t = eval { Time::Piece->strptime($next, '%Y-%m-%d') } or return '';
	return &_vf_day($t->strftime('%Y-%m-%d'), -1);
}

sub _vf_month_shift($date, $n) {
	my $t = eval { Time::Piece->strptime($date, '%Y-%m-%d') } or return ($date, $date);
	my ($y, $m) = ($t->year, $t->mon + $n);
	while ($m <= 0) { $m += 12; $y--; }
	while ($m > 12) { $m -= 12; $y++; }
	return (sprintf('%04d-%02d-01', $y, $m), &_vf_month_end($y, $m));
}

sub _vf_shift_years($date, $n) {
	my ($y, $m, $d) = $date =~ /^(\d{4})-(\d{2})-(\d{2})$/ or return '';
	my $t = eval { Time::Piece->strptime(sprintf('%04d-%02d-%02d', $y + $n, $m, $d), '%Y-%m-%d') };
	unless ($t) {
		# 29 February has no counterpart in a common year
		$t = eval { Time::Piece->strptime(sprintf('%04d-%02d-28', $y + $n, $m), '%Y-%m-%d') };
	}
	return $t ? $t->strftime('%Y-%m-%d') : '';
}

sub _vf_date_label($date) {
	my $t = eval { Time::Piece->strptime($date, '%Y-%m-%d') } or return $date;
	return $t->strftime('%B') . ' ' . $t->mday . ', ' . $t->year;
}

sub _vf_day_name($date) {
	my $t = eval { Time::Piece->strptime($date, '%Y-%m-%d') } or return '';
	return $t->strftime('%A');
}

sub _vf_week_start($date) {
	my $t = eval { Time::Piece->strptime($date, '%Y-%m-%d') } or return $date;
	my $back = $t->wday == 0 ? 6 : $t->wday - 1;   # Monday starts the week
	return &_vf_day($date, -$back);
}

sub _vf_last_week($today) {
	my $from = &_vf_day(&_vf_week_start($today), -7);
	return ($from, &_vf_day($from, 6));
}

sub _vf_this_week($today) {
	my $from = &_vf_week_start($today);
	return ($from, &_vf_day($from, 6));
}

sub _vf_next_week($today) {
	my $from = &_vf_day(&_vf_week_start($today), 7);
	return ($from, &_vf_day($from, 6));
}

sub _vf_last_season($today, $season) {
	my $t = eval { Time::Piece->strptime($today, '%Y-%m-%d') } or return ($today, $today);
	my ($sm, $sd, $em, $ed) = @{ $VF_SEASON{$season} || [3, 1, 5, 31] };
	my $y = $t->year;
	if ($season eq 'winter') {
		my $end_year = $y;
		my $end = sprintf('%04d-02-%02d', $end_year, &_vf_leap($end_year) ? 29 : 28);
		if ($end gt $today) {
			$end_year--;
			$end = sprintf('%04d-02-%02d', $end_year, &_vf_leap($end_year) ? 29 : 28);
		}
		return (sprintf('%04d-12-01', $end_year - 1), $end);
	}
	my $end = sprintf('%04d-%02d-%02d', $y, $em, $ed);
	if ($end gt $today) {
		$y--;
		$end = sprintf('%04d-%02d-%02d', $y, $em, $ed);
	}
	return (sprintf('%04d-%02d-%02d', $y, $sm, $sd), $end);
}

sub _vf_calendar_day($today, $year, $mon, $mday, $last_year = 0) {
	my $t = eval { Time::Piece->strptime($today, '%Y-%m-%d') } or return $today;
	my $explicit = (defined $year && $year =~ /^\d{4}$/) ? 1 : 0;
	my $y = $explicit ? $year : $t->year;
	$y = $t->year - 1 if !$explicit && $last_year;
	my $candidate = sprintf('%04d-%02d-%02d', $y, $mon, $mday);
	my $valid = eval { Time::Piece->strptime($candidate, '%Y-%m-%d') };
	return '' unless $valid;
	# No year named: the coming occurrence while it is in the forecast, else the
	# most recent one. "March 5" in November is this year; "December 20" is last
	# year, because that is the last time it happened.
	if (!$explicit && !$last_year) {
		my $ahead = &subs::weather_days_between($today, $candidate);
		if (defined $ahead && $ahead > 14) {
			$candidate = sprintf('%04d-%02d-%02d', $y - 1, $mon, $mday);
		}
	}
	return $candidate;
}

sub _vf_round($v) {
	return undef unless defined $v && "$v" =~ /^-?\d+(?:\.\d+)?$/;
	my $n = 0 + $v;
	return int($n * 10 + ($n < 0 ? -0.5 : 0.5)) / 10;
}

sub _vf_avg {
	my @v = grep { defined } @_;
	return undef unless @v;
	my $sum = 0;
	$sum += $_ for @v;
	return $sum / @v;
}

# The day or stretch a weather question names. Returns
#   { from, to, label, compare }
# or undef when the words name no time at all. "compare" is last_year,
# last_month or last_week, and the same period is read again for the answer.
sub _voice_funnel_weather_target($when, $text) {
	my $now = &subs::rightNow();
	my $today = &subs::weather_day_key($now);
	my $s = lc(join(' ', (defined $when ? $when : ''), (defined $text ? $text : '')));
	$s =~ s/\x{2019}/'/g;
	$s =~ s/[^a-z0-9\s\/:.-]+/ /g;
	$s =~ s/\bplease\b//g;
	$s =~ s/\s+/ /g;
	$s =~ s/^\s+|\s+$//g;
	return undef unless length $s;

	my $compare = '';
	if ($s =~ /\b(?:compare|compared|versus|vs|difference|warmer|colder|hotter|cooler|wetter|drier)\b/) {
		$compare = 'last_year' if $s =~ /\blast year\b|\byear ago\b/;
		$compare = 'last_month' if $s =~ /\blast month\b/;
		$compare = 'last_week' if $s =~ /\blast week\b/;
		if (length $compare) {
			# the comparison phrase is not the time being asked about
			$s =~ s/\b(?:than|versus|vs|compared to|compare with|to)\s+last (?:year|month|week)\b//g;
			$s =~ s/\b(?:warmer|colder|hotter|cooler|wetter|drier)\s+last (?:year|month|week)\b//g;
			$s =~ s/\blast (?:year|month|week)\b//g if $s =~ /\b(?:warmer|colder|hotter|cooler|wetter|drier)\b/;
		}
	}
	my $last_year = (!$compare && $s =~ /\blast year\b/) ? 1 : 0;

	my ($from, $to, $label);
	if ($s =~ /\b(\d{4})-(\d{2})-(\d{2})\b/) {
		my ($y, $m, $d) = ($1, $2, $3);
		$from = $to = sprintf('%04d-%02d-%02d', $y, $m, $d);
		$label = 'on ' . &_vf_date_label($from);
	}
	elsif ($s =~ /\b(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|sept|october|oct|november|nov|december|dec)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b/) {
		my ($mon, $mday, $year) = ($VF_MONTH{$1}, $2, $3);
		$from = $to = &_vf_calendar_day($today, $year, $mon, $mday, $last_year);
		$label = 'on ' . &_vf_date_label($from);
	}
	elsif ($s =~ /\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|sept|october|oct|november|nov|december|dec)\.?(?:,?\s+(\d{4}))?\b/) {
		my ($mday, $mon, $year) = ($1, $VF_MONTH{$2}, $3);
		$from = $to = &_vf_calendar_day($today, $year, $mon, $mday, $last_year);
		$label = 'on ' . &_vf_date_label($from);
	}
	elsif ($s =~ /\b(\d{1,3}|a|one)\s+(day|days|week|weeks|month|months|year|years)\s+ago\b/) {
		my $n = ($1 eq 'a' || $1 eq 'one') ? 1 : 0 + $1;
		my $unit = $2;
		if ($unit =~ /^day/) {
			$from = $to = &_vf_day($today, -$n);
			$label = 'on ' . &_vf_date_label($from);
		}
		elsif ($unit =~ /^week/) {
			$from = &_vf_day($today, -7 * $n);
			$to = &_vf_day($from, 6);
			$label = 'the week of ' . &_vf_date_label($from);
		}
		elsif ($unit =~ /^month/) {
			my ($fy) = &_vf_month_shift($today, -$n);
			my ($y, $m) = split /-/, $fy;
			$from = sprintf('%04d-%02d-01', $y, $m);
			$to = &_vf_month_end($y, $m);
			$label = 'in ' . $VF_MONTH_NAME[$m] . ' ' . $y;
		}
		else {
			$from = $to = &_vf_shift_years($today, -$n);
			$label = 'on ' . &_vf_date_label($from);
		}
	}
	elsif ($s =~ /\b(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|sept|october|oct|november|nov|december|dec)\.?\s+(\d{4})\b/) {
		my ($mon, $y) = ($VF_MONTH{$1}, $2);
		$from = sprintf('%04d-%02d-01', $y, $mon);
		$to = &_vf_month_end($y, $mon);
		$label = 'in ' . $VF_MONTH_NAME[$mon] . ' ' . $y;
	}
	elsif ($s =~ /\b(?:in|during|for)\s+(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|sept|october|oct|november|nov|december|dec)\b/) {
		my $mon = $VF_MONTH{$1};
		my $t = eval { Time::Piece->strptime($today, '%Y-%m-%d') };
		my $y = $t ? $t->year : (localtime)[5] + 1900;
		$y-- if &_vf_month_end($y, $mon) gt $today;
		$from = sprintf('%04d-%02d-01', $y, $mon);
		$to = &_vf_month_end($y, $mon);
		$label = 'in ' . $VF_MONTH_NAME[$mon] . ' ' . $y;
	}
	elsif ($s =~ /\bday after tomorrow\b/) {
		$from = $to = &_vf_day($today, 2);
		$label = 'the day after tomorrow';
	}
	elsif ($s =~ /\btomorrow\b/) {
		$from = $to = &_vf_day($today, 1);
		$label = 'tomorrow';
	}
	elsif ($s =~ /\byesterday\b/) {
		$from = $to = &_vf_day($today, -1);
		$label = 'yesterday';
	}
	elsif ($s =~ /\btoday\b|\btonight\b|\bnow\b|\bcurrently\b/) {
		$from = $to = $today;
		$label = 'today';
	}
	elsif ($s =~ /\blast\s+(week|month|year|spring|summer|fall|autumn|winter)\b/) {
		my $p = $1;
		if ($p eq 'week') {
			($from, $to) = &_vf_last_week($today);
			$label = 'last week (' . &_vf_date_label($from) . ' to ' . &_vf_date_label($to) . ')';
		}
		elsif ($p eq 'month') {
			($from, $to) = &_vf_month_shift($today, -1);
			my ($y, $m) = split /-/, $from;
			$label = 'last month (' . $VF_MONTH_NAME[$m] . ' ' . $y . ')';
		}
		elsif ($p eq 'year') {
			$from = $to = &_vf_shift_years($today, -1);
			$label = 'a year ago today';
		}
		else {
			($from, $to) = &_vf_last_season($today, $p);
			$label = 'last ' . $p . ' (' . &_vf_date_label($from) . ' to ' . &_vf_date_label($to) . ')';
		}
	}
	elsif ($s =~ /\bthis\s+(week|month)\b/) {
		my $p = $1;
		if ($p eq 'week') {
			($from, $to) = &_vf_this_week($today);
			$label = 'this week (' . &_vf_date_label($from) . ' to ' . &_vf_date_label($to) . ')';
		}
		else {
			($from, $to) = &_vf_month_shift($today, 0);
			my ($y, $m) = split /-/, $from;
			$label = 'this month (' . $VF_MONTH_NAME[$m] . ' ' . $y . ')';
		}
	}
	elsif ($s =~ /\bnext\s+(week|month)\b/) {
		my $p = $1;
		if ($p eq 'week') {
			($from, $to) = &_vf_next_week($today);
			$label = 'next week (' . &_vf_date_label($from) . ' to ' . &_vf_date_label($to) . ')';
		}
		else {
			($from, $to) = &_vf_month_shift($today, 1);
			my ($y, $m) = split /-/, $from;
			$label = 'next month (' . $VF_MONTH_NAME[$m] . ' ' . $y . ')';
		}
	}
	elsif ($s =~ /\b(last|next)\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b/) {
		my ($which, $name) = ($1, $2);
		my $target = $VF_WEEKDAY{$name};
		my $t = eval { Time::Piece->strptime($today, '%Y-%m-%d') };
		my $today_w = $t ? $t->wday : 0;
		my $ahead = ($target - $today_w + 7) % 7;
		if ($which eq 'last') {
			my $back = ($today_w - $target + 7) % 7;
			$back = 7 if $back == 0;
			$from = $to = &_vf_day($today, -$back);
		}
		else {
			$ahead = 7 if $ahead == 0;
			$ahead += 7 if $ahead > 0 && $ahead < 7;
			$from = $to = &_vf_day($today, $ahead);
		}
		$label = 'on ' . &_vf_day_name($from) . ', ' . &_vf_date_label($from);
	}
	elsif ($s =~ /\b(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b/) {
		my $target = $VF_WEEKDAY{$1};
		my $t = eval { Time::Piece->strptime($today, '%Y-%m-%d') };
		my $today_w = $t ? $t->wday : 0;
		my $ahead = ($target - $today_w + 7) % 7;
		$from = $to = &_vf_day($today, $ahead);
		$label = $ahead == 0 ? 'today' : ($ahead == 1 ? 'tomorrow' : 'on ' . &_vf_day_name($from) . ', ' . &_vf_date_label($from));
	}
	elsif ($s =~ /\bin\s+(\d{1,2})\s+(day|days|week|weeks)\b/) {
		my $n = 0 + $1;
		my $days = $2 =~ /^week/ ? $n * 7 : $n;
		$from = $to = &_vf_day($today, $days);
		$label = 'on ' . &_vf_date_label($from);
	}
	elsif ($s =~ /\b(\d{1,2})\s+days?\s+from\s+now\b/) {
		$from = $to = &_vf_day($today, 0 + $1);
		$label = 'on ' . &_vf_date_label($from);
	}
	if (!defined $from && length $compare) {
		$from = $to = $today;
		$label = 'today';
	}
	return undef unless defined $from && length $from;
	$label = 'on ' . &_vf_date_label($from) unless defined $label && length $label;
	return { from => $from, to => $to, label => $label, compare => $compare };
}

# The days of a range, from the forecast while it reaches and from Open-Meteo's
# archive for the past. Each row carries its own source so the answer can say
# which record it read.
sub _voice_funnel_weather_range_days($lat, $lon, $from, $to) {
	return [] unless defined $from && defined $to && length $from && length $to && $from le $to;
	my %rows;
	my $today = &subs::weather_day_key(&subs::rightNow());
	if ($to ge $today) {
		my $w = eval { &subs::weather_fetch($lat, $lon, {}) };
		if ($w && ref $w eq 'HASH' && !$w->{'error'}) {
			foreach my $d (@{ $w->{'daily'} || [] }) {
				my $date = $d->{'date'} // '';
				next unless $date ge $from && $date le $to;
				$rows{$date} = { %$d, source => 'forecast' };
			}
		}
	}
	my @missing;
	my $d = $from;
	my $guard = 0;
	while ($d le $to && $guard++ < 400) {
		push @missing, $d if $d lt $today && !$rows{$d};
		$d = &_vf_day($d, 1);
	}
	if (@missing) {
		my $archive = eval { &subs::weather_history_archive_days($lat, $lon, $missing[0], $missing[-1]) } || {};
		foreach my $row (@{ $archive->{'days'} || [] }) {
			my $date = $row->{'date'} // '';
			next unless length $date;
			$rows{$date} = { %$row, source => 'archive' };
		}
	}
	return [ map { $rows{$_} } sort keys %rows ];
}

sub _voice_funnel_weather_range_speech($target, $days, $what, $place) {
	my @d = @{ $days || [] };
	return '' unless @d;
	my $archive = 1;
	$archive = 0 if grep { ($_->{'source'} // '') ne 'archive' } @d;
	my $label = $target->{'label'} // ('on ' . &_vf_date_label($target->{'from'}));
	my $head = $label;
	if ($archive) {
		my $tail = $label;
		$tail =~ s/^(?:on|in|from)\s+//;
		$head = "Open-Meteo's record for " . $tail;
	}
	if (@d == 1) {
		my $d = $d[0];
		my @bits;
		if (($what // '') eq 'precip') {
			if (defined $d->{'precip_mm'}) { push @bits, &_vf_round($d->{'precip_mm'}) . ' mm of rain'; }
			elsif (defined $d->{'precip_prob'}) { push @bits, &_vf_round($d->{'precip_prob'}) . '% chance of precipitation'; }
			else { push @bits, 'no precipitation figure'; }
		}
		elsif (($what // '') eq 'highlow') {
			push @bits, 'high ' . &_vf_round($d->{'high'}) if defined $d->{'high'};
			push @bits, 'low ' . &_vf_round($d->{'low'}) if defined $d->{'low'};
		}
		else {
			push @bits, lc($d->{'condition'}) if length($d->{'condition'} // '');
			push @bits, 'high ' . &_vf_round($d->{'high'}) if defined $d->{'high'};
			push @bits, 'low ' . &_vf_round($d->{'low'}) if defined $d->{'low'};
			if (defined $d->{'precip_mm'} && $d->{'precip_mm'} > 0) { push @bits, &_vf_round($d->{'precip_mm'}) . ' mm of rain'; }
			elsif (defined $d->{'precip_prob'}) { push @bits, &_vf_round($d->{'precip_prob'}) . '% chance of precipitation'; }
			if (($what // '') eq 'wind' && defined $d->{'wind_speed'}) {
				push @bits, 'wind ' . &_vf_round($d->{'wind_speed'}) . ' kilometres an hour' . (length($d->{'wind_direction'} // '') ? ' from the ' . $d->{'wind_direction'} : '');
			}
		}
		@bits = ('no reading') unless @bits;
		return ucfirst($head) . $place . ': ' . join(', ', @bits) . '.';
	}
	my @highs = grep { defined } map { $_->{'high'} } @d;
	my @lows = grep { defined } map { $_->{'low'} } @d;
	my @precips = grep { defined } map { $_->{'precip_mm'} } @d;
	my %conditions;
	$conditions{$_->{'condition'}}++ for grep { length($_->{'condition'} // '') } @d;
	my @bits;
	if (($what // '') eq 'precip') {
		my $total = 0;
		$total += $_ for @precips;
		@bits = @precips ? ('about ' . &_vf_round($total) . ' mm of rain') : ('no rainfall figure');
	}
	elsif (($what // '') eq 'highlow') {
		my $mh = &_vf_avg(@highs);
		my $ml = &_vf_avg(@lows);
		push @bits, 'highs averaging ' . &_vf_round($mh) if defined $mh;
		push @bits, 'lows averaging ' . &_vf_round($ml) if defined $ml;
	}
	else {
		my $mh = &_vf_avg(@highs);
		my $ml = &_vf_avg(@lows);
		push @bits, 'highs averaging ' . &_vf_round($mh) if defined $mh;
		push @bits, 'lows averaging ' . &_vf_round($ml) if defined $ml;
		my ($top) = sort { $conditions{$b} <=> $conditions{$a} || $a cmp $b } keys %conditions;
		push @bits, 'mostly ' . lc($top) if defined $top && length $top;
		my $total = 0;
		$total += $_ for @precips;
		push @bits, &_vf_round($total) . ' mm of rain' if @precips && $total > 0;
	}
	@bits = ('no reading') unless @bits;
	return ucfirst($head) . $place . ': ' . join(', ', @bits) . '.';
}

sub _voice_funnel_weather_compare_range($target) {
	my $kind = $target->{'compare'} // '';
	return () unless length $kind;
	my ($from, $to) = ($target->{'from'}, $target->{'to'});
	return () unless defined $from && defined $to && length $from && length $to;
	if ($kind eq 'last_year') {
		return (&_vf_shift_years($from, -1), &_vf_shift_years($to, -1), 'the same time last year');
	}
	if ($kind eq 'last_month') {
		my ($f, $t) = &_vf_month_shift($from, -1);
		return ($f, $t, 'the month before');
	}
	if ($kind eq 'last_week') {
		return (&_vf_day($from, -7), &_vf_day($to, -7), 'the week before');
	}
	return ();
}

sub _voice_funnel_weather_compare_speech($days, $cdays, $clabel, $what) {
	my @t = @{ $days || [] };
	my @c = @{ $cdays || [] };
	return '' unless @t && @c;
	if (($what // '') eq 'precip') {
		my ($tt, $tn, $ct, $cn) = (0, 0, 0, 0);
		foreach my $d (@t) { if (defined $d->{'precip_mm'}) { $tt += $d->{'precip_mm'}; $tn++; } }
		foreach my $d (@c) { if (defined $d->{'precip_mm'}) { $ct += $d->{'precip_mm'}; $cn++; } }
		return '' unless $tn && $cn;
		my $word = $tt > $ct + 0.5 ? 'wetter' : ($tt < $ct - 0.5 ? 'drier' : 'about as wet');
		return ' That was ' . $word . ' than ' . $clabel . ' (' . &_vf_round($tt) . ' mm against ' . &_vf_round($ct) . ').';
	}
	my $th = &_vf_avg(map { $_->{'high'} } @t);
	my $ch = &_vf_avg(map { $_->{'high'} } @c);
	my $tl = &_vf_avg(map { $_->{'low'} } @t);
	my $cl = &_vf_avg(map { $_->{'low'} } @c);
	return '' unless defined $th && defined $ch;
	my $diff = $th - $ch;
	my $word = $diff > 0.5 ? 'warmer' : ($diff < -0.5 ? 'cooler' : 'about the same');
	my $amount = ($diff > 0.5 || $diff < -0.5) ? ' by ' . &_vf_round(abs($diff)) . ' degrees' : '';
	my $speech = ' That is ' . $word . $amount . ' than ' . $clabel . ' (a high of ' . &_vf_round($th) . ' against ' . &_vf_round($ch);
	$speech .= '; a low of ' . &_vf_round($tl) . ' against ' . &_vf_round($cl) if defined $tl && defined $cl;
	return $speech . ').';
}

sub voice_funnel_weather_answer($when, $what, $text = '') {
	my ($lat, $lon, $location_label) = &_voice_funnel_weather_location($text);
	unless (defined $lat && defined $lon) {
		return { handled => 1, kind => 'weather', speech => 'I do not have a recent location for the weather.' };
	}
	my $target = &_voice_funnel_weather_target($when, $text);
	if ($target && length($target->{'from'} // '')) {
		my $place = (length($location_label // '') && $location_label ne 'here') ? ' in ' . $location_label : '';
		my $days = &_voice_funnel_weather_range_days($lat, $lon, $target->{'from'}, $target->{'to'});
		unless (@{$days}) {
			my $missing = $target->{'label'} // 'that time';
			$missing =~ s/^(?:on|in|from)\s+//;
			return { handled => 1, kind => 'weather', speech => 'I have no weather record for ' . lc($missing) . $place . '.' };
		}
		my $speech = &_voice_funnel_weather_range_speech($target, $days, $what, $place);
		my ($cf, $ct, $clabel) = &_voice_funnel_weather_compare_range($target);
		if (length($cf // '')) {
			my $cdays = &_voice_funnel_weather_range_days($lat, $lon, $cf, $ct);
			if (@{$cdays}) {
				$speech .= &_voice_funnel_weather_compare_speech($days, $cdays, $clabel, $what);
			}
			else {
				$speech .= ' I have no record for ' . $clabel . ' to compare.';
			}
		}
		return { handled => 1, kind => 'weather', speech => $speech };
	}
	my $w = eval { &subs::weather_fetch($lat, $lon, {}) };
	unless ($w && ref $w eq 'HASH' && !$w->{'error'}) {
		return { handled => 1, kind => 'weather', speech => 'Weather is unavailable right now.' };
	}
	my $cur = $w->{'current'} || {};
	my $place = length($location_label) ? ' in ' . $location_label : '';
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
