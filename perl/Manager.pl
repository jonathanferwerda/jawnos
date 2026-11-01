#!/usr/bin/perl
# Manager.pl is now a launcher. The app is lib/JawnOS.pm; its routes are
# lib/JawnOS/Routes and its actions lib/JawnOS/Controller/*.pm, and the old
# Manager.pl body (config, state, helpers, hooks, session settings) is
# lib/JawnOS/Manager.pm (package Manager, a Mojolicious::Controller subclass).
#
# President.pl, watch.pl, teletype.pl, scripts and morbo load ./perl/Manager.pl and
# expect either an app object back or a running server, so this keeps that
# contract.
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
$ENV{MOJO_HOME} ||= "$FindBin::Bin/..";

require JawnOS;
my $app = JawnOS->new;

if ($ENV{PURPOSE} && $ENV{PURPOSE} ne 'alarm' && $ENV{PURPOSE} ne 'watch' && $ENV{PURPOSE} ne 'teletype') {
	$app->start;
}
else {
	$app;
}
