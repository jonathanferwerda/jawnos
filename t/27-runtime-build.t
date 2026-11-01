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

# --- relocating the prefix ---------------------------------------------------
# The runtime is built from a Termux prefix, whose absolute paths every binary
# carries (RUNPATH, perl's module directories, git's exec path, the CA bundle).
# The app can be installed under a different package, so the packer rewrites the
# old path to the new one - and it may only do that when both are the same
# length, or every offset in every ELF would shift.
my $old = '/data/data/com.termux/files/usr';
my $new = '/data/data/com.jawnos/files/usr';
is(length($old), length($new), 'the two prefixes are the same length');

my $move = tempdir(CLEANUP => 1);
write_file_at("$move/bin/perl", "say $old;\n", 0755);
write_file_at("$move/lib/perl5/5.42.0/aarch64-android/CORE/libperl.so", "ELF $old\n", 0755);
my $moved = tempdir(CLEANUP => 1) . '/moved.zip';
my $moved_out = qx{"$^X" "$build" --from "$move" --out "$moved" --rewrite-prefix "$old=$new" 2>&1};
is($? >> 8, 0, 'the packer rewrites a moved prefix') or diag($moved_out);
like(zip_body($moved, 'bin/perl'), qr/\Q$new\E/, 'the baked path in a script moved with it');
unlike(zip_body($moved, 'bin/perl'), qr{com\.termux}, 'and the old path is gone');
like(zip_body($moved, 'lib/perl5/5.42.0/aarch64-android/CORE/libperl.so'), qr/\Q$new\E/,
	'and in a binary too');

my $uneven = qx{"$^X" "$build" --from "$move" --out "$moved" --rewrite-prefix '$old=/data/data/jawnos/files/usr' 2>&1};
isnt($? >> 8, 0, 'an unequal-length rewrite is refused');
like($uneven, qr/same length|equal-length/, 'and it says why');

# --- the executables the app supplies ---------------------------------------
# M5b: the app ships the runtime's executables as jniLibs and links them back
# into bin/ and libexec/ on start, so --no-bin leaves them out of the archive.
# It must drop exactly what scripts/runtime_native_bins.pl converts - regular
# executables and symlinks under those two trees - while a data file in the same
# tree and everything outside it still ships.
my $nobin = tempdir(CLEANUP => 1);
write_file_at("$nobin/bin/perl", "#!/bin/sh\n", 0755);
write_file_at("$nobin/bin/git", "#!/bin/sh\n", 0755);
symlink('git', "$nobin/bin/egrep") or plan skip_all => 'no symlinks here';
write_file_at("$nobin/libexec/git-core/git-remote-http", "#!/bin/sh\n", 0755);
write_file_at("$nobin/libexec/git-core/git-sh-setup", "shell library\n", 0644);
symlink('git-remote-http', "$nobin/libexec/git-core/git");
write_file_at("$nobin/lib/perl5/5.42.0/aarch64-android/CORE/libperl.so", "ELF\n", 0755);
write_file_at("$nobin/lib/perl5/5.42.0/Foo.pm", "package Foo; 1;\n", 0644);
write_file_at("$nobin/share/terminfo/x/xterm", "term\n", 0644);
write_file_at("$nobin/etc/tls/ca.pem", "ca\n", 0644);
write_file_at("$nobin/etc/ssh/sshd_config", "Port 8022\n", 0644);

my $nlist = qx{"$^X" "$build" --from "$nobin" --no-bin --list 2>&1};
is($? >> 8, 0, '--no-bin lists a prefix') or diag($nlist);
my %n = map { $_ => 1 } split /\n/, $nlist;
ok(!$n{'bin/perl'}, '--no-bin omits the interpreter');
ok(!$n{'bin/git'} && !$n{'bin/egrep'}, 'and the tools, including symlinked ones');
ok(!$n{'libexec/git-core/git-remote-http'}, 'and a real executable in libexec');
ok(!$n{'libexec/git-core/git'}, 'and a symlink in libexec');
ok($n{'libexec/git-core/git-sh-setup'}, 'but a non-executable data file in libexec still ships');
ok($n{'lib/perl5/5.42.0/aarch64-android/CORE/libperl.so'} && $n{'lib/perl5/5.42.0/Foo.pm'},
	'lib/ still ships');
