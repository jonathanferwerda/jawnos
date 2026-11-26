# tests-for: lib/JawnOS/Domain/Intelligence.pm lib/JawnOS/Controller/manager_intelligence.pm lib/JawnOS/Routes/manager_intelligence.pm lib/JawnOS/Routes.pm lib/JawnOS/Domain/Loader.pm templates/apps/intelligence.html.ep public/js/manager/intelligence.js templates/start_menu/start_menu.html.ep public/js/manager/manager/05_start_menu.js lib/JawnOS/Manager/Core1_tables_hooks.pm perl/gb/02_labels_and_collectives.pl perl/help/topics_apps.pl public/icons/sets/build.js public/icons/intelligence.svg t/460-icon-sets-generation.t
# covers:    The Intelligence app: its six domain panels, the role grouping,
#            empty-database tolerance, evaluation scope/cadence and history range
#            shaping, the editable cadence/days controls, the route and
#            controller wiring, the pill markup, and the generated icon.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(encode_json);
use Time::Piece;
use JawnOSTest;
use RepoSource;

# The domain layer is lazy: load the real definitions before the local *subs::
# stubs below, or a later module load would replace a stub mid-test.
subs::preload($_) for qw(
	intelligence_summary intelligence_agents intelligence_evaluations
	intelligence_providers intelligence_history intelligence_recent
);

