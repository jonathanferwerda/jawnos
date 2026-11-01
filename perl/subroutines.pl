#!/usr/bin/env perl
package subs;

BEGIN {
	require Cwd;
	require File::Basename;
	# absolute, from this file's real path: a later chdir cannot break it, and a
	# symlinked copy (the test sandbox) still finds the tree's own lib/. This file
	# lives in perl/, so lib/ is one level up.
	unshift @INC, File::Basename::dirname(Cwd::abs_path(__FILE__)) . '/../lib';
}

use strict;
use warnings;
use utf8;

use Unicode::Normalize qw(NFC);
use Encode qw(encode_utf8);
# This file used to pull in Mojolicious::Lite, whose import built an app object
# and monkey-patched the DSL into package subs. It is a library: load Mojolicious
# for the modules the app fragments (Websocket.pl and friends) expect, but no Lite.
use Mojolicious;
use List::Util qw(shuffle);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use Text::Unidecode;

use MIME::Base64;
use Time::Duration;
use Date::Parse;
use Time::Piece;
use Time::Local;
use Fcntl qw(:flock);
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Crypt::Simple;
use Crypt::PK::ECC;
use Digest::SHA qw(sha256_hex);
use File::Slurp;
use File::Find;
use File::Copy;
use File::Path;
use File::Type;
use Mojo::JSON qw(decode_json encode_json);
use JSON::PP ();
use Mojo::IOLoop::ReadWriteFork;
use Mojo::SQLite;
use Minion;
use Data::Dumper;
use Time::HiRes qw(gettimeofday time);
use Mojo::IOLoop;
use Clone qw(clone);
use MIME::Base64;
# The mail stack is heavy and used by exactly two routines (email_receiver and
# email_send). Loading it per worker at boot is pure waste on a box that never
# touches IMAP/SMTP, so each routine requires what it needs the first time it
# runs. All five are used only as class methods, so there is no import to keep.
use IO::Socket::UNIX;
use IO::Select;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
use IPC::Open2;
our $encoder = Sereal::Encoder->new({ compress => SRL_ZSTD, compress_level => 3 });
our $decoder = Sereal::Decoder->new();
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
no warnings 'uninitialized';
no warnings 'once';
# The domain layer in lib/ (lazy: the Loader AUTOLOADs each module on first
# call), so no caller needs Manager.pl for its functions. This is before the
# requires below: gb.pl calls subs::rightNow() while it compiles.
require JawnOS::Domain::Loader;

require "./perl/gb.pl";
require "./perl/Websocket.pl";
require "./perl/language.pl";

our $config_file = read_file('./config.json');
# `our`, not `my`: the domain modules in lib/ are in this package and read the
# same config (notification_sender, embedded_toggle and friends used to be in
# Manager.pl).
our $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
our $resolve_when_residual = '';   # what resolve_when could not read as a date (see date_leftover)
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
our $universal_splitter = $gb::universal_splitter;

our $device = &device_setter();


# Request-scoped settings read-through memo (see setting_grabber). Cleared at
# each request boundary by hooks.pl; off outside requests so long-lived
# utility processes never serve stale settings.
our %setting_memo;
our $setting_memo_on = 0;
# Two radios (the desktop bridge daemon and the manager's own listener, or an
# older board that still ran both of its input scanners) can deliver the same
# physical switch/button event twice. One flick then toggles the app - and
# clicks the relay - twice. Remember what was applied for a moment so the same
# event is only acted on once.
our %ble_event_seen;

# Model rows in the order a chooser should read them: alphabetical by the name the
# user sees. Kept as a routine rather than a `sort { $a->{'name'} }` in a template
# because Mojo extracts a template's stash keys into lexicals, so a template whose
# stash holds `a` (the app name) would sort the app name instead of the rows
# (the same trap written up in templates/configure/packaging.html.ep).


# The filesystem form of a name. App names are keys first: they may contain
# slashes, colons, semicolons, quotes and anything else a person can type. A
# file or folder cannot take all of those safely, and a shell command must not
# see them either, so this percent-encodes every byte that is not a letter,
# mark, number or one of . _ -. Letters of any script stay as themselves, so an
# existing café/中文 folder keeps its name. The encoding is injective, so two
# distinct keys never share a folder.

# The interface language: the house-wide row first, then the person's own
# ("Me") row, then any device row, then the language chosen at install, then
# English. setting_grabber's request-scoped memo makes the repeated asks in
# one page cheap; reading it per call also means a change made in one worker
# is seen by every other worker on the next request, not after a restart.





# A translated label. Placeholders are {0}, {1}, ... so the same catalog can
# feed Perl templates and JavaScript.


# Translate a full UI or help string through the generated catalog. This is the
# server-side counterpart of jawnosT(): it is for printed documents, mail and a
# template that needs the text before the browser can translate the DOM.



# Translate text or a batch of UI strings through the configured Guide model.
# Results are cached in the cache table, so the same label is paid for once.
#
#   &translate_engine({ to => 'French', text => 'Save' })
#   &translate_engine({ to => 'fr', strings => [ 'Save', 'Cancel' ] })
#
# Returns { ok => 1, to => {...}, translations => {...}, cached => N,
# translated => N, model => ... } or { ok => 0, error => '...' }.


# One model turn over a list of strings. Returns a hash of source => translation.







# Percent-encode a filesystem name for a URL. Names that come from a directory
# walk are decoded to characters (see Music::process_file), and a Mojolicious
# template is a character string, so encode back to UTF-8 bytes first: url_escape
# would otherwise escape a multi-byte character's codepoint (Æ -> %C6) instead of
# its UTF-8 bytes (%C3%86). Plain ASCII and already-byte strings pass through.

# encode_json returns UTF-8 bytes, but a Mojolicious template is a character
# string: interpolating those bytes upgrades them as Latin-1 and mangles every
# non-ASCII value in the data (an "Ænima" tag renders as "Ãnima"). Decode back to
# characters for the template, the same reason process_file decodes the names it
# hands the window.


# A name printed inside HTML text or an attribute. The stored key keeps every
# printable character, so the renderer must encode the markup characters rather
# than rely on the key being safe.







# Numbers people write as words, turned into digits so the same duration reader
# can take "five minutes" or "2 hours". Only the number itself is rewritten; the
# rest of the phrase is left for the unit reader.


# A duration a person can read several ways. The element carries the span in
# milliseconds and the client turns it through the short form, all hours and all
# minutes when it is clicked, remembering the reading for that window; the
# server's own reading is the first paint. A negative span (a shortfall, a
# moment read the other way) keeps its minus in `sign`, because the client's
# readings fold a sign away when they take the size.

# A length written the many ways people write one: "2d", "2 days", "2days",
# "1 hour 30 minutes", "1h30m", "in 2h", "-3h", "a week", "1.5d". The
# compact forms are what the app stores; the spelled forms are what a person
# types in the appointment and budget inputs.
#
# A single capital M is a month while a lower-case m is a minute, and D is a
# decade while d is a day, as everywhere else in the app. Months and years step
# the real calendar (February is 28 or 29; 29 February shortens to the 28th), so
# a length read here agrees with a schedule stepped elsewhere.
#
# Returns milliseconds (a duration), not a timestamp; a number with no unit keeps
# the old contract and reads as minutes.
our %time_abbrev_ms = (
	millisecond => 1,
	second      => 1000,
	minute      => 60 * 1000,
	hour        => 60 * 60 * 1000,
	day         => 24 * 60 * 60 * 1000,
	week        => 7 * 24 * 60 * 60 * 1000,
	decade      => 10 * 365 * 24 * 60 * 60 * 1000,
	century     => 100 * 365 * 24 * 60 * 60 * 1000,
);

# The unit a timing token names, normalised to one word. The single letters are
# case-sensitive, so they are matched before the lower-case spellings.



# A calendar month's length. February is 29 in a leap year, and is_leap_year
# carries the century rule: 2000 is a leap year, 1900 and 2100 are not.

# Move a moment by whole calendar units. Months and years keep the day of the
# month, shortening to the month's last day when it is shorter (31 January ->
# 28 or 29 February) and returning to $anchor_day on later months when one is
# given (28 February -> 31 March). Days and weeks step through the local
# calendar, so daylight saving neither drifts the hour nor shortens a day.




# The session a stop should close: the NEWEST open start/record for the app - the one
# the person is running now. The appointment header carries this so a stop names its
# own session, and every machine in the mesh closes that same row instead of each
# resolving "the open session" against its own, possibly lagging, copy of the
# database. The newest, not the oldest: a session left open by a stop that never
# landed is the oldest, and naming it would make every fresh stop close the stale one.

# The row a stop closes, resolved the same way wherever the stop runs (manager_reset
# and appointment_writer both call this): the session the client named, carried
# through the relay so every machine closes the same one. A stop that names a session
# closes that row and only it - a session already closed (a stop delivered twice, or
# one this machine has not synced) matches nothing and the stop does nothing, so a
# duplicate can never reach another session. Only a stop that names none falls back to
# the NEWEST open start/record for the app at or before the press. One row, never the
# backlog, and never a stale open session swept up by a nameless or repeated stop.

# A queued replay can deliver the same start twice a fraction of a second apart
# (a toggle replayed after a sleep, say). The start branch used to mint a fresh
# uuid every time, so the stop closed the row it named and the twin stayed open
# on whichever machine had received the other write - visibly "still running"
# long after the person stopped it. These two selectors make one press mean one
# session: an open row already close to this start is reused instead of a twin
# being written, and a stop retires any twin beside the row it closed.




our $cached_sockets = {};

# Per-process backoff for a watch socket that is down. A missing or refused
# socket used to be dialled on every send and the whole payload was dumped to
# the log each time; under a busy tick that is a loop of encode + Dumper + log
# I/O and can pin a core. Keyed like the socket cache, reset by a success.
our $socket_retry = {};

# ---- requests the worker supervisor watches ---------------------------------
# A prefork worker handles one request at a time, so a handful of slow requests
# (a model answer, an IMAP fetch) can hold every worker and leave the UI queued
# behind them. Each main worker keeps a marker file for as long as it is inside
# a request; President.pl's supervisor reads those markers and asks the prefork
# manager for another worker when all of them are busy (see prefork_autoscale).
# The file is named by pid so a marker left by a dead worker can be spotted, and
# it lives under ~/.president, which the master wipes at boot.
our $request_busy_depth = 0;

# A request that hands its wait to a child (or to an async user agent) no longer
# blocks this worker, so release the busy marker before it yields. The matching
# after_dispatch sees the cleared flag and leaves the count alone.

# Run a slow piece of work in a child process and render its answer when it
# comes back, so this worker can serve other requests while it waits. The work
# callback must not touch the controller or this process's state: it is a
# forked copy, and only the values it returns cross back. The render callback
# runs here, in the worker, once the child has finished. The HTTP contract is
# unchanged - the caller still gets the same JSON, only later - but the worker
# is free in between, which is what keeps the rest of the UI answering.
# A burst can ask for one of these per visible row (the inventory summaries),
# so a few at a time per worker and the rest wait their turn: each child is a
# fork of the worker, and a phone cannot afford twenty of them at once.
our $deferred_children = 0;
our @deferred_jobs;




our $random_seeded_for;



# Every span the app offers: a span is a count of a unit, so "2month" is two
# of the 30 day months, and the odd ones do not read that way.  time_span() is
# the one door into them, which is why a twenty two month can no longer mean
# twenty one, and time_span_list() is what the pickers are built from.
our $time_units = {
	second => 1000,
	minute => 60 * 1000,
	hour => 60 * 60 * 1000,
	day => 24 * 60 * 60 * 1000,
	week => 7 * 24 * 60 * 60 * 1000,
	month => 30 * 24 * 60 * 60 * 1000,
	year => 365 * 24 * 60 * 60 * 1000,
};

our $time_odd_spans = {
	'15second' => [ 15 * 1000, '15 Seconds' ],
	'30second' => [ 30 * 1000, '30 Seconds' ],
	'45second' => [ 45 * 1000, '45 Seconds' ],
	'fortyfiveminute' => [ 45 * 60 * 1000, '45 Minutes' ],
	moon => [ 28 * 24 * 60 * 60 * 1000, 'Moon' ],
	season => [ 90 * 60 * 60 * 1000, 'Season' ],
	quarter => [ (30.5 * 3) * 60 * 60 * 1000, 'Quarter' ],
	decade => [ 10 * 365 * 24 * 60 * 60 * 1000, 'Decade' ],
	century => [ 100 * 365 * 24 * 60 * 60 * 1000, 'Century' ],
	millenium => [ 1000 * 365 * 24 * 60 * 60 * 1000, 'Millenium' ],
	era => [ 10000 * 365 * 24 * 60 * 60 * 1000, 'Era' ],
};

our %time_span_table;



# A repeating interval, read the many ways people write one: "1d", "2 weeks",
# "monthly", "quarterly", "30days" and the old payable spellings. The count
# comes back with a calendar unit, so the caller can step it with
# calendar_shift and keep month lengths and leap February honest.
our %interval_words = (
	daily       => [ 1, 'day' ],
	hourly      => [ 1, 'hour' ],
	weekly      => [ 1, 'week' ],
	fortnightly => [ 2, 'week' ],
	biweekly    => [ 2, 'week' ],
	monthly     => [ 1, 'month' ],
	bimonthly   => [ 2, 'month' ],
	quarterly   => [ 3, 'month' ],
	yearly      => [ 1, 'year' ],
	annually    => [ 1, 'year' ],
);


# Read a schedule the appointment input and the payable scheduler share:
# "<interval> for <horizon>". "1d for -2w" is every day for two weeks;
# "monthly for 1y" is the first of each month for a year. "-2w" and "2w"
# both mean two weeks ahead, because a horizon runs forward from the first
# occurrence. Either part may be left out and "once" means no repeat.

# The moment a schedule's horizon names, counted forward from its first
# occurrence. A written date ("dec 31") is read as a date; anything else is a
# length and runs ahead whichever sign it was typed with.

# The next occurrence of an interval, calendar-aware for months and years.

# ---- schedules written in words -------------------------------------------
# A schedule can also be a phrase: "every third Saturday of the month", "the
# next five full moons", "my mom's next 5 birthdays". The Guide reads the
# words into a small plan and the functions below do every piece of date
# arithmetic, because a model is good at language and poor at counting dates.


# The day-of-month of the $nth $wday (0 Sunday .. 6 Saturday) in a month;
# $nth -1 is the last one. 0 when the month has no such day.

# Easter Sunday in the Gregorian calendar (the anonymous algorithm).

# The days the house treats as holidays, keyed YYYY-MM-DD. The built-in set is
# a common US/Canada list; "Name = date" lines in the __president holidays
# setting add the family's own (a date with a year is one day, a month and day
# repeat every year). "except on holidays" skips these days.

# A full moon via Meeus's lunar phase series (the main periodic terms), accurate
# to about a minute. $k is the lunation number; the same k is a full moon.

# The full moons after a moment, oldest first.

# The moment a named person reaches an age, from a saved birthday.

# The Guide reads a phrase into one of the plans recurrence_expand knows. The
# plan is remembered for the day: a schedule typed on every press of the same
# app's usual phrase should not cost a model call each time.
our %recurrence_plan_cache;

# The horizon a plan names: an absolute date, or the day a person reaches an age.

# Turn a plan into the repeat timestamps after $start. Returns the list, the
# horizon, and a question when the plan cannot be carried out.

# The one entry point both the appointment form and the payable form call.
# Compact text stays on the fast parser; anything else is read by the Guide.

# ---- a schedule waiting for the Guide to finish it ------------------------
# When a phrase cannot be read yet, the appointment or bill is already made and
# the facts needed to finish it later are held under a token. The Associate is
# handed that token, asks its question, and calls the schedule action with the
# clarified words; nothing is written until then.





# The rows a page of periods walks: the periods around now first (the nexts,
# this one, the lasts), then the block of periods before or after it, so
# scrolling a graph sideways carries on along the timeline.  A row that names
# periods ahead counts from the request forward, so the part of this period
# already spent belongs to "this" and never shows in a row past it.


# What a picker shows: the whole family is still readable by time_span(), but
# scrolling three hundred of them is not a picker, so this is the handful per
# unit that gets reached for, in size order.  Add or drop names here freely.
our $time_picker_spans = [ qw(
	second 15second 30second 45second
	minute fiveminute tenminute fifteenminute thirtyminute fortyfiveminute
	hour twohour threehour sixhour ninehour twelvehour fifteenhour eighteenhour twentyonehour twentyfourhour
	day twoday threeday fourday fiveday sixday sevenday
	week twoweek threeweek fourweek
	moon month twomonth threemonth sixmonth ninemonth twelvemonth
	season quarter
	year twoyear fiveyear tenyear
	decade century millenium era
) ];



# A warranty that never expires, in the epoch milliseconds every warranty here
# is compared in. Year 3000 is a constant on purpose: no expiry check or sweep
# will ever reach it, and two machines comparing the same ticket agree. The app
# tickets carry it, so the desktop and mobile apps never ask for a login again.

# The age a phrase names, if it names one: "when I'm 60", "when I am 60", "60yo",
# "60 years old", "my 35th birthday". The caller matches the lowercased phrase
# with its apostrophes already dropped, so "I'm" reads as "im".

# The moment the person is a given age: the present time of day, in the year they
# reach it ("today, but when I'm 60"). Reads the birthday the way every other
# date is read, so a written birthday works. undef when none is set or the sum
# will not make a date, so the caller falls through.

# Read a typed time the way a person writes one. A relative offset ("-3h", "in 2
# days", "3d 4h") belongs to ago_calc's own arithmetic and is left to it; a
# calendar date is read here, so a bare "jul 16", an ordinal "16th 2", a "last
# dec 25" and a full "dec 25 2025 at 7:04pm" all land where they say. A date with
# no time of day keeps the present time of day; a date with no year is this year,
# and a leading "last"/"next" moves it by one. A bare ordinal day with no month
# rolls to the next month once it is already behind. Returns undef when the text
# is not a calendar date, so ago_calc keeps its old path untouched.

# Whether the last resolve_when read only a date, or left words it could not read.
# "dec 25 at 7pm" leaves only connective words, but "sept 11 attacks" leaves a
# name - which the guide should read instead of the bare date (so the phrase means
# the 2001 attacks, not this year's September 11).

# A local time as an unambiguous ISO string, its year signed so B.C. reads as a
# negative year ("-0044-03-15 00:00:00"). resolve_when reads this back exactly,
# which is what the walkman's jump buttons hand the time machine.

# The birthdays the person keeps (Configure -> App -> Birthdays), one to a line as
# "Name = date" ("Abraham Lincoln = February 12 1809"). Read across devices - the
# newest value wins - so a save on any machine is seen everywhere.

# The saved birthday for a named person, in ms, or undef. A thing named for the
# person (its app) carries its own Birthday setting, and that is read first; then
# the list; failing both, a name whose words all sit inside the other's, so
# "Lincoln" finds "Abraham Lincoln".

# Every birthday the house can name: the "Name = date" list plus each
# construct that carries a Birthday setting of its own (a person app's own
# panel). The Guide is given this directory so "my mom's next 5 birthdays" can
# resolve to a saved person instead of asking for a date it already has.

# The times of day an app's records cluster around: the busiest hours (a habit can
# fall more than once a day - coffee mid-morning and again mid-afternoon), each
# with the minute that clusters within it. Empty with no records, so a caller
# falls back to a plain clock time.

# A time of day that is a habit rather than a date ("breakfast", "tea time", "next
# coffee time"): the times the person usually does it, read from that app's own
# records, and a plain hour when there is nothing to read. "next" is the next of
# those times after now (today, else tomorrow); otherwise it is the one nearest
# now, today. undef when the phrase names no such habit.

# The times an app is expected to happen, for the ghost appointments a clock draws
# ahead of now. The record's own habit comes first (the hours its appointments
# cluster around); with too little to read, the app's saved clothesline hours; and
# with none, the hours of its own 'usual' occurrences. Memoized briefly, so the
# viewer's poll does not re-read the history on every tick.
our %ghost_times_memo;

# An hour written the clothesline's way ("9am", "10pm", "12am") as a number 0-23.

# The span a ghost should wear: the app's own recent average, its duration setting,
# else nothing.

# The real appointments an app has near now, cached briefly, for matching an
# expected time to the occurrence a real one belongs to. Only called for apps that
# have a habit, so the range stays small.
our %ghost_done_memo;

# The ghost rows for one app: its expected times that have not been met and are not
# already scheduled. An expected time is dropped once a real appointment sits
# nearest to it (a started or scheduled occurrence - the coffee that just began
# stops being a ghost until tomorrow's comes round). The next expected time beyond
# the view is kept too, so a clock shows it clamped at the edge rather than
# nothing.

# Work claims: who is sorting out what, so two agents - or two machines - do not
# take the same job. They live as settings on the 'claims' app, which is NOT one of
# @gb::protected, so the mesh merge carries each claim to every machine; the
# protected __president settings (the agent registry among them) stay local.



# The machine's own name, for a claim a person has to read. The signatorial is the
# mesh identity; this is what to show beside it.

# The name a person reads for a machine. A phone has no hostname of its own:
# Android/Termux answers `hostname` with 'localhost', and that used to overwrite
# the good name a peer had already learned every time the phone reconnected.
# Prefer the machine's own report, then the name we already remember, then the
# first label of its fqdn (phone.example.com -> Phone).

# Released by writing it empty rather than deleting it, so the release rides the
# same mesh merge the claim does.


# The device bridge hands back an SMS or call date as the epoch in milliseconds
# (Telephony.Sms.DATE and CallLog.Calls.DATE), while ago_calc reads a span like
# "-3h" and bills a bare number as minutes. Passing a millisecond date straight
# to ago_calc therefore subtracted date*60000 ms from now and put the record
# millions of years in the past - the "3409757y" rows the SMS and call-log
# checks wrote after the app moved off termux-api (whose list returned a
# written date). An absolute epoch passes through; anything else keeps the old
# span reader. A ten-digit value is a seconds stamp, widened to milliseconds.

# A warranty belongs to the house, not to the machine that set it. It is stored
# on the 'all' device row (like the language and the theme), so every device
# reads the same value. A per-device row from an older build is still honoured
# as a fallback until the backfill has written the house row.

# A renewal keeps the offset between the chosen warranty and the moment it was
# anchored at, and lands that same offset on every record's own timestamp. The
# value is already resolved to a moment, so a warranty typed in the card is the
# one that applies - not the stored setting.

# A warranty is a moment ahead of the record. A renewal that resolves behind now
# would expire every record it touches on the next alarm_haircut, so it is not a
# renewal at all and must not be written.

# The voices say_it can speak with. A friendly name carries the engine and what
# that engine needs; the Speech setting in Configure picks one by name, so the
# list here is the single source of truth for both the taker and the picker.
# The piper models live under voices/ (carried as blobs like the APKs, see
# app_release_sync); espeak voices are the fallback when piper is not staged.
# Only cleanly-permissive voices belong here: LJSpeech is public domain,
# LibriTTS-R and Alba are CC BY 4.0. A model dropped from this list is pruned
# from every device by voice_sync, so a licence problem is fixed everywhere.



# Where the piper binary is on this device. It is arch-specific, so the voice
# sync never carries it - only the models (which are arch-independent). The
# dependency step's copy wins, then a piper on PATH; the repo's own bundle is the
# desktop last resort (on the phone it is the wrong architecture).

# The command that runs piper here, engine only (say_it appends the model and
# output args). A glibc-built bundle needs the glibc launcher on Android; a
# Termux build runs directly.

# How to play a finished wav here. Android has no sox audio backend; the app
# plays the clip through the bridge instead, so there is no shell player on a
# handheld and the caller passes an empty command.

our $say_quiet;

# The piper invocation shared by the local player and the streaming reply:
# (argv, extra args, model path, the model's own sample rate). '' when no piper
# render is possible on this machine.

# Shell-quote one command of a pipeline ("arg with space" -> 'arg with space'),
# so the paths the voice settings name survive the sh -c that runs piper | ffmpeg.

# Piper render to a file (the local player's path). Returns the path of a fresh
# WAV, or '' when no piper render is possible. The caller owns (and unlinks) it.


# Is the device on WiFi and reachable? Its own web server on port 3000 is the
# test: an off-LAN or powered-down device fails the connect at once, which is
# what lets the reply go to Bluetooth without waiting for a timeout. Returns
# the address the reply route is served from, or undef.

# Render the answer once as a WAV, so a WiFi device can fetch it in one
# streamed GET instead of receiving hundreds of BLE notifications. Returns the
# id (the file is ~/.president/reply_<id>.wav) or undef when piper/ffmpeg
# cannot produce one; the caller then keeps the BLE stream.

# A spoken answer to a voice command that came from the watch: push the reply
# text (the watch shows it on screen) and the spoken answer (a short piper clip
# the watch plays) over the bridge, so the answer lands on the wrist. No local
# say_it: the machine holding the bridge would double-talk with the watch.

# Stream the spoken answer to the watch as PCM parts. Piper writes raw samples as
# it makes them; ffmpeg resamples them to 8 kHz mono (16 KB/s, which the BLE link
# carries comfortably) as it goes, so parts leave while the sentence is still
# being synthesized - the watch starts talking back almost at once instead of
# after the whole clip has been rendered and pushed. Each part is its own bridge
# message (all over one connection, see bluetooth_stream_open), so a long answer
# is no longer capped by the 64 KB message limit.

# The picture an app's icon shows: the person's own main image when there is
# one, else the active icon set's version of the app's known picture, else the
# placeholder for its pos. main_icon_maker renders this in HTML; the native
# home asks /apps/icon for the same answer as a PNG it can draw. Returns ''
# when the app has no icon at all.



# M0 contracts (docs/roadmap-handoff.md): one door for every Android device
# command. A caller names the command without its "termux-" prefix and passes
# the argument string exactly as the shell should see it, so wrapping a call
# site changes nothing at runtime. M1 replaces these three bodies with the
# DeviceService client and the call sites stay put. The literal "termux-"
# now lives only here; scripts/termux_ledger.pl counts it.

# Run a device command through the shell. The optional prefix keeps a pipeline
# or a timeout at the call site ("timeout 8 ", 'echo "$message" | ').

# Where the Termux API app's command would be, for the capability probes that
# ask "-x" before spawning one. M1 answers this from the bridge instead.

# The host app's identity (M4). The Java package is com.jawnos.app and every
# intent action is com.jawnos.app.*, but the *installed* package is com.jawnos
# (the app's manifest package) and in the fork it was com.termux. A component
# name is relative to the installed package ("com.jawnos/.app.X"), so both the
# action and the component follow this one value: a device still on the fork
# keeps answering its own names until it is migrated.

# An intent action of the host app: JAWN_WAKE -> com.jawnos.app.JAWN_WAKE.

# A component of the host app, named the way `am` wants it.

# M1 device bridge (docs/roadmap-handoff.md): ask the host app directly instead
# of spawning a termux-* command. One JSON line in, one back, with a request
# id, on a loopback socket the app opens (the jawn-bt pattern). Returns the
# decoded result, or undef when the bridge is not there - every caller keeps
# the termux command as its fallback, so an old app with a new tree and a new
# app with an old tree both work.
#
# The token is the app's: it writes $HOME/.jawn/device.token (mode 600) because
# the app and Termux share one uid. JAWNOS_DEVICE_TOKEN/BRIDGE_PORT exist for
# the tests and an unusual install.
our $device_bridge_sock;
our $device_bridge_memo;   # { until => epoch } after a transport failure
our $device_bridge_seq = 0;





# A thumbnail straight from the host app (M3): MediaMetadataRetriever for a film
# frame, BitmapFactory for a picture, PdfRenderer for a page. Returns PNG bytes,
# or undef so the caller keeps its ffmpeg | magick pipeline - which is what a
# desktop does, because there is no bridge there. Decoding a frame is slower than
# a ping, so this call waits longer than the default two seconds.

