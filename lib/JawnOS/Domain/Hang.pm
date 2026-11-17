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
our $config;
our %m;

# The clothesline is the House's line, not this device's. The rail, the
# anticipatory head and each app's hang live on the House row (`device='all'`),
# so a machine whose clothesline utility is off still reads the line another
# machine hung. Older builds kept a copy per device; those rows are the fallback
# until the House row is written, so an upgrade does not lose the line.
sub clothesline_house_setting {
	my ($app, $setting) = @_;
	my $house = eval { &setting_grabber({ app => $app, setting => $setting, device => 'all' }) };
	return $house if defined $house && length $house;
	return eval { &setting_grabber({ app => $app, setting => $setting }) } || '';
}

# One app's hang as the House keeps it: the `all` row wins, otherwise the newest
# of the per-device copies, so a hang set on the phone is the one the laptop
# reads before either has saved the House row.
sub clothesline_app_setting {
	my ($app) = @_;
	return '' unless defined $app && length $app;
	my $row = eval {
		&db_query(
			"select value from settings where setting = 'clothesline' and app = ? and value is not null"
			. " order by case when device = 'all' then 1 else 0 end desc, cast(server_time as integer) desc limit 1",
			$app
		)->hashes->[0]
	};
	return (defined $row && defined $row->{'value'}) ? $row->{'value'} : '';
}

