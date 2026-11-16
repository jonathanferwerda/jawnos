package subs;

# Hang: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $device;
our $gb;
our %m;

sub hang_to_dry {
	my $server_time = &rightNow();
	my $returner = [];

	my $cls = &db_query('select * from settings where setting = ? and device = ? and app!= ? and value is not null', 'clothesline', $device,'__president')->hashes;
	# Every app's days and the order the day runs in. The appointment scan reads
	# only the steps the person starts and stops themselves, so a task or a
	# default option does not teach the line a routine of its own.
	my $daily = &clothesline_daily_hours();
	# The alphabetical tail is the apps whose own hang is on now. A time slot
	# was picked in the house's words, so the match reads the house clock: the
	# box keeps UTC, and a slot must not open eight o'clock late.
	my @slot = &clothesline_slot_now($server_time);
	# The person's own say over the anticipatory head, and the apps they took off
	# the line altogether, gathered as the rows are read.
	my (%say, %hidden, %renew);

	foreach my $clr ( @{$cls} ) {

		my $cl = eval { return decode_json $clr->{'value'} } || {};
		my $app = &unformat_name($clr->{'app'});
		$say{$app} = $cl->{'anticipatory'} if defined $cl->{'anticipatory'} && $cl->{'anticipatory'} =~ /\S/;
		if ($cl->{'hidden'}) {
			$hidden{$app} = 1;
			next;
		}
		# A phrase whose days have run out is read again from the plan it was made
		# from: the dates are the plan's own, so this costs no model call.
		$renew{$app} = $cl if &clothesline_schedule_renew($cl, $server_time);
		my $settings = &settings_grabber({ app => $app });
		my $app_data = { name => $app, app => $app, formatted_name => &format_name($app), colour => $settings->{'colour'}, dark_colour => $settings->{'dark_colour'} };
		# a registration by date and time, or one by budget: nothing with no
		# registration hangs itself in the tail
		push @{$returner}, $app_data if (&clothesline_slot_wears($cl, \@slot) || &clothesline_schedule_wears($cl, $server_time)) && !&app_hidden_now($app);
		next if grep { $_->{'app'} eq $app } @{$returner};
		# a running session stays even outside its slots, but only while the
		# app has time slots of its own: a line with no registration at all
		# does not hang
		if (&clothesline_registered($cl)) {
			my $running_appts = &db_query('select * from appointments where app = ? and (type = ? or type = ?)', $app, 'start', 'record')->hashes;
			if (scalar @{$running_appts}) {
				push @{$returner}, $app_data unless &app_hidden_now($app);
				next;
			}
		}
		foreach my $circumstance( keys %{$gb::budget_modes} ) {
			if ($cl->{$circumstance . '_budget'}) {
				my $budget = &subs::cache_get({ app => $app, context => 'budget', subcontext => $circumstance });
				if ($budget && grep { $budget->{'status'} eq $_ } @{$cl->{$circumstance . '_budget'}}) {
					push @{$returner}, $app_data unless &app_hidden_now($app);
					last;
				}
			}
		}

	}
	# a renewed phrase is saved once, after every row has been read
	foreach my $app ( sort keys %renew ) {
		&setting_setter({ app => $app, setting => 'clothesline', value => encode_json $renew{$app} });
	}
	# The anticipatory head: the next steps of the routine under way, in the order
	# the person takes them, whether it begins at eight or at ten. The rest of
	# what belongs on the line follows alphabetically. An app in the head is not
	# repeated in the tail, and a step the routine takes twice is one name in the
	# head - the next time it comes round.
	my $anticipation = &clothesline_sequence_anticipate($daily, $server_time, limit => 40);
	my $anticipated = $anticipation->{'list'} || [];
	# The anticipate step already sets a running step at the place the routine
	# usually stops it. Only a session the sequence does not name at all - one
	# started out of its order, or off its day - is put at the head here, so a
	# running app never falls off the line.
	my $running = ($daily->{'current'} && $daily->{'current'}{'running'}) ? $daily->{'current'}{'running'} : undef;
	if (defined $running && length $running && !grep { $_->{'app'} eq $running } @{$anticipated}) {
		unshift @{$anticipated}, { app => $running, wave => $anticipation->{'current_wave'} || 0 };
	}
	my %have = map { $_->{'app'} => $_ } @{$returner};
	my @head;
	foreach my $row ( @{$anticipated} ) {
		my $app = $row->{'app'};
		next unless defined $app && length $app;
		next if $hidden{$app};
		next if &app_hidden_now($app);
		my $item = $have{$app};
		unless ($item) {
			my $aset = &settings_grabber({ app => $app });
			$item = { name => $app, app => $app, formatted_name => &format_name($app), colour => $aset->{'colour'}, dark_colour => $aset->{'dark_colour'} };
		}
		$item->{'wave'} = $row->{'wave'};
		push @head, $item;
	}
	# The person's own say over the head: an app they excluded leaves it, and one
	# they included joins the front even when the routine has not learned it.
	my ($kept, $included) = &clothesline_anticipation_apply(\@head, \%say);
	my @lead;
	foreach my $app ( @{$included} ) {
		next if $hidden{$app} || &app_hidden_now($app);
		my $item = $have{$app};
		unless ($item) {
			my $aset = &settings_grabber({ app => $app });
			$item = { name => $app, app => $app, formatted_name => &format_name($app), colour => $aset->{'colour'}, dark_colour => $aset->{'dark_colour'} };
		}
		push @lead, $item;
	}
	@head = (@lead, @{$kept});
	# The rail draws its divider where the anticipatory steps end and the
	# alphabetical rest begins.
	foreach my $item ( @head ) { $item->{'head'} = 1; }
	@{$returner} = @{ &clothesline_line_order(\@head, $returner) };
	&subs::subprocessor(sub {
		my %done;
		foreach my $clothes ( @{$returner} ) {
			my $app = &subs::unformat_name($clothes->{'app'});
			next if $done{$app}++;
			&Manager::centre_view_grabber({ app => $app, timestamp => &subs::rightNow() });
		}
	}, { name => 'clothesline centreview cacher' });
	my $jreturner = encode_json $returner;
	&setting_setter({ app => '__president', setting => 'clothesline', value => $jreturner });
	return 0;

}

