package JawnOS::PDF;

# A PDF writer with no external tools: objects, xref and trailer are written
# here, the standard-14 faces are described from the Adobe-wide AFM metrics,
# and a document is laid out by asking this module to draw lines and words at
# points on a page. It exists because the house prints its store papers on a
# phone, where weasyprint (~69 MiB and no package) cannot be installed, and the
# phone must still hand a customer a receipt.
#
# What it draws: text runs in Helvetica, Helvetica-Bold, Times-Roman and
# Courier (WinAnsiEncoding), wrapped paragraphs, rules, filled rectangles, a
# rotated stamp, tables with fixed column widths whose cells wrap and whose
# header repeats after a page break, and JPEG images passed through with
# DCTDecode. Page sizes are Letter, A4 and an 80mm receipt roll.
#
# Coordinates: the public API is top-down. `y` is points from the top edge of
# the page (0 is the top), which is how a document flows; the writer converts
# each one to PDF's bottom-up space once, at draw time. `x` is from the left.
#
# Names are not always Latin-1: the house accepts every printable character in
# a name. When a string cannot be written in WinAnsi and a TrueType font is on
# the machine (DejaVu, Liberation or the Android system fonts), the text is
# drawn as a Type0/Identity-H CIDFontType2 with the whole font embedded and
# glyph ids read from its cmap. With no font file, the text is sanitised to the
# WinAnsi characters it can keep, the rest become '?', and the substitution is
# logged through the logger the caller supplied (warn otherwise).
#
# Two things this deliberately does not do: it does not render HTML (that stays
# weasyprint's job) and it does not decode PNG or SVG. A JPEG is cheap because
# its bytes are already DCT data; anything else would be an image decoder.

use strict;
use warnings;
use utf8;

our $VERSION = '1.0';

# ---------------------------------------------------------------- page sizes
my %PAGE = (
	letter    => [612, 792],
	a4        => [595.28, 841.89],
	legal     => [612, 1008],
	'80mm'    => [226.77, 841.89],
	receipt80 => [226.77, 841.89],
	receipt   => [226.77, 841.89],
);

# --------------------------------------------------------------- AFM widths
# Widths in 1/1000 em for WinAnsi codes 32..255. These are the Adobe core-font
# metrics (the URW base35 faces ship the same advances), embedded so the writer
# never needs an AFM file at run time.
my %WIDTHS = (
	'Helvetica' => '278,278,355,556,556,889,667,191,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,278,278,584,584,584,556,1015,667,667,722,722,667,611,778,722,278,500,667,556,833,722,778,667,778,722,667,611,722,667,944,667,667,611,278,278,278,469,556,333,556,556,500,556,556,278,556,556,222,222,500,222,833,556,556,556,556,333,500,278,556,500,722,500,500,500,334,260,334,584,500,500,500,222,556,333,1000,556,556,333,1000,500,333,1000,500,500,500,500,222,222,333,333,350,556,1000,333,500,500,333,944,500,500,500,278,333,556,556,556,556,500,556,333,500,370,556,500,333,500,333,500,500,500,500,333,500,537,278,333,500,365,556,500,500,500,611,500,500,500,500,500,500,1000,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,778,500,500,500,500,500,500,611,500,500,500,500,500,500,889,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,611,500,500,500,500,500,500,500',
	'Helvetica-Bold' => '278,333,474,556,556,889,722,238,333,333,389,584,278,333,278,278,556,556,556,556,556,556,556,556,556,556,333,333,584,584,584,611,975,722,722,722,722,667,611,778,722,278,556,722,611,833,722,778,667,778,722,667,611,722,667,944,667,667,611,333,278,333,584,556,333,556,611,556,611,556,333,611,611,278,278,556,278,889,611,611,611,611,389,556,333,611,556,778,556,556,500,389,280,389,584,500,500,500,278,556,500,1000,556,556,333,1000,500,333,1000,500,500,500,500,278,278,500,500,350,556,1000,333,500,500,333,944,500,500,500,278,333,556,556,556,556,500,556,333,500,370,556,500,333,500,333,500,500,500,500,333,500,556,278,333,500,365,556,500,500,500,611,500,500,500,500,500,500,1000,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,778,500,500,500,500,500,500,611,500,500,500,500,500,500,889,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,611,500,500,500,500,500,500,500',
	'Times-Roman' => '250,333,408,500,500,833,778,180,333,333,500,564,250,333,250,278,500,500,500,500,500,500,500,500,500,500,278,278,564,564,564,444,921,722,667,667,722,611,556,722,722,333,389,722,611,889,722,722,556,722,667,556,611,722,722,944,722,722,611,333,278,333,469,500,333,444,500,444,500,444,333,500,500,278,278,500,278,778,500,500,500,500,333,389,278,500,500,722,500,500,444,480,200,480,541,500,500,500,333,500,444,1000,500,500,333,1000,500,333,889,500,500,500,500,333,333,444,444,350,500,1000,333,500,500,333,722,500,500,500,250,333,500,500,500,500,500,500,333,500,276,500,500,333,500,333,500,500,500,500,333,500,453,250,333,500,310,500,500,500,500,444,500,500,500,500,500,500,889,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,722,500,500,500,500,500,500,500,500,500,500,500,500,500,667,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500,500',
	'Courier' => '600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600,600',
);

my %ALIAS = (
	'helvetica'       => 'Helvetica',
	'helvetica-bold'  => 'Helvetica-Bold',
	'helvetica_bold'  => 'Helvetica-Bold',
	'bold'            => 'Helvetica-Bold',
	'times'           => 'Times-Roman',
	'times-roman'     => 'Times-Roman',
	'times_roman'     => 'Times-Roman',
	'serif'           => 'Times-Roman',
	'courier'         => 'Courier',
	'mono'            => 'Courier',
	'monospace'       => 'Courier',
);

