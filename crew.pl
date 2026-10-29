#!/usr/bin/env perl
package crew;

# The Crew: what each machine in the house can do, and where a job should run.
#
# Two things live here and nothing else does:
#
#   abilities - the facts a machine can advertise: cores, load, RAM, disk, the
#     AI models it holds and the tools it has. Cheap to compute and cached for a
#     minute, because a request must never wait on `ollama list`.
#   jobs - a fixed registry of kinds. A crew route may only run a kind from this
#     table: never a shell string, a path, or a caller-supplied sub name.
#
# The Evaluate AI (and every other role call) asks choose_model() before it
# tries to answer, so a device stops calling a model it does not hold or cannot
# pay for, and places the call on a peer that does.
#
# Loaded by President.pl and Manager.pl beside gb.pl/hooks.pl. It requires
# nothing itself and calls &subs::... only at run time, so `perl -I. -Mcrew`
# can exercise the pure helpers (job_kind, can, model_family) with no database
# and no network.

use strict;
use warnings;

use Mojo::JSON qw(decode_json encode_json);
use Sereal::Decoder qw(decode_sereal);
use POSIX ();
use IO::Select;
use IPC::Open3;
use MIME::Base64 qw(decode_base64);

# How long this machine's own facts are reused (seconds). One minute keeps the
# Configure panel and the role placer cheap without hiding a model just pulled.
our $ABILITIES_TTL = 60;
# A peer advert older than this (milliseconds) is not offered to a caller. The
# advert sync runs every five minutes, so fifteen minutes rides three misses.
our $ADVERT_TTL = 15 * 60 * 1000;
# A role's placement is reused this long (seconds) so a burst of role calls
# reads the roster once, not once per call.
our $ROLE_TTL = 30;
# A finished job's result is kept this long (milliseconds) so a retried job_id
# is answered from the cache rather than run a second time.
our $JOB_TTL = 30 * 60 * 1000;

# This machine's last computed facts: { at => epoch_seconds, abilities => {} }.
our $ab_memo;
# role => { at => epoch_seconds, model => ... , why => '...' }
our %role_memo;
# job_id => { kind, origin, started } for jobs this worker is running now. The
# map is per process by design (see queue()).
our %running;

# ---------------------------------------------------------------------------
# The job registry. This table is the only thing a crew route may invoke.
#
#   handler => sub { my ($payload, $ctx) = @_; return { ... } }
#   timeout => seconds before the handler is killed
#   needs   => [ 'ollama:<model>', '<tool name from abilities()->{tools}>' ]
#   cost    => 'light' | 'heavy' - a heavy kind is not placed on a machine
#              whose one-minute load already exceeds its cores
#
# The seeds are deliberately small: noop and echo prove the rail, ai.evaluate
# is the Evaluate AI, and whisper.transcribe delegates to subs::whisper_transcribe
# (which already chooses the warm server, the CLI or a cloud model).
# ---------------------------------------------------------------------------
our %KINDS = (
	noop => {
		handler => sub {
			return { pong => 1, at => &subs::rightNow() };
		},
		timeout => 20,
		needs   => [],
		cost    => 'light',
	},
	echo => {
		handler => sub {
			my ($payload) = @_;
			return { echo => $payload };
		},
		timeout => 30,
		needs   => [],
		cost    => 'light',
	},
	'ai.evaluate' => {
		handler => \&_job_ai_evaluate,
		timeout => 300,
		needs   => [],
		cost    => 'heavy',
	},
	'whisper.transcribe' => {
		handler => \&_job_whisper_transcribe,
		timeout => 600,
		needs   => ['whisper'],
		cost    => 'heavy',
	},
);

# The kind's registry row, or undef. The name is validated before lookup so a
# caller cannot reach a Perl hash key through a path or a sub name.
sub job_kind {
	my ($kind) = @_;
	return undef unless defined $kind && $kind =~ /^[a-z][a-z0-9_.]{1,40}$/;
	return $KINDS{$kind};
}

# The kinds this machine can run right now.
sub kinds_for {
	my ($abilities) = @_;
	$abilities ||= abilities();
	return [ grep { can($_, $abilities) } sort keys %KINDS ];
}

