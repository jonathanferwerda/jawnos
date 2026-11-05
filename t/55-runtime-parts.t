# tests-for: scripts/app_publish.pl scripts/runtime_build.pl scripts/runtime_native_bins.pl scripts/runtime_zip.pl
# covers:    Runtime parts (docs/runtime-parts.md): media/ocr are optional archives beside the pinned core.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use Archive::Zip qw(:ERROR_CODES);

# Runtime parts (docs/runtime-parts.md): media/ocr are optional archives beside
# the pinned core. This pins the manifest contract, the build script's part
# selection and the merged jniLibs manifest, with no network and no real archive.

my $root     = abs_path("$FindBin::Bin/..");
my $build    = "$root/scripts/runtime_build.pl";
my $zip      = "$root/scripts/runtime_zip.pl";
my $bins     = "$root/scripts/runtime_native_bins.pl";
my $publish  = "$root/scripts/app_publish.pl";
my $pin_path = "$root/releases/jawnrt.json";

sub read_file {
	my ($path) = @_;
	open(my $fh, '<', $path) or die "$path: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

sub write_file {
	my ($path, $text) = @_;
	make_path(dirname($path));
	open(my $fh, '>', $path) or die "$path: $!";
	print {$fh} $text;
	close $fh;
}

# Run a command, return (exit status, combined stdout).
sub run {
	my (@cmd) = @_;
	my $out = '';
	open(my $fh, '-|', @cmd) or die "run @cmd: $!";
	while (my $line = <$fh>) { $out .= $line }
	close $fh;
	return ($? >> 8, $out);
}

sub list_paths {
	my ($out) = @_;
	return grep { !/^runtime_build:/ } split /\n/, $out;
}

# --- 1. the pin keeps the old core and adds parts ---------------------------
if (-f $pin_path) {
	my $pin = eval { decode_json(read_file($pin_path)) };
	ok($pin && ref $pin eq 'HASH', 'jawnrt.json is valid JSON');
	for my $abi (qw(aarch64 x86_64)) {
		my $core = $pin->{'abi'}{$abi} || {};
		like($core->{'file'} || '', qr/^jawnrt-\Q$abi\E-\d+\.\d+\.\d+\.zip$/,
			"$abi core file keeps its old name shape");
		like($core->{'sha256'} || '', qr/^[0-9a-f]{64}$/, "$abi core has a sha256");
		cmp_ok($core->{'size'} || 0, '>', 0, "$abi core has a size");
	}
	my $parts = $pin->{'parts'};
	ok(ref $parts eq 'HASH', 'pin carries a parts map');
	for my $abi (qw(aarch64 x86_64)) {
		next unless exists $parts->{$abi};
		ok(ref $parts->{$abi} eq 'HASH', "parts.$abi is an object");
		for my $name (sort keys %{ $parts->{$abi} }) {
			ok($name eq 'media' || $name eq 'ocr' || $name eq 'video', "known part name $name");
			my $p = $parts->{$abi}{$name} || {};
			like($p->{'file'} || '', qr/^jawnrt-\Q$abi\E-\Q$name\E-\d+\.\d+\.\d+\.zip$/,
				"$abi/$name part file name");
			like($p->{'sha256'} || '', qr/^[0-9a-f]{64}$/, "$abi/$name sha256");
			cmp_ok($p->{'size'} || 0, '>', 0, "$abi/$name size");
			like($p->{'version'} || '', qr/^\d+\.\d+\.\d+$/, "$abi/$name version");
			like($p->{'min_core'} || '', qr/^\d+\.\d+\.\d+$/, "$abi/$name min_core");
			ok($p->{'optional'}, "$abi/$name is optional");
			my $provides = $p->{'provides'};
			ok(ref $provides eq 'ARRAY' && @$provides, "$abi/$name provides paths");
			my @bad = grep { !m{^usr/} || /[*?\[]/ } @{ $provides || [] };
			is_deeply(\@bad, [], "$abi/$name provides are exact usr/ paths");
			my $bins = $p->{'bins'};
			ok(ref $bins eq 'ARRAY' && @$bins, "$abi/$name names its executables");
			my @bad_bins = grep { !m{^bin/} } @{ $bins || [] };
			is_deeply(\@bad_bins, [], "$abi/$name bins are bin/ paths");
			my $file = "$root/releases/" . ($p->{'file'} || '');
			if (-f $file) {
				is(-s $file, $p->{'size'}, "$abi/$name staged size matches the pin");
				is(sha256_hex(read_file($file)), $p->{'sha256'},
					"$abi/$name staged sha256 matches the pin");
			}
		}
	}
	my $a = $pin->{'abi'}{'aarch64'}{'file'};
	my $m = $pin->{'parts'}{'aarch64'}{'media'}{'file'};
	my $o = $pin->{'parts'}{'aarch64'}{'ocr'}{'file'};
	my $v = $pin->{'parts'}{'aarch64'}{'video'}{'file'};
	ok($v && $m && $o, 'the aarch64 pin carries video, media and ocr');
	ok($m ne $a && $o ne $a && $v ne $a && $m ne $o && $m ne $v && $o ne $v,
		'part files are distinct from core and each other');

	# The core archive is now the boot set: no ffmpeg/codec stack. The parts must
	# not carry a core path, and video must carry the codecs the core gave up.
	my $core_zip = "$root/releases/" . ($pin->{'abi'}{'aarch64'}{'file'} || '');
	if (-f $core_zip) {
		my $cz = Archive::Zip->new;
		is($cz->read($core_zip), AZ_OK, 'the pinned core archive reads');
		my %core_names = map { $_->fileName => 1 } grep { !$_->isDirectory } $cz->members;
		ok($core_names{'lib/libcrypto.so.3'}, 'core keeps openssl');
		ok($core_names{'lib/libssl.so.3'}, 'core keeps libssl');
		ok($core_names{'lib/libz.so'}, 'core keeps the libz alias');
		ok((grep { m{/CORE/libperl\.so$} } keys %core_names), 'core keeps libperl');
		ok(!$core_names{'lib/libavcodec.so.62'}, 'core no longer carries libavcodec');
		ok(!$core_names{'lib/libx265.so'}, 'core no longer carries libx265');
		ok(!$core_names{'lib/libaom.so'}, 'core no longer carries libaom');
		for my $name (sort keys %{ $pin->{'parts'}{'aarch64'} }) {
			my $file = "$root/releases/" . $pin->{'parts'}{'aarch64'}{$name}{'file'};
			next unless -f $file;
			my $pz = Archive::Zip->new;
			is($pz->read($file), AZ_OK, "$name part archive reads");
			my %part_names = map { $_->fileName => 1 } grep { !$_->isDirectory } $pz->members;
			is_deeply([ grep { $core_names{$_} } keys %part_names ], [],
				"$name does not carry a core path");
			if ($name eq 'video') {
				ok($part_names{'lib/libavcodec.so.62'}, 'video carries libavcodec');
				ok($part_names{'lib/libx265.so'}, 'video carries libx265');
				ok($part_names{'lib/libplacebo.so'}, 'video carries libplacebo');
			}
			if ($name eq 'media') {
				ok($part_names{'lib/libjxl.so'}, 'media now carries libjxl');
				ok($part_names{'lib/libx265.so'}, 'media now carries libx265');
			}
			if ($name eq 'ocr') {
				ok($part_names{'share/tessdata/eng.traineddata'}, 'ocr carries eng.traineddata');
			}
		}
	}
}
else {
	# skip() is a "last SKIP"; without the block it aborts the whole file on a
	# machine that has no staged runtime pin (a clean checkout, CI, the table).
	SKIP: {
		skip('no releases/jawnrt.json to check', 1);
	}
}

# --- 2. build-script part selection -----------------------------------------
my $tmp = tempdir(CLEANUP => 1);
my $prefix = "$tmp/prefix";
for my $p (qw(bin lib/perl5/CORE etc/ImageMagick-7 lib/ImageMagick-7.1.2/config-Q16HDRI
	share/ImageMagick-7 share/tessdata)) {
	make_path("$prefix/$p");
}
write_file("$prefix/bin/perl", "perl");
write_file("$prefix/lib/perl5/CORE/libperl.so", "perl");
write_file("$prefix/bin/magick", "magick");
write_file("$prefix/bin/convert", "convert");
write_file("$prefix/bin/tesseract", "tesseract");
write_file("$prefix/bin/ffmpeg", "ffmpeg");
write_file("$prefix/bin/ffprobe", "ffprobe");
write_file("$prefix/bin/unrelated", "no");
write_file("$prefix/etc/ImageMagick-7/colors.xml", "colors");
write_file("$prefix/etc/ImageMagick-7/log.xml", "log");
write_file("$prefix/lib/ImageMagick-7.1.2/config-Q16HDRI/configure.xml", "config");
write_file("$prefix/share/ImageMagick-7/locale.xml", "locale");
write_file("$prefix/share/tessdata/eng.traineddata", "eng");
write_file("$prefix/lib/libMagickCore-7.Q16HDRI.so", "lib");
write_file("$prefix/lib/libtesseract.so", "lib");

my ($rc, $out) = run($^X, $build, '--from', $prefix, '--part', 'media', '--abi', 'aarch64', '--list');
is($rc, 0, 'media selection succeeds');
my %media = map { $_ => 1 } list_paths($out);
ok($media{'bin/magick'}, 'media selects bin/magick');
ok($media{'etc/ImageMagick-7/colors.xml'}, 'media selects ImageMagick config');
ok($media{'share/ImageMagick-7/locale.xml'}, 'media selects ImageMagick share');
ok(!$media{'bin/tesseract'}, 'media does not select tesseract');
ok(!$media{'bin/perl'}, 'media does not select the core perl');
ok(!$media{'bin/ffmpeg'}, 'media does not select ffmpeg');
ok(!$media{'bin/unrelated'}, 'media does not select an unlisted tool');

($rc, $out) = run($^X, $build, '--from', $prefix, '--part', 'ocr', '--abi', 'aarch64', '--list');
is($rc, 0, 'ocr selection succeeds');
my %ocr = map { $_ => 1 } list_paths($out);
ok($ocr{'bin/tesseract'}, 'ocr selects bin/tesseract');
ok($ocr{'share/tessdata/eng.traineddata'}, 'ocr selects eng tessdata');
ok(!$ocr{'bin/magick'}, 'ocr does not select magick');
ok(!$ocr{'bin/perl'}, 'ocr does not select the core perl');
ok(!$ocr{'bin/ffmpeg'}, 'ocr does not select ffmpeg');

($rc, $out) = run($^X, $build, '--from', $prefix, '--part', 'video', '--abi', 'aarch64', '--list');
is($rc, 0, 'video selection succeeds');
my %video = map { $_ => 1 } list_paths($out);
ok($video{'bin/ffmpeg'}, 'video selects bin/ffmpeg');
ok($video{'bin/ffprobe'}, 'video selects bin/ffprobe');
ok(!$video{'bin/magick'}, 'video does not select magick');
ok(!$video{'bin/perl'}, 'video does not select the core perl');

($rc, $out) = run($^X, $build, '--from', $prefix, '--abi', 'aarch64', '--list');
is($rc, 0, 'default selection is core');
my %core = map { $_ => 1 } list_paths($out);
ok($core{'bin/perl'}, 'core still selects bin/perl');
ok($core{'lib/perl5/CORE/libperl.so'}, 'core still selects libperl');
ok(!$core{'bin/magick'}, 'core does not select a part tool');
ok(!$core{'bin/ffmpeg'}, 'core no longer selects ffmpeg');
ok(!$core{'bin/ffprobe'}, 'core no longer selects ffprobe');
ok(!$core{'share/tessdata/eng.traineddata'}, 'core does not select part data');

# --keep forces a path the closure does not infer (the libz alias).
symlink 'libz.so.1', "$prefix/lib/libz.so" or die "symlink: $!";
write_file("$prefix/lib/libz.so.1", "z");
($rc, $out) = run($^X, $build, '--from', $prefix, '--abi', 'aarch64',
	'--keep', 'lib/libz.so', '--list');
is($rc, 0, 'core selection with --keep succeeds');
my %kept = map { $_ => 1 } list_paths($out);
ok($kept{'lib/libz.so'}, '--keep adds the alias to the core');

($rc, $out) = run($^X, $build, '--from', $prefix, '--part', 'nope', '--list');
isnt($rc, 0, 'an unknown part is refused');

# The part manifest a build writes has the schema the pin and the app use.
my $part_out = "$tmp/jawnrt-aarch64-media-9.9.9.zip";
($rc, $out) = run($^X, $build, '--from', $prefix, '--part', 'media', '--abi', 'aarch64',
	'--version', '9.9.9', '--min-core', '1.2.3', '--no-bin', '--out', $part_out);
is($rc, 0, 'a part archive builds');
my $meta = eval { decode_json(read_file("$part_out.json")) } || {};
is($meta->{'part'}, 'media', 'part manifest names the part');
is($meta->{'version'}, '9.9.9', 'part manifest keeps its own version');
is($meta->{'min_core'}, '1.2.3', 'part manifest records min_core');
ok($meta->{'optional'}, 'part manifest marks the part optional');
like($meta->{'filename'}, qr/^jawnrt-aarch64-media-9\.9\.9\.zip$/, 'part file name');
like($meta->{'sha256'} || '', qr/^[0-9a-f]{64}$/, 'part manifest sha256');
is($meta->{'size'}, -s $part_out, 'part manifest size is the file size');
my @bins = @{ $meta->{'bins'} || [] };
ok((grep { $_ eq 'bin/magick' } @bins), 'part manifest names its executable');
my $z = Archive::Zip->new;
is($z->read($part_out), AZ_OK, 'the part archive reads back');
my %in_zip = map { ('usr/' . $_->fileName) => 1 } grep { !$_->isDirectory && $_->fileName !~ m{^licenses/} } $z->members;
my %in_meta = map { $_ => 1 } @{ $meta->{'provides'} || [] };
is_deeply([ sort keys %in_meta ], [ sort keys %in_zip ], 'provides is exactly the archive');

# --- 3. a baseline archive's paths stay out of a part ----------------------
my $base_stage = "$tmp/base-stage";
make_path("$base_stage/etc/ImageMagick-7");
write_file("$base_stage/etc/ImageMagick-7/colors.xml", "colors");
my $base_zip = "$tmp/core.zip";
($rc, $out) = run($^X, $zip, $base_stage, $base_zip);
is($rc, 0, 'runtime_zip builds a baseline archive');
($rc, $out) = run($^X, $build, '--from', $prefix, '--part', 'media',
	'--baseline', $base_zip, '--abi', 'aarch64', '--list');
is($rc, 0, 'media selection with a baseline succeeds');
my %with_base = map { $_ => 1 } list_paths($out);
ok(!$with_base{'etc/ImageMagick-7/colors.xml'}, 'baseline path is not carried by the part');
ok($with_base{'etc/ImageMagick-7/log.xml'}, 'non-baseline path is still carried');

# --- 4. merged jniLibs manifest from core + part archives ------------------
my $core_stage = "$tmp/core-bins";
make_path("$core_stage/bin");
write_file("$core_stage/bin/perl", "perl");
chmod 0755, "$core_stage/bin/perl";
my $core_bins_zip = "$tmp/core-bins.zip";
($rc, $out) = run($^X, $zip, $core_stage, $core_bins_zip);
is($rc, 0, 'runtime_zip builds the core bins archive');

my $part_stage = "$tmp/part-bins";
make_path("$part_stage/bin");
write_file("$part_stage/bin/magick", "magick");
chmod 0755, "$part_stage/bin/magick";
symlink 'magick', "$part_stage/bin/convert" or die "symlink: $!";
my $part_bins_zip = "$tmp/part-bins.zip";
($rc, $out) = run($^X, $zip, $part_stage, $part_bins_zip);
is($rc, 0, 'runtime_zip builds the part bins archive');

my $bins_out = "$tmp/native";
($rc, $out) = run($^X, $bins, '--zip', "core=$core_bins_zip",
	'--zip', "media=$part_bins_zip", '--out', $bins_out, '--abi', 'arm64-v8a');
is($rc, 0, 'merged native bins conversion succeeds');
ok(-f "$bins_out/arm64-v8a/libbin_perl.so", 'core executable becomes a jniLib');
ok(-f "$bins_out/arm64-v8a/libbin_magick.so", 'part executable becomes a jniLib');
my %manifest;
for my $line (split /\n/, read_file("$bins_out/runtime-bins.txt")) {
	next unless length $line;
	my @f = split /\t/, $line, -1;
	is(scalar @f, 3, "runtime-bins.txt line has three fields: $line");
	$manifest{$f[0]} = \@f;
}
is_deeply($manifest{'bin/magick'}, ['bin/magick', 'file', 'bin_magick'],
	'merged manifest names the part executable');
is_deeply($manifest{'bin/convert'}, ['bin/convert', 'link', 'bin/magick'],
	'merged manifest keeps the part symlink');
like(read_file("$bins_out/runtime-bins-parts.txt"), qr/^media\tbin\/magick\tfile$/m,
	'parts side file labels the part executable');
like(read_file("$bins_out/runtime-bins-parts.txt"), qr/^core\tbin\/perl\tfile$/m,
	'parts side file labels the core executable');

# --- 5. a missing part does not break an APK publish ----------------------
my $tree = "$tmp/publish-tree";
make_path("$tree/scripts", "$tree/releases", "$tree/app/app/src/main/assets");
copy($publish, "$tree/scripts/app_publish.pl") or die "copy app_publish.pl: $!";
write_file("$tree/releases/jawnos-app-1-0.0.1.apk", "apk");
my $core_payload = "core archive";
write_file("$tree/releases/core.zip", $core_payload);
my $pin = {
	abi => { aarch64 => {
		file => 'core.zip', sha256 => sha256_hex($core_payload),
		size => length($core_payload), version => '0.0.1',
	} },
	parts => { aarch64 => { media => {
		file => 'missing-media.zip', sha256 => ('0' x 64), size => 1,
		version => '0.0.1', min_core => '0.0.1', optional => JSON::PP::true,
		provides => ['usr/bin/magick'],
	} } },
};
write_file("$tree/app/app/src/main/assets/jawnrt.json",
	JSON::PP->new->canonical->encode($pin));
($rc, $out) = run($^X, "$tree/scripts/app_publish.pl",
	'--dir', "$tree/releases", '--app-repo', "$tree/app", '--dry-run');
is($rc, 0, 'publish dry-run survives a missing part');
like($out, qr/part aarch64\/media: missing-media\.zip is not staged; skipping/,
	'missing part is reported and skipped');

# The device's Vulkan loader is not ours to ship: the Termux copy needs vendor
# HIDL libraries an app namespace lacks, and it stopped ffmpeg from linking.
my $build_src = read_file($build);
like($build_src, qr/next if \$name eq 'libvulkan\.so';/,
	'the prefix libvulkan is left to the device');
like($build_src, qr/\bvideo\s*=>\s*\{/,
	'ffmpeg/ffprobe are their own optional part');
like($build_src, qr/tools\s*=>\s*\[qw\(ffmpeg ffprobe\)\]/,
	'the video part selects exactly the ffmpeg pair');

# The core diet must not select ffmpeg again; those bytes are what the split
# removed. The video spec is the only place the pair is named.
my ($tool_block) = $build_src =~ /my %TOOL = map \{ \$_ => 1 \} qw\((.*?)\n\);/s;
ok(defined $tool_block, 'the core tool list is present');
unlike($tool_block || '', qr/(?:^|\s)ffmpeg(?:\s|$)/, 'ffmpeg is not in the core tool list');
unlike($tool_block || '', qr/(?:^|\s)ffprobe(?:\s|$)/, 'ffprobe is not in the core tool list');

done_testing();
