# tests-for: public/js/manager/studio/06_controls.js templates/studio/song_select.html.ep templates/studio/markup.html.ep
# covers:    New, Open, Save and Configure sit together at the left of the Studio
#            layout bar; Open is a button that raises a dialog listing every
#            saved studio song. The dialog is built from the hidden song select
#            (which the save response still replaces), a row loads its song and
#            closes the sheet, and Close, Escape or a press outside dismisses
#            it. Structure only; the dialog's pixels are not asserted here.

use strict;
use warnings;

use FindBin;
use Test::More;

sub slurp {
	my ($path) = @_;
	open my $fh, '<', $path or die "cannot read $path: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

my $root   = $FindBin::Bin;
$root =~ s{/t$}{};
my $markup = slurp("$root/templates/studio/markup.html.ep");
my $select = slurp("$root/templates/studio/song_select.html.ep");
my $js     = slurp("$root/public/js/manager/studio/06_controls.js");

# --- New, Open, Save and Configure share the left edge ----------------------
like($markup, qr/id="studio_layout_bar"[\s\S]*class="studio_file_buttons"[\s\S]*id="studio_new"[\s\S]*id="studio_open"[\s\S]*id="studio_save"[\s\S]*id="studio_config_toggle"/,
	'the four file controls sit together in the layout bar, Configure last');
like($markup, qr/<img id="studio_open" class="little_thumb hover"/, 'Open is an icon like New and Save, not a text button');
like($markup, qr{id="studio_open"[\s\S]*?src="<%=\s*&subs::icon_for\('/images/decipherable/folder\.png'\)\s*%>"},
	'Open wears the icon set\'s folder, so every set gives it its own artwork');
like($markup, qr/id="studio_open"[^>]*hint="<%=\s*&subs::ui\('Open a saved studio song'\)\s*%>"/,
	'the Open button says what it opens');

my @new  = $markup =~ /id="studio_new"/g;
my @save = $markup =~ /id="studio_save"/g;
is(scalar(@new), 1, 'New appears exactly once in the markup');
is(scalar(@save), 1, 'Save appears exactly once in the markup');
unlike($markup, qr/id="song_controls"[\s\S]*?id="studio_new"/,
	'Configure no longer carries its own New copy');
unlike($markup, qr/id="song_controls"[\s\S]*?id="studio_save"/,
	'Configure no longer carries its own Save copy');
like($markup, qr/id="song_controls"[\s\S]*id="studio_delete"[\s\S]*id="studio_config_close"[\s\S]*id="studio_name"/,
	'Delete, the Configure gear and the name field stay behind');

# --- the Open dialog ---------------------------------------------------------
like($markup, qr/id="studio_open_dialog"[^>]*class="studio_dialog"[^>]*role="dialog"/,
	'the Open dialog is a dialog');
like($markup, qr/class="studio_dialog_bar"[\s\S]*id="studio_open_close"/,
	'the dialog bar carries its Close button');
like($markup, qr/class="studio_dialog_list"/, 'the dialog has a scrollable list');
like($markup, qr/class="studio_open_row hover" data-uuid="<%=\s*\$song->\{'uuid'\}\s*%>"/,
	'a row is rendered for every saved song and names its uuid');
like($markup, qr/class="studio_open_name"[\s\S]*class="studio_open_time time"/,
	'a row shows the song name and its time');

# The select the save response replaces stays in the DOM, hidden inside the
# closed Configure panel, so no route learns a new shape.
like($markup, qr/id="studio_song_select_holder"[^>]*style="display:none;"[\s\S]*?include 'studio\/song_select'/,
	'the song select lives in a hidden holder');
like($select, qr/id="studio_song_select"/, 'the select keeps its id for save and load');

# --- the select's options carry what the dialog needs -----------------------
like($select, qr/<option value="<%=\s*\$song->\{'uuid'\}\s*%>" data-app="<%=\s*&subs::format_name\(\$song->\{'app'\}\)\s*%>" data-timestamp="<%=\s*\$song->\{'timestamp'\}\s*%>"/,
	'each song option carries its app name and timestamp');
like($select, qr/<option value="none">None<\/option>/, 'the None row is unchanged');

# --- the handlers ------------------------------------------------------------
like($js, qr/\$\(document\)\.on\('click', '#studio_open', function/, 'the Open button raises the dialog');
like($js, qr/\$\(document\)\.on\('click', '#studio_open_close'/, 'the Close button dismisses it');
like($js, qr/\$\(document\)\.on\('click', '#studio_open_dialog \.studio_open_row'/, 'a row press is wired');
like($js, qr/'#studio_open_dialog \.studio_open_row'[\s\S]*?var uuid = \$\(this\)\.attr\('data-uuid'\);[\s\S]*?studioOpenDialogHide\(\);[\s\S]*?studioLoad\(uuid\);/,
	'a row press closes the sheet then loads the song');
like($js, qr/keydown[\s\S]*?e\.key == 'Escape'[\s\S]*?studioOpenDialogHide\(\)/,
	'Escape dismisses the dialog');
like($js, qr/'pointerdown'[\s\S]*?closest\('#studio_open_dialog, #studio_open'\)[\s\S]*?studioOpenDialogHide\(\)/,
	'a press outside the dialog dismisses it');
like($js, qr/function studioOpenDialogShow\(\)[\s\S]*?\.focus\(\)/,
	'opening the dialog gives the keyboard a starting point');

# --- rows are rebuilt from the hidden select ---------------------------------
like($js, qr/function studioOpenDialogRows\(\)[\s\S]*?\$\('#studio_song_select'\)\.find\('option'\)/,
	'the rows are rebuilt from the select every time the dialog opens');
like($js, qr/uuid == 'none'/, 'the None option never becomes a row');
like($js, qr/\.text\(option\.attr\('data-app'\)/, 'the row name is written with text()');
like($js, qr/\.text\(studioOpenDialogTime\(stamp\)\)/, 'the row time is written with text()');
like($js, qr/function studioOpenDialogTime\(timestamp\)[\s\S]*?fixedTimeString\(ts\)/,
	'the row time uses the house formatter when it is on the page');
like($js, qr/function studioOpenDialogTime\(timestamp\)[\s\S]*?toLocaleString\(\)/,
	'a plain locale string is the fallback');
like($js, qr/function studioOpenDialogShow\(\)[\s\S]*?studioOpenDialogRows\(\)/,
	'showing the dialog refreshes it first');

# --- save and load still share the select ------------------------------------
like($js, qr/on\('change', '#studio_song_select'[\s\S]*?studioLoad\(uuid\)/,
	'the select change handler still loads');
like($js, qr/\$\('#studio_song_select'\)\.replaceWith\(response\.song_select\)/,
	'save still replaces the select in place');
like($js, qr/\$\('#studio_song_select'\)\.val\(response\['uuid'\]\)/,
	'load still marks the loaded song in the select');
like($js, qr/function studioLoad\(uuid\) \{\s*studioOpenDialogHide\(\);/,
	'a load never leaves the dialog open');

done_testing();
