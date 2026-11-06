void jawn_loop() {
  // The UI has been answering keystrokes and roller clicks late, so the loop
  // times itself and names the slow section instead of us guessing.
  uint32_t loopStart = millis();
  // a press's relay outcome paints its button for two seconds
  button_feedback_tick();
  static uint32_t lastKbProbe = 0;
  char keyValue = 0;
  // Only poll a live socket: a stopped TLS client can block in its read path
  // and stall the whole UI.
  if (ws_connected == 1) { wsclient.poll(); }

  // The House task found a live machine: move every address the deck dials onto
  // it (HTTP, teletype, wss) and reopen the control socket. The preferred
  // machine reclaims all of them the same way when it answers again.
  {
    int next = house_switch_req;
    if (next >= 0 && next < house_node_count) {
      house_switch_req = -1;
      String host = house_nodes[next].host;
      int arm = house_nodes[next].arm;
      int bestow = house_nodes[next].bestow > 0 ? house_nodes[next].bestow : arm + 1;
      int coms = house_nodes[next].coms > 0 ? house_nodes[next].coms : arm + 2;
      homebase = host;
      homebaseIP = host + ":" + String(arm);
      thomebaseIP = host + ":" + String(bestow);
      twshomebaseIP = host + ":" + String(coms);
      homebase_down_until = 0;
      buttoned_before = false;   // re-fetch the room from the machine now serving
      deckLog("[house] now using %s:%d", host.c_str(), arm);
      if (tauth_remote_enabled == "on" && authorization != "") {
        wsclient.close();
        ws_connected = 0;
        tauth_connect();
      }
    }
  }

  // The failover worker exists only while it has work. A deck whose preferred
  // House machine is answering keeps its 8 KB stack for the UI and the voice.
  {
    bool down = ((int32_t)(millis() - homebase_down_until) < 0);
    bool on_preferred = (homebase_preferredIP.length() == 0 || homebaseIP == homebase_preferredIP);
    if ((down || !on_preferred) && house_task_handle == NULL) {
      if (xTaskCreatePinnedToCore(house_task, "HouseTask", 8192, NULL, 1, &house_task_handle, 0) != pdPASS) {
        house_task_handle = NULL;
      }
    }
  }

  // The wss control socket follows Now Me, but a handshake can fail while the
  // radio or a TLS buffer is still coming up. Retry it while remote input is on
  // and a Now Me pair is held, instead of waiting for the next key press.
  {
    static uint32_t ws_retry_at = 0;
    if (tauth_remote_enabled == "on" && ws_connected == 0 && authorization != ""
        && twshomebaseIP.length() && WiFi.status() == WL_CONNECTED
        && (tauth_connect_pending || millis() - ws_retry_at > 30000)) {
      // One dial per half minute, not every ten seconds: each failed dial still
      // blocks for up to the 2 s connect timeout, and that is a visible stutter.
      tauth_connect_pending = false;
      ws_retry_at = millis();
      tauth_connect();
    }
  }

  // Bluetooth asked for by the saved config comes up here, well away from
  // setup(), where initialising the stack used to panic the board
  if (btStartPending && millis() > 2000) {
    btStartPending = false;
    start_ble_transfer();
  }
  // Sleep mode restores the station link without the blocking wifi_server()
  // join: the server and mDNS come up here once association completes.
  if (wifi_restore_pending && WiFi.status() == WL_CONNECTED) {
    wifi_restore_pending = false;
    if (!wifi_ap_enabled) {
      server.begin();
      webserver_enabled = true;
    }
    jawnos_mdns_start();
  }

  // messages written to the NUS RX characteristic are queued by the stack's
  // task; the JSON is handled here, on the same thread as everything else
  String* incomingMsgPtr = nullptr;
  if (bleIncomingQueue != NULL && xQueueReceive(bleIncomingQueue, &incomingMsgPtr, 0) == pdTRUE) {
    if (incomingMsgPtr != nullptr) {
      String btmsg;
      btmsg = std::move(*incomingMsgPtr);   // steal the buffer: the push can be 25 KB
      delete incomingMsgPtr;
      btmsg = ble_inflate_if_zlib(btmsg);   // the bridge deflates a large push
      // a length, not the map: the message can be 25 KB of JSON
      deckLog("[bt] rx %u bytes", (unsigned)btmsg.length());
      JSONVar btMsg = JSON.parse(btmsg);
      if (JSON.typeof(btMsg) != "undefined") {
        String mtype = btMsg.hasOwnProperty("type") ? String((const char *)btMsg["type"]) : String("");
        // A relay envelope from the house: unwrap it when it names this deck.
        // The manager has already routed it, so a copy naming another chip is
        // stale and must not be applied here.
        if (mtype == "relay") {
          String relay_to = btMsg.hasOwnProperty("to") ? String((const char *)btMsg["to"]) : String("");
          if (relay_to == "" || relay_to == chip_id_maker()) {
            JSONVar relay_inner = btMsg["message"];
            if (JSON.typeof(relay_inner) == "object") {
              btMsg = relay_inner;
              mtype = btMsg.hasOwnProperty("type") ? String((const char *)btMsg["type"]) : String("");
            }
            else { btMsg = JSON.parse("{}"); mtype = ""; }
          }
          else { btMsg = JSON.parse("{}"); mtype = ""; }
        }
        if (mtype == "button") {
          if (before_me == "") {
            before_me = "{}";
          }
          JSONVar bm = JSON.parse(before_me);
          if (btMsg.hasOwnProperty("data") && btMsg["data"].hasOwnProperty("button")) {
            int button = 0;
            if (JSON.typeof(btMsg["data"]["button"]) == "string") {
              button = String((const char *)btMsg["data"]["button"]).toInt();
            }
            else {
              button = (int)btMsg["data"]["button"];
            }
            String buttonKey = "b" + String(button);
            bm[buttonKey] = btMsg["data"];
            before_me = JSON.stringify(bm);
            // The press's outcome: a named command that did not land, or an
            // every-machine command that missed a machine, flashes red; an
            // every-machine command that reached all of them flashes green.
            button_face_key = button;
            button_face_dirty = true;
            button_flash_from_result(button, btMsg["data"]);
          }
        }
        else if (mtype == "hello") {
          // the bridge names itself (this machine's name): what the net room's
          // BT line shows in place of the address, which rotates underneath it
          const char *who = (const char *)btMsg["name"];
          if (who != nullptr) {
            snprintf(ble_peer_name, sizeof(ble_peer_name), "%s", who);
          }
          deckLog("[bt] hello: %s", ble_peer_name);
        }
        else if (mtype == "battery") {
          // The house asked for the pack over the link it is already holding.
          // The same reading /device_query answers with, so a deck whose WiFi
          // is asleep still appears in the levels view.
          int bp = deck_battery_percent();
          int bmv = (int)deck_battery_voltage();
          JSONVar reply;
          reply["type"] = "battery";
          reply["chip_id"] = chip_id_maker();
          reply["edt"] = "teletype";
          reply["battery"] = bp;
          reply["battery_mv"] = bmv;
          reply["battery_status"] = (bmv > 4300) ? (bp >= 100 ? "full" : "charging") : "discharging";
          ble_send(reply);
          deckLog("[bt] battery %d%% (%d mV)", bp, bmv);
        }
        else if (mtype == "now_me") {
          // the phone pushes the whole picture over BLE: the homebase, the
          // authorization (freshly rotated), the clock offset and the room
          // shape. No network needed on this side.
          JSONVar params = btMsg["data"];
          homebaseIP = (const char *)params["homebase"];
          homebase = (const char *)params["ip"];
          authorization = (const char *)params["authorization"];
          twshomebaseIP = (const char *)params["twshomebase"];
          thomebaseIP = (const char *)params["thomebase"];
          homebase_preferredIP = homebaseIP;
          thomebase_preferredIP = thomebaseIP;
          twshomebase_preferredIP = twshomebaseIP;
          if (params.hasOwnProperty("houses")) {
            house_learn_json(String((const char *)params["houses"]));
          }
          house_remember_preferred();
          house_last_scan = 0;
          offset = params["offset"];
          rtc.offset = offset;
          long timestamp = params["timestamp"];
          rtc.setTime(timestamp + offset);
          room_count = params["room_count"] || room_count;
          room_max = params["room_max"] || room_max;
          if (params.hasOwnProperty("voice_trigger")) {
            const char *vt = (const char *)params["voice_trigger"];
            if (vt) { voice_trigger = vt; }
          }
          if (params.hasOwnProperty("voice_floor")) {
            const char *vf = (const char *)params["voice_floor"];
            if (vf) { voice_floor = vf; }
          }
          voice_trigger_apply();
          buttoned_before = false;   // ask the bridge for fresh buttons
          deckLog("[bt] now_me applied");
          remote_room();
          // Now Me is the whole authorization: remote input follows it with no
          // password step, and it may name a different House machine.
          tauth_remote_enabled = "on";
          wsclient.close();
          ws_connected = 0;
          tauth_connect();
        }
        else if (mtype == "room") {
          // a room payload pushed by the bridge: the same picture the http
          // fetch returns. It is carved out of the raw message in place --
          // parsing the envelope only to stringify the payload held three
          // 25 KB strings at once (the watch's heap crash, 2026-10-09)
          int payload_at = 0, payload_len = 0;
          if (raw_json_field_span(btmsg, "payload", payload_at, payload_len) && payload_len > 2) {
            btmsg.remove(0, payload_at);
            btmsg.remove(payload_len);
            before_me = std::move(btmsg);
            buttoned_before = true;
            String specs_str = raw_json_field(before_me, "__specs");
            if (specs_str.length() > 2) {
              JSONVar specs = JSON.parse(specs_str);
              int32_t year = specs["time"]["year"];
              if (year > 2020) {
                rtc.setTime(specs["time"]["sec"], specs["time"]["min"], specs["time"]["hour"],
                            specs["time"]["day"], specs["time"]["month"], year);
              }
            }
            if (jw_room == "room") {
              presidents_buttons();
              remote_writer();
              presidents_title();
            }
            deckLog("[bt] room pushed");
          }
        }
        else if (mtype == "say") {
          // The Guide's answer to a spoken request: the words, drawn on the top
          // layer for a while. (The sound half arrives as say_audio parts, which
          // the deck does not play yet.)
          const char *words = (const char *)btMsg["data"]["text"];
          deckLog("[voice] guide says: %s", words ? words : "");
          if (words) { say_label_show(String(words)); }
          // the hold ends when the spoken answer has played (or in loop()'s
          // timeout), not here: the words arrive before the sound
        }
        else if (mtype == "say_audio") {
          // the Guide's spoken answer in PCM parts; the last one plays it
          say_audio_add(btMsg["data"]);
        }
        else if (mtype == "say_audio_ready") {
          // the answer is on the server: pull the one WAV over WiFi. The server
          // only sends this after the deck's web server answered, but WiFi can
          // have dropped since, so check again before starting a fetch.
          String id = (const char *)btMsg["data"]["id"];
          String base = (const char *)btMsg["data"]["base"];
          if (id.length() && base.length() && WiFi.status() == WL_CONNECTED) {
            if (sayFetchReq) { delete sayFetchReq; }
            sayFetchReq = new String(base + "/watch/reply_audio?id=" + id);
            if (sayFetchReq) { sayFetchPending = true; }
            deckLog("%s", "[voice] WiFi audio ready; fetching");
          }
          else {
            deckLog("%s", "[voice] WiFi audio ready but no WiFi; waiting for BLE parts");
          }
        }
        else if (mtype == "toggle" || mtype == "toggles") {
          // a toggle flipped somewhere else (a phone press, an alarm, an
          // appointment): light up every button that has that app
          JSONVar updates = JSON.parse("{}");
          if (mtype == "toggles") {
            updates = btMsg["data"];
          }
          else {
            updates[(const char *)btMsg["data"]["app"]] = btMsg["data"]["state"];
          }
          JSONVar bm = JSON.parse(before_me);
          JSONVar keys = bm.keys();
          String changed;
          for (int i = 0; i < keys.length(); i++) {
            String k = keys[i];
            String app = (const char *)bm[k]["app"];
            if (app.length() > 0 && updates.hasOwnProperty(app.c_str())) {
              String state = (const char *)updates[app.c_str()];
              int tog = (state == "on") ? 1 : 0;
              if (tog != (int)bm[k]["toggle"]) {
                bm[k]["toggle"] = tog;
                changed += k.substring(1) + ",";
              }
            }
          }
          before_me = JSON.stringify(bm);
          // A toggle changes one face, not the room: rebuilding every widget on
          // a push from the panel or a watch press is what made a busy room
          // crawl. The button under a live flash is left alone - the tick puts
          // its face back when the flash ends.
          if (jw_room == "room" && changed.length()) {
            bool flashing = (button_flash_until != 0
                             && (int32_t)(millis() - button_flash_until) < 0);
            int at = 0;
            while (at < (int)changed.length()) {
              int comma = changed.indexOf(',', at);
              if (comma < 0) { break; }
              int key = changed.substring(at, comma).toInt();
              if (key > 0 && key < ROOM_BUTTON_SLOTS
                  && !(flashing && key == button_flash_key)) {
                lv_obj_t *b = room_button_obj[key];
                if (b) { deck_button_face(b, bm["b" + String(key)]); }
              }
              at = comma + 1;
            }
          }
          deckLog("[bt] toggles applied");
        }
        else if (mtype == "wifi") {
          // the panel sent our network credentials over BLE (a deck that has
          // never joined a network cannot fetch them). Store them and let loop()
          // join; wifi_server() blocks, and this dispatch is the main loop.
          JSONVar w = btMsg["data"];
          if (w.hasOwnProperty("ssid")) { ssid = (const char *)w["ssid"]; }
          if (w.hasOwnProperty("password")) { password = (const char *)w["password"]; }
          if (w.hasOwnProperty("ap_ssid")) { ap_ssid = (const char *)w["ap_ssid"]; }
          if (w.hasOwnProperty("ap_password")) { ap_password = (const char *)w["ap_password"]; }
          wifi_enabled = true;
          wifi_join_requested = true;
          deckLog("[bt] wifi credentials received");
        }
      }
    }
  }

  // the panel handed us network credentials over BLE: join now (the same
  // blocking join the deck's Net-room WiFi button runs)
  if (wifi_join_requested) {
    wifi_join_requested = false;
    deckLog("[wifi] joining from BLE credentials");
    wifi_server();
  }

  // Now Me arrived on the /now_me web route: draw it here, not in the web
  // handler (remote_room() fetches over HTTPS and drives LVGL - nesting that in
  // the HTTP server's stack reboots the deck)
  if (now_me_requested) {
    now_me_requested = false;
    remote_room();
    buttonMillis = millis();
    lastMillis = millis();
    authorization_pusher(before_me);
    // Now Me is the whole authorization: the wss control socket opens on the
    // pair it just delivered, with no password to type. It may also name a
    // different House machine, so drop the old socket before redialing.
    tauth_remote_enabled = "on";
    wsclient.close();
    ws_connected = 0;
    tauth_connect();
    voice_trigger_apply();
  }

  // the panel's voice setting: keep a listener armed for a model we have, and
  // hold while a manual record or playback owns the microphone (the listener
  // task also stands aside itself; this is what re-arms it afterwards)
  if (voiceCaptureEnabled && !voiceTaskAlive && !isRecording && !audio.isRunning()
      && !voiceAwaitingReply) {
    deckVoiceListenStart();
  }

  // The room can go blank: a Now Me clears buttoned_before, and the room push the
  // bridge is then asked for can be missed - which leaves the screen with no
  // buttons until something else draws. Ask over the bridge again, and if that
  // still says nothing, fetch it over the network the deck already has (the same
  // route the bridge would have called). The clip is a message either way.
  if (jw_room == "room" && !buttoned_before) {
    static uint32_t last_room_ask = 0;
    static int room_ask_tries = 0;
    if (millis() - last_room_ask > 4000) {
      last_room_ask = millis();
      room_ask_tries++;
      if (deviceConnected && room_ask_tries < 3) {
        call_the_president();          // over the bridge: a message, no wait
      }
      else if (homebaseIP.length() && WiFi.status() == WL_CONNECTED) {
        room_ask_tries = 0;
        String watchRequest = https_request("https://" + homebaseIP + "/watch?room=" + room);
        if (watchRequest != "failure" && watchRequest.length() > 2) {
          before_me = watchRequest;
          buttoned_before = true;
          deckLog("[room] fetched over wifi (%u bytes)", (unsigned)watchRequest.length());
          remote_room();
        }
        else {
          deckLog("%s", "[room] wifi fetch failed; will try again");
        }
      }
    }
  }

  // the bridge just came up: ask for anything that changed while it was down,
  // and hand over the taps that queued in the meantime
  static bool state_requested = false;
  if (!deviceConnected) {
    state_requested = false;
  }
  else if (!state_requested && ble_connected_at != 0 && millis() - ble_connected_at > 3000) {
    state_requested = true;
    JSONVar req = JSON.parse("{}");
    req["type"] = "state_request";
    req["chip_id"] = chip_id_maker();
    req["edt"] = "teletype";
    ble_send(req);
    deckLog("[bt] state requested");
  }
  static bool ble_link_was_up = false;
  static uint32_t ble_link_up_at = 0;
  if (deviceConnected && !ble_link_was_up) {
    ble_link_was_up = true;
    ble_link_up_at = millis();
  }
  else if (!deviceConnected) {
    ble_link_was_up = false;
  }
  if (deviceConnected && ble_link_up_at != 0 && millis() - ble_link_up_at > 2500) {
    ble_link_up_at = 0;
    ble_flush_wigi();
  }
  // The audio library is pumped by hand, from here. A task turned out to be
  // worse than useless: if its creation failed or it exited early the flag that
  // said "a task owns the pump" stayed set and nothing drove the I2S at all,
  // which sounds exactly like a silent file. This is reported below when a
  // stream ends.
  static bool audioWasRunning = false;
  if (sayFetchPending && !sayFetchRunning) {
    sayFetchPending = false;
    String* req = sayFetchReq;
    sayFetchReq = nullptr;
    if (req) {
      sayFetchRunning = true;
      if (sayFetchWorkerOk && sayFetchQueue && xQueueSend(sayFetchQueue, &req, 0) == pdPASS) {
        // the worker owns req now and clears sayFetchRunning when it lands
      }
      else {
        delete req;
        sayFetchRunning = false;
        deckLog("%s", "[voice] WiFi fetch queue unavailable");
      }
    }
  }
  if (sayWifiReady && !isRecording && !audio.isRunning()) {
    sayWifiReady = false;
    sayWifiPlaying = true;
    audio.setVolume(volumeLevel);
    bool ok = audio.connecttoFS(*store, "/jawn/reply.wav");
    audio.setVolume(volumeLevel);
    deckLog("[voice] answer pulled over WiFi (%d)", (int)ok);
    if (!ok) {
      sayWifiPlaying = false;
      if (voiceAwaitingReply) { voiceAwaitingReply = false; buttonMillis = millis(); }
    }
  }
  if (audio.isRunning()) {
    audio.loop();
    audioWasRunning = true;
  }
  else if (audioWasRunning) {
    audioWasRunning = false;
    voiceAckUntil = 0;   // the acknowledgment beep (or a reply) has finished
    deckLog("[mic] playback finished (or gave up)");
    if (sayWifiPlaying) {
      sayWifiPlaying = false;
      store->remove("/jawn/reply.wav");
    }
    // the Guide's answer has been said: the screen may time out again from now
    if (voiceAwaitingReply) {
      voiceAwaitingReply = false;
      buttonMillis = millis();
    }
  }

  if (digitalRead(BOARD_TOUCH_INT)) {
    bool res =  touch->read();
    if (res) {
      // A touch has to reset the idle timer like a key or the roller does: with
      // this commented out, tapping a dozing deck did nothing at all - only a key
      // press or a roll of the ball brought the panel back (the getTouch() indev
      // path sets it, but only when LVGL is the one that reads the panel).
      buttonMillis = millis();

      TP_Point  p = touch->getPoint(0);
      static uint32_t lastTouchLog = 0;
      if (millis() - lastTouchLog > 1000) {
        lastTouchLog = millis();
        deckLog("[deck] touch x=%d y=%d int=%d", p.x, p.y, digitalRead(BOARD_TOUCH_INT));
      }
      if (troom == "typewriter" && jw_room == "room") {
        if (millis() >= touchLastMillis + 50 && ws_connected == 1 && ws_mouse_to_send <= 3) {
          ws_mouse_to_send++;
          touchLastMillis = millis();
          JSONVar wsdata;
          wsdata["command"] = "touch";
          wsdata["res_x"] = screenWidth;
          wsdata["res_y"] = screenHeight;
          wsdata["x"] = p.x;
          wsdata["y"] = p.y;
          wsdata["t"] = millis();
          wsdata["r"] = tft.getRotation();
          wsdata["mmr"] = mouse_move_relative;

          if (mouse_move_relative == "on") {
            wsdata["last_x"] = last_x;
            wsdata["last_y"] = last_y;
            wsdata["touching"] = touching;
          }
          String jsonwsdata = JSON.stringify(wsdata);
          wsclient.send(jsonwsdata);
          touching = 1;
          last_x = p.x;
          last_y = p.y;
          ws_mouse_to_send--;
        }
      }
      else if (jw_room == "room") {
        button_writer();
        lv_task_handler();
      }
    }
    else {
      touching = 0;
    }
  }
  // One render pass per loop: this pair used to run twice whenever neither room
  // was the typewriter, and every pass walks and flushes the whole screen.
  if (troom != "typewriter" || jw_room != "typewriter") {
    lv_task_handler();
  }
  if (jw_room == "watch") {
    time_writer("loop");
  }
  if (jw_room == "net") {
    ip_writer();
  }
  static  int16_t last_x;
  static int16_t last_y;
  bool left_button_down = false;
  const uint8_t dir_pins[5] = {1, 2, 3, 15, 0};
  static bool last_dir[5];
  uint8_t pos = 1;
  String movement;
  for (int i = 0; i < 5; i++) {
    bool dir = digitalRead(dir_pins[i]);
    // Serial.println(dir);
    if (last_dir[i] != dir) {
      buttonMillis = millis();
      last_dir[i] = dir;
      if (dir_pins[i] == 1) {
        movement = "left";
        if (roller_ball_direction == "left" && rb_count >= 5) {
          troom = "home";
          jw_room = "room";
          rb_count = 0;
          //authorization_changer("down");
          remote_room();
        }
        else if (roller_ball_direction == "left") {
          rb_count++;
        }
        else {
          rb_count = 0;
        }
        roller_ball_direction = "left";
      }
      if (dir_pins[i] == 2) {
        movement = "right";
        if (roller_ball_direction == "right" && rb_count >= 5) {
          troom = "home";
          clock_writer();          // right is the clock (was the pen room)
          rb_count = 0;
        }
        else if (roller_ball_direction == "right") {
          rb_count++;
        }
        else {
          rb_count = 0;
        }
        roller_ball_direction = "right";
      }
      if (dir_pins[i] == 15) {
        movement = "down";
        if (roller_ball_direction == "down" && rb_count >= 5) {
          troom = "home";
          rb_count = 0;
          pen_room();              // down is the pen room (was configure; the
          //                        configure room is still on the third room
          //                        button)
        }
        else if (roller_ball_direction == "down") {
          rb_count++;
        }
        else {
          rb_count = 0;
        }
        roller_ball_direction = "down";
      }
      if (dir_pins[i] == 3) {
        movement = "up";
        if (roller_ball_direction == "up" && rb_count >= 5) {
          troom = "home";
          jw_room = "chat";
          display_exit();
          button_writer();
          chat_displayer();
          rb_count = 0;
        }
        else if (roller_ball_direction == "up") {
          rb_count++;
        }
        else {
          rb_count = 0;
        }
        roller_ball_direction = "up";
      }
      if (dir_pins[i] == 0) {
        movement = "button";
        if (jw_room == "room" && ws_connected == 1) {
          long timestamp = rtc.getLocalEpoch() - rtc.offset;
  
          JSONVar json;
          json["value"] = dir;
          json["command"] = "mouse";
          json["movement"] = movement;
          json["timestamp"] = timestamp;
  
          String json_p = JSON.stringify(json);
          wsclient.send(json_p);
        }
      }
    }
  }
  if (millis() - wsLastMillis > 2000 && ws_connected == 1) {
    wsclient.send("hey");
    wsLastMillis = millis();

  }

  uint32_t tBeforeServer = millis();
  if (!kb_indev && millis() - lastKbProbe > 5000) {
    lastKbProbe = millis();
    registerKeyboard();
  }
  server.handleClient();
  readRadio();
  uint32_t tAfterRadio = millis();
    // The GPS bring-up retries in the background: bounded, and it stops trying
    // after a few goes so a missing module costs nothing after that. Only while
    // the panel is asleep: the probe blocks for up to a couple of seconds and
    // must not stall a room the person is using.
    if (!gpsReady && gpsAttempts < GPS_MAX_ATTEMPTS && millis() > gpsRetryAt && screenAsleep) {
      gpsAttempts++;
      gpsRetryAt = millis() + GPS_RETRY_INTERVAL;
      deckLog("[gps] retry %u of %u", (unsigned)gpsAttempts, (unsigned)GPS_MAX_ATTEMPTS);
      gpsReady = gpsBringUp(1000, 300, 1, 300);
      if (gpsReady) {
        deckLog("[gps] module ready");
      } else if (gpsAttempts >= GPS_MAX_ATTEMPTS) {
        deckLog("[gps] giving up on the module; the deck runs fine without it");
      }
    }

    // Host -> GPS bridge. One exception: a line that arrives as "JAWNDUMP
    // <path>" is a request to print that file as base64 back up this port, so a
    // recording can be pulled for analysis without wifi. Those bytes still go
    // to the GPS (gibberish to it) so a config tool keeps working.
    static String hostLine;
    while (Serial.available()) {
        char ch = Serial.read();
        SerialGPS.write(ch);
        if (ch == '\n') {
            if (hostLine.startsWith("JAWNDUMP ")) {
                serialDumpFile(hostLine.substring(9));
            }
            else if (hostLine.startsWith("JAWNREC ")) {
                serialRecordStart((uint32_t)hostLine.substring(8).toInt());
            }
            else if (hostLine.startsWith("JAWNREG ")) {
                serialRegWrite(hostLine.substring(8));
            }
            else if (hostLine.startsWith("JAWNSLOT ")) {
                serialSlotSet(hostLine.substring(9));
            }
            else if (hostLine.startsWith("JAWNCH ")) {
                int ch = hostLine.substring(7).toInt();
                mic_channels = (ch == MIC_TDM_SLOTS) ? MIC_TDM_SLOTS : 1;
                Serial.printf("JAWNCH %d\n", mic_channels);
            }
            else if (hostLine.startsWith("JAWNBT ")) {
                String onoff = hostLine.substring(7);
                onoff.trim();
                if (onoff == "on") {
                    start_ble_transfer();
                }
                else {
                    stop_ble_transfer();
                }
                // persist it the way the net room's toggle does at the next
                // screen sleep, so the boot-time start can be tested from here
                configSave();
                Serial.printf("JAWNBT %s\n", bt_enabled ? "on" : "off");
            }
            else if (hostLine.startsWith("JAWNVOICE ")) {
                // pick the voice model from the host, for tuning without the
                // panel: "JAWNVOICE hey_jawn" / "JAWNVOICE vad" / "JAWNVOICE off"
                String m = hostLine.substring(10);
                m.trim();
                voice_trigger = m.length() ? m : "off";
                voice_trigger_apply();
                Serial.printf("JAWNVOICE %s\n", voice_trigger.c_str());
            }
            else if (hostLine.startsWith("JAWNFLOOR ")) {
                // the end-of-speech floor: "JAWNFLOOR auto" follows the room,
                // "JAWNFLOOR 1800" pins it. The room figure it rides on is printed
                // beside it, so an adjustment is a measurement and not a guess.
                String fl = hostLine.substring(10);
                fl.trim();
                voice_floor = fl.length() ? fl : "auto";
                Serial.printf("JAWNFLOOR %s (room %u -> %u)\n", voice_floor.c_str(),
                              (unsigned)voice_ambient_rms, (unsigned)voice_end_floor());
            }
            hostLine = "";
        }
        else if (ch != '\r' && hostLine.length() < 96) {
            hostLine += ch;
        }
    }

    {
        // Keep the GPS off the loop's critical path: a backlog of NMEA at the
        // wrong baud used to hold this loop for seconds. Parse at most 10 ms
        // worth per pass; the rest waits for the next pass.
        uint32_t gps_started = millis();
        while (SerialGPS.available() && millis() - gps_started < 10) {
            int c = SerialGPS.read();
            // Serial.write(c);
            if (gps.encode(c)) {
                displayInfo();
            }
        }
    }

    if (millis() > 30000 && gps.charsProcessed() < 10) {
        Serial.println(F("No GPS detected: check wiring."));
        delay(1000);
    }
  uint32_t tAfterGps = millis();
  // A spoken command needs the panel to itself: hold the idle timeout off while a
  // clip is being captured and sent, since a doze writes the config and changes
  // the panel, and both stall the microphone. Show the same orange ring the watch
  // does while the listener has a clip, so it is clear it heard you. voiceHeard is
  // set on the first frame the model reads, so the panel lights the moment the
  // wake phrase lands - not after the capture commits.
  if (voiceHeard || voiceRecording) { buttonMillis = millis(); }
  if (voiceAwaitingReply) {
    buttonMillis = millis();
    // a reply that never comes must not hold the panel on for ever; while it is
    // actually being spoken the hold continues
    if (!audio.isRunning() && millis() - voiceAwaitingSince > 30000) {
      voiceAwaitingReply = false;
      buttonMillis = millis();
    }
  }
  {
    static bool voice_border_on = false;
    bool ring = voiceHeard || voiceRecording;
    if (ring != voice_border_on) {
      voice_border_on = ring;
      voice_border_show(ring);
    }
  }
  // the Guide's answer is a few seconds' notice, not a screen of its own
  if (say_shown_at && millis() - say_shown_at > SAY_TEXT_MS) {
    say_shown_at = 0;
    if (say_label) { lv_obj_add_flag(say_label, LV_OBJ_FLAG_HIDDEN); }
  }
  // The panel sleeps after the idle timeout and any input (anything that
  // refreshes buttonMillis) brings it back. The flag makes each transition
  // happen exactly once: the wake branch used to re-run tft.begin() - a
  // half-second panel re-init - on every loop whenever brightness restored as
  // 0, which is what a wiped config produces.
  if (millis() - buttonMillis > DEFAULT_SCREEN_TIMEOUT && !screenAsleep) {
    tempBrightness = lastBrightness;
    configSave();

    // instant: the old 16-step fade cost ~0.5 s of the sleep transition and
    // nobody is reading the screen at that point
    setBrightness(0);

      //If you need other peripherals to maintain power, please set the IO port to hold

    tft.writecommand(0x10);      //set display enter sleep mode
    screenAsleep = true;
    // Sleep mode stops more than the panel: the radios and the CPU go down too,
    // and the first touch, key or trackball move brings them back. A clip being
    // recorded or played (or an answer still on its way) keeps the deck awake -
    // light sleep would stall the microphone and the network fetch.
    if (lightSleep) {
      bool busy = isRecording || audio.isRunning() || sayFetchRunning ||
                  voiceRecording || voiceAwaitingReply;
      if (!busy) {
        deck_low_power_sleep();
        buttonMillis = millis();
      }
    }
  }
  else if (screenAsleep && millis() - buttonMillis < DEFAULT_SCREEN_TIMEOUT) {
    // Wake the panel out of its own sleep command; a full tft.begin() here was
    // a ~half-second re-init of a display that was never reset.
    screenAsleep = false;
    tft.writecommand(0x11);      // sleep out
    delay(120);
    tft.writecommand(0x29);      // display on
    uint8_t target = brightnessLevel > 0 ? (uint8_t)brightnessLevel : (uint8_t)7;
    setBrightness(target);
    lv_task_handler();
  }
  uint32_t tAfterSleep = millis();

  // A quiet heartbeat. The USB CDC only talks while a host is listening, and a
  // periodic line makes "is the deck alive, and is the GPS up?" answerable
  // without having to catch the boot output.
  uint32_t loopEnd = millis();
  if (loopEnd - loopStart > 200) {
    deckLog("[deck] slow loop %u ms (ui %u, server+radio %u, gps %u, sleep %u, rest %u) bright=%u last=%u lvl=%u idle=%u",
            (unsigned)(loopEnd - loopStart), (unsigned)(tBeforeServer - loopStart),
            (unsigned)(tAfterRadio - tBeforeServer), (unsigned)(tAfterGps - tAfterRadio),
            (unsigned)(tAfterSleep - tAfterGps), (unsigned)(loopEnd - tAfterSleep),
            (unsigned)currentBrightness, (unsigned)lastBrightness, (unsigned)brightnessLevel,
            (unsigned)(millis() - buttonMillis));
  }
  static uint32_t lastBeat = 0;
  if (millis() - lastBeat > 30000) {
    lastBeat = millis();
    deckLog("[deck] alive heap=%u room=%s gps=%d",
            (unsigned)ESP.getFreeHeap(), jw_room.c_str(), (int)gpsReady);
  }
}

