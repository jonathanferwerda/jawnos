package subs;

# Contrast: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

# The named colour schemes the configure panel offers. One table, shared by the
# Misc panel (which paints its swatches from it) and the appointment theme
# dropdown (which stores a scheme name, not a colour), so the two can never
# drift apart. Each palette is a ramp the misc surfaces cycle through, in
# @gb::misc_settings order; the manager surface is therefore a fixed index.
our @colour_scheme_order;
our %colour_schemes;
our $config;
our $device;
our $gb;
# The colours a text control wears to sit beside the icon set's tiles: every
# generated tile is filled from hsl() values (the loud sets build their
# gradients from the same ones, so the first hsl() in the file is still the
# tile's colour) and the lightness says whether dark or light ink reads on it.
# The tile is named for the state the control is about - the page button wears
# the "now" tile at home and the back/forward tiles once it has walked. Memoised
# per set and tile: the files only change when build.js runs, while the manager
# re-renders constantly.
our %icon_plate_memo;
# The currently selected pseudonym icon set ('' for the modern default). Memoised
# per process with a short TTL: icon_for() runs once per icon on every render and
# each miss costs a config read (a DB query plus Sereal decode).
our $icon_set_memo;
our $icon_set_memo_time;
# cursor_set() is asked once per render and once per push, like the icon set.
our $cursor_set_memo;
our $cursor_set_memo_time;
our %m;
our %theme_aliases;
our %theme_presets;
our $theme_registry_memo;
our $theme_registry_time;
our $theme_state_memo;
our $theme_state_time;

# Pick black or white ink to sit on top of an arbitrary background colour, so
# appointment/name labels stay readable whatever colour the theme gives them.
# The inks are weighed the WCAG way - each channel linearised and weighted
# before the sum - because that is how the eye reads them: the two tie at a
# luminance of about 0.179, not half way, so a hot pink like #ea43b8 takes
# black where a flat average of the channels inked it white.
sub contrast_ink {
	my ($bg) = @_;
	return '#000000' unless defined $bg && $bg =~ /^\#?([0-9a-fA-F]{6})$/;
	my @channel = map { hex } ($1 =~ /(..)(..)(..)/);
	my @weight = ( 0.2126, 0.7152, 0.0722 );
	my $lum = 0;
	foreach my $i ( 0 .. 2 ) {
		my $c = $channel[$i] / 255;
		$c = $c <= 0.04045 ? $c / 12.92 : ((($c + 0.055) / 1.055) ** 2.4);
		$lum += $c * $weight[$i];
	}
	return $lum < 0.179 ? '#ffffff' : '#000000';
}

# The mark a budget light wears, as inner SVG for a 24x24 viewBox. The four
# built-in budget modes each get something that reads at chip size - a repeat
# for a count of times, a clock for a duration, a price tag for a money total,
# a hash for a quantity. A user's special budget has no mark and falls back to
# its initial. Paths only: the caller owns the <svg> element and its fill.
sub budget_icon {
	my ($circumstance) = @_;
	return '' unless defined $circumstance;
	my %glyph = (
		occurences => '<path d="M7 7h10v3l4-4-4-4v3H5v6h2V7zm10 10H7v-3l-4 4 4 4v-3h12v-6h-2v4z"/>',
		duration   => '<path d="M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z"/>',
		total      => '<path d="M21.41 11.58l-9-9C12.05 2.22 11.55 2 11 2H4c-1.1 0-2 .9-2 2v7c0 .55.22 1.05.59 1.42l9 9c.36.36.86.58 1.41.58s1.05-.22 1.41-.59l7-7c.37-.36.59-.86.59-1.41s-.23-1.06-.59-1.42zM5.5 7C4.67 7 4 6.33 4 5.5S4.67 4 5.5 4 7 4.67 7 5.5 6.33 7 5.5 7z"/>',
		quantity   => '<path d="M15.5 3l-.86 5H10.4l.86-5H9.2l-.86 5H5v2.1h3.1l-.7 4H4v2.1h3.17L6.5 21h2.06l.86-5h4.24l-.86 5h2.06l.86-5H20v-2.1h-4.1l.7-4H20V7.9h-3.2l.86-5zM13.05 10.1l-.7 4H8.1l.7-4z"/>',
	);
	return $glyph{$circumstance} || '';
}

