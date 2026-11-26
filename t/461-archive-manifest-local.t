# tests-for: lib/JawnOS/Domain/Archive.pm lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_folders2.pm
# covers:    A laptop keeps its own copy of a remote archive's manifest and
#            revalidates it by digest in the background, so a Music search reads
#            the local rows instead of asking the archive machine every time.
#            A drive whose files moved without its listing queues a rescan, and
#            the periodic check is long enough not to walk the drive constantly.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use Digest::SHA qw(sha256_hex);
use JawnOSTest;

# The queue job only uses note/finish, so a plain object is enough.
package FakeJob;
sub new { bless { notes => [], finished => undef }, shift }
sub note { my ($self, $what, $message) = @_; push @{$self->{notes}}, $message; return 1 }
sub finish { my ($self, $result) = @_; $self->{finished} = $result; return 1 }

package FakeMinion;
sub new { bless { calls => [] }, shift }
sub enqueue {
	my ($self, $task, $args, $opts) = @_;
	push @{$self->{calls}}, { task => $task, args => $args, opts => $opts };
	return scalar @{$self->{calls}};
}

package main;

subs::preload($_) for qw(
	archive_manifest_digest archive_manifest_media_digest archive_manifest_rows_digest
	archive_manifest_combine_digest archive_manifest_listing_digest
	archive_manifest_read archive_manifest_write archive_manifest_append
	archive_manifest_local_key archive_manifest_local_read archive_manifest_local_write
	archive_manifest_cached archive_manifest_fetch archive_manifest_refresh_start
	archive_manifest_refresh_job archive_manifest_rescan_start archive_manifest_poll
	archive_destination archive_root
	cache_get cache_set setting_grabber device_setter minion_task_list
	machine_name signatorial_designer remote_machine_lister
);

sub clear_memos {
	%subs::archive_manifest_media_memo = ();
	%subs::archive_manifest_memo = ();
	return;
}

my $tmp = tempdir(CLEANUP => 1);
my $archive = "$tmp/archive";
make_path("$archive/Music");

local $subs::device = 'computer';
local $subs::config = { archive_dir => $archive };
local *subs::setting_grabber = sub { return undef };
local *subs::machine_name = sub { return 'Laptop' };
local *subs::signatorial_designer = sub { return 'laptopsig' };
local *subs::remote_machine_lister = sub { return [] };

# ---- the fingerprint -------------------------------------------------------
# It costs two stats on the drive's manifest files, so the far machine can
# answer "anything new?" without reading or sending the rows.

my $empty = subs::archive_manifest_digest("$archive/Music");
is($empty, subs::archive_manifest_digest("$archive/Music"), 'the digest is stable');
is(subs::archive_manifest_digest("$archive/Nope"), subs::archive_manifest_digest("$archive/Nope"),
	'a folder with no manifest still has a stable digest');

my $appended = subs::archive_manifest_append({
	location => 'music',
	rows => [ { relative => 'first.mp3', size => 3, mtime => 123, type => 'audio' } ],
});
is($appended->{'error'}, undef, 'the fixture manifest is written');
my $one = subs::archive_manifest_digest("$archive/Music");
isnt($one, $empty, 'a journal append changes the digest');

my $read = subs::archive_manifest_read({ dir => "$archive/Music" });
is($read->{'digest'}, $one, 'a read reports the same manifest fingerprint the route would');
is(scalar @{$read->{'rows'}}, 1, 'and the row is there');

# ---- the media sweep -------------------------------------------------------
# A file written straight onto the drive, with no manifest row, still changes
# the client-facing digest. The manifest files and a transfer's partials do not.

clear_memos();
my $media_before = subs::archive_manifest_media_digest("$archive/Music");
subs::archive_manifest_append({
	location => 'music',
	rows => [ { relative => 'second.mp3', size => 4, mtime => 456, type => 'audio' } ],
});
clear_memos();
is(subs::archive_manifest_media_digest("$archive/Music"), $media_before,
	'the media sweep ignores the manifest files');

