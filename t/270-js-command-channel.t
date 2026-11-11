# tests-for: lib/JawnOS/Domain/Render.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Controller/manager_misc13.pm public/js/manager/websocket/00_console_router.js public/js/manager/websocket/01_message_handler.js
# covers:    An app's command/kill setting used to be sent as terminalJs to every
#            open manager tab, so a saved setting was script. Only the shapes the
#            house really uses survive the server validator (a click on a named
#            element, a seek on the music player); the terminal marker is the one
#            way to terminalJs, and a command's echoed output is escaped.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);
use JawnOSTest;

subs::preload('browser_command_valid');

my $root = repo_root();

# --- the browser commands the live settings table carries --------------------
my @accept = (
	q{$('#play').trigger('click');},
	q{$('#next_logo').trigger('click');},
	q{$('#prev_logo').trigger('click');},
	q{$('#music_toggle').trigger('click');},
	q{$('.fuck_you').trigger('click');},
	"tree.sound.currentTime = tree.sound.currentTime + 25;\n",
	"tree.sound.currentTime = tree.sound.currentTime - 15;\n",
	# the same shapes without a trailing semicolon, and padded
	"  \$('#play').trigger('click')  ",
	q{tree.sound.currentTime = tree.sound.currentTime + 5},
);
for my $command (@accept) {
	ok(&subs::browser_command_valid($command), 'accepts ' . $command);
}

# --- anything that is script, or a shell command, is not a browser command ---
my @reject = (
	'alert(document.cookie)',
	q{fetch('/x')},
	q{eval('1')},
	q{document.cookie='x'},
	q{$('#x').html('<img src=x onerror=alert(1)>')},
	# the same shape widened by a second statement
	q{$('#play').trigger('click'); alert(1)},
	# another jQuery verb, an unknown selector character
	q{$('#play').html('x')},
	q{$('#pl ay').trigger('click');},
	# a shell command belongs in the worker, not in a tab
	'firefox',
	'pkill firefox',
	'amixer set Master toggle',
	'amixer set Master 2%+',
	'xfce4-screenshooter -fd 1',
	'',
);
for my $command (@reject) {
	ok(!&subs::browser_command_valid($command), 'rejects ' . ($command eq '' ? '(empty)' : $command));
}

# --- the server only sends a console frame for the accepted shapes -----------
my $render = read_file("$root/lib/JawnOS/Domain/Render.pm");
like($render, qr/^sub browser_command_valid\b/m, 'Render.pm defines the validator');
like($render, qr/elsif \(&browser_command_valid\(\$command\)\)/, 'run_command sends a browser frame only when the validator accepts it');
like($render, qr/console_command\('browserCommand', \$command\)/, 'the accepted string travels as browserCommand');
like($render, qr/console_command\('terminalJs', \$command, 'terminal'\)/, 'terminalJs carries the explicit terminal marker');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Render' for qw\([^)]*\bbrowser_command_valid\b/, 'the domain loader maps the validator to Render.pm');

# --- the terminal route is the only caller with the marker -------------------
my $terminal = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
like($terminal, qr/run_command\('terminal',\$c->param\('command'\),\$timestamp,\{ terminal => 1 \}\)/,
	'POST /manager/terminal asks for the terminal channel');

# --- a setting write cannot smuggle script into the command channel ----------
my $setter = read_file("$root/lib/JawnOS/Controller/manager_misc13.pm");
like($setter, qr/\$setting eq 'command' \|\| \$setting eq 'kill'/, 'the setter treats command and kill specially');
like($setter, qr/!&subs::browser_command_valid\(\$value\)/, 'a script-shaped value must pass the validator');

# --- the browser half: a twin validator, and a marked terminal --------------
my $router = read_file("$root/public/js/manager/websocket/00_console_router.js");
like($router, qr/function jawnosBrowserCommandValid\(command\)/, 'the router has the JS twin of the validator');
like($router, qr/browserCommand: function \(a\)/, 'the router names browserCommand');
like($router, qr/!jawnosBrowserCommandValid\(command\)/, 'browserCommand validates before eval');
like($router, qr/String\(a\[1\] \|\| ''\) !== 'terminal'/, 'terminalJs refuses a frame without the marker');
my @evals = $router =~ /eval\(/g;
is(scalar(@evals), 2, 'only terminalJs and browserCommand reach an eval');

# --- a command's echo is escaped before it becomes markup -------------------
my $handler = read_file("$root/public/js/manager/websocket/01_message_handler.js");
like($handler, qr/syncEscape\(data\['whoami'\]\)/, 'the command echo escapes whoami');
like($handler, qr/syncEscape\(data\['hostname'\]\)/, 'the command echo escapes hostname');
like($handler, qr/syncEscape\(data\['command'\]\)/, 'the command echo escapes the command');
like($handler, qr/syncEscape\(data\['return'\]\)\.replace\(\/\(\?:\\r\\n\|\\r\|\\n\)\/g, '<br>'\)/,
	'the command return is escaped before newlines become <br>');

done_testing();
