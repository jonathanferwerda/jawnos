# Help registry part 2 of 9: The web, the terminal, the network, the camera and the phone.
package help;

use strict;
our %topic;

$topic{'internet'} = {
		title => 'Internet', category => 'apps', app => 'internet',
		templates => [ 'templates/internet/internet.html.ep', 'templates/web/web.html.ep', 'public/js/manager/internet.js', 'public/js/manager/page_agent.js' ],
		verified => '2026-11-04',
		summary => 'Web and Browse: saved pages with measures, and a real browser that counts site time.',
		body => [
			'Internet has two components. Web holds the pages the house fetched; each can be opened, or measured with the Measures tool. Browse opens a real browser in its own window on a computer (or its own screen on a phone), because a live page cannot run inside the manager window. The tab you used last is the tab Internet opens, so Web and Browse do not keep switching places.',
			'Browse counts the time each site is in front, but only in the JawnOS browser: a page opened in another browser is not counted, and neither is the Facebook app. Every domain you visit is also a bookmark. Press a domain to open it in the browser, or type an app beside it: the box suggests any appointment in the house that the visibility rule shows here and now, so an app the rule hides (by place, or by a lockdown) is not offered. Pick one to assign the domain, so facebook.com minutes land under the app you chose. While the JawnOS browser stays on that domain, the app\'s appointment runs; when you leave the site, close the tab or change app, it stops at the last moment the page was in front. Type a dash to stop counting the domain against an app.',
			'A domain you assigned opens two ways: its link opens the browser at the saved address, and the app name beside it opens that app in the manager exactly as its own window. The Browse tab shows today\'s site time beside each domain, and the time is kept per machine so the phone and the laptop do not blur together.',
			'To measure a live page, open a saved page from the Web tab with the measure icon. The browser opens with the picker on; click the value you want. JawnOS offers the shapes it can read and saves the one you pick, exactly as the Measures tool does for a fetched page.',
			'The browser is a separate surface on purpose: it has its own cookies and history, keeps the manager\'s bridges away from the pages you visit, and cannot reach the house\'s local address.',
			'The JawnOS browser blocks a baseline of ad servers and the boxes they leave behind. Press the bug button at the right of the tab row to enter bug mode, then press anything on the page you do not want to see: it disappears at once, and the browser remembers the shape for that site, so it stays gone on the next visit. Press the bug button again (or press Esc) to leave bug mode. The list button beside it shows everything blocked on the current site; each entry can be removed, or the whole site cleared. The switch there turns ad blocking off for every site. A video that asks for fullscreen fills the screen: the browser\'s own bars step out of the way and return when you leave fullscreen.',
			'The Internet window\'s title bar carries the Guide\'s page-agent button in place of the question mark: press it and the Guide is attached to this window, able to read and fill its fields — the address in Browse, the app box beside a domain — from what you discussed, from your own records, or from another field. Closing the panel detaches it. Help for this window is still a press of F1 away, and every other window keeps its question mark.'
		],
		steps => [
			'Open Internet from the start menu.',
			'Web lists the pages the house fetched; use the browser icon to open one, or the measures icon to point at a value in it.',
			'Browse takes an address and opens the JawnOS browser; time on each site appears under Site time today.',
			'To make a domain count toward an app, type the app name in its row and pick it; type a dash to clear it. Press the domain to open it, or the app name to open that app.',
			'A page opened in another browser is not counted; the count is per machine.',
			'To remove something from a page, press the bug button at the right of the tab row, press the element, then press the bug button again. The list button beside it shows what is blocked on this site; the switch there turns ad blocking off.',
			'Press the page-agent button in the title bar to have the Guide fill the address or the app box for you; close the panel to detach it.'
		],
		related => [ 'web' ]
	};
$topic{'web'} = {
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
	};
