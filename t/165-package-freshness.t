# tests-for: lib/JawnOS/Packages.pm scripts/jawnos_deps.pl qa/installers/run.sh qa/systemd/jawnos-qa-installers.service qa/systemd/jawnos-qa-installers.timer
# covers:    the installer freshness check reads package metadata only -- no
#           tarball, no `apt-get update`, no `pacman -S`, no cpanm -- and says
#           whether upstream still offers every name the installers ask for.
#           The parsers grade candidates against a simulated host, so the
#           statuses (current/outdated/available/missing) are deterministic on
#           any machine; a missing name fails, an outdated one only with
#           --strict, and the nightly unit never installs or downloads.

use strict;
use warnings;

use FindBin;
use File::Copy;
use File::Slurp qw(read_file);
use File::Temp ();
use JSON::PP;
use Test::More;

use lib "$FindBin::Bin/../lib";
use JawnOS::Packages;

my $root     = "$FindBin::Bin/..";
my $fixtures = "$root/t/fixtures/packages";

# --- parsers -----------------------------------------------------------------

is_deeply(
	JawnOS::Packages::parse_metacpan('{"version":"9.53","release":"Mojolicious-9.53"}'),
	{ latest => '9.53', release => 'Mojolicious-9.53' },
	'MetaCPAN: the candidate version and its release'
);
ok( !defined JawnOS::Packages::parse_metacpan(''), 'MetaCPAN: an empty body is no answer' );
ok( !defined JawnOS::Packages::parse_metacpan('not json'), 'MetaCPAN: junk is no answer' );
ok( !defined JawnOS::Packages::parse_metacpan('{"release":"Mojolicious-9.53"}'),
	'MetaCPAN: a response without a version is no candidate' );

my $madison = JawnOS::Packages::parse_madison(join "\n",
	'tmux | 3.5a-3 | stable | amd64, arm64',
	'tmux | 3.6-1 | testing | amd64',
	'tmux | 3.7-1 | unstable | amd64',
	'');
is( scalar @{ $madison->{'lines'} }, 3, 'madison: one row per suite' );
is( $madison->{'suites'}{'stable'}, '3.5a-3', 'madison: suites are keyed by name' );
is_deeply( JawnOS::Packages::debian_latest($madison),
	{ version => '3.5a-3', suite => 'stable' },
	'Debian: stable is the candidate the installer will get' );
is_deeply(
	JawnOS::Packages::debian_latest(JawnOS::Packages::parse_madison('sox | 14.4.2-5 | unstable | amd64')),
	{ version => '14.4.2-5', suite => 'unstable' },
	'Debian: a package only in unstable is still offered, and says so'
);
ok( !defined JawnOS::Packages::debian_latest(JawnOS::Packages::parse_madison("\n")),
	'Debian: an answer with no rows is no candidate (and the caller calls that missing)' );

my $arch = JawnOS::Packages::parse_arch(
	'{"results":['
	. '{"pkgname":"tmux","repo":"core","arch":"aarch64","pkgver":"1.0","pkgrel":"9","epoch":0},'
	. '{"pkgname":"tmux","repo":"extra","arch":"any","pkgver":"3.8","pkgrel":"2","epoch":0}]}');
is( $arch->{'repo'}, 'extra', 'Arch: the x86_64/any build is the one this host installs' );
is( $arch->{'rel'}, '2', 'Arch: pkgrel is kept' );
is( JawnOS::Packages::arch_version($arch), '3.8-2', 'Arch: the version vercmp and pacman -Q show' );
is( JawnOS::Packages::arch_version({ latest => '3.8', rel => '1', epoch => 0 }), '3.8-1',
	'Arch: epoch 0 is not printed' );
is( JawnOS::Packages::arch_version({ latest => '20260924', rel => '1', epoch => 1 }), '1:20260924-1',
	'Arch: a real epoch is printed' );
ok( !defined JawnOS::Packages::parse_arch('{"results":[]}'),
	'Arch: a package with no builds is no candidate (and the caller calls that missing)' );

my $sdk = JawnOS::Packages::parse_sdk_repository(
	'<sdkRepository>'
	. '<remotePackage path="platform-tools"><revision/></remotePackage>'
	. '<remotePackage path="ndk;22.1.7171670"/>'
	. '<channel id="beta"><remotePackage path="platforms;android-37-beta"/></channel>'
	. '</sdkRepository>');
