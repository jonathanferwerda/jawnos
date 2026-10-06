#!/data/data/com.termux/files/usr/bin

`termux-toast hello`;
my $app = shift;
my $action = shift;
use strict;
use warnings;

use Mojolicious::Lite -signatures;
use File::Slurp;
use Mojo::JSON qw(decode_json encode_json);
use SQL::Abstract;
use Mojo::SQLite;
use Data::Dumper;
use URI::Encode qw(uri_encode uri_decode);
use Mojo::Util qw(secure_compare);
use threads;
plugin 'RenderFile';
#chdir('../');
require './gb.pl';
require './subroutines.pl';
require './Websocket.pl';
my ($db) = &subs::database_grabber();
my $timestamp = &subs::rightNow();
my $dir = `pwd`;
&subs::say_it('running');

print $app . "\n";
print $action . "\n";
unless ($app && $action) {
	die;
}
if ($action eq 'close') {
	&subs::window_closer(&subs::unformat_name($app));
}
else {
	my $whoami = `whoami`;
	chomp $whoami;
	my $hostname = `hostname`;
	chomp $hostname;
	my $command;
	if ($action eq 'show') {
		$command = "appointmentGrabber('$app')";
	}
	my $msg = { app => $app, whoami => $whoami, hostname => $hostname, uuid => &subs::random_string_creator(25), console => $command };
	&Websocket::send('server', $msg);
}

return "heyyyy";