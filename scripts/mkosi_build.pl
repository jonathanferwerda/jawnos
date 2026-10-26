#!/usr/bin/env perl
# Stage and build the JawnOS image with mkosi.
#
#   perl scripts/mkosi_build.pl               # stage, then build the live image
#   perl scripts/mkosi_build.pl --vm          # build, then boot it in a VM
#   perl scripts/mkosi_build.pl --vm --disk-size 32
#                                             # boot the VM with a 32G disk
#   perl scripts/mkosi_build.pl --dry-run     # stage and print the command
#   perl scripts/mkosi_build.pl --stage-only  # stage only (no mkosi needed)
#
# --disk-size GROWS the QEMU disk only; the built artefact stays at its minimum
# size (1G ESP + 5G root + 2G state) so the download stays small. The image's
# jawnos-grow service expands the state partition into the extra space at boot,
# exactly as it does on a USB stick.
#
# mkosi must be installed on the machine that runs this: `pip install mkosi`,
# or the distro's `mkosi` package. Building also needs root, network access to
# the Arch mirrors, and room in desktop/mkosi. Booting the result with --vm also
# needs qemu and an OVMF firmware package.
#
# Everything this script stages is output, not source: the tree copy and the
# repart definitions the installed system reuses. `.stage/` is gitignored.

use strict;
use warnings;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Getopt::Long qw(GetOptions);

my $root = abs_path(dirname(__FILE__) . '/..');
my $mkosi_dir = "$root/desktop/mkosi";
my $stage = "$mkosi_dir/.stage/extra";
my $output = "$mkosi_dir/output";
my $profile = 'live';
my $dry = 0;
my $stage_only = 0;
my $vm = 0;
my $disk_size;
my $disk_size_given = 0;

GetOptions(
	'profile=s'   => \$profile,
	'output-dir=s'=> \$output,
	'dry-run'     => \$dry,
	'stage-only'  => \$stage_only,
	'vm'          => \$vm,
	'disk-size=i' => sub { $disk_size = $_[1]; $disk_size_given = 1 },
) or die "usage: $0 [--profile live] [--output-dir DIR] [--disk-size GB] [--dry-run] [--stage-only] [--vm]\n";

# The image is built at 8G; a VM disk smaller than that cannot hold it, and a
# size under 10G leaves no room for the state partition to grow into.
$disk_size = 16 unless defined $disk_size;
if ($disk_size < 10 || $disk_size > 4096) {
	die "mkosi_build: --disk-size must be 10..4096 GB\n";
}
if ($disk_size_given && !$vm) {
	print "note: --disk-size only affects --vm; the built image stays at its minimum size\n";
}

sub need {
	my ($cmd) = @_;
	my @path = split /:/, ($ENV{'PATH'} || '');
	foreach my $dir (@path) {
		next unless length $dir;
		return "$dir/$cmd" if -f "$dir/$cmd" && -x "$dir/$cmd";
	}
	return undef;
}

my $rsync = need('rsync') or die "mkosi_build: rsync is required\n";

# A clean stage every run: a leftover file from an older tree would be baked into
# the image and would look like something JawnOS shipped.
system('rm', '-rf', $stage);
make_path("$stage/opt/jawnos", "$stage/usr/lib/jawnos/repart");

my $tree = "$stage/opt/jawnos/tree";
make_path($tree);

# The tree, without the parts that are machine state, secrets or build output.
# `releases/` is a blob store; the live database and its backups are this
# machine's own view; and `config.json` carries this builder's name, domain and
# signatorial - none of that may be baked into a distributable image. The
# database *sources* (schema.sql, initial.enc) do travel: first boot needs them
# to build a fresh database of its own.
#
# The firmware `.pio/` and `build/` trees are generated output, often several
# hundred MB, and nothing on a running JawnOS reads them. The one exception is
# `jp/alarmclock/build`, which is the manager's hardwired OTA path (see
# scripts/stage_firmware.pl), so it stays; the rest would bloat the download and
# the state partition firstboot copies them to.
my @exclude = (
	'.git', 'releases', '.shots', '.secrets', '.president', 'config.json',
	'desktop/mkosi/.stage', 'desktop/mkosi/output', 'node_modules',
	'database/*.db', 'database/*.db-shm', 'database/*.db-wal',
	'database/backups', 'database/.thumbs', 'database/.jawnos_signatorial_id',
	'jt/.pio', 'jt/build', 'jw/.pio', 'jw/build', 'jp/alarmclock/.pio',
);
my @args = ('-a');
foreach my $skip (@exclude) { push @args, '--exclude=' . $skip; }
print "staging the tree...\n";
system($rsync, @args, "$root/", "$tree/") == 0 or die "mkosi_build: rsync failed\n";

# First-run defaults, so the live image boots with a real config.json rather
# than a blank wizard. The defaults are the image's own (config.default.json),
# never this machine's config.json - that one was excluded above.
my $default_config = "$mkosi_dir/config.default.json";
if (!-e "$tree/config.json" && -e $default_config) {
	system('cp', $default_config, "$tree/config.json") == 0
		or die "mkosi_build: could not seed config.json\n";
}

# The installer reuses these definitions with `systemd-repart --size=auto`.
foreach my $def ( glob("$mkosi_dir/mkosi.repart/*.conf") ) {
	system('cp', $def, "$stage/usr/lib/jawnos/repart/") == 0
		or die "mkosi_build: could not stage $def\n";
}

# Executables the overlay carries. The repo keeps them 0755, but a fresh checkout
# on a filesystem that drops the bit would otherwise bake a non-runnable script.
foreach my $exe ( glob("$mkosi_dir/mkosi.extra/usr/local/bin/*") ) {
	chmod 0755, $exe;
}

print "staged: $stage\n";
if ($stage_only) {
	print "stage only; mkosi was not run.\n";
	exit 0;
}

my $mkosi = need('mkosi');
if (!$mkosi && !$dry) {
	print STDERR "mkosi is not installed. Install it (pip install mkosi, or your\n"
		. "distro's mkosi package) and run this again. On Arch:\n"
		. "  sudo pacman -S mkosi qemu-desktop edk2-ovmf systemd-ukify python-pefile mtools\n"
		. "The stage is ready at:\n  $stage\n";
	exit 1;
}

# Booting is a separate dependency. Check it before a long build rather than
# after, so a missing qemu does not cost half an hour of package fetching.
if ($vm && !$dry && !need('qemu-system-x86_64')) {
	print STDERR "qemu is not installed, so the image cannot be booted here.\n"
		. "On Arch: sudo pacman -S qemu-desktop edk2-ovmf\n"
		. "Or build only (without --vm) and boot the .raw on another machine.\n";
	exit 1;
}

my @cmd = (
	($mkosi || 'mkosi'), "-C", $mkosi_dir, "--force", "--profile", $profile,
	"--extra-tree", $stage, "--output-dir", $output,
	($vm ? ('--runtime-size', "${disk_size}G") : ()),
	($vm ? 'vm' : 'build'),
);
if ($dry) {
	print "would run:\n  " . join(' ', @cmd) . "\n";
	exit 0;
}
print "building with mkosi ($profile)...\n";
exec(@cmd);
