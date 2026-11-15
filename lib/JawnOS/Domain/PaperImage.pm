package subs;

# PaperImage: the JPEG renditions of a picture that a printed paper can embed.
# A source image may be a PNG, WebP, HEIC or a sealed photo; a PDF can carry a
# JPEG without decoding it, so each picture gets a colour JPEG and a grayscale
# one, cached beside the house's scans and keyed by the source path. The cache is
# made when a paper first needs it, reused on every later paper, and removed when
# the source is deleted or the app's main_image is changed.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.

use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Digest::SHA qw(sha1_hex);
use File::Path ();
use File::Spec ();
use File::Slurp qw(write_file);
use JSON::PP ();
use MIME::Base64 ();

our $paper_image_max = 900;

# The Store's own setting: none, line, single or both. An unset or unknown value
# is none, so a house that never chose the feature keeps the text-only sheet.
sub paper_image_mode {
	my $v = &setting_grabber({ app => 'me', setting => 'invoice_images' });
	return 'none' unless defined $v && length $v;
	return $v if $v =~ /\A(?:line|single|both)\z/;
	return 'none';
}

# Where the renditions live. A machine with no scan location keeps them beside
# the home folder's own scan cache; a machine that cannot make the folder answers
# undef and the caller keeps the paper text-only.
sub paper_image_dir {
	my $base = &home(&setting_grabber({ app => 'misc', setting => 'scan_location' }));
	return undef unless defined $base && length $base;
	my $dir = $base . '/.paper-images';
	unless (-d $dir) {
		eval { File::Path::make_path($dir) };
	}
	return -d $dir ? $dir : undef;
}

sub paper_image_key {
	my ($source) = @_;
	return undef unless defined $source && length $source;
	return sha1_hex(File::Spec->rel2abs($source));
}

sub paper_image_paths {
	my ($source) = @_;
	my $dir = &paper_image_dir();
	return undef unless defined $dir;
	my $key = &paper_image_key($source);
	return undef unless defined $key;
	return {
		colour => $dir . '/' . $key . '.jpg',
		gray   => $dir . '/' . $key . '-gray.jpg',
	};
}

# The local picture an app's main_image names. A row written on another machine
# maps through this device's photo folder; a snapshot is written out as its own
# small source file. A sealed photo is served by its cached thumb when there is
# one, because magick cannot read the envelope.
sub paper_image_source {
	my ($value, $app) = @_;
	return undef unless defined $value && length $value;
	if ($value =~ /\Adata:image\/[a-z0-9.+-]+;base64,(.*)\z/is) {
		my $bytes = MIME::Base64::decode_base64($1);
		my $dir = &paper_image_dir();
		return undef unless defined $dir && defined $bytes && length $bytes;
		my $src = $dir . '/' . sha1_hex($bytes) . '.src';
		write_file($src, $bytes) unless -e $src;
		return -e $src ? $src : undef;
	}
	my $file = -e $value ? $value : '';
	if (!length $file) {
		my ($destination, $asset) = &file_device_renamer({ file => $value, app => $app, type => 'image' });
		my $local = (defined $destination && defined $asset) ? $destination . $asset : '';
		$file = $local if length $local && -e $local;
	}
	return undef unless length $file && -e $file;
	return undef unless &main_image_real_file($file);
	return &paper_image_thumb($file, $app) if &_paper_image_sealed($file);
	return $file;
}

# The image an invoice line's model row names. The model table carries the app;
# that app's main_image is the picture the person picked.
sub paper_image_for_model {
	my ($uuid) = @_;
	return undef unless defined $uuid && length $uuid;
	my $row = eval { &db_select('model', ['app', 'uuid'], { uuid => $uuid })->hash };
	return undef unless ref $row eq 'HASH' && ($row->{'app'} || '') =~ /\S/;
	my $value = &setting_grabber({ app => $row->{'app'}, setting => 'main_image' });
	my $source = &paper_image_source($value, $row->{'app'});
	unless (defined $source && length $source) {
		eval { &log_writer('paper image: no local picture for ' . $row->{'app'} . ' main_image'); 1 }
			if defined &log_writer;
		return undef;
	}
	return {
		path  => $source,
		app   => $row->{'app'},
		stamp => &paper_image_stamp($source, $row->{'app'}),
	};
}

# A cache is only fresh while the source and its file row are unchanged. The
# filesystem mtime/size catch an edit in place; the file row's own
# server_time/timestamp catches a sync or a re-filing of the picture. The stamp
# is read on every paper, so no write path can forget to refresh it.
sub paper_image_stamp {
	my ($source, $app) = @_;
	return undef unless defined $source && length $source;
	my @st = stat($source);
	return undef unless @st;
	my $stamp = $st[9] . ':' . $st[7];
	return $stamp unless defined $app && length $app;
	my $rows = eval { &db_select('appointments', ['file', 'server_time', 'timestamp'], { app => $app })->hashes } || [];
	my $json = JSON::PP->new;
	foreach my $row (@{$rows}) {
		next unless defined $row->{'file'} && length $row->{'file'};
		my $files = eval { $json->decode($row->{'file'}) };
		next unless ref $files eq 'ARRAY';
		foreach my $entry (@{$files}) {
			next unless ref $entry eq 'HASH';
			next unless grep { defined $entry->{$_} && $entry->{$_} eq $source } qw(f thumb preview);
			my $row_stamp = $entry->{'server_time'} // $entry->{'timestamp'}
				// $row->{'server_time'} // $row->{'timestamp'} // '';
			return $stamp . ':' . $row_stamp;
		}
	}
	return $stamp;
}

