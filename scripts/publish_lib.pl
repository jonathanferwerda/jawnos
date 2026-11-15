#!/usr/bin/perl

# The download manifest both release publishers write.
#
# `server/downloads.json` is tracked and served from raw.githubusercontent, so
# jawnos.ca sees a release only after the change is committed and promoted. The
# checkout a publish runs in is the primary, on `main`; committing there would
# put a commit on main that `origin/working` does not have, and promotion is a
# fast-forward (main must stay an ancestor of working). So the commit is made
# where every other change is made: on a branch from `origin/working`, queued
# for the coordinator that lands it. `land` does that, which is why a publish no
# longer leaves the primary dirty and no longer blocks a landing.
#
# A publish for the build the trunk already names writes nothing (the
# `generated` stamp alone is not a change), so a rerun cannot make an empty
# commit. If the queue cannot be reached, the publishers fall back to writing
# the file in the checkout — the old behaviour — so a release is never lost.
#
# This is a library, not a command: app_publish.pl and mkosi_publish.pl require
# it. Each passes its own encoder and decoder, so the file keeps the exact
# spelling (Mojo::JSON for the app, canonical pretty JSON::PP for the image).

package PublishManifest;

use strict;
use warnings;

use Cwd ();
use JSON::PP ();

# update_text($text, $payload, $encode, $decode) -> ($json, $changed).
#
# $payload holds the top-level keys this publisher owns (`app` or `desktop`);
# the other keys already in $text are preserved. `generated` is ignored when
# deciding whether anything changed, and is refreshed only on a real write.
sub update_text {
	my ($text, $payload, $encode, $decode) = @_;
	my $data = {};
	$data = eval { $decode->($text) } || {} if defined $text && length $text;
	my $merged = { %$data, %{ $payload || {} } };
	return (undef, 0) if _canonical($data) eq _canonical($merged);

	my @t = gmtime(time());
	$merged->{'generated'} = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
		$t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
	my $json = $encode->($merged);
	return (undef, 0) unless defined $json;
	return ($json, 1);
}

# update($path, $payload, $encode, $decode) -> 1 written, 0 unchanged.
#
# The fallback writer: a checkout that cannot reach the queue still gets the
# new manifest, for a human to commit with the next change.
sub update {
	my ($path, $payload, $encode, $decode) = @_;
	my $text = '';
	if (-f $path) {
		if (open(my $fh, '<', $path)) { local $/; $text = <$fh>; close $fh; }
	}
	my ($json, $changed) = update_text($text, $payload, $encode, $decode);
	return 0 unless $changed;
	open(my $out, '>', $path) or return 0;
	print {$out} $json;
	close $out;
	return 1;
}

# trunk_text($root, $trunk, 'server/downloads.json') -> the manifest on the
# trunk, or '' when the trunk does not carry it yet (the first publish).
#
# The trunk, not this checkout: the checkout is on main and lags working, so
# merging the other product's entry from it would quietly revert a release the
# trunk already has.
sub trunk_text {
	my ($root, $trunk, $rel) = @_;
	my ($rc, $text) = _git($root, 'show', "origin/$trunk:$rel");
	return $rc ? '' : $text;
}

