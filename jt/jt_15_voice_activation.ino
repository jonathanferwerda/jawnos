// ---- voice activation: the watch's listener on the deck's TDM microphone ----
// The panel's voice_trigger setting names what starts a capture: 'vad' (the
// neural voice-activity model - capture on any speech) or a wake phrase whose
// model voice_models.h carries. This task reads the ES7210 through the same TDM
// channel micCaptureTask uses, hands the mono slot to the model frame by frame,
// and - when the model reads speech - buffers the utterance in PSRAM and ships
// it over the BLE bridge as a "voice" message, exactly as a manual recording is
// sent. Nothing touches the flash while the microphone is live (see
// micCaptureTask's note): the clip is written out once, when the utterance ends.
#define VOICE_FRAME_MS 30
#define VOICE_ONSET_FRAMES 4         // held-speech frames before a capture commits (a lone loud frame is the room, not a word)
#define VOICE_SILENCE_MS 450         // trailing quiet that ends a command
#define VOICE_MAX_MS 6000            // a command, not a lecture
#define VOICE_MIN_MS 300             // shorter than a word is a cough
#define VOICE_WAKE_RMS_FLOOR 400     // fallback end floor, before the room has been read
#define VOICE_AUTO_MARGIN 120        // the 'auto' floor holds at least this far above the room it read
#define VOICE_AUTO_DIVIDER 8         // ... and a further eighth of the room's own level, so a loud room scales
#define VOICE_AMBIENT_RISE 8         // the most the room estimate may climb in one frame: a voice cannot drag it up faster
#define VOICE_FLOOR_MAX 12000        // a very loud room must not push the floor past a shout
#define VOICE_COMMAND_MS 900         // a burst this long is the phrase and the command run together, not the phrase alone
#define VOICE_GAP_MS 200             // a burst after this much quiet is the command, not the tail of the phrase
#define VOICE_LEAD_MS 2000           // a wake capture with no command at all gives up after this much quiet
#define VOICE_CAPTURE_PATH "/jawn/voice.wav"

// The frame RMS a wake capture holds above once the voice stops: the room's own
// level - measured by voice_ambient_rms while nothing was being captured - plus a
// margin, or the number the panel pinned. It decides that a capture has ended, so
// it must sit above the room and below a spoken word. A VAD capture reads its
// model instead and needs no floor at all.
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

// The microphone arrives on a pedestal: a steady offset rides on every sample.
// It is board and codec, not sound, but the model's front-end turns it into
// log-mel features where it dwarfs the speech, and every level test sees a room
// that never goes quiet. One pole of high pass takes it off before either reads
// the frame (the watch's voice_dc_block).
static float voice_dc_x1 = 0.0f, voice_dc_y1 = 0.0f;
static bool voice_dc_primed = false;
static void voice_dc_reset() {
  voice_dc_x1 = voice_dc_y1 = 0.0f;
  voice_dc_primed = false;
}
static void voice_dc_block(int16_t *s, int n) {
  const float R = 0.995f;             // ~13 Hz corner at 16 kHz, far below speech
  for (int i = 0; i < n; i++) {
    float x = (float)s[i];
    if (!voice_dc_primed) {
      // start level with the first sample, so the pedestal is never a step in
      voice_dc_x1 = x;
      voice_dc_y1 = 0.0f;
      voice_dc_primed = true;
    }
    float y = x - voice_dc_x1 + R * voice_dc_y1;
    voice_dc_x1 = x;
    voice_dc_y1 = y;
    if (y > 32767.0f) { y = 32767.0f; }
    else if (y < -32768.0f) { y = -32768.0f; }
    s[i] = (int16_t)y;
  }
}

// The two acknowledgment chimes. The closing one is a quick high-then-low pair
// (E6 then A5); the opening one is the same pair reversed (A5 then E6), played
// as soon as the wake phrase commits. The files are written once and reused, the
// way speakerSelfTest's tone is.
#define VOICE_ACK_PATH "/jawn/chime_hi_lo.wav"
#define VOICE_ACK_WAKE_PATH "/jawn/chime_lo_hi.wav"
#define VOICE_ACK_FREQ1 1319      // E6
#define VOICE_ACK_FREQ2 880       // A5
#define VOICE_ACK_TONE1_MS 65
#define VOICE_ACK_TONE2_MS 95
#define VOICE_ACK_GAP_MS 12
#define VOICE_ACK_AMP 7000

