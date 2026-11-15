#!/usr/bin/perl
# Count the lines the house wrote, by language.
#
# This is the number to quote when somebody asks how big JawnOS is. It counts
# tracked files only - the worktrees, firmware .pio/build output, releases and
# the database can never be in it - and it keeps two things out of the table:
#
#   - code the house did not write (vendored jQuery, jQuery UI, Moment.js,
#     Numeral.js, the jQuery UI theme), and
#   - data that was generated rather than authored (font bitmaps, TFLite model
#     blobs, LVGL's lv_conf.h).
#
# Both are still weighed and printed under the table, so the exclusion stays
# visible; --all folds them back into their languages.
#
#   perl scripts/loc.pl                 # authored code, by language
#   perl scripts/loc.pl --json          # the same numbers, machine-readable
#   perl scripts/loc.pl --all           # count vendored and generated files too
#   perl scripts/loc.pl --root DIR      # count a tree on disk (a fixture)
#
# "Code" is a lexical count: a line carrying at least one character that is
# neither whitespace nor inside a comment. Comments are read per language -
# hash and POD for Perl, // and /* */ for the C family, triple quotes for
# Python, -- for SQL, ; for Inno Setup - and a line that is only a closing
# brace, a bracket or a lone template tag counts as code, the way cloc does.
#
# A new vendored file goes in %VENDOR with its reason; a new language goes in
# %LANGUAGE and %STYLE; an extension that is not code goes in %NONCODE with
# what it is. t/305-loc.t fails a tracked file that lands in no bucket, and one
# that lands in "not code" without a category - so a new asset type, or a
# language nobody counted, is a decision rather than an accident.
use strict;
use warnings;

use FindBin qw($RealBin);
use File::Find qw(find);
use File::Spec;
use Getopt::Long qw(GetOptions);
use JSON::PP ();

# extension => language. A file whose extension is not here is not code.
my %LANGUAGE = (
	pm  => 'Perl',
	pl  => 'Perl',
	t   => 'Perl',
	ep  => 'Perl (Mojo templates)',
	js  => 'JavaScript',
	css => 'CSS',
	py  => 'Python',
	ino => 'C/C++ (Arduino)',
	c   => 'C',
	h   => 'C/C++ header',
	sh  => 'Shell',
	sql => 'SQL',
	ps1 => 'PowerShell',
	iss => 'Inno Setup',
	PL  => 'Perl',
	mjs => 'JavaScript',
	bat => 'Batch',
);

# language => comment style, read by classify_line below.
my %STYLE = (
	'Perl'                  => 'pod',
	'Perl (Mojo templates)' => 'ep',
	'JavaScript'            => 'c',
	'CSS'                   => 'c',
	'C'                     => 'c',
	'C/C++ header'          => 'c',
	'C/C++ (Arduino)'       => 'c',
	'Python'                => 'python',
	'Shell'                 => 'hash',
	'SQL'                   => 'sql',
	'PowerShell'            => 'hash',
	'Inno Setup'            => 'iss',
	'Batch'                 => 'batch',
);

# interpreter => language, for whatever is tracked without an extension
# (jawn, the desktop launchers, the packaging wrappers, the git hooks).
my %SHEBANG = (
	perl   => 'Perl',
	python => 'Python',
	sh     => 'Shell',
	bash   => 'Shell',
	dash   => 'Shell',
	zsh    => 'Shell',
);

# Code the house did not write, or data generated rather than authored. The
# path is repo-relative; t/305-loc.t fails if one of them stops being tracked.
my %VENDOR = (
	'public/js/jquery.js'                    => 'jQuery 3.6.1 (minified)',
	'public/js/jquery-ui.js'                 => 'jQuery UI',
	'public/js/jquery.ui.touch-punch.min.js' => 'jQuery UI touch-punch (minified)',
	'public/js/moment.js'                    => 'Moment.js',
	'public/js/numeral.min.js'               => 'Numeral.js (minified)',
	'public/css/jquery-ui.css'               => 'jQuery UI theme',
	'jw/fonts/clock_font_72.c'               => 'generated bitmap: clock font',
	'jt/Latin_Hiragana_24.h'                 => 'generated bitmap: Latin/Hiragana font',
	'jt/NotoSansBold15.h'                    => 'generated bitmap: Noto Sans Bold 15',
	'jt/NotoSansBold36.h'                    => 'generated bitmap: Noto Sans Bold 36',
	'jt/Unicode_Test_72.h'                   => 'generated bitmap: Unicode test font',
	'jt/Final_Frontier_28.h'                 => 'generated bitmap: Final Frontier font',
	'jt/hey_jawn_model.h'                    => 'generated blob: wake-word model',
	'jw/hey_jawn_model.h'                    => 'generated blob: wake-word model',
	'jw/jawn_do_model.h'                     => 'generated blob: wake-word model',
	'jt/vad_model.h'                         => 'generated blob: VAD model',
	'jw/vad_model.h'                         => 'generated blob: VAD model',
	'jt/lv_conf.h'                           => 'LVGL configuration template',
	'jw/lv_conf.h'                           => 'LVGL configuration template',
);

