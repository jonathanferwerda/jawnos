package subs;

# Sync: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Crypt::Simple;
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
use Sereal::Decoder qw(decode_sereal);
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $device;
our %m;
our %note_cipher_specs;
our %note_key_material;
# Whether one standard can be sealed and opened again on this machine. The
# in-process families answer from the table; the openssl-only ones are probed
# once (a tiny round trip) and memoised for the life of the worker.
our %note_standard_supported;

sub sync_plan {
	my ($mine, $theirs, $above, $seen, $bands) = @_;
	return undef unless ref $mine eq 'HASH' && ref $theirs eq 'HASH';
	$seen ||= {};
	my %plan;
	foreach my $t ( keys %{$theirs} ) {
		my $a = $mine->{$t} || {};
		my $b = $theirs->{$t} || {};
		my ($ac, $bc) = (($a->{'count'} || 0) + 0, ($b->{'count'} || 0) + 0);
		my ($as, $bs) = (($a->{'sum'} || 0) + 0, ($b->{'sum'} || 0) + 0);
		my ($am, $bm) = (($a->{'max'} || 0) + 0, ($b->{'max'} || 0) + 0);
		next if $ac == $bc && $as == $bs && $am == $bm;
		# The picture we last reconciled with this peer. An unchanged picture is
		# skipped outright; when it has moved, the *change* is measured against
		# this baseline, not against our own table. Comparing with our table made
		# a peer that holds fewer rows (the union already landed here) look
		# divergent on every write forever: the count difference never matched
		# the rows above our newest, so every appointment asked for the whole
		# 110k-row table again.
		my $s = $seen->{$t};
		my $seen_count = (ref $s eq 'HASH') ? ($s->{'count'} || 0) : 0;
		my $seen_sum = (ref $s eq 'HASH') ? ($s->{'sum'} || 0) : 0;
		my $seen_max = (ref $s eq 'HASH') ? ($s->{'max'} || 0) : 0;
		my $seen_full = (ref $s eq 'HASH' && $s->{'full'}) ? 1 : 0;
		# Settings are judged on their own terms. The durable count is not
		# comparable with our table - the merge stores a peer's values under the
		# local device class, so the two counts differ permanently - and comparing
		# them either suppressed a real change or asked for the whole table. Judge
		# this table only against the peer's own last reconciled picture.
		if ($t eq 'settings_durable') {
			next if ref $s eq 'HASH' && $seen_full
				&& $seen_count == $bc
				&& $seen_sum == $bs
				&& $seen_max == $bm;
			my $since;
			if ($bm > $am) {
				# A forward delta names its rows exactly; no map needed.
				$since = $am;
			}
			elsif (!$seen_full) {
				# Never reconciled whole: ask for the whole picture. The pull stores the
				# peer's map and reads only the bands that differ, so this is a band walk,
				# not a whole-table copy.
				$since = 0;
			}
			elsif (ref $s eq 'HASH' && ref $s->{'buckets'} eq 'HASH' && scalar keys %{ $s->{'buckets'} }) {
				# A baseline map lets the pull read only the bands that moved.
				$since = 0;
			}
			else {
				# Reconciled before this code could store a map. A peer that can answer
				# one is asked for the whole picture so the pull can localise it; an
				# older peer gets a bounded window, which is the safe answer.
				$since = $bands ? 0 : $am - 600000;
			}
			$plan{'settings'} = $since;
			next;
		}
		next if ref $s eq 'HASH' && $seen_full
			&& $seen_count == $bc
			&& $seen_sum == $bs
			&& $seen_max == $bm;
		my $since;
		# A small divergence is not worth copying a whole table: the watermark
		# catches new rows, and a migration (full=1) or the nightly pass can
		# reconcile the few old ones later. 500 rows is a guard, not a rule.
		my $small = 500;
		# The peer's rows above our newest are a clean forward delta only when they
		# account for the whole difference. The handshake's `above` counts them at
		# the cut this machine sent, so what is left (total minus above) is what the
		# peer holds at or below our newest. Equal to ours means the delta is the
		# whole story; otherwise an old row is hiding under the watermark and only
		# a band walk can name it. Without `above` the watermark keeps its old
		# authority.
		my $above_count = (ref $above->{$t} eq 'HASH') ? ($above->{$t}->{'count'} || 0) : undef;
		my $above_sum = (ref $above->{$t} eq 'HASH') ? ($above->{$t}->{'sum'} || 0) : undef;
		my $delta_whole = 0;
		if ($bm > $am) {
			$delta_whole = (!defined $above_count || (($bc - $above_count) == $ac && ($bs - $above_sum) == $as)) ? 1 : 0;
		}
		# Watermark first: anything newer than our newest row is a forward delta,
		# whatever the handshake's above-count says. The count is advisory and can
		# be zero while the peer plainly holds a newer row.
		if ($bm > $am) {
			# A delta that leaves an old row behind is read by band instead, so the
			# newer rows and the missed one arrive in the same pull.
			$since = ($bands && !$delta_whole) ? 0 : $am;
		}
		# A peer that can answer a band map is asked to localise whatever the
		# watermark cannot name - including the handful of old rows the small-gap
		# guard used to leave behind forever. One sealed map request names the
		# blocks that moved, so this costs a band, not the whole table.
		elsif ($bands) {
			$since = 0;
		}
		# An older peer cannot localise. The peer is behind or level and holds no
		# more rows than we do, so there is nothing the watermark can name; do not
		# rebuild the table for it.
		elsif ($bm <= $am && $bc <= $ac) {
			next;
		}
		# It holds a few more rows and the gap is small. A full copy of 110k rows
		# to find a handful is what ran the CPU hot every few minutes.
		elsif ($bm <= $am && ($bc - $ac) <= $small) {
			next;
		}
		# A real gap we have never read whole: read it once. The flag then
		# makes the cheap paths above the rule.
		elsif (!$seen_full) {
			$since = 0;
		}
		# Its newest is recent: a bounded window covers rows written a few seconds
		# below our max by a concurrent writer, without the full table.
		elsif ($bm >= $am - 600000) {
			$since = $am - 600000;
		}
		else {
			$since = 0;
		}
		my $key = ($t eq 'settings_durable') ? 'settings' : $t;
		$plan{$key} = $since;
	}
	return \%plan;
}

