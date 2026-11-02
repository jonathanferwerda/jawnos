use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

# Manager.pl is one file no longer: lib/JawnOS.pm is the app, lib/JawnOS/Routes*
# the route table, lib/JawnOS/Controller/* the actions, and lib/JawnOS/Manager.pm
# the bootstrap plus an index of helpers in lib/JawnOS/Manager/Part*.pm that load
# on first call. These are the invariants that break *quietly* if the split is
# disturbed - a worker that boots but has no session secret, a helper whose index
# entry points at a file that no longer defines it, or the Lite DSL coming back
# into package Manager and re-pointing app() at a second app.

my $root = "$FindBin::Bin/..";
sub slurp_rel { my $t = read_file("$root/$_[0]"); return defined $t ? $t : '' }

# The eager boot body is the index plus the Core*.pm parts it requires (the
# lazy helper parts under Part*.pm are not read here), in require order.
my $manager = slurp_rel('lib/JawnOS/Manager.pm');
my @boot_parts = grep { m{^JawnOS/Manager/Core} } ($manager =~ /^require\s+'([^']+)';/mg);
$manager .= slurp_rel("lib/$_") for @boot_parts;
my $index   = slurp_rel('lib/JawnOS/Manager/Index.pm');
my $decls   = slurp_rel('lib/JawnOS/Manager/Declarations.pm');
my $app     = slurp_rel('lib/JawnOS.pm');

# 1. The worker bootstrap stays eager. The websocket worker binds its sockets and
#    the last block sets sessions and secrets; in a lazy part they would never
#    run and the worker would come up deaf and cookieless.
my @purpose_blocks = ($manager =~ /^if \(\$ENV\{PURPOSE\}/mg);
is(scalar @purpose_blocks, 3, 'Manager.pm keeps the three PURPOSE bootstrap blocks in the eager file');
like($manager, qr{^\s*app->sessions->encrypted\(1\);?$}m, 'the session settings are in the eager file');

# 2. One index entry per helper, pointing at a part that really defines it.
my %in_index;
while ($index =~ /^\t'([A-Za-z_]\w*)'\s*=>\s*'(JawnOS\/Manager\/Part\d+\.pm)',/mg) {
	$in_index{$1} = $2;
}
cmp_ok(scalar keys %in_index, '>', 500, 'the index maps every helper');

my (%part_source, @missing);
for my $name (sort keys %in_index) {
	my $file = $in_index{$name};
	$part_source{$file} //= slurp_rel("lib/$file");
	push @missing, "$name -> $file" unless $part_source{$file} =~ /^\s*sub\s+\Q$name\E\b/m;
}
is(scalar @missing, 0, 'every indexed helper is defined in the part it names')
	or diag(join "\n", @missing[0 .. ($#missing > 9 ? 9 : $#missing)]);

# 3. Every indexed helper is forward-declared, so the eager files compile and a
#    call reaches AUTOLOAD instead of dying.
my @undeclared = grep { $decls !~ /^sub \Q$_\E;/m } sort keys %in_index;
is(scalar @undeclared, 0, 'every indexed helper is forward-declared')
	or diag(join "\n", @undeclared[0 .. ($#undeclared > 9 ? 9 : $#undeclared)]);

# 4. Lazy loading: Manager.pm requires the declarations and the index, nothing
#    else from the helper parts.
unlike($manager, qr{require\s+['"]JawnOS/Manager/Part\d+}, 'no helper part is required eagerly');
like($manager, qr/^sub AUTOLOAD\b/m, 'the helpers are loaded through AUTOLOAD');

# 5. One app. Mojolicious::Lite's import creates an app object and re-points
#    app()/get()/new() in the importing package. Music.pl and hooks.pl are
#    compiled into package Manager, so a Lite import there silently replaces the
#    application - that is exactly the bug this split had to remove.
for my $f ('perl/Music.pl', 'perl/hooks.pl', 'perl/subroutines.pl') {
	my $src = slurp_rel($f);
	unlike($src, qr/^use\s+Mojolicious::Lite\b/m, "$f does not run the Lite import");
}
unlike($app, qr/^use\s+Mojolicious::Lite\b/m, 'JawnOS.pm is full Mojolicious');

# 6. The controller is reached as a controller, not as a mounted application.
like($app, qr/^\s*\$r->namespaces\(\['main'\]\);?$/m,
	'the route namespace resolves the top-level Manager package');
like($manager, qr/^use Mojo::Base 'Mojolicious::Controller';$/m,
	'Manager.pm is a controller class');

done_testing();
