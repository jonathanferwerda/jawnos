	# ----------------------------------------------------------- functions
# Help registry part 8 of 9: appointments, records and the functions that cut across apps.
package help;

use strict;
our %topic;

$topic{'appointments'} = {
		'title' => 'Appointments', category => 'functions',
		templates => [ 'templates/appointment_wrapper.html.ep', 'templates/apps/edit_app.html.ep', 'templates/apps/app_file.html.ep' ],
		verified => '2026-10-31',
		summary => 'The one record everything else hangs from.',
		body => [
			'An appointment is the atom of JawnOS: a timestamped record with a type, a status, a duration and an app-specific body. Files, invoices, measurements, notes and mail are all appointments under the hood, which is why they can refer to one another.',
			'An appointment inherits visibility from the social constructs it belongs to. Its own app is one source, and every social construct named on the record is another - team, project, club, community, institution, government, corporation, place, vendor, event, account and the rest; each of those may itself belong to another construct. The lowest-numbered level wins, so a record filed under a private project is Private even when its app is Public. A Private appointment is hidden everywhere, never appears on the timeline, and can only be found in a private place with no Enemy present after a fingerprint on this screen.',
			'Opening one spawns a centre view that ties together everything that names it. Appointments can have alarms, recur, and be exported to a calendar. With Alarm on in an app\'s notification panel, that app\'s future appointments also add themselves to the Clock as alarms linked back to the appointment.',
			'The fields under the appointment carry a live reading of what will be saved: ago, duration, schedule and warranty, and now quantity as well - type 355ml and the line says 355 mL. The ago reading follows the clock while you edit it, so an absolute time counts down and a phrase like 5m ago resolves against the moment you press. A media button names its machine in the Media group: camera, video/audio/screen and scan each carry their own picker, remembered for that person at that screen, so a phone can take the picture while the scan runs on a computer. The video, audio and screen buttons are record presses: each writes a Record with that source, so it moves stock, stops and edits like any other Record, while a plain Record follows the app\'s own record setting and the same machine picker. A picture or a scan goes only to the machine you picked; if it has no such camera or feeder, nothing is captured somewhere else.',
			'Editing an appointment uses its own form, shaped by what the record is: a transaction keeps its money form, a start or record keeps its duration, quantity and unit, a picture or recording shows the file it holds, and a note keeps its notes. Only the fields the form shows are saved, so an edit never blanks a column it does not display. A name typed in the editor moves just that one record to that app, keeping its own values, and leaves the old app and its other records alone; Configure\'s name field is the whole-app relabel. The trash beside it deletes that record alone, with two presses. Cloning copies the app\'s settings, models and options - no history or stock. Editing a stock movement does not rewrite history: the difference is written as a move - taken from the shelf or returned to it - so the levels end up right and the ledger still tells the story. Renew takes the warranty typed in the app card and re-anchors every record of that app to it, so one correction reaches the whole history.',
			'A picture carries a toolbox: press the picture to open it. The palette in that toolbox edits the picture in place - type a number, then press rotate, crop, brightness, contrast, black level, blur or sharpen; press duplicate to copy the file, clear to go back, and save to keep the edit. On the phone the edit runs inside the JawnOS app itself, so no separate image program is needed.',
		],
		related => [ 'appointment_windows', 'clothesline', 'tasks', 'reminders' ]
	};
$topic{'reminders'} = {
		title => 'Reminders and alarms', category => 'functions',
		summary => 'Let an appointment come back and find you.',
		body => [
			'An appointment can be given an alarm, a reminder and a recurrence, so it announces itself when its time comes and returns on schedule.',
			'A recurrence is written as an interval and, optionally, a horizon: 1d for -2w repeats every day for two weeks, 2w for -3M every other week for three months, and 1M for -1y once a month for a year. A bare interval repeats until the app\'s warranty setting. The appointment you are starting is the first occurrence; the rest are written from it, so the first is never booked twice. Months step through the calendar, so February is 28 or 29 days and a monthly recurrence on the 31st keeps to the month\'s last day.',
			'A schedule can also be written in words: "every third Saturday of the month", "every Tuesday for the next 6 weeks except on holidays", "the next five full moons", "my mom\'s next 5 birthdays", or "every anniversary of the birth of Abraham Lincoln until my mom is 80". The Guide reads the words and writes the matching appointments, including the appointment you are starting as the first one. "Except on holidays" skips the common US/Canada holidays. If it needs a detail - a birthday it does not have, or which Tuesday you meant - it opens a Guide associate to ask, and then finishes the schedule.'
		],
		related => [ 'appointments', 'clothesline' ]
	};
