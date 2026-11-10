package JawnOS::GameMapping;

use strict;
use warnings;

# The physical buttons the Gou exposes to the house. The index is what the
# daemon reports and what a RetroArch remap writes: B=0 ... R2=13. The token is
# what the page stores in a mapping and what a person sees as its label.
our @PHYSICAL = (
	{ token => 'b',          label => 'B',      index => 0 },
	{ token => 'a',          label => 'A',      index => 1 },
	{ token => 'x',          label => 'X',      index => 2 },
	{ token => 'y',          label => 'Y',      index => 3 },
	{ token => 'select',     label => 'Select', index => 4 },
	{ token => 'start',      label => 'Start',  index => 5 },
	{ token => 'dpad_up',    label => 'Up',     index => 6 },
	{ token => 'dpad_down',  label => 'Down',   index => 7 },
	{ token => 'dpad_left',  label => 'Left',   index => 8 },
	{ token => 'dpad_right', label => 'Right',  index => 9 },
	{ token => 'l',          label => 'L',      index => 10 },
	{ token => 'r',          label => 'R',      index => 11 },
	{ token => 'l2',         label => 'L2',     index => 12 },
	{ token => 'r2',         label => 'R2',     index => 13 },
);

our %PHYSICAL = map { $_->{'token'} => $_ } @PHYSICAL;

sub physical_buttons { return [ map { { %$_ } } @PHYSICAL ] }
sub physical_index   { my ($token) = @_; return $PHYSICAL{$token} ? $PHYSICAL{$token}->{'index'} : undef }
sub physical_label   { my ($token) = @_; return $PHYSICAL{$token} ? $PHYSICAL{$token}->{'label'} : undef }