$topic{'terminal'} = {
		title => 'Terminal', category => 'apps', app => 'terminal',
		summary => 'A shell, in a window - on this machine or another one.',
		verified => '2026-11-02',
		body => [
			'Terminal is a real shell attached to the machine running JawnOS. It is where you do the hands-on work: scripts, checks, and the occasional bit of archaeology.',
			'The toolbar at the foot of the window switches views. Shell is the live session: click it and type straight into it, with colour, cursor keys, Backspace, Tab, Ctrl+C and the rest behaving as they do in a desktop terminal. Commands holds a short history of what you sent to the shell. Errors and Log are readable lists, each with its own Clear button in the header; the newest entry is always in view, and the list follows new entries while you are at the bottom.',
			'The status at the left of the toolbar names the machine the shell is running on. Press the server button beside it to open the terminal settings: connect back to this machine, or pick one of the machines linked to the house and connect to it over ssh. Each machine remembers its own login name and port; the port is 8022 by default, which is the sshd JawnOS runs elsewhere. Each Terminal window has its own shell, so switching here changes only this window. The panel also sets the text size.',
			'Open as many terminals as you need from the Terminal pin or the start menu: every window runs its own shell, can be moved and resized on its own, and wears its own tile on the taskbar. Minimising a window keeps its tile, so the taskbar is the quickest way to jump between them. Closing a window leaves its shell running on the server; the Open sessions list in the settings panel brings a closed one back into a window, and End closes a shell you no longer need.',
			'The code button in the toolbar opens the Coding agent\'s chatbox, so you can ask for a change in words and watch it run the commands and ship the result without leaving the terminal. It keeps its own conversation. The bar drags the panel anywhere on the screen, and + in the bar opens another agent, each with its own thread. A run keeps going in the background, so reloading the page or restarting the tree does not lose it; the panel picks it back up when it returns.',
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
	};
$topic{'network'} = {
		title => 'Network', category => 'apps', app => 'network',
		templates => [ 'templates/apps/network.html.ep', 'public/js/manager/network.js' ],
		verified => '2026-10-30',
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
	};
$topic{'camera'} = {
		title => 'Camera', category => 'apps', app => 'camera',
		'templates' => [ 'templates/apps/camera.html.ep', 'public/js/manager/camera.js' ],
		controls => [ 'Take a photo', 'Record a video', 'Unclaimed media', 'Select all', 'Approved' ],
		verified => '2026-11-01',
		summary => 'The device camera and video recorder, plus the pool of unclaimed media waiting to be filed.',
		body => [
			'Camera takes a photo or records a video. In the app it opens the device camera and its video recorder (window.JawnCamera), so you get a viewfinder you can see and the camera\'s own processing. On the desktop and in a browser it uses the machine\'s own webcam through getUserMedia.',
			'A capture is filed under the Camera app. In the app an appointment\'s own camera buttons open the same OS camera: the rear/front pair in its Details view and Camera (native) / Video (native) in its Media group. Details files the capture onto that row. The Media group names only the app, so it files onto the app\'s open session, or its newest row when nothing is running - never into Unclaimed media.',
			'A capture taken in the Camera app itself - and media an agent generated without an appointment - waits in Unclaimed media with a one-week warranty. Tick the items you want (or Select all), then search for an appointment name and press Approved, or drop them onto the drop zone.',
			'On the desktop and in a browser, Source chooses which camera the next capture uses: Auto, Front or Back, and then every video input the machine reports by name. The choice is remembered on that machine, so the same lens is used next time. On a phone the OS camera chooses its own lens.',
			'An appointment\'s Media group carries the same idea across the House: each row of buttons has a machine picker under it, so a photo can be taken on a chosen phone and a scan on a chosen computer while the appointment stays where you are. The pick is remembered for that person at that screen, and the picture or scan lands on the appointment as usual. Only a machine that can do the job is offered - phones for a camera, computers for a flatbed or feeder scan.'
		],
		steps => [
			'Open Camera from the start menu, or pin it to the taskbar.',
			'Choose a Source when the machine has more than one camera.',
			'Tap Take a photo or Record a video; the OS camera opens.',
			'The capture is saved when you accept it in the camera.',
			'To file unclaimed media onto an appointment, tick items, search for the appointment name, and press Approved.'
		],
		related => [ 'gallery' ]
	};
$topic{'phone'} = {
		title => 'Phone', category => 'apps', app => 'phone',
		templates => [ 'templates/apps/phone.html.ep', 'public/js/manager/phone.js', 'public/js/manager/screening.js' ],
		controls => [ 'Known', 'Recent', 'Blocked', 'All', 'IVR', 'Dial', 'Call', 'Call routing', 'Caller ID', 'Phone app', 'Block', 'Unblock', 'Save', 'Follow the person', 'Ring through', 'Receptionist', 'Voicemail', 'Reject', 'Arm the gateway', 'Hold music', 'Voicemail length', 'Record greeting', 'Stop', 'Play greeting', 'Remove greeting', 'Transcript', 'Add flow', 'Edit flow', 'Rename flow', 'Delete flow', 'After', 'Hide', 'Add step', 'Remove step', 'Drag to reorder', 'Step type' ],
		verified => '2026-11-06',
		summary => 'Calls, the house\'s known contacts, and a dial pad.',
		body => [
			'Phone shows the calls the house has logged - every call is an appointment with the subtype phone, on the caller\'s own app - and the numbers the house knows. Known is the people it knows; Recent lists the latest calls, and a row opens that person\'s thread; All adds the numbers that are only numbers, the ones a caller left behind that no name has claimed yet, which is where you go to find an unknown caller and name them.',
			'A person can keep more than one line (a home number, a work number, a second mobile - set under Configure, in the app\'s Phones configuration, where the main line is the first row and every other line sits under it). They are listed together on one row, the plain phone number first and the rest with their type; tapping any one fills the dial pad with that number, and a call or text from any of them still reaches the person.',
			'Blocked shows the Box Office\'s blocked numbers, each with an Unblock button. A number there never rings: the phone turns the call away and files it as a cancelled call, and Recent leaves it out.',
			'A person or a number can answer differently from the rest of their kind. Press the routing icon on a recent call or on a known person and choose Follow the person, Ring through, Receptionist, Voicemail or Reject; the sheet says what that number\'s calls do now and why. The choice belongs to the number, so it rides the house\'s sync and the phone obeys it before it rings, even with no page open.',
			'IVR is the reception page. Turn it on, choose the remote machine that runs the audio gateway, and set up the flows. A flow is one voice and one set of words the gateway speaks: a name, a Piper voice, the greeting, the name prompt, the voicemail greeting, the thanks, the hold music the caller hears while somebody decides to pick up - None, Shuffle all of the gateway\'s music library, or one track - and an After choice: Hold, Voicemail or End. The list shows each flow\'s name and how many kinds of caller it answers, and it folds to one open flow at a time: press a flow to open its words, press it again to fold it, Add flow to begin another, Rename to change its name, and Delete - twice, the house\'s habit for anything that leaves a lasting rule - to remove one. A built-in flow can be edited but not deleted. Each flow also has a Callers list: Add caller picks a person, vendor or corporation the house already knows, Add number takes a typed line, and Remove takes an entry away. A call checks the exact number a flow names, then the person, vendor or corporation the number belongs to, and only then the call flow below. A number belongs to one flow, so adding one another flow already had moves it here and says so. The heart of a flow is its Steps: an ordered list the gateway speaks from top to bottom. Drag a step by its handle to move it, or press Add step to put another kind in the list and Remove to take one out. Say plays one of the flow\'s own texts - the greeting, the name prompt, the thanks or the voicemail greeting - and an empty text is skipped. Ask for a name plays the name prompt, beeps and records the caller\'s name. Keypad menu plays its spoken text, listens for a digit for its timeout, and jumps to Ring, Reject or the flow a digit names; a digit left on Nothing, or no digit in time, carries on to the next step. Hold music plays this flow\'s hold music for its seconds, or until the caller leaves when it is 0. Voicemail plays the voicemail greeting and records a message, and Voicemail length sets how many seconds that message may run - 15 to 1800, five minutes unless the flow says otherwise, and the gateway and the Send to voicemail button both obey the flow\'s own number. After uses the flow\'s After choice. A flow with no steps still speaks the old order: greeting, ask for a name, thanks, then After. Beside a flow\'s Voicemail greeting, Record captures a greeting from this device\'s microphone, Stop ends it, Play hears the one in use, and Remove goes back to the typed words. A greeting is a minute at most, and one recording is kept per flow: Save puts the latest one on the flow. The recording is a house file in the media folder; the gateway plays it when the voicemail step runs, and a caller hears the typed greeting instead if the file has moved or cannot be played. Deleting a flow also drops every keypad digit that pointed at it. The prompts are spoken on the gateway machine, so a phone with no voice engine of its own works; leave the choice on this machine when this is the one with the adapter. Below the flows is the call flow for each kind of caller - unknown numbers, blocked numbers, and a person who is you, a friend, a stranger or an enemy - each set to ring through, be rejected, or go to one of the flows. Save puts the flows and the routing in place, and Arm the gateway renders the receptionist flow and puts the gateway back to listening after you have changed its words. The library is the folder ~/Music/Jon Ferwerda on the gateway machine, and the hold dropdown lists what that machine can actually play. The machine list shows which house machines are online, and the line under it shows what the gateway is doing. The receptionist waits for the caller to speak and lets them finish before it moves on, so a slow start still leaves a name. The line under the machine list also names the WiFi band the gateway machine is on: a machine on 2.4 GHz shares its antenna with Bluetooth and the caller\'s voice breaks up, so move it to 5 GHz or a cable. While a call is up, the transcript\'s header names the caller - the house\'s name for the number when it knows one, and the number itself when it does not - and Live transcript shows the caller\'s words as chat bubbles - the sentence being recognised is dimmed and an italic line, and each finished sentence joins it - so a screening can be read without listening to it. Every device with the house open shows a small panel at the top of the window when a screening starts, with the same transcript and Connect me, and it closes when the line is free - so the call is visible on the tablet and the laptop, not only on the phone. Hide tucks the panel into a pill on the same edge and leaves a call you have already connected running; press the pill to bring it back. A device that opens, wakes or reconnects while a call is up gets the panel by itself, so you can press Connect me on the laptop you have just opened. The transcript needs whisper.cpp installed on the gateway machine (Configure → Plat → AI, Transcription); without it the call is unchanged and the box says why there is no text. The words are kept on the gateway beside the recording and the phone files them into the Chat app for that number when the call ends. The Voicemail pill at the top of the app is the messages themselves, newest first: each row shows when the call came and how long the message ran, Play asks the gateway for the recording, and a message a call left with words offers Transcript, an expanding row that opens that same Chat note instead of keeping a second copy of the words. The IVR pane keeps a one-line Voicemail count back to the same list, and the pane asks the gateway for the list every couple of seconds while it is open.',
			'In the app a screened call has a face of its own: with the screen on it is a floating panel over whatever you are doing, and with the screen off or the phone locked it is an alarm-style screen raised over the lock screen. It shows the caller and the same live transcript, with Connect phone (take the call back on this phone, on the earpiece or a headset) and Disconnect. Connect me, on the IVR pane, hands the call to the device you pressed it on over WebRTC: you hear the caller and speak from that device, with the tailnet carrying the audio and the gateway speaker and microphone out of the path. Press it again to hand the call back. While a dialer call is screened the app face shows Connect me (it opens this device\'s Phone page and bridges the call to it), Connect phone and Disconnect.',
			'Known and All: tapping a number fills the dial pad with it. In the app the device\'s own address book (window.JawnContacts) replaces the Known list once its permission is granted.',
			'Dial is a pad that places a call on a phone (termux-telephony-call). On the desktop it says dialing is only available on a phone.',
			'The reception only works while JawnOS is the phone app: without that role Android hands an incoming call to another dialer and the house never sees it, so a Be the phone app button appears beside the caller-ID button. Press it and accept the system\'s confirmation.',
			'With Caller ID on (the button asks for the Call screening role), the house learns who is calling as it rings. In the app that role names the caller on screen: an incoming call wakes the screen over the lock screen with their picture (the house\'s own image for them, or the JawnOS logo), their name, the number, and Answer and Decline. Without it the house\'s call-log check files the call a moment later.',
			'A call is recorded by the app itself, not by whatever page happens to be open: the phone keeps one record per call - who, which way, when, and whether anyone answered - and the house files it from that, so a call taken with the app in the background still becomes an appointment on the caller\'s own app (or the phone app when the number is not known). It opens at the ring and closes at the hangup, or cancels when nobody answered.',
			'A recent call\'s Block button - twice, the house\'s habit for anything that leaves a lasting rule - puts that number on the Box Office\'s blacklist, drops the call out of Recent, and Unblock in the Blocked pane takes it off again.'
		],
		steps => [
			'Open Phone from the start menu, or pin it to the taskbar.',
			'Known: tap a number to fill the dial pad - a person with several lines lists them all, and each one taps on its own.',
			'Recent: tap a call to open the caller\'s appointment thread.',
			'Recent or Known: press the routing icon on a person or a number to choose how their calls are handled.',
			'Recent: press Block twice on a call to bar that number from ringing again.',
			'Voicemail: open the Voicemail pill to play the latest messages and read their transcripts.',
			'Blocked: press Unblock twice to let a number through again.',
			'IVR: choose a machine, open a flow to set its voice, words and hold music, drag its steps into the order it should speak and add a keypad menu where a caller should choose, point each kind of caller at a flow, then press Save.',
			'IVR: open a flow and press Record greeting beside its voicemail greeting to record one - Stop ends it, Play hears it, and Remove uses the typed words again.',
			'Dial: key a number and press Call.'
		],
		related => [ 'mailbox', 'box_office' ]
	};
1;