sub sync_map_encode {
	my ($map) = @_;
	return '' unless ref $map eq 'HASH';
	return join ',', map { $_ . ':' . int($map->{$_} || 0) }
		sort grep { /^[A-Za-z0-9_]+$/ } keys %{$map};
}

sub sync_map_decode {
	my ($text) = @_;
	my %map;
	return \%map unless defined $text && length $text;
	foreach my $pair ( split /,/, $text ) {
		my ($t, $v) = split /:/, $pair, 2;
		next unless defined $t && $t =~ /^[A-Za-z0-9_]+$/;
		next unless defined $v && $v =~ /^[0-9]+$/;
		$map{$t} = $v + 0;
	}
	return \%map;
}

sub sync_job_start {
	my ($data) = @_;
	$data ||= {};
	my $uuid = $data->{'uuid'} || &random_string_creator(24);
	my $now = &rightNow();
	&db_query('delete from sync_jobs where cast(updated as integer) < ?', $now - 86400000);
	&db_query('insert or replace into sync_jobs (uuid,direction,peer,phase,current,total,state,note,steps,started,updated) values (?,?,?,?,?,?,?,?,?,?,?)',
		$uuid, ($data->{'direction'} || ''), ($data->{'peer'} || ''), ($data->{'phase'} || 'starting'),
		($data->{'current'} || 0), ($data->{'total'} || 0), ($data->{'state'} || 'running'),
		($data->{'note'} || ''), '[]', $now, $now);
	return $uuid;
}

sub sync_job_step {
	my ($uuid, $key, $data) = @_;
	return unless $uuid && defined $key && $key ne '';
	$data ||= {};
	my $row = &db_query('select steps from sync_jobs where uuid = ?', $uuid)->hashes->[0] || {};
	my $steps = eval { decode_json($row->{'steps'} || '[]') } || [];
	my ($step) = grep { ref $_ eq 'HASH' && ($_->{'key'} || '') eq $key } @{$steps};
	unless ($step) {
		$step = { key => $key, label => $key, current => 0, total => 0, state => 'running', note => '' };
		push @{$steps}, $step;
	}
	foreach my $k ( qw/label current total state note/ ) {
		$step->{$k} = $data->{$k} if exists $data->{$k};
	}
	&db_query('update sync_jobs set steps = ?, phase = ?, updated = ? where uuid = ?',
		encode_json($steps), ($data->{'label'} || $step->{'label'} || $key), &rightNow(), $uuid);
	return $step;
}

