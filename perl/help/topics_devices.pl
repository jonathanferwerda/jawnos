	# ------------------------------------------------------------ devices
# Help registry part 9 of 9: the watch, the deck, the pico, the bridge and the help pages.
package help;

use strict;
our %topic;

$topic{'watch'} = {
		title => 'The T-Watch', category => 'devices',
		summary => 'A wrist clock, notifications and app buttons.',
		body => [
			'The T-Watch is the wearable: a clock that also shows notification lines and screens of app buttons, logs steps, wakes when you raise your wrist to look at it, and can listen for a voice command. A button you press on it runs that app\'s movement in JawnOS, and a command button runs on every machine unless it names one.',
			'A button whose toggle is running wears a yellow ring rather than a yellow fill, so the app\'s own colour stays visible. A command reports its outcome on the button that was pressed: an every-machine command flashes green for two seconds when every machine took it and red when one did not; a command naming a machine flashes red only when it could not be handed over at all. When the named machine is away, the house relay keeps the press and delivers it there once that machine is back.',
			'Its listening mode - off, any speech, or a wake word such as Hey Jawn or Jawn Do - is set from the watch row in the Embedded panel; see Voice and wake words.',
			'Its status bar carries the battery (with the time in its place whenever the clock is not the screen you are on) and, hard against the right edge, the name of the machine it is talking to - its homebase - in place of an address.',
			'An answer to a request the guide associate handles arrives on the watch itself: the words on screen, and the voice over its speaker unless the Audio replies toggle on its Embedded row is off.',
			'It talks to JawnOS over Bluetooth through a bridge running on a nearby phone or desktop, and stays with the machine it was paired to (its homebase) - another machine that links to it lets it go again.',
		],
		verified => '2026-10-15',
		related => [ 'voice', 'ble_bridge', 'tdeck', 'embedded' ]
	};
$topic{'tdeck'} = {
		title => 'The T-Deck', category => 'devices',
		summary => 'A handheld terminal with a keyboard and GPS.',
		body => [
			'The T-Deck is the handheld: a keyboard, a touch screen and GPS in a device small enough to carry. It acts as a handheld terminal — a "teletype" — for the machine it is talking to, and it can report where it is.',
			'It can also listen for a voice command: its Voice setting on the Embedded row - Voice: Off, Voice: Any speech (VAD), or Voice: Hey Jawn - starts a clip when it hears speech and sends it to JawnOS to transcribe. See Voice and wake words.',
			'Its Set room is grouped into Screen, Radio and System tabs. Screen carries brightness, volume and the typewriter font, Radio carries the LoRa broadcast and receive toggles and the AP and WiFi credential sends, and System carries Sleep, Save, Restore, Clear Text and Delete.',
			'Sleep is the battery saver. The button is a toggle: when it is lit, the deck turns off WiFi, Bluetooth, LoRa receive and the microphone after the screen has gone dark, and spends the idle time in light sleep. A touch, a key or a move of the trackball wakes it and the screen comes back. A deck on USB keeps its radios up, since the cable is supplying the power.',
			'Recordings, voice clips and the generated chimes are written to the SD card when one is mounted; without a card they fall back to the deck\'s internal storage. Config stays on internal storage either way.',
			'Its room buttons behave like the watch\'s: a running toggle wears a yellow ring rather than a yellow fill, and a command reports its outcome on the button - green for two seconds when every machine took an every-machine command, red when one missed it or a command naming a machine could not be handed over.',
		],
		verified => '2026-10-19',
		related => [ 'watch', 'pico', 'ble_bridge', 'voice' ]
	};
$topic{'pico'} = {
		title => 'The Pico', category => 'devices',
		summary => 'A microcontroller that drives real pins.',
		body => [
			'The Pico 2W is the hands-on device: it drives real-world pins — LED, relay, servo, switch — and holds a small LCD. Jobs are scheduled on it and fire when their time comes, so it can act on the physical world on JawnOS\'s behalf.'
		],
		related => [ 'tdeck', 'watch', 'embedded' ]
	};
$topic{'ble_bridge'} = {
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
	};
