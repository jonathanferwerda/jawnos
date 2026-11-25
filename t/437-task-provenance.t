# tests-for: lib/JawnOS/Domain/Warehouse.pm
# covers:    a task completion carries exact provenance in its row's data, the
#           press time marks the checklist while the row keeps its own moment,
#           nested completions carry the same provenance, and completed=off still
#           removes the appointment

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;

{
	package ProvenanceRows;
	sub new { my ($class, $rows) = @_; bless { rows => $rows }, $class }
	sub hashes { $_[0]->{'rows'} }
}

{
	package ProvenanceCtx;
	sub new { bless {}, shift }
	sub param { return undef }
}

my %lists;
my @appointments;
my @deletes;
my $db_calls = 0;
my $running;

{
	no warnings 'redefine';
	# A checklist is a JSON array in the app's `tasks` setting. Shower owns the
	# washing task; washing owns a nested rinse task.
	local *subs::setting_grabber = sub {
		my ($request) = @_;
		return undef unless ($request->{'setting'} // '') eq 'tasks';
		return encode_json($lists{ $request->{'app'} }) if exists $lists{ $request->{'app'} };
		return undef;
	};
	local *subs::settings_grabber = sub {
		return { colour => '#abc', duration => '5m', worth => '' };
	};
	local *subs::db_query = sub { $db_calls++; return ProvenanceRows->new($running ? [ $running ] : []) };
	local *subs::rightNow = sub { return 9_999_999_999 };
	local *Manager::appointment_writer = sub {
		my ($c, $row) = @_;
		push @appointments, { %{$row} };
		return { uuid => 'written-' . $row->{'app'}, server_time => $row->{'server_time'} };
	};
	local *Manager::delete_app = sub { push @deletes, [ @_ ] ; return 1 };

	# ------------------------------------------------------------ completed on
	$lists{'shower'} = [
		{ uuid => 'tw', task => 'washing', appt => 'on', occurences => 1, duration => '5m',
			colour => '#abc', completed => 'off' },
	];
	$lists{'washing'} = [
		{ uuid => 'nr', task => 'rinse', colour => '#def' },
	];
	$lists{'rinse'} = [
		{ uuid => 'nr', task => 'rinse_again', appt => 'on', occurences => 1, duration => '5m',
			colour => '#def', completed => 'off' },
	];
	$running = { uuid => 'open-session' };

	my $result = &subs::task_writer(ProvenanceCtx->new, {
		papp => 'shower',
		app => 'shower',
		timestamp => 1_700_000_100_000,
		uuid => 'tw',
		name => 'completed',
		value => 'on',
		colour => '#abc',
		project => 'p1',
		account => 'a1',
		movement => 'm1',
		server_time => 1_700_000_000_000,
		completed_at => 1_699_999_000_000,
		quiet_child => 1,
	});

	my %appt = map { $_->{'app'} => $_ } @appointments;
	ok($appt{'washing'}, 'the task app wrote its appointment');
	my $provenance = decode_json($appt{'washing'}{'data'});
	is_deeply($provenance, { task_list => 'shower', task => 'washing', task_uuid => 'tw' },
		'the row names the checklist, the task and the entry that completed it');
	is($appt{'washing'}{'type'}, 'usual', 'the task row is still a usual row');
	is($appt{'washing'}{'source'}, 'task', 'and still says a task wrote it');
	is($appt{'washing'}{'timestamp'}, 1_700_000_100_000, 'the row keeps its own moment');
	ok($appt{'washing'}{'quiet_child'}, 'the row is written as a quiet child');

	my ($washing) = grep { $_->{'uuid'} eq 'tw' } @{$result};
	is($washing->{'completed'}, 'on', 'the checklist entry is completed');
	is($washing->{'last_completed'}, 1_699_999_000_000, 'the checklist is marked at the press, not at the row time');
	is($washing->{'last_appt_uuid'}, 'written-washing', 'and remembers the appointment it wrote');
	is($appt{'washing'}{'source_uuid'}, 'open-session', 'without a parent the row links to the open session on this machine');

	# A nested completion carries the same provenance. The recursive call names
	# the nested entry's own list owner, so the row it writes is rinse_again.
	ok($appt{'rinse_again'}, 'the nested task wrote its appointment too');
	my $nested = decode_json($appt{'rinse_again'}{'data'});
	is_deeply($nested, { task_list => 'shower', task => 'rinse_again', task_uuid => 'nr' },
		'the nested completion names the same checklist and its own entry');
	ok($appt{'rinse_again'}{'quiet_child'}, 'and is quiet as well');

	# An explicit parent links the task to the usual row that replayed it, and
	# the open-session query is not asked at all.
	@deletes = ();
	@appointments = ();
	$db_calls = 0;
	$running = { uuid => 'open-session' };
	$lists{'shower'} = [
		{ uuid => 'tw', task => 'washing', appt => 'on', occurences => 1, duration => '5m',
			colour => '#abc', completed => 'off' },
	];
	$lists{'washing'} = [];
	&subs::task_writer(ProvenanceCtx->new, {
		papp => 'shower',
		app => 'shower',
		timestamp => 1_700_000_150_000,
		uuid => 'tw',
		name => 'completed',
		value => 'on',
		server_time => 1_700_000_050_000,
		completed_at => 1_699_999_500_000,
		parent_uuid => 'usual-parent',
		quiet_child => 1,
	});
	is($appointments[0]{'source_uuid'}, 'usual-parent', 'an explicit parent links the task row to the usual row');
	is($db_calls, 0, 'and the open-session query is skipped');

	# ----------------------------------------------------------- completed off
	@deletes = ();
	@appointments = ();
	$lists{'shower'} = [
		{ uuid => 'tw', task => 'washing', appt => 'on', occurences => 1, duration => '5m',
			colour => '#abc', completed => 'on', last_appt_uuid => 'old-uuid',
			server_time => '1234567890123' },
	];
	$lists{'washing'} = [];
	&subs::task_writer(ProvenanceCtx->new, {
		papp => 'shower',
		app => 'shower',
		timestamp => 1_700_000_200_000,
		uuid => 'tw',
		name => 'completed',
		value => 'off',
		server_time => 1_700_000_200_000,
	});
	is(scalar @appointments, 0, 'unchecking writes no appointment');
	is(scalar @deletes, 1, 'unchecking removes the appointment the task last wrote');
	is_deeply($deletes[0], [ 'washing', 'old-uuid', '1234567890123', 'task' ],
		'through the task app, the last row and the reason the register knows');

	# ------------------------------------------------------- no press time given
	@deletes = ();
	@appointments = ();
	$lists{'shower'} = [
		{ uuid => 'tw', task => 'washing', appt => 'on', occurences => 1, duration => '5m',
			colour => '#abc', completed => 'off' },
	];
	$lists{'washing'} = [];
	my $undated = &subs::task_writer(ProvenanceCtx->new, {
		papp => 'shower',
		app => 'shower',
		timestamp => 1_700_000_300_000,
		uuid => 'tw',
		name => 'completed',
		value => 'on',
		server_time => 1_700_000_300_000,
	});
	my ($entry) = grep { $_->{'uuid'} eq 'tw' } @{$undated};
	is($entry->{'last_completed'}, 9_999_999_999, 'without a press time the checklist is marked now');
}

done_testing();
