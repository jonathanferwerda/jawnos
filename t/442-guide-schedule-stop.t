# tests-for: lib/JawnOS/Manager/Part29.pm
# covers:    a repeat scheduled from a stop row is offered to the writer as a
#           record to insert (a stop has no open session to close), while a
#           scheduled start/record stays a movement and carries no such flag.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;

my $root = "$FindBin::Bin/..";
require "$root/lib/JawnOS/Manager/Part29.pm";

{
	package SchedRows;
	sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
}

my (@written, @dropped);

sub run_schedule {
	my ($type) = @_;
	@written = ();
	@dropped = ();
	no warnings 'redefine';
	no warnings 'once';
	local *subs::pending_schedule_get = sub {
		return { uuid => 'base-' . ($type // 'blank'), app => 'shower', type => $type,
			start => 1_700_000_000_000 };
	};
	local *subs::schedule_from_text = sub { return { dates => [ 1_700_086_400_000 ] } };
	local *subs::pending_schedule_drop = sub { push @dropped, $_[0]; return 1 };
	local *subs::settings_grabber = sub { return { duration => '5m', project => 'shower' } };
	local *subs::time_abbrev_translator = sub { return 300_000 };
	local *subs::db_query = sub { return SchedRows->new([]) };
	local *Manager::appointment_writer = sub {
		my ($c, $row) = @_;
		push @written, { %{$row} };
		return { uuid => $row->{'uuid'} };
	};
	return Manager::guide_apply_schedule(undef, 'tok', 'daily');
}

my $stop = run_schedule('stop');
is($stop->{'ok'}, 1, 'the schedule is applied');
is($stop->{'count'}, 1, 'one repeat is written');
is(scalar @written, 1, 'the writer is called once');
is($written[0]{'type'}, 'stop', 'the repeat keeps the stop type');
ok($written[0]{'completed_row'}, 'and is offered as a record to insert, not a session to close');
is($written[0]{'timestamp'}, 1_700_086_400_000, 'the repeat sits at its scheduled moment');
is($written[0]{'duration'}, 300_000, 'with the app duration');
is($written[0]{'stop_timestamp'}, 1_700_086_400_000 + 300_000, 'and its end');
is($written[0]{'source_uuid'}, 'base-stop', 'linked to the source row');
is_deeply(\@dropped, [ 'tok' ], 'the waiting schedule is consumed');

my $blank = run_schedule('');
is($written[0]{'type'}, 'stop', 'a blank source type is read as the stop it became');
ok($written[0]{'completed_row'}, 'and written as a record');

my $usual = run_schedule('usual');
is($written[0]{'type'}, 'stop', 'the retired usual type repeats as stop');
ok($written[0]{'completed_row'}, 'and is written as a record');

my $start = run_schedule('start');
is($written[0]{'type'}, 'start', 'a start repeat stays a start');
ok(!exists $written[0]{'completed_row'}, 'and stays a movement, not a finished record');
is($written[0]{'duration'}, -300_000, 'with the start sign the writer expects');

done_testing();
