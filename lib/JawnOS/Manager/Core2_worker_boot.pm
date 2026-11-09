package Manager;

# Manager boot, part 2 of 2. Verbatim from the old Manager.pm: the folder and
# mailbox state, the junderground client, remote-input geometry, the padlock and
# credential caches, the websocket server and the three $ENV{PURPOSE} worker
# blocks. Manager.pm requires this last, at the exact point the code used to
# sit, so every block here still runs eagerly when the app loads.
use strict;
use warnings;
use utf8;
use feature 'signatures';
# File-scoped pragmas do not cross a require: repeat the ones the original
# file had in force at this point, so diagnostics are unchanged.
no warnings 'uninitialized';
no warnings 'once';
BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../.." if $dir && -d "$dir/../..";
}
use JawnOS::Transport ();
# Globals declared by the index (Manager.pm) and read below.
use vars qw($config $decoder $log);


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
		# On TCP one port carries every app (the payload names its app), so there
		# is nothing per-app to probe or rebind.
		if (JawnOS::Transport::tcp()) {
			my $server = $ws_server->{'__tcp'};
			return if $server && defined Mojo::IOLoop->acceptor($server);
			$ws_server->{'__tcp'} = &ws_server_socket({ app => 'ws' });
			return;
		}
		foreach my $ws ( @{$gb::ws_apps} ) {
			my $file = $gb::tmp_dir . '/ws/' . &subs::path_name($ws);
			if ($check && -e $file) {
				my $probe = JawnOS::Transport::client_unix_socket($file);
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
		my $file;
		my $args;
		if (JawnOS::Transport::tcp()) {
			my $existing = $ws_server->{'__tcp'};
			return $existing if $existing && defined Mojo::IOLoop->acceptor($existing);
			$args = JawnOS::Transport::server_args('ws') or return undef;
		}
		else {
			my $folder = $gb::tmp_dir . '/ws';
			`mkdir -p $folder` unless -e $folder;
			$file = $folder . '/' . &subs::path_name($app);
			# a reused descriptor wins over a real bind in Mojo's listen(), and the
			# pre-fork server put this path in MOJO_REUSE from the loader's own
			# listeners; drop it so the bind really creates the path
			if ($ENV{'MOJO_REUSE'}) {
				$ENV{'MOJO_REUSE'} = join ',', grep { !/^unix:\Q$file\E:/ } split /,/, $ENV{'MOJO_REUSE'};
			}
			unlink $file if -e $file;
			$args = JawnOS::Transport::server_args('ws', path => $file) or return undef;
		}
		my $server = eval {
			Mojo::IOLoop->server($args => sub ($loop,$stream,$id) {
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
            next unless ref $wsm eq 'HASH';
            next if JawnOS::Transport::tcp()
                && !JawnOS::Transport::token_ok($wsm->{'token'});
						# The 'device' group is the embedded output bus, not a
						# browser app: deliver to the socket the websocket worker
						# holds for that chip. No chip connected means nothing goes
						# out; the caller already chose its HTTP fallback.
						if (($wsm->{'app'} || '') eq 'device') {
							&subs::device_ws_deliver($wsm);
						}
						else {
							&websocket_sender($wsm);
						}



						$stream->write($wsm->{'uuid'}) if defined $wsm->{'uuid'} && $wsm->{'uuid'};
					}
				});
				$stream->on(close => sub {
					delete $buffers{$id};
				});
			});
		};
		my $err = $@;
		$log->error('ws socket ' . ($file || 'tcp') . ' could not bind: ' . ($err || 'no acceptor')) if $err || !defined $server;
		return $server;
	}

	# One accessor for the per-app listener: native binds one path per app, TCP
	# binds one shared port (the payload names the app). A caller that only has
	# its app name asks here instead of touching $ws_server directly.
	sub ws_server_ensure($app) {
		return $ws_server->{$app} if $ws_server->{$app};
		if (JawnOS::Transport::tcp()) {
			my $server = $ws_server->{'__tcp'};
			return $server if $server && defined Mojo::IOLoop->acceptor($server);
			return $ws_server->{'__tcp'} = &ws_server_socket({ app => 'ws' });
		}
		return $ws_server->{$app} = &ws_server_socket({ app => $app });
	}

	my $mailfile = $gb::tmp_dir . '/ws/mailws';

	my $mailws_server;
	my $mailws_listener = sub {
		my $args = JawnOS::Transport::server_args('mailws', path => $mailfile) or return;
		if (!JawnOS::Transport::tcp()) {
			# the loader no longer binds the per-app sockets (a fork child must),
			# so this process makes the folder rather than finding it made
			my $ws_folder = $gb::tmp_dir . '/ws';
			`mkdir -p $ws_folder` unless -d $ws_folder;
			unlink $mailfile if -e $mailfile;
		}
		$mailws_server = eval { Mojo::IOLoop->server($args => sub ($loop,$stream,$id) {
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
		        next unless ref $m eq 'HASH';
		        next if JawnOS::Transport::tcp()
		            && !JawnOS::Transport::token_ok($m->{'token'});

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
		return if JawnOS::Transport::tcp();   # one shared listener serves every app
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




if ($ENV{PURPOSE} && ($ENV{PURPOSE} ne "alarm" && $ENV{PURPOSE} ne "watch" && $ENV{PURPOSE} ne "teletype" && $ENV{PURPOSE} ne "coding")) {

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