package subs;

# Resolve: extracted from subroutines.pl (package subs). Loaded on
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

our %H;
our %M;
our %Y;
our $config;
our $device;
our $gb;
our %ghost_done_memo;
our %ghost_times_memo;
our %m;
our $resolve_when_residual;

# Read a typed time the way a person writes one. A relative offset ("-3h", "in 2
# days", "3d 4h") belongs to ago_calc's own arithmetic and is left to it; a
# calendar date is read here, so a bare "jul 16", an ordinal "16th 2", a "last
# dec 25" and a full "dec 25 2025 at 7:04pm" all land where they say. A date with
# no time of day keeps the present time of day; a date with no year is this year,
# and a leading "last"/"next" moves it by one. A bare ordinal day with no month
# rolls to the next month once it is already behind. Returns undef when the text
# is not a calendar date, so ago_calc keeps its old path untouched.
sub resolve_when {
	my ($text,$now) = @_;
	$now = &rightNow() unless $now;
	$resolve_when_residual = '';
	my $t = lc($text // '');
	$t =~ s/['\x{2019}]//g;       # "when I'm 60" reads as "when im 60", "new year's" as "new years"
	$t =~ s/[.,]/ /g;             # "Jan.", "dec 25, 2025"
	$t =~ s/\s+/ /g;
	$t =~ s/^\s+|\s+$//g;
	return undef unless length $t;
	return $now + 0 if $t eq 'now';
	# the day-words, whole days from the present at the same time of day, read
	# here so ago_calc's string surgery (which mangles "yesterday") is not used
	my %day_word = (today => 0, tonight => 0, tomorrow => 1, tom => 1, yesterday => -1, yes => -1);
	return $now + $day_word{$t} * 86400000 if defined $day_word{$t};
	# a day-word with a time of day ("yesterday around 6pm", "tomorrow at 9"):
	# the day moves whole days and the written hour pins the time, so the fast
	# reader answers it without the Guide
	if ($t =~ /^(yesterday|today|tonight|tomorrow|tom|yes)\b\s*(?:at|around|about|by|@)?\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*$/) {
		my ($word, $hour, $min, $ap) = ($1, $2 + 0, ($3 // 0) + 0, $4);
		my $day = $day_word{$word};
		$hour += 12 if (defined $ap && lc($ap) eq 'pm' && $hour < 12)
			|| (!defined $ap && $word eq 'tonight' && $hour < 12);
		$hour = 0 if defined $ap && lc($ap) eq 'am' && $hour == 12;
		my @d = localtime(($now + $day * 86400000) / 1000);
		my $e = eval { int(POSIX::mktime(0, $min, $hour, $d[3], $d[4], $d[5])) };
		return $e * 1000 if defined $e;
	}
	# a leading modifier moves the whole date a year: "last dec 25", "next jul 16";
	# "this christmas" pins it to this year
	my $year_shift = 0;
	if ($t =~ s/^last\s+//) { $year_shift = -1; }
	elsif ($t =~ s/^next\s+//) { $year_shift = 1; }
	elsif ($t =~ s/^this\s+//) { $year_shift = 0; }
	$t =~ s/^\s+|\s+$//g;
	return undef unless length $t;

	# a named holiday, at this year's date, moved by the modifier above: "this
	# christmas" is December 25 of this year, "next christmas" next year's. Read
	# here, before the offset words below, or "new year" would be taken for an
	# amount of time. Only the fixed dates - a movable feast (Thanksgiving, Easter)
	# is left to the guide, which counts the days.
	my %holiday = (
		christmas => [12,25], xmas => [12,25],
		'new year' => [1,1], 'new years' => [1,1], 'new years day' => [1,1],
		'new years eve' => [12,31],
		halloween => [10,31],
		'valentines day' => [2,14], valentines => [2,14],
		'independence day' => [7,4],
	);
	if (my $h = $holiday{$t}) {
		my @n = localtime($now / 1000);
		my $yr = $n[5] + 1900 + $year_shift;
		my $e = eval { int(POSIX::mktime($n[0], $n[1], $n[2], $h->[1], $h->[0] - 1, $yr - 1900)) };
		return $e * 1000 if defined $e;
	}

	# an age, read against the person's birthday: the present time of day in the
	# year they reach that age ("today, but when I'm 60")
	if (my $age_target = &age_phrase_target($t)) {
		my $aged = &birthday_moment_for_age($age_target, $now);
		return $aged if defined $aged;
	}
	# any other "birthday" phrase names an age or a person, not a day of the month:
	# "<name>'s 35th birthday" would otherwise read as "the 35th" and overflow into
	# the next month. Leave it to the guide, which looks the person up.
	return undef if $t =~ /\bbirthday\b/;
	# a spelled-out or joined offset ("2 hours", "3d 4h") is arithmetic, not a date
	return undef if $t =~ /\b(?:milliseconds?|seconds?|minutes?|hours?|days?|weeks?|months?|years?|decades?|centur(?:y|ies))\b/;

	# a year written in words: "44 bc" is the year -44, the negative year the app
	# shows B.C. as; "ad"/"ce" leaves the year as written
	my $bc = 0;
	if ($t =~ s/\b(\d{1,4})\s*(?:bc|bce)\b//i) { $bc = $1 + 0; }
	else { $t =~ s/\b(\d{1,4})\s*(?:ad|ce)\b//i; }
	$t =~ s/^\s+|\s+$//g;

	my %month = (
		january=>1, february=>2, march=>3, april=>4, may=>5, june=>6, july=>7,
		august=>8, september=>9, october=>10, november=>11, december=>12,
		sept=>9, jan=>1, feb=>2, mar=>3, apr=>4, jun=>6, jul=>7,
		aug=>8, sep=>9, oct=>10, nov=>11, dec=>12
	);
	my @now = localtime($now / 1000);

	# the time of day, when one is written
	my ($hour, $min, $sec) = ($now[2], $now[1], $now[0]);
	my $has_time = 0;
	my $scan = $t;
	if ($scan =~ /\b(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?\b/) {
		($hour, $min, $sec) = ($1 + 0, $2 + 0, ($3 // 0) + 0);
		my $ap = $4;
		$hour += 12 if defined $ap && $ap eq 'pm' && $hour < 12;
		$hour = 0   if defined $ap && $ap eq 'am' && $hour == 12;
		$has_time = 1;
	}
	elsif ($scan =~ /\b(\d{1,2})\s*(am|pm)\b/) {
		($hour, $min, $sec) = ($1 + 0, 0, 0);
		$hour += 12 if $2 eq 'pm' && $hour < 12;
		$hour = 0   if $2 eq 'am' && $hour == 12;
		$has_time = 1;
	}
	# drop the time so the day and the year are not read out of it
	$scan =~ s/\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?\b/ /g;
	$scan =~ s/\b\d{1,2}\s*(?:am|pm)\b/ /g;

	my ($mon, $day, $year);
	my $date_like = 0;
	my $year_given = 0;
	if ($scan =~ /(?:^|[^\d-])(-?\d{1,4})-(\d{1,2})-(\d{1,2})(?![\d-])/) {
		($year, $mon, $day) = ($1 + 0, $2 + 0, $3 + 0);
		$date_like = $year_given = 1;
	}
	elsif ($scan =~ /\b(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?\b/) {
		($mon, $day) = ($1 + 0, $2 + 0);
		$date_like = 1;
		if (defined $3) { $year = $3 < 100 ? ($3 < 69 ? 2000 + $3 : 1900 + $3) : $3 + 0; $year_given = 1; }
	}
	elsif ($bc) { $year = -$bc; $date_like = $year_given = 1; }
	# any four-figure year, including "0001" and the hundreds ("first christmas"
	# is year 1); a lone four-figure number is read as a year
	if (!$date_like && $scan =~ /\b(\d{4})\b/) { $year = $1 + 0; $date_like = $year_given = 1; }
	if (!$mon && $scan =~ /\b(january|february|march|april|may|june|july|august|september|october|november|december|sept|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)\b/) {
		$mon = $month{$1};
		$date_like = 1;
	}
	my $month_named = $mon ? 1 : 0;
	my $ordinal = 0;
	if ($scan =~ /\b(\d{1,2})(?:st|nd|rd|th)\b/ && $1 >= 1 && $1 <= 31) { $day = $1 + 0; $date_like = 1; $ordinal = 1; }
	return undef unless $date_like;

	# what is left once the month, year and any date form are removed: the day, if
	# a month was named but no ordinal, and then a lone small number is the hour
	my $residual = ' ' . $scan . ' ';
	$residual =~ s/\b(?:january|february|march|april|may|june|july|august|september|october|november|december|sept|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec)\b/ /g;
	$residual =~ s{-?\d{1,4}-\d{1,2}-\d{1,2}}{ }g;
	$residual =~ s{\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b}{ }g;
	if (defined $year) { $residual =~ s/\b\Q$year\E\b/ /g; }
	if (defined $day) {
		$residual =~ s/\b0*\Q$day\E(?:st|nd|rd|th)?\b/ /g;
	}
	elsif ($residual =~ /\b(\d{1,2})\b/) {
		$day = $1 + 0;
		$residual =~ s/\b0*\Q$day\E\b/ /g;
	}
	# a lone small number left over is the hour ("16th 2"); a two-figure number
	# too big for an hour is a short year ("oct 12 96" is October 12 1996)
	if ($residual =~ /\b(\d{1,2})\b/) {
		my $n = $1 + 0;
		if (!$has_time && $n <= 24) {
			$hour = $n; $min = 0; $sec = 0; $has_time = 1;
		}
		elsif (!defined $year && $n >= 25) {
			$year = $n < 69 ? 2000 + $n : 1900 + $n;
			$year_given = 1;
		}
	}
	$resolve_when_residual = $residual;

	$year = $now[5] + 1900 unless defined $year;
	$year += $year_shift;
	$mon = $now[4] + 1 unless defined $mon;
	$day = $now[3] unless defined $day;
	my $epoch = eval { int(POSIX::mktime($sec, $min, $hour, $day, $mon - 1, $year - 1900)) };
	return undef unless defined $epoch;
	my $ms = $epoch * 1000;
	# a bare ordinal day ("16th 2") with no month or year rolls to the next month
	# once the moment it names is behind
	if ($ordinal && !$month_named && !$year_given) {
		for (my $i = 0; $i < 24 && $ms < $now; $i++) {
			$mon++;
			if ($mon > 12) { $mon = 1; $year++; }
			my $e = eval { int(POSIX::mktime($sec, $min, $hour, $day, $mon - 1, $year - 1900)) };
			last unless defined $e;
			$ms = $e * 1000;
		}
	}
	return $ms;
}

# Whether the last resolve_when read only a date, or left words it could not read.
# "dec 25 at 7pm" leaves only connective words, but "sept 11 attacks" leaves a
# name - which the guide should read instead of the bare date (so the phrase means
# the 2001 attacks, not this year's September 11).
sub date_leftover {
	my ($r) = @_;
	$r = lc($r // '');
	$r =~ s/\b(?:at|on|in|of|the|a|an|and|am|pm|o|clock|oclock)\b/ /g;
	return $r =~ /[a-z]/ ? 1 : 0;
}

# A local time as an unambiguous ISO string, its year signed so B.C. reads as a
# negative year ("-0044-03-15 00:00:00"). resolve_when reads this back exactly,
# which is what the walkman's jump buttons hand the time machine.
sub iso_local {
	my ($ms) = @_;
	return '' unless defined $ms;
	# the same idiom every other printer uses, so this agrees with the screens;
	# strftime %Y already writes a negative year as "-44" and year 1 as "1", and
	# resolve_when reads both back
	my $t = localtime($ms / 1000);
	return '' unless ref $t;
	return $t->strftime('%Y-%m-%d %H:%M:%S');
}

# The birthdays the person keeps (Configure -> App -> Birthdays), one to a line as
# "Name = date" ("Abraham Lincoln = February 12 1809"). Read across devices - the
# newest value wins - so a save on any machine is seen everywhere.
sub saved_birthdays {
	my $row = &db_query('select value from settings where app = ? and setting = ? order by server_time desc limit 1', 'me', 'birthdays')->hashes->[0];
	my %bday;
	foreach my $line ( split /\n/, ($row->{'value'} // '') ) {
		next unless $line =~ /\S/;
		my ($name, $when) = split /\s*=\s*/, $line, 2;
		if (!defined $when) { ($name, $when) = split /\s*:\s*/, $line, 2; }
		next unless defined $when && $when =~ /\S/ && $name =~ /\S/;
		$name = lc $name;
		$name =~ s/['\x{2019}]//g;
		$name =~ s/\s+/ /g; $name =~ s/^\s+|\s+$//g;
		$bday{$name} = $when;
	}
	return \%bday;
}

# The saved birthday for a named person, in ms, or undef. A thing named for the
# person (its app) carries its own Birthday setting, and that is read first; then
# the list; failing both, a name whose words all sit inside the other's, so
# "Lincoln" finds "Abraham Lincoln".
sub saved_birthday_ms {
	my ($name, $now) = @_;
	return undef unless defined $name && $name =~ /\S/;
	$now = &rightNow() unless $now;
	my $own = &setting_grabber({ app => &unformat_name($name), setting => 'birthday' });
	return &resolve_when($own, $now) if defined $own && $own =~ /\S/;
	my $clean = lc $name;
	$clean =~ s/['\x{2019}]//g;
	$clean =~ s/\s+/ /g; $clean =~ s/^\s+|\s+$//g;
	my $all = &saved_birthdays();
	my $hit = $all->{$clean};
	unless (defined $hit) {
		my %q = map { $_ => 1 } split ' ', $clean;
		foreach my $k ( sort keys %{$all} ) {
			my %kw = map { $_ => 1 } split ' ', $k;
			my ($all_in, $all_out) = (1, 1);
			$all_in = 0 foreach grep { !$kw{$_} } keys %q;
			$all_out = 0 foreach grep { !$q{$_} } keys %kw;
			if ($all_in || $all_out) { $hit = $all->{$k}; last; }
		}
	}
	return undef unless defined $hit;
	return &resolve_when($hit, $now);
}

# Every birthday the house can name: the "Name = date" list plus each
# construct that carries a Birthday setting of its own (a person app's own
# panel). The Guide is given this directory so "my mom's next 5 birthdays" can
# resolve to a saved person instead of asking for a date it already has.
sub birthday_directory {
	my %all = eval { %{ &saved_birthdays() || {} } };
	my $rows = eval { &db_query("select app, value, server_time from settings where setting = 'birthday' and value is not null and value != '' order by server_time asc")->hashes } || [];
	foreach my $r ( @{$rows} ) {
		next unless ($r->{'app'} // '') =~ /\S/ && ($r->{'value'} // '') =~ /\S/;
		my $name = lc $r->{'app'};
		$name =~ s/['\x{2019}]//g;
		$name =~ s/\s+/ /g; $name =~ s/^\s+|\s+$//g;
		$all{$name} = $r->{'value'};
	}
	return \%all;
}

# The times of day an app's records cluster around: the busiest hours (a habit can
# fall more than once a day - coffee mid-morning and again mid-afternoon), each
# with the minute that clusters within it. Empty with no records, so a caller
# falls back to a plain clock time.
sub usual_times_for {
	my ($app) = @_;
	return unless $app;
	my $rows = &db_query('select timestamp from appointments where app = ? order by timestamp desc limit 500', $app)->hashes;
	my (%hour, %min);
	foreach my $r (@{$rows}) {
		next unless defined $r->{'timestamp'} && $r->{'timestamp'} =~ /^-?\d+$/;
		my @t = localtime($r->{'timestamp'} / 1000);
		$hour{$t[2]}++;
		push @{ $min{$t[2]} }, $t[1];
	}
	return unless scalar keys %hour;
	# the peaks: take the busiest hour, drop the hours beside it, and take the next
	# busiest that is left - so a two-a-day habit yields two times. A walk-off peak
	# below a quarter of the top is a tail, not a second habit.
	my $top = (sort { $b <=> $a } values %hour)[0] || 1;
	my (%taken, @peaks);
	foreach my $h ( sort { $hour{$b} <=> $hour{$a} || $a <=> $b } keys %hour ) {
		next if $taken{$h};
		last if $hour{$h} < $top * 0.25;
		last if scalar @peaks >= 5;
		push @peaks, $h;
		my $x = $h - 2;
		$taken{$x++} = 1 for 1 .. 5;
	}
	my @times;
	foreach my $h ( sort { $a <=> $b } @peaks ) {
		my %m;
		$m{$_}++ foreach @{ $min{$h} };
		my ($bm) = sort { $m{$b} <=> $m{$a} || $a <=> $b } keys %m;
		push @times, [ $h + 0, ($bm // 0) + 0 ];
	}
	return @times;
}

# A time of day that is a habit rather than a date ("breakfast", "tea time", "next
# coffee time"): the times the person usually does it, read from that app's own
# records, and a plain hour when there is nothing to read. "next" is the next of
# those times after now (today, else tomorrow); otherwise it is the one nearest
# now, today. undef when the phrase names no such habit.
sub usual_ritual_time {
	my ($spec, $now) = @_;
	$now = &rightNow() unless $now;
	my $t = lc($spec // '');
	$t =~ s/['\x{2019}]//g;
	$t =~ s/[.,]/ /g; $t =~ s/\s+/ /g; $t =~ s/^\s+|\s+$//g;
	return undef unless length $t;
	my $next = 0;
	if ($t =~ s/^next\s+//) { $next = 1; }
	my %ritual = (
		'breakfast'   => [ 'breakfast', 8, 0 ],
		'brekkie'     => [ 'breakfast', 8, 0 ],
		'lunch'       => [ 'lunch', 12, 0 ],
		'brunch'      => [ 'brunch', 11, 0 ],
		'dinner'      => [ 'dinner', 18, 0 ],
		'supper'      => [ 'dinner', 18, 0 ],
		'tea'         => [ 'tea', 16, 0 ],
		'tea time'    => [ 'tea', 16, 0 ],
		'coffee'      => [ 'coffee', 10, 0 ],
		'coffee time' => [ 'coffee', 10, 0 ],
		'bed'         => [ 'bed', 22, 0 ],
		'bed time'    => [ 'bed', 22, 0 ],
		'bedtime'     => [ 'bed', 22, 0 ],
	);
	my $r = $ritual{$t};
	return undef unless $r;
	my ($app, $hour, $min) = @{$r};
	my @times = &usual_times_for($app);
	@times = ( [ $hour, $min ] ) unless @times;
	my @n = localtime($now / 1000);
	my $today = sub {
		my ($tm) = @_;
		my $e = eval { int(POSIX::mktime(0, $tm->[1], $tm->[0], $n[3], $n[4], $n[5])) };
		return defined $e ? $e * 1000 : undef;
	};
	my $ms;
	if ($next) {
		foreach my $tm ( @times ) {
			my $c = $today->($tm);
			next unless defined $c;
			if ($c > $now) { $ms = $c; last; }
		}
		unless (defined $ms) {
			my $e = eval { int(POSIX::mktime(0, $times[0]->[1], $times[0]->[0], $n[3] + 1, $n[4], $n[5])) };
			$ms = $e * 1000 if defined $e;
		}
	}
	else {
		my $best;
		foreach my $tm ( @times ) {
			my $c = $today->($tm);
			next unless defined $c;
			my $d = abs($c - $now);
			$best = [ $d, $c ] if !$best || $d < $best->[0];
		}
		$ms = $best->[1] if $best;
	}
	return $ms;
}

# The times an app is expected to happen, for the ghost appointments a clock draws
# ahead of now. The record's own habit comes first (the hours its appointments
# cluster around); with too little to read, the app's saved clothesline hours; and
# with none, the hours of its own 'usual' occurrences. Memoized briefly, so the
# viewer's poll does not re-read the history on every tick.
sub ghost_times_for {
	my ($app) = @_;
	return [] unless defined $app && length $app;
	my $cache = $ghost_times_memo{$app};
	return $cache->{'times'} if $cache && &rightNow() - $cache->{'at'} < 300000;
	my @out = &usual_times_for($app);
	if (!@out) {
		my $cl = eval { return decode_json &setting_grabber({ app => $app, setting => 'clothesline' }) } || {};
		foreach my $h ( @{ $cl->{'time_plinko'}->{'hour'} || [] } ) {
			my $hh = &hour_from_words($h);
			push @out, [ $hh, 0 ] if defined $hh;
		}
	}
	if (!@out) {
		my $rows = &db_query(q{select timestamp from appointments where app = ? and type = 'usual' order by timestamp desc limit 200}, $app)->hashes;
		my (%h, %m);
		foreach my $r (@{$rows}) {
			next unless defined $r->{'timestamp'} && $r->{'timestamp'} =~ /^-?\d+$/;
			my @t = localtime($r->{'timestamp'} / 1000);
			$h{$t[2]}++;
			push @{ $m{$t[2]} }, $t[1];
		}
		foreach my $hh ( sort { $a <=> $b } keys %h ) {
			my %mm; $mm{$_}++ foreach @{ $m{$hh} };
			my ($bm) = sort { $mm{$b} <=> $mm{$a} || $a <=> $b } keys %mm;
			push @out, [ $hh + 0, ($bm // 0) + 0 ];
		}
	}
	$ghost_times_memo{$app} = { at => &rightNow(), times => \@out };
	return \@out;
}

sub hour_from_words {
	my ($h) = @_;
	my $s = lc($h // '');
	return undef unless $s =~ /^(\d{1,2})\s*(am|pm)?$/;
	my ($n, $ap) = ($1 + 0, $2);
	if (defined $ap) {
		return 0 if $ap eq 'am' && $n == 12;
		return 12 if $ap eq 'pm' && $n == 12;
		return $n + 12 if $ap eq 'pm';
		return $n;
	}
	return $n <= 23 ? $n : undef;
}

sub usual_duration_for {
	my ($app) = @_;
	my $rows = &db_query(q{select duration from appointments where app = ? and type = 'stop' order by timestamp desc limit 20}, $app)->hashes;
	my @d = map { (defined $_->{'duration'} && $_->{'duration'} =~ /^-?\d+$/) ? abs($_->{'duration'}) + 0 : () } @{$rows};
	if (@d) {
		my $t = 0; $t += $_ for @d;
		return int($t / scalar @d);
	}
	my $s = &setting_grabber({ app => $app, setting => 'duration' });
	return &time_abbrev_translator($s) if defined $s && $s =~ /\S/;
	return 0;
}

sub ghost_done_times_for {
	my ($app) = @_;
	my $cache = $ghost_done_memo{$app};
	return $cache->{'reals'} if $cache && &rightNow() - $cache->{'at'} < 60000;
	my $now = &rightNow();
	my $rows = &db_query('select timestamp from appointments where app = ? and cast(timestamp as integer) between ? and ? order by timestamp', $app, $now - 86400000, $now + 8 * 86400000)->hashes;
	my @reals = map { $_->{'timestamp'} + 0 } grep { defined $_->{'timestamp'} && $_->{'timestamp'} =~ /^-?\d+$/ } @{$rows};
	$ghost_done_memo{$app} = { at => $now, reals => \@reals };
	return \@reals;
}

# The ghost rows for one app: its expected times that have not been met and are not
# already scheduled. An expected time is dropped once a real appointment sits
# nearest to it (a started or scheduled occurrence - the coffee that just began
# stops being a ghost until tomorrow's comes round). The next expected time beyond
# the view is kept too, so a clock shows it clamped at the edge rather than
# nothing.
sub ghost_rows_for {
	my ($app, $now, $view_end) = @_;
	my $times = &ghost_times_for($app);
	return [] unless @{$times};
	my @n = localtime($now / 1000);
	# the expected times from yesterday to a week out, so a real appointment can be
	# matched to the occurrence it belongs to
	my @cand;
	for my $d (-1 .. 7) {
		foreach my $tm ( @{$times} ) {
			my $e = eval { int(POSIX::mktime(0, $tm->[1], $tm->[0], $n[3] + $d, $n[4], $n[5])) };
			push @cand, $e * 1000 if defined $e;
		}
	}
	my %done;
	foreach my $r ( @{ &ghost_done_times_for($app) } ) {
		my ($bi, $bd);
		for my $i (0 .. $#cand) {
			my $d = abs($cand[$i] - $r);
			if (!defined $bd || $d < $bd) { $bd = $d; $bi = $i; }
		}
		$done{$cand[$bi]} = 1 if defined $bi && $bd <= 3 * 3600000;
	}
	my @in;
	my $beyond;
	foreach my $ts (@cand) {
		next unless $ts > $now;
		next if $done{$ts};
		if (defined $view_end && $ts <= $view_end) { push @in, $ts; }
		elsif (!defined $beyond || $ts < $beyond) { $beyond = $ts; }
	}
	@in = sort { $a <=> $b } @in;
	@in = @in[0 .. 5] if @in > 6;
	push @in, $beyond if !@in && defined $beyond;
	my $duration = &usual_duration_for($app);
	return [ map { { ghost => 1, app => $app, type => 'usual', timestamp => $_, duration => $duration, formatted_name => &format_name($app) } } @in ];
}

# Work claims: who is sorting out what, so two agents - or two machines - do not
# take the same job. They live as settings on the 'claims' app, which is NOT one of
# @gb::protected, so the mesh merge carries each claim to every machine; the
# protected __president settings (the agent registry among them) stay local.
sub work_claims {
	my $rows = &db_query(q{select setting, value from settings where app = 'claims' order by cast(server_time as integer) desc})->hashes;
	my %claims;
	foreach my $r (@{$rows}) {
		next unless ($r->{'setting'} || '') =~ /^claim_(.+)$/;
		my $task = $1;
		next if $claims{$task};   # newest first, so the first row for a task wins
		my $c = eval { decode_json $r->{'value'} } || {};
		next unless ref $c eq 'HASH' && $c->{'by'};
		$claims{$task} = $c;
	}
	return \%claims;
}

sub work_claim {
	my ($task) = @_;
	return undef unless defined $task && $task =~ /\S/;
	return (&work_claims())->{$task};
}

sub claim_work {
	my ($task, $note) = @_;
	return undef unless defined $task && $task =~ /\S/;
	my $value = encode_json({ by => &signatorial_designer(), machine => &machine_name(), at => &rightNow(), note => ($note // '') });
	&setting_setter({ app => 'claims', setting => 'claim_' . $task, value => $value });
	return &work_claim($task);
}

# The machine's own name, for a claim a person has to read. The signatorial is the
# mesh identity; this is what to show beside it.
#
# Android has no hostname of its own - Termux answers `hostname` with 'localhost'
# and some builds answer a build token ('fe'), neither of which tells a person
# which device it is. The config's own name, then its house domain's first label
# (phone.jonathanferwerda.com -> Phone), are the names a person actually uses;
# the OS hostname is the last resort and only when it is a real name.
sub machine_name {
	# The config's own name is what the rest of the app shows (Generate, Notify,
	# the page title, the ws fallback), so it comes first here too. A machine's
	# `me/computer_name` can be a leftover from setup - the laptop's read 'fe' -
	# and used to win, which is why a laptop called Laptop answered as 'fe'.
	my $config = eval { &config_reader() } || {};
	my $configured = &machine_name_from_config($config, '');
	return $configured if $configured ne '';
	my $name = &setting_grabber({ app => 'me', setting => 'computer_name' }) || &setting_grabber({ app => 'me', setting => 'my_name' });
	$name =~ s/^\s+|\s+$//g if defined $name;
	return $name if defined $name && $name ne '';
	my $h = `hostname`;
	chomp $h;
	$h =~ s/^\s+|\s+$//g;
	return '' if $h eq '' || $h =~ /^(?:localhost|127\.0\.0\.1|::1)$/i;
	return $h;
}

# The name a machine shows when no setting names it: the config's own name, then
# the first label of its house domain, then the OS hostname when that is a real
# name. Kept apart from the settings read so the fallback order can be tested.
sub machine_name_from_config {
	my ($config, $os_hostname) = @_;
	$config ||= {};
	my $configured = $config->{'name'} || '';
	$configured =~ s/^\s+|\s+$//g;
	return $configured if $configured ne '';
	my $label = &device_hostname_from_domain($config->{'domain'});
	return $label if $label ne '';
	my $h = defined $os_hostname ? $os_hostname : '';
	$h =~ s/^\s+|\s+$//g;
	return '' if $h eq '' || $h =~ /^(?:localhost|127\.0\.0\.1|::1)$/i;
	return $h;
}

# The first label of a house domain, when it names a machine: a domain that is an
# ip literal, loopback, the tailnet's CGNAT range or 'localhost' says nothing.
sub device_hostname_from_domain {
	my $domain = shift || '';
	$domain =~ s{^[a-z]+://}{}i;
	$domain =~ s{[:/].*$}{};
	$domain =~ s/^\s+|\s+$//g;
	return '' if $domain eq '' || $domain !~ /[a-z]/i || $domain !~ /\./;
	return '' if $domain =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
	return '' if $domain =~ /^(?:127\.|localhost$|\[?::1\]?$)/i;
	return '' if $domain =~ /^100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./;
	my ($label) = split /\./, $domain;
	return '' unless defined $label && $label =~ /[a-z]/i;
	return ucfirst lc $label;
}

# The name a person reads for a machine. A phone has no hostname of its own:
# Android/Termux answers `hostname` with 'localhost', and that used to overwrite
# the good name a peer had already learned every time the phone reconnected.
# Prefer the machine's own report, then the name we already remember, then the
# first label of its fqdn (phone.example.com -> Phone).
sub device_hostname_better {
	my ($reported, $stored, $fqdn) = @_;
	my $clean = sub {
		my $n = shift;
		return '' unless defined $n;
		$n =~ s/^\s+|\s+$//g;
		return '' if $n eq '' || $n eq 'null' || $n eq 'NULL';
		return '' if $n =~ /^(?:localhost|127\.0\.0\.1|::1|\[?::1\]?)(?::\d+)?$/i;
		return $n;
	};
	my $own = $clean->($reported);
	return $own if $own ne '';
	my $remembered = $clean->($stored);
	return $remembered if $remembered ne '';
	my $host = $clean->($fqdn);
	# only a real name says anything: an ip-literal fqdn would give '192' or a
	# stray hextet as a device name
	if ($host ne '' && $host =~ /[a-z]/i && $host =~ /\./) {
		my $label = &device_hostname_from_domain($host);
		return $label if $label ne '';
	}
	# Nothing usable was reported: do not hand 'localhost' back as a name. The
	# caller keeps what it has rather than learning a name that means "this
	# machine" on every machine.
	return '';
}

# Released by writing it empty rather than deleting it, so the release rides the
# same mesh merge the claim does.
sub release_work {
	my ($task) = @_;
	return unless defined $task && $task =~ /\S/;
	&setting_setter({ app => 'claims', setting => 'claim_' . $task, value => '' });
}

sub ago_calc {
	my ($ago,$timestamp) = @_;
	# A caller with no offset is the empty offset, not an error; the arithmetic
	# below then behaves as it did, without the split/pattern warnings.
	$ago = '' unless defined $ago;
	$timestamp = &rightNow() unless $timestamp;
	# a written calendar date is read whole here; a relative offset ("-3h") and
	# everything else falls through to the arithmetic below, unchanged
	my $resolved = &resolve_when($ago, $timestamp);
	return $resolved if defined $resolved;
	my $server_time = &subs::rightNow();
	my $server_dow = localtime($timestamp / 1000)->[6];
	my $time_dow = localtime($timestamp / 1000)->[6];
	my @days = qw/sun mon tue wed thu fri sat/;
	my @ago = split ' ', $ago;
	my $announced_time;
	my $difference = 0;
	if ($ago =~ /(yo)/) {
		my $birthday = &subs::duration_sayer( ($timestamp / 1000 ) - &ago_calc( $config->{'birthday'},$timestamp) / 1000) || (($timestamp / 1000 ) - (&original_timestamp() / 1000 ) );
		my $birthday_timestamp = &ago_calc( $config->{'birthday'},$timestamp);
		my @years_ago = grep { $_ =~ 'yo' } @ago;
		my $years_ago = $years_ago[0];
		my @birthday = split ' ', $birthday;
		my $bday = $birthday[0];
		if ($bday != $years_ago) {
			my $tims = $years_ago - $bday;
			my $diff = &subs::time_abbrev_translator('1y',$timestamp);
			$timestamp = ($diff * $tims) + $timestamp;
		}
		@ago = grep { $_ !~ 'yo' } @ago;
		$ago = join ' ', @ago;
	}
	if ($ago) {
		if ($ago =~ /(tom)/) {
			$difference = &time_span('day', 0);
			$ago =~ s/$1//gi;
		}
		if ($ago =~ /(yes)/) {
			$difference = -1 * &time_span('day', 0);
			$ago =~ s/$1//gi;
		}

		my $is_dow = 0;
		if ($ago =~ /(mon)/) {
			$difference = (1 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(tue)/) {
			$difference = (2 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(wed)/) {
			$difference = (3 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(thu)/) {
			$difference = (4 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(fri)/) {
			$difference = (5 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(sat)/) {
			$difference = (6 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		elsif ($ago =~ /(sun)/) {
			$difference = (7 - $time_dow) * &time_span('day', 0);
			$ago =~ s/$1//gi;
			$is_dow = 1;
		}
		if ($ago =~ /[:\/APap]/) {
			$timestamp = str2time($ago) * 1000;
			$announced_time = ago(($server_time - $timestamp ) / 1000) if $server_time != $timestamp;
		}
		else {
			my $subtractable = &subs::time_abbrev_translator($ago,$timestamp);
			$timestamp = $timestamp - $subtractable;
			my $time = localtime($timestamp / 1000 )->strftime('%I:%M%P');
			my $date = localtime($timestamp / 1000 )->strftime('%A %B %d %Y');
			my $todays_date = localtime()->strftime('%A %B %d %Y');
			my $todays_time = localtime()->strftime('%I:%M%P');
			$announced_time = $time if $server_time != $timestamp;
			$announced_time = $date . ' at ' . $time if $todays_date ne $date;
		}
		$timestamp = $timestamp - $difference;

	}
	return $timestamp;
}

# The device bridge hands back an SMS or call date as the epoch in milliseconds
# (Telephony.Sms.DATE and CallLog.Calls.DATE), while ago_calc reads a span like
# "-3h" and bills a bare number as minutes. Passing a millisecond date straight
# to ago_calc therefore subtracted date*60000 ms from now and put the record
# millions of years in the past - the "3409757y" rows the SMS and call-log
# checks wrote after the app moved off termux-api (whose list returned a
# written date). An absolute epoch passes through; anything else keeps the old
# span reader. A ten-digit value is a seconds stamp, widened to milliseconds.
sub epoch_or_span {
	my ($value, $now) = @_;
	$now = &rightNow() unless $now;
	return undef unless defined $value;
	if ($value =~ /^\s*(\d{10,})\s*$/) {
		my $ms = $1 + 0;
		$ms *= 1000 if $ms < 100000000000;
		return $ms if $ms >= 946684800000;
	}
	return &ago_calc($value, $now);
}

# A warranty belongs to the house, not to the machine that set it. It is stored
# on the 'all' device row (like the language and the theme), so every device
# reads the same value. A per-device row from an older build is still honoured
# as a fallback until the backfill has written the house row.
sub warranty_device { return 'all' }

# A renewal keeps the offset between the chosen warranty and the moment it was
# anchored at, and lands that same offset on every record's own timestamp. The
# value is already resolved to a moment, so a warranty typed in the card is the
# one that applies - not the stored setting.
sub warranty_renewed {
	my ($warranty, $holder, $timestamp) = @_;
	return undef unless defined $warranty && defined $holder && defined $timestamp;
	return $warranty - $holder + $timestamp;
}

# A warranty is a moment ahead of the record. A renewal that resolves behind now
# would expire every record it touches on the next alarm_haircut, so it is not a
# renewal at all and must not be written.
sub warranty_renewal_ok {
	my ($warranty, $now) = @_;
	return 0 unless defined $warranty && length $warranty;
	return ($warranty + 0) > (($now || &rightNow()) + 0) ? 1 : 0;
}

# The voices say_it can speak with. A friendly name carries the engine and what
# that engine needs; the Speech setting in Configure picks one by name, so the
# list here is the single source of truth for both the taker and the picker.
# The piper models live under voices/ (carried as blobs like the APKs, see
# app_release_sync); espeak voices are the fallback when piper is not staged.
# Only cleanly-permissive voices belong here: LJSpeech is public domain,
# LibriTTS-R and Alba are CC BY 4.0. A model dropped from this list is pruned
# from every device by voice_sync, so a licence problem is fixed everywhere.
sub say_voices {
	return (
		{ value => 'piper-ljspeech', label => 'LJSpeech - US female', engine => 'piper', model => 'en_US-ljspeech-medium'   },
		{ value => 'piper-libritts', label => 'LibriTTS-R - US',     engine => 'piper', model => 'en_US-libritts_r-medium'  },
		{ value => 'piper-alba',     label => 'Alba - UK female',    engine => 'piper', model => 'en_GB-alba-medium'        },
		# John is public domain (LibriVox), like LJSpeech.
		{ value => 'piper-john',     label => 'John - US male',      engine => 'piper', model => 'en_US-john-medium'        },
		# Jonathan is this house's own fine-tune: the same public-domain John base,
		# trained on Jonathan's recordings (see .shots/voice_train/ and docs).
		{ value => 'piper-jonathan', label => 'Jonathan - US male',  engine => 'piper', model => 'en_US-jonathan-medium'    },
		{ value => 'espeak-us',      label => 'eSpeak - US',         engine => 'espeak', voice => 'en-us'                    },
		{ value => 'espeak-gb',      label => 'eSpeak - UK',         engine => 'espeak', voice => 'en-gb'                    },
		{ value => 'espeak-nyc',     label => 'eSpeak - NYC',        engine => 'espeak', voice => 'gmw/en-US-nyc'            },
	);
}

sub say_default_voice { return 'piper-ljspeech'; }

1;