# Can this machine run this kind, given the kind's needs and its load? Pure:
# the abilities hash is the only input, so it answers the same for a peer's
# cached advert as it does for this machine.
sub can {
	my ($kind, $abilities) = @_;
	my $spec = job_kind($kind);
	return 0 unless $spec;
	$abilities ||= abilities();
	return 0 unless $abilities && ref $abilities eq 'HASH';
	foreach my $need ( @{ $spec->{'needs'} || [] } ) {
		next unless defined $need && length $need;
		if ($need =~ /^ollama:(.+)$/) {
			return 0 unless _lists_model($abilities, $1);
		}
		else {
			return 0 unless $abilities->{'tools'} && $abilities->{'tools'}->{$need};
		}
	}
	return 0 if _overloaded($abilities, $spec->{'cost'} || 'light');
	return 1;
}

# ---------------------------------------------------------------------------
# Abilities: this machine's advertise-able facts.
# ---------------------------------------------------------------------------

sub abilities {
	my $opt = shift || {};
	my $now = time;
	if (!$opt->{'refresh'} && $ab_memo && $now - $ab_memo->{'at'} < $ABILITIES_TTL) {
		return $ab_memo->{'abilities'};
	}
	my $abilities = _compute_abilities();
	$ab_memo = { at => $now, abilities => $abilities };
	return $abilities;
}

sub _compute_abilities {
	my @uname = POSIX::uname();
	my $hostname = $uname[1] || _read_first_line('/proc/sys/kernel/hostname') || '';
	my $arch = $uname[4] || '';
	my $cores = _cores();

	my $load1 = 0;
	if (open(my $fh, '<', '/proc/loadavg')) {
		my $line = <$fh>;
		close $fh;
		$load1 = $1 + 0 if defined $line && $line =~ /^([\d.]+)/;
	}

	my ($ram_mb, $ram_free_mb) = _memory_mb();
	my $disk_free_mb = _disk_free_mb($ENV{'HOME'} || '.');
	my ($on_ac, $battery_percent) = _power();
	my $os = _os_name();

	my $has_ollama = _which('ollama') ? 1 : 0;
	my @ollama_models;
	if ($has_ollama) {
		@ollama_models = _ollama_models();
	}

	my %tools = (
		browser   => (_which('chromium') || _which('chromium-browser') || _which('playwright')) ? 1 : 0,
		ffmpeg    => _which('ffmpeg') ? 1 : 0,
		tesseract => _which('tesseract') ? 1 : 0,
		whisper   => _whisper_binary() ? 1 : 0,
		perl      => _which('perl') ? 1 : 0,
		node      => _which('node') ? 1 : 0,
		git       => _which('git') ? 1 : 0,
	);

	my %abilities = (
		signatorial  => (eval { &subs::signatorial_designer() } || ''),
		hostname     => $hostname,
		device_type  => (eval { &subs::device_setter() } || 'computer'),
		arch         => $arch,
		cores        => $cores,
		load1        => $load1,
		ram_mb       => $ram_mb,
		ram_free_mb  => $ram_free_mb,
		disk_free_mb => $disk_free_mb,
		os           => $os,
		ollama       => $has_ollama,
		ollama_models => \@ollama_models,
		tools        => \%tools,
		at           => int(time() * 1000),
	);
	# Only advertised when the hardware really reports it. Android denies the
	# power_supply sysfs to apps, so a phone simply says nothing here.
	$abilities{'on_ac'} = $on_ac if defined $on_ac;
	$abilities{'battery_percent'} = $battery_percent if defined $battery_percent;
	return \%abilities;
}

# ---------------------------------------------------------------------------
# Peer adverts. A peer's last answer is kept in the cache table (app 'crew',
# context = its signatorial) because that table is this machine's own view and
# never syncs. No new table, and nothing written into the peer's settings.
# ---------------------------------------------------------------------------

sub advert_sync {
	my $me = &subs::signatorial_designer();
	my $rms = &subs::db_select('remote_machines')->hashes || [];
	my $seen = 0;
	foreach my $rm ( @{$rms} ) {
		my $rsig = $rm->{'signatorial'};
		next unless $rsig && $rsig ne $me;
		# Following ollama_models_sync: a peer that cannot be reached, or
		# answers something that is not an ability advert, keeps its last one.
		my ($ua, $p) = &subs::peer_useragent($rm);
		next unless $ua;
		my $res = eval {
			$ua->inactivity_timeout(12)->get($p->{'manager'} . '/manager/crew/state?signatorial=' . $me)->result;
		};
		next unless $res && $res->is_success;
		my $body = eval { decode_json $res->body };
		next unless $body && ref $body eq 'HASH' && ref $body->{'abilities'} eq 'HASH';
		my $abilities = $body->{'abilities'};
		$abilities->{'signatorial'} = $rsig;
		$abilities->{'hostname'} = ($rm->{'hostname'} || '') unless length($abilities->{'hostname'} || '');
		my $read_at = &subs::rightNow();
		&subs::cache_set({ app => 'crew', context => $rsig }, {
			json      => encode_json($abilities),
			abilities => $abilities,
			read_at   => $read_at,
		});
		$seen++;
	}
	&_log('crew: advert sync answered for ' . $seen . ' peer(s)');
	return $seen;
}

