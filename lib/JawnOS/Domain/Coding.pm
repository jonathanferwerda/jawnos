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

	my $final = '';
	my $error = '';
	eval {
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
		while ($tries++ < $coding_run_turns) {
			# The master owns this process. If it was SIGKILLed, there is
			# nobody left to report to; stop between steps rather than keep
			# changing the tree for a house that is gone.
			if ($master && !kill(0, $master)) { $error = 'the master that owns this worker is gone'; last; }
			my $fresh = &coding_run_state_load($id);
			if ($fresh->{'cancel'}) { $final = 'Stopped at your request.'; last; }
			my $system = &Manager::coding_system_prompt();
			# What the poller shows while the model is answering.
			$state->{'current'} = { state => 'thinking', at => &subs::rightNow() };
			$state->{'updated'} = &subs::rightNow();
			&coding_run_state_save($id, $state);
			my ($parts, $err) = &subs::ai_chat_parts_with_fallback(
				$model, $fallback,
				[ { role => 'system', content => $system },
				  { role => 'user', content => join("\n", @lines) . "\n\nReply with the single next JSON action." } ],
				$thinking, 'coding_assistant'
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
			# What the poller shows while the tool is running.
			$state->{'current'} = { state => 'acting', action => $action, at => &subs::rightNow() };
			$state->{'updated'} = &subs::rightNow();
			&coding_run_state_save($id, $state);
			my $obs = &Manager::coding_execute(undef, $action, \%touched);
			my $step = { action => $action, observation => &coding_step_view($obs) };
			$step->{'reasoning'} = &coding_reasoning_view($reasoning) if length $reasoning;
			push @steps, $step;
			push @lines, 'ACTION: ' . encode_json($action);
			push @lines, 'OBSERVATION: ' . (defined $obs ? $obs : '');
			$state->{'steps'} = \@steps;
			delete $state->{'current'};
			$state->{'updated'} = &subs::rightNow();
			&coding_run_state_save($id, $state);
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
	# showing the last step as still acting.
	delete $state->{'current'};
	$state->{'final'} = $final;
	$state->{'error'} = $error if length $error;
	$state->{'version'} = &subs::jawn_version();
	$state->{'state'} = length $error ? 'failed' : 'finished';
	$state->{'finished'} = &subs::rightNow();
	$state->{'updated'} = &subs::rightNow();
	&coding_run_state_save($id, $state);
	if (length $error) { $job->fail($error); return }
	$job->finish({ conversation => $conversation, version => $state->{'version'} });
	return;
}

1;