# The machine's battery in one shape for the Monitor and the old System view.
# termux-battery-status is a spawned API call, so a short shared cache keeps the
# Monitor's two-second poll from spawning one per tick; Android denies the
# power_supply sysfs to apps, while a desktop reads BAT0 directly.
our $battery_sample_memo;

# The robust slope of a battery history, in percentage points per hour.
# Points are { t => epoch_ms, p => percent }. A fit needs $min_points samples
# across $min_span milliseconds AND at least $min_delta points of net movement:
# on a 1% gauge a three-sample five-minute window is one integer step, not a
# rate. The slope is Theil-Sen (the median of every pairwise slope), so a
# single voltage sag or bad reading is one pair's worth of noise rather than the
# answer. Returns (slope, span_ms, samples, p25, p75, movement); the first three
# are the old contract, and p25/p75 form the confidence band the card shows as a
# range. A partial answer still carries the span/movement so a caller can tell
# "not enough time yet" from "too flat to measure".

# The PPH comparator: the same discharging history, grouped by the lock state
# that produced each sample. A scheduled-wake reading and a permanent-lock
# reading can then be compared without a separate measuring process (which would
# itself keep the phone awake). The caller prints or renders the rows.

# The card's one estimate, in hours, from whichever reading the pack gives.
# The gauge (energy/power) is the only real measurement; a percentage slope is
# an inference. Fills eta_kind (left/full), eta_hours, eta_lo/eta_hi (a band),
# eta_flat (too flat to measure) and eta_floor (the most time a flat reading
# allows). `$previous` is the last sample, used to keep the shown figure still
# while the fit settles; a status change or a large real move is taken at once.
# Fill in a finish-time estimate from a pack's own gauge, where the fields are
# there to do it: Android's charge counter plus the percentage gives the pack's
# capacity, and the averaged current then gives the hours to full (or flat).
# Called by the sampler and, for a peer still on older code, by the levels
# pass that receives its raw reading.


# --- House levels -----------------------------------------------------------
# The System card shows one battery line per House machine and per embedded
# board. A machine's own reading is cheap; a peer's is one signed
# /manager/health call, and a board's is its /device_query. Both kinds of I/O
# happen in the levels loop, never in a request: the card renders the cached
# snapshot, so a sleeping watch or a dead peer cannot hold the menu open.




# The System card asks for quick passes while it is on screen. Rendering the
# card sets this stamp; the levels loop sees it and shortens its interval, so a
# phone plugged in a moment ago shows its new state instead of waiting out the
# two-minute house pass. Rewritten at most every 30s so an open card does not
# write the cache on every refresh.

# CPU and RAM for the levels card. A peer's /manager/health answers with the
# same shape, so one reading means one thing across the house.
#
# /proc/stat is the whole machine and the first choice. Android denies it to
# apps, so the fallback sums JawnOS's own processes - the same figure the
# Monitor app shows there - and the reading says so. A cumulative sample lives
# in the cache so a percentage is a real difference over a real window, and so
# every prefork worker reads the same sample instead of guessing from one tick.




# The machine rows' embedded boards, deduplicated: one board may be in several
# machines' neighbour tables. Both the pull (house_levels_sync) and a peer's push
# (health_report) rebuild the list this way, so a pushed row cannot leave the
# boards view disagreeing with the machines.

# Tell each recently seen peer "I am awake and my rows have moved; pull me now".
# A phone sleeps between beats, so a peer's own poll usually lands while it is
# away; this is the announcement that lets the peer run its delta pull during
# the seconds the phone is up. Returns how many peers said they need a pull.

# Note that a peer is reading rows from this machine right now. The scheduled
# wake checks this before releasing the CPU: a phone must not sleep in the
# middle of a pull it is serving. The mtime is the signal, and utime updates it
# without rewriting the file, so a multi-batch pull costs no flash writes.
# The Android receiver's hard hold: while this file is fresh it renews the CPU
# lock instead of letting the 45-second scheduled window expire. Touch it when a
# peer is about to pull and for every row batch served; the receiver treats a
# touch within 60s as a lease (the five-minute cap still bounds a runaway peer).
# utime updates only the inode, so a multi-batch pull costs no flash writes.


# The card's read: the cached snapshot with this machine's reading refreshed.
# The local battery is cheap and should not wait for the next two-minute pass.




our ($network_report_memo, $network_report_memo_at);

# The Android runtime has no ifconfig, and `ip addr` cannot bind a netlink socket
# as an app uid (SELinux), so the phone and tablet reported no interfaces at all
# and their devices row carried `{}`. The app answers the same report natively
# (network.interfaces); this maps it to the structure the ifconfig parser below
# produces. A desktop has no bridge, so it keeps parsing ifconfig.
# Order-insensitive identity for an address map. It covers the fields a peer
# needs to reach and label this machine (address, MAC, gateway and the ports),
# so a row written without the port environment is corrected on the next pass.

# The device bridge resizes and re-encodes images natively. A call site keeps
# its magick pipeline as the fallback for a desktop, where there is no bridge;
# the helper answers undef then. This is the first half of the ImageMagick diet:
# once every image call site asks here first, magick can leave the runtime.



# The palette's duties are a list of per-file steps - rotate, crop, modulate,
# level, black-threshold, gaussian-blur, sharpen - which the route used to run
# as one `magick <file> -<duty> <value> <file>` per step. The bridge applies the
# same list in one call, so the palette survives on a phone with no magick; a
# desktop gets undef and keeps the command. Steps the bridge does not know are
# reported back in `skipped` rather than failing the whole edit.

# A display copy of a picture for a card or an avatar: the bridge fills a square
# from the centre (magick's `-resize NxN^ -gravity center -extent NxN`). A
# desktop answers undef and keeps its command.

# A thumbnail file made by the bridge: the bytes come back as PNG and are
# written where the caller wants them. A desktop gets undef, so it keeps its
# ffmpeg | magick pipeline.









# Only a private or link-local network is ours to probe: a public address is not.

# ---- routers on the network ------------------------------------------------
# The gateway is the one device every network has, and the Dev panel should
# name it without a person tagging it. Probe it once (the login page says which
# firmware answers), keep the row when the machine later leaves that network,
# and let the card show the last time it was seen. A router is not a JawnOS
# peer, so it does not belong in remote_machines.


# Every router this machine has met, newest sighting first. Keep only one seen
# in the last day, or the gateway of a NIC that is up right now: a laptop that
# roams would otherwise pile up an unnamed row for every network it has left.
# The rows stay in the table, so returning to that network lists it again.
# online is a short window so a router that is simply off the network still
# lists, greyed, with the last time it answered.

# Resolve mDNS/DNS-SD services of one type on the local network, as a list of
# records (avahi is the responder this house already has). Parsable output, one
# `=` line per resolved instance:
#   =;iface;proto;name;type;domain;host;address;port;txt

# The printers the local network advertises, keyed by address and by MAC so a
# scanned device can be recognised either way. _ipp._tcp is the Internet
# Printing service every modern printer answers; _pdl-datastream (port 9100) is
# the fallback for one that only speaks raw.

# What a printer says about its own consumables, read over IPP. A printer that
# advertises _ipp._tcp answers Get-Printer-Attributes: marker-levels is the ink or
# toner left in each cartridge, with marker-names, marker-colors (one #rrggbb, or
# several for a tri-colour cartridge) and marker-types labelling each one, and
# printer-state / printer-state-reasons saying whether it needs attention.
# Returns a hashref of the markers and the state, or { error => ... } when nothing
# answers - so a printer that is off leaves its row saying so, not blank.

# The JawnOS devices the local network advertises on _jawnos._tcp, keyed by
# address, MAC and chip_id so a scanned device is recognised however it is known.
# The firmware puts purpose/model/caps in the TXT records (see jw/jt/alarmclock).

# Fold what mDNS knows into an address map in place: name the JawnOS devices and
# the printers on each network, and add any the neighbour read missed, so a
# device answers what it is the moment it appears. Returns 1 if anything changed.

# The light half of a scan, on a timer: fold what mDNS knows into this machine's
# own device row, so a device plugged in is named within seconds without running
# the whole interface scan. Writes only when something changed.

# An address and its netmask as a CIDR: 192.168.2.3 + 255.255.255.0 ->
# 192.168.2.0/24. Returns undef for anything that is not a plain IPv4 address,
# and reads a hex netmask (0xffffff00) the way some ifconfig builds print it.

# `ip neigh` is only the ARP cache: a device this machine has never spoken to -
# a printer, a fresh appliance - is simply absent from it until something pings
# the network once. On an explicit scan, sweep the NIC's own subnet so those
# hosts answer and land in the cache the neighbour read then relies on. The
# sweep keeps its own bound so a slow or filtered network cannot stall a scan.


# This machine's own row in `devices`, created without a browser. The one Scan
# that used to build it runs in Configure -> Dev, so a headless server never had
# a self row - and with no row this hub has no `address` map at all, so the
# tunnels it holds can never be listed as its own neighbours (tunnel_checker
# hangs them off that row; device_scan is otherwise the only writer). Built from
# the same interface report device_scan writes, so the two agree on shape. Cheap
# when the row already exists (one select), so a per-tick caller is fine.
# The self row is written by device_scan, which only runs on a real scan. A
# phone or tablet that never presses Scan therefore kept the address map it
# had (often `{}`) and peers could not learn its LAN address. Every
# device_lister pass refreshes it from the interface report, and only when the
# interface/address signature moved.



# The device rows as the lister shows them, grouped by the network each
# neighbour sits on: one group per subnet, its members (the interfaces that
# reach it, each on a machine), and the devices found there. device_lister has
# already left each address once, so a device is listed under a single network.

# The machines remote_machines knows that no neighbour table shows. A peer
# reached over the tailnet, or one on a subnet none of this machine's NICs
# reach, is in remote_machines but in no `devices` neighbour list, so the
# network cards never draw it. Deduplicate by signatorial, or by address when a
# row has none, so the card only adds what the neighbour tables missed.

# --- JawnOS BLE bridge (replaces the am broadcast + Tasker + BLE plugin chain) ---




# ---- multi-link bridge state (protocol v2) --------------------------------
# A desktop or phone bridge can hold several radios at once. Every link event
# names its MAC; keep the same map here so a send, a yield and a sighting can
# name the right radio instead of guessing at "the" link. A v1 daemon still
# works: its status has no links[], so the top-level fields become the one link.




	# How long a Bluetooth sighting keeps an embedded device listed in the Embedded
	# app after its last bridge message. A watch's radio sleeps and re-links on the
	# next advert, and even awake it only talks when something changes, so this must
	# outlast a quiet spell - not merely a nap. Two hours, so a watch that speaks
	# rarely (a connected one says nothing for a long time) stays on the list even
	# across a spell where its jawn was down; a device genuinely gone still drops.
	sub ble_presence_window() { return 7200000; }


# The embedded devices' one authentication check: a watch, deck or alarmclock
# presents the rotated Now Me pair from its own operator_door row. The pair is
# the same one every route uses (edt + chip_id + authorization), and the token
# is the encrypted secret the device was last handed. This lives here, not in
# watch.pl, because the backup route is registered by Manager.pl and both
# workers must check it the same way.






















# --- BLE battery -------------------------------------------------------------
# The bridge can ask a linked board for its pack; the board answers on the same
# NUS link. The reply is cached per chip, and the levels scan merges it with the
# HTTP reading, so a board whose WiFi is asleep still appears. A board linked to
# a phone is relayed by that phone's levels response, the same as any embedded
# board it can see.





# The Bluetooth devices the bridge has seen, for the Dev panel. A BLE-only device
# off its access point is in no machine's neighbour table, so the network listing
# never shows it; the bridge records each sighting in a machine's `chip_ids`
# (ble_device_record), which device_lister already falls back to for the Embedded
# app. Same source here: one row per chip, the freshest sighting, and only while
# the presence window still holds - so a headless hub (or any machine with no
# browser scan) still lists the fleet's radios.


# A send that must not hold the caller's event loop. bluetooth_sender waits for
# the radio to acknowledge the write; a watch that has gone to sleep suspends its
# link without saying so, and nothing comes back until Android's link supervision
# timeout, tens of seconds later. Run inline that wait is the whole manager
# frozen - the bridge listener's reader, a recurring timer, a request handler -
# and every later message queues behind it, so the freeze repeats. The homebase
# checks are cheap; the client and its wait ride a child instead.


# One bridge connection for a run of messages, for a streamed reply: the daemon
# reads command lines per connection, so a dozen parts ride one client process
# instead of starting one per part (a perl start each time, on a phone, costs
# more than the audio). Returns a filehandle to print message JSON lines to, or
# undef when this machine may not drive the bridge. The caller closes it.





# Speech -> text through a cloud model. The transcription model (Configure -> Plat)
# is either Cloudflare's @cf/openai/whisper or an OpenAI-compatible /audio/
# transcriptions endpoint (Groq whisper-large-v3*, OpenAI whisper-1). '' on any
# failure, so the caller falls back to the local whisper.cpp pipeline.


# The warm whisper.cpp server's loopback port. It is an accelerator for this
# machine, never a service offered to the network.

# A warm server keeps the model loaded, so a clip skips the model load the
# one-shot CLI pays on every call. '' when it is not running or did not answer.

# The one-shot CLI path. It is also the local path on a machine whose warm
# server is not up yet.


















# The backups registry is merged across the mesh, so rows pile up for every
# machine's old archives - and the file-based prune in backup_now can only ever
# match this machine's own files, which is why a peer's rows (a phone's
# /data/data/... paths, say) were never cleaned and the table ran to thousands.
# Bound it: keep only the newest few rows per (reason, machine, recipient,
# destination) and delete the rest, with a tombstone so the deletion reaches the
# other machines too. Keeping the newest is what makes it safe: the newest
# remote_upgraded row of a group is the sync watermark (remote_machine's
# reconnector and remote_upgrade read it), and merge_database reads the newest
# one or two rows overall. Capped so one pass never floods the tombstone log;
# successive backups finish the job.

# The encrypted SQLite snapshot is the archive / migration / v2 path now. A normal
# delta between peers runs the v3 row stream (`Manager::sync_rows_pull` and the
# `/manager/sync_rows` route), which shares merge_table_rows/merge_finish and never
# builds this temporary database.

# A cheap, truthful picture of what this machine's appointments hold, so a peer
# can tell whether it already has everything instead of pulling the window every
# tick. Appointments are only inserted or re-stamped, so if the count and the
# newest server_time are both unchanged there is nothing new to send.

# What this machine holds above the watermark a peer already has (its ?since=):
# appointments with a newer server_time. A count, not the rows, so the check
# stays cheap on the two-minute tick; the reconciliation is what moves data.

# --- the House digest -------------------------------------------------------
# `server_time` is the write time of every replicated row, so a per-table
# {count, sum(server_time), max} is a cheap fingerprint of the whole table. Two
# machines that hold the same rows have the same fingerprint even when the rows
# arrived by different paths; a machine that was offline and is missing an old
# row has a different count (or sum) and is caught. /remote_auth_test exchanges
# this map, and the caller plans a per-table pull from the difference.

our $sync_table_cache;


# The same count/sum/max as `sync_table_digest`, but per band of `server_time`:
# the whole-table digest is the cheap gate that says a table moved, this says
# where it moved, so a repair can read the bands that differ instead of the
# whole table. Bands are fixed-width and computed by the same SQL on both
# machines, so a band means the same range on each side. A negative server_time
# is folded into band 0; the reader uses [-inf, band) for that band.
our $sync_bucket_band = 7 * 24 * 60 * 60 * 1000;   # one week
our $sync_bucket_low = -9223372036854775807;



# Bands whose picture moved between the baseline (the peer's last reconciled
# map) and now. A band only in the baseline is a deletion and has no rows to
# fetch; a band only in `now` is new. The same diff serves a first reconciliation
# with this machine's own map as the baseline: a band either side differs in has
# to be read, because counts and sums cannot tell which side holds the row the
# other lacks. Newest band first: the walk moves back through history, so a
# recent gap is filled before an older one.

# Can a peer answer a band map? The route arrived in 0.1.1036, so its handshake
# version answers it. An explicit `bands` marker is enough on its own; a peer
# that reports no usable version is assumed unable, which keeps the old small-gap
# guard (and the CPU it saves) for an older build.

# The half-open server_time range a band covers. Band 0 owns everything below
# one band, including a pathological negative server_time.

our $sync_digest_cache;


# The caller's plan: table => since. `0` asks for the whole table's picture (the
# puller localises it by band when the peer can answer a map); a timestamp means
# pull only what is newer. Watermark first: rows above our newest are always a
# delta. `bands` says the peer can answer `/manager/sync_buckets`, which lets any
# other divergence be localised instead of skipped or read whole.

# Compact table=>integer maps on the peer rail (?cuts=, and the plan handed to
# backup_now). Table names are SQL identifiers; anything else is dropped rather
# than interpolated.

# --- one sync job, for the yellow dot's progress ---------------------------

# The individual bars across the top of the panel: one entry per phase/table, in
# the order it was first seen. A sync job is short-lived and only its owner writes
# it, so a read-modify-write of the small JSON array is safe.
	sub sync_job_update {
		my ($uuid, $data) = @_;
		return unless $uuid && ref $data eq 'HASH';
		my (@sets, @vals);
		foreach my $k ( qw/phase current total state note peer direction/ ) {
			next unless exists $data->{$k};
			push @sets, "$k = ?";
			push @vals, $data->{$k};
		}
		return unless scalar @sets;
		push @vals, &rightNow(), $uuid;
		&db_query('update sync_jobs set ' . join(', ', @sets) . ', updated = ? where uuid = ?', @vals);
	}

# A tree that dies mid-pull leaves its job row 'running': only a clean
# Jawn::SyncJob exit writes the final state, and a SIGKILL or a tree restart
# skips it. At boot no worker from the old tree can still own a job, so age out
# the plainly abandoned ones. The 30-minute bound matches the remote_upgrade
# lock, so a genuinely long pull is not cut short if its owner somehow survived.

# The peer picture we have already reconciled, per table. Storing it after a
# successful pull turns "this table diverges" into "this exact picture has
# already been read", so a peer that is merely behind us is not full-read every
# tick while a peer that changed (the offline row) is read once more.

# A peer that told us it was busy gets a short rest instead of being asked again
# on every tick. The cache is machine-local (and forbidden from the export).

# A sync pass starts at most one pull: the marker holds the slot until the
# forked child claims it. Roster order therefore decides who gets to sync, and
# a busy first peer (the laptop in daily use) takes every pass while a peer that
# has been behind for days never gets a turn. Order the pass by the last
# confirmed pull instead: the peer with the oldest watermark (or none at all)
# goes first. Ties are broken by signatorial so the order is stable.

# This machine's pull marker. The value is either
#   running:<pid>   a forked pull that owns the work, or
#   running:claim   a caller's claim made just before it forks, or
#   <anything else> idle ('' or the panel's 'inactive').
# Mojo::IOLoop::subprocess forks on the next tick, not when subprocessor is
# called, so a claim is written before any child exists. If that tick never
# happens - a tree restart, a torn-down loop, a failed fork - the claim used to
# keep the marker looking like a live owner (it carried the caller's pid, and a
# long-lived worker's pid never dies), which blocked every automatic pull for
# the full thirty-minute bound and made the Upgrade button answer "already
# running". A claim now gets its own short bound; only a real pid, still alive,
# holds the long one.


# A pull killed by an app update or a tree restart leaves this marker behind,
# and every peer then hears "merging" and skips this machine's newer rows until
# the age bound expires (the phone hid six appointments this way, 2026-10-31).
# At boot nothing from a previous life can still be pulling, so a marker that no
# live process owns may be dropped at once instead of waiting out the bound.
# A live pid, a fresh claim, or an empty marker keeps its place.


# --- durable deletion tombstones -------------------------------------------
# A deletion is permanent for any machine that has not yet seen it. Each
# tombstone carries a monotonic id; a machine only drops a tombstone once every
# remote machine has *confirmed* reading past it (sync_cursors), so a desktop
# left off for weeks still receives the whole backlog when it reconnects. The
# owner advances a reader's cursor only from the cursor that reader sends on its
# next request, so a lost response can never purge a deletion early.



# Drop tombstones every known machine has confirmed reading. With no remote
# machines there is nothing to sync, so the log clears wholesale; if any machine
# has never confirmed (no cursor yet) the whole backlog is kept.
#
# File-scope tombstones stay: a peer reads the log to advance its cursor, but an
# older peer has no file-scope deletion (the entry carried no file uuid before),
# so "confirmed reading" does not mean "applied". Keeping these rows is what
# stops a peer that still carries the attachment from handing it back on every
# pull; they are few, and a peer on current code applies them when it reads them.






# ---- note encryption ---------------------------------------------------------
#
# A note is sealed in two layers: an inner cipher - an openssl `enc` container
# ("Salted__" + an 8-byte salt + the ciphertext), keyed by PBKDF2-HMAC-SHA256 of
# the secret - and an outer Crypt::Simple layer keyed by the same secret. The
# standard travels inside the payload, so a note written under any standard still
# reads back.
#
# The inner cipher runs in-process for the AES family (through CryptX) and falls
# back to the openssl binary for the rest; both produce the identical container,
# so notes are interchangeable either way. The old pipeline forked base64 and
# openssl for every single note - tens of milliseconds each, which is why a page
# of mail took seconds - this one costs microseconds.

# The standards the Encryption Standard setting offers. Everything here is
# filtered by what this machine can actually run (see note_standard_supported),
# so the Configure list never offers a cipher that would write letters nobody can
# read back. A standard not listed can still be read: the openssl fallback accepts
# any cipher that binary knows.

# Whether one standard can be sealed and opened again on this machine. The
# in-process families answer from the table; the openssl-only ones are probed
# once (a tiny round trip) and memoised for the life of the worker.
our %note_standard_supported;

# The in-process cipher for a standard, or undef when only openssl can run it.
# aes/camellia-NNN-ctr/cbc map onto the named cipher with the key length the
# number names; CTR keeps a big-endian, full-block counter, which is what
# openssl's EVP uses. des-ede3-cbc is 3DES (8-byte block); sm4 is a 16-byte-block
# cipher. keylen is the key, ivlen is both the IV and the block. Everything listed
# here is also readable through openssl, so a peer that still shells out can open
# the same file.
our %note_cipher_specs = (
	'aes-128-ctr' => [ 'ctr', 'AES', 16, 16 ], 'aes-192-ctr' => [ 'ctr', 'AES', 24, 16 ], 'aes-256-ctr' => [ 'ctr', 'AES', 32, 16 ],
	'aes-128-cbc' => [ 'cbc', 'AES', 16, 16 ], 'aes-192-cbc' => [ 'cbc', 'AES', 24, 16 ], 'aes-256-cbc' => [ 'cbc', 'AES', 32, 16 ],
	'camellia-128-ctr' => [ 'ctr', 'Camellia', 16, 16 ], 'camellia-192-ctr' => [ 'ctr', 'Camellia', 24, 16 ], 'camellia-256-ctr' => [ 'ctr', 'Camellia', 32, 16 ],
	'camellia-128-cbc' => [ 'cbc', 'Camellia', 16, 16 ], 'camellia-192-cbc' => [ 'cbc', 'Camellia', 24, 16 ], 'camellia-256-cbc' => [ 'cbc', 'Camellia', 32, 16 ],
	'des-ede3-cbc' => [ 'cbc', 'DES_EDE', 24, 8 ],
	'sm4-cbc' => [ 'cbc', 'SM4', 16, 16 ],
);

# The standard to seal a new note with: the setting when it names a cipher this
# machine can actually run, otherwise the default. The setting used to be filled
# from every cipher `openssl enc -ciphers` lists, most of which this scheme cannot
# use - choosing one wrote letters that could never be read back. Validating here
# means a bad setting degrades to the default instead of losing data.

# PBKDF2-HMAC-SHA256, 10000 rounds - openssl enc -pbkdf2 with its default digest.


# Key and IV for one container, memoised per process. PBKDF2 costs about 6 ms and
# a file is opened again and again (a thumbnail, a video range, a gallery reload),
# so the same secret and salt must not pay for it twice. Bounded and never
# written anywhere: a cache is a convenience, not storage.
our %note_key_material;


# Run openssl over bytes held in memory. The input goes through a temp file, not
# a pipe pair: with two pipes the parent writes the container into the child's
# stdin while the child writes the answer back, and once either buffer fills
# both sides wait forever. (This only bit the openssl fallback; AES and the other
# in-process ciphers never spawn a process.)

# openssl enc over files, with the passphrase in a 0600 temp file. Returns 1 on
# success and 0 on failure. $quiet keeps a wrong-password "bad decrypt" out of
# the log when a caller is walking a credential history.

# The same, but returning the plaintext instead of writing it to a path.

# Seal $content with the inner cipher, returning the openssl container (or undef).



# Open an openssl container with the inner cipher; undef when it will not open.
# $nopad leaves the PKCS#7 padding on (the file path sniffs the plaintext by its
# own nose, so it asks for the bytes untouched). $limit decrypts only that many
# leading ciphertext bytes - enough to sniff a key without paying for the whole
# file. A limit is only meaningful with $nopad: a note needs its last block to
# strip PKCS#7, so a limited open returns the raw prefix instead.


# The file sealing is the very same container, read from and written to a path.


# The verdict for a decrypted prefix. File::Type knows the formats it ships,
# but WebM/Matroska is EBML: it often comes back application/octet-stream. The
# old probes treated a webm path as good enough for *any* credential, so the
# first (wrong) secret won and the file was served as garbage. Sniff the
# plaintext's own magic first; it is the only thing that says the key is right.
# This is the house's primary sniffer: the table covers the media, documents,
# archives, executables and fonts a person actually stores, and text is
# recognised from its bytes rather than its extension. File::Type is only the
# last resort for a format the table does not name.
our $plaintext_ft;
# ZIP containers name themselves inside the archive: ODF and EPUB put an
# uncompressed `mimetype` first, OOXML leaves `[Content_Types].xml` and then
# `word/`, `xl/` or `ppt/`, and iWork leaves `Index/*.iwa`. The prefix is
# enough to read the local headers, so a .docx is not just "a zip".

# Legacy Office files are OLE2 compound documents. The directory's stream names
# say which program wrote it; the first directory sector is inside the prefix.


# Text is bytes with no NUL and no control characters; valid UTF-8 is text even
# when most of it is outside ASCII. This is strict enough that a wrong key's
# random bytes do not pass, which is what makes it usable as a key verdict.


# ---- fast sealed-file opens --------------------------------------------------
#
# Rock and roll used to read the whole file, derive a key and decrypt every byte
# once per credential in the rotation history. Two facts make that unnecessary:
# a key can be tested on a short prefix (File::Type never looks past byte 5122),
# and a file that opened once will open with the same secret and standard next
# time. The helpers below read the container once, test keys on 16 KB, and remember
# the winner for as long as the file is unchanged. Nothing here changes the
# container: the bytes on disk stay exactly what openssl writes.

our $SEALED_PROBE_BYTES = 16384;

# The identity of a sealed file: any change to it (a reseal) makes a different
# key. inode covers a replace, size and mtime cover an in-place rewrite.

# Try candidate secrets and standards in order, decrypting only the prefix for
# each. $inspect receives the prefix and returns a true value (the verdict) when
# it looks like the file wanted. Returns the winner without the body bytes.

# Advance a CTR IV by whole blocks (big-endian, which is what openssl's EVP
# counter is), so a range can start anywhere without decrypting what precedes it.

# Decrypt one byte range of a container. CTR is seekable by advancing the IV;
# CBC starts at the requested block using the previous ciphertext block as its IV.
# The caller passes nopad-style files (no padding block to strip from the tail),
# which is exactly the stream rock_and_roll serves today.

# Open a sealed file, remembering the secret/standard that opened it. $range is
# an optional [ start, length ] (length undef means to the end). Returns a hash:
# data, secret, standard, verdict, total, start, length; or { unsatisfiable }.
# With $stream set (and no range, nopad, an in-process cipher and a non-PDF
# verdict) it returns { stream => 1, ct, spec, key, iv, total, ... } instead of
# the body, so the caller can pump the plaintext out a chunk at a time.
our %sealed_file_memo;

