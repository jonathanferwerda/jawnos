# tests-for: scripts/publish_lib.pl scripts/mkosi_publish.pl scripts/app_publish.pl
# covers:    A publish must not leave the primary checkout dirty, because a dirty
#            primary blocks both a landing and the fast-forward promotion. The
#            manifest is committed on a branch from origin/working and handed to
#            land_enqueue.pl, so the checkout keeps its old copy, a rerun for the
#            build the trunk already names makes no branch at all, and a newer
#            build builds on the landed snapshot instead of reverting it. A
#            publish run outside a git checkout still writes the file and says
#            why it could not queue the commit.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();

require "$FindBin::Bin/../scripts/publish_lib.pl";

sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or die "$path: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

sub spew {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh $text;
	close $fh;
}

# One git command -> (exit code, output). The paths come from File::Temp, so the
# simple quoting below is enough.
sub git_at {
	my ($dir, @args) = @_;
	my $out = qx{git -C '$dir' @args 2>&1};
	return ($? >> 8, $out);
}

my $tmp = tempdir(CLEANUP => 1);
my $path = "$tmp/downloads.json";
my $enc = sub { JSON::PP->new->canonical->pretty->encode($_[0]) };
my $dec = sub { JSON::PP->new->decode($_[0]) };

my $desktop = {
	'ok' => JSON::PP::true,
	'url' => 'https://dl.jawnos.ca/jawnos-live.raw.zst',
	'manifest' => 'https://dl.jawnos.ca/desktop_release.json',
	'size' => 1234,
	'sha256' => 'a' x 64,
	'version' => '1.0',
	'label' => 'One file, no parts',
};

my $wrote = PublishManifest::update($path, { 'desktop' => $desktop }, $enc, $dec);
is($wrote, 1, 'a first publish writes the manifest');
my $first = slurp($path);
like($first, qr/"generated"\s*:/, 'and stamps it');

# Simulate an older run, then publish the same image again. The only difference
# the old code would have written is the generated stamp.
my $sentinel = $first;
$sentinel =~ s/"generated"\s*:\s*"[^"]*"/"generated": "2000-01-01T00:00:00Z"/;
spew($path, $sentinel);
$wrote = PublishManifest::update($path, { 'desktop' => $desktop }, $enc, $dec);
is($wrote, 0, 'the same image published again writes nothing');
is(slurp($path), $sentinel, 'and leaves the file, generated stamp included, untouched');

# The other product's entry is preserved, and its presence alone is not a
# reason to rewrite the file.
my $both = JSON::PP->new->canonical->pretty->encode({
	'app' => {
		'ok' => JSON::PP::true,
		'filename' => 'jawnos-app-1309-0.118.311.apk',
		'versionName' => '0.118.311',
		'versionCode' => 1309,
	},
	'desktop' => $desktop,
	'generated' => '2000-01-01T00:00:00Z',
});
spew($path, $both);
$wrote = PublishManifest::update($path, { 'desktop' => $desktop }, $enc, $dec);
is($wrote, 0, 'a manifest carrying the app entry does not make the image publish a change');
like(slurp($path), qr/0\.118\.311/, 'and the app entry is kept');

# A real change writes once and moves the stamp.
my $newer = { %$desktop, 'version' => '2.0' };
$wrote = PublishManifest::update($path, { 'desktop' => $newer }, $enc, $dec);
is($wrote, 1, 'a newer image writes the manifest');
my $third = slurp($path);
unlike($third, qr/2000-01-01T00:00:00Z/, 'and refreshes the generated stamp');
like($third, qr/"version"\s*:\s*"2\.0"/, 'with the new version');
like($third, qr/0\.118\.311/, 'and keeps the app entry');

# update_text is the writer the publishers use against the trunk's copy; it must
# reach the same verdict without a file in the way.
{
	my ($json, $changed) = PublishManifest::update_text($third, { 'desktop' => $newer }, $enc, $dec);
	is($changed, 0, 'update_text leaves an unchanged payload alone');
	is($json, undef, 'and returns no document');
	($json, $changed) = PublishManifest::update_text($third, { 'desktop' => { %$newer, 'version' => '3.0' } }, $enc, $dec);
	is($changed, 1, 'update_text writes a real change');
	like($json, qr/"version"\s*:\s*"3\.0"/, 'with the new value');
	like($json, qr/0\.118\.311/, 'and the other product still in it');
}

