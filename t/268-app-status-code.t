# tests-for: lib/JawnOS/Controller/manager_device.pm public/js/universal/03_unlock_requests_media_locks.js templates/app_required.html.ep
# covers:    GET /manager/device/app_status answers a pending app enrollment
#           with a boolean for a caller that is not the device it belongs to,
#           and with the short code only for that device's own session or a
#           house session. The asking app takes its code from the app_request
#           response it already receives, so enrollment still has a code.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../lib", 't/lib';
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(encode_json);
use JawnOSTest;

require(root() . '/lib/JawnOS/Controller/manager_device.pm');

my $now = &subs::rightNow();
my $victim = 'device-victim-0000000001';
my $other  = 'device-other-0000000002';

# The sandbox snapshot comes from schema.sql, where device_requests predates the
# app columns. app_schema_ensure adds them in a live house; do the same here
# rather than depend on a populated live database.
my @columns = map { $_->{'name'} } @{ &subs::db_query('pragma table_info(device_requests)')->hashes };
if (!grep { $_ eq 'kind' } @columns) {
	&subs::db_query('alter table device_requests add column kind VARCHAR(16)');
}

foreach my $uuid ($victim, $other) {
	&subs::db_insert('paired_devices', {
		uuid => $uuid, name => $uuid, pubkey => '', status => 'active',
		privilege => 'citizen', timestamp => $now, server_time => $now,
	});
}

my $code = 'ABC-123';
&subs::db_insert('device_requests', {
	uuid => 'request-victim', name => 'Desktop app', pubkey => '',
	code => $code, status => 'pending', device_uuid => $victim, kind => 'app',
	timestamp => $now, server_time => $now,
});

{
	package AppStatusTestController;
	sub new {
		my ($class, %args) = @_;
		return bless { param => $args{'param'} || {}, session => $args{'session'} || {} }, $class;
	}
	sub param {
		my ($self, $key) = @_;
		return $self->{'param'}->{$key};
	}
	sub session {
		my ($self, $key) = @_;
		return $self->{'session'}->{$key};
	}
	sub render {
		my ($self, @args) = @_;
		my %args = @args;
		$self->{'rendered'} = $args{'json'};
		return 1;
	}
}

# app_schema_ensure and the two key/session helpers belong to the wider Manager
# package; the rule under test never needs them.
{
	no warnings 'redefine';
	no warnings 'once';
	*Manager::app_schema_ensure = sub { 1 };
	*Manager::app_key_for = sub { return ('', '') };
	*Manager::app_session_ok = sub { return 0 };
}

sub status_for {
	my (%args) = @_;
	my $c = AppStatusTestController->new(%args);
	Manager::action_38048($c);
	return $c->{'rendered'} || {};
}

# --- a stranger -- or another device -- learns no code ----------------------
my $anon = status_for(param => { device_uuid => $victim });
is($anon->{'ok'}, 1, 'an unnamed caller still gets the status');
is($anon->{'pending'}, 1, 'it is told only that a request waits');
unlike(encode_json($anon), qr/\Q$code\E/, 'the code is not in the reply');

my $neighbour = status_for(param => { device_uuid => $victim }, session => { device_uuid => $other });
is($neighbour->{'pending'}, 1, 'a session bound to another device gets a boolean');
unlike(encode_json($neighbour), qr/\Q$code\E/, 'and never the other device\'s code');

# --- the device's own session sees the code --------------------------------
my $own = status_for(param => { device_uuid => $victim }, session => { device_uuid => $victim });
is($own->{'pending'}, $code, 'the device bound to the request gets its code');

my $by_session = status_for(session => { device_uuid => $victim });
is($by_session->{'pending'}, $code, 'a session-only device uuid is the same binding');

# --- a house session may read it; a guest session may not ------------------
my $house = status_for(
	param => { device_uuid => $victim },
	session => { device_uuid => $other, authentication => 'approved', privilege => 'citizen' },
);
is($house->{'pending'}, $code, 'a house session may compare the code');

my $guest = status_for(
	param => { device_uuid => $victim },
	session => { authentication => 'approved', privilege => 'guest' },
);
is($guest->{'pending'}, 1, 'a guest ticket is not a house session');
unlike(encode_json($guest), qr/\Q$code\E/, 'and gets no code');

# --- a stale request is still expired --------------------------------------
my $stale = 'device-stale-0000000003';
&subs::db_insert('paired_devices', {
	uuid => $stale, name => $stale, pubkey => '', status => 'active',
	privilege => 'citizen', timestamp => $now, server_time => $now,
});
&subs::db_insert('device_requests', {
	uuid => 'request-stale', name => 'Desktop app', pubkey => '',
	code => 'OLD-999', status => 'pending', device_uuid => $stale, kind => 'app',
	timestamp => $now - 3600001, server_time => $now - 3600001,
});
my $old = status_for(session => { device_uuid => $stale });
is($old->{'pending'}, '', 'an expired request stops waiting');
is(&subs::db_select('device_requests', ['status'], { uuid => 'request-stale' })->hash->{'status'},
	'expired', 'and is marked expired in the table');

# --- the code still reaches the asking app ----------------------------------
my $controller = read_file(root() . '/lib/JawnOS/Controller/manager_device.pm');
my ($request) = $controller =~ /(sub action_38088 \{.*?\n\})/s;
ok($request, 'the app_request action is still one sub');
like($request, qr/code => \$code/, 'app_request still answers with the code it stored');

my $js = read_file(root() . '/public/js/universal/03_unlock_requests_media_locks.js');
like($js, qr/localStorage\.setItem\('jawn_app_request_code', r\.code\)/,
	'the desktop takes the code from the app_request reply, not from app_status');

my $page = read_file(root() . '/templates/app_required.html.ep');
like($page, qr/function showCode\(/, 'the app-required page can show the code it was given');
like($page, qr/jawnAppEnrollDesktop\(\)\.then\(function \(r\) \{ showCode\(r && r\.code\); \}\)/,
	'and reads it from that reply');

done_testing();
