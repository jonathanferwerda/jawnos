package subs;

# Records2: extracted from subroutines.pl (package subs). Loaded on
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
use Mojo::SQLite;
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
our $ai_tokens;
our $coding_protocols_cache;
our $coding_protocols_mtime;
our $config;
our $device;
our $gb;
our $log;
our %m;
our $say_quiet;
our %setting_memo;

# Compare a snapshot to the live table and list the rows the live table made
# shorter (or dropped). A row is a candidate when its app is one the person named
# or when it ran longer than older_than_ms in the snapshot - the two signals a
# fixed rule cannot supply on its own.
sub records_recover_scan {
	my ($opts) = @_;
	$opts ||= {};
	my $min_ms = (defined $opts->{'older_than_ms'} && $opts->{'older_than_ms'} =~ /^[0-9]+$/) ? $opts->{'older_than_ms'} : 86400000;
	my @apps = @{ $opts->{'apps'} || [ 'home', 'alone', 'urbaniak', 'eczema', 'snow', 'winter', 'autumn' ] };
	my $backup = $opts->{'backup'} || &records_latest_backup();
	my $result = { backup => $backup, older_than_ms => $min_ms, apps => [ @apps ], candidates => [], summary => {}, error => '' };
	unless ($backup && -e $backup) { $result->{'error'} = 'there is no snapshot to compare against'; return $result; }
	my ($snap_ms) = $backup =~ /jawnos_(\d+)\.enc$/;
	$snap_ms = (stat($backup))[9] * 1000 unless $snap_ms;
	$result->{'snapshot_time'} = $snap_ms;
	my $old_db = &records_backup_decrypt($backup);
	unless ($old_db) { $result->{'error'} = 'could not unseal the snapshot (key or format)'; return $result; }
	my $rows = eval { Mojo::SQLite->new('sqlite:' . $old_db)->db->query('select * from appointments')->hashes } || [];
	$result->{'summary'}{'old_rows'} = scalar @{$rows};
	# the app's own session length: the yardstick that says whether a shorter live
	# value is a repair (live ~ duration) or a loss
	my %dur;
	foreach my $s ( @{ &db_query('select app, value from settings where setting = ?', 'duration')->hashes } ) {
		next unless defined $s->{'value'} && $s->{'value'} =~ /[0-9]/;
		my $d = abs &time_abbrev_translator($s->{'value'});
		$dur{ $s->{'app'} } = $d if $d;
	}
	my $matches = sub {
		my ($app) = @_;
		return 0 unless defined $app && length $app;
		foreach my $want ( @apps ) {
			my $w = $want; $w =~ s/\*//g;
			return 1 if length $w && index(lc($app), lc($w)) >= 0;
		}
		return 0;
	};
	my $now = &rightNow();
	foreach my $r ( @{$rows} ) {
		next unless $r->{'uuid'};
		my $old_ended = (defined $r->{'stop_timestamp'} && $r->{'stop_timestamp'} =~ /^[0-9]+$/ && $r->{'stop_timestamp'} > 0) ? 1 : 0;
		my $old_span = &records_span_ms($r, $snap_ms);
		next unless defined $old_span;
		my $named = $matches->($r->{'app'});
		next unless $named || $old_span > $min_ms;
		my $live = &subs::db_select('appointments', undef, { uuid => $r->{'uuid'} })->hash;
		# only an end that was written can be lost. An open row's span is just the
		# clock, so a pair where neither side is ended is never a candidate - without
		# this, every far-future row reads as "shortened" as the clock advances
		if (!$live) {
			next unless $old_ended;
			push @{$result->{'candidates'}}, {
				uuid => $r->{'uuid'}, app => $r->{'app'}, type => $r->{'type'},
				start => $r->{'timestamp'}, old_stop => $r->{'stop_timestamp'}, old_duration => $r->{'duration'},
				old_span_ms => $old_span, live_stop => undef, live_span_ms => undef,
				app_duration => $dur{ $r->{'app'} },
				status => 'missing', named => $named, action => 'reinstate', old_row => $r,
			};
			next;
		}
		my $live_ended = (defined $live->{'stop_timestamp'} && $live->{'stop_timestamp'} =~ /^[0-9]+$/ && $live->{'stop_timestamp'} > 0) ? 1 : 0;
		next unless $old_ended || $live_ended;
		my $live_span = &records_span_ms($live, $now);
		next unless !defined $live_span || $live_span < $old_span;
		push @{$result->{'candidates'}}, {
			uuid => $r->{'uuid'}, app => $r->{'app'}, type => $r->{'type'},
			start => $r->{'timestamp'}, old_stop => $r->{'stop_timestamp'}, old_duration => $r->{'duration'},
			old_span_ms => $old_span, live_stop => $live->{'stop_timestamp'},
			live_span_ms => $live_span, app_duration => $dur{ $r->{'app'} },
			status => 'shortened', named => $named, action => 'restore',
			old_row => $r,
		};
	}
	@{$result->{'candidates'}} = sort { ($b->{'old_span_ms'} || 0) <=> ($a->{'old_span_ms'} || 0) } @{$result->{'candidates'}};
	$result->{'summary'}{'candidates'} = scalar @{$result->{'candidates'}};
	$result->{'summary'}{'shortened'} = scalar grep { $_->{'status'} eq 'shortened' } @{$result->{'candidates'}};
	$result->{'summary'}{'missing'} = scalar grep { $_->{'status'} eq 'missing' } @{$result->{'candidates'}};
	unlink $old_db;
	return $result;
}

