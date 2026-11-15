# tests-for: lib/JawnOS/PDF.pm
# covers:    the sparse TrueType subset the dependency-free writer embeds for a
#           paper in another script: stable glyph ids, rebuilt loca/glyf,
#           dropped DSIG, recomputed table directory and checksums, composite
#           components kept, and the size the subset saves.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;

use JawnOS::PDF ();

my $TEXT = "\x{0418}\x{0432}\x{0430}\x{043D}";    # Иван

# --- a face for a non-Latin script ------------------------------------------
# Walk the same candidate list the writer walks; a machine with no TrueType
# face covering Cyrillic skips rather than fails.
my ($SOURCE, $SOURCE_PATH);
CANDIDATE:
for my $path (JawnOS::PDF::_candidate_ttfs('Helvetica')) {
	my $font = JawnOS::PDF::_ttf_load($path) or next;
	for my $ch (split //, $TEXT) {
		next CANDIDATE unless JawnOS::PDF::_glyph($font, ord $ch);
	}
	($SOURCE, $SOURCE_PATH) = ($font, $path);
	last;
}
plan skip_all => 'no candidate TrueType font covers Cyrillic' unless $SOURCE;

# The writer picks a face per character and groups a run by its path; every
# character has to land on this face or the ids below are not the ids drawn.
for my $ch (split //, $TEXT) {
	my $found = JawnOS::PDF::_font_for_char('Helvetica', $ch);
	plan skip_all => 'the writer picks a different face per character'
		unless $found && $found->{'font'}{'path'} eq $SOURCE_PATH;
}

# --- small readers for the sfnt the test inspects ---------------------------
sub table_index {
	my ($data) = @_;
	return undef unless defined $data && length($data) >= 12;
	return undef unless substr($data, 0, 4) eq "\x00\x01\x00\x00";
	my $count = unpack('n', substr($data, 4, 2));
	return undef if $count < 1 || 12 + $count * 16 > length $data;
	my (%tab, @order);
	for my $i (0 .. $count - 1) {
		my ($tag, $sum, $off, $len) = unpack('a4 N N N', substr($data, 12 + $i * 16, 16));
		return undef if $off + $len > length $data;
		$tab{$tag} = { sum => $sum, off => $off, len => $len };
		push @order, $tag;
	}
	return (\%tab, \@order);
}

sub loca_offsets {
	my ($data, $tab, $count) = @_;
	my $head = substr($data, $tab->{'head'}{'off'}, $tab->{'head'}{'len'});
	my $format = unpack('s>', substr($head, 50, 2));
	my $raw = substr($data, $tab->{'loca'}{'off'}, $tab->{'loca'}{'len'});
	my @off = $format
		? unpack('N*', $raw)
		: map { $_ * 2 } unpack('n*', $raw);
	splice @off, $count + 1 if @off > $count + 1;
	return @off;
}

sub checksum {
	my ($bytes) = @_;
	my $sum = 0;
	for (my $i = 0; $i < length $bytes; $i += 4) {
		my $word = substr($bytes, $i, 4);
		$word .= "\0" x (4 - length $word) if length $word < 4;
		$sum = ($sum + unpack('N', $word)) & 0xFFFFFFFF;
	}
	return $sum;
}

sub components {
	my ($glyph) = @_;
	return () if length($glyph) < 10;
	return () unless unpack('s>', substr($glyph, 0, 2)) < 0;
	my @out;
	my $p = 10;
	while (1) {
		return () if $p + 4 > length $glyph;
		my $flags = unpack('n', substr($glyph, $p, 2));
		push @out, unpack('n', substr($glyph, $p + 2, 2));
		$p += 4;
		$p += ($flags & 0x0001) ? 4 : 2;
		if    ($flags & 0x0008) { $p += 2 }
		elsif ($flags & 0x0040) { $p += 4 }
		elsif ($flags & 0x0080) { $p += 8 }
		return () if $p > length $glyph;
		last unless $flags & 0x0020;
	}
	return @out;
}

# The first /Length ... /Length1 object is the embedded face; the content
# streams carry /Length but no /Length1.
sub fontfile2 {
	my ($pdf) = @_;
	my $re = qr{/Length (\d+) /Length1 (\d+)( /Filter /FlateDecode)? >>\nstream\n};
	return () unless $pdf =~ m{$re}g;
	my ($len, $len1, $filter) = ($1, $2, $3);
	my $start = pos($pdf);
	return () if $start + $len > length $pdf;
	my $stream = substr($pdf, $start, $len);
	if ($filter) {
		require IO::Uncompress::Inflate;
		my $out = '';
		IO::Uncompress::Inflate::inflate(\$stream => \$out) or return ();
		$stream = $out;
	}
	return ($stream, $len1);
}

# --- draw a paper in the other script ---------------------------------------
my $pdf = JawnOS::PDF->new(size => 'letter');
$pdf->text($TEXT, 72, 100, size => 12);
my $bytes = $pdf->bytes;

