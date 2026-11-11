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
use POSIX ();
use Cwd ();
use JawnOS::Platform::Process ();

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
	# a recycled pid is not a worker; the command line says which it is. An
	# unreadable command line (no process table, another user) is not evidence
	# against it, so the name test is skipped rather than failed.
	my $cmd = JawnOS::Platform::Process::command_line($pid);
	return 0 if length $cmd && $cmd !~ /Coding\.pl/;
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
		children     => ($state->{'children'} // 0) + 0,
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
	# A path can be spelled scripts/./restart.pl or ./scripts//x.pl: judge the
	# basename of every word, so no spelling reaches a shipping script.
	for my $word (split /\s+/, $c) {
		(my $base = $word) =~ s{.*/}{};
		return 0 if $base =~ /^(?:restart|manager_killer|app_build|app_publish|git_bootstrap_update|git_peer_update|version_bump|land_enqueue|land_promote|agent_land)\.pl$/;
	}
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

# The real path of $abs, resolving symlinks in the part that already exists. A
# path that does not exist yet is resolved through its deepest existing ancestor,
# so a guard can answer for a file the agent is about to create. Empty when the
# path cannot be resolved at all.
sub coding_real_path {
	my $abs = defined $_[0] ? "$_[0]" : '';
	return '' unless length $abs;
	my @rest;
	my $p = $abs;
	$p =~ s{/+$}{} unless $p eq '/';
	while (1) {
		my $real = Cwd::abs_path($p);
		if (defined $real && length $real) {
			return @rest ? "$real/" . join('/', reverse @rest) : $real;
		}
		last if $p eq '/' || $p eq '.';
		my ($base) = $p =~ m{([^/]+)$};
		last unless defined $base && length $base;
		unshift @rest, $base;
		$p =~ s{/[^/]+$}{};
		$p = '/' unless length $p;
	}
	return '';
}

# The same normalisation the repo guard uses (drop a leading ./ or /, and a
# trailing /), kept in one place so a path is compared one way everywhere. A
# scope written as ./ or / means the repo root, not nothing.
sub coding_child_norm_path {
	my $in = defined $_[0] ? "$_[0]" : '';
	my $p = $in;
	$p =~ s{^\./+}{};
	$p =~ s{^/+}{};
	$p =~ s{/+$}{};
	return '.' if !length $p && length $in;
	return $p;
}

# Is $path a write the child may make? Both sides are normalised the way
# Manager::coding_rel does it (drop a leading ./ or /), then the path must sit
# under one of the allowed paths and must not be one of the things no subagent
# may touch, even when its scope nominally covers them.
sub coding_child_write_ok {
	my ($path, $paths) = @_;
	return 0 unless ref $paths eq 'ARRAY' && scalar @{$paths};
	my $rel = &coding_child_norm_path($path);
	return 0 unless length $rel;
	return 0 if $rel =~ m{(^|/)\.\.(/|$)};
	return 0 if $rel =~ m{[\x00-\x1f"`\\]};
	my @deny = qw(.git .secrets .president voices VERSION database releases desktop/mkosi config.json);
	foreach my $d (@deny) {
		return 0 if $rel eq $d || index($rel, "$d/") == 0;
	}
	# the one file in the scratch folder that must never be overwritten
	return 0 if $rel eq '.shots/ticket.txt';
	# The name is not the file: a symlink inside the repo can point anywhere.
	# Judge the file it really names, and refuse it when that is out of the repo.
	my $repo = &subs::coding_repo();
	my $repo_real = (defined $repo && length $repo) ? &coding_real_path($repo) : '';
	my $full_real = $repo_real ? &coding_real_path("$repo/$rel") : '';
	if ($repo_real && length $full_real) {
		return 0 unless $full_real eq $repo_real || index($full_real, "$repo_real/") == 0;
	}
	foreach my $allowed (@{$paths}) {
		my $dir = &coding_child_norm_path($allowed);
		next unless length $dir;
		next if $dir =~ m{(^|/)\.\.(/|$)};
		return 1 if $dir eq '.';
		next unless $rel eq $dir || index($rel, "$dir/") == 0;
		# the string says yes; the folder it really names must say yes too
		next unless $repo_real && length $full_real;
		my $dir_real = &coding_real_path("$repo/$dir");
		next unless length $dir_real;
		return 1 if $full_real eq $dir_real || index($full_real, "$dir_real/") == 0;
		return 0;
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
	my %touched;
	eval {
		my $system = &Manager::coding_system_prompt()
			. "\n\nYou are a subagent. Do only the task below. Do not bump, commit, push or restart, and do not ask for another agent. Read what you need. When done, reply with done and a short summary.";
		my $prompt = 'PARENT TASK: ' . ($opt->{'parent_task'} // '') . "\n"
			. 'SUBAGENT TASK: ' . $task . "\n"
			. 'SCOPE: ' . $scope . "\n"
			. 'ALLOWED PATHS: ' . (@paths ? join(', ', map { "$_" } @paths) : '(any in the repo; read only)');
		my @lines = ($prompt);
		my $turns = 0;
		my $parent = $opt->{'parent_pid'} || 0;
		while ($turns++ < $coding_child_turns) {
			# A child outlives nothing: if the process that started it is gone,
			# it must not keep writing to the tree for a run nobody is watching.
			die "the parent process is gone\n" if $parent && !kill(0, $parent);
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
			if (($verb eq 'write' || $verb eq 'patch') && $scope eq 'write') {
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
					. ($scope eq 'write' ? ', and write or patch inside its allowed paths' : '');
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
	# What the child wrote is the parent's business too: the commit that follows
	# stages this set, and a write made by a subagent used to vanish from it.
	$record->{'touched'} = [ sort keys %touched ];
	unless (defined $record->{'final'} && length $record->{'final'}) {
		my $last = @{$record->{'steps'}} ? $record->{'steps'}[-1]{'observation'} : '';
		$record->{'final'} = length $last ? $last : 'stopped after ' . scalar(@{$record->{'steps'}}) . ' steps';
	}
	return $record;
}

# The tasks one `agent` action asks for, in order. A single `task` is the same
# thing as a `tasks` list of one, so the model may use whichever reads better.
sub coding_action_tasks {
	my ($action) = @_;
	$action = {} unless ref $action eq 'HASH';
	my @tasks;
	if (ref $action->{'tasks'} eq 'ARRAY') {
		foreach my $t ( @{$action->{'tasks'}} ) {
			next unless ref $t eq 'HASH';
			push @tasks, $t;
		}
		return @tasks if @tasks;
	}
	if (defined $action->{'task'} && length "$action->{'task'}") {
		push @tasks, {
			task  => $action->{'task'},
			scope => $action->{'scope'},
			paths => $action->{'paths'},
		};
	}
	return @tasks;
}

# The record a task that never ran still gets, so the parent has one answer per
# task and the person can see which one was refused and why.
sub coding_child_refused {
	my ($action, $why) = @_;
	$action = {} unless ref $action eq 'HASH';
	my $scope = lc($action->{'scope'} // 'read');
	$scope = 'read' unless $scope eq 'write';
	return {
		task    => ($action->{'task'} // ''),
		scope   => $scope,
		paths   => (ref $action->{'paths'} eq 'ARRAY' ? [ @{$action->{'paths'}} ] : []),
		steps   => [],
		touched => [],
		error   => (defined $why && length $why ? "$why" : 'the subagent could not run'),
	};
}

# Two write-scope subagents running at the same time must not share a path: the
# second write would replace the first and neither would say so. Read-only
# children may overlap freely. Returns the reason a batch is refused, or ''.
sub coding_child_batch_clash {
	my ($tasks) = @_;
	$tasks = [] unless ref $tasks eq 'ARRAY';
	return '' if scalar @{$tasks} < 2;
	my @writes;
	foreach my $i ( 0 .. $#{$tasks} ) {
		my $t = $tasks->[$i];
		next unless ref $t eq 'HASH' && lc($t->{'scope'} // 'read') eq 'write';
		next unless ref $t->{'paths'} eq 'ARRAY';
		push @writes, [ $i + 1, $t ];
	}
	my $repo = &subs::coding_repo();
	my $repo_ok = defined $repo && length $repo ? 1 : 0;
	for my $a ( 0 .. $#writes ) {
		for my $b ( $a + 1 .. $#writes ) {
			my ($na, $ta) = @{ $writes[$a] };
			my ($nb, $tb) = @{ $writes[$b] };
			foreach my $x ( @{ $ta->{'paths'} } ) {
				foreach my $y ( @{ $tb->{'paths'} } ) {
					my $px = &coding_child_norm_path($x);
					my $py = &coding_child_norm_path($y);
					next unless length $px && length $py;
					# judge the folder each scope really names: two names for one
					# folder (a symlink, a different spelling) clash just the same
					if ($repo_ok) {
						my $rx = &coding_real_path("$repo/$px");
						my $ry = &coding_real_path("$repo/$py");
						$px = $rx if length $rx;
						$py = $ry if length $ry;
					}
					my $clash = ($px eq '.' || $py eq '.'
						|| $px eq $py
						|| index($px, "$py/") == 0
						|| index($py, "$px/") == 0) ? 1 : 0;
					next unless $clash;
					return "tasks $na and $nb may both write under $px and $py; send them one at a time";
				}
			}
		}
	}
	return '';
}

# One child's record, off the file it wrote. A missing or unreadable file is a
# refusal record, never a hole in the list the parent is handed.
sub coding_child_record_read {
	my ($scratch, $slot, $task, $stopped) = @_;
	my $json = '';
	if (open(my $fh, '<', "$scratch/$slot.json")) {
		local $/;
		$json = <$fh>;
		close $fh;
	}
	my $record = length $json ? eval { decode_json($json) } : undef;
	return $record if ref $record eq 'HASH';
	return &coding_child_refused($task, length $stopped
		? "the run was $stopped before this subagent finished"
		: 'the subagent ended without a record');
}

# Run a batch of subagent tasks at the same time, one forked child each, and
# return { records => [...], stopped => '' } - the records in the order the tasks
# were asked for, and why the batch stopped short when it did. A child re-dials
# its own database connection (database_grabber detaches an inherited handle on
# a pid change), writes its record to a file of its own, and leaves with
# POSIX::_exit so it never runs the parent's destructors. One task is the plain
# path: no fork, no files.
sub coding_run_subagents {
	my ($tasks, $opt) = @_;
	$tasks = [] unless ref $tasks eq 'ARRAY';
	$opt = {} unless ref $opt eq 'HASH';
	my @records;
	my $out = { records => \@records, stopped => '' };
	return $out unless @{$tasks};
	if (scalar @{$tasks} == 1) {
		$records[0] = &coding_run_subagent({
			%{$opt},
			action => $tasks->[0],
			count  => ($opt->{'count'} // 0),
		});
		return $out;
	}
	my $scratch = File::Temp::tempdir(CLEANUP => 1);
	my @pids;
	my $fork_failed = 0;
	foreach my $slot ( 0 .. $#{$tasks} ) {
		my $action = $tasks->[$slot];
		my $pid = fork();
		unless (defined $pid) { $fork_failed = 1; last; }
		if (!$pid) {
			# Its own process group, so a stop reaches the commands the child
			# itself runs, not just the perl process.
			eval { setpgrp(0, 0) };
			my $record;
			my $ok = eval {
				$record = &coding_run_subagent({
					%{$opt},
					action     => $action,
					count      => ($opt->{'count'} // 0) + $slot,
					parent_pid => $$,
				});
				1;
			};
			if (!$ok || ref $record ne 'HASH') {
				my $why = $@ || 'the subagent process ended without a record';
				$why =~ s/\s+$//;
				$record = &coding_child_refused($action, $why);
			}
			my $json = eval { encode_json($record) };
			if (!defined $json) {
				# Keep the reason, even when the record itself will not encode.
				$json = eval { encode_json(&coding_child_refused($action, 'the subagent record could not be written')) };
			}
			if (defined $json && open(my $fh, '>', "$scratch/$slot.json")) {
				print $fh $json;
				close $fh;
			}
			POSIX::_exit(0);
		}
		$pids[$slot] = $pid;
	}
	if ($fork_failed) {
		# A batch that cannot start whole starts not at all, and charges nothing.
		my @started = grep { defined } @pids;
		foreach my $pid ( @started ) { kill 'TERM', -$pid; kill 'TERM', $pid; }
		foreach my $pid ( @started ) { waitpid($pid, 0); }
		my $why = 'could not start every subagent in the batch';
		$out->{'records'} = [ map { &coding_child_refused($_, $why) } @{$tasks} ];
		return $out;
	}
	my %alive = map { defined $_ ? ($_ => 1) : () } @pids;
	my %slot_of = map { defined $pids[$_] ? ($pids[$_] => $_) : () } 0 .. $#pids;
	my $stopped = '';
	my $master = $ENV{JAWNOS_MASTER_PID} || 0;
	while (%alive) {
		foreach my $pid ( keys %alive ) {
			my $done = waitpid($pid, POSIX::WNOHANG);
			# -1 with ECHILD means it was already reaped; -1 on EINTR does not.
			next unless $done == $pid || ($done == -1 && $!{ECHILD});
			delete $alive{$pid};
			my $slot = $slot_of{$pid};
			next unless defined $slot && !defined $records[$slot];
			# A finished child has written its record; read it now, so the panel
			# can count it while the others are still working.
			$records[$slot] = &coding_child_record_read($scratch, $slot, $tasks->[$slot], '');
			if (ref $opt->{'on_child'} eq 'CODE') {
				eval { $opt->{'on_child'}->($records[$slot]) };
			}
		}
		last unless %alive;
		# A run stopped at the person's request, or a house whose master is
		# gone, must not keep several model calls going.
		my $fresh = $opt->{'run'} ? &coding_run_state_load($opt->{'run'}) : {};
		if (ref $fresh eq 'HASH' && $fresh->{'cancel'}) { $stopped = 'cancelled'; last; }
		if ($master && !kill(0, $master)) { $stopped = 'orphaned'; last; }
		select(undef, undef, undef, 0.25);
	}
	if (length $stopped) {
		foreach my $pid ( keys %alive ) { kill 'TERM', -$pid; kill 'TERM', $pid; }
		# A child that will not take the message must not hold the one worker
		# slot forever.
		my %left = %alive;
		my $give_up = time + 5;
		while (%left && time <= $give_up) {
			foreach my $pid ( keys %left ) {
				my $done = waitpid($pid, POSIX::WNOHANG);
				delete $left{$pid} if $done == $pid || ($done == -1 && $!{ECHILD});
			}
			last unless %left;
			select(undef, undef, undef, 0.1);
		}
		foreach my $pid ( keys %left ) { kill 'KILL', $pid; waitpid($pid, 0); }
	}
	foreach my $slot ( 0 .. $#{$tasks} ) {
		next if defined $records[$slot];
		$records[$slot] = &coding_child_record_read($scratch, $slot, $tasks->[$slot], $stopped);
	}
	$out->{'stopped'} = $stopped;
	return $out;
}

# One line the parent's transcript can carry for a child: its last word, or why
# it failed.
sub coding_child_line {
	my ($record) = @_;
	$record = {} unless ref $record eq 'HASH';
	my $line = (($record->{'error'} // '') ne '')
		? 'subagent failed: ' . $record->{'error'}
		: 'subagent: ' . (length($record->{'final'} // '') ? $record->{'final'} : 'done');
	$line = substr($line, 0, 2000) . '…' if length($line) > 2000;
	return $line;
}

# Apply one exact patch to $text. The block is a literal, not a pattern: exact
# match only, unique unless "all" is set, so a small change stays small and a
# miss is reported rather than guessed at. Returns ($new_text, $line, $count) or
# (undef, 0, 0, $why).
sub coding_patch_text {
	my ($text, $old, $new, $all) = @_;
	$text = '' unless defined $text;
	$old  = '' unless defined $old;
	$new  = '' unless defined $new;
	return (undef, 0, 0, 'patch needs a non-empty "old" block') unless length $old;
	return (undef, 0, 0, 'patch "old" and "new" are identical') if $old eq $new;
	return (undef, 0, 0, 'refused: a patch block is capped at 200000 bytes')
		if length($old) > 200_000 || length($new) > 200_000;

	my $quoted = quotemeta $old;
	my $count  = () = $text =~ /$quoted/g;
	return (undef, 0, 0, 'no match: the "old" text does not appear in that file') unless $count;
	return (undef, 0, 0, "ambiguous: the \"old\" text appears $count times; include more context or set \"all\"")
		if $count > 1 && !$all;

	my $at  = 1 + ( substr($text, 0, index($text, $old)) =~ tr/\n// );
	my $out = $text;
	if ($all) { $out =~ s/$quoted/$new/g }
	else      { $out =~ s/$quoted/$new/ }
	return ($out, $at, $count);
}

# One range of a file, so an agent that needs a symbol does not pull a
# 1,000-line file into its context. offset is 1-based; limit is capped so a bad
# number cannot silently become a whole-file read.
sub coding_read_range {
	my ($text, $offset, $limit) = @_;
	$text = '' unless defined $text;
	my @lines = split /\n/, $text;
	return '' unless @lines;
	my $from  = (defined $offset && $offset =~ /^\d+$/ && $offset > 0) ? $offset + 0 : 1;
	my $count = (defined $limit  && $limit  =~ /^\d+$/ && $limit  > 0) ? $limit  + 0 : 200;
	$count = 200 if $count > 200;
	return 'no such range' if $from > @lines;
	my $to = $from + $count - 1;
	$to = scalar @lines if $to > @lines;
	return join("\n", @lines[ $from - 1 .. $to - 1 ]);
}

# Write $content to $abs, which coding_path has already resolved and checked. A
# destination that is a symlink is refused rather than followed, and the file is
# written whole (a temp file in the same folder, then a rename) so neither the
# verifier nor a commit can read a half-written file. Returns '' on success, or
# the sentence to hand the agent.
sub coding_write_file {
	my ($abs, $content) = @_;
	return 'could not write that file' unless defined $abs && length $abs;
	$content = '' unless defined $content;
	# A symlink planted where the file goes would take the write with it. The
	# resolved path has no symlink in it, so one can only appear after the check.
	return 'refused: that path is a symlink, which the agent may not write through' if -l $abs;
	require File::Basename;
	my $dir = File::Basename::dirname($abs);
	unless (-d $dir) {
		require File::Path;
		eval { File::Path::make_path($dir) };
		return 'could not make that folder' unless -d $dir;
	}
	my $bytes = $content;
	# The same bytes the old whole-file write produced, without a wide-character
	# warning on the way out.
	utf8::encode($bytes) if utf8::is_utf8($bytes);
	# A rename would otherwise hand an executable script the plain file mode.
	my $mode = -f $abs ? ((stat($abs))[2] & 07777) : undef;
	require Fcntl;
	my $tmp = $abs . '.jawn-tmp-' . $$;
	my $flags = Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL();
	$flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
	my $fh;
	unless (sysopen($fh, $tmp, $flags, 0666)) {
		return 'could not write that file';
	}
	binmode($fh);
	# sysopen's mode is filtered by the umask; an existing file keeps its own.
	chmod($mode, $tmp) if defined $mode;
	my $ok = print $fh $bytes;
	$ok = 0 unless close($fh);
	unless ($ok) {
		unlink $tmp;
		return 'could not write that file';
	}
	# rename replaces the destination entry; it does not follow a symlink there.
	unless (rename($tmp, $abs)) {
		unlink $tmp;
		return 'could not write that file';
	}
	return '';
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
		my $thinking = &subs::ai_role_thinking_effective('coding_assistant');
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
			# A Stop pressed while the model was thinking must not be erased by
			# the save at the foot of this turn.
			my $before = &coding_run_state_load($id);
			if (ref $before eq 'HASH' && $before->{'cancel'}) { $final = 'Stopped at your request.'; last; }
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
			my @children;
			my $stop_after = '';
			if (($action->{'action'} // '') eq 'agent') {
				my @tasks = &coding_action_tasks($action);
				# A reply with two hundred tasks must not fill the run state: keep
				# only what the run could ever start, and say what was not tried.
				my $extra = 0;
				if (scalar @tasks > $child_max + 1) {
					$extra = scalar(@tasks) - ($child_max + 1);
					@tasks = @tasks[ 0 .. $child_max ];
				}
				my $children = $state->{'children'} // 0;
				# Only the tasks the run has room for may start; the rest are told
				# why, rather than dropped without a word.
				my (@run, @over);
				foreach my $t ( @tasks ) {
					if (&coding_child_limit_ok(0, $children + scalar(@run), $child_max)) { push @run, $t }
					else { push @over, $t }
				}
				# A batch that cannot run whole runs not at all: half the work done,
				# with no way to tell which half, is worse than a plain refusal.
				my $clash = &coding_child_batch_clash(\@run);
				if (length $clash) {
					push @children, &coding_child_refused($_, $clash) foreach @run;
					@run = ();
				}
				if (@run) {
					$state->{'children'} = $children + scalar(@run);
					my $batch_total = scalar @run;
					my @progress;
					# A batch is work in progress, not one silent action: the panel is
					# told how many are running, how many have finished, and what each
					# finished one said.
					$state->{'current'} = { state => 'subagents', total => $batch_total, done => 0, children => [], at => &subs::rightNow() }
						if $batch_total > 1;
					&coding_run_state_save($id, $state);
					&coding_run_push($id, $conversation);
					my $batch = &coding_run_subagents(\@run, {
						model       => $model,
						fallback    => $fallback,
						thinking    => $thinking,
						parent_task => $task,
						depth       => 0,
						count       => $children,
						max         => $child_max,
						run         => $id,
						on_child    => sub {
							my $r = shift;
							my $failed = (($r->{'error'} // '') ne '') ? 1 : 0;
							my $said = $failed ? 'failed: ' . $r->{'error'}
								: (length($r->{'final'} // '') ? $r->{'final'} : 'done');
							push @progress, {
								task => substr(($r->{'task'} // ''), 0, 120),
								said => substr($said, 0, 160),
								ok   => $failed ? 0 : 1,
							};
							$state->{'current'} = {
								state    => 'subagents',
								total    => $batch_total,
								done     => scalar(@progress),
								children => [ @progress ],
								at       => &subs::rightNow(),
							};
							$state->{'updated'} = &subs::rightNow();
							&coding_run_state_save($id, $state);
							&coding_run_push($id, $conversation);
						},
					});
					push @children, @{ $batch->{'records'} };
					$stop_after = $batch->{'stopped'} if length $batch->{'stopped'};
				}
				push @children, &coding_child_refused($_, "this run has already used its $child_max subagents") foreach @over;
				push @children, &coding_child_refused({ task => '' }, "$extra more tasks were not attempted") if $extra;
				$obs = join("\n", map { &coding_child_line($_) } @children);
				$obs = 'no task to run' unless length $obs;
				# A subagent's writes are the parent's to commit.
				foreach my $r ( @children ) {
					foreach my $f ( ref $r->{'touched'} eq 'ARRAY' ? @{ $r->{'touched'} } : () ) { $touched{$f} = 1; }
				}
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
			# One step per child, so a batch reads as the parallel work it was.
			if (scalar @children > 1) {
				my $first = 1;
				foreach my $r ( @children ) {
					my $s = { action => $action, observation => &coding_step_view(&coding_child_line($r)), subagent => $r };
					$s->{'reasoning'} = &coding_reasoning_view($reasoning) if $first && length $reasoning;
					$first = 0;
					push @steps, $s;
				}
			}
			else {
				my $step = { action => $action, observation => &coding_step_view($obs) };
				$step->{'reasoning'} = &coding_reasoning_view($reasoning) if length $reasoning;
				$step->{'subagent'} = $children[0] if ref $children[0] eq 'HASH';
				push @steps, $step;
			}
			push @lines, 'ACTION: ' . encode_json($action);
			push @lines, 'OBSERVATION: ' . (defined $obs ? $obs : '');
			$state->{'steps'} = \@steps;
			delete $state->{'current'};
			# A Stop pressed during this turn is a fact about the run, not a stale
			# field of this copy: carry it forward, or the save below erases it.
			my $live = &coding_run_state_load($id);
			$state->{'cancel'} = 1 if ref $live eq 'HASH' && $live->{'cancel'};
			$state->{'updated'} = &subs::rightNow();
			&coding_run_state_save($id, $state);
			&coding_run_push($id, $conversation);
			if ($stop_after eq 'cancelled') { $final = 'Stopped at your request.'; last; }
			if ($stop_after eq 'orphaned') { $error = 'the master that owns this worker is gone'; last; }
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
