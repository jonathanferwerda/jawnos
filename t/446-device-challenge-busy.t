# tests-for: lib/JawnOS/Controller/manager_device.pm lib/JawnOS/Manager/Part30.pm
# covers:    The app-key door is the first thing an app asks for after a boot,
#            and the database can still be opening or held by a sync write.
#            A challenge, a login, a status read and the schema pass answer a
#            JSON "busy, retry" instead of dying on ->hashes; a kept nonce is
#            the only success, and an unreadable nonce is the same as an absent
#            one. The happy path still mints the challenge.

use strict;
use warnings;
no warnings 'once';
no warnings 'redefine';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

require "$FindBin::Bin/../lib/JawnOS/Controller/manager_device.pm";
require "$FindBin::Bin/../lib/JawnOS/Manager/Part30.pm";

# --- the smallest controller the actions touch ------------------------------
package FakeTx;
sub new { bless {}, shift }
sub remote_address { '203.0.113.7' }

package FakeC;
sub new { my ($class, $params) = @_; bless { params => $params || {}, session => {}, rendered => undef }, $class }
sub param { my ($s, $k) = @_; return $s->{params}{$k}; }
sub session { my ($s, $k) = @_; return $s->{session}{$k}; }
sub tx { FakeTx->new }
sub render { my ($s, @args) = @_; my %a = @args; $s->{rendered} = exists $a{json} ? $a{json} : \%a; return 1; }

package FakeResults;
sub new { my ($class, $rows) = @_; bless { rows => $rows || [] }, $class }
sub hashes { return $_[0]->{rows}; }
sub hash { return $_[0]->{rows}[0]; }

package main;

my $device = { uuid => 'DEV1', status => 'active', name => 'Laptop' };
# What the stubs do for this call: 'ok', 'die', 'undef' or 'empty' for the
# device read; 'ok' or 'die' for the count; 'ok' or 'fail' for the nonce write.
our ($select_mode, $query_mode, $insert_mode) = ('ok', 'ok', 'ok');

sub challenge {
	local *Manager::app_schema_ensure = sub { };
	local *subs::rightNow = sub { 1_700_000_000_000 };
	local *subs::random_string_creator = sub { 'NONCE' };
	local *subs::db_select = sub {
		die "database is locked\n" if $select_mode eq 'die';
		return undef if $select_mode eq 'undef';
		return FakeResults->new($select_mode eq 'empty' ? [] : [ $device ]);
	};
	local *subs::db_query = sub {
		die "database is locked\n" if $query_mode eq 'die';
		return FakeResults->new([ { n => 0 } ]);
	};
	local *subs::db_insert = sub {
		my ($table, $data) = @_;
		return undef if $insert_mode eq 'fail' && (($data->{context} || '') eq 'app_nonce');
		return 1;
	};
	my $c = FakeC->new({ device_uuid => 'DEV1', purpose => 'login' });
	my $error = '';
	eval { Manager::action_37983($c); 1 } or $error = $@;
	return ($c, $error);
}

my ($c, $error);

# --- a database that dies or answers nothing is busy, not a 500 -------------
($select_mode, $query_mode, $insert_mode) = ('die', 'ok', 'ok');
($c, $error) = challenge();
is($error, '', 'a failed device read does not take the challenge down');
is_deeply($c->{rendered}, { ok => 0, error => 'busy', retry => 1 },
	'a failed device read answers busy with a retry');

($select_mode, $query_mode, $insert_mode) = ('undef', 'ok', 'ok');
($c, $error) = challenge();
is($error, '', 'a missing database does not take the challenge down');
is_deeply($c->{rendered}, { ok => 0, error => 'busy', retry => 1 },
	'a missing database answers busy');

($select_mode, $query_mode, $insert_mode) = ('empty', 'ok', 'ok');
($c, $error) = challenge();
is_deeply($c->{rendered}, { ok => 0, error => 'not paired' },
	'an answered empty row still says not paired');

($select_mode, $query_mode, $insert_mode) = ('ok', 'die', 'ok');
($c, $error) = challenge();
is_deeply($c->{rendered}, { ok => 0, error => 'busy', retry => 1 },
	'a failed rate-count read answers busy');

($select_mode, $query_mode, $insert_mode) = ('ok', 'ok', 'fail');
($c, $error) = challenge();
is_deeply($c->{rendered}, { ok => 0, error => 'busy', retry => 1 },
	'a nonce the store did not keep is busy, never a challenge');

($select_mode, $query_mode, $insert_mode) = ('ok', 'ok', 'ok');
($c, $error) = challenge();
is($error, '', 'the happy path does not die');
is_deeply($c->{rendered}, { ok => 1, nonce => 'NONCE', seconds => 120 },
	'the challenge is the nonce, in the existing shape');

# --- app_login and app_status guard the same read ---------------------------
{
	local *Manager::app_schema_ensure = sub { };
	local *subs::rightNow = sub { 1_700_000_000_000 };
	local *subs::db_select = sub { die "database is locked\n" };
	my $login = FakeC->new({ device_uuid => 'DEV1' });
	my $login_error = '';
	eval { Manager::action_38011($login); 1 } or $login_error = $@;
	is($login_error, '', 'a failed read does not take app_login down');
	is_deeply($login->{rendered}, { ok => 0, error => 'busy', retry => 1 },
		'app_login answers busy');

	my $status = FakeC->new({ device_uuid => 'DEV1' });
	my $status_error = '';
	eval { Manager::action_38048($status); 1 } or $status_error = $@;
	is($status_error, '', 'a failed read does not take app_status down');
	is_deeply($status->{rendered}, { ok => 0, error => 'busy', retry => 1 },
		'app_status answers busy');
}

# --- app_nonce_take: an unreadable cache is an absent nonce -----------------
{
	local *subs::db_query = sub { die "database is locked\n" };
	my $spent;
	my $failed = '';
	eval { $spent = Manager::app_nonce_take('login', 'DEV1', 'ABCDEFGH'); 1 } or $failed = $@;
	is($failed, '', 'an unreadable nonce does not die');
	is($spent, 0, 'and it does not spend a challenge it could not read');
}

# --- the schema pass survives a locked pragma read --------------------------
{
	local $Manager::app_schema_done = 0;
	local *subs::database_grabber = sub { return (1, 'database.db', 1) };
	local *subs::db_query = sub { die "database is locked\n" };
	my $failed = '';
	eval { Manager::app_schema_ensure(); 1 } or $failed = $@;
	is($failed, '', 'a locked pragma read does not take the schema pass down');
	is($Manager::app_schema_done, 0, 'and the pass is not memoised, so the next request retries');
}

done_testing();
