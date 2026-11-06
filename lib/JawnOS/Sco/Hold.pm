package JawnOS::Sco::Hold;

# The music a screened call waits on.
#
# The caller has said their name and heard the thanks, and the house keeps the
# line while somebody decides to pick up. The tracks are the house's own files
# on the gateway machine - that is the machine with the caller's line, so a
# track named by the phone must be resolved there, never here.
#
# The Hands-Free link carries 8 kHz mono s16le, so every track is converted once
# with ffmpeg and cached by path, size and mtime. A track is named by its path
# relative to the library ("Misidentification/Parlour.mp3"), which is what the
# IVR pane's dropdown stores and what survives a library being added to.
use strict;
use warnings;
use Digest::SHA qw(sha1_hex);
use File::Find ();
use File::Path qw(make_path);
use List::Util qw(shuffle);

# The library. JAWNOS_HOLD_MUSIC exists so a test (or a house with its music
# elsewhere) can point at its own folder without touching the code.
sub music_root {
	return $ENV{'JAWNOS_HOLD_MUSIC'} if defined $ENV{'JAWNOS_HOLD_MUSIC'} && length $ENV{'JAWNOS_HOLD_MUSIC'};
	return &subs::home('~/Music/Jon Ferwerda');
}

sub cache_dir {
	my $dir = (defined $ENV{'JAWNOS_HOLD_CACHE'} && length $ENV{'JAWNOS_HOLD_CACHE'})
		? $ENV{'JAWNOS_HOLD_CACHE'}
		: &subs::home('~/.president/sco/hold');
	make_path($dir) unless -d $dir;
	return $dir;
}

my @AUDIO = qw(mp3 wav flac m4a aac ogg opus);
my $tracks_at = 0;
my $tracks_cache;

# Every playable track in the library, as sorted relative paths. The pane
# offers these and nothing else, so a stored choice always names a real file.
# Cached for a minute: status is written on every plan step and asked for every
# couple of seconds, and walking a music library is not free.
sub tracks {
	my ($refresh) = @_;
	return $tracks_cache if !$refresh && $tracks_cache && time - $tracks_at < 60;
	my $root = &music_root();
	$root = '' unless length $root && -d $root;
	my @out;
	if (length $root) {
		File::Find::find({
			no_chdir => 1,
			wanted => sub {
				return unless -f $File::Find::name;
				my ($ext) = $File::Find::name =~ /\.([A-Za-z0-9]+)$/;
				return unless defined $ext && grep { $_ eq lc $ext } @AUDIO;
				my $rel = $File::Find::name;
				$rel =~ s/^\Q$root\E\/*//;
				push @out, $rel if length $rel;
			},
		}, $root);
	}
	$tracks_cache = [ sort @out ];
	$tracks_at = time;
	return $tracks_cache;
}

# What the dropdown shows: the file's name without its extension, which is what
# a person calls the song, and the folder when two folders share a name.
sub label {
	my ($rel) = @_;
	my $name = $rel || '';
	$name =~ s{.*/}{};
	$name =~ s/\.[A-Za-z0-9]+$//;
	return $name;
}

sub in_library {
	my ($choice) = @_;
	return '' unless defined $choice && length $choice;
	$choice =~ s{^/+}{};
	# a stored choice is a relative path, never a way out of the library
	return '' if $choice =~ /\.\./ || $choice =~ /\0/ || $choice =~ m{^/};
	return $choice;
}

# The raw file for a track, converted on first use. '' when the library has no
# such file or this machine cannot convert it: the plan then simply has no hold
# step, rather than a caller listening to nothing while the gateway believes it
# is playing.
sub raw {
	my ($choice) = @_;
	my $rel = &in_library($choice);
	return '' unless length $rel;
	my $root = &music_root();
	return '' unless length $root;
	my $file = "$root/$rel";
	return '' unless -f $file;
	my @st = stat($file);
	return '' unless @st;
	my $out = &cache_dir() . '/' . sha1_hex("$rel\0$st[7]\0$st[9]") . '.raw';
	return $out if -s $out;
	my $tmp = "$out.tmp.$$";
	my $ok = system('ffmpeg', '-nostdin', '-loglevel', 'error', '-y',
		'-i', $file, '-f', 's16le', '-ar', '8000', '-ac', '1', $tmp);
	if ($ok != 0 || !-s $tmp) {
		unlink $tmp;
		return '';
	}
	rename $tmp, $out or do { unlink $tmp; return '' };
	&prune();
	return $out;
}

# One shuffle's order is one process's own; the plan keeps the list it was
# given and reshuffles when it gets to the end, so a long hold does not fall
# into the same rotation twice.
sub playlist {
	my ($choice) = @_;
	$choice = defined $choice ? $choice : '';
	return [] unless length $choice && lc($choice) ne 'none';
	my @tracks = @{ &tracks(1) };
	if (lc($choice) eq 'shuffle') {
		my @raw = map { &raw($_) } shuffle(@tracks);
		return [ grep { length } @raw ];
	}
	my $one = &raw($choice);
	return $one ? [$one] : [];
}

# The raw cache is keyed by the file's own size and mtime, so an edited track
# makes a new key; the old ones would otherwise collect forever.
sub prune {
	my $dir = &cache_dir();
	my @files = sort { (stat($b))[9] <=> (stat($a))[9] } glob("$dir/*.raw");
	if (@files > 40) { unlink $_ for @files[ 40 .. $#files ]; }
	return 1;
}

1;
