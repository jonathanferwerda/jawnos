# tests-for: lib/JawnOS/Manager/Part16.pm
# covers:    An app_measures entry that is a bare reading (the older shape) must
#            not break /manager/inventory/details; only a definition hash has a unit.

use strict;
use warnings;
use utf8;

no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource qw(repo_root);

my $part16 = repo_root() . '/lib/JawnOS/Manager/Part16.pm';
require $part16;

# inventory_details reads its settings through the app's helpers and renders the
# panel through the controller. This test answers just those calls, so the
# measure-definition walk runs on the real sub with the shape the live
# "depressed" row carries: a definition for speed and bare readings for intensity
# and polarity.
$gb::budget_modes = {
	duration => {}, occurences => {}, total => {}, quantity => {},
};

package FakeResult;

sub new {
	my ($class, $rows) = @_;
	return bless { rows => $rows }, $class;
}

sub hashes {
	my $self = shift;
	return [ map { { %{$_} } } @{$self->{'rows'}} ];
}

package FakeController;

sub new {
	my ($class, $params) = @_;
	return bless { params => $params, rendered => {} }, $class;
}

sub param {
	my ($self, $name) = @_;
	return $self->{'params'}->{$name};
}

sub render_to_string {
	my ($self, %args) = @_;
	$self->{'rendered'} = { %args };
	return '';
}

package main;

{
	no warnings 'redefine';
	*subs::rightNow = sub { 1794608000000 };
	*subs::setting_setter = sub { };
	*subs::settings_grabber = sub { return {} };
	*subs::setting_grabber = sub { return undef };
	*subs::db_query = sub {
		return FakeResult->new([
			{
				app => 'depressed', type => 'start', timestamp => 1794604400000,
				duration => 0, stop_timestamp => 1794606200000, total => 0,
				measures => '', unit => '', quantity => 0, uuid => 'u1',
				server_time => 1794604400000,
			},
			{
				app => 'depressed', type => 'stop', timestamp => 1794606200000,
				duration => 0, total => 0, measures => '', unit => '',
				quantity => 0, uuid => 'u2', server_time => 1794606200000,
			},
		]);
	};
	*subs::format_name = sub { return defined $_[0] ? "$_[0]" : '' };
	*subs::unformat_name = sub { return defined $_[0] ? "$_[0]" : '' };
	*subs::time_scope_page = sub { return ('this', 'last') };
	*subs::duration_sayer = sub { return '' };
	*subs::time_abbrev_translator = sub { return $_[0] };
	*subs::timespan_widener = sub { return defined $_[0] ? "$_[0]" : '' };
	*subs::cache_get = sub { return {} };
	*subs::cache_set = sub { };
	*subs::random_string_creator = sub { return 'random' };
	*subs::appt_header_printer = sub { };
	*Manager::father_time = sub { return (0, 4000000000000) };
	*Manager::appointment_overlap = sub {
		my ($a, $begin, $end) = @_;
		my $start = $a->{'timestamp'} || 0;
		my $finish = $start + abs($a->{'duration'} || 0);
		my $from = $start > $begin ? $start : $begin;
		my $to = $finish < $end ? $finish : $end;
		return $to > $from ? $to - $from : 0;
	};
	*Manager::budget_calculator = sub { return {} };
	*Manager::budget_status_maker = sub { return $_[0] };
	*Manager::allocation_duration_add = sub { };
	*Manager::formula_calculator = sub { return ('', 0, '', '') };
	*Websocket::send = sub { };
}

my $c = FakeController->new({
	app => 'depressed',
});

my $settings = {
	app_measures => '{"intensity":"21","polarity":"0","speed":{"type":"number","unit":"km\/h"}}',
	s_display => 'duration',
	s_visual => 'historical',
	s_calc => 'sum',
	s_lock => 'on',
	s_scope_count => 30,
	s_movement => '["all"]',
	unit => 'belief',
};

my $returner = eval { Manager::inventory_details($c, $settings) };
is($@, '', 'a bare measure reading does not stop the details call');
ok(ref $returner eq 'HASH', 'the call returns the details payload');

my $options = $c->{'rendered'}->{'display_options'} || [];
my ($intensity) = grep { $_->{'name'} eq 'intensity' } @{$options};
my ($polarity) = grep { $_->{'name'} eq 'polarity' } @{$options};
my ($speed) = grep { $_->{'name'} eq 'speed' } @{$options};
ok($intensity, 'the bare reading is still offered as a display option');
is($intensity->{'formatted_name'}, 'intensity', 'a bare reading has no unit to show');
ok($polarity, 'a second bare reading is offered too');
ok($speed, 'the definition hash is offered as a display option');
is($speed->{'formatted_name'}, 'speed (km/h)', 'a definition hash keeps its unit');

done_testing();