clear_memos();
my $listing_before = subs::archive_manifest_listing_digest("$archive/Music");
write_file("$archive/Music/first.mp3", 'abc');
my $first_mtime = (stat("$archive/Music/first.mp3"))[9];
utime($first_mtime + 10, $first_mtime + 10, "$archive/Music/first.mp3");
clear_memos();
isnt(subs::archive_manifest_listing_digest("$archive/Music"), $listing_before,
	'a media file the manifest has not seen changes the listing digest');

clear_memos();
my $listing_file = subs::archive_manifest_listing_digest("$archive/Music");
write_file("$archive/Music/first.mp3", 'xyz');
utime($first_mtime + 20, $first_mtime + 20, "$archive/Music/first.mp3");
clear_memos();
isnt(subs::archive_manifest_listing_digest("$archive/Music"), $listing_file,
	'a same-size rewrite still changes the listing digest when its time does');

clear_memos();
my $listing_open = subs::archive_manifest_listing_digest("$archive/Music");
write_file("$archive/Music/first.mp3.part", 'partial');
write_file("$archive/Music/first.mp3.part.json", '{}');
write_file("$archive/Music/manifest.json.tmp", '[]');
clear_memos();
is(subs::archive_manifest_listing_digest("$archive/Music"), $listing_open,
	'a transfer partial and a manifest rewrite temp are not part of the listing digest');
unlink "$archive/Music/first.mp3.part";
unlink "$archive/Music/first.mp3.part.json";
unlink "$archive/Music/manifest.json.tmp";

# ---- the listing rows and the sweep ---------------------------------------
# A listing written from the drive's own files has the same fingerprint as the
# sweep, which is what lets the poll tell a listing change from a drive change.

my $poll_dir = "$tmp/poll";
make_path($poll_dir);
write_file("$poll_dir/a.mp3", 'aaa');
write_file("$poll_dir/b.mp3", 'bbbb');
my $a_mtime = (stat("$poll_dir/a.mp3"))[9];
my $b_mtime = (stat("$poll_dir/b.mp3"))[9];
my @poll_rows = (
	{ relative => 'a.mp3', size => 3, mtime => $a_mtime, type => 'audio' },
	{ relative => 'b.mp3', size => 4, mtime => $b_mtime, type => 'audio' },
);
subs::archive_manifest_write({ dir => $poll_dir, rows => \@poll_rows });
clear_memos();
my $poll_media = subs::archive_manifest_media_digest($poll_dir);
my $poll_rows_digest = subs::archive_manifest_rows_digest(\@poll_rows);
is($poll_rows_digest, $poll_media, 'the listing rows and the media sweep agree');
my $poll_manifest = subs::archive_manifest_digest($poll_dir);
my $poll_digest = subs::archive_manifest_combine_digest($poll_manifest, $poll_media);
is($poll_digest, subs::archive_manifest_listing_digest($poll_dir), 'the combined digest is the listing digest');

# ---- the poll: unchanged, a listing change, and a drive-only change --------
{
	my $rescans = 0;
	local *subs::archive_manifest_rescan_start = sub { $rescans++; return 1 };
	my $answer = subs::archive_manifest_poll({
		location => 'poll', folder => $poll_dir,
		digest => $poll_digest, manifest_digest => $poll_manifest,
	});
	ok($answer->{'unchanged'}, 'a matching digest is unchanged');
	is($rescans, 0, 'and starts no rescan');
	is(scalar @{$answer->{'rows'} || []}, 0, 'with no rows sent');
}

