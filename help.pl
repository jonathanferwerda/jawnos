#!/usr/bin/env perl
# The help registry: plain-language descriptions of every app, feature, device
# and cross-cutting function, keyed by a topic id. A topic is
#
#   title    - what the reader sees as the heading
#   category - 'apps' | 'features' | 'functions' | 'devices'
#   summary  - one line, used in the index and in hover enrichments
#   body     - an arrayref of paragraphs (plain text; the template escapes it)
#   steps    - an optional arrayref of how-to steps, shown as an ordered list
#   related  - an arrayref of other topic ids worth reading next
#   app      - optional: the app name whose window this topic explains, so the
#              template can offer an "Open" button
#   prompt   - optional: extra steering handed to the Help agent for this topic,
#              on top of the entry itself
#
# The registry is deliberately data, not code: adding a topic is adding a key.
# Topics are matched case-insensitively and tolerate spaces or hyphens where the
# key has underscores, so help("Start Menu"), help("start-menu") and
# help("start_menu") all resolve.

package help;

use strict;
no warnings;

# The date every topic is considered vetted as of, unless it carries its own
# `verified`. The auditor compares this against the git history of the app's
# files: anything that changed since is reported as possibly stale.
our $verified_default = '2026-10-12';

our %topic = (

	# ---------------------------------------------------------------- apps
	'folders' => {
		title => 'Folders', category => 'apps', app => 'folders',
		summary => 'Browse, manage, seal and play with your files.',
		verified => '2026-10-18',
		body => [
			'Folders is the file browser. It walks your media directories and shows thumbnails for images, video and audio, with a full right-click menu on every file and folder: new file and folder, rename, open, open with, copy, cut, paste, delete, shred, archive and properties.',
			'Right-click a file to seal it — encrypt it under a name of its own — and open it again from the same menu. Long jobs (moving, sealing, opening, deleting) run in the background and report their progress.',
			'Moving, sealing, opening or deleting a file carries the appointments, mail attachments and store entries that named it along with it, so nothing is left pointing at a file that is no longer there.',
			'A lock on the toolbar turns the media padlock. Anything you have marked not-visible is kept out of the listing until the padlock is open and you are at home, so a private folder stays out of sight out in public.'
		],
		steps => [
			'Open Folders from the start menu.',
			'Click into a folder to descend; the breadcrumb along the top walks back up.',
			'Right-click a file for its menu — open, rename, copy, cut, delete, shred, seal or properties.',
			'To keep something safe off the record, choose Seal: it is encrypted under a name of your own, and opens again from this same menu.',
			'For a not-visible folder, press the lock on the toolbar and unlock it on a paired phone, and it appears — at home.'
		],
		related => [ 'sealing_files', 'gallery', 'backup' ]
	},
	'gallery' => {
		title => 'Gallery', category => 'apps', app => 'gallery',
		templates => [ 'templates/apps/gallery.html.ep', 'templates/apps/gallery_album.html.ep', 'templates/apps/gallery_home.html.ep' ],
		controls => [ 'Previous', 'Next', 'Refresh', 'Repeat', 'Shuffle', 'File information', 'Fetch home', 'Set as main image', 'Albums', 'Home', 'Lock', 'Archives' ],
		verified => '2026-10-18',
		summary => 'Browse your photos by album or one at a time, and choose what each app shows.',
		body => [
			'Gallery is the photo browser. It gathers the photos and videos your apps have recorded and shows them three ways: **Home** (an album cover per app), **Album** (every photo in one scrollable grid) and **Photo** (a single shot, full-screen).',
			'Which photos appear is decided by the **sources** — the apps whose galleries are open. Open the apps you want to look through and their photos join the Gallery; a source app also has to be marked visible (or the gallery unlocked) to be shown.',
			'In the single-photo view you can walk the whole set, shuffle or loop it, read a photo\'s details, or make it the cover the app uses. In the Album view you can search, flip the order, and include photos whose local copy has moved to the archive.'
		],
		steps => [
			'Open the apps whose photos you want to browse — Gallery shows the galleries of the windows you have open.',
			'Open Gallery from the start menu (the photo icon). It lands on Home, one album cover per app.',
			'Use the Home button for the album covers and the Albums button for the full grid of every photo; as you scroll the grid it keeps loading more.',
			'Click any photo to open it full-screen. The toolbar gives Previous and Next, Refresh (reload the set), Shuffle (play them in a random order), Repeat (loop the slideshow), File information, Fetch home, and Set as main image.',
			'Type in the Search box (top-left in Home and Album) and press Enter to find photos by app or file name.',
			'In Album view, toggle Archives to include photos stored away, and use the arrow to flip the order between newest-first and oldest-first.',
			'The lock covers the gallery when you want it out of the way; unlock it on a paired phone.'
		],
		prompt => 'The reader is using JawnOS\'s Gallery, a photo browser — not a phone gallery and not a file manager. Its photos are the ones recorded by their apps, and which apps are shown are the "sources", which default to the apps they currently have open. Guide them in terms of the Home / Album / Photo views and the named buttons (Home, Albums, Previous, Next, Shuffle, Repeat, Refresh, File information, Set as main image, Archives, lock). If they say they see nothing, the likeliest cause is that no source app is open or marked visible — suggest opening an app that has photos. If you are unsure how a control starts or works, describe what its label means rather than inventing a sequence of clicks. Never describe or guess the content of their photos.',
		related => [ 'folders', 'marker', 'sealing_files', 'help_app' ]
	},
	'marker' => {
		title => 'Marker', category => 'apps', app => 'marker',
		summary => 'A layered paint board for drawing and annotation.',
		body => [
			'Marker is a layered paint board with pencil, paintbrush, spray, fill and matching erase tools, plus undo and redo, zoom and pan.',
			'It reads stylus pressure and ignores your palm on a tablet, and it autosaves so a refresh never loses a painting.'
		],
		steps => [
			'Open Marker and pick a tool from the palette — pencil, brush, spray, fill or erase.',
			'Add a layer for anything you want to keep separate, and name it by double-clicking.',
			'Your work autosaves; reopen the drawing later from the marker\'s session list.'
		],
		related => [ 'gallery', 'studio' ]
	},
	'studio' => {
		title => 'Studio', category => 'apps', app => 'studio',
		templates => [ 'templates/studio/studio.html.ep', 'public/js/manager/studio.js' ],
		summary => 'A multitrack audio studio with takes and a pedalboard.',
		verified => '2026-10-16',
		body => [
			'Studio is a multitrack recorder and editor: takes, crossfades, waveform clips, and a pedalboard routed onto individual channels.',
			'It works with the same library as Music, so recorded and imported tracks sit together.',
			'A channel\'s input is a plug you choose: a microphone or camera, another window, screen share, or the Synth — pick Synth and what you play records through the channel\'s tone stack and pedals like any other source.',
			'A synth panel sits at the top of the window (Hide tucks it away): pick a sound and play its keys right there, then record it by setting a channel\'s input to Synth.'
		],
		steps => [
			'Open Studio and add a track per instrument or take.',
			'Record or drop a clip onto a track; drag its edges to trim and overlap to crossfade.',
			'Route a pedalboard onto a channel to shape its sound, then mix the tracks together.'
		],
		related => [ 'music', 'synth' ]
	},
	'synth' => {
		title => 'Synth', category => 'apps', app => 'synth',
		summary => 'A polyphonic synthesiser with 88 keys, MIDI, and a computer-keyboard mode.',
		verified => '2026-10-16',
		body => [
			'Synth is a polyphonic software synthesiser. It plays from the on-screen keys (a full 88-key range, A0 to C8, that scrolls sideways), a connected USB MIDI keyboard, or your computer keyboard. It shares the studio\'s audio engine, so it can be routed into a channel and recorded like any other source.',
			'Its voices are two oscillators (plus a noise transient) through a resonant filter, each with its own envelope and a shared LFO, or a plucked-string voice that gives a convincing piano, harpsichord or guitar without any samples; a harder strike is brighter, not just louder. The sound library is twelve instruments - Acoustic Piano, Electric Piano, Organ, Strings, Brass, Woodwind, Guitar & Plucked, Bells & Mallets, Bass, Lead, Pad and Synth Poly - each with twenty sounds, the most popular first.',
			'The piano roll is the full 88 keys, as wide as its window and scrolled to the octave you are playing from the computer keyboard. An arpeggiator (Arp) turns a held chord into a running figure - up, down, up/down or random, over one to four octaves. Mono (with Glide) plays one voice that slides between notes, and MIDI learn maps a knob on your controller to any parameter: choose it, press Learn, and move the knob. A step sequencer (Seq) loops a grid of notes through the synth at its own rate.'
		],
		steps => [
			'Open Synth.',
			'Choose an instrument and a sound, play the on-screen keys, or press Connect and play a USB MIDI keyboard.',
			'Press Keys to play from the computer keyboard (A W S E D F T G Y H U J K; Z and X change octave, and the roll follows).',
			'Press Arp and hold a chord to arpeggiate it; press Seq to loop a grid; switch on Mono for a gliding lead.',
			'To map a hardware knob: pick a parameter, press Learn, then move the knob.',
			'In Studio, set a channel\'s input to Synth (or drag the JawnSynth pedal onto it), arm it, and record what you play.',
			'The same synth also sits as an always-visible panel at the top of Studio, so you can pick a sound and play without leaving it.'
		],
		related => [ 'studio', 'music' ]
	},
	'music' => {
		title => 'Music', category => 'apps', app => 'music',
		templates => [ 'templates/apps/music/music.html.ep', 'templates/apps/music/files.html.ep', 'templates/apps/video.html.ep', 'public/js/music.js' ],
		controls => [ 'Theatre mode', 'Fullscreen', 'Visualization' ],
		verified => '2026-10-19',
		summary => 'A player, a library, and the place music is organised.',
		body => [
			'Music is the player and library: artists, albums and folders, with a mute, a lock and a configuration drawer.',
			'Texture, in Appearance, dresses the window in the desk\'s material - the top interface bar, every track, the player bar at the foot and every other surface; Plain and Round leave them bare.',
			'It plays through the browser and can hand playback to a linked device, and it is where the audio output is chosen.',
			'An audio track has no picture of its own, so the player can draw the sound instead and play that drawing as its picture: the tools panel in the player carries a Visualization choice of None, Equalizer (bars of the spectrum), Dots (colourful dots that dance, and now and then grow a face), Psychedelic (a tie-dye that swirls with the music) and Modern Art (painted strokes that follow the sound).',
			'On a phone the window draws itself differently: the artists and albums become one line of pills each, scrolling sideways, and the tracks below them are cards — the picture, the title (up to two lines) and the time — with the list running right down to the player, so the time is always in reach.'
		],
		steps => [
			'Open Music; the library lists artists and albums from your media folders.',
			'Click a track to play it; the transport along the top controls playback.',
			'For a track with no picture of its own, open the tools panel (the wrench in the player) and choose a Visualization; the drawing shows in the player\'s corner while the library is up, and takes the whole player in Theatre mode or fullscreen.',
			'Fullscreen (the player button, or F) fills the screen with the picture; moving the mouse brings back the top bar and the transport, and they fade away again when the pointer rests.',
			'A wheel over the picture moves through the track; on a trackpad, a sideways swipe does the same and up/down sets the volume. On a touchscreen, drag sideways to move through it and up or down to set the volume. The same gestures work in fullscreen, over the interface; the fullscreen button (or F) leaves fullscreen too.',
			'Open the configuration drawer to choose the audio output, or to send playback to another machine on the mesh.'
		],
		related => [ 'studio', 'synth' ]
	},
	'video' => {
		title => 'Video', category => 'apps', app => 'video',
		verified => '2026-10-18',
		summary => 'Play video from your media folders.',
		body => [
			'Video plays your files in the window. Playback quality is the browser\'s (or, in the desktop app, GStreamer\'s) — the desktop app page covers the hardware-decode setup that keeps HD smooth.'
		],
		steps => [
			'Open Video and pick a file from your media folders.',
			'Play, pause and scrub with the controls; go fullscreen from the player.',
			'A wheel over the picture scrubs it; on a trackpad, a sideways swipe scrubs and up/down sets the volume. On a touchscreen, drag sideways to scrub and up or down to set the volume. The fullscreen button leaves fullscreen too.'
		],
		related => [ 'gallery', 'folders' ]
	},
	'editor' => {
		title => 'Editor', category => 'apps', app => 'editor',
		summary => 'A rich text editor whose variables can answer for an appointment.',
		body => [
			'Editor is a rich text editor for letters, notes and documents. Its variables can pull live values — including values from an appointment — so a document can fill itself in from your data.'
		],
		steps => [
			'Open Editor and start a document.',
			'Where you want a live value, drop in a variable; it can answer for an appointment\'s field.',
			'Save the article; it appears in the library and can be reopened from where it belongs.'
		],
		related => [ 'ide', 'notes' ]
	},
	'ide' => {
		title => 'IDE', category => 'apps', app => 'ide',
		templates => [ 'templates/apps/coding_chat.html.ep', 'public/js/manager/coding.js' ],
		summary => 'A colour-coded editor for Perl, JavaScript, HTML and templates.',
		verified => '2026-10-16',
		body => [
			'IDE edits code with syntax colouring for Perl, JavaScript, HTML and templates. It is what the project is developed in from inside itself.',
			'The code button in the toolbar opens the Coding agent\'s own chatbox: ask it what to change and it edits the repo, checks the change and ships it, reporting each step. It is the same agent the Guide\'s Coding toggle drives, and the editor keeps its own conversation. The + in its bar opens another agent, each with its own thread, and the bar drags the panel anywhere on the screen — it floats over the windows like the Guide\'s associate, and it reopens where you left it. A fix that has shipped reaches the page on its own: a stylesheet or template change lands in place, while a change to the manager\'s scripts or its shell asks once with a press-to-update note (a hidden tab reloads itself, and a chat in the panel survives it). Double-press the Assistant button for the Agents list: every coding conversation and guide associate, named, with history a press away.',
			'That chatbox also holds the error watch\'s staging area: press fixes in its corner to see every error caught in the running tree\'s log (switch the watch on under Configure → Plat → Self-healing), each with a fix the Coding agent has proposed. Apply writes the proposal, checks it compiles, and gives it the same finishing routine a chat change gets — bump, commit, push — and the panel\'s restart link puts it live. Forget throws a row away, and nothing is written until Apply. Every fix that ships is recorded: Fixed so far in Configure → Plat → Self-healing keeps the list, and review shows it.',
			'Only the top of the tree loads at first; a folder brings its own contents in when you unfold it, so a big project opens quickly. The tree reopens with the folders you had unfolded still open, the window returns to whichever pane — the list or the editor — you left it on, and the file list and each open file keep their place, so you come back to where you were.'
		],
		steps => [
			'Open the IDE and choose a file from the project tree; unfold a folder to see what is in it.',
			'Edit with syntax colouring and the code helpers.',
			'Save; a Perl or JavaScript change needs a restart to take effect, while a template change is live at once.',
			'Press the code button to open the Coding agent and describe a change in words.',
			'Drag the panel by its bar to move it; the + in the bar opens another agent, with its own conversation.',
			'Press fixes in its corner to review errors caught in the log and apply a proposed fix.'
		],
		related => [ 'editor', 'terminal' ]
	},
	'web' => {
		title => 'Web', category => 'apps', app => 'web',
		templates => [ 'templates/web/web.html.ep', 'templates/web/web_measure_confirm.html.ep' ],
		verified => '2026-10-18',
		summary => 'A browser in a window, with measures.',
		body => [
			'Web is a browser window, useful for pulling a page up beside your work without leaving the desktop.',
			'To watch a number on a page, open the page in Web and click the Measures icon in its toolbar. Pick the measure from the list, then click the value on the page. Web tests the click and offers the shapes it can read: a JSON path for a feed, the table row and cell that hold the value, a label with the value beside it, or the plain element. Pick the shape whose Value column shows the number you want, then press Save.',
			'The shape is stored, not a page position, so a table that gains a row keeps reading the right cell; a JSON feed keeps the exact key. A measure reads from the workspace as a whole, so the phone can fetch the page while the selectors stay on the computer.'
		],
		related => [ 'terminal' ]
	},
	'terminal' => {
		title => 'Terminal', category => 'apps', app => 'terminal',
		summary => 'A shell, in a window.',
		verified => '2026-10-13',
		body => [
			'Terminal is a real shell attached to the machine running JawnOS. It is where you do the hands-on work: scripts, checks, and the occasional bit of archaeology.',
			'The code button in the toolbar opens the Coding agent\'s chatbox, so you can ask for a change in words and watch it run the commands and ship the result without leaving the terminal. It keeps its own conversation. The bar drags the panel anywhere on the screen, and + in the bar opens another agent, each with its own thread.',
		],
		steps => [
			'Open Terminal; it opens a session on the host machine.',
			'Run commands as you would in any shell.',
			'Use multiple windows or tabs for separate jobs.',
			'Press the code button to hand a task to the Coding agent — or + in its bar for another one, so several can work at once.'
		],
		related => [ 'ide', 'process_monitor' ]
	},
	'camera' => {
		title => 'Camera', category => 'apps', app => 'camera',
		templates => [ 'templates/apps/camera.html.ep' ],
		controls => [ 'Take a photo', 'Record a video', 'Unclaimed media', 'Select all', 'Approved' ],
		verified => '2026-10-16',
		summary => 'The device camera and video recorder, plus the pool of unclaimed media waiting to be filed.',
		body => [
			'Camera takes a photo or records a video. In the app it opens the device camera and its video recorder (window.JawnCamera), so you get a viewfinder you can see and the camera\'s own processing. On the desktop and in a browser it uses the machine\'s own webcam through getUserMedia.',
			'A capture is filed under the Camera app. In the app the same pair of buttons also rides in an appointment\'s media group - Camera (native) and Video (native) - where the capture lands on the appointment instead.',
			'A capture taken in the Camera app itself - and media an agent generated without an appointment - waits in Unclaimed media with a one-week warranty. Tick the items you want (or Select all), then search for an appointment name and press Approved, or drop them onto the drop zone.'
		],
		steps => [
			'Open Camera from the start menu, or pin it to the taskbar.',
			'Tap Take a photo or Record a video; the OS camera opens.',
			'The capture is saved when you accept it in the camera.',
			'To file unclaimed media onto an appointment, tick items, search for the appointment name, and press Approved.'
		],
		related => [ 'gallery' ]
	},
	'phone' => {
		title => 'Phone', category => 'apps', app => 'phone',
		templates => [ 'templates/apps/phone.html.ep', 'public/js/manager/phone.js' ],
		controls => [ 'Known', 'Recent', 'Blocked', 'All', 'Dial', 'Call', 'Caller ID', 'Block', 'Unblock' ],
		verified => '2026-10-16',
		summary => 'Calls, the house\'s known contacts, and a dial pad.',
		body => [
			'Phone shows the calls the house has logged - every call is an appointment with the subtype phone, on the caller\'s own app - and the numbers the house knows. Known is the people it knows; Recent lists the latest calls, and a row opens that person\'s thread; All adds the numbers that are only numbers, the ones a caller left behind that no name has claimed yet, which is where you go to find an unknown caller and name them.',
			'A person can keep more than one line (a home number, a work number, a second mobile - set under Configure, in the app\'s Phones tile). They are listed together on one row, the plain phone number first and the rest with their type; tapping any one fills the dial pad with that number, and a call or text from any of them still reaches the person.',
			'Blocked shows the Box Office\'s blocked numbers, each with an Unblock button. A number there never rings: the phone turns the call away and files it as a cancelled call, so it still shows in Recent.',
			'Known and All: tapping a number fills the dial pad with it. In the app the device\'s own address book (window.JawnContacts) replaces the Known list once its permission is granted.',
			'Dial is a pad that places a call on a phone (termux-telephony-call). On the desktop it says dialing is only available on a phone.',
			'With Caller ID on (the button asks for the Call screening role), the house learns who is calling as it rings. In the app that role names the caller on screen: an incoming call wakes the screen over the lock screen with their picture (the house\'s own image for them, or the JawnOS logo), their name, the number, and Answer and Decline. Without it the house\'s call-log check files the call a moment later.',
			'A call is recorded by the app itself, not by whatever page happens to be open: the phone keeps one record per call - who, which way, when, and whether anyone answered - and the house files it from that, so a call taken with the app in the background still becomes an appointment on the caller\'s own app (or the phone app when the number is not known). It opens at the ring and closes at the hangup, or cancels when nobody answered.',
			'A recent call\'s Block button - twice, the house\'s habit for anything that leaves a lasting rule - puts that number on the Box Office\'s blacklist, and Unblock in the Blocked pane takes it off again.'
		],
		steps => [
			'Open Phone from the start menu, or pin it to the taskbar.',
			'Known: tap a number to fill the dial pad - a person with several lines lists them all, and each one taps on its own.',
			'Recent: tap a call to open the caller\'s appointment thread.',
			'Recent: press Block twice on a call to bar that number from ringing again.',
			'Blocked: press Unblock twice to let a number through again.',
			'Dial: key a number and press Call.'
		],
		related => [ 'mailbox', 'box_office' ]
	},
	'notes' => {
		title => 'Notes', category => 'apps', app => 'notes',
		verified => '2026-10-14',
		summary => 'Free-form notes you can scan, OCR and barcode.',
		body => [
			'Notes is note-taking with a document-scanning streak. It can capture a page from a camera or scanner, read a barcode or QR code (zbar), run text recognition over a scan (Tesseract) and render documents to PDF.',
			'Each note is an appointment like everything else, so a scanned page can carry attachments and be found from whatever it belongs to.'
		],
		steps => [
			'Open Notes and start a new note.',
			'To scan a document, use the scan action and pick the camera or a scanner; crop the page if you are offered it.',
			'Turn on OCR to lift the text out of the scan, so the page becomes searchable.',
			'For a barcode or QR code, use the scan action in its code mode instead — it reads the code and records it on the note.',
			'Save the note; its scan and any recognised text travel with it.'
		],
		prompt => 'The reader wants a genuine step-by-step for scanning a document into JawnOS. Walk them through it in order, naming the buttons as they appear, and keep each step to one action.',
		related => [ 'editor', 'folders' ]
	},
	'tasks' => {
		title => 'Tasks', category => 'apps', app => 'tasks',
		summary => 'Nested checklists with colour, priority, renewal and budget.',
		verified => '2026-10-16',
		body => [
			'Tasks is a nested checklist. Each item carries a colour, a priority, a renewal interval and a budget, so a task can repeat on its own and keep its own tally.',
			'Ticking an item off can record the matching appointment, so doing the thing and logging the thing are one action.'
		],
		steps => [
			'Open Tasks and add a list.',
			'Add items; nest related ones under a parent to build a checklist.',
			'Give an item a colour, a priority, a renewal interval or a budget as needed.',
			'Tick an item off — if it is set to, the matching appointment is recorded for you.'
		],
		related => [ 'appointments', 'measures' ]
	},
	'measures' => {
		title => 'Measures', category => 'apps', app => 'measures',
		summary => 'Track a value over time.',
		body => [
			'Measures records a number against a time — weight, a reading, a score — and charts it. Ranges, multiple-selects and free values are all available, and the evaluation app can read what it finds.'
		],
		steps => [
			'Open Measures and pick the kind of value: a range, a multiple-select, or a free number.',
			'Record a reading; it is timestamped and added to the chart.',
			'Change the scope to look back over a day, a week, a month or a year.'
		],
		related => [ 'budget', 'travel', 'evaluation' ]
	},
	'travel' => {
		title => 'Travel', category => 'apps', app => 'travel',
		templates => [ 'templates/travel/travel.html.ep', 'public/js/manager/travel.js', 'public/js/manager/mapengine.js', 'public/js/manager/mapmarkers.js', 'public/js/manager/continentprinter.js' ],
		controls => [ 'Configure', 'Now', 'Delete', 'Guess the gaps' ],
		verified => '2026-10-16',
		summary => 'A pannable map of every map you have measured, with your history on it.',
		body => [
			'Travel logs where you have been and turns it into history: routes, distance covered, and speed. It draws on the fixes the phone feeds in as well as anything logged by hand, and lays them on a map.',
			'The map is a canvas you drag to pan, and zoom with a wheel or a pinch. On it sit the measured maps you have stored — each one an image georeferenced when you measured it (a home plate plus a scale bar), so it lands at its true place on the globe. Pan toward another area and whichever of your maps covers it scrolls into view: that is how you move among the maps you have rather than looking at one at a time, and where two maps overlap the finer one lies on top.',
			'The configuration row is pinned to the top of the window: scroll the view down and the Home Plate and Update buttons, the map picker and the Start/End times stay in reach. The gear tucks the row away.',
			'Above the measured maps you can lay a tile basemap from the Map picker: OpenStreetMap, OpenTopoMap, Carto, Esri imagery, a county GIS such as Lambton, or a Custom URL. Leave it on None and nothing is fetched — the measured maps are all it needs, so it works offline.',
			'The first four services are built in and need no key — just pick one. For a county or city service (Lambton GIS, and the like) or anything else, paste the service\'s tile URL into the box next to the picker. A service that speaks {z}/{x}/{y} works; an ArcGIS service is usually …/MapServer/tile/{z}/{y}/{x} (note y before x). Where to find it: the publisher lists its map services under a REST directory (for a county, look for an "ArcGIS REST Services" or "GIS Data" page); open the layer, and the Tile link or the URL under the map is the template to copy. Google Maps and Apple Maps have no keyless tile URL — they need their own SDK — so use another service, or paste a keyed URL you already hold.',
			'Drag to move the map; a flick glides on and eases out, a mouse wheel or a pinch zooms (a trackpad\'s two-finger scroll zooms too), and a double-tap zooms in. The red marker is the machine\'s current position (the same point navigation keeps fresh); the smaller labelled dots are the places the continent knows — tap one to open that app\'s appointment window, and where several share a spot the dot wears their count and a tap unfolds the list.',
			'To set a map up: upload the picture, set its function to map on the appointment, and the measuring tools appear under it — Scale (click the two ends of the scale bar, with its legend typed in) and Location (the home plate). Read legend lifts the scale number off the picture with OCR; Ask vision sends the picture to your Vision model (Configure → Plat) and comes back with the scale bar placed, the legend read (turned into metres), and a tilt. The Tilt box turns the picture straight — with a live preview — if its screenshot was taken rotated, so it lands level on the map.',
			'The empty ground between measured maps can be guessed: switch the hat (Guess the gaps) on and, as you pan, the blank ground on screen is filled by the Plat Image-generation model (Configure → Plat → Image generation). It takes the largest blank in view and stretches it 40% into the empty ground around it, stopping wherever a map begins — so the guess fills the space the maps leave and never lies under ground you already have, and ground once guessed stays guessed (the same gap is never generated twice). The Vision model reads the parts of every neighbouring map that fall around the blank first, and the picture is prompted to continue them conservatively: no invented bends, junctions or landmarks. The picture is kept sealed under the photo location\'s me folder — where the mugshot lives — and drawn dashed, under every measured map; it is not one of the picker\'s maps. Switch the hat off and the blanks stay blank; the status line beside the hat names the last guess, and a tap on it twice (as the trash buttons work) deletes it, leaving that gap blank for a fresh guess.',
			'The continent desktop background draws the same map, with the current timeframe\'s appointments and every home plate on it; the header and the clothesline rail ride over it. Home plates sharing a spot collapse into one marker wearing their count — tap it and the list unfolds, and a tap on a name opens that app\'s appointment window; a tap on an appointment\'s dot opens its window too. Its now button (or a double-click on the background) centres it back on you.'
		],
		steps => [
			'Open Travel. The view frames your maps and your current position.',
			'Drag to pan; scroll or pinch to zoom, and double-tap to zoom in. Your maps scroll into view as you go.',
			'Pick a built-in Map source (OpenStreetMap, OpenTopoMap, Carto, Esri), or paste a tile URL for Lambton or Custom — see where to find one in the words above.',
			'Use the map selector to bring a measured map into view and the trash to delete one; Search and the Start/End times scope the history shown. The toolbar stays pinned as you scroll.',
			'Set Home Plate to mark the place your maps share as their reference.',
			'To fill the blanks, switch the hat on: the empty ground you are looking at is guessed and drawn under the measured maps, so it never covers known ground. Switch it off to leave the blanks blank; the status line beside the hat names the last guess and deletes it on a second tap, and a right-click on any guess on the map offers to delete it too.',
			'On the continent background, tap an appointment dot or a home plate to open its appointment window; a numbered marker unfolds the places sharing that spot.'
		],
		related => [ 'measures', 'relational', 'navigation' ]
	},
	'relational' => {
		title => 'Contacts', category => 'apps', app => 'relational',
		summary => 'People, and the relationships between them.',
		body => [
			'Contacts is the relational app: it stores people and the measured, named relationships between them — friend, family, colleague — with a measures panel for each connection.'
		],
		steps => [
			'Open Contacts and add a person.',
			'Record the people they connect to, and what the relationship is.',
			'Use the measures panel to track how a connection is going over time.'
		],
		related => [ 'mailbox', 'travel' ]
	},
	'cards' => {
		title => 'Cards', category => 'apps', app => 'cards',
		verified => '2026-10-14',
		summary => 'A deck of cards, drawn from your own data.',
		body => [
			'Cards is a card deck — part game, part lens. It deals from your own appointments and measures, so a draw is a small reflection rather than a random flip.'
		],
		related => [ 'twirl', 'measures' ]
	},
	'twirl' => {
		title => 'Twirl', category => 'apps', app => 'twirl',
		summary => 'A small, playful reflective toy.',
		body => [
			'Twirl is one of the softer corners of the catalogue: a small interactive toy that lives in a window and asks nothing of you.'
		],
		related => [ 'cards' ]
	},
	'budget' => {
		title => 'Budget', category => 'apps', app => 'budget',
		verified => '2026-10-18',
		summary => 'Statement, budgets, a document ledger and a daily sheet.',
		body => [
			'Budget turns your transaction history into something you can look at: a statement of what has moved, budgets to hold it against, a document ledger of invoices and quotes, and a daily sheet.',
			'The statement is drawn per account; a transaction with no account attached will not appear on it, so transactions are recorded with a real account. The window and its scope (hour, day, week, month, year) come from the app\'s own settings, so a view you set up is the view you come back to.',
			'Each app that keeps a budget has a budget light in its header. Opening it shows the period against its budget, the pace it is on, and — when what is counted is over the budget — a Recommended button. Pressing it sets the budget to the app\'s own typical period, keeping the budget\'s scope, measure and floor or ceiling, and fills the matching row on the app\'s card in Configure. The light also lists the budget and the app\'s typical amount at the budget\'s own scope and the next two larger ones — a per-hour budget reads as an hour, a day and a week, with no meaningless per-minute figure. While a scope is still running, the budget-vs-typical and this-vs-budget rows are read against the share of the scope that has elapsed, so an early morning is not read as a fall. The light reopens with its app if it was left open when the window was closed.'
		],
		steps => [
			'Open Budget; it lands on the statement for the current scope.',
			'Change the scope along the top to widen or narrow the window — hour, day, week, month, year.',
			'Add or edit budgets so the statement has something to hold the movement against; a budget that is over its typical amount offers a Recommended value in its budget light.',
			'Switch the display to the document ledger to see invoices and quotes with their balances, or to the daily sheet for a day at a glance.',
			'The display and scope are remembered, so the view you settle on is there next time.'
		],
		prompt => 'The reader wants help setting up a Budget view that makes sense for them. Help them decide on a scope and a display, and explain what each display is for, step by step. Never invent numbers — talk about how to read and arrange the view, not about their actual figures.',
		related => [ 'store', 'warehouse', 'invoices_payments' ]
	},
	'store' => {
		title => 'Store', category => 'apps', app => 'store',
		summary => 'Items, models, options, quotes and invoices.',
		body => [
			'Store is the catalogue and the paperwork. Items carry models and options, each with its own prices; a quote or invoice is built from them and prints to a white, house-styled sheet that can be delivered by email.',
			'Recording a payment against a document updates its balance and closes it when the balance reaches zero.'
		],
		steps => [
			'Open Store and add the items you sell, each with its models and options and their prices.',
			'Build a quote from those items and options; the totals are worked out as you go.',
			'When the quote is accepted, move it to an invoice — it converts and the quote is consumed.',
			'Email the invoice to the customer, or print it to the house-styled sheet.',
			'Record a payment against it; the balance falls and it closes at zero.'
		],
		related => [ 'budget', 'invoices_payments', 'market' ]
	},
	'warehouse' => {
		title => 'Warehouse', category => 'apps', app => 'warehouse',
		summary => 'Money and goods tracked per place.',
		body => [
			'Warehouse tracks stock per place: what is where and how much of it. Packaging carries real quantities (a carton of twelve, a box of nails by weight), and shelf life means expired stock is swept up on its own.',
			'Every stock movement is journalled with its reason, and a moves ledger folds stock and money into one signed list.'
		],
		steps => [
			'Open Warehouse and set up the places you keep stock in.',
			'Add your products; where a product ships in packaging, give the packaging its real quantity.',
			'Move stock in and out — each move is journalled with its reason.',
			'Read the moves ledger to see goods and money together.'
		],
		related => [ 'inventory', 'market', 'moves_ledger' ]
	},
	'market' => {
		'Market', category => 'apps', app => 'market',
		'verified' => '2026-10-17',
		templates => [ 'templates/market/market.html.ep', 'public/js/manager/market.js' ],
		summary => 'The shopping list and the shopping run.',
		body => [
			'Market is where what you need to buy gathers. A Lists dropdown groups what to buy by kind, prepopulated with the house\'s categories (Clothes, Food, Household, Tech, and the rest) and opening the list you were last on; a Vendors dropdown scopes to a shop. The Shopping List tab holds what to buy, each row carrying a need/want dial, and Enter adds an item; the Shopping tab reads the same list through a Needs, Wants or All filter.',
			'An item the warehouse says is due - one whose own quantity budget (keep 6 on hand) sits below its target - is upgraded to a need on its own, so the shopping run already knows what is short.',
			'While you shop, tick an item off and drop it in the cart; Checkout retires the cart from the list and opens the list\'s category with an expense transaction filled line by line from the cart - quantity, unit and amounts are all editable there, and pressing Save is what records the purchases (each on the item\'s own app, and its stock move). The + beside Unit names a new packaging on the spot (a loaf, a bag of six) and offers it here and next time. Cancel just empties the cart back onto the list.',
			'Scan reads a barcode - the app\'s own bridge on a phone, else the camera, else a typed code. A code never seen before is looked up once and named in our terms by the model (a house item name, a category we keep, a unit), then remembered, so the same product is instant next time.',
			'Scan remembers the device it last used and starts there, so a phone chosen once is the default next time. That device opens its own scanner (the phone\'s Google code scanner) as if it had pressed Scan; each read comes back to the machine that started the run, and the scanner re-opens for the next one. On a computer with a webcam the machine reads with zbar straight from the camera instead - hold an item up and it appears on the scanning page in real time. The reads collect on the scanning page: Done puts them on the list, Cancel throws them away, and either one puts the phone\'s scan sheet away. The phone\'s Back button cancels too. The device picker stays on the scanning page, so another input can join the run (a phone beside the webcam) and each input has an x to stop just it. A browser without that scanner gets a live camera view instead, and a machine with no camera can type the code in the app.',
			'An account is an app whose part of speech is account (a Visa, a debit card, Cash). Its Configure panel carries a Payment type (cash, debit, credit, visa, mastercard, amex, interac, crypto, cheque, gift, other); a receipt whose tender says mastercard is matched to the account with that type, and the confirm lets you correct the pick. When no account names the word exactly, its family decides if that family has only one account: a receipt saying credit finds the only credit card (a mastercard, say), and debit or interac finds the only debit one.',
			'Receipt reads a whole shopping run at once, for the shop you did not scan at the till. The Receipt button offers the scanner (the ADF feeds the long receipt in one pass) or a photo - the scanner buttons appear only on a machine that has one; while the feeder runs the panel shows the scanner\'s own line and each page as it arrives, Cancel stops it, and a run that produces nothing says why (no paper, device busy). The vision model reads the pages into lines, and the confirm shows the receipt page full size beside them with the date, total, paid-by, reference and account editable, so they can be checked against the paper; each line is named in our terms and marked when it is already on the list. Add to cart links them into the list in the cart, so Checkout still writes the purchases, and the receipt itself - with its date, total and tender - is kept with the Market app.',
			'Receipts reopens what was kept. Once a receipt has been read, the Receipts button lists them newest first, each with its date, total and page thumbnails (press a page to open it); Add to list puts that receipt\'s lines back on the list in one press, the same way a fresh read does.',
			'Where you are decides which lists apply. A list remembers the vendors it is shopped at, and a vendor has a home plate; when Market opens at a place, the applicable lists appear as Here: - a supermarket shows the grocery list, a big-box store several at once.'
		],
		steps => [
			'Open Market from the start menu.',
			'Pick a list and a vendor to scope both tabs; both are kept on what you add.',
			'Type an item and press Enter to add it; set its dial to need or want.',
			'Switch to the Shopping tab and filter the run to needs, wants or all.',
			'At a shop, tap a Here: list to open on it.',
		'On a computer, press Scan and pick a phone (or This machine); each read comes back here, and Done puts the run on the list while Cancel (or the phone\'s Back) throws it away.',
			'Set an account\'s Payment type once in its Configure panel, so a receipt\'s tender finds that account.',
			'After a shop, press Receipt and scan the whole receipt in the ADF, then Add to cart and Checkout.',
			'In the confirm, check the date, paid-by and account against the page (fix them if the read is off), tick the lines, then Add to cart.',
			'After Checkout, the list\'s category opens with the expense transaction filled in - set each line\'s quantity and packaging, check the amounts, then press Save; that is when the purchase and its stock move are written.',
			'When a line needs a packaging the house does not know, press + beside Unit, name it, and say how many each it holds.',
			'Press Receipts to reopen a kept receipt: its pages open, and Add to list puts its lines back on the list.'
		],
		related => [ 'warehouse', 'store' ]
	},
	'inventory' => {
		title => 'Inventory', category => 'apps', app => 'inventory',
		verified => '2026-10-16',
		summary => 'An app\'s own record of what it holds and has been up to.',
		body => [
			'Inventory is the shared surface behind the apps: it holds the entries an app has recorded — a measure, a document, a report — and shows them together, with statistics and the Evaluation reports.'
		],
		related => [ 'evaluation', 'measures', 'warehouse' ]
	},
	'chat' => {
		title => 'Chat', category => 'apps', app => 'chat',
		templates => [ 'templates/apps/chat.html.ep', 'templates/mail/mailbox.html.ep', 'templates/mail/conversation.html.ep', 'templates/mail/message.html.ep', 'public/js/manager/chat.js' ],
		verified => '2026-10-16',
		summary => 'The house\'s conversations: sms, the dial, ticket threads and lora.',
		body => [
			'Chat gathers the ways the house talks, split out of the mailbox as an app of its own: sms to phones, the dial (the house\'s radio, where a set of appointments picked across the six groups names one thread and a tab only hears messages addressed to the set it is tuned to), the list of those sets, the ticket threads the house opens for its guests, and lora.',
			'Friends is one row per person the house knows, carrying every road they can be reached on: their name joins to a ticket when one is open for them, and their number is the thread until then. A person who keeps more than one line (a home number, a work number - set under Configure, in the app\'s Phones tile) shows them under their name, and the transport dropdown offers sms once per number, so the next text can go to the work line rather than the mobile.',
			'A letter is filed only when its sender is trusted: a citizen\'s or resident\'s words are stored and synced, while a guest\'s are heard live by whoever is tuned in and never written down - except on the guest\'s own ticket thread, the one conversation the house opened for them.',
			'A paperclip beside the composer attaches files to the next message; they ride the message on the ticket road and go as an MMS on the phone road.',
			'Advertise opens the tuned set to guests, who may then tune the same channel from the public page. Room bubbles that are not kept are dashed to say so.',
			'An appointment\'s Connect group carries a Chat button: it opens that person\'s one conversation right in the window - the ticket thread when they hold a ticket, the phone otherwise - and the window keeps their name and colour on the way. A back button beside the menu puts the appointment back, and closing the window closes the chat.'
		],
		steps => [
			'Open Chat from the start menu.',
			'Pick a section from the sidebar - sms, dial, list, tickets or lora.',
			'Friends: tap a person to open their one conversation, and the transport dropdown picks how the next message travels (a person with several lines gets one sms option each).',
			'Sms: tap a number, then write in the box below the conversation.',
			'Dial: pick a set, then press Advertise to open it to guests.',
			'List: add and configure the sets the dial picks from.',
			'From an appointment, press Connect then Chat to open that person\'s conversation in the window.'
		],
		related => [ 'mailbox', 'phone', 'email' ]
	},
	'pen' => {
		title => 'Pen', category => 'apps', app => 'pen',
		templates => [ 'templates/apps/pen.html.ep', 'templates/mail/pen_sections.html.ep', 'templates/mail/conversation.html.ep', 'templates/mail/message.html.ep', 'public/js/manager/pen.js' ],
		verified => '2026-10-16',
		summary => 'The assistant conversations, each with its own model and voice.',
		body => [
			'Pen is the house\'s assistant, split out of the mailbox as an app of its own: a row of conversations, each a picked model with its own name and system message, and one thread of letters per conversation.',
			'Tick a conversation to read and write on it; the newest row (no tick) is a new one waiting for its name. The trash arms first, so a slip does not throw a conversation away.',
			'Model choices and provider keys live under Configure → Plat, so every assistant is set in one place - a conversation without a model of its own uses the one picked there.'
		],
		steps => [
			'Open Pen from the start menu.',
			'Pick a conversation, or name the new one and choose its model.',
			'Write in the box below the conversation and send; the reply lands on the same thread.'
		],
		related => [ 'mailbox', 'configure', 'assistant' ]
	},
	'email' => {
		title => 'Email', category => 'apps', app => 'email',
		templates => [ 'templates/apps/email.html.ep', 'templates/mail/email_rail.html.ep', 'templates/mail/email_folder.html.ep', 'templates/mail/email_rows.html.ep', 'templates/mail/email_compose.html.ep', 'templates/mail/email_configure.html.ep', 'templates/mail/conversation.html.ep', 'templates/mail/message.html.ep', 'public/js/manager/email.js' ],
		verified => '2026-10-16',
		summary => 'A mail client: folders, a paged and searchable list, and the letter or the draft in the pane.',
		body => [
			'Email is the mailbox\'s mail half as an app of its own: it speaks IMAP and SMTP directly, so mail arrives on the desktop, and a new message raises the dot in the start menu.',
			'The window is laid out like a mail client. The folders - inbox, starred, drafts, sent, outbox, archive, trash and contacts - sit down the left, each carrying a count (unread for Inbox and Starred, the total for Drafts and Trash), under the address the list is showing. The chosen folder\'s messages fill the pane beside them, a page of fifty at a time; scroll to the foot and the next page loads. Letters that answer one another are one thread - followed by their message headers, so a reply stays in its thread even when the subject changes: the list shows the thread once, newest first, with a count of how many letters it holds. Each row is the time, the other party, and the subject with a line of the message under it; an unread inbox row is bold and a star marks a flagged one.',
			'The Search box in the toolbar searches the words themselves - the sender and every other party, the Cc and Bcc, the subject and the body - so it finds a letter by what was said in it, not just by its subject. Refresh rereads the folder, and Mark read clears the folder\'s unread marks in one press. The list can be ordered by date, sender or subject, ascending or descending, and the choice is remembered; a descending list opens at its foot and loads more above it as you scroll up.',
			'Tick a letter (or Select all) and the bulk bar appears: move the ticked letters to a folder from its list, mark them read or unread, or delete them to Trash in one go. Folders can be made from the rail - + New folder - and a letter or a whole selection can simply be dragged onto one to file it there; a folder you made carries a small x to remove it, which returns its mail to the inbox.',
			'Click a thread and it opens in the pane over the list: every letter in the exchange, each with its Device, From, To, Cc, Date, attachments and body, and its own Reply, Reply all, Forward, Star, Unread and Move - a menu of folders (Inbox, Archive, Drafts, Sent, Trash) - and Delete. A reply fills in the other party and a forward leaves the To empty; both wear Re: or Fwd: on the subject and quote the letter they answer, and Reply all carries the original Cc. An attachment is a link: press it to open the file, or download it. A letter from someone the house does not know carries a New sender button - press it to make them an appointment, and the attachments the letter brought, waiting in the unclaimed pool, are filed there. Until then those attachments are not links but buttons: this sender is new, so nothing is handed over until you press Download. Back returns to the list.',,,
			'Delete is a move to Trash, not a loss: the row leaves the folder and a note offers Undo for a few seconds. In Trash a message can be Restored to the inbox or, pressing Delete again, removed for good; Empty Trash, at the foot of the rail, clears it out.',
			'Compose, in the toolbar, opens the same pane as a blank message: From, To, Cc, Bcc, Subject, an Add for attachments, and the body. Send sends the letter at once over the account\'s own SMTP server - it is not queued; the background email sender utility is kept for lists. A send that fails leaves the letter in Drafts to retry by hand. Sending files the mail onto the recipient\'s app and seals its attachments, so a document you emailed is still findable from the thing it belongs to. A letter from someone the house does not know is kept too: its attachments wait in the unclaimed pool for a month, to be claimed onto an appointment (or filed by the New sender button) before they expire. The gear opens the server settings, the attachment-scanning options (which follow to the machine that receives the mail, where clamd answers on demand and stops itself when idle) and the saved templates. An account can be set to OAuth2 there (Outlook and Gmail no longer accept a plain password): register the app once under Configure &rarr; Plat &rarr; OAuth2 (Add client &mdash; for Microsoft turn on Allow public client flows, and Google needs the secret), pick that client on the account, and press Connect - a short code and a web address appear, and approving them there lets the house read and send that mail.'
		],
		steps => [
			'Open Email from the start menu: the folders are down the left, the inbox beside them.',
			'Scroll the list to load more, type in Search to find a letter by its words, or pick a folder - or, under Contacts, an address.',
			'Order the list by date, sender or subject with the toolbar controls and flip the arrow for ascending or descending; a descending list starts at its foot.',
			'Tick letters (or Select all) to move, mark or delete them together, or drag a letter or selection onto a folder; press + New folder in the rail to make one.',
			'Click a thread to read it; Reply, Reply all or Forward opens a draft in the same pane, and Star, Unread or Archive flags it - Back returns to the list.',
			'Delete a letter to move it to Trash, then press Undo in the note to put it back - or open Trash to Restore it or Empty Trash for good.',
			'Press Mark read in the toolbar to clear a folder\'s unread marks at once.',
			'Press Compose to write a new one, adding Cc or Bcc and attachments with Add, then press Send.',
			'The gear sets up the server and the templates.'
		],
		related => [ 'mailbox', 'sealing_files' ]
	},
	'mailbox' => {
		title => 'Mailbox', category => 'apps', app => 'mailbox',
		templates => [ 'templates/mail/mailbox.html.ep', 'templates/mail/conversation.html.ep', 'templates/mail/message.html.ep', 'public/js/mailbox.js' ],
		verified => '2026-10-16',
		summary => 'The whole mailbox in one window — email, sms, lora, the dial, the list, ticket threads and the pen.',
		body => [
			'Mailbox speaks IMAP and SMTP directly. Mail arrives on the desktop rather than in a separate client: a new message raises the mailbox dot in the start menu and, if no mailbox is watching, a notification.',
			'Sent mail is filed back onto the recipient\'s app, and its attachments are filed and sealed, so a document you emailed is still findable from the thing it belongs to. Alongside email it carries SMS, the internal message and paper-route system, and the Pen assistant — each of those sections also opens as an app of its own now, while the umbrella still carries them all.',
			'The dial is the house\'s radio: a set of appointments picked across the six groups names one thread, and a tab only hears messages addressed to the set it is tuned to. Advertise opens the tuned set to guests, who may then tune the same channel from the mailbox on the public page.',
			'A paperclip beside the composer attaches files to the next message; they ride the message on the ticket road and go as an MMS on the phone road.',
			'A letter is filed only when its sender is trusted: a citizen\'s or resident\'s words are stored and synced, while a guest\'s are heard live by whoever is tuned in and never written down — except on the guest\'s own ticket thread, the one conversation the house opened for them. Room bubbles that are not kept are dashed to say so.'
		],
		steps => [
			'Open Mailbox and choose a section from the sidebar — sms, email, lora, list, dial, pen or tickets.',
			'For email, pick a folder (contacts, inbox, drafts, outbox, sent) and an address.',
			'Compose with the new-file button; attachments are filed and sealed when you send.',
			'On the dial, pick a set and press Advertise to open it to guests; press Advertised to close it again.',
			'As a guest on the public page, open Mailbox, tune an advertised set from the Dial section, and write; the house\'s replies stay, and so does the ticket thread — your words in the rooms are only heard.'
		],
		related => [ 'relational', 'store', 'sealing_files', 'assistant' ]
	},
	'process_monitor' => {
		title => 'Process Monitor', category => 'apps', app => 'process_monitor',
		templates => [ 'templates/monitor/monitor.html.ep', 'public/js/manager/monitor.js' ],
		verified => '2026-10-18',
		summary => 'Live CPU, memory and battery health, per-core graphs and a process list.',
		body => [
			'Process Monitor is the system\'s own dashboard: live CPU and memory readings, per-core graphs and a sortable process list. It is how you see what JawnOS — and everything else on the machine — is actually doing.',
			'The health strip along the top says how many processes jawn is running (including the master), the machine\'s load average and uptime, how many sync jobs are running and how many peers are linked, and the database and write-ahead-log sizes. On a machine with a battery it also shows charge, charging state, temperature, voltage, current and battery health. PPH is the battery\'s percent-per-hour draw, measured as a least-squares slope over the discharging samples in the last hour; on a desktop, where every process is visible, it is scaled by jawn\'s share of the CPU so it reads as jawn\'s own rate, while a phone hides other apps and therefore shows the device rate. Hover the strip for the measurement window and the last sync job\'s note.'
		],
		steps => [
			'Open Process Monitor.',
			'Read the health strip for jawn\'s process count, load, sync, the battery\'s temperature and voltage, and PPH (jawn\'s percent-per-hour draw).',
			'Read the headline CPU and memory figures under it.',
			'Sort the process list by CPU or memory to find what is busy.'
		],
		related => [ 'configure', 'terminal' ]
	},
	'configure' => {
		title => 'Configure', category => 'apps', app => 'configure',
		verified => '2026-10-19',
		summary => 'Settings: the look, the devices, the utilities and the mesh.',
		body => [
			'Configure is where the desktop is made yours. Appearance (colour schemes, texture, icon set, zoom, bar heights and the window border), the device lister, the utility controller and the remote-machine and mesh settings all live here.',
			'The Dev panel lists the devices by the network they are on: a section per network, named by its subnet, with the machines and interfaces that reach it and a table of the devices found there. Scan sweeps the local network first, so a device nobody has talked to yet - a printer, a fresh appliance - still appears and can be given its purpose.',
			'The Dev panel carries the mesh switch too. Sync topology sets how this house talks to itself: Auto keeps the hub in charge while the server is live and falls back to a full mesh when it is not, Mesh makes every peer dial every other peer, and Hub only makes the spokes dial the server. The choice is a house setting - every machine picks it up on its next sync - and Auto still lets machines on the same network talk directly.',
			'A device that is off its network but bridged over Bluetooth is listed too, in a Bluetooth card below the machines: its name, purpose, radio address and when the bridge last heard it, so the fleet\'s radios are visible even when they are on no network of yours. The card\'s Scan now button asks the bridge to look for a JawnOS radio immediately; adoption otherwise happens on its own every 30 seconds. A machine with no screen of its own - a headless server - lists the devices it can see the same way, with no browser involved.',
			'A machine reached over a tunnel is enrolled on its own: the hub asks the peer its name and its backups, so the row shows the peer and its saved jawnos.enc (shown by its file name, not the whole path) and carries its buttons, with no Scan or Connect press. That is what lets a headless hub upgrade or relay to a tunnelled peer without a browser.',
			'A device names itself as it joins. A watch, deck or pico advertises what it is - its purpose, model and abilities (screen, keyboard, mic, gps, pins and the like) - over mDNS, and a printer is recognised the same way, so a new device appears in the list with its purpose and its abilities within seconds, without pressing Scan. A device with no network of its own - a fresh deck that has never joined one - is met over Bluetooth instead: the house scans for it and connects the moment it names itself, so it appears without an access point at all.',
			'A linked machine has a Migrate button: it asks that machine to pull the whole house from this one. Connect a device with no key first - the house key seeds its vault - then press Migrate and watch its line move from building to downloading to merging. The pull is resumable, so a dropped connection picks up where it stopped instead of starting the whole snapshot again.',
			'A printer in the list reads out its own ink and toner: a bar per cartridge (a tri-colour cartridge draws as one band), with the printer\'s state under it - idle, or what it is asking for, such as paper. The reading comes from the printer itself over IPP; click it to ask again after changing a cartridge.',
			'The Misc panel holds the routine settings, and its Speech section sets which voice the desktop speaks with — the neural Piper voices (LJSpeech, LibriTTS-R, Alba, John, Jonathan) or an eSpeak fallback, each chosen per device. Texture, in Appearance, dresses the clothesline, the coloured marks the canvas printers draw (the timeline bands and dots, the leaderboard rows, the clockface and calendar dots, and the narrator ticks), every button and hinted image across the program, the taskbar and the dock, and every other surface - the desktop, window frames and their app contents, window title bars, the start menu, configured panels, menus and dialogs, form fields, tables and cards - in plain, round, sandglass, glass, paper, fabric, wood or metal: plain is the clothesline as it looked before the pills and materials (a solid rounded tile with its name printed plainly), round is a solid rounded pill, and the rest are panes of glass, paper, fabric, wood or metal with the app\'s colour breathing through them. The material layers over the control\'s own colour, so an active green or a destroy red keeps its meaning underneath. Encryption Standard picks the cipher new notes and files are sealed with: the AES, Camellia, 3DES and SM4 families run in-process, the rest through openssl, and the list offers only the standards this machine can actually seal and open. Anything openssl knows can still be read, so a note or file reads back under whichever standard wrote it and changing this never strands what is already stored.',
			'The App panel is one card per app. An app\'s abilities — measures, budgets, goals, notifications, packaging, a web table and the rest — sit as a grid of icon tiles under its name and colour; tap one to open its settings, and that tile opens out across the card. The icon set you pick under Misc gives every tile its look. Beside Colour, Dark Colour is the version of it worn while the desktop is dark — it starts as the same hue at a tone that reads on a dark panel, and can be picked separately. Theme picks a colour scheme for the app: while one of its start appointments is running the desktop wears it, the most recently started running app wins when several do, and Follow system returns the desktop to the Misc scheme.',
			'On an app card, Budget and Goals are lists of rows: an amount, a measure - occurrences (a count), money, quantity, duration or one of the app\'s own measures - a scope (none holds a fixed level, otherwise per hour, day, week, month or year) and whether it is a floor to reach or a ceiling to stay under. An amount carrying a time unit (11h, 90m, 2d) turns the measure to duration by itself, and a duration with no unit (90) is read as minutes.',
			'A person can keep more than one number or address: Phone and Email each hold the one line calls and mail route on, and the Phones and Emails tiles beside them list any others, each with a type — Mobile, Home, Work, or a Custom label. A call, a text or a letter from any of them still names the person, and contact sync fills the list rather than overwriting the line.',
			'Renaming an app into a name the house already knows opens the merge panel: for each setting the two records share, pick which value keeps the name, and a value nobody chose (marked <i>house default</i>) loses. Contacts either side holds are carried over unless you drop them, and window state — where the window was left, how big it was — is never asked about. Phone and email, like nfc and measures, keep both sides.',
			'Renaming into a known name also shows a compact history summary for both sides — sessions, date range, typical length, timing, data-quality flags and any expired warranty — and asks what to do with the appointments: keep both, remove exact duplicates, merge duplicates (with the proposed drops listed), flag the candidates, or keep only one side. The history choice is separate from the settings choice; a policy that drops rows takes a backup first and tombstones them under the new name, so every machine agrees.',
			'Notifications, on a card, sets what an app says and sounds like: a sound and a line of text for the default, for a start, for a stop and for a budget. The sounds are the ones in the house (Ring, Chime, Sonar, Pulse, Crystal, Ding, Rattle), and (default) leaves the choice to the house. Add your own sound takes an audio file from your device and files it with the rest, so it appears in every app\'s list from then on.'
		],
		steps => [
			'Open Configure.',
			'Use the tabs to move between appearance, devices, utilities and the mesh.',
			'The Plat tab has two pages: AI, which holds every AI model choice and provider key, and OAuth2, where an app registration (a client id, secret and tenant) is added once with Add client and shared by any number of mail accounts. The other tabs hold the rest of the house\'s settings.',
			'For speech, pick a Say voice under Misc and press Preview to hear it.',
			'To give an app a ringtone, open its card on the App panel, tap Notifications, and pick a sound — or add your own sound from there.',
			'To see how much ink or toner a printer has left, look at its row in the Dev panel; click the reading to refresh it.',
			'To move the house onto a new device, Connect it with the house key, then press Migrate on its row and watch the migration line.',
			'To add another number or address to a person, open their card, tap Phones or Emails, pick a type and press Add Phone (or Add Email).',
			'Changes save as you make them; a bar or theme change is felt at once.'
		],
		related => [ 'themes', 'icon_sets', 'devices_and_mesh', 'platform', 'assistant' ]
	},
	'security' => {
		title => 'Security', category => 'apps', app => 'security',
		templates => [ 'templates/security.html.ep', 'templates/padlock.html.ep', 'templates/padlock_key.html.ep', 'templates/layouts/padlock_key.html.ep', 'templates/locked.html.ep', 'templates/layouts/locked.html.ep', 'public/js/manager/security.js' ],
		verified => '2026-10-19',
		summary => 'Passwords, pseudonyms, screen lock, the gate and secrets.',
		body => [
			'Security gathers the safety tools: password and pseudonym generation, QR codes, encryption helpers, screen locking and a keyring-style secret store.',
			'The Padlock view sets the screen lock. There is no dial and no camera key: the only ways in are a paired phone or tablet, the paper recovery code, and - on the phone itself - an enrolled fingerprint. The padlock on the taskbar locks this screen with one tap and the whole house with a double tap (it appears while the gate is on and General is one of its contexts). When a screen locks, a phone or tablet already running the manager opens the unlock page and waits: press Unlock and confirm with your fingerprint when the phone supports it, and it signs a one-time challenge for that screen. In the Android app the fingerprint prompt is the phone\'s own; a browser uses WebAuthn when it can. The phone can also unlock the screen it is locked on: enroll its fingerprint under Security while the screen is open, then press Use this phone\'s fingerprint on the locked screen. If a fingerprint is already enrolled, confirm it before replacing it with a new one. The app keeps an EC key in Android Keystore that the OS will not use until the fingerprint passes, and the house verifies that key\'s signature, so this is a real factor and not a browser promise; it opens only that phone\'s own screen. A phone with no enrolled fingerprint can still be unlocked by another paired device or the paper code; enrollment is refused while the screen is locked, so set it up before locking. If the whole house is locked, open the screen you are at and press Send the unlock page to my phone; unlocking that screen sets only its own timer and the other screens stay locked. If several screens are locked, the page lists them. On a machine with an enrolled fingerprint reader, the locked page also offers Use this computer\'s fingerprint. After fifteen seconds the lock shows a screensaver; moving the mouse or pressing a key brings the lock back. A phone that slept through the lock catches up on its next connection. A phone that is talking to a different machine in the house still unlocks you: the signed open is relayed over the peer rail to the machine that holds the lock. The phone shows Unlocking... and then Unlocked., and the locked screen follows within a couple of seconds.',
			'Gate decides what the lock does to the server. The gate starts on in Enforce once the house has a way back in - a paper recovery code or an already-paired phone - so a fresh house is never locked out before it has one. Shadow writes each request it would refuse to the log and still answers, so the list can be checked on a live machine; Enforce refuses every manager request behind the padlock except the ways in - the phone\'s signature, the unlock page, and the paper recovery code. Use Shadow to check the list on a live machine. Turn the gate on makes the lock exist; Turn the gate off removes it, and stays off across restarts. The gate only acts when General is one of the padlock\'s contexts; the others are per-app. Phone unlock page opens the unlock page on this machine.',
			'It also shows the neighbour links — which machines are trusted, and with what privilege.',
			'The Devices view lists the browsers and phones paired to the house. A citizen session pairs its device once; from then on the device logs itself back in with its own key, with no ticket or password. Revoke a device here and its sessions die — it must be paired again. A new device can also ask to pair from the gate: its request waits at the top of this view with a short code, and Approve lets it in — but only when that code matches the one on the new device\'s screen.',
			'The Recovery view holds the paper code that gets you back in when every ticket is lost and no paired device is at hand: make one and write it down. It is shown once and keeps working through password changes — only rotating the house key replaces it; enter it under Recovery Code at the gate and that device is paired on the spot. The house key itself works too: typed at the gate it opens the house in any vault state - a machine whose vault is gone heals it on the spot - so one long string written down is a complete backup.',
			'The Recovery view also carries the sharing tick: while it is on, a linked machine that has lost its key can fetch the house key from here - the request must carry the machine\'s pinned signature, and the key is sealed to a one-time secret for the trip.',
			'Under Rotation, the house key can be replaced with a fresh random one: the database\'s sealed values are re-sealed in place, sessions start again (paired devices re-admit themselves), the recovery code is set aside - write down a new one - and the old key stays wrapped under the new one, so files and notes sealed before the rotation still open. The sealed files themselves then re-seal in the background through the queue, each one kept exactly until its new seal is written and checked, and every linked machine is handed the new key so it re-seals its own; one that was away catches up on its own.',
			'Under Old Seals, Upgrade Old Seals re-seals values left from long ago, when the outer layer was locked with a passphrase anybody could know: it runs here and asks every linked machine to do the same, and values already under the house key are left alone.'
		],
		related => [ 'box_office', 'devices_and_mesh', 'sealing_files' ]
	},
	'box_office' => {
		title => 'Box Office', category => 'apps', app => 'box_office',
		templates => [ 'templates/box_office.html.ep', 'public/js/manager/manager.js' ],
		verified => '2026-10-18',
		summary => 'Issue, suspend, renew and revoke tickets.',
		body => [
			'The Box Office manages tickets — the single-use links that log a visitor in. From here you issue a ticket, set its privilege, and suspend, renew, reinstate or delete it. The select in a ticket\'s row changes its privilege; the next time the link is opened the session wears the new chair.',
			'The Requests view holds what the public page asked for: each request shows its name, contact, description and whether the house already knows the contact. Approve mints the ticket (the waiting page lets itself in), Decline forgets it, Blacklist remembers the identifiers so the door refuses them before a request is ever queued.',
			'Issue guest tickets on request keeps the door open: a request is minted a guest ticket on the spot at the guest warranty. Leave it unticked and requests queue for approval instead.',
			'A blacklisted ticket is the deny: its holder is shown the denial page and that browser is then locked out of the house — public pages included — with no redirect.',
			'The tickets view also carries Blocked numbers: a number typed there — or added by the Phone app\'s Block button on a recent call — is turned away before it can ring, and the same list keeps that number (or a request from the same email) out at the door. Removing a number from the list lets it ring again.'
		],
		steps => [
			'Open the Box Office.',
			'Issue a new ticket and choose its privilege — citizen, resident, guest or blacklisted.',
			'Copy the link and give it to whoever needs it.',
			'Suspend, renew or delete a ticket from the same list when it is no longer wanted.',
			'Change a ticket\'s privilege from the select in its row; the next login wears it.',
			'Open the Requests view to approve, decline or blacklist what the public page asked for.',
			'Block a nuisance number under Blocked numbers — or from the Phone app\'s Recents — and remove it there when it is welcome again.'
		],
		related => [ 'tickets', 'security', 'phone' ]
	},
	'handbook' => {
		title => 'Handbook', category => 'apps', app => 'handbook',
		templates => [ 'templates/handbook/handbook.html.ep' ],
		summary => 'Chaptered notes about the system itself.',
		body => [
			'Handbook is the reference shelf: chaptered pages about how JawnOS works, with diagrams. It is the longer-form cousin of this Help app.'
		],
		related => [ 'help_app' ]
	},
	'embedded' => {
		title => 'Embedded', category => 'apps', app => 'embedded',
		templates => [ 'templates/embedded/embedded.html.ep', 'templates/embedded/component.html.ep' ],
		verified => '2026-10-17',
		summary => 'The device fleet, from the desktop.',
		body => [
			'Embedded is the fleet view: it lists the JawnOS devices on your network, their purposes and models, and lets you query one, send a room to a watch, deck or board, and set how a device behaves.',
			'A watch or board that is off its network but bridged over Bluetooth still appears, and stays listed while the bridge holds it: its row reads Bluetooth in place of an address, its buttons are shown so they can be changed, and its Now Me and settings go out over that bridge. The bridge holds four radios by default, and a machine with a capable adapter can be set to hold more (up to 25), so a whole desk of watches, decks and boards can stay linked together.',
			'A board that crashed into its provisioning AP can be recovered without joining it: plug it in over USB and press Restore over USB on its row. The manager writes the stored WiFi and role into the board\'s config file, the board acknowledges and reboots, and it comes back with its switches and relays already set. A board on the Bluetooth bridge gets the same role as a compact board config, so it can resume before it has any network at all.',
			'Picking a device shows its controls: its name, Now Me (send it a fresh copy of its settings and screens) and Query (ask a board what it is). A watch or t-deck row also carries the Voice select, which chooses how the device listens (see Voice and wake words), and the Noise floor select, which sets how quiet the room has to go before a recorded command is taken to have ended. A watch or t-deck row carries its room count and screen timeout, and the Audio replies toggle, which decides whether the guide associate answers a spoken request out loud on the device or only on its screen.'
		],
		steps => [
			'Open Embedded to list the devices on your network.',
			'Choose a device from the chip list, then press Query to ask a board what it is.',
			'Set the room\'s buttons, then press Now Me to send that room to a watch or deck.',
			'On a watch or t-deck row, set the Voice select to choose what it listens for, then press Now Me to push the change.',
			'On a board row, plug the board in over USB and press Restore over USB to rewrite its stored WiFi and role, then let it reboot.',
			'Leave Noise floor on Auto; pin one of its numbers only if a noisy room keeps cutting a command short.'
		],
		related => [ 'watch', 'tdeck', 'pico', 'ble_bridge', 'voice' ]
	},

	# ------------------------------------------------------------ features
	'voice' => {
		title => 'Voice and wake words', category => 'features',
		templates => [ 'templates/embedded/embedded.html.ep', 'public/js/manager/embedded.js' ],
		verified => '2026-10-17',
		summary => 'Speak to the watch or t-deck; it listens for a phrase and files the rest.',
		body => [
			'A watch or a t-deck can listen for you and, when it hears speech (or its wake phrase), record a short clip and send it to JawnOS over Bluetooth or Wi-Fi. JawnOS transcribes the clip: a recognised command runs, and anything else is kept as a note you can sort out later.',
			'How the device listens is the Voice setting on its row in the Embedded panel. The watch offers four choices and the t-deck three: Voice: Off (it does not listen), Voice: Any speech (VAD) (it starts a clip as soon as it hears any speech), and a wake word - Voice: Hey Jawn, and on the watch also Voice: Jawn Do - which waits for that phrase and records what follows.',
			'The wake words are custom phrases trained for JawnOS rather than stock ones, so "Hey Jawn" (and, on the watch, "Jawn Do") are the phrases it knows; the any-speech setting is the fallback that needs no phrase at all. The t-deck does not carry Jawn Do.',
			'How quiet the room has to go before the device decides you have finished speaking is the Noise floor select on its row. Auto is the default and reads the room the device is standing in - a device hears a steady tone of its own, so the floor rides just above whatever it is hearing and lets go when you stop. The numbers 1200 to 3400 pin it by hand, for when a noisy room cuts a command short or a quiet one will not let go.',
			'A pause between the phrase and the command is fine - "Hey Jawn" ... "start email test" is one request - and a phrase with nothing after it is ignored rather than acted on: the device waits a couple of seconds for the command to start, then drops the clip, so a stray wake-up does not become a note or an answer.',
			'Listening does not stop when the screen sleeps: the microphone stays armed, and saying the wake phrase with the panel dark lights the screen and gives a short two-tone chime, so you know it heard you before you give the command. While a device is taking a clip it rings its screen with an orange border - the same mark the watch makes - and holds its screen awake, so a spoken command is not cut short by the screen dozing part-way through it. The screen stays on while the house thinks and while the answer is spoken, and only then does the idle timeout start again.',
			'What was said is also set to the Guide: when the Guide window is open, the message appears in its conversation and the Guide answers it there, as though it had been typed - the same answer comes back to the device.',
			'When the guide associate answers a spoken request, the reply lands on the device itself: the words appear on its screen, and the spoken answer plays over its speaker. The Audio replies button on the row in the Embedded panel turns the speech off, leaving the words on screen.'
		],
		steps => [
			'Open Embedded and find the watch or t-deck in the device list.',
			'Set the Voice select on its row to Voice: Off, Voice: Any speech (VAD), or a wake word - Voice: Hey Jawn, and on the watch Voice: Jawn Do.',
			'Leave Noise floor on its row on Auto unless a noisy room keeps cutting your command short.',
			'The choice is pushed to the device as a fresh Now Me, and it starts listening in that mode.',
			'Speak: a command runs, and anything else is saved as a note. Answers to requests the guide associate handles are shown and spoken on the device.'
		],
		related => [ 'watch', 'tdeck', 'embedded', 'notes', 'ble_bridge' ],
		prompt => 'Describe the Voice select on the watch or t-deck row in the Embedded panel. The watch offers four choices and the t-deck three: Voice: Off, Voice: Any speech (VAD), Voice: Hey Jawn, and on the watch only Voice: Jawn Do. Those two phrases are the only wake words trained - do not name any other. Also mention the Noise floor select on the same row: Auto (the default, which reads the room) or one of 1200, 1600, 2000, 2600, 3400 to pin it.'
	},
	'windows' => {
		title => 'Windows', category => 'features',
		summary => 'Open, stack, move, resize, snap and minimise.',
		body => [
			'Everything that opens opens in a window. Windows stack in the order you last touched them, drag by their title bar, resize by their edge, and minimise to a small bar.',
			'The title bar\'s buttons are help (?), minimise, restore, maximise and close, and each window\'s drop-down menu adds snapping to half the screen and a move mode for precise placement. The layout of what is open is remembered and restored next time.'
		],
		related => [ 'taskbar', 'start_menu', 'appointment_windows', 'help_app' ]
	},
	'appointment_windows' => {
		title => 'Appointment windows', category => 'features',
		summary => 'The window that gathers everything about one record.',
		body => [
			'Opening an appointment — a task, an invoice, a scan, a note, a measurement — spawns a window built around that one record. It gathers what the record is (its details), what has happened to it, and the things that name it: files, mail, transactions, the apps it touches.',
			'An appointment window is a centre view: it is not one app but a hub, and it can pull in panels from several apps at once. That is why opening one can feel like the whole desktop leaning in — it is.',
			'Its header carries the record\'s controls; below it, the panels are drawn from the record\'s own data and the apps that reference it.'
		],
		steps => [
			'Open an appointment by clicking it on the timeline, or a row in any app.',
			'The header shows what the record is; edit the fields there.',
			'The panels below gather the files, mail, money and other appointments that name it.',
			'Close the window when you are done — nothing about the record changes until you edit a field.'
		],
		related => [ 'appointments', 'windows' ]
	},
	'taskbar' => {
		title => 'The taskbar', category => 'features',
		summary => 'A reorderable row of window slots, the clock, the start button and pins.',
		body => [
			'The taskbar is an ordered list of slots: the open windows, the clock, the start button, the search box and any apps or keyboards you have pinned. It can sit on any edge, be shown, hidden or set to auto-hide.',
			'Right-click (or long-press) the bar for its context menu: rearrange the slots in edit mode, move it, choose the clock\'s format and time zone, and add items.',
			'The clock shows the time the view is standing on, so when the time machine or a timeshift carries you off the present its plate lights up - a warm, breathing glow - and goes dark again when the face reads now.',
			'Click the clock to use it as a time machine: type a time - "-3h", "jul 16", "last dec 25", "dec 25 2025 at 7:04pm", even "oct 12 96" - and press Enter to carry the view there, or Escape to leave it. An empty entry is now. Named days come out right ("this christmas" is this year\'s, "next christmas" the next), as do ages ("when I\'m 60" is today, at sixty). A time of day that is a habit - "breakfast", "tea time", "coffee", "next coffee time", "bed time" - is read from when you usually do it, the times your own records cluster around (twice a day for coffee, say), and falls back to a plain hour when there is nothing to read. A phrase the app cannot read itself is handed to the guide, which reads your own records for it ("the last time I had a beer", "the next time I\'ll be free"), knows the birthdays you saved under Configure -> App -> Birthdays ("mom\'s birthday" is the next one to come, "when was mom\'s birthday" the last one that passed, "mom\'s 60th birthday" the year she turned sixty) and looks up the rest ("Abraham Lincoln\'s 35th birthday"), and gives the time as well as the day for a past or future event ("the moment JFK was shot", "when the first world war ended", "the American Revolution"), then travels where it says. When you ask for something to be started ("start lunch in 20 minutes") it makes the appointment - written at once, or staged for a yes when the Confirmation Requirement is ticked - so its alarm and any embedded relay fire. A length you name is kept too ("start office that lasts 5 minutes" writes a five-minute office visit), held the way the tree counts time - an accrual, stored as a negative offset, so a start and its stop add up. Any year works, backward as well as forward, B.C. being a negative year ("-0044-03-15").',
			'A ghost appointment is one your records expect but that is not scheduled - your usual breakfast, the next coffee - drawn semi-transparent ahead of now in the timeline and every other view. Turn them on or off under the walkman\'s Configure (the wrench beside the time machine).'
		],
		steps => [
			'Right-click the bar to open its context menu.',
			'Turn on edit mode to rearrange the slots and pins.',
			'Or use Position to move the bar, and Autohide to tuck it away.',
			'Set the clock\'s format and time zone from the same menu.',
			'Click the clock and type a time to travel to it.'
		],
		related => [ 'start_menu', 'dock', 'windows' ]
	},
	'start_menu' => {
		title => 'The start menu', category => 'features',
		summary => 'Recently used apps, a category rail and a search.',
		body => [
			'The start menu opens on the apps you used most recently, with a category rail (accessories, business, games, media, system) for the whole catalogue.',
			'Its pages also cover what is running, what is upcoming and what is expiring, plus a System view of the house\'s levels: this machine\'s battery, every peer that answered the last pass, and the embedded boards any of them can see (over Wi-Fi, or the Bluetooth link a machine is already holding), each with charge, state, temperature, voltage and PPH, and an estimate of the time left on it (or the time to full while it is charging). The view stays live while it is open, refreshing every few seconds; a pack that reports its own gauge (a phone\'s charge counter, a laptop\'s energy and power) gives the finish time the moment it is plugged in, without waiting for a measured rate. A search box can ride the menu, the taskbar or the dock. A new message raises a dot on the menu\'s mailbox icon.'
		],
		steps => [
			'Press the start button to open the menu.',
			'Use the category rail to narrow the catalogue, or the search box to find an app by name.',
			'The menu\'s other pages show running, upcoming, expiring and the house\'s system levels.',
			'Help sits at the foot of the menu if you want to read about an app before opening it.'
		],
		related => [ 'search', 'taskbar', 'hints' ]
	},
	'dock' => {
		title => 'The dock', category => 'features',
		summary => 'A second bar that slides away when idle.',
		body => [
			'The dock is a second bar you can place on any edge. It holds pinned apps and can host the search box; a side dock tucks itself away and slides back when you call for it.'
		],
		related => [ 'taskbar', 'search' ]
	},
	'clothesline' => {
		title => 'The clothesline', category => 'features',
		verified => '2026-10-19',
		summary => 'A rail that hangs the routines belonging to this hour.',
		body => [
			'The clothesline runs along the top of the desktop and hangs the routines and rituals that belong at the current hour, in the order they usually happen.',
			'It can hang the ones your history shows you actually do, automatically, and each hang is configured per app: a schedule, a budget, and the time slots it belongs to.',
			'Each routine hangs as a pill in the material picked under Misc → Texture — plain (the original solid tile with its name printed plainly), round (a solid rounded pill), sandglass, glass, paper, fabric, wood or metal — sized to its own name so the whole name fits, with the name printed in black or white (tinted with the app\'s colour) so it reads on the pane.'
		],
		related => [ 'appointments', 'tasks' ]
	},
	'search' => {
		title => 'Search', category => 'features',
		summary => 'Find an app by name, from wherever the box sits.',
		body => [
			'Search finds apps by name. The box can live in the start menu, the taskbar or the dock, and it filters the catalogue as you type.'
		],
		related => [ 'start_menu', 'dock' ]
	},
	'hints' => {
		title => 'Hints', category => 'features',
		summary => 'Hover (or long-press) a control to learn what it does.',
		body => [
			'Most controls carry a hint. On a desk you hover over one and a small label appears; on a touchscreen you press and hold instead. That is the fastest way to learn an unfamiliar button.',
			'For anything longer than a label, open this Help app — press F1, or search here. The question-mark button in a window\'s title bar opens a Guide associate for that window instead, so it already knows what you were looking at.'
		],
		related => [ 'help_app', 'start_menu' ]
	},
	'themes' => {
		title => 'Colour schemes', category => 'features',
		verified => '2026-10-18',
		summary => 'Named palettes, each in a light and a dark cut.',
		body => [
			'JawnOS ships a set of named colour schemes — Blue, Graphite, Green, Indigo, Steel, Amber, Teal, Plum and Rose — and each has a light and a dark cut, so the chrome can range from near-white to near-black.',
			'They live under Configure, and the whole desktop changes as you pick one. The dark cuts change the window surfaces most, because the chrome is derived from the manager surface; inputs and dropdowns follow the same surface, so their text stays readable. Each scheme also gives windows and appointments their own surface, one step along the same ramp, so an app does not dissolve into the desktop behind it.',
			'A dark scheme also darkens the other surfaces by itself — the dock and its buttons, Configure, the start menu, the keyboard and its panels, the store and the taskbar — so a light face picked earlier does not glare through. They keep the hue they were given and are simply taken down to a dark shade; switching back to a light scheme restores them.',
			'An app can also carry its own Theme: while one of that app\'s start appointments is running the desktop wears it, the most recently started running app wins when more than one has a theme, and with none running the Misc scheme comes back. The icons follow too: every set has a light and a dark cut, and the dark cut is chosen automatically while a dark theme is in force.'
		],
		related => [ 'icon_sets', 'zoom', 'configure' ]
	},
	'icon_sets' => {
		title => 'Icon sets', category => 'features',
		summary => 'A choice of looks for every icon, hand-drawn by default.',
		body => [
			'Every icon can be swapped between a set of looks — from the original hand-drawn artwork through cleaner, flatter and frankly sillier sets. The default is the hand-drawn one.',
			'Pick one under Configure; the whole interface follows, including the window controls, the phone app\'s handset and camera buttons and the dock\'s own buttons.',
			'Each set has a light and a dark cut. While a dark colour scheme (or a dark appointment theme) is in force the dark cut is chosen automatically — the same glyphs, on a plate that does not glare — and it returns to the light cut when the desktop does. The hand-drawn set has no dark cut of its own, so it stays as drawn.'
		],
		related => [ 'themes', 'configure' ]
	},
	'zoom' => {
		title => 'Display zoom', category => 'features',
		summary => 'Scale the whole interface from a phone to a large display.',
		body => [
			'Global display zoom runs from twenty to two hundred per cent, and the bar heights and window border are adjustable too. Between them the same interface fits a phone, a tablet or a wall-sized screen.'
		],
		related => [ 'themes', 'configure' ]
	},
	'utility_controller' => {
		title => 'Utility controller', category => 'features',
		templates => [ 'templates/configure/utility_controller.html.ep', 'templates/configure/system_setting_list.html.ep' ],
		controls => [ 'Run this job', 'How often', 'Good', 'Bad' ],
		verified => '2026-10-16',
		summary => 'The background jobs every machine runs, how often, and the house AI view above them.',
		body => [
			'Configure → Sys holds the Utility controller: one card per machine on the mesh, and under each card its background jobs — the utilities. A job has a switch to run it, a box for how often, the time it last ran, and a good/bad dot. Your own machine is the first card, named Me, above every peer; the peer cards follow, named by their hostname.',
			'The dot is good (green) while the job has last run within five of its intervals, and bad (red) once it has not. A job that throws or runs past its timeout is stopped and logged rather than retried, and simply waits for its next turn.',
			'Under each job a line says what its last run did - a count when it worked on something new, or that it found nothing - so a job that ran and found nothing does not read as one that never ran.',
			'The jobs include backups, email send and receive, the tunnels, the remote-machine sync, the remote relay (which hands a change queued with no browser behind it on to the other machines), navigation, the alarm haircut, the budget pass, tasks, warehouse expiry, the battery sample (htop) and a manager tick. A few only do anything on a handheld — SMS, the telephone check and navigation.',
			'It is per machine: an interval or a switch set here applies to the machine whose card it is on, so one job can run every two minutes on the phone and hourly on the server.',
			'The Sys panel also shows the house at a glance, above the Utility controller: one row per machine, whether it has a model, when it was last seen, and what it has spent today, with the house total against the shared Tokens/day ceiling. Because each AI job runs once for the house and a machine that goes quiet hands its job on, the roster is the live machines only.',
			'Below it is the API balances table: what is left on each provider account, where the provider reports it. OpenRouter and DeepSeek do; the rest — Ollama, Cloudflare, OpenAI, Anthropic, Google, xAI, Mistral and Groq — have no balance endpoint and read “no balance API”. The read happens in the background every ten minutes, so the page never waits.'
		],
		steps => [
			'Open Configure and press Sys; the Utility controller is in that panel.',
			'Find the machine whose jobs you want to change.',
			'Tick the switch to run a job, and set its interval in the box beside it (for example 2m).',
			'Watch the last-run time and the good/bad dot to see whether it is keeping up.',
			'In the Sys panel, read the house table and the API balances to see the AI work and what is left on each account.'
		],
		prompt => 'Explain the Utility controller in Configure → Sys: one card per machine, each background job with a run switch, an interval box, a last-run time and a good/bad dot. Good means it has run within five intervals; bad means it has not. A failing job waits its interval instead of retrying. Everything is per machine, so an interval on one machine does not move another. The Sys panel also shows the house AI ledger - each machine, whether it has a model, when it was last seen, its tokens today, and the house total against the shared Tokens/day ceiling - and the API balances table, where only OpenRouter and DeepSeek report a balance and the rest read no balance API. Do not invent job names beyond the ones listed.',
		related => [ 'configure', 'backup', 'devices_and_mesh', 'process_monitor' ]
	},
	'navigation' => {
		title => 'Navigation (location logging)', category => 'features',
		templates => [ 'templates/appointment_details.html.ep', 'templates/appointment_wrapper.html.ep', 'public/js/manager/travel.js' ],
		verified => '2026-10-16',
		summary => 'JawnOS records where a device is on a schedule, screen on or off.',
		body => [
			'Navigation is the autonomous location log. On a handheld the backend asks for a fresh GPS fix once per navigation interval — whether or not the app is open and whether or not the screen is on, since the phone holds a wake lock for it — and writes that one point down as the machine\'s current position.',
			'An app can also carry its own pace. An app\'s navigation setting is none (never log), once (log only when you act on it), or an interval such as 1m. While an appointment of that app is running, a fix is filed against it at that interval — never faster than the navigation interval itself (the utility\'s own pace in the Utility controller), which is the real ceiling.',
			'Those filed fixes are the Distance list on the appointment: open its details and the Distance section lists each point with its distance from home, the kilometres since the last one, and the speed between them.',
			'Navigation also drives the home plate: when the device crosses a home plate\'s radius, that plate\'s duty can start or stop the matching appointment on its own.'
		],
		steps => [
			'Give an app a navigation value in its settings: none never logs, once only logs when you act, and an interval (like 1m) logs while one of its appointments is running.',
			'Start an appointment of that app and carry the device; the backend files a fix each navigation interval.',
			'Open the appointment and read its Distance list for the points, the distance and the speed.',
			'Set a home plate and a duty on it to let crossing that radius start or stop the appointment by itself.'
		],
		prompt => 'Explain JawnOS navigation: the backend logs one GPS fix per navigation interval, screen on or off, while the phone holds its wake lock; the per-app navigation setting is none / once / an interval; and filed fixes appear in the appointment\'s Distance list (distance from home, kilometres since the last, speed). The utility interval is the ceiling — a 1m per-app setting still only gets a point about as often as the utility runs. Do not describe it as a live map, and never guess a person\'s actual location.',
		related => [ 'travel', 'appointments', 'devices_and_mesh' ]
	},

	# ----------------------------------------------------------- functions
	'appointments' => {
		title => 'Appointments', category => 'functions',
		summary => 'The one record everything else hangs from.',
		body => [
			'An appointment is the atom of JawnOS: a timestamped record with a type, a status, a duration and an app-specific body. Files, invoices, measurements, notes and mail are all appointments under the hood, which is why they can refer to one another.',
			'Opening one spawns a centre view that ties together everything that names it. Appointments can have alarms, recur, and be exported to a calendar.'
		],
		related => [ 'appointment_windows', 'clothesline', 'tasks', 'reminders' ]
	},
	'reminders' => {
		title => 'Reminders and alarms', category => 'functions',
		summary => 'Let an appointment come back and find you.',
		body => [
			'An appointment can be given an alarm, a reminder and a recurrence, so it announces itself when its time comes and returns on schedule.'
		],
		related => [ 'appointments', 'clothesline' ]
	},
	'scanning' => {
		title => 'Scanning a document', category => 'functions',
		summary => 'Turn a paper page into a searchable record.',
		body => [
			'A scan is born in Notes: it captures a page, can read the text off it, and can read a barcode or QR code. The result is an appointment carrying the scan as an attachment, so it can be found from whatever it belongs to.'
		],
		steps => [
			'Open Notes and start a new note.',
			'Use the scan action and choose your camera or a connected scanner.',
			'Crop the page to the paper if you are offered it; this improves the text recognition.',
			'Turn on OCR so the text is lifted off the image and becomes searchable.',
			'For a barcode or QR code, use the scan action\'s code mode instead — it records the code on the note.',
			'Save the note; the scan and any recognised text stay with it.'
		],
		prompt => 'The reader is new and wants to scan a document. Give a numbered, click-by-click walkthrough, in order, using plain language. If OCR or barcode modes are the wrong fit for what they described, say so and redirect them. Do not assume any personal data.',
		related => [ 'notes', 'sealing_files', 'folders' ]
	},
	'sealing_files' => {
		title => 'Sealing files', category => 'functions',
		summary => 'Encrypt a file under a name of its own.',
		body => [
			'Sealing encrypts a file with your credentials and gives it a name of its own, so it can be stored anywhere without being readable. It opens again from the same right-click menu in Folders.',
			'Attachments you email are sealed too, so the copy on disk is protected the same way.'
		],
		steps => [
			'Open Folders and right-click the file.',
			'Choose Seal; give it a name of its own.',
			'The job runs in the background and reports its progress.',
			'Open it again from the same menu — the sealed file carries what it needs to be unlocked.'
		],
		related => [ 'folders', 'security', 'mailbox' ]
	},
	'invoices_payments' => {
		title => 'Invoices and payments', category => 'functions',
		summary => 'A document that closes itself when it is paid.',
		body => [
			'A quote or invoice is built from store items and prints to a house-styled sheet. Recording a payment against it writes the matching income transaction and pushes a payment onto the document, updating the balance and closing it when the balance reaches zero.',
			'Deleting that transaction unwinds the payment: the balance goes back up, and a document that had closed reopens.'
		],
		steps => [
			'Build the document in Store from items and options.',
			'Move a quote to an invoice when it is accepted.',
			'Send or print the invoice.',
			'Record a payment against it; the balance falls.',
			'At zero it closes. Delete the payment\'s transaction and it reopens, balance restored.'
		],
		related => [ 'store', 'budget', 'moves_ledger' ]
	},
	'moves_ledger' => {
		title => 'The moves ledger', category => 'functions',
		summary => 'Stock and money folded into one signed list.',
		body => [
			'The warehouse keeps a journal of every stock movement and its reason. The moves ledger takes that journal and the money beside it and folds them into one signed list, so goods in and out and money in and out read as a single story.'
		],
		related => [ 'warehouse', 'invoices_payments', 'budget' ]
	},
	'evaluation' => {
		title => 'Evaluation', category => 'functions',
		summary => 'A model-backed appraisal of an app\'s activity.',
		body => [
			'Evaluation is an appraisal of any app\'s activity, run on demand or nightly. It reads what the app is and what it has been doing, weighs day, week, month and year together, and leaves a report beside the app with a headline and links to everything it names.',
			'It runs through a local model, so the appraisal never leaves your machine unless you point it elsewhere.'
		],
		steps => [
			'Open the app you want appraised and find its evaluation panel.',
			'Run it on demand, or let the nightly pass do it.',
			'Read the report in the app\'s inventory; its links open everything it names.'
		],
		related => [ 'assistant', 'inventory', 'measures' ]
	},
	'assistant' => {
		title => 'Assistant', category => 'functions',
		summary => 'Chat and image generation, plus speech.',
		body => [
			'Assistant is the AI surface: chat and image generation, with speech synthesis and transcription alongside. Like Evaluation, it prefers a local model so your data stays put unless you point it elsewhere.',
			'Which model each assistant uses, and the keys that reach them, are set under Configure → Plat. Besides the local Ollama and Cloudflare Workers AI, that list now reaches OpenAI, Anthropic (Claude), Google (Gemini), xAI (Grok), DeepSeek, Mistral, Groq and OpenRouter.',
			'When JawnOS speaks aloud it uses the voice set under Configure → Misc → Speech: a neural Piper voice, or an eSpeak fallback. Speech plays on the machine running that device\'s jawn.'
		],
		related => [ 'evaluation', 'help_app', 'platform' ]
	},
	'agents' => {
		title => 'Agents (associates and coding)', category => 'functions',
		templates => [ 'public/js/manager/agents.js' ],
		verified => '2026-10-16',
		summary => 'Every Guide associate and Coding agent conversation, named and kept.',
		body => [
			'Double-press the Assistant button — the taskbar pin, the start menu\'s icon, or an associate\'s own corner icon — and the Agents list opens against the button it was pressed on: beneath it, or just above when there is no room below — or wherever you last left it, if you have dragged it. A double-press shows the list only — the chat panel itself waits for a single press. The list holds every conversation the Guide\'s associate and the Coding agent have had, newest first; a row whose panel is on screen says open, and the rest are history, re-opened with what was said replayed into them when pressed.',
			'Every conversation names itself the way a chat thread does: shortly after the first thing is said, the assistant\'s model gives it a title of two to five words (a plain cut of the words when no model is set), and that name follows it in the list and on the panel\'s bar.',
			'Conversations live in the app\'s settings, so they sync like the rest and a thread begun on one machine is in the list on another. The list\'s + guide and + coding make fresh conversations; the + in an open panel\'s own bar does the same. The chat panels themselves stand larger on a desk, with bigger text; on a small screen they keep the compact size.',
			'A work claim says which machine is on which job, so two agents do not take the same one: a job (the ghost appointments, say) is claimed by name, and the claim rides the \'claims\' app - not one of the protected apps - so the mesh carries it to every machine, the same way appointments stay in step. The walkman\'s Configure shows who holds the ghosts claim, with take and release.',
			'Any row deletes the way this program deletes: the first press arms it red for two seconds, and a second press inside that window throws the conversation away - an open one takes its panels with it, while the taskbar\'s own associate or a chatbox mounted in an app clears its log and stays.'
		],
		steps => [
			'Double-press the Assistant button for the Agents list.',
			'Press a row to bring its panel forward, or to re-open its thread.',
			'Press delete on a row twice to throw the conversation away - any row, open or history.'
		],
		related => [ 'help_app', 'ide', 'terminal' ]
	},
	'platform' => {
		title => 'Platform (AI providers)', category => 'functions',
		templates => [ 'templates/configure/plat_setting_list.html.ep' ],
		summary => 'Choose the model each assistant uses, add provider keys, and teach the Guide runtime commands.',
		verified => '2026-10-16',
		body => [
			'Configure → Plat gathers every AI choice in one place: which model each assistant uses, and the key or account each provider needs.',
			'Providers include the local Ollama, Cloudflare Workers AI, OpenAI, Anthropic (Claude), Google (Gemini), xAI (Grok), DeepSeek, Mistral, Groq and OpenRouter. A model is addressed as provider:model — a bare name goes to Ollama, and @cf/… to Cloudflare.',
			'Other machines\' own Ollama models are offered too, each listed under the machine that runs it (Ollama · that machine). Their model lists are cached in the background, so Plat opens without waiting on the network; picking one runs the call on that machine.',
			'Google Veo is offered as a Video-generation model: it runs the job on Google\'s side and the tree polls it until the video is ready.',
			'Thinking is set per agent, beside its model, and shown for the language agents — the Help guide, Evaluation, Vision, the Pen and Coding — when the chosen model can reason; Image generation never carries one. A model that does not reason is not offered the choice (the families that do: the o-series, GPT-5, Claude 3.7/4, Gemini 2.5+, Grok 3/4, DeepSeek R1/v4/flash, Magistral, Qwen3 and the like). The level reaches each agent\'s own model calls, and a level a model does not understand is dropped and the call retried without it.',
			'Image, Audio and Video generation are their own agents, each holding the model that produces that kind of file; a prompt Pen (or a Guide associate) describes is filed by the matching one, with a “Generating … with …” note while it runs. Transcription (speech in) is its own agent too: it tries the chosen cloud model first and falls back to the local whisper.cpp when that fails.',
			'Every agent also carries a Fallback choice beside its model — the same list minus the primary. When the primary errors (an outage), the call steps down to the fallback instead of failing; the transcription agent adds whisper.cpp after that.',
			'Secret keys are stored encrypted and are never shown back: a key that is set reads “••• set”, and typing a new value replaces it.',
			'Beside each provider that is set up sits the money left on its account, where the provider reports one: OpenRouter and DeepSeek publish a figure, and the rest read “no balance API”. The reading is kept fresh in the background (off the page), so opening Plat never waits on a provider.',
			'Guide commands (runtime) is where you teach the Guide new verbs without a code change. Each is a JSON entry naming a primitive — say, open_app, set_setting, run_command, toggle, stage, find or play_music — and its parameters. The list is a setting, so it syncs to every machine and they all learn the verb.',
			'Self-healing is the error watch: tick Watch errors and, with a Coding model set, every new error is caught and listed in the IDE\'s coding panel with a fix the Coding agent has proposed — the tree\'s own log (the pty stream the master tees to ~/pty.log, plus manager.log) and the browser: every page reports its fatal JavaScript errors (an uncaught exception, an unhandled promise rejection, a script or stylesheet that would not load), which is what JS means on a row\'s line. The fix waits there: Apply writes it, checks it compiles, bumps the version, commits and pushes, and the panel\'s restart link puts it live. Nothing is written until Apply — unless Apply automatically is ticked, when each proposal is written, checked (perl -c, rolled back if it fails) and shipped at once, like the Guide associate\'s Confirm tick; a file that has uncommitted work stands down and waits for you, and Tokens/day caps what the day may spend. Tick Watch the Guide and the Guide\'s own conversations are read the same way: a turn that went nowhere — a thing not found, a command that could not run, a closing line that says so — is staged for the Coding agent to adjust the Guide\'s training itself, its rules and its verbs. Fixed so far, under the tick, is the record of what has shipped: press review to read each fixed error, with the model that fixed it and the version it went out as. A tab follows a shipped fix on its own: a stylesheet or template change lands in place (the open windows re-render), while a change to the manager\'s scripts or its shell asks once — a small press-to-update note in the corner, or a silent reload when the tab is hidden; a conversation left in a coding agent survives it. The watch is one per house, not one per machine: a stable hash over the machines that have a model configured ranks them and the first takes each error, and only that machine pays to propose the fix, so two machines never repair the same thing; a fix already proposed is left alone while a person decides, and if that machine goes quiet the job hands on to the next rather than waiting. The day\'s token budget is one pot for the whole house, each machine\'s spend summed, so Tokens/day is the house\'s ceiling rather than one per machine. A machine named by hand wins over the ledger.',
			'Watch records is the same watch pointed at the database. Tick it and every two hours the appointments table is audited for the fault that corrupts the numbers: a session one stop press closed along with others, the same row written twice, and an open session run far past the app\'s length. Each finding is staged under Self-healing with the rows it would tombstone or repair. Nothing is written until Apply; the window sets how far back it looks (0 is all time). Apply records automatically writes only exact duplicates — the same event written twice on the mesh, which is provably one event — while a sweep or a long-open session always waits for you, because a real appointment can be surprisingly long (a home stay, a months-long ailment) and a fixed rule can never know that. Any finding carries an Ask box: put it to the Coding agent and it reads the rows and says what it makes of them, whether the repair is safe, and whether the honest answer is to leave it alone; Leave this app alone silences the audit for an app you know runs long.',
		],
		steps => [
			'Open Configure and press Plat.',
			'Under Agent models, pick the model each assistant should use — the Help guide, Evaluation, Vision, Image generation, Audio generation, Video generation, the Pen, Coding and Transcription — and, beside each, a Fallback model (the same list minus the primary) tried when the primary is down. Each list only offers models that fit the role, so a text assistant is not offered a vision-only model and the Vision role is not offered a plain text one; a model already chosen stays listed even if it does not fit. Each choice is marked free or paid. A language agent shows a Thinking choice beside its model when that model can reason — none, low, high or max — how long it may reason before it answers (the generation and transcription roles have none); a model that ignores the hint answers as it always did. A provider that runs out of credit has its paid models hidden and its chats step down to a free model until the account is topped up.',
			'Under Provider access, paste the key or account for each provider you want to reach. A field that already shows “••• set” is kept unless you type a new value.',
			'The balance beside a set-up provider is what is left on that account, where the provider reports it.',
			'Under Guide commands, add a verb as a JSON entry and press Save — every machine picks it up.',
			'Under Self-healing, tick Watch errors to have the Coding agent watch the tree\'s log and stage a fix for each new error; tick Watch the Guide and it reads the Guide\'s conversations for turns that did not land. Review and apply them from the fixes list in the IDE\'s coding panel, or tick Apply automatically to have each one written, checked and shipped on its own. Fixed so far, under the tick, shows the errors already fixed and shipped. Tick Watch records and the appointments table is audited on the same principle: review a finding, Ask the Coding agent about it before you decide, or Apply it — Leave this app alone clears an app you know runs long.',
		],
		related => [ 'configure', 'assistant', 'help_app' ]
	},
	'backup' => {
		title => 'Backup and restore', category => 'functions',
		summary => 'Take a copy, and put it back.',
		body => [
			'Backup packs the database and the media into an archive that can be moved or stored elsewhere; restore puts one back. A "Backup now" button lives in the start menu, and the same machinery carries data between machines.'
		],
		related => [ 'devices_and_mesh', 'folders' ]
	},
	'tickets' => {
		title => 'Tickets and logging in', category => 'functions',
		summary => 'A single-use link that is the credential.',
		body => [
			'A ticket is a single-use link that carries its own secret. Opening it mints a session and lands you on the desktop (or the store, or the homepage, depending on the ticket\'s privilege).',
			'Because the link is the credential, treat it like a password and revoke it from the Box Office when you are done. It is also how the desktop and Android apps log themselves in.'
		],
		related => [ 'box_office', 'security' ]
	},
	'devices_and_mesh' => {
		title => 'Machines, the mesh and sync', category => 'functions',
		summary => 'Several machines that keep each other in step.',
		body => [
			'JawnOS is built to run on more than one machine — a laptop, a phone, a tablet, a server — and to keep them in step without a central authority. Code, app builds and data all move the same way: whoever has the newest is the authority.',
			'Machines reach each other across whatever network they are on, including from behind a router, and every machine can be logged into from another via a ticket.',
			'One machine can also tell another what to do: name it and say the task — "on the table, play Friends" — and the command is read by that machine\'s own guide there, so it runs on that machine without the words leaving the mesh. The Assistant\'s remote_control panel has a box for the same thing.',
			'A machine with no browser — a headless server — holds its place in the mesh on its own: it registers itself in its own device list, so the tunnels its peers dial in on show up as its addresses, and it keeps pulling each peer\'s newest data on a schedule. A change it has no page to make is queued and handed on by the remote relay job, so the fleet stays in step whether or not anybody has a window open.',
			'The comparison is per table, not just the newest appointment: each machine exchanges a fingerprint of every table (how many rows, the sum of their write times, and the newest write time). A changed setting therefore counts as a change and syncs, while churn that carries no state — window geometry, open tabs, the door and remote timers — is left out of the comparison so it cannot start a sync by itself. Appointments are still the most useful trigger, but they are no longer the only one.',
			'The same comparison keeps one picture when a machine has been away: if its rows do not account for the difference between two tables — an old row made while offline and seen nowhere else — that table is read in full rather than by a time window, so the union of every machine survives.',
			'The yellow dot in the corner is the sync notice. While a machine pulls or serves a snapshot, a ring around the dot fills with the overall progress, and the panel it opens stacks a bar for each step — the export, the download, and each table as it merges. A finished sync shows a green check and a failed one a red cross; clicking the dot pins the panel until you click it again, after which the notice resumes its ordinary short life. The size beside a completed sync is the encrypted snapshot that actually moved, not the whole database, so a change-only pull is usually far smaller than the full copy.'
		],
		verified => '2026-10-17',
		related => [ 'backup', 'ble_bridge', 'tickets' ]
	},

	# ------------------------------------------------------------ devices
	'watch' => {
		title => 'The T-Watch', category => 'devices',
		summary => 'A wrist clock, notifications and app buttons.',
		body => [
			'The T-Watch is the wearable: a clock that also shows notification lines and screens of app buttons, logs steps, wakes when you raise your wrist to look at it, and can listen for a voice command. A button you press on it runs that app\'s movement in JawnOS, and a command button runs on every machine unless it names one.',
			'Its listening mode - off, any speech, or a wake word such as Hey Jawn or Jawn Do - is set from the watch row in the Embedded panel; see Voice and wake words.',
			'Its status bar carries the battery (with the time in its place whenever the clock is not the screen you are on) and, hard against the right edge, the name of the machine it is talking to - its homebase - in place of an address.',
			'An answer to a request the guide associate handles arrives on the watch itself: the words on screen, and the voice over its speaker unless the Audio replies toggle on its Embedded row is off.',
			'It talks to JawnOS over Bluetooth through a bridge running on a nearby phone or desktop, and stays with the machine it was paired to (its homebase) - another machine that links to it lets it go again.',
		],
		verified => '2026-10-15',
		related => [ 'voice', 'ble_bridge', 'tdeck', 'embedded' ]
	},
	'tdeck' => {
		title => 'The T-Deck', category => 'devices',
		summary => 'A handheld terminal with a keyboard and GPS.',
		body => [
			'The T-Deck is the handheld: a keyboard, a touch screen and GPS in a device small enough to carry. It acts as a handheld terminal — a "teletype" — for the machine it is talking to, and it can report where it is.',
			'It can also listen for a voice command: its Voice setting on the Embedded row - Voice: Off, Voice: Any speech (VAD), or Voice: Hey Jawn - starts a clip when it hears speech and sends it to JawnOS to transcribe. See Voice and wake words.'
		],
		related => [ 'watch', 'pico', 'ble_bridge', 'voice' ]
	},
	'pico' => {
		title => 'The Pico', category => 'devices',
		summary => 'A microcontroller that drives real pins.',
		body => [
			'The Pico 2W is the hands-on device: it drives real-world pins — LED, relay, servo, switch — and holds a small LCD. Jobs are scheduled on it and fire when their time comes, so it can act on the physical world on JawnOS\'s behalf.'
		],
		related => [ 'tdeck', 'watch', 'embedded' ]
	},
	'ble_bridge' => {
		title => 'The Bluetooth bridge', category => 'devices',
		summary => 'How the watch and boards reach JawnOS.',
		verified => '2026-10-17',
		body => [
			'The devices speak Bluetooth Low Energy, but JawnOS itself is reached over the network, so a small bridge sits in between: a Bluetooth central (on a phone, or on a desktop) that links to a device and relays messages to and from JawnOS over a local socket.',
			'The bridge is the same piece of software on both platforms, so a watch links to whichever machine is in range and can bring its own apps with it.',
			'Each device names itself in a Bluetooth scan response: a small JawnOS payload carrying its chip id and purpose (watch, deck or board). The bridge recognizes that payload before it connects, so a crashed board or a fresh one is adopted and restored without touching its network, and a device already in the fleet comes back to its role as soon as it is in radio range.',
			'A T-Watch is a one-link device, so it stays with the machine it was last paired to from the watch row (its homebase). Another machine that links to it releases it again, so a button press always lands on the right machine. If the homebase drops off the mesh - a phone that switches off - another machine takes the watch over after a while, and hands it back the moment the homebase is seen again. A homebase that merely leaves the network keeps it - only one gone long enough to stop waiting hands over. A button you press on the watch is applied by the machine holding the link, so it lands whatever machine you were looking at; a command button runs on every machine unless it names one.',
			'The bridge itself is not limited to one radio: it holds four links by default, and a machine that can carry more may be set up to 25, each named by its address, so a watch, a deck and a board can stay linked together. Sends and releases name the radio they mean, which is what keeps one device\'s message from being applied to another. A message addressed to another chip is relayed to whichever machine holds that device, so devices on different bridges still reach each other, and a phone bridge can carry a watch-to-deck message with no WiFi at all.',
		],
		related => [ 'watch', 'tdeck', 'pico' ]
	},
	'help_app' => {
		title => 'This Help app', category => 'features',
		summary => 'The map you are reading now, and its guide.',
		verified => '2026-10-15',
		body => [
			'Help is the built-in guide. Search it, browse by category, or open it contextually: press F1 to read about the window you are focused on. The question-mark button in a window\'s title bar opens a Guide associate for that window — the same Guide, in a chat of its own, already aware of the window it came from.',
			'Each topic hands you to the Guide along the foot: pick a model and ask. It answers in a chat, and it can also act on the screen. "Show me pictures of George Michael" searches your records and opens the photo browser on them; "how far have I walked this month" and "when am I expected to be 180" are read from your own logs; "show Sarnia on a map" centres the travel map; "where was I on September 18th" reads the recorded place fixes; and "play Friends" plays every episode it matches, as a list. Asked "when did I last have a beer" or "when am I next free", it reads the oldest, newest and next matching appointment from your own records (across the appointments log and the other tables), and the time machine reads them the same way. It reports each step as it goes.',
			'It writes only with your say-so: the Confirmation Requirement. Ask it for an appointment and it stages the proposal and shows you what it would save; nothing is written until you confirm. Ask it to change one you already have — "delay email test by 5 minutes", "make it last 10 minutes", "move it to tomorrow at 3pm" — and it stages that too, then applies it in place. "Stop email test", "stop it in 10 minutes" or "stop it at 5pm" stops the running one at once; "delete the email test one that\'s coming up" (or "the one from yesterday at 3:30pm", "the one a week from now") deletes one, staged for a yes. Say "undo that" and it puts your last change back. The Guide\'s associate - the small chat in the corner, the same Guide and so carrying every one of these powers - carries a Confirm tick beside its close button: untick it and the Guide saves what it proposes without asking. Its configure button also holds Staged: everything the Guide is holding for a yes shows there, each row with a thumbs-up to save it and a trash to throw it away, showing what it is, when, and - when you gave one - how long it lasts, and the chat you left is still there when you come back. It never sends or pays, and never deletes without a yes.',
			'There can be several associates at once: the + in a panel\'s bar opens another, each with its own thread. Double-pressing the Assistant button shows the Agents list, where every associate and coding conversation is kept, named by its own words, and a press away from being re-opened or thrown away (see Agents). Its config menu also carries Speak the replies; ticked, each answer is spoken as well as written, through the voice set under Configure → Misc → Speech (Piper first — the same voice the watch\'s answers use).',
			'A thing you have marked not-visible is neither named nor opened here unless its padlock is open and you are at home, so a hidden album stays hidden out in public.',
			'It can also tell another of your machines what to do, by name - "on the table, play Friends" - and that machine\'s own guide reads the command there, so it stays on that machine.',
			'You can speak instead of typing: if you press Send with the box empty, the guide starts listening, and Stop turns what you said into words in the box. It uses the same speech-to-text the watch uses. The Converse button turns it into a conversation: the mic opens again after each answer - the clip ends itself once you stop talking - and each thing you say is the next turn of the same thread. Say or type "hey jawn" (or "jawn do") to start one, and "bye jawn" or the End button to stop; while it is on, the button is red. An on-device "hey jawn" listener will call the same switch when its model lands.',
			'Tick the Coding box in the composer (set its model under Configure → Plat → Coding) and the same box becomes the Coding agent. It can change JawnOS\'s own code, check it, and ship it - bumping the version, committing and pushing to GitHub, then restarting - so the program can mend itself from a plain request.',
			'Under each answer is a small good / not-good pair. Press the one that fits and the verdict is kept with the question and the reply, so the guide\'s answers can be judged over time.',
			'You can also teach it new verbs at runtime (Configure → Plat → Guide commands): each is a small JSON entry naming a primitive and its parameters, and because it is a setting it syncs, so every machine understands the same commands.'
		],
		related => [ 'hints', 'handbook', 'assistant' ]
	}
);