$topic{'scanning'} = {
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
	};
$topic{'sealing_files'} = {
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
	};
$topic{'invoices_payments'} = {
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
	};
$topic{'moves_ledger'} = {
		title => 'The moves ledger', category => 'functions',
		summary => 'Stock and money folded into one signed list.',
		body => [
			'The warehouse keeps a journal of every stock movement and its reason. The moves ledger takes that journal and the money beside it and folds them into one signed list, so goods in and out and money in and out read as a single story.'
		],
		related => [ 'warehouse', 'invoices_payments', 'budget' ]
	};
$topic{'transactions'} = {
		title => 'Recording a transaction', category => 'functions', verified => '2026-11-02',
		summary => 'Enter what you spent or received from the record\'s own window.',
		templates => [ 'templates/apps/app_details.html.ep', 'templates/apps/transaction/expense.html.ep', 'templates/apps/transaction/income.html.ep', 'templates/apps/transaction/transfer.html.ep', 'templates/apps/transaction/inventory.html.ep', 'templates/apps/transaction/models.html.ep', 'templates/apps/app_transaction.html.ep', 'public/js/manager/transaction.js' ],
		body => [
			'A transaction is the money side of a record. Open the app\'s window and press Transaction (the coin beside Measures and Tasks) to open the form; it opens with the type, project and account already chosen from the app\'s own settings.',
			'The form reads from the top down. Vendor names who was paid, or who paid you. Item says what it was for; several things can be separated with commas, or each one put on its own line with Add item. Total is the figure on the receipt or the invoice; the amount and tax are worked out from it at the house tax rate. Typing Amount instead works the other way and fills the total.',
			'Each line carries its own quantity and unit, and Add item starts another line. The totals under the lines add every line together, and that is the figure saved. More details holds the inventory side of a line: manufacturer, model, state, an extra charge such as a deposit or tip, and the switches for whether the amount is for the whole line and whether the price includes tax.',
			'Choose Transfer from Type to move money between two of your own accounts. The account above the form is the From side; To picks where the money lands, and Amount is the figure that leaves one and arrives in the other. Both accounts get a leg of the same transfer, so the pair reads as one move, and To cannot be the same account as From.',
			'When the account is a cash account, Cash given takes the notes handed over and Change shows what came back. That pair is kept with the transaction for counting a drawer; the ledger still records only the total that left the account. Remember vendor and Remember item create or reuse an app for that name so its history gathers in one place; leave them clear to record the words on this transaction only.',
			'Save writes the transaction. Repeat last fills the form from the last transaction in the same app, which is the quickest way to enter a regular purchase; Cancel empties the form after a confirming press.'
		],
		steps => [
			'Open the app\'s window and press Transaction.',
			'Check the type, project and paid-from account, then name the vendor.',
			'For a transfer, pick Transfer, check the From account, choose To and enter the Amount.',
			'Enter the total from the receipt, or the amount and let the total follow.',
			'Put the items on the line; use Add item for more lines.',
			'For cash, enter what you handed over and check the change.',
			'Press Save.'
		],
		related => [ 'budget', 'warehouse', 'moves_ledger', 'market' ]
	};
