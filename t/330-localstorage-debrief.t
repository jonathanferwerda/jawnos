# tests-for: public/js/gate.js public/js/manager/stored.js public/js/manager/websocket.js templates/configure/system_setting_list.html.ep lib/JawnOS/Domain/Key.pm
# covers:    A debrief snapshot once carried bare numeric keys (a string
#            iterated as indices, one character each). The gate seeded them
#            into every browser, the Sys panel drew a table row for each of
#            198k, and the renderer pinned a core opening Sys. The snapshot no
#            longer seeds or saves numeric keys, the live store drops them once,
#            the Sys table draws a bounded sample, and the ticket store drops
#            them on the way in.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $gate = read_file("$root/public/js/gate.js");
my $stored = read_file("$root/public/js/manager/stored.js");
my $ws = read_file("$root/public/js/manager/websocket.js");
my $tpl = read_file("$root/templates/configure/system_setting_list.html.ep");
my $key = read_file("$root/lib/JawnOS/Domain/Key.pm");

# --- the gate never seeds a bare index --------------------------------------
like($gate, qr/if \(\/\^\\d\+\$\/\.test\(i\)\) \{ return; \}/,
	'the gate skips a numeric key from the ticket snapshot');
like($gate, qr/localStorage\.getItem\(i\) === null/,
	'and still seeds the named keys it does carry');

# --- the live store heals once ---------------------------------------------
like($stored, qr/else if \(\/\^\\d\+\$\/\.test\(key\)\)/,
	'the fold recognises a numeric key');
like($stored, qr/if \(!source\) \{ try \{ localStorage\.removeItem\(key\); \}/,
	'and drops it from the live store');
like($stored, qr/jawnosStoreFold\(null\);/,
	'which runs on every load');

# --- a saved snapshot carries no bare indices ------------------------------
like($ws, qr/function debriefSnapshot\(\)/,
	'the debrief builds its own snapshot');
like($ws, qr/\^\\d\+\$\/\.test\(key\)/,
	'skipping numeric keys');
like($ws, qr/var d = debriefSnapshot\(\);/,
	'and saves that instead of the whole store');

# --- the Sys table draws a bounded sample ----------------------------------
like($tpl, qr/my \$ls_limit = 500;/,
	'the localStorage table has a row limit');
like($tpl, qr/splice\(\@ls_keys, \$ls_limit\) if \@ls_keys > \$ls_limit;/,
	'and truncates the sorted key list to it');
like($tpl, qr/foreach my \$ls \( \@ls_keys \)/,
	'the table walks only that sample');
like($tpl, qr/Showing the first \{0\} of \{1\} stored keys\./,
	'and says how many were left out');

# --- the ticket store drops the garbage on the way in ----------------------
like($key, qr/my \@drop = grep \{ \/\^\\d\+\$\/ \} keys %\{\$d\};/,
	'debrief_store drops numeric keys');
like($key, qr/if \(\@keys > 5000\) \{/,
	'and caps a snapshot that is absurdly wide');

done_testing();
