package subs;

# Schedule: extracted from subroutines.pl (package subs). Loaded on
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

our %M;
our %Y;
our $config;
our $device;
our %m;
our %recurrence_plan_cache;
# What a picker shows: the whole family is still readable by time_span(), but
# scrolling three hundred of them is not a picker, so this is the handful per
# unit that gets reached for, in size order.  Add or drop names here freely.
our $time_picker_spans;

# The next occurrence of an interval, calendar-aware for months and years.
sub schedule_next {
	my ($timestamp, $every, $anchor_day) = @_;
	my ($count, $unit) = &interval_parse($every);
	return undef unless defined $count && defined $unit && $unit ne 'once' && $count > 0;
	return &calendar_shift($timestamp, $count, $unit, $anchor_day);
}

sub day_key {
	my ($ts) = @_;
	return '' unless defined $ts;
	return POSIX::strftime('%Y-%m-%d', localtime(int($ts / 1000)));
}

# ---- schedules written in words -------------------------------------------
# A schedule can also be a phrase: "every third Saturday of the month", "the
# next five full moons", "my mom's next 5 birthdays". The Guide reads the
# words into a small plan and the functions below do every piece of date
# arithmetic, because a model is good at language and poor at counting dates.

# The day-of-month of the $nth $wday (0 Sunday .. 6 Saturday) in a month;
# $nth -1 is the last one. 0 when the month has no such day.
sub nth_weekday_of_month {
	my ($year, $month, $wday, $nth) = @_;
	$year += 0; $month += 0; $wday += 0;
	$nth = 1 unless defined $nth && $nth =~ /^-?\d+$/;
	$nth += 0;
	my $last = &days_in_month($year, $month);
	return 0 unless $last;
	if ($nth < 0) {
		my @t = localtime(timelocal(0, 0, 0, $last, $month - 1, $year - 1900));
		my $back = ($t[6] - $wday + 7) % 7;
		return $last - $back;
	}
	return 0 if $nth < 1;
	my @f = localtime(timelocal(0, 0, 0, 1, $month - 1, $year - 1900));
	my $day = 1 + (($wday - $f[6] + 7) % 7) + 7 * ($nth - 1);
	return 0 if $day < 1 || $day > $last;
	return $day;
}

# Easter Sunday in the Gregorian calendar (the anonymous algorithm).
sub easter_sunday {
	my $year = shift;
	my $a = $year % 19;
	my $b = int($year / 100);
	my $c = $year % 100;
	my $d = int($b / 4);
	my $e = $b % 4;
	my $f = int(($b + 8) / 25);
	my $g = int(($b - $f + 1) / 3);
	my $h = (19 * $a + $b - $d - $g + 15) % 30;
	my $i = int($c / 4);
	my $k = $c % 4;
	my $l = (32 + 2 * $e + 2 * $i - $h - $k) % 7;
	my $m = int(($a + 11 * $h + 22 * $l) / 451);
	my $month = int(($h + $l - 7 * $m + 114) / 31);
	my $day = (($h + $l - 7 * $m + 114) % 31) + 1;
	return ($month, $day);
}

