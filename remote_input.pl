package remote_input;
use strict;
use warnings;
use feature 'signatures';

# --- input injection --------------------------------------------------------
#
# One place for the way this machine turns a request into a real pointer or
# keyboard event. teletype.pl (the T-Deck's control channel) and Manager.pl
# (the remote_control panel) both come through here, so a backend installed for
# one works for the other and the argv mapping is tested once.
#
# X11 lets any client move the pointer and press keys, which is what xdotool
# does. Wayland *deliberately* does not: an ordinary client (or a sandboxed one)
# cannot inject input into the compositor. The compositor-independent Wayland
# route is a virtual *kernel* input device (uinput), which is what the
# xdotool-for-Wayland tools are built on:
#
#   dotool   reads actions on stdin ("key ctrl+alt+t", "type hi", "mouseto
#            0.25 0.5", "mousemove 3 -2", "buttondown left"). Closest
#            xdotool-shaped drop-in; needs access to /dev/uinput (AUR on Arch).
#   wtype    the compositor's virtual-keyboard protocol -- typing and keys only
#            (no pointer), and only where the protocol exists (wlroots: sway,
#            Hyprland; not GNOME or KDE).
#   ydotool  also uinput, but its `key` takes Linux input *keycodes*, not
#            keysyms, so key names are unsupported there; pointer and typing
#            work. It needs the ydotoold daemon (`click 0x40` is left down).
#
# Auto-detection keeps every installed backend as a fallback, so a tool that
# cannot perform one action (wtype has no pointer) does not hide another that
# can. A forced backend stays forced.
#
# The backend is chosen from the session and can be forced with the `teletype`
# setting `input_backend` (x11 | dotool | wtype | ydotool | none) or the
# JAWNOS_INPUT_BACKEND environment variable, for a compositor we have not
# covered. With nothing installed the injection is a logged no-op rather than a
# broken keystroke.

our $input_warned = 0;
our $log;

sub set_log {
	($log) = @_;
}

sub which($cmd) {
	for my $dir ( split /:/, ($ENV{PATH} || '/usr/local/bin:/usr/bin:/bin') ) {
		return "$dir/$cmd" if -x "$dir/$cmd";
	}
	return undef;
}

sub wayland_session() {
	return 1 if ($ENV{XDG_SESSION_TYPE} || '') eq 'wayland';
	# XDG_SESSION_TYPE is set by the login session, but a manager started from a
	# service or a nested shell may only have the compositor's own socket.
	return 1 if $ENV{WAYLAND_DISPLAY} || $ENV{SWAYSOCK}
		|| $ENV{HYPRLAND_INSTANCE_SIGNATURE} || $ENV{NIRI_SOCKET};
	return 0;
}

sub backends() {
	my $forced = $ENV{JAWNOS_INPUT_BACKEND}
		|| eval { &subs::setting_grabber({ app => 'teletype', setting => 'input_backend' }) };
	if ($forced && $forced ne 'auto') {
		return ('xdotool') if $forced eq 'x11' || $forced eq 'xdotool';
		return ($forced) if $forced =~ /^(dotool|wtype|ydotool|none)$/;
	}
	my @backends;
	if (wayland_session()) {
		# xdotool cannot reach native Wayland clients.
		push @backends, grep { which($_) } qw(dotool ydotool wtype);
	}
	else {
		push @backends, grep { which($_) } qw(xdotool dotool ydotool wtype);
	}
	return @backends ? @backends : ('none');
}

sub backend() {
	my @backends = backends();
	return $backends[0];
}

