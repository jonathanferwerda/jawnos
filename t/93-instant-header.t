# tests-for: lib/JawnOS/Manager/Part14.pm public/js/manager/manager/06_appointment_distance.js
# covers:    A start or stop replies with its header immediately, and the centre-view render no longer sits in front of it

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A start or stop changes the appointment header. The header frame is pushed to
# every tab at once, but a page whose socket is asleep only ever sees the reset
# reply - and that reply used to wait for a full centre-view render (~40 KB of
# window) even though the caller that pressed start/stop never reads `cv` out of
# it. The window is still redrawn, by the header worker's fork and by
# budget_runner; it just no longer delays the header.
#
# A caller that really does read `response.cv` (the Add press) asks for the
# render with cv=yes, so nothing that used it loses it.

my $root = repo_root();
my $part14 = read_file("$root/lib/JawnOS/Manager/Part14.pm");
my $js     = read_file("$root/public/js/manager/manager/06_appointment_distance.js");

# --- the reply no longer waits for the window --------------------------------

like($part14, qr/if \(\(\$c->param\('cv'\) \/\/ ''\) eq 'yes'\) \{\s*\$cv = &centre_view_grabber\(/,
	'the centre view is rendered synchronously only when the caller asks for cv');
unlike($part14, qr/\n\tmy \$cv = &centre_view_grabber/,
	'no caller pays for the centre view on the way to the header reply');
like($part14, qr/\$returner->\{'cv'\} = \$cv;[\s\S]*?\$returner->\{'header'\} = \$appt_header/,
	'the header reply is filled after (and outside) the optional render');

# --- the media seal walks its files in a fork -------------------------------

like($part14, qr/if \(&subs::setting_grabber\(\{ app => \$app, setting => 'enc' \}\) eq 'on'\) \{\s*my \$suds = &subs::session_suds\(\$c\);[\s\S]*?&subs::subprocessor\(sub \{\s*Mojo::IOLoop->reset;\s*&subs::file_encrypter\(\{ app => \$app, suds => \$suds \}\);\s*\}, \{ name => 'reset file encrypt' \}\)/,
	'sealing an app\'s media is a fork, and the no-op path skips the fork');
unlike($part14, qr/\n\t&subs::file_encrypter\(\{ app => \$app, suds => &subs::session_suds\(\$c\) \}\);/,
	'no synchronous file_encrypter is left in the reply path');

# --- the one caller that reads the window asks for it -----------------------

like($js, qr/type: entry,[^\n]*\bcv: 'yes'/,
	'the Add press asks for the centre view it reads out of response.cv');
like($js, qr/centreViewWriter\(response\.cv\)/,
	'and still consumes that render');

done_testing();
