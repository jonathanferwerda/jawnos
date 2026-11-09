# Help registry part 3 of 9: People, notes, tasks, measures, travel and money.
package help;

use strict;
our %topic;

$topic{'people'} = {
		title => 'People', category => 'apps', app => 'people',
		templates => [ 'templates/apps/people.html.ep', 'templates/apps/people/body.html.ep', 'templates/apps/people_person.html.ep', 'public/js/manager/people.js' ],
		controls => [ 'Scan my crest', 'Take picture', 'Upload a photo', 'Download card', 'Save card here', 'Show QR', 'Write to NFC tag', 'Import a crest card', 'Import a crest code', 'I have met this crest', 'Save name', 'Verify a photo', 'Refresh', 'Publish', 'Published', 'Upload a logo', 'Open their page' ],
		verified => '2026-10-30',
		summary => 'The house crest, and the people the house knows.',
		body => [
			'People holds the house crest: the one hand-drawn picture that names it to other houses. The picture is what a person recognises; it is not the proof. A house key signs a record that pins the drawing\'s hashes, and the short fingerprint on the card is what another house compares. Keep the original drawing - the scan is a copy.',
			'Scan your own crest on the flatbed, or upload a photograph from a device with no scanner. The scan is normalized, its hash is recorded, and both the colour original and the matching reference are sealed like a photo. Re-scan after the paper ages or creases: the same key signs the new reference, so the house does not change.',
			'Download card writes a signed card for this house: the record, a small copy of the drawing, and the vouches this house has given. Give that file to a house you have met. Import a crest card takes the card they give you, checks its signature and the drawing against the signed hash, and lists the house. I have met this crest signs a vouch of your own for that house; its scope is communication, not physical access. If the card came with an introduction from a house you already know, the row says so; a card with no introduction is only a claim.',
			'Show QR puts the compact signed record into a QR code: name, key, fingerprint, drawing hash and signature, without the picture or the vouch chain. The same code can be copied from the box under the QR and written to an NFC tag with an NFC writer; an NTAG215 or larger holds the compressed code, while a tiny NTAG213 does not. The full card file is still the one that carries the picture.',
			'Save card here writes the card into Downloads on this machine, which is the reliable path in the desktop app. Write to NFC tag writes the compact code onto the tag the phone is touching; tapping a crest tag anywhere in the app imports that house and the status appears under the crest.',
			'The line under the crest names the address other houses can reach this one at: the configured domain, or this machine\'s private network address when there is no domain. A house with neither still has a crest - the drawing and the fingerprint identify it in person - it just cannot be looked up until an address is known.',
			'The house\'s other machines can each back the crest. A machine signs a small statement naming the crest\'s id, house key and fingerprint with its own peer key, and hands it to the others; each keeps it on that machine\'s roster row. The Me panel lists the machines that have confirmed the crest, and the card carries their signatures. A machine that joins later adds its signature on its next pass, and a re-scan needs no new signature because the statement names the house, not the drawing\'s latest hash.',
			'Open a crest in Other houses (or tap its NFC tag) to see the drawing, name and fingerprint, then use Homepage, Store or Message. The panel names the address the other house says it can be reached at. Linking a crest to one of the house\'s contacts puts that crest beside the person in Chat and Mail. The address buttons come from the card the house gave you.',
			'Look up their constructs asks the other house, at that address, what it publishes. This house presents its own crest code, the other house answers with a record signed by its crest key, and the panel lists the constructs it made public with their member names and the time of the answer. The answer is kept on the crest, so opening it again shows the last lookup without asking again.',
			'Publishing is a choice on each construct row in its tab. Publish offers that construct to houses that look this one up; Published means it is already being offered, and pressing it again withdraws it. A lookup reveals only the construct\'s name and the names of its members - never a permission, a record or a way in. The choice is kept per device, the same public toggle the appointment itself carries, so the machine you are using can answer for its own constructs. People consolidates the rows it holds: the most recent choice across the house is the one the construct row shows, and the one a lookup answers with.',
			'A construct can carry its own crest or logo. Open its row in a construct tab and press Upload a logo. The picture is normalized and signed with the house key, and the record names the construct and the house that made it, so it is the same kind of signed record as the house crest, with its own card and compact code. The construct row shows the logo in place of its initial. Download card, Show QR and Write to NFC tag work for it, and a phone can write that code to a tag. A tag written for one of this house\'s constructs opens that construct when it is tapped; a tag for another house\'s construct is imported as that house\'s construct, provided its house crest is already known.',
			'Another house\'s construct is read-only here. Its row says which house it came from, offers that house\'s page when the crest names an address, and cannot be published, given a logo, or edited in Relational. Its identity is the construct crest\'s id, not its name, so two houses can both have a Garden Club; when the name is already taken locally the row\'s key is suffixed with the house, while the name shown stays the one the other house uses.',
			'Verify a photo compares a fresh photograph with the stored reference and reports a distance; the person confirms. A photocopy still looks like the drawing - the signed record, not the paper, is what proves the house.',
			'The window is tabbed: Me is the house crest and its card; People is every person the house knows; then a tab for each social construct - Communities, Clubs, Teams, Projects, Institutions, Governments, Corporations, Places, Vendors and Events. The strip scrolls sideways, and each tab counts what it holds.',
			'A person is a person construct in Relational. The moment one exists, its People row is made for it, and the row goes away when the construct is deleted; changing a construct from person to idea only hides it, so a mistaken change does not lose the identity behind it. A person\'s row shows their crest (when one is linked), the app name they are known by, and chips for the constructs they belong to. A chip opens that construct\'s tab on their row.',
			'Clicking a person opens their card. Their own main picture is the portrait; when a crest is linked it sits beside it. The card carries no scan, upload, card, QR, NFC or rename controls - the drawing belongs to their house. It offers Homepage, Store, Message, I have met this crest, a control to link a known crest, and Open Relational, which starts Relational already focused on that person. The card also carries the person\'s Relationship: Self, Friend, Stranger or Enemy. It is a configuration, like a place\'s private/public/dangerous setting, not a measure: one choice per person, numbered on the place scale (Self and Friend 1, Stranger 2, Enemy 3). An Enemy in the house\'s local presence starts a lockdown: other apps close, and only Security stays open until the Enemy\'s running appointment is stopped.',
			'Each construct tab lists the constructs of that kind and their members. A row opens to show who belongs to it, the names it answers to, and its crest controls. Relational is where the structure itself is made and changed; People reads it.',
			'A construct can answer to more than one name. Open its row and type another name under Also called; that name then works in the Guide, on the watch and in commands sent to another machine. The x beside a name forgets it. A word that already means something else is refused, because it would make every use of that word a question; another house\'s construct is read-only here, so its names stay its own.'
		],
		steps => [
			'Open People from the start menu. Me holds the house crest; People lists the people, and the construct tabs list the constructs they belong to.',
			'To make a person, add them in Relational; the People row follows automatically.',
			'On a person\'s card, set Relationship to Self, Friend, Stranger or Enemy; the choice is kept as a configuration setting and read by the visibility rule and the phone\'s call-flow matrix.',
			'Place the drawing flat on the scanner, or choose Upload a photo.',
			'Press Scan my crest; the flatbed reads one page.',
			'Type the house name and press Save name.',
			'Check the fingerprint under the crest; that is what another house compares.',
			'Press Download card and give the file to a house you are meeting.',
			'Press Save card here to keep a copy in Downloads; in the desktop app that is the copy that actually lands somewhere.',
			'Press Write to NFC tag and hold an NTAG215 to the phone; tapping that tag later imports the house.',
			'Press Show QR to show or copy the compact code.',
			'Press Publish on a construct row to offer it to other houses; Published turns it back off.',
			'Open a construct row and press Upload a logo to give that construct its own crest.',
			'Open a construct row, type another name under Also called and press Enter; the x beside a chip forgets that name.',
			'When they give you their card, press Import a crest card, choose the file, then press I have met this crest.',,
			'Tap a crest in Other houses to open it; Homepage and Store open its public pages, and Message opens the linked contact.',
			'Press Look up their constructs to ask that house, at its address, what it publishes.',
			'To label a construct in the world, press Write to NFC tag on its row and hold an NTAG215 to the phone; tapping that tag opens the construct.',
			'Use the Link control in that panel to put the crest beside a person in Chat and Mail.',
			'After the paper ages, scan it again; the new reference is signed with the same key.',
			'To check a photograph later, press Verify a photo and read the distance.'
		],
		related => [ 'security', 'scanning', 'mailbox' ]
	};
