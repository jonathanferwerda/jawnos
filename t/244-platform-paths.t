# tests-for: lib/JawnOS/Platform/Paths.pm lib/JawnOS/Platform.pm jawn perl/President.pl lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Say.pm lib/JawnOS/Domain/Clock.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Pay2.pm perl/gb/01_state_and_defaults.pl
# covers:    the install roots come from one module, Platform keeps its old
#            names as a facade, and an unusable /tmp falls back to the data
#            directory everywhere the tree writes a temporary.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use Cwd ();
use File::Temp qw(tempdir);
use File::Slurp qw(read_file);

use JawnOS::Platform;
use JawnOS::Platform::Paths qw(home tree_dir data_dir config_dir state_dir tmp_dir log_path tool_path);

my $root = "$FindBin::Bin/..";

# --- home -------------------------------------------------------------------
is(home(env => { 'HOME' => '/house/home' }), '/house/home', 'HOME answers first');
is(home(env => { 'USERPROFILE' => 'C:\\Users\\j' }), 'C:\\Users\\j',
	'USERPROFILE is the Windows answer');
is(home(env => { 'HOMEDRIVE' => 'C:', 'HOMEPATH' => '\\Users\\x' }), 'C:\\Users\\x',
	'the older HOMEDRIVE+HOMEPATH pair still works');
is(home(env => {}), eval { (getpwuid($<))[7] } || '',
	'and the passwd entry is the guarded last answer');

# --- tree and data roots ----------------------------------------------------
is(tree_dir(env => { 'JAWNOS_DIR' => '/a/tree' }), '/a/tree', 'JAWNOS_DIR caps the tree');
is(tree_dir(env => { 'JAWNOS_DIR' => '' }), Cwd::getcwd(), 'without it the tree is the cwd');
is(data_dir(env => { 'JAWNOS_DATA_DIR' => '/a/data' }), '/a/data', 'JAWNOS_DATA_DIR caps the data dir');
is(data_dir(env => { 'HOME' => '/house/home' }), '/house/home/.president',
	'otherwise the data dir sits under home');
my $no_home = home(env => {});
is(data_dir(env => {}), length($no_home) ? "$no_home/.president" : './.president',
	'the data dir follows whatever home the box has');

# --- XDG roots --------------------------------------------------------------
is(config_dir(env => { 'XDG_CONFIG_HOME' => '/xdg', 'HOME' => '/h' }), '/xdg/jawnos',
	'config honours XDG_CONFIG_HOME');
is(config_dir(env => { 'HOME' => '/h' }), '/h/.config/jawnos',
	'and falls back under home');
is(state_dir(env => { 'XDG_STATE_HOME' => '/state', 'HOME' => '/h' }), '/state/jawnos',
	'state honours XDG_STATE_HOME');
is(state_dir(env => { 'HOME' => '/h' }), '/h/.local/state/jawnos',
	'and falls back to the fixed path');

# --- temp -------------------------------------------------------------------
my $tmp = tempdir(CLEANUP => 1);
is(tmp_dir(root => $tmp), $tmp, 'a writable temp is kept');
is(tmp_dir(root => "$tmp/none", env => { 'HOME' => '/h' }), '/h/.president',
	'an unusable temp falls back to the data dir');

# --- log and tool -----------------------------------------------------------
ok(!defined log_path(undef), 'no name, no log path');
is(log_path('/already/absolute.log'), '/already/absolute.log',
	'an absolute name is already the answer');
is(log_path('jawn.log', env => { 'XDG_STATE_HOME' => '/state' }), '/state/jawnos/jawn.log',
	'a relative name lives under the state dir');
ok(length tool_path('perl'), 'a tool on PATH resolves');
ok(!defined tool_path('jawnos-no-such-tool-xyz'), 'an absent tool does not');

# --- the facade stays -------------------------------------------------------
is(JawnOS::Platform::home(env => { 'HOME' => '/facade' }), '/facade',
	'Platform::home still answers');
is(JawnOS::Platform::tree_dir(env => { 'JAWNOS_DIR' => '/facade/tree' }), '/facade/tree',
	'Platform::tree_dir still answers');
is(JawnOS::Platform::data_dir(env => { 'HOME' => '/facade' }), '/facade/.president',
	'Platform::data_dir still answers');
is(JawnOS::Platform::tool_path('perl'), tool_path('perl'),
	'Platform::tool_path is the same seam');

# --- the call sites ask the seam --------------------------------------------
my $jawn = read_file("$root/jawn");
unlike($jawn, qr/^my \$tmp_dir = '\/tmp';/m,
	'the master no longer hardcodes its temp root');
like($jawn, qr/JawnOS::Platform::Paths::tmp_dir\(\)/, 'the master asks the seam for it');
like($jawn, qr/Platform::Paths::log_path\('jawn-stdout\.log'\)/,
	'and for its log candidate');
my $gb = read_file("$root/perl/gb/01_state_and_defaults.pl");
like($gb, qr/Platform::Paths::tmp_dir\(root => '\/tmp'\)/, 'gb asks the seam for its temp root');
for my $file (qw(lib/JawnOS/Domain/Say.pm lib/JawnOS/Domain/Clock.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Pay2.pm)) {
	my $text = read_file("$root/$file");
	unlike($text, qr/(?<!\$gb::tmp_dir \|\| )'\/tmp'\)? unless -d/,
		"$file does not fall back to a bare /tmp");
}

done_testing();
