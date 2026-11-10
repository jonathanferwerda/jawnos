package JawnOS::RomCovers;

# Cover art for the emulated shelf, from the libretro thumbnails tree.
#
# This module is deliberately pure: it builds a URL, reads an Apache directory
# listing and picks the closest title, but it never opens a socket and never
# touches the database. scripts/rom_covers.pl owns the network and the files;
# every rule here is testable with a string.
#
# A thumbnail lives at
#   https://thumbnails.libretro.com/<system folder>/<kind>/<title>.png
# where <kind> is Named_Boxarts (preferred), Named_Snaps or Named_Titles. The
# folder names are libretro's own, not ours, so the map below is the one place
# the two vocabularies meet. A system whose folder cannot be confirmed is left
# out rather than guessed at.

use strict;
use warnings;
use utf8;
use File::Basename qw(dirname);
use File::Path qw(make_path);

our $BASE = 'https://thumbnails.libretro.com/';

our %FOLDER = (
	nes          => 'Nintendo - Nintendo Entertainment System',
	snes         => 'Nintendo - Super Nintendo Entertainment System',
	gb           => 'Nintendo - Game Boy',
	gbc          => 'Nintendo - Game Boy Color',
	gba          => 'Nintendo - Game Boy Advance',
	n64          => 'Nintendo - Nintendo 64',
	gamegear     => 'Sega - Game Gear',
	mastersystem => 'Sega - Master System - Mark III',
	megadrive    => 'Sega - Mega Drive - Genesis',
	sega32x      => 'Sega - 32X',
	segacd       => 'Sega - Sega CD',
	saturn       => 'Sega - Saturn',
	psx          => 'Sony - PlayStation',
	psp          => 'Sony - PlayStation Portable',
	dreamcast    => 'Sega - Dreamcast',
	gc           => 'Nintendo - GameCube',
	pcengine     => 'NEC - PC Engine - TurboGrafx 16',
	pcenginecd   => 'NEC - PC Engine CD - TurboGrafx-CD',
	neogeo       => 'SNK - Neo Geo',
	mame2003     => 'MAME',
	atari2600    => 'Atari - 2600',
	atari5200    => 'Atari - 5200',
	atari7800    => 'Atari - 7800',
	atarilynx    => 'Atari - Lynx',
	'3do'        => 'The 3DO Company - 3DO',
	coleco       => 'Coleco - ColecoVision',
	ngp          => 'SNK - Neo Geo Pocket',
	ngpc         => 'SNK - Neo Geo Pocket Color',
);

# The three folders a cover may come from, in the order a caller tries them.
our @KIND = qw(Named_Boxarts Named_Snaps Named_Titles);

sub folder_for {
	my ($system) = @_;
	return undef unless defined $system && length $system;
	return $FOLDER{$system};
}

sub _url_encode {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge;
	return $text;
}

sub _url_decode {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
	return $text;
}