$topic{'notes'} = {
		title => 'Notes', category => 'apps', app => 'notes',
		templates => [ 'templates/notes/notes.html.ep', 'public/js/manager/notes.js' ],
		verified => '2026-11-02',
		summary => 'Free-form notes filed under six categories or Uncategorized, each open or completed, and the drafts of notes being typed in an appointment.',
		body => [
			'Notes is the house\'s free-form notebook. Every note is a row of its own, newest first: a watch that heard something that was not a command lands here, and so does anything typed in the box at the foot.',
			'A note is filed under one of six categories, or under Uncategorized when it names none. Uncategorized is the default in the picker, so a note typed without choosing a category stays Uncategorized rather than being called something it is not; older notes stamped Journal by an earlier version keep reading as Journal. Journal is a day\'s thought; Roadmap is where you are going; Social is people, communities and clubs; Shopping is the shopping list; Dreams is the dream journal; and JawnOS collects ideas and bugs for JawnOS itself, which the nightly agent reads. The chips along the top name every category, Uncategorized included, with the number of notes it holds - press one to read just that value, or All for everything. The picker above the box is what the note being saved is filed under, and opening a note for editing moves the picker to that note\'s category.',
			'Every note also carries a status. A new note is Open; when the Coding agent has done the work a note asked for, it marks the note Completed. The badge beside the note says which, a completed note keeps its place in the list with its words faded and struck through rather than disappearing, and the small editor on each row changes the category or the status in place. Both ride the house sync like the words.',
			'Four categories hand off to the app they belong with. With one of those chips showing, an Open button sits beside the chips: Open Store for Roadmap, Open Market for Shopping, Open Dreams for the Handbook\'s Today, where dreams are planted, and Open People for Social. Journal and JawnOS stay in Notes.',
			'Notes ride the house sync, so a note written on one machine appears on the rest. Click a note to load it into the box for editing, drag one onto an appointment window to fold it into that app\'s notes, and the X is a two-click delete. A deleted note is tombstoned rather than erased: the row stays so every machine learns it is gone, but it is not listed again.',
			'While an appointment\'s Notes field is being typed into, the words are kept as a draft: this browser holds a copy on every keystroke, against a crash or a refresh, and the house holds one in this same table so it reaches every machine. A draft belongs to no category - it is not a note you filed - so it is marked Draft instead of carrying a chip\'s name, and the appointment name beside it says where it came from. The draft is rewritten in place as the words grow - it is one row, not a new note per save - until the appointment is saved, which clears it.',
			'A browser that still held older notes in its own storage hands every non-empty one over the first time it opens the manager after this, so they turn up here under their appointment names instead of having to be found by hand. A draft the house already has is kept, so an old copy cannot undo newer words. A note that was written before categories existed reads as a Journal note.'
		],
		steps => [
			'Open Notes and type in the box at the foot; press Save (Enter saves on a desk, Shift+Enter makes a line).',
			'Choose the category in the picker before saving - Uncategorized is the default; a note written while a category chip is showing is filed under that value.',
			'Press a chip to read one category (Uncategorized included), or All for every note with its count beside it.',
			'Press the Open button beside the chips to go on to Store for Roadmap, Market for Shopping, the Handbook\'s Today for Dreams or People for Social.',
			'Click a note to load it into the box and edit it; saving updates that row.',
			'Use the small editor on a note to change its category or its status (Open or Completed) in place.',
			'Drag a note onto an appointment window to fold it into that app\'s notes.',
			'Press X twice to delete a note.'
		],
		related => [ 'editor', 'folders', 'handbook', 'store', 'market', 'people' ]
	};
