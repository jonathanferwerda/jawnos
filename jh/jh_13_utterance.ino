// ---- utterance: one spoken command, from the wake word to the answer --------
// The wake word is only the door. What follows it is the actual question, and
// phase 0's exit test is the whole loop: say the phrase, ask what is in front,
// hear a correct answer (docs/hat.md). This part owns the middle of that loop.
//
// The shape is the deck's (jt/jt_15_voice_activation.ino), cut down to what a
// phase-0 hat needs:
//
//   * voice_task keeps filling the ring and running the detector; a second task
//     drains the ring while one utterance is captured, so listening never stops;
//   * the capture starts fresh after the wake frame - the phrase tail already in
//     the ring is discarded - and ends on the first of a fixed quiet gap or the
//     maximum length;
//   * the clip is 16 kHz mono PCM in PSRAM, wrapped in a 44-byte WAV header and
//     POSTed to /watch/voice with the Now Me authorization;
//   * the answer arrives as text (`say`), a one-shot WAV (`say_audio_ready`) or
//     PCM parts over BLE (`say_audio`); the two audio forms play through the
//     MAX98357 and the bone-conduction pair.
//
// `say` text cannot be heard. There is no on-device TTS, and a transducer plays
// samples, not words: the text is logged for the bench and that is all it can do
// until the house's audio forms arrive (or phase 1 adds a voice).

#define JH_UTTER_RATE         JH_MIC_RATE       // mic, model and house all speak 16 kHz
#define JH_UTTER_SILENCE_MS   450               // trailing quiet that ends a command (jt's number)
#define JH_UTTER_MAX_MS       6000              // a command, not a lecture
// Phase 0 uses one fixed floor, as the deck does before its room estimate has
// settled (VOICE_WAKE_RMS_FLOOR in jt_15_voice_activation.ino). That is a
// simplification, not a calibration: a quiet room and a noisy one get the same
// number. The first bench run's "[utter] rms" lines are what would justify a
// second constant or the deck's ambient-tracking floor.
#define JH_UTTER_RMS_FLOOR    400
#define JH_UTTER_MAX_SAMPLES  ((uint32_t)JH_UTTER_RATE * JH_UTTER_MAX_MS / 1000)
#define JH_UTTER_WAV_BYTES    (44 + (size_t)JH_UTTER_MAX_SAMPLES * 2)

static volatile bool jh_utter_busy = false;   // one capture at a time
static volatile bool jh_fetch_busy = false;   // one reply download at a time

// The BLE fallback stream (`say_audio`). Each part is 4 KB of PCM, base64'd on
// its own, so the parts are decoded one at a time and appended; concatenating
// the base64 text would leave padding at every seam. `total` is only the
// sender's estimate (Say.pm's est_total), so this grows instead of trusting it.
static uint8_t *jh_say_pcm = nullptr;
static size_t jh_say_cap = 0;
static size_t jh_say_len = 0;
static uint32_t jh_say_rate = 8000;
static uint32_t jh_say_next_seq = 0;
static bool jh_say_drop = false;   // a part failed: ignore the rest of this stream

// ---- small writers: the WAV header is little-endian, whatever the host is ---
static void utter_wr16(uint8_t *p, uint16_t v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)((v >> 8) & 0xff);
}

static void utter_wr32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)((v >> 8) & 0xff);
  p[2] = (uint8_t)((v >> 16) & 0xff);
  p[3] = (uint8_t)((v >> 24) & 0xff);
}

// 44-byte canonical PCM WAV: 16 kHz, mono, 16-bit. The house reads it as a file,
// and the same bytes are what the route hands to whisper.
static void utter_wav_header(uint8_t *h, uint32_t pcm_bytes) {
  memcpy(h, "RIFF", 4);
  utter_wr32(h + 4, pcm_bytes + 36);
  memcpy(h + 8, "WAVE", 4);
  memcpy(h + 12, "fmt ", 4);
  utter_wr32(h + 16, 16);                      // fmt chunk size
  utter_wr16(h + 20, 1);                       // PCM
  utter_wr16(h + 22, 1);                       // mono
  utter_wr32(h + 24, JH_UTTER_RATE);
  utter_wr32(h + 28, JH_UTTER_RATE * 2);       // byte rate: mono * 16-bit
  utter_wr16(h + 32, 2);                       // block align
  utter_wr16(h + 34, 16);                      // bits per sample
  memcpy(h + 36, "data", 4);
  utter_wr32(h + 40, pcm_bytes);
}

