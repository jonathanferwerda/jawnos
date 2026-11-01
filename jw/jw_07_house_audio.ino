// ---- House machines -------------------------------------------------------
// A watch is a one-link peripheral with one stored homebase, so when that
// machine leaves the LAN the wrist used to wait for the next Now Me. These
// helpers let it find another House machine (computer/mobile/server) that is
// actually up. The preferred address always wins when it answers, so a phone
// that comes back reclaims the watch.
static void house_add(const String &host, int arm, int coms, int bestow) {
  if (host.length() == 0 || host == "0.0.0.0" || arm <= 0) { return; }
  for (int i = 0; i < house_node_count; i++) {
    if (house_nodes[i].host == host && house_nodes[i].arm == arm) {
      // refresh the ports of an entry mDNS or Now Me named again
      if (coms > 0) { house_nodes[i].coms = coms; }
      if (bestow > 0) { house_nodes[i].bestow = bestow; }
      return;
    }
  }
  if (house_node_count >= HOUSE_MAX) { return; }
  house_nodes[house_node_count].host = host;
  house_nodes[house_node_count].arm = arm;
  house_nodes[house_node_count].coms = coms;
  house_nodes[house_node_count].bestow = bestow;
  house_node_count++;
}

static void house_learn_json(const String &js) {
  // Now Me's `houses` value: [{"ip":"192.168.2.3","arm":45547,...}, ...]
  if (js.length() < 2) { return; }
  JSONVar list = JSON.parse(js);
  if (JSON.typeof(list) != "array") { return; }
  for (int i = 0; i < (int)list.length(); i++) {
    JSONVar h = list[i];
    if (JSON.typeof(h) != "object") { continue; }
    String ip = (const char *)h["ip"];
    int arm = (int)h["arm"];
    int coms = JSON.typeof(h["coms"]) != "undefined" ? (int)h["coms"] : 0;
    int bestow = JSON.typeof(h["bestow"]) != "undefined" ? (int)h["bestow"] : 0;
    if (arm <= 0 && ip.length()) { arm = 45547; }
    house_add(ip, arm, coms, bestow);
  }
}

static void house_remember_preferred() {
  // The address the House handed us, and the machine's own address, are always
  // candidates even before mDNS has answered.
  if (homebaseIP.length() == 0) { return; }
  String host = homebaseIP;
  int arm = 0;
  int split = host.lastIndexOf(':');
  if (split > 0) {
    arm = host.substring(split + 1).toInt();
    host = host.substring(0, split);
  }
  if (arm > 0) { house_add(host, arm, 0, 0); }
}

static bool house_probe(const String &host, int arm) {
  // A live House machine answers /watch/time with this watch's own Now Me
  // pair. The address is on the LAN, so a dead one fails fast; the timeout is
  // short because this runs on the House task, not in the UI path.
  // A TLS handshake plus HTTPClient needs tens of KB; keep that heap for the UI
  // and the listener when the watch is already tight.
  if (ESP.getFreeHeap() < 60000) { return false; }
  if (WiFi.status() != WL_CONNECTED || authorization.length() == 0) { return false; }
  if (host.length() == 0 || arm <= 0) { return false; }
  String url = "https://" + host + ":" + String(arm) + "/watch/time?edt=watch&chip_id="
             + urlEncode(chip_id_maker()) + "&authorization=" + urlEncode(authorization)
             + "&timestamp=" + String(timestamp_maker());
  WiFiClientSecure conn;
  conn.setInsecure();
  HTTPClient https;
  https.setTimeout(2500);
  if (!https.begin(conn, url)) { return false; }
  int code = https.GET();
  // A denial is a template, and Mojo answers it 200 with a ~130 KB body, so the
  // status and even the content type are the same as the timestamp answer. The
  // length is what tells them apart; never read the denial into the heap.
  int size = https.getSize();
  if (code != HTTP_CODE_OK || size <= 0 || size > 4096) { https.end(); return false; }
  String body = https.getString();
  https.end();
  return body.indexOf("timestamp") >= 0;
}

