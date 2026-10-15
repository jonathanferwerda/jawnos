# Voice → Guide handoff (the "voice brain" seam)

Who this is for: the agent building the guide as a voice brain. It records the seam that
already exists in the tree (currently an **uncommitted stub** in `subroutines.pl`) and the
facts the watch side already provides, so the guide can be wired in without guessing.

## The seam

`subs::voice_brain($text, $meta)` — a stub today, returning `undef`.

`subs::voice_ingest()` calls it for an utterance that was **addressed to us but is not a
plain `start/stop <app>` command**, before it falls back to filing the transcript as a note:

    my $cmd = &subs::voice_command_parse($text, $wake_optional);
    if (($cmd->{status}||'') ne 'ok') {
        my $addressed = $wake_optional || (($cmd->{status}||'') ne 'no_wake');
        if ($addressed) {
            my $brain = eval { &subs::voice_brain($text, $meta) };
            if ($brain && ref $brain eq 'HASH' && $brain->{handled}) {
                &subs::voice_clip_ack($meta);
                return { status => 'brain', said => $text, %{$brain} };
            }
        }
        ... falls through to voice_note_store ...
    }

So: **return `{ handled => 1, ... }` to claim the utterance** (the clip is acked and the note
fallback is skipped); return `undef`/`{}` and it is filed as a note. The fast lane
(`start`/`stop <app>`) never reaches here.

## What the watch already provides (`$meta`)

    { edt, chip_id, ts, voice }

- `ts` — **when the utterance began** (the wake word), epoch ms. Stamp any appointment/note
  the brain creates with it, not with `rightNow()`. (The watch sends epoch *seconds* —
  `timestamp_maker` in `jw.ino` — and `voice_ingest` normalizes to ms; the raw seconds stay
  in `meta->{'ts_watch'}` for `voice_clip_ack`, which must echo the watch's own clock.)
- `voice` — the capture mode, tagged with the **active model** (`vad`, `hey_jawn`, `jawn_do`).
  A wake-word capture already consumed the phrase on the watch, so **its transcript is the
  command itself**; a `vad` capture still opens with the phrase. (This is why `voice_ingest`
  passes `$wake_optional`.)
- `edt` / `chip_id` — which device spoke, for routing a reply or a `now_me` back.

## What the brain should call (already built, guide side)

- **Act / answer:** `/manager/help/act` — the closed vocabulary in `help::actions_prompt()`
  (find, open_gallery, open_app, say, ask). One JSON action per turn.
- **Propose a write:** `POST /manager/help/stage` then `/promote` / `/discard` (the
  `staged_appointments` table) — a proposal a person promotes, never a direct write. Use this
  for "remind me to…", not a direct `appointment_writer`.
- **Answer in words:** `/manager/help/ask`, or `subs::evaluation_model_call` directly.
- **Speak the answer:** `&subs::say_it($text)` — piper-first on every device.

## Caveats

- `voice_ingest` may hold a **database handle**; do not fork inside the brain (a forked child
  loses the SQLite handle). The BLE path already runs `voice_ingest` inside a subprocessor, so
  a model call there is off the listener; the WiFi path runs inline in the request, so a slow
  brain delays its HTTP response — keep the call bounded, or hand the work to the existing
  queue.
- Only **addressed** utterances reach the brain (wake word present/mode). Room chatter over
  VAD never does, so the brain is not called on overheard conversation.
- Keep the watch facts (`ts`, `voice`) plumbed as-is; they are the two things the watch adds
  and the brain cannot recover on its own.

## Ownership

The stub and the call site are the guide agent's to fill. The watch-side facts (`voice` tag,
`ts` at the utterance onset) are done and stable. If the interface needs to change — e.g. a
richer return, or a separate queue — change `voice_brain`'s signature here and say so, so the
two halves stay in step.
