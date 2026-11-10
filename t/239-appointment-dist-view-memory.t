# tests-for: lib/JawnOS/Controller/manager_misc7.pm templates/appointment_details.html.ep public/js/manager/manager/06_appointment_distance.js public/js/manager/manager/10_appointment_edit.js perl/help/topics_features.pl
# covers:    Each app remembers its own appointment-details layout: the Dist view, and whether the Dist, Measures and Duties sections were left open.

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

# --- the answer belongs to the app, not to the house or one browser ---------
like($pm, qr/foreach my \$name \(qw\(dist_view distance_open measures_open duties_open\)\)/,
	'the controller reads the four layout answers');
like($pm, qr/setting_grabber\(\{ app => \$app, setting => 'appointment_' \. \$name, device => 'all' \}\)/,
	'each is read for this appointment app');
like($pm, qr/setting_grabber\(\{ app => '__president', setting => 'appointment_' \. \$name, device => 'all' \}\)/,
	'a first-build house value is the fallback until the app is changed');
like($pm, qr/my \$dist_view = \$detail_setting\{'dist_view'\} \|\| 'fixes';/,
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
like($js, qr/var app = \$\(this\)\.attr\('app'\);/, 'the pick knows which app it belongs to');
like($js, qr/if \(\$\(this\)\.attr\('app'\) === app\) \{ \$\(this\)\.attr\('data-view', kind\); \}/,
	'every Dist panel of that app already on the page follows the pick');
like($js, qr/settingSetter\(\{ app: app, setting: 'appointment_dist_view', device: 'all', value: kind \}\)/,
	'picking a view writes the app setting');
unlike($js, qr/appointmentDistViewMemory/, 'the view is not kept in one browser');

# --- Dist, Measures and Duties remember whether they were left open ---------
like($pm, qr/my \$distance_open = \(\$detail_setting\{'distance_open'\} \|\| ''\) eq 'on' \? 1 : 0;/,
	'the Dist section defaults to closed');
like($pm, qr/my \$measures_open = \(\$detail_setting\{'measures_open'\} \|\| ''\) eq 'on' \? 1 : 0;/,
	'the Measures section defaults to closed');
like($pm, qr/my \$duties_open = \(\$detail_setting\{'duties_open'\} \|\| ''\) eq 'on' \? 1 : 0;/,
	'the Duties section defaults to closed');
like($pm, qr/distance_open => \$distance_open,/, 'the Dist state reaches the template');
like($pm, qr/measures_open => \$measures_open,/, 'the Measures state reaches the template');
like($pm, qr/duties_open => \$duties_open,/, 'the Duties state reaches the template');
like($tpl, qr/class="appointment_list appointment_distance_panel" list="distance" style="<%= \$distance_open \? '' : 'display:none;' %>"/,
	'a remembered Dist section is rendered open');
like($tpl, qr/class="appointment_list" list="measures" style="<%= \$measures_open \? '' : 'display:none;' %>"/,
	'a remembered Measures section is rendered open');
like($tpl, qr/class="appointment_list" list="duties" style="<%= \$duties_open \? '' : 'display:none;' %>"/,
	'a remembered Duties section is rendered open');
like($js, qr/var app = detail\.attr\('app'\);/, 'a toggle knows which app it belongs to');
like($js, qr/if \(list == 'distance' \|\| list == 'measures' \|\| list == 'duties'\) \{/,
	'Dist, Measures and Duties are kept');
like($js, qr/setting: 'appointment_' \+ list \+ '_open'/, 'the toggle writes the matching app setting');
like($js, qr/settingSetter\(\{ app: app, setting: 'appointment_' \+ list \+ '_open', device: 'all', value: open \? 'on' : 'off' \}\)/,
	'and writes the state the toggle moved to');
like($js, qr/function appointmentDistOpen\(\)/, 'an open Dist section has a restore sweep');
like($js, qr/\$\('\.appointment_distance_panel:visible'\)\.each/, 'the sweep only draws a visible panel');
like($js, qr/new MutationObserver\(.*?appointmentDistOpen\(\)/s, 'a new detail begins the sweep');
like($edit_js, qr/if \(list_name == 'distance' \|\| list_name == 'measures' \|\| list_name == 'duties'\) \{ return; \}/,
	'a detail refresh leaves the app state to the server render');

# --- the guide says the choice is kept --------------------------------------
my $help = read_file("$root/perl/help/topics_features.pl");
like($help, qr/The view picked there - the list of fixes, or one of the basemaps - is remembered for that app/,
	'the navigation topic says the Dist view is remembered for the app');
like($help, qr/The Dist, Measures and Duties sections themselves also come back open or closed/,
	'and that all three sections remember whether they were left open');

done_testing();
