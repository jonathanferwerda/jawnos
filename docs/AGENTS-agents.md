# The local agents and the creative apps

Moved out of `AGENTS.md` (a per-task reference, not an every-request map).

## Token economy

The bill is generated text, not stored context. Four rules that move it:

- **Ask for the hunk.** "Return only the changed lines; do not restate code you did not change."
  Whole-file rewrites are the most expensive habit available.
- **Keep the prefix stable.** Automatic prefix caching only pays when the top of the context does not
  move; editing early messages, reordering files, or re-pasting the same file invalidates it.
- **Concurrency multiplies context.** Each parallel agent re-sends the same repo context and builds its
  own cache. One main thread plus narrow sub-agents returning `file:line` beats three broad agents.
- **Cap the loop.** Plan → approve → execute; paste the failing lines instead of re-running a suite;
  `sed -n` a range instead of reading the file.
- **Ask the locator, not the map.** `perl scripts/where.pl <name>` answers "where is this" in
  one line — a Manager helper, a domain sub, a route action or path, a help topic, or a file (which
  reports the topics covering it); `--topics` lists the help registry and `--tech <name>` prints the
  tier-2 technical brief. Reading `Index.pm` or grepping nine parts costs ~20 KB for the same answer.

**Agents (local, optional, and all on the same records).** Four, plus the generators Pen can call:

- **Guide** — `help.pl`, `POST /manager/help/ask`, `subs::evaluation_model_call`. Teaches the program
  and acts: opens apps, starts music, answers what happened, is happening, or will happen. Its memory
  is the Handbook: goals, plans and journals are records like everything else.
- **Coding** — `public/js/manager/coding.js`, `templates/apps/coding_chat.html.ep`. Edits the repo,
  compiles, bumps/commits/pushes, restarts. Doubles as the **error watch** (Configure → Plat →
  Self-healing): reads `~/pty.log`, `manager.log` and browser fatals, stages a proposed fix, and only
  writes on Apply (or auto-Apply). One watch per house; the first machine with a model takes each error.
- **Evaluation** — server-rendered rather than a client app: `templates/apps/evaluation*.ep` (the
  report block at an appointment's foot and in Configure → Misc), with `subs::evaluation_report_for`
  (`Domain/Budget2.pm`) and `subs::evaluation_model_call*` (`Domain/Ai2.pm`). Reads measures and
  the relationships between events, reports correlations and predictions; also feeds ghost appointments.
- **Pen** — `public/js/manager/pen.js` and `subs::pen_message` (`Domain/Sent.pm`); there is **no
  `pen.pl`**. General chat with memory that routes to audio, video and image generation
  (`ai_extract_generation_action`), then files the output into Studio, Marker or Music. It is the
  mailbox's assistant section as an app of its own: `pen.js` fetches `# GET /manager/pen`
  (`Controller/manager_misc10.pm`), which renders the mailbox scoped to the pen section.

**Creative apps.** Studio (`public/js/manager/studio.js`, `templates/studio`) is multitrack,
multi-input recording. Marker (`public/js/manager/marker.js`) is multilayer paint with snapshots and
playback, exports image/video, and can be dragged over a video or image as an overlay. Music
(`Music.pl`, `templates/apps/music`) plays audio and video with subtitles and streams single audio
channels, or the video, to remote machines.

**New apps.** There is no app generator. The start menu is built from the app registry (`help.pl` notes
that adding an app cannot drop it from the sheet), so the Coding agent adds one the way a person would:
a template, a route, a registry entry. Prompt it with the behaviour you want — "a new app in the start
menu that finds Bluetooth devices and adds them to Embedded so I can bind their controls to start and
stop" — and it writes, checks, bumps, and ships the code.