# Extensions that are text even where -B would hesitate (a translated doc with
# an emoji, a certificate, a patch). Everything else is probed with -B.
my %TEXT = map { $_ => 1 } qw(
	md txt json yml yaml ini conf service timer svg xml patch desktop in
	iss bat csv env tmpfiles preset network os-release gitignore example
);

# Extensions that are deliberately not code, with what they are. The bucket is
# not a dumping ground: an extension missing from here is reported by --json as
# unknown and fails t/305-loc.t, so a new asset, document or data file is named
# here once instead of quietly lowering the count.
my %NONCODE = (
	# prose and notes
	md => 'docs', txt => 'docs', ipynb => 'docs', patch => 'docs',
	# configuration and packaging metadata
	json => 'config', yml => 'config', yaml => 'config', ini => 'config',
	conf => 'config', service => 'config', timer => 'config',
	network => 'config', preset => 'config', in => 'config',
	desktop => 'config', xml => 'config', gitignore => 'config',
	dockerignore => 'config', example => 'config', env => 'config',
	net => 'config', sysusers => 'config', tmpfiles => 'config',
	install => 'config', bash_profile => 'config',
	'lintian-overrides' => 'config',
	# images, audio and the vendored bitmap font format
	svg => 'assets', png => 'assets', jpg => 'assets', webp => 'assets',
	mp3 => 'assets', vlw => 'assets', xcf => 'assets', ico => 'assets',
	# the boot splash theme (its .script is not a shell script)
	plymouth => 'theme', script => 'theme',
	# data the app reads, not code it runs
	csv => 'data', jawn => 'data', enc => 'data',
	# no extension at all: licences, VERSION, PKGBUILD, debian/rules
	none => 'extensionless',
);

my %opt;
GetOptions(\%opt, 'json', 'all', 'root=s', 'help|h') or usage(2);
usage(0) if $opt{help};

my $root = $opt{root} ? File::Spec->rel2abs($opt{root}) : File::Spec->rel2abs("$RealBin/..");
$root =~ s{/+$}{};
$root = '/' unless length $root;
my $repo_mode = !defined $opt{root};

my @files = $repo_mode ? repo_files($root) : disk_files($root);

my (%by_language, %vendor_path);
my %other = (files => 0, lines => 0, binary => 0, ext => {});

for my $rel (@files) {
	my $path = "$root/$rel";
	my $reason = $VENDOR{$rel};
	$reason = "minified third-party build"
		if !defined $reason && $rel =~ /\.min\.(?:js|css)$/;
	undef $reason if $opt{all};
	my $language = language_for($root, $rel);

	if (defined $reason) {
		my $lines = count_lines($path);
		$vendor_path{$rel} = { path => $rel, reason => $reason, lines => $lines };
		next;
	}

	if (defined $language) {
		my ($lines, $blank, $comment, $code) = count_code($path, $STYLE{$language});
		my $row = $by_language{$language} ||= {
			language => $language, files => 0, lines => 0,
			blank => 0, comment => 0, code => 0,
		};
		$row->{files}++;
		$row->{lines} += $lines;
		$row->{blank} += $blank;
		$row->{comment} += $comment;
		$row->{code} += $code;
		next;
	}

	$other{files}++;
	my ($ext) = $rel =~ /\.([^.\/]+)$/;
	$ext = 'none' unless defined $ext;
	$other{ext}{$ext} ||= [0, 0];
	$other{ext}{$ext}[0]++;
	if ($TEXT{$ext} || !-B $path) {
		my $lines = count_lines($path);
		$other{lines} += $lines;
		$other{ext}{$ext}[1] += $lines;
	}
	else {
		$other{binary}++;
	}
}

my @rows = sort { $b->{code} <=> $a->{code} || $a->{language} cmp $b->{language} }
	values %by_language;
my %total = (files => 0, lines => 0, blank => 0, comment => 0, code => 0);
for my $row (@rows) {
	$total{$_} += $row->{$_} for keys %total;
}
my @vendor = sort { $a->{path} cmp $b->{path} } values %vendor_path;
my $vendor_lines = 0;
$vendor_lines += $_->{lines} for @vendor;