# A media-only change keeps the client's digest and queues one rescan.
{
	write_file("$poll_dir/a.mp3", 'zzzzz');
	utime($a_mtime + 60, $a_mtime + 60, "$poll_dir/a.mp3");
	clear_memos();
	my $rescans = 0;
	local *subs::archive_manifest_rescan_start = sub { $rescans++; return 1 };
	my $answer = subs::archive_manifest_poll({
		location => 'poll', folder => $poll_dir,
		digest => $poll_digest, manifest_digest => $poll_manifest,
	});
	ok($answer->{'unchanged'}, 'a media-only change is not a new listing');
	ok($answer->{'media_changed'}, 'it says the drive changed');
	is($answer->{'rescan'}, 1, 'and queues a rescan');
	is($rescans, 1, 'one rescan is queued');
	is($answer->{'digest'}, $poll_digest, 'the client keeps its old digest so a failed rescan is retried');
	is(scalar @{$answer->{'rows'} || []}, 0, 'no rows are sent for a listing that did not move');
}

# Once the rescan rewrites the listing, the same client gets the new rows.
{
	my @new_rows = (
		{ relative => 'a.mp3', size => 5, mtime => (stat("$poll_dir/a.mp3"))[9], type => 'audio' },
		{ relative => 'b.mp3', size => 4, mtime => $b_mtime, type => 'audio' },
	);
	subs::archive_manifest_write({ dir => $poll_dir, rows => \@new_rows });
	clear_memos();
	my $rescans = 0;
	local *subs::archive_manifest_rescan_start = sub { $rescans++; return 1 };
	my $answer = subs::archive_manifest_poll({
		location => 'poll', folder => $poll_dir,
		digest => $poll_digest, manifest_digest => $poll_manifest,
	});
	ok(!$answer->{'unchanged'}, 'a rewritten listing is sent');
	is($answer->{'manifest_digest'}, subs::archive_manifest_digest($poll_dir), 'with the new manifest part');
	is(scalar @{$answer->{'rows'}}, 2, 'and the rows');
	is($answer->{'rows'}[0]{'size'}, 5, 'the row reflects the file');
	is($rescans, 0, 'the corrected listing queues no further rescan');
}

# A hand-filled drive has no listing at all; the first ask queues a rescan.
{
	my $hand = "$tmp/hand";
	make_path($hand);
	write_file("$hand/song.mp3", 'x');
	clear_memos();
	my $rescans = 0;
	local *subs::archive_manifest_rescan_start = sub { $rescans++; return 1 };
	my $answer = subs::archive_manifest_poll({ location => 'hand', folder => $hand });
	is($rescans, 1, 'a drive with no listing queues a rescan on the first ask');
	ok($answer->{'rescan'}, 'and says so');
	is(scalar @{$answer->{'rows'} || []}, 0, 'the first answer has no rows yet');
	is($answer->{'digest'}, '', 'and carries no settled digest, so the next poll asks again');
}

# ---- the rescan throttle ---------------------------------------------------
{
	my $minion = FakeMinion->new;
	local *subs::minion_grabber = sub { return $minion };
	my $first = subs::archive_manifest_rescan_start({ location => 'throttle-1' });
	is($first, 1, 'the first drift queues a rescan');
	is(scalar @{$minion->{calls}}, 1, 'one enqueue');
	is($minion->{calls}[0]{'task'}, 'archive_manifest_rescan', 'for the rescan job');
	is($minion->{calls}[0]{'args'}[0]{'location'}, 'throttle-1', 'with the location');
	my $second = subs::archive_manifest_rescan_start({ location => 'throttle-1' });
	is($second, 0, 'a second drift inside the interval is throttled');
	is(scalar @{$minion->{calls}}, 1, 'and does not enqueue again');
	my $other = subs::archive_manifest_rescan_start({ location => 'throttle-2' });
	is($other, 1, 'another location has its own throttle');
}

# ---- the local copy --------------------------------------------------------

