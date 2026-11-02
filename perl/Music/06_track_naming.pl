package Manager;
use strict;
use warnings;
no warnings 'uninitialized';
use feature 'signatures';

# ---- what a track is called -------------------------------------------------
#
# The library is a folder tree - artist/album/track - but a file's own name
# often carries more than its folder, and a release name such as
# Doctor.Who.S03E06.720p.HDTV.x264 tells nobody what the episode is. The list
# shows three things and only three: the artist, the album and the track. A
# music file normally carries them as tags, so those win. A video usually has
# only its name: the episode marker is read out of it (S03E06, 1x02,
# Season 3 Episode 6), and the quality, source, codec and release group are
# dropped, so both kinds read the same way.

sub music_trim_text {
	my $text = shift;
	return '' unless defined $text;
	$text = "$text";
	$text =~ s/[\x00-\x1f\x7f]+/ /g;
	$text =~ s/\s+/ /g;
	$text =~ s/^ | $//g;
	return $text;
}

# A folder or file name rather than a tag: dots and underscores stand in for
# spaces, and a name stored wholly in lower case is title-cased. A name that
# already carries a capital keeps its own spelling (AC/DC stays AC/DC).
sub music_path_text {
	my $text = &music_trim_text(shift);
	$text =~ s/[._]+/ /g;
	$text =~ s/\s+/ /g;
	$text =~ s/^ | $//g;
	if ($text !~ /\p{Lu}/) {
		$text =~ s/(^|[\s\-\(\[])(\p{Ll})/$1 . uc($2)/ge;
	}
	return $text;
}

# Everything a release name carries that is about the file and not the work.
my $music_release_junk = qr{
	\b(?:
		(?:2160|1440|1080|720|576|480|360)p
		|4k|uhd|hdr10|hdr
		|blu[ .-]?ray|bdrip|brrip|remux|web[ .-]?dl|webrip|web[ .-]?rip
		|hdtv|pdtv|dvd|dvdrip|dvdscr|hdrip|hdlight
		|x264|x265|h[ .]?264|h[ .]?265|hevc|avc|xvid|divx
		|10bit|8bit|hi10p
		|aac|ac3|eac3|dts(?:[ .-]?hd)?|ddp?[ .]?[57][ .]?1|truehd|flac|opus
		|amzn|dsnp|hmax|atvp|yify|yts|rarbg|eztv|galaxytv
	)\b
}ix;

sub music_strip_release {
	my $text = &music_trim_text(shift);
	return '' unless length $text;
	$text =~ s/\[[^\]]*\]//g;
	$text =~ s/\{[^}]*\}//g;
	$text =~ s/\([^)]*(?:\d{3,4}p|rip|x26[45]|hevc|avc|aac|ac3|dts|hdr|uhd|web)[^)]*\)//gi;
	my $had_junk = ($text =~ s/$music_release_junk/ /gi) ? 1 : 0;
	# a group tag usually hangs off the last release token, as in x264-GROUP
	$text =~ s/\s*[-\x{2013}\x{2014}]\s*[A-Za-z0-9][A-Za-z0-9._-]{1,24}\s*$// if $had_junk;
	# edges: Arrested Development - S01E01 - Pilot leaves "- Pilot"; the dashes
	# belong to the release name, not the episode
	$text =~ s/^[\s\-\x{2013}\x{2014}:;,.|_]+//;
	$text =~ s/^[+&]\s+//;
	$text =~ s/[\s\-\x{2013}\x{2014}:;,.|_]+$//;
	return &music_trim_text($text);
}

# A file's extension tells us how to play it, never what it is. song_maker has
# already removed the audio ones it recognises; this finishes the job for video
# (and for a sealed track, whose real extension sits inside .enc).
my $music_media_extension = qr/\.(?:mp4|m4v|mkv|avi|mov|webm|wmv|flv|mpg|mpeg|m2ts|ts|mp3|m4a|wav|flac|aac|ogg|opus|aiff|wma)$/i;
sub music_media_stem {
	my $text = shift;
	return '' unless defined $text;
	my $stem = "$text";
	$stem =~ s/\.enc$//i;
	$stem =~ s/$music_media_extension//;
	return $stem;
}