if ($opt{json}) {
	my $json = JSON::PP->new->canonical->pretty;
	print $json->encode({
		languages => [ map { { %$_ } } @rows ],
		total     => \%total,
		vendored  => {
			files => scalar @vendor,
			lines => $vendor_lines,
			paths => \@vendor,
		},
		not_counted => {
			files  => $other{files},
			lines  => $other{lines},
			binary => $other{binary},
			unknown => [ grep { !$NONCODE{$_} } sort keys %{ $other{ext} } ],
			by_extension => {
				map {
					$_ => {
						files    => $other{ext}{$_}[0],
						lines    => $other{ext}{$_}[1],
						category => $NONCODE{$_} // 'unclassified',
					}
				} sort keys %{ $other{ext} }
			},
		},
	});
	exit 0;
}

printf "%-34s %6s %9s %8s %8s %9s\n",
	'LANGUAGE', 'FILES', 'LINES', 'BLANK', 'COMMENT', 'CODE';
for my $row (@rows) {
	printf "%-34s %6d %9d %8d %8d %9d\n",
		$row->{language}, $row->{files}, $row->{lines},
		$row->{blank}, $row->{comment}, $row->{code};
}
printf "%-34s %6d %9d %8d %8d %9d\n", 'TOTAL', @total{qw(files lines blank comment code)};

print "\n";
if (@vendor) {
	printf "%d files / %s lines vendored or generated, not counted (--all folds them in)\n",
		scalar @vendor, commas($vendor_lines);
}
my @ext = sort { $other{ext}{$b}[1] <=> $other{ext}{$a}[1] || $a cmp $b }
	keys %{ $other{ext} };
my @unknown = grep { !$NONCODE{$_} } @ext;
print STDERR "loc: unclassified extension(s): @unknown"
	. " - add a language to %LANGUAGE or a category to %NONCODE\n"
	if @unknown;
splice(@ext, 5) if @ext > 5;
my @top = map { sprintf '%s (%d files)', $_, $other{ext}{$_}[0] } @ext;
printf "%d files / %s lines not code: %s\n",
	$other{files}, commas($other{lines}), (@top ? join(', ', @top) : 'none');

exit 0;

