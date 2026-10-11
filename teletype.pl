#!/usr/bin/perl

use strict;
use warnings;
package teletype;
use Mojolicious::Lite -signatures;
use File::Slurp;
use Mojo::JSON qw(decode_json encode_json);
use SQL::Abstract;
use Mojo::SQLite;
use Data::Dumper;
use URI::Encode qw(uri_encode uri_decode);
use Mojo::Util qw(secure_compare);
use Time::Local;
plugin 'RenderFile';
no warnings 'uninitialized';
# the gb globals below live in gb.pl and are written or read from every
# corner of the house; a file that touches one only once is not a typo
no warnings 'once';
require './subroutines.pl';
require './gb.pl';
require './watch.pl';
require './Websocket.pl';


my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
my $device = &subs::device_setter();
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);


sub auth_check($c) {
	my $lock = &subs::setting_grabber({ app => 'teletype', setting => 'tauthorization' });
	my $patience = &subs::setting_grabber({ app => 'teletype', setting => 'patience' });
	my $authorship = `echo $lock | base64 --decode`;
	my $auth = &subs::note_decrypter($patience,$authorship);
	chomp $auth;
	my @t = localtime(time);
	my $offset = timegm(@t) - timelocal(@t);
	my $server_time = time();
	if ($c->param('first_check') eq 'true') {
		my $tauthorization = $c->param('tauthorization');
		chomp $tauthorization;
		my $tty_port = $ENV{PORT_BESTOW};
		if ($tauthorization && secure_compare $auth, $tauthorization) {
			my $info = {
				tty_port => $tty_port,
				tauthorization => $lock,
				result => "approved",
				server_time => $server_time,
				offset => $offset,
				returner => "You're so in!"
			};

			return $info;
		}
		else {
			return { result => "denial" };
		}
	}
	else {
		my $saved_auth = $c->param('tauthorization');
		my $authors = `echo $saved_auth | base64 --decode`;
		my $au = &subs::note_decrypter($patience, $authors);
		chomp $au;
		if ($au eq $auth) {
			my $sa = `echo $saved_auth | base64 --decode`;
			my $result = "You said " . $c->param('life');

			return { result => "approved" , returner => $result, tauthorization => $saved_auth, server_time => $server_time, offset => $offset};
		}
	}
};

# --- input injection --------------------------------------------------------
#
# X11 lets any client move the pointer and press keys, which is what xdotool
# does. Wayland *deliberately* does not: an ordinary client (or a sandboxed one)
# cannot inject input into the compositor. The compositor-independent Wayland
# route is a virtual *kernel* input device (uinput), which is what the
# xdotool-for-Wayland tools are built on:
#
#   dotool   reads xdotool-shaped commands on stdin ("key ctrl+alt+t", "type
#            hi", "mousemove 10 20", "buttondown 1"). Closest drop-in; needs
#            access to /dev/uinput (AUR on Arch).
#   wtype    the compositor's virtual-keyboard protocol -- typing and keys only
#            (no pointer), and only where the protocol exists (wlroots: sway,
#            Hyprland; not GNOME or KDE).
#   ydotool  also uinput, but its `key` takes Linux input *keycodes*, not
#            keysyms, so the key names below are awkward there; pointer and
#            typing work. Supported for those, not for key names.
#
# The backend is chosen from the session and can be forced with the `teletype`
# setting `input_backend` (x11 | dotool | wtype | ydotool | none) or the
# JAWNOS_INPUT_BACKEND environment variable, for a compositor we have not
# covered. With nothing installed the injection is a logged no-op rather than a
# broken keystroke.

sub which($cmd) {
	for my $dir ( split /:/, ($ENV{PATH} || '/usr/local/bin:/usr/bin:/bin') ) {
		return "$dir/$cmd" if -x "$dir/$cmd";
	}
	return undef;
}

sub wayland_session() {
	return (($ENV{XDG_SESSION_TYPE} || '') eq 'wayland' || $ENV{WAYLAND_DISPLAY}) ? 1 : 0;
}