# A tree that dies mid-pull leaves its job row 'running': only a clean
# Jawn::SyncJob exit writes the final state, and a SIGKILL or a tree restart
# skips it. At boot no worker from the old tree can still own a job, so age out
# the plainly abandoned ones. The 30-minute bound matches the remote_upgrade
# lock, so a genuinely long pull is not cut short if its owner somehow survived.
sub sync_jobs_reap {
	my ($age_ms, $direction, $note) = @_;
	$age_ms = 30 * 60 * 1000 unless defined $age_ms && $age_ms =~ /^\d+$/;
	$note = 'interrupted by restart' unless defined $note && $note ne '';
	my $now = &rightNow();
	my $cut = $now - $age_ms;
	my @where = ('state = ?', 'cast(updated as integer) < ?');
	my @args = ('running', $cut);
	if (defined $direction && $direction ne '') {
		push @where, 'direction = ?';
		push @args, $direction;
	}
	my $scope = join ' and ', @where;
	my $row = &db_query("select count(*) as c from sync_jobs where $scope", @args)->hashes->[0] || {};
	my $n = $row->{'c'} || 0;
	return 0 unless $n;
	# Leave `updated` alone: it is when the job last actually ran, and moving it to
	# now made a reaped job look like the newest activity in the panel.
	&db_query("update sync_jobs set state = ?, note = ? where $scope",
		'failed', $note, @args);
	return $n;
}

sub sync_job_finish {
	my ($uuid, $state, $note) = @_;
	return unless $uuid;
	$state ||= 'done';
	my $now = &rightNow();
	# Settle any bar still open, so a failed job does not leave a table reading
	# "running" in the panel after the dot has already shown a red cross.
	my $row = &db_query('select steps from sync_jobs where uuid = ?', $uuid)->hashes->[0] || {};
	my $steps = eval { decode_json($row->{'steps'} || '[]') } || [];
	foreach my $step ( @{$steps} ) {
		next unless ref $step eq 'HASH';
		if (($step->{'state'} || '') eq 'running') {
			$step->{'state'} = $state;
			$step->{'current'} = $step->{'total'} if $state eq 'done';
		}
	}
	&db_query('update sync_jobs set state = ?, phase = ?, note = ?, steps = ?, current = total, updated = ? where uuid = ?',
		$state, $state, ($note || ''), encode_json($steps), $now, $uuid);
}

sub sync_job_list {
	my ($limit) = @_;
	$limit ||= 10;
	# A worker that died mid-sync leaves its row 'running'; after ten minutes
	# nobody is coming back for it, so show it as interrupted rather than a dot
	# that rings forever.
	&db_query(q{update sync_jobs set state = 'failed', phase = 'failed', note = 'interrupted' where state = 'running' and cast(updated as integer) < ?}, &rightNow() - 1800000);
	my $rows = [ @{ &db_query('select * from sync_jobs order by cast(updated as integer) desc limit ?', $limit)->hashes || [] } ];
	foreach my $r ( @{$rows} ) {
		$r->{'steps'} = eval { decode_json($r->{'steps'} || '[]') } || [];
		if (($r->{'total'} || 0) > 0) {
			$r->{'percent'} = int(($r->{'current'} || 0) / $r->{'total'} * 100);
		}
		elsif (scalar @{ $r->{'steps'} }) {
			# A serve job counts progress in its steps (one per table) rather
			# than in current/total, which belongs to the pull's table count.
			my $done = grep { ($_->{'state'} || '') eq 'done' } @{ $r->{'steps'} };
			$r->{'percent'} = int(($done / scalar(@{ $r->{'steps'} })) * 100);
		}
		else {
			$r->{'percent'} = (($r->{'state'} || '') eq 'done') ? 100 : 0;
		}
		$r->{'percent'} = 100 if $r->{'percent'} > 100;
	}
	return $rows;
}

sub sync_job_active {
	my ($limit) = @_;
	return [ grep { ($_->{'state'} || '') eq 'running' } @{ &sync_job_list($limit || 4) } ];
}
{
	package Jawn::SyncJob;
	sub new { my ($class, $uuid) = @_; return bless { uuid => $uuid, done => 0 }, $class; }
	sub done { my ($self, $state, $note) = @_; $state ||= 'done'; $self->{'state'} = $state; &subs::sync_job_finish($self->{'uuid'}, $state, $note); $self->{'done'} = 1; }
	sub DESTROY { my $self = shift; &subs::sync_job_finish($self->{'uuid'}, 'failed', 'sync ended without a result') unless $self->{'done'}; }
}