ok($n{'share/terminfo/x/xterm'}, 'share/ still ships');
ok($n{'etc/tls/ca.pem'} && $n{'etc/ssh/sshd_config'}, 'etc/ still ships');

my $nout = tempdir(CLEANUP => 1) . '/nobin.zip';
my $npack = qx{"$^X" "$build" --from "$nobin" --no-bin --out "$nout" 2>&1};
is($? >> 8, 0, '--no-bin writes an archive') or diag($npack);
like($npack, qr/--no-bin: omitting 5 executables and links/, 'the build reports what it omitted');
my $nmodes = zip_modes($nout);
ok(!$nmodes->{'bin/perl'}, 'the archive carries no interpreter');
ok(!$nmodes->{'bin/git'} && !$nmodes->{'bin/egrep'}, 'and no tool or tool symlink');
ok(!$nmodes->{'libexec/git-core/git-remote-http'} && !$nmodes->{'libexec/git-core/git'},
	'and no libexec executable or symlink');
ok($nmodes->{'libexec/git-core/git-sh-setup'}, 'the data file in libexec is in the archive');
ok($nmodes->{'lib/perl5/5.42.0/Foo.pm'} && $nmodes->{'share/terminfo/x/xterm'}
	&& $nmodes->{'etc/ssh/sshd_config'}, 'and lib/, share/ and etc/ are all in it');

# A build without the flag is unchanged, so an older app still gets the tools.
my $default_list = qx{"$^X" "$build" --from "$nobin" --list 2>&1};
my %d = map { $_ => 1 } split /\n/, $default_list;
ok($d{'bin/perl'} && $d{'bin/git'} && $d{'libexec/git-core/git'},
	'a build without --no-bin still ships the executables');

# --- an alias path that climbs with .. must not truncate its target ----------
# git-core ships some entries as libexec/git-core/../../bin/X. The symlink
# closure re-adds them as literal paths, and staging one a second time copied
# over bin/git's hard link and left the SOURCE at 0 bytes (2026-10-31), so the
# archive shipped an empty git. The alias must be dropped, not staged.
my $alias = tempdir(CLEANUP => 1);
write_file_at("$alias/bin/perl", "#!/bin/sh\n", 0755);
my $git_bytes = "REAL-GIT-BYTES\n";
write_file_at("$alias/bin/git", $git_bytes, 0755);
write_file_at("$alias/lib/perl5/5.42.0/aarch64-android/CORE/libperl.so", "ELF\n", 0755);
write_file_at("$alias/libexec/git-core/git-sh-setup", "shell library\n", 0644);
symlink('../../bin/git', "$alias/libexec/git-core/alias-git") or plan skip_all => 'no symlinks here';

my $alist = qx{"$^X" "$build" --from "$alias" --list 2>/dev/null};
is($? >> 8, 0, 'a prefix with a climbing alias lists') or diag($alist);
unlike($alist, qr/\.\./, 'no alias path that climbs with .. is listed');

my $aout = tempdir(CLEANUP => 1) . '/alias.zip';
my $apack = qx{"$^X" "$build" --from "$alias" --out "$aout" 2>&1};
is($? >> 8, 0, 'and packs') or diag($apack);
like($apack, qr/dropped 1 alias/, 'the build reports the dropped alias');
is(-s "$alias/bin/git", length($git_bytes), 'the source bin/git is not truncated by the staging copy');
my $amodes = zip_modes($aout);
ok($amodes->{'bin/git'}, 'the archive still carries bin/git');

done_testing();