# Where a machine keeps a TrueType font, most specific first. The phone's
# Android system fonts are included because a phone is the machine that most
# needs this path; fc-match is consulted only when it exists, and a Perl phone
# has no fontconfig.
my @FONT_DIRS = qw(
	/usr/share/fonts/truetype/dejavu
	/usr/share/fonts/truetype/liberation
	/usr/share/fonts/truetype/droid
	/usr/share/fonts/TTF
	/usr/share/fonts/dejavu
	/usr/share/fonts/truetype
	/usr/local/share/fonts
	/system/fonts
);

my %STYLE_FILES = (
	'Helvetica'      => [qw(DejaVuSans.ttf LiberationSans-Regular.ttf NotoSans-Regular.ttf Roboto-Regular.ttf)],
	'Helvetica-Bold' => [qw(DejaVuSans-Bold.ttf LiberationSans-Bold.ttf NotoSans-Bold.ttf Roboto-Bold.ttf)],
	'Times-Roman'    => [qw(DejaVuSerif.ttf LiberationSerif-Regular.ttf)],
	'Courier'        => [qw(DejaVuSansMono.ttf LiberationMono-Regular.ttf)],
);

# Faces that carry scripts the Latin faces do not: a name in Chinese or
# Japanese asks for one of these after the styled face fails to map it.
my @FALLBACK_FILES = qw(
	DroidSansFallbackFull.ttf DroidSansFallback.ttf
	NotoSansCJK-Regular.ttf NotoSansCJKsc-Regular.ttf
	NotoSansJP-Regular.ttf
);

# Unicode spellings of the WinAnsi characters that people actually type. A
# string made only of these stays a standard-14 face: no font is embedded for
# a curly apostrophe or an em dash.
my %UNI_WINANSI = (
	0x20AC => 0x80, 0x201A => 0x82, 0x0192 => 0x83, 0x201E => 0x84,
	0x2026 => 0x85, 0x2020 => 0x86, 0x2021 => 0x87, 0x02C6 => 0x88,
	0x2030 => 0x89, 0x0160 => 0x8A, 0x2039 => 0x8B, 0x0152 => 0x8C,
	0x017D => 0x8E, 0x2018 => 0x91, 0x2019 => 0x92, 0x201C => 0x93,
	0x201D => 0x94, 0x2022 => 0x95, 0x2013 => 0x96, 0x2014 => 0x97,
	0x02DC => 0x98, 0x2122 => 0x99, 0x0161 => 0x9A, 0x203A => 0x9B,
	0x0153 => 0x9C, 0x017E => 0x9E, 0x0178 => 0x9F,
);

my %TTF_CACHE;

sub new {
	my ($class, %opt) = @_;
	my $size = lc($opt{'size'} || 'letter');
	my $dim = $PAGE{$size} || $PAGE{'letter'};
	my $m = $opt{'margin'};
	my ($ml, $mt, $mr, $mb);
	if (ref $m eq 'ARRAY') {
		($ml, $mt, $mr, $mb) = @{$m};
		$mt = $ml unless defined $mt;
		$mr = $ml unless defined $mr;
		$mb = $mt unless defined $mb;
	}
	elsif (defined $m) {
		($ml, $mt, $mr, $mb) = ($m, $m, $m, $m);
	}
	else {
		($ml, $mt, $mr, $mb) = ($size =~ /80mm|receipt/ ? (12, 14, 12, 16) : (42, 42, 42, 48));
	}
	my $self = bless {
		width   => $dim->[0],
		height  => $dim->[1],
		size    => $size,
		margin  => [$ml, $mt, $mr, $mb],
		cursor  => $mt,
		pages   => [''],
		objects => [
			{ body => '' },   # 1 catalog
			{ body => '' },   # 2 pages
		],
		font_res   => {},   # resource name => object number
		font_seq   => 0,    # resource names are reserved when allocated, not
		                    # when the object is written at the end
		base_fonts => {},   # family => { res => ... }
		uni_fonts  => {},   # path => { res, font, used => {} }
		images     => {},   # resource name => object number
		logger     => $opt{'logger'},
		quiet      => $opt{'quiet'},
		warnings   => [],
		warned     => {},
	}, $class;
	return $self;
}

sub width       { $_[0]->{'width'} }
sub height      { $_[0]->{'height'} }
sub page_size   { $_[0]->{'size'} }
sub margin      { @{$_[0]->{'margin'}} }
sub warnings    { $_[0]->{'warnings'} }
sub page_count  { scalar @{$_[0]->{'pages'}} }
sub cursor      { $_[0]->{'cursor'} }
sub set_cursor  { $_[0]->{'cursor'} = $_[1] }

sub content_width {
	my ($self) = @_;
	return $self->{'width'} - $self->{'margin'}[0] - $self->{'margin'}[2];
}

sub content_height {
	my ($self) = @_;
	return $self->{'height'} - $self->{'margin'}[1] - $self->{'margin'}[3];
}

sub bottom {
	my ($self) = @_;
	return $self->{'height'} - $self->{'margin'}[3];
}

# --------------------------------------------------------------- log / warn
sub _warn {
	my ($self, $message) = @_;
	return if $self->{'warned'}{$message}++;
	push @{$self->{'warnings'}}, $message;
	if ($self->{'logger'}) {
		eval { $self->{'logger'}->($message); 1 };
		return;
	}
	warn "$message\n" unless $self->{'quiet'};
}

# ------------------------------------------------------------------- objects
sub add_object {
	my ($self, $body, $stream, %opt) = @_;
	push @{$self->{'objects'}}, {
		body   => $body,
		stream => $stream,
		%opt,
	};
	return scalar @{$self->{'objects'}};
}

sub _num {
	my ($n) = @_;
	$n = 0 unless defined $n && $n =~ /^-?[0-9.]+$/;
	return sprintf('%.2f', $n + 0);
}

sub _color {
	my ($color, $stroke) = @_;
	my $op = $stroke ? 'RG' : 'rg';
	return '0 0 0 ' . $op unless defined $color;
	if (ref $color eq 'ARRAY') {
		return join(' ', map { _num($_) } @{$color}[0 .. 2]) . ' ' . $op;
	}
	if ($color =~ /^\s*#?([0-9a-f]{6})\s*$/i) {
		my ($r, $g, $b) = map { hex($_) / 255 } $1 =~ /(..)(..)(..)/;
		return _num($r) . ' ' . _num($g) . ' ' . _num($b) . ' ' . $op;
	}
	my $gray = $color =~ /^-?[0-9.]+$/ ? $color : 0;
	return _num($gray) . ' g' if !$stroke;
	return _num($gray) . ' G';
}