# The peer picture we have already reconciled, per table. Storing it after a
# successful pull turns "this table diverges" into "this exact picture has
# already been read", so a peer that is merely behind us is not full-read every
# tick while a peer that changed (the offline row) is read once more.
sub sync_seen_get {
	my ($peer) = @_;
	return {} unless $peer;
	my $row = &db_query('select data from cache where context = ? and subcontext = ? order by cast(server_time as integer) desc limit 1', 'sync_seen', $peer)->hashes->[0];
	return {} unless $row && $row->{'data'};
	# New rows are JSON: it has no NULs, so an older DBD cannot truncate it at the
	# first NUL the way it does a Sereal blob. Fall back to Sereal for rows written
	# before this change (a newer DBD stored those whole).
	my $d = eval { decode_json($row->{'data'}) };
	return $d if ref $d eq 'HASH';
	my $old = eval { decode_sereal($row->{'data'}) };
	return (ref $old eq 'HASH') ? $old : {};
}

sub sync_seen_set {
	my ($peer, $digest) = @_;
	return unless $peer && ref $digest eq 'HASH';
	my $dev = &device_setter();
	# JSON, not Sereal: `cache_set` would encode a Sereal blob whose header has a
	# NUL at byte 5, and the older DBD on this box binds that at the NUL - the map
	# arrived as a 5-byte header and the planner lost its baseline every tick.
	&db_query('delete from cache where app = ? and context = ? and subcontext = ? and device = ?', '__president', 'sync_seen', $peer, $dev);
	&db_insert('cache', {
		app => '__president',
		context => 'sync_seen',
		subcontext => $peer,
		data => encode_json($digest),
		timestamp => &rightNow(),
		server_time => &rightNow(),
		warranty => &ago_calc('-10d', &rightNow()),
		device => $dev,
		uuid => &random_string_creator(25)
	});
}

# A peer that told us it was busy gets a short rest instead of being asked again
# on every tick. The cache is machine-local (and forbidden from the export).
sub sync_backoff_active {
	my ($peer) = @_;
	return 0 unless $peer;
	my $row = &db_query('select server_time from cache where context = ? and uuid = ? order by cast(server_time as integer) desc limit 1', 'sync_backoff', $peer)->hashes->[0];
	return ($row && $row->{'server_time'} > &rightNow()) ? 1 : 0;
}

sub sync_backoff_set {
	my ($peer, $seconds) = @_;
	return unless $peer;
	&db_query('delete from cache where context = ? and uuid = ?', 'sync_backoff', $peer);
	&db_query('insert into cache (uuid, context, app, server_time, timestamp) values (?,?,?,?,?)', $peer, 'sync_backoff', '__president', &rightNow() + ($seconds || 120) * 1000, &rightNow());
}

sub sync_backoff_clear {
	my ($peer) = @_;
	return unless $peer;
	&db_query('delete from cache where context = ? and uuid = ?', 'sync_backoff', $peer);
}

# A sync pass starts at most one pull: the marker holds the slot until the
# forked child claims it. Roster order therefore decides who gets to sync, and
# a busy first peer (the laptop in daily use) takes every pass while a peer that
# has been behind for days never gets a turn. Order the pass by the last
# confirmed pull instead: the peer with the oldest watermark (or none at all)
# goes first. Ties are broken by signatorial so the order is stable.
sub sync_peer_order {
	my ($machines, $synced_at) = @_;
	$synced_at ||= {};
	return [
		sort {
			($synced_at->{$a->{'signatorial'} || ''} || 0)
				<=> ($synced_at->{$b->{'signatorial'} || ''} || 0)
				|| (($a->{'signatorial'} || '') cmp ($b->{'signatorial'} || ''))
		} @{ $machines || [] }
	];
}

