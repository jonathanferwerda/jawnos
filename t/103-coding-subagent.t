# tests-for: lib/JawnOS/Domain/Coding.pm perl/gb/03_engines_and_tools.pl perl/help.pl
# covers:    the Coding agent's live answer (the on_delta sink) and the `agent`
#           action: a bounded child loop with read/write scope, its own small
#           toolset, and a record the parent step carries.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Slurp qw(read_file);
use Test::More;

my $root = "$FindBin::Bin/..";

require JawnOS::Domain::Coding;

sub source {
	my ($rel) = @_;
	return read_file("$root/$rel");
}

# --- the pure child rules ----------------------------------------------------
ok(&subs::coding_child_write_ok('lib/JawnOS/Domain/Coding.pm', ['lib/JawnOS/Domain']),
	'a write under an allowed directory is allowed');
ok(&subs::coding_child_write_ok('lib/JawnOS/Domain/Coding.pm', ['lib/JawnOS/Domain/Coding.pm']),
	'an exact allowed file is allowed');
ok(!&subs::coding_child_write_ok('lib/JawnOS/Manager/Part29.pm', ['lib/JawnOS/Domain']),
	'a sibling path is refused');
ok(!&subs::coding_child_write_ok('.git/config', ['.']),
	'the git store is refused even under a root scope');
ok(!&subs::coding_child_write_ok('VERSION', ['.']),
	'VERSION is refused even under a root scope');
ok(!&subs::coding_child_write_ok('database/jawnos.db', ['database']),
	'the database is refused even when its directory is allowed');
ok(!&subs::coding_child_write_ok('releases/jawn.apk', ['releases']),
	'staged releases are refused');
ok(!&subs::coding_child_write_ok('desktop/mkosi/x.conf', ['desktop']),
	'the image build is refused');

ok(&subs::coding_child_allowed('list'), 'a child may list');
ok(&subs::coding_child_allowed('read'), 'a child may read');
ok(&subs::coding_child_allowed('run'), 'a child may run a checked command');
ok(!&subs::coding_child_allowed('write'), 'write needs the scope check, not the bare vocabulary');
ok(!&subs::coding_child_allowed('bump'), 'a child may not bump');
ok(!&subs::coding_child_allowed('commit'), 'a child may not commit');
ok(!&subs::coding_child_allowed('push'), 'a child may not push');
ok(!&subs::coding_child_allowed('restart'), 'a child may not restart');
ok(!&subs::coding_child_allowed('agent'), 'a child may not start another child');

ok(&subs::coding_child_run_ok('perl -c perl/Manager.pl'), 'a compile check is allowed');
ok(&subs::coding_child_run_ok('perl scripts/tests_for.pl --files lib/x.pm'), 'a test helper is allowed');
ok(!&subs::coding_child_run_ok('perl scripts/restart.pl --reason x'), 'a restart is refused');
ok(!&subs::coding_child_run_ok('perl scripts/manager_killer.pl'), 'the killer is refused');
ok(!&subs::coding_child_run_ok('git commit -m x'), 'a commit is refused');
ok(!&subs::coding_child_run_ok('git push'), 'a push is refused');

is(&subs::coding_unwrap_final(q({"action":"done","text":"the answer"})), 'the answer',
	'a final that is an action object is unwrapped');
is(&subs::coding_unwrap_final(q({"action":"done","text":"{\"action\":\"done\",\"text\":\"nested\"}"})), 'nested',
	'a nested action is unwrapped twice');
is(&subs::coding_unwrap_final('  plain prose  '), 'plain prose', 'prose is trimmed, not changed');
is(&subs::coding_unwrap_final(undef), '', 'an empty final stays empty');

ok(&subs::coding_child_limit_ok(0, 9, 10), 'the parent may start a child before the cap');
ok(!&subs::coding_child_limit_ok(0, 10, 10), 'a child at the cap is refused');
ok(!&subs::coding_child_limit_ok(0, 2, 2), 'a child at a lower cap is refused');
ok(!&subs::coding_child_limit_ok(0, 0, 0), 'a max of 0 refuses every child');
ok(!&subs::coding_child_limit_ok(1, 0, 10), 'a child at depth 1 may not start one');

# --- the configured subagent cap --------------------------------------------
{
	my $value;
	no warnings 'redefine';
	local *subs::setting_grabber = sub { $value };
	$value = undef;
	is(&subs::coding_child_max_setting(), 10, 'a missing setting falls back to ten');
	$value = '10';
	is(&subs::coding_child_max_setting(), 10, 'a setting of ten is ten');
	$value = '0';
	is(&subs::coding_child_max_setting(), 0, 'a setting of zero turns subagents off');
	$value = '99';
	is(&subs::coding_child_max_setting(), 10, 'anything above ten is capped at ten');
	$value = 'x';
	is(&subs::coding_child_max_setting(), 10, 'a non-numeric setting falls back to ten');
}

