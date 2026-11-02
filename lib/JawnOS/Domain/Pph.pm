package subs;

# Pph: extracted from subroutines.pl (package subs). Loaded on
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

our $battery_sample_memo;

# The PPH comparator: the same discharging history, grouped by the lock state
# that produced each sample. A scheduled-wake reading and a permanent-lock
# reading can then be compared without a separate measuring process (which would
# itself keep the phone awake). The caller prints or renders the rows.
sub pph_compare_report {
	my $cached = &cache_get({ app => '__president', context => 'battery', subcontext => 'current' });
	my $history = (ref $cached eq 'HASH' && ref $cached->{'history'} eq 'ARRAY') ? $cached->{'history'} : [];
	# Points written before the state was recorded are assigned by the handoff
	# marker's mtime: before it was written, the permanent lock was held.
	my $release = &subs::home('~/.president/wake_lock_released');
	my $released_at = -e $release ? ((stat($release))[9] || 0) * 1000 : 0;
	my %group;
	foreach my $point ( @{$history} ) {
		next unless ref $point eq 'HASH' && defined $point->{'p'} && defined $point->{'t'};
		next unless (($point->{'s'} || '') eq 'discharging');
		my $state = $point->{'w'} || ($released_at && $point->{'t'} >= $released_at ? 'scheduled' : 'permanent');
		push @{$group{$state}}, $point;
	}
	my @rows;
	foreach my $state ( qw/scheduled permanent/ ) {
		my @points = sort { $a->{'t'} <=> $b->{'t'} } @{$group{$state} || []};
		# A jump of ten points or a gap over half an hour is a new segment (a
		# battery swap, a bad read, a long shutdown), not drain to be fitted.
		my @clean;
		foreach my $point ( @points ) {
			if (@clean && (abs($point->{'p'} - $clean[-1]->{'p'}) > 10
				|| $point->{'t'} - $clean[-1]->{'t'} > 1800000)) {
				@clean = ();
			}
			push @clean, $point;
		}
		my $pph;
		my $hours = 0;
		if (scalar @clean >= 3) {
			my $base = $clean[0]->{'t'};
			$hours = ($clean[-1]->{'t'} - $base) / 3600000;
			my ($n, $sx, $sy, $sxx, $sxy) = (0, 0, 0, 0, 0);
			foreach my $point ( @clean ) {
				my $x = ($point->{'t'} - $base) / 3600000;
				my $y = $point->{'p'} + 0;
				$n++; $sx += $x; $sy += $y; $sxx += $x * $x; $sxy += $x * $y;
			}
			my $den = $n * $sxx - $sx * $sx;
			if ($n >= 3 && $den > 0) {
				my $slope = ($n * $sxy - $sx * $sy) / $den;
				$pph = -$slope if $slope < 0;
			}
		}
		push @rows, {
			state => $state,
			label => ($state eq 'scheduled' ? 'Scheduled wake' : 'Permanent lock'),
			points => scalar @clean,
			hours => $hours,
			pph => $pph,
		};
	}
	return {
		rows => \@rows,
		history => scalar @{$history},
		released_at => $released_at,
		note => (scalar @{$history} ? undef : 'No battery history yet.'),
	};
}