# The house clock's parts in the panel's own words: a saved time slot ('9am',
# 'Sun', 'Nov') is picked against these. The box keeps UTC, so this one read
# adopts the house zone instead of trusting the worker's clock.
sub clothesline_slot_now {
	my ($server_time) = @_;
	my @slot;
	my $restore = &clock_zone_adopt(&clock_zone_house());
	my $now = localtime($server_time / 1000);
	if (ref $now) {
		@slot = map { $now->[$_] } 0 .. 8;
		$slot[4] = $now->monname;
		$slot[5] = $now->[5] + 1900;
		$slot[6] = $now->wdayname;
	}
	$restore->() if $restore;
	return @slot;
}

# An app's own clothesline registration: at least one chosen time slot. A
# running session hangs in the tail only for an app that has one; a budget is
# a different kind of registration and does not keep a running app up.
sub clothesline_registered {
	my ($cl) = @_;
	return 0 unless ref $cl eq 'HASH';
	my $slots = $cl->{'time_plinko'};
	if (ref $slots eq 'HASH') {
		foreach my $chosen ( values %{$slots} ) {
			return 1 if ref $chosen eq 'ARRAY' && scalar @{$chosen};
		}
	}
	# a phrase the Guide read is a registration of its own, so a running app that
	# hangs by its words keeps its pill outside the hours the phrase names
	my $rule = $cl->{'schedule_rule'};
	return 1 if ref $rule eq 'HASH' && ref $rule->{'days'} eq 'HASH' && scalar keys %{$rule->{'days'}};
	return 0;
}

# Does an app's own clothesline registration wear at this moment? Every chosen
# time slot must match, and a slot reading `all` matches any value; an app with
# no time slots never hangs itself this way, though a budget below still can.
sub clothesline_slot_wears {
	my ($cl, $slot) = @_;
	return 0 unless ref $cl eq 'HASH' && ref $slot eq 'ARRAY';
	my $time_plinko = $cl->{'time_plinko'} || {};
	my $count = scalar keys %{$time_plinko};
	return 0 unless $count;
	my $matched = 0;
	foreach my $tp ( @{$gb::time_plinkos} ) {
		my $chosen = $time_plinko->{$tp->{'name'}};
		next unless ref $chosen eq 'ARRAY' && scalar @{$chosen};
		my $ft = $slot->[$tp->{'n'}];
		next unless defined $ft;
		if ($tp->{'name'} eq 'hour') {
			if ($ft == 0) { $ft = '12am'; }
			elsif ($ft >= 12) {
				$ft = 24 if $ft == 12;
				$ft = ($ft - 12) . 'pm';
			}
			else { $ft .= 'am'; }
		}
		$matched++ if grep { defined $_ && ($_ eq $ft || $_ eq 'all') } @{$chosen};
	}
	return $matched >= $count ? 1 : 0;
}

# Order the rail: the anticipatory steps keep the order they were learned in,
# and everything else follows alphabetically by its printed name. An app in the
# head is removed from the tail, so the line never carries the same pill twice.
sub clothesline_line_order {
	my ($head, $tail) = @_;
	$head = [] unless ref $head eq 'ARRAY';
	$tail = [] unless ref $tail eq 'ARRAY';
	my %head_app = map { $_->{'app'} => 1 } @{$head};
	my (%seen, @rest);
	foreach my $item ( sort {
			lc($a->{'formatted_name'} || '') cmp lc($b->{'formatted_name'} || '')
			|| ($a->{'app'} || '') cmp ($b->{'app'} || '')
		} grep { ref $_ eq 'HASH' && !$head_app{$_->{'app'}} } @{$tail} ) {
		next if $seen{$item->{'app'}}++;
		push @rest, $item;
	}
	return [ @{$head}, @rest ];
}