# Render the CSS custom properties for a theme, given its background colour.
# Light themes get a light grey, dark themes a dark grey; both keep a whisper of
# the theme's hue. Returned as a declaration string so a layout can fold it into
# an inline style attribute.
sub theme_panel_css {
	my ($bg, $accent) = @_;
	unless (defined $accent && length $accent) {
		my $bundle = &active_theme_bundle();
		$accent = $bundle->{'accent'} if defined $bundle->{'accent'} && length $bundle->{'accent'};
	}
	my ($r, $g, $b);
	if (defined $bg && $bg =~ /^\#?([0-9a-fA-F]{6})$/) {
		($r, $g, $b) = map { hex } ($1 =~ /(..)(..)(..)/);
	}
	unless (defined $r) {
		my @palette = &theme_palette();
		if (scalar @palette && $palette[0] =~ /^\#([0-9a-fA-F]{6})$/) {
			($r, $g, $b) = map { hex } ($1 =~ /(..)(..)(..)/);
		}
	}
	unless (defined $r) {
		return '--ink:#000000;--ink-muted:#333333;--panel:#ffffff;--panel-2:#f0f0f0;--window:#f0f0f0;--line:#c9c9c9;--accent:#3b7ddd;--accent-soft:#e6effb;--accent-ink:#ffffff;--accent-line:#2f6cc4;';
	}
	my $lum = (0.2126 * $r + 0.7152 * $g + 0.0722 * $b) / 255;
	my ($h, $s, $l) = &_rgb_to_hsl($r, $g, $b);
	my $tint = $s < 0.18 ? $s : 0.18;
	# The accent is the one loud colour the desk is allowed. A theme may name
	# one; otherwise it is the manager hue pulled to a readable saturation, so
	# every scheme gets a matching focus ring, active tile and link without a
	# second table to maintain. --accent-soft is the same hue as a quiet wash.
	my $accent_hex = '';
	my ($ah, $as, $al);
	if (defined $accent && $accent =~ /^\#?([0-9a-fA-F]{6})$/) {
		my $accent_rgb = lc $1;
		$accent_hex = '#' . $accent_rgb;
		($ah, $as, $al) = &_rgb_to_hsl(map { hex } ($accent_rgb =~ /(..)(..)(..)/));
	}
	else {
		$ah = $h;
		$as = $s < 0.35 ? 0.58 : ($s > 0.78 ? 0.78 : $s);
		$as = 0.55 if $s < 0.12;   # graphite still needs a visible focus ring
		$al = $lum < 0.5 ? 0.68 : 0.46;
		$accent_hex = &_hsl_to_hex($ah, $as, $al);
	}
	my $accent_soft = &_hsl_to_hex($ah, $as, $lum < 0.5 ? 0.24 : 0.94);
	my $accent_line = &_hsl_to_hex($ah, $as, $lum < 0.5 ? 0.55 : 0.38);
	my $accent_ink = &contrast_ink($accent_hex);
	my $accent_vars = "--accent:$accent_hex;--accent-soft:$accent_soft;--accent-line:$accent_line;--accent-ink:$accent_ink;";
	# the curated window surface for a named scheme, or a shade of its own for a
	# hand-picked manager colour (lighter than the desktop on a dark theme,
	# lighter than the panel on a light one)
	my $window = &colour_scheme_window_colour(&colour_scheme_for_manager_colour($bg));
	$window ||= &_hsl_to_hex($h, $tint, $lum < 0.5 ? 0.24 : 0.96);
	# --line is the chrome border colour, kept a shade off --panel so frames and
	# seams read as an edge rather than a bright white outline. --ink is the text;
	# it was #f2f2f2 (near white) which glares on a dark panel, and it used to be
	# the border colour too (borders with no colour inherit currentColor), which
	# is why every dark window wore a white outline.
	if ($lum < 0.5) {
		my $panel = &_hsl_to_hex($h, $tint, 0.16);
		my $panel2 = &_hsl_to_hex($h, $tint, 0.23);
		my $line = &_hsl_to_hex($h, $tint, 0.32);
		return "--ink:#e6e6e6;--ink-muted:#9a9a9a;--panel:$panel;--panel-2:$panel2;--window:$window;--line:$line;$accent_vars";
	}
	my $panel = &_hsl_to_hex($h, $tint, 0.88);
	my $panel2 = &_hsl_to_hex($h, $tint, 0.80);
	my $line = &_hsl_to_hex($h, $tint, 0.66);
	return "--ink:#111417;--ink-muted:#5b6169;--panel:$panel;--panel-2:$panel2;--window:$window;--line:$line;$accent_vars";
}

sub theme_canonical {
	my ($name) = @_;
	return '' unless defined $name && length $name;
	return $theme_aliases{$name} // $name;
}

sub theme_registry {
	my $now = &rightNow();
	return $theme_registry_memo if $theme_registry_memo && $now - $theme_registry_time < 1000;
	my %registry;
	foreach my $slug ( keys %theme_presets ) {
		# an alias row is a compatibility key, not a card: a renamed preset is
		# offered once, under its new slug
		next if $theme_presets{$slug}->{'alias_to'};
		$registry{$slug} = { %{ $theme_presets{$slug} }, slug => $slug, builtin => 1 };
	}
	my $rows = eval {
		&db_query("select subsetting, value from settings where app = 'misc' and setting = 'appearance_theme_custom' and subsetting is not null and value is not null and value != ''")->hashes;
	} || [];
	foreach my $row ( @{$rows} ) {
		my $slug = $row->{'subsetting'} // '';
		next unless $slug =~ /^[a-z0-9][a-z0-9_-]{0,39}$/;
		# a stale custom row under a pre-rename slug must not shadow the preset
		# that slug now resolves to
		next if $theme_aliases{$slug};
		my $data = eval { decode_json($row->{'value'}) };
		next unless ref $data eq 'HASH';
		$registry{$slug} = { %{$data}, slug => $slug, builtin => 0 };
	}
	$theme_registry_memo = \%registry;
	$theme_registry_time = $now;
	return $theme_registry_memo;
}