sub repo_files {
	my $root = shift;
	open(my $fh, '-|', 'git', '-C', $root, 'ls-files', '-z')
		or die "loc: cannot run git in $root: $!\n";
	local $/;
	my $raw = <$fh>;
	close $fh;
	die "loc: git ls-files failed in $root\n" if $?;
	my @files = grep { length } split /\0/, ($raw // '');
	return grep { -f "$root/$_" } @files;
}

sub disk_files {
	my $root = shift;
	my @files;
	find({
		no_chdir => 1,
		wanted   => sub {
			my $path = $File::Find::name;
			if (-d $path) {
				$File::Find::prune = 1 if $_ eq '.git';
				return;
			}
			return unless -f $path;
			(my $rel = $path) =~ s{^\Q$root\E/+}{};
			push @files, $rel;
		},
	}, $root);
	return sort @files;
}

sub language_for {
	my ($root, $rel) = @_;
	my ($ext) = $rel =~ /\.([^.\/]+)$/;
	return $LANGUAGE{$ext} if defined $ext && exists $LANGUAGE{$ext};

	# An extension nobody has mapped may still be a script - a Debian
	# maintainer script, a packaging wrapper - so the shebang decides.
	open(my $fh, '<', "$root/$rel") or return undef;
	my $first = <$fh>;
	close $fh;
	return undef unless defined $first && $first =~ /^#! *(\S+)(?: +(\S+))?/;

	my ($interp, $arg) = ($1, $2);
	$interp =~ s{.*/}{};
	if ($interp eq 'env' && defined $arg) {
		$interp = $arg;
		$interp =~ s{.*/}{};
	}
	$interp =~ s/[0-9.]+$// if $interp =~ /^python/;
	return $SHEBANG{$interp};
}

sub count_code {
	my ($path, $style) = @_;
	my ($lines, $blank, $comment, $code) = (0, 0, 0, 0);
	my $state = { block => 0, pod => 0, doc => '' };
	open(my $fh, '<', $path) or return (0, 0, 0, 0);
	while (defined(my $line = <$fh>)) {
		$lines++;
		$line =~ s/\r?\n\z//;
		$line =~ s/[ \t]+\z//;
		if ($line !~ /\S/) {
			$blank++;
			next;
		}
		if (classify_line($line, $state, $style) eq 'code') {
			$code++;
		}
		else {
			$comment++;
		}
	}
	close $fh;
	return ($lines, $blank, $comment, $code);
}

sub count_lines {
	my $path = shift;
	open(my $fh, '<', $path) or return 0;
	my ($count, $tail) = (0, '');
	while (read($fh, my $buf, 65536)) {
		$count += ($buf =~ tr/\n//);
		$tail = substr($buf, -1);
	}
	close $fh;
	$count++ if length $tail && $tail ne "\n";
	return $count;
}
sub classify_line {
	my ($line, $state, $style) = @_;

	if ($style eq 'c' || $style eq 'sql') {
		my $token = $style eq 'sql' ? '--' : '//';
		return classify_c($line, $state, $token);
	}

	if ($style eq 'pod') {
		if ($state->{pod}) {
			$state->{pod} = 0 if $line =~ /^=cut\b/;
			return 'comment';
		}
		if ($line =~ /^=\w/) {
			$state->{pod} = 1 unless $line =~ /^=cut\b/;
			return 'comment';
		}
		return $line =~ /^\s*#/ ? 'comment' : 'code';
	}

	if ($style eq 'ep') {
		return 'comment' if $line =~ /^\s*%#/;
		return 'comment' if $line =~ /^\s*<%#/;
		return $line =~ /^\s*#/ ? 'comment' : 'code';
	}

	if ($style eq 'python') {
		my $open = $state->{doc};
		if (length $open) {
			$state->{doc} = '' if $line =~ /\Q$open\E/;
			return 'comment';
		}
		if ($line =~ /^\s*[rRbBuU]{0,2}("""|''')/) {
			my $quote = $1;
			my $first = index($line, $quote);
			$state->{doc} = $quote if index($line, $quote, $first + 3) < 0;
			return 'comment';
		}
		return $line =~ /^\s*#/ ? 'comment' : 'code';
	}

	if ($style eq 'iss') {
		return $line =~ /^\s*;/ ? 'comment' : 'code';
	}

	if ($style eq 'batch') {
		return $line =~ /^\s*(?:rem\b|::)/i ? 'comment' : 'code';
	}

	return $line =~ /^\s*#/ ? 'comment' : 'code';
}

# Most lines hold no string and no block comment, so two index() calls answer
# them; only a line that can hide a marker behind a quote, or that carries a
# block comment, pays for the character scan in strip_comment.
sub classify_c {
	my ($line, $state, $token) = @_;
	my $rest = $line;

	if ($state->{block}) {
		my $end = index($line, '*/');
		return 'comment' if $end < 0;
		$state->{block} = 0;
		$rest = substr($line, $end + 2);
		return 'comment' if $rest !~ /\S/;
	}

	if ($rest !~ /["']/ && index($rest, '/*') < 0) {
		my $at = index($rest, $token);
		$rest = substr($rest, 0, $at) if $at >= 0;
		return $rest =~ /\S/ ? 'code' : 'comment';
	}

	my $visible = strip_comment($rest, $state, $token);
	return $visible =~ /\S/ ? 'code' : 'comment';
}

# Remove comments from one line, carrying block state across lines and leaving
# string literals alone, so a line that only looks like a comment is still code.
sub strip_comment {
	my ($line, $state, $token) = @_;
	my $rest = '';
	my $i = 0;
	my $len = length $line;
	my $quote = '';
	my $token_len = length $token;
	while ($i < $len) {
		if ($state->{block}) {
			my $end = index($line, '*/', $i);
			if ($end < 0) {
				$i = $len;
				last;
			}
			$i = $end + 2;
			$state->{block} = 0;
			next;
		}
		my $ch = substr($line, $i, 1);
		if (length $quote) {
			$rest .= $ch;
			if ($ch eq '\\' && $i + 1 < $len) {
				$rest .= substr($line, $i + 1, 1);
				$i += 2;
				next;
			}
			$quote = '' if $ch eq $quote;
			$i++;
			next;
		}
		if ($ch eq '"' || $ch eq "'") {
			$quote = $ch;
			$rest .= $ch;
			$i++;
			next;
		}
		if (substr($line, $i, 2) eq '/*') {
			$state->{block} = 1;
			$i += 2;
			next;
		}
		if (substr($line, $i, $token_len) eq $token) {
			$i = $len;
			last;
		}
		$rest .= $ch;
		$i++;
	}
	return $rest;
}

sub commas {
	my $number = shift;
	1 while $number =~ s/^(-?[0-9]+)([0-9]{3})/$1,$2/;
	return $number;
}

sub usage {
	my $code = defined $_[0] ? $_[0] : 0;
	print <<'USAGE';
usage: loc.pl [--json] [--all] [--root DIR]

  (no flag)   authored code by language, from the tracked tree
  --json      the same numbers, machine-readable
  --all       count vendored libraries and generated data too
  --root DIR  count a tree on disk instead of the tracked repo (a fixture)
USAGE
	exit $code;
}
