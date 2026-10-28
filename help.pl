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
use Mojo::Util qw(xml_escape);

# The date every topic is considered vetted as of, unless it carries its own
# `verified`. The auditor compares this against the git history of the app's
# files: anything that changed since is reported as possibly stale.
our $verified_default = '2026-10-12';

our %topic = (

	# ---------------------------------------------------------------- apps
	'folders' => {
		'title' => 'Folders', category => 'apps', app => 'folders',
		templates => [ 'templates/folders/folders.html.ep', 'templates/folders/context.html.ep', 'templates/folders/properties.html.ep', 'templates/folders/dialog_box.html.ep', 'templates/folders/app_picker.html.ep', 'public/js/manager/folders.js', 'public/js/manager/desk.js' ],
		summary => 'Browse, manage, seal and play with your files.',
		verified => '2026-10-28',
		body => [
			'Folders is the file browser. It walks your media directories and shows thumbnails for images, video and audio, with a full right-click menu on every file and folder: new file and folder, rename, open, open with, copy, cut, paste, delete, shred, archive and properties.',
			'The toolbar carries Sidebar, Home, Back, Forward, Up and Refresh, a clickable breadcrumb back to Home, the machine chooser, and a button that switches the listing between a grid of icons and a list showing each item\'s type, size and date. Back and Forward walk the folders already visited (Alt+Left and Alt+Right do the same), and the path can be typed instead: press the small button beside the breadcrumb, or Ctrl+L, and Enter to go. The breadcrumb and the window\'s title bar read each folder in the house\'s own words - underscores as spaces and each word capitalised - while every command still works on the real path and name; typing a path shows the real one.',
			'Open in new tab and Open in new window sit on the menu of every file, folder and the folder background. A new tab joins the window you are working in; a new window opens beside it with its own history, title and taskbar tile. Both are named Folders - the folder they show, not its whole path. Folders also remembers the last folder read and the machine it was read from, so a plain open returns there; picking a folder, a machine or a command in the menu still goes exactly where you asked. The machine chooser always names the machine whose files are on screen, including a remote one - the listing of a remote machine is drawn by that machine, where it is "this machine", so its own row stays in the list. The tab strip appears under the path bar only once a window has more than one tab: press a tab to switch, its cross to close it (closing the last tab closes the window), or + to open another.',
			'On a screen wide enough for it - a tablet, laptop or desktop, or a Folders window widened past the sidebar\'s break - a Places column sits beside the listing: Computer, Home, Desktop, your media locations, Archive and the Recycle Bin. Press the Sidebar button to show or hide it; the choice is remembered on this screen. The padlock and the path bar keep the full width above it.',
			'Selecting works the way a file manager\'s does: click one item, Ctrl (or Cmd) click to add or remove one, Shift click to take the run between the last click and this one, and drag on the empty background to draw a selection box. The arrow keys walk the listing, Shift and an arrow extend the run, Ctrl+A selects everything, Enter opens, F2 renames, Delete removes and Shift+Delete shreds; typing a name jumps to it.',
			'Dotfiles stay out of the listing by default. Right-click the folder background and choose Show hidden files to bring them in; the choice is remembered on this screen, and the same row then reads Hide hidden files.',
			'Dragging carries the whole selection. Drop it on a folder\'s tile to put it inside, on the window\'s empty space to put it in the folder on screen, or on the desk to put it in the desktop folder; Ctrl (or Cmd) held at the drop copies instead of moving. Every move reports its progress in a dialog and the listing reads itself again when it finishes.',
			'Archive copies the selection to the drive of the machine chosen for the location it sits in (Configure, Locations). It lands under that drive\'s archive_dir in a folder named for the location - Videos, Music, Photos - and the original stays here: archiving is a copy, not a move. If a location has no machine chosen and the house has exactly one machine with an archive drive, that machine is used automatically; with more than one, pick the machine in Configure. The queue button on the toolbar shows what is waiting, sending and finished, and retry or stop each job. A local item that also has an archived copy wears the archive icon beside it, and so does a folder whose contents are archived; the Archive entry in the right-click menu uses the same icon.',
			'Delete moves an item to the Recycle Bin instead of destroying it: the file is kept in ~/.local/share/Trash with a note saying where it came from, so the rest of the desktop can see it too. Open the bin from the Places column, the desk\'s Recycle Bin icon, or the desk menu, then choose Restore on an item (or a run of them) to put it back where it was; a name already taken is kept beside it with .restored on the end. Empty Recycle Bin, on the bin\'s background menu or on the desk, permanently deletes everything in it after one confirmation. Shred is the permanent command that never uses the bin.',
			'The desk behind the manager shows a folder of its own. It starts on ~/Desktop when that has something in it, and on your home folder otherwise. To choose another, right-click that folder (or the folder background) and pick Use as desk folder; Reset desk folder returns to the automatic choice. Its icons fill a column top to bottom in alphabetical order, then start the next column to the right, the way a desktop lays them out; whatever fits the screen is shown, under the clothesline when the rail is showing, and right-clicking the desk also offers the browser\'s own Back and Refresh.',
			'Two places keep the first two spots on the desk whatever it holds: Computer, which opens the root of this machine, and the Recycle Bin, carrying a small badge with how many items are waiting in it. Both open in a Folders window; neither is dragged, renamed or deleted.',
			'The desk\'s clock keeps the wall time ticking every second, and the clothesline is read again once a minute while the desk is up. The appointment view behind the other backgrounds is not built at all while the desk is the background.',
			'Right-click the desk or the folder background and pick Pin apps to the desk to keep app shortcuts there. A double-click opens the app; right-click a shortcut and choose Unpin from the desk to take it away. The shortcut wears a small arrow on its icon, and files can still be dragged past or onto the desk around it.',
			'Properties tells you what a file is without opening it: its path, type, size (or for a folder, how many things are inside), modified, accessed and changed dates, permissions, owner and group. Select several items and Properties gives one table with the sizes and a total. Copy path puts the full path on the clipboard, and Show in Folders opens the folder that holds it.',
			'Right-click a file to seal it — encrypt it under a name of its own — and open it again from the same menu. Long jobs (moving, sealing, opening, deleting) run in the background and report their progress.',
			'Some names on disk are the house\'s own and are shown as words instead: an app\'s folder in a media location reads as the app\'s name (Pictures/autumn appears as Autumn), and a sealed file reads as the name recorded with it when its json carries one (a map\'s place, a document\'s title) or as the app that wrote it and the moment it was made — Autumn 10162026 3:30pm. This is the label only; opening, renaming, moving and deleting still use the real path.',
			'Opening a picture, a track or a video hands the app the whole set: Gallery opens the picture you picked in its viewer, with every picture of the same kind in that folder as the album behind it, so closing the picture lands on the folder; Music queues the folder\'s other tracks or videos, starting with the one you opened. A document opens in IDE on its own - the editor keeps one tab per file, so a folder\'s worth of documents is not swept in.',
			'Moving, sealing, opening or deleting a file carries the appointments, mail attachments and store entries that named it along with it, so nothing is left pointing at a file that is no longer there.',
			'A lock on the toolbar turns the media padlock. Private is a lock, not a place level: a private folder is hidden everywhere, even at home, and its files are kept out of the listing until the Folders padlock is opened with a fingerprint (or on a paired phone). It can only be found in a private place with no Enemy present; in a public or dangerous place, or with an Enemy present, it cannot be found at all and no unlock brings it back. A sealed file (a name ending .enc) in a folder whose visibility shows it is listed as usual; only a sealed file belonging to a private folder waits for the padlock. Folders opens with that padlock shut, and the next open starts shut again. The house gate in Security has nothing to do with this; each media app has its own padlock.',
		],
		steps => [
			'Open Folders from the start menu.',
			'Click into a folder to descend; the breadcrumb along the top walks back up, and Home returns to your home folder. Back and Forward (or Alt+Left and Alt+Right) retrace the folders you have visited.',
			'Open a folder from the Places column beside the listing, or press Sidebar to show or hide that column; it appears when the window is wide enough.',
			'Right-click a folder and choose Open in new tab or Open in new window to keep it beside what you are doing. Tabs show under the path bar when there is more than one; their crosses close them and + opens another.',
			'Right-click the empty space in the listing and choose Show hidden files to list dotfiles too; choose Hide hidden files to put them away again.',
			'Press the view button (or Ctrl+L to type a path) to work in a list with type, size and date instead of icons.',
			'Click an item; Ctrl-click adds one, Shift-click takes a run, and a drag on the empty background draws a selection box.',
			'Right-click a file for its menu — open, rename, copy, cut, delete, shred, seal or properties.',
			'Drag the selection onto a folder tile, the window\'s empty space, or the desk; hold Ctrl while dropping to copy.',
			'Delete or Shift+Delete puts an item in the Recycle Bin; open the bin, select what you want back and choose Restore, or press Empty Recycle Bin to clear it for good.',
			'Right-click a folder and choose Use as desk folder to make it the desk\'s folder; Reset desk folder on the desk returns to ~/Desktop or home automatically.',
			'Right-click the desk and choose Pin apps to the desk; double-click a shortcut to open the app, or right-click it to unpin it.',
			'Choose Properties on a file or folder to read its dates, permissions, owner and group; Copy path and Show in Folders sit at the foot of that card.',
			'To keep something safe off the record, choose Seal: it is encrypted under a name of your own, and opens again from this same menu.',
			'For a hidden folder, press the lock on the toolbar and unlock it with this computer\'s fingerprint or on a paired phone, and it appears.',
			'Sealed names ending .enc are listed with their folder; only a sealed name inside a hidden folder waits for that same Folders padlock. Press an open padlock to shut it again.'
		],
		related => [ 'sealing_files', 'gallery', 'backup' ]
	},
	'clock' => {
		title => 'Clock', category => 'apps', app => 'clock',
		templates => [ 'templates/apps/clock.html.ep', 'public/js/manager/clock.js', 'templates/manager.html.ep' ],
		verified => '2026-10-27',
		summary => 'Alarms, a stopwatch, timers and world clocks, with alarms and timers that can start and stop appointments.',
		body => [
			'The Clock app has four faces. Alarm holds up to ten alarms, each with a time, a name, an optional sound and a linked appointment. Each alarm is a folded row: the strip shows its time, its name and the machines that carry it as pills, with the on/off switch at its end. Press the strip (or the arrow) to open the alarm and see the editors - the time and name, the days, the next run, the sound and Play mode - and press it again to fold it away; only one alarm is open at a time. Stopwatch counts up with laps. Timer holds up to ten countdowns, and several can run at once. World Clock shows the local time beside any time zones you add.',
			'An opened alarm shows when it will next run, as a day and time with a live countdown (Next Mon 9:01 · 16h 24m). Skip for today cancels the coming occurrence without changing the days or the switch: the countdown moves to the following occurrence, and the alarm stays set. The skip is the same one the phone\'s half-hour notice offers, so a skipped alarm agrees on every machine.',
			'Play mode sets what answering the alarm takes. Left at None, the ring is answered with Snooze and Dismiss as usual. Set to Math, the phone\'s locked alarm screen asks for a small arithmetic problem - nothing harder than 12 × 12 − 6 - so the alarm is not silenced half asleep, and a wrong answer leaves the alarm ringing. The Clock window\'s ring card still shows the problem but answers directly: unlocking the phone and using the buttons there is the acknowledged way past the math, and later play modes will use the same escape.',
			'Use NFC to snooze turns the ring into a trip to a tag. It appears once the alarm\'s Linked appointment names an app that has an NFC tag assigned to that app\'s start control: the same tag that starts the app is the one the alarm asks for. Switch it on and choose the NFC action - Snooze or Dismiss - and the phone must scan that tag before the alarm will quiet. The scan is checked against the app\'s own NFC assignment, so a different tag is refused and the alarm keeps ringing. The Clock window\'s ring card still shows the alarm and can still Snooze or Dismiss it; that card is the acknowledged first-step bypass, so the window remains a way to answer the alarm even when the phone wants the tag.',
			'Press the clock in the taskbar for a small menu carrying the four faces and the time machine. The menu hangs below the clock when the taskbar is along the top or a side edge, and above it when the taskbar is along the bottom. Choosing a face opens the Clock window on that face; a window already open is brought forward instead of being replaced.',
			'An alarm can be toggled on or off, and its seven day buttons say which days it repeats on. With no day chosen it is a one-shot: it rings at the next matching time and then switches itself off. Press Once to clear the days, or press the days the alarm should repeat on. Ten alarms are kept; add another only after deleting one. A name is held to twenty characters, which is the room the row has beside the time.',
			'The alarm list belongs to the house, not to one machine. Shared with names the machines that ring an alarm: Me is where you are now, and every other machine the mesh knows is listed beside it, so one alarm can wake the phone and the laptop together. Press a machine to add or remove it; at least one stays on. A change is pushed to the named machines immediately and each one confirms it, while the row also rides the normal sync as a fallback; a confirmed machine is marked in the alarm\'s machine pills. Whichever machine rings, Snooze or Dismiss carries to all of them - the shared row carries the stop, and the other machines are told at once, so the sound ends everywhere rather than in the one room where the button was pressed.',
			'The sound plays through the operating system, not through the browser. On a phone the app plays it on Android\'s alarm channel, so the ringer\'s alarm volume and Do Not Disturb rules apply, and while the alarm rings the app raises the alarm stream to its maximum before putting the previous alarm volume back when the ring ends; the alarm\'s own Volume still scales that sound on top, so a phone kept quiet is still loud enough to wake the person without the setting being changed. On a desk it goes through the house\'s usual notification channel. Every sound repeats until Dismiss or Snooze, or until five minutes have passed: a short chime starts quietly and loops every fifteen seconds while the volume climbs over the alarm\'s Volume ramp, and a long-form track - the I Dig it recordings are in the Sound list - loops instead of playing once, fading in over the ramp. Preview, beside the Sound list, plays the chosen sound on this machine for a few seconds at the alarm\'s Volume, so a track can be heard before the morning it matters; pressing Preview again stops it, and choosing another sound starts that one. The Clock window shows a ring card with the same two buttons, but makes no sound of its own.',
			'On a handheld, Android posts a native notice half an hour before the next alarm. It names the alarm\'s linked appointment when there is one and says when it will sound; its Skip today button ends the phone\'s own wake at once and asks jawn to skip that occurrence, so the alarm stays in the schedule for its following day. Dismissing or snoozing the alarm, or changing the schedule, takes the half-hour notice away.',
			'When an alarm rings on a locked phone it opens a full-screen Clock alarm screen: a filled circle with the JawnOS logo sits at the bottom and an empty circle near the top. Tap the logo to snooze; drag the logo up to the empty circle to dismiss. The Android notification also carries Dismiss and Snooze buttons, so the alarm can be answered without opening the app.',
			'An appointment can bring its own alarm. When an app\'s notification panel has Alarm on, a future appointment of that app adds its time to the Clock as an alarm automatically, linked back to that appointment, so the clock row starts the activity when it rings like any other linked alarm.',
			'Linked appointment wires an alarm to an activity: when the alarm rings, that appointment is started, and any intelligent-automation outputs on it are switched on. An appointment already running is left alone, so the alarm cannot open a second session, and two machines ringing the same alarm write the one start. A timer behaves the same way in both directions: starting it starts the linked appointment, and when the countdown reaches zero that same session is stopped. Cancelling a running timer stops the appointment too, and Restore above Delete puts a finished timer back on the clock at its old length, starting the linked appointment again. A finished timer\'s notice and chime are played through the operating system, like an alarm\'s, not in the browser.',
			'The linked-appointment list hides appointments the visibility rule hides here and now, and each name wears the icon the app wears elsewhere in the house. Type to narrow the list and press a row to choose it; the cross clears it.',
			'The stopwatch and the world-clock list are kept by this browser. The stopwatch keeps running when you switch faces or reload the page; world clocks are remembered per browser, with the local time always shown first and an extra day marker when a zone is on another date. Alarms and timers are kept by the machine itself, so they keep their time when the window is closed and are still there after a restart. Alarms, being the house\'s, are shared between machines; timers are not.',
		],
		steps => [
			'Press the clock in the taskbar and choose Alarm, Stopwatch, Timer or World Clock, or open Clock from the start menu.',
			'On Alarm, press Add alarm. Set its time, give it a name, and choose the days it should repeat on; leave every day off for a one-shot.',
			'Press an alarm\'s strip to open it. The top line names the machines that will ring it; the body holds the time, name, days, linked appointment, sound, volume, ramp, Snooze length, Play mode, and Use NFC to snooze with its NFC action.',
			'To call off the next occurrence without changing the schedule, press Skip for today and read the countdown move to the following day.',
			'Choose a sound, a volume and a volume ramp. A ramp of 60 fades in over a minute. Every sound repeats until Dismiss or Snooze, or for five minutes, and a long track loops rather than playing once. Press Preview beside the sound to hear it on this machine.',
			'Set Play mode: None answers the ring with Snooze and Dismiss as usual, while Math asks a small arithmetic problem (no harder than 12 × 12 − 6) on the phone\'s locked alarm screen before either will work; the Clock window\'s ring card still answers directly, which is the intended bypass.',
			'Set Snooze length, from 1 to 60 minutes with a default of 5, to choose how long Snooze waits before the alarm sounds again.',
			'Press Me, or any other machine, under Shared with to say where the alarm should ring.',
			'To start an activity with the alarm, type its name in Linked appointment and pick it from the list.',
			'To have the phone read a tag, link the alarm to an app whose start control has an NFC tag, switch on Use NFC to snooze and choose the NFC action - Snooze or Dismiss; the phone then scans that tag to quiet the alarm and refuses any other tag, while the Clock window\'s ring card still answers it.',
			'On Timer, type a length (hours, minutes and seconds) or press a preset, name it, and link an appointment if the timer should run that activity.',
			'Press Add timer. Several timers can run at once; Stop ends one, Restore runs a finished one again, and Clear finished tidies the list.',
			'On Stopwatch, press Start to count up, Lap to record a split, and Reset to clear it.',
			'On World Clock, type a city or time zone and press Add; the cross removes one.',
			'When an alarm rings, press Dismiss to stop it or Snooze to hear it again after the alarm\'s Snooze length.',
			'On a locked phone the ring opens full-screen: tap the JawnOS logo to snooze, or drag it to the top circle to dismiss; the Android notification also offers Dismiss and Snooze.',
			'To let an app\'s future appointments raise a Clock alarm, turn on Alarm in that app\'s Notifications panel under Configure.',
			'Press the clock in the taskbar and choose Time machine to carry the desk to another time, as the clock itself did before.',
		],
		related => [ 'appointments', 'taskbar', 'start_menu' ]
	},
	'gallery' => {
		'title' => 'Gallery', category => 'apps', app => 'gallery',
		templates => [ 'templates/apps/gallery.html.ep', 'public/js/images.js' ],
		controls => [ 'Albums', 'All photos', 'Search', 'Newest first', 'Oldest first', 'Lock', 'Unlock', 'Previous', 'Next', 'Close', 'Full screen', 'File information', 'Set as main image', 'Fetch home', 'Delete' ],
		verified => '2026-10-28',
		summary => 'Browse your photos and videos by album, in a grid, or one at a time.',
		body => [
			'Gallery is the photo browser. It opens on **Albums**: one cover per app that has photos or videos, with the number of items in each. Tap an album to see its photos in a grid, or tap **All photos** to see everything.',
			'Tap any photo to open the viewer: the photo or video fills the window, Previous and Next (or a swipe, a trackpad\'s sideways swipe, or the arrow keys) move through the set, and Close returns to the grid. The bar under the photo offers File information, Set as main image (the cover the app uses), Fetch home and Delete. Fetch home appears only for a photo that lives on another machine: it brings that photo back to this one.',
			'A picture opened from Folders arrives in the viewer straight away, with the rest of that folder\'s pictures as the grid behind it - Close leaves you on the folder, not the album list.',
			'Which photos appear is decided by the apps whose visibility shows them: a private album is hidden everywhere, even at home, and never appears on the timeline. It can only be found in a private place with no Enemy present, and even then it waits for the gallery lock. The search box finds photos by app or file name, and the sort button flips the order between newest and oldest first.',
			'An album that is Public or Dangerous opens straight away, sealed photos and all. A private album stays out of the grid until the gallery is unlocked: press **Lock** to open the padlock view and unlock it with this phone or computer\'s fingerprint, or with the recovery code. Outside a private place - or with an Enemy present - no unlock brings it back. The unlock is for that screen and that window only, and the padlock shuts again as soon as the Gallery window closes, the screen goes away, or the house restarts.'
		],
		steps => [
			'Open Gallery from the start menu (the photo icon). It lands on Albums, one cover per app.',
			'Tap an album to see its photos, or All photos for every app; the grid loads more as you scroll.',
			'Use the search box to find photos by app or file name, and the sort button to switch between newest and oldest first.',
			'Tap a photo to open it full-screen. Swipe or use Previous and Next; Close returns to the grid. The square button beside Close gives the gallery the whole screen, over the taskbar, and takes it back again.',
			'The viewer bar gives File information, Set as main image, Fetch home and Delete.',
			'Press Lock to unlock the album the visibility rule hides; the albums it shows never need it.'
		],
		prompt => 'The reader is using JawnOS\'s Gallery, a photo browser. It is not a phone gallery or a file manager: its photos are the ones recorded by their apps. Describe it in terms of Albums, All photos, the photo grid, and the viewer with Previous, Next, Close, File information, Set as main image, Fetch home and Delete. If they see nothing, the likeliest cause is that no app with photos is marked visible, or the hidden albums need the gallery lock opened. If you are unsure how a control works, describe what its label means rather than inventing a sequence. Never describe or guess the content of their photos.',
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
		verified => '2026-10-28',
		body => [
			'Studio is a multitrack recorder and editor: takes, crossfades, waveform clips, and a pedalboard routed onto individual channels.',
			'The knobs and pedal backdrops follow the selected icon set, so the mixer wears the same finish as the rest of the desk.',
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
		'title' => 'Music', category => 'apps', app => 'music',
		templates => [ 'templates/apps/music/music.html.ep', 'templates/apps/music/configuration.html.ep', 'templates/apps/music/audio.html.ep', 'templates/apps/music/files.html.ep', 'templates/apps/video.html.ep', 'templates/keyboard_music.html.ep', 'public/js/music.js', 'public/js/manager/keyboard.js' ],
		controls => [ 'Theatre mode', 'Fullscreen', 'Visualization', 'Volume normalization', 'Remote audio format', 'Sync offset', 'Me audio delay', 'Remote delay', 'Left speaker', 'Stereo', 'Right speaker', 'Video enhancement', 'Sharpness', 'Quality', 'Frame rate', 'Video status' ],
		verified => '2026-10-28',
		summary => 'A player, a library, and the place music is organised.',
		body => [
			'Music is the player and library: artists, albums and folders, with a mute, a lock and a configuration drawer.',
			'Archives, in the configuration drawer\'s folders row, brings what an archive drive holds into the library. With it on, the audio and video kept on the machine chosen for each location are listed beside the local files: an archived video plays from the archive machine, and an archived track carries a Fetch home button that queues its file back onto this machine. Press Archives again to put them away and show only what is here.',
			'Texture, in Appearance, dresses the window in the desk\'s material - the top interface bar, every track, the player bar at the foot and every other surface; Plain and Round leave them bare.',
			'Sealed tracks (a name ending .enc) in a Public or Dangerous album are listed and play as usual. A private album is hidden everywhere, even at home, and never appears on the timeline. It can only be found in a private place with no Enemy present, and even there its tracks wait for the padlock: press the lock on the toolbar and unlock it with this computer\'s fingerprint or on a paired phone. Outside a private place no unlock brings it back. The unlock belongs to that screen and that window; closing the Music window, the screen going away, or a restart shuts the padlock again.',
			'It plays through the browser and can hand the sound to a linked device, and it is where the audio output is chosen. Each output is a row of three: L, the output\'s name, and R. The name in the centre is the whole stereo pair; L sends the left channel and R the right, so two machines can stand in for a pair of speakers, or one room can be given one side. On a computer\'s stereo pair the chosen side is the physical speaker alone; on a phone or tablet, which usually has one speaker, the chosen channel is played through the speaker it has, so it is heard either way. Press the lit side or the lit centre again to turn that output off. The server player (Srv) has only on and off: it hands the file to the machine\'s own player, which has no channel split to offer. The chosen machine receives the player\'s sound as a live stream and plays it through its own audio output, so it needs no Music window of its own and no copy of the file. Remote audio format, in the Audio drawer, chooses PCM (lowest latency, ordinary 16-bit stereo) or Opus (about a twelfth of the bandwidth, decoded on the receiving machine with a little more buffering). A phone or tablet keeps playing with its screen off: the receiving machine holds a wake lock and starts its audio server again if a reboot left it down. Its websocket panel carries a strip naming the track being received, with a Stop button and a Receive music from other devices switch. The stream follows this machine\'s volume and mute, so the volume bar turns every remote down with it; the Me output switch is separate and silences only this machine\'s own speaker. Turning the switch off stops the current stream and refuses later ones to that machine; turning it back on lets it be an output again.',
			'Every machine playing the same stream hears the same samples, so two remote speakers stay in step with each other. Sound that goes through the player\'s audio graph (any volume normalization, equalizer or remote output) leaves the browser\'s own sound-to-picture timing, so the player measures how far the picture shown on screen sits behind its clock: a frame callback says which moment of the track is actually on screen. That measurement is used twice - this machine\'s own sound is held back by it so Me lands with the picture, and the remote lead is reduced by it, so the sound from the other room lands with the picture too. On the desktop app\'s WebKit engine, taking the main video\'s sound into the graph makes the engine present the picture about a second behind its clock, so a video keeps the browser\'s own sound even while a room is on: Me stays with the picture, and the remote is fed from the hidden audio-only lead, whose copy of the chain still carries volume normalization and the equalizer. A left/right split or a manual Me audio delay is the exception, because those need the main element in the graph. The lead is a hidden audio-only copy of the track that reads the measured moment plus the stream\'s own delay; when the picture lags more than the stream takes, the lead is negative and reads a little earlier in the file (the copy may trail the player). The delay is measured after the remote player has started (so its startup is not counted), and Opus adds its own buffering to it. It applies while a video with a remote output is playing; an audio track has no picture to line up. Every remote reports the moment it actually measures - the sound still buffered in its own player, plus any it did not receive since the last beacon - and the Audio drawer shows it as Remote delay; that report sets the lead, so a stream that falls behind is pulled forward again instead of drifting. Sync offset trims the remote lead, a positive value sending the remote sound later and a negative one earlier, each by up to five seconds; it does not move Me. A busy video can make the browser fall behind for an instant; the stream then drops the stale sound, and a receiver whose own player has buffered hundreds of milliseconds behind the stream throws that buffer away and starts again on the live audio, so it returns to the live moment instead of staying a second behind.',
			'Me audio delay, in the same drawer, adds a manual trim to the wait the player already measures for this machine\'s own sound: the picture\'s own lag is taken out automatically, and this moves Me a little further if a residual remains. It applies with a remote output too - it trims only Me, not the remote. Leave it at zero when the picture and the sound already agree.',
			'Volume normalization, in the Audio drawer, evens out the difference between a quiet recording and a loud one. Off leaves the sound untouched. Slight, Mild and Aggressive never turn a loud track down: a track quieter than the house level is raised towards it, by about half, three quarters or all of the correction, up to about 8, 14 or 18 decibels. Inside the track a slow leveller closes the gap between quiet dialogue and loud action by about 3, 6 or 10 decibels - more on a film far below the house level, whose quiet dialogue would otherwise stay inaudible - leaving the action a little above the dialogue instead of following every line. One pass over the whole track measures it; the first play of an unmeasured track may wait a moment, then it is cached, and the next track in the queue is measured while the current one plays so the change is seamless. It is one setting for the whole player and it is remembered on this machine.',
			'The equalizer, in the same Audio drawer, is ten bands from 31 Hz to 16 kHz and a Bass boost shelf for the low end. Drag a band up or down, roll the wheel over it, or use the arrow keys; a double click puts that band back at zero. The preset row (Flat, Rock, Pop, Jazz, Classical, Vocal and Bass) sets a whole curve at once, and Flat also clears the bass boost. A band that is not flat builds the shared audio graph so the curve can be applied, and it reaches the remote outputs as well as this machine\'s own speaker. The curve is one setting for the player and is remembered on this machine.',
			'The Video section, above the equalizer, does two things. Its presets (Off, Clean, HD and Cinema) and the Sharpness slider add an unsharp mask with a little contrast and saturation to a video, so an SD picture reads closer to HD; it cannot invent detail, but edges and local contrast are what make it look sharper, and the same effect is applied to the picture on every machine the video is sent to. Every screen has a TV box above its L/name/R buttons, this machine (Me) included: the TV box sends the picture to that screen, while the L/name/R buttons send the sound, so the two are chosen separately. Turning Me\'s TV box off hides the picture on this screen and the player carries on as it does for a music file, while the sound and any other screen\'s picture keep going. There is no separate master switch: the boxes are the choice. The line under them reports what answered (ready, waiting, failed, or closed), so a machine that has not opened its screen is visible rather than guessed at. Quality (720p or 1080p) and Frame rate (15, 24 or 30) trade bandwidth for smoothness. The source machine draws the frames and sends them to each screen, so the picture does not depend on the receiving machine having the file; the viewer follows play, pause, seek and speed and carries the video\'s subtitles, and it closes when the track stops or another one starts. A server is left out because it has no screen.',
			'The line under the search box names the library this window is showing: this machine\'s own name for a local library, or the host it is relayed from for a remote one.',
			'On a phone it keeps playing with the screen off or the app in the background: the player asks the app to leave the view running while a track is playing, so the queue carries on to the next track instead of stopping when the screen sleeps.',
			'An audio track has no picture of its own, so the player can draw the sound instead and play that drawing as its picture: the tools panel in the player carries a Visualization choice of None, Equalizer (bars of the spectrum), Dots (colourful dots that dance, and now and then grow a face), Psychedelic (a tie-dye that swirls with the music) and Modern Art (painted strokes that follow the sound).',
			'The library has two draws, chosen by Layout in the configuration drawer: a list of rows, and a grid of pictures. Both show the same three things about a track, and nothing else from its file name: the artist, the album and the track name. A music file\'s own tags supply them. A video\'s name is read for the episode and its title — S03E06, 1x02 and Season 3 Episode 6 are all understood — and the quality, source, codec and release group are left out, so Doctor.Who.S03E06.720p.HDTV.x264 reads as Doctor Who, Season 3 and S03E06 (or the episode\'s own name when the file carries one).',
			'On a phone the window draws itself differently: the artists and albums become one line of pills each, scrolling sideways, and the tracks below them are cards — the picture, the title (up to two lines), the artist and album, and the time — with the list running right down to the player, so the time is always in reach.'
		],
		steps => [
			'Open Music; the library lists artists and albums from your media folders.',
			'Open the gear and press Archives in the folders row to include the archive drives as well as this machine; press it again to show only what is here.',
			'Click a track to play it; the transport along the top controls playback.',
			'For a track with no picture of its own, open the tools panel (the wrench in the player) and choose a Visualization; the drawing shows in the player\'s corner while the library is up, and takes the whole player in Theatre mode or fullscreen.',
			'Fullscreen (the player button, or F) fills the screen with the picture; moving the mouse brings back the top bar and the transport, and they fade away again when the pointer rests. The player bar also carries the equalizer and gear icons in fullscreen and the theatre, so the Audio and Configuration sheets can be opened without leaving the picture; the sheet floats above the video.',
			'A wheel over the picture moves through the track; on a trackpad, a sideways swipe does the same and up/down sets the volume. On a touchscreen, drag sideways to move through it and up or down to set the volume. The same gestures work in fullscreen, over the interface; the fullscreen button (or F) leaves fullscreen too.',
			'A wheel or trackpad scroll directly over the seek bar moves through the track, and the same over the volume bar turns it up or down.',
			'The gear opens the configuration drawer and the equalizer icon opens the Audio drawer. Both can be open together: the first stays where it is and the next opens beside it, so the folders, the outputs and the equalizer are all in reach. Drag either one by the bar across its top to move it anywhere on the screen, and press the X on that bar to close it.',
			'Open the Audio drawer (the equalizer icon beside the gear) to choose the audio output, or to send playback to another machine on the mesh.',
			'Each output has L, its name and R: press the centre for stereo, L for the left channel, or R for the right. On a computer with a stereo pair that is the left or right speaker alone; a phone or tablet plays the chosen channel through the speaker it has. Press the same side again to turn that output off.',
			'When a remote speaker is in use and you are watching a video on this screen, the player measures how far the picture on screen sits behind its clock, sends a hidden audio-only copy of the track at that adjusted lead, and holds this machine\'s own sound back by the same lag, so Me and the other room line up with the picture while the picture stays live. There is nothing to switch on: a video with a remote output is led automatically. With me as the only output no lead copy is made.',
			'If the other room and this screen still lead or lag each other, move Sync offset in the Audio drawer until they agree; a positive value sends the remote sound later and a negative one earlier, without moving the picture or Me.',
			'The Remote delay under Sync offset is what the other machine measures after the lead: the receiver\'s pipeline less the lead it was given and the picture\'s lag. Zero means it is in step with the frame on screen; a negative number means it is playing ahead of the picture. A number that keeps growing means the stream is falling behind, not that the trim is wrong.',
			'Choose Remote audio format in the Audio drawer: PCM carries the sound uncompressed and is the most responsive; Opus compresses it for a weak link and is decoded on the receiving machine. The choice applies as soon as it is picked (the stream restarts briefly).',
			'To even out volumes, open the Audio drawer and choose Volume normalization: Off, Slight, Mild or Aggressive. The setting applies as soon as it is picked and stays with this machine.',
			'To shape the sound, open the Audio drawer and use the equalizer: drag or roll a band, pick a preset, or raise the Bass boost. Flat returns the curve to zero and clears the boost.',
			'To sharpen a video, open the Audio drawer and choose a Video enhancement preset, or move Sharpness. To watch it on another screen, press the TV box above that machine\'s L/name/R buttons; press Me\'s TV box to show or hide the picture on this screen, and the L/name/R buttons choose each screen\'s sound. Pick Quality and Frame rate, and read the line under the boxes to see which screens answered.',
			'If a machine starts playing with no Music window to control it, open its websocket panel and press the square Stop beside the received track. The Receive music from other devices switch under it keeps that machine from being used as an output at all.'
		],
		related => [ 'studio', 'synth' ]
	},
	'video' => {
		title => 'Video', category => 'apps', app => 'video',
		verified => '2026-10-21',
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
			'Editor is a rich text editor for letters, notes and documents. Its variables can pull live values — including values from an appointment — so a document can fill itself in from your data.',
			'A microphone in the editor\'s toolbox dictates into the document: press it to listen and press it again to stop. It is the same dictation the keyboard uses - a pause ends the phrase, the house transcribes it and the Guide punctuates it - and the words join the text where the caret is. It learns the room\'s own quiet as it listens, so a fan or a steady hiss does not stop it hearing the pause.',
			'While it is being typed, a note is kept as a draft: this browser holds a copy against a crash or a refresh, and the house holds one that reaches every machine, so the words are there again when the window reopens.'
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
	'internet' => {
		title => 'Internet', category => 'apps', app => 'internet',
		templates => [ 'templates/internet/internet.html.ep', 'templates/web/web.html.ep', 'public/js/manager/internet.js' ],
		verified => '2026-10-28',
		summary => 'Web and Browse: saved pages with measures, and a real browser that counts site time.',
		body => [
			'Internet has two components. Web holds the pages the house fetched; each can be opened, or measured with the Measures tool. Browse opens a real browser in its own window on a computer (or its own screen on a phone), because a live page cannot run inside the manager window. The tab you used last is the tab Internet opens, so Web and Browse do not keep switching places.',
			'Browse counts the time each site is in front, but only in the JawnOS browser: a page opened in another browser is not counted, and neither is the Facebook app. Every domain you visit is also a bookmark. Press a domain to open it in the browser, or type an app beside it: the box suggests any appointment in the house that the visibility rule shows here and now, so an app the rule hides (by place, or by a lockdown) is not offered. Pick one to assign the domain, so facebook.com minutes land under the app you chose. While the JawnOS browser stays on that domain, the app\'s appointment runs; when you leave the site, close the tab or change app, it stops at the last moment the page was in front. Type a dash to stop counting the domain against an app.',
			'A domain you assigned opens two ways: its link opens the browser at the saved address, and the app name beside it opens that app in the manager exactly as its own window. The Browse tab shows today\'s site time beside each domain, and the time is kept per machine so the phone and the laptop do not blur together.',
			'To measure a live page, open a saved page from the Web tab with the measure icon. The browser opens with the picker on; click the value you want. JawnOS offers the shapes it can read and saves the one you pick, exactly as the Measures tool does for a fetched page.',
			'The browser is a separate surface on purpose: it has its own cookies and history, keeps the manager\'s bridges away from the pages you visit, and cannot reach the house\'s local address.'
		],
		steps => [
			'Open Internet from the start menu.',
			'Web lists the pages the house fetched; use the browser icon to open one, or the measures icon to point at a value in it.',
			'Browse takes an address and opens the JawnOS browser; time on each site appears under Site time today.',
			'To make a domain count toward an app, type the app name in its row and pick it; type a dash to clear it. Press the domain to open it, or the app name to open that app.',
			'A page opened in another browser is not counted; the count is per machine.'
		],
		related => [ 'web' ]
	},
	'web' => {
		title => 'Web', category => 'apps', app => 'web',
		templates => [ 'templates/web/web.html.ep', 'templates/web/web_measure_confirm.html.ep' ],
		verified => '2026-10-26',
		summary => 'The pages the house fetched, with measures.',
		body => [
			'Web is the saved-page component of Internet, useful for pulling a page up beside your work without leaving the desktop.',
			'To watch a number on a page, open the page in Web and click the Measures icon in its toolbar. Pick the measure from the list, then click the value on the page. Web tests the click and offers the shapes it can read: a JSON path for a feed, the table row and cell that hold the value, a label with the value beside it, or the plain element. Pick the shape whose Value column shows the number you want, then press Save.',
			'The shape is stored, not a page position, so a table that gains a row keeps reading the right cell; a JSON feed keeps the exact key. A measure reads from the workspace as a whole, so the phone can fetch the page while the selectors stay on the computer.'
		],
		related => [ 'internet', 'terminal' ]
	},
	'terminal' => {
		title => 'Terminal', category => 'apps', app => 'terminal',
		summary => 'A shell, in a window - on this machine or another one.',
		verified => '2026-10-21',
		body => [
			'Terminal is a real shell attached to the machine running JawnOS. It is where you do the hands-on work: scripts, checks, and the occasional bit of archaeology.',
			'The toolbar at the foot of the window switches views. Shell is the live session: click it and type straight into it, with colour, cursor keys, Backspace, Tab, Ctrl+C and the rest behaving as they do in a desktop terminal. Commands holds a short history of what you sent to the shell. Errors and Log are readable lists, each with its own Clear button in the header; the newest entry is always in view, and the list follows new entries while you are at the bottom.',
			'The status at the left of the toolbar names the machine the shell is running on. Press the server button beside it to open the terminal settings: connect back to this machine, or pick one of the machines linked to the house and connect to it over ssh. Each machine remembers its own login name and port; the port is 8022 by default, which is the sshd JawnOS runs elsewhere. Each Terminal window has its own shell, so switching here changes only this window. The panel also sets the text size.',
			'Open as many terminals as you need from the Terminal pin or the start menu: every window runs its own shell, can be moved and resized on its own, and wears its own tile on the taskbar. Minimising a window keeps its tile, so the taskbar is the quickest way to jump between them. Closing a window leaves its shell running on the server; the Open sessions list in the settings panel brings a closed one back into a window, and End closes a shell you no longer need.',
			'The code button in the toolbar opens the Coding agent\'s chatbox, so you can ask for a change in words and watch it run the commands and ship the result without leaving the terminal. It keeps its own conversation. The bar drags the panel anywhere on the screen, and + in the bar opens another agent, each with its own thread.',
		],
		steps => [
			'Open Terminal; it opens a session on the host machine.',
			'Open it again for another terminal; each window keeps its own shell and taskbar tile.',
			'Run commands as you would in any shell, or use Commands to keep a history of them.',
			'Press the server button to switch this window to another linked machine over ssh, or to reopen a closed session.',
			'Use Errors and Log to read what went wrong; Clear in either header empties that list.',
			'Press the code button to hand a task to the Coding agent — or + in its bar for another one, so several can work at once.'
		],
		related => [ 'ide', 'process_monitor' ]
	},
	'network' => {
		title => 'Network', category => 'apps', app => 'network',
		templates => [ 'templates/apps/network.html.ep', 'public/js/manager/network.js' ],
		verified => '2026-10-26',
		summary => 'Interfaces, Wi-Fi, VPN, the machines on the mesh, and the phone.',
		body => [
			'Network is the app for the connection itself. It opens from the start menu and shows four things in one window: this machine\'s interfaces, its Wi-Fi, its VPN, and a read-only view of the machines on the mesh. A fifth section appears on a phone.',
			'Interfaces lists every network interface with its state, MAC address, IPv4 and IPv6 addresses, whether the address came from DHCP or was set by hand, and the bytes received and sent. The list refreshes itself every fifteen seconds while the window is open, and Refresh reads it again at once. An interface carries an Up or Down button beside its state, for bringing a link up or taking it down.',
			'Wi-Fi is driven through iwd. The Radio button turns the wireless adapter on or off, Scan lists the networks in range with their security and signal, and Connect takes a passphrase for a secured network. Disconnect drops the current network and Forget removes a saved one. A machine with no wireless adapter says so instead of showing an empty list.',
			'VPN reports what is really running. When Tailscale is installed it shows whether the tailnet is up, its address and any exit node. WireGuard configurations in /etc/wireguard and OpenVPN client configurations in /etc/openvpn/client are listed with Start and Stop buttons that drive their systemd units. When none of these is configured the section says so; it never pretends a connection exists.',
			'Devices and mesh is a compact, read-only summary: the machines the house knows and the interfaces each one reaches a network with, built from the same device listing the Dev panel uses. The button opens Configure -> Dev for the full panel - scanning, purposes, privileges and the router cards - so the Network app never duplicates it.',
			'On Android, when the JawnOS app exposes its network bridge, the Android section shows the phone\'s current connection and VPN and offers Scan, Connect, Disconnect, and buttons that open the phone\'s own Wi-Fi and VPN settings. The Linux sections remain the machine\'s own network, not the phone\'s.',
			'On the live image, systemd-networkd brings up wired and wireless interfaces over DHCP, iwd handles Wi-Fi, and systemd-resolved answers DNS. In QEMU with user-mode networking the guest receives 10.0.2.15 and a working gateway automatically.'
		],
		steps => [
			'Open Network from the system category of the start menu.',
			'Read the Interfaces table, or press Refresh to read it again.',
			'In Wi-Fi, press Radio to turn the adapter on, then Scan.',
			'Type the passphrase in a secured network\'s row and press Connect; Disconnect drops it and Forget removes it from the saved list.',
			'In VPN, start or stop Tailscale, or a WireGuard or OpenVPN configuration that is already on the machine.',
			'Press Open Configure -> Dev for the full machine and network panel.',
			'On a phone, use the Android section to scan, connect or open the system Wi-Fi and VPN settings.'
		],
		related => [ 'devices_and_mesh', 'configure', 'terminal', 'start_menu' ]
	},
	'camera' => {
		title => 'Camera', category => 'apps', app => 'camera',
		'templates' => [ 'templates/apps/camera.html.ep', 'public/js/manager/camera.js' ],
		controls => [ 'Take a photo', 'Record a video', 'Unclaimed media', 'Select all', 'Approved' ],
		verified => '2026-10-28',
		summary => 'The device camera and video recorder, plus the pool of unclaimed media waiting to be filed.',
		body => [
			'Camera takes a photo or records a video. In the app it opens the device camera and its video recorder (window.JawnCamera), so you get a viewfinder you can see and the camera\'s own processing. On the desktop and in a browser it uses the machine\'s own webcam through getUserMedia.',
			'A capture is filed under the Camera app. In the app the same pair of buttons also rides in an appointment\'s media group - Camera (native) and Video (native) - where the capture lands on the appointment instead.',
			'A capture taken in the Camera app itself - and media an agent generated without an appointment - waits in Unclaimed media with a one-week warranty. Tick the items you want (or Select all), then search for an appointment name and press Approved, or drop them onto the drop zone.',
			'On the desktop and in a browser, Source chooses which camera the next capture uses: Auto, Front or Back, and then every video input the machine reports by name. The choice is remembered on that machine, so the same lens is used next time. On a phone the OS camera chooses its own lens.'
		],
		steps => [
			'Open Camera from the start menu, or pin it to the taskbar.',
			'Choose a Source when the machine has more than one camera.',
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
	'people' => {
		title => 'People', category => 'apps', app => 'people',
		templates => [ 'templates/apps/people.html.ep', 'templates/apps/people_person.html.ep', 'public/js/manager/people.js' ],
		controls => [ 'Scan my crest', 'Take picture', 'Upload a photo', 'Download card', 'Save card here', 'Show QR', 'Write to NFC tag', 'Import a crest card', 'Import a crest code', 'I have met this crest', 'Save name', 'Verify a photo', 'Refresh', 'Publish', 'Published', 'Upload a logo', 'Open their page' ],
		verified => '2026-10-27',
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
			'Clicking a person opens their card. Their own main picture is the portrait; when a crest is linked it sits beside it. The card carries no scan, upload, card, QR, NFC or rename controls - the drawing belongs to their house. It offers Homepage, Store, Message, I have met this crest, a control to link a known crest, and Open Relational, which starts Relational already focused on that person. The card also carries the person\'s Relationship: Friend, Stranger or Enemy. It is one choice, not a list, and it is numbered on the same scale as a place (Friend 1, Stranger 2, Enemy 3). An Enemy in the house\'s local presence starts a lockdown: other apps close, and only Security stays open until the Enemy\'s running appointment is stopped.',
			'Each construct tab lists the constructs of that kind and their members. A row opens to show who belongs to it, the names it answers to, and its crest controls. Relational is where the structure itself is made and changed; People reads it.',
			'A construct can answer to more than one name. Open its row and type another name under Also called; that name then works in the Guide, on the watch and in commands sent to another machine. The x beside a name forgets it. A word that already means something else is refused, because it would make every use of that word a question; another house\'s construct is read-only here, so its names stay its own.'
		],
		steps => [
			'Open People from the start menu. Me holds the house crest; People lists the people, and the construct tabs list the constructs they belong to.',
			'To make a person, add them in Relational; the People row follows automatically.',
			'On a person\'s card, set Relationship to Friend, Stranger or Enemy; the choice is kept on the person and read by the visibility rule.',
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
	},
	'notes' => {
		title => 'Notes', category => 'apps', app => 'notes',
		verified => '2026-10-24',
		summary => 'Free-form notes, and the drafts of notes being typed in an appointment.',
		body => [
			'Notes is the house\'s free-form notebook. Every note is a row of its own, newest first: a watch that heard something that was not a command lands here, and so does anything typed in the box at the foot.',
			'Notes ride the house sync, so a note written on one machine appears on the rest. Click a note to load it into the box for editing, drag one onto an appointment window to fold it into that app\'s notes, and the X is a two-click delete.',
			'While an appointment\'s Notes field is being typed into, the words are kept as a draft: this browser holds a copy on every keystroke, against a crash or a refresh, and the house holds one in this same table so it reaches every machine. The draft is rewritten in place as the words grow - it is one row, not a new note per save - and the list shows it under the appointment it belongs to, marked Draft, until the appointment is saved, which clears it.',
			'A browser that still held older notes in its own storage hands every non-empty one over the first time it opens the manager after this, so they turn up here under their appointment names instead of having to be found by hand. A draft the house already has is kept, so an old copy cannot undo newer words.'
		],
		steps => [
			'Open Notes and type in the box at the foot; press Save (Enter saves on a desk, Shift+Enter makes a line).',
			'Click a note to load it into the box and edit it; saving updates that row.',
			'Drag a note onto an appointment window to fold it into that app\'s notes.',
			'Press X twice to delete a note.'
		],
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
	},
	'travel' => {
		title => 'Travel', category => 'apps', app => 'travel',
		templates => [ 'templates/travel/travel.html.ep', 'public/js/manager/travel.js', 'public/js/manager/mapengine.js', 'public/js/manager/mapmarkers.js', 'public/js/manager/continentprinter.js' ],
		controls => [ 'Configure', 'Now', 'Delete', 'Guess the gaps' ],
		verified => '2026-10-24',
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
		title => 'Relational', category => 'apps', app => 'relational',
		templates => [ 'templates/relational/workspace.html.ep', 'public/js/manager/relational.js' ],
		verified => '2026-10-27',
		summary => 'The social constructs, and the relationships between them.',
		body => [
			'Relational is where the house\'s social structure is made: people, teams, clubs, communities, projects, institutions, governments, corporations, places, vendors and events. The window is a workspace. The left column is the library of constructs, one tab per kind, with a search and a New name box; the right side is the construct you are working on, with one drop group for each kind it can belong to.',
			'Adding is deliberately two ways. On a desk, drag a card from the library onto the matching group (a team card onto Teams); on a phone, press the + on the card. Either way the link is written both ways, so the team lists the person and the person wears the team. Remove a link with the x on the member, or drag the member to Drop here to remove.',
			'A construct is a named row with a kind (its pos, or its mab when it belongs to a second kind). Details on the focused card changes that kind; the tree and calculator tools of the old matcher are not part of this board.',
			'A person construct is also a person in People: the window adds the People row for it and keeps their construct chips up to date. Deleting the construct removes the person; changing its kind away from person only hides it, so an accidental change can be undone. Opening Relational from a Person card focuses that person. A person\'s Friend, Stranger or Enemy relationship is set on their People card, not here: it is one numbered measure that the visibility rule reads, and it is not a construct membership.',
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
		title => 'Accounting', category => 'apps', app => 'budget',
		verified => '2026-10-24',
		templates => [ 'templates/budget.html.ep', 'templates/budget_reconcile.html.ep', 'public/js/manager/budget.js' ],
		summary => 'Accrual income statement and balance sheet, cash flow, account activity, trial balance, receivables, scheduled payables, the ledger and bank reconciliation.',
		body => [
			'Accounting turns your transaction history into the statements a business reads: an income statement, a balance sheet, a cash flow statement, account activity, receivables, payables, the ledger of what has moved, the document ledger of invoices and quotes, a day book, and a reconciliation screen for a bank statement. The income statement and the balance sheet are kept on an accrual basis - an invoice is revenue when it is written and a bill is a cost when it arrives, whether or not the money has moved. The cash flow statement is the cash view, so it reports what actually moved through the accounts in its period.',
			'The income statement lists income by account, then cost of goods sold and gross profit, then operating expenses, with the prior period beside it, and shows net income. The balance sheet lists every asset account the journal holds - bank accounts, receivables, inventory - then liabilities such as Accounts Payable and sales tax, and the difference as equity. Because both are read from the double-entry journal, they agree with the Trial Balance. The cash flow statement starts from receipts and payments, then shows transfers between accounts and any balance adjustment, and ties the opening and closing cash. Account activity is each account\'s opening, receipts, payments, transfers and closing for the period. Receivables ages every unpaid invoice from the date it was written; Payables ages every bill still owed.',
			'Trial Balance is the double-entry view. Every money move is posted once as a balanced entry: a bank account against the app that earned or spent it, an invoice against Accounts Receivable with the revenue and sales tax on the other side, a payment against the receivable when it settles an invoice, and a transfer against the other bank account. A stocked item moves through Inventory: a purchase debits Inventory instead of the expense, and a sale takes its moving-average cost out of Inventory into Cost of Goods Sold. A bill credits Accounts Payable instead of a bank account, and paying it moves the payable to the bank. The journal is built from the ledger and the documents, so Rebuild journal can always regenerate it; the screen lists each account\'s debit and credit balance and says whether debits equal credits. The clearing line is a transfer whose other leg was never recorded - it should fall to zero as those are repaired.',
			'The ledger is drawn per account; a transaction with no account attached will not appear on it, so transactions are recorded with a real account. The window and its scope (hour, day, week, month, year) come from the app\'s own settings, so a view you set up is the view you come back to.',
			'Each app that keeps a budget still has its budget light in its header; that is the app\'s own measure, not this app\'s reports. Opening it shows the period against its budget, the pace it is on, and — when what is counted is over the budget — a Recommended button. Pressing it sets the budget to the app\'s own typical period, keeping the budget\'s scope, measure and floor or ceiling, and fills the matching row on the app\'s card in Configure. The light also lists the budget and the app\'s typical amount at the budget\'s own scope and the next two larger ones — a per-hour budget reads as an hour, a day and a week, with no meaningless per-minute figure. While a scope is still running, the budget-vs-typical and this-vs-budget rows are read against the share of the scope that has elapsed, so an early morning is not read as a fall. A duration budget counts time where it was actually spent, so a session that runs past midnight gives each period its own share rather than putting the whole night on the day it began. While a session is running, an open light follows it, so the time it names keeps growing instead of standing at the value from when the panel was opened. The light reopens with its app if it was left open when the window was closed.',
			'Reconcile is the bank side. Import a statement file — CSV, QIF or OFX — for one account, with the date order the file uses (month first or day first), and Accounting matches each line to what it already holds by amount within three days. The screen lists the lines it found, the lines it did not, and the money in Accounting that the statement does not show, so the difference between the two sides is visible before anything is written. A line the ledger holds in pieces — an e-transfer whose service charge was recorded on its own, as Libro writes it — is settled from those rows and only the remainder is offered to record; a line with an existing transfer leg on another account is recorded as the missing leg of that transfer, so the other account is left alone; a line before the account\'s last inventory balance is shown as covered by it rather than offered again. Each line left to record can name its own app and whether it is income, an expense or a transfer; when the house has paid the same merchant before, the app and item are filled in from that history and shown as a suggestion for you to confirm. Pressing Reconcile first records those lines, then writes the statement\'s ending balance as the account\'s inventory balance: from that point on the balance is measured from the bank\'s own figure, and the Delta line on the screen is that figure minus what the ledger holds.',
			'Payables is the other side of the ledger. Record a bill with its vendor, app, item, total, tax and date; Accounting books the expense and the payable at once, so the cost belongs to the period the bill was written even though no money moved. The table ages every open bill from its date, shows what has been paid against it and what is still owed, and a Pay control settles it from a chosen bank account - in full or in part - which moves the payable to that account. Delete removes the bill and any payments against it. The total owed is the Accounts Payable credit the trial balance carries.',
			'A bill can repeat. Choose Every week, Every 2 weeks, Every 30 days, Every month, Every quarter or Every year when you record it, and Accounting keeps a schedule. A custom schedule can be typed instead: an interval, then for how long, so 1d for -2w is every day for two weeks and monthly for 1y is the first of each month for a year. Without a for it keeps repeating. The same field takes words too - "every third Saturday of the month", "every Tuesday for 6 weeks except on holidays", "the next five full moons", "my mom\'s next 5 birthdays" - and the Guide turns them into the due dates; "except on holidays" skips the common US/Canada holidays. If it needs a detail, it opens a Guide associate to ask and then finishes the schedule. Each due date becomes a real bill on that date - the payable is not raised early - and any dates already past are filled in when the schedule is first read. Months follow the calendar, so a bill on the 31st shortens to February\'s last day and returns to the 31st afterwards, and a leap February has 29 days. A schedule can be paused and resumed; one whose for has passed reads ended, and deleting it leaves the bills it already made. The first due date is the date typed beside the rate.',
			'Payments named in bank notifications book themselves. When a notification from a bank account the house knows says you spent an amount at a merchant - Koho writes "You spent $29.38 at PUBLIC MOBILE SELF" - Accounting raises the bill and pays it from the account the notification came from at once, with no press, filling the app from the house\'s history with that merchant. Payables lists the last few at the top as Booked from notifications so you can see what it did; Undo there removes the bill and its payment and leaves that notification unbooked. A purchase a statement import or a typed transaction already recorded is not booked a second time.',
		],
		steps => [
			'Open Accounting; the display dropdown chooses the statement — Income Statement, Balance Sheet, Cash Flow, Account Activity, Ledger, Receivables, Payables, Invoices, Day Book or Reconcile.',
			'Change the scope along the top to set the period — this month, last quarter, this year — and the accounts the statements cover.',
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
	},
	'store' => {
		title => 'Store', category => 'apps', app => 'store',
		verified => '2026-10-21',
		templates => [ 'templates/store/store.html.ep', 'templates/store/category.html.ep', 'templates/store/item.html.ep', 'templates/store/item_selection.html.ep', 'templates/store/list.html.ep', 'templates/store/register.html.ep', 'templates/store/correspondence.html.ep', 'templates/store/customer.html.ep', 'public/css/store.css', 'public/js/store.js' ],
		summary => 'Items, models, options, quotes and invoices.',
		body => [
			'Store is the catalogue and the paperwork. Items carry models and options, each with its own prices; a quote or invoice is built from them and prints to a white, house-styled sheet that can be delivered by email.',
			'Browsing is arranged as shelves: the category rail on the left shows only categories that hold something, with the number of items beside each, and choosing one fills the item grid. The subcategory chips under the rail narrow that shelf, the type chips at the top filter by product, service, event, place or media, and the sort control orders by name or price. Search runs across the whole store once two characters are typed. The result count says how many items the filters leave; Clear puts every filter back.',
			'Choosing an item opens its details in a pane beside the grid rather than over it, so the shelves stay in view; Back to items (or the close button) returns to them. The price summary stays pinned to the foot of that pane while the models and options scroll, and it can be tapped to edit a price.',
			'With a customer loaded, the foot of the window carries four labelled actions. Quotes and Invoices list the documents themselves. Register is a sales journal: every invoice or sale for that customer with its total, amount paid and balance, and each payment indented beneath the document it settled. Correspondence is the other journal: the emails and chats the house and that customer exchanged, newest first, showing the channel, direction, subject and a readable preview.',
			'The movement dropdown uses the house\'s own words: Selling (an income movement) is what this house has available, and Buying (an expense movement) is a purchase the house makes. The stored movement values are unchanged, so existing quotes, invoices and reports keep working.',
			'Recording a payment against a document updates its balance and closes it when the balance reaches zero.',
			'A visitor who asks for a ticket sees the privacy notice before the form and must acknowledge it; the acknowledgement is stored with the request. The store and the public homepage both link to the full privacy policy, which names the controller, the data processed, the legal basis, retention, the cookies and local storage used, and how to exercise a data right.'
		],
		steps => [
			'Open Store and add the items you sell, each with its models and options and their prices.',
			'Use the category rail and the type chips to narrow the shelves; search finds an item by name anywhere in the store.',
			'Build a quote from those items and options; the totals are worked out as you go.',
			'When the quote is accepted, move it to an invoice — it converts and the quote is consumed.',
			'Email the invoice to the customer, or print it to the house-styled sheet.',
			'Record a payment against it; the balance falls and it closes at zero.'
		],
		related => [ 'budget', 'invoices_payments', 'market', 'crypto' ]
	},
	'crypto' => {
		title => 'Crypto wallets and rates', category => 'functions',
		verified => '2026-10-27',
		templates => [ 'templates/configure/pay_setting_list.html.ep', 'templates/configure/crypto_setting_list.html.ep', 'templates/configure/appointment_list.html.ep', 'templates/store/crypto_payment.html.ep', 'templates/store/printer/header.html.ep', 'templates/store/pay_box.html.ep', 'templates/store/list.html.ep', 'public/js/manager/configure.js', 'public/js/manager/transaction.js', 'public/js/store.js' ],
		summary => 'Wallet accounts that hold a coin, per-invoice receiving addresses from an xpub, live fiat and coin rates, and cost or market valuation.',
		body => [
			'A wallet is an ordinary account whose Payment Type is crypto. It keeps a public address and the coin it holds, and it records transactions, transfers and statements like any other account. JawnOS never holds a key, cannot spend from a wallet, and refuses anything that looks like a seed phrase or a private key; if a page ever asks for one, it is not JawnOS.',
			'A hardware wallet is the right home for coins you are not about to spend: the device keeps the key, and JawnOS only ever sees the public address. For the widest coin coverage, Ledger Nano S Plus or Flex; for open-source firmware, Trezor Safe 3/5 or BitBox02; if it is Bitcoin only, Coldcard or Blockstream Jade. Buy direct from the maker, never a reseller or a marketplace, and never trust a device that arrives already set up. Write the recovery phrase on paper or steel, keep it offline, and never type it into a computer or a website. Review this recommendation every three to six months, and update the device firmware in the same pass: devices, prices and coin support move.',
			'A wallet can issue a fresh receiving address for every invoice. In Configure -> App, paste the Bitcoin account xpub (xpub, ypub or zpub) into Account xpub; it is public, so it can derive addresses and cannot spend. The invoice then owns its own address: the first time it is written, and again when it is opened for payment or saved after the key was added, JawnOS derives the next unused address at /0/index and keeps it with the invoice. A wallet with no xpub keeps the single saved address. If the wallet\'s own app does not show an xpub (Ledger Live does not), connect the device to Sparrow or Electrum on the laptop and copy the account xpub from there. Compare the first five addresses with the wallet app\'s Receive list; if they do not match, the path or script type is wrong, so clear the key and check the wallet. Only Bitcoin is supported for this so far.',
			'A crypto payment cannot be reversed or refused by this server. The QR on an invoice carries the exact amount, and the invoice panel refuses to record a payment once the balance is zero, so the ledger cannot count a second payment twice. Coins sent a second time still arrive, though: the wallet shows them, and the payment panel reports an overpayment so the seller can return the extra deliberately.',
			'Configure -> Plat -> Pay -> Crypto owns the shared parts: which coins may be used, the cached exchange rates, and how a holding is valued. Cost is the money recorded when the coin arrived, which is the safe figure for statements. Market is the native holding at today\'s rate, which moves with the price. The wallet list shows both so the difference is visible.',
			'Every conversion in the app now reads the same rate snapshot, including a measure typed as 5USD to CAD or 0.01BTC to CAD. One public, keyless call to Coinbase returns every fiat code and every coin; the snapshot keeps the most-used fiat currencies (the top 50 the source answers) and the enabled coins. A half-hour loop refreshes it, and Refresh now asks at once. While no snapshot has been read, the older built-in constants still answer. An offline house keeps its last snapshot rather than losing its rates.',
			'Currency tracking keeps a history without an appointment. Tick it and every six hours one measure appointment is written into the app chosen under History app - Canadian Dollar by default, since that is the app this house already used, or Markets if you prefer - with a value for every tracked fiat code. The Measures app charts those points. Choosing a different History app while tracking is on writes the first point there at once. Stop the old app\'s own appointment once the tick is on, or both will write. The same snapshot also fills the Measures app\'s PV column: every currency row, plus a row for each enabled coin, shows one unit valued in the reporting currency.',
			'In a transaction, a wallet account is read in its own coin: type the native amount and the form shows what it is worth, while the ledger stores the house\'s reporting-currency value so every budget and statement still sums one currency. A transfer between two wallets must stay in the same coin on both sides; moving between a wallet and a bank is a sale and a purchase, not a transfer, and the app will say so rather than write a wrong figure.',
			'An invoice in the Store carries a crypto action when a wallet exists. It shows the coin, the amount for the balance, the invoice\'s own receiving address and a QR. The printed or on-screen invoice carries one QR: a BIP21 payment request (bitcoin:address?amount=...) when it is a single unpaid invoice with a Bitcoin wallet, and the public invoice link otherwise. After the buyer sends the coin, type the amount and txid and press Verify & record. A payer\'s PAY1Z proof, when pasted, is checked against their crest and countersigned with this house\'s; the txid is carried, not checked against the chain. On a device with a fingerprint the record asks for it; a device without one (a laptop, or a tablet with only a PIN) asks another fingerprinted device in the house. Only when the house has no fingerprinted device does the signed-in citizen record it.',
			'The coin list carries Bitcoin, Ethereum, USD Coin, Tether, Litecoin, Solana, Dogecoin, XRP, Cardano, BNB, TRON, Avalanche, Chainlink, Polkadot, Bitcoin Cash, Stellar, Cosmos and Toncoin. Only the ticked ones appear when a wallet or a payment picks a coin.',
			'To pay another house, open Configure -> Plat -> Pay -> Crypto -> Make a payment proof: paste the seller\'s crest uuid (their Store crypto panel shows it), the invoice ref, coin, amount, address and txid, then sign with this house\'s crest. Hand the PAY1Z code (or its QR) to the seller; their panel verifies it and countersigns the same bytes.',
		],
		steps => [
			'Open Configure -> Plat -> Pay and make sure the coins you want are ticked.',
			'Press Refresh now once; the rate table and the last-read time show what the house will use.',
			'In Configure -> App, make the account, turn on Payment Type, set it to crypto, then fill in the coin, network, public address and a label.',
			'Use a receive address from a hardware wallet you control, not an exchange deposit address; copy it into the wallet card, confirm it on the device screen, and send a small test amount before relying on it.',
			'For a fresh address on every invoice, paste the Bitcoin account xpub into Account xpub and compare the next invoice address it reports with the wallet app\'s Receive list. Bitcoin only, and never a private key or seed phrase.',
			'Record a transaction from that account in the app: the amount is in the coin, and the line beside it shows the money value before you save.',
			'Read the wallet list in Plat -> Pay -> Crypto for the holding, its cost and its market value; choose which one the rest of the page treats as the value.',
			'Tick Currency tracking if you want rate history: it writes a point every six hours into the selected History app (Canadian Dollar or Markets by default), and the Measures app charts it.',
			'Pick a different History app if the currency measures should live elsewhere; selecting one while tracking is on writes the first point there straight away.',
			'To take a crypto payment, open the customer\'s invoices in the Store, press the wallet icon on the invoice, send the shown amount to the address, then fill in the amount and txid (and paste the buyer\'s PAY1Z proof if they gave one) and press Verify & record.',
			'Print or open an unpaid invoice: its single QR is the exact-amount payment request. A second send cannot be stopped on the chain; the panel will not record it after the balance reaches zero, so return any excess from the wallet.',
			'To pay another house, build a PAY1Z proof under Configure -> Plat -> Pay -> Crypto -> Make a payment proof and give the seller the code; they verify and countersign it when they record the payment.',
			'Stop the currency app\'s old updating appointment once tracking is on, so the history has one writer.'
		],
		related => [ 'budget', 'store', 'configure' ]
	},
	'pay' => {
		title => 'Taking payment online', category => 'functions', verified => '2026-10-27',
		templates => [ 'templates/configure/pay_setting_list.html.ep', 'templates/configure/crypto_setting_list.html.ep', 'templates/store/pay_box.html.ep', 'templates/store/printer/header.html.ep', 'templates/pay/message.html.ep', 'templates/pay/return.html.ep', 'public/js/manager/configure.js' ],
		summary => 'Stripe, Square, PayPal and Interac e-Transfer on a public invoice, beside the crypto wallets they share a page with.',
		body => [
			'Configure -> Plat -> Pay is one page with Crypto as its first section and the hosted checkouts below it. The switch at the top turns every online method on or off; the currency is the house reporting currency, and the public address is what a provider redirects back to and what it posts a webhook to. Leave the address blank to use this house\'s public name on port 3000, or set it when a tunnel or proxy answers on another address.',
			'Stripe, Square and PayPal each create a hosted checkout for the exact invoice balance. The customer types card or PayPal details on the provider\'s page, never here, and returns to this house. The return page asks the provider what happened and records the payment; a webhook does the same when the house is reachable from the internet. Either path is safe to repeat: the provider reference is stored on the payment, so a return and a webhook cannot count the same money twice.',
			'Keys are sealed in the same way as an AI provider key. A secret field left blank keeps the saved value; type a new one to replace it, or press Clear. Test keys asks the provider a harmless question and reports whether it answered. Stripe needs the secret key and, for webhooks, the signing secret. Square needs the access token, a location id, the signature key, and the exact webhook URL Square shows if it differs from the one this page prints. PayPal needs the client id, the secret, and the webhook id.',
			'Every payment is booked as an ordinary income transaction on the account chosen for that provider, so a statement, budget or reconciliation sees it like any other money. Without a chosen account the first matching credit account is used, and Interac looks for an interac account first. The payment is also pushed onto the invoice, which falls by the amount and closes at zero. A partial payment leaves the invoice open for the rest.',
			'Interac e-Transfer has no consumer API, so JawnOS reads the notification letters that already arrive in the mailbox. English and French notices are both understood. With Autodeposit on, the money lands without a question and the invoice is matched by its reference, then by the exact amount, then by the sender. A notification is staged for a person unless Record automatically is ticked, and even then only when the money is already deposited and exactly one invoice carries the reference. Without Autodeposit the sender\'s security question has to be answered by a person; record the transfer after it has landed. A bank or payment service that can forward the same facts can POST amount, currency, sender, reference, memo, deposited and an optional invoice to the Forwarder URL, whose token is a password.',
			'An unpaid invoice\'s public page carries the pay buttons. A provider appears only when it is switched on and has its keys, so a half-finished panel never offers a button that cannot complete. The e-Transfer section prints the receiving address, the amount and the invoice reference, and the invoice\'s QR still carries its public link. Nothing is charged until the customer confirms on the provider\'s page.',
			'JawnOS records the gross amount the provider reports. A provider fee, a refund or a chargeback is handled at the provider; refunding there and deleting the payment\'s income transaction here puts the invoice balance back and reopens it. Card data never touches this machine, and a webhook is only believed after its signature verifies against the key saved on this page.'
		],
		steps => [
			'Open Configure -> Plat -> Pay and tick Online payments.',
			'Set the public address if the house is reached through a tunnel or a name other than its own; otherwise leave it blank.',
			'For cards, open Stripe, paste the secret key and the webhook signing secret, choose the account the money books to, and press Test keys.',
			'For Square, paste the access token, choose Production or Sandbox, set the location id, paste the signature key, and press Test keys.',
			'For PayPal, paste the client id, secret and webhook id, choose the account, and press Test keys.',
			'Add the printed webhook URL at the provider (Stripe: checkout.session.completed and checkout.session.async_payment_succeeded; Square: payment.updated; PayPal: CHECKOUT.ORDER.APPROVED and PAYMENT.CAPTURE.COMPLETED).',
			'For e-Transfer, set the receiving email, tick Autodeposit when the address has it, choose the account, and tick Watch the inbox.',
			'Open an unpaid invoice\'s public page (the link in its QR or the emailed sheet) and press a pay button; finish on the provider\'s page and come back.',
			'Check the invoice: the payment is listed, the balance has fallen, and the income transaction is on the chosen account.',
			'For e-Transfer, open Pay after the notification arrives, choose the invoice if the match is ambiguous, and press Record; or tick Record automatically once the references are reliable.',
			'To refund, refund at the provider, then delete the payment\'s income transaction so the invoice reopens.',
			'For crypto wallets and rates, read the Crypto section on the same page; it behaves exactly as it did under Plat -> Crypto.'
		],
		related => [ 'crypto', 'store', 'invoices_payments', 'configure' ]
	},
	'warehouse' => {
		title => 'Warehouse', category => 'apps', app => 'warehouse',
		summary => 'Money and goods tracked per place.',
		body => [
			'Warehouse tracks stock per place: what is where and how much of it. Packaging carries real quantities (a carton of twelve, a box of nails by weight), and shelf life means expired stock is swept up on its own.',
			'Stock is a physical ledger, not a claim on who paid. A purchase adds stock through its transaction; Stock in adds what arrived without one - a gift, something found, a transfer in - and carries no money. A sale, a consumption or an expiry takes stock out. Stock in takes the item and the amount together: 4260mL for a 12-pack of 355mL, or 12 each if you count packs.',
			'An app can move stock from its own quantity field. Set Stock Movement to Consume or Produce in the app\'s Configure, and set Stock Item if the warehouse name differs from the app\'s name. A Record moves at once; a Start/Stop session moves when it stops, using the amount typed at the start, so a cancelled session never touches the shelf. Only a real measure moves stock - a volume, a mass, a length or a count; hours and money are not stock.',
			'Consume takes only what is on the shelf at that place. Anything beyond it is recorded as Usage: the drink that came from outside the warehouse is counted in the moves ledger and the item\'s journal, but it does not make the shelf negative. When a pack is bought later, the purchase fills the shelf and the next consumption comes out of it; when that runs out, consumption goes back to Usage. That is how a daily Coke bought for you and a 12-pack you bought yourself live in one account.',
			'Every stock movement is journalled with its reason, and a moves ledger folds stock and money into one signed list.'
		],
		steps => [
			'Open Warehouse and set up the places you keep stock in.',
			'Add your products; where a product ships in packaging, give the packaging its real quantity.',
			'Use Stock in for what arrived without a purchase: a gift, something found, a transfer in.',
			'On an app whose amount you want counted, set Stock Movement to Consume (or Produce) and Stock Item if its warehouse name differs.',
			'Move stock in and out - each move is journalled with its reason.',
			'Read the moves ledger to see goods and money together; Usage rows are consumption that had no shelf to come from.'
		],
		related => [ 'inventory', 'market', 'moves_ledger' ]
	},
	'market' => {
		title => 'Market', category => 'apps', app => 'market',
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
		verified => '2026-10-24',
		summary => 'An app\'s own record of what it holds and has been up to.',
		body => [
			'Inventory is the shared surface behind the apps: it holds the entries an app has recorded — a measure, a document, a report — and shows them together, with statistics. The Evaluation report and the controls that run it live at the foot of the app itself.',
			'When Duration is shown, in Historical and Allocation alike, time is counted where it was actually spent: a session that runs from late evening into the next morning gives each day, hour and weekday the part that happened in it, while its occurrence stays with the period it started in. The same split is used by the app\'s duration budget, so an overnight session does not land wholly on the day it began.'
		],
		related => [ 'evaluation', 'measures', 'warehouse' ]
	},
	'chat' => {
		title => 'Chat', category => 'apps', app => 'chat',
		templates => [ 'templates/apps/chat.html.ep', 'templates/mail/mailbox.html.ep', 'templates/mail/conversation.html.ep', 'templates/mail/message.html.ep', 'templates/mail/chat_sections.html.ep', 'templates/soft_keyboard.html.ep', 'templates/ime.html.ep', 'public/js/manager/chat.js', 'public/js/manager/soft_keyboard.js', 'public/css/chat.css', 'public/css/soft_keyboard.css' ],
		verified => '2026-10-28',
		summary => 'The house\'s conversations: sms, the dial, pass threads and lora.',
		body => [
			'Chat gathers the ways the house talks, split out of the mailbox as an app of its own: sms to phones, the dial (the house\'s radio, where a set of appointments picked across the social construct groups names one thread and a tab only hears messages addressed to the set it is tuned to), the list of those sets, the pass threads the house opens for its guests, lora, and Rooms — a junderground dial for other houses.',
			'Friends is one row per person the house knows, carrying every road they can be reached on: their name joins to a ticket when one is open for them, and their number is the thread until then. A person who keeps more than one line (a home number, a work number - set under Configure, in the app\'s Phones tile) shows them under their name, and the transport dropdown offers sms once per number, so the next text can go to the work line rather than the mobile.',
			'A letter is filed only when its sender is trusted: a citizen\'s or resident\'s words are stored and synced, while a guest\'s are heard live by whoever is tuned in and never written down - except on the guest\'s own pass thread, the one conversation the house opened for them.',
			'A paperclip beside the composer attaches files to the next message; they ride the message on the ticket road and go as an MMS on the phone road. The picture and its words travel as one message, not a text beside a picture. The phone sends it itself when JawnOS is its default SMS app and files the sent copy in the phone\'s own message thread, so the stock thread and the house\'s conversation hold the same message under the same id rather than two copies; otherwise it opens the phone\'s messaging app with the picture and number filled in, ready to send. A picture larger than a carrier will take is shrunk to fit first.',
			'Advertise opens the tuned set to guests, who may then tune the same channel from the public page. Room bubbles that are not kept are dashed to say so.',
			'The conversation is drawn as a modern chat: a conversation rail on the left, bubbles for each road on the right, a rounded composer with an emoji picker, and a live SMS counter. The counter knows the difference between GSM-7 and Unicode: an emoji, an accent or a CJK character switches the body to the 70-unit Unicode alphabet, which the phone splits correctly through SmsManager.divideMessage. Incoming emoji are stored and shown as themselves.',
			'The lists live in a drawer. The menu at the top left opens and closes them - on a phone the drawer starts closed so the thread has the room, and picking a conversation puts it away again. Inside, subheadings group the lists: People, Sections, then the open section\'s own list. Press a subheading to fold that list away, and it stays folded. The rail remembers the place you left it, and keeps a separate place for each section, so coming back to Sms returns to the row you were reading rather than the top. In the phone-number list, Known and Unknown are subheadings of their own: Known holds the numbers the house has named, Unknown the bare numbers it has not, and either can be folded away.',
			'The transport is remembered per person. Pick sms for someone once and their thread opens on sms from then on, with their phone number under their name in place of the section name, until another road is picked. The thread itself stays theirs - a pass-holder keeps their pass thread while the next message goes by phone. Opening a thread lands on its newest message; a page of mail is decrypted before it is drawn, so the conversation is whole when the window appears rather than filling in bubble by bubble, and the thread follows its newest message while the composer grows and while the phone\'s keyboard changes the window\'s height. A deliberate scroll up stops it following until you return to the bottom.',
			'The JawnOS keyboard is the default on a phone: tapping into any text field raises a docked keyboard - it slides up from the foot of the screen and slides away again when it closes - and keeps the system keyboard away, so the page never reshapes itself around a field. While it is up it owns the foot of the screen: the keys sit at the very bottom, and the floating dock (or the taskbar, when the search rides there) rises above them while you type into its search, so the bar is never covered and never covers the space bar. It has three pages - letters, a calculator and a page of special characters (currency, maths, punctuation, arrows, fractions and symbols). A number field opens on the calculator; any other field has a 123 button to switch to it and an abc button to come back. The calculator has a display, digits, + - x /, parentheses, percent, sign, clear, backspace and =; the answer goes into a number field or, in a text field, at the caret. A quantity that names a unit - $32.31, 5jpy, 32.33L - brings up a row of conversions to the other units of that kind: currencies use the live rate snapshot, and distance, volume, mass, weight, temperature and speed use the Measures units, with each formula read both ways so a litre reaches a teaspoon. Tap a conversion to use its answer. The calculator first offers the kinds of measure - Currency, Weight, Volume, Distance, Temperature, Speed and the rest - and shows the conversions for the chosen kind below; the units used most come first, and a bare number converts from the unit remembered for that kind. The last unit used is remembered, so a bare number keeps converting without typing usd again. Each answer is also kept in a row of sums above the keys, newest first and remembered across sessions: press one to use its answer again, or the x to clear them. Backspace and C edit the number field as well as the display while the calculator is typing into it. The keyboard also reads the field it is in: a time field (ago, timestamp) offers now, 5m, 1h, 4h, 1d, yesterday, today, tomorrow and in 1h, and the row follows a number already typed (5 becomes 5s, 5m, 5h, 5d, 5w, 5M, 5y before the fixed chips); a duration offers the usual spans the same way; a warranty offers -1d through -10y; a schedule offers once and the repeat intervals; and a notes box keeps the plain keys. In those fields a typed 5m means five minutes, so the unit conversions stay out of the way. A sideways swipe along a row of chips pans it; a chip only answers a tap. Dragging a finger sideways across a field selects the text from where it landed and highlights as it moves, without raising the keys; dragging up or down scrolls the page past the field, and only a tap into it places the caret and opens the keyboard. Holding backspace, after a short wait, repeats characters and gets faster the longer it is held; a double tap takes a whole word at once, and holding after it keeps taking words. The keys answer on the press rather than waiting for the server. A character key that is held also shows a large copy of itself above the finger, so the key stays readable while it is covered. A desk keeps its own keyboard: the dock stays closed there even if it was left on last time, and the first real key press puts it away when it is open; the Chat composer\'s keyboard button or the dock\'s keyboard icon turns it on for that visit. A desk still gets the conversions - a quantity that names a unit brings the same row in a small panel just above the field being typed in, and tapping one replaces the typed quantity, unit and all, with the answer, while a bare number is left alone.',
			'The bar above the keys carries the layout chooser and the microphone, beside the hide key. The globe offers the keyboard you already know - Samsung (One UI), iOS, Gboard and US QWERTY - and layouts for French, German, Spanish, Italian, Portuguese, Turkish, Russian, Arabic, Hindi and Bengali; the chosen one is remembered on the device. Each keeps the key shape its people expect, and a language\'s accented letters (or the characters another script needs) ride their own row above the letters, scrolled sideways when there are more than a screenful. The layout\'s language is also the one dictation listens for. The microphone speaks into the field you are typing in: press it to listen and press it again to stop, and the key turns red while it is on. The house does the listening itself: a phrase is recorded, ended by a pause, and sent to the transcription role chosen under Configure -> Plat (whisper.cpp on this machine or the chosen cloud Whisper); the pause is measured against the room\'s own noise, learned while it listens, so a laptop fan or a steady hiss still lets a phrase end; the Guide\'s model then restores punctuation and capital letters without changing a word. The next phrase begins listening at once, while the last is transcribed, so talking continues without pressing anything; the transcript joins the field where the microphone was opened. Nothing goes to a phone or browser speech service. The dock\'s keyboard and calculator icons open this same dock, the calculator straight to its page.',
			'The bar also carries the vault. A key appears when a saved entry matches the field in hand; press it to fill that field, or to choose among several. A lock (a password field) or a disk (any other field) saves what is there: a browser password asks for its site, because the keyboard cannot read the address bar. The entries live in the house\'s credentials table, sealed with the house key, and ride the ordinary sync between the machines of the house; while the house is padlocked nothing can be saved or filled. On Android, choose JawnOS Autofill in the dashboard\'s Keyboard card to fill a whole login form at once - the input method alone can only reach the field that has focus.',
			
			'LoRa mode is its own section and its own road. Configure the network in the LoRa panel: band, sub-band, Join EUI, Dev EUI, App key, port and whether uplinks are confirmed. Save and configure pushes the credentials to the T-Deck on the LAN; Join network asks its SX1262 to join; Send test sends one uplink. A message written in the LoRa section travels through the LoRaWAN node and is filed on the LoRa thread, and a network server forwards downlinks to the webhook URL shown in the panel. LoRaWAN and the old raw-LoRa mesh are alternatives: while LoRaWAN is on, the deck\'s point-to-point broadcast and receive stand down.',
			'An appointment\'s Connect group carries a Chat button: it opens that person\'s one conversation right in the window - the pass thread when they hold a ticket, the phone otherwise - and the window keeps their name and colour on the way. A back button beside the menu puts the appointment back, and closing the window closes the chat.'
		],
		steps => [
			'Open Chat from the start menu.',
			'Press the menu at the top left to show or hide the lists. Press a subheading to fold that list; the Known and Unknown subheadings put that kind of phone number away.',
			'Pick a section from the sidebar - sms, dial, list, passes or lora.',
			'Friends: tap a person to open their one conversation, and the transport dropdown picks how the next message travels (a person with several lines gets one sms option each).',
			'Sms: tap a number, then write in the box below the conversation. The emoji button opens the picker, and the counter above the box names the alphabet and the segments.',
			'LoRa: open the LoRa section, fill in the network credentials, press Save and configure, then Join network. Write in the composer as usual; the transport pill is already on LoRaWAN.',
			'Dial: pick a set, then press Advertise to open it to guests.',
			'Rooms: set the junderground web address and this house\'s handle in the panel, then press Register this house once; approval is the switch administrator\'s. Choose any of the social constructs and press Dial to see the rooms whose scope they reach, open one to read its door, rentals and roster, and press Join — with a ticket or pass code if the room asks for one. A construct written in any language reaches the same room: the switch keeps a language-neutral identity and answers with the administrator\'s word for it, shown beside Dial, so 圣诞节, navidad and weihnachten all ring the same Christmas room; a word the switch does not know yet is translated by this house\'s Guide before the dial, so two houses naming the same new place in different languages still meet. A successful Join also opens the room\'s signaling channel to the switch and an audio call with the other houses there (a mesh; the microphone is used only while you are joined, and Mute sits under the roster); the status line then sits on Live and says how many houses are joined. Each other house gets a card: Video asks them for a picture and their feed reaches you only after you press it; what you send is chosen under Sharing (camera, Screen on a desktop, the Studio, the Music player\'s #video picture, or the Marker board) and is only captured while someone is watching; Translate turns their speech into captions in your language; Add friend makes them one of your appointments and puts their crest in People. The house that rented the room (the citizen) also gets Broadcast: tick any sources - camera, Screen, the Studio master, each live Studio channel, #video, the Marker board - and send them all at once, as many as the uplink holds; each listener\'s card lists the streams by name. While you are in the room with them an appointment runs with Chat as its source, so the duration is kept. The grade is this house\'s own reading of the people in the room: Friends, Enemies, and everyone else a Stranger. A person\'s relationship set in People is read here too, and an Enemy among them starts a lockdown.',
			'List: add and configure the sets the dial picks from.',
			'From an appointment, press Connect then Chat to open that person\'s conversation in the window.',
			'Keyboard: press the globe in the keyboard\'s bar to choose a layout, and the microphone beside it to dictate into the field. A pause ends the phrase, the house transcribes it and the Guide punctuates it, and the microphone keeps listening for the next one.',
		],
		related => [ 'mailbox', 'phone', 'email' ]
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
		verified => '2026-10-21',
		summary => 'The whole mailbox in one window — email, sms, lora, the dial, the list, pass threads and the pen.',
		body => [
			'Mailbox speaks IMAP and SMTP directly. Mail arrives on the desktop rather than in a separate client: a new message raises the mailbox dot in the start menu and, if no mailbox is watching, a notification.',
			'Sent mail is filed back onto the recipient\'s app, and its attachments are filed and sealed, so a document you emailed is still findable from the thing it belongs to. Alongside email it carries SMS, the internal message and paper-route system, and the Pen assistant — each of those sections also opens as an app of its own now, while the umbrella still carries them all.',
			'The dial is the house\'s radio: a set of appointments picked across the social construct groups names one thread, and a tab only hears messages addressed to the set it is tuned to. Advertise opens the tuned set to guests, who may then tune the same channel from the mailbox on the public page.',
			'A paperclip beside the composer attaches files to the next message; they ride the message on the ticket road and go as an MMS on the phone road, as one picture message with its words in it.',
			'A letter is filed only when its sender is trusted: a citizen\'s or resident\'s words are stored and synced, while a guest\'s are heard live by whoever is tuned in and never written down — except on the guest\'s own pass thread, the one conversation the house opened for them. Room bubbles that are not kept are dashed to say so.'
		],
		steps => [
			'Open Mailbox and choose a section from the sidebar — sms, email, lora, list, dial, pen or passes.',
			'For email, pick a folder (contacts, inbox, drafts, outbox, sent) and an address.',
			'Compose with the new-file button; attachments are filed and sealed when you send.',
			'On the dial, pick a set and press Advertise to open it to guests; press Advertised to close it again.',
			'As a guest on the public page, open Mailbox, tune an advertised set from the Dial section, and write; the house\'s replies stay, and so does the pass thread — your words in the rooms are only heard.'
		],
		related => [ 'relational', 'store', 'sealing_files', 'assistant' ]
	},
	'process_monitor' => {
		title => 'Process Monitor', category => 'apps', app => 'process_monitor',
		templates => [ 'templates/monitor/monitor.html.ep', 'public/js/manager/monitor.js' ],
		verified => '2026-10-23',
		summary => 'Live CPU, memory and battery health, per-core graphs and a process list.',
		body => [
			'Process Monitor is the system\'s own dashboard: live CPU and memory readings, per-core graphs and a sortable process list. It is how you see what JawnOS — and everything else on the machine — is actually doing.',
			'The health strip along the top says how many processes jawn is running (including the master), the machine\'s load average and uptime, how many sync jobs are running and how many peers are linked, and the database and write-ahead-log sizes. On a machine with a battery it also shows charge, charging state, temperature, voltage, current and battery health. PPH is the battery\'s percent-per-hour draw, measured as a robust slope over the discharging samples in the last three hours, and only once the pack has moved at least two percent across twenty minutes; on a desktop, where every process is visible, it is scaled by jawn\'s share of the CPU so it reads as jawn\'s own rate, while a phone hides other apps and therefore shows the device rate. When the slope is too flat or too noisy to measure, the strip says so rather than inventing a number. Hover the strip for the measurement window and the last sync job\'s note.',
			'The main server adds a worker while every worker is inside a request and retires the extra one when they have been quiet for half a minute, so a burst of slow requests - a language model answer, a mail fetch - does not leave the rest of the interface queued behind them. That is why the process count can rise for a while and settle back on its own; the resting count is set by the `main_workers` value in config.json (0 keeps the automatic choice for the device).'
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
		'title' => 'Configure', category => 'apps', app => 'configure',
		templates => [ 'templates/configure/configure.html.ep', 'templates/configure/misc_setting_list.html.ep', 'templates/configure/device_lister.html.ep', 'templates/configure/plat_setting_list.html.ep', 'templates/configure/dns_clients.html.ep', 'public/js/manager/configure.js' ],
		verified => '2026-10-28',
		summary => 'Settings: the look, the devices, the utilities and the mesh.',
		body => [
			'Configure is where the desktop is made yours. Appearance (themes, colour schemes, font, texture, icon set, zoom, bar heights, the window border and the button border), the device lister, the utility controller and the remote-machine and mesh settings all live here. This copy is JawnOS {{live:version}}, running on {{live:machine}}.',
			'The panels are built from collapsible sections. Press a section\'s heading to fold it away and press it again to open it; the arrow beside the heading says which way it will go. Which sections are open is remembered on this screen, so reloading the window - or coming back to it later - returns to the same shape. A section with no remembered choice keeps the default it ships with, so a fresh screen is never empty and an old choice never hides a section you have not opened yet.',
			'The Dev panel lists the devices by the network they are on: a section per network, named by its subnet, with the machines and interfaces that reach it and a table of the devices found there. Scan sweeps the local network first, so a device nobody has talked to yet - a printer, a fresh appliance - still appears and can be given its purpose.',
			'The Dev panel carries the mesh switch too. Sync topology sets how this house talks to itself: Auto keeps the hub in charge while the server is live and falls back to a full mesh when it is not, Mesh makes every peer dial every other peer, and Hub only makes the spokes dial the server. The choice is a house setting - every machine picks it up on its next sync - and Auto still lets machines on the same network talk directly.',
			'Update Method, beside Sync topology, sets where a machine takes its own code from. None leaves the watcher off; Manual - GitHub and Manual - Peers also leave it off, and the Update now button beside the select applies a pull from that source when you press it. GitHub follows origin/main alone; Peers takes only a true fast-forward from another machine on the mesh; and Any, the default, tries GitHub first and falls back to a peer. It is a house setting as well, and the watcher reads it on its next pass, so a change takes effect within about a minute. Update now reports a dirty tree or local commits rather than discarding them; for either a dirty tree or local commits that block the pull it asks before discarding them, and a forced pull resets the checkout hard to the authority\'s head.',
			'A device that is off its network but bridged over Bluetooth is listed too, in a Bluetooth card below the machines: its name, purpose, radio address and when the bridge last heard it, so the fleet\'s radios are visible even when they are on no network of yours. The card\'s Scan now button asks the bridge to look for a JawnOS radio immediately; adoption otherwise happens on its own every 30 seconds. A machine with no screen of its own - a headless server - lists the devices it can see the same way, with no browser involved.',
			'A machine reached over a tunnel is enrolled on its own: the hub asks the peer its name and its backups, so the row shows the peer and its saved jawnos.enc (shown by its file name, not the whole path) and carries its buttons, with no Scan or Connect press. That is what lets a headless hub upgrade or relay to a tunnelled peer without a browser.',
			'A device names itself as it joins. A watch, deck or pico advertises what it is - its purpose, model and abilities (screen, keyboard, mic, gps, pins and the like) - over mDNS, and a printer is recognised the same way, so a new device appears in the list with its purpose and its abilities within seconds, without pressing Scan. A device with no network of its own - a fresh deck that has never joined one - is met over Bluetooth instead: the house scans for it and connects the moment it names itself, so it appears without an access point at all.',
			'A linked machine has a Migrate button: it asks that machine to pull the whole house from this one. Connect a device with no key first - the house key seeds its vault - then press Migrate and watch its line move from building to downloading to merging. The pull is resumable, so a dropped connection picks up where it stopped instead of starting the whole snapshot again.',
			'The same row carries Go: it opens that machine\'s own Manager in a window of its own. The window loads that machine at its own address rather than a copy served from here, so its tab and its stored settings stay its own.',
			'The row also carries Privilege: the relationship to this house and what it may do. No access revokes it; Guest may look and reply; Resident may start and stop appointments, toggle things, press Go and open a Manager, but cannot change configuration; Trusted adds remote control, relays and backups. The days box is the lease - blank means no expiry. A citizen machine shows Citizen instead of a choice, and only a citizen can set these.',
			'A printer in the list reads out its own ink and toner: a bar per cartridge (a tri-colour cartridge draws as one band), with the printer\'s state under it - idle, or what it is asking for, such as paper. The reading comes from the printer itself over IPP; click it to ask again after changing a cartridge.',
			'The Misc panel holds the routine settings, and its Speech section sets which voice the desktop speaks with — the neural Piper voices (LJSpeech, LibriTTS-R, Alba, John, Jonathan) or an eSpeak fallback, each chosen per device. Its Bars section sets the desk\'s edges and frames: which edge the dock and taskbar take, where the search lives, whether the dock keeps its icons, the clock\'s form, the taskbar, title-bar and clothesline heights, the Window Border that frames every window, and the Button Border worn by buttons, image buttons, icons and the clothesline — with Window Border Colour choosing the frame\'s colour and Button Border Colour choosing the edge on those same pressed surfaces and the clothesline pills. Language, at the top of Misc, sets the interface language for the whole house: English (the default), Mandarin, French, Spanish, German, Portuguese, Hindi, Arabic, Bengali, Russian, Japanese, Punjabi, Indonesian, Korean, Italian and Turkish. The choice is saved for the whole house, so every device follows it, and the page reloads in the new language; the setup wizard asks the same question at install. Corner Radius, in Appearance, sets how round the desk is: 0 is square and 28 is the softest. It rounds every window and its title bar, the inputs, dropdowns and textareas, the buttons, the checkboxes, and the desk\'s panels and cards; a theme carries its own corner: picking one from the gallery applies that theme\'s radius, and while a theme is in charge the slider is an override and Follow theme beside it returns to the theme\'s own value. Texture, in Appearance, dresses the clothesline, the coloured marks the canvas printers draw (the timeline bands and dots, the leaderboard rows, the clockface and calendar dots, and the narrator ticks), every button and hinted image across the program, the taskbar and the dock, and every other surface - the desktop, window frames and their app contents, window title bars, the start menu, configured panels, menus and dialogs, form fields, tables and cards - in plain, round, soft, sandglass, glass, paper, fabric, wood or metal: plain is the clothesline as it looked before the pills and materials (a solid rounded tile with its name printed plainly), round is a solid rounded pill, soft is a flat pane with a breath of light and a quiet shadow (the house default), and the rest are panes of glass, paper, fabric, wood or metal with the app\'s colour breathing through them. The material layers over the control\'s own colour, so an active green or a destroy red keeps its meaning underneath. A material also goes down when it is pressed - a button, a hinted picture or a clothesline pill takes an inset shade in place of its raised sheen, so a glass key reads pressed-in while it is held. Encryption Standard picks the cipher new notes and files are sealed with: the AES, Camellia, 3DES and SM4 families run in-process, the rest through openssl, and the list offers only the standards this machine can actually seal and open. Anything openssl knows can still be read, so a note or file reads back under whichever standard wrote it and changing this never strands what is already stored.',
						'Appearance also carries the screensaver. Screensaver style picks Cartoon world - a side-scrolling cartoon made from the house\'s own hand-drawn pictures, with logo2 or the doctor bouncing through four worlds a minute each (outdoors, a cave, underwater and a house), zooming in and out and every so often stepping into the logo\'s eyes for a first-person look around - or Drifting logo, the older drifting art. Screensaver in Manager sets how long a padlock inside Manager - the music, folders or gallery lock - waits before its screensaver starts. Type a number of minutes (3 is three minutes) or a length such as 30s or 3m; blank waits two minutes. A playing video keeps the screensaver away, and the lock screen itself still shows its screensaver after fifteen seconds.',
						'The Misc panel also carries the on-demand translator. Pick a target language and press Translate this window, or ask the Guide to translate a phrase or the visible window. The engine offers 107 languages and lists them in the same card; it uses the Guide\'s model, caches each string, and leaves the saved interface language alone.',
			'The App panel is one card per app. An app\'s abilities — measures, budgets, goals, notifications, packaging, a web table and the rest — sit as a grid of icon tiles under its name and colour; tap one to open its settings, and that tile opens out across the card. The icon set you pick under Misc gives every tile its look. Beside Colour, Dark Colour is the version of it worn while the desktop is dark — it starts as the same hue at a tone that reads on a dark panel, and can be picked separately. Theme picks a colour scheme for the app: while one of its start appointments is running the desktop wears it, the most recently started running app wins when several do, and Follow system returns the desktop to the Misc scheme. Visibility is a dropdown with three levels: Private, Public and Dangerous. A new app is Public. Public is shown as usual. Dangerous is shown as usual and also stays open during a lockdown. Private is a lock, not a place level: the app and its appointments are hidden everywhere, even at home, and never appear on the timeline. A private app can only be found in a private place with no Enemy present, and even there it needs a fingerprint on this screen (Security, Private apps) before it appears. In a public or dangerous place, or with an Enemy present, it cannot be found at all, not even in the start menu. Visibility is inherited through the social constructs: every construct an app or one of its records belongs to - team, project, club, community, institution, government, corporation, place, vendor, event, account and the rest - counts, and the lowest number wins. A dangerous place and an Enemy present are the same thing - a lockdown: other apps close at once, Security stays open, and an Enemy\'s running app waits for a fingerprint in Security before it can be seen and stopped.',
			'On an app card, Budget and Goals are lists of rows: an amount, a measure - occurrences (a count), money, quantity, duration or one of the app\'s own measures - a scope (none holds a fixed level, otherwise per hour, day, week, month or year) and whether it is a floor to reach or a ceiling to stay under. An amount carrying a time unit (11h, 90m, 2d) turns the measure to duration by itself, and a duration with no unit (90) is read as minutes.',
			'A person can keep more than one number or address: Phone and Email each hold the one line calls and mail route on, and the Phones and Emails tiles beside them list any others, each with a type — Mobile, Home, Work, or a Custom label. A call, a text or a letter from any of them still names the person, and contact sync fills the list rather than overwriting the line.',
			'Renaming an app into a name the house already knows opens the merge panel: for each setting the two records share, pick which value keeps the name, and a value nobody chose (marked <i>house default</i>) loses. Contacts either side holds are carried over unless you drop them, and window state — where the window was left, how big it was — is never asked about. Phone and email, like nfc and measures, keep both sides.',
			'Renaming into a known name also shows a compact history summary for both sides — sessions, date range, typical length, timing, data-quality flags and any expired warranty — and asks what to do with the appointments: keep both, remove exact duplicates, merge duplicates (with the proposed drops listed), flag the candidates, or keep only one side. The history choice is separate from the settings choice; a policy that drops rows takes a backup first and tombstones them under the new name, so every machine agrees.',
			'Notifications, on a card, sets what an app says and sounds like: a sound and a line of text for the default, for a start, for a stop and for a budget. The sounds are the ones in the house (Ring, Chime, Sonar, Pulse, Crystal, Ding, Rattle), and (default) leaves the choice to the house. Add your own sound takes an audio file from your device and files it with the rest, so it appears in every app\'s list from then on. An Alarm box at the top of the panel makes a future appointment of that app add itself to the Clock as an alarm, linked back to the appointment.'
		],
		steps => [
			'Open Configure.',
			'Use the tabs to move between appearance, devices, utilities and the mesh. The tabs and the version badge stay pinned across the top of the window in one row; the bar tucks itself away while you read downward and returns as soon as you scroll back up. Pressing the tab that is already open reloads that panel in place rather than hiding it, and a reload (a theme\'s icon set, say) reopens the same panel at the same scroll position.',
			'The Plat tab has four pages: AI, which holds every AI model choice and provider key; OAuth2, where an app registration (a client id, secret and tenant) is added once with Add client and shared by any number of mail accounts; Crypto, which holds the assets, the rate snapshot and how a holding is valued; and DNS, where the DNS provider\'s API token is saved so the house can prove it owns its domain and renew a wildcard certificate without opening a port. The same page names the house domain and the name each machine answers on, so a ticket or a sign-in can use the public name while the house keeps calling itself on 127.0.0.1. It also picks the outside service the remote_control panel asks for this machine\'s public address, or None to stop the lookup. The other tabs hold the rest of the house\'s settings.',
			'For speech, pick a Say voice under Misc and press Preview to hear it.',
			'Pick the interface language at the top of Misc; the page reloads in the language you chose, and every device in the house follows it.',
			'To give an app a ringtone, open its card on the App panel, tap Notifications, and pick a sound — or add your own sound from there.',
			'To see how much ink or toner a printer has left, look at its row in the Dev panel; click the reading to refresh it.',
			'To change how a machine updates itself, set Update Method under Dev: None, Manual - GitHub, Manual - Peers, GitHub, Peers or Any, then press Update now to apply a pull at once. If local commits block the pull, Update now offers to discard them and force the pull.',
			'To move the house onto a new device, Connect it with the house key, then press Migrate on its row and watch the migration line.',
			'To work in another machine\'s Manager, press Go on its row in the Dev panel; the window opens on that machine, with its own storage. In the installed desktop or Android app, Go first asks for a second factor: touch this computer\'s fingerprint reader, use the phone\'s own fingerprint, or ask another paired phone or tablet to approve it. Once that print is accepted, the Go pass is minted over the signed peer rail and the window opens already signed in - the pass carries the minting house\'s vouch, mints a person there, and passes the app gate as that peer, so a headless machine opens for a trusted house without needing a local app key or a person of its own. A house with no reader and no other paired device falls back to the app key alone. In a plain browser Go opens the peer\'s Gate instead, where a fingerprint or another of your devices confirms the login - that confirmation is what stops a link from signing a browser in behind your back. A pass minted at a box office has no such vouch and is still answered by the app gate when Enforce is on.',
			'To make another house a resident, open its row in the Dev panel, pick Resident under Privilege, and type a number of days (or leave it blank for no expiry); the change saves at once.',
			'To add another number or address to a person, open their card, tap Phones or Emails, pick a type and press Add Phone (or Add Email).',
			'Changes save as you make them; a bar or theme change is felt at once.'
		],
		related => [ 'themes', 'icon_sets', 'devices_and_mesh', 'platform', 'assistant' ]
	},
	'privacy' => {
		title => 'Privacy and your data', category => 'features',
		templates => [ 'templates/privacy.html.ep', 'templates/gdpr_consent.html.ep' ],
		verified => '2026-10-19',
		summary => 'What the house collects, why, and how to exercise a data right.',
		body => [
			'The public homepage and the store show a short notice the first time a browser visits: the site uses only essential cookies and local storage, with no advertising or third-party analytics. The notice points to the full privacy policy at /privacy.',
			'The policy names the controller and contact address, the data processed (account and contact details, the content you create, and the technical data that keeps you signed in), the purpose and legal basis, how long it is kept, who it is shared with, the cookies and local storage used, the security measures, and your rights of access, correction, deletion, restriction, objection and portability.',
			'A visitor asking for a ticket sees the same notice and must acknowledge it before the request is stored. The acknowledgement and its time are kept with the request, so the house can show that the notice was given.',
			'To exercise a right, write to the controller address on the policy or use the ticket form. The person can also ask for a copy of their data or for its deletion; backups rotate on the schedule set under Configure -> Misc.'
		],
		steps => [
			'Open /privacy from the homepage or the store footer.',
			'Read who is responsible and what is processed.',
			'Write to the contact address, or use the ticket form, to ask for access, correction or deletion.',
			'To change what the store collects, open the ticket request form and read the notice before acknowledging it.'
		],
		related => [ 'store', 'configure' ]
	},
	'translation' => {
		title => 'Translation', category => 'features',
		templates => [ 'templates/configure/misc_setting_list.html.ep', 'public/js/translate.js', 'public/js/manager/help.js' ],
		verified => '2026-10-19',
		summary => 'Translate text or the visible window on demand with the Guide\'s model.',
		body => [
			'JawnOS ships English plus fifteen interface languages (Mandarin, French, Spanish, German, Portuguese, Hindi, Arabic, Bengali, Russian, Japanese, Punjabi, Indonesian, Korean, Italian and Turkish). The Language selector at the top of Configure -> Misc changes the saved interface language, and the page reloads in it.',
			'For everything else, the translation engine translates on demand: a phrase, a block of text, or the visible labels, buttons and help text of the current window. The engine offers {{live:languages}} languages, from Afrikaans and Albanian to Welsh, Xhosa, Yiddish, Yoruba and Zulu; the full list is under Configure -> Misc -> Languages the Guide can translate, and the Guide can read it back with translate_languages.',
			'The model configured under Configure -> Plat for the Guide does the translating. DeepSeek, Gemini, Claude, GPT, Grok, Mistral and the local Ollama models are broadly multilingual; quality varies by language and model. The engine preserves placeholders, HTML, punctuation, file paths, code identifiers and product names.',
			'Ask the Guide to "translate this into French" or "translate this window into Japanese". In Configure -> Misc, choose a target language and press Translate this window. An on-demand translation changes the visible window and is cached on the device; it does not change the saved interface language. The server also caches every translated string, so repeating a window does not pay the model again.'
		],
		steps => [
			'To translate words, ask the Guide: "translate good morning into Swahili".',
			'To translate what is on screen, ask: "translate this window into French" - or open Configure -> Misc, pick a language and press Translate this window.',
			'To see the offered languages, open Configure -> Misc -> Languages the Guide can translate, or ask the Guide "what languages can you translate?".',
			'To change the permanent interface language, use the Language selector at the top of Misc; the page reloads in it.'
		],
		related => [ 'configure', 'privacy', 'assistant' ]
	},
	'security' => {
		'title' => 'Security', category => 'apps', app => 'security',
		templates => [ 'templates/security.html.ep', 'templates/padlock.html.ep', 'templates/padlock_key.html.ep', 'templates/layouts/padlock_key.html.ep', 'templates/locked.html.ep', 'templates/locked_screen.html.ep', 'templates/layouts/locked.html.ep', 'templates/app_required.html.ep', 'public/js/manager/security.js' ],
		verified => '2026-10-28',
		summary => 'Passwords, pseudonyms, screen lock, the gate and secrets.',
		body => [
			'Security gathers the safety tools: password and pseudonym generation, QR codes, encryption helpers, screen locking and a keyring-style secret store.',
			'The app itself opens locked, because it holds the ways the house can be opened. Browsing it takes one fingerprint confirmation on a paired phone or tablet (or the reader on this machine); rotating the key, replacing the recovery code, splitting or releasing shares, adding or removing a passkey, revoking a person or a device, and turning the gate off each ask again, and only a confirmation no older than two minutes counts. Turning the gate on does not ask, so a lost phone can still lock the house down rather than leave it open. A grant minted before that is refused and the action is asked for once more. The paper recovery code - or three paper shares - also opens the app, so a lost phone is not a lockout; typing the code counts as the person, because it is the same secret that already opens the house.',
			'Lockdown is the house\'s own reading of where it is and who is present: a dangerous place, or an Enemy with a running appointment, closes every app except Security and the ones marked Dangerous. The Enemy\'s app is hidden too. Open Security, confirm with your fingerprint, then press Open beside the hidden appointment in its Lockdown panel; that reveals the Enemy\'s running app for two minutes and opens it, and stopping the appointment ends the lockdown. Confirm with fingerprint reveals the app without opening it, if you would rather open it from elsewhere. A dangerous place with no Enemy has no hidden appointment to reveal: leave the place, or change it, and the lockdown ends. Other apps stay shut, and the grant lapses by itself, so a walk away from the phone does not leave the app open.',
			'Private apps are a separate lock, and the strongest one. A private app is hidden everywhere, even at home, and its appointments never appear on the timeline. It can only be found in a private place with no Enemy present, and even there it stays locked until a fingerprint confirms it on this screen: press Confirm with fingerprint under Private apps. In a public or dangerous place, or with an Enemy present, it cannot be found at all - not in the start menu, not in search, and no unlock brings it back. Hide private apps, closing the last private app window, or five minutes with no movement on the screen shuts the grant again at once. The same fingerprint also opens the app\'s own Gallery, Folders or Music padlock for its files.',
			'The Padlock view sets the screen lock. There is no dial and no camera key: the only ways in are a paired phone or tablet, the paper recovery code, and - on the phone itself - an enrolled fingerprint. The padlock on the taskbar locks this screen with one tap and the whole house with a double tap (it appears while the gate is on and General is one of its contexts). A screen that locks stays on its own lock screen; it does not pull other devices away from what they are doing. Press Unlock on the locked screen and the paired phone or laptop you confirm on signs that screen open and returns to what it was doing. The lock screens wear the hand-drawn denial picture; when a fingerprint button is pressed the hand-drawn padlock appears locked, opens after the print is accepted while the house verifies it, and snaps shut again if the reading fails. The Unlock button asks every paired phone and laptop for a fingerprint, and the fingerprint picture glows while a reader is ready. Press Unlock and confirm with your fingerprint when the phone supports it, and it signs a one-time challenge for that screen. In the Android app the fingerprint prompt is the phone\'s own; a browser uses WebAuthn when it can. The phone can also unlock the screen it is locked on: enroll its fingerprint under Security while the screen is open, then press Use this phone\'s fingerprint on the locked screen. If a fingerprint is already enrolled, confirm it before replacing it with a new one. The app keeps an EC key in Android Keystore that the OS will not use until the fingerprint passes, and the house verifies that key\'s signature, so this is a real factor and not a browser promise; it opens the screen the request names - the phone\'s own, or the screen someone pressed Unlock on - and the target is bound into the signature. A phone with no enrolled fingerprint can still be unlocked by another paired device or the paper code; enrollment is refused while the screen is locked, so set it up before locking. If the whole house is locked, press Unlock on the screen you are at and confirm on another device; unlocking that screen sets only its own timer and the other screens stay locked. If several screens are locked, the page lists them. On a machine with an enrolled fingerprint reader, the locked page offers Use this computer\'s fingerprint. A phone that has enrolled its fingerprint shows Use this phone\'s fingerprint on its own locked screen; if that page is a plain browser without the app\'s bridge, it asks the platform authenticator (WebAuthn) and then signs with the pairing key instead of doing nothing. A screen that is locked for itself ignores requests to unlock other screens, so it is never pulled into someone else\'s prompt. After fifteen seconds the lock shows a screensaver; moving the mouse or pressing a key brings the lock back. A phone that slept through the request finds it on its next connection and asks for the fingerprint then; it is never sent away from the page it was on. A phone that is talking to a different machine in the house still unlocks you: the signed open is relayed over the peer rail to the machine that holds the lock. The prompt shows Unlocking... and then Unlocked., and the device that confirmed stays where it was; the locked screen follows within a couple of seconds. The computer\'s own reader is read in the background, so the lock page and its sockets stay responsive while fprintd waits for a finger. The unlock page is still there for a device that opens it by hand, and it still returns to the manager when it is done.',
			'Gate decides what the lock does to the server. The gate starts on in Enforce once the house has a way back in - a paper recovery code or an already-paired phone - so a fresh house is never locked out before it has one. Shadow writes each request it would refuse to the log and still answers, so the list can be checked on a live machine; Enforce refuses every manager request behind the padlock except the ways in - the phone\'s signature, the unlock page, and the paper recovery code. Use Shadow to check the list on a live machine. Turn the gate on makes the lock exist; Turn the gate off removes it, and stays off across restarts. The gate only acts when General is one of the padlock\'s contexts; the others are per-app. Phone unlock page opens the unlock page on this machine.',
			'App access decides who may open the manager at all. Off admits any browser with a valid ticket or login. Shadow writes to the log every private request a browser would lose and still answers it. Enforce admits only the installed desktop and Android apps, which prove themselves with a key a browser cannot hold - the desktop app\'s own Ed25519 key, or the phone\'s Android Keystore fingerprint key - and the signed peer rail a linked machine uses. The homepage and the store stay public for everyone, including apps that are not part of the house. Turn on Shadow first, use the house for a day, then choose Enforce. A new desktop app asks for its key on the app-required page; approve the request under Devices on a phone that is already signed in. An Android app with no key yet offers Set up this device\'s unlock on the app-required page, and Pair this device when it is not paired yet. Pairing travels over the mesh, so an approval can take a couple of minutes to reach the new device; the gate page keeps checking and continues by itself. A device with no fingerprint reader can use its own PIN or pattern as the unlock. Tunnels between machines keep working: they ride the signed peer rail, not a browser, and a peer whose session cookie was lost is still admitted by its pinned key. A browser opened through a tunnel is not a peer key, so a raw browser is answered with the app-required page; the Dev panel\'s Go is different in the installed apps, because there the pass is minted by the trusted peer over that rail and carries the peer\'s vouch after the fingerprint or another device approves it, while Go in a plain browser meets the peer\'s Gate. jawnosctl is a supervisor, not an installed app: its status reads the public health route, and its open command starts the desktop app when one is installed.',
			'It also shows the neighbour links — which machines are trusted, and with what privilege.',
			'The Devices view lists the browsers and phones paired to the house. A citizen session pairs its device once; from then on the device logs itself back in with its own key, with no pass or password. Revoke a device here and its sessions die — it must be paired again. A new device can also ask to pair from the gate: its request waits at the top of this view with a short code, and Approve lets it in — but only when that code matches the one on the new device\'s screen.',
			'The Person column says whose device it is. Add a person with their name and privilege above the table, then pick them in a device\'s Person column; that person\'s privilege is what the device\'s next login wears. A device left unassigned is a guest, never a citizen: assign it before it can act as one. Devices paired before this rule were attached to the owner once. A device can be moved or left unassigned, but the device you are using cannot be demoted below citizen — the change would only take effect at its next login, and that login would be the lower one. Revoke a person from the people table to end them in one move: their devices are revoked, the house-key shares those devices hold are deleted, their invitations stop, and their sessions end at the next request. The owner and the person you are using cannot be revoked.',
			'The Kind column names each row: App for a device with a native app key, Phone for a biometric key, Browser for a browser pairing key, and Desktop window for the WebKit windows of the desktop app that have no app key. A browser pairing key alone is not an app session; under Enforce it can pair and log in but not open the manager.',
			'A password login is no longer a citizen session by itself. From another device it is a bootstrap session: it can pair a device, restore a backup or recover, but it cannot open the manager. It never resolves the house key either, so it cannot read a sealed note or file; only a session that has proved a device key does. The recovery code, or the app and its device key, is the way back in; the app gate still asks for the app key under Enforce. The password is not a recovery share: it opens the door and is never sealed to the house key, so a lost key file needs the recovery code or three shares, never one remembered secret.',
			'Passkeys are the browser\'s own way in. The Passkeys view makes one on this device: the keypair is created in the platform authenticator and never leaves it, and the house stores only the public half, so there is nothing here to steal and nothing to type into the wrong page. Each key is bound to the house domain from Configure -> Plat -> DNS, which means the same passkey signs in on every machine under that name - laptop, phone, tablet and the server alike - once the house has synced it. Add a passkey while signed in, give it a name, and approve the fingerprint or screen-lock prompt; the Gate then offers Sign in with a passkey. Press Open in browser to enroll from the installed app: it makes a five-minute, single-use link and opens a standalone page on the house name, because the app\'s own window is on 127.0.0.1, which no authenticator accepts as an origin. The page makes the key, names it, and spends the link. Only a security key is accepted: the enrollment page asks for a roaming authenticator, and a key that reports itself as this device\'s own reader or as a phone handed over the network is refused, because a synced passkey cannot be told apart from one of those and its custody runs through somebody else\'s account. A plain Chromium on Linux usually has no platform authenticator and no key of its own, so plug the key in before pressing Create the passkey here. The page\'s What this browser can offer section names what the browser actually has, and a refused prompt is reported by name rather than as a generic message. A passkey proves who you are, not what you may do: the privilege still comes from the person the passkey belongs to. It has to be created on a page under the house domain, so the enrollment page always opens on the public name (laptop.jonathanferwerda.com); Add a passkey appears in the panel only when that window is already on the house name; on 127.0.0.1 it is not offered at all, so use Open in browser there. Under App access Enforce a passkey session is let in, because the key is held by the device and bound to this house; a ticket or password session is still refused.',
			'The Recovery view holds the paper code that gets you back in when every pass is lost and no paired device is at hand: make one and write it down. It is shown once and keeps working through password changes — only rotating the house key replaces it; enter it under Recovery Code at the gate and that device is paired on the spot. The field also takes three paper shares pasted on separate lines. The view can split the house key into five paper shares: any three rebuild it and any two reveal nothing, so write each on its own sheet, keep them apart, and type three at the gate if the code is gone. Each share is shown as a PS1 paper code — uppercase, grouped, no case or +/= — and is also saved as a QR image under ~/.jawnos_paper_shares/ on this machine (the folder is private and is not synced); the QR carries the same paper code, and the gate accepts both the PS1 form and the older base64 shares. They stay good until the house key is rotated; making a new set does not cancel an older one. The house key itself works too: typed at the gate it opens the house in any vault state - a machine whose vault is gone heals it on the spot - so one long string written down is a complete backup.',
			'The Recovery view also carries the sharing tick: while it is on, a linked machine that has lost its key can fetch the house key from here - the request must carry the machine\'s pinned signature, and the key is sealed to a one-time secret for the trip.',
			'Device shares put a share on people\'s devices instead of paper. A device makes a share key the first time the Recovery view opens - an X25519 key kept only for this, not the login key - and Make device shares splits the house key again and seals one share to each chosen device, at most one per person so one person with several devices is not a threshold. Any share no device takes is printed once. A machine with no key opens Use Device Shares at the gate, which shows a short code; each holder opens Security, then Recovery, and presses Release a share while the asking machine is listed. The share is re-sealed to that machine\'s one-time key and never shown to this server, and that machine combines three releases into the house key and pairs itself. Two shares reveal nothing, rotation clears every device share, and revoking a device takes its share with it.',
			'Under Rotation, the house key can be replaced with a fresh random one: the database\'s sealed values are re-sealed in place, sessions start again (paired devices re-admit themselves), the recovery code is set aside - write down a new one - and the old key stays wrapped under the new one, so files and notes sealed before the rotation still open. The sealed files themselves then re-seal in the background through the queue, each one kept exactly until its new seal is written and checked, and every linked machine is handed the new key so it re-seals its own; one that was away catches up on its own.',
			'Under Old Seals, Upgrade Old Seals re-seals values left from long ago, when the outer layer was locked with a passphrase anybody could know: it runs here and asks every linked machine to do the same, and values already under the house key are left alone.'
		],
		related => [ 'box_office', 'devices_and_mesh', 'sealing_files' ]
	},
	'box_office' => {
		title => 'Box Office', category => 'apps', app => 'box_office',
		templates => [ 'templates/box_office.html.ep', 'templates/store/ticket_request.html.ep', 'public/js/manager/manager.js', 'public/js/homepage.js' ],
		verified => '2026-10-22',
		summary => 'Issue, suspend, renew and revoke passes.',
		body => [
			'The Box Office manages passes — the single-use links that log a visitor in. The Passes tab opens on an issue form: choose who the pass is for, the app it opens, its privilege, an optional project and the warranty, then press Issue pass. Nothing has to be dragged onto a window any more; the app is a field on the form.',
			'Network address is a fold-away panel under the form. It names the interface the pass link should point at and shows the exact address that will go into the link. The panel stays closed until you need it, so the common case is one short form.',
			'The list below shows each pass as a compact row: its QR, who and what app it is for, its status, privilege and project, when it was issued and when it expires. The access log is its own accordion in the row — open it to see the addresses that used the link and when — so a busy pass does not stretch the whole table.',
			'Copy puts the pass link on the clipboard; Link opens it. The select in a pass\'s row changes its privilege; the next time the link is opened the session wears the new chair. Suspend pauses a pass, Reinstate brings it back, Renew gives it the warranty currently typed in the issue form, and Delete asks for a second press before it removes the pass.',
			'The Requests view holds what the public page asked for: each request shows its name, contact, description and whether the house already knows the contact. A request may also carry a crest — a compact signed code pasted from the visitor\'s QR or NFC tag. The Crest column shows that house, its fingerprint and whether this house has met it (Met in person), has an introduction to it (Introduced by ...), has imported it without meeting (Imported, not met), or has only the verified record (Not known yet). The crest is identity, not a grant: it never approves a request by itself.',
			'Approve mints the pass (the waiting page lets itself in), Decline forgets it, Blacklist remembers the identifiers so the door refuses them before a request is ever queued.',
			'Issue guest passes on request keeps the door open: a request is minted a guest pass on the spot at the guest warranty. Leave it unticked and requests queue for approval instead.',
			'A blacklisted pass is the deny: its holder is shown the denial page and that browser is then locked out of the house — public pages included — with no redirect.',
			'The Passes tab also carries Blocked numbers: a number typed there — or added by the Phone app\'s Block button on a recent call — is turned away before it can ring, and the same list keeps that number (or a request from the same email) out at the door. Removing a number from the list lets it ring again.'
		],
		steps => [
			'Open the Box Office.',
			'On the Passes tab, choose who the pass is for and the app it opens.',
			'Choose its privilege — citizen, resident, guest or blacklisted — and the warranty.',
			'Press Issue pass, then Copy the link and give it to whoever needs it.',
			'Open Network address only when the pass must point at another interface or address.',
			'Open a pass row\'s Access log to see the addresses that used it.',
			'Suspend, reinstate, renew or delete a pass from the same list when it is no longer wanted.',
			'Open the Requests tab to approve, decline or blacklist what the public page asked for.',
			'Read the Crest column beside Known before deciding; it says who is asking, not what they may do.',
			'Block a nuisance number under Blocked numbers — or from the Phone app\'s Recents — and remove it there when it is welcome again.'
		],
		related => [ 'tickets', 'security', 'phone' ]
	},
	'handbook' => {
		title => 'Handbook', category => 'apps', app => 'handbook',
		templates => [ 'templates/handbook/handbook.html.ep', 'templates/handbook/today.html.ep' ],
		verified => '2026-10-21',
		summary => 'The day as a journal, and chaptered notes about the system itself.',
		body => [
			'Handbook opens on Today: the day read as a journal. It gathers what the house already knows - what money moved and what bills are due, the shape of the day, the latest measures and notes, the projects that have moved recently, and the people named in the day\'s plans - so the day can be read in one place.',
			'The day header is also a time machine: type a day (today, yesterday, jul 16, 2025-10-21) and press Enter, or use the arrows to step one day at a time. Today reads the same stores the rest of the program writes to, so nothing is copied or typed twice.',
			'The Journal box writes an entry for the day being read. Save entry keeps it as a note for that day. Plant with the Guide asks the configured Guide model to read the journal (the last 30 days and the entry you just typed) and to plant the ideas, plans and dreams that point forward: each becomes a quiet Journal appointment on the day it belongs to, marked planted, so it appears when you turn Today to that day. Nothing is invented - the Guide quotes the entry - and a planted entry can be opened, edited or deleted like any other appointment.',
			'Predicted by your records is the ghost appointments\' view of the day: the times an app\'s own history says it is likely to happen, drawn faded and without writing anything. They are the same predictions the desktop timeline, calendar and clockface draw, read here for the one day.',
			'Below Today, Handbook is still the reference shelf: chaptered pages about how JawnOS works, with diagrams. It is the longer-form cousin of this Help app.'
		],
		steps => [
			'Open Handbook; Today is the first entry and the default page.',
			'Type a day in the header and press Enter, or press the arrows to move a day at a time.',
			'Read Money for what went out, what came in and which bills are due.',
			'Read State of life for the day\'s timeline, predictions, measures and journal entries.',
			'Write in the Journal box and press Save entry to keep the day\'s note.',
			'Press Plant with the Guide to have the journal read and its forward-looking ideas, plans and dreams placed on their days.',
			'Read Projects and People for what moved recently and who is in the day\'s plans.'
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
	'welcome' => {
		title => 'Welcome to JawnOS', category => 'features',
		templates => [ 'templates/apps/help.html.ep', 'public/js/manager/help.js' ],
		controls => [ 'Take the tour' ],
		verified => '2026-10-26',
		summary => 'A short tour of the desktop: windows, the start menu and System page, the dock, Configure and this Guide.',
		body => [
			'JawnOS is a desktop made of apps. Everything you open is a window: drag it by its title bar, pull its edge to resize it, and use the buttons in the title bar to minimise, maximise or close it. The window you last touched comes to the front. Press the question mark in a window\'s title bar to ask this Guide about that window, or press F1 to read the help topic for whatever is in front.',
			'The start menu is the round button at the corner of the desk. It opens on the apps you used most recently, with a category rail for the whole catalogue and a search box. Its other pages show what is running, what is upcoming, what is expiring, and a System page (the water-drop tab) with this machine\'s battery, CPU load and memory, every other machine in the house and the parking lot of saved sessions. A new install opens the menu on that System page, so the first press shows whether the house is well.',
			'The dock is the bar along an edge of the desk. Its icons are its pseudonyms: each one has a name, an icon, a colour, a place and something it says, all edited under Configure → Pseud. Pin the apps you reach for most and the dock keeps them within a press.',
			'Configure is the wrench on the start menu. Under Misc → Appearance you can pick a whole theme (paint, icons, material, font and corner radius) or a colour scheme on its own; it also sets the font, the corner and how long a lock waits before its screensaver. Under App, each app has a card for its colour, budgets, goals and notifications. Under Dev are the machines of the house: Scan finds them, and each row carries its privilege, its lease, Migrate and Go. The Pseud tab holds the dock pseudonyms.',
			'The Guide is always one press away. Type in the box under this page and press Guide me: it can answer from these topics, search your records, play media, translate a page, and open or drive the apps. It asks before it writes while the Confirmation Requirement is on, and it stages each change so you can read it first. Press Converse to keep the microphone open, or the question mark in any window\'s title bar to ask about that window. Press Take the tour at the foot of this window to hear this walkthrough again.'
		],
		steps => [
			'Read this page, or press Take the tour at the foot of the window to have the Guide walk you through it.',
			'Press the round start button; on a new install the menu opens on the System page. Use its category rail or search box to find an app.',
			'Open an app and move its window by the title bar; press the question mark in its title bar to ask the Guide about it.',
			'Open Configure (the wrench) and look under Misc → Appearance for themes and colour schemes, Pseud for the dock icons, and Dev for the other machines.',
			'Type a question under this page and press Guide me; ask it to do something and it opens the app or stages the change.',
			'Come back to this topic any time from the Help rail, or press F1 while another window is in front.'
		],
		examples => [
			{ open => 'app', app => 'configure' },
			{ configure => 'pseud' }
		],
		related => [ 'windows', 'start_menu', 'dock', 'configure', 'themes', 'devices_and_mesh', 'help_app' ]
	},
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
		verified => '2026-10-23',
		body => [
			'Everything that opens opens in a window. Windows stack in the order you last touched them, drag by their title bar, resize by their edge, and minimise to a small bar. Pressing or scrolling in a window brings it to the front, so the window you are reading is the one you are working in.',
			'The title bar\'s buttons are help (?), minimise, restore, maximise and close, and each window\'s drop-down menu adds snapping to half the screen and a move mode for precise placement. The layout of what is open is remembered and restored next time.'
		],
		related => [ 'taskbar', 'start_menu', 'appointment_windows', 'help_app' ]
	},
	'appointment_windows' => {
		title => 'Appointment windows', category => 'features', verified => '2026-10-28',
		summary => 'The window that gathers everything about one record.',
		body => [
			'Opening an appointment — a task, an invoice, a scan, a note, a measurement — spawns a window built around that one record. It gathers what the record is (its details), what has happened to it, and the things that name it: files, mail, transactions, the apps it touches.',
			'An appointment window is a centre view: it is not one app but a hub, and it can pull in panels from several apps at once. That is why opening one can feel like the whole desktop leaning in — it is.',
			'Its header carries the record\'s controls; below it, the panels are drawn from the record\'s own data and the apps that reference it.',
			'The details list carries the record\'s models and options. Tapping an option\'s name selects or clears it - the quantity and unit sit beside it - so the words no longer launch anything. The small view button beside the name is what opens that option\'s own app.',
			'Each row in the details table shows when it began, its duration, its warranty and its own stamp. The duration of an open session ticks every second while the window is open, in the same two-unit shape the rest of the house uses (1h 5s, 59m 59s, 1d 1m); a closed row keeps the length it was given.',
			'Clicking a time in the row turns its reading: the short form (5d 10h), all hours (130h 10m), all minutes (7810m 22s), then the fixed stamp. Clicking a duration turns it through the same three relative readings - a duration has no fixed form. The short form is not fixed to one denomination: it turns over to days as soon as there is a whole day (1d 6h), then to months and years the same way (1M 15d, 1y 1M), so both denominations share the reading. A reading that would print exactly the same words as the one already showing is stepped past, so a click always changes something - two hours reads 2h in the short form and 2h again in whole hours, so it goes straight on to 120m. Each window remembers the reading it was left on, so a reload comes back the same way.',
			'Every other duration the house prints turns the same way - an inventory card or column, a budget reading, a handbook row, a pass in the box office - because they all carry the span itself, not just the words for it.',
			'The fields under the record controls take plain words. Ago reads the same language as the taskbar clock, so "five days ago", "yesterday around 6pm", "last christmas" and even a name or an event ("Abraham Lincoln\'s birthday") land on the moment they mean. Duration reads a length - "5m", "1 hour 30 minutes", "five minutes" - and Schedule reads a repeat, from a compact interval to "every third Saturday" or "the next 5 full moons". Warranty reads the same words as a moment ahead of the record, so "2 years" means two years from it, not two years before it. The line under each field says what the words will save to and updates as they are typed; a phrase the fast reader cannot read is handed to the Guide once typing pauses, and the line then shows the moment it found.'
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
			'While the on-screen keyboard is up, typing in the search box lifts the box itself to just above the keys - the bar it lives in keeps its own mode - and its result list opens in the space above the keys, never across them.',
			'Right-click (or long-press) the bar for its context menu: rearrange the slots in edit mode, move it, choose the clock\'s format and time zone, and add items.',
			'The clock shows the time the view is standing on, so when the time machine or a timeshift carries you off the present its plate lights up - a warm, breathing glow - and goes dark again when the face reads now.',
			'Click the clock to use it as a time machine: type a time - "-3h", "jul 16", "last dec 25", "dec 25 2025 at 7:04pm", even "oct 12 96" - and press Enter to carry the view there, or Escape to leave it. An empty entry is now. Named days come out right ("this christmas" is this year\'s, "next christmas" the next), as do ages ("when I\'m 60" is today, at sixty). A time of day that is a habit - "breakfast", "tea time", "coffee", "next coffee time", "bed time" - is read from when you usually do it, the times your own records cluster around (twice a day for coffee, say), and falls back to a plain hour when there is nothing to read. A phrase the app cannot read itself is handed to the guide, which reads your own records for it ("the last time I had a beer", "the next time I\'ll be free"), knows the birthdays you saved under Configure -> App -> Birthdays ("mom\'s birthday" is the next one to come, "when was mom\'s birthday" the last one that passed, "mom\'s 60th birthday" the year she turned sixty) and looks up the rest ("Abraham Lincoln\'s 35th birthday"), and gives the time as well as the day for a past or future event ("the moment JFK was shot", "when the first world war ended", "the American Revolution"), then travels where it says. When you ask for something to be started ("start lunch in 20 minutes") it makes the appointment - written at once, or staged for a yes when the Confirmation Requirement is ticked - so its alarm and any embedded relay fire. A length you name is kept too ("start office that lasts 5 minutes" writes a five-minute office visit), held the way the tree counts time - an accrual, stored as a negative offset, so a start and its stop add up. Any year works, backward as well as forward, B.C. being a negative year ("-0044-03-15").',
			'A ghost appointment is one your records expect but that is not scheduled - your usual breakfast, the next coffee - drawn semi-transparent ahead of now in the timeline and every other view. Turn them on or off under the walkman\'s Configure (the wrench beside the time machine), where the Clothesline tick also switches the rail itself on and off.',
			'Dialogs count as windows in the taskbar: the Alert, a folder question and a job\'s progress each get a tile there, so pressing the tile brings one back, raises it or minimises it. A dialog\'s title bar drags it, and its own X closes it - there is no separate Cancel button to hunt for.'
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
			'Its pages also cover what is running, what is upcoming and what is expiring, plus a System view of the house\'s levels: this machine\'s battery, every peer that answered the last pass, and the embedded boards any of them can see (over Wi-Fi, or the Bluetooth link a machine is already holding), each with charge, state, temperature, voltage and PPH, and an estimate of the time left on it (or the time to full while it is charging). The estimate is the pack\'s own gauge reading where it reports one, cross-checked against the measured drop: when the two disagree by more than half again, the percentage slope wins, since an Android charge counter is not in consistent units from one vendor to the next. Without a gauge it is a robust slope over up to three hours of discharging samples, shown as a range while the samples are noisy and as "more than" a floor when the pack is moving too slowly to measure. Every machine with a processor also reports its CPU load and the share of RAM in use, in green, amber or red as the load rises; on Android, where the kernel hides the whole-machine counters, the CPU figure is JawnOS\'s own share and says so. The view stays live while it is open, refreshing every few seconds; a pack that reports its own gauge (a phone\'s charge counter, a laptop\'s energy and power) gives the finish time the moment it is plugged in, without waiting for a measured rate. A search box can ride the menu, the taskbar or the dock. A new message raises a dot on the menu\'s mailbox icon.'
		],
		steps => [
			'Press the start button to open the menu.',
			'Use the category rail to narrow the catalogue, or the search box to find an app by name.',
			'The menu\'s other pages show running, upcoming, expiring and the house\'s system levels.',
			'Help sits at the foot of the menu if you want to read about an app before opening it.'
		],
		related => [ 'search', 'taskbar', 'hints', 'network' ]
	},
	'dock' => {
		title => 'The dock', category => 'features',
		verified => '2026-10-26',
		summary => 'A second bar for the keyboard panels and the apps you keep at hand.',
		templates => [ 'templates/pseudonyms.html.ep', 'templates/keyboard.html.ep', 'public/js/manager/keyboard.js' ],
		body => [
			'The dock is a second bar you can place on any edge. Its faces are the house\'s pseudonyms - Remote control, the walkman (delorean), Walkboy, the on-screen keyboard, the calculator, Notifications, Sessions and the Controller - and any apps you add yourself. It can also host the search box; a side dock tucks itself away and slides back when you call for it.',
			'A face opens its own panel: the keyboard and calculator faces open the JawnOS keyboard (the calculator straight to its page), and the others open their keyboard panel above the dock. Press the same face again to put its panel away.',
			'Right-click (or long-press) a face to remove it from the dock, and right-click the dock\'s empty background to see the faces you have removed and put one back. Right-click an app in the start menu, or a taskbar window button or app pin, to add that app to the dock or take it off again. An app added this way opens its window from the dock, and raises or minimises it like its taskbar tile.',
			'The dock\'s app faces and each face\'s on/off are kept by this browser, not by the house: another browser or machine sees the server\'s pseudonym list and starts with every face on. The pseudonym list itself - what exists, its icon and colour, and whether it is on the dock at all - is shared, and lives under Configure -> Pseud.',
			'An appointment type\'s glyph (an invoice, a quote, the encrypt stamp and the rest) is not a dock face. Those have no panel of their own; they stay in the pseudonym list so the ledger can draw them on an appointment, and they start off the dock.',
			'The dock keeps at least one face so it can always be called back: if every face is removed, Remote control returns.'
		],
		steps => [
			'Press a face to open its panel, and press it again to close it.',
			'Right-click a face to remove it from the dock.',
			'Right-click an app in the start menu or on the taskbar to add it to the dock.',
			'Right-click the dock background to put a removed face back.'
		],
		related => [ 'taskbar', 'search' ]
	},
	'clothesline' => {
		title => 'The clothesline', category => 'features',
		verified => '2026-10-22',
		summary => 'A rail that hangs the routines belonging to this hour.',
		body => [
			'The clothesline runs along the top of the desktop and hangs the routines and rituals that belong at the current hour, in the order they usually happen.',
			'It can hang the ones your history shows you actually do, automatically, and each hang is configured per app: a schedule, a budget, and the time slots it belongs to.',
			'The rail can be switched off altogether: the Show clothesline tick beside the time machine (the walkman\'s Configure) hides it and gives its band back to the view, and ticking it again hangs it at its configured height. Each app\'s own hang is still set from its Clothesline button in Configure -> App.',
			'Each routine hangs as a pill in the material picked under Misc → Texture — plain (the original solid tile with its name printed plainly), round (a solid rounded pill), soft, sandglass, glass, paper, fabric, wood or metal — sized to its own name, with the full name set in the Misc → Font face and printed in black or white (tinted with the app\'s colour) so it reads on the pane.',
			'A textured pill goes down when you press it: its lit top edge becomes an inset shade for a moment, so the tile reads pressed-in rather than sticking up. Plain, round and classic settle the same quiet pixel and inset shade as every button now, without the canvas material.'
		],
		related => [ 'appointments', 'tasks' ]
	},
	'search' => {
		title => 'Search', category => 'apps', app => 'search',
		templates => [ 'templates/apps/search.html.ep', 'public/js/manager/search.js' ],
		verified => '2026-10-27',
		summary => 'One window for the house, the web and the Guide, with a tab for each.',
		body => [
			'The search box in the start menu, the taskbar or the dock still filters apps as you type. The magnifier beside it opens Search, the app: it keeps your words and lets you choose what to search.',
			'Apps finds the house\'s own apps and the appointments you have made, showing each app\'s own icon beside its name; press a result to open it.',
			'Web asks the search engines that are switched on and shows the links each one finds under its name. Bing, Brave, DuckDuckGo and Wikipedia are on to begin with; the settings panel lists dozens more under General, Reference, Media, Shopping and News. A link opens in the JawnOS Browser; the Search window stays where it is.',
			'The gear on the tab row opens the engine settings. Type in Find an engine to narrow the list, tick an engine to switch it on or off, and press the × on a custom engine to remove it. The choice is kept for the whole house, so every machine searches with the same engines; with none ticked the Web tab says so and offers the panel.',
			'In the browser on a phone, + Search adds the site you are reading: the server reads the page\'s OpenSearch description, then a search parameter already in the address, and offers a plain /search?q= guess if neither is there. An engine that answers a server with a JavaScript shell still appears in the list, and its row opens that engine in the browser.',
			'AI asks the model chosen for the Guide under Configure → Plat. It answers in plain text in the same window; press Enter to ask, so typing a question does not spend a call on every letter.',
			'Only the tab you are on is searched, and the app remembers that tab the next time it opens. Type to search Apps and Web; Enter asks the AI.'
		],
		steps => [
			'Type in the dock\'s search box and press the magnifier, or open Search from the start menu.',
			'Choose Apps, Web or AI across the top and type your words.',
			'Press a result to open the app, or a web link to read it in the JawnOS Browser.',
			'Use the gear to choose which engines Web asks; in the phone\'s browser, + Search adds the site you are reading.'
		],
		related => [ 'start_menu', 'dock', 'internet', 'assistant' ]
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
		title => 'Themes and colour schemes', category => 'features',
		verified => '2026-10-23',
		summary => 'Named dressings: paint, icons, material, face and corner under one name.',
		body => [
			'JawnOS ships a set of named colour schemes — Blue, Graphite, Green, Indigo, Steel, Amber, Teal, Plum, Rose, Nord, Sage, Mocha, Geek, Phosphor and Cyberpunk — and each has a light and a dark cut, so the chrome can range from near-white to near-black. A colour scheme is only the paint. A theme is the whole dressing: the scheme, the icon set, the material, the font and the corner radius, saved under one name.',
			'Configure → Misc → Themes is a gallery. Each card shows its palette and names its scheme and material; one click applies the whole dressing to this device. System follows the Misc choices below and changes nothing on its own. The presets are Deepjawn, Jawnfish, Adwaita, Cuperjawno, Jawndows, Mint, Nord, Sage, Mocha, Neon, Mono, Rose, Geek, Phosphor and Cyberpunk.',
			'New theme opens the editor: give it a name, pick a colour scheme, an icon set, a material, a font and a corner radius, and save. A custom theme is a house-wide row, so it appears in the gallery on every machine; Edit and Delete sit on its own card. A theme may take the accent for its focus rings and active tiles from its scheme, or name one of its own.',
			'An app can also carry its own Theme: while one of that app\'s start appointments is running the desktop wears the whole bundle — paint, icons, material, face and corner — the most recently started running app wins when more than one has a theme, and with none running the Misc theme or scheme comes back.',
			'While a theme is active, the Icon Set and Texture pickers under Misc → Appearance show Follow theme. Choosing another set or material overrides just that piece for this machine and leaves the theme\'s paint, face and corner alone; Follow theme returns to the theme\'s own choice. The Corner Radius slider works the same way: with a theme in charge it overrides that theme\'s corner, and Follow theme beside it returns to the theme\'s own radius. Picking another theme from the gallery clears that override, so every theme shows its own radius again. The override belongs to this machine and is separate from the gallery\'s theme definition, so a preset is never edited by it.',
			'The dark cuts change the window surfaces most, because the chrome is derived from the manager surface; inputs and dropdowns follow the same surface, so their text stays readable. Each scheme also gives windows and appointments their own surface, one step along the same ramp, so an app does not dissolve into the desktop behind it. A dark scheme also darkens the other surfaces by itself — the dock and its buttons, Configure, the start menu, the keyboard and its panels, the store and the taskbar — so a light face picked earlier does not glare through.'
		],
		related => [ 'icon_sets', 'zoom', 'configure' ]
	},
	'icon_sets' => {
		title => 'Icon sets', category => 'features',
		summary => 'A choice of looks for every icon; a theme may carry its own.',
		body => [
			'Every icon can be swapped between a set of looks — from the original hand-drawn artwork through cleaner, flatter and frankly sillier sets. New installs start on the clean GNOME-like set; a theme can name its own set, and the Misc choice is what a desk with no theme in force wears.',
			'Pick one under Configure; the whole interface follows, including the window controls, the phone app\'s handset and camera buttons and the dock\'s own buttons. The Folders listing and the desk take the set too: a folder, a plain file, an audio track, subtitles and a sealed file each wear the set\'s own picture.',
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
		controls => [ 'Crew', 'This machine', 'Peers', 'Advertise now', 'Processor cores', 'One-minute load average', 'Free and total memory', 'Job kinds this machine can run', 'Peer machine', 'Peer load', 'Run this job', 'How often', 'Good', 'Bad', 'Batch groups', 'Batch pools', 'New pool name', 'Add a pool', 'Pool name', 'Pace for this pool', 'Remove this pool', 'Drop jobs here', 'Not in a pool', 'Keep the scheduled wake', 'Discharging samples', 'percent per hour while discharging' ],
		verified => '2026-10-25',
		summary => 'The background jobs every machine runs, how often, and the house AI view above them.',
		body => [
			'Configure → Sys holds the Utility controller. Your own jobs are at the top: the Batch pools grid, and a Not in a pool bin for everything outside them. Every job is a tile carrying its switch, its name, the time it last ran and a good/bad dot; a job outside every pool also carries its own interval box, and the bin lists the switched-on jobs before the switched-off ones. A peer machine follows as a card named by its hostname, with its jobs and pools beneath it.',
			'The dot is good (green) while the job has last run within five of its intervals, and bad (red) once it has not. A job that throws or runs past its timeout is stopped and logged rather than retried, and simply waits for its next turn.',
			'Under each job a line says what its last run did - a count when it worked on something new, or that it found nothing - so a job that ran and found nothing does not read as one that never ran.',
			'At the top of the panel, Batch pools groups jobs so they wake together. Drop a job into a pool and it runs on that pool\'s pace; the whole pool wakes at the same moment and the device gets one long nap instead of several short ones. A job outside every pool shows in the regular bin and keeps its own interval box. The default pools are Navigation (four minutes, the GPS beat), Fast (fifteen minutes - presence, health, mail and the tunnels), Slow (one hour - the code sync, release and balances) and Daily (backups, housekeeping and expiry), and they can be renamed, retimed, added to or removed. Removing a pool returns its jobs to the regular bin; nothing stops running. On a phone, drag a chip with a finger; a plain tap still works the switch inside it.',
			'Above the jobs, Wake schedule is the Android app\'s short scheduled wake. While it is on and the app is arming it, the phone sleeps between beats and the app holds the CPU only for the work a beat needs: once the utility runner reports that nothing is due, it releases the CPU early instead of holding it for the full window. A peer pulling rows keeps the CPU up until that pull finishes, with a five-minute cap, so a batch is never cut in half by the window. Turn it off to go back to the old permanently held wake lock. Music still holds its own lock while a track plays, and the schedule never releases that.',
			'Below the wake switch, PPH comparator groups the battery history by which lock was in force when each sample was taken - Scheduled wake or Permanent lock - and works out the drain in percent per hour for each. It needs a few hours of discharging samples in each state before it prints a number; until then it reads not enough samples. Points is the number of readings used, Hours the span they cover. The readings come from the history the manager already keeps, so looking at the table does not itself keep the phone awake.',
			'The jobs include backups, email send and receive, the tunnels, the remote-machine sync, the remote relay (which hands a change queued with no browser behind it on to the other machines), the code sync (git fetch from the authority or a peer, every thirty minutes by default), navigation, the alarm haircut, the budget pass, tasks, warehouse expiry, the battery sample (htop) and a manager tick. A few only do anything on a handheld — SMS, the telephone check and navigation.',
			'It is per machine: an interval or a switch set here applies to the machine whose card it is on, so one job can run every two minutes on the phone and hourly on the server.',
			'The Sys panel also shows the house at a glance, above the Utility controller: one row per machine, whether it has a model, when it was last seen, and what it has spent today, with the house total against the shared Tokens/day ceiling. Because each AI job runs once for the house and a machine that goes quiet hands its job on, the roster is the live machines only.',
			'Below it is the API balances table, and it lists only the providers with an account on file — a key or account entered under Configure → Plat, under Provider access. For each of those it says what is left, where the provider reports it: OpenRouter and DeepSeek do; the rest — Ollama, Cloudflare, OpenAI, Anthropic, Google, xAI, Mistral and Groq — have no balance endpoint and read “no balance API”. A provider with no account entered is not listed. The read happens in the background every ten minutes, so the page never waits.'
		],
		steps => [
			'Open Configure and press Sys; the Utility controller is in that panel.',
			'Your own jobs are the pool tiles and the Not in a pool bin; a peer\'s jobs are under its card, named by hostname.',
			'For a whole pool, set its pace once in the Batch pools card; every job dropped into it takes that interval.',
			'Drag a job chip into a pool, or back to Not in a pool, to change where it runs. Use New pool name and Add a pool for another pool, and the × on a pool to remove it.',
			'Tick the switch to run a job, and set its interval in the box beside it (for example 2m).',
			'Watch the last-run time and the good/bad dot to see whether it is keeping up.',
			'In the Sys panel, read the house table and the API balances to see the AI work and what is left on each registered account.'
		],
		prompt => 'Explain the Utility controller in Configure → Sys: one card per machine, each background job with a run switch, an interval box, a last-run time and a good/bad dot. Good means it has run within five intervals; bad means it has not. A failing job waits its interval instead of retrying. Everything is per machine, so an interval on one machine does not move another. The Batch pools card at the top holds pools of jobs - Navigation (four minutes), Fast (fifteen), Slow (one hour), Daily - and a job dropped into a pool runs on the pool\'s pace instead of its own interval, so the pool wakes together. A job outside every pool keeps its own interval. Pools can be added, renamed, retimed and removed; removing one returns its jobs to the regular bin. The Crew section at the top of the panel is not a job list: it is what this machine can do and what the peers have advertised, and it is what decides where a job runs. Above that, Wake schedule releases the phone\'s CPU as soon as a scheduled wake has finished its work, and the PPH comparator compares battery drain between the scheduled wake and the old permanent lock. The Sys panel also shows the house AI ledger - each machine, whether it has a model, when it was last seen, its tokens today, and the house total against the shared Tokens/day ceiling - and the API balances table, which lists only the providers with an account registered under Configure → Plat; only OpenRouter and DeepSeek report a balance and the rest read no balance API. Do not invent job names beyond the ones listed.',
		related => [ 'crew', 'configure', 'backup', 'devices_and_mesh', 'process_monitor' ]
	},
	'crew' => {
		title => 'Crew', category => 'features',
		templates => [ 'crew.pl', 'templates/configure/utility_controller.html.ep', 'templates/configure/plat_setting_list.html.ep' ],
		controls => [ 'This machine', 'Peers', 'Advertise now', 'Processor cores', 'One-minute load average', 'Free and total memory', 'Job kinds this machine can run', 'Peer machine', 'Peer load' ],
		verified => '2026-10-25',
		summary => 'What each machine in the house can do, and where a job is sent to run.',
		body => [
			'The Crew is the house\'s account of its own machines. Each one advertises what it can do - processor cores, one-minute load, memory, free disk, operating system and architecture, battery state when the hardware reports one, the AI models its local Ollama lists, and the tools it has such as a browser, ffmpeg, tesseract and whisper - and the house keeps the most recent advert from every reachable peer. Configure → Sys → Crew shows this machine\'s own facts first, then one line per peer with its load, its model count and the job kinds it can take. Advertise now asks this machine to re-read its facts and pulls every reachable peer\'s advert in at once, instead of waiting for the five-minute pass.',
			'An advert goes stale after fifteen minutes, so a peer that has gone quiet stops being offered. Nothing is invented: a machine that cannot read its battery says nothing about a battery, and a peer that never answered is simply absent rather than shown as idle.',
			'The Crew is also what the assistants consult before they call a model. A role names a primary model and a fallback in Configure → Plat, but naming one is not proof it can answer here. Before a call, the house checks that the model can really be reached: a peer\'s own model must appear in that peer\'s advert, a paid provider must have its key or account on file and its budget not stood down, and a local Ollama model must be in this machine\'s own list. If the named model fails that check the fallback is tried, then the free model, then a model of the same family on a peer that holds one. When nothing is viable the assistant says so rather than reporting an answer, so a device no longer claims it heard from a model it does not have. A call that answered is the only one recorded as the last model used.',
			'Work is described as a job kind, never as a command. The registry is fixed and small: a no-op and an echo that prove the rail, ai.evaluate for an assistant call, and whisper.transcribe for a recording. A peer route may only run a kind in that registry, the caller must be a machine on the roster and sign the request, and the payload is bounded before it is read. A finished job is remembered by its id for half an hour, so a retry is answered from the result instead of doing the work twice. This is deliberately narrower than a shell: nothing in a job names a path, a program or a line of code, and adding a kind means editing the registry.',
			'Placement prefers this machine when it can run the kind and is not already at its cores, then the able peer with the lowest load. A heavy kind - a model call, a transcription - is kept off a machine already busy at its core count, while a light one tolerates a busier box. A job is never sent back to the machine that dispatched it, so two peers cannot bounce it between them.',
			'Today the Crew carries the assistant calls and transcription. The same rail is meant for the housekeeping that should happen once rather than on every device - the task pass, the budget pass, a headless browser - and those are not moved onto it yet. The Crew section is honest about that: it lists the kinds this machine can actually run now.',
		],
		steps => [
			'Open Configure, press Sys, and open the Crew section at the top of the Utility controller.',
			'Read This machine for what this box contributes, then each peer\'s line for its load and models.',
			'Press Advertise now after connecting a machine or pulling a model, so the house sees it without waiting five minutes.',
			'If an assistant stops answering, read its model under Configure → Plat against the Crew list: a model no machine advertises is the usual reason.',
		],
		prompt => 'Explain the Crew: what each machine advertises (cores, load, memory, disk, OS and architecture, battery when reported, local Ollama models, tools), that a peer advert goes stale after fifteen minutes, and that the panel lives at Configure → Sys → Crew above the job tiles. The Crew is what chooses a model for an assistant role, so a role naming a model no machine holds is reported rather than called; the order is the role primary, its fallback, the free model, then the same family on a peer. Work is a small fixed registry of job kinds, not commands: noop, echo, ai.evaluate and whisper.transcribe today. A job is signed, bounded, and deduplicated by job id. Placement prefers this machine, then the least loaded able peer, never the dispatcher. Do not claim that tasks, budgets or a headless browser already run through the Crew; they are the next step.',
		related => [ 'utility_controller', 'platform', 'devices_and_mesh', 'help_app' ]
	},
	'navigation' => {
		title => 'Navigation (location logging)', category => 'features',
		templates => [ 'templates/appointment_details.html.ep', 'templates/appointment_wrapper.html.ep', 'templates/start_menu/start_menu.html.ep', 'public/js/manager/travel.js' ],
		verified => '2026-10-25',
		summary => 'JawnOS records where a device is on a schedule from its own GPS, screen on or off, and never from the network.',
		body => [
			'Navigation is the autonomous location log. On a handheld the Android app runs a GPS foreground service: it reads the GPS provider and nothing else, and writes each fix to a small file the manager reads. The navigation utility takes that fix once per navigation interval - four minutes by default, set in Configure → Sys, whether or not the app is open and whether or not the screen is on - and writes it down as the machine\'s current position. The service is a location foreground service, so Android wakes it when a fix arrives; the phone is not held awake between fixes. The app also arms a short scheduled wake each interval so the Perl tree can run its due utilities, then releases the CPU again.',
			'Only a real GPS answer is ever used. The network provider is not asked, and the browser\'s geolocation is no longer used at all: a WebView or browser answer carries no provider, so a Wi-Fi or cell-tower guess looks exactly like a fix. If there is no fresh GPS fix - indoors, in a pocket - no place is recorded, and an older place is not restamped as today\'s.',
			'An app can also carry its own pace. An app\'s navigation setting is none (never log), once (log only when you act on it), or an interval such as 1m. While an appointment of that app is running, a fix is filed against it at that interval, and the machine\'s own navigation pace follows the fastest running app: an app asking for a point a minute makes navigation run about a minute apart even when the Utility controller\'s navigation interval is longer. The navigation fast pace has a ten-second floor so a very short setting cannot hammer the GPS.',
			'The current place holds until the next navigation run, so a private place stays private between fixes instead of falling back to public. When no automatic fix is due, the old five-minute warranty on the machine\'s position is what used to expire first; a fix now stays current through the next run, with a couple of minutes of grace for a late or failed one.',
			'A handheld with a GPS also hands each fresh fix to the house\'s computers on the same local network, as the fix lands rather than on the next sync. A laptop with no GPS of its own records the same place at once and its site-type picture follows. The handover is a signed notice over the physical local network only - never the tunnel or the VPN - and the receiving machine writes the position down without starting or stopping an appointment, since the handheld\'s own navigation already logged the visit.',
			'A machine without a real GPS never publishes a place. A phone, tablet or computer that has only ever seen a network estimate is not a source another machine may borrow from, and a computer\'s borrowed place is never lent on to a third machine. A handheld whose own GPS has answered keeps its own fix: a peer\'s borrowed place cannot overwrite it, so the site-type picture follows the real fix and the navigation button only confirms it.',
			'To ask for a fix at once, press the navigation button at the foot of the Start menu, beside the Guide\'s associate button. On a handheld it asks the app\'s GPS service for a fresh sample and waits up to twenty seconds for it; a cached fix is only the fallback, and it keeps its own timestamp rather than being restamped as today\'s. Starting or stopping an appointment asks for the same fresh sample, so the point is where you are at the moment of the press, not the last four-minute beat. If the GPS is cold and the fresh sample misses, an appointment set to `once` still takes the next real fix it can get, so the start is not lost. On a computer with no GPS of its own it asks a phone or deck on the same local network for its current fix; if none answers there is no place to adopt. The answer is recorded here as this machine\'s place, without starting or stopping an appointment. The site-type picture beside the button follows the answer.',
			'Those filed fixes are the Distance list on the appointment: open its details and the Distance section lists each point with its distance from home, the kilometres since the last one, and the speed between them.',
			'Navigation also drives the home plate: walking outside a plate\'s radius stops the matching appointment at once. When you come back inside, a session stopped by navigation within the last fifteen minutes is reopened rather than started again, so a stray fix that briefly put you outside does not split the appointment in two. A departure more than three times the radius away (with a fix better than 200 m) is a certain leave: coming back starts a new session instead of reopening the old one, even inside the fifteen minutes. Only a real GPS fix can move a plate - a network estimate, or the home-plate fallback a desktop uses when no deck answers, is ignored. The fixes can come at the navigation interval or from real GPS samples, whichever arrives.',
			'A plate\'s duty is remembered per device and per plate, so a fix from one device does not confirm a crossing for another.',
		],
		steps => [
			'Give an app a navigation value in its settings: none never logs, once only logs when you act, and an interval (like 1m) logs while one of its appointments is running.',
			'Set the navigation utility on and to four minutes in Configure → Sys so the phone has a GPS fix to answer with, with or without an appointment running.',
			'Start an appointment of that app and carry the device; the backend files a fix each navigation interval, or at the app\'s faster interval while one of its appointments runs.',
			'Press the navigation button at the foot of the Start menu whenever you want a fix now.',
			'Open the appointment and read its Distance list for the points, the distance and the speed.',
			'Set a home plate and a duty on it to let crossing that radius start or stop the appointment by itself; a return within fifteen minutes reopens a navigation stop.',
		],
		prompt => 'Explain JawnOS navigation: the Android app runs a GPS-only foreground service that writes each fix to a file the manager reads; the navigation utility takes one fix per navigation interval (four minutes by default, set in Configure → Sys), screen on or off and whether or not an appointment is running, a short scheduled wake runs the utilities and the phone sleeps between fixes (music holds its own lock); an appointment start or stop, and the navigation button, ask for a fresh sample and wait up to twenty seconds, using a cached fix only as the fallback, and a `once` appointment with no point yet still takes the next real fix after a cold start; the per-app navigation setting is none / once / an interval; while an appointment with a shorter interval runs, navigation follows that faster pace (down to a ten-second floor); the current place holds until the next automatic fix so a private place does not fall back to public between runs; the network provider and the browser geolocation are never used, so indoors there may be no fix at all; and filed fixes appear in the appointment\'s Distance list (distance from home, kilometres since the last, speed). A home plate\'s duty stops the running appointment at once when a real GPS fix puts the device outside its radius; a return within fifteen minutes reopens that same session, while a departure more than three radii away (a fix better than 200 m) is a certain leave, so the return starts a new session even inside the window. Only a real GPS fix may move a plate: a network estimate and the desktop\'s home-plate fallback are ignored. Do not describe it as a live map, and never guess a person\'s actual location.',
		related => [ 'travel', 'appointments', 'devices_and_mesh' ]
	},

	# ----------------------------------------------------------- functions
	'appointments' => {
		title => 'Appointments', category => 'functions',
		summary => 'The one record everything else hangs from.',
		body => [
			'An appointment is the atom of JawnOS: a timestamped record with a type, a status, a duration and an app-specific body. Files, invoices, measurements, notes and mail are all appointments under the hood, which is why they can refer to one another.',
			'An appointment inherits visibility from the social constructs it belongs to. Its own app is one source, and every social construct named on the record is another - team, project, club, community, institution, government, corporation, place, vendor, event, account and the rest; each of those may itself belong to another construct. The lowest-numbered level wins, so a record filed under a private project is Private even when its app is Public. A Private appointment is hidden everywhere, never appears on the timeline, and can only be found in a private place with no Enemy present after a fingerprint on this screen.',
			'Opening one spawns a centre view that ties together everything that names it. Appointments can have alarms, recur, and be exported to a calendar. With Alarm on in an app\'s notification panel, that app\'s future appointments also add themselves to the Clock as alarms linked back to the appointment.',
		],
		related => [ 'appointment_windows', 'clothesline', 'tasks', 'reminders' ]
	},
	'reminders' => {
		title => 'Reminders and alarms', category => 'functions',
		summary => 'Let an appointment come back and find you.',
		body => [
			'An appointment can be given an alarm, a reminder and a recurrence, so it announces itself when its time comes and returns on schedule.',
			'A recurrence is written as an interval and, optionally, a horizon: 1d for -2w repeats every day for two weeks, 2w for -3M every other week for three months, and 1M for -1y once a month for a year. A bare interval repeats until the app\'s warranty setting. The appointment you are starting is the first occurrence; the rest are written from it, so the first is never booked twice. Months step through the calendar, so February is 28 or 29 days and a monthly recurrence on the 31st keeps to the month\'s last day.',
			'A schedule can also be written in words: "every third Saturday of the month", "every Tuesday for the next 6 weeks except on holidays", "the next five full moons", "my mom\'s next 5 birthdays", or "every anniversary of the birth of Abraham Lincoln until my mom is 80". The Guide reads the words and writes the matching appointments, including the appointment you are starting as the first one. "Except on holidays" skips the common US/Canada holidays. If it needs a detail - a birthday it does not have, or which Tuesday you meant - it opens a Guide associate to ask, and then finishes the schedule.'
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
			'Deleting that transaction unwinds the payment: the balance goes back up, and a document that had closed reopens.',
			'An unpaid invoice\'s public page also carries the online ways to settle it when Configure -> Plat -> Pay has a method ready: a hosted checkout for cards or PayPal, and the e-Transfer address with the invoice reference. The buttons are on the public page only; the printed sheet and the emailed attachment carry the QR that opens it.'
		],
		steps => [
			'Build the document in Store from items and options.',
			'Move a quote to an invoice when it is accepted.',
			'Send or print the invoice; its QR opens the public page, where a ready online method can be used.',
			'Record a payment against it, or let the provider\'s return or webhook record an online one; the balance falls.',
			'At zero it closes. Delete the payment\'s transaction and it reopens, balance restored.'
		],
		related => [ 'store', 'budget', 'moves_ledger', 'pay' ]
	},
	'moves_ledger' => {
		title => 'The moves ledger', category => 'functions',
		summary => 'Stock and money folded into one signed list.',
		body => [
			'The warehouse keeps a journal of every stock movement and its reason. The moves ledger takes that journal and the money beside it and folds them into one signed list, so goods in and out and money in and out read as a single story.'
		],
		related => [ 'warehouse', 'invoices_payments', 'budget' ]
	},
	'transactions' => {
		title => 'Recording a transaction', category => 'functions', verified => '2026-10-28',
		summary => 'Enter what you spent or received from the record\'s own window.',
		templates => [ 'templates/apps/app_details.html.ep', 'templates/apps/transaction/expense.html.ep', 'templates/apps/transaction/income.html.ep', 'templates/apps/transaction/transfer.html.ep', 'templates/apps/transaction/inventory.html.ep', 'templates/apps/transaction/models.html.ep', 'templates/apps/app_transaction.html.ep', 'public/js/manager/transaction.js' ],
		body => [
			'A transaction is the money side of a record. Open the app\'s window and press Transaction (the coin beside Measures and Tasks) to open the form; it opens with the type, project and account already chosen from the app\'s own settings.',
			'The form reads from the top down. Vendor names who was paid, or who paid you. Item says what it was for; several things can be separated with commas, or each one put on its own line with Add item. Total is the figure on the receipt or the invoice; the amount and tax are worked out from it at the house tax rate. Typing Amount instead works the other way and fills the total.',
			'Each line carries its own quantity and unit, and Add item starts another line. The totals under the lines add every line together, and that is the figure saved. More details holds the inventory side of a line: manufacturer, model, state, an extra charge such as a deposit or tip, and the switches for whether the amount is for the whole line and whether the price includes tax.',
			'When the account is a cash account, Cash given takes the notes handed over and Change shows what came back. That pair is kept with the transaction for counting a drawer; the ledger still records only the total that left the account. Remember vendor and Remember item create or reuse an app for that name so its history gathers in one place; leave them clear to record the words on this transaction only.',
			'Save writes the transaction. Repeat last fills the form from the last transaction in the same app, which is the quickest way to enter a regular purchase; Cancel empties the form after a confirming press.'
		],
		steps => [
			'Open the app\'s window and press Transaction.',
			'Check the type, project and paid-from account, then name the vendor.',
			'Enter the total from the receipt, or the amount and let the total follow.',
			'Put the items on the line; use Add item for more lines.',
			'For cash, enter what you handed over and check the change.',
			'Press Save.'
		],
		related => [ 'budget', 'warehouse', 'moves_ledger', 'market' ]
	},
	'evaluation' => {
		title => 'Evaluation', category => 'functions', verified => '2026-10-22',
		summary => 'A model-backed appraisal of an app\'s activity.',
		body => [
			'Evaluation is an appraisal of any app\'s activity, run on demand or on a cadence. It reads what the app is and what it has been doing, weighs day, week, month and year together, and leaves a report at the foot of the app with a headline and links to everything it names.',
			'The report sits at the bottom of the app. Open its headline and the controls are inside the same accordion: the button that runs one now, how often it runs on its own, the days it runs, and the machine preferred for the work. In the app\'s Configure panel the controls sit above the report instead, so they can be set while the app is being configured.',
			'The days list has an All box. All runs every night; clear it to pick particular days, or to leave the list empty and stop the scheduled runs without changing the cadence. A daily or weekly cadence that was left blank used to mean All, and the app now makes that choice explicit instead of showing an empty list.',
			'Where an app\'s records are measurements (a weather feed, a currency quote, a meter reading), the report speaks only about the measured values and how they moved, not about how many readings there were: a reading is a value, not an occurrence. Speed from the GPS track is read only for an app whose own construct is an action; a start or stop in any other app still takes a GPS fix, but its speed is not a movement and is left out.',
			'It runs through a local model, so the appraisal never leaves your machine unless you point it elsewhere. The house dispatches the work: the server is the dispatcher, and the mobile and computer machines are the workers. The server assigns each scheduled run to a ready worker a few minutes before it is due, and a worker runs only what is addressed to it, so a split house does not run the same report twice. A house with no server uses a quorum instead: a majority of the machines must be present, and a minority waits. A server gone for a week is treated as no server, so a dead dispatcher does not freeze the house.'
		],
		steps => [
			'Open the app you want appraised and scroll to the Evaluation at its foot.',
			'Open the report\'s headline to reach the controls, then run it now or set how often it runs on its own.',
			'Use the All box to run every night, or clear it and pick the days you want.',
			'Read the report where it sits; its links open everything it names.'
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
		verified => '2026-10-19',
		body => [
			'Configure → Plat gathers every AI choice in one place: which model each assistant uses, and the key or account each provider needs. On this machine {{live:models}} assistant roles have a model set, and the local Ollama is {{live:ollama}}.',
			'Providers include the local Ollama, Cloudflare Workers AI, OpenAI, Anthropic (Claude), Google (Gemini), xAI (Grok), DeepSeek, Mistral, Groq and OpenRouter. A model is addressed as provider:model — a bare name goes to Ollama, and @cf/… to Cloudflare.',
			'Other machines\' own Ollama models are offered too, each listed under the machine that runs it (Ollama · that machine). Their model lists are cached in the background, so Plat opens without waiting on the network; picking one runs the call on that machine.',
			'Google Veo is offered as a Video-generation model: it runs the job on Google\'s side and the tree polls it until the video is ready.',
			'Thinking is set per agent, beside its model, and shown for the language agents — the Help guide, Evaluation, Vision, the Pen and Coding — when the chosen model can reason; Image generation never carries one. A model that does not reason is not offered the choice (the families that do: the o-series, GPT-5, Claude 3.7/4, Gemini 2.5+, Grok 3/4, DeepSeek R1/v4/flash, Magistral, Qwen3 and the like). The level reaches each agent\'s own model calls, and a level a model does not understand is dropped and the call retried without it.',
			'Image, Audio and Video generation are their own agents, each holding the model that produces that kind of file; a prompt Pen (or a Guide associate) describes is filed by the matching one, with a “Generating … with …” note while it runs. Transcription (speech in) is its own agent too: it can be set to whisper.cpp on this machine — the model is kept warm by a local whisper server, so a clip is transcribed without a network round trip — or to a cloud model, which is what a machine without whisper.cpp uses.',
			'Every agent also carries a Fallback choice beside its model — the same list minus the primary. When the primary errors (an outage), the call steps down to the fallback instead of failing; the transcription agent adds whisper.cpp after that, and when whisper.cpp is the primary the cloud model is its fallback.',
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
		title => 'Passes and logging in', category => 'functions',
		summary => 'A single-use link that is the credential.',
		body => [
			'A pass is a single-use link that carries its own secret. Opening it mints a session and lands you on the desktop (or the store, or the homepage, depending on the pass\'s privilege).',
			'Because the link is the credential, treat it like a password and revoke it from the Box Office when you are done. It is also how the desktop and Android apps log themselves in.'
		],
		related => [ 'box_office', 'security' ]
	},
	'devices_and_mesh' => {
		title => 'Machines, the mesh and sync', category => 'functions',
		summary => 'Several machines that keep each other in step.',
		body => [
			'JawnOS is built to run on more than one machine — a laptop, a phone, a tablet, a server — and to keep them in step without a central authority. Code, app builds and data all move the same way: whoever has the newest is the authority.',
			'Machines reach each other across whatever network they are on, including from behind a router, and every machine can be logged into from another via a pass.',
			'Two machines on the same network find each other without waiting for the tunnel. Every machine broadcasts a small signed presence notice on its LAN every few seconds and, when it joins a network, sweeps the subnet by unicast too (some phones drop broadcast); a machine that hears a known peer updates that peer\'s row with the LAN address it is on now, replies once by unicast, and starts the sync at once, so a laptop and phone that meet on the house wifi, a friend\'s wifi or a hotspot resume the mesh within seconds. The notice is signed with the machine\'s peer key and only refreshes a peer already in the mesh, so it cannot introduce a stranger. The phone and tablet use this path because Termux has no mDNS responder; the avahi advertisement still serves the embedded devices. The Dev panel follows the same notices: this machine\'s network card, a peer\'s LAN address and the build shown beside its name refresh in place, without pressing Scan.',
			'A machine that moves — a phone waking on a different wifi, a laptop joining a friend\'s network — tells the house its current addresses: at boot, when its interfaces change, and on each scheduled wake. A machine that can reach the house server sends the signed notice itself; one that cannot (the phone whose tailnet is down, a laptop on a network that cannot see the cloud) hands the same signed notice to a peer that can, and the peer relays it. The server keeps that address book, tells the other machines when it changes, and answers a machine that asks where a peer is now. A stored name that points at an unreachable tailnet address is therefore repaired from the address book instead of waiting out a connection timeout; a peer on the same LAN is always reached directly.',
			'One machine can also tell another what to do: name it and say the task — "on the table, play Friends" — and the command is read by that machine\'s own guide there, so it runs on that machine without the words leaving the mesh. The Assistant\'s remote_control panel has a box for the same thing, and its Go button opens the named machine\'s own Manager in a window of the JawnOS app, asking for the same fingerprint or another device as the Dev panel\'s Go (which does the same). A plain browser is told to open it in the app. A single click on the panel\'s dock icon opens it; drag the bar across its top to move it, and it stops at the clothesline. The machine list names each peer once, with Me first. When a peer is selected, the panel also shows its public IP where the house knows it — the address a hub saw it dial from, or an interface address of a machine that sits directly on the internet — and clicking it copies the address. A machine behind a router that no hub has seen dial in shows none.',
			'The remote_control panel can also lend this machine\'s keyboard and mouse to the named machine. Switch Remote keyboard and mouse on, say which side that screen sits on (left, right, top or bottom), then move the pointer into that edge; the first click or key captures the pointer and the other screen behaves like the monitor on that side. Keys and clicks go there until the pointer comes back to the same edge or you press Escape, and the local screen takes over again at once. Take control does the same without crossing. While the hold is open, Ctrl+C on the far screen brings its selected text back to this machine\'s clipboard, and Ctrl+V pastes this machine\'s text there (when the browser allows clipboard access; otherwise the Clipboard box under the button holds what was copied). On the other machine the input is injected with xdotool on X11, or dotool, wtype or ydotool on Wayland, and that machine must grant this house Trusted access (Devices -> Privilege). A peer with no injection backend answers with that, rather than appearing to work.',
			'The remote_control panel also carries a VPN button. Pick a machine and press it to route this device\'s web traffic through that machine\'s exit node, so websites see this device at that machine\'s address; press it again to come back. It is offered only for a machine that advertises an exit node (the house server is the usual one), and the local network stays direct, so the house\'s own addresses still answer. If the tailnet is on and external sites stop resolving while the house still answers, the fault is the tailnet\'s DNS proxy, not the tunnel: Headscale must carry upstream nameservers (1.1.1.1 and 8.8.8.8 are set here), otherwise every external lookup waits on a proxy with nowhere to forward and reads as “no internet”. The Me view of the same panel names this machine\'s own public address, which is the quickest check that the VPN is really carrying the traffic: while an exit node is in force it shows that machine\'s address, and without one it shows this device\'s ISP address. Configure -> Plat -> DNS chooses the outside service, and None stops the lookup and hides the line on every machine and on Me, except a server whose own interface carries a public address — a server behind NAT has none to show.',
			'On the desktop the dashboard also carries Start VPN and Stop VPN, which bring the machine\'s own tailnet up or down. Both the desktop and the Android app watch the underlying network: when Wi-Fi or cellular changes, a running tailnet is stopped and started again so the client binds the new route, while a tailnet the person stopped stays stopped.',
			'A machine does not need the tailnet to open its own manager. The Dev panel discovers the gateway and lists it as a Router card even after the machine leaves that network, with the last time it answered. The router\'s DNS gives each machine its own name at its own address (and local.<house domain> at 127.0.0.1); on a laptop the hosts file can do the same. So the view is opened at the machine\'s own domain, resolves to the loopback or to the machine\'s own LAN address, keeps the wildcard certificate, and works with the VPN off. The tailnet is then only for reaching other machines.',
			'The Android app can go one step further: set "loopback_manager": true in config.json and it opens the manager at 127.0.0.1 directly, so it needs no DNS, router or tailnet at all and answers the moment the device joins a new network. The app carries its paired-device id across to the loopback origin, and the pass is addressed there too; the first launch after the switch opens the domain form once to move that id, then stays on loopback.',
			'A machine with no browser — a headless server — holds its place in the mesh on its own: it registers itself in its own device list, so the tunnels its peers dial in on show up as its addresses, and it keeps pulling each peer\'s newest data on a schedule. A change it has no page to make is queued and handed on by the remote relay job, so the fleet stays in step whether or not anybody has a window open.',
			'The comparison is per table, not just the newest appointment: each machine exchanges a fingerprint of every table (how many rows, the sum of their write times, and the newest write time). A changed setting therefore counts as a change and syncs, while churn that carries no state — window geometry, open tabs, the door and remote timers — is left out of the comparison so it cannot start a sync by itself. Appointments are still the most useful trigger, but they are no longer the only one.',
			'The same comparison keeps one picture when a machine has been away: each table is compared in blocks of a week, and only the blocks whose picture differs are read, so an old row made while offline and seen nowhere else is found without copying the whole table. The blocks are walked from the newest back, so a recent gap is filled before an older one.',
			'A peer house is not trusted just because it is reachable: its row in the Dev panel carries a Privilege (No access, Guest, Resident or Trusted) and a lease in days. A resident may act in the house - start and stop appointments, toggle things, press Go and open a Manager - but configuration stays with the citizen. The lease expires on its own, so access that is no longer renewed stops working.',
			'A message a peer hands over is accepted only from a signed key this house has already pinned. A visitor may reply to a thread the house already holds; starting a new conversation needs a resident grant. A name in a query string is not enough.',
			'A peer that logs in proves the name it claims with its key; a first contact is pinned from the key it offers, and a session that carries no proved name is not trusted for a lease.',
			'A proved peer is rate-limited per house: 30 messages a minute and 120 actions an hour. The counters live on this machine and are not synced; a house that hits the cap is refused until its window slides.',
			'The yellow dot in the corner is the sync notice. While a machine pulls or serves a snapshot, a ring around the dot fills with the overall progress, and the panel it opens stacks a bar for each step — the export, the download, and each table as it merges. A finished sync shows a green check and a failed one a red cross; clicking the dot pins the panel until you click it again, after which the notice resumes its ordinary short life. The size beside a completed sync is the encrypted snapshot that actually moved, not the whole database, so a change-only pull is usually far smaller than the full copy. While the on-screen keyboard is up the dots step out of the way and return as soon as it closes.'
		],
		verified => '2026-10-25',
		related => [ 'backup', 'ble_bridge', 'tickets', 'network' ]
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
			'It can also listen for a voice command: its Voice setting on the Embedded row - Voice: Off, Voice: Any speech (VAD), or Voice: Hey Jawn - starts a clip when it hears speech and sends it to JawnOS to transcribe. See Voice and wake words.',
			'Its Set room is grouped into Screen, Radio and System tabs. Screen carries brightness, volume and the typewriter font, Radio carries the LoRa broadcast and receive toggles and the AP and WiFi credential sends, and System carries Sleep, Save, Restore, Clear Text and Delete.',
			'Sleep is the battery saver. The button is a toggle: when it is lit, the deck turns off WiFi, Bluetooth, LoRa receive and the microphone after the screen has gone dark, and spends the idle time in light sleep. A touch, a key or a move of the trackball wakes it and the screen comes back. A deck on USB keeps its radios up, since the cable is supplying the power.',
			'Recordings, voice clips and the generated chimes are written to the SD card when one is mounted; without a card they fall back to the deck\'s internal storage. Config stays on internal storage either way.',
		],
		verified => '2026-10-19',
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
		verified => '2026-10-26',
		body => [
			'Help is the built-in guide. Search it, browse by category, or open it contextually: press F1 to read about the window you are focused on. The question-mark button in a window\'s title bar opens a Guide associate for that window — the same Guide, in a chat of its own, already aware of the window it came from. The Take the tour button at the foot of the window replays a short tour of the desktop: its windows, the start menu and its System page, the dock and its pseudonyms, Configure, and how to ask the Guide.',
			'Each topic hands you to the Guide along the foot: pick a model and ask. It answers in a chat, and it can also act on the screen. "Show me pictures of George Michael" searches your records and opens the photo browser on them; "how far have I walked this month" and "when am I expected to be 180" are read from your own logs; "show Sarnia on a map" centres the travel map; "where was I on September 18th" reads the recorded place fixes; and "play Friends" plays every episode it matches, as a list. Asked "when did I last have a beer" or "when am I next free", it reads the oldest, newest and next matching appointment from your own records (across the appointments log and the other tables), and the time machine reads them the same way. It reports each step as it goes.',
			'It writes only with your say-so: the Confirmation Requirement. Ask it for an appointment and it stages the proposal and shows you what it would save; nothing is written until you confirm. Ask it to change one you already have — "delay email test by 5 minutes", "make it last 10 minutes", "move it to tomorrow at 3pm" — and it stages that too, then applies it in place. "Stop email test", "stop it in 10 minutes" or "stop it at 5pm" stops the running one at once; "delete the email test one that\'s coming up" (or "the one from yesterday at 3:30pm", "the one a week from now") deletes one, staged for a yes. Say "undo that" and it puts your last change back. The Guide\'s associate - the small chat in the corner, the same Guide and so carrying every one of these powers - carries a Confirm tick beside its close button: untick it and the Guide saves what it proposes without asking. Its configure button also holds Staged: everything the Guide is holding for a yes shows there, each row with a thumbs-up to save it and a trash to throw it away, showing what it is, when, and - when you gave one - how long it lasts, and the chat you left is still there when you come back. It never sends or pays, and never deletes without a yes.',
			'It can give an appointment or a bill a recurrence in your own words too: "every third Saturday of the month", "every Tuesday for the next 6 weeks except on holidays", "the next five full moons", "my mom\'s next 5 birthdays", or "every anniversary of the birth of Abraham Lincoln until my mom is 80". The appointment you are starting is always the first occurrence. If a detail is missing - a birthday it does not have, or which Tuesday you meant - it opens an associate to ask, and the schedule finishes once you answer.',
			'A name can mean more than one thing - "music" the app or a club called Music, or two people called John Smith. When that happens the Guide asks which one you mean instead of picking for you, and the action then runs on the one you chose. You can name the one you mean more exactly: app:music or club:music fixes the kind, maple/john the house, and john#7f3a the short id shown beside the name. The same rule applies to names spoken to a watch or sent to another machine.',
			'You can also teach it your own word for a thing: say "call sleep zzz", "aka zzz for sleep", or "zzz means sleep", and the Guide remembers it; "forget zzz" drops it. In People, open a construct\'s row to see the other names it already answers to and add one; the x beside a chip forgets it. A word that already means something else is refused rather than made ambiguous. Aliases are kept with the house settings, so every machine understands them, and they work in the chat, on the watch and in commands sent to another machine.',
			'There can be several associates at once: the + in a panel\'s bar opens another, each with its own thread. Double-pressing the Assistant button shows the Agents list, where every associate and coding conversation is kept, named by its own words, and a press away from being re-opened or thrown away (see Agents). Its config menu also carries Speak the replies; ticked, each answer is spoken as well as written, through the voice set under Configure → Misc → Speech (Piper first — the same voice the watch\'s answers use).',
			'A thing the visibility rule hides is neither named nor opened here unless its padlock is open, so a hidden album stays out of sight until you unlock it.',
			'It can also tell another of your machines what to do, by name - "on the table, play Friends" - and that machine\'s own guide reads the command there, so it stays on that machine.',
			'You can speak instead of typing: if you press Send with the box empty, the guide starts listening, and Stop turns what you said into words in the box. It uses the same speech-to-text the watch uses. The Converse button turns it into a conversation: the mic opens again after each answer, and the clip ends itself once you stop talking - the pause is measured against the room\'s own noise, learned from the microphone exactly as the keyboard\'s dictation learns it, so a fan or a steady hiss does not keep the mic open - and each thing you say is the next turn of the same thread. Say or type "hey jawn" (or "jawn do") to start one, and "bye jawn" or the End button to stop; while it is on, the button is red. An on-device "hey jawn" listener will call the same switch when its model lands.',
			'Tick the Coding box in the composer (set its model under Configure → Plat → Coding) and the same box becomes the Coding agent. It can change JawnOS\'s own code, check it, and ship it - bumping the version, committing and pushing to GitHub, then restarting - so the program can mend itself from a plain request.',
			'Under each answer is a small good / not-good pair. Press the one that fits and the verdict is kept with the question and the reply, so the guide\'s answers can be judged over time.',
			'You can also teach it new verbs at runtime (Configure → Plat → Guide commands): each is a small JSON entry naming a primitive and its parameters, and because it is a setting it syncs, so every machine understands the same commands.'
		],
		related => [ 'hints', 'handbook', 'assistant' ]
	},

	'live_docs' => {
		title => 'Live docs', category => 'functions',
		templates => [ 'help.pl', 'templates/apps/help.html.ep', 'public/js/manager/help.js' ],
		verified => '2026-10-25',
		summary => 'Help pages that carry a value read when the page is drawn, and examples that open what they describe.',
		body => [
			'Most help is written once and read later, so a version number typed into a sentence goes stale. A live doc fills the value when the page is drawn instead: this page was drawn on {{live:machine}} running JawnOS {{live:version}}, and it is one of {{live:topics}} topics. Open the topic again and the value is read again.',
			'A live value is written as {{live:example_token}}, with a name from the list between the braces. Only these names are filled: version (the installed JawnOS version), machine (this machine\'s name), now (this machine\'s clock at the moment of drawing), ollama (whether a local Ollama answers here), models (how many assistant roles have a model set), languages (how many languages the translator offers), topics (how many help topics this copy carries) and crew (the crew abilities, where that module is loaded). Anything else - a misspelling such as {{live:versoin}}, say - is left on the page exactly as written, so it is visible and does nothing.',
			'Every value is read from the running system, and every one of them is inert text: it is escaped along with the rest of the paragraph, so a machine name can never become markup. Nothing is evaluated, looped over or read from a file a person did not add to the token list by hand.',
			'A topic can also carry runnable examples. Press the button and JawnOS opens the app, or Configure on the named tab, at the place the line describes - the same path the Open button and the Configure tabs already use. There are only two shapes, an app to open and a Configure tab to show; an example holds no URL, no shell command and no path.',
		],
		examples => [
			{ open => 'app', app => 'music' },
			{ configure => 'plat' },
		],
		related => [ 'help_app', 'configure', 'platform' ]
	},

	'keyboard_shortcuts' => {
		title => 'Keyboard shortcuts', category => 'features',
		summary => 'The keys that move windows and drive each app, gathered on one sheet.',
		verified => '2026-10-24',
		sheet => 1,
		body => [
			'Shortcuts fall into two groups. The desktop keys work whatever is in front: moving, maximising and closing windows, the app switcher, the start menu, dialog boxes and Help itself. An app\'s own keys act only while that app is the front window, and never while the focus is in a text field - a field keeps the space bar, the arrows and Enter for typing. The Super key is the Windows key on a PC and the Command key on a Mac; Folders also accepts Cmd wherever Ctrl is named, while a Terminal keeps Cmd for the browser.',
			'The sheet below is built from the same lists that each app carries on its own Help page, so the two cannot drift apart. Every app with keys of its own is listed here under its name, and the heading is a link straight to its topic. The keys named with an app are the ones worth learning; ordinary form keys such as Enter to press the focused button are not repeated for every box.',
			'The same sheet can be written out as a file for printing or for reading away from the screen: run perl scripts/keyboard_shortcuts.pl from the jawnos folder, which regenerates docs/KEYBOARD-SHORTCUTS.md from this registry. Add --check to the command to ask whether that file is still current; it exits non-zero when it is not.'
		],
		related => [ 'windows', 'start_menu', 'search', 'folders', 'terminal', 'hints' ]
	}
);

# ---- live docs: values a page reads when it is drawn ------------------------
# A live doc is still ordinary help text, but it may carry a placeholder written
# {{live:name}}. Only a name in this table is filled; every value is a
# no-argument sub returning a plain string. There is deliberately no eval and no
# string interpolation here, so a token can never run code or reach anything a
# person did not add to this file by hand. A name that is not listed is left on
# the page exactly as written, so a misspelling is visible and harmless.
our $live_ollama_memo;
our %live_token = (
	version => sub {
		my $v = defined &subs::jawn_version ? eval { &subs::jawn_version() } : undef;
		# A bare `require help.pl` (the auditor, a one-liner) has no subroutines.pl
		# loaded, so fall back to the same file the app reads.
		if (!defined $v || $v !~ /\S/) {
			$v = eval {
				my $fh;
				open $fh, '<', './VERSION' or die;
				local $/;
				<$fh>;
			};
			$v = '' unless defined $v;
			$v =~ s/\s+$//;
		}
		return (defined $v && $v =~ /\S/) ? $v : 'unknown';
	},
	machine => sub {
		my $v = eval { &subs::machine_name() };
		$v = eval { &subs::device_setter() } if !defined $v || $v !~ /\S/;
		return (defined $v && $v =~ /\S/) ? $v : 'unknown';
	},
	now => sub {
		my $ms = eval { &subs::rightNow() };
		return 'unknown' unless defined $ms && $ms =~ /^\d+$/;
		my @t = localtime(int($ms / 1000));
		return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
			$t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
	},
	ollama => sub {
		# A connect probe, not a shelled command and not a model fetch: the local
		# API is asked once a minute at most, because one help page may be drawn
		# many times in a row.
		my $now = time;
		return $live_ollama_memo->{'value'}
			if $live_ollama_memo && $live_ollama_memo->{'at'} > $now - 60;
		my $up = 0;
		eval {
			require IO::Socket::INET;
			my $sock = IO::Socket::INET->new(
				PeerHost => '127.0.0.1', PeerPort => 11434,
				Proto => 'tcp', Timeout => 0.3
			);
			if ($sock) { $up = 1; close $sock; }
		};
		my $value = $up ? 'running' : 'not running';
		$live_ollama_memo = { at => $now, value => $value };
		return $value;
	},
	models => sub {
		my @roles = qw/help_assistant eval_assistant visual_assistant
			text_to_image_assistant text_to_audio_assistant
			text_to_video_assistant coding_assistant transcription_assistant/;
		my $n = eval {
			my $s = &subs::settings_grabber({ app => 'mail', settings => [ @roles ] }) || {};
			scalar grep { defined $s->{$_} && $s->{$_} =~ /\S/ } @roles;
		};
		return defined $n ? "$n" : 'unknown';
	},
	languages => sub {
		my $n = eval {
			my $l = &language::translation_languages();
			ref $l eq 'ARRAY' ? scalar @{$l} : undef;
		};
		return defined $n ? "$n" : 'unknown';
	},
	topics => sub { return scalar keys %topic },
	crew => sub {
		my $n = eval {
			return 'unavailable' unless defined &crew::abilities;
			my $a = &crew::abilities();
			return ref $a eq 'ARRAY' ? scalar @{$a}
				: ref $a eq 'HASH' ? scalar keys %{$a}
				: 'unavailable';
		};
		return (defined $n && length $n) ? $n : 'unavailable';
	},
);

# ---- live docs: runnable examples ------------------------------------------
# A topic may carry `examples`, each in one of two fixed shapes:
#
#   { open => 'app', app => 'music' }   opens that app's window
#   { configure => 'plat' }             opens Configure on that tab
#
# The tab names below are the tab ids the Configure window itself uses, so an
# example travels the same path as a press on that tab. Nothing else is
# accepted: no URL, no shell, no path.
our %example_configure_tab = (
	me    => [ 'me_settings', 'Me' ],
	enc   => [ 'restore_list', 'Enc' ],
	system => [ 'system_setting_lister', 'Sys' ],
	misc  => [ 'misc_setting', 'Misc' ],
	plat  => [ 'plat_setting', 'Plat' ],
	app   => [ 'appointment_list_grabber', 'App' ],
	dev   => [ 'device_lister', 'Dev' ],
	tun   => [ 'tunnel_lister', 'Tun' ],
	pseud => [ 'pseudonym_setting_lister', 'Pseud' ],
	store => [ 'store_setting_lister', 'Store' ],
);

# Keyboard shortcuts, keyed by the topic they belong to. Each row is
# [ keys, action ]. They live beside the prose but in one list, so an app\'s own
# Help page and the aggregated cheat sheet are always the same words. The
# desktop keys are the 'keyboard_shortcuts' entry; every other key is an app's
# own. Keep the actions in the imperative, and name keys as they are printed on
# the keyboard (Super, Ctrl, Alt, Shift).
our %shortcuts = (
	'keyboard_shortcuts' => [
		[ 'Super+Left', 'Fit the front window to the left half of the screen' ],
		[ 'Super+Right', 'Fit the front window to the right half' ],
		[ 'Super+Up', 'Maximise the front window, or restore it if it is already maximised' ],
		[ 'Super+Down', 'Minimise the front window' ],
		[ 'Super+Q', 'Close the front window' ],
		[ 'Super+Ctrl+Left / Right / Up / Down', 'Nudge the front window a little in that direction' ],
		[ 'Super+Shift', 'Open the app switcher; keep Super held, press Left or Right to choose, then release Super' ],
		[ 'Ctrl+Alt', 'Open or close the start menu' ],
		[ 'F1', 'Open Help for the window in focus, or for the control under the pointer' ],
		[ 'Enter', 'Press the highlighted button in a dialog box' ],
		[ 'Escape', 'Cancel the dialog box, or leave the mode you are in' ]
	],
	'folders' => [
		[ 'Ctrl+A', 'Select every item in the listing' ],
		[ 'Ctrl+C', 'Copy the selection' ],
		[ 'Ctrl+X', 'Cut the selection' ],
		[ 'Ctrl+V', 'Paste into the folder on screen' ],
		[ 'Ctrl+L', 'Type a path instead of browsing to it' ],
		[ 'Alt+Left', 'Go back to the folder visited before this one' ],
		[ 'Alt+Right', 'Go forward again' ],
		[ 'Enter', 'Open the selected item' ],
		[ 'F2', 'Rename the one selected item' ],
		[ 'Delete', 'Move the selection to the Recycle Bin' ],
		[ 'Shift+Delete', 'Shred the selection for good' ],
		[ 'Arrow keys', 'Walk the listing' ],
		[ 'Shift+Arrow', 'Extend the selection from the last click' ],
		[ 'Home / End', 'Jump to the first or last item' ],
		[ 'A letter or name', 'Jump to the first item whose name starts with what you type' ],
		[ 'Escape', 'Clear the selection, or stop editing the path' ]
	],
	'gallery' => [
		[ 'Left / Right', 'Show the previous or next picture in the viewer' ],
		[ 'Escape', 'Close the viewer' ]
	],
	'marker' => [
		[ 'Ctrl+Z', 'Undo the last stroke' ],
		[ 'Ctrl+Shift+Z', 'Redo' ],
		[ 'Ctrl+Y', 'Redo' ],
		[ '+ or =', 'Zoom in' ],
		[ '- or _', 'Zoom out' ],
		[ '0', 'Fit the whole board in the window' ]
	],
	'music' => [
		[ 'Space', 'Play or pause' ],
		[ 'Left', 'Previous track' ],
		[ 'Right', 'Next track' ],
		[ 'Up', 'Next chapter' ],
		[ 'Down', 'Previous chapter' ],
		[ 'F', 'Full screen the player' ],
		[ 'Arrows on an EQ band', 'Raise or lower that band; Home returns it to flat' ]
	],
	'synth' => [
		[ "A W S E D F T G Y H U J K O L P ; '", 'Play the chromatic scale from the current octave, with Keys on' ],
		[ 'Z', 'Down an octave' ],
		[ 'X', 'Up an octave' ]
	],
	'studio' => [
		[ 'Delete / Backspace', 'Remove the selected take' ],
		[ 'S', 'Split the selected take at the playhead' ]
	],
	'terminal' => [
		[ 'Ctrl+C', 'Interrupt the running command' ],
		[ 'Ctrl+D', 'End input' ],
		[ 'Ctrl+Z', 'Suspend the foreground job' ],
		[ 'Ctrl+L', 'Clear the screen' ],
		[ 'Tab / Shift+Tab', 'Complete forward or backward' ],
		[ 'Ctrl + a letter', 'Send that letter\'s usual control code to the shell' ],
		[ 'Up / Down in the Commands box', 'Recall an earlier or later command' ],
		[ 'Function and navigation keys', 'Sent to the running program as a terminal expects' ]
	],
	'ide' => [
		[ 'Tab', 'Insert two spaces in the code editor' ]
	],
	'notes' => [
		[ 'Enter', 'Save the note on a desk; Shift+Enter makes a new line (on a phone Enter makes the new line)' ]
	],
	'chat' => [
		[ 'Enter', 'Send the message in the composer' ]
	],
	'market' => [
		[ 'Enter', 'Add the typed item, or find the typed barcode' ]
	],
	'help_app' => [
		[ 'Enter', 'Ask the Guide the question in the composer' ]
	],
	'search' => [
		[ 'Up / Down', 'Move through the results' ],
		[ 'Enter', 'Open the chosen result' ],
		[ 'Escape', 'Close the result list' ]
	]
);

# The cheat sheet's order: the desktop keys first, then the apps as a person
# would look for them. Any topic with rows but not named here follows in key
# order, so adding a new app cannot silently drop it from the sheet.
our @shortcut_order = qw(
	keyboard_shortcuts folders gallery marker music synth studio terminal ide
	notes chat market help_app search
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

# ---- first run ------------------------------------------------------------
# The welcome tour is shown once per install. The flag is a settings row whose
# absence means first run; it lives in __president, one of the protected
# (machine-local) apps, so it belongs to this database rather than to a
# browser's localStorage. Reading it without a device matches any row, which is
# what keeps it per install when a person uses more than one browser.
sub welcome_seen {
	my $row = eval {
		&subs::db_query(
			'select value from settings where app = ? and setting = ? order by server_time desc limit 1',
			'__president', 'welcome_tour'
		)->hashes->[0];
	};
	return (ref $row eq 'HASH' && defined $row->{'value'} && length $row->{'value'}) ? 1 : 0;
}

sub welcome_mark {
	my $value = shift;
	$value = &subs::rightNow() unless defined $value && length $value;
	eval {
		&subs::setting_setter({
			app => '__president', setting => 'welcome_tour', value => $value,
			device => &subs::device_setter()
		});
	};
	return 1;
}

# One live value, or 'unavailable' when it cannot be read. Kept private so the
# only public way into the registry is render_live below.
sub _live_value {
	my ($name) = @_;
	my $sub = $live_token{$name};
	return 'unavailable' unless $sub;
	my $value = eval { $sub->() };
	return (defined $value && length $value) ? $value : 'unavailable';
}

# Fill the live placeholders in one piece of help text and return HTML-ready
# text. The whole string is escaped first, exactly as the template used to do;
# a recognised token is then replaced with its value, which is escaped too so a
# machine name or a version can never become markup. An unknown token is left
# verbatim. The template prints the result with <%== %> precisely because the
# escaping has already happened here.
sub render_live {
	my ($text) = @_;
	return '' unless defined $text && length $text;
	my $html = xml_escape($text);
	$html =~ s{\{\{live:([a-z][a-z0-9_]*)\}\}}{
		my $name = $1;
		exists $live_token{$name} ? xml_escape(_live_value($name)) : "{{live:$name}}"
	}ge;
	return $html;
}

# Resolve one runnable example to the values the template and help.js use, or
# undef when it is not one of the two shapes above. The label is the app's own
# topic title (a proper name) or the Configure tab's printed name, so the
# template can put the existing "Open" label in front of it.
sub example {
	my ($spec) = @_;
	return undef unless ref $spec eq 'HASH';
	if (($spec->{'open'} // '') eq 'app') {
		my $app = $spec->{'app'} // '';
		return undef unless $app =~ /^[a-z][a-z0-9_]*$/;
		return { kind => 'app', value => $app, label => ($topic{$app}{'title'} || $app) };
	}
	if (defined $spec->{'configure'}) {
		my $tab = $spec->{'configure'} // '';
		return undef unless $tab =~ /^[a-z][a-z0-9_]*$/;
		my ($id, $label) = @{ $example_configure_tab{$tab} || [ $tab, $tab ] };
		return undef unless $id =~ /^[a-z][a-z0-9_]*$/;
		return { kind => 'configure', value => $id, label => 'Configure: ' . $label };
	}
	return undef;
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

# The keyboard rows belonging to one topic, as [ keys, action ] pairs.
sub shortcuts_for {
	my ($id) = @_;
	$id = help::key($id);
	return @{ $shortcuts{$id} || [] };
}

# Every topic that carries shortcuts, in the sheet's reading order, grouped for
# the cheat sheet. $skip drops one topic (the sheet calls with its own id so the
# desktop keys are not printed twice).
sub shortcut_sheet {
	my ($skip) = @_;
	$skip = help::key($skip) if defined $skip && length $skip;
	my @ids;
	my %seen;
	foreach my $id ( @shortcut_order, sort keys %shortcuts ) {
		next if $seen{$id}++;
		next unless $shortcuts{$id} && @{ $shortcuts{$id} };
		next if defined $skip && $id eq $skip;
		next unless $topic{$id};
		push @ids, $id;
	}
	return map { {
		id => $_,
		title => $topic{$_}{'title'},
		rows => $shortcuts{$_}
	} } @ids;
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
		$hay .= ' ' . join ' ', map { @{$_} } @{ $shortcuts{$id} || [] };
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
	if (@{ $shortcuts{$id} || [] }) {
		push @lines, 'Keyboard shortcuts: ' . join('; ', map { $_->[0] . ' = ' . $_->[1] } @{ $shortcuts{$id} });
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
- When a schedule could not be read, the question names a token. Ask what is unclear,
  then use schedule with that token and the person's clarified words (for example
  "every third Saturday of the month"). It writes the repeat appointments or bills;
  do not invent dates yourself.
- "Where was I" and "when did I last see X" are different questions. For a place
  at a time, use where_when with an absolute date. For a record or photo, use find.
- For "show me <place> on a map", use show_place - it works offline from the
  places we have measured, so an odd name is matched against the things named for it.
- For "how far did I walk" use measure with measure "walk"; for a weight goal use
  measure with measure "weight". Do not guess a number - always take it from measure.
- To translate words or a phrase, use translate with "text" and the language the
  person named in "to". To translate what is on screen, use translate_page. If they
  ask which languages are offered, use translate_languages; never invent a language
  that is not in its list.
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
