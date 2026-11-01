void audio_playback_loop_task(void *pvParameters) {
    Serial.println("[Player] Playback track active.");
    watch.getAudioOutput()->setVolume(volumeLevel);
    uint32_t started_ms = millis();
    size_t pcm_bytes = file_source ? (size_t)file_source->getSize() : 0;

    while (isPlaying) {
        if (wav->isRunning()) {
            if (!wav->loop()) {
                wav->stop();
                isPlaying = false;
            }
        } else {
            isPlaying = false;
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }

    uint32_t spent = millis() - started_ms;
    if (pcm_bytes && spent) {
      // 16 kHz mono 16-bit is ~32000 B/s; a very different number means the sink
      // is being clocked at the wrong rate
      Serial.printf("[Player] played %u PCM bytes in %u ms (%u B/s, expect ~32000)\n",
                    (unsigned)pcm_bytes, spent,
                    (unsigned)((uint64_t)pcm_bytes * 1000 / spent));
    }

    // Safely clean memory resources upon completion
    if(wav) { delete wav; wav = nullptr; }
    if(file_source) { delete file_source; file_source = nullptr; }
    if(out_hardware) { delete out_hardware; out_hardware = nullptr; }
    if (say_wifi_playing) {
      say_wifi_playing = false;
      FFat.remove("/reply.wav");
      if (voiceAwaitingReply) { voiceAwaitingReply = false; buttonMillis = millis(); }
    }

    // Safely restore playback button graphics text layer (a reply playback may
    // have used the same task; the button can also be gone after a room rebuild)
    if (playbtn1) {
      lv_obj_t * btn_label = lv_obj_get_child(playbtn1, 0);
      if (btn_label) { lv_label_set_text(btn_label, "Play Recording"); }
    }

    vTaskDelete(NULL);
}

// The reply's playback task: open the codec at the stream's own rate, then write
// whatever the stream hands over, until the final part has played out. It is its
// own task rather than the generator one because there is no file here: the
// samples are still being synthesized on the other machine.
void say_playback_task(void *pvParameters) {
  AudioOutputIf *codec = watch.getAudioOutput();
  uint32_t rate = say_stream_rate;
  if (!codec || !codec->open(16, 1, rate)) {
    Serial.println("[say] codec open failed");
    if (say_stream) { xStreamBufferReset(say_stream); }
    say_stream_dead = true;
    isPlaying = false;
    if (voiceAwaitingReply) { voiceAwaitingReply = false; buttonMillis = millis(); }
    vTaskDelete(NULL);
  }
  codec->setVolume(volumeLevel);
  Serial.printf("[say] playing at %u Hz\n", (unsigned)rate);
  // Hold back until the cushion the first part named is in hand (or the sender
  // has sent everything): speaking too early is what made the playback stutter.
  uint32_t waited = millis();
  while (!say_stream_last && say_stream && xStreamBufferBytesAvailable(say_stream) < say_stream_preload
         && millis() - waited < 4000 && !say_stream_dead) {
    vTaskDelay(pdMS_TO_TICKS(20));
  }
  Serial.printf("[say] preload %u/%u bytes\n", say_stream ? (unsigned)xStreamBufferBytesAvailable(say_stream) : 0, (unsigned)say_stream_preload);
  uint8_t buf[512];
  uint32_t started = millis();
  uint32_t bytes = 0;
  bool starved = false;
  while (true) {
    size_t n = say_stream ? xStreamBufferReceive(say_stream, buf, sizeof(buf), pdMS_TO_TICKS(SAY_STREAM_STALL_MS)) : 0;
    if (!n) {
      if (say_stream_last && (say_stream ? xStreamBufferIsEmpty(say_stream) : true)) {
        break;   // the answer has arrived and played
      }
      // nothing for a while and more is promised: wait, but not forever
      if (millis() - say_stream_at > 6000) { starved = true; break; }
      continue;
    }
    if (!codec->write(buf, n)) { break; }
    bytes += n;
  }
  codec->close();
  uint32_t spent = millis() - started;
  Serial.printf("[say] played %u bytes in %u ms%s\n", (unsigned)bytes, (unsigned)spent, starved ? " (starved)" : "");
  // Nothing is listening any more: let any part still being pushed give up
  // instead of waiting on a buffer nobody drains, and clear what is left.
  say_stream_dead = true;
  if (say_stream) { xStreamBufferReset(say_stream); }
  isPlaying = false;
  // the answer has been said: the screen may time out again from now
  if (voiceAwaitingReply) { voiceAwaitingReply = false; buttonMillis = millis(); }
  vTaskDelete(NULL);
}

// Start the spoken answer. Called from loop() (core 1) when the first part has
// landed, so the codec and the task live where the other audio does.
static void say_stream_play() {
  if (isPlaying || isRecording) {
    // Cannot speak now (the person is recording, or audio is already playing):
    // let the parts go instead of buffering sound nobody will hear.
    say_stream_dead = true;
    if (say_stream) { xStreamBufferReset(say_stream); }
    return;
  }
  if (!say_stream) { return; }
  say_stream_dead = false;
  isPlaying = true;
  // If the playback task cannot be created, isPlaying would stay set with nothing
  // left to clear it - and the listener steps aside for any playback, so voice
  // would go quietly deaf until the next reboot. Clear it here instead.
  if (xTaskCreatePinnedToCore(say_playback_task, "SayTask", 4096, NULL, 2, NULL, 1) != pdPASS) {
    Serial.println("[say] playback task could not start");
    isPlaying = false;
    say_stream_dead = true;
    if (say_stream) { xStreamBufferReset(say_stream); }
  }
}


// Fetch a WiFi reply WAV the server announced. The URL is handed over from
// loop2 (core 0) through say_fetch_req; the download runs off the UI task, and
// loop() plays the file once it is on flash.
static void say_fetch_task(void *pv) {
  String* req = (String *)pv;
  String url = req ? *req : String();
  delete req;
  if (url.length()) {
    https_download(FFat, url, "/reply.wav");
    File f = FFat.open("/reply.wav");
    if (f && f.size() > 44) { say_wifi_ready = true; }
    if (f) { f.close(); }
    Serial.printf("[say] WiFi audio %s\n", say_wifi_ready ? "ready" : "fetch failed");
  }
  say_fetch_running = false;
  vTaskDelete(NULL);
}

// Play the WAV the WiFi reply task downloaded. The existing WAV playback task
// drives the codec; the flag tells its completion to end the reply hold and
// delete the one-shot file.
static void say_wifi_play(const char *path) {
  if (isPlaying || isRecording) { return; }
  if (!path || !FFat.exists(path)) { return; }
  isPlaying = true;
  say_wifi_playing = true;
  out_hardware = new LilyGoAudioSink(watch.getAudioOutput());
  file_source = new AudioFileSourceFATFS(path);
  wav = new AudioGeneratorWAV();
  wav->begin(file_source, out_hardware);
  if (xTaskCreatePinnedToCore(audio_playback_loop_task, "SayWav", 4096, NULL, 2, NULL, 1) != pdPASS) {
    Serial.println("[say] WiFi playback task could not start");
    isPlaying = false;
    say_wifi_playing = false;
    if (wav) { delete wav; wav = nullptr; }
    if (file_source) { delete file_source; file_source = nullptr; }
    if (out_hardware) { delete out_hardware; out_hardware = nullptr; }
  }
}

void when_i_get_in(JSONVar wigi_item, String url) {
  
  int l = wigi.length();
  if (l < 0) {
    l = 0;
  }
  long timestamp = timestamp_maker();  
  wigi_item["timestamp"] = timestamp;
  int room = wigi_item["room"];
  int button = wigi_item["button"];
  
  JSONVar bm = JSON.parse(before_me);
  
  int rooming = (((room - 1 ) * room_max) + button);
  String roomings = String(rooming);
  JSONVar buttonski = bm["b" + roomings];
  String bs = JSON.stringify(buttonski);
  
  String movement = (const char *)buttonski["movement"];
  int toggle = buttonski["toggle"];
  
  if (movement == "start") {
    if (toggle == 1) {
      bm["b" + roomings]["toggle"] = 0;
    }
    else {
      bm["b" + roomings]["toggle"] = 1;
    }
    before_me = JSON.stringify(bm);
    room_redraw = true;          // rebuilt from loop(): this ran inside a button
  }
  Serial.print("Defice connected: ");
  Serial.println(deviceConnected);
  if (ble_link_ready()) {
    // a local envelope: btMessages was shared with loop2 on core 0, and staging
    // a tap into it from here raced with that reader until resetting it from
    // this side panicked the chip (StoreProhibited)
    JSONVar envelope = JSON.parse("{}");
    envelope["type"] = "button";
    envelope["payload"] = wigi_item;
    url = url_maker(url);
    envelope["url"] = url;
    String payload = JSON.stringify(envelope);
    String message = "Hello from T-Watch!";
    Serial.println(message);
    // Fire the notification to the connected phone (chunked to the link's MTU)
    ble_notify_payload(payload);

    Serial.print("Sent to Tasker: ");
    Serial.println(message);
  } else {
    wigi[l] = wigi_item;
  }
}

// Hand a button tap to the phone bridge when it is up: the homebase fetches the
// same url the tap would have (ble_message_processor's queued-tap fetch), but
// the watch does not block the UI on a 1-2 s TLS round trip, so a press
// (vol +/-, play, ...) lands at once. Returns true when it went over BLE, so
// the caller skips https_request().
static bool tap_over_ble(int which, int toggle, const String &url) {
  if (!ble_link_ready()) {
    return false;
  }
  JSONVar updater;
  updater["room"] = room;
  updater["button"] = which;
  updater["toggle"] = toggle;
  when_i_get_in(updater, url);
  return true;
}

String generateRandomString(int length) {
  // Define the pool of characters you want to use
  const char charset[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  const int charsetSize = sizeof(charset) - 1;
  
  String randomString = "";
  randomString.reserve(length); // Pre-allocate memory to prevent RAM fragmentation

  for (int i = 0; i < length; i++) {
    // esp_random() fetches a true 32-bit hardware random unsigned integer
    uint32_t randomNum = esp_random(); 
    
    // Use modulo to safely pick an index within our character pool range
    int randomIndex = randomNum % charsetSize;
    
    randomString += charset[randomIndex];
  }

  return randomString;
}

// Taps made while no central was attached sit in wigi until the webapp's WIGI
// button collects them; when a central comes back, hand the fresh ones over
// over BLE so a momentary drop does not strand them. Anything older than five
// minutes stays in the queue for the webapp to pull.
void ble_flush_wigi() {
  int l = wigi.length();
  if (l <= 0) {
    return;
  }
  // the link must be up AND subscribed, or these notifies are dropped too
  if (!ble_link_ready()) {
    return;
  }
  if (homebaseIP.length() == 0 || authorization.length() == 0) {
    return;
  }
  long now = timestamp_maker();
  JSONVar remainder = JSON.parse("[]");
  int keep = 0;
  for (int i = 0; i < l; i++) {
    JSONVar item = wigi[i];
    if (!item.hasOwnProperty("room") || !item.hasOwnProperty("button")) {
      continue;
    }
    long ts = item["timestamp"];
    if (now - ts > 300) {
      remainder[keep] = item;
      keep++;
      continue;
    }
    int room_n = item["room"];
    int button_n = item["button"];
    int toggle_n = item["toggle"];
    String url = "https://" + homebaseIP +
      "/watch/button?room=" + room_n +
      "&button=" + button_n +
      "&toggle=" + toggle_n;
    // a local envelope, same reason as when_i_get_in(): the shared btMessages
    // map is what raced with loop2 and panicked the chip
    JSONVar envelope = JSON.parse("{}");
    envelope["type"] = "button";
    envelope["payload"] = item;
    envelope["url"] = url_maker(url);
    String payload = JSON.stringify(envelope);
    ble_notify_payload(payload);
    Serial.println("Flushed a queued tap over BLE");
    delay(50);
  }
  wigi = remainder;
}

// The step count used to leave the watch only over its own access point: the
// webapp's WIGI collection hit /wigi, handed the samples over and reset the
// pedometer. A wrist that only ever talks BLE recorded no steps at all. This
// hands the count over the same link the taps use, as one small message that
// carries `base` - the cumulative value just before it. The server deltas the
// sample against that base, exactly as the whole-array AP batch is deltas
// against zero, so the pedometer is left running (the face keeps its count) and
// neither side has to remember anything across a message: a restart cannot
// double-count. A count that went backwards means the AP path reset the
// pedometer underneath us, and base drops to zero with it.
static void ble_push_steps(bool force) {
  if (!ble_link_ready()) {
    return;
  }
  if (homebaseIP.length() == 0 || authorization.length() == 0) {
    return;
  }
  uint32_t counter = watch.getStepCounter();
  if (counter == bleStepsBase) {
    return;                    // nothing since the last hand-off
  }
  // the automatic (link-up) push keeps the minute cadence step_writer uses; a
  // real sample passes force and is never held back
  if (!force && ble_steps_pushed_at != 0 && millis() - ble_steps_pushed_at < BLE_STEPS_MIN_INTERVAL_MS) {
    return;
  }
  if (counter < bleStepsBase) {
    bleStepsBase = 0;          // a reset happened elsewhere
  }
  JSONVar sample = JSON.parse("{}");
  sample["timestamp"] = timestamp_maker();
  sample["steps"] = (double)counter;
  JSONVar data = JSON.parse("[]");
  data[0] = sample;
  JSONVar envelope = JSON.parse("{}");
  envelope["type"] = "steps";
  envelope["chip_id"] = chip_id_maker();
  envelope["edt"] = "watch";
  envelope["base"] = (double)bleStepsBase;
  envelope["data"] = data;
  String payload = JSON.stringify(envelope);
  // one notify only: a truncated message is a silently lost batch
  if (payload.length() > 480) {
    return;
  }
  ble_notify_payload(payload);
  bleStepsBase = counter;
  ble_steps_pushed_at = millis();
  Serial.printf("[ble] steps %u pushed\n", (unsigned)counter);
}

void mb1(lv_event_t *e) {
  if (b1_toggle == 0) {
    b1_toggle = 1;
  } else {
    b1_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=1&toggle=" + b1_toggle;
  if (tap_over_ble(1, b1_toggle, r)) {
    return;   // the bridge carries the tap; no blocking TLS round trip
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 1;
    updater["toggle"] = b1_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  
  b1_toggle = result["toggle"];
  
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b1_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);

  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);  
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 1)] = result;
  before_me = JSON.stringify(bm);
}

