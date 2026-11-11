# tests-for: lib/JawnOS/Controller/manager_folders2.pm lib/JawnOS/Controller/manager_folders.pm templates/folders/folders.html.ep public/js/manager/folders.js public/js/manager/folders/02_archive_and_keyboard.js public/js/manager/desk.js public/css/manager.css perl/help/topics_apps.pl perl/language.pl
# covers:    Folders on a thin window, CloudSync drawn in the listing, and the Sync queue.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::Template;
use RepoSource;
use JawnOSTest;

# These are the UI rules the Folders app now follows: Places is automatic on a
# wide window and an overlay behind the toolbar button on a thin one; CloudSync
# is a place in the listing rather than a dialog; and the Archive control is the
# Sync drawer that shows archive and CloudSync jobs together.

my $root      = repo_root();
my $controller = read_file("$root/lib/JawnOS/Controller/manager_folders2.pm");
my $listing_controller = read_file("$root/lib/JawnOS/Controller/manager_folders.pm");
my $template  = template_source('folders/folders');
my $js        = js_source('public/js/manager/folders.js');
my $desk_js   = read_file("$root/public/js/manager/desk.js");
my $css       = read_file("$root/public/css/manager.css");
my $help      = help_source();
my $language  = language_source();

# ---- Places on a thin window ------------------------------------------------

like($js, qr/root\.width\(\) >= 720/, 'the sidebar decision still uses the 176px break at 720px');
like($js, qr/localStorage\.getItem\('folders_sidebar'\)/, 'the Places preference is still remembered');
like($js, qr/folders_sidebar_toggle'\)\.toggle\(!wide\)/,
	'the toolbar button shows on a thin window, not a wide one');
like($js, qr/folders_sidebar_overlay/, 'a thin window opens Places as an overlay class');
my ($sidebar_toggle) = $js =~ /(\$\(document\)\.on\('click', '#folders_sidebar_toggle'.*?\n\}\);)/s;
ok(defined $sidebar_toggle, 'the Places button handler is readable');
like($sidebar_toggle, qr/\.folders_sidebar'\)\.is\(':visible'\)/,
	'the button toggles from the column\'s current visibility');
unlike($sidebar_toggle, qr/pref == 'off'/,
	'it does not read the stored preference, so a fresh thin window opens on the first press');
like($sidebar_toggle, qr/visible \? 'off' : 'on'/,
	'and stores the opposite of what is on screen');
like($js, qr/function foldersSidebarClose/, 'choosing a place puts the overlay away');
like($css, qr/\.folders_app\.folders_sidebar_overlay \.folders_sidebar \{[^}]*position:\s*absolute[^}]*z-index:\s*30/s,
	'the overlay is positioned above the listing');

# ---- CloudSync is a place, not a dialog -------------------------------------

my ($cloud_action) = $controller =~ /(sub action_30702 \{.*?^\})/ms;
ok(defined $cloud_action, 'action_30702 is readable');
like($cloud_action, qr/template => 'folders\/folders'/, 'the CloudSync answer renders the Folders page');
like($cloud_action, qr/place => \$place/, 'and names the place it is showing');
like($cloud_action, qr/html => \$html/, 'the listing receives html, not a dialog wrapper');
unlike($cloud_action, qr/dialog =>/, 'the old dialog wrapper is gone from GET /manager/folders/cloud');

like($template, qr/folders_cloud_open/, 'Places still carries the CloudSync row');
like($template, qr/place="cloud"/, 'the page marks the CloudSync place');
like($template, qr/include 'folders\/cloud_list'/, 'the watched folders are drawn in the listing pane');
like($template, qr/folders_place_view/, 'the listing switches to the place layout');
like($css, qr/folders_place_view/, 'and the CSS gives that layout its own rule');
like($template, qr/aria-current="page"/, 'the breadcrumb names CloudSync as the current place');

