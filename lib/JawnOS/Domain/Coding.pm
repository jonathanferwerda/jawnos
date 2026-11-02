package subs;

# The Coding agent's background run.
#
# A run used to be one blocking request: the browser held the connection while
# the model, the tools and the git routine ran, so a reload, a tree restart or
# the agent's own "restart" step killed the answer it had already earned. It is
# a Minion job now, on its own `coding` queue, and perl/Coding.pl consumes that
# queue from a process the master starts and leaves alone across a tree restart.
#
# The job row is Minion's; the run the panel watches is a per-device setting
# (`coding_run_<id>`), written after every step. That is what lets a re-opened
# page reattach to a run that is still going, and read the finished one without
# the browser having been present for it.
#
# The heavy lifting stays where it was: Manager::coding_execute (the checked
# toolset), Manager::coding_system_prompt (the prompt plus AGENTS.md) and
# Manager::coding_conversation_*. The worker boots the app before it runs a
# job, so those helpers are there; a test that only exercises the job record
# does not need them.
use strict;
use warnings;
use utf8;

use Mojo::JSON qw(decode_json encode_json);
use Minion;
use File::Temp ();
use Digest::SHA ();

# The coding queue is its own SQLite file, not the tree's minion.db. The master
# wipes ~/.president on a reload (that is how the tree gets a clean run state),
# and a queued coding run must not be part of what that clears. Both the web
# process (enqueue, poll) and perl/Coding.pl (consume) open this one.
our $coding_minion;

sub coding_minion {
	unless ($coding_minion) {
		my $dir = &subs::home('~/.president');
		$coding_minion = Minion->new(SQLite => $dir . '/coding-queue.db');
		$coding_minion->add_task(coding_run => \&coding_run_job);
	}
	return $coding_minion;
}

# How much of a tool's answer the panel keeps. The model still sees all of it;
# this is the step list a person reads, so a 40 KB file dump is trimmed here.
our $coding_step_view_bytes = 1200;

# How much of the model's reasoning the panel keeps beside a step.
our $coding_reasoning_view_bytes = 4000;

# The number of model turns one run gets, the same cap the old request had.
our $coding_run_turns = 12;

# How many turns a child one parent hands a task to may take, and how many
# children one run may use. A subagent is bounded on purpose: it is an
# investigation, not a second run that can go on spending tokens by itself.
our $coding_child_turns = 6;

# How much of the live answer the panel keeps while the model is thinking. The
# newest text is the useful part, so the tail is kept and the cut is marked.
our $coding_live_bytes = 4000;

# How many subagents one run may start (the fallback when no setting is
# readable), and how deep one may go. A child is depth 1, so the depth check
# refuses a child that asks for another child.
our $coding_child_max = 10;

# The configured cap: Configure -> Plat -> Coding -> Subagents. A missing,
# empty or non-numeric setting falls back to the same ten, zero turns
# subagents off, and anything above ten is capped at ten.
sub coding_child_max_setting {
	my $n = &subs::setting_grabber({ app => 'mail', setting => 'coding_subagents' });
	return $coding_child_max unless defined $n && "$n" =~ /^[0-9]+$/;
	$n = $n + 0;
	return $coding_child_max if $n > $coding_child_max;
	return $n;
}

# A commit is the one coding action that writes the repo's history, so it waits
# for a person when review is on. The setting is on unless it was explicitly
# turned off: a missing or empty row means the default, not "off".
sub coding_review_setting {
	my $v = &subs::setting_grabber({ app => 'mail', setting => 'coding_review' });
	return 1 unless defined $v && length "$v";
	$v = "$v";
	$v =~ s/^\s+|\s+$//g;
	return lc($v) eq 'off' ? 0 : 1;
}

# Snapshot a run for the panel. `steps` is the whole list, so a poller can
# render only the new tail; observations in it are already trimmed.
sub coding_run_state_save {
	my ($id, $state) = @_;
	return 0 unless defined $id && $id =~ /^[0-9]+$/ && ref $state eq 'HASH';
	&subs::setting_setter({
		app     => '__president',
		setting => 'coding_run_' . $id,
		value   => encode_json($state),
	});
	return 1;
}

sub coding_run_state_load {
	my ($id) = @_;
	return {} unless defined $id && $id =~ /^[0-9]+$/;
	my $raw = &subs::setting_grabber({ app => '__president', setting => 'coding_run_' . $id });
	my $state = eval { decode_json $raw } if defined $raw && length $raw;
	return ref $state eq 'HASH' ? $state : {};
}

# Queue a run and remember it against the conversation, so a panel that opens
# later finds the newest run without knowing its id.
sub coding_run_enqueue {
	my ($task, $conversation) = @_;
	$task = '' unless defined $task;
	$conversation = 'coding' unless defined $conversation && length $conversation;
	$conversation =~ s/[^A-Za-z0-9_-]//g;
	$conversation = 'coding' unless length $conversation;
	my $minion = &coding_minion();
	my $id = $minion->enqueue(
		coding_run => [ { task => $task, conversation => $conversation } ],
		{ queue => 'coding', attempts => 1 }
	);
	&coding_run_state_save($id, {
		run          => $id + 0,
		conversation => $conversation,
		task         => $task,
		state        => 'queued',
		steps        => [],
		queued       => &subs::rightNow(),
		updated      => &subs::rightNow(),
	});
	&subs::setting_setter({
		app     => '__president',
		setting => 'coding_run_for_' . $conversation,
		value   => $id,
	});
	return $id;
}

