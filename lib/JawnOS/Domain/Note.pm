package subs;

# Note: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Crypt::Simple;
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use File::Type;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our $NOTE_MEMO_MAX;
# ---- fast sealed-file opens --------------------------------------------------
#
# Rock and roll used to read the whole file, derive a key and decrypt every byte
# once per credential in the rotation history. Two facts make that unnecessary:
# a key can be tested on a short prefix (File::Type never looks past byte 5122),
# and a file that opened once will open with the same secret and standard next
# time. The helpers below read the container once, test keys on 16 KB, and remember
# the winner for as long as the file is unchanged. Nothing here changes the
# container: the bytes on disk stay exactly what openssl writes.
our $SEALED_PROBE_BYTES;
our $device;
our $gb;
our %m;
our %note_key_material;
our %note_memo;
our $note_memo_bytes;
our @note_memo_order;
our $note_security_memo;
# The verdict for a decrypted prefix. File::Type knows the formats it ships,
# but WebM/Matroska is EBML: it often comes back application/octet-stream. The
# old probes treated a webm path as good enough for *any* credential, so the
# first (wrong) secret won and the file was served as garbage. Sniff the
# plaintext's own magic first; it is the only thing that says the key is right.
# This is the house's primary sniffer: the table covers the media, documents,
# archives, executables and fonts a person actually stores, and text is
# recognised from its bytes rather than its extension. File::Type is only the
# last resort for a format the table does not name.
our $plaintext_ft;
# Open a sealed file, remembering the secret/standard that opened it. $range is
# an optional [ start, length ] (length undef means to the end). Returns a hash:
# data, secret, standard, verdict, total, start, length; or { unsatisfiable }.
# With $stream set (and no range, nopad, an in-process cipher and a non-PDF
# verdict) it returns { stream => 1, ct, spec, key, iv, total, ... } instead of
# the body, so the caller can pump the plaintext out a chunk at a time.
our %sealed_file_memo;

# Seal $content with the inner cipher, returning the openssl container (or undef).
sub note_seal_container {
	my ($content, $secret, $standard) = @_;
	my $spec = &note_cipher_spec($standard);
	if ($spec) {
		my $salt = &note_random_salt();
		return undef unless defined $salt && length $salt == 8;
		my $klen = $spec->{'keylen'} + $spec->{'ivlen'};
		my $kiv = eval { &note_kdf($secret, $salt, $klen) };
		return undef unless defined $kiv && length $kiv == $klen;
		my $key = substr($kiv, 0, $spec->{'keylen'});
		my $iv = substr($kiv, $spec->{'keylen'}, $spec->{'ivlen'});
		my $ct = eval {
			$spec->{'family'} eq 'ctr' ? &note_ctr_mode($spec)->encrypt($content, $key, $iv)
			                           : &note_cbc_mode($spec)->encrypt($content, $key, $iv)
		};
		return undef unless defined $ct;
		return 'Salted__' . $salt . $ct;
	}
	# not a cipher we can run in-process: let openssl do it. The bytes are raw -
	# base64 here only bought a 33% copy on each side.
	my $container = &note_openssl_run(['openssl', 'enc', '-e', '-' . $standard, '-pbkdf2'], $content, $secret);
	return undef unless defined $container && length $container;
	return $container;
}

sub note_encrypter {
	my ($secret, $content, $keep_newline) = @_;
	return undef unless defined $content && length $content;
	# The websocket hands text back as characters (an emoji is one code point,
	# not its four UTF-8 bytes). MD5 and the cipher both refuse a wide string,
	# so a message carrying an emoji, an accent or CJK text used to return undef
	# and never reach the thread. Seal the same UTF-8 bytes the rest of the
	# house stores, and note_decrypter hands the characters back.
	$content = encode_utf8($content) if utf8::is_utf8($content);
	# A new note loses one trailing newline. A re-seal must keep the plaintext
	# exactly: the note already lost that newline when it was first written, and
	# stripping again would quietly shorten it.
	$content =~ s/\r?\n$// unless $keep_newline;
	my $md5 = &shorthand_name(md5_sum($content), 5);
	my $standard = &note_encryption_standard();
	my $container = &note_seal_container($content, $secret, $standard);
	# never hand back a letter that cannot be read again
	return undef unless defined $container && length $container;
	my $almost_ready = encode_base64($container, '') . ':::---:::' . $standard . ':::---:::' . $md5;
	my $returner = &subs::encrypter($secret, $almost_ready);
	return $returner;
}

# Open an openssl container with the inner cipher; undef when it will not open.
# $nopad leaves the PKCS#7 padding on (the file path sniffs the plaintext by its
# own nose, so it asks for the bytes untouched). $limit decrypts only that many
# leading ciphertext bytes - enough to sniff a key without paying for the whole
# file. A limit is only meaningful with $nopad: a note needs its last block to
# strip PKCS#7, so a limited open returns the raw prefix instead.
sub note_open_container {
	my ($container, $secret, $standard, $nopad, $limit) = @_;
	my $spec = &note_cipher_spec($standard);
	if ($spec) {
		# The in-process families run with no openssl fallback: a wrong key then
		# costs nothing but a failed padding check, instead of two forked openssl
		# processes per attempt while the credential history is walked.
		return undef unless substr($container, 0, 8) eq 'Salted__' && length($container) > 16;
		my $salt = substr($container, 8, 8);
		my $ct = substr($container, 16);
		my $take = length $ct;
		if (defined $limit) {
			return undef unless $nopad;
			$take = $limit if $limit < $take;
			if ($spec->{'family'} eq 'cbc') {
				$take = int($take / $spec->{'ivlen'}) * $spec->{'ivlen'};
				$take = $spec->{'ivlen'} if $take == 0 && length($ct) >= $spec->{'ivlen'};
			}
		}
		my $chunk = $take == length($ct) ? $ct : substr($ct, 0, $take);
		my $material = &note_key_material($secret, $salt, $spec);
		return undef unless $material;
		return eval {
			$spec->{'family'} eq 'ctr' ? &note_ctr_mode($spec)->decrypt($chunk, $material->{'key'}, $material->{'iv'})
			                           : &note_cbc_mode($spec, $nopad)->decrypt($chunk, $material->{'key'}, $material->{'iv'})
		};
	}
	# a cipher we cannot run in-process: openssl, and a second try through the
	# legacy provider for the older ciphers
	my $plain = &note_openssl_open($container, $secret, $standard, 0, $nopad);
	return $plain if defined $plain && length $plain;
	return &note_openssl_open($container, $secret, $standard, 1, $nopad);
}

sub note_openssl_open {
	my ($container, $secret, $standard, $legacy, $nopad) = @_;
	my @args = ('openssl', 'enc', '-d', '-' . $standard, '-pbkdf2');
	push @args, '-provider', 'default', '-provider', 'legacy' if $legacy;
	push @args, '-nopad' if $nopad;
	return &note_openssl_run(\@args, $container, $secret);
}