$topic{'evaluation'} = {
		title => 'Evaluation', category => 'functions', app => 'evaluation', verified => '2026-11-03',
		summary => 'A model-backed appraisal of an app\'s activity.',
		body => [
			'Evaluation is an appraisal of any app\'s activity, run on demand or on a cadence. It reads what the app is and what it has been doing, weighs day, week, month and year together, and leaves a report at the foot of the app with a headline and links to everything it names.',
			'The report sits at the bottom of the app. Open its headline and the controls are inside the same accordion: the button that runs one now, how often it runs on its own, the days it runs, and the machine preferred for the work. In the app\'s Configure panel the controls sit above the report instead, so they can be set while the app is being configured.',
			'The days list has an All box. All runs every night; clear it to pick particular days, or to leave the list empty and stop the scheduled runs without changing the cadence. A daily or weekly cadence that was left blank used to mean All, and the app now makes that choice explicit instead of showing an empty list.',
			'Where an app\'s records are measurements (a weather feed, a currency quote, a meter reading), the report speaks only about the measured values and how they moved, not about how many readings there were: a reading is a value, not an occurrence. Speed from the GPS track is read only for an app whose own construct is an action; a start or stop in any other app still takes a GPS fix, but its speed is not a movement and is left out.',
			'It runs through a local model, so the appraisal never leaves your machine unless you point it elsewhere. Automatic runs happen on a server or a computer: an appraisal re-reads the whole history and then holds a model call, which is minutes of one core on a handheld, so a phone or tablet never starts one by itself. Any machine still runs one when you press Evaluate. The cadence and days are house-wide, so setting them anywhere updates the schedule; a phone or tablet leaves its own schedule empty. The house hands each report to one machine that can carry it, so a split house does not run the same appraisal twice, and when the server is named a model it cannot reach — a key that was never entered, or a local model that is not running — a ready computer takes the report instead. A house of phones and tablets alone therefore runs no automatic appraisals until a server or a computer joins.'
		],
		steps => [
			'Open the app you want appraised and scroll to the Evaluation at its foot.',
			'Open the report\'s headline to reach the controls, then run it now or set how often it runs on its own.',
			'Use the All box to run every night, or clear it and pick the days you want.',
			'Read the report where it sits; its links open everything it names.'
		],
		related => [ 'assistant', 'inventory', 'measures' ]
	};
$topic{'assistant'} = {
		title => 'Assistant', category => 'functions',
		summary => 'Chat and image generation, plus speech.',
		body => [
			'Assistant is the AI surface: chat and image generation, with speech synthesis and transcription alongside. Like Evaluation, it prefers a local model so your data stays put unless you point it elsewhere.',
			'Which model each assistant uses, and the keys that reach them, are set under Configure → Plat. Besides the local Ollama and Cloudflare Workers AI, that list now reaches OpenAI, Anthropic (Claude), Google (Gemini), xAI (Grok), DeepSeek, Mistral, Groq and OpenRouter.',
			'When JawnOS speaks aloud it uses the voice set under Configure → Misc → Speech: a neural Piper voice, or an eSpeak fallback. Speech plays on the machine running that device\'s jawn.'
		],
		related => [ 'evaluation', 'help_app', 'platform' ]
	};
