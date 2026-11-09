# tests-for: lib/JawnOS/Platform/Runner/Windows.pm
# covers:    the Windows child runner: start, read both streams, see the exit,
#            and stop a live child. Skipped everywhere but Windows.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);
use Time::HiRes qw(sleep);

plan skip_all => 'Windows only' unless $^O eq 'MSWin32';

use Mojo::IOLoop;
require JawnOS::Platform::Runner::Windows;

my $tmp = tempdir(CLEANUP => 1);
my $child = "$tmp/child.pl";
write_file($child, "print qq(one\\n); print STDERR qq(two\\n); sleep 1; exit 3;\n");

my $seen = '';
my $exit;
my $runner = JawnOS::Platform::Runner::Windows->new;
$runner->conduit({ type => 'pipe' });
$runner->on(read => sub { $seen .= $_[1] });
$runner->on(close => sub { $exit = $_[1]; Mojo::IOLoop->stop });

my $pid = $runner->start({ program => $^X, program_args => [$child] });
ok($pid, 'the child starts') or diag($runner->{'error'});
is($runner->pid, $pid, 'and its pid is known');
Mojo::IOLoop->timer(15 => sub { Mojo::IOLoop->stop });
Mojo::IOLoop->start;

like($seen, qr/^one\r?$/m, 'stdout arrives through the reader');
like($seen, qr/^two\r?$/m, 'stderr arrives through the reader');
is($exit, 3, 'the exit code is seen');

# a live child is stopped, and stopping is not a wait for a clean exit
my $long = "$tmp/long.pl";
write_file($long, "sleep 60;\n");
my $second = JawnOS::Platform::Runner::Windows->new;
my $pid2 = $second->start({ program => $^X, program_args => [$long] });
ok($pid2, 'the second child starts');
sleep 1;
ok($second->alive, 'and is alive');
$second->stop;
ok(!$second->alive, 'stop takes it down');

done_testing();