# The security credentials a note of a given moment could have been sealed under,
# newest first. The rows are the same for every note on a page, so they are held
# for a few seconds rather than fetched for each note.
our $note_security_memo;

# Unseal one note with one key: the outer Crypt::Simple layer, then the inner
# cipher, then the md5 in the payload to prove the plaintext is the right one.
# Returns undef when the key does not open it, so the caller can try the next.

# A note's plaintext never changes for a given key and ciphertext, and the same
# notes are read again and again (a page reload, a second window, the socket),
# so the results are held for the life of the worker. Key derivation is the price
# of the scheme - PBKDF2 at 10000 rounds is around twenty milliseconds - and this
# is what keeps the second read of a letter from paying it again. Bounded by
# total size, oldest first, so a long-lived worker cannot grow without limit.
our (%note_memo, @note_memo_order);
our $note_memo_bytes = 0;
our $NOTE_MEMO_MAX = 8 * 1024 * 1024;









# A rename into a name the house already knows is a merge, and the settings the
# two apps share meet on one row each: this lists those rows so the panel can
# pick which value keeps the name per setting - and which ones merge naturally
# (nfc tags concatenate, measures union their keys, contact lists join).

# Is this value just what a brand-new app would be born with (setting_initializer)?
# True for the fixed ones (visible, permanent, cost, enc, public, schedule,
# navigation), for the me app's worth, duration, currency, unit and warranty - on
# any device, since a default made on the phone is still the default here, and the
# me rows are per device - and for the app's own name as its notification line.
# Anything else is a value somebody chose for this app.
our %setting_defaults_memo;

# How two values of a setting join: nfc, measures and the typed contact lists are
# lists at heart, so a natural merge keeps both sides; anything else keeps the
# renaming app's value. Merging with an empty side simply keeps the side that has
# a value - which is what a one-sided contact row does.

# Applies the panel's choices and leaves only the rows the rename will carry:
# 'new' drops the target's row (the renaming app's value takes the name), 'old'
# drops the renaming app's row (the existing value stays), and 'merge' writes
# the joined value under the target name and drops both.

# --- appointment history: what a rename into a known name would merge --------
# The settings merge above answers "which value keeps the name". This answers
# the other half: what happens to the app's events. The panel shows a compact
# per-side summary and a few policies, and the chosen policy's rows are
# tombstoned after the rename (under the unified name, so every peer agrees).






# 'full' when start and end both agree, 'open' when one side has no end.





# Which of two matched rows survives: the explicit end, then notes, then the
# length closest to that side's configured duration, then the newer write. A
# true tie keeps the existing record (the target) rather than the renamed one.



# Plan the rows a policy would drop, BEFORE the rename. The uuids are applied
# after the rename, under the unified name, so a peer that held the row under
# either old name receives a tombstone it can match.




# A misc setting as this device should read it: this device's own row when it has
# one, then the person's own ("Me"), then nothing - the caller names the
# fallback. The configure panel's per-device blocks write the tab's row, so a
# value chosen under Me used to be invisible to the manager, which read the
# device's row alone and fell back to its defaults on every load. An explicit
# device may be named, for the panel asking after a tab that is not this one.

# The desk's material as the layout and universal.css name it. 'plain' was the
# solid rounded pill's old internal value; it reads as 'round' now that Plain
# means the clothesline as it looked before the materials (internal 'classic').

# The desk's corner radius, in pixels. A theme carries its own corner; an
# explicit choice made from Misc while that theme is active (corner_override)
# wins over it, and with no theme in charge the Misc slider (corner_radius) is
# the value. It is held between 0 (square) and the 28px the theme editor allows,
# so no surface is rounded past its own middle. The layout seeds it as
# --corner_radius, which --jawnos-corner falls back to; every window, control
# and panel rounds by that property.













# Gossip dedupe for relayed requests. A relay carries a relay_id, minted once by
# the machine that first sent it, and every machine that handles it claims the
# id here. INSERT OR IGNORE makes claim-and-check atomic, so of two copies that
# race in exactly one is "fresh" and the rest are dropped. cache is local (never
# synced), and the rows are pruned by age, so a machine forgets a relay only
# long after it has stopped circulating.



# Put an arbitrary filesystem path into a shell command literally. Single
# quotes carry spaces, brackets, parentheses, ampersands and quotes, and the
# one character that cannot appear inside them is escaped the usual way.


# Where a video's poster frame is taken from. Ten milliseconds in is a fade or a
# black frame on most encodes, which is why so many posters came back blank; the
# frame people recognise is a little way in. The plain-file thumb path used this
# rule inline; the sealed path now shares it instead of always taking 00:00:00.010.

# A cached Music file_information entry is only worth reusing when it carries the
# facts the cards draw. A failed ffprobe used to be cached as
# { chapters => undef, tags => {} }: truthy, so it was reused for ever, and every
# video card asked for a duration and a height it did not have and fell back to
# the generic icon. The callers treat an unusable entry as a miss and re-probe.


# The old whole-file transmitter is retired: it downloaded the track on the
# remote and started `play` at a guessed offset. Remote audio is now a live PCM
# stream driven by public/js/music.js over /manager/music/stream. An older page
# that still sends method=transmitter reaches this no-op instead of starting a
# download.

# A remembered music queue (see music_queue_remember in Music.pl) is replayed
# into a reopened window only when it still describes the same library: a peer's
# paths mean nothing on this machine. What a window may *list* is a different
# question - sealed and private tracks are filtered out of the queue by the
# window it is being replayed into (music_queue_file_visible), the same rule the
# folder walk applies, so a list assembled while unlocked still comes back in a
# locked window instead of being thrown away. Pure, so the rule is testable
# without a database.


# The location types a device can point at a folder and archive to: one per
# <location>_location / <location>_archive setting pair, and one folder each
# under the archive root.

# The folder a location lands in under the archive root. A location's key is a
# setting name (video, rec); a person looking at the drive expects the words the
# folders use here (Videos, Recordings). An archive made before these names
# still reads: archive_location_folder keeps the old lower-case folder when it
# is the one that exists.
our %archive_folder_names = (
	music => 'Music',
	download => 'Downloads',
	photo => 'Photos',
	document => 'Documents',
	video => 'Videos',
	scan => 'Scans',
	rec => 'Recordings'
);


# The folder an archive keeps a location's files in. A drive filled before the
# readable names keeps its lower-case folder rather than growing a second one
# beside it; an empty or new drive gets the readable name.

# The machines that advertise an archive drive, once each however many rows or
# mirrors name them.

# The machine a location archives to. A configured <location>_archive wins by
# its signatorial (or uuid). When nothing is chosen and the house has exactly
# one machine with an archive drive, that machine is used - a single drive is
# not a guess. More than one candidate is a real choice, so it stays refused
# until a person picks one rather than let listing order decide.
# In list context it also says why there is no machine, for the refusal text.

# The archive root of this machine: the configure panel's pick first — it is a
# misc setting, so the root can be chosen without editing config.json — then
# config.json's archive_dir. Tidied: ~ resolved, no trailing slash. Undef when
# this machine is not an archive.

# Where an item lands inside an archive: <root>/<location folder>/<path inside
# the location folder>. The location has to be one we know, and the relative path
# cannot climb out of it, since the sending machine chooses both. `folder` is
# the location's folder, `parent` the folder the item's own file goes in.

# A selected path's archive plan. The location whose folder holds the path,
# the machine that location archives to, and where the item lands inside the
# archive. The longest matching location folder wins, so a scans folder inside
# documents resolves to scans; a tie, which is two names for one folder, goes
# to the earlier location type, so document beats scan. A path under no
# location is refused by name rather than guessed at; a location with no chosen
# machine uses the house's only archive drive, or is refused when the choice is
# genuinely ambiguous. Every path appears once however many selections repeat
# it.

# Make sure the archive root (config.json's archive_dir) has one folder per
# location type. A blank archive_dir — the default — means this machine is not
# an archive, so nothing is touched; an archive_dir that is not there yet is
# left alone rather than invented, since it may be a mount that has not come up.
# Folders that already exist are left exactly as they are, so this is safe to
# run at any time. Pass a path to check a specific root.

# The queue for work that has to outlive the request that asked for it: its own
# SQLite file under ~/.president. The web process enqueues, the worker in
# President.pl runs, and the folders app lists the same rows, so there is one
# place that says what is waiting, running or failed.
our $minion;

# A manager-to-manager agent for a job to use. The worker runs under
# President.pl and cannot see Manager.pl, so this is the small twin of
# subs::remote_useragent_maker: the cookie jar stored on the
# remote_machines row is the whole of the authentication, and the tunnel-aware
# manager url is the whole of the addressing.

# A manager-to-manager answer as JSON, with a readable failure when the far
# machine returns an HTML error page instead (a missing archive folder, a
# refused upload). Without this the sender only knows "the upload did not
# land" and nobody sees the reason.

# The worker half of archiving: deliver one queued item. The far machine is
# asked first whether it already has the file at that size and time, because a
# retry after a failed folder re-runs the whole folder and everything already
# sent should cost one small request each instead of the file itself. Errors
# are collected rather than thrown on the first bad file, so one unreadable
# file does not hide the rest; a job with any of them fails at the end, and
# Minion's retry skips what did land.
# Send one file to the archive machine. A small file is one request; a large
# one is cut into 64 MB pieces so no single upload has to survive a long
# request or a whole film's worth of buffering. Each piece is written at its
# offset, and a retry starts again at zero, so a dropped connection never
# leaves a half-written file that looks complete. Returns (bytes, error).


# The type an archive row carries, in the same words the folders app uses for a
# file, so a listing built from a manifest reads like a local one.

# One manifest row for a file: what it is and where it sits inside its location
# folder, with the media facts worked out once, so the apps reading a manifest
# never have to open the file. `relative` is what makes a row portable - it
# means the same thing on whichever machine is holding the drive.

# What an archive holds for a location: the compacted manifest with the journal
# read over the top of it. An append is one line, so a transfer never rewrites
# the listing; a read is one file plus whatever has piled up since. A line that
# does not parse - a write caught mid-flight - is skipped rather than fatal,
# and the last row for a path wins.

# Write the listing a reader sees. Rewriting the whole thing is the one
# expensive write there is, so it happens when the journal has piled up or a
# rescan asks for it, never per received file. A temporary file is renamed into
# place, so a reader can never catch half of one, and the journal is dropped
# once it is folded in.

# Read an archive location again from the drive itself and write the manifest
# from what is really there, for a drive filled by hand or shuffled outside the
# queue. It opens every media file it finds, so it runs as a job and says where
# it is in its notes.

# What an archive machine holds for a location, asked for by uuid, with the
# absolute folder those rows sit in - so a caller can address the files on that
# machine without ever mounting it. An unreachable machine is an answer too:
# the caller carries on without the archive instead of failing the whole
# listing.

# A short-lived copy of a manifest for callers that only need to know which
# local paths have an archived copy. Folders re-reads on every navigation, so
# one small request per location per fifteen seconds is enough; a finished
# archive shows up on the next read after that.
our %archive_manifest_memo;

# Where a photo that has left this disk can still be found. The archive machine
# holding photo_location is asked for its manifest once, and `locate` then
# answers for one path at a time, by the path's place inside the location. Only
# missing files are ever asked about, so a listing of live files never waits on
# a machine, and a machine that cannot be reached answers with nothing rather
# than failing the listing.

# Where a fetched item lands here: the same place inside this machine's own
# folder for that location. The inverse of the archive plan, and the only path
# a fetch writes to; the relative path is resolved so it cannot climb out.

# Bring something the archive holds back to this machine, into the place it came
# from: a whole folder - a series, an album - or one file. A folder is read out
# of the archive's manifest, so nothing walks the far disk over the tunnel, and
# each file is streamed down rather than pulled into memory, since a fetched
# video is a video. Anything already here, at the same size, is left alone.

# Ask the machine holding a path what it is: which location it belongs to and
# where it sits inside it. Only the machine that owns the drive can answer,
# because only it knows its own archive root.

# The files a folders selection names: every file, with folders walked, so a
# job can take a selection straight from the menu and a folder added to since
# the menu was drawn is still covered.

# Take something off the disk for good, folders with everything in them.
# Returns nothing when it went, and a line saying why not when it did not.

# Shred something: every file is overwritten where it lies and the folders they
# sat in go with them. Shredding is for files that should not be readable
# again, which is why the encryption turns to it too.

# The appointment entries that name a path, or a file under it when the path is
# a folder, so the folders app can hand a file an appointment has attached to
# the app's own file deletion - which lets the appointment go of it, takes the
# thumb with it, and tells the other machines - rather than pulling it out from
# under the row. Each answer is an appointment and the entry in it to delete.

# Whether a decoded thing names a path, anywhere inside it: an entry's f or
# thumb, an attachment wrapped around an entry, or a bare path in a list.

# Take the entries naming a path out of one decoded blob: an entry goes whole,
# a bare path in a list goes alone, and an attachment wrapped around an entry
# goes with it. Returns how many were dropped.

# Take a path out of the rows besides an appointment that write one down - a
# mailbox's attachments, the store's rows - so a file that is taken away is not
# still named by them. A folder covers the files under it, and a row that
# changed is stamped with the time so the other machines hear about it.
# Returns how many entries were taken out.

# Every place a path is written down, so that sealing a file or opening one
# keeps whatever points at it pointing at it: an appointment's file array, a
# mailbox's attachments (each one wrapped around a file entry), and the store's
# rows, which carry the same kind of entries as an appointment does. A backup
# remembers its sealed file as a bare path, so it is here too.

# Walk a decoded blob and hang every path in it off the map, so a path can be
# found again by what it names: an entry's f or thumb, an attachment wrapped
# around an entry, or a bare path in a list. What was found is kept with the
# blob it sits in, so the spot can be written back to.

# Every path the rows write down, read once, as a map from each path to where
# it was found, so a job sealing or opening a whole folder can look a selection
# up without dialing the database file by file. The looking is done on decoded
# values: the JSON written by this house escapes the slashes, so the stored
# text is no way to find a path in.

# What the rows remember about a path, from a set already read: the name the
# file went in under, and the encryption standard the row carries, the two
# things opening a seal again needs to hand the file back the way it was.
# Undefined when nothing points at the path.

# Put the new paths where the old ones were written down, in a set already
# read, and write back only the rows that changed. Each pair is named by the
# path it was, and carries where it went and the name it went in under; a
# moved folder hands its prefixes over instead, and every path under them gets
# its pair worked out from them. A row that changed is stamped with the time
# so the other machines hear about it, and an appointment that had a file
# sealed or opened says which encryption standard it is under now, the way
# file_encrypter and file_decrypter say it.

# The worker half of paste: put what was cut or copied into the folder being
# looked at. A move on one disk is a rename; anything else is copied file by
# file and the source taken away once it has landed, so a selection can cross
# disks, and a folder goes with everything in it. A move also hands the rows
# that pointed at a file its new path, once the old one has gone; a copy
# leaves what points at the original pointing at it. Errors are collected
# rather than thrown on the first bad file, and the job stops itself when the
# dialog asks it to.

# The worker half of encrypting: every file the selection names is sealed the
# way an app's files are sealed - openssl with the encryption standard and the
# suds as the password, a name of its own, and the plaintext shredded behind
# it - so the folder gives nothing away by its names. Whatever row pointed at
# the plaintext is pointed at the seal instead, and remembers the name the file
# went in under, so decrypting can hand it back the way it was. Files already
# sealed are left alone.

# Whether the start of a file reads as text. Plain text has no type File::Type
# knows, so it is the one thing a content check misses, and a password that
# does not fit never comes out as words: a stream of random bytes is printable
# about two fifths of the time, so a head that is printable throughout is not
# something a wrong password produces.

# The worker half of decrypting: every sealed file the selection names is
# opened with the first password that works - the suds the request handed
# over, since that is what the folders app seals with, then the padlock
# secrets the way file_decrypter tries them - under the standard the row it
# belongs to carries, falling back to the setting. It lands under the name the
# rows that point at it remember it by, and whatever pointed at the seal is
# pointed at the plaintext. The seal is only shredded once its plaintext is
# safely out, so a file no password opens is left exactly as it was.

# The sealed files under the given roots: dir_listing's find(1), with the name
# filter left to the child, so a home with a hundred thousand files costs one
# process to ask.

# system() with the child's stderr sent to /dev/null: openssl enc -d chatters
# "bad decrypt" on every wrong password, and a reseal pass tries many.

# A database backup is not a folder seal: backup_now appends its standard
# after the ciphertext, marked with the universal splitter (the restore path
# splits on it), so the tail tells the two apart without opening anything. The
# marker is 31 characters, which random ciphertext does not spell by accident.

# The rotation's tail on disk: walk the sealed files and put every one that
# opens under an old key back under the current one. The passwords are the ones
# a rotation leaves reachable - the current suds first, so an already re-sealed
# file is recognised and left alone, then every secret the security rows derive
# (the wrapped old keys among them, which is what finds the old seals). Nothing
# is ever lost to a guess: the original seal is replaced only once the new one
# is written and opens back to the identical bytes, a file no password opens is
# counted and left exactly as it was, database backups (recognised by the
# standard they append after the ciphertext) are left whole, and a file written
# since the rotation
# (mtime past `before`) is skipped without opening, since it is already under
# the new key. Batched by a time budget; when the budget runs out the job
# queues its own follow-up carrying a cursor - the walk is sorted, so the next
# run starts where this one stopped instead of re-walking the whole home.
# Where the sealed files live: the home plus every media location the misc
# settings name (music, download, photo, document, video, scan, rec). On a phone
# those point at /sdcard/... rather than the Termux home, so walking only ~ would
# leave a rotation's tail of /sdcard seals untouched.


# --- key propagation -----------------------------------------------------------
# A rotation has to reach the rest of the house, or the machines drift apart:
# each one ends up holding a different key, and only the machine that rotated
# can read what it sealed. So a rotation queues a push: the new key is handed
# to every linked machine over the signed peer rail, wrapped under the key it
# replaced. Only a machine still on that key can open it, and a machine on a
# different lineage fails the unwrap and keeps its own - divergence is not
# healed by adopting a stranger's key. A machine that is away needs no push: the
# canary syncs with the database, its next key resolution finds a vault that no
# longer validates and pulls the new key the way a keyless machine does.


# The queue's half: push the envelope to every machine with a pinned key. The
# result names what happened; machines that do not answer ride the pull path
# instead, the next time their database syncs the new canary in.

# Every job the queue can run, in one place. The worker and the code that
# enqueues register the same list, so a name can never drift between them.

# Resolve ~ once; this used to shell out to `echo $HOME` on every call. That
# helper is hit constantly (every settings/cache/db path), so caching it avoids
# a fork+exec per call.
our $home_dir;

# The newest mtime the app cares about, for the homepage "Last Update" label.
# This used to reuse ide_files(), which walks and stats the whole tree - about
# 9,400 files, most of them .pio/build artifacts and the public/icons set. It now
# walks only the project's own files, pruning the generated and bulk-media
# directories before descending: a few hundred stats instead of thousands.

# Paths under the given directories, for the walkers that need the whole tree
# (the ide's file list, the folders app's copy/delete, the archive, the music
# search). find(1) walks in C and streams NUL-separated names, so a large tree -
# a project, a home folder - costs one process instead of a Perl callback and an
# lstat per entry: measured about 5x faster for the music media search and 2x for
# a full listing that then stats each name. The directories go in as argv, not
# shell words, so nothing needs quoting, and NUL separation keeps awkward names
# whole. Falls back to File::Find where find(1) is not on PATH.

our $find_program;

# One level of the ide's tree. The editor opens with only the selected root's
# own children and asks for a folder's children when it unfolds, so a project is
# not walked and stat'd end to end (~9,400 files) before the window appears.
# Paths come back exactly as given, relative to the selected root, which is what
# the rows' file= and location= attributes key on.

our $ide_files = [];



our $database_holder;
our $database;

# One machine, one database, at a fixed path inside the install: database/jawnos.db,
# beside schema.sql. A machine never picks or moves it - the old "newest .db in
# start_dir" scan let any stray file silently become the database, and start_dir is
# gone from this path. Backups (.enc) live in database/backups/, out of ~/. The
# install dir is this file's own real directory, resolved once, so a probe started
# from a throwaway tree of symlinks still names the real install.
our $install_dir;
BEGIN {
	require Cwd;
	require File::Basename;
	my $real = eval { Cwd::abs_path(__FILE__) };
	# the install dir is the tree that holds perl/ and database/, not perl/ itself
	$install_dir = File::Basename::dirname(File::Basename::dirname(($real && -e $real) ? $real : Cwd::getcwd()));
}

# A house with a way back in starts gated. The paper recovery code is the
# emergency door, so a house that has one gets the padlock row, General as its
# context, and Enforce as the mode the first time this runs, then the marker
# makes it a default rather than a policy: Turn the gate off stays off across
# restarts. A fresh house with no way in is left alone, because turning its
# gate on before there is a way in would lock it out - a paper recovery code or
# an already-paired phone is that way in.

# One machine, one database: anything else under database/ is an older
# database's leftover (server.enc, laptop_*.enc, a stray .db) and is discarded.
# The working set is the jawnos database and its sidecars, the factory seed, the
# schema, and the jawnos backups - everything else is shredded. Directories are
# never touched, so the backups/ dir itself is safe.

# Adopt a pre-fixed-path install: move the database the old scan would have
# chosen, and the .enc backups beside it, into database/. Runs once, and only
# when the fixed database is missing, so pulling this build onto an existing
# machine needs no hand - the first database_grabber migrates it in place.



# One stable id per construct, independent of the name and of the device. The
# per-device `uuid` settings rows are the membership references and stay as
# they are; this is the id a name resolves to, and what an appointment carries
# (app_uuid) so a rename is not an identity change. Created lazily and memoised
# for the life of this worker.
our %construct_uuid_memo;



# The rows from a query as a plain arrayref of hashes - what db_query's
# ->hashes gives back, but over the shared handle with a statement cache and
# without the Mojo::SQLite::Results object and its per-call finalize. The hot
# readers (log_reader's per-poll selects) only ever ask for ->hashes, and that
# wrapper was a measurable slice of the poll. Anything needing more of the
# Results API still goes through db_query.

# db_raw's fresh twin: the same read, but on a freshly prepared statement, so it
# cannot inherit a cached handle that a dead request left executed-but-unfetched
# - such a handle answers 0 rows to every later read of the same SQL, and the
# mailbox threads hit exactly that. A fresh prepare costs microseconds, which
# the once-per-render readers can spare; the per-poll hot paths stay on db_raw.








# A raw-SQL fast path for the common db_select shape: one table, equality
# filters, and IS NULL for an undef value. SQL::Abstract was a measurable slice
# of a settings read (it re-derives the same WHERE every call). Anything richer
# - a ref filter value, or a $filters argument - falls back to db_select, so
# behaviour is unchanged.



# ---- theme surfaces -----------------------------------------------------------
# Windows and panels should read as a step away from the page background, in a
# grey that still carries a hint of the theme's hue. These helpers turn a theme
# background colour into the --panel/--panel-2/--ink values the CSS uses.


# Pick black or white ink to sit on top of an arbitrary background colour, so
# appointment/name labels stay readable whatever colour the theme gives them.
# The inks are weighed the WCAG way - each channel linearised and weighted
# before the sum - because that is how the eye reads them: the two tie at a
# luminance of about 0.179, not half way, so a hot pink like #ea43b8 takes
# black where a flat average of the channels inked it white.

# The mark a budget light wears, as inner SVG for a 24x24 viewBox. The four
# built-in budget modes each get something that reads at chip size - a repeat
# for a count of times, a clock for a duration, a price tag for a money total,
# a hash for a quantity. A user's special budget has no mark and falls back to
# its initial. Paths only: the caller owns the <svg> element and its fill.

# Render the CSS custom properties for a theme, given its background colour.
# Light themes get a light grey, dark themes a dark grey; both keep a whisper of
# the theme's hue. Returned as a declaration string so a layout can fold it into
# an inline style attribute.

# The named colour schemes the configure panel offers. One table, shared by the
# Misc panel (which paints its swatches from it) and the appointment theme
# dropdown (which stores a scheme name, not a colour), so the two can never
# drift apart. Each palette is a ramp the misc surfaces cycle through, in
# @gb::misc_settings order; the manager surface is therefore a fixed index.
our @colour_scheme_order = (
	'Blue', 'Blue Dark', 'Graphite', 'Graphite Dark', 'Green', 'Green Dark',
	'Indigo', 'Indigo Dark', 'Steel', 'Steel Dark', 'Amber', 'Amber Dark',
	'Teal', 'Teal Dark', 'Plum', 'Plum Dark', 'Rose', 'Rose Dark',
	'Nord', 'Nord Dark', 'Sage', 'Sage Dark', 'Mocha', 'Mocha Dark',
	'Geek', 'Geek Dark', 'Phosphor', 'Phosphor Dark', 'Cyberpunk', 'Cyberpunk Dark'
);
our %colour_schemes = (
	'Blue'          => [ '#eaf2fb', '#d6e5f7', '#b4cfef', '#86b0e0', '#4a90d9', '#0078d4' ],
	'Blue Dark'     => [ '#1b1b1c', '#232324', '#2b2b2d', '#353538', '#2f5f86', '#3f83b5' ],
	'Graphite'      => [ '#f5f5f7', '#e8e8ed', '#d2d2d7', '#aeaeb2', '#8e8e93', '#6e6e73' ],
	'Graphite Dark' => [ '#1c1c1e', '#242426', '#2c2c2e', '#38383a', '#48484a', '#6e6e73' ],
	'Green'         => [ '#e8f7f1', '#c9ecdf', '#a2dec8', '#74ceac', '#45b98d', '#1e9e6f' ],
	'Green Dark'    => [ '#16201c', '#1e2a24', '#26332c', '#30413a', '#2f6b52', '#3f9d76' ],
	'Indigo'        => [ '#eaf1fc', '#d6e3f8', '#b5ccf2', '#8fade8', '#6690dd', '#3584e4' ],
	'Indigo Dark'   => [ '#1b1e26', '#232734', '#2b3140', '#353c4d', '#37528f', '#4f78c2' ],
	'Steel'         => [ '#edf1f5', '#dbe3ea', '#c4d0db', '#a6b7c6', '#7e95ab', '#4e7ba8' ],
	'Steel Dark'    => [ '#1b2026', '#232a31', '#2b343c', '#354049', '#3a5d80', '#4f82ab' ],
	'Amber'         => [ '#fdf3e7', '#f8e3c8', '#f0cfa4', '#e0ab68', '#e67e22', '#c35e0a' ],
	'Amber Dark'    => [ '#201812', '#2a1f16', '#34271b', '#453325', '#c35e0a', '#e67e22' ],
	'Teal'          => [ '#e9f7f6', '#cdecea', '#a8dcd9', '#78c6c2', '#2fa8a2', '#0e837e' ],
	'Teal Dark'     => [ '#12201f', '#1a2c2a', '#223836', '#2e4a47', '#0e837e', '#2fa8a2' ],
	'Plum'          => [ '#f4eefb', '#e5d8f5', '#d0bcec', '#b393df', '#8b5cf6', '#6d3bd4' ],
	'Plum Dark'     => [ '#1c1626', '#241c31', '#2e2440', '#3c2f52', '#6d3bd4', '#8b5cf6' ],
	'Rose'          => [ '#fdf0f3', '#f9dbe3', '#f2c2d0', '#e79cb3', '#d64570', '#b02853' ],
	'Rose Dark'     => [ '#211419', '#2b1a21', '#36222b', '#462e39', '#b02853', '#d64570' ],
	# Cool, warm and green neutrals: the desk needed a quiet register between
	# the Blue scheme and the vivid accents. Each keeps the same six-step ramp as
	# every other scheme, so it works the Misc panel and the appointment picker.
	'Nord'          => [ '#eef2f7', '#dfe6ef', '#c8d4e4', '#a7b8d0', '#5e81ac', '#4a6b94' ],
	'Nord Dark'     => [ '#1a1f27', '#222933', '#2b3441', '#394658', '#5e81ac', '#81a5cf' ],
	'Sage'          => [ '#f1f5ee', '#e2ebdd', '#cdddc6', '#aec7a4', '#6f9e62', '#517f46' ],
	'Sage Dark'     => [ '#191f19', '#212921', '#2a332a', '#364337', '#4b7a45', '#6fa968' ],
	'Mocha'         => [ '#f8f1eb', '#efe2d7', '#e0cabb', '#c9a891', '#b07d5f', '#8c5b3f' ],
	'Mocha Dark'    => [ '#1f1915', '#29211c', '#332922', '#43352d', '#8c5b3f', '#c08562' ],
	# The terminal register: phosphor green on near-black, and a pale
	# green-tinted paper cut for daylight. Same six-step ramp as every other
	# scheme, with the green reserved for the accent step.
	'Geek'          => [ '#f4f8f1', '#e6efdf', '#d1e0c8', '#b4cba9', '#2f9e5b', '#1c7a42' ],
	'Geek Dark'     => [ '#060a07', '#0b110d', '#101812', '#16211a', '#1f8a4c', '#3ee37c' ],
	# Two more terminal registers: amber phosphor on warm black (the VT220),
	# and electric cyan on blue-black with a magenta accent (the cyberpunk).
	'Phosphor'      => [ '#faf5e9', '#f2ead8', '#e6d9bf', '#d3c09c', '#c07f13', '#8f5c08' ],
	'Phosphor Dark' => [ '#0a0805', '#110d08', '#17110a', '#21180e', '#8a5a12', '#ffb000' ],
	'Cyberpunk'     => [ '#eef7fa', '#dceff5', '#c1e0ea', '#95c8d8', '#00a6c2', '#007a90' ],
	'Cyberpunk Dark' => [ '#050a0c', '#0a1114', '#0e171c', '#142128', '#0e5f70', '#22e6ff' ],
);