static int house_active_index() {
  // The candidate the active homebaseIP names, or -1 when it is none of them.
  String host = homebaseIP;
  int arm = 0;
  int split = host.lastIndexOf(':');
  if (split > 0) {
    arm = host.substring(split + 1).toInt();
    host = host.substring(0, split);
  }
  if (arm <= 0) { return -1; }
  for (int i = 0; i < house_node_count; i++) {
    if (house_nodes[i].host == host && house_nodes[i].arm == arm) { return i; }
  }
  return -1;
}

static void house_scan_mdns() {
  if (WiFi.status() != WL_CONNECTED) { return; }
  if (ESP.getFreeHeap() < 45000) { return; }
  int n = MDNS.queryService("jawnos-house", "tcp");
  for (int i = 0; i < n; i++) {
    String purpose = MDNS.txt(i, "purpose");
    if (purpose != "computer" && purpose != "mobile" && purpose != "server") { continue; }
    String host = MDNS.address(i).toString();
    if (host == "0.0.0.0" || host.length() == 0) { host = MDNS.hostname(i); }
    int arm = MDNS.txt(i, "arm").toInt();
    int coms = MDNS.txt(i, "coms").toInt();
    int bestow = MDNS.txt(i, "bestow").toInt();
    // A peer that predates the explicit TXT still advertises its main port,
    // and this tree's offsets are main +2/+3/+4.
    if (arm <= 0) {
      int main_port = MDNS.port(i);
      if (main_port > 0) { arm = main_port + 2; }
    }
    house_add(host, arm, coms, bestow);
  }
}

static void house_maintain() {
  if (WiFi.status() != WL_CONNECTED || authorization.length() == 0) { return; }
  // Wait while the microphone or speaker owns the heap and the radio.
  if (voiceRecording || isRecording || isPlaying || voiceAwaitingReply) { return; }
  bool down = ((int32_t)(millis() - homebase_down_until) < 0);
  // While the homebase is answering, refresh the list slowly. While it is
  // gone, look every 15 s so the wrist recovers on the next press.
  uint32_t wait = down ? 15000 : 300000;
  if (house_last_scan != 0 && millis() - house_last_scan < wait) { return; }
  house_last_scan = millis();
  house_scan_mdns();
  house_remember_preferred();
  if (house_node_count == 0) { return; }
  	int active = house_active_index();
  	// Prefer the address Now Me named, then the rest in the order learned.
  	int preferred = -1;
  	for (int i = 0; i < house_node_count; i++) {
  		String addr = house_nodes[i].host + ":" + String(house_nodes[i].arm);
  		if (homebase_preferredIP.length() && addr == homebase_preferredIP) { preferred = i; break; }
  	}
  	// Nothing to do while the active machine answers and is the preferred one.
  	bool need_preferred = (!down && preferred >= 0 && preferred != active);
  	if (!down && !need_preferred && active >= 0) { return; }
  	int order[HOUSE_MAX];
  	int n = 0;
  	if (preferred >= 0) { order[n++] = preferred; }
  	for (int i = 0; i < house_node_count; i++) {
  		if (i != preferred) { order[n++] = i; }
  	}
  	int tries = 0;
  	for (int k = 0; k < n && tries < 2; k++) {
  		int i = order[k];
  		if (i == active) { continue; }   // it just failed, or is already in use
  		tries++;
  		if (house_probe(house_nodes[i].host, house_nodes[i].arm)) {
  			house_switch_req = i;
  			return;
  		}
  	}
  }

static void house_task(void *pvParameters) {
  int quiet = 0;
  for (;;) {
    house_maintain();
    bool down = ((int32_t)(millis() - homebase_down_until) < 0);
    bool on_preferred = (homebase_preferredIP.length() == 0 || homebaseIP == homebase_preferredIP);
    if (!down && on_preferred) {
      if (++quiet >= 2) { break; }
    }
    else { quiet = 0; }
    vTaskDelay(pdMS_TO_TICKS(5000));
  }
  house_task_handle = NULL;
  vTaskDelete(NULL);
}