# The card's one estimate, in hours, from whichever reading the pack gives.
# The gauge (energy/power) is the only real measurement; a percentage slope is
# an inference. Fills eta_kind (left/full), eta_hours, eta_lo/eta_hi (a band),
# eta_flat (too flat to measure) and eta_floor (the most time a flat reading
# allows). `$previous` is the last sample, used to keep the shown figure still
# while the fit settles; a status change or a large real move is taken at once.
sub battery_eta_estimate {
	my ($b, $previous) = @_;
	return $b unless ref $b eq 'HASH';
	delete @{$b}{qw/eta_kind eta_hours eta_lo eta_hi eta_flat eta_floor/};
	my $pct = $b->{'percentage'};
	return $b unless defined $pct;
	my $status = lc($b->{'status'} || '');
	return $b if $status eq 'full' || $pct >= 100;
	my ($kind, $hours, $lo, $hi, $flat, $floor);
	if ($status eq 'charging') {
		$kind = 'full';
		if (defined $b->{'charge_eta'} && $b->{'charge_eta'} > 0) {
			$hours = $lo = $hi = $b->{'charge_eta'};
		}
		elsif (defined $b->{'charge_pph'} && $b->{'charge_pph'} > 0) {
			# A percentage-only charge runs short in the constant-current phase:
			# the last part of a Li-ion charge tapers. Pad it a little, and show
			# the slope's own band where there is one.
			$hours = (100 - $pct) / $b->{'charge_pph'} * 1.2;
			if (defined $b->{'charge_pph_hi'} && $b->{'charge_pph_hi'} > 0
				&& defined $b->{'charge_pph_lo'} && $b->{'charge_pph_lo'} > 0) {
				$lo = (100 - $pct) / $b->{'charge_pph_hi'} * 1.2;
				$hi = (100 - $pct) / $b->{'charge_pph_lo'} * 1.2;
			}
		}
	}
	elsif ($status eq 'discharging' || $status eq '') {
		$kind = 'left';
		my $gauge = (defined $b->{'discharge_eta'} && $b->{'discharge_eta'} > 0) ? $b->{'discharge_eta'} : undef;
		my ($slope, $slo, $shi);
		if (defined $b->{'pph'} && $b->{'pph'} > 0) {
			$slope = $pct / $b->{'pph'};
			if (defined $b->{'pph_hi'} && $b->{'pph_hi'} > 0
				&& defined $b->{'pph_lo'} && $b->{'pph_lo'} > 0) {
				$slo = $pct / $b->{'pph_hi'};   # the steepest plausible rate
				$shi = $pct / $b->{'pph_lo'};   # the shallowest
			}
		}
		# An Android charge counter is not in consistent units across vendors: on
		# a phone here the gauge named a 2.4 Ah pack and four hours left while the
		# measured drop said twelve hours (and the pack is rated 4.7 Ah). When the
		# gauge and the percentage slope disagree by more than half again, the
		# slope is the drain the person is actually living through, so it wins.
		if (defined $gauge && defined $slope && ($gauge > $slope * 1.5 || $gauge < $slope / 1.5)) {
			$hours = $slope;
			$lo = $slo;
			$hi = $shi;
		}
		elsif (defined $gauge) {
			$hours = $lo = $hi = $gauge;
		}
		elsif (defined $slope) {
			$hours = $slope;
			$lo = $slo;
			$hi = $shi;
		}
		elsif ($b->{'pph_flat'}) {
			$flat = 1;
			my $window = $b->{'pph_window'} || 2;
			# Two points of movement is the smallest step the gauge resolves;
			# a flatter history means the rate is no more than this.
			$floor = $window > 0 ? $pct / (2 / $window) : undef;
		}
	}
	else {
		return $b;   # not charging, unknown: the template says plugged in
	}
	return $b unless defined $kind;
	if (defined $hours) {
		my $prev = ref $previous eq 'HASH' ? $previous->{'eta_hours'} : undef;
		my $prev_kind = ref $previous eq 'HASH' ? ($previous->{'eta_kind'} || '') : '';
		if (defined $prev && $prev > 0 && $prev_kind eq $kind) {
			# Follow a real move at once; otherwise smooth, so an eight-second
			# card refresh does not make the figure flicker.
			$b->{'eta_hours'} = ($hours > $prev * 1.25 || $hours < $prev * 0.8)
				? $hours : $prev * 0.7 + $hours * 0.3;
		}
		else {
			$b->{'eta_hours'} = $hours;
		}
		$b->{'eta_lo'} = $lo if defined $lo;
		$b->{'eta_hi'} = $hi if defined $hi;
		$b->{'eta_over'} = 1 if $hours >= 240;   # a clamped gauge is a floor
	}
	$b->{'eta_kind'} = $kind;
	$b->{'eta_flat'} = 1 if $flat;
	$b->{'eta_floor'} = $floor if defined $floor;
	return $b;
}

