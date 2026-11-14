# tests-for: lib/JawnOS/Manager/Part15.pm lib/JawnOS/Controller/manager_configure3.pm
# covers:    Recording a measure or editing its definition must tolerate an older
#            app_measures row that carries a bare reading instead of a hash.

use strict;
use warnings;
use utf8;

no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource qw(repo_root);
use Mojo::JSON qw(decode_json encode_json);

my $root = repo_root();
require $root . '/lib/JawnOS/Manager/Part15.pm';
require $root . '/lib/JawnOS/Controller/manager_configure3.pm';

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
	return bless { params => $params, rendered => undef }, $class;
}

sub param {
	my ($self, $name) = @_;
	return $self->{'params'}->{$name};
}

sub render_to_string {
	return '';
}

sub render {
	my ($self, @args) = @_;
	$self->{'rendered'} = \@args;
	return '';
}

package main;

my %written;
my $appt_rows = [];
my $bare = '{"intensity":"21","polarity":"0"}';

{
	no warnings 'redefine';
	*subs::setting_setter = sub {
		my $d = shift;
		$written{$d->{'app'} . '/' . $d->{'setting'}} = $d->{'value'};
	};
	*subs::settings_grabber = sub {
		return {
			app_measures => $bare,
			duration => '4h 54m',
			seen_measures => '[]',
		};
	};
	*subs::setting_grabber = sub {
		my $d = shift;
		return $bare if ($d->{'setting'} // '') eq 'app_measures';
		return '{}';
	};
	*subs::db_select = sub { return FakeResult->new([ { warranty => '', measures => '' } ]) };
	*subs::db_update = sub { };
	*subs::db_query = sub { return FakeResult->new($appt_rows) };
	*subs::rightNow = sub { return 1800000000000 };
	*subs::unformat_name = sub { return defined $_[0] ? "$_[0]" : '' };
	*subs::format_name = sub { return defined $_[0] ? "$_[0]" : '' };
	*subs::web_measure_number = sub { return $_[0] };
	*subs::intelligent_automation_toggle = sub { };
	*Manager::appt_measure_action = sub { };
	*Manager::log_reader = sub { return { depressed => { setting => { app_measures => '{"intensity":{}}' } } } };
	*Websocket::send = sub { };
	*Websocket::console_command = sub { return '' };
}

subtest 'recording a reading onto a bare app_measures entry' => sub {
	my $c = FakeController->new({});
	my $uuid = eval {
		Manager::appt_measure_writer($c, {
			app => 'depressed',
			measure => 'intensity',
			value => '42',
			timestamp => 1800000000000,
			uuid => 'u1',
			source => 'web',
		});
	};
	is($@, '', 'the writer does not die');
	is($uuid, 'u1', 'the reading still lands on the appointment');

	my $am = eval { decode_json $written{'depressed/app_measures'} };
	ok(ref $am->{'intensity'} eq 'HASH', 'the recorded measure becomes a definition hash');
	is($am->{'intensity'}->{'value'}, '42', 'the new reading is stored on the definition');
	is($am->{'polarity'}, '0', 'an unrelated bare entry is left alone');
};

subtest 'editing a definition on a bare app_measures entry' => sub {
	my $c = FakeController->new({
		app => 'depressed',
		measure => 'intensity',
		setting => 'unit',
		value => 'belief',
		oldvalue => 'intensity',
	});
	my $ok = eval { Manager::action_17694($c); 1 };
	is($@, '', 'the configurator does not die');

	my $am = eval { decode_json $written{'depressed/app_measures'} };
	ok(ref $am->{'intensity'} eq 'HASH', 'the edited measure becomes a definition hash');
	is($am->{'intensity'}->{'unit'}, 'belief', 'the new setting is stored');
};

subtest 'renaming a bare app_measures entry' => sub {
	$appt_rows = [ { uuid => 'u1', app => 'depressed', measures => '[{"intensity":"7"}]' } ];
	my $c = FakeController->new({
		app => 'depressed',
		measure => 'intensity',
		setting => 'measure',
		value => 'severity',
		oldvalue => 'intensity',
	});
	my $ok = eval { Manager::action_17694($c); 1 };
	is($@, '', 'the rename does not die');

	my $am = eval { decode_json $written{'depressed/app_measures'} };
	ok(ref $am->{'severity'} eq 'HASH', 'the renamed measure is a definition hash');
	ok(!exists $am->{'intensity'}, 'the old bare key is gone');
};

done_testing();
