# tests-for: lib/JawnOS/Domain/Sound.pm lib/JawnOS/Domain/Silence.pm lib/JawnOS/Domain/Loader.pm templates/apps/sound.html.ep public/js/manager/sound/03_apps.js perl/help/topics_apps.pl
# covers:    The Apps pill lists only apps with a window open on this machine.
#            A desktop tab's layout snapshot lives on its websockets row; a row
#            counts only while it is a stayingAlive heartbeat inside the
#            manager's 60s liveness window, so a stale beat, a retired 'closed'
#            row, another machine's row and a bare non-window key are all
#            absent. An app with a live window keeps its profile level (or reads
#            passive when it has none), and no live snapshot is an empty list.
#            The list containers are bounded and keyboard reachable, and the
#            help topic says the list follows open windows and scrolls.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JSON::PP ();
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = JawnOSTest::root();
my $now = &subs::rightNow();
my $host = &subs::machine_hostname();
my $seq = 0;

# The sandbox is a throwaway snapshot that may carry rows from the factory
# seed or the live house; this test asserts exact lists, so start clean.
&subs::db_query('delete from websockets');
&subs::db_query("delete from settings where setting in ('sound_profile','silence')");

sub window_row {
	my (%row) = @_;
	$seq++;
	&subs::db_insert('websockets', {
		uuid => 'open-window-' . $$ . '-' . $seq,
		app => 'tab',
		browser_tab_id => 'open-window-tab-' . $$,
		type => 'stayingAlive',
		hostname => $host,
		server_time => $now,
		connected => $now,
		%row,
	});
	return 'open-window-' . $$ . '-' . $seq;
}

&subs::db_insert('settings', {
	app => 'Music',
	setting => 'sound_profile',
	value => 'quiet',
	device => 'all',
	timestamp => $now,
	server_time => $now,
	uuid => 'open-window-profile-' . $$,
});

my $windows = sub {
	return JSON::PP::encode_json({ map { $_ => { type => 'window', app => $_ } } @_ });
};

# Music and Studio are open on this machine; the snapshot also carries the
# tab's own bookkeeping keys, which are not apps.
&window_row(
	windows => JSON::PP::encode_json({
		Music => { type => 'window', app => 'Music' },
		Studio => { type => 'window', app => 'Studio' },
		window_stacks => { piles => [] },
		musicData => {},
	}),
);
# A heartbeat that stopped two minutes ago is stale.
&window_row(server_time => $now - 120_000, windows => $windows->(Ghost => 1));
# A retired socket is disconnected even with a fresh server_time.
&window_row(type => 'closed', windows => $windows->(Lens => 1));
# Another machine's row is never this machine's reading.
&window_row(hostname => 'another-machine', windows => $windows->(Travel => 1));
# A live row with an empty snapshot opens no app.
&window_row(windows => '{}');

my $open = &subs::sound_open_window_apps();
is_deeply($open, [ 'Music', 'Studio' ], 'only the live local windows are open apps');

my $list = &subs::sound_apps_list();
is_deeply([ map { $_->{'name'} } @{$list} ], [ 'Music', 'Studio' ],
	'the Apps pill lists only apps with a window open');
is($list->[0]{'level'}, 'quiet', 'a listed app keeps its profile level');
is($list->[1]{'level'}, 'passive', 'an app with no profile reads as Passive');

my %listed = map { $_->{'name'} => 1 } @{$list};
ok(!$listed{'Ghost'}, 'a stale heartbeat is not an open window');
ok(!$listed{'Lens'}, 'a closed socket is not an open window');
ok(!$listed{'Travel'}, "another machine's window is not counted");
ok(!$listed{'window_stacks'} && !$listed{'musicData'},
	"the tab's own bookkeeping keys are not apps");

# No live snapshot at all is the empty list, not the whole catalogue.
&subs::db_query('delete from websockets');
is_deeply(&subs::sound_open_window_apps(), [], 'no live rows means no open apps');
is_deeply(&subs::sound_apps_list(), [], 'and the Apps pill is empty, not the catalogue');

# ---------------------------------------------------------------- the scroll and the words

my $template = read_file("$root/templates/apps/sound.html.ep");
like($template,
	qr/#sound \.sound_apps_rows \{[^}]*max-height:[^}]*overflow-y:\s*auto/s,
	'the app and stream lists are height bounded and scroll');
like($template,
	qr{id="sound_apps_apps" class="sound_apps_rows" tabindex="0" aria-label="[^"]+"},
	'the app list is a labelled keyboard scroll area');
like($template,
	qr{id="sound_apps_playback" class="sound_apps_rows" tabindex="0" aria-label="[^"]+"},
	'the playback list is a labelled keyboard scroll area');
like($template,
	qr{id="sound_apps_recording" class="sound_apps_rows" tabindex="0" aria-label="[^"]+"},
	'the recording list is a labelled keyboard scroll area');
unlike($template, qr{id="sound_apps_channels"[^>]*tabindex},
	'the house-channel list above is left alone');

my $js = read_file("$root/public/js/manager/sound/03_apps.js");
like($js, qr/No apps have a window open on this machine/,
	'the empty state names the open-window rule');

my $help = read_file("$root/perl/help/topics_apps.pl");
like($help, qr/window open on this machine/i, 'the help topic states the open-window rule');
like($help, qr/lists scroll when there are more rows than fit/i, 'and that the lists scroll');

my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Sound' for qw\([^)]*\bsound_open_window_apps\b/,
	'the open-window reader is mapped in the loader');

done_testing();