# Resolve a loose topic name to a canonical key. Case is folded and spaces or
# hyphens become underscores, so callers can be forgiving about what they pass.
sub key {
	my ($id) = @_;
	return '' unless defined $id && length $id;
	$id = lc $id;
	$id =~ s/[\s\-]+/_/g;
	$id =~ s/^_+|_+$//g;
	return $id;
}

sub get {
	my ($id) = @_;
	return $topic{ help::key($id) };
}

# The whole catalogue as plain records, for the index and for search.
sub catalogue {
	my @out;
	foreach my $id (sort keys %topic) {
		my $t = $topic{$id};
		push @out, {
			id => $id,
			title => $t->{'title'},
			category => $t->{'category'},
			summary => $t->{'summary'},
			app => $t->{'app'}
		};
	}
	return @out;
}

# Simple case-insensitive substring search over the title, summary, body and
# steps.
sub search {
	my ($q) = @_;
	return () unless defined $q && length $q;
	my $needle = lc $q;
	my @out;
	foreach my $id (sort keys %topic) {
		my $t = $topic{$id};
		my $hay = join ' ', ($t->{'title'} // ''), ($t->{'summary'} // ''), @{ $t->{'body'} // [] }, @{ $t->{'steps'} // [] };
		if (lc($hay) =~ /\Q$needle\E/) {
			push @out, { id => $id, title => $t->{'title'}, category => $t->{'category'}, summary => $t->{'summary'}, app => $t->{'app'} };
		}
	}
	return @out;
}

# The material an AI guide should read about a topic: everything the reader can
# see here, plus any steering the topic carries.
sub briefing {
	my ($id) = @_;
	my $t = help::get($id);
	return '' unless $t;
	my @lines;
	push @lines, 'Title: ' . ($t->{'title'} // '');
	push @lines, 'Summary: ' . ($t->{'summary'} // '');
	foreach my $p ( @{ $t->{'body'} // [] } ) { push @lines, $p; }
	if (@{ $t->{'steps'} // [] }) {
		push @lines, 'Steps: ' . join(' | ', @{ $t->{'steps'} });
	}
	push @lines, 'Steering: ' . $t->{'prompt'} if $t->{'prompt'};
	return join "\n", @lines;
}

# ---- code-aware helpers (the auditor and the guide both use these) ---------

# The files that back a topic: any it names explicitly, plus the conventional
# spots for its app. Only paths that exist are returned, so a moved file surfaces
# as a missing one the auditor can complain about when it was listed explicitly.
sub resolve_files {
	my ($id) = @_;
	my $t = help::get($id) or return ();
	my %seen;
	my @out;
	my $add = sub {
		my $p = shift;
		return unless defined $p && length $p;
		return unless -e $p;
		return if $seen{$p}++;
		push @out, $p;
	};
	foreach my $p ( @{ $t->{'templates'} || [] } ) { $add->($p); }
	my $a = $t->{'app'};
	if ($a) {
		$add->($_) foreach (
			"templates/apps/$a.html.ep",
			"templates/$a.html.ep",
			"public/js/manager/$a.js",
			"public/js/$a.js",
		);
	}
	return @out;
}

# The on-screen controls a topic's files declare, taken from their `hint="..."`
# literals. Interpolated hints (the ones with <, >, { or }) are skipped: only a
# fixed label is something the auditor can match a step against.
sub hints {
	my @files = @_;
	my %h;
	foreach my $f (@files) {
		next unless -e $f;
		open my $fh, '<', $f or next;
		local $/;
		my $body = <$fh>;
		close $fh;
		next unless defined $body;
		while ($body =~ /hint="([^"<>{}]+)"/g) { $h{$1} = 1; }
	}
	return sort keys %h;
}

# A machine-generated inventory of an app, handed to the guide alongside the
# hand-written entry. It is built from the code, so it stays current even when
# the prose lags - and the guide is told to prefer it when the two disagree.
sub inventory {
	my ($id) = @_;
	my $t = help::get($id) or return '';
	my @files = help::resolve_files($id);
	my @h = help::hints(@files);
	my $v = $t->{'verified'} || $verified_default;
	my @lines;
	push @lines, 'CURRENT UI (generated from the code - trust this over the prose if the two disagree):';
	push @lines, '  source files: ' . (@files ? join(', ', @files) : '(none resolved)');
	push @lines, '  on-screen controls (from the code): ' . (@h ? join(', ', @h) : '(none found)');
	push @lines, '  hand-written entry last vetted: ' . ($v || 'never') . '.';
	return join "\n", @lines;
}

# Check every topic against the tree. Returns a list of [severity, topic, message]
# where severity is one of 'error' (blocking), 'stale' (the code moved on), or
# 'warn'/'info' (advisory).
sub audit {
	my %ids = map { $_ => 1 } keys %topic;
	my @out;
	foreach my $id (sort keys %topic) {
		my $t = $topic{$id};
		foreach my $r ( @{ $t->{'related'} || [] } ) {
			push @out, [ 'error', $id, "related '$r' has no topic" ] unless $ids{ help::key($r) };
		}
		foreach my $p ( @{ $t->{'templates'} || [] } ) {
			push @out, [ 'error', $id, "listed template '$p' is missing" ] unless -e $p;
		}
		my @files = help::resolve_files($id);
		if ($t->{'app'} && !@files) {
			push @out, [ 'warn', $id, "no source files resolved for app '$t->{'app'}' - add a templates list" ];
		}
		if ($t->{'controls'}) {
			my %h = map { $_ => 1 } help::hints(@files);
			foreach my $c ( @{ $t->{'controls'} } ) {
				push @out, [ 'error', $id, "control '$c' is no longer an on-screen hint in the app" ] unless $h{$c};
			}
		}
		my $v = $t->{'verified'} || $verified_default;
		if ($v && @files) {
			open my $fh, '-|', 'git', 'log', '--oneline', "--since=$v", '--', @files or next;
			my @commits = <$fh>;
			close $fh;
			push @out, [ 'stale', $id, "source changed since it was vetted on $v (" . scalar(@commits) . ' commit(s))' ] if @commits;
		}
	}
	# app templates with no topic at all
	foreach my $f ( sort glob('templates/apps/*.html.ep') ) {
		(my $base = $f) =~ s{.*/}{};
		$base =~ s{\.html\.ep$}{};
		my $found = 0;
		foreach my $id (keys %topic) { if (($topic{$id}->{'app'} || '') eq $base) { $found = 1; last; } }
		push @out, [ 'info', '(orphan)', "templates/apps/$base.html.ep has no topic" ] unless $found;
	}
	return @out;
}

# The catalogue and rules the acting guide is given. Kept here with the rest of
# the help content so the vocabulary lives in one place.
# ---- runtime (learned) verbs ----------------------------------------------
# Beyond the built-in tools, a verb can be added at runtime: one row in the
# __president/guide_verbs setting names a closed primitive and the parameters to
# run it with. A row is data, and settings already sync across the mesh, so a
# verb added on one machine is understood by all of them. The primitives are the
# only things a learned verb can do, so a runtime verb can never reach past them.
sub learned_verbs {
	my $raw = eval { &subs::setting_grabber({ app => '__president', setting => 'guide_verbs', device => 'all' }) } || '';
	my $rows = eval { Mojo::JSON::decode_json($raw) } || [];
	$rows = [] unless ref $rows eq 'ARRAY';
	my @out;
	foreach my $v ( @{$rows} ) {
		next unless ref $v eq 'HASH';
		next unless ($v->{'name'} // '') =~ /^[a-z][a-z0-9_]{1,40}$/;
		next unless ($v->{'primitive'} // '') =~ /^(?:say|open_app|set_setting|run_command|toggle|stage|find|play_music)$/;
		push @out, $v;
	}
	return \@out;
}

# The learned verbs as prompt lines, shaped like the built-in ones.
sub learned_tool_lines {
	my $lines = '';
	foreach my $v ( @{ &learned_verbs() } ) {
		my @args = sort keys %{ $v->{'args'} || {} };
		my $ex = '{"action":"' . $v->{'name'} . '"' . join('', map { ',"' . $_ . '":"..."' } @args) . '}';
		my $gap = ' ' x (length($ex) < 46 ? (46 - length($ex)) : 2);
		$lines .= '  ' . $ex . $gap . ($v->{'desc'} // 'a learned command you may run') . "\n";
	}
	return $lines;
}

# Every verb the guide may pick: the built-in ones plus the learned ones. Used
# for the allow-list here and by the remote channel, so both understand alike.
sub live_verb_names {
	my %names = map { $_->{'name'} => 1 } grep { !$_->{'planned'} } @gb::guide_tools;
	$names{ $_->{'name'} } = 1 for @{ &learned_verbs() };
	return \%names;
}

sub actions_prompt {
	# The action lines are generated from @gb::guide_tools (see gb.pl), so a tool is
	# declared once and offered here automatically once it is live (not `planned`).
	# $only, when given, is a hashref of tool names to offer: the remote channel has
	# its own executor that runs only a few of these verbs, so it must not offer the
	# rest - a model told it could "find" when nothing can run a find simply did
	# nothing at all.
	my ($only) = @_;
	# The Confirmation Requirement (the Confirm tick in the Guide's associate
	# panel, stored as a setting so it is the same on every machine): off means
	# a proposed appointment is saved as it is made, so promote and discard are
	# not offered and create says it writes straight in.
	my $confirm_setting = &subs::setting_grabber({ app => '__president', setting => 'guide_confirm', device => 'all' });
	my $auto_save = (defined $confirm_setting && $confirm_setting eq 'off');
	my $header = "You are the JawnOS Guide. You can explain things, and you can operate the screen\nfor the person. Reply with EXACTLY ONE JSON object and nothing else - no prose\naround it. Choose one action:\n\n";
	my $lines = '';
	foreach my $t ( @gb::guide_tools ) {
		next if $t->{'planned'};
		next if $only && ref $only eq 'HASH' && !$only->{ $t->{'name'} };
		next if $auto_save && ($t->{'name'} eq 'promote' || $t->{'name'} eq 'discard');
		my $desc = $t->{'desc'};
		if ($auto_save && $t->{'name'} eq 'create') {
			$desc = 'make the appointment and save it right away: the Confirmation Requirement is off, so create writes it straight in - do not ask for a yes and there is nothing to promote';
		}
		if ($auto_save && $t->{'name'} eq 'update') {
			$desc = 'change an appointment that already exists, named by "app" (add "title" when you know it). "delay" pushes it later by the length the person said; "when" moves it to a named moment instead; "duration" sets how long it lasts; "notes" replaces the note. Give only the fields that change. The Confirmation Requirement is off, so the change is saved the moment it is made - do not ask for a yes and there is nothing to promote';
		}
		my $ex = $t->{'example'} || ('{"action":"' . $t->{'name'} . '"}');
		# pad to the shared column, but never let a long example swallow the gap
		my $gap = ' ' x (length($ex) < 46 ? (46 - length($ex)) : 2);
		$lines .= '  ' . $ex . $gap . $desc . "\n";
	}
	# runtime verbs are added on every invocation: they are the person's own
	# commands (and the Coding agent's), understood on every machine
	$lines .= &learned_tool_lines();
	my $create_rule = $auto_save
		? "- To make an appointment, use create - the Confirmation Requirement is off, so it is saved the moment it is made. Do not ask the person to confirm and do not call promote; say briefly that it is saved."
		: "- To make an appointment, use create - it only stages a proposal. Tell the person what you staged and ask them to confirm; call promote only once they agree, and never say it is saved before promote returns. Use discard if they decline.";
	my $update_rule = $auto_save
		? "- To change an appointment that already exists (\"delay email test by 5 minutes\", \"make it last 10 minutes\", \"move it to tomorrow at 3pm\"), use update and name it by app. The Confirmation Requirement is off, so the change is saved the moment it is made - do not ask and do not call promote; say briefly what changed."
		: "- To change an appointment that already exists (\"delay email test by 5 minutes\", \"make it last 10 minutes\", \"move it to tomorrow at 3pm\"), use update and name it by app. It only stages the change - tell the person what will change and call promote only once they agree; call discard if they decline. Never say it is changed before promote returns.";
	my $rules = <<"TXT";
Rules:
- Navigate, search, make media and change appointments (update). Never delete, send or
  pay, and never change anything else.
- Choose only from the actions listed above; there is no other verb here.
- When the person names a photo, a record or an app to show them, use find first,
  then open what the result points at. If find returns an app, pass that exact app
  name to open_gallery - do not hand open_gallery a free-text name instead.
- The moment an OBSERVATION shows the thing they asked to see or do is now on
  screen, STOP and reply with done - for example
  {"action":"done","text":"Here are the photos."}. Do not follow a success with a
  question; the task is finished, so say so briefly and stop.
- If a search turns up nothing, say so or ask a short question - do not keep
  searching the same way.
- Read the OBSERVATION lines in the conversation to see what each action did
  before choosing the next one.
- The conversation may hold several USER lines. The earlier ones are history you
  have already handled - each is followed by the ANSWERED: note of what you said.
  Act only on the newest USER line; never answer an earlier turn again.
- For "when did I last see/do X", use find and answer from its last date - do not
  guess a date.
$create_rule
$update_rule
- If the person says "undo that" or "put it back", use undo to reverse your last
  appointment change.
- To stop what the app has running ("stop email test", "stop it in 10 minutes",
  "stop it at 5pm"), use stop. It acts at once - say briefly what you stopped.
- To delete one of the app's appointments ("delete the email test one that's coming
  up", "delete the one from yesterday around 3:30pm", "delete the one a week from
  now"), use delete, naming it with "which" (upcoming or last) or "when". It stages
  the delete, so tell the person which one and call promote only once they agree.
- "Where was I" and "when did I last see X" are different questions. For a place
  at a time, use where_when with an absolute date. For a record or photo, use find.
- For "show me <place> on a map", use show_place - it works offline from the
  places we have measured, so an odd name is matched against the things named for it.
- For "how far did I walk" use measure with measure "walk"; for a weight goal use
  measure with measure "weight". Do not guess a number - always take it from measure.
- To play or watch anything (a song, an artist, an album, a show or its
  episodes), use play_music with the person's own words; it plays every match as
  a list. Set "shuffle":1 when they ask for a shuffle or a surprise. Do not
  reach for find or open_gallery when the thing is to be watched or listened to.
- To make an image, a sound or a video, use generate with "kind" (image, audio
  or video) and a full, self-contained "prompt". Set "app" to the appointment it
  is for only when you are sure of it - if the person did not say which
  appointment, or the room holds more than one, ask which before you generate;
  with no "app" the media waits in the Camera pool to be filed. It is slow, so
  say what you are making rather than making several at once.
- Keep every text field short and in plain, everyday words.
TXT
	return $header . $lines . "\n" . $rules;
}

# The Coding agent's prompt: the JawnOS Guide's self-healing half. It reads and
# writes the repo, runs the release routine and ships - one JSON action per turn,
# from @gb::coding_tools. Kept deliberately narrow: every verb is a fixed, safe
# operation, so the model can never reach a shell it was not handed.
sub coding_prompt {
	my $header = "You are the JawnOS Coding agent. You fix and ship the JawnOS code itself.\n"
		. "The repository is at ~/jawnos; every path you give is relative to it.\n"
		. "Reply with EXACTLY ONE JSON object and nothing else - no prose around it.\n"
		. "Choose one action:\n\n";
	my $lines = '';
	foreach my $t ( @gb::coding_tools ) {
		my $ex = $t->{'example'} || ('{"action":"' . $t->{'name'} . '"}');
		my $gap = ' ' x (length($ex) < 62 ? (62 - length($ex)) : 2);
		$lines .= '  ' . $ex . $gap . $t->{'desc'} . "\n";
	}
	my $rules = <<'TXT';
Rules:
- Work in small steps: read the file you are about to change first, then write it
  whole, then run "perl -c <file>" (or a test) to check it before you commit.
- Never commit code that failed its check. Fix it and check again.
- The finishing routine is: bump, then commit with a short message, then push,
  then restart. Do each as its own action, in that order. Commit as the subject
  "v<version> - <summary>" once bumped.
- To give the Guide a new command without a code change, use learn: it saves a
  runtime verb to the shared setting, so the Guide and every machine pick it up
  at once.
- If you cannot find a file, or the right place for one, after three attempts,
  stop and say what you tried; never invent a path or keep guessing.
- Only ever change the files the task needs. A commit stages only the files you
  wrote, so never sweep in unrelated work that was already in the tree.
- Treat the person's data as private; never print secrets (keys, tokens).
- Write plain, everyday, factual text. Do not narrate; act.
- When the work is done and shipped, reply with done and one short sentence.
- When AGENTS.md is quoted below, follow it: it is the map of this codebase.
TXT
	return $header . $lines . "\n" . $rules;
}

# The error watch's prompt: the same Coding agent, but it cannot ship. Its write
# stages a whole file for a person to look over and apply from the IDE's fixing
# panel; bump, commit, push and restart are not offered here, and it is told so.
sub coding_propose_prompt {
	my $header = "You are the JawnOS Coding agent, watching the running system for errors.\n"
		. "A fault was caught: an error in the log, or a Guide turn that did not land. Diagnose it and propose one small, complete fix.\n"
		. "You cannot ship: \"write\" stages the whole file for a person to review and apply later;\n"
		. "it does not change the repo. Do not ask for bump, commit, push or restart - they do not exist here.\n"
		. "The repository is at ~/jawnos; every path you give is relative to it. A check command runs against\n"
		. "the tree as it is, not against your staged file, so use it to look around, not to validate a change.\n"
		. "Reply with EXACTLY ONE JSON object and nothing else - no prose around it.\n"
		. "Choose one action:\n\n";
	my $lines = '';
	my %allowed = map { $_ => 1 } qw/list read run write say done/;
	foreach my $t ( @gb::coding_tools ) {
		next unless $allowed{ $t->{'name'} };
		my $ex = $t->{'example'} || ('{"action":"' . $t->{'name'} . '"}');
		my $gap = ' ' x (length($ex) < 62 ? (62 - length($ex)) : 2);
		$lines .= '  ' . $ex . $gap . $t->{'desc'} . "\n";
	}
	my $rules = <<'TXT';
Rules:
- Read the file you are about to change first; write the whole file, not a diff.
- Diagnose from the error text and the code. Keep the fix minimal, and in the
  codebase's own style.
- If the fault is not a code fix (no disk space, a permission, a network outage,
  a missing device), write nothing: reply with say and one short sentence saying
  why.
- If you cannot find the file after three attempts, say what you tried; never
  invent a path.
- Write plain, everyday, factual text. Do not narrate; act.
- When the fix is staged, reply with done and one short sentence naming the
  file(s) and what changed.
TXT
	return $header . $lines . "\n" . $rules;
}

1;