# A name an appointment may store: a saved/preset theme or a bare colour scheme
# (the older values still in the table). A pre-rename preset slug is resolved to
# the renamed bundle first, so an old row keeps dressing the desk.
sub theme_known {
	my ($name) = @_;
	return 0 unless defined $name && length $name;
	$name = &theme_canonical($name);
	return 1 if $colour_schemes{$name};
	my $registry = &theme_registry();
	return $registry->{$name} ? 1 : 0;
}

sub theme_safe_font {
	my ($font) = @_;
	return '' unless defined $font && length $font;
	foreach my $f ( @gb::theme_fonts ) {
		return $f->{'value'} if $f->{'value'} eq $font;
	}
	return '';
}

sub theme_safe_corner {
	my ($corner) = @_;
	return '' unless defined $corner && $corner =~ /^\s*(\d{1,2})\s*(?:px)?\s*$/;
	my $n = $1 + 0;
	return '' if $n > 28;
	return $n . 'px';
}

# A name -> the whole bundle. Unknown names resolve to an empty bundle, which
# means "the Misc settings are in charge". A bare colour-scheme name resolves
# to that scheme and nothing else, so rows written before themes existed keep
# their meaning.
sub theme_bundle {
	my ($name) = @_;
	return {} unless defined $name && length $name;
	# an old slug is the renamed bundle: the returned slug (and so the name the
	# gallery, the push and the appointment label show) is the current one
	$name = &theme_canonical($name);
	my $registry = &theme_registry();
	my $theme = $registry->{$name};
	$theme = { scheme => $name } if !$theme && $colour_schemes{$name};
	return {} unless $theme;
	my $scheme = $theme->{'scheme'} // '';
	$scheme = '' unless $colour_schemes{$scheme};
	my $background = $theme->{'background'} // '';
	$background = '' unless $background =~ /^\#?[0-9a-fA-F]{6}$/;
	$background = '#' . $background if $background =~ /^[0-9a-fA-F]{6}$/;
	my $bg = $scheme ? &colour_scheme_manager_colour($scheme) : $background;
	my $icon_set = $theme->{'icon_set'} // '';
	$icon_set = '' unless grep { $_ eq $icon_set } @gb::icon_sets;
	my $cursor_set = $theme->{'cursor_set'} // '';
	$cursor_set = '' unless grep { $_ eq $cursor_set } @gb::cursor_sets;
	my $texture = $theme->{'texture'} // '';
	$texture = '' unless grep { $_ eq $texture } @gb::textures;
	my $accent = $theme->{'accent'} // '';
	$accent = '' unless $accent =~ /^\#?[0-9a-fA-F]{6}$/;
	$accent = '#' . $accent if $accent =~ /^[0-9a-fA-F]{6}$/;
	# A theme that names no accent takes its scheme's own accent step, not a
	# colour derived from the manager surface: on a charcoal window the derived
	# hue is grey and the active tile loses the theme's colour entirely.
	if (!length $accent && $scheme && ref $colour_schemes{$scheme} eq 'ARRAY') {
		my $pal = $colour_schemes{$scheme};
		my $dark = 0;
		if (defined $bg && $bg =~ /^\#?([0-9a-fA-F]{6})$/) {
			my ($r, $g, $b) = map { hex } ($1 =~ /(..)(..)(..)/);
			$dark = ((0.2126 * $r + 0.7152 * $g + 0.0722 * $b) / 255) < 0.5 ? 1 : 0;
		}
		$accent = $pal->[ $dark ? 5 : 4 ] // $pal->[4] // '';
		$accent = '#' . $accent if $accent =~ /^[0-9a-fA-F]{6}$/;
	}
	return {
		slug       => $name,
		name       => $theme->{'name'} // $name,
		builtin    => $theme->{'builtin'} ? 1 : 0,
		scheme     => $scheme,
		background => $bg,
		icon_set   => $icon_set,
		cursor_set => $cursor_set,
		texture    => $texture,
		font       => &theme_safe_font($theme->{'font'}),
		corner     => &theme_safe_corner($theme->{'corner'}),
		accent     => $accent,
	};
}

# The theme in charge: a running start/record appointment first, then the
# Misc Appearance choice. Blank means the Misc surfaces are in charge.
sub active_theme_name {
	my $theme = &running_appointment_theme();
	return &theme_canonical($theme) if defined $theme && length $theme;
	my $picked = &misc_setting('appearance_theme');
	return &theme_canonical($picked) if defined $picked && length $picked && &theme_known($picked);
	return '';
}

