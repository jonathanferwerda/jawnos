#!/usr/bin/perl
# black_images.pl - find photos that are effectively black, and remove the ones
# a person confirms.
#
#   perl scripts/black_images.pl                      dry run: list the black photos
#   perl scripts/black_images.pl --apply              remove them through the app
#   perl scripts/black_images.pl --limit 40           stop after 40 photos (a probe)
#   perl scripts/black_images.pl --max-mean 0.05      widen the darkness test
#   perl scripts/black_images.pl --json /tmp/black.json
#
# A stored thumbnail is read first: it is a small copy, so a whole library can
# be scanned without decrypting every original. A thumbnail is only a cache,
# though, so a candidate is confirmed against its original before anything is
# removed - a thumb that failed to render is not evidence that the photo is
# black.
#
# Removal goes through POST /manager/delete_file, the same route the Gallery's
# Delete button uses: the file entry leaves the appointment's json, the file and
# its thumbnail are shredded, an emptied appointment is closed, the deletion is
# registered for the peer rail and the windows are told. A script writing the
# rows by hand would be overwritten by the next sync pass.
#
# Before a deletion the file and its thumbnail are copied to
# .shots/black-quarantine-<date>/ (gitignored scratch) with a manifest, so a
# wrongly judged photo can be put back by hand.
use strict;
use warnings;
use FindBin;
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use File::Copy qw(copy);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './subroutines.pl';

our $main_url;

my ($apply, $limit, $json_path, $ticket_path) = (0, 0, '', '.shots/ticket.txt');
my ($max_mean, $max_spread, $max_luma) = (0.02, 0.02, 0.08);
for (my $i = 0; $i < @ARGV; $i++) {
	my $a = $ARGV[$i];
	$apply = 1 if $a eq '--apply';
	if ($a eq '--limit' && defined $ARGV[$i + 1]) { $limit = int($ARGV[++$i]); }
	elsif ($a eq '--max-mean' && defined $ARGV[$i + 1]) { $max_mean = $ARGV[++$i] + 0; }
	elsif ($a eq '--max-spread' && defined $ARGV[$i + 1]) { $max_spread = $ARGV[++$i] + 0; }
	elsif ($a eq '--max-luma' && defined $ARGV[$i + 1]) { $max_luma = $ARGV[++$i] + 0; }
	elsif ($a eq '--json' && defined $ARGV[$i + 1]) { $json_path = $ARGV[++$i]; }
	elsif ($a eq '--ticket' && defined $ARGV[$i + 1]) { $ticket_path = $ARGV[++$i]; }
	elsif ($a eq '--help' || $a eq '-h') {
		print "usage: perl scripts/black_images.pl [--apply] [--limit N] [--max-mean F] [--max-spread F] [--max-luma F] [--json PATH] [--ticket PATH]\n";
		exit 0;
	}
}

my $suds = &subs::suds_grabber();
my @standards = @{ &subs::note_encryption_standards() };
my $inspect = sub { return &subs::plaintext_verdict($_[0]); };

# Open a sealed (or plain) file into a temp path an encoder can read.
sub open_plain {
	my ($path, $stamp) = @_;
	return undef unless length $path && -e $path;
	if ($path !~ /\.enc$/i) { return $path; }
	my $passwords = &subs::db_query('select * from security where level != ? and level != ? and timestamp <= ? order by timestamp DESC', 'padlock', 'door', $stamp);
	my @secrets;
	push @secrets, $suds if defined $suds && length $suds;
	foreach my $p ( @{ $passwords->hashes } ) {
		my $secret = &subs::decrypter($suds, $p->{'credential'}, $stamp);
		push @secrets, $secret if defined $secret && length $secret;
	}
	my $opened = &subs::sealed_file_open($path, \@secrets, \@standards, 1, $inspect);
	return undef unless $opened && defined $opened->{'data'} && length $opened->{'data'};
	my ($fh, $tmp) = tempfile(SUFFIX => '.img', TMPDIR => 1);
	binmode $fh;
	print $fh $opened->{'data'};
	close $fh;
	return $tmp;
}

sub stats {
	my ($path) = @_;
	return undef unless $path && -e $path;
	my $out = `magick $path -colorspace Gray -format '%[fx:mean] %[fx:standard_deviation] %[fx:maxima]' info: 2>/dev/null`;
	chomp $out;
	my @v = split ' ', $out;
	return undef unless scalar @v == 3 && $v[0] =~ /^[0-9.eE+-]+$/;
	return { mean => $v[0] + 0, spread => $v[1] + 0, luma => $v[2] + 0 };
}

sub is_black {
	my ($s) = @_;
	return 0 unless $s;
	return ($s->{'mean'} <= $max_mean && $s->{'spread'} <= $max_spread && $s->{'luma'} <= $max_luma) ? 1 : 0;
}

