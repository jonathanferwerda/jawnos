# Training a "hey jawn" wake word (microWakeWord)

This is the one heavy step. Everything else runs on your machines; training wants
a **GPU**.

## Where to run it

| Option | Cost | Notes |
| --- | --- | --- |
| **Google Colab (free)** | $0 | T4 GPU; the notebook's home turf. GPU availability can queue. |
| **Kaggle (free)** | $0 | ~30 GPU-hours/week, often less fuss than Colab. Good fallback. |
| **This laptop (CPU only)** | $0 | Works, but **days** per run, and the box already runs jawn + other agents with swap near full. Not recommended. |
| **OVHcloud VPS (CPU only)** | — | No faster than the laptop (no GPU). |

So: **use Colab (or Kaggle)**. You already have a Google account. Nothing to
install locally.

## The plan

Run the official notebook — `kahrendt/microWakeWord` →
`notebooks/basic_training_notebook.ipynb` — in Colab with a **GPU runtime**
(Runtime → Change runtime type → T4). It is explicitly a *starting point*: the
first model may not be usable and takes experimentation. Two things to know:

- **One model per phrase.** Train "hey jawn" first; then "sup jawn", "jawnski",
  "sup ya hoser" are separate runs. The firmware holds a *list* of models.
- **The front-end settings are fixed** (we deploy with these, so don't change
  them): 16 kHz, 30 ms window, 10 ms step, 40 channels, PCAN, 125–7500 Hz. They
  live in `microwakeword/audio/audio_utils.py` and are already what the notebook
  uses.

### Only edit the target word

In the notebook, set:

```python
target_word = 'hey jawn'   # phonetic spellings often sample better; try 'hey jawn'
                           # and, if training struggles, 'hey_john'-style variants
```

Generate **several thousand** samples (the notebook's first pass is 1000 — bump
it, e.g. `--max-samples 3000`), download the negatives it names, build the
features, write the yaml, train (~10k steps). Then download:

```
trained_models/wakeword/tflite_stream_state_internal_quant/stream_state_internal_quant.tflite
```

Rename it `hey_jawn.tflite` and hand it back — that's all that's needed to wire it
into the watch.

## The model manifest (for our firmware / ESPHome)

Alongside the `.tflite`, write a `hey_jawn.json`:

```json
{
  "type": "micro",
  "wake_word": "hey jawn",
  "author": "you",
  "website": "https://example.invalid",
  "model": "hey_jawn.tflite",
  "trained_languages": ["en"],
  "version": 2,
  "micro": {
    "probability_cutoff": 0.90,
    "feature_step_size": 10,
    "sliding_window_size": 5,
    "tensor_arena_size": 26080,
    "minimum_esphome_version": "2024.7.0"
  }
}
```

`probability_cutoff` and `sliding_window_size` come from the test results the
notebook prints; raise the cutoff if it false-triggers, lower it if it misses.

## What lands where

- Your trained `<phrase>.tflite` → I add it as a **row** beside the VAD in
  `jw/voice_models.h` (a `*_model.h` via `.shots/tflite_to_header.py`, plus a
  `voice_words[]` entry with its mode name and cutoff), and flash.
- The same file works on the deck and (later) the Pico — train once.

## Training the other phrases (Jawn Do)

One model per phrase. "Jawn Do" is this notebook with two edits:

```python
target_word = 'jawn do'          # cell 2, "... + our target word"
dst = "jawn_do.tflite"           # cell 11, the output copy
```

The ready-to-run version lives at `~/Downloads/jawn_do_colab.ipynb` (File →
Upload notebook in Colab). Run all cells on a GPU runtime and download the model.

**The trap that bit us:** the first "Jawn Do" model turned out to be a byte copy
of `hey_jawn.tflite` (both `md5 a3da6184…`), so the watch could only ever fire on
"hey jawn" and the setting looked broken. After downloading, check it is its own
model before wiring anything in:

    md5sum ~/Downloads/jawn_do.tflite ~/Downloads/hey_jawn.tflite   # must differ

Then: `.shots/tflite_to_header.py jawn_do.tflite jw/jawn_do_model.h jawn_do_model`,
build and flash, and set the watch to it (`vtrig jawn_do` over USB, or the Voice
select in the Embedded panel, which pushes a Now Me). The `jawn_do` cutoff in
`jw/voice_models.h` starts at 0.55; the ROC file the notebook prints (`tflite_streaming_roc.txt`)
tells you the false-accept/hour at each cutoff to move it.

## Tips that matter for this phrase

- "hey jawn" is two syllables and fairly distinctive — a much easier target than
  a lone "jawn".
- Watch the notebook's reported **false-accepts/hour**; that's the number to
  minimise, usually by adding background negatives and raising the cutoff.
- If it misses, generate more samples and add more negative speech.
