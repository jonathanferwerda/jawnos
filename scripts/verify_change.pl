#!/usr/bin/perl

# verify_change.pl - did a change break anything?
#
# Syntax-checks the files a change touched before they ship: Perl must compile
# (perl -c), JavaScript must parse (node --check, when node is present), a Mojo
# .ep template must compile the way Mojo::Template does, and JSON must decode.
# It also flags a file that lost more than half its length against the base
# commit: the coding agents write whole files, so a truncated write is the
# failure this catches - a 4,151-line manager.js once shipped as 1,008 lines and
# blanked /manager, and perl -c alone never looked at it (it was not Perl).
#
#   perl scripts/verify_change.pl                     # files the tree changed
#   perl scripts/verify_change.pl <file> [<file> ...] # named files
#   perl scripts/verify_change.pl --all               # every source file
#   perl scripts/verify_change.pl --range <a>..<b>    # the files a push changed
#   perl scripts/verify_change.pl --allow-shrink      # skip the truncation guard
#   perl scripts/verify_change.pl --quiet             # failures and summary only
#
# Exit 0 when every file passes, 1 when any file fails. scripts/verify_change.pl
# is what staged_fix_apply calls before it commits a coding agent's proposal, and
# .githooks/pre-push calls it before a push, so a broken file cannot ship.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Find ();

my $root = abs_path("$FindBin::Bin/..");

# node is the only exact JavaScript syntax checker we have; without it the JS
# parse is skipped (the truncation guard below still stands) rather than failed.
my $node = 0;
{
	my $p = `command -v node 2>/dev/null`;
	chomp $p if defined $p;
	$node = 1 if defined $p && length $p && -x $p;
}

my (@named, $all, $quiet, $allow_shrink, $range);
while (@ARGV) {
	my $a = shift @ARGV;
	if ($a eq '--all') { $all = 1 }
	elsif ($a eq '--quiet') { $quiet = 1 }
	elsif ($a eq '--allow-shrink') { $allow_shrink = 1 }
	elsif ($a eq '--range') { $range = shift @ARGV }
	elsif ($a =~ /^--/) { die "verify_change.pl: unknown option $a\n" }
	else { push @named, $a }
}

# --range checks the committed files a push advances (base -> tip); everything
# else checks the working tree. The base is what the truncation guard compares
# against, so both modes judge the change they are handed.
my ($base, $tip, $range_mode);
if (defined $range && $range =~ /^(\S+)\.\.(\S+)$/) {
	($base, $tip, $range_mode) = ($1, $2, 1);
}
$base = 'HEAD' unless defined $base;

sub rel_of {
	my $p = shift;
	$p =~ s/^\s+|\s+$//g;
	$p =~ s{^\./}{};
	return $p;
}

sub abs_of {
	my $rel = shift;
	return $rel if $rel =~ m{^/};
	return "$root/$rel";
}

sub read_text {
	my $abs = shift;
	return '' unless -f $abs;
	open(my $fh, '<', $abs) or return '';
	my $text = do { local $/; <$fh> };
	close $fh;
	return defined $text ? $text : '';
}

# A file's committed text at a revision, or undef when it is not there (a new
# file, an absolute temp path, or a shallow clone without the base).
sub git_blob {
	my ($rev, $rel) = @_;
	return undef if !defined $rev || $rel =~ m{^/};
	my $text = `cd "$root" && git --no-pager show "$rev:$rel" 2>/dev/null`;
	return undef if $? != 0;
	return $text;
}

# A file with the right extension for the compilers, outside the tree, holding
# text that only exists in git (so perl -c and node --check can still see it).
sub temp_for {
	my ($rel, $src) = @_;
	my $ext = ($rel =~ /\.([A-Za-z0-9]+)$/) ? lc $1 : '';
	require File::Temp;
	require File::Spec;
	my ($fh, $tmp) = File::Temp::tempfile('jawn_verify_XXXXXX',
		SUFFIX => ($ext ? ".$ext" : ''), DIR => File::Spec->tmpdir, UNLINK => 1);
	return undef unless $fh && $tmp;
	print $fh $src;
	close $fh;
	return $tmp;
}

sub first_line {
	my $text = shift;
	$text = '' unless defined $text;
	my @lines = grep { /\S/ } split /\n/, $text;
	return '' unless @lines;
	# prefer the sentence that names the fault over a bare "file:line" header
	my ($useful) = grep { /rror|FAIL|Cannot|Unexpected|syntax/ } @lines;
	my $line = defined $useful ? $useful : $lines[0];
	$line =~ s/^\s+|\s+$//g;
	return substr($line, 0, 300);
}