// The Now Me authorization is base64. '+' is the one character a query decoder
// turns into a space, which is exactly how the deck's token stopped matching
// before it escaped the whole value (jt_01_globals_ble_house.ino's urlEncode).
// This keeps the RFC 3986 unreserved set and percent-encodes everything else.
static String utter_url_encode(const char *s) {
  static const char hex[] = "0123456789ABCDEF";
  String out;
  out.reserve(strlen(s) * 3);
  for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
    if (isalnum(*p) || *p == '-' || *p == '_' || *p == '.' || *p == '~') {
      out += (char)*p;
    }
    else {
      out += '%';
      out += hex[*p >> 4];
      out += hex[*p & 0x0f];
    }
  }
  return out;
}

// Where the voice route lives. Now Me's homebase is the machine that paired this
// hat ("host" or "host:port", no scheme), and it is preferred because it is the
// machine that actually holds the pairing. With no Now Me yet, fall back to the
// configured house_url: cut it at the third '/', so
// https://192.168.2.3:45547/manager/... becomes https://192.168.2.3:45547.
static String utter_house_base(const char *homebase) {
  if (homebase && homebase[0]) {
    String h = homebase;
    if (h.startsWith("http://") || h.startsWith("https://")) {
      return h;
    }
    return String("https://") + h;
  }
  if (!jh_house_url.length()) {
    return String("");
  }
  int slashes = 0;
  for (int i = 0; i < (int)jh_house_url.length(); i++) {
    if (jh_house_url[i] != '/') {
      continue;
    }
    if (++slashes == 3) {
      return jh_house_url.substring(0, i);
    }
  }
  return jh_house_url;   // already a base, with no path to trim
}

// POST the clip exactly as the deck does: the raw WAV as the body, the Now Me
// pair in the query, a 4 s timeout, and anything under 400 accepted. The house
// answers 'ok' before it transcribes, so the device never waits for whisper.
static bool utter_post(uint8_t *wav, size_t len) {
  char auth[JH_NOW_ME_AUTH_MAX];
  char homebase[JH_NOW_ME_HOST_MAX];
  bool have_offset = false;
  long offset = 0;
  now_me_snapshot(auth, sizeof auth, homebase, sizeof homebase, &have_offset, &offset);

  // Never post unauthenticated. An empty token is not a retry problem: the
  // bridge has not delivered a Now Me yet, and inventing one would only add a
  // rejection to the log.
  if (!auth[0]) {
    jh_log("[utter] no Now Me authorization yet; clip not posted");
    return false;
  }
  String base = utter_house_base(homebase);
  if (!base.length()) {
    jh_log("[utter] no homebase and no house_url; clip not posted");
    return false;
  }
  if (WiFi.status() != WL_CONNECTED) {
    jh_log("[utter] wifi is down; clip not posted (%u bytes)", (unsigned)len);
    return false;
  }

  // timestamp is epoch SECONDS. There is no RTC, so a clock fixed by Now Me is
  // the only way to stamp a clip; with none, 0 is honest and the house files it
  // as unstamped rather than at a confident wrong hour.
  long stamp = 0;
  if (have_offset) {
    stamp = (long)time(NULL) + offset;
  }
  else {
    jh_log("[utter] no clock fix yet; posting an unstamped clip (timestamp=0)");
  }

  const char *mode = voice_mode_name ? voice_mode_name : "hey_jawn";
  String url = base + "/watch/voice?edt=microcontroller"
               "&chip_id=" + chip_id_maker()
             + "&voice=" + String(mode)
             + "&timestamp=" + String(stamp)
             + "&authorization=" + utter_url_encode(auth);

  HTTPClient http;
  WiFiClientSecure secure;
  WiFiClient plain;
  bool tls = base.startsWith("https://");
  bool began = false;
  if (tls) {
    secure.setCACert(HOUSE_CA_PEM);
    began = http.begin(secure, url);
  }
  else {
    began = http.begin(plain, url);
  }
  if (!began) {
    jh_log("[utter] bad url: %s", url.c_str());
    return false;
  }
  http.setTimeout(4000);
  http.addHeader("Content-Type", "application/octet-stream");
  int code = http.sendRequest("POST", wav, len);
  http.end();
  bool ok = (code > 0 && code < 400);
  jh_log("[utter] posted %u bytes, http %d%s", (unsigned)len, code, ok ? "" : " (failed)");
  return ok;
}

