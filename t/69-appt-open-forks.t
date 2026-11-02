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
# caller. The render after the alarm poke still gets its own process, and the
# source=ws broadcast guard is untouched.

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

# --- the header alarm poke runs inline on the grabber path ------------------

my ($grabber_branch) = $calendar =~ /if \(\(\$data->\{'source'\} \/\/ ''\) eq 'centre_view_grabber'\) \{(.*?)\} else \{/s;
ok($grabber_branch, 'appt_header_printer has a centre_view_grabber branch and another caller branch');
unlike($grabber_branch, qr/subprocessor/,
	'a centre_view_grabber header does not fork for its alarms');
like($grabber_branch, qr/\$alarm_run->\(\);/,
	'the centre_view_grabber header runs the alarm poke inline');
like($calendar, qr/my \$alarm_run = sub \{\s*my \$list = .*?&appt_alarm_setter\(\$a\);/s,
	'the inline path still walks the rows through appt_alarm_setter');

# --- other callers keep their worker (it renders the centre view) ----------

like($calendar, qr/\} else \{\s*&subs::subprocessor\(sub \{\s*Mojo::IOLoop->reset;\s*\$alarm_run->\(\);.*?&Manager::centre_view_grabber\(.*?name => 'header worker'/s,
	'the other callers still fork a header worker that renders the centre view');

# --- the source=ws suppression is exactly as it was ------------------------

like($calendar, qr/unless \(\(\$data->\{'broadcast'\} \/\/ ''\) eq 'no' \|\| \(\$data->\{'source'\} \/\/ ''\) eq 'ws'\)/,
	'a source=ws header still does not broadcast');
like($calendar, qr/unless \(\(\$data->\{'broadcast'\}.*?Websocket::send\('tab', \{ type => 'header'/s,
	'the header send still sits inside the silent guard');

done_testing();