is( $sdk->{'packages'}{'platform-tools'}, 1, 'SDK: platform-tools is a package id' );
is( $sdk->{'packages'}{'ndk;22.1.7171670'}, 1, 'SDK: ndk;<version> is a package id' );
is( $sdk->{'packages'}{'platforms;android-37-beta'}, 1, 'SDK: channels do not hide a package' );
ok( !defined JawnOS::Packages::parse_sdk_repository('<sdkRepository></sdkRepository>'),
	'SDK: an index with no packages is no answer' );
ok( !defined JawnOS::Packages::parse_sdk_repository('not xml'), 'SDK: junk is no answer' );

is_deeply( [ JawnOS::Packages::ndk_prune_plan([qw(22.1.7171670 30.0.16248370)], 2, '30.0.16248370') ],
	[], 'prune: the pinned NDK and the newest two are all kept' );
is_deeply( [ JawnOS::Packages::ndk_prune_plan([qw(22.1.7171670 30.0.16248370 31.0.1)], 2, '30.0.16248370') ],
	['22.1.7171670'], 'prune: a third NDK drops the oldest, not the pin' );
is_deeply( [ JawnOS::Packages::ndk_prune_plan([qw(22.1.7171670 30.0.16248370 31.0.1)], 2, undef) ],
	['22.1.7171670'], 'prune: without a pin the newest two win' );
is_deeply( [ JawnOS::Packages::ndk_prune_plan([qw(22.1.7171670 30.0.16248370)], 1, '22.1.7171670') ],
	[], 'prune: the pin survives even when it is the oldest' );
is_deeply( [ JawnOS::Packages::ndk_prune_plan([qw(22.1.7171670 30.0.16248370)], 1, undef) ],
	['22.1.7171670'], 'prune: --android-keep 1 removes exactly one' );

is_deeply( [ JawnOS::Packages::sdk_prune_plan([qw(34.0.0 35.0.0 36.0.0 37.0.0)], 2, '35.0.0') ],
	['34.0.0'], 'prune: build-tools keep the newest two and the version the app pins' );
is_deeply( [ JawnOS::Packages::sdk_prune_plan([qw(34.0.0 36.0.0 37.0.0)], 2, '34.0.0') ],
	[], 'prune: the build-tools AGP resolves survive even though they are the oldest' );
is( JawnOS::Packages::parse_agp_version(q{classpath 'com.android.tools.build:gradle:8.7.3'}),
	'8.7.3', 'AGP: the plugin version is read from the app build file' );
ok( !defined JawnOS::Packages::parse_agp_version('classpath "org.other:thing:1.0"'),
	'AGP: no plugin, no version' );
is( JawnOS::Packages::parse_agp_build_tools("\xca\xfe\xba\xbe" . '34.0.0' . "\x00\x01"), '34.0.0',
	'AGP: its default build-tools is read from the class constant' );
ok( !defined JawnOS::Packages::parse_agp_build_tools('no version here'),
	'AGP: an unreadable class yields no pin, and nothing is pruned' );
my $platform_version = sub { $_[0] =~ /^android-([\d.]+)$/ ? $1 : $_[0] };
is_deeply(
	[ JawnOS::Packages::sdk_prune_plan([qw(android-34 android-35 android-36)], 2, 'android-36',
		$platform_version) ],
	['android-34'], 'prune: platforms compare by number, not by name' );
is_deeply(
	[ JawnOS::Packages::sdk_prune_plan([qw(android-34 android-36 android-37)], 2, 'android-36',
		$platform_version) ],
	['android-34'], 'prune: a new platform keeps the compileSdk platform and the newest' );

my $tools = JawnOS::Packages::parse_sdk_repository(
	'<r><remotePackage path="build-tools;36.0.0"/><remotePackage path="build-tools;36.1.0"/>'
	. '<remotePackage path="build-tools;37.0.0-rc1"/><remotePackage path="build-tools;38.0.0-beta2"/>'
	. '<remotePackage path="cmdline-tools;latest"/></r>');
is( JawnOS::Packages::sdk_newest($tools, 'build-tools'), '36.1.0',
	'SDK: a preview is not a candidate to install' );
is( JawnOS::Packages::sdk_newest($tools, 'cmdline-tools'), undef,
	'SDK: `latest` is an alias, not a version to compare' );
is( JawnOS::Packages::sdk_newest($tools, 'ndk'), undef, 'SDK: a family the index lacks has no candidate' );
is( JawnOS::Packages::sdk_newest(
		JawnOS::Packages::parse_sdk_repository(
			'<r><remotePackage path="ndk;9.0.1"/><remotePackage path="ndk;30.0.16248370"/></r>'),
		'ndk'), '30.0.16248370', 'SDK: versions compare as numbers, not strings' );

