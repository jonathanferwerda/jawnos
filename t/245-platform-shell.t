# tests-for: lib/JawnOS/Platform/Shell.pm perl/remote_input.pl lib/JawnOS/Controller/manager_misc8.pm lib/JawnOS/Controller/manager_folders.pm scripts/jawnos_setup.pl
# covers:    the shell seam: the clipboard tool fallback order and argv, the
#            UTF-8 decode/encode at the clipboard edge, the safe empty answers
#            a machine with no tool gives, the xdg-open argv for a URL and a
#            path, the notify-send argv, the terminal list and the first
#            installed entry's argv, and that the four call sites ask the seam
#            instead of spelling a tool themselves.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Slurp qw(read_file);
use JawnOS::Platform::Shell qw(
	clipboard_get clipboard_set open_url open_path notify
	terminal_argv terminals
);

can_ok('JawnOS::Platform::Shell',
	qw(clipboard_get clipboard_set open_url open_path notify terminal_argv terminals));

# The fixture: which tools this machine "has", and what a run records. Nothing
# here starts xclip, xdg-open, notify-send or a terminal.
my %have;
my @calls;
my $answer = '';

local $JawnOS::Platform::Shell::TOOL_LOOKUP = sub {
	my ($name) = @_;
	return $have{$name} ? "/usr/bin/$name" : undef;
};
local $JawnOS::Platform::Shell::RUN = sub {
	my ($argv, $stdin) = @_;
	push @calls, { argv => [@{$argv}], stdin => $stdin };
	return defined $stdin ? 1 : $answer;
};
local $JawnOS::Platform::Shell::SPAWN = sub {
	my ($argv) = @_;
	push @calls, { argv => [@{$argv}], spawn => 1 };
	return 1;
};
local $JawnOS::Platform::Shell::OPEN_COMMAND = '/usr/bin/xdg-open';

my $last  = sub { return $calls[-1] };
my $clear = sub { @calls = (); $answer = '' };

# ------------------------------------------------------------ the terminal list
my @terminals = terminals();
is(scalar @terminals, 8, 'the list has every terminal core_shell.py names');
is_deeply($terminals[0], ['x-terminal-emulator', ['-e']], 'x-terminal-emulator comes first');
is_deeply($terminals[1], ['kgx', ['-e']], 'kgx is second');
is_deeply($terminals[2], ['gnome-terminal', ['--']], 'gnome-terminal takes --');
is_deeply($terminals[5], ['kitty', []], 'kitty needs no flag');
is_deeply($terminals[6], ['wezterm', ['start', '--']], 'wezterm takes start --');
$terminals[0][1][0] = '-x';
is_deeply((terminals())[0], ['x-terminal-emulator', ['-e']], 'the list is a copy, not the internals');

%have = ();
is_deeply([ terminal_argv('perl', './jawn') ], [], 'no terminal answers an empty argv');

%have = (xterm => 1);
is_deeply([ terminal_argv('perl', './jawn') ], ['/usr/bin/xterm', '-e', 'perl', './jawn'],
	'xterm is run with -e');

%have = (xterm => 1, kgx => 1);
is_deeply([ terminal_argv('perl', './jawn') ], ['/usr/bin/kgx', '-e', 'perl', './jawn'],
	'the list order wins, not PATH order');

%have = (kgx => 1, 'gnome-terminal' => 1);
is_deeply([ terminal_argv('true') ], ['/usr/bin/kgx', '-e', 'true'], 'kgx beats gnome-terminal');

%have = ('gnome-terminal' => 1);
is_deeply([ terminal_argv('true') ], ['/usr/bin/gnome-terminal', '--', 'true'],
	'gnome-terminal takes -- before the command');

# ------------------------------------------------------------ the clipboard read
%have = (xclip => 1, xsel => 1, 'wl-paste' => 1);
$clear->(); $answer = "from xclip\n";
is(clipboard_get(), "from xclip\n", 'xclip answers the read');
is_deeply($last->()->{'argv'}, ['timeout', '2', 'xclip', '-selection', 'clipboard', '-o'],
	'xclip reads the clipboard selection with the 2s guard');

%have = (xsel => 1, 'wl-paste' => 1);
$clear->(); $answer = 'from xsel';
is(clipboard_get(), 'from xsel', 'xsel answers when xclip is absent');
is_deeply($last->()->{'argv'}, ['timeout', '2', 'xsel', '--clipboard', '--output'],
	'xsel reads the clipboard selection');

%have = ('wl-paste' => 1);
$clear->(); $answer = 'from wl-paste';
is(clipboard_get(), 'from wl-paste', 'wl-paste answers when both X11 tools are absent');
is_deeply($last->()->{'argv'}, ['timeout', '2', 'wl-paste', '--no-newline'],
	'wl-paste is read without its trailing newline');

%have = ();
$clear->();
is(clipboard_get(), '', 'no clipboard tool answers the empty string');
is(scalar @calls, 0, 'and starts nothing');

%have = (xclip => 1);
$clear->(); $answer = "caf\xc3\xa9";
is(clipboard_get(), "caf\x{e9}", 'the read is decoded from UTF-8 bytes');

# ------------------------------------------------------------ the clipboard write
%have = (xclip => 1, xsel => 1, 'wl-copy' => 1);
$clear->();
is(clipboard_set('hello'), 1, 'xclip answers the write');
is_deeply($last->()->{'argv'}, ['xclip', '-selection', 'clipboard'],
	'xclip writes the clipboard selection');
is($last->()->{'stdin'}, 'hello', 'and receives the text on stdin');

