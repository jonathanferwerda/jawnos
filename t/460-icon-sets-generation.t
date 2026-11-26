# tests-for: public/icons/sets/build.js public/icons/sets/*/desktop.svg public/icons/sets/*/network.svg public/icons/sets/*/notifications.svg public/icons/sets/*/power.svg public/icons/sets/*/sound.svg public/icons/sets/*/workspaces.svg public/icons/sets/*/star.svg public/icons/sets/*/face.svg public/icons/sets/*/fingerprint.svg public/icons/sets/*/wallet.svg public/icons/sets/*/routing.svg public/icons/sets/*/sessions.svg public/icons/sets/*/intelligence.svg
# covers:    The last hand-drawn pictures that no set could dress. Each one is
#            reached by its source basename - icon_for/icon_path for a template,
#            or a widget's own img - so build.js routes that basename to a glyph
#            and every one of the sixteen sets writes it in both the light and
#            dark cut. A missing tile is the silent fallback this pins down.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root  = repo_root();
my $build = read_file("$root/public/icons/sets/build.js");

# The basenames that had no generated counterpart, and the glyph each borrows.
# The mappings are semantic, not literal: the network widget's hand-drawn signal
# arcs are the beacon, the workspaces/sessions stacks borrow the layered system
# and the app grid, a face is the person, and a fingerprint stands for the key.
my @generated = (
	{ name => 'desktop',       glyph => 'monitor' },
	{ name => 'network',       glyph => 'beacon' },
	{ name => 'notifications', glyph => 'bell' },
	{ name => 'power',         glyph => 'power' },
	{ name => 'sound',         glyph => 'speaker' },
	{ name => 'workspaces',    glyph => 'system' },
	{ name => 'star',          glyph => 'president' },
	{ name => 'face',          glyph => 'person' },
	{ name => 'fingerprint',   glyph => 'key' },
	{ name => 'wallet',        glyph => 'wallet' },
	{ name => 'routing',       glyph => 'detour' },
	{ name => 'sessions',      glyph => 'apps' },
	{ name => 'intelligence',  glyph => 'intelligence' },
);

opendir(my $sets_dh, "$root/public/icons/sets") or die "cannot read the icon sets: $!";
my @sets = sort grep { $_ ne '.' && $_ ne '..' && -d "$root/public/icons/sets/$_" } readdir($sets_dh);
closedir $sets_dh;
is(scalar(@sets), 32, 'the generator ships sixteen styles in a light and a dark cut');

for my $icon (@generated) {
	my ($name, $glyph) = @{$icon}{qw(name glyph)};

	like($build, qr/'\Q$name\E': '\Q$glyph\E'/,
		"build.js routes $name to the $glyph glyph");
	like($build, qr/^\t\Q$glyph\E: '/m,
		"the generator carries the $glyph glyph $name borrows");

	for my $set (@sets) {
		my $file = "$root/public/icons/sets/$set/$name.svg";
		ok(-s $file, "$set draws $name");
	}

	my $sample = "$root/public/icons/sets/cartoon/$name.svg";
	if (-s $sample) {
		like(read_file($sample), qr/<svg /, "the generated $name is an svg");
	}
}

# The two cuts sit side by side for every style, so a name present in both is
# what lets a dark desktop wear the same picture as a light one.
for my $set (@sets) {
	next unless $set =~ /^(.*)_dark$/;
	my $light = $1;
	ok(-d "$root/public/icons/sets/$light", "$light has a matching dark cut");
}

done_testing();