# Fill in a finish-time estimate from a pack's own gauge, where the fields are
# there to do it: Android's charge counter plus the percentage gives the pack's
# capacity, and the averaged current then gives the hours to full (or flat).
# Called by the sampler and, for a peer still on older code, by the levels
# pass that receives its raw reading.
sub battery_gauge_eta {
	my ($b) = @_;
	return $b unless ref $b eq 'HASH';
	return $b if defined $b->{'charge_eta'} || defined $b->{'discharge_eta'};
	my $status = lc($b->{'status'} || '');
	return $b unless $status eq 'charging' || $status eq 'discharging';
	my $scale = $b->{'scale'} || 100;
	my $pct = $b->{'percentage'};
	my $counter = $b->{'charge_counter'};
	return $b unless defined $counter && $counter > 0 && defined $pct && $pct > 0 && $scale > 0;
	my $capacity = ($counter / 1000) / ($pct / $scale);
	return $b unless $capacity > 0;
	my $amps = $b->{'current_average'};
	$amps = $b->{'current'} if !defined $amps || $amps == 0;
	return $b unless defined $amps && $amps != 0;
	$amps = abs($amps);
	my $eta = $status eq 'charging' ? 'charge_eta' : 'discharge_eta';
	my $hours = $status eq 'charging'
		? ($capacity * ($scale - $pct) / $scale) / $amps
		: ($capacity * $pct / $scale) / $amps;
	$b->{'capacity_mah'} = $capacity;
	if ($hours > 0.01) {
		if ($hours > 240) { $hours = 240; $b->{'eta_capped'} = 1; }
		$b->{$eta} = $hours;
	}
	return $b;
}

