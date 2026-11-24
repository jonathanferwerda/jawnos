# tests-for: templates/configure/restore_list.html.ep public/js/manager/configure/04_currency_backup.js lib/JawnOS/Controller/manager_configure5.pm lib/JawnOS/Domain/Embedded.pm perl/Alarm.pl
# covers:    the Enc panel's four retention fields, the second-copy folder, the
#            verify button, and card backups in the restore list.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use JawnOSTest;

subs::preload('restore_list backup_archive_owner backups_dir backup_archive_dir signatorial_designer');

my $root = "$FindBin::Bin/..";
my $enc = read_file("$root/templates/configure/restore_list.html.ep");
like($enc, qr/setting="max_backups"/, 'the Enc panel owns the daily count');
like($enc, qr/setting="backup_weeks"/, 'and the weekly count');
like($enc, qr/setting="backup_months"/, 'and the monthly count');
like($enc, qr/setting="backup_years"/, 'and the yearly count');
like($enc, qr/setting="backup_offsite"/, 'and the second-copy folder');
like($enc, qr/id="backup_verify_now"/, 'the panel offers Verify now');
like($enc, qr/source/, 'the backup cards name their source');

my $js = read_file("$root/public/js/manager/configure/04_currency_backup.js");
like($js, qr/#backup_verify_now/, 'the button has a handler');
like($js, qr{/manager/configure/backup_verify}, 'it calls the verification route');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_configure5.pm");
like($controller, qr/sub action_19725\b/, 'the verification action exists');
like($controller, qr/backup_path_allowed/, 'restore, merge and delete accept the card folder');
like($controller, qr/backup_open_sealed\(\$path, \$cr, \$t_database, 0\)/, 'restore uses the shared sealed reader');

my $embedded = read_file("$root/lib/JawnOS/Domain/Embedded.pm");
like($embedded, qr/backup_archive_dir/, 'the restore list reads the card folder');
like($embedded, qr/source =>/, 'and labels each card copy');

my $alarm = read_file("$root/perl/Alarm.pl");
like($alarm, qr/backup_verify_retained/, 'the monthly haircut runs the drill');
like($alarm, qr/setting => 'backup_verify_at'/, 'and records when it ran');

my $misc = read_file("$root/templates/configure/misc_setting_list.html.ep");
unlike($misc, qr/max_backups/, 'the daily count moved out of the Misc panel');

# The restore list shows a card mirror as its own row, and hides a card that
# names another machine.
my $local_dir = tempdir(CLEANUP => 1);
my $card_dir = tempdir(CLEANUP => 1);
write_file("$local_dir/jawnos.enc", 'local');
write_file("$local_dir/jawnos_1795478403416.enc", 'dated');
write_file("$card_dir/jawnos_1795392003353.enc", 'card');
my ($mine, $foreign);
{
	local *subs::backups_dir = sub { $local_dir };
	local *subs::backup_archive_dir = sub { $card_dir };
	local *subs::backup_archive_owner = sub { 'machine-a' };
	local *subs::signatorial_designer = sub { 'machine-a' };
	$mine = subs::restore_list();
}
is( scalar @{$mine}, 3, 'local and card backups are listed' );
is( scalar( grep { ($_->{'source'} // '') eq 'card' } @{$mine} ), 1,
	'the card copy is labelled as a card copy' );
{
	local *subs::backups_dir = sub { $local_dir };
	local *subs::backup_archive_dir = sub { $card_dir };
	local *subs::backup_archive_owner = sub { 'machine-a' };
	local *subs::signatorial_designer = sub { 'machine-b' };
	$foreign = subs::restore_list();
}
is( scalar( grep { ($_->{'source'} // '') eq 'card' } @{$foreign} ), 0,
	'a card that names another machine is not offered' );

done_testing();