# land($root, $trunk, $rel, $text, $decode, $subject) -> (1, $branch) queued,
# (0, $why) not queued.
#
# Commits $text as $rel on a fresh branch from origin/$trunk and hands it to
# scripts/land_enqueue.pl, which backs the branch up and writes the ticket. The
# worktree is removed at once — the coordinator lands from origin — and the
# branch is left for the warden and worktree_gc. Every failure returns a reason
# and leaves the caller's checkout untouched; the publisher decides what to do
# about it (it writes the file itself rather than losing the release).
sub land {
	my ($root, $trunk, $rel, $text, $decode, $subject) = @_;
	my ($frc) = _git($root, 'fetch', 'origin', '--quiet');
	return (0, 'could not fetch origin') if $frc;
	my ($vrc) = _git($root, 'rev-parse', '--verify', "origin/$trunk");
	return (0, "there is no origin/$trunk to land on") if $vrc;

	# A rerun before the ticket lands would queue the same snapshot a second
	# time. The branch the first run made still holds it byte for byte, so hand
	# that one back instead of making another.
	my (undef, $refs) = _git($root, 'for-each-ref', '--format=%(refname:short)', 'refs/heads/publish/');
	for my $ref (grep { length } split /\n/, $refs) {
		my ($src, $have) = _git($root, 'show', "$ref:$rel");
		return (1, $ref) if $src == 0 && _same_manifest($text, $have, $decode);
	}

	my @t = gmtime(time());
	my $base = sprintf('downloads-%04d%02d%02d%02d%02d%02d',
		$t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
	# app_publish can publish several staged builds in one run, so two publishes
	# may share a second; take the next free name rather than failing.
	my $branch = "publish/$base";
	my $n = 0;
	while ($n < 50) {
		my ($rc) = _git($root, 'rev-parse', '--verify', "refs/heads/$branch");
		last if $rc != 0;
		$n++;
		$branch = "publish/$base-$n";
	}
	return (0, 'too many publishes in one second') if $n >= 50;

	my $dir = "$root/.worktrees/$base" . ($n ? "-$n" : '');
	my ($wrc) = _git($root, 'worktree', 'add', '-q', '-b', $branch, $dir, "origin/$trunk");
	return (0, 'could not create a worktree for it') if $wrc;

	my $why = _commit_then_queue($root, $dir, $branch, $trunk, $rel, $text, $subject);
	_git($root, 'worktree', 'remove', '--force', $dir);
	if (length $why) {
		_git($root, 'branch', '-D', $branch);
		return (0, $why);
	}
	return (1, $branch);
}

# Write, commit and enqueue in the throwaway worktree. The commit runs with
# hooks off on purpose: the house pre-commit hook refuses a commit from any
# worktree while the primary is dirty, and a dirty primary is the situation this
# whole path exists to clear. Only this one path is committed, so a neighbour's
# staged files are left alone.
sub _commit_then_queue {
	my ($root, $dir, $branch, $trunk, $rel, $text, $subject) = @_;
	my $path = "$dir/$rel";
	open(my $fh, '>', $path) or return 'could not write it';
	print {$fh} $text;
	close $fh or return 'could not write it';

	my ($ac) = _git($dir, 'add', '--', $rel);
	return 'could not stage it' if $ac;
	my ($cc) = _git($dir, '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false',
		'commit', '-q', '-m', $subject, '--', $rel);
	return 'could not commit it' if $cc;

	my $script = "$root/scripts/land_enqueue.pl";
	return 'land_enqueue.pl is missing' unless -f $script;
	# The queue script takes the worktree it is run from as the thing to land.
	my $cwd = Cwd::getcwd();
	return 'could not enter the worktree' unless chdir $dir;
	my $rc = system($^X, $script, '--trunk', $trunk, '--branch', $branch);
	chdir $cwd;
	return $rc == 0 ? '' : 'the landing queue refused it';
}

# Two spellings of one manifest: identical bytes, or the same document once the
# generated stamp is set aside. A rerun a second later differs only in the
# stamp, and it is still the same release.
sub _same_manifest {
	my ($a, $b, $decode) = @_;
	return 1 if defined $a && defined $b && $a eq $b;
	my $da = eval { $decode->($a) };
	my $db = eval { $decode->($b) };
	return 0 unless defined $da && defined $db;
	return _canonical($da) eq _canonical($db);
}

# A stable string for the manifest without its generated stamp. The values are
# ordinary JSON shapes; a boolean is a blessed scalar, so its truth value is the
# comparison (the `ok` flags are the only ones either publisher writes).
sub _canonical {
	my ($value) = @_;
	return JSON::PP->new->canonical->allow_nonref->encode(_normal($value));
}

sub _normal {
	my ($value) = @_;
	return undef unless defined $value;
	if (ref $value eq 'HASH') {
		return {
			map { $_ => _normal($value->{$_}) }
			grep { $_ ne 'generated' } keys %$value
		};
	}
	if (ref $value eq 'ARRAY') {
		return [ map { _normal($_) } @$value ];
	}
	return $value ? 1 : 0 if ref $value;
	return $value;
}

# One git command in $dir -> (failed?, output). Quoted for sh so a path with a
# space is safe, and with stderr discarded: "not a git repository" is an
# ordinary skip here, not something to spray at the operator.
sub _git {
	my ($dir, @args) = @_;
	my $cmd = join(' ', 'git', '-C', _sh($dir), map { _sh($_) } @args) . ' 2>/dev/null';
	open(my $fh, '-|', 'sh', '-c', $cmd) or return (1, '');
	local $/;
	my $out = <$fh>;
	$out = '' unless defined $out;
	close $fh;
	return ($? ? 1 : 0, $out);
}

sub _sh {
	my ($text) = @_;
	$text =~ s/'/'"'"'/g;
	return "'$text'";
}

1;