// ---- capture ----------------------------------------------------------------
// The capture task is the ring's second consumer. voice_task stays the producer,
// so the wake detector keeps running while a question is being recorded; the
// only shared state is the ring itself.
static void utterance_task(void *arg) {
  (void)arg;
  uint8_t *wav = (uint8_t *)ps_malloc(JH_UTTER_WAV_BYTES);
  if (!wav) {
    jh_log("[utter] no %u-byte PSRAM buffer; capture dropped", (unsigned)JH_UTTER_WAV_BYTES);
    jh_utter_busy = false;
    vTaskDelete(NULL);
    return;
  }

  const uint32_t silence_end = (uint32_t)JH_UTTER_RATE * JH_UTTER_SILENCE_MS / 1000;
  uint32_t started = millis();
  uint32_t total_samples = 0;
  uint32_t silence_samples = 0;
  size_t pcm = 0;
  bool speech = false;
  int16_t frame[256];

  while (true) {
    size_t n = voice_read(frame, sizeof(frame) / sizeof(frame[0]));
    if (n == 0) {
      // The microphone can stall (radio contention, a dead capture task's
      // predecessor). The wall clock is the backstop so a capture can never
      // hold this task, and the ring's consumer, forever.
      if (millis() - started >= JH_UTTER_MAX_MS) {
        break;
      }
      vTaskDelay(pdMS_TO_TICKS(5));
      continue;
    }

    int64_t sq = 0;
    for (size_t i = 0; i < n; i++) {
      sq += (int32_t)frame[i] * (int32_t)frame[i];
    }
    uint32_t rms = (uint32_t)sqrtf((float)sq / (float)(n ? n : 1));
    bool loud = (rms >= JH_UTTER_RMS_FLOOR);

    if (!speech) {
      // The pause between "hey jawn" and the question is not part of the clip.
      // Wait for the first frame over the floor, then start copying with it.
      if (!loud) {
        total_samples += (uint32_t)n;
        if (millis() - started >= JH_UTTER_MAX_MS || total_samples >= JH_UTTER_MAX_SAMPLES) {
          break;
        }
        continue;
      }
      speech = true;
      jh_log("[utter] speech started (rms=%u floor=%u)", (unsigned)rms,
             (unsigned)JH_UTTER_RMS_FLOOR);
    }

    size_t room = (size_t)JH_UTTER_MAX_SAMPLES - pcm / 2;
    size_t take = n < room ? n : room;
    memcpy(wav + 44 + pcm, frame, take * 2);
    pcm += take * 2;
    total_samples += (uint32_t)n;

    // End on the first of: the quiet gap after speech, the sample ceiling, or
    // the wall clock. The deck also arms a lead window for a command after a
    // pause; phase 0 keeps the simpler 450 ms rule and accepts that a phrase
    // tail leaking past the drain could end a very late question early.
    silence_samples = loud ? 0 : silence_samples + (uint32_t)n;
    if (pcm / 2 >= (size_t)JH_UTTER_MAX_SAMPLES ||
        silence_samples >= silence_end ||
        millis() - started >= JH_UTTER_MAX_MS) {
      break;
    }
  }

  if (pcm) {
    utter_wav_header(wav, (uint32_t)pcm);
    jh_log("[utter] captured %u bytes (%u ms)", (unsigned)pcm,
           (unsigned)(pcm / 2 * 1000 / JH_UTTER_RATE));
    utter_post(wav, 44 + pcm);
  }
  else {
    jh_log("[utter] no speech after the wake word; nothing to post");
  }

  free(wav);
  jh_utter_busy = false;
  vTaskDelete(NULL);
}

