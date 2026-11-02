# tests-for: lib/JawnOS/Domain/Sent.pm lib/JawnOS/Controller/manager_help.pm
# covers:    the Help model dropdown polls Ollama and Cloudflare once, then answers from the
#            local cache; a provider that answers nothing is an empty list, not a crash.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

# The domain layer is lazy: load the real definition before the local stubs.
subs::preload('help_model_list');

my @calls;

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

# A miss polls both providers, merges them, and stores the result for ten minutes.
{
	@calls = ();
	no warnings 'once';
	local *subs::cache_get = sub { push @calls, 'get'; return undef };
	my ($stored_params, $stored_data);
	local *subs::cache_set = sub { push @calls, 'set'; ($stored_params, $stored_data) = @_ };
	local *subs::pen_model_list = sub { push @calls, 'pen'; return [ { name => 'ollama' } ] };
	local *subs::cloudflare_model_list = sub { push @calls, 'cloud'; return [ { name => 'cf' } ] };
	my $list = &subs::help_model_list();
	is_deeply($list, [ { name => 'ollama' }, { name => 'cf' } ], 'both provider lists are merged');
	is_deeply(\@calls, [ 'get', 'pen', 'cloud', 'set' ], 'a miss polls both providers and stores the result');
	is($stored_params->{'app'}, 'mail', 'the cached list belongs to the mail app');
	is($stored_params->{'context'}, 'help_models', 'the cached list has its own context');
	is($stored_params->{'warranty'}, '-10m', 'the list is kept for ten minutes');
	is_deeply($stored_data, $list, 'the merged list is what is cached');
}

# A provider that answers nothing is treated as empty, so one broken probe cannot
# take the dropdown (or the Help window) down with it.
{
	no warnings 'once';
	local *subs::cache_get = sub { return undef };
	local *subs::cache_set = sub { };
	local *subs::pen_model_list = sub { return undef };
	local *subs::cloudflare_model_list = sub { return [ { name => 'cf' } ] };
	my $list = &subs::help_model_list();
	is_deeply($list, [ { name => 'cf' } ], 'a provider with no answer becomes an empty list');
}

done_testing();
