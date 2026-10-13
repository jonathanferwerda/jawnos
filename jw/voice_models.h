#pragma once
// On-device voice models (microWakeWord). One model runs at a time, chosen by the
// panel's voice_trigger setting: 'vad' runs vad.tflite (capture on any speech); a
// wake phrase runs that phrase's model (capture after the phrase). All share the
// same front-end (micro_features) and the same runtime (the interpreter bundled
// with the ESP32 core); only the model bytes and the cutoff differ.
//
// Adding a phrase is a file drop: train it, run .shots/tflite_to_header.py to make
// a *_model.h, include that header here, and add one row to voice_words[].

#include <Arduino.h>
#include <string.h>

#include "jawn_micro_features.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_resource_variable.h"
#include "tensorflow/lite/micro/micro_allocator.h"
#include "vad_model.h"
#include "hey_jawn_model.h"
#include "jawn_do_model.h"

#define VOICE_MODEL_WINDOW 5           // sliding_window_size (the models ship 5)
#define VOICE_MODEL_TENSOR_ARENA 32768 // in PSRAM
#define VOICE_MODEL_VAR_ARENA 8192

// The voices the panel can pick. cutoff is the microWakeWord probability_cutoff,
// kept here rather than read from the model: lower means more sensitive. Tune
// each phrase from the tflite_streaming_roc.txt its training run writes.
struct voice_word_t {
  const char *mode;
  const unsigned char *bytes;
  float cutoff;
};

static const voice_word_t voice_words[] = {
  // Cutoffs suit a quiet user: whispering into the watch sits well below a
  // spoken word, so the noise floor is low. Raise these if it false-triggers.
  { "vad",      vad_model,      0.30f },
  { "hey_jawn", hey_jawn_model, 0.55f },
  { "jawn_do",  jawn_do_model,  0.55f },
};
#define VOICE_WORD_COUNT (sizeof(voice_words) / sizeof(voice_words[0]))

struct voice_model_t {
  tflite::MicroMutableOpResolver<20> resolver;
  tflite::MicroInterpreter *interp = nullptr;
  tflite::MicroAllocator *ma = nullptr;
  tflite::MicroResourceVariables *mrv = nullptr;
  TfLiteTensor *in = nullptr, *out = nullptr;
  uint8_t *tensor_arena = nullptr;
  uint8_t *var_arena = nullptr;
  uint8_t stride = 1, step = 0;
  uint8_t probs[VOICE_MODEL_WINDOW];
  int idx = 0;
  uint8_t cutoff_q = 127;
  bool ready = false;
};

// One slot per row in voice_words[], loaded lazily and kept (the setting rarely
// changes, and a resident model reloads in no time). Only the picked one is active.
static voice_model_t voice_slots[VOICE_WORD_COUNT];
static voice_model_t *voice_active = nullptr;
// The mode string of the model actually running ("vad" or a wake phrase), which
// is what a shipped clip is tagged with - not the setting, which can be 'off'
// while the listener falls back to the VAD. The server routes on this.
static const char *voice_mode_name = "off";

// Diagnostics for the serial 'voicedbg' line: the highest model probability
// seen since the last report (0 = never invoked or always silent), and how many
// frames in the last second read as speech.
static uint8_t voice_dbg_peak = 0;
static uint32_t voice_dbg_fires = 0;

static bool voice_model_load(voice_model_t *m, const voice_word_t *w) {
  if (m->ready) { return true; }
  auto &r = m->resolver;
  r.AddCallOnce(); r.AddVarHandle(); r.AddReshape(); r.AddReadVariable();
  r.AddStridedSlice(); r.AddConcatenation(); r.AddAssignVariable(); r.AddConv2D();
  r.AddMul(); r.AddAdd(); r.AddMean(); r.AddFullyConnected(); r.AddLogistic();
  r.AddQuantize(); r.AddDepthwiseConv2D(); r.AddAveragePool2D(); r.AddMaxPool2D();
  r.AddPad(); r.AddPack(); r.AddSplitV();

  // The resource-variable arena is 8 KB per slot and there are three slots, but
  // only one model runs at a time: keeping all three in .bss cost ~24 KB of
  // internal RAM, the same memory the LCD's SPI DMA bounce needs (see the tensor
  // arena below). Nothing here is DMA, so it lives in PSRAM too.
  if (!m->var_arena) {
    m->var_arena = (uint8_t *)ps_malloc(VOICE_MODEL_VAR_ARENA);
    if (!m->var_arena) { m->var_arena = (uint8_t *)malloc(VOICE_MODEL_VAR_ARENA); }
    if (!m->var_arena) { return false; }
  }
  m->ma = tflite::MicroAllocator::Create(m->var_arena, VOICE_MODEL_VAR_ARENA);
  if (!m->ma) { return false; }
  m->mrv = tflite::MicroResourceVariables::Create(m->ma, 20);
  if (!m->mrv) { return false; }

  // tensor arena in PSRAM: 32 KB of internal RAM starves the LCD's SPI DMA
  m->tensor_arena = (uint8_t *)ps_malloc(VOICE_MODEL_TENSOR_ARENA);
  if (!m->tensor_arena) { m->tensor_arena = (uint8_t *)malloc(VOICE_MODEL_TENSOR_ARENA); }
  if (!m->tensor_arena) { return false; }

  const tflite::Model *model = tflite::GetModel(w->bytes);
  m->interp = new tflite::MicroInterpreter(model, r, m->tensor_arena, VOICE_MODEL_TENSOR_ARENA, m->mrv);
  if (m->interp->AllocateTensors() != kTfLiteOk) { return false; }
  m->in = m->interp->input(0);
  m->out = m->interp->output(0);
  m->stride = m->in->dims->data[1];
  m->cutoff_q = (uint8_t)(w->cutoff * 255);
  for (int i = 0; i < VOICE_MODEL_WINDOW; i++) { m->probs[i] = 0; }
  m->idx = 0;
  m->ready = true;
  return true;
}