# --- app_publish.pl through its real command path ---------------------------
# The app publisher uses Mojo::JSON, so a boolean decoded from the file and the
# Mojo boolean it writes must compare equal: otherwise every run would look like
# a change.

my $calls = "$tmp/land-called.txt";
local $ENV{'LAND_CALLED'} = $calls;

# Everything a publish needs: the publisher and its library, the queue it hands
# a commit to (stubbed — t/88 and t/91 own the real one), an empty manifest, the
# staged APK's directory and the app repo it inspects.
sub fixture {
	my ($base) = @_;
	my $releases = "$base-releases";
	my $app_repo = "$base-app-repo";
	make_path("$base/scripts", "$base/server", "$base/docs", $releases);
	make_path("$app_repo/app/src/main/assets");
	spew("$base/scripts/app_publish.pl", slurp("$FindBin::Bin/../scripts/app_publish.pl"));
	spew("$base/scripts/publish_lib.pl", slurp("$FindBin::Bin/../scripts/publish_lib.pl"));
	spew("$base/scripts/land_enqueue.pl", <<'STUB');
#!/usr/bin/perl
# Record the ticket the publisher asked for; t/267 asserts on it.
use strict;
use warnings;
open(my $fh, '>>', $ENV{'LAND_CALLED'}) or die "LAND_CALLED: $!\n";
print {$fh} "@ARGV\n";
close $fh;
exit 0;
STUB
	spew("$base/server/downloads.json", "{}\n");
	return ($base, $releases, $app_repo);
}

sub publish {
	my ($root, $releases, $app_repo) = @_;
	my $out = qx{$^X '$root/scripts/app_publish.pl' --dir '$releases' --app-repo '$app_repo' --no-runtime --repo owner/name 2>&1};
	return ($? >> 8, $out);
}

my $bin = "$tmp/bin";
make_path($bin);
my $fake_gh = "$bin/gh";
spew($fake_gh, "#!/bin/sh\nexit 0\n");
chmod 0755, $fake_gh or die "chmod gh: $!";
local $ENV{'PATH'} = "$bin:$ENV{'PATH'}";