# One table for every console the page offers. `buttons` is the drawing order
# and the row order: token, label and the place the picture puts it. `retropad`
# is the core's own button name (the suffix of input_player1_<name>_btn), so a
# console button and its remap line cannot drift apart. `default` is the
# physical -> console assignment a fresh install starts from.
our %SYSTEMS = (
	n64 => {
		key   => 'n64',
		label => 'Nintendo 64',
		core  => 'Mupen64Plus-Next',
		buttons => [
			{ token => 'dpad_up',    label => 'Up',      x => 70,  y => 83,  r => 15 },
			{ token => 'dpad_down',  label => 'Down',    x => 70,  y => 137, r => 15 },
			{ token => 'dpad_left',  label => 'Left',    x => 43,  y => 110, r => 15 },
			{ token => 'dpad_right', label => 'Right',   x => 97,  y => 110, r => 15 },
			{ token => 'start',      label => 'Start',   x => 170, y => 105, r => 13 },
			{ token => 'z',          label => 'Z',       x => 170, y => 145, shape => 'rect', w => 56, h => 20 },
			{ token => 'l',          label => 'L',       x => 55,  y => 32,  shape => 'rect', w => 52, h => 18 },
			{ token => 'r',          label => 'R',       x => 285, y => 32,  shape => 'rect', w => 52, h => 18 },
			{ token => 'c_up',       label => 'C Up',    x => 222, y => 72,  r => 14 },
			{ token => 'c_down',     label => 'C Down',  x => 222, y => 114, r => 14 },
			{ token => 'c_left',     label => 'C Left',  x => 200, y => 93,  r => 14 },
			{ token => 'c_right',    label => 'C Right', x => 244, y => 93,  r => 14 },
			{ token => 'a',          label => 'A',       x => 286, y => 93,  r => 15 },
			{ token => 'b',          label => 'B',       x => 268, y => 122, r => 15 },
		],
		retropad => {
			a => 'b', b => 'y',
			c_up => 'x', c_down => 'a', c_left => 'l', c_right => 'r',
			z => 'l2', l => 'select', r => 'r2', start => 'start',
			dpad_up => 'up', dpad_down => 'down', dpad_left => 'left', dpad_right => 'right',
		},
		# The GoldenEye scheme: the four face buttons are the C buttons, the
		# right trigger fires (N64 A) and the left trigger uses (N64 B).
		default => {
			a => 'c_down', b => 'c_right', x => 'c_up', y => 'c_left',
			r2 => 'a', l2 => 'b', r => 'z', l => 'r', start => 'start',
			dpad_up => 'dpad_up', dpad_down => 'dpad_down',
			dpad_left => 'dpad_left', dpad_right => 'dpad_right',
		},
	},
	psx => {
		key   => 'psx',
		label => 'PlayStation',
		core  => 'PCSX-ReARMed',
		buttons => [
			{ token => 'dpad_up',    label => 'Up',       x => 70,  y => 83,  r => 15 },
			{ token => 'dpad_down',  label => 'Down',     x => 70,  y => 137, r => 15 },
			{ token => 'dpad_left',  label => 'Left',     x => 43,  y => 110, r => 15 },
			{ token => 'dpad_right', label => 'Right',    x => 97,  y => 110, r => 15 },
			{ token => 'select',     label => 'Select',   x => 156, y => 105, r => 12 },
			{ token => 'start',      label => 'Start',    x => 176, y => 105, r => 12 },
			{ token => 'l2',         label => 'L2',       x => 55,  y => 12,  shape => 'rect', w => 52, h => 14 },
			{ token => 'r2',         label => 'R2',       x => 285, y => 12,  shape => 'rect', w => 52, h => 14 },
			{ token => 'l1',         label => 'L1',       x => 55,  y => 32,  shape => 'rect', w => 52, h => 18 },
			{ token => 'r1',         label => 'R1',       x => 285, y => 32,  shape => 'rect', w => 52, h => 18 },
			{ token => 'triangle',   label => 'Triangle', x => 242, y => 93,  r => 15 },
			{ token => 'square',     label => 'Square',   x => 264, y => 71,  r => 15 },
			{ token => 'circle',     label => 'Circle',   x => 286, y => 93,  r => 15 },
			{ token => 'cross',      label => 'Cross',    x => 264, y => 115, r => 15 },
		],
		retropad => {
			cross => 'b', circle => 'a', square => 'y', triangle => 'x',
			l1 => 'l', r1 => 'r', l2 => 'l2', r2 => 'r2',
			start => 'start', select => 'select',
			dpad_up => 'up', dpad_down => 'down', dpad_left => 'left', dpad_right => 'right',
		},
		default => {
			b => 'cross', a => 'circle', y => 'square', x => 'triangle',
			l => 'l1', r => 'r1', l2 => 'l2', r2 => 'r2',
			start => 'start', select => 'select',
			dpad_up => 'dpad_up', dpad_down => 'dpad_down',
			dpad_left => 'dpad_left', dpad_right => 'dpad_right',
		},
	},
	snes => {
		key   => 'snes',
		label => 'Super Nintendo',
		core  => 'Snes9x',
		buttons => [
			{ token => 'dpad_up',    label => 'Up',     x => 70,  y => 83,  r => 15 },
			{ token => 'dpad_down',  label => 'Down',   x => 70,  y => 137, r => 15 },
			{ token => 'dpad_left',  label => 'Left',   x => 43,  y => 110, r => 15 },
			{ token => 'dpad_right', label => 'Right',  x => 97,  y => 110, r => 15 },
			{ token => 'select',     label => 'Select', x => 156, y => 105, r => 12 },
			{ token => 'start',      label => 'Start',  x => 176, y => 105, r => 12 },
			{ token => 'l',          label => 'L',      x => 55,  y => 32,  shape => 'rect', w => 52, h => 18 },
			{ token => 'r',          label => 'R',      x => 285, y => 32,  shape => 'rect', w => 52, h => 18 },
			{ token => 'x',          label => 'X',      x => 264, y => 71,  r => 15 },
			{ token => 'y',          label => 'Y',      x => 242, y => 93,  r => 15 },
			{ token => 'a',          label => 'A',      x => 286, y => 93,  r => 15 },
			{ token => 'b',          label => 'B',      x => 264, y => 115, r => 15 },
		],
		retropad => {
			b => 'b', y => 'y', a => 'a', x => 'x', l => 'l', r => 'r',
			start => 'start', select => 'select',
			dpad_up => 'up', dpad_down => 'down', dpad_left => 'left', dpad_right => 'right',
		},
		default => {
			b => 'b', y => 'y', a => 'a', x => 'x',
			l => 'l', r => 'r', start => 'start', select => 'select',
			dpad_up => 'dpad_up', dpad_down => 'dpad_down',
			dpad_left => 'dpad_left', dpad_right => 'dpad_right',
		},
	},
	genesis => {
		key   => 'genesis',
		label => 'Genesis',
		core  => 'Genesis Plus GX',
		buttons => [
			{ token => 'dpad_up',    label => 'Up',     x => 70,  y => 83,  r => 15 },
			{ token => 'dpad_down',  label => 'Down',   x => 70,  y => 137, r => 15 },
			{ token => 'dpad_left',  label => 'Left',   x => 43,  y => 110, r => 15 },
			{ token => 'dpad_right', label => 'Right',  x => 97,  y => 110, r => 15 },
			{ token => 'mode',       label => 'Mode',   x => 156, y => 105, r => 12 },
			{ token => 'start',      label => 'Start',  x => 176, y => 105, r => 12 },
			{ token => 'x',          label => 'X',      x => 264, y => 93,  r => 15 },
			{ token => 'y',          label => 'Y',      x => 286, y => 93,  r => 15 },
			{ token => 'z',          label => 'Z',      x => 308, y => 93,  r => 15 },
			{ token => 'a',          label => 'A',      x => 264, y => 115, r => 15 },
			{ token => 'b',          label => 'B',      x => 286, y => 115, r => 15 },
			{ token => 'c',          label => 'C',      x => 308, y => 115, r => 15 },
		],
		retropad => {
			b => 'b', a => 'y', c => 'a', x => 'l', y => 'x', z => 'r',
			start => 'start', mode => 'select',
			dpad_up => 'up', dpad_down => 'down', dpad_left => 'left', dpad_right => 'right',
		},
		default => {
			b => 'b', a => 'a', x => 'x', y => 'y', l => 'c', r => 'z',
			start => 'start', select => 'mode',
			dpad_up => 'dpad_up', dpad_down => 'dpad_down',
			dpad_left => 'dpad_left', dpad_right => 'dpad_right',
		},
	},
);

