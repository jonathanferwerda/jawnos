# Concurrent agents

More than one agent works this tree at a time. The map cannot hold this protocol — it is already at
its size budget — so it lives here: the why, and the edges the short pointer in `AGENTS.md` cannot
carry.

## The three things that are global

A worktree isolates the *working tree*: its own index, its own `HEAD`, its own `.shots/` (so
checkpoints stop colliding) and no `database/` of its own. It does **not** isolate the three things
every landing touches:

- **`VERSION`** is one counter. Two unlocked read-modify-writes read the same number and write the
  same next one: a lost update, two commits claiming one version. `scripts/version_bump.pl` takes a
  lock in the git common dir for exactly this reason, and `agent_land.pl` re-bumps on the rebased tip
  so the number belongs to the push, not to the branch.
- **The suite** is this box's cores. `scripts/run_tests.pl` defaults to `min(8, cores)`; ten agents
  doing that at once is 80 processes on 8 cores. The lander holds its own lock across the suite, so
  only one lands at a time, and it defaults to `--jobs 2`.
- **The master** is one process on one checkout. `scripts/restart.pl` is a global mutex with a
  150-second wait for a verdict; ten agents asking at once queue, time out and report failures for
  work that was fine. Only the lander restarts.

## Which landing method

Three paths, and the condition picks one:

- **Queue it** (`perl scripts/land_enqueue.pl`, the default when more than one agent is working):
  commit the branch, run the script, and let the coordinator land it. You do not push or restart,
  and **you do not delete the worktree**. `perl scripts/land_status.pl --branch <branch>` is the
  verdict; when it says landed, the branch is on the trunk and the worktree may go (or wait for
  `worktree_gc`). A refused ticket keeps the worktree: fix, re-enqueue, and never run
  `agent_land.pl` on the same branch.
- **Land it yourself** (`perl ~/jawnos/scripts/agent_land.pl`, from the worktree root): one agent at
  the gate, which the lock makes safe. It bumps `VERSION`, runs the suite once, pushes, restarts and
  removes the worktree. `--keep` is only for work that continues (an open checkpoint) or a handoff;
  a refusal keeps the worktree anyway.
- **Hand-land as the owner** (the old "Alone" path): only when you are the **sole agent on this box
  and the primary checkout is yours** — no other agent is working and no queue is draining. Then
  `perl scripts/version_bump.pl` → commit with `JAWNOS_ALLOW_PRIMARY_COMMIT=1` → `git push` →
  `perl scripts/restart.pl`. This is the only hand push/restart; with another agent active it is the
  collision the lander exists to prevent.

## The commit identity

Every commit in this tree is authored **and** committed as
`Jonathan Ferwerda <jonathan.ferwerda@outlook.com>`. GitHub, the release feeds and every mirror speak
as that identity; a commit carrying an agent's own name puts a stranger on the project's history.

Two shapes have reached the trunk: an agent naming itself on the command line
(`git -c user.name=Zed -c user.email=zed@jawnos.local commit`) and a QA lane carrying a fixture
identity out of a test (`JawnOS test <test@jawnos.invalid>`). Both are refused by
`.githooks/pre-commit` before the commit exists: it compares the identity git resolved — from `-c`,
`--author`, or `GIT_AUTHOR_*`/`GIT_COMMITTER_*` — with the house identity and stops anything else.
The fix is a plain `git commit`: never pass `-c user.name`, `-c user.email` or `--author`. The
checkout's own config is the house identity; a fresh clone sets it once with
`git config user.name 'Jonathan Ferwerda'` and
`git config user.email 'jonathan.ferwerda@outlook.com'`.

The refusal names `JAWNOS_ALLOW_FOREIGN_COMMIT=1`, the escape for importing somebody else's patch
on purpose. It is not for an agent's own work. The rule is claimed only by the house tree (it needs
`AGENTS.md` and `scripts/agent_land.pl`), so the throwaway repos `t/` builds still commit as their
own fixtures.

## The gate also closes the corruption

Two failures have made agents spin after their work was done, and the gate now refuses
both instead of pushing out of a broken repo:

