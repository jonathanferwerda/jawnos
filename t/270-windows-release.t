# tests-for: .github/workflows/windows-release.yml scripts/windows_release_manifest.pl
# covers:    The Windows release feed. The manifest generator is the contract
#            the updater reads (product/versionCode/filename/sha256/size/url),
#            so its schema, versionCode formula, filename check and SHA256SUMS
#            line are pinned here. The workflow is source-only on Linux, so its
#            release path (build-portable.ps1 -> iscc -> manifest -> gh release)
#            and the guarded SignPath step are asserted as text.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use JSON::PP ();

my $root     = "$FindBin::Bin/..";
my $script   = "$root/scripts/windows_release_manifest.pl";
my $workflow = slurp("$root/.github/workflows/windows-release.yml");

sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or die "read $path: $!\n";
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

sub spew {
	my ($path, $text) = @_;
	open(my $fh, '>', $path) or die "write $path: $!\n";
	binmode $fh;
	print {$fh} $text;
	close $fh;
}

# List-form execution through the shell, with every argument single-quoted, so
# a temp path or a note cannot be re-split (and no argument here holds a quote).
sub run_manifest {
	my (@args) = @_;
	my $command = join ' ', map { "'$_'" } ($^X, $script, @args);
	my $output = qx{$command 2>&1};
	return ($? >> 8, $output);
}

my $tmp   = tempdir(CLEANUP => 1);
my $bytes = "installer payload\n";
my $sha   = sha256_hex($bytes);

sub new_exe {
	my ($version) = @_;
	my $path = "$tmp/JawnOS-$version-Setup.exe";
	spew($path, $bytes);
	return $path;
}

# --- the manifest -----------------------------------------------------------

my $exe      = new_exe('0.1.2727');
my $manifest = "$tmp/windows_release.json";
my $sums     = "$tmp/SHA256SUMS";
my $url      = 'https://github.com/jonathanferwerda/jawnos/releases/download/releases/JawnOS-0.1.2727-Setup.exe';
my ($code, $out) = run_manifest(
	'--version', '0.1.2727',
	'--file',    $exe,
	'--url',     $url,
	'--notes',   'JawnOS 0.1.2727 for Windows',
	'--out',     $manifest,
	'--sums',    $sums,
);
is($code, 0, 'the manifest generator succeeds') or diag($out);
ok(-s $manifest, 'it writes the manifest');
ok(-s $sums, 'it writes SHA256SUMS');

my $man = eval { JSON::PP->new->decode(slurp($manifest)) };
ok($man && ref $man eq 'HASH', 'the manifest is a JSON object') or diag($@);

is_deeply(
	[sort keys %{$man || {}}],
	[sort qw(product version versionCode filename sha256 size url notes min_os signed)],
	'the manifest has exactly the feed schema',
);
is($man->{'product'}, 'windows', 'product is windows');
is($man->{'version'}, '0.1.2727', 'version is the argument');
is($man->{'versionCode'}, 1002727, 'versionCode is major*1e8 + minor*1e6 + patch');
is($man->{'filename'}, 'JawnOS-0.1.2727-Setup.exe', 'filename is the Setup.exe basename');
is($man->{'sha256'}, $sha, 'sha256 is the lowercase hex digest of the file');
is($man->{'size'}, length($bytes), 'size is the file size in bytes');
is($man->{'url'}, $url, 'url is the feed URL');
is($man->{'notes'}, 'JawnOS 0.1.2727 for Windows', 'notes are carried through');
is($man->{'min_os'}, '10.0.19044', 'min_os defaults to Windows 10 21H2');
is($man->{'signed'}, 0, 'the unsigned build says so');

is(slurp($sums), "$sha  JawnOS-0.1.2727-Setup.exe\n",
	'SHA256SUMS holds the coreutils line for the Setup.exe');

# The formula is not just the one example: 2.3.4 -> 203000004.
my $exe234 = new_exe('2.3.4');
($code, $out) = run_manifest(
	'--version', '2.3.4', '--file', $exe234, '--url', $url,
	'--out', "$tmp/manifest-234.json",
);
is($code, 0, 'another version builds') or diag($out);
my $man234 = JSON::PP->new->decode(slurp("$tmp/manifest-234.json"));
is($man234->{'versionCode'}, 203000004, 'versionCode for 2.3.4 is 203000004');

# --signed 1 is what the post-SignPath run passes.
($code, $out) = run_manifest(
	'--version', '0.1.2727', '--file', $exe, '--url', $url,
	'--signed', '1', '--out', "$tmp/manifest-signed.json",
);
is($code, 0, 'the signed manifest builds') or diag($out);
is(JSON::PP->new->decode(slurp("$tmp/manifest-signed.json"))->{'signed'}, 1,
	'--signed 1 records a signed build');

# --- the refusals -----------------------------------------------------------

my $wrong = "$tmp/setup.exe";
spew($wrong, $bytes);
($code, $out) = run_manifest(
	'--version', '0.1.2727', '--file', $wrong, '--url', $url,
	'--out', "$tmp/refused.json",
);
isnt($code, 0, 'a file that is not JawnOS-<version>-Setup.exe is refused');
like($out, qr/filename must be JawnOS-0\.1\.2727-Setup\.exe/,
	'the refusal names the expected filename');
