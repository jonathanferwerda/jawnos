use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use feature 'signatures';
no warnings 'experimental::signatures';

# Camera captures on the Android app (v0.1.1676) had two separate failures:
#
#   1. The appointment details view posts /manager/take_picture. On the phone
#      the capture itself succeeded, then ocr_reader ran `tesseract`, found no
#      output (the Termux image has no tesseract), and called read_file on the
#      missing .txt. Mojo::File::read_file croaks, so the request ended in HTTP
#      500 after the JPEG was already on disk and before the appointment row was
#      updated - the picture looked lost.
#   2. The wrapper's native camera handed the whole file back as base64 through
#      evaluateJavascript. A normal photo is several megabytes, far past the
#      WebView binder transaction, so window.__jawnCameraResult never ran; the
#      camera opened and nothing was ever written. It also posted to
#      /manager/upload_file with no uuid, which files a new row instead of the
#      appointment the button belongs to.
#
# The fix is one road for both templates: window.JawnCamera stages the file in
# the shared Termux home, the page posts only its path to /manager/take_picture,
# the route claims it into the house's photo/video folder, and OCR is optional.

my $manager = read_file("$FindBin::Bin/../Manager.pl");
my $js = read_file("$FindBin::Bin/../public/js/manager/manager.js");
my $details = read_file("$FindBin::Bin/../templates/appointment_details.html.ep");
my $wrapper = read_file("$FindBin::Bin/../templates/appointment_wrapper.html.ep");

# --- OCR cannot fail a capture ------------------------------------------------
my ($ocr_body) = $manager =~ /(sub ocr_reader\(.*?\n\})/s;
ok(defined $ocr_body, 'ocr_reader is present');
like($ocr_body, qr/command -v tesseract/, 'ocr_reader checks that an OCR engine exists');
like($ocr_body, qr/unless \(-e \$text_file\)/, 'ocr_reader refuses to read a .txt tesseract never wrote');
like($ocr_body, qr/eval \{ read_file\(\$text_file\) \}/, 'a read failure is caught instead of killing the request');
unlike($ocr_body, qr/^\s*my \$ocr = read_file\(\$text_file\);/m, 'no unguarded read_file remains');

# Run the real extracted sub with a stub shell. The phone's failure is "engine
# wrote no .txt"; the old code died there, the new code returns no text.
package CameraOcr;
sub read_file {
	my ($file) = @_;
	open(my $fh, '<', $file) or die "read_file '$file': $!";
	local $/;
	return scalar <$fh>;
}
package subs;
sub shell_quote {
	my $s = shift // '';
	$s =~ s/'/'\\''/g;
	return "'" . $s . "'";
}
sub session_suds { return 'suds' }
sub note_encrypter {
	my ($secret, $content) = @_;
	return defined $content && length $content ? "enc:$content" : undef;
}
package main;

my $code = "package CameraOcr;\n$ocr_body\n1;";
my $compiled = eval $code;
is($@, '', 'the extracted ocr_reader compiles against the stubs');

auto_dummy: {
	my $dir = tempdir(CLEANUP => 1);
	my $input = "$dir/photo.jpg";
	open(my $fh, '>', $input) or die $!;
	print $fh 'jpeg';
	close $fh;

	# a tesseract that succeeds
	my $bin = "$dir/bin";
	make_path($bin);
	open(my $t, '>', "$bin/tesseract") or die $!;
	print $t "#!/bin/sh\nprintf 'hello from ocr' > \"\$2.txt\"\n";
	close $t;
	chmod 0755, "$bin/tesseract";
	local $ENV{PATH} = $bin;
	is(CameraOcr::ocr_reader(undef, $input), 'enc:hello from ocr', 'a successful OCR still returns text');
}

no_engine: {
	my $dir = tempdir(CLEANUP => 1);
	my $input = "$dir/photo.jpg";
	open(my $fh, '>', $input) or die $!;
	print $fh 'jpeg';
	close $fh;
	my $bin = "$dir/empty";
	make_path($bin);
	local $ENV{PATH} = $bin;
	my $got = eval { CameraOcr::ocr_reader(undef, $input) };
	is($@, '', 'a device with no tesseract does not die');
	is($got, undef, 'no tesseract means no text, not HTTP 500');
}

engine_failed: {
	my $dir = tempdir(CLEANUP => 1);
	my $input = "$dir/photo.jpg";
	open(my $fh, '>', $input) or die $!;
	print $fh 'jpeg';
	close $fh;
	# tesseract present but writes no .txt - the phone's actual failure
	my $bin = "$dir/bin";
	make_path($bin);
	open(my $t, '>', "$bin/tesseract") or die $!;
	print $t "#!/bin/sh\nexit 1\n";
	close $t;
	chmod 0755, "$bin/tesseract";
	local $ENV{PATH} = $bin;
	my $got = eval { CameraOcr::ocr_reader(undef, $input) };
	is($@, '', 'an engine that produced no .txt does not die');
	is($got, undef, 'the capture proceeds without OCR text');
}