sub can_inject() {
	return backend() eq 'none' ? 0 : 1;
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

my %x_button = ( left => 1, middle => 2, right => 3 );
my %y_button = ( left => '40', middle => '42', right => '41' );

# The argv (plus any stdin) for one action on one backend, or {} when that
# backend cannot do it. Kept separate from running it so the mapping is
# testable without touching the pointer.
sub command_for($b, $action, @args) {
	my $button = $args[0] || 'left';
	$button = 'left' unless $x_button{$button};
	if ($b eq 'xdotool') {
		my $n = $x_button{$button};
		return { argv => ['xdotool', 'mousedown', $n] } if $action eq 'mousedown';
		return { argv => ['xdotool', 'mouseup',  $n] } if $action eq 'mouseup';
		return { argv => ['xdotool', 'key',  $args[0]] } if $action eq 'key';
		return { argv => ['xdotool', 'type', '--', $args[0]] } if $action eq 'type';
		return { argv => ['xdotool', 'mousemove', int($args[0]), int($args[1])] } if $action eq 'move';
		return { argv => ['xdotool', 'mousemove_relative', '--', int($args[0]), int($args[1])] } if $action eq 'move_rel';
		if ($action eq 'wheel') {
			my ($dy, $dx) = map { int($_ || 0) } @args;
			my @argv = ('xdotool');
			if ($dy) {
				push @argv, 'click', '--repeat', abs($dy), ($dy > 0 ? '5' : '4');
			}
			if ($dx) {
				push @argv, 'click', '--repeat', abs($dx), ($dx > 0 ? '7' : '6');
			}
			return @argv > 1 ? { argv => \@argv } : {};
		}
		return {};
	}
	if ($b eq 'dotool') {
		# dotool names the buttons and takes a *fraction* of the desktop for
		# an absolute jump; plain mousemove is relative.
		return { argv => ['dotool'], stdin => "buttondown $button\n" } if $action eq 'mousedown';
		return { argv => ['dotool'], stdin => "buttonup $button\n" } if $action eq 'mouseup';
		return { argv => ['dotool'], stdin => "key $args[0]\n" } if $action eq 'key';
		if ($action eq 'type') {
			my $text = $args[0];
			$text =~ s/[\r\n]+/ /g;   # one action per line on dotool's stdin
			return { argv => ['dotool'], stdin => "type $text\n" };
		}
		if ($action eq 'move') {
			my ($x, $y, $w, $h) = @args;
			return {} unless $w && $h;
			$x = 0 if $x < 0;
			$y = 0 if $y < 0;
			$x = $w if $x > $w;
			$y = $h if $y > $h;
			return { argv => ['dotool'], stdin => sprintf("mouseto %.4f %.4f\n", $x / $w, $y / $h) };
		}
		return { argv => ['dotool'], stdin => 'mousemove ' . int($args[0]) . ' ' . int($args[1]) . "\n" } if $action eq 'move_rel';
		return {};
	}
	if ($b eq 'wtype') {
		return { argv => ['wtype', '--', $args[0]] } if $action eq 'type';
		return { argv => [ 'wtype', wtype_key_args($args[0]) ] } if $action eq 'key';
		return {};              # wtype has no pointer control
	}
	if ($b eq 'ydotool') {
		return { argv => ['ydotool', 'type', '--', $args[0]] } if $action eq 'type';
		# 0x40 is left-button down, 0x80 left-button up (ydotool manpage);
		# the middle and right buttons count on from there.
		my $code = $y_button{$button};
		return { argv => ['ydotool', 'click', '0x' . $code] } if $action eq 'mousedown';
		return { argv => ['ydotool', 'click', sprintf('0x%02x', hex($code) + 0x40)] } if $action eq 'mouseup';
		return { argv => ['ydotool', 'mousemove', '--absolute', int($args[0]), int($args[1])] } if $action eq 'move';
		return { argv => ['ydotool', 'mousemove', int($args[0]), int($args[1])] } if $action eq 'move_rel';
		return {};              # key names need keycodes ydotool does not take
	}
	return {};
}

sub command($action, @args) {
	for my $b (backends()) {
		my $c = &command_for($b, $action, @args);
		return $c if $c->{'argv'} && @{$c->{'argv'}};
	}
	if (!$input_warned) {
		$input_warned = 1;
		$log->warn('remote input: no backend (install dotool, wtype or ydotool, or set teletype: input_backend)') if $log;
	}
	return {};
}

sub run_command($c) {
	return 0 unless $c->{'argv'} && @{$c->{'argv'}};
	if (defined $c->{'stdin'}) {
		open(my $fh, '|-', @{$c->{'argv'}}) or return 0;
		print {$fh} $c->{'stdin'};
		close $fh;
		return 1;
	}
	system(@{$c->{'argv'}});
	return 1;
}

sub inject($action, @args) {
	# Letting go of everything is two commands on xdotool (keys and buttons),
	# so it does not fit the one-command shape the rest of the actions use.
	if ($action eq 'release') {
		my $backend = backend();
		if ($backend eq 'xdotool') {
			system('xdotool', 'keyup', 'Shift_L', 'Control_L', 'Alt_L', 'Super_L');
			system('xdotool', 'mouseup', '1', '2', '3');
			return 1;
		}
		if ($backend eq 'dotool') {
			open(my $fh, '|-', 'dotool') or return 0;
			print {$fh} "keyup shift\nkeyup ctrl\nkeyup alt\nkeyup super\n";
			print {$fh} "buttonup left\nbuttonup middle\nbuttonup right\n";
			close $fh;
			return 1;
		}
		for my $button (qw/left middle right/) {
			&inject('mouseup', $button);
		}
		return 1;
	}
	my $c = &command($action, @args);
	return &run_command($c);
}

# The screen the pointer is measured against. X11 answers xprop; on Wayland the
# compositor owns the outputs, so try sway's IPC, then Hyprland's, then a
# `teletype: screen_size` setting ("1920x1080") as the fallback. The union of
# every output is used because an absolute injection addresses the whole
# virtual desktop, not just the first monitor.
sub screen_geometry() {
	unless (wayland_session()) {
		my $s = `xprop -notype -len 16 -root _NET_DESKTOP_GEOMETRY 2>/dev/null`;
		chomp $s;
		return [ $1, $2 ] if $s =~ /=\s*(\d+)\s*,\s*(\d+)/;
		if (which('xdotool')) {
			my $g = `xdotool getdisplaygeometry 2>/dev/null`;
			chomp $g;
			return [ $1, $2 ] if $g =~ /^\s*(\d+)\s+(\d+)\s*$/;
		}
	}
	if (which('swaymsg')) {
		my $j = `swaymsg -t get_outputs 2>/dev/null`;
		my $outputs = eval { require Mojo::JSON; Mojo::JSON::decode_json($j) } || [];
		my ($w, $h);
		for my $o (@{$outputs}) {
			my $r = $o->{'rect'} || {};
			next unless $r->{'width'} && $r->{'height'};
			my $right  = ($r->{'x'} || 0) + $r->{'width'};
			my $bottom = ($r->{'y'} || 0) + $r->{'height'};
			$w = $right  if !defined $w || $right  > $w;
			$h = $bottom if !defined $h || $bottom > $h;
		}
		return [ $w, $h ] if $w && $h;
	}
	if (which('hyprctl')) {
		my $j = `hyprctl monitors -j 2>/dev/null`;
		my $monitors = eval { require Mojo::JSON; Mojo::JSON::decode_json($j) } || [];
		my ($w, $h);
		for my $m (@{$monitors}) {
			next unless $m->{'width'} && $m->{'height'};
			my $right  = ($m->{'x'} || 0) + $m->{'width'};
			my $bottom = ($m->{'y'} || 0) + $m->{'height'};
			$w = $right  if !defined $w || $right  > $w;
			$h = $bottom if !defined $h || $bottom > $h;
		}
		return [ $w, $h ] if $w && $h;
	}
	my $set = eval { &subs::setting_grabber({ app => 'teletype', setting => 'screen_size' }) };
	return [ $1, $2 ] if defined $set && $set =~ /^\s*(\d+)\s*x\s*(\d+)\s*$/;
	return undef;
}

1;