# Make (or reuse) the two JPEGs. Answers the paths, or undef when the source is
# not a picture this machine can read. A machine with neither the image bridge
# nor magick keeps no rendition; the paper then omits the picture.
sub paper_image_cache {
	my ($source, $opts) = @_;
	$opts ||= {};
	return undef unless defined $source && length $source && -e $source;
	my $paths = &paper_image_paths($source);
	return undef unless $paths;
	my $stamp = exists $opts->{'stamp'} ? $opts->{'stamp'}
		: &paper_image_stamp($source, $opts->{'app'});
	my $stamp_file = $paths->{'colour'} . '.stamp';
	my $cached_stamp = '';
	if (-e $stamp_file) {
		if (open my $sf, '<', $stamp_file) {
			local $/;
			$cached_stamp = <$sf> // '';
			close $sf;
			$cached_stamp =~ s/\s+\z//;
		}
	}
	my $have_colour = &_paper_image_jpeg($paths->{'colour'}) ? 1 : 0;
	my $have_gray = &_paper_image_jpeg($paths->{'gray'}) ? 1 : 0;
	my $fresh = $have_colour && $have_gray && defined $stamp && $cached_stamp eq $stamp;
	return $paths if $fresh && !$opts->{'force'};
	my $max = $opts->{'max'} || $paper_image_max;
	&_paper_image_convert($source, $paths->{'colour'}, $max, 0) unless $have_colour && $fresh;
	&_paper_image_convert($source, $paths->{'gray'}, $max, 1) unless $have_gray && $fresh;
	unlink $paths->{'gray'} unless &_paper_image_jpeg($paths->{'gray'});
	unless (&_paper_image_jpeg($paths->{'colour'})) {
		eval { &log_writer('paper image: no JPEG could be made from ' . $source); 1 }
			if defined &log_writer;
		return undef;
	}
	write_file($stamp_file, $stamp) if defined $stamp;
	return $paths;
}

# Remove both renditions. Called when a main_image changes and when the source
# file is deleted; a missing path is simply nothing to do.
sub paper_image_forget {
	my ($source) = @_;
	my $paths = &paper_image_paths($source);
	return 0 unless $paths;
	my $removed = 0;
	foreach my $path ($paths->{'colour'}, $paths->{'gray'}) {
		next unless defined $path && -e $path;
		my $ok = eval { &secure_unlink($path); 1 };
		unlink $path unless $ok;
		$removed++ unless -e $path;
	}
	my $stamp_file = $paths->{'colour'} . '.stamp';
	if (-e $stamp_file) {
		my $ok = eval { &secure_unlink($stamp_file); 1 };
		unlink $stamp_file unless $ok;
	}
	# A snapshot source (a data URI written out for magick) is ours too; do not
	# leave it behind when the picture that named it goes away.
	if (defined $source && $source =~ m{/\.paper-images/[0-9a-f]+\.src\z} && -e $source) {
		my $ok = eval { &secure_unlink($source); 1 };
		unlink $source unless $ok;
		$removed++ unless -e $source;
	}
	return $removed;
}

# ---- the conversion --------------------------------------------------------

sub _paper_image_jpeg {
	my ($path) = @_;
	return 0 unless defined $path && length $path && -s $path;
	open my $fh, '<', $path or return 0;
	binmode $fh;
	my $head = '';
	read($fh, $head, 2);
	close $fh;
	return $head eq "\xFF\xD8" ? 1 : 0;
}

sub _paper_image_sealed {
	my ($path) = @_;
	return 0 unless defined $path && -e $path && (-s $path) > 16;
	open my $fh, '<', $path or return 0;
	binmode $fh;
	my $head = '';
	read($fh, $head, 8);
	close $fh;
	return $head eq 'Salted__' ? 1 : 0;
}

sub _paper_image_thumb {
	my ($file, $app) = @_;
	return undef unless defined $app && length $app;
	my $rows = eval { &db_select('appointments', ['file'], { app => $app })->hashes } || [];
	my $json = JSON::PP->new;
	foreach my $row (@{$rows}) {
		next unless defined $row->{'file'} && length $row->{'file'};
		my $files = eval { $json->decode($row->{'file'}) };
		next unless ref $files eq 'ARRAY';
		foreach my $entry (@{$files}) {
			next unless ref $entry eq 'HASH';
			next unless (($entry->{'f'} || '') eq $file);
			for my $key (qw(thumb preview)) {
				my $path = $entry->{$key};
				next unless defined $path && length $path && -e $path;
				next if &_paper_image_sealed($path);
				return $path;
			}
		}
	}
	return undef;
}

sub _paper_image_convert {
	my ($source, $out, $max, $gray) = @_;
	return 0 unless defined $out && length $out;
	my $bridge_in = $source;
	my $edit_tmp;
	if ($gray) {
		$edit_tmp = $out . '.edit';
		my $edited = eval {
			&image_bridge_edit($source, [ { duty => 'modulate', value => '100,0' } ], $edit_tmp);
		};
		if (ref $edited eq 'HASH' && defined $edited->{'path'} && -s $edited->{'path'}) {
			$bridge_in = $edited->{'path'};
		}
	}
	eval {
		&image_bridge_convert($bridge_in, $out,
			format => 'jpeg', quality => 82, max_width => $max, max_height => $max);
	};
	# A bridge that answered in another format is a miss, not a cache hit.
	unlink $out if -s $out && !&_paper_image_jpeg($out);
	unless (-s $out) {
		my @cmd = ('magick', $source, '-auto-orient', '-resize', $max . 'x' . $max . '>');
		push @cmd, ('-colorspace', 'Gray') if $gray;
		push @cmd, ('-quality', '82', $out);
		eval { system(@cmd) };
	}
	unlink $edit_tmp if defined $edit_tmp && -e $edit_tmp;
	unlink $out unless -s $out;
	return (-s $out) ? 1 : 0;
}

1;
