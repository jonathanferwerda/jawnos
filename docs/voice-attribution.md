# Voice model attribution

JawnOS ships three Piper voices. Two are fine-tuned from datasets licensed
**CC BY 4.0**, which requires attribution; the third is public domain.

- `en_US-libritts_r-medium` — trained on **LibriTTS-R** (OpenSLR 141),
  CC BY 4.0. Dataset: http://www.openslr.org/141/ — licence:
  https://creativecommons.org/licenses/by/4.0/ . Paper: Y. Koizumi et al.,
  "LibriTTS-R: A Restored Multi-Speaker Text-to-Speech Corpus" (2023).
- `en_GB-alba-medium` — trained on the **Alba** dataset (Edinburgh DataShare
  10283/3270), CC BY 4.0. Dataset:
  https://datashare.ed.ac.uk/handle/10283/3270 — licence:
  https://creativecommons.org/licenses/by/4.0/ .
- `en_US-ljspeech-medium` — trained on **LJSpeech**, public domain:
  https://keithito.com/LJ-Speech-Dataset/ .

The model files themselves are distributed from
https://huggingface.co/rhasspy/piper-voices (MIT at the repository level; the
per-voice dataset licences above govern the training data).

`voice_sync` writes this attribution into `~/jawnos/voices/ATTRIBUTION.md` on
every device that holds the models, so the notice travels with the blobs rather
than only living in the repository.