// The president room's button state lives on the homebase and asking for it is a
// one to two second TLS round trip, which used to freeze the screen every time
// the room was opened. It is fetched on core 0 now and applied from loop().
static void president_fetch_task(void *pvParameters) {
  String req = "https://" + homebaseIP + "/watch?room=" + String(president_fetch_room);
  Serial.print("[president] asking ");
  Serial.println(req);
  String watchRequest = https_request(req);
  if (watchRequest != "failure") {
    if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
      president_payload = std::move(watchRequest);   // no second 25 KB copy
      president_data_ready = true;      // loop() picks the answer up
      xSemaphoreGive(taskMutex);
    }
  }
  else if (homebaseIP.length() > 0) {
    // only a real attempt that failed is worth recording: an empty homebase
    // (before the first now_me) would otherwise clobber the boot report and
    // make the next boot restore from the backup config
    writeFile(FFat, "/bootreport.txt", "failure");
  }
  president_fetch_running = false;
  vTaskDelete(NULL);
}

// The watch face reads the hardware RTC chip (watch.rtc); the ESP32Time clock
// (the global `rtc`) is a separate thing. A now_me carries a fresh time and the
// homebase's UTC offset, so write the chip straight from them and the face is
// right the moment Now Me is pressed -- instead of only when a room payload
// happens to come back and apply_president_payload() sets it. That mattered:
// with the BLE bridge up remote_room() asks the phone for the room over BLE and
// the direct fetch (the old path that refreshed the chip) never runs, so the
// face kept an old time while the server's clock was fine. The offset already
// carries DST (it is timegm - timelocal on the homebase: -4 h in summer, -5 h
// in winter here), and the ESP runs in UTC, so system clock + offset is the
// local wall clock.
static void clock_apply_to_face() {
  struct tm local_tm = rtc.getTimeStruct();   // system clock + homebase offset
  if (local_tm.tm_year + 1900 < 2024) {
    return;   // the clock was never set; do not write junk into the chip
  }
  watch.rtc.setDateTime(RTC_DateTime(local_tm));
  Serial.printf("[rtc] face <- %04d-%02d-%02d %02d:%02d:%02d (offset %ld)\n",
                local_tm.tm_year + 1900, local_tm.tm_mon + 1, local_tm.tm_mday,
                local_tm.tm_hour, local_tm.tm_min, local_tm.tm_sec, (long)offset);
}

