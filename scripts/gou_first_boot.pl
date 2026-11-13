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
use File::Path ();
use Getopt::Long ();
use JSON::PP ();

chdir Cwd::abs_path("$Bin/..") or die "gou_first_boot: cannot find the jawnos root\n";
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
	# here must not leave a file the service cannot write.
	my @stat = stat($path);
	if (@stat) { chown($stat[4], $stat[5], $tmp) }
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
	my $line = 'UUID=' . $uuid . ' ' . $mount . ' ' . $type . ' defaults,nofail,x-systemd.device-timeout=10 0 2' . "\n";
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
	push @done, 'folders' if $scaffold->{'enabled'};
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

sub _self_address {
	my $config = eval { &subs::config_reader() } || {};
	my $port = $ENV{'PORT_AHOY'} || $config->{'working_port'} || $config->{'port'} || '';
	my $host = $config->{'domain'} || '';
	$host = &subs::device_hostname_better((`hostname` || ''), '', '') unless length $host;
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
	my $ua = Mojo::UserAgent->new->connect_timeout(20)->request_timeout(40);
	&subs::peer_tls_verify($ua);
	$ua->on(start => sub { my ($ua, $tx) = @_; &subs::peer_sign_request($tx->req) });
	my $url = ($token->{'house'}->{'manager'} // '') . '/device/join';
	my $pubkey = &subs::peer_pubkey() || '';
	return { ok => 0, error => 'this machine has no peer key' } unless length $pubkey;
	my $res = eval {
		$ua->post($url => form => {
			secret => $token->{'secret'},
			signatorial => &subs::signatorial_designer() || '',
			pubkey => $pubkey,
			name => $token->{'hostname'} || $token->{'name'} || 'Controller',
			device => &subs::device_setter() || 'controller',
			ost => $^O,
			address => &_self_address(),
			version => &subs::jawn_version(),
		})->result;
	};
	unless ($res) {
		return { ok => 0, error => 'the house did not answer at ' . $url };
	}
	my $answer = eval { Mojo::JSON::decode_json($res->body // '') } || {};
	unless ($answer->{'ok'}) {
		return { ok => 0, error => ($answer->{'error'} || 'the house refused the token (' . $res->code . ')') };
	}
	my $house = ref $answer->{'house'} eq 'HASH' ? $answer->{'house'} : {};
	my $row = &_house_row($house);
	return { ok => 1, uuid => $answer->{'uuid'}, house => $house, filed => ($row->{'ok'} ? 1 : 0), error => $row->{'error'} };
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
if ($token->{'error'}) {
	_fail(6, $token->{'error'});
}
$report->{'token'} = $token->{'absent'} ? 'none' : 'found';

# A board that was just flashed has no identity of its own yet (the provisioner
# removes the image's), and both the card's finding and the join are written
# under it. An unflashed machine keeps the identity it has.
unless ($opt{'dry_run'}) {
	$report->{'identity'} = &_identity_ensure() unless $token->{'absent'};
}

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
		my $choice = $opt{'dry_run'} ? '' : &_card_choice_read();
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
			# The answer has been applied; a later boot must not apply it again.
			&_card_setting_clear('card_choice') if length $choice;
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
			_fail(6, $joined->{'error'});
		}
	}
}

_emit($report, 0);

# A failed card keeps the token: the board can be booted again once the card is
# sorted out, and a token that was never sent is still the house's word.
sub _report_token {
	my ($token) = @_;
	return if $token->{'absent'} || $token->{'error'};
	_note('the join token is still on the board, for the next boot');
}
