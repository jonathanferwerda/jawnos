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

done_testing();