sub hang_to_dry {
	my %opt = @_;
	my $server_time = &rightNow();
	my $returner = [];
	# The person's own settings for the anticipatory head: on or off, whether the
	# next routine's pills ride along, whether a press recomputes it, and the
	# per-day lists they curated. Read once, used by the head below.
	my $anticipatory = &clothesline_anticipatory_settings();

	# The line is the House's: every app's hang is one row every machine reads,
	# whichever device wrote it. The `all` row wins; otherwise the newest copy,
	# so the phone's hang is on the laptop's line before either saved the House
	# row. A per-device row is the fallback from before the line was shared.
	my $cls = &db_query(
		"select * from settings where setting = 'clothesline' and app != '__president' and value is not null"
		. " order by case when device = 'all' then 1 else 0 end desc, cast(server_time as integer) desc"
	)->hashes;
	# The alphabetical tail is the apps whose own hang is on now. A time slot
	# was picked in the house's words, so the match reads the house clock: the
	# box keeps UTC, and a slot must not open eight o'clock late.
	my @slot = &clothesline_slot_now($server_time);
	# The person's own say over the anticipatory head, and the apps they took off
	# the line altogether, gathered as the rows are read.
	my (%say, %hidden, %renew, %seen_row);

	foreach my $clr ( @{$cls} ) {

		my $cl = eval { return decode_json $clr->{'value'} } || {};
		my $app = &unformat_name($clr->{'app'});
		# one row per app, the House row or the newest copy; the query orders them
		next if $seen_row{$app}++;
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
		&setting_setter({ app => $app, setting => 'clothesline', value => encode_json($renew{$app}), device => 'all' });
	}
	# The anticipatory head: the next steps of the routine under way, in the order
	# the person takes them, whether it begins at eight or at ten. The rest of
	# what belongs on the line follows alphabetically. An app in the head is not
	# repeated in the tail, and a step the routine takes twice is one name in the
	# head - the next time it comes round.
	my $anticipated = [];
	my ($daily, $reused);
	$reused = 0;
	if ($anticipatory->{'on'}) {
		# A press can reuse the head already hung (the person asked that a press
		# not recompute it), so a routine scan only runs when it is wanted.
		if ($opt{'reuse_head'}) {
			my $stored = eval { decode_json &clothesline_house_setting('__president', 'clothesline') } || [];
			$anticipated = [ map { { app => $_->{'app'}, wave => (defined $_->{'wave'} ? $_->{'wave'} : 0) } }
				grep { ref $_ eq 'HASH' && $_->{'head'} && defined $_->{'app'} && length $_->{'app'} } @{$stored} ];
			$reused = @{$anticipated} ? 1 : 0;
		}
		if (!@{$anticipated}) {
			# Every app's days and the order the day runs in. The appointment scan
			# reads only the steps the person starts and stops themselves, so a task
			# or a default option does not teach the line a routine of its own.
			$daily = &clothesline_daily_hours();
			my $anticipation = &clothesline_sequence_anticipate($daily, $server_time, limit => 40,
				next_wave => ($anticipatory->{'next_wave'} ? 1 : 0));
			$anticipated = $anticipation->{'list'} || [];
			# The anticipate step already sets a running step at the place the
			# routine usually stops it. Only a session the sequence does not name at
			# all - one started out of its order, or off its day - is put at the head
			# here, so a running app never falls off the line.
			my $running = ($daily->{'current'} && $daily->{'current'}{'running'}) ? $daily->{'current'}{'running'} : undef;
			if (defined $running && length $running && !grep { $_->{'app'} eq $running } @{$anticipated}) {
				unshift @{$anticipated}, { app => $running, wave => ($anticipation->{'current_wave'} || 0) };
			}
		}
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
	if ($anticipatory->{'on'}) {
		# The person's own say over the head: an app they excluded leaves it, and
		# one they included joins the front even when the routine has not learned it.
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
		# The day's own list wins when the person curated this day in the
		# anticipatory settings: it is those pills, in their order, but the head
		# still advances through them. The same sequence call subtracts a step
		# already taken, keeps the wave limit, and leaves a hand-added pill in
		# place, so a planned day does not freeze while the person takes it. A
		# press told to reuse the head keeps the list already hung.
		my ($today) = &clothesline_house_day($server_time);
		my $day = $anticipatory->{'days'}{$today};
		my ($day_apps, $day_sections) = (undef, {});
		if (ref $day eq 'ARRAY') { $day_apps = $day; }
		elsif (ref $day eq 'HASH' && ref $day->{'apps'} eq 'ARRAY') {
			$day_apps = $day->{'apps'};
			$day_sections = $day->{'sections'} if ref $day->{'sections'} eq 'HASH';
		}
		if ($day_apps && !$reused && $daily) {
			my (@apps, @waves, @keep);
			my %once;
			foreach my $app ( @{$day_apps} ) {
				next unless defined $app && length $app;
				next if $once{$app}++;
				next if $hidden{$app} || &app_hidden_now($app);
				# the routine the person put it in is where the rail draws its own
				# divider, so a curated day keeps the sections it was written in
				my $section = $day_sections->{$app};
				my $wave = (defined $section && $section =~ /^w(\d+)$/) ? (0 + $1) : 0;
				push @keep, $app if defined $section && $section eq 'more';
				push @apps, $app;
				push @waves, $wave;
			}
			my $curated = &clothesline_sequence_anticipate($daily, $server_time,
				limit => 40,
				sequence => \@apps,
				waves => \@waves,
				keep => \@keep,
				force_due => 1,
				next_wave => ($anticipatory->{'next_wave'} ? 1 : 0));
			my $curated_list = $curated->{'list'} || [];
			# A step started again after the routine had already taken it is
			# subtracted as done and has no occurrence left in the curated list;
			# put the running step at the head anyway, where the routine usually
			# stops it, so the pill in hand is never left in the tail.
			my $curated_running = ($daily->{'current'} && $daily->{'current'}{'running'}) ? $daily->{'current'}{'running'} : undef;
			if (defined $curated_running && length $curated_running && !grep { $_->{'app'} eq $curated_running } @{$curated_list}) {
				unshift @{$curated_list}, { app => $curated_running, wave => ($curated->{'current_wave'} || 0) };
			}
			my @manual;
			foreach my $row ( @{$curated_list} ) {
				my $app = $row->{'app'};
				next unless defined $app && length $app;
				my $item = $have{$app};
				unless ($item) {
					my $aset = &settings_grabber({ app => $app });
					$item = { name => $app, app => $app, formatted_name => &format_name($app), colour => $aset->{'colour'}, dark_colour => $aset->{'dark_colour'} };
				}
				$item->{'wave'} = $row->{'wave'};
				push @manual, $item;
			}
			@head = @manual;
		}
	}
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
	# The rail is a cache of the line and belongs to the House too, so a device
	# whose clothesline utility is off still reads the line another machine hung.
	# Skip an identical write: this runs every five minutes and a changed stamp
	# would be nothing but churn.
	my $previous = eval { &setting_grabber({ app => '__president', setting => 'clothesline', device => 'all' }) };
	unless (defined $previous && $previous eq $jreturner) {
		&setting_setter({ app => '__president', setting => 'clothesline', value => $jreturner, device => 'all' });
	}
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
	# a phrase the house read is a registration of its own, so a running app that
	# hangs by its words keeps its pill outside the hours the phrase names
	foreach my $rule ( @{ &clothesline_schedule_list($cl) } ) {
		next unless ref $rule eq 'HASH' && ref $rule->{'days'} eq 'HASH';
		return 1 if scalar keys %{ $rule->{'days'} };
	}
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

# ---- the anticipatory settings ---------------------------------------------
# The context menu's Settings dialog owns the head: whether it shows at all,
# whether the next routine rides along, whether a press recomputes it, and the
# per-day lists the person curated for this week. Every switch defaults on, so
# an install that never opened the dialog behaves exactly as it did.
sub clothesline_anticipatory_settings {
	# The head's switches and curated days are the House's: every machine reads
	# the same row, so a day planned on the phone is the day the laptop leads
	# with, and a machine whose clothesline utility is off still reads it.
	my $house = eval { &setting_grabber({ app => '__president', setting => 'clothesline_anticipatory', device => 'all' }) };
	my $s;
	if (defined $house && $house =~ /\S/) {
		$s = eval { decode_json $house } || {};
	}
	else {
		# Upgrade: the copies older builds kept per device are merged once into
		# the House row - the switches from the newest copy, and every day from
		# the newest copy that has it, so no curated day is lost.
		my $rows = eval { &db_query("select value, server_time from settings where setting = 'clothesline_anticipatory' and value is not null")->hashes } || [];
		my @parsed;
		foreach my $r ( @{$rows} ) {
			my $v = eval { decode_json $r->{'value'} } || {};
			next unless ref $v eq 'HASH';
			push @parsed, [ (0 + ($r->{'server_time'} || 0)), $v ];
		}
		@parsed = sort { $b->[0] <=> $a->[0] } @parsed;
		$s = {};
		if (@parsed) {
			my $newest = $parsed[0][1];
			foreach my $key ( qw/on next_wave on_reset/ ) {
				$s->{$key} = $newest->{$key} if defined $newest->{$key};
			}
			my %days;
			foreach my $p ( @parsed ) {
				my $d = $p->[1]{'days'};
				next unless ref $d eq 'HASH';
				foreach my $date ( keys %{$d} ) {
					next if exists $days{$date};
					$days{$date} = $d->{$date};
				}
			}
			$s->{'days'} = \%days;
			&setting_setter({ app => '__president', setting => 'clothesline_anticipatory', value => encode_json($s), device => 'all' });
		}
	}
	$s = {} unless ref $s eq 'HASH';
	foreach my $key ( qw/on next_wave on_reset/ ) { $s->{$key} = 1 unless defined $s->{$key}; }
	$s->{'days'} = {} unless ref $s->{'days'} eq 'HASH';
	return $s;
}

sub clothesline_anticipatory_save {
	my ($payload) = @_;
	return 0 unless ref $payload eq 'HASH';
	my $s = &clothesline_anticipatory_settings();
	foreach my $key ( qw/on next_wave on_reset/ ) {
		$s->{$key} = $payload->{$key} ? 1 : 0 if exists $payload->{$key};
	}
	if (ref $payload->{'days'} eq 'HASH') {
		foreach my $date ( keys %{ $payload->{'days'} } ) {
			next unless $date =~ /^\d{4}-\d{2}-\d{2}$/;
			my $day = $payload->{'days'}{$date};
			if (!defined $day) { delete $s->{'days'}{$date}; next; }
			# A day is its pills in order; a pill the person put in a routine
			# outright also keeps that routine, which is what the dialog's section
			# picker stores. The older shape (a plain list) is still read.
			my ($list, $sections) = (undef, {});
			if (ref $day eq 'ARRAY') { $list = $day; }
			elsif (ref $day eq 'HASH' && ref $day->{'apps'} eq 'ARRAY') {
				$list = $day->{'apps'};
				$sections = $day->{'sections'} if ref $day->{'sections'} eq 'HASH';
			}
			next unless ref $list eq 'ARRAY';
			my %seen;
			my @keep = grep { defined $_ && length $_ && !$seen{$_}++ } map { "$_" } @{$list};
			my %kept;
			foreach my $app ( @keep ) {
				my $key = $sections->{$app};
				$kept{$app} = "$key" if defined $key && $key =~ /^(?:w\d+|more)$/;
			}
			$s->{'days'}{$date} = %kept ? { apps => \@keep, sections => \%kept } : \@keep;
		}
	}
	&setting_setter({ app => '__president', setting => 'clothesline_anticipatory', value => encode_json($s), device => 'all' });
	return 1;
}

# The apps the dialog may put in a day: every app the appointment log knows,
# under its printed name, minus the ones the rail already keeps off the desk.
sub clothesline_anticipatory_apps {
	my $rows = eval { &db_query("select distinct app from appointments where app is not null and app != '' order by app")->hashes } || [];
	my %seen;
	my @apps;
	foreach my $r ( @{$rows} ) {
		my $app = $r->{'app'};
		next unless defined $app && length $app;
		next if $seen{$app}++;
		next if eval { &clothesline_app_off_line($app) };
		push @apps, { app => $app, name => &format_name($app) };
	}
	# an app with a clothesline setting but no appointment yet is still a pill
	my $clothes = eval { &db_query("select distinct app from settings where setting = 'clothesline' and app != ? and value is not null", '__president')->hashes } || [];
	foreach my $r ( @{$clothes} ) {
		my $app = &unformat_name($r->{'app'});
		next unless length $app && !$seen{$app}++;
		next if eval { &clothesline_app_off_line($app) };
		push @apps, { app => $app, name => &format_name($app) };
	}
	@apps = sort { lc($a->{'name'}) cmp lc($b->{'name'}) || $a->{'app'} cmp $b->{'app'} } @apps;
	return \@apps;
}

# The current week, Monday first: the learned head for each day, and the
# person's own list where they curated one. The dialog walks these. A day is
# shown as the waves the routine keeps - the morning, the midday, the
# afternoon, the evening - so the whole day is there to curate, not only the
# wave the head happens to be on now.
sub clothesline_anticipatory_week {
	my ($now) = @_;
	$now = &rightNow() unless defined $now;
	my $s = &clothesline_anticipatory_settings();
	my $restore = &clock_zone_adopt(&clock_zone_house());
	my @lt = localtime(int($now / 1000));
	my $today = &day_key($now);
	my $start = timelocal(0, 0, 0, $lt[3], $lt[4], $lt[5]) * 1000;
	my $monday = $start - ((($lt[6] + 6) % 7) * 86400 * 1000);
	# The near two months are read once for the whole week: a scan a day would
	# read the same history seven times, and that read was the dialog's wait.
	my $history = [ &clothesline_place_history($now) ];
	my @week;
	for my $i ( 0 .. 6 ) {
		my $day_ms = &calendar_shift($monday, $i, 'day');
		my @d = localtime(int($day_ms / 1000));
		my $morning = timelocal(0, 0, 9, $d[3], $d[4], $d[5]) * 1000;
		my $key = &day_key($morning);
		my $daily = &clothesline_daily_hours($morning, history => $history);
		# The whole day, not the head: every routine the day keeps, and every habit
		# the one day the routine was read from happened to leave out.
		my $ant = &clothesline_sequence_anticipate($daily, $morning, limit => 400, all_waves => 1);
		my @rows = @{ &clothesline_anticipatory_habits(
			[ grep { ref $_ eq 'HASH' && defined $_->{'app'} && length $_->{'app'} } @{ $ant->{'list'} || [] } ],
			$daily) };
		my @learned = map { $_->{'app'} } @rows;
		# A day the person curated is its own pills in their order, each in the
		# routine they put it in; the older shape (a plain list) still reads.
		my $day_value = $s->{'days'}{$key};
		my ($override, $sections) = (undef, {});
		if (ref $day_value eq 'ARRAY') { $override = $day_value; }
		elsif (ref $day_value eq 'HASH' && ref $day_value->{'apps'} eq 'ARRAY') {
			$override = $day_value->{'apps'};
			$sections = $day_value->{'sections'} if ref $day_value->{'sections'} eq 'HASH';
		}
		# a day curated before the house kept an app private must not carry it now
		my @apps = grep { defined $_ && length $_ && !&clothesline_app_off_line($_) } ($override ? @{$override} : @learned);
		push @week, {
			key => $key,
			label => POSIX::strftime('%A, %B %d', @d),
			today => ($key eq $today ? 1 : 0),
			learned => \@learned,
			apps => \@apps,
			phases => &clothesline_anticipatory_phases(\@apps, \@rows, $daily, $sections),
			learned_phases => &clothesline_anticipatory_phases(\@learned, \@rows, $daily),
			override => ($override ? 1 : 0),
		};
	}
	$restore->() if $restore;
	return \@week;
}

# A day's pills grouped into the routines it runs, so the settings dialog can
# show the morning, the midday, the afternoon and the evening as their own
# sections. The section a pill sits in is the one the person put it in, else the
# one the routine learned it in, else the day's own last section - so a curated
# day never loses a pill. The sections are ordered by the time of day their
# pills usually happen, not by where the pauses happened to fall.
sub clothesline_anticipatory_phases {
	my ($list, $rows, $scan, $sections) = @_;
	$list = [] unless ref $list eq 'ARRAY';
	$rows = [] unless ref $rows eq 'ARRAY';
	$sections = {} unless ref $sections eq 'HASH';
	my $apps = (ref $scan eq 'HASH' && ref $scan->{'apps'} eq 'HASH') ? $scan->{'apps'} : {};
	my %wave_of;
	for my $r ( @{$rows} ) {
		next unless ref $r eq 'HASH' && defined $r->{'app'} && length $r->{'app'};
		$wave_of{$r->{'app'}} = $r->{'wave'} || 0 unless defined $wave_of{$r->{'app'}};
	}
	my (@phases, %slot);
	for my $app ( @{$list} ) {
		next unless defined $app && length $app;
		my $key = $sections->{$app};
		$key = (defined $wave_of{$app} ? 'w' . $wave_of{$app} : 'more')
			unless defined $key && length $key;
		unless ($slot{$key}) {
			$slot{$key} = { key => $key, wave => ($key =~ /^w(\d+)$/ ? (0 + $1) : 99), apps => [], hours => [] };
			push @phases, $slot{$key};
		}
		push @{$slot{$key}{'apps'}}, $app;
		my $row = $apps->{$app};
		my $hour = ref $row eq 'HASH' ? $row->{'hour'} : undef;
		push @{$slot{$key}{'hours'}}, (0 + $hour) if defined $hour && $hour =~ /^\d+$/;
	}
	# The routine's hour is the hour most of its pills happen, not the first
	# one's: a single 2am step must not name a morning routine the night. A tie
	# goes to the earlier hour.
	for my $phase ( @phases ) {
		my %count;
		$count{$_}++ for @{$phase->{'hours'}};
		my $best = -1;
		foreach my $hour ( sort { $a <=> $b } keys %count ) {
			if ($count{$hour} > $best) { ($phase->{'hour'}, $best) = (0 + $hour, $count{$hour}); }
		}
		$phase->{'label'} = $phase->{'key'} eq 'more' ? 'Added' : &clothesline_anticipatory_wave_name($phase->{'hour'});
	}
	# the day runs from the morning into the small hours, so one in the morning
	# sorts after eleven at night rather than before the day it ends
	my $clock = sub {
		my $hour = shift;
		return 99 unless defined $hour;
		return $hour < 5 ? $hour + 24 : $hour;
	};
	return [ sort {
		$clock->($a->{'hour'}) <=> $clock->($b->{'hour'})
			|| $a->{'wave'} <=> $b->{'wave'}
			|| $a->{'key'} cmp $b->{'key'}
	} @phases ];
}

# The habits one day's shape leaves out. The routine is read from the one day
# most like the others, so a step that happens most days but not on that day is
# invisible - the yogurt at noon the chosen day happened to miss. A habit is a
# step the person starts and stops themselves, due today, and seen on five of
# the last fourteen days - most days, not every other week. It is placed by its
# own hour, in the routine of the step it falls before, so the day still reads
# in its own order.
sub clothesline_anticipatory_habits {
	my ($rows, $scan) = @_;
	$rows = [] unless ref $rows eq 'ARRAY';
	my $apps = (ref $scan eq 'HASH' && ref $scan->{'apps'} eq 'HASH') ? $scan->{'apps'} : {};
	my %have = map { $_->{'app'} => 1 } grep { ref $_ eq 'HASH' && defined $_->{'app'} } @{$rows};
	my @add;
	foreach my $app ( sort keys %{$apps} ) {
		next if $have{$app};
		my $row = $apps->{$app};
		next unless ref $row eq 'HASH';
		next unless $row->{'due'};
		next unless defined $row->{'hour'} && $row->{'hour'} =~ /^\d+$/;
		next unless ($row->{'recent_days'} || 0) >= 5;
		# the line is a public surface: a private app and a caller's number are not
		# habits, however often they happen
		next if &clothesline_app_off_line($app);
		push @add, { app => $app, hour => (0 + $row->{'hour'}) };
	}
	return [ @{$rows} ] unless @add;
	my @out = @{$rows};
	foreach my $new ( sort { $a->{'hour'} <=> $b->{'hour'} || $a->{'app'} cmp $b->{'app'} } @add ) {
		# The step it happens beside, not the next one down the order: the day's
		# order can wander (a 2am step at its end), so a noon habit placed by the
		# first later hour landed in the evening. The nearest hour is the routine
		# it belongs to.
		my ($at, $best) = (scalar @out, undef);
		for my $i ( 0 .. $#out ) {
			my $row = $apps->{ $out[$i]{'app'} };
			my $hour = ref $row eq 'HASH' ? $row->{'hour'} : undef;
			next unless defined $hour && $hour =~ /^\d+$/;
			my $gap = abs((0 + $hour) - $new->{'hour'});
			# an equal gap goes to the routine the day reaches first, and the wave
			# number is that order
			my $wave = $out[$i]{'wave'} || 0;
			my $kept = ($at < scalar @out) ? ($out[$at]{'wave'} || 0) : 99;
			if (!defined $best || $gap < $best || ($gap == $best && $wave < $kept)) {
				($at, $best) = ($i, $gap);
			}
		}
		# A habit in the hour before another routine is that routine's run-up: the
		# eleven o'clock yogurt belongs with the noon lunch, not with the ten
		# o'clock steps it is numerically nearest. Between two routines, the one it
		# leads into wins.
		my $runup;
		for my $i ( 0 .. $#out ) {
			my $row = $apps->{ $out[$i]{'app'} };
			my $hour = ref $row eq 'HASH' ? $row->{'hour'} : undef;
			next unless defined $hour && $hour =~ /^\d+$/;
			next unless (0 + $hour) > $new->{'hour'} && ((0 + $hour) - $new->{'hour'}) <= 1;
			my $wave = $out[$i]{'wave'} || 0;
			my $key = [ (0 + $hour) - $new->{'hour'}, $wave, $i ];
			$runup = [ $key, $i ] if !$runup || ($key->[0] <=> $runup->[0][0]) < 0
				|| (($key->[0] <=> $runup->[0][0]) == 0 && (($key->[1] <=> $runup->[0][1]) < 0
					|| (($key->[1] <=> $runup->[0][1]) == 0 && ($key->[2] <=> $runup->[0][2]) < 0)));
		}
		$at = $runup->[1] if $runup;
		# a habit earlier than the step it sits beside goes before it
		my $wave = 0;
		if (@out) {
			my $row = $apps->{ $out[$at]{'app'} };
			my $hour = ref $row eq 'HASH' ? $row->{'hour'} : undef;
			$at++ if defined $hour && $hour =~ /^\d+$/ && (0 + $hour) < $new->{'hour'};
			$wave = $out[ $at < scalar @out ? $at : scalar @out - 1 ]{'wave'} || 0;
		}
		splice @out, $at, 0, { app => $new->{'app'}, wave => $wave };
	}
	return \@out;
}

# The word a wave is called by, from the hour its first step usually happens.
# English here, so a test can name it; the dialog translates it.
sub clothesline_anticipatory_wave_name {
	my ($hour) = @_;
	return 'Routine' unless defined $hour && $hour =~ /^\d+$/;
	return 'Morning' if $hour >= 5 && $hour < 11;
	return 'Midday' if $hour >= 11 && $hour < 14;
	return 'Afternoon' if $hour >= 14 && $hour < 17;
	return 'Evening' if $hour >= 17 && $hour < 22;
	return 'Night';
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

# The house day, hour and minute a moment falls on. The box keeps UTC, so the rail
# reads the person's own clock, matching the time slots it already matches against.
sub clothesline_house_day {
	my ($now) = @_;
	$now = &rightNow() unless defined $now;
	my $restore = &clock_zone_adopt(&clock_zone_house());
	my $key = &day_key($now);
	my @t = localtime(int($now / 1000));
	$restore->() if $restore;
	return ($key, defined $t[2] ? $t[2] + 0 : 0, defined $t[1] ? $t[1] + 0 : 0);
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
	# a model that answers a span with its two ends ("9am to 12pm" -> 9 and 12)
	# means the hours between them; the end hour is the boundary, not covered
	@hours = ( $hours[0] .. $hours[1] - 1 ) if scalar(@hours) == 2 && $hours[1] - $hours[0] > 1;
	my @mraw = ();
	if (ref $plan->{'minutes'} eq 'ARRAY') { @mraw = @{ $plan->{'minutes'} }; }
	my %mseen;
	my @minutes = sort { $a <=> $b } grep { defined $_ && $_ =~ /^\s*\d+\s*$/ && $_ >= 0 && $_ <= 59 && !$mseen{$_ + 0}++ } @mraw;
	# a model that lists every minute is saying the whole hour, not a minute range
	@minutes = () if scalar(@minutes) == 60 && $minutes[0] == 0 && $minutes[-1] == 59;
	$restore->() if $restore;
	return { days => \%days, hours => \@hours, minutes => \@minutes, ask => ($ask || '') };
}

# The app's schedules, newest shape first. An app scheduled before a phrase could
# hold more than one is one schedule, read where it stands.
sub clothesline_schedule_list {
	my ($cl) = @_;
	return [] unless ref $cl eq 'HASH';
	return $cl->{'schedules'} if ref $cl->{'schedules'} eq 'ARRAY';
	return [ $cl->{'schedule_rule'} ] if ref $cl->{'schedule_rule'} eq 'HASH';
	return [];
}

# Does any of the app's phrases wear at this moment? A schedule's day must be one
# it names, and its hour and minute (when it named any) must be among them.
sub clothesline_schedule_wears {
	my ($cl, $now) = @_;
	my $list = &clothesline_schedule_list($cl);
	return 0 unless @{$list};
	my ($day, $hour, $minute) = &clothesline_house_day($now);
	foreach my $rule ( @{$list} ) {
		next unless ref $rule eq 'HASH';
		my $days = ref $rule->{'days'} eq 'HASH' ? $rule->{'days'} : {};
		next unless scalar keys %{$days} && $days->{$day};
		my @hours = @{ ref $rule->{'hours'} eq 'ARRAY' ? $rule->{'hours'} : [] };
		next if @hours && !grep { $_ =~ /^\d+$/ && $_ == $hour } @hours;
		my @minutes = @{ ref $rule->{'minutes'} eq 'ARRAY' ? $rule->{'minutes'} : [] };
		next if @minutes && !grep { $_ =~ /^\d+$/ && $_ == $minute } @minutes;
		return 1;
	}
	return 0;
}

# A phrase's days are a window: once its last day has passed, the plan is read
# again from today. A bounded plan (an explicit until) yields no days after its
# end and is left to expire, which is what the person asked for.
sub clothesline_schedule_renew {
	my ($cl, $now) = @_;
	my $list = &clothesline_schedule_list($cl);
	return 0 unless @{$list};
	my ($today) = &clothesline_house_day($now);
	my $changed = 0;
	foreach my $rule ( @{$list} ) {
		next unless ref $rule eq 'HASH' && ref $rule->{'plan'} eq 'HASH';
		my $days = ref $rule->{'days'} eq 'HASH' ? $rule->{'days'} : {};
		next unless scalar keys %{$days};
		my @keys = sort keys %{$days};
		next if $keys[-1] ge $today;
		my $fresh = &clothesline_schedule_expand($rule->{'plan'}, $now);
		next unless scalar keys %{ $fresh->{'days'} };
		$rule->{'days'} = $fresh->{'days'};
		$rule->{'refreshed'} = $now;
		$changed = 1;
	}
	return $changed;
}

# ---- reading a phrase without a model --------------------------------------
# The words name the recurrence, the part of the day and the horizon; the house's
# own recurrence plans carry the dates. The app's appointment history is never
# consulted, so a new app can be scheduled the first time it is asked. The Guide
# is asked only when a clause names nothing this reader knows.

my %clothesline_weekday_number = (
	sunday => 0, sun => 0, monday => 1, mon => 1, tuesday => 2, tue => 2, tues => 2,
	wednesday => 3, wed => 3, thursday => 4, thu => 4, thur => 4, thurs => 4,
	friday => 5, fri => 5, saturday => 6, sat => 6,
);
my @clothesline_weekday_short = qw(sun mon tue wed thu fri sat);
my @clothesline_month_name = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
my %clothesline_month = (
	jan => 1, january => 1, feb => 2, february => 2, mar => 3, march => 3,
	apr => 4, april => 4, may => 5, jun => 6, june => 6, jul => 7, july => 7,
	aug => 8, august => 8, sep => 9, sept => 9, september => 9, oct => 10,
	october => 10, nov => 11, november => 11, dec => 12, december => 12,
);
my $clothesline_month_re = join '|', sort { length $b <=> length $a } keys %clothesline_month;
# The words a clause may leave behind and still be understood. Anything else - a
# foreign word, or one the reader has never met - sends the whole phrase to the
# Guide, which is the path that can read any language.
my %clothesline_stop_word = map { $_ => 1 } qw(
	the and or as well on at in of for from to until through every each my our me
	house whole all day days time times around about between first second half
	hour hours minute minutes a an is it this that then when while during plus
);

# The hours a named part of the day covers. `night` wraps midnight, so it is a
# set, not a range. `dinner` and `supper` are the house's early evening.
sub clothesline_day_part {
	my $name = lc(shift // '');
	$name =~ s/\s*(?:time|hours?)\s*$//;
	my %part = (
		morning   => [ 6 .. 11 ],
		afternoon => [ 12 .. 16 ],
		evening   => [ 17 .. 20 ],
		dinner    => [ 17 .. 19 ],
		supper    => [ 17 .. 19 ],
		lunch     => [ 12, 13 ],
		breakfast => [ 7, 8, 9 ],
		noon      => [ 12 ],
		midnight  => [ 0 ],
		night     => [ 0 .. 4, 21 .. 23 ],
	);
	return $part{$name};
}

# The fixed dates the reader knows by name: lower-case name => [month, day].
sub clothesline_named_days {
	return {
		'christmas' => [12,25], 'christmas day' => [12,25],
		'boxing day' => [12,26],
		'valentines' => [2,14], 'valentines day' => [2,14], "valentine's day" => [2,14],
		'new years' => [1,1], 'new years day' => [1,1],
		'halloween' => [10,31],
		'canada day' => [7,1],
		'independence day' => [7,4],
		'remembrance day' => [11,11],
		'groundhog day' => [2,2],
		'april fools' => [4,1], 'april fools day' => [4,1],
		'st patricks day' => [3,17],
	};
}

# The house's own birthday, as [month, day].
sub clothesline_house_birthday {
	my ($now) = @_;
	$now = &rightNow() unless defined $now;
	my $born = eval { $config->{'birthday'} };
	return undef unless defined $born && $born =~ /\S/;
	# the config keeps a written date ("Jan. 1 2000 12pm"); its month and day
	# are all a yearly schedule needs
	if ($born =~ /($clothesline_month_re)\.?\s+(\d{1,2})(?:st|nd|rd|th)?/i) {
		my $m = $clothesline_month{lc $1};
		return [ $m, $2 + 0 ] if $m && $2 >= 1 && $2 <= 31;
	}
	my $ms = &resolve_when($born, $now);
	return undef unless defined $ms;
	my @t = localtime(int($ms / 1000));
	return [ $t[4] + 1, $t[3] ];
}

# '4pm', '16:30' or '9' as (hour, minute). A bare number is the 24-hour clock.
sub clothesline_clock {
	my $text = lc(shift // '');
	if ($text =~ /(\d{1,2})\s*:\s*(\d{2})\s*(am|pm)?/) {
		my ($h, $m, $ap) = ($1 + 0, $2 + 0, $3);
		$h += 12 if defined $ap && $ap eq 'pm' && $h < 12;
		$h = 0 if defined $ap && $ap eq 'am' && $h == 12;
		return ($h, $m) if $h <= 23 && $m <= 59;
	}
	if ($text =~ /(\d{1,2})\s*(am|pm)/) {
		my ($h, $ap) = ($1 + 0, $2);
		$h = 0 if $ap eq 'am' && $h == 12;
		$h += 12 if $ap eq 'pm' && $h < 12;
		return ($h, 0) if $h <= 23;
	}
	if ($text =~ /^\s*(\d{1,2})\s*$/) {
		my $h = $1 + 0;
		return ($h, 0) if $h <= 23;
	}
	return;
}

# Take the part of the day out of a clause. Returns the hours, the minutes, the
# clause without them, whether any were named, and whether it said "all day".
sub clothesline_take_time {
	my ($text) = @_;
	my (@hours, @minutes);
	my $found = 0;
	my $all_day = 0;
	if ($text =~ s/\b(?:all|the\s+whole|whole)\s+day\b//) { $found = 1; $all_day = 1; }
	my $part = qr/morning|afternoon|evening|night|dinner(?:\s*time)?|supper(?:\s*time)?|lunch(?:\s*time)?|breakfast|noon|midnight/;
	my $time = qr/[0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm)?/;
	my ($h1, $m1, $h2, $m2);
	if ($text =~ /\b(?:between|from)\s+($time)\s*(?:and|to|until|-|–)\s*($time)\b/) {
		my ($a, $b) = ($1, $2);
		($h1, $m1) = &clothesline_clock($a);
		($h2, $m2) = &clothesline_clock($b);
		$text =~ s/\b(?:between|from)\s+\Q$a\E\s*(?:and|to|until|-|–)\s*\Q$b\E\b//;
	}
	elsif ($text =~ /\b($time)\s*(?:to|until|-|–)\s*($time)\b/) {
		my ($a, $b) = ($1, $2);
		($h1, $m1) = &clothesline_clock($a);
		($h2, $m2) = &clothesline_clock($b);
		$text =~ s/\b\Q$a\E\s*(?:to|until|-|–)\s*\Q$b\E\b//;
	}
	if (defined $h1 && defined $h2) {
		$h1 += 12 if $h1 < 12 && $h2 >= 12 && $text !~ /\bam\b/i;
		if ($h2 > $h1) { @hours = ($m2 ? ($h1 .. $h2) : ($h1 .. $h2 - 1)); }
		elsif ($h2 < $h1) { @hours = ($h1 .. 23, 0 .. ($m2 ? $h2 : $h2 - 1)); }
		else { @hours = ($h1); }
		$found = 1;
	}
	if (!$found && $text =~ s/\b(?:around|about|at|by)\s+($time)\b//) {
		my ($h, $m) = &clothesline_clock($1);
		if (defined $h) { @hours = ($h); $found = 1; }
	}
	if (!$found && $text =~ s/\b(\d{1,2}(?::\d{2})?\s*(?:am|pm))\b//) {
		my $cap = $1;
		my ($h, $m) = &clothesline_clock($cap);
		if (defined $h) { @hours = ($h); $found = 1; }
		else { $text = " $cap $text"; }
	}
	if (!$found && $text =~ s/\b(?:in|during|around|about|at|on)?\s*(?:the\s+)?($part)s?\b//) {
		my $span = &clothesline_day_part($1);
		if ($span) { @hours = @{$span}; $found = 1; }
	}
	if ($text =~ s/\b(?:for\s+)?(?:the\s+)?first\s+half(?:\s*(?:of\s+)?(?:the\s+)?hour)?\b//) { @minutes = (0 .. 29); $found = 1; }
	elsif ($text =~ s/\b(?:for\s+)?(?:the\s+)?second\s+half(?:\s*(?:of\s+)?(?:the\s+)?hour)?\b//) { @minutes = (30 .. 59); $found = 1; }
	elsif ($text =~ s/\b(?:a\s+)?quarter\s+(?:past|after)\b//) { @minutes = (15); $found = 1; }
	elsif ($text =~ s/\bhalf\s+past\b//) { @minutes = (30); $found = 1; }
	elsif ($text =~ s/\b(?:for\s+)?(?:the\s+)?first\s+(\d{1,2})\s+minutes?\b//) { my $n = $1 + 0; $n = 59 if $n > 59; @minutes = (0 .. $n - 1); $found = 1; }
	return (\@hours, \@minutes, $text, $found, $all_day);
}

# 'until July 24 2027', 'through June', 'for the next 6 weeks'.
sub clothesline_take_horizon {
	my ($text, $now) = @_;
	my $until;
	if ($text =~ s/\b(?:until|through|till|til|ending(?:\s+on)?)\s+(.+?)\s*$//) {
		my $when = $1;
		$until = &resolve_when($when, $now);
		if (!defined $until && $when =~ /($clothesline_month_re)\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})/i) {
			$until = timelocal(0, 0, 12, $2 + 0, $clothesline_month{lc $1} - 1, $3 - 1900) * 1000;
		}
	}
	elsif ($text =~ s/\bfor\s+the\s+next\s+(\d{1,3})\s+(day|week|month|year)s?\b//) {
		$until = &calendar_shift($now, $1 + 0, $2);
	}
	return ($until, $text);
}

# Take the recurrence out of a clause: [plans], the clause without it, and
# whether a recurrence was named.
sub clothesline_take_days {
	my ($text, $now) = @_;
	my @plans;
	my $found = 0;
	if ($text =~ s/\b(?:every|each)\s+single\s+day\b// || $text =~ s/\b(?:every\s+day|each\s+day|daily)\b//) {
		push @plans, { kind => 'interval', interval => '1d' };
		$found = 1;
	}
	if ($text =~ s/\bevery\s+other\s+(day|week|month)\b//) {
		my $unit = $1 eq 'day' ? 'd' : $1 eq 'week' ? 'w' : 'M';
		push @plans, { kind => 'interval', interval => "2$unit" };
		$found = 1;
	}
	elsif ($text =~ s/\bevery\s+(\d+)\s+(day|week|month|year)s?\b//) {
		my ($n, $u) = ($1, $2);
		my $unit = $u eq 'day' ? 'd' : $u eq 'week' ? 'w' : $u eq 'month' ? 'M' : 'y';
		push @plans, { kind => 'interval', interval => "$n$unit" };
		$found = 1;
	}
	if ($text =~ s/\b(?:every\s+)?weekdays?\b//) {
		push @plans, { kind => 'weekdays', weekdays => [qw(mon tue wed thu fri)] };
		$found = 1;
	}
	if ($text =~ s/\b(?:every\s+)?weekends?\b//) {
		push @plans, { kind => 'weekdays', weekdays => [qw(sat sun)] };
		$found = 1;
	}
	if ($text =~ s/\b(?:the\s+|each\s+|every\s+)?(first|second|third|fourth|fifth|last)\s+(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\s*(?:of\s+(?:the\s+|each\s+|every\s+)?month|each\s+month|every\s+month)\b//) {
		my %nth = (first => 1, second => 2, third => 3, fourth => 4, fifth => 5, last => -1);
		my $w = $clothesline_weekday_number{$2};
		push @plans, { kind => 'monthly_nth_weekday', nth => $nth{$1}, weekday => $clothesline_weekday_short[$w] } if defined $w;
		$found = 1;
	}
	if ($text =~ s/\b(?:every|each)\s+full\s+moon\b// || $text =~ s/\bfull\s+moon\b//) {
		push @plans, { kind => 'full_moon' };
		$found = 1;
	}
	if ($text =~ s/\b(?:on\s+)?(?:my|the\s+house(?:'s)?)\s+birthday\b//) {
		my $day = &clothesline_house_birthday($now);
		push @plans, { kind => 'annual', month => $day->[0], day => $day->[1] } if $day;
		$found = 1;
	}
	elsif ($text =~ s/\b([a-z][a-z' -]{1,40}?)\s*'s\s+birthday\b//) {
		my $who = $1;
		$who =~ s/^\s*(?:on|for|my)\s+//;
		$who =~ s/^\s+|\s+$//g;
		push @plans, { kind => 'birthday', person => $who } if length $who;
		$found = 1;
	}
	my $named = &clothesline_named_days();
	foreach my $name ( sort { length $b <=> length $a } keys %{$named} ) {
		while ($text =~ s/\b\Q$name\E\b//) {
			push @plans, { kind => 'annual', month => $named->{$name}->[0], day => $named->{$name}->[1] };
			$found = 1;
		}
	}
	if ($text =~ s/\b($clothesline_month_re)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b//i) {
		my ($m, $d) = ($clothesline_month{lc $1}, $2 + 0);
		push @plans, { kind => 'annual', month => $m, day => $d } if $m && $d >= 1 && $d <= 31;
		$found = 1;
	}
	if ($text =~ s/\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?($clothesline_month_re)\b//i) {
		my ($d, $m) = ($1 + 0, $clothesline_month{lc $2});
		push @plans, { kind => 'annual', month => $m, day => $d } if $m && $d >= 1 && $d <= 31;
		$found = 1;
	}
	if ($text =~ /\b(sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tue|tues|wed|thu|thur|thurs|fri|sat)s?\b/i) {
		my @w;
		while ($text =~ s/\b(sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tue|tues|wed|thu|thur|thurs|fri|sat)s?\b//i) {
			my $w = $clothesline_weekday_number{lc $1};
			next unless defined $w;
			my $short = $clothesline_weekday_short[$w];
			push @w, $short unless grep { $_ eq $short } @w;
		}
		if (@w) { push @plans, { kind => 'weekdays', weekdays => \@w }; $found = 1; }
	}
	return (\@plans, $text, $found);
}

# "from 4pm to 6pm", "at 9pm", "all day".
sub clothesline_time_words {
	my ($hours, $minutes) = @_;
	my @h = @{ ref $hours eq 'ARRAY' ? $hours : [] };
	my @m = @{ ref $minutes eq 'ARRAY' ? $minutes : [] };
	@m = () if scalar(@m) == 60 && $m[0] == 0 && $m[-1] == 59;
	return &ui('all day') unless @h;
	return &ui('at') . ' ' . &clothesline_hour_word($h[0]) . ' ' . &ui('minutes') . ' ' . $m[0] . ' ' . &ui('to') . ' ' . $m[-1] if @m;
	if (@h == 1) { return &ui('at') . ' ' . &clothesline_hour_word($h[0]); }
	my $contig = 1;
	for my $i ( 1 .. $#h ) { $contig = 0 if $h[$i] != $h[$i - 1] + 1; }
	if ($contig && $h[-1] < 23) {
		return &ui('from') . ' ' . &clothesline_hour_word($h[0]) . ' ' . &ui('to') . ' ' . &clothesline_hour_word($h[-1] + 1);
	}
	return join(', ', map { &clothesline_hour_word($_) } @h);
}

# The plans in the house's own words, for the editor's card and the summary.
sub clothesline_plan_words {
	my ($plan) = @_;
	$plan = {} unless ref $plan eq 'HASH';
	my $kind = $plan->{'kind'} // '';
	if ($kind eq 'interval' && ($plan->{'interval'} // '') eq '1d') { return &ui('Every day'); }
	if ($kind eq 'interval') { return &ui('Every') . ' ' . ($plan->{'interval'} // '?'); }
	if ($kind eq 'weekdays') {
		my @names = map { ucfirst $_ } @{ $plan->{'weekdays'} || [] };
		return &ui('Every') . ' ' . join(', ', @names);
	}
	if ($kind eq 'monthly_nth_weekday') {
		my %nth = (1 => 'first', 2 => 'second', 3 => 'third', 4 => 'fourth', 5 => 'fifth', -1 => 'last');
		return ucfirst(&ui($nth{$plan->{'nth'} + 0} || 'first')) . ' ' . ucfirst($plan->{'weekday'} // '') . ' ' . &ui('of the month');
	}
	if ($kind eq 'annual') {
		my $m = int($plan->{'month'} || 0);
		my $d = int($plan->{'day'} || 0);
		return &ui('Every') . ' ' . ($clothesline_month_name[$m - 1] || '?') . ' ' . $d if $m >= 1 && $m <= 12 && $d;
	}
	if ($kind eq 'birthday') { return ucfirst($plan->{'person'} // '') . ' ' . &ui('birthday'); }
	if ($kind eq 'full_moon') { return &ui('Every full moon'); }
	if ($kind eq 'dates') { return &ui('On a list of dates'); }
	return &ui('A schedule');
}

sub clothesline_plans_words {
	my ($plan) = @_;
	my $plans = (ref $plan eq 'HASH' && ref $plan->{'plans'} eq 'ARRAY') ? $plan->{'plans'} : [];
	return join('; ', map { &clothesline_plan_words($_) } grep { ref $_ eq 'HASH' } @{$plans});
}

sub clothesline_schedule_say {
	my ($plans, $hours, $minutes) = @_;
	my @bits = map { &clothesline_plan_words($_) } grep { ref $_ eq 'HASH' } @{ $plans || [] };
	my $when = &clothesline_time_words($hours, $minutes);
	return join(', ', @bits) . ($when && $when ne &ui('all day') ? ', ' . $when : '');
}

# One comma-separated clause into a schedule. A clause that names only a time of
# day is a modifier on the one before it.
sub clothesline_schedule_clause {
	my ($clause, $now, $later, $original) = @_;
	my $shown = (defined $original && length $original) ? $original : $clause;
	my $rest = $clause;
	my ($until, $after_horizon) = &clothesline_take_horizon($rest, $now);
	$rest = $after_horizon;
	my ($hours, $minutes, $after_time, $time_found, $all_day) = &clothesline_take_time($rest);
	$rest = $after_time;
	my ($plans, $left, $day_found) = &clothesline_take_days($rest, $now);
	return (undef, 0) if !$day_found && !$time_found;
	# words the reader did not use mean it did not understand the clause: a phrase
	# in another language goes to the Guide whole, not half-read here
	my @leftover = grep { length($_) > 2 && !$clothesline_stop_word{$_} } split /[^a-z']+/, lc($left // '');
	return (undef, 0) if @leftover;
	if (!$day_found) {
		return ({ text => $shown, plans => [], hours => $hours, minutes => $minutes, all_day => $all_day, modifier => 1 }, 1) if $later;
		push @{$plans}, { kind => 'interval', interval => '1d' };
	}
	if (defined $until) {
		foreach my $p ( @{$plans} ) { $p->{'until'} = $until unless defined $p->{'until'}; }
	}
	return ({ text => $shown, plans => $plans, hours => $hours, minutes => $minutes, all_day => $all_day, say => &clothesline_schedule_say($plans, $hours, $minutes) }, 1);
}

# The whole phrase: comma-separated clauses, each its own schedule, with a
# time-only clause merged into the one before it.
sub clothesline_schedule_parse {
	my ($text, %opt) = @_;
	my $now = $opt{'now'} || &rightNow();
	my @raw = grep { /\S/ } map { s/^\s+|\s+$//gr } split /\s*,\s*/, (defined $text ? "$text" : '');
	my @clauses = map { my $c = lc $_; $c =~ s/[\x{2019}]/'/g; $c } @raw;
	return { ask => &ui('Say when this routine should hang.') } unless @clauses;
	my (@schedules, $unread);
	$unread = 0;
	for my $i ( 0 .. $#clauses ) {
		my ($sched, $ok) = &clothesline_schedule_clause($clauses[$i], $now, $i > 0, $raw[$i]);
		if (!$ok) { $unread++; next; }
		if ($sched->{'modifier'}) {
			if (!@schedules) { $unread++; next; }
			my $prev = $schedules[-1];
			if ($sched->{'all_day'}) { $prev->{'hours'} = []; $prev->{'minutes'} = []; }
			else {
				my (%h, %m);
				$h{$_} = 1 for @{ $prev->{'hours'} || [] }, @{ $sched->{'hours'} || [] };
				$m{$_} = 1 for @{ $prev->{'minutes'} || [] }, @{ $sched->{'minutes'} || [] };
				$prev->{'hours'} = [ sort { $a <=> $b } keys %h ];
				$prev->{'minutes'} = [ sort { $a <=> $b } keys %m ];
			}
			$prev->{'say'} = &clothesline_schedule_say($prev->{'plans'}, $prev->{'hours'}, $prev->{'minutes'});
			next;
		}
		push @schedules, $sched;
	}
	return { ask => &ui('I could not read that schedule. Can you say it another way?') } unless @schedules;
	return { schedules => \@schedules, unread => $unread };
}

# The Guide's read, for words the fast reader does not know. It answers with one
# schedule per comma-separated part, each with its own hours and minutes.
sub clothesline_schedule_model_read {
	my ($text, $now, $model) = @_;
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
{"schedules":[{"text":"their words for this part","plans":[ ... ],"hours":[16,17],"minutes":[0,29],"say":"one short sentence"}]}
One schedule for each distinct time of day; a comma-separated list of different times of day is several schedules.
Each plan is one recurrence, in one of these shapes:
{"kind":"weekdays","weekdays":["thu"],"until":"2027-07-24"}
{"kind":"interval","interval":"1d","count":10} or {"kind":"interval","interval":"1M","until":"2027-06-01"}
{"kind":"monthly_nth_weekday","nth":3,"weekday":"sat","count":12}
{"kind":"annual","month":2,"day":14}
{"kind":"birthday","person":"mom"}
{"kind":"full_moon","until":"2036-07-01"}
{"kind":"dates","dates":["2026-11-26","2026-12-24"]}
"hours" are 24-hour clock integers: a span's end hour is the boundary, not covered ("9am to 12pm" is [9,10,11]); "minutes" are 0-59 integers, only for part of an hour ("the first half hour" is 0-29); leave both out for all day.
A time of day NEVER goes in "until". "until" is only the last date the schedule runs, as an absolute date.
"count" is how many repeats. "count" and "until" are the only ways to bound a rule.
Add "exclude_holidays":true for "except on holidays", and "except":["2026-12-25"] for other named days.
Named days: New Year's Day 1/1, Valentine's Day 2/14, Canada Day 7/1, Independence Day 7/4, Halloween 10/31, Remembrance Day 11/11, Christmas Day 12/25, Boxing Day 12/26.
Their saved birthdays: $bday_text.
The phrase may be written in any language. Read it as it is, and write "say" and "ask" in that same language; the JSON keys and the plan values stay as shown.
If the phrase is ambiguous, reply {"ask":"a short question"}.
Do not write prose. Do not invent a date you are unsure of.
TXT
	my ($out, $err) = &evaluation_model_call_role('help_assistant', $system, $text, &ai_role_thinking_effective('help_assistant'));
	return { ask => ($err || &ui('The Guide did not answer that.')) } unless defined $out && $out =~ /\S/;
	# A model writes Perl characters and decode_json wants UTF-8 bytes, so one
	# accent in a French or Spanish sentence made the whole answer unreadable.
	# json_from_model encodes first and also tolerates a code fence or prose.
	my $answer = &json_from_model($out);
	return { ask => &ui('I could not read that schedule. Can you say it another way?') } unless ref $answer eq 'HASH';
	return { ask => $answer->{'ask'} } if defined $answer->{'ask'} && $answer->{'ask'} =~ /\S/;
	my $list = ref $answer->{'schedules'} eq 'ARRAY' ? $answer->{'schedules'} : [];
	if (!@{$list} && ref $answer->{'plans'} eq 'ARRAY') { push @{$list}, $answer; }
	my @out;
	foreach my $s ( @{$list} ) {
		next unless ref $s eq 'HASH';
		my $expanded = &clothesline_schedule_expand({ plans => $s->{'plans'}, hours => $s->{'hours'}, minutes => $s->{'minutes'} }, $now);
		next unless scalar keys %{ $expanded->{'days'} };
		push @out, {
			text => ($s->{'text'} // $text),
			say => ($s->{'say'} // ''),
			days => $expanded->{'days'},
			hours => $expanded->{'hours'},
			minutes => $expanded->{'minutes'},
			plan => { plans => $s->{'plans'}, hours => $expanded->{'hours'}, minutes => $expanded->{'minutes'} },
			made => $now,
		};
	}
	return { ask => &ui('I could not find any days in that schedule. Can you say it another way?') } unless @out;
	return { schedules => \@out };
}

# The editor's phrase: the fast reader first, the Guide only when it must be.
# Nothing here writes; the caller stores the schedules.
sub clothesline_schedule_read {
	my ($text, %opt) = @_;
	$text = defined $text ? "$text" : '';
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return { ask => &ui('Say when this routine should hang.') } unless length $text;
	my $now = $opt{'now'} || &rightNow();
	my $parsed = &clothesline_schedule_parse($text, now => $now);
	my @out;
	my $why = '';
	if (!$parsed->{'ask'} && !$parsed->{'unread'}) {
		foreach my $s ( @{ $parsed->{'schedules'} || [] } ) {
			my $expanded = &clothesline_schedule_expand({ plans => $s->{'plans'}, hours => $s->{'hours'}, minutes => $s->{'minutes'} }, $now);
			if (!scalar keys %{ $expanded->{'days'} }) { $why = $expanded->{'ask'} if !length $why; next; }
			push @out, {
				text => $s->{'text'},
				say => ($s->{'say'} || ''),
				days => $expanded->{'days'},
				hours => $expanded->{'hours'},
				minutes => $expanded->{'minutes'},
				plan => { plans => $s->{'plans'}, hours => $expanded->{'hours'}, minutes => $expanded->{'minutes'} },
				made => $now,
			};
		}
		return { schedules => \@out } if @out;
		# a phrase the reader knew but could not carry out (an unsaved birthday,
		# say) is answered by the reader, not handed to a model that cannot know
		return { ask => $why } if length $why;
	}
	my $model = $opt{'model'} || &setting_grabber({ app => 'mail', setting => 'help_assistant' });
	return { ask => &ui('A schedule written in words needs the Guide model, and none is set.') } unless defined $model && length $model;
	return &clothesline_schedule_model_read($text, $now, $model);
}

# What the editor prints under the phrase box: how many days it read, the last
# of them, and the hours it hangs. The person's own words are the field's value.
# What the editor prints under the phrase box: each schedule's days and hours,
# joined. The person's own words are the field's value; the cards carry the rest.
sub clothesline_schedule_status {
	my ($cl) = @_;
	my @lines;
	foreach my $rule ( @{ &clothesline_schedule_list($cl) } ) {
		next unless ref $rule eq 'HASH';
		my $days = ref $rule->{'days'} eq 'HASH' ? $rule->{'days'} : {};
		my $count = scalar keys %{$days};
		next unless $count;
		my @keys = sort keys %{$days};
		my @hours = sort { $a <=> $b } @{ ref $rule->{'hours'} eq 'ARRAY' ? $rule->{'hours'} : [] };
		my @minutes = sort { $a <=> $b } @{ ref $rule->{'minutes'} eq 'ARRAY' ? $rule->{'minutes'} : [] };
		push @lines, &ui('Hangs on') . ' ' . $count . ' ' . ($count == 1 ? &ui('day') : &ui('days'))
			. ' ' . &ui('through') . ' ' . $keys[-1] . ', ' . &clothesline_time_words(\@hours, \@minutes);
	}
	return join('; ', @lines);
}

# The editor's audit: one card per schedule, with the recurrence it read, the
# days it matches, the hours and minutes, and the next few dates.
sub clothesline_schedule_cards {
	my ($cl) = @_;
	my @cards;
	my $list = &clothesline_schedule_list($cl);
	for my $i ( 0 .. $#$list ) {
		my $rule = $list->[$i];
		next unless ref $rule eq 'HASH';
		my $days = ref $rule->{'days'} eq 'HASH' ? $rule->{'days'} : {};
		my @keys = sort keys %{$days};
		my @hours = sort { $a <=> $b } @{ ref $rule->{'hours'} eq 'ARRAY' ? $rule->{'hours'} : [] };
		my @minutes = sort { $a <=> $b } @{ ref $rule->{'minutes'} eq 'ARRAY' ? $rule->{'minutes'} : [] };
		push @cards, {
			index => $i,
			text => ($rule->{'text'} // ''),
			say => (defined $rule->{'say'} && $rule->{'say'} =~ /\S/) ? $rule->{'say'} : &clothesline_schedule_say(
				(ref $rule->{'plan'} eq 'HASH' && ref $rule->{'plan'}->{'plans'} eq 'ARRAY') ? $rule->{'plan'}->{'plans'} : [],
				\@hours, \@minutes),
			plans => &clothesline_plans_words($rule->{'plan'}),
			count => scalar @keys,
			first => ($keys[0] // ''),
			last => ($keys[-1] // ''),
			hours => &clothesline_time_words(\@hours, \@minutes),
			next => [ @keys[0 .. ($#keys < 7 ? $#keys : 7)] ],
		};
	}
	return \@cards;
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
