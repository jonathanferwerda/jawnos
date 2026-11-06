# tests-for: scripts/app_build.pl scripts/app_release.pl
# covers:    M5 (docs/roadmap-handoff.md): targetSdk 36 stops the app exec'ing a file it wrote into its own data dir, so th...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use Cwd qw(abs_path);

# M5 (docs/roadmap-handoff.md): targetSdk 36 stops the app exec'ing a file it
# wrote into its own data dir, so the runtime's executables ship as native
# libraries and the APK carries assets/runtime-bins.txt: one line per entry,
# three tab-separated fields,
#
#     <prefix-relative path>\tfile\t<slug>
#     <prefix-relative path>\tlink\t<target>
#
# scripts/app_build.pl must copy the manifest produced under
# releases/native-bins/ into the APK's assets and pass -PjawnNativeBins=<dir>
# to gradle. The Java reader (JawnRuntimeBins) runs on the device, so this pins
# the build half and the format the reader is handed.

my $real_build = abs_path("$FindBin::Bin/../scripts/app_build.pl");

sub slurp {
	my ($path) = @_;
	open(my $fh, '<', $path) or die "$path: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}

sub spew {
	my ($path, $text) = @_;
	make_path($1) if $path =~ m{^(.*)/[^/]+$};
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh $text;
	close $fh;
}

sub shq {
	my ($text) = @_;
	$text =~ s/'/'\\''/g;
	return "'$text'";
}

# A throwaway tree that looks enough like the repo for app_build.pl: the copied
# script resolves $root from its own location, so releases/ and the fake
# app_release.pl stay inside the temp dir (the real releases/ is never touched).
sub fake_tree {
	my ($manifest, $with_bins, $opt) = @_;
	$opt ||= {};
	my $tmp  = tempdir(CLEANUP => 1);
	my $tree = "$tmp/tree";
	my $app  = "$tmp/app";
	make_path("$tree/scripts", "$app/app/src/main/assets");

	copy($real_build, "$tree/scripts/app_build.pl")
		or die "copy app_build.pl: $!";
	spew("$tree/scripts/app_release.pl", "#!/usr/bin/perl\nprint \"staged\\n\"; exit 0;\n");
	spew("$app/app/build.gradle",
		"android {\n    defaultConfig {\n        versionCode 7\n        versionName \"9.9.9\"\n    }\n}\n");
	spew("$app/app/src/main/assets/runtime-bins.txt", "placeholder\n");

	# The tree has the key when the test says so. A release build without it is
	# refused, so --release writes one too. With the key present, release is the
	# default; --debug is the deliberate way back to the dev variant.
	my $keystore = $opt->{'keystore'} || $opt->{'release'};
	my $release  = $opt->{'debug'} ? 0 : ($keystore ? 1 : 0);

	my $args_file = "$tmp/gradle-args";
	my $flavour   = $release ? 'release' : 'debug';
	my $apk_dir   = "$app/app/build/outputs/apk/$flavour";
	if ($keystore) {
		spew("$app/keystore.properties",
			"storeFile=$tmp/release.jks\n"
			. "storePassword=testpass\n"
			. "keyAlias=jawnos\n"
			. "keyPassword=testpass\n");
		spew("$tmp/release.jks", "not a real keystore\n");
	}
	# runtime => 1 makes a real zip carrying the entries the release check
	# reads; otherwise the artefact is a placeholder text file.
	my $artefact = $opt->{'runtime'}
		? "cd " . shq($apk_dir) . " && mkdir -p lib/arm64-v8a assets"
			. " && printf x > lib/arm64-v8a/libbin_perl.so"
			. " && printf 'bin/perl\\tfile\\tbin_perl\\n' > assets/runtime-bins.txt"
			. " && zip -q -r universal.apk lib assets"
		: "printf 'apk' > " . shq("$apk_dir/universal.apk");
	spew("$app/gradlew",
		"#!/bin/sh\n"
		. "printf '%s\\n' \"\$@\" > " . shq($args_file) . "\n"
		. "mkdir -p " . shq($apk_dir) . "\n"
		. "$artefact\n");
	chmod 0755, "$app/gradlew";

	my $sdk = "$tmp/sdk";
	my $jdk = "$tmp/jdk";
	make_path($sdk, "$jdk/bin", "$sdk/build-tools/99.0.0");
	spew("$jdk/bin/java", "#!/bin/sh\nexit 0\n");
	chmod 0755, "$jdk/bin/java";

	# The release key's certificate and the certificate the fake build's APK
	# carries. They differ so a debug-signed artifact is recognisably not the
	# app's identity.
	my $release_hex = '3ec2a6577005414aa579164f9697dfc89c37c4a9cbcac1af25ff9bd397a3f86f';
	my $debug_hex   = 'b6da01480eefd5fbf2cd3771b8d1021ec791304bdd6c4bf41d3faabad48ee5e1';
	my $signer      = $opt->{'signer'} || 'match';
	my $apk_hex     = $signer eq 'mismatch' ? $debug_hex : $release_hex;
	spew("$jdk/bin/keytool",
		"#!/bin/sh\ncat <<'EOT'\nCertificate fingerprints:\n\t SHA256: "
			. join(':', map { uc } ($release_hex =~ /../g))
			. "\nEOT\nexit 0\n");
	chmod 0755, "$jdk/bin/keytool";
	spew("$sdk/build-tools/99.0.0/apksigner",
		$signer eq 'unsigned'
			? "#!/bin/sh\necho 'DOES NOT VERIFY' >&2\nexit 1\n"
			: "#!/bin/sh\ncat <<'EOT'\nSigner #1 certificate DN: CN=JawnOS\n"
				. "Signer #1 certificate SHA-256 digest: $apk_hex\nEOT\nexit 0\n");
	chmod 0755, "$sdk/build-tools/99.0.0/apksigner";

	if ($with_bins) {
		make_path("$tree/releases/native-bins");
		spew("$tree/releases/native-bins/runtime-bins.txt", $manifest);
	}

	my $out;
	{
		local $ENV{'JAVA_HOME'}        = $jdk;
		local $ENV{'ANDROID_SDK_ROOT'} = $sdk;
		my @args = ('--repo', $app);
		push @args, '--release' if $opt->{'release'};
		push @args, '--debug'   if $opt->{'debug'};
		my $argv = join ' ', map { shq($_) } @args;
		$out = qx{$^X '$tree/scripts/app_build.pl' $argv 2>&1};
	}
	my $code = $? >> 8;

	return {
		tmp    => $tmp,
		tree   => $tree,
		app    => $app,
		asset  => "$app/app/src/main/assets/runtime-bins.txt",
		args   => (-f $args_file ? slurp($args_file) : ''),
		code   => $code,
		output => $out,
	};
}

my $manifest = "bin/perl\tfile\tbin_perl\n"
	. "bin/applets\tfile\tbin_applets\n"
	. "libexec/git-core\tlink\tbin/git\n";

my $r = fake_tree($manifest, 1);
my $bins_dir = abs_path("$r->{tree}/releases/native-bins");
is($r->{code}, 0, 'a build with releases/native-bins/ succeeds') or diag($r->{output});
is(slurp($r->{asset}), $manifest,
	'the manifest is copied verbatim over the checked-in placeholder');
like($r->{args}, qr/^-PjawnNativeBins=\Q$bins_dir\E$/m,
	"gradle is told where the native binaries live");

# Pin the format the Java reader depends on.
my @lines = grep { length } split /\n/, $manifest;
is(scalar @lines, 3, 'the fixture describes three entries');
for my $line (@lines) {
	my @fields = split /\t/, $line, -1;
	is(scalar @fields, 3, "a manifest line has three tab-separated fields: $line");
	ok($fields[1] eq 'file' || $fields[1] eq 'link',
		"the middle field is file or link: $line");
	ok(length $fields[0] && $fields[0] !~ m{^/},
		"the first field is a prefix-relative path: $line");
}

# The writer may legitimately produce an empty file; the reader must accept it.
my $empty = fake_tree('', 1);
is($empty->{code}, 0, 'an empty manifest still builds') or diag($empty->{output});
is(slurp($empty->{asset}), '', 'an empty manifest copies as an empty asset');

# A machine that has not produced native bins must not fail, and must not
# invent the property.
my $absent = fake_tree('', 0);
is($absent->{code}, 0, 'a build without releases/native-bins/ still succeeds')
	or diag($absent->{output});
unlike($absent->{args}, qr/-PjawnNativeBins=/,
	'no -PjawnNativeBins property when the directory is absent');
is(slurp($absent->{asset}), "placeholder\n",
	'the checked-in placeholder is left alone when there is nothing to copy');

# A release APK without the runtime is a phone that cannot start: 0.118.294
# was staged with no libbin_* at all, so every files/usr/bin symlink on every
# install pointed into nothing and the tree never started. Both shapes are
# refused now - the missing input directory, and an artifact that came back
# without the runtime.
my $nobins = fake_tree($manifest, 0, { release => 1 });
isnt($nobins->{code}, 0, 'a release build with no releases/native-bins is refused');
like($nobins->{output}, qr/native-bins/, 'and the refusal names the missing directory');

my $limbless = fake_tree($manifest, 1, { release => 1 });
isnt($limbless->{code}, 0, 'a release APK with no runtime in it is refused');
like($limbless->{output}, qr/libbin_perl\.so/, 'and the refusal names the missing library');
unlike($limbless->{output}, qr/^staged$/m, 'the staging step never ran');

# The app key is the identity, not just "a signature". 0.118.296 was built with
# the dev keystore, staged and published, and every phone that already ran a
# release build refused it with SIGNATURE_MISMATCH - so a tree holding the key
# builds the release by default, and the artifact's certificate is compared
# against the keystore's before anything is staged.
my $signed = fake_tree($manifest, 1, { keystore => 1, runtime => 1 });
is($signed->{code}, 0, 'a tree with the key builds and stages without being told')
	or diag($signed->{output});
like($signed->{args}, qr/^:app:assembleRelease$/m, 'the default build is the release variant');
like($signed->{output}, qr/signed with the release key/, 'the artifact is checked against the keystore');

my $dev = fake_tree($manifest, 1, { keystore => 1, runtime => 1, debug => 1 });
is($dev->{code}, 0, '--debug still builds the dev variant') or diag($dev->{output});
like($dev->{args}, qr/^:app:assembleDebug$/m, 'and it asks gradle for the debug variant');
like($dev->{output}, qr/cannot install over a release-signed app/,
	'saying out loud what such an APK cannot do');

my $wrong = fake_tree($manifest, 1, { keystore => 1, runtime => 1, signer => 'mismatch' });
isnt($wrong->{code}, 0, 'an APK signed by another key is refused');
like($wrong->{output}, qr/SIGNATURE_MISMATCH/, 'and the refusal says what a device would');
unlike($wrong->{output}, qr/^staged$/m, 'nothing is staged');

my $unsigned = fake_tree($manifest, 1, { keystore => 1, runtime => 1, signer => 'unsigned' });
isnt($unsigned->{code}, 0, 'an APK apksigner cannot verify is refused');
unlike($unsigned->{output}, qr/^staged$/m, 'and nothing is staged');

done_testing();
