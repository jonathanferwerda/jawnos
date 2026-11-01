#!/usr/bin/env perl
package Manager;
use strict;
use warnings ;#'uninitialized';


use Mojo::Base 'Mojolicious::Controller';
use utf8;
use feature 'signatures';

# The old `app` was Mojolicious::Lite's accessor for the one application object.
# Manager.pm is now loaded by JawnOS::startup, which publishes the app here
# before the require, so every `app->...` below still means the same thing.
our $APP;
sub app { return $APP }
# The helpers live in lib/JawnOS/Manager/Part*.pm, one require on first call. Every
# name is forward-declared (Manager/Declarations.pm), so this file and the
# controllers compile normally and a call resolves here instead of dying. This is
# registered before the init code below runs, because that code calls helpers.
require 'JawnOS/Manager/Declarations.pm';
require JawnOS::Manager::Index;
our $AUTOLOAD;
our %IN_AUTOLOAD;
sub AUTOLOAD {
	return if $AUTOLOAD eq 'Manager::DESTROY';
	my $name = $AUTOLOAD;
	my ($short) = $name =~ /([^:]+)$/;
	my $part = $JawnOS::Manager::Index::SUB{$short}
		or die "Undefined subroutine &$name called\n";
	# A part that loads without defining the sub leaves the forward-declared
	# stub in place; calling it re-enters here, and that second entry is the
	# one that reports it. (A coderef comparison cannot tell: the glob's CV
	# slot is reused, so \&name is the same ref before and after the load.)
	die "Undefined subroutine &$name called ($part does not define it)\n"
		if $IN_AUTOLOAD{$short};
	unless ($JawnOS::Manager::Index::LOADED{$part}) {
		$JawnOS::Manager::Index::LOADED{$part} = 1;
		require $part;
	}
	local $IN_AUTOLOAD{$short} = 1;
	no strict 'refs';
	goto &{$name};
}

use Mojo::Promise;
use Mojo::UserAgent;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Clone qw(clone);
use feature 'signatures';

use Mojolicious::Static;
use Mojo::Log;
use Mojo::Transaction::WebSocket;
use Mojo::Parameters;
use Mojo::DOM;
use Mojo::URL;

use Mojo::JSON qw(decode_json encode_json);
use URI::Encode qw(uri_encode uri_decode);
use List::Util qw(shuffle);
app->plugin('RenderFile');

# A websocket beat refreshes its row's liveness column on a slow cadence (the
# row itself is written only when something changed), so "still here" is judged
# over a window wide enough to cover a missed refresh rather than the old
# every-two-seconds beat. Rows are still deleted the moment a socket closes.
our $ws_live_window = 60000;

use Data::Dumper;
use Mojo::Util qw/md5_sum html_unescape xml_escape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use File::Find;
use File::Slurp;
use File::Type;
use File::Copy;
use POSIX ();
use Fcntl qw(:flock O_CREAT O_EXCL O_WRONLY);
use Number::Format qw/:subs/;
use SQL::Abstract;
use Mojo::SQLite;
use Mojo::IOLoop;
use Mojo::IOLoop::ReadWriteFork;
use Mojolicious::Sessions;
use Mojo::Server::Daemon;
use Mojolicious::Renderer;
use Crypt::Simple;
use CryptX;
use HTML::Strip;
use HTML::Parser;
use Data::UUID;
use Storable;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use MIME::Base64;
# The mail stack is loaded on demand (see subroutines.pl): heavy, and used by two
# routines only, so a worker that never handles mail should not pay for it.
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
our $encoder = Sereal::Encoder->new({ compress => SRL_ZSTD, compress_level => 3 });
our $decoder = Sereal::Decoder->new();
use Minion;
use IO::Socket::UNIX;
use IPC::Open2 qw(open2);
no warnings 'uninitialized';
no warnings 'once';
require "./perl/Websocket.pl";
require "./perl/subroutines.pl";
require "./perl/junderground.pl";
require "./perl/AddressDirectory.pl";
require "./perl/remote_input.pl";
require "./perl/tls.pl";
require "./perl/webauthn.pl";
require "./perl/Music.pl";
require "./perl/hooks.pl";
require "./perl/tunnel.pl";
require "./perl/help.pl";
require "./perl/crew.pl";
require "./perl/printers.pl";

# The domain layer owns these now (domain.pl, package subs). The forward
# declarations are for the parser (and for any call spelled without parens);
# the glob aliases keep this file, the templates and the Music/Alarm callers
# working through the old Manager:: name, while subroutines.pl calls the
# subs:: name directly and no longer needs this file for them.
sub ocr_reader;
sub misc_setting_list;
sub remote_useragent_maker;
sub deletion_registration;
sub notification_sender;
sub embedded_toggle;
sub migration_already_applied;
sub guide_resolve_when;

*Manager::ocr_reader = sub { &subs::ocr_reader(@_) };
*Manager::misc_setting_list = sub { &subs::misc_setting_list(@_) };
*Manager::remote_useragent_maker = sub { &subs::remote_useragent_maker(@_) };
*Manager::deletion_registration = sub { &subs::deletion_registration(@_) };
*Manager::notification_sender = sub { &subs::notification_sender(@_) };
*Manager::embedded_toggle = sub { &subs::embedded_toggle(@_) };
*Manager::migration_already_applied = sub { &subs::migration_already_applied(@_) };
*Manager::guide_resolve_when = sub { &subs::guide_resolve_when(@_) };

# Second slice of the same move (guide aliases, budget, log reader, leave,
# database migrations, relay and coding path). Same contract as above.
sub leave;
sub original_timestamp;
sub appts_marker_builder;
sub log_reader;
sub remote_relay_request;
sub appointment_overlap;
sub father_time;
sub measure_calc_for;
sub budget_calculator;
sub budget_status_maker;
sub people_index;
sub people_chips;
sub help_app_hidden;
sub guide_name_normalize;
sub guide_name_distance;
sub guide_target_label;
sub guide_aliases_read;
sub guide_aliases_write;
sub guide_aka_read;
sub guide_alias_add;
sub guide_alias_remove;
sub guide_resolve_target;
sub guide_resolve_action;
sub guide_ask_candidates;
sub coding_repo;
sub coding_path;
sub update_database;

*Manager::leave = sub { &subs::leave(@_) };
*Manager::original_timestamp = sub { &subs::original_timestamp(@_) };
*Manager::appts_marker_builder = sub { &subs::appts_marker_builder(@_) };
*Manager::log_reader = sub { &subs::log_reader(@_) };
*Manager::remote_relay_request = sub { &subs::remote_relay_request(@_) };
*Manager::appointment_overlap = sub { &subs::appointment_overlap(@_) };
*Manager::father_time = sub { &subs::father_time(@_) };
*Manager::measure_calc_for = sub { &subs::measure_calc_for(@_) };
*Manager::budget_calculator = sub { &subs::budget_calculator(@_) };
*Manager::budget_status_maker = sub { &subs::budget_status_maker(@_) };
*Manager::people_index = sub { &subs::people_index(@_) };
*Manager::people_chips = sub { &subs::people_chips(@_) };
*Manager::help_app_hidden = sub { &subs::help_app_hidden(@_) };
*Manager::guide_name_normalize = sub { &subs::guide_name_normalize(@_) };
*Manager::guide_name_distance = sub { &subs::guide_name_distance(@_) };
*Manager::guide_target_label = sub { &subs::guide_target_label(@_) };
*Manager::guide_aliases_read = sub { &subs::guide_aliases_read(@_) };
*Manager::guide_aliases_write = sub { &subs::guide_aliases_write(@_) };
*Manager::guide_aka_read = sub { &subs::guide_aka_read(@_) };
*Manager::guide_alias_add = sub { &subs::guide_alias_add(@_) };
*Manager::guide_alias_remove = sub { &subs::guide_alias_remove(@_) };
*Manager::guide_resolve_target = sub { &subs::guide_resolve_target(@_) };
*Manager::guide_resolve_action = sub { &subs::guide_resolve_action(@_) };
*Manager::guide_ask_candidates = sub { &subs::guide_ask_candidates(@_) };
*Manager::coding_repo = sub { &subs::coding_repo(@_) };
*Manager::coding_path = sub { &subs::coding_path(@_) };
*Manager::update_database = sub { &subs::update_database(@_) };
{ package gb; }

# Run the schema migrations once per worker when the app comes up: a git pull
# (which the watcher follows with a restart) then lands its new schema on boot
# instead of waiting for a login. update_database is idempotent
# (migration_already_applied), so a restart with no schema change is cheap.
app->hook(before_dispatch => sub {
	unless ($Manager::schema_checked) {
		$Manager::schema_checked = 1;
		# one machine, one database: leftovers from older databases (server.enc,
		# laptop_*.enc, a stray .db) are discarded here, once per worker at boot
		eval { &subs::database_tidy(); };
		eval { &update_database({}); };
	}
});

our $tuuid    = Data::UUID->new;
our $thread_uuid = $tuuid->create_str();
our $universal_splitter = $gb::universal_splitter;
our $database;
our $sql;
our $remote_input_clipboard;
our $config_file = read_file('./config.json');
our $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
&remote_input::set_log($log);
our $environment = $config->{'environment'};
our $random_caching_string = &subs::jawn_version();
our $duty_file = &subs::home('~/.president/on_duty');
write_file($duty_file, &subs::rightNow());
$gb::database_holder->{'last_restart'} = &subs::rightNow();

our $main_process = $$;
our $device = &subs::device_setter();
our $user_agent = $gb::user_agent;

if ($device eq 'mobile' && !&subs::sshd_running()) {
	# The command that used to live here was a bare `sshd`, which starts with no
	# usable host key on Android and (worse) made this guard skip the properly
	# configured daemon below. subs::sshd_start names the prefix's keys and an
	# absolute AuthorizedKeysFile.
	&subs::sshd_start();
}

# A pull interrupted by an app update or a tree restart leaves the
# `remote_upgrade` marker behind; peers then hear "merging" and skip this
# machine's newer rows until the age bound expires (the phone hid six rows this
# way, 2026-10-31). Drop a marker no live process owns as the tree comes up.
if ($device eq 'mobile') {
	my $up = &subs::remote_upgrade_lock_state();
	&subs::setting_setter({ app => '__president', setting => 'remote_upgrade', value => '' })
		if &subs::remote_upgrade_marker_reapable($up);
}

# A record press may name its source (the media group's video/audio/screen
# buttons do). Only the sources this build can actually run are accepted; an
# empty or unknown value falls back to the app's own setting.





# What the guide made of a phrase the time machine could not read; cached per
# phrase so a typed word the poll re-sends every cycle costs one model call, not
# one per poll. A phrase mapped to undef is one the guide could not read either.
our %time_machine_guide_cache;

# The time machine's phrase turned into a moment. A written date and a recognized
# relative offset are read by subs::resolve_when / ago_calc; anything else - a
# phrase neither can read, or one that lands exactly on the epoch without naming
# it - is handed to the guide to interpret, and the view travels where it says.


# A warranty is a moment ahead of the record: the same reader as the time
# machine, but a bare length ("2 years", "-2y") runs forward rather than back.

# A duration in milliseconds, from the compact form ("5m", "1h 30m") or the
# words ("five minutes", "an hour and a half"). Always a positive length; the
# caller applies the start/record accrual sign.



# A staged appointment's time, read the same way the time machine reads a typed
# time. A value already in milliseconds passes straight through; anything else
# ("in 20 minutes", "jul 16", "next friday") is resolved by the one resolver the
# clock uses, guide fallback and all, so a create lands where it says.

# A length the person gave ("5 minutes", "lasts 2h") as the tree stores it. Read
# here rather than through time_abbrev_translator: that parser reads a compact unit
# ("5m", "1h") but treats a number followed by a spelled-out word as a bare number -
# minutes - so a model's "90 seconds" arrived as ninety minutes and "1 hour" as one
# minute. A model writes words, so both forms are read here, and a phrase may name
# several parts ("1 hour 30 minutes").

# The words worth searching a phrase for: its nouns, with the small connective
# words dropped, so "the last time I had a beer" searches for "beer".

# A one-line report of a help_search, for a prompt.

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

# One search over the person's records: the appointments that match (by app, file
# or notes), the files they carry, the first, newest and next such moments, and
# any named thing in the content tables. This is the read behind the guide's find
# action and the time machine's own fallback.

# A person's birthday. "<name>'s [next|last] [Nth] birthday" (and "when is/was
# <name>'s birthday") names the annual occasion: the plain form is the next one to
# come, "was"/"last" the last one that passed, and the Nth the year they turn N -
# all counted here from the saved birthday (Configure -> App -> Birthdays). "when
# was <name> born" and "the day <name> was born" name the actual date. Failing a
# saved birthday the guide looks the person up (it knows "Abraham Lincoln's
# birthday"). undef when the phrase is none of these or the date cannot be found,
# so the guide still runs.