our @SYSTEM_ORDER = qw(n64 psx snes genesis);

use Mojo::JSON qw(decode_json encode_json);

sub system_keys { return @SYSTEM_ORDER }
sub system_list {
	return [ map { { key => $_, label => $SYSTEMS{$_}{'label'}, core => $SYSTEMS{$_}{'core'} } } @SYSTEM_ORDER ];
}

# An unknown system is not an exception: the page falls back to Nintendo 64 and
# the writer says it cannot write a remap for a console it does not know.
sub resolve_system {
	my ($key) = @_;
	return undef unless defined $key;
	$key = lc $key;
	$key =~ s/^\s+|\s+$//g;
	return exists $SYSTEMS{$key} ? $key : undef;
}

sub profile {
	my ($key) = @_;
	my $resolved = resolve_system($key);
	return $resolved ? $SYSTEMS{$resolved} : undef;
}

sub console_buttons {
	my ($key) = @_;
	my $profile = profile($key) or return [];
	return [ map { { %$_ } } @{ $profile->{'buttons'} } ];
}

sub console_labels {
	my ($key) = @_;
	my $profile = profile($key) or return {};
	return { map { $_->{'token'} => $_->{'label'} } @{ $profile->{'buttons'} } };
}

# A mapping is physical token -> console token. Unknown physical buttons and
# console buttons that do not exist on this system are dropped. One console
# button takes one physical button: the first physical in index order wins, so
# the stored mapping and the remap cannot disagree about which press it means.
sub normalize_mapping {
	my ($key, $raw) = @_;
	my $profile = profile($key) or return undef;
	my $src = ref $raw eq 'HASH' ? $raw : {};
	my %valid = map { $_->{'token'} => 1 } @{ $profile->{'buttons'} };
	my (%out, %taken);
	for my $physical (@PHYSICAL) {
		my $token = $physical->{'token'};
		my $console = $src->{$token};
		next unless defined $console;
		next unless $valid{$console};
		next if $taken{$console}++;
		$out{$token} = $console;
	}
	return \%out;
}

sub default_mapping {
	my ($key) = @_;
	my $profile = profile($key) or return undef;
	return normalize_mapping($key, $profile->{'default'});
}

sub load_mapping {
	my ($key, $raw) = @_;
	my $profile = profile($key) or return undef;
	return default_mapping($key) unless defined $raw && length $raw;
	my $decoded = ref $raw eq 'HASH' ? $raw : eval { decode_json($raw) };
	return default_mapping($key) unless ref $decoded eq 'HASH';
	return normalize_mapping($key, $decoded);
}

