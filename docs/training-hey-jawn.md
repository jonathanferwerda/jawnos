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

- Your trained `hey_jawn.tflite` → I add it as a **second model** beside the VAD
  in `jw/voice_vad.h`, map the `voice_trigger` value `hey_jawn` onto it in
  `voice_trigger_apply()`, and flash.
- The same file works on the deck and (later) the Pico — train once.

## Tips that matter for this phrase

- "hey jawn" is two syllables and fairly distinctive — a much easier target than
  a lone "jawn".
- Watch the notebook's reported **false-accepts/hour**; that's the number to
  minimise, usually by adding background negatives and raising the cutoff.
- If it misses, generate more samples and add more negative speech.
