# tests-for: templates/ime.html.ep public/css/soft_keyboard.css
# covers:    the IME page's dock must not add env(safe-area-inset-bottom). Android
#           wraps the input-method window and owns the navigation-bar strip, so
#           the shared .soft_kb inset counts that strip twice and leaves a blank
#           band below the space bar when the system bars are shown.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $ime  = scalar read_file("$root/templates/ime.html.ep");
my $css  = scalar read_file("$root/public/css/soft_keyboard.css");

# --- the IME page's own override -------------------------------------------
my ($style) = $ime =~ m{<style>(.*?)</style>}s;
ok(defined $style, 'templates/ime.html.ep has its own <style> block');

# The page may name the dock on its own or in a selector list; take the rule
# body so whitespace and declaration order do not matter.
my ($dock_rule) = ($style || '') =~ m!#jawn_soft_keyboard[^{}]*\{([^}]*)\}!s;
ok(defined $dock_rule, 'the page style targets #jawn_soft_keyboard');

unlike($dock_rule || '', qr/env\(\s*safe-area-inset-bottom/i,
	'the IME dock does not add the navigation-bar safe-area inset');

# Accept the shorthand `6px 8px 8px` or a longhand `padding-bottom: 8px`.
sub bottom_pad {
	my ($block) = @_;
	return $1 if $block =~ /(?:^|;)\s*padding-bottom\s*:\s*([^;]+);/i;
	return undef unless $block =~ /(?:^|;)\s*padding\s*:\s*([^;]+);/i;
	my @values = split(/\s+/, $1);
	return $values[-1];
}

is(bottom_pad($dock_rule || ''), '8px',
	'the IME dock keeps a plain 8px bottom pad');

# --- the shared on-page dock is unchanged ----------------------------------
like($css, qr/\.soft_kb\s*\{[^}]*env\(\s*safe-area-inset-bottom/s,
	'the manager dock still pads for the safe area');

done_testing();