$topic{'tasks'} = {
		title => 'Tasks', category => 'apps', app => 'tasks',
		summary => 'Nested checklists with colour, priority, renewal and budget.',
		verified => '2026-10-16',
		body => [
			'Tasks is a nested checklist. Each item carries a colour, a priority, a renewal interval and a budget, so a task can repeat on its own and keep its own tally.',
			'Ticking an item off can record the matching appointment, so doing the thing and logging the thing are one action.',
			'A task\'s colour fills its row, and the desktop composes that colour with its own theme, so the row still reads as that task while its name, its fields and the numbers in it stay legible in a light or a dark theme. The row under the list - Sort, Filter and the totals - is the app\'s own surface, not a task\'s colour, so it looks the same after a change is saved as it did when the list was opened.'
		],
		steps => [
			'Open Tasks and add a list.',
			'Add items; nest related ones under a parent to build a checklist.',
			'Give an item a colour, a priority, a renewal interval or a budget as needed.',
			'Tick an item off — if it is set to, the matching appointment is recorded for you.'
		],
		related => [ 'appointments', 'measures' ]
	};
$topic{'measures'} = {
		title => 'Measures', category => 'apps', app => 'measures',
		summary => 'Track a value over time.',
		body => [
			'Measures records a number against a time — weight, a reading, a score — and charts it. Ranges, multiple-selects and free values are all available, and the evaluation app can read what it finds.',
			'Each row in the window is a unit the house knows. Attach one to a measure an app records, and the PV column shows that app\'s latest value. Currency and coin rows take their PV from the live rate snapshot the Crypto panel reads: one unit valued in the house\'s reporting currency, with the coins the Crypto panel offers getting a row of their own. The column fills when the snapshot refreshes and whenever this window opens, so a price is readable here without visiting the panel.',
			'The keyboard\'s calculator uses the same units: type a quantity such as 32.33L or 5jpy and every other unit of that kind is offered beside it.'
		],
		steps => [
			'Open Measures and pick the kind of value: a range, a multiple-select, or a free number.',
			'Record a reading; it is timestamped and added to the chart.',
			'Change the scope to look back over a day, a week, a month or a year.'
		],
		related => [ 'budget', 'travel', 'evaluation' ]
	};