static bool voice_ack_file(bool wake) {
  const char *path = wake ? VOICE_ACK_WAKE_PATH : VOICE_ACK_PATH;
  File check = store->open(path);
  if (check) {
    uint32_t have = check.size();
    check.close();
    if (have >= 44 + 1000) { return true; }
    store->remove(path);   // a dud from a full filesystem
  }
  if (!create_wav_header_on_flash(path, MIC_I2S_SAMPLE_RATE, MIC_I2S_BITS_PER_SAMPLE, 1)) {
    return false;
  }
  File f = store->open(path, FILE_APPEND);
  if (!f) { return false; }
  // the wake chime swaps the notes but keeps each note's own length
  const uint32_t tone1_ms = wake ? VOICE_ACK_TONE2_MS : VOICE_ACK_TONE1_MS;
  const uint32_t tone2_ms = wake ? VOICE_ACK_TONE1_MS : VOICE_ACK_TONE2_MS;
  const float freq1 = wake ? VOICE_ACK_FREQ2 : VOICE_ACK_FREQ1;
  const float freq2 = wake ? VOICE_ACK_FREQ1 : VOICE_ACK_FREQ2;
  const uint32_t seg1 = MIC_I2S_SAMPLE_RATE * tone1_ms / 1000;
  const uint32_t gap = MIC_I2S_SAMPLE_RATE * VOICE_ACK_GAP_MS / 1000;
  const uint32_t seg2 = MIC_I2S_SAMPLE_RATE * tone2_ms / 1000;
  const uint32_t frames = seg1 + gap + seg2;
  const uint32_t edge = MIC_I2S_SAMPLE_RATE / 200;   // 5 ms fade, so it does not click
  int16_t chunk[256];
  uint32_t written = 0;
  for (uint32_t done = 0; done < frames;) {
    uint32_t n = frames - done;
    if (n > 256) { n = 256; }
    for (uint32_t i = 0; i < n; i++) {
      uint32_t at = done + i;
      float v = 0.0f;
      uint32_t local = 0, len = 0;
      float freq = 0.0f;
      if (at < seg1) { local = at; len = seg1; freq = freq1; }
      else if (at >= seg1 + gap) { local = at - seg1 - gap; len = seg2; freq = freq2; }
      if (len) {
        float env = 1.0f;
        if (local < edge) { env = (float)local / (float)edge; }
        else if (len - local < edge) { env = (float)(len - local) / (float)edge; }
        v = env * sinf(2.0f * 3.14159265f * freq * (float)local / MIC_I2S_SAMPLE_RATE);
      }
      chunk[i] = (int16_t)(VOICE_ACK_AMP * v);
    }
    f.write((uint8_t *)chunk, n * 2);
    written += n * 2;
    done += n;
  }
  f.close();
  finalize_wav_sizes(path, written, 1);
  return written > 0;
}

// True while the listener's own beep is playing. The deadline is generous (the
// file is 70 ms) and loop() clears it as soon as playback ends; it only has to
// cover the gap between connecttoFS and audio.isRunning() turning true.
static inline bool voice_ack_playing() {
  return voiceAckUntil && (int32_t)(millis() - voiceAckUntil) < 0;
}

static void voice_ack(bool wake) {
  if (audio.isRunning()) {
    deckLog("%s", "[voice] ack skipped (speaker busy)");
    return;   // something else owns the speaker
  }
  if (!voice_ack_file(wake)) {
    deckLog("%s", "[voice] ack file failed");
    return;
  }
  voiceAckUntil = millis() + 2000;
  audio.setVolume(volumeLevel);
  audio.connecttoFS(*store, wake ? VOICE_ACK_WAKE_PATH : VOICE_ACK_PATH);
  audio.setVolume(volumeLevel);
  deckLog("%s", wake ? "[voice] wake chime" : "[voice] ack chime");
}