# This machine's pull marker. The value is either
#   running:<pid>   a forked pull that owns the work, or
#   running:claim   a caller's claim made just before it forks, or
#   <anything else> idle ('' or the panel's 'inactive').
# Mojo::IOLoop::subprocess forks on the next tick, not when subprocessor is
# called, so a claim is written before any child exists. If that tick never
# happens - a tree restart, a torn-down loop, a failed fork - the claim used to
# keep the marker looking like a live owner (it carried the caller's pid, and a
# long-lived worker's pid never dies), which blocked every automatic pull for
# the full thirty-minute bound and made the Upgrade button answer "already
# running". A claim now gets its own short bound; only a real pid, still alive,
# holds the long one.
sub remote_upgrade_marker_state {
	my ($value, $server_time, $now, $alive) = @_;
	$value = '' unless defined $value;
	$server_time = 0 unless defined $server_time && $server_time =~ /^\d+$/;
	$now = &rightNow() unless defined $now;
	my ($flag, $pid) = split /:/, $value, 2;
	$flag ||= '';
	$pid = '' unless defined $pid;
	my $is_pid = ($pid =~ /^\d+$/ && $pid > 1) ? 1 : 0;
	my $live = ($flag eq 'running' && $is_pid && $alive) ? 1 : 0;
	# 'claim' (or a bare 'running' from an older build) cannot be checked with
	# kill 0, so it is a claim with the short bound.
	my $claim = ($flag eq 'running' && !$is_pid) ? 1 : 0;
	my $age = $now - $server_time;
	my $bound = $claim ? 120000 : ($live ? 1800000 : 600000);
	my $busy = ($flag eq 'running' && ($claim || $live) && $age < $bound) ? 1 : 0;
	return {
		flag => $flag,
		pid => $pid,
		live => $live,
		claim => $claim,
		age => $age,
		bound => $bound,
		busy => $busy,
		value => $value,
		server_time => $server_time,
	};
}

sub remote_upgrade_lock_state {
	my $row = &db_query('select value,server_time from settings where app = ? and setting = ? order by cast(server_time as integer) desc limit 1', '__president', 'remote_upgrade')->hashes->[0] || {};
	my $value = $row->{'value'} || '';
	my ($flag, $pid) = split /:/, $value, 2;
	$flag ||= '';
	my $alive = ($flag eq 'running' && defined $pid && $pid =~ /^\d+$/ && $pid > 1 && kill(0, $pid)) ? 1 : 0;
	return &remote_upgrade_marker_state($value, $row->{'server_time'}, &rightNow(), $alive);
}

# A pull killed by an app update or a tree restart leaves this marker behind,
# and every peer then hears "merging" and skips this machine's newer rows until
# the age bound expires (the phone hid six appointments this way, 2026-10-31).
# At boot nothing from a previous life can still be pulling, so a marker that no
# live process owns may be dropped at once instead of waiting out the bound.
# A live pid, a fresh claim, or an empty marker keeps its place.
sub remote_upgrade_marker_reapable {
	my ($up) = @_;
	$up ||= {};
	return 0 unless length($up->{'value'} || '');
	return $up->{'busy'} ? 0 : 1;
}

# --- durable deletion tombstones -------------------------------------------
# A deletion is permanent for any machine that has not yet seen it. Each
# tombstone carries a monotonic id; a machine only drops a tombstone once every
# remote machine has *confirmed* reading past it (sync_cursors), so a desktop
# left off for weeks still receives the whole backlog when it reconnects. The
# owner advances a reader's cursor only from the cursor that reader sends on its
# next request, so a lost response can never purge a deletion early.
sub tombstone_writer {
	my $data = shift;
	&db_insert('sync_log', {
		server_time => &subs::rightNow(),
		signatorial => &subs::signatorial_designer(),
		tbl => $data->{'table'},
		app => $data->{'app'},
		uuid => $data->{'uuid'},
		scope => $data->{'scope'},
		additional => (ref $data->{'additional'} ? encode_json($data->{'additional'}) : $data->{'additional'}),
	});
	return &tombstone_max();
}

sub tombstones_since {
	my $cursor = shift;
	$cursor = 0 unless defined $cursor && $cursor =~ /^[0-9]+$/;
	return &db_query('select * from sync_log where id > ? order by id asc', $cursor)->hashes || [];
}

sub tombstone_max {
	my $row = &db_query('select coalesce(max(id),0) as m from sync_log')->hashes->[0];
	return ($row->{'m'} || 0) + 0;
}