# --------------------------------------------------------------------- pages
sub new_page {
	my ($self) = @_;
	push @{$self->{'pages'}}, '';
	$self->{'cursor'} = $self->{'margin'}[1];
	return $self->{'cursor'};
}

sub ensure_space {
	my ($self, $needed) = @_;
	$needed = 0 unless defined $needed;
	if ($self->{'cursor'} + $needed > $self->bottom) {
		$self->new_page;
	}
	return $self->{'cursor'};
}

# --------------------------------------------------------------------- text
sub _family {
	my ($name) = @_;
	$name = 'Helvetica' unless defined $name && length $name;
	my $key = lc $name;
	$key =~ s/\s+/ /g;
	return $ALIAS{$key} || 'Helvetica';
}

# WinAnsi bytes for a Perl character string. Returns the bytes and the number
# of characters that had no WinAnsi spelling.
sub _winansi {
	my ($text) = @_;
	my $out = '';
	my $missing = 0;
	for my $ch (split //, $text) {
		my $o = ord $ch;
		if (($o >= 0x20 && $o <= 0x7E) || ($o >= 0xA0 && $o <= 0xFF)) {
			$out .= chr $o;
		}
		elsif (exists $UNI_WINANSI{$o}) {
			$out .= chr $UNI_WINANSI{$o};
		}
		else {
			$out .= '?';
			$missing++;
		}
	}
	return ($out, $missing);
}

sub _winansi_char {
	my ($o) = @_;
	return 1 if ($o >= 0x20 && $o <= 0x7E) || ($o >= 0xA0 && $o <= 0xFF);
	return exists $UNI_WINANSI{$o} ? 1 : 0;
}

sub _width_of {
	my ($family, $code) = @_;
	my $table = $WIDTHS{$family} || $WIDTHS{'Helvetica'};
	my @w = split /,/, $table;
	my $i = $code - 32;
	return ($i >= 0 && $i < @w) ? $w[$i] : 500;
}

sub _pdf_string {
	my ($bytes) = @_;
	$bytes = '' unless defined $bytes;
	$bytes =~ s/([\\()])/\\$1/g;
	$bytes =~ s/([^\x20-\x7e])/sprintf('\\%03o', ord $1)/ge;
	return '(' . $bytes . ')';
}

sub _string_op {
	my ($enc) = @_;
	return $enc->{'cid'} ? '<' . unpack('H*', $enc->{'bytes'}) . '>' : _pdf_string($enc->{'bytes'});
}

sub _next_font_res {
	my ($self) = @_;
	return 'F' . (++$self->{'font_seq'});
}

sub _base_resource {
	my ($self, $family) = @_;
	$family = _family($family);
	return $self->{'base_fonts'}{$family} if $self->{'base_fonts'}{$family};
	my $obj = $self->add_object(
		"<< /Type /Font /Subtype /Type1 /BaseFont /$family /Encoding /WinAnsiEncoding >>"
	);
	my $res = $self->_next_font_res;
	$self->{'font_res'}{$res} = $obj;
	return $self->{'base_fonts'}{$family} = { res => $res, family => $family };
}

my %FONT_FOR_CHAR;

# The font that has a glyph for this one character, remembered per character so
# a wrapped line does not re-walk the candidate list for every measurement.
sub _font_for_char {
	my ($family, $ch) = @_;
	my $key = $family . "\0" . ord($ch);
	return $FONT_FOR_CHAR{$key} if exists $FONT_FOR_CHAR{$key};
	for my $path (_candidate_ttfs($family)) {
		my $font = _ttf_load($path) or next;
		return $FONT_FOR_CHAR{$key} = { font => $font } if _glyph($font, ord $ch);
	}
	return $FONT_FOR_CHAR{$key} = undef;
}

sub _unicode_resource {
	my ($self, $family, $char) = @_;
	my $found = _font_for_char($family, $char);
	return undef unless $found;
	my $font = $found->{'font'};
	my $path = $font->{'path'};
	return $self->{'uni_fonts'}{$path} if $self->{'uni_fonts'}{$path};
	my $res = $self->_next_font_res;
	return $self->{'uni_fonts'}{$path} = {
		res  => $res,
		font => $font,
		used => {},
	};
}

# Turns a string into runs, at most one per font: WinAnsi text stays in the
# standard-14 face, and a character the face cannot show goes to the TrueType
# font that has it. A run is { res, bytes, cid, font }.
sub _encode {
	my ($self, $text, $family) = @_;
	$family = _family($family);
	my $base = $self->_base_resource($family);
	my @chars = split //, $text;
	my @runs;
	my $i = 0;
	while ($i < @chars) {
		my $o = ord $chars[$i];
		if (_winansi_char($o)) {
			my $bytes = '';
			while ($i < @chars && _winansi_char(ord $chars[$i])) {
				my ($b) = _winansi($chars[$i]);
				$bytes .= $b;
				$i++;
			}
			push @runs, { res => $base->{'res'}, bytes => $bytes, cid => 0 };
			next;
		}
		my $uni = $self->_unicode_resource($family, $chars[$i]);
		if ($uni) {
			my $path = $uni->{'font'}{'path'};
			my $bytes = '';
			while ($i < @chars && !_winansi_char(ord $chars[$i])) {
				my $here = $self->_unicode_resource($family, $chars[$i]);
				last unless $here && $here->{'font'}{'path'} eq $path;
				my $gid = _glyph($here->{'font'}, ord $chars[$i]);
				$here->{'used'}{$gid} = 1;
				$bytes .= pack('n', $gid);
				$i++;
			}
			push @runs, { res => $uni->{'res'}, bytes => $bytes, cid => 1, font => $uni->{'font'} };
			next;
		}
		# No font on this machine can show the character: keep the rest of
		# the run honest with '?' and say so once.
		my $bytes = '';
		my $lost = 0;
		while ($i < @chars && !_winansi_char(ord $chars[$i])) {
			$bytes .= '?';
			$lost++;
			$i++;
		}
		$self->_warn('PDF: no TrueType font covers ' . $lost
			. ' character(s) in "' . $text . '"; they became "?"');
		push @runs, { res => $base->{'res'}, bytes => $bytes, cid => 0 };
	}
	return \@runs;
}