# Every fresh advert this machine holds: [ { signatorial, abilities, read_at } ].
sub advert_list {
	my $now = &subs::rightNow();
	my $rows = eval {
		&subs::db_select_simple('cache', ['context', 'data', 'server_time'], { app => 'crew' })->hashes;
	} || [];
	my @out;
	foreach my $row ( @{$rows} ) {
		# cache_set() stores encode_sereal, so read it back with the same codec.
		# (There is no subs::decode_sereal: it is the module's imported function.)
		my $data = eval { decode_sereal($row->{'data'}) };
		next unless $data && ref $data eq 'HASH';
		my $abilities = $data->{'abilities'};
		next unless $abilities && ref $abilities eq 'HASH';
		my $read_at = $data->{'read_at'} || $row->{'server_time'} || 0;
		next if $read_at && $now - $read_at > $ADVERT_TTL;
		my $sig = $row->{'context'} || $abilities->{'signatorial'} || '';
		next unless length $sig;
		$abilities->{'signatorial'} = $sig;
		push @out, { signatorial => $sig, abilities => $abilities, read_at => $read_at };
	}
	return \@out;
}

sub advert_get {
	my ($signatorial) = @_;
	return undef unless defined $signatorial && length $signatorial;
	foreach my $advert ( @{ advert_list() } ) {
		return $advert if $advert->{'signatorial'} eq $signatorial;
	}
	return undef;
}

# One small tick for President.pl: re-read this machine's facts (so a model
# pulled a minute ago is offered without a restart) and drop adverts and job
# results nobody will ask for again.
sub tick {
	my $now = &subs::rightNow();
	my $abilities = abilities({ refresh => 1 });
	eval { &subs::db_query('delete from cache where app = ? and server_time < ?', 'crew', $now - $ADVERT_TTL) };
	eval { &subs::db_query('delete from cache where app = ? and server_time < ?', 'crew_job', $now - $JOB_TTL) };
	return $abilities;
}

# The answer to GET /manager/crew/state.
sub state {
	my $me = &subs::signatorial_designer();
	return {
		signatorial => $me,
		abilities   => abilities(),
		queue       => queue(),
		at          => &subs::rightNow(),
	};
}

# Jobs this worker is running now. A worker owns its own map, so the state
# route reports the queue it can actually see; every machine's advert carries
# the facts a placer needs, not this list.
sub queue {
	my @out;
	foreach my $job_id ( sort keys %running ) {
		push @out, { job_id => $job_id, %{ $running{$job_id} } };
	}
	return \@out;
}