# The time machine's own fallback: read a phrase neither a written date nor a
# relative offset could. The records are looked up first and handed to the guide,
# which answers with the moment it means - or, when the phrase asks the person's
# thing to be started, with an appointment it has it write (through
# appointment_writer, so alarms, budgets and any embedded relay all fire). No
# guide model on this machine leaves the phrase unread.






# The app's camera bridge (window.JawnCamera) writes its capture here, in the
# Termux home both processes share, and the page posts only the path. Base64 of
# a real phone photo was several megabytes through evaluateJavascript, which the
# WebView's binder transaction cannot carry - the camera opened and the answer
# never arrived.

# Accept only a plain file directly inside the staging directory: the page names
# the path, so a traversal or a link to somewhere else must not be followed.




# The scanimage invocation for a feed, shared by the document scanner and the
# Market receipt reader so the two never drift. $feed is 'adf' or 'flatbed'
# (case-insensitive) and must be one the scanner declares; $file is the output
# base (an ADF pages itself with --batch and a %d suffix). Undef for a feed the
# scanner does not offer, which callers read as "this scanner cannot do that".

# The page files one scanner run produced, in page order. An ADF run writes
# $base_1.tiff, $base_2.tiff, ... (the %d suffix); a flatbed run a single
# $base.tiff. mtime is not a trustworthy order for a fast feed, so a numbered
# page sorts by that number and an unnumbered page (the flatbed one) by name.









# One URL from a /manager/thumbs batch, as a data URI. Returns (src, raw size).
# Everything that is not a cheap, local, already-existing picture is left to
# /file_open: that is where thumbnail generation, archive lookup and peer relay
# live, and each has its own guard there.

# The data URI's type when the bytes themselves did not identify one. Sealed
# files end in .enc, so look at the name they were sealed from.


# The tag for a file response: path, inode, size and mtime. A reseal changes the
# ciphertext (and the tag); an unchanged file revalidates without any decryption.

# Stamp an existing tag on a response that is about to carry the file.

# Answer an unchanged file with a 304 before any bytes are read. Only called
# after authentication, so it cannot tell a stranger whether a path exists.
# Nothing is stamped unless the request really is a match, so a failed render is
# never given a tag a later request could revalidate against.

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

# A media response is inline, so a phone's player receives it as the track and
# not as a download; every other file keeps render_file's attachment default.

# Android's /sdcard is a FUSE mount. Mojolicious's render_file(filepath => ...)
# hands the path to Mojo::Asset::File, whose sendfile/seek path never returns on
# that mount: the request is left open with no headers, so the phone's <video>
# sits at readyState 0 and the music player runs through the whole queue. A
# plain read/seek on the same path works (the /play as_is path proves it), so
# stream the bytes here instead - with the one Range a media element sends.

# Pump a sealed file to the client a chunk at a time, so a large video starts
# playing after the 16 KB probe instead of after the whole file is decrypted and
# copied. Content-Length is known (the ciphertext length, which is exactly what
# the old path served for nopad), so this is a plain body, not chunked encoding.
# Only the in-process ciphers reach here; the openssl fallback and PDFs keep the
# buffered path.

# Decrypt just the head of a sealed video for ffmpeg. The first frame needs the
# header and opening clusters, not the whole file; the caller falls back to a
# full decrypt when the prefix yields nothing (an mp4 whose moov atom is last).

# Write a sealed stream's whole plaintext to a path, a chunk at a time, so a
# two-hour film never has to sit in memory as one string.

# The whole-track loudness baseline: one ffmpeg pass over the audio, measuring
# the mean and peak level. The mean is the track's own loudness; a single gain
# computed from it preserves the dynamics inside the track instead of squeezing
# dialogue and action towards each other every second.



# Answer with a cached measurement when there is one, otherwise measure the
# plaintext path and cache the result against the original file's identity.

# Making a thumbnail means decrypting the whole original and running
# ImageMagick inside the request. A gallery asks for a screenful at once, so
# every prefork worker ended up doing that (or sleeping on the per-appointment
# priority lock) and the UI's own requests waited behind them - the "web UI
# froze" reports. Only one generation runs per machine; a request that finds
# the slot taken answers at once with a placeholder, and the next view gets the
# finished thumbnail because it is stored in the appointment.


# A corrupt file or a stuck decoder used to hold the worker forever; a
# thumbnail is not worth an unanswered request.
# The app answers a thumbnail in one bridge call (M3). undef means there is no
# bridge (a desktop) or the file is not something it can draw, and the caller
# runs its ffmpeg | magick pipeline exactly as before.


our %file_relay_down;
# A remote track is streamed to the player as it arrives. The ordinary relay
# reads the whole body into a scalar and hands it to render(): a film on an
# archive drive is gigabytes, so the browser waited for the entire download,
# the manager held two copies of it, and every seek re-read the whole file.
# The peer's Range answer is passed through, so <video> can start at once and
# seek; only /play takes this path (pictures stay on the bounded relay above).










our (@appointments,@results);









# --- Market: the shopping side of the warehouse ---
# A vendor is an app whose part of speech (or second reading) is 'vendor', the way
# packaging reads the places. The shopping list is one JSON setting on the market
# app: rows of { uuid, text, kind (need|want), vendor, timestamp }.
# The registry of named lists (Grocery, Hardware, Clothing, ...) with the vendors
# each is shopped at, so a vendor's location can name the lists that apply there.
# Names come from the house's categories, so a list lines up with the budget's
# category rather than inventing a parallel scheme.
# The lists the dropdown offers: every category the house keeps, plus any list
# already in use. A category app is a list by default, so the names line up with
# the budget's categories.
# Remember that a list is shopped at a vendor, so a vendor's location names it.
# --- barcodes: look a code up once, then name it in our terms ---
# The cache is one setting: { code => { raw, item, category, unit, at } }, so a
# code is looked up and consolidated the first time and is instant after.
# A code the house already knows: an item app carrying it as its product code.
# Ask a public catalogue what a code is. Best-effort and only for a code never
# seen before: an ISBN goes to Open Library, a retail code to UPCitemdb, and a
# failure never stops the scan (the code itself is kept until it is named).
# Fold a raw retail name into our terms: a house item name, a category the house
# keeps and a unit. The model does the naming; the categories and units are ours.

# The newest GPS fix the house holds (the phone writes continent rows), or nothing.
# A vendor's own home plate, if it has one.
# The lists that apply where the house is now: a list whose vendors include one
# within the radius. At a supermarket that is the grocery list; at a big-box store
# several lists can be in range at once.

# Upgrade a matching list row to a need: what the warehouse asks, and what the
# sweep does on open.
# An item on the list the warehouse says is due: its own app's fixed-level quantity
# budget (6quantity) names the target, and on-hand below it is due.
# Every due row becomes a need: the list keeps its own books in step with the
# shelf without the warehouse reaching in.









# The account apps: an app whose pos or mab is 'account' (the same discovery the
# transaction form and the budget use).

# Every unit a transaction can name: the built-in measures plus the ones the
# Measures app has saved, so a packaging named on the spot is offered next time.


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

# Guess which account a printed tender names. An exact word always wins (a
# mastercard account for a mastercard receipt); with no exact word, a family with
# a single account takes it (a receipt saying "credit" selects the only credit
# account, which may be a mastercard; "debit" selects the only interac one).


# The device type a browser's user agent names. Only the types the capability
# table knows are returned; anything else is a computer (the house's default).


# --- a scan session: a rapid-fire run of codes a person confirms at the end ---
# The machine that pressed Scan owns the list and the session. A phone on its own
# jawn forwards each code to it over the peer rail; Done puts the collected items
# on the list, Cancel throws them away and stops the phone's scanner.



# A run can have several inputs at once (the computer's webcam and two phones,
# say). Each has a stable id so the page can add, replace or stop one without
# disturbing the others.


# One resolved code into a session. The phone's relay and this machine's own
# webcam reader both come through here, so a product is looked up in our terms
# once and lands in the run the same way.

# The computer's own webcam, read by zbar. A session on this machine watches the
# camera in the background; each poll folds the codes the reader printed since the
# last one into the run. A phone has its own scanner, and a server has neither.



# A reused pid must not be taken for our reader.

# Is the reader this machine started still running?

# Start the reader for a fresh run: one zbarcam on the machine, writing each code
# it reads as a line, detached so the request can return at once.

# Fold the lines the reader printed since the last poll into the session. zbar
# repeats a code while it stays in view, so the same read is ignored for a few
# seconds; a new item is taken at once.

# Ask the Android app to put its scanner away. The page is paused behind Google's
# scan sheet, so the JS cannot do it; a broadcast reaches the bridge natively and
# it clears the sheet off the task.

# What the session page shows: the raw names stay in the record, the printed ones
# are formatted here so no caller has to remember to unformat an app name.

# Tell a device/tab to start (or stop) its scanner. A peer is reached over the
# signed rail; a tab on this machine gets the console command directly.











# --- receipts: read a shop receipt into the cart ---
# A receipt is long, so it is scanned - the ADF feeds it in one pass - or
# photographed, and the vision model reads the pages into strict JSON. Each line
# is then matched to a house item: a printed code through the barcode cache, else
# the description folded into our terms by the same model that names a scan. The
# list is only touched once a person confirms, and confirming links each line to
# the list in the cart, so the familiar Checkout is still what writes purchases.

# Whether the house already has an app by this name (a scanned or typed item).

# The list row an item names, if the list already holds one (by our name or by
# what it was typed as).

# Fold a receipt's unknown descriptions into our terms in ONE model call: a
# receipt has many lines, and one call each would be slow and wasteful. Returns
# a hash of description => house name, its misses left absent.

# The pages of one receipt -> its lines as JSON. All pages go in one call so a
# total printed on the last page is read with the lines above it.

# Read a receipt's lines into rows a person can confirm. A printed code resolves
# through the barcode cache; a description the house already keeps is taken as
# is; only the genuinely new descriptions are handed to the batch fold. Every row
# carries what it matched by, so the confirm panel can say why.

# Run the scanner for a receipt, into the market app's own scan folder so the
# pages can be filed as a document afterwards. Synchronous, because the person is
# at the printer waiting, and bounded so a jam cannot wedge the request. A run is
# named by the caller's scan_id so a second request can watch its pages arrive.
# Returns (error, [jpg paths]).

# The last lines of a log, read from its tail so a chatty scanner (--progress
# writes a lot) does not make every poll slurp the whole file.

# The scanner's own last word on why a run produced nothing, in plain terms. The
# useful line is scanimage's error ("Document feeder out of documents", "Error
# during device I/O"), not the batch summary printed after it.

# Save a bridged or uploaded receipt page into the market app's scan folder, so
# the paper can be filed like a scanned one. Returns the jpg path, or undef when
# it could not be converted.

# Keep the receipt: its pages stay where the scanner put them (the market app's
# own folder) and a record of what it was - vendor, total, date, the lines read -
# is kept under the market app's own settings, beside the shopping list and the
# barcode cache rather than as an appointment, so nothing else about the app is
# touched by a receipt.

# The scan feeds THIS machine can run: the capability table's answer for the host
# device. A computer has the ADF and the flatbed, a server neither, so the Market
# offers the scanner buttons only when this is non-empty (a phone reaching the
# house still scans on the computer that holds the scanner - the scan runs here).

# The kept receipts, newest first (the raw `receipts` setting on the market app).

# The kept receipts prepared for the Market pane: the pages that are still on
# disk as /file_open links, and each receipt's lines ready to re-apply (so the
# pane can put the whole shop back on the list in one press).











# Group warehouse rows for the warehouse app. The warehouse holds both money
# and stock: a money row is one that names an account (or is denominated in a
# currency measure), everything else is stock grouped by place, then item,
# then unit. Used for the place view and for item search.

# The warehouse as one ledger of moves, stock and money together. A stock row is
# already signed - a pull is negative, an addition positive - and a money move is
# the ledger row mirrored from the transaction that produced it (an expense is
# stored negative, an income positive, a transfer as both), so a single list says
# what left and what came in. The balance snapshots (kind inventory) are anchors,
# not moves, and are left out. Filters: places (stock only - money carries none),
# search, limit.

# A money move is a warehouse row. Every transaction with an account is written
# to the warehouse as it is recorded - the same fields under the same names, so
# the budget can read the ledger without knowing it moved - and the row is keyed
# by the source transaction's uuid, so a re-write or a backfill cannot double it.
# kind='money' marks it; type and movement keep what the transaction was.

# An appointment's own quantity can move stock. The app names the item, unless
# its Stock Item setting names another. A record moves at once; a start/stop
# session moves when it stops, using the amount typed at the start, so a
# cancelled session never touches the shelf. A consume takes only what is on
# hand at that place; the rest is usage - the Coke that came from outside the
# warehouse is counted, but does not make the shelf negative.

# An edit to a record documents the difference as a move: a return to the shelf or
# a take from it, never a rewrite of the original rows. The levels end up where the
# edit says, and the ledger still shows what happened. The original movement keeps
# its uuid, time and reason; the adjustment carries reason 'returned_to_shelf',
# 'taken_from_shelf' or 'edit_adjust_unstocked'.