// Runs on core 1 with whatever the background fetch brought back: remember the
// buttons, sync the clock to the homebase's time and redraw the room if we are
// still standing in it.
void apply_president_payload() {
  crumb("a0 apply");
  if (president_payload.length() == 0) {
    return;
  }
  // hand the buffer over: the copy here was another of the five 25 KB strings
  // the push path held at its peak (see queue_ble_message's note)
  before_me = std::move(president_payload);
  buttoned_before = true;
  crumb("a1 moved");

  // Only six numbers are needed here, and for a 25 KB payload a full parse is
  // a big tree to build just for them -- the last of the memory the push
  // could not spare. Cut the little __specs.time object out first and parse
  // only that; the draw still parses the payload itself, once, in its own
  // room (two trees were never meant to be alive at the same time on
  // 2026-10-09).
  int32_t year = 0;
  int32_t month = 0;
  int32_t day = 0;
  int32_t hour = 0;
  int32_t minute = 0;
  int32_t second = 0;
  {
    String time_str = raw_json_field(raw_json_field(before_me, "__specs"), "time");
    if (time_str.length() > 2) {
      JSONVar result = JSON.parse(time_str);
      year = result["year"];
      month = result["month"];
      day =  result["day"];
      hour =  result["hour"];
      minute = result["min"];
      second = result["sec"];
    }
  }
  crumb("a2 time");

  struct tm set_time = {};
  set_time.tm_year = year - 1900;
  set_time.tm_mon = month - 1;
  set_time.tm_mday = day;
  set_time.tm_hour = hour;
  set_time.tm_min = minute;
  set_time.tm_sec = second;
  // say what the payload wants and where the clock was: a clock that jumps
  // hours in the night is visible here, with the payload to blame or not
  struct tm had_tm = {};
  watch.rtc.getDateTime(&had_tm);
  time_t had = mktime(&had_tm);
  time_t wanted = mktime(&set_time);
  Serial.printf("[rtc] payload %04d-%02d-%02d %02d:%02d:%02d; clock was %04d-%02d-%02d %02d:%02d:%02d (%ld s)\n",
                (int)year, (int)month, (int)day, (int)hour, (int)minute, (int)second,
                had_tm.tm_year + 1900, had_tm.tm_mon + 1, had_tm.tm_mday,
                had_tm.tm_hour, had_tm.tm_min, had_tm.tm_sec,
                (long)(wanted - had));
  // A payload carries the time it was built. Replaying a stale one (a queued
  // push arriving late) used to walk the clock backwards by hours -- the "two
  // hours behind" mornings. Time only moves forward: a payload that is not
  // behind the clock, or a clock that was never set, is what earns a set.
  if (had_tm.tm_year + 1900 < 2024 || wanted + 60 >= had) {
    watch.rtc.setDateTime(RTC_DateTime(set_time));
    // Put the ESP's own clock in step with the chip too. wanted is the payload
    // read through the ESP's UTC frame, so back the homebase offset out to
    // recover the true epoch; the old code wrote wanted straight in and left
    // this clock four hours off after every room draw.
    rtc.setTime((unsigned long)(wanted - offset));
  }
  else {
    Serial.printf("[rtc] stale payload time ignored (%ld s behind)\n", (long)(had - wanted));
  }
  buttonMillis = millis();
  lastMillis = millis();
  crumb("a4 applied");
  Serial.printf("[heap] after push free=%u max=%u\n", (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getMaxAllocHeap());
  Serial.println("[president] payload applied");

  if (jw_room == "room") {
    // drawn in loop(), once this function's locals are gone
    room_redraw = true;
  }
}

// A room button's face: the app's own colour, white label, and - when its toggle
// is on - a thick yellow ring. The ring replaced a full yellow fill, which hid
// which app the button belonged to.
static void button_finish(lv_obj_t *b, JSONVar &result, int sb) {
  lv_obj_set_style_bg_color(b, lv_color_make(result["b" + String(sb)]["rgb"][0],
                                             result["b" + String(sb)]["rgb"][1],
                                             result["b" + String(sb)]["rgb"][2]), LV_PART_MAIN);
  lv_obj_set_style_text_color(b, lv_color_make(255, 255, 255), LV_PART_MAIN);
  int tog = result["b" + String(sb)]["toggle"];
  lv_obj_set_style_border_width(b, tog == 1 ? 5 : 0, LV_PART_MAIN);
  lv_obj_set_style_border_color(b, lv_color_make(255, 255, 0), LV_PART_MAIN);
}

void presidents_buttons() {
  crumb("d0 buttons");
  JSONVar result;
  Serial.println("in the buttons");

  if (!buttoned_before) {
    if (!face_presidente) {
      // centred: this line is the whole screen until the buttons are known
      face_presidente = face_label_maker(0, 80, &lv_font_montserrat_20, lv_color_hex(0xFFFFFF), 240, LV_ALIGN_TOP_MID);
    }
    lv_label_set_text(face_presidente, "Ne pas Presidente");
    return;
  }
  else {
    result = JSON.parse(before_me);
  }
  crumb("d1 parsed");
  Serial.println("after before me parsing");
  Serial.printf("[heap] draw free=%u max=%u\n", (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getMaxAllocHeap());
  if (room > room_count) { room = 1; }  
  int sb = ((room - 1) * 6) + 1;

  // Serial.println(room);
  // Serial.println(sb);
  // the status bar keeps the top rows: the buttons start below it so the
  // battery and ip:port line stay readable in every room
  lv_obj_t * b1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b1, mb1, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b1, 10, 26 );
  lv_obj_set_size(b1, 60, 60 );
  button_finish(b1, result, sb);
  lv_obj_t *l1;
  l1 = lv_label_create(b1);
  lv_label_set_text(l1, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l1);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b1_toggle);
  lv_obj_t * b2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b2, mb2, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b2, 90, 26 );
  lv_obj_set_size(b2, 60, 60 );
  button_finish(b2, result, sb);
  lv_obj_t *l2;
  l2 = lv_label_create(b2);
  lv_label_set_text(l2, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l2);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b2_toggle);
  lv_obj_t * b3 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b3, mb3, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b3, 170, 26 );
  lv_obj_set_size(b3, 60, 60 );
  button_finish(b3, result, sb);
  lv_obj_t *l3;
  l3 = lv_label_create(b3);
  lv_label_set_text(l3, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l3);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b3_toggle);
  lv_obj_t * b4 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b4, mb4, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b4, 10, 106 );
  lv_obj_set_size(b4, 60, 60 );
  button_finish(b4, result, sb);
  lv_obj_t *l4;
  l4 = lv_label_create(b4);
  lv_label_set_text(l4, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l4);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b4_toggle);
  lv_obj_t * b5 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b5, mb5, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b5, 90, 106 );
  lv_obj_set_size(b5, 60, 60 );
  button_finish(b5, result, sb);
  lv_obj_t *l5;
  l5 = lv_label_create(b5);
  lv_label_set_text(l5, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l5);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b5_toggle);
  // Serial.println("b" + String(sb));
  lv_obj_t * b6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b6, mb6, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b6, 170, 106 );
  lv_obj_set_size(b6, 60, 60 );
  // Serial.println(result["b" + String(sb)]["toggle"]);
  button_finish(b6, result, sb);
  
  lv_obj_t *l6;
  l6 = lv_label_create(b6);
  lv_label_set_text(l6, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l6);
  buttonMillis = millis();
  Serial.printf("[room] draw room=%d count=%d\n", room, room_count);
  crumb("d9 drawn");
}

