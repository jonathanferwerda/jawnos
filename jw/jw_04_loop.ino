void chat_grabber(String s, String uuid) {
  Serial.println(s);
  if (authorization) {
    String request = "https://" + homebaseIP + "/watch/chat_grabber?s=" + s + "&uuid=" + uuid;
    Serial.println(request);
    String response = https_request(request);
    Serial.println(response);
    JSONVar mail = JSON.parse(response);
    buttonMillis = millis();
    String manager_file = mail["manager_file"];
    String body = mail["body"]; 
    long timestamp = mail["timestamp"];
    loraChatBroadcast(manager_file, body, timestamp);    
  }
}

void loraChatBroadcast(String computer_name, String body, long timestamp) {
  if (loraChatBroadcaster) {
    
    JSONVar msg;
    msg["u"] = computer_name;
    msg["m"] = body;
    
    String returns = JSON.stringify(msg);
    Serial.println(returns);
    radio.startTransmit(returns);
    Serial.println("transmitted");
   // delay(2000);
  //   radio.startReceive();
    Serial.println("back to listening");
  }
}

// A sample is what the server collects as a step measure, so they are kept rare on
// purpose: only while the clock room is the room on screen, only when the counter
// has actually moved, and at most one a minute. A sample a minute regardless (or
// one per step) would leave thousands of measures for /inventory to wade through.
//
// The pedometer counts cumulatively, so one sample per visit still carries every
// step taken since the last collection, and taking it from a timer rather than the
// BMA interrupt is what keeps the count alive: the wake cycle re-arms the sensor
// for tilt alone, which quietly dropped the pedometer's interrupt after a few days.
void step_writer() {
  if (sportsIrq) {
    watch.loopSensor();       // the library reads and clears the latched interrupt
    sportsIrq = false;
  }
  if (stepCounter != true || jw_room != "watch") {
    return;
  }
  uint32_t counter = watch.getStepCounter();
  if (counter == steps) {
    return;                   // no steps since the last sample, nothing to add
  }
  if (millis() - stepSampleMillis < 60000) {
    return;
  }
  stepSampleMillis = millis();
  steps = counter;
  if (!JSON.stringify(stepped).startsWith("[")) {
    stepped = JSON.parse("[]");         // a damaged config must not stop the count
  }
  // bounded: this lives in RAM and in the saved config
  while (stepped.length() > 240) {
    JSONVar trimmed = JSON.parse("[]");
    for (int n = 1; n < stepped.length(); n++) {
      trimmed[trimmed.length()] = stepped[n];
    }
    stepped = trimmed;
  }
  JSONVar last_step;
  last_step["timestamp"] = timestamp_maker();
  last_step["steps"] = steps;
  stepped[stepped.length()] = last_step;
  Serial.print("steps ");
  Serial.print((int)steps);
  Serial.print(" across ");
  Serial.print((int)stepped.length());
  Serial.println(" samples");
  ble_push_steps(true);   // hand the new count to a connected bridge, if any
}

#include "esp_mac.h" // Handles direct low-level chip hardware queries

JSONVar printAllMacAddresses() {
  uint8_t mac[6];
  char buf[18]; // Safe buffer to temporarily hold formatted string data ("XX:XX:XX:XX:XX:XX")
  JSONVar addresses;
  
  Serial.println("\n===== ESP32 HARDWARE MAC ADDRESSES =====");

  // 1. Get Base System MAC (Queries factory-programmed eFuse layout directly)
  if (esp_efuse_mac_get_default(mac) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["base"] = String(buf);
    Serial.printf("Base System MAC:  %s\n", buf);
  }

  // 2. Get Wi-Fi Station (STA) MAC -> Cast integer (esp_mac_type_t)0
  if (esp_read_mac(mac, (esp_mac_type_t)0) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["wifi_sta"] = String(buf);
    Serial.printf("Wi-Fi Station:    %s\n", buf);
  }

  // 3. Get Wi-Fi Soft Access Point (AP) MAC -> Cast integer (esp_mac_type_t)1
  if (esp_read_mac(mac, (esp_mac_type_t)1) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["wifi_ap"] = String(buf);
    Serial.printf("Wi-Fi Access Pt:  %s\n", buf);
  }

  // 4. Get Bluetooth (Classic & BLE) MAC -> Cast integer (esp_mac_type_t)2
  if (esp_read_mac(mac, (esp_mac_type_t)2) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["bluetooth"] = String(buf);
    Serial.printf("Bluetooth Mac:    %s\n", buf); // <-- Use this exact value for your Tasker Profiles!
  }

  // 5. Get Ethernet MAC -> Cast integer (esp_mac_type_t)3
  if (esp_read_mac(mac, (esp_mac_type_t)3) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["ethernet"] = String(buf);
    Serial.printf("Ethernet Mac:     %s\n", buf);
  }
  
  Serial.println("========================================\n");
  
  return addresses;
}