sub active_theme_bundle {
	# The running appointment's theme sits over the Misc theme: a field the
	# running theme does not name (a legacy colour-scheme row has no icons or
	# material) is taken from the Misc theme, so a start appointment never
	# undresses the desk by accident.
	my $running = &running_appointment_theme();
	my $picked = &misc_setting('appearance_theme');
	$picked = '' unless defined $picked && length $picked && &theme_known($picked);
	my $system = length $picked ? &theme_bundle($picked) : {};
	if (defined $running && length $running) {
		my $over = &theme_bundle($running);
		my %merged = %{$system};
		foreach my $key ( qw/scheme background icon_set cursor_set texture font corner accent name/ ) {
			$merged{$key} = $over->{$key} if defined $over->{$key} && length $over->{$key};
		}
		$merged{'slug'} = &theme_canonical($running);
		$merged{'appointment'} = 1;
		return \%merged;
	}
	$system->{'appointment'} = 0 if ref $system eq 'HASH';
	return $system;
}

# A scheme's manager surface and its window surface. The palette is applied
# across @gb::misc_settings by index, so the manager is the same colour the Misc
# panel writes into manager_background_colour when the scheme is picked; the
# window is the next step of the same ramp, which keeps every theme's windows
# distinct from its desktop while staying in its motif.
sub colour_scheme_window_colour {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	my $palette = $colour_schemes{$name};
	return undef unless ref $palette eq 'ARRAY' && scalar @{$palette} > 3;
	return $palette->[3];
}

# The scheme a manager colour came from, so a server-rendered desktop can pick
# its curated window colour. A hand-picked colour finds no scheme and gets a
# derived shade instead (theme_panel_css).
sub colour_scheme_for_manager_colour {
	my ($bg) = @_;
	return '' unless defined $bg && length $bg;
	my $target = lc $bg;
	$target = '#' . $target unless $target =~ /^#/;
	foreach my $name ( @colour_scheme_order ) {
		my $manager = $colour_schemes{$name}->[2];
		return $name if defined $manager && lc($manager) eq $target;
	}
	return '';
}

sub colour_scheme_manager_colour {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	my $palette = $colour_schemes{$name};
	return undef unless ref $palette eq 'ARRAY' && scalar @{$palette};
	my $index = 0;
	my $found = 0;
	foreach my $key ( @gb::misc_settings ) {
		if ($key eq 'manager') { $found = 1; last; }
		$index++;
	}
	return undef unless $found;
	return $palette->[ $index % scalar @{$palette} ];
}

# The dark-theme counterpart of an appointment's colour. The named schemes ship
# a light and a dark cut with the same ramp, so a colour from a light scheme maps
# straight to the same step of its dark pair - the face the app would have been
# given had it been born on a dark desktop. A colour no scheme knows keeps its
# hue and its place on the lightness ramp, pulled into the dark desktop's range:
# the ramp's steps stay distinct instead of collapsing onto one tone.
sub dark_colour_for {
	my ($colour) = @_;
	return $colour unless defined $colour && $colour =~ /^\#?([0-9a-fA-F]{6})$/;
	my $hex = lc('#' . $1);
	foreach my $name ( @colour_scheme_order ) {
		next if $name =~ / Dark$/;
		my $palette = $colour_schemes{$name};
		next unless ref $palette eq 'ARRAY';
		my $index = 0;
		foreach my $step ( @{$palette} ) {
			if (lc($step) eq $hex) {
				my $dark = $colour_schemes{$name . ' Dark'};
				return $dark->[$index] if ref $dark eq 'ARRAY' && defined $dark->[$index];
				last;
			}
			$index++;
		}
	}
	# $hex still carries the leading '#'; strip it before reading the three
	# channels, or hex('#f') warns and the red channel becomes 0.
	my ($r, $g, $b) = map { hex } (substr($hex, 1) =~ /(..)(..)(..)/);
	my ($h, $s, $l) = &_rgb_to_hsl($r, $g, $b);
	$s = 0.62 if $s > 0.62;
	my $target = 0.18 + (0.34 * $l);
	return lc &_hsl_to_hex($h, $s, $target);
}

# The light-face counterpart of a colour an appointment stored while a dark cut
# was in charge. A colour is the light face and dark_colour the dark one, but an
# app born on a dark desktop took its colour from that cut's ramp, so switching
# to a light theme left its plates near-black. A step only a dark pair knows maps
# back to the same step of its light pair; a colour any light scheme already
# names is left alone (some steps, like Graphite's last, are shared by both
# cuts), and a hand-picked colour no scheme knows is untouched.
sub light_colour_for {
	my ($colour) = @_;
	return $colour unless defined $colour && $colour =~ /^\#?([0-9a-fA-F]{6})$/;
	my $hex = lc('#' . $1);
	foreach my $name ( @colour_scheme_order ) {
		next if $name =~ / Dark$/;
		my $palette = $colour_schemes{$name};
		next unless ref $palette eq 'ARRAY';
		foreach my $step ( @{$palette} ) {
			return $colour if lc($step) eq $hex;
		}
	}
	foreach my $name ( @colour_scheme_order ) {
		next unless $name =~ / Dark$/;
		my $palette = $colour_schemes{$name};
		next unless ref $palette eq 'ARRAY';
		my $index = 0;
		foreach my $step ( @{$palette} ) {
			if (lc($step) eq $hex) {
				(my $light_name = $name) =~ s/ Dark$//;
				my $light = $colour_schemes{$light_name};
				return $light->[$index] if ref $light eq 'ARRAY' && defined $light->[$index];
				last;
			}
			$index++;
		}
	}
	return $colour;
}