// Is this room's first button in the payload? A string search, not a parse:
// a second full JSON tree for the same payload ran the heap too close to the
// edge (a 25 KB push aborted the watch on 2026-10-09).
static bool room_has_buttons(int r) {
  if (!buttoned_before || before_me.length() < 3) {
    return false;
  }
  String key = "\"b" + String(((r - 1) * room_max) + 1) + "\"";
  return before_me.indexOf(key) > 0;
}

// Swiping across the buttons room walks the rooms: left to the next, right
// back. The rooms all arrive in one payload, so no fetch is needed between
// them; loop() rebuilds the screen after the gesture.
static void screen_gesture(lv_event_t *e) {
  if (jw_room != "room" || room_count < 2) {
    return;
  }
  lv_dir_t dir = lv_indev_get_gesture_dir(lv_indev_active());
  if (dir == LV_DIR_LEFT) {
    room = (room >= room_count) ? 1 : room + 1;
    room_redraw = true;
    Serial.printf("[room] swipe -> %d\n", room);
  }
  else if (dir == LV_DIR_RIGHT) {
    room = (room <= 1) ? room_count : room - 1;
    room_redraw = true;
    Serial.printf("[room] swipe -> %d\n", room);
  }
}

static void touch_button1(lv_event_t *e) {
  if (jw_room == "room") {
    if (room == room_count) {
      room = 1;

    }
    else {
      room++;
    }
  }
  remote_room();
}
void remote_room() {
  uint32_t draw_started = millis();
  crumb("r0 room");
  jw_room = "room";
  display_exit();
  if (bt_enabled && ble_restore_at == 0 && !ble_radio_up) {
    // a wrist glance skipped the radio bring-up; entering a room is when the
    // bridge is actually wanted, so ask for it now and let loop() run it (never
    // block the room draw on the stack coming up)
    ble_restore_at = millis();
  }
  if (!room_has_buttons(room) && !president_fetch_running) {
    // this used to block the screen for the length of the TLS handshake; ask in
    // the background instead and draw the room straight away. The throttle stops
    // a homebase that keeps failing from being asked on every single tap
    static uint32_t last_attempt = 0;
    if (millis() - last_attempt > 20000) {
      last_attempt = millis();
      if (ble_link_ready()) {
        // the bridge is up: the phone fetches the room and pushes it back, so
        // this works away from the home wifi
        JSONVar req = JSON.parse("{}");
        req["type"] = "room_request";
        req["chip_id"] = chip_id_maker();
        req["edt"] = "watch";
        req["room"] = room;
        ble_send(req);
        // arm the timeout: if the phone never pushes the room back, loop()
        // fetches it directly (see ble_room_requested_at)
        ble_room_requested_room = room;
        ble_room_requested_at = millis();
        Serial.println("[ble] room requested");
      }
      else {
        president_fetch_room = room;
        president_fetch_running = true;
        // the handshake needs more stack than loop2's 4 KB
        xTaskCreatePinnedToCore(president_fetch_task, "PresTask", 12288, NULL, 1, NULL, 0);
      }
    }
  }
  presidents_buttons();
  button_writer();
  full_refresh();
  crumb("r9 room done");
  if (millis() - draw_started > 80) {
    Serial.printf("[draw] room %u ms\n", millis() - draw_started);
  }
}

