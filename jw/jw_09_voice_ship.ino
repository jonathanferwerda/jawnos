static bool voice_ship_clip(const String &path) {
  // Prefer WiFi: a clip is tens of KB, and over BLE that is hundreds of
  // notifications the bridge drops parts of (its reassembler logs "never
  // arrived"), so a clip often reaches the server holed and whisper gets half a
  // word. WiFi POSTs the whole file in one request. The BLE bridge is the
  // fallback for when there is no WiFi (or the homebase is unreachable); taps and
  // steps, which are tiny, still ride BLE as before.
  if (WiFi.status() == WL_CONNECTED) {
    if (homebaseIP.length() == 0) {
      Serial.println("[voice] no homebase; BLE now");
    }
    else if ((int32_t)(millis() - homebase_down_until) < 0) {
      Serial.println("[voice] homebase marked down; BLE now");
    }
    else if (voice_post_clip(path)) {
      Serial.println("[voice] clip shipped over WiFi");
      return true;
    }
    else {
      Serial.println("[voice] WiFi POST failed; BLE now");
    }
  }
  else {
    Serial.println("[voice] WiFi not connected; BLE now");
  }
  if (deviceConnected && voice_ble_send(path)) {
    Serial.println("[voice] clip shipped over BLE");
    return true;
  }
  Serial.println("[voice] no radio to ship the clip on");
  return false;
}

// The orange ring: a border around the whole panel while a spoken command is
// being heard. It lives on the top layer so the per-room rebuilds - which
// lv_obj_clean the screen - never sweep it away, and it is not clickable, so a
// touch still lands on the buttons beneath it. loop() drives it from
// `voiceRecording`, the same flag that keeps the screen awake mid-sentence, so
// the ring means the one thing: the watch is listening right now.
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
  }
  else {
    lv_obj_add_flag(voice_border, LV_OBJ_FLAG_HIDDEN);
  }
}

// The guide associate's answer, drawn on the top layer so the per-room rebuilds
// never sweep it away (the same trick the orange ring uses). Hidden by loop()
// after SAY_TEXT_MS, or by passing an empty string.
static void say_label_show(const String &t) {
  if (!say_label) {
    say_label = lv_label_create(lv_layer_top());
    lv_obj_set_width(say_label, LV_PCT(90));
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
  }
  else {
    lv_obj_add_flag(say_label, LV_OBJ_FLAG_HIDDEN);
  }
}

// ---- the acknowledgment chimes ------------------------------------------
// The opening chime is the closing pair reversed: A5 then E6 (low, then high).
// It plays as soon as the wake phrase commits, and the closing chime (E6 then
// A5) plays when the capture ends. The watch's speaker is its own I2S device,
// so this plays while the PDM microphone keeps reading. It deliberately does
// not raise isPlaying: that would stop the listener and cut the command short.
#define VOICE_ACK_FREQ_HIGH 1319
#define VOICE_ACK_FREQ_LOW 880
#define VOICE_ACK_HIGH_MS 65
#define VOICE_ACK_LOW_MS 95
#define VOICE_ACK_GAP_MS 12
#define VOICE_ACK_AMP 7000
#define VOICE_ACK_RATE 16000

static volatile bool voiceAckPlaying = false;

static void voice_ack_task(void *pv) {
  bool wake = (bool)(uintptr_t)pv;
  AudioOutputIf *codec = watch.getAudioOutput();
  if (!codec || !codec->open(16, 1, VOICE_ACK_RATE)) {
    voiceAckPlaying = false;
    vTaskDelete(NULL);
    return;
  }
  codec->setVolume(volumeLevel);
  // reverse the pair for the wake: A5 (95 ms) then E6 (65 ms)
  const uint32_t seg1 = VOICE_ACK_RATE * (wake ? VOICE_ACK_LOW_MS : VOICE_ACK_HIGH_MS) / 1000;
  const uint32_t gap = VOICE_ACK_RATE * VOICE_ACK_GAP_MS / 1000;
  const uint32_t seg2 = VOICE_ACK_RATE * (wake ? VOICE_ACK_HIGH_MS : VOICE_ACK_LOW_MS) / 1000;
  const float freq1 = wake ? VOICE_ACK_FREQ_LOW : VOICE_ACK_FREQ_HIGH;
  const float freq2 = wake ? VOICE_ACK_FREQ_HIGH : VOICE_ACK_FREQ_LOW;
  const uint32_t frames = seg1 + gap + seg2;
  const uint32_t edge = VOICE_ACK_RATE / 200;   // 5 ms fade, so it does not click
  int16_t chunk[256];
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
        v = env * sinf(2.0f * 3.14159265f * freq * (float)local / VOICE_ACK_RATE);
      }
      chunk[i] = (int16_t)(VOICE_ACK_AMP * v);
    }
    codec->write((const uint8_t *)chunk, n * 2);
    done += n;
  }
  codec->close();
  voiceAckPlaying = false;
  vTaskDelete(NULL);
}