# The two faces of an appointment's colour: the light one a light desk paints and
# the dark one a dark desk paints. A stored colour that is really a dark cut's
# step is the dark face, and its light pair is the light face; anything else gets
# its dark face derived (or keeps the one the row already names).
sub appointment_colours {
	my ($colour, $dark) = @_;
	return ($colour, $dark) unless defined $colour && length $colour;
	my $light = &light_colour_for($colour);
	if (defined $light && length $light && lc($light) ne lc($colour)) {
		return ($light, $colour);
	}
	$dark = &dark_colour_for($colour) unless defined $dark && length $dark;
	return ($colour, $dark);
}

# Every app's chosen theme in one read, for the appointment list (one query
# rather than one per app block). A house-wide row wins, then this device's,
# then the person's.
sub app_theme_map {
	my %rank = ( 'all' => 3, &device_setter() => 2, &signatorial_designer() => 1 );
	my %map;
	my %best;
	my $rows = eval { &db_query("select app, device, value from settings where setting = ? and value is not null and value != ''", 'theme')->hashes } || [];
	foreach my $row ( @{$rows} ) {
		my $app = $row->{'app'};
		my $rank = $rank{ $row->{'device'} // '' } || 0;
		next unless $app && $rank;
		next if defined $best{$app} && $best{$app} >= $rank;
		$best{$app} = $rank;
		$map{$app} = $row->{'value'};
	}
	return \%map;
}

# The theme an actively running start/record appointment asks for: the most
# recently started one that has a theme. One join rather than a settings read
# per open row - a stale run must not cost the desktop a query per appointment.
# Blank when none is running.
sub running_appointment_theme {
	my $now = &rightNow();
	my $device = &device_setter();
	my $signatorial = &signatorial_designer();
	my $rows = eval {
		&db_query(
			"select a.app as app, a.timestamp as timestamp, s.value as theme, s.device as theme_device "
			. "from appointments a join settings s on s.app = a.app and s.setting = ? "
			. "where (a.type = ? or a.type = ?) and a.stop_seen is null and a.timestamp is not null and a.timestamp <= ? "
			. "and s.value is not null and s.value != '' and s.device in (?, ?, ?) "
			. "order by a.timestamp desc, "
			. "(case s.device when 'all' then 3 when ? then 2 when ? then 1 else 0 end) desc "
			. "limit 200",
			'theme', 'start', 'record', $now, 'all', $device, $signatorial, $device, $signatorial
		)->hashes;
	} || [];
	foreach my $row ( @{$rows} ) {
		my $theme = $row->{'theme'};
		return $theme if defined $theme && length $theme && &theme_known($theme);
	}
	return '';
}

# The manager background the desktop should paint now, plus the appointment
# theme driving it (blank when the Misc system theme is in charge). Both come
# from theme_state(), so a render asks the running-appointment query once.
sub active_manager_background {
	my (undef, $theme, $bg) = &theme_state();
	return ($bg, $theme);
}

# Tell every open manager to re-paint its body for the current active theme.
# A theme is more than a colour: the message carries the whole bundle, so the
# icons, cursor, material, face and corner change with it and no reload is needed.
sub appointment_theme_push {
	# the running set may have just changed: a warm memo would send the room the
	# desk is leaving, so forget every theme cache before asking
	&icon_set_forget();
	my (undef, undef, $bg, $bundle, undef, $appointment) = &theme_state();
	return unless defined $bg && length $bg;
	# The effective values, not the bundle's defaults: an icon/texture/corner
	# override chosen on top of the theme is part of what the desk is wearing. The
	# signature lets the browser ignore a push that changes nothing - a start or
	# stop on the same theme must not reload every window.
	my $icon_set = &icon_set();
	my $cursor_set = &cursor_set();
	my $texture = &texture_name();
	my $font = $bundle->{'font'} || &misc_setting('title_font') || 'system-ui, sans-serif';
	# the corner the desk is wearing: the theme's own, or the Misc override on
	# top of it. Empty with no theme, so the browser falls back to the Misc
	# slider's --corner_radius there.
	my $corner = $bundle->{'slug'} ? &corner_radius() . 'px' : '';
	my $accent = $bundle->{'accent'} || '';
	my $signature = &theme_signature();
	my %send = (
		background => $bg,
		appointment => $appointment ? 1 : 0,
		icon_set => $icon_set,
		cursor_set => $cursor_set,
		texture => $texture,
		font => $font,
		corner => $corner,
		accent => $accent,
		signature => $signature,
	);
	# The launcher and the lock screen are native: they hold no manager session
	# and cannot be sent a console line, so the same paint is written where they
	# already read - the settings table. One house-wide row, and only when it
	# changes, so a stop/start on the same theme does not churn sync.
	&native_theme_record({ %send, theme => $bundle->{'slug'} // '' });
	&Websocket::send('server', { console => &Websocket::console_command('jawnosThemeBundleApply', \%send)});
}

# The native surfaces (the launcher and the lock screen) wear the desk's paint.
# They read the house database, not the WebSocket, so the effective bundle is
# recorded where they can see it: ~/.president/native_theme.json. A FILE, not a
# settings row, because a theme is this device's own (the phone and the laptop
# pick different ones) and a shared row would let the newest sync win on every
# machine. The launcher falls back to the Misc manager colour when the file has
# never been written.
sub native_theme_record {
	my ($send) = @_;
	my $file = &home('~/.president/native_theme.json');
	my $value = encode_json({
		background => $send->{'background'} // '',
		accent => $send->{'accent'} // '',
		appointment => $send->{'appointment'} ? 1 : 0,
		theme => $send->{'theme'} // '',
		signature => $send->{'signature'} // '',
	});
	my $current = '';
	eval {
		local $/;
		open(my $in, '<', $file) or die;
		$current = <$in>;
		close $in;
	};
	return if defined $current && $current eq $value;
	# Write beside and rename, so a launcher reading at the wrong moment never
	# sees half a file.
	my $tmp = $file . '.tmp';
	eval {
		open(my $fh, '>', $tmp) or die;
		print $fh $value;
		close $fh;
		rename $tmp, $file or die;
	};
}

# What the desk currently wears, as one comparable string: paint, effective
# glyphs, cursor, material, face and corner. The appointment flag is deliberately left
# out - it changes who owns the desk, not how it is painted - so a start/stop on
# the same theme pushes nothing and reloads no window.
sub theme_signature {
	my $bundle = &active_theme_bundle();
	my $bg = $bundle->{'background'} // '';
	my $font = $bundle->{'font'} || &misc_setting('title_font') || 'system-ui, sans-serif';
	my $corner = $bundle->{'slug'} ? &corner_radius() . 'px' : '';
	my $accent = $bundle->{'accent'} || '';
	return join '|', map { defined $_ ? $_ : '' } ( $bg, &icon_set(), &cursor_set(), &texture_name(), $font, $corner, $accent );
}

# The colours the current theme is built from: the distinct *_background_colour
# swatches for a device (falling back through the other devices if unset).
sub theme_palette {
	my $device = shift || &subs::device_setter();
	my $config = &subs::config_reader();
	my @devices = ( $device, @gb::device_types, &subs::signatorial_designer() );
	my %tried;
	foreach my $dt ( @devices ) {
		next if $tried{$dt}++;
		next unless $config->{$dt};
		my %seen;
		my @palette;
		foreach my $k ( @gb::misc_settings ) {
			my $c = $config->{$dt}->{$k}->{'background_colour'};
			next unless $c;
			$c = '#' . $c unless $c =~ /^#/;
			next unless $c =~ /^#[0-9a-fA-F]{6}$/;
			$c = lc $c;
			push @palette, $c unless $seen{$c}++;
		}
		return @palette if scalar @palette;
	}
	return ();
}

sub random_colour_grabber {
	my @palette = &theme_palette();
	if (scalar @palette > 0) {
		my $pick = $palette[ int(rand(scalar @palette)) ];
		$pick =~ s/^#//;
		return $pick;
	}

	my $col = [ 0, 0, 0 ];
	foreach my $co ( @{$col} ) {
		until ($co > 130) {
			$co = rand(255);
		}
	}
	return join "", map { sprintf "%02x", $col->[$_] } (0..2);
}

# Snap an app's colour into the theme. If the existing colour is already one of
# the theme's colours it is left alone; otherwise a stable theme colour is chosen
# for that app and saved. With no theme colours configured, the value is returned
# unchanged.
sub theme_colour_grabber {
	my $data = ( ref $_[0] eq 'HASH' ) ? $_[0] : { app => $_[0] };
	my $app = $data->{'app'};
	return $data->{'existing'} unless $app;
	my $device = $data->{'device'} || &subs::device_setter();

	my $existing = $data->{'existing'};
	unless (defined $existing) {
		my $q = &db_select('settings', ['value'], { app => $app, setting => 'colour', device => $device })->hashes;
		$q = &db_select('settings', ['value'], { app => $app, setting => 'colour' })->hashes unless scalar @{$q};
		$existing = $q->[-1]->{'value'} if scalar @{$q};
	}

	my @palette = &theme_palette($device);
	return $existing unless scalar @palette;

	my $normalized = defined $existing ? lc $existing : '';
	$normalized = '#' . $normalized if $normalized =~ /^[0-9a-f]{6}$/;
	if (grep { $_ eq $normalized } @palette) {
		return $existing;
	}

	my $sum = 1;
	$sum += ord for split //, $app;
	my $colour = $palette[ $sum % scalar @palette ];

	&setting_setter({ app => $app, setting => 'colour', value => $colour, device => $device, silent => 'yes' });
	return $colour;
}

# Wrapper used by the getters: skips the built-in apps and blank names.
sub theme_colour_for_app {
	my ($app, $existing, $device) = @_;
	return $existing unless $app;
	foreach my $p ( @gb::protected ) {
		return $existing if lc($p) eq lc($app);
	}
	return &theme_colour_grabber({ app => $app, existing => $existing, device => $device });
}

sub theme_state {
	my $now = &rightNow();
	return @{$theme_state_memo} if $theme_state_memo && $now - $theme_state_time < 1000;
	my $bundle = &active_theme_bundle();
	my $name = $bundle->{'slug'} // '';
	my $appointment = $bundle->{'appointment'} ? 1 : 0;
	my $bg = $bundle->{'background'} // '';
	unless (length $bg) {
		my $config = &config_reader();
		$bg = $config->{ &signatorial_designer() }->{'manager'}->{'background_colour'} // '';
	}
	my $dark = 0;
	if ($bg =~ /^\#?([0-9a-fA-F]{6})$/) {
		my ($r, $g, $b) = map { hex } ($1 =~ /(..)(..)(..)/);
		# keep in step with theme_panel_css(): the same 0.5 luminance line
		# decides whether the chrome is a light or a dark face
		$dark = ((0.2126 * $r + 0.7152 * $g + 0.0722 * $b) / 255) < 0.5 ? 1 : 0;
	}
	$theme_state_memo = [ $dark, ($appointment ? $name : ''), $bg, $bundle, $name, $appointment ];
	$theme_state_time = $now;
	return @{$theme_state_memo};
}

sub theme_is_dark {
	my ($dark) = &theme_state();
	return $dark;
}

# A misc surface's background for the theme that is in charge. A running
# appointment theme paints its own ramp across every surface - the same ramp the
# scheme picker would write - and the Misc theme keeps each surface's configured
# colour, darkened when the desktop is dark and that colour is a light face.
sub theme_surface_colour {
	my ($key, $device) = @_;
	return undef unless defined $key && length $key;
	my (undef, undef, undef, $bundle) = &theme_state();
	my $dark = &theme_is_dark();
	my $scheme = ref $bundle eq 'HASH' ? ($bundle->{'scheme'} // '') : '';
	if (length $scheme && $colour_schemes{$scheme}) {
		my $index = 0;
		foreach my $k ( @gb::misc_settings ) {
			last if $k eq $key;
			$index++;
		}
		my $ramp = $colour_schemes{$scheme};
		return $ramp->[ $index % scalar @{$ramp} ];
	}
	my $config = &config_reader();
	$device = &device_setter() unless defined $device && length $device;
	my $colour = $config->{$device}->{$key}->{'background_colour'};
	return $colour unless defined $colour && length $colour;
	return $colour unless $dark;
	return &dark_surface_colour($colour);
}

# Turn a light face into a dark one of the same hue. A colour already dark is
# left alone, so a dark scheme's curated ramp survives untouched.
sub dark_surface_colour {
	my ($colour) = @_;
	return $colour unless defined $colour && length $colour;
	my $hex = $colour;
	$hex =~ s/^\s+//;
	$hex =~ s/\s+$//;
	$hex =~ s/^\#//;
	return $colour unless $hex =~ /^[0-9a-fA-F]{6}$/;
	my ($r, $g, $b) = map { hex } ($hex =~ /(..)(..)(..)/);
	my ($h, $s, $l) = &_rgb_to_hsl($r, $g, $b);
	return $colour if $l < 0.5;
	my $tint = $s > 0.32 ? 0.32 : $s;
	return &_hsl_to_hex($h, $tint, 0.22);
}

sub icon_set {
	my $now = &rightNow();
	return $icon_set_memo if defined $icon_set_memo && $now - $icon_set_memo_time < 1000;
	my $config = &config_reader();
	my $set = '';
	# While a theme is in charge it names the glyphs; the Misc Icon Set is what a
	# desk with no theme wears. An explicit override (chosen from the Misc panel
	# while the theme is active) wins over the theme's own set, so a person can
	# keep Deepjawn's paint and still use another set of icons.
	my $bundle = &active_theme_bundle();
	if ($bundle->{'slug'}) {
		my $override = &misc_setting('icon_set_override');
		if (defined $override && length $override && grep { $_ eq $override } @gb::icon_sets) {
			$set = $override;
		}
		elsif (defined $bundle->{'icon_set'} && length $bundle->{'icon_set'}) {
			$set = $bundle->{'icon_set'};
		}
	}
	$set = $config->{'icon_set'} || '' unless length $set;
	# a dark desktop asks for the set's dark cut: the same glyphs on a plate
	# that does not glare. The light cut stays the fallback for a hand-drawn
	# set (which has no generated cut) and for any set without one.
	if ($set && $set ne 'handdrawn' && $set !~ /_dark$/ && &theme_is_dark()) {
		my $dark_set = $set . '_dark';
		$set = $dark_set if -d "public/icons/sets/$dark_set";
	}
	$icon_set_memo = $set;
	$icon_set_memo_time = $now;
	return $icon_set_memo;
}

# The cursor set the desk wears, resolved the way the icon set is: a theme may
# name one, an explicit choice from Misc while that theme is active overrides
# just the pointer (cursor_set_override), and a desk with no theme in charge
# wears the Misc choice. An empty value means the system cursors, which is what
# a theme that names none leaves alone.
sub cursor_set {
	my $now = &rightNow();
	return $cursor_set_memo if defined $cursor_set_memo && $now - $cursor_set_memo_time < 1000;
	my $set = '';
	my $bundle = &active_theme_bundle();
	if ($bundle->{'slug'}) {
		my $override = &misc_setting('cursor_set_override');
		if (defined $override && length $override && grep { $_ eq $override } @gb::cursor_sets) {
			$set = $override;
		}
		elsif (defined $bundle->{'cursor_set'} && length $bundle->{'cursor_set'}) {
			$set = $bundle->{'cursor_set'};
		}
	}
	unless (length $set) {
		my $misc = &misc_setting('cursor_set');
		$set = $misc if defined $misc && length $misc;
	}
	$set = '' unless grep { $_ eq $set } @gb::cursor_sets;
	$cursor_set_memo = $set;
	$cursor_set_memo_time = $now;
	return $cursor_set_memo;
}

# The CSS that maps each cursor set's roles onto the keywords the sheets ask
# for. Every set is written once, so a theme push only moves the body's
# data-cursor-set attribute; no stylesheet is rebuilt or re-injected. A role
# with no image is simply absent, and the var() fallback in the sheet leaves
# the system cursor in place.
sub cursor_css {
	my @rules;
	foreach my $set ( @gb::cursor_sets ) {
		next unless defined $set && $set =~ /^[a-z0-9][a-z0-9_-]*$/;
		my @vars;
		foreach my $role ( @gb::cursor_roles ) {
			my $png = "public/cursors/sets/$set/$role.png";
			next unless -e $png;
			my $hotspot = $gb::cursor_hotspots{$role} // '16 16';
			push @vars, "--jawnos-cursor-$role:url('/cursors/sets/$set/$role.png') $hotspot, $role";
		}
		next unless @vars;
		push @rules, 'body[data-cursor-set="' . $set . '"]{' . join(';', @vars) . ';cursor:var(--jawnos-cursor-default, auto)}';
	}
	return join "\n", @rules;
}

# Called when the icon set is changed, so the very next render already uses it
# instead of waiting out the memo above. The theme memo goes with it: a scheme
# change can flip which cut of the set is wanted.
sub icon_set_forget {
	$icon_set_memo = undef;
	$icon_set_memo_time = 0;
	$cursor_set_memo = undef;
	$cursor_set_memo_time = 0;
	$theme_state_memo = undef;
	$theme_state_time = 0;
	$theme_registry_memo = undef;
	$theme_registry_time = 0;
}

# When the hand-drawn set is active, swap a public icon path for its original
# hand-drawn PNG (kept in public/icons/original/) if one exists.
sub icon_original {
	my $path = shift;
	return $path unless defined $path && $path =~ m{^/};
	return $path unless &icon_set() eq 'handdrawn';
	my $candidate = "/icons/original" . $path;
	return -e "public" . $candidate ? $candidate : $path;
}

# The hand-drawn picture behind a public icon path, whatever icon set is
# selected - the gate's splash and the denial page wear it always. build.js
# renders generated tiles in at the old public paths, so the plain path no
# longer shows the hand.
sub icon_drawn {
	my $path = shift;
	return $path unless defined $path && $path =~ m{^/};
	my $candidate = "/icons/original" . $path;
	return -e "public" . $candidate ? $candidate : $path;
}

# Resolve a button icon through the selected set, falling back to the given path.
sub icon_path {
	my ($name, $fallback) = @_;
	my $set = &icon_set();
	if ($set eq 'handdrawn') {
		return &icon_original($fallback);
	}
	if ($set) {
		my $path = "/icons/sets/" . $set . "/" . $name . ".svg";
		return $path if -e "public" . $path;
	}
	return $fallback;
}

# Resolve an app icon given its normal public path: hand-drawn originals for the
# hand-drawn set, or the matching /icons/sets/<set>/<basename>.svg when present.
sub icon_for {
	my ($path, $set) = @_;
	return $path unless defined $path && $path =~ m{^/};
	$set = &icon_set() unless defined $set;
	return &icon_original($path) if $set eq 'handdrawn';
	return $path unless $set;
	my ($base) = $path =~ m{([^/]+)$};
	$base =~ s/\.[A-Za-z0-9]+$//;
	my $candidate = "/icons/sets/$set/$base.svg";
	return $candidate if -e "public" . $candidate;
	return $path;
}

sub icon_plate_colours {
	my $icon = shift || 'now';
	my $set = &icon_set() || '';
	my $memo_key = $set . '/' . $icon;
	return $icon_plate_memo{$memo_key} if exists $icon_plate_memo{$memo_key};
	my $colours = { plate => '', ink => '' };
	if ($set && $set ne 'handdrawn') {
		my $file = 'public/icons/sets/' . $set . '/' . $icon . '.svg';
		my $svg = -e $file ? read_file($file) : undef;
		if (defined $svg && $svg =~ /(hsl\(\s*\d+\s*,\s*\d+%\s*,\s*(\d+)%\s*\))/) {
			$colours = { plate => $1, ink => ($2 > 65 ? '#111111' : '#ffffff') };
		}
	}
	return $icon_plate_memo{$memo_key} = $colours;
}

1;
