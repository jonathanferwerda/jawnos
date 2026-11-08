# tests-for: desktop/ jawn
# covers:    The root is the user's shelf: the commands people run live here, beside the service entry, and the desktop imp...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The root is the user's shelf: the commands people run live here, beside the
# service entry, and the desktop implementation stays in desktop/. Each
# wrapper execs its implementation so __file__ still points at desktop/, which
# is what the Python packages resolve their imports from.

my $root = repo_root();
my @commands = qw(jawn jawnosctl jawnos-desktop jawnos-bt-daemon);

foreach my $command (@commands) {
	ok(-f "$root/$command", "$command is at the root");
	ok(-x "$root/$command", "$command is executable");
}

foreach my $command (qw(jawnosctl jawnos-desktop jawnos-bt-daemon)) {
	my $src = read_file("$root/$command");
	like($src, qr{exec "\$here/desktop/\Q$command\E" "\$@"},
		"$command execs its desktop implementation");
}

# The desktop command is Qt only: no GTK dashboard, no WebKitGTK view.
my $desktop = read_file("$root/desktop/jawnos-desktop");
unlike($desktop, qr/jawnos_desktop\.(?:ui|webview)/,
	'jawnos-desktop has no GTK/WebKit branch');

my $python = qx{python3 --version 2>/dev/null};
SKIP: {
	skip 'python3 is not installed', 1 unless $python;
	my $out = qx{"$root/jawnosctl" --version 2>&1};
	like($out, qr/jawnosctl/, 'the root command runs from a checkout');
}

done_testing();
