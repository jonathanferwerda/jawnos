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
#   perl scripts/verify_change.pl --all --manifest <path>  # ... re-checking only
#                                                     # the files whose bytes moved
#   perl scripts/verify_change.pl --range <a>..<b>    # the files a push changed
#   perl scripts/verify_change.pl --allow-shrink      # skip the truncation guard
#   perl scripts/verify_change.pl --quiet             # failures and summary only
#
# --manifest is the restart guard's fast path (see ./jawn's tree_verify): a full
# sweep is ~744 compiler spawns and a git show each, ~90s on a laptop, and it sits
# on the critical path of every restart. A file's verdict only changes when its
# bytes change, so the manifest records the sha256 of every file that last passed
# and a later run re-checks only the files whose content moved. Content-keyed, not
# mtime-keyed: a checkout back to an already-verified state is a hit too. It only
# writes a manifest when the whole run passes, so a failure is never cached.
#
# Every external command (git, perl, node) is run from an argv list through
# IPC::Open3, never through a shell. The restart guard runs this script on the
# Windows machines too, where the Unix idioms - a null-device redirect, a shell
# builtin lookup, `cd ... &&` - are not things cmd.exe understands and every
# check failed with "The system cannot find the path specified."
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
#
# The lookup is a PATH scan done in-process. Asking the shell where a tool lives
# is a POSIX builtin, so under cmd.exe it is not a command at all - the reason a
# machine that only needed the JS check skipped refused every restart instead.
# JawnOS::Platform::tool_path already answers this for every platform (it adds
# .exe/.bat/.cmd on MSWin32); a copy of this script run from a tree without lib/
# - the tests copy it into a temp repo - falls back to the same scan here.
use lib "$FindBin::Bin/../lib";
my ($node, $node_bin) = (0, undef);
{
	my $found = eval {
		require JawnOS::Platform;
		JawnOS::Platform::tool_path('node');
	};
	if (!defined $found || !length $found) {
		require File::Spec;
		my @names = ('node');
		if ($^O eq 'MSWin32') {
			my @ext = split /;/, (defined $ENV{PATHEXT} && length $ENV{PATHEXT})
				? $ENV{PATHEXT} : '.EXE;.BAT;.CMD';
			push @names, map { 'node' . $_ } grep { length } @ext;
		}
		foreach my $dir (File::Spec->path) {
			next unless defined $dir && length $dir;
			foreach my $name (@names) {
				my $abs = File::Spec->catfile($dir, $name);
				next unless -f $abs && -x $abs;
				$found = $abs;
				last;
			}
			last if defined $found && length $found;
		}
	}
	if (defined $found && length $found && -x $found) {
		$node = 1;
		$node_bin = $found;
	}
}