sub _runs_width {
	my ($self, $runs, $family, $size) = @_;
	my $total = 0;
	for my $run (@{$runs}) {
		if ($run->{'cid'}) {
			my $font = $run->{'font'};
			$total += _glyph_width($font, $_) for unpack('n*', $run->{'bytes'});
		}
		else {
			$total += _width_of($family, $_) for unpack('C*', $run->{'bytes'});
		}
	}
	return $total * $size / 1000;
}

sub text_width {
	my ($self, $text, $family, $size) = @_;
	$text = '' unless defined $text;
	$family = _family($family);
	$size = 10 unless defined $size;
	return $self->_runs_width($self->_encode($text, $family), $family, $size);
}

sub text {
	my ($self, $string, $x, $y, %opt) = @_;
	$string = '' unless defined $string;
	$string = "$string";
	return 0 unless length $string;
	$x = $self->{'margin'}[0] unless defined $x;
	$y = $self->{'cursor'} unless defined $y;
	my $family = _family($opt{'font'} || $opt{'family'});
	my $size = defined $opt{'size'} ? $opt{'size'} : 10;
	my $align = $opt{'align'} || 'left';
	my $w = $self->text_width($string, $family, $size);
	if (defined $opt{'width'} && ($align eq 'right' || $align eq 'center')) {
		$x += ($opt{'width'} - $w) / ($align eq 'center' ? 2 : 1);
	}
	my $runs = $self->_encode($string, $family);
	my $fill = _color(defined $opt{'color'} ? $opt{'color'} : 0);
	my $py = $self->{'height'} - $y;
	my $stream = 'BT ' . $fill . ' 1 0 0 1 ' . _num($x) . ' ' . _num($py) . ' Tm ';
	for my $run (@{$runs}) {
		$stream .= '/' . $run->{'res'} . ' ' . _num($size) . ' Tf '
			. _string_op($run) . ' Tj ';
	}
	$self->{'pages'}[-1] .= $stream . "ET\n";
	return $w;
}

sub wrap {
	my ($self, $text, $family, $size, $width) = @_;
	$text = '' unless defined $text;
	$family = _family($family);
	$size = 10 unless defined $size;
	$width = $self->content_width unless defined $width && $width > 0;
	my @lines;
	for my $para (split /\r?\n/, $text) {
		$para =~ s/^\s+//;
		$para =~ s/\s+$//;
		if (!length $para) {
			push @lines, '';
			next;
		}
		my $line = '';
		for my $word (split / +/, $para) {
			my $candidate = length($line) ? $line . ' ' . $word : $word;
			if ($self->text_width($candidate, $family, $size) <= $width) {
				$line = $candidate;
				next;
			}
			if (!length $line) {
				# A single word wider than the column: break it by character.
				my $chunk = '';
				for my $ch (split //, $word) {
					if (length($chunk) && $self->text_width($chunk . $ch, $family, $size) > $width) {
						push @lines, $chunk;
						$chunk = $ch;
					}
					else {
						$chunk .= $ch;
					}
				}
				$line = $chunk;
				next;
			}
			push @lines, $line;
			$line = $word;
		}
		push @lines, $line if length $line;
	}
	@lines = ('') unless @lines;
	return \@lines;
}

# Draws a wrapped paragraph and returns the y just below it.
sub paragraph {
	my ($self, $string, $x, $y, $width, %opt) = @_;
	my $family = _family($opt{'font'} || $opt{'family'});
	my $size = defined $opt{'size'} ? $opt{'size'} : 10;
	my $leading = defined $opt{'leading'} ? $opt{'leading'} : $size * 1.35;
	my $align = $opt{'align'} || 'left';
	my $lines = $self->wrap($string, $family, $size, $width);
	my $cy = $y;
	for my $line (@{$lines}) {
		$self->text($line, $x, $cy, font => $family, size => $size,
			align => $align, width => $width, color => $opt{'color'});
		$cy += $leading;
	}
	return $y + scalar(@{$lines}) * $leading;
}

# ------------------------------------------------------------- shapes / line
sub rule {
	my ($self, $x1, $y1, $x2, $y2, %opt) = @_;
	$x1 = $self->{'margin'}[0] unless defined $x1;
	$y1 = $self->{'cursor'} unless defined $y1;
	$y2 = $y1 unless defined $y2;
	$x2 = $x1 + $self->content_width unless defined $x2;
	my $line_width = defined $opt{'width'} ? $opt{'width'} : 0.5;
	my $stroke = _color(defined $opt{'color'} ? $opt{'color'} : 0, 'stroke');
	$self->{'pages'}[-1] .= $stroke . ' ' . _num($line_width) . ' w '
		. _num($x1) . ' ' . _num($self->{'height'} - $y1) . ' m '
		. _num($x2) . ' ' . _num($self->{'height'} - $y2) . " l S\n";
	return $y1;
}

sub rect {
	my ($self, $x, $y, $w, $h, %opt) = @_;
	$x = $self->{'margin'}[0] unless defined $x;
	$y = $self->{'cursor'} unless defined $y;
	my $py = $self->{'height'} - $y - $h;
	my $paint = $opt{'fill'} && $opt{'stroke'} ? 'B' : $opt{'stroke'} ? 'S' : 'f';
	my $op = '';
	if ($opt{'fill'}) {
		$op .= _color($opt{'fill'} eq '1' ? 0 : $opt{'fill'}) . ' ';
	}
	if ($opt{'stroke'}) {
		$op .= _color($opt{'stroke_color'} || $opt{'color'} || 0, 'stroke') . ' '
			. _num(defined $opt{'line_width'} ? $opt{'line_width'} : 0.5) . ' w ';
	}
	$self->{'pages'}[-1] .= $op . _num($x) . ' ' . _num($py) . ' '
		. _num($w) . ' ' . _num($h) . ' re ' . $paint . "\n";
	return $y + $h;
}

