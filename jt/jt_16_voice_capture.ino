static void micCaptureTask(void *pvParameters) {
  int16_t *buf = (int16_t *)ps_malloc(MIC_TDM_BUFFER_BYTES);
  if (!buf) { buf = (int16_t *)malloc(MIC_TDM_BUFFER_BYTES); }
  // The whole recording is held in PSRAM and written to the flash in one go at
  // the end. Writing during capture is what broke the audio: a flash erase or
  // program stalls the cpu with the cache off for tens of milliseconds, the i2s
  // dma overruns while that happens, and the read that follows returns torn
  // buffers - heard as a buzz that comes and goes about once a second.
  static const uint32_t caps_s[] = {120, 60, 30, 15};
  uint32_t max_frames = 0;
  int16_t *stage = NULL;
  for (int i = 0; i < 4 && stage == NULL; i++) {
    max_frames = MIC_I2S_SAMPLE_RATE * caps_s[i];
    stage = (int16_t *)ps_malloc((size_t)max_frames * 2);
  }
  if (buf == NULL || stage == NULL) {
    deckLog("[mic] no buffer (i2s %d, psram %d)", buf ? 1 : 0, stage ? 1 : 0);
    if (buf) {
      free(buf);
    }
    if (stage) {
      free(stage);
    }
    isRecording = false;
    vTaskDelete(NULL);
    return;
  }
  deckLog("[mic] buffering up to %u s in psram", (unsigned)(max_frames / MIC_I2S_SAMPLE_RATE));

  // the channel has been enabled since boot and nobody read it, so drop what
  // is sitting in the DMA and start from now
  i2s_channel_disable(mic_rx_handle);
  i2s_channel_enable(mic_rx_handle);

  // The microphone report: which slot is loud is printed once here (and the
  // slot itself can be changed with "JAWNSLOT <n>" over the usb serial), so a
  // different board can be read straight off the log.
  const int mono_slot = (mic_mono_slot >= 0 && mic_mono_slot < MIC_TDM_SLOTS) ? mic_mono_slot : 1;
  uint32_t staged = 0;
  size_t got = 0;
  if (i2s_channel_read(mic_rx_handle, buf, MIC_TDM_BUFFER_BYTES, &got, 100) == ESP_OK
      && got >= MIC_TDM_SLOTS * 2) {
    int frames = got / (MIC_TDM_SLOTS * 2);
    uint32_t sums[MIC_TDM_SLOTS] = {0, 0, 0, 0};
    for (int i = 0; i < frames; i++) {
      for (int c = 0; c < MIC_TDM_SLOTS; c++) {
        int32_t v = buf[i * MIC_TDM_SLOTS + c];
        sums[c] += (uint32_t)(v * v);
      }
    }
    for (int c = 0; c < MIC_TDM_SLOTS; c++) {
      String line;
      for (int i = 0; i < 8; i++) {
        line += String(buf[i * MIC_TDM_SLOTS + c]) + " ";
      }
      deckLog("[mic] slot %d rms %u samples: %s", c,
              (unsigned)sqrtf((float)sums[c] / frames), line.c_str());
    }
    if (frames > (int)max_frames) {
      frames = max_frames;
    }
    for (int i = 0; i < frames; i++) {
      stage[staged + i] = buf[i * MIC_TDM_SLOTS + mono_slot];
    }
    staged += frames;
  }
  deckLog("[mic] recording %s from slot %d", WAV_FILE_PATH.c_str(), mono_slot);

  uint32_t started_ms = millis();
  uint32_t last_levels_ms = 0;

  while (isRecording && (record_end_ms == 0 || millis() < record_end_ms)) {
    size_t got = 0;
    if (i2s_channel_read(mic_rx_handle, buf, MIC_TDM_BUFFER_BYTES, &got, 100) != ESP_OK
        || got < MIC_TDM_SLOTS * 2) {
      vTaskDelay(pdMS_TO_TICKS(1));
      continue;
    }
    int frames = got / (MIC_TDM_SLOTS * 2);

    // once every other second say how loud each channel is, so a future
    // board's slot layout can be read straight off the log
    if (millis() - last_levels_ms > 2000) {
      last_levels_ms = millis();
      uint32_t levels[MIC_TDM_SLOTS] = {0, 0, 0, 0};
      for (int i = 0; i < frames; i++) {
        for (int c = 0; c < MIC_TDM_SLOTS; c++) {
          int32_t v = buf[i * MIC_TDM_SLOTS + c];
          levels[c] += (uint32_t)(v * v);
        }
      }
      deckLog("[mic] levels %u %u %u %u",
              (unsigned)sqrtf((float)levels[0] / frames), (unsigned)sqrtf((float)levels[1] / frames),
              (unsigned)sqrtf((float)levels[2] / frames), (unsigned)sqrtf((float)levels[3] / frames));
    }

    // keep the microphone we picked, mono (or all four slots when the host
    // asked for "JAWNCH 4" to see which channel carries a mic), straight into
    // psram: nothing in this loop touches the flash, which is the whole point
    // of the buffer
    int ch = (mic_channels == MIC_TDM_SLOTS) ? MIC_TDM_SLOTS : 1;
    int n = frames;
    if (n > (int)((max_frames - staged) / ch)) {
      n = (max_frames - staged) / ch;
    }
    if (ch == 1) {
      for (int i = 0; i < n; i++) {
        stage[staged + i] = buf[i * MIC_TDM_SLOTS + mono_slot];
      }
      staged += n;
    }
    else {
      for (int i = 0; i < n; i++) {
        for (int c = 0; c < ch; c++) {
          stage[staged + i * ch + c] = buf[i * MIC_TDM_SLOTS + c];
        }
      }
      staged += n * ch;
    }
    if (staged >= max_frames - ch) {
      deckLog("[mic] buffer full (%u samples), stopping", (unsigned)staged);
      isRecording = false;
    }
  }

  // the timed recording has to release the flag itself; the button path sets
  // it when it is tapped, and "JAWNREC" would otherwise refuse forever
  isRecording = false;
  record_end_ms = 0;

  // now, and only now, the flash: header first, then the whole recording in
  // 32 KB bites
  uint32_t spent = millis() - started_ms;
  uint32_t written = 0;
  int out_ch = (mic_channels == MIC_TDM_SLOTS) ? MIC_TDM_SLOTS : 1;
  if (create_wav_header_on_flash(WAV_FILE_PATH.c_str(), MIC_I2S_SAMPLE_RATE, MIC_I2S_BITS_PER_SAMPLE, out_ch)) {
    File audio_file = store->open(WAV_FILE_PATH.c_str(), FILE_APPEND);
    if (audio_file) {
      uint8_t *p = (uint8_t *)stage;
      uint32_t remaining = staged * 2;
      while (remaining > 0) {
        size_t chunk = remaining > 32768 ? 32768 : remaining;
        audio_file.write(p, chunk);
        p += chunk;
        remaining -= chunk;
        written += chunk;
      }
      audio_file.close();
    }
  }
  finalize_wav_sizes(WAV_FILE_PATH.c_str(), written, out_ch);
  free(stage);
  free(buf);
  // size() on an append handle reports the size it had when it was opened, so
  // ask the file again now that it is closed
  uint32_t file_size = 0;
  {
    File check = store->open(WAV_FILE_PATH.c_str());
    if (check) {
      file_size = check.size();
      check.close();
    }
  }
  // How continuous is what we just wrote? A clean waveform does not jump by
  // half scale between neighbours; a file full of those is a capture problem
  // rather than a speaker one.
  uint32_t cliffs = 0;
  int32_t biggest = 0;
  uint32_t cliff_last = 0;
  uint32_t gap_min = 0;
  uint32_t gap_max = 0;
  uint32_t sample_idx = 0;
  {
    File scan_file = store->open(WAV_FILE_PATH.c_str());
    if (scan_file) {
      scan_file.seek(44);
      static int16_t scan[2048];
      int16_t prev = 0;
      bool have_prev = false;
      while (true) {
        size_t n = scan_file.read((uint8_t *)scan, sizeof(scan));
        if (n < 2) {
          break;
        }
        int samples = n / 2;
        for (int s = 0; s < samples; s++) {
          int16_t v = scan[s];
          if (have_prev) {
            int32_t d = (int32_t)v - prev;
            if (d < 0) {
              d = -d;
            }
            if (d > biggest) {
              biggest = d;
            }
            if (d > 20000) {
              cliffs++;
              if (cliffs > 1) {
                uint32_t gap = sample_idx - cliff_last;
                if (gap_min == 0 || gap < gap_min) {
                  gap_min = gap;
                }
                if (gap > gap_max) {
                  gap_max = gap;
                }
              }
              cliff_last = sample_idx;
            }
          }
          prev = v;
          have_prev = true;
          sample_idx++;
        }
      }
      scan_file.close();
    }
  }
  deckLog("[mic] captured %u bytes in %u ms (%u B/s, expect ~32000), file %u bytes, %u cliffs, biggest step %d, gaps %u..%u",
          (unsigned)written, (unsigned)spent,
          spent ? (unsigned)((uint64_t)written * 1000 / spent) : 0, (unsigned)file_size,
          (unsigned)cliffs, (int)biggest, (unsigned)gap_min, (unsigned)gap_max);
  // hand the clip to the bridge the way the watch does, off this task so the
  // microphone is released at once. Compress it either way; the task sends only
  // if the bridge is up (and logs the clip so it can be shipped later)
  if (written > 44 && mic_channels != MIC_TDM_SLOTS) {
    deck_voice_wav = WAV_FILE_PATH;
    xTaskCreatePinnedToCore(deckVoiceShipTask, "VoiceShip", 8192, NULL, 1, NULL, 0);
  }
  vTaskDelete(NULL);
}

