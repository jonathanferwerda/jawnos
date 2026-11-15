# tests-for: perl/junderground.pl lib/JawnOS/Controller/manager_box_office.pm lib/JawnOS/Routes/manager_box_office.pm templates/box_office/markup.html.ep public/js/manager/manager/03_box_office.js perl/help/topics_configure.pl
# covers:    An interview is a room on the switch, not a session in the house:
#            the house signs the room record, mints a one-use bearer pass, and
#            stores it on the request without touching the mesh or the tailnet.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;
use RepoSource;

my $root = repo_root();
require "$root/perl/junderground.pl";

# --- the room name is a switch slug, not a house handle --------------------
is(main::jg_room_slug('Interview ABC_123'), 'interview-abc_123', 'a room slug is lower-case and keeps the allowed marks');
is(main::jg_room_slug('  --Interview  '), 'interview', 'spaces and a leading dash are trimmed');
ok(length(main::jg_room_slug('x' x 200)) <= 63, 'a room slug is capped at the switch length');
like(main::jg_room_slug('123 abc'), qr/^[a-z0-9][a-z0-9._-]*$/, 'the first character is not a separator');

# --- the signed record -----------------------------------------------------
my @calls;
{
	local *main::jg_key = sub { return 'K' x 32 };
	local *subs::crest_record_read = sub { return { pubkey => 'P' x 44, name => 'Jawn' } };
	local *subs::crest_sign_record = sub {
		my ($record, $key) = @_;
		$record->{'signed_with'} = $key;
		$record->{'sig'} = 'SIGNATURE';
		return $record;
	};
	local *main::jg_call = sub {
		my ($c, $method, $path, $body, $auth) = @_;
		push @calls, { method => $method, path => $path, body => $body, auth => $auth };
		return { ok => 1 };
	};
	my $made = main::jg_room_register(undef, 'Jawn House', 'Interview-ABC',
		name => 'Interview', policy => 'invite', max => 8, expires => 42);
	ok($made->{'ok'}, 'the switch accepted the room');
	is($made->{'room'}, 'interview-abc', 'the registered room is the slug');
	my $call = $calls[-1];
	is($call->{'method'}, 'POST', 'the room is registered with a POST');
	is($call->{'path'}, '/v1/rooms', 'at the rooms endpoint');
	ok($call->{'auth'}, 'signed by the house key');
	my $record = decode_json($call->{'body'});
	is($record->{'format'}, 'junderground-room', 'the record names the room format');
	is($record->{'kind'}, 'register', 'and the register kind');
	is($record->{'handle'}, 'jawn_house', 'the house handle is a slug');
	is($record->{'room'}, 'interview-abc', 'the room is the slug');
	is($record->{'name'}, 'Interview', 'the display name is kept');
	is($record->{'pubkey'}, 'P' x 44, 'the crest key is inside the signed record');
	is($record->{'seq'}, 1, 'a fresh room starts the chain');
	is($record->{'advertised'}, 'no', 'the room is not advertised');
	is($record->{'policy'}, 'invite', 'and is invite-only');
	is($record->{'max'}, 8, 'with the room size');
	is($record->{'recording'}, 'off', 'recording is off');
	is($record->{'expires'}, 42, 'the room can expire with its pass');
	is($record->{'signed_with'}, 'K' x 32, 'the room record was signed with the house key');
}

# --- the one-use pass ------------------------------------------------------
@calls = ();
{
	local *main::jg_call = sub {
		my ($c, $method, $path, $body, $auth) = @_;
		push @calls, { method => $method, path => $path, body => $body, auth => $auth };
		return { ticket => 'JG1.pass', jti => 'j1', expires => 99 };
	};
	my $pass = main::jg_room_pass(undef, 'jawn_house', 'interview-abc',
		uses => 1, expires => 99, meta => { purpose => 'interview', name => 'Dana' });
	is($pass->{'ticket'}, 'JG1.pass', 'the pass token comes back');
	my $call = $calls[-1];
	is($call->{'path'}, '/v1/rooms/jawn_house/interview-abc/passes', 'a pass is issued on the room');
	my $body = decode_json($call->{'body'});
	is($body->{'bind'}, 'bearer', 'an applicant has no house identity, so the pass is bearer');
	is($body->{'uses'}, 1, 'and works once');
	is_deeply($body->{'caps'}, [qw(join publish_audio publish_video)], 'it carries join and both media directions');
	is($body->{'expires'}, 99, 'the expiry is the caller\'s');
	is($body->{'meta'}->{'name'}, 'Dana', 'the applicant name rides in the metadata');
}

# --- the house action and the desk UI -------------------------------------
my $controller = read_file("$root/lib/JawnOS/Controller/manager_box_office.pm");
like($controller, qr/sub action_24780/, 'the room action exists');
my ($action) = $controller =~ /(sub action_24780\b.*?)(?=\nsub |\z)/s;
like($action, qr/jg_room_register/, 'it registers the room');
like($action, qr/jg_room_pass/, 'and mints the pass');
like($action, qr/\$info->\{'room'\}/, 'it stores the room on the request');
like($action, qr/expires => \$until/, 'the room expires with the pass');
like($action, qr/substr\(\$uuid, 0, 8\)/, 'each press makes a fresh room slug');
unlike($action, qr/db_(?:insert|update)\(\s*'remote_machines'/, 'it never makes a mesh row for the applicant');
unlike($action, qr/tailnet_ip/, 'and never gives them a tailnet address');
my $routes = read_file("$root/lib/JawnOS/Routes/manager_box_office.pm");
like($routes, qr{/manager/box_office/room}, 'the room route is registered');
my $markup = read_file("$root/templates/box_office/markup.html.ep");
like($markup, qr/class="ticket_room\b/, 'the desk offers an interview room');
like($markup, qr/ticket_room_copy/, 'and a copy for an existing pass');
like($markup, qr/ticket_room_new/, 'and a fresh room when it expires');
my $js = read_file("$root/public/js/manager/manager/03_box_office.js");
like($js, qr{/manager/box_office/room}, 'the script opens the room');
like($js, qr/bo_room_chip/, 'and shows the room it made');
like($js, qr/ticket_room_new/, 'and can mint a fresh one');
my $help = read_file("$root/perl/help/topics_configure.pl");
like($help, qr/Interview room/, 'the help explains the room');

done_testing();
