# tests-for: lib/JawnOS/Domain/Sent.pm lib/JawnOS/Controller/manager_help.pm
# covers:    the Help model dropdown asks the shared chat catalogue once, keeps only
#            providers that can answer, then reads the provider-keyed local cache;
#            a provider that answers nothing is an empty group, not a crash.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

# The domain layer is lazy: load the real definition before the local stubs.
subs::preload('help_model_list');
require(root() . '/lib/JawnOS/Controller/manager_help.pm');

my @calls;

# The review route's controller shape: param reads the request, render keeps
# the JSON reply so the test can see what the route answered.
{
	package ReviewTestController;
	sub new { my ($class, %args) = @_; return bless { %args, rendered => undef }, $class }
	sub param { return $_[0]->{'param'}->{ $_[1] } }
	sub render {
		my ($self, %args) = @_;
		$self->{'rendered'} = $args{'json'};
		return 1;
	}
}

# A cached list is the whole answer: no provider is touched.
{
	no warnings 'once';
	local *subs::cache_get = sub { push @calls, 'get'; return [ { name => 'cached' } ] };
	local *subs::cache_set = sub { push @calls, 'set' };
	local *subs::pen_model_list = sub { push @calls, 'pen'; return [] };
	local *subs::cloudflare_model_list = sub { push @calls, 'cloud'; return [] };
	my $list = &subs::help_model_list();
	is_deeply($list, [ { name => 'cached' } ], 'a cached list is returned');
	is_deeply(\@calls, ['get'], 'no provider is polled on a cache hit');
}

# A miss asks the shared chat catalogue, keeps only providers that can answer
# here, flattens them to picker rows, and caches the result.
{
	@calls = ();
	no warnings 'once';
	local *subs::cache_get = sub { push @calls, 'get'; return undef };
	my ($stored_params, $stored_data);
	local *subs::cache_set = sub { push @calls, 'set'; ($stored_params, $stored_data) = @_ };
	local *subs::ai_model_catalogue = sub {
		push @calls, 'catalogue';
		return [
			{ id => 'ollama', label => 'Ollama (local)', models => [ { value => 'qwen3:8b', name => 'qwen3:8b' } ] },
			{ id => 'cloudflare', label => 'Cloudflare Workers AI', models => [ { value => '@cf/llama', name => '@cf/llama' } ] },
			{ id => 'openai', label => 'OpenAI', models => [ { value => 'openai:gpt-4o', name => 'gpt-4o' } ] },
		];
	};
	local *subs::ai_provider_ready = sub {
		my ($id) = @_;
		push @calls, 'ready:' . $id;
		return ($id eq 'cloudflare') ? 1 : 0;
	};
	my $list = &subs::help_model_list();
	is_deeply([ map { $_->{'model'} } @{$list} ], [ 'qwen3:8b', '@cf/llama' ],
		'only a ready provider is offered; a provider with models of its own is too');
	is_deeply(\@calls, [ 'get', 'catalogue', 'ready:cloudflare', 'ready:openai', 'set' ],
		'a miss asks the catalogue once and checks the keyed providers');
	is($stored_params->{'app'}, 'mail', 'the cached list belongs to the mail app');
	like($stored_params->{'context'}, qr/^help_models_/, 'the cache is keyed by the provider set');
	is($stored_params->{'warranty'}, '-10m', 'the list is kept for ten minutes');
	is_deeply($stored_data, $list, 'the merged list is what is cached');
}

# A provider that answers nothing is treated as empty, so one broken probe cannot
# take the dropdown (or the Help window) down with it.
{
	no warnings 'once';
	local *subs::cache_get = sub { return undef };
	local *subs::cache_set = sub { };
	local *subs::ai_model_catalogue = sub {
		return [
			{ id => 'ollama', label => 'Ollama (local)', models => [] },
			{ id => 'cloudflare', label => 'Cloudflare Workers AI', models => [ { value => '@cf/cf', name => '@cf/cf' } ] },
		];
	};
	local *subs::ai_provider_ready = sub { return 1 };
	my $list = &subs::help_model_list();
	is_deeply([ map { $_->{'model'} } @{$list} ], [ '@cf/cf' ],
		'a provider with no answer contributes nothing');
}

# The review prompt is built as lines. It joined its fields with a literal
# backslash-n (a single-quoted '\n'), so the model saw one long line. The
# request is what is under test; the answer is stubbed.
{
	my $got_user;
	no warnings 'once', 'redefine';
	local $gb::known_appts = {};
	local *subs::setting_grabber = sub {
		my ($args) = @_;
		my $setting = ($args && $args->{'setting'}) || '';
		return '[]'    if $setting eq 'guide_reviewed';
		return 'model' if $setting eq 'help_assistant';
		return '';
	};
	local *subs::settings_grabber = sub { return { pos => 'media', mab => '' } };
	local *subs::ai_role_thinking_effective = sub { return '' };
	local *subs::evaluation_model_call_role = sub {
		$got_user = $_[2];
		return ('{"pos":"media","keep":true}', undef);
	};
	local *subs::setting_setter = sub { return 1 };

	my $app = &subs::unformat_name('the_tonight_show');
	foreach my $case (
		[ '',               qr/\AApp: \Q$app\E\nCurrent pos: media\nCurrent mab: \z/ ],
		[ 'late night talk', qr/\AApp: \Q$app\E\nCurrent pos: media\nCurrent mab: \nDescription: late night talk\z/ ],
	) {
		my ($description, $want) = @{$case};
		my $c = ReviewTestController->new(
			param => { app => 'the_tonight_show', description => $description },
		);
		Manager::action_37610($c);
		like($got_user, $want, 'the review prompt is built as real lines');
		unlike($got_user, qr/\\n/, 'no literal backslash-n reaches the model');
		is($c->{'rendered'}->{'reviewed'}, 1, 'the review answered and marked the app');
	}
}

done_testing();
