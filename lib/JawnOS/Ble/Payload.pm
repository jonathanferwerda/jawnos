package JawnOS::Ble::Payload;

# The toggles reply a watch asks for with `state_request`: { app => 'on'|'off' }
# for every setting the house carries. Two separate faults lived here, both
# visible at the bridge:
#
# - The map was built from every `settings` row whose setting is 'toggle', so
#   14 corrupt `app` keys (a double-encoded UTF-8 name that doubles on each
#   sync, 108 -> 786,444 bytes, plus junk rows like `{` and `{"name":"budget"}`)
#   rode along. On the phone that was 2,594 rows and 1,626,591 bytes.
# - It was then sent as one message, and the Android bridge holds writes in a
#   64 KB queue and sends plain UTF-8 (the compress flag is stored, not used),
#   so the reply overflowed and the daemon dropped it. The watch asked again and
#   the link churned.
#
# The pure halves live here so they can be tested directly: which keys are
# plausible names, and how the map is split into messages that fit. The caller
# (Ble2's state_request) still owns the socket and the order of the sends.

use strict;
use warnings;

use Encode ();
use Exporter 'import';
use JSON::PP ();

our @EXPORT_OK = qw(key_ok toggle_map toggle_wanted toggle_chunks);

# A name, not a payload. The measured keys are names like `12_grain_bread`,
# `i'm_confident`, `a&w`, `2%_milk` and `__orphan_03afafd1bfe2`; the corrupt
# ones are the 14 doubling rows (108 -> 786,444 bytes, and twice that each
# sync) and serialized leftovers. 128 bytes is far above any real name; the
# rows below that need rule 6, the ones above it this cap alone.
our $MAX_KEY_BYTES = 128;

# A message's data budget. The bridge queue is 64 KiB and the older broadcast
# path base64s the JSON (x 4/3): 24 KiB of JSON is 32 KiB on that path, leaving
# room for the wrapper and the daemon's own framing. A single entry after
# key_ok() is under ~160 bytes, so one entry can never exceed this on its own.
our $MAX_CHUNK_BYTES = 24 * 1024;

# The entry cap keeps a chunk small even when the names are short. Both limits
# are enforced; whichever binds first ends the chunk.
our $MAX_CHUNK_ENTRIES = 200;

