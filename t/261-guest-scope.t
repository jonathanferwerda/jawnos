# tests-for: lib/JawnOS/Manager/Part04.pm lib/JawnOS/Controller/manager_misc3.pm lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Domain/Crest.pm
# covers:    A visitor's ticket is not the house: as_is file reads, the sync
#           and backup rails, and the pull's manager URL refuse it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

sub source { return read_file(root() . '/' . $_[0]) }

# --- the helper itself -------------------------------------------------------
ok(subs::guest_browser_session('visitor', 'ticket'), 'a visitor ticket is a guest');
ok(subs::guest_browser_session('stranger', 'ticket'), 'a stranger ticket is a guest');
ok(subs::guest_browser_session('', 'ticket'), 'an empty-scope ticket is a guest');
ok(!subs::guest_browser_session('resident', 'ticket'), 'a resident ticket is the house');
ok(!subs::guest_browser_session('citizen', 'ticket'), 'a citizen ticket is the house');
ok(!subs::guest_browser_session('', 'device'), 'a paired device with no person is not a guest');

# --- as_is is house-only -----------------------------------------------------
my $part04 = source('lib/JawnOS/Manager/Part04.pm');
like($part04, qr/\$c->param\('as_is'\) && !\$peer_signed && &subs::guest_browser_session\(/,
	'as_is refuses a guest browser');
like($part04, qr/media_path_allowed\(\$file\)/, 'and stays inside the media roots');

# --- sync and backup rails refuse a guest ------------------------------------
my $misc3 = source('lib/JawnOS/Controller/manager_misc3.pm');
my $guards = () = $misc3 =~ /!&subs::guest_browser_session\(\$c->session\('privilege'\), \$c->session\('source'\)\)/g;
cmp_ok($guards, '>=', 4, 'sync_rows, tombstones, buckets and backup/confirm all ask for the house');
like($misc3, qr/path_is_within\(\$p, \$backup_root\)/,
	'backup/confirm only shreds a file under the backup folder');

# --- the pull's manager URL is a local house override ------------------------
my $conf2 = source('lib/JawnOS/Controller/manager_configure2.pm');
like($conf2, qr/my \$house_session = \(\$c->session\('authentication'\) \|\| ''\) eq 'approved'/,
	'remote_upgrade asks for a house session');
like($conf2, qr/\$house_session && \$caller_local\) \? \$c->param\('manager'\)/,
	'and only a local house caller may name the manager URL');

done_testing();