# A large word across the paper, rotated and pale, exactly as a rubber stamp
# leans: the mark is behind everything drawn after it.
sub stamp {
	my ($self, $string, %opt) = @_;
	$string = '' unless defined $string;
	return 0 unless length $string;
	my $family = _family($opt{'font'} || 'Helvetica-Bold');
	my $size = defined $opt{'size'} ? $opt{'size'} : 72;
	my $angle = defined $opt{'angle'} ? $opt{'angle'} : -8;
	my $cx = defined $opt{'x'} ? $opt{'x'} : $self->{'width'} / 2;
	my $cy = defined $opt{'y'} ? $opt{'y'} : $self->{'height'} / 3;
	my $w = $self->text_width($string, $family, $size);
	my $rad = $angle * 3.14159265358979 / 180;
	my ($co, $si) = (cos($rad), sin($rad));
	my $runs = $self->_encode($string, $family);
	my $fill = _color($opt{'color'} || '#cc0000');
	my $frame = _num($co) . ' ' . _num($si) . ' ' . _num(-$si) . ' ' . _num($co)
		. ' ' . _num($cx) . ' ' . _num($self->{'height'} - $cy);
	my $s = 'q ' . $fill . ' ' . $frame . ' cm BT 1 0 0 1 '
		. _num(-$w / 2) . ' ' . _num(-$size * 0.35) . ' Tm ';
	for my $run (@{$runs}) {
		$s .= '/' . $run->{'res'} . ' ' . _num($size) . ' Tf '
			. _string_op($run) . ' Tj ';
	}
	$s .= 'ET';
	if ($opt{'box'}) {
		$s .= ' 0.9 w 0.7 0 0 RG ' . _num(-$w / 2 - 8) . ' ' . _num(-$size * 0.45)
			. ' ' . _num($w + 16) . ' ' . _num($size * 1.35) . ' re S';
	}
	$s .= " Q\n";
	$self->{'pages'}[-1] .= $s;
	return $w;
}

# --------------------------------------------------------------------- table
sub _cell_parts {
	my ($cell, $font) = @_;
	my ($text, $fam, $align, $color) = ('', $font, 'left', undef);
	if (ref $cell eq 'HASH') {
		$text = $cell->{'text'};
		$fam = _family($cell->{'bold'} ? 'Helvetica-Bold' : ($cell->{'font'} || $font));
		$align = $cell->{'align'} if defined $cell->{'align'};
		$color = $cell->{'color'};
	}
	else {
		$text = $cell;
	}
	$text = '' unless defined $text;
	return ($text, $fam, $align, $color);
}

sub table {
	my ($self, %opt) = @_;
	my $x = defined $opt{'x'} ? $opt{'x'} : $self->{'margin'}[0];
	my $y = defined $opt{'y'} ? $opt{'y'} : $self->{'cursor'};
	my @w = @{$opt{'widths'} || [1]};
	my $maxw = 0;
	for my $col (@w) { $maxw = $col if $col > $maxw }
	if ($maxw <= 1.001) {
		my $cw = defined $opt{'width'} ? $opt{'width'} : $self->content_width;
		@w = map { $_ * $cw } @w;
	}
	my $total = 0;
	$total += $_ for @w;
	my $font = _family($opt{'font'} || 'Helvetica');
	my $header_font = _family($opt{'header_font'} || 'Helvetica-Bold');
	my $size = defined $opt{'size'} ? $opt{'size'} : 9;
	my $leading = defined $opt{'leading'} ? $opt{'leading'} : $size * 1.25;
	my $pad = defined $opt{'padding'} ? $opt{'padding'} : 4;
	my $aligns = $opt{'align'} || [];
	my $header = $opt{'header'};
	my $bottom = $self->bottom;
	my $rules = defined $opt{'rules'} ? $opt{'rules'} : 1;
	my $rule_color = $opt{'rule_color'} || '#cccccc';
	my $header_rule = $opt{'header_rule'} || 0;
	my $draw_header = sub {
		my ($at) = @_;
		return $at unless $header && scalar @{$header};
		my @cells;
		my $h = 0;
		for my $i (0 .. $#w) {
			my ($txt, $fam, $al, $col) = _cell_parts($header->[$i], $header_font);
			$fam = $header_font;
			$al = $aligns->[$i] if defined $aligns->[$i]
				&& !(ref $header->[$i] eq 'HASH' && defined $header->[$i]{'align'});
			my $lines = $self->wrap($txt, $fam, $size, $w[$i] - 2 * $pad);
			push @cells, { lines => $lines, fam => $fam, align => $al, color => $col };
			my $lh = scalar(@{$lines}) * $leading;
			$h = $lh if $lh > $h;
		}
		$h += 2 * $pad;
		if ($at + $h > $bottom) {
			$self->new_page;
			$at = $self->{'cursor'};
		}
		my $colx = $x;
		for my $i (0 .. $#w) {
			my $cell = $cells[$i];
			my $lx = $colx + $pad;
			my $ly = $at + $pad + $size * 0.8;
			for my $line (@{$cell->{'lines'}}) {
				$self->text($line, $lx, $ly, font => $cell->{'fam'}, size => $size,
					align => $cell->{'align'}, width => $w[$i] - 2 * $pad,
					color => $cell->{'color'});
				$ly += $leading;
			}
			$colx += $w[$i];
		}
		$self->rule($x, $at + $h, $x + $total, $at + $h,
			width => $header_rule || 0.75, color => '#000000');
		return $at + $h;
	};
	$y = $draw_header->($y);
	for my $row (@{$opt{'rows'} || []}) {
		my @cells;
		my $h = 0;
		for my $i (0 .. $#w) {
			my ($txt, $fam, $al, $col) = _cell_parts($row->[$i], $font);
			$al = $aligns->[$i] if defined $aligns->[$i]
				&& !(ref $row->[$i] eq 'HASH' && defined $row->[$i]{'align'});
			my $lines = $self->wrap($txt, $fam, $size, $w[$i] - 2 * $pad);
			push @cells, { lines => $lines, fam => $fam, align => $al, color => $col };
			my $lh = scalar(@{$lines}) * $leading;
			$h = $lh if $lh > $h;
		}
		$h += 2 * $pad;
		if ($y + $h > $bottom) {
			$self->new_page;
			$y = $self->{'cursor'};
			$y = $draw_header->($y);
		}
		my $colx = $x;
		for my $i (0 .. $#w) {
			my $cell = $cells[$i];
			my $lx = $colx + $pad;
			my $ly = $y + $pad + $size * 0.8;
			for my $line (@{$cell->{'lines'}}) {
				$self->text($line, $lx, $ly, font => $cell->{'fam'}, size => $size,
					align => $cell->{'align'}, width => $w[$i] - 2 * $pad,
					color => $cell->{'color'});
				$ly += $leading;
			}
			$colx += $w[$i];
		}
		$y += $h;
		$self->rule($x, $y, $x + $total, $y, width => 0.25, color => $rule_color) if $rules;
	}
	$self->{'cursor'} = $y;
	return $y;
}

