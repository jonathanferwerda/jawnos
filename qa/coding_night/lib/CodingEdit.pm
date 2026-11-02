package CodingEdit;

# The 06:00 agent's hands. A model reply becomes either whole files or a
# unified diff; this module decides which of those it may touch and how.
#
# The fence is not a suggestion to the model, it is enforced here:
#   - a path must be repository-relative and stay inside the worktree, with no
#     "..", no absolute path, no symlink and no control character;
#   - .git, .secrets, .shots, .president, releases, signatorials, database
#     files, config.json, downloads.json and *.pem are never written;
#   - binary files (by extension or by a NUL byte) are refused;
#   - at most $MAX_CHANGED_BYTES of new content across the whole run.
#
# A turn is all-or-nothing: every edit is validated and staged before the first
# rename, so a refused turn leaves the worktree exactly as it was. The nightly's
# commit is `git add -A`, so a partial turn would be a partial commit.

use strict;
use warnings;

use Cwd qw(abs_path);
use Encode ();
use File::Path qw(make_path);
use File::Spec ();
use File::Temp ();
use IO::Select;
use IPC::Open3;
use JSON::PP ();
use Symbol qw(gensym);

our $VERSION = '2';

# Total new bytes the agent may write, across every turn. 256 KB is several
# times the size of any one change this nightly should be making.
our $MAX_CHANGED_BYTES = 256 * 1024;

# A reply is a JSON object or a patch, never a document. 64 KB is generous for
# either and small enough that a runaway (or a truncated provider stream that
# repeats itself) cannot become the turn. Over the cap is a failed turn, not an
# applied edit: nothing is parsed and nothing is written.
our $MAX_REPLY_BYTES = 64 * 1024;

our %BINARY_EXT = map { $_ => 1 } qw(
	png jpg jpeg gif webp bmp ico tif tiff psd
	pdf zip gz tgz bz2 xz 7z rar tar
	apk aab jar class db sqlite sqlite3 bin hex elf so dylib dll exe o a
	p12 pfx der pem key jks keystore
	woff woff2 ttf otf eot
	mp3 mp4 m4a wav ogg oga opus flac avi mov mkv webm wmv iso dmg img
);

# Top-level trees the agent never writes. `.shots` is every agent's scratch
# space; `.president` is the master's sockets and verdicts.
our $PROTECTED_TOP = qr{^(?:\.git|\.secrets|\.shots|\.president|releases|signatorials|voices)(?:/|$)};

sub max_changed_bytes { return $MAX_CHANGED_BYTES }
sub max_reply_bytes { return $MAX_REPLY_BYTES }

# The reply's size in UTF-8 bytes, the unit the cap and the log use.
sub reply_bytes {
	my ($text) = @_;
	return 0 unless defined $text;
	return length Encode::encode('UTF-8', $text);
}

