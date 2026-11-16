// ---- voice in: the PDM microphone, the ring buffer, the wake-word hook ------
// The XIAO ESP32S3 Sense carries a PDM microphone. I2S port 1 reads it at 16 kHz
// mono into a FreeRTOS stream buffer; a phase-1 detector consumes that buffer
// and, when it fires, starts a capture and a snap. Phase 0 wires the plumbing and
// stops at the detector:
//
//   * wake_word_detected() is the hook. It returns false today.
//   * The model itself is NOT duplicated here. jt/hey_jawn_model.h is included
//     through -I../jt (see platformio.ini), the same arrangement as the deck.
//     Phase 1 should extract that header (and jt/vad_model.h) into a shared
//     location so two boards do not depend on one board's tree.
//   * The inference stack is real in the siblings: deck-libs/micro_features is
//     the front-end and the platform bundles espressif__esp-tflite-micro. What
//     is missing here is the ~120 lines of model loading and the sliding-window
//     probability in jt/jt_15_voice_activation.ino, deliberately left for phase 1.
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

static I2SClass jh_mic(I2S_NUM_1);
static StreamBufferHandle_t jh_voice_ring = nullptr;
static volatile uint32_t jh_voice_drops = 0;
static volatile uint32_t jh_voice_frames = 0;
static volatile bool jh_voice_alive = false;

// The one hook phase 1 fills in. Keep the signature: a detector that reads a
// frame at a time is what the shared model wants, and a future VAD can use the
// same entry point.
bool wake_word_detected(const int16_t *samples, size_t n) {
  (void)samples;
  (void)n;
  // TODO(phase 1): run hey_jawn_model through the micro_features front-end and
  // fire on the sliding-window probability cutoff. Do not fake a detector.
  return false;
}

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
      // Phase 1: a real detector lands here. The action is the same two calls
      // the BLE protocol already exposes, which is why the hook is this small.
      camera_request_snap();
      haptics_tick(70);
    }

    // The detector is the consumer once it exists. Until then this only fills
    // and drops, which the report line makes visible instead of hiding.
    size_t sent = xStreamBufferSend(jh_voice_ring, buf, n * 2, 0);
    if (sent < n * 2) {
      jh_voice_drops = jh_voice_drops + (uint32_t)((n * 2 - sent) / 2);
    }

    if (millis() - last_report >= 2000) {
      jh_log("[voice] rms=%u peak=%u frames=%u drops=%u", rms, peak_rms,
             (unsigned)jh_voice_frames, (unsigned)jh_voice_drops);
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
  jh_log("[voice] model shared from jt: %u bytes (first 0x%02x); inference TODO",
         hey_jawn_model_len, hey_jawn_model[0]);
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
