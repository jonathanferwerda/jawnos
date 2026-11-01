void dualCoreTaskMaker(JSONVar task) {
  if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {

    int dct = dualCoreTasks.length();
    JSONVar dctask;

    if (task.hasOwnProperty("delay")) {
      dctask["delay"] = task["delay"];
    } else {
      dctask["delay"] = 0; // Default to 0 delay if not provided
    }
    dctask["millis"] = millis();
    dctask["task"] = task["task"];
    dualCoreTasks[dct] = dctask;
    xSemaphoreGive(taskMutex); 
  }

}

// Find a field's value in raw JSON text: where it starts and how long it is,
// without copying it out. The room push is ~25 KB: parsing the envelope only
// to re-stringify its payload (and parse it again on the other core) ran the
// heap into an abort on 2026-10-09, so callers that just need to reach the
// bytes -- the splice, the clock -- use the span and copy only what they parse.
static bool raw_json_field_span(const String &src, const char *key, int &start, int &len) {
  String needle = String("\"") + key + "\":";
  int k = src.indexOf(needle);
  if (k < 0) {
    return false;
  }
  int i = k + needle.length();
  while (i < (int)src.length() && (src[i] == ' ' || src[i] == '\t')) {
    i++;
  }
  if (i >= (int)src.length()) {
    return false;
  }
  int from = i;
  char c = src[i];
  if (c == '"') {
    i++;
    bool esc = false;
    while (i < (int)src.length()) {
      char d = src[i];
      if (esc) { esc = false; }
      else if (d == '\\') { esc = true; }
      else if (d == '"') { break; }
      i++;
    }
    if (i >= (int)src.length()) {
      return false;
    }
    start = from;
    len = i + 1 - from;      // keeps the quotes
    return true;
  }
  if (c == '{' || c == '[') {
    char close = (c == '{') ? '}' : ']';
    int depth = 0;
    bool in_str = false, esc = false;
    for (; i < (int)src.length(); i++) {
      char d = src[i];
      if (in_str) {
        if (esc) { esc = false; }
        else if (d == '\\') { esc = true; }
        else if (d == '"') { in_str = false; }
        continue;
      }
      if (d == '"') { in_str = true; }
      else if (d == c) { depth++; }
      else if (d == close) {
        depth--;
        if (depth == 0) {
          start = from;
          len = i + 1 - from;
          return true;
        }
      }
    }
    return false;
  }
  while (i < (int)src.length() && src[i] != ',' && src[i] != '}' && src[i] != ']' && src[i] != ' ') {
    i++;
  }
  start = from;
  len = i - from;
  return len > 0;
}

// Lift a value out of raw JSON text without building a tree.
static String raw_json_field(const String &src, const char *key) {
  int start = 0, len = 0;
  if (!raw_json_field_span(src, key, start, len)) {
    return "";
  }
  return src.substring(start, start + len);
}

// The homebase sends room_count as a JSON string ("2"), and Arduino_JSON's
// operator int() only reads JSON numbers (a string silently became 0). That 0
// then clamped every room back to 1 in presidents_buttons()/touch_button1(), so
// room 2 was unreachable. Read a value whether it is a string or a number.
static int json_int(JSONVar v) {
  const char *s = (const char *)v;   // NULL unless it is a JSON string
  if (s) {
    return String(s).toInt();
  }
  return (int)v;
}