# ---- named themes ----------------------------------------------------------
# A colour scheme is only the paint. A theme is the whole dressing: paint, icon
# set, material, face and corner. The presets below are the house's own curated
# bundles; a person may save more (see theme_registry). A name found here is
# what an appointment's Theme setting stores, so every machine that reads the
# row paints the same room.
#
# The four desktop looks are the house's own names: Jawndows, Cuperjawno,
# Jawnfish and Deepjawn. They keep the schemes, icon sets and faces they always
# had; only the borrowed name is gone. @theme_preset_order is what the gallery
# and the appointment picker offer. %theme_aliases holds the slugs an older
# database still carries, and theme_canonical() maps them onto the renamed
# bundle, so a desk that was already wearing one does not lose its dressing.
our @theme_preset_order = qw/deepjawn jawnfish adwaita cuperjawno jawndows mint nord sage mocha neon mono rose geek phosphor cyberpunk/;
our %theme_presets = (
	deepjawn => {
		name => 'Deepjawn', scheme => 'Blue Dark',
		icon_set => 'gnome', texture => 'soft',
		font => 'Noto Sans, system-ui, sans-serif', corner => 12,
	},
	jawnfish => {
		name => 'Jawnfish', scheme => 'Teal',
		icon_set => 'pastel', texture => 'soft',
		font => 'Cantarell, system-ui, sans-serif', corner => 16,
	},
	adwaita => {
		name => 'Adwaita', scheme => 'Graphite',
		icon_set => 'gnome', texture => 'soft',
		font => 'Cantarell, system-ui, sans-serif', corner => 12,
	},
	cuperjawno => {
		name => 'Cuperjawno', scheme => 'Graphite',
		icon_set => 'mac', texture => 'soft',
		font => 'system-ui, sans-serif', corner => 12,
	},
	jawndows => {
		name => 'Jawndows', scheme => 'Blue',
		icon_set => 'windows', texture => 'soft',
		font => 'Segoe UI, system-ui, sans-serif', corner => 8,
	},
	mint => {
		name => 'Mint', scheme => 'Green',
		icon_set => 'gnome', texture => 'paper',
		font => 'Noto Sans, system-ui, sans-serif', corner => 10,
	},
	nord => {
		name => 'Nord', scheme => 'Nord Dark',
		icon_set => 'outline', texture => 'fabric',
		font => 'Inter, system-ui, sans-serif', corner => 10,
	},
	sage => {
		name => 'Sage', scheme => 'Sage',
		icon_set => 'pastel', texture => 'fabric',
		font => 'Noto Sans, system-ui, sans-serif', corner => 14,
	},
	mocha => {
		name => 'Mocha', scheme => 'Mocha Dark',
		icon_set => 'outline', texture => 'paper',
		font => 'Palatino Linotype, Iowan Old Style, Georgia, serif', corner => 14,
	},
	neon => {
		name => 'Neon', scheme => 'Indigo Dark',
		icon_set => 'neon', texture => 'glass',
		font => 'JetBrains Mono, Courier New, monospace', corner => 14,
	},
	mono => {
		name => 'Mono', scheme => 'Graphite Dark',
		icon_set => 'mono', texture => 'metal',
		font => 'system-ui, sans-serif', corner => 6,
	},
	rose => {
		name => 'Rose', scheme => 'Rose',
		icon_set => 'pastel', texture => 'paper',
		font => 'Noto Sans, system-ui, sans-serif', corner => 16,
	},
	# Phosphor green, a monospace face, a CRT grain and square corners: the
	# dressing a terminal-dweller reaches for.
	geek => {
		name => 'Geek', scheme => 'Geek Dark',
		icon_set => 'neon', texture => 'sandglass',
		font => 'JetBrains Mono, Courier New, monospace', corner => 2,
	},
	# The VT220: amber on warm black, plain plates, outline glyphs, square
	# corners and the Courier face the terminals actually printed in.
	phosphor => {
		name => 'Phosphor', scheme => 'Phosphor Dark',
		icon_set => 'outline', texture => 'classic',
		font => 'Courier New, monospace', corner => 0,
	},
	# Neon nights: cyan glass with a magenta accent and iridescent glyphs.
	cyberpunk => {
		name => 'Cyberpunk', scheme => 'Cyberpunk Dark',
		icon_set => 'holographic', texture => 'glass',
		font => 'JetBrains Mono, Courier New, monospace', corner => 10,
		accent => '#ff3cc7',
	},
);

# The slugs written before the rename: a settings row, an appointment or an
# old jawnos-theme.txt may still say one of these, and it must paint the same
# room. Each is also kept in %theme_presets as an alias row so the save route,
# which refuses a preset's name, cannot let a saved theme take one - but
# theme_registry() skips alias rows, so the gallery and the appointment picker
# list only the new names.
our %theme_aliases = (
	windows  => 'jawndows',
	macos    => 'cuperjawno',
	cutefish => 'jawnfish',
	deepin   => 'deepjawn',
);
foreach my $old ( keys %theme_aliases ) {
	my $renamed = $theme_aliases{$old};
	$theme_presets{$old} = { %{ $theme_presets{$renamed} }, alias_to => $renamed };
}

# The slug whose bundle a name wears: a renamed preset's old slug resolves to
# the new one, and every other name (a current preset, a saved theme or a bare
# colour scheme) is returned untouched.

# A saved theme lives as one settings row: app misc, setting
# appearance_theme_custom, subsetting <slug>, value a small JSON document. The
# row is house-wide (device 'all') because an appointment may name it on any
# machine. Memoised for a second: icon_set() and texture_name() ask on every
# render, and each read is a query.
our ($theme_registry_memo, $theme_registry_time);

# A name an appointment may store: a saved/preset theme or a bare colour scheme
# (the older values still in the table). A pre-rename preset slug is resolved to
# the renamed bundle first, so an old row keeps dressing the desk.



# A name -> the whole bundle. Unknown names resolve to an empty bundle, which
# means "the Misc settings are in charge". A bare colour-scheme name resolves
# to that scheme and nothing else, so rows written before themes existed keep
# their meaning.

# The theme in charge: a running start/record appointment first, then the
# Misc Appearance choice. Blank means the Misc surfaces are in charge.

# A scheme's manager surface and its window surface. The palette is applied
# across @gb::misc_settings by index, so the manager is the same colour the Misc
# panel writes into manager_background_colour when the scheme is picked; the
# window is the next step of the same ramp, which keeps every theme's windows
# distinct from its desktop while staying in its motif.

# The scheme a manager colour came from, so a server-rendered desktop can pick
# its curated window colour. A hand-picked colour finds no scheme and gets a
# derived shade instead (theme_panel_css).


# The dark-theme counterpart of an appointment's colour. The named schemes ship
# a light and a dark cut with the same ramp, so a colour from a light scheme maps
# straight to the same step of its dark pair - the face the app would have been
# given had it been born on a dark desktop. A colour no scheme knows keeps its
# hue and its place on the lightness ramp, pulled into the dark desktop's range:
# the ramp's steps stay distinct instead of collapsing onto one tone.

# Every app's chosen theme in one read, for the appointment list (one query
# rather than one per app block). A house-wide row wins, then this device's,
# then the person's.

# The theme an actively running start/record appointment asks for: the most
# recently started one that has a theme. One join rather than a settings read
# per open row - a stale run must not cost the desktop a query per appointment.
# Blank when none is running.

# The manager background the desktop should paint now, plus the appointment
# theme driving it (blank when the Misc system theme is in charge). Both come
# from theme_state(), so a render asks the running-appointment query once.

# Tell every open manager to re-paint its body for the current active theme.
# A theme is more than a colour: the message carries the whole bundle, so the
# icons, material, face and corner change with it and no reload is needed.

# The native surfaces (the launcher and the lock screen) wear the desk's paint.
# They read the house database, not the WebSocket, so the effective bundle is
# recorded where they can see it: ~/.president/native_theme.json. A FILE, not a
# settings row, because a theme is this device's own (the phone and the laptop
# pick different ones) and a shared row would let the newest sync win on every
# machine. The launcher falls back to the Misc manager colour when the file has
# never been written.

# What the desk currently wears, as one comparable string: paint, effective
# glyphs, material, face and corner. The appointment flag is deliberately left
# out - it changes who owns the desk, not how it is painted - so a start/stop on
# the same theme pushes nothing and reloads no window.

# The colours the current theme is built from: the distinct *_background_colour
# swatches for a device (falling back through the other devices if unset).


# Snap an app's colour into the theme. If the existing colour is already one of
# the theme's colours it is left alone; otherwise a stable theme colour is chosen
# for that app and saved. With no theme colours configured, the value is returned
# unchanged.

# Wrapper used by the getters: skips the built-in apps and blank names.

# The currently selected pseudonym icon set ('' for the modern default). Memoised
# per process with a short TTL: icon_for() runs once per icon on every render and
# each miss costs a config read (a DB query plus Sereal decode).
our $icon_set_memo;
our $icon_set_memo_time = 0;

# Whether the active desktop theme is dark, and the scheme name driving it (blank
# when the Misc manager colour is in charge). Memoised on the same short TTL as
# icon_set() because a render asks it once per icon and once per surface.
our ($theme_state_memo, $theme_state_time);

# A misc surface's background for the theme that is in charge. A running
# appointment theme paints its own ramp across every surface - the same ramp the
# scheme picker would write - and the Misc theme keeps each surface's configured
# colour, darkened when the desktop is dark and that colour is a light face.

# Turn a light face into a dark one of the same hue. A colour already dark is
# left alone, so a dark scheme's curated ramp survives untouched.

# Called when the icon set is changed, so the very next render already uses it
# instead of waiting out the memo above. The theme memo goes with it: a scheme
# change can flip which cut of the set is wanted.

# When the hand-drawn set is active, swap a public icon path for its original
# hand-drawn PNG (kept in public/icons/original/) if one exists.

# The hand-drawn picture behind a public icon path, whatever icon set is
# selected - the gate's splash and the denial page wear it always. build.js
# renders generated tiles in at the old public paths, so the plain path no
# longer shows the hand.

# Resolve a button icon through the selected set, falling back to the given path.

# Resolve an app icon given its normal public path: hand-drawn originals for the
# hand-drawn set, or the matching /icons/sets/<set>/<basename>.svg when present.

# The colours a text control wears to sit beside the icon set's tiles: every
# generated tile is filled from hsl() values (the loud sets build their
# gradients from the same ones, so the first hsl() in the file is still the
# tile's colour) and the lightness says whether dark or light ink reads on it.
# The tile is named for the state the control is about - the page button wears
# the "now" tile at home and the back/forward tiles once it has walked. Memoised
# per set and tile: the files only change when build.js runs, while the manager
# re-renders constantly.
our %icon_plate_memo;

# A fingerprint of everything that gets baked into cached window/header HTML:
# the icon set, the active theme's dressing and the device's theme colours.
# Cached renders whose signature no longer matches are discarded, so closed
# windows don't come back looking stale.




&signatorial_establisher();



# A second copy beside the database. The home copy is the traditional one, but
# it depends on HOME, which a container, a `run-as` shell or a hand-run script
# can have wrong - and a database restored from another machine must never be
# able to change this machine's identity. The database directory is local, is
# not replaced by a restore (only jawnos.db is), and is excluded from the code
# sync, so this copy survives both.







# Whether this machine has a real GPS. termux-location names the provider that
# answered; only a `gps` answer proves the hardware. The flag is cache, which is
# this machine's own and never syncs, so one phone cannot lend its GPS to a
# laptop. A network fix can be a cell-tower guess blocks from where the person
# stands, so it never turns the flag on by itself.

# Remember that a real GPS answered here. Returns 1 once the flag is set.

# The app's GPS service writes each fix to ~/.president/location.json. Only a
# record that names provider=gps may become a place: a network fix looks like a
# fix in every other field, which is how the phone was reported in places it had
# never been. Returns the fix hash (aged by the fix's own timestamp) or undef.

# The navigation utility's own pace, in seconds. President adopts this machine's
# Batch pools. A pool is a group of utilities that wake together on one pace;
# the pace lives on the pool, not on each job, so moving a job between pools
# (or out of all of them) changes only where it is written down. Stored in the
# machine's utility row as a list, so the order is the person's:
#   __batch_groups => [ { id, label, seconds }, ... ]
# An older row stored a plain { id => seconds } map and reads the same; a row
# that has never been edited has no pools of its own and takes gb.pl's defaults.

# The pool a job belongs to, or undef when it runs on its own interval.

# The pace a job actually keeps: its pool's seconds, or undef when it is not in
# a pool (the caller then uses the job's own interval).

# A job table adopted from the stored utility blob becomes this process's runtime.
# `lasted_run` is process state - when this runtime last executed the job - so a
# marker written by a *previous* process (anything before this one started) is
# meaningless here: the stored value sat 103 hours old on one machine, and the
# tunnels watchdog read it as "stuck for twelve intervals" on the first tick after
# every boot, resetting every tunnel as the mesh came up. A marker this process
# wrote is kept, or the controller's periodic re-adoption would reset the clock
# every few seconds and no job's own gate would ever elapse. Everything else on
# the row (schedule, switches, network map) is carried over untouched.

# Does the runtime need to adopt the stored utility row? At boot, yes; after
# that only when someone else stamped it (the Configure editor, a peer merge).
# The controller writes its own row back with the same stamp it just stored
# (utility_runtime_stamped), so its periodic persist no longer looks like an
# edit and re-adoption cannot overwrite the live runtime with stale copies of
# last_run/lasted_run.

# Record on the runtime the last_change it just persisted, so the next tick's
# comparison sees the row it wrote rather than a newer stranger's.

# Whether the tunnels worker has been stalled long enough to justify restarting
# the tunnels on this run. No marker means this process has not run the worker
# yet (a fresh install, or the tick right after adoption), which is not a stall.

# The machine's navigation interval, in seconds. The runtime adopts the stored
# row from the utility controller at runtime, but Manager and the scripts do not
# share that process, so read the same persisted row here. A navigation job in a
# batch pool keeps the pool's pace.

# The pace navigation must keep right now, in seconds. The machine's utility
# interval is the base, but a running appointment whose app asks for fixes more
# often than that (its navigation setting, say 1m) is a request to update faster
# than the slower utility slot - so the pace follows the app down to a
# battery-wise floor. Base only asks for the utility's own pace.

# How long a fix the browser writes stays the machine's current place. It has
# to outlive the next automatic navigation run or the place falls back to public
# between fixes - the old flat five minutes did exactly that whenever the
# navigation utility was slower than five minutes. A scheduled watcher says when
# its own next run is due; otherwise the utility's pace (or the app's, when that
# is longer) is the gap to cover. One more interval lets the place survive a run
# that could not get a fix, and two minutes of grace absorbs a late slot.



# ---- Visibility -----------------------------------------------------------
#
# A thing's visibility is one of three words. `public` is shown as usual and
# `dangerous` is shown and stays open during a lockdown. `private` is a lock,
# not a place level:
#
#   * it is hidden at every place, including home, and never appears on the
#     timeline;
#   * it may only be located in a private place (rating 1) with no enemy
#     present - a public or dangerous place denies it entirely, even to an old
#     media padlock grant;
#   * even there it needs a live fingerprint grant on this screen (Security ->
#     Private apps, or the app's own padlock). No grant, no entry anywhere.
#
# The place rating is still read by the lockdown (a dangerous place, or an enemy
# present, closes the house). A person's relationship is numbered on the same
# scale - friend 1 (private), stranger 2 (public), enemy 3 (dangerous) - so an
# enemy's presence raises the room to dangerous. Strangers are not negative and
# do not change the room.
our %relationship_rating = (friend => 1, stranger => 2, enemy => 3);
our @relationship_order = qw/friend stranger enemy/;

# A relationship value as a number. Understands the new single values, the old
# multiple_select JSON list and the old relationship words, so a row written by
# an older build still reads. The most negative word in a list decides.




# The newest app_measures row for an app, across devices: a relationship is a
# fact about the person, not about the phone it was typed on.


# Every app that carries a relationship, newest row wins. Used by the
# junderground grade so the room reads the house's own relationship map rather
# than a second hand-typed list.

# Who is present: a person app with an appointment still running. junderground
# starts one for each other person in a room it has joined, and a person's own
# open appointment is a presence too, so this is the house's one local signal.
our $present_person_apps_cache;

our $presence_relationship_cache;

# A person with an Enemy relationship and an open appointment. During lockdown
# these are the only apps a fingerprint may reveal, one at a time, so the
# person can be seen and stopped.
our $lockdown_enemy_apps_cache;

# A dangerous place and an Enemy present are the same thing: the house locks
# down. There is deliberately no destructive "leave" here - the emergency wipe
# is a separate act, never something a sensor can trigger.

# The fingerprint reveal. It is a short grant on this device, not a change to
# the room: other apps stay shut, only the Enemy's running app appears, and the
# grant lapses on its own so the lockdown comes back if nothing is stopped.



# Close every window the lockdown does not allow, now. Security stays (it is
# the way to the fingerprint), an app marked dangerous stays, and the Enemy's
# own app stays only while this device holds a fresh reveal.
our %lockdown_sweep_at;

# The numeric rating of the room now: the place's own number, raised to 3 when
# an enemy is present. A house with no fix reads as public, the same default
# the manual place switch and the guide use.
our $visibility_exposure_cache;


# Normalise the visible setting. The three levels are the numbered place scale.
# `checked`/`on` become public (the new default); `unchecked` and the retired
# `off` become private, the least visible level that still exists.


# Visibility is inherited from the social constructs an app is part of, and
# the lowest-numbered level wins (Private 1, Public 2, Dangerous 3). A private
# row anywhere also locks the app everywhere: a stale row on another device (or
# one made before the app was hidden) must never expose it. Public and Dangerous
# are still read this device first, then the house's `all` row, then the
# person's `me` row, then the newest. No row at all is Public.
our (%app_visibility_cache, %app_visibility_own_cache, %app_visibility_rank_cache, %appointment_visibility_cache,
	%visibility_graph_links, %visibility_graph_uuid_app);
our $visibility_graph_ready = 0;

# One request-wide read of the visibility rows and the construct links. The
# links live in settings: a construct's own `uuid`, and the `sc_<kind>` arrays
# naming the constructs of that kind it is part of. The workspace writes both
# sides of a link, so the map is followed both ways and a private construct
# reaches every appointment filed under it.


# The strictest level in the app's construct component, itself included.


# A picker can ask about hundreds of apps at once (every appointment in the
# house). The graph is read once and every app's answer comes from the same
# request cache, so each check costs no query.

# An appointment's level is the strictest of its own app and every social
# construct named on the row. The field names come from $gb::social_constructs,
# so every kind - community, club, team, person, project, institution,
# government, corporation, place, vendor, event - is read, not a fixed list;
# `account` is included too. The lowest number wins, so a private project makes
# the record private even when its app is Public.


# Private is not a place level any more: it is a lock. A private thing is
# hidden everywhere, including at home, and only a live fingerprint grant on
# this screen can show it - and even then only in a private place with no
# enemy present. The place words stay because a lockdown reads the rating.

# A private thing may only be located in a private place during no lockdown.
# An unknown place reads as public, so a lost fix denies rather than reveals.


# The screen a request speaks for. media_unlock_store keys a fingerprint grant
# by the paired device uuid, not by the machine's device kind (device_setter),
# so the request boundary records the browser's own uuid here.
our $request_device_uuid = '';
our %private_revealed_cache;



# The domain -> app map the Internet app keeps. A site a person assigned to an
# app is that app's session too, so both the manager and the browser tick read
# the same map.

# A browser posts a site span every half minute while its page is in front
# (and as the page closes or loses focus). While a span for a mapped domain
# keeps arriving, its app's session runs. A gap longer than the grace is a
# person who left: the session stops at the last span's end, not at the next
# tick, so the recorded time is the time actually spent on the site.
our $internet_site_tick_at;

# A settings write or a presence change must be seen by the rest of this
# request; a worker serves one request at a time, so these are request caches.

# The plate remembers how its latest navigation stop happened. A departure more
# than three radii away is certain - no ordinary GPS jitter brings a person back
# from there - so a return must start a new session instead of reopening the one
# it closed. A near-boundary stop stays resumable for the fifteen-minute window
# in navigation_automation. The fact is transient (a cache entry), but it only
# has to outlive the next fix and the resume window.



# A departure more than three radii from a plate is a certain leave: no ordinary
# GPS jitter brings a person back to that plate from there. A loose fix is not
# certainty - 200 m is the house's own bound on a usable place - so a coarse
# reading does not count.

# The details bar offers autostop only where navigation_automation can act on it:
# a duty needs a radius and an action, and a place for the plate to measure from -
# its own coordinates, or the app's base plate, or the house's. A duty with no
# radius, or with its action left on none, never moves a session, so a switch
# built for it would promise something no fix ever acts on.



# The hour of the day each app most often happens at, over the recent past, in
# one query for every app. The clothesline reads in the order the day does, so
# this gives it that order; it also names the apps whose routine is regular
# enough to hang themselves, and the hour to hang them at. `hour_days` is how
# many of the days the anchor hour was seen on, `days` how many days the app was
# seen at all.


# ---- web measures ----------------------------------------------------------
# A web measure used to be a CSS selector plus a count, applied to whatever the
# last fetch stored. That works until a page reorders, and it cannot say where
# a JSON value lives. One spec now covers both worlds:
#
#   JSON:  { "path": "properties.currentConditions.temperature.value.en" }
#   HTML:  { "selector": "#price", "count": 0, "attribute": "text" }
#          { "row": "tr", "match": "Gold", "within": "td" }
#
# with optional regex, fallback, number/unit/scale and the old prev/next
# context. The old selector/count specs keep working unchanged; a JSON id from
# the prettyfier is mapped back to its path, so weather's old selectors start
# reading the decoded JSON instead of the rendered DOM.


# The JSON prettyfier writes <span id="propertiescurrentConditions..."> by
# concatenating the keys (arrays become 1arr, 2arr...). Recover the real path
# from that id, so an old JSON selector keeps working and can be read as a
# path instead of through the rendered page.

# Every scalar path a JSON response offers, for the picker and the audit tool.

# One number parser for every source. Currency, percent, a degree sign and a
# unit suffix are stripped; a comma decimal and a thousands separator are read
# by position; a leading minus (or parentheses) is kept. appt_measure_writer
# used to strip everything but digits and dots, which quietly turned -0.5 into
# 0.5.

# Some pages write a label as bare text, with the value in the next element:
#   Phase: <span>Waxing Crescent</span><br>
# Mojo::DOM drops text nodes from children(), so match the label in the
# container's own markup and return the first element that follows it.

# Extract one value from a fetched page. $ctx is { format, json, dom, raw }.

# Suggest working specs for a label on this page. The useful shape for a table
# is "the row that contains Gold, cell N", where N is the first cell *after*
# the label. Every candidate is tested against the page before it is offered,
# so a suggestion is a value the extractor will really read.

# Build the specs a person can choose after clicking a value in the web view:
# a JSON path, a table row, a label/value pair, or - last - the old CSS
# selector + count. Every candidate is run through the extractor, so the list
# only contains shapes that really read this page.

# app/setting rows, with the local device preferred but a row stored on another
# device still visible. A web measure is an app fact, not a device fact: the
# phone can be the headless browser and still use the selectors configured on
# the computer. Dedupe by $by when a setting has one row per subsetting.




# The contacts of one kind a person keeps: the plain setting (phone/email) and
# the typed list beside it (phones/emails, rows of {type,label,value}). Comparison
# tidies the way the rest of the code does - a phone to its digits (a leading 1
# dropped) so a country code or spacing never hides a match, an email lowered.


# Every app whose records hold this phone or email: the plain setting first
# (phone/email), then the typed list (phones/emails). A match is the address, so
# the two are scanned the same way - a number kept as somebody's work line names
# them as surely as the one on the app.

# Every line the house holds of one kind, one app's under it: the plain setting
# (phone/email) first and marked primary, then the typed list (phones/emails) with
# its type and label. A person with a home and a work line is one entry with all
# of them, not one per number - which is what the Phone app's directory and
# Chat's friends both want. Pass $only_app to read just one person's lines.

# How one line reads in a list: the number or address, and - for a line beyond
# the first - its type in front of it (a custom entry wears its own label). A
# blocked line says so.

# The app a number belongs to: the person who saved it, or - when the house
# does not know the number - the number itself, filed as an app of its own so
# a stranger's calls and texts still land somewhere, and naming that app later
# turns the stranger into a person. The phone row is made at the same time, so
# the next call or text from the same number resolves the same way. Matching is
# on the last ten digits of both sides, the way the call-log check learned to,
# and covers the typed list as well as the plain phone row.



# ---- warehouse / inventory helpers -----------------------------------------

# Where are we right now? navigation_automation starts a place when GPS says we
# are in it, which shows up as its 'toggle' being on. A device without GPS
# (laptop/desktop) can't do that, so we fall back to whichever running place is
# flagged with inventory ability.

# Split a typed quantity from its unit: "355mL" -> (355, mL), "12" ->
# (12, default). A known measure is returned in its canonical spelling (mL, not
# ml); with keep_unknown an unrecognised letter unit is returned as written so a
# caller can refuse it rather than silently count it as a bare number.

# What an item has on hand at one place and unit: the same signed stock rows the
# Levels view sums, but scoped so a consumption can take only what is on that
# shelf. Usage rows are history, not stock, and are left out.

# What an item has on hand right now: its signed stock rows summed per unit, the
# same figure the warehouse Levels view shows. A money row (it names an account)
# and a balance anchor (kind inventory) are not stock and are left out, the way
# warehouse_grabber reads them.

# What an item has on hand, in the unit its own app names (its `unit` setting),
# else its sole unit - what a fixed-level quantity budget reads. Zero when nothing
# of it is stocked.

# How to reach a stock target from what is on hand now, in whole packages where
# the item names them: a shortfall of four covered by a six-pack reads "buy one
# six-pack". The smallest pack that covers the shortfall is bought once; when no
# pack covers it the biggest is repeated; with no packaging at all the bare
# shortfall is the answer.