# A whole-file write that cut the file down is the signature failure, so flag it
# even though it is syntax-valid. Only text files with a git counterpart can be
# judged; a brand-new file, a binary, or a small file is left alone.
sub shrink_problem {
	my ($rel, $new_text) = @_;
	return '' if $allow_shrink;
	my $old = &git_blob($base, $rel);
	return '' unless defined $old && length $old;
	return '' if index($old, "\0") >= 0;            # binary
	my $old_lines = ($old =~ tr/\n//);
	return '' if $old_lines < 120;
	my $new_lines = (defined $new_text ? ($new_text =~ tr/\n//) : 0);
	return '' unless $new_lines < $old_lines * 0.5;
	return "shrank from $old_lines to $new_lines lines against $base - a truncated write?";
}

# What a file is, so it gets the right check: by extension, or - for an
# extension-less entry point like ./jawn - by its shebang.
sub source_kind {
	my ($rel, $src) = @_;
	my $ext = ($rel =~ /\.([A-Za-z0-9]+)$/) ? lc $1 : '';
	return 'perl' if $ext eq 'pl' || $ext eq 'pm' || $ext eq 't';
	return 'js'   if $ext eq 'js' || $ext eq 'mjs' || $ext eq 'cjs';
	return 'ep'   if $ext eq 'ep';
	return 'json' if $ext eq 'json';
	my ($first) = split /\n/, ($src // '');
	return 'perl' if defined $first && $first =~ /^#!.*\bperl\b/;
	return '';
}

sub check {
	my ($rel, $src, $path) = @_;
	my @probs;
	my $kind = &source_kind($rel, $src);

	if ($kind eq 'perl') {
		my $out = `cd "$root" && perl -c "$path" 2>&1`;
		$out = '' unless defined $out;
		unless ($out =~ /syntax OK/) {
			# an app fragment (hooks.pl) leans on the DSL and imports Manager.pl
			# brings in, so retry with them before calling it broken
			my $again = `cd "$root" && perl -Mfeature=signatures -MMojolicious::Lite -MMojo::JSON=decode_json,encode_json -c "$path" 2>&1`;
			$again = '' unless defined $again;
			push @probs, 'perl -c: ' . &first_line($out) unless $again =~ /syntax OK/;
		}
	}
	elsif ($kind eq 'js') {
		if ($node) {
			my $out = `cd "$root" && node --check "$path" 2>&1`;
			my $code = $? >> 8;
			$out = '' unless defined $out;
			push @probs, 'node --check: ' . &first_line($out) if $code != 0;
		}
	}
	elsif ($kind eq 'ep') {
		my $ok = eval {
			require Mojo::Template;
			Mojo::Template->new(vars => 1)->name($rel)->parse($src);
			1;
		};
		push @probs, 'ep compile: ' . &first_line("$@") unless $ok;
	}
	elsif ($kind eq 'json') {
		my $ok = eval { require Mojo::JSON; Mojo::JSON::decode_json($src); 1 };
		push @probs, 'json: ' . &first_line("$@") unless $ok;
	}

	my $shrink = &shrink_problem($rel, $src);
	push @probs, $shrink if length $shrink;
	return @probs;
}

sub collect_files {
	return @named if @named;
	if ($range_mode) {
		my @f = split /\n/, `cd "$root" && git -c core.quotepath=0 diff --name-only --diff-filter=ACMR $range 2>/dev/null`;
		return map { rel_of($_) } @f;
	}
	if ($all) {
		my @f;
		File::Find::find({
			no_chdir => 1,
			wanted => sub {
				my $p = $File::Find::name;
				return if $p =~ m{(?:^|/)(?:\.git|\.shots|node_modules|\.pio|build|releases|__pycache__)(?:/|$)};
				return unless -f $p;
				my $rel = $p;
				$rel =~ s{^\Q$root/\E}{};
				return if $rel =~ m{(?:^|/)\.};
				my $known = $rel =~ /\.(?:pl|pm|t|js|mjs|cjs|ep|json)$/;
				# an extension-less entry point (./jawn) or a scripts/ tool is judged
				# by its shebang in check()
				my $tool = $rel =~ m{^(?:[^/]+|scripts/[^/]+)$} && $rel !~ m{\.[^./]+$};
				return unless $known || $tool;
				push @f, $rel;
			},
		}, $root);
		return @f;
	}
	my @f;
	foreach my $line (split /\n/, `cd "$root" && git -c core.quotepath=0 status --porcelain 2>/dev/null`) {
		next unless length $line;
		my $path = substr($line, 3);
		if ($path =~ / -> /) { ($path) = $path =~ / -> (.*)$/; }
		$path =~ s/^"(.*)"$/$1/;
		push @f, $path;
	}
	return @f;
}

my %seen;
my @files = sort grep { length && !$seen{$_}++ } map { rel_of($_) } &collect_files();

my (@passed, @failed, @skipped, $checked);
foreach my $rel (@files) {
	my ($src, $path, $temp);
	if ($range_mode) {
		$src = &git_blob($tip, $rel);
		unless (defined $src) { push @skipped, $rel; next; }
		$path = $temp = &temp_for($rel, $src);
		unless (defined $path) { push @skipped, $rel; next; }
	}
	else {
		my $abs = &abs_of($rel);
		unless (-f $abs) { push @skipped, $rel; next; }
		$src = &read_text($abs);
		$path = $abs;
	}
	$checked++;
	my @probs = &check($rel, $src, $path);
	unlink $temp if defined $temp;
	if (@probs) { push @failed, [ $rel, \@probs ] }
	else { push @passed, $rel }
}

if (!$quiet) {
	print "ok    $_\n" foreach @passed;
	print "skip  $_ (not present)\n" foreach @skipped;
	print "skip  JavaScript parse skipped - node is not installed\n"
		if !$node && grep { /\.(?:js|mjs|cjs)$/ } @files;
}

foreach my $f (@failed) {
	print "FAIL  $f->[0]\n";
	print "        $_\n" foreach @{ $f->[1] };
}

if (@failed) {
	print sprintf("verify_change: %d of %d file(s) FAILED (%s)\n",
		scalar @failed, $checked, $range_mode ? "$base..$tip" : "base $base");
	exit 1;
}
print sprintf("verify_change: %d file(s) pass (%s)%s\n",
	$checked, $range_mode ? "$base..$tip" : "base $base",
	$node ? '' : ' - JavaScript not checked (node missing)');
exit 0;
