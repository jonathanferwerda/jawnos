use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use Digest::SHA qw(sha256_hex);
use RepoSource;

# Archiving is a push: the source machine reads the file and the archive
# machine writes it. This pins the parts that make it observable and safe:
# byte fractions for the progress bar, the partial-file resume rule, the
# cancel that removes only the partial, and the delete-original guard.
#
# Everything here works in a tempdir. No real folder or archive_dir is touched.

my $root = repo_root();
require "$root/lib/JawnOS/Domain/Archive.pm";

# ---- progress is computed from bytes ----------------------------------------

my $one = subs::archive_progress_view({
	state => 'copying',
	file => 'clip.mp4',
	files => 1,
	index => 1,
	file_bytes_done => 250,
	file_bytes_total => 1000,
	bytes_done => 250,
	bytes_total => 1000,
});
is($one->{'file_fraction'}, 0.25, 'a quarter of the file is a 0.25 fraction');
is($one->{'file_percent'}, 25, 'and 25 percent of the file');
is($one->{'fraction'}, 0.25, 'the overall fraction is the same for one file');
is($one->{'percent'}, 25, 'and the overall percentage');
is($one->{'state'}, 'copying', 'the state is carried with the bytes');

my $many = subs::archive_progress_view({
	state => 'copying',
	file => 'second.mov',
	files => 4,
	index => 2,
	file_bytes_done => 100,
	file_bytes_total => 400,
	bytes_done => 1500,
	bytes_total => 3000,
});
is($many->{'file_fraction'}, 0.25, 'a file fraction is its own bytes');
is($many->{'fraction'}, 0.5, 'the overall fraction is every byte done over every byte queued');
is($many->{'percent'}, 50, 'so several queued files keep an overall line');
is($many->{'files'}, 4, 'the job carries how many files it has');

is(subs::archive_fraction(0, 0), 0, 'a job with no total never reports progress');
is(subs::archive_fraction(0, 10), 0, 'nothing done is zero');
is(subs::archive_fraction(10, 10), 1, 'all done is one');
is(subs::archive_fraction(20, 10), 1, 'a count past the total is clamped');
is(subs::archive_fraction(1, 3), 0.3333, 'fractions are rounded to four places');
is(subs::archive_progress_view({ file_bytes_done => 10, file_bytes_total => 10 })->{'file_percent'}, 100,
	'100 percent means finished, not nearly finished');

# ---- a partial copy is resumed, and only from the same source ----------------

my $tmp = tempdir(CLEANUP => 1);
make_path("$tmp/archive");
my $source = "$tmp/source.bin";
my $dest = "$tmp/archive/source.bin";
write_file($source, 'ABCDEFGHIJ');

my $part = subs::archive_partial_path($dest);
my $meta = subs::archive_partial_meta_path($dest);
is($part, "$dest.part", 'the partial sits beside the destination, not on it');
is($meta, "$dest.part.json", 'and has a sidecar naming its source');

write_file($part, 'ABCDE');
subs::archive_partial_meta_write($dest, {
	source => 'source.bin',
	total => 10,
	mtime => 1700000000,
});

my $state = subs::archive_partial_state({ path => $dest });
ok($state->{'exists'}, 'the partial is seen');
is($state->{'size'}, 5, 'with the bytes already written');
is($state->{'total'}, 10, 'and the size the copy expects');
is($state->{'mtime'}, 1700000000, 'and the source time it belongs to');
is($state->{'prefix_sha256'}, sha256_hex('ABCDE'), 'and a hash of the prefix, not a guess');

my $resume = subs::archive_resume_offset({
	file => $source,
	total => 10,
	mtime => 1700000000,
	partial => $state,
});
ok($resume->{'resumed'}, 'the same source resumes');
is($resume->{'offset'}, 5, 'from the byte after the partial');

# continue exactly the way the receiver does, then prove the result
open(my $out, '+<:raw', $part) or die "partial: $!";
seek($out, $resume->{'offset'}, 0);
my $whole = read_file($source);
print $out substr($whole, $resume->{'offset'});
close $out;
is(-s $part, length $whole, 'the resumed copy is the whole file');
is(read_file($part), $whole, 'and every byte matches the source');

# a different source in the same destination must never be stitched in
write_file($part, 'ZZZZZ');
subs::archive_partial_meta_write($dest, { source => 'source.bin', total => 10, mtime => 1700000000 });
my $other = subs::archive_resume_offset({
	file => $source,
	total => 10,
	mtime => 1700000000,
	partial => subs::archive_partial_state({ path => $dest }),
});
ok(!$other->{'resumed'}, 'a partial from another source is refused');
is($other->{'offset'}, 0, 'so the copy starts from zero');
like($other->{'reason'}, qr/(does not match|different source)/, 'and says why');

# a source whose time changed is a different source too
write_file($part, 'ABCDE');
subs::archive_partial_meta_write($dest, { source => 'source.bin', total => 10, mtime => 1600000000 });
my $stale = subs::archive_resume_offset({
	file => $source,
	total => 10,
	mtime => 1700000000,
	partial => subs::archive_partial_state({ path => $dest }),
});
ok(!$stale->{'resumed'}, 'a partial recorded against another time is not resumed');
is($stale->{'offset'}, 0, 'it starts again instead');