sub music_episode_from_text {
	my $text = shift;
	return {} unless defined $text && length $text;
	# S06E01, S06X01 / S04M01 (The Office and Sabrina use X and M),
	# S01E01+E02, S07E17X01, S07E21+22
	if ($text =~ /^(.*?)\s*\bS(\d{1,2})\s*([EXM])(\d{1,3})(?:\s*[+&]\s*[EXM]?\d{1,3})*(?:\s*X\d{1,3})?\b(.*)$/i) {
		my ($show, $season, $marker, $episode, $rest) = ($1, $2, $3, $4, $5);
		return { show => $show, season => $season, episode => $episode, rest => $rest,
			code => sprintf('S%02d%s%02d', $season, uc $marker, $episode) };
	}
	# 1x02, and 4x22 & 23
	if ($text =~ /^(.*?)\s*\b(\d{1,2})\s*x\s*(\d{1,3})(?:\s*[+&]\s*\d{1,3})*\b(.*)$/i) {
		return { show => $1, season => $2, episode => $3, rest => $4, code => sprintf('S%02dE%02d', $2, $3) };
	}
	if ($text =~ /^(.*?)\s*\b(?:Season|Series)\s*(\d{1,2})\s*(?:Episode|Ep)\s*(\d{1,3})\b(.*)$/i) {
		return { show => $1, season => $2, episode => $3, rest => $4, code => sprintf('S%02dE%02d', $2, $3) };
	}
	# Episode 6 / E06 / X01 / M01. X264 and X265 are codecs, not episodes.
	if ($text =~ /^(.*?)\s*\b([EXM])(?:p|pisode)?\s*(\d{1,3})\b(.*)$/i) {
		my ($show, $marker, $episode, $rest) = ($1, $2, $3, $4);
		unless (uc($marker) eq 'X' && $episode =~ /^26[45]$/) {
			my $code = ($marker =~ /E/i) ? sprintf('Episode %d', $episode) : sprintf('%s%02d', uc $marker, $episode);
			return { show => $show, season => '', episode => $episode, rest => $rest, code => $code };
		}
	}
	# Home Improvement - 315 - Reel Men: a packed season/episode code
	if ($text =~ /^(.*?)\s*[-\x{2013}\x{2014}]\s*(\d)(\d{2})\s*[-\x{2013}\x{2014}]\s*(.*)$/) {
		return { show => $1, season => $2, episode => $3, rest => $4, code => sprintf('S%02dE%02d', $2, $3) };
	}
	# Home Improvement 5-01 A Taylor Runs Through It
	if ($text =~ /^(.*?)\s*\b(\d{1,2})\s*[-\x{2013}\x{2014}]\s*(\d{2})\b(.*)$/) {
		return { show => $1, season => $2, episode => $3, rest => $4, code => sprintf('S%02dE%02d', $2, $3) };
	}
	return {};
}

# A release tag repeated through a whole folder (GalaxyTV, PSA, SAiNTS, 2CH) is
# part of the release, not the episode. Only tokens that *look* like release
# noise are taken: one with a digit, one in capitals at the end, or one sitting
# after a known release token. This is deliberately narrow - in the Portugal.
# The Man album every track ends in "Magic", and Magic is the title, not noise.
sub music_common_noise {
	my $files = shift;
	my %noise;
	my @names;
	foreach my $path ( @{$files || []} ) {
		next unless defined $path && length $path;
		my $base = $path;
		$base =~ s{.*/}{};
		$base = &music_media_stem($base);
		push @names, $base if length $base;
	}
	my $count = scalar @names;
	return {} if $count < 3;
	my $need = int($count * 0.8 + 0.9999);
	my (%seen, %after, %last);
	foreach my $base ( @names ) {
		my @token = grep { length } split /[^A-Za-z0-9]+/, $base;
		next unless scalar @token;
		my %once;
		$once{$_} = 1 for @token;
		$seen{$_}++ for keys %once;
		$last{$token[-1]}++ if length $token[-1];
		my $marked = 0;
		foreach my $token ( @token ) {
			if ($token =~ $music_release_junk) {
				$marked = 1;
				next;
			}
			$after{$token}++ if $marked;
		}
	}
	foreach my $token ( keys %seen ) {
		next if length($token) < 2;
		next if $token =~ /^\d+$/;
		next if $token =~ /^[Ss]\d{1,2}[EeXxMm]?\d{0,3}$/;
		next if $token =~ /^\d{1,2}x\d{1,3}$/i;
		next if $token =~ /^(?:the|a|an|and|or|of|to|in|on|for|with|at|by|from|one|two|part|vol|ep|episode|season|series)$/i;
		next if ($seen{$token} || 0) < $need;
		my $digit = ($token =~ /\d/) ? 1 : 0;
		my $caps = ($token =~ /^[A-Z0-9]{2,12}$/) ? 1 : 0;
		my $after = (($after{$token} || 0) >= $need) ? 1 : 0;
		my $last = (($last{$token} || 0) >= $need) ? 1 : 0;
		$noise{lc $token} = 1 if $digit || $after || ($caps && $last);
	}
	return \%noise;
}

