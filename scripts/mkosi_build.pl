#!/usr/bin/env perl
# Stage and build the JawnOS image with mkosi.
#
#   perl scripts/mkosi_build.pl               # stage, then build the live image
#   perl scripts/mkosi_build.pl --dry-run     # stage and print the command
#   perl scripts/mkosi_build.pl --stage-only  # stage only (no mkosi needed)
#
# mkosi must be installed on the machine that runs this (it is not installed
# here): `pip install mkosi`, or the distro's `mkosi` package. Building also
# needs root, network access to the Arch mirrors, and room in desktop/mkosi.
#
# Everything this script stages is output, not source: the tree copy, the repart
# definitions the installed system reuses, and the two systemd wants-links that
# would otherwise be symlinks in git. `.stage/` is gitignored.

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

GetOptions(
	'profile=s'   => \$profile,
	'output-dir=s'=> \$output,
	'dry-run'     => \$dry,
	'stage-only'  => \$stage_only,
) or die "usage: $0 [--profile live] [--output-dir DIR] [--dry-run] [--stage-only]\n";

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

# The tree, without the parts that are machine state or build output. `releases/`
# is a blob store and `database/` carries one machine's own view; neither may be
# baked into a distributable image.
my @exclude = (
	'.git', 'releases', 'database', '.shots', '.secrets', '.president',
	'desktop/mkosi/.stage', 'desktop/mkosi/output', 'node_modules',
);
my @args = ('-a');
foreach my $skip (@exclude) { push @args, '--exclude=' . $skip; }
print "staging the tree...\n";
system($rsync, @args, "$root/", "$tree/") == 0 or die "mkosi_build: rsync failed\n";

# First-run defaults, so the live image boots with options rather than a blank
# wizard. A real config.json (never committed) is left alone.
if (!-e "$tree/config.json" && -e "$tree/config.json.example") {
	system('cp', "$tree/config.json.example", "$tree/config.json") == 0
		or warn "mkosi_build: could not seed config.json\n";
}

# The installer reuses these definitions with `systemd-repart --size=auto`.
foreach my $def ( glob("$mkosi_dir/mkosi.repart/*.conf") ) {
	system('cp', $def, "$stage/usr/lib/jawnos/repart/") == 0
		or die "mkosi_build: could not stage $def\n";
}

# Units that must be on without a preset pass. mkosi copies the tree verbatim,
# and git cannot carry a symlink through this script's staging, so make them here.
my $wants = {
	"$stage/etc/systemd/system/local-fs.target.wants" => {
		'home-jawn.mount' => '../home-jawn.mount',
	},
	"$stage/etc/systemd/system/multi-user.target.wants" => {
		'jawnos-firstboot.service' => '../jawnos-firstboot.service',
		'getty@tty1.service'       => '/usr/lib/systemd/system/getty@tty1.service',
	},
};
foreach my $dir ( keys %{$wants} ) {
	make_path($dir);
	foreach my $name ( keys %{ $wants->{$dir} } ) {
		symlink($wants->{$dir}->{$name}, "$dir/$name")
			or warn "mkosi_build: could not link $dir/$name: $!\n";
	}
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
if (!$mkosi) {
	print STDERR "mkosi is not installed. Install it (pip install mkosi, or your\n"
		. "distro's mkosi package) and run this again. The stage is ready at:\n"
		. "  $stage\n";
	exit 1;
}

my @cmd = (
	$mkosi, "-C", $mkosi_dir, "--force", "--profile", $profile,
	"--extra-tree", $stage, "--output-dir", $output, "build",
);
if ($dry) {
	print "would run:\n  " . join(' ', @cmd) . "\n";
	exit 0;
}
print "building with mkosi ($profile)...\n";
exec(@cmd);