sub queue_note {
	my ($job_id, $kind, $origin) = @_;
	return 0 unless defined $job_id && length $job_id;
	$running{$job_id} = {
		kind    => ($kind // ''),
		origin  => ($origin // ''),
		started => &subs::rightNow(),
	};
	return 1;
}

sub queue_done {
	my ($job_id) = @_;
	delete $running{$job_id} if defined $job_id;
	return 1;
}

# ---------------------------------------------------------------------------
# Running and placing jobs.
# ---------------------------------------------------------------------------

# Run a registry kind. Returns { ok => 1, result => ... } or { ok => 0, error }.
# The timeout is an alarm in this process; the crew route runs this in a forked
# child (subs::render_in_subprocess), so a job that ignores it dies alone.
# No database write happens here: job_store() is the caller's job, in the
# process that owns the request.
sub job_run {
	my ($kind, $payload, %opt) = @_;
	my $spec = job_kind($kind);
	return { ok => 0, error => 'unknown job kind' } unless $spec;
	$payload = {} unless ref $payload eq 'HASH';
	my $timeout = ($opt{'timeout'} || 0) > 0 ? $opt{'timeout'} : ($spec->{'timeout'} || 60);
	my $outcome;
	eval {
		local $SIG{ALRM} = sub { die "the job ran past its " . $timeout . "s limit\n" };
		alarm $timeout;
		my $result = $spec->{'handler'}->($payload, {
			kind    => $kind,
			job_id  => ($opt{'job_id'} // ''),
			origin  => ($opt{'origin'} // ''),
		});
		alarm 0;
		$outcome = { ok => 1, result => $result };
		1;
	};
	unless ($outcome) {
		alarm 0;
		my $err = $@ || 'the job failed';
		$err =~ s/\s+$//;
		$outcome = { ok => 0, error => $err };
	}
	return $outcome;
}

# Keep a finished job's answer so a retried job_id is not run twice.
sub job_store {
	my ($job_id, $outcome) = @_;
	return 0 unless defined $job_id && length $job_id;
	return 0 unless $outcome && ref $outcome eq 'HASH';
	&subs::cache_set({ app => 'crew_job', context => substr($job_id, 0, 100) }, {
		at      => &subs::rightNow(),
		outcome => $outcome,
	});
	return 1;
}

# The stored answer for this job_id, or undef. Only a successful run is cached,
# so a caller never mistakes a failure for an answer.
sub job_cached {
	my ($job_id) = @_;
	return undef unless defined $job_id && length $job_id;
	my $row = eval { &subs::cache_get({ app => 'crew_job', context => substr($job_id, 0, 100) }) };
	return undef unless $row && ref $row eq 'HASH';
	my $outcome = $row->{'outcome'};
	return undef unless $outcome && ref $outcome eq 'HASH' && $outcome->{'ok'};
	return undef if &subs::rightNow() - ($row->{'at'} || 0) > $JOB_TTL;
	return $outcome;
}

sub new_job_id {
	my ($kind) = @_;
	my $id = eval { &subs::random_string_creator(20) } || '';
	$id = sprintf('%d-%d', time, int(rand(1_000_000))) unless length $id;
	return substr(($kind || 'job'), 0, 24) . '-' . $id;
}

# Where should this kind run? Self first when self can and is not overloaded,
# otherwise the able peer with the lowest load (a newer advert breaks a tie).
# %opt: from => the signatorial that dispatched this, which is never a target.
sub place {
	my ($kind, $payload, %opt) = @_;
	my $spec = job_kind($kind);
	return { ok => 0, error => 'unknown job kind' } unless $spec;
	my $me = &subs::signatorial_designer();
	my $from = $opt{'from'} // '';

	my $local = abilities();
	if ($me && (!$from || $from ne $me) && can($kind, $local)) {
		return {
			ok          => 1,
			signatorial => $me,
			hostname    => $local->{'hostname'},
			local       => 1,
			why         => 'this machine can run it',
		};
	}

	my @candidates;
	foreach my $advert ( @{ advert_list() } ) {
		my $sig = $advert->{'signatorial'};
		next unless $sig && $sig ne $me;
		# A job never goes back to the machine that dispatched it.
		next if $from && $sig eq $from;
		next unless can($kind, $advert->{'abilities'});
		push @candidates, $advert;
	}
	@candidates = sort {
		($a->{'abilities'}->{'load1'} // 0) <=> ($b->{'abilities'}->{'load1'} // 0)
			|| ($b->{'read_at'} || 0) <=> ($a->{'read_at'} || 0)
	} @candidates;
	if (my $best = $candidates[0]) {
		return {
			ok          => 1,
			signatorial => $best->{'signatorial'},
			hostname    => ($best->{'abilities'}->{'hostname'} || $best->{'signatorial'}),
			local       => 0,
			why         => 'the least loaded able peer',
		};
	}
	return { ok => 0, error => 'no machine here can run ' . $kind };
}

# Place a job and carry it out: locally when this machine is the choice, over
# the peer rail otherwise. %opt: job_id => ... (minted when absent),
# from => the machine that asked us, so it is never sent the job back.
sub dispatch {
	my ($kind, $payload, %opt) = @_;
	my $spec = job_kind($kind);
	return { ok => 0, error => 'unknown job kind' } unless $spec;
	$payload = {} unless ref $payload eq 'HASH';
	my $me = &subs::signatorial_designer();

	my $job_id = $opt{'job_id'} // '';
	$job_id =~ s/[^A-Za-z0-9_.-]//g;
	$job_id = new_job_id($kind) unless length $job_id;

	my $cached = job_cached($job_id);
	return $cached if $cached;

	my $where = place($kind, $payload, from => ($opt{'from'} // ''));
	return $where unless $where->{'ok'};

	if ($where->{'local'}) {
		my $outcome = job_run($kind, $payload,
			timeout => $spec->{'timeout'},
			job_id  => $job_id,
			origin  => $me,
		);
		job_store($job_id, $outcome) if $outcome->{'ok'};
		return $outcome;
	}

	my ($rm) = grep { ($_->{'signatorial'} || '') eq $where->{'signatorial'} }
		@{ &subs::db_select('remote_machines')->hashes || [] };
	return { ok => 0, error => 'no connection to ' . $where->{'signatorial'} } unless $rm;
	my ($ua, $p) = &subs::peer_useragent($rm);
	return { ok => 0, error => 'could not reach ' . ($where->{'hostname'} || $where->{'signatorial'}) } unless $ua;

	my $timeout = $spec->{'timeout'} || 60;
	my $res = eval {
		$ua->inactivity_timeout($timeout + 30)->post(
			$p->{'manager'} . '/manager/crew/job?signatorial=' . $me => json => {
				kind     => $kind,
				job_id   => $job_id,
				payload  => $payload,
				origin   => ($opt{'from'} || $me),
				deadline => time + $timeout + 30,
			}
		)->result;
	};
	unless ($res && $res->is_success) {
		my $why = $@ || ($res ? 'HTTP ' . $res->code : 'no answer');
		return { ok => 0, error => 'the crew job on ' . ($where->{'hostname'} || $where->{'signatorial'}) . ' failed: ' . $why };
	}
	my $body = eval { decode_json $res->body };
	return { ok => 0, error => 'the crew job returned nothing readable' }
		unless $body && ref $body eq 'HASH' && ($body->{'ok'} || $body->{'error'});
	job_store($job_id, $body) if $body->{'ok'};
	return $body;
}

# ---------------------------------------------------------------------------
# The Evaluate AI's placement. A model is viable only if this house can really
# reach it, not merely because a setting names it.
# ---------------------------------------------------------------------------

# The role's model, chosen from what this house can actually run. Returns
# ($model, $why), or (undef, $why) when nothing is viable. The order is the
# role's primary, its fallback, the free model, then a peer that advertises a
# local model of the same family.
sub choose_model {
	my ($role) = @_;
	$role = '' unless defined $role;
	my $now = time;
	my $memo = $role_memo{$role};
	if ($memo && $now - $memo->{'at'} < $ROLE_TTL) {
		return ($memo->{'model'}, $memo->{'why'});
	}

	my ($primary, $fallback) = &subs::ai_role_models($role);
	my $ctx = _choice_context();
	my @tried;
	my $pick;

	foreach my $model ( grep { defined $_ && length $_ } ($primary, $fallback) ) {
		my ($viable, $why) = _candidate_viable($model, $ctx);
		if ($viable) { $pick = { model => $model, why => $why }; last; }
		push @tried, $model . ': ' . $why;
	}

	if (!$pick) {
		my $free = eval { &subs::ai_free_model() } || '';
		if (length $free && !grep { defined $_ && $_ eq $free } ($primary, $fallback)) {
			my ($viable, $why) = _candidate_viable($free, $ctx);
			if ($viable) {
				$pick = { model => $free, why => 'the configured model is unusable; this free model is ' . $why };
			}
			else {
				push @tried, $free . ': ' . $why;
			}
		}
	}

	if (!$pick) {
		my $family = _model_family($primary || $fallback);
		if (length $family) {
			my $me = &subs::signatorial_designer();
			my @adverts = sort {
				($a->{'abilities'}->{'load1'} // 0) <=> ($b->{'abilities'}->{'load1'} // 0)
			} @{ advert_list() };
			foreach my $advert ( @adverts ) {
				my $sig = $advert->{'signatorial'};
				next unless $sig && $sig ne $me;
				next unless $advert->{'abilities'}->{'ollama'};
				my ($seat) = grep { _model_family($_) eq $family }
					@{ $advert->{'abilities'}->{'ollama_models'} || [] };
				next unless defined $seat && length $seat;
				$pick = {
					model => '@' . $sig . '/' . $seat,
					why   => 'the same family on ' . ($advert->{'abilities'}->{'hostname'} || $sig),
				};
				last;
			}
		}
	}

	unless ($pick) {
		my $why = 'nothing viable' . (@tried ? ' (' . join('; ', @tried) . ')' : '');
		$role_memo{$role} = { at => $now, model => undef, why => $why };
		return (undef, $why);
	}
	$role_memo{$role} = { at => $now, model => $pick->{'model'}, why => $pick->{'why'} };
	return ($pick->{'model'}, $pick->{'why'});
}

# Is one model reachable from this house? The context is read once per choice
# so a primary and a fallback do not each read the roster.
sub _candidate_viable {
	my ($model, $ctx) = @_;
	$ctx ||= _choice_context();
	return (0, 'no model is set') unless defined $model && length $model;
	# whisper.cpp is chosen as a local engine, not as a chat model
	return (0, 'not a chat model') if $model =~ /^local:/;

	my $provider = &subs::ai_model_provider($model);

	# A peer's own Ollama: the advert is the truth. A model the peer no longer
	# lists is not called, however recently the role named it.
	if ($provider eq 'ollama_remote') {
		my ($device, $bare) = $model =~ /^\@([^\/]+)\/(.+)$/;
		my $advert = $device ? $ctx->{'adverts'}->{$device} : undef;
		return (0, $device . ' has not advertised') unless $advert;
		return (0, $device . ' does not list ' . $bare)
			unless _lists_model($advert->{'abilities'}, $bare);
		return (0, $device . ' is overloaded')
			if _overloaded($advert->{'abilities'}, 'heavy');
		return (1, 'advertised by ' . $device);
	}

	# A local Ollama comes first, because a :cloud model is billed through the same
	# daemon and has no key setting of its own to look up. Read as a paid
	# provider instead, every :cloud model would be called unreachable. But the
	# daemon must still know the model: a phone that never pulled a :cloud model
	# sent the call to its own localhost and answered with a connection error.
	if ($provider eq 'ollama') {
		if ($model =~ /:cloud\b/i) {
			return (0, 'the ollama_cloud budget is stood down')
				unless $ctx->{'bucket_ok'}->('ollama_cloud');
			return (0, 'this machine does not have ' . $model)
				unless _lists_model($ctx->{'abilities'}, $model);
			return (0, 'this machine is overloaded')
				if _overloaded($ctx->{'abilities'}, 'heavy');
			return (1, 'an Ollama cloud model installed here');
		}
		return (0, 'this machine does not have ' . $model)
			unless _lists_model($ctx->{'abilities'}, $model);
		return (0, 'this machine is overloaded')
			if _overloaded($ctx->{'abilities'}, 'heavy');
		return (1, 'installed here');
	}

	if (&subs::ai_model_paid($model)) {
		my $bucket = &subs::ai_model_bucket($model);
		return (0, 'the ' . $bucket . ' budget is stood down')
			unless $ctx->{'bucket_ok'}->($bucket);
		my $key_setting = $ctx->{'provider_keys'}->{$bucket};
		if (defined $key_setting) {
			return (0, $bucket . ' has no key here')
				unless $ctx->{'keys'}->{$key_setting};
		}
		return (1, 'billable (' . $bucket . ') and available');
	}

	if ($provider eq 'cloudflare') {
		return (0, 'Cloudflare is not configured')
			unless $ctx->{'keys'}->{'cloudflare_account'} && $ctx->{'keys'}->{'cloudflare_token'};
		return (1, 'included with Cloudflare');
	}

	my $key_setting = $ctx->{'provider_keys'}->{$provider};
	return (0, 'no provider for ' . $model) unless $key_setting;
	return (0, $provider . ' has no key here') unless $ctx->{'keys'}->{$key_setting};
	return (1, $provider . ' key is set');
}

sub _choice_context {
	my $abilities = abilities();
	my %adverts;
	foreach my $advert ( @{ advert_list() } ) {
		$adverts{ $advert->{'signatorial'} } = $advert;
	}
	my %keys;
	my @names = eval { &subs::ai_key_settings() };
	if (@names) {
		my $values = eval { &subs::settings_grabber({ app => 'mail', settings => [ @names ] }) } || {};
		%keys = %{$values} if ref $values eq 'HASH';
	}
	my %bucket_ok;
	return {
		abilities => $abilities,
		adverts   => \%adverts,
		keys      => \%keys,
		provider_keys => {
			openai     => 'openai_key',
			anthropic  => 'anthropic_key',
			google     => 'google_key',
			xai        => 'xai_key',
			mistral    => 'mistral_key',
			groq       => 'groq_key',
			openrouter => 'openrouter_key',
			deepseek   => 'deepseek_key',
		},
		bucket_ok => sub {
			my ($bucket) = @_;
			return 1 unless defined $bucket && length $bucket;
			unless (exists $bucket_ok{$bucket}) {
				$bucket_ok{$bucket} = eval { &subs::ai_bucket_available($bucket) } ? 1 : 0;
			}
			return $bucket_ok{$bucket};
		},
	};
}

# The family a model belongs to, so a peer's copy can stand in for one that
# went away: llama3.3:70b and llama3.3 are one family, as are @peer/llama3.3
# and llama3.3. Pure, so a one-liner can check it.
sub model_family {
	my ($model) = @_;
	return '' unless defined $model && length $model;
	my $name = $model;
	$name =~ s/^\@cf\///;
	$name =~ s/^\@[^\/]+\///;
	if ($name =~ /^([a-z]+):/ && grep { $_ eq $1 } qw/openai anthropic google xai mistral groq openrouter deepseek/) {
		$name =~ s/^[a-z]+://;
	}
	$name =~ s/:.*$//;
	return $name;
}

# ---------------------------------------------------------------------------
# Shared helpers. None of these touch the database or the network beyond a
# bounded subprocess.
# ---------------------------------------------------------------------------

sub _lists_model {
	my ($abilities, $model) = @_;
	return 0 unless defined $model && length $model;
	foreach my $name ( @{ $abilities->{'ollama_models'} || [] } ) {
		return 1 if defined $name && $name eq $model;
	}
	return 0;
}

# Would this machine be placed on? A light kind tolerates a fully busy box (two
# runnable tasks per core); a heavy one (a model call, a transcription) is kept
# off a machine already at its core count.
sub _overloaded {
	my ($abilities, $cost) = @_;
	return 0 unless $abilities && ref $abilities eq 'HASH';
	my $load = $abilities->{'load1'};
	return 0 unless defined $load;
	my $cores = ($abilities->{'cores'} || 1) + 0;
	my $cap = ($cost || 'light') eq 'heavy' ? $cores : $cores * 2;
	return $load > $cap ? 1 : 0;
}

sub _cores {
	my $count = 0;
	if (open(my $fh, '<', '/proc/cpuinfo')) {
		while (my $line = <$fh>) {
			$count++ if $line =~ /^processor\s*:/;
		}
		close $fh;
	}
	return $count > 0 ? $count : 1;
}

sub _memory_mb {
	my ($total, $available) = (0, 0);
	if (open(my $fh, '<', '/proc/meminfo')) {
		while (my $line = <$fh>) {
			$total = $1 + 0 if $line =~ /^MemTotal:\s+(\d+)/;
			$available = $1 + 0 if $line =~ /^MemAvailable:\s+(\d+)/;
		}
		close $fh;
	}
	return (int($total / 1024), int($available / 1024));
}

sub _disk_free_mb {
	my ($path) = @_;
	$path = '.' unless defined $path && length $path;
	my $out = _run_capped(3, 'df', '-P', '-k', $path);
	return 0 unless defined $out && length $out;
	my @lines = grep { /\S/ } split /\n/, $out;
	my $line = $lines[-1] || '';
	my @field = split ' ', $line;
	return (defined $field[3] && $field[3] =~ /^\d+$/) ? int($field[3] / 1024) : 0;
}

# (on_ac, battery_percent) from sysfs, or () when the hardware does not expose
# it (Android denies it to apps). Never invents a value.
sub _power {
	my ($on_ac, $percent);
	foreach my $base ( glob('/sys/class/power_supply/*') ) {
		my $type = _read_first_line($base . '/type') // '';
		if ($type eq 'Battery') {
			my $capacity = _read_first_line($base . '/capacity');
			$percent = int($capacity) if defined $capacity && $capacity =~ /^\d+/;
		}
		elsif ($type eq 'Mains' || $type eq 'USB' || $type eq 'AC') {
			my $online = _read_first_line($base . '/online');
			$on_ac = ($online && $online + 0) ? 1 : 0 if defined $online;
		}
	}
	return ($on_ac, $percent);
}

sub _os_name {
	my $line = _read_first_line('/etc/os-release');
	if (defined $line && $line =~ /^PRETTY_NAME="?([^"]*)"?\s*$/) {
		my $name = $1;
		$name =~ s/\s+$//;
		return $name if length $name;
	}
	return (POSIX::uname())[0] || '';
}

sub _read_first_line {
	my ($path) = @_;
	return undef unless defined $path && length $path;
	open(my $fh, '<', $path) or return undef;
	my $line = <$fh>;
	close $fh;
	return undef unless defined $line;
	$line =~ s/\s+$//;
	return $line;
}

sub _which {
	my ($name) = @_;
	return '' unless defined $name && length $name;
	foreach my $dir ( split /:/, ($ENV{'PATH'} || '') ) {
		next unless length $dir;
		my $path = $dir . '/' . $name;
		return $path if -f $path && -x $path;
	}
	return '';
}

sub _whisper_binary {
	my $hardwired = eval { &subs::home('~/whisper.cpp/build/bin/whisper-cli') };
	if (defined $hardwired && length $hardwired && -x $hardwired) {
		return $hardwired;
	}
	foreach my $name ( qw/whisper-cli whisper-cpp whisper/ ) {
		my $path = _which($name);
		return $path if length $path;
	}
	return '';
}

# `ollama list` is a daemon round trip. Run it with a hard cap so a hung daemon
# costs two seconds, never a request.
sub _ollama_models {
	my $out = _run_capped(2, 'ollama', 'list');
	return () unless defined $out && length $out;
	my @models;
	foreach my $line ( split /\n/, $out ) {
		next if $line !~ /\S/;
		next if $line =~ /^\s*NAME\s/;
		my ($name) = $line =~ /^(\S+)/;
		next unless defined $name && length $name;
		push @models, $name unless grep { $_ eq $name } @models;
	}
	return @models;
}

# Run a command with a wall-clock cap, returning stdout and stderr together.
# IPC::Open3 + IO::Select so no shell is involved and no alarm is spent.
sub _run_capped {
	my ($seconds, @cmd) = @_;
	$seconds = 5 unless $seconds && $seconds > 0;
	return '' unless @cmd;
	local $SIG{PIPE} = 'IGNORE';
	my ($wtr, $out, $err);
	my $pid = eval { IPC::Open3::open3($wtr, $out, $err, @cmd) };
	return '' unless $pid;
	close $wtr if $wtr;
	my $select = IO::Select->new;
	$select->add($out) if $out;
	$select->add($err) if $err;
	my (%buffer, $timed_out);
	my $deadline = time + $seconds;
	while ($select->count) {
		if (time >= $deadline) {
			$timed_out = 1;
			last;
		}
		my @ready = $select->can_read(0.1);
		next unless @ready;
		foreach my $fh ( @ready ) {
			my $read = sysread($fh, my $chunk, 8192);
			if (!defined $read || $read == 0) {
				$select->remove($fh);
				next;
			}
			$buffer{ fileno($fh) } .= $chunk;
		}
	}
	kill 'KILL', $pid if $timed_out;
	waitpid($pid, 0);
	close $out if $out;
	close $err if $err;
	return join '', map { $buffer{$_} } sort { $a <=> $b } keys %buffer;
}

sub _log {
	my ($line) = @_;
	return 0 unless defined $line && length $line;
	eval { $subs::log->info($line) } if $subs::log;
	return 1;
}

# ---------------------------------------------------------------------------
# Seed handlers.
# ---------------------------------------------------------------------------

sub _job_ai_evaluate {
	no warnings 'once';   # the one read of the AI wire's last-model record
	my ($payload) = @_;
	my $role = (($payload->{'role'} // '') =~ /^[a-z][a-z0-9_]{1,40}$/) ? $payload->{'role'} : 'eval_assistant';
	my $user = $payload->{'user'} // $payload->{'prompt'} // '';
	die "ai.evaluate needs a prompt\n" unless defined $user && length $user;
	my $system = $payload->{'system'} // '';
	my $thinking = $payload->{'thinking'} // &subs::ai_role_thinking($role);
	my ($text, $err) = &subs::evaluation_model_call_role($role, $system, $user, $thinking);
	die(($err || 'no answer') . "\n") if $err;
	return { text => $text, role => $role, model => ($subs::ai_last_model // '') };
}

sub _job_whisper_transcribe {
	my ($payload) = @_;
	my $raw;
	if (defined $payload->{'audio_b64'} && length $payload->{'audio_b64'}) {
		$raw = decode_base64($payload->{'audio_b64'});
	}
	elsif (defined $payload->{'audio'} && length $payload->{'audio'} && !ref $payload->{'audio'}) {
		$raw = $payload->{'audio'};
	}
	die "whisper.transcribe needs audio\n" unless defined $raw && length $raw;
	my $lang = $payload->{'lang'} // 'auto';
	my $text = &subs::whisper_transcribe($raw, $lang);
	die "no transcript\n" unless defined $text && length $text;
	return { text => $text, lang => $lang };
}

1;
