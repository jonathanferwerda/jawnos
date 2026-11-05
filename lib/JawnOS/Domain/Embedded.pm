package subs;

# Embedded: extracted from subroutines.pl (package subs). Loaded on
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
our $database;
our $device;
our $log;
our %m;

sub embedded_levels_scan {
	# One entry per chip, not per neighbour copy: the deck showed three times
	# (two NICs and lo) when it was listed straight from the neighbour tables.
	# A chip can also be known only to the Bluetooth bridge (chip_ids) - a watch
	# off its WiFi - so both sightings feed the same list.
	my $previous = &embedded_levels_cached();
	my %old = map { ($_->{'chip_id'} || '') => $_ } grep { $_->{'chip_id'} } @{$previous};
	my $ble = &cache_get({ app => '__president', context => 'levels', subcontext => 'ble' });
	$ble = {} unless ref $ble eq 'HASH';
	my $now = &rightNow();
	my %seen;
	my @found;
	# A board answers /device_query on its own firmware port, not on our entry
	# port: PORT_BOARD is the firmware's 3000, so moving PORT_DOCK to PORT_AHOY
	# no longer sends every board probe to a door that does not exist.
	my $default_board_port = $ENV{'PORT_BOARD'} || 3000;
	my $device_rows = &db_select('devices')->hashes || [];
	# The bridge's own sighting is the freshest thing we have for a board off
	# its WiFi; keep it beside the neighbour rows so a phone that holds the
	# watch gets the credit (and the newest sighting wins the host merge).
	my %ble_meta;
	foreach my $row ( @{$device_rows} ) {
		foreach my $c ( @{ (eval { decode_json($row->{'chip_ids'} || '[]') } || []) } ) {
			next unless $c->{'id'};
			my $cur = $ble_meta{$c->{'id'}} || {};
			# A chip can have two sightings in the blob (a bridge record and an
			# older neighbour-derived one); keep the one with the bridge's
			# last-seen/address, not whichever the array happened to end on.
			my $take = !%{$cur}
				|| (($c->{'ble_seen'} || 0) > ($cur->{'ble_seen'} || 0))
				|| (!$cur->{'bluetooth'} && $c->{'bluetooth'});
			$ble_meta{$c->{'id'}} = { %{$cur}, %{$c} } if $take;
		}
	}

	# One reading every five minutes, kept for three hours: the same robust
	# slope the machines use, over the same window, without a row that grows
	# with the cache's warranty. Both the HTTP and the Bluetooth paths land
	# here.
	my $entry = sub {
		my ($d) = @_;
		my $chip = $d->{'chip_id'};
		my $old_row = $old{$chip} || {};
		my @history = @{ (ref $old_row->{'history'} eq 'ARRAY') ? $old_row->{'history'} : [] };
		if ($d->{'online'} && defined $d->{'battery'}) {
			push @history, { t => $now, p => $d->{'battery'} + 0, s => lc($d->{'status'} || '') };
			splice @history, 0, scalar(@history) - 36 if scalar @history > 36;
		}
		my $recent = [ grep { defined $_->{'p'} && defined $_->{'t'} && $now - $_->{'t'} <= 10800000 } @history ];
		my ($pph, $pph_lo, $pph_hi, $pph_window, $pph_points);
		my ($charge_pph, $charge_pph_lo, $charge_pph_hi, $charge_window, $charge_points);
		my $pph_flat;
		my $status_now = lc($d->{'status'} || '');
		if ($status_now eq 'discharging' || $status_now eq 'charging') {
			my @p = grep { ($_->{'s'} || '') eq $status_now } @{$recent};
			my ($slope, $span, $count, $lo, $hi, $movement) = &battery_slope(\@p);
			if (defined $slope) {
				if ($status_now eq 'discharging' && -$slope > 0) {
					$pph = -$slope;
					$pph_lo = -$hi if defined $hi && -$hi > 0;
					$pph_hi = -$lo if defined $lo && -$lo > 0;
					$pph_window = $span / 3600000; $pph_points = $count;
				}
				elsif ($status_now eq 'charging' && $slope > 0) {
					$charge_pph = $slope;
					$charge_pph_lo = $lo if defined $lo && $lo > 0;
					$charge_pph_hi = $hi if defined $hi && $hi > 0;
					$charge_window = $span / 3600000; $charge_points = $count;
				}
			}
			elsif ($status_now eq 'discharging' && $span >= 7200000 && $movement < 2) {
				# Too flat to measure over two hours: a floor, not a number.
				$pph_flat = 1;
				$pph_window = $span / 3600000;
				$pph_points = $count;
			}
		}
		else {
			# Older firmware sends no state; the sign of the slope still says
			# which way the pack is going.
			my ($slope, $span, $count, $lo, $hi) = &battery_slope($recent);
			if (defined $slope) {
				if ($slope < -0.01) {
					$pph = -$slope;
					$pph_lo = -$hi if defined $hi && -$hi > 0;
					$pph_hi = -$lo if defined $lo && -$lo > 0;
					$pph_window = $span / 3600000; $pph_points = $count;
				}
				elsif ($slope > 0.01) {
					$charge_pph = $slope;
					$charge_pph_lo = $lo if defined $lo && $lo > 0;
					$charge_pph_hi = $hi if defined $hi && $hi > 0;
					$charge_window = $span / 3600000; $charge_points = $count;
				}
			}
		}
		my $entry = {
			chip_id => $chip,
			name => $d->{'name'} || $d->{'model'} || $d->{'purpose'},
			model => $d->{'model'} || '',
			purpose => $d->{'purpose'},
			ip => $d->{'ip'} || '',
			bt => $d->{'bt'} || '',
			battery => $d->{'battery'},
			percentage => $d->{'battery'},
			battery_mv => $d->{'mv'},
			status => $d->{'status'},
			link => $d->{'link'} || '',
			history => \@history,
			pph => $pph,
			pph_lo => $pph_lo,
			pph_hi => $pph_hi,
			pph_flat => $pph_flat,
			pph_window => $pph_window,
			pph_points => $pph_points,
			charge_pph => $charge_pph,
			charge_pph_lo => $charge_pph_lo,
			charge_pph_hi => $charge_pph_hi,
			charge_window => $charge_window,
			charge_points => $charge_points,
			online => $d->{'online'} ? 1 : 0,
			seen => $d->{'seen'} || 0,
		};
		&battery_eta_estimate($entry, $old_row);
		return $entry;
	};

	foreach my $row ( @{$device_rows} ) {
		my $address = eval { decode_json($row->{'address'} || '{}') } || {};
		foreach my $nic ( keys %{$address} ) {
			foreach my $n ( @{ $address->{$nic}->{'neigh'} || [] } ) {
				my $purpose = $n->{'purpose'} || '';
				next unless $purpose =~ /^(?:watch|teletype|microcontroller)$/;
				my $chip = $n->{'chip_id'} || '';
				next unless $chip;
				next if $seen{$chip}++;
				my $ip = $n->{'ip'} || '';
				$ip = '' unless $ip =~ /^\d+\.\d+\.\d+\.\d+$/;
				my $bt = $n->{'mac_addresses'}->{'bluetooth'} || $n->{'mac'} || '';
				my ($battery, $mv, $status, $online, $seen_at, $link) = (undef, undef, undef, 0, 0, '');
				if ($ip) {
					my $port = $n->{'PORT_DOCK'} || $default_board_port;
					my $ua = Mojo::UserAgent->new;
					my $res = eval { $ua->connect_timeout(2)->inactivity_timeout(3)->get("http://$ip:$port/device_query")->result };
					if ($res && $res->is_success) {
						my $j = eval { decode_json $res->body } || {};
						$battery = $j->{'battery'} if defined $j->{'battery'};
						$mv = $j->{'battery_mv'} if defined $j->{'battery_mv'};
						$status = lc($j->{'battery_status'} || '') if defined $j->{'battery_status'};
						$online = 1; $seen_at = $now; $link = 'wifi';
					}
				}
				# The bridge's reading wins when it is newer (a board whose WiFi
				# is asleep still answers on the link it is already holding).
				my $b = $ble->{$chip} || {};
				if ($b->{'seen'} && $now - $b->{'seen'} < 900000 && $b->{'seen'} >= $seen_at) {
					$battery = $b->{'battery'} if defined $b->{'battery'};
					$mv = $b->{'battery_mv'} if defined $b->{'battery_mv'};
					$status = $b->{'status'} if defined $b->{'status'} && $b->{'status'} ne '';
					$online = 1; $seen_at = $b->{'seen'}; $link = 'bluetooth';
				}
				my $old_row = $old{$chip} || {};
				my $meta = $ble_meta{$chip} || {};
				$bt ||= $meta->{'bluetooth'} || '';
				$seen_at ||= $meta->{'ble_seen'} || 0;
				# An offline board keeps its last reading: a watch asleep on the
				# charger is still the watch, and a dash would read as "lost".
				$battery = $old_row->{'battery'} unless defined $battery;
				$mv = $old_row->{'battery_mv'} unless defined $mv;
				$status = $old_row->{'status'} unless defined $status;
				$seen_at ||= $old_row->{'seen'} || 0;
				push @found, $entry->({
					chip_id => $chip,
					name => $n->{'name'} || $n->{'model'} || $purpose,
					model => $n->{'model'} || '',
					purpose => $purpose,
					ip => $ip,
					bt => $bt,
					battery => $battery,
					mv => $mv,
					status => $status,
					online => $online,
					seen => $seen_at,
					link => $link,
				});
			}
		}
		# Bridge-only sightings: the watch off its access point has no neighbour
		# row of its own, only the chip the radio named.
		foreach my $c ( @{ (eval { decode_json($row->{'chip_ids'} || '[]') } || []) } ) {
			my $chip = $c->{'id'} || '';
			next unless $chip && !$seen{$chip};
			my $purpose = $c->{'purpose'} || '';
			next unless $purpose =~ /^(?:watch|teletype|microcontroller)$/;
			my $b = $ble->{$chip} || {};
			my $b_fresh = $b->{'seen'} && $now - $b->{'seen'} < 900000;
			my $old_row = $old{$chip} || {};
			next unless $b_fresh || $b->{'seen'} || ($c->{'ble_seen'} && $now - $c->{'ble_seen'} < 900000) || $old_row->{'battery'};
			$seen{$chip} = 1;
			my $battery = $b->{'battery'};
			my $mv = $b->{'battery_mv'};
			my $status = $b->{'status'};
			$battery = $old_row->{'battery'} unless defined $battery;
			$mv = $old_row->{'battery_mv'} unless defined $mv;
			$status = $old_row->{'status'} unless defined $status;
			push @found, $entry->({
				chip_id => $chip,
				name => $c->{'name'} || $old_row->{'name'} || $purpose,
				model => $old_row->{'model'} || '',
				purpose => $purpose,
				ip => '',
				bt => $c->{'bluetooth'} || '',
				battery => $battery,
				mv => $mv,
				status => $status,
				online => $b_fresh ? 1 : 0,
				seen => $b_fresh ? $b->{'seen'} : ($b->{'seen'} || $c->{'ble_seen'} || $old_row->{'seen'} || 0),
				link => $b_fresh ? 'bluetooth' : '',
			});
		}
	}
	&cache_set({ app => '__president', context => 'levels', subcontext => 'embedded', warranty => '-1d' },
		{ at => &rightNow(), devices => \@found });
	return \@found;
}

