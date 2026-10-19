#!/usr/bin/perl
#
# i18n_extract.pl - collect every translatable string the running app can show.
#
#   perl scripts/i18n_extract.pl [--out i18n/strings.json]
#
# Sources:
#   - help.pl: every topic title, summary, body paragraph and step.
#   - templates/**/*.ep: text nodes and the user-visible attributes hint,
#     placeholder, title, alt and aria-label (script/style and <% %> code are
#     skipped).
#   - public/js/manager/*.js and public/js/*.js: literals passed to .text(),
#     .html(), .append(), .prepend(), .before(), .after(), the visible .attr()
#     names, and alert/confirm/prompt.
#
# The output is the source of truth for scripts/i18n_translate.pl. Running the
# extractor is safe and idempotent; it never writes into the app tree.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use Cwd ();
use Getopt::Long qw(GetOptions);
use Mojo::JSON qw(encode_json decode_json);
use JSON::PP ();
use Mojo::Util qw(html_unescape);
use File::Slurp qw(read_file write_file);
use Encode qw(decode);
use HTML::Parser;
use File::Find;

my $root = Cwd::abs_path("$Bin/..");
chdir $root or die "cannot chdir to $root: $!\n";
require "./language.pl";
require "./help.pl";
no warnings 'once';

my $out_file = 'i18n/strings.json';
GetOptions( 'out=s' => \$out_file ) or die "bad options\n";

my %strings;
my %source;

