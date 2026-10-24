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
use File::Type;
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
# Without a verdict every secret "opens" the file: the first one always wins and
# the probe writes ciphertext, which ImageMagick then refuses. The verdict is what
# tells sealed_file_open which secret is the right one. The current suds is a
# candidate of its own - a file sealed on window close used it directly.
my $inspect = sub {
	return &subs::plaintext_verdict($_[0]);
};
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
		push @secrets, $suds if defined $suds && length $suds;
		foreach my $p ( @{ $passwords->hashes } ) {
			my $secret = &subs::decrypter($suds, $p->{'credential'}, $stamp);
			push @secrets, $secret if defined $secret && length $secret;
		}
		my $opened = &subs::sealed_file_open($file, \@secrets, \@standards, 1, $inspect);
		unless ($opened && defined $opened->{'data'} && length $opened->{'data'}) { print "OPEN FAIL $file\n" if $apply; $failed++; next; }
		my ($fh, $tmp) = tempfile(SUFFIX => '.img', TMPDIR => 1);
		binmode $fh;
		print $fh $opened->{'data'};
		close $fh;
		my $orientation = `magick $tmp -format '%[orientation]' info: 2>/dev/null`;
		chomp $orientation;
		# no answer means the probe could not read the picture: count it, never
		# treat it as "upright", which is how a whole library can be skipped
		unless (length $orientation) { unlink $tmp; $failed++; next; }
		if ($orientation eq 'TopLeft' || $orientation eq 'Undefined') { unlink $tmp; next; }
		$sideways++;
		print $apply ? 'FIX    ' : 'sideways ', $appt->{'app'} || '', ' ', $file, ' (', $orientation, ")\n";
		next unless $apply;
		# Regenerate the thumb upright in place. Deleting it would work too, but
		# then the album lies blank until every photo is opened again; the plain
		# image is already in hand here, so this is the cheap moment to redo it.
		my $size = &subs::setting_grabber({ app => 'misc', setting => 'thumbnail_size' }) || 'none';
		if ($size eq 'none') { unlink $tmp; next; }
		my ($tfh, $plain) = tempfile(SUFFIX => '.png', TMPDIR => 1);
		close $tfh;
		# -strip drops the source's profiles: a few Samsung JPEGs carry an ICC
		# profile ImageMagick refuses to write, and it then emits a broken PNG
		my $cmd = 'magick ' . $tmp . ' -auto-orient -strip -resize ' . $size . ' png:' . $plain . ' 2>/dev/null';
		`$cmd`;
		if (-e $plain && (-s $plain) > 100 && &subs::seal_file($plain, $thumb, $opened->{'secret'}, $opened->{'standard'})) {
			$removed++;
		}
		else { print "WRITE FAIL $thumb\n" if $apply; $failed++; }
		unlink $plain;
		unlink $tmp;
	}
}

printf "%s: checked=%d sideways=%d fixed=%d failed=%d\n",
	($apply ? 'APPLIED' : 'DRY RUN'), $checked, $sideways, $removed, $failed;
