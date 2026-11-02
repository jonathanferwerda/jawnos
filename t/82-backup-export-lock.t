# tests-for: lib/JawnOS/Domain/Backup.pm lib/JawnOS/Domain/Ble2.pm lib/JawnOS/Domain/Loader.pm
# covers:    A peer's snapshot export (`backup_now?reason=remote_update`) takes a `remote_backup_lock` and holds it with a ...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;

# A peer's snapshot export (`backup_now?reason=remote_update`) takes a
# `remote_backup_lock` and holds it with a guard object so the lock is released
# even when the export dies part-way.
#
# Regression: the guard class `Jawn::BackupLock` was defined at the bottom of
# Domain/Ble2.pm, but the code that blesses it is Domain/Backup.pm, and
# Domain/Loader.pm names Backup.pm for `backup_now` alone. A worker that had
# never touched Bluetooth/embedded - every worker on a phone or tablet - died
# with `Can't locate object method "new" via package "Jawn::BackupLock"` at
# Backup.pm:150, so every snapshot pull failed: the panel's Upgrade button, a
# nightly deep pull, and a migration. The v3 row stream uses another path, so
# automatic sync looked healthy while the button did not work (the tablet's
# sync_jobs carried that exact error on 2026-11-01).
#
# The guard is asserted in a fresh interpreter that loads Backup.pm and nothing
# else, which is the state the loader actually creates for `backup_now`.

my $root = repo_root();

sub perl_out {
	my ($code) = @_;
	open(my $fh, '-|', $^X, '-I' . "$root/lib", '-e', $code) or return '';
	local $/;
	my $out = <$fh>;
	close $fh;
	return defined $out ? $out : '';
}

my $out = perl_out(
	'require JawnOS::Domain::Backup; print Jawn::BackupLock->can("new") ? "yes" : "no";'
);
is($out, 'yes', 'loading Domain/Backup.pm alone defines the export lock guard');

my $guard = perl_out(
	'require JawnOS::Domain::Backup; my $g = Jawn::BackupLock->new("abc:123");'
	. ' print ref($g) eq "Jawn::BackupLock" && $g->can("release") && $g->can("DESTROY") ? "yes" : "no";'
);
is($guard, 'yes', 'the guard can be created and has its release hooks');

# Two files defining the same package would warn "Subroutine new redefined" the
# first time both were loaded in one worker.
my $ble2 = '';
if (open(my $fh, '<', "$root/lib/JawnOS/Domain/Ble2.pm")) {
	local $/;
	$ble2 = <$fh>;
	close $fh;
}
unlike($ble2, qr/package\s+Jawn::BackupLock/, 'the guard is not defined a second time in Ble2.pm');

my $backup = '';
if (open(my $fh, '<', "$root/lib/JawnOS/Domain/Backup.pm")) {
	local $/;
	$backup = <$fh>;
	close $fh;
}
like($backup, qr/package\s+Jawn::BackupLock;/, 'the guard is defined beside backup_now');
like($backup, qr/Jawn::BackupLock->new\(\$backup_lock\)/, 'backup_now still takes the guard');

done_testing();