my $local_row = {
	relative => 'first.mp3',
	size => 3,
	mtime => 123,
	type => 'audio',
};
subs::archive_manifest_local_write({
	remote_uuid => 'peer-1',
	location => 'music',
	folder => '/mnt/archive/Music',
	hostname => 'Studio',
	rows => [ { %{$local_row} } ],
	digest => 'digest-1',
	manifest_digest => 'manifest-1',
});
my $local = subs::archive_manifest_local_read({ remote_uuid => 'peer-1', location => 'music' });
is($local->{'folder'}, '/mnt/archive/Music', 'the folder rides with the local copy');
is($local->{'digest'}, 'digest-1', 'so does the fingerprint');
is($local->{'manifest_digest'}, 'manifest-1', 'and the manifest part');
is($local->{'hostname'}, 'Studio', 'and the machine name');
is(scalar @{$local->{'rows'}}, 1, 'with the rows');
ok($local->{'checked'}, 'and when it was last checked');
is(subs::archive_manifest_local_read({ remote_uuid => 'peer-2', location => 'music' }), undef,
	'another archive machine is a different copy');

# ---- the background revalidation ------------------------------------------
# An unchanged digest keeps the rows and only moves `checked`, so the drive is
# checked once per interval rather than once a search.

{
	local *subs::archive_manifest_fetch = sub {
		return { status => 'ok', unchanged => 1, digest => 'digest-1', manifest_digest => 'manifest-1', folder => '/mnt/archive/Music', hostname => 'Studio' };
	};
	my $stale = subs::rightNow() - 70 * 60 * 1000;
	subs::archive_manifest_local_write({ %{$local}, checked => $stale });
	my $row_key = {
		app => 'archive', context => 'manifest',
		subcontext => sha256_hex(subs::archive_manifest_local_key('peer-1', 'music')),
		device => 'computer',
	};
	my $stamp_before = subs::db_select_simple('cache', ['timestamp'], $row_key)->hashes->[0]{'timestamp'};
	my $job = FakeJob->new;
	subs::archive_manifest_refresh_job($job, { remote_uuid => 'peer-1', location => 'music', digest => 'digest-1' });
	ok($job->{'finished'}{'unchanged'}, 'an unchanged listing says so');
	my $after = subs::archive_manifest_local_read({ remote_uuid => 'peer-1', location => 'music' });
	is_deeply($after->{'rows'}, $local->{'rows'}, 'the rows are kept');
	is($after->{'digest'}, 'digest-1', 'the fingerprint is kept');
	cmp_ok($after->{'checked'}, '>', $stale, 'and the check time moves forward');
	my $stamp_after = subs::db_select_simple('cache', ['timestamp'], $row_key)->hashes->[0]{'timestamp'};
	is($stamp_after, $stamp_before, 'an unchanged check does not rewrite the listing');
}

# A changed digest replaces the rows and both fingerprints.
{
	local *subs::archive_manifest_fetch = sub {
		return {
			status => 'ok',
			digest => 'digest-2',
			manifest_digest => 'manifest-2',
			folder => '/mnt/archive/Music',
			hostname => 'Studio',
			rows => [
				{ %{$local_row} },
				{ relative => 'second.mp3', size => 4, mtime => 456, type => 'audio' },
			],
		};
	};
	my $job = FakeJob->new;
	subs::archive_manifest_refresh_job($job, { remote_uuid => 'peer-1', location => 'music', digest => 'digest-1' });
	ok($job->{'finished'}{'changed'}, 'a changed listing says so');
	my $after = subs::archive_manifest_local_read({ remote_uuid => 'peer-1', location => 'music' });
	is($after->{'digest'}, 'digest-2', 'the new fingerprint is stored');
	is($after->{'manifest_digest'}, 'manifest-2', 'and the new manifest part');
	is(scalar @{$after->{'rows'}}, 2, 'and the new rows replace the old');
	is($after->{'rows'}[1]{'relative'}, 'second.mp3', 'the added track is there');
}

