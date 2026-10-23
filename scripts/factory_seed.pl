#!/usr/bin/perl
#
# Build database/initial.enc - the factory seed a new install is provisioned
# from: the shipped schema plus the factory settings (appearance and
# configuration defaults, no personal data), sealed under the factory code.
#
#   perl scripts/factory_seed.pl
#
# The sealed seed is opened by scripts/jawnos_setup.pl with the same code and
# re-sealed under the user's own unlock code, so the factory code guards an
# empty template, not a secret. Provisioning keeps only the rows for the
# machine's own kind of device. Re-run this after changing the factory settings
# below, and commit the new database/initial.enc.
#
use strict;
use warnings;
use Cwd ();
use FindBin qw($Bin);
use Mojo::SQLite;
use Crypt::Simple;
use File::Path qw(make_path);

my $root = Cwd::abs_path("$Bin/..");
chdir $root or die "cannot chdir to $root: $!\n";

# must match $FACTORY_CODE in scripts/jawnos_setup.pl; the seed is sealed with
# openssl enc -e -k <code> -aes-256-cbc -pbkdf2, standard recorded in the appendage
our $FACTORY_CODE = 'JAWNOS-FACTORY-SEED-v1';
my $standard = 'aes-256-cbc';
my $splitter = "--simple--split--and--whatnot--";

sub encrypter { my ( $secret, $content ) = @_; local *encrypt; local *decrypt; Crypt::Simple->import( passphrase => $secret ); return encrypt($content); }
sub randstr    { my $len = shift || 20; my @c = ( 'A'..'Z', 'a'..'z', 0..9 ); my $s = ''; $s .= $c[ int( rand(@c) ) ] for 1 .. $len; return $s; }

# ---------------------------------------------------------------------------
# the factory settings: what a fresh install starts with
# ---------------------------------------------------------------------------
# Lifted from working installs of each kind - mobile from Fe, computer from the
# desktop, server from cloud - and appearance and configuration only: no
# personal data, no keys, nothing that names anyone. Everything is stored per
# device, the way the running system stores it (setting_grabber reads the row
# for the machine's own device); provisioning keeps that device's rows and
# drops the rest, so a phone never carries the desktop's palette or the
# desktop the phone's.

# the same value on every kind of machine
my %factory_common = (
	encryption_standard       => 'aes-256-cbc',
	language                  => 'en',
	payment_background_colour => '#66b5ff',
	photo_size                => '3840x2160',
	scan_size                 => 'Raw',
	thumbnail_size            => '200x200',
);

my %factory_me = (
	name     => 'Me',
	warranty => '-10d',
	currency => 'CAD',
	worth    => '0',
);

# [ what the computer uses (the server follows it) , what the mobile uses ]
my %factory_look = (
	box_office_background_colour                 => [ '#a6e7e7', '#fea62a' ],
	calculator_background_colour                 => [ '#36a1a1', '#7affcc' ],
	configure_background_colour                  => [ '#36a1a1', '#85baff' ],
	console_background_colour                    => [ '#64cece', '#a6a5f3' ],
	controller_background_colour                 => [ '#88dddd', '#feef90' ],
	delorean_background_colour                   => [ '#a6e7e7', '#95ff5c' ],
	gate_background_colour                       => [ '#40bfbf', '#8aff97' ],
	homepage_background_colour                   => [ '#c5f1f1', '#7542ff' ],
	homepage_content_background_colour           => [ '#a6e7e7', '#ffd952' ],
	ide_sidebar_container_background_colour      => [ '#40bfbf', '#4aff47' ],
	keyboard_background_colour                   => [ '#40bfbf', '#88f07a' ],
	mail_sidebar_container_background_colour     => [ '#64cece', '#fe7f48' ],
	manager_background_colour                    => [ '#88dddd', '#b06d94' ],
	notifications_background_colour              => [ '#88dddd', '#fba2ef' ],
	pseudonym_background_colour                  => [ '#36a1a1', '#ffd599' ],
	pseudonym_home_background_colour             => [ '#c5f1f1', '#99eeff' ],
	remote_control_background_colour             => [ '#64cece', '#5dfee3' ],
	soundroom_sidebar_container_background_colour => [ '#88dddd', '#5cff67' ],
	start_menu_background_colour                 => [ '#64cece', '#6e7fff' ],
	store_background_colour                      => [ '#c5f1f1', '#62ff57' ],
	store_header_background_colour               => [ '#a6e7e7', '#fbffc2' ],
	document_location                            => [ '~/Documents', '/sdcard/Documents' ],
	download_location                            => [ '~/Downloads', '/sdcard/Download' ],
	music_location                               => [ '~/Music', '/sdcard/Music' ],
	photo_location                               => [ '~/Pictures', '/sdcard/DCIM' ],
	rec_location                                 => [ '~/Recordings', '/sdcard/Recordings' ],
	scan_location                                => [ '~/Documents', '/sdcard/Documents' ],
	max_backups                                  => [ '17', '20' ],
	max_files                                    => [ '92', '118' ],
);

