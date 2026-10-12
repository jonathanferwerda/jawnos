#pragma once
// On-device voice activity detection: microWakeWord's vad.tflite.
//
// The watch's listener used an RMS energy gate, which answered taps, doors and
// running water. This replaces it with a neural VAD: 30 ms frames feed the
// microWakeWord spectrogram front-end (the micro_features library), the 40
// features are quantised to int8 exactly as training expected, and a streaming
// TFLite-Micro model (the interpreter bundled with the ESP32 core) returns a
// probability. A sliding-window average over that probability is the speech
// decision. Same runtime and settings any future wake-word model will use.

#include <Arduino.h>
#include <math.h>
#include <string.h>

#include "jawn_micro_features.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_resource_variable.h"
#include "tensorflow/lite/micro/micro_allocator.h"
#include "vad_model.h"

#define VOICE_VAD_WINDOW 5         // vad.json sliding_window_size
#define VOICE_VAD_CUTOFF_Q 127     // 0.5 * 255, the manifest's quantised cutoff
#define VOICE_VAD_TENSOR_ARENA 32768
#define VOICE_VAD_VAR_ARENA 8192

static tflite::MicroMutableOpResolver<20> voice_vad_resolver;
// The tensor arena goes in PSRAM (as ESPHome does): 32 KB of internal RAM spent
// here starves the LCD's SPI DMA buffers, which showed up as
// "setup_dma_priv_buffer failed" on every draw. Falls back to internal RAM if
// there is no PSRAM.
static uint8_t *voice_vad_tensor_arena = nullptr;
static uint8_t voice_vad_var_arena[VOICE_VAD_VAR_ARENA];
static tflite::MicroInterpreter *voice_vad_interp = nullptr;
static tflite::MicroAllocator *voice_vad_ma = nullptr;
static tflite::MicroResourceVariables *voice_vad_mrv = nullptr;
static TfLiteTensor *voice_vad_in = nullptr, *voice_vad_out = nullptr;
static uint8_t voice_vad_stride = 1, voice_vad_step = 0;
static uint16_t voice_vad_feats[JAWN_FEATURE_SIZE];
static uint8_t voice_vad_probs[VOICE_VAD_WINDOW];
static int voice_vad_idx = 0;
static bool voice_vad_ready = false;

static bool voice_vad_init() {
  if (voice_vad_ready) { return true; }
  voice_vad_resolver.AddCallOnce();
  voice_vad_resolver.AddVarHandle();
  voice_vad_resolver.AddReshape();
  voice_vad_resolver.AddReadVariable();
  voice_vad_resolver.AddStridedSlice();
  voice_vad_resolver.AddConcatenation();
  voice_vad_resolver.AddAssignVariable();
  voice_vad_resolver.AddConv2D();
  voice_vad_resolver.AddMul();
  voice_vad_resolver.AddAdd();
  voice_vad_resolver.AddMean();
  voice_vad_resolver.AddFullyConnected();
  voice_vad_resolver.AddLogistic();
  voice_vad_resolver.AddQuantize();
  voice_vad_resolver.AddDepthwiseConv2D();
  voice_vad_resolver.AddAveragePool2D();
  voice_vad_resolver.AddMaxPool2D();
  voice_vad_resolver.AddPad();
  voice_vad_resolver.AddPack();
  voice_vad_resolver.AddSplitV();

  voice_vad_ma = tflite::MicroAllocator::Create(voice_vad_var_arena, VOICE_VAD_VAR_ARENA);
  if (!voice_vad_ma) { return false; }
  voice_vad_mrv = tflite::MicroResourceVariables::Create(voice_vad_ma, 20);
  if (!voice_vad_mrv) { return false; }

  const tflite::Model *model = tflite::GetModel(vad_model);
  voice_vad_tensor_arena = (uint8_t *)ps_malloc(VOICE_VAD_TENSOR_ARENA);
  if (!voice_vad_tensor_arena) { voice_vad_tensor_arena = (uint8_t *)malloc(VOICE_VAD_TENSOR_ARENA); }
  if (!voice_vad_tensor_arena) { return false; }
  voice_vad_interp = new tflite::MicroInterpreter(model, voice_vad_resolver,
                                                  voice_vad_tensor_arena,
                                                  VOICE_VAD_TENSOR_ARENA, voice_vad_mrv);
  if (voice_vad_interp->AllocateTensors() != kTfLiteOk) { return false; }
  voice_vad_in = voice_vad_interp->input(0);
  voice_vad_out = voice_vad_interp->output(0);
  voice_vad_stride = voice_vad_in->dims->data[1];
  for (int i = 0; i < VOICE_VAD_WINDOW; i++) { voice_vad_probs[i] = 0; }
  voice_vad_idx = 0;
  voice_vad_step = 0;
  jawn_features_init();
  voice_vad_ready = true;
  return true;
}

// Feed 16 kHz int16 samples; returns true when the VAD reads speech.
static bool voice_vad_frame(const int16_t *samples, size_t n) {
  if (!voice_vad_ready) { return false; }
  bool fired = false;
  size_t done = 0;
  while (done < n) {
    size_t used = 0;
    size_t produced = jawn_features_process(samples + done, n - done, voice_vad_feats, 1, &used);
    done += used;
    if (used == 0) { break; }
    if (produced == 0) { continue; }
    // the microWakeWord int8 mapping: (((f / 25.6) / 26.0) * 256) - 128
    int8_t f[JAWN_FEATURE_SIZE];
    for (int i = 0; i < JAWN_FEATURE_SIZE; i++) {
      int32_t v = ((int32_t)voice_vad_feats[i] * 256 + 333) / 666;
      v += -128;
      if (v < -128) { v = -128; }
      if (v > 127) { v = 127; }
      f[i] = (int8_t)v;
    }
    voice_vad_step = voice_vad_step % voice_vad_stride;
    memcpy((int8_t *)voice_vad_in->data.int8 + JAWN_FEATURE_SIZE * voice_vad_step, f, JAWN_FEATURE_SIZE);
    voice_vad_step++;
    if (voice_vad_step >= voice_vad_stride) {
      if (voice_vad_interp->Invoke() != kTfLiteOk) { continue; }
      voice_vad_probs[voice_vad_idx] = voice_vad_out->data.uint8[0];
      voice_vad_idx = (voice_vad_idx + 1) % VOICE_VAD_WINDOW;
      uint32_t sum = 0;
      for (int i = 0; i < VOICE_VAD_WINDOW; i++) { sum += voice_vad_probs[i]; }
      fired = sum > (uint32_t)(VOICE_VAD_CUTOFF_Q * VOICE_VAD_WINDOW);
    }
  }
  return fired;
}
