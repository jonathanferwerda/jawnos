package JawnOS::Sco::Audio;

# A recorded greeting: one house media file, played as 8 kHz mono s16le.
#
# The caller's line carries that shape, so a greeting is converted once with
# ffmpeg and cached by path, size and mtime - the same rule the hold music
# follows (JawnOS::Sco::Hold::raw). A greeting is chosen in the Phone app and
# lives in one of the house's media folders. It may have been sealed by the
# media tree's own policy, so a .enc file is opened here before ffmpeg sees it.
#
# A greeting can be on another machine, or have been moved, or the house may
# have no ffmpeg: every one of those answers '' rather than a path the helper
# would play as silence. The gateway then speaks the flow's text instead.
use strict;
use warnings;
use Cwd qw(realpath);
use Digest::SHA qw(sha1_hex);
use File::Path qw(make_path);
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);

# The converted clips. JAWNOS_SCO_AUDIO_CACHE exists for the same reason
# JAWNOS_HOLD_CACHE does: a test points at its own folder.
sub cache_dir {
	my $dir = (defined $ENV{'JAWNOS_SCO_AUDIO_CACHE'} && length $ENV{'JAWNOS_SCO_AUDIO_CACHE'})
		? $ENV{'JAWNOS_SCO_AUDIO_CACHE'}
		: &subs::home('~/.president/sco/audio');
	make_path($dir) unless -d $dir;
	return $dir;
}

# The folders a greeting may name: the house's own media folders. A recorded
# greeting is a house file like any other, never a path to whatever the
# browser felt like reading. JAWNOS_SCO_AUDIO_ROOTS (colon-separated) is the
# test seam, as JAWNOS_HOLD_MUSIC is for the music library.
sub media_roots {
	my $override = $ENV{'JAWNOS_SCO_AUDIO_ROOTS'};
	if (defined $override && length $override) {
		return grep { length } split /:/, $override;
	}
	my @roots;
	my %seen;
	foreach my $setting (qw(photo_location video_location rec_location music_location)) {
		my $folder = eval { &subs::setting_grabber({ app => 'misc', setting => $setting }) };
		next unless defined $folder && length $folder;
		my $dir = &subs::home($folder);
		next unless defined $dir && length $dir;
		my $real = realpath($dir);
		$real = $dir unless defined $real && length $real;
		next if $seen{$real}++;
		push @roots, $real;
	}
	return @roots;
}

# A stored greeting, as the path of a file the house owns, or ''. A relative
# name is under the house's home; an absolute one is checked the same way.
# realpath is what stops a symlink inside a media folder from reaching out of
# it, and the trailing separator keeps /Pictures2 from passing as /Pictures.
#
# $must_exist is off by default: the flow setting is house-wide and may reach a
# peer before the file does, exactly as a hold-music choice reaches the gateway
# that owns the library. The upload route writes the file before it names it,
# and raw() asks for it to be there, so a caller still never hears silence for
# a path that moved.
sub in_house {
	my ($value, $must_exist) = @_;
	return '' unless defined $value && length $value;
	$value =~ s/^\s+|\s+$//g;
	return '' unless length $value;
	return '' if $value =~ /\0/;
	my $path = $value;
	if ($path =~ /^~/) { $path = &subs::home($path); }
	elsif ($path !~ m{^/}) { $path = &subs::home("~/$path"); }
	return '' if $must_exist && !-f $path;
	my $real = realpath($path);
	if (!defined $real || !length $real) {
		return '' if $must_exist;
		require File::Spec;
		$real = File::Spec->canonpath($path);
	}
	foreach my $root (&media_roots()) {
		return $real if $real eq $root;
		return $real if $root =~ m{/$} ? index($real, $root) == 0 : index($real, "$root/") == 0;
	}
	return '';
}

# The secrets a sealed media file may have been sealed with, in the same order
# and with the same rows file_decrypter uses.
sub sealed_secrets {
	my @secrets;
	my $suds = eval { &subs::suds_grabber() } || '';
	push @secrets, $suds if defined $suds && length $suds;
	my $rows = eval {
		&subs::db_query('select credential from security where level != ? and level != ? order by server_time desc', 'padlock', 'door')->hashes;
	} || [];
	foreach my $row ( @{$rows} ) {
		my $secret = eval { &subs::decrypter($suds, $row->{'credential'}) };
		push @secrets, $secret if defined $secret && length $secret;
	}
	return @secrets;
}

sub open_sealed {
	my ($file) = @_;
	return undef unless defined $file && $file =~ /\.enc$/i && -f $file;
	my @secrets = &sealed_secrets();
	return undef unless @secrets;
	my $standard = eval { &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) } || 'aes-256-ctr';
	return eval {
		&subs::sealed_file_open($file, \@secrets, [ $standard ], 0,
			sub { &subs::plaintext_verdict($_[0]) });
	};
}

# One greeting's plaintext, from the file itself or from its sealed container.
# The pane's Play asks for this; the gateway's converter below writes it to a
# temporary path for ffmpeg instead of keeping another copy.
sub bytes {
	my ($value) = @_;
	my $file = &in_house($value);
	return '' unless length $file;
	return '' unless -f $file;
	return '' if $file !~ /\.enc$/i && !-r $file;
	if ($file =~ /\.enc$/i) {
		my $opened = &open_sealed($file);
		return (ref $opened eq 'HASH' && defined $opened->{'data'}) ? $opened->{'data'} : '';
	}
	my $bytes = eval { &read_file($file) };
	return defined $bytes ? $bytes : '';
}

# The raw clip for a greeting, converted on first use. '' when the file is not
# one the house owns, cannot be opened, or this machine cannot convert it: the
# gateway then falls back to the words, because a caller must never hear
# silence for a file that moved.
sub raw {
	my ($value) = @_;
	my $file = &in_house($value, 1);
	return '' unless length $file;
	my $plain = $file;
	my $temporary = '';
	if ($file =~ /\.enc$/i) {
		my $bytes = &bytes($file);
		return '' unless length $bytes;
		my ($fh, $name) = tempfile('jawn-greeting-XXXXXX', TMPDIR => 1, SUFFIX => '.wav', UNLINK => 0);
		return '' unless $fh;
		binmode $fh;
		print {$fh} $bytes;
		close $fh;
		$plain = $name;
		$temporary = $name;
	}
	my @st = stat($file);
	unless (@st) {
		unlink $temporary if length $temporary;
		return '';
	}
	my $out = &cache_dir() . '/' . sha1_hex("$file\0$st[7]\0$st[9]") . '.raw';
	my $ok = -s $out ? 1 : 0;
	unless ($ok) {
		my $tmp = "$out.tmp.$$";
		my $ran = system('ffmpeg', '-nostdin', '-loglevel', 'error', '-y',
			'-i', $plain, '-f', 's16le', '-ar', '8000', '-ac', '1', $tmp);
		if ($ran == 0 && -s $tmp) {
			if (rename $tmp, $out) {
				$ok = -s $out ? 1 : 0;
			}
			else {
				unlink $tmp;
			}
		}
		else {
			unlink $tmp;
		}
		&prune() if $ok;
	}
	unlink $temporary if length $temporary;
	return $ok ? $out : '';
}

# The raw cache is keyed by the file's own size and mtime, so a new recording
# makes a new key; the old ones would otherwise collect forever.
sub prune {
	my $dir = &cache_dir();
	my @files = sort { (stat($b))[9] <=> (stat($a))[9] } glob("$dir/*.raw");
	if (@files > 40) { unlink $_ for @files[ 40 .. $#files ]; }
	return 1;
}

1;