void jawn_loop() {
  static uint32_t loopStarted = millis();
  char count = 0;
  watch.loop();   // pumps the PMU and motion sensor events into the callbacks
  tilt_serial_poll();   // "tilt ..." commands from the USB console

  // BLE was asked for by the saved config: bring it up here, well away from
  // setup(), where initialising the stack used to panic the watch
  if (btStartPending && millis() > 2000) {
    btStartPending = false;
    start_ble_transfer();
    full_refresh();
  }
  // the radio, restored off the sleep-wake path (see ble_restore_at). The task
  // runs the bring-up on core 0, so the clock keeps running while it comes up;
  // the repaint it owes is done here, on the ui core.
  if (ble_restore_at != 0 && (int32_t)(millis() - ble_restore_at) >= 0) {
    ble_restore_at = 0;
    if (bt_enabled && !dozing) {
      ble_start_async();
    }
  }
  	if (ble_refresh_pending) {
  		ble_refresh_pending = false;
  		full_refresh();
  	}

  	// The House task found a live machine: land on it. A pending switch is
  	// applied here (UI core) under the same mutex the BLE now_me uses.
  	{
  		int next = house_switch_req;
  		if (next >= 0 && next < house_node_count) {
  			house_switch_req = -1;
  			if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
  				homebase = house_nodes[next].host;
  				homebaseIP = house_nodes[next].host + ":" + String(house_nodes[next].arm);
  				xSemaphoreGive(taskMutex);
  			}
			homebase_down_until = 0;
			Serial.printf("[house] now using %s:%d\n", house_nodes[next].host.c_str(), house_nodes[next].arm);
		}
	}

	// The failover worker exists only while it has work; its stack belongs to the
	// UI and the listener when the preferred House machine is answering.
	{
		bool down = ((int32_t)(millis() - homebase_down_until) < 0);
		bool on_preferred = (homebase_preferredIP.length() == 0 || homebaseIP == homebase_preferredIP);
		if ((down || !on_preferred) && house_task_handle == NULL) {
			if (xTaskCreatePinnedToCore(house_task, "HouseTask", 8192, NULL, 1, &house_task_handle, 0) != pdPASS) {
				house_task_handle = NULL;
			}
		}
	}

  if (jw_room == "watch") {
    time_writer("loop");
    if (notification_viewing == 0) {
      step_writer();
    }
  }
  else if (jw_room == "net") {
    ip_writer();
  }
  else if (jw_room == "message") {
    if (buttonMillis != 0  && millis() - buttonMillis > DEFAULT_SCREEN_TIMEOUT && count < 350) {
      lowPowerEnergyHandler();
      count = 0;
      jw_room = "watch";
    }
    else {
      count++;
    }
    delay(60);
  }
  // The IP row lives on the face, and the face is the floor every room is drawn
  // over, so keep it fresh wherever we are: that way turning the AP on shows its
  // address on the screen right away instead of only while standing in net room.
  ip_writer();
  int volts = watch.getBatteryPercent();
  // the status strip belongs to the watch face; the Set room owns that space
  // for its tab row, so leave the labels empty while we are in there. Off the
  // clock room the face (and its clock) is not on screen, so its corner shows
  // the time instead - the battery reading only means something beside the clock.
  if (face_battery && jw_room != "configure") {
    lv_color_t status_colour;
    if (volts < 20) {
      status_colour = lv_color_hex(0xFF0000);
    }
    else if (volts < 40) {
      status_colour = lv_color_hex(0xFFFF00);
    }
    else {
      status_colour = lv_color_hex(0x00FF00);
    }
    lv_obj_set_style_text_color(face_battery, status_colour, LV_PART_MAIN);
    lv_obj_set_style_text_color(face_percent, status_colour, LV_PART_MAIN);
    if (jw_room == "watch") {
      lv_label_set_text_fmt(face_battery, "%d", volts);
      lv_label_set_text(face_percent, "%");
    }
    else {
      lv_label_set_text(face_battery, rtc.getTime("%H:%M").c_str());
      lv_label_set_text(face_percent, "");
    }
    // the machine serving the watch, by name; the address is the fallback until
    // a Now Me has ever named it
    if (computer_name != "") {
      lv_label_set_text(face_name, computer_name.c_str());
    }
    else {
      lv_label_set_text(face_name, homebaseIP.c_str());
    }
  }
  touch_watch();
  if (buttonMillis == 0 && sportsIrq == 0) {
    setSportsFlag();
    settingPMU();
    pmuIrq = false;
    buttonMillis = millis();
  }


  // the crown is the screen button now: while the watch is awake a click puts it
  // to sleep, and a click that ends a doze just lights the screen back up
  if (pmuIrq) {
    pmuIrq = false;
    if (sleepRequested) {
      sleepRequested = false;
      lowPowerEnergyHandler();
      return;
    }
    wakeup();
  }
  else {
    lv_task_handler();
    if (webserver_enabled == true) {
      server.handleClient();
    }
    if (tiltDbg) {
      tilt_dbg_stream();
    }
    delay(5);
  }
  if (president_data_ready) {
    // the fetch ran on core 0; the JSON and the screen belong to this core
    president_data_ready = false;
    ble_room_requested_at = 0;   // whatever asked for the room, it arrived
    crumb("c0 apply loop");
    apply_president_payload();
  }
  if (ble_now_me_ready) {
    // the bridge pushed new params: land on the buttons room; remote_room()
    // asks for the buttons over BLE (see below)
    ble_now_me_ready = false;
    clock_apply_to_face();   // the pushed params set rtc/offset; sync the chip
    room = 1;
    remote_room();
  }
  if (ble_toggle_refresh) {
    ble_toggle_refresh = false;
    if (jw_room == "room") {
      presidents_buttons();
      full_refresh();
    }
  }
  if (room_redraw) {
    // a page button or the scroller asked for a rebuild: it has to happen here,
    // outside the event that asked (the pages die with the rebuild)
    room_redraw = false;
    if (jw_room == "room") {
      crumb("c1 redraw");
      remote_room();
    }
  }
  // the phone may not answer a room_request (a sleeping bridge, an app that
  // does not forward it): fetch the room directly instead of leaving the room
  // blank. Resets on the payload's own arrival above.
  if (ble_room_requested_at != 0 && !president_fetch_running
      && homebaseIP.length() > 0
      && !room_has_buttons(ble_room_requested_room)
      && !voiceRecording
      && (int32_t)(millis() - homebase_down_until) >= 0
      && millis() - ble_room_requested_at > 2500) {
    ble_room_requested_at = 0;
    president_fetch_room = ble_room_requested_room;
    president_fetch_running = true;
    Serial.println("[ble] room_request unanswered; fetching over http");
    xTaskCreatePinnedToCore(president_fetch_task, "PresTask", 12288, NULL, 1, NULL, 0);
  }
  // taps queued while the link was down go out shortly after a fresh central
  // arrives: notify() before its CCCD subscription lands is dropped, so wait
  // for the subscription flag too, not just the connection
  static bool ble_link_was_up = false;
  static uint32_t ble_link_up_at = 0;
  if (ble_link_ready() && !ble_link_was_up) {
    ble_link_was_up = true;
    ble_link_up_at = millis();
  }
  else if (!ble_link_ready()) {
    ble_link_was_up = false;
  }
  if (ble_link_ready() && ble_link_up_at != 0 && millis() - ble_link_up_at > 2500) {
    ble_link_up_at = 0;
    ble_flush_wigi();
    ble_push_steps(false);   // recover the steps taken while the link was down
  }
  // the panel handed us network credentials over BLE: join now (this is the
  // same blocking join the watch's Net-room WiFi button runs)
  if (wifi_join_requested) {
    wifi_join_requested = false;
    Serial.println("[wifi] joining from BLE credentials");
    wifi_server();
  }
  // a watch armed for hands-free voice keeps a listener running while it is
  // awake: the task captures one utterance, ships it, and stays listening. It
  // steps aside (and is not restarted) while a manual record or playback holds
  // the microphone, and only listens while the screen is on (dozing = off).
  if (voiceCaptureEnabled && !voiceListening && !isRecording && !isPlaying && !dozing
      && !voiceAwaitingReply) {
    // start the listener the moment the screen is up: a command spoken in the
    // first seconds of a wake must be heard, so this no longer waits for the
    // radio (a wrist glance skipped the bring-up entirely and voice detection
    // waited on a link that was never coming). The clip waits on disk and ships
    // as soon as there is a radio.
    voiceListenStart(false);
  }
  // a clip being heard or waiting to go needs the bridge: bring the radio up on
  // demand (a glance did not), so the payload has somewhere to go
  if ((voiceRecording || voiceShipping) && bt_enabled && !ble_radio_up && ble_restore_at == 0) {
    ble_restore_at = millis();
  }
  // the server said the clip was transcribed and filed: drop the watch's local
  // copy. Only when it is still that clip (a new capture would have changed the
  // timestamp) and nothing is recording.
  if (voice_done_ts >= 0 && !voiceRecording) {
    long done_ts = voice_done_ts;
    voice_done_ts = -1;
    if (done_ts != 0 && done_ts == voice_clip_ts && FFat.exists(VOICE_WAV_PATH.c_str())) {
      FFat.remove(VOICE_WAV_PATH.c_str());
      FFat.remove(VOICE_ADPCM_PATH.c_str());
      Serial.println("[voice] local clip deleted (transcribed)");
    }
  }
  if (loraChatReceiver) {
    readRadio();
  }
  wrist_look_monitor();   // hold a glance while the arm is up, drop it when it falls
  // a spoken command keeps the watch awake until it is captured: without this the
  // screen timeout could doze us mid-sentence and the clip would be lost
  if (voiceRecording || voiceShipping
      || (voiceWakeHoldUntil && (int32_t)(millis() - voiceWakeHoldUntil) < 0)) {
    buttonMillis = millis();
  }
  // A spoken request is answered in a few seconds, not instantly: hold the screen
  // on through the wait and the answer, then let the idle timer start again. While
  // the answer is actually being spoken (isPlaying) the hold simply continues; the
  // timeout is for a reply that never comes.
  if (voiceAwaitingReply) {
    buttonMillis = millis();
    if (!isPlaying && millis() - voiceAwaitingSince > 30000) {
      voiceAwaitingReply = false;
      buttonMillis = millis();
    }
  }
  // the orange ring: shown for exactly as long as a command is being heard
  {
    static bool voice_border_on = false;
    if (voiceRecording != voice_border_on) {
      voice_border_on = voiceRecording;
      voice_border_show(voice_border_on);
    }
  }
  // a guide associate reply: draw the words, then hear them - the parts arrive
  // into the stream buffer, and the playback task drains them as they come.
  if (say_text_pending) {
    String t;
    bool has = false;
    if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
      if (say_text_pending) { has = true; t = say_text; say_text_pending = false; }
      xSemaphoreGive(taskMutex);
    }
    if (has) {
      say_label_show(t);
      say_shown_at = millis();
    }
  }
  if (say_label && say_shown_at && millis() - say_shown_at > SAY_TEXT_MS) {
    say_label_show("");
    say_shown_at = 0;
  }
  if (say_stream_start) {
    say_stream_start = false;
    say_stream_play();
  }
  if (say_fetch_pending && !say_fetch_running) {
    say_fetch_pending = false;
    String* req = say_fetch_req;
    say_fetch_req = nullptr;
    if (req) {
      say_fetch_running = true;
      if (xTaskCreatePinnedToCore(say_fetch_task, "SayFetch", 12288, req, 1, NULL, 0) != pdPASS) {
        delete req;
        say_fetch_running = false;
        Serial.println("[say] WiFi fetch task could not start");
      }
    }
  }
  if (say_wifi_ready && !isPlaying && !isRecording) {
    say_wifi_ready = false;
    say_wifi_play("/reply.wav");
  }
  if (buttonMillis != 0 && millis() - buttonMillis > DEFAULT_SCREEN_TIMEOUT) {
    if (voiceShipping) {
      // A payload is still going out, so the radio (and the chip) must stay up.
      // Dark the panel as the timeout wanted, but do NOT enter the sleep path -
      // its blocking wait here is what left the screen frozen when the watch was
      // woken mid-send. Hold the deadline so the sleep keeps being deferred, and
      // a touch (touch_watch rebases buttonMillis) brings the screen straight
      // back while the send carries on.
      if (!ship_dim) {
        ship_dim = true;
        brightnessLevel = watch.getBrightness();
        watch.setBrightness(0);
        watch.sleepDisplay();
        Serial.println("[voice] screen off, staying awake for the send");
      }
      buttonMillis = millis();
    }
    else {
      lowPowerEnergyHandler();
    }
  }
  else if (ship_dim) {
    // the send finished, or the screen was woken: put the panel back
    ship_dim = false;
    if (brightnessLevel <= 1) { brightnessLevel = 20; }
    watch.wakeupDisplay();
    watch.setBrightness(brightnessLevel);
    buttonMillis = millis();
    Serial.println("[voice] screen back after the send");
  }
  awake_notifications();

  // anything that blocks long enough to be felt gets a line in the log
  uint32_t spent = millis() - loopStarted;
  if (spent > 300) {
    Serial.printf("[slow] loop %u ms (%s)\n", spent, jw_room.c_str());
  }
  loopStarted = millis();
}