sub column_x {
	my ($self, $x, $widths, $index) = @_;
	my $cx = $x;
	$cx += $widths->[$_] for 0 .. $index - 1;
	return $cx;
}

# -------------------------------------------------------------------- images
sub _jpeg_info {
	my ($bytes) = @_;
	return () unless defined $bytes && length $bytes > 4;
	return () unless substr($bytes, 0, 2) eq "\xFF\xD8";
	my $i = 2;
	while ($i + 4 <= length $bytes) {
		return () unless substr($bytes, $i, 1) eq "\xFF";
		my $marker = ord substr($bytes, $i + 1, 1);
		$i += 2;
		next if $marker == 0xD8 || $marker == 0x01 || ($marker >= 0xD0 && $marker <= 0xD7);
		return () if $marker == 0xD9 || $marker == 0xDA;
		return () if $i + 2 > length $bytes;
		my $len = unpack('n', substr($bytes, $i, 2));
		return () if $len < 2;
		if (($marker >= 0xC0 && $marker <= 0xCF) && $marker != 0xC4
			&& $marker != 0xC8 && $marker != 0xCC) {
			return () if $i + 8 > length $bytes;
			my $h = unpack('n', substr($bytes, $i + 3, 2));
			my $w = unpack('n', substr($bytes, $i + 5, 2));
			my $n = ord substr($bytes, $i + 7, 1);
			return ($w, $h, $n);
		}
		$i += $len;
	}
	return ();
}

sub image_jpeg {
	my ($self, $bytes, $x, $y, $w, $h, %opt) = @_;
	my ($jw, $jh, $n) = _jpeg_info($bytes);
	return undef unless $jw && $jh;
	my $colorspace = $n == 1 ? '/DeviceGray' : $n == 3 ? '/DeviceRGB' : $n == 4 ? '/DeviceCMYK' : undef;
	return undef unless $colorspace;
	my $res = 'Im' . (scalar(keys %{$self->{'images'}}) + 1);
	my $decode = $n == 4 ? ' /Decode [1 0 1 0 1 0 1 0]' : '';
	my $obj = $self->add_object(
		"<< /Type /XObject /Subtype /Image /Width $jw /Height $jh /ColorSpace $colorspace"
		. " /BitsPerComponent 8 /Filter /DCTDecode$decode /Length " . length($bytes) . ' >>',
		$bytes,
	);
	$self->{'images'}{$res} = $obj;
	$x = $self->{'margin'}[0] unless defined $x;
	$y = $self->{'cursor'} unless defined $y;
	$w = $jw unless defined $w;
	$h = $jh unless defined $h;
	$self->{'pages'}[-1] .= 'q ' . _num($w) . ' 0 0 ' . _num($h) . ' '
		. _num($x) . ' ' . _num($self->{'height'} - $y - $h) . ' cm /' . $res . " Do Q\n";
	return ($w, $h);
}

# --------------------------------------------------------------------- fonts
my %FONT_CANDIDATES;

sub _candidate_ttfs {
	my ($family) = @_;
	return @{$FONT_CANDIDATES{$family}} if $FONT_CANDIDATES{$family};
	my @out;
	my $env = $ENV{'JAWN_PDF_FONT'};
	push @out, $env if defined $env && length $env && -f $env && $env =~ /\.ttf$/i;
	my @names = (@{$STYLE_FILES{$family} || $STYLE_FILES{'Helvetica'}}, @FALLBACK_FILES);
	for my $dir (@FONT_DIRS) {
		for my $name (@names) {
			my $path = "$dir/$name";
			push @out, $path if -f $path;
		}
	}
	# fontconfig answers where a package put the files; a phone has no
	# fontconfig and a Perl phone has no reason to shell out to a missing tool.
	my $fc = `command -v fc-match 2>/dev/null`;
	chomp $fc if defined $fc;
	if (defined $fc && length $fc && -x $fc) {
		my $wanted = $family eq 'Helvetica-Bold' ? 'sans:bold'
			: $family eq 'Times-Roman' ? 'serif'
			: $family eq 'Courier' ? 'mono' : 'sans';
		for my $query ($wanted, ':lang=zh') {
			my $found = `$fc -f '%{file}' '$query' 2>/dev/null`;
			chomp $found if defined $found;
			push @out, $found if defined $found && length $found && -f $found && $found =~ /\.ttf$/i;
		}
	}
	my %seen;
	@out = grep { !$seen{$_}++ } @out;
	return @{$FONT_CANDIDATES{$family} = \@out};
}

