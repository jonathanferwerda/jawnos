# tests-for: templates/store/ticket_request.html.ep public/js/homepage.js lib/JawnOS/Controller/box_office_misc.pm t/310-applications.t
# covers:    The applicant side of a job request. The public ticket-request form
#            asks what the person is applying for, when they could talk, and
#            what they can show; the role list is offered by name only, because
#            a role's permissions are the house's business and never a
#            stranger's. The submit filters the role keys against the catalog
#            and stores the three answers with the request.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

my $root = repo_root();

my $template = read_file("$root/templates/store/ticket_request.html.ep");
my $homepage = read_file("$root/public/js/homepage.js");
my $controller = read_file("$root/lib/JawnOS/Controller/box_office_misc.pm");

# The action is read on its own: a helper elsewhere in the file must not answer
# for the ticket-request branch.
my ($action) = $controller =~ /(# ANY \/box_office\/ticket_request\nsub action_14132 \{.*?)(?=\n# GET \/box_office\/:uuid)/s;
ok($action, 'the ticket_request action is read on its own');

# --- the public form --------------------------------------------------------
like($template, qr/id="ticket_request_role"/, 'the form has a role select');
like($template, qr/name="roles"[^>]*multiple|multiple[^>]*name="roles"/,
	'and it allows more than one role');
like($template, qr/<option value="<%= \$role->\{'uuid'\} %>"><%= \$role->\{'name'\} %>/,
	'one option per role, by uuid and name');
unlike($template, qr/permissions/i,
	'no permission key or label reaches the public form');
like($template, qr/id="ticket_request_interview"[^>]*maxlength="300"/,
	'the interview field is capped at 300 characters');
like($template, qr/<textarea[^>]*id="ticket_request_trial"[^>]*maxlength="1000"/,
	'the trial field is a capped textarea');
like($template, qr/&subs::ui\('Role applied for'\)/,
	'the role label is translatable');
like($template, qr/&subs::ui\('Interview availability'\)/,
	'the interview label is translatable');
like($template, qr/&subs::ui\('Trial task'\)/, 'the trial label is translatable');

# --- the script -------------------------------------------------------------
like($homepage, qr/var form = \{\};/, 'the payload is a JSON object, not an array');
like($homepage, qr/form\['roles'\]\s*=\s*role_select\.length \? \(role_select\.val\(\) \|\| \[\]\) : \[\]/,
	'it sends the selected roles, or an empty list when the field is absent');
like($homepage, qr/form\['interview'\]\s*=\s*\$\('#ticket_request_interview'\)\.val\(\) \|\| ''/,
	'it sends the interview availability safely');
like($homepage, qr/form\['trial'\]\s*=\s*\$\('#ticket_request_trial'\)\.val\(\) \|\| ''/,
	'it sends the trial task safely');

# --- the controller ---------------------------------------------------------
like($action, qr/roles => \[ map \{ \{ uuid => \$_->\{'uuid'\}, name => \$_->\{'name'\} \} \} \@\{ &subs::role_catalog\(\) \} \]/,
	'the form is given a role list of uuid and name only');
like($action, qr/&subs::role_keys_filter\(&subs::role_catalog\(\), \$data->\{'roles'\}\)/,
	'the submit keeps only the roles the catalog knows');
like($action, qr/\$info->\{'roles'\} = \$roles_applied if scalar \@\{\$roles_applied\}/,
	'known roles are stored on the request');
like($action, qr/\$info->\{'interview'\} = \$interview if length \$interview/,
	'an empty interview answer is left out');
like($action, qr/substr\(\$interview, 0, 300\)/, 'the interview answer is capped at 300');
like($action, qr/\$info->\{'trial'\} = \$trial if length \$trial/,
	'an empty trial answer is left out');
like($action, qr/substr\(\$trial, 0, 1000\)/, 'the trial answer is capped at 1000');

my $filter_at = index($action, 'role_keys_filter');
my $blacklist_at = index($action, 'ticket_blacklist_match');
my $interview_at = index($action, q{my $interview = $data->{'interview'}});
ok($filter_at >= 0 && $interview_at > $filter_at && $blacklist_at > $interview_at,
	'the applicant fields are settled before the blacklist and dedupe checks');

# --- the helper itself ------------------------------------------------------
my $catalog = subs::role_presets();
my $known = $catalog->[0]->{'uuid'};
is_deeply(subs::role_keys_filter($catalog, [$known, 'ghost', $known]), [$known],
	'an unknown or repeated role key is not kept');
is_deeply(subs::role_keys_filter($catalog, qq{["$known"]}), [$known],
	'a JSON list is read as the same keys');
is_deeply(subs::role_keys_filter($catalog, "$known,ghost"), [$known],
	'and a comma list is read too');
is_deeply(subs::role_keys_filter($catalog, undef), [],
	'no answer keeps no roles');

done_testing();
