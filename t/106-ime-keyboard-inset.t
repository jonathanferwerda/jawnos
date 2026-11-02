# tests-for: public/css/soft_keyboard.css templates/ime.html.ep
# covers:    the keyboard dock must not add env(safe-area-inset-bottom). The
#           Android view already pads the page by the system bars, and an input
#           method's window is placed above the navigation bar by Android
#           itself; the inset counted that strip twice and left a blank band
#           below the space bar whenever the app showed the system bars.

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

# --- the shared dock: no second safe-area strip ----------------------------
my ($dock_rule) = $css =~ m!\.soft_kb\s*\{([^}]*)\}!s;
ok(defined $dock_rule, 'soft_keyboard.css has the .soft_kb dock rule');

# the rule keeps prose in comments; only the declarations count here
(my $dock_decls = $dock_rule || '') =~ s{/\*.*?\*/}{}gs;

unlike($dock_decls, qr/env\(\s*safe-area-inset-bottom/i,
	'the dock does not add the navigation-bar safe-area inset');

# Accept the shorthand `6px 8px 8px` or a longhand `padding-bottom: 8px`.
sub bottom_pad {
	my ($block) = @_;
	return $1 if $block =~ /(?:^|;)\s*padding-bottom\s*:\s*([^;]+);/i;
	return undef unless $block =~ /(?:^|;)\s*padding\s*:\s*([^;]+);/i;
	my @values = split(/\s+/, $1);
	return $values[-1];
}

is(bottom_pad($dock_decls), '8px',
	'the dock keeps a plain 8px bottom pad');

# --- the IME page reuses the dock and adds no inset of its own -------------
my ($style) = $ime =~ m{<style>(.*?)</style>}s;
ok(defined $style, 'templates/ime.html.ep has its own <style> block');

my ($ime_rule) = ($style || '') =~ m!#jawn_soft_keyboard[^{}]*\{([^}]*)\}!s;
ok(defined $ime_rule, 'the page style targets #jawn_soft_keyboard');

unlike($ime_rule || '', qr/env\(\s*safe-area-inset-bottom/i,
	'the IME page adds no navigation-bar safe-area inset');
ok(($ime_rule || '') !~ /(?:^|;)\s*padding(?:-bottom)?\s*:/,
	'the IME page leaves the dock padding to soft_keyboard.css');

like($ime, qr{/css/soft_keyboard\.css\?string=},
	'the IME page versions the keyboard stylesheet so a fix reaches it');
like($ime, qr{/css/universal\.css\?string=},
	'the IME page versions the shared stylesheet too');

done_testing();
