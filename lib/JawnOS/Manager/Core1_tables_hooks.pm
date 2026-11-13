package Manager;

# Manager boot, part 1 of 2. The eager segment of the old Manager.pm: the app's
# own tables, the load-time hooks and the asset bundle lists. Manager.pm requires
# this at the exact point the code used to sit, so load order and eagerness are
# unchanged. The package is still Manager; the lazily loaded helpers and their
# docs stay in lib/JawnOS/Manager/Part*.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
# File-scoped pragmas do not cross a require: repeat the ones the original
# file had in force at this point, so diagnostics are unchanged.
no warnings 'uninitialized';
no warnings 'once';
# Globals declared by the index (Manager.pm) and read below.
use vars qw($database);
# This file ends on the %folders_desk_not_app assignment, whose non-empty
# map is a true value: require accepts it without an added 1; terminator.

# The apps whose own padlock is a media padlock (per screen, per window).
our @media_unlock_apps = qw/gallery music folders/;

# The content tables the guide may search by name, beyond the appointments log.
# Only tables that hold the person's own words: the settings, credentials,
# device and cache tables are deliberately left out, so a secret cannot ride out
# to a model on a search.
our %help_search_tables = (
	notes           => [qw/text/],
	mailbox         => [qw/subject/],
	magazine        => [qw/title teaser/],
	model           => [qw/name description manufacturer/],
	option          => [qw/name description manufacturer/],
	subcategory     => [qw/name description manufacturer/],
	option_category => [qw/name/],
);

# The MIME an <audio>/<video> element can open, from the extension first (an
# mp4 can be either) and the sniffer's verdict second. /play and /file_open
# used to hand the data to render_file() without a type, and that helper
# answers "application/x-download" with "Content-Disposition: attachment".
# Desktop Chrome sniffs past that; Android's media stack does not - it refused
# the track outright. Only audio/video are listed here: everything else keeps
# the download disposition it had.
our %media_type_for_ext = (
	mp3 => 'audio/mpeg', m4a => 'audio/mp4', aac => 'audio/aac',
	wav => 'audio/wav', flac => 'audio/flac', oga => 'audio/ogg',
	ogg => 'audio/ogg', opus => 'audio/ogg',
	mp4 => 'video/mp4', m4v => 'video/mp4', mkv => 'video/x-matroska',
	webm => 'video/webm', mov => 'video/quicktime',
	wmv => 'video/x-ms-wmv', avi => 'video/x-msvideo',
	mpg => 'video/mpeg', mpeg => 'video/mpeg',
);

our %file_relay_down;

our (@appointments,@results);

# The families a printed tender may name. A receipt that says "credit" can name a
# mastercard account, and "interac" a debit one, so a family with ONE account in
# it is enough to pick that account; an ambiguous family is left for the person.
our %market_payment_family = (
	cash => [ qw(cash) ],
	debit => [ qw(debit interac maestro) ],
	credit => [ qw(credit visa mastercard amex discover) ],
	crypto => [ qw(crypto bitcoin ethereum btc eth) ],
	cheque => [ qw(cheque check) ],
	gift => [ qw(gift) ],
);

app->hook(before_dispatch => sub {
	my ($c) = @_;
	$c->session(expiration => 604800);
	# visibility and presence are read many times in one request; the caches
	# must not outlive it (a worker serves many people over its life)
	&subs::visibility_cache_clear();
});

app->hook(before_render => sub {
	$database = '';
});

# Static files (icons, css, js) get an ETag/Last-Modified but no Cache-Control,
# so browsers cached them heuristically and kept showing stale icons. Scripts and
# styles still force a revalidation on every request: an unchanged file answers
# 304, a changed one a fresh 200, and the bundle rebuilds from their mtimes. A
# STABLE ?string= is what lets the 304 happen - a random buster made every load a
# fresh URL and a full re-download. Icons, template pictures and cursors carry no
# such stamp and a window draws about fifty of them, so they take a short max-age
# instead (the policy lives in subs::static_cache_control): opening a window no
# longer pays a round trip per icon, and a replaced file shows on the next page.
app->hook(after_static => sub {
	my ($c) = @_;
	$c->res->headers->cache_control(&subs::static_cache_control($c->req->url->path));
});

