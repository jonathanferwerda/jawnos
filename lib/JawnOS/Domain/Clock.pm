package subs;

# Clock: extracted from subroutines.pl (package subs). Loaded on
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

our $clock_apps_memo;
our $clock_apps_memo_at;
our $clock_apps_memo_images;
our $device;
our %m;

# Write the next alarm for the app, and only broadcast when it really moved.
# The file is what survives a reboot; the broadcast is what arms it now.
sub clock_write_device_alarm {
	my ($alarms, $now) = @_;
	$now = &rightNow() unless defined $now;
	my ($next, $next_alarm);
	foreach my $alarm (@{ $alarms || [] }) {
		# A ringing alarm has already woken the phone; the next one is what the
		# app should arm now. Only an alarm this machine carries is armed here.
		next unless &clock_alarm_targets_me($alarm);
		next if $alarm->{'ringing'};
		my $candidate;
		if ($alarm->{'snooze_until'} && $alarm->{'snooze_until'} > $now) {
			$candidate = $alarm->{'snooze_until'};
		}
		elsif ($alarm->{'enabled'}) {
			my $from = $now;
			$from = $alarm->{'skip_fire'} if $alarm->{'skip_fire'} && $alarm->{'skip_fire'} > $now;
			$candidate = &clock_alarm_next_ms($alarm, $from);
		}
		next unless $candidate;
		if (!$next || $candidate < $next) {
			$next = $candidate;
			$next_alarm = $alarm;
		}
	}
	my $file = &home('~/.president/clock_alarm.json');
	my $payload;
	if ($next && $next_alarm) {
		my $sound = &clock_valid_alarm_sound($next_alarm->{'sound'}) || 'notifications/ring.mp3';
		$payload = {
			at => $next,
			uuid => ($next_alarm->{'uuid'} || ''),
			label => ($next_alarm->{'label'} || ''),
			app => ($next_alarm->{'app'} || ''),
			# The phone plays this itself on the alarm channel; the kind of
			# sound and its ramp ride along so a reboot or an exact wake has
			# them without another broadcast.
			file => 'public/sounds/' . $sound,
			volume => int($next_alarm->{'volume'} || 70),
			ramp => int($next_alarm->{'ramp'} || 0),
			# Every alarm sound repeats now: a long recording loops at the alarm's
			# volume, a chime loops on the alarm channel. Dismiss/Snooze, or the
			# five-minute guard, is what ends it.
			loop => 1,
			snooze => int($next_alarm->{'snooze'} || 5),
			play => ($next_alarm->{'play'} || ''),
			nfc => (($next_alarm->{'nfc'} || 0) && &clock_app_has_nfc_start($next_alarm->{'app'})) ? 1 : 0,
			nfc_action => ($next_alarm->{'nfc_action'} || 'snooze'),
			guard => &clock_alarm_ring_length($next_alarm),
		};
	}
	my $json = $payload ? encode_json($payload) : '';
	my $old = -e $file ? (eval { read_file($file) } // '') : '';
	return 0 if $old eq $json;
	if (length $json) {
		eval { write_file($file, $json); };
	}
	else {
		unlink $file;
	}
	&clock_device_broadcast(&app_action('JAWN_CLOCK_SYNC'), %{ $payload || {} });
	return 1;
}

sub clock_device_ring {
	my ($alarm, $fire_at) = @_;
	return 0 unless $alarm;
	my $sound = &clock_valid_alarm_sound($alarm->{'sound'}) || 'notifications/ring.mp3';
	# The phone plays this itself, on the alarm channel: a chime repeats until
	# Dismiss, and a long track plays once at the alarm's own volume.
	&clock_device_broadcast(&app_action('JAWN_CLOCK_RING'),
		uuid => ($alarm->{'uuid'} || ''),
		label => ($alarm->{'label'} || ''),
		app => ($alarm->{'app'} || ''),
		at => ($fire_at || &rightNow()),
		file => 'public/sounds/' . $sound,
		volume => int($alarm->{'volume'} || 70),
		ramp => int($alarm->{'ramp'} || 0),
		loop => 1,
		snooze => int($alarm->{'snooze'} || 5),
		play => ($alarm->{'play'} || ''),
		nfc => (($alarm->{'nfc'} || 0) && &clock_app_has_nfc_start($alarm->{'app'})) ? 1 : 0,
		nfc_action => ($alarm->{'nfc_action'} || 'snooze'),
		guard => &clock_alarm_ring_length($alarm),
	);
	return 1;
}

# A timer's chime is the same promise as an alarm's; it goes through the same
# alarm channel on a phone rather than the notification stream.
sub clock_device_timer {
	my $timer = shift;
	return 0 unless $timer;
	my $sound = &clock_valid_timer_sound($timer->{'sound'});
	&clock_device_broadcast(&app_action('JAWN_CLOCK_TIMER'),
		uuid => ($timer->{'uuid'} || ''),
		label => ($timer->{'label'} || ''),
		app => ($timer->{'app'} || ''),
		at => ($timer->{'ends_at'} || &rightNow()),
		file => 'public/sounds/' . $sound,
		volume => int($timer->{'volume'} || 70),
		ramp => 0,
		loop => 0,
		guard => 60000,
	);
	return 1;
}

sub clock_device_dismissed {
	my $uuid = shift;
	&clock_device_broadcast(&app_action('JAWN_CLOCK_DISMISSED'), uuid => ($uuid || ''));
	return 1;
}

sub clock_lock_path {
	my $dir = &home('~/.president');
	unless (-d $dir) {
		eval { File::Path::make_path($dir); };
	}
	$dir = '/tmp' unless -d $dir;
	return $dir . '/.clock_lock';
}

sub clock_lock_take {
	my $path = &clock_lock_path();
	my $fh;
	open($fh, '>>', $path) or return undef;
	flock($fh, LOCK_EX) or do { close($fh); return undef; };
	return $fh;
}

sub clock_lock_drop {
	my $fh = shift;
	return unless $fh;
	flock($fh, LOCK_UN);
	close($fh);
}

sub clock_normalize_alarm {
	my $in = shift;
	$in = {} unless ref $in eq 'HASH';
	my @raw_days = ref $in->{'days'} eq 'ARRAY' ? @{ $in->{'days'} } : split /,/, ($in->{'days'} // '');
	my (@days, %seen);
	foreach my $d (@raw_days) {
		next unless defined $d && "$d" =~ /^\d+$/;
		$d = int($d);
		next if $d < 0 || $d > 6 || $seen{$d}++;
		push @days, $d;
	}
	@days = sort { $a <=> $b } @days;
	my $hour = (defined $in->{'hour'} && "$in->{'hour'}" =~ /^\d+$/) ? int($in->{'hour'}) : 7;
	my $minute = (defined $in->{'minute'} && "$in->{'minute'}" =~ /^\d+$/) ? int($in->{'minute'}) : 0;
	$hour = 23 if $hour > 23;
	$minute = 59 if $minute > 59;
	my $volume = (defined $in->{'volume'} && "$in->{'volume'}" =~ /^\d+$/) ? int($in->{'volume'}) : 70;
	$volume = 5 if $volume < 5;
	$volume = 100 if $volume > 100;
	my $ramp = (defined $in->{'ramp'} && "$in->{'ramp'}" =~ /^\d+$/) ? int($in->{'ramp'}) : 60;
	$ramp = 0 if $ramp < 0;
	$ramp = 600 if $ramp > 600;
	my $label = defined $in->{'label'} ? "$in->{'label'}" : 'Alarm';
	$label =~ s/^\s+//;
	$label =~ s/\s+$//;
	# The name sits beside a wide time field; twenty characters is all the row
	# can show, and nobody needs a sentence here.
	$label = substr($label, 0, 20);
	$label = 'Alarm' unless length $label;
	my $sound = &clock_valid_alarm_sound($in->{'sound'}) || 'notifications/ring.mp3';
	# How long Snooze waits. Each alarm carries its own length so a morning alarm
	# and a nap alarm can differ; five minutes is the old fixed behaviour.
	my $snooze = (defined $in->{'snooze'} && "$in->{'snooze'}" =~ /^\d+$/) ? int($in->{'snooze'}) : 5;
	$snooze = 1 if $snooze < 1;
	$snooze = 60 if $snooze > 60;
	# Play mode is the first step towards a wake-up game. Only math exists now;
	# an unknown value reads as none so an old client cannot arm a puzzle the
	# alarm screen does not know how to draw.
	my $play = (($in->{'play'} // '') eq 'math') ? 'math' : '';
	# NFC requires a tag assigned to the linked app. The action is what the tag
	# does when it is scanned; snooze is the old default and dismiss is the
	# Tasker-style "get out of bed" choice.
	my $nfc = ($in->{'nfc'} && $in->{'nfc'} ne '0' && $in->{'nfc'} ne 'off') ? 1 : 0;
	my $nfc_action = (($in->{'nfc_action'} // '') eq 'dismiss') ? 'dismiss' : 'snooze';
	my $enabled = defined $in->{'enabled'} ? (($in->{'enabled'} && $in->{'enabled'} ne '0' && $in->{'enabled'} ne 'off') ? 1 : 0) : 1;
	my $self = &signatorial_designer() || '';
	my @raw_machines = ref $in->{'machines'} eq 'ARRAY' ? @{ $in->{'machines'} } : split /,/, ($in->{'machines'} // '');
	my (@machines, %seen_machine);
	foreach my $m (@raw_machines) {
		next unless defined $m;
		$m =~ s/^\s+|\s+$//g;
		next unless length $m && $m =~ /^[A-Za-z0-9_\-]{1,64}$/;
		$m = $self if $m eq 'me' && length $self;
		next if $seen_machine{$m}++;
		push @machines, $m;
	}
	return {
		uuid => ($in->{'uuid'} // ''),
		hour => $hour,
		minute => $minute,
		days => \@days,
		enabled => $enabled,
		label => $label,
		app => ($in->{'app'} // ''),
		sound => $sound,
		volume => $volume,
		ramp => $ramp,
		snooze => $snooze,
		play => $play,
		nfc => $nfc,
		nfc_action => $nfc_action,
		machines => \@machines,
		# An alarm written from a future appointment points back at it, so the next
		# appointment replaces the same Clock row instead of adding another one.
		appt_uuid => ($in->{'appt_uuid'} // ''),
		source => ($in->{'source'} // ''),
		updated => int($in->{'updated'} || 0),
		last_fire => int($in->{'last_fire'} || 0),
		snooze_until => int($in->{'snooze_until'} || 0),
		skip_fire => int($in->{'skip_fire'} || 0),
		stop_at => int($in->{'stop_at'} || 0),
		ringing => ($in->{'ringing'} ? 1 : 0),
		ring_started => int($in->{'ring_started'} || 0),
		ring_last => int($in->{'ring_last'} || 0),
		created => int($in->{'created'} || 0),
	};
}

sub clock_normalize_timer {
	my $t = shift;
	$t = {} unless ref $t eq 'HASH';
	my $seconds = (defined $t->{'seconds'} && "$t->{'seconds'}" =~ /^\d+$/) ? int($t->{'seconds'}) : 300;
	$seconds = 1 if $seconds < 1;
	$seconds = 359999 if $seconds > 359999;
	my $label = defined $t->{'label'} ? "$t->{'label'}" : 'Timer';
	$label =~ s/^\s+//;
	$label =~ s/\s+$//;
	$label = substr($label, 0, 120);
	$label = 'Timer' unless length $label;
	my $state = $t->{'state'} // 'running';
	$state = 'running' unless grep { $_ eq $state } qw/running done cancelled/;
	my $volume = (defined $t->{'volume'} && "$t->{'volume'}" =~ /^\d+$/) ? int($t->{'volume'}) : 70;
	$volume = 5 if $volume < 5;
	$volume = 100 if $volume > 100;
	return {
		uuid => ($t->{'uuid'} // ''),
		label => $label,
		seconds => $seconds,
		started_at => int($t->{'started_at'} || 0),
		ends_at => int($t->{'ends_at'} || 0),
		ended_at => int($t->{'ended_at'} || 0),
		state => $state,
		app => ($t->{'app'} // ''),
		appt_uuid => ($t->{'appt_uuid'} // ''),
		sound => &clock_valid_timer_sound($t->{'sound'}),
		volume => $volume,
		created => int($t->{'created'} || 0),
	};
}

# The house alarm list. Before sharing, each machine kept its own row under its
# device type; a new install would see only its own. The first read moves every
# such row into the single house row, and those alarms are addressed to the
# machine doing the moving ("Me").
sub clock_alarms_migrate {
	my $store = &clock_alarm_store_device();
	my $rows = eval { &db_query('select value, device, server_time from settings where app = ? and setting = ? and device != ? order by cast(server_time as integer) asc', 'clock', 'alarms', $store)->hashes } || [];
	my $self = &signatorial_designer() || '';
	my (@out, %seen);
	foreach my $r (@{ $rows || [] }) {
		my $list = eval { decode_json($r->{'value'} || '') } || [];
		next unless ref $list eq 'ARRAY';
		foreach my $a (@{ $list }) {
			next unless ref $a eq 'HASH';
			my $alarm = &clock_normalize_alarm($a);
			next unless length($alarm->{'uuid'} || '');
			next if $seen{$alarm->{'uuid'}}++;
			$alarm->{'machines'} = [ $self ] if (!scalar @{ $alarm->{'machines'} || [] }) && length $self;
			push @out, $alarm;
		}
	}
	my $json = encode_json(\@out);
	eval { &setting_setter({ app => 'clock', setting => 'alarms', value => $json, device => $store }) };
	return $json;
}

sub clock_alarms_read {
	my $raw = eval { &setting_grabber({ app => 'clock', setting => 'alarms', device => &clock_alarm_store_device() }) };
	unless (defined $raw && length $raw) {
		$raw = eval { &clock_alarms_migrate() };
	}
	my $list = (defined $raw && length $raw) ? eval { decode_json($raw) } : [];
	$list = [] unless ref $list eq 'ARRAY';
	return [ map { &clock_normalize_alarm($_) } @{$list} ];
}

sub clock_timers_read {
	my $raw = eval { &setting_grabber({ app => 'clock', setting => 'timers', device => &clock_device() }) };
	my $list = (defined $raw && length $raw) ? eval { decode_json($raw) } : [];
	$list = [] unless ref $list eq 'ARRAY';
	return [ map { &clock_normalize_timer($_) } @{$list} ];
}

sub clock_alarms_write {
	my $alarms = shift;
	my $json = encode_json($alarms || []);
	&setting_setter({ app => 'clock', setting => 'alarms', value => $json, device => &clock_alarm_store_device() });
	return $alarms;
}

sub clock_timers_write {
	my $timers = shift;
	my $json = encode_json($timers || []);
	&setting_setter({ app => 'clock', setting => 'timers', value => $json, device => &clock_device() });
	return $timers;
}

# The next moment an alarm is due, strictly after $from. A day list of none is a
# one-shot: the next such time, whatever day it lands on. The caller decides what
# to do with a moment that has just gone by (the firing loop allows two minutes).
sub clock_alarm_next_ms {
	my ($alarm, $from) = @_;
	my $hour = int($alarm->{'hour'} || 0);
	my $minute = int($alarm->{'minute'} || 0);
	my @days = @{ $alarm->{'days'} || [] };
	$from = &rightNow() unless defined $from;
	my @lt = localtime(int($from / 1000));
	my ($mday, $mon, $year) = @lt[3, 4, 5];
	for my $offset (0 .. 8) {
		# POSIX::mktime normalises a day past the end of the month (Oct 31 + 1
		# is Nov 1). Time::Local::timelocal croaks on day 32, which made the
		# whole Clock state 500 for the last week of every month.
		my $candidate = POSIX::mktime(0, $minute, $hour, $mday + $offset, $mon, $year) * 1000;
		next if $candidate <= $from;
		if (!scalar @days) { return $candidate; }
		my @d = localtime(int($candidate / 1000));
		return $candidate if grep { $_ == $d[6] } @days;
	}
	return undef;
}

sub clock_next_wake {
	my ($alarms, $timers, $now, $rings) = @_;
	$now = &rightNow() unless defined $now;
	my $next;
	foreach my $a (@{ $alarms || [] }) {
		next unless &clock_alarm_targets_me($a);
		my $candidate;
		if ($a->{'ringing'}) {
			# A chime repeats every fifteen seconds; a long track plays once and
			# only needs a wake at the guard to clear the ring state. The machine's
			# own ring record says when it last sounded, since the shared row is
			# not rewritten on every repetition.
			my $ring = ref $rings eq 'HASH' ? $rings->{ $a->{'uuid'} } : undef;
			my $started = (ref $ring eq 'HASH' && $ring->{'started'}) ? $ring->{'started'} : ($a->{'ring_started'} || $now);
			my $last = (ref $ring eq 'HASH' && $ring->{'last'}) ? $ring->{'last'} : ($a->{'ring_last'} || $now);
			my $end = $started + &clock_alarm_ring_length($a);
			if (&clock_sound_is_long($a->{'sound'})) {
				$candidate = $end;
			}
			else {
				$candidate = $last + 15000;
				$candidate = $end if $end < $candidate;
			}
			$candidate = $now + 1000 if $candidate <= $now;
			$next = $candidate if $candidate && (!$next || $candidate < $next);
			next;
		}
		if ($a->{'snooze_until'} && $a->{'snooze_until'} > $now) {
			$candidate = $a->{'snooze_until'};
		}
		elsif ($a->{'enabled'}) {
			my $from = $now;
			$from = $a->{'skip_fire'} if $a->{'skip_fire'} && $a->{'skip_fire'} > $now;
			$candidate = &clock_alarm_next_ms($a, $from);
		}
		$next = $candidate if $candidate && (!$next || $candidate < $next);
	}
	foreach my $t (@{ $timers || [] }) {
		next unless ($t->{'state'} || '') eq 'running';
		my $candidate = $t->{'ends_at'};
		$next = $candidate if $candidate && (!$next || $candidate < $next);
	}
	return $next;
}

# Nudge the alarm worker so a save, a start or a cancel is reflected at once
# rather than at the appointment it was already sleeping toward.
sub clock_poke {
	my $timestamp = shift;
	$timestamp = &rightNow() unless defined $timestamp;
	eval { &appt_alarm_setter({ uuid => 'clock', timestamp => $timestamp }) };
	return 1;
}

sub clock_apps {
	my $now = &rightNow();
	my $memo = ($clock_apps_memo && $clock_apps_memo_at && ($now - $clock_apps_memo_at) < 60000) ? $clock_apps_memo : undef;
	my (@out, %seen);
	foreach my $name (qw/me misc music_folder_toggle teletype __president __DEBRIEFING__/) { $seen{$name} = 1; }
	if ($memo) {
		@out = @{ $memo };
		foreach my $row (@out) { $seen{$row->{'value'}} = 1; }
	}
	else {
		# A hidden appointment must not be offered for linking. Visibility is a
		# setting per app ("visible" = unchecked is hidden) and this machine's own
		# row wins over the person's.
		my $device = &clock_device();
		my %visible;
		my $vis_rows = eval { &db_query("select app, device, value from settings where setting = 'visible' and device in (?, 'me')", $device)->hashes } || [];
		foreach my $v (@{ $vis_rows || [] }) {
			my $a = $v->{'app'};
			next unless defined $a && length $a;
			if (($v->{'device'} || '') eq $device) { $visible{$a} = $v->{'value'}; }
			elsif (!exists $visible{$a}) { $visible{$a} = $v->{'value'}; }
		}
		# One query for the album art the icon maker would otherwise ask for
		# app by app.
		my %main_image;
		my $img_rows = eval { &db_query("select app, device, value from settings where setting = 'main_image' and device in (?, 'me')", $device)->hashes } || [];
		foreach my $v (@{ $img_rows || [] }) {
			my $a = $v->{'app'};
			next unless defined $a && length $a && length($v->{'value'} || '');
			if (($v->{'device'} || '') eq $device) { $main_image{$a} = $v->{'value'}; }
			elsif (!exists $main_image{$a}) { $main_image{$a} = $v->{'value'}; }
		}
		# The most recently used appointments make a useful picker without
		# shipping the whole history: a house can name thousands of things and
		# only the last hundred and fifty are likely to be linked to a clock.
		my $rows = eval {
			return &db_query('select app, max(timestamp) as last from appointments where app is not null and app != ? group by app order by last desc limit 150', '')->hashes;
		} || [];
		foreach my $r (@{ $rows || [] }) {
			my $a = $r->{'app'};
			next unless defined $a && length $a;
			next if $a =~ /^__/;
			next if &app_hidden_now($a);
			next if $seen{$a}++;
			push @out, { value => $a, label => &format_name($a) };
		}
		@out = sort { lc($a->{'label'}) cmp lc($b->{'label'}) } @out;
		$clock_apps_memo = [ @out ];
		$clock_apps_memo_at = $now;
		$clock_apps_memo_images = { %main_image };
	}
	my $images = $clock_apps_memo_images || {};
	# a link already on an alarm or timer stays offered even before that app has
	# written an appointment of its own
	foreach my $row (@{ &clock_alarms_read() }, @{ &clock_timers_read() }) {
		my $a = $row->{'app'};
		next unless defined $a && length $a;
		next if $seen{$a}++;
		push @out, { value => $a, label => &format_name($a) };
	}
	@out = sort { lc($a->{'label'}) cmp lc($b->{'label'}) } @out;
	# The picker is a list of rows, not a datalist: each one carries the icon the
	# app wears elsewhere in the house, so a person recognises it at a glance.
	my $n = 0;
	foreach my $row (@out) {
		$n++;
		next if defined $row->{'icon'} && length $row->{'icon'};
		$row->{'icon'} = &main_icon_maker({
			app => $row->{'value'},
			timestamp => $now + $n,
			size => 'little',
			onclick => ' ',
			hint => $row->{'label'},
			settings => { main_image => ($images->{$row->{'value'}} || '') },
		});
	}
	return \@out;
}

# The moment an alarm will next run, for the row's countdown. A snooze is the
# next run; a skipped occurrence is not, so the search starts past it.
sub clock_alarm_next_at {
	my ($alarm, $now) = @_;
	$now = &rightNow() unless defined $now;
	return $alarm->{'snooze_until'} if $alarm->{'snooze_until'} && $alarm->{'snooze_until'} > $now;
	return 0 unless $alarm->{'enabled'};
	my $from = $now;
	$from = $alarm->{'skip_fire'} if $alarm->{'skip_fire'} && $alarm->{'skip_fire'} > $now;
	return &clock_alarm_next_ms($alarm, $from) || 0;
}

# The phone's "Skip today" button cannot call the manager, so it writes this
# little file; the alarm worker picks it up and applies the same skip the
# browser button does.
sub clock_skip_file {
	my $dir = &home('~/.president');
	eval { File::Path::make_path($dir); } unless -d $dir;
	$dir = '/tmp' unless -d $dir;
	return $dir . '/clock_skip.json';
}

sub clock_skip_apply {
	my $file = &clock_skip_file();
	return 0 unless -e $file;
	my $raw = eval { read_file($file) } // '';
	unlink $file;
	my $data = eval { decode_json($raw) };
	return 0 unless ref $data eq 'HASH';
	my $uuid = $data->{'uuid'} || '';
	return 0 unless length $uuid;
	my $now = &rightNow();
	my $lock = &clock_lock_take();
	my $alarms = &clock_alarms_read();
	my ($alarm) = grep { ($_->{'uuid'} || '') eq $uuid } @{ $alarms };
	if (!$alarm) {
		&clock_lock_drop($lock);
		return 0;
	}
	my $at = int($data->{'at'} || 0);
	$at = &clock_alarm_next_ms($alarm, $now) if $at <= 0;
	$alarm->{'skip_fire'} = $at;
	$alarm->{'snooze_until'} = 0;
	$alarm->{'ringing'} = 0;
	$alarm->{'ring_started'} = 0;
	$alarm->{'ring_last'} = 0;
	&clock_alarms_write($alarms);
	&clock_lock_drop($lock);
	&clock_alarm_stop_sound($uuid);
	&clock_write_device_alarm($alarms, $now);
	&clock_poke($now);
	return 1;
}

# Every NFC tag row for an app, across devices. A tag is written from the phone
# that owns the reader, so its settings row may sit under that machine; the
# alarm has to find it whichever machine is editing the Clock.
sub clock_app_nfc_tags {
	my ($app) = @_;
	return [] unless defined $app && length $app;
	my $rows = eval { &db_query("select device, value from settings where app = ? and setting = 'nfc'", $app)->hashes } || [];
	my @tags;
	foreach my $r (@{ $rows || [] }) {
		my $list = eval { decode_json($r->{'value'} || '') } || [];
		next unless ref $list eq 'ARRAY';
		foreach my $t (@{$list}) {
			next unless ref $t eq 'HASH' && length($t->{'uuid'} || '');
			$t->{'device'} = $r->{'device'};
			push @tags, $t;
		}
	}
	return \@tags;
}

# The controls that start an app. A tag assigned for any of these can answer the
# linked alarm; a tag that only records or commands does not count as the
# waking-up tag.
sub clock_nfc_control_starts {
	my ($control) = @_;
	return 0 unless defined $control && length $control;
	return $control =~ /^(?:start|record|usual)$/ ? 1 : 0;
}

sub clock_app_has_nfc_start {
	my ($app) = @_;
	my $tags = &clock_app_nfc_tags($app);
	return scalar grep { &clock_nfc_control_starts($_->{'control'}) } @{ $tags || [] };
}

# app => 1 for every app with a start tag; the alarm editor uses this to offer
# the "Use NFC to snooze" box only where a tag really exists.
sub clock_nfc_start_apps {
	my $rows = eval { &db_query("select app, value from settings where setting = 'nfc'")->hashes } || [];
	my %out;
	foreach my $r (@{ $rows || [] }) {
		my $app = $r->{'app'} || '';
		next unless length $app;
		my $list = eval { decode_json($r->{'value'} || '') } || [];
		next unless ref $list eq 'ARRAY';
		foreach my $t (@{$list}) {
			next unless ref $t eq 'HASH';
			if (&clock_nfc_control_starts($t->{'control'})) { $out{$app} = 1; last; }
		}
	}
	return \%out;
}

sub clock_state {
	my $now = &rightNow();
	my $me = &signatorial_designer() || '';
	my $alarms = &clock_alarms_read();
	my $acks = &clock_alarm_acks_read();
	my $nfc_apps = &clock_nfc_start_apps();
	foreach my $alarm (@{ $alarms }) {
		$alarm->{'next_at'} = &clock_alarm_next_at($alarm, $now);
		# A stale NFC flag on an alarm whose app no longer has a start tag must
		# not leave the phone asking for a tag that cannot answer.
		$alarm->{'nfc_ready'} = ($alarm->{'nfc'} && $nfc_apps->{$alarm->{'app'}}) ? 1 : 0;
		my $delivered = {};
		if (ref $acks->{ $alarm->{'uuid'} } eq 'HASH') {
			# Keep only confirmations of the row as it stands now: an ack from a
			# previous edit is not a confirmation that the new edit arrived.
			my $updated = int($alarm->{'updated'} || 0);
			foreach my $sig ( keys %{ $acks->{ $alarm->{'uuid'} } } ) {
				my $at = int($acks->{ $alarm->{'uuid'} }->{$sig} || 0);
				next if !$at || ($updated && $at < $updated);
				$delivered->{$sig} = $at;
			}
		}
		# This machine holds the row it is showing, so its own pill is always
		# confirmed; the check marks are for the machines the push reached.
		$delivered->{$me} = $now if length $me && &clock_alarm_targets_me($alarm);
		$alarm->{'delivered'} = $delivered;
	}
	return {
		now => $now,
		alarms => $alarms,
		timers => &clock_timers_read(),
		apps => &clock_apps(),
		sounds => &clock_sounds(),
		alarm_sounds => &clock_alarm_sounds(),
		machines => &clock_machines(),
		nfc_apps => $nfc_apps,
		me => $me,
		max => 10,
	};
}

sub clock_send_console {
	my $script = shift;
	return unless defined $script && length $script;
	eval { &Websocket::send('tab', { console => $script, timestamp => &rightNow() }); };
	return 1;
}

# How loud the OS alarm is at a moment in its ring: a little above silence at
# the start, then the alarm's own volume by the end of its ramp. The browser
# draws the ring card, but the sound belongs to the machine.
sub clock_alarm_volume_at {
	my ($alarm, $elapsed, $system_set) = @_;
	# When the machine's sink already carries the chosen level, the player only
	# adds the ramp; scaling by the percentage again would square it.
	my $target = $system_set ? 1 : (($alarm->{'volume'} || 70) / 100);
	my $ramp = ($alarm->{'ramp'} || 0) * 1000;
	my $progress = 1;
	if ($ramp > 0) {
		$progress = $elapsed / $ramp;
		$progress = 1 if $progress > 1;
		$progress = 0 if $progress < 0;
		$progress = 0.15 + (0.85 * $progress);
	}
	my $level = $target * $progress;
	$level = 0.02 if $level < 0.02;
	return sprintf('%.2f', $level);
}

# A long-form track loops until Dismiss, Snooze or the five-minute guard. The
# old reading played a recording once and left the person asleep after it ended;
# `repeat` makes the operating-system player carry the alarm the same way a
# phone's alarm channel does. The pid file still lets Dismiss stop it.
sub clock_alarm_ring_length {
	my $alarm = shift;
	return 300000;
}

# The command the OS player runs for this alarm. A long track is played once,
# at the alarm's volume, with the ramp as its fade-in, and its pid is written so
# Dismiss can stop it. A chime is played at the moment's ramped volume.
sub clock_alarm_play_command {
	my ($alarm, $elapsed, $system_set) = @_;
	$elapsed ||= 0;
	my $sound = &clock_valid_alarm_sound($alarm->{'sound'}) || 'notifications/ring.mp3';
	my $file = &clock_sound_file($sound);
	if (&clock_sound_is_long($sound)) {
		my $target = $system_set ? '1.00' : sprintf('%.2f', ($alarm->{'volume'} || 70) / 100);
		my $ramp = int($alarm->{'ramp'} || 0);
		$ramp = 1 if $ramp < 1;
		my $play = 'play -q -v ' . $target . ' ' . &quote($file) . ' fade t ' . $ramp . ' repeat 1000';
		return $play . ' & echo $! > ' . &clock_alarm_pidfile($alarm->{'uuid'});
	}
	my $level = &clock_alarm_volume_at($alarm, $elapsed, $system_set);
	return 'play -q -v ' . $level . ' ' . &quote($file) . ' fade t 1';
}

# Play one repetition of a short chime through the operating system. The
# notification at the first ring carries the first sound; later rings use this
# one directly, so the volume climbs across the ramp and no notification row is
# written each time. A long-form track is never repeated this way.
sub clock_alarm_sound {
	my ($alarm, $elapsed) = @_;
	$elapsed ||= 0;
	my $sound = &clock_valid_alarm_sound($alarm->{'sound'}) || 'notifications/ring.mp3';
	return '' if &clock_sound_is_long($sound);
	# On a phone the app owns the sound: it loops the chime on the alarm channel
	# and stops it on Dismiss. A Perl player here would sound on the media
	# stream beside it.
	return '' if &device_setter() eq 'mobile';
	my $command = &clock_alarm_play_command($alarm, $elapsed, &clock_alarm_volume_saved($alarm->{'uuid'} || ''));
	eval {
		&subprocessor(sub { &run_command('clock', $command); }, { name => 'clock alarm sound' });
	};
	return $command;
}

1;
