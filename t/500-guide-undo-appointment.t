# tests-for: lib/JawnOS/Manager/Part29.pm lib/JawnOS/Controller/manager_help.pm
# covers:    One undo for the Guide's route and for the wrist: undoing a delete puts
#           the whole saved row back; undoing a change restores every field it moved;
#           an empty stack, a missing row or a delete with no saved row is an error,
#           not a silent success.

use strict;
use warnings;
use utf8;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

require 'JawnOS/Manager/Part29.pm';
&subs::preload($_) for qw(setting_grabber setting_setter rightNow format_name
	appt_toggle_checker db_insert db_update db_select);

package TRes;
sub hash { return $_[0]->{'row'} }
package main;

my (@inserted, @updated, @toggled, @refreshed);
my $select_row;
my $stack = '[]';

local *subs::setting_grabber = sub { return $stack };
local *subs::setting_setter = sub {
	my ($h) = @_;
	$stack = $h->{'value'} if (($h && $h->{'setting'}) // '') eq 'guide_undo';
};
local *subs::rightNow = sub { return 1700000000000 };
local *subs::db_insert = sub { push @inserted, { $_[0] => { %{ $_[1] } } }; return 1 };
local *subs::db_update = sub {
	my ($table, $set, $where) = @_;
	push @updated, { table => $table, set => { %{$set} }, where => { %{$where} } };
	return 1;
};
local *subs::db_select = sub { return bless({ row => $select_row }, 'TRes') };
local *subs::appt_toggle_checker = sub { push @toggled, $_[0] };
local *Manager::guide_refresh_app = sub { push @refreshed, [ @_ ] };

sub reset_all {
	@inserted = (); @updated = (); @toggled = (); @refreshed = ();
	$select_row = undef;
	$stack = '[]';
}

# ------------------------------------------------------------ empty stack
reset_all();
my $r = Manager::guide_undo_appointment(undef);
ok(!$r->{'ok'}, 'an empty stack is not a success');
like($r->{'error'} // '', qr/nothing to undo/, 'and says there is nothing to undo');

# ------------------------------------------------------------ undo a delete
reset_all();
Manager::guide_undo_push({
	kind => 'delete', app => 'dentist', uuid => 'u1',
	row => { uuid => 'u1', app => 'dentist', timestamp => 123, notes => 'filling' },
});
$r = Manager::guide_undo_appointment(undef);
ok($r->{'ok'}, 'undoing a delete succeeds');
is(scalar @inserted, 1, 'the saved row is inserted once');
is($inserted[0]{'appointments'}{'uuid'}, 'u1', 'the same uuid comes back');
is($inserted[0]{'appointments'}{'timestamp'}, 123, 'the original time comes back');
is($inserted[0]{'appointments'}{'notes'}, 'filling', 'the original notes come back');
is($inserted[0]{'appointments'}{'server_time'}, 1700000000000, 'the insert is stamped now');
is_deeply(\@toggled, ['dentist'], 'the app toggle is checked again');
is(scalar @refreshed, 1, 'the app is redrawn');
like($r->{'summary'} // '', qr/put back the "Dentist" appointment/i, 'the summary names what came back');

# A delete with no saved row is an error.
reset_all();
Manager::guide_undo_push({ kind => 'delete', app => 'dentist', uuid => 'u2', row => {} });
$r = Manager::guide_undo_appointment(undef);
ok(!$r->{'ok'}, 'a delete with no saved row fails');
like($r->{'error'} // '', qr/nothing to put back/, 'and says so');

# ------------------------------------------------------------ undo a change
reset_all();
$select_row = { uuid => 'u3', app => 'dentist' };
Manager::guide_undo_push({
	app => 'dentist', uuid => 'u3', title => 'move the "Dentist" appointment',
	timestamp => 900, duration => 1800000, notes => 'before',
	seen => 0, stop_seen => 1, type => 'usual', stop_timestamp => 950,
});
$r = Manager::guide_undo_appointment(undef);
ok($r->{'ok'}, 'undoing a change succeeds');
is(scalar @updated, 1, 'the appointment is updated once');
my $set = $updated[0]{'set'};
is($set->{'timestamp'}, 900, 'the old time is restored');
is($set->{'duration'}, 1800000, 'the old duration is restored');
is($set->{'notes'}, 'before', 'the old notes are restored');
is($set->{'seen'}, 0, 'the seen flag is restored');
is($set->{'stop_seen'}, 1, 'the stop_seen flag is restored');
is($set->{'type'}, 'usual', 'the type is restored');
is($set->{'stop_timestamp'}, 950, 'the stop time is restored');
is($set->{'server_time'}, 1700000000000, 'the update is stamped now');
is_deeply($updated[0]{'where'}, { uuid => 'u3', app => 'dentist' }, 'the update names the exact row');
is($r->{'summary'}, 'move the "Dentist" appointment', 'the summary is the change it undid');

# A field the record does not carry is left alone.
reset_all();
$select_row = { uuid => 'u4', app => 'dentist' };
Manager::guide_undo_push({ app => 'dentist', uuid => 'u4', timestamp => 1000 });
$r = Manager::guide_undo_appointment(undef);
ok($r->{'ok'}, 'a change with only a time still undoes');
ok(!exists $updated[0]{'set'}{'notes'}, 'an absent field is not written');
ok(!exists $updated[0]{'set'}{'type'}, 'and neither is an absent type');

# The row is gone.
reset_all();
Manager::guide_undo_push({ app => 'dentist', uuid => 'u5', timestamp => 1000 });
$r = Manager::guide_undo_appointment(undef);
ok(!$r->{'ok'}, 'a missing appointment fails the undo');
like($r->{'error'} // '', qr/appointment is gone/, 'and says so');
is(scalar @updated, 0, 'nothing is written');

done_testing();
