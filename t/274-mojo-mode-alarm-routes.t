# tests-for: perl/President.pl perl/Alarm.pl
# covers:    Mojo's mode follows the configured environment, so a production
#           tree builds each app in production mode and a dying route renders
#           the generic 500 page instead of the development stack trace; and the
#           alarm listener answers GET / and a catch-all 404 instead of a 500
#           for a request that has no route.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $president = read_file(root() . '/perl/President.pl');

# --- the master sets the mode the children inherit --------------------------
#
# JawnOS::startup runs in the Manager and Alarm children, which read MOJO_MODE
# when they build the app. The master has to set it first so both inherit it.
my $mode_at = index($president, '$ENV{MOJO_MODE}');
ok($mode_at >= 0, 'President sets MOJO_MODE');
like(
	$president,
	qr/\$ENV\{MOJO_MODE\}\s*=\s*\$config->\{'environment'\}/,
	'from the configured environment',
);
like(
	$president,
	qr/defined \$config->\{'environment'\}\s*&&\s*\$config->\{'environment'\}\s*=~\s*\/\\S\//,
	'and only when that value is not empty',
);

my $manager_at = index($president, "server_process('./perl/Manager.pl'");
my $alarm_at   = index($president, "server_process('./perl/Alarm.pl'");
ok($manager_at > $mode_at, 'the mode is set before the Manager listener starts');
ok($alarm_at > $mode_at, 'and before the Alarm listener starts');

# --- production mode renders the generic page -------------------------------
#
# The mechanism, exercised on a bare app: the mode is read at construction, and
# a dying route's body must not be the development page.
{
	local $ENV{MOJO_MODE} = 'production';
	require Mojolicious;
	require Mojo::Transaction::HTTP;

	my $app = Mojolicious->new;
	is($app->mode, 'production', 'an app built with the production mode reports it');

	$app->routes->get('/die' => sub { die "boom\n" });
	my $tx = Mojo::Transaction::HTTP->new;
	$tx->req->method('GET');
	$tx->req->url->path('/die');
	$app->handler($tx);

	is($tx->res->code, 500, 'a dying route is still a 500');
	unlike($tx->res->body, qr/development mode/,
		'and the body is not the development page');
	like($tx->res->body, qr/Server Error/, 'it is the generic server error page');
}

# --- the alarm listener answers, it does not 500 ----------------------------
#
# Load it with no PURPOSE so the file only registers its routes; app->start is
# inside the PURPOSE=alarm branch and never runs here.
{
	local $ENV{PURPOSE}   = '';
	local $ENV{MOJO_MODE} = 'production';

	require "./perl/Alarm.pl";

	my $app = Alarm::app();
	ok($app, 'the alarm file still yields its app');

	my $root = Mojo::Transaction::HTTP->new;
	$root->req->method('GET');
	$root->req->url->path('/');
	$app->handler($root);

	is($root->res->code, 200, 'GET / on the alarm listener is a 200');
	unlike($root->res->body, qr/Route without action/,
		'and it is not the no-route 500');
	like($root->res->body, qr/alarm listener ok/, 'the health text answers');

	my $missing = Mojo::Transaction::HTTP->new;
	$missing->req->method('GET');
	$missing->req->url->path('/not-a-route');
	$app->handler($missing);

	is($missing->res->code, 404, 'an unknown path is a 404');
	isnt($missing->res->code, 500, 'never a 500');
}

done_testing();
