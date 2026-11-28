# tests-for: lib/JawnOS/Domain/Ai.pm lib/JawnOS/Manager/Part29.pm
# covers:    The spoken appointment loop end to end on the wrist: create stages and
#           holds its id for the next "yes"; a held staged appointment is promoted
#           on yes and discarded on no (and on an unrelated answer); update and
#           delete stage and hold the same way; a bare promote and undo speak their
#           result. The brain claims each of these turns and never asks for a
#           second breath.

use strict;
use warnings;
use utf8;
$| = 1;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

require './perl/help.pl';
require 'JawnOS/Manager/Part29.pm';
require 'JawnOS/Domain/Ai.pm';
&subs::preload($_) for qw(voice_brain voice_card_show voice_funnel_enabled ai_role_models
	ai_role_thinking_effective evaluation_model_call_role guide_resolve_action
	controller_builder watch_reply setting_grabber rightNow unformat_name format_name
	db_update db_select db_insert appt_toggle_checker);

package TestLog;
sub info { }
sub warn { }
sub error { }
package main;

# ------------------------------------------------------------ the harness
my (@replied, @promoted, @staged);
my $next_action = '';
my $confirm_setting = 'on';
my $promote_result = { ok => 1 };
my $undo_result = { ok => 1, summary => 'put back the "dentist" appointment' };
my $stage_update_result = { staged => 'u-upd', summary => 'move the dentist appointment' };
my $stage_delete_result = { staged => 'u-del', summary => 'delete the dentist appointment' };
my @discarded;

my $now = 1_800_000_000_000;
local *subs::rightNow = sub { return $now };