# The file sealing is the very same container, read from and written to a path.
sub note_seal_bytes { my ($plain, $secret, $standard) = @_; return &note_seal_container($plain, $secret, $standard); }

sub note_open_bytes { my ($container, $secret, $standard, $nopad) = @_; return &note_open_container($container, $secret, $standard, $nopad); }

sub seal_file {
	my ($in_path, $out_path, $secret, $standard) = @_;
	my $plain = eval { &read_file($in_path) };
	return 0 unless defined $plain && length $plain;
	my $container = &note_seal_bytes($plain, $secret, $standard);
	return 0 unless defined $container && length $container;
	# Write beside the destination, then rename. The caller shreds the plaintext
	# on a true answer, so `-e` alone (or a short write) used to keep a broken
	# container and destroy the only good copy; it also must not damage an
	# existing file when this is an in-place re-seal.
	my $temp = $out_path . '.part.' . &random_string_creator(10);
	eval { &write_file($temp, $container) };
	my $ok = (-e $temp && (-s $temp || 0) == length($container)) ? 1 : 0;
	if (!$ok || !rename $temp, $out_path) {
		unlink $temp;
		return 0;
	}
	return 1;
}

# ZIP containers name themselves inside the archive: ODF and EPUB put an
# uncompressed `mimetype` first, OOXML leaves `[Content_Types].xml` and then
# `word/`, `xl/` or `ppt/`, and iWork leaves `Index/*.iwa`. The prefix is
# enough to read the local headers, so a .docx is not just "a zip".
sub zip_container_verdict {
	my ($head) = @_;
	my @names;
	my $mimetype = '';
	my $pos = 0;
	my $len = length $head;
	my $seen = 0;
	while ($pos + 30 <= $len && $seen++ < 512) {
		last unless substr($head, $pos, 4) eq "PK\x03\x04";
		my $flags = unpack('v', substr($head, $pos + 6, 2));
		my $method = unpack('v', substr($head, $pos + 8, 2));
		my $csize = unpack('V', substr($head, $pos + 18, 4));
		my $usize = unpack('V', substr($head, $pos + 22, 4));
		my $nlen = unpack('v', substr($head, $pos + 26, 2));
		my $elen = unpack('v', substr($head, $pos + 28, 2));
		last if $pos + 30 + $nlen > $len;
		my $name = substr($head, $pos + 30, $nlen);
		push @names, $name;
		my $data = $pos + 30 + $nlen + $elen;
		if ($name eq 'mimetype' && $method == 0 && $usize > 0 && $data + $usize <= $len) {
			$mimetype = substr($head, $data, $usize);
		}
		last if $flags & 0x08;    # data descriptor: the sizes here are not trustworthy
		my $next = $data + $csize;
		last if $next <= $pos;
		$pos = $next;
	}
	my %has = map { $_ => 1 } @names;
	$mimetype =~ s/^\s+|\s+$//g;
	return $mimetype if $mimetype =~ m{^application/(?:vnd\.oasis\.opendocument\.[a-z.+-]+|epub\+zip)$};
	# Apple iWork packages
	return 'application/vnd.apple.keynote' if $has{'Index/Presentation.iwa'};
	return 'application/vnd.apple.numbers' if $has{'Index/CalculationEngine.iwa'};
	return 'application/vnd.apple.pages' if $has{'Index/Document.iwa'};
	# Microsoft Office: macro-enabled flavours carry vbaProject.bin
	return 'application/vnd.ms-word.document.macroEnabled.12' if $has{'word/vbaProject.bin'};
	return 'application/vnd.ms-excel.sheet.macroEnabled.12' if $has{'xl/vbaProject.bin'};
	return 'application/vnd.ms-powerpoint.presentation.macroEnabled.12' if $has{'ppt/vbaProject.bin'};
	return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' if grep { m{^word/} } @names;
	return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' if grep { m{^xl/} } @names;
	return 'application/vnd.openxmlformats-officedocument.presentationml.presentation' if grep { m{^ppt/} } @names;
	return 'application/vnd.android.package-archive' if $has{'AndroidManifest.xml'} && $has{'classes.dex'};
	return 'application/java-archive' if $has{'META-INF/MANIFEST.MF'} && grep { m{\.class$} } @names;
	return 'application/vnd.ms-xpsdocument' if $has{'FixedDocSeq.fdseq'};
	return 'application/vnd.ms-package.3dmanufacturing-3dmodel+zip' if $has{'3D/3dmodel.model'};
	return 'application/vnd.openxmlformats-officedocument' if $has{'[Content_Types].xml'};
	return 'application/epub+zip' if $has{'META-INF/container.xml'};
	return 'application/zip';
}

# Legacy Office files are OLE2 compound documents. The directory's stream names
# say which program wrote it; the first directory sector is inside the prefix.
sub ole_container_verdict {
	my ($head) = @_;
	return undef if length($head) < 512;
	my $sector = unpack('v', substr($head, 30, 2));
	$sector = 512 if $sector < 128 || $sector > 65536;
	my $dir = unpack('V', substr($head, 48, 4));
	return undef if $dir == 0xFFFFFFFE || $dir > 1_000_000;
	my $off = ($dir + 1) * $sector;
	my $len = length $head;
	my $count = 0;
	while ($off + 128 <= $len && $count++ < 64) {
		my $nlen = unpack('v', substr($head, $off + 64, 2));
		last unless $nlen >= 2 && $nlen <= 64;
		my $name = substr($head, $off, $nlen - 2);
		$name =~ s/\x00//g;
		return 'application/msword' if $name eq 'WordDocument';
		return 'application/vnd.ms-excel' if $name eq 'Workbook' || $name eq 'Book';
		return 'application/vnd.ms-powerpoint' if $name eq 'PowerPoint Document';
		return 'application/vnd.openxmlformats-officedocument' if $name eq 'EncryptedPackage';
		$off += 128;
	}
	return undef;
}