# The person's own say over the anticipatory head. $say maps an app to its
# clothesline setting: 'exclude' takes it out of the learned sequence, 'include'
# names it for the front even when the routine has not learned it, and anything
# else (or no entry) is the routine's own decision. Returns the kept head and the
# included apps the head does not already carry, in name order.
sub clothesline_anticipation_apply {
	my ($head, $say) = @_;
	$head = [] unless ref $head eq 'ARRAY';
	$say = {} unless ref $say eq 'HASH';
	my @kept = grep { ($say->{$_->{'app'}} || '') ne 'exclude' } grep { ref $_ eq 'HASH' } @{$head};
	my %in = map { $_->{'app'} => 1 } @kept;
	my @included = grep { ($say->{$_} || '') eq 'include' && !$in{$_} } sort keys %{$say};
	return (\@kept, \@included);
}

# ---- a schedule written in words -------------------------------------------
# The editor's phrase is read by the Guide associate into the same recurrence
# plans the rest of the house already understands, then expanded here into the
# days (and hours) the rail can match without asking a model again.

# The house day and hour a moment falls on. The box keeps UTC, so the rail reads
# the person's own clock, matching the time slots it already matches against.
sub clothesline_house_day {
	my ($now) = @_;
	$now = &rightNow() unless defined $now;
	my $restore = &clock_zone_adopt(&clock_zone_house());
	my $key = &day_key($now);
	my $hour = (localtime(int($now / 1000)))[2];
	$restore->() if $restore;
	return ($key, defined $hour ? $hour + 0 : 0);
}

# '3pm' from the 24-hour clock, the same words the time-slot grid uses.
sub clothesline_hour_word {
	my $h = int(shift || 0);
	return '12am' if $h == 0;
	return (($h > 12 ? $h - 12 : $h) . ($h >= 12 ? 'pm' : 'am'));
}

# Every day the plan names, from the top of today onward, keyed YYYY-MM-DD, and
# the hours of the day it hangs. A plan is read from the day before today so
# today's own occurrence is included; a bounded plan stops at its own end.
sub clothesline_schedule_expand {
	my ($plan, $now) = @_;
	$now = &rightNow() unless defined $now;
	$plan = {} unless ref $plan eq 'HASH';
	my $plans = ref $plan->{'plans'} eq 'ARRAY' ? $plan->{'plans'} : [];
	my $restore = &clock_zone_adopt(&clock_zone_house());
	my @lt = localtime(int($now / 1000));
	my $start = timelocal(0, 0, 0, $lt[3], $lt[4], $lt[5]) * 1000 - 1;
	my $horizon = &calendar_shift($start, 50, 'year');
	my (%days, $ask);
	foreach my $one ( @{$plans} ) {
		next unless ref $one eq 'HASH';
		my ($dates, $until, $why) = &recurrence_expand($one, $start, max => 500, default_until => $horizon);
		if (defined $why && length $why) { $ask = $why unless defined $ask && length $ask; next; }
		$days{ &day_key($_) } = 1 for @{$dates || []};
	}
	my @raw = ();
	if (ref $plan->{'hours'} eq 'ARRAY') { @raw = @{ $plan->{'hours'} }; }
	elsif (defined $plan->{'hours'} && $plan->{'hours'} =~ /^\s*\d+\s*$/) { @raw = ( $plan->{'hours'} ); }
	my %seen;
	my @hours = sort { $a <=> $b } grep { defined $_ && $_ =~ /^\s*\d+\s*$/ && $_ >= 0 && $_ <= 23 && !$seen{$_ + 0}++ } @raw;
	$restore->() if $restore;
	return { days => \%days, hours => \@hours, ask => ($ask || '') };
}

# Does the app's phrase wear at this moment? The day must be one the plan
# names, and the hour (when the phrase named any) must be one of them.
sub clothesline_schedule_wears {
	my ($cl, $now) = @_;
	return 0 unless ref $cl eq 'HASH' && ref $cl->{'schedule_rule'} eq 'HASH';
	my $rule = $cl->{'schedule_rule'};
	my $days = ref $rule->{'days'} eq 'HASH' ? $rule->{'days'} : {};
	return 0 unless scalar keys %{$days};
	my ($day, $hour) = &clothesline_house_day($now);
	return 0 unless $days->{$day};
	my @hours = @{ ref $rule->{'hours'} eq 'ARRAY' ? $rule->{'hours'} : [] };
	return 1 unless scalar @hours;
	return (grep { $_ =~ /^\d+$/ && $_ == $hour } @hours) ? 1 : 0;
}

# A phrase's days are a window: once its last day has passed, the plan is read
# again from today. A bounded plan (an explicit until) yields no days after its
# end and is left to expire, which is what the person asked for.
sub clothesline_schedule_renew {
	my ($cl, $now) = @_;
	return 0 unless ref $cl eq 'HASH' && ref $cl->{'schedule_rule'} eq 'HASH';
	my $rule = $cl->{'schedule_rule'};
	my $days = ref $rule->{'days'} eq 'HASH' ? $rule->{'days'} : {};
	return 0 unless scalar keys %{$days};
	return 0 unless ref $rule->{'plan'} eq 'HASH';
	my ($today) = &clothesline_house_day($now);
	my @keys = sort keys %{$days};
	return 0 if $keys[-1] ge $today;
	my $fresh = &clothesline_schedule_expand($rule->{'plan'}, $now);
	return 0 unless scalar keys %{ $fresh->{'days'} };
	$rule->{'days'} = $fresh->{'days'};
	$rule->{'refreshed'} = $now;
	return 1;
}