like($bytes, qr{/Subtype /Type0}, 'the text is still a Type0 font');
like($bytes, qr{/Encoding /Identity-H}, 'still Identity-H');
like($bytes, qr{/CIDToGIDMap /Identity}, 'still an identity CID-to-GID map');

my ($font, $length1) = fontfile2($bytes);
ok(defined $font, 'the embedded face was found and inflated')
	or BAIL_OUT('no /FontFile2 stream to inspect');
is(length($font), $length1, '/Length1 is the subset byte count');

# --- the embedded font is a valid sfnt --------------------------------------
is(substr($font, 0, 4), "\x00\x01\x00\x00", 'the subset starts with a TrueType sfnt header');
my ($tab, $order) = table_index($font);
ok($tab, 'the subset has a table directory') or BAIL_OUT('unparseable table directory');
for my $need (qw(head hhea maxp hmtx cmap loca glyf)) {
	ok($tab->{$need}, "the $need table survived");
}
ok(!$tab->{'DSIG'}, 'DSIG was dropped (its signature no longer applies)');
is_deeply($order, [sort @{$order}], 'directory entries are sorted by tag');
my @misaligned = grep { $tab->{$_}{'off'} % 4 } keys %{$tab};
is_deeply(\@misaligned, [], 'every table starts on a 4-byte boundary');

my @bad_checksum;
for my $tag (sort keys %{$tab}) {
	my $table = substr($font, $tab->{$tag}{'off'}, $tab->{$tag}{'len'});
	substr($table, 8, 4) = "\0\0\0\0" if $tag eq 'head';
	push @bad_checksum, $tag if checksum($table) != $tab->{$tag}{'sum'};
}
is_deeply(\@bad_checksum, [], 'every table checksum matches its directory entry');
is(checksum($font), 0xB1B0AFBA, 'the whole-font checksum adjustment is correct');

# --- glyph ids did not move -------------------------------------------------
my $source_data = $SOURCE->{'data'};
my ($source_tab) = table_index($source_data);
ok($source_tab, 'the source face has a table directory');
my $source_count = unpack('n', substr($source_data, $source_tab->{'maxp'}{'off'} + 4, 2));
my $subset_count = unpack('n', substr($font, $tab->{'maxp'}{'off'} + 4, 2));
is($subset_count, $source_count, 'maxp.numGlyphs is unchanged');
is($subset_count, $SOURCE->{'num_glyphs'}, 'and matches the loaded face');

my @source_loca = loca_offsets($source_data, $source_tab, $source_count);
my @subset_loca = loca_offsets($font, $tab, $source_count);
is(scalar @subset_loca, $source_count + 1, 'loca covers every glyph id');
my @descending = grep { $subset_loca[$_] < $subset_loca[$_ - 1] } 1 .. $source_count;
is_deeply(\@descending, [], 'loca is monotonic');

my %drawn;
for my $ch (split //, $TEXT) {
	$drawn{JawnOS::PDF::_glyph($SOURCE, ord $ch)} = 1;
}
for my $gid (sort { $a <=> $b } keys %drawn) {
	ok($subset_loca[$gid + 1] > $subset_loca[$gid], "drawn glyph $gid kept its outline");
}
ok($subset_loca[1] > $subset_loca[0], '.notdef kept its outline');

# Expand the drawn glyphs through composite records so "unused" is exact.
my $source_glyf = substr($source_data, $source_tab->{'glyf'}{'off'}, $source_tab->{'glyf'}{'len'});
my %reachable = (0 => 1);
my @queue = keys %drawn;
while (@queue) {
	my $gid = shift @queue;
	next if $reachable{$gid}++;
	my $start = $source_loca[$gid];
	my $end = $source_loca[$gid + 1];
	my $glyph = $end > $start ? substr($source_glyf, $start, $end - $start) : '';
	push @queue, components($glyph);
}
my @emptied = grep {
	!$reachable{$_} && $source_loca[$_ + 1] > $source_loca[$_]
		&& $subset_loca[$_ + 1] == $subset_loca[$_]
} 0 .. $source_count - 1;
cmp_ok(scalar @emptied, '>', 0, 'at least one unused glyph outline was emptied');

# --- a composite the text reaches kept its components -----------------------
my @composites = grep {
	$reachable{$_} && $source_loca[$_ + 1] > $source_loca[$_]
		&& components(substr($source_glyf, $source_loca[$_],
			$source_loca[$_ + 1] - $source_loca[$_]))
} sort { $a <=> $b } keys %reachable;
if (@composites) {
	for my $gid (@composites) {
		ok($subset_loca[$gid + 1] > $subset_loca[$gid], "composite glyph $gid kept its outline");
		my @parts = components(substr($source_glyf, $source_loca[$gid],
			$source_loca[$gid + 1] - $source_loca[$gid]));
		for my $part (@parts) {
			ok($subset_loca[$part + 1] > $subset_loca[$part],
				"component glyph $part of $gid kept its outline");
		}
	}
}
else {
	pass('the chosen face has no composite reachable from the text');
}