# Is this string a plausible app name? The rules, in order:
#   1. valid UTF-8 text (a name is text; corrupt bytes are not a name)
#   2. 1..128 bytes
#   3. no control characters and no surrounding whitespace
#   4. at least one letter or digit (rules out punctuation-only leftovers)
#   5. does not begin with `{`, `[` or `"` (a serialized blob, not a name)
#   6. does not carry the double-encoding signature: a UTF-8 lead byte that was
#      itself read back as a character (`Â`, `Ã`, `â`) immediately followed by a
#      continuation-range character (U+0080..U+00BF) or by another such lead
#      character. Real text does not do this; `iÃ¢ÂÂm_confident` and the doubling
#      rows do.
#
# Rule 6 is what catches the sub-128-byte corrupt rows (the 108-byte original
# and its smaller duplicates); rule 2 catches everything above 128.
sub key_ok {
	my ($key) = @_;
	return 0 unless defined $key && !ref $key && length $key;
	# Rows from the database arrive as bytes; a name typed in this app arrives
	# as text. Ask both the same question by decoding the byte form first.
	my $text = $key;
	if (!utf8::is_utf8($text)) {
		my $decoded = eval { Encode::decode('UTF-8', $text, Encode::FB_CROAK) };
		return 0 unless defined $decoded;
		$text = $decoded;
	}
	return 0 if length(Encode::encode_utf8($text)) > $MAX_KEY_BYTES;
	return 0 if $text =~ /\p{Cc}/;
	return 0 if $text =~ /\A\s|\s\z/;
	return 0 unless $text =~ /[\p{L}\p{N}]/;
	return 0 if $text =~ /\A[\[{"]/;
	return 0 if $text =~ /[\x{C2}\x{C3}\x{E2}](?=[\x{80}-\x{BF}\x{C2}\x{C3}\x{E2}])/;
	return 1;
}

# toggle_map(\@settings_rows) -> { app => 'on' | 'off' }
# Builds the reply from the rows the caller selected. A key that fails key_ok()
# is not a name and is skipped here, before it can reach any transport. A later
# row for the same app wins, as it always did.
sub toggle_map {
	my ($rows) = @_;
	my %map;
	foreach my $row ( @{ $rows || [] } ) {
		next unless ref $row eq 'HASH';
		my $app = $row->{'app'};
		next unless key_ok($app);
		$map{$app} = (($row->{'value'} // '') eq 'on') ? 'on' : 'off';
	}
	return \%map;
}

# toggle_wanted(\%toggles, \%door) -> { app => 'on' | 'off' }
# Keep only the apps the device's own placed components name. A board, a watch
# or a deck lights the buttons it draws; the house can carry a thousand settings
# (the phone held 1281, this watch names 14). Handing a watch all of them meant a
# multi-page burst on every reconnect: the link never settled, and a tap queued
# while it was down waited for the next connection to go out.
# A door key starting `__` is a section (__specs, __shutup), not a component.
sub toggle_wanted {
	my ($toggles, $door) = @_;
	my %wanted;
	foreach my $k ( keys %{ ref $door eq 'HASH' ? $door : {} } ) {
		next if $k =~ /^__/;
		my $component = $door->{$k};
		next unless ref $component eq 'HASH';
		my $app = $component->{'app'};
		$wanted{$app} = 1 if defined $app && $app ne '';
	}
	return { map { $_ => $toggles->{$_} } grep { $wanted{$_} } keys %{ ref $toggles eq 'HASH' ? $toggles : {} } };
}

my $DEFAULT_JSON = JSON::PP->new->utf8;

# toggle_chunks(\%toggles, %options) -> \@chunks
#   encode      => sub { encode one map to bytes } (default: JSON::PP, UTF-8)
#   max_entries => entries per chunk (default: $MAX_CHUNK_ENTRIES)
#   max_bytes   => encoded bytes per chunk (default: $MAX_CHUNK_BYTES)
#
# Each chunk is a plain { app => 'on'|'off' } map the caller wraps as
# { type => 'toggles', data => $chunk }. Keys are sorted so a chunk boundary is
# reproducible, the key guard runs again here (a caller that skipped
# toggle_map() still cannot ship a corrupt key), and values are normalised to
# the shape the watch reads. An empty map returns no chunks; the caller decides
# whether a booting watch still deserves one empty message.
sub toggle_chunks {
	my ($toggles, %opt) = @_;
	my $encode = $opt{'encode'} || sub { $DEFAULT_JSON->encode($_[0]) };
	my $max_entries = $opt{'max_entries'} || $MAX_CHUNK_ENTRIES;
	my $max_bytes = $opt{'max_bytes'} || $MAX_CHUNK_BYTES;
	my @chunks;
	my $chunk = {};
	foreach my $app ( sort keys %{ $toggles || {} } ) {
		next unless key_ok($app);
		my $value = (($toggles->{$app} // '') eq 'on') ? 'on' : 'off';
		if ( keys %{$chunk} ) {
			# Ask before adding, so a chunk never ends up over either limit: the
			# entry that would cross it starts the next chunk instead. Measuring the
			# candidate with the caller's encoder keeps the bound true for whatever
			# encoder the wire actually uses.
			my $candidate = { %{$chunk}, $app => $value };
			if ( keys(%{$chunk}) >= $max_entries || length($encode->($candidate)) > $max_bytes ) {
				push @chunks, $chunk;
				$chunk = {};
			}
		}
		$chunk->{$app} = $value;
	}
	push @chunks, $chunk if keys %{$chunk};
	return \@chunks;
}

1;
