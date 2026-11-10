package subs;

# RetroArch is the emulator frontend the handheld's game shelf runs. Its settings
# live in an INI-style file (`key = "value"`) under the person's config folder,
# and each core keeps its own option file beside it. This module is the only
# writer: it reads the current file, changes named keys, and writes the whole
# file back through a temporary path so a half-written config can never be
# loaded by a game. The original is kept once as `<file>.jawnos-bak`.
#
# Only the keys in @TOP_SETTINGS and %CORE_SETTINGS are writable. The page that
# draws the controls and this module share those two tables, so a key cannot be
# invented by a request. A value is written as a quoted string, which is the
# shape RetroArch itself saves.
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);

our @TOP_SETTINGS = (
	{ key => 'audio_out_rate', label => 'Audio rate', type => 'select', options => [qw(48000 44100)] },
	{ key => 'audio_latency', label => 'Audio latency', type => 'number', min => 16, max => 256, step => 8 },
	{ key => 'audio_resampler', label => 'Resampler', type => 'select', options => [qw(sinc cc nearest)] },
	{ key => 'audio_rate_control', label => 'Rate control', type => 'bool' },
	{ key => 'audio_sync', label => 'Audio sync', type => 'bool' },
	{ key => 'video_driver', label => 'Video driver', type => 'select', options => [qw(gl glcore vulkan)] },
	{ key => 'video_vsync', label => 'Vertical sync', type => 'bool' },
	{ key => 'video_threaded', label => 'Threaded video', type => 'bool' },
	{ key => 'video_frame_delay', label => 'Frame delay', type => 'number', min => 0, max => 15, step => 1 },
	{ key => 'video_hard_sync', label => 'Hard sync', type => 'bool' },
	{ key => 'fastforward_ratio', label => 'Fast-forward rate', type => 'number', min => 0, max => 10, step => 0.1 },
	{ key => 'threaded_data_runloop_enable', label => 'Threaded runloop', type => 'bool' },
);

# The two cores the handheld plays PlayStation and Nintendo 64 through. The
# names are the folders RetroArch uses in $HOME/.config/retroarch/config.
our %CORE_SETTINGS = (
	'pcsx_rearmed' => {
		dir => 'PCSX-ReARMed',
		label => 'PlayStation',
		settings => [
			{ key => 'pcsx_rearmed_frameskip', label => 'Frame skip', type => 'select', options => [qw(disabled auto fixed)] },
			{ key => 'pcsx_rearmed_gpu_thread_rendering', label => 'Threaded GPU', type => 'select', options => [qw(disabled enabled)] },
			{ key => 'pcsx_rearmed_spu_interpolation', label => 'SPU interpolation', type => 'select', options => [qw(simple gaussian cubic)] },
			{ key => 'pcsx_rearmed_psx_clock', label => 'PSX clock', type => 'select', options => [qw(auto 55 60)] },
			{ key => 'pcsx_rearmed_region', label => 'Region', type => 'select', options => [qw(auto NTSC PAL)] },
		],
	},
	'mupen64plus_next' => {
		dir => 'Mupen64Plus-Next',
		label => 'Nintendo 64',
		settings => [
			{ key => 'mupen64plus-rdp-plugin', label => 'RDP plugin', type => 'select', options => [qw(gliden64 parallel angrylion)] },
			{ key => 'mupen64plus-ThreadedRenderer', label => 'Threaded renderer', type => 'bool', bool_true => 'True', bool_false => 'False' },
			{ key => 'mupen64plus-EnableFBEmulation', label => 'Frame buffer emulation', type => 'bool', bool_true => 'True', bool_false => 'False' },
			{ key => 'mupen64plus-FrameDuping', label => 'Frame duping', type => 'bool', bool_true => 'True', bool_false => 'False' },
		],
	},
);

our %PRESETS = (
	audio_compatible => {
		label => 'Audio compatibility',
		note => 'Larger buffer and the cheap resampler: the fix for a pitched squeal on the handheld speaker.',
		top => {
			audio_out_rate => '48000',
			audio_latency => '128',
			audio_resampler => 'cc',
			audio_rate_control => 'true',
			audio_sync => 'true',
		},
		core => {
			pcsx_rearmed => { pcsx_rearmed_spu_interpolation => 'simple' },
		},
	},
	smoother => {
		label => 'Smoother emulation',
		note => 'Threaded video and renderers, no frame delay. Use when a 3D title runs below its frame rate.',
		top => {
			video_driver => 'gl',
			video_vsync => 'true',
			video_threaded => 'true',
			video_frame_delay => '0',
			threaded_data_runloop_enable => 'true',
		},
		core => {
			pcsx_rearmed => { pcsx_rearmed_gpu_thread_rendering => 'enabled' },
			mupen64plus_next => { 'mupen64plus-ThreadedRenderer' => 'True' },
		},
	},
);

sub retroarch_config_file {
	my $override = $ENV{'JAWNOS_RETROARCH_CONFIG'};
	return $override if defined $override && length $override;
	my $home = $ENV{'HOME'};
	return '' unless defined $home && length $home;
	return "$home/.config/retroarch/retroarch.cfg";
}

sub retroarch_core_file {
	my ($core) = @_;
	my $entry = $CORE_SETTINGS{$core};
	return undef unless $entry;
	my $config = &retroarch_config_file();
	return undef unless length $config;
	my $dir = dirname($config);
	my $name = $entry->{'dir'};
	return "$dir/config/$name/$name.opt";
}

# Read one INI file into a hash. Comments and blank lines are ignored here; the
# writer keeps them in the original order because it edits the line list.
sub retroarch_config_read {
	my ($file) = @_;
	$file = &retroarch_config_file() unless defined $file && length $file;
	my @lines = ();
	if (defined $file && length $file && -f $file) {
		open my $fh, '<:encoding(UTF-8)', $file or return ({}, []);
		@lines = <$fh>;
		close $fh;
	}
	my %value;
	for my $line (@lines) {
		next if $line =~ /^\s*(?:#|$)/;
		if ($line =~ /^\s*([A-Za-z0-9_]+)\s*=\s*"?([^"\r\n]*)"?\s*$/) {
			$value{$1} = $2;
		}
	}
	return (\%value, \@lines);
}

# Write one key, keeping every other line (including comments) where it was.
# The file is replaced through a temporary in the same directory, so a reader
# sees either the old file or the new one.
sub retroarch_config_write {
	my ($file, $key, $value) = @_;
	return { ok => 0, error => 'no config file' } unless defined $file && length $file;
	return { ok => 0, error => 'bad key' } unless defined $key && $key =~ /^[A-Za-z0-9_]+$/;
	$value = '' unless defined $value;
	$value = '' if $value eq 'undef';
	$value =~ s/[\r\n"]//g;
	my ($current, $lines) = &retroarch_config_read($file);
	my $found = 0;
	for my $line (@{ $lines }) {
		if ($line =~ /^\s*\Q$key\E\s*=/) {
			$line = "$key = \"$value\"\n";
			$found = 1;
			last;
		}
	}
	push @{ $lines }, "$key = \"$value\"\n" unless $found;
	my $dir = dirname($file);
	make_path($dir) unless -d $dir;
	my $tmp = "$file.tmp.$$";
	open my $out, '>:encoding(UTF-8)', $tmp
		or return { ok => 0, error => "cannot write $tmp" };
	print $out @{ $lines };
	close $out or return { ok => 0, error => "cannot close $tmp" };
	my $backup = "$file.jawnos-bak";
	copy($file, $backup) if -f $file && !-f $backup;
	rename $tmp, $file or do {
		unlink $tmp;
		return { ok => 0, error => "cannot replace $file" };
	};
	return { ok => 1, key => $key, value => $value, file => $file };
}

# Every knob the page may draw. The tables above are copied into a plain array
# so a template does not have to know the package variables.
sub retroarch_settings {
	my $file = &retroarch_config_file();
	my ($values) = &retroarch_config_read($file);
	my @cores;
	for my $id (sort keys %CORE_SETTINGS) {
		my $entry = $CORE_SETTINGS{$id};
		my $opt = &retroarch_core_file($id);
		my ($current) = &retroarch_config_read($opt);
		push @cores, {
			id => $id,
			label => $entry->{'label'},
			file => $opt,
			settings => [ map { { %{$_} } } @{ $entry->{'settings'} } ],
			values => $current,
		};
	}
	my @presets = map {
		{ id => $_, label => $PRESETS{$_}{'label'}, note => $PRESETS{$_}{'note'} }
	} sort keys %PRESETS;
	return {
		ok => 1,
		path => $file,
		exists => (defined $file && length $file && -f $file) ? 1 : 0,
		values => $values,
		settings => [ map { { %{$_} } } @TOP_SETTINGS ],
		cores => \@cores,
		presets => \@presets,
	};
}

sub retroarch_cores {
	my $settings = &retroarch_settings();
	return $settings->{'cores'};
}

# Write one setting. `core` selects a per-core option; without it the key must
# be one of the top-level settings. A key that is not in the tables is refused,
# so a crafted request cannot append arbitrary lines to the file.
sub retroarch_set {
	my ($key, $value, $core) = @_;
	if (defined $core && length $core) {
		my $entry = $CORE_SETTINGS{$core};
		return { ok => 0, error => 'unknown core' } unless $entry;
		my ($known) = grep { $_->{'key'} eq ($key // '') } @{ $entry->{'settings'} };
		return { ok => 0, error => 'unknown setting' } unless $known;
		my $file = &retroarch_core_file($core);
		return { ok => 0, error => 'no core option file' } unless defined $file;
		my $answer = &retroarch_config_write($file, $key, $value);
		return { %{$answer}, core => $core };
	}
	my ($known) = grep { $_->{'key'} eq ($key // '') } @TOP_SETTINGS;
	return { ok => 0, error => 'unknown setting' } unless $known;
	my $answer = &retroarch_config_write(&retroarch_config_file(), $key, $value);
	return $answer;
}

# Apply a named group of values. A preset is all-or-nothing for its own keys,
# but a key that cannot be written is reported without hiding the others.
sub retroarch_preset {
	my ($name) = @_;
	my $preset = $PRESETS{$name // ''};
	return { ok => 0, error => 'unknown preset' } unless $preset;
	my @failed;
	my $file = &retroarch_config_file();
	for my $key (sort keys %{ $preset->{'top'} }) {
		my $answer = &retroarch_config_write($file, $key, $preset->{'top'}{$key});
		push @failed, $key unless $answer->{'ok'};
	}
	for my $core (sort keys %{ $preset->{'core'} || {} }) {
		my $opt = &retroarch_core_file($core);
		next unless defined $opt;
		for my $key (sort keys %{ $preset->{'core'}{$core} }) {
			my $answer = &retroarch_config_write($opt, $key, $preset->{'core'}{$core}{$key});
			push @failed, "$core/$key" unless $answer->{'ok'};
		}
	}
	return @failed
		? { ok => 0, error => 'could not write: ' . join(', ', @failed), preset => $name }
		: { ok => 1, preset => $name };
}

1;