sub _entity_decode {
	my ($text) = @_;
	$text = '' unless defined $text;
	my %entity = (
		'amp' => '&', 'quot' => '"', 'apos' => "'", 'lt' => '<', 'gt' => '>',
		'#39' => "'", '#x27' => "'", '#x2F' => '/', '#47' => '/',
	);
	$text =~ s{&(#?[A-Za-z0-9]+);}{exists $entity{$1} ? $entity{$1} : "&$1;"}ge;
	return $text;
}

sub _join_url {
	my ($base, $href) = @_;
	$base = $BASE unless defined $base && length $base;
	return $href if $href =~ m{^https?://}i;
	if ($href =~ m{^/}) {
		my ($origin) = $base =~ m{^(https?://[^/]+)};
		return ($origin || '') . $href;
	}
	$base =~ s{/*\z}{/};
	return $base . $href;
}

# The thumbnail URL for one title. The title is given without `.png`; if a
# caller passes one it is not doubled. `kind` defaults to the box art.
sub thumbnail_url {
	my ($system, $name, $kind) = @_;
	my $folder = folder_for($system);
	return undef unless defined $folder;
	$kind = 'Named_Boxarts' unless defined $kind && length $kind;
	$name = '' unless defined $name;
	$name =~ s/\.png\z//i;
	return $BASE . _url_encode($folder) . '/' . _url_encode($kind) . '/' . _url_encode($name) . '.png';
}

# The directory a listing comes from. Kept here so the script does not have to
# know the folder vocabulary.
sub listing_url {
	my ($system, $kind) = @_;
	my $folder = folder_for($system);
	return undef unless defined $folder;
	$kind = 'Named_Boxarts' unless defined $kind && length $kind;
	return $BASE . _url_encode($folder) . '/' . _url_encode($kind) . '/';
}

# Apache's directory listing: every href that names a png, keyed by the decoded
# basename without the extension and valued by the absolute URL. &amp; is the
# one entity a filename regularly carries.
sub listing_parse {
	my ($html, $base) = @_;
	my %out;
	return \%out unless defined $html && length $html;
	$base = $BASE unless defined $base && length $base;
	while ($html =~ /href\s*=\s*"([^"]*)"/gi) {
		my $href = _entity_decode($1);
		next unless $href =~ /\.png\z/i;
		my ($leaf) = $href =~ m{([^/]+)\z};
		next unless defined $leaf && length $leaf;
		(my $name = _url_decode($leaf)) =~ s/\.png\z//i;
		next unless length $name;
		$out{$name} = _join_url($base, $href);
	}
	return \%out;
}

# A region token inside parentheses. The short and long names normalise to one
# tag, so a ROM tagged (U) matches a listing tagged (USA).
sub _region_token {
	my ($token) = @_;
	my $text = lc(defined $token ? $token : '');
	return 'usa' if $text eq 'u' || $text eq 'usa' || $text eq 'us';
	return 'europe' if $text eq 'e' || $text eq 'europe' || $text eq 'eur';
	return 'japan' if $text eq 'j' || $text eq 'japan' || $text eq 'jp';
	return 'world' if $text eq 'w' || $text eq 'world';
	return undef;
}

sub _canonical {
	my ($name) = @_;
	$name = '' unless defined $name;
	$name =~ s/\.[A-Za-z0-9]{1,5}\z//;   # a ROM extension, not a title's full stop
	$name =~ s/\[[^\]]*\]//g;            # [!], [b1], [T+Eng]
	my (@regions, @revisions);
	while ($name =~ s/\(([^()]*)\)//) {
		my $group = $1;
		$group =~ s/^\s+|\s+$//g;
		my @tokens = grep { length } split /[\s,\/]+/, $group;
		next unless @tokens;
		my (@here, $all_region);
		$all_region = 1;
		foreach my $token (@tokens) {
			my $region = _region_token($token);
			if (defined $region) { push @here, $region; }
			else { $all_region = 0; }
		}
		if ($all_region && @here) { push @regions, @here; next; }
		if ($group =~ /^Rev(?:ision)?\s*([A-Za-z0-9.]+)$/i) { push @revisions, 'rev' . lc($1); next; }
		if ($group =~ /^V(\d+(?:\.\d+)*)$/i) { push @revisions, 'v' . lc($1); next; }
		# A language list, a date, a publisher or anything else is ignored.
	}
	my $base = $name;
	$base =~ s/_/ /g;
	$base =~ s/&/ and /g;
	$base =~ s/\A(.+?),\s*The\b(.*)\z/The $1$2/i;
	$base =~ s/\s+/ /g;
	$base =~ s/^\s+|\s+$//g;
	$base =~ s/!+\z//;
	$base =~ s/\s+$//;
	my $base_key = lc $base;
	my $key = join ' ', $base_key, @regions, @revisions;
	$key =~ s/\s+/ /g;
	$key =~ s/^\s+|\s+$//g;
	return ($base, \@regions, \@revisions, $key);
}

# Everything the canonicaliser decided, for a caller that needs the parts.
# `key` includes the region and revision tags; `base_key` is the title alone.
sub title_groups {
	my ($name) = @_;
	my ($base, $regions, $revisions, $key) = _canonical($name);
	return {
		base => $base,
		base_key => lc $base,
		regions => $regions,
		revisions => $revisions,
		key => $key,
	};
}

sub name_key {
	return title_groups($_[0])->{'key'};
}

sub _usa {
	my ($name) = @_;
	my $groups = title_groups($name);
	return scalar grep { $_ eq 'usa' } @{ $groups->{'regions'} };
}

# Several candidates may match; USA first, then the key's own order, then the
# raw name, so the answer is the same on every run.
sub _preferred {
	my ($list) = @_;
	my @usa = grep { _usa($_) } @{ $list };
	my @pool = @usa ? @usa : @{ $list };
	@pool = sort { name_key($a) cmp name_key($b) || $a cmp $b } @pool;
	return $pool[0];
}

# Pick the listing name closest to a ROM's title. Deterministic and
# conservative: an exact key, then the title ignoring region and revision, then
# the same digits in the same order, then a whole-word prefix in either
# direction. Anything looser would put the wrong box art on a card.
sub best_match {
	my ($candidates, $title) = @_;
	return undef unless ref $candidates eq 'ARRAY';
	my @names = grep { defined $_ && length $_ } @{ $candidates };
	return undef unless @names;
	my $wanted = title_groups($title);

	my @exact = grep { name_key($_) eq $wanted->{'key'} } @names;
	return _preferred(\@exact) if @exact;

	my @same_base = grep { title_groups($_)->{'base_key'} eq $wanted->{'base_key'} } @names;
	return _preferred(\@same_base) if @same_base;

	my @digits = $wanted->{'base_key'} =~ /(\d+)/g;
	if (@digits) {
		my $wanted_digits = join '|', @digits;
		my @same_digits = grep {
			my @found = title_groups($_)->{'base_key'} =~ /(\d+)/g;
			join('|', @found) eq $wanted_digits;
		} @names;
		return _preferred(\@same_digits) if @same_digits;
	}

	my $base = $wanted->{'base_key'};
	if (length $base >= 4) {
		my @prefix = grep {
			my $other = title_groups($_)->{'base_key'};
			length $other >= 4
				&& ($other =~ /^\Q$base\E(?:\b|$)/ || $base =~ /^\Q$other\E(?:\b|$)/);
		} @names;
		return _preferred(\@prefix) if @prefix;
	}

	return undef;
}

# Download one cover through a caller-supplied fetcher, so the module stays
# network-free. The bytes are checked for PNG magic and land through a
# temporary beside the destination, never over an existing file unless told to.
sub cover_fetch {
	my ($url, $dest, $fetch, $opts) = @_;
	$opts = {} unless ref $opts eq 'HASH';
	return { ok => 0, error => 'There is no destination for the cover.' }
		unless defined $dest && length $dest;
	return { ok => 1, skipped => 1, path => $dest } if -e $dest && !$opts->{'force'};
	return { ok => 0, error => 'There is no downloader.' } unless ref $fetch eq 'CODE';
	my $bytes = $fetch->($url);
	return { ok => 0, error => 'The cover could not be downloaded.' }
		unless defined $bytes && length $bytes;
	return { ok => 0, error => 'That file is not a PNG.' }
		unless substr($bytes, 0, 8) eq "\x89PNG\r\n\x1a\n";
	my $dir = dirname($dest);
	make_path($dir) unless -d $dir;
	my $tmp = $dest . '.tmp.' . $$;
	open(my $fh, '>', $tmp) or return { ok => 0, error => "cannot write $tmp" };
	binmode $fh;
	unless (print $fh $bytes) {
		close $fh;
		unlink $tmp;
		return { ok => 0, error => "cannot write $tmp" };
	}
	unless (close $fh) {
		unlink $tmp;
		return { ok => 0, error => "cannot close $tmp" };
	}
	unless (rename $tmp, $dest) {
		unlink $tmp;
		return { ok => 0, error => "cannot replace $dest" };
	}
	return { ok => 1, path => $dest, bytes => length $bytes };
}

1;