// Called by voice_task the moment the wake word fires. It drains the phrase
// tail already buffered, sets the single-capture latch and starts the consumer.
// Returns true when the wake frame itself must stay out of the ring.
bool utterance_arm() {
  if (jh_utter_busy) {
    jh_log("[utter] already capturing; wake ignored");
    return false;
  }
  // The camera's frame buffer and this clip both live in PSRAM. Nothing starts
  // a snap from the wake word (jh_10_voice_in.ino says why), but jh.snap can
  // arrive at any time, so the two entrants refuse each other rather than
  // proving on a bench that 8 MB is enough for both at once.
  if (camera_busy()) {
    jh_log("[utter] camera busy; wake ignored");
    return false;
  }

  // Claim the arena before the drain: the loop task can ask for a snap at any
  // moment, and camera_request_snap() checks this same latch.
  jh_utter_busy = true;

  // Whatever the ring holds now is the tail of the phrase that just fired. It
  // is not the command, so it is discarded; the capture starts at the next
  // frame the microphone produces. This runs on voice_task, before the consumer
  // exists, so there is no second reader to race with the drain. The scratch is
  // static because this task's 4 KB stack already carries the model inference.
  static int16_t discard[128];
  while (voice_read(discard, sizeof(discard) / sizeof(discard[0])) > 0) {
  }

  if (xTaskCreatePinnedToCore(utterance_task, "jh-utter", 12288, NULL, 1, NULL, 0) != pdPASS) {
    jh_utter_busy = false;
    jh_log("[utter] no capture task");
    return false;
  }
  jh_log("[utter] capturing after the wake word");
  return true;
}

bool utterance_busy() {
  return jh_utter_busy;
}

// ---- the house's answer -----------------------------------------------------
void utterance_reply_text(const String &text) {
  // There is no on-device TTS, and this transducer plays samples, not words.
  // The text is logged so the bench can read the answer; it cannot be heard
  // until the house's audio forms below arrive (or phase 1 adds a voice).
  jh_log("[say] %s", text.length() ? text.c_str() : "(empty)");
}

// Pull the one-shot WAV the house rendered for this answer. The id is the
// capability: the route needs no Now Me pair (perl/watch.pl's reply_audio), and
// the file is deleted once sent. The fetch blocks, so it gets its own task.
static void utter_fetch_task(void *arg) {
  String url = *(String *)arg;
  delete (String *)arg;
  jh_log("[say] fetching reply %s", url.c_str());

  HTTPClient http;
  WiFiClientSecure secure;
  WiFiClient plain;
  bool tls = url.startsWith("https://");
  bool began = false;
  if (tls) {
    secure.setCACert(HOUSE_CA_PEM);
    began = http.begin(secure, url);
  }
  else {
    began = http.begin(plain, url);
  }
  if (!began) {
    jh_log("[say] bad reply url");
    jh_fetch_busy = false;
    vTaskDelete(NULL);
    return;
  }

  http.setTimeout(8000);
  int code = http.GET();
  if (code == 200) {
    int size = http.getSize();
    if (size > 44) {
      uint8_t *wav = (uint8_t *)ps_malloc((size_t)size);
      if (!wav) {
        wav = (uint8_t *)malloc((size_t)size);
      }
      if (wav) {
        WiFiClient *stream = http.getStreamPtr();
        size_t got = 0;
        uint32_t started = millis();
        // The response is a file asset with a Content-Length, but read the
        // stream rather than assuming it arrived whole: a short read played as
        // a WAV would click or stop halfway.
        while (got < (size_t)size && millis() - started < 15000) {
          int avail = stream->available();
          if (avail > 0) {
            size_t want = (size_t)size - got;
            if ((size_t)avail < want) {
              want = (size_t)avail;
            }
            int r = stream->readBytes(wav + got, want);
            if (r <= 0) {
              break;
            }
            got += (size_t)r;
          }
          else if (!stream->connected()) {
            break;
          }
          else {
            delay(2);
          }
        }
        http.end();
        bool played = (got > 44) && audio_play_wav(wav, got);
        jh_log("[say] reply %u/%d bytes, play %s", (unsigned)got, size,
               played ? "started" : "failed");
        free(wav);
      }
      else {
        http.end();
        jh_log("[say] no %d-byte buffer for the reply", size);
      }
    }
    else {
      http.end();
      jh_log("[say] reply has no usable length (%d)", size);
    }
  }
  else {
    jh_log("[say] reply fetch http %d", code);
    http.end();
  }

  jh_fetch_busy = false;
  vTaskDelete(NULL);
}