my $rows = &subs::db_query('select uuid, app, timestamp, server_time, file from appointments where file is not null and type = ? order by timestamp', 'image')->hashes;
my @candidates;
my ($checked, $failed) = (0, 0);
PHOTO:
foreach my $appt ( @{$rows} ) {
	my $files = eval { decode_json($appt->{'file'}) } || [];
	foreach my $f ( @{$files} ) {
		next unless ($f->{'type'} || 'image') eq 'image';
		my $file = $f->{'f'} || '';
		next unless length $file;
		next unless -e $file;
		last PHOTO if $limit && $checked >= $limit;
		$checked++;
		my $stamp = $f->{'server_time'} || $appt->{'server_time'};
		# the thumbnail is the cheap witness; the original confirms a candidate
		my ($probe_path, $probe_tmp, $from) = ($f->{'thumb'}, undef, 'thumb');
		unless (length($probe_path) && -e $probe_path && (-s $probe_path) > 100) {
			$probe_path = $file;
			$from = 'original';
		}
		my $probe = &open_plain($probe_path, $stamp);
		$probe_tmp = $probe if defined $probe && $probe ne $probe_path;
		if (!defined $probe) { print "NOREAD $file\n"; $failed++; next; }
		my $thumb_stats = &stats($probe);
		if (defined $probe_tmp) { unlink $probe_tmp; $probe_tmp = undef; }
		if (!$thumb_stats) { print "NOREAD $file\n"; $failed++; next; }
		next unless &is_black($thumb_stats);
		# a black thumbnail may be a failed render, so read the photo itself
		my $full = &open_plain($file, $stamp);
		my $full_tmp = (defined $full && $full ne $file) ? $full : undef;
		my $full_stats = defined $full ? &stats($full) : undef;
		if (defined $full_tmp) { unlink $full_tmp; }
		if (!defined $full || !$full_stats) { print "NOREAD $file\n"; $failed++; next; }
		next unless &is_black($full_stats);
		# delete_file names the appointment and the file entry; without both a
		# removal would quietly do nothing
		next unless length($appt->{'uuid'} || '') && length($f->{'uuid'} || '');
		push @candidates, {
			app => $appt->{'app'} || '',
			app_uuid => $appt->{'uuid'} || '',
			file_uuid => $f->{'uuid'} || '',
			file => $file,
			thumb => $f->{'thumb'} || '',
			name => $f->{'of'} || $file,
			timestamp => $appt->{'timestamp'} || 0,
			probe_from => $from,
			mean => sprintf('%.4f', $full_stats->{'mean'}),
			spread => sprintf('%.4f', $full_stats->{'spread'}),
			luma => sprintf('%.4f', $full_stats->{'luma'}),
		};
		print $apply ? 'REMOVE ' : 'black  ', $appt->{'app'} || '', ' ', $file,
			' (mean ', $full_stats->{'mean'}, ' spread ', $full_stats->{'spread'}, ")\n";
	}
}

write_json($json_path, \@candidates) if length $json_path;

my $removed = 0;
if ($apply && scalar @candidates) {
	my $delete = &delete_sender($ticket_path);
	my $stamp_dir = '.shots/black-quarantine-' . time();
	unless (-d $stamp_dir) { make_path($stamp_dir) or die "cannot make $stamp_dir: $!\n"; }
	my $manifest = [];
	foreach my $c ( @candidates ) {
		my $kept = { %{$c} };
		foreach my $key (qw/file thumb/) {
			my $p = $c->{$key} || '';
			next unless length $p && -e $p;
			my $dest = $stamp_dir . '/' . $c->{'file_uuid'} . '-' . ($key eq 'thumb' ? 'thumb-' : '') . ($p =~ s{.*/}{}r);
			copy($p, $dest) or warn "copy failed $p: $!\n";
			$kept->{$key . '_kept'} = $dest;
		}
		push @{$manifest}, $kept;
		my $tx = $delete->($c);
		if ($tx->is_success) { $removed++; }
		else { warn 'delete failed ', $c->{'file_uuid'}, ': ', $tx->code, ' ', $tx->body, "\n"; }
	}
	write_json($stamp_dir . '/manifest.json', $manifest);
	print "kept a copy of each removed photo in $stamp_dir (gitignored)\n";
}

printf "%s: checked=%d black=%d removed=%d failed=%d\n",
	($apply ? 'APPLIED' : 'DRY RUN'), $checked, scalar @candidates, $removed, $failed;

sub write_json {
	my ($path, $data) = @_;
	open(my $fh, '>', $path) or die "cannot write $path: $!\n";
	print $fh encode_json($data);
	close $fh;
}

# The app's own route wants the session cookie the ticket mints. The ticket is a
# real credential and lives in gitignored scratch; nothing is written to a log.
sub delete_sender {
	my ($ticket_file) = @_;
	my $config = eval { decode_json(do { local $/; open(my $cf, '<', 'config.json') or die $!; <$cf> }) } || {};
	my $working_port = $config->{'working_port'} || $config->{'port'} || 3000;
	$main_url = 'https://127.0.0.1:' . $working_port;
	open(my $tf, '<', $ticket_file) or die "no ticket at $ticket_file (pass --ticket)\n";
	my $ticket = <$tf>;
	close $tf;
	$ticket =~ s/\s+$//;
	my $boot = Mojo::UserAgent->new->insecure(1);
	my $res = $boot->get($ticket)->res;
	die "ticket failed: " . $res->code . "\n" unless $res->is_success;
	my ($cookie) = ($res->headers->header('Set-Cookie') || '') =~ /^([^;]+)/;
	die "the ticket minted no session cookie\n" unless $cookie;
	my $ua = Mojo::UserAgent->new->insecure(1)->max_redirects(0);
	return sub {
		my ($c) = @_;
		return $ua->post($main_url . '/manager/delete_file'
			=> { Cookie => $cookie }
			=> form => { app => $c->{'app'}, app_uuid => $c->{'app_uuid'}, file_uuid => $c->{'file_uuid'} })->res;
	};
}
