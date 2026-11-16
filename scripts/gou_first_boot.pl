#!/usr/bin/perl
#
# gou_first_boot.pl - what a flashed ODROID Go Ultra does before the house does.
#
#   perl scripts/gou_first_boot.pl [--dry-run] [--format] [--no-join] [--no-card]
#                                  [--token PATH] [--device PATH] [--mount PATH]
#
# The provisioner writes two things into the image while the board is still in
# recovery: .controller-join.json (the house's address and a single-use secret)
# and the systemd unit that runs this script before jawnos.service. On the first
# boot this script:
#
#   1. finds the board's SD card, and either adopts what is already on it or
#      makes it the archive (see the rules below);
#   2. redeems the join token at the house, which files this board on the house's
#      roster with the grant a citizen's own machine carries;
#   3. files the house on this board's own roster, so the first sync has an
#      address to call without waiting for a discovery pass.
#
# Then it removes the token and exits 0. With no token it is a no-op, so the
# unit stays enabled and costs nothing on later boots.
#
# The card rules, in order:
#   - an ext4/ext3/xfs/btrfs card is adopted as it stands: the eight folders are
#     scaffolded into it and nothing on it is removed;
#   - a card with no filesystem is only formatted with --format;
#   - a card with some other filesystem (vfat, exfat, ntfs) is left alone and
#     reported, because it is somebody's data until a person says otherwise;
#     --format is what says so.
# An adopted card is mounted at --mount (default /media/jawn/SD) and named in
# /etc/fstab by UUID with nofail, so the archive root survives a reboot with no
# card in the slot.
#
# Both modes print JSON on stdout and every human word on stderr, like the
# provisioner. Exit codes: 0 ok, 6 the token could not be redeemed, 7 the card
# could not be prepared.

use strict;
use warnings;

use Cwd ();
use FindBin qw($Bin);
use File::Basename ();
use File::Path ();
use Getopt::Long ();
use JSON::PP ();

use lib "$Bin/../lib";
use JawnOS::Platform::Paths ();

chdir Cwd::abs_path("$Bin/..") or die "gou_first_boot: cannot find the jawnos root\n";
&_config_bootstrap();
require './perl/subroutines.pl';

my $JSON = JSON::PP->new->utf8(1)->canonical(1);
my $DEFAULT_TOKEN = '~/jawnos/.controller-join.json';
my $DEFAULT_MOUNT = '/media/jawn/SD';
my $DEFAULT_LABEL = 'JAWNOS-SD';

my %opt;
Getopt::Long::Configure('no_ignore_case');
Getopt::Long::GetOptions(
	'dry-run'   => \$opt{'dry_run'},
	'format'    => \$opt{'format'},
	'no-join'   => \$opt{'no_join'},
	'no-card'   => \$opt{'no_card'},
	'token=s'   => \$opt{'token'},
	'device=s'  => \$opt{'device'},
	'mount=s'   => \$opt{'mount'},
	'help|h'    => \$opt{'help'},
) or _fail(7, 'bad options');

if ($opt{'help'}) {
	print <<'USAGE';
gou_first_boot.pl [--dry-run] [--format] [--no-join] [--no-card]
                  [--token PATH] [--device PATH] [--mount PATH]
USAGE
	exit 0;
}

# ---------------------------------------------------------------------------
# Output

# Every Perl entrypoint loads config.json while perl/subroutines.pl compiles.
# An image built by gou_image_build.sh has none on purpose - the config is
# machine identity, not image content - so the first boot seeds one here, as
# ./jawn does on a fresh install. The seed runs as the account that owns the
# tree: the config, the database and the identity it writes all belong to that
# account, not to root, and the service that starts after this pass has to be
# able to write them.
sub _config_bootstrap {
	my $config = JawnOS::Platform::Paths::config_path();
	return if -e $config && -s $config > 20;
	my $name = &_board_name();
	my ($uid, $gid, $home) = &_tree_owner();
	my @seed = ($^X, 'scripts/jawnos_setup.pl',
		'--seed', '--device', 'controller', '--name', $name, '--language', 'en');
	my $user = $uid ? (getpwuid($uid))[0] : '';
	if ($< == 0 && defined $user && length $user && length $home && $uid != 0) {
		@seed = ('runuser', '-u', $user, '--', 'env', 'HOME=' . $home, @seed);
	}
	my ($said, $status) = &_capture(@seed);
	print STDERR $said if length $said;
	# The seed mints this machine's unlock code and puts it in the level-1
	# canary, then prints it once and keeps it nowhere. local_code_suds reads it
	# from the file beside the house, so without this line the board has no
	# candidate key: the vault is never seeded, the box office refuses the
	# kiosk's own ticket and the board parks at the Gate.
	if ($said =~ /^JAWNOS_UNLOCK_CODE=([0-9]{4,12})\s*$/m) {
		my $path = "$home/UNLOCK-CODE.txt";
		if (open(my $fh, '>', $path)) {
			print {$fh} "$1\n";
			close $fh;
			chmod 0600, $path;
			chown $uid, $gid, $path if $< == 0;
		}
	}
	unless (-e $config && -s $config > 20) {
		# The seed could not run (an image with no setup script, a failed
		# database build). Leave a config the tree can load; ./jawn sees no
		# signatorial and finishes the seed on its own first start.
		my $placeholder = {
			name => $name, device => 'controller',
			logfile => '~/manager.log', environment => 'production',
			domain => '127.0.0.1', port => '3000', working_port => '45545',
		};
		my $dir = File::Basename::dirname($config);
		File::Path::make_path($dir) unless -d $dir;
		if (open(my $fh, '>', $config)) {
			print {$fh} JSON::PP->new->canonical->pretty->utf8->encode($placeholder);
			close $fh;
			chmod 0644, $config;
			chown $uid, $gid, $config if $< == 0;
		}
		print STDERR "gou_first_boot: the config seed did not finish (status $status); wrote a placeholder\n";
	}
	chown $uid, $gid, $config if $< == 0 && -e $config;
}