# A media-only answer keeps the old digest so the next poll asks again.
{
	local *subs::archive_manifest_fetch = sub {
		return { status => 'ok', unchanged => 1, media_changed => 1, rescan => 1, digest => 'digest-new', manifest_digest => 'manifest-2' };
	};
	my $stale = subs::rightNow() - 70 * 60 * 1000;
	subs::archive_manifest_local_write({ %{$local}, digest => 'digest-2', manifest_digest => 'manifest-2', checked => $stale });
	my $job = FakeJob->new;
	subs::archive_manifest_refresh_job($job, { remote_uuid => 'peer-1', location => 'music', digest => 'digest-2' });
	ok($job->{'finished'}{'media_changed'}, 'a media-only reply says so');
	ok($job->{'finished'}{'rescan'}, 'and that a rescan is queued');
	my $after = subs::archive_manifest_local_read({ remote_uuid => 'peer-1', location => 'music' });
	is($after->{'digest'}, 'digest-2', 'the client keeps its old digest so a failed rescan is retried');
	cmp_ok($after->{'checked'}, '>', $stale, 'and the check time moves forward');
}

# A partless row from before the manifest part existed adopts it once.
{
	local *subs::archive_manifest_fetch = sub {
		return { status => 'ok', unchanged => 1, digest => 'digest-3', manifest_digest => 'manifest-3' };
	};
	subs::archive_manifest_local_write({
		remote_uuid => 'peer-3',
		location => 'music',
		folder => '/mnt/archive/Music',
		hostname => 'Studio',
		rows => [ { %{$local_row} } ],
		digest => 'digest-3',
	});
	my $job = FakeJob->new;
	subs::archive_manifest_refresh_job($job, { remote_uuid => 'peer-3', location => 'music', digest => 'digest-3' });
	my $after = subs::archive_manifest_local_read({ remote_uuid => 'peer-3', location => 'music' });
	is($after->{'manifest_digest'}, 'manifest-3', 'a partless row adopts the manifest part');
}

# A machine that does not answer keeps the copy and still moves `checked`, so
# a sleeping peer is asked once per interval, not once a search.
{
	local *subs::archive_manifest_fetch = sub {
		return { error => 'the archive machine did not answer' };
	};
	my $stale = subs::rightNow() - 70 * 60 * 1000;
	my $before = subs::archive_manifest_local_write({ %{$local}, digest => 'digest-2', checked => $stale });
	my $job = FakeJob->new;
	subs::archive_manifest_refresh_job($job, { remote_uuid => 'peer-1', location => 'music', digest => 'digest-2' });
	ok($job->{'finished'}{'error'}, 'the failure is reported to the queue');
	my $after = subs::archive_manifest_local_read({ remote_uuid => 'peer-1', location => 'music' });
	is_deeply($after->{'rows'}, $before->{'rows'}, 'the rows survive an unreachable machine');
	cmp_ok($after->{'checked'}, '>', $stale, 'and the next check waits, so searches are not flooded');
}

# ---- a search reads the local copy, never the rail -------------------------

{
	clear_memos();
	my $stale = subs::rightNow() - 70 * 60 * 1000;
	subs::archive_manifest_local_write({
		remote_uuid => 'peer-1',
		location => 'music',
		folder => '/mnt/archive/Music',
		hostname => 'Studio',
		rows => [ { %{$local_row} }, { relative => 'second.mp3', size => 4, mtime => 456, type => 'audio' } ],
		digest => 'digest-2',
		manifest_digest => 'manifest-2',
		checked => $stale,
	});
	my ($fetched, $started) = (0, 0);
	local *subs::archive_manifest_fetch = sub { $fetched++; die "the search must not fetch\n" };
	local *subs::archive_manifest_refresh_start = sub { $started++; return 1 };
	my $answer = subs::archive_manifest_cached({ remote_uuid => 'peer-1', location => 'music' });
	is($answer->{'cached'}, 1, 'a search answers from the local copy');
	is(scalar @{$answer->{'rows'}}, 2, 'with the rows it already holds');
	is($answer->{'digest'}, 'digest-2', 'and the fingerprint it recorded');
	is($fetched, 0, 'the archive machine is not asked during the search');
	is($started, 1, 'a copy older than the interval starts one background check');
}