$topic{'travel'} = {
		title => 'Travel', category => 'apps', app => 'travel',
		templates => [ 'templates/travel/travel.html.ep', 'public/js/manager/travel.js', 'public/js/manager/mapengine.js', 'public/js/manager/mapmarkers.js', 'public/js/manager/continentprinter.js' ],
		controls => [ 'Configure', 'Now', 'Delete', 'Guess the gaps' ],
		verified => '2026-10-30',
		summary => 'A pannable map of every map you have measured, with your history on it.',
		body => [
			'Travel logs where you have been and turns it into history: routes, distance covered, and speed. It draws on the fixes the phone feeds in as well as anything logged by hand, and lays them on a map.',
			'The map is a canvas you drag to pan, and zoom with a wheel or a pinch. On it sit the measured maps you have stored — each one an image georeferenced when you measured it (a home plate plus a scale bar), so it lands at its true place on the globe. Pan toward another area and whichever of your maps covers it scrolls into view: that is how you move among the maps you have rather than looking at one at a time, and where two maps overlap the finer one lies on top.',
			'The configuration row is pinned to the top of the window: scroll the view down and the Home Plate and Update buttons, the Maps menu, the Map picker and the Start/End times stay in reach. The gear tucks the row away.',
			'Above the measured maps you can lay a tile basemap from the Map picker. The picker is grouped by what a service needs: Built in — no key needed (OpenStreetMap, OpenTopoMap, OSM Humanitarian, CyclOSM, Esri imagery, Esri Streets, Esri Topo, Esri Light, Esri NatGeo) loads as soon as it is picked; Needs your key (Carto Light, MapTiler, Mapbox, Stadia Maps, Thunderforest) draws once that key is saved under Configure → Plat → Maps; Needs a tile URL (Lambton / county GIS, Custom URL) takes the service\'s whole tile template. Leave it on None and nothing is fetched — the measured maps are all it needs, so it works offline. A URL is remembered with the travel settings.',
			'A key comes from the service\'s own account page: sign up, make a project or token, and copy it. Save it once under Configure → Plat → Maps — that page also links to where each service keeps its key — and every Travel window on the house can then pick that service; the line beside the Map picker says when a chosen service still has no key. For a county or city service (Lambton GIS, and the like) or any other service, paste its tile URL into the URL box instead. A service that speaks {z}/{x}/{y} works; an ArcGIS service is usually …/MapServer/tile/{z}/{y}/{x} (note y before x). Where to find it: the publisher lists its map services under a REST directory (for a county, look for an "ArcGIS REST Services" or "GIS Data" page); open the layer, and the Tile link or the URL under the map is the template to copy.',
			'Google Maps is not in the picker: its Maps Tiles API needs an API key plus a short-lived session token minted for each session, so it is not a paste-a-URL service, and it also needs a billing account. Apple Maps likewise has no keyless tile URL. Use one of the services above, or paste a keyed tile URL you already hold from another provider.',
			'The Maps button holds the measured maps as a multi-select: one tick per map. Untick a map to hide it — it stays hidden when the window is reopened and on the continent background too — and All or None ticks or clears the lot, so None leaves only the tile basemap. Press a map\'s name to bring it into view (and tick it back on), and the trash beside it to delete it. The map you last brought into view is the reference the near and far distances are measured from.',
			'The map remembers where you left it: pan and zoom, and opening Travel again returns to that ground at that zoom rather than jumping back to your current position.',
			'A single tap on the map asks for the house\'s own pictures and videos taken on the ground the map is showing. A file carries no coordinates of its own, so a photo is counted when a position fix inside that ground was recorded around the time it was taken. The strip along the top shows the newest 20 (with a +N more marker); press one, or press the Nearby count itself, to open Gallery on the whole set, which pages through every picture in view. The set is the current map\'s range, so pan or zoom and tap again for a different ground. Hidden albums and private records are left out of the strip, exactly as the Gallery leaves them out.',
			'A still long press on the map shows a small preview of street view under your finger; press the preview for the full view. The preview carries only a street-level photo — the house\'s own pictures stay in the strip above. Mapillary is asked first, then a Google Street View key if one is saved; when neither has a photo of that ground the preview says so, and the full view falls back to the house\'s pictures there. Mapillary is free and crowd-sourced, so coverage is dense in cities and often absent on quiet roads. A free Mapillary token is saved under Configure → Plat → Maps; a Google Street View key is a paid Google Cloud API key (billing on, Street View Static API enabled), not OAuth2. The ✕ at the top right, or Escape, puts the ordinary map back. Google Street View and Bing Streetside do not offer a keyless tile service, so the Map picker does not draw them.',
			'The preview also carries Set a plate here: type an app\'s name (the list offers the apps the house can see), give the plate\'s radius in metres, choose the action — start, record or stop — and press Save. The plate belongs to that app and triggers only it, and an app may have as many plates as it has places, so a franchise is detected at each of its shops. The new plate appears under Configure → App → Home Plate with its own latitude and longitude, ready to move later.',
			'Only one device records an appointment\'s movement. Two machines carried together would each write the trip down and the appointment\'s distance would be counted twice, so the house picks one: Configure → Plat → Maps → Movement recording is set to Automatic, which takes the device that has actually covered ground in the last hour, the one that has been recording longest, and hands the trip over if it goes quiet for a quarter of an hour; it can also be pinned to one machine, or set to Every device to let them all record as they used to. The other machines still keep their own current place and still run their own home plates — they simply do not file the appointment\'s fixes.',
			'Every fix in the view\'s time range is drawn on the map, and the fixes that share an appointment\'s uuid are joined by a line in its colour — one line per session. Where an older appointment still holds fixes from more than one device, the house names the one that was actually with you: the device whose fixes covered the most ground, counted in steps over 25 m so a parked device\'s jitter does not add up. Only that carrier\'s fixes make the line, so a device left at home cannot zigzag the walk; the other device\'s fixes still appear as dots. The Dist section of an appointment says which device carried it (With <name>), and its map frames that device\'s fixes. A run that covers less than 50 m is left out. Home plates are drawn for the ground on screen as little house marks, fetched as you pan to a place, and a tap on one opens its app.',
			'Drag to move the map; a flick glides on and eases out, a mouse wheel or a pinch zooms (a trackpad\'s two-finger scroll zooms too), and a double-tap zooms in. A basemap stops zooming in at the deepest tile it serves, and switching to one with a lower limit backs the view up to it. The red marker is the machine\'s current position (the same point navigation keeps fresh); the smaller labelled dots are the places the continent knows — tap one to open that app\'s appointment window, and where several share a spot the dot wears their count and a tap unfolds the list.',
			'To set a map up: upload the picture, set its function to map on the appointment, and the measuring tools appear under it — Scale (click the two ends of the scale bar, with its legend typed in) and Location (the home plate). Read legend lifts the scale number off the picture with OCR; Ask vision sends the picture to your Vision model (Configure → Plat) and comes back with the scale bar placed, the legend read (turned into metres), and a tilt. The Tilt box turns the picture straight — with a live preview — if its screenshot was taken rotated, so it lands level on the map.',
			'The empty ground between measured maps can be guessed: switch the hat (Guess the gaps) on and, as you pan, the blank ground on screen is filled by the Plat Image-generation model (Configure → Plat → Image generation). It takes the largest blank in view and stretches it 40% into the empty ground around it, stopping wherever a map begins — so the guess fills the space the maps leave and never lies under ground you already have, and ground once guessed stays guessed (the same gap is never generated twice). The Vision model reads the parts of every neighbouring map that fall around the blank first, and the picture is prompted to continue them conservatively: no invented bends, junctions or landmarks. The picture is kept sealed under the photo location\'s me folder — where the mugshot lives — and drawn dashed, under every measured map; it is not one of the picker\'s maps. Switch the hat off and the blanks stay blank; the status line beside the hat names the last guess, and a tap on it twice (as the trash buttons work) deletes it, leaving that gap blank for a fresh guess.',
			'The continent desktop background draws the same map, with the current timeframe\'s appointments and every home plate on it; the header and the clothesline rail ride over it. Home plates sharing a spot collapse into one marker wearing their count — tap it and the list unfolds, and a tap on a name opens that app\'s appointment window; a tap on an appointment\'s dot opens its window too. Its now button (or a double-click on the background) centres it back on you.'
		],
		steps => [
			'Open Travel. The view frames your maps and your current position.',
			'Drag to pan; scroll or pinch to zoom, and double-tap to zoom in. Your maps scroll into view as you go.',
			'Pick a built-in Map source (OpenStreetMap, OpenTopoMap, OSM Humanitarian, CyclOSM, Esri) — none of them needs a key. A keyed service (Carto, MapTiler, Mapbox, Stadia Maps, Thunderforest) needs its key saved once under Configure → Plat → Maps; for Lambton or another county paste the tile URL — see where to find one in the words above.',
			'Open the Maps menu to tick which measured maps are shown (All or None), press a map\'s name to bring it into view, and its trash to delete it; Search and the Start/End times scope the history shown. The toolbar stays pinned as you scroll.',
			'Tap the map for the house\'s pictures taken in the view — the strip shows the first 20, and pressing one (or the Nearby count) opens Gallery on the whole set. Long-press for a street-view preview, then press the preview for the full view; ✕ (or Escape) returns to the map. Travel reopens on the ground and zoom you left it at.',
			'Set Home Plate to mark the place your maps share as their reference.',
			'To fill the blanks, switch the hat on: the empty ground you are looking at is guessed and drawn under the measured maps, so it never covers known ground. Switch it off to leave the blanks blank; the status line beside the hat names the last guess and deletes it on a second tap, and a right-click on any guess on the map offers to delete it too.',
			'On the continent background, tap an appointment dot or a home plate to open its appointment window; a numbered marker unfolds the places sharing that spot.'
		],
		related => [ 'measures', 'relational', 'navigation' ]
	};