# a partial that is not smaller than the source cannot be resumed (it is done
# or wrong, and either way appending would corrupt it)
write_file($part, 'ABCDEFGHIJ');
subs::archive_partial_meta_write($dest, { source => 'source.bin', total => 10, mtime => 1700000000 });
my $full = subs::archive_resume_offset({ file => $source, total => 10, mtime => 1700000000, partial => subs::archive_partial_state({ path => $dest }) });
ok(!$full->{'resumed'}, 'a full-size partial is not appended to');
is($full->{'offset'}, 0, 'the receiver starts over');

# ---- cancel removes the partial and keeps the source ------------------------

ok(-e $source, 'the source is still there before the cancel');
my $discarded = subs::archive_partial_discard($dest);
is($discarded->{'removed'}, 2, 'cancel removes the partial and its sidecar');
ok(!-e $part, 'the partial copy is gone');
ok(!-e $meta, 'the sidecar is gone');
ok(-e $source, 'the original is untouched');
ok(!-e $dest, 'and nothing was moved onto the destination');

# ---- delete-original refuses until the destination is verified --------------

my $copy = "$tmp/archive/verified.bin";
write_file($copy, read_file($source));

my $unverified = subs::archive_delete_source({ source => $source });
ok($unverified->{'error'}, 'deleting without verification is refused');
like($unverified->{'error'}, qr/not verified/, 'and says it is not verified');
ok(-e $source, 'the original survives the refusal');

my $short = subs::archive_delete_source({
	source => $source, verified => 1, dest_size => 3, dest_sha256 => sha256_hex(read_file($copy)),
});
ok($short->{'error'}, 'a smaller destination is refused');
like($short->{'error'}, qr/different size/, 'the size guard names itself');
ok(-e $source, 'the original survives a size mismatch');

my $wrong = subs::archive_delete_source({
	source => $source, verified => 1, dest_size => 10, dest_sha256 => sha256_hex('not the copy'),
});
ok($wrong->{'error'}, 'a destination with another checksum is refused');
like($wrong->{'error'}, qr/checksums do not match/, 'the checksum guard names itself');
ok(-e $source, 'the original survives a checksum mismatch');

my $removed = subs::archive_delete_source({
	source => $source, verified => 1, dest_size => 10, dest_sha256 => sha256_hex(read_file($copy)),
});
ok($removed->{'deleted'}, 'a verified size and checksum allow the original to go');
is($removed->{'bytes'}, 10, 'the removed size is reported');
ok(!-e $source, 'the original is gone');
ok(-e $copy, 'and the verified copy stays');

# ---- the route, controller and app speak the same contract -------------------

my $archive = read_file("$root/lib/JawnOS/Domain/Archive.pm");
my $receiver = read_file("$root/lib/JawnOS/Controller/manager_folders2.pm");
my $jobs = read_file("$root/lib/JawnOS/Controller/manager_folders.pm");
my $routes = read_file("$root/lib/JawnOS/Routes/manager_folders2.pm");
my $script = js_source('public/js/manager/folders.js');
my $template = template_source('folders/dialog_box');
my $context = template_source('folders/context');

like($archive, qr/sub archive_progress_view/, 'the worker notes a structured progress view');
like($archive, qr/\$progress->\(\$offset \+ \$read, \$total\)/, 'progress is written during the copy, not only at the end');
like($archive, qr/sub archive_resume_offset/, 'the sender has one resume rule');
like($archive, qr/sub archive_partial_discard/, 'and one discard rule');
like($archive, qr/sub archive_delete_source/, 'and one delete-original guard');
like($archive, qr/eq 'verifying'/, 'a final chunk reports the verifying state');

like($receiver, qr{/manager/folders/archive/discard}, 'the receiver names the discard route');
like($receiver, qr/subs::archive_partial_path\(\$dest->\{'path'\}\)/, 'the receiver writes to the partial path');
like($receiver, qr/rename\(\$part, \$dest->\{'path'\}\)/, 'and renames only after the full size is checked');
like($receiver, qr/sha256 => \$sha/, 'the final response carries the checksum');
like($receiver, qr/sub action_30660/, 'the discard action exists');

like($routes, qr{'/manager/folders/archive/discard', 'action_30660'}, 'the discard route is registered');
like($jobs, qr/delete_after => \$delete_after/, 'the archive plan carries the explicit delete choice');
like($jobs, qr/my \$archive = \$notes->\{'archive'\}/, 'the job endpoint exposes the structured progress');

like($script, qr/job\['archive'\]/, 'the folders script draws from the job archive note');
like($script, qr/folders_job_bar_fill/, 'it has a progress bar');
like($script, qr/file_percent/, 'with a per-file line');
like($script, qr/archive_move/, 'and an explicit archive-and-remove command');
like($script, qr{foldersArchiveJob\('cancel'}, 'cancel still goes through the archive cancel path');
like($script, qr{'/manager/folders/archive/' \+ action}, 'and it is the archive job endpoint');
like($script, qr/All archive jobs/, 'and one overall line when several jobs are queued');
like($template, qr/job_bar/, 'the dialog template has the bar');
like($context, qr/archive_move/, 'the context menu offers the delete-original choice');

done_testing();