my ($cloud_js) = $js =~ /(function foldersCloudList\(root\) \{.*?^\})/ms;
ok(defined $cloud_js, 'foldersCloudList renders the place');
like($cloud_js, qr/windowMaker\(response\.html\)/, 'it draws the response in the window');
unlike($cloud_js, qr/response\.dialog/, 'it does not append a dialog');
like($js, qr/folders_cloud_now/, 'Sync now stays available in the place');
like($js, qr/folders_cloud_stop/, 'and so does Stop');

# ---- Archive is now Sync ----------------------------------------------------

like($template, qr/id="folders_archive_toggle"/, 'the toolbar keeps the same control');
like($template, qr/folders_archive_toggle[^>]*hint="<%= &subs::lang\('folders\.sync'\) %>"/,
	'its hint is the Sync core label');
unlike($template, qr/Archive queue/, 'the old Archive queue wording is gone');
like($template, qr/aria-label="<%= &subs::lang\('folders\.sync'\) %>"/,
	'its accessible label is Sync too');

my ($sync_labels) = $language =~ /my %folders_sync_labels = \((.*?)\n\);/ms;
ok(defined $sync_labels, 'the Sync label has a catalog block');
my @codes = $sync_labels =~ /^\s*(\w+) => \[/mg;
is(scalar @codes, 16, 'the Sync core label is written in all sixteen languages');
like($language, qr/folders\.sync/, 'the key is registered for the Folders app');

like($js, qr/foldersArchiveT\('All sync jobs'\)/, 'the queue summary speaks of sync jobs');
like($js, qr/foldersArchiveT\('Nothing is queued to sync\.'\)/, 'and the empty queue does too');
like($js, qr/job\['task'\] == 'cloud_sync'/, 'a CloudSync job gets its own queue line');
like($js, qr/foldersArchiveBar/, 'the queue keeps the byte progress bar');
like($js, qr/function foldersJobWatcher/, 'and the job watcher still updates progress');
like($controller, qr/'archive_fetch_home', 'cloud_sync'/,
	'action_30392 lists CloudSync jobs beside archive jobs');

# ---- the page compiles with the keys its routes pass ------------------------
#
# Mojo::Template declares exactly the stash keys it is handed and compiles the
# template under strict, so a page that reads a key its route does not pass is
# not a blank row: it is a 500 on that whole route. The listing route passed
# neither `place` nor `cloud_rows` (only the CloudSync route did), and every
# Folders window answered 500 until that was noticed by hand. A default like
# `my $place = $place // ''` cannot rescue it: the name it reads is the one it
# is declaring, so it is the same compile error.
my @page_renders;
foreach my $source ($controller, $listing_controller) {
	while ($source =~ /render_to_string\((.*?)\n\t\);/gs) {
		my $call = $1;
		push @page_renders, $call if $call =~ /template\s*=>\s*'folders\/folders'/;
	}
}
is(scalar @page_renders, 2, 'the Folders page is rendered from both routes');
for my $call (@page_renders) {
	like($call, qr/place\s*=>/, 'every Folders render passes place');
	like($call, qr/cloud_rows\s*=>/, 'every Folders render passes cloud_rows');
}

# Render the real page with the stash those routes build. The database calls in
# the page fail in this sandbox and stop the render partway, so what is asserted
# is the compile: the strict error (or an aborted template) is the failure this
# test exists to catch, and the markup above the first query proves the render
# started.
my $render_count = 0;
my $stub_c = bless {}, 'FoldersRenderStub';
sub FoldersRenderStub::stash { return undef }
my $read_template = sub { read_file("$root/templates/$_[0].html.ep") };
my $render_page = sub {
	my (%stash) = @_;
	my $namespace = 'FoldersRender' . ++$render_count;
	my $mt = Mojo::Template->new(vars => 1, namespace => $namespace);
	no strict 'refs';
	no warnings 'redefine';
	*{"${namespace}::include"} = sub {
		my ($name, @pairs) = @_;
		return '' unless $name =~ m{^folders/};
		my $src = $read_template->($name);
		return $mt->render($src, { @pairs, c => $stub_c });
	};
	my $src = $read_template->('folders/folders');
	return $mt->render($src, \%stash);
};
my %page = (
	fo => { folder => '', display_folder => '', display_name => 'Folders', files => [], disk => {} },
	folder => '',
	folders_id => 'f0123456789a',
	tab_id => 't0123456789a',
	unlocked => 0,
	unlock => '',
	machines => [],
	remote_uuid => '',
	settings => {},
	c => $stub_c
);
my $compile_bad = qr/requires explicit package name|Execution of template aborted|syntax error at template/;
my %shapes = (
	'the listing, as its route renders it' => [ place => '', cloud_rows => [] ],
	'the CloudSync place, as its route renders it' => [
		place => { name => 'CloudSync', home => '/home/test', folder => '', folder_name => '' },
		cloud_rows => []
	],
);
foreach my $label (sort keys %shapes) {
	my $out = $render_page->(%page, @{ $shapes{$label} });
	unlike($out, $compile_bad, "$label compiles with the keys the route passes");
}


# ---- the CloudSync status badge on an icon ---------------------------------

like($template, qr/folders_sync_badge/, 'an item in a watched folder wears a sync badge');
like($template, qr/folders_sync_<%= \$f->\{'sync_status'\} %>/, 'named for the status the listing passed');
like($template, qr/'Synced' : .*?eq 'failed' \? 'Sync failed' : 'Syncing'/, 'and labelled Synced, Sync failed or Syncing');
like($css, qr/\.folders_thumb \.folders_sync_badge \{[^}]*position:\s*absolute[^}]*right:\s*-4px;\s*bottom:\s*-4px;/s,
	'the badge sits in the icon\'s lower-right corner');