my (@named, $all, $quiet, $allow_shrink, $range, $manifest);
while (@ARGV) {
	my $a = shift @ARGV;
	if ($a eq '--all') { $all = 1 }
	elsif ($a eq '--quiet') { $quiet = 1 }
	elsif ($a eq '--allow-shrink') { $allow_shrink = 1 }
	elsif ($a eq '--range') { $range = shift @ARGV }
	elsif ($a eq '--manifest') { $manifest = shift @ARGV }
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

# Run a command from an argv list - never through a shell - and collect its
# stdout and stderr. IPC::Open3 is core, and given more than one argument it
# execs the program directly on every platform (under cmd.exe as well), so a
# path or a flag is never re-parsed as shell syntax. Both streams are read:
# `perl -c` prints its verdict, and its syntax errors, on stderr, and the report
# quotes them. Returns ($text, $exit_code) with stdout first, then stderr; a
# signalled child reports 128 + the signal.
#
# The child writes to real files, not pipes. On Windows `select` only works on
# sockets, so an anonymous-pipe pair wrapped in IO::Select->can_read is never
# reported ready and the guard waits forever; the lost stderr then made check()
# fall through to the -M retry, which hung the same way. A temp file needs no
# readiness check: the child exits, and we seek back and read it. IPC::Open3
# builds a pipe for any handle it is merely given, so the redirections are
# written as the documented '<&N'/'>&N' descriptor dups of our files.
sub run_capture {
	require IPC::Open3;
	require File::Temp;
	require File::Spec;
	my ($out_fh) = File::Temp::tempfile('jawn_verify_out_XXXXXX',
		TMPDIR => 1, UNLINK => 1);
	my ($err_fh) = File::Temp::tempfile('jawn_verify_err_XXXXXX',
		TMPDIR => 1, UNLINK => 1);
	open(my $devnull, '<', File::Spec->devnull)
		or return ('could not open ' . File::Spec->devnull . ": $!\n", 127);
	my $pid = eval {
		IPC::Open3::open3('<&' . fileno($devnull),
			'>&' . fileno($out_fh), '>&' . fileno($err_fh), @_)
	};
	unless ($pid) {
		my $why = $@ || 'could not start';
		$why =~ s/\s+\z//;
		return ("$why\n", 127);
	}
	close $devnull;
	waitpid($pid, 0);
	my $status = $?;
	my $code = ($status & 127) ? 128 + ($status & 127) : ($status >> 8);
	my $text = '';
	foreach my $fh ($out_fh, $err_fh) {
		seek($fh, 0, 0);
		local $/;
		my $chunk = <$fh>;
		$text .= $chunk if defined $chunk;
		close $fh;
	}
	return ($text, $code);
}

# --- the verification manifest ---------------------------------------------
# Bump the version when the CHECK changes, not the format: a verdict recorded by
# an older checker is not evidence for a newer one, and a bump discards every old
# manifest (a full sweep, the once).
my $manifest_version = 1;

sub sha_of {
	require Digest::SHA;
	return Digest::SHA::sha256_hex(defined $_[0] ? $_[0] : '');
}

# path => [ verdict, sha256 ] for files this machine has already judged. Anything
# unreadable, foreign, or from a different manifest version yields () - a full
# sweep is always the safe answer.
sub load_manifest {
	my $path = shift;
	return () unless defined $path && length $path && -f $path;
	open(my $fh, '<', $path) or return ();
	my $head = <$fh>;
	unless (defined $head && $head =~ /^# jawnos verify manifest ([0-9]+)\s*$/) { close $fh; return () }
	unless ($1 == $manifest_version) { close $fh; return () }
	my $flag = <$fh>;
	unless (defined $flag && $flag =~ /^# node=([01])\s*$/) { close $fh; return () }
	# A JS file "passed" on a machine without node only by skipping its parse;
	# install node and every one of them needs the real check. Anything added to
	# the environment since is then judged the strict way.
	unless ($1 == $node) { close $fh; return () }
	my %entries;
	while (my $line = <$fh>) {
		chomp $line;
		next unless length $line;
		my ($verdict, $sha, $rel) = split /\t/, $line, 3;
		next unless defined $rel && defined $sha && length $rel;
		next unless $verdict eq 'ok' || $verdict eq 'skip';
		$entries{$rel} = [ $verdict, $sha ];
	}
	close $fh;
	return %entries;
}

# Written to a sibling temp file and renamed, so a run killed mid-write leaves the
# previous manifest intact rather than a half file that reads as "all changed".
sub save_manifest {
	my ($path, $entries) = @_;
	return unless defined $path && length $path;
	my $tmp = "$path.tmp.$$";
	open(my $fh, '>', $tmp) or return;
	print $fh "# jawnos verify manifest $manifest_version\n";
	print $fh '# node=' . $node . "\n";
	print $fh join("\t", @{$_}), "\n" foreach @$entries;
	close $fh;
	rename($tmp, $path) or unlink $tmp;
	return;
}

# A file's committed text at a revision, or undef when it is not there (a new
# file, an absolute temp path, or a shallow clone without the base).
sub git_blob {
	my ($rev, $rel) = @_;
	return undef if !defined $rev || $rel =~ m{^/};
	my ($text, $code) = &run_capture('git', '-C', $root, '--no-pager', 'show', "$rev:$rel");
	return undef if $code != 0;
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
#
# A refactor is the one legitimate big shrink: the content moved into new files.
# So a shrink whose lost lines are covered by files this same change adds is a
# move, not a truncated write, and passes. A doc cleanup is the other: when the
# lines that went are only whole comments and blanks, every line of code is
# still there, so there is nothing to truncate.
sub code_lines {
	my ($text) = @_;
	return join '', grep { !/^\s*$/ && !/^\s*(?:#|\/\/)/ } split /(?<=\n)/, $text;
}
my $added_lines;
sub added_lines {
	return $added_lines if defined $added_lines;
	my ($range_added) = &run_capture('git', '-C', $root, '--no-pager',
		'diff', '--name-only', '--diff-filter=A', "$base..$tip");
	my ($untracked) = &run_capture('git', '-C', $root, '--no-pager',
		'ls-files', '--others', '--exclude-standard');
	my ($staged) = &run_capture('git', '-C', $root, '--no-pager',
		'diff', '--cached', '--name-only', '--diff-filter=A');
	my @added = $range_mode
		? map { &rel_of($_) } split /\n/, $range_added
		: (map { &rel_of($_) } split /\n/, $untracked),
		  (map { &rel_of($_) } split /\n/, $staged);
	$added_lines = 0;
	for my $rel (@added) {
		next unless length $rel;
		my $text = $range_mode ? (&git_blob($tip, $rel) // '') : &read_text("$root/$rel");
		next unless defined $text && length $text && index($text, "\0") < 0;
		$added_lines += ($text =~ tr/\n//);
	}
	return $added_lines;
}

sub shrink_problem {
	my ($rel, $new_text) = @_;
	return '' if $allow_shrink;
	my $old = &git_blob($base, $rel);
	return '' unless defined $old && length $old;
	return '' if index($old, "\0") >= 0;            # binary
	my $old_lines = ($old =~ tr/\n//);
	return '' if $old_lines < 120;
	return '' if defined $new_text && &code_lines($old) eq &code_lines($new_text);
	my $new_lines = (defined $new_text ? ($new_text =~ tr/\n//) : 0);
	return '' unless $new_lines < $old_lines * 0.5;
	return '' if &added_lines >= $old_lines - $new_lines;
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

# A file that will not compile only because a CPAN module is not installed on
# THIS machine is an environment gap, not a broken file. perl -c stops at the
# missing use, so the rest of the file is never seen; treating that as a failure
# is what wedged a machine on old code while its checkout was current - the
# restart guard in ./jawn runs `verify_change.pl --all`, saw pen.pl fail for a
# missing WebService::Ollama, refused every restart, and the tree kept serving
# the version it booted hours earlier (2026-10-16). In --all mode (the whole-tree
# check the guard runs, where any machine's env gaps are expected) such a file is
# reported as a skip, the way the JavaScript parse is skipped when node is absent.
# A named or --range check judges a change, so it stays strict.
my @dep_skips;
sub missing_module_name {
	my $t = shift;
	return undef unless defined $t;
	return $1 if $t =~ /Can't locate (\S+)\.pm in \@INC/;
	return undef;
}
sub missing_module { return defined &missing_module_name($_[0]) ? 1 : 0; }

sub check {
	my ($rel, $src, $path) = @_;
	my @probs;
	my $kind = &source_kind($rel, $src);

	if ($kind eq 'perl') {
		# -I$root/lib is what `cd $root && perl -Ilib` meant: the app's own
		# modules resolve the same from any working directory.
		my ($out) = &run_capture($^X, '-I' . "$root/lib", '-c', $path);
		$out = '' unless defined $out;
		unless ($out =~ /syntax OK/) {
			# an app fragment (hooks.pl) leans on the DSL and imports Manager.pl
			# brings in, so retry with them before calling it broken
			my ($again) = &run_capture($^X, '-I' . "$root/lib", '-Mfeature=signatures',
				'-MMojolicious::Lite', '-MMojo::JSON=decode_json,encode_json', '-c', $path);
			$again = '' unless defined $again;
			unless ($again =~ /syntax OK/) {
				my $missing = &missing_module_name($out);
				$missing = &missing_module_name($again) unless defined $missing;
				if ($all && &missing_module($out) && $out !~ /syntax error/i) {
					push @dep_skips, $rel;
				}
				elsif (defined $missing && $out !~ /syntax error/i && $again !~ /syntax error/i) {
					# A module the machine does not have stops the compile before the
					# file is judged; say which side of the fence this is, so nobody
					# rewrites good code because the hook's Perl lacked a library.
					push @probs, "perl -c: cannot load $missing (install it; this is the hook's environment, not the code)";
				}
				else {
					push @probs, 'perl -c: ' . &first_line($out);
				}
			}
		}
	}
	elsif ($kind eq 'js') {
		if ($node) {
			my ($out, $code) = &run_capture($node_bin, '--check', $path);
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
		my ($out) = &run_capture('git', '-C', $root, '-c', 'core.quotepath=0',
			'diff', '--name-only', '--diff-filter=ACMR', $range);
		return map { rel_of($_) } split /\n/, $out;
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
	my ($out) = &run_capture('git', '-C', $root, '-c', 'core.quotepath=0', 'status', '--porcelain');
	my @f;
	foreach my $line (split /\n/, $out) {
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

# The manifest only describes the working tree, so a --range run (which judges
# blobs from git) never reads or writes one.
my $manifest_mode = (defined $manifest && $all && !$range_mode) ? 1 : 0;
my %cached = $manifest_mode ? &load_manifest($manifest) : ();

my (@passed, @failed, @skipped, @entries);
my ($checked, $unchanged) = (0, 0);
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
	# Same bytes this machine already judged -> no compiler to spawn. Reuse the
	# earlier verdict ("ok", or "skip" for a file this box lacks a CPAN module for).
	my $sha = $manifest_mode ? &sha_of($src) : undef;
	if ($manifest_mode && defined $cached{$rel} && $cached{$rel}->[1] eq $sha) {
		$checked++;
		$unchanged++;
		push @entries, [ $cached{$rel}->[0], $sha, $rel ];
		next;
	}
	my $deps_before = scalar @dep_skips;
	my @probs = &check($rel, $src, $path);
	unlink $temp if defined $temp;
	if (@probs) { $checked++; push @failed, [ $rel, \@probs ] }
	elsif (scalar @dep_skips > $deps_before) {
		# an env gap, reported from @dep_skips; remembering it keeps the file
		# from costing a perl -c on every restart of a machine that lacks it
		push @entries, [ 'skip', $sha, $rel ] if $manifest_mode;
	}
	else {
		$checked++;
		push @passed, $rel;
		push @entries, [ 'ok', $sha, $rel ] if $manifest_mode;
	}
}

# Only a run that judged every file is worth remembering: a failure leaves the
# previous manifest in place, so the broken file is re-examined next time.
&save_manifest($manifest, [ sort { $a->[2] cmp $b->[2] } @entries ])
	if $manifest_mode && !@failed;

if (!$quiet) {
	print "ok    $_\n" foreach @passed;
	print "skip  $_ (not present)\n" foreach @skipped;
	print "skip  $_ (a CPAN module is not installed here)\n" foreach @dep_skips;
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
print sprintf("verify_change: %d file(s) pass (%s%s)%s\n",
	$checked, $range_mode ? "$base..$tip" : "base $base",
	($manifest_mode && $unchanged) ? "; $unchanged unchanged from the last verified run" : '',
	$node ? '' : ' - JavaScript not checked (node missing)');
exit 0;