# The days the house treats as holidays, keyed YYYY-MM-DD. The built-in set is
# a common US/Canada list; "Name = date" lines in the __president holidays
# setting add the family's own (a date with a year is one day, a month and day
# repeat every year). "except on holidays" skips these days.
sub holiday_days {
	my ($from, $to) = @_;
	$from = &rightNow() unless defined $from;
	$to = &calendar_shift($from, 5, 'year') unless defined $to;
	my @f = localtime(int($from / 1000));
	my @t = localtime(int($to / 1000));
	my ($y0, $y1) = ($f[5] + 1900, $t[5] + 1900);
	$y1 = $y0 + 5 if $y1 < $y0;
	$y1 = $y0 + 100 if $y1 > $y0 + 100;
	my %day;
	my $put = sub {
		my ($y, $m, $d, $name) = @_;
		return unless $m && $d && $d >= 1 && $d <= &days_in_month($y, $m);
		$day{ sprintf('%04d-%02d-%02d', $y, $m, $d) } = $name;
	};
	for my $y ($y0 .. $y1) {
		$put->($y, 1, 1, "New Year's Day");
		$put->($y, 7, 1, 'Canada Day');
		$put->($y, 7, 4, 'Independence Day');
		$put->($y, 11, 11, 'Remembrance Day');
		$put->($y, 12, 25, 'Christmas Day');
		$put->($y, 12, 26, 'Boxing Day');
		$put->($y, 1, &nth_weekday_of_month($y, 1, 1, 3), 'Martin Luther King Day');
		$put->($y, 2, &nth_weekday_of_month($y, 2, 1, 3), "Presidents' Day");
		$put->($y, 5, &nth_weekday_of_month($y, 5, 1, -1), 'Memorial Day');
		$put->($y, 9, &nth_weekday_of_month($y, 9, 1, 1), 'Labor Day');
		$put->($y, 10, &nth_weekday_of_month($y, 10, 1, 2), 'Thanksgiving (Canada)');
		$put->($y, 11, &nth_weekday_of_month($y, 11, 4, 4), 'Thanksgiving (US)');
		# Victoria Day: the Monday before May 25
		my @may = localtime(timelocal(0, 0, 0, 24, 4, $y - 1900));
		$put->($y, 5, 24 - (($may[6] - 1 + 7) % 7), 'Victoria Day');
		my ($em, $ed) = &easter_sunday($y);
		$put->($y, $em, $ed, 'Easter Sunday');
		my $good = &calendar_shift(timelocal(0, 0, 0, $ed, $em - 1, $y - 1900) * 1000, -2, 'day');
		my @g = localtime(int($good / 1000));
		$put->($g[5] + 1900, $g[4] + 1, $g[3], 'Good Friday');
	}
	# the family's own holidays, in the birthdays setting's "Name = date" shape
	my $custom = eval { &setting_grabber({ app => '__president', setting => 'holidays', device => 'all' }) };
	if (defined $custom && $custom =~ /\S/) {
		foreach my $line ( split /\n/, $custom ) {
			next unless $line =~ /\S/;
			my ($name, $when) = split /\s*=\s*/, $line, 2;
			next unless defined $when && $when =~ /\S/ && $name =~ /\S/;
			my $resolved = &resolve_when($when, timelocal(0, 0, 12, 1, 0, $y0 - 1900) * 1000);
			next unless defined $resolved;
			my @r = localtime(int($resolved / 1000));
			my ($rm, $rd) = ($r[4] + 1, $r[3]);
			if ($when =~ /\b\d{4}\b/) {
				$put->($r[5] + 1900, $rm, $rd, $name);
			}
			else {
				$put->($_, $rm, $rd, $name) for $y0 .. $y1;
			}
		}
	}
	return \%day;
}

# A full moon via Meeus's lunar phase series (the main periodic terms), accurate
# to about a minute. $k is the lunation number; the same k is a full moon.
sub moon_full_ts {
	my $k = shift;
	my $T = $k / 1236.85;
	my $JDE = 2451550.09766 + 29.530588861 * $k + 0.00015437 * $T ** 2
		- 0.000000150 * $T ** 3 + 0.00000000073 * $T ** 4;
	my $M = 2.5534 + 29.10535670 * $k - 0.0000014 * $T ** 2 - 0.00000011 * $T ** 3;
	my $Mp = 201.5643 + 385.81693528 * $k + 0.0107582 * $T ** 2
		+ 0.00001238 * $T ** 3 - 0.000000058 * $T ** 4;
	my $F = 160.7108 + 390.67050284 * $k - 0.0016118 * $T ** 2
		- 0.00000227 * $T ** 3 + 0.000000011 * $T ** 4;
	my $O = 124.7746 - 1.56375588 * $k + 0.0020672 * $T ** 2 + 0.00000215 * $T ** 3;
	my $sin = sub { sin(deg2rad($_[0])) };
	$JDE +=
		-0.40614 * $sin->($Mp) + 0.17302 * $sin->($M)
		+ 0.01614 * $sin->(2 * $Mp) + 0.01043 * $sin->(2 * $F)
		+ 0.00734 * $sin->($Mp - $M) - 0.00515 * $sin->($Mp + $M)
		+ 0.00209 * $sin->(2 * $M) - 0.00111 * $sin->($Mp - 2 * $F)
		+ 0.00056 * $sin->(2 * $Mp + $M) - 0.00042 * $sin->(3 * $Mp)
		+ 0.00042 * $sin->($M + 2 * $F) + 0.00038 * $sin->($M - 2 * $F)
		- 0.00024 * $sin->(2 * $Mp - $M) - 0.00017 * $sin->($O)
		- 0.00007 * $sin->($Mp + 2 * $M) + 0.00004 * $sin->(2 * $Mp - 2 * $F)
		+ 0.00004 * $sin->(3 * $M) + 0.00003 * $sin->($Mp + $M - 2 * $F)
		+ 0.00003 * $sin->(2 * $Mp + 2 * $F) - 0.00003 * $sin->($Mp + $M + 2 * $F)
		+ 0.00003 * $sin->($Mp - $M + 2 * $F) - 0.00002 * $sin->($Mp - $M - 2 * $F)
		- 0.00002 * $sin->(3 * $Mp + $M) + 0.00002 * $sin->(4 * $Mp);
	return ($JDE - 2440587.5) * 86400 * 1000;
}