like($css, qr/\.folders_thumb \.folders_sync_badge \{[^}]*background:\s*#2e9e4f/s, 'synced is a green badge');
like($css, qr/folders_sync_syncing \{[^}]*background:\s*#2f6feb;[^}]*animation:/s,
	'syncing is a blue badge that turns');
like($css, qr/folders_sync_failed \{[^}]*background:\s*#d33a2c/s, 'failed is a red badge');
like($css, qr/content: '\\2713'/, 'a check for synced');
like($css, qr/content: '\\21BB'/, 'a turning arrow for syncing');
like($css, qr/content: '\\2715'/, 'a cross for failed');
like($css, qr/\@keyframes folders_sync_turn/, 'the turning mark has its own keyframes');
like($css, qr/prefers-reduced-motion[^}]*folders_sync_syncing/s, 'and stops turning for a person who asked for less motion');
like($css, qr/\.folders_thumb \.folders_archived_badge \{ left:\s*-3px; right:\s*auto; \}/,
	'the archive mark moves to the lower left so both can show');
like($desk_js, qr/folders_sync_badge/, 'the desk wears the same badge');
like($desk_js, qr/jawnosT\('Synced'\)/, 'in the same words, ready for translation');
like($help, qr/green check when every chosen device has it/, 'the help explains the green check');
like($help, qr/blue turning mark while a change is still on its way/, 'the blue mark');
like($help, qr/red cross when a device refused the last copy/, 'and the red cross');

# ---- only a folder inside home can sync -------------------------------------

like($controller, qr/Only a folder inside your home can sync\./,
	'an empty base says only a folder inside home can sync');

# ---- help keeps the on-screen words ----------------------------------------

like($help, qr/Sidebar button on the toolbar/, 'the help explains the thin-window Places button');
like($help, qr/Sync button on the toolbar/, 'the help names the Sync drawer');
like($help, qr/CloudSync row at the foot of Places opens the watch list/,
	'the help puts the CloudSync list in the listing');
like($help, qr/only a folder inside your home can sync/, 'and states the home rule');

done_testing();
