package subs;

# Article: the allowlist an article's HTML passes through before it is stored or
# drawn. The magazine editor writes markup that the homepage renders raw (an
# article is the newspaper), and magazine rows sync between machines, so the
# content is treated as untrusted on both the way in and the way out.
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;

# What an article may contain: the blocks the editor writes, the inline markup a
# paste can carry, and the media a drop can bring. Anything else keeps its text
# and loses its tag.
my %ARTICLE_TAG = map { $_ => 1 } qw(
	p br h1 h2 h3 h4 h5 h6 a img video audio source blockquote figure figcaption
	hr strong b em i u s ul ol li span div sup sub small
);

# An element whose *content* is dropped too: it is not a block we understand, it
# is an instruction we refuse to carry.
my %ARTICLE_DROP = map { $_ => 1 } qw(
	script style iframe object embed applet svg math template noscript form input
	button select textarea option link meta base frame frameset title head canvas
);

# class is allowed everywhere; everything else is a short list per tag.
my %ARTICLE_ATTR = (
	a      => { href => 1, title => 1, target => 1, rel => 1 },
	img    => { src => 1, alt => 1, title => 1, width => 1, height => 1, loading => 1 },
	video  => { src => 1, poster => 1, controls => 1, loop => 1, muted => 1, preload => 1, width => 1, height => 1, playsinline => 1 },
	audio  => { src => 1, controls => 1, loop => 1, muted => 1, preload => 1 },
	source => { src => 1, type => 1 },
	td     => { colspan => 1, rowspan => 1 },
);

# The CSS an article may set. The editor writes colours and a few sizes; a
# property outside this list could position or hide a block on the homepage.
my %ARTICLE_CSS = map { $_ => 1 } qw(
	color background-color background text-align font-size font-weight font-style
	font-family text-decoration line-height letter-spacing float display
	vertical-align white-space word-break word-wrap
	margin margin-top margin-right margin-bottom margin-left
	padding padding-top padding-right padding-bottom padding-left
	border border-color border-style border-width border-radius
	width max-width min-width height max-height min-height
);

# Void elements: they have no end tag, so nothing is buffered for them.
my %ARTICLE_VOID = map { $_ => 1 } qw(br hr img source);

# The article is always walked. HTML::Parser costs about 1.5 ms for a 41 KB
# document, which is cheap enough to pay on every read (the homepage draws
# articles the public can see, and old rows were written before this rule).

# The schemes a link or a source may use. A relative path, the house's own
# routes, the open web, an image/video/audio data URL.
sub article_url_ok {
	my ($url) = @_;
	return 0 unless defined $url;
	(my $u = $url) =~ s/[\x00-\x20]//g;
	return 1 if $u =~ m{^(?:/(?!/)|\./|\.\./|#)};
	return 1 if $u =~ m{^https?://}i;
	return 1 if $u =~ m{^data:(?:image/(?:png|jpeg|jpg|gif|webp|avif)|video/[a-z0-9.+-]+|audio/[a-z0-9.+-]+)[;,]}i;
	return 1 if $u =~ m{^(?:mailto|tel):}i;
	return 0;
}

sub article_style_clean {
	my ($style) = @_;
	return '' unless defined $style && length $style;
	my @keep;
	foreach my $decl (split /;/, $style) {
		next unless $decl =~ /^\s*([a-z-]+)\s*:\s*(.*?)\s*$/i;
		my ($prop, $value) = (lc $1, $2);
		next unless $ARTICLE_CSS{$prop};
		next if $value =~ /url\s*\(|expression|javascript:|vbscript:|\@import|[\\<>"]/i;
		$value =~ s/!important//gi;
		$value =~ s/\s+$//;
		next unless length $value;
		push @keep, $prop . ':' . $value;
	}
	return join ';', @keep;
}

sub article_html_clean {
	my ($html) = @_;
	return '' unless defined $html && length $html;

	require HTML::Parser;
	my $out = '';
	my @open;
	my @skip;
	my $skip_depth = 0;

	my $escape = sub {
		(my $value = shift // '') =~ s/&/&amp;/g;
		$value =~ s/"/&quot;/g;
		$value =~ s/</&lt;/g;
		$value =~ s/>/&gt;/g;
		return $value;
	};

	my $p = HTML::Parser->new(api_version => 3, unbroken_text => 1, marked_sections => 1);
	$p->handler(start => sub {
		my ($tag, $attr) = @_;
		if (@skip) {
			$skip_depth++ if $tag eq $skip[-1];
			return;
		}
		if ($ARTICLE_DROP{$tag}) {
			push @skip, $tag;
			$skip_depth = 0;
			return;
		}
		return unless $ARTICLE_TAG{$tag};
		my $allowed = $ARTICLE_ATTR{$tag} || {};
		my @written;
		foreach my $name (sort keys %{$attr}) {
			next unless $allowed->{$name} || $name eq 'class' || $name eq 'style';
			next if $name =~ /^on/i;
			my $value = $attr->{$name};
			next unless defined $value;
			if ($name eq 'href' || $name eq 'src') {
				next unless &article_url_ok($value);
			}
			elsif ($name eq 'style') {
				$value = &article_style_clean($value);
				next unless length $value;
			}
			elsif ($name eq 'class') {
				$value =~ s/[^A-Za-z0-9_\- ]//g;
				$value =~ s/^\s+//;
				$value =~ s/\s+$//;
				next unless length $value;
			}
			push @written, $name . '="' . $escape->($value) . '"';
		}
		$out .= '<' . $tag . (@written ? ' ' . join(' ', @written) : '') . '>';
		push @open, $tag unless $ARTICLE_VOID{$tag};
	}, 'tagname,attr');
	$p->handler(text => sub {
		my ($text) = @_;
		return if @skip;
		$out .= $text;
	}, 'text');
	$p->handler(end => sub {
		my ($tag) = @_;
		if (@skip) {
			if ($tag eq $skip[-1]) {
				if ($skip_depth) { $skip_depth-- }
				else { pop @skip }
			}
			return;
		}
		return unless @open;
		# an end tag that closes something we never opened is dropped; one that
		# closes an element we did open closes everything above it too, so a
		# crossed pair cannot leave the article unbalanced
		my $at = -1;
		for (my $i = $#open; $i >= 0; $i--) {
			if ($open[$i] eq $tag) { $at = $i; last; }
		}
		return if $at < 0;
		while (@open > $at) {
			my $closing = pop @open;
			$out .= '</' . $closing . '>';
		}
	}, 'tagname');
	$p->parse($html);
	$p->eof;
	# a tag the article never closed is closed here
	while (@open) {
		my $closing = pop @open;
		$out .= '</' . $closing . '>';
	}
	return $out;
}

1;
