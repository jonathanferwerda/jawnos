# tests-for: lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Remote.pm
# covers:    A domain helper exists for nobody until lib/JawnOS/Domain/Loader.pm maps it: the loader's %DOMAIN_MODULE is wh...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A domain helper exists for nobody until lib/JawnOS/Domain/Loader.pm maps it:
# the loader's %DOMAIN_MODULE is what subs::provides() answers from and what
# AUTOLOAD uses to find the module that defines a name. v0.1.1799 defined the
# QA schedule helpers in Domain::Remote (qa_retime_local, qa_oncalendar_time,
# qa_command, ...) and left every one of them out of the map. No test noticed,
# because the new tests load Remote.pm directly, so subs::provides() was the
# only caller that would have failed - at runtime, on a person's machine.
#
# This pins the map for the QA helpers. It is deliberately scoped to qa_* : other
# sections of the map have older gaps and pinning them all at once would turn a
# regression test into an inventory.

my $root = repo_root();
my $remote = read_file("$root/lib/JawnOS/Domain/Remote.pm");
my @qa     = ($remote =~ /^sub\s+(qa_\w+)/mg);

ok( scalar @qa > 0, "Domain::Remote defines QA helpers (" . scalar(@qa) . ")" );

require JawnOS::Domain::Loader;

my @missing = grep { !subs::provides($_) } @qa;
is_deeply( \@missing, [], 'every qa_* helper is registered in the domain loader' )
	or diag( "unregistered: " . join( ', ', @missing ) );

# And the loader must name the module that really defines them, or AUTOLOAD
# would load the wrong file.
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like( $loader, qr/JawnOS::Domain::Remote' for qw\([^)]*\bqa_retime_local\b/,
	'the QA helpers are mapped to Domain::Remote' );

# The map is what AUTOLOAD reads, so a domain sub missing from it is unreachable
# by name from any other module: the call dies "Undefined subroutine" at runtime,
# on a person's machine. The qa_* check above was scoped on purpose while older
# sections of the map had gaps; they are closed now, so the whole map is pinned,
# in both directions. When the first check fails, add the name to the `qw(...)`
# for the module that defines it; scripts/where.pl <name> prints that module.
#
# The allowlist is the package plumbing, not domain helpers: the loader's own API
# (provides/preload/AUTOLOAD), the app accessor the renderer uses (Calendar.pm),
# and the OO methods of two local classes (a sync job's new/done/DESTROY, a
# lease's new/release/DESTROY). None of these is called by name through the map.
my %not_a_domain_sub = map { $_ => 1 } qw(app AUTOLOAD DESTROY done new preload provides release);

my %mapped;
while ($loader =~ /qw\(([^)]*)\)/g) {
	$mapped{$_} = 1 for split ' ', $1;
}

my (%defined, %defined_in);
for my $file (glob "$root/lib/JawnOS/Domain/*.pm") {
	my ($rel) = $file =~ m{lib/(JawnOS/Domain/[^/]+\.pm)$};
	next unless $rel;
	my $src = read_file($file);
	while ($src =~ /^\s*sub\s+([A-Za-z_]\w*)\s*(?:\(|\{)/mg) {
		$defined{$1} = 1;
		$defined_in{$1} //= $rel;
	}
}
cmp_ok(scalar(keys %defined), '>', 1000, 'the domain modules define their helpers');

my @unmapped = grep { !$mapped{$_} } sort grep { !$not_a_domain_sub{$_} } keys %defined;
is(scalar @unmapped, 0, 'every domain sub is in %DOMAIN_MODULE')
	or diag('add to Loader.pm: ' . join(', ', map { "$_ ($defined_in{$_})" } @unmapped));

my @ghosts = grep { !$defined{$_} } sort keys %mapped;
is(scalar @ghosts, 0, 'every %DOMAIN_MODULE name is defined by a module')
	or diag('mapped but not defined: ' . join(', ', @ghosts));

done_testing();