# The three labels every track carries, worked out once so the list, the icons
# grid and the phone all draw the same words.
sub music_media_labels {
	my ($f, $noise) = @_;
	$noise ||= {};
	my $tags = (ref($f->{'info'}) && ref($f->{'info'}->{'tags'})) ? $f->{'info'}->{'tags'} : {};
	my $tag_artist = &music_trim_text($tags->{'artist'} || $tags->{'album_artist'} || '');
	my $tag_album  = &music_trim_text($tags->{'album'} || '');
	my $tag_title  = &music_trim_text($tags->{'title'} || '');
	my $is_video = (($f->{'type'} || '') eq 'video') ? 1 : 0;
	my $folder_artist = &music_path_text($f->{'artist_name'} // $f->{'artist'});
	my $folder_album  = &music_path_text($f->{'album_name'} // $f->{'album'});
	my $stem = &music_path_text(&music_media_stem($f->{'full_title'} || $f->{'song'}));
	# folder names that only say where the file is, not who made it
	my %generic = map { $_ => 1 } qw/videos video movies movie tv television shows show media library music audio films film/;
	$folder_artist = '' if $generic{lc $folder_artist};
	$folder_album  = '' if $generic{lc $folder_album};
	if ($is_video) {
		# A folder carries release notes too ("(360p re-dvdrip)"), and a
		# whole-series folder carries a range ("S01-S07 (1993-)"). Clean both
		# before they become the artist and album.
		$folder_artist = &music_strip_release($folder_artist);
		$folder_album  = &music_strip_release($folder_album);
		my $album_range = ($folder_album =~ /\bS\d{1,2}\s*[-\x{2013}\x{2014}]\s*S?\d{1,2}\b/i
			|| $folder_album =~ /\b(?:season|series)\s*\d{1,2}\s*[-\x{2013}\x{2014}]\s*\d{1,2}\b/i) ? 1 : 0;
		my $series_name = '';
		if ($album_range) {
			($series_name = $folder_album) =~ s/\s*\bS\d{1,2}\s*[-\x{2013}\x{2014}]\s*S?\d{1,2}\b//ig;
			$series_name =~ s/\s*\b(?:season|series)\s*\d{1,2}\s*[-\x{2013}\x{2014}]\s*\d{1,2}\b//ig;
			$folder_album = '';
		}
		foreach my $name ( \$folder_artist, \$folder_album ) {
			next unless length $$name;
			$$name =~ s/\s*\bS\d{1,2}\s*[-\x{2013}\x{2014}]\s*S?\d{1,2}\b//ig;
			$$name =~ s/\s*\b(?:season|series)\s*\d{1,2}\s*[-\x{2013}\x{2014}]\s*\d{1,2}\b//ig;
			$$name =~ s/\s*\((?:19|20)\d{2}\s*[-\x{2013}\x{2014}]\s*(?:\d{2,4})?\)\s*$//;
			$$name =~ s/\s+\b(?:19|20)\d{2}\s*[-\x{2013}\x{2014}]\s*(?:\d{2,4})?$// if $$name =~ /[^\d\s]/;
			$$name = &music_trim_text($$name);
		}
		# a whole-series folder is the show, not an album: when the file sits
		# directly in it, that show is the artist and the season comes from the
		# episode marker (Entourage S08M01, Sabrina TTW X01)
		if (!length $folder_artist && length $series_name) {
			$series_name =~ s/\s*\((?:19|20)\d{2}\s*[-\x{2013}\x{2014}]\s*(?:\d{2,4})?\)\s*$//;
			$series_name =~ s/\s+\b(?:19|20)\d{2}\s*[-\x{2013}\x{2014}]\s*(?:\d{2,4})?$// if $series_name =~ /[^\d\s]/;
			$folder_artist = &music_trim_text($series_name);
		}
	}
	# "Home Improvement Season 3", "The Office US S06 (360p re-blurip)" and
	# "Friends Season 1" are all the same shelf; name it Season N. A folder
	# holding a range (S01-S09, Season 1-3) was emptied above.
	if ($folder_album =~ /\b(?:season|series)\s*(\d{1,2})\b(?!\s*[-\x{2013}\x{2014}]\s*[SE]?\d)/i
		|| $folder_album =~ /\bS(\d{1,2})\b(?!\s*[-\x{2013}\x{2014}]\s*[SE]?\d)/i) {
		$folder_album = 'Season ' . (0 + $1);
	}

	my ($artist, $album, $track, $code);
	if (($f->{'type'} || '') eq 'video') {
		my $ep = &music_episode_from_text($stem);
		# A container's own title is sometimes the release name itself; trust it
		# only when it is not that.
		my $tag_ok = length($tag_title)
			&& $tag_title !~ /\bS\d{1,2}\s*[EXM]\d{1,3}\b/i
			&& $tag_title !~ /\b(?:\d{3,4}p|4k|x26[45]|hevc|web[ .-]?dl|blu[ .-]?ray)\b/i
			&& $tag_title !~ /\.(?:mp4|m4v|mkv|avi|mov|webm|wmv|flv|mpg|mpeg|m2ts|ts)$/i;
		if ($ep->{'episode'}) {
			$artist = &music_strip_release($ep->{'show'});
			# Doctor Who 2005 is the same show as Doctor Who in the folder
			$artist =~ s/\s*\((?:19|20)\d{2}\)\s*$//;
			$artist =~ s/\s+\b(?:19|20)\d{2}\s*$// if $artist =~ /[^\d\s]/;
			$artist = &music_trim_text($artist);
			$artist = $tag_artist if !length $artist;
			$artist = $folder_artist if !length $artist;
			$code = $ep->{'code'};
			my $title = &music_strip_release($ep->{'rest'});
			$title = $tag_title if !length($title) && $tag_ok && lc($tag_title) ne lc($artist);
			$track = length($title) ? $title : $code;
			my $season_no = $ep->{'season'};
			my $folder_is_season = $folder_album =~ /\b(?:season|series)\b|\bS\d{1,2}\b/i;
			if (length($folder_album) && lc($folder_album) ne lc($artist) && ($folder_is_season || length $season_no)) {
				$album = $folder_album;
			}
			elsif (length $season_no) {
				$album = 'Season ' . (0 + $season_no);
			}
			else {
				$album = $folder_album;
			}
			$album = $tag_album if !length $album;
		}
		else {
			$artist = $tag_artist || $folder_artist;
			$album = $tag_album || $folder_album;
			# "001 - Pilot" (Boy Meets World): the number is the episode and the
			# season is the folder. Only where the folder names a season, so a
			# film called 300 keeps its number.
			my ($season_no) = $folder_album =~ /^Season\s*(\d+)$/i;
			my $name_rest;
			if (length($season_no) && $stem =~ /^(\d{1,3})(?:-\d)?\s*[-\x{2013}\x{2014}]\s*(.+)$/) {
				my $ep_no = $1;
				$name_rest = $2;
				$code = sprintf('S%02dE%02d', $season_no, $ep_no);
			}
			if ($tag_ok) {
				$track = $tag_title;
			}
			elsif (defined $name_rest) {
				$track = &music_strip_release($name_rest);
			}
			else {
				$track = &music_strip_release($stem);
			}
			# a film has no artist/album split: the folder is the work, so it
			# becomes the artist rather than an album that repeats the title
			if (!length($artist) && length($album) && $album !~ /^Season\s+\d+$/i) {
				$artist = $album;
				$album = '';
			}
			# the film's year sits in the folder; do not repeat it in the track
			if (length($artist) && $artist =~ /\(((?:19|20)\d{2})\)/) {
				my $year = $1;
				$track =~ s/\s*\b\Q$year\E\b\s*$//;
			}
			# a film filed as Movies/Inception/inception-2010.mkv would otherwise
			# read the same words twice; when there is no artist, the album is the
			# only other word worth keeping, so drop it only when it repeats the track
			if (!length($artist) && length($album)) {
				my $album_key = lc $album;
				my $track_key = lc $track;
				$album_key =~ s/[^\p{L}\p{N}]+//g;
				$track_key =~ s/[^\p{L}\p{N}]+//g;
				$album = '' if $album_key eq $track_key;
			}
		}
	}
	else {
		$artist = $tag_artist || $folder_artist;
		$album = $tag_album || $folder_album;
		$track = $tag_title;
		if (!length $track) {
			# no tag: the file name, with its track number and any repeated artist
			my $name = &music_strip_release($stem);
			$name =~ s/^\d{1,3}[\s._-]+//;
			$track = $name;
		}
	}
	# the show's own name is the artist, not part of the track
	if (length $artist) {
		$track =~ s/^\s*\Q$artist\E\s*[-\x{2013}\x{2014}:]\s*//i;
	}
	# a tag repeated through the folder is release noise (GalaxyTV, 2CH, PSA)
	if (%{$noise}) {
		my @word;
		foreach my $word ( split /\s+/, $track ) {
			(my $key = $word) =~ s/[^\p{L}\p{N}]+//g;
			next if length($key) && $noise->{lc $key};
			push @word, $word;
		}
		$track = &music_trim_text(join ' ', @word);
	}
	$track =~ s/^[\s\-\x{2013}\x{2014}:;,.|_]+//;
	$track =~ s/[\s\-\x{2013}\x{2014}:;,.|_]+$//;
	$track = &music_trim_text($track);
	$track = $code if !length($track) && length($code);
	$track = $stem if !length $track;
	return {
		artist => $artist,
		album => $album,
		track => $track,
		code => $code || '',
		meta => join(' ' . chr(0xB7) . ' ', grep { length } ($artist, $album)),
	};
}

1;