# The full moons after a moment, oldest first.
sub full_moons_after {
	my ($from, $count) = @_;
	$from = &rightNow() unless defined $from;
	$count = 1 unless defined $count && $count > 0;
	my @lt = localtime(int($from / 1000));
	my $k = int((($lt[5] + 1900) - 2000) * 12.3685);
	my @all;
	for my $i (-3 .. 3) { push @all, &moon_full_ts($k + $i + 0.5); }
	@all = sort { $a <=> $b } @all;
	my @out;
	for my $ts (@all) {
		next unless $ts > $from;
		push @out, $ts;
		last if @out >= $count;
	}
	my $step = $k + 3;
	while (@out < $count && $step < $k + 600) {
		$step++;
		my $ts = &moon_full_ts($step + 0.5);
		push @out, $ts if $ts > $from;
	}
	return @out;
}

# The moment a named person reaches an age, from a saved birthday.
sub person_age_moment {
	my ($name, $age, $now) = @_;
	return undef unless defined $name && $name =~ /\S/ && defined $age && $age =~ /^\d{1,3}$/;
	my $birth = &saved_birthday_ms($name, $now);
	return undef unless defined $birth;
	my @b = localtime(int($birth / 1000));
	my $year = $b[5] + 1900 + $age;
	return &resolve_when(sprintf('%04d-%02d-%02d %02d:%02d:%02d',
		$year, $b[4] + 1, $b[3], $b[2], $b[1], $b[0]), $now);
}

# The Guide reads a phrase into one of the plans recurrence_expand knows. The
# plan is remembered for the day: a schedule typed on every press of the same
# app's usual phrase should not cost a model call each time.
sub recurrence_plan_from_model {
	my ($text, $start, %opts) = @_;
	my $model = $opts{'model'} || &setting_grabber({ app => 'mail', setting => 'help_assistant' });
	my $cache_key = lc($text) . '|' . &day_key($start || &rightNow()) . '|' . ($model || '');
	return $recurrence_plan_cache{$cache_key} if $recurrence_plan_cache{$cache_key};
	return { ask => 'A schedule written in words needs the Guide model, and none is set.' } unless $model;
	my $now = &rightNow();
	my @lt = localtime(int(($start || $now) / 1000));
	my $when = POSIX::strftime('%A, %B %d %Y, %I:%M%P', @lt);
	my %bday = eval { %{ &birthday_directory() || {} } };
	my $bday_text = join('; ', map { $_ . ' = ' . $bday{$_} } sort keys %bday) || '(none saved)';
	my $system = <<"TXT";
You turn a person's plain-language recurrence into one JSON object for JawnOS.
The appointment or bill is being started on $when, and that moment is always the first occurrence. Describe only the repeats after it.

Reply with EXACTLY ONE JSON object and nothing else. Use one of these shapes:
{"kind":"interval","interval":"1d","count":10} or {"kind":"interval","interval":"1M","until":"2027-06-01"}
{"kind":"weekdays","weekdays":["tue"],"until_after":"6 weeks"}
{"kind":"monthly_nth_weekday","nth":3,"weekday":"sat","count":12}
{"kind":"annual","month":2,"day":12,"until_person":"mom","until_age":80}
{"kind":"birthday","person":"mom","count":5}
{"kind":"full_moon","count":5}
{"kind":"dates","dates":["2026-11-26","2026-12-24"]}
Add "exclude_holidays":true for "except on holidays", and "except":["2026-12-25"] for any other named dates.
"count" is how many repeats to make. "until" is an absolute date; "until_after" is a length from the start ("6 weeks"); "until_person" + "until_age" is the day that person reaches that age. A date with no year means this year's or the next one that fits.
A span of time ("for the next 6 weeks", "through June") is "until_after" (or "until" when it names a date); a number of named events ("the next 5 full moons", "5 birthdays") is "count".
Use monthly_nth_weekday for "every third Saturday", weekdays for "every Tuesday", full_moon for the moon, birthday for a saved person's birthday, and annual for a named day each year (an anniversary). For an annual anniversary you know, give its month and day; if you do not know it, ask.
Their saved birthdays: $bday_text.
If the phrase is ambiguous, or a person is not saved and you do not know their birthday, reply {"ask":"a short question"}.
Do not write prose. Do not invent a date you are unsure of.
TXT
	my ($out, $err) = &evaluation_model_call_role('help_assistant', $system, $text, &ai_role_thinking('help_assistant'));
	return { ask => ($err || 'I could not read that schedule.') } unless defined $out && $out =~ /\S/;
	my $plan = eval { decode_json $out };
	unless (ref $plan eq 'HASH') {
		if ($out =~ /(\{.*\})/s) { $plan = eval { decode_json $1 }; }
	}
	return { ask => 'I could not read that schedule. Can you say it another way?' } unless ref $plan eq 'HASH';
	return { ask => $plan->{'ask'} } if defined $plan->{'ask'} && $plan->{'ask'} =~ /\S/;
	$recurrence_plan_cache{$cache_key} = $plan;
	return $plan;
}

