use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use IO::Uncompress::Unzip qw($UnzipError);

# M3 (docs/leaving-termux.md): the runtime a clean install unpacks instead of
# the Termux bootstrap. scripts/runtime_build.pl decides what ships and
# scripts/runtime_zip.pl packs it; this file pins both halves, because a wrong
# diet or a lost mode produces an archive that unpacks into a perl nobody can
# execute - which is exactly the failure that shipped once (every tool 0666
# because the stage copy took run-as's umask).

my $root = "$FindBin::Bin/..";
my $build = "$root/scripts/runtime_build.pl";
my $zip   = "$root/scripts/runtime_zip.pl";

sub write_file_at {
	my ($path, $body, $mode) = @_;
	make_path($path =~ m{^(.*)/[^/]+$} ? $1 : '.');
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh $body;
	close $fh;
	chmod($mode, $path) if $mode;
}

# A small but real 64-bit ELF shared object whose DT_NEEDED names @needed.
# The diet finds libraries by reading this, not by matching names, so the
# fixture has to be a real ELF: a text file proves nothing about the parser.
sub elf_so {
	my (@needed) = @_;
	my $str = "\0";
	my @off;
	foreach my $n (@needed) { push @off, length $str; $str .= "$n\0" }
	my $dyn = join('', map { pack('q<Q<', 1, $_) } @off) . pack('q<Q<', 0, 0);
	my $dynstr_off = 64;
	my $dyn_off = $dynstr_off + length $str;
	my $shoff = $dyn_off + length $dyn;
	my $ehdr = "\x7fELF" . pack('C4', 2, 1, 1, 0) . ("\0" x 8)
		. pack('v', 3) . pack('v', 183) . pack('V', 1)     # ET_DYN, AArch64, v1
		. pack('Q<', 0) . pack('Q<', 0) . pack('Q<', $shoff)  # entry, phoff, shoff
		. pack('V', 0) . pack('v', 64) . pack('v', 56) . pack('v', 0)
		. pack('v', 64) . pack('v', 3) . pack('v', 2);         # shensize, shnum, shstrndx
	die 'bad ehdr' unless length($ehdr) == 64;
	my $shdr = sub {
		my ($type, $offset, $size, $link) = @_;
		pack('V V Q< Q< Q< Q< V V Q< Q<', 0, $type, 0, 0, $offset, $size, $link, 0, 1, 0);
	};
	return $ehdr . $str . $dyn
		. ("\0" x 64)                                    # SHT_NULL
		. $shdr->(3, $dynstr_off, length $str, 0)         # SHT_STRTAB
		. $shdr->(6, $dyn_off, length $dyn, 1);           # SHT_DYNAMIC -> strtab 1
}

# A prefix shaped like Termux's, carrying one of each interesting case: a tool
# that ships, a tool that must never ship (pkg), a file outside the diet, a
# pruned pod, and the two things a runtime is useless without.
my $src = tempdir(CLEANUP => 1);
write_file_at("$src/bin/perl", "#!/bin/sh\n", 0755);
write_file_at("$src/bin/rm", "#!/bin/sh\n", 0755);
write_file_at("$src/bin/pkg", "#!/bin/sh\n", 0755);
write_file_at("$src/bin/node", "#!/bin/sh\n", 0755);
write_file_at("$src/lib/perl5/5.42.0/aarch64-android/CORE/libperl.so", "ELF\n", 0755);
write_file_at("$src/lib/perl5/5.42.0/Foo.pm", "package Foo; 1;\n", 0644);
write_file_at("$src/lib/perl5/5.42.0/Foo.pod", "=head1 Foo\n", 0644);
write_file_at("$src/lib/perl5/pod/perlfunc.pod", "=head1 perlfunc\n", 0644);
write_file_at("$src/lib/perl5/5.42.0/auto/Foo/Foo.so", elf_so('libssl.so.3'), 0755);
write_file_at("$src/lib/libssl.so.3", elf_so(), 0644);
write_file_at("$src/lib/libLLVM.so", elf_so(), 0644);
write_file_at("$src/share/terminfo/x/xterm", "term\n", 0644);

