# tests-for: lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Domain/Embedded.pm lib/JawnOS/Domain/Loader.pm
# covers:    a phone call row is written locally and the peers are asked to pull
#           it now; the announcement is once per request, stays quiet on a
#           relayed copy, and fires after ring, ignore, log and end/miss.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

my $root = repo_root();
require "$root/lib/JawnOS/Domain/Embedded.pm";
require "$root/lib/JawnOS/Controller/manager_phone.pm";

{
	package PhoneCtx;
	sub new {
		my ($class, $params) = @_;
		return bless { params => { %{ $params || {} } }, stash => {}, rendered => undef }, $class;
	}
	sub param {
		my ($self, $key, $value) = @_;
		if (@_ > 2) { $self->{'params'}{$key} = $value; return $value }
		return $self->{'params'}{$key};
	}
	sub stash {
		my ($self, $key, $value) = @_;
		if (@_ > 2) { $self->{'stash'}{$key} = $value; return $value }
		return $self->{'stash'}{$key};
	}
	sub render {
		my ($self, %opt) = @_;
		$self->{'rendered'} = \%opt;
		return 1;
	}
}

{
	package PhoneRows;
	sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
	sub hash { return $_[0]->{'rows'}[0] }
}

# --- the announcement helper ------------------------------------------------
{
	my @forks;
	{
		no warnings 'redefine';
		local *subs::subprocessor = sub {
			my ($cb, $opt) = @_;
			push @forks, ($opt->{'name'} || '');
			return 1;
		};

		my $ctx = PhoneCtx->new;
		ok(&subs::remote_available_announce_action($ctx), 'a plain action asks the peers to pull');
		is(scalar @forks, 1, 'with one forked announcement');
		ok(!&subs::remote_available_announce_action($ctx), 'the same request does not ask a second time');
		is(scalar @forks, 1, 'still one announcement');

		foreach my $relayed ( { relay_id => 'r' }, { remoted => 'yes' },
			{ dissemination => 'yes' }, { source_signatorial => 'abc' } ) {
			my $copy = PhoneCtx->new($relayed);
			ok(!&subs::remote_available_announce_action($copy),
				'a relayed copy stays quiet (' . join(',', sort keys %{$relayed}) . ')');
		}
		is(scalar @forks, 1, 'a relayed copy forks nothing');
	}

	my @announced;
	{
		no warnings 'redefine';
		local *subs::subprocessor = sub { my ($cb) = @_; $cb->(); return 1 };
		local *subs::remote_available_announce = sub { push @announced, 1; return 0 };
		my $ctx = PhoneCtx->new;
		&subs::remote_available_announce_action($ctx);
		is(scalar @announced, 1, 'the forked announcement runs the house announce');
	}
}

# --- each call event asks after its write -----------------------------------
my (@announced, @written, @updates);
my $fail_write = 0;
{
	no warnings 'redefine';
	no warnings 'once';
	local *Manager::timestamp_adjuster = sub { return 1_700_000_000_000 };
	local *Manager::appointment_writer = sub {
		my ($c, $row) = @_;
		push @written, { %{$row} };
		return $fail_write ? {} : { uuid => 'row-' . scalar(@written), server_time => 1_700_000_000_000 };
	};
	local *subs::remote_available_announce_action = sub { push @announced, $_[0]; return 1 };
	local *subs::rightNow = sub { return 1_700_000_000_000 };
	local *subs::phone_number_app = sub { return 'phone' };
	local *subs::phone_call_transcript_note = sub { return 1 };
	local *subs::db_update = sub { push @updates, { set => { %{$_[1]} }, where => { %{$_[2]} } }; return 1 };
	local *subs::db_query = sub { return PhoneRows->new([]) };
	local *subs::db_select = sub {
		return PhoneRows->new([ { uuid => 'open-1', app => 'phone', timestamp => 1_699_999_999_000 } ]);
	};

	my $run = sub {
		my (@args) = @_;
		@announced = ();
		@written = ();
		@updates = ();
		my $ctx = PhoneCtx->new({ @args });
		Manager::action_24636($ctx);
		return $ctx;
	};

	my $ring = $run->(event => 'ring', number => '5550100', direction => 'incoming');
	is($ring->{'rendered'}{'json'}{'ok'}, 1, 'ring writes a call row');
	is(scalar @announced, 1, 'ring asks the peers to pull it');

	my $ignore = $run->(event => 'ignore', number => '5550100');
	is($ignore->{'rendered'}{'json'}{'ok'}, 1, 'ignore writes the refused call');
	is(scalar @announced, 1, 'ignore asks the peers to pull it');

	my $log = $run->(event => 'log', number => '5550100', started => 1_699_999_999_000,
		ended => 1_700_000_010_000, answered => 'yes', direction => 'incoming');
	is($log->{'rendered'}{'json'}{'ok'}, 1, 'log files the whole call');
	is(scalar @announced, 1, 'log asks the peers to pull it');

	my $end = $run->(event => 'end', uuid => 'open-1');
	is($end->{'rendered'}{'json'}{'ok'}, 1, 'end closes the call');
	is(scalar @announced, 1, 'end asks the peers to pull it');

	my $miss = $run->(event => 'miss', uuid => 'open-1');
	is($miss->{'rendered'}{'json'}{'ok'}, 1, 'miss cancels the call');
	is(scalar @announced, 1, 'miss asks the peers to pull it');

	my $unknown = $run->(event => 'nonsense');
	is($unknown->{'rendered'}{'json'}{'ok'}, 0, 'an unknown event writes nothing');
	is(scalar @announced, 0, 'and asks nobody to pull');

	$fail_write = 1;
	my $failed = $run->(event => 'ring', number => '5550100');
	is($failed->{'rendered'}{'json'}{'ok'}, 0, 'a ring with no row is refused');
	is(scalar @announced, 0, 'and no pull is asked for');
	$fail_write = 0;
}

# The action has to call the helper in every branch that writes a row.
my $phone = read_file("$root/lib/JawnOS/Controller/manager_phone.pm");
my $calls = () = $phone =~ /&subs::remote_available_announce_action\(\$c\);/g;
is($calls, 4, 'ring, ignore, log and end/miss each announce after their write');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/\bremote_available_announce_action\b/, 'the announcement helper is mapped in the domain loader');

done_testing();
