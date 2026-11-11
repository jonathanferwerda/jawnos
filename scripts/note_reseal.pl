#!/usr/bin/perl

# note_reseal.pl - bring saved notes to the authenticated JS1 seal.
#
#   perl scripts/note_reseal.pl           # dry run: print what would change
#   perl scripts/note_reseal.pl --apply   # rewrite legacy notes as JS1
#   perl scripts/note_reseal.pl --json    # machine-readable result
#   perl scripts/note_reseal.pl --batch 100 --after-appt 12000
#
# Older uploads sealed a note's outer Crypt::Simple layer under the empty
# passphrase (public knowledge) while the inner cipher stayed keyed to the real
# secret. The ordinary note reader still opens those so they are not lost, but
# the value at rest is not in the authenticated JS1 format. This rewrites them
# under the key this machine holds now: appointment notes (notes, start_notes,
# end_notes), the OCR text stored inside an appointment's file JSON, and mailbox
# subject/body. Safe to re-run: a value that already opens as JS1 is left alone.
#
# It works in rowid batches so a long sweep reports progress and a kill is not a
# loss: every batch is committed and the next run picks up from the rowid it
# prints. --after-appt / --after-mail start from a cursor by hand.
use strict;
use warnings;
use FindBin;
require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $apply = (grep { $_ eq '--apply' } @ARGV) ? 1 : 0;
my $json  = (grep { $_ eq '--json' } @ARGV) ? 1 : 0;
my ($batch, $after_appt, $after_mail) = (250, 0, 0);
for (my $i = 0; $i < @ARGV; $i++) {
	$batch      = int($ARGV[$i + 1]) if $ARGV[$i] eq '--batch' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^\d+$/;
	$after_appt = int($ARGV[$i + 1]) if $ARGV[$i] eq '--after-appt' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^\d+$/;
	$after_mail = int($ARGV[$i + 1]) if $ARGV[$i] eq '--after-mail' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^\d+$/;
}
$batch = 1 if $batch < 1;

my %sum = map { $_ => 0 } qw(seen appointments notes ocr mailbox failed already);
my $sweep = sub {
	my ($table) = @_;
	while (1) {
		my $res = subs::note_reseal($apply, {
			table => $table,
			after_appt => $after_appt,
			after_mail => $after_mail,
			limit => $batch,
		});
		if ($res->{'error'}) {
			print "note reseal: $res->{'error'}\n";
			exit 1;
		}
		$sum{$_} += $res->{$_} for keys %sum;
		last unless $res->{'more_appt'} || $res->{'more_mail'};
		$after_appt = $res->{'next_appt'} if $table eq 'appointments';
		$after_mail = $res->{'next_mail'} if $table eq 'mailbox';
		printf STDERR "  %s: through rowid %s (%d value(s) checked)\n",
			$table, ($table eq 'appointments' ? $after_appt : $after_mail), $sum{'seen'};
	}
};
$sweep->('appointments');
$sweep->('mailbox');

my $result = { ok => 1, apply => $apply ? 1 : 0, %sum };
if ($json) {
	print Mojo::JSON::encode_json($result), "\n";
	exit 0;
}

printf "note reseal - %s\n", $apply ? 'applied' : 'dry run (pass --apply to write)';
printf "  appointments: %d row(s), %d note field(s), %d OCR field(s)\n",
	$result->{'appointments'}, $result->{'notes'}, $result->{'ocr'};
printf "  mailbox:      %d row(s)\n", $result->{'mailbox'};
printf "  already JS1:  %d field(s)\n", $result->{'already'};
printf "  unreadable:   %d field(s) (left as they are)\n", $result->{'failed'};
