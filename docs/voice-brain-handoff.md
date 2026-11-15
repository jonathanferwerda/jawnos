# Voice → Guide seam (implemented)

Who this is for: anyone changing the spoken-input path. This is a reference, not
a plan — the seam it used to describe as a stub is implemented. The contract and
the watch facts below are still the useful parts.

## The seam

`subs::voice_brain($text, $meta)` lives in `lib/JawnOS/Domain/Ai.pm` (registered
in `lib/JawnOS/Domain/Loader.pm`) and is called from `voice_ingest`
(`Ai.pm:967`) for an utterance that was **addressed to us but is not a plain
`start/stop <app>` command**:

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

So: **return `{ handled => 1, ... }` to claim the utterance** (the clip is acked
and the note fallback is skipped); return `undef`/`{}` and it is filed as a note.
The fast lane (`start`/`stop <app>`) never reaches here.

## What the watch already provides (`$meta`)

    { edt, chip_id, ts, voice }

- `ts` — **when the utterance began** (the wake word), epoch ms. Stamp any
  appointment/note the brain creates with it, not with `rightNow()`. (The watch
  sends epoch *seconds* — `timestamp_maker` in `jw.ino` — and `voice_ingest`
  normalizes to ms; the raw seconds stay in `meta->{'ts_watch'}` for
  `voice_clip_ack`, which must echo the watch's own clock.)
- `voice` — the capture mode, tagged with the **active model** (`vad`, `hey_jawn`,
  `jawn_do`). A wake-word capture already consumed the phrase on the watch, so
  **its transcript is the command itself**; a `vad` capture still opens with the
  phrase. (This is why `voice_ingest` passes `$wake_optional`.)
- `edt` / `chip_id` — which device spoke, for routing a reply or a `now_me` back.

## What the brain actually calls

- **The guide's model role** — `subs::ai_role_models('help_assistant')`, with the
  optional `mail/voice_assistant` fast model tried first
  (`evaluation_model_call_with_fallback`, else
  `evaluation_model_call_role`). Without a guide model it returns `undef` and the
  transcript stays a note.
- **A closed action vocabulary** — `help::actions_prompt(\%voice_verbs)` over
  `say ask done measure where_when create play_music open_app alias unalias`.
  The verbs are deliberately narrower than the Guide's full set: there is no
  screen and no follow-up turn.
- **Name resolution** — `subs::guide_resolve_action` rewrites a clear app name to
  its canonical key; a tie becomes a spoken `ask`, never a guess.
- **Writes** — `create` stages a proposal through
  `Manager::guide_stage_appointment` (the `staged_appointments` table) and, when
  `guide_confirm` is `off`, promotes it in the same turn. It never calls
  `appointment_writer` directly.
- **Speech** — `subs::watch_reply` when `chip_id` is present, otherwise
  `subs::say_it`. `measure`/`where_when`/`play_music`/`open_app` run through
  `Manager::remote_command_execute`, so they reach the open tabs over the socket.

The raw model reply and the chosen action are logged as `voice: brain ...`.

## Caveats

- `voice_ingest` may hold a **database handle**; do not fork inside the brain (a
  forked child loses the SQLite handle). The BLE path already runs `voice_ingest`
  inside a subprocessor, so a model call there is off the listener; the WiFi path
  runs inline in the request, so a slow brain delays its HTTP response — keep the
  call bounded, or hand the work to the existing queue.
- Only **addressed** utterances reach the brain (wake word present/mode). Room
  chatter over VAD never does, so the brain is not called on overheard
  conversation.
- Keep the watch facts (`ts`, `voice`) plumbed as-is; they are the two things the
  watch adds and the brain cannot recover on its own.

## Ownership

Implemented in `lib/JawnOS/Domain/Ai.pm`; the watch-side facts (`voice` tag, `ts`
at the utterance onset) are stable. If the interface needs to change — e.g. a
richer return, or a separate queue — change `voice_brain`'s signature here and
say so, so the two halves stay in step.