$topic{'relational'} = {
		title => 'Relational', category => 'apps', app => 'relational',
		templates => [ 'templates/relational/workspace.html.ep', 'public/js/manager/relational.js' ],
		verified => '2026-10-27',
		summary => 'The social constructs, and the relationships between them.',
		body => [
			'Relational is where the house\'s social structure is made: people, teams, clubs, communities, projects, institutions, governments, corporations, places, vendors and events. The window is a workspace. The left column is the library of constructs, one tab per kind, with a search and a New name box; the right side is the construct you are working on, with one drop group for each kind it can belong to.',
			'Adding is deliberately two ways. On a desk, drag a card from the library onto the matching group (a team card onto Teams); on a phone, press the + on the card. Either way the link is written both ways, so the team lists the person and the person wears the team. Remove a link with the x on the member, or drag the member to Drop here to remove.',
			'A construct is a named row with a kind (its pos, or its mab when it belongs to a second kind). Details on the focused card changes that kind; the tree and calculator tools of the old matcher are not part of this board.',
			'A person construct is also a person in People: the window adds the People row for it and keeps their construct chips up to date. Deleting the construct removes the person; changing its kind away from person only hides it, so an accidental change can be undone. Opening Relational from a Person card focuses that person. A person\'s Self, Friend, Stranger or Enemy relationship is set on their People card, not here: it is a configuration setting that the visibility rule and the phone\'s call-flow matrix read, and it is not a construct membership.',
		],
		steps => [
			'Open Relational, or press Open Relational on a Person card to start focused on them.',
			'Pick a construct in the library; its card fills the right side with one group per kind.',
			'Drag a card onto its group, or press + on the card, to add the relationship.',
			'Press x on a member, or drag it to Drop here to remove, to end the relationship.',
			'Type in New name and press Add to make a construct without leaving the board.',
			'Open People to see the same people with their crests and memberships.'
		],
		related => [ 'people', 'mailbox', 'travel' ]
	};
