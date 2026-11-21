# tests-for: public/js/manager/terminal.js public/js/manager/terminal/02_events.js public/js/manager/windows/03_stack.js
# covers:    Terminal's window lifecycle - a view is pruned when its window closes
#            rather than at the next open, its ResizeObserver and any pending
#            resize or repaint are released with it, and the shell registry runs
#            the hook that does it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $events = read_file("$root/public/js/manager/terminal/02_events.js");
my $stack  = read_file("$root/public/js/manager/windows/03_stack.js");

# --- a view counts as live only while its root is in the page ----------------
my ($prune) = $events =~ /function terminalPruneViews\(\) \{(.*?)\n\}/s;
ok(defined $prune, 'the prune is found');
$prune = '' unless defined $prune;
like($prune, qr/!v\.root\.isConnected/, 'a detached root is what makes a view stale');
like($prune, qr/v\.observer\.disconnect\(\)/, 'its ResizeObserver is disconnected');
like($prune, qr/clearTimeout\(v\.resizeTimer\)/, 'a pending resize timer is cleared');
like($prune, qr/cancelAnimationFrame\(v\.state\.raf\)/, 'and a pending repaint cancelled');

# --- close is the moment to prune -------------------------------------------
like($events, qr/function terminalTeardown\(\)/, 'Terminal has a close hook');
like($events, qr/function terminalTeardown\(\) \{\s*terminalPruneViews\(\);/s,
	'the hook prunes immediately instead of waiting for the next open');
my ($teardown) = $events =~ /function terminalTeardown\(\) \{(.*?)\n\}/s;
ok(defined $teardown, 'the hook is found');
$teardown = '' unless defined $teardown;
like($teardown, qr/terminalCurrentView = null/, 'the closed view stops being current');
like($teardown, qr/terminalVars = terminalNewState\(\)/,
	'and the shared parser state is dropped with it');
like($events, qr/jawnosAppTeardown\['terminal'\] = terminalTeardown/,
	'the shell registry learns about it');

# --- the shell runs a registered hook after the window leaves the page ------
like($stack, qr/jawnosAppTeardown\[app\]/, 'the close path knows the registry');

done_testing();
