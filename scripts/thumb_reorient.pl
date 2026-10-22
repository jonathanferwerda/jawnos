#!/usr/bin/env perl
# thumb_reorient.pl - find thumbnails made before the gallery asked ImageMagick
# to honour EXIF orientation, and remove them so the next view regenerates an
# upright copy. Removing is safe: a thumbnail is a cache, the photo is untouched.
#
#   perl scripts/thumb_reorient.pl                 dry run: list what it found
#   perl scripts/thumb_reorient.pl --apply         remove those thumbs
#   perl scripts/thumb_reorient.pl --limit 20      stop after 20 photos (a probe)
#
# Only image appointments are read. A photo that fails to open is counted, never
# guessed at.
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempfile);
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './subroutines.pl';
require Mojo::JSON;

my $apply = grep { $_ eq '--apply' } @ARGV;
my $limit = 0;
for (my $i = 0; $i < @ARGV; $i++) {
	$limit = int($ARGV[$i + 1]) if $ARGV[$i] eq '--limit' && defined $ARGV[$i + 1];
}

my $suds = &subs::suds_grabber();
my @standards = @{ &subs::note_encryption_standards() };
my $rows = &subs::db_query('select uuid, app, type, server_time, file from appointments where file is not null and type = ?', 'image')->hashes;

my ($checked, $sideways, $removed, $failed) = (0, 0, 0, 0);
PHOTO:
foreach my $appt ( @{$rows} ) {
	my $files = eval { Mojo::JSON::decode_json($appt->{'file'}) } || [];
	foreach my $f ( @{$files} ) {
		my $file = $f->{'f'} || '';
		my $thumb = $f->{'thumb'} || '';
		next unless length $file && length $thumb && -e $file && -e $thumb;
		last PHOTO if $limit && $checked >= $limit;
		$checked++;
		my $stamp = $f->{'server_time'} || $appt->{'server_time'};
		my $passwords = &subs::db_query('select * from security where level != ? and level != ? and timestamp <= ? order by timestamp DESC', 'padlock', 'door', $stamp);
		my @secrets;
		foreach my $p ( @{ $passwords->hashes } ) {
			my $secret = &subs::decrypter($suds, $p->{'credential'}, $stamp);
			push @secrets, $secret if defined $secret && length $secret;
		}
		my $opened = &subs::sealed_file_open($file, \@secrets, \@standards, 1);
		unless ($opened && defined $opened->{'data'} && length $opened->{'data'}) { $failed++; next; }
		my ($fh, $tmp) = tempfile(SUFFIX => '.img', TMPDIR => 1);
		binmode $fh;
		print $fh $opened->{'data'};
		close $fh;
		my $orientation = `magick $tmp -format '%[orientation]' info: 2>/dev/null`;
		unlink $tmp;
		chomp $orientation;
		next unless length $orientation;
		next if $orientation eq 'TopLeft' || $orientation eq 'Undefined';
		$sideways++;
		print $apply ? 'REMOVE ' : 'sideways ', $appt->{'app'} || '', ' ', $file, ' (', $orientation, ")\n";
		next unless $apply;
		unlink $thumb;
		$removed++ unless -e $thumb;
	}
}

printf "%s: checked=%d sideways=%d removed=%d failed=%d\n",
	($apply ? 'APPLIED' : 'DRY RUN'), $checked, $sideways, $removed, $failed;