is( JawnOS::Packages::compare_module('0.085', '0.091'), -1, 'CPAN: 0.085 is behind 0.091' );
is( JawnOS::Packages::compare_module('9.39', '9.39'), 0, 'CPAN: equal versions compare equal' );
is( JawnOS::Packages::compare_module('10.31', '9.53'), 1, 'CPAN: versions compare as numbers, not strings' );
is( JawnOS::Packages::compare_module(undef, '1.0'), 0,
	'CPAN: an absent install is never "outdated" by accident' );

is( JawnOS::Packages::compare_arch('3.7-1', '3.8-1'), -1, 'Arch: 3.7-1 is behind 3.8-1' );
is( JawnOS::Packages::compare_arch('3.8-1', '3.8-1'), 0, 'Arch: equal versions compare equal' );
is( JawnOS::Packages::compare_arch('3.8-2', '3.8-1'), 1, 'Arch: pkgrel breaks a tie' );
is( JawnOS::Packages::compare_arch('1:20250924-1', '20260924-1'), 1, 'Arch: an epoch beats a pkgver' );
is( JawnOS::Packages::compare_arch('1.0rc1-1', '1.0-1'), -1, 'Arch: a release beats its own rc' );
is( JawnOS::Packages::compare_arch('1.0.1-1', '1.0-1'), 1, 'Arch: a further number is newer' );
is( JawnOS::Packages::compare_arch('1.10-1', '1.9-1'), 1, 'Arch: digit runs compare as numbers, not strings' );

# --- the report against a simulated host -------------------------------------

sub freshness_in {
	my ($dir, @args) = @_;
	my @cmd = ($^X, "$root/scripts/jawnos_deps.pl", '--freshness', '--fixtures', $dir, @args);
	my $pid = open(my $fh, '-|');
	die "fork: $!" unless defined $pid;
	if (!$pid) {
		open STDERR, '>&', \*STDOUT;
		exec @cmd;
		exit 127;
	}
	local $/;
	my $out = <$fh>;
	close $fh;
	return ($? >> 8, defined $out ? $out : '');
}

sub freshness {
	return freshness_in($fixtures, @_);
}

my ($rc, $out) = freshness('--json',
	'--only=Mojo::SQLite', '--only=Minion::Backend::SQLite',
	'--only=Crypt::Simple', '--only=CryptX');
is( $rc, 0, 'outdated rows do not fail the nightly' );
my $data = eval { decode_json($out) };
ok( ref $data eq 'HASH', '--json prints one JSON document and nothing else' );
is( $data->{'metadata_only'}, 1, 'the report says it downloaded nothing' );
my %mod = map { $_->{'name'} => $_ } @{ $data->{'modules'} || [] };
is( $mod{'Mojo::SQLite'}{'status'}, 'outdated', 'an install behind its candidate is outdated' );
is( $mod{'Mojo::SQLite'}{'latest'}, '4.0.0', 'and it reports the candidate' );
is( $mod{'Minion::Backend::SQLite'}{'status'}, 'available',
	'not installed but offered is available, never outdated' );
is( $mod{'Crypt::Simple'}{'status'}, 'current', 'equal versions are current' );
is( $mod{'CryptX'}{'status'}, 'available',
	'the simulated host decides what is installed, not this machine' );

($rc) = freshness('--json', '--strict', '--only=Mojo::SQLite');
is( $rc, 1, '--strict turns an outdated row into a failure' );

($rc, $out) = freshness('--only=Email::Stuffer');
is( $rc, 1, 'a module upstream no longer offers fails the check' );
like( $out, qr/Email::Stuffer\s+-\s+->\s+-\s+missing/, 'the row is marked missing' );
like( $out, qr/missing upstream: Email::Stuffer/, 'and it is named in the summary' );

($rc, $out) = freshness('--only=sox');
is( $rc, 1, 'a package Arch dropped fails even when Debian still has it' );
like( $out, qr/sox\s+-\s+->\s+14\.4\.2\+git20190427-5\s+available/,
	'the Debian row still reports the candidate' );
like( $out, qr/missing upstream: sox/, 'and the missing Arch name is reported' );

($rc, $out) = freshness('--only=noto-fonts-emoji');
is( $rc, 0, 'a package that is merely behind is informational' );
like( $out, qr/noto-fonts-emoji\s+1:20250924-1\s+->\s+1:20260924-1\s+outdated/,
	'an epoch survives into the comparison and the report' );

