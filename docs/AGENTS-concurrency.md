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

## Why the lander moves the primary checkout

`scripts/restart.pl` restarts whatever the master is already running. The primary checkout advances
on its own only through the code-sync job (`perl/President.pl`, Slow pool), so push-then-restart alone
restarts the *previous* commit and "always newest" becomes "newest within the hour". `agent_land.pl`
therefore fast-forwards the primary checkout (the first entry in `git worktree list --porcelain`)
before it restarts, and refuses the landing up front when that checkout is dirty — a landing that
cannot reach the server should not be pushed as though it did.

## The gate, step by step

`perl scripts/agent_land.pl` runs from the agent's worktree:

1. Take `jawnos-land.lock` in the git common dir (shared by every worktree); wait `--wait` seconds,
   then exit 4.
2. Refuse a dirty worktree, or a dirty primary checkout — both are someone's unswept work.
3. `git fetch origin`, then rebase onto `origin/main`. A `VERSION`-only conflict is taken from the
   trunk (the bump below moves it past trunk's number); any other conflict aborts the rebase and
   names the file.
4. Run the suite **once** (`--jobs 2` by default) and export `JAWNOS_SUITE_ALREADY_RUN=1`
   for the push, so the pre-push hook does not run it a second time. A failure refuses the landing;
   nothing is pushed.
5. Bump `VERSION`, rewrite the tip subject to `v<new> - <summary>` (an existing prefix is replaced,
   never stacked), amend. The body is preserved.
6. `git push origin HEAD:refs/heads/main` — fast-forward only, and the lock is why it stays one. The
   hook still runs its parse guard and help audit; only the duplicate suite is skipped.
7. Fast-forward the primary checkout, then `scripts/restart.pl --reason "v<new> - <summary>"`.

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

## Hot files

These are edited by nearly every task, so a landing that touches one should be small and land first —
rebase immediately before running the gate:

- `lib/JawnOS/Manager/Index.pm`, `lib/JawnOS/Manager/Declarations.pm`
- `lib/JawnOS/Domain/Loader.pm`, `lib/JawnOS/Routes/`
- `perl/language.pl`, `perl/help/topics_*`
- shared `.ep` partials, and the `t/54` / `t/58` / `t/91` / `t/11` / `t/99` pins

## In a worktree

- `git worktree add .worktrees/<task> -b agent/<task> origin/main`, and work only there.
- `config.json` is tracked with fixed ports (3000/3001). Do not run a server from a worktree, and do
  not run server-binding tests in parallel with another agent.
- `database/` is empty there. Seed a test database; never point one at `database/jawnos.db`.
- `perl/` and `lib/` are reached by cwd-relative `require`, so run commands from the worktree root.