subtest 'app_publish queues the snapshot instead of dirtying the checkout' => sub {
	my ($root, $releases, $app_repo) = fixture("$tmp/root");
	my $origin = "$tmp/origin.git";

	my ($rc, $err) = git_at($root, 'init', '-q', '-b', 'main');
	plan skip_all => "git is unavailable: $err" if $rc;
	for my $pair ([ 'user.email', 'test@example.invalid' ], [ 'user.name', 'Test' ]) {
		($rc, $err) = git_at($root, 'config', $pair->[0], $pair->[1]);
		die "git config $pair->[0] failed: $err" if $rc;
	}
	($rc, $err) = git_at($root, 'add', '-A');
	die "git add failed: $err" if $rc;
	($rc, $err) = git_at($root, 'commit', '-q', '-m', 'fixture');
	die "fixture commit failed: $err" if $rc;
	($rc, $err) = git_at($tmp, 'init', '--bare', '-q', $origin);
	die "bare init failed: $err" if $rc;
	($rc, $err) = git_at($root, 'remote', 'add', 'origin', $origin);
	die "remote add failed: $err" if $rc;
	for my $ref (qw(main working)) {
		($rc, $err) = git_at($root, 'push', '-q', 'origin', "main:refs/heads/$ref");
		die "push $ref failed: $err" if $rc;
	}
	($rc, $err) = git_at($root, 'fetch', 'origin', '--quiet');
	die "fetch failed: $err" if $rc;

	spew("$releases/jawnos-app-7-0.0.7.apk", "not really an apk\n");
	my ($code, $out) = publish($root, $releases, $app_repo);
	is($code, 0, 'the first publish runs against the fake gh') or diag($out);
	like($out, qr/queued publish\/downloads-\d+ for the working trunk/,
		'the publish queues the snapshot for the trunk');
	is(slurp("$root/server/downloads.json"), "{}\n",
		'and the primary checkout keeps its old copy');
	my (undef, $status) = git_at($root, 'status', '--porcelain');
	is($status, '', 'so the checkout stays clean');

	my ($called) = split /\n/, slurp($calls);
	like($called, qr/^--trunk working --branch publish\/downloads-/,
		'the queue is asked for the working trunk');
	my ($branch) = $called =~ /--branch (\S+)/;
	my ($sc, $snapshot) = git_at($root, 'show', $branch . ':server/downloads.json');
	is($sc, 0, 'the queued branch carries the manifest') or diag($snapshot);
	like($snapshot, qr/"versionCode"\s*:\s*7,/, 'naming the staged build');
	my (undef, $subject) = git_at($root, 'log', '-1', '--format=%s', $branch);
	like($subject, qr/0\.0\.7/, 'with a commit subject that names it');
	my (undef, $files) = git_at($root, 'show', '--name-only', '--format=', $branch);
	is_deeply([ grep { /\S/ } split /\n/, $files ], [ 'server/downloads.json' ],
		'and the commit carries the manifest and nothing else');
	# A rerun before the coordinator picks the branch up must not queue the same
	# snapshot again: it hands back the branch that already holds it.
	($code, $out) = publish($root, $releases, $app_repo);
	is($code, 0, 'a rerun before landing still succeeds') or diag($out);
	like($out, qr/queued \Q$branch\E for the working trunk/,
		'and names the branch that already holds the snapshot');
	my $pending = () = slurp($calls) =~ /\n/g;
	is($pending, 1, 'without queueing a second ticket');

	# Stand in for the coordinator: the branch lands on the trunk.
	($rc, $err) = git_at($root, 'push', '-q', 'origin', "$branch:refs/heads/working");
	is($rc, 0, 'the branch lands on the working trunk') or diag($err);
	git_at($root, 'fetch', 'origin', '--quiet');

	# The same build again reads the trunk, finds what it already has, and
	# makes neither a branch nor a ticket.
	($code, $out) = publish($root, $releases, $app_repo);
	is($code, 0, 'the same build publishes again') or diag($out);
	my $count = () = slurp($calls) =~ /\n/g;
	is($count, 1, 'and queues nothing');
	is(slurp("$root/server/downloads.json"), "{}\n", 'still leaving the checkout untouched');
	unlike($out, qr/queued|updated downloads\.json/, 'with no notice about the manifest');

	spew("$releases/jawnos-app-8-0.0.8.apk", "a newer apk\n");
	($code, $out) = publish($root, $releases, $app_repo);
	is($code, 0, 'a newer staged build publishes') or diag($out);
	my @lines = split /\n/, slurp($calls);
	is(scalar @lines, 2, 'and is queued');
	my ($next) = $lines[1] =~ /--branch (\S+)/;
	my (undef, $next_snapshot) = git_at($root, 'show', $next . ':server/downloads.json');
	like($next_snapshot, qr/"versionCode"\s*:\s*8,/, 'naming the newer build');
	unlike($next_snapshot, qr/0\.0\.7/, 'and only it');
	my ($anc) = git_at($root, 'merge-base', '--is-ancestor', $branch, $next);
	is($anc, 0, 'building on the landed snapshot rather than reverting it');
};

# A publisher run from a plain directory (an unpacked copy, a test root) has no
# trunk to queue to. It must still write the manifest, succeed, and say why.
subtest 'a publish outside a git checkout still writes the manifest' => sub {
	my ($root, $releases, $app_repo) = fixture("$tmp/plain");
	spew("$releases/jawnos-app-9-0.0.9.apk", "an apk in a plain directory\n");

	my ($code, $out) = publish($root, $releases, $app_repo);
	is($code, 0, 'the publish still succeeds') or diag($out);
	like(slurp("$root/server/downloads.json"), qr/"versionCode"\s*:\s*9/,
		'and the manifest is written');
	like($out, qr/updated downloads\.json \(could not fetch origin\)/,
		'saying why it could not queue the commit');
};

# The image publisher shares the same writer; a direct write would reintroduce
# the dirty-file bug on the desktop side.
my $mkosi = slurp("$FindBin::Bin/../scripts/mkosi_publish.pl");
like($mkosi, qr/PublishManifest::update_text/, 'mkosi_publish uses the shared writer');
like($mkosi, qr/PublishManifest::land/, 'and queues what it writes');
like($mkosi, qr/PublishManifest::trunk_text/, 'against the trunk rather than the checkout');

done_testing();