# The shelf life (e.g. '3w') declared on an item's packaging, if any.

# Where does an item live? Most specific first: a 'stock_place' setting on the
# item (or its app), then the older 'place' setting on either, a 'default_place'
# on the item's packaging, the app itself when it is a place (pos=place), and
# finally wherever we currently are. Returns '' when nothing resolves, and
# callers treat that as "do not touch stock".

# The journal metadata stored in a warehouse row's data column: why the stock
# moved, what app it came from, and the uuid of the document that caused it.

# Record a stock movement. Positive quantity puts stock in, negative takes it
# out. Only called once a place is known, so stock never lands unplaced.

# Record consumption that had no stock to take from. It is a history row, not a
# stock row: the Levels view and every balance ignore it, while the moves view
# and the item's journal still show that the amount was used. This is the drink
# that came from outside the warehouse - counted, but not owed to it.

# FIFO-walk the stock and write off whatever has outlived its packaging shelf
# life. Runs on a timer (see President.pl). Each write-off references the lot it
# expired via app_uuid, and since the write-off is itself a negative movement,
# the next pass consumes that lot and won't expire it twice.









# A plain public IPv4 address, or '' for loopback, private, carrier-grade NAT
# and anything that is not an address at all.

# The public-IP echo services offered under Configure -> Plat -> DNS. `all`
# asks each in turn so one service having a bad day does not leave the panel
# blank; `none` stops the lookup entirely.


# A machine's own public interface, without asking anyone outside. This is what
# a server shows when the external check is off: its NIC carries the address
# itself. A machine behind NAT has no public interface, so this returns ''.

# The address a remote machine presents on the public internet, as far as this
# house knows it: the address a hub saw it dial from (kept in `public_address`,
# or still inside the network blob), or one of its own interfaces when the
# machine sits directly on a public address (a hosted server). Returns '' for a
# machine behind a router that no hub has seen.


# ---- the tailnet: exit-node status and selection ---------------------------
# The remote_control panel's VPN button routes this machine's web traffic
# through a peer that offers an exit node, so sites see this device at that
# peer's address. A Linux peer drives its own tailscaled; the Android client
# answers through its own bridge instead (there is no tailscale binary or
# socket for the manager to call there).


# The tailnet address a roster row advertises, from its own network map first
# (a peer's ip column is often the LAN address) and its ip column second.
# The name this machine calls itself on. It is the configured domain with its
# first label replaced by `local` (oldtop.jonathanferwerda.com reads as
# local.jonathanferwerda.com), which the house's DNS points at 127.0.0.1: the
# router does it on the home LAN and Headscale carries the same record for the
# tailnet. The URL keeps the wildcard certificate, while the bytes never leave
# the device - so the manager opens without a VPN and without a round trip to
# another machine. `local_domain` in config.json overrides the derivation.

# ---- public naming ---------------------------------------------------------
# config.json's `domain` is an address, not a name: it is the loopback the house
# calls itself on, so it is deliberately not a public name. The public side
# lives in two synced settings: the house domain (the wildcard's zone and the
# WebAuthn RP ID) and a per-device map, keyed by signatorial, of the name each
# machine answers on. The map is written once from any machine and read by each
# device for its own entry, so a name never has to be typed on the device
# itself.





# A peer advertises its own name as its manager. On a machine whose dnsmasq or
# hosts map that name back to itself - or when a hub-tunnel manager sits at
# 127.0.0.1 while we are a peer, not the hub - reaching it that way loops home.
# When the manager host resolves to loopback, or onto the tailnet, fall back to
# the LAN address the peer reported in its network map, so same-net peers talk
# directly. The tailnet counts because 100.64.0.0/10 is CGNAT: a node that is
# offline blackholes the connection until the timeout rather than refusing it.

# The url to call for one candidate, in the order remote_machine_online probes
# them. A literal address is called directly. The peer's fqdn is called by
# name - unless the row is a tunnel, because a hub's hosts/dnsmasq can resolve
# the peer's name to loopback there and the stored tunnel manager is the only
# route that reaches it. Anything else uses the manager the row carries.

# ---------------------------------------------------------------------------
# Peer addressing without the tailnet
#
# The house names (*.jonathanferwerda.com) resolve through the tailnet's DNS.
# With the VPN off and no router entry for them, gethostbyname fails outright,
# so a row whose only address is its name cannot be dialled - even though the
# row still carries the LAN address the peer last advertised. The helpers below
# keep the literal addresses a row knows about ahead of the names, so the
# plain-wifi path is tried first and the tailnet name stays as the last resort.
# ---------------------------------------------------------------------------

# A literal address needs no resolver. (IPv6 literals are accepted so a row that
# already carries one is not skipped; the probe formats it as-is.)


# 0 = a private LAN or link-local address, 1 = the tailnet's CGNAT range,
# 2 = anything else. Probing a same-wifi peer on its LAN first means a dead
# tailnet route cannot hold up the pass, while the tailnet is still tried.

# The host and port a stored manager url names.

# A manager url with no route path. The panel and the CLI hand over the address a
# person clicks (https://host:port/manager), while the peer rail appends
# /manager/... itself: keeping the suffix dials .../manager/manager/configure/...
# and the pull reads the Gate page as "the peer sent no snapshot" (the tablet,
# 2026-10-31). A tunnel's loopback route is still a base url; only the trailing
# route segment is dropped.

# --- Android sshd ----------------------------------------------------------
# Termux's sshd_config comments out every HostKey line, Android has no /etc/ssh,
# and the login user's home in the passwd entry is the old Termux prefix. A bare
# `sshd` therefore starts with no usable host key (or resolves keys and
# authorized_keys under a path this app cannot read), and key auth silently
# fails while the port still answers. Start it once, here, with the prefix's own
# keys and an absolute AuthorizedKeysFile. StrictModes is off because it walks
# /data/user/0, which is system-owned.


# The argv for the daemon, with no side effects, so the options can be checked.

# Every literal address a peer row can be dialled at, best first: the stored ip,
# the LAN address it advertised, the manager's literal host, the address map,
# a stored pseudonym and the tailnet address. Names are added by
# peer_probe_candidates; they need the resolver and are worth trying last.

# The literal addresses first, then the names (the peer's fqdn and any name in
# its stored manager). A name that does not resolve is skipped by the probe.

# The one address a row carries without needing DNS, as a manager url. Used
# when a stored manager names a host that does not resolve on this network.

# Ask a peer whether it is there, and which address answered. The caller's own
# candidate ($opts->{ip}, e.g. a same-net probe) is tried first; the rest come
# from the row. A name that does not resolve is skipped without shelling out
# `ping` (that is the 'unknown host' noise on a machine with no VPN), and a
# literal address is still dialled when ping gets no reply: ICMP is a hint for
# how long to wait, never the gate, because a peer may drop echo while its
# manager answers. Returns { ok => 1, manager, ip, port } or { ok => 0 }.

# A loopback manager is the hub's own tunnel route. On any other row it is a
# leftover from a tunnel that no longer exists; a literal LAN address is the
# route that still works with the VPN off, and the peer's fqdn is the last
# resort (the name is only usable while the tailnet's DNS answers).

# ---- LAN presence: a peer on whatever network we have just joined ----------
# Every House machine broadcasts a small signed UDP datagram on its LANs. mDNS
# is the other advertisement, and the embedded devices use it, but Termux has no
# avahi - so a broadcast is the one discovery path the phone and tablet share
# with the computers. A beacon can only refresh a peer that is already in
# remote_machines (matched by signatorial); it never introduces a stranger, and
# the signed peer rail still authenticates every real request. The payload is
# signed once and rebroadcast, so the phone is not running openssl every five
# seconds.


# The interfaces a beacon is sent on, or matched against: a real IPv4 LAN, not
# loopback and not the public address.



# A beacon arrived from $peer_ip. Refresh the row only when it is one of ours and
# the address is on a network we are on, then wake the mesh so the sync starts
# now rather than on its next timer.

# Fold a peer's presence into this machine's own devices row, so the Dev panel's
# network cards show the peer at the address it is on now, with its purpose and
# the machine's own name. The entry is the same shape a scan writes, so the
# existing row actions and the tunnel/restore display keep working.

# The mesh wake is a cache row so the listener never forks; President's wake
# loop picks it up within a couple of seconds and runs the reconnector.

our $lan_beacon;
our $lan_reply_beacon;
our %lan_reply_at;

# One unicast beacon back to the peer that just told us where it is, so a machine
# that cannot receive broadcast (Termux on Android) still learns the peers that
# heard its sweep. Rate-limited per address.

# A directed unicast sweep of the /24 around each private NIC. Broadcast is the
# cheap path when it is delivered, but Android drops it for a Termux socket; a
# sweep on boot and on a network change reaches the same peers one by one, and
# their replies come back as unicast. Only a private /24 is swept, and only when
# the address changed or five minutes have passed.


# The known peers that share one of our current subnets, resolved to the
# address and manager port they answered from. The row's ip is tried first,
# then the NICs in its network report (including the `lan` entry the presence
# notices keep fresh). A caller that only needs addresses calls
# lan_presence_targets below.


# The physical LANs this machine is on: the interfaces the presence notices use,
# less the tunnel and tailnet adapters. A fix shared over a VPN would claim the
# receiving machine stands where the phone is when all the two share is a route,
# so the handover is limited to a real subnet.

# A handheld that has just taken its own fix hands it to the peers on this LAN,
# so a computer with no GPS of its own can be in the same place now instead of
# on the next mesh sync. Only a mobile sends; the receiving computer records the
# place but never repeats it, so there is no echo. Nothing here starts or stops
# an appointment: the handheld's navigation_automation already logged the visit,
# and a second start for the same place is exactly the duplicate to avoid.

# A fix arrived from a handheld on this LAN. Record it as this machine's own
# current position, with the same hold the handheld gives its own fixes, but
# deliberately do not run navigation_automation: the appointment the visit
# belongs to is the handheld's to start, and starting a second one here is the
# duplicate this handover exists to avoid.

# This machine's own current fix, used when a peer asks for it. A held fix from
# the last navigation run answers at once; when that is stale, ask the GPS with a
# short bound and fall back to the network provider, then to the last held fix.
# Read-only: the asking machine writes the place, and this one's own navigation
# keeps its cadence.

# The manual navigation button on a computer asks the devices that can actually
# see the sky: a teletype (the T-Deck serves /my_position on the LAN) and then
# any mobile peer on one of this machine's physical subnets. The peer route is
# signed and answers only a verified caller on the same subnet. Returns a fix
# hash, or an empty hash when nothing answers; the caller then falls back to the
# browser's own geolocation.




# Relay a request with no browser behind it. remote_relay_request reads the
# caller's request - its path, method and params - which a headless machine (the
# cloud, a utility job, a CLI) does not have; build a bare controller and hand it
# a synthesized request instead, so a server with no page can still hand a change
# on to its peers over exactly the rail the browser uses. $data:
#   path        => '/manager/...'           (required)
#   method      => 'post' | 'get'            (default post)
#   params      => { ... }                    (request params)
#   remote_uuid => a single target, else a flood to every reachable peer
#   extra       => extra_params for remote_relay_request (e.g. dissemination)


# Drain the headless relay queue: a JSON list of relay_headless calls left by a
# job or a CLI with no browser to drive. Each entry is relayed once and the queue
# is cleared, so a machine that has been away does not replay a stale backlog on
# every tick.

# The hub websocket endpoint a NAT'd peer dials out to. Preferred source is the
# hub's OWN manager URL from the handshake (e.g. https://thejunderground.com:45545),
# rewritten to wss -- so the peer dials the right host AND port instead of
# guessing from its own domain. config tunnel_hub overrides; the last resort is
# this machine's domain. The peer names itself with its own signatorial.

# Run the peer half of the wss tunnel: dial the hub's manager and serve its
# `open` frames. $manager is the hub's manager URL from the handshake.









# What device_scan does for a neighbour it finds on the LAN, done headlessly for a
# peer the hub holds a tunnel to: ask the peer's own /gate for its name, purpose,
# signatorial and restore list (its jawnos.enc backups), write them onto the
# neighbour row in this machine's own device address, then run the same handshake
# the Dev panel's Connect button does (remote_device_connect) so the roster row
# carries the buttons and hub-side manager. Without a browser nothing else does
# this for a tunnel, so the peer appeared in Dev with no name and no backup to
# restore from.



# --- the vault ---------------------------------------------------------------
# The suds at rest, sealed to this machine's own key file (~/.house.key, which
# never rides the database, a backup, or a code sync). One row per machine, so
# a merged database still opens on every machine; a database that leaves this
# machine carries only sealed rows, worthless without the key file.

# --- wrapping the house key to a device ---------------------------------------
# A device never needs the house key in the clear. To hand it one, the server
# mints a throwaway key pair, agrees a secret with the device's public key,
# derives an AES-256 key from the agreement (SHA-256 over both public halves
# and a context, so swapping either half changes the key), and seals the house
# key with AES-GCM. The blob carries the throwaway public half, an IV and the
# tag; the device repeats the agreement with its own private key.
#
# Two curves are accepted, and the blob says which one it is, because the
# devices are not alike: an app key is Ed25519 (signing only - this machine has
# no libsodium to convert it to X25519), while a phone's bio key is P-256 and
# can agree. Ed25519 is refused rather than guessed at, so a caller has to give
# the device a key that can actually do the agreement.
#
# Every wrap is fresh, so nothing is stored: there is no table of wrapped
# copies, and a leaked blob is useless once the throwaway half is gone.

our $house_key_wrap_magic = 'JHKY1';
our $house_key_wrap_context = 'jawnos/house-key/v1';
our %house_key_wrap_alg = ('Crypt::PK::X25519' => 1, 'Crypt::PK::ECC' => 2);


# house_key_wrap($key, $device_public_key_object) -> base64 blob or undef

# house_key_unwrap($blob, $device_private_key_object) -> the key or undef

# --- Ed25519 -> X25519 --------------------------------------------------------
# An app device's key is Ed25519: it signs but cannot agree. The birational map
# takes its public half to a Montgomery point, and its private seed becomes a
# scalar the same way libsodium does it (SHA-512, then clamp), so a device can
# wrap and unwrap with the key it already has. Checked against libsodium on four
# random keys: public and private agree byte for byte.
#
# Math::BigInt does the only big-number work and it runs twice per pairing, not
# per request; the private half is a hash and a clamp, so it is cheap.



# --- the recovery share -------------------------------------------------------
# The house key sealed to a password rather than to a machine: what survives
# ~/.house.key. It is a way back in, not a login.
#
# Argon2id everywhere: if the OpenSSL under this Perl predates 3.2, the
# reference `argon2` tool performs the same derivation with the same
# parameters and produces the same bytes (the probe asserts it). Only when
# neither exists does a new share fall back to scrypt, then PBKDF2 at 600k.
# The blob records the descriptor and the salt, so any machine can reopen it
# with either provider.
#
# The salt is a printable base64 string, not raw bytes: the command line takes
# its salt as an argument, and both providers must hash identical bytes.

our $house_key_password_magic = 'JHKP2';
our $house_key_password_context = 'jawnos/house-key/recovery/v1';


# The reference tool, for an OpenSSL without Argon2. The password arrives on
# stdin, never in argv; the salt is public and may ride the command line.

# (key, descriptor) - with no descriptor, take the strongest that works here



# Legacy (v0.1.959): the password is no longer a recovery share, so no login or
# route calls this. The seal/open primitives remain for the old sealed blobs and
# for their probe; nothing mints a new share.

# --- Shamir over GF(256) ------------------------------------------------------
# Splitting the house key so no one holder can unwrap it. The field is the one
# AES uses (x^8 + x^4 + x^3 + x + 1); subtraction is XOR, and each byte of the
# secret is split independently with a random polynomial of degree k-1.
#
# A share is { x => 1..255, y => the same length as the secret }. The field
# arithmetic is checked against known AES vectors and an exhaustive inverse
# sweep in the probe; three shares rebuild, two reveal nothing.




# shamir_split($secret, $k, $n) -> [ { x, y }, ... ]

# shamir_combine([ { x, y }, ... ]) -> the secret, or undef


# --- paper shares -------------------------------------------------------------
# A share meant for paper is Crockford base32, uppercase and grouped, because it
# may be written by hand: no case, no +/=, and I/L/O read as 1/1/0. The PS1
# prefix names the format; the gate still accepts the old base64 codes.
our $shamir_paper_prefix = 'PS1';
our $crockford_alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';





# Save each paper code as a QR PNG under a private per-machine folder. The code
# goes through a 0600 temp file, never the command line, and the PNG is 0600.
# The data URI is for the one-time display; the file is what the person keeps.

# The threshold this house uses. The policy is not secret (3:5), so it sits in
# settings and syncs with everything else; the shares themselves never do.

# The recovery door's share path: decode whatever codes were pasted, require at
# least k, and hand back the combined secret. The caller still checks the
# canary; a wrong or partial set yields a string it refuses.

# --- device-held shares -------------------------------------------------------
# A share can be stored sealed to a device instead of printed. The device makes
# an X25519 key just for this (not its login key: the browser's Ed25519 key is
# non-extractable and cannot agree), sends the public half here, and the server
# wraps one share to it. The server never sees a share in the clear.
#
# Recovery is the other direction: a machine with no key mints an ephemeral
# X25519 key, each holder unwraps its share and re-wraps it to that key, and the
# recovering machine combines the answers itself. The server only relays opaque
# blobs. At most one wrapped share is assigned per person, so one person with
# five devices is not a threshold.


# The current set is the newest set with any active shares. A recovery request
# names it, so a holder never releases a share from an older split (shares from
# two different splits never combine).




# Split $suds and wrap as many shares as there are eligible holders. The rest
# are returned as paper codes. Holders are device uuids; one per person (an
# unassigned device counts as its own holder key).

# A revocation is a deletion: a wrapped share the device can no longer open is
# still a row a copy of the database carries.

# Rotation makes every wrapped share useless (they open the old key) and leaves
# a note so the Recovery view can ask for a new set.

# --- the recovery request -----------------------------------------------------
# A machine with no vault asks for shares. Its ephemeral public key is the only
# thing stored; holders re-wrap to it, and the server relays blobs it cannot
# open. The request lives for half an hour.








# A fingerprint of the suds, for the session: a session proves it was minted
# under the current key without ever carrying the key.

# Does this candidate unwrap the level-1 canary (the current password encrypted
# with itself)? That is the check authentication_passer always made, now usable
# on any candidate key.

# --- the door and the key -----------------------------------------------------
# The login password gets its own row (sealed with itself), apart from the level-1
# key canary, so a password change never re-keys the house: the key lives in the
# vault, the password only opens the door. On a machine that predates the door
# the two are still one thing; login_gate migrates it the first time it is used.



# The login gate: (authorized, key). The key comes from this machine's vault;
# the password only has to open the door row. The house key itself is the root
# credential and opens the house in every state: with a door present it
# authorizes without touching the door, with no door it becomes the password,
# and a machine whose vault was lost heals its vault here. Neither password nor
# key ever travel in a session.

# The pre-vault derivation: the newest active ticket carries a copy of the suds,
# wrapped with the ticket's own one-time key. Kept as the migration path.

# The suds, resolved server-side. Sessions carry only suds_id now; nothing a
# client holds can produce the key.

# A machine whose vault is gone can ask a linked machine for the house key
# over the signed peer rail. The asker supplies a one-time secret; the donor
# seals the key to it (see /manager/vault_share), so the key never travels
# naked and a replayed answer is useless. Only a key the local canary accepts
# is handed back: machines holding different keys are a different problem.


# --- rotation -----------------------------------------------------------------
# Replace the house key with a fresh random one. Everything the database seals is
# re-sealed in place: the vault, the level-1 canary, the security history (earlier
# oldkey wraps included), note-shaped and binary-shaped settings values, and the
# neighbour-link credentials. The old key is wrapped under the new one as an
# 'oldkey' security row, which the file and note paths consult when deriving
# candidate secrets - so content sealed before the rotation still opens. The
# recovery code sealed the old key and is set aside (recovery_stale). Sessions do
# not survive: every suds_id changes, so browsers re-admit themselves through
# their device keys. $target lets a caller supply the key instead of generating
# one: probes rotate back with it, and /manager/key_push adopts a peer's new
# key with it; the local rotation route never passes it.
# One stored value, re-sealed from one house key to another. Returns undef when
# the value is sealed with neither the current key nor the legacy empty
# passphrase; the new sealed value otherwise. The unwrap is exact - Crypt::Simple
# checks its own digest and refuses a key that did not seal the value - so a
# value's bytes are proven, not guessed (its output is base64, so a shape test
# would say nothing). A note carries ':::---:::' inside that outer layer, and its
# own openssl layer is keyed to the real secret: it is remade whole, since
# re-wrapping only the outer layer would not open later. Values from the era when
# encrypter sealed under the empty passphrase are upgraded too - that key is
# public knowledge, so leaving them is leaving them readable to anyone holding a
# copy of the database.


# The half both re-seal sweeps share: the outer layer is already unwrapped, so
# this decides note or plain blob and hands back the value sealed under $Knew.
# A note carries ':::---:::' inside that outer layer, and its own openssl layer
# is keyed to the real secret ($K reaches a legacy note's inner layer through
# note_decrypter's own fallback), so it is remade whole - re-wrapping only the
# outer layer would not open later.

# The standalone form of the rotation's legacy side effect: re-seal one value
# still locked by the empty-passphrase era and leave everything else exactly
# alone (a value already under $K reports back as undefined, so nothing is ever
# rewritten for nothing).


# --- legacy seals -------------------------------------------------------------
# A sweep for values left from the era when encrypter sealed the outer layer
# under the empty passphrase (md5(''), public knowledge): out in the open to
# anyone holding a copy of the database. Unlike rotation this changes no key -
# each value is upgraded to the key this machine already holds - so it is safe
# on any machine at any time, idempotent, and cheap where none are left. The
# mesh form asks every linked machine to run its own, over the signed peer
# rail: nothing secret crosses, only signatures.

# Ask one linked machine to upgrade its own legacy values (its route runs the
# same local sweep) and hand back the counts. A machine that has not caught up
# with this code yet simply fails to answer.



# --- peer keys ---------------------------------------------------------------
# Every machine gets an Ed25519 keypair at first use (~/.peer.key, 0600, never
# in the database or a code sync). Requests between machines carry a timestamp,
# a nonce and a signature over method and path; once a peer's key is on file an
# unsigned request is refused, so a leaked address, cookie or signatorial is no
# longer enough to pull a backup or push code. The first verified contact pins
# the offered key to the peer's row (trust on first use).



# Name this machine and sign the request it is about to make. Attached to a
# peer user agent's start event, so every request on that rail is signed.
# The signing dance writes throwaway files (a message, a signature, a public
# key). They live in the app's own state dir on fresh File::Temp names, not on
# /tmp under a pseudo-random name: a phone without shred leaves /tmp names
# behind, and a leftover file the process cannot truncate turned every signed
# request into a 500 (Fe, found over the mesh), while a world-writable /tmp
# also lets a local name be pre-made as a symlink to clobber.


# Sign an arbitrary blob with this machine's peer key. The LAN presence beacon
# uses it: a datagram cannot carry HTTP headers, and an unsigned discovery could
# redirect a known peer's address.

# The server half: is this request really from the peer it claims, and has it
# not been seen before? Unsigned requests pass only while the peer has no key on
# file yet, so machines upgrade without a flag day; once pinned, only a fresh
# valid signature from the holder of the private key gets through.

# A login must prove the name it claims. peer_verify's unsigned path exists for
# a keyless row's first contact; a session that names a machine already on the
# roster is never allowed to use it.

# --- the house crest (People) ------------------------------------------------
# A crest is the house's face: one hand-drawn picture that people recognise. The
# picture is not the proof. A house key signs a record that names the drawing's
# hashes, and the short fingerprint on that record is what another house compares.
# Everything here is pure or settings-backed; nothing writes the live roster.












# The address another house reaches this one at. A configured domain that is
# not loopback wins, since it survives the machine moving between networks;
# otherwise the machine's private LAN address on the manager's working port.
# Empty when it has neither: a crest met in person still identifies a house that
# cannot be called, it just cannot be looked up until its address is known.

# Where a peer crest says its house can be reached. New codes carry the origin
# in the signed record; a card from before that names the manager endpoint, and
# the origin is that endpoint without /manager.

# A member machine backs the house crest with its peer key. The house key signs
# the crest itself; a cosignature is the same crest named by a machine, signed
# by the key the rest of the house already pins to it. It is identity only -
# uuid, house key and fingerprint - so a re-scan (a new dhash or version) does
# not require every machine to sign again.




# The cosignatures this house can check: a roster row that names the crest, with
# its signature verified against the key pinned on that row. The local machine
# is not in its own roster, so include_local adds a fresh signature of its own.

# A peer handed this house its cosignature. It must name the crest this house
# holds and verify against the key pinned to that machine; a row with no key
# yet pins the key its signature carries, the same first-contact rule the peer
# rail uses. The statement is kept on the row, so it still verifies after the
# request itself is gone.

# Tell the other machines which crest this one backs. Each peer verifies the
# signature against the key it already pins for us and records it on our roster
# row. The roster is this machine's own view and does not sync, so every machine
# posts to every peer: each one gathers the backers it has heard from itself.


# Normalize the drawing the same way every time: grayscale, level, deskew when
# the paper allows it, trim to the ink, and cap the long side. The color original
# is kept separately for the person to look at; this is the matching reference.

# A 64-bit difference hash: resize to 9x8, compare each pixel to its right-hand
# neighbour, one bit each. Small enough to store in the record, cheap to compare.


# Where a crest image lives. The record names the scanning device, but the app may
# be opened on another machine; try both photo locations before giving up.

# A peer crest's picture is stored under the importing machine's photo location,
# beside the house's own crest. The entry carries the file name and the device.

# A vouch is a signed statement by one crest about another. It is the same
# canonical JSON discipline as the crest record, and the signature is made by the
# vouching house's K_crest. Verification proves the key signed it, not that the
# key belongs to a house you know; the caller must match from_uuid/from_pubkey
# against its own roster.


# The crests this house has imported, kept as one settings array. Each entry is
# { crest => the signed record, image_file => ..., device => ...,
#   imported_at => ..., status => imported|met, met_at => ...,
#   vouches => [ claims the other house presented ], vouch => our signed vouch }.
our $crest_peer_list_cache;
our $crest_peer_list_raw;






# A crest can be linked to one of the house's chat/mail contacts by the same app
# name those lists use. The link is one settings map, so it syncs with the rest.





# Vouches this house has received: another crest's signed statement that this
# house is the house it says it is. They travel on this house's card so a third
# house can see who introduced it. Outgoing vouches stay on the peer entries.



# The house that issued a vouch, when its key matches a crest this house already
# knows (its own or an imported one). Undef means the vouch is a claim, not an
# introduction this house can stand behind.

# A card carries a display copy of the drawing (a small JPEG) beside the signed
# record. The JPEG is not the signature; the record's dhash is. Import normalizes
# the JPEG and checks it against that dhash, so a swapped picture is caught.


# A compact signed record for a QR code or an NFC tag: the name, key,
# fingerprint, dHash and signature, without the picture or the vouch chain. It is
# zlib-compressed and base64ed; the prefix says which form it is.



# The crest drawing is public, and a 512px copy is small enough to ride the
# settings sync with the record. The dHash in the record still checks it, so a
# tampered copy is refused when a machine materializes it locally.



# A machine that has the record but not the drawing (a phone after the settings
# sync) writes the synced 512px copy into its own photo location, named the way
# the record names it, after checking the picture against the record's dHash.

# --- construct crests --------------------------------------------------------
# A construct's crest is the same scheme as the house crest - a signed record
# pinning the drawing's hashes, a card and a compact code - but it is signed by
# the house key and names the construct it belongs to. The house is the
# authority for its own constructs; a separate key per construct would add a key
# to guard and prove nothing more.


# The drawing identifies the construct, not the house key: uuid, construct name
# and dHash are what make this fingerprint different from another construct's.





# Authorization beside authentication. peer_verify answers "is this who they
# claim?", peer_allows answers "may this house do this, and is the lease still
# alive?". Call it only after peer_verify has accepted the row for this request:
# the stash is the proof that the row was verified, never the signatorial in a
# query string (a name is public and quotable).
#
# Scopes are a ladder - visitor < resident < trusted. A resident is the house's
# word for a peer that may act here (start and stop appointments, toggle things,
# press Go, open a Manager) but may not touch configuration; configuration stays
# citizen-only at the session gate. member is the older spelling of that rung,
# so a row written before this vocabulary still reads. A row with no scope is an
# older peer and keeps exactly the trust it had before grants existed; an
# unknown word is never a promotion. grant_expires is epoch milliseconds, the
# same clock server_time uses; empty means no expiry (also grandfathered).

# What a peer may ask for, and the rung each needs. config is absent on purpose:
# configuration is session-citizen only, never a peer grant. A route gate calls
# peer_allows with peer_action_scope($action), so this table is the one place the
# policy lives. A resident may act in the house (start and stop appointments,
# toggle things, press Go, open a Manager) but a visitor may only look and reply.

# The action a manager movement names, so /manager/reset and the appointment
# writer share one mapping. Anything unrecognized is an appointment write and
# needs a resident; a command is the higher tier.

# A readable kind for a paired device. The stored kind is set when the row is
# made or when an app/biometric key is added; an older row with no kind falls
# back to its keys and agent. webview is the desktop's WebKit windows.

# A sliding window per proved peer. The cache table is local and unsynced, so
# these rows never travel; a race between workers can let a few extra through,
# which is acceptable for a spam brake.


# --- people ------------------------------------------------------------------
# A person is the identity; a device is how they carry it. Until now every
# paired device was a citizen by itself, with no way to say whose it is. The
# first person is the owner, at a fixed uuid so every machine in the mesh agrees
# on the same identity.
#
# Existing devices are attached once, when the owner is first ensured, so an
# older house migrates without anyone re-pairing. A device with no person still
# enters as a citizen (the behaviour before this table existed); once assignment
# lands, the lookup here is where the session's privilege comes from.



# The privilege a device's session wears: its person's, or guest when nobody
# has claimed it. A device with no person is never a citizen.

# What a session's privilege must be to reach a path. A citizen reaches
# everything; a resident everything except the citizen's desk; a guest nothing
# under /manager (the public and device rails are carved out by the caller, in
# hooks.pl, because they authenticate themselves). The patterns are anchored on
# purpose: the old unanchored strings also matched any path that merely
# contained them.
our $tier_required = [
	[ 'citizen',  qr{^/manager/(?:configure|security|magazine/publish)(?:/|$)} ],
	[ 'resident', qr{^/manager(?:/|$)} ],
];
our %tier_rank = ( guest => 1, resident => 2, citizen => 3 );

# The privilege a path needs, or '' when no tier claims it.

# Does this session fall short of the path's tier? An unknown or missing
# privilege has no rank and is refused, never waved through.

# Does this privilege reach the house's own rails (resident or above)? A guest
# ticket minted by a peer is still a guest, and 'visitor' (the box office's
# fallback default) is below a guest for this purpose.

# A person at a browser holding a ticket below house level, as opposed to a
# paired device with no person of its own. Rails that are public only so a
# device or a peer can reach them refuse the former; a device is the machine's
# own face and keeps its door.

# A revoked person is revoked for every session at once: the session carries
# person_uuid and, for a device, device_uuid, so both are checked rather than
# waiting for a cookie to expire.


# Whether a session may still be trusted: its person and its device are both
# active. A session with neither (a password bootstrap) is not the caller's
# question - it is handled by the gate itself.

# Revoking a person is one move: the person, every device they carry, every
# wrapped share one of those devices holds, and the invitations written to them.
# The owner is the house's own identity and cannot be revoked from here; the
# person using the current device cannot revoke themselves out of the session.



# Whether an assignment may be made. The device in the hand is the one thing an
# assignment must not quietly demote: the live session keeps its privilege until
# the next login, and the next login would read the lower one.

# A ticket is an invitation; the person it admits is the identity that outlives
# the link. The first login mints one from the ticket's name and privilege and
# writes the link back, so a resumed ticket keeps the same person. The ticket's
# own privilege remains the session's grant - this is attribution, not a second
# source of privilege.


# Validate a grant before it is written. Kept pure so a probe can exercise the
# policy without a database. Returns a normalized hashref, or undef when the
# scope is missing or unknown (a typo must never become a permission).
#
# privilege is the relationship, not the capability: citizen is the owner's own
# machine, peer is another house, visitor is an introduced house not yet a peer,
# and guest is a one-off device. grant_scope still decides what the row may do.

# Write a grant to a roster row. The caller decides who may set one (a citizen
# route, or a house acting on its own roster); this only refuses garbage and
# keeps privilege untouched unless it was named.

# Verify an Ed25519 signature (base64) over a message against a PEM public key.
# The shared primitive behind peer_verify and the paired-device challenge.

# Verify an ECDSA P-256 signature (base64 DER) over a message against an SPKI
# DER public key (base64). The phone's biometric key is an Android Keystore EC
# key: the OS releases it only after the person authenticates, so a valid
# signature is a real factor rather than a client-side confirmation.

# The public half is accepted only if it is an EC key on P-256, the curve the
# Android Keystore key is made on.

# --- the recovery code --------------------------------------------------------
# The paper code: eight groups of five from Crockford's alphabet (no I, L, O or
# U to mistype). Verification is the decryption itself - the code unwraps a copy
# of the suds sealed to it - so the house keeps no hash, only the sealed blob.
# n characters from Crockford's alphabet, straight from /dev/urandom: the house
# key material of the recovery code, and the short codes humans compare. Perl's
# rand (predictable, and inherited by forked workers) is not good enough. Each
# byte mod 32 is uniform: 256 divides by 32.


# the approval code: short enough to compare across two screens



# ---- OAuth2 for mail accounts ------------------------------------------------
# Outlook and Gmail no longer accept a plain password over IMAP or SMTP. An
# account can be marked auth=oauth2 instead: the house runs the OAuth 2.0 device
# authorization grant - it shows a short code, the person approves it at the
# provider, and the refresh token is kept (sealed) to mint access tokens after.
# The access token rides XOAUTH2 for both IMAP and SMTP. A plain-password account
# is untouched: every branch below only fires when auth is exactly 'oauth2'.

# The OAuth2 clients the house can sign in with: one entry per app registration
# (a name, a provider, a client id and secret, a tenant and scopes), kept as a
# setting so it syncs and so several accounts can share the one registration. The
# secret is sealed like a mail password.

# An account may name a registered client instead of carrying its own id/secret/
# tenant; this lays the client's fields over the account's, so every caller goes
# on reading the same keys.




# Write fields back onto one account in the email_config setting.


# A live access token for the account: the one held if it is still good, else a
# fresh one minted from the refresh token.

# Log an IMAP connection in, by XOAUTH2 for an oauth2 account or by password
# otherwise. The SASL initial response rides as an IMAP literal, which is what the
# continuation the server answers is for.


# Send what waits in the outbox. A uuid picks one letter and sends it on the
# spot - the compose side calls it the moment a letter is written, so nothing
# waits for the sweep. The uuid-less form is the utility's, and it keeps the
# old manners: only this device's letters, and never ahead of their timestamp.

# Letters the server accepts all come through here: the imap reader, the
# telephone's sms list, a watch, a neighbour posting one over. The message
# travels to the websocket daemon over the mail socket, which matches it to
# open mailboxes, dots the start menus' mail icons, and lets the regular
# notification speak when no mailbox is watching the thread. The envelope is
# rendered here because a controller is what reads the words back out.


# A letter that leaves is filed like one that arrives: an appointment on the
# app of the address it went to, so that app's details show both sides of the
# conversation. The attachments are copied into that app's own folders and
# written into the row's file column, and the mailbox row's uuid rides in the
# data so the envelope in the details can open the very message.


# The instruction that tells a chat model how to ask for media, appended to the
# system message so the trigger does not depend on a magic marker the model may
# or may not emit: any model that can follow a JSON shape works. Empty when no
# generation agent is configured.

# The first balanced {...} object in a string, respecting quoted strings, or
# undef. Lets a reply that mixes prose with the action still be read.

# Read a chat model's reply for a media request. Prefers the explicit JSON action
# the instruction above asks for ({"action":"generate","kind":...,"prompt":...}),
# and falls back to the legacy markers (dalle.text2 and kin) so a conversation
# configured the old way keeps working. Returns (kind, prompt) or ().


# --- the evaluation agent -------------------------------------------------------
# The evaluate buttons hand an app - or the whole house - to this. The raw
# appointment numbers are rolled up first: counts, durations, an hourly and a
# weekday profile, and one count per calendar day. The relational window's
# links (the sc_ lists, one per construct) are walked to find the apps tied to
# it, and each tied app's daily series is lined up against the app's own and
# correlated - Pearson, tried at a small spread of lags, so a thing that
# follows another can say so. Only then does a model speak: its job is the
# words - trends, correlations, predictions - never the arithmetic, which the
# numbers below it have already done.


# the busiest few values of each kind, so a window says what the activity was
# made of without opening the whole catalogue

# Every appointment the house knows, by its unformatted name. Membership is a
# pos setting (every app carries one), which is broader than the built-in
# known_appts and so catches a project that is really an appointment too.

# What one of a unit is in millilitres (or grams, near enough), when the unit is
# a measure the house uses; undef for a bare count ('each', '', an app name),
# which is a number of things, not an amount.

# What one logged unit of an appointment is: the app's quantity setting, read as
# an amount and a unit (coffee logs '10oz' a cup, soap '0.25'). A bare number is
# read as millilitres, the house's habit. Undef when the app records no serving.

# The amount an app's window adds up to, spoken in one unit. A logged quantity is
# already an amount when its own unit is a measure; the app's serving is the
# default for the appointments that logged none, so every one is counted. All of
# it is put in millilitres and then back into the unit the app speaks.

# every app the relational window has tied to this one: the sc_ settings are
# uuid links, one list per construct, and 'all' means every app of it

# two apps' day counts, lined up over the union of their days

# Pearson's r at a small spread of lags; the best fit wins, so a follower can
# be told from a leader. Positive lag means the second series trails the first
# by that many days. Undef when there is too little shared history, when the
# pair is almost all zero days, or when either line never moves

# every numeric measure the window's appointments logged, averaged per day:
# { app => { measure => { day => average } } }. A condition word is skipped;
# the measure's own reading time wins over the appointment's, so a humidity
# log lands on the day it was read

# A number as a person writes it: two decimals at most, trailing zeros dropped,
# so a rate reads "3" not "3.00" and "0.03" stays "0.03". The briefing hands
# the model plain figures, and it should not parrot "3.00" back.

# The readings an app logged against its appointments, so the report can speak
# the numbers themselves and not only the correlations they make. A logged entry
# is a snapshot of every measure the app carried at that moment ({weight => 180,
# pressure => 120, ts, uuid}); the app's own app_measures setting names the unit
# and the range the reading is set to expect. Numeric readings are summarised
# (readings, average, min, max, the latest and when it was read); a text or
# select reading keeps its latest value and the spread of values seen.
# An app's appointments gathered into episodes: walked in order and merged
# wherever the gap from one to the next is small, each an { ts, stop }. A night
# broken by a waking is one episode; a single cup is one. The split gap is read
# from the app itself - a coffee (minutes long) splits from the next by a few
# minutes, a night (hours long) only by a long gap.

# An app's natural unit rather than a count per calendar day: a night, a cup, a
# session, a walk. Reports how many episodes there were and how many an active
# day, the median and longest, the hour each began at (so a sleep reads as a
# bedtime, a coffee as a time of day) and, where the app logs a quantity, the
# amount an episode, a day and in all.

# The typical gap from an episode of one app to the nearest episode of another -
# the last coffee before a night's sleep, the walk before a meal - so a
# relationship carries a time. Works on episode onsets, so a night is one onset
# and not each record, and the median is signed (negative when the other tends
# to come first).

# What conditions the app runs under: every numeric measure any app logged is
# read against the app's own episodes. Two contrasts are weighed - the reading in
# the windows around the episodes against its value everywhere else (around), and
# its mean on the days the app ran against the days it did not (day) - and both
# are handed over, with confidence saying which stand (both, day or around),
# because a daily thing like weather is honest at the day while a
# moment-to-moment thing is honest around the event, and a condition that only
# leans around may just be the hour of the clock. A walk in the cold, an eczema
# day in the damp, steps that climb with a walk: the measure's app is what
# carries the condition, so a weather app's temperature stands beside the apps.

# Speed is a reading of movement, and an app is a movement only when its own
# construct (its POS) is action. A MAB is a "might also be", and every start or
# stop takes a GPS fix and gets a derived speed whether or not the app moved -
# programming is a service that might also be an action, and its speed came from
# the fix rather than from the work. So a MAB alone does not make speed relevant.


# Which device was actually with the person over a set of fixes. Every phone,
# tablet and watch writes its own continent rows, so one appointment can hold two
# tracks: the tablet left in the house and the phone that went for the walk. The
# device that covered the most ground is the one that went somewhere. A step
# shorter than the jitter floor is a stationary device shuffling, so it is not
# counted; steps are measured from the last accepted fix, so a walk whose fixes
# are spaced far apart still adds up. Ties fall to the device with more fixes,
# then to its signatorial, so the answer does not change between reads.
#
#   my $carrier = &subs::carrier_device($fixes);
#   # { signatorial, metres, fixes, devices } or undef

# A device's signatorial as the name the house knows it by: the first label of
# its house address (phone, tablet, laptop), then a peer's hostname, and this
# machine's own name when neither is known. One place, so a carrier line, the
# movement picker and anything else name a machine the same way.


# Which device records an appointment's movement. Two machines carried together
# would each file their own fixes and the appointment's distance would be
# counted twice; one device records and the rest keep their own current place
# and their home plates, they just do not file the appointment's movement.
#
#   my $sig = &subs::movement_recorder({ app => $app, appt => $uuid, signatorial => $me, timestamp => $t });
#
# The house setting movement_device answers: a signatorial names that machine,
# 'every' lets them all record (the old way), and 'auto' (the default) takes the
# device that has actually covered ground in the last hour, preferring the one
# that has been recording the appointment longest. A device standing still never
# wins over one that is moving, so a tablet left in the house cannot take a trip
# away from the phone that went for the walk.

# The decision behind movement_recorder with the rows already read, so it can be
# tested without a database. An explicit choice answers at once; 'auto' reads
# the appointment's fixes from the last hour and picks the device that went
# somewhere, the longest-recording one first.

# The places an app went, read from the continent table the GPS fills. A walk's
# track is a run of latitude/longitude rows tied to the appointment; summed here
# into what a report can use: how many places, how far (km), for how long, the
# box they fall in, where it started and ended, and the speed in km/h - from the
# speed the readings carried (the fix gives m/s), or the average worked out from
# the distance and the time when the readings carried no speed of their own.

# The speed a GPS fix carried, saved where the evaluator's measurements live: an
# entry on the appointment's own measures ({speed => 5.0, ts => ...}), so every
# reading counts in the readings, averages and trends the same way a typed-in
# measure does. The house reads speed in km/h (the fix carries m/s). The app's
# measure table gets a name for it the first time, so it is a measure the house
# knows rather than a stray key. A fix with no speed (the device gave none) is
# left alone.
#
# Volume is the worry on a walk: a fix every few seconds would pile hundreds of
# readings on one appointment. So a reading is kept at most once a gap, and a
# long track keeps its most recent readings, not all of them. Both knobs are here.
our $SPEED_MEASURE_GAP_MS = 60000;   # one reading a minute
our $SPEED_MEASURE_CAP = 500;        # a single appointment keeps this many at most

# The clocks a trend is read from, the same scopes the inventory graphs. Each is
# summarised for the last few periods (oldest first) rather than one span's
# total, so a week that fell away or a month that doubled shows in the shape.
# A period with nothing is kept, because a gap is a trend too.
our %PERIOD_TREND = (
	minute => { seconds => 60,      cap => 60, bucket => "strftime('%Y-%m-%dT%H:%M', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime')" },
	hour   => { seconds => 3600,    cap => 24, bucket => "strftime('%Y-%m-%dT%H', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime')" },
	day    => { seconds => 86400,   cap => 31, bucket => "date(cast(timestamp as integer) / 1000, 'unixepoch', 'localtime')" },
	week   => { seconds => 604800,  cap => 26, bucket => "date(cast(timestamp as integer) / 1000, 'unixepoch', 'localtime', 'weekday 0', '-6 days')" },
	month  => { seconds => 2678400, cap => 24, bucket => "strftime('%Y-%m', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime')" },
	year   => { seconds => 31622400, cap => 12, bucket => "strftime('%Y', cast(timestamp as integer) / 1000, 'unixepoch', 'localtime')" },
);

# Where the moment sits in the calendar period it is in: the start, the start of
# the next period, and the fraction between them (0 at the opening instant, 1 as
# the next period begins). The periods come off the calendar - a month is however
# many days it holds, and daylight saving is honoured - the same way father_time
# builds a locked window, so a pace read here and a window drawn there agree.
# $week_start is the weekday a week begins on (0 Sunday, 1 Monday): the budget's
# locked window and the trend buckets start their weeks on different days, so
# each caller says which. This is what lets a part-run period be read as a pace
# rather than a fall.

# the label of each of the last $n periods of a scope, oldest first, in the same
# form the SQL bucket produces

# The last few periods of every scope, oldest first, as "label=count ..." - the
# same compact shape as a window's daily_counts, but for month, week, day, hour
# and minute as well, so the model reads the pace period by period. $count is the
# app's own scope count (how many periods its graph walks), capped per scope so
# the short clocks do not swamp the prompt.

# every day of the window, so a lag stays a lag in calendar days even when a
# series has holes in it

# Pearson over day maps that may have holes - a day without a reading is not a
# zero reading - joined on the window's days, so the best lag is in days

# Two series that both run on nearly every day of the window correlate by
# construction - the calendar, not a cause. The maps that can have holes
# (measured readings) count a day by being defined, the others by being non-zero.

# what else was happening: every app's daily counts and every numeric measure
# any app logged, correlated against the targets. The relational window only
# knows the apps it was shown, so a headache never gets to blame the humidity
# unless it is asked to look at the whole house.

# What ran around this app's own occurrences: for each occurrence, the other
# apps whose occurrences fall within a window either side of it, so a thing that
# consistently happens at the same time of day - the coffee after waking, the
# walk after lunch, the code right after the coffee - stands out. A correlation
# of daily totals drowns that in the calendar (two daily routines move together
# by construction); an event read asks instead how often the thing was actually
# there when this one happened, against how often chance would put it there.
# Returns the apps that co-occur more than chance, each with how many of this
# app's occurrences had it nearby (hits), how many were scanned (of), the lift
# over chance, and the average offset in minutes (negative when it tends to come
# before this app, positive after).

# what was out of the ordinary on the days this app ran: every measure's
# average on those days against its average on the window's other days, scaled
# by how spread the measure is. A sparse app can still point at a reading this
# way, which a correlation needs too many days to do.

# Every AI provider the Platform panel can point a model at, and the models each
# offers. A model is chosen by id: a bare name goes to the local Ollama,
# @cf/... to Cloudflare, and everything else is "provider:model".

# Every setting name that holds a secret, so a panel can tell a key from a value.

# Whether a provider can answer here at all: the key (or account) it needs is
# entered, and for the local Ollama the daemon is actually running. "Valid"
# beyond that is only knowable by calling it - the bucket tracker already stands
# down an account that answered with no credit, and the Plat panel hides those
# paid models. The model lists only offer providers that pass this.

# A provider with an account on file: at least one of the settings it needs is
# filled in. Ollama's key is optional, so a bare local daemon has no account and
# does not count; passing $values avoids re-reading the settings per provider.

# The model choices, grouped by provider, for the dropdowns. Ollama and
# Cloudflare are read live; the rest are the fixed lists above.
#
# Which of chat / vision / image / audio a model can serve, so a role only offers
# models that fit it: a text chatbot is not offered a vision-only model, and the
# Vision role is not offered a plain text one. A name is the only signal for most
# providers, so this is a heuristic and errs toward 'chat'.



# Which provider a model id points at. A bare name (and a :cloud one) goes to
# Ollama; @cf/... to Cloudflare; the rest are "provider:model".

# The machine a @<device>/<model> names, or ''.

# The billing bucket a model draws on. Local Ollama and Cloudflare (its plan is
# included) are free; an Ollama :cloud model and every third-party provider cost.


# A provider that has answered "no credit" is stood down for a while, so the panel
# can hide its paid models and chat can step down to a free one.
our $AI_UNAVAILABLE_FOR = 30 * 60 * 1000;
# the model that actually answered the last ai_chat (a paid one may stand down)
our $ai_last_model;
# what model calls have cost, running (calls, in, out tokens): the error watch
# reads it around a proposal to log the spend and to stop at its day's budget
our $ai_tokens = { calls => 0, in => 0, out => 0, unmetered => 0 };

# A provider's own answer to "when may I call again". The stand-down above is
# for a bucket that has run dry; a rate limit is not that - it clears in
# seconds or at a stated clock time, and pausing the bucket for 30 minutes over
# a 20-second per-minute limit both loses the model and misstates the cause.
# Returns ($milliseconds, $why) when this response is a limit, () when it is
# not. Every duration is clamped to 5s..24h, so a malformed hint can neither
# lose a model for a week nor retry it in a hot loop.

# The cheapest thing that still answers: a local Ollama chat model, else a
# Cloudflare text model (its plan is included).

# Pass a capability (chat, vision, image, audio) to keep only models that serve it.

# Talk to whichever provider a model id points at, and return the whole answer.
# The message list may carry a system message; Anthropic and Google want it
# apart from the turns, so it is lifted out and put back per provider.
# The media one message carries, flattened to one shape. A caller may hand images
# (and, for providers that take them, audio/video/files) as base64 strings, data:
# URLs, or { data => .., mime => .. } / { url => .. }. The per-provider builders
# below read this, so the parse lives in exactly one place.

# OpenAI-compatible content: a plain string with no media, else the multimodal
# array (text + image_url parts, and input_audio where the model takes it).

# Anthropic content: text block + image (or document) blocks.

# Gemini parts: an ordered list of text and inline_data parts.

# The provider-specific wire message for one of our messages.

# The text out of any of the providers' reply shapes.


# The reply as parts, so a caller can take more than the words (an image a
# multimodal model returns, and the shape to grow into audio/video later). A paid
# model whose bucket is stood down steps down to a free one here, so every caller
# gets the fallback.


# the same wire pen_message uses, but the answer is read whole: the evaluation
# is a report, not a conversation
# The thinking levels the Plat panel stores: none means "let the model answer
# as it always has" (no field is added anywhere).

# Whether a model reasons before it answers - whether the thinking knob (see
# ai_chat_raw) means anything to it. No provider publishes this, so it is read
# from the model id: the reasoning families by name. A model not named here
# simply never offers the choice, and a level sent to a model that ignores the
# knob is still caught (a 400) and the call retried without it, so a miss costs
# nothing. Names are given without their provider: prefix.

# The thinking effort chosen in Configure -> Plat beside a role's model, '' when
# none is set. The Coding agent's own coding_thinking predates the per-role
# settings, so it is read as that one role's fallback.

# The primary and fallback models chosen for a role (the fallback list is the
# same catalogue minus the primary, set in Configure -> Plat). A caller retries
# the fallback when the primary is down. whisper.cpp is the transcription role's
# own final fallback, read in whisper_transcribe.

# One role's chat call. Before it is made, the Crew places it (crew::choose_model):
# a role naming a peer that no longer holds the model, a paid bucket that is
# stood down, or a local model this device never pulled is answered by what the
# house can actually reach, and a peer's own Ollama carries the call. The call
# still retries the role's fallback (then the primary) when the placed model
# errors - an outage is not a placement mistake. A role with nothing viable is
# reported rather than sent to a model that cannot answer.



# The same retry, for a caller that already holds its primary (the Guide's
# per-session model, the Coding agent's own fallback): primary first, then the
# role's fallback setting.




# Whether this machine can actually run the evaluation right now. The wish to
# evaluate is shared but the queue is per-machine, so a machine with no ollama,
# no model, or no key would otherwise run the night and answer with a connection
# error. A blank model is never available.

# Whether this machine can actually carry an evaluation now. The configured
# model is only half the answer: the Crew may place the call on a peer's Ollama
# (or step down to a free model), and a local :cloud model is useless without
# the daemon that serves it. The heartbeat publishes this, and a job consults it
# before it claims a run, so only a working agent is ever asked.
our $evaluation_agent_ready_memo;


# The app's own budget, held against the window the evaluation rolled up. The
# setting is a comma list of <amount>/<scope> entries - 17h/week, 7.0/w,
# $50/M - and each is scaled to the window before it meets its actual, so a
# month of readings of a weekly budget is still the same budget. Before this,
# the report could see how long an app ran but never whether running that
# long was over the line.


# the report a scope last produced: the setting is what the whole house can
# read, the cache is where it lived before it travelled

# the rolling headlines a scope has seen, newest first

# the report's text, split so that each app name inside it comes back as its
# own piece: the page renders those as links, and format_name drops the
# underscores on the way. The model may write an app the way it is spelled
# (chips_and_granola) or the way it reads (chips and granola), so both forms
# are offered to the match.

# the report as the page wants to show it: a headline first, then the rest -
# split into chunks - that waits behind it. A report told to begin with a
# headline has one on its first line; an older one that opens straight into a
# heading falls back to the first line of that section, shortened.

# The evaluation may name one relationship it is sure of. This checks the
# naming against what the briefing actually showed - the pair must be there,
# strong and not a daily habit - and then writes it the way the relational app
# itself does: the uuid goes into both apps' sc_ lists, filed under what the
# other app is (its pos, or its mab). A wrong link mislabels an app, so every
# check here is a gate, not a suggestion.

# File one relationship, by hand or by the house's own notice: the two apps are
# joined under each other's construct (sc_), which is what the relational window
# shows and what the evaluation reads back as a link. Idempotent, and it drops
# the two buckets from the relational cache so the window redraws them.

# Assemble the relationships the house is sure enough of, without a hand on each:
# the event scan's strongest neighbours of one app are filed straight away, so
# drawing them is the exception rather than the rule. The bar is high (a strong
# lift over chance, seen often) and an already-related pair is skipped, so a run
# only ever adds and never churns.

# The relational window reads the settings rows directly; a change to either end
# of a relationship is already in those rows when the next board is built.

# Undo a relationship, both ways, whoever made it. Symmetric with
# evaluation_relate so a link the house filed and one drawn by hand are taken
# apart the same way.

# Take the relationships back that no longer hold up, whoever drew them: for
# each app this one is related to, keep it only if the house can still see why -
# the event scan still puts it nearby, or a condition it runs under is still
# tied to the app - and drop the rest. Nothing is judged until the app has run
# enough to be read, and only a few go in a run, so a link is removed when it
# has truly gone quiet and not on a single thin night.

# the machine whose worker runs the nightly evaluations; blank means every
# machine that reconciles keeps its own queue

# The nightly evaluation is one Minion schedule per scope, named for the scope.
# The schedule is the mechanism, but it does not survive the launcher: jawn
# clears ~/.president at startup. So the wish lives in a setting too, and the
# worker restores the schedules from the settings at boot - see
# nightly_evaluation_reconcile. Minion reads cron expressions in UTC, and
# 0 7 * * * is the small hours of the house: 3am EDT, 2am EST.

# The schedule a scope now has, as Minion lists it. The configure page asks per
# app, so the answer is memoised for a few seconds: one query serves a page of
# apps instead of one per app. arrange() calls this right after a write, so the
# memo is short enough that a just-made change is seen on the next repaint.
our %schedule_memo;

# the days the nightly runs, as a comma list of cron weekdays (0 is Sunday);
# nothing picked means every night