$topic{'agents'} = {
		title => 'Agents (associates and coding)', category => 'functions',
		templates => [ 'public/js/manager/agents.js' ],
		verified => '2026-11-02',
		summary => 'Every Guide associate and Coding agent conversation, named and kept.',
		body => [
			'Double-press the Assistant button — the taskbar pin, the start menu\'s icon, or an associate\'s own corner icon — and the Agents list opens against the button it was pressed on: beneath it, or just above when there is no room below — or wherever you last left it, if you have dragged it. A double-press shows the list only — the chat panel itself waits for a single press. The list holds every conversation the Guide\'s associate and the Coding agent have had, newest first; a row whose panel is on screen says open, and the rest are history, re-opened with what was said replayed into them when pressed. The panels you left open come back after a page reload, and a coding run keeps going in the background while its panel is away. A panel is moved by its header, which wears the keyboard\'s grip - an open hand at rest, a closed one while dragging - and it reopens where you left it.',
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
	};
$topic{'platform'} = {
		title => 'Platform (AI providers)', category => 'functions',
		templates => [ 'templates/configure/plat_setting_list.html.ep' ],
		summary => 'Choose the model each assistant uses, add provider keys, and teach the Guide runtime commands.',
		verified => '2026-11-03',
		body => [
			'Configure → Plat gathers every AI choice in one place: which model each assistant uses, and the key or account each provider needs. On this machine {{live:models}} assistant roles have a model set, and the local Ollama is {{live:ollama}}.',
			'Providers include the local Ollama, Cloudflare Workers AI, OpenAI, Anthropic (Claude), Google (Gemini), xAI (Grok), DeepSeek, Mistral, Groq and OpenRouter. A model is addressed as provider:model — a bare name goes to Ollama, and @cf/… to Cloudflare.',
			'Other machines\' own Ollama models are offered too, each listed under the machine that runs it (Ollama · that machine). Their model lists are cached in the background, so Plat opens without waiting on the network; picking one runs the call on that machine.',
			'Google Veo is offered as a Video-generation model: it runs the job on Google\'s side and the tree polls it until the video is ready.',
			'Thinking is set per agent, beside its model, and shown for the language agents — the Help guide, Evaluation, Vision, the Pen and Coding — when the chosen model can reason; Image generation never carries one. A model that does not reason is not offered the choice (the families that do: the o-series, GPT-5, Claude 3.7/4, Gemini 2.5+, Grok 3/4, DeepSeek R1/v4/flash, Magistral, Qwen3 and the like). The level reaches each agent\'s own model calls, and a level a model does not understand is dropped and the call retried without it. A machine can also switch an agent\'s thinking off outright — see Thinking (AI agents) under Configure → Misc — and then that agent carries no level here at all, whatever is chosen for it.',
			'Image, Audio and Video generation are their own agents, each holding the model that produces that kind of file; a prompt Pen (or a Guide associate) describes is filed by the matching one, with a “Generating … with …” note while it runs. Transcription (speech in) is its own agent too: it can be set to whisper.cpp on this machine — the model is kept warm by a local whisper server, so a clip is transcribed without a network round trip — or to a cloud model, which is what a machine without whisper.cpp uses.',
			'Every agent also carries a Fallback choice beside its model — the same list minus the primary. When the primary errors (an outage), the call steps down to the fallback instead of failing; the transcription agent adds whisper.cpp after that, and when whisper.cpp is the primary the cloud model is its fallback.',
			'Secret keys are stored encrypted and are never shown back: a key that is set reads “••• set”, and typing a new value replaces it.',
			'Beside each provider that is set up sits the money left on its account, where the provider reports one: OpenRouter and DeepSeek publish a figure, and the rest read “no balance API”. The reading is kept fresh in the background (off the page), so opening Plat never waits on a provider. The figure carries a currency dropdown: the house currency is the default, the provider\'s own currency is the second choice, and the rest of the currencies with a loaded rate follow.',
			'Guide commands (runtime) is where you teach the Guide new verbs without a code change. Each is a JSON entry naming a primitive — say, open_app, set_setting, run_command, toggle, stage, find or play_music — and its parameters. The list is a setting, so it syncs to every machine and they all learn the verb.',
			'Self-healing is the error watch: tick Watch errors and, with a Coding model set, every new error is caught and listed in the IDE\'s coding panel with a fix the Coding agent has proposed — the tree\'s own log (the live console stream the master serves (seeded from the supervisor\'s log after a master restart), plus manager.log) and the browser: every page reports its fatal JavaScript errors (an uncaught exception, an unhandled promise rejection, a script or stylesheet that would not load), which is what JS means on a row\'s line. The fix waits there: Apply writes it, checks it compiles, bumps the version, commits and pushes, and the panel\'s restart link puts it live. Nothing is written until Apply — unless Apply automatically is ticked, when each proposal is written, checked (perl -c, rolled back if it fails) and shipped at once, like the Guide associate\'s Confirm tick; a file that has uncommitted work stands down and waits for you, and Tokens/day caps what the day may spend. Tick Watch the Guide and the Guide\'s own conversations are read the same way: a turn that went nowhere — a thing not found, a command that could not run, a closing line that says so — is staged for the Coding agent to adjust the Guide\'s training itself, its rules and its verbs. Fixed so far, under the tick, is the record of what has shipped: press review to read each fixed error, with the model that fixed it and the version it went out as. A tab follows a shipped fix on its own: a stylesheet or template change lands in place (the open windows re-render), while a change to the manager\'s scripts or its shell asks once — a small press-to-update note in the corner, or a silent reload when the tab is hidden; a conversation left in a coding agent survives it. The watch is one per house, not one per machine: a stable hash over the machines that have a model configured ranks them and the first takes each error, and only that machine pays to propose the fix, so two machines never repair the same thing; a fix already proposed is left alone while a person decides, and if that machine goes quiet the job hands on to the next rather than waiting. The day\'s token budget is one pot for the whole house, each machine\'s spend summed, so Tokens/day is the house\'s ceiling rather than one per machine. A machine named by hand wins over the ledger.',
			'Watch records is the same watch pointed at the database. Tick it and every two hours the appointments table is audited for the fault that corrupts the numbers: a session one stop press closed along with others, the same row written twice, and an open session run far past the app\'s length. Each finding is staged under Self-healing with the rows it would tombstone or repair. Nothing is written until Apply; the window sets how far back it looks (0 is all time). Apply records automatically writes only exact duplicates — the same event written twice on the mesh, which is provably one event — while a sweep or a long-open session always waits for you, because a real appointment can be surprisingly long (a home stay, a months-long ailment) and a fixed rule can never know that. Any finding carries an Ask box: put it to the Coding agent and it reads the rows and says what it makes of them, whether the repair is safe, and whether the honest answer is to leave it alone; Leave this app alone silences the audit for an app you know runs long.',
		],
		steps => [
			'Open Configure and press Plat.',
			'Under Agent models, pick the model each assistant should use — the Help guide, Evaluation, Vision, Image generation, Audio generation, Video generation, the Pen, Coding and Transcription — and, beside each, a Fallback model (the same list minus the primary) tried when the primary is down. Each list only offers models that fit the role, so a text assistant is not offered a vision-only model and the Vision role is not offered a plain text one; a model already chosen stays listed even if it does not fit. Each choice is marked free or paid. A language agent shows a Thinking choice beside its model when that model can reason — none, low, high or max — how long it may reason before it answers (the generation and transcription roles have none); a model that ignores the hint answers as it always did. A provider that runs out of credit has its paid models hidden and its chats step down to a free model until the account is topped up.',
			'Under Provider access, paste the key or account for each provider you want to reach. A field that already shows “••• set” is kept unless you type a new value.',
			'Every machine reads this one panel, so a model chosen here is the model every machine uses. To have one machine (the desk, say) answer without reasoning while the rest keep it, turn that agent off for that machine under Configure → Misc → Thinking (AI agents): the choice here stays as it is, and that machine simply stops asking for it.',
			'The balance beside a set-up provider is what is left on that account, where the provider reports it.',
			'Under Guide commands, add a verb as a JSON entry and press Save — every machine picks it up.',
			'Under Self-healing, tick Watch errors to have the Coding agent watch the tree\'s log and stage a fix for each new error; tick Watch the Guide and it reads the Guide\'s conversations for turns that did not land. Review and apply them from the fixes list in the IDE\'s coding panel, or tick Apply automatically to have each one written, checked and shipped on its own. Fixed so far, under the tick, shows the errors already fixed and shipped. Tick Watch records and the appointments table is audited on the same principle: review a finding, Ask the Coding agent about it before you decide, or Apply it — Leave this app alone clears an app you know runs long.',
		],
		related => [ 'configure', 'assistant', 'help_app' ]
	};
$topic{'backup'} = {
		title => 'Backup and restore', category => 'functions',
		summary => 'Take a copy, and put it back.',
		body => [
			'Backup packs the database and the media into an archive that can be moved or stored elsewhere; restore puts one back. A "Backup now" button lives in the start menu, and the same machinery carries data between machines.'
		],
		related => [ 'devices_and_mesh', 'folders' ]
	};
$topic{'tickets'} = {
		title => 'Passes and logging in', category => 'functions',
		summary => 'A single-use link that is the credential.',
		body => [
			'A pass is a single-use link that carries its own secret. Opening it mints a session and lands you on the desktop (or the store, or the homepage, depending on the pass\'s privilege).',
			'Because the link is the credential, treat it like a password and revoke it from the Box Office when you are done. It is also how the desktop and Android apps log themselves in.'
		],
		related => [ 'box_office', 'security' ]
	};
$topic{'devices_and_mesh'} = {
		title => 'Machines, the mesh and sync', category => 'functions',
		summary => 'Several machines that keep each other in step.',
		body => [
			'JawnOS is built to run on more than one machine — a laptop, a phone, a tablet, a server — and to keep them in step without a central authority. Code, app builds and data all move the same way: whoever has the newest is the authority.',
			'Machines reach each other across whatever network they are on, including from behind a router, and every machine can be logged into from another via a pass.',
			'Two machines on the same network find each other without waiting for the tunnel. Every machine broadcasts a small signed presence notice on its LAN every few seconds and, when it joins a network, sweeps the subnet by unicast too (some phones drop broadcast); a machine that hears a known peer updates that peer\'s row with the LAN address it is on now, replies once by unicast, and starts the sync at once, so a laptop and phone that meet on the house wifi, a friend\'s wifi or a hotspot resume the mesh within seconds. The notice is signed with the machine\'s peer key and only refreshes a peer already in the mesh, so it cannot introduce a stranger. The phone and tablet use this path because Termux has no mDNS responder; the avahi advertisement still serves the embedded devices. The Dev panel follows the same notices: this machine\'s network card, a peer\'s LAN address and the build shown beside its name refresh in place, without pressing Scan.',
			'A machine that moves — a phone waking on a different wifi, a laptop joining a friend\'s network — tells the house its current addresses: at boot, when its interfaces change, and on each scheduled wake. A machine that can reach the house server sends the signed notice itself; one that cannot (the phone whose tailnet is down, a laptop on a network that cannot see the cloud) hands the same signed notice to a peer that can, and the peer relays it. The server keeps that address book, tells the other machines when it changes, and answers a machine that asks where a peer is now. A stored name that points at an unreachable tailnet address is therefore repaired from the address book instead of waiting out a connection timeout; a peer on the same LAN is always reached directly.',
			'One machine can also tell another what to do: name it and say the task — "on the table, play Friends" — and the command is read by that machine\'s own guide there, so it runs on that machine without the words leaving the mesh. The Assistant\'s remote_control panel has a box for the same thing, and its Go button opens the named machine\'s own Manager in a window of the JawnOS app, asking for the same fingerprint or another device as the Dev panel\'s Go (which does the same). A plain browser is told to open it in the app. A single click on the panel\'s dock icon opens it; drag the bar across its top to move it, and it stops at the clothesline. The machine list names each peer once, with Me first. When a peer is selected, the panel also shows its public IP where the house knows it — the address a hub saw it dial from, or an interface address of a machine that sits directly on the internet — and clicking it copies the address. A machine behind a router that no hub has seen dial in shows none.',
			'The remote_control panel can also lend this machine\'s keyboard and mouse to the named machine. Switch Remote keyboard and mouse on, say which side that screen sits on (left, right, top or bottom), then move the pointer into that edge; the first click or key captures the pointer and the other screen behaves like the monitor on that side. Keys and clicks go there until the pointer comes back to the same edge or you press Escape, and the local screen takes over again at once. Take control does the same without crossing. While the hold is open, Ctrl+C on the far screen brings its selected text back to this machine\'s clipboard, and Ctrl+V pastes this machine\'s text there (when the browser allows clipboard access; otherwise the Clipboard box under the button holds what was copied). On the other machine the input is injected with xdotool on X11, or dotool, wtype or ydotool on Wayland, and that machine must grant this house Trusted access (Devices -> Privilege). A peer with no injection backend answers with that, rather than appearing to work.',
			'The Me view of the remote_control panel also carries a VPN button and the list of machines that offer a tailnet exit node — the house server is the usual one, whether or not it is a row in the machine list above. Pick a node and press VPN to route this device\'s web traffic through it, so websites see this device at that machine\'s address; press it again to come back. Only an online machine that advertises an exit node is listed, and the local network stays direct, so the house\'s own addresses still answer. If the tailnet is on and external sites stop resolving while the house still answers, the fault is the tailnet\'s DNS proxy, not the tunnel: Headscale must carry upstream nameservers (1.1.1.1 and 8.8.8.8 are set here), otherwise every external lookup waits on a proxy with nowhere to forward and reads as “no internet”. The same view names this machine\'s own public address, which is the quickest check that the VPN is really carrying the traffic: while an exit node is in force it shows that machine\'s address, and without one it shows this device\'s ISP address. Configure -> Plat -> DNS chooses the outside service, and None stops the lookup and hides the line on every machine and on Me, except a server whose own interface carries a public address — a server behind NAT has none to show.',
			'On the desktop the dashboard also carries Start VPN and Stop VPN, which bring the machine\'s own tailnet up or down. Both the desktop and the Android app watch the underlying network: when Wi-Fi or cellular changes, a running tailnet is stopped and started again so the client binds the new route, while a tailnet the person stopped stays stopped.',
			'A machine does not need the tailnet to open its own manager. The Dev panel discovers the gateway and lists it as a Router card, with the last time it answered; a card for a network the machine has left stays for a day, while the current gateway stays as long as it is up. The router\'s DNS gives each machine its own name at its own address (and local.<house domain> at 127.0.0.1); on a laptop the hosts file can do the same. So the view is opened at the machine\'s own domain, resolves to the loopback or to the machine\'s own LAN address, keeps the wildcard certificate, and works with the VPN off. The tailnet is then only for reaching other machines.',
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
	};
1;