($rc, $out) = freshness('--only=no-such-package-anywhere');
is( $rc, 2, 'an --only that matches nothing is a usage error, not a pass' );
like( $out, qr/no requested names matched/, 'and it says so' );

# --- the Android SDK/NDK -----------------------------------------------------
# A fixture run describes the machine too: sdk_installed.txt is what the SDK
# here has, sdk_repository.xml is what Google offers.
my @sdk_ids = ('platform-tools', 'cmdline-tools;latest', 'platforms;android-36',
	'build-tools;36.0.0', 'ndk;22.1.7171670');
($rc, $out) = freshness('--android', '--json', map { "--only=$_" } @sdk_ids);
is( $rc, 0, 'an SDK the index still offers passes' );
my $sdk_json = eval { decode_json($out) };
my @android = @{ $sdk_json->{'android'} || [] };
is( scalar @android, 5, 'every component this machine has is checked once' );
is( scalar(grep { $_->{'status'} eq 'offered' } @android), 5, 'and each is offered' );
is( scalar(grep { $_->{'installed'} } @android), 5, 'the report marks what is installed here' );
is( $sdk_json->{'summary'}{'android_missing'}, 0, 'the summary counts no missing component' );

# The failure this job exists for: Google stops offering a component the build
# here depends on. One variable changes, in a throwaway copy of the fixtures.
my $tmp = File::Temp::tempdir(CLEANUP => 1);
opendir(my $dh, $fixtures) or die "fixtures: $!";
for my $name (grep { !/^\.\.?$/ } readdir $dh) {
	next unless -f "$fixtures/$name";
	File::Copy::copy("$fixtures/$name", "$tmp/$name") or die "copy $name: $!";
}
closedir $dh;
my $xml = read_file("$fixtures/sdk_repository.xml");
my $crippled = join '', grep { !/remotePackage path="(?:ndk|cmdline-tools)/ } split /^/, $xml;
open(my $xh, '>', "$tmp/sdk_repository.xml") or die "write: $!";
print {$xh} $crippled;
close $xh;

($rc, $out) = freshness_in($tmp, '--android', '--only=ndk;22.1.7171670', '--only=cmdline-tools;latest');
is( $rc, 1, 'a component the index dropped fails, even when it is installed locally' );
like( $out, qr/ndk;22\.1\.7171670\s+missing/, 'the ndk row is marked missing' );
like( $out, qr/android missing: cmdline-tools;latest, ndk;22\.1\.7171670/,
	'and both dropped components are named' );

# And the index itself gone: one request, so "no answer" is a failure, not a
# quiet pass over the section the caller asked for.
unlink "$tmp/sdk_repository.xml";
($rc, $out) = freshness_in($tmp, '--android', '--only=platform-tools');
is( $rc, 1, 'a vanished SDK index fails the check' );
like( $out, qr/repository index\s+missing/, 'and the report says the index is the missing thing' );

# --- is there a newer build-tools or NDK? ----------------------------------
# The base fixtures describe a machine that is up to date; this copy offers a
# newer build-tools and NDK, which is the drift the check must name.
my $newer = File::Temp::tempdir(CLEANUP => 1);
opendir(my $ndh, $fixtures) or die "fixtures: $!";
for my $name (grep { !/^\.\.?$/ } readdir $ndh) {
	next unless -f "$fixtures/$name";
	File::Copy::copy("$fixtures/$name", "$newer/$name") or die "copy $name: $!";
}
closedir $ndh;
my $offered = read_file("$fixtures/sdk_repository.xml");
$offered =~ s{</sdkRepository>}{  <remotePackage path="build-tools;36.1.0"/>\n  <remotePackage path="ndk;30.0.16248370"/>\n</sdkRepository>};
open(my $nh, '>', "$newer/sdk_repository.xml") or die "write: $!";
print {$nh} $offered;
close $nh;

($rc, $out) = freshness_in($newer, '--android', '--json', '--only=build-tools', '--only=ndk');
my $toolchain = eval { decode_json($out) };
my %tool = map { $_->{'tool'} => $_ } @{ $toolchain->{'toolchain'} || [] };
is( $rc, 0, 'a newer toolchain is informational, not a failure' );
is( $tool{'build-tools'}{'status'}, 'outdated', 'build-tools behind upstream is outdated' );
is( $tool{'build-tools'}{'latest'}, '36.1.0', 'and it names the version offered' );
is( $tool{'build-tools'}{'update'}, 'build-tools;36.1.0', 'and the package id to install' );
is( $tool{'ndk'}{'status'}, 'outdated', 'so is an NDK behind upstream' );
is( $toolchain->{'summary'}{'android_outdated'}, 2, 'the summary counts both' );

($rc) = freshness_in($newer, '--android', '--strict', '--json', '--only=build-tools', '--only=ndk');
is( $rc, 1, '--strict makes a toolchain behind upstream fail' );

($rc, $out) = freshness_in($newer, '--android', '--android-update', '--only=build-tools', '--only=ndk');
unlike( $out, qr/sdkmanager --install/, 'a fixture run never installs anything, even when asked to update' );
unlike( $out, qr/android prune/, 'and never deletes an NDK' );

# --- the nightly job downloads nothing ---------------------------------------

ok( -x "$root/qa/installers/run.sh", 'the nightly freshness job is executable' );
is( system('bash', '-n', "$root/qa/installers/run.sh"), 0, 'it parses under bash' );

my $script = read_file("$root/qa/installers/run.sh");
my $bare   = join "\n", grep { !/^\s*#/ } split /\n/, $script;
like( $script, qr/--freshness/, 'the job runs the metadata check' );
like( $script, qr/--desktop/, 'and it covers the desktop app too' );
like( $script, qr/--android/, 'and the Android SDK/NDK index' );
like( $script, qr/--android-update/, 'and it installs a newer toolchain' );
like( $script, qr/ANDROID_UPDATE/, 'with an opt-out' );
like( $script, qr/QA_SOURCE/, 'it checks the committed tree unless asked otherwise' );
like( $script, qr/flock/, 'two timers cannot overlap' );
unlike( $bare, qr/apt-get\s+update/, 'it never refreshes the apt index' );
unlike( $bare, qr/\bapt(-get)?\s+install\b/, 'it never installs a Debian package' );
unlike( $bare, qr/\bpacman\s+-S\b/, 'it never installs an Arch package' );
unlike( $bare, qr/\bcpanm\b/, 'it never installs a CPAN module' );
unlike( $bare, qr/\bsudo\b/, 'it needs no privileges' );

my $deps = read_file("$root/scripts/jawnos_deps.pl");
like( $deps, qr{fastapi\.metacpan\.org/v1/module/}, 'the CPAN endpoint is pinned in the source' );
like( $deps, qr{api\.ftp-master\.debian\.org/madison}, 'the Debian endpoint is pinned in the source' );
like( $deps, qr{archlinux\.org/packages/search/json/}, 'the Arch endpoint is pinned in the source' );
like( $deps, qr{dl\.google\.com/android/repository/repository2-3\.xml},
	'the Android SDK index is pinned in the source' );
like( $deps, qr/android-keep/, 'and the NDK keep count is a flag' );

# Piper: the 2023 bundle reads a phoneme as one codepoint and the voices that
# ship use multi-codepoint ones ("aɪ"), so every phrase failed with "Phonemes
# must be one codepoint" and the gateway spoke nothing. A desktop installs the
# pip wheel in its own venv and runs it through a wrapper; Termux keeps the
# glibc bundle, which is why that path stays.
like( $deps, qr/sub install_piper_wheel/, 'a desktop installs the pip wheel' );
like( $deps, qr/'--upgrade', 'piper-tts/, 'and re-running the installer upgrades it' );
like( $deps, qr{jawnos/piper18/venv}, 'in its own venv' );
like( $deps, qr/sub piper_wrapper/, 'behind a wrapper the app can run' );
like( $deps, qr{\$piper_dir-2023}, 'the 2023 bundle is kept beside it' );
like( $deps, qr/install_piper_bundle\(\$arch\)/, 'and Termux still takes the bundle' );

my $service = read_file("$root/qa/systemd/jawnos-qa-installers.service");
my $timer   = read_file("$root/qa/systemd/jawnos-qa-installers.timer");
like( $service, qr{ExecStart=/bin/bash \S+/qa/installers/run\.sh}, 'the unit runs the job' );
like( $timer, qr/OnCalendar=\*-\*-\* 03:45:00/, 'nightly at 03:45, ahead of the Docker smoke' );
unlike( $service, qr/device_target/, 'metadata only, so it is not gated on the QA machine' );
like( $service, qr/MemoryMax=3G/, 'a metadata check plus an SDK install stays bounded' );

my $readme = read_file("$root/qa/README.md");
like( $readme, qr/installer package freshness/i, 'the QA README documents the job' );
like( $readme, qr{repository2-3\.xml}, 'and the Android half of it' );

done_testing;
