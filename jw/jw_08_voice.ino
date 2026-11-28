// ---- voice commands: a VAD-gated clip sent to the homebase ----------------
// The watch is hands-free if it listens by itself, but only while there is
// speech: the microphone is read in short frames, a run of frames above the
// energy floor starts a recording, and the recording ends once the voice has
// been quiet for a moment (or it grows past a cap). The clip leaves for the
// homebase - over the BLE bridge when one is attached, otherwise as a POST to
// /watch/voice - where whisper transcribes it and acts on "jawn ..."; the watch
// hears the result only as the toggle that comes back.
// Off unless the user arms it in Configure > System, so it never competes with
// a normal record.
#define VOICE_FRAME_MS 30
#define VOICE_FRAME_SAMPLES ((int)(MIC_I2S_SAMPLE_RATE / 1000 * VOICE_FRAME_MS))
#define VOICE_ONSET_FRAMES 4         // held-energy frames before a capture commits (a lone loud frame is the room, not a word)
#define VOICE_SILENCE_MS 450         // trailing quiet that ends a command
#define VOICE_MAX_MS 6000            // a command, not a lecture
#define VOICE_MIN_MS 300             // shorter than a word is a cough
#define VOICE_WAKE_RMS_FLOOR 400     // fallback end floor, for the first frames before the room has been read
#define VOICE_AUTO_MARGIN 120        // the 'auto' floor holds at least this far above the room it read
#define VOICE_AUTO_DIVIDER 8         // ... and a further eighth of the room's own level, so a loud room scales
#define VOICE_AMBIENT_RISE 8         // the most the room estimate may climb in one 30 ms frame: a voice cannot drag it up faster
#define VOICE_FLOOR_MAX 12000        // a very loud room must not push the floor past a shout
#define VOICE_COMMAND_MS 900         // a burst this long is the phrase and the command run together, not the phrase alone
#define VOICE_GAP_MS 200             // a burst that begins after this much quiet is the command, not the tail of the phrase
#define VOICE_LEAD_MS 2000           // a wake capture with no command at all gives up after this much quiet
#define VOICE_BLE_CHUNK 384          // base64 chars per notify; with the "<i>/<n>:" prefix and the JSON head this stays under the MTU-3 notify limit
#define VOICE_BLE_PACE_MS 45         // between parts: ~one per connection interval, so the controller queue does not overflow and drop parts
#define VOICE_SAMPLE_RATE 8000       // the BLE/live-stream rate: half the mic's, for the slow path

// The frame RMS a wake capture holds above once the voice has stopped: the room's
// own level - measured by voice_ambient_rms while nothing was being captured -
// plus a margin, or the number the panel pinned. This is the figure that decides
// a capture has ended, so it must sit above the watch's own tone (which never
// goes away) and below a spoken word. A VAD capture reads its model instead and
// needs no floor at all.
static uint32_t voice_end_floor() {
  if (voice_floor.length() && voice_floor != "auto" && voice_floor != "off") {
    uint32_t manual = (uint32_t)voice_floor.toInt();
    if (manual) { return manual; }
  }
  if (!voice_ambient_rms) { return VOICE_WAKE_RMS_FLOOR; }
  uint32_t margin = voice_ambient_rms / VOICE_AUTO_DIVIDER;
  if (margin < VOICE_AUTO_MARGIN) { margin = VOICE_AUTO_MARGIN; }
  uint32_t f = voice_ambient_rms + margin;
  if (f > VOICE_FLOOR_MAX) { f = VOICE_FLOOR_MAX; }
  return f;
}

// The microphone arrives on a pedestal: a steady ~1500 of a possible 32768 rides
// on every sample. It is board and codec offset, not sound - but it is not
// invisible to the two things that read these frames. The wake model's front-end
// turns them into log-mel features, where the pedestal is a term that dwarfs the
// speech: the model read about 5% on a phrase it should read 90% on, so "hey jawn"
// only landed when it was spoken right into the microphone. And every level test
// saw a room that never went quiet. One pole of high pass takes the pedestal off
// before either of them sees it, and the clip that ships is centred the way a
// transcriber expects.
static float voice_dc_x1 = 0.0f, voice_dc_y1 = 0.0f;
static bool voice_dc_primed = false;
static int64_t voice_dc_sum = 0;      // for the debug line: the pedestal as it arrives
static uint32_t voice_dc_n = 0;
static void voice_dc_reset() {
  voice_dc_x1 = voice_dc_y1 = 0.0f;
  voice_dc_primed = false;
  voice_dc_sum = 0;
  voice_dc_n = 0;
}
static void voice_dc_block(int16_t *s, int n) {
  const float R = 0.995f;             // ~13 Hz corner at 16 kHz, far below speech
  for (int i = 0; i < n; i++) {
    float x = (float)s[i];
    if (voiceDbg) { voice_dc_sum += s[i]; }
    if (!voice_dc_primed) {
      // start level with the first sample, so the pedestal is never a step in
      voice_dc_x1 = x;
      voice_dc_y1 = 0.0f;
      voice_dc_primed = true;
    }
    float y = x - voice_dc_x1 + R * voice_dc_y1;
    voice_dc_x1 = x;
    voice_dc_y1 = y;
    // a transient can overshoot what the sample type holds; wrap-around there
    // would be heard as a click, so clamp instead
    if (y > 32767.0f) { y = 32767.0f; }
    else if (y < -32768.0f) { y = -32768.0f; }
    s[i] = (int16_t)y;
  }
  if (voiceDbg) { voice_dc_n += n; }
}