sub input_backend() {
	my $forced = $ENV{JAWNOS_INPUT_BACKEND}
		|| &subs::setting_grabber({ app => 'teletype', setting => 'input_backend' });
	if ($forced && $forced ne 'auto') {
		return 'xdotool' if $forced eq 'x11' || $forced eq 'xdotool';
		return $forced if $forced =~ /^(dotool|wtype|ydotool|none)$/;
	}
	if (wayland_session()) {
		return 'dotool' if which('dotool');
		return 'wtype'  if which('wtype');
		return 'none';          # xdotool cannot reach native Wayland clients
	}
	return 'xdotool' if which('xdotool');
	return 'none';
}

# wtype wants modifiers as -M/-m around a -k key, so "ctrl+alt+t" becomes
# -M ctrl -M alt -k t -m alt -m ctrl.
sub wtype_key_args($spec) {
	my @parts = split /\+/, $spec;
	my $key = pop @parts;
	my @argv;
	push @argv, '-M', $_ for @parts;
	push @argv, '-k', $key;
	push @argv, '-m', $_ for reverse @parts;
	return @argv;
}

our $input_warned = 0;

# The argv (plus any stdin) for one injected action, or {} when the backend
# cannot do it. Kept separate from running it so the mapping is testable.
sub input_command($action, @args) {
	my $b = input_backend();
	if ($b eq 'xdotool') {
		return { argv => ['xdotool', 'mousedown', '1'] } if $action eq 'mousedown';
		return { argv => ['xdotool', 'mouseup',  '1'] } if $action eq 'mouseup';
		return { argv => ['xdotool', 'key',  $args[0]] } if $action eq 'key';
		return { argv => ['xdotool', 'type', $args[0]] } if $action eq 'type';
		return { argv => ['xdotool', 'mousemove', $args[0], $args[1]] } if $action eq 'move';
		return { argv => ['xdotool', 'mousemove_relative', '--', $args[0], $args[1]] } if $action eq 'move_rel';
		return {};
	}
	if ($b eq 'dotool') {
		my $line =
			  $action eq 'mousedown' ? 'buttondown 1'
			: $action eq 'mouseup'   ? 'buttonup 1'
			: $action eq 'key'       ? "key $args[0]"
			: $action eq 'type'      ? "type $args[0]"
			: $action eq 'move'      ? "mousemove $args[0] $args[1]"
			: $action eq 'move_rel'  ? "mousemove_relative $args[0] $args[1]"
			: undef;
		return {} unless defined $line;
		return { argv => ['dotool'], stdin => "$line\n" };
	}
	if ($b eq 'wtype') {
		return { argv => ['wtype', '--', $args[0]] } if $action eq 'type';
		return { argv => [ 'wtype', wtype_key_args($args[0]) ] } if $action eq 'key';
		return {};              # wtype has no pointer control
	}
	if ($b eq 'ydotool') {
		return { argv => ['ydotool', 'type', '--', $args[0]] } if $action eq 'type';
		return {};              # key names need keycodes ydotool does not take
	}
	if (!$input_warned) {
		$input_warned = 1;
		$log->warn('teletype input: no backend (install dotool, wtype or ydotool, or set teletype: input_backend)') if $log;
	}
	return {};
}

sub inject($action, @args) {
	my $c = &input_command($action, @args);
	return unless $c->{'argv'} && @{$c->{'argv'}};
	if (defined $c->{'stdin'}) {
		open(my $fh, '|-', @{$c->{'argv'}}) or return;
		print {$fh} $c->{'stdin'};
		close $fh;
		return;
	}
	system(@{$c->{'argv'}});
}

# The screen the pointer is measured against. X11 answers xprop; on Wayland the
# compositor owns the outputs, so try sway's IPC, then a `teletype:
# screen_size` setting ("1920x1080") as the fallback.
sub screen_geometry() {
	unless (wayland_session()) {
		my $s = `xprop -notype -len 16 -root _NET_DESKTOP_GEOMETRY 2>/dev/null`;
		chomp $s;
		return [ $1, $2 ] if $s =~ /=\s*(\d+)\s*,\s*(\d+)/;
	}
	if (which('swaymsg')) {
		my $j = `swaymsg -t get_outputs 2>/dev/null`;
		my $outputs = eval { decode_json $j } || [];
		for my $o (@{$outputs}) {
			my $r = $o->{'rect'} || {};
			return [ $r->{'width'}, $r->{'height'} ] if $r->{'width'} && $r->{'height'};
		}
	}
	my $set = &subs::setting_grabber({ app => 'teletype', setting => 'screen_size' });
	return [ $1, $2 ] if defined $set && $set =~ /^\s*(\d+)\s*x\s*(\d+)\s*$/;
	return undef;
}