void mb2(lv_event_t *e) {
  if (b2_toggle == 0) {
    b2_toggle = 1;
  } else {
    b2_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=2&toggle=" + b2_toggle;
  if (tap_over_ble(2, b2_toggle, r)) {
    return;   // the bridge carries the tap; no blocking TLS round trip
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 2;
    updater["toggle"] = b2_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b2_toggle = result["toggle"];
  lv_color_t c;
  lv_color_t t;
  lv_obj_t * b = lv_event_get_target_obj(e);
  if (b2_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);  
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);   
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);                 
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 2)] = result;
  before_me = JSON.stringify(bm);
}
void mb3(lv_event_t *e) {
  if (b3_toggle == 0) {
    b3_toggle = 1;
  } else {
    b3_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=3&toggle=" + b3_toggle;
  if (tap_over_ble(3, b3_toggle, r)) {
    return;   // the bridge carries the tap; no blocking TLS round trip
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 3;
    updater["toggle"] = b3_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b3_toggle = result["toggle"];
  // Serial.println(b3_toggle);
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b3_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0,0,0);
   
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 3)] = result;
  before_me = JSON.stringify(bm);
}
void mb4(lv_event_t *e) {
  if (b4_toggle = 0) {
    b4_toggle = 1;
  } else {
    b4_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=4&toggle=" + b4_toggle;
  if (tap_over_ble(4, b4_toggle, r)) {
    return;   // the bridge carries the tap; no blocking TLS round trip
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 4;
    updater["toggle"] = b4_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b4_toggle = result["toggle"];
  lv_color_t c;
  lv_color_t t;
  lv_obj_t * b = lv_event_get_target_obj(e);
  if (b4_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);  
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 4)] = result;
  before_me = JSON.stringify(bm);

}
void mb5(lv_event_t *e) {
  if (b5_toggle == 0) {
    b5_toggle = 1;
  } else {
    b5_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=5&toggle=" + b5_toggle;
  if (tap_over_ble(5, b5_toggle, r)) {
    return;   // the bridge carries the tap; no blocking TLS round trip
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 5;
    updater["toggle"] = b5_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b5_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);

  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
 lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
 lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);  
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 5)] = result;
  before_me = JSON.stringify(bm);
}
void mb6(lv_event_t *e) {
  if (b6_toggle == 0) {
    b6_toggle = 1;
  } else {
    b6_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=6&toggle=" + b6_toggle;
  if (tap_over_ble(6, b6_toggle, r)) {
    return;   // the bridge carries the tap; no blocking TLS round trip
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 6;
    updater["toggle"] = b6_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b6_toggle = result["toggle"];
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b6_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
 lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
 lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);  
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 6)] = result;
  before_me = JSON.stringify(bm);
}


static void touch_button2(lv_event_t *e) {
  notification_viewing = 0;
  clock_writer();
}