# Drop tombstones every known machine has confirmed reading. With no remote
# machines there is nothing to sync, so the log clears wholesale; if any machine
# has never confirmed (no cursor yet) the whole backlog is kept.
#
# File-scope tombstones stay: a peer reads the log to advance its cursor, but an
# older peer has no file-scope deletion (the entry carried no file uuid before),
# so "confirmed reading" does not mean "applied". Keeping these rows is what
# stops a peer that still carries the attachment from handing it back on every
# pull; they are few, and a peer on current code applies them when it reads them.
sub tombstone_purge {
	my $rms = &db_select('remote_machines', ['signatorial'])->hashes || [];
	if (!scalar @{$rms}) { &db_query('delete from sync_log'); return; }
	my $floor;
	foreach my $rm ( @{$rms} ) {
		my $row = &db_query('select cursor from sync_cursors where signatorial = ?', $rm->{'signatorial'})->hashes->[0];
		my $c = $row && $row->{'cursor'};
		return unless defined $c && $c =~ /^[0-9]+$/;
		$floor = $c if !defined $floor || $c < $floor;
	}
	&db_query("delete from sync_log where id <= ? and coalesce(scope, '') <> 'file'", $floor) if defined $floor && $floor > 0;
}

sub sms_list_check {
my $returner = '';
	if ($device eq 'mobile') {
		my $timestamp = &subs::rightNow();
		my $c = &subs::controller_builder();
		my $suds = &suds_grabber();
		my $bridge_sms = &subs::device_call('sms.list', { limit => 10 });
		my $list = ($bridge_sms && ref $bridge_sms->{'messages'} eq 'ARRAY')
			? $bridge_sms->{'messages'}
			: [];
		foreach my $l (grep { $_->{'type'} eq 'draft' || $_->{'type'} eq 'sent' || $_->{'type'} eq 'inbox' } @{$list}) {
			my $time = &subs::epoch_or_span($l->{'received'},$timestamp);
			my $phone = $l->{'number'};
			$phone =~ s/\D+//gi;
			$phone =~ s/^1//;
			next unless $phone;
			$returner .= "Phone is " . $phone . "\n";
			# the person the number belongs to; a stranger's number becomes an app
			# of its own, so their texts land somewhere and naming the app later
			# turns the stranger into a person
			my $app = &subs::phone_number_app($phone);
			next unless $app;
			my $chats = &subs::db_select('mailbox', undef, { phone => $phone, timestamp => $time })->hashes;
			if ( scalar @{$chats} == 0) {
				$l->{'body'} =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]+//g;
				my $message = &subs::note_encrypter($suds,$l->{'body'});
				my $sender = &subs::format_name($app);
				my $suuid = &subs::random_string_creator(44);
				&subs::db_insert('mailbox', {
					uuid => $suuid,
					timestamp => $time,
					server_time => &subs::rightNow(),
					body => $l->{'body'}, #$message,
					manager_file => $sender,
					status => 'public', #$l->{'type'},
					phone => $phone,
				});
				# the telephone accepted a message: the browsers hear about it
				&subs::mail_arrival({
					c => $c,
					uuid => $suuid,
					phone => $phone,
					manager_file => $sender,
					body => $l->{'body'},
					status => 'public'
				});
			}

			my $q = &subs::db_query('select * from appointments where app = ? and type = ? and timestamp = ?', $app,'sms',$time);
			my $qu = $q->hashes;
			if ( scalar @{$qu} == 0 ) {
				$l->{'body'} =~ s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]+//g;
				$returner .= "Phone: " . $phone . " - " . $app . "\n";
				&Manager::appointment_writer($c,{
					app => &subs::unformat_name($app),
					timestamp => $time || $timestamp,
					type => 'sms',
					notes => &subs::note_encrypter($suds,&subs::format_name($l->{'type'}) . ": " . $l->{'body'}),
					duration => 5000
				});
			}
			else {
				$returner .= "Seen " . $phone . " at " . $l->{'received'} . " from " . $app . " already\n";
			}
		}
	}
	return $returner;
}

sub encrypter {
	my ($secret,$content) = @_;
	local *encrypt;
	local *decrypt;
	Crypt::Simple->import(passphrase => $secret);
	my $notes = eval { encrypt($content) };
	return $notes;
}

sub decrypter {
	my ($secret,$content) = @_;
	my ($notes,$ok);
	{
		local *encrypt;
		local *decrypt;
		Crypt::Simple->import(passphrase => $secret);
		$ok = eval { $notes = decrypt($content); 1 };
	}
	unless ($ok) {
		# Legacy data was written by an older `use Crypt::Simple passphrase => $undef`,
		# which keyed everything off an empty passphrase. Fall back so it stays readable.
		local *encrypt;
		local *decrypt;
		Crypt::Simple->import(passphrase => undef);
		$notes = eval { decrypt($content) };
	}
	return $notes;
}

