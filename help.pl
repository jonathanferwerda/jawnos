#!/usr/bin/env perl
# The help registry: plain-language descriptions of every app, feature, device
# and cross-cutting function, keyed by a topic id. A topic is
#
#   title    - what the reader sees as the heading
#   category - 'apps' | 'features' | 'functions' | 'devices'
#   summary  - one line, used in the index and in hover enrichments
#   body     - an arrayref of paragraphs (plain text; the template escapes it)
#   related  - an arrayref of other topic ids worth reading next
#   app      - optional: the app name whose window this topic explains, so the
#              template can offer an "Open" button
#
# The registry is deliberately data, not code: adding a topic is adding a key.
# Topics are matched case-insensitively and tolerate spaces or hyphens where the
# key has underscores, so help("Start Menu"), help("start-menu") and
# help("start_menu") all resolve.

package help;

use strict;
no warnings;

our %topic = (

	# ---------------------------------------------------------------- apps
	'folders' => {
		title => 'Folders', category => 'apps', app => 'folders',
		summary => 'Browse, manage, seal and play with your files.',
		body => [
			'Folders is the file browser. It walks your media directories and shows thumbnails for images, video and audio, with a full right-click menu on every file and folder: new file and folder, rename, open, open with, copy, cut, paste, delete, shred, archive and properties.',
			'Right-click a file to seal it — encrypt it under a name of its own — and open it again from the same menu. Long jobs (moving, sealing, opening, deleting) run in the background and report their progress.',
			'Moving, sealing, opening or deleting a file carries the appointments, mail attachments and store entries that named it along with it, so nothing is left pointing at a file that is no longer there.'
		],
		related => [ 'sealing_files', 'gallery', 'backup' ]
	},
	'gallery' => {
		title => 'Gallery', category => 'apps', app => 'gallery',
		summary => 'View and organise photos, with albums and editing.',
		body => [
			'Gallery lays your images out for viewing. It reads from the same media folders as Folders and adds album grouping and a viewing surface with pan and zoom.',
			'Image functions live alongside it — cropping, resizing and the like — and a map view for images that carry a location.'
		],
		related => [ 'folders', 'marker' ]
	},
	'marker' => {
		title => 'Marker', category => 'apps', app => 'marker',
		summary => 'A layered paint board for drawing and annotation.',
		body => [
			'Marker is a layered paint board with pencil, paintbrush, spray, fill and matching erase tools, plus undo and redo, zoom and pan.',
			'It reads stylus pressure and ignores your palm on a tablet, and it autosaves so a refresh never loses a painting.'
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
		related => [ 'music', 'synth' ]
	},
	'synth' => {
		title => 'Synth', category => 'apps', app => 'synth',
		summary => 'A playable synthesiser.',
		body => [
			'Synth is a software synthesiser you play from the screen or a keyboard. It shares the studio\'s audio plumbing, so it can be routed and recorded like any other source.'
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
		related => [ 'studio', 'synth' ]
	},
	'video' => {
		title => 'Video', category => 'apps', app => 'video',
		summary => 'Play video from your media folders.',
		body => [
			'Video plays your files in the window. Playback quality is the browser\'s (or, in the desktop app, GStreamer\'s) — see the Desktop Application page for the hardware-decode setup that keeps HD smooth.'
		],
		related => [ 'gallery', 'folders' ]
	},
	'editor' => {
		title => 'Editor', category => 'apps', app => 'editor',
		summary => 'A rich text editor whose variables can answer for an appointment.',
		body => [
			'Editor is a rich text editor for letters, notes and documents. Its variables can pull live values — including values from an appointment — so a document can fill itself in from your data.'
		],
		related => [ 'ide', 'notes' ]
	},
	'ide' => {
		title => 'IDE', category => 'apps', app => 'ide',
		summary => 'A colour-coded editor for Perl, JavaScript, HTML and templates.',
		body => [
			'IDE edits code with syntax colouring for Perl, JavaScript, HTML and templates. It is what the project is developed in from inside itself.'
		],
		related => [ 'editor', 'terminal' ]
	},
	'web' => {
		title => 'Web', category => 'apps', app => 'web',
		summary => 'A browser in a window.',
		body => [
			'Web is a browser window, useful for pulling a page up beside your work without leaving the desktop.'
		],
		related => [ 'terminal' ]
	},
	'terminal' => {
		title => 'Terminal', category => 'apps', app => 'terminal',
		summary => 'A shell, in a window.',
		body => [
			'Terminal is a real shell attached to the machine running JawnOS. It is where you do the hands-on work: scripts, checks, and the occasional bit of archaeology.'
		],
		related => [ 'ide', 'process_monitor' ]
	},
	'notes' => {
		title => 'Notes', category => 'apps', app => 'notes',
		summary => 'Free-form notes you can scan, OCR and barcode.',
		body => [
			'Notes is note-taking with a document-scanning streak: it can OCR a page (Tesseract), read barcodes and QR codes (zbar), and render documents to PDF.'
		],
		related => [ 'editor', 'folders' ]
	},
	'tasks' => {
		title => 'Tasks', category => 'apps', app => 'tasks',
		summary => 'Nested checklists with colour, priority, renewal and budget.',
		body => [
			'Tasks is a nested checklist. Each item carries a colour, a priority, a renewal interval and a budget, so a task can repeat on its own and keep its own tally.',
			'Ticking an item off can record the matching appointment, so doing the thing and logging the thing are one action.'
		],
		related => [ 'appointments', 'measures' ]
	},
	'measures' => {
		title => 'Measures', category => 'apps', app => 'measures',
		summary => 'Track a value over time.',
		body => [
			'Measures records a number against a time — weight, a reading, a score — and charts it. Ranges, multiple-selects and free values are all available, and the evaluation app can read what it finds.'
		],
		related => [ 'budget', 'travel', 'evaluation' ]
	},
	'travel' => {
		title => 'Travel', category => 'apps', app => 'travel',
		summary => 'Location logging, history, distance and speed.',
		body => [
			'Travel logs where you have been and turns it into history: routes, distance covered, and speed. It draws on the device data the phone feeds in as well as anything logged by hand.'
		],
		related => [ 'measures', 'relational' ]
	},
	'relational' => {
		title => 'Contacts', category => 'apps', app => 'relational',
		summary => 'People, and the relationships between them.',
		body => [
			'Contacts is the relational app: it stores people and the measured, named relationships between them — friend, family, colleague — with a measures panel for each connection.'
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
			'The statement is drawn per account; a transaction with no account attached will not appear on it, so transactions are recorded with a real account.'
		],
		related => [ 'store', 'warehouse', 'invoices_payments' ]
	},
	'store' => {
		title => 'Store', category => 'apps', app => 'store',
		summary => 'Items, models, options, quotes and invoices.',
		body => [
			'Store is the catalogue and the paperwork. Items carry models and options, each with its own prices; a quote or invoice is built from them and prints to a white, house-styled sheet that can be delivered by email.',
			'Recording a payment against a document updates its balance and closes it when the balance reaches zero. See Invoices and payments.'
		],
		related => [ 'budget', 'invoices_payments', 'market' ]
	},
	'warehouse' => {
		title => 'Warehouse', category => 'apps', app => 'warehouse',
		summary => 'Money and goods tracked per place.',
		body => [
			'Warehouse tracks stock per place: what is where and how much of it. Packaging carries real quantities (a carton of twelve, a box of nails by weight), and shelf life means expired stock is swept up on its own.',
			'Every stock movement is journalled with its reason, and a moves ledger folds stock and money into one signed list. See The moves ledger.'
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
			'Inventory is the shared surface behind the apps: it holds the entries an app has recorded — a measure, a document, a report — and shows them together. The Evaluation reports appear here too.'
		],
		related => [ 'evaluation', 'measures', 'warehouse' ]
	},
	'mailbox' => {
		title => 'Mailbox', category => 'apps', app => 'mailbox',
		summary => 'Email over IMAP and SMTP, straight on the desktop.',
		body => [
			'Mailbox speaks IMAP and SMTP directly. Mail arrives on the desktop rather than in a separate client: a new message raises the mailbox dot in the start menu and, if no mailbox is watching, a notification.',
			'Sent mail is filed back onto the recipient\'s app, and its attachments are filed and sealed, so a document you emailed is still findable from the thing it belongs to.'
		],
		related => [ 'relational', 'store', 'sealing_files' ]
	},
	'process_monitor' => {
		title => 'Process Monitor', category => 'apps', app => 'process_monitor',
		summary => 'Live CPU and memory, per-core graphs and a process list.',
		body => [
			'Process Monitor is the system\'s own dashboard: live CPU and memory readings, per-core graphs and a sortable process list. It is how you see what JawnOS — and everything else on the machine — is actually doing.'
		],
		related => [ 'configure', 'terminal' ]
	},
	'configure' => {
		title => 'Configure', category => 'apps', app => 'configure',
		summary => 'Settings: the look, the devices, the utilities and the mesh.',
		body => [
			'Configure is where the desktop is made yours. Appearance (colour schemes, icon set, zoom, bar heights and the window border), the device lister, the utility controller and the remote-machine and mesh settings all live here.'
		],
		related => [ 'themes', 'icon_sets', 'devices_and_mesh' ]
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
			'The Box Office manages tickets — the single-use links that log a visitor in. From here you issue a ticket, set its privilege, and suspend, renew, reinstate or delete it. See Tickets for the mechanics.'
		],
		related => [ 'tickets', 'security' ]
	},
	'handbook' => {
		title => 'Handbook', category => 'apps', app => 'handbook',
		summary => 'Chaptered notes about the system itself.',
		body => [
			'Handbook is the reference shelf: chaptered pages about how JawnOS works, with diagrams. It is the longer-form cousin of this Help app.'
		],
		related => [ 'help_app' ]
	},
	'embedded' => {
		title => 'Embedded', category => 'apps', app => 'embedded',
		summary => 'The device fleet, from the desktop.',
		body => [
			'Embedded is the fleet view: it lists the JawnOS devices on your network, their purposes and models, and lets you query one or push a room to a watch, deck or board.'
		],
		related => [ 'watch', 'tdeck', 'pico', 'ble_bridge' ]
	},

	# ------------------------------------------------------------ features
	'windows' => {
		title => 'Windows', category => 'features',
		summary => 'Open, stack, move, resize, snap and minimise.',
		body => [
			'Everything that opens opens in a window. Windows stack in the order you last touched them, drag by their title bar, resize by their edge, and minimise to a small bar.',
			'The title bar\'s buttons are minimise, restore, maximise and close, and each window\'s drop-down menu adds snapping to half the screen and a move mode for precise placement. The layout of what is open is remembered and restored next time.'
		],
		related => [ 'taskbar', 'start_menu', 'help_app' ]
	},
	'taskbar' => {
		title => 'The taskbar', category => 'features',
		summary => 'A reorderable row of window slots, the clock, the start button and pins.',
		body => [
			'The taskbar is an ordered list of slots: the open windows, the clock, the start button, the search box and any apps or keyboards you have pinned. It can sit on any edge, be shown, hidden or set to auto-hide.',
			'Right-click (or long-press) the bar for its context menu: rearrange the slots in edit mode, move it, choose the clock\'s format and time zone, and add items.'
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
			'For anything longer than a label, open this Help app — press F1, or use the question-mark button in a window\'s title bar, or search here.'
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

	# ----------------------------------------------------------- functions
	'appointments' => {
		title => 'Appointments and the centre view', category => 'functions',
		summary => 'The one record everything else hangs from.',
		body => [
			'An appointment is the atom of JawnOS: a timestamped record with a type, a status, a duration and an app-specific body. Files, invoices, measurements, notes and mail are all appointments under the hood, which is why they can refer to one another.',
			'Opening one spawns a centre view that ties together everything that names it. Appointments can have alarms, recur, and be exported to a calendar.'
		],
		related => [ 'clothesline', 'tasks', 'reminders' ]
	},
	'reminders' => {
		title => 'Reminders and alarms', category => 'functions',
		summary => 'Let an appointment come back and find you.',
		body => [
			'An appointment can be given an alarm, a reminder and a recurrence, so it announces itself when its time comes and returns on schedule.'
		],
		related => [ 'appointments', 'clothesline' ]
	},
	'sealing_files' => {
		title => 'Sealing files', category => 'functions',
		summary => 'Encrypt a file under a name of its own.',
		body => [
			'Sealing encrypts a file with your credentials and gives it a name of its own, so it can be stored anywhere without being readable. It opens again from the same right-click menu in Folders.',
			'Attachments you email are sealed too, so the copy on disk is protected the same way.'
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
		related => [ 'assistant', 'inventory', 'measures' ]
	},
	'assistant' => {
		title => 'Assistant', category => 'functions',
		summary => 'Chat and image generation, plus speech.',
		body => [
			'Assistant is the AI surface: chat and image generation through local Ollama models and Cloudflare Workers AI, with speech synthesis and transcription alongside. Like Evaluation, it prefers a local model so your data stays put.'
		],
		related => [ 'evaluation', 'notes' ]
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
			'Machines reach each other across whatever network they are on, including from behind a router, and every machine can be logged into from another via a ticket.'
		],
		related => [ 'backup', 'ble_bridge', 'tickets' ]
	},

	# ------------------------------------------------------------ devices
	'watch' => {
		title => 'The T-Watch', category => 'devices',
		summary => 'A wrist clock, notifications and app buttons.',
		body => [
			'The T-Watch is the wearable: a clock that also shows notification lines and screens of app buttons, logs steps, can capture voice, and wakes when you raise your wrist to look at it.',
			'It talks to JawnOS over Bluetooth through a bridge running on a nearby phone or desktop.'
		],
		related => [ 'ble_bridge', 'tdeck', 'embedded' ]
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
		summary => 'The map you are reading now.',
		body => [
			'Help is the built-in guide. Search it, browse by category, or open it contextually: press F1 to read about the window you are focused on, or use the question-mark button in a window\'s title bar.',
			'It is arranged in four groups — apps, features, functions and devices — and each topic links to the ones worth reading next.'
		],
		related => [ 'hints', 'handbook' ]
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

# Simple case-insensitive substring search over the title, summary and body.
sub search {
	my ($q) = @_;
	return () unless defined $q && length $q;
	my $needle = lc $q;
	my @out;
	foreach my $id (sort keys %topic) {
		my $t = $topic{$id};
		my $hay = join ' ', ($t->{'title'} // ''), ($t->{'summary'} // ''), @{ $t->{'body'} // [] };
		if (lc($hay) =~ /\Q$needle\E/) {
			push @out, { id => $id, title => $t->{'title'}, category => $t->{'category'}, summary => $t->{'summary'}, app => $t->{'app'} };
		}
	}
	return @out;
}

1;
