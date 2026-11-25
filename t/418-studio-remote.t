# tests-for: lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm
# covers:    The server half of remote Studio control: the picker lists active
#            peers but never this machine or the server, the chosen target is a
#            studio setting, the target's browser publishes one compact snapshot,
#            the state reader answers it back, and a command crosses only as a
#            whitelisted name with a bounded JSON-object payload. A controller
#            request relays through the signed peer rail; a relayed request can
#            never publish and a peer that is not active is never relayed.

use strict;
use warnings;

use FindBin;
use Test::More;
use File::Slurp qw(read_file);

my $root       = "$FindBin::Bin/..";
my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my $routes     = read_file("$root/lib/JawnOS/Routes/manager_misc9.pm");

# --- the five routes ---------------------------------------------------------
my @routes = (
	[ 'get',  '/manager/studio/remote_machines', 'action_44037' ],
	[ 'post', '/manager/studio/remote_target',   'action_44038' ],
	[ 'post', '/manager/studio/remote_publish',  'action_44039' ],
	[ 'post', '/manager/studio/remote_state',    'action_44040' ],
	[ 'post', '/manager/studio/remote_command',  'action_44041' ],
);
for my $row (@routes) {
	my ($method, $path, $action) = @{$row};
	like($routes, qr/\[\s*\d+\s*,\s*'\Q$method\E'\s*,\s*'\Q$path\E'\s*,\s*'\Q$action\E'\s*\]/,
		"$method $path is registered to $action");
	like($controller, qr/^\s*sub\s+\Q$action\E\b/m, "$action exists in the controller");
}

# --- the picker filters like the Music picker --------------------------------
like($controller, qr/sub studio_remote_machines/, 'the picker is one filter');
like($controller, qr/subs::remote_machine_lister\(\{ self => 'no' \}\)/,
	'it asks the peer lister for the other machines');
like($controller, qr/\(\$rm->\{'device'\} \|\| ''\) eq 'server'/,
	'a server is never a target: it has no browser');
like($controller, qr/\(\$rm->\{'connection'\} \|\| ''\) eq 'active'/,
	'only a peer that is active now is listed');
like($controller, qr/'hostname'.*'me'.*127\.0\.0\.1/,
	'the synthetic me row is dropped');
like($controller, qr/%seen/, 'the list is deduped by uuid');
like($controller, qr/subs::device_hostname_better/, 'the label is the display hostname');

# --- the saved target --------------------------------------------------------
like($controller, qr/subs::setting_grabber\(\{ app => 'studio', setting => 'remote_target' \}\)/,
	'the picker returns the saved target');
like($controller, qr/subs::setting_setter\(\{ app => 'studio', setting => 'remote_target', value => \$target \}\)/,
	'the target is saved as a studio setting');
like($controller, qr/\$target eq 'local'/, 'local clears the target');
like($controller, qr/sub studio_remote_peer/, 'a target has to be an active peer');
like($controller, qr/remote_machine_lister\(\{ self => 'no', connection => 'active', uuid => \$uuid \}\)/,
	'and is re-checked before anything is relayed');

# --- the published snapshot --------------------------------------------------
like($controller, qr/context => 'remote_state'/, 'the snapshot cache is studio/remote_state');
like($controller, qr/subs::cache_set\(\{ app => 'studio', context => 'remote_state' \}, \$state\)/,
	'publish stores the snapshot');
like($controller, qr/subs::cache_get\(\{ app => 'studio', context => 'remote_state' \}\)/,
	'state reads it back');
like($controller, qr/\$state->\{'at'\} = \$at/, 'the snapshot carries a server timestamp');
like($controller, qr/ok => 1,\s*\n\s*at => 0,\s*\n\s*song => \{\},/,
	'an unwritten snapshot still has the documented song shape');
like($controller, qr/tracks => \[\],\s*\n\s*clips => \[\],\s*\n\s*master => \[\]/,
	'and empty tracks, clips and master');

# --- the publish guard -------------------------------------------------------
like($controller, qr/\(\$c->param\('remoted'\) \|\| ''\) eq 'yes'/,
	'publish refuses a relayed request');