// POST the finished clip to the homebase. Streamed from flash: the WAV is tens
// of KB, well past what the TLS stack wants held in RAM.
static bool voice_post_clip(const String &path, long ts, const char *mode) {
  if (homebaseIP.length() == 0 || authorization.length() == 0) {
    Serial.printf("[voice] post mode=%s skipped: no homebase (%u) or authorization (%u)\n",
                  mode, (unsigned)homebaseIP.length(), (unsigned)authorization.length());
    return false;
  }
  // A person just spoke: a fresh clip gets its attempt even if a background
  // fetch marked the homebase down. The 4 s timeout bounds the cost, and the
  // retry window is what makes a slow join survivable.
  File f = FFat.open(path.c_str(), FILE_READ);
  if (!f) {
    Serial.printf("[voice] post mode=%s skipped: clip open failed (%s)\n", mode, path.c_str());
    return false;
  }
  // The body's size and the mode are the whole request; the URL carries the
  // authorization token, so it is never printed.
  Serial.printf("[voice] post mode=%s ts=%ld bytes=%u\n", mode, ts, (unsigned)f.size());
  WiFiClientSecure client;
  client.setCACert(HOUSE_CA_PEM);
  Serial.printf("[voice] post mode=%s heap free=%u max=%u\n", mode,
                (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getMaxAllocHeap());
  String url = "https://" + homebaseIP + "/watch/voice?edt=watch"
    + "&chip_id=" + chip_id_maker()
    + "&authorization=" + urlEncode(authorization)
    + "&voice=" + String(mode)
    + "&timestamp=" + String(ts);
  bool ok = false;
  bool reached = false;
  // A connect can be refused while the radio is still settling after the
  // capture's join: the same POST succeeds minutes later at sleep. One short
  // retry (rewinding the file) turns that into WiFi instead of a whole clip
  // over the slower BLE link.
  for (int attempt = 1; attempt <= 2 && !ok && !reached; attempt++) {
    if (attempt > 1) { vTaskDelay(pdMS_TO_TICKS(300)); }
    HTTPClient https;
    // The house's watch listener can answer a room fetch in five seconds when it
    // is busy; a four-second POST timed out every clip (-1) while the same port
    // served GETs. Long enough for a busy listener, still bounded. The connect
    // has its own deadline (5 s by default), and that - not the read timeout - is
    // what a listener still finishing a room render blows through.
    https.setTimeout(12000);
    https.setConnectTimeout(12000);
    if (https.begin(client, url)) {
      https.addHeader("Content-Type", "application/octet-stream");
      int code = https.sendRequest("POST", &f, (size_t)f.size());
      Serial.printf("[voice] post mode=%s -> %d (wifi=%d, attempt %d)\n",
                    mode, code, (int)WiFi.status(), attempt);
      // Only 2xx means the house took the body. A 403 (auth) or 400 (unusable
      // body) is a failure like any other: keep the clip for the bounded retry
      // and let the caller fall back to the other transport. A 4xx still proves
      // the homebase is reachable, so it must not mark it down.
      reached = code > 0;
      ok = (code >= 200 && code < 300);
      https.end();
    }
    else {
      char err[96] = {0};
      client.lastError(err, sizeof(err));
      Serial.printf("[voice] post mode=%s begin failed (tls=%s heap free=%u max=%u, attempt %d)\n",
                    mode, err, (unsigned)ESP.getFreeHeap(),
                    (unsigned)ESP.getMaxAllocHeap(), attempt);
    }
    if (!reached && !ok && f) { f.seek(0, SeekSet); }
  }
  homebase_down_until = (ok || reached) ? 0 : millis() + 20000;
  f.close();
  return ok;
}

// Ship a finished clip over the BLE link. The bridge frames the daemon -> watch
// direction on its own, but the watch must frame this one: "<i>/<n>:" + part,
// the same shape ble_frame_ingest expects, so the bridge reassembles it and
// hands the server one JSON envelope. The clip rides base64 so the whole
// message stays text on the wire; the server base64-decodes it. Sent in
// VOICE_BLE_CHUNK-sized pieces so neither side holds the whole clip at once -
// the WAV can run ~190 KB and base64 a third larger again.
static bool voice_ble_notify(String &part) {
  if (!ble_link_ready()) {
    return false;
  }
  // Each part must fit the notify limit (MTU - 3): an oversized part is rejected
  // outright and the characteristic keeps its old value, which silently loses
  // that part. VOICE_BLE_CHUNK is sized so the JSON head in part 0 still fits.
  //
  // Bluedroid gives us no backpressure (notify() is void and the controller's
  // per-connection packet count is not exported to the Arduino core), so pace
  // the parts out generously instead: one part per connection interval or so,
  // which is why a 20 ms pace used to outrun the link and leave parts missing
  // ("never arrived"). A whole clip a touch slower beats a fast holed one. If a
  // clip still arrives incomplete the caller retries it whole.
  pTxCharacteristic->setValue((uint8_t *)part.c_str(), part.length());
  pTxCharacteristic->notify();
  delay(VOICE_BLE_PACE_MS);
  return true;
}

static bool voice_ble_send(const String &path, long ts, const char *mode) {
  if (!ble_link_ready()) {
    return false;
  }
  File f = FFat.open(path.c_str(), FILE_READ);
  if (!f) {
    return false;
  }
  size_t size = f.size();
  if (size == 0) {
    f.close();
    return false;
  }
  size_t b64_len = ((size + 2) / 3) * 4;
  int total = (int)((b64_len + VOICE_BLE_CHUNK - 1) / VOICE_BLE_CHUNK);
  if (total < 1) { total = 1; }
  Serial.printf("[voice] ble send mode=%s ts=%ld bytes=%u parts=%d\n",
                mode, ts, (unsigned)size, total);
  static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  String head = "{\"type\":\"voice\",\"chip_id\":\"" + chip_id_maker() + "\",\"edt\":\"watch\",\"ts\":" + String(ts) + ",\"voice\":\"" + String(mode) + "\",\"data\":\"";
  String out = String(0) + "/" + String(total) + ":" + head;
  int in_chunk = 0;
  int index = 0;
  uint8_t b[3];
  bool ok = true;
  while (ok) {
    int got = f.read(b, 3);
    if (got <= 0) {
      break;
    }
    if (got == 3) {
      out += tbl[(b[0] >> 2) & 0x3f];
      out += tbl[((b[0] & 0x03) << 4) | ((b[1] >> 4) & 0x0f)];
      out += tbl[((b[1] & 0x0f) << 2) | ((b[2] >> 6) & 0x03)];
      out += tbl[b[2] & 0x3f];
    }
    else if (got == 1) {
      out += tbl[(b[0] >> 2) & 0x3f];
      out += tbl[((b[0] & 0x03) << 4) & 0x3f];
      out += '=';
      out += '=';
    }
    else {
      out += tbl[(b[0] >> 2) & 0x3f];
      out += tbl[((b[0] & 0x03) << 4) | ((b[1] >> 4) & 0x0f)];
      out += tbl[((b[1] & 0x0f) << 2) & 0x3f];
      out += '=';
    }
    in_chunk += 4;
    // a full part goes out only while more of the clip follows, so the JSON
    // tail lands in the last part instead of an extra empty one
    if (in_chunk >= VOICE_BLE_CHUNK && f.available() > 0) {
      ok = voice_ble_notify(out);
      index++;
      out = String(index) + "/" + String(total) + ":";
      in_chunk = 0;
    }
    if (got != 3) {
      break;   // a padded final group ends the stream
    }
  }
  out += "\"}";
  if (ok) {
    ok = voice_ble_notify(out);
  }
  f.close();
  Serial.printf("[voice] ble send mode=%s done %s\n", mode, ok ? "ok" : "short");
  return ok;
}

// Compress the recorded clip to an IMA ADPCM WAV (~4:1) before shipping. The
// server's whisper_transcribe() pipes the clip through ffmpeg, which reads IMA
// ADPCM WAV natively, so the server needs no change. Fixed 1024-byte blocks,
// each a 4-byte header (int16 LE predictor, step index, reserved) then 4-bit
// nibbles - the layout ffmpeg writes itself (verified against its output).
#define VOICE_ADPCM_BLOCK 1024
#define VOICE_ADPCM_SPB ((VOICE_ADPCM_BLOCK - 4) * 2 + 1)   // 2041 samples/block

static const int32_t voice_adpcm_step[89] = {
  7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,
  50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,
  337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,
  2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,
  12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767 };
static const int8_t voice_adpcm_index[16] = { -1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8 };

static void voice_wr16(uint8_t *p, uint16_t v) { p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; }
static void voice_wr32(uint8_t *p, uint32_t v) { p[0]=v&0xff; p[1]=(v>>8)&0xff; p[2]=(v>>16)&0xff; p[3]=(v>>24)&0xff; }

// ---- streaming the clip up while it is still being recorded ---------------
// The same IMA ADPCM the whole-clip path ships, encoded as the samples arrive
// instead of after the fact: the parts are on their way while the person is
// still speaking, so the server holds the clip the moment they stop rather than
// a second or two later. The server reassembles the parts and wraps them in the
// 60-byte WAV header (the very file the whole-clip path sends), so the ingest is
// unchanged. Encoding happens in the capture task; sending does not - a part is
// a burst of paced notifies, and pacing them from the capture task would stall
// the microphone and drop audio.
#define VOICE_STREAM_PART 4096        // encoded bytes per part (base64 ~5.5 KB)
#define VOICE_STREAM_SLACK 8192       // encoder-to-sender slack (~2 s of speech)
#define VOICE_STREAM_PACE_MS 25       // per notify inside a part
static StreamBufferHandle_t voice_stream = nullptr;
static volatile bool voice_stream_run = false;    // the sender task is alive
static volatile bool voice_stream_stop = false;   // capture over: flush and finish
static volatile bool voice_stream_dead = false;   // aborted: send nothing more
static unsigned voice_stream_seq = 0;
static int16_t voice_sblk[VOICE_ADPCM_SPB];       // samples of the block being built
static int voice_sblk_have = 0;
static uint8_t voice_spart[VOICE_STREAM_PART + VOICE_ADPCM_BLOCK];
static unsigned voice_spart_len = 0;

// base64, appended (the same table voice_ble_send uses)
static void voice_b64_append(String &out, const uint8_t *p, unsigned len) {
  static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  for (unsigned i = 0; i < len; i += 3) {
    unsigned rem = len - i;
    uint8_t b0 = p[i];
    out += tbl[(b0 >> 2) & 0x3f];
    if (rem == 1) {
      out += tbl[((b0 & 0x03) << 4) & 0x3f];
      out += '=';
      out += '=';
    }
    else {
      uint8_t b1 = p[i + 1];
      out += tbl[((b0 & 0x03) << 4) | ((b1 >> 4) & 0x0f)];
      if (rem == 2) {
        out += tbl[((b1 & 0x0f) << 2) & 0x3f];
        out += '=';
      }
      else {
        uint8_t b2 = p[i + 2];
        out += tbl[((b1 & 0x0f) << 2) | ((b2 >> 6) & 0x03)];
        out += tbl[b2 & 0x3f];
      }
    }
  }
}

// One part out: the encoded bytes gathered so far, with the clip's identity and a
// last flag on the final one. Paced (Bluedroid gives no backpressure, and an
// unpaced burst is what leaves parts missing). Runs on the sender task only - the
// capture task never waits on the radio.
static void voice_stream_send(bool last) {
  // The live stream is always the folded 8 kHz copy, whatever the whole-file
  // path does, so its header rate is fixed at 8000 - and a watch that predates
  // the field simply omits it, which the server reads as 8000 as well.
  String msg = "{\"type\":\"voice_stream\",\"chip_id\":\"" + chip_id_maker()
    + "\",\"edt\":\"watch\",\"ts\":" + String((long)voice_clip_ts)
    + ",\"voice\":\"" + voice_mode_name + "\",\"rate\":8000,\"seq\":" + String(voice_stream_seq)
    + ",\"last\":" + (last ? "1" : "0") + ",\"audio\":\"";
  voice_b64_append(msg, voice_spart, voice_spart_len);
  msg += "\"}";
  voice_stream_seq++;
  voice_spart_len = 0;
  if (!ble_link_ready()) {
    return;   // nothing to send on; the whole-clip fallback covers this clip
  }
  ble_notify_payload(msg, VOICE_STREAM_PACE_MS);
}

// Hand encoded bytes to the sender task. If the link has fallen behind the
// speaking there is nowhere for them to go: abandon the stream outright (no
// last flag, so the server never assembles a truncated clip) and let the
// whole-clip path send it after the capture, as it always did.
static void voice_stream_push(const uint8_t *p, unsigned len) {
  if (!voice_stream || voice_stream_dead) { return; }
  size_t sent = 0;
  while (sent < len) {
    size_t n = xStreamBufferSend(voice_stream, p + sent, len - sent, pdMS_TO_TICKS(20));
    if (!n) {
      Serial.println("[voice] stream fell behind the speech; leaving the clip to the file path");
      voice_stream_dead = true;
      return;
    }
    sent += n;
  }
}

// Encode `count` samples into one 1024-byte IMA ADPCM block and return the bytes
// written (padded). Each block carries its own predictor and step index (the
// layout ffmpeg reads), so a block boundary is a safe place to split for the
// wire - the BLE stream and the Com WiFi upload both rely on that.
static int voice_adpcm_block(const int16_t *samples, int count, uint8_t *blk) {
  int32_t pred = samples[0];
  int index = 0;
  int at = 0;
  blk[at++] = (uint8_t)(pred & 0xff);
  blk[at++] = (uint8_t)((pred >> 8) & 0xff);
  blk[at++] = 0;
  blk[at++] = 0;
  int nib_have = 0;
  uint8_t pending = 0;
  for (int i = 1; i < count; i++) {
    int32_t step = voice_adpcm_step[index];
    int32_t diff = (int32_t)samples[i] - pred;
    uint8_t nib = 0;
    if (diff < 0) { nib = 8; diff = -diff; }
    if (diff >= step) { nib |= 4; diff -= step; }
    if (diff >= (step >> 1)) { nib |= 2; diff -= (step >> 1); }
    if (diff >= (step >> 2)) { nib |= 1; }
    int32_t diffq = step >> 3;
    if (nib & 4) { diffq += step; }
    if (nib & 2) { diffq += step >> 1; }
    if (nib & 1) { diffq += step >> 2; }
    pred = (nib & 8) ? pred - diffq : pred + diffq;
    if (pred > 32767) { pred = 32767; } else if (pred < -32768) { pred = -32768; }
    index += voice_adpcm_index[nib];
    if (index < 0) { index = 0; } else if (index > 88) { index = 88; }
    if (!nib_have) { pending = nib; nib_have = 1; }
    else { blk[at++] = pending | (nib << 4); nib_have = 0; }
  }
  if (nib_have) { blk[at++] = pending; }
  while (at < VOICE_ADPCM_BLOCK) { blk[at++] = 0; }   // pad, as the file path does
  return at;
}

// Encode the samples held for one block and hand it to the BLE sender.
static void voice_stream_encode_block() {
  int count = voice_sblk_have;
  voice_sblk_have = 0;
  if (count < 2) { return; }
  uint8_t blk[VOICE_ADPCM_BLOCK];
  int at = voice_adpcm_block(voice_sblk, count, blk);
  voice_stream_push(blk, at);
}

// The capture's 8 kHz samples in, with whatever complete blocks that makes on
// their way to the sender task. Never blocks on the radio.
static void voice_stream_feed(const int16_t *samples, int n) {
  if (!voice_stream_run || voice_stream_dead) { return; }
  for (int i = 0; i < n; i++) {
    voice_sblk[voice_sblk_have++] = samples[i];
    if (voice_sblk_have >= VOICE_ADPCM_SPB) { voice_stream_encode_block(); }
  }
}

static void voice_stream_task(void *pv) {
  while (true) {
    size_t n = 0;
    if (voice_stream && !voice_stream_dead) {
      n = xStreamBufferReceive(voice_stream, voice_spart + voice_spart_len,
                               sizeof(voice_spart) - voice_spart_len, pdMS_TO_TICKS(100));
    }
    voice_spart_len += n;
    bool drained = !voice_stream || xStreamBufferIsEmpty(voice_stream);
    if (voice_stream_dead) { break; }
    if (voice_spart_len >= VOICE_STREAM_PART || (voice_stream_stop && n == 0 && drained)) {
      voice_stream_send(voice_stream_stop && drained);
      if (voice_stream_stop && drained) { break; }
    }
    vTaskDelay(pdMS_TO_TICKS(5));
  }
  if (voice_stream) { xStreamBufferReset(voice_stream); }
  voice_stream_run = false;
  vTaskDelete(NULL);
}

// Begin streaming for the capture that is starting. Best effort: with no link, or
// no room for the buffers, the capture carries on and the whole-clip path ships
// it afterwards exactly as before.
static void voice_stream_begin() {
  if (voice_stream_run) { return; }
  if (!bt_enabled) { return; }
  if (!voice_stream) {
    voice_stream = xStreamBufferCreate(VOICE_STREAM_SLACK, 64);
    if (!voice_stream) { return; }
  }
  xStreamBufferReset(voice_stream);
  voice_stream_seq = 0;
  voice_sblk_have = 0;
  voice_spart_len = 0;
  voice_stream_stop = false;
  voice_stream_dead = false;
  voice_stream_run = true;
  xTaskCreatePinnedToCore(voice_stream_task, "VoiceStream", 4096, NULL, 2, NULL, 1);
}

// Capture over: encode the tail and let the sender finish (its last part is the
// only thing that tells the server the clip is whole).
static void voice_stream_end() {
  if (!voice_stream_run) { return; }
  voice_stream_encode_block();   // the partial final block
  voice_stream_stop = true;
}

// ---- Com: upload the push-to-talk clip while it is being spoken -----------
// A Com command is uploaded over WiFi in 1024-byte IMA ADPCM blocks as the mic
// fills them, so the house has the audio the moment the button is released.
// Each block is one POST; the block that turns out to be last carries last=1
// (an empty final chunk when the last data block was already full), and the
// house assembles the session and runs the same voice_ingest. The whole-file
// POST over /watch/voice (then BLE) remains the fallback when WiFi is down or
// any chunk fails. Rec memos stay whole-file: they are not spoken live.
//
// The stream is folded to 8 kHz, the rate the BLE path already uses and the one
// the house reads. Every block has its own predictor and step index, so block
// boundaries are safe split points.
#define COM_STREAM_QUEUE 6
#define COM_STREAM_TIMEOUT_MS 12000
#define COM_STREAM_DRAIN_MS 20000
static QueueHandle_t com_stream_q = nullptr;
static String com_stream_base;                       // URL without seq/last
static String com_stream_session;
static volatile bool com_stream_active = false;      // the capture is feeding it
static volatile bool com_stream_done = false;        // capture ended: flush, close
static volatile bool com_stream_abort_requested = false;  // never send a last chunk
static volatile bool com_stream_failed = false;      // a chunk failed: fall back
static volatile bool com_stream_ok = false;          // every chunk landed
static volatile bool com_stream_sender_alive = false;
static volatile unsigned com_stream_seq = 0;
static volatile unsigned com_stream_chunks = 0;
static volatile unsigned com_stream_queued = 0;   // blocks handed to the upload task
static int16_t com_sblk[VOICE_ADPCM_SPB];
static int com_sblk_have = 0;

static bool com_stream_post(WiFiClientSecure &client, const uint8_t *data, unsigned len, bool last) {
  String url = com_stream_base + "&seq=" + String(com_stream_seq)
    + "&last=" + (last ? "1" : "0");
  HTTPClient https;
  https.setTimeout(COM_STREAM_TIMEOUT_MS);
  https.setConnectTimeout(12000);
  bool ok = false;
  if (https.begin(client, url)) {
    https.addHeader("Content-Type", "application/octet-stream");
    int code = (data && len) ? https.POST((uint8_t *)data, len) : https.POST((uint8_t *)"", 0);
    ok = (code >= 200 && code < 300);
    Serial.printf("[voice] com stream chunk seq=%u bytes=%u last=%d -> %d\n",
                  (unsigned)com_stream_seq, len, last ? 1 : 0, code);
    https.end();
  }
  else {
    Serial.printf("[voice] com stream chunk seq=%u begin failed (wifi=%d)\n",
                  (unsigned)com_stream_seq, (int)WiFi.status());
  }
  if (ok) { com_stream_seq++; }
  return ok;
}

static void com_stream_task(void *pv) {
  uint8_t pend[VOICE_ADPCM_BLOCK];
  bool have_pend = false;
  WiFiClientSecure client;
  client.setCACert(HOUSE_CA_PEM);
  bool logged_heap = false;
  while (true) {
    uint8_t blk[VOICE_ADPCM_BLOCK];
    if (!logged_heap && com_stream_seq == 0) {
      logged_heap = true;
      Serial.printf("[voice] com stream heap free=%u max=%u\n",
                    (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getMaxAllocHeap());
    }
    if (xQueueReceive(com_stream_q, blk, pdMS_TO_TICKS(100)) == pdTRUE) {
      // Hold one block back: only the next block (or the end) tells us this one
      // was not the last, and the last one must carry last=1.
      if (have_pend) {
        if (!com_stream_post(client, pend, sizeof(pend), false)) { com_stream_failed = true; break; }
        com_stream_chunks++;
      }
      memcpy(pend, blk, sizeof(pend));
      have_pend = true;
      if (com_stream_abort_requested) { break; }
      continue;
    }
    if (com_stream_abort_requested) { break; }
    if (com_stream_done) {
      if (have_pend) {
        if (!com_stream_post(client, pend, sizeof(pend), true)) { com_stream_failed = true; break; }
      }
      else {
        // safety net: no data block was held back, so an empty final chunk is
        // the only way to close the session
        if (!com_stream_post(client, nullptr, 0, true)) { com_stream_failed = true; break; }
      }
      com_stream_chunks++;
      break;
    }
  }
  if (com_stream_q) { xQueueReset(com_stream_q); }
  com_stream_ok = !com_stream_failed && !com_stream_abort_requested;
  com_stream_sender_alive = false;
  vTaskDelete(NULL);
}

// Start the WiFi upload for a Com capture. Best effort: with no WiFi, no
// homebase or no room for the queue the whole-file path covers the clip.
static void com_stream_begin(long ts) {
  if (com_stream_active || com_stream_sender_alive) { return; }
  if (WiFi.status() != WL_CONNECTED || homebaseIP.length() == 0 || authorization.length() == 0) {
    Serial.printf("[voice] com stream not started (wifi=%d homebase=%u auth=%u)\n",
                  (int)(WiFi.status() == WL_CONNECTED),
                  (unsigned)homebaseIP.length(), (unsigned)authorization.length());
    return;
  }
  if (!com_stream_q) {
    com_stream_q = xQueueCreate(COM_STREAM_QUEUE, VOICE_ADPCM_BLOCK);
    if (!com_stream_q) { Serial.println("[voice] com stream not started (no queue)"); return; }
  }
  xQueueReset(com_stream_q);
  // The session id must match [A-Za-z0-9_.-]{1,64}: the clip's epoch, a dash,
  // and the boot millis in hex.
  com_stream_session = String(ts) + "-" + String((unsigned long)millis(), HEX);
  com_stream_base = "https://" + homebaseIP + "/watch/voice/stream?edt=watch"
    + "&chip_id=" + chip_id_maker()
    + "&authorization=" + urlEncode(authorization)
    + "&voice=" + COMMAND_MODE
    + "&timestamp=" + String(ts)
    + "&session=" + com_stream_session;
  com_stream_active = true;
  com_stream_done = false;
  com_stream_abort_requested = false;
  com_stream_failed = false;
  com_stream_ok = false;
  com_stream_seq = 0;
  com_stream_chunks = 0;
  com_stream_queued = 0;
  com_sblk_have = 0;
  com_stream_sender_alive = true;
  Serial.printf("[voice] com stream begin session=%s ts=%ld\n", com_stream_session.c_str(), ts);
  if (xTaskCreatePinnedToCore(com_stream_task, "ComStream", 12288, NULL, 1, NULL, 0) != pdPASS) {
    Serial.println("[voice] com stream not started (no task)");
    com_stream_active = false;
    com_stream_sender_alive = false;
  }
}

// 8 kHz samples in, complete 1024-byte blocks on their way to the upload task.
// Never blocks the microphone for long; a full queue means the link is behind
// the speech, so the clip falls back to the whole-file path.
static void com_stream_feed(const int16_t *samples, int n) {
  if (!com_stream_active || com_stream_failed) { return; }
  for (int i = 0; i < n; i++) {
    com_sblk[com_sblk_have++] = samples[i];
    if (com_sblk_have >= VOICE_ADPCM_SPB) {
      uint8_t blk[VOICE_ADPCM_BLOCK];
      voice_adpcm_block(com_sblk, com_sblk_have, blk);
      com_sblk_have = 0;
      if (xQueueSend(com_stream_q, blk, pdMS_TO_TICKS(20)) != pdTRUE) {
        Serial.println("[voice] com stream fell behind the speech; whole file will be sent");
        com_stream_failed = true;
        com_stream_active = false;
        return;
      }
      com_stream_queued++;
    }
  }
}

// Capture over: flush the partial final block, close the session with last=1,
// and wait (bounded) for the uploads to finish. True means the house has the
// whole clip and the ship task can skip the whole-file POST.
static bool com_stream_end() {
  if (!com_stream_active && !com_stream_sender_alive) {
    if (com_stream_q) { vQueueDelete(com_stream_q); com_stream_q = nullptr; }
    return false;
  }
  if (!com_stream_failed && !com_stream_abort_requested) {
    if (com_sblk_have >= 2) {
      uint8_t blk[VOICE_ADPCM_BLOCK];
      voice_adpcm_block(com_sblk, com_sblk_have, blk);
      if (xQueueSend(com_stream_q, blk, pdMS_TO_TICKS(200)) != pdTRUE) {
        com_stream_failed = true;
      }
      else {
        com_stream_queued++;
      }
    }
  }
  if (!com_stream_failed && !com_stream_abort_requested && com_stream_queued == 0) {
    // A tap too short for one 1024-byte block: close nothing. A session with no
    // audio would only make the house ingest silence.
    Serial.println("[voice] com stream aborted (no blocks)");
    com_stream_abort_requested = true;
    if (com_stream_q) { xQueueReset(com_stream_q); }
  }
  com_sblk_have = 0;
  com_stream_active = false;
  com_stream_done = true;
  uint32_t t = millis();
  while (com_stream_sender_alive && millis() - t < COM_STREAM_DRAIN_MS) {
    vTaskDelay(20 / portTICK_PERIOD_MS);
  }
  if (com_stream_sender_alive) {
    Serial.println("[voice] com stream did not finish; whole file will be sent");
    com_stream_failed = true;
    com_stream_abort_requested = true;
  }
  bool ok = com_stream_ok && !com_stream_failed && !com_stream_abort_requested;
  Serial.printf("[voice] com stream %s chunks=%u session=%s\n",
                ok ? "ok" : "failed", (unsigned)com_stream_chunks, com_stream_session.c_str());
  // The upload task is gone and its queue is dead weight: a failed Com used to
  // leave it behind, and the 12 KB ship task the recorder starts next could not
  // be created, so the clip never fell back to BLE. Free it with the task.
  if (!com_stream_sender_alive && com_stream_q) {
    vQueueDelete(com_stream_q);
    com_stream_q = nullptr;
  }
  return ok;
}

// A silent or too-short capture: drop the session without its last chunk, so
// the house never assembles or ingests it.
static void com_stream_abort() {
  if (!com_stream_active && !com_stream_sender_alive) { return; }
  com_stream_abort_requested = true;
  com_stream_active = false;
  if (com_stream_q) { xQueueReset(com_stream_q); }
  uint32_t t = millis();
  while (com_stream_sender_alive && millis() - t < 2000) {
    vTaskDelay(20 / portTICK_PERIOD_MS);
  }
  com_stream_ok = false;
  com_stream_failed = true;
  Serial.printf("[voice] com stream aborted (chunks=%u)\n", (unsigned)com_stream_chunks);
  if (!com_stream_sender_alive && com_stream_q) {
    vQueueDelete(com_stream_q);
    com_stream_q = nullptr;
  }
}

// Capture over with nothing in it: abandon the stream rather than finish it. The
// last part is the only thing that tells the server a clip is whole - it ingests
// nothing before that - so the parts already sent are dropped unseen and age out
// of the bridge's half-clip sweep (see voice_stream in ble_message_processor).
static void voice_stream_abort() {
  if (!voice_stream_run) { return; }
  voice_stream_dead = true;
}

static bool voice_compress_clip(const String &in_path, const String &out_path, bool fold_half, uint32_t rate) {
  File in = FFat.open(in_path.c_str(), FILE_READ);
  if (!in || in.size() <= 44) { if (in) { in.close(); } return false; }
  uint32_t pcm_bytes = in.size() - 44;
  uint32_t in_samples = pcm_bytes / 2;
  // fold_half is the caller's choice: the Rec memo records at the mic's 16 kHz
  // and is folded here, while the listener hands over samples it has already
  // chosen to fold or not. rate is the rate of the bytes after that choice, and
  // the header below names it, so the file never disagrees with its samples.
  uint32_t samples = fold_half ? in_samples / 2 : in_samples;
  uint32_t blocks = (samples + VOICE_ADPCM_SPB - 1) / VOICE_ADPCM_SPB;
  uint32_t data_bytes = blocks * VOICE_ADPCM_BLOCK;
  uint32_t total = 60 + data_bytes;
  uint8_t *buf = (uint8_t *)ps_malloc(total);
  if (!buf) { buf = (uint8_t *)malloc(total); }
  if (!buf) { in.close(); return false; }
  uint32_t abps = (uint32_t)((uint64_t)rate * VOICE_ADPCM_BLOCK / VOICE_ADPCM_SPB);
  memcpy(buf, "RIFF", 4); voice_wr32(buf + 4, total - 8); memcpy(buf + 8, "WAVE", 4);
  memcpy(buf + 12, "fmt ", 4); voice_wr32(buf + 16, 20);
  voice_wr16(buf + 20, 0x11); voice_wr16(buf + 22, 1);
  voice_wr32(buf + 24, rate); voice_wr32(buf + 28, abps);
  voice_wr16(buf + 32, VOICE_ADPCM_BLOCK); voice_wr16(buf + 34, 4);
  voice_wr16(buf + 36, 2); voice_wr16(buf + 38, VOICE_ADPCM_SPB);
  memcpy(buf + 40, "fact", 4); voice_wr32(buf + 44, 4); voice_wr32(buf + 48, samples);
  memcpy(buf + 52, "data", 4); voice_wr32(buf + 56, data_bytes);
  in.seek(44);
  static int16_t blk[VOICE_ADPCM_SPB];
  int16_t pair[2];
  uint32_t o = 60;
  while (true) {
    int count = 0;
    while (count < VOICE_ADPCM_SPB) {
      if (fold_half) {
        int got = in.read((uint8_t *)pair, 4);   // two 16 kHz samples -> one 8 kHz
        if (got < 4) { break; }
        blk[count++] = (int16_t)(((int32_t)pair[0] + (int32_t)pair[1]) >> 1);
      }
      else {
        int got = in.read((uint8_t *)(blk + count), (VOICE_ADPCM_SPB - count) * 2);
        if (got <= 0) { break; }
        if (got % 2) { break; }        // a torn sample ends the clip
        count += got / 2;
      }
    }
    if (count < 2) { break; }
    uint32_t block_start = o;
    int32_t pred = blk[0];
    int index = 0;
    voice_wr16(buf + o, (uint16_t)pred); o += 2; buf[o++] = (uint8_t)index; buf[o++] = 0;
    int nib_have = 0; uint8_t pending = 0;
    for (int i = 1; i < count; i++) {
      int32_t step = voice_adpcm_step[index];
      int32_t diff = (int32_t)blk[i] - pred;
      uint8_t nib = 0;
      if (diff < 0) { nib = 8; diff = -diff; }
      if (diff >= step) { nib |= 4; diff -= step; }
      if (diff >= (step >> 1)) { nib |= 2; diff -= (step >> 1); }
      if (diff >= (step >> 2)) { nib |= 1; }
      int32_t diffq = step >> 3;
      if (nib & 4) { diffq += step; }
      if (nib & 2) { diffq += step >> 1; }
      if (nib & 1) { diffq += step >> 2; }
      pred = (nib & 8) ? pred - diffq : pred + diffq;
      if (pred > 32767) { pred = 32767; } else if (pred < -32768) { pred = -32768; }
      index += voice_adpcm_index[nib];
      if (index < 0) { index = 0; } else if (index > 88) { index = 88; }
      if (!nib_have) { pending = nib; nib_have = 1; }
      else { buf[o++] = pending | (nib << 4); nib_have = 0; }
    }
    if (nib_have) { buf[o++] = pending; }
    while (o - block_start < VOICE_ADPCM_BLOCK) { buf[o++] = 0; }   // pad the last block
    if (count < VOICE_ADPCM_SPB) { break; }
  }
  in.close();
  File out = FFat.open(out_path.c_str(), FILE_WRITE);
  if (!out) { free(buf); return false; }
  size_t wrote = out.write(buf, o);
  out.close();
  free(buf);
  Serial.printf("[voice] compressed clip %u -> %u bytes\n", (unsigned)pcm_bytes, (unsigned)wrote);
  return wrote == o;
}

// Collect the answer over WiFi when no BLE bridge can carry it. The house parks
// the words the moment they are ready and the rendered WAV id when the voice
// finishes (/watch/reply); each is handed over once. The ship task calls this
// after a clip that went over WiFi, so a watch with no bridge still shows and
// speaks the reply. Bounded on purpose: the UI loop keeps running while this
// background task polls.
static void wifi_reply_poll(uint32_t budget_ms) {
  if (WiFi.status() != WL_CONNECTED || homebaseIP.length() == 0 || authorization.length() == 0) {
    Serial.println("[say] reply poll skipped (no wifi/homebase/auth)");
    return;
  }
  uint32_t started = millis();
  bool got_text = false;
  bool got_audio = false;
  while (millis() - started < budget_ms) {
    String url = url_maker("https://" + homebaseIP + "/watch/reply?poll=1");
    String body = https_request(url);
    if (body.length()) {
      JSONVar r = JSON.parse(body);
      if (JSON.typeof(r) != "undefined") {
        if (r.hasOwnProperty("text")) {
          String t = (const char *)r["text"];
          if (t.length() && !got_text) {
            if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
              say_text = t;
              say_text_pending = true;
              xSemaphoreGive(taskMutex);
            }
            got_text = true;
            Serial.printf("[say] polled reply %u chars: %s\n", (unsigned)t.length(), t.c_str());
          }
        }
        if (r.hasOwnProperty("id")) {
          String id = (const char *)r["id"];
          String base = r.hasOwnProperty("base") ? (const char *)r["base"] : String("");
          if (id.length() && base.length() && !got_audio && WiFi.status() == WL_CONNECTED) {
            if (say_fetch_req) { delete say_fetch_req; }
            say_fetch_req = new String(base + "/watch/reply_audio?id=" + id);
            if (say_fetch_req) {
              say_fetch_pending = true;
              got_audio = true;
              Serial.println("[say] polled audio ready; fetching");
            }
          }
        }
      }
    }
    if (got_text && got_audio) { break; }
    vTaskDelay(600 / portTICK_PERIOD_MS);
  }
  Serial.printf("[say] reply poll done text=%d audio=%d\n", (int)got_text, (int)got_audio);
}

// Ship a clip by whichever radio is up: the BLE bridge first (the preferred
// radio, matching taps and steps), then a POST to the homebase over WiFi when
// there is no bridge. A clip is tens of KB, so over BLE it is hundreds of
// notifications and takes several seconds; keep the parts within the notify
// limit and the bridge reassembles it whole.
