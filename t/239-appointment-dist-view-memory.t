# tests-for: lib/JawnOS/Controller/manager_misc7.pm templates/appointment_details.html.ep public/js/manager/manager/06_appointment_distance.js public/js/manager/manager/10_appointment_edit.js perl/help/topics_features.pl
# covers:    The Dist section's picker remembers for the house whether the fixes list or a basemap was chosen, and the Dist and Measures sections remember whether they were left open.

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
my $edit_js = read_file("$root/public/js/manager/manager/10_appointment_edit.js");

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

# --- Dist and Measures remember whether they were left open ----------------
like($pm, qr/setting => 'appointment_distance_open', device => 'all'/, 'the controller reads the Dist open state');
like($pm, qr/setting => 'appointment_measures_open', device => 'all'/, 'and the Measures open state');
like($pm, qr/my \$distance_open = .*? eq 'on' \? 1 : 0;/, 'the Dist section defaults to closed');
like($pm, qr/my \$measures_open = .*? eq 'on' \? 1 : 0;/, 'the Measures section defaults to closed');
like($pm, qr/distance_open => \$distance_open,/, 'the Dist state reaches the template');
like($pm, qr/measures_open => \$measures_open,/, 'the Measures state reaches the template');
like($tpl, qr/class="appointment_list appointment_distance_panel" list="distance" style="<%= \$distance_open \? '' : 'display:none;' %>"/,
	'a remembered Dist section is rendered open');
like($tpl, qr/class="appointment_list" list="measures" style="<%= \$measures_open \? '' : 'display:none;' %>"/,
	'a remembered Measures section is rendered open');
like($js, qr/if \(list == 'distance' \|\| list == 'measures'\) \{/, 'only Dist and Measures are kept');
like($js, qr/setting: 'appointment_' \+ list \+ '_open'/, 'the toggle writes the matching house setting');
like($js, qr/value: open \? 'on' : 'off'/, 'and writes the state the toggle moved to');
like($js, qr/function appointmentDistOpen\(\)/, 'an open Dist section has a restore sweep');
like($js, qr/\$\('\.appointment_distance_panel:visible'\)\.each/, 'the sweep only draws a visible panel');
like($js, qr/new MutationObserver\(.*?appointmentDistOpen\(\)/s, 'a new detail begins the sweep');
like($edit_js, qr/if \(list_name == 'distance' \|\| list_name == 'measures'\) \{ return; \}/,
	'a detail refresh leaves the house state to the server render');

# --- the guide says the choice is kept --------------------------------------
my $help = read_file("$root/perl/help/topics_features.pl");
like($help, qr/The view picked there - the list of fixes, or one of the basemaps - is remembered for the house/,
	'the navigation topic says the Dist view is remembered for the house');
like($help, qr/The Dist and Measures sections themselves also come back open or closed/,
	'and that both sections remember whether they were left open');

done_testing();