my $listing = qx{"$^X" "$build" --from "$src" --list 2>&1};
is($? >> 8, 0, 'the packer lists a Termux-shaped prefix') or diag($listing);
my %listed = map { $_ => 1 } split /\n/, $listing;

ok($listed{'bin/perl'}, 'the interpreter ships');
ok($listed{'bin/rm'}, 'a kept tool ships');
ok(!$listed{'bin/pkg'}, 'the package manager never ships');
ok(!$listed{'bin/node'}, 'a tool outside the diet does not ship');
ok($listed{'lib/perl5/5.42.0/aarch64-android/CORE/libperl.so'}, 'the core library ships');
ok($listed{'lib/perl5/5.42.0/Foo.pm'}, 'a module ships');
ok(!$listed{'lib/perl5/5.42.0/Foo.pod'}, 'a module pod is pruned');
ok(!$listed{'lib/perl5/pod/perlfunc.pod'}, 'perls own pods are pruned');
ok($listed{'lib/libssl.so.3'}, 'a library an XS module names in its DT_NEEDED ships');
ok(!$listed{'lib/libLLVM.so'}, 'and a heavy library nothing in the diet names does not');
ok($listed{'share/terminfo/x/xterm'}, 'terminfo ships');

# An incomplete prefix is refused, named, and non-zero - the runtime is not
# something to ship half of.
my $half = tempdir(CLEANUP => 1);
write_file_at("$half/bin/perl", "#!/bin/sh\n", 0755);
my $refused = qx{"$^X" "$build" --from "$half" --dry-run 2>&1};
isnt($? >> 8, 0, 'a prefix without CORE/libperl.so is refused');
like($refused, qr/bin\/perl: yes, CORE\/libperl\.so: NO/, 'and it says which half is missing');

# A library a shipped module names but the prefix does not carry cannot appear
# on the device later: refuse the build and name it, rather than ship a runtime
# that dies with "library not found" on first use.
my $gap = tempdir(CLEANUP => 1);
write_file_at("$gap/bin/perl", "#!/bin/sh\n", 0755);
write_file_at("$gap/lib/perl5/5.42.0/aarch64-android/CORE/libperl.so", "ELF\n", 0755);
write_file_at("$gap/lib/perl5/5.42.0/auto/Bar/Bar.so", elf_so('libgone.so.2'), 0755);
my $gapped = qx{"$^X" "$build" --from "$gap" --dry-run 2>&1};
isnt($? >> 8, 0, 'a library nothing in the prefix provides is refused');
like($gapped, qr/missing libraries: libgone\.so\.2/, 'and the refusal names it');

# --- the archive itself -----------------------------------------------------
my $out = tempdir(CLEANUP => 1) . '/rt.zip';
my $pack = qx{"$^X" "$build" --from "$src" --out "$out" 2>&1};
is($? >> 8, 0, 'the packer writes an archive') or diag($pack);
ok(-s $out, 'the archive is not empty');
ok(-s "$out.json", 'a manifest is written beside it');

open(my $mf, '<', "$out.json") or die $!;
my $manifest = <$mf>;
close $mf;
like($manifest, qr/"product":"runtime"/, 'the manifest names the runtime product');
like($manifest, qr/"abi":"aarch64"/, 'the manifest carries the ABI');
like($manifest, qr/"sha256":"[0-9a-f]{64}"/, 'the manifest pins a sha256');

