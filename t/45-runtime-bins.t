use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use Cwd qw(abs_path);

# M5 (docs/leaving-termux.md): targetSdk 36 stops the app exec'ing a file it
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
	my ($manifest, $with_bins) = @_;
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

	my $args_file = "$tmp/gradle-args";
	my $apk_dir   = "$app/app/build/outputs/apk/debug";
	spew("$app/gradlew",
		"#!/bin/sh\n"
		. "printf '%s\\n' \"\$@\" > " . shq($args_file) . "\n"
		. "mkdir -p " . shq($apk_dir) . "\n"
		. "printf 'apk' > " . shq("$apk_dir/universal.apk") . "\n");
	chmod 0755, "$app/gradlew";

	my $sdk = "$tmp/sdk";
	my $jdk = "$tmp/jdk";
	make_path($sdk, "$jdk/bin");
	spew("$jdk/bin/java", "#!/bin/sh\nexit 0\n");
	chmod 0755, "$jdk/bin/java";

	if ($with_bins) {
		make_path("$tree/releases/native-bins");
		spew("$tree/releases/native-bins/runtime-bins.txt", $manifest);
	}

	my $out;
	{
		local $ENV{'JAVA_HOME'}        = $jdk;
		local $ENV{'ANDROID_SDK_ROOT'} = $sdk;
		$out = qx{$^X '$tree/scripts/app_build.pl' --repo '$app' 2>&1};
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

done_testing();
