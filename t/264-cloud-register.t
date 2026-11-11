# tests-for: lib/JawnOS/Controller/manager_folders2.pm
# covers:    A peer's CloudSync register unions into this machine's own device
#            list. A peer can add a device but never removes one the person
#            registered; duplicates, entries with no uuid and this machine's own
#            signatorial are dropped, and the stored path/base come from the
#            route's destination.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use Mojo::JSON qw(encode_json);
use JawnOSTest;

require(root() . '/lib/JawnOS/Controller/manager_folders2.pm');

my $test_home = tempdir(CLEANUP => 1);
$ENV{'HOME'} = $test_home;
# run_tests may have asked home() before this file set HOME.
$subs::home_dir = $test_home;

# The registration list is a cache row; start from no row at all.
subs::cache_delete({ app => 'folders', context => 'cloud_sync' });

my $self = subs::signatorial_designer();
ok(defined $self && length $self, 'this machine has a signatorial');

{
	package CloudRegisterController;
	sub new {
		my ($class, %args) = @_;
		return bless {
			param   => $args{'param'}   || {},
			stash   => $args{'stash'}   || {},
			session => $args{'session'} || {
				authentication => 'approved',
				app_until      => subs::rightNow() + 3_600_000,
			},
			rendered => undef,
		}, $class;
	}
	sub param   { return $_[0]->{'param'}->{ $_[1] } }
	sub stash   { return $_[0]->{'stash'}->{ $_[1] } }
	sub session { return $_[0]->{'session'}->{ $_[1] } }
	sub render {
		my ($self, @args) = @_;
		my %args = @args;
		$self->{'rendered'} = $args{'json'};
		return 1;
	}
	sub reply { return $_[0]->{'rendered'} }
}

{
	package CloudRegisterMinion;
	sub new { return bless { enqueued => [] }, shift }
	sub enqueue {
		my ($self, @args) = @_;
		push @{ $self->{'enqueued'} }, \@args;
		return 'job-' . scalar @{ $self->{'enqueued'} };
	}
}

sub destination { return subs::cloud_sync_destination({ base => $_[0], path => '' }) }
sub registration { return subs::cloud_sync_registration_for( destination($_[0])->{'root'} ) }

sub seed_registration {
	my ($base, $devices, $added) = @_;
	my $dest = destination($base);
	subs::cloud_sync_registrations_modify(sub {
		my $list = shift;
		@{$list} = grep { ($_->{'path'} || '') ne $dest->{'root'} } @{$list};
		push @{$list}, {
			path    => $dest->{'root'},
			base    => $base,
			devices => $devices,
			added   => $added,
		};
		return 1;
	});
}

# Calls the route action the way a peer's POST does, with the peer gate and the
# job queue stood in for: neither is the rule under test, and the real queue
# would write under ~/.president.
sub run_register {
	my (%args) = @_;
	my $minion = $args{'minion'} || CloudRegisterMinion->new;
	my $c = CloudRegisterController->new(
		param => {
			base    => $args{'base'},
			members => encode_json($args{'members'} || []),
			%{ $args{'extra_params'} || {} },
		},
	);
	{
		no warnings 'redefine';
		no warnings 'once';
		local *Manager::archive_peer_allowed = sub { 1 };
		local *subs::minion_grabber = sub { $minion };
		Manager::action_30715($c);
	}
	return ($c->reply, $minion);
}

# ---- a peer's subset keeps every device the person registered ---------------
my $base_keep = 'cloud-register-keep';
seed_registration($base_keep, [
	{ uuid => 'reg-keep-a1', hostname => 'A One', signatorial => 'sig-keep-a1' },
	{ uuid => 'reg-keep-a2', hostname => 'A Two', signatorial => 'sig-keep-a2' },
	{ uuid => 'reg-keep-a3', hostname => 'A Three' },
], 111);
my ($keep_reply) = run_register(
	base    => $base_keep,
	members => [ { uuid => 'reg-keep-a2' } ],
);
my $keep = registration($base_keep);
my $keep_dest = destination($base_keep);
my %keep_device = map { $_->{'uuid'} => $_ } @{ $keep->{'devices'} };
is($keep_reply->{'status'}, 'ok', 'the peer registration answers ok');
is($keep_reply->{'path'}, $keep_dest->{'root'}, 'and names the destination root');
is(scalar keys %keep_device, 3, 'the peer kept the two devices it did not name');
ok($keep_device{'reg-keep-a1'} && $keep_device{'reg-keep-a3'}, 'the local extras survive');
is($keep_device{'reg-keep-a2'}->{'hostname'}, 'A Two',
	'the local hostname survives a peer that sent only a uuid');
