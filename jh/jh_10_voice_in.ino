// ---- voice in: the PDM microphone, the ring buffer, the wake-word hook ------
// The XIAO ESP32S3 Sense carries a PDM microphone. I2S port 1 reads it at 16 kHz
// mono into a FreeRTOS stream buffer; a phase-1 detector consumes that buffer
// and, when it fires, starts a capture and a snap. Phase 0 wires the plumbing and
// stops at the detector:
//
//   * wake_word_detected() runs the shared model through jt/voice_models.h.
//   * The model and the loading code are NOT duplicated here. jt/voice_models.h,
//     hey_jawn_model.h and vad_model.h are included through -I../jt (see
//     platformio.ini), the same arrangement as the deck. Extraction into a
//     shared location is still owed: two boards now depend on one board's tree.
//   * The front-end (deck-libs/micro_features) and the runtime
//     (espressif__esp-tflite-micro) are the siblings' own, so what lives here is
//     wiring and a latch, not a second inference stack.
//
// The mic pins are the Sense's onboard PDM wiring per Seeed's schematic
// (data 41, clock 42). I have not verified them against every board revision:
// the first boot's "[voice] rms=" line is the check. A silent or tiny RMS with
// the hat on the desk means the pins or the slot mode are wrong, not that the
// microphone is dead.
#define JH_PDM_DATA_PIN 41
#define JH_PDM_CLK_PIN  42
#define JH_VOICE_RING_BYTES (16 * 1024)
#define JH_VOICE_FRAME 256          // int16 samples per I2S read

// The sibling's TFLM stack: the same micro_features front-end, the same
// interpreter, and the same model table. Reached through -I../jt, like the
// header it replaces; pulling it in twice is safe, every model header is
// #pragma once.
//
// That front-end is named directly because PlatformIO's dependency finder only
// follows an include chain that starts in this project's own sources. voice_models.h
// sits in jt/ behind -I../jt, which is a build flag the finder does not read, so
// without this line the header resolves for the compiler and micro_features is
// never linked: the deck gets away with it only because its own jt.ino includes
// the same header from its src dir.
#include <jawn_micro_features.h>
#include "voice_models.h"

static I2SClass jh_mic(I2S_NUM_1);
static StreamBufferHandle_t jh_voice_ring = nullptr;
static volatile uint32_t jh_voice_drops = 0;
static volatile uint32_t jh_voice_frames = 0;
static volatile bool jh_voice_alive = false;
static bool jh_wake_latched = false;
static volatile bool jh_wake_ready = false;
static volatile uint32_t jh_wake_fires = 0;

// The detector. voice_active_frame() reports a *state* - the sliding window
// reads the phrase right now - and that stays true across consecutive frames, so
// the latch is what turns 30 ms of audio into one event per utterance. Without
// it a wake word would fire dozens of times as it is spoken.
bool wake_word_detected(const int16_t *samples, size_t n) {
  if (!jh_wake_ready) {
    return false;
  }
  if (!voice_active_frame(samples, n)) {
    jh_wake_latched = false;   // the phrase has passed: rearm
    return false;
  }
  if (jh_wake_latched) {
    return false;
  }
  jh_wake_latched = true;
  jh_wake_fires = jh_wake_fires + 1;
  jh_log("[voice] wake: %s", voice_mode_name);
  return true;
}

// The house reads these through jh.status. The peak probability is the number
// to watch when tuning the cutoff: a phrase that never climbs past ~0.4 wants a
// lower cutoff, and a room that idles above it wants a higher one.
bool wake_word_ready() { return jh_wake_ready; }
uint32_t wake_word_fires() { return jh_wake_fires; }
uint8_t wake_word_peak() { return voice_dbg_peak; }

static void voice_task(void *arg) {
  (void)arg;
  jh_voice_alive = true;
  static int16_t buf[JH_VOICE_FRAME];
  uint32_t last_report = millis();
  uint32_t frames = 0;
  uint32_t peak_rms = 0;
  while (true) {
    size_t got = jh_mic.readBytes((char *)buf, sizeof(buf));
    if (got < 2) {
      vTaskDelay(pdMS_TO_TICKS(2));
      continue;
    }
    size_t n = got / 2;
    frames++;
    jh_voice_frames = jh_voice_frames + 1;

    // A frame's RMS is enough to prove the microphone is live and to show the
    // room's floor; it is also what a future energy gate would use.
    int64_t sq = 0;
    for (size_t i = 0; i < n; i++) {
      sq += (int32_t)buf[i] * (int32_t)buf[i];
    }
    uint32_t rms = (uint32_t)sqrtf((float)sq / (float)n);
    if (rms > peak_rms) {
      peak_rms = rms;
    }

    if (wake_word_detected(buf, n)) {
      // A tick, not a snap. What follows a wake word is the utterance the house
      // should hear, and snapping here would post one frame per false trigger
      // into unclaimed media. The capture and its POST are the next piece;
      // voice_read() below already hands out the PCM for them.
      haptics_tick(70);
    }

    // The detector is the consumer once it exists. Until then this only fills
    // and drops, which the report line makes visible instead of hiding.
    size_t sent = xStreamBufferSend(jh_voice_ring, buf, n * 2, 0);
    if (sent < n * 2) {
      jh_voice_drops = jh_voice_drops + (uint32_t)((n * 2 - sent) / 2);
    }

    if (millis() - last_report >= 2000) {
      jh_log("[voice] rms=%u peak=%u frames=%u drops=%u wake=%u model=%u", rms, peak_rms,
             (unsigned)jh_voice_frames, (unsigned)jh_voice_drops,
             (unsigned)jh_wake_fires, (unsigned)voice_dbg_peak);
      last_report = millis();
      peak_rms = 0;
      (void)frames;
    }
  }
}

void voice_in_init() {
  jh_mic.setPinsPdmRx(JH_PDM_CLK_PIN, JH_PDM_DATA_PIN);
  if (!jh_mic.begin(I2S_MODE_PDM_RX, JH_MIC_RATE, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_MONO)) {
    jh_log("[voice] pdm begin failed (%d); no wake word", jh_mic.lastError());
    return;
  }
  jh_voice_ring = xStreamBufferCreate(JH_VOICE_RING_BYTES, 1);
  if (!jh_voice_ring) {
    jh_log("[voice] no ring buffer");
    return;
  }
  // The model loads into PSRAM (32 KB tensors, 8 KB resource variables) and
  // reports its own failure, because a hat whose microphone runs but which
  // nothing listens to is the quietest possible bug.
  if (!voice_models_init("hey_jawn")) {
    jh_log("[voice] no wake model loaded; the mic runs, nothing listens");
  }
  else {
    jh_wake_ready = true;
    jh_log("[voice] wake word armed: hey_jawn, %u model bytes (first 0x%02x)",
           hey_jawn_model_len, hey_jawn_model[0]);
  }
  if (xTaskCreatePinnedToCore(voice_task, "jh-voice", 4096, NULL, 1, NULL, 1) != pdPASS) {
    jh_log("[voice] no task");
    return;
  }
  jh_log("[voice] pdm mic %u Hz mono on data=%d clk=%d", (unsigned)JH_MIC_RATE,
         JH_PDM_DATA_PIN, JH_PDM_CLK_PIN);
}

// Phase 1's detector (or a manual capture) reads PCM from here. Zero timeout:
// the caller decides whether to wait.
size_t voice_read(int16_t *out, size_t samples) {
  if (!jh_voice_ring || !out || !samples) {
    return 0;
  }
  size_t got = xStreamBufferReceive(jh_voice_ring, out, samples * 2, 0);
  return got / 2;
}