$topic{'cards'} = {
		title => 'Cards', category => 'apps', app => 'cards',
		verified => '2026-11-04',
		summary => 'Four decks: tarot drawn from your own data, solitaire, mahjong and blackjack.',
		body => [
			'Cards opens on a chooser with four decks. The table remembers the one you picked; press Cards in the top left to bring the chooser back.',
			'Tarot is the deck of Jawn: a daily card, a weekly card, or a three-card spread drawn from your own appointments and measures. Press Deal, or click a card, to draw; a spread shows its three cards side by side. The draw lists belong to the house, so every device shows the same recent draws, and the card, table and controls fit a narrow phone screen too.',
			'Solitaire is Klondike with a three-card deal and a felt table in the house\'s own colours. Click a card, then the column or foundation to move it, or drag the card where it belongs; double-click sends a card to its foundation. The stock is top left and the four foundations stack at the top right. Auto sends the cards that are safe to go up, Undo takes a move back, and Bank keeps a running casino score across rounds.',
			'Mahjong is a five-layer turtle: pair two matching tiles that are free, which means nothing is stacked on top of them and nothing sits immediately left or right. Clear the upper layers to free the ones below. Shuffle rearranges what is left; the timer starts with your first pick.',
			'Blackjack is the casino table. Pick a chip, press Deal, then Hit or Stand; Double doubles the stake and draws one card. The dealer stands on seventeen, blackjack pays three to two, and Bank carries across rounds. Reset bank starts it at five hundred again.'
		],
		related => [ 'twirl', 'measures' ]
	};
$topic{'twirl'} = {
		title => 'Twirl', category => 'apps', app => 'twirl',
		verified => '2026-11-05',
		templates => [ 'templates/twirl.html.ep', 'public/js/manager/twirl.js' ],
		summary => 'A falling-block puzzle in a ten-by-twenty well.',
		body => [
			'Seven shapes fall one square at a time into a ten-by-twenty well. The left and right arrows slide a shape, the down arrow nudges it, the up arrow turns it, and the space bar drops it to the bottom. A full row clears and everything above it sinks. Ten cleared lines raise the level and the fall quickens.',
			'The Next window shows the shape after this one, and Best keeps the five highest scores with three initials each. Escape pauses the game, C clears the saved scores, and Enter deals again after a game over. The shapes, the brick wall and the table are drawn in the house\'s own colours.'
		],
		related => [ 'cards' ]
	};
$topic{'controller'} = {
		title => 'Controller', category => 'apps', app => 'controller',
		verified => '2026-11-08',
		templates => [ 'templates/apps/controller.html.ep' ],
		summary => 'The handheld\'s home: eight tiles, Network, Sound, battery/CPU and Manager buttons, and a Leave panel that puts the panel into a dark idle.',
		body => [
			'Controller is the home screen of the handheld. It has no desk of windows: it shows eight tiles, each one press away from the surface it names, with Network, Sound, the battery reading and a Manager button at the top right. Press the battery reading for the pack\'s state and the CPU profile (Auto, Power saver, Balanced, Performance).',
			'Network shows whether Wi-Fi and Bluetooth are on and lets you switch either one; the Wi-Fi row names the network it is joined to. Sound is a master level and three channels: Music, Phone and Alarm. Master is the machine\'s own mixer, so it is the level that leaves the speaker or the headphones; a controller whose boot tree has no sound card says so and leaves the master row disabled. Each channel keeps its own level, so one source can be turned down without silencing another; a player applies its channel as it is brought onto the mix.',
			'Music opens the house music, Gallery the photos and videos, Notifications what the house has told you, and Games a second launcher for Cards and Twirl. Configuration holds the house and device settings, including the Sys section. IVR opens the Phone app, where the call menu and recorded greeting live. Automation opens the embedded device toggles.',
			'An app opens on the whole panel: no desk, taskbar or title bar. The button above the arrow keys sends Home, which returns here from any screen.',
			'Leave is a working panel on the launcher. Screen off stops the display painters, blacks the panel and drops the CPU to powersave, so the machine can wait in a bag for a call; Restart and Shut down do what they say. A controller is not offered Sleep, because a system suspend would take the radios down. Press one and the tile says it asked; a refusal names its reason. The two trigger-happy keys pressed together bring the screen back.'
		],
		related => [ 'twirl', 'phone', 'configure' ]
	};
