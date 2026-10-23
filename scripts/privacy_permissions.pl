#!/usr/bin/env perl
# Close the permissions on everything this install keeps private.
#
# The tree ships with a private umask (jawn sets 077 and the systemd units set
# UMask=0077), but that only covers files created from now on. This is the
# one-time pass for what is already on disk, and it can be re-run after a
# restore or an upgrade that unpacked files with the wrong mode.
#
# What it changes:
#   database/           0700, everything inside 0600
#     jawnos.db, -wal, -shm, initial.enc, backups/*.enc, thumbs/, schema.sql
#   config.json         0600        (host, ports and the install's own settings)
#   .secrets/           0700, files 0600
#   .shots/             0700, files 0600   (ticket.txt is a live credential)
#   ~/manager.log       0600
#   ~/.president/       0700, files 0600   (status + plaintext export temporaries)
#   ~/.local/state/jawnos/  0700, files 0600
#   ~/.house.key        0600
#   ~/.jawnos_paper_shares/ 0700, files 0600
#
# It never follows a symlink and never changes the execute bit, so scripts and
# the jawn launcher keep working. Tracked files are only touched inside
# database/, and git does not record 0644 vs 0600.
#
#   perl scripts/privacy_permissions.pl            # apply
#   perl scripts/privacy_permissions.pl --dry-run  # list only
#   perl scripts/privacy_permissions.pl --root DIR # when run from a copy
use strict;
use warnings;
use FindBin;
use File::Find ();

my $dry = 0;
my $root = '';
for (my $i = 0; $i < @ARGV; $i++) {
	my $arg = $ARGV[$i];
	if ($arg eq '--dry-run') { $dry = 1; next; }
	if ($arg eq '--root') { $root = defined $ARGV[$i + 1] ? $ARGV[++$i] : ''; next; }
	if ($arg eq '--help' || $arg eq '-h') {
		print "usage: $0 [--dry-run] [--root DIR]\n";
		exit 0;
	}
	die "unknown argument: $arg\n";
}

my $home = $ENV{HOME} || (getpwuid $<)[7] || '';
if (!length $root) {
	# Run from the tree, or from a copy in /tmp (the deploy does that): take the
	# first directory that really looks like an install.
	foreach my $try ("$FindBin::Bin/..", "$home/jawnos") {
		if (-f "$try/Manager.pl" && -d "$try/database") { $root = $try; last; }
	}
}
die "cannot find the jawn install; pass --root DIR\n" unless length $root && -d $root && -f "$root/Manager.pl";
$root =~ s{/+$}{};

my (@changed, @failed);
sub tighten {
	my ($mode, @paths) = @_;
	foreach my $path (@paths) {
		next unless defined $path && length $path && -e $path;
		next if -l $path;
		my $now = (stat $path)[2] & 07777;
		# Keep the execute bits only where a shebang says the file is meant to be
		# run directly. config.json is 0755 on older installs by accident; it must
		# become 0600, while an installer or probe with #! keeps its 0100.
		my $exec = 0;
		if (-f $path && ($now & 0111)) {
			if (open(my $head, '<', $path)) { binmode $head; read($head, my $two, 2); close $head; $exec = 0111 if ($two || '') eq '#!'; }
		}
		my $target = $exec ? 0700 : $mode;
		next if $now == $target;
		if (!$dry && !chmod $target, $path) {
			push @failed, "$path: $!";
			next;
		}
		push @changed, sprintf '%04o -> %04o  %s', $now, $target, $path;
	}
}
sub tighten_tree {
	my ($dir_mode, $file_mode, $top) = @_;
	return unless -d $top && !-l $top;
	File::Find::find({
		no_chdir => 1,
		wanted => sub {
			my $path = $File::Find::name;
			return if -l $path;
			&tighten(-d $path ? $dir_mode : $file_mode, $path);
		}
	}, $top);
}

&tighten(0700, "$root/database", "$root/database/backups", "$root/database/thumbs",
	"$root/.secrets", "$root/.shots",
	"$home/.president", "$home/.local/state/jawnos", "$home/.jawnos_paper_shares");
&tighten(0600, "$root/config.json", "$root/.shots/ticket.txt", "$home/manager.log", "$home/.house.key");

# The whole database tree, so the WAL, the SHM, the factory seed, the sealed
# backups, the signatorial id and the thumbnails are covered by one rule.
&tighten_tree(0700, 0600, "$root/database");
&tighten_tree(0700, 0600, "$root/.secrets");
&tighten_tree(0700, 0600, "$home/.president");
&tighten_tree(0700, 0600, "$home/.local/state/jawnos");
&tighten_tree(0700, 0600, "$home/.jawnos_paper_shares");

my $shown = 0;
foreach my $line (@changed) {
	last if $shown++ >= 25;
	print $line, "\n";
}
print '  ... and ', scalar(@changed) - $shown, " more\n" if scalar(@changed) > $shown;
foreach my $line (@failed) { print STDERR "failed: $line\n"; }
printf "%s %d file%s%s\n",
	$dry ? 'would tighten' : 'tightened',
	scalar @changed,
	@changed == 1 ? '' : 's',
	scalar @failed ? ' (with ' . scalar(@failed) . ' failure' . (@failed == 1 ? '' : 's') . ')' : '';
exit(@failed ? 1 : 0);
