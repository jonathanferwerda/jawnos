# tests-for: lib/JawnOS/Domain/Archive.pm lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_folders2.pm
# covers:    A laptop keeps its own copy of a remote archive's manifest and
#            revalidates it by digest in the background, so a Music search reads
#            the local rows instead of asking the archive machine every time.

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

package main;

subs::preload($_) for qw(
	archive_manifest_digest archive_manifest_media_digest archive_manifest_listing_digest
	archive_manifest_read archive_manifest_append
	archive_manifest_local_key archive_manifest_local_read archive_manifest_local_write
	archive_manifest_cached archive_manifest_fetch archive_manifest_refresh_start
	archive_manifest_refresh_job archive_destination archive_root
	cache_get cache_set setting_grabber device_setter minion_task_list
	machine_name signatorial_designer remote_machine_lister
);

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

%subs::archive_manifest_media_memo = ();
my $media_before = subs::archive_manifest_media_digest("$archive/Music");
subs::archive_manifest_append({
	location => 'music',
	rows => [ { relative => 'second.mp3', size => 4, mtime => 456, type => 'audio' } ],
});
%subs::archive_manifest_media_memo = ();
is(subs::archive_manifest_media_digest("$archive/Music"), $media_before,
	'the media sweep ignores the manifest files');

%subs::archive_manifest_media_memo = ();
my $listing_before = subs::archive_manifest_listing_digest("$archive/Music");
write_file("$archive/Music/first.mp3", 'abc');
my $first_mtime = (stat("$archive/Music/first.mp3"))[9];
utime($first_mtime + 10, $first_mtime + 10, "$archive/Music/first.mp3");
%subs::archive_manifest_media_memo = ();
isnt(subs::archive_manifest_listing_digest("$archive/Music"), $listing_before,
	'a media file the manifest has not seen changes the listing digest');

%subs::archive_manifest_media_memo = ();
my $listing_file = subs::archive_manifest_listing_digest("$archive/Music");
write_file("$archive/Music/first.mp3", 'xyz');
utime($first_mtime + 20, $first_mtime + 20, "$archive/Music/first.mp3");
%subs::archive_manifest_media_memo = ();
isnt(subs::archive_manifest_listing_digest("$archive/Music"), $listing_file,
	'a same-size rewrite still changes the listing digest when its time does');

%subs::archive_manifest_media_memo = ();
my $listing_open = subs::archive_manifest_listing_digest("$archive/Music");
write_file("$archive/Music/first.mp3.part", 'partial');
write_file("$archive/Music/first.mp3.part.json", '{}');
write_file("$archive/Music/manifest.json.tmp", '[]');
%subs::archive_manifest_media_memo = ();
is(subs::archive_manifest_listing_digest("$archive/Music"), $listing_open,
	'a transfer partial and a manifest rewrite temp are not part of the listing digest');
unlink "$archive/Music/first.mp3.part";
unlink "$archive/Music/first.mp3.part.json";
unlink "$archive/Music/manifest.json.tmp";

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
});
my $local = subs::archive_manifest_local_read({ remote_uuid => 'peer-1', location => 'music' });
is($local->{'folder'}, '/mnt/archive/Music', 'the folder rides with the local copy');
is($local->{'digest'}, 'digest-1', 'so does the fingerprint');
is($local->{'hostname'}, 'Studio', 'and the machine name');
is(scalar @{$local->{'rows'}}, 1, 'with the rows');
ok($local->{'checked'}, 'and when it was last checked');
is(subs::archive_manifest_local_read({ remote_uuid => 'peer-2', location => 'music' }), undef,
	'another archive machine is a different copy');

# ---- the background revalidation ------------------------------------------
# An unchanged digest keeps the rows and only moves `checked`, so the check is
# repeated once a minute rather than once a search.

{
	local *subs::archive_manifest_fetch = sub {
		return { status => 'ok', unchanged => 1, digest => 'digest-1', folder => '/mnt/archive/Music', hostname => 'Studio' };
	};
	my $stale = subs::rightNow() - 5 * 60 * 1000;
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

# A changed digest replaces the rows and the fingerprint.
{
	local *subs::archive_manifest_fetch = sub {
		return {
			status => 'ok',
			digest => 'digest-2',
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
	is(scalar @{$after->{'rows'}}, 2, 'and the new rows replace the old');
	is($after->{'rows'}[1]{'relative'}, 'second.mp3', 'the added track is there');
}

# A machine that does not answer keeps the copy and still moves `checked`, so
# a sleeping peer is asked once a minute, not once a search.
{
	local *subs::archive_manifest_fetch = sub {
		return { error => 'the archive machine did not answer' };
	};
	my $stale = subs::rightNow() - 5 * 60 * 1000;
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
	%subs::archive_manifest_memo = ();
	my $stale = subs::rightNow() - 5 * 60 * 1000;
	subs::archive_manifest_local_write({
		remote_uuid => 'peer-1',
		location => 'music',
		folder => '/mnt/archive/Music',
		hostname => 'Studio',
		rows => [ { %{$local_row} }, { relative => 'second.mp3', size => 4, mtime => 456, type => 'audio' } ],
		digest => 'digest-2',
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
	is($started, 1, 'a stale copy starts one background check');
}

# A fresh copy starts no check at all.
{
	%subs::archive_manifest_memo = ();
	subs::archive_manifest_local_write({
		remote_uuid => 'peer-1',
		location => 'music',
		folder => '/mnt/archive/Music',
		hostname => 'Studio',
		rows => [ { %{$local_row} } ],
		digest => 'digest-1',
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
	%subs::archive_manifest_memo = ();
	my $fetched = 0;
	local *subs::archive_manifest_fetch = sub {
		$fetched++;
		return {
			status => 'ok',
			folder => '/mnt/archive/Music',
			hostname => 'Studio',
			digest => 'digest-9',
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
}
{
	%subs::archive_manifest_memo = ();
	local *subs::archive_manifest_fetch = sub { die "the next search must not fetch\n" };
	my $answer = subs::archive_manifest_cached({ remote_uuid => 'peer-9', location => 'music' });
	is($answer->{'cached'}, 1, 'the next search answers locally');
}

# ---- the wiring ------------------------------------------------------------

my $tasks = subs::minion_task_list();
ok($tasks->{'archive_manifest_refresh'}, 'the background check is a registered queue job');
is($tasks->{'archive_manifest_refresh'}, \&subs::archive_manifest_refresh_job,
	'and it points at the revalidation job');

my $root = root();
my $folders2 = read_file("$root/lib/JawnOS/Controller/manager_folders2.pm");
like($folders2, qr/archive_manifest_listing_digest\(\$dest->\{'folder'\}\)/, 'the manifest route fingerprints the drive and its media');
like($folders2, qr/unchanged => 1/, 'and answers an unchanged digest without the rows');
like($folders2, qr/defined \$known && length \$known/, 'only a caller that sent a digest can be answered unchanged');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/archive_manifest_listing_digest/, 'the loader maps the listing fingerprint');
like($loader, qr/archive_manifest_refresh_job/, 'and the revalidation job');

done_testing();
