# tests-for: lib/JawnOS/Domain/Render.pm lib/JawnOS/Manager/Core1_tables_hooks.pm
# covers:    A window draws about fifty icons, template pictures and cursors.
#            They used to be served no-cache, so every open revalidated every
#            one and a phone paid a round trip per icon. They now carry a short
#            max-age; scripts and styles keep the revalidation the bundle's
#            mtime read depends on.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

my $asset = 'private, max-age=300, must-revalidate';
my $check = 'no-cache, max-age=0, must-revalidate';

is(&subs::static_cache_control('/icons/sets/outline_dark/gear.svg'), $asset,
	'an icon may be reused for five minutes');
is(&subs::static_cache_control('/images/decipherable/gear.png'), $asset,
	'template art is cached the same way');
is(&subs::static_cache_control('/cursors/sets/bold/32/pointer.png'), $asset,
	'cursor art is cached the same way');
is(&subs::static_cache_control('/js/manager/bundle.js'), $check,
	'a script still revalidates: the bundle reads its mtime');
is(&subs::static_cache_control('/css/manager.css'), $check,
	'a stylesheet still revalidates');
is(&subs::static_cache_control('/manager'), $check,
	'a page is never cached by this hook');
is(&subs::static_cache_control(undef), $check,
	'a missing path falls back to revalidation');
is(&subs::static_cache_control(''), $check,
	'an empty path falls back to revalidation');

# The hook must ask the policy: a re-hard-coded string would pass the calls
# above and still revalidate every icon.
my $hook = read_file(root() . '/lib/JawnOS/Manager/Core1_tables_hooks.pm');
like($hook, qr/after_static\s*=>\s*sub\s*\{[^}]*static_cache_control/s,
	'the static hook asks static_cache_control');

done_testing();