# The run the panel for `$conversation` should show: the newest one asked for,
# whether it is queued, active or done. A conversation that never ran anything
# answers `none` rather than an error.
sub coding_run_current {
	my ($conversation) = @_;
	$conversation = 'coding' unless defined $conversation && length $conversation;
	$conversation =~ s/[^A-Za-z0-9_-]//g;
	$conversation = 'coding' unless length $conversation;
	my $id = &subs::setting_grabber({ app => '__president', setting => 'coding_run_for_' . $conversation });
	return { run => 0, conversation => $conversation, state => 'none', steps => [], current => {}, worker => &coding_worker_alive() }
		unless defined $id && $id =~ /^[0-9]+$/;
	return &coding_run_view($id);
}

sub coding_worker_alive {
	my $path = &subs::home('~/.president/coding.pid');
	return 0 unless -f $path;
	open(my $fh, '<', $path) or return 0;
	my $pid = <$fh>;
	close $fh;
	$pid = '' unless defined $pid;
	$pid =~ s/\s+//g;
	return 0 unless $pid =~ /^[0-9]+$/ && kill(0, $pid);
	# a recycled pid is not a worker; the command line says which it is
	if (open(my $cf, '<', "/proc/$pid/cmdline")) {
		local $/;
		my $cmd = <$cf>;
		close $cf;
		return 0 unless defined $cmd && $cmd =~ /Coding\.pl/;
	}
	return 1;
}