// The orange ring the watch draws while a capture is in flight: the answer that
// the listener heard you, since the deck's own screen may be on another room.
// Built on lv_layer_top() so a room rebuild never sweeps it away, and only ever
// touched from loop() (LVGL is not thread-safe; the listener sets voiceRecording
// and loop() draws).
static lv_obj_t *voice_border = nullptr;
static void voice_border_maker() {
  if (voice_border) { return; }
  voice_border = lv_obj_create(lv_layer_top());
  lv_obj_remove_flag(voice_border, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_remove_flag(voice_border, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_set_size(voice_border, LV_PCT(100), LV_PCT(100));
  lv_obj_set_pos(voice_border, 0, 0);
  lv_obj_set_style_bg_opa(voice_border, LV_OPA_TRANSP, LV_PART_MAIN);
  lv_obj_set_style_radius(voice_border, 0, LV_PART_MAIN);
  lv_obj_set_style_border_color(voice_border, lv_color_hex(0xff8000), LV_PART_MAIN);
  lv_obj_set_style_border_width(voice_border, 6, LV_PART_MAIN);
  lv_obj_add_flag(voice_border, LV_OBJ_FLAG_HIDDEN);
}

static void voice_border_show(bool on) {
  voice_border_maker();
  if (!voice_border) { return; }
  if (on) {
    lv_obj_remove_flag(voice_border, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(voice_border);
  }
  else {
    lv_obj_add_flag(voice_border, LV_OBJ_FLAG_HIDDEN);
  }
}

// The Guide's answer, on the deck's own screen. The server sends the words as a
// {type:'say'} message (the sound follows as say_audio parts, not played here), so
// a request spoken to the deck is readable on it. Drawn on lv_layer_top() and
// hidden by loop() after SAY_TEXT_MS, the way the watch does it.
static void say_label_show(const String &t) {
  if (!say_label) {
    say_label = lv_label_create(lv_layer_top());
    lv_obj_set_width(say_label, LV_PCT(92));
    lv_label_set_long_mode(say_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_bg_opa(say_label, LV_OPA_80, LV_PART_MAIN);
    lv_obj_set_style_bg_color(say_label, lv_color_hex(0x101428), LV_PART_MAIN);
    lv_obj_set_style_text_color(say_label, lv_color_white(), LV_PART_MAIN);
    lv_obj_set_style_radius(say_label, 10, LV_PART_MAIN);
    lv_obj_set_style_pad_all(say_label, 8, LV_PART_MAIN);
    lv_obj_align(say_label, LV_ALIGN_TOP_MID, 0, 8);
    lv_obj_add_flag(say_label, LV_OBJ_FLAG_HIDDEN);
  }
  if (t.length()) {
    lv_label_set_text(say_label, t.c_str());
    lv_obj_remove_flag(say_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_move_foreground(say_label);
    say_shown_at = millis();
  }
  else {
    lv_obj_add_flag(say_label, LV_OBJ_FLAG_HIDDEN);
  }
}

// The Guide's spoken answer. The server streams the reply's PCM as
// {type:'say_audio', data:{seq,last,rate,total,audio}} parts (8 kHz mono s16 when
// ffmpeg resampled it, else the synthesizer's own rate). The parts are held in
// PSRAM and, when the last one lands, written as one WAV and played through the
// speaker - so the answer is heard as well as read.
static uint8_t *say_pcm = nullptr;
static size_t say_pcm_len = 0, say_pcm_cap = 0;
static uint32_t say_pcm_rate = 8000;

static int say_b64_val(char c) {
  if (c >= 'A' && c <= 'Z') { return c - 'A'; }
  if (c >= 'a' && c <= 'z') { return c - 'a' + 26; }
  if (c >= '0' && c <= '9') { return c - '0' + 52; }
  if (c == '+') { return 62; }
  if (c == '/') { return 63; }
  return -1;
}

static size_t say_b64_decode(const char *s, size_t n, uint8_t *out, size_t cap) {
  size_t o = 0;
  uint32_t acc = 0;
  int bits = 0;
  for (size_t i = 0; i < n && o < cap; i++) {
    int v = say_b64_val(s[i]);
    if (v < 0) { continue; }        // padding and whitespace
    acc = (acc << 6) | (uint32_t)v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[o++] = (uint8_t)((acc >> bits) & 0xff);
    }
  }
  return o;
}

// One WAV with the stream's own rate: finalize_wav_sizes() is fixed at the mic's
// 16 kHz, which would mistune a spoken answer.
static bool say_wav_write(const char *path, const uint8_t *pcm, size_t bytes, uint32_t rate) {
  File f = store->open(path, FILE_WRITE);
  if (!f) { return false; }
  uint8_t h[44] = { 0 };
  memcpy(h, "RIFF", 4); deck_wr32(h + 4, (uint32_t)(bytes + 36)); memcpy(h + 8, "WAVE", 4);
  memcpy(h + 12, "fmt ", 4); deck_wr32(h + 16, 16);
  deck_wr16(h + 20, 1); deck_wr16(h + 22, 1);
  deck_wr32(h + 24, rate); deck_wr32(h + 28, rate * 2);
  deck_wr16(h + 32, 2); deck_wr16(h + 34, 16);
  memcpy(h + 36, "data", 4); deck_wr32(h + 40, (uint32_t)bytes);
  f.write(h, 44);
  f.write(pcm, bytes);
  f.close();
  return true;
}

static void say_audio_add(JSONVar d) {
  uint32_t rate = (uint32_t)(int)d["rate"];
  if (rate < 4000 || rate > 96000) { rate = 8000; }
  uint32_t total = (uint32_t)(int)d["total"];
  bool last = ((int)d["last"]) != 0;
  if (!say_pcm) {
    size_t cap = total ? (size_t)total : (size_t)262144;
    if (cap < 16384) { cap = 16384; }
    if (cap > 1048576) { cap = 1048576; }
    say_pcm = (uint8_t *)ps_malloc(cap);
    if (!say_pcm) { say_pcm = (uint8_t *)malloc(cap); }
    say_pcm_len = 0;
    say_pcm_cap = say_pcm ? cap : 0;
    say_pcm_rate = rate;
  }
  const char *a = (const char *)d["audio"];
  if (say_pcm && a && say_pcm_len < say_pcm_cap) {
    say_pcm_len += say_b64_decode(a, strlen(a), say_pcm + say_pcm_len, say_pcm_cap - say_pcm_len);
  }
  if (!last) { return; }
  if (say_pcm && say_pcm_len > 8 && !isRecording && !audio.isRunning()) {
    if (say_wav_write("/jawn/say.wav", say_pcm, say_pcm_len, say_pcm_rate)) {
      audio.setVolume(volumeLevel);
      bool ok = audio.connecttoFS(*store, "/jawn/say.wav");
      audio.setVolume(volumeLevel);
      deckLog("[voice] answer spoken (%u bytes @ %u Hz): %d",
              (unsigned)say_pcm_len, (unsigned)say_pcm_rate, (int)ok);
    }
  }
  else if (say_pcm && say_pcm_len > 8) {
    deckLog("[voice] answer audio skipped (recording=%d playing=%d)",
            (int)isRecording, (int)audio.isRunning());
  }
  if (say_pcm) { free(say_pcm); }
  say_pcm = nullptr;
  say_pcm_len = 0;
  say_pcm_cap = 0;
}

// Fetch a WiFi reply WAV the server announced. The URL was handed over from
// loop() (the BLE message task) through sayFetchReq and is queued to the
// persistent worker below; loop() plays the file when it lands.
static void sayFetchWorker(void *pv) {
  (void)pv;
  for (;;) {
    String* req = nullptr;
    if (xQueueReceive(sayFetchQueue, &req, portMAX_DELAY) != pdTRUE || !req) { continue; }
    String url = *req;
    delete req;
    if (url.length()) {
      sayWifiReady = false;
      https_download(*store, url, "/jawn/reply.wav");
      File f = store->open("/jawn/reply.wav");
      if (f && f.size() > 44) { sayWifiReady = true; }
      if (f) { f.close(); }
      deckLog("[voice] WiFi audio %s", sayWifiReady ? "ready" : "fetch failed");
    }
    sayFetchRunning = false;
  }
}

// The panel's voice_trigger names the model to run; anything we have no model for
// ('off', or a phrase still to be trained) leaves the listener disarmed. A
// running listener is stopped so the model reloads on the way back up.
static void voice_trigger_apply() {
  bool on = voice_models_has(voice_trigger);
  // Only tear a running listener down when the model actually changes (or the
  // setting goes off): a Now Me that re-sends the same setting - the panel does
  // on every push - must not cut a capture in flight short.
  const char *want = on ? voice_trigger.c_str() : "off";
  if (voiceTaskAlive && strcmp(voice_mode_name ? voice_mode_name : "off", want) != 0) {
    voiceListening = false;
    uint32_t t0 = millis();
    while (voiceTaskAlive && millis() - t0 < 1000) { vTaskDelay(pdMS_TO_TICKS(20)); }
  }
  voiceCaptureEnabled = on;
  if (!on && voice_trigger.length() && voice_trigger != "off") {
    deckLog("[voice] no model for '%s'", voice_trigger.c_str());
  }
  deckLog("[voice] mode=%s", voice_trigger.c_str());
}

static void deckVoiceListenTask(void *pv);

// Arm the listener the setting asks for: it needs somewhere to send a clip (the
// bridge, wifi, or the radio loop() brings up for it).
static void deckVoiceListenStart() {
  if (voiceTaskAlive) { return; }
  if (!deviceConnected && WiFi.status() != WL_CONNECTED && !bt_enabled) {
    deckLog("%s", "[voice] no radio to ship a clip on; not listening");
    return;
  }
  voiceListening = true;
  xTaskCreatePinnedToCore(deckVoiceListenTask, "DeckVoice", 8192, NULL, 2, NULL, 1);
}

static void deckVoiceListenTask(void *pv) {
  (void)pv;
  voiceTaskAlive = true;
  int16_t *buf = (int16_t *)ps_malloc(MIC_TDM_BUFFER_BYTES);
  if (!buf) { buf = (int16_t *)malloc(MIC_TDM_BUFFER_BYTES); }
  // the whole utterance is held here and written to flash once, at the end: a
  // flash erase stalls the cpu with the cache off, and the i2s DMA overruns
  // while that happens (see micCaptureTask)
  uint32_t max_samples = (uint32_t)MIC_I2S_SAMPLE_RATE / 1000 * VOICE_MAX_MS;
  int16_t *stage = (int16_t *)ps_malloc((size_t)max_samples * 2);
  if (!buf || !stage) {
    deckLog("[voice] no buffer (i2s %d, psram %d)", buf ? 1 : 0, stage ? 1 : 0);
    if (buf) { free(buf); }
    if (stage) { free(stage); }
    voiceTaskAlive = false;
    vTaskDelete(NULL);
    return;
  }
  const int mono_slot = (mic_mono_slot >= 0 && mic_mono_slot < MIC_TDM_SLOTS) ? mic_mono_slot : 1;
  // the channel has been enabled since boot and nobody read it: drop what is
  // sitting in the DMA and start from now
  i2s_channel_disable(mic_rx_handle);
  i2s_channel_enable(mic_rx_handle);
  // the first frames after the flush are a loud transient: the microphone warming
  // up, not a word. Discard ~400 ms of it, the way the watch does, so the energy
  // gate (and the model) never read the power-on as speech.
  {
    uint32_t warm = millis();
    size_t g = 0;
    while (voiceListening && millis() - warm < 400) {
      i2s_channel_read(mic_rx_handle, buf, MIC_TDM_BUFFER_BYTES, &g, 50);
      vTaskDelay(pdMS_TO_TICKS(10));
    }
  }
  voice_dc_reset();   // the mic has just been flushed: prime the pedestal filter on it
  if (!voice_models_init(voice_trigger)) { deckLog("%s", "[voice] no voice model loaded"); }
  deckLog("[voice] listening: %s (slot %d) int=%u", voice_mode_name, mono_slot,
          (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
  // Build both chime files now, before any capture: a flash write while the
  // microphone is recording overruns the i2s DMA (see micCaptureTask), and the
  // first wake would otherwise write the opening chime mid-capture.
  voice_ack_file(false);
  voice_ack_file(true);

  static int16_t mono[MIC_TDM_FRAMES];
  while (voiceListening) {
    // The Guide's answer is about to be spoken: do not listen for it, or the
    // deck records its own speaker (setting isRecording) and say_audio_add
    // then refuses to play the reply. The hold ends in loop() when playback
    // finishes (or the reply times out).
    if (voiceAwaitingReply) {
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }
    if (isRecording || (audio.isRunning() && !voice_ack_playing())) {
      // a manual record or playback owns the microphone: hold without reading,
      // so the two never slice the same DMA buffer. The listener's own beep is
      // the exception: it is on the speaker bus, and the wake word has already
      // been read, so the capture reads through it.
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }
    bool recording = false;
    bool aborted = false;   // cut short by a manual record / playback, or by the setting going off
    bool gave_up = false;   // a wake phrase with no command behind it
    bool wake_mode = (voice_mode_name && strcmp(voice_mode_name, "vad") != 0);
    int speech_run = 0;      // held-speech frames seen before a capture commits
    bool have_onset = false; // the first speech of this utterance stamps the clip
    uint32_t onset_ts = 0;
    uint32_t end_floor = 0;  // fixed when the capture commits
    uint32_t loud_ms = 0;    // the run above the floor, currently
    bool command_seen = false;
    uint32_t rec_ms = 0, silence_ms = 0, pcm_bytes = 0;

    while (voiceListening) {
      if (isRecording || (audio.isRunning() && !voice_ack_playing())) { aborted = true; break; }
      size_t got = 0;
      if (i2s_channel_read(mic_rx_handle, buf, MIC_TDM_BUFFER_BYTES, &got, 100) != ESP_OK
          || got < MIC_TDM_SLOTS * 2) {
        vTaskDelay(pdMS_TO_TICKS(1));
        continue;
      }
      int frames = got / (MIC_TDM_SLOTS * 2);
      if (frames > MIC_TDM_FRAMES) { frames = MIC_TDM_FRAMES; }
      for (int i = 0; i < frames; i++) { mono[i] = buf[i * MIC_TDM_SLOTS + mono_slot]; }
      int n = frames;
      int16_t *s = mono;
      // the pedestal comes off first: the model's features and every level read
      // what is left
      voice_dc_block(s, n);
      bool speech = voice_active_frame(s, n);
      // the frame's own level, taken once: the room estimate and the
      // end-of-speech floor both read this same figure. 64-bit: a 512 sample
      // frame of loud speech squares past what int32 holds.
      int64_t sq = 0;
      for (int k = 0; k < n; k++) { sq += (int32_t)s[k] * (int32_t)s[k]; }
      uint32_t rms = (uint32_t)sqrtf((float)sq / (float)(n > 0 ? n : 1));
      // learn the room while nothing is captured, and never during one: a quieter
      // frame is the room and is taken at once, a louder one is climbed towards at
      // a capped pace, so a voice cannot drag the room estimate up with it
      if (!recording) {
        if (!voice_ambient_rms || rms <= voice_ambient_rms) { voice_ambient_rms = rms; }
        else {
          uint32_t step = (rms - voice_ambient_rms) / 8;
          if (step > VOICE_AMBIENT_RISE) { step = VOICE_AMBIENT_RISE; }
          voice_ambient_rms += step;
        }
        // once a second, say what the microphone and the model are reading, so a
        // quiet or wedged voice path is visible over USB without speaking
        static uint32_t vdbg_at = 0, vdbg_frames = 0, vdbg_peak = 0;
        if (voice_dbg_peak > vdbg_peak) { vdbg_peak = voice_dbg_peak; }
        vdbg_frames++;
        if (millis() - vdbg_at >= 1000) {
          deckLog("[vdbg] frames=%u rms=%u ambient=%u efloor=%u peak=%u fires=%u",
                  (unsigned)vdbg_frames, (unsigned)rms, (unsigned)voice_ambient_rms,
                  (unsigned)voice_end_floor(), (unsigned)vdbg_peak, (unsigned)voice_dbg_fires);
          vdbg_at = millis(); vdbg_frames = 0; vdbg_peak = 0;
          voice_dbg_peak = 0; voice_dbg_fires = 0;
        }
      }
      if (!recording) {
        // a single loud frame is not a word: hold the speech for a short run
        // before committing, so the listener answers speech, not the room
        if (!speech) { speech_run = 0; voiceHeard = false; continue; }
        // the clip's timestamp is when the utterance STARTED - the wake word,
        // not the command after a pause - so stamp the first speech frame and keep it
        if (!have_onset) { have_onset = true; onset_ts = (uint32_t)rightNow(); voiceHeard = true; }
        if (++speech_run < VOICE_ONSET_FRAMES) { continue; }
        if (!create_wav_header_on_flash(VOICE_CAPTURE_PATH, MIC_I2S_SAMPLE_RATE, MIC_I2S_BITS_PER_SAMPLE, 1)) { break; }
        recording = true;
        rec_ms = 0;
        silence_ms = 0;
        pcm_bytes = 0;
        deck_voice_ts = have_onset ? (long)onset_ts : rightNow();
        end_floor = voice_end_floor();
        voiceRecording = true;   // loop() holds the screen awake and rings the border
        // answer the wake word at once: A5 then E6, the reverse of the closing pair
        if (wake_mode) { voice_ack(true); }
        deckLog("[voice] speech (%s), recording", voice_mode_name);
      }
      // keep the frame (16 kHz mono); the compressor folds it to 8 kHz when it ships
      uint32_t room = max_samples - pcm_bytes / 2;
      int m = ((uint32_t)n < room) ? n : (int)room;
      for (int i = 0; i < m; i++) { stage[pcm_bytes / 2 + i] = s[i]; }
      pcm_bytes += (uint32_t)m * 2;
      // end of speech. A wake-word model speaks only for its phrase, so its
      // output cannot be the silence detector once the capture has started - a
      // command would end about a second after "hey jawn" with nothing in it. A
      // wake capture therefore ends on the frame's energy; a VAD capture keeps
      // using the model, which is speech for as long as the person speaks. The
      // phrase and the command are two bursts with a pause between them, so a
      // short first burst does not end the capture: it arms a window for the command.
      bool quiet = speech;
      if (wake_mode) {
        bool loud = (rms >= end_floor);
        if (loud) {
          if (!loud_ms && silence_ms >= VOICE_GAP_MS) { command_seen = true; }
          loud_ms += VOICE_FRAME_MS;
        }
        else {
          if (loud_ms >= VOICE_COMMAND_MS) { command_seen = true; }
          loud_ms = 0;
        }
        quiet = !loud;
      }
      rec_ms += VOICE_FRAME_MS;
      silence_ms = quiet ? silence_ms + VOICE_FRAME_MS : 0;
      if (silence_ms >= VOICE_SILENCE_MS && rec_ms >= VOICE_MIN_MS) {
        // a wake capture the command never reached waits the lead window out, so
        // a pause after the phrase is not mistaken for the end of one
        if (!wake_mode || command_seen) { break; }
        if (silence_ms >= VOICE_LEAD_MS) { gave_up = true; break; }
      }
      if (rec_ms >= VOICE_MAX_MS) { break; }
    }
    if (!voiceListening) { aborted = true; }
    if (recording && !aborted && !gave_up && pcm_bytes > 0) {
      File f = store->open(VOICE_CAPTURE_PATH, FILE_APPEND);
      if (f) {
        uint8_t *p = (uint8_t *)stage;
        uint32_t remaining = pcm_bytes;
        while (remaining > 0) {
          size_t chunk = remaining > 32768 ? 32768 : remaining;
          f.write(p, chunk);
          p += chunk;
          remaining -= (uint32_t)chunk;
        }
        f.close();
        finalize_wav_sizes(VOICE_CAPTURE_PATH, pcm_bytes, 1);
        // listening has finished: acknowledge with the high-then-low chime
        if (wake_mode) { voice_ack(false); }
        deckLog("[voice] clip %u bytes ts=%ld -> bridge", (unsigned)pcm_bytes, (long)deck_voice_ts);
        // Compact it first: ffmpeg reads IMA ADPCM WAV natively, so the link
        // carries a quarter of the bytes and the server reads an identical file.
        String ship_path = VOICE_CAPTURE_PATH;
        if (deck_voice_compress(VOICE_CAPTURE_PATH, "/jawn/voice.adpcm")) { ship_path = "/jawn/voice.adpcm"; }
        if (!deck_voice_ship(ship_path, deck_voice_ts, voice_mode_name)) {
          deckLog("%s", "[voice] clip NOT shipped (no radio?)");
        }
        else {
          // hold the screen on until the Guide answers
          voiceAwaitingSince = millis();
          voiceAwaitingReply = true;
        }
      }
    }
    else if (recording) {
      // a clip cut short by a manual record, or a wake phrase with no command
      // behind it, is dropped rather than shipped: a near-silent clip is what the
      // transcribers turn into a stock phrase, and the guide then answers nobody
      // -- but the listening still finished, so still give the chime (unless the
      // microphone was taken away mid-capture)
      if (!aborted && wake_mode) { voice_ack(false); }
      deckLog("[voice] clip dropped (%s)", aborted ? "mic taken" : "no command");
    }
    // the clip is written and away (or dropped): the screen may time out again
    voiceRecording = false;
    voiceHeard = false;
    if (!voiceCaptureEnabled) { break; }
    vTaskDelay(1);
  }
  free(stage);
  free(buf);
  voiceRecording = false;
  voiceHeard = false;
  voiceTaskAlive = false;
  deckLog("%s", "[voice] listener end");
  vTaskDelete(NULL);
}

