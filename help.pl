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
		verified => '2026-10-13',
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
			'For a not-visible folder, press the lock on the toolbar, enter the combination, and it appears — at home.'
		],
		related => [ 'sealing_files', 'gallery', 'backup' ]
	},
	'gallery' => {
		title => 'Gallery', category => 'apps', app => 'gallery',
		templates => [ 'templates/apps/gallery.html.ep', 'templates/apps/gallery_album.html.ep', 'templates/apps/gallery_home.html.ep' ],
		controls => [ 'Previous', 'Next', 'Refresh', 'Repeat', 'Shuffle', 'File information', 'Fetch home', 'Set as main image', 'Albums', 'Home', 'Lock', 'Archives' ],
		verified => '2026-10-12',
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
			'The lock covers the gallery when you want it out of the way; unlock it with the combination.'
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
		summary => 'A multitrack audio studio with takes and a pedalboard.',
		body => [
			'Studio is a multitrack recorder and editor: takes, crossfades, waveform clips, and a pedalboard routed onto individual channels.',
			'It works with the same library as Music, so recorded and imported tracks sit together.'
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
		summary => 'A playable synthesiser.',
		body => [
			'Synth is a software synthesiser you play from the screen or a keyboard. It shares the studio\'s audio plumbing, so it can be routed and recorded like any other source.'
		],
		steps => [
			'Open Synth.',
			'Play the on-screen keyboard, or use a connected MIDI keyboard.',
			'Shape the sound with the controls, and record it into Studio when you have one you like.'
		],
		related => [ 'studio', 'music' ]
	},
	'music' => {
		title => 'Music', category => 'apps', app => 'music',
		summary => 'A player, a library, and the place music is organised.',
		body => [
			'Music is the player and library: artists, albums, folders and playlists, with a mute, a lock and a configuration drawer.',
			'It plays through the browser and can hand playback to a linked device, and it is where the audio output is chosen.'
		],
		steps => [
			'Open Music; the library lists artists and albums from your media folders.',
			'Click a track to play it; the transport along the top controls playback.',
			'Open the configuration drawer to choose the audio output, or to send playback to another machine on the mesh.'
		],
		related => [ 'studio', 'synth' ]
	},
	'video' => {
		title => 'Video', category => 'apps', app => 'video',
		summary => 'Play video from your media folders.',
		body => [
			'Video plays your files in the window. Playback quality is the browser\'s (or, in the desktop app, GStreamer\'s) — the desktop app page covers the hardware-decode setup that keeps HD smooth.'
		],
		steps => [
			'Open Video and pick a file from your media folders.',
			'Play, pause and scrub with the controls; go fullscreen from the player.'
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
		summary => 'A colour-coded editor for Perl, JavaScript, HTML and templates.',
		verified => '2026-10-13',
		body => [
			'IDE edits code with syntax colouring for Perl, JavaScript, HTML and templates. It is what the project is developed in from inside itself.',
			'The code button in the toolbar opens the Coding agent\'s own chatbox: ask it what to change and it edits the repo, checks the change and ships it, reporting each step. It is the same agent the Guide\'s Coding toggle drives, and the editor keeps its own conversation.'
		],
		steps => [
			'Open the IDE and choose a file from the project tree.',
			'Edit with syntax colouring and the code helpers.',
			'Save; a Perl or JavaScript change needs a restart to take effect, while a template change is live at once.',
			'Press the code button to open the Coding agent and describe a change in words.'
		],
		related => [ 'editor', 'terminal' ]
	},
	'web' => {
		title => 'Web', category => 'apps', app => 'web',
		templates => [ 'templates/web/web.html.ep' ],
		summary => 'A browser in a window.',
		body => [
			'Web is a browser window, useful for pulling a page up beside your work without leaving the desktop.'
		],
		related => [ 'terminal' ]
	},
	'terminal' => {
		title => 'Terminal', category => 'apps', app => 'terminal',
		summary => 'A shell, in a window.',
		verified => '2026-10-13',
		body => [
			'Terminal is a real shell attached to the machine running JawnOS. It is where you do the hands-on work: scripts, checks, and the occasional bit of archaeology.',
			'The code button in the toolbar opens the Coding agent\'s chatbox, so you can ask for a change in words and watch it run the commands and ship the result without leaving the terminal. It keeps its own conversation.'
		],
		steps => [
			'Open Terminal; it opens a session on the host machine.',
			'Run commands as you would in any shell.',
			'Use multiple windows or tabs for separate jobs.',
			'Press the code button to hand a task to the Coding agent.'
		],
		related => [ 'ide', 'process_monitor' ]
	},
	'notes' => {
		title => 'Notes', category => 'apps', app => 'notes',
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
		templates => [ 'templates/travel/travel.html.ep', 'public/js/manager/travel.js', 'public/js/manager/mapengine.js', 'public/js/manager/continentprinter.js' ],
		controls => [ 'Configure', 'Now', 'Delete' ],
		verified => '2026-10-12',
		summary => 'A pannable map of every map you have measured, with your history on it.',
		body => [
			'Travel logs where you have been and turns it into history: routes, distance covered, and speed. It draws on the fixes the phone feeds in as well as anything logged by hand, and lays them on a map.',
			'The map is a canvas you drag to pan and zoom with the slider (or the wheel). On it sit the measured maps you have stored — each one an image georeferenced when you measured it (a home plate plus a scale bar), so it lands at its true place on the globe. Pan toward another area and whichever of your maps covers it scrolls into view: that is how you move among the maps you have rather than looking at one at a time.',
			'Above the measured maps you can lay a tile basemap from the Map picker: OpenStreetMap, OpenTopoMap, Carto, Esri imagery, a county GIS such as Lambton, or a Custom URL. Leave it on None and nothing is fetched — the measured maps are all it needs, so it works offline.',
			'The first four services are built in and need no key — just pick one. For a county or city service (Lambton GIS, and the like) or anything else, paste the service\'s tile URL into the box next to the picker. A service that speaks {z}/{x}/{y} works; an ArcGIS service is usually …/MapServer/tile/{z}/{y}/{x} (note y before x). Where to find it: the publisher lists its map services under a REST directory (for a county, look for an "ArcGIS REST Services" or "GIS Data" page); open the layer, and the Tile link or the URL under the map is the template to copy. Google Maps and Apple Maps have no keyless tile URL — they need their own SDK — so use another service, or paste a keyed URL you already hold.',
			'Drag to move the map; a mouse wheel or a pinch zooms, and a double-tap zooms in; a trackpad\'s two-finger scroll pans it. The red marker is the machine\'s current position (the same point navigation keeps fresh); the smaller labelled dots are the places the continent knows.',
			'To set a map up: upload the picture, set its function to map on the appointment, and the measuring tools appear under it — Scale (click the two ends of the scale bar, with its legend typed in) and Location (the home plate). Read legend lifts the scale number off the picture with OCR; Ask vision sends the picture to your Vision model (Configure → Plat) and comes back with the scale bar placed, the legend read (turned into metres), and a tilt. The Tilt box turns the picture straight — with a live preview — if its screenshot was taken rotated, so it lands level on the map.',
			'The continent desktop background draws the same map: your current position in relation to every map you have measured. Its now button (or a double-click on the background) centres it back on you.'
		],
		steps => [
			'Open Travel. The view frames your maps and your current position.',
			'Drag to pan; scroll or pinch to zoom, and double-tap to zoom in. Your maps scroll into view as you go.',
			'Pick a built-in Map source (OpenStreetMap, OpenTopoMap, Carto, Esri), or paste a tile URL for Lambton or Custom — see where to find one in the words above.',
			'Use the map selector to choose the current map and the trash to delete one; Search and the Start/End times scope the history shown.',
			'Set Home Plate to mark the place your maps share as their reference.'
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
		summary => 'Statement, budgets, a document ledger and a daily sheet.',
		body => [
			'Budget turns your transaction history into something you can look at: a statement of what has moved, budgets to hold it against, a document ledger of invoices and quotes, and a daily sheet.',
			'The statement is drawn per account; a transaction with no account attached will not appear on it, so transactions are recorded with a real account. The window and its scope (hour, day, week, month, year) come from the app\'s own settings, so a view you set up is the view you come back to.'
		],
		steps => [
			'Open Budget; it lands on the statement for the current scope.',
			'Change the scope along the top to widen or narrow the window — hour, day, week, month, year.',
			'Add or edit budgets so the statement has something to hold the movement against.',
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
		title => 'Market', category => 'apps', app => 'market',
		summary => 'Trade in the things you stock and sell.',
		body => [
			'Market is the trading side of the warehouse and store: vendors, buyers and the deals between them, drawing on the same items and prices.'
		],
		related => [ 'warehouse', 'store' ]
	},
	'inventory' => {
		title => 'Inventory', category => 'apps', app => 'inventory',
		summary => 'An app\'s own record of what it holds and has been up to.',
		body => [
			'Inventory is the shared surface behind the apps: it holds the entries an app has recorded — a measure, a document, a report — and shows them together, with statistics and the Evaluation reports.'
		],
		related => [ 'evaluation', 'measures', 'warehouse' ]
	},
	'mailbox' => {
		title => 'Mailbox', category => 'apps', app => 'mailbox',
		summary => 'Email over IMAP and SMTP, straight on the desktop.',
		body => [
			'Mailbox speaks IMAP and SMTP directly. Mail arrives on the desktop rather than in a separate client: a new message raises the mailbox dot in the start menu and, if no mailbox is watching, a notification.',
			'Sent mail is filed back onto the recipient\'s app, and its attachments are filed and sealed, so a document you emailed is still findable from the thing it belongs to. Alongside email it carries SMS, the internal message and paper-route system, and the Pen assistant.'
		],
		steps => [
			'Open Mailbox and choose a section from the sidebar — sms, email, list, dial, pen or tickets.',
			'For email, pick a folder (contacts, inbox, drafts, outbox, sent) and an address.',
			'Compose with the new-file button; attachments are filed and sealed when you send.'
		],
		related => [ 'relational', 'store', 'sealing_files', 'assistant' ]
	},
	'process_monitor' => {
		title => 'Process Monitor', category => 'apps', app => 'process_monitor',
		templates => [ 'templates/monitor/monitor.html.ep', 'public/js/manager/monitor.js' ],
		summary => 'Live CPU and memory, per-core graphs and a process list.',
		body => [
			'Process Monitor is the system\'s own dashboard: live CPU and memory readings, per-core graphs and a sortable process list. It is how you see what JawnOS — and everything else on the machine — is actually doing.'
		],
		steps => [
			'Open Process Monitor.',
			'Read the headline CPU and memory figures along the top.',
			'Sort the process list by CPU or memory to find what is busy.'
		],
		related => [ 'configure', 'terminal' ]
	},
	'configure' => {
		title => 'Configure', category => 'apps', app => 'configure',
		verified => '2026-10-12',
		summary => 'Settings: the look, the devices, the utilities and the mesh.',
		body => [
			'Configure is where the desktop is made yours. Appearance (colour schemes, icon set, zoom, bar heights and the window border), the device lister, the utility controller and the remote-machine and mesh settings all live here.',
			'The Misc panel holds the routine settings, and its Speech section sets which voice the desktop speaks with — the neural Piper voices (LJSpeech, LibriTTS-R, Alba) or an eSpeak fallback, each chosen per device.'
		],
		steps => [
			'Open Configure.',
			'Use the tabs to move between appearance, devices, utilities and the mesh.',
			'The Plat tab holds every AI model choice and provider key.',
			'For speech, pick a Say voice under Misc and press Preview to hear it.',
			'Changes save as you make them; a bar or theme change is felt at once.'
		],
		related => [ 'themes', 'icon_sets', 'devices_and_mesh', 'platform', 'assistant' ]
	},
	'security' => {
		title => 'Security', category => 'apps', app => 'security',
		summary => 'Passwords, pseudonyms, QR codes, screen lock and secrets.',
		body => [
			'Security gathers the safety tools: password and pseudonym generation, QR codes, encryption helpers, screen locking and a keyring-style secret store.',
			'It also shows the neighbour links — which machines are trusted, and with what privilege.'
		],
		related => [ 'box_office', 'devices_and_mesh', 'sealing_files' ]
	},
	'box_office' => {
		title => 'Box Office', category => 'apps', app => 'box_office',
		summary => 'Issue, suspend, renew and revoke tickets.',
		body => [
			'The Box Office manages tickets — the single-use links that log a visitor in. From here you issue a ticket, set its privilege, and suspend, renew, reinstate or delete it.'
		],
		steps => [
			'Open the Box Office.',
			'Issue a new ticket and choose its privilege — citizen, resident or guest.',
			'Copy the link and give it to whoever needs it.',
			'Suspend, renew or delete a ticket from the same list when it is no longer wanted.'
		],
		related => [ 'tickets', 'security' ]
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
		verified => '2026-10-12',
		summary => 'The device fleet, from the desktop.',
		body => [
			'Embedded is the fleet view: it lists the JawnOS devices on your network, their purposes and models, and lets you query one, push a room to a watch, deck or board, and set how a device behaves.',
			'Picking a device shows its controls: its name, Now Me (send it a fresh copy of its settings and screens) and Query (ask a board what it is). A watch row also carries the Voice select, which chooses how the watch listens (see Voice and wake words), plus its room count and screen timeout.'
		],
		steps => [
			'Open Embedded to list the devices on your network.',
			'Use Scan to re-discover devices, or Query on a row to ask one board what it is.',
			'Push a room to send a screen of buttons to a watch or deck.',
			'On a watch row, set the Voice select to choose what it listens for, then press Now Me to push the change.'
		],
		related => [ 'watch', 'tdeck', 'pico', 'ble_bridge', 'voice' ]
	},

	# ------------------------------------------------------------ features
	'voice' => {
		title => 'Voice and wake words', category => 'features',
		templates => [ 'templates/embedded/embedded.html.ep', 'public/js/manager/embedded.js' ],
		verified => '2026-10-12',
		summary => 'Speak to the watch; it listens for a phrase and files the rest.',
		body => [
			'The watch can listen for you and, when it hears speech (or its wake phrase), record a short clip and send it to JawnOS over Bluetooth or Wi-Fi. JawnOS transcribes the clip: a recognised command runs, and anything else is kept as a note you can sort out later.',
			'How the watch listens is the Voice setting on the watch row in the Embedded panel. There are four choices: Voice: Off (it does not listen), Voice: Any speech (VAD) (it starts a clip as soon as it hears any speech), and a wake word - Voice: Hey Jawn or Voice: Jawn Do - which waits for that phrase and records what follows.',
			'The wake words are custom phrases trained for JawnOS rather than stock ones, so "Hey Jawn" and "Jawn Do" are the phrases it knows; the any-speech setting is the fallback that needs no phrase at all.'
		],
		steps => [
			'Open Embedded and find the watch in the device list.',
			'Set the Voice select on its row to Voice: Off, Voice: Any speech (VAD), Voice: Hey Jawn or Voice: Jawn Do.',
			'The choice is pushed to the watch as a fresh Now Me, and the watch starts listening in that mode.',
			'Speak: a command runs, and anything else is saved as a note.'
		],
		related => [ 'watch', 'embedded', 'notes', 'ble_bridge' ],
		prompt => 'Describe the Voice select on the watch row in the Embedded panel and its four choices exactly: Voice: Off, Voice: Any speech (VAD), Voice: Hey Jawn, Voice: Jawn Do. Only those two phrases are trained - do not name any other wake word.'
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
			'Right-click (or long-press) the bar for its context menu: rearrange the slots in edit mode, move it, choose the clock\'s format and time zone, and add items.'
		],
		steps => [
			'Right-click the bar to open its context menu.',
			'Turn on edit mode to rearrange the slots and pins.',
			'Or use Position to move the bar, and Autohide to tuck it away.',
			'Set the clock\'s format and time zone from the same menu.'
		],
		related => [ 'start_menu', 'dock', 'windows' ]
	},
	'start_menu' => {
		title => 'The start menu', category => 'features',
		summary => 'Recently used apps, a category rail and a search.',
		body => [
			'The start menu opens on the apps you used most recently, with a category rail (accessories, business, games, media, system) for the whole catalogue.',
			'Its pages also cover what is running, what is upcoming and what is expiring, plus a System view. A search box can ride the menu, the taskbar or the dock. A new message raises a dot on the menu\'s mailbox icon.'
		],
		steps => [
			'Press the start button to open the menu.',
			'Use the category rail to narrow the catalogue, or the search box to find an app by name.',
			'The menu\'s other pages show running, upcoming, expiring and system.',
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
		summary => 'A rail that hangs the routines belonging to this hour.',
		body => [
			'The clothesline runs along the top of the desktop and hangs the routines and rituals that belong at the current hour, in the order they usually happen.',
			'It can hang the ones your history shows you actually do, automatically, and each hang is configured per app: a schedule, a budget, and the time slots it belongs to.'
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
			'For anything longer than a label, open this Help app — press F1, or use the question-mark button in a window\'s title bar, or search here. The Help agent can then walk you through it.'
		],
		related => [ 'help_app', 'start_menu' ]
	},
	'themes' => {
		title => 'Colour schemes', category => 'features',
		summary => 'Named palettes, each in a light and a dark cut.',
		body => [
			'JawnOS ships a set of named colour schemes — Blue, Graphite, Green, Indigo, Steel, Amber, Teal, Plum and Rose — and each has a light and a dark cut, so the chrome can range from near-white to near-black.',
			'They live under Configure. The dark cuts change the window surfaces most, because the chrome is derived from the manager surface.'
		],
		related => [ 'icon_sets', 'zoom', 'configure' ]
	},
	'icon_sets' => {
		title => 'Icon sets', category => 'features',
		summary => 'A choice of looks for every icon, hand-drawn by default.',
		body => [
			'Every icon can be swapped between a set of looks — from the original hand-drawn artwork through cleaner, flatter and frankly sillier sets. The default is the hand-drawn one.',
			'Pick one under Configure; the whole interface follows, including the window controls.'
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
		templates => [ 'templates/configure/utility_controller.html.ep' ],
		controls => [ 'Run this job', 'How often', 'Good', 'Bad' ],
		verified => '2026-10-12',
		summary => 'The background jobs every machine runs, and how often.',
		body => [
			'Configure → Sys holds the Utility controller: one card per machine on the mesh, and under each card its background jobs — the utilities. A job has a switch to run it, a box for how often, the time it last ran, and a good/bad dot.',
			'The dot is good (green) while the job has last run within five of its intervals, and bad (red) once it has not. A job that throws or runs past its timeout is stopped and logged rather than retried, and simply waits for its next turn.',
			'The jobs include backups, email send and receive, the tunnels, the remote-machine sync, navigation, the alarm haircut, the budget pass, tasks, warehouse expiry, the battery sample (htop) and a manager tick. A few only do anything on a handheld — SMS, the telephone check and navigation.',
			'It is per machine: an interval or a switch set here applies to the machine whose card it is on, so one job can run every two minutes on the phone and hourly on the server.'
		],
		steps => [
			'Open Configure and press Sys; the Utility controller is in that panel.',
			'Find the machine whose jobs you want to change.',
			'Tick the switch to run a job, and set its interval in the box beside it (for example 2m).',
			'Watch the last-run time and the good/bad dot to see whether it is keeping up.'
		],
		prompt => 'Explain the Utility controller in Configure → Sys: one card per machine, each background job with a run switch, an interval box, a last-run time and a good/bad dot. Good means it has run within five intervals; bad means it has not. A failing job waits its interval instead of retrying. Everything is per machine, so an interval on one machine does not move another. Do not invent job names beyond the ones listed.',
		related => [ 'configure', 'backup', 'devices_and_mesh', 'process_monitor' ]
	},
	'navigation' => {
		title => 'Navigation (location logging)', category => 'features',
		templates => [ 'templates/appointment_details.html.ep', 'templates/appointment_wrapper.html.ep', 'public/js/manager/travel.js' ],
		verified => '2026-10-12',
		summary => 'JawnOS records where a device is on a schedule, screen on or off.',
		body => [
			'Navigation is the autonomous location log. On a handheld the backend asks for a fresh GPS fix once per navigation interval — whether or not the app is open and whether or not the screen is on, since the phone holds a wake lock for it — and writes that one point down as the machine\'s current position.',
			'An app can also carry its own pace. An app\'s navigation setting is none (never log), once (log only when you act on it), or an interval such as 1m. While an appointment of that app is running, a fix is filed against it at that interval — never faster than the navigation interval itself (the utility\'s own pace in the Utility controller), which is the real ceiling.',
			'Those filed fixes are the Distance list on the appointment: open its details and the Distance section lists each point with its distance from home, the metres since the last one, and the speed between them.',
			'Navigation also drives the home plate: when the device crosses a home plate\'s radius, that plate\'s duty can start or stop the matching appointment on its own.'
		],
		steps => [
			'Give an app a navigation value in its settings: none never logs, once only logs when you act, and an interval (like 1m) logs while one of its appointments is running.',
			'Start an appointment of that app and carry the device; the backend files a fix each navigation interval.',
			'Open the appointment and read its Distance list for the points, the distance and the speed.',
			'Set a home plate and a duty on it to let crossing that radius start or stop the appointment by itself.'
		],
		prompt => 'Explain JawnOS navigation: the backend logs one GPS fix per navigation interval, screen on or off, while the phone holds its wake lock; the per-app navigation setting is none / once / an interval; and filed fixes appear in the appointment\'s Distance list (distance from home, metres since the last, speed). The utility interval is the ceiling — a 1m per-app setting still only gets a point about as often as the utility runs. Do not describe it as a live map, and never guess a person\'s actual location.',
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
	'platform' => {
		title => 'Platform (AI providers)', category => 'functions',
		summary => 'Choose the model each assistant uses, add provider keys, and teach the Guide runtime commands.',
		verified => '2026-10-13',
		body => [
			'Configure → Plat gathers every AI choice in one place: which model each assistant uses, and the key or account each provider needs.',
			'Providers include the local Ollama, Cloudflare Workers AI, OpenAI, Anthropic (Claude), Google (Gemini), xAI (Grok), DeepSeek, Mistral, Groq and OpenRouter. A model is addressed as provider:model — a bare name goes to Ollama, and @cf/… to Cloudflare.',
			'Secret keys are stored encrypted and are never shown back: a key that is set reads “••• set”, and typing a new value replaces it.',
			'Guide commands (runtime) is where you teach the Guide new verbs without a code change. Each is a JSON entry naming a primitive — say, open_app, set_setting, run_command, toggle, stage, find or play_music — and its parameters. The list is a setting, so it syncs to every machine and they all learn the verb.'
		],
		steps => [
			'Open Configure and press Plat.',
			'Under Agent models, pick the model each assistant should use — the Help guide, Evaluation, Vision, Image generation, the Pen and Coding. Each list only offers models that fit the role, so a text assistant is not offered a vision-only model and the Vision role is not offered a plain text one; a model already chosen stays listed even if it does not fit. Each choice is marked free or paid. A provider that runs out of credit has its paid models hidden and its chats step down to a free model until the account is topped up.',
			'Under Provider access, paste the key or account for each provider you want to reach. A field that already shows “••• set” is kept unless you type a new value.',
			'Under Guide commands, add a verb as a JSON entry and press Save — every machine picks it up.'
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
			'One machine can also tell another what to do: name it and say the task — "on the table, play Friends" — and the command is read by that machine\'s own guide there, so it runs on that machine without the words leaving the mesh. The Assistant\'s remote_control panel has a box for the same thing.'
		],
		verified => '2026-10-13',
		related => [ 'backup', 'ble_bridge', 'tickets' ]
	},

	# ------------------------------------------------------------ devices
	'watch' => {
		title => 'The T-Watch', category => 'devices',
		summary => 'A wrist clock, notifications and app buttons.',
		body => [
			'The T-Watch is the wearable: a clock that also shows notification lines and screens of app buttons, logs steps, wakes when you raise your wrist to look at it, and can listen for a voice command.',
			'Its listening mode - off, any speech, or a wake word such as Hey Jawn or Jawn Do - is set from the watch row in the Embedded panel; see Voice and wake words.',
			'It talks to JawnOS over Bluetooth through a bridge running on a nearby phone or desktop.'
		],
		related => [ 'voice', 'ble_bridge', 'tdeck', 'embedded' ]
	},
	'tdeck' => {
		title => 'The T-Deck', category => 'devices',
		summary => 'A handheld terminal with a keyboard and GPS.',
		body => [
			'The T-Deck is the handheld: a keyboard, a touch screen and GPS in a device small enough to carry. It acts as a handheld terminal — a "teletype" — for the machine it is talking to, and it can report where it is.'
		],
		related => [ 'watch', 'pico', 'ble_bridge' ]
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
		body => [
			'The devices speak Bluetooth Low Energy, but JawnOS itself is reached over the network, so a small bridge sits in between: a Bluetooth central (on a phone, or on a desktop) that links to a device and relays messages to and from JawnOS over a local socket.',
			'The bridge is the same piece of software on both platforms, so a watch links to whichever machine is in range and can bring its own apps with it.'
		],
		related => [ 'watch', 'tdeck', 'pico' ]
	},
	'help_app' => {
		title => 'This Help app', category => 'features',
		summary => 'The map you are reading now, and its guide.',
		verified => '2026-10-13',
		body => [
			'Help is the built-in guide. Search it, browse by category, or open it contextually: press F1 to read about the window you are focused on, or use the question-mark button in a window\'s title bar. It already knows what you were looking at when you asked.',
			'Each topic hands you to the Guide along the foot: pick a model and ask. It answers in a chat, and it can also act on the screen. "Show me pictures of George Michael" searches your records and opens the photo browser on them; "how far have I walked this month" and "when am I expected to be 180" are read from your own logs; "show Sarnia on a map" centres the travel map; "where was I on September 18th" reads the recorded place fixes; and "play Ben Folds Five" starts the track. It reports each step as it goes.',
			'It writes only with your say-so: the Confirmation Requirement. Ask it for an appointment and it stages the proposal and shows you what it would save; nothing is written until you confirm. The Guide\'s associate - the small chat in the corner - carries a Confirm tick beside its close button: untick it and the Guide saves what it proposes without asking. It never sends, pays or deletes.',
			'A thing you have marked not-visible is neither named nor opened here unless its padlock is open and you are at home, so a hidden album stays hidden out in public.',
			'It can also tell another of your machines what to do, by name - "on the table, play Friends" - and that machine\'s own guide reads the command there, so it stays on that machine.',
			'You can speak instead of typing: if you press Send with the box empty, the guide starts listening, and Stop turns what you said into words in the box. It uses the same speech-to-text the watch uses.',
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
	my $rules = <<"TXT";
Rules:
- Navigate and search only. Never delete, send, pay, or change any data.
- Choose only from the actions listed above; there is no other verb here.
- When the person names something you should show them, use find first, then open
  what the result points at. If find returns an app, pass that exact app name to
  open_gallery - do not hand open_gallery a free-text name instead.
- The moment an OBSERVATION shows the thing they asked to see or do is now on
  screen, STOP and reply with done - for example
  {"action":"done","text":"Here are the photos."}. Do not follow a success with a
  question; the task is finished, so say so briefly and stop.
- If a search turns up nothing, say so or ask a short question - do not keep
  searching the same way.
- Read the OBSERVATION lines in the conversation to see what each action did
  before choosing the next one.
- For "when did I last see/do X", use find and answer from its last date - do not
  guess a date.
$create_rule
- "Where was I" and "when did I last see X" are different questions. For a place
  at a time, use where_when with an absolute date. For a record or photo, use find.
- For "show me <place> on a map", use show_place - it works offline from the
  places we have measured, so an odd name is matched against the things named for it.
- For "how far did I walk" use measure with measure "walk"; for a weight goal use
  measure with measure "weight". Do not guess a number - always take it from measure.
- For music, use play_music with the artist and track; it plays the first match.
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

1;