- **A bare repository.** `core.bare=true` stops every git command in the primary. The gate checks it
  before it starts and again after the suite, resets the flag, and refuses with the words "the suite
  left the repository bare". The corruption is named, not mistaken for a branch problem.
- **A trunk that moved during the suite.** The gate holds the lock, so no other agent can be landing;
  a move is a fixture commit from a test. If the new commit carries a fixture identity
  (`@example.invalid`, `@example.test`, `@jawnos.invalid`), the gate puts the trunk back and refuses.
  Anything else is left alone and reported — a human commit is never reverted.

Both are refusals: nothing is pushed, and the agent is told to report it rather than retry.

## Why the lander moves the primary checkout

`scripts/restart.pl` restarts whatever the master is already running. The primary checkout advances
on its own only through the code-sync job (`perl/President.pl`, Slow pool), so push-then-restart alone
restarts the *previous* commit and "always newest" becomes "newest within the hour". `agent_land.pl`
therefore fast-forwards the primary checkout (the first entry in `git worktree list --porcelain`)
before it restarts, and refuses the landing up front when that checkout is dirty — a landing that
cannot reach the server should not be pushed as though it did.

## The gate, step by step

`perl ~/jawnos/scripts/agent_land.pl`, run **from the worktree root**, lands it. Run the primary
checkout's copy, not the worktree's: a worktree holds its own checkout of the lander, so an agent whose
worktree is behind runs an older lander — the one before backup branches were deleted, or before the
bare-repo guard. The path is only how the script is found; it still works on the checkout you are in.

1. Refuse a dirty worktree, or a dirty primary checkout — both are someone's unswept work.
2. **Back the branch up to `origin/<branch>`** (`--force-with-lease`, `--no-verify`). This needs no
   lock and collides with nobody, so a queue at the gate can never cost the work.
3. Take `jawnos-land.lock` in the git common dir; wait `--wait` seconds (default **300**), then exit 4
   naming the holder — with the branch already safe on origin, a timeout is a pause, not a loss.
