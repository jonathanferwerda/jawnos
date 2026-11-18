# tests-for: scripts/jawnos_game_openssl.pl scripts/jawnos_game_install.pl
# covers:    the post-flash OpenSSL layer for the GOU's RetroArch: a binary whose
#            ldd asks for libssl.so.4 / libcrypto.so.4 gets those two libraries
#            lifted out of the downloaded-but-not-installed openssl package into
#            /opt/openssl4, the loader conf points at them, and the system's own
#            OpenSSL is untouched. A second run reports the layer as present and
#            writes nothing; a binary that is missing nothing is left alone; a
#            soname with a non-numeric version is refused; and the emulator
#            installer calls this helper.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use IPC::Open3 qw(open3);
use JSON::PP ();
use Symbol qw(gensym);
use Test::More;

my $root = abs_path("$FindBin::Bin/..");
my $script = "$root/scripts/jawnos_game_openssl.pl";
ok(-f $script, 'scripts/jawnos_game_openssl.pl is in the tree');

my @OVERRIDES = qw(
	JAWNOS_OPENSSL_COMPAT_DIR JAWNOS_OPENSSL_LDCONF JAWNOS_OPENSSL_PACMAN
	JAWNOS_OPENSSL_LDCONFIG JAWNOS_OPENSSL_LDD JAWNOS_OPENSSL_BINARY
	JAWNOS_OPENSSL_CACHE
);

sub put {
	my ($path, $body, $mode) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh $body;
	close $fh or die "$path: $!";
	chmod $mode, $path if defined $mode;
}

sub slurp {
	my ($path) = @_;
	return '' unless -f $path;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

sub lines {
	my ($path) = @_;
	my $text = slurp($path);
	return () unless length $text;
	return split /\n/, $text;
}

# Every run starts from no JAWNOS_OPENSSL_* value at all, so a fixture reaches
# the child only through the hash the caller passes.
sub run_script {
	my (%env) = @_;
	local %ENV = (%ENV);
	delete @ENV{@OVERRIDES};
	$ENV{$_} = $env{$_} for sort keys %env;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $script);
	close $in;
	local $/;
	my $stdout = <$out>;
	my $stderr = <$err>;
	$stdout = '' unless defined $stdout;
	$stderr = '' unless defined $stderr;
	close $out;
	close $err;
	waitpid($pid, 0);
	my $code = $? >> 8;
	my $data = eval { JSON::PP->new->decode($stdout) };
	return ($code, $data, $stdout, $stderr);
}

sub perl_compiles {
	my ($path) = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, '-c', $path);
	close $in;
	local $/;
	my $stdout = <$out>;
	my $stderr = <$err>;
	$stdout = '' unless defined $stdout;
	$stderr = '' unless defined $stderr;
	close $out;
	close $err;
	waitpid($pid, 0);
	return ($? >> 8, $stdout . $stderr);
}

my $installer = "$root/scripts/jawnos_game_install.pl";
my ($install_code, $install_out) = perl_compiles($installer);
is($install_code, 0, 'the emulator installer compiles') or diag($install_out);
my ($helper_code, $helper_out) = perl_compiles($script);
is($helper_code, 0, 'the OpenSSL helper compiles') or diag($helper_out);

# --- the fixture ---------------------------------------------------------------
my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/bin", "$tmp/fake");

# The binary the helper checks. ldd is faked, so this only has to exist and be
# executable.
my $binary = "$tmp/bin/retroarch";
put($binary, "#!/bin/sh\nexit 0\n", 0755);

# The package the fake pacman "downloads": a real tar with the two members.
my $stage = "$tmp/package";
make_path("$stage/usr/lib");
put("$stage/usr/lib/libssl.so.4", "openssl 4 ssl\n");
put("$stage/usr/lib/libcrypto.so.4", "openssl 4 crypto\n");
my $package = "$tmp/openssl-4.1.0-1-aarch64.pkg.tar.gz";
my $packed = system('tar', '-czf', $package, '-C', $stage,
	'usr/lib/libssl.so.4', 'usr/lib/libcrypto.so.4') == 0;
ok($packed, 'a fixture openssl package with the two sonames was built');

# ldd prints the fixture's missing names, and prints them resolved once the
# fake ldconfig has run - the loader cache, in miniature.
my $ldd = "$tmp/fake/ldd";
put($ldd, "#!$^X\n" . <<'FAKE_LDD', 0755);
use strict;
use warnings;
my $list = $ENV{'FAKE_LDD_LIST'} || '';
my @names;
if (open(my $fh, '<', $list)) {
	while (my $line = <$fh>) { chomp $line; push @names, $line if length $line }
	close $fh;
}
my $resolved = defined $ENV{'FAKE_LDD_MARK'} && -e $ENV{'FAKE_LDD_MARK'};
if (defined $ENV{'FAKE_LDD_LOG'}) {
	if (open(my $fh, '>>', $ENV{'FAKE_LDD_LOG'})) { print $fh "ldd\n"; close $fh }
}
for my $name (@names) {
	print $resolved
		? "\t$name => /opt/fake/usr/lib/$name (0x00000000)\n"
		: "\t$name => not found\n";
}
print "\tlibc.so.6 => /usr/lib/libc.so.6 (0x00000000)\n";
exit 0;
FAKE_LDD