is($keep_device{'reg-keep-a2'}->{'signatorial'}, 'sig-keep-a2',
	'and so does the local signatorial');
is($keep->{'added'}, 111, 'added is preserved from the local registration');
is($keep_reply->{'kept'}, 2, 'the reply counts the devices the peer did not name');
is($keep_reply->{'added'}, 0, 'and the devices it did');

# ---- a new device is added --------------------------------------------------
my $base_add = 'cloud-register-add';
seed_registration($base_add, [
	{ uuid => 'reg-add-b1', hostname => 'B One', signatorial => 'sig-add-b1' },
], 222);
my ($add_reply, $add_minion) = run_register(
	base    => $base_add,
	members => [ { uuid => 'reg-add-b1' }, { uuid => 'reg-add-b2', hostname => 'B Two' } ],
);
my $add = registration($base_add);
my %add_device = map { $_->{'uuid'} => $_ } @{ $add->{'devices'} };
is(scalar keys %add_device, 2, 'the new device is added beside the registered one');
ok($add_device{'reg-add-b2'}, 'the device the peer named is registered');
is($add->{'added'}, 222, 'the local added time is still the one stored');
is($add_reply->{'added'}, 1, 'the reply counts the one new device');
is(scalar @{ $add_minion->{'enqueued'} }, 1, 'a new device gets one seed job');
is($add_minion->{'enqueued'}->[0]->[1]->[0]->{'devices'}->[0]->{'uuid'}, 'reg-add-b2',
	'and the seed job is for the new device only');

# ---- duplicates, no-uuid rows and this machine are dropped ------------------
my $base_dedupe = 'cloud-register-dedupe';
seed_registration($base_dedupe, [
	{ uuid => 'reg-dedupe-c1', hostname => 'C One' },
	{ uuid => 'reg-dedupe-c1', hostname => 'C One again' },
	{ hostname => 'no uuid' },
	{ uuid => 'self', hostname => 'me' },
	{ uuid => 'reg-dedupe-self', hostname => 'me too', signatorial => $self },
], 333);
my ($dedupe_reply) = run_register(
	base    => $base_dedupe,
	members => [
		{ uuid => 'reg-dedupe-c2', hostname => 'C Two' },
		{ uuid => 'reg-dedupe-c2', hostname => 'C Two again' },
		{ hostname => 'no uuid incoming' },
		{ uuid => 'reg-dedupe-self-sig', hostname => 'self by signatorial', signatorial => $self },
		{ uuid => 'self', hostname => 'me' },
	],
);
my $dedupe = registration($base_dedupe);
my @dedupe_uuids = sort map { $_->{'uuid'} || '' } @{ $dedupe->{'devices'} };
is_deeply(\@dedupe_uuids, [ 'reg-dedupe-c1', 'reg-dedupe-c2' ],
	'one row per uuid, with no empty uuid and nothing for this machine');
is($dedupe_reply->{'devices'}, 2, 'the reply counts the two stored devices');

# ---- the stored path and base are the route's destination -------------------
my $base_dest = 'cloud-register-dest';
my ($dest_reply) = run_register(
	base         => $base_dest,
	members      => [ { uuid => 'reg-dest-d1', hostname => 'D One' } ],
	extra_params => { path => '../../etc' },
);
my $dest_reg = registration($base_dest);
my $dest_here = destination($base_dest);
is($dest_reg->{'path'}, $dest_here->{'root'},
	'the stored path is the destination root, not a caller-supplied path');
is($dest_reg->{'base'}, $base_dest, 'the stored base is the route base');
unlike($dest_reg->{'path'}, qr{^/etc}, 'the caller cannot steer the registration outside home');

# ---- a registration that does not exist is created as the caller lists it ---
my $base_new = 'cloud-register-new';
my ($new_reply) = run_register(
	base    => $base_new,
	members => [
		{ uuid => 'reg-new-e1', hostname => 'E One', signatorial => 'sig-new-e1' },
		{ uuid => 'reg-new-e2', hostname => 'E Two' },
	],
);
my $new = registration($base_new);
my @new_uuids = map { $_->{'uuid'} } @{ $new->{'devices'} };
is_deeply(\@new_uuids, [ 'reg-new-e1', 'reg-new-e2' ],
	'the new registration is exactly the caller list');
is($new->{'base'}, $base_new, 'with the route base');
is($new->{'path'}, destination($base_new)->{'root'}, 'and the destination root');
ok(!exists $new->{'starting'}, 'and no starting marker was invented');
ok($new->{'added'} > 0, 'the new registration gets an added time');
is($new_reply->{'status'}, 'ok', 'the new registration answers ok');

done_testing();
