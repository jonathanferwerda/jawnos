use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# Two idle costs a phone pays for:
#
#   - the levels loop asked every unreachable peer every two minutes, so a
#     machine that was gone still cost a socket and a radio wake on schedule.
#     It now backs off per peer (doubling, capped at fifteen minutes) and a
#     peer's own announce - a health_report push, an available nudge, or a
#     health pull - clears the backoff at once. That is how "back" is noticed
#     without polling for it.
#
#   - the beat sent the lockdown face to every tab every ten seconds, so every
#     open tab ran a console eval, appended a terminal entry and repainted its
#     clock for a value that rarely moves. It is sent when it changes now, and
#     the sweep that closes a window opened during a lockdown runs when the
#     state turns on and then on a slow cadence.

my $root = repo_root();
my $embedded = read_file("$root/lib/JawnOS/Domain/Embedded.pm");
my $misc13 = read_file("$root/lib/JawnOS/Controller/manager_misc13.pm");
my $ws_pm = read_file("$root/lib/JawnOS/Controller/manager_ws.pm");
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");

# --- the backoff -------------------------------------------------------------

my ($sync) = $embedded =~ /(sub house_levels_sync \{.*?\n\})/s;
ok($sync, 'house_levels_sync is still one sub');

like($sync, qr/context => 'levels_backoff', subcontext => \$rsig/,
	'the backoff is per peer');
like($sync, qr/my \$hold = \(\$backoff->\{'until'\} \|\| 0\) > &rightNow\(\);/,
	'a backed-off peer is not asked');
like($sync, qr/if \(\$hold\) \{\s*\$skipped\+\+;\s*\$keep_previous->\(\$rsig, \$pname\);\s*next;/,
	'a skipped peer keeps the row it last had');
like($sync, qr/my \$delay = 240000 \* \(2 \*\* \(\$failures - 1\)\);/,
	'the delay doubles with each failure');
like($sync, qr/\$delay = 900000 if \$delay > 900000;/,
	'and is capped at fifteen minutes');
like($sync, qr/\$hold = 0 if \$opts->\{'fast'\} && \$failures <= 2;/,
	'an open card looks past a first blip, not past a peer that is gone');
like($sync, qr/# it answered: the next pass asks it again\s*if \(\$failures\) \{/,
	'a peer that answers clears its own record');
like($sync, qr/ - next try in ' \. int\(\$delay \/ 60000\) \. 'm'/,
	'the log line says when the next try is');
like($sync, qr/skipped => \$skipped,/,
	'the snapshot counts the peers it did not ask');

my ($announce) = $embedded =~ /(sub levels_peer_announced \{.*?\n\})/s;
ok($announce, 'levels_peer_announced exists');
like($announce, qr/\{ failures => 0, until => 0, at => &rightNow\(\), announced => &rightNow\(\) \}/,
	'an announce drops the backoff');
like($loader, qr/levels_peer_announced/,
	'the domain loader can find it');

# --- a peer that comes back says so -----------------------------------------

my ($health) = $misc13 =~ /(sub action_45064 \{.*?\n\})/s;
ok($health, 'the health route is found');
like($health, qr/&subs::levels_peer_announced\(\$c->param\('signatorial'\)\);/,
	'GET /manager/health clears the caller\'s backoff');

my ($report) = $misc13 =~ /(sub action_45074 \{.*?\n\})/s;
ok($report, 'the health_report route is found');
like($report, qr/&subs::levels_peer_announced\(\$sig\);/,
	'a health_report push clears the peer\'s backoff');
like($report, qr/a machine reports only itself/i,
	'the self-push guard and its note are still there');

my ($available) = $misc13 =~ /(sub action_45121 \{.*?\n\})/s;
ok($available, 'the available route is found');
like($available, qr/&subs::levels_peer_announced\(\$sig\);/,
	'a scheduled wake clears the peer\'s backoff');

# --- the beat sends the lockdown face when it moves -------------------------

my ($beat) = $ws_pm =~ /(# The lockdown face is a fact.*?>= 20000\) \{.*?\n\t\t\t\})/s;
ok($beat, 'the lockdown block is found in the beat');
like($beat, qr/if \(!defined \$ws_lockdown_state\{\$lockdown_key\} \|\| \$ws_lockdown_state\{\$lockdown_key\} != \$lockdown\)/,
	'the console line is sent when the state changes');
like($beat, qr/\$ws_lockdown_swept\{\$lockdown_key\} = \$server_time;\s*\n\s*eval \{ &subs::lockdown_sweep\(\{ browser_tab_id => \$browser_tab_id \}\) \};/,
	'the backstop sweep runs on a slow cadence');
like($beat, qr/>= 20000/,
	'that cadence is 20 s, not every beat');
like($beat, qr/&subs::lockdown_sweep\(\{ browser_tab_id => \$browser_tab_id, force => 1 \}\)/,
	'a lockdown turning on sweeps at once');
unlike($beat, qr/&Websocket::send\('server', \{[^}]*\}\);\s*\n\s*\}/,
	'the console send is not unconditional');
like($ws_pm, qr/my %ws_lockdown_state;/, 'the worker remembers what it told each tab');
like($ws_pm, qr/my \$lockdown_key = \(\$browser_tab_id \|\| ''\) \. "\\x1f" \. \(\$uuid \|\| ''\);/,
	'the memory is per connection, so a reloaded page is told again');

# --- and everything still compiles ------------------------------------------

my $perl = $^X;
foreach my $file (qw(lib/JawnOS/Controller/manager_ws.pm lib/JawnOS/Domain/Embedded.pm lib/JawnOS/Controller/manager_misc13.pm lib/JawnOS/Domain/Loader.pm)) {
	my $out = `$perl -I. -c "$root/$file" 2>&1`;
	my $ok = ($out =~ /syntax OK/) ? 1 : 0;
	ok($ok, "$file compiles") or diag($out);
}

done_testing();