# The domain readers only ever ask db_query for ->hashes.
{
	package FakeRows;
	sub new    { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
}

{
	package FakeMinion;
	sub new { my ($class, $sched) = @_; return bless { schedules => $sched || [] }, $class }
	sub list_schedules { return { schedules => $_[0]->{'schedules'} } }
}

# ---------------------------------------------------------------- role groups
{
	local *subs::db_query = sub {
		my ($sql) = @_;
		if ($sql =~ /group by role, provider/) {
			return FakeRows->new([
				{ role => 'chatbot_model',    provider => 'deepseek',   ti => 100, t_o => 50,  calls => 2, active_minutes => 1, sessions => 1, last_used => '2026-01-01 10:00' },
				{ role => 'coding_assistant', provider => 'cloudflare', ti => 200, t_o => 100, calls => 3, active_minutes => 2, sessions => 2, last_used => '2026-01-02 11:00' },
				{ role => 'help_assistant',   provider => 'deepseek',   ti => 10,  t_o => 5,   calls => 1, active_minutes => 1, sessions => 1, last_used => '2026-01-01 09:00' },
				{ role => 'visual_assistant', provider => 'deepseek',   ti => 20,  t_o => 10,  calls => 1, active_minutes => 1, sessions => 1, last_used => '2026-01-01 09:30' },
				{ role => 'eval_assistant',   provider => 'opencode',   ti => 40,  t_o => 20,  calls => 1, active_minutes => 1, sessions => 1, last_used => '2026-01-01 08:00' },
				{ role => 'music_assistant',  provider => 'ollama',     ti => 5,   t_o => 5,   calls => 1, active_minutes => 1, sessions => 1, last_used => '2026-01-01 07:00' },
				{ role => 'some_new_role',    provider => 'ollama',     ti => 1,   t_o => 1,   calls => 1, active_minutes => 1, sessions => 1, last_used => '2026-01-01 06:00' },
			]);
		}
		return FakeRows->new([]);
	};
	# The card's session count is the ledger's own run-of-calls arithmetic, not
	# the SQL row's hour count; stub that helper with the same shape the real one
	# returns (provider -> roles -> role).
	local *subs::ai_spend_sessions = sub {
		return { providers => {
			deepseek   => { roles => { chatbot_model => { sessions => 1, active_ms => 60000 }, help_assistant => { sessions => 1, active_ms => 60000 }, visual_assistant => { sessions => 1, active_ms => 60000 } } },
			cloudflare => { roles => { coding_assistant => { sessions => 2, active_ms => 120000 } } },
			opencode   => { roles => { eval_assistant => { sessions => 1, active_ms => 60000 } } },
			ollama     => { roles => { music_assistant => { sessions => 1, active_ms => 60000 }, some_new_role => { sessions => 1, active_ms => 60000 } } },
		} };
	};

	my $groups = &subs::intelligence_agents();
	is(ref $groups, 'ARRAY', 'intelligence_agents returns a list');
	my %by = map { $_->{'name'} => $_ } @{$groups};

	is($by{'Pen'}->{'tokens'}, 150, 'chatbot_model is Pen and its tokens add up');
	is($by{'Coding agent'}->{'tokens'}, 300, 'coding_assistant is the Coding agent');
	is($by{'Guide & associates'}->{'tokens'}, 45, 'help and visual assistants are Guide & associates');
	is($by{'Evaluations'}->{'tokens'}, 60, 'eval_assistant is Evaluations');
	is($by{'Other'}->{'tokens'}, 12, 'music and an unknown role fall into Other');
	is($by{'Pen'}->{'providers'}->{'deepseek'}, 150, 'the group keeps its provider mix');
	is($by{'Coding agent'}->{'sessions'}, 2, 'sessions are summed for the group');
	is($by{'Coding agent'}->{'last_used'}, '2026-01-02 11:00', 'the newest use is the group last used');
	is(scalar(keys %{$by{'Guide & associates'}->{'providers'}}), 1, 'providers are merged across the roles');
}

# ------------------------------------------------------- empty database is safe
{
	local *subs::db_query = sub { return FakeRows->new([]) };
	local *subs::ai_spend_sessions = sub { return { providers => {} } };
	local *subs::setting_grabber = sub { return undef };
	local *subs::evaluation_cadence = sub { return 'off' };
	local *subs::nightly_evaluation_days = sub { return [] };
	local *subs::minion_grabber = sub { return FakeMinion->new };
	local *subs::ai_house_budget_spent = sub { return 0 };
	local *subs::ai_balance_report = sub { return { rows => [] } };
	local *subs::ai_balance_chart = sub { return { series => [] } };

	my $summary = eval { &subs::intelligence_summary() };
	is($@, '', 'intelligence_summary survives an empty database');
	is($summary->{'today'}->{'tokens'}, 0, 'today reads zero');
	is($summary->{'week'}->{'tokens'}, 0, 'the week reads zero');
	is($summary->{'month'}->{'tokens'}, 0, 'the month reads zero');
	is($summary->{'budget'}->{'spent'}, 0, 'the purse reads zero');

	my $agents = eval { &subs::intelligence_agents() };
	is($@, '', 'intelligence_agents survives an empty database');
	ok(scalar(@{$agents}) >= 5, 'the five agent groups are still named');

	my $evaluations = eval { &subs::intelligence_evaluations() };
	is($@, '', 'intelligence_evaluations survives an empty database');
	my ($house) = grep { $_->{'scope'} eq '__president' } @{$evaluations};
	ok($house, 'the whole house is always a scope');
	is($house->{'tokens_7d'}, 0, 'an unasked scope reads zero tokens');

	my $providers = eval { &subs::intelligence_providers() };
	is($@, '', 'intelligence_providers survives an empty database');
	ok(ref $providers->{'rows'} eq 'ARRAY' && @{ $providers->{'rows'} } >= 6,
		'the known providers and the total are still rows');

	my $history = eval { &subs::intelligence_history('7d') };
	is($@, '', 'intelligence_history survives an empty database');
	is(scalar @{ $history->{'days'} }, 7, '7d still answers seven day rows');
	is($history->{'totals'}->{'tokens'}, 0, 'an empty range totals zero');

	my $recent = eval { &subs::intelligence_recent(5) };
	is($@, '', 'intelligence_recent survives an empty database');
	is_deeply($recent, [], 'no calls read as no rows');
}

# ---------------------------------------------- evaluation scopes and cadence
{
	my $now = &subs::rightNow();
	my $runs = encode_json([
		{ timestamp => $now - 3600 * 1000, machine => 'here', model => 'test-model', outcome => 'ran', tokens => 123 },
	]);
	local *subs::db_query = sub {
		my ($sql) = @_;
		if ($sql =~ /select distinct app from settings/) {
			return FakeRows->new([ { app => 'mail' }, { app => 'notes' } ]);
		}
		if ($sql =~ /from ai_spend where role = \? and app/) {
			return FakeRows->new([ { app => 'mail', t7 => 700, t30 => 3000 } ]);
		}
		return FakeRows->new([]);
	};
	local *subs::setting_grabber = sub {
		my ($args) = @_;
		return $runs if ($args->{'setting'} // '') eq 'evaluation_runs' && ($args->{'app'} // '') eq 'mail';
		return undef;
	};
	local *subs::evaluation_cadence = sub {
		my ($app) = @_;
		return 'daily' if $app eq 'mail';
		return 'each_run' if $app eq '__president';
		return 'off';
	};
	local *subs::nightly_evaluation_days = sub {
		my ($app) = @_;
		return [ 1, 3 ] if $app eq 'mail';
		return [];
	};
	local *subs::minion_grabber = sub {
		return FakeMinion->new([ { name => 'nightly_evaluation_mail', next_run => 1700000000 } ]);
	};

	my $rows = &subs::intelligence_evaluations();
	my %by = map { $_->{'scope'} => $_ } @{$rows};
	ok($by{'__president'} && $by{'mail'} && $by{'notes'}, 'every settings scope and the house is enumerated');
	is($by{'mail'}->{'cadence'}, 'daily', 'the cadence is read per scope');
	is_deeply($by{'mail'}->{'days'}, [ 1, 3 ], 'the daily weekdays are carried');
	is($by{'mail'}->{'tokens_30d'}, 3000, 'the scope token split comes from the eval ledger');
	is($by{'mail'}->{'runs_30d'}, 1, 'a thirty-day run is counted');
	is($by{'mail'}->{'avg_per_run'}, 3000, 'the average divides tokens by runs');
	is($by{'mail'}->{'last_run'}->{'outcome'}, 'ran', 'the last run outcome is read');
	is($by{'mail'}->{'last_run'}->{'tokens'}, 123, 'the last run token count is read');
	is($by{'mail'}->{'next_run'}, 1700000000, 'the queued next run comes from the one schedule read');
	is($by{'mail'}->{'state'}, 'active', 'a recent daily run is Active');
	is($by{'__president'}->{'state'}, 'on_demand', 'each_run is On demand');
	is($by{'notes'}->{'state'}, 'idle', 'an off scope with no run is Idle');
}

# ------------------------------------------------------------ history and fallback
{
	my $today = localtime()->strftime('%Y-%m-%d');
	my $older = localtime(time - 3 * 86400)->strftime('%Y-%m-%d');
	local *subs::db_query = sub {
		my ($sql, $since) = @_;
		$since = '' unless defined $since;
		if ($sql =~ /from ai_spend_daily/) {
			return FakeRows->new([ { day => $today, app => 'notes', provider => 'deepseek', tokens => 1000, calls => 5 } ])
				if $today ge $since;
		}
		if ($sql =~ /from ai_budget/) {
			return FakeRows->new([ { day => $older, tokens => 500 } ])
				if $older ge $since;
		}
		return FakeRows->new([]);
	};

	my $week = &subs::intelligence_history('7d');
	is(scalar @{ $week->{'days'} }, 7, '7d has seven days');
	my ($today_row) = grep { $_->{'day'} eq $today } @{ $week->{'days'} };
	is($today_row->{'tokens'}, 1000, 'the daily rollup is read');
	is($today_row->{'calls'}, 5, 'the daily rollup carries calls');
	is($today_row->{'top_agent'}, 'notes', 'the top agent is the day\'s app');
	is($today_row->{'top_provider'}, 'deepseek', 'the top provider is the day\'s provider');
	is($today_row->{'source'}, 'daily', 'a rollup day is marked daily');
	my ($older_row) = grep { $_->{'day'} eq $older } @{ $week->{'days'} };
	is($older_row->{'tokens'}, 500, 'a day the rollup omits falls back to ai_budget');
	is($older_row->{'source'}, 'budget', 'the fallback day is marked budget');
	is($week->{'totals'}->{'tokens'}, 1500, 'the range total adds both sources');
	is($week->{'range'}, '7d', 'the range is echoed');

	my $month = &subs::intelligence_history('30d');
	is(scalar @{ $month->{'days'} }, 30, '30d has thirty days');
	my $short = &subs::intelligence_history('24h');
	is(scalar @{ $short->{'days'} }, 2, '24h spans today and yesterday at daily granularity');
	my $unknown = &subs::intelligence_history('bogus');
	is($unknown->{'range'}, '7d', 'an unknown range falls back to 7d');
}

# --------------------------------------------------------------- web wiring
{
	my $routes = read_file("$FindBin::Bin/../lib/JawnOS/Routes/manager_intelligence.pm");
	like($routes, qr/\[\s*92001\s*,\s*'get'\s*,\s*'\/manager\/intelligence'\s*,\s*'action_92001'\s*\]/,
		'the intelligence route is 92001 GET /manager/intelligence');
	like($routes, qr/\[\s*92002\s*,\s*'post'\s*,\s*'\/manager\/intelligence\/cadence'\s*,\s*'action_92002'\s*\]/,
		'the cadence change is 92002 POST /manager/intelligence/cadence');
	my $controller = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_intelligence.pm");
	like($controller, qr/sub\s+action_92001\b/, 'the controller defines action_92001');
	like($controller, qr/sub\s+action_92002\b/, 'the controller defines the cadence action');
	like($controller, qr/evaluation_cadence_apply\(\$app, \$cadence\)/, 'the cadence action uses the schedule arranger');
	like($controller, qr/nightly_evaluation_days/, 'the cadence action saves the weekdays');
	like($controller, qr/intel\s*=>\s*\$data/, 'the panels use a non-reserved stash name');
	unlike($controller, qr/render_to_string\([^;]*data\s*=>\s*\$data/s,
		'the panels are not passed as Mojo response data');
	like($controller, qr/app\s*=>\s*'intelligence'/, 'the controller opens the intelligence window');
	my $names = read_file("$FindBin::Bin/../lib/JawnOS/Routes.pm");
	like($names, qr/\bmanager_intelligence\b/, 'the route module is registered in @NAMES');

	my $tpl = read_file("$FindBin::Bin/../templates/apps/intelligence.html.ep");
	like($tpl, qr/ref \$intel eq 'HASH'/, 'the template reads the intel stash');
	like($tpl, qr/display:flex; flex-wrap:nowrap; overflow-x:auto; overflow-y:hidden; white-space:nowrap/,
		'the pill row scrolls sideways and never wraps');
	like($tpl, qr/border-radius:999px/, 'the pills are rounded');
	like($tpl, qr/flex:1 1 auto; min-height:0; overflow-y:auto/, 'a panel fills the window and scrolls');
	for my $section (qw(overview agents evaluations providers history)) {
		like($tpl, qr/data-section="$section"/, "the $section panel is present");
	}
	like($tpl, qr/data-eval-filter="active"/, 'the evaluation filter pills are present');
	like($tpl, qr/data-history-range="7d"/, 'the history range pills are present');
	like($tpl, qr/class="intelligence_cadence" data-scope=/, 'each evaluation row carries an editable cadence picker');
	like($tpl, qr/class="intelligence_days" data-scope=/, 'each evaluation row carries an editable weekday picker');
	like($tpl, qr/class="intelligence_next_run" data-scope=/, 'the row names the next-run span the picker updates');

	my $js = read_file("$FindBin::Bin/../public/js/manager/intelligence.js");
	like($js, qr/function\s+intelligenceOpener\b/, 'the lazy entry function exists');
	like($js, qr/localStorage\.setItem\(intelligenceSectionKey/, 'the section pill is remembered');
	like($js, qr/localStorage\.setItem\(intelligenceHistoryKey/, 'the history range is remembered');
	like($js, qr/url:\s*'\/manager\/intelligence\/cadence'/, 'the cadence picker posts to the app route');
	like($js, qr/payload\.days/, 'the weekday picker sends days in the cadence request');
	unlike($js, qr/settingSetter/, 'the weekdays are not a second request');

	my $menu = read_file("$FindBin::Bin/../templates/start_menu/start_menu.html.ep");
	like($menu, qr/id="intelligence_toggle"/, 'the start menu carries the intelligence icon');
	my $maps = read_file("$FindBin::Bin/../lib/JawnOS/Manager/Core1_tables_hooks.pm");
	like($maps, qr/intelligence\s*=>\s*\[qw\(\/js\/manager\/intelligence\.js\)\]/, 'the app script is lazy');
	like($maps, qr/intelligence\s*=>\s*\[qw\(intelligenceOpener\)\]/, 'the entry stub is declared');
	like($maps, qr/intelligence_toggle\s*=>\s*'intelligence'/, 'the first click is routed to the app');
}

# ------------------------------------------------------------------ the icon
{
	my $fallback = "$FindBin::Bin/../public/icons/intelligence.svg";
	ok(-s $fallback, 'the stable fallback icon exists');
	opendir(my $dh, "$FindBin::Bin/../public/icons/sets") or die $!;
	my @sets = sort grep { /^(?!\.\.?$)/ && -d "$FindBin::Bin/../public/icons/sets/$_" } readdir($dh);
	closedir $dh;
	is(scalar(@sets), 32, 'sixteen styles in a light and a dark cut');
	my @missing = grep { !-s "$FindBin::Bin/../public/icons/sets/$_/intelligence.svg" } @sets;
	is_deeply(\@missing, [], 'every icon set draws intelligence');
}

done_testing();