%have = (xsel => 1, 'wl-copy' => 1);
$clear->();
is(clipboard_set('hello'), 1, 'xsel answers when xclip is absent');
is_deeply($last->()->{'argv'}, ['xsel', '--clipboard', '--input'],
	'xsel writes the clipboard selection');

%have = ('wl-copy' => 1);
$clear->();
is(clipboard_set('hello'), 1, 'wl-copy answers when both X11 tools are absent');
is_deeply($last->()->{'argv'}, ['wl-copy'], 'wl-copy takes no flag');

%have = ();
$clear->();
is(clipboard_set('hello'), 0, 'no clipboard tool reports a failed copy');
is(scalar @calls, 0, 'and starts nothing');

%have = (xclip => 1);
$clear->();
my $utf8 = "caf\x{e9}";
utf8::upgrade($utf8);
is(clipboard_set($utf8), 1, 'a decoded string is written');
is($last->()->{'stdin'}, "caf\xc3\xa9", 'as UTF-8 bytes');

$clear->();
is(clipboard_set(undef), 1, 'undef writes an empty clipboard');
is($last->()->{'stdin'}, '', 'with no bytes');

{
	local $JawnOS::Platform::Shell::RUN = sub { return 0 };
	is(clipboard_set('hello'), 0, 'a tool that cannot be started is a failed copy');
}

# ------------------------------------------------------------ opening
$clear->();
is(open_url('https://127.0.0.1:3000/manager'), 1, 'a URL opens');
is_deeply($last->()->{'argv'}, ['/usr/bin/xdg-open', 'https://127.0.0.1:3000/manager'],
	'with xdg-open and the URL as one argument');

$clear->();
is(open_path('/tmp/a b.txt'), 1, 'a path opens');
is_deeply($last->()->{'argv'}, ['/usr/bin/xdg-open', '/tmp/a b.txt'],
	'with the path as one argument, spaces and all');

$clear->();
is(open_url(''), 0, 'an empty URL opens nothing');
is(open_path(undef), 0, 'an undef path opens nothing');
is(scalar @calls, 0, 'and launches nothing');

{
	local $JawnOS::Platform::Shell::OPEN_COMMAND = '';
	is(open_url('https://127.0.0.1:3000/manager'), 0, 'no opener means the URL is not opened');
	is(open_path('/tmp/a.txt'), 0, 'and a path is not opened');
	is(scalar @calls, 0, 'nothing is launched without an opener');
}
{
	local $JawnOS::Platform::Shell::SPAWN = sub { return 0 };
	is(open_url('https://127.0.0.1:3000/manager'), 0,
		'a launch that fails is reported as not opened');
}
{
	local $JawnOS::Platform::Shell::SPAWN = undef;
	local $JawnOS::Platform::Shell::OPEN_COMMAND = '/bin/true';
	is(open_url('https://127.0.0.1:3000/manager'), 1,
		'the real launch path forks and returns without waiting on an opener');
}

# ------------------------------------------------------------ notifications
%have = ();
$clear->();
is(notify('JawnOS VM', 'ready'), 0, 'no notify-send means no notification');
is(scalar @calls, 0, 'and nothing is launched');

%have = ('notify-send' => 1);
$clear->();
is(notify('JawnOS VM', 'ready'), 1, 'notify-send sends the notification');
is_deeply($last->()->{'argv'}, ['/usr/bin/notify-send', 'JawnOS VM', 'ready'],
	'with the title then the body');

$clear->();
is(notify('Only a title', undef), 1, 'a missing body is still sent');
is_deeply($last->()->{'argv'}, ['/usr/bin/notify-send', 'Only a title', ''],
	'so the argv keeps its two arguments');

# ------------------------------------------------------------ remote_input.pl
require "$FindBin::Bin/../perl/remote_input.pl";
%have = ();
$clear->();
is(remote_input::clipboard_read(), '', 'remote_input reads nothing with no tool');
is(remote_input::clipboard_write('hello'), 0, 'remote_input reports the failed copy');
is(scalar @calls, 0, 'and starts nothing');

%have = (xclip => 1);
$clear->(); $answer = 'pasted';
is(remote_input::clipboard_read(), 'pasted', 'remote_input reads through the seam');
is_deeply($last->()->{'argv'}, ['timeout', '2', 'xclip', '-selection', 'clipboard', '-o'],
	'with the seam read argv');
$clear->();
is(remote_input::clipboard_write('hello'), 1, 'remote_input writes through the seam');
is_deeply($last->()->{'argv'}, ['xclip', '-selection', 'clipboard'],
	'with the seam write argv');

# ------------------------------------------------------------ the call sites
my $remote = read_file("$FindBin::Bin/../perl/remote_input.pl");
like($remote, qr/JawnOS::Platform::Shell::clipboard_get/,
	'remote_input reads through the seam');
like($remote, qr/JawnOS::Platform::Shell::clipboard_set/,
	'remote_input writes through the seam');
unlike($remote, qr/xclip/, 'and no longer spells xclip itself');

my $misc8 = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_misc8.pm");
like($misc8, qr/Platform::Shell::clipboard_get\(\)/, 'the clipboard getter asks the seam');
unlike($misc8, qr/xclip -o/, 'and no longer runs xclip on its own');

my $folders = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_folders.pm");
like($folders, qr/Platform::Shell::open_path\(\$path\)/, 'folders open with asks the seam');
unlike($folders, qr/my \$opener = -x/, 'and no longer probes /usr/bin itself');

my $setup = read_file("$FindBin::Bin/../scripts/jawnos_setup.pl");
like($setup, qr/Platform::Shell::open_url\(\$url\)/, 'the wizard opens its URL through the seam');
unlike($setup, qr/system\("xdg-open/, 'and no longer builds an xdg-open shell string');

done_testing();