sub _board_name {
	my $name = '';
	if (open(my $fh, '<', '/etc/hostname')) {
		$name = <$fh> // '';
		close $fh;
	}
	$name =~ s/^\s+|\s+$//g if defined $name;
	return 'gou' unless defined $name && $name =~ /^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$/;
	return $name;
}

sub _tree_owner {
	my @stat = stat(Cwd::abs_path('.'));
	return (0, 0, '') unless @stat;
	my @pw = getpwuid($stat[4]);
	return ($stat[4], $stat[5], ($pw[7] // ''));
}

sub _capture {
	my (@args) = @_;
	open my $fh, '-|', @args or return ('', -1);
	local $/;
	my $said = <$fh>;
	close $fh;
	return ((defined $said ? $said : ''), $? >> 8);
}

sub _emit {
	my ($data, $code) = @_;
	print $JSON->encode($data), "\n";
	exit(defined $code ? $code : 0);
}

sub _note {
	my ($message) = @_;
	$message = '' unless defined $message;
	$message =~ s/\s+/ /g;
	print STDERR "gou_first_boot: $message\n" if length $message;
}

sub _fail {
	my ($code, $message) = @_;
	_note($message);
	_emit({ ok => 0, error => $message }, $code);
}

# ---------------------------------------------------------------------------
# The token

# A token is the house's word that a citizen pressed New for this board. It is
# read once and never rewritten: the boot either redeems it or leaves it for a
# later boot, and a token the house has already spent comes back as an error.
# A token is the house's word that a citizen pressed New for this board. It is
# read once and never rewritten: the boot either redeems it or leaves it for a
# later boot, and a token the house has already spent comes back as an error.
sub _token_read {
	my ($path) = @_;
	$path = $DEFAULT_TOKEN unless defined $path && length $path;
	my $file = &subs::home($path);
	return { absent => 1, path => $file } unless -f $file;
	my $raw = '';
	if (open(my $fh, '<', $file)) {
		local $/;
		$raw = <$fh> // '';
		close $fh;
	}
	my $token = eval { $JSON->decode($raw) };
	return { error => 'the join token is not JSON', path => $file } unless ref $token eq 'HASH';
	return { error => 'the join token is not a JawnOS join token', path => $file }
		unless ($token->{'kind'} // '') eq 'jawnos-controller-join';
	return { error => 'the join token carries no secret', path => $file }
		unless ($token->{'secret'} // '') =~ /^[A-Za-z0-9]{16,64}$/;
	my $house = ref $token->{'house'} eq 'HASH' ? $token->{'house'} : {};
	return { error => 'the join token names no house', path => $file }
		unless ($house->{'manager'} // '') =~ m{^https?://};
	return { error => 'the join token has expired', path => $file }
		if defined $token->{'expires'} && $token->{'expires'} =~ /^\d+$/ && $token->{'expires'} < &subs::rightNow();
	return { path => $file, token => $token, house => $house };
}

# ---------------------------------------------------------------------------
# The card

# lsblk's answer, in bytes and as JSON: the whole tree, so a card's partition
# carries its own FSTYPE and MOUNTPOINT. A file path in JAWNOS_GOU_LSBLK_FILE
# stands in for the command, which is how the plan is tested without a card.
sub _lsblk {
	my $path = $ENV{'JAWNOS_GOU_LSBLK_FILE'} || '';
	if (length $path) {
		my $raw = '';
		if (open(my $fh, '<', $path)) { local $/; $raw = <$fh> // ''; close $fh; }
		return eval { $JSON->decode($raw) };
	}
	my $raw = '';
	if (open(my $fh, '-|', 'lsblk', '-J', '-b', '-o', 'NAME,TYPE,SIZE,RM,FSTYPE,MOUNTPOINT,LABEL,MODEL')) {
		local $/;
		$raw = <$fh> // '';
		close $fh;
	}
	return eval { $JSON->decode($raw) };
}

# The disk the running system is on: never a candidate, whatever it reports.
sub _root_disk_name {
	my $source = '';
	if (open(my $fh, '-|', 'findmnt', '-no', 'SOURCE', '/')) {
		$source = <$fh> // '';
		close $fh;
	}
	$source =~ s/\s+$//;
	return '' unless length $source;
	$source =~ s{\[.*$}{};
	# /dev/mmcblk1p2 -> mmcblk1, /dev/sda2 -> sda, /dev/nvme0n1p2 -> nvme0n1
	return $1 if $source =~ m{/dev/(mmcblk\d+|nvme\d+n\d+)p?\d*$};
	return $1 if $source =~ m{/dev/([A-Za-z]+)\d*$};
	return '';
}

# Every disk lsblk shows whose device says it is removable, biggest first. The
# USB gadget the recovery mode presents is not removable on this side (it is a
# cable), and the root disk is excluded by name, so what is left is the slot.
sub _card_candidates {
	my ($tree) = @_;
	my @found;
	my $root = &_root_disk_name();
	foreach my $disk ( @{ ($tree && ref $tree->{'blockdevices'} eq 'ARRAY') ? $tree->{'blockdevices'} : [] } ) {
		next unless ref $disk eq 'HASH';
		next unless ($disk->{'type'} // '') eq 'disk';
		next unless &_truthy($disk->{'rm'});
		next if length $root && ($disk->{'name'} // '') eq $root;
		next unless (($disk->{'size'} // 0) + 0) > 0;
		my $part;
		foreach my $child ( @{ (ref $disk->{'children'} eq 'ARRAY') ? $disk->{'children'} : [] } ) {
			next unless ref $child eq 'HASH';
			next unless ($child->{'type'} // '') eq 'part';
			next unless length($child->{'fstype'} // '');
			$part = $child;
			last;
		}
		$part ||= (ref $disk->{'children'} eq 'ARRAY' && ref $disk->{'children'}->[0] eq 'HASH') ? $disk->{'children'}->[0] : $disk;
		push @found, {
			dev => '/dev/' . ($part->{'name'} // $disk->{'name'} // ''),
			disk => '/dev/' . ($disk->{'name'} // ''),
			size => ($disk->{'size'} // 0) + 0,
			fstype => ($part->{'fstype'} // '') . '',
			mount => ($part->{'mountpoint'} // '') . '',
			label => ($part->{'label'} // '') . '',
			model => ($disk->{'model'} // '') . '',
		};
	}
	@found = sort { $b->{'size'} <=> $a->{'size'} } @found;
	return @found;
}

sub _truthy {
	my ($value) = @_;
	return 0 unless defined $value;
	return $value ? 1 : 0;
}

# What to do with one card. Pure: the caller has already probed it, so the
# rules can be read and tested without a block device.
#   adopt   the card is usable where it is; scaffold the eight folders
#   format  the card has no usable filesystem, or a person said so
#   leave   another filesystem, and nobody has chosen yet
# `format` is the command-line switch; `choice` is the person's answer from the
# house's Controllers page, and the answer outranks the switch.
sub _card_plan {
	my ($card, $opts) = @_;
	$opts ||= {};
	return { state => 'none' } unless $card;
	my $fs = lc($card->{'fstype'} // '');
	my $state = !length $fs ? 'blank'
		: ($fs =~ /^(?:ext[234]|xfs|btrfs)$/ ? 'archive' : 'foreign');
	my $choice = ($opts->{'choice'} // '') =~ /^(adopt|format)$/ ? $opts->{'choice'} : '';
	my $action;
	if ($state eq 'archive') { $action = 'adopt'; }
	# A card with no filesystem cannot be adopted: there is nothing to mount.
	# The answer travels in the token before the person can see the card, so the
	# desk's "a card with no filesystem can only be formatted" has to hold here
	# too - an adopt answer leaves it alone for a later boot.
	elsif ($state eq 'blank') { $action = ($choice eq 'format' || $opts->{'format'}) ? 'format' : 'leave'; }
	elsif ($choice eq 'format' || $opts->{'format'}) { $action = 'format'; }
	elsif ($choice eq 'adopt') { $action = 'adopt'; }
	else { $action = 'leave'; }
	return {
		state => $state,
		action => $action,
		choice => $choice,
		description => (
			$state eq 'archive' ? 'a card ready to hold the archive'
			: $state eq 'blank' ? 'a card with no filesystem'
			: 'a card with another filesystem on it'
		),
		dev => $card->{'dev'},
		fstype => $fs,
		size => $card->{'size'},
		mount => $card->{'mount'},
		label => $card->{'label'},
	};
}

# The finding and the choice ride the settings table, which is this machine's
# own row for a setting and is synced, so the Controllers page on the house can
# read what the board found and answer it. The board writes under its own
# signatorial, which is how every per-device setting already travels.
sub _card_setting_write {
	my ($setting, $value) = @_;
	my $sig = &subs::signatorial_designer() || '';
	return { ok => 0, error => 'this machine has no signatorial yet' } unless length $sig;
	my $now = &subs::rightNow();
	my $row = &subs::db_select('settings', undef, { app => '__president', setting => $setting, device => $sig })->hash;
	if ($row) {
		&subs::db_update('settings', { value => $value, server_time => $now }, { uuid => $row->{'uuid'} });
	}
	else {
		&subs::db_insert('settings', {
			uuid => &subs::random_string_creator(25),
			app => '__president',
			setting => $setting,
			device => $sig,
			value => $value,
			timestamp => $now,
			server_time => $now,
		});
	}
	return { ok => 1 };
}

sub _card_setting_clear {
	my ($setting) = @_;
	my $sig = &subs::signatorial_designer() || '';
	return unless length $sig;
	&subs::db_delete('settings', { app => '__president', setting => $setting, device => $sig });
}

# The Controllers page can only offer a choice if it is told what the slot holds.
# One settings row per machine, written on every pass that saw a card; the page
# answers it through card_choice.
sub _card_report {
	my ($plan, $prepared) = @_;
	my $finding = {
		state => $plan->{'state'},
		action => $plan->{'action'},
		fstype => $plan->{'fstype'} || '',
		size => $plan->{'size'} || 0,
		label => $plan->{'label'} || '',
		dev => $plan->{'dev'} || '',
	};
	$finding->{'archive_dir'} = $prepared->{'archive_dir'} if $prepared && $prepared->{'archive_dir'};
	my $wrote = &_card_setting_write('card_finding', $JSON->encode($finding));
	return $wrote->{'ok'} ? 1 : 0;
}

sub _card_choice_read {
	my $sig = &subs::signatorial_designer() || '';
	return '' unless length $sig;
	my $value = eval { &subs::setting_grabber({ app => '__president', setting => 'card_choice', device => $sig }) } || '';
	return $value =~ /^(adopt|format)$/ ? $value : '';
}

# ---------------------------------------------------------------------------
# The house's files

# The archive root lives in config.json, which is this machine's own file and is
# never synced. The whole object is written back, not a merged view, so nothing
# a person set there is lost.
sub _config_archive_dir {
	my ($dir) = @_;
	my $path = eval { JawnOS::Platform::Paths::config_path(root => Cwd::abs_path('.')) } || 'config.json';
	my $config = {};
	if (-f $path) {
		my $raw = '';
		if (open(my $fh, '<', $path)) { local $/; $raw = <$fh> // ''; close $fh; }
		$config = eval { $JSON->decode($raw) } || {};
	}
	return { ok => 0, error => 'config.json could not be read' } unless ref $config eq 'HASH';
	$config->{'archive_dir'} = $dir;
	my $tmp = $path . '.new';
	my $ok = open(my $out, '>', $tmp);
	return { ok => 0, error => 'config.json could not be written' } unless $ok;
	print {$out} $JSON->pretty->encode($config);
	close $out;
	# An install that runs as jawn keeps config.json's owner; root writing it
	# here must not leave a file the service cannot write. A config that did not
	# exist yet (the image drops it, and the bootstrap may have written only a
	# placeholder) belongs to the tree's account too.
	my @stat = stat($path);
	if (@stat) { chown($stat[4], $stat[5], $tmp) }
	else {
		my ($uid, $gid) = &_tree_owner();
		chown($uid, $gid, $tmp);
	}
	rename($tmp, $path) or return { ok => 0, error => 'config.json could not be replaced' };
	return { ok => 1, path => $path };
}

sub _fstab_add {
	my ($dev, $mount, $fstype) = @_;
	my $path = '/etc/fstab';
	my $raw = '';
	if (open(my $fh, '<', $path)) { local $/; $raw = <$fh> // ''; close $fh; }
	return { ok => 0, error => '/etc/fstab could not be read' } unless length $raw || -z $path;
	return { ok => 1, already => 1 } if $raw =~ m{\s\Q$mount\E\s};
	my $uuid = '';
	if (open(my $fh, '-|', 'blkid', '-s', 'UUID', '-o', 'value', $dev)) { $uuid = <$fh> // ''; close $fh; }
	$uuid =~ s/\s+$//;
	return { ok => 0, error => 'the card has no UUID' } unless length $uuid;
	# A card adopted with its own filesystem keeps its own type in fstab; an
	# entry that named ext4 for an exfat card would fail to mount on the reboot.
	my $type = ($fstype // '') =~ /^(?:ext[234]|xfs|btrfs|vfat|exfat|ntfs)$/ ? $fstype : 'auto';
	# A vfat/exfat/ntfs card has no Unix owners of its own: the mount options are
	# what give the service (which runs as jawn, not root) a card it can write.
	my $owners = '';
	if ($type =~ /^(?:vfat|exfat|ntfs)$/) {
		my ($uid, $gid) = &_tree_owner();
		$owners = 'uid=' . $uid . ',gid=' . $gid . ',umask=0077,';
	}
	my $line = 'UUID=' . $uuid . ' ' . $mount . ' ' . $type . ' ' . $owners
		. 'defaults,nofail,x-systemd.device-timeout=10 0 2' . "\n";
	$raw .= "\n" unless $raw =~ /\n$/ || !length $raw;
	my $ok = open(my $out, '>>', $path);
	return { ok => 0, error => '/etc/fstab could not be written' } unless $ok;
	print {$out} $line;
	close $out;
	return { ok => 1, uuid => $uuid };
}

# Mount the card where the archive root will be, make the eight folders and
# record the root. The scaffold is the house's own helper, so the folder list
# cannot drift from the one every reader uses.
sub _card_adopt {
	my ($plan, $opts) = @_;
	my $mount = $opts->{'mount'} || $DEFAULT_MOUNT;
	my @done;
	my $mounted_here = 0;
	my $where = $plan->{'mount'};
	if (!length $where) {
		File::Path::make_path($mount) unless -d $mount;
		my $rc = system('mount', $plan->{'dev'}, $mount);
		return { ok => 0, error => "could not mount $plan->{'dev'}" } if $rc != 0;
		$where = $mount;
		$mounted_here = 1;
	}
	$plan->{'archive_dir'} = $where;
	my $fstab = &_fstab_add($plan->{'dev'}, $where, $plan->{'fstype'});
	push @done, 'fstab' if $fstab->{'ok'} && !$fstab->{'already'};
	my $scaffold = eval { &subs::archive_scaffolder($where) } || {};
	if ($scaffold->{'enabled'}) {
		push @done, 'folders';
		# The mount is root's for this pass, but the folders are the service's:
		# an adopted card's existing files keep their owners, and only the folders
		# this pass made are given to the tree's account.
		if ($< == 0) {
			my ($uid, $gid) = &_tree_owner();
			foreach my $location ( @{ $scaffold->{'created'} || [] } ) {
				my $path = eval { &subs::archive_location_folder($where, $location) } || '';
				chown($uid, $gid, $path) if length $path && -e $path;
			}
		}
	}
	my $config = &_config_archive_dir($where);
	return { ok => 0, error => $config->{'error'} } unless $config->{'ok'};
	push @done, 'archive_dir';
	# The mount was only ours to make for this pass; leave the card as it was.
	system('umount', $where) if $mounted_here;
	return {
		ok => 1,
		archive_dir => $where,
		done => \@done,
		($fstab->{'ok'} ? () : (fstab_error => $fstab->{'error'})),
	};
}

sub _card_format {
	my ($plan, $opts) = @_;
	my $mount = $opts->{'mount'} || $DEFAULT_MOUNT;
	my $rc = system('mkfs.ext4', '-F', '-L', $DEFAULT_LABEL, $plan->{'dev'});
	return { ok => 0, error => "could not format $plan->{'dev'}" } if $rc != 0;
	$plan->{'fstype'} = 'ext4';
	$plan->{'mount'} = '';
	return &_card_adopt($plan, $opts);
}

# ---------------------------------------------------------------------------
# The join

# A flashed board is a new machine, but the image is a copy of the card it was
# built from: it carries that card's identity, and two boards sharing one would
# overwrite each other's roster row on the house. The provisioner removes the
# identity files from the image for exactly this reason, so an absent identity
# here is a board that has never had one - mint it before anything reads the
# house's rows. An identity that is already there is left alone: a second boot
# after a refused join must not churn it.
# The unit runs as root (mount and mkfs need it) with HOME pointing at the
# board's own account, so the files this pass writes in that home - the identity,
# the peer key - have to end up owned by the account the service runs as. The
# tree's own owner is that account.
sub _own_by_tree {
	my @paths = @_;
	my @tree = stat(Cwd::abs_path('.'));
	return unless @tree;
	foreach my $path ( @paths ) {
		next unless defined $path && length $path && -e $path;
		chown($tree[4], $tree[5], $path);
	}
}

# This pass runs as root with HOME pointing at the board's own account, so every
# file the tree opens while it works lands owned by root: its log, its runtime
# dir, the socket ledger. The manager runs as that account, and a root-owned
# manager.log or run/ leaves it printing one server line and dying with EACCES -
# the panel then shows a dead page on a board that booted perfectly. Hand them
# back on every exit path, a failed join included.
sub _hand_back_runtime {
	my ($uid, $gid, $home) = &_tree_owner();
	return unless $uid && $uid != 0 && length $home;
	# An empty log owned by root is not a log: dropping it lets the manager
	# create its own on the first write, which it can then append to.
	my $log = "$home/manager.log";
	if (-f $log && -z $log && (stat($log))[4] == 0) {
		unlink $log;
	}
	# A runtime dir is a tree, and its children carry the same ownership.
	my @queue = grep { -d $_ } ("$home/jawnos/run", "$home/.president");
	while (my $dir = shift @queue) {
		chown $uid, $gid, $dir;
		opendir(my $dh, $dir) or next;
		foreach my $entry (grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
			my $path = "$dir/$entry";
			if (-d $path && !-l $path) { push @queue, $path }
			else { chown $uid, $gid, $path }
		}
		closedir $dh;
	}
	&_own_by_tree($log, "$home/.process_watch");
	return 1;
}

END { eval { $< == 0 && !$opt{'dry_run'} && &_hand_back_runtime() } }

# The kiosk window's own state. The desktop shell records its last window on
# quit and, with nothing recorded, falls back to a 1100x820 window - on this
# 854x480 panel the launcher then lays four columns into 1100 px and the person
# sees three tiles and the top of a second row. The scrub removes the source
# card's copy along with its ticket store, so seed the one state a board wants.
sub _desktop_shell_state {
	my ($uid, $gid, $home) = &_tree_owner();
	return 0 unless length $home;
	my $dir = "$home/.config/jawnos";
	my $path = "$dir/desktop.json";
	# Whatever the shell last recorded is the person's own choice, so never
	# overwrite it - only fill the hole a copied card leaves behind.
	return 0 if -e $path;
	File::Path::make_path($dir) unless -d $dir;
	my $tmp = "$path.tmp";
	return 0 unless open(my $out, '>', $tmp);
	print {$out} JSON::PP->new->canonical->pretty->encode({ fullscreen => \1 });
	close $out;
	chmod 0600, $tmp;
	chown $uid, $gid, $tmp if $< == 0;
	return 0 unless rename($tmp, $path);
	chown $uid, $gid, $dir if $< == 0;
	return 1;
}

sub _own_database {
	my $database = eval { &subs::database_path() } || '';
	return unless length $database;
	&_own_by_tree($database, $database . '-wal', $database . '-shm', File::Basename::dirname($database));
}

sub _kiosk_ticket {
	my $script = 'scripts/app_ticket.pl';
	return 0 unless -f $script;
	my ($uid, $gid, $home) = &_tree_owner();
	my @command = ($^X, $script, 'desktop', '--save');
	my $user = $uid ? (getpwuid($uid))[0] : '';
	if ($< == 0 && defined $user && length $user && length $home && $uid != 0) {
		@command = ('runuser', '-u', $user, '--', 'env', 'HOME=' . $home, @command);
	}
	my ($said, $status) = &_capture(@command);
	# $said is the URL; do not print it. Only --save's 0600 file is kept.
	my $shots = Cwd::abs_path('.') . '/.shots';
	File::Path::make_path($shots) unless -d $shots;
	&_own_by_tree($shots, $shots . '/ticket.txt');
	print STDERR "gou_first_boot: the kiosk ticket could not be minted (status $status)\n" if $status != 0;
	return 0 unless $status == 0;
	my $shared = &_ticket_share($home);
	print STDERR "gou_first_boot: the kiosk ticket could not be saved for the installed shell\n"
		unless $shared;
	return 1;
}

# The Qt shell is installed at ~/.local/share/jawnos/desktop, so its ROOT_DIR is
# ~/.local/share/jawnos and it reads ROOT_DIR/.shots/ticket.txt - not the working
# tree's .shots. app_ticket.pl --save writes the tree's copy; put the same ticket
# where the installed shell looks, or a freshly flashed board stays at the Gate.
sub _ticket_share {
	my ($home) = @_;
	return 0 unless defined $home && length $home;
	my $source = Cwd::abs_path('.') . '/.shots/ticket.txt';
	return 0 unless -f $source;
	my $body = '';
	if (open(my $in, '<', $source)) { local $/; $body = <$in> // ''; close $in; }
	return 0 unless length $body;
	my $root = $home . '/.local/share/jawnos';
	return 0 unless -d "$root/desktop";
	my $dir = "$root/.shots";
	File::Path::make_path($dir) unless -d $dir;
	my $dest = $dir . '/ticket.txt';
	my $tmp = $dest . '.new';
	return 0 unless open(my $out, '>', $tmp);
	print {$out} $body;
	close $out;
	chmod 0600, $tmp;
	return 0 unless rename($tmp, $dest);
	&_own_by_tree($dir, $dest);
	return 1;
}

sub _identity_ensure {
	foreach my $file (&subs::signatorial_identity_file(), &subs::signatorial_identity_mirror()) {
		next unless defined $file && length $file;
		return 'existing' if -e $file;
	}
	my $fresh = join '', map { sprintf '%x', int(rand(16)) } 1 .. 32;
	&subs::signatorial_identity_write($fresh);
	&_own_by_tree(&subs::signatorial_identity_file(), &subs::signatorial_identity_mirror());
	return 'minted';
}

# Where the board says it is: its own name and the manager port, never a
# stale configured domain (an image copied from another card can carry that
# card's domain, or loopback). The join row is how the house reaches the board
# later, so a loopback or somebody else's name is worse than the hostname.
# This board's own name, read where systemd reads it. The image carries no
# `hostname` binary, and the empty result left the join address blank, so the
# house was told about the wrong machine.
sub _hostname {
	my $name = '';
	if (open(my $fh, '<', '/etc/hostname')) {
		$name = <$fh> // '';
		close $fh;
	}
	$name =~ s/^\s+|\s+$//g;
	return $name if length $name;
	require Sys::Hostname;
	return Sys::Hostname::hostname() // '';
}

sub _self_address {
	my $config = eval { &subs::config_reader() } || {};
	my $port = $ENV{'PORT_AHOY'} || $config->{'working_port'} || $config->{'port'} || '';
	my $host = &subs::device_hostname_better(&_hostname(), '', '');
	if (!length $host) {
		$host = $config->{'domain'} || '';
		$host = '' if $host =~ /^(?:localhost|127\.|\[?::1\]?)/i;
	}
	return $host . (length $port ? ':' . $port : '');
}

# Redeem the token at the house. The request is signed with this machine's peer
# key, which is generated on first use: the key is what the house pins to the
# row it writes, so the next call needs the token no more than it needs an
# address. The house's CA is used when the tree carries it; a certificate the
# board does not yet trust is a failure worth reporting, not one to skip past.
sub _join {
	my ($token) = @_;
	require Mojo::UserAgent;
	require Mojo::JSON;
	my $house = ref $token->{'house'} eq 'HASH' ? $token->{'house'} : {};
	my $manager = $house->{'manager'} // '';
	my ($scheme, $host, $port) = $manager =~ m{^(https?)://(\[[^\]]+\]|[^/:]+)(?::(\d+))?};
	$host = '' unless defined $host;
	$port = '' unless defined $port;
	my $url = $manager . '/device/join';
	# The token's address names the browser's manager port, whose certificate is
	# the public wildcard (or the local self-signed pair). The house-CA leaf that
	# proves an address lives on the peer listener, port + 6; peer_secure_url
	# rewrites the origin to it when it answers. When it cannot, the signed
	# request still authenticates the board, so the unverified rail is the
	# fallback - the same rail manager_configure2 uses for a house not rostered.
	my $rm = {
		ip => $host, fqdn => $host, port => $port,
		manager => $manager,
		signatorial => $house->{'signatorial'} // '',
		pubkey => $house->{'pubkey'} // '',
		hostname => $house->{'name'} // '',
		tunnel => '',
	};
	my ($endpoint, $verified) = &subs::peer_secure_url($rm, $url);
	my $ua = Mojo::UserAgent->new->connect_timeout(20)->request_timeout(40);
	# Whether this board proved the house's leaf. The house returns its own leaf
	# (and key) only to a board that did: the fallback rail is signed but not
	# confidential, and a key that crossed it would be usable by whoever read it.
	my $trusted = ($verified && &subs::peer_tls_verify($ua)) ? 1 : 0;
	if ($trusted) { $url = $endpoint; }
	else { $ua->insecure(1); }
	$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req) });
	my $pubkey = &subs::peer_pubkey() || '';
	return { ok => 0, error => 'this machine has no peer key' } unless length $pubkey;
	my $res = eval {
		$ua->post($url => form => {
			secret => $token->{'secret'},
			signatorial => &subs::signatorial_designer() || '',
			pubkey => $pubkey,
			name => $token->{'hostname'} || $token->{'name'} || 'Controller',
			# The board is a controller, whatever the tree's device class says
			# before the config seed has been read.
			device => 'controller',
			ost => $^O,
			address => &_self_address(),
			version => &subs::jawn_version(),
			# Signed with the body: the house may return a private key only on
			# a connection the board proved.
			tls_verified => $trusted,
		})->result;
	};
	unless ($res) {
		return { ok => 0, error => 'the house did not answer at ' . $url };
	}
	my $answer = eval { Mojo::JSON::decode_json($res->body // '') } || {};
	unless ($answer->{'ok'}) {
		return { ok => 0, error => ($answer->{'error'} || 'the house refused the token (' . $res->code . ')') };
	}
	my $sent = ref $answer->{'house'} eq 'HASH' ? $answer->{'house'} : {};
	# The house named this board under its domain and, when its CA is here,
	# issued the leaf for that name. Install it before the manager starts; the
	# report shows the status, never the key.
	my $tls = ref $answer->{'tls'} eq 'HASH' ? $answer->{'tls'} : {};
	my $certificate = &_install_join_certificate($tls);
	my $row = &_house_row($sent);
	return {
		ok => 1, uuid => $answer->{'uuid'}, house => $sent,
		filed => ($row->{'ok'} ? 1 : 0),
		public_host => ($answer->{'public_host'} // ''),
		tls => $certificate,
		tls_host => ($tls->{'host'} // ''),
		error => $row->{'error'},
	};
}

# The house CA issued this board a leaf for the name it joined under. Install it
# as both pairs before the manager starts: the main listener serves the public
# name, and the peer listener serves the same leaf. The CA certificate stays
# beside them (the tree already trusts it), and the service account owns what
# root just wrote. The leaf's key never reaches the report or the log.
sub _install_join_certificate {
	my ($tls) = @_;
	return 'none' unless ref $tls eq 'HASH' && $tls->{'ok'};
	my $cert = $tls->{'cert'} // '';
	my $key = $tls->{'key'} // '';
	return 'invalid' unless $cert =~ /-----BEGIN CERTIFICATE-----/ && $key =~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/;
	my $server = eval { &subs::server_dir() } || '';
	return 'failed' unless length $server;
	File::Path::make_path($server) unless -d $server;
	my @written;
	foreach my $pair (['fullchain.pem', $cert, 0644], ['privkey.pem', $key, 0600],
		['peer-fullchain.pem', $cert, 0644], ['peer-privkey.pem', $key, 0600]) {
		my ($name, $body, $mode) = @$pair;
		my $path = "$server/$name";
		next unless open(my $fh, '>', $path);
		print {$fh} $body;
		close $fh;
		chmod $mode, $path;
		push @written, $path;
	}
	&_own_by_tree(@written);
	return @written == 4 ? 'installed' : 'partial';
}

# File the house on this board's roster, so the first sync has somewhere to go.
# The house's own grant (what it may ask of us) is not ours to set: this writes
# the row only.
sub _house_row {
	my ($house) = @_;
	my $manager = $house->{'manager'} || '';
	return { ok => 0, error => 'the house sent no address' } unless $manager =~ m{^https?://};
	my ($host, $port) = $manager =~ m{^https?://([^:/]+)(?::(\d+))?};
	return { ok => 0, error => 'the house sent no host' } unless defined $host && length $host;
	my $signatorial = $house->{'signatorial'} || '';
	my $now = &subs::rightNow();
	my $known = $signatorial ? &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hash : undef;
	my $row = {
		uuid => ($known && $known->{'uuid'}) ? $known->{'uuid'} : &subs::random_string_creator(15),
		ip => $host,
		fqdn => $host,
		port => $port || '',
		manager => $manager,
		signatorial => $signatorial,
		pubkey => $house->{'pubkey'} || '',
		hostname => $house->{'name'} || '',
		device => 'server',
		status => 'connected',
		connection => 'active',
		server_time => $now,
		timestamp => $now,
	};
	my $ok = eval {
		if ($known) { &subs::db_update('remote_machines', $row, { uuid => $row->{'uuid'} }); }
		else { &subs::db_insert('remote_machines', $row); }
		1;
	};
	return { ok => $ok ? 1 : 0, error => $ok ? '' : 'the house row could not be filed' };
}

# ---------------------------------------------------------------------------
# main

my $report = { ok => 1, dry_run => ($opt{'dry_run'} ? 1 : 0) };

my $token = &_token_read($opt{'token'});

# A board that was just flashed has no identity of its own yet (the provisioner
# removes the image's), and both the card's finding and the join are written
# under it. An unflashed machine keeps the identity it has.
unless ($opt{'dry_run'}) {
	$report->{'identity'} = &_identity_ensure() unless $token->{'absent'};
}

# The image drops the source card's ticket, and the desktop view's fallback
# file with it. Mint this board's own forever ticket here, before the launcher
# opens it, so a fresh board arrives logged in instead of at the gate. The URL
# is a credential: the mint's stdout is captured and never written to the log;
# --save puts it in .shots/ticket.txt (0600), and _ticket_share puts it where
# the installed Qt shell reads it.
&_kiosk_ticket() unless $opt{'dry_run'};
# A board's shell is the whole glass from its first start; the launcher is
# laid out for the panel, not for a 1100 px window.
$report->{'desktop'} = &_desktop_shell_state() ? 'fullscreen' : 'kept' unless $opt{'dry_run'};

if ($token->{'error'}) {
	_fail(6, $token->{'error'});
}
$report->{'token'} = $token->{'absent'} ? 'none' : 'found';

my $card = undef;
unless ($opt{'no_card'}) {
	my @candidates = &_card_candidates(&_lsblk());
	my $chosen = undef;
	foreach my $candidate ( @candidates ) {
		if (defined $opt{'device'} && length $opt{'device'}) {
			next unless $candidate->{'dev'} eq $opt{'device'} || $candidate->{'disk'} eq $opt{'device'};
		}
		$chosen = $candidate;
		last;
	}
	if ($chosen) {
		# The person's answer can arrive two ways: in the token, chosen before the
		# flash (the card is in the board, so this is the only chance to say), or a
		# setting they answered later on the Controllers page. The setting is the
		# later word and wins; a dry run reports the token's answer, which needs no
		# database.
		my $token_card = ($token->{'token'} || {})->{'card'} // '';
		$token_card = '' unless $token_card =~ /^(adopt|format)$/;
		my $choice = $opt{'dry_run'} ? $token_card : (&_card_choice_read() || $token_card);
		my $plan = &_card_plan($chosen, { format => $opt{'format'}, choice => $choice });
		$report->{'card'} = $plan;
		my $prepared = undef;
		if (!$opt{'dry_run'} && $plan->{'action'} ne 'leave') {
			$prepared = $plan->{'action'} eq 'format'
				? &_card_format($plan, { mount => $opt{'mount'} })
				: &_card_adopt($plan, { mount => $opt{'mount'} });
			if (!$prepared->{'ok'}) {
				_report_token($token);
				_fail(7, $prepared->{'error'});
			}
			$report->{'card'}->{'done'} = $prepared->{'done'};
			$report->{'card'}->{'archive_dir'} = $prepared->{'archive_dir'};
			$report->{'card'}->{'fstab_error'} = $prepared->{'fstab_error'} if $prepared->{'fstab_error'};
			# A setting has been applied; a later boot must not apply it again. The
			# token's own answer needs no clearing, since the token is spent below.
			&_card_setting_clear('card_choice');
		}
		if (!$opt{'dry_run'}) {
			$report->{'card'}->{'reported'} = &_card_report($plan, $prepared);
		}
	}
	else {
		$report->{'card'} = { state => 'none' };
		&_card_setting_clear('card_finding') unless $opt{'dry_run'};
	}
}

if (!$opt{'no_join'} && !$token->{'absent'} && !$token->{'error'}) {
	if ($opt{'dry_run'}) {
		$report->{'join'} = 'would redeem at ' . ($token->{'house'}->{'manager'} || '');
	}
	else {
		# The board is itself before it introduces itself.
		$report->{'identity'} //= &_identity_ensure();
		my $joined = &_join($token);
		$report->{'join'} = $joined;
		if ($joined->{'ok'}) {
			# The first signed request made the peer key; the service runs as the
			# account that owns the tree and must be able to read it.
			&_own_by_tree(&subs::peer_key_paths());
			unlink($token->{'path'}) if -f $token->{'path'};
			$report->{'token'} = 'redeemed';
		}
		else {
			# The card's finding may already have made a WAL as root; hand the
			# database back before the token is kept for the next boot.
			&_own_database();
			_fail(6, $joined->{'error'});
		}
	}
}

# The settings row the card reported and the roster row the join filed are
# written by this root pass. SQLite creates the WAL and SHM beside the database
# as this process, so hand the whole family to the tree's account before the
# service opens it; otherwise jawn can read the database and not write it.
&_own_database() unless $opt{'dry_run'};

_emit($report, 0);

# A failed card keeps the token: the board can be booted again once the card is
# sorted out, and a token that was never sent is still the house's word.
sub _report_token {
	my ($token) = @_;
	return if $token->{'absent'} || $token->{'error'};
	_note('the join token is still on the board, for the next boot');
}
