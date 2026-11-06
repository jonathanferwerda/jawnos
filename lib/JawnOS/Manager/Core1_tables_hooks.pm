package Manager;

# Manager boot, part 1 of 2. Verbatim from the old Manager.pm: the app's own
# tables, the load-time hooks and the asset bundle lists. Manager.pm requires
# this at the exact point the code used to sit, so load order and eagerness are
# unchanged. The package is still Manager; the lazily loaded helpers stay in
# lib/JawnOS/Manager/Part*.pm.
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
	/js/manager/lazy.js
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
	/js/manager/budget_light.js
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
	/js/manager/weather.js
	/js/manager/weather_history.js
	/js/manager/clock.js
	/js/manager/help.js
	/js/manager/page_agent.js
	/js/manager/coding.js
	/js/manager/agents.js
	/js/manager/camera.js
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
	network         => [qw(/js/manager/network.js)],
	phone           => [qw(/js/manager/phone.js)],
	people          => [qw(/js/manager/people.js)],
	notes           => [qw(/js/manager/notes.js)],
	weather         => [qw(/js/manager/weather.js /js/manager/weather_history.js)],
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
	notes_toggle => 'notes', search_app_toggle => 'search', camera_toggle => 'camera',
	network_toggle => 'network', phone_toggle => 'phone', ide_toggle => 'ide',
	budget => 'budget', warehouse_toggle => 'warehouse', measures_toggle => 'measures',
	market_toggle => 'market', process_monitor_toggle => 'process_monitor',
	store_toggle => 'store', email_toggle => 'email',
	weather_toggle => 'weather',
);

# The one bundle the page loads up front: everything an app chunk names is gone
# from it. A file added to the list above but not to any app stays core, so a
# mistake costs bytes rather than a broken app.
our @manager_core_files = do {
	my %lazy = map { $_ => 1 } map { @{$_} } values %manager_app_scripts;
	grep { !$lazy{$_} } @manager_bundle_files;
};

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