# --- the run loop, with the model and the tools stubbed ----------------------
{
	package FakeJob;
	sub new { bless { id => 999, done => 0, error => '', result => undef }, shift }
	sub id { $_[0]->{'id'} }
	sub finish { $_[0]->{'done'} = 1; $_[0]->{'result'} = $_[1]; 1 }
	sub fail { $_[0]->{'done'} = 1; $_[0]->{'error'} = $_[1]; 1 }
}

sub run_fake_job {
	my ($responder, $execute, $subagent_max) = @_;
	$subagent_max = '2' unless defined $subagent_max;
	my %state;
	my @snapshots;
	my @executed;
	my $calls = 0;
	my $saw_sink = 0;
	my $clock = 1000;
	my $job = FakeJob->new;
	{
		no warnings 'redefine';
		local *subs::rightNow = sub { $clock += 1000 };
		local *subs::setting_grabber = sub {
			my ($arg) = @_;
			return $subagent_max if ref $arg eq 'HASH' && ($arg->{'setting'} // '') eq 'coding_subagents';
			return 'fake-model';
		};
		local *subs::ai_role_thinking = sub { '' };
		local *subs::ai_chat_parts_with_fallback = sub {
			my ($model, $fallback, $messages, $thinking, $role, $opt) = @_;
			$calls++;
			if (ref $opt eq 'HASH' && ref $opt->{'on_delta'} eq 'CODE') {
				$saw_sink = 1;
				$opt->{'on_delta'}->('reasoning', 'considering ');
				$opt->{'on_delta'}->('text', 'the answer');
			}
			my ($text, $err) = $responder->($calls);
			return (undef, $err) if $err;
			return ([ { type => 'reasoning', text => "why $calls" },
			          { type => 'text', text => $text } ], undef);
		};
		local *subs::ai_parts_text = sub {
			my ($parts, $type) = @_;
			$type = 'text' unless defined $type && length $type;
			return join '', map { $_->{'text'} } grep { ($_->{'type'} // '') eq $type } @{ $parts || [] };
		};
		local *subs::coding_run_state_save = sub {
			my ($id, $st) = @_;
			$state{$id} = $st;
			push @snapshots, {
				%$st,
				current => (ref $st->{'current'} eq 'HASH' ? { %{$st->{'current'}} } : $st->{'current'}),
			};
			1;
		};
		local *subs::coding_run_state_load = sub { $state{ $_[0] } || {} };
		local *subs::jawn_version = sub { '9.9.9' };
		local *Manager::coding_conversation_load = sub { [] };
		local *Manager::coding_conversation_save = sub { 1 };
		local *Manager::coding_system_prompt = sub { 'system' };
		local *Manager::coding_execute = sub {
			my ($c, $action) = @_;
			push @executed, $action->{'action'} // '';
			return $execute ? $execute->(@_) : 'ok';
		};
		local *Manager::agent_registry_note = sub { { title => 'A title' } };
		&subs::coding_run_job($job, { task => 'do it', conversation => 'selftest' });
	}
	return ( $state{999} || {}, $job, $calls, \@executed, \@snapshots, $saw_sink );
}

# A parent hands one read to a child, the child finishes, and the parent ships.
{
	my ($state, $job, $calls, $executed, $snapshots, $saw_sink) = run_fake_job(sub {
		my $n = shift;
		return ('{"action":"agent","task":"find the cursor","scope":"read","paths":[]}', undef) if $n == 1;
		return ('{"action":"read","path":"lib/JawnOS/Domain/Coding.pm"}', undef) if $n == 2;
		return ('{"action":"done","text":"the cursor is in sync_cursors"}', undef) if $n == 3;
		return ('{"action":"done","text":"parent finished"}', undef);
	});
	is($calls, 4, 'the parent and the child each take their turns');
	ok($saw_sink, 'the parent passes an on_delta sink to the model');
	is($state->{'state'}, 'finished', 'the parent run finishes');
	is($state->{'final'}, 'parent finished', 'the parent keeps its own last word');
	is($state->{'children'}, 1, 'one child is counted on the run');
	is(scalar @{ $state->{'steps'} || [] }, 2, 'the agent step and the parent done step are recorded');
	is($state->{'steps'}[0]{'action'}{'action'}, 'agent', 'the first parent step is the agent action');
	like($state->{'steps'}[0]{'observation'}, qr/^subagent:/, 'the observation names the subagent');
	my $child = $state->{'steps'}[0]{'subagent'};
	ok(ref $child eq 'HASH', 'the parent step carries the child record');
	is($child->{'task'}, 'find the cursor', 'the child record keeps its task');
	is($child->{'scope'}, 'read', 'the scope defaults to read');
	is(scalar @{ $child->{'steps'} || [] }, 1, 'the child records the one read it did');
	is($child->{'steps'}[0]{'action'}{'action'}, 'read', 'the child step is the read');
	is($child->{'final'}, 'the cursor is in sync_cursors', 'the child final reaches the record');
	is_deeply($executed, [ 'read', 'done' ], 'the parent never sends agent to the toolset');
	ok($job->{'done'} && !$job->{'error'}, 'the Minion job is finished');

	my ($live) = grep { ref $_->{'current'} eq 'HASH' && length($_->{'current'}{'live_text'} // '') } @$snapshots;
	ok($live, 'a live snapshot reaches the panel while the model writes');
	is($live->{'current'}{'live_text'}, 'the answer', 'the live text is what the sink saw');
	is($live->{'current'}{'live_reasoning'}, 'considering ', 'the live reasoning is kept beside it');
	is($live->{'current'}{'state'}, 'thinking', 'the live line is a thinking state');
}

# A read-scope child that tries to write is refused, and the toolset never sees
# the write; the parent still finishes.
{
	my ($state, $job, $calls, $executed) = run_fake_job(sub {
		my $n = shift;
		return ('{"action":"agent","task":"edit it","scope":"read","paths":["lib/JawnOS/Domain"]}', undef) if $n == 1;
		return ('{"action":"write","path":"lib/JawnOS/Domain/Coding.pm","content":"x"}', undef) if $n == 2;
		return ('{"action":"done","text":"could not write"}', undef) if $n == 3;
		return ('{"action":"done","text":"parent done"}', undef);
	});
	my $child = $state->{'steps'}[0]{'subagent'};
	is(scalar @{ $child->{'steps'} || [] }, 1, 'the refused write is still a child step');
	like($child->{'steps'}[0]{'observation'}, qr/^refused:/, 'the child is told the write was refused');
	ok(!grep({ $_ eq 'write' } @$executed), 'the toolset never ran the refused write');
	is($state->{'state'}, 'finished', 'a refused child write does not fail the parent');
	is($state->{'final'}, 'parent done', 'the parent finishes its own run');
}

# The third child in one run is refused, and the parent is told why.
{
	my ($state, $job) = run_fake_job(sub {
		my $n = shift;
		return ('{"action":"agent","task":"one","scope":"read"}', undef) if $n == 1;
		return ('{"action":"done","text":"one done"}', undef) if $n == 2;
		return ('{"action":"agent","task":"two","scope":"read"}', undef) if $n == 3;
		return ('{"action":"done","text":"two done"}', undef) if $n == 4;
		return ('{"action":"agent","task":"three","scope":"read"}', undef) if $n == 5;
		return ('{"action":"done","text":"parent done"}', undef);
	});
	is($state->{'children'}, 2, 'two children are counted, the third is not');
	like($state->{'steps'}[2]{'observation'}, qr/^subagent failed: .*2 subagents/,
		'the refused third child says the run has used its two');
	is($state->{'state'}, 'finished', 'the parent continues after a refused child');
}

# A setting of zero refuses the agent action outright, and the parent continues.
{
	my ($state, $job) = run_fake_job(sub {
		my $n = shift;
		return ('{"action":"agent","task":"one","scope":"read"}', undef) if $n == 1;
		return ('{"action":"done","text":"parent done"}', undef);
	}, undef, '0');
	ok(!($state->{'children'} // 0), 'no child is counted when subagents are off');
	like($state->{'steps'}[0]{'observation'}, qr/^subagent failed: .*0 subagents/,
		'the refused child says subagents are off');
	is($state->{'state'}, 'finished', 'the parent continues with subagents off');
	is($state->{'final'}, 'parent done', 'the parent still finishes its run');
}

# --- the prompt and the tool list -------------------------------------------
my $tools = source('perl/gb/03_engines_and_tools.pl');
like($tools, qr/name => 'agent'/, 'the Coding tool list offers agent');
like($tools, qr/"action":"agent"/, 'the agent entry has an example');
like($tools, qr/scope.*read|read.*scope/s, 'the agent entry names the read scope');
like($tools, qr/scope.*write|write.*scope/s, 'the agent entry names the write scope');
like($tools, qr/cannot ship/, 'the agent entry says it cannot ship');

my $help = source('perl/help.pl');
like($help, qr/Use agent for a self-contained investigation or a scoped edit/,
	'the coding prompt tells the agent when to use a subagent');
like($help, qr/Never ask a subagent to spawn/, 'the coding prompt forbids nesting');

done_testing();
