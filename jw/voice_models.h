#pragma once
// On-device voice models (microWakeWord). One model runs at a time, chosen by the
// panel's voice_trigger setting: 'vad' runs vad.tflite (capture on any speech); a
// wake phrase runs that phrase's model (capture after the phrase). Both share the
// same front-end (micro_features) and the same runtime (the interpreter bundled
// with the ESP32 core); only the model bytes and the cutoff differ.

#include <Arduino.h>
#include <string.h>

#include "jawn_micro_features.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_resource_variable.h"
#include "tensorflow/lite/micro/micro_allocator.h"
#include "vad_model.h"
#include "hey_jawn_model.h"

#define VOICE_MODEL_WINDOW 5           // sliding_window_size (the models ship 5)
#define VOICE_MODEL_TENSOR_ARENA 32768 // in PSRAM
#define VOICE_MODEL_VAR_ARENA 8192

struct voice_model_t {
  tflite::MicroMutableOpResolver<20> resolver;
  tflite::MicroInterpreter *interp = nullptr;
  tflite::MicroAllocator *ma = nullptr;
  tflite::MicroResourceVariables *mrv = nullptr;
  TfLiteTensor *in = nullptr, *out = nullptr;
  uint8_t *tensor_arena = nullptr;
  uint8_t var_arena[VOICE_MODEL_VAR_ARENA];
  uint8_t stride = 1, step = 0;
  uint8_t probs[VOICE_MODEL_WINDOW];
  int idx = 0;
  uint8_t cutoff_q = 127;
  bool ready = false;
};

static voice_model_t voice_vad;
static voice_model_t voice_wake;
static voice_model_t *voice_active = nullptr;

static bool voice_model_load(voice_model_t *m, const unsigned char *bytes, uint8_t cutoff_q) {
  if (m->ready) { return true; }
  auto &r = m->resolver;
  r.AddCallOnce(); r.AddVarHandle(); r.AddReshape(); r.AddReadVariable();
  r.AddStridedSlice(); r.AddConcatenation(); r.AddAssignVariable(); r.AddConv2D();
  r.AddMul(); r.AddAdd(); r.AddMean(); r.AddFullyConnected(); r.AddLogistic();
  r.AddQuantize(); r.AddDepthwiseConv2D(); r.AddAveragePool2D(); r.AddMaxPool2D();
  r.AddPad(); r.AddPack(); r.AddSplitV();

  m->ma = tflite::MicroAllocator::Create(m->var_arena, VOICE_MODEL_VAR_ARENA);
  if (!m->ma) { return false; }
  m->mrv = tflite::MicroResourceVariables::Create(m->ma, 20);
  if (!m->mrv) { return false; }

  // tensor arena in PSRAM: 32 KB of internal RAM starves the LCD's SPI DMA
  m->tensor_arena = (uint8_t *)ps_malloc(VOICE_MODEL_TENSOR_ARENA);
  if (!m->tensor_arena) { m->tensor_arena = (uint8_t *)malloc(VOICE_MODEL_TENSOR_ARENA); }
  if (!m->tensor_arena) { return false; }

  const tflite::Model *model = tflite::GetModel(bytes);
  m->interp = new tflite::MicroInterpreter(model, r, m->tensor_arena, VOICE_MODEL_TENSOR_ARENA, m->mrv);
  if (m->interp->AllocateTensors() != kTfLiteOk) { return false; }
  m->in = m->interp->input(0);
  m->out = m->interp->output(0);
  m->stride = m->in->dims->data[1];
  m->cutoff_q = cutoff_q;
  for (int i = 0; i < VOICE_MODEL_WINDOW; i++) { m->probs[i] = 0; }
  m->idx = 0;
  m->ready = true;
  return true;
}

// Pick and load the model the setting asks for. Anything that is not a wake word
// we have a model for (including 'vad', and the on-device voice toggle which
// leaves the trigger unset) falls back to the VAD.
static bool voice_models_init(const String &mode) {
  jawn_features_init();
  if (mode == "hey_jawn") {
    if (voice_model_load(&voice_wake, hey_jawn_model, (uint8_t)(0.90f * 255))) {
      voice_active = &voice_wake;
      Serial.println("[voice] model: hey jawn");
      return true;
    }
    Serial.println("[voice] hey jawn model failed to load; using VAD");
  } else if (mode.length() && mode != "off" && mode != "vad") {
    Serial.printf("[voice] no model for '%s' yet; using VAD\n", mode.c_str());
  }
  if (voice_model_load(&voice_vad, vad_model, (uint8_t)(0.5f * 255))) {
    voice_active = &voice_vad;
    return true;
  }
  voice_active = nullptr;
  return false;
}

// Feed 16 kHz int16 samples to the active model; true when it reads speech (VAD)
// or the wake phrase (wake word).
static bool voice_active_frame(const int16_t *samples, size_t n) {
  voice_model_t *m = voice_active;
  if (!m || !m->ready) { return false; }
  bool fired = false;
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
      m->probs[m->idx] = m->out->data.uint8[0];
      m->idx = (m->idx + 1) % VOICE_MODEL_WINDOW;
      uint32_t sum = 0;
      for (int i = 0; i < VOICE_MODEL_WINDOW; i++) { sum += m->probs[i]; }
      if (sum > (uint32_t)(m->cutoff_q * VOICE_MODEL_WINDOW)) { fired = true; }
    }
  }
  if (fired) {
    // cool off: clear the window so the same utterance is not detected twice
    for (int i = 0; i < VOICE_MODEL_WINDOW; i++) { m->probs[i] = 0; }
    m->idx = 0;
  }
  return fired;
}