# The fake pacman records its argv and "downloads" the fixture package into the
# cache. It never installs anything, which is exactly what -Sddw promises.
my $pacman = "$tmp/fake/pacman";
put($pacman, "#!$^X\n" . <<'FAKE_PACMAN', 0755);
use strict;
use warnings;
use File::Copy qw(copy);
if (defined $ENV{'FAKE_PACMAN_LOG'}) {
	open(my $log, '>>', $ENV{'FAKE_PACMAN_LOG'}) or exit 2;
	print $log join(' ', @ARGV), "\n";
	close $log;
}
my $package = $ENV{'FAKE_PACMAN_PACKAGE'} || '';
my $cache = $ENV{'FAKE_PACMAN_CACHE'} || '';
(my $name = $package) =~ s{.*/}{};
copy($package, "$cache/$name") or exit 3;
exit 0;
FAKE_PACMAN

my $ldconfig = "$tmp/fake/ldconfig";
put($ldconfig, "#!$^X\n" . <<'FAKE_LDCONFIG', 0755);
use strict;
use warnings;
if (defined $ENV{'FAKE_LDCONFIG_LOG'}) {
	open(my $log, '>>', $ENV{'FAKE_LDCONFIG_LOG'}) or exit 2;
	print $log "ldconfig\n";
	close $log;
}
open(my $mark, '>', $ENV{'FAKE_LDCONFIG_MARK'}) or exit 3;
close $mark;
exit 0;
FAKE_LDCONFIG

# --- nothing is missing --------------------------------------------------------
my $plain = "$tmp/plain";
make_path($plain);
put("$plain/missing.txt", "libz.so.1\n");
my ($plain_code, $plain_data, undef, $plain_err) = run_script(
	JAWNOS_OPENSSL_BINARY => $binary,
	JAWNOS_OPENSSL_LDD => $ldd,
	JAWNOS_OPENSSL_PACMAN => $pacman,
	JAWNOS_OPENSSL_LDCONFIG => $ldconfig,
	JAWNOS_OPENSSL_COMPAT_DIR => "$plain/opt/openssl4",
	JAWNOS_OPENSSL_LDCONF => "$plain/ld.so.conf.d/openssl4.conf",
	JAWNOS_OPENSSL_CACHE => "$plain/cache",
	FAKE_LDD_LIST => "$plain/missing.txt",
	FAKE_LDD_MARK => "$plain/ldconfig-ran",
	FAKE_LDD_LOG => "$plain/ldd.log",
	FAKE_PACMAN_LOG => "$plain/pacman.log",
	FAKE_PACMAN_PACKAGE => $package,
	FAKE_PACMAN_CACHE => "$plain/cache",
	FAKE_LDCONFIG_LOG => "$plain/ldconfig.log",
	FAKE_LDCONFIG_MARK => "$plain/ldconfig-ran",
);
is($plain_code, 0, 'a binary with no missing OpenSSL exits 0');
ok($plain_data && $plain_data->{'ok'}, 'the report is ok') or diag($plain_err);
is($plain_data->{'state'}, 'none', 'nothing missing is reported as none');
ok(!-d "$plain/opt/openssl4", 'no compat dir was created');
ok(!-e "$plain/ld.so.conf.d/openssl4.conf", 'no loader conf was written');
ok(!-e "$plain/pacman.log", 'pacman was not asked for anything');

# --- libssl.so.4 and libcrypto.so.4 are missing ---------------------------------
my $case = "$tmp/staged";
make_path($case, "$case/cache");
put("$case/missing.txt", "libssl.so.4\nlibcrypto.so.4\n");
my %staged_env = (
	JAWNOS_OPENSSL_BINARY => $binary,
	JAWNOS_OPENSSL_LDD => $ldd,
	JAWNOS_OPENSSL_PACMAN => $pacman,
	JAWNOS_OPENSSL_LDCONFIG => $ldconfig,
	JAWNOS_OPENSSL_COMPAT_DIR => "$case/opt/openssl4",
	JAWNOS_OPENSSL_LDCONF => "$case/etc/ld.so.conf.d/openssl4.conf",
	JAWNOS_OPENSSL_CACHE => "$case/cache",
	FAKE_LDD_LIST => "$case/missing.txt",
	FAKE_LDD_MARK => "$case/ldconfig-ran",
	FAKE_LDD_LOG => "$case/ldd.log",
	FAKE_PACMAN_LOG => "$case/pacman.log",
	FAKE_PACMAN_PACKAGE => $package,
	FAKE_PACMAN_CACHE => "$case/cache",
	FAKE_LDCONFIG_LOG => "$case/ldconfig.log",
	FAKE_LDCONFIG_MARK => "$case/ldconfig-ran",
);
my ($stage_code, $stage_data, undef, $stage_err) = run_script(%staged_env);
is($stage_code, 0, 'staging the missing libraries exits 0');
ok($stage_data && $stage_data->{'ok'}, 'the staged report is ok') or diag($stage_err);
is($stage_data->{'state'}, 'staged', 'the report says the layer was staged');
is($stage_data->{'major'}, 4, 'the major version comes from the soname');
is($stage_data->{'source'}, 'openssl-4.1.0-1-aarch64.pkg.tar.gz', 'the manifest names the package');