sub _ttf_load {
	my ($path) = @_;
	my @st = stat($path);
	return undef unless @st;
	my $key = $path . ':' . $st[9] . ':' . $st[7];
	return $TTF_CACHE{$key} if $TTF_CACHE{$key};
	open my $fh, '<:raw', $path or return undef;
	local $/;
	my $data = <$fh>;
	close $fh;
	return undef unless defined $data && length $data > 12;
	return undef unless substr($data, 0, 4) eq "\x00\x01\x00\x00";
	my $count = unpack('n', substr($data, 4, 2));
	my %tab;
	for my $i (0 .. $count - 1) {
		my $rec = substr($data, 12 + $i * 16, 16);
		next unless length($rec) == 16;
		my ($tag, $sum, $off, $len) = unpack('a4 N N N', $rec);
		next unless $off + $len <= length $data;
		$tab{$tag} = [$off, $len];
	}
	return undef unless $tab{'head'} && $tab{'hhea'} && $tab{'maxp'}
		&& $tab{'hmtx'} && $tab{'cmap'};
	my $head = substr($data, $tab{'head'}[0], $tab{'head'}[1]);
	my $hhea = substr($data, $tab{'hhea'}[0], $tab{'hhea'}[1]);
	my $maxp = substr($data, $tab{'maxp'}[0], $tab{'maxp'}[1]);
	my $hmtx = substr($data, $tab{'hmtx'}[0], $tab{'hmtx'}[1]);
	my $units = unpack('n', substr($head, 18, 2)) || 1000;
	my ($xmin, $ymin, $xmax, $ymax) = unpack('s>4', substr($head, 36, 8));
	my $ascent = unpack('s>', substr($hhea, 4, 2));
	my $descent = unpack('s>', substr($hhea, 6, 2));
	my $hmetrics = unpack('n', substr($hhea, 34, 2));
	my $glyphs = unpack('n', substr($maxp, 4, 2));
	$hmetrics = 1 if $hmetrics < 1;
	my @advances;
	for my $i (0 .. $hmetrics - 1) {
		last if $i * 4 + 2 > length $hmtx;
		push @advances, unpack('n', substr($hmtx, $i * 4, 2));
	}
	@advances = (1000) unless @advances;
	my $cmap = substr($data, $tab{'cmap'}[0], $tab{'cmap'}[1]);
	my $map = _cmap_best($cmap);
	return undef unless $map;
	my $font = {
		path       => $path,
		data       => $data,
		units      => $units,
		bbox       => [$xmin, $ymin, $xmax, $ymax],
		ascent     => $ascent,
		descent    => $descent,
		num_glyphs => $glyphs,
		advances   => \@advances,
		cmap       => $map,
	};
	$TTF_CACHE{$key} = $font;
	return $font;
}

sub _cmap_best {
	my ($cmap) = @_;
	return undef unless length $cmap >= 4;
	my $count = unpack('n', substr($cmap, 2, 2));
	my ($score, $offset) = (-1, undef);
	for my $i (0 .. $count - 1) {
		last if 4 + $i * 8 + 8 > length $cmap;
		my ($platform, $encoding, $off) = unpack('n n N', substr($cmap, 4 + $i * 8, 8));
		next if $off + 2 > length $cmap;
		my $format = unpack('n', substr($cmap, $off, 2));
		my $s = 0;
		if ($format == 12 && (($platform == 3 && $encoding == 10) || $platform == 0)) {
			$s = 4;
		}
		elsif ($format == 4 && (($platform == 3 && $encoding == 1) || $platform == 0)) {
			$s = 3;
		}
		elsif ($format == 4 && $platform == 3 && $encoding == 0) {
			$s = 2;
		}
		if ($s > $score) {
			($score, $offset) = ($s, $off);
		}
	}
	return undef unless defined $offset;
	my $format = unpack('n', substr($cmap, $offset, 2));
	return _cmap4($cmap, $offset) if $format == 4;
	return _cmap12($cmap, $offset) if $format == 12;
	return undef;
}

sub _cmap4 {
	my ($cmap, $off) = @_;
	my $segments = int(unpack('n', substr($cmap, $off + 6, 2)) / 2);
	return undef unless $segments > 0;
	return {
		format   => 4,
		data     => $cmap,
		end      => $off + 14,
		start    => $off + 16 + $segments * 2,
		delta    => $off + 16 + $segments * 4,
		range    => $off + 16 + $segments * 6,
		segments => $segments,
	};
}

sub _cmap12 {
	my ($cmap, $off) = @_;
	my $groups = unpack('N', substr($cmap, $off + 12, 4));
	return undef if $off + 16 + $groups * 12 > length $cmap;
	my @groups;
	for my $i (0 .. $groups - 1) {
		my ($start, $end, $glyph) = unpack('N3', substr($cmap, $off + 16 + $i * 12, 12));
		push @groups, [$start, $end, $glyph];
	}
	return { format => 12, groups => \@groups };
}

sub _glyph {
	my ($font, $code) = @_;
	my $map = $font->{'cmap'};
	return 0 unless $map;
	if ($map->{'format'} == 12) {
		my $lo = 0;
		my $hi = $#{$map->{'groups'}};
		while ($lo <= $hi) {
			my $mid = int(($lo + $hi) / 2);
			my $g = $map->{'groups'}[$mid];
			if ($code < $g->[0]) { $hi = $mid - 1 }
			elsif ($code > $g->[1]) { $lo = $mid + 1 }
			else { return $g->[2] + ($code - $g->[0]) }
		}
		return 0;
	}
	return 0 if $code > 0xFFFF;
	my $c = $map->{'data'};
	my $segments = $map->{'segments'};
	for my $i (0 .. $segments - 1) {
		my $end = unpack('n', substr($c, $map->{'end'} + $i * 2, 2));
		next if $code > $end;
		my $start = unpack('n', substr($c, $map->{'start'} + $i * 2, 2));
		return 0 if $code < $start;
		my $delta = unpack('s>', substr($c, $map->{'delta'} + $i * 2, 2));
		my $range = unpack('n', substr($c, $map->{'range'} + $i * 2, 2));
		return ($code + $delta) & 0xFFFF if $range == 0;
		my $at = $map->{'range'} + $i * 2 + $range + ($code - $start) * 2;
		return 0 if $at + 1 >= length $c;
		my $glyph = unpack('n', substr($c, $at, 2));
		return 0 if $glyph == 0;
		return ($glyph + $delta) & 0xFFFF;
	}
	return 0;
}