void utterance_reply_audio_ready(const String &id, const String &base) {
  if (!id.length() || !base.length()) {
    jh_log("[say] audio ready without id/base; ignored");
    return;
  }
  if (jh_fetch_busy) {
    jh_log("[say] a reply fetch is already running; dropped %s", id.c_str());
    return;
  }
  String *url = new String(base + "/watch/reply_audio?id=" + id);
  if (!url) {
    return;
  }
  jh_fetch_busy = true;
  if (xTaskCreatePinnedToCore(utter_fetch_task, "jh-reply", 12288, url, 1, NULL, 0) != pdPASS) {
    jh_fetch_busy = false;
    delete url;
    jh_log("[say] no reply task");
    return;
  }
  jh_log("[say] reply audio ready; pulling over WiFi");
}

static bool utter_say_reserve(size_t need) {
  if (need <= jh_say_cap) {
    return true;
  }
  if (need > (size_t)(4 * 1024 * 1024)) {
    jh_log("[say] BLE answer over 4 MB; dropped");
    return false;
  }
  size_t cap = jh_say_cap ? jh_say_cap : 16384;
  while (cap < need) {
    cap *= 2;
  }
  uint8_t *p = (uint8_t *)heap_caps_realloc(jh_say_pcm, cap, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!p) {
    jh_log("[say] no %u-byte PSRAM buffer for BLE audio", (unsigned)cap);
    return false;
  }
  jh_say_pcm = p;
  jh_say_cap = cap;
  return true;
}

static void utter_say_reset() {
  if (jh_say_pcm) {
    free(jh_say_pcm);
    jh_say_pcm = nullptr;
  }
  jh_say_cap = 0;
  jh_say_len = 0;
  jh_say_next_seq = 0;
}

// The BLE fallback: raw PCM in base64 parts. Parts arrive in seq order over one
// BLE link, so a gap means lost audio; play nothing rather than a sentence with
// a hole in it, and wait for the next answer.
void utterance_reply_audio(JSONVar &data) {
  if (JSON.typeof(data) != "object") {
    jh_log("[say] BLE audio without a data object");
    return;
  }
  uint32_t seq = (uint32_t)(int)data["seq"];
  bool last = ((int)data["last"]) != 0;
  uint32_t rate = (uint32_t)(int)data["rate"];
  if (rate < 4000 || rate > 96000) {
    rate = 8000;
  }

  // A new stream is the only thing that clears a broken one. Until then, keep
  // consuming the remaining parts (so they do not look like fresh gaps) but
  // build nothing, and clear the latch on the closing part.
  if (seq == 0) {
    utter_say_reset();
    jh_say_drop = false;
    jh_say_rate = rate;
  }
  if (jh_say_drop) {
    if (last) {
      jh_log("[say] BLE answer dropped (a part did not decode)");
      jh_say_drop = false;
    }
    return;
  }
  if (seq != jh_say_next_seq) {
    jh_log("[say] BLE audio gap (seq %u, wanted %u); stream dropped", (unsigned)seq,
           (unsigned)jh_say_next_seq);
    utter_say_reset();
    jh_say_drop = true;
    return;
  }
  jh_say_next_seq = seq + 1;

  if (!last) {
    String b64 = ble_json_string(data, "audio");
    size_t add = 0;
    uint8_t *chunk = b64.length() ? decode_base64(b64, &add) : nullptr;
    if (!chunk || !add) {
      jh_log("[say] BLE audio part %u did not decode", (unsigned)seq);
      free(chunk);
      utter_say_reset();
      jh_say_drop = true;
      return;
    }
    if (!utter_say_reserve(jh_say_len + add)) {
      free(chunk);
      utter_say_reset();
      jh_say_drop = true;
      return;   // reserve already logged; the rest of this stream is unusable
    }
    memcpy(jh_say_pcm + jh_say_len, chunk, add);
    jh_say_len += add;
    free(chunk);
    return;
  }

  // last: the sender's final part carries no audio, only the close.
  if (jh_say_pcm && jh_say_len > 8) {
    jh_log("[say] BLE answer %u bytes at %u Hz", (unsigned)jh_say_len, (unsigned)jh_say_rate);
    if (!audio_play_pcm(jh_say_pcm, jh_say_len, jh_say_rate)) {
      jh_log("[say] speaker refused the BLE answer");
    }
  }
  else {
    jh_log("[say] BLE answer was empty");
  }
  utter_say_reset();
}
