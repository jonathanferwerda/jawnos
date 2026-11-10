# tests-for: lib/JawnOS/Domain/Log.pm templates/appointment_details.html.ep perl/help/topics_features.pl
# covers:    The details panel names the window it is reading: the moment its
#            view began and the moment it ended, as two .time stamps at the top
#            of the panel.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $log = read_file("$root/lib/JawnOS/Domain/Log.pm");
my $details = read_file("$root/templates/appointment_details.html.ep");
my $help = read_file("$root/perl/help/topics_features.pl");

# --- the reader says which window the details cover -------------------------
like($log, qr/my \$t2 = \(\$t1 \+ \$timestamp\);\s*\n\s*# the panel's own header says which window it is reading\s*\n\s*\$appts->\{'__specs'\}->\{'view_start'\} = \$t;\s*\n\s*\$appts->\{'__specs'\}->\{'view_end'\} = \$t2;/,
	'the appointment_details branch hands the view start and end to the panel');

# --- the panel wears them at the top, in the house's time reading -----------
like($details, qr/class="detail_view_range"/,
	'the panel has a view-range line');
like($details, qr/<span class="time" timestamp="<%= \$appts->\{'__specs'\}->\{'view_start'\} %>"><\/span>/,
	'the start is a time stamp');
like($details, qr/<span class="time" timestamp="<%= \$appts->\{'__specs'\}->\{'view_end'\} %>"><\/span>/,
	'the end is a time stamp too');
like($details, qr/&subs::ui\('View began'\)[\s\S]*?&subs::ui\('and ended'\)/,
	'the line says plainly that the view began and ended');

# --- the guide says so ------------------------------------------------------
like($help, qr/Above the rows, the panel says when the view it is reading began and ended/,
	'the appointment-windows topic names the view range');

done_testing();