static void micRecordToggle(lv_event_t *e) {
  lv_obj_t *btn = lv_event_get_target_obj(e);
  lv_obj_t *label = lv_obj_get_child(btn, 0);
  if (isRecording) {
    isRecording = false;      // the task closes the file and patches the sizes
    lv_label_set_text(label, "Rec");
    return;
  }
  if (audio.isRunning()) {
    return;
  }
  // Same naming as the watch: /jawn/recordings/<epoch>.wav, so the manager - and
  // whisper.cpp behind it - can tell when something was said.
  if (!store->exists("/jawn/recordings")) {
    createDir(*store, "/jawn/recordings");
  }
  // keep the newest dozen recordings and say how much room is left: a full
  // filesystem turns every recording into an empty header
  pruneRecordings(12);
  deckLog("[mic] store free %u bytes before recording", (unsigned)store_free_bytes());
  deck_voice_ts = rightNow();
  WAV_FILE_PATH = "/jawn/recordings/" + String(deck_voice_ts) + ".wav";
  deckLog("[mic] recording %s", WAV_FILE_PATH.c_str());
  record_end_ms = 0;
  isRecording = true;
  lv_label_set_text(label, "Stop");
  xTaskCreatePinnedToCore(micCaptureTask, "MicTask", 6144, NULL, 4, NULL, 1);
}

