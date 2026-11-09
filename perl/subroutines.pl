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
our %recurrence_plan_cache;
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
our %ghost_times_memo;

# An hour written the clothesline's way ("9am", "10pm", "12am") as a number 0-23.

# The span a ghost should wear: the app's own recent average, its duration setting,
# else nothing.

# The real appointments an app has near now, cached briefly, for matching an
# expected time to the occurrence a real one belongs to. Only called for apps that
# have a habit, so the range stays small.
our %ghost_done_memo;
our $say_quiet;
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
our ($network_report_memo, $network_report_memo_at);
	sub ble_presence_window() { return 7200000; }
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
our $plaintext_ft;
our $SEALED_PROBE_BYTES = 16384;
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
our %archive_folder_names = (
	music => 'Music',
	download => 'Downloads',
	photo => 'Photos',
	document => 'Documents',
	video => 'Videos',
	scan => 'Scans',
	rec => 'Recordings'
);
our $minion;
our %archive_manifest_memo;
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
our %construct_uuid_memo;
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
# set, cursor, material, face and corner. The presets below are the house's own curated
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
		cursor_set => 'bold',
		font => 'Noto Sans, system-ui, sans-serif', corner => 12,
	},
	jawnfish => {
		name => 'Jawnfish', scheme => 'Teal',
		icon_set => 'pastel', texture => 'soft',
		cursor_set => 'pastel',
		font => 'Cantarell, system-ui, sans-serif', corner => 16,
	},
	adwaita => {
		name => 'Adwaita', scheme => 'Graphite',
		icon_set => 'gnome', texture => 'soft',
		cursor_set => 'outline',
		font => 'Cantarell, system-ui, sans-serif', corner => 12,
	},
	cuperjawno => {
		name => 'Cuperjawno', scheme => 'Graphite',
		icon_set => 'mac', texture => 'soft',
		cursor_set => 'white',
		font => 'system-ui, sans-serif', corner => 12,
	},
	jawndows => {
		name => 'Jawndows', scheme => 'Blue',
		icon_set => 'windows', texture => 'soft',
		cursor_set => 'bold',
		font => 'Segoe UI, system-ui, sans-serif', corner => 8,
	},
	mint => {
		name => 'Mint', scheme => 'Green',
		icon_set => 'gnome', texture => 'paper',
		cursor_set => 'outline',
		font => 'Noto Sans, system-ui, sans-serif', corner => 10,
	},
	nord => {
		name => 'Nord', scheme => 'Nord Dark',
		icon_set => 'outline', texture => 'fabric',
		cursor_set => 'outline',
		font => 'Inter, system-ui, sans-serif', corner => 10,
	},
	sage => {
		name => 'Sage', scheme => 'Sage',
		icon_set => 'pastel', texture => 'fabric',
		cursor_set => 'pastel',
		font => 'Noto Sans, system-ui, sans-serif', corner => 14,
	},
	mocha => {
		name => 'Mocha', scheme => 'Mocha Dark',
		icon_set => 'outline', texture => 'paper',
		cursor_set => 'pastel',
		font => 'Palatino Linotype, Iowan Old Style, Georgia, serif', corner => 14,
	},
	neon => {
		name => 'Neon', scheme => 'Indigo Dark',
		icon_set => 'neon', texture => 'glass',
		cursor_set => 'neon',
		font => 'JetBrains Mono, Courier New, monospace', corner => 14,
	},
	mono => {
		name => 'Mono', scheme => 'Graphite Dark',
		icon_set => 'mono', texture => 'metal',
		cursor_set => 'mono',
		font => 'system-ui, sans-serif', corner => 6,
	},
	rose => {
		name => 'Rose', scheme => 'Rose',
		icon_set => 'pastel', texture => 'paper',
		cursor_set => 'pastel',
		font => 'Noto Sans, system-ui, sans-serif', corner => 16,
	},
	# Phosphor green, a monospace face, a CRT grain and square corners: the
	# dressing a terminal-dweller reaches for.
	geek => {
		name => 'Geek', scheme => 'Geek Dark',
		icon_set => 'neon', texture => 'sandglass',
		cursor_set => 'mono',
		font => 'JetBrains Mono, Courier New, monospace', corner => 2,
	},
	# The VT220: amber on warm black, plain plates, outline glyphs, square
	# corners and the Courier face the terminals actually printed in.
	phosphor => {
		name => 'Phosphor', scheme => 'Phosphor Dark',
		icon_set => 'outline', texture => 'classic',
		cursor_set => 'contrast',
		font => 'Courier New, monospace', corner => 0,
	},
	# Neon nights: cyan glass with a magenta accent and iridescent glyphs.
	cyberpunk => {
		name => 'Cyberpunk', scheme => 'Cyberpunk Dark',
		icon_set => 'holographic', texture => 'glass',
		cursor_set => 'neon',
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
our $icon_set_memo;
our $icon_set_memo_time = 0;
# cursor_set() asks the same question on every render, so it is memoised on the
# same short TTL as the icon set.
our $cursor_set_memo;
our $cursor_set_memo_time = 0;
# The size slider is memoised on the same TTL; it is read once per cursor set.
our $cursor_size_memo;
our $cursor_size_memo_time = 0;

# Whether the active desktop theme is dark, and the scheme name driving it (blank
# when the Misc manager colour is in charge). Memoised on the same short TTL as
# icon_set() because a render asks it once per icon and once per surface.
our ($theme_state_memo, $theme_state_time);
our %icon_plate_memo;

# A fingerprint of everything that gets baked into cached window/header HTML:
# the icon set, the active theme's dressing and the device's theme colours.
# Cached renders whose signature no longer matches are discarded, so closed
# windows don't come back looking stale.




&signatorial_establisher();
our %relationship_rating = (self => 1, friend => 1, stranger => 2, enemy => 3);
our @relationship_order = qw/self friend stranger enemy/;

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
our $lan_beacon;
our $lan_reply_beacon;
our %lan_reply_at;
our $house_key_wrap_magic = 'JHKY1';
our $house_key_wrap_context = 'jawnos/house-key/v1';
our %house_key_wrap_alg = ('Crypt::PK::X25519' => 1, 'Crypt::PK::ECC' => 2);
our $house_key_password_magic = 'JHKP2';
our $house_key_password_context = 'jawnos/house-key/recovery/v1';
our $shamir_paper_prefix = 'PS1';
our $crockford_alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
our $crest_peer_list_cache;
our $crest_peer_list_raw;
our $tier_required = [
	[ 'citizen',  qr{^/manager/(?:configure|security|magazine/publish|power)(?:/|$)} ],
	[ 'resident', qr{^/manager(?:/|$)} ],
];
our %tier_rank = ( guest => 1, resident => 2, citizen => 3 );
our $SPEED_MEASURE_GAP_MS = 60000;   # one reading a minute
our $SPEED_MEASURE_CAP = 500;        # a single appointment keeps this many at most
# A join request is only a short introduction: ten minutes is long enough for a
# person to read a code out loud and type it on the other machine, and every read
# deletes a request older than this.
our $JOIN_REQUEST_TTL_MS = 600000;

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
our $AI_UNAVAILABLE_FOR = 30 * 60 * 1000;
# the model that actually answered the last ai_chat (a paid one may stand down)
our $ai_last_model;
# what model calls have cost, running (calls, in, out tokens): the error watch
# reads it around a proposal to log the spend and to stop at its day's budget
our $ai_tokens = { calls => 0, in => 0, out => 0, unmetered => 0 };
our $evaluation_agent_ready_memo;
our %schedule_memo;
our $code_revision_cache;
our $jawn_version_cache;
our %accounting_account_cache;
our $backfills_running;
our %error_watch_state;    # source => bytes already read (for this watcher's life)
our %error_watch_partial;  # source => an unterminated tail line
our $error_watch_state_loaded = 0;
our $ai_eval_ready_memo;

# Publish this machine's capability and heartbeat, throttled: a row every couple
# of minutes is enough to keep it counted, and the peers see it when next synced.

# Publish this machine's capability and heartbeat, and make sure the ledger tables
# exist (so it works from the first boot after an update, before anyone logs in
# and migrates). Called at the top of the watch tick, before the watch toggles
# are consulted: the ledger gates evaluations and the shared budget too, so a
# machine must announce itself whatever the watches are set to.
our $ai_ledger_ready;
our $error_watch_noise = qr/Permission denied|cannot open \/proc\/net|Cannot bind netlink|error watch:|President stopping on SIGINT; cleaning up|Broken pipe|UDTA parsing failed|source=model_show_cache|model recommendations refresh failed|Socket sender:|kill: sending signal to \d+ failed: No such process|\{"event": "error", "message": "not connected"\}/;
our $coding_protocols_cache;
our $coding_protocols_mtime;
our $git_watcher_blocked_note;
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
1;
