# tests-for: lib/JawnOS/Manager/Part30.pm lib/JawnOS/Controller/manager_ws.pm
# covers:    The app rail proves a caller by the key it offers. A machine that is
#            not the hub only appears on another peer as a mirror entry in the
#            hub's row, so scanning the direct roster alone refused it: the
#            device relay answered 403 to every press from this machine, and the
#            board was never told. A mirror that publishes a key proves the same
#            caller a direct row would; a mirror without one still proves nothing.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use MIME::Base64 qw(encode_base64);
use Mojo::JSON qw(encode_json);

use JawnOSTest;

require(root() . '/lib/JawnOS/Manager/Part30.pm');

my $pem = "-----BEGIN PUBLIC KEY-----\n"
	. "MCowBQYDK2VwAyEAduf40HZGe9PDwUxU5+XxhggtOMOjRWt7voQAhhvsT9s=\n"
	. "-----END PUBLIC KEY-----\n";
my $other = "-----BEGIN PUBLIC KEY-----\n"
	. "MCowBQYDK2VwAyEAzu3jqGKqPmMQnxkYRuIcJZ2vGDAtv0kFPH4DDMkO0jw=\n"
	. "-----END PUBLIC KEY-----\n";

package FakeRows;
sub hashes { return $_[0]->{'rows'} }

package FakeCaller;
sub req { return $_[0] }
sub headers { return bless { h => $_[0]->{'headers'} }, 'FakeHeaders' }

package FakeHeaders;
sub header { return $_[0]->{'h'}->{ $_[1] } }

package main;

{
	no warnings 'redefine';
	# The signature itself is covered by the peer crypt tests; here it is the
	# roster search that matters.
	local *subs::peer_verify = sub { return 1 };
	local *subs::db_select = sub {
		my $rows = [
			{
				hostname => 'hub',
				signatorial => 'df48d7c36b59a871ef1da44d778e9f51',
				pubkey => $other,
				mirrors => encode_json([
					{ hostname => 'Dev', signatorial => '6272cece8cf68ec77200c604f4cf2d69',
					  ip => '10.20.0.10', tailnet_ip => '100.64.0.4', pubkey => $pem },
					{ hostname => 'Keyless', signatorial => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
					  ip => '10.0.0.9' },
				]),
			},
		];
		return bless { rows => $rows }, 'FakeRows';
	};

	my $caller = sub {
		my ($key) = @_;
		return bless { headers => {
			'X-Peer-Signature' => 'c2ln',
			'X-Peer-Key' => encode_base64($key, ''),
			'X-Peer-Timestamp' => time(),
			'X-Peer-Nonce' => 'abcdefgh12345678',
		} }, 'FakeCaller';
	};

	ok(Manager::app_peer_ok($caller->($pem)),
		'a machine the hub listed can use the app rail');
	ok(Manager::app_peer_ok($caller->($other)),
		'a direct row\'s own key still works');
	my $stranger = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA" . ('q' x 43) . "=\n-----END PUBLIC KEY-----\n";
	ok(!Manager::app_peer_ok($caller->($stranger)),
		'a key nobody published is still refused');
	my $unsigned = bless { headers => { 'X-Peer-Key' => encode_base64($pem, '') } }, 'FakeCaller';
	ok(!Manager::app_peer_ok($unsigned), 'an unsigned frame is never proof');
}

# The route has to use that proof.
my $route = do { local $/; open(my $fh, '<', 'lib/JawnOS/Controller/manager_ws.pm') or die $!; <$fh> };
like($route, qr/unless \(&app_peer_ok\(\$c\)\)/, 'the device relay asks the app rail');

done_testing();
