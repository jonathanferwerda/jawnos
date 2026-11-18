# tests-for: lib/JawnOS/Domain/File.pm lib/JawnOS/Manager/Part17.pm lib/JawnOS/Manager/Part04.pm lib/JawnOS/Domain/Lan.pm templates/configure/misc_setting_list.html.ep perl/help/topics_configure.pl lib/JawnOS/Domain/Loader.pm
# covers:    files on demand. The merge keeps an appointment's file reference
#            and not its bytes; the first open fetches the file from the server,
#            then the machine the row came from, then the other peers, and keeps
#            it; and the sweep gives that space back once the disk passes the
#            mark set in Configure -> Misc.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use RepoSource;
use JawnOSTest;

my $root = repo_root();
my $scratch = tempdir(CLEANUP => 1);

# --- the switch ---------------------------------------------------------------
{
	my $stored = '';
	my $device = 'computer';
	no warnings 'redefine';
	local *subs::misc_setting = sub { $_[0] eq 'files_on_demand' ? $stored : '' };
	local *subs::device_setter = sub { $device };

	is(subs::files_on_demand(), 0, 'a computer does not keep files on demand unless it says so');
	$device = 'controller';
	is(subs::files_on_demand(), 1, 'a controller does');
	$stored = 'off';
	is(subs::files_on_demand(), 0, 'an explicit off wins on a controller');
	$device = 'computer';
	$stored = 'on';
	is(subs::files_on_demand(), 1, 'an explicit on wins on a computer');
}

# --- the disk mark ------------------------------------------------------------
{
	my $stored = '';
	no warnings 'redefine';
	local *subs::misc_setting = sub { $_[0] eq 'files_cache_full_percent' ? $stored : '' };

	is(subs::files_pressure_percent(), 80, '80 per cent by default');
	$stored = '70';
	is(subs::files_pressure_percent(), 70, 'a number is read');
	$stored = ' 65 ';
	is(subs::files_pressure_percent(), 65, 'whitespace is allowed');
	$stored = '30';
	is(subs::files_pressure_percent(), 50, 'below 50 is raised to 50');
	$stored = '99';
	is(subs::files_pressure_percent(), 95, 'above 95 is held to 95');
	$stored = 'soon';
	is(subs::files_pressure_percent(), 80, 'anything else is the default');
}

# --- the cache rows the sweep works from --------------------------------------
{
	my $path = "$scratch/fod-probe.txt";
	write_file($path, "x");
	ok(subs::files_cache_note($path), 'a fetched file is noted for the sweep');
	my $row = subs::db_select('cache', undef, { context => 'files_on_demand', uuid => $path })->hash;
	ok($row, 'the note is a cache row');
	ok(!defined subs::files_cache_source($path), 'a note with no source names no machine');

	# The row is also the map a path-only request reads: the Gallery asks
	# /file_open?file=<path>, with no appointment entry in hand.
	ok(subs::files_cache_note($path, '/house/photo.jpg', 'peer-sig'), 'a note can carry the source');
	my $source = subs::files_cache_source($path);
	is($source->{'remote_f'}, '/house/photo.jpg', 'the path on the machine that has it comes back');
	is($source->{'remote_peer'}, 'peer-sig', 'and that machine');
	# A fetch moves the last-use time only; the source has to survive it or a
	# request that names only the path would stop finding the machine.
	ok(subs::files_cache_note($path), 'a later fetch re-notes the file');
	my $after = subs::files_cache_source($path);
	is($after->{'remote_f'}, '/house/photo.jpg', 'and the source survives it');

	ok(subs::files_cache_forget($path), 'and can be forgotten');
	ok(!subs::db_select('cache', undef, { context => 'files_on_demand', uuid => $path })->hash,
		'the row is gone');
	unlink $path;
}

# --- the sweep leaves a disk alone when the switch is off ---------------------
{
	no warnings 'redefine';
	local *subs::misc_setting = sub { '' };
	local *subs::device_setter = sub { 'computer' };
	my $said = subs::files_pressure_sweep();
	is($said->{'skipped'}, 'off', 'nothing is removed when the switch is off');
}

# --- a file with no source is not fetched ------------------------------------
is(subs::media_fetch_on_demand("$scratch/nowhere.txt", {}), 0,
	'a file with no remote reference is not fetched');
