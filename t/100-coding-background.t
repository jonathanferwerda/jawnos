# tests-for: lib/JawnOS/Domain/Coding.pm perl/Coding.pl lib/JawnOS/Controller/manager_misc11.pm lib/JawnOS/Routes/manager_misc11.pm jawn public/js/manager/coding.js public/js/manager/coding/ public/js/manager/agents.js public/js/manager/manager/01_assistant_conversation.js public/js/manager/windows/01_storage.js templates/apps/coding_chat.html.ep
# covers:    the Coding agent as a background process - its own queue, the run
#           record the panel reattaches to, the master that leaves it alone on a
#           tree restart, and the browser's remembered panels.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Slurp qw(read_file);
use Test::More;

my $root = "$FindBin::Bin/..";

# Loading the module defines the subs without touching a database: every helper
# that reads one is only called by the job, not at compile time.
require JawnOS::Domain::Coding;

sub source {
	my ($rel) = @_;
	return read_file("$root/$rel");
}

# A split script is its index plus the numbered parts; a source-grep test that
# reads only the index stops seeing the code that moved.
sub js_source {
	my ($rel) = @_;
	my $index = "$root/$rel";
	my @files = -f $index ? ($index) : ();
	(my $dir = $index) =~ s{\.js$}{};
	push @files, sort grep { -f } glob("$dir/*.js") if -d $dir;
	return join '', map { read_file($_) } @files;
}

sub sub_body {
	my ($text, $name) = @_;
	my ($body) = $text =~ /sub\s+\Q$name\E\s*(?:\([^)]*\))?\s*\{(.*?)\n\}/s;
	return $body // '';
}

# --- the one pure part of the job -------------------------------------------
is_deeply(
	&subs::coding_parse_action('{"action":"read","path":"AGENTS.md"}'),
	{ action => 'read', path => 'AGENTS.md' },
	'a bare JSON action parses'
);

is_deeply(
	&subs::coding_parse_action('Sure, here it is: {"action":"done","text":"ok"} - anything else?'),
	{ action => 'done', text => 'ok' },
	'a JSON object wrapped in prose still parses'
);

is(&subs::coding_parse_action('I could not find that file.'), undef, 'prose is not an action');
is(&subs::coding_parse_action(''), undef, 'an empty answer is not an action');
is(&subs::coding_parse_action('{"action":""}'), undef, 'an action without a verb is refused');

# --- the bound the panel reads ----------------------------------------------
my $long = 'x' x 5000;
my $view = &subs::coding_step_view($long);
ok(length($view) <= 1210, 'a long observation is trimmed for the panel');
like($view, qr/…$/, 'the trim is marked');
my $why = &subs::coding_reasoning_view('y' x 5000);
ok(length($why) <= 4010, 'a long reasoning is trimmed for the panel');
like($why, qr/…$/, 'the reasoning trim is marked');

# --- the job loop, with the model and the tools stubbed ----------------------
# The loop is the part a reload used to kill. These stubs stand in for the
# model and the checked toolset, so the whole run - steps, final answer,
# conversation save, Minion finish - is exercised without touching the tree.
{
	package FakeJob;
	sub new { bless { id => 999, done => 0, error => '', result => undef }, shift }
	sub id { $_[0]->{'id'} }
	sub finish { $_[0]->{'done'} = 1; $_[0]->{'result'} = $_[1]; 1 }
	sub fail { $_[0]->{'done'} = 1; $_[0]->{'error'} = $_[1]; 1 }
}