# Write the scan's candidates back: the old row's ended-ness onto the live row, or
# the whole old row when it was dropped. server_time is now, so every machine takes
# the recovered version on its next sync. The recovered apps are then left alone by
# the audit (they are, by definition, the ones that legitimately run long), so a
# sweep does not sweep them up a second time.
sub records_recover_apply {
	my ($scan, $opts) = @_;
	$scan ||= {};
	$opts ||= {};
	# A shorter live value is usually the correct repair (an app that runs three
	# minutes was ended at three minutes), so only the apps the person named are put
	# back unless "any" is asked for. A blanket restore would undo good fixes.
	my $any = $opts->{'any'} ? 1 : 0;
	my @cands = @{ $scan->{'candidates'} || [] };
	my $now = &rightNow();
	my ($restored, $reinstated, $failed, $skipped) = (0, 0, 0, 0);
	my @apps;
	foreach my $c ( @cands ) {
		if (!$any && !$c->{'named'}) { $skipped++; next; }
		my $old = $c->{'old_row'};
		if (!$old || !$old->{'uuid'}) { $skipped++; next; }
		my $ok = eval {
			my $live = &subs::db_select('appointments', undef, { uuid => $old->{'uuid'} })->hash;
			if ($live) {
				&db_update('appointments', {
					stop_timestamp => $old->{'stop_timestamp'},
					stop_seen => $old->{'stop_seen'},
					duration => $old->{'duration'},
					type => $old->{'type'},
					seen => $old->{'seen'},
					server_time => $now,
				}, { uuid => $old->{'uuid'} });
			}
			else {
				my %copy = %{$old};
				delete $copy{$_} for qw(rowid id);
				$copy{'server_time'} = $now;
				&db_insert('appointments', \%copy);
			}
			1;
		};
		if ($ok) {
			if ($c->{'status'} eq 'missing') { $reinstated++; } else { $restored++; }
			push @apps, $c->{'app'} if $c->{'app'};
		}
		else { $failed++; }
	}
	foreach my $a ( @apps ) { &records_exempt_add($a); }
	return { restored => $restored, reinstated => $reinstated, failed => $failed, skipped => $skipped, exempted => [ sort keys %{ &records_exempt() } ] };
}

