use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The magazine Editor app was broken on open: editorInit read an undefined
# original_key_position, the client sent a self-assigned timestamp, and the
# route died on an empty scope. It also had no save state and no labeled
# controls. These are the roads that replaced that.

my $root = repo_root();
my $js = read_file("$root/public/js/manager/editor.js");
my $pm = read_file("$root/lib/JawnOS/Manager/Part08.pm");
my $template = read_file("$root/templates/editor.html.ep");
my $css = read_file("$root/public/css/manager.css");
my $help = read_file("$root/perl/help.pl");

# --- the runtime bug --------------------------------------------------------
like($js, qr/if \(original_grapple_position == undefined\)/,
	'the grapple position guard uses the variable that exists');
unlike($js, qr/original_key_position/, 'the undefined key position name is gone');
unlike($js, qr/var timestamp = timestamp;/, 'the timestamp self-assignment is gone');
like($js, qr/localStorage\.getItem\('scope'\) \|\| 'day'/, 'a first open gets a scope');
like($js, qr/var timestamp = Date\.now\(\);/, 'the editor sends a real timestamp');

# --- route defaults and the current row -------------------------------------
like($pm, qr/\$scope = 'day' unless/, 'the route defaults an empty scope');
like($pm, qr/\$timestamp = &subs::rightNow\(\) unless/, 'the route defaults a bad timestamp');
like($pm, qr/my \(\$current\) = grep \{/, 'the route finds the selected article');
like($pm, qr/\$current \|\|= \{/, 'a new/empty article gets a complete default row');
like($pm, qr/current => \$current,/, 'the template is handed the selected row');

# --- the template no longer reads an undefined array slot -------------------
like($template, qr/\$current->\{'content'\}/, 'the content comes from the current row');
like($template, qr/id="editor_save_state"/, 'the toolbar has a save-state slot');
like($template, qr/type="button" content_type=/, 'content adders are real buttons');
like($template, qr/aria-label="<%= &subs::ui\('Article'\) %>"/, 'the picker has a label');
like($css, qr/\.editor_toolbar \{/, 'the toolbar has its own layout rules');
like($css, qr/\.editor_save_dirty/, 'the unsaved state has a visible style');

# --- save feedback ----------------------------------------------------------
like($js, qr/function editorDirty\(\)/, 'there is a dirty-state writer');
like($js, qr/function editorSaved\(\)/, 'there is a saved-state writer');
like($js, qr/localStorage\.setItem\('editor_saved', '1'\)/, 'a save carries its confirmation across the reload');
like($js, qr/editorDirty\(\);/, 'edits mark the article unsaved');

# --- the help topic describes this app, not the appointment text editor -----
like($help, qr/summary => 'Lay out a magazine article/, 'the help summary names the magazine editor');
unlike($help, qr/summary => 'A rich text editor whose variables/, 'the old text-editor summary is gone');

done_testing();