# configuration only the desktop kinds carry
my %factory_computer = (
	clock_format        => '12',
	clock_notifications => 'on',
	enc                 => 'on',
	icon_set            => 'gnome',
	navigation          => 'none',
	taskbar_autohide    => 'off',
	taskbar_position    => 'top',
	ui_zoom             => '100',
);

my @rows;
foreach my $s ( sort keys %factory_common ) {
	push @rows, [ 'misc', $s, $factory_common{$s}, $_ ] for qw/computer mobile server/;
}
foreach my $s ( sort keys %factory_me ) {
	push @rows, [ 'me', $s, $factory_me{$s}, $_ ] for qw/computer mobile server/;
}
foreach my $s ( sort keys %factory_look ) {
	my ( $c, $m ) = @{ $factory_look{$s} };
	push @rows, [ 'misc', $s, $c, 'computer' ], [ 'misc', $s, $m, 'mobile' ], [ 'misc', $s, $c, 'server' ];
}
foreach my $s ( sort keys %factory_computer ) {
	push @rows, [ 'misc', $s, $factory_computer{$s}, 'computer' ];
}

my $tmp = "$ENV{HOME}/.president/factory_seed_" . randstr(8) . '.db';
make_path("$ENV{HOME}/.president") unless -d "$ENV{HOME}/.president";
my $build = `sqlite3 $tmp < database/schema.sql 2>&1`;
die "could not build the schema: $build\n" if $? != 0 || !-e $tmp;

my $sql = Mojo::SQLite->new('sqlite:' . $tmp);
my $db  = $sql->db;
$db->query('PRAGMA journal_mode=WAL');
my $now = time() * 1000;
$db->insert( 'security', {
	level       => 1,
	database    => 'jawnos.db',
	timestamp   => $now,
	server_time => $now,
	credential  => encrypter( $FACTORY_CODE, $FACTORY_CODE ),
	uuid        => randstr(30),
} );
foreach my $r ( @rows ) {
	$db->insert( 'settings', {
		app         => $r->[0],
		setting     => $r->[1],
		value       => $r->[2],
		device      => $r->[3],
		timestamp   => $now,
		server_time => $now,
		uuid        => randstr(20),
	} );
}
$db->query('PRAGMA wal_checkpoint(TRUNCATE)');
undef $db;
undef $sql;

my $temp = $tmp . '.1.db';
`sqlite3 $tmp ".backup '$temp'"`;
my $out = "$root/database/initial.enc";
`openssl enc -e -k "$FACTORY_CODE" -$standard -pbkdf2 -in $temp -out $out`;
die "openssl failed to seal the seed\n" unless -e $out && -s $out > 100;
open my $fh, '>>', $out or die $!;
binmode $fh;
print $fh ( $splitter . encrypter( $FACTORY_CODE, $standard ) );
close $fh;
`shred -u $tmp $temp $tmp-wal $tmp-shm 2>/dev/null`;
`rm -f $tmp-wal $tmp-shm $temp`;

print "wrote $out (" . ( -s $out ) . " bytes, " . scalar(@rows) . " factory settings)\n";