sub run_fake_job {
	my ($responder, $execute) = @_;
	my %state;
	my $calls = 0;
	my $job = FakeJob->new;
	{
		no warnings 'redefine';
		local *subs::rightNow = sub { 123 };
		local *subs::setting_grabber = sub { 'fake-model' };
		local *subs::ai_role_thinking_effective = sub { '' };
		local *subs::ai_chat_parts_with_fallback = sub {
			$calls++;
			my ($text, $err) = $responder->($calls);
			return (undef, $err) if $err;
			return ([ { type => 'reasoning', text => "why $calls" }, { type => 'text', text => $text } ], undef);
		};
		local *subs::ai_parts_text = sub {
			my ($parts, $type) = @_;
			$type = 'text' unless defined $type && length $type;
			return join '', map { $_->{'text'} } grep { ($_->{'type'} // '') eq $type } @{ $parts || [] };
		};
		local *subs::coding_run_state_save = sub { $state{ $_[0] } = $_[1]; 1 };
		local *subs::coding_run_state_load = sub { $state{ $_[0] } || {} };
		local *subs::coding_run_push = sub { 1 };
		local *subs::coding_review_setting = sub { 0 };
		local *subs::jawn_version = sub { '9.9.9' };
		local *Manager::coding_conversation_load = sub { [] };
		local *Manager::coding_conversation_save = sub { 1 };
		local *Manager::coding_system_prompt = sub { 'system' };
		local *Manager::coding_execute = $execute || sub { 'read 42 bytes' };
		local *Manager::agent_registry_note = sub { { title => 'A title' } };
		&subs::coding_run_job($job, { task => 'do it', conversation => 'selftest' });
	}
	return ( $state{999} || {}, $job, $calls );
}

{
	my $n = 0;
	my ($state, $job, $calls) = run_fake_job(sub {
		$n++;
		return $n == 1
			? ('{"action":"read","path":"AGENTS.md"}', undef)
			: ('{"action":"done","text":"all done"}', undef);
	});
	is($calls, 2, 'the loop takes one action per model turn');
	is($state->{'state'}, 'finished', 'the run finishes');
	is($state->{'final'}, 'all done', 'the last word reaches the panel');
	is(scalar @{ $state->{'steps'} || [] }, 2, 'both steps are in the record');
	is($state->{'steps'}[0]{'reasoning'}, 'why 1', 'the reasoning is kept beside the step');
	ok(!exists $state->{'current'}, 'no live line is left on a finished run');
	is($state->{'title'}, 'A title', 'the registry title is carried back');
	is($state->{'version'}, '9.9.9', 'the version is carried back');
	ok($job->{'done'} && !$job->{'error'}, 'the Minion job is finished');
}

{
	my ($state, $job) = run_fake_job(sub { (undef, 'the model answered 500') });
	is($state->{'state'}, 'failed', 'a model error fails the run');
	like($state->{'error'} // '', qr/500/, 'the reason is kept for the panel');
	ok($job->{'done'} && $job->{'error'}, 'the Minion job is failed too');
}

# --- the worker --------------------------------------------------------------
my $worker = source('perl/Coding.pl');
like($worker, qr/\$ENV\{PURPOSE\}\s*=\s*'coding'/, 'the worker names its purpose');
like($worker, qr/&\w+::coding_minion\(\)/, 'the worker consumes the coding queue, not the tree minion');
like($worker, qr/status->\{queues\}\s*=\s*\['coding'\]/, 'the worker takes only the coding queue');
like($worker, qr/status->\{jobs\}\s*=\s*1/, 'one coding run at a time');
like($worker, qr/status->\{spare\}\s*=\s*0/, 'no spare slot, so one active run really is one');
like($worker, qr/on\(wait => sub/, 'the worker checks for new code between jobs');
like($worker, qr/jawn_version_forget/, 'and re-reads VERSION instead of its boot cache');

# --- the run record ---------------------------------------------------------
my $domain = source('lib/JawnOS/Domain/Coding.pm');
like($domain, qr/'coding_run_'\s*\.\s*\$id/, 'a run is a per-device setting keyed by id');
like($domain, qr/coding-queue\.db/, 'the queue has a file the master reload does not wipe');
	like($domain, qr/JAWNOS_MASTER_PID/, 'a run stops when the master that owns it is gone');
	like($domain, qr/sub coding_reasoning_view\b/, 'the model\'s reasoning is trimmed for the panel');
{
	my $body = sub_body($domain, 'coding_run_job');
	like($body, qr/coding_run_state_save\(\$id,\s*\$state\)/,
		'the state is written as the run goes, not only at the end');
	like($body, qr/coding_run_state_load\(\$id\)/, 'the cancel flag is read between model turns');
	like($body, qr/coding_conversation_save/, 'the finished turn joins the remembered conversation');
	like($body, qr/agent_registry_note/, 'the agents list learns the run');
}

# --- the master -------------------------------------------------------------
my $master = source('jawn');
like($master, qr/sub coding_start\b/, 'the master starts the coding process');
like(sub_body($master, 'coding_start'), qr/POSIX::setsid/,
	'the daemon detaches through POSIX, which is imported');
unlike(sub_body($master, 'coding_start'), qr/(?<!::)\bsetsid\(/,
	'no bare setsid in the spawn: ./jawn does not import it');
like($master, qr/sub coding_stop\b/, 'the master can stop it');
like($master, qr/&coding_supervise\(\)/, 'the tick keeps it alive');
like($master, qr/coding-queue\.db/, 'the queue database survives a master reload wipe');
my $keeps = () = $master =~ /&shut_down\(1\)/g;
ok($keeps >= 2, 'a restart and a master reload both keep the coding process');
like(sub_body($master, 'shut_down'), qr/&coding_stop\(\) unless \$keep_coding/,
	'a real stop still takes it down');

# --- the route ---------------------------------------------------------------
my $controller = source('lib/JawnOS/Controller/manager_misc11.pm');
{
	my $heal = sub_body($controller, 'action_37291');
	like($heal, qr/coding_run_enqueue/, 'heal queues a run');
	unlike($heal, qr/coding_execute\(/, 'heal no longer runs the loop inside the request');
	like($heal, qr/queued\s*=>\s*1/, 'heal answers with the run, not the answer');
}
like(sub_body($controller, 'action_37569'), qr/coding_run_view|coding_run_current/,
	'the run route reads the record');
like(sub_body($controller, 'action_37570'), qr/coding_run_cancel/, 'the cancel route exists');

require JawnOS::Routes::manager_misc11;
my $routes = [ JawnOS::Routes::manager_misc11::routes() ];
my ($run_route) = grep { ($_->[2] // '') eq '/manager/coding/run' } @$routes;
ok($run_route, 'the run route is registered');
is($run_route->[1], 'get', 'the panel polls it with GET');
is($run_route->[3], 'action_37569', 'it names its action');
my ($cancel_route) = grep { ($_->[2] // '') eq '/manager/coding/cancel' } @$routes;
ok($cancel_route && $cancel_route->[1] eq 'post', 'the cancel route is a POST');

# --- the browser -------------------------------------------------------------
my $coding_js = js_source('public/js/manager/coding.js');
like($coding_js, qr{/manager/coding/run}, 'the panel polls the run');
like($coding_js, qr{/manager/coding/cancel}, 'the panel can stop');
like($coding_js, qr/function codingChatPoll\b/, 'the poller exists');
like($coding_js, qr/function codingChatReattach\b/, 'a reload reattaches to the run');
like($coding_js, qr/run:\s*panel\.data\('coding_run'\)/, 'the run id rides the reload');
like($coding_js, qr/steps:\s*panel\.data\('coding_steps_shown'\)/, 'the step count rides the reload');
like($coding_js, qr/coding_chat_thought_toggle/, 'a step can open the model\'s reasoning');
like($coding_js, qr/coding_chat_now/, 'the log names what the run is doing now');

my $agents_js = source('public/js/manager/agents.js');
like($agents_js, qr/jawnos_agents_open/, 'the browser remembers the open panels');
like($agents_js, qr/function jawnosAgentOpenRestore\b/, 'and puts them back on load');
like($agents_js, qr/function jawnosAgentOpenForget\b/, 'closing one forgets it');

my $guide_js = source('public/js/manager/manager/01_assistant_conversation.js');
like($guide_js, qr/jawnosAgentOpenRemember\('guide:'/, 'a spawned guide associate is remembered');

my $storage_js = source('public/js/manager/windows/01_storage.js');
like($storage_js, qr/terminal_id:\s*\$\(v\)\.attr\('data-terminal-id'\)/,
	'a terminal window saves its id');
like($storage_js, qr/terminalOpener\(\{ 'window_maker': 'yes', 'terminal_id':/,
	'restoring the window reuses that id, so the coding chat keeps its conversation');

my $template = source('templates/apps/coding_chat.html.ep');
like($template, qr/coding_chat_stop/, 'the panel carries the stop control');

done_testing();