# ---- note encryption ---------------------------------------------------------
#
# A note is sealed in two layers: an inner cipher - an openssl `enc` container
# ("Salted__" + an 8-byte salt + the ciphertext), keyed by PBKDF2-HMAC-SHA256 of
# the secret - and an outer Crypt::Simple layer keyed by the same secret. The
# standard travels inside the payload, so a note written under any standard still
# reads back.
#
# The inner cipher runs in-process for the AES family (through CryptX) and falls
# back to the openssl binary for the rest; both produce the identical container,
# so notes are interchangeable either way. The old pipeline forked base64 and
# openssl for every single note - tens of milliseconds each, which is why a page
# of mail took seconds - this one costs microseconds.

# The standards the Encryption Standard setting offers. Everything here is
# filtered by what this machine can actually run (see note_standard_supported),
# so the Configure list never offers a cipher that would write letters nobody can
# read back. A standard not listed can still be read: the openssl fallback accepts
# any cipher that binary knows.
sub note_encryption_standards {
	my @offered = (
		'aes-256-ctr', 'aes-192-ctr', 'aes-128-ctr',
		'aes-256-cbc', 'aes-192-cbc', 'aes-128-cbc',
		'camellia-256-ctr', 'camellia-192-ctr', 'camellia-128-ctr',
		'camellia-256-cbc', 'camellia-192-cbc', 'camellia-128-cbc',
		'des-ede3-cbc', 'sm4-cbc',
		'chacha20', 'aria-256-cbc',
	);
	return [ grep { &note_standard_supported($_) } @offered ];
}

sub note_standard_supported {
	my ($standard) = @_;
	return undef unless defined $standard && length $standard;
	return $note_standard_supported{$standard} if exists $note_standard_supported{$standard};
	my $spec = &note_cipher_spec($standard);
	my $ok = eval {
		if ($spec) {
			# the cipher is in-process: prove this build can construct it
			$spec->{'family'} eq 'ctr' ? &note_ctr_mode($spec) : &note_cbc_mode($spec);
			return 1;
		}
		my $probe = &note_seal_container('jawnos', 'jawnos', $standard);
		return 0 unless defined $probe && length $probe;
		my $plain = &note_open_container($probe, 'jawnos', $standard);
		return (defined $plain && $plain eq 'jawnos') ? 1 : 0;
	};
	$note_standard_supported{$standard} = $ok ? 1 : 0;
	return $note_standard_supported{$standard};
}

sub note_cipher_spec {
	my ($standard) = @_;
	my $f = $note_cipher_specs{$standard} or return undef;
	return { family => $f->[0], cipher => $f->[1], keylen => $f->[2], ivlen => $f->[3] };
}

sub note_encryption_standard {
	my $standard = &setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
	return $standard if grep { $_ eq $standard } @{ &note_encryption_standards() };
	return $standard if &note_cipher_spec($standard);
	return 'aes-256-ctr';
}

sub note_kdf {
	my ($secret, $salt, $len) = @_;
	require Crypt::KeyDerivation;
	return Crypt::KeyDerivation::pbkdf2($secret, $salt, 10000, 'SHA256', $len);
}

sub note_ctr_mode { my ($spec) = @_; require Crypt::Mode::CTR; return Crypt::Mode::CTR->new($spec->{'cipher'}, 1, $spec->{'ivlen'}); }

sub note_cbc_mode { my ($spec, $nopad) = @_; require Crypt::Mode::CBC; return Crypt::Mode::CBC->new($spec->{'cipher'}, $nopad ? 0 : 1); }

sub note_key_material {
	my ($secret, $salt, $spec) = @_;
	return undef unless defined $secret && defined $salt;
	my $memo_key = join "\x1f", $spec->{'cipher'}, $spec->{'keylen'}, $spec->{'ivlen'}, &md5_sum($secret), $salt;
	return $note_key_material{$memo_key} if $note_key_material{$memo_key};
	my $len = $spec->{'keylen'} + $spec->{'ivlen'};
	my $kiv = eval { &note_kdf($secret, $salt, $len) };
	return undef unless defined $kiv && length $kiv == $len;
	my $key = substr($kiv, 0, $spec->{'keylen'});
	my $iv = substr($kiv, $spec->{'keylen'}, $spec->{'ivlen'});
	%note_key_material = () if scalar(keys %note_key_material) >= 512;
	$note_key_material{$memo_key} = { key => $key, iv => $iv };
	return $note_key_material{$memo_key};
}