# Fifty minutes is inside the hour; a fresh copy starts no check at all.
{
	clear_memos();
	my $recent = subs::rightNow() - 50 * 60 * 1000;
	subs::archive_manifest_local_write({
		remote_uuid => 'peer-1',
		location => 'music',
		folder => '/mnt/archive/Music',
		hostname => 'Studio',
		rows => [ { %{$local_row} } ],
		digest => 'digest-1',
		manifest_digest => 'manifest-1',
		checked => $recent,
	});
	my $started = 0;
	local *subs::archive_manifest_refresh_start = sub { $started++; return 1 };
	local *subs::archive_manifest_fetch = sub { die "the search must not fetch\n" };
	subs::archive_manifest_cached({ remote_uuid => 'peer-1', location => 'music' });
	is($started, 0, 'a copy checked fifty minutes ago waits for the next interval');
}

{
	clear_memos();
	subs::archive_manifest_local_write({
		remote_uuid => 'peer-1',
		location => 'music',
		folder => '/mnt/archive/Music',
		hostname => 'Studio',
		rows => [ { %{$local_row} } ],
		digest => 'digest-1',
		manifest_digest => 'manifest-1',
		checked => subs::rightNow(),
	});
	my $started = 0;
	local *subs::archive_manifest_refresh_start = sub { $started++; return 1 };
	local *subs::archive_manifest_fetch = sub { die "the search must not fetch\n" };
	subs::archive_manifest_cached({ remote_uuid => 'peer-1', location => 'music' });
	is($started, 0, 'a fresh copy starts no check');
}

# ---- the first search fills the local copy ---------------------------------

{
	clear_memos();
	my $fetched = 0;
	local *subs::archive_manifest_fetch = sub {
		$fetched++;
		return {
			status => 'ok',
			folder => '/mnt/archive/Music',
			hostname => 'Studio',
			digest => 'digest-9',
			manifest_digest => 'manifest-9',
			rows => [ { relative => 'new.mp3', size => 1, mtime => 1, type => 'audio' } ],
		};
	};
	my $answer = subs::archive_manifest_cached({ remote_uuid => 'peer-9', location => 'music' });
	isnt($answer->{'cached'}, 1, 'the first search does fetch');
	is($answer->{'digest'}, 'digest-9', 'and keeps the fingerprint');
	is($fetched, 1, 'one request, once');
}
{
	my $stored = subs::archive_manifest_local_read({ remote_uuid => 'peer-9', location => 'music' });
	is($stored->{'digest'}, 'digest-9', 'the answer is kept locally for the next search');
	is($stored->{'manifest_digest'}, 'manifest-9', 'with the manifest part');
}
{
	clear_memos();
	local *subs::archive_manifest_fetch = sub { die "the next search must not fetch\n" };
	my $answer = subs::archive_manifest_cached({ remote_uuid => 'peer-9', location => 'music' });
	is($answer->{'cached'}, 1, 'the next search answers locally');
}

# ---- the wiring ------------------------------------------------------------

my $tasks = subs::minion_task_list();
ok($tasks->{'archive_manifest_refresh'}, 'the background check is a registered queue job');
is($tasks->{'archive_manifest_refresh'}, \&subs::archive_manifest_refresh_job,
	'and it points at the revalidation job');
ok($tasks->{'archive_manifest_rescan'}, 'the rescan is a registered queue job');

my $root = root();
my $folders2 = read_file("$root/lib/JawnOS/Controller/manager_folders2.pm");
like($folders2, qr/archive_manifest_poll\(\{/, 'the manifest route hands the poll the drive and the client digest');
like($folders2, qr/manifest_digest => \$known_manifest/, 'including the manifest part');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/archive_manifest_poll/, 'the loader maps the poll');
like($loader, qr/archive_manifest_rescan_start/, 'and the rescan request');

done_testing();