sub coding_run_view {
	my ($id) = @_;
	my $state = &coding_run_state_load($id);
	my $view = {
		run          => (defined $id && $id =~ /^[0-9]+$/) ? $id + 0 : 0,
		conversation => ($state->{'conversation'} // ''),
		task         => ($state->{'task'} // ''),
		state        => ($state->{'state'} // 'none'),
		steps        => (ref $state->{'steps'} eq 'ARRAY' ? $state->{'steps'} : []),
		current      => (ref $state->{'current'} eq 'HASH' ? $state->{'current'} : {}),
		pending_commit => (ref $state->{'pending_commit'} eq 'HASH' ? $state->{'pending_commit'} : {}),
		final        => ($state->{'final'} // ''),
		version      => ($state->{'version'} // ''),
		title        => ($state->{'title'} // ''),
		error        => ($state->{'error'} // ''),
		queued       => ($state->{'queued'} // 0) + 0,
		updated      => ($state->{'updated'} // 0) + 0,
		finished     => ($state->{'finished'} // 0) + 0,
		cancel       => ($state->{'cancel'} // 0) ? 1 : 0,
		worker       => &coding_worker_alive(),
	};
	# A run whose job row vanished (the master wipes ~/.president/minion.db on
	# a reload) and whose worker never wrote a finish is stale, not forever
	# queued. Say so instead of leaving the panel polling.
	my $job = eval { &coding_minion()->job($id) };
	if ($job) {
		my $info = eval { $job->info } || {};
		my $minion_state = $info->{'state'} // '';
		if ($minion_state eq 'failed' && ($view->{'state'} eq 'queued' || $view->{'state'} eq 'active')) {
			$view->{'state'} = 'failed';
			$view->{'error'} = $info->{'error'} if defined $info->{'error'} && length $info->{'error'};
		}
	}
	elsif ($view->{'state'} eq 'queued' || $view->{'state'} eq 'active') {
		$view->{'state'} = 'stale';
		$view->{'error'} = 'the background coding process is not running this job';
	}
	# A review only a running worker will ever take. Polling it forever, with
	# buttons that answer into the void, is worse than saying it is over.
	if ($view->{'state'} eq 'awaiting_approval' && !$view->{'worker'}) {
		$view->{'state'} = 'stale';
		$view->{'error'} = 'the background coding process is not running, so nothing would take the answer';
	}
	return $view;
}

# Ask a running job to stop after the step it is on. Minion has no cross-process
# cancel for a job already executing; the loop reads this flag between steps.
sub coding_run_cancel {
	my ($id) = @_;
	my $state = &coding_run_state_load($id);
	return 0 unless ref $state eq 'HASH' && scalar keys %{$state};
	$state->{'cancel'} = 1;
	$state->{'updated'} = &subs::rightNow();
	&coding_run_state_save($id, $state);
	&coding_run_push($id, $state->{'conversation'});
	return 1;
}

# The model's reply as one action, or undef when the turn was prose. Kept pure
# so the fallback parsing is testable without a model.
sub coding_parse_action {
	my ($text) = @_;
	return undef unless defined $text && length $text;
	my $action = eval { decode_json $text };
	unless (ref $action eq 'HASH' && ($action->{'action'} // '') ne '') {
		if ($text =~ /(\{.*\})/s) { $action = eval { decode_json $1 }; }
	}
	return (ref $action eq 'HASH' && ($action->{'action'} // '') ne '') ? $action : undef;
}

sub coding_step_view {
	my ($observation) = @_;
	my $text = defined $observation ? "$observation" : '';
	$text =~ s/\x00//g;
	if (length $text > $coding_step_view_bytes) {
		$text = substr($text, 0, $coding_step_view_bytes) . '…';
	}
	return $text;
}

sub coding_reasoning_view {
	my ($text) = @_;
	$text = defined $text ? "$text" : '';
	$text =~ s/\x00//g;
	if (length $text > $coding_reasoning_view_bytes) {
		$text = substr($text, 0, $coding_reasoning_view_bytes) . '…';
	}
	return $text;
}

# A child's tool vocabulary. write is deliberately not here: it is allowed only
# when the child was given write scope and the path is inside one of its own
# allowed paths (coding_child_write_ok).
sub coding_child_allowed {
	my ($action) = @_;
	$action = '' unless defined $action;
	return 1 if $action eq 'list' || $action eq 'read' || $action eq 'run'
		|| $action eq 'say' || $action eq 'done';
	return 0;
}

# A child may run checks and read-only commands, but the buttons that ship or
# tear the house down are the parent's alone. `run` otherwise reaches every
# `perl scripts/*`, restart.pl and manager_killer.pl included.
sub coding_child_run_ok {
	my ($command) = @_;
	my $c = defined $command ? "$command" : '';
	$c =~ s/^\s+|\s+$//g;
	return 0 if $c =~ m{\bgit\s+(?:commit|push|checkout|reset|clean|branch|tag|merge|rebase)\b};
	return 0 if $c =~ m{scripts/(?:restart|manager_killer|app_build|app_publish|git_bootstrap_update|git_peer_update|version_bump)\.pl};
	return 1;
}

# $max children per run (the configured cap by default), and a child (depth 1)
# may not start one of its own. A max of 0 refuses every child.
sub coding_child_limit_ok {
	my ($depth, $count, $max) = @_;
	$depth = 0 unless defined $depth;
	$count = 0 unless defined $count;
	$max = &coding_child_max_setting() unless defined $max;
	return 0 if $depth >= 1;
	return 0 if $count >= $max;
	return 1;
}

# Is $path a write the child may make? Both sides are normalised the way
# Manager::coding_rel does it (drop a leading ./ or /), then the path must sit
# under one of the allowed paths and must not be one of the things no subagent
# may touch, even when its scope nominally covers them.
sub coding_child_write_ok {
	my ($path, $paths) = @_;
	return 0 unless ref $paths eq 'ARRAY' && scalar @{$paths};
	my $norm = sub {
		my $p = defined $_[0] ? "$_[0]" : '';
		$p =~ s{^\./+}{};
		$p =~ s{^/+}{};
		$p =~ s{/+$}{};
		return $p;
	};
	my $rel = $norm->($path);
	return 0 unless length $rel;
	return 0 if $rel =~ m{(^|/)\.\.(/|$)};
	my @deny = qw(.git VERSION database releases desktop/mkosi);
	foreach my $d (@deny) {
		return 0 if $rel eq $d || index($rel, "$d/") == 0;
	}
	foreach my $allowed (@{$paths}) {
		my $dir = $norm->($allowed);
		next unless length $dir;
		next if $dir =~ m{(^|/)\.\.(/|$)};
		return 1 if $dir eq '.' || $dir eq '';
		return 1 if $rel eq $dir || index($rel, "$dir/") == 0;
	}
	return 0;
}

# A child's last word is sometimes the action object itself (the model quotes
# the JSON back), and a display that shows {"action":"done",...} under the
# parent's step is noise. Peel up to two layers of an action-shaped object and
# return its text; prose is returned unchanged.
sub coding_unwrap_final {
	my ($text) = @_;
	my $out = defined $text ? "$text" : '';
	for (1 .. 2) {
		my $obj = eval { decode_json($out) };
		last unless ref $obj eq 'HASH' && defined $obj->{'text'} && length $obj->{'text'};
		$out = "$obj->{'text'}";
	}
	$out =~ s/^\s+|\s+$//g;
	return $out;
}

# Run one child loop for an `agent` action. It is handed no parent transcript
# and no sink, so its tokens and its view stay small; it can only answer with
# the checked toolset, and write only inside the paths it was given. A failure
# is recorded on the child, never thrown at the parent.
sub coding_run_subagent {
	my ($opt) = @_;
	$opt = {} unless ref $opt eq 'HASH';
	my $action = ref $opt->{'action'} eq 'HASH' ? $opt->{'action'} : {};
	my $task = $action->{'task'} // '';
	$task = "$task";
	my $scope = lc($action->{'scope'} // 'read');
	$scope = 'read' unless $scope eq 'write';
	my @paths = ref $action->{'paths'} eq 'ARRAY' ? @{$action->{'paths'}} : ();
	my $record = {
		task  => $task,
		scope => $scope,
		paths => [ @paths ],
		steps => [],
	};
	my $depth = $opt->{'depth'} // 0;
	my $count = $opt->{'count'} // 0;
	my $max = $opt->{'max'};
	$max = &coding_child_max_setting() unless defined $max;
	unless (&coding_child_limit_ok($depth, $count, $max)) {
		$record->{'error'} = $depth >= 1
			? 'a subagent may not start another subagent'
			: "this run has already used its $max subagents";
		return $record;
	}
	if ($scope eq 'write') {
		my @given = grep { defined $_ && length "$_" } @paths;
		unless (@given) {
			$record->{'error'} = 'write scope needs a non-empty paths list';
			return $record;
		}
	}
	eval {
		my $system = &Manager::coding_system_prompt()
			. "\n\nYou are a subagent. Do only the task below. Do not bump, commit, push or restart, and do not ask for another agent. Read what you need. When done, reply with done and a short summary.";
		my $prompt = 'PARENT TASK: ' . ($opt->{'parent_task'} // '') . "\n"
			. 'SUBAGENT TASK: ' . $task . "\n"
			. 'SCOPE: ' . $scope . "\n"
			. 'ALLOWED PATHS: ' . (@paths ? join(', ', map { "$_" } @paths) : '(any in the repo; read only)');
		my @lines = ($prompt);
		my %touched;
		my $turns = 0;
		while ($turns++ < $coding_child_turns) {
			my ($parts, $err) = &subs::ai_chat_parts_with_fallback(
				$opt->{'model'}, $opt->{'fallback'},
				[ { role => 'system', content => $system },
				  { role => 'user', content => join("\n", @lines) . "\n\nReply with the single next JSON action." } ],
				$opt->{'thinking'}, 'coding_assistant'
			);
			my $text = &subs::ai_parts_text($parts, 'text');
			my $reasoning = &subs::ai_parts_text($parts, 'reasoning');
			if ($err || !defined $text || !length $text) {
				die(($err || 'the model returned nothing') . "\n");
			}
			my $act = &coding_parse_action($text);
			unless ($act) { $record->{'final'} = &coding_unwrap_final($text); last; }
			my $verb = $act->{'action'} // '';
			# say and done are the child's answer, not another tool step; that
			# keeps its record to the work it actually did.
			if ($verb eq 'done' || $verb eq 'say') {
				$record->{'final'} = &coding_unwrap_final($act->{'text'} // '');
				last;
			}
			my $obs;
			if ($verb eq 'write' && $scope eq 'write') {
				$obs = &coding_child_write_ok($act->{'path'}, \@paths)
					? &Manager::coding_execute(undef, $act, \%touched)
					: 'refused: that path is not one of this subagent\'s allowed paths';
			}
			elsif (&coding_child_allowed($verb)) {
				if ($verb eq 'run' && !&coding_child_run_ok($act->{'command'})) {
					$obs = 'refused: a subagent may not ship or restart the tree';
				}
				else { $obs = &Manager::coding_execute(undef, $act, \%touched); }
			}
			else {
				$obs = 'refused: a subagent may not ' . ($verb || 'do that')
					. '; it may list, read, run, say and done'
					. ($scope eq 'write' ? ', and write inside its allowed paths' : '');
			}
			my $step = { action => $act, observation => &coding_step_view($obs) };
			$step->{'reasoning'} = &coding_reasoning_view($reasoning) if length $reasoning;
			push @{$record->{'steps'}}, $step;
			push @lines, 'ACTION: ' . encode_json($act);
			push @lines, 'OBSERVATION: ' . (defined $obs ? $obs : '');
		}
		1;
	};
	if ($@) {
		my $err = $@;
		$err =~ s/\s+$//;
		$record->{'error'} = $err;
	}
	unless (defined $record->{'final'} && length $record->{'final'}) {
		my $last = @{$record->{'steps'}} ? $record->{'steps'}[-1]{'observation'} : '';
		$record->{'final'} = length $last ? $last : 'stopped after ' . scalar(@{$record->{'steps'}}) . ' steps';
	}
	return $record;
}

# A path as one shell word. The review and the commit both build a command line
# from filenames the agent chose, and a name may hold a space - or a `$`, which
# a double-quoted word would expand.
sub coding_shell_quote {
	my $s = defined $_[0] ? "$_[0]" : '';
	$s =~ s/'/'\\''/g;
	return "'" . $s . "'";
}

# The paths a commit stages: what the run wrote, plus VERSION, which the commit
# always includes. The review and the commit read this one list, so what a person
# approves is what the commit stages - VERSION used to be committed unreviewed.
sub coding_review_files {
	my ($touched) = @_;
	my %seen;
	my @files;
	foreach my $f ( ref $touched eq 'HASH' ? sort keys %{$touched} : () ) {
		next unless defined $f && length "$f";
		next if $seen{"$f"}++;
		push @files, "$f";
	}
	my $repo = &subs::coding_repo();
	if (defined $repo && length $repo && -f "$repo/VERSION" && !$seen{'VERSION'}++) {
		push @files, 'VERSION';
	}
	return @files;
}

# The diff a commit would ship, for the person reviewing it, and a fingerprint of
# it. A new file is invisible to `git diff` until it is in an index, so `add -N`
# marks it intent-to-add in a throwaway index seeded from HEAD: the real index is
# never touched, because an intent-to-add left behind by a refused review changes
# what the person's next commit does.
#
# The review fails closed. A path this cannot put on a command line, or a git
# call that fails, is an error - never an empty diff that a caller would read as
# "nothing to review" and auto-approve.
our $coding_diff_view_bytes = 20000;

sub coding_diff_bundle {
	my ($files) = @_;
	my $out = { text => '', hash => '', truncated => 0, error => '' };
	return $out unless ref $files eq 'ARRAY' && scalar @{$files};
	my $repo = &subs::coding_repo();
	unless (defined $repo && length $repo) {
		$out->{'error'} = 'the repository is not set, so the change cannot be shown';
		return $out;
	}
	my @safe;
	foreach my $path ( @{$files} ) {
		my $raw = defined $path ? "$path" : '';
		my $rel = $raw;
		$rel =~ s{^\./+}{};
		$rel =~ s{^/+}{};
		$rel =~ s{/+$}{};
		next unless length $rel;
		# Refused, not rewritten: a rewritten name matches no file (a `+` becomes
		# nothing, a non-ASCII letter loses its bytes) and the empty diff that
		# follows would read as an approval of a change nobody saw.
		if ($rel =~ m{(^|/)\.\.(/|$)} || $rel !~ m{^[A-Za-z0-9_.][A-Za-z0-9_./-]*$}) {
			$out->{'error'} = 'cannot show a diff for that path: ' . $raw;
			return $out;
		}
		push @safe, $rel;
	}
	unless (@safe) {
		$out->{'error'} = 'there is nothing to review';
		return $out;
	}
	my $scratch = File::Temp::tempdir(CLEANUP => 1);
	my $index = "$scratch/index";
	my $list = join(' ', map { &coding_shell_quote($_) } @safe);
	my $git = 'GIT_INDEX_FILE=' . &coding_shell_quote($index);
	my $cd = 'cd ' . &coding_shell_quote($repo);
	my $trim = sub {
		my $t = defined $_[0] ? "$_[0]" : '';
		$t =~ s/\s+/ /g;
		$t =~ s/^\s+|\s+$//g;
		return substr($t, 0, 300);
	};
	my $setup = `$cd && $git git read-tree HEAD 2>&1`;
	if ($? >> 8) { $out->{'error'} = 'could not read the repository state: ' . $trim->($setup); return $out; }
	my $added = `$cd && $git git add -N -- $list 2>&1`;
	if ($? >> 8) { $out->{'error'} = 'could not prepare the change for review: ' . $trim->($added); return $out; }
	my $text = `$cd && $git git diff --no-color -- $list 2>&1`;
	if ($? >> 8) { $out->{'error'} = 'could not read the diff: ' . $trim->($text); return $out; }
	$text = '' unless defined $text;
	$text =~ s/\x00//g;
	my $full = $text;
	if (length $text > $coding_diff_view_bytes) {
		my $cut = substr($text, 0, $coding_diff_view_bytes);
		# Never end on half a character: the text is encoded into the run state,
		# and half a UTF-8 sequence is not something JSON can carry.
		for (1 .. 3) {
			my $probe = $cut;
			last if utf8::decode($probe);
			chop $cut;
		}
		$text = $cut . "\n... the rest of the diff is not shown\n";
		$out->{'truncated'} = 1;
	}
	$out->{'text'} = $text;
	$out->{'hash'} = Digest::SHA::sha256_hex(join("\n", @safe) . "\x00" . $full);
	return $out;
}

# The diff text alone, for a caller that only wants to show it. An error is an
# empty string here; the gate uses coding_diff_bundle so it can tell the two
# apart and refuse.
sub coding_diff_text {
	my ($files) = @_;
	my $bundle = &coding_diff_bundle($files);
	return $bundle->{'text'};
}

# The answer to a paused commit lives in its own setting, not in the run
# snapshot. The worker owns that snapshot and rewrites it every step and on a
# timeout; a route that read-modify-wrote the same blob could lose either
# write, resurrecting a review no worker will ever consume.
sub coding_verdict_set {
	my ($id, $verdict) = @_;
	return 0 unless defined $id && $id =~ /^[0-9]+$/;
	$verdict = defined $verdict ? "$verdict" : '';
	$verdict = '' unless $verdict eq 'approve' || $verdict eq 'reject';
	&subs::setting_setter({ app => '__president', setting => 'coding_verdict_' . $id, value => $verdict });
	return 1;
}

# Read the verdict and clear it in one step, so one answer is consumed once and
# a stale verdict from an earlier pause cannot answer the next one.
sub coding_verdict_take {
	my ($id) = @_;
	return '' unless defined $id && $id =~ /^[0-9]+$/;
	my $v = &subs::setting_grabber({ app => '__president', setting => 'coding_verdict_' . $id });
	$v = defined $v ? "$v" : '';
	return '' unless $v eq 'approve' || $v eq 'reject';
	&subs::setting_setter({ app => '__president', setting => 'coding_verdict_' . $id, value => '' });
	return $v;
}

# How often a paused run looks for the person's verdict, and how long it waits
# before giving up. The deadline may be handed in for a test, as an absolute ms
# timestamp.
our $coding_approve_poll = 2;
our $coding_approve_timeout = 30 * 60;

# Drop the review offer and put the run back to working.
sub coding_await_resume {
	my ($id, $conversation) = @_;
	my $state = &coding_run_state_load($id);
	$state = {} unless ref $state eq 'HASH';
	delete $state->{'pending_commit'};
	$state->{'state'} = 'active';
	$state->{'current'} = { state => 'active', at => &subs::rightNow() };
	$state->{'updated'} = &subs::rightNow();
	&coding_run_state_save($id, $state);
	&coding_run_push($id, $conversation);
	return 1;
}

# The review could not happen (or the tree moved under it): say why and leave the
# offer off the panel. Nothing is committed.
sub coding_await_fail {
	my ($id, $conversation, $why) = @_;
	my $state = &coding_run_state_load($id);
	$state = {} unless ref $state eq 'HASH';
	delete $state->{'pending_commit'};
	$state->{'state'} = 'active';
	$state->{'error'} = defined $why && length $why ? "$why" : 'the change could not be shown for review';
	$state->{'current'} = { state => 'active', at => &subs::rightNow() };
	$state->{'updated'} = &subs::rightNow();
	&coding_run_state_save($id, $state);
	&coding_run_push($id, $conversation);
	return 1;
}

# Pause before a commit and wait for approve/reject/cancel. Returns one word:
# `approved` (run the commit), `rejected`, `cancelled`, `timeout`, `orphaned`,
# `diff_failed` (nothing could be shown) or `changed` (the tree moved after it
# was shown). Only the first of those lets the commit run; every other answer
# stops short, so an unshowable change is never quietly committed.
sub coding_await_commit {
	my ($id, $conversation, $files, $deadline) = @_;
	$files = [] unless ref $files eq 'ARRAY';
	# Nothing was written. There is no change to show, and the commit itself says
	# so; this is not a review that was skipped.
	return 'approved' unless scalar @{$files};
	my $bundle = &coding_diff_bundle($files);
	if (length $bundle->{'error'}) {
		&coding_await_fail($id, $conversation, $bundle->{'error'});
		return 'diff_failed';
	}
	unless (length $bundle->{'text'}) {
		&coding_await_fail($id, $conversation, 'there is no change to show for this commit');
		return 'diff_failed';
	}
	my $hash = $bundle->{'hash'};
	# A verdict left from an earlier pause must not answer this one.
	&coding_verdict_set($id, '');
	my $now = &subs::rightNow();
	$deadline = $now + $coding_approve_timeout * 1000 unless defined $deadline;
	my $state = &coding_run_state_load($id);
	$state = {} unless ref $state eq 'HASH';
	$state->{'state'} = 'awaiting_approval';
	$state->{'pending_commit'} = {
		files     => [ @{$files} ],
		diff      => $bundle->{'text'},
		hash      => $hash,
		truncated => $bundle->{'truncated'} ? 1 : 0,
		at        => $now,
	};
	$state->{'current'} = { state => 'awaiting_approval', at => $now };
	$state->{'updated'} = $now;
	&coding_run_state_save($id, $state);
	&coding_run_push($id, $conversation);
	my $master = $ENV{JAWNOS_MASTER_PID} || 0;
	while (1) {
		select(undef, undef, undef, $coding_approve_poll);
		if ($master && !kill(0, $master)) { return 'orphaned'; }
		my $verdict = &coding_verdict_take($id);
		if ($verdict eq 'approve') {
			# The commit stages the tree as it is now, so the tree as it is now
			# must still be the change the person was shown.
			my $again = &coding_diff_bundle($files);
			if (length $again->{'error'} || $again->{'hash'} ne $hash) {
				&coding_await_fail($id, $conversation, 'the change moved after it was shown, so nothing was committed');
				return 'changed';
			}
			&coding_await_resume($id, $conversation);
			return 'approved';
		}
		if ($verdict eq 'reject') {
			&coding_await_resume($id, $conversation);
			return 'rejected';
		}
		# The cancel flag still lives in the snapshot; read it, never rewrite it.
		my $fresh = &coding_run_state_load($id);
		if (ref $fresh eq 'HASH' && $fresh->{'cancel'}) {
			return 'cancelled';
		}
		if (&subs::rightNow() > $deadline) {
			return 'timeout';
		}
	}
}

# Tell an open panel that a run it may be watching just changed. The worker has
# Websocket.pl loaded; a test or a process without the socket must never have a
# save fail because of it, so the send is wrapped.
sub coding_run_push {
	my ($id, $conversation) = @_;
	eval { &Websocket::send('server', { coding_run => $id + 0, coding_conversation => defined $conversation ? "$conversation" : '' }); };
	return 1;
}

# The Minion task. Runs in perl/Coding.pl; anything it writes for the panel is
# a state snapshot, and its one observable side effect on failure is a failed
# job plus a state row saying why.
sub coding_run_job {
	my ($job, $data) = @_;
	my $id = $job->id;
	$data = {} unless ref $data eq 'HASH';
	my $conversation = $data->{'conversation'} || 'coding';
	$conversation =~ s/[^A-Za-z0-9_-]//g;
	$conversation = 'coding' unless length $conversation;
	my $task = $data->{'task'} // '';
	my $state = {
		run          => $id + 0,
		conversation => $conversation,
		task         => $task,
		state        => 'active',
		steps        => [],
		started      => &subs::rightNow(),
		updated      => &subs::rightNow(),
	};
	&coding_run_state_save($id, $state);
	&coding_run_push($id, $conversation);

	my $final = '';
	my $error = '';
	eval {
		my $child_max = &coding_child_max_setting();
		my $child_note = $child_max > 0
			? "\nYou may use at most $child_max subagents in this run; use them only for self-contained work."
			: "\nDo not use subagents in this run.";
		my $model = &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant' })
			|| &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' });
		die "No Coding model is set (Configure \x{2192} Platform).\n" unless $model;
		my $fallback = &subs::setting_grabber({ app => 'mail', setting => 'coding_assistant_fallback' });
		my $thinking = &subs::ai_role_thinking('coding_assistant');
		my $remembered = &Manager::coding_conversation_load($conversation);
		my @lines;
		foreach my $m ( @{$remembered} ) {
			next unless $m->{'content'};
			push @lines, (($m->{'role'} || 'user') eq 'user' ? 'USER: ' : 'AGENT: ') . $m->{'content'};
		}
		push @lines, 'TASK: ' . $task;
		my %touched;
		my @steps;
		my $master = $ENV{JAWNOS_MASTER_PID} || 0;
		my $tries = 0;
		# The live answer is for the wait, not for the record: each turn starts
		# it empty, the sink below rewrites `current` while the model writes, and
		# the step that follows replaces it.
		my ($live_text, $live_reasoning, $last_live) = ('', '', undef);
		my $live_tail = sub {
			my $text = defined $_[0] ? "$_[0]" : '';
			return $text if length($text) <= $coding_live_bytes;
			return '…' . substr($text, -$coding_live_bytes);
		};
		while ($tries++ < $coding_run_turns) {
			# The master owns this process. If it was SIGKILLed, there is
			# nobody left to report to; stop between steps rather than keep
			# changing the tree for a house that is gone.
			if ($master && !kill(0, $master)) { $error = 'the master that owns this worker is gone'; last; }
			my $fresh = &coding_run_state_load($id);
			if ($fresh->{'cancel'}) { $final = 'Stopped at your request.'; last; }
			my $system = &Manager::coding_system_prompt() . $child_note;
			# What the poller shows while the model is answering.
			$live_text = '';
			$live_reasoning = '';
			$last_live = undef;
			my $sink = sub {
				my ($kind, $piece) = @_;
				return unless defined $piece && length $piece;
				if (($kind // 'text') eq 'reasoning') { $live_reasoning .= $piece }
				else { $live_text .= $piece }
				my $now = &subs::rightNow();
				return if defined $last_live && ($now - $last_live) < 700;
				$last_live = $now;
				$state->{'current'} = {
					state          => 'thinking',
					live_text      => $live_tail->($live_text),
					live_reasoning => $live_tail->($live_reasoning),
					at             => $now,
				};
				$state->{'updated'} = $now;
				&coding_run_state_save($id, $state);
				&coding_run_push($id, $conversation);
			};
			$state->{'current'} = { state => 'thinking', at => &subs::rightNow() };
			$state->{'updated'} = &subs::rightNow();
			&coding_run_state_save($id, $state);
			&coding_run_push($id, $conversation);
			my ($parts, $err) = &subs::ai_chat_parts_with_fallback(
				$model, $fallback,
				[ { role => 'system', content => $system },
				  { role => 'user', content => join("\n", @lines) . "\n\nReply with the single next JSON action." } ],
				$thinking, 'coding_assistant', { on_delta => $sink }
			);
			my $text = &subs::ai_parts_text($parts, 'text');
			my $reasoning = &subs::ai_parts_text($parts, 'reasoning');
			if ($err || !defined $text || !length $text) {
				$error = $err || 'the model returned nothing';
				push @steps, { action => { action => 'error' }, observation => $error };
				last;
			}
			my $action = &coding_parse_action($text);
			unless ($action) { $final = $text; last; }
			# The turn is over; the live line must not linger on the step that
			# replaces it. The step keeps the reasoning the way it always has.
			if (ref $state->{'current'} eq 'HASH') {
				delete $state->{'current'}{'live_text'};
				delete $state->{'current'}{'live_reasoning'};
			}
			# What the poller shows while the tool is running.
			$state->{'current'} = { state => 'acting', action => $action, at => &subs::rightNow() };
			$state->{'updated'} = &subs::rightNow();
			&coding_run_state_save($id, $state);
			&coding_run_push($id, $conversation);
			my $obs;
			my $subagent;
			if (($action->{'action'} // '') eq 'agent') {
				my $children = $state->{'children'} // 0;
				if (&coding_child_limit_ok(0, $children, $child_max)) {
					$state->{'children'} = $children + 1;
					$subagent = &coding_run_subagent({
						action      => $action,
						model       => $model,
						fallback    => $fallback,
						thinking    => $thinking,
						parent_task => $task,
						depth       => 0,
						count       => $children,
						max         => $child_max,
					});
				}
				else {
					my $scope = lc($action->{'scope'} // 'read');
					$scope = 'read' unless $scope eq 'write';
					$subagent = {
						task  => ($action->{'task'} // ''),
						scope => $scope,
						paths => (ref $action->{'paths'} eq 'ARRAY' ? [ @{$action->{'paths'}} ] : []),
						steps => [],
						error => "this run has already used its $child_max subagents",
					};
				}
				if (($subagent->{'error'} // '') ne '') {
					$obs = 'subagent failed: ' . $subagent->{'error'};
				}
				else {
					my $said = $subagent->{'final'} // '';
					$said = 'done' unless length $said;
					$obs = 'subagent: ' . $said;
				}
				$obs = substr($obs, 0, 2000) . '…' if length($obs) > 2000;
			}
			else {
				# A commit that follows a review uses the same touched set: the
				# diff a person approved is the one the commit stages.
				if (($action->{'action'} // '') eq 'commit' && &coding_review_setting()) {
					my @files = &coding_review_files(\%touched);
					my $verdict = &coding_await_commit($id, $conversation, \@files);
					if ($verdict eq 'rejected') {
						$final = 'Stopped: the commit was rejected. The changed files are still in the tree.';
						last;
					}
					if ($verdict eq 'cancelled') {
						$final = 'Stopped at your request.';
						last;
					}
					if ($verdict eq 'timeout' || $verdict eq 'orphaned') {
						$error = $verdict eq 'timeout'
							? 'the commit waited more than 30 minutes for review'
							: 'the master that owns this worker is gone';
						last;
					}
					# Nothing was shown, or the tree moved under it: fail closed.
					if ($verdict eq 'diff_failed' || $verdict eq 'changed') {
						$error = $verdict eq 'changed'
							? 'the change moved after it was shown, so nothing was committed'
							: 'the change could not be shown for review, so nothing was committed';
						last;
					}
				}
				$obs = &Manager::coding_execute(undef, $action, \%touched);
			}
			my $step = { action => $action, observation => &coding_step_view($obs) };
			$step->{'reasoning'} = &coding_reasoning_view($reasoning) if length $reasoning;
			$step->{'subagent'} = $subagent if ref $subagent eq 'HASH';
			push @steps, $step;
			push @lines, 'ACTION: ' . encode_json($action);
			push @lines, 'OBSERVATION: ' . (defined $obs ? $obs : '');
			$state->{'steps'} = \@steps;
			delete $state->{'current'};
			$state->{'updated'} = &subs::rightNow();
			&coding_run_state_save($id, $state);
			&coding_run_push($id, $conversation);
			if (($action->{'action'} || '') eq 'done' || ($action->{'action'} || '') eq 'say') {
				$final = $action->{'text'} // '';
				last;
			}
		}
		push @{$remembered}, { role => 'user', content => $task };
		# The transcript is the next turn's memory, so it must not say "done"
		# for a run that failed. Put the reason in the record instead.
		my $said = length $final ? $final
			: (length $error ? 'The run failed: ' . $error : 'done');
		push @{$remembered}, { role => 'assistant', content => $said };
		&Manager::coding_conversation_save($conversation, $remembered);
		my $noted = &Manager::agent_registry_note('coding', $conversation, $remembered);
		$state->{'title'} = $noted->{'title'} || '' if ref $noted eq 'HASH';
		1;
	};
	if ($@) {
		$error = $@;
		$error =~ s/\s+$//;
	}
	# A finished or failed run has nothing in flight; the panel must not keep
	# showing the last step as still acting, nor a commit still waiting.
	delete $state->{'current'};
	delete $state->{'pending_commit'};
	$state->{'final'} = $final;
	$state->{'error'} = $error if length $error;
	$state->{'version'} = &subs::jawn_version();
	$state->{'state'} = length $error ? 'failed' : 'finished';
	$state->{'finished'} = &subs::rightNow();
	$state->{'updated'} = &subs::rightNow();
	&coding_run_state_save($id, $state);
	&coding_run_push($id, $conversation);
	if (length $error) { $job->fail($error); return }
	$job->finish({ conversation => $conversation, version => $state->{'version'} });
	return;
}

1;