unsigned long getTime() {
  time_t now;
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo)) {
    //Serial.println("Failed to obtain time");
    return (0);
  }
  time(&now);
  return now;
}
static void audio_button(lv_event_t * e) {
    lv_event_code_t code = lv_event_get_code(e);
    lv_obj_t * btn = lv_event_get_target_obj(e);
    lv_obj_t * btn_label = lv_obj_get_child(btn, 0);

    if (btn == recbtn1) {
        if (code == LV_EVENT_PRESSED) {
            if (isPlaying) return; // Prevent conflicts during execution
            
            isRecording = true;
            lv_label_set_text(btn_label, "Recording...");
            String filename = String(timestamp_maker()) + ".wav";
            saveFileToFolder("/recordings", filename.c_str());
            
            WAV_FILE_PATH = "/recordings/" + filename;
            xTaskCreatePinnedToCore(micCaptureTask, "MicTask", 4096, NULL, 2, NULL, 1);

        } else if (code == LV_EVENT_RELEASED) {
            if (isRecording) {
                isRecording = false; 
                lv_label_set_text(btn_label, "Rec");
            }
        }
    }
    else if (btn == playbtn1) {
        if (code == LV_EVENT_CLICKED) {
            if (isRecording) return; 

            if (!isPlaying) {
                if (!FFat.exists(WAV_FILE_PATH.c_str())) {
                    lv_label_set_text(btn_label, "No File Found");
                    return;
                }

                isPlaying = true;
                lv_label_set_text(btn_label, "Playing...");

                // Initialize template playback structure elements dynamically
                out_hardware = new LilyGoAudioSink(watch.getAudioOutput());
                file_source = new AudioFileSourceFATFS(WAV_FILE_PATH.c_str());
                wav = new AudioGeneratorWAV();
                wav->begin(file_source, out_hardware);

                xTaskCreatePinnedToCore(audio_playback_loop_task, "PlayTask", 4096, NULL, 2, NULL, 1);
            } else {
                // Tapping while playing forces an emergency stop sequence
                isPlaying = false; 
            }
        }
    }
}


// Generates the proper 44-byte RIFF layout header directly into local flash storage
bool create_wav_header_on_flash(const char *song_name, const uint32_t sampling_rate, uint16_t bits_per_sample) {
    // Open file to write structural container. Size will be updated upon release.
    File new_audio_file = FFat.open(song_name, FILE_WRITE);
    if (!new_audio_file) {
        Serial.println("[WAV] Failed to create storage file partition!");
        return false;
    }

    uint8_t header[44] = {
        'R', 'I', 'F', 'F',
        0, 0, 0, 0,       // ChunkSize placeholder (updated later)
        'W', 'A', 'V', 'E',
        'f', 'm', 't', ' ',
        16, 0, 0, 0,      // Subchunk1Size
        1, 0,             // AudioFormat PCM
        1, 0,             // Mono channel (1)
        (uint8_t)(sampling_rate & 0xff), (uint8_t)((sampling_rate >> 8) & 0xff), 0, 0,
        0, 0, 0, 0,       // ByteRate placeholder (updated later)
        (uint8_t)((1 * bits_per_sample) / 8), 0, // BlockAlign
        (uint8_t)bits_per_sample, 0,             // BitsPerSample
        'd', 'a', 't', 'a',
        0, 0, 0, 0        // Subchunk2Size placeholder (updated later)
    };

    new_audio_file.write(header, 44);
    new_audio_file.close();
    return true;
}