sub add {
	my ( $text, $where ) = @_;
	return unless defined $text;
	# help.pl is loaded as Perl source without `use utf8`, so its literals are
	# UTF-8 bytes. Decode them once; template and JS sources are already decoded.
	$text = decode('UTF-8', $text) unless utf8::is_utf8($text);
	$text = html_unescape($text);
	$text =~ s/\x{00a0}/ /g;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return unless length $text;
	return unless $text =~ /\p{L}/;
	return if length($text) > 4000;
	# code and markup fragments are never labels
	return if $text =~ /<%|%>|&subs::/;
	return if $text =~ /=>|\bfunction\s*\(|===|!==|\|\||&&/;
	return if $text =~ /['"]\s*\+|\+\s*['"]/;
	return if $text =~ m{^\s*['"]};
	return if $text =~ m{^\s*<[a-z!/]}i;
	return if $text =~ m{</|/>|<(?:div|span|img|a|p|br|td|th|tr|table|script|style)\b}i;
	return if $text =~ /\{[^}]*\}/ && $text !~ /\{\d+\}/ && length($text) < 200;
	my $letters = () = $text =~ /\p{L}/g;
	return if $letters < 2;
	my $bad = () = $text =~ /[{}<>;=\[\]\\|]/g;
	return if length($text) > 20 && ($bad / length($text)) > 0.08;
	return if $text =~ /^[A-Za-z_-]+=/;
	return if $text =~ /^\s*[,;:.\-]/;
	return if $text =~ /[,;:\-]\s*$/;
	return if $text =~ /\s[,;]\s/;
	return if $text =~ m{^\s*(?:https?://|/|#|\$|%|\{|\}|\[|\]|\.|@|!|//)};
	return if $text =~ /^[A-Za-z_][A-Za-z0-9_]*\([^)]*\)$/;
	return if $text =~ /^[\W_]+$/;
	$strings{$text} = 1;
	$source{$text}->{$where} = 1;
}

# ---------------------------------------------------------------------------
# help.pl
# ---------------------------------------------------------------------------
foreach my $id ( keys %help::topic ) {
	my $t = $help::topic{$id};
	next unless ref $t eq 'HASH';
	add( $t->{'title'},   "help:$id:title" )   if defined $t->{'title'};
	add( $t->{'summary'}, "help:$id:summary" ) if defined $t->{'summary'};
	foreach my $p ( @{ $t->{'body'} || [] } ) {
		add( $p, "help:$id:body" );
	}
	foreach my $s ( @{ $t->{'steps'} || [] } ) {
		add( $s, "help:$id:step" );
	}
}

# ---------------------------------------------------------------------------
# templates
# ---------------------------------------------------------------------------
my @templates;
find(
	{ no_chdir => 1, wanted => sub { push @templates, $_ if /\.ep$/ } },
	'templates'
);

my $ATTR = { hint => 1, placeholder => 1, title => 1, alt => 1, 'aria-label' => 1 };
foreach my $file ( sort @templates ) {
	my $src = eval { read_file($file) } // next;
	$src = decode('UTF-8', $src) unless utf8::is_utf8($src);
	# Template directives are code, not text. Replace them with a space so an
	# element's opening and closing tags remain separate.
	$src =~ s/<%.*?%>/ /gs;
	my $skip = 0;
	my $parser = HTML::Parser->new(
		api_version => 3,
		handlers => {
			start => [ sub {
				my ( $tag, $attr ) = @_;
				$skip++ if $tag eq 'script' || $tag eq 'style' || $tag eq 'pre' || $tag eq 'code';
				foreach my $a ( keys %{$ATTR} ) {
					next unless defined $attr->{$a} && length $attr->{$a};
					add( $attr->{$a}, "$file\@$a" );
				}
			}, 'tagname,attr' ],
			end => [ sub {
				my ($tag) = @_;
				$skip-- if ($tag eq 'script' || $tag eq 'style' || $tag eq 'pre' || $tag eq 'code') && $skip > 0;
			}, 'tagname' ],
			text => [ sub {
				my ($text) = @_;
				add( $text, $file ) unless $skip;
			}, 'text' ],
		},
	);
	$parser->parse($src);
	$parser->eof;
}

# ---------------------------------------------------------------------------
# JavaScript
# ---------------------------------------------------------------------------
sub js_add {
	my ( $text, $where ) = @_;
	return unless defined $text;
	# decode the common escapes a JS literal carries
	$text =~ s/\\n/ /g;
	$text =~ s/\\t/ /g;
	$text =~ s/\\r/ /g;
	$text =~ s/\\(['"\\])/$1/g;
	# the capture can run past a closing quote into a concatenation; those
	# fragments are code, not a label
	return if $text =~ m{^<};
	return if $text =~ /formData|data\.append|\.append\(|\.attr\(|\$\(|\);|\}\)/;
	return if $text =~ /['"]\s*,\s*['"]/;
	return if $text =~ /['"]\s*$/;
	return if $text =~ /\b(?:var|let|const|return|function)\b\s*[\(\[A-Za-z_\$]/;
	return if $text =~ /=>|===|!==|\|\||&&|\\/;
	add( $text, $where );
}

my @js_files;
find(
	{ no_chdir => 1, wanted => sub {
		return unless /\.js$/;
		# App-owned scripts only. jquery/moment/numeral and the other vendored
		# libraries carry their own English internals, which are not our labels.
		return if m{/(?:jquery|moment|numeral|touch-threshold)[^/]*\.js$};
		return unless m{public/js/manager/} || m{public/js/(?:homepage|store|mailbox|paperboy|music|images|universal|device|gate)\.js$};
		push @js_files, $_;
	} },
	'public/js'
);
foreach my $file ( sort @js_files ) {
	my $src = eval { read_file($file) } // next;
	$src = decode('UTF-8', $src) unless utf8::is_utf8($src);
	while ( $src =~ /\.(?:text|html|append|prepend|before|after)\(\s*(['"])(.*?)\1\s*\)/gs ) {
		js_add( $2, "$file:jquery" );
	}
	while ( $src =~ /\.attr\(\s*(['"])(?:hint|placeholder|title|alt|aria-label)\1\s*,\s*(['"])(.*?)\2\s*\)/gs ) {
		js_add( $3, "$file:attr" );
	}
	while ( $src =~ /\b(?:alert|confirm|prompt)\(\s*(['"])(.*?)\1/gs ) {
		js_add( $2, "$file:dialog" );
	}
}

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
my @ordered = sort { lc($a) cmp lc($b) } keys %strings;
my @items;
foreach my $s (@ordered) {
	push @items, {
		text    => $s,
		sources => [ sort keys %{ $source{$s} || {} } ],
	};
}

my $data = {
	generated => scalar( localtime() ),
	languages => [ map { $_->{'code'} } @language::languages ],
	count     => scalar(@items),
	strings   => \@items,
};

my $dir = $out_file;
$dir =~ s{/[^/]+$}{};
`mkdir -p $dir` if length $dir && !-d $dir;
write_file( $out_file, JSON::PP->new->canonical->pretty->utf8->encode($data) );

print "i18n_extract: " . scalar(@items) . " unique strings -> $out_file\n";
print "  help:      " . scalar( grep { /^help:/ } map { keys %{ $source{$_} } } keys %source ) . " source strings\n";
print "  templates: " . scalar( grep { !/^help:|:jquery|:attr|:dialog/ } map { keys %{ $source{$_} } } keys %source ) . " source strings\n";
print "  script:    " . scalar( grep { /:jquery|:attr|:dialog/ } map { keys %{ $source{$_} } } keys %source ) . " source strings\n";

1;