sub battery_sample {
	my $now = &rightNow();
	return $battery_sample_memo
		if $battery_sample_memo && $now - ($battery_sample_memo->{'sampled'} || 0) < 10000;
	my $cached = &cache_get({ app => '__president', context => 'battery', subcontext => 'current' });
	if (ref $cached eq 'HASH' && $cached->{'sampled'} && $now - $cached->{'sampled'} < 10000) {
		my %fresh = %{$cached};
		delete $fresh{'history'};
		return $battery_sample_memo = \%fresh;
	}
	my $b = { sampled => $now, source => 'none' };
	# M1: the app answers through the bridge. A machine with no bridge (a
	# desktop, or an Android host that is not the app) has no power-supply
	# sysfs to read either, so it reports source 'none' rather than spawning
	# a termux command that is no longer installed.
	# A five second wait survives a busy app (a sync or a page render) without
	# declaring the battery gone; the cooldown is short and the stale sample
	# below covers the case where it is still too late.
	my $j = &subs::device_call('battery.status', {}, 5);
	if (ref $j eq 'HASH' && defined $j->{'percentage'}) {
			$b->{'source'} = 'bridge';
			$b->{'present'} = $j->{'present'} ? 1 : 0;
			$b->{'percentage'} = $j->{'percentage'} + 0;
			$b->{'temperature'} = defined $j->{'temperature'} ? $j->{'temperature'} + 0 : undef;
			# termux reports mV and uA; the Monitor shows V and mA
			$b->{'voltage'} = defined $j->{'voltage'} ? $j->{'voltage'} / 1000 : undef;
			$b->{'current'} = defined $j->{'current'} ? $j->{'current'} / 1000 : undef;
			$b->{'current_average'} = defined $j->{'current_average'} ? $j->{'current_average'} / 1000 : undef;
			$b->{'status'} = &unformat_name($j->{'status'} || '');
			$b->{'health'} = &unformat_name($j->{'health'} || '');
			$b->{'plugged'} = &unformat_name($j->{'plugged'} || '');
			$b->{'technology'} = $j->{'technology'} || '';
			$b->{'cycle'} = $j->{'cycle'};
			$b->{'charge_counter'} = $j->{'charge_counter'};
			$b->{'scale'} = $j->{'scale'};
			$b->{'temperature_source'} = 'battery' if defined $b->{'temperature'};
			# The Android gauge reports the charge left in microamp-hours, so
			# the pack's own capacity follows from the percentage reading. With
			# that and the (averaged) current, the finish time is known the
			# moment the cable goes in - no five-minute slope needed.
			&battery_gauge_eta($b);
		}
	elsif (-e '/sys/class/power_supply/BAT0/capacity') {
		my $base = '/sys/class/power_supply/BAT0';
		my $read = sub {
			my $path = shift;
			my $value = '';
			if (open(my $fh, '<', $path)) { $value = <$fh> // ''; close $fh; $value =~ s/\s+$//; }
			return $value;
		};
		$b->{'source'} = 'sysfs';
		$b->{'present'} = 1;
		$b->{'percentage'} = $read->("$base/capacity") + 0;
		$b->{'status'} = &unformat_name($read->("$base/status"));
		$b->{'health'} = &unformat_name($read->("$base/health"));
		my $temp = $read->("$base/temp");
		$b->{'temperature'} = $temp =~ /^-?\d+$/ ? $temp / 10 : undef;
		# a laptop often exposes no battery temperature; its thermal zones are
		# the next-best reading, and the strip marks it as the CPU's
		unless (defined $b->{'temperature'}) {
			my $best;
			for my $zone (glob('/sys/class/thermal/thermal_zone*/temp')) {
				my $value = $read->($zone);
				next unless $value =~ /^-?\d+$/;
				my $celsius = $value / 1000;
				next if $celsius < -50 || $celsius > 150;
				$best = $celsius if !defined $best || $celsius > $best;
			}
			if (defined $best) {
				$b->{'temperature'} = $best;
				$b->{'temperature_source'} = 'cpu';
			}
		}
		$b->{'temperature_source'} ||= 'battery' if defined $b->{'temperature'};
		my $volt = $read->("$base/voltage_now");
		$b->{'voltage'} = $volt =~ /^\d+$/ ? $volt / 1_000_000 : undef;
		my $cur = $read->("$base/current_now");
		$b->{'current'} = $cur =~ /^-?\d+$/ ? $cur / 1000 : undef;
		my $pow = $read->("$base/power_now");
		$b->{'power'} = $pow =~ /^\d+$/ ? $pow / 1_000_000 : undef;
		# The pack's own gauge gives the finish time outright: the energy still
		# to take over the power going in (energy_now/power_now), or the charge
		# still to take over the current. Both are read in the gauge's units so
		# no conversion can drift.
		my $energy_now = $read->("$base/energy_now");
		my $energy_full = $read->("$base/energy_full");
		my $charge_now = $read->("$base/charge_now");
		my $charge_full = $read->("$base/charge_full");
		# A laptop's power_now is a short-term average that swings with the
		# load, so a finish time taken from one reading jumps every few seconds.
		# A slow EMA (about three samples) keeps it steady without hiding a real
		# change in the charge rate. A status change starts fresh: blending a
		# charging rate into a discharging one would read several times too
		# short for a few samples after the cable comes out.
		my $status_now = lc($b->{'status'} || '');
		my $rate_w = defined $b->{'power'} ? abs($b->{'power'}) : undef;
		# current is mA; /1000 makes it A, so current * voltage is W. Without
		# this the fallback was 1000x too high (mW treated as W).
		$rate_w = abs($b->{'current'}) / 1000 * $b->{'voltage'}
			if (!defined $rate_w || $rate_w == 0) && defined $b->{'current'} && defined $b->{'voltage'};
		if (defined $rate_w && $rate_w > 0) {
			my $prev_source = (ref $cached eq 'HASH') ? ($cached->{'source'} || '') : '';
			my $prev_status = (ref $cached eq 'HASH') ? lc($cached->{'status'} || '') : '';
			my $prev = (ref $cached eq 'HASH' && $prev_status eq $status_now && $prev_source eq $b->{'source'})
				? $cached->{'rate_w'} : undef;
			$b->{'rate_w'} = (defined $prev && $prev > 0) ? ($prev * 0.7 + $rate_w * 0.3) : $rate_w;
			$rate_w = $b->{'rate_w'};
		}
		my ($now_u, $full_u, $rate_u);
		if ($energy_now =~ /^\d+$/ && $energy_full =~ /^\d+$/ && $energy_full > 0) {
			($now_u, $full_u) = ($energy_now, $energy_full);
			$rate_u = defined $rate_w ? $rate_w * 1_000_000 : undef;
		}
		elsif ($charge_now =~ /^\d+$/ && $charge_full =~ /^\d+$/ && $charge_full > 0) {
			($now_u, $full_u) = ($charge_now, $charge_full);
			$rate_u = (defined $rate_w && $b->{'voltage'})
				? $rate_w * 1_000_000 / $b->{'voltage'}
				: (defined $b->{'current'} ? abs($b->{'current'}) * 1000 : undef);
			$b->{'capacity_mah'} = $charge_full / 1000;
		}
		if (defined $rate_u && $rate_u > 0 && defined $now_u) {
			if ($status_now eq 'charging' && $full_u > $now_u) {
				$b->{'charge_eta'} = ($full_u - $now_u) / $rate_u;
			}
			elsif ($status_now eq 'discharging' && $now_u > 0) {
				$b->{'discharge_eta'} = $now_u / $rate_u;
			}
		}
	}
	# PPH: one number, the battery's percent-per-hour draw while discharging.
	# The old view divided one drop by one interval and had a `percenttage` typo
	# that made every value zero. The fit is now robust across the whole stored
	# history (three hours), needs twenty minutes and two points of movement, and
	# carries a confidence band, so one integer step or one bad reading does not
	# decide the answer. A sample is kept every 30s (the reading itself may
	# refresh every 10s) and 360 of them give a three-hour window without growing
	# the cache row.
	my $history = (ref $cached eq 'HASH' && ref $cached->{'history'} eq 'ARRAY') ? $cached->{'history'} : [];
	if (defined $b->{'percentage'}) {
		my $last_at = scalar(@{$history}) ? ($history->[-1]->{'t'} || 0) : 0;
		if ($now - $last_at >= 30000) {
			# w records which lock produced the reading: the PPH comparator groups
			# the drain by it (scheduled wake vs the old permanent lock).
			push @{$history}, {
				t => $now,
				p => $b->{'percentage'} + 0,
				s => lc($b->{'status'} || ''),
				w => (-e &subs::home('~/.president/wake_lock_released') ? 'scheduled' : 'permanent'),
			};
			splice @{$history}, 0, scalar(@{$history}) - 360 if scalar @{$history} > 360;
		}
	}
	if (lc($b->{'status'} || '') eq 'discharging' || lc($b->{'status'} || '') eq 'charging') {
		my $want = lc($b->{'status'} || '');
		my @points = grep {
			defined $_->{'p'} && defined $_->{'t'} && ($_->{'s'} || '') eq $want
				&& $now - $_->{'t'} <= 10800000
		} @{$history};
		my ($slope, $span, $n, $lo, $hi, $movement) = &battery_slope(\@points);
		if (defined $slope && $want eq 'discharging' && -$slope > 0) {
			my $rate = -$slope;
			$b->{'pph'} = $rate;
			$b->{'pph_lo'} = -$hi if defined $hi && -$hi > 0;
			$b->{'pph_hi'} = -$lo if defined $lo && -$lo > 0;
			$b->{'pph_window'} = $span / 3600000;
			$b->{'pph_points'} = $n;
		}
		elsif (defined $slope && $want eq 'charging' && $slope > 0) {
			# the same slope the other way: how fast the pack is filling
			$b->{'charge_pph'} = $slope;
			$b->{'charge_pph_lo'} = $lo if defined $lo && $lo > 0;
			$b->{'charge_pph_hi'} = $hi if defined $hi && $hi > 0;
			$b->{'charge_window'} = $span / 3600000;
			$b->{'charge_points'} = $n;
		}
		elsif ($want eq 'charging') {
			# A pack with no usable gauge still needs twenty minutes for the
			# regular slope, but integer percentages hide a fast charge for a
			# long time: the last two readings that actually differ, within a
			# quarter of an hour, say enough to show "about an hour". The gauge
			# estimate above, where the pack reports one, stays the better one.
			my @recent = grep { $_->{'t'} >= $now - 900000 } @points;
			if (@recent >= 2) {
				my $last = $recent[-1];
				my ($prev) = reverse grep { $_->{'p'} != $last->{'p'} } @recent;
				if ($prev) {
					my $dt = ($last->{'t'} - $prev->{'t'}) / 3600000;
					my $dp = $last->{'p'} - $prev->{'p'};
					if ($dt > 0 && $dp > 0) {
						$b->{'charge_pph'} = $dp / $dt;
						$b->{'charge_window'} = $dt;
						$b->{'charge_points'} = 2;
						$b->{'charge_quick'} = 1;
					}
				}
			}
		}
		elsif ($want eq 'discharging' && $span >= 7200000 && $movement < 2) {
			# It has not moved enough to measure over two hours: the drain is
			# below the gauge's resolution, so the honest answer is a floor.
			$b->{'pph_flat'} = 1;
			$b->{'pph_window'} = $span / 3600000;
			$b->{'pph_points'} = $n;
		}
	}
	# A gauge can divide by a near-empty reading and return a wild number; keep
	# only a plausible finish time (roughly a minute to ten days). A pack that
	# reports more than ten days is kept at the bound rather than dropped, so
	# the card can say "> ten days" instead of falling back to "estimating".
	foreach my $eta ( qw/charge_eta discharge_eta/ ) {
		next unless defined $b->{$eta};
		if ($b->{$eta} <= 0.01) { $b->{$eta} = undef; }
		elsif ($b->{$eta} > 240) { $b->{$eta} = 240; $b->{'eta_capped'} = 1; }
	}
	# One missed bridge reply must not blank the card. The app can be busy for
	# longer than the read timeout, and device_call then refuses every call for
	# its cooldown; the last good reading is still true, so serve it marked
	# stale instead of reporting a phone with no battery. Ten minutes is the
	# limit: older than that is not a reading worth trusting.
	if (($b->{'source'} // '') eq 'none'
		&& ref $cached eq 'HASH'
		&& ($cached->{'source'} // '') ne 'none'
		&& defined $cached->{'percentage'}
		&& $now - ($cached->{'sampled'} || 0) <= 600000) {
		my %held = %{$cached};
		delete $held{'history'};
		$held{'stale'} = 1;
		$held{'stale_age'} = int(($now - ($cached->{'sampled'} || $now)) / 1000);
		$held{'sampled'} = $now;
		return $battery_sample_memo = \%held;
	}
	# a machine with no battery has nothing worth caching; the Monitor can stat
	# it every poll without a write
	if ($b->{'source'} ne 'none') {
		&battery_eta_estimate($b, $cached);
		my %store = %{$b};
		$store{'history'} = $history;
		&cache_set({ app => '__president', context => 'battery', subcontext => 'current', warranty => '-1d' }, \%store);
	}
	return $battery_sample_memo = $b;
}

# --- House levels -----------------------------------------------------------
# The System card shows one battery line per House machine and per embedded
# board. A machine's own reading is cheap; a peer's is one signed
# /manager/health call, and a board's is its /device_query. Both kinds of I/O
# happen in the levels loop, never in a request: the card renders the cached
# snapshot, so a sleeping watch or a dead peer cannot hold the menu open.
sub embedded_levels_cache {
	my $c = &cache_get({ app => '__president', context => 'levels', subcontext => 'embedded' });
	return (ref $c eq 'HASH' && ref $c->{'devices'} eq 'ARRAY') ? $c : { at => 0, devices => [] };
}

sub embedded_levels_cached {
	return &embedded_levels_cache()->{'devices'} || [];
}

1;
