# tests-for: lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/File.pm lib/JawnOS/Domain/Generate.pm lib/JawnOS/Manager/Declarations.pm lib/JawnOS/Manager/Part21.pm
# covers:    Opening an app used to fork twice for work that was not a render: once for the centre view's template cache wr...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# Opening an app used to fork twice for work that was not a render: once for the
# centre view's template cache write and once for the header's alarm poke on a
# centre-view header read. Both are small and local, so both now run in the
# caller. The header itself stays a plain render/cache/push - the window render
# is the caller's fork - and the source=ws broadcast guard is untouched.

my $root = repo_root();
my $part21 = read_file("$root/lib/JawnOS/Manager/Part21.pm");
my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");

# --- the template cache write is inline -------------------------------------

my ($grabber) = $part21 =~ /(sub centre_view_grabber\(.*?\n\})/s;
ok($grabber, 'centre_view_grabber is still one sub');

like($grabber, qr/my \$template_cached = eval \{ &subs::cache_set\(\{app => \$app, context => 'template'/,
	'the centre view template cache is written inline, keeping the result');
unlike($grabber, qr/subprocessor/,
	'no subprocess is spawned anywhere in centre_view_grabber');
like($grabber, qr/warranty => '-10d'/,
	'the cache entry keeps its warranty');
like($grabber, qr/if \(\$@\) \{\s*eval \{ &subs::log_writer\('centre view cache set failed/,
	'a failed inline write is logged instead of killing the window');

# --- the header is the fast half, with no fork of its own -------------------

my ($header_sub) = $calendar =~ /(sub appt_header_printer \{.*?\n\}\n)/s;
ok($header_sub, 'appt_header_printer is still one sub');
unlike($header_sub, qr/subprocessor/,
	'the header render does not fork; the caller forks the window render instead');
unlike($header_sub, qr/&(?:Manager::)?centre_view_grabber\s*\(/,
	'the header no longer renders the centre view');
like($header_sub, qr/foreach my \$a \( \@\{ \(\$appts->\{\$app\} \|\| \{\}\)->\{'list'\} \|\| \[\] \} \) \{\s*&appt_alarm_setter\(\$a\);/s,
	'the alarm poke runs inline for every caller, walking the rows through appt_alarm_setter');
like($header_sub, qr/&subs::cache_set\(\{ app => \$app, context => 'header'/, 'the header is cached');
like($header_sub, qr/Websocket::send\('tab', \{ type => 'header'/, 'the header is pushed');

# --- the source=ws suppression is exactly as it was ------------------------

like($calendar, qr/unless \(\(\$data->\{'broadcast'\} \/\/ ''\) eq 'no' \|\| \(\$data->\{'source'\} \/\/ ''\) eq 'ws'\)/,
	'a source=ws header still does not broadcast');
like($calendar, qr/unless \(\(\$data->\{'broadcast'\}.*?Websocket::send\('tab', \{ type => 'header'/s,
	'the header send still sits inside the silent guard');

done_testing();