# The horizon a plan names: an absolute date, or the day a person reaches an age.
sub recurrence_until {
	my ($plan, $start) = @_;
	my $until;
	if (defined $plan->{'until_after'} && $plan->{'until_after'} =~ /\S/) {
		return &schedule_until($plan->{'until_after'}, $start);
	}
	if (ref $plan->{'until'} eq 'HASH') {
		my $u = $plan->{'until'};
		return &person_age_moment($u->{'person'}, $u->{'age'}, $start) if $u->{'person'} && $u->{'age'};
		$until = $u->{'date'};
	}
	elsif (defined $plan->{'until_person'} && defined $plan->{'until_age'}) {
		return &person_age_moment($plan->{'until_person'}, $plan->{'until_age'}, $start);
	}
	else { $until = $plan->{'until'}; }
	return undef unless defined $until && $until =~ /\S/;
	return $until + 0 if $until =~ /^\d{12,}$/;
	my $ms = &resolve_when($until, $start);
	return $ms if defined $ms;
	if ($until =~ /^\s*(\d{4})-(\d{1,2})-(\d{1,2})\s*$/) {
		return timelocal(59, 59, 23, $3, $2 - 1, $1 - 1900) * 1000;
	}
	return undef;
}

# Turn a plan into the repeat timestamps after $start. Returns the list, the
# horizon, and a question when the plan cannot be carried out.
sub recurrence_expand {
	my ($plan, $start, %opts) = @_;
	$start = &rightNow() unless defined $start;
	my $max = $opts{'max'} || 366;
	my $until = &recurrence_until($plan, $start);
	my $count = (defined $plan->{'count'} && $plan->{'count'} =~ /^\d+$/) ? int($plan->{'count'}) : undef;
	my $kind = $plan->{'kind'} || '';
	# A horizon that names a person's age needs their saved birthday; without it
	# the rule would silently run longer than the person asked for.
	my $age_who = '';
	if (ref $plan->{'until'} eq 'HASH' && $plan->{'until'}->{'person'} && $plan->{'until'}->{'age'}) {
		$age_who = $plan->{'until'}->{'person'};
	}
	elsif (defined $plan->{'until_person'} && $plan->{'until_person'} =~ /\S/ && defined $plan->{'until_age'}) {
		$age_who = $plan->{'until_person'};
	}
	if ($age_who ne '' && !defined $until) {
		return ([], undef, 'I do not know when ' . $age_who . ' was born. Add their birthday under Configure -> App -> Birthdays, or tell me the end as a date.');
	}
	if (!defined $until && !$count && ((defined $plan->{'until'} && !ref $plan->{'until'} && $plan->{'until'} =~ /\S/) || (ref $plan->{'until'} eq 'HASH' && $plan->{'until'}->{'date'} =~ /\S/))) {
		return ([], undef, 'I could not read the end date of that schedule. Can you give it as a date?');
	}
	# A rule with no end of its own runs to the app's warranty when the caller
	# names one, or ten years otherwise. The cap still bounds a daily rule. An
	# explicit list of dates is the rule itself, so it gets no horizon.
	if ($kind ne 'dates' && !defined $until && !defined $count) {
		$until = $opts{'default_until'} if defined $opts{'default_until'} && $opts{'default_until'} > $start;
		$until = &calendar_shift($start, 10, 'year') unless defined $until;
	}
	my %except;
	foreach my $e ( @{ $plan->{'except'} || [] } ) {
		my $ts = ($e =~ /^\d{12,}$/) ? $e + 0 : &resolve_when($e, $start);
		$except{&day_key($ts)} = 1 if defined $ts;
	}
	my $holidays = $plan->{'exclude_holidays'} ? &holiday_days($start, $until || &calendar_shift($start, 10, 'year')) : {};
	my @dates;
	my $consider = sub {
		my ($ts) = @_;
		return 0 unless defined $ts && $ts > $start;
		return 0 if defined $until && $ts > $until;
		my $key = &day_key($ts);
		return 0 if $except{$key};
		return 0 if $holidays->{$key};
		return 0 if grep { $_ == $ts } @dates;
		push @dates, $ts;
		return 1;
	};
	my $stop = sub { (defined $count && @dates >= $count) || @dates >= $max };
	my $wd = {
		sun => 0, sunday => 0, mon => 1, monday => 1, tue => 2, tues => 2, tuesday => 2,
		wed => 3, wednesday => 3, thu => 4, thur => 4, thurs => 4, thursday => 4,
		fri => 5, friday => 5, sat => 6, saturday => 6
	};
	my @lt = localtime(int($start / 1000));
	my ($h, $m, $s) = ($lt[2], $lt[1], $lt[0]);
	my $anchor_day = $lt[3];
	my $at_time = sub {
		my ($y, $mo, $d) = @_;
		$mo += 0; $d += 0;
		return undef unless $mo >= 1 && $mo <= 12;
		my $last = &days_in_month($y, $mo);
		$d = $last if $d > $last;
		return timelocal($s, $m, $h, $d, $mo - 1, $y - 1900) * 1000;
	};
	if ($kind eq 'interval') {
		my ($c, $u) = &interval_parse($plan->{'interval'} || '1d');
		unless (defined $c && defined $u && $u ne 'once' && $c > 0) {
			return ([], $until, 'I could not read the repeat interval. Can you say it as an interval such as 1d or 2 weeks?');
		}
		my $n = 1;
		while (!$stop->() && $n < 5000) {
			my $ts = &calendar_shift($start, $c * $n, $u, $anchor_day);
			last if defined $until && $ts > $until;
			$consider->($ts);
			$n++;
		}
	}
	elsif ($kind eq 'weekdays') {
		my %want;
		foreach my $d ( @{ $plan->{'weekdays'} || [] } ) {
			my $k = lc($d // ''); $k =~ s/[^a-z]//g;
			$want{ $wd->{$k} } = 1 if defined $wd->{$k};
		}
		return ([], $until, 'I could not tell which weekdays to use. Can you name them?') unless %want;
		my $n = 1;
		while (!$stop->() && $n < 5000) {
			my $ts = &calendar_shift($start, $n, 'day');
			last if defined $until && $ts > $until;
			$consider->($ts) if $want{ (localtime(int($ts / 1000)))[6] };
			$n++;
		}
	}
	elsif ($kind eq 'monthly_nth_weekday') {
		my $nth = int($plan->{'nth'} || 1);
		my $key = lc($plan->{'weekday'} // ''); $key =~ s/[^a-z]//g;
		my $w = $wd->{$key};
		return ([], $until, 'I could not tell which weekday that is. Can you name it?') unless defined $w;
		if (defined $w) {
			for my $i (0 .. 600) {
				last if $stop->();
				my $idx = ($lt[5] + 1900) * 12 + $lt[4] + $i;
				my $y = int($idx / 12);
				my $mo = ($idx % 12) + 1;
				my $d = &nth_weekday_of_month($y, $mo, $w, $nth);
				next unless $d;
				my $ts = $at_time->($y, $mo, $d);
				last if defined $until && $ts > $until;
				$consider->($ts);
			}
		}
	}
	elsif ($kind eq 'annual' || $kind eq 'birthday') {
		my ($mo, $d);
		if ($kind eq 'birthday') {
			my $birth;
			$birth = &saved_birthday_ms($plan->{'person'}, $start) if $plan->{'person'};
			$birth = &resolve_when($plan->{'birth_date'}, $start) unless defined $birth;
			return ([], $until, 'I do not know that person\'s birthday. Add it under Configure -> App -> Birthdays, or tell me the date.') unless defined $birth;
			my @b = localtime(int($birth / 1000));
			($mo, $d) = ($b[4] + 1, $b[3]);
		}
		else {
			$mo = int($plan->{'month'} || 0);
			$d = int($plan->{'day'} || 0);
			return ([], $until, 'I need the month and day of that anniversary.') unless $mo >= 1 && $mo <= 12 && $d >= 1 && $d <= 31;
		}
		my $y = $lt[5] + 1900;
		for (1 .. 600) {
			last if $stop->();
			my $ts = $at_time->($y, $mo, $d);
			last if defined $until && $ts > $until;
			$consider->($ts);
			$y++;
		}
	}
	elsif ($kind eq 'full_moon') {
		my $want = defined $count ? $count : $max;
		for my $ts (&full_moons_after($start, $want + 5)) {
			last if $stop->();
			$consider->($ts);
		}
	}
	elsif ($kind eq 'dates') {
		foreach my $e ( @{ $plan->{'dates'} || [] } ) {
			last if $stop->();
			my $ts;
			if ($e =~ /^\d{12,}$/) { $ts = $e + 0; }
			elsif ($e =~ /^\s*(\d{4})-(\d{1,2})-(\d{1,2})\s*$/) { $ts = $at_time->($1 + 0, $2 + 0, $3 + 0); }
			else { $ts = &resolve_when($e, $start); }
			$consider->($ts);
		}
	}
	else {
		return ([], $until, 'I could not tell what rule to repeat. Can you say it another way?');
	}
	@dates = sort { $a <=> $b } @dates;
	return ([], $until, 'I could not find any dates for that schedule. Can you say it another way?') unless @dates;
	return (\@dates, $until);
}

# The one entry point both the appointment form and the payable form call.
# Compact text stays on the fast parser; anything else is read by the Guide.
sub schedule_from_text {
	my ($text, $start, %opts) = @_;
	$start = &rightNow() unless defined $start;
	$text = '' unless defined $text;
	my $max = $opts{'max'} || 366;
	my $compact = &schedule_parse($text);
	return { dates => [], source => 'once' } if $compact && $compact->{'once'};
	if ($compact && !$compact->{'error'}) {
		my $until = &schedule_until($compact->{'horizon'}, $start);
		$until = $opts{'default_until'} unless defined $until;
		my @dates;
		my $anchor = (localtime(int($start / 1000)))[3];
		my $n = 1;
		while (@dates < $max && $n < 5000) {
			my $ts = &calendar_shift($start, $compact->{'count'} * $n, $compact->{'unit'}, $anchor);
			last if defined $until && $ts >= $until;
			push @dates, $ts;
			$n++;
		}
		return { dates => \@dates, source => 'interval', every => $compact->{'every'}, until => $until, plan => $compact };
	}
	my $plan = &recurrence_plan_from_model($text, $start, %opts);
	return { ask => $plan->{'ask'}, source => 'guide', plan => $plan } if $plan->{'ask'};
	my ($dates, $until, $ask) = &recurrence_expand($plan, $start, max => $max, default_until => $opts{'default_until'});
	return { ask => $ask, source => 'guide', plan => $plan } if $ask;
	return { dates => $dates, source => 'guide', plan => $plan, until => $until };
}

# ---- a schedule waiting for the Guide to finish it ------------------------
# When a phrase cannot be read yet, the appointment or bill is already made and
# the facts needed to finish it later are held under a token. The Associate is
# handed that token, asks its question, and calls the schedule action with the
# clarified words; nothing is written until then.
sub pending_schedules {
	my $raw = eval { &setting_grabber({ app => '__president', setting => 'pending_schedules', device => 'all' }) } || '[]';
	my $list = eval { decode_json $raw } || [];
	$list = [] unless ref $list eq 'ARRAY';
	return [ grep { ref $_ eq 'HASH' } @{$list} ];
}

sub pending_schedules_save {
	my $list = shift || [];
	&setting_setter({ app => '__president', setting => 'pending_schedules', device => 'all', value => encode_json($list) });
}

sub pending_schedule_add {
	my $row = shift || {};
	my $list = &pending_schedules();
	my $now = &rightNow();
	# a clarification older than a day is stale; it belongs to a form the person
	# has long since left
	@{$list} = grep { (($_->{'created'} || 0) + 0) > $now - 86400000 } @{$list};
	push @{$list}, $row;
	splice @{$list}, 0, @{$list} - 20 if @{$list} > 20;
	&pending_schedules_save($list);
	return $row->{'token'};
}

sub pending_schedule_get {
	my $token = shift;
	return undef unless defined $token && length $token;
	my $list = &pending_schedules();
	my ($row) = grep { ($_->{'token'} || '') eq $token } @{$list};
	return $row;
}

sub pending_schedule_drop {
	my $token = shift;
	my $list = &pending_schedules();
	@{$list} = grep { ($_->{'token'} || '') ne $token } @{$list};
	&pending_schedules_save($list);
}

# The rows a page of periods walks: the periods around now first (the nexts,
# this one, the lasts), then the block of periods before or after it, so
# scrolling a graph sideways carries on along the timeline.  A row that names
# periods ahead counts from the request forward, so the part of this period
# already spent belongs to "this" and never shows in a row past it.
sub time_scope_page {
	my $data = shift;
	my $count = $data->{'count'} || 30;
	my $page = $data->{'page'} || 0;
	return ( ( map { $_ . 'next' } reverse( 2 .. $count ) ), 'next', 'this', 'last', ( map { $_ . 'last' } 2 .. $count ) ) unless $page;
	return ( map { $_ . 'last' } ( $page * $count + 1 .. ( $page + 1 ) * $count ) ) if $page > 0;
	my $ahead = -$page;
	return ( map { $_ . 'next' } reverse( $ahead * $count + 1 .. ( $ahead + 1 ) * $count ) );
}

sub time_span_list {
	return sort { &time_spans()->{$a}->[0] <=> &time_spans()->{$b}->[0] || $a cmp $b } keys %{&time_spans()};
}

sub time_span_picker {
	my $spans = &time_spans();
	foreach my $span ( @{$time_picker_spans} ) {
		die "unknown time span in the picker: $span" unless $spans->{$span};
	}
	return sort { $spans->{$a}->[0] <=> $spans->{$b}->[0] || $a cmp $b } @{$time_picker_spans};
}

sub time_span_label {
	my $span = shift;
	my $found = &time_spans()->{$span};
	return $found ? $found->[1] : undef;
}

# A warranty that never expires, in the epoch milliseconds every warranty here
# is compared in. Year 3000 is a constant on purpose: no expiry check or sweep
# will ever reach it, and two machines comparing the same ticket agree. The app
# tickets carry it, so the desktop and mobile apps never ask for a login again.
sub forever_warranty {
	return 32503680000000;    # 3000-01-01T00:00:00Z in ms
}

# The age a phrase names, if it names one: "when I'm 60", "when I am 60", "60yo",
# "60 years old", "my 35th birthday". The caller matches the lowercased phrase
# with its apostrophes already dropped, so "I'm" reads as "im".
sub age_phrase_target {
	my ($t) = @_;
	return $1 if $t =~ /\bwhen\s+i\s+(?:am|turn)\s+(\d{1,3})\b/;
	return $1 if $t =~ /\bwhen\s+im\s+(\d{1,3})\b/;
	return $1 if $t =~ /\b(\d{1,3})\s*yo\b/;
	return $1 if $t =~ /\b(\d{1,3})\s*years?\s*old\b/;
	return $1 if $t =~ /\bmy\s+(\d{1,3})(?:st|nd|rd|th)?\s+birthday\b/;
	return undef;
}

# The moment the person is a given age: the present time of day, in the year they
# reach it ("today, but when I'm 60"). Reads the birthday the way every other
# date is read, so a written birthday works. undef when none is set or the sum
# will not make a date, so the caller falls through.
sub birthday_moment_for_age {
	my ($target, $now) = @_;
	return undef unless $config->{'birthday'};
	my $born = &resolve_when($config->{'birthday'}, $now);
	return undef unless defined $born;
	my @n = localtime($now / 1000);
	my @b = localtime($born / 1000);
	my $age = ($n[5] + 1900) - ($b[5] + 1900);
	$age-- if $n[4] < $b[4] || ($n[4] == $b[4] && $n[3] < $b[3]);
	my $year = $n[5] + 1900 + ($target - $age);
	my $epoch = eval { int(POSIX::mktime($n[0], $n[1], $n[2], $n[3], $n[4], $year - 1900)) };
	return undef unless defined $epoch;
	return $epoch * 1000;
}

1;