# --- the staged-path guard really rejects what it should --------------------
my ($dir_sub) = $manager =~ /(sub native_capture_dir\(\) \{.*?\n\})/s;
my ($claim_sub) = $manager =~ /(sub native_capture_claim\(.*?\n\})/s;
ok(defined $dir_sub && defined $claim_sub, 'both native capture helpers are present');

{
	package subs;
	our $claim_root = '';
	sub home { my $p = shift // ''; return $subs::claim_root . '/' . $p }
}
my $claim_code = "package CameraClaim;\n$dir_sub\n$claim_sub\n1;";
my $claim_ok = eval $claim_code;
is($@, '', 'the native capture helpers compile against the stubs');

{
	my $root = tempdir(CLEANUP => 1);
	local $subs::claim_root = $root;
	my $dir = "$root/.jawn/captures";
	make_path($dir);
	my $good = "$dir/jawn_123.jpg";
	open(my $fh, '>', $good) or die $!;
	print $fh 'jpeg';
	close $fh;
	is(CameraClaim::native_capture_claim($good), $good, 'a plain file in the staging dir is claimed');
	is(CameraClaim::native_capture_claim("$dir/../secret.jpg"), undef, 'a traversal out of the staging dir is refused');
	is(CameraClaim::native_capture_claim("$dir/nested/jawn.jpg"), undef, 'a path below the staging dir is refused');
	is(CameraClaim::native_capture_claim('/etc/passwd'), undef, 'a file outside the staging dir is refused');
	is(CameraClaim::native_capture_claim(''), undef, 'an empty path is refused');
	my $link = "$dir/jawn_link.jpg";
	symlink('/etc/passwd', $link);
	is(CameraClaim::native_capture_claim($link), undef, 'a symlink in the staging dir is refused');
	is(CameraClaim::native_capture_claim("$dir/missing.jpg"), undef, 'a path that is not a file is refused');
}

# --- the route claims a staged native capture --------------------------------
like($manager, qr/sub native_capture_dir/, 'there is one staging directory for native captures');
like($manager, qr/sub native_capture_claim/, 'the staged path is validated before use');
like($manager, qr/native_capture_claim\(\$native_path\)/, 'take_picture claims the path the app named');
like($manager, qr/return \('denial','denial'\) if length \$native_path && !\$native_capture/,
	'a stale or outside-the-staging-dir path is refused, not re-captured');
like($manager, qr/my \$native_path = \$c->param\('native_path'\)/, '/manager/take_picture reads native_path');
like($manager, qr/!length \$native_path && \$timestamp >=/, 'an already-taken capture is never deferred as a future duty');
like($manager, qr/elsif \(\$device eq 'mobile'/, 'the old termux camera.photo path remains as a fallback');

# The details view names the row it belongs to; the wrapper names only the app.
like($manager, qr/if \(!\$uuid && !\$data->\{'capture_only'\} && \$app ne 'camera'\)/,
	'a wrapper capture resolves the app\'s newest appointment row');
like($manager, qr/select uuid from appointments where app=\? and uuid is not null order by server_time desc/,
	'that resolution is the newest row, never the Camera app\'s unclaimed media');
like($manager, qr/\$data->\{'uuid'\} = \$uuid if \$uuid;/, 'the resolved row is handed back to the caller');
like($manager, qr/\$data->\{'uuid'\} \|\| \$uuid/, 'the websocket refresh names the resolved row');

# --- the web side uses the bridge for both templates -------------------------
like($js, qr/if \(jawnCameraAvailable\(\) && \(camera === '0' \|\| camera === '1'\)\)/,
	'.take_picture uses the app camera when the bridge answers');
like($js, qr/window\.__jawnCameraPending = \{ app: app, uuid: uuid, camera: camera, timestamp: timestamp \};/,
	'the details capture carries its appointment uuid and facing');
like($js, qr/native_path: result\.path/, 'a native capture posts the path, not the bytes');
like($js, qr/url: '\/manager\/take_picture'/, 'the native capture goes to the same route as the details button');
like($js, qr/window\.JawnCamera\.photo\(b\.attr\('capture'\) \|\| '0'\)/, 'the wrapper native button still opens the OS camera');
like($js, qr/formData\.append\('uuid', pending\.uuid \|\| ''\)/, 'the base64 fallback keeps the appointment uuid');

# --- both templates still render their own camera controls -------------------
like($details, qr/class="little_thumb take_picture hover" camera="0"/, 'details renders the rear camera button');
like($details, qr/class="little_thumb take_picture hover" camera="1"/, 'details renders the front camera button');
like($wrapper, qr/class="little_thumb native_capture"/, 'wrapper renders the native camera button');

done_testing();
