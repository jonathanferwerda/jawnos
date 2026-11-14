#!/usr/bin/perl

# note_reseal.pl - bring saved notes to the authenticated JS1 seal.
#
#   perl scripts/note_reseal.pl           # dry run: print what would change
#   perl scripts/note_reseal.pl --apply   # rewrite legacy notes as JS1
#   perl scripts/note_reseal.pl --json    # machine-readable result
#   perl scripts/note_reseal.pl --batch 100 --after-appt 12000
#   perl scripts/note_reseal.pl --table rest --apply   # only the rest pass
#   perl scripts/note_reseal.pl --old-secret-file OLD.txt --apply
#   perl scripts/note_reseal.pl --try-all               # every security credential
#   perl scripts/note_reseal.pl --export-keys OLD.txt   # candidates for another machine
#
# Older uploads sealed a note's outer Crypt::Simple layer under the empty
# passphrase (public knowledge) while the inner cipher stayed keyed to the real
# secret. The ordinary note reader still opens those so they are not lost, but
# the value at rest is not in the authenticated JS1 format. This rewrites them
# under the key this machine holds now: appointment notes (notes, start_notes,
# end_notes), the OCR text stored inside an appointment's file JSON, and mailbox
# subject/body. Safe to re-run: a value that already opens as JS1 is left alone.
#
# A value sealed under a key this machine no longer holds (the security history
# was restored from a copy that had already dropped it, or the rotation predates
# the history this build keeps) cannot be opened by the key in use now. If the
# person still has that passphrase, hand it in with --old-secret-file (one per
# line), --old-secret, or JAWNOS_OLD_SECRET. Each candidate is tried only on the
# values that did not open otherwise, must decrypt to text, and is never written
# to the database or the report.
#
# --try-all does what the old reader did: it tries every credential the security
# table holds, whatever its ost, including the door row. A restore or import
# rewrites ost, so the key that wrote a note can sit after it and the ordinary
# timestamp walk never reaches it. Combine it with --old-secret-file for a key
# that is no longer in the table at all.
#
# --export-keys writes those candidates to a file (mode 0600) instead of running
# the sweep. Run it on a machine that still has the old security rows, copy the
# file to the machine whose notes will not open, and pass it back in with
# --old-secret-file. The file holds secrets: delete it after use.
#
# It works in rowid batches so a long sweep reports progress and a kill is not a
# loss: every batch is committed and the next run picks up from the rowid it
# prints. --after-appt / --after-mail start from a cursor by hand.
use strict;
use warnings;
use FindBin;
use Fcntl qw(O_WRONLY O_CREAT O_TRUNC);
require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $apply = (grep { $_ eq '--apply' } @ARGV) ? 1 : 0;
my $json  = (grep { $_ eq '--json' } @ARGV) ? 1 : 0;
my $try_all = (grep { $_ eq '--try-all' } @ARGV) ? 1 : 0;
my $export = '';
my ($batch, $after_appt, $after_mail, $only) = (250, 0, 0, 'all');
my @old_secrets;
for (my $i = 0; $i < @ARGV; $i++) {
	$batch      = int($ARGV[$i + 1]) if $ARGV[$i] eq '--batch' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^\d+$/;
	$after_appt = int($ARGV[$i + 1]) if $ARGV[$i] eq '--after-appt' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^\d+$/;
	$after_mail = int($ARGV[$i + 1]) if $ARGV[$i] eq '--after-mail' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^\d+$/;
	$only = $ARGV[$i + 1] if $ARGV[$i] eq '--table' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^(?:appointments|mailbox|rest|all)$/;
	if ($ARGV[$i] eq '--old-secret-file' && defined $ARGV[$i + 1]) {
		my $path = $ARGV[++$i];
		open(my $fh, '<', $path) or do { print "note reseal: cannot read $path: $!\n"; exit 1 };
		my $text = do { local $/; <$fh> };
		close $fh;
		push @old_secrets, grep { length } map { my $s = $_; $s =~ s/\s+\z//; $s } split /\r?\n/, $text;
	}
	elsif ($ARGV[$i] eq '--export-keys' && defined $ARGV[$i + 1]) {
		$export = $ARGV[++$i];
	}
	elsif ($ARGV[$i] eq '--old-secret' && defined $ARGV[$i + 1]) {
		# argv is visible in ps; the file and the environment are the safe ways.
		print STDERR "note reseal: --old-secret is visible in the process list; prefer --old-secret-file or JAWNOS_OLD_SECRET\n";
		push @old_secrets, $ARGV[++$i];
	}
}
push @old_secrets, $ENV{'JAWNOS_OLD_SECRET'} if defined $ENV{'JAWNOS_OLD_SECRET'} && length $ENV{'JAWNOS_OLD_SECRET'};
my %seen_secret;
@old_secrets = grep { length && !$seen_secret{$_}++ } @old_secrets;
$batch = 1 if $batch < 1;

# Hand the security table's candidates to another machine. This writes a secret
# file, not the database, and says how many it wrote (never what they are).
if (length $export) {
	my $keys = subs::note_legacy_candidates();
	unless (ref $keys eq 'ARRAY' && scalar @{$keys}) {
		print "note reseal: no security candidates on this machine\n";
		exit 1;
	}
	sysopen(my $out, $export, O_WRONLY | O_CREAT | O_TRUNC, 0600) or do { print "note reseal: cannot write $export: $!\n"; exit 1 };
	chmod 0600, $export;
	print $out "$_\n" for @{$keys};
	close $out;
	print "note reseal: wrote ", scalar(@{$keys}), " candidate(s) to $export (mode 0600; delete it after use)\n";
	exit 0;
}

my %sum = map { $_ => 0 } qw(seen appointments notes ocr mailbox warehouse credentials settings keyboard tickets appointments_data vault mail_tokens device_tokens failed already);
my $sweep = sub {
	my ($table) = @_;
	while (1) {
		my $res = subs::note_reseal($apply, {
			table => $table,
			after_appt => $after_appt,
			after_mail => $after_mail,
			limit => $batch,
			old_secrets => \@old_secrets,
			try_all => $try_all,
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
$sweep->('appointments') if $only eq 'all' || $only eq 'appointments';
$sweep->('mailbox') if $only eq 'all' || $only eq 'mailbox';
if ($only eq 'all' || $only eq 'rest') {
	my $rest = subs::note_reseal($apply, { table => 'rest', old_secrets => \@old_secrets, try_all => $try_all });
	if ($rest->{'error'}) {
		print "note reseal: $rest->{'error'}\n";
		exit 1;
	}
	$sum{$_} += $rest->{$_} for keys %sum;
}

my $result = { ok => 1, apply => $apply ? 1 : 0, %sum };
if ($json) {
	print Mojo::JSON::encode_json($result), "\n";
	exit 0;
}

printf "note reseal - %s\n", $apply ? 'applied' : 'dry run (pass --apply to write)';
printf "  appointments: %d row(s), %d note field(s), %d OCR field(s)\n",
	$result->{'appointments'}, $result->{'notes'}, $result->{'ocr'};
printf "  mailbox:      %d row(s)\n", $result->{'mailbox'};
printf "  warehouse:    %d note(s)\n", $result->{'warehouse'};
printf "  credentials:  %d payload(s)\n", $result->{'credentials'};
printf "  settings:     %d value(s)\n", $result->{'settings'};
printf "  keyboard:     %d value(s)\n", $result->{'keyboard'};
printf "  tickets:      %d secret(s)\n", $result->{'tickets'};
printf "  appt data:    %d value(s)\n", $result->{'appointments_data'};
printf "  vault:        %d row(s)\n", $result->{'vault'};
printf "  mail secrets: %d field(s)\n", $result->{'mail_tokens'};
printf "  device auth:  %d token(s)\n", $result->{'device_tokens'};
printf "  already JS1:  %d field(s)\n", $result->{'already'};
printf "  unreadable:   %d field(s) (left as they are)\n", $result->{'failed'};