# How many items a category holds, counting only the ones this viewer may see.
# The Store uses this to hide empty shelves and to print a count beside each one.

# One distinct item per type, so a chip can say how much it would show. A row
# that carries both a pos and a mab value must not be counted twice.

# Item counts for the direct children of a category (or of a subcategory). The
# $field is the settings key the items carry at that depth: `subcategory` for the
# first level, `subcategory1` for the next, and so on.













# Move the stock a quote/invoice/sale represents through the warehouse. $sign
# is +1 to apply the movement and -1 to reverse it (when the document is
# deleted or moved back to a quote). Only fires when the item has a place.




























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
# so browsers cached them heuristically and kept showing stale icons. Force a
# revalidation on every request: an unchanged file answers 304, a changed one a
# fresh 200, so a refresh always sees the latest. A STABLE ?string= is what lets
# the 304 happen - a random buster made every load a fresh URL and a full
# re-download.
app->hook(after_static => sub {
	my ($c) = @_;
	$c->res->headers->cache_control('no-cache, max-age=0, must-revalidate');
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
	/js/manager/stored.js
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
	/js/manager/narratorprinter.js
	/js/manager/marker.js
	/js/pm.js
	/js/manager/terminal.js
	/js/manager/network.js
	/js/manager/budget.js
	/js/manager/embedded.js
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
	/js/manager/folders.js
	/js/manager/desk.js
	/js/manager/notes.js
	/js/manager/clock.js
	/js/manager/help.js
	/js/manager/page_agent.js
	/js/manager/coding.js
	/js/manager/agents.js
	/js/manager/camera.js
	/js/manager/internet.js
	/js/manager/search.js
	/js/manager/phone.js
	/js/manager/people.js
);
our $manager_bundle_cache;

# Where the built bundle is memoised. The in-process cache below only ever helps
# the worker that built it: production runs several prefork workers and recycles
# each after `accepts`, so a per-process memo meant every fresh worker shelled
# out to terser again -- several seconds on the ~1.3MB concatenation -- and a
# page load stalled whenever it landed on a cold one. Sharing the built bytes on
# disk (keyed by the source signature) means terser runs once per code change for
# the whole machine, and every other worker just reads the file.

# Minify the concatenation on the way out, so the readable files under public/js
# stay the source of truth for a person (or an agent) while the browser gets one
# small script. terser -c only: it strips whitespace and comments and folds
# constants, but never renames - the manager leans on names (HTML attributes call
# globals directly, and a few places hand eval() a string). If no minifier is
# found the plain concatenation is served, so this degrades to correct-but-bigger
# rather than broken. Point JAWN_JS_MINIFIER at another terser to override.
our $js_minifier;




# The login body: the password and identity fields ride the POST body, and the
# digest is appended to the query the peer signature covers. Length-prefixing
# keeps the canonical form unambiguous even if a value contains & or =.





# --- Network app ------------------------------------------------------------
# The Network window is a thin client over scripts/jawnos_network.pl. The helper
# owns the fixed Linux command set (iwctl, ip, tailscale, systemctl) and answers
# JSON, so no interface name, SSID or passphrase ever reaches a shell. The phone
# calls its own window.JawnNetwork bridge in the browser and never comes here.


























# ---- crypto payments on a Store invoice -------------------------------------
# The seller shows a payment request, the buyer sends the coin, and the seller
# records it here. A payer's PAY1Z proof is checked against their crest and
# countersigned with the house's; the txid is carried, not chain-checked. The
# money side is an ordinary income transaction on the wallet account, so every
# statement keeps working.


























# ---- passkeys (WebAuthn) ---------------------------------------------------
# Registration needs a signed-in session and a person; login is the one thing
# that must work before anyone is signed in, so those two routes are public in
# app_public_path. A passkey session is marked webauthn so the app gate admits
# it: a key held by the platform, bound to this house's origin, is a stronger
# door than a ticket and is exactly what the gate exists to protect.


















# Where a mugshot is rendered from. Older installs still hold a data URI in
# me.mugshot; those are returned as-is. A name is served by the public /mugshot
# route, which is where the image file actually lives (sealed, under
# photo_location/me). Returns undef when nothing is set.











# Code sync is a peer-key route, not a session route: a peer's cookie lapses,
# and a gated reply silently stalls a sync. Both routes require a pinned key
# (no trust-on-first-contact for a tree that can carry secrets) and are
# restricted to the jawnos folder. The exclusion list is the gitignored/secret
# side of the tree: .shots (the ticket and DB copies), the database, voices,
# releases, personal pictures, generated build caches and the agent notes.


# Extract only a tarball whose every member is under jawnos/; this keeps a
# compromised or mistaken peer from writing .ssh, .president or anything else
# in the home directory.



















# ---------------------------------------------------------------------------
# App releases (the APK). scripts/app_release.pl stages a built APK into
# <repo>/releases (gitignored); every machine replicates it as a blob, not
# through git history. A peer asks what a machine holds, then fetches one - the
# app half of "whoever has the newest is the authority".
# ---------------------------------------------------------------------------
our %app_release_sha;











# The voice models this machine can serve - the *.onnx files and their json under
# voices/. Only the models are shared: the piper binary is per-arch and stays
# local (say_piper_binary), so it is not listed here.




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

# One encrypted batch of a table's rows: the wire unit of the v3 sync rail. The
# cursor is the last rowid the caller already has, so a dropped tunnel costs the
# batch, not the pull; the total is sent with the first batch for progress.

# One table's band map, over the same sealed peer rail. The map is a few integers
# per band, so it is one request, not a cursor. An older peer has no route: that
# is a plain failure and the caller falls back to the whole-table read.

# Pull a peer's rows as encrypted batches and merge them with the same per-row
# rules the snapshot path uses. Only the local watermark and `sync_seen` move, and
# only after every table finished: a short batch leaves the next tick to retry.












# A browser cannot carry the house key to a peer, and the peer's ticket desk
# will not serve an expired session. Mint a ticket with the stored peer
# session; if that session has lapsed, re-auth with the house key and try
# once more. The URL keeps the peer's path/secret but is pointed at the
# peer's own host and dock port, because qrcode_generator may compute a
# loopback or tunnel-local origin.


# The login URL carries only the name and the body digest; the password and the
# identity fields travel in the POST body. The peer signature covers the query,
# so the digest binds the body to it without changing the signature format.











# The tunnel control calls come from a peer's own supervisor, not a browser.
# They sit on the gate-exempt rail (hooks.pl) because a peer whose session
# cookie was lost must still be able to reserve its ports; the route checks the
# caller itself - a session or a pinned, signed peer - like the rest of the
# peer rail.















# A typed contact list (phones/emails): the editor the nfc list wears, one row
# per number or address with a type - mobile, home, work, or a custom label. The
# uuid names the row so a field change and a delete both find the same one, and
# a uuid nobody holds yet starts a new row.

















# The apps the start menu was last used to open, freshest first. The app menu
# is a recent list and the shelf rail is how everything else is reached, so
# it lives in the president's cache like the System view's snapshot; cache entries are
# per device, so each screen keeps its own list. The warranty is asked for
# outright: __president has no warranty setting, and the fallback resolves to
# "now", which the alarm's cache purge then deletes a minute later.

# A press's key is the button's id, or its hint when it has none. It is a
# cache value that the list renders back into the page, so the press and the
# forget both cut it down to plain words first.

# The freshest ten are kept.

# What the X on an item asks for: the app leaves the list, whatever its place.

# The start menu's static icon grid is the house's built-in apps, so a private
# one must disappear from it too. The client matches these keys against the
# icon map; a custom app is not in the grid, and its running rows are filtered
# by appointment_private_now in the template.












# Ticket management is the citizen's desk: minting, deleting, suspending,
# renewing and reinstating are the owner's acts, and the hook's tier check only
# knows that /manager is resident territory, not who the owner is. A
# neighbouring machine on the mesh is admitted too, over the same signed rail
# the other peer routes use: it names itself in `signatorial` and peer_verify
# checks its signature. The desk
# is exactly the thing a device without a ticket of its own needs, and the
# request it holds may live on a neighbour's database, so the owner must be
# able to answer it from a machine that is not the citizen session itself.
#
# A pinned pubkey is required, unlike the trust-on-first-contact peer routes:
# this desk hands out citizenship, so a machine that has merely linked and not
# yet completed a signed exchange must not reach it before its key is on file.

# The request desk's policy and its blacklist are rows read by the newest
# write, not device-scoped settings: the public page is served by the server
# while the owner may sit at a phone, so a choice made anywhere has to be seen
# everywhere the mesh carries the settings table.




# The call blacklist is that same desk list seen from the phone: every entry
# that carries a phone, as the bare digits the app compares. A listed number is
# turned away before it can ring (the app's CallScreeningService reads this), so
# the numbers are handed to the phone on its own route.

# Block a number straight from the desk or from the phone's recents: one entry,
# keyed by the number so a second press never doubles it. The label is the app
# that owns the number when the house knows it, blank otherwise.

# The house's numbers by name, for the app's in-call screen and its contact
# list: the same settings 'phone' rows the Phone app shows, keyed by the bare
# digits so the native side compares them the way it compares the blacklist.

# Every number the house holds, split the way the Phone app's panes want it: the
# people it knows, and the numbers that are only numbers (a stranger's call makes
# its number an app of its own, so those rows are the ones still to be named).
# One row per app, carrying every line the person keeps - the plain phone row
# first, then the typed list - so a person with a home and a work number is listed
# once, not once per number.

# The desk's blacklist seen as calls: the numbers to refuse, each with whatever
# the desk knew about it (a name when the request carried one, the note).

# A small square picture of a person for the app's call screen: the house's own
# image when there is one, downscaled once and kept beside the database, keyed by
# the source's name, size and mtime so a new picture makes a new thumbnail. The
# app shows its own logo when there is none, so nothing is drawn here for that.

# The person's picture as a data URI, for the one fetch the app makes: it hands
# the whole directory over at once, so an image per call would be a fetch the app
# (which may be ringing with no page up) cannot wait for.


# A request matches the blacklist when any one of its identifiers does.

# Is this requester already known to the house? The same rows the mailbox uses
# to name a thread: an email or a phone number kept on an app - the plain setting
# or a typed entry beside it (their work line, a second mailbox).

# The door's throttle: one request per browser tab at a time, and one per
# address per ten minutes. Over the line the form answers exactly as it does
# to a queued request, so the door never says who is on the list.


# What an approval mints: the box office's own mint, with the house's suds
# when a citizen is not the one pressing the button, and the requesting tab
# carried over so the waiting page can be let in.
























# Build the account/project pickers' marker lists (__accounts/__projects) from
# the pos/mab settings. A header-only log_reader skips this work; the centre
# view that follows builds it once before rendering the wrapper.













# Decrypt a sealed file's bytes, trying each security credential the way
# rock_and_roll does. Returns undef when none open it.


# A scale legend read off a map ("500 ft") is ground truth only once it is metres:
# the engine measures pixels-per-metre off it, so a plain number is what gets stored.




















# A peer's lease is enforced here: a signed peer call must carry the rung its
# movement needs (start/stop and an app toggle are resident; a shell command is
# trusted). A local session has no peer identity and is left to the session
# gate. A peer session minted by sesh_check carries the caller's signatorial, so
# a session-riding call is checked too; a session from before that change has no
# name on it yet and keeps its existing gate until it logs in again.
# The verified row for this request, or undef for a local session. A signed
# request sets the stash through app_peer_ok/peer_verify; a peer session carries
# its proved signatorial and is looked up here. Local calls have neither.































# The part of an appointment's span that lies inside [start, end): an appointment
# runs from its timestamp for its duration, and a session that crosses a period's
# edge belongs to both periods by the time actually spent in each - 23:36 to
# 02:30 gives the first day 24 minutes and the next 2 hours 30, rather than the
# whole night to the day it started. The caller sets duration for a running
# session (there is none in the row while it is open).

# The next local midnight after a moment, as epoch milliseconds. The calendar
# date is stepped by hand because Time::Local refuses an out-of-range day (32)
# and normalising through it would croak on the last day of a month.

# Allocate a session's time across the allocation view's components by when it
# was actually spent: the hour of the day, weekday, day of the month and the
# rest each get their part, instead of the whole session landing on the one it
# started in. Seconds and minutes repeat on a fixed clock, so whole cycles are
# added once and only the remainder is walked; the longer components step from
# one local boundary to the next. A span past a year is one bad row rather than
# a distribution, so it stays on the components it started in.

# the value one window shows for the inventory's chosen measure, the way the
# inventory buckets it (a running session read to now, a measure read off the
# appointment's own readings). A duration is read only for the part inside the
# window when the caller names its edges.











































# Merge one table's rows into the live database. The row source is a closure so the
# encrypted-snapshot path (rowid batches from a temp SQLite) and the row-stream path
# share every table-specific rule: uuid upsert, protected settings, utility
# controller keys, window state, continent temporary rows, file mirrors, deletions.
# The body keeps its original `next` statements: a one-pass ROW label makes a row's
# `next` leave just that row, while a `next` inside a nested loop still binds to it.

# The post-merge work shared by the snapshot path and the row-stream path: refresh
# the header/budget for appointments that moved, apply the deletions that came with
# the pull, and drop the relational caches an app's settings invalidate.

# Merge an encrypted snapshot: the full-migration / deep-gimme / v2 path. A normal
# v3 delta never gets here - `sync_rows_pull` feeds the same merge_table_rows and
# merge_finish directly from the row batches.



# --- Bank statement import and reconciliation ------------------------------
# A statement is read into dated, signed lines, matched against the money the
# ledger already holds for one account, and shown as a screen where a person
# settles the rest. Reconciling writes the statement's ending balance as an
# inventory anchor, which is the number the Budget balance is measured from.








# The money the ledger already holds for the account at the statement's end:
# its last inventory anchor plus every transaction after it. Purchase rows are
# breakdowns, not moves, so only type='transaction' is read.

# Pair each bank line with at most one ledger row of the same amount within three
# days; the closest date wins. A line the ledger only partly holds - an e-transfer
# whose service charge was recorded on its own, as Libro writes it - is then
# settled from the few rows that make it up, and the screen records only the
# remainder. Rows left over are the money in Budget that the statement does not
# show.

# The merchant memory: the app a description has consistently been filed under.
# It reads the old transactions' vendor (Libro writes 77 Vape Wyoming as
# 77_vape), then their item, then their app, and matches those words against a
# statement line. A suggestion is only a default - the line still waits to be
# confirmed.



# The pair of two legs of one transfer is the other side of the same move, so a
# missing leg is recorded as that transfer rather than as a new expense.

# Write the decisions of a reconciliation: each line left on Record becomes a
# transaction, then the statement's closing balance becomes the account's newest
# inventory anchor. Nothing is read back from the browser to decide this, so the
# same routine can run on a copy of the database in a test.

# --- Financial statements --------------------------------------------------
# The cash-basis statements read the same ledger the Budget view does: each
# account's money moves (type='transaction'), grouped by the app that carries
# the category. Nothing here writes.

# Open invoices (not quotes) at a moment, with the balance and the age of each.
# There is no due date on an invoice, so the age is counted from the day it was
# written; the screen says so.

# Open bills at a moment. A bill is a money row on the payables account (money
# owed, not money moved); a payment is a bank move that names the bill it
# settles in source_uuid. There is no due date on a bill, so the age is counted
# from the day it was written; the screen says so.

# --- Recurring bills -------------------------------------------------------
# A schedule is a template, not a bill. It lives in a setting so it needs no
# table of its own, and each due date becomes a real bill keyed by the schedule
# and that date, so running the schedules twice cannot double a bill.




# --- Notifications that name a payment -------------------------------------
# A bank's "you spent $29.38 at PUBLIC MOBILE SELF" is a bill that has already
# been paid. Match it, suggest the app the house has used for that merchant, and
# offer one OK. The bill's uuid is derived from the notification's own key, so a
# notification stored twice (the phone and the mirror) is still one bill.


# What a notification names: an amount and the merchant it was paid to. It is
# only a payment when a spending verb sits beside the amount, so "you have $0.00
# left" is not one.


# Remember that a notification is not a bill. The undo of a booked notification
# is the same decision, so a key dismissed here is never booked again.

# The same calendar day, in the house's own local time. A statement line is
# stamped with the purchase date, so an import and the notification that
# announced it share a day even when the import ran hours later.

# Has this purchase already been written as money leaving the account? A
# statement import, a reconciliation or a typed transaction records the same
# payment as an expense; a bill and its payment on top of that would take the
# money out twice. The match is the account, the amount and the day, and the
# merchant when the recorded row names one. The day is what keeps today's coffee
# from looking like yesterday's.

# Book every qualifying notification. This is the clickless path: a payment the
# bank has already made is a bill raised and settled in the same breath, so it
# needs no prompt. Only a notification from a bank account the house knows is
# booked, because that is what makes the payment leg real money leaving an
# account. The bill's uuid comes from the notification's key, so a duplicate row
# (phone and mirror) books once, and a row already booked is skipped.

# The bills the notifications made, newest first, so the screen can show what it
# booked and offer an undo.

# The accrual side of the statements. Income and expenses are what the journal
# posted - an invoice's revenue, a bill's cost, a stocked item's cost of goods -
# so the income statement agrees with the Trial Balance. A row whose account is
# a bank account outside the chosen set is left out, so the account filter still
# means something; invoices and bills have no bank account and are house-wide.









# A bill is money owed, not money moved, so it is written on the payables
# account and the journal carries the expense now and the payable until a
# payment settles it.









# A circumstance's own reading, written the way the budget panel shows it: a base
# mode (occurences, duration, total, quantity) wears that mode's formatter, and a
# measure wears its own name, the way the autocalc writes one ("8681.139steps").
# The lookup is guarded on purpose: a bare chained deref of an absent measure
# would autovivify the key in %{$gb::budget_modes}, and then every later
# budget_calculator in this process would take the measure for a base mode and
# skip reading it (its budget value came back undef).




# The calc a measure reads with: its own remembered one (steps sum, weight
# average), else the app's s_calc as the fallback. Used wherever a measure's
# value is taken - the budget runner, the panel - so a steps budget and a weight
# budget read right at the same time, whatever the display is showing.


# One budget/goal entry read apart: a leading "<=" or ">=" says which way it
# runs (under is good, or over is good), the number is the target, the name that
# follows is the measure ($ for money, absent for occurences), and "/<scope>"
# makes it a rate rather than a fixed level.

# The measure's own trend: a least-squares line through its readings, as
# value-per-day, with the latest reading and the reading count. The stretch it
# reads is the floor given unless the measure is recorded more sparsely than
# that: the window is widened to about a dozen readings when the median gap
# between them is longer than the floor of a dozen dozen, so a level recorded
# once a month or once a year is not judged on the few points a fixed 90 days
# would hold. Times are measured from the first reading so the huge millisecond
# stamps do not cancel the fit.

# A goal read for one circumstance: the target, where the measure stands now, and
# - the part a budget cannot give a scopeless entry - when the current trend
# carries it to the goal. A trend moving the wrong way has no date.
















# --- People: the house crest -------------------------------------------------
# The first pass owns one crest: the house's own drawing. It is scanned or
# uploaded, normalized and hashed, sealed like a picture, and signed by a house
# key kept sealed under the house key. Other houses' crests and the vouches
# between them come next; nothing here writes a peer row.


# The social people are settings rows (`pos` or `mab` = person), not the
# `people` table's device accounts. One read builds the whole picture: every
# app's effective construct, the settings uuid each device copy carries, and
# the membership arrays (`sc_<singular>`) those rows already keep. The
# Relational cache is deliberately not reused here: it caches rendered
# buckets, and this index is one small query over rows the window needs fresh.

# Keep the people table and the person constructs in step. A person construct
# creates its people row; a row whose construct was deleted from the database
# is removed; a construct that merely changed away from person (to idea, say)
# keeps its row, so a mistaken change does not cost the identity behind it.

# The construct chips a person wears: each membership array names a construct
# app's settings uuid, and the index's reverse map names the app itself.

# The peer crest linked to a contact app, as an image the window can show.


# The person's own picture. The main_image setting is written per device and
# may be a sealed path or (on a phone) a data URI; /file_open is what unfastens
# a sealed picture for an <img>, and it takes the app alongside the path.

# Met / introduced state for a linked crest, read the same way the crest
# detail panel reads it.


# The singular a construct app answers to ('community', 'team', ...), or empty
# when the app is not a construct of this house.

# True when this app is another house's construct, imported read-only. A local
# construct has no house_uuid; the marker is what keeps publication, logos and
# Relational edits away from something this house does not own.


# A construct is published to another house only when its own public setting
# says so. The setting is kept per device, like the public toggle on the
# appointment itself, and People consolidates the rows it holds: the newest
# choice across the house is the answer the construct row shows and the answer
# a lookup carries.

# Import another house's construct as settings rows this house can read but not
# change. Its identity is the signed construct crest (uuid + house uuid); the
# local app key is only a label, suffixed when the name is already taken. The
# house crest must already be held: a construct is only trustworthy as part of
# a house this machine knows.

# What this house publishes to another house that presents a crest: the house
# name and key, its address, and only the constructs marked public, with the
# names of their members. Nothing here is a permission; the answer is signed by
# the house key so the asker can check it came from the crest it holds.



# A construct's crest: the same signed record, card and compact code as the
# house crest, signed by the house key and naming the construct. It lives on the
# construct's own settings rows, so deleting the construct takes its crest with
# it. The drawing is stored beside the house drawing with a name only this
# construct's id makes, so the two never collide.




























# The note an appointment window is still typing is a draft. It is the same
# notes table the Notes app reads, which already rides the generic peer sync, so
# a refresh, a crash or another machine finds the words again. The row's name is
# derived from the app name, so every peer converges on one draft per app rather
# than making a note for each keystroke. An empty text clears the draft once the
# note has been filed on the appointment; the row is kept (and hidden) rather
# than deleted, because a notes deletion is not carried by the sync tombstones.








































# The entry a setting wears for this device: the device's own row, then the
# house-wide ('all') one, then whatever row there is.

# Has anything the search list draws changed? Every write through setting_setter
# stamps a fresh server_time, and a delete (a removed app or its last setting)
# moves the count, so these two aggregates are the cheap watch. The icon set is
# included because the row pictures follow it; manager_background_colour picks
# the light or dark cut of that set.

# The picture an app's search row wears: the same one its window does - the
# app's own main image first, then the built-in drawing, then the pos tile.




# The Apps tab. An app matches when its own name (or the name a person reads)
# carries the words, and it is one the house knows: an appointment record, a
# visible app, or a built-in the menu opens.


# ---- search engines -------------------------------------------------------
# The engines live in code (gb.pl) and the person's own are in one setting:
# which are on, and any added from the Browser. `device => 'all'` keeps the
# choice for the whole house, like the language.



# The five catalogue sections, plus custom for a site added from the Browser.
# The label is a core interface label so it comes back in the house language.



# The engines the Web tab asks, in the order they sit in the settings panel.




# Add one engine the person named, or (from the Browser) one found on the page
# they are reading. Both end in the same custom entry.



# The Web tab. Every enabled engine is asked for the words and its links are
# read back as results. The page is never shown as-is: a result is a title and
# an address, and the click opens it in the house's own browser. Eight engines
# at most keeps one query from holding a worker for a minute.
















# ---- Internet: usage and live-page measures ------------------------------
# Browse is a native sibling of the manager (a WebKitGTK window on the desktop,
# an activity on Android). It posts here as the installed app it belongs to, so
# the ordinary app gate is the only credential; there is no second token.






# The apps the launcher and the Internet tab choose from: the house's own
# catalog first, then any app a person has made. Kept in one place so the
# manager and the phone never disagree about what an app is called.
#
# visible_only is for a picker that assigns a thing to an app: it leaves out an
# app the visibility rule hides here and now (off, or a place level below the
# room), so a suggestion never offers what the house is keeping out of sight.
#
# any_appt is for the Internet picker: a website may belong to any appointment
# in the house, not only the house's built-in apps and launcher icons. The
# visibility rule still decides which ones are offered.

# The launcher's icon URL. The icon set ships SVG, which Android's
# BitmapFactory cannot decode, and a person's own main image is sealed behind
# /file_open; /apps/icon answers both with a PNG.












































# --- Relational: the social-construct workspace ------------------------------
# The workspace is built from the same index the People window uses. The old
# matcher rendered each bucket through the relational cache; this one reads the
# settings rows once and hands the client a single JSON board, so adding a link
# is one request rather than a partial re-render per pane.




# Write the membership array on every device copy of an app. The workspace
# unions those copies, so changing only this device's row would leave the
# member visible on the others.















# Apps that are not launchable from the app menu: citizen kinds and the
# handbook's older alias. They must not be offered as desk shortcuts.
our %folders_desk_not_app = map { $_ => 1 } qw(citizen resident guest blacklisted library);

# The folder the desk shows. A chosen desktop_folder wins; otherwise ~/Desktop
# is used only when it has something in it (an empty desktop reads as broken),
# and the home folder stands in for both.

# The apps pinned to the desk, in the order they were pinned.

# Every app a person may pin, with the name and icon the picker draws.





# The app a path belongs to: the first segment under a known location root
# (~/Pictures/<app>/...). Used to apply the visibility rule to a listing.

# The house's own apps are written to disk under their key form - path_name() of
# the app name - so a folder the program made reads as a word salad in the
# listing. The apps the settings table knows are collected here once per folder.

# One path segment as the address bar reads it: a component a program wrote
# carries its percent escapes (path_name), so decode it first; then the house's
# own words, the same format_name every other name gets.

# The folder a person reads along the top and in the title bar. This is the eye
# only: folder, path, history and every command keep the real path.

# The name the window's title bar adds after "Folders": the folder on screen,
# not its whole path.

# The folder a media location wrote for an app reads as the app's own name. Only
# a location's top level is renamed; a folder inside an app folder keeps the
# name it has on disk.

# A sealed name carries no words of its own. A row that points at it may name it
# - a map's place, a document's title - and that name wins; otherwise it reads as
# the app that wrote it and the moment it was made, "Autumn 10162026 3:30pm".

# The moment a sealed file was made, in the house's short form: 10162026 3:30pm.

# Whether Folders may list sealed names comes from the window's own unlock
# token (media_unlock_open), never from the secret left in settings: a fresh
# open is locked, while the refresh after an unlock carries the token.

# The names in a folder, in the order a file manager lists them. `readdir` rather
# than a shell `ls`: a name is data, and one holding a space, a quote, a star or a
# newline used to be split or expanded by the shell before the app ever saw it.
# Dotfiles stay out of the listing, as they did with `ls`.

# The archive's copy of the folder being read, for the badge on a local item
# that also has a copy on the archive machine. The manifest is asked for once
# per location and cached briefly; an unreachable archive leaves the listing
# unmarked rather than failing it.

# One folder read as the app (and the desktop behind it) shows it: its entries,
# the folders apart from the files and the disk's own figures. The padlock rule
# is the same one the gallery reads, so a not-visible app's files stay out until
# this screen's Folders padlock is open.


# One name inside a folder, as a file manager means it: no slash, no climbing
# out of the folder, and nothing that is only whitespace.

# What a folders command works on: what is selected, else the file the menu was
# opened on, else nothing at all. The background menu names no item.

# ---- the Recycle Bin ---------------------------------------------------------
# Deleting a file moves it here instead of unlinking it; a shred still destroys
# it. The layout is the freedesktop one (~/.local/share/Trash/files beside
# info/*.trashinfo), so the bin also works with the rest of the desktop.

# A move that works across filesystems: rename is the cheap same-disk case; a
# folder is walked otherwise, so a file deleted onto another drive still lands
# in the bin rather than being shredded to make the move fit.

# Put one path in the bin, with a .trashinfo naming where it came from.

# The original path a bin entry remembers, or '' when there is no info file.

# Put one bin entry back where it came from. A restored name that is already
# taken is kept beside it as name.restored, never written over.

# Permanently take away every entry in the bin.

# Take a folders selection away. Anything an appointment has attached goes
# through the app's own file deletion first, so the appointment lets go of it,
# the thumb goes with it, and the other machines hear about it; the rows
# besides appointments that named the file - a mailbox's attachments, the
# store's rows - are trimmed of it, and a backup whose sealed file it was goes
# the way a pruned backup goes. Whatever is left after that is deleted or
# shredded where it lies. Returns the errors.

# A backup whose sealed file is being taken away goes with it: the row is
# deleted and the other machines are told to drop it, the same as when
# backup_now rotates a backup out. Returns how many were pruned.










# Which location an archived path belongs to and where it sits inside it, asked
# of the machine that owns the drive. A caller that only has a path on that
# machine - a selection in folders, a track, a photo - asks this first, and the
# answer is what a fetch needs.
#
# These archive routes are on the peer rail the way remote_upgrade is: a
# sending machine has no session on the archive machine, so the login gate must
# step aside for its pinned signature. archive_peer_allowed is their gate.



























# ---- junderground client ---------------------------------------------------
# The Chat Rooms section talks to these; every call is signed on this side with
# the house crest key, so the browser never sees it.
our $jg_body = sub ($c) {
	my $raw = $c->param('incoming_data') || '{}';
	return eval { decode_json($raw) } || {};
};








































# The mailbox rows a folder holds. The built-in folders are statuses; Starred is
# the flagged subset of everything not thrown away; Trash is the soft delete. A
# folder the person made is simply a status of its own, so it needs no schema.


# The folders the person made: their names live in one setting and ride the mesh
# like everything else. Reserved names are ignored so a stored list can never
# shadow a built-in.

# How the list is ordered: date, sender or subject, ascending or descending. The
# choice is a setting, so it is remembered and follows the person's machines.

# Order a folder's threads. Date and sender sort on columns (no decryption);
# subject needs the subjects read, so they are opened once here when asked for.
# Always ascending - the caller slices from whichever end the direction wants.

# A short plain-text preview of a letter's body, for the list's second line.

# Group a folder's letters into conversations, newest first, each with its newest
# letter's row. This touches no ciphertext, so it is cheap for a whole folder;
# the readable bits (subject, snippet, counts) are added per page instead
# (email_thread_annotate), so a folder of thousands only decrypts what it shows.
# Grouping rides the stored thread key only (a header chain, set when a letter is
# written or received); a row from before the column has no key and stands alone.
# A key is never rebuilt from the subject here - two unrelated letters that
# happen to share a subject must not fold into one thread.

# The readable half of a thread: the newest letter's party and subject, its star,
# how many letters it holds and how many are unread, and a snippet of the newest
# body. This is the part that decrypts, so it runs on one page of threads, not a
# whole folder.

# What the folder rail wears beside each name: the unread count for Inbox and
# Starred, the total for Drafts and Trash, nothing for the rest.










# Which sections each app owns. Mailbox (no scope) carries them all. An app that
# owns one section shows no switcher; one that owns several (chat) shows just its
# own, so its sidebar is that app's navigation and nothing else. Declared here,
# beside the renderer, because the scope is what picks the sidebar's buttons.

# A decrypted note is UTF-8 bytes. The template and the JSON socket both want
# characters, or an emoji goes out as four Latin-1 glyphs; invalid UTF-8 is left
# exactly as it came.














# A map's home plate is its anchor on the globe: a pixel at a latitude/longitude.
# Measuring can also leave it as a named legend instead ("lambton mall") - the
# home_plate setting of the app it names - so fold whichever exists into the
# map's home_plate, and the client has one shape to read. The map is modified in
# place; the resolved plate is returned.

# The ground bounds of a measured map: the latitude/longitude of its top-left and
# bottom-right image pixels, from its home plate and scale bar - the same
# arithmetic the client engine does (mapengine.js mapBounds), here so the server
# can reason about where the maps sit and what lies between them.

# Whether the ground at a point is already known: inside any placed map's bounds -
# and, when $with_guesses, inside a guess already drawn, so a pocket is not
# guessed over twice.

# The largest pocket of unmapped ground inside the view: a coarse grid marks the
# cells whose centre no placed map (or existing guess) covers, and the largest
# all-empty rectangle in it becomes the pocket. A rectangle - not the bounding box
# of a connected region: empty ground that wraps around a map (the corridor beside
# it, the void above it) has a bounding box that swallows the map itself, and a
# guess there would lie under ground we already know. Undef when the view is all
# known ground, or only slivers of it are not.

# A grid pocket's cells as a ground box - the grid's own arithmetic, read back.

# Advance one side of an empty grid pocket by one line, when the whole line is
# empty ground and still inside the grid. Returns 1 when the line was taken.

# The pocket grown by a fraction of each of its own spans, on every side - but only
# through empty ground: a side advances one grid line at a time and stops at the
# first line that would touch a map, so the grown box still covers nothing known.
# The guess fills the blank the measured maps leave, never over them.

# Widen a pocket's short axis towards the canvas the picture will be drawn on (the
# long side 768, the short side never under 256, so about 1:3 at the most), a grid
# line at a time and only through empty ground - so the picture is not stretched
# on the canvas, and the widening, like everything else here, still covers nothing
# known. A map in the way simply stops that side; the picture stretches a little.

# The box grown by a fraction of each of its own spans, on every side.

# The part of one map that falls inside a ground box, as picture bytes: the
# georeference read backwards (a box corner to an image pixel), cropped and shrunk
# for the Vision model. Undef when the map is not on this machine or the box
# misses it.

# What the maps around a pocket show of it: their own parts of that ground, read
# by the Vision model into a conservative paragraph the image model can draw from.
# Returns the description and the names of the maps that fed it; both may be empty.

# The names of the placed maps nearest a box (a map inside or touching it counts
# as at its edge), for naming the guess after where it lies. A map whose ground
# lies inside a bigger map's is a detail of it, not a neighbour a guess can sit
# "between" - naming by it reads oddly (the mall sits inside Sarnia) - so the
# top-level maps do the naming.

# The measured maps, normalised for the client engine: a file URL the browser can
# open plus the two things that place the picture on the globe - the home_plate (a
# pixel at a latitude/longitude) and the scale bar (metres between two pixels).
# Shared by the travel viewer and the continent background. A map that cannot be
# placed (no plate, still ungeoreferenced) is left out rather than sent to be
# silently skipped.

# The machine's current position - the single row several writers (the headless
# navigator, the browser, the tunnels, the reconnector) keep rewriting with type
# 'temporary'. Returns undef when none has been recorded, or when the row's hold
# has run out: a fix borrowed from a phone must not leave the laptop claiming a
# place the phone left hours ago. Writers always stamp a warranty; a legacy row
# with none is still read.
# A filed fix carries its appointment's uuid as a prefix (uuid => appt . '-' .
# random). Find that prefix when it names a real appointment; a fix that names no
# session is not part of a track.


# Every place the continent has a fix for in a time range (or all of them), the
# same places the travel viewer shows. Repeated identical fixes collapse to one
# dot, so a walk reads as its points rather than a stack of samples.

# The appointments the view's time range holds: every app with a row whose span
# touches [start,end] (a running appointment reaches back past the window), each
# at its latest recorded fix, so a tap on the map can open its appointment
# window. The same visibility rule as travel_atlas_points applies - a thing
# marked not-visible is not drawn.

# Every home plate the machine knows, for the map's place markers: the plates are
# the fixed points a walk comes home to, and the same spot can hold several of
# them (one per device, or a place and the thing beside it), so the client groups
# them by where they sit.






# --- Handbook: Today ---------------------------------------------------------
# Today is the Handbook's daily page. It reads the day in the same stores the
# rest of the house writes to - appointments, the money ledger, measures, notes
# and the social constructs - and lays them out as a journal: what the day cost,
# what state things are in, which projects moved and who is in the plans. A
# typed `day` is read by the same resolver the clock's time machine uses, so
# "today", "yesterday", "jul 16" or "2025-10-21" all land on a day.

# A money row's value, without its sign: the ledger writes expenses and payments
# as negatives and income as a positive.


# The moment a planted idea/plan/dream belongs to. A model is asked for an ISO
# date, but a phrase the calendar can read is kept too; a bare item falls back to
# a horizon that fits its kind. A past date is rolled forward - a thing planted
# now is a thing ahead, not a record of something already gone.

# The day's journal, read from both stores the house keeps: the journal app's note
# appointments (encrypted, the long-form entries the person already has) and the
# plain notes table (the Notes app and the watch). They are merged into one list
# so the page and the Guide read the same journal, whatever wrote the entry.

# A journal entry is an appointment on the journal app, encrypted the way that
# app's existing notes are. It is a real record, not a note in a side table, so
# it travels the mesh and the Guide can read it back through note_retriever.


















# ---- what the acting guide reads to answer, instead of guessing --------
# These turn the model's words into an answer from data already on the machine
# (the place fixes, the home plates, the logged measurements), so the guide can
# say where, how far, and when without reaching the network or inventing a number.

# kilometres between two latitude/longitude pairs, in the app's own units

# The current place's rating - 1 at home (private), 2 out (public), 3 dangerous.
# A lost fix reads as public, so an unknown place denies rather than reveals.

# The media padlocks (gallery, music, folders) are per screen. An unlock is a
# token minted for the device that asked for the print, stored for that device
# alone, and dropped the moment the app window, the screen or the tree closes.
# A peer, another window on a different device, or a restarted tree holds no
# grant, so opening the app there stays locked.

# The screen a media request speaks for. The app's own requests carry the uuid
# it knows (jawnDeviceUuid); a request without one falls back to the session.

# The window a media request speaks for, when it names one.

# Drop one app's grant (or every media grant) for one device. The rows are keyed
# by the device uuid, so one screen locking never reaches a peer's row.

# Closing a private window, or five minutes without movement, relocks private.
# On a manual close, $opts->{'only_if_last'} keeps the grant and the other
# private windows alive while any of them is still open (the person may just be
# tidying the screen); the last close clears it. The idle lock passes
# close_windows and closes them all.

# Mint one window's grant. Only one grant stands per app and device: a second
# unlock replaces the first, which is what makes a new window open locked even
# while another was open a moment ago.

# The sealed token an open grant holds, for the request that just minted it.
# The console push is the usual way a window is told; this lets the same window
# read it straight from the reply when the push is late or the socket is down.

# A grant belongs to one device. Helpers without a request (the guide's own
# search) are given the device explicitly; with no device they see a shut lock.

# A thing the person marked not-visible is shown while that screen's padlock is
# open. The place used to be part of the rule; it is not any more: a machine with
# no location fix could never reveal its own private albums after an unlock,
# which read as "the unlock did nothing". The unlock is the deliberate act.

# A file read is not an app window: /file_open and /play do not carry the media
# app's own unlock token. Any live media grant on this screen is still a
# fingerprint, so a private file loads after Gallery, Folders or Music was
# unlocked (or after Security's Private apps grant). The place gate is checked
# by the caller.

# Whether one page's `unlock` token opens one media app's padlock. The token is
# checked against the grant stored for this device: a token minted on another
# screen or another machine is no proof here, and a fresh open carries none and
# stays locked.

# An app is hidden when the visibility rule says it is hidden here and now:
# a place level below the room's exposure, or the lockdown (a dangerous place or
# an Enemy present). During a lockdown Security stays, a Dangerous app stays,
# and an Enemy's running app waits for the fingerprint reveal.

# What the guide may reach: an app the rule shows, or the reveal rule holds.
# A lockdown is not opened by an old media padlock grant.

# the nearest thing we have measured, for naming a fix

# the distance walked between two moments, read from the walk app's own fixes.
# A step is only counted between fixes close in time and at a walking pace, so
# the quiet hours between two walks do not read as one long stride.

# the person's weight trend, read from their logged measurements, projected to a
# target: a line through the recent readings, taken to where it meets the budget

# "where was I at a moment" - the newest fix at or before it, named if we can



# "how far did I walk" and "when will I be <target>" - read from the fixes and
# the logged measurements, answered in the guide's own voice


# "play <x>" - run the music app's own folder walk (Music::music_search) over
# every known location, then keep the files that contain all the words asked for,
# best match first (a "Ben Folds Five" album folder and a "Mess" track are the
# same request). Hands back the one file to play. Shared by the guide's route and
# the remote command channel.






# ---- the remote verb channel ------------------------------------------------
# A peer can be told what to do in the words the person used (text, parsed by
# that machine's own guide, so it stays offline) or as a structured verb from the
# same registry the local guide offers. Client effects are broadcast to the
# peer's own tabs over its websocket; questions are answered here and handed back.
# ---- names and identity -----------------------------------------------------
# A name is not an identity. "music" can mean the Music app or a club called
# Music, and two people can both be called John Smith. Resolution returns a
# ranked set of candidates and only acts when one is clearly ahead; anything
# else is handed back as a question, never guessed.



# A person's own words for a thing: "zzz" for sleep, "js" for John Smith.
# One synced map of normalized word -> target, so every machine understands the
# same aliases. The target is stored by identity (kind + uuid + app) as well as
# by name, so a rename does not break the alias.


# The long-standing aka convention: a settings row on the app itself, with a
# comma-separated list of other words for it ("21" for policy 21, "zzz" for
# sleep). It predates the Guide and is already used by setting_initializer, so
# the resolver reads it too; a taught alias for an app is written here.



# Resolve a spoken or typed name. opts: kind => app|person|construct|machine|house.

# Resolve the app a Guide action names before it runs. A clear answer is written
# back as the canonical key; a tie becomes an "ask" action, so the model does not
# get to pick one John Smith for the person.

# A name a write route was handed by our own client or by the model. An id wins
# over a name, so a rename is not an identity change; a name that now means more
# than one thing asks instead of acting on the wrong one. An exact app key the
# client sent is trusted even when the name is ambiguous, because a key is not a
# guess. A name nothing matches is handed back unchanged: stage may be naming an
# app that does not exist yet.
# exact => 1 is for a create: there a partial name is a new thing being named,
# not a shorthand for an old one, so only the key itself (or an id) is accepted.



# Run one action here. Client effects go to our own tabs over the websocket;
# anything that is only words is answered directly.


# The local half: this machine sends a command to a peer.


# Remote keyboard and mouse, the peer half: a linked machine that this house
# already trusts sends one batch of pointer/key events and they are injected
# here. It is the same path the T-Deck's teletype uses, shared through
# remote_input.pl, so an X11 or Wayland backend installed for one serves both.
#
# The batch is small and arrives in order from the sending manager; moves are
# absolute fractions of this screen, so a lost or reordered batch cannot leave
# the pointer drifting.
# The screen does not usually change between batches, and asking xprop for it
# on every pointer move would add a process to each one. A ten-second memory
# keeps a monitor that is plugged in from being missed for long.
our $remote_input_geometry_at = 0;
our $remote_input_geometry_cache;

# Adjacent moves and typed characters are one action each: a fast typist must
# not become a process per character, and a dragged pointer only needs its last
# position. Runs on both sides so a batch that crossed a handshake is still one
# string.




our %remote_input_ua;
our %remote_input_ws;
our %remote_input_rm;
our %remote_input_ws_failed;

# A peer that answered the handshake with a page or a refusal is not asked again
# for a minute: the signed HTTP route still carries input, and an old peer must
# not pay a dial on every batch.

# The roster row is read on every batch otherwise (a SQLite query per 6 ms of
# typing). Ten seconds is long enough to save the work and short enough to
# follow a tunnel that moved.


# Mojo builds a text frame from a character string and would encode a byte
# string again, so an accented letter typed on one side would arrive mangled.
# Decode exactly once, as websocket_sender does.

# The signed HTTP relay, used when a control socket cannot be opened. Every call
# signs and verifies with openssl, which is exactly why the socket exists.

# One open control socket per peer. Signing the handshake is the expensive part
# (openssl on each end), so it is paid once and the frames after it are cheap.
# Nothing is sent on the socket until the peer's `hello` arrives: until then the
# signed HTTP route carries the input, so an old peer (or a handshake the gate
# refused after the upgrade) costs latency but never control.





# The remote_control panel's Me view names this machine's public address, which is
# the quickest proof that the VPN is really carrying the traffic: with an exit
# node in force the echo service sees that machine, and without one it sees the
# ISP. The answer is kept for 30 seconds; `refresh` skips it so toggling the VPN
# repaints at once instead of showing the previous route's address. The lookup is
# asynchronous, so a slow or unreachable echo service cannot stall the manager.
our $public_ip_memo;

# ---- the Guide's write path: stage, then promote or drop ------------------
# The Guide never writes an appointment straight in. It stages a proposal, the
# person sees it, and only a promote turns it into a real appointment.
# The Guide's write path as named subs, so the routes and the voice brain share
# one implementation: a proposal staged by a spoken "remind me to ..." lands in
# the same staged_appointments row a typed one would.



# ---- the Guide's change path: update an appointment that already exists -------
# A change names the appointment by its app (the app is the thing; its appointments
# are its events), the latest one unless a title picks among them. The change is
# staged the way a create is, so the person sees what will happen and confirms it,
# and it is applied in place - an edit, not a new event.

# The appointment a guide action names, or undef. The app is the thing; its
# appointments are its events. Which one is picked by $opts: "which" is "upcoming"
# (the next one) or "last" (the most recent past one); "at" is a named moment
# ("yesterday around 3:30pm", "a week from now") matched to the closest
# appointment; "title" is a match on the note; the latest by default.
# The WHERE that names one construct's appointments. The stable id is preferred
# when the caller has it, so a rename is not an identity change; rows written
# before app_uuid existed still match by name, but only when they carry no id of
# their own, so one construct's rows never answer for another's.


# The fields a change would set, read from the person's words: "delay" pushes the
# moment later by the length they gave, "when" moves it to a named time instead,
# "duration" sets how long it lasts, "notes" replaces the note. Only the fields
# actually named come back, so the change touches nothing else.


# Plain words for what a change does, shown in the chat and on the staged row.

# Stage a change to an appointment that already exists, the shape promote applies:
# the row names the appointment (kind "update", target_uuid) and carries the fields
# to set.


# The app's running appointment: a start (or a recording) that has begun and has not
# been stopped. This is what "stop it" means - the newest such row, so a stale session
# left open by a stop that never landed is not the one "stop it" reaches.

# When a stop should land: a length from now ("in 10 minutes", "10 minutes") is a
# delay; "now" and anything else (a clock time) is read as a moment.

# Stop the running appointment. Not staged: a stop is a control the person wants at
# once, and it is on the undo stack. Stopping now goes the way the stop button does
# (the writer stops the open start/record, finalises any recording and redraws the
# header); a stop at a named moment is a scheduled stop - a stop_timestamp the alarm
# clock fires when it comes.

# Stage a delete of one of the app's appointments. Staged like any other change, so
# the person confirms which one goes; promote removes it.

# The undo stack: one record per applied change, the appointment's fields as they
# were before it, newest last. One setting, capped, so it syncs but cannot grow.

# Redraw an app on screen the moment a change lands: the header a window shows
# (appointment_header) and the open detail view. appt_header_printer also re-arms
# the app's alarms through its header worker, so a moved appointment fires at its
# new time.

# Apply a staged change in place, remembering how to undo it, then redraw it.

# Apply a staged delete: remove the appointment it names the way the program always
# deletes one - the file rows, the warehouse rows, a payment to unwind, and the
# tombstone that tells the peers - then redraw the app.

# A schedule that waited for clarification: the appointment or bill is already
# made, and this writes the repeats from the clarified phrase. The token names
# the row the form left behind, so the Guide cannot schedule the wrong one.











# ---- runtime (learned) verbs: the executor --------------------------------
# Run one learned verb. Its row (help::learned_verbs) names a closed primitive
# and the parameters; the model's own args may fill {placeholders} or override a
# declared argument. It can never reach anything the primitive list does not name.






# ---- the Coding agent: the Guide's self-healing half ---------------------
# A closed-vocabulary agent that edits the repo and ships the change: read and
# write files, run one checked command, bump the version, commit, push, restart.
# Every verb is a fixed operation with its own guardrail (paths stay inside the
# repo, commands are allow-listed), so the model can never reach a raw shell. It
# runs server-side because git and the release routine have to.


# Resolve a repo-relative path, refusing anything that climbs out of the tree or
# reaches state the agent must not touch (git internals, local config, the blob
# stores whose files are large binaries kept out of git).

# The repo-relative form of a path, for recording what the agent touched.

# Run one coding action and hand back its observation as plain text. The verbs
# are the same ones help::coding_prompt offers (gb::coding_tools).

# The Coding agent's protocols: the baked, tracked copy first (so every machine
# carries them, even though AGENTS.md itself is gitignored), else a local AGENTS.md
# if there is one. Cached by mtime so a run does not re-read it every turn.
our $coding_protocols;
our $coding_protocols_mtime;

# A named conversation's recent turns, kept in one setting so the agent remembers
# what it did last time without a table of its own.

# The Guide associate's threads, the same way (the Coding agent's thread is
# saved by its own route; both kinds land in the one registry below).
# The warranty a guide message expires on: the appointment's own when the thread
# is scoped to an app (its conversation name is app_<name>), otherwise the house
# default. Each message carries it, so old turns drop the way everything else does.


# ---- the agents list ---------------------------------------------------------
# Every named conversation - the Coding agent's threads and the Guide
# associate's - leaves a row in one registry setting: what to call it, when it
# last spoke, how long it is, and a line of what it is about. The registry is
# one setting so it syncs with the rest; the turns stay in the conversation's
# own setting. The list is opened by double-pressing the Assistant button.



# A thread names itself the way a chat thread does: one small model call over
# the first words, with a cut of them as the floor when no model is set.

# Note a conversation: upsert its registry row. A row that has no title yet
# gets one made from the thread's own words; every note carries the turn count
# and a line of the last thing said.


# Threads from before the registry existed (the Coding agent's settings rows):
# give each a row so the history is complete. Only threads with something said.





































# The paired-device plumbing shared by pair, device login, recovery and the
# approval door.








































# The dial and the camera key were removed in v0.1.804: the signed challenge
# is the only remote unlock, and the paper code is the emergency. Nothing here
# starts a camera or accepts a combination any more.

# --- the lock gate ---------------------------------------------------------
# The padlock used to be a client overlay: every route still answered behind
# it. The gate is the server-side half. 'shadow' writes what it would refuse
# and still answers (so the list can be checked on a live machine); 'enforce'
# refuses everything except the ways in.

# --- the app gate ----------------------------------------------------------
# The installed apps are the only browser engines allowed to see /manager. A
# browser may read the public homepage and store, and the embedded devices keep
# their own rotated-token rail. 'shadow' logs what it would deny; 'enforce'
# answers with the open-in-the-app page.



# The other way in is the signed peer rail. A linked machine's request is not
# a browser and has no app key; its proof is the pinned key on its roster row.
# Some peer routes verify that themselves, but the app gate runs first, so a
# peer whose session cookie was lost (or a tunnelled peer whose calls cross a
# restart) was answered with the app-required page before its signature was
# ever read. Require a real signature and an already-pinned key - not the
# trust-on-first-contact path - so a browser quoting a signatorial cannot use
# this door. peer_verify memoises its answer on the stash, so a route that
# checks again after this does not fail on the already-spent nonce.



our $app_schema_done;

# A lock is local to the machine that saw it, but an explicit unlock request
# must reach every screen in the house. This hands the same padlock_key_show to
# the peers over the signed rail; each one broadcasts to its own websockets and
# carries the message on, and relay_id stops a loop. `prompt` marks a request
# the person made on the locked screen (not a lock being announced), so only
# that kind may put a confirmation in front of another device.

# ---- explicit unlock requests --------------------------------------------
# A locked screen no longer pulls every phone and laptop onto the unlock page.
# The person presses Unlock on the locked screen; that writes a short-lived
# request (local cache, never synced) and broadcasts it. A device that is
# already open shows a fingerprint prompt in place, signs the target screen
# open, and goes back to what it was doing. The request is also readable from
# padlock_state, so a phone that was asleep when the button was pressed finds
# it on its next connection.

# The request a media mint may read: the newest one naming this screen. Its
# `source` says which machine holds the screen, and its `tab` says which window
# asked, so the token goes to that window alone.


# One screen opening does not answer a request for another screen, and a
# whole-house open answers every request.

# Clearing a request is also the signal that stops the prompt everywhere. The
# request's own id travels with it, so a screen can tell this one from a newer
# request that happens to name the same device.

# --- Go approvals ---------------------------------------------------------
# A Go pressed in the installed app is already authenticated by the app key,
# but the person may ask for a second factor before the peer ticket is minted:
# this machine's reader, the phone's own Keystore print, or another paired
# device's print. The request itself stays local to this machine; only asking a
# device puts it on the padlock prompt rail, so a laptop fingerprint does not
# buzz every phone in the house.


# One pending Go per session. The row carries the peer the ticket is for, so
# go_status can mint it after the approval; the session names the request so a
# second page cannot redeem someone else's approval.






# Dismiss any device prompt still showing this request (the target is the
# request id, not a screen, so the padlock handler only dismisses and stops).

# A request that came from this machine itself. The phone/tablet is remote, so
# its signature opens the lock; the locked screen's own key may not.

# The server machine's own fingerprint reader, if it has an enrolled finger.
# Checked at most once a minute: fprintd-list talks to D-Bus.
our ($fingerprint_checked_at, $fingerprint_ok);
# A phone that enrolled its Keystore fingerprint: the lock screen should offer
# that fingerprint even when the page itself cannot see the native bridge (the
# button then explains that the app is needed rather than hiding silently).




# The screen's own unlock stamp, used only when the whole house is locked: it
# is what lets one screen open without opening every screen.



# What a target's unlock request is asking about: a manual row always locks;
# a screen timer decides on its own; otherwise the house-wide timer does.

# The lock timers are milliseconds, not secrets: a plain number is readable by
# every worker, and an older sealed value still decrypts. A sealed value is
# opened once per worker rather than on every request: the answer is a pure
# function of (key, ciphertext), so the memo is exact - a rotation or a re-seal
# changes the key id or the ciphertext and misses. It is capped because a lock
# stamp is rewritten whenever the timer moves.
our %padlock_time_memo;

# $state is the truth this request has already established (see
# authentication_passer): { row => the padlock security row, contexts => the
# decoded padlock_contexts }. It saves the duplicate reads without changing
# the answer; callers with nothing prefetched pass nothing.




# One way to open: a paired device's signature, the paper recovery code, and
# the emergency paths all land here. A manual gate locks one device; a target
# names it, an empty target is the house-wide timeout lock. The global timer is
# moved past now either way, so the unlocked screen is not re-locked at once.
# The key material in Security is a second door behind the app: rotating the
# house key, replacing the recovery code, splitting or releasing shares, and
# adding or removing a passkey each ask for the person again. Only a grant
# minted in the last two minutes counts, so browsing the app on one unlock is
# not enough to change how the house can be opened.













# --- local biometric unlock ------------------------------------------------
# The phone's Android app keeps an EC P-256 key in the Android Keystore with
# setUserAuthenticationRequired: the OS will not use it until the person passes
# the fingerprint prompt. The house verifies the key's signature, so this is a
# real factor - unlike the JS confirmation the phone-as-key page uses - and it
# is the one signature a local request may present. It opens only the screen it
# is on, never another device and never the whole house.

# A payment is confirmed by the current device's enrolled biometric key: the
# phone signs a verify challenge, the same proof used before replacing a
# fingerprint. A device with no key has no biometric to ask for, so the signed-in
# citizen is the fallback there; the panel says which path it will use.













# A self-contained page command for a phone-side send: the new bundle's helper
# when it is there, the bridge when the bundle is old but the app is new, and
# the phone's own termux when neither has landed yet - so a message always goes
# out during the hand-over from termux-sms-send.

# This machine's radio. termux-telephony-deviceinfo is the same source the
# Phone app trusts: a phone answers phone_type=gsm/cdma with a ready SIM, a
# wifi-only tablet answers phone_type=none. Which is why a caller that needs a
# radio asks the bridge rather than the platform name.

# A peer's radio, asked before an MMS is handed over: a laptop with a phone and
# a wifi tablet must not send the picture to the tablet and call it a phone.


# The app's FileProvider is rooted at getFilesDir() (/data/user/0/...), while
# subs::home() and TermuxConstants say /data/data/.... Hand the bridge the
# provider's own spelling so getUriForFile finds the file; a path outside that
# root is what made the share() hand-off fail.

# MMS carriers are happiest below about a megabyte; an original photo can be
# several. A copy is shrunk to fit (and auto-oriented), leaving the filed
# original alone. No ImageMagick, or a failure, keeps the original for the
# bridge's own Bitmap compression to handle.





# The house encrypts files at rest, renaming them to random .enc paths; an
# attachment carried on a message names its file by uuid, so the current paths
# are read from the filing the upload made, not from the snapshot the page sent.
# Returns (f, thumb, encryption_standard) - f is the current path, possibly .enc.

# An attachment's file as plain bytes on disk: encrypted at rest, so a copy is
# decrypted to the house's sms_parts drawer and that path is returned.

# An attachment on the sms road: on the phone the parts are already local files
# the bridge reads; anywhere else they are read, base64'd and relayed to the
# phone's /manager/sms/mms. A phone is found by asking its radio, not by taking
# the first mobile peer (the house may also hold a wifi-only tablet).

# The house row a message was filed as before it touched the sms stack wears
# the system's own identity once the phone has filed the same message: the
# system thread keeps the sent copy, and this row IS that message here, so the
# poll, a re-read and every other machine see one message rather than two. The
# system's date also becomes the row's time, so a poll matches it exactly.


# ---------------------------------------------------------------------------
# LoRaWAN: the Chat app's radio mode.
#
# The T-Deck carries an SX1262 and RadioLib's LoRaWANNode; JawnOS keeps the
# network credentials, pushes them to the deck that is on the LAN, and offers a
# webhook a network server (TTN, ChirpStack, Helium) can post uplinks to. The
# message itself is filed on the `lora` contact, the same way sms is filed on a
# number and a ticket on its uuid, so the conversation survives a restart.
# ---------------------------------------------------------------------------



# The T-Deck's HTTP server uses the same port the embedded fleet already knows.






















# Apply a peer's deletions: its queued `deletions` and its durable tombstone
# log. Used by the handshake and by the v3 row pull, so a machine that never
# handshakes the donor (out of its hub's range) still learns what was deleted.
# The reader's confirmed cursor is advanced here, which is what lets the donor
# purge the tombstones once every machine has read past them.

















# ---- the keyboard's vault ---------------------------------------------------
# A saved login or field is one row: the non-secret metadata used to offer it
# (app, origin, kind, label, hints) and a note_encrypter() payload holding the
# values. The payload is sealed with the house key, so it rides the ordinary
# sync rail - and a remote backup - without the secrets being readable there.
#
# Scope is the security rule: a row with an `origin` belongs to that site and is
# only offered for that site; a row without one belongs to that app package. A
# browser package may not save a password without a site, because the keyboard
# cannot see the address bar and a package-wide Chrome password would be offered
# on every site (the Autofill service is what reads the web domain).

our %credential_browser_app = map { $_ => 1 } qw(
	com.android.chrome com.brave.browser com.microsoft.emmx org.mozilla.firefox
	com.sec.android.app.sbrowser com.opera.browser com.opera.mini.native
	com.duckduckgo.mobile.android com.vivaldi.browser com.ecosia.android
);








# Is a measure code a currency (a fiat code, a coin, or a crypto asset)?


# ---- the keyboard's units of conversion -----------------------------------
# A unit resolved from whatever a person typed: the registry key ("JPY", "L",
# "m"), the same code in another case, the unit's own name, or its plural.

# The old calculator's formulas are directed ("x * 1000mL" says one litre is a
# thousand millilitres), so the graph carries each edge and its reciprocal and a
# short walk reaches any unit of the same kind (Litre -> mL -> teaspoon).

# units of $to per one $from, walked over the formula graph




# The live snapshot gives every fiat pair and every coin in one read: a code's
# rate is the reporting currency per one unit, so the pair is the ratio of the
# two. While no snapshot exists yet, the old calculator's static formulas answer.




















# The app gate in shadow mode writes what it would refuse. A browser with no app
# key sends every request through here, so a repeating poll wrote the same line
# on every tick (tens of thousands of lines in the log). Name each
# (method, path, caller) once a minute instead: a route that would be refused is
# still recorded, without the repeated write becoming a per-request cost.
our %app_gate_shadow_seen;


























# ---- USB flashing -----------------------------------------------------------
# The esp32 boards are plugged into this machine, so the panel cannot flash them
# itself: it asks the manager, which runs the PlatformIO upload and then polls the
# log for esptool's percentage lines.




































# ---- marker sessions ---------------------------------------------------
# A session is one cache row (context 'sessions', subcontext = the session
# id) holding every marker layer as a PNG data URL, so a drawing outlives the
# window and can be recalled from the sessions panel. The cache table lives in
# the encrypted database, so nothing here needs the network or the filesystem.










# ---------------------------------------------------------------------------
# A headless health read: what a supervisor or `jawnosctl status` needs to tell
# "the tree is up and current" from "it is wedged" - the running version and
# commit, how long it has been up, the database and its write-ahead log, and
# each peer's last reported version and link state. No setting value crosses
# here. A server has no session and no login, so the route rides the gate-exempt
# rail (hooks.pl) and gates itself: a loopback caller (the machine's own CLI or
# monitor), an approved browser session, or a signed peer (peer_verify against
# the roster) - everyone else is refused.
# ---------------------------------------------------------------------------









# The house address book. Every machine reports its signed presence here when it
# boots, changes network or wakes; the server merges it and pushes the address
# directory to the other machines. A peer that cannot reach the server relays
# the same signed notice, and a machine whose stored name has gone stale asks
# here rather than waiting out a timeout. All three routes authenticate the
# caller with the signed peer rail (or a loopback caller) inside the handlers.



# A lot of the migration list below predates the schema, so on a database built from
# database/schema.sql the column or index it wants to add is already there and
# SQLite refuses the statement ("duplicate column name", "index ... already
# exists"). Those refusals are warnings, not errors, so they never reached the eval
# around the runner -- they just filled the log on every unlock, and a real failure
# would have been one line among dozens. Statements that are already satisfied are
# skipped now, and everything that still runs is worth looking at.










# The app's WebView trusts the house certificate for page loads
# (onReceivedSslError), but a WebSocket handshake never reaches that callback,
# so wss:// to the self-signed manager fails inside the app. The socket server
# also listens plainly on 127.0.0.1; Chromium treats loopback as trustworthy,
# so an https page may open ws:// there. A Secure session cookie is not sent on
# that handshake, so the page carries a short-lived token that restores the
# session for the socket.


















# Log a peer back in so the session cookie we keep for it is fresh. The relay and
# the sync rail post to a peer's ordinary routes carrying that cookie, and those
# routes are gated; the cookie lapses without a word - most often when the peer
# renames its database, which the session remembers - so a relayed request comes
# back with the Gate page where the route's reply was expected. Reuses the same
# credentialed login (the peer's /sesh_check) the reconnect path uses.

# The sync topology is a house setting (`sync/topology`, so the settings merge
# carries it to every machine). The Dev panel writes one shared `device => 'all'`
# row; an older override can still sit on a machine's own device row or in
# `__president/sync_topology`, so read those as fallbacks. A blank or unknown
# value means auto.

# A hub is healthy enough to collapse a spoke's pass to hub-and-spoke when its
# last handshake is recent and, if we reach it through a tunnel, that tunnel still
# has a fresh pong (the same freshness the tunnel checker reads).

# Pick the hub once per pass and persist it, so roster churn cannot silently move
# the mesh's centre. A server is its own hub; a spoke learns its server's
# signatorial from the roster and keeps the saved one while its row is recent.





our $ws_server;

# Fill in the variables a text editor says: ${vape}->duration; becomes the
# setting itself, shown as an illusion that remembers what was written, so a
# click hands the words back. The name may wear braces and a dollar or neither
# - ${vape}->duration, $vape->duration and vape->duration all name the same app
# and setting, read the way the manager reads names. A dollar with a digit
# behind it - $5, $500 - is a number, not a name, and is left alone. A word
# whose setting does not exist is left exactly as it was written, never eaten.
# The whole text comes back with the token its spans wear, so the caret can be
# put back after the last one; the token is undefined when nothing was found.
#
# $self->total names the thing the editor is about rather than an app: the
# appointment it sits in, the quote/invoice and its customer the compose window
# was opened for, or the person a letter is addressed to and the newest thing
# they were sent. The context rides on the editor's magic_vars attribute; when
# it names no record - a template, before it belongs to a document - the words
# are left as written, because a template is where they are meant to wait.
#
# Two flourishes for fields that are not rich editors. 'plain' answers with the
# value itself, no illusion, and does not need the semicolon - it is for the
# compose subject, which cannot wear spans and is prose. 'self_only' refuses
# the app->setting spellings and only says $self: a subject is prose, and
# prose must not have its arrows eaten. Tags are stepped over, so an illusion
# already in the text keeps its remembrance of the words through a later pass.

# The context an upgraded text editor carries in its magic_vars attribute:
# comma separated key:value pairs. The keys name the kinds of thing an editor
# can be about - appointment, document, customer, template. It is deliberately
# small, and both sides of the wire build or read it in one line.

# The newest thing a customer was sent - whatever carries numbers, so a quote,
# invoice, receipt or the like - is what a letter about them is about. Only
# papers this house printed are asked for, by the numbers they carry.

# What $self->name and its brothers answer for a context. An appointment
# answers from itself and its settings, and names its app rather than a record -
# the newest record that app wrote is the one its numbers come from; a document
# answers from its numbers (total, balance, the id it printed under) and from
# its customer (name, email, phone, address); a letter to a customer answers
# the same way, with the newest document standing in for the one the words are
# about; a context that names no record answers nothing, so the words wait to
# be said by whoever applies them.

# The legend an upgraded text editor shows across its top: the names $self
# can say in this context, each with the value it would show right now when
# there is something to resolve it against. A template is shown the same
# names without values - they are what it will say once it belongs to a
# document, and seeing them is how a template is written at all.



# The bytes a key press should send down the pty. The browser now sends those
# bytes itself, so this only has to keep an older page working: a whole-string
# key name is mapped, a modifier name is dropped (it is not input), and any
# other string passes through unchanged.

# Only values that can name a host, an ssh login and a port get through; the
# start below passes them as separate argv entries, never through a shell.



# The live session list the Terminal settings panel shows. The websocket worker
# writes it, the manager route reads it; an ended shell is removed here.







# Kept for callers from older code: sessions now start when a window opens.





if ($ENV{PURPOSE} && ($ENV{PURPOSE} eq 'alarm' || ($ENV{PORT_ENV} eq 'development' && $ENV{PURPOSE} eq 'main'))) {
	#require './perl/Alarm.pl';
	#&Alarm::alarm_clock();;
}


if ($ENV{PURPOSE} && ($ENV{PURPOSE} eq 'websocket' || ($ENV{PORT_ENV} eq 'development' && $ENV{PURPOSE} eq 'main'))) {
	# Sessions are ptys owned by this worker: a restarted worker has none, so
	# the list a person sees must not promise shells that no longer exist.
	$gb::terminal_sessions = {};
	&subs::cache_set({ app => 'terminal', context => 'sessions', warranty => '-1d' }, {});


	my %buffers;

	# These sockets are how a manager worker hands a live push to the websocket
	# worker that holds the page's socket. The websocket worker must bind them
	# *itself*, after the fork: bound earlier (in the process that loads this
	# file), the pre-fork server's start registers the listeners as MOJO_REUSE
	# descriptors and the forked worker then "reuses" a file descriptor while
	# no path exists on disk. Every push then looked delivered to the caller
	# while the page never saw it - the phone's silent MMS failure. Bound here,
	# on the worker's first tick, the path is real; and a worker that is
	# recycled leaves a stale path behind, so any path that stops answering is
	# bound again. (See ws_server_socket: it also clears this path from
	# MOJO_REUSE, which is what made the reuse win over a real bind.)
	my $ws_binder_pid = $$;
	my $ws_bind_all = sub {
		my ($check) = @_;
		foreach my $ws ( @{$gb::ws_apps} ) {
			my $file = $gb::tmp_dir . '/ws/' . &subs::path_name($ws);
			if ($check && -e $file) {
				my $probe = IO::Socket::UNIX->new(Peer => $file, Type => SOCK_STREAM);
				if ($probe) { close $probe; next; }
			}
			$ws_server->{$ws} = &ws_server_socket({ app => $ws });
		}
	};
	# only a forked worker binds: the loader's own loop never accepts, so a
	# listener it held would swallow a push with no page socket to deliver to
	Mojo::IOLoop->next_tick(sub { $ws_bind_all->(0) if $$ != $ws_binder_pid });
	Mojo::IOLoop->recurring(5 => sub { $ws_bind_all->(1) if $$ != $ws_binder_pid });
	sub ws_server_socket($data) {
		my $app = $data->{'app'} || 'general';
		my $folder = $gb::tmp_dir . '/ws';
		`mkdir -p $folder` unless -e $folder;
		my $file = $folder . '/' . &subs::path_name($app);
		# a reused descriptor wins over a real bind in Mojo's listen(), and the
		# pre-fork server put this path in MOJO_REUSE from the loader's own
		# listeners; drop it so the bind really creates the path
		if ($ENV{'MOJO_REUSE'}) {
			$ENV{'MOJO_REUSE'} = join ',', grep { !/^unix:\Q$file\E:/ } split /,/, $ENV{'MOJO_REUSE'};
		}
		unlink $file if -e $file;
		my $server = eval {
			Mojo::IOLoop->server({ path => $file } => sub ($loop,$stream,$id) {
				$stream->handle->autoflush(1);
				$stream->high_water_mark(8 * 1024 * 1024);
				$buffers{$id} = '';
				$stream->on(read => sub ($stream, $bytes) {
					$buffers{$id} .= $bytes;


					while (1) {
						last if length($buffers{$id}) < 4;

			      my $payload_length = unpack('N', substr($buffers{$id}, 0, 4));

			      # If we don't have the full payload yet, wait for next event loop tick
			      last if length($buffers{$id}) < (4 + $payload_length);

			      # Extract header and data cleanly using 4-argument substr for speed
			      substr($buffers{$id}, 0, 4, '');
			      my $sereal_blob = substr($buffers{$id}, 0, $payload_length, '');

			      my $wsm = eval { $decoder->decode($sereal_blob) };

            if ($@) {
                warn "Worker $$: Failed to parse Sereal: $@";
                next;
            }
						&websocket_sender($wsm);



						$stream->write($wsm->{'uuid'}) if defined $wsm->{'uuid'} && $wsm->{'uuid'};
					}
				});
				$stream->on(close => sub {
					delete $buffers{$id};
				});
			});
		};
		my $err = $@;
		$log->error('ws socket ' . $file . ' could not bind: ' . ($err || 'no acceptor')) if $err || !defined $server;
		return $server;
	}

	my $mailfile = $gb::tmp_dir . '/ws/mailws';

	my $mailws_server;
	my $mailws_listener = sub {
		# the loader no longer binds the per-app sockets (a fork child must),
		# so this process makes the folder rather than finding it made
		my $ws_folder = $gb::tmp_dir . '/ws';
		`mkdir -p $ws_folder` unless -d $ws_folder;
		unlink $mailfile if -e $mailfile;
		$mailws_server = eval { Mojo::IOLoop->server({ path => $mailfile } => sub ($loop,$stream,$id) {
			$stream->handle->autoflush(1);
			$stream->high_water_mark(8 * 1024 * 1024);
			$buffers{$id} = '';
			$stream->on(read => sub ($stream, $bytes) {
				$buffers{$id} .= $bytes;


				while (1) {
					last if length($buffers{$id}) < 4;

			      my $payload_length = unpack('N', substr($buffers{$id}, 0, 4));

			      # If we don't have the full payload yet, wait for next event loop tick
			      last if length($buffers{$id}) < (4 + $payload_length);


			      # Extract header and data cleanly using 4-argument substr for speed
			      substr($buffers{$id}, 0, 4, '');
			      my $sereal_blob = substr($buffers{$id}, 0, $payload_length, '');
			      my $m = eval { $decoder->decode($sereal_blob) };
		        if ($@) {
		            warn "Worker $$: Failed to parse mail message: $@";
		            next;
		        }

					# one sender matches it against every tab's address
					my $count = &mailws_sender($m);

					# mail_arrival marked what the server just accepted: the tab socket
					# hears it for the start menu dot, and when no mailbox is watching
					# that thread the regular notification speaks
					if ($m->{'arrival'}) {
						&Websocket::send('tab', { type => 'mail_arrival', uuid => $m->{'uuid'}, message => $m->{'arrival_message'}, timestamp => $m->{'timestamp'} || &subs::rightNow() });
						unless ($count) {
							&notification_sender({ app => 'mailbox', role => 'all', title => 'Mail', message => $m->{'arrival_message'} || 'New mail', image => '/images/decipherable/envelope.png' });
						}
					}

				  $stream->write($m->{'uuid'});
				}
		    });
				$stream->on(close => sub {
						delete $buffers{$id};
				});
			});
		};
		$log->error('mailws could not bind: ' . $@) if $@;
	};
	$mailws_listener->();
	# like the per-app sockets above, the mail socket is put back up if it dies
	Mojo::IOLoop->recurring(5 => sub {
		my $is_running = defined Mojo::IOLoop->acceptor($mailws_server) ? 1 : 0;
		if (!$is_running) { $mailws_listener->(); }
	});
	sub websocket_close($app) {
		$app = $app;
		unless (grep { $app eq $_ } @{$gb::ws_apps}) {
			if (scalar keys %{$gb::ws->{$app}} == 0) {
				Mojo::IOLoop->remove($ws_server->{$app});
				my $folder = $gb::tmp_dir . '/ws';
				my $file = $folder . '/' . &subs::path_name($app);
				`rm -R $file` if -e $file;
				delete $ws_server->{$app};
			}



		}
	}
}


# The construct columns in the fixed order a channel tuple names them: the
# plural keys sorted, which is what mail_channel_key joins and what a list
# row's uuid concatenates. Changing $gb::social_constructs changes the tuple,
# so every place that builds or splits one asks here instead of naming six.

# The social constructs with every value filled: what the client leaves out
# falls back to the same default the mailbox reader reaches for, so a tab with
# its pickers hidden (a phone) still has an address a message can find.

# The house's trust rule for words: a citizen or a resident holds a ticket
# this house issued and named, so what they write is filed - stored, synced
# and readable later like any mail. A guest is a visitor whose words are only
# ever heard live by whoever is tuned in: they are never written down.
# Moving a privilege between the two lists is the whole policy.

# A dialled picker: at least one social construct chosen by hand. A tab with
# an empty picker has no dial of its own - a guest on their ticket, say - not
# a tab dialled to the defaults.

# One tuple of construct values names one thread; this is how two dials are
# compared, whatever order their keys arrived in.

# The dials this house advertises to guests, each filled to the same six
# values a message carries, so comparing one to a dial is comparing threads.

# A channel is public only when the house advertised exactly this tuple; a
# guest may watch or write to advertised dials and nothing else.

# The human name of a dial: its construct values in the order the dial lists them.

# An unfiled letter's pace: a guest speaks at most this many times a minute.
our %mailws_untrusted_rate = ();

# What one mail tab is watching when it connects: a guest watches a dial the
# house advertises when they tuned one, and their ticket otherwise; everyone
# else watches whichever of a phone number, an email address, a contact or a
# social construct chain their section put in the url.

# The constructs a message is addressed to - undef when it wears a phone, an
# email or a contact instead.


# Deliver one mail message to every tab it is addressed to. The registry is
# flat now - one entry per browser tab - so the address does the matching
# instead of a hand-walked nest of hash levels, and every door a message can
# come through (a browser, the mail unix socket, the depublicizer) ends up
# here.




if ($ENV{PURPOSE} && ($ENV{PURPOSE} ne "alarm" && $ENV{PURPOSE} ne "watch" && $ENV{PURPOSE} ne "teletype")) {

	app->sessions->samesite('lax');
	$ENV{MOJO_MAX_MESSAGE_SIZE} = 1023423423473741824;
	app->renderer->cache->max_keys(0);
	app->sessions->encrypted(1);
	app->secrets($gb::secret_maker);
	app->sessions->cookie_name($ENV{'cookie_name'});
	if ($config->{'environment'} eq 'production') {
		app->log->level('error');
	} else {
		app->log->level('debug');
	}

}
else {
	1;
}


1;