# The cadence a scope runs on its own: off, hourly, daily, weekly, monthly,
# yearly, or each_run (evaluated whenever the appointment itself runs). The old
# nightly checkbox is read as daily, so a house that has not been reconfigured
# keeps its nights. The timed cadences become a cron the worker carries out;
# each_run has no schedule and rides the appointment writer instead.

# Minion reads cron in UTC, and 0 7 * * ... is the small hours of the house
# (3am EDT, 2am EST). The days select narrows daily and weekly; nothing picked
# means every night for daily and Sunday for weekly. Each scope gets its own
# minute from its name, so the whole house does not hand the model twenty runs
# at the same instant (which is what made a nightly batch time out).

# How often a scope wants a report, in milliseconds. Zero for the cadences with
# no interval to catch up (off, each_run).

# carry out one scope's cadence: schedule its cron, or clear it (off, each_run)

# the controls write both halves: the setting remembers the wish, the schedule
# carries it out, and the answer reports the schedule that now exists

# the old on/off checkbox, kept for anything that still speaks it

# Every run fires the evaluation when the scope's cadence is each_run. A Minion
# lock throttles a burst of runs to one evaluation per window (300s), so a
# morning of records does not queue a morning of model calls. Only a completed
# run counts - a one-shot ('usual') or the end of a start/stop pair ('stop') -
# and never a spawned child.

# The queue under ~/.president does not outlive the launcher, but the settings
# do. At boot this reads the wishes back, puts the schedules that are wanted
# back, and drops any nightly schedule the settings no longer ask for. Held in
# an eval because a boot that cannot reach the queue or the settings must not
# take the worker down with it.

# The worker half of the nightly checkbox: the same agent the evaluate button
# runs, so a fresh report is in the cache before the house wakes.

# Close a claim that could not be carried. A dispatched assignment is marked
# failed so the dispatcher stops addressing it and the next cadence reassigns;
# an elected run releases the row so a retry or a peer can take it.

# A durable note of what each night did, per scope: which machine ran it, when,
# with which model, and - when the run stepped aside - why. The queue is
# per-machine and the wish is shared, so without it the only witness to a night
# that did nothing was the absence of a report.

# Text to an image: the Plat Image-generation model, and the bytes it answered
# with. Cloudflare's @cf text-to-image models run at the run/{model} endpoint and
# answer with the picture itself; any other model goes through the chat layer,
# whose image parts are collected here. Returns ($bytes, $mime, $error).

# The audio/video twin of ai_text_to_image's generic path: the chosen generation
# model is asked for the media and the first part of the right kind it returns is
# the answer. Pen uses this so a described audio/video prompt is filed by the
# agent that takes care of that kind.

# Google Veo, the video-generation job: submit a prompt, poll the long-running
# operation until it is done, then fetch the file it names. Returns
# ($bytes, $mime, $error), the same shape as the other generators.













# A fingerprint of the code this machine is actually running. There is no
# .git on the remote machines (remote_rsync excludes it), so the source files
# themselves are hashed; when a .git is present the commit is reported too.
# Computed once per process and memoised - the app only re-reads its code on a
# restart, so the values cannot change under it.
our $code_revision_cache;
our $jawn_version_cache;

# The human version shown in the System view (and available to the peer
# handshake). Bumped per commit by scripts/version_bump.pl; stored in ./VERSION.

# A bump rewrites ./VERSION under a live process; whatever cached the old number
# (the Coding agent's commit subject reads it) must be told to forget it.


# A money move is a warehouse row. Every transaction with an account is written
# to the warehouse as it is recorded - the same fields under the same names, so
# the budget can read the ledger without knowing it moved - and the row is keyed
# by the source transaction's uuid, so a re-write or a backfill cannot double it.
# kind='money' marks it; type and movement keep what the transaction was.
# (Lives here, not in Manager.pl, so the boot process can run backfills.)

# --- Double-entry journal ---------------------------------------------------
# A chart of accounts seeded from the money accounts and the apps that carry
# income and expenses, and a journal that posts every money move once with the
# other side on the account that earned or spent it. The journal is derived: a
# rebuild is deterministic (every entry is keyed by its source row's uuid), and
# both tables stay off the sync list, so each machine builds its own from the
# data it already holds.
our %accounting_account_cache;





# Rebuild the whole journal from the ledger and the documents. Every entry is
# keyed by its source uuid, so the same data always yields the same journal.

# Is the journal still the ledger's own picture? A missing source, a source
# deleted, or a source edited after the last rebuild all mean rebuild.


# The trial balance as of a moment: each account's debit and credit balance.

# ---------------------------------------------------------------------------
# Data backfills. Schema migrations can be detected by inspecting the schema
# (subs::migration_already_applied); a data backfill cannot, so it is named
# here and recorded in the `backfills` table once it has run. A machine that
# receives this code runs any names it has not recorded - from the boot process
# (President) and from update_database (login / remote auth / merge) - so a
# code sync followed by the usual restart heals the data without a manual step.
#
# An entry returns true when it has run (recorded), false when its
# prerequisites are not ready yet (left for the next pass, e.g. the column the
# schema migration adds is not there), and dies on a real error (logged).
# ---------------------------------------------------------------------------

# The warranty a guide message expires on: the appointment's own when the thread
# is scoped to an app (its conversation name is app_<name>), otherwise the house
# default. It lives here - not in Manager - so the backfill below can stamp old
# turns from the boot process too, before the Manager worker is loaded.

our $backfills_running;

# ---------------------------------------------------------------------------
# Auto-update. A machine that receives code by git can keep itself current: the
# watcher fetches origin and fast-forwards when the tree is clean and strictly
# behind (never clobbers local commits or a dirty tree), then asks jawn to
# restart. When the tree is clean but diverged because origin's history was
# rewritten (every local commit still exists upstream under a new hash), it
# resets hard to origin/main so the machine rejoins the update track; a tree
# with genuinely local commits is left alone. Open browsers reload on their own:
# the websocket hands out the revision and the client reloads when it changes.
# ---------------------------------------------------------------------------
# Push the current code to a neighbour over ssh, using the credentials the
# remote_machines table already holds. Every device can also pull on its own
# (git_watcher_check), so this is the "force it now" lever: fast-forward the
# repo, reinstall the desktop app where one is installed, and ask jawn to
# restart. Returns { ok, message, output }.


# Fast-forward a checkout to origin/main. Returns (status, output):
#   current   already up to date
#   updated   fast-forwarded to origin/main
#   ahead     has commits origin/main does not; left alone
#   reset     diverged, but every local commit already exists upstream under a
#             rewritten hash, so reset hard to origin/main (nothing unique lost)
#   diverged  has local commits that are not upstream; left alone (use force)
#   dirty     tracked files are modified; never touched (use force)
#   error     the fetch failed (no route, bad credentials) or the checkout
#             could not be read; nothing was moved
#   no-repo   not a git checkout
# A clean tree only, unless force, which skips the dirty guard and hard-resets.
# Which of two dotted versions is newer - numerically, so 0.1.112 beats 0.1.79

# The tree the working files would commit as, without touching the worktree or
# the index. A code sync writes a peer's files over a checkout, so this is what
# a commit would carry - and what can be compared with the commits origin knows.

# Whether origin/main's history already carries this exact tree.

# A code sync writes a peer's tree over a checkout (the pack excludes .git), so
# every synced file reads as modified against a stale HEAD. Put the checkout back
# in a state git can move: if the synced tree is a shipped commit, reset to
# origin/main; otherwise preserve it as a local commit, so the work is not lost
# and the tree is clean for the next pull. No git, nothing to do.


# Pull the code from a peer: it hands back a git bundle of its own HEAD (a
# delta since ours when it can), we fetch it and fast-forward or reset by the
# same rules as a pull from origin. This is the watcher's fallback for a machine
# with no route to GitHub. ff_only also refuses the reset case: the fallback
# must never move a tree anywhere a fast-forward cannot reach, or a peer whose
# advertised version outran its actual tree can drag a machine backward (the
# rewritten-history reset once did, under "whoever has the newest is it").

# Best-effort, idempotent install of the optional applications the tree names
# (scripts/jawnos_deps.pl's extras: Piper today). Called after a code update so a
# new version's new apps land without a hand; a device that cannot install one
# simply keeps the fallback.

# New versions name new Perl modules, and the image's system Perl only has the
# ones it shipped with. A pull cannot install system packages as the person who
# runs the app, so the modules go in ~/perl5 - the local::lib `jawn` already
# puts on @INC, which lives on the state partition and therefore survives a
# reboot. Best effort: a failure is logged and the code update stands.

# ---- the error watch: the Coding agent's ears -------------------------
# The running tree prints its warnings and errors to the pty that the master
# (`./jawn`) reads, and jawn keeps that stream in a bounded, sequenced ring and
# serves it at ~/.president/log. This watcher asks the bus for what it has not
# seen yet (and reads ~/manager.log, for the $log lines that never reach the
# pty) and records each new error signature once in staged_fixes. When a Coding
# model is set, the agent reads the error and stages a proposed fix - whole
# files, not applied yet - for a person to review and apply from the IDE's
# coding chatbox. President runs the tick, so there is exactly one watcher per
# machine.

our %error_watch_state;    # source => bytes already read (for this watcher's life)
our %error_watch_partial;  # source => an unterminated tail line
our $error_watch_state_loaded = 0;


# The offsets live in a little file so a President restart (which happens on
# every code change) does not re-read the whole pty log and count every fault
# again; ~/.president is wiped when the master starts, so they never outlive the
# pty log they describe.


# The watch's purse: what today's proposals have cost, kept in the local cache
# (cache is never synced or backed up), so the day's budget can stop it before
# a runaway spend. The ceiling is the error_watch_budget setting (tokens/day;
# unset means a 1,000,000-a-day default, and 0 means no ceiling).



# ---- the house AI ledger -----------------------------------------------------
# One machine runs each AI job, and the day's purse is shared. A "job" is a unit
# of work with a name: an error's fix, an app's evaluation. Ownership is
# deterministic - a stable hash ranks the house and the job's home is the member
# ranked first - so every machine computes the same home with no lock service and
# no shared write to race. Only the home's own watcher proposes a given fix or
# runs a given evaluation.
#
# Eligibility rides the same synced tables: each machine publishes its own row
# (does it have an AI model, when it was last seen) and its own day's spend. The
# house is the members whose row says they have a model and were seen recently;
# a machine with nothing synced yet sees only itself, so it still works alone.


# The ledger's rows are keyed by a natural name (a job, a machine, a machine's
# day) but the sync matches rows by uuid. A fresh random uuid on every write
# meant a peer never recognised the update, and the table's unique key then
# refused the insert, so the ledger froze at each machine's first row. A uuid
# derived from the natural key is stable, so the sync updates the row it holds.



# Whether this machine can reach the model the evaluation is configured to use.
# The setting is shared but the reach is local: an ollama that is not running or a
# key that was never entered makes a machine a poor home for the night's run.
# Memoised for a minute so the heartbeat and a job do not probe twice.
our $ai_eval_ready_memo;

# Publish this machine's capability and heartbeat, throttled: a row every couple
# of minutes is enough to keep it counted, and the peers see it when next synced.

# Publish this machine's capability and heartbeat, and make sure the ledger tables
# exist (so it works from the first boot after an update, before anyone logs in
# and migrates). Called at the top of the watch tick, before the watch toggles
# are consulted: the ledger gates evaluations and the shared budget too, so a
# machine must announce itself whatever the watches are set to.
our $ai_ledger_ready;

# The machines that can take AI work: those that published a model and were seen
# in the last ten minutes, plus this machine (so a lone or not-yet-synced machine
# is never left with nobody). When $need_eval is set the machine must also reach
# the evaluation's model. Sorted, so every machine ranks the same house.

# The house's servers, by signatorial. A server is the machine most likely to be
# awake and reachable, so it is asked to carry the evaluation before the rest.

# Whether a named machine can take the work now. The local machine is asked
# directly (its heartbeat may be this very process's); a peer is judged by the
# row it synced, so a machine that has gone quiet is not believed.


# The machine that dispatches scheduled evaluations: a server, when the house
# has one. Several servers would choose the same one because the list is sorted.

# On a worker, "the server is known" means the server has published a heartbeat
# under this code and has been seen within the week. A server that is merely
# listed in remote_machines but has not upgraded yet is ignored, so a rolling
# update does not stop the first morning; a server gone for longer than the
# week is no longer a dispatcher, and the house falls back to quorum.

# The roster a serverless house uses for quorum: the AI-capable machines seen
# within a week, plus this machine. A machine gone for longer than that has left
# the house and no longer holds a vote.

# A strict majority of the roster must be present. A one-machine house is its
# own majority; a minority partition stands down instead of running the report a
# second time.

# The machine that runs $job now. The present house - the machines whose model
# heartbeat is fresh - is ranked by the job's own order, and if nobody has run
# the job within $ttl the highest-ranked member takes it. Because the house holds
# only machines seen recently, a home that goes quiet drops out and the job falls
# to the next machine (the failover); a job already run within the ttl is left
# alone by everyone, so a machine that runs it and then goes quiet does not cause
# a second run.
#
# A claim (state 'running' or 'claimed') is a lease rather than a fact: it covers
# the job for half an hour, and only while its owner is still among the living.
# A machine that claimed a run and then vanished therefore hands the work on
# instead of holding it forever.

# Write the claim before the work starts. A peer that reads the ledger sees a job
# already spoken for, so two machines never pay for the same evaluation; a claim
# left by a machine that goes quiet expires (see ai_job_runner), so the house can
# take the work back.

# The moment this manager booted, in ms. A claim older than this cannot belong
# to a live process: every worker was restarted after it was written.

# A retry of a job this machine already claimed: the previous attempt died
# before it could settle, and the queue runs one job at a time, so the claim
# cannot belong to a live attempt here. A peer still sees the claim as live,
# which is why the retry takes it back explicitly rather than through the
# election (that could elect the peer and deadlock on this very row).

# May this machine run $job? Only when it is the job's runner. The claim is
# written here, before the caller spends anything, so the rest of the house sees
# the intent at once; ai_job_note marks it finished afterwards.


# ---- evaluation dispatch ----------------------------------------------------
# The server is the dispatcher; a mobile or computer is a worker. The dispatcher
# assigns each scheduled run to one ready worker a few minutes before it is due,
# and a worker only runs what is addressed to it. A partition that cannot see
# the server receives no fresh assignment and stands down, which is what keeps a
# split house from running the same report twice. A house with no server at all
# elects by quorum instead.

# Minion lists schedules with next_run as epoch seconds; a stored string form
# is accepted too when a caller reads the row directly.

# A worker claims the server's assignment. Only the addressed machine may take
# it, only while it is fresh, and only once: 'running' is the claim, 'ran' the
# receipt. A stale claim can be taken over, so a worker that dies mid-run does
# not hold the job forever.

# The dispatcher's half: look at the schedules due in the next ten minutes and
# write one assignment per run. An assignment still in flight is left alone, so
# a run is never handed to a second machine while the first holds it.

# Every machine's minute: the server writes the assignments, and every machine
# turns an assignment addressed to it into a queued job. Using the tick rather
# than the cron means an assignment that reaches a worker a few seconds late is
# still picked up on the next minute instead of waiting for the next cadence.

# the shared purse: what the whole house has spent today


# The house at a glance for Configure → Sys: every machine that has published
# itself (does it hold a model, when it was last seen) with its spend today, and
# the day's house total against the shared ceiling. Read-only, straight from the
# synced ledger tables, so every machine shows the same picture.

# The money left on each provider account, where the provider will say. There is
# no common balance API: OpenRouter publishes its credits and DeepSeek its account
# balance, and the rest (OpenAI, Anthropic, Google, xAI, Mistral, Groq,
# Cloudflare) have none, so they read "—". Only providers with an account on file
# are listed at all. The read itself is done off the page
# by President.pl's ai balance loop; this only ever reads the cached result, so a
# page load never waits on a provider.


# One point of the balance history, at a known time. Pure so a test can pin
# both the series and the clock. The drawn points carry a synthetic point at
# the window's left edge, interpolated from the last sample before it, so a
# 24h line starts where the window does instead of at its first sample.
# `change` is positive when the balance fell; `per_day` is the pace in money.

# A line for one provider over one window. currentColor means it follows the
# theme, and a flat balance gets a little headroom so it does not sit on the
# floor. Only the caller's numbers reach the markup.

# The Sys panel's chart, assembled from the cached read. No provider call and no
# database write happen here: the route has already loaded the same report. The
# balances and the pace are shown in the house's reporting currency, converted
# at the rate snapshot the rest of the app uses; a provider whose rate is not
# loaded keeps its own currency rather than a wrong number.

# A span in the units that read best: minutes under an hour, hours under two
# days, then days. The chart's first hours are a short line, and "3 h" says
# more than "0 d".

# Money in a label: two decimals are right for a balance, but a slow spend is
# often cents a day and would read as 0.00, so small values keep four.

# Kept for the balance chart's existing callers. New displays use currency_money.

# The fiat currencies a picker may offer, and what one unit of the house
# currency is worth in each. The order is deliberate: the house currency first,
# the amount's own currency second, then the rest of the fiat table in its own
# order. A code the rate snapshot does not carry is left out - offering it would
# be a promise the conversion cannot keep. `rate` is target units per one base.

# An amount in its own currency as the house currency. Returns undef when no
# rate is loaded, so a caller can show the original figure instead of a guess.

# Auto-approve, kept on a leash: at most 8 auto-applies a day (each one is a
# commit and a push; a bad day must not become a hundred). Past that the
# proposals simply wait for a person, as they always did.


# An auto-applied fix writes whole files; if any of them has uncommitted work in
# the tree, writing would swallow it, so auto-approve stands down and leaves the
# proposal for a person (the log says why).

# Apply one staged fix: write its files, check the Perl, then the finishing
# routine - bump, commit only what was written (plus VERSION), push. A failure
# at the check puts every file back and nothing is committed. Both the panel's
# Apply and the watch's auto-approve come through here.

# Lines that are normal noise rather than errors. jawn() already suppresses the
# same ones from its own console, and the master prints the shutdown line on
# every restart.
our $error_watch_noise = qr/Permission denied|cannot open \/proc\/net|Cannot bind netlink|error watch:|President stopping on SIGINT; cleaning up|Broken pipe|UDTA parsing failed|source=model_show_cache|model recommendations refresh failed|Socket sender:|\{"event": "error", "message": "not connected"\}/;


# One invariant name per distinct error: control codes, addresses and numbers
# (line numbers, pids, ports, counts) are blanked, so a flood of one fault
# collapses to a single staged row.


# A Perl warning is two lines - the message, then " at ./file line N." - so a
# matched line swallows the source location that follows it before it is caught.

# Record one caught fault: a new row when its signature is new, a tally bump on
# the row already carrying it. Shared by the log watch and the browser's fatal
# JavaScript reporter (the signature may come from a shorter text than the
# sample - a JS fault's stack must not make every occurrence a new signature).

# ---- the records watch ------------------------------------------------------
# The database's half of the self-heal, and the mirror of the error watch: a
# fixed, deterministic audit of the appointments table for the fault classes
# that corrupt the person's numbers. A stop press closes ONE session, but two
# bugs left rows ended by a press that was not their own (one stop applied to
# several open sessions) or wrote the same event once per machine. The judgement
# - which row to keep, what to repair - is the Coding agent's, staged and
# approved the way a code fix is (staged_records). Nothing here writes.

# An app the person has said is genuinely, surprisingly long-lived (a home stay, an
# eight-month ailment). Length alone can never tell a real session from a swept one,
# so the audit must be able to be told to leave an app alone entirely. Stored per
# machine as a JSON list of app names (mail/records_exempt).


# A millisecond date that a bridge reader mistook for a span of minutes was
# subtracted from the writing moment, so the row landed millions of years in the
# past. The arithmetic inverts exactly: the original stamp is
# (ost - timestamp) / 60000. Only the unmistakable magnitude is touched, and
# only when the recovered value is a real date, so no other odd row is rewritten.

# The bad-date rows and what to do with each. Most are not new records: the
# check re-read the same last ten messages and thirty calls on every pass, and a
# mangled stamp never matched the row it had already written, so it wrote the
# event again. Keep one row per event - the sane record when one exists, else the
# first bad row - and tombstone the re-writes instead of repairing a duplicate
# into view.

# The same bridge bug wrote the mailbox row beside the appointment: sms_list_check
# inserted both with the mangled stamp. Mailbox has no stop_timestamp, so only
# timestamp is inverted. A sealed body is encrypted with a random container, so
# two writes of one message never share the same bytes; an unreadable body is
# therefore matched on the event (phone, sender, status, the same second), while
# a readable body must agree.


# What to do with each mangled mailbox row: one row per event, preferring the
# sane copy already stored, then the first mangled row of a batch. Pure, so the
# scan can be tested and the caller owns the writes.




# Run only the bad-date pass. A peer that holds the accurate copy can ask this
# machine to clear its own mangled dates over the signed records/repair rail;
# the pass touches only the unmistakable signature and is idempotent. The same
# bridge bug wrote the mailbox row beside the appointment, so both are cleared.



# ---- the records watch: staging and apply --------------------------------
# The mirror of the error watch. A finding the fixed audit produces is staged as
# a row; a person reviews it and Applies, and the actions it carries are written
# through the same quiet paths the bulk pass uses. Machine-local (staged_records),
# so each machine repairs its own rows and the tombstones converge the mesh.

# drop one appointment row and tell the mesh (a tombstone, so no peer re-adds it).
# Quiet on purpose: Manager::delete_app also pushes to every open window, which a
# batch of hundreds must not do.

# set a session's real end (its own start + the app's length). A fresh server_time
# is what makes the repair win the peer merge.

# Restore a mangled millisecond stamp in place, leaving the row's other fields
# alone. The row is a finished event (an SMS or a call), not an open session.

# the table, created here too so the watch works from the first boot after an update

# stage one finding: an existing signature just bumps last_seen; a new one is inserted

# turn an audit report into staged findings

# Apply one staged row: carry out every action it holds, then mark it applied

# Put one staged finding to the Coding agent. The audit finds; the agent reads;
# the person decides. A real appointment can be surprisingly long (a home stay, an
# eight-month ailment) and a fixed rule can never know that, so the person can talk
# a finding through before pressing Apply - and the agent is free to answer "leave
# it alone". Nothing here writes.

# ---- the records recovery: putting back what a repair shortened --------------
# A repair overwrites an end in place, so a genuinely long appointment that a
# sweep swept up can vanish from the live table with nothing left to compare to.
# The machine keeps hourly sealed snapshots, and the one taken before the repair
# still holds the old ends. These routines compare a snapshot to now and list the
# rows the repair shortened (or dropped), so a person - or the Coding agent - can
# put them back. Nothing is written by the scan; apply stamps a current
# server_time, so the recovered rows win the peer merge and reach every machine.

# the newest sealed snapshot, by the timestamp in its name

# take one now, with the app's own idiom (sqlite .backup, then openssl, then the
# splitter-and-standard appendage). Kept outside backups/ only as the plaintext,
# which is shredded; the sealed file is named jawnos_<ms>.enc so the tidy keeps it.

# the newest snapshot is younger than the window, or one is taken to make it so.
# The guard the person asked for: nothing is applied without a recent backup.

# unseal a snapshot to a scratch database outside backups/ (the tidy shreds
# anything there that is not jawnos*.enc). Returns the path, or undef.

# how long a row ran: its own stop when it has one, else as far as the reference
# time (the snapshot's moment for an old row, now for a live one)

# Compare a snapshot to the live table and list the rows the live table made
# shorter (or dropped). A row is a candidate when its app is one the person named
# or when it ran longer than older_than_ms in the snapshot - the two signals a
# fixed rule cannot supply on its own.

# Write the scan's candidates back: the old row's ended-ness onto the live row, or
# the whole old row when it was dropped. server_time is now, so every machine takes
# the recovered version on its next sync. The recovered apps are then left alone by
# the audit (they are, by definition, the ones that legitimately run long), so a
# sweep does not sweep them up a second time.

# One pass of the watch: stage what the audit finds, and - when Apply automatically
# is ticked - write the oldest exact-duplicate finding. A sweep or an orphan waits
# for a person (a genuinely long appointment must never be repaired on its own).
# Off until Configure -> Plat ticks Records.

# One pass: catch what is new, record it, and hand the oldest waiting error to
# the Coding agent to propose a fix for. Called from President's schedule.

# ---- the guide watch: the Coding agent's other ear --------------------------
# The Guide's conversations are saved as they go (guide_conversation_<name>,
# the rows the Agents list reads back), tool observations and all. This reads
# the ones that changed since last time and stages a turn that went nowhere -
# a thing not found, a command that could not run, a closing line that says so
# ("[object Object]" among them) - like an error, so the same propose/Apply
# loop adjusts the Guide's training: its rules in help.pl, its verbs in gb.pl.
# A signature dedupes repeats, and a small offset file keeps each conversation
# from being read twice. The first pass only takes a baseline, so switching the
# watch on does not stage the whole history at once.


# The words that read like the turn went nowhere. The Guide's phrasebook is
# small and its observations are its own client's strings, so this is the same
# text the person sees. "is hidden here" is left out on purpose: refusing a
# hidden thing is the rule working, not a miss.


# The propose loop runs in President, which never loads Manager.pl, so it carries
# its own copy of the repo-path guard (the same rules as subs::coding_path).
# Nothing here can change the repo: every write is staged, so the guard only has
# to keep the agent's reading inside the tree.



# Check a staged file's text before it is even proposed, against a temp copy of
# the same basename (the tree is not written to here). The same verifier the
# Apply path runs, so the agent learns at once instead of staging a file that
# breaks the tree. Returns '' when it passes, else the reason.

# The propose mode's tool loop: the same verbs' shape, but write only stages the
# whole file, so the agent can change nothing here.

our $coding_protocols_cache;
our $coding_protocols_mtime;

# The tracked protocol text the manager-side agent also follows (baked from the
# gitignored AGENTS.md into docs/coding_agent_protocols.md), so the watcher's
# proposals obey the same rules. Cached by mtime.

# One bounded propose run for a staged error: the model picks the next action,
# write stages the file, repeat until done or the step cap. The proposal lands
# on the row as whole files, never as a change to the tree.

# Where this machine takes code updates from. A house setting
# (`sync/update_method`, device => 'all'), so the Dev panel writes it once and
# every machine's next settings pull carries it. Blank or unknown means any:
# origin first, a peer as the fallback, which is what the watcher always did.

# The newest peer that can fast-forward this checkout. The watcher's fallback
# and the manual button share it: sort by the version the peer advertises, keep
# the few that are newer, and stop at the first true fast-forward. A peer whose
# history merely shares a commit with ours is not enough - ff_only refuses the
# reset, which is what keeps a rewritten peer history from dragging a machine
# backward. Returns (status, output, peer row).

# A tree seeded from the image has no .git, so git_repo_update can only answer
# no-repo. The boot unit owns turning it into a checkout; the Update now button
# delegates to that same program, so a fresh image can update without a
# re-image and both paths agree. The program's final JAWNOS_UPDATE_STATUS line
# speaks the vocabulary update_now already uses.

# An explicit update, from the Dev panel's button. Unlike the watcher this may
# run whichever source the method names, and for None (or Any) it tries GitHub
# first and then a peer: pressing the button is the person's own instruction,
# so the automatic-update switch does not veto it. Never force unless the caller
# says so - force is what discards tracked local changes.

our $git_watcher_blocked_note;


# A Mojo::UserAgent that speaks to a peer the way remote_useragent_maker builds
# one - the tunnel-aware manager url plus the session cookie we already hold for
# it. Kept in subroutines so the boot-time loops, which run before Manager.pl is
# loaded, can reach a peer without pulling the whole app in.

# Append one line to the app-release sync's own log (the manager log). Quiet
# when there is no logfile yet (an early boot).