get '/teletype/information' => sub($c) {
	my $auth_check = &auth_check($c);
	if ( $auth_check->{'result'} eq 'approved') {
		my ($db,$database) = &subs::database_grabber();

		my $server_time = &subs::rightNow();
		my $timestamp = $c->param('timestamp') * 1000;
		my $life = &subs::unformat_name($c->param('life'));
		my ($app,$type) = &subs::typesetter($life);
		&subs::setting_setter({ app => $app, setting => 'pos', value => $type });
		my $init = &subs::setting_initializer($app,$timestamp);
	
		my $insert = &subs::db_insert('appointments', {
			app => $app,
			server_time => $server_time,
			timestamp => $timestamp,
			type => 'text',
#			toggle => $b->{'toggle'}
			uuid => &subs::random_string_creator(40)
		});
		$c->render(json => $auth_check);
		my $msg = { app => $app, console => 'appointmentGrabber("' . $app . '",' . $timestamp . ')' };
		&Websocket::send('server', $msg);
	}
};

websocket '/teletype/ws' => sub($c) {
	my $auth_check = &auth_check($c);
	if ($auth_check->{'result'} eq 'approved') {
		$c->on(message => sub ($ws, $msg) {
			my $server_time = &subs::rightNow();
			if ($msg eq 'hey') {
				$c->send('Hey yourself!');
			}
			else { #if (	&subs::setting_grabber({ app => 'teletype', setting => 'enabled' }) eq 1) {
				my ($db,$database) = &subs::database_grabber();
				my $m = eval { return decode_json $msg } || {};
				my $resolution = &screen_geometry();
				if ($m->{'command'} eq 'mouse') {
					if ($m->{'movement'} eq "button") {
						if ($m->{'value'} == 0) {
							&inject('mousedown') if $device eq 'computer';
						}
						elsif ($m->{'value'} == 1) {
							&inject('mouseup') if $device eq 'computer';
						}
					}
					if ($device eq 'mobile') {
						&Websocket::send('tab', $msg);

					}
				}
				elsif ($m->{'command'} eq 'keypress') {
					my $key = $m->{'key'};
					my @keyboard = grep { $_->{'num'} eq $key } @{$gb::inputs};

					if ($keyboard[0]->{'trigger'} eq 'key') {
						&inject('key', $keyboard[0]->{'img'});
					}
					else {
						&inject('type', $keyboard[0]->{'c'});
					}
				}
				elsif ($m->{'command'} eq 'touch') {
					if ($device eq 'mobile') {
						my $ms = {
							'x' => $m->{'x'},
							'y' => $m->{'y'},
							'res_x' => $m->{'res_x'},
							'res_y' => $m->{'res_y'},
							'command' => 'touch'
						};
						&Websocket::send('tab', $ms);
					}
					elsif ($device eq 'computer' && $resolution && $m->{'res_x'} && $m->{'res_y'}) {
						my ($screen_x,$screen_y) = @{$resolution};
						my $x = ($screen_x / $m->{'res_x'}) * $m->{'y'};
						my $y = ($screen_y / $m->{'res_y'}) * ($m->{'res_y'} - $m->{'x'});
						if ($m->{'mmr'} eq "off") {
							&inject('move', $x, $y);
						}
						elsif ($m->{'last_y'} && $m->{'last_x'} && $m->{'touching'} == 1) {
							my $new_x = ($m->{'y'} - $m->{'last_y'} ) * 3;
							my $new_y = ($m->{'last_x'} - $m->{'x'} ) * 3;
							&inject('move_rel', $new_x, $new_y);
						}
					}
				}
			}
		});
	}
};

if (!$ENV{PURPOSE} || $ENV{PURPOSE} eq "teletype") { 
	app->sessions->samesite('lax');
	$ENV{MOJO_MAX_MESSAGE_SIZE} = 1023423423473741824;
	app->renderer->cache->max_keys(0);
	app->sessions->encrypted(1);
	app->secrets($gb::secret_maker);
	app->sessions->cookie_name($ENV{'cookie_name'});
	if ($config->{'environment'} eq 'production') {
		app->log->level('error'); 
	} else {
		app->log->level('debug'); 
	}
	app->start;
}
else {
	1;
}