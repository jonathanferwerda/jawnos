# tests-for: perl/gb/05_abilities_and_studio.pl templates/studio/markup.html.ep public/icons/sets/build.js public/images/studio/pedal_harmonizer.png public/images/studio/pedal_de_esser.png public/images/studio/pedal_modulator.png public/images/studio/pedal_pitch_shift.png public/images/studio/pedal_gate.png public/images/studio/pedal_slider.png public/images/studio/pedal_overdrive.png public/images/studio/pedal_wah.png public/images/studio/pedal_chorus.png public/images/studio/pedal_vibrato.png
# covers:    The ten newer pedals' hand-drawn shelf faces. Each has an artwork
#            asset (`pedal_<name>`, namespaced because `slider` is the UI
#            fader), a 344x408 PNG for the hand-drawn set, a matching generated
#            SVG in all sixteen icon sets and both cuts, a shelf entry whose
#            knobs and selects cover exactly its contract controls, and the
#            template path that renders a shelf tile's choices and Sync field.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $studio = read_file("$root/perl/gb/05_abilities_and_studio.pl");
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $build  = read_file("$root/public/icons/sets/build.js");

my @pedals = (
	{ name => 'harmonizer',  label => 'Harmonizer',  controls => [qw(key scale degree mix)] },
	{ name => 'de_esser',    label => 'De-esser',    controls => [qw(thresh freq amount)] },
	{ name => 'modulator',   label => 'Modulator',   controls => [qw(rate depth mix)], sync => 1 },
	{ name => 'pitch_shift', label => 'Pitch Shift', controls => [qw(semitones mix)] },
	{ name => 'gate',        label => 'Gate',        controls => [qw(thresh attack hold release range)] },
	{ name => 'slider',      label => 'Slider',      controls => [qw(rate depth duty)], sync => 1 },
	{ name => 'overdrive',   label => 'Overdrive',   controls => [qw(drive tone level)] },
	{ name => 'wah',         label => 'Wah',         controls => [qw(rate depth mix)], sync => 1 },
	{ name => 'chorus',      label => 'Chorus',      controls => [qw(rate depth mix)], sync => 1 },
	{ name => 'vibrato',     label => 'Vibrato',     controls => [qw(rate depth)], sync => 1 },
);

# The PNG's IHDR: width and height are big-endian at bytes 16 and 20.
sub png_size {
	my ($path) = @_;
	open my $fh, '<:raw', $path or return;
	read $fh, my $head, 24;
	close $fh;
	return unless defined $head && length($head) == 24 && substr($head, 0, 8) eq "\x89PNG\r\n\x1a\n";
	my ($w, $h) = unpack 'x16 N N', $head;
	return ($w, $h);
}

my ($motif_block) = $build =~ /const PEDAL_MOTIFS = \{(.*?)\n\};/s;
ok(defined $motif_block, 'the generator carries one motif per pedal');

my @sets = grep { -d } glob("$root/public/icons/sets/*");

for my $p (@pedals) {
	my $name = $p->{name};
	my $label = $p->{label};
	my $asset = 'pedal_' . $name;

	# --- the shelf entry ---
	my ($block) = $studio =~ /name => '\Q$name\E',\s*\n\s*image => '\Q$asset\E',(.*?)\n\t\}/s;
	ok(defined $block, "$name joins the artwork shelf as $asset");
	next unless defined $block;
	for my $control (@{ $p->{controls} }) {
		like($block, qr/control => '\Q$control\E'/, "the shelf tile for $name carries $control");
	}
	is(scalar(my @rows = $block =~ /control => '[a-z0-9_]+'/g), scalar(@{ $p->{controls} }),
		"the shelf tile for $name has exactly one row per contract control");
	if ($p->{sync}) {
		like($block, qr/^\t\tsync => 1,/m, "the shelf tile for $name renders a Sync field");
	}
	else {
		unlike($block, qr/^\t\tsync => 1,/m, "the shelf tile for $name has no Sync field");
	}
	# a numeric control is a knob, a choice is a select
	for my $select (qw(key scale degree)) {
		next unless grep { $_ eq $select } @{ $p->{controls} };
		like($block, qr/selects => \[[\s\S]*?control => '\Q$select\E'/,
			"the $select of $name is a dropdown, not a knob");
	}

	# --- the hand-drawn PNG ---
	my $png = "$root/public/images/studio/$asset.png";
	ok(-f $png, "$asset.png is the hand-drawn face");
	if (-f $png) {
		my ($w, $h) = png_size($png);
		is($w, 344, "$asset.png is 344 wide");
		is($h, 408, "$asset.png is 408 tall");
	}

	# --- the generated SVG in every icon set ---
	my @have = grep { -f "$_/$asset.svg" } @sets;
	is(scalar(@have), scalar(@sets), "every icon set draws $asset");
	like($build, qr/'$asset': 'pedal'/, "$asset routes to the pedal renderer");
	like($build, qr/\b$asset: \[344, 408\]/, "$asset keeps the PNG's face ratio");
	like($build, qr/\b$asset: '\Q$label\E'/, "$asset is labelled $p->{label}");
	like($build, qr/\b$asset: \d+/, "$asset has its own hue");
	my $svg = "$root/public/icons/sets/cartoon/$asset.svg";
	like(read_file($svg), qr/>\Q$label\E</, "the generated artwork for $asset letters its name");
	like($motif_block // '', qr/\b\Q$asset\E: '[^']+'/, "$asset has a motif path");
	like(read_file($svg), qr/<path d="[^"]+"/, "the generated face for $asset draws its motif");
	like(read_file($svg), qr/stroke-width="12"/, "the motif of $asset is a marker stroke");
}

# --- the slider asset is not stolen ----------------------------------------
like($build, qr/'slider': 'groove'/, 'the UI fader graphic stays a groove');
unlike($build, qr/'slider': 'pedal'/, 'the Slider pedal does not take the fader name');
ok(-f "$root/public/images/studio/slider.png", 'the fader PNG is still there');

# --- the template renders a shelf tile's choices and tempo field ------------
like($markup, qr/\@\{\$p->\{'selects'\} \|\| \[\]\}/,
	'a shelf tile can carry a list of dropdowns');
like($markup, qr/\$p->\{'sync'\}/, 'and one optional Sync row');
like($markup, qr/class="studio_pedal_model pedal_select"/,
	'a shelf dropdown wears the same classes the drawn tiles use');
like($markup, qr/class="studio_pedal_text pedal_text"/,
	'a shelf Sync field is the same typed control');
like($markup, qr/style="position:absolute;left:<%= \$s->\{'left'\} %>;top:<%= \$s->\{'top'\} %>;width:<%= \$s->\{'width'\} %>;/,
	'the pedals entry places the dropdown on the artwork');
like($markup, qr/studio_tempo_<%= &subs::html_name\(\$ch\) %>_sync/,
	'each synced shelf tile has its own datalist');

done_testing();