local $subs::log = bless {}, 'TestLog';
local *subs::voice_card_show = sub { };
local *subs::voice_funnel_enabled = sub { 0 };
local *subs::ai_role_models = sub { return ('test-model', '') };
local *subs::ai_role_thinking_effective = sub { 'off' };
local *subs::evaluation_model_call_role = sub { return ($next_action, undef) };
local *subs::guide_resolve_action = sub { return $_[0] };
local *subs::controller_builder = sub { return undef };
local *subs::watch_reply = sub { push @replied, $_[1]; return 1 };
local *subs::setting_grabber = sub {
	my ($h) = @_;
	return $confirm_setting if (($h && $h->{'setting'}) // '') eq 'guide_confirm';
	return '';
};
local *subs::db_update = sub {
	my ($table, $set, $where) = @_;
	push @discarded, { table => $table, set => $set, where => $where }
		if ($table // '') eq 'staged_appointments';
	return 1;
};
local *Manager::guide_stage_appointment = sub {
	my ($c, $params) = @_;
	return { staged => 'u-new', title => 'Dentist', app => 'dentist',
		timestamp => $now + 14_340_000 };
};
local *Manager::guide_promote_staged = sub {
	my ($c, $uuid) = @_;
	push @promoted, $uuid;
	return $promote_result;
};
local *Manager::guide_stage_update = sub {
	my ($c, $params) = @_;
	push @staged, { kind => 'update', params => $params };
	return $stage_update_result;
};
local *Manager::guide_stage_delete = sub {
	my ($c, $params) = @_;
	push @staged, { kind => 'delete', params => $params };
	return $stage_delete_result;
};
local *Manager::guide_undo_appointment = sub { return $undo_result };

sub turn {
	my ($text, $chip) = @_;
	@replied = ();
	return subs::voice_brain($text, { chip_id => ($chip // 'watch-loop'), ts => &subs::rightNow() });
}

# ------------------------------------------------------------ create
$next_action = '{"action":"create","app":"Dentist","title":"Dentist","when":"tomorrow at 3"}';
my $v = turn('make a dentist appointment tomorrow at three');
ok($v && $v->{'handled'}, 'create is claimed');
is($v->{'action'}, 'create', 'the turn is a create');
is($v->{'staged'}, 'u-new', 'the staged id is returned');
like($replied[0] // '', qr/^Staging Dentist at \d{1,2}(:\d\d)?[ap]m, in 3h 59m\. Say yes to save it\.$/,
	'create repeats back the app, its time and how far away it is');
ok(Manager::app_action_pending_peek({ chip_id => 'watch-loop' }),
	'the staged appointment is held for the speaking wrist');

# yes promotes the held staged appointment
@promoted = ();
$v = turn('yes');
ok($v && $v->{'handled'} && $v->{'saved'}, 'a yes saves the held appointment');
is_deeply(\@promoted, ['u-new'], 'the held staged uuid is promoted');
like($replied[0] // '', qr/^Saved Dentist at \d{1,2}(:\d\d)?[ap]m, in 3h 59m\.$/,
	'and speaks the saved appointment and its time');
ok(!Manager::app_action_pending_peek({ chip_id => 'watch-loop' }), 'the hold is gone');

# another wrist's yes does not promote it
$next_action = '{"action":"create","app":"Dentist","title":"Dentist","when":"tomorrow at 3"}';
turn('make a dentist appointment tomorrow at three');
$next_action = '{"action":"say","text":"Noted."}';
@promoted = ();
$v = turn('yes', 'watch-other');
is(scalar @promoted, 0, 'a yes from another wrist does not promote');
ok($v && $v->{'handled'}, 'the other wrist is answered normally');
ok(Manager::app_action_pending_peek({ chip_id => 'watch-loop' }), 'the appointment is still held');

# no discards it
@discarded = ();
$v = turn('no');
ok($v && $v->{'handled'} && $v->{'dropped'}, 'a no leaves the appointment unsaved');
is(scalar @discarded, 1, 'the staged row is marked discarded');
is($discarded[0]{'set'}{'status'}, 'discarded', 'the discard state is written');
is($discarded[0]{'where'}{'uuid'}, 'u-new', 'the held uuid is the one discarded');
like($replied[0] // '', qr/left it unsaved/, 'and says so');

# an unrelated answer drops the hold without promoting
$next_action = '{"action":"create","app":"Dentist","title":"Dentist","when":"tomorrow at 3"}';
turn('make a dentist appointment tomorrow at three');
@promoted = ();
@discarded = ();
$next_action = '{"action":"say","text":"It is clear."}';
$v = turn('what is the weather');
is(scalar @promoted, 0, 'an unrelated answer does not promote');
ok(!Manager::app_action_pending_peek({ chip_id => 'watch-loop' }), 'and the hold is dropped');
ok($v && $v->{'handled'}, 'the unrelated utterance is answered normally');

# The Confirmation Requirement off saves in the same breath.
$confirm_setting = 'off';
$next_action = '{"action":"create","app":"Dentist","title":"Dentist","when":"tomorrow at 3"}';
@promoted = ();
$v = turn('make a dentist appointment tomorrow at three');
ok($v && $v->{'handled'} && $v->{'saved'}, 'with the requirement off create saves at once');
is_deeply(\@promoted, ['u-new'], 'the staged appointment is promoted');
like($replied[0] // '', qr/^Saved Dentist at \d{1,2}(:\d\d)?[ap]m, in 3h 59m\.$/,
	'and speaks the saved appointment and its time');
ok(!Manager::app_action_pending_peek({ chip_id => 'watch-loop' }), 'nothing is held');
$confirm_setting = 'on';

# ------------------------------------------------------------ update and delete
$next_action = '{"action":"update","app":"Dentist","when":"friday at four","duration":"an hour"}';
@staged = ();
$v = turn('move the dentist appointment to friday at four for an hour');
ok($v && $v->{'handled'}, 'update is claimed');
is($v->{'staged'}, 'u-upd', 'update returns the staged id');
is($staged[0]{'kind'}, 'update', 'it stages an update');
is($staged[0]{'params'}{'app'}, 'dentist', 'the app is normalised');
is($staged[0]{'params'}{'when'}, 'friday at four', 'the spoken time reaches the stage');
is($staged[0]{'params'}{'duration'}, 'an hour', 'the spoken duration reaches the stage');
like($replied[0] // '', qr/Say yes to apply it/, 'update says how to apply it');
ok(Manager::app_action_pending_peek({ chip_id => 'watch-loop' }), 'update is held for yes');

$next_action = '{"action":"delete","app":"Dentist","which":"latest"}';
@staged = ();
$v = turn('delete the dentist appointment');
ok($v && $v->{'handled'}, 'delete is claimed');
is($v->{'staged'}, 'u-del', 'delete returns the staged id');
is($staged[0]{'kind'}, 'delete', 'it stages a delete');
like($replied[0] // '', qr/Say yes to apply it/, 'delete says how to apply it');

# A failed stage speaks the reason and holds nothing.
$next_action = '{"action":"update","app":"Dentist"}';
$stage_update_result = { error => 'I could not find that appointment' };
$v = turn('move the dentist appointment');
like($replied[0] // '', qr/could not change it: I could not find/, 'a failed stage names the reason');
ok(!Manager::app_action_pending_peek({ chip_id => 'watch-loop' }), 'nothing is held on a failure');
$stage_update_result = { staged => 'u-upd', summary => 'move the dentist appointment' };

# ------------------------------------------------------------ promote
$next_action = '{"action":"promote","uuid":"u-direct"}';
@promoted = ();
$v = turn('save it');
ok($v && $v->{'handled'}, 'a bare promote is claimed');
is_deeply(\@promoted, ['u-direct'], 'the named staged appointment is promoted');
is($replied[0] // '', 'Saved it.', 'and speaks the save');

$promote_result = { error => 'that appointment is gone' };
$v = turn('save it');
like($replied[0] // '', qr/could not save it: that appointment is gone/, 'a failed promote speaks the reason');
$promote_result = { ok => 1 };

# A promote with no uuid does not act.
@promoted = ();
$next_action = '{"action":"promote"}';
$v = turn('save it');
ok(!($v && $v->{'handled'}), 'a promote without a uuid is not claimed');
is(scalar @promoted, 0, 'and promotes nothing');

# ------------------------------------------------------------ undo
$next_action = '{"action":"undo"}';
$v = turn('undo that');
ok($v && $v->{'handled'}, 'undo is claimed');
is($v->{'action'}, 'undo', 'the turn is an undo');
like($replied[0] // '', qr/Put back the "dentist" appointment/, 'undo speaks the summary');

$undo_result = { error => 'there is nothing to undo' };
$v = turn('undo that');
like($replied[0] // '', qr/I could not undo it: there is nothing to undo/, 'a failed undo speaks the reason');

done_testing();