// A timed recording, started from the host with "JAWNREC <seconds>". The point
// is that a codec experiment can then be run from the serial port alone:
// record, dump, listen - no screen tapping in between.
static void serialRecordStart(uint32_t seconds) {
  if (isRecording) {
    Serial.println("JAWNREC already recording");
    return;
  }
  if (seconds < 1) {
    seconds = 1;
  }
  if (seconds > 120) {
    seconds = 120;
  }
  if (!store->exists("/jawn/recordings")) {
    createDir(*store, "/jawn/recordings");
  }
  pruneRecordings(12);
  deck_voice_ts = rightNow();
  WAV_FILE_PATH = "/jawn/recordings/" + String(deck_voice_ts) + ".wav";
  record_end_ms = millis() + seconds * 1000;
  isRecording = true;
  xTaskCreatePinnedToCore(micCaptureTask, "MicTask", 6144, NULL, 4, NULL, 1);
  Serial.printf("JAWNREC %s for %u s, free %u\n", WAV_FILE_PATH.c_str(),
                (unsigned)seconds, (unsigned)store_free_bytes());
}

// "JAWNREG <reg> <value>", both hex: write one codec register from the host, so
// the serial interface can be tried out without a reflash.
static void serialRegWrite(String args) {
  int sp = args.indexOf(' ');
  if (sp <= 0) {
    Serial.println("JAWNREG bad args");
    return;
  }
  long reg = strtol(args.substring(0, sp).c_str(), NULL, 16);
  long value = strtol(args.substring(sp + 1).c_str(), NULL, 16);
  es7210WriteReg((uint8_t)reg, (uint8_t)value);
  Wire.beginTransmission(ES7210_ADDR);
  Wire.write((uint8_t)reg);
  Wire.endTransmission(false);
  Wire.requestFrom((uint8_t)ES7210_ADDR, (uint8_t)1);
  int got = Wire.available() ? Wire.read() : -1;
  Serial.printf("JAWNREG %02x = %02x (read back %02x)\n",
                (unsigned)reg, (unsigned)value, (unsigned)got);
}

