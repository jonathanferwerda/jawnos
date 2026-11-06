# tests-for: lib/JawnOS/Manager/Part05.pm lib/JawnOS/Manager/Part34.pm jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino
# covers:    A start arms a scheduled stop job on a board; stopping the session
#            early (or stopping it and then starting it again) cancels that job
#            for the session uuid, so the abandoned stop cannot turn the board
#            off later. The cancellation runs before the record branches that
#            may skip the rest of the loop.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root   = repo_root();
my $part05 = read_file("$root/lib/JawnOS/Manager/Part05.pm");
my $part34 = read_file("$root/lib/JawnOS/Manager/Part34.pm");
my $board  = read_file("$root/jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino");

# The stop branch is the block that closes the named session.
my $stop_at = index($part05, q{if ($app->{'type'} eq 'stop')});
ok($stop_at >= 0, 'the stop branch is still there');
my $image_at = index($part05, q{if ($app->{'type'} eq 'image'}, $stop_at + 1);
my $stop = $stop_at >= 0
	? substr($part05, $stop_at, ($image_at > $stop_at ? $image_at - $stop_at : 12000))
	: '';

like($stop, qr/&embedded_app_deleter\(\{\s*appt_uuid\s*=>\s*\$appt->\{'uuid'\}\s*\}\)/,
	'the stopped session cancels the jobs armed for it');

my $cancel_at = index($stop, 'embedded_app_deleter');
my $record_at = index($stop, q{if ($appt->{'type'} eq 'record')});
ok($cancel_at >= 0 && $record_at > $cancel_at,
	'the cancellation runs before the record branches, which may next');

# The deleter is the manager's one job-cancel road: it names the session uuid.
like($part34, qr/sub embedded_app_deleter/,
	'the manager still has one embedded job deleter');
like($part34, qr{/delete_job.*appt_uuid=}, 'and it posts the session uuid to the board');

# The board matches jobs by the appointment uuid, which is what the stop
# cancels. If this key changed, the cancellation would silently do nothing.
my $del_at = index($board, 'server.on("/delete_job"');
ok($del_at >= 0, 'the board still has the delete_job route');
my $next_at = index($board, 'server.on(', $del_at + 1);
my $del = $del_at >= 0
	? substr($board, $del_at, ($next_at > $del_at ? $next_at - $del_at : 1600))
	: '';
like($del, qr/\["appt_uuid"\]/, 'the board keys a job by its appointment uuid');
like($del, qr/config\["jobs"\]\[\$?uuid\]\s*=\s*undefined/, 'and removes the matching jobs');

done_testing();
