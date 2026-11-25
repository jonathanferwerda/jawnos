# tests-for: scripts/gou_image_build.sh
# covers:    The eMMC image carries the static arm64 Tailscale build so the
#            first boot can join the tailnet: the two binaries, the state
#            directory, the unit and its multi-user wants link, a staged
#            tarball or the pinned stable URL, and a skip (not a failure) when
#            neither is available. Also the /dev/net/tun note, since the image
#            installs the daemon but never changes the kernel.

use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);

my $root = "$Bin/..";
my $script = "$root/scripts/gou_image_build.sh";

ok(-f $script, 'scripts/gou_image_build.sh exists');

my $syntax = `bash -n "$script" 2>&1`;
is($?, 0, 'bash -n accepts the script') or diag $syntax;

my $source = read_file($script);

# The binaries go where the first boot looks for them.
like($source, qr{install -m 755 "\$top/tailscale"\s+"\$root/usr/bin/tailscale"},
	'tailscale is installed at /usr/bin/tailscale');
like($source, qr{install -m 755 "\$top/tailscaled"\s+"\$root/usr/sbin/tailscaled"},
	'tailscaled is installed at /usr/sbin/tailscaled');
like($source, qr{install -d -m 700 "\$root/var/lib/tailscale"},
	'the state directory is created 0700');
like($source, qr{install_tailscale "\$root"},
	'apply_fixes installs it, so build and repair both carry it');

# The unit, at the path systemd reads, with the paths the installer wrote.
like($source, qr{etc/systemd/system/tailscaled\.service},
	'the unit is written under /etc/systemd/system');
like($source,
	qr{ExecStart=/usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled\.state --socket=/run/tailscale/tailscaled\.sock},
	'ExecStart names the installed daemon, state and socket');
like($source, qr{ExecStopPost=/usr/bin/tailscale down},
	'the unit brings the node down after a stop');
like($source, qr{RuntimeDirectory=tailscale}, 'the runtime directory is declared');
like($source, qr{RuntimeDirectoryMode=0750}, 'with mode 0750');
like($source, qr{StateDirectory=tailscale}, 'the state directory is declared');
like($source, qr{StateDirectoryMode=0700}, 'with mode 0700');
like($source, qr{WantedBy=multi-user\.target}, 'the unit wants multi-user.target');

# systemctl cannot run against a mounted image; the enable link is written.
like($source, qr{ln -sfn /etc/systemd/system/tailscaled\.service},
	'the enable link points at the unit as the board sees it');
like($source, qr{multi-user\.target\.wants/tailscaled\.service},
	'under multi-user.target.wants');

# Tarball source: staged first, pinned URL second.
like($source, qr{--tailscale-tgz}, 'a staged tarball can be named on the command line');
like($source, qr{TAILSCALE_TGZ}, 'or supplied in the environment');
like($source, qr{TAILSCALE_TGZ="\$\{TAILSCALE_TGZ:-\}"},
	'the environment is read, not required');
like($source, qr{TAILSCALE_VERSION="\$\{TAILSCALE_VERSION:-1\.\d+\.\d+\}"},
	'the version is pinned');
like($source,
	qr{https://pkgs\.tailscale\.com/stable/tailscale_\$\{TAILSCALE_VERSION\}_arm64\.tgz},
	'the default URL is the arm64 static tarball');
like($source, qr{tailscale_\*_arm64},
	'the tarball layout is the top directory the build expects');

# An explicit tarball is checked; a missing download is only a warning.
like($source, qr{invalid tailscale tarball}, 'an explicit tarball that will not unpack fails the build');
like($source, qr{die "no such tailscale tarball}, 'an explicit tarball that is absent fails the build');
like($source, qr{skipping \(the board stays a LAN peer\)},
	'an unavailable default download skips with a warning');
like($source, qr{no staged tarball and neither curl nor wget},
	'and a host with no downloader skips too');

# The kernel is not this script's business, but the requirement is documented.
like($source, qr{/dev/net/tun}, 'the header names /dev/net/tun');
like($source, qr{does not build or}, 'and says the kernel is not modified');

# The option parses, and a dry run still needs no root and no tarball.
my $help = `bash "$script" --help 2>&1`;
is($?, 0, '--help exits 0');
like($help, qr/--tailscale-tgz/, '--help names --tailscale-tgz');

my $dir = tempdir(CLEANUP => 1);
write_file("$dir/dump.img", "x" x 1024);
write_file("$dir/stock.img", "y" x 1024);
my $dry = `bash "$script" build --from "$dir/dump.img" --out "$dir/out.img" --stock-backup "$dir/stock.img" --tailscale-tgz "$dir/absent.tgz" --dry-run 2>&1`;
is($?, 0, 'build --dry-run accepts --tailscale-tgz without the tarball present');
like($dry, qr/plan:/, 'and still prints the plan');

done_testing();