ok(!-e "$tmp/refused.json", 'and writes no manifest');

($code, $out) = run_manifest(
	'--version', '1.2', '--file', $exe, '--url', $url,
	'--out', "$tmp/refused.json",
);
isnt($code, 0, 'a malformed version is refused');
like($out, qr/not a version/, 'the refusal says the version is malformed');

($code, $out) = run_manifest(
	'--version', '0.1.2727', '--file', "$tmp/nope-Setup.exe", '--url', $url,
	'--out', "$tmp/refused.json",
);
isnt($code, 0, 'a missing Setup.exe is refused');
like($out, qr/no such file/, 'the refusal says the file is missing');
ok(!-e "$tmp/refused.json", 'and still writes no manifest');

# Strawberry Perl on Windows opens in text mode by default and would digest
# CRLF-translated bytes, which no longer match the published file. The digest
# must be read raw; the Linux test cannot see the difference, so pin the source.
like(slurp($script), qr/<:raw|binmode/,
	'the manifest hashes raw bytes, not CRLF-translated text');

# --- the workflow -----------------------------------------------------------

my $wf = $workflow;
like($wf, qr/^name:\s*windows-release\s*$/m, 'the workflow is named windows-release');
like($wf, qr/^\s{2}windows-release:\s*$/m, 'it has the windows-release job');
like($wf, qr/runs-on:\s*windows-latest/, 'on the Windows runner');
like($wf, qr/timeout-minutes:\s*60/, 'bounded at 60 minutes');
like($wf, qr/workflow_dispatch:/, 'it can be dispatched by hand');
like($wf, qr/^\s+version:/m, 'dispatch takes a version input');
like($wf, qr/^\s+draft:/m, 'dispatch takes a draft input');
like($wf, qr/tags:\s*\n\s*- 'v\*'/, 'a v* tag push triggers it');
like($wf, qr/^\s*ref:\s*\$\{\{\s*github\.ref\s*\}\}/m, 'checkout follows the tag/ref');

like($wf, qr/strawberryperl/, 'Strawberry Perl comes from choco');
like($wf, qr/cpanm --notest/, 'the module set is installed with cpanm');
for my $module (qw(Mojolicious Mojo::SQLite Minion Minion::Backend::SQLite
		DBD::SQLite Net::SSLeay File::Slurp Win32::API Win32API::File)) {
	like($wf, qr/\b\Q$module\E\b/, "the pinned set includes $module");
}

like($wf, qr/choco install innosetup/, 'Inno Setup 6 comes from choco');
like($wf, qr/ISCC\.exe/, 'the build locates ISCC.exe');

# The release path, in order: the portable bundle, the wrapper, the manifest.
like($wf, qr/build-portable\.ps1/, 'it runs the portable bundle build');
like($wf, qr/-RuntimeDir C:\\Strawberry/, 'the bundle carries the Strawberry runtime');
like($wf, qr/\biscc\b/i, 'it compiles with iscc');
like($wf, qr{/DAppVersion=}, 'the version reaches the Inno preprocessor');
like($wf, qr{/DPayloadDir=}, 'the payload directory reaches the Inno preprocessor');
like($wf, qr/windows_release_manifest\.pl/, 'it runs the manifest generator');
like($wf, qr/windows_release\.json/, 'it publishes windows_release.json');
like($wf, qr/SHA256SUMS/, 'it publishes SHA256SUMS');
like($wf, qr/actions\/upload-artifact\@v4/, 'it uploads workflow artifacts');

# The feed: the fixed `releases` tag, the same shape as the Android manifest.
like($wf, qr{releases/download/releases/}, 'the manifest URL is the fixed releases tag');
like($wf, qr/gh release view releases/, 'it checks for the fixed releases feed');
like($wf, qr/\$ErrorActionPreference = 'Continue'/,
	'the release probe tolerates gh stderr under the Actions wrapper');
unlike($wf, qr/gh release view [^\n]*2>\$null/,
	'no bare gh stderr redirect can terminate the publish step');
like($wf, qr/gh release create releases/, 'it creates the feed when absent');
like($wf, qr/gh release upload releases/, 'it replaces the feed assets');
like($wf, qr/--clobber/, 'old feed assets are replaced');
like($wf, qr/GH_TOKEN/, 'gh is authenticated from GH_TOKEN');
like($wf, qr/contents:\s*write/, 'the job may write releases');

# Signing is optional and must not fail an unconfigured repo.
like($wf, qr/SIGNPATH_API_TOKEN/, 'the SignPath token is read from a secret');
like($wf, qr/if:\s*\$\{\{\s*env\.SIGNPATH_API_TOKEN != ''\s*\}\}/,
	'the SignPath steps run only when the secret is set');
like($wf, qr{signpath/github-action-submit-signing-request\@v1},
	'it uses the official SignPath action');
like($wf, qr/SignPath Foundation/, 'the placeholder records the Foundation application');
like($wf, qr/--signed 1/, 'the signed run regenerates the manifest as signed');

done_testing();
