use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The magazine Editor was a rack of placeholder buttons you had to prime before
# dragging anything onto it, its surface stopped short of the window's right
# edge, and the article's HTML reached the public homepage raw. These are the
# roads that replaced that.

my $root = repo_root();
my $js = read_file("$root/public/js/manager/editor.js");
my $pm = read_file("$root/lib/JawnOS/Manager/Part08.pm");
my $save = read_file("$root/lib/JawnOS/Controller/manager_misc2.pm");
my $homepage = read_file("$root/lib/JawnOS/Manager/Part05.pm");
my $template = read_file("$root/templates/editor.html.ep");
my $css = read_file("$root/public/css/manager.css");
my $help = help_source();

# --- the runtime bugs that used to break the open ---------------------------
unlike($js, qr/original_key_position/, 'the undefined key position name is gone');
unlike($js, qr/var timestamp = timestamp;/, 'the timestamp self-assignment is gone');
like($js, qr/localStorage\.getItem\('scope'\) \|\| 'day'/, 'a first open gets a scope');
like($js, qr/var timestamp = Date\.now\(\);/, 'the editor sends a real timestamp');
like($pm, qr/\$scope = 'day' unless/, 'the route defaults an empty scope');
like($pm, qr/\$timestamp = &subs::rightNow\(\) unless/, 'the route defaults a bad timestamp');
like($pm, qr/my \(\$current\) = grep \{/, 'the route finds the selected article');
like($pm, qr/\$current \|\|= \{/, 'a new/empty article gets a complete default row');

# --- the surface fills the window -------------------------------------------
like($css, qr/\.editor_surface \{[^}]*width: 100%/, 'the editor surface fills its window');
like($css, qr/\.editor_content_parent \{[^}]*flex: 1 1 auto/, 'the writing column takes the room');
unlike($css, qr/\.editor_content_parent \{ text-align: center; \}/, 'the old centred, narrow column is gone');

# --- a page you write on, not a rack of adders -------------------------------
like($template, qr/id="editor_content_area"[^>]*contenteditable="true"/,
	'the article body is an editable page');
like($template, qr/id="editor_stored_content"/, 'stored markup is carried as text, not live DOM');
like($template, qr/data-block="<%= \$style->\[0\] %>"/, 'the style buttons act on the current block');
like($template, qr/id="editor_add_text"/, 'there is a plain Add text');
like($template, qr/id="editor_add_media"/, 'there is an Add media');
unlike($template, qr/content_type=/, 'the placeholder adders are gone');
like($js, qr/function editorSetBlockStyle\(/, 'a block is restyled in place');
like($js, qr/function editorAddText\(/, 'a paragraph can be added and typed into');

# --- media is read for what it is -------------------------------------------
like($js, qr/function editorInsertTransfer\(/, 'one path takes anything dropped');
like($js, qr/EDITOR_VIDEO_EXT/, 'a video is recognised from its URL, not declared');
like($js, qr/EDITOR_AUDIO_EXT/, 'a track is recognised from its URL, not declared');
like($js, qr/data\.files/, 'files dropped from the desktop are handled');
like($js, qr/editorNodeFromElement/, 'an element dragged from another window is read');
like($js, qr/editorNodeFromUrl/, 'a dropped URL is read for what it points at');
like($js, qr/'paste'/, 'a pasted picture is picked up');
like($js, qr/editorImageFromFile/, 'a picture file is embedded');

# --- blocks move ------------------------------------------------------------
like($js, qr/id="editor_block_grip"|editor_block_grip/, 'there is a drag grip');
like($js, qr/ArrowUp/, 'a block moves by keyboard too');
like($template, qr/id="editor_block_grip"[^>]*draggable="true"/, 'the grip is the draggable handle');

# --- the article cannot carry script ----------------------------------------
like($save, qr/my \$content = &subs::article_html_clean\(\$c->param\('content'\)\)/,
	'a save runs the article through the allowlist');
like($pm, qr/\$current->\{'content'\} = &subs::article_html_clean/,
	'a stored article is cleaned again on the way out');
like($homepage, qr/\$mc->\{'content'\} = &subs::article_html_clean/,
	'the public homepage draws only what passed the allowlist');

# --- save feedback and the two destructive presses --------------------------
like($js, qr/function editorDirty\(\)/, 'there is a dirty-state writer');
like($js, qr/function editorSaved\(\)/, 'there is a saved-state writer');
like($js, qr/localStorage\.setItem\('editor_saved', '1'\)/, 'a save carries its confirmation across the reload');
like($js, qr/Press again to delete/, 'delete says in its own label that it is armed');
like($js, qr/Press close again to discard/, 'closing with unsaved work asks for a second press');

# --- the help topic describes this app, not the appointment text editor -----
like($help, qr/summary => 'Write and lay out a magazine article/,
	'the help summary names the writing surface');
unlike($help, qr/summary => 'A rich text editor whose variables/, 'the old text-editor summary is gone');

done_testing();