is(subs::media_fetch_on_demand(undef, { remote_f => '/x' }), 0,
	'no local path is no fetch');

# --- the merge keeps the reference and not the bytes --------------------------
my $merge = read_file("$root/lib/JawnOS/Manager/Part17.pm");
like($merge, qr/if \(&subs::files_on_demand\(\)\) \{\s*\n\s*\$fi->\{\$file_type\} = \$dest;\s*\n\s*\$fi->\{'remote_f'\} = \$file;/,
	'the merge keeps the entry and the path on the machine that has the file');
like($merge, qr/\$fi->\{'remote_peer'\} = \(\$configuration->\{'remote'\}->\{'signatorial'\} \/\/ ''\)/,
	'and names that machine');
unlike($merge, qr/unless \(-e \$dest && !&subs::file_sentinel_stub\(\$dest\)\) \{\s*\n\s*`mkdir -p \$destination`;/,
	'the eager copy no longer runs, so on-demand has its own branch');

# --- the open fetches it once ------------------------------------------------
my $open = read_file("$root/lib/JawnOS/Manager/Part04.pm");
like($open, qr/&subs::media_fetch_on_demand\(\$file, \$source\)/,
	'opening a file that is not here asks the house for it');
like($open, qr/&subs::files_cache_source\(\$file\)/,
	'a request that names only the path reads the source from the cache row');
like($open, qr/\$on_demand_entry = \$f;/, 'the appointment entry goes with the request');

my $file_pm = read_file("$root/lib/JawnOS/Domain/File.pm");
my ($fetch) = $file_pm =~ /(sub media_fetch_on_demand\b.*?\n\})/s;
ok($fetch, 'media_fetch_on_demand exists');
my $server_at = index($fetch, "eq 'server'");
my $peer_at = index($fetch, 'length $remembered &&');
my $rest_at = index($fetch, 'return 0 unless @candidates;');
ok($server_at >= 0 && $peer_at > $server_at && $rest_at > $peer_at,
	'the server is asked first, then the machine the row came from, then the rest');
like($fetch, qr/remoted=yes/, 'a peer answers the read instead of handing it on again');
like($fetch, qr/&synced_file_payload\(\$res->body, \$path\)/,
	'and the body goes through the sentinel-aware check');
like($fetch, qr/&files_cache_note\(\$path\);/, 'a fetched file is remembered for the sweep');

# --- the sweep runs where the machine already ticks --------------------------
my $lan = read_file("$root/lib/JawnOS/Domain/Lan.pm");
like($lan, qr/if \(&subs::files_on_demand\(\)\) \{\s*\n\s*my \$swept = eval \{ &subs::files_pressure_sweep\(\) \};/,
	'the two-minute pass sweeps before the card hold');
my ($sweep) = $file_pm =~ /(sub files_pressure_sweep\b.*?\n\})/s;
ok($sweep, 'files_pressure_sweep exists');
like($sweep, qr/context = \? order by cast\(server_time as integer\) asc/, 'oldest copy first');
like($sweep, qr/next unless -f \$path/, 'a file already given back is skipped');
like($sweep, qr/^\s*unlink \$path;/m, 'the copy is removed');
unlike($sweep, qr/files_cache_forget/, 'the row stays: it is where the read finds the source');

# --- Configure -> Misc offers both --------------------------------------------
my $misc = read_file("$root/templates/configure/misc_setting_list.html.ep");
like($misc, qr/setting="files_on_demand"/, 'Misc carries the switch');
like($misc, qr/setting="files_cache_full_percent"/, 'and the disk mark');
like($misc, qr/min="50" max="95"/, 'the mark is held between 50 and 95');

my $help = read_file("$root/perl/help/topics_configure.pl");
like($help, qr/Files on demand, in Misc/, 'the Configure topic names the section');
like($help, qr/from the server first, then the machine the record came from/, 'and the order it asks in');

# --- the name index knows the new subs ---------------------------------------
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/for qw\(.*\bfiles_on_demand\b.*\)/, 'the loader carries files_on_demand');
like($loader, qr/for qw\(.*\bmedia_fetch_on_demand\b.*\)/, 'and media_fetch_on_demand');

done_testing();
