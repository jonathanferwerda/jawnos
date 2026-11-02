# tests-for: lib/JawnOS/Domain/Name.pm lib/JawnOS/Controller/Root_misc.pm lib/JawnOS/Routes/Root_misc.pm lib/JawnOS/Controller/manifest_json_misc.pm lib/JawnOS/Manager/Part30.pm perl/hooks.pl templates/layouts/manager.html.ep templates/layouts/homepage.html.ep templates/layouts/store.html.ep templates/layouts/public_view.html.ep templates/layouts/padlock_key.html.ep
# covers:    the house mark is one cacheable URL, never 195 KB of base64 inside every page.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use MIME::Base64 ();
use JawnOSTest;

# The domain layer is lazy: preload the real definitions before the local stubs
# below replace them for the call.
subs::preload('logo_data_uri data_uri_parts');

package FakeRows;
sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
sub hashes { $_[0]->{'rows'} }

package main;

# --- a data: URI becomes its type and bytes -----------------------------------
my $png = "\x89PNG\r\n\x1a\n";
my $uri = 'data:image/png;base64,' . MIME::Base64::encode_base64($png, '');
my $parts = &subs::data_uri_parts($uri);
ok(ref $parts eq 'HASH', 'a base64 data: URI parses');
is($parts->{'mime'}, 'image/png', 'the media type is kept');
is($parts->{'bytes'}, $png, 'the bytes are decoded');
is_deeply(&subs::data_uri_parts(''), undef, 'an empty value has no bytes');
is_deeply(&subs::data_uri_parts('https://example.test/logo.png'), undef, 'a plain URL is not a data: URI');
is_deeply(&subs::data_uri_parts('data:image/png;base64,'), undef, 'an empty payload has no bytes');

# newlines in the base64 body (what a form upload can produce) are ignored
my $wrapped = 'data:image/png;base64,' . MIME::Base64::encode_base64($png, "\n");
is(&subs::data_uri_parts($wrapped)->{'bytes'}, $png, 'line-wrapped base64 still decodes');

# --- the settings row is the source, and only the favicon route reads it ------
{
	no warnings 'once';
	local *subs::db_query = sub {
		my ($sql) = @_;
		like($sql, qr/from settings where app = 'me' and setting = 'logo'/, 'the logo query names its row');
		return FakeRows->new([ { value => $uri } ]);
	};
	is(&subs::logo_data_uri(), $uri, 'the stored data: URI is returned');
}
{
	no warnings 'once';
	local *subs::db_query = sub { return FakeRows->new([]) };
	is(&subs::logo_data_uri(), undef, 'a house with no mark answers undef');
}

# --- the route exists, is public, and matches its action ----------------------
my $repo = root();
my $routes = read_file("$repo/lib/JawnOS/Routes/Root_misc.pm");
like($routes, qr/\[\s*2999\s*,\s*'get'\s*,\s*'\/house\/logo\.png'\s*,\s*'action_2999'\s*\]/,
	'the logo route is registered as a public GET');
my $controller = read_file("$repo/lib/JawnOS/Controller/Root_misc.pm");
like($controller, qr/^sub action_2999\b/m, 'the route has its action');
like($controller, qr/if_none_match/, 'a repeat request can answer 304');
like($controller, qr/cache_control\(/, 'the response is cacheable');

# --- no layout inlines the image any more ------------------------------------
for my $layout (qw(manager homepage store public_view padlock_key)) {
	my $source = read_file("$repo/templates/layouts/$layout.html.ep");
	unlike($source, qr/setting_grabber\(\{\s*app\s*=>\s*'me'\s*,\s*setting\s*=>\s*'logo'/,
		"$layout does not fetch the data: URI");
	like($source, qr{href=["']/house/logo\.png["']}, "$layout points at the favicon URL");
}

# --- the manifest names the URL instead of embedding the image twice ---------
my $manifest = read_file("$repo/lib/JawnOS/Controller/manifest_json_misc.pm");
like($manifest, qr{"/house/logo\.png"}, 'the manifest icons use the favicon URL');
unlike($manifest, qr/settings_grabber\(\{\s*app\s*=>\s*'me'\s*,\s*settings\s*=>\s*\['logo'/,
	'the manifest no longer loads the logo value');

# --- the app gate lets the published mark through, and only it ---------------
require "$repo/lib/JawnOS/Manager/Part30.pm";
ok(Manager::app_public_path('/house/logo.png'), 'the favicon is reachable before a session');
ok(!Manager::app_public_path('/house/other.png'), 'the public exemption is that one path');
my $hooks = read_file("$repo/perl/hooks.pl");
like($hooks, qr{\$path ne '/house/logo\.png'}, 'the locker gate lets the mark through as well');

done_testing();