void loop2(void * pvParameters) {
  esp_task_wdt_add(NULL);   // feed it below; a stalled loop2 reboots the chip
  for(;;) {
    String* incomingMsgPtr = nullptr;
        
    // Non-blocking check for a new string pointer from the queue
    if (bleIncomingQueue != NULL && xQueueReceive(bleIncomingQueue, &incomingMsgPtr, 0) == pdTRUE) {
      if (incomingMsgPtr != nullptr) {
        crumb("l0 received");
        String btmsg;
        btmsg = std::move(*incomingMsgPtr);   // steal the buffer: the push can be 25 KB
        delete incomingMsgPtr; // CRITICAL: Free the allocated heap memory!
        crumb("l1 moved");

        // A compressed bridge payload (the daemon's TX_ZLIB_*): inflate before
        // anything parses it. This runs here, not in ble_frame_ingest, because
        // the BLE callback task's stack is ~2 KB and the inflater overruns it.
        btmsg = ble_inflate_if_zlib(btmsg);
        crumb("l1b inflated");

        // the BLE callback cannot afford these prints (its task's stack runs
        // ~2 KB from full); loop2 can, and this is the first place the whole
        // message exists
        Serial.printf("[ble] rx %u bytes free=%u max=%u\n",
                      (unsigned)btmsg.length(), (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getMaxAllocHeap());
        Serial.printf("[stack] loop2 headroom %u\n", (unsigned)uxTaskGetStackHighWaterMark(NULL));
        Serial.print("Safely processing incoming Tasker JSON on loop2 stack: ");
        // the whole message can be several KB and the usb serial drops what it
        // cannot buffer while the host is slow, taking the markers after it down
        // with it; a prefix is enough to follow what arrived
        Serial.println(btmsg.substring(0, 120));
        crumb("l2 printed");

        // A room push is ~25 KB of JSON: the payload is cut out of the raw text
        // here so nothing but the one parse on core 1 ever builds a tree for it.
        bool room_raw = false;
        if (btmsg.indexOf("\"type\":\"room\"") >= 0) {
          int payload_at = 0, payload_len = 0;
          if (raw_json_field_span(btmsg, "payload", payload_at, payload_len) && payload_len > 2) {
            crumb("l2a span");
            String room_str = raw_json_field(btmsg, "room");
            crumb("l2b room");
            btmsg.remove(0, payload_at);
            crumb("l2c cut");
            btmsg.remove(payload_len);
            crumb("l3 carved");
            unsigned int pushed = (unsigned int)btmsg.length();
            if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
              president_fetch_room = room_str.toInt();
              if (president_fetch_room < 1) { president_fetch_room = 1; }
              president_payload = std::move(btmsg);
              president_data_ready = true;
              xSemaphoreGive(taskMutex);
              crumb("l4 staged");
              Serial.printf("[ble] room pushed (raw %u bytes)\n", pushed);
              Serial.flush();
            }
            room_raw = true;
          }
        }
        if (!room_raw) {
        JSONVar btMsg = JSON.parse(btmsg);
        if (JSON.typeof(btMsg) != "undefined") {
          // A relay envelope from the house: unwrap it when it names this watch.
          // The manager has already routed it, so a copy naming another chip is
          // stale and must not be applied here.
          if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "relay") {
            String relay_to = btMsg.hasOwnProperty("to") ? String((const char *)btMsg["to"]) : String("");
            if (relay_to == "" || relay_to == chip_id_maker()) {
              JSONVar relay_inner = btMsg["message"];
              if (JSON.typeof(relay_inner) == "object") { btMsg = relay_inner; }
              else { btMsg = JSON.parse("{}"); }
            }
            else { btMsg = JSON.parse("{}"); }
          }
          if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "button") {
            
            // Mutex protect because we are modifying global memory map strings
            if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
              if (before_me == "") before_me = "{}";
              JSONVar bm = JSON.parse(before_me);
              
              if (btMsg.hasOwnProperty("data") && btMsg["data"].hasOwnProperty("button")) {
                int button = 0;
                if (JSON.typeof(btMsg["data"]["button"]) == "string") {
                    button = String((const char*)btMsg["data"]["button"]).toInt();
                } else {
                    button = (int)btMsg["data"]["button"];
                }
                
                String buttonKey = "b" + String(button);
                bm[buttonKey] = btMsg["data"];
                before_me = JSON.stringify(bm);

                // not the map itself: the console drowns in 25 KB
                Serial.printf("[ble] %s updated (%u bytes)\n", buttonKey.c_str(), (unsigned)before_me.length());
              }
              xSemaphoreGive(taskMutex);
            }
          }
          if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "hello") {
            // the bridge names itself ("SM-S721W"): what the net room shows
            // in place of the address, which Android rotates underneath it
            const char *who = (const char *)btMsg["name"];
            if (who != nullptr) {
              snprintf(ble_peer_name, sizeof(ble_peer_name), "%s", who);
            }
            Serial.printf("[bt] hello: %s\n", ble_peer_name);
          }
          if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "battery") {
            // The house asked for the pack over the link it is already holding.
            // The same reading /device_query answers with, so a watch whose WiFi
            // is asleep still appears in the levels view.
            int bp = (int)watch.getBatteryPercent();
            int bmv = (int)(watch.getBattVoltage() * 1000);
            JSONVar reply;
            reply["type"] = "battery";
            reply["chip_id"] = chip_id_maker();
            reply["edt"] = "watch";
            reply["battery"] = bp;
            reply["battery_mv"] = bmv;
            reply["battery_status"] = watch.isCharging() ? (bp >= 100 ? "full" : "charging") : "discharging";
            ble_send(reply);
            Serial.printf("[bt] battery %d%% (%d mV)\n", bp, bmv);
          }
          if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "now_me") {
            // the phone pushes the whole picture over BLE: the homebase, the
            // authorization (freshly rotated), the clock offset and the room
            // shape. No network needed on this side.
            JSONVar params = btMsg["data"];
            if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
              // the same mapping the http /now_me handler uses
              homebaseIP = (const char *)params["homebase"];
              homebase = (const char *)params["ip"];
              homebase_preferredIP = homebaseIP;
              if (JSON.typeof(params["houses"]) != "undefined") {
                house_learn_json(String((const char *)params["houses"]));
              }
              house_remember_preferred();
              house_last_scan = 0;
              authorization = (const char *)params["authorization"];
              DEFAULT_SCREEN_TIMEOUT = params["screen_timeout"];
              long timestamp = params["timestamp"];
              rtc.setTime(timestamp);
              offset = params["offset"];
              rtc.offset = offset;
              room_count = json_int(params["room_count"]);
              room_max = json_int(params["room_max"]) || room_max;
              if (params.hasOwnProperty("voice_trigger")) {
                const char *vt = (const char *)params["voice_trigger"];
                if (vt) { voice_trigger = vt; voice_trigger_apply(); }
              }
              if (params.hasOwnProperty("voice_floor")) {
                const char *vf = (const char *)params["voice_floor"];
                if (vf) { voice_floor = vf; }
              }
              if (params.hasOwnProperty("computer_name")) {
                const char *cn = (const char *)params["computer_name"];
                if (cn && cn[0]) { computer_name = cn; }
              }
              if (DEFAULT_SCREEN_TIMEOUT < 30000) {
                DEFAULT_SCREEN_TIMEOUT = 30000;
              }
              buttoned_before = false;   // ask the bridge for fresh buttons
              xSemaphoreGive(taskMutex);
              ble_now_me_ready = true;
              Serial.println("[ble] now_me applied");
              Serial.flush();
            }
          }
          else if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "wifi") {
            // the panel sent our network credentials over BLE (the watch cannot
            // reach a LAN it is not on yet). Store them and let loop() join;
            // wifi_server() blocks, so it must not run here on loop2.
            JSONVar w = btMsg["data"];
            if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
              if (w.hasOwnProperty("ssid")) { ssid = (const char *)w["ssid"]; }
              if (w.hasOwnProperty("password")) { password = (const char *)w["password"]; }
              if (w.hasOwnProperty("ap_ssid")) { ap_ssid = (const char *)w["ap_ssid"]; }
              if (w.hasOwnProperty("ap_password")) { ap_password = (const char *)w["ap_password"]; }
              wifi_enabled = true;
              wifi_join_requested = true;
              xSemaphoreGive(taskMutex);
              Serial.println("[ble] wifi credentials received");
              Serial.flush();
            }
          }
          else if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "room") {
            // a room payload pushed by the bridge: the same picture the HTTP
            // fetch returns, handed to loop() through the existing apply path
            if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
              president_fetch_room = btMsg["data"]["room"];
              president_payload = JSON.stringify(btMsg["data"]["payload"]);
              president_data_ready = true;
              xSemaphoreGive(taskMutex);
              Serial.println("[ble] room pushed");
              Serial.flush();
            }
          }
          else if (btMsg.hasOwnProperty("type") &&
                   (String((const char *)btMsg["type"]) == "toggle" || String((const char *)btMsg["type"]) == "toggles")) {
            // a toggle flipped somewhere else (a phone press, an alarm, an
            // appointment): light up every button that has that app
            if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
              JSONVar updates = JSON.parse("{}");
              if (String((const char *)btMsg["type"]) == "toggles") {
                updates = btMsg["data"];
              }
              else {
                updates[(const char *)btMsg["data"]["app"]] = btMsg["data"]["state"];
              }
              JSONVar bm = JSON.parse(before_me);
              JSONVar keys = bm.keys();
              for (int i = 0; i < keys.length(); i++) {
                String k = keys[i];
                String app = (const char *)bm[k]["app"];
                if (app.length() > 0 && updates.hasOwnProperty(app.c_str())) {
                  String state = (const char *)updates[app.c_str()];
                  bm[k]["toggle"] = (state == "on") ? 1 : 0;
                }
              }
              before_me = JSON.stringify(bm);
              ble_toggle_refresh = true;
              Serial.println("[ble] toggles applied");
              xSemaphoreGive(taskMutex);
            }
          }
          else if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "voice_done") {
            // the server transcribed the clip and filed it: loop() deletes the
            // watch's local copy (it is on core 1, where the mic task runs, so the
            // filesystem is not touched from two cores)
            long t = btMsg["ts"];
            voice_done_ts = t;
            voice_acked_ts = t;
            Serial.printf("[voice] done ack ts=%ld\n", t);
          }
          else if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "voice_recv") {
            // the clip arrived whole: stop the voice task retrying it. The file
            // stays until voice_done says it was transcribed and filed.
            long t = btMsg["ts"];
            voice_acked_ts = t;
            Serial.printf("[voice] recv ack ts=%ld\n", t);
          }
          else if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "say") {
            // the guide associate's answer: loop() shows it on the screen
            if (btMsg.hasOwnProperty("data") && btMsg["data"].hasOwnProperty("text")) {
              String t;
              if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
                t = (const char *)btMsg["data"]["text"];
                say_text = t;
                say_text_pending = true;
                xSemaphoreGive(taskMutex);
              }
              Serial.printf("[say] %s\n", t.c_str());
            }
          }
          else if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "say_audio_ready") {
            // the spoken answer is on the server: pull it over WiFi, or leave it
            // to the BLE parts (the server only sends this when the device's own
            // web server answered, but WiFi can still have dropped since)
            if (btMsg.hasOwnProperty("data") && btMsg["data"].hasOwnProperty("id")) {
              String id = (const char *)btMsg["data"]["id"];
              String base = (const char *)btMsg["data"]["base"];
              if (id.length() && base.length() && WiFi.status() == WL_CONNECTED) {
                if (say_fetch_req) { delete say_fetch_req; }
                say_fetch_req = new String(base + "/watch/reply_audio?id=" + id);
                if (say_fetch_req) {
                  say_fetch_pending = true;
                  Serial.println("[say] WiFi audio ready; fetching");
                }
              }
              else {
                Serial.println("[say] WiFi audio ready but no WiFi; waiting for BLE parts");
              }
            }
          }
          else if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "say_audio") {
            // one part of the spoken answer: PCM, base64, with the sample rate on
            // the first part and a last flag on the final one. Decoded and pushed
            // into the stream here (core 0, the BLE task's own loop); the codec
            // work happens on the playback task loop() starts.
            if (btMsg.hasOwnProperty("data") && btMsg["data"].hasOwnProperty("audio")) {
              int seq = json_int(btMsg["data"]["seq"]);
              int rate = json_int(btMsg["data"]["rate"]);
              bool last = btMsg["data"]["last"] ? true : false;
              String a = (const char *)btMsg["data"]["audio"];
              // A part carries a sequence number. One without it is a whole clip
              // in an older format (the MP3 the first cut of this feature sent):
              // play nothing rather than push an mp3 through the PCM writer.
              if (!btMsg["data"].hasOwnProperty("seq")) {
                Serial.println("[say] audio without a part number (older sender) ignored");
              }
              else if (seq <= 0) {
                if (!say_stream) {
                  say_stream = xStreamBufferCreate(SAY_STREAM_BYTES, 128);
                }
                if (say_stream) {
                  xStreamBufferReset(say_stream);
                  say_stream_last = false;
                  say_stream_dead = false;
                  say_stream_rate = (rate > 4000 && rate < 96000) ? (uint32_t)rate : 8000;
                  // The sender's estimate of the whole clip decides how much to
                  // hold back before speaking. Hold the lot when the answer is
                  // short enough to fit (the common case - then it cannot pause
                  // at all), and two seconds of it otherwise: enough cushion to
                  // ride out the link's jitter, which is what a pause is.
                  uint32_t total = (uint32_t)json_int(btMsg["data"]["total"]);
                  uint32_t pre = total ? total : SAY_PRELOAD_MIN;
                  if (pre < SAY_PRELOAD_MIN) { pre = SAY_PRELOAD_MIN; }
                  if (pre > SAY_PRELOAD_MAX) { pre = SAY_PRELOAD_MAX; }
                  say_stream_total = total;
                  say_stream_preload = pre;
                  say_stream_start = true;
                }
              }
              if (say_stream && !say_stream_dead && a.length()) {
                size_t cap = (a.length() * 3) / 4 + 8;
                uint8_t *buf = (uint8_t *)ps_malloc(cap);
                if (!buf) { buf = (uint8_t *)malloc(cap); }
                if (buf) {
                  size_t olen = 0;
                  int rc = mbedtls_base64_decode(buf, cap, &olen, (const unsigned char *)a.c_str(), a.length());
                  if (rc == 0 && olen) {
                    // Wait for room rather than drop: the synthesizer runs faster
                    // than the audio plays, so the buffer fills by design, and a
                    // dropped part is an audible hole. The playback task drains
                    // it, and marks the stream dead if it cannot play at all (a
                    // recording in progress), which stops this from waiting on
                    // nobody.
                    size_t sent = 0;
                    while (sent < olen && !say_stream_dead) {
                      size_t n = xStreamBufferSend(say_stream, buf + sent, olen - sent, pdMS_TO_TICKS(500));
                      if (!n) { continue; }
                      sent += n;
                    }
                    if (sent < olen) { Serial.println("[say] audio part abandoned"); }
                    say_stream_at = millis();
                  }
                  else {
                    Serial.printf("[say] audio part decode failed rc=%d\n", rc);
                  }
                  free(buf);
                }
              }
              if (last) { say_stream_last = true; }
              Serial.printf("[say] audio part %d%s (%u chars)\n", seq, last ? " last" : "", (unsigned)a.length());
            }
          }
        }
        }
      }
    }

    // --- SECTION B: YOUR EXISTING OUTBOUND PROCESSING CODE ---
    // (Keep your existing xSemaphoreTake(taskMutex...) code block that iterates over btMessages here)

    // Essential: Prevents Core 0 Watchdog starvation panics
    esp_task_wdt_reset();
    vTaskDelay(pdMS_TO_TICKS(10)); 

    // once the bridge is up, ask for anything that changed while the watch was
    // asleep: the phone queues nothing for a sleeping peripheral, so the watch
    // asks on its own (from here, so the ui never waits on the radio)
    static bool state_requested = false;
    if (!deviceConnected) {
      state_requested = false;
    }
    else if (!ble_state_off && !state_requested && ble_connected_at != 0 && millis() - ble_connected_at > 3000) {
      state_requested = true;
      JSONVar req = JSON.parse("{}");
      req["type"] = "state_request";
      req["chip_id"] = chip_id_maker();
      req["edt"] = "watch";
      // where the watch currently believes jawn is: the bridge that hears this
      // can re-home it to itself when they differ
      req["homebase"] = homebaseIP;
      ble_send(req);
      Serial.println("[ble] state requested");
    }
    



    String taskToExecute = ""; // Local variable to hold the task name
    int taskIndexToRemove = -1; // Keep track of which slot to clear

    if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
      // btMessages used to be drained here; taps now go out on the wire
      // directly from when_i_get_in()/ble_flush_wigi() with a local envelope,
      // because this shared map was only ever touched safely from one core at
      // a time and cross-core use of it panicked the chip (StoreProhibited)
      int taskCount = dualCoreTasks.length();
      if (taskCount > 0) {
        for (int i = 0; i < taskCount; i++) {
          if (dualCoreTasks[i] == null) continue; 

          JSONVar dct = dualCoreTasks[i];
          String dctstring = (const char *)dct["task"];
          long scheduledTime = dct["millis"]; 
          long taskDelay = 0;

          if (dct.hasOwnProperty("delay")) {
              taskDelay = dct["delay"];
          }
          if (millis() - scheduledTime >= taskDelay) {
            taskToExecute = (const char *)dct["task"]; 
            
            // Clear the slot immediately while locked
            dualCoreTasks[i] = JSONVar(); 
            taskIndexToRemove = i; 

            // Break the loop early so we can execute this single task safely
            break; 
          }
        }
      }
      if (taskIndexToRemove != -1) {
        // Clear it by wiping its internal object keys cleanly
        dualCoreTasks[taskIndexToRemove] = JSONVar(); 
      }
      xSemaphoreGive(taskMutex); 
    }
    if (taskToExecute != "") {
      if (taskToExecute == "homebasePing") {
        homebasePing(); // Wi-Fi lag here will NO LONGER stall Core 1
      }
      // Add other task conditions here if needed
    }
    // Remember to leave a delay so Core 0 can handle Wi-Fi/System tasks
    vTaskDelay(10 / portTICK_PERIOD_MS); 
  }
}