$topic{'games'} = {
	title => 'Games', category => 'apps', app => 'games',
	verified => '2026-11-09',
	templates => [ 'templates/apps/games.html.ep', 'public/js/manager/twirl.js' ],
	summary => 'The games launcher: Cards and Twirl, and an emulated shelf that installs its emulators, reads the ROMs under ~/roms, and runs one outside the house view.',
	body => [
		'Games is a second launcher, one press in from the Controller\'s Games tile. Cards opens the card room and its solitaire and blackjack games. Twirl opens the falling-block puzzle, where the left and right arrows slide a piece, the down arrow nudges it, the space bar drops it, and Enter deals again after a game over.',
		'On the handheld the A button turns the piece clockwise and B turns it counter-clockwise. A is the plain click the launcher and the Manager already use, so a press on the well turns the piece; B is delivered as a key that no other app uses.',
		'Emulated games opens on the shelf. Install emulators fetches RetroArch and the emulator cores the shelf knows; Install ROMs copies ROMs from the emmc or a USB stick into the person\'s own roms folder, without overwriting one already there. The games found there are drawn as a grid of cards, each with its cover picture when the ROM folder carries one beside it, and its system under the title.',
		'Press a card to run the game. It leaves the JawnOS view and runs in its own programme, with the handheld\'s controls handed to it as a gamepad; the Home button above the arrow keys ends it and brings the launcher back. A machine with no emulator for a system says so instead of starting nothing.'
	],
	related => [ 'cards', 'twirl', 'controller' ]
};
$topic{'budget'} = {
		title => 'Accounting', category => 'apps', app => 'budget',
		verified => '2026-10-30',
		templates => [ 'templates/budget.html.ep', 'templates/budget_reconcile.html.ep', 'templates/budget/runway.html.ep', 'public/js/manager/budget.js' ],
		summary => 'Accrual income statement and balance sheet, cash flow, runway, account activity, trial balance, receivables, scheduled payables, the ledger and bank reconciliation.',
		body => [
			'Accounting turns your transaction history into the statements a business reads: an income statement, a balance sheet, a cash flow statement, account activity, receivables, payables, the ledger of what has moved, the document ledger of invoices and quotes, a day book, and a reconciliation screen for a bank statement. The income statement and the balance sheet are kept on an accrual basis - an invoice is revenue when it is written and a bill is a cost when it arrives, whether or not the money has moved. The cash flow statement is the cash view, so it reports what actually moved through the accounts in its period.',
			'The income statement lists income by account, then cost of goods sold and gross profit, then operating expenses, with the prior period beside it, and shows net income. The balance sheet lists every asset account the journal holds - bank accounts, receivables, inventory - then liabilities such as Accounts Payable and sales tax, and the difference as equity. Because both are read from the double-entry journal, they agree with the Trial Balance. The cash flow statement starts from receipts and payments, then shows transfers between accounts and any balance adjustment, and ties the opening and closing cash. Account activity is each account\'s opening, receipts, payments, transfers and closing for the period. Receivables ages every unpaid invoice from the date it was written; Payables ages every bill still owed.',
			'Trial Balance is the double-entry view. Every money move is posted once as a balanced entry: a bank account against the app that earned or spent it, an invoice against Accounts Receivable with the revenue and sales tax on the other side, a payment against the receivable when it settles an invoice, and a transfer against the other bank account. A stocked item moves through Inventory: a purchase debits Inventory instead of the expense, and a sale takes its moving-average cost out of Inventory into Cost of Goods Sold. A bill credits Accounts Payable instead of a bank account, and paying it moves the payable to the bank. The journal is built from the ledger and the documents, so Rebuild journal can always regenerate it; the screen lists each account\'s debit and credit balance and says whether debits equal credits. The clearing line is a transfer whose other leg was never recorded - it should fall to zero as those are repaired.',
			'The ledger is drawn per account; a transaction with no account attached will not appear on it, so transactions are recorded with a real account. The window and its scope (hour, day, week, month, year) come from the app\'s own settings, so a view you set up is the view you come back to. Each app\'s row and its budget cells carry that app\'s colour as a tint, composed against the desktop, so the figures stay readable in a light or a dark theme.',
			'Runway is the cash reading: how long the money lasts. Day, Week, Month, Quarter and Year choose the step, and Estimate from (week, month, quarter, year, decade or all time) chooses how far back the pace is read - so a month of vape, banking and dinners is what a month actually costs, and an old one-off does not dominate the figure. Past periods are the money ledger\'s own net movement. The projection carries that pace, read against each period, plus any transaction you have dated ahead; the bills a schedule will raise and the bills already owed are listed beside the periods and on the chart\'s hover, but are not added again, because the pace is read from a ledger that already paid the bills of the periods it covers. The bars under the line are each period\'s net (a loss below the line, a gain above), and the dashed floor is the total of the minimums your accounts are set to keep. Where the projection crosses that floor is the runway date.',
			'Hover any chart point for its figures; click it to open that period. On the statements the click shows the same display over just that period. On Runway it lists the period\'s transactions underneath and offers Open this period, which switches the app to the Ledger on that window.',
			'Each app that keeps a budget still has its budget light in its header; that is the app\'s own measure, not this app\'s reports. Opening it shows the period against its budget, the pace it is on, and — when what is counted is over the budget — a Recommended button. Pressing it sets the budget to the app\'s own typical period, keeping the budget\'s scope, measure and floor or ceiling, and fills the matching row on the app\'s card in Configure. The light also lists the budget and the app\'s typical amount at the budget\'s own scope and the next two larger ones — a per-hour budget reads as an hour, a day and a week, with no meaningless per-minute figure. While a scope is still running, the budget-vs-typical and this-vs-budget rows are read against the share of the scope that has elapsed, so an early morning is not read as a fall. A duration budget counts time where it was actually spent, so a session that runs past midnight gives each period its own share rather than putting the whole night on the day it began. While a session is running, an open light follows it, so the time it names keeps growing instead of standing at the value from when the panel was opened. The light reopens with its app if it was left open when the window was closed.',
			'Reconcile is the bank side. Import a statement file — CSV, QIF or OFX — for one account, with the date order the file uses (month first or day first), and Accounting matches each line to what it already holds by amount within three days. The screen lists the lines it found, the lines it did not, and the money in Accounting that the statement does not show, so the difference between the two sides is visible before anything is written. A line the ledger holds in pieces — an e-transfer whose service charge was recorded on its own, as Libro writes it — is settled from those rows and only the remainder is offered to record; a line with an existing transfer leg on another account is recorded as the missing leg of that transfer, so the other account is left alone; a line before the account\'s last inventory balance is shown as covered by it rather than offered again. Each line left to record can name its own app and whether it is income, an expense or a transfer; when the house has paid the same merchant before, the app and item are filled in from that history and shown as a suggestion for you to confirm. Pressing Reconcile first records those lines, then writes the statement\'s ending balance as the account\'s inventory balance: from that point on the balance is measured from the bank\'s own figure, and the Delta line on the screen is that figure minus what the ledger holds.',
			'Payables is the other side of the ledger. Record a bill with its vendor, app, item, total, tax and date; Accounting books the expense and the payable at once, so the cost belongs to the period the bill was written even though no money moved. The table ages every open bill from its date, shows what has been paid against it and what is still owed, and a Pay control settles it from a chosen bank account - in full or in part - which moves the payable to that account. Delete removes the bill and any payments against it. The total owed is the Accounts Payable credit the trial balance carries.',
			'A bill can repeat. Choose Every week, Every 2 weeks, Every 30 days, Every month, Every quarter or Every year when you record it, and Accounting keeps a schedule. A custom schedule can be typed instead: an interval, then for how long, so 1d for -2w is every day for two weeks and monthly for 1y is the first of each month for a year. Without a for it keeps repeating. The same field takes words too - "every third Saturday of the month", "every Tuesday for 6 weeks except on holidays", "the next five full moons", "my mom\'s next 5 birthdays" - and the Guide turns them into the due dates; "except on holidays" skips the common US/Canada holidays. If it needs a detail, it opens a Guide associate to ask and then finishes the schedule. Each due date becomes a real bill on that date - the payable is not raised early - and any dates already past are filled in when the schedule is first read. Months follow the calendar, so a bill on the 31st shortens to February\'s last day and returns to the 31st afterwards, and a leap February has 29 days. A schedule can be paused and resumed; one whose for has passed reads ended, and deleting it leaves the bills it already made. The first due date is the date typed beside the rate.',
			'Payments named in bank notifications book themselves. When a notification from a bank account the house knows says you spent an amount at a merchant - Koho writes "You spent $29.38 at PUBLIC MOBILE SELF" - Accounting raises the bill and pays it from the account the notification came from at once, with no press, filling the app from the house\'s history with that merchant. Payables lists the last few at the top as Booked from notifications so you can see what it did; Undo there removes the bill and its payment and leaves that notification unbooked. A purchase a statement import or a typed transaction already recorded is not booked a second time.',
		],
		steps => [
			'Open Accounting; the display dropdown chooses the statement — Income Statement, Balance Sheet, Cash Flow, Runway, Account Activity, Ledger, Receivables, Payables, Invoices, Day Book or Reconcile.',
			'Change the scope along the top to set the period — this month, last quarter, this year — and the accounts the statements cover.',
			'Open Runway to see how long the money lasts: pick Day, Week, Month, Quarter or Year for the step and Estimate from for the window the pace is read over, then click a period on the chart to see its transactions or open it.',
			'Read the income statement against its prior period, then check the balance sheet (assets, liabilities and equity) and the cash flow for the same window.',
			'Use Receivables to see which invoices are still open and how old they are.',
			'Use Payables to see which bills are still owed: record a bill when it arrives, then pay it from the account the money left. A bill can be paid in parts and each payment is shown against it. Set a repeat on a regular bill and it is raised for you on each due date.',
			'Payments named in bank notifications book themselves: the bill appears at the top of Payables already paid from the account the notification came from. Press Undo there if one was not a bill; a purchase an import already recorded is not booked twice.',
			'Open Trial Balance to read the double-entry journal; press Rebuild journal after a change to the ledger or the invoices if the balances look stale.',
			'To settle an account against its bank statement, choose Reconcile, pick the account and the file\'s date order, and import the file. Check the matches, set each unmatched line to Record or Ignore (untick a line to leave it alone), give it an app and a movement, type the statement ending balance, and press Reconcile.',
			'The display and scope are remembered, so the view you settle on is there next time.'
		],
		prompt => 'The reader wants help reading the Accounting statements. Explain what each display is for, what the period and account filters do, and how a bank reconciliation sets an account balance. Never invent numbers — talk about how to read and arrange the view, not about their actual figures.',
		related => [ 'store', 'warehouse', 'invoices_payments' ]
	};
1;