# One pass of the watch: stage what the audit finds, and - when Apply automatically
# is ticked - write the oldest exact-duplicate finding. A sweep or an orphan waits
# for a person (a genuinely long appointment must never be repaired on its own).
# Off until Configure -> Plat ticks Records.
sub records_watch_tick {
	%setting_memo = ();
	return unless ((&subs::setting_grabber({ app => 'mail', setting => 'records_watch' }) // '') eq 'on');
	my $hours = &subs::setting_grabber({ app => 'mail', setting => 'records_watch_window' });
	my $window_ms = (defined $hours && $hours =~ /^[0-9]+$/) ? $hours * 3600000 : 172800000;
	my $scan = eval { &records_stage_scan($window_ms) } || { error => ($@ || 'scan failed') };
	$log->info('records watch: staged pass, ' . ($scan->{'staged'} // 0) . ' finding(s)') if defined $log && !$scan->{'error'};
	my $auto = ((&subs::setting_grabber({ app => 'mail', setting => 'records_watch_auto' }) // '') eq 'on');
	return unless $auto && &watch_auto_allowed();
	# Automatic apply is for the provably-safe class only: two rows that are the
	# same event written twice. A sweep or an orphan is a judgement call - a real
	# appointment can be surprisingly long - so those always wait for a person,
	# who can put the finding to the Coding agent first (records_ask).
	my $pending = &subs::db_query('select * from staged_records where status = ? and kind = ? order by ost asc limit 1', 'proposed', 'dupe')->hashes->[0];
	if ($pending) {
		my $applied = eval { &records_fix_apply($pending->{'uuid'}) } || { error => ($@ || 'no result') };
		&watch_auto_count();
		$log->info('records watch: auto-applied "' . substr($pending->{'signature'} || '?', 0, 60) . '": ' . ($applied->{'error'} // ($applied->{'rows'} . ' row(s)'))) if defined $log;
	}
}

# One pass: catch what is new, record it, and hand the oldest waiting error to
# the Coding agent to propose a fix for. Called from President's schedule.
sub error_watch_tick {
	# settings may have changed since this long-lived fork last read them (the
	# setting memo lasts the process), so each pass starts from a fresh read
	%setting_memo = ();
	# the house ledger heartbeat runs whatever the watches are set to: the ledger
	# gates evaluations and the shared budget as well as the watches, so this
	# machine must announce itself and its model even when both watches are off
	&ai_house_heartbeat();
	# either watch may want this pass: the error watch for its logs, the guide
	# watch for the Guide's conversations (its rows are proposed from here too,
	# so one proposer, one budget, one Apply)
	my $errors_on = ((&subs::setting_grabber({ app => 'mail', setting => 'error_watch' }) // '') eq 'on');
	my $guide_on = ((&subs::setting_grabber({ app => 'mail', setting => 'guide_watch' }) // '') eq 'on');
	return unless $errors_on || $guide_on;
	# the table normally arrives with the schema migration at a login; create it
	# here too (as run_backfills does for `backfills`) so the watch works from the
	# first boot after an update, before anyone has logged in
	my $table = &subs::db_query('select name from pragma_table_info(?) where name = ?', 'staged_fixes', 'uuid')->hashes->[0];
	unless ($table) {
		&subs::db_query('create table if not exists staged_fixes (
			uuid VARCHAR(255) unique,
			server_time VARCHAR(255),
			ost VARCHAR(25),
			source VARCHAR(25),
			signature VARCHAR(500),
			sample LONGTEXT,
			tally INT,
			status VARCHAR(25),
			model VARCHAR(255),
			summary LONGTEXT,
			files LONGTEXT,
			steps LONGTEXT,
			note LONGTEXT,
			last_seen VARCHAR(255)
		)');
		&subs::db_query('create index if not exists idx1_staged_fixes on staged_fixes (signature)');
		&subs::db_query('create index if not exists idx2_staged_fixes on staged_fixes (status)');
	}
	if ($errors_on) {
		my @caught;
		# The console stream arrives over the master's log bus (a bounded, sequenced
		# ring served at ~/.president/log); there is no pty.log file to read. The
		# long-lived manager.log stays a file and keeps its own cursor.
		push @caught, map { { source => 'pty', line => $_ } } &error_watch_catch(&log_bus_read_new());
		my $log_path = &subs::home('~/manager.log');
		push @caught, map { { source => 'log', line => $_ } } &error_watch_catch(&error_watch_read_new($log_path, 'log'));
		my %new;
		foreach my $c ( @caught ) {
			my $sig = &error_signature($c->{'line'});
			next unless length $sig;
			my $row = $new{$sig} //= { source => $c->{'source'}, sample => substr($c->{'line'}, 0, 2000), tally => 0 };
			$row->{'tally'}++;
		}
		foreach my $sig ( sort keys %new ) {
			my $row = $new{$sig};
			&staged_fix_note({ source => $row->{'source'}, sample => $row->{'sample'}, tally => $row->{'tally'} });
		}
	}
	# one proposal per tick keeps a model's cost and the tree's patience bounded
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' })
		|| &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
	return unless $model;
	my $waiting = &subs::db_query('select * from staged_fixes where status = ? order by ost asc limit 1', 'new')->hashes->[0];
	if ($waiting) {
		# a propose run that dies inside the fork would otherwise vanish into the
		# outer eval; say so, or the row just sits 'new' forever with no trace
		my $ok = eval { &coding_propose_fix($waiting); 1 };
		$log->info('error watch: the proposal for "' . substr($waiting->{'signature'} || '?', 0, 60) . '" died: ' . $@) if !$ok && defined $log;
	}
	# the person's Confirm tick, for fixes: with auto-approve on, the oldest
	# waiting proposal is written, checked and shipped. A file with uncommitted
	# work stands down and is tried again on a later pass, the leash caps the
	# day, and the restart stays a word of its own.
	my $auto = ((&subs::setting_grabber({ app => 'mail', setting => 'error_watch_auto' }) // '') eq 'on');
	if ($auto && &watch_auto_allowed()) {
		my $pending = &subs::db_query('select * from staged_fixes where status = ? order by ost asc limit 1', 'proposed')->hashes->[0];
		if ($pending && &auto_apply_clean($pending)) {
			my $applied = eval { &staged_fix_apply($pending->{'uuid'}) } || { error => ($@ || 'no result') };
			&watch_auto_count();
			if (defined $log) {
				my $note = $applied->{'error'} // ('v' . ($applied->{'version'} // '?'));
				$note .= ' (push: ' . substr($applied->{'push'}, 0, 120) . ')' if $applied->{'push'} && $applied->{'push'} =~ /reject|fail|error/i;
				$log->info('error watch: auto-applied "' . substr($pending->{'signature'} || '?', 0, 60) . '": ' . $note);
			}
		}
		elsif ($pending && defined $log) {
			$log->info('error watch: auto-apply stood down for "' . substr($pending->{'signature'} || '?', 0, 60) . '" - a file it would write has uncommitted work');
		}
	}
	return 1;
}

# ---- the guide watch: the Coding agent's other ear --------------------------
# The Guide's conversations are saved as they go (guide_conversation_<name>,
# the rows the Agents list reads back), tool observations and all. This reads
# the ones that changed since last time and stages a turn that went nowhere -
# a thing not found, a command that could not run, a closing line that says so
# ("[object Object]" among them) - like an error, so the same propose/Apply
# loop adjusts the Guide's training: its rules in help.pl, its verbs in gb.pl.
# A signature dedupes repeats, and a small offset file keeps each conversation
# from being read twice. The first pass only takes a baseline, so switching the
# watch on does not stage the whole history at once.
sub guide_watch_state_file { return &subs::home('~/.president/guide_watch_seen'); }

sub guide_watch_state_load {
	my $file = &guide_watch_state_file();
	my $saved = -e $file ? eval { decode_json read_file($file) } : undef;
	return (ref $saved eq 'HASH') ? $saved : {};
}

# The words that read like the turn went nowhere. The Guide's phrasebook is
# small and its observations are its own client's strings, so this is the same
# text the person sees. "is hidden here" is left out on purpose: refusing a
# hidden thing is the rule working, not a miss.
sub guide_watch_trouble {
	my $text = shift;
	return 0 unless defined $text && length $text;
	return 1 if $text =~ /\[object /i;
	return 1 if $text =~ /could not|cannot|can'?t |unable to/i;
	return 1 if $text =~ /does not exist|doesn'?t exist|there is no |no such /i;
	return 1 if $text =~ /found nothing|nothing found|found 0 record/i;
	return 1 if $text =~ /did not run|no app named|not available here/i;
	return 0;
}

sub guide_watch_tick {
	%setting_memo = ();
	return unless ((&subs::setting_grabber({ app => 'mail', setting => 'guide_watch' }) // '') eq 'on');
	my $fresh = !-e &guide_watch_state_file();
	my $seen = &guide_watch_state_load();
	my $rows = &subs::db_query("select setting, device, value from settings where app = ? and setting like ?", '__president', 'guide_conversation_%')->hashes;
	return unless scalar @{$rows};
	my $noted = 0;
	my %live;
	foreach my $row ( @{$rows} ) {
		next unless length($row->{'setting'} // '');
		my $key = $row->{'setting'} . '|' . ($row->{'device'} // '');
		$live{$key} = 1;
		my $turns = eval { decode_json($row->{'value'} // '') } || [];
		next unless ref $turns eq 'ARRAY' && scalar @{$turns};
		my $from = $seen->{$key} || 0;
		# a thread that shrank was deleted and remade: read it from the top
		$from = 0 if $from > scalar @{$turns};
		$seen->{$key} = scalar @{$turns};
		next if $fresh || $from >= scalar @{$turns};
		# walk the new rows, carrying the turn as the client saved it: a user
		# line opens one, and it is judged where the Guide's own words end it -
		# a step that failed mid-turn and was recovered from is not staged
		my ($question, $trouble, @said);
		foreach my $t ( @{$turns}[$from .. $#{$turns}] ) {
			next unless ref $t eq 'HASH';
			my $role = $t->{'role'} || 'user';
			my $text = $t->{'content'} // '';
			if ($role eq 'user') { $question = $text; $trouble = undef; @said = (); next; }
			# the action line is not words to judge; the final wording is
			next if $role eq 'assistant' && $text =~ /^\s*\{/;
			push @said, (($role eq 'tool' ? '  observed: ' : '  said: ') . substr($text, 0, 300));
			shift @said while scalar @said > 12;
			$trouble //= $text if &guide_watch_trouble($text);
			next unless $role eq 'assistant' && defined $trouble;
			last if $noted >= 2;
			$noted++;
			my $sample = 'The person asked: ' . (defined $question && length $question ? $question : '(nothing said)') . "\n"
				. "The Guide's turn went:\n" . join("\n", @said) . "\n"
				. 'The line that reads like trouble: ' . substr($trouble, 0, 500);
			&staged_fix_note({
				source => 'guide',
				signature_text => 'guide: ' . ($question // '') . ' | ' . $trouble,
				sample => $sample,
			});
			$trouble = undef;
		}
	}
	# forget conversations that are gone
	foreach my $key ( keys %{$seen} ) { delete $seen->{$key} unless $live{$key}; }
	write_file(&guide_watch_state_file(), encode_json($seen));
	return 1;
}

# The propose loop runs in President, which never loads Manager.pl, so it carries
# its own copy of the repo-path guard (the same rules as subs::coding_path).
# Nothing here can change the repo: every write is staged, so the guard only has
# to keep the agent's reading inside the tree.
sub error_watch_repo { return &subs::home('~/jawnos'); }

sub error_watch_rel {
	my $rel = shift;
	$rel = '' unless defined $rel;
	$rel =~ s{^\./+}{};
	$rel =~ s{^/+}{};
	return $rel;
}

sub error_watch_path {
	my $rel = &error_watch_rel(shift);
	return undef if $rel =~ /(^|\/)\.\.(\/|$)/;
	return undef if $rel =~ /[\x00-\x1f"`\\\$;(){}|&<>]/;
	return undef if $rel =~ m{^(?:\.git|\.secrets|\.president|releases|voices)(?:/|$)};
	return undef if $rel =~ m{(?:^|/)\.env(?:$|\.)};
	return undef if $rel =~ m{(?:^|/)(?:jawnos\.db(?:-wal|-shm)?|initial\.enc)$};
	return undef if $rel eq 'config.json';
	return undef if $rel eq '.shots/ticket.txt';
	return &error_watch_repo() . ($rel eq '' ? '' : '/' . $rel);
}

# Check a staged file's text before it is even proposed, against a temp copy of
# the same basename (the tree is not written to here). The same verifier the
# Apply path runs, so the agent learns at once instead of staging a file that
# breaks the tree. Returns '' when it passes, else the reason.
sub coding_verify_text {
	my ($rel, $content) = @_;
	return '' unless defined $content && length $content;
	my $repo = &error_watch_repo();
	return '' unless -f "$repo/scripts/verify_change.pl";
	my $ext = ($rel =~ /\.([A-Za-z0-9]+)$/) ? lc $1 : '';
	return '' unless $ext =~ /^(?:pl|pm|t|js|mjs|cjs|ep|json)$/;
	# perl -c runs a file's BEGIN blocks, so compiling proposed Perl would run
	# the model's text before anyone applied it. The compile happens after the
	# write, against the tree that is about to be tested, not against a proposal.
	return '' if $ext =~ /^(?:pl|pm|t)$/;
	require File::Temp;
	require File::Spec;
	my ($fh, $tmp) = File::Temp::tempfile('jawn_verify_XXXXXX', SUFFIX => '.' . $ext, DIR => File::Spec->tmpdir, UNLINK => 1);
	return '' unless $fh && $tmp;
	print $fh $content;
	close $fh;
	my $out = `cd "$repo" && perl scripts/verify_change.pl --allow-shrink "$tmp" 2>&1`;
	my $code = $? >> 8;
	$out = '' unless defined $out;
	unlink $tmp;
	return '' if $code == 0;
	my ($line) = grep { /FAIL|rror|shrank|Unexpected|syntax/ } split /\n/, $out;
	$line = $out unless defined $line;
	$line =~ s/^\s+|\s+$//g;
	return substr($line, 0, 300);
}

# The propose mode's tool loop: the same verbs' shape, but write only stages the
# whole file, so the agent can change nothing here.
sub coding_propose_execute {
	my ($action, $staged) = @_;
	my $a = $action->{'action'} // '';
	if ($a eq 'list') {
		my $abs = &error_watch_path($action->{'path'});
		return 'refused: that path is outside the repo or not allowed' unless $abs;
		return 'no such folder' unless -d $abs;
		opendir(my $dh, $abs) or return 'could not read that folder';
		my @names = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
		closedir($dh);
		@names = map { -d "$abs/$_" ? "$_/" : $_ } @names;
		@names = @names[0 .. 199] if @names > 200;
		return join("\n", @names);
	}
	if ($a eq 'read') {
		my $abs = &error_watch_path($action->{'path'});
		return 'refused: that path is outside the repo or not allowed' unless $abs;
		return 'no such file' unless -f $abs;
		my $text = eval { read_file($abs) } // '';
		$text =~ s/\x00//g;
		if (length $text > 40000) { $text = substr($text, 0, 40000) . "\n... [trimmed]"; }
		return length($text) ? $text : '(empty file)';
	}
	if ($a eq 'write') {
		my $abs = &error_watch_path($action->{'path'});
		return 'refused: that path is outside the repo or not allowed' unless $abs;
		my $rel = &error_watch_rel($action->{'path'});
		my $content = $action->{'content'};
		$content = '' unless defined $content;
		return 'refused: a staged file is capped at 300000 bytes' if length($content) > 300000;
		return 'refused: at most 10 files in one proposal' if scalar(keys %{$staged}) >= 10 && !exists $staged->{$rel};
		$staged->{$rel} = $content;
		my $problem = &coding_verify_text($rel, $content);
		return 'staged ' . length($content) . ' bytes for ' . $rel . ' (not written; a person must apply it)'
			. ($problem ? ' - IT DOES NOT PASS THE VERIFIER: ' . $problem . '; write the file whole and correct it' : '');
	}
	if ($a eq 'run') {
		my $cmd = $action->{'command'} // '';
		$cmd =~ s/^\s+|\s+$//g;
		return 'refused: only perl -c, perl scripts/*, prove and read-only git are allowed here'
			unless $cmd =~ m{^(?:perl\s+-c\s+[\w./-]+|perl\s+scripts/[\w./-]+(?:\s+[^\n;|&]*)?|prove(?:\s+[^\n;|&]*)?|git\s+(?:status|diff|log|show|rev-parse|branch|remote)(?:\s+[^\n;|&]*)?)$};
		# The command still runs through a shell: `$(...)`, a backtick or a quote
		# in an argument would run as code, so no metacharacter may survive.
		return 'refused: a shell metacharacter in a run command'
			if $cmd =~ /[\$`\\'"<>(){}*?!\[\]\n]/;
		my $repo = &error_watch_repo();
		my $out = `cd "$repo" && $cmd 2>&1`;
		$out = '' unless defined $out;
		if (length $out > 8000) { $out = substr($out, 0, 8000) . "\n... [trimmed]"; }
		return $out =~ /\S/ ? $out : '(no output)';
	}
	if ($a eq 'say' || $a eq 'done') {
		return $action->{'text'} // '';
	}
	return 'unknown action: ' . $a;
}

# The tracked protocol text the manager-side agent also follows (baked from the
# gitignored AGENTS.md into docs/coding_agent_protocols.md), so the watcher's
# proposals obey the same rules. Cached by mtime.
sub coding_protocols_text {
	my $repo = &error_watch_repo();
	my $path = -f "$repo/docs/coding_agent_protocols.md" ? "$repo/docs/coding_agent_protocols.md"
		: (-f "$repo/AGENTS.md" ? "$repo/AGENTS.md" : '');
	return '' unless length $path;
	my $mtime = (stat($path))[9] // 0;
	if (!defined $coding_protocols_cache || ($coding_protocols_mtime // 0) != $mtime) {
		my $text = eval { read_file($path) } // '';
		if (length $text > 20000) { $text = substr($text, 0, 20000) . "\n... [trimmed]"; }
		$coding_protocols_cache = $text;
		$coding_protocols_mtime = $mtime;
	}
	return $coding_protocols_cache // '';
}

# One bounded propose run for a staged error: the model picks the next action,
# write stages the file, repeat until done or the step cap. The proposal lands
# on the row as whole files, never as a change to the tree.
sub coding_propose_fix {
	my $row = shift;
	return unless ref $row eq 'HASH' && $row->{'uuid'};
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' })
		|| &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
	unless ($model) {
		&subs::db_update('staged_fixes', { note => 'no Coding model is set (Configure -> Plat)' }, { uuid => $row->{'uuid'} });
		return;
	}
	# One machine proposes each fix: a stable hash over the house picks the fix's
	# home and only that machine spends on it, so two machines never pay to propose
	# the same repair. The cost is bounded below by the house-wide purse.
	my $job = 'fix:' . ($row->{'source'} || 'log') . ':' . ($row->{'signature'} || $row->{'uuid'});
	unless (&ai_job_may_run($job, 7 * 24 * 3600 * 1000)) {
		&subs::db_update('staged_fixes', { note => 'the house ledger has another machine on this one' }, { uuid => $row->{'uuid'} });
		return 'another machine';
	}
	&ai_job_note($job);
	# The purse: a proposal costs a handful of calls. The day's ceiling (a
	# setting, in tokens) stops the watch before a runaway spend, and one run
	# stops at its own cap below.
	my $budget = &subs::setting_grabber({ app => 'mail', setting => 'error_watch_budget' });
	$budget = (defined $budget && $budget =~ /^\d+$/) ? ($budget + 0) : 1000000;   # unset: a million a day; 0: no cap
	my $spent_today = &watch_tokens_spent();
	if ($budget && $spent_today >= $budget) {
		&subs::db_update('staged_fixes', { note => "the day's token budget is spent ($spent_today/$budget)" }, { uuid => $row->{'uuid'} });
		$log->info('error watch: proposal skipped for "' . substr($row->{'signature'} || '?', 0, 80) . "\" - day's token budget is spent ($spent_today/$budget)") if defined $log;
		return 'over-budget';
	}
	my $ai_start = { calls => $ai_tokens->{'calls'}, in => $ai_tokens->{'in'}, out => $ai_tokens->{'out'} };
	# the coding agent's thinking effort, set in Configure -> Plat beside its model
	my $thinking = &subs::ai_role_thinking_effective('coding_assistant');
	# a fallback model's stand-down notice must not speak from this fork
	local $say_quiet = 1;
	require &error_watch_repo() . '/help.pl';
	my $system = &help::coding_propose_prompt();
	my $protocols = &coding_protocols_text();
	$system .= "\n\nCodebase protocols (follow these):\n" . $protocols . "\n" if length $protocols;
	$system .= "\nRight now it is " . localtime(&subs::rightNow() / 1000)->strftime('%A, %B %d %Y, %I:%M%P') . '.';
	my $where = (($row->{'source'} || '') eq 'js')
		? 'A FATAL JAVASCRIPT ERROR WAS REPORTED BY A BROWSER IN THE JAWNOS INTERFACE:'
		: (($row->{'source'} || '') eq 'guide')
		? "A GUIDE CONVERSATION DID NOT ACCOMPLISH WHAT THE PERSON ASKED. The transcript follows; adjust the Guide's training so this would land next time. Its rules live in help.pl (actions_prompt), its verbs and their descriptions in gb.pl (guide_tools), and the acting loop's resolvers in Manager.pl and public/js/manager/help.js. A rule or a verb's words usually beats code - change the code only when words cannot reach:"
		: 'AN ERROR WAS CAUGHT IN THE RUNNING SYSTEM (source: ' . ($row->{'source'} || '?') . ' log):';
	my @lines = (
		$where,
		'---',
		($row->{'sample'} || $row->{'signature'}),
		'---',
		'It has been seen ' . ($row->{'tally'} || 1) . ' time(s). Propose one small fix.',
		'Reply with the single next JSON action.'
	);
	my (%staged, @steps);
	my $final = '';
	my $tries = 0;
	while ($tries++ < 10) {
		my ($text, $err) = &subs::evaluation_model_call_with_fallback($model, &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant_fallback' }), $system, join("\n", @lines), $thinking, 'coding_assistant');
		if ($err || !$text) {
			push @steps, { action => { action => 'error' }, observation => ($err || 'the model returned nothing') };
			$final = 'the model could not be reached: ' . ($err || 'no answer');
			last;
		}
		my $action = eval { decode_json $text };
		unless ($action && $action->{'action'}) {
			if ($text =~ /(\{.*\})/s) { $action = eval { decode_json $1 }; }
		}
		unless ($action && $action->{'action'}) { $final = $text; last; }
		my $obs = &coding_propose_execute($action, \%staged);
		push @steps, { action => $action, observation => $obs };
		push @lines, 'ACTION: ' . encode_json($action);
		push @lines, 'OBSERVATION: ' . $obs;
		if ($action->{'action'} eq 'done' || $action->{'action'} eq 'say') { $final = $action->{'text'} // ''; last; }
		if (($ai_tokens->{'in'} + $ai_tokens->{'out'}) - ($ai_start->{'in'} + $ai_start->{'out'}) > 80000) {
			$final = "stopped: this run's token cap";
			last;
		}
	}
	my $files = scalar(keys %staged) ? encode_json(\%staged) : '';
	&subs::db_update('staged_fixes', {
		status => ($files ? 'proposed' : 'failed'),
		model => $model,
		summary => substr($final // '', 0, 4000),
		files => $files,
		steps => encode_json(\@steps),
		note => ($files ? '' : 'no file change was proposed'),
	}, { uuid => $row->{'uuid'} });
	my $run_calls = $ai_tokens->{'calls'} - $ai_start->{'calls'};
	my $run_in = $ai_tokens->{'in'} - $ai_start->{'in'};
	my $run_out = $ai_tokens->{'out'} - $ai_start->{'out'};
	&watch_tokens_add($run_in + $run_out);
	if (defined $log) {
		$log->info('error watch: ' . ($files ? 'proposed' : 'no proposal') . ' for "' . substr($row->{'signature'} || '?', 0, 80) . '" - '
			. $run_calls . ' call(s), in ' . $run_in . ' out ' . $run_out . ' tokens, day ' . &watch_tokens_spent() . ($budget ? '/' . $budget : ' (no cap)'));
	}
	return $files ? 'proposed' : 'failed';
}

# Where this machine takes code updates from. A house setting
# (`sync/update_method`, device => 'all'), so the Dev panel writes it once and
# every machine's next settings pull carries it. Blank or unknown means any:
# origin first, a peer as the fallback, which is what the watcher always did.
sub sync_update_method_get {
	my $v = &subs::setting_grabber({ app => 'sync', setting => 'update_method', device => 'all' });
	$v = &subs::setting_grabber({ app => 'sync', setting => 'update_method' }) unless defined $v && length $v;
	$v = 'any' unless defined $v && $v =~ /^(?:none|github|peers|any|manual_github|manual_peers)$/;
	return $v;
}

# How often this machine's code watcher runs. A per-machine setting: a dev box
# can follow the trunk every 30 seconds while a server sleeps for days.
# The list is the Dev panel's Check every menu, and the two must agree; an
# unknown value falls back to the hour, which is the slow pool's pace and the
# behaviour before this control existed.
sub sync_update_interval_get {
	my ($device) = @_;
	$device = &subs::signatorial_designer() unless defined $device && length $device;
	my %q = (app => 'sync', setting => 'update_interval');
	$q{'device'} = $device if defined $device && length $device;
	my $v = &subs::setting_grabber(\%q);
	$v = &subs::setting_grabber({ app => 'sync', setting => 'update_interval' })
		unless defined $v && length $v;
	return 3600 unless defined $v && $v =~ /^(?:30|60|120|300|600|900|1200|1800|2700|3600|7200|10800|21600|32400|43200|86400|172800|259200|518400|604800|1209600|1814400|2592000)$/;
	return int $v;
}

# Which branch this machine's code watcher follows. A per-machine setting, like
# its cadence: a house box can ride `working` (the newest landed, tested code)
# while a release candidate stays on `main`. `main` is the fallback, which is
# what every machine followed before this control existed, and an unknown value
# must never point the watcher at a branch nobody publishes.
sub sync_update_branch_get {
	my ($device) = @_;
	$device = &subs::signatorial_designer() unless defined $device && length $device;
	my %q = (app => 'sync', setting => 'update_branch');
	$q{'device'} = $device if defined $device && length $device;
	my $v = &subs::setting_grabber(\%q);
	$v = &subs::setting_grabber({ app => 'sync', setting => 'update_branch' })
		unless defined $v && length $v;
	return 'main' unless defined $v && $v =~ /^(?:main|working)$/;
	return $v;
}

# Where the 06:00 coding nightly pushes. `coding_push_repo` is the JawnOS
# checkout and `coding_app_push_repo` the Android app checkout; empty means the
# checkout's own remote (origin / fork). The value is `owner/name` or an https
# URL, never spaces or credentials. The same rules live in
# qa/coding_night/lib/CodingNight.pm (the fenced runner cannot boot this file),
# and t/92 asks both so they cannot drift.
our %CODING_PUSH_SETTING = (
	repo => 'coding_push_repo',
	app  => 'coding_app_push_repo',
);

sub coding_push_repo_setting {
	my ($which) = @_;
	$which = 'app' if defined $which && $which eq 'app';
	return $CODING_PUSH_SETTING{$which} || $CODING_PUSH_SETTING{'repo'};
}

sub coding_push_repo_default {
	my ($which) = @_;
	return (defined $which && $which eq 'app') ? 'fork' : 'origin';
}

sub coding_push_repo_valid {
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/^\s+|\s+$//g;
	return { ok => 1, value => '', kind => 'default' } unless length $value;
	return { ok => 0, error => 'A push repo cannot contain spaces.' }
		if $value =~ /\s/;
	return { ok => 0, error => 'A push repo cannot carry credentials (user or token@host).' }
		if $value =~ /\@/;

	if ($value =~ m{^https://([A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?)(?::\d{1,5})?/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$}i) {
		my ($host, $owner, $name) = ($1, $2, $3);
		if ($owner !~ /^\.+$/ && $name !~ /^\.+$/) {
			return { ok => 1, value => $value, kind => 'url', host => $host, slug => "$owner/$name" };
		}
	}
	elsif ($value =~ m{^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?$}) {
		my ($owner, $name) = ($1, $2);
		if ($owner !~ /^\.+$/ && $name !~ /^\.+$/) {
			return { ok => 1, value => $value, kind => 'owner', slug => "$owner/$name" };
		}
	}
	return { ok => 0, error => 'Use owner/name or an https:// URL with owner/name.' };
}

sub coding_push_repo_target {
	my ($value) = @_;
	return '' unless defined $value && length $value;
	return $value if $value =~ m{^https://}i;
	(my $slug = $value) =~ s/\.git$//;
	return "https://github.com/$slug.git";
}

sub coding_push_repo_slug {
	my ($value) = @_;
	return '' unless defined $value && length $value;
	(my $slug = $value) =~ s/\.git$//;
	$slug =~ s{^https://[^/]+/}{}i;
	return $slug;
}

# The saved value and what it resolves to. A bad row is an error, not a silent
# fallback: the panel must show the operator that the setting is unusable.
sub coding_push_repo_get {
	my ($which, $opts) = @_;
	$opts ||= {};
	$which = 'app' if defined $which && $which eq 'app';
	my $setting  = coding_push_repo_setting($which);
	my $fallback = coding_push_repo_default($which);
	my $raw;
	if (ref $opts->{'grabber'} eq 'CODE') {
		$raw = $opts->{'grabber'}->($setting);
	}
	else {
		$raw = &subs::setting_grabber({ app => '__president', setting => $setting, device => 'all' });
		$raw = &subs::setting_grabber({ app => '__president', setting => $setting })
			unless defined $raw && length $raw;
	}
	$raw = '' unless defined $raw;
	my $check = coding_push_repo_valid($raw);
	unless ($check->{'ok'}) {
		return {
			ok => 0, which => $which, setting => $setting, raw => $raw,
			value => $raw, target => $fallback, effective => $fallback,
			fallback => $fallback, error => $check->{'error'},
		};
	}
	my $value  = $check->{'value'};
	my $target = length $value ? coding_push_repo_target($value) : $fallback;
	return {
		ok => 1, which => $which, setting => $setting, raw => $raw,
		value => $value, target => $target, effective => $target,
		fallback => $fallback,
		slug => length $value ? coding_push_repo_slug($value) : '',
	};
}

sub coding_push_repo_save {
	my ($which, $value, $opts) = @_;
	$opts ||= {};
	$which = 'app' if defined $which && $which eq 'app';
	my $check = coding_push_repo_valid($value);
	unless ($check->{'ok'}) {
		return { ok => 0, which => $which, error => $check->{'error'} };
	}
	my $setting = coding_push_repo_setting($which);
	if (ref $opts->{'setter'} eq 'CODE') {
		$opts->{'setter'}->($setting, $check->{'value'});
	}
	else {
		&subs::setting_setter({
			app     => '__president',
			setting => $setting,
			device  => 'all',
			value   => $check->{'value'},
		});
	}
	my $fallback = coding_push_repo_default($which);
	return {
		ok => 1, which => $which, setting => $setting,
		value => $check->{'value'},
		effective => length $check->{'value'} ? coding_push_repo_target($check->{'value'}) : $fallback,
	};
}

# The newest peer that can fast-forward this checkout. The watcher's fallback
# and the manual button share it: sort by the version the peer advertises, keep
# the few that are newer, and stop at the first true fast-forward. A peer whose
# history merely shares a commit with ours is not enough - ff_only refuses the
# reset, which is what keeps a rewritten peer history from dragging a machine
# backward. Returns (status, output, peer row).
sub git_peer_update_best {
	my ($opts) = @_;
	my $repo = $opts->{'repo'} || '.';
	my $mine = &subs::jawn_version();
	my $rms = eval { &subs::db_select('remote_machines')->hashes } || [];
	my @peers = sort { &subs::version_cmp($b->{'version'}, $a->{'version'}) }
		grep { $_->{'version'} && &subs::version_newer($_->{'version'}, $mine) } @{$rms};
	@peers = @peers[0 .. 2] if scalar @peers > 3;
	my ($last_status, $last_out) = ('none', '');
	foreach my $rm ( @peers ) {
		my ($st, $o) = &subs::git_peer_update({ repo => $repo, rm => $rm, ff_only => 1, force => $opts->{'force'} });
		return ($st, $o, $rm) if $st eq 'updated' || $st eq 'reset' || $st eq 'dirty';
		$last_status = $st;
		$last_out = $o;
	}
	return ($last_status, $last_out, undef);
}

# A tree seeded from the image has no .git, so git_repo_update can only answer
# no-repo. The boot unit owns turning it into a checkout; the Update now button
# delegates to that same program, so a fresh image can update without a
# re-image and both paths agree. The program's final JAWNOS_UPDATE_STATUS line
# speaks the vocabulary update_now already uses.
sub git_bootstrap_update {
	my ($opts) = @_;
	my $repo = $opts->{'repo'} || &subs::home('~/jawnos');
	require Cwd;
	$repo = eval { Cwd::abs_path($repo) } || $repo;
	my $installed = '/usr/local/bin/jawnos-update';
	my @command;
	if (-x $installed) {
		@command = ($installed);
	}
	elsif (-f "$repo/scripts/jawnos_update.pl") {
		@command = ($^X, "$repo/scripts/jawnos_update.pl");
	}
	else {
		return ('no-repo', '');
	}
	local $ENV{'JAWNOS_REPO'} = $repo;
	local $ENV{'JAWNOS_HOME'} = &subs::home('~');
	local $ENV{'JAWNOS_BRANCH'} = $opts->{'branch'} || &subs::sync_update_branch_get();
	open(my $fh, '-|', @command) or return ('error', "cannot run the updater: $!");
	local $/;
	my $out = <$fh>;
	close $fh;
	my $code = $? >> 8;
	$out = '' unless defined $out;
	my ($status) = $out =~ /^JAWNOS_UPDATE_STATUS=([A-Za-z-]+)/m;
	$out =~ s/^JAWNOS_UPDATE_STATUS=\S+\s*$//mg;
	return ($status || ($code ? 'error' : 'current'), $out);
}

# An explicit update, from the Dev panel's button. Unlike the watcher this may
# run whichever source the method names, and for None (or Any) it tries GitHub
# first and then a peer: pressing the button is the person's own instruction,
# so the automatic-update switch does not veto it. Never force unless the caller
# says so - force is what discards tracked local changes.
sub update_now {
	my ($opts) = @_;
	my $repo = $opts->{'repo'} || '.';
	my $force = $opts->{'force'} ? 1 : 0;
	my $method = $opts->{'method'} || &subs::sync_update_method_get();
	my $branch = $opts->{'branch'} || &subs::sync_update_branch_get();
	my $was_dirty = 0;
	if ($force) {
		my $git = &subs::git_binary();
		my $d = `cd "$repo" && "$git" status --porcelain --untracked-files=no 2>/dev/null`;
		$was_dirty = ($d =~ /\S/) ? 1 : 0;
	}
	my ($status, $out, $source) = ('none', '', '');
	# A seeded image's tree has no .git. The boot unit bootstraps it, and this
	# button hands the job to the same program; the program installs the new
	# modules before its own perl -c check (that check needs them).
	my $bootstrapped = (-d "$repo/.git") ? 0 : 1;
	if ($bootstrapped) {
		($status, $out) = &subs::git_bootstrap_update({ repo => $repo, branch => $branch });
		$source = 'github';
	}
	elsif ($method eq 'github' || $method eq 'manual_github') {
		($status, $out) = &subs::git_repo_update({ repo => $repo, force => $force, branch => $branch });
		$source = 'github';
	}
	elsif ($method eq 'peers' || $method eq 'manual_peers') {
		($status, $out, undef) = &subs::git_peer_update_best({ repo => $repo, force => $force });
		$source = 'peers';
	}
	else {
		($status, $out) = &subs::git_repo_update({ repo => $repo, force => $force, branch => $branch });
		$source = 'github';
		unless ($status eq 'updated' || $status eq 'reset' || $status eq 'current') {
			my ($pst, $pout) = &subs::git_peer_update_best({ repo => $repo, force => $force });
			if ($pst ne 'none') {
				($status, $out, $source) = ($pst, $pout, 'peer');
			}
		}
	}
	# A confirmed force on an already-current tree has nothing to pull, but it
	# still promised to discard the tracked changes that blocked the watcher.
	if ($force && $was_dirty && $status eq 'current') {
		my $git = &subs::git_binary();
		$out = `cd "$repo" && "$git" reset --hard HEAD 2>&1`;
		$status = 'reset';
	}
	# New code may `use` a module the image did not ship. The updater already
	# installed it before its syntax check; this run covers the checkout path and
	# is a cheap no-op after the updater.
	&subs::install_local_modules($repo)
		if $status eq 'updated' || $status eq 'reset' || $status eq 'peer/updated';
	# The system packages the new tree names (core commands and the desktop
	# extras) are the half a person may have to authorise: install_system_dependencies
	# uses sudo -n when it can and otherwise writes the request the manager asks
	# about after the restart.
	my $dependencies;
	if ($status eq 'updated' || $status eq 'reset' || $status eq 'peer/updated') {
		$dependencies = &subs::install_system_dependencies($repo);
	}
	# A pull rewrites ./VERSION under this live process, so the cached number is
	# the one from before the update. Forget it here and whoever asks next (the
	# update route paints it into the Configure bar) reads the new version.
	if ($status eq 'updated' || $status eq 'reset' || $status eq 'peer/updated') {
		&subs::jawn_version_forget();
	}
	return { status => $status, output => $out, source => $source, method => $method,
		(defined $dependencies ? (dependencies => $dependencies) : ()) };
}

1;