sub plaintext_verdict {
	my ($head, $strict) = @_;
	return undef unless defined $head && length $head;
	# a zip is only the wrapper; decide what it holds before the generic table
	if (substr($head, 0, 4) eq "PK\x03\x04" || substr($head, 0, 4) eq "PK\x05\x06") {
		return &zip_container_verdict($head);
	}
	# OLE2 compound file: legacy .doc/.xls/.ppt (and encrypted OOXML)
	if (substr($head, 0, 8) eq "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1") {
		my $ole = &ole_container_verdict($head);
		return defined $ole ? $ole : 'application/x-ole-storage';
	}
	my @exact = (
		[ "\x1a\x45\xdf\xa3", 'video/webm' ],                  # EBML: webm / matroska
		[ "\x89PNG\r\n\x1a\n", 'image/png' ],
		[ "\xff\xd8\xff", 'image/jpeg' ],
		[ 'GIF87a', 'image/gif' ],
		[ 'GIF89a', 'image/gif' ],
		[ "\x00\x00\x01\x00", 'image/x-icon' ],
		[ "\x00\x00\x02\x00", 'image/x-icon' ],
		[ 'II*' . "\0", 'image/tiff' ],
		[ 'MM' . "\0*", 'image/tiff' ],
		[ '8BPS', 'image/vnd.adobe.photoshop' ],
		[ 'gimp xcf ', 'image/x-xcf' ],
		[ 'DDS ', 'image/vnd-ms.dds' ],
		[ 'KTX 11', 'image/ktx' ],
		[ "\x00\x00\x00\x0cjP  \r\n\x87\n", 'image/jp2' ],
		[ "\xff\x4f\xff\x51", 'image/jp2' ],
		[ "\x00\x00\x00\x0cJXL \r\n\x87\n", 'image/jxl' ],
		[ 'qoif', 'image/qoi' ],
		[ 'farbfeld', 'image/farbfeld' ],
		[ "v/1\x01", 'image/openexr' ],
		[ 'FLIF', 'image/flif' ],
		[ 'glTF', 'model/gltf-binary' ],
		[ '%PDF', 'application/pdf' ],
		[ '%!PS', 'application/postscript' ],
		[ '{\\rtf', 'application/rtf' ],
		[ 'OggS', 'application/ogg' ],
		[ 'fLaC', 'audio/flac' ],
		[ 'FLAC', 'audio/flac' ],
		[ 'ID3', 'audio/mpeg' ],
		[ 'MThd', 'audio/midi' ],
		[ '#!AMR', 'audio/amr' ],
		[ 'caff', 'audio/x-caf' ],
		[ 'wvpk', 'audio/wavpack' ],
		[ 'MAC ', 'audio/ape' ],
		[ 'MPCK', 'audio/musepack' ],
		[ 'TTA1', 'audio/tta' ],
		[ 'wOFF', 'font/woff' ],
		[ 'wOF2', 'font/woff2' ],
		[ 'OTTO', 'font/otf' ],
		[ 'ttcf', 'font/collection' ],
		[ "\x00\x01\x00\x00\x00", 'font/ttf' ],
		[ "\x1f\x8b", 'application/gzip' ],
		[ 'BZh', 'application/x-bzip2' ],
		[ "\xfd7zXZ\x00", 'application/x-xz' ],
		[ "7z\xbc\xaf\x27\x1c", 'application/x-7z-compressed' ],
		[ "Rar!\x1a\x07", 'application/vnd.rar' ],
		[ "PK\x07\x08", 'application/zip' ],
		[ "!<arch>\n", 'application/x-ar' ],
		[ "\xed\xab\xee\xdb", 'application/x-rpm' ],
		[ "QFI\xfb", 'application/x-qemu-disk' ],
		[ "\x7fELF", 'application/x-elf' ],
		[ "\xca\xfe\xba\xbe", 'application/x-mach-binary' ],
		[ "\xfe\xed\xfa\xce", 'application/x-mach-binary' ],
		[ "\xce\xfa\xed\xfe", 'application/x-mach-binary' ],
		[ "\xfe\xed\xfa\xcf", 'application/x-mach-binary' ],
		[ "\xcf\xfa\xed\xfe", 'application/x-mach-binary' ],
		[ "\x00asm", 'application/wasm' ],
		[ "dex\n", 'application/x-dex' ],
		[ "SQLite format 3\0", 'application/vnd.sqlite3' ],
		[ "FLV\x01", 'video/x-flv' ],
		[ "\x30\x26\xb2\x75\x8e\x66\xcf\x11", 'video/x-ms-asf' ],
		[ "\x00\x00\x01\xba", 'video/mpeg' ],
		[ "\x00\x00\x01\xb3", 'video/mpeg' ],
	);
	foreach my $pair ( @exact ) {
		# A strict pass is picking a credential, not naming a file: a two- or
		# three-byte coincidence is how a wrong key was read as a file in the
		# sealed-file self-test, so only four bytes or a structural check counts.
		next if $strict && length($pair->[0]) < 4;
		return $pair->[1] if substr($head, 0, length $pair->[0]) eq $pair->[0];
	}
	# RIFF / FORM containers name their flavour in the first 12 bytes
	if (length($head) >= 12 && substr($head, 0, 4) eq 'RIFF') {
		my $kind = substr($head, 8, 4);
		return 'image/webp' if $kind eq 'WEBP';
		return 'audio/wav'  if $kind eq 'WAVE';
		return 'video/x-msvideo' if $kind eq 'AVI ';
	}
	if (length($head) >= 12 && substr($head, 0, 4) eq 'FORM') {
		my $kind = substr($head, 8, 4);
		return 'audio/aiff' if $kind eq 'AIFF';
		return 'audio/aiff' if $kind eq 'AIFC';
	}
	# ISO base media: the brand after ftyp says what it holds
	if (length($head) >= 12 && substr($head, 4, 4) eq 'ftyp') {
		my $brand = substr($head, 8, 4);
		return 'image/heic' if $brand =~ /^(?:heic|heix|hevc|hevx|mif1|msf1)$/;
		return 'image/avif' if $brand eq 'avif';
		return 'video/quicktime' if $brand eq 'qt  ';
		return 'audio/mp4' if $brand =~ /^(?:M4A |M4B )$/;
		return 'video/mp4';
	}
	# a BMP is 'BM' plus a zeroed reserved field; 'BM' alone is too weak
	if (substr($head, 0, 2) eq 'BM' && length($head) >= 26 && substr($head, 6, 4) eq "\0\0\0\0") {
		return 'image/bmp';
	}
	# a DOS/PE executable: 'MZ' alone is two bytes, and two bytes is what a
	# wrong key can match by accident. The PE header is the proof.
	if (substr($head, 0, 2) eq 'MZ' && length($head) >= 64 && index($head, "PE\0\0") >= 0) {
		return 'application/x-dosexec';
	}
	# MPEG transport stream: sync bytes 188 apart
	if (substr($head, 0, 1) eq "\x47" && length($head) > 188 && substr($head, 188, 1) eq "\x47") {
		return 'video/mp2t';
	}
	# MPEG audio / ADTS frame sync
	if (!$strict && length($head) >= 4 && substr($head, 0, 1) eq "\xff") {
		my $b2 = ord(substr($head, 1, 1));
		return 'audio/aac' if ($b2 & 0xF6) == 0xF0;
		return 'audio/mpeg' if ($b2 & 0xE0) == 0xE0;
	}
	# tar names itself 257 bytes in
	if (length($head) >= 262 && substr($head, 257, 5) eq 'ustar') {
		return 'application/x-tar';
	}
	# markup, before the generic text test
	my $probe = substr($head, 0, 4096);
	if ($probe =~ /^\s*<\?xml/i) {
		return 'image/svg+xml' if $probe =~ /<svg[\s>]/i;
		# flat OpenDocument (.fodt/.fods/.fodp) names its MIME on the root
		if ($probe =~ /office:mimetype\s*=\s*["']([^"']+)["']/i) {
			my $flat = $1;
			return $flat if $flat =~ m{^application/vnd\.oasis\.opendocument\.};
		}
		# flat OOXML (Word 2003 XML / Flat OPC)
		return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' if $probe =~ /<pkg:package[\s>]/i && $probe =~ /spreadsheetml/i;
		return 'application/vnd.openxmlformats-officedocument.presentationml.presentation' if $probe =~ /<pkg:package[\s>]/i && $probe =~ /presentationml/i;
		return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' if $probe =~ /<w:document[\s>]/i || ($probe =~ /<pkg:package[\s>]/i && $probe =~ /wordprocessingml/i);
		return 'application/msword' if $probe =~ /<w:wordDocument[\s>]/i;
		return 'application/xml';
	}
	if ($probe =~ /^\s*(?:<!doctype\s+html|<html[\s>])/i) {
		return 'text/html';
	}
	# the EBML doctype names the flavour a little further in
	my $doc = substr($head, 0, 64);
	return 'video/x-matroska' if index($doc, 'matroska') >= 0;
	return 'video/webm' if index($doc, 'webm') >= 0;
	return 'text/plain' if &plaintext_looks_text($head);
	# A guessed type is enough to name a file, never to choose a credential.
	return undef if $strict;
	$plaintext_ft ||= File::Type->new();
	my $fd = eval { $plaintext_ft->checktype_contents($head) };
	return (defined $fd && $fd ne 'application/octet-stream') ? $fd : undef;
}