4. `git fetch origin`, then rebase onto `origin/main`. A `VERSION`-only conflict is taken from the
   trunk (the bump below moves it past trunk's number); any other conflict aborts the rebase and
   names the file.
5. Run the suite **once** (`--jobs 2` by default) and export `JAWNOS_SUITE_ALREADY_RUN=1`
   for the push, so the pre-push hook does not run it a second time. A failure refuses the landing;
   nothing is pushed.
6. Bump `VERSION`, rewrite the tip subject to `v<new> - <summary>` (an existing prefix is replaced,
   never stacked), amend. The body is preserved.
7. `git push origin HEAD:refs/heads/main` — fast-forward only, and the lock is why it stays one. The
   hook still runs its parse guard and help audit; only the duplicate suite is skipped.
8. Delete the backup branch on origin. Its work is on the trunk now, and a branch left behind is a
   "Compare & pull request" banner in GitHub for every finished task.
9. Fast-forward the primary checkout, then `scripts/restart.pl --reason "v<new> - <summary>"`.
10. **Remove the worktree and its merged branch** — the default, not a flag. A landed worktree is
    170 MB of files that exist on the trunk and in the primary checkout, and git never deletes one.
    `--keep` spares it; without it a finished task waits for the next `worktree_gc.pl` run, for
    something already over.

Exit codes: **0** landed — **1** refused, nothing pushed — **2** bad usage — **4** another landing held
the lock past `--wait` — **5** pushed, but the dev server is not on it (primary checkout dirty or
diverged, or the restart was refused). Exit 5 means the work is safe on `origin`; fix the checkout and
restart.

## A refusal ends the attempt

The lander is the last step, not a loop. When it exits non-zero, the run is over: report the refusal
with its reason and stop. Do not re-run it hoping the lock or a flaky test has cleared, and do not fall
back to `git push` and `restart.pl` by hand — that is how two agents resume sweeping each other's work.
A landing takes a minute or two (rebase, one suite, push, restart); it is not hung, and its progress
lines go to stderr, so a wrapper that pipes stdout shows nothing until it ends.

**What "done" looks like after a refusal:** the worktree is still there (the lander removes it only
after the push and the restart), the branch is on `origin/<branch>`, and the reason and the next
action belong in `.shots/AGENT-CHECKPOINT.md`. Report that and stop. "Done" for the task is "refused
and reported", not "landed"; nothing else is owed, and the next attempt is a deliberate one.

## The landing queue and the train

The lander is still the hand landing, but a busy checkout runs a queue.
`perl scripts/land_enqueue.pl` from the worktree validates the branch, backs it up to origin and
writes a ticket in `<git-common-dir>/land-queue/`. With `--authority <host>` the ticket is written
by the authority's copy over ssh instead, so a worker box never owns a second queue. The coordinator
(`scripts/land_coordinator.pl`) drains the queue in **waves** on the box that owns the primary
checkout and the master — the authority:

- **One suite per wave.** It rebases the wave's branches onto a growing tip in a scratch worktree,
  drops each branch's `VERSION` hunk, bumps once per branch, regenerates the generated indexes at the
  tip, runs `run_tests.pl` once on the integrated tree, pushes that tree as one fast-forward and
  restarts once. The worktrees themselves are left to `worktree_gc`; a landed branch is recognized
  by the subject a rebase preserves.
- **One hot-file branch per wave.** The name maps (`Manager/Index.pm`, `Declarations.pm`,
  `Domain/Loader.pm`, the route rows) and the help/language tables are the conflict class; a second
  hot ticket waits for the next wave.
- **A red wave is split, not retried forever.** The suite is retried once; if it is still red, the
  wave becomes single-ticket waves. The bad branch is refused with its failing lines and the rest
  land.
- **The queue is a snapshot.** Re-enqueueing the same branch updates its sha and keeps its place.
  `perl scripts/land_status.pl` gives the position and verdict; `--stats` prints measured waits and
  suite times.
- **The ticket owns your worktree.** The coordinator lands from origin and never needs your
  directory; the worktree stays until the ticket is landed (then `worktree_gc` may sweep it) or
  refused (then it stays for the fix). Do not delete it before the verdict.
- **A dirty primary blocks this box's apply, not the trunk.** The coordinator pushes the green train,
  records `apply blocked`, and the next wave retries the fast-forward and restart.
- **One coordinator per trunk.** Two boxes running it would race the push. The authority is the box
  with the suite and the primary. A worker pushes its branch and runs
  `perl scripts/land_enqueue.pl --authority <host>`; that runs the authority's copy over ssh (port
  8022, `BatchMode`, root `$HOME/jawnos`, `--authority-root` to move it), and
  `perl scripts/land_status.pl --authority <host>` reads the queue back. A same-box authority uses
  the primary's copy directly, no sshd. The authority checks the commit's identity because the
  worker's pre-commit hook never ran there.
- **A remote ticket carries no worktree path.** The worker's own `worktree_gc` sweeps the branch by
  the subject a rebase preserves; the authority only needs the branch on origin.
- **A worker box follows the trunk through the existing code sync.** A dedicated apply timer on a
  worker is not built; a box that runs the app waits for the sync, or lands by hand.
- The units are `scripts/systemd/jawnos-land-coordinator.{service,timer}`; install them on the
  authority. Do not make it a manager utility job: it must land the fix when the tree is broken.

## Hot files

These are edited by nearly every task, so a landing that touches one should be small and land first —
rebase immediately before running the gate:

- `lib/JawnOS/Manager/Index.pm`, `lib/JawnOS/Manager/Declarations.pm`
- `lib/JawnOS/Domain/Loader.pm`, `lib/JawnOS/Routes/`
- `perl/language.pl`, `perl/help/topics_*`
- shared `.ep` partials, and the `t/54` / `t/58` / `t/91` / `t/11` / `t/99` pins

## In a worktree

- `git worktree add .worktrees/<task> -b agent/<task> origin/main` **before your first edit**, and
  work only there. The primary checkout is read-only for agents: a source write left in it makes
  `agent_land.pl` refuse every landing, not just yours. Generated artifacts that scripts stage in
  place — `releases/`, firmware `build/`, `.shots/` — are gitignored and are not source writes.