# The Assistant's read of a phrase: the plan it says, and the days and hours
# expanded from it. Nothing here writes; the caller stores the rule.
sub clothesline_schedule_read {
	my ($text, %opt) = @_;
	$text = defined $text ? "$text" : '';
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return { ask => &ui('Say when this routine should hang.') } unless length $text;
	my $now = $opt{'now'} || &rightNow();
	my $model = $opt{'model'} || &setting_grabber({ app => 'mail', setting => 'help_assistant' });
	return { ask => &ui('A schedule written in words needs the Guide model, and none is set.') } unless defined $model && length $model;
	my $restore = &clock_zone_adopt(&clock_zone_house());
	my @lt = localtime(int($now / 1000));
	my $when = POSIX::strftime('%A, %B %d %Y, %I:%M%P', @lt);
	$restore->() if $restore;
	my %bday = eval { %{ &birthday_directory() || {} } };
	my $bday_text = join('; ', map { $_ . ' = ' . $bday{$_} } sort keys %bday) || '(none saved)';
	my $system = <<"TXT";
You turn a person's plain-language schedule for a JawnOS clothesline pill into one JSON object.
It is $when now. The pill hangs when its app is in its own registered time.

Reply with EXACTLY ONE JSON object and nothing else, in this shape:
{"plans":[ ... ], "hours":[15,16,17], "say":"one short sentence in their words"}
Each plan is one recurrence, in one of these shapes:
{"kind":"weekdays","weekdays":["thu"],"until":"2027-07-24"}
{"kind":"interval","interval":"1d","count":10} or {"kind":"interval","interval":"1M","until":"2027-06-01"}
{"kind":"monthly_nth_weekday","nth":3,"weekday":"sat","count":12}
{"kind":"annual","month":2,"day":14}
{"kind":"birthday","person":"mom"}
{"kind":"full_moon","until":"2036-07-01"}
{"kind":"dates","dates":["2026-11-26","2026-12-24"]}
Use one plan for each distinct rule; several named days are several annual plans, or one dates plan.
"hours" is the 24-hour clock, inclusive, of the part of the day it hangs; leave it out for all day.
"count" is how many repeats to make. "until" is an absolute date; "until_after" is a length from the start ("6 weeks"). A date with no year means this year's or the next one that fits.
Add "exclude_holidays":true for "except on holidays", and "except":["2026-12-25"] for other named days.
Common named days: New Year's Day 1/1, Valentine's Day 2/14, Canada Day 7/1, Independence Day 7/4, Halloween 10/31, Remembrance Day 11/11, Christmas Day 12/25, Boxing Day 12/26.
Their saved birthdays: $bday_text.
If the phrase is ambiguous, reply {"ask":"a short question"}.
Do not write prose. Do not invent a date you are unsure of.
TXT
	my ($out, $err) = &evaluation_model_call_role('help_assistant', $system, $text, &ai_role_thinking_effective('help_assistant'));
	return { ask => ($err || &ui('The Guide did not answer that.')) } unless defined $out && $out =~ /\S/;
	my $plan = eval { decode_json $out };
	unless (ref $plan eq 'HASH') {
		if ($out =~ /(\{.*\})/s) { $plan = eval { decode_json $1 }; }
	}
	return { ask => &ui('I could not read that schedule. Can you say it another way?') } unless ref $plan eq 'HASH';
	return { ask => $plan->{'ask'} } if defined $plan->{'ask'} && $plan->{'ask'} =~ /\S/;
	# a model that answered with one plan instead of a list is read as one
	if (ref $plan->{'plans'} ne 'ARRAY') {
		if (ref $plan->{'plan'} eq 'HASH') { $plan->{'plans'} = [ $plan->{'plan'} ]; }
		elsif ($plan->{'kind'}) { $plan->{'plans'} = [ { %{$plan} } ]; }
	}
	my $expanded = &clothesline_schedule_expand($plan, $now);
	return { ask => $expanded->{'ask'} || &ui('I could not find any days in that schedule. Can you say it another way?') }
		unless scalar keys %{ $expanded->{'days'} };
	my $say = (defined $plan->{'say'} && $plan->{'say'} =~ /\S/) ? substr($plan->{'say'}, 0, 300) : '';
	return { rule => {
		text => $text,
		days => $expanded->{'days'},
		hours => $expanded->{'hours'},
		plan => { plans => $plan->{'plans'}, hours => $expanded->{'hours'} },
		say => $say,
		made => $now,
	} };
}