// "JAWNSLOT <n>": which of the four TDM slots becomes the mono track.
static void serialSlotSet(String args) {
  long n = strtol(args.c_str(), NULL, 10);
  if (n < 0 || n >= MIC_TDM_SLOTS) {
    Serial.println("JAWNSLOT bad slot");
    return;
  }
  mic_mono_slot = (int)n;
  Serial.printf("JAWNSLOT %d\n", mic_mono_slot);
}

static void recordingPlay(lv_event_t *e) {
  if (isRecording) {
    return;
  }
  if (!store->exists(WAV_FILE_PATH.c_str())) {
    deckLog("[mic] nothing recorded yet (%s)", WAV_FILE_PATH.c_str());
    return;
  }
  if (audio.isRunning()) {
    // play again while it is playing = stop it
    deckLog("[mic] stopping playback");
    audio.stopSong();
    deckLog("[mic] stopped");
    return;
  }
  audio.setVolume(volumeLevel);
  bool connected = audio.connecttoFS(*store, WAV_FILE_PATH.c_str());
  deckLog("[mic] play %s: connect=%d running=%d volume=%d", WAV_FILE_PATH.c_str(),
          (int)connected, (int)audio.isRunning(), (int)volumeLevel);
  // set it again once the stream exists: this makes the slider take effect
  // whether it was moved before or during playback
  audio.setVolume(volumeLevel);
}

// Keep the newest `keep` recordings in /recordings, delete the rest oldest
// first, and if the flash is nearly full keep deleting until there is room
// again. The manager pulls these out; the deck should not fill its own flash
// with them (a full filesystem makes every write fail silently, which is how a
// recording ends up as a 44 byte header that plays nothing).
static void pruneRecordings(int keep) {
  // The listing array is capped, so a filesystem holding hundreds of small
  // recordings needs several passes before it has room again.
  for (int round = 0; round < 20; round++) {
    File dir = store->open("/jawn/recordings");
    if (!dir) {
      return;
    }
    String names[64];
    int count = 0;
    for (File f = dir.openNextFile(); f && count < 64; f = dir.openNextFile()) {
      if (!f.isDirectory()) {
        String n = String(f.name());
        int slash = n.lastIndexOf('/');
        if (slash >= 0) {
          n = n.substring(slash + 1);
        }
        names[count++] = n;
      }
      f.close();
    }
    dir.close();

    // the names are the epochs they were recorded at, so plain string order is
    // chronological order
    for (int i = 0; i < count - 1; i++) {
      for (int j = i + 1; j < count; j++) {
        if (names[j] < names[i]) {
          String t = names[i];
          names[i] = names[j];
          names[j] = t;
        }
      }
    }

    int doomed = count - keep;
    if (doomed < 0) {
      doomed = 0;
    }
    // a write needs room for the whole recording, not just its header, and a
    // nearly full filesystem starts failing before it is actually full
    while (doomed < count && store_free_bytes() < 512 * 1024) {
      doomed++;
    }
    if (doomed <= 0) {
      return;
    }
    for (int i = 0; i < doomed && i < count; i++) {
      String path = "/jawn/recordings/" + names[i];
      File df = store->open(path.c_str());
      uint32_t dsz = df ? (uint32_t)df.size() : 0;
      if (df) {
        df.close();
      }
      deckLog("[mic] deleting old recording %s (%u bytes)", path.c_str(), (unsigned)dsz);
      store->remove(path.c_str());
    }
    deckLog("[fs] prune round %d deleted %d of %d, free now %u",
            round, doomed < count ? doomed : count, count, (unsigned)store_free_bytes());
    if (store_free_bytes() >= 512 * 1024 || count == 0) {
      return;
    }
  }
}