sub _glyph_width {
	my ($font, $gid) = @_;
	my $count = scalar @{$font->{'advances'}};
	my $advance = $gid < $count ? $font->{'advances'}[$gid] : $font->{'advances'}[$count - 1];
	my $units = $font->{'units'} || 1000;
	return $advance * 1000 / $units;
}

sub _deflate {
	my ($bytes) = @_;
	return undef unless eval { require IO::Compress::Deflate; 1 };
	my $out = '';
	return undef unless IO::Compress::Deflate::deflate(\$bytes => \$out);
	return $out;
}

sub _build_unicode_fonts {
	my ($self) = @_;
	for my $path (keys %{$self->{'uni_fonts'}}) {
		my $entry = $self->{'uni_fonts'}{$path};
		next if $entry->{'built'};
		my $font = $entry->{'font'};
		my $units = $font->{'units'} || 1000;
		my $scale = sub { sprintf('%.2f', $_[0] * 1000 / $units) };
		# /W groups consecutive glyph ids so the array stays small.
		my @gids = sort { $a <=> $b } keys %{$entry->{'used'}};
		my @runs;
		for my $gid (@gids) {
			my $width = sprintf('%.2f', _glyph_width($font, $gid));
			if (@runs && $runs[-1][1] == $gid - 1) {
				push @{$runs[-1][2]}, $width;
				$runs[-1][1] = $gid;
			}
			else {
				push @runs, [$gid, $gid, [$width]];
			}
		}
		my $w = '[ ' . join(' ', map { $_->[0] . ' [' . join(' ', @{$_->[2]}) . ']' } @runs) . ' ]';
		my $data = $font->{'data'};
		my $packed = _deflate($data);
		my $filter = defined $packed ? ' /Filter /FlateDecode' : '';
		my $bytes = defined $packed ? $packed : $data;
		my $file = $self->add_object(
			"<< /Length " . length($bytes) . ' /Length1 ' . length($data) . $filter . ' >>',
			$bytes,
		);
		my $bbox = join(' ', map { $scale->($_) } @{$font->{'bbox'}});
		my $descriptor = $self->add_object(
			"<< /Type /FontDescriptor /FontName /JawnOSEmbedded /Flags 4 /FontBBox [$bbox]"
			. ' /ItalicAngle 0 /Ascent ' . $scale->($font->{'ascent'})
			. ' /Descent ' . $scale->($font->{'descent'})
			. ' /CapHeight ' . $scale->($font->{'ascent'})
			. ' /StemV 80 /FontFile2 ' . $file . ' 0 R >>'
		);
		my $descendant = $self->add_object(
			"<< /Type /Font /Subtype /CIDFontType2 /BaseFont /JawnOSEmbedded"
			. ' /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>'
			. " /FontDescriptor $descriptor 0 R /DW 1000 /W $w /CIDToGIDMap /Identity >>"
		);
		my $type0 = $self->add_object(
			"<< /Type /Font /Subtype /Type0 /BaseFont /JawnOSEmbedded /Encoding /Identity-H"
			. " /DescendantFonts [$descendant 0 R] >>"
		);
		$self->{'font_res'}{$entry->{'res'}} = $type0;
		$entry->{'built'} = 1;
	}
}

# -------------------------------------------------------------------- output
sub _resource_dict {
	my ($self) = @_;
	my @fonts;
	for my $name (sort keys %{$self->{'font_res'}}) {
		push @fonts, "/$name $self->{'font_res'}{$name} 0 R";
	}
	my @images;
	for my $name (sort keys %{$self->{'images'}}) {
		push @images, "/$name $self->{'images'}{$name} 0 R";
	}
	my $dict = '<< /ProcSet [/PDF /Text /ImageB /ImageC] /Font << '
		. join(' ', @fonts) . ' >>';
	$dict .= ' /XObject << ' . join(' ', @images) . ' >>' if @images;
	return $dict . ' >>';
}

sub bytes {
	my ($self) = @_;
	$self->_build_unicode_fonts;
	# A trailing page the caller opened and never drew on is dropped.
	pop @{$self->{'pages'}}
		if scalar @{$self->{'pages'}} > 1 && $self->{'pages'}[-1] eq '';
	my $resources = $self->_resource_dict;
	my @kids;
	for my $content (@{$self->{'pages'}}) {
		my $content_obj = $self->add_object("<< /Length " . length($content) . ' >>', $content);
		my $page_obj = $self->add_object(
			"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 "
			. _num($self->{'width'}) . ' ' . _num($self->{'height'})
			. "] /Resources $resources /Contents $content_obj 0 R >>"
		);
		push @kids, "$page_obj 0 R";
	}
	$self->{'objects'}[0]{'body'} = '<< /Type /Catalog /Pages 2 0 R >>';
	$self->{'objects'}[1]{'body'} = '<< /Type /Pages /Kids ['
		. join(' ', @kids) . '] /Count ' . scalar(@kids) . ' >>';

	my $out = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n";
	my @offset;
	for my $i (0 .. $#{$self->{'objects'}}) {
		my $object = $self->{'objects'}[$i];
		$offset[$i + 1] = length $out;
		$out .= ($i + 1) . " 0 obj\n" . $object->{'body'} . "\n";
		if (defined $object->{'stream'}) {
			$out .= "stream\n" . $object->{'stream'} . "\nendstream\n";
		}
		$out .= "endobj\n";
	}
	my $xref = length $out;
	my $count = scalar(@{$self->{'objects'}}) + 1;
	$out .= "xref\n0 $count\n0000000000 65535 f \n";
	for my $n (1 .. $count - 1) {
		$out .= sprintf("%010d 00000 n \n", $offset[$n] || 0);
	}
	$out .= "trailer\n<< /Size $count /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n";
	return $out;
}

sub save {
	my ($self, $path) = @_;
	return (undef, 'no path given') unless defined $path && length $path;
	my $bytes = $self->bytes;
	open my $fh, '>:raw', $path or return (undef, "could not write $path: $!");
	print $fh $bytes;
	close $fh;
	return (-s $path) ? ($path, undef) : (undef, "nothing was written to $path");
}

1;