# The manager view used to open ~44 separate <script> tags, a request each over
# HTTP/1.1. They are concatenated here in the order the layout wants and the
# result is memoised until a file changes (an mtime+size signature recomputed
# per request; the concat is redone only on a change). The individual files stay
# the source of truth - nothing is generated on disk. With a stable ?string= and
# the ETag below a repeat load revalidates to a 304, while a changed file (or a
# version bump) is served at once.
#
# An entry may name an app that grew: foo.js stays as the index (its first
# segment) and the rest live in foo/ in numeric name order. The route expands
# that folder through subs::js_part_files, so a split needs no change here; the
# list only says where each app starts in the concatenation.
our @manager_bundle_files = qw(
	/js/manager/lazy.js
	/js/manager/stored.js
	/js/manager/game_session.js
	/js/manager/keyboard.js
	/js/manager/remote_input.js
	/js/manager/text_editor_variables.js
	/js/manager/texture.js
	/js/manager/clothesline.js
	/js/manager/dialog.js
	/js/manager/manager.js
	/js/manager/mapengine.js
	/js/manager/mapmarkers.js
	/js/manager/artwork.js
	/js/music.js
	/js/images.js
	/js/manager/configure.js
	/js/manager/windows.js
	/js/manager/editor.js
	/js/manager/ide.js
	/js/manager/ide_code.js
	/js/mailbox.js
	/js/manager/email.js
	/js/manager/soft_keyboard.js
	/js/manager/chat.js
	/js/manager/junderground.js
	/js/manager/pen.js
	/js/manager/clockfaceprinter.js
	/js/manager/leaderboardprinter.js
	/js/manager/calendarprinter.js
	/js/manager/continentprinter.js
	/js/manager/timelineprinter.js
	/js/manager/backgroundprinter.js
	/js/manager/taskbar.js
	/js/manager/taskbar_edit.js
	/js/manager/taskbar_panel.js
	/js/manager/notifications_toast.js
	/js/manager/taskbar_power.js
	/js/manager/taskbar_network.js
	/js/manager/taskbar_sound.js
	/js/manager/taskbar_notifications.js
	/js/manager/shell_layout.js
	/js/manager/narratorprinter.js
	/js/manager/marker.js
	/js/pm.js
	/js/manager/terminal.js
	/js/manager/network.js
	/js/manager/budget_light.js
	/js/manager/budget.js
	/js/manager/embedded.js
	/js/manager/controllers.js
	/js/manager/travel.js
	/js/manager/studio.js
	/js/manager/synth_presets.js
	/js/manager/synth.js
	/js/manager/attributes.js
	/js/manager/inventory.js
	/js/manager/security.js
	/js/device.js
	/js/manager/tasks.js
	/js/store.js
	/js/manager/twirl.js
	/js/manager/transaction.js
	/js/manager/time_preview.js
	/js/manager/relational.js
	/js/manager/warehouse.js
	/js/manager/market.js
	/js/manager/measures.js
	/js/manager/monitor.js
	/js/manager/power.js
	/js/manager/sound.js
	/js/manager/silence.js
	/js/manager/folders.js
	/js/manager/desk.js
	/js/manager/notes.js
	/js/manager/notifications.js
	/js/manager/weather.js
	/js/manager/weather_history.js
	/js/manager/weather_automation.js
	/js/manager/weather_map.js
	/js/manager/weather_sources.js
	/js/manager/clock.js
	/js/manager/help.js
	/js/manager/page_agent.js
	/js/manager/coding.js
	/js/manager/agents.js
	/js/manager/camera.js
	/js/manager/scan.js
	/js/manager/internet.js
	/js/manager/search.js
	/js/manager/screening.js
	/js/manager/phone.js
	/js/manager/people.js
);

# Apps that load their scripts when they are first opened. The value is the
# bundle order, so a chunk runs its files exactly as the one big bundle did;
# entries shared by two apps (the synth in Studio, the travel markers) are kept
# in one list and the loader executes each file only once. A file named here is
# removed from the core bundle; anything not named stays core.
our %manager_app_scripts = (
	synth           => [qw(/js/manager/synth_presets.js /js/manager/synth.js)],
	studio          => [qw(/js/manager/studio.js /js/manager/synth_presets.js /js/manager/synth.js)],
	marker          => [qw(/js/manager/marker.js)],
	terminal        => [qw(/js/manager/terminal.js)],
	travel          => [qw(/js/manager/travel.js)],
	twirl           => [qw(/js/manager/twirl.js)],
	editor          => [qw(/js/manager/editor.js)],
	relational      => [qw(/js/manager/relational.js)],
	warehouse       => [qw(/js/manager/warehouse.js)],
	market          => [qw(/js/manager/market.js)],
	measures        => [qw(/js/manager/measures.js)],
	budget          => [qw(/js/manager/budget.js)],
	process_monitor => [qw(/js/manager/monitor.js)],
	camera          => [qw(/js/manager/camera.js)],
	scan            => [qw(/js/manager/scan.js)],
	network         => [qw(/js/manager/network.js)],
	phone           => [qw(/js/manager/phone.js)],
	people          => [qw(/js/manager/people.js)],
	notes           => [qw(/js/manager/notes.js)],
	notifications   => [qw(/js/manager/notifications.js)],
	weather          => [qw(/js/manager/weather.js /js/manager/weather_history.js /js/manager/weather_automation.js /js/manager/weather_map.js /js/manager/weather_sources.js)],
	power            => [qw(/js/manager/power.js)],
	sound            => [qw(/js/manager/sound.js)],
	search          => [qw(/js/manager/search.js)],
	ide             => [qw(/js/manager/ide.js /js/manager/ide_code.js)],
	store           => [qw(/js/store.js)],
	email           => [qw(/js/manager/email.js)],
);