// What is actually on the flash? A full filesystem makes every write fail
// (config.json and new recordings both come out empty) and nothing can be freed
// without knowing what took the room. Returns the bytes the files hold, so it
// can be compared with what the filesystem says is used.
static uint32_t fsAccount(File dir, int depth, int *files) {
  uint32_t total = 0;
  for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
    if (f.isDirectory()) {
      if (depth < 4) {
        total += fsAccount(f, depth + 1, files);
      }
    }
    else {
      total += f.size();
      (*files)++;
      deckLog("[fs] %s %u", String(f.name()).c_str(), (unsigned)f.size());
    }
    f.close();
  }
  return total;
}

static uint32_t flashReport() {
  int files = 0;
  File root = FFat.open("/");
  if (!root) {
    return 0;
  }
  uint32_t total = fsAccount(root, 0, &files);
  root.close();
  deckLog("[fs] free %u of %u bytes, %d files holding %u bytes",
          (unsigned)FFat.freeBytes(), (unsigned)FFat.totalBytes(), files, (unsigned)total);
  return total;
}

// A one shot speaker check: 1.5 seconds of 440 Hz on flash, played once, so
// "is the playback clean?" can be answered with no microphone involved. The
// file is left behind, so only the first boot after a flash plays it.
static void speakerSelfTest() {
  if (store->exists("/jawn/tone.wav")) {
    File check = store->open("/jawn/tone.wav");
    uint32_t have = 0;
    if (check) {
      have = check.size();
      check.close();
    }
    if (have >= 44 + 10000) {
      // a real tone from a previous boot: it has already been heard
      return;
    }
    // a dud from a boot with a full filesystem: drop it and try again
    deckLog("[mic] stale %u byte tone file, rewriting it", (unsigned)have);
    store->remove("/jawn/tone.wav");
  }
  const uint32_t frames = MIC_I2S_SAMPLE_RATE * 3 / 2;
  if (!create_wav_header_on_flash("/jawn/tone.wav", MIC_I2S_SAMPLE_RATE, MIC_I2S_BITS_PER_SAMPLE, 1)) {
    return;
  }
  File f = store->open("/jawn/tone.wav", FILE_APPEND);
  if (!f) {
    return;
  }
  int16_t chunk[256];
  uint32_t written = 0;
  for (uint32_t done = 0; done < frames;) {
    uint32_t n = frames - done;
    if (n > 256) {
      n = 256;
    }
    for (uint32_t i = 0; i < n; i++) {
      chunk[i] = (int16_t)(12000.0f * sinf(2.0f * 3.14159265f * 440.0f * (done + i) / MIC_I2S_SAMPLE_RATE));
    }
    f.write((uint8_t *)chunk, n * 2);
    written += n * 2;
    done += n;
  }
  f.close();
  finalize_wav_sizes("/jawn/tone.wav", written, 1);
  // a zero byte tone means the write failed (a full filesystem); drop the file
  // so the test runs again on the next boot
  uint32_t actual = 0;
  {
    File check = store->open("/jawn/tone.wav");
    if (check) {
      actual = check.size();
      check.close();
    }
  }
  if (actual < 44 + 10000) {
    deckLog("[mic] tone file came out %u bytes, removing it", (unsigned)actual);
    store->remove("/jawn/tone.wav");
    return;
  }
  deckLog("[mic] speaker test tone written (%u bytes), playing it once", (unsigned)actual);
  audio.setVolume(volumeLevel);
  if (audio.connecttoFS(*store, "/jawn/tone.wav")) {
    deckLog("[mic] tone playing");
  }
}