$topic{'help_app'} = {
		title => 'This Help app', category => 'features', app => 'help',
		templates => [ 'templates/apps/help.html.ep', 'public/js/manager/help.js', 'public/js/manager/page_agent.js' ],
		summary => 'The map you are reading now, and its guide.',
		verified => '2026-11-02',
		body => [
			'Help is the built-in guide. Search it, browse by category, or open it contextually: press F1 to read about the window you are focused on. The question-mark button in a window\'s title bar opens a Guide associate for that window — the same Guide, in a chat of its own, already aware of the window it came from. The Take the tour button at the foot of the window replays a short tour of the desktop: its windows, the start menu and its System page, the dock and its pseudonyms, Configure, and how to ask the Guide.',
			'Each topic hands you to the Guide along the foot: pick a model and ask. It answers in a chat, and it can also act on the screen. "Show me pictures of George Michael" searches your records and opens the photo browser on them; "how far have I walked this month" and "when am I expected to be 180" are read from your own logs; "show Sarnia on a map" centres the travel map; "where was I on September 18th" reads the recorded place fixes; and "play Friends" plays every episode it matches, as a list. Asked "when did I last have a beer" or "when am I next free", it reads the oldest, newest and next matching appointment from your own records (across the appointments log and the other tables), and the time machine reads them the same way. It reports each step as it goes, and when the model returns its working beside the answer a small thinking control opens it.',
			'It writes only with your say-so: the Confirmation Requirement. Ask it for an appointment and it stages the proposal and shows you what it would save; nothing is written until you confirm. Ask it to change one you already have — "delay email test by 5 minutes", "make it last 10 minutes", "move it to tomorrow at 3pm" — and it stages that too, then applies it in place. "Stop email test", "stop it in 10 minutes" or "stop it at 5pm" stops the running one at once; "delete the email test one that\'s coming up" (or "the one from yesterday at 3:30pm", "the one a week from now") deletes one, staged for a yes. Say "undo that" and it puts your last change back. The Guide\'s associate - the small chat in the corner, the same Guide and so carrying every one of these powers - carries a Confirm tick beside its close button: untick it and the Guide saves what it proposes without asking. Its configure button also holds Staged: everything the Guide is holding for a yes shows there, each row with a thumbs-up to save it and a trash to throw it away, showing what it is, when, and - when you gave one - how long it lasts, and the chat you left is still there when you come back. It never sends or pays, and never deletes without a yes.',
			'It can give an appointment or a bill a recurrence in your own words too: "every third Saturday of the month", "every Tuesday for the next 6 weeks except on holidays", "the next five full moons", "my mom\'s next 5 birthdays", or "every anniversary of the birth of Abraham Lincoln until my mom is 80". The appointment you are starting is always the first occurrence. If a detail is missing - a birthday it does not have, or which Tuesday you meant - it opens an associate to ask, and the schedule finishes once you answer.',
			'A name can mean more than one thing - "music" the app or a club called Music, or two people called John Smith. When that happens the Guide asks which one you mean instead of picking for you, and the action then runs on the one you chose. You can name the one you mean more exactly: app:music or club:music fixes the kind, maple/john the house, and john#7f3a the short id shown beside the name. The same rule applies to names spoken to a watch or sent to another machine.',
			'You can also teach it your own word for a thing: say "call sleep zzz", "aka zzz for sleep", or "zzz means sleep", and the Guide remembers it; "forget zzz" drops it. In People, open a construct\'s row to see the other names it already answers to and add one; the x beside a chip forgets it. A word that already means something else is refused rather than made ambiguous. Aliases are kept with the house settings, so every machine understands them, and they work in the chat, on the watch and in commands sent to another machine.',
			'There can be several associates at once: the + in a panel\'s bar opens another, each with its own thread. Double-pressing the Assistant button shows the Agents list, where every associate and coding conversation is kept, named by its own words, and a press away from being re-opened or thrown away (see Agents). Its config menu also carries Speak the replies; ticked, each answer is spoken as well as written, through the voice set under Configure → Misc → Speech (Piper first — the same voice the watch\'s answers use).',
			'On the Internet window the question mark is replaced by the Guide\'s page-agent button: press it and the Guide is attached to that window\'s form — it can read the visible fields and fill them in for you, from what you discussed in the conversation, from your records (an appointment, a note, a message, a measure, a place) or from another field on the same form, and it can press the form\'s own buttons. Say "fill this in from what we talked about" or "put my phone number in there"; it reports each field it filled, and a green flash shows where the value landed. Closing the panel detaches it. Every other window keeps its question mark for help. It never fills a password field, and never presses Send, Pay or Delete.',
			'A thing the visibility rule hides is neither named nor opened here unless its padlock is open, so a hidden album stays out of sight until you unlock it.',
			'It can also tell another of your machines what to do, by name - "on the table, play Friends" - and that machine\'s own guide reads the command there, so it stays on that machine.',
			'You can speak instead of typing: if you press Send with the box empty, the guide starts listening, and Stop turns what you said into words in the box. It uses the same speech-to-text the watch uses. The Converse button turns it into a conversation: the mic opens again after each answer, and the clip ends itself once you stop talking - the pause is measured against the room\'s own noise, learned from the microphone exactly as the keyboard\'s dictation learns it, so a fan or a steady hiss does not keep the mic open - and each thing you say is the next turn of the same thread. Say or type "hey jawn" (or "jawn do") to start one, and "bye jawn" or the End button to stop; while it is on, the button is red. An on-device "hey jawn" listener will call the same switch when its model lands.',
			'Tick the Coding box in the composer (set its model under Configure → Plat → Coding) and the same box becomes the Coding agent. It can change JawnOS\'s own code, check it, and ship it - bumping the version, committing and pushing to GitHub, then restarting - so the program can mend itself from a plain request.',
			'Under each answer is a small good / not-good pair. Press the one that fits and the verdict is kept with the question and the reply, so the guide\'s answers can be judged over time.',
			'You can also teach it new verbs at runtime (Configure → Plat → Guide commands): each is a small JSON entry naming a primitive and its parameters, and because it is a setting it syncs, so every machine understands the same commands.'
		],
		steps => [
			'Press the page-agent button in the Internet window\'s title bar to attach the Guide to that page.',
			'Ask it to fill the form — "fill this in from what we talked about" — and check the green flash on each field it filled.',
			'Ask it to press the form\'s own save or open button when you want the change carried out; close the panel to detach it.'
		],
		related => [ 'hints', 'handbook', 'assistant' ]
	};
$topic{'live_docs'} = {
		title => 'Live docs', category => 'functions',
		templates => [ 'perl/help.pl', 'templates/apps/help.html.ep', 'public/js/manager/help.js' ],
		verified => '2026-10-30',
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
	};
$topic{'keyboard_shortcuts'} = {
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
	};
1;
