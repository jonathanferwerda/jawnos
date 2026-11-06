# tests-for: lib/JawnOS/Domain/Render.pm lib/JawnOS/Domain/Edt.pm
# covers:    A watch pin whose command names a machine reaches that machine even
#            while the roster still calls it inactive: a phone hears no LAN
#            beacons, so the cached connection flag can be minutes stale.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;
use JawnOSTest;

# --- a stand-in peer agent ---------------------------------------------------
# Only the chain destination_relay uses: connect_timeout(...)->inactivity_timeout
# (...), then insecure(1)->post(url => form => {...})->result.
{
	package FakeUA;
	sub new { bless { posted => [] }, shift }
	sub connect_timeout    { return $_[0] }
	sub inactivity_timeout { return $_[0] }
	sub insecure           { return $_[0] }
	sub post {
		my ($self, $url, $how, $form) = @_;
		push @{$self->{'posted'}}, { url => $url, form => { %{$form || {}} } };
		return bless {}, 'FakeTx';
	}
}
{
	package FakeTx;
	sub result { return bless {}, 'FakeRes' }
}
{
	package FakeRes;
	sub is_success { return 1 }
}

my $PEER_SIG = 'peer-sig-0001';
my $ua = FakeUA->new;
my @lister_calls;

{
	no warnings 'redefine';
	local *subs::remote_machine_lister = sub {
		my $args = shift || {};
		push @lister_calls, { %{$args} };
		my @rows = ({
			signatorial => $PEER_SIG,
			hostname    => 'Laptop',
			device      => 'computer',
			connection  => 'inactive',
			ip          => '192.168.1.123',
			manager     => 'https://192.168.1.123:45545',
			port        => 45545,
			tunnel      => 'no',
		});
		# Honour the filters the real lister applies, so an `active`-only lookup
		# really finds nothing here.
		@rows = grep { ($_->{'connection'} || '') eq $args->{'connection'} } @rows
			if $args->{'connection'};
		@rows = grep { ($_->{'signatorial'} || '') eq $args->{'signatorial'} } @rows
			if $args->{'signatorial'};
		return [ @rows ];
	};
	local *subs::remote_useragent_maker = sub {
		return { ua => $ua, manager => 'https://192.168.1.123:45545', ip => '192.168.1.123' };
	};

	# --- a named destination is dialled while the roster says inactive --------
	my $label = subs::destination_relay({
		destination => $PEER_SIG,
		app         => 'vol_+',
		movement    => 'command',
		timestamp   => 1,
	});

	is($label, 'Laptop (192.168.1.123)',
		'a press names the machine to run on, and it is relayed even while its row is inactive');
	is(scalar @lister_calls, 1, 'the destination row is looked up once');
	ok(!exists $lister_calls[0]->{'connection'},
		'the named lookup does not demand an active row');
	is(scalar @{$ua->{'posted'}}, 1, 'the command reached the named machine');
	is($ua->{'posted'}[0]->{'url'}, 'https://192.168.1.123:45545/manager/reset',
		'the relay posts to the peer\'s reset route');
	is($ua->{'posted'}[0]->{'form'}{'type'}, 'command', 'the movement rides the relay');
	is($ua->{'posted'}[0]->{'form'}{'app'}, 'vol_+', 'and the app it belongs to');

	# --- every machine still means every machine that is up -------------------
	@lister_calls = ();
	my $flood = subs::destination_relay({
		destination => 'all',
		app         => 'vol_+',
		movement    => 'command',
		timestamp   => 1,
	});
	is($flood, undef, 'a fan-out skips the inactive roster row');
	is(scalar @{$ua->{'posted'}}, 1, 'and posts no second copy');
	like($lister_calls[0]->{'connection'}, qr/^active$/,
		'a fan-out still asks only for active rows');
}

# --- the press hands its pin's destination over ------------------------------
my $root = repo_root();
my $edt = read_file("$root/lib/JawnOS/Domain/Edt.pm");
my ($press) = $edt =~ /(sub edt_button_presser \{.*?\n\})/s;
ok($press, 'edt_button_presser is still one sub');
like($press, qr/my \$destination = \$b->\{'destination'\} \|\| ''/,
	'the press reads the pin\'s named machine');
like($press, qr/&subs::destination_relay\(\{ destination => \$destination/,
	'and relays the movement to it');
like($press, qr/unless \(\$ran_away\) \{.*?run_command\(/s,
	'the local run is only the fallback when the relay reports nobody took it');

done_testing();
