# tests-for: perl/President.pl jawn lib/JawnOS/Platform.pm lib/JawnOS/Domain/Devicews.pm
# covers:    the two entry points consult the platform module: no threads, a
#            Daemon instead of Prefork in portable mode, and a pipe instead of
#            a pty for the master's tree runner. The choice itself is exercised
#            in t/219; this pins the wiring that cannot be booted in a test, and
#            compiles the tree with no repo lib in @INC (the launch shape).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Slurp qw(read_file);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

my $president = read_file("$FindBin::Bin/../perl/President.pl");
my $master    = read_file("$FindBin::Bin/../jawn");

unlike($president, qr/^use threads\b/m, 'the tree no longer loads threads');
unlike($president, qr/threads->create/, 'no browser-open thread remains');

like($president, qr/^require JawnOS::Platform;/m,
	'President loads the platform module');
like($president, qr/^sub run_server\b/m, 'the server chooser exists');
like($president, qr/JawnOS::Platform::portable\(\)/,
	'the chooser consults portable mode');
like($president, qr/Mojo::Server::Daemon->new\(listen => \$listeners\)/,
	'portable mode uses a single Daemon');
like($president, qr/Mojo::Server::Prefork->new\(listen => \$listeners\)/,
	'native mode keeps Prefork');
like($president, qr/^sub run_dev_server\b/m, 'development has the same choice');

like($master, qr/^use JawnOS::Transport;/m,
	'the master loads the transport module (and Platform through it)');
like($master, qr/type => 'pipe'/, 'the master can run the tree on a pipe');
like($master, qr/type => 'pty'/, 'the master still uses a pty when native');

# Windows cannot call getpwuid (it dies), and a launch by a service or a desktop
# shortcut has no HOME, so the master's own local::lib block has to resolve
# USERPROFILE and only fall back to getpwuid inside an eval. Its PERL5LIB also
# travels to the tree, where Windows splits it on ';'.
like($master, qr/USERPROFILE/, 'the master finds a Windows home without getpwuid');
like($master, qr/eval \{ \(getpwuid/, 'and calls getpwuid only inside an eval');
like($master, qr/\$sep = \$\^O eq 'MSWin32'/, 'and exports PERL5LIB with the platform separator');

# The master adds the repo lib to its own @INC but its PERL5LIB carries only the
# local::lib tree, so the tree starts as plain `perl ./perl/President.pl` with no
# repo lib. A compile-time load that does not locate lib itself aborts the tree
# before it can log (the 16:28 crash loop).
sub compiles_without_repo_lib {
	my ($file) = @_;
	my @local = grep { m{/perl5/lib/perl5} } @INC;
	local $ENV{'PERL5LIB'} = join ':', @local;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, '-c', $file);
	close $in;
	my $stderr = do { local $/; <$err> } // '';
	my $stdout = do { local $/; <$out> } // '';
	waitpid($pid, 0);
	return ($? >> 8, $stderr . $stdout);
}

my ($president_boot, $president_out) = compiles_without_repo_lib("$FindBin::Bin/../perl/President.pl");
is($president_boot, 0, 'President compiles without the repo lib in @INC')
	or diag($president_out);

my ($devicews_boot, $devicews_out) = compiles_without_repo_lib("$FindBin::Bin/../lib/JawnOS/Domain/Devicews.pm");
is($devicews_boot, 0, 'Devicews compiles without the repo lib in @INC')
	or diag($devicews_out);

done_testing();