# The reason a repository-relative path may not be written, or undef. Separate
# from resolve() so a test can ask about a path with no worktree on disk.
sub deny_reason {
	my ($rel) = @_;
	return 'no path was given' unless defined $rel && length $rel;
	$rel =~ s/^\s+|\s+$//g;
	return 'no path was given' unless length $rel;
	return 'an absolute path' if $rel =~ m{^(?:/|[A-Za-z]:[\\/]|~)};
	return 'a control character' if $rel =~ /[\x00-\x1f\x7f]/;
	return 'a backslash path' if $rel =~ /\\/;
	my $clean = $rel;
	$clean =~ s{^\./+}{};
	$clean =~ s{/+$}{};
	$clean =~ s{//+}{/}g;
	return 'an empty path' unless length $clean;
	return 'a parent-directory reference' if $clean =~ m{(?:^|/)\.\.(?:/|$)};
	return 'a protected path (.git, .secrets, .shots, .president, releases, ...)'
		if $clean =~ $PROTECTED_TOP;
	return 'config.json is not the agent\'s to write' if $clean eq 'config.json';
	return 'downloads.json is not the agent\'s to write' if $clean eq 'downloads.json';
	return 'a database file' if $clean =~ m{^database/(?:.*\.db(?:$|[-.])|initial\.enc$|backups/)}i;
	return 'a private key' if $clean =~ /\.pem$/i;
	if ($clean =~ /\.([A-Za-z0-9]+)$/ && $BINARY_EXT{lc $1}) {
		return 'a binary file';
	}
	return undef;
}

sub _inside {
	my ($root, $abs) = @_;
	return 0 unless defined $root && defined $abs && length $root;
	return 1 if $abs eq $root;
	return index($abs, "$root/") == 0;
}

# The absolute path a relative edit may be written to, or (undef, reason).
sub resolve {
	my ($root, $rel) = @_;
	$root = abs_path($root) if defined $root && length $root;
	return (undef, 'the worktree root is not a directory') unless defined $root && -d $root;
	my $reason = deny_reason($rel);
	return (undef, $reason) if $reason;
	my $clean = $rel;
	$clean =~ s/^\s+|\s+$//g;
	$clean =~ s{^\./+}{};
	$clean =~ s{/+$}{};
	$clean =~ s{//+}{/}g;
	$reason = deny_reason($clean);
	return (undef, $reason) if $reason;
	my $abs = "$root/$clean";
	return (undef, 'a path outside the worktree') unless _inside($root, $abs);

	# Walk the existing prefix: a symlinked directory (or a symlink at the
	# target) could put a write anywhere. The in-memory path check alone does
	# not catch that, so every existing component is resolved for real.
	my @parts = split m{/}, $clean;
	my $walk = $root;
	for my $part (@parts) {
		$walk .= '/' . $part;
		last unless -e $walk || -l $walk;
		return (undef, 'a symlink') if -l $walk;
		my $real = abs_path($walk);
		return (undef, 'a path outside the worktree') unless defined $real && _inside($root, $real);
	}
	return ($abs, undef);
}

sub is_binary_content {
	my ($content) = @_;
	return 0 unless defined $content && length $content;
	return index($content, "\x00") >= 0 ? 1 : 0;
}

sub slurp {
	my ($path) = @_;
	return undef unless defined $path && -f $path;
	open(my $fh, '<:raw', $path) or return undef;
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

# Apply whole-file edits. %opt: root (worktree), edits (arrayref of
# { path, content } or { path, delete => 1 }), state ({ bytes => n }).
# Returns { ok, applied => [ { path, bytes } ], errors => [ ... ], bytes }.
sub apply_edits {
	my ($root, $edits, $state) = @_;
	$state ||= { bytes => 0 };
	return { ok => 0, applied => [], errors => [ 'no edits were given' ], bytes => $state->{'bytes'} }
		unless ref $edits eq 'ARRAY' && @{$edits};

	my @plan;
	my @errors;
	my $total = $state->{'bytes'} // 0;
	for my $edit ( @{$edits} ) {
		$edit = {} unless ref $edit eq 'HASH';
		my $given = $edit->{'path'};
		my ($abs, $reason) = resolve($root, $given);
		if (!$abs) {
			push @errors, (defined $given && length $given ? $given : '(no path)') . ': ' . $reason;
			next;
		}
		my $rel = $given;
		$rel =~ s/^\s+|\s+$//g;
		$rel =~ s{^\./+}{};
		$rel =~ s{/+$}{};

		my $delete = $edit->{'delete'} ? 1 : 0;
		my $old = -f $abs ? slurp($abs) : undef;
		if (defined $old && is_binary_content($old)) {
			push @errors, "$rel: the existing file is binary";
			next;
		}
		if (!$delete && !defined $edit->{'content'}) {
			push @errors, "$rel: no content was given";
			next;
		}
		my $content = $delete ? '' : $edit->{'content'};
		if (is_binary_content($content)) {
			push @errors, "$rel: the new content is binary";
			next;
		}
		my $bytes = length Encode::encode('UTF-8', $content);
		if ($total + $bytes > $MAX_CHANGED_BYTES) {
			push @errors, "$rel: " . $bytes . ' bytes would exceed the ' . $MAX_CHANGED_BYTES
				. " byte budget for the whole run ($total already written)";
			next;
		}
		$total += $bytes;
		push @plan, {
			abs => $abs, rel => $rel, content => $content,
			delete => $delete, bytes => $bytes, old => $old,
		};
	}

	return { ok => 0, applied => [], errors => \@errors, bytes => $state->{'bytes'} // 0 } if @errors;

	# Stage every file before the first rename. A write error in the middle of a
	# turn therefore leaves the tree alone, and the model is told why.
	my @staged;
	my $failed;
	for my $item (@plan) {
		if ($item->{'delete'}) {
			push @staged, $item;
			next;
		}
		require File::Basename;
		my $dir = File::Basename::dirname($item->{'abs'});
		unless (-d $dir) {
			my $ok = eval { make_path($dir); 1 };
			if (!$ok) { $failed = "$item->{rel}: the directory $dir could not be created"; last }
		}
		my ($fh, $tmp) = eval { File::Temp::tempfile('jawn_edit_XXXXXX', DIR => $dir, UNLINK => 0) };
		if (!$fh) { $failed = "$item->{rel}: a temporary file could not be made in $dir"; last }
		binmode $fh;
		my $wrote = print {$fh} Encode::encode('UTF-8', $item->{'content'});
		close $fh;
		if (!$wrote) { unlink $tmp; $failed = "$item->{rel}: the file could not be written"; last }
		$item->{'tmp'} = $tmp;
		push @staged, $item;
	}

	if (defined $failed) {
		unlink(($_->{'tmp'} // '')) for @staged;
		return { ok => 0, applied => [], errors => [ $failed ], bytes => $state->{'bytes'} // 0 };
	}

	my @applied;
	for my $item (@staged) {
		if ($item->{'delete'}) {
			unlink $item->{'abs'} if -e $item->{'abs'};
			push @applied, { path => $item->{'rel'}, bytes => 0, deleted => 1 };
			next;
		}
		my $mode = -e $item->{'abs'} ? (stat($item->{'abs'}))[2] & 07777 : undef;
		if (!rename $item->{'tmp'}, $item->{'abs'}) {
			unlink $item->{'tmp'};
			# Undo nothing here: the earlier renames in this turn did land. Say
			# so plainly rather than report a clean turn.
			push @applied, { path => $item->{'rel'}, bytes => $item->{'bytes'}, error => 'rename failed: ' . $! };
			return { ok => 0, applied => \@applied, errors => [ "$item->{rel}: the file could not be replaced" ], bytes => $state->{'bytes'} // 0 };
		}
		chmod $mode, $item->{'abs'} if defined $mode;
		push @applied, { path => $item->{'rel'}, bytes => $item->{'bytes'} };
	}

	$state->{'bytes'} = $total;
	return { ok => 1, applied => \@applied, errors => [], bytes => $total };
}

# --- unified diffs ----------------------------------------------------------

# A diff into whole-file edits, then through the same fence. Returns the same
# shape as apply_edits.
sub apply_diff {
	my ($root, $diff, $state) = @_;
	my ($files, $err) = parse_unified_diff($diff);
	return { ok => 0, applied => [], errors => [ $err ], bytes => ($state->{'bytes'} // 0) } if $err;

	my @edits;
	for my $file ( @{$files} ) {
		my ($abs, $reason) = resolve($root, $file->{'path'});
		if (!$abs) {
			return { ok => 0, applied => [], errors => [ $file->{'path'} . ': ' . $reason ],
				bytes => ($state->{'bytes'} // 0) };
		}
		my $old = -f $abs ? slurp($abs) : '';
		$old = '' unless defined $old;
		$old = Encode::decode('UTF-8', $old, Encode::FB_DEFAULT());
		my ($content, $aerr) = apply_hunks($old, $file->{'hunks'});
		if (defined $aerr) {
			return { ok => 0, applied => [], errors => [ $file->{'path'} . ': ' . $aerr ],
				bytes => ($state->{'bytes'} // 0) };
		}
		push @edits, { path => $file->{'path'}, content => $content, delete => $file->{'delete'} };
	}
	return apply_edits($root, \@edits, $state);
}

# Parse "--- a/x / +++ b/x / @@ ..." into [ { path, hunks, delete } ].
sub parse_unified_diff {
	my ($text) = @_;
	return (undef, 'the diff is empty') unless defined $text && $text =~ /\S/;
	# A trailing newline would otherwise become an empty "context" line after
	# split -1, and the first hunk would fail on a line that is not there.
	$text =~ s/\n+\z//;
	my @lines = split /\n/, $text, -1;
	my @files;
	my $i = 0;
	while ($i < @lines) {
		my $line = $lines[$i];
		if ($line =~ m{^---\s+(?:[^\t]+\t)?(\S+)}) {
			my $old_path = _diff_path($1);
			$i++;
			my $plus = $i < @lines ? $lines[$i] : '';
			return (undef, "the diff has a --- line for $old_path with no +++ line")
				unless $plus =~ m{^\+\+\+\s+(?:[^\t]+\t)?(\S+)};
			my $new_path = _diff_path($1);
			$i++;
			my ($hunks, $herr) = _parse_hunks(\@lines, \$i);
			return (undef, $herr) if $herr;
			my $delete = ($new_path eq '/dev/null') ? 1 : 0;
			my $path = $delete ? $old_path : $new_path;
			return (undef, 'a diff hunk names no path') unless length($path) && $path ne '/dev/null';
			push @files, { path => $path, hunks => $hunks, delete => $delete };
			next;
		}
		$i++;
	}
	return (undef, 'the diff has no file hunks') unless @files;
	return (\@files, undef);
}

sub _diff_path {
	my ($path) = @_;
	$path = '' unless defined $path;
	$path =~ s/^"|"$//g;
	$path =~ s{^[ab]/}{};
	return $path;
}

sub _parse_hunks {
	my ($lines, $iref) = @_;
	my @hunks;
	while ($$iref < @{$lines}) {
		my $line = $lines->[$$iref];
		last if $line =~ /^(?:--- |diff --git )/;
		if ($line =~ /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) {
			my $hunk = {
				old_start => $1 + 0,
				old_count => defined $2 ? $2 + 0 : 1,
				new_start => $3 + 0,
				new_count => defined $4 ? $4 + 0 : 1,
				body      => [],
			};
			$$iref++;
			while ($$iref < @{$lines}) {
				my $l = $lines->[$$iref];
				last if $l =~ /^@@ / || $l =~ /^(?:--- |\+\+\+ |diff --git )/;
				last if $l !~ /^(?:[ +\-\\]|$)/;
				push @{$hunk->{'body'}}, $l;
				$$iref++;
			}
			push @hunks, $hunk;
			next;
		}
		$$iref++;
	}
	return (\@hunks, undef) if @hunks;
	return (undef, 'the diff has no @@ hunks');
}

# Apply parsed hunks to $old. Returns ($new, undef) or (undef, reason).
sub apply_hunks {
	my ($old, $hunks) = @_;
	$old = '' unless defined $old;
	my @old = split /\n/, $old, -1;
	my $trailing = (@old && $old[-1] eq '') ? 1 : 0;
	pop @old if $trailing;

	my @new;
	my $pos = 0;
	for my $hunk ( @{ ref $hunks eq 'ARRAY' ? $hunks : [] } ) {
		my $start = $hunk->{'old_start'} > 0 ? $hunk->{'old_start'} - 1 : 0;
		return (undef, 'a hunk overlaps the one before it') if $start < $pos;
		return (undef, 'a hunk starts past the end of the file') if $start > scalar @old;
		push @new, @old[$pos .. $start - 1] if $start > $pos;
		$pos = $start;

		my ($oc, $nc) = (0, 0);
		for my $line ( @{ $hunk->{'body'} } ) {
			my ($tag, $body) = (' ', '');
			if ($line eq '') { ($tag, $body) = (' ', '') }
			else { $tag = substr($line, 0, 1); $body = substr($line, 1) }
			if ($tag eq ' ') {
				return (undef, 'the context does not match at line ' . ($pos + 1))
					unless $pos < @old && $old[$pos] eq $body;
				push @new, $body;
				$pos++;
				$oc++;
				$nc++;
			}
			elsif ($tag eq '-') {
				return (undef, 'a removed line does not match at line ' . ($pos + 1))
					unless $pos < @old && $old[$pos] eq $body;
				$pos++;
				$oc++;
			}
			elsif ($tag eq '+') {
				push @new, $body;
				$nc++;
			}
			elsif ($tag eq '\\') {
				next;
			}
			else {
				return (undef, 'a hunk line begins with an unknown marker');
			}
		}
		return (undef, 'the hunk removed ' . $oc . ' lines but the header says ' . $hunk->{'old_count'})
			if $oc != $hunk->{'old_count'};
		return (undef, 'the hunk added ' . $nc . ' lines but the header says ' . $hunk->{'new_count'})
			if $nc != $hunk->{'new_count'};
	}
	push @new, @old[$pos .. $#old] if $pos < @old;
	my $out = join "\n", @new;
	$out .= "\n" if $trailing;
	return ($out, undef);
}

# --- the model's reply ------------------------------------------------------

# The body of the first ```<lang> fence, with the closing fence removed. The
# language match is case-insensitive and the newline after it is optional, so
# "```JSON { ... }```" and "```diff\n...\n```" are both understood. Returns
# undef when there is no such fence.
sub _fenced_block {
	my ($text, $lang) = @_;
	return undef unless defined $text && length $text;
	return $1 if $text =~ /```[ \t]*(?:$lang)[ \t]*\r?\n?(.*?)(?:\r?\n)?[ \t]*```/si;
	return undef;
}

# Either a JSON object (edits/diff/done/note) or a bare unified diff. A JSON
# object may be wrapped in ```json fences, and a patch in ```diff/```patch
# fences; prose around either one is ignored. Returns
# ({ edits, diff, done, note }, undef) or (undef, reason).
sub parse_model_response {
	my ($text) = @_;
	$text = '' unless defined $text;
	my $bytes = reply_bytes($text);
	return (undef, 'the reply is ' . $bytes . ' bytes, over the '
		. $MAX_REPLY_BYTES . '-byte cap (nothing was written)')
		if $bytes > $MAX_REPLY_BYTES;
	my $raw = $text;
	$raw =~ s/^\s+|\s+$//g;
	return (undef, 'the model replied with nothing') unless length $raw;

	# A JSON fence is decoded from its own body; a bare or prose-wrapped object
	# is taken from the first { to the last }. Both go through JSON::PP, so a
	# fence is a convenience, not a second format.
	my $json_text = _fenced_block($raw, 'json');
	$json_text = $raw unless defined $json_text;
	my $object;
	my $start = index($json_text, '{');
	my $end = rindex($json_text, '}');
	if ($start >= 0 && $end > $start) {
		$object = eval { JSON::PP::decode_json(substr($json_text, $start, $end - $start + 1)) };
		$object = undef unless ref $object eq 'HASH';
	}

	if ($object) {
		my @edits;
		if (ref $object->{'edits'} eq 'ARRAY') {
			for my $e ( @{ $object->{'edits'} } ) {
				next unless ref $e eq 'HASH';
				my $content = $e->{'content'};
				$content = $e->{'write'} if !defined $content && defined $e->{'write'};
				$content = $e->{'text'}  if !defined $content && defined $e->{'text'};
				push @edits, {
					path    => $e->{'path'},
					content => $content,
					delete  => $e->{'delete'} ? 1 : 0,
				};
			}
		}
		my $diff = ref $object->{'diff'} eq 'SCALAR' ? ${ $object->{'diff'} } : $object->{'diff'};
		my $done = $object->{'done'} ? 1 : 0;
		my $note = $object->{'note'} // '';
		if (!@edits && !(defined $diff && length $diff) && !$done) {
			return (undef, 'the JSON has no edits, no diff and no done flag');
		}
		return ({ edits => \@edits, diff => (defined $diff ? $diff : ''), done => $done, note => $note }, undef);
	}

	my $fenced  = _fenced_block($raw, 'diff|patch');
	my $candidate = defined $fenced ? $fenced
		: (($raw =~ /^(?:diff --git |--- )/m) ? $raw : '');
	if (defined $candidate && length $candidate && $candidate =~ /^--- /m) {
		return ({ edits => [], diff => $candidate, done => 0, note => '' }, undef);
	}
	return (undef, 'the reply is neither a JSON object nor a unified diff');
}

# --- checks -----------------------------------------------------------------

# perl -c for Perl, node --check for JavaScript. Returns
# { ok, failures => [ { path, command, exit, output } ], skipped => [...] }.
sub check_files {
	my ($root, $rels) = @_;
	my @failures;
	my @skipped;
	my $node = which('node');
	for my $rel ( sort @{ ref $rels eq 'ARRAY' ? $rels : [] } ) {
		next unless defined $rel && length $rel;
		my $abs = "$root/$rel";
		next unless -f $abs;
		my @cmd;
		if ($rel =~ /\.(?:pl|pm|t)$/i) {
			my @inc = map { "-I$_" } grep { -d $_ } (
				"$root/lib", "$root/perl", "$root/t/lib", "$root/qa/lib",
			);
			@cmd = ($^X, @inc, '-c', $abs);
		}
		elsif ($rel =~ /\.(?:js|mjs|cjs)$/i) {
			if (!$node) { push @skipped, "$rel: node is not installed"; next }
			@cmd = ($node, '--check', $abs);
		}
		else {
			next;
		}
		my ($rc, $out) = run_capture(@cmd);
		next if $rc == 0;
		$out = '' unless defined $out;
		$out = substr($out, 0, 2000) . "\n... [trimmed]" if length $out > 2000;
		push @failures, {
			path => $rel, command => join(' ', @cmd), exit => $rc, output => $out,
		};
	}
	return { ok => (@failures ? 0 : 1), failures => \@failures, skipped => \@skipped };
}

sub which {
	my ($name) = @_;
	return undef unless defined $name && length $name;
	for my $dir ( split /:/, ($ENV{'PATH'} // '') ) {
		next unless length $dir;
		my $path = "$dir/$name";
		return $path if -f $path && -x _;
	}
	return undef;
}

sub run_capture {
	my (@cmd) = @_;
	my $err = gensym;
	my ($in, $out);
	my $pid = eval { open3($in, $out, $err, @cmd) };
	return (127, 'could not run ' . join(' ', @cmd)) unless $pid;
	close $in;
	my ($stdout, $stderr) = ('', '');
	my $sel = IO::Select->new($out, $err);
	while (my @ready = $sel->can_read(60)) {
		for my $fh (@ready) {
			my $buf = '';
			my $n = sysread($fh, $buf, 65536);
			if (!defined $n || $n == 0) { $sel->remove($fh); next }
			if ($fh == $out) { $stdout .= $buf } else { $stderr .= $buf }
		}
	}
	waitpid($pid, 0);
	my $rc = $? >> 8;
	return ($rc, $stdout . $stderr);
}

1;