like($controller, qr/a relayed request cannot publish Studio state/, 'and says why');
like($controller, qr/65_536/, 'the snapshot is capped at 64 KB');
like($controller, qr/ref \$state eq 'HASH'/, 'a snapshot must be a JSON object');

# --- the command whitelist ---------------------------------------------------
like($controller, qr/my %studio_remote_command = map \{ \$_ => 1 \} qw\(transport record track mixer master song select\);/,
	'only the seven Studio command areas cross');
unlike($controller, qr/qw\(transport record track mixer master song select\)[^;]*\b(?:clip|export|load)\b/,
	'clip, export and load are not commands');
like($controller, qr/ref \$payload eq 'HASH'/, 'a command payload must be a JSON object');
like($controller, qr/16_384/, 'and is bounded');

# --- the relay and the console hand-off -------------------------------------
like($controller, qr/Manager::remote_relay_request\(\$c\)/,
	'a peer request is relayed through the signed rail');
like($controller, qr/\$c->param\('remote_uuid' => \$peer->\{'uuid'\}\)/,
	'the relay names the peer that was checked');
like($controller, qr/if \(!\$remoted && defined \$target/,
	'a relayed or local target is not relayed again');
like($controller, qr/console_command\('studioRemoteCommand', \$command, \$payload\)/,
	'the target gets a named console instruction');
like($controller, qr/Websocket::send\('server'/, 'on the server console channel');
unlike($controller, qr/Websocket::send\('studio'/, 'never the Studio data channel');
unlike($controller, qr/remote_relay_request\(\$c, \{.*url/, 'no arbitrary path is relayed');

# --- the publish accepts the page's form field -------------------------------
# The Studio page posts `state=<json>` as a form field (07_layout.js), not a
# raw JSON body. The route must read that field first and still accept the raw
# body shape; a malformed state is one 400 either way.
{
	package subs;
	no warnings 'redefine';
	our %studio_test_cache;
	sub rightNow { 1_700_000_000_000 }
	sub cache_set {
		my ($key, $value) = @_;
		$studio_test_cache{ $key->{'context'} } = $value;
		return 1;
	}
}
{
	package FakeStudioRequest;
	sub new { my ($class, %args) = @_; return bless { body => ($args{'body'} // '') }, $class }
	sub body { return $_[0]->{'body'} }

	package FakeStudioController;
	sub new { my ($class, %args) = @_; return bless { %args }, $class }
	sub param {
		my ($self, $name) = @_;
		return $self->{'params'}->{$name};
	}
	sub req { return $_[0]->{'req'} }
	sub render {
		my ($self, %args) = @_;
		$self->{'status'} = $args{'status'};
		$self->{'json'} = $args{'json'};
		return;
	}

	package main;
}

require "$root/lib/JawnOS/Controller/manager_misc9.pm";
{
	my $c = FakeStudioController->new(
		params => { state => '{"song":{"name":"form"}}' },
		req => FakeStudioRequest->new(body => ''),
	);
	Manager::action_44039($c);
	is($c->{'json'}{'ok'}, 1, 'a form-encoded state publishes');
	is($subs::studio_test_cache{'remote_state'}{'song'}{'name'}, 'form',
		'and its decoded object is cached');

	my $raw = FakeStudioController->new(
		params => {},
		req => FakeStudioRequest->new(body => '{"song":{"name":"raw"}}'),
	);
	Manager::action_44039($raw);
	is($raw->{'json'}{'ok'}, 1, 'a raw JSON body still publishes');
	is($subs::studio_test_cache{'remote_state'}{'song'}{'name'}, 'raw',
		'and it is the one cached');

	my $bad = FakeStudioController->new(
		params => { state => '{"song":' },
		req => FakeStudioRequest->new(body => ''),
	);
	Manager::action_44039($bad);
	is($bad->{'status'}, 400, 'a malformed form state is still a 400');
	ok(!$bad->{'json'}{'ok'}, 'and publishes nothing');

	my $scalar = FakeStudioController->new(
		params => { state => '"just a string"' },
		req => FakeStudioRequest->new(body => ''),
	);
	Manager::action_44039($scalar);
	is($scalar->{'status'}, 400, 'a non-object state is a 400');
}

done_testing();