sub dump_mapping {
	my $mapping = ref $_[0] eq 'HASH' ? $_[0] : {};
	return encode_json($mapping);
}

# console token -> physical button, the direction the remap writer needs. When
# two physical buttons were stored for one console button, the lower index wins
# (normalize_mapping already prevents that, but a caller can hand us a raw hash).
sub reverse_mapping {
	my ($key, $mapping) = @_;
	my $norm = normalize_mapping($key, $mapping);
	return {} unless ref $norm eq 'HASH';
	my %rev;
	for my $physical (@PHYSICAL) {
		my $console = $norm->{ $physical->{'token'} };
		next unless defined $console;
		$rev{$console} //= $physical->{'token'};
	}
	return \%rev;
}

# input_player1_<retropad>_btn = "<index>", one line per console button that has
# a physical button assigned. The key is the core's RetroPad name, never the
# console's own label, because that is what a .rmp reads.
sub remap_lines {
	my ($key, $mapping) = @_;
	my $profile = profile($key) or return ();
	my $rev = reverse_mapping($key, $mapping);
	my @lines;
	my %seen;
	for my $button (@{ $profile->{'buttons'} }) {
		my $console = $button->{'token'};
		my $retropad = $profile->{'retropad'}{$console};
		next unless defined $retropad;
		next if $seen{$retropad}++;
		my $physical = $rev->{$console};
		next unless defined $physical;
		my $index = physical_index($physical);
		next unless defined $index;
		push @lines, sprintf('input_player1_%s_btn = "%d"', $retropad, $index);
	}
	return @lines;
}

sub remap_text {
	my ($key, $mapping) = @_;
	my @lines = remap_lines($key, $mapping);
	return '' unless @lines;
	return join("\n", @lines) . "\n";
}

sub remap_dir {
	my ($dir) = @_;
	return $dir if defined $dir && length $dir;
	return $ENV{'JAWNOS_MAPPING_DIR'} if defined $ENV{'JAWNOS_MAPPING_DIR'} && length $ENV{'JAWNOS_MAPPING_DIR'};
	my $home = $ENV{'HOME'};
	if (!defined $home || !length $home) {
		$home = (getpwuid($<))[7];
	}
	return join('/', $home, '.config', 'retroarch', 'config', 'remaps');
}

sub remap_path {
	my ($key, $dir) = @_;
	my $profile = profile($key) or return undef;
	return join('/', remap_dir($dir), $profile->{'core'} . '.rmp');
}

# Write through a temporary file in the same directory and rename it over the
# target, so RetroArch never reads a half-written remap. The optional
# before_rename callback is a seam for tests and for callers that want to see
# the staged file; it receives ($temp_path, $target_path).
sub write_remap {
	my ($key, $mapping, $opts) = @_;
	$opts ||= {};
	my $profile = profile($key);
	unless ($profile) {
		return { ok => 0, error => 'Unknown system: ' . (defined $key ? $key : '') };
	}
	my $path = remap_path($key, $opts->{'dir'});
	my $dir = $path;
	$dir =~ s{/[^/]+$}{};
	unless (-d $dir) {
		eval { require File::Path; File::Path::make_path($dir); 1 }
			or return { ok => 0, error => "Could not create $dir" };
	}
	my $text = remap_text($key, $mapping);
	my $temp = $dir . '/.' . $profile->{'core'} . '.rmp.' . $$ . '.' . int(rand(1_000_000)) . '.tmp';
	my $fh;
	unless (open($fh, '>', $temp)) {
		return { ok => 0, error => "Could not write $temp: $!" };
	}
	unless (print {$fh} $text) {
		my $error = "$!";
		close $fh;
		unlink $temp;
		return { ok => 0, error => "Could not write $temp: $error" };
	}
	unless (close $fh) {
		my $error = "$!";
		unlink $temp;
		return { ok => 0, error => "Could not close $temp: $error" };
	}
	if (ref $opts->{'before_rename'} eq 'CODE') {
		eval { $opts->{'before_rename'}->($temp, $path); 1 };
	}
	unless (rename($temp, $path)) {
		my $error = "$!";
		unlink $temp;
		return { ok => 0, error => "Could not replace $path: $error" };
	}
	my @lines = remap_lines($key, $mapping);
	return { ok => 1, path => $path, lines => scalar @lines, text => $text };
}

1;
