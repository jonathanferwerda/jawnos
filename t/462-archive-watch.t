# tests-for: lib/JawnOS/Domain/Archive.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Process.pm perl/jobs.pl perl/President.pl lib/JawnOS/Controller/manager_folders2.pm scripts/jawnos_deps.pl
# covers:    The archive machine watches its drive with inotifywait and turns a
#            real change into the same drift check the hourly poll uses. A push
#            in progress is deferred, so its own files do not look external.

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

package FakeMinion;
sub new { bless { jobs => $_[1] || [] }, $_[0] }
sub backend { $_[0] }
sub list_jobs { return { jobs => $_[0]->{'jobs'} } }

package main;

subs::preload($_) for qw(
	archive_watch_location archive_watch_event archive_receive_note
	archive_receive_recent archive_watch_busy archive_watch_check
	archive_location_folder archive_root archive_manifest_poll
	cache_get cache_set device_setter setting_grabber minion_grabber
	machine_name signatorial_designer remote_machine_lister
	subprocessor_warranty_for subprocessor_heartbeat_for
);

my $tmp = tempdir(CLEANUP => 1);
my $root = "$tmp/archive";
make_path("$root/Music/Album", "$root/Videos");

local $subs::device = 'computer';
local $subs::config = { archive_dir => $root };
local *subs::setting_grabber = sub { return undef };
local *subs::machine_name = sub { return 'Archive' };
local *subs::signatorial_designer = sub { return 'archivesig' };
local *subs::remote_machine_lister = sub { return [] };

# ---- which location an event belongs to ------------------------------------

is(subs::archive_watch_location({ root => $root, path => "$root/Music/Album/a.mp3" }), 'music',
	'a file under Music is a music change');
is(subs::archive_watch_location({ root => $root, path => "$root/Videos/clip.mp4" }), 'video',
	'a file under Videos is a video change');
is(subs::archive_watch_location({ root => $root, path => "$root/Music" }), 'music',
	'the location folder itself is a music change');
is(subs::archive_watch_location({ root => $root, path => "$root/Loose/thing.mp3" }), undef,
	'a path under no location is not a change');

is(subs::archive_watch_event({ root => $root, path => "$root/Music/manifest.json" }), undef,
	'the compacted manifest is not media');
is(subs::archive_watch_event({ root => $root, path => "$root/Music/manifest.jsonl" }), undef,
	'the journal is not media');
is(subs::archive_watch_event({ root => $root, path => "$root/Music/manifest.json.tmp" }), undef,
	'a manifest rewrite temp is not media');
is(subs::archive_watch_event({ root => $root, path => "$root/Music/a.mp3.part" }), undef,
	'a transfer partial is not media');
is(subs::archive_watch_event({ root => $root, path => "$root/Music/a.mp3.part.json" }), undef,
	'a partial sidecar is not media');
is(subs::archive_watch_event({ root => $root, path => "$root/Music/Album/a.mp3" }), 'music',
	'a media file is a music change');

# ---- a push in progress ----------------------------------------------------

ok(subs::archive_receive_note({ location => 'music' }), 'the receive route notes a push');
ok(subs::archive_receive_recent({ location => 'music' }), 'and the note is recent');
is(subs::archive_receive_recent({ location => 'photo' }), 0, 'a location with no note is not receiving');
subs::cache_set({
	app => 'archive', context => 'receive', subcontext => sha256_hex('receive|video'), warranty => '100y'
}, { at => subs::rightNow() - 20 * 60 * 1000, location => 'video' });
is(subs::archive_receive_recent({ location => 'video' }), 0, 'an old note is not a push in progress');

# An active transfer or rescan for this location defers the watch.
{
	my $minion = FakeMinion->new([
		{ state => 'active', task => 'archive_transfer', args => [ { location => 'video' } ] },
	]);
	local *subs::minion_grabber = sub { return $minion };
	ok(subs::archive_watch_busy({ location => 'video' }), 'a transfer writing this location defers the watch');
	is(subs::archive_watch_busy({ location => 'photo' }), 0, 'a transfer to another location does not');
}
{
	my $minion = FakeMinion->new([
		{ state => 'finished', task => 'archive_transfer', args => [ { location => 'video' } ] },
	]);
	local *subs::minion_grabber = sub { return $minion };
	is(subs::archive_watch_busy({ location => 'video' }), 0, 'a finished transfer does not defer the watch');
}
{
	my $minion = FakeMinion->new([
		{ state => 'inactive', task => 'archive_manifest_rescan', args => [ { location => 'video' } ] },
	]);
	local *subs::minion_grabber = sub { return $minion };
	ok(subs::archive_watch_busy({ location => 'video' }), 'a queued rescan defers the watch');
}

# ---- the watch's turn ------------------------------------------------------

{
	my $polled;
	local *subs::archive_manifest_poll = sub { $polled = $_[0]; return {} };
	$subs::archive_manifest_media_memo{"$root/Music"} = { at => subs::rightNow(), digest => 'old' };
	my $ok = subs::archive_watch_check({ location => 'music', root => $root });
	is($ok, 1, 'the watch checks an existing location');
	ok(!exists $subs::archive_manifest_media_memo{"$root/Music"},
		'and does not answer from a sweep that ran before the event');
	is($polled->{'folder'}, "$root/Music", 'with the location folder');
	is($polled->{'location'}, 'music', 'and the location');
	my $gone = subs::archive_watch_check({ location => 'photo', root => $root });
	is($gone, 0, 'a location folder that is not there is not checked');
}

# ---- the wiring ------------------------------------------------------------

my $jobs = read_file(root() . '/perl/jobs.pl');
like($jobs, qr/^sub job_archive_watch\b/m, 'the watch job exists');
like($jobs, qr/inotifywait/, 'it uses inotifywait');
like($jobs, qr/'archive watch' => \\&job_archive_watch/, 'and is registered by name for a box without fork');
like($jobs, qr/archive_watch_busy/, 'it defers while a push is writing');
like($jobs, qr/archive_watch_check/, 'and asks the drift question');

my $pres = read_file(root() . '/perl/President.pl');
like($pres, qr/name => 'archive watch', fork => 1/, 'President starts the watch as a real child');

my $folders = read_file(root() . '/lib/JawnOS/Controller/manager_folders2.pm');
like($folders, qr/archive_receive_note/, 'the receive and append routes note their activity');

my $deps = read_file(root() . '/scripts/jawnos_deps.pl');
like($deps, qr/inotifywait/, 'the dependency check knows inotifywait');
my $docker = read_file(root() . '/Dockerfile');
like($docker, qr/inotify-tools/, 'and the Docker image installs it');

is(subs::subprocessor_warranty_for('archive watch'), 'forever', 'the watch has a warranty');
is(subs::subprocessor_heartbeat_for('archive watch'), '15m', 'and a heartbeat lease');

my $loader = read_file(root() . '/lib/JawnOS/Domain/Loader.pm');
like($loader, qr/archive_watch_check/, 'the loader maps the watch helpers');

done_testing();