# Text is bytes with no NUL and no control characters; valid UTF-8 is text even
# when most of it is outside ASCII. This is strict enough that a wrong key's
# random bytes do not pass, which is what makes it usable as a key verdict.
sub plaintext_looks_text {
	my ($head) = @_;
	return 0 unless defined $head && length $head;
	# a 16-byte block of padding from an empty seal is not text, and random
	# bytes that short can pass by accident
	return 0 if length($head) < 32;
	return 0 if index($head, "\0") >= 0;
	# The decode itself is the test. high bytes that are not valid UTF-8 are a
	# wrong key's output far more often than they are text, so they have to
	# clear the printable check below; reading the decode's answer is what
	# stopped a 32-byte window of random bytes being taken as text about once
	# in twenty runs.
	my $copy = $head;
	if (eval { utf8::decode($copy) }) {
		my $control = ($copy =~ tr/\x00-\x08\x0b\x0c\x0e-\x1f\x7f//);
		return 1 if $control == 0;
	}
	return &folders_reads_as_text($head);
}

sub open_file {
	my ($in_path, $secret, $standard, $nopad) = @_;
	my $container = eval { &read_file($in_path) };
	return undef unless defined $container && length $container;
	return &note_open_bytes($container, $secret, $standard, $nopad);
}

# The identity of a sealed file: any change to it (a reseal) makes a different
# key. inode covers a replace, size and mtime cover an in-place rewrite.
sub sealed_file_identity {
	my ($path) = @_;
	my @st = stat($path);
	return undef unless @st;
	return join "\x1f", $path, $st[1], $st[7], $st[9];
}

# Try candidate secrets and standards in order, decrypting only the prefix for
# each. $inspect receives the prefix and returns a true value (the verdict) when
# it looks like the file wanted. Returns the winner without the body bytes.
sub sealed_file_probe {
	my ($container, $secrets, $standards, $inspect) = @_;
	# Two passes. The first takes only a credential whose plaintext carries a
	# signature strong enough to be proof; the second is the old one, for a file
	# whose type the house cannot name. Without the first, a wrong key whose
	# random bytes happened to look like a file was accepted - the sealed-file
	# self-test's wrong-credential walk caught it about once in fifteen runs.
	foreach my $strict (1, 0) {
		foreach my $secret (@{$secrets || []}) {
			next unless defined $secret && length $secret;
			foreach my $standard (@{$standards || []}) {
				next unless defined $standard && length $standard;
				my $probe = &note_open_container($container, $secret, $standard, 1, $SEALED_PROBE_BYTES);
				next unless defined $probe && length $probe;
				my $verdict = $inspect ? eval { $inspect->($probe) } : 1;
				next unless $verdict;
				next if $strict && !&plaintext_strong($probe);
				# An openssl-only standard has no prefix mode, so the "probe" above
				# already decrypted the whole stream. Hand it back rather than making
				# the caller decrypt it a second time.
				my $full = &note_cipher_spec($standard) ? undef : $probe;
				return { secret => $secret, standard => $standard, verdict => $verdict, full => $full };
			}
		}
	}
	return undef;
}

# The verdict a credential has to earn: a real signature, not a guess.
sub plaintext_strong {
	return &plaintext_verdict($_[0], 1);
}

# Advance a CTR IV by whole blocks (big-endian, which is what openssl's EVP
# counter is), so a range can start anywhere without decrypting what precedes it.
sub note_iv_advance {
	my ($iv, $blocks) = @_;
	return $iv unless $blocks;
	my $out = $iv;
	my $carry = $blocks;
	for (my $i = length($out) - 1; $i >= 0 && $carry; $i--) {
		my $v = ord(substr($out, $i, 1)) + $carry;
		substr($out, $i, 1) = chr($v & 0xff);
		$carry = int($v / 256);
	}
	return $out;
}

# Decrypt one byte range of a container. CTR is seekable by advancing the IV;
# CBC starts at the requested block using the previous ciphertext block as its IV.
# The caller passes nopad-style files (no padding block to strip from the tail),
# which is exactly the stream rock_and_roll serves today.
sub note_open_slice {
	my ($container, $secret, $standard, $start, $len) = @_;
	my $spec = &note_cipher_spec($standard) or return undef;
	return undef unless substr($container, 0, 8) eq 'Salted__' && length($container) > 16;
	my $salt = substr($container, 8, 8);
	my $ct = substr($container, 16);
	my $total = length $ct;
	$start = 0 if !defined $start || $start < 0;
	return undef if $start > $total;
	$len = $total - $start if !defined $len || $start + $len > $total;
	$len = 0 if $len < 0;
	return '' if $len == 0;
	my $block = $spec->{'ivlen'};
	my $first = int($start / $block);
	my $skip = $start - $first * $block;
	my $take = $skip + $len;
	if ($spec->{'family'} eq 'cbc') {
		$take = int(($take + $block - 1) / $block) * $block;
	}
	my $avail = $total - $first * $block;
	$take = $avail if $take > $avail;
	return undef if $take <= 0;
	my $ct_slice = substr($ct, $first * $block, $take);
	my $material = &note_key_material($secret, $salt, $spec);
	return undef unless $material;
	my $iv = $material->{'iv'};
	if ($spec->{'family'} eq 'ctr') {
		$iv = &note_iv_advance($iv, $first);
	} elsif ($first > 0) {
		$iv = substr($ct, ($first - 1) * $block, $block);
	}
	my $plain = eval {
		$spec->{'family'} eq 'ctr' ? &note_ctr_mode($spec)->decrypt($ct_slice, $material->{'key'}, $iv)
		                           : &note_cbc_mode($spec, 1)->decrypt($ct_slice, $material->{'key'}, $iv)
	};
	return undef unless defined $plain;
	return substr($plain, $skip, $len);
}

sub sealed_file_open {
	my ($in_path, $secrets, $standards, $nopad, $inspect, $range, $stream) = @_;
	my $id = &sealed_file_identity($in_path);
	my $container = eval { &read_file($in_path) };
	return undef unless defined $container && length $container;
	my $cand;
	if ($id && (my $memo = $sealed_file_memo{$id})) {
		$cand = &sealed_file_probe($container, [ $memo->{'secret'} ], [ $memo->{'standard'} ], $inspect);
		delete $sealed_file_memo{$id} unless $cand;
	}
	$cand ||= &sealed_file_probe($container, $secrets, $standards, $inspect);
	return undef unless $cand;
	if ($id) {
		%sealed_file_memo = () if scalar(keys %sealed_file_memo) >= 256;
		$sealed_file_memo{$id} = { secret => $cand->{'secret'}, standard => $cand->{'standard'} };
	}
	my $spec = &note_cipher_spec($cand->{'standard'});
	if ($stream && !$range && $nopad && $spec && ($cand->{'verdict'} // '') !~ /pdf/) {
		return undef unless substr($container, 0, 8) eq 'Salted__' && length($container) > 16;
		my $salt = substr($container, 8, 8);
		my $material = &note_key_material($cand->{'secret'}, $salt, $spec);
		return undef unless $material;
		return {
			stream => 1,
			container => $container,
			secret => $cand->{'secret'},
			standard => $cand->{'standard'},
			verdict => $cand->{'verdict'},
			spec => $spec,
			key => $material->{'key'},
			iv => $material->{'iv'},
			total => length($container) - 16,
		};
	}
	my $result = { secret => $cand->{'secret'}, standard => $cand->{'standard'}, verdict => $cand->{'verdict'} };
	if ($range && $spec && $nopad) {
		my $total = length($container) - 16;
		my ($start, $len) = @{$range};
		$start = 0 if !defined $start || $start < 0;
		return { unsatisfiable => 1, total => $total } if $start >= $total && $total > 0;
		$len = $total - $start if !defined $len || $start + $len > $total;
		my $slice = &note_open_slice($container, $cand->{'secret'}, $cand->{'standard'}, $start, $len);
		return undef unless defined $slice;
		$result->{'data'} = $slice;
		$result->{'total'} = $total;
		$result->{'start'} = $start;
		$result->{'length'} = $len;
		return $result;
	}
	my $data;
	if ($nopad && defined $cand->{'full'}) {
		$data = $cand->{'full'};
	}
	else {
		$data = &note_open_container($container, $cand->{'secret'}, $cand->{'standard'}, $nopad);
	}
	return undef unless defined $data && length $data;
	my $total = length $data;
	if ($range) {
		my ($start, $len) = @{$range};
		$start = 0 if !defined $start || $start < 0;
		return { unsatisfiable => 1, total => $total } if $start >= $total && $total > 0;
		$len = $total - $start if !defined $len || $start + $len > $total;
		$data = substr($data, $start, $len);
		$result->{'start'} = $start;
		$result->{'length'} = $len;
	}
	$result->{'data'} = $data;
	$result->{'total'} = $total;
	return $result;
}

sub note_security_rows {
	my ($timestamp) = @_;
	my $now = time;
	if (!$note_security_memo || $now - $note_security_memo->{'at'} > 3) {
		my $q = &db_query('select * from security where level != ? and level != ? order by ost desc', 'padlock', 'door');
		$note_security_memo = { at => $now, rows => ($q ? $q->hashes : []) };
	}
	my @rows = @{ $note_security_memo->{'rows'} };
	@rows = grep { ($_->{'ost'} || 0) <= $timestamp } @rows if $timestamp;
	return \@rows;
}

sub note_unseal {
	my ($key, $contented, $strict) = @_;
	# The ordinary reader, not the strict one, by default: a note written by an
	# older build had its outer Crypt::Simple layer sealed under the empty
	# passphrase while its inner cipher stayed keyed to the real secret (an upload
	# with no resolved session wrote those). decrypter() still reads that
	# empty-key layer and refuses a JS1 blob that does not open, so the
	# authenticated format stays closed. A caller judging a token passes $strict,
	# which refuses the empty-key layer instead of accepting it.
	my $payload = $strict ? &subs::decrypter_strict($key, $contented)
	                      : &subs::decrypter($key, $contented);
	return undef unless defined $payload && length $payload;
	my ($b64, $standard, $md5) = split ':::---:::', $payload, 3;
	return undef unless defined $b64 && length $b64;
	$standard = 'aes-256-ctr' unless defined $standard && length $standard;
	my $container = decode_base64($b64);
	return undef unless defined $container && length $container;
	my $plain = &note_open_container($container, $key, $standard);
	return undef unless defined $plain && length $plain;
	if (defined $md5 && length $md5) {
		# the md5 names the plaintext: when it matches, the key was the right one.
		# (The old check compared a full digest against the short marker and so
		# never actually verified anything.)
		my $mark = lc substr($md5, 0, 5);
		return $plain if &shorthand_name(md5_sum($plain), 5) eq $mark;
		my $chopped = $plain; chomp $chopped;
		return $chopped if &shorthand_name(md5_sum($chopped), 5) eq $mark;
		# the marker does not name it and the bytes are not text: the wrong key
		return undef if $plain =~ /[^\x00-\x7F]/;
	}
	return $plain;
}

sub note_memo_put {
	my ($key, $value) = @_;
	return if exists $note_memo{$key};
	$note_memo{$key} = $value;
	$note_memo_bytes += length($value) + 40;
	push @note_memo_order, $key;
	while ($note_memo_bytes > $NOTE_MEMO_MAX && @note_memo_order) {
		my $old = shift @note_memo_order;
		next unless exists $note_memo{$old};
		$note_memo_bytes -= length($note_memo{$old}) + 40;
		delete $note_memo{$old};
	}
}

sub note_decrypter {
	my ($secret, $contented, $timestamp, $tries) = @_;
	$tries ||= 0;
	return '' unless defined $contented && length $contented;

	# a plain note is memoised on (key, ciphertext, timestamp); '' there means a
	# known miss. The timestamp is part of the key because a note written before a
	# key rotation is opened with the credentials current then - and it is always
	# present for mail, so leaving it out kept every message out of the memo and
	# made a re-read pay the key derivation again. A timed miss is not kept: a
	# historical credential that arrives later can still open it.
	my $memo_key = md5_sum($secret // '') . ':' . md5_sum($contented) . ':' . md5_sum($timestamp // '');
	return $note_memo{$memo_key} if defined $note_memo{$memo_key};

	# the key in use now opens almost every note, and one in-process try costs
	# nothing, so it is tried alone first
	my $plain = &note_unseal($secret, $contented);

	# it did not: the note was written before the key rotated, under one of the
	# credentials that were current at $timestamp (or, given none, the whole
	# history), newest first. Working those keys out is not free, so it only
	# happens for the notes that need them.
	unless (defined $plain) {
		foreach my $row ( @{ &note_security_rows($timestamp) } ) {
			my $old = &decrypter($secret, $row->{'credential'});
			next unless defined $old && length $old;
			$plain = &note_unseal($old, $contented);
			last if defined $plain;
		}
	}

	# nothing opened it: the note may predate the oldest credential we hold, so ask
	# again from a moment further back, twice at most
	if (!defined $plain && !$timestamp && $tries < 2) {
		my $deep = &note_decrypter($secret, $contented, &subs::rightNow() * 10000, $tries + 1);
		$plain = $deep if defined $deep && length $deep;
	}

	$plain = '' unless defined $plain;
	&note_memo_put($memo_key, $plain) if length $plain || !$timestamp;
	return $plain;
}

sub note_decrypter_strict {
	my ($secret, $contented) = @_;
	return '' unless defined $contented && length $contented;
	# A token or a peer's bytes must open under the real secret, never the legacy
	# empty-passphrase layer. Kept beside the ordinary note reader so at-rest
	# notes can stay compatible while a token read cannot.
	my $memo_key = 'strict:' . md5_sum($secret // '') . ':' . md5_sum($contented);
	return $note_memo{$memo_key} if defined $note_memo{$memo_key};
	my $plain = &note_unseal($secret, $contented, 1);
	$plain = '' unless defined $plain;
	&note_memo_put($memo_key, $plain);
	return $plain;
}

# --- bringing saved notes to the authenticated seal --------------------------
# Older uploads sealed the outer Crypt::Simple layer under the empty passphrase
# while the inner cipher stayed keyed to the real secret. The ordinary reader
# still opens those, but the value at rest is not in the authenticated JS1
# format. This sweep rewrites each legacy note as JS1 under the key in use now;
# it is idempotent and only writes a value that proves it reads back strictly.
sub note_reseal_value {
	my ($v, $K, $timestamp) = @_;
	return undef unless defined $v && length $v && defined $K && length $K;
	return $v if index($v, 'JS1:') == 0 && defined &subs::decrypter_strict($K, $v);
	my $plain = &note_decrypter($K, $v, $timestamp);
	return undef unless defined $plain && length $plain;
	# Re-seal the plaintext exactly: this note is already missing the newline
	# note_encrypter drops on a first write, so asking it to drop another would
	# shorten the note and fail the read-back below.
	my $re = &note_encrypter($K, $plain, 1);
	return undef unless defined $re && length $re && index($re, 'JS1:') == 0;
	return undef unless defined &subs::decrypter_strict($K, $re);
	return undef unless &note_decrypter_strict($K, $re) eq $plain;
	return $re;
}

# A value sealed by encrypter (not the note container) can be legacy too: the
# outer Crypt::Simple layer under the real key, or under the empty passphrase.
# Re-wrap the plaintext as JS1 under the key in use now. A note payload is
# refused here so a caller can try this after note_reseal_value without ever
# wrapping a note's inner payload as plain text.
sub sealed_reseal_value {
	my ($v, $K) = @_;
	return undef unless defined $v && length $v && defined $K && length $K;
	return $v if index($v, 'JS1:') == 0 && defined &subs::decrypter_strict($K, $v);
	my $plain = &subs::decrypter_strict($K, $v);
	$plain = &subs::decrypter($K, $v) unless defined $plain;
	return undef unless defined $plain && length $plain;
	return undef if index($plain, ':::---:::') >= 0;
	my $re = &subs::encrypter($K, $plain);
	return undef unless defined $re && index($re, 'JS1:') == 0;
	return undef unless defined &subs::decrypter_strict($K, $re);
	return undef unless &subs::decrypter_strict($K, $re) eq $plain;
	return $re;
}

sub note_reseal {
	my ($apply, $opts) = @_;
	$opts ||= {};
	my $limit = $opts->{'limit'};
	my $limit_sql = (defined $limit && $limit =~ /^\d+$/ && $limit > 0) ? ' limit ' . int($limit) : '';
	my $want = $opts->{'table'} || 'both';
	my $K = &suds_grabber() || $gb::suds;
	return { ok => 0, error => 'no key on this machine' } unless $K;
	my $counts = { appointments => 0, notes => 0, ocr => 0, mailbox => 0, warehouse => 0, credentials => 0, settings => 0, keyboard => 0, tickets => 0, appointments_data => 0, vault => 0, mail_tokens => 0, device_tokens => 0, failed => 0, already => 0, seen => 0 };
	my $next_appt = $opts->{'after_appt'} || 0;
	my $next_mail = $opts->{'after_mail'} || 0;
	my ($more_appt, $more_mail) = (0, 0);

	if ($want eq 'both' || $want eq 'appointments') {
		my $rows = &db_query('select rowid, notes, start_notes, end_notes, file, ost from appointments where rowid > ? and (length(notes)>0 or length(start_notes)>0 or length(end_notes)>0 or length(file)>0) order by rowid' . $limit_sql, $next_appt)->hashes;
		foreach my $row ( @{ $rows || [] } ) {
			$counts->{'seen'}++;
			$next_appt = $row->{'rowid'};
			my %up;
			foreach my $field ( qw/notes start_notes end_notes/ ) {
				my $v = $row->{$field};
				next unless defined $v && length $v;
				my $re = &note_reseal_value($v, $K, $row->{'ost'});
				$re = &sealed_reseal_value($v, $K) unless defined $re;
				if (!defined $re) { $counts->{'failed'}++; next; }
				if ($re eq $v) { $counts->{'already'}++; next; }
				$up{$field} = $re;
				$counts->{'notes'}++;
			}
			if (defined $row->{'file'} && length $row->{'file'}) {
				my $decoded = eval { decode_json($row->{'file'}) };
				my $shape = ref $decoded;
				my @files = $shape eq 'ARRAY' ? @{$decoded} : $shape eq 'HASH' ? ($decoded) : ();
				my $changed = 0;
				foreach my $f ( @files ) {
					next unless ref $f eq 'HASH' && defined $f->{'ocr'} && length $f->{'ocr'};
					my $re = &note_reseal_value($f->{'ocr'}, $K, $row->{'ost'});
					if (!defined $re) { $counts->{'failed'}++; next; }
					if ($re eq $f->{'ocr'}) { $counts->{'already'}++; next; }
					$f->{'ocr'} = $re;
					$changed = 1;
					$counts->{'ocr'}++;
				}
				$up{'file'} = encode_json($decoded) if $changed && $shape;
			}
			next unless scalar keys %up;
			$counts->{'appointments'}++;
			next unless $apply;
			# Only write the row we read: a live writer's newer value must not be
			# clobbered by this sweep.
			my %where = ( rowid => $row->{'rowid'} );
			$where{$_} = $row->{$_} for keys %up;
			&db_update('appointments', \%up, \%where);
		}
		$more_appt = (defined $limit && $limit > 0 && scalar(@{ $rows || [] }) >= $limit) ? 1 : 0;
	}

	if ($want eq 'mailbox' || ($want eq 'both' && !$more_appt)) {
		my $mail = &db_query('select rowid, subject, body, ost from mailbox where rowid > ? and (length(subject)>0 or length(body)>0) order by rowid' . $limit_sql, $next_mail)->hashes;
		foreach my $row ( @{ $mail || [] } ) {
			$counts->{'seen'}++;
			$next_mail = $row->{'rowid'};
			my %up;
			foreach my $field ( qw/subject body/ ) {
				my $v = $row->{$field};
				next unless defined $v && length $v;
				my $re = &note_reseal_value($v, $K, $row->{'ost'});
				$re = &sealed_reseal_value($v, $K) unless defined $re;
				if (!defined $re) { $counts->{'failed'}++; next; }
				if ($re eq $v) { $counts->{'already'}++; next; }
				$up{$field} = $re;
			}
			next unless scalar keys %up;
			$counts->{'mailbox'}++;
			next unless $apply;
			my %where = ( rowid => $row->{'rowid'} );
			$where{$_} = $row->{$_} for keys %up;
			&db_update('mailbox', \%up, \%where);
		}
		$more_mail = (defined $limit && $limit > 0 && scalar(@{ $mail || [] }) >= $limit) ? 1 : 0;
	}

	if ($want eq 'rest') {
		# Warehouse notes and saved credential payloads are the same note shape.
		my $wh = &db_query('select rowid, notes, ost from warehouse where length(notes)>0')->hashes;
		foreach my $row ( @{ $wh || [] } ) {
			my $re = &note_reseal_value($row->{'notes'}, $K, $row->{'ost'});
			if (!defined $re) { $counts->{'failed'}++; next; }
			if ($re eq $row->{'notes'}) { $counts->{'already'}++; next; }
			$counts->{'warehouse'}++;
			next unless $apply;
			&db_update('warehouse', { notes => $re }, { rowid => $row->{'rowid'}, notes => $row->{'notes'} });
		}
		my $cr = &db_query('select rowid, payload, ost from credentials where length(payload)>0')->hashes;
		foreach my $row ( @{ $cr || [] } ) {
			my $re = &note_reseal_value($row->{'payload'}, $K, $row->{'ost'});
			if (!defined $re) { $counts->{'failed'}++; next; }
			if ($re eq $row->{'payload'}) { $counts->{'already'}++; next; }
			$counts->{'credentials'}++;
			next unless $apply;
			&db_update('credentials', { payload => $re }, { rowid => $row->{'rowid'}, payload => $row->{'payload'} });
		}
		# Note-shaped settings. Most settings are plain text and are not this
		# sweep's business; a sealed one that will not open is counted a failure.
		my $set = &db_query("select rowid, app, setting, value, ost from settings where length(value)>0 and not (app='__president' and setting='vault') and setting != 'operator_door' and not (app='mailbox' and setting='email_config') and not (app='keyboard' and setting in ('keyboard','calculator'))")->hashes;
		foreach my $row ( @{ $set || [] } ) {
			my $re = &note_reseal_value($row->{'value'}, $K, $row->{'ost'});
			if (!defined $re) {
				$counts->{'failed'}++
					if defined &subs::decrypter($K, $row->{'value'})
					   || defined &subs::decrypter_strict($K, $row->{'value'});
				next;
			}
			if ($re eq $row->{'value'}) { $counts->{'already'}++; next; }
			$counts->{'settings'}++;
			next unless $apply;
			&db_update('settings', { value => $re }, { rowid => $row->{'rowid'}, value => $row->{'value'} });
		}
		# The keyboard layouts are encrypter-sealed rather than note-shaped.
		my $kb = &db_query("select rowid, value from settings where app='keyboard' and setting in ('keyboard','calculator') and length(value)>0")->hashes;
		foreach my $row ( @{ $kb || [] } ) {
			my $re = &sealed_reseal_value($row->{'value'}, $K);
			next unless defined $re;
			if ($re eq $row->{'value'}) { $counts->{'already'}++; next; }
			$counts->{'keyboard'}++;
			next unless $apply;
			&db_update('settings', { value => $re }, { rowid => $row->{'rowid'}, value => $row->{'value'} });
		}
		# A ticket's secret is url-escaped base64 of a note sealed under the
		# ticket's own one-time password; the password stays a random plaintext key.
		my $tk = &db_query("select rowid, password, secret from tickets where length(password)>0 and length(secret)>0")->hashes;
		foreach my $row ( @{ $tk || [] } ) {
			my $ver = url_unescape(decode_base64($row->{'secret'}));
			next unless defined $ver && length $ver;
			my $re = &note_reseal_value($ver, $row->{'password'}, undef);
			next unless defined $re;
			if ($re eq $ver) { $counts->{'already'}++; next; }
			my $new = url_escape(encode_base64($re, ''));
			$counts->{'tickets'}++;
			next unless $apply;
			&db_update('tickets', { secret => $new }, { rowid => $row->{'rowid'}, secret => $row->{'secret'} });
		}
		# Appointment data is plain JSON for most rows; a row sealed by an older
		# path is upgraded and the plain rows are left exactly as they are.
		my $ad = &db_query('select rowid, data, ost from appointments where length(data)>0')->hashes;
		foreach my $row ( @{ $ad || [] } ) {
			my $re = &note_reseal_value($row->{'data'}, $K, $row->{'ost'});
			$re = &sealed_reseal_value($row->{'data'}, $K) unless defined $re;
			next unless defined $re;
			if ($re eq $row->{'data'}) { $counts->{'already'}++; next; }
			$counts->{'appointments_data'}++;
			next unless $apply;
			&db_update('appointments', { data => $re }, { rowid => $row->{'rowid'}, data => $row->{'data'} });
		}
		# The vault is sealed with the house key, not the suds.
		my $hk = eval { &house_key() } || '';
		if (length $hk) {
			my $vr = &db_query("select rowid, value from settings where app='__president' and setting='vault' and length(value)>0")->hashes;
			foreach my $row ( @{ $vr || [] } ) {
				# Already JS1 under the house key: re-sealing would only churn the
				# salt (and the value) on every run.
				next if index($row->{'value'}, 'JS1:') == 0 && defined &subs::decrypter_strict($hk, $row->{'value'});
				my $suds = &note_decrypter($hk, $row->{'value'});
				next unless defined $suds && length $suds;
				my $re = &note_encrypter($hk, $suds, 1);
				next unless defined $re && index($re, 'JS1:') == 0;
				next unless defined &subs::decrypter_strict($hk, $re);
				next unless &note_decrypter_strict($hk, $re) eq $suds;
				if ($re eq $row->{'value'}) { $counts->{'already'}++; next; }
				$counts->{'vault'}++;
				next unless $apply;
				&db_update('settings', { value => $re }, { rowid => $row->{'rowid'}, value => $row->{'value'} });
			}
		}
		# Mail account secrets live inside the email_config JSON.
		my $ec = &db_query("select rowid, value from settings where app='mailbox' and setting='email_config' and length(value)>0")->hashes;
		foreach my $row ( @{ $ec || [] } ) {
			my $servers = eval { decode_json($row->{'value'}) };
			next unless ref $servers eq 'ARRAY';
			my $changed = 0;
			foreach my $es ( @{$servers} ) {
				next unless ref $es eq 'HASH';
				foreach my $field ( qw/password oauth_access_token oauth_refresh_token oauth_client_secret/ ) {
					my $v = $es->{$field};
					next unless defined $v && length $v;
					my $re = &note_reseal_value($v, $K, undef);
					if (!defined $re) { $counts->{'failed'}++; next; }
					if ($re eq $v) { $counts->{'already'}++; next; }
					$es->{$field} = $re;
					$changed = 1;
					$counts->{'mail_tokens'}++;
				}
			}
			next unless $changed;
			my $new = encode_json($servers);
			next unless $apply;
			&db_update('settings', { value => $new }, { rowid => $row->{'rowid'}, value => $row->{'value'} });
		}
		# Watch/deck authorizations live inside the operator_door JSON, sealed
		# under the per-device patience rather than the house suds.
		my $od = &db_query("select rowid, value from settings where setting='operator_door' and length(value)>0")->hashes;
		foreach my $row ( @{ $od || [] } ) {
			my $door = eval { decode_json($row->{'value'}) };
			next unless ref $door eq 'HASH';
			my @pairs = ( [ $door->{'__shutup'}->{'patience'}, $door->{'__specs'}, 'authorization' ] );
			if (ref $door->{'__shutup'}->{'previous'} eq 'HASH') {
				push @pairs, [ $door->{'__shutup'}->{'previous'}->{'patience'}, $door->{'__shutup'}->{'previous'}, 'authorization' ];
			}
			my $changed = 0;
			foreach my $pair ( @pairs ) {
				my ($patience, $holder, $field) = @{$pair};
				next unless $patience && ref $holder eq 'HASH' && defined $holder->{$field} && length $holder->{$field};
				my $raw = decode_base64($holder->{$field});
				next unless length $raw;
				my $re = &note_reseal_value($raw, $patience, undef);
				if (!defined $re) { $counts->{'failed'}++; next; }
				if ($re eq $raw) { $counts->{'already'}++; next; }
				$holder->{$field} = encode_base64($re, '');
				$changed = 1;
				$counts->{'device_tokens'}++;
			}
			next unless $changed;
			my $new = encode_json($door);
			next unless $apply;
			&db_update('settings', { value => $new }, { rowid => $row->{'rowid'}, value => $row->{'value'} });
		}
	}

	return { ok => 1, apply => $apply ? 1 : 0, %{$counts},
		next_appt => $next_appt, next_mail => $next_mail,
		more_appt => $more_appt, more_mail => $more_mail,
		done => ($more_appt || $more_mail) ? 0 : 1 };
}

sub manufacturer_grabber {
	my $manufacturers = &subs::db_query('select * from settings where (setting = ? or setting = ?) and value = ? and device = ?', 'pos', 'mab','manufacturer',$device)->hashes;
	my $mans = [];
	foreach my $m ( @{$manufacturers} ) {
		push @{$mans}, $m->{'app'};
	}
	$gb::abilities->{'manufacturer'}->{'options'} = $mans;
}

sub step_ingest {
	# Turn a batch of the pedometer's cumulative samples into measure
	# appointments - the shape the AP's /wigi collection has always produced.
	# Each sample's `steps` is the watch's running count; what gets recorded is
	# the difference from the sample before it, and `$base` is the cumulative
	# value just before the batch. The AP path sends the whole array with base
	# zero; a BLE push sends one small message carrying its own base, so both
	# delta the same way. A count that went backwards means the pedometer was
	# reset under us (the AP path does that): that sample then stands on its
	# own rather than losing the steps.
	my ($steps, $base) = @_;
	return unless ref $steps eq 'ARRAY' && scalar @{$steps};
	my $last_step = $base || 0;
	my (@measures,$first_step);
	foreach my $step ( @{$steps} ) {
		next unless ref $step eq 'HASH' && defined $step->{'steps'};
		my $ls = $step->{'steps'};
		$step->{'steps'} = $step->{'steps'} - $last_step;
		if ($step->{'steps'} < 0) {
			$step->{'steps'} = $ls;
		}
		$last_step = $ls;
		$step->{'timestamp'} = $step->{'timestamp'} * 1000;
		if ($step->{'steps'} > 0 && !$first_step) {
			$first_step = $step->{'timestamp'};
		}
		if ($step->{'timestamp'} && $step->{'steps'} > 0) {
			$step->{'uuid'} = &subs::random_string_creator(19);
			push @measures, $step;
		}
	}
	return unless scalar @measures > 0;
	my $jstep = encode_json \@measures;
	&Manager::appointment_writer(&subs::controller_builder(), {
		app => &subs::unformat_name(&subs::setting_grabber({ app => 'me', setting => 'my_name' })),
		type => 'measure',
		measures => $jstep,
		timestamp => &subs::rightNow(),
		seen => 'yes',
		duration => $first_step ? &subs::rightNow() - $first_step : 1
	});
}

1;
