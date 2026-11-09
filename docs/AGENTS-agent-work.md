# Agent work (moved from AGENTS.md)

Read this for a long or risky task: context size, payloads, delegation, checkpoints.

## Crash-resilient agent work

The Zed panel retains every byte it is shown and can grow the editor into the GBs; zram + earlyoom turn
that into a slow patch instead of a frozen machine. Protect the work, not the chat:

- **One thread = one task**, closed when done; fresh thread when the task changes or an approach fails —
  long history degrades answers as well as memory. Keep output small (`grep`/`sed -n`, `read_file`
  ranges, `--quiet`, `cmd > /tmp/x.log 2>&1; tail -40`), never a whole 1 MB file for a pointed question.
- **Split large files — a `413 payload too large` means the request was the problem, not the tool.**
  Never retry it unchanged. Read source/JSON/logs by line range or with `sed -n`; read a log by its
  tail. Never pull a raw screenshot, PDF, audio or video into context: downscale first
  (`magick in.png -resize 1024x1024\> -quality 82 /tmp/small.webp` — aim under ~150 KB), then look at the
  small one. **Write screenshots as WebP, not PNG:** a WebP capture is typically 3–10× smaller than the
  same PNG and the image reader accepts it, so it is far less likely to hit the payload limit; prefer
  `.webp` for every `.shots` capture you create. A capture PNG is 0.2–2.7 MB and its base64 is larger
  still; that is what a 413 is made of. For a
  large write, generate it with a script (`write_file`/heredoc in sections), not by echoing the whole
  body through the model. If an HTTP upload answers 413, send one file per request or in parts. Compress,
  crop and thumbnail as its own step (see `scripts/gallery/`), then inspect the contact sheet.
- **Delegate** builds, test suites, `logcat` and repo-wide searches to a sub-agent returning finding +
  `file:line` + reproduce command, no raw logs; keep edits in the main thread so the diff is visible.
- **Checkpoint** each step in `.shots/AGENT-CHECKPOINT.md` (goal, done + paths, next action, last commit)
  and **commit** it (`git add -p`, `v<version> - <summary>`). After a crash start a *fresh* thread that
  reads it first; delete it when the task is done. While it is open the lander keeps your
  worktree and the `.shots/` beside it across a landing, so a task that lands a first piece and
  goes on does not lose its screenshots or probes.
- **The checkpoint file may be shared.** More than one agent can be writing `.shots/AGENT-CHECKPOINT.md`
  at the same time, so **identify yourself** — put an agent id/model and a timestamp on your section,
  re-read before you write, and only replace your own entry. Never overwrite another agent's section or
  delete the file while someone else's work is still in it; if you are unsure who owns a line, leave it.
- **Leave the tool, not the ticket.** A probe you had to build in `.shots/` and would want again belongs
  in `scripts/tools/`, with a row in its `README.md`. Make it argument-driven (a PID, host, port, MAC or
  file the call provides), keep the default read-only, and leave out anything that identifies the house:
  a ticket URL, token, cookie, phone number, MAC, signatorial, person's path, fixture row or timestamp.
  `.shots/` is gitignored scratch — the shelf is what another machine inherits. `perl scripts/where.pl
  --tools` lists it and `perl scripts/where.pl cpuspy` prints a tool's catalog row, so write the row for
  the next agent, not for yourself.

## Token economy

The bill is generated text, not stored context. **Ask for the hunk**, and for the range
(`where.pl --outline`, `--body`) rather than the file; a change is a patch, not a whole-file rewrite.
**Keep the prefix stable**
(caching only pays when the top of the context does not move); **one thread plus narrow sub-agents**
returning `file:line`, never raw logs; **cap the loop** — plan → approve → execute, paste the failing
lines, `sed -n` a range instead of reading the file. **Ask the locator, not the map:**
`perl scripts/where.pl <name>`; `--tech <app>` prints the technical brief; `--tools` lists the
shareable probes. The four local agents
(Guide, Coding, Evaluation, Pen), the creative apps and how a new app is added: `docs/AGENTS-agents.md`.