# What the editor prints under the phrase box: how many days it read, the last
# of them, and the hours it hangs. The person's own words are the field's value.
sub clothesline_schedule_status {
	my ($cl) = @_;
	return '' unless ref $cl eq 'HASH' && ref $cl->{'schedule_rule'} eq 'HASH';
	my $rule = $cl->{'schedule_rule'};
	my $days = ref $rule->{'days'} eq 'HASH' ? $rule->{'days'} : {};
	my $count = scalar keys %{$days};
	return &ui('The Guide read no days from that.') unless $count;
	my @keys = sort keys %{$days};
	my @hours = sort { $a <=> $b } @{ ref $rule->{'hours'} eq 'ARRAY' ? $rule->{'hours'} : [] };
	my $span;
	if (!@hours) { $span = &ui('all day'); }
	elsif (scalar(@hours) == 1) { $span = &clothesline_hour_word($hours[0]); }
	elsif ($hours[-1] - $hours[0] == $#hours) { $span = &clothesline_hour_word($hours[0]) . ' ' . &ui('to') . ' ' . &clothesline_hour_word($hours[-1]); }
	else { $span = join(', ', map { &clothesline_hour_word($_) } @hours); }
	my $line = &ui('Hangs on') . ' ' . $count . ' ' . ($count == 1 ? &ui('day') : &ui('days'))
		. ' ' . &ui('through') . ' ' . $keys[-1] . ', ' . $span;
	$line .= ' — ' . $rule->{'say'} if defined $rule->{'say'} && $rule->{'say'} =~ /\S/;
	return $line;
}

# ---- web measures ----------------------------------------------------------
# A web measure used to be a CSS selector plus a count, applied to whatever the
# last fetch stored. That works until a page reorders, and it cannot say where
# a JSON value lives. One spec now covers both worlds:
#
#   JSON:  { "path": "properties.currentConditions.temperature.value.en" }
#   HTML:  { "selector": "#price", "count": 0, "attribute": "text" }
#          { "row": "tr", "match": "Gold", "within": "td" }
#
# with optional regex, fallback, number/unit/scale and the old prev/next
# context. The old selector/count specs keep working unchanged; a JSON id from
# the prettyfier is mapped back to its path, so weather's old selectors start
# reading the decoded JSON instead of the rendered DOM.
sub web_measure_clean_text {
	my ($s) = @_;
	return '' unless defined $s;
	$s =~ s/\x{00A0}/ /g;
	$s =~ s/\s+/ /g;
	$s =~ s/^\s+|\s+$//g;
	return $s;
}

sub web_measure_json_path {
	my ($json, $path) = @_;
	return undef unless defined $path && length $path;
	my $p = $path;
	$p =~ s/^\$//;
	$p =~ s/\[(\d+)\]/.$1/g;
	my @t = grep { length } split /\./, $p;
	my $node = $json;
	for my $t (@t) {
		if (ref $node eq 'HASH') {
			return undef unless exists $node->{$t};
			$node = $node->{$t};
		}
		elsif (ref $node eq 'ARRAY') {
			return undef unless $t =~ /^\d+$/ && $t < scalar @{$node};
			$node = $node->[$t];
		}
		else {
			return undef;
		}
	}
	return $node;
}

# The JSON prettyfier writes <span id="propertiescurrentConditions..."> by
# concatenating the keys (arrays become 1arr, 2arr...). Recover the real path
# from that id, so an old JSON selector keeps working and can be read as a
# path instead of through the rendered page.
sub web_measure_json_id_path {
	my ($json, $id) = @_;
	return undef unless defined $id && length $id;
	my $flat = sub { my $s = shift; $s =~ s/[^A-Za-z0-9]//g; return $s; };
	my $want = $flat->($id);
	my $walk;
	$walk = sub {
		my ($node, $parts, $idparts) = @_;
		if (ref $node eq 'HASH') {
			foreach my $k ( sort keys %{$node} ) {
				my $r = $walk->($node->{$k}, [@{$parts}, $k], [@{$idparts}, $k]);
				return $r if defined $r;
			}
		}
		elsif (ref $node eq 'ARRAY') {
			for my $i ( 0 .. $#{$node} ) {
				my $r = $walk->($node->[$i], [@{$parts}, $i], [@{$idparts}, ($i + 1) . 'arr']);
				return $r if defined $r;
			}
		}
		else {
			return join('.', @{$parts}) if $flat->(join '', @{$idparts}) eq $want;
		}
		return undef;
	};
	return $walk->($json, [], []);
}

# Every scalar path a JSON response offers, for the picker and the audit tool.
sub web_measure_json_paths {
	my ($json, $prefix, $out, $limit) = @_;
	$prefix = '' unless defined $prefix;
	$out = [] unless ref $out eq 'ARRAY';
	$limit ||= 4000;
	return $out if scalar @{$out} >= $limit;
	if (ref $json eq 'HASH') {
		foreach my $k ( sort keys %{$json} ) {
			my $p = length $prefix ? $prefix . '.' . $k : $k;
			&web_measure_json_paths($json->{$k}, $p, $out, $limit);
		}
	}
	elsif (ref $json eq 'ARRAY') {
		for my $i ( 0 .. $#{$json} ) {
			my $p = (length $prefix ? $prefix : '') . '[' . $i . ']';
			&web_measure_json_paths($json->[$i], $p, $out, $limit);
		}
	}
	else {
		push @{$out}, { path => $prefix, value => $json };
	}
	return $out;
}

# One number parser for every source. Currency, percent, a degree sign and a
# unit suffix are stripped; a comma decimal and a thousands separator are read
# by position; a leading minus (or parentheses) is kept. appt_measure_writer
# used to strip everything but digits and dots, which quietly turned -0.5 into
# 0.5.
sub web_measure_number {
	my ($raw, $spec) = @_;
	$spec ||= {};
	return undef unless defined $raw;
	my $s = &web_measure_clean_text($raw);
	return undef unless length $s;
	my $neg = 0;
	if ($s =~ /^\((.*)\)\s*$/) { $neg = 1; $s = $1; }
	my ($token) = $s =~ /([+\-]?(?:\d[\d.,']*|\.\d+)(?:[eE][+\-]?\d+)?)/;
	return undef unless defined $token;
	$token =~ s/['\s]//g;
	my $sign = 1;
	if ($token =~ s/^-//) { $sign = -1; }
	$token =~ s/^\+//;
	my $dec = $spec->{'decimal'};
	my $thou = $spec->{'thousands'};
	if (!defined $dec || !length $dec) {
		my $last_comma = rindex($token, ',');
		my $last_dot = rindex($token, '.');
		if ($last_comma >= 0 && $last_dot >= 0) {
			if ($last_comma > $last_dot) { $dec = ','; $thou = '.'; }
			else { $dec = '.'; $thou = ','; }
		}
		elsif ($last_comma >= 0) {
			my @c = split /,/, $token;
			if (scalar @c == 2 && length($c[1]) && length($c[1]) <= 2) { $dec = ','; $thou = ''; }
			else { $dec = '.'; $thou = ','; }
		}
		else { $dec = '.'; $thou = ''; }
	}
	if ($thou) { $token =~ s/\Q$thou\E//g; }
	if ($dec ne '.') { $token =~ s/\Q$dec\E/./g; }
	return undef unless $token =~ /^\d*(?:\.\d*)?$/ && $token =~ /\d/;
	my $n = $token + 0;
	$n = -$n if $neg || $sign < 0;
	my $scale = $spec->{'scale'};
	$n *= $scale if defined $scale && $scale =~ /^-?\d+(?:\.\d+)?$/;
	if (defined $spec->{'decimals'} && $spec->{'decimals'} =~ /^\d+$/) {
		return sprintf('%.' . $spec->{'decimals'} . 'f', $n);
	}
	# Keep the precision the page wrote. A fixed %.10f rounds 149,095,031.14
	# through a float and prints 149095031.1399999857.
	my $dp = ($token =~ /\.(\d+)$/) ? length($1) : 0;
	$dp = 10 if $dp > 10;
	my $out = sprintf('%.' . $dp . 'f', $n);
	$out =~ s/0+$// if $out =~ /\./;
	$out =~ s/\.$//;
	return $out;
}

# Some pages write a label as bare text, with the value in the next element:
#   Phase: <span>Waxing Crescent</span><br>
# Mojo::DOM drops text nodes from children(), so match the label in the
# container's own markup and return the first element that follows it.
sub web_measure_after_text_label {
	my ($dom, $container, $label, $skip) = @_;
	return undef unless $dom && defined $container && length $container && defined $label && length $label;
	my $box = $dom->at($container) or return undef;
	my $html = $box->to_string;
	my $needle = lc $label;
	my $pos = -1;
	for (my $i = 0; $i <= ($skip || 0); $i++) {
		$pos = index(lc($html), $needle, $pos + 1);
		return undef if $pos < 0;
	}
	my $cursor = 0;
	foreach my $child ( @{$box->children} ) {
		next unless $child->type eq 'tag';
		my $markup = $child->to_string;
		my $at = index($html, $markup, $cursor);
		next unless $at >= 0;
		$cursor = $at + length $markup;
		next unless $at > $pos;
		my $tag = lc($child->tag || '');
		next if $tag eq 'br' || $tag eq 'hr' || $tag eq 'wbr';
		return $child;
	}
	return undef;
}

# Extract one value from a fetched page. $ctx is { format, json, dom, raw }.
sub web_measure_extract {
	my ($spec, $ctx) = @_;
	$spec ||= {};
	$ctx ||= {};
	require Mojo::DOM;
	require Mojo::Collection;
	my $result = { ok => 0, value => undef, raw => undef, used => '', error => '' };
	my $json = $ctx->{'json'};
	my $dom = $ctx->{'dom'};
	my $raw_value;
	my $used = '';
	my $attr = $spec->{'attribute'} || 'text';

	# 1. an explicit JSON path
	if (ref $json && defined $spec->{'path'} && length $spec->{'path'}) {
		my $v = &web_measure_json_path($json, $spec->{'path'});
		if (defined $v && !ref $v) { $raw_value = $v; $used = 'path'; }
		else { $result->{'error'} = 'JSON path not found'; }
	}

	# 2. an old JSON id selector, mapped back to a path
	if (!defined $raw_value && ref $json && defined $spec->{'selector'} && $spec->{'selector'} =~ /^\s*\[id\s*=\s*["']?([^"'\]]+)["']?\]\s*$/i) {
		my $id = $1;
		my $path = &web_measure_json_id_path($json, $id);
		if (defined $path) {
			my $v = &web_measure_json_path($json, $path);
			if (defined $v && !ref $v) {
				$raw_value = $v;
				$used = 'path (from id)';
				$result->{'path'} = $path;
			}
		}
	}

	# 3. label then value: the label's own next cell/sibling, or a selector
	# inside the label's row. This survives a reordered page where a global
	# count does not.
	if (!defined $raw_value && $dom && defined $spec->{'label'} && length $spec->{'label'}) {
		my $want = $spec->{'label'};
		my $match_label = sub {
			my $t = &web_measure_clean_text(shift);
			return 0 unless length $t && length $t <= 200;
			if ($want =~ m{^/(.*)/([i]?)$}) { return $t =~ /$1/i ? 1 : 0; }
			return index(lc($t), lc($want)) >= 0 ? 1 : 0;
		};
		my $scope = $dom;
		if (defined $spec->{'container'} && length $spec->{'container'}) {
			my $box = $dom->at($spec->{'container'});
			$scope = $box if $box;
		}
		# all_text, not text: text only returns an element's own text, so a
		# <td><a>Silver</a></td> or <dd><span>2.4</span></dd> would look empty.
		my @labels = $scope->find('td, th, dt, dd, b, strong, span, div, label, h1, h2, h3, h4, h5, h6, p')->each;
		my @picked = grep { $match_label->($_->all_text) } @labels;
		# the tightest match wins: a <dt>Condition:</dt> is the label, not the
		# <dl> that contains it and its value
		@picked = sort { length($a->all_text) <=> length($b->all_text) } @picked;
		my $label_node = $picked[ $spec->{'label_count'} || 0 ];
		my $node;
		if ($label_node) {
			my $value = $spec->{'value'};
			if (defined $value && $value eq 'parent_next') {
				my $p = $label_node->parent;
				$node = $p ? $p->next : undef;
			}
			elsif (defined $value && $value eq 'next') {
				$node = $label_node->next;
			}
			elsif (defined $spec->{'value_selector'} && length $spec->{'value_selector'}) {
				my $scope = $label_node->parent;
				if (defined $spec->{'row'} && length $spec->{'row'}) {
					my $r = $label_node->ancestors($spec->{'row'})->[0];
					$scope = $r if $r;
				}
				my $nodes = $scope ? $scope->find($spec->{'value_selector'}) : Mojo::Collection->new;
				$node = $nodes->[ $spec->{'count'} || 0 ];
			}
			else {
				# a bare label means "the cell or sibling beside it"
				$node = $label_node->next;
			}
		}
		elsif (defined $spec->{'container'} && length $spec->{'container'}) {
			# a label written as bare text (moongiant: "Moon Angle: <span>0.49</span>")
			# has no element to match; walk the container's children instead.
			$node = &web_measure_after_text_label($dom, $spec->{'container'}, $want, $spec->{'label_count'} || 0);
		}
		if ($node) {
			$raw_value = ($attr ne 'text') ? $node->attr($attr) : $node->all_text;
			$used = 'label';
		}
	}

	# 4. HTML row + label + cell (the stable way to read a table)
	if (!defined $raw_value && $dom && defined $spec->{'row'} && length $spec->{'row'}) {
		my @rows = $dom->find($spec->{'row'})->each;
		my @cand;
		my $match = $spec->{'match'};
		foreach my $row (@rows) {
			my $t = &web_measure_clean_text($row->all_text);
			if (defined $match && length $match) {
				if ($match =~ m{^/(.*)/([i]?)$}) { next unless $t =~ /$1/i; }
				else { next unless index(lc($t), lc($match)) >= 0; }
			}
			if (defined $spec->{'contains'} && length $spec->{'contains'}) {
				next unless index(lc($t), lc($spec->{'contains'})) >= 0;
			}
			push @cand, $row;
		}
		my $row = $cand[ $spec->{'row_count'} || 0 ];
		if ($row) {
			my $nodes = (defined $spec->{'within'} && length $spec->{'within'})
				? $row->find($spec->{'within'})
				: Mojo::Collection->new($row);
			my $node = $nodes->[ $spec->{'count'} || 0 ];
			if ($node) {
				$raw_value = ($attr ne 'text') ? $node->attr($attr) : $node->all_text;
				$used = 'row';
			}
		}
	}

	# 5. the classic CSS selector + count. An [id="…"] selector is a JSON id
	# only when there is JSON to read; on an HTML page it is a real selector
	# (tradingeconomics puts prices in <td id="p">).
	if (!defined $raw_value && $dom && defined $spec->{'selector'} && length $spec->{'selector'} && ($spec->{'selector'} !~ /^\s*\[id\s*=/i || !ref $json)) {
		my @nodes = $dom->find($spec->{'selector'})->each;
		if (defined $spec->{'contains'} && length $spec->{'contains'}) {
			@nodes = grep { index(lc(&web_measure_clean_text($_->all_text)), lc($spec->{'contains'})) >= 0 } @nodes;
		}
		my $node;
		if ((defined $spec->{'prev'} && length $spec->{'prev'}) || (defined $spec->{'next'} && length $spec->{'next'})) {
			foreach my $n ( @nodes ) {
				my $p = $n->previous;
				my $q = $n->next;
				my $okp = !defined $spec->{'prev'} || !length $spec->{'prev'} || ($p && index(lc(&web_measure_clean_text($p->all_text)), lc($spec->{'prev'})) >= 0);
				my $okq = !defined $spec->{'next'} || !length $spec->{'next'} || ($q && index(lc(&web_measure_clean_text($q->all_text)), lc($spec->{'next'})) >= 0);
				if ($okp && $okq) { $node = $n; last; }
			}
		}
		$node ||= $nodes[ $spec->{'count'} || 0 ];
		if ($node) {
			$raw_value = ($attr ne 'text') ? $node->attr($attr) : $node->all_text;
			$used = 'selector';
		}
	}

	# 6. named fallbacks
	if (!defined $raw_value && ref $spec->{'fallback'} eq 'ARRAY') {
		foreach my $f ( @{$spec->{'fallback'}} ) {
			next unless ref $f eq 'HASH';
			my $r = &web_measure_extract($f, $ctx);
			return $r if $r->{'ok'};
		}
	}

	unless (defined $raw_value) {
		$result->{'error'} ||= 'no element matched';
		return $result;
	}

	if (defined $spec->{'regex'} && length $spec->{'regex'}) {
		my $re = $spec->{'regex'};
		if ($re =~ m{^/(.*)/([i]?)$}) { $re = $1; }
		if ($raw_value =~ /$re/) { $raw_value = defined $1 ? $1 : $&; }
		else { $result->{'error'} = 'regex did not match'; return $result; }
	}

	$raw_value = &web_measure_clean_text($raw_value);
	if ($spec->{'number'}) {
		my $n = &web_measure_number($raw_value, $spec);
		return { %{$result}, error => 'not a number' } unless defined $n;
		$raw_value = $n;
	}
	return { ok => 1, value => $raw_value, raw => $raw_value, used => $used, error => '', path => $result->{'path'} };
}

# Suggest working specs for a label on this page. The useful shape for a table
# is "the row that contains Gold, cell N", where N is the first cell *after*
# the label. Every candidate is tested against the page before it is offered,
# so a suggestion is a value the extractor will really read.
sub web_measure_suggest {
	my ($ctx, $label) = @_;
	my $dom = $ctx->{'dom'};
	return [] unless $dom && defined $label && length $label;
	my @out;
	my $seen;
	my $add = sub {
		my ($spec, $value) = @_;
		my $key = join '|', map { $_ . '=' . (defined $spec->{$_} ? $spec->{$_} : '') } sort keys %{$spec};
		return if $seen->{$key}++;
		push @out, { spec => $spec, value => $value };
	};
	my $test = sub {
		my ($spec) = @_;
		my $r = &web_measure_extract($spec, $ctx);
		return undef unless $r->{'ok'} && defined $r->{'value'} && length $r->{'value'};
		return &web_measure_clean_text($r->{'value'});
	};

	# the row that holds the label, then the cells after the label's own cell
	my @rows = grep {
		index(lc(&web_measure_clean_text($_->all_text)), lc($label)) >= 0
	} $dom->find('tr')->each;
	foreach my $row ( @rows ) {
		my @cells = $row->find('td, th')->each;
		my $label_idx = -1;
		for my $i ( 0 .. $#cells ) {
			if (index(lc(&web_measure_clean_text($cells[$i]->all_text)), lc($label)) >= 0) { $label_idx = $i; last; }
		}
		next if $label_idx < 0;
		for my $j ( $label_idx + 1 .. $#cells ) {
			my $txt = &web_measure_clean_text($cells[$j]->all_text);
			next unless length $txt;
			my $spec = { row => 'tr', match => $label, within => 'td, th', count => $j };
			my $v = $test->($spec);
			$add->($spec, $v) if defined $v;
		}
		foreach my $sel ( '[data-testid="change"]', '.price', '.value', 'span', 'b', 'strong' ) {
			my $spec = { row => 'tr', match => $label, within => $sel, count => 0 };
			my $v = $test->($spec);
			$add->($spec, $v) if defined $v;
		}
		last if scalar @out >= 4;
	}

	# definition-list / label-and-next shapes
	foreach my $spec ( { label => $label, value => 'next' }, { label => $label, value => 'parent_next' } ) {
		my $v = $test->($spec);
		$add->($spec, $v) if defined $v;
	}

	# a label written as bare text inside a container that has an id
	# (moongiant: "Moon Angle: <span>0.49</span>")
	my $scanned = 0;
	foreach my $box ( $dom->find('[id]')->each ) {
		last if scalar @out >= 4 || $scanned++ >= 200;
		my $kids = $box->children;
		next if scalar @{$kids} > 100;
		my $html = $box->to_string;
		foreach my $child ( @{$kids} ) {
			next unless $child->type eq 'tag';
			next if ($child->tag || '') =~ /^(?:br|hr|wbr)$/i;
			my $markup = $child->to_string;
			my $at = index($html, $markup);
			next if $at <= 0;
			my ($tail) = substr($html, 0, $at) =~ /([^<>]*)$/;
			$tail = &web_measure_clean_text($tail);
			next unless $tail =~ /([A-Za-z][A-Za-z0-9 .\/#%()+_-]{0,40}:)\s*$/;
			my $near = $1;
			next unless index(lc($near), lc($label)) >= 0;
			my $spec = { container => '#' . $box->attr('id'), label => $near };
			my $v = $test->($spec);
			$add->($spec, $v) if defined $v;
			last if scalar @out >= 4;
		}
	}
	return \@out;
}

1;