# The entry functions core code may call before the app's own script is there
# (the Handbook's Today cards, the People crest opening Relational). lazy.js
# installs a stub for each and the real definition replaces it when the chunk
# loads. Keep this beside the map so a new lazy app is one edit, not two.
our %manager_app_entry = (
	synth           => [qw(pianoInit)],
	studio          => [qw(studioInit)],
	marker          => [qw(markerInit)],
	terminal        => [qw(terminalOpener)],
	travel          => [qw(travelViewer)],
	twirl           => [qw(twirlGame)],
	editor          => [qw(editorInit)],
	relational      => [qw(relationalInit relationalOpener)],
	warehouse       => [qw(warehouseInitializer)],
	market          => [qw(marketOpener)],
	measures        => [qw(measuresOpener)],
	budget          => [qw(budgetInit)],
	process_monitor => [qw(monitorOpener)],
	people          => [qw(peopleOpener)],
	ide             => [qw(ideTabPopulator)],
	store           => [qw(storeOpener)],
	email           => [qw(emailReaderOpen emailReaderClose)],
	weather         => [qw(weatherMaker)],
	power           => [qw(powerOpener)],
	sound            => [qw(soundOpener)],
	scan            => [qw(scanOpener)],
);

# The start-menu icons are drawn by the server, but each app used to register
# its own click handler inside its script. The first click therefore has to be
# caught in core, the chunk loaded, and the click replayed so the app's own
# handler (or the core Handbook handler for Marker/Terminal/Twirl) runs. The
# key is the element's id or a class name; lazy.js checks both.
our %manager_toggle_apps = (
	synth_toggle => 'synth', studio_toggle => 'studio', marker_toggle => 'marker',
	terminal_toggle => 'terminal', travel_toggle => 'travel', twirl_toggle => 'twirl',
	editor_toggle => 'editor', relational_toggle => 'relational', people_toggle => 'people',
	notes_toggle => 'notes', notifications_toggle => 'notifications', search_app_toggle => 'search', camera_toggle => 'camera', scan_toggle => 'scan',
	network_toggle => 'network', phone_toggle => 'phone', ide_toggle => 'ide',
	budget => 'budget', warehouse_toggle => 'warehouse', measures_toggle => 'measures',
	market_toggle => 'market', process_monitor_toggle => 'process_monitor',
	store_toggle => 'store', email_toggle => 'email',
	weather_toggle => 'weather',
	power_toggle => 'power',
	sound_toggle => 'sound',
);

# The one bundle the page loads up front: everything an app chunk names is gone
# from it. A file added to the list above but not to any app stays core, so a
# mistake costs bytes rather than a broken app.
our @manager_core_files = do {
	my %lazy = map { $_ => 1 } map { @{$_} } values %manager_app_scripts;
	grep { !$lazy{$_} } @manager_bundle_files;
};

our $manager_bundle_cache;

# Minify the concatenation on the way out, so the readable files under public/js
# stay the source of truth for a person (or an agent) while the browser gets one
# small script. terser -c only: it strips whitespace and comments and folds
# constants, but never renames - the manager leans on names (HTML attributes call
# globals directly, and a few places hand eval() a string). If no minifier is
# found the plain concatenation is served, so this degrades to correct-but-bigger
# rather than broken. Point JAWN_JS_MINIFIER at another terser to override.
our $js_minifier;

# ---------------------------------------------------------------------------
# App releases (the APK). scripts/app_release.pl stages a built APK into
# <repo>/releases (gitignored); every machine replicates it as a blob, not
# through git history. A peer asks what a machine holds, then fetches one - the
# app half of "whoever has the newest is the authority".
# ---------------------------------------------------------------------------
our %app_release_sha;

# Released by the guard in remote_upgrade on every exit, including a die, so a
# pull that crashes part-way no longer leaves a live-looking 'running' marker
# behind. The age/pid check still covers a worker the kernel killed.
{
	package Jawn::RemoteUpgradeLock;
	sub new { my ($class, $val) = @_; return bless { val => $val }, $class; }
	sub release {
		my $self = shift;
		return unless $self->{'val'};
		my $val = $self->{'val'};
		$self->{'val'} = undef;
		eval {
			my $row = &subs::db_query('select value from settings where app = ? and setting = ? order by cast(server_time as integer) desc limit 1', '__president', 'remote_upgrade')->hashes->[0];
			&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' }) if (($row->{'value'} || '') eq $val);
		};
	}
	sub DESTROY { shift->release }
}

# Apps that are not launchable from the app menu: citizen kinds and the
# handbook's older alias. They must not be offered as desk shortcuts.
our %folders_desk_not_app = map { $_ => 1 } qw(citizen resident guest blacklisted library);