my $libdir = "$case/opt/openssl4/usr/lib";
ok(-f "$libdir/libssl.so.4", 'libssl.so.4 was extracted');
ok(-f "$libdir/libcrypto.so.4", 'libcrypto.so.4 was extracted');
is((stat("$libdir/libssl.so.4"))[2] & 07777, 0755, 'the staged library is executable');
ok(!-f "$libdir/libssl.so.3", 'the system soname was not staged');
ok(!-f "$case/opt/openssl4/usr/lib/libssl.so.3", 'and no other OpenSSL version appears');

my $conf = "$case/etc/ld.so.conf.d/openssl4.conf";
is(slurp($conf), "$libdir\n", 'the loader conf points at the compat directory once');
is_deeply([grep { length } lines("$case/pacman.log")],
	['-Sddw --noconfirm openssl'], 'the package is downloaded, never installed');
is(scalar(grep { length } lines("$case/ldconfig.log")), 1, 'ldconfig ran once');
is(scalar(grep { length } lines("$case/ldd.log")), 2,
	'ldd ran before and after the cache refresh');

my $manifest_path = "$case/opt/openssl4/jawnos-compat.json";
ok(-f $manifest_path, 'the compat manifest was written');
my $manifest = eval { JSON::PP->new->decode(slurp($manifest_path)) };
is(ref $manifest, 'HASH', 'the manifest is a JSON object');
is_deeply($manifest->{'sonames'}, ['libcrypto.so.4', 'libssl.so.4'],
	'the manifest names both sonames');
is($manifest->{'binary'}, $binary, 'the manifest names the binary it was staged for');
like($manifest->{'created'}, qr/^\d+$/, 'the manifest carries when it was made');

# --- a second run is a no-op ---------------------------------------------------
my ($again_code, $again_data, undef, $again_err) = run_script(%staged_env);
is($again_code, 0, 'a second run exits 0');
ok($again_data && $again_data->{'ok'}, 'the second report is ok') or diag($again_err);
is($again_data->{'state'}, 'present', 'a staged layer is reported as present');
is($again_data->{'major'}, 4, 'and names its major version');
is(scalar(grep { length } lines("$case/pacman.log")), 1,
	'the second run did not download the package again');
is(scalar(grep { length } lines("$case/ldconfig.log")), 1,
	'the second run did not refresh a cache that already worked');
is(slurp($conf), "$libdir\n", 'the loader conf still has one line');

# --- an unsafe soname is refused ----------------------------------------------
my $bad = "$tmp/unsafe";
make_path($bad);
put("$bad/missing.txt", "libssl.so.4x\n");
my ($bad_code, $bad_data, undef, $bad_err) = run_script(
	JAWNOS_OPENSSL_BINARY => $binary,
	JAWNOS_OPENSSL_LDD => $ldd,
	JAWNOS_OPENSSL_PACMAN => $pacman,
	JAWNOS_OPENSSL_LDCONFIG => $ldconfig,
	JAWNOS_OPENSSL_COMPAT_DIR => "$bad/opt/openssl4",
	JAWNOS_OPENSSL_LDCONF => "$bad/ld.so.conf.d/openssl4.conf",
	JAWNOS_OPENSSL_CACHE => "$bad/cache",
	FAKE_LDD_LIST => "$bad/missing.txt",
	FAKE_LDD_MARK => "$bad/ldconfig-ran",
	FAKE_LDD_LOG => "$bad/ldd.log",
	FAKE_PACMAN_LOG => "$bad/pacman.log",
	FAKE_PACMAN_PACKAGE => $package,
	FAKE_PACMAN_CACHE => "$bad/cache",
	FAKE_LDCONFIG_LOG => "$bad/ldconfig.log",
	FAKE_LDCONFIG_MARK => "$bad/ldconfig-ran",
);
isnt($bad_code, 0, 'a non-numeric soname exits nonzero');
ok($bad_data && !$bad_data->{'ok'}, 'and is reported as a refusal') or diag($bad_err);
like($bad_data->{'error'}, qr/libssl\.so\.4x/, 'the refusal names the soname');
ok(!-d "$bad/opt/openssl4", 'nothing was staged for an unsafe soname');
ok(!-e "$bad/pacman.log", 'and no package was downloaded');

# --- the installer calls it ----------------------------------------------------
my $installer_text = slurp($installer);
like($installer_text, qr/jawnos_game_openssl\.pl/, 'the emulator installer runs the OpenSSL helper');
like($installer_text, qr/\$STATUS\{'openssl'\}/, 'and records what it reported');

done_testing();