// Rewrites header placeholders with the exact byte sizes after recording stops
void finalize_wav_sizes(const char *song_name, uint32_t raw_pcm_bytes, uint32_t sample_rate) {
    File audio_file = FFat.open(song_name, "r+");
    if (!audio_file) return;

    uint32_t chunk_size = raw_pcm_bytes + 36;
    uint32_t byte_rate = sample_rate * 1 * (MIC_I2S_BITS_PER_SAMPLE / 8);

    // Update ChunkSize field (offset index 4)
    audio_file.seek(4);
    audio_file.write((uint8_t*)&chunk_size, 4);

    // Update ByteRate field (offset index 28)
    audio_file.seek(28);
    audio_file.write((uint8_t*)&byte_rate, 4);

    // Update Subchunk2Size field (offset index 40)
    audio_file.seek(40);
    audio_file.write((uint8_t*)&raw_pcm_bytes, 4);

    audio_file.close();
    Serial.printf("[WAV] Header successfully updated. File size: %lu bytes.\n", raw_pcm_bytes + 44);
}

// FreeRTOS background task handling the microphone pipeline data stream
void micCaptureTask(void *pvParameters) {
    AudioInputIf *mic = watch.getAudioInput();
    if (!mic || !mic->open(MIC_I2S_BITS_PER_SAMPLE, 1, MIC_I2S_SAMPLE_RATE)) {
        Serial.println("[Recorder] microphone open failed");
        isRecording = false;
        vTaskDelete(NULL);
    }

    if (!create_wav_header_on_flash(WAV_FILE_PATH.c_str(), MIC_I2S_SAMPLE_RATE, MIC_I2S_BITS_PER_SAMPLE)) {
        isRecording = false;
        vTaskDelete(NULL);
    }

    File audio_file = FFat.open(WAV_FILE_PATH.c_str(), FILE_APPEND);
    if (!audio_file) {
        isRecording = false;
        vTaskDelete(NULL);
    }

    uint8_t *tempBuf = (uint8_t *)malloc(AUDIO_BUFFER_CHUNK_SIZE);
    uint32_t bytes_written_total = 0;

    Serial.println("[Recorder] Flash append loop initialized.");
    uint32_t started_ms = millis();

    while (isRecording) {
        int got = mic->read(tempBuf, AUDIO_BUFFER_CHUNK_SIZE);
        if (got > 0) {
            audio_file.write(tempBuf, got);
            bytes_written_total += got;
        }
        else {
            // the read blocks until the buffer is full, so this only runs when it
            // came back with nothing; a short yield keeps the loop from spinning
            vTaskDelay(pdMS_TO_TICKS(1));
        }
    }

    mic->close();
    audio_file.close();
    free(tempBuf);
    uint32_t spent = millis() - started_ms;
    // the bytes-per-second figure says whether the microphone really produced the
    // 16 kHz the WAV header claims (16 kHz mono 16-bit is ~32000 B/s)
    Serial.printf("[Recorder] captured %u bytes in %u ms (%u B/s, expect ~32000)\n",
                  bytes_written_total, spent,
                  spent ? (unsigned)((uint64_t)bytes_written_total * 1000 / spent) : 0);

    // Patch structural sizing tags so whisper.cpp can process it cleanly
    finalize_wav_sizes(WAV_FILE_PATH.c_str(), bytes_written_total, MIC_I2S_SAMPLE_RATE);
    vTaskDelete(NULL);
}