# The System card asks for quick passes while it is on screen. Rendering the
# card sets this stamp; the levels loop sees it and shortens its interval, so a
# phone plugged in a moment ago shows its new state instead of waiting out the
# two-minute house pass. Rewritten at most every 30s so an open card does not
# write the cache on every refresh.
sub levels_fast_request {
	my $now = &rightNow();
	my $seen = &cache_get({ app => '__president', context => 'levels', subcontext => 'fast' });
	return $seen if $seen && $now - $seen < 30000;
	&cache_set({ app => '__president', context => 'levels', subcontext => 'fast', warranty => '-1d' }, $now);
	return $now;
}

# CPU and RAM for the levels card. A peer's /manager/health answers with the
# same shape, so one reading means one thing across the house.
#
# /proc/stat is the whole machine and the first choice. Android denies it to
# apps, so the fallback sums JawnOS's own processes - the same figure the
# Monitor app shows there - and the reading says so. A cumulative sample lives
# in the cache so a percentage is a real difference over a real window, and so
# every prefork worker reads the same sample instead of guessing from one tick.
sub usage_cpu_sample {
	if (open(my $fh, '<', '/proc/stat')) {
		my $line = <$fh>;
		close $fh;
		if (defined $line && $line =~ /^cpu\s+(.+)$/) {
			my @v = split ' ', $1;
			my $idle = ($v[3] // 0) + ($v[4] // 0);   # idle + iowait
			my $total = 0;
			$total += ($_ // 0) for @v;
			return ($total, $idle, undef, 'system');
		}
	}
	# Android: sum the jiffies of the processes this app can see. Only its own
	# are readable, which is still the answer to "is JawnOS the hot one?".
	my %p;
	foreach my $d (glob('/proc/[0-9]*')) {
		(my $pid = $d) =~ s{.*/}{};
		open(my $sf, '<', "$d/stat") or next;
		my $line = <$sf>;
		close $sf;
		next unless defined $line && $line =~ /\)\s+\S+\s+(.*)$/;
		my @v = split ' ', $1;   # field 3 consumed; utime is field 14, stime 15
		$p{$pid} = ($v[10] // 0) + ($v[11] // 0);
	}
	return (undef, undef, undef, '') unless %p;
	return (undef, undef, \%p, 'jawnos');
}

sub usage_mem_sample {
	my ($total, $avail);
	if (open(my $fh, '<', '/proc/meminfo')) {
		while (my $l = <$fh>) {
			$total = $1 + 0 if $l =~ /^MemTotal:\s+(\d+)/;
			$avail = $1 + 0 if $l =~ /^MemAvailable:\s+(\d+)/;
			last if defined $total && defined $avail;
		}
		close $fh;
	}
	return (undef, undef) unless $total;
	$avail = 0 unless defined $avail;
	my $pct = 100 * ($total - $avail) / $total;
	$pct = 0 if $pct < 0;
	$pct = 100 if $pct > 100;
	return ($pct, $total);
}

sub system_usage_sample {
	my $now = &rightNow();
	my ($mem, $mem_total) = &usage_mem_sample();
	my ($total, $idle, $pids, $scope) = &usage_cpu_sample();
	my $cpu;
	if ($scope ne '') {
		my $stored = &cache_get({ app => '__president', context => 'usage', subcontext => 'cpu' });
		$stored = {} unless ref $stored eq 'HASH';
		my $elapsed = $now - ($stored->{'at'} || 0);
		my $fresh = 0;
		# No usable previous reading (first call, or the scope changed): take a
		# short sample now, so the card has a number on its first read.
		if (!defined $stored->{'at'} || ($stored->{'scope'} || '') ne $scope) {
			my ($t0, $i0, $p0) = ($total, $idle, $pids);
			select(undef, undef, undef, 0.25);
			my ($t1, $i1, $p1, $s1) = &usage_cpu_sample();
			if ($s1 eq $scope) {
				$stored = { at => $now, total => $t0, idle => $i0, pids => (ref $p0 eq 'HASH' ? $p0 : undef), scope => $scope };
				($total, $idle, $pids) = ($t1, $i1, $p1);
				$elapsed = 250;
				$fresh = 1;
			}
		}
		elsif ($elapsed < 500 && defined $stored->{'pct'}) {
			# A burst of card reads over a few milliseconds would only measure
			# noise; answer with the sample already held.
			$cpu = $stored->{'pct'};
		}
		if (!defined $cpu && $elapsed > 0) {
			if ($scope eq 'jawnos') {
				my $old = (ref $stored->{'pids'} eq 'HASH') ? $stored->{'pids'} : {};
				my $sum = 0;
				foreach my $pid (keys %{ $pids || {} }) {
					next unless exists $old->{$pid};
					my $d = $pids->{$pid} - $old->{$pid};
					$sum += $d if $d > 0;
				}
				# 100 jiffies a second per core, as the Monitor app assumes.
				$cpu = 100 * ($sum / 100) / ($elapsed / 1000);
			}
			else {
				my $dt = $total - ($stored->{'total'} || 0);
				my $di = $idle - ($stored->{'idle'} || 0);
				$cpu = $dt > 0 ? 100 * (1 - $di / $dt) : undef;
			}
			if (defined $cpu) { $cpu = 0 if $cpu < 0; $cpu = 100 if $cpu > 100; }
		}
		if (defined $cpu && ($fresh || $elapsed >= 500)) {
			&cache_set({ app => '__president', context => 'usage', subcontext => 'cpu', warranty => '-1h' }, {
				at => $now, total => $total, idle => $idle,
				pids => (ref $pids eq 'HASH' ? $pids : undef),
				scope => $scope, pct => $cpu,
			});
		}
	}
	return {
		cpu => $cpu,
		cpu_scope => $scope,
		mem => $mem,
		mem_total_kb => $mem_total,
		at => $now,
	};
}

sub house_levels_sync {
	my $opts = shift || {};
	my ($connect_timeout, $inactivity_timeout) = $opts->{'fast'} ? (2, 3) : (6, 10);
	my $me = &signatorial_designer();
	my $hostname = `hostname`; chomp $hostname;
	my $embedded_cache = &embedded_levels_cache();
	my $devices = (($embedded_cache->{'at'} || 0) + 300000 > &rightNow())
		? $embedded_cache->{'devices'}
		: &embedded_levels_scan();
	my $previous = &cache_get({ app => '__president', context => 'levels', subcontext => 'current' });
	my %previous_machine = map { ($_->{'signatorial'} || '') => $_ }
		grep { $_->{'signatorial'} } @{ (ref $previous eq 'HASH' ? $previous->{'machines'} : []) || [] };
	my @machines = ({
		signatorial => $me,
		hostname => $hostname,
		device => &device_setter(),
		version => &jawn_version(),
		battery => &battery_sample(),
		usage => &system_usage_sample(),
		embedded => $devices,
		local => 1,
		seen => &rightNow(),
	});
	my ($peers, $failed, $skipped) = (0, 0, 0);
	# Push this machine's own row to the peers, so a handheld that slept through
	# their poll still updates their cards. The pull above cannot reach a phone
	# between its scheduled wakes, and waiting for a poll to coincide with a wake
	# left its tile an hour old. A two-minute stamp keeps the fast (card-open)
	# passes from turning this into a stream.
	my $last_push = &cache_get({ app => '__president', context => 'levels', subcontext => 'pushed' }) || 0;
	my $push = (!$last_push || &rightNow() - $last_push >= 120000) ? 1 : 0;
	my $report = { %{ $machines[0] } };
	delete $report->{'local'};
	&cache_set({ app => '__president', context => 'levels', subcontext => 'pushed', warranty => '-1d' }, &rightNow()) if $push;
	# A failed pull keeps the last row, but a machine that pushed seconds ago is
	# not stale: dim the tile only when the row is a few minutes old, so a phone
	# that updates by push and never answers the poll still reads as current.
	my $keep_previous = sub {
		my ($rsig, $pname) = @_;
		return unless $previous_machine{$rsig};
		my %row = %{ $previous_machine{$rsig} };
		my $seen = $row{'seen'} || 0;
		$row{'stale'} = 1 if !$seen || &rightNow() - $seen > 300000;
		$row{'hostname'} = $pname;
		push @machines, \%row;
	};
	foreach my $rm ( @{ &db_select('remote_machines')->hashes || [] } ) {
		my $rsig = $rm->{'signatorial'} || '';
		next unless $rsig && $rsig ne $me;
		my $recent = (($rm->{'server_time'} || 0) + 15 * 60 * 1000) > &rightNow();
		next unless ($rm->{'connection'} || '') eq 'active' || $recent;
		my ($ua, $p) = &peer_useragent($rm);
		# The manager URL is the name the house knows the machine by
		# (phone.jonathanferwerda.com); the OS hostname is often a bare "Fe" or
		# "localhost". Prefer the URL label, and fall back to the hostname.
		my ($pname) = (($rm->{'manager'} || ($p->{'manager'} || '')) =~ m{^https?://([^/:]+)});
		# Strip a domain only from a name. A dotted-decimal manager is an address,
		# and cutting at its first dot turned every peer reached by ip into "192"
		# on the System card. Keep the address whole, and prefer the name the peer
		# reports when it has one.
		my $host_is_ip = (defined $pname && $pname =~ /^\d{1,3}(?:\.\d{1,3}){3}$/);
		$pname =~ s/\..*$// if defined $pname && $pname ne '' && !$host_is_ip && $pname !~ /:/;
		my $named = $rm->{'hostname'} || '';
		$pname = $named if $host_is_ip && $named ne '' && $named !~ /^(?:localhost|127\.0\.0\.1)$/i;
		$pname = $rm->{'hostname'} || $rsig
			if !defined $pname || $pname eq '' || $pname =~ /^(?:localhost|127\.0\.0\.1)$/i;
		unless ($ua) {
			$keep_previous->($rsig, $pname);
			next;
		}
		# A peer that has stopped answering is not asked every pass: each attempt
		# is a socket and a radio wake, and a phone pays for both. The backoff is
		# per peer and doubles, capped at fifteen minutes; a peer's own announce
		# (/manager/health_report, /manager/available) clears it at once, which is
		# how a machine coming back is noticed without polling for it.
		my $backoff = &cache_get({ app => '__president', context => 'levels_backoff', subcontext => $rsig }) || {};
		my $failures = ($backoff->{'failures'} || 0) + 0;
		my $hold = ($backoff->{'until'} || 0) > &rightNow();
		# the card being open is a person waiting: it may look again past a first
		# blip, but not past a peer that has been gone for several passes
		$hold = 0 if $opts->{'fast'} && $failures <= 2;
		if ($hold) {
			$skipped++;
			$keep_previous->($rsig, $pname);
			next;
		}
		if ($push) {
			eval {
				$ua->connect_timeout($connect_timeout)->inactivity_timeout($inactivity_timeout)
					->post($p->{'manager'} . '/manager/health_report?signatorial=' . $me => json => $report)->result;
			};
		}
		my $res = eval { $ua->connect_timeout($connect_timeout)->inactivity_timeout($inactivity_timeout)
			->get($p->{'manager'} . '/manager/health?signatorial=' . $me)->result };
		my $h = ($res && $res->is_success) ? eval { decode_json $res->body } : undef;
		unless (ref $h eq 'HASH') {
			$failed++;
			$failures++;
			my $delay = 240000 * (2 ** ($failures - 1));
			$delay = 900000 if $delay > 900000;
			&cache_set({ app => '__president', context => 'levels_backoff', subcontext => $rsig, warranty => '+1d' },
				{ failures => $failures, until => &rightNow() + $delay, at => &rightNow() });
			my $err = $@ ? do { my $e = $@; $e =~ s/\s+/ /g; substr($e, 0, 120) } : '';
			$log->info('house levels: ' . $pname . ' '
				. ($res ? ('HTTP ' . $res->code) : 'no answer') . ($err ne '' ? " ($err)" : '')
				. ' - next try in ' . int($delay / 60000) . 'm');
			$keep_previous->($rsig, $pname);
			next;
		}
		# it answered: the next pass asks it again
		if ($failures) {
			&cache_set({ app => '__president', context => 'levels_backoff', subcontext => $rsig, warranty => '+1d' },
				{ failures => 0, until => 0, at => &rightNow() });
		}
		$peers++;
		my $peer_battery = (ref $h->{'battery'} eq 'HASH') ? &battery_gauge_eta($h->{'battery'}) : {};
		# A peer on older code sends the raw pph but not the estimate; fill
		# it in so every row on the card is read the same way. A newer peer's
		# own smoothed figure is left alone.
		&battery_eta_estimate($peer_battery)
			if ref $peer_battery eq 'HASH' && !defined $peer_battery->{'eta_hours'};
		push @machines, {
			signatorial => $rsig,
			hostname => $pname,
			device => $h->{'device'} || $rm->{'device'} || '',
			version => $h->{'version'} || $rm->{'version'} || '',
			battery => $peer_battery,
			usage => (ref $h->{'usage'} eq 'HASH') ? $h->{'usage'} : undef,
			embedded => (ref $h->{'embedded'} eq 'ARRAY') ? $h->{'embedded'} : [],
			seen => &rightNow(),
		};
	}
	# One board can be in several machines' neighbour tables. Keep the copy with
	# a reading and the newest sighting, and name the machine that sees it.
	my $device_list = &levels_devices(\@machines);
	my $snapshot = {
		at => &rightNow(),
		machines => \@machines,
		devices => $device_list,
		peers => $peers,
		failed => $failed,
		skipped => $skipped,
	};
	&cache_set({ app => '__president', context => 'levels', subcontext => 'current', warranty => '-1d' }, $snapshot);
	return $snapshot;
}

# The machine rows' embedded boards, deduplicated: one board may be in several
# machines' neighbour tables. Both the pull (house_levels_sync) and a peer's push
# (health_report) rebuild the list this way, so a pushed row cannot leave the
# boards view disagreeing with the machines.
sub levels_devices {
	my $machines = shift || [];
	my %device;
	foreach my $m ( @{$machines} ) {
		foreach my $d ( @{ $m->{'embedded'} || [] } ) {
			my $chip = $d->{'chip_id'} || $d->{'name'} || '';
			next unless $chip;
			my $cur = $device{$chip};
			my $better = !$cur
				|| (defined $d->{'battery'} && !defined $cur->{'battery'})
				|| (($d->{'seen'} || 0) > ($cur->{'seen'} || 0));
			$device{$chip} = { %$d, host => $m->{'hostname'}, host_signatorial => $m->{'signatorial'} } if $better;
		}
	}
	return [ sort { ($a->{'host'} || '') cmp ($b->{'host'} || '') || ($a->{'name'} || '') cmp ($b->{'name'} || '') } values %device ];
}

# A peer announcing itself is proof it is back. Whatever backoff its silence
# earned is dropped here, so the coming pass asks it again instead of waiting
# out a timer that was set while it was away.
sub levels_peer_announced {
	my ($sig) = @_;
	return 0 unless defined $sig && $sig =~ /^[0-9a-f]{32}$/;
	my $before = &cache_get({ app => '__president', context => 'levels_backoff', subcontext => $sig }) || {};
	&cache_set({ app => '__president', context => 'levels_backoff', subcontext => $sig, warranty => '+1d' },
		{ failures => 0, until => 0, at => &rightNow(), announced => &rightNow() });
	return ($before->{'until'} || 0) > &rightNow() ? 1 : 0;
}

# Tell each recently seen peer "I am awake and my rows have moved; pull me now".
# A phone sleeps between beats, so a peer's own poll usually lands while it is
# away; this is the announcement that lets the peer run its delta pull during
# the seconds the phone is up. Returns how many peers said they need a pull.
sub remote_available_announce {
	my $me = &signatorial_designer();
	my $newest = 0;
	my $digest = &sync_digest_map();
	foreach my $table ( values %{$digest} ) {
		my $max = ($table->{'max'} || 0) + 0;
		$newest = $max if $max > $newest;
	}
	my $pulled = 0;
	my @peers = grep {
		my $rsig = $_->{'signatorial'} || '';
		$rsig && $rsig ne $me
			&& ((($_->{'connection'} || '') eq 'active')
				|| (($_->{'server_time'} || 0) + 15 * 60 * 1000) > &rightNow())
	} @{ &db_select('remote_machines')->hashes || [] };
	# Active peers first: the hold that keeps us up is set when the first peer
	# says it needs the rows, not after the slowest unreachable one has timed out.
	@peers = sort { (($b->{'connection'} || '') eq 'active') <=> (($a->{'connection'} || '') eq 'active') } @peers;
	foreach my $rm ( @peers ) {
		my ($ua, $p) = &peer_useragent($rm);
		next unless $ua;
		my $res = eval {
			$ua->connect_timeout(2)->inactivity_timeout(3)
				->post($p->{'manager'} . '/manager/available?signatorial=' . $me
					=> json => { signatorial => $me, newest => $newest })->result;
		};
		next unless $res && $res->is_success;
		my $h = eval { decode_json $res->body } || {};
		next unless $h->{'pull'};
		$pulled++;
		# A peer is pulling from us now: stay up long enough to answer it.
		&cache_set({ app => '__president', context => 'wake', subcontext => 'hold', warranty => '-1d' }, &rightNow() + 35000);
		&wake_hold_touch();
	}
	return $pulled;
}

# Note that a peer is reading rows from this machine right now. The scheduled
# wake checks this before releasing the CPU: a phone must not sleep in the
# middle of a pull it is serving. The mtime is the signal, and utime updates it
# without rewriting the file, so a multi-batch pull costs no flash writes.
# The Android receiver's hard hold: while this file is fresh it renews the CPU
# lock instead of letting the 45-second scheduled window expire. Touch it when a
# peer is about to pull and for every row batch served; the receiver treats a
# touch within 60s as a lease (the five-minute cap still bounds a runaway peer).
# utime updates only the inode, so a multi-batch pull costs no flash writes.
sub wake_hold_touch {
	my $file = &home('~/.president/wake_hold');
	unless (utime undef, undef, $file) {
		if (open(my $fh, '>', $file)) {
			print $fh &rightNow();
			close $fh;
		}
	}
	return 1;
}

sub sync_pull_touch {
	my $file = &home('~/.president/sync_pull');
	unless (utime undef, undef, $file) {
		if (open(my $fh, '>', $file)) {
			print $fh &rightNow();
			close $fh;
		}
	}
	# A served batch is also the moment the scheduled window must not close.
	&wake_hold_touch();
	return 1;
}

# The card's read: the cached snapshot with this machine's reading refreshed.
# The local battery is cheap and should not wait for the next two-minute pass.
sub levels_snapshot {
	my $snap = &cache_get({ app => '__president', context => 'levels', subcontext => 'current' });
	$snap = { at => 0, machines => [], devices => [] } unless ref $snap eq 'HASH';
	$snap->{'machines'} = [] unless ref $snap->{'machines'} eq 'ARRAY';
	$snap->{'devices'} = [] unless ref $snap->{'devices'} eq 'ARRAY';
	my $me = &signatorial_designer();
	my $local;
	foreach my $m ( @{ $snap->{'machines'} } ) {
		next unless ($m->{'signatorial'} || '') eq $me;
		$local = $m;
		last;
	}
	unless ($local) {
		my $hostname = `hostname`; chomp $hostname;
		$local = { signatorial => $me, hostname => $hostname, device => &device_setter(), version => &jawn_version() };
		unshift @{ $snap->{'machines'} }, $local;
	}
	$local->{'battery'} = &battery_sample();
	$local->{'usage'} = &system_usage_sample();
	$local->{'seen'} = &rightNow();
	$local->{'local'} = 1;
	delete $local->{'stale'};
	return $snap;
}

sub restore_list {
	my $returner = [];
	my @backups;
	# One database, one backup directory: it no longer varies by caller (start_dir
	# is gone from this path), so the install's own backups dir is the list.
	my $directory = &subs::backups_dir() . '/';
	if ($directory && $directory =~ /\/$/) {
		my $backup_ls = `ls -t $directory`;
		@backups = split "\n", $backup_ls;
		foreach my $b (@backups) {
			$b = $directory . $b;
		}
	}

	foreach my $b (@backups) {
		my @stat = stat $b ;
		# one fixed database: the decrypted copy no longer sits beside its backup,
		# so "open" marks the current snapshot (initial.enc), not a sibling .db
		my $archive = $b =~ /_\d+\.enc$/ ? 'archive' : 'current';
		my $status = $archive eq 'current' ? 'open' : 'closed';

		my $size = sprintf('%.2f', ( $stat[7] / 1024 )) . 'kb';
		my $created = localtime($stat[9] )->strftime('%A %B %d %Y - %I:%M:%S%P %Z');
		(my $name = $b) =~ s{.*/}{};
		push @{$returner}, { archive => $archive, status => $status, directory => $directory, filename => $b, name => $name, size => $size, created => $created, blocks => $stat[12] };
	}

	return $returner;
}

1;