static const voice_word_t *voice_word_for(const String &mode) {
  for (size_t i = 0; i < VOICE_WORD_COUNT; i++) {
    if (mode == voice_words[i].mode) { return &voice_words[i]; }
  }
  return nullptr;
}

// True when the setting names a voice we have a model for. jw.ino uses this to arm
// the capture listener (the panel path); 'off' and unknown names return false.
static bool voice_models_has(const String &mode) {
  return voice_word_for(mode) != nullptr;
}

// Pick and load the model the setting asks for. Anything without a model (the
// on-device toggle leaving the trigger unset, and 'off') falls back to the VAD.
static bool voice_models_init(const String &mode) {
  jawn_features_init();
  const voice_word_t *w = voice_word_for(mode);
  if (!w) {
    if (mode.length() && mode != "off") {
      Serial.printf("[voice] no model for '%s' yet; using VAD\n", mode.c_str());
    }
    w = voice_word_for("vad");
  }
  if (!w) { voice_active = nullptr; return false; }
  voice_model_t *slot = &voice_slots[w - voice_words];
  if (!voice_model_load(slot, w)) {
    Serial.printf("[voice] %s model failed to load; using VAD\n", w->mode);
    voice_active = nullptr;
    return false;
  }
  voice_active = slot;
  voice_mode_name = w->mode;
  Serial.printf("[voice] model: %s\n", w->mode);
  return true;
}

// Feed 16 kHz int16 samples to the active model; true when it reads speech (VAD)
// or the wake phrase (wake word).
static bool voice_active_frame(const int16_t *samples, size_t n) {
  voice_model_t *m = voice_active;
  if (!m || !m->ready) { return false; }
  bool present = false;
  size_t done = 0;
  uint16_t feats[JAWN_FEATURE_SIZE];
  while (done < n) {
    size_t used = 0;
    size_t produced = jawn_features_process(samples + done, n - done, feats, 1, &used);
    done += used;
    if (used == 0) { break; }
    if (produced == 0) { continue; }
    // the microWakeWord int8 mapping: (((f / 25.6) / 26.0) * 256) - 128
    int8_t f[JAWN_FEATURE_SIZE];
    for (int i = 0; i < JAWN_FEATURE_SIZE; i++) {
      int32_t v = ((int32_t)feats[i] * 256 + 333) / 666;
      v += -128;
      if (v < -128) { v = -128; }
      if (v > 127) { v = 127; }
      f[i] = (int8_t)v;
    }
    m->step = m->step % m->stride;
    memcpy((int8_t *)m->in->data.int8 + JAWN_FEATURE_SIZE * m->step, f, JAWN_FEATURE_SIZE);
    m->step++;
    if (m->step >= m->stride) {
      if (m->interp->Invoke() != kTfLiteOk) { continue; }
      uint8_t p = m->out->data.uint8[0];
      m->probs[m->idx] = p;
      if (p > voice_dbg_peak) { voice_dbg_peak = p; }
      m->idx = (m->idx + 1) % VOICE_MODEL_WINDOW;
      uint32_t sum = 0;
      for (int i = 0; i < VOICE_MODEL_WINDOW; i++) { sum += m->probs[i]; }
      if (sum > (uint32_t)(m->cutoff_q * VOICE_MODEL_WINDOW)) { present = true; }
    }
  }
  // Report the window as a *state* (is there speech right now?), not a one-shot
  // event that clears its own window. The listener counts consecutive speech
  // frames before it commits a capture, so a latched 'fired' that zeroed the
  // window on every hit made that count reset each time and no capture ever
  // committed: the VAD read speech, but nothing ever recorded.
  if (present) { voice_dbg_fires++; }
  return present;
}
