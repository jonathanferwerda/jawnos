# tests-for: lib/JawnOS/Platform/Paths.pm lib/JawnOS/Platform.pm lib/JawnOS/Platform/TLS.pm lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Git.pm lib/JawnOS/Domain/Say.pm lib/JawnOS/Domain/Remote.pm lib/JawnOS/Manager.pm lib/JawnOS/Manager/Part08.pm lib/JawnOS/Controller/manager_misc3.pm lib/JawnOS/Controller/manager_security.pm perl/subroutines.pl perl/President.pl perl/Alarm.pl perl/Music.pl perl/Websocket.pl perl/watch.pl perl/teletype.pl perl/hooks.pl perl/Reception.pl perl/Sco.pl scripts/jawnos_setup.pl scripts/house_ca.pl scripts/tls_issue.pl jawn t/lib/JawnOSTest.pm
# covers:    the writable store is one root: database, run, TLS, voices,
#            releases and config.json follow JAWNOS_STORE_DIR while the factory
#            seed and schema stay with the read-only tree. A checkout defaults
#            to the tree, so nothing changes without the override; a first
#            bootstrap builds the database in the store and leaves the tree
#            clean. Every reader and writer asks the seam instead of spelling
#            ./config.json, ./server or ~/jawnos/{voices,releases}.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use Cwd qw(getcwd);
use JawnOSTest;

my $tree  = tempdir('jawnos-store-tree-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $store = tempdir('jawnos-store-data-XXXXXX', TMPDIR => 1, CLEANUP => 1);

# --- the default is the tree (a checkout is unchanged) ----------------------
{
	local $subs::install_dir = $tree;
	local $ENV{'JAWNOS_STORE_DIR'} = '';
	local $ENV{'JAWNOS_RUN_DIR'} = '';

	is(subs::store_dir(), $tree, 'without an override the store is the tree');
	is(subs::database_dir(), "$tree/database", 'and the database stays beside it');
	is(subs::runtime_dir(), "$tree/run", 'run/ stays in the tree');
	my $cwd = getcwd();
	chdir $tree or die "chdir tree: $!";
	is(subs::config_path(), "$tree/config.json", 'config.json stays in the tree');
	chdir $cwd or die "chdir back: $!";
	is(subs::database_seed_path(), "$tree/database/initial.enc",
		'the factory seed is still read from the tree');
	is(subs::database_schema_path(), "$tree/database/schema.sql",
		'and so is the schema');
}

# --- JAWNOS_STORE_DIR moves every writable surface --------------------------
{
	local $subs::install_dir = $tree;
	local $ENV{'JAWNOS_STORE_DIR'} = $store;
	local $ENV{'JAWNOS_RUN_DIR'} = '';

	is(subs::store_dir(), $store, 'the store follows JAWNOS_STORE_DIR');
	is(subs::database_dir(), "$store/database", 'database/ moves into the store');
	is(subs::runtime_dir(), "$store/run", 'run/ moves into the store');
	is(subs::server_dir(), "$store/server", 'TLS material moves into the store');
	is(subs::voices_dir(), "$store/voices", 'voices move into the store');
	is(subs::releases_dir(), "$store/releases", 'staged releases move into the store');
	is(subs::config_path(), "$store/config.json", 'config.json moves into the store');
	is(subs::database_seed_path(), "$tree/database/initial.enc",
		'the read-only seed stays in the tree');
	is(subs::database_schema_path(), "$tree/database/schema.sql",
		'and the read-only schema stays in the tree');
	ok(-d "$store/run", 'asking for run/ makes it');
}

# --- JAWNOS_RUN_DIR still wins, and a blank value is ignored ----------------
{
	local $subs::install_dir = $tree;
	local $ENV{'JAWNOS_STORE_DIR'} = $store;
	local $ENV{'JAWNOS_RUN_DIR'} = "$tree/elsewhere";
	is(subs::runtime_dir(), "$tree/elsewhere", 'JAWNOS_RUN_DIR overrides the store');
}

# --- first boot: build the database in the store from the tree's schema -----
{
	local $subs::install_dir = $tree;
	local $ENV{'JAWNOS_STORE_DIR'} = $store;
	local $ENV{'JAWNOS_RUN_DIR'} = '';

	make_path("$tree/database");
	copy("$FindBin::Bin/../database/schema.sql", "$tree/database/schema.sql")
		or die "copy schema: $!";

	my $db = subs::database_bootstrap();
	is($db, "$store/database/jawnos.db", 'the first database is built in the store');
	ok(-e $db && -s $db > 5000, 'and it is a real database');
	ok(!-e "$tree/database/jawnos.db", 'the read-only tree gains no database');
}

# --- the call sites ask the seam -------------------------------------------
my %expect = (
	'jawn' => qr/JawnOS::Platform::Paths::config_path/,
	'lib/JawnOS/Manager.pm' => qr/JawnOS::Platform::Paths::config_path/,
	'perl/subroutines.pl' => qr/JawnOS::Platform::Paths::config_path/,
	'perl/President.pl' => qr/JawnOS::Platform::Paths::(?:config_path|server_dir)/,
	'perl/Alarm.pl' => qr/subs::config_path/,
	'perl/Music.pl' => qr/subs::config_path/,
	'perl/Websocket.pl' => qr/subs::config_path/,
	'perl/watch.pl' => qr/subs::config_path/,
	'perl/teletype.pl' => qr/subs::config_path/,
	'perl/hooks.pl' => qr/subs::config_path/,
	'perl/Reception.pl' => qr/subs::config_path/,
	'perl/Sco.pl' => qr/subs::config_path/,
	'lib/JawnOS/Controller/manager_security.pm' => qr/subs::config_path/,
	'lib/JawnOS/Platform/TLS.pm' => qr/JawnOS::Platform::Paths::server_dir/,
	'lib/JawnOS/Domain/Remote.pm' => qr/subs::server_dir/,
	'scripts/house_ca.pl' => qr/JawnOS::Platform::Paths::server_dir/,
	'scripts/tls_issue.pl' => qr/subs::server_dir/,
	'scripts/jawnos_setup.pl' => qr/JawnOS::Platform::Paths::(?:store_dir|config_path|database_seed_path)/,
);
foreach my $file (sort keys %expect) {
	my $text = read_file("$FindBin::Bin/../$file");
	like($text, $expect{$file}, "$file asks the seam");
}

for my $file (qw(
	lib/JawnOS/Domain/Git.pm
	lib/JawnOS/Manager/Part08.pm
	lib/JawnOS/Controller/manager_misc3.pm
	lib/JawnOS/Domain/Say.pm
)) {
	my $text = read_file("$FindBin::Bin/../$file");
	like($text, qr/subs::(?:voices|releases)_dir/,
		"$file resolves voices/releases from the store");
	unlike($text, qr{~/jawnos/(?:voices|releases)},
		"$file no longer hardcodes ~/jawnos");
}

done_testing();
