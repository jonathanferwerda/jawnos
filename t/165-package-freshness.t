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
use File::Slurp qw(read_file);
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

sub freshness {
	my (@args) = @_;
	my @cmd = ($^X, "$root/scripts/jawnos_deps.pl", '--freshness', '--fixtures', $fixtures, @args);
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

($rc, $out) = freshness('--only=zbar');
is( $rc, 1, 'a package Arch dropped fails even when Debian still has it' );
like( $out, qr/zbar-tools\s+-\s+->\s+0\.23\.93-1\s+available/,
	'the Debian row still reports the candidate' );
like( $out, qr/missing upstream: zbar/, 'and the missing Arch name is reported' );

($rc, $out) = freshness('--only=noto-fonts-emoji');
is( $rc, 0, 'a package that is merely behind is informational' );
like( $out, qr/noto-fonts-emoji\s+1:20250924-1\s+->\s+1:20260924-1\s+outdated/,
	'an epoch survives into the comparison and the report' );

($rc, $out) = freshness('--only=no-such-package-anywhere');
is( $rc, 2, 'an --only that matches nothing is a usage error, not a pass' );
like( $out, qr/no requested names matched/, 'and it says so' );

# --- the nightly job downloads nothing ---------------------------------------

ok( -x "$root/qa/installers/run.sh", 'the nightly freshness job is executable' );
is( system('bash', '-n', "$root/qa/installers/run.sh"), 0, 'it parses under bash' );

my $script = read_file("$root/qa/installers/run.sh");
my $bare   = join "\n", grep { !/^\s*#/ } split /\n/, $script;
like( $script, qr/--freshness/, 'the job runs the metadata check' );
like( $script, qr/--desktop/, 'and it covers the desktop app too' );
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

my $service = read_file("$root/qa/systemd/jawnos-qa-installers.service");
my $timer   = read_file("$root/qa/systemd/jawnos-qa-installers.timer");
like( $service, qr{ExecStart=/bin/bash \S+/qa/installers/run\.sh}, 'the unit runs the job' );
like( $timer, qr/OnCalendar=\*-\*-\* 03:45:00/, 'nightly at 03:45, ahead of the Docker smoke' );
unlike( $service, qr/device_target/, 'metadata only, so it is not gated on the QA machine' );
like( $service, qr/MemoryMax=1G/, 'a metadata check stays small' );

my $readme = read_file("$root/qa/README.md");
like( $readme, qr/installer package freshness/i, 'the QA README documents the job' );

done_testing;
