package Printer;

# The printer rail: one standalone page that draws a real manager printer on a
# canvas for an app widget to capture. The route is app-gated by the global
# before_dispatch hook (the WebView's session cookie is the credential), so a
# page with no session is handed the Gate page like any other manager route.
#
# The page is loaded by Android's headless WebView; it needs no Manager.pl
# `require` ordering beyond this file being loaded after Mojolicious::Lite has
# made the app (Manager::app). Nothing here writes to the database.

use strict;
use warnings;
use feature 'signatures';
no warnings 'experimental::signatures';

my @printer_kinds = qw(clockface timeline leaderboard calendar narrator continent);

Manager::app->routes->get('/manager/printer' => sub ($c) {

	my $kind = lc($c->param('kind') // 'clockface');
	$kind = 'clockface' unless grep { $_ eq $kind } @printer_kinds;

	# the widget sends its content size in CSS pixels; clamp a bad or absurd one
	my $w = int($c->param('w') // 500);
	my $h = int($c->param('h') // 500);
	$w = 500 unless $w >= 32 && $w <= 4096;
	$h = 500 unless $h >= 32 && $h <= 4096;

	# the scope owns the window appointment_viewer computes its percents over
	my $scope = lc($c->param('scope') // 'day');
	my $span = eval { &subs::time_span($scope, &subs::rightNow()) };
	$scope = 'day' unless defined $span;

	# the layout names the printer; default it to the kind the caller asked for
	my $layout = lc($c->param('layout') // $kind);
	$layout = $kind unless grep { $_ eq $layout } @printer_kinds;

	$c->res->headers->cache_control('no-store, max-age=0');
	$c->render(
		template => 'printer/widget',
		layout => undef,
		kind => $kind,
		w => $w,
		h => $h,
		scope => $scope,
		layout => $layout,
	);
});

1;