sub note_random_salt {
	return Crypt::PRNG::random_bytes(8) if eval { require Crypt::PRNG; 1 };
	open(my $fh, '<', '/dev/urandom') or return undef;
	my $bytes; read($fh, $bytes, 8); close $fh;
	return $bytes;
}

# Run openssl over bytes held in memory. The input goes through a temp file, not
# a pipe pair: with two pipes the parent writes the container into the child's
# stdin while the child writes the answer back, and once either buffer fills
# both sides wait forever. (This only bit the openssl fallback; AES and the other
# in-process ciphers never spawn a process.)
sub note_openssl_run {
	my ($args, $input, $secret) = @_;
	return undef unless defined $secret && length $secret;
	require File::Temp;
	require File::Spec;
	# The passphrase goes in a 0600 temp file, never in argv: a `-k` leaves the
	# house key visible in `ps` for the life of the child.
	my ($pfh, $ppath) = eval { File::Temp::tempfile('jawnos-pass-XXXXXX', DIR => File::Spec->tmpdir, UNLINK => 0) };
	return undef unless $pfh && defined $ppath;
	binmode $pfh;
	print $pfh $secret;
	close $pfh;
	my ($fh, $path) = eval { File::Temp::tempfile('jawnos-enc-XXXXXX', DIR => File::Spec->tmpdir, UNLINK => 0) };
	if (!$fh || !defined $path) { unlink $ppath; return undef }
	binmode $fh;
	print $fh $input;
	close $fh;
	my @cmd = (@{$args}, '-pass', 'file:' . $ppath, '-in', $path);
	my $result;
	if (open(my $out, '-|', @cmd)) {
		binmode $out;
		$result = do { local $/; <$out> };
		close $out;
	}
	my $ok = $? == 0;
	unlink $path, $ppath;
	return undef unless $ok;
	return $result;
}

# openssl enc over files, with the passphrase in a 0600 temp file. Returns 1 on
# success and 0 on failure. $quiet keeps a wrong-password "bad decrypt" out of
# the log when a caller is walking a credential history.
sub openssl_file_crypt {
	my ($mode, $standard, $secret, $in_path, $out_path, $nopad, $quiet) = @_;
	return 0 unless defined $secret && length $secret && defined $in_path && defined $out_path;
	require File::Temp;
	require File::Spec;
	my ($pfh, $ppath) = eval { File::Temp::tempfile('jawnos-pass-XXXXXX', DIR => File::Spec->tmpdir, UNLINK => 0) };
	return 0 unless $pfh && defined $ppath;
	binmode $pfh;
	print $pfh $secret;
	close $pfh;
	my @args = ('openssl', 'enc', $mode eq 'd' ? '-d' : '-e', '-pass', 'file:' . $ppath, '-' . $standard, '-pbkdf2');
	push @args, '-nopad' if $nopad;
	push @args, '-in', $in_path, '-out', $out_path;
	my $rc = $quiet ? &system_quiet(@args) : system(@args);
	unlink $ppath;
	return $rc == 0 ? 1 : 0;
}

# The same, but returning the plaintext instead of writing it to a path.
sub openssl_file_read {
	my ($standard, $secret, $in_path, $nopad, $quiet) = @_;
	return undef unless defined $secret && length $secret && defined $in_path;
	require File::Temp;
	require File::Spec;
	my ($pfh, $ppath) = eval { File::Temp::tempfile('jawnos-pass-XXXXXX', DIR => File::Spec->tmpdir, UNLINK => 0) };
	return undef unless $pfh && defined $ppath;
	binmode $pfh;
	print $pfh $secret;
	close $pfh;
	my @args = ('openssl', 'enc', '-d', '-pass', 'file:' . $ppath, '-' . $standard, '-pbkdf2');
	push @args, '-nopad' if $nopad;
	push @args, '-in', $in_path;
	my $data;
	my $saved;
	if ($quiet) {
		open($saved, '>&', \*STDERR) or do { unlink $ppath; return undef };
		open(STDERR, '>', '/dev/null') or do { close $saved; unlink $ppath; return undef };
	}
	if (open(my $out, '-|', @args)) {
		binmode $out;
		$data = do { local $/; <$out> };
		close $out;
		$data = undef if $?;
	}
	if ($saved) {
		open(STDERR, '>&', $saved);
		close $saved;
	}
	unlink $ppath;
	return $data;
}

1;
