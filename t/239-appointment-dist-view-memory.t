# tests-for: lib/JawnOS/Controller/manager_misc7.pm templates/appointment_details.html.ep public/js/manager/manager/06_appointment_distance.js perl/help/topics_features.pl
# covers:    The Dist section's picker remembers for the house whether the fixes list or a basemap was chosen, and falls back to the list when a remembered basemap is no longer offered.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $pm   = read_file("$root/lib/JawnOS/Controller/manager_misc7.pm");
my $tpl  = read_file("$root/templates/appointment_details.html.ep");
my $js   = read_file("$root/public/js/manager/manager/06_appointment_distance.js");

# --- the answer belongs to the house, not to one browser --------------------
like($pm, qr/setting_grabber\(\{ app => '__president', setting => 'appointment_dist_view', device => 'all' \}\)/,
	'the details controller reads the house-wide Dist view');
like($pm, qr/\|\| 'fixes';/,
	'an unset view opens on the fixes list');
like($pm, qr/dist_view => \$dist_view,/, 'the controller hands the view to the template');
like($tpl, qr/<select class="appointment_dist_view"[^\n]*data-view="<%= \$dist_view %>">/,
	'the picker carries the remembered view');

# --- the picker restores that view, and keeps it on a change ----------------
like($js, qr/var saved = sel\.attr\('data-view'\) \|\| 'fixes';/,
	'opening a panel reads the view from the template');
like($js, qr/appointmentDistViewRestore\(sel\);/, 'the picker is restored after its basemaps are offered');
like($js, qr/sel\.find\('option'\)\.each\(.*?found = true/s,
	'restoring checks the option is actually offered');
like($js, qr/sel\.val\(found \? saved : 'fixes'\)/,
	'a basemap whose key was removed falls back to the fixes list');
like($js, qr/var kind = \$\(this\)\.val\(\) \|\| 'fixes';/,
	'picking a view takes the picker\'s value');
like($js, qr/\$\('\.appointment_dist_view'\)\.attr\('data-view', kind\);/,
	'every Dist panel already on the page follows the pick');
like($js, qr/settingSetter\(\{ app: '__president', setting: 'appointment_dist_view', device: 'all', value: kind \}\)/,
	'picking a view writes the house setting');
unlike($js, qr/appointmentDistViewMemory/, 'the view is not kept in one browser any more');

# --- the guide says the choice is kept --------------------------------------
my $help = read_file("$root/perl/help/topics_features.pl");
like($help, qr/The view picked there - the list of fixes, or one of the basemaps - is remembered for the house/,
	'the navigation topic says the Dist view is remembered for the house');

done_testing();