- A worktree is a **checkout, not a clone**: it shares the one object store (`.git` stays one copy)
  and adds a full checkout of the tracked files — about 170 MB here, with the firmware fonts and
  images. History is never duplicated.
- **A landed worktree is deleted by the lander.** Removal is the default: the branch's work is on the
  trunk and on origin, and nothing else ever deletes the directory. `--keep` spares it and prints
  the command that would drop it. **An open `.shots/AGENT-CHECKPOINT.md` spares it too** — that file
  is the repo's own "this task is not over" marker, and a thread can land a first piece and go on
  from the same worktree, so the lander keeps the worktree and its `.shots/` (shots, probes, notes)
  while it is open; delete it when the task is done, or pass `--remove` to force the removal.
  Everything else in `.shots/` is scratch by design — a probe you want after the landing belongs in
  `scripts/tools/`. Nothing archives it either: a screenshot of the pre-landing code is stale the
  moment the trunk moves, so a thread that carries on retakes what it needs, and the primary's
  `.shots/` stays a place agents curate rather than a dump of every finished task's scratch.
  (The lander removes it from the primary checkout, so it works even while your shell sits inside.)
  A **refused** landing keeps the worktree too: removal happens only after the push and the restart,
  so the files and the checkpoint are still there to look at and fix.
  `scripts/worktree_gc.pl` is the sweep for worktrees whose agent died: report-only by default,
  `--apply` to act, and it removes a worktree only when its branch is an ancestor of `origin/main`,
  its tree is clean, and no process has its cwd in it. A landed one goes at the first sweep that
  sees it; `--older-than H` asks for a buffer. It is the
  `worktree_gc` utility job (daily pool, on by default), so a machine sweeps itself; run it by hand
  with `perl scripts/worktree_gc.pl --apply`. It reports anything unfinished as `wip` and keeps it:
  an unmerged branch or detached commit, a dirty tree, a waiting stash, an open
  `.shots/AGENT-CHECKPOINT.md`, or a process standing in the worktree. That is what makes it safe to
  run while someone is mid-task. It also deletes `origin/agent/*` backup branches whose work is on the
  trunk (`--remote-only` for just that), which is what keeps GitHub's branch list clean. A worktree
  whose directory is gone is reclaimed with `git worktree prune` (the sweep does that too).
- `config.json` is **not tracked** (it is gitignored) and `database/jawnos.db` is not in git, so a
  worktree starts with neither. You do not copy or build them by hand: `scripts/worktree_seed.pl`
  writes `config.json` from the tracked `config.json.example` and builds `database/jawnos.db` from
  `database/schema.sql`, and `scripts/run_tests.pl` runs it before every suite — so iterating and
  landing both have the files, and a step an agent forgot can no longer read as "the suite failed".
  Run it yourself (`perl scripts/worktree_seed.pl`) when something other than the suite boots the
  app. It writes only inside a linked worktree — never the primary's live config or database —
  replaces nothing already there, and writes nothing tracked, so the checkout cannot go dirty. The
  ports stay fixed (3000/3001/3001). Do not run a server from a worktree, and do not run
  server-binding tests in parallel with another agent.
- `perl/` and `lib/` are reached by cwd-relative `require`, so run commands from the worktree root.
- Land from here with `perl ~/jawnos/scripts/agent_land.pl`, the **primary checkout's** copy: a
  worktree's own copy can be behind. The gate refuses while the primary checkout has tracked changes,
  so keep that checkout clean. A successful landing deletes this worktree; `--keep` leaves it
  standing (a refused landing always keeps it).
- Enable the shared hooks once per clone: `git config core.hooksPath .githooks`. The pre-commit
  hook refuses a commit in the primary checkout — even when no linked worktree exists — and refuses
  a commit in a worktree while the primary has uncommitted tracked changes — listing the files, so
  the write is caught where it can still be moved instead of at somebody else's landing. Untracked
  files are not that write. It moves no files by itself; the deliberate escapes are
  `JAWNOS_ALLOW_PRIMARY_COMMIT=1` (a lone checkout, on purpose) and `JAWNOS_ALLOW_DIRTY_PRIMARY=1`.
- `.worktrees/` is gitignored, so a worktree never shows in the primary checkout's `git status`.