# --- the subset is materially smaller ---------------------------------------
my $source_size = length $source_data;
my $subset_size = length $font;
cmp_ok($subset_size, '<', $source_size, 'the embedded face is smaller than the source');
if ($source_size >= 300_000) {
	cmp_ok($subset_size, '<', $source_size * 0.5, 'and less than half of it');
}
diag("font $SOURCE_PATH: $source_size bytes -> $subset_size bytes embedded");

# --- the content stream still draws the same glyph ids ----------------------
my %in_pdf;
for my $hex ($bytes =~ /<([0-9a-f]+)>\s*Tj/g) {
	my $raw = pack('H*', $hex);
	for (my $i = 0; $i + 1 < length $raw; $i += 2) {
		$in_pdf{unpack('n', substr($raw, $i, 2))} = 1;
	}
}
is_deeply(
	[sort { $a <=> $b } keys %in_pdf],
	[sort { $a <=> $b } keys %drawn],
	'the content stream carries the same two-byte glyph ids',
);

# --- a WinAnsi-only paper still embeds nothing ------------------------------
my $plain = JawnOS::PDF->new(size => 'letter');
$plain->text('HELLO', 72, 100);
unlike($plain->bytes, qr{/FontFile2}, 'a WinAnsi-only document embeds no /FontFile2');

# --- the short loca format --------------------------------------------------
# The installed faces all use the long format, so build a tiny font whose
# loca is uint16/2: four glyphs, gid 2 a composite over gid 1, gid 3 unused.
subtest 'format-0 loca and a composite component' => sub {
	my $glyph0 = pack('s>', 1) . ("\0" x 14);
	my $glyph1 = pack('s>', 1) . ("\0" x 10);
	my $glyph2 = pack('s>', -1) . ("\0" x 8)
		. pack('n n', 0x0001, 1) . ("\0" x 4);    # ARG_1_AND_2_ARE_WORDS, gid 1
	my $glyph3 = pack('s>', 1) . ("\0" x 8);
	my $glyf = $glyph0 . $glyph1 . $glyph2 . $glyph3;    # 16 + 12 + 18 + 10
	my $head = "\0" x 54;
	substr($head, 50, 2) = pack('s>', 0);                  # indexToLocFormat
	my $maxp = "\0" x 6;
	substr($maxp, 4, 2) = pack('n', 4);                    # numGlyphs
	my %table = (
		head => $head,
		hhea => "\0" x 36,
		maxp => $maxp,
		hmtx => "\0" x 16,
		cmap => "\0" x 4,
		loca => pack('n*', 0, 8, 14, 23, 28),             # 0,16,28,46,56
		glyf => $glyf,
	);

	# A source sfnt is just a header, a sorted directory and the tables.
	my @tags = sort keys %table;
	my $n = scalar @tags;
	my $offset = 12 + $n * 16;
	my %rec;
	for my $tag (@tags) {
		$offset += 2 - $offset % 2 if $offset % 2;
		$rec{$tag} = [$offset, length $table{$tag}];
		$offset += length $table{$tag};
	}
	my $selector = 0;
	$selector++ while (1 << ($selector + 1)) <= $n;
	my $source = pack('N n n n n', 0x00010000, $n,
		(1 << $selector) * 16, $selector, $n * 16 - (1 << $selector) * 16);
	for my $tag (@tags) {
		$source .= $tag . pack('N N N', 0, @{$rec{$tag}});
	}
	for my $tag (@tags) {
		$source .= "\0" x ($rec{$tag}[0] - length $source);
		$source .= $table{$tag};
	}

	my $subset = JawnOS::PDF::_ttf_subset($source, { 2 => 1 });
	ok(defined $subset, 'the short-loca face subsets') or return;
	my ($stab) = table_index($subset);
	ok($stab, 'the subset has a table directory') or return;
	is(unpack('s>', substr($subset, $stab->{'head'}{'off'} + 50, 2)), 0,
		'the short loca format is preserved');
	my @lo = loca_offsets($subset, $stab, 4);
	is(scalar @lo, 5, 'loca covers all four glyph ids');
	is_deeply(\@lo, [0, 16, 28, 48, 48],
		'glyphs stay in id order and the unused one is empty');
	cmp_ok($lo[1], '>', $lo[0], '.notdef kept its outline');
	cmp_ok($lo[2], '>', $lo[1], 'the composite component kept its outline');
	cmp_ok($lo[3], '>', $lo[2], 'the used composite kept its outline');
	is($lo[4], $lo[3], 'the unused glyph was emptied');
	is(unpack('n', substr($subset, $stab->{'maxp'}{'off'} + 4, 2)), 4,
		'numGlyphs is unchanged');
	my @bad;
	for my $tag (keys %{$stab}) {
		my $table = substr($subset, $stab->{$tag}{'off'}, $stab->{$tag}{'len'});
		substr($table, 8, 4) = "\0\0\0\0" if $tag eq 'head';
		push @bad, $tag if checksum($table) != $stab->{$tag}{'sum'};
	}
	is_deeply(\@bad, [], 'checksums are right for a short-loca subset');
	is(checksum($subset), 0xB1B0AFBA, 'and the whole-font adjustment is right');
};

done_testing();
