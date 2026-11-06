# tests-for: public/js/manager/websocket/00_console_router.js public/js/manager/websocket/01_message_handler.js public/js/manager/websocket.js perl/Websocket.pl lib/JawnOS/Manager/Part31.pm lib/JawnOS/Domain/Render.pm
# covers:    The console channel routes named commands and never evals a frame.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);

my $root = abs_path("$FindBin::Bin/..");

sub source {
	my ($rel) = @_;
	open(my $fh, '<', "$root/$rel") or die "open $rel: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

my $router = source('public/js/manager/websocket/00_console_router.js');
like($router, qr/function jawnosConsoleRun\(payload\)/, 'the router exposes one entry point');
like($router, qr/var jawnosConsoleCommands\s*=\s*\{/, 'commands are a name table');
like($router, qr/Object\.prototype\.hasOwnProperty\.call\(jawnosConsoleCommands/, 'inherited names are not commands');
like($router, qr/var jawnosConsoleExact\s*=\s*\{/, 'static instructions are an exact lookup');
like($router, qr/function jawnosConsoleLegacyRun/, 'legacy strings are parsed, not evaluated');
my $evals = () = $router =~ /\beval\s*\(/g;
is($evals, 1, 'the router has exactly one eval (the named terminalJs command)');
like($router, qr/terminalJs:\s*function/, 'that eval is the explicit terminal command');

my $handler = source('public/js/manager/websocket/01_message_handler.js');
like($handler, qr/jawnosConsoleRun\(data\['console'\]\)/, 'the message handler routes the console frame');
unlike($handler, qr/eval\(data\[/, 'the frame is never evaluated');

my $websocket = source('perl/Websocket.pl');
like($websocket, qr/sub console_command\s*\{/, 'the server builds command objects');

my $part31 = source('lib/JawnOS/Manager/Part31.pm');
like($part31, qr/cmd => 'smsSend'/, 'sms send is a command object');
like($part31, qr/cmd => 'smsMms'/, 'sms mms is a command object');

my $render = source('lib/JawnOS/Domain/Render.pm');
like($render, qr/console_command\('terminalJs', \$command\)/, 'the terminal is the named JS command');

# The matrix runs only where node is available; the suite stays runnable without it.
my $node = $ENV{'JAWNOS_NODE'} || '';
if (!$node) {
	for my $c ( '/home/jawn/.local/opt/node/bin/node', '/usr/bin/node', '/usr/local/bin/node' ) {
		if (-x $c) { $node = $c; last; }
	}
}
SKIP: {
	skip 'node is not installed', 1 unless $node;
	my $matrix = "$root/t/lib/console_router_matrix.js";
	my $file = "$root/public/js/manager/websocket/00_console_router.js";
	my $out = `$node $matrix $file 2>&1`;
	is($? >> 8, 0, 'the command matrix passes') or diag($out);
}

done_testing();
