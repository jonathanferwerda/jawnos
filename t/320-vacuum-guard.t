# tests-for: lib/JawnOS/Domain/File.pm lib/JawnOS/Controller/manager_configure5.pm lib/JawnOS/Controller/manager_misc12.pm public/js/manager/configure/04_currency_backup.js perl/help/topics_configure.pl
# covers:    Vacuum and Delete app share one refusal: the house's own apps and a
#            card ticked Permanent keep their rows. Vacuum refuses before it
#            reads an appointment, unlinks a file or deletes anything, and the
#            automatic sweep uses the same list.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# The domain layer is lazy: load the real definitions before the local *subs::
# stubs below, or a later module load would replace them.
subs::preload($_) for qw(app_removal_refusal app_removal_refusal_text vacuum vacuum_app ui);

package FakeRows;
sub new {
	my ($class, $rows, $hashes) = @_;
	return bless { rows => $rows, hashes => $hashes || [] }, $class;
}
sub rows   { $_[0]->{'rows'} }
sub hashes { $_[0]->{'hashes'} }

package main;

my $NOW = 1_700_000_000_000;
my (@calls, $appts, %settings);

# The smallest world vacuum and vacuum_app ask for. A select of appointments
# answers with $appts; every other statement is recorded, not run. The locals
# only live for the call, so each case runs its code through _run.
sub _run {
	my $code = shift;
	@calls = ();
	%settings = ();
	$appts = [];
	local *subs::database_grabber = sub { return (undef, '/tmp/vacuum-guard.db', '') };
	local *subs::rightNow = sub { $NOW };
	local *subs::language = sub { 'en' };
	local *subs::html_name = sub { $_[0] };
	local *subs::setting_grabber = sub { my $a = shift; return $settings{ $a->{'app'} } || '' };
	local *subs::db_query = sub {
		my ($sql, @bind) = @_;
		push @calls, [ 'query', $sql, @bind ];
		return FakeRows->new(0, $appts) if $sql =~ /^\s*select\s+\*\s+from\s+appointments/i;
		return FakeRows->new(1);
	};
	local *Websocket::console_command = sub { push @calls, [ 'console', @_ ]; return '{}' };
	local *Websocket::send = sub { push @calls, 'send'; return 1 };
	$code->();
}

# The delete statements the call issued, in order.
sub _deletes {
	return grep { ref $_ eq 'ARRAY' && $_->[0] eq 'query' && $_->[1] =~ /^\s*delete from/i } @calls;
}

sub guard_for {
	my ($app, $permanent) = @_;
	my $got;
	_run(sub {
		$settings{$app} = $permanent if defined $permanent;
		$got = subs::app_removal_refusal($app);
	});
	return $got;
}

sub words {
	my ($reason, $action) = @_;
	my $got;
	_run(sub { $got = subs::app_removal_refusal_text($reason, $action) });
	return $got;
}

# --- the rule -------------------------------------------------------------

is(guard_for('me'), 'house', "me is one of the house's own apps");
is(guard_for('store'), 'house', 'store cannot be emptied from a card');
is(guard_for('__president'), 'house', '__president keeps the house settings');
is(guard_for('customs'), 'house', 'customs is refused, though only the old sweep knew it');
is(guard_for('knitting', 'checked'), 'permanent', 'a card ticked Permanent is refused');
is(guard_for('me', 'checked'), 'house', 'the house list wins over the tick');
is(guard_for('knitting'), '', 'an ordinary app may go');
is(guard_for(''), '', 'an empty app name is no refusal at all');

like(words('house', 'vacuum'), qr/vacuumed/, 'the Vacuum panel says a house app cannot be vacuumed');
like(words('house', 'delete'), qr/deleted/, 'Delete app says deleted instead');
like(words('permanent', 'vacuum'), qr/Permanent/, 'a Permanent card names the tick to remove');
like(words('permanent', 'delete'), qr/Permanent/, 'the same sentence serves Delete app');
is(words('', 'vacuum'), '', 'no refusal, no sentence');

# --- the Vacuum button ----------------------------------------------------

my $answer;
_run(sub { $answer = subs::vacuum_app('me') });
is($answer, 'house', 'the Vacuum button refuses a house app');
is(scalar @calls, 0, 'and touches nothing: no select, no unlink, no close');

_run(sub { $settings{'knitting'} = 'checked'; $answer = subs::vacuum_app('knitting') });
is($answer, 'permanent', 'the Vacuum button refuses a Permanent card');
is(scalar @calls, 0, 'and again acts on nothing before the refusal');

# --- the automatic sweep --------------------------------------------------

_run(sub { subs::vacuum('knitting') });
my @del = _deletes();
my %tables = map { $_->[1] =~ /^\s*delete from\s+(\w+)/i ? ($1 => 1) : () } @del;
is_deeply([ sort keys %tables ], [ sort qw(appointments cache continent mailbox model option option_category settings subcategory tickets websites websockets) ],
	'an emptied ordinary app is swept from every app-scoped table');
like($del[0]->[1], qr/^\s*delete from appointments/i, 'its appointments go first');

_run(sub { subs::vacuum('me') });
is(scalar(_deletes()), 0, 'the automatic sweep leaves a house app alone');

_run(sub { $settings{'knitting'} = 'checked'; subs::vacuum('knitting') });
is(scalar(_deletes()), 0, 'and a Permanent card');

_run(sub { $appts = [ { uuid => 'a1', app => 'knitting', file => '' } ]; subs::vacuum('knitting') });
is(scalar(_deletes()), 0, 'an app that still has an appointment is not swept');

# --- the panels ask the one rule ------------------------------------------

sub slurp {
	my $path = shift;
	open my $fh, '<', $path or die "$path: $!";
	local $/;
	return <$fh>;
}

my $misc = slurp(root() . '/lib/JawnOS/Controller/manager_misc12.pm');
like($misc, qr/sub action_41622 \{.{0,900}?app_removal_refusal\(/s, 'Delete app asks the shared guard');
unlike($misc, qr/%reserved/, 'and keeps no private house-app list of its own');

my $configure = slurp(root() . '/lib/JawnOS/Controller/manager_configure5.pm');
my @vacuum_text = ($configure =~ /app_removal_refusal_text\(\$refusal, 'vacuum'\)/g);
is(scalar @vacuum_text, 2, 'the Vacuum panel and its confirm both refuse in words');

my $js = slurp(root() . '/public/js/manager/configure/04_currency_backup.js');
like($js, qr/body\.message/, "Delete app shows the server's refusal sentence");
unlike($js, qr/house app and cannot be deleted/, 'and no longer guesses from the status code alone');

my $help = slurp(root() . '/perl/help/topics_configure.pl');
like($help, qr/Vacuum, beside Delete app on a card/, 'the Configure topic describes the Vacuum button');
like($help, qr/ticked Permanent: untick Permanent first/, 'and the refusal it shares with Delete app');

done_testing();
