# tests-for: lib/JawnOS/Manager/Part05.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Loader.pm scripts/warranty_backfill.pl
# covers:    a row written by appointment_writer carries its warranty, project and pos from the moment it is inserted, not from a later refresh that omits them; and the backfill that gives rows already born without one their app's warranty

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# appointment_writer writes a start/record/usual row at the top of the sub and
# only refreshes the maker's own fields at the foot. The warranty, project and
# pos used to be filled between those two, so every session the writer started
# itself - a home plate, a timer, a relayed start - was inserted without a
# warranty and never got one: the refresh does not carry those columns, and a
# NULL warranty means the culler never sees the row (the plate-started Home
# session from 2026-11-08 was the one that made this visible).

my $root   = repo_root();
my $part05 = read_file("$root/lib/JawnOS/Manager/Part05.pm");

my $warranty_at = index($part05, "\$app->{'warranty'} = \$app->{'warranty'} || &warranty_resolve");
my $insert_at   = index($part05, "&subs::db_insert('appointments', \$app);");

ok($warranty_at >= 0, 'appointment_writer resolves the warranty');
ok($insert_at >= 0, 'and it inserts the row');
ok($warranty_at < $insert_at, 'the warranty is on the row before the insert, so the insert carries it');

my $project_at = index($part05, "\$app->{'project'} = \$settings->{'t_project'} unless \$app->{'project'};");
my $pos_at     = index($part05, "\$app->{'pos'} = \$settings->{'pos'} unless \$app->{'pos'};");
ok($project_at >= 0 && $project_at < $insert_at, 'and so is the project');
ok($pos_at >= 0 && $pos_at < $insert_at, 'and the pos');

# The foot of the sub refreshes only these columns; warranty/project/pos must not
# silently become its job again, because a start's insert has already happened.
my ($maker_fields) = $part05 =~ /my %maker_fields = .*?qw[\/\(]([^\/\)]+)[\/\)]/;
ok($maker_fields, 'the maker refresh names its columns');
unlike($maker_fields, qr/\bwarranty\b/, 'the refresh does not carry the warranty - the insert must');
unlike($maker_fields, qr/\bproject\b/, 'the refresh does not carry the project');
unlike($maker_fields, qr/\bpos\b/, 'the refresh does not carry the pos');

# ------------------------------------------------------------ the backfill
# Rows written before the fix have no warranty at all, and NULL never expires.
# The backfill reads each app's own warranty spec and applies it from the row's
# own moment; the dry run must write nothing.
{
	package WarrantyRows;
	sub new { my ($class, $rows) = @_; bless { rows => $rows }, $class }
	sub hashes { $_[0]->{'rows'} }
}

my $calendar = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
my $loader   = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($calendar, qr/sub appointment_warranty_backfill\s*\{/, 'the warranty backfill lives in the domain');
like($loader, qr/JawnOS::Domain::Calendar' for qw\([^)]*\bappointment_warranty_backfill\b/,
	'and the loader maps it');

my @rows = (
	{ uuid => 'a', app => 'home',  timestamp => 1_700_000_000_000, server_time => 1_700_000_002_000 },
	{ uuid => 'b', app => 'home',  timestamp => '1700000003000', server_time => '1700000004000' },
	{ uuid => 'c', app => 'weird', timestamp => 1_700_000_000_000, server_time => 1_700_000_002_000 },
);
my @updates;
{
	no warnings 'redefine';
	local *subs::db_query = sub { return WarrantyRows->new(\@rows); };
	local *subs::setting_grabber = sub { return $_[0]->{'app'} eq 'weird' ? 'nonsense' : '-20y'; };
	# the app's spec is read, and the row's own moment anchors it
	local *subs::ago_calc = sub {
		my ($spec, $holder) = @_;
		return undef if $spec eq 'nonsense';
		return $holder + 1_000_000;
	};
	local *subs::db_update = sub { push @updates, [@_]; return 1; };

	my $dry = &subs::appointment_warranty_backfill(0);
	is(scalar @updates, 0, 'the dry run writes nothing');
	is(scalar @{ $dry->{'rows'} }, 2, 'a row whose spec cannot be read is left out');
	is($dry->{'apps'}->{'home'}, 2, 'the report counts the rows per app');

	my $applied = &subs::appointment_warranty_backfill(1);
	is(scalar @updates, 2, 'the apply run writes every row with a readable warranty');
	is($updates[0]->[0], 'appointments', 'into the appointments table');
	is($updates[0]->[1]->{'warranty'}, 1_700_001_002_000, 'anchored on the newest of the row\'s own times');
	is($updates[1]->[1]->{'warranty'}, 1_700_001_004_000, 'and each row reads its own moment');
	is($updates[0]->[2]->{'uuid'}, 'a', 'keyed by the row it repairs');
}

my $script = read_file("$root/scripts/warranty_backfill.pl");
like($script, qr/appointment_warranty_backfill\(\$apply\)/, 'the script runs the shared backfill');
like($script, qr/\(\s*grep \{ \$_ eq '--apply' \} \@ARGV\s*\)/, 'and reads --apply as one grep');

done_testing();
