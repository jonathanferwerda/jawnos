# tests-for: Dockerfile compose.yaml docker/entrypoint.sh
# covers:    the container packaging keeps the app's own contracts. The image
#           installs every distribution the tree loads (including the two the
#           dependency checker's list omits), first boot goes through
#           scripts/jawnos_setup.pl --seed instead of inventing a second setup,
#           and the published websocket port stays one above the manager port.

use strict;
use warnings;

use FindBin;
use Test::More;

my $root = "$FindBin::Bin/..";

sub slurp {
	my ($rel) = @_;
	open( my $fh, '<', "$root/$rel" ) or return undef;
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

my $dockerfile = slurp('Dockerfile');
my $compose    = slurp('compose.yaml');
my $entry      = slurp('docker/entrypoint.sh');
my $ignore     = slurp('.dockerignore');

ok( defined $dockerfile, 'Dockerfile exists' );
ok( defined $compose,    'compose.yaml exists' );
ok( defined $entry,      'docker/entrypoint.sh exists' );
ok( defined $ignore,     '.dockerignore exists' );
ok( -x "$root/docker/entrypoint.sh", 'the entry point is executable' );

my $syntax = system( '/bin/sh', '-n', "$root/docker/entrypoint.sh" );
is( $syntax, 0, 'the entry point parses under /bin/sh' );

# Distributions the tree loads at boot. Text::Unidecode and Email::Sender are
# exactly the drift to catch: both are used by the domain layer but neither is
# in scripts/jawnos_deps.pl's @modules list.
my @dist = qw(
	Mojolicious Mojo::SQLite Minion Mojo::IOLoop::ReadWriteFork
	Sereal::Encoder Sereal::Decoder Crypt::Simple CryptX Net::SSLeay
	File::Slurp SQL::Abstract Data::UUID MIME::Parser Email::Stuffer
	Email::Sender Authen::SASL Text::Unidecode
	Mojolicious::Plugin::RenderFile LWP::UserAgent LWP::Protocol::https
	WWW::Mechanize HTML::Strip URI::Encode File::Type Number::Format
	Date::Parse Hash::Merge Time::Duration Compress::Zlib Clone
);
for my $module (@dist) {
	like( $dockerfile, qr/(?:^|\s)\Q$module\E(?:\s|\\|$)/m, "the image installs $module" );
}

# The live database must never become an image layer; only the factory seed and
# the schema are needed to build a fresh one.
like( $ignore, qr{^database/\*$}m,              '.dockerignore excludes the live database' );
like( $ignore, qr{^!database/initial\.enc$}m,   'the factory seed is kept' );
like( $ignore, qr{^!database/schema\.sql$}m,    'the schema is kept' );
like( $ignore, qr{^\.secrets$}m,                'credentials never enter the image' );
like( $ignore, qr{^docs/AGENTS-notes\.md$}m,    'the token-bearing field notes never enter the image' );

like( $compose, qr{^services:$}m,          'compose declares services' );
like( $compose, qr{^  jawnos:$}m,          'the service is named jawnos' );
like( $compose, qr{jawnos-database:/app/database}, 'the database is a volume' );
like( $compose, qr{jawnos-home:/home/jawn},       'config and state are a volume' );
like( $compose, qr{^\s+init: true$}m,             'a tiny init reaps orphaned workers' );

my ($working) = $compose =~ /JAWNOS_WORKING_PORT:-(\d+)/;
my ($ws)      = $compose =~ /JAWNOS_WS_PORT:-(\d+)/;
ok( defined $working, 'compose defaults the manager port' );
ok( defined $ws,      'compose defaults the websocket port' );
is( $ws, defined $working ? $working + 1 : undef,
	'the websocket default is one above the manager port' );
my $published = "\${JAWNOS_WORKING_PORT:-$working}:\${JAWNOS_WORKING_PORT:-$working}";
like( $compose, qr/\Q$published\E/, 'the manager port is published' );

like( $entry, qr{scripts/jawnos_setup\.pl --seed}, 'first boot uses the non-interactive seed' );
like( $entry, qr{exec perl \./jawn},                    'the tree runs in the foreground under the image Perl' );
like( $entry, qr{\.president/pid},                 'a stale pid from the previous container is cleared' );
like( $entry, qr{open_browser},                    'the container turns the browser off' );
like( $entry, qr{unlock code},                     'the generated unlock code is surfaced' );
like( $entry, qr{ln -sfn "\$CONFIG" "\$APP/config\.json"},
	'config.json is the home-volume file, linked into the tree' );

done_testing();