# Read it back the way the app must: the central directory, whose external
# attributes carry the Unix mode. Java's ZipInputStream does not expose them,
# so the unpacker parses this record itself; the test does the same.
sub zip_modes {
	my ($file) = @_;
	open(my $fh, '<', $file) or die "$file: $!";
	binmode $fh;
	local $/;
	my $buf = <$fh>;
	close $fh;
	my %mode;
	while ($buf =~ /PK\x01\x02/g) {
		my $s = $-[0];
		my ($namelen) = unpack('v', substr($buf, $s + 28, 2));
		my $ext = unpack('V', substr($buf, $s + 38, 4));
		my $name = substr($buf, $s + 46, $namelen);
		$mode{$name} = ($ext >> 16) & 0xFFFF;
	}
	return \%mode;
}

sub zip_body {
	my ($file, $want) = @_;
	my $u = IO::Uncompress::Unzip->new($file) or die "unzip: $UnzipError";
	while (1) {
		my $h = $u->getHeaderInfo() or return undef;
		my $body = '';
		$body .= $_ while <$u>;
		return $body if ($h->{'Name'} || '') eq $want;
		last unless $u->nextStream();
	}
	return undef;
}

my $modes = zip_modes($out);
ok(scalar keys %{$modes}, 'the archive has a central directory');
is($modes->{'bin/perl'}, 0100755, 'an executable keeps its mode (100755)');
is($modes->{'lib/perl5/5.42.0/Foo.pm'}, 0100644, 'a module keeps its mode (100644)');
ok(!$modes->{'bin/pkg'}, 'the archive carries no package manager');
ok(!$modes->{'lib/perl5/pod/perlfunc.pod'}, 'the archive carries no pods');

# --- symlinks ---------------------------------------------------------------
my $links = tempdir(CLEANUP => 1);
write_file_at("$links/bin/perl", "#!/bin/sh\n", 0755);
write_file_at("$links/lib/perl5/5.42.0/aarch64-android/CORE/libperl.so", "ELF\n", 0755);
symlink('perl', "$links/bin/awk") or plan skip_all => 'no symlinks here';
my $lout = tempdir(CLEANUP => 1) . '/links.zip';
qx{"$^X" "$build" --from "$links" --out "$lout" 2>&1};
my $lmodes = zip_modes($lout);
is($lmodes->{'bin/awk'}, 0120777, 'a symlink is stored with S_IFLNK');
is(zip_body($lout, 'bin/awk'), 'perl', 'and its target is the entry body');

# --- the runtime declares itself complete -----------------------------------
# The first-run wizard runs `perl scripts/jawnos_deps.pl --install`; on a
# device whose prefix is this runtime there is no package manager and nothing
# missing, so it must succeed without trying to install anything.
my $marked = tempdir(CLEANUP => 1);
write_file_at("$marked/etc/jawnos-runtime.json", '{"version":"9.9.9"}', 0644);
my $deps = qx{PREFIX="$marked" "$^X" "$root/scripts/jawnos_deps.pl" --install 2>&1};
is($? >> 8, 0, 'the dependency install is a no-op inside the app runtime') or diag($deps);
like($deps, qr/runtime 9\.9\.9 supplies every module/, 'and it says why');

# A named tool is often a link to a multi-call binary the diet never names: the
# target must come along or the unpacked tool dangles (bin/sh -> dash, bin/cat
# -> coreutils). This is the defect that shipped once.
my $multi = tempdir(CLEANUP => 1);
write_file_at("$multi/bin/perl", "#!/bin/sh\n", 0755);
write_file_at("$multi/bin/coreutils", "ELF\n", 0755);
write_file_at("$multi/lib/perl5/5.42.0/aarch64-android/CORE/libperl.so", "ELF\n", 0755);
symlink('coreutils', "$multi/bin/cat") or plan skip_all => 'no symlinks here';
my $mlist = qx{"$^X" "$build" --from "$multi" --list 2>&1};
my %m = map { $_ => 1 } split /\n/, $mlist;
ok($m{'bin/cat'}, 'a named tool that is a symlink is shipped');
ok($m{'bin/coreutils'}, 'and the multi-call binary it points at comes with it');

done_testing();
