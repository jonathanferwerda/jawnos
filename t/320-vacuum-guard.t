# tests-for: lib/JawnOS/Domain/File.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Manager/Part32.pm lib/JawnOS/Manager/Index.pm lib/JawnOS/Manager/Declarations.pm lib/JawnOS/Controller/manager_configure5.pm lib/JawnOS/Controller/manager_misc12.pm public/js/manager/configure/04_currency_backup.js perl/help/topics_configure.pl
# covers:    Vacuum and Delete app share one refusal: the house's own apps and a
#            card ticked Permanent keep their rows. Vacuum itself clears the
#            app's records through the ordinary delete - so files go through
#            delete_file, not a comma split - plus the place rows that do not
#            ride a record, and never touches a configuration table.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# The domain layer is lazy: load the real definitions before the local *subs::
# stubs below, or a later module load would replace them.
subs::preload($_) for qw(app_removal_refusal app_removal_refusal_text vacuum ui);

# The record clear is a Manager helper because it rides delete_app and
# delete_file; Part32 loads on its own (as t/256 does).
require(root() . '/lib/JawnOS/Manager/Part32.pm');

package FakeRows;
sub new {
	my ($class, $rows, $hashes) = @_;
	return bless { rows => $rows, hashes => $hashes || [] }, $class;
}
sub rows   { $_[0]->{'rows'} }
sub hashes { $_[0]->{'hashes'} }

package main;

my $NOW = 1_700_000_000_000;
my (@calls, $appts, $places, %settings);

# The smallest world these subs ask for. Every statement and helper is
# recorded, not run; the locals only live for the call, so each case runs its
# code through _run.
sub _run {
	my $code = shift;
	@calls = ();
	%settings = ();
	$appts = [];
	$places = [];
	local *subs::database_grabber = sub { return (undef, '/tmp/vacuum-guard.db', '') };
	local *subs::rightNow = sub { $NOW };
	local *subs::language = sub { 'en' };
	local *subs::html_name = sub { $_[0] };
	local *subs::setting_grabber = sub { my $a = shift; return $settings{ $a->{'app'} } || '' };
	local *subs::db_query = sub {
		my ($sql, @bind) = @_;
		push @calls, [ 'query', $sql, @bind ];
		return FakeRows->new(1);
	};
	local *subs::db_select = sub {
		my ($table) = @_;
		push @calls, [ 'select', $table ];
		return FakeRows->new(0, $appts) if $table eq 'appointments';
		return FakeRows->new(0, $places) if $table eq 'continent';
		return FakeRows->new(0, []);
	};
	local *subs::appt_header_printer = sub { push @calls, 'header' };
	local *subs::subprocessor = sub { push @calls, 'subprocessor' };
	local *Manager::delete_app = sub { push @calls, [ 'delete_app', @_ ] };
	local *Manager::deletion_registration = sub { push @calls, [ 'tombstone', @_ ] };
	local *Websocket::console_command = sub { push @calls, [ 'console', @_ ]; return '{}' };
	local *Websocket::send = sub { push @calls, 'send'; return 1 };
	$code->();
}