static void voice_ack(bool wake) {
  if (isPlaying || isRecording || voiceAckPlaying) { return; }
  voiceAckPlaying = true;
  if (xTaskCreatePinnedToCore(voice_ack_task, "AckTask", 3072, (void *)(wake ? 1 : 0), 2, NULL, 1) != pdPASS) {
    voiceAckPlaying = false;
    return;
  }
  Serial.println(wake ? "[voice] wake chime" : "[voice] ack chime");
}

static void voiceListenTask(void *pv) {
  if (voiceDbg) { Serial.printf("[voice] task int=%u\n", (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL)); }
  AudioInputIf *mic = watch.getAudioInput();
  if (!mic || !mic->open(MIC_I2S_BITS_PER_SAMPLE, 1, MIC_I2S_SAMPLE_RATE)) {
    Serial.println("[voice] microphone open failed");
    voiceListening = false;
    vTaskDelete(NULL);
  }
  uint8_t *buf = (uint8_t *)malloc(VOICE_FRAME_SAMPLES * 2);
  if (!buf) {
    mic->close();
    voiceListening = false;
    vTaskDelete(NULL);
  }
  // The microphone's first frames after open are a loud transient. The listener
  // is torn down when the watch dozes and rebuilt on the way up, so that
  // transient landed on every screen wake: the energy gate read it as speech,
  // lit the ring, and shipped a clip of nothing. Discard the warm-up first.
  {
    uint32_t warm = millis();
    while (voiceListening && millis() - warm < 400) {
      mic->read(buf, VOICE_FRAME_SAMPLES * 2);
      vTaskDelay(10 / portTICK_PERIOD_MS);
    }
  }
  // bring in the voice model the setting asks for (VAD or a wake word)
  voice_dc_reset();   // the mic has just been opened: prime the pedestal filter on it
  if (!voice_models_init(voice_trigger)) { Serial.println("[voice] no voice model loaded"); }
  if (voiceDbg) {
    // the display's SPI flush bounces through the DMA-capable pool, so watch it
    // around the microphone: the I2S driver's buffers come from the same pool.
    // The three flags ride along because any one of them stops the listener the
    // moment it starts (see the loop below), and which one it was is the whole
    // question when a capture never reaches a frame.
    Serial.printf("[voice] armed: int=%u dma=%u rec=%d play=%d doze=%d\n",
                  (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                  (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA),
                  (int)isRecording, (int)isPlaying, (int)dozing);
  }
  // the microphone stays open across utterances: each pass captures one spoken
  // run, ships it, and - while the setting is on - goes straight back to
  // listening, so a command needs no button at all
  while (voiceListening) {
    if (isRecording || isPlaying) {
      break;   // a manual record or playback owns the mic; loop() re-arms us
    }
    if (dozing) {
      break;   // the screen is off: the listener only runs while it is on
    }
    bool recording = false;
    // A wake-word capture ends on a level test, a VAD capture on its model (see the
    // end-of-speech block below).
    bool wake_mode = (voice_mode_name && strcmp(voice_mode_name, "vad") != 0);
    int speech_run = 0;      // held-energy frames seen before a capture commits
    bool have_onset = false; // the first speech of this utterance stamps the clip
    uint32_t onset_ts = 0;
    uint32_t end_floor = 0;  // fixed when the capture commits (see voice_end_floor)
    uint32_t loud_ms = 0;    // the run above the floor, currently
    bool command_seen = false; // the command is under way, not just the wake phrase
    bool gave_up = false;      // nothing was said: drop the clip rather than ship it
    uint32_t rec_ms = 0, silence_ms = 0, pcm_bytes = 0;
    File f;
    while (voiceListening) {
      if (isRecording || isPlaying) {
        break;   // a manual record or playback started: hand the mic over
      }
      if (dozing) {
        break;   // the screen went off mid-capture: stop listening
      }
      if (president_fetch_running) {
        break;   // a TLS room fetch is running: do not add to the peak (see the notes)
      }
      int got = mic->read(buf, VOICE_FRAME_SAMPLES * 2);
      if (got <= 0) { continue; }
      int n = got / 2;
      int16_t *s = (int16_t *)buf;
      // take the microphone's pedestal off first: the model's features and every
      // level below are read from what is left (see voice_dc_block)
      voice_dc_block(s, n);
      // the neural model reads the frame as speech (VAD) or the wake phrase
      bool speech = voice_active_frame(s, n);
      // the frame's own level, taken once: the room estimate, the [vdbg] line and
      // the end-of-speech floor all read this same figure. The sum is 64-bit: a
      // 480-sample frame of loud speech squares past what int32 holds.
      int64_t sq = 0;
      for (int k = 0; k < n; k++) { sq += (int32_t)s[k] * (int32_t)s[k]; }
      uint32_t rms = (uint32_t)sqrtf((float)sq / (float)(n > 0 ? n : 1));
      // Learn the room while nothing is being captured, and never during one: it
      // is what 'auto' stands on. A quieter frame is the room and is taken at once;
      // a louder one is climbed towards at a capped pace, so a voice or a running
      // tap cannot be mistaken for the room it is measured against.
      if (!recording) {
        if (!voice_ambient_rms || rms <= voice_ambient_rms) { voice_ambient_rms = rms; }
        else {
          uint32_t step = (rms - voice_ambient_rms) / 8;
          if (step > VOICE_AMBIENT_RISE) { step = VOICE_AMBIENT_RISE; }
          voice_ambient_rms += step;
        }
      }
      if (voiceDbg) {
        static uint32_t vdbg_at = 0, vdbg_frames = 0;
        static int32_t vdbg_amp = 0;
        static uint32_t vdbg_rms_sum = 0, vdbg_rms_n = 0, vdbg_rms_max = 0;
        for (int k = 0; k < n; k++) { int32_t a = s[k]; if (a < 0) { a = -a; } if (a > vdbg_amp) { vdbg_amp = a; } }
        vdbg_rms_sum += rms; vdbg_rms_n++;
        if (rms > vdbg_rms_max) { vdbg_rms_max = rms; }
        vdbg_frames++;
        if (millis() - vdbg_at >= 1000) {
          Serial.printf("[vdbg] frames=%u maxamp=%d rms=%u rms_max=%u dc=%ld ambient=%u efloor=%u voice=%s model=%s cut=%u peak=%u fires=%u\n",
                        (unsigned)vdbg_frames, (int)vdbg_amp,
                        (unsigned)(vdbg_rms_n ? vdbg_rms_sum / vdbg_rms_n : 0), (unsigned)vdbg_rms_max,
                        (long)(voice_dc_n ? voice_dc_sum / (int64_t)voice_dc_n : 0),
                        (unsigned)voice_ambient_rms, (unsigned)voice_end_floor(), voice_floor.c_str(),
                        voice_mode_name ? voice_mode_name : "?",
                        (unsigned)(voice_active ? voice_active->cutoff_q : 0),
                        (unsigned)voice_dbg_peak, (unsigned)voice_dbg_fires);
          vdbg_at = millis(); vdbg_frames = 0; vdbg_amp = 0; voice_dbg_peak = 0; voice_dbg_fires = 0;
          vdbg_rms_sum = 0; vdbg_rms_n = 0; vdbg_rms_max = 0;
          voice_dc_sum = 0; voice_dc_n = 0;
        }
      }
      if (!recording) {
        // a single loud frame is not a word: the room crosses the floor, and so
        // does a running tap. Hold the energy for a short run before committing,
        // so the listener - and the orange ring - answer speech, not the room.
        if (!speech) { speech_run = 0; continue; }
        // the clip's timestamp is when the utterance STARTED - the wake word, not
        // the command word after a pause. Stamp the first speech frame and keep
        // it, so a pause between "jawn do" and the command does not move it.
        if (!have_onset) { have_onset = true; onset_ts = timestamp_maker(); voiceWakeHoldUntil = millis() + 15000; }
        if (++speech_run < VOICE_ONSET_FRAMES) { continue; }
        Serial.println("[voice] speech (vad)");
        if (!create_wav_header_on_flash(VOICE_WAV_PATH.c_str(), VOICE_SAMPLE_RATE, MIC_I2S_BITS_PER_SAMPLE)) { break; }
        f = FFat.open(VOICE_WAV_PATH.c_str(), FILE_APPEND);
        if (!f) { break; }
        recording = true;
        rec_ms = 0;
        silence_ms = 0;
        voiceRecording = true;
        // answer the wake word at once: the opening pair is the closing pair
        // reversed (A5 then E6), so the person knows the phrase landed before
        // they speak the command
        if (wake_mode) { voice_ack(true); }
        voice_clip_ts = have_onset ? (long)onset_ts : timestamp_maker();
        // The floor is fixed for this capture: the room does not change while the
        // person is speaking, and one that moved mid-sentence would cut it short.
        end_floor = voice_end_floor();
        // send the clip up while it is being spoken (see voice_stream_begin):
        // the server has it the moment the person stops
        voice_stream_begin();
        Serial.println("[voice] speech detected, recording");
      }
      // The clip ships at 8 kHz: half of what the microphone produced, so a BLE
      // transfer (the only radio when the watch is off WiFi) carries half the
      // notifications and stands a far better chance of arriving whole. Whisper
      // resamples to 16 kHz regardless, so speech decodes the same. Averaging
      // each pair is the crude half-band filter - enough for a spoken command.
      {
        int16_t *in16 = (int16_t *)buf;
        static int16_t folded[VOICE_FRAME_SAMPLES / 2 + 2];
        int m = 0;
        for (int i = 0; i + 1 < n; i += 2) {
          folded[m++] = (int16_t)(((int32_t)in16[i] + (int32_t)in16[i + 1]) >> 1);
        }
        pcm_bytes += f.write((uint8_t *)folded, m * 2);
        voice_stream_feed(folded, m);   // and up the link, as it is spoken
      }
      // A wake-word model speaks only for its phrase: its output cannot be the
      // silence detector once the capture has started, or every command ends
      // about 900 ms after "hey jawn" and the clip carries the wake word and
      // nothing else - which is exactly what the server heard (a blank or
      // fragmentary transcript) on the walk. While recording a wake-word
      // capture, end on the frame's energy instead: the room reads quiet, the
      // command does not. A VAD capture keeps using the model, which is speech
      // for as long as the person is speaking.
      //
      // The phrase and the command are two bursts with a pause between them, and
      // taking that pause for the end is what cut every command off a second after
      // "hey jawn" - shipping a clip with no command in it, which the transcribers
      // answer with a stock phrase ("thank you"). So a short first burst does not
      // end the capture; it arms a window for the command. A burst long enough to
      // be the phrase and the command run together is the command itself.
      bool quiet = speech;
      if (recording && wake_mode) {
        bool loud = (rms >= end_floor);
        if (loud) {
          // a burst that begins after a real gap is the command, not the phrase
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
        // that a pause after the phrase is not mistaken for the end of one
        if (!wake_mode || command_seen) { break; }
        if (silence_ms >= VOICE_LEAD_MS) { gave_up = true; break; }
      }
      if (rec_ms >= VOICE_MAX_MS) { break; }
    }
    if (recording && !isRecording && !isPlaying && gave_up) {
      // The wake phrase fired and no command followed. Drop the clip rather than
      // ship it: a near-silent clip is what the transcribers turn into "thank
      // you", and the guide associate then answers a sentence nobody said. The
      // parts already streamed are never finished, so the server never assembles
      // and never ingests them.
      f.close();
      voiceRecording = false;
      voiceWakeHoldUntil = 0;
      // listening has finished: acknowledge with the high-then-low chime, even
      // when there was no command to ship
      if (wake_mode) { voice_ack(false); }
      voice_stream_abort();
      Serial.printf("[voice] no command after %s; clip dropped\n", voice_mode_name ? voice_mode_name : "?");
    }
    else if (recording && !isRecording && !isPlaying) {
      f.close();
      voiceRecording = false;
      voiceWakeHoldUntil = 0;
      // listening has finished: acknowledge with the high-then-low chime
      if (wake_mode && pcm_bytes > 0) { voice_ack(false); }
      voice_stream_end();   // encode the tail and let the last part go out
      if (pcm_bytes > 0) {
        // hold the screen on until the Guide answers
        voiceAwaitingSince = millis();
        voiceAwaitingReply = true;
        finalize_wav_sizes(VOICE_WAV_PATH.c_str(), pcm_bytes, VOICE_SAMPLE_RATE);
        Serial.printf("[voice] clip %u bytes ts=%ld -> homebase\n", (unsigned)pcm_bytes, (long)voice_clip_ts);
        // Compact it first: ffmpeg on the server reads IMA ADPCM WAV natively, so
        // the BLE link carries a quarter of the bytes with no server change.
        String ship_path = VOICE_WAV_PATH;
        if (voice_compress_clip()) { ship_path = VOICE_ADPCM_PATH; }
        // Ship, then hold the file until the server says the clip arrived whole.
        // A clip that never lands is tried again as a whole - the queue is one
        // clip, retried in place - so a busy bridge costs a moment, not the
        // command. The server acks on reassembly (voice_recv), so the wait is a
        // network round trip, not the transcription.
        long ts = voice_clip_ts;
        voiceShipping = true;
        uint32_t ship_started = millis();
        // Keep trying until the server says the clip arrived whole, or the cap is
        // reached. A send that finds no radio (the bridge is still coming up) is
        // not a failure - wait and try again. The queue is one clip, retried in
        // place; the file stays until the server's ack deletes it.
        while (voiceListening && voice_acked_ts != ts && millis() - ship_started < 45000) {
          if (voice_ship_clip(ship_path)) {
            uint32_t started = millis();
            while (voiceListening && voice_acked_ts != ts && millis() - started < 6000) {
              vTaskDelay(100 / portTICK_PERIOD_MS);
            }
          }
          else {
            vTaskDelay(500 / portTICK_PERIOD_MS);   // no radio yet: wait for one
          }
        }
        voiceShipping = false;
        if (voice_acked_ts != ts) {
          Serial.println("[voice] clip unacked; left on disk for the next pass");
        }
      }
    }
    else if (f) {
      f.close();   // a capture cut short by a manual record is discarded
      voiceRecording = false;
      voiceWakeHoldUntil = 0;
    }
    if (voiceOneShot) { break; }             // a serial "voice" capture is one utterance
    if (!voiceCaptureEnabled) { break; }     // the setting was turned off
    vTaskDelay(1);
  }
  mic->close();
  free(buf);
  voiceRecording = false;
  voiceWakeHoldUntil = 0;
  voiceListening = false;
  if (voiceDbg) { Serial.printf("[voice] task end int=%u\n", (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL)); }
  vTaskDelete(NULL);
}

// Arm the listener. one_shot is the serial trigger (a single utterance); the
// setting keeps it running until it is turned off. A capture already in flight
// is left alone.
static void voiceListenStart(bool one_shot) {
  if (voiceListening) {
    return;
  }
  if (!one_shot && !deviceConnected && WiFi.status() != WL_CONNECTED && !bt_enabled) {
    // the setting keeps a listener up, so it needs somewhere for the clip to go;
    // with the bridge setting on the radio is brought up for it (see loop), and
    // the serial trigger still records without a radio, so the VAD can be tuned
    // over USB
    Serial.println("[voice] no radio to ship a clip on; not listening");
    return;
  }
  if (voiceDbg) { Serial.printf("[voice] start int=%u\n", (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL)); }
  voiceOneShot = one_shot;
  voiceListening = true;
  xTaskCreatePinnedToCore(voiceListenTask, "VoiceTask", 8192, NULL, 2, NULL, 1);
}

// The Configure > System toggle: arm the listener with the setting, disarm it
// when it goes off.
static void voice_control(lv_event_t *e) {
  lv_obj_t *voice_button = lv_event_get_target_obj(e);
  if (voiceCaptureEnabled) {
    voiceCaptureEnabled = false;
    lv_obj_set_style_bg_color(voice_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  else {
    voiceCaptureEnabled = true;
    lv_obj_set_style_bg_color(voice_button, lv_color_hex(0x5afcdd), LV_PART_MAIN);
    voiceListenStart(false);
  }
}

// Background monitoring frame calculation handler for playback