# Fetch a URL into a string. curl first, forced to IPv4: on a network whose IPv6
# path to GitHub's asset CDN stalls, Mojo::UserAgent (which does not pin the
# address family) hangs where curl -4 completes. Falls back to Mojo when curl is
# absent, then to curl without -4 for a host that has no A record.

# The public app-release manifest on GitHub - a source that needs no peer to
# answer, or to hold a valid cookie for us. The release carries app_release.json
# (product, versionCode, versionName, filename, sha256) beside the APK, under a
# fixed tag so the URL never moves; the download is a plain github.com asset,
# not the rate-limited API. Returns the manifest plus the asset base url, or
# undef when there is no release (or no network).

# Reconcile the staged app releases (the APKs under releases/) with the newest a
# reachable peer holds: a device that is behind pulls the APK in, so every
# device becomes a holder and a source. The APK is a blob (gitignored) carried
# over http, not through git - a ~35 MB binary per version in git history would
# be untenable. Pull, on the watcher's slow tick; the code watcher keeps the
# Perl tree current. GitHub's release manifest is consulted too, so a device
# with no reachable peer (or no valid peer cookie) still updates.
# Cache each reachable peer's Ollama model list, so Plat can offer models by the
# machine they run on without waiting on the network. Runs on a slow tick; a
# peer that goes quiet keeps its last list until it answers again.


# Reconcile the voice models (voices/*.onnx and their json) with a reachable peer.
# Models are arch-independent, so they travel the same way the APKs do - a device
# that lacks one pulls it in and can then serve it, so every device ends up with
# the same voices. The piper binary is per-arch and stays local, so it is never
# part of this list. The models are immutable, so presence is enough: no version
# to compare, unlike an APK.

# ---- crypto wallets and live exchange rates --------------------------------
# A wallet is an ordinary account app whose tender is crypto. JawnOS keeps the
# public address and the asset, never a key or a seed phrase: it can say what a
# wallet holds and what that is worth, but it cannot spend from it, and nothing
# here ever asks for a phrase that could.
#
# Rates are one cached snapshot, denominated in the house's reporting currency:
# rates{CODE} is how much of that currency one unit of CODE is worth. One
# Coinbase call returns every fiat code and every coin; open.er-api is the
# fiat-only fallback for a first boot. formula_calculator reads the same
# snapshot, so 'x USD to CAD' is live too instead of the hand-written constants
# in gb.pl.

our @crypto_asset_list = (
	{ code => 'BTC',  name => 'Bitcoin',   decimals => 8,  symbol => '₿', network => 'bitcoin',  coinbase => 'BTC'  },
	{ code => 'ETH',  name => 'Ethereum',  decimals => 18, symbol => 'Ξ', network => 'ethereum', coinbase => 'ETH'  },
	{ code => 'USDC', name => 'USD Coin',  decimals => 6,  symbol => '$', network => 'ethereum', coinbase => 'USDC' },
	{ code => 'USDT', name => 'Tether',    decimals => 6,  symbol => '$', network => 'tron',     coinbase => 'USDT' },
	{ code => 'LTC',  name => 'Litecoin',  decimals => 8,  symbol => 'Ł', network => 'litecoin', coinbase => 'LTC'  },
	{ code => 'SOL',  name => 'Solana',    decimals => 9,  symbol => '◎', network => 'solana',   coinbase => 'SOL'  },
	{ code => 'DOGE', name => 'Dogecoin',  decimals => 8,  symbol => 'Ð', network => 'dogecoin', coinbase => 'DOGE' },
	{ code => 'XRP',  name => 'XRP',       decimals => 6,  symbol => 'X', network => 'xrpl',     coinbase => 'XRP'  },
	{ code => 'ADA',  name => 'Cardano',   decimals => 6,  symbol => '₳', network => 'cardano',  coinbase => 'ADA'  },
	{ code => 'BNB',  name => 'BNB',       decimals => 18, symbol => 'BNB', network => 'bnb',    coinbase => 'BNB'  },
	{ code => 'TRX',  name => 'TRON',      decimals => 6,  symbol => 'TRX', network => 'tron',    coinbase => 'TRX'  },
	{ code => 'AVAX', name => 'Avalanche', decimals => 18, symbol => 'AVAX', network => 'avalanche', coinbase => 'AVAX' },
	{ code => 'LINK', name => 'Chainlink', decimals => 18, symbol => 'LINK', network => 'ethereum', coinbase => 'LINK' },
	{ code => 'DOT',  name => 'Polkadot',  decimals => 10, symbol => 'DOT', network => 'polkadot', coinbase => 'DOT'  },
	{ code => 'BCH',  name => 'Bitcoin Cash', decimals => 8, symbol => 'BCH', network => 'bitcoin-cash', coinbase => 'BCH' },
	{ code => 'XLM',  name => 'Stellar',   decimals => 7,  symbol => 'XLM', network => 'stellar',  coinbase => 'XLM'  },
	{ code => 'ATOM', name => 'Cosmos',    decimals => 6,  symbol => 'ATOM', network => 'cosmos',  coinbase => 'ATOM' },
	{ code => 'TON',  name => 'Toncoin',   decimals => 9,  symbol => 'TON', network => 'ton',     coinbase => 'TON'  },
);

# The most-used currencies, in the order a trader would rank them. Coinbase
# returns three-letter coin tickers (ADA, DOT, XRP) beside the fiat, so this
# table is the line: only these codes are kept from a snapshot. Each entry's
# measure is the key the Measures app already stores history under - the first
# five match the canadian_dollar app, so its existing charts carry on.
our @crypto_fiat_table = (
	{ code => 'USD', name => 'American Dollar',    measure => 'american_dollar' },
	{ code => 'EUR', name => 'Euro',                measure => 'euro' },
	{ code => 'JPY', name => 'Japanese Yen',        measure => 'japanese_yen' },
	{ code => 'GBP', name => 'British Pound',       measure => 'gbp' },
	{ code => 'CNY', name => 'Chinese Yuan',        measure => 'chinese_yuan' },
	{ code => 'AUD', name => 'Australian Dollar',   measure => 'australian_dollar' },
	{ code => 'CAD', name => 'Canadian Dollar',     measure => 'canadian_dollar' },
	{ code => 'CHF', name => 'Swiss Franc',         measure => 'swiss_franc' },
	{ code => 'HKD', name => 'Hong Kong Dollar',    measure => 'hong_kong_dollar' },
	{ code => 'SGD', name => 'Singapore Dollar',    measure => 'singapore_dollar' },
	{ code => 'NZD', name => 'New Zealand Dollar',  measure => 'new_zealand_dollar' },
	{ code => 'SEK', name => 'Swedish Krona',       measure => 'swedish_krona' },
	{ code => 'NOK', name => 'Norwegian Krone',     measure => 'norwegian_krone' },
	{ code => 'DKK', name => 'Danish Krone',        measure => 'danish_krone' },
	{ code => 'KRW', name => 'South Korean Won',    measure => 'south_korean_won' },
	{ code => 'INR', name => 'Indian Rupee',        measure => 'indian_rupee' },
	{ code => 'BRL', name => 'Brazilian Real',      measure => 'brazilian_real' },
	{ code => 'MXN', name => 'Mexican Peso',        measure => 'mexican_peso' },
	{ code => 'ZAR', name => 'South African Rand',  measure => 'south_african_rand' },
	{ code => 'TRY', name => 'Turkish Lira',        measure => 'turkish_lira' },
	{ code => 'RUB', name => 'Russian Ruble',       measure => 'russian_ruble' },
	{ code => 'PLN', name => 'Polish Zloty',        measure => 'polish_zloty' },
	{ code => 'CZK', name => 'Czech Koruna',        measure => 'czech_koruna' },
	{ code => 'HUF', name => 'Hungarian Forint',    measure => 'hungarian_forint' },
	{ code => 'ILS', name => 'Israeli Shekel',      measure => 'israeli_shekel' },
	{ code => 'AED', name => 'UAE Dirham',          measure => 'uae_dirham' },
	{ code => 'SAR', name => 'Saudi Riyal',         measure => 'saudi_riyal' },
	{ code => 'THB', name => 'Thai Baht',           measure => 'thai_baht' },
	{ code => 'IDR', name => 'Indonesian Rupiah',   measure => 'indonesian_rupiah' },
	{ code => 'MYR', name => 'Malaysian Ringgit',   measure => 'malaysian_ringgit' },
	{ code => 'PHP', name => 'Philippine Peso',     measure => 'philippine_peso' },
	{ code => 'VND', name => 'Vietnamese Dong',     measure => 'vietnamese_dong' },
	{ code => 'TWD', name => 'Taiwan Dollar',       measure => 'taiwan_dollar' },
	{ code => 'CLP', name => 'Chilean Peso',        measure => 'chilean_peso' },
	{ code => 'COP', name => 'Colombian Peso',      measure => 'colombian_peso' },
	{ code => 'PEN', name => 'Peruvian Sol',        measure => 'peruvian_sol' },
	{ code => 'ARS', name => 'Argentine Peso',      measure => 'argentine_peso' },
	{ code => 'RON', name => 'Romanian Leu',        measure => 'romanian_leu' },
	{ code => 'BGN', name => 'Bulgarian Lev',       measure => 'bulgarian_lev' },
	{ code => 'ISK', name => 'Icelandic Krona',     measure => 'icelandic_krona' },
	{ code => 'UAH', name => 'Ukrainian Hryvnia',   measure => 'ukrainian_hryvnia' },
	{ code => 'KZT', name => 'Kazakhstani Tenge',   measure => 'kazakhstani_tenge' },
	{ code => 'NGN', name => 'Nigerian Naira',      measure => 'nigerian_naira' },
	{ code => 'KES', name => 'Kenyan Shilling',     measure => 'kenyan_shilling' },
	{ code => 'GHS', name => 'Ghanaian Cedi',       measure => 'ghanaian_cedi' },
	{ code => 'EGP', name => 'Egyptian Pound',      measure => 'egyptian_pound' },
	{ code => 'MAD', name => 'Moroccan Dirham',     measure => 'moroccan_dirham' },
	{ code => 'PKR', name => 'Pakistani Rupee',     measure => 'pakistani_rupee' },
	{ code => 'BDT', name => 'Bangladeshi Taka',    measure => 'bangladeshi_taka' },
	{ code => 'LKR', name => 'Sri Lankan Rupee',    measure => 'sri_lankan_rupee' },
	{ code => 'NPR', name => 'Nepalese Rupee',      measure => 'nepalese_rupee' },
	{ code => 'QAR', name => 'Qatari Riyal',        measure => 'qatari_riyal' },
	{ code => 'KWD', name => 'Kuwaiti Dinar',       measure => 'kuwaiti_dinar' },
	{ code => 'JOD', name => 'Jordanian Dinar',     measure => 'jordanian_dinar' },
	{ code => 'BHD', name => 'Bahraini Dinar',      measure => 'bahraini_dinar' },
	{ code => 'OMR', name => 'Omani Rial',          measure => 'omani_rial' },
	{ code => 'TND', name => 'Tunisian Dinar',      measure => 'tunisian_dinar' },
	{ code => 'UYU', name => 'Uruguayan Peso',      measure => 'uruguayan_peso' },
	{ code => 'DOP', name => 'Dominican Peso',      measure => 'dominican_peso' },
	{ code => 'GTQ', name => 'Guatemalan Quetzal',  measure => 'guatemalan_quetzal' },
);






# The house's reporting currency: the one the ledger, budgets and statements
# already speak. misc/currency can arrive as a JSON list, so read the first
# three-letter code from it.

# The coin an account holds, or '' when it is not a wallet. The asset setting is
# what names it; an older wallet with only the tender set is Bitcoin, so a row
# never becomes unreadable.


# A typed amount becomes a plain decimal string, never a float: 18-decimal coins
# would lose their last places on the way through a Perl number. Commas are
# thousands separators (the same rule numeric_formatter uses) and only the last
# dot is a decimal point.

# Display form: the coin's own decimals, trimmed, with at least two places so a
# small amount still reads as money rather than a bare integer.

# A seed phrase pasted into an address field is refused before it is stored.


# ---- watch-only Bitcoin addresses (BIP32 public derivation) -------------------
# An account xpub is public: it derives receive addresses and cannot spend. A
# wallet that carries one gives every invoice its own address. OpenSSL does the
# scalar multiple (import the scalar as a private key, export its public point)
# and the hash/encoding work; the one step it does not expose - adding the
# parent point to IL*G - is a handful of BigInt operations below.
#
# Everything here is public data. There is deliberately no function that takes a
# private key, a seed phrase or an xprv.
require Math::BigInt;

our $crypto_secp256k1_p = Math::BigInt->new('0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F');
our $crypto_secp256k1_n = Math::BigInt->new('0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141');
our $crypto_base58_alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
our $crypto_bech32_charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
our %crypto_base58_index;
@crypto_base58_index{ split //, $crypto_base58_alphabet } = ( 0 .. 57 ) unless %crypto_base58_index;

# The public version bytes a wallet exports for an account. A testnet key is
# accepted only when the wallet itself is not on bitcoin mainnet.
our %crypto_xpub_version = (
	0x0488B21E => { script => 'p2pkh',       net => 'main' },
	0x049D7CB2 => { script => 'p2sh-p2wpkh', net => 'main' },
	0x04B24746 => { script => 'p2wpkh',      net => 'main' },
	0x043587CF => { script => 'p2pkh',       net => 'test' },
	0x044A5262 => { script => 'p2sh-p2wpkh', net => 'test' },
	0x045F1CF6 => { script => 'p2wpkh',      net => 'test' },
);

# A private extended key or a WIF is a spending key, never a watch-only one.




# IL*G. The scalar is imported as a secp256k1 private key and its public point
# exported, so the curve work stays in CryptX.











# Decode an account xpub (or ypub/zpub and their testnet forms). Returns the
# public key and chain code plus the script type the version bytes name.


# One non-hardened public child. Returns undef when BIP32 says the child is
# invalid (IL = 0 or IL >= n), so the caller can try the next index.

# The address at /0/index under an account xpub, encoded for the script type
# the key names. This is the external (receive) chain only; change addresses
# live at /1/index and are never issued here.

# A BIP21 payment request: the address and, when known, the exact amount. No
# label or message, so no ampersand ever reaches the QR encoder's argument.



# reporting currency per one unit of $code


# A fiat pair, read from the same snapshot. The static formulas in gb.pl are the
# fallback only while no snapshot exists yet.



# One snapshot for every asset and every fiat code. The request is public and
# keyless; an offline house keeps its last snapshot rather than losing the rates.

# What each wallet holds and what it is worth. Native units follow the signed
# amount stored on the transaction (income positive, expense negative, a
# transfer leg signed by its own direction); the money column is the signed
# total, exactly the figure the ledger's account balance uses.

# ---- one address per invoice -------------------------------------------------
# The wallet's account xpub makes a fresh receiving address from the external
# chain. The row lives in crypto_address (synced like any other table) so an
# invoice keeps its address across edits, peers and reprints. A wallet with no
# xpub falls back to the single address saved on the account, exactly as before.


# A wallet field that must be the same on every machine (the xpub, and the
# address it falls back to). A shared row wins even when it is empty, so
# clearing the field on one machine is not undone by a stale device row.

# Read the address an invoice already owns. Never writes: the public invoice
# page and the print view call this, and a GET must not allocate.

# Reserve this invoice's address. Idempotent: a second call returns the same
# row. insert or ignore keeps two machines that allocated the same index while
# apart from failing the insert; the loser simply takes the next index.

# ---- currency tracking ------------------------------------------------------
# The old way to keep a currency history was an app with an appointment that
# wrote a measure every few hours. The checkbox in Configure -> Plat -> Crypto
# does the same job from the rate snapshot: one appointment of type measure in
# the house's currency app every six hours, carrying every tracked fiat code, so
# the Measures app charts it and no appointment has to run.


# The app the history goes to. An explicit choice wins; otherwise adopt the app
# the house already uses for currency measures, so its existing charts carry on.



# The app's measures can live on more than one device; update every row that is
# there rather than the one this worker happens to be running as.

# The Measures app's PV column reads the same snapshot the Crypto panel shows:
# one unit of a code, valued in the house's reporting currency. The fiat rows
# Measures already holds are updated in place; every enabled coin gets a row of
# its own, so a market price has somewhere to sit. Called after a refresh and
# whenever Measures opens, so a snapshot taken while the panel was closed still
# fills the column without waiting for the next half-hour.


# The Store's two directions, named for what the house is doing: an income
# movement is a sale and an expense movement is a purchase. The stored movement
# values do not change - only the words on the Store's own dropdown.

# ---- payment proofs ---------------------------------------------------------
# A payer's crest signs a statement of what was sent for which document; the
# payee signs the same bytes back. The code travels like a crest code (PAY1Z:
# deflated JSON), so it can be pasted or scanned. This is an attestation by the
# two houses, not a chain check: the txid is carried, not verified here.








# A native amount and a claimed amount are equal when they are within 1% - a
# rate moves between quoting and sending, but not by more than that in practice.

# ---- online payments (Configure -> Plat -> Pay) ----------------------------
#
# Four ways for a customer to settle an invoice from the public invoice page:
# Stripe, Square and PayPal create a hosted checkout for the exact balance and
# record the payment when the provider says it is paid; Interac e-Transfer has
# no consumer API, so JawnOS reads the notification letters already arriving in
# the mailbox (or accepts a signed forwarder) and stages them for the seller.
# Keys are sealed like an AI key and never leave the server.


# Read a pay setting. The house shares these the way it shares the language, so
# a phone and the desk agree on which provider is on.

# A secret is stored sealed; a value written by an older build (or a plain row
# replayed by a peer) still opens, so a key is never lost to a format change.




# A provider is offered only when the house turned it on AND it has what it
# needs to work. The public page reads this same answer, so a half-filled panel
# never shows a button that cannot complete.

# The accounts a payment may be booked into. An account is an app whose part of
# speech is account, the same list the App tab and a transaction use.

# Where a provider's money lands. The panel's own choice wins; without one, the
# first account that names the tender is a sensible fallback so a house that
# never opened this panel still records the money somewhere.

# The address a provider redirects back to, and the address a webhook is sent
# to. The public side of the house lives on port 3000; a house with a public
# name can override the whole thing with pay.base_url.



# The invoice's own reference, printed on the paper and used to match an
# e-transfer's message. It is the human id, not the uuid.


# Find the invoice a public payment link names. The customer uuid scopes it, so
# one invoice uuid cannot be paid through another customer's page.

# A hosted checkout is remembered for an hour so a refresh reopens the same one
# instead of creating a second charge. The key carries the amount, so a partial
# payment creates its own session.



# The one place a payment is written to an invoice. It is safe to call twice:
# a provider reference already on the invoice is reported, not counted again.

# What the public invoice page offers. Only providers that can actually finish
# are listed; Interac has no redirect, so it carries the address and reference
# the customer needs instead of a button.

# Minor units: most currencies have cents, but a few do not. Checkout APIs
# want an integer, and paying 100x too much is worse than a wrong-looking row.


# ---- Stripe ---------------------------------------------------------------




# ---- Square ---------------------------------------------------------------





# ---- PayPal ---------------------------------------------------------------








# ---- starting and finishing a checkout ------------------------------------
# One entry point both the public page and a return use, so the invoice lookup
# and the readiness check cannot drift apart.

# The provider sends the customer back here. Nothing the browser says is
# trusted: the provider's own record is read and that is what is recorded.

# A small, honest check from the panel: the key works and the provider answers.

# ---- Interac e-Transfer -----------------------------------------------------
# There is no consumer API for an e-Transfer. The notification letter is the
# source of truth, so JawnOS reads the ones already arriving in the mailbox, or
# accepts the same facts from a bank/aggregator that can forward them. A letter
# is staged for a person unless the house has said auto-record, and even then
# only when one invoice is an unmistakable match.



# Pull out the few facts an e-Transfer letter carries. Anything it does not
# recognise stays empty rather than guessed, so a person can still match it.

# Open invoices that could be the one this e-transfer is for. The score is
# deliberately simple: an invoice reference in the message is strongest, the
# exact balance next, then the sender's own address and name.

# Stage one notification. Auto-record happens only when the house asked for it,
# the money is actually deposited, and exactly one invoice names the reference.



# What the panel lists: staged notifications with their best invoice matches,
# newest first. A candidate whose invoice has since been paid is dropped.



# A bank or aggregator that can see e-Transfer notifications posts the same
# facts here. The task token is the gate, exactly like the LoRaWAN uplink.

# ---------------------------------------------------------------------------
# The Clock app: alarms, timers, and the little that has to live server-side.
#
# Alarms and timers are rows in the `settings` table under app 'clock' so they
# survive a restart and ride the house's usual per-device sync. They are small
# JSON arrays, capped at ten each. Every read-modify-write takes one flock so a
# web worker saving an alarm cannot lose the alarm the firing loop just marked,
# and the firing loop itself runs from Alarm.pl.
# ---------------------------------------------------------------------------

our @clock_sound_files = qw/chime.mp3 crystal.mp3 ding.mp3 pulse.mp3 rattle.mp3 ring.mp3 sonar.mp3/;
# Long-form alarm tracks, kept under public/sounds/alarms/ and served to the
# operating system's player. The labels are the titles the recordings came with.
our %clock_long_alarm_files = (
	'bros-and-monks-2.mp3' => 'Bros and Monks 2',
	'bros-and-monks.mp3' => 'Bros and Monks',
	'dolphin-chorus-singers-reuniting-tour.mp3' => 'Dolphin Chorus Singers Reuniting Tour',
	'find-the-ship-learn-from-it.mp3' => 'Find the Ship, Learn From It',
	'going-to-work-in-the-battery-factory.mp3' => 'Going to work in the battery factory',
	'it-feels-so-right.mp3' => 'It Feels so Right',
	'mans-gotta-bellow.mp3' => 'Man\'s Gotta Bellow!',
	'music-to-gel-your-hair-to.mp3' => 'Music to gel your hair to',
	'music-to-grow-a-mullet-to.mp3' => 'Music to grow a mullet to',
	'our-heads-will-stay-up.mp3' => 'Our Heads Will Stay Up',
	'the-hero-always-gets-the-squirrel.mp3' => 'The Hero Always Gets the Squirrel',
	'we-celebrate-the-lives-of-those-with-gum-disease.mp3' => 'We Celebrate the Lives of Those with Gum Disease',
	'were-all-professionals-here.mp3' => 'We\'re all Professionals Here',
);
our ($clock_apps_memo, $clock_apps_memo_at, $clock_apps_memo_images);


# Alarms are the house's, not one machine's: they live in a single settings row
# every machine reads, and each alarm names the machines that should ring it.
# Timers stay on the machine that started them (they are a countdown in a hand).

# The machines an alarm can be shared with: this machine ("Me") first, then
# every peer the mesh knows. The value is the machine's signatorial, because
# that is the identity each machine compares against its own.

# Does this alarm ring on this machine? An empty list is an alarm from before
# sharing: every machine that held the row rang it, so keep that reading.


# The alarm picker's library: the short chimes first, then the long recordings.


# A stored alarm may be a chime's bare name from before the library grew, a
# notifications/ path, or a long alarms/ path. Everything else is refused.





# A long-form track is one process; Dismiss kills it through the pid its shell
# wrote when it started. A short chime finishes on its own and has no pid file.

# A ringtone preview is the alarm's own sound, played on this machine for a
# few seconds while the person chooses. It is one process at a time, so
# auditioning the next sound ends the last one.



# The phone app is the only device that can wake itself from Doze and put an
# alarm in front of a locked screen. jawn hands it both the next alarm and the
# moment one rings over these short broadcasts; the app's receivers do the rest.

# Write the next alarm for the app, and only broadcast when it really moved.
# The file is what survives a reboot; the broadcast is what arms it now.


# A timer's chime is the same promise as an alarm's; it goes through the same
# alarm channel on a phone rather than the notification stream.







# The house alarm list. Before sharing, each machine kept its own row under its
# device type; a new install would see only its own. The first read moves every
# such row into the single house row, and those alarms are addressed to the
# machine doing the moving ("Me").





# The next moment an alarm is due, strictly after $from. A day list of none is a
# one-shot: the next such time, whatever day it lands on. The caller decides what
# to do with a moment that has just gone by (the firing loop allows two minutes).


# Nudge the alarm worker so a save, a start or a cancel is reflected at once
# rather than at the appointment it was already sleeping toward.


# The moment an alarm will next run, for the row's countdown. A snooze is the
# next run; a skipped occurrence is not, so the search starts past it.

# The phone's "Skip today" button cannot call the manager, so it writes this
# little file; the alarm worker picks it up and applies the same skip the
# browser button does.


# Every NFC tag row for an app, across devices. A tag is written from the phone
# that owns the reader, so its settings row may sit under that machine; the
# alarm has to find it whichever machine is editing the Clock.

# The controls that start an app. A tag assigned for any of these can answer the
# linked alarm; a tag that only records or commands does not count as the
# waking-up tag.


# app => 1 for every app with a start tag; the alarm editor uses this to offer
# the "Use NFC to snooze" box only where a tag really exists.



# How loud the OS alarm is at a moment in its ring: a little above silence at
# the start, then the alarm's own volume by the end of its ramp. The browser
# draws the ring card, but the sound belongs to the machine.

# A long-form track loops until Dismiss, Snooze or the five-minute guard. The
# old reading played a recording once and left the person asleep after it ended;
# `repeat` makes the operating-system player carry the alarm the same way a
# phone's alarm channel does. The pid file still lets Dismiss stop it.

# The command the OS player runs for this alarm. A long track is played once,
# at the alarm's volume, with the ramp as its fade-in, and its pid is written so
# Dismiss can stop it. A chime is played at the moment's ramped volume.

# Play one repetition of a short chime through the operating system. The
# notification at the first ring carries the first sound; later rings use this
# one directly, so the volume climbs across the ramp and no notification row is
# written each time. A long-form track is never repeated this way.




# One pass of the clock's own clock. Called by Alarm.pl; returns the next moment
# it should be woken for, or undef when there is nothing waiting.
# --------------------------------------------------------------------------
# Per-machine ring state
#
# The alarm list is shared, but the sound is local. Each machine remembers the
# fire it has already handled and when its own ring began, so a peer syncing
# the row mid-ring cannot make it ring twice. A dismiss or snooze is carried on
# the shared row (`stop_at`, `snooze_until`) and, for speed, relayed to the
# machines the alarm names.



# Hand a dismiss/snooze/stop_all to the machines that carry the alarm. The
# shared settings row reaches them as well; this is what makes the stop
# immediate rather than whenever the next sync runs. Quiet about a peer that is
# away - the row will still catch it up.

# ---- confirmed, immediate alarm sharing -------------------------------------
# The shared settings row carries an alarm to the other machines eventually, on
# the normal sync pass. These helpers push a single edit now, wait for the peer
# to answer, and record who confirmed. A peer that does not answer directly is
# offered the edit through another reachable machine, one hop only.




# The roster rows a push can reach, by signatorial. A same-LAN row may carry no
# manager URL; the lister builds one when the push finds it missing.

# One target's row, resolved the way the rest of the peer rail resolves a peer.
# A machine advertises the manager it answers on, which on an Android handset is
# its own 127.0.0.1: using that verbatim made every alarm push to the phone fail
# with "Connection refused" and no confirmation was ever recorded. The lister
# swaps a loopback or dead tailnet manager for the LAN address the peer
# advertised, so a phone on the house network is reached directly.

# Push one alarm edit. Returns { delivered => [...], failed => [...] }. The
# ack file is written here, so the next /manager/clock/state already shows the ✓.

# Apply an edit that arrived from a peer. A per-alarm `updated` stamp decides
# between two copies; the shared row still converges later either way.

# The phone's notification buttons and the lock-screen gestures cannot call the
# manager, so they leave a small request here; the alarm worker applies it within
# a couple of seconds. The file holds one request and is removed as it is read.


# A future appointment in an app whose notification panel has Alarm on becomes
# one Clock alarm, linked back to that appointment. Re-saving the appointment
# moves the same Clock row; the next future one replaces it, so an app never
# collects a pile of stale alarms.


1;
