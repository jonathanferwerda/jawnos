# tests-for: lib/JawnOS/Manager/Part05.pm
# covers:    a row written by appointment_writer carries its warranty, project and pos from the moment it is inserted, not from a later refresh that omits them

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

done_testing();