sub _calls_of {
	my $kind = shift;
	return grep { ref $_ eq 'ARRAY' && $_->[0] eq $kind } @calls;
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

# --- Vacuum: records out, configuration kept -------------------------------

my $cleared;
_run(sub {
	$appts = [ { uuid => 'a1', server_time => $NOW }, { uuid => 'a2' } ];
	$places = [ { uuid => 'p1', server_time => $NOW } ];
	$cleared = Manager::vacuum_app_records('knitting', $NOW);
});
is($cleared, 2, 'the count is the records cleared');

my @deletes = _calls_of('delete_app');
is(scalar @deletes, 2, 'each record goes through the ordinary delete');
is_deeply($deletes[0], [ 'delete_app', 'knitting', 'a1', $NOW, 'vacuum records', 1 ],
	'with its own time, the vacuum reason and silent set');
is_deeply($deletes[1], [ 'delete_app', 'knitting', 'a2', $NOW, 'vacuum records', 1 ],
	'a record without a time uses the sweep time');

my @tombstones = _calls_of('tombstone');
is(scalar @tombstones, 1, 'a place row gets its own tombstone');
is_deeply($tombstones[0][1], { table => 'continent', app => 'knitting', uuid => 'p1', scope => 'single', server_time => $NOW },
	'so a peer drops that row instead of pushing it back');

my @queries = _calls_of('query');
is_deeply([ map { $_->[1] } @queries ], [ 'delete from continent where app = ?' ],
	'the place rows that do not ride a record are swept');
my $sql = join ' ', map { $_->[1] } @queries;
unlike($sql, qr/\b(settings|model|option|option_category|subcategory|websites|tickets|mailbox|cache|websockets)\b/,
	'no configuration, mail or shared table is touched');

is(scalar(grep { $_ eq 'header' } @calls), 1, 'the header is reprinted once, not once per record');
is(scalar(grep { $_ eq 'subprocessor' } @calls), 1, 'and the centre view is redrawn once');

# --- Vacuum refuses before it reads ---------------------------------------

my $count;
_run(sub { $count = Manager::vacuum_app_records('me') });
is($count, 0, 'a house app is refused');
is(scalar @calls, 0, 'before any row is read or deleted');

_run(sub { $settings{'knitting'} = 'checked'; $count = Manager::vacuum_app_records('knitting') });
is($count, 0, 'a Permanent card is refused');
is(scalar @calls, 0, 'and nothing is read either');

_run(sub { $count = Manager::vacuum_app_records('') });
is($count, 0, 'an empty app name is a no-op');

# --- the old wipe and its comma splitter are gone -------------------------

sub slurp {
	my $path = shift;
	open my $fh, '<', $path or die "$path: $!";
	local $/;
	return <$fh>;
}

my $file = slurp(root() . '/lib/JawnOS/Domain/File.pm');
unlike($file, qr/sub vacuum_app\b/, 'the old vacuum_app with its comma splitter is gone');
like($file, qr/^sub vacuum \{/m, 'the automatic sweep after the last record stays');

my $loader = slurp(root() . '/lib/JawnOS/Domain/Loader.pm');
unlike($loader, qr/\bvacuum_app\b/, 'and the loader no longer offers it');

my $index = slurp(root() . '/lib/JawnOS/Manager/Index.pm');
like($index, qr/'vacuum_app_records'\s*=>\s*'JawnOS\/Manager\/Part32\.pm'/, 'the new helper is in the Manager map');
my $decl = slurp(root() . '/lib/JawnOS/Manager/Declarations.pm');
like($decl, qr/^sub vacuum_app_records;/m, 'and forward-declared');

my $part32 = slurp(root() . '/lib/JawnOS/Manager/Part32.pm');
like($part32, qr/sub vacuum_app_records\(.*?&delete_app\(/s, 'records ride delete_app, and so delete_file');
like($part32, qr/sub vacuum_app_records\(.*?delete from continent/s, 'the place rows are swept after');
unlike($part32, qr/sub vacuum_app_records\(.*?delete from (?:settings|model|option|subcategory|websites|tickets|mailbox|cache|websockets)/s,
	'and no configuration table is deleted');
like($part32, qr/'scope'\} eq 'vacuum'.*?vacuum_app_records/s, 'a peer applying the tombstone gets the same rule');

my $configure = slurp(root() . '/lib/JawnOS/Controller/manager_configure5.pm');
like($configure, qr/vacuum_app_records\(\$app\)/, 'the Vacuum panel runs the record clear');
unlike($configure, qr/scope => 'vacuum'/, 'and writes no coarse vacuum tombstone');
like($configure, qr/Every record and the files those records name/, 'its confirm says what goes');
like($configure, qr/keeps its settings, models, options, categories, web sources and tickets/, 'and what stays');

my $js = slurp(root() . '/public/js/manager/configure/04_currency_backup.js');
like($js, qr/#vacuum_app_confirm.*?configurationReloader\(app\)/s, 'the panel reloads the card Vacuum keeps');
unlike($js, qr/#vacuum_app_confirm.*?appointment_configuration_cell.*?remove/s, 'and no longer removes it');

my $help = slurp(root() . '/perl/help/topics_configure.pl');
like($help, qr/clears the app\\'s records/, 'the Configure topic describes the repurposed Vacuum');
like($help, qr/keeps its settings, models, options, categories, web sources and tickets/, 'including what it keeps');
like($help, qr/ticked Permanent: untick Permanent first/, 'and the refusal it shares with Delete app');

done_testing();
