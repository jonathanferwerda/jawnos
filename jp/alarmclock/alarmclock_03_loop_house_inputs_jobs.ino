void handleCreate() {
  server.send(200, "text/plain", "");
}
unsigned long lastOTAMillis = millis();
unsigned long lastOTASendMillis = millis();
void ledFlasher(int interval, int duration) {
  pinMode(led, OUTPUT);
  unsigned long end_time = millis() + duration;
  while ((long)(millis() - end_time) < 0) {
    if (digitalRead(led) == 1) {
      digitalWrite(led, LOW);
    }
    else {
      digitalWrite(led, HIGH);
    }
    delay(interval);
  }
  digitalWrite(led, HIGH);
}


void handleCreateProcess() {
  // A raw upload never goes through the WebServer's query-argument parser, so
  // server.arg() is empty there. The manager sends the device authorization as
  // a collected header; keep the query fallback for a plain upload or an older
  // manager.
  String rauth = server.header("authorization");
  if (rauth == "") { rauth = server.arg("authorization"); }
  if (authorization.length() > 0 && rauth == authorization) {
    pinMode(led, OUTPUT);
    int brightness = 255;
    String path = "/" + server.pathArg(0);
    HTTPRaw& raw = server.raw();
    
    if (raw.status == RAW_START) {
      if (LittleFS.exists((char *)path.c_str())) {
        LittleFS.remove((char *)path.c_str());
      }
      rawFile = LittleFS.open(path.c_str(), "w");
      
    } else if (raw.status == RAW_WRITE) {
      if (rawFile) {
        rawFile.write(raw.buf, raw.currentSize);
      }
      if ((unsigned long)(millis() - lastOTAMillis) > 20) {
        lastOTAMillis = millis();
        if (digitalRead(led) == 1) {
          digitalWrite(led, LOW);
        }
        else {
          digitalWrite(led, HIGH);
        }
      }
      if ((unsigned long)(millis() - lastOTASendMillis) > 3000) {
        lastOTASendMillis = millis();
        String current_size = String(raw.totalSize);
        String jobTime = String(millis());
        coreJobs[jobTime]["type"] = "https";
        coreJobs[jobTime]["url"] = "https://" + homebaseIP +
          "/watch/ota_status?current_size=" + current_size +
          "&status=uploading";
        
      }
    } else if (raw.status == RAW_END) {
      if (rawFile) {
        // The OTA shim programs whole 4 KB pages; an image that ends mid-page
        // would carry whatever followed it in the read buffer into the last
        // page. Pad with erased-flash bytes so the tail is harmless.
        size_t pad = (4096 - (raw.totalSize % 4096)) % 4096;
        uint8_t fill[256];
        memset(fill, 0xFF, sizeof(fill));
        while (pad) {
          size_t n = pad < sizeof(fill) ? pad : sizeof(fill);
          rawFile.write(fill, n);
          pad -= n;
        }
        rawFile.close();
      }
      String current_size = String(raw.totalSize);

      String jobTime = String(millis());
      coreJobs[jobTime]["type"] = "https";
      coreJobs[jobTime]["url"] = "https://" + homebaseIP +
        "/watch/ota_status?current_size=" + current_size +
        "&status=updating";

      picoOTA.begin();
      picoOTA.addFile(path.c_str());
      picoOTA.commit();
      // The shim reads this file from LittleFS after the reboot, so it must
      // stay until then. Removing it here left the command page pointing at
      // nothing; the next upload replaces it at RAW_START.
      String https = https_request(
        "https://" + homebaseIP +
        "/watch/ota_status?current_size=" + current_size +
        "&status=complete"
      );
      delay(1000);
      rebooting = 1;
    }
  }
}
void jawn_loop() {
  // Switches first. A board's own switch must not wait behind an HTTP request
  // or the LCD, and the local internal job below is the fast path to its relay.
  input_scanner();
  server.handleClient();
  read_time();
  // USB serial: echo (as before) and accept a "JAWNCFG <json>" line from the
  // manager, which writes the stored WiFi and role and then reboots us.
  usb_config_loop();
  ble_loop();
  if (config_reload_pending) {
    config_reload_pending = false;
    config_init();
  }
  // Scheduled output jobs read/write the config document, so they belong on
  // this core with the switch scanner.
  run_local_jobs();
  // Persist a switch/relay change once it has been quiet for a moment. Doing
  // it inline made a flick wait on a LittleFS rewrite.
  if (config_dirty && (uint32_t)(millis() - config_dirty_at) > 2000) {
    config_dirty = false;
    config_writer();
  }

  if (BOOTSEL) {
    File f = LittleFS.open("config.txt", "w");
    f.print("");
    Serial.println(rp2040.getChipID());
    rp2040.reboot();
  }

  delay(10);
}

void loop1() {
  if ((unsigned long)(millis() - lastPing) > 60000) {
    homebasePing();
  }
  if ((unsigned long)(millis() - lastWifiCheck) > 10000) {
    lastWifiCheck = millis();
    wifi_supervise();
  }
  // the crystal drifts; re-anchor the epoch from the (NTP-synced) house every
  // six hours, so a long uptime never accumulates the old 9-minute offset
  if ((unsigned long)(millis() - lastTimeSync) > 21600000UL && wifiState == "connected" && homebaseIP != "") {
    request_time();
  }
  if (rebooting == 1) {
    rp2040.reboot();
  }
  // Pull the role (components and internal_jobs) from the house. A blocking
  // HTTPS call, so it runs on this core: putting it on core 0 spent most of a
  // loop downloading a refusal page and starved the switch scanner.
  if (!president_loaded && wifiState == "connected" && homebaseIP != "" && (millis() - lastPresidentTry > 20000)) {
    lastPresidentTry = millis();
    call_the_president();
  }
  handle_jobs();
//  delay(10);
}

void homebasePing() {
  if (wifiState == "connected") {
    homebaseOnline = 1;  // this IS the probe: allow it to run after a failure
    String https = https_request(
      "https://" + homebaseIP +
      "/watch/alive?millis=" + millis()
    );
    JSONVar alive;
    if (https != "failure") {
      alive = JSON.parse(https);
    }
    Serial.println(https);
    if (String(alive["status"]) == "alive") {
      homebaseChecked();
      // The preferred machine wins the moment it answers again, so the phone or
      // laptop the board was paired to reclaims it from a temporary fallback.
      if (homebasePreferredIP != "" && homebasePreferredIP != homebaseIP) {
        houseAdoptIfAlive(homebasePreferredIP);
      }
      lastPing = millis();
      return;
    }
    Serial.println("no ping");
    if (houseTryFallback()) {
      lastPing = millis();
      return;
    }
    homebaseOnline = 0;
  }
  else {
    // wifi_supervise() owns reconnecting and the AP, so there is one owner.
    wifiState = "disconnected";
  }
  lastPing = millis();
}

// A house entry is "ip:arm". Add it once.
void houseAdd(const String &ip, int arm) {
  if (ip == "" || arm <= 0) { return; }
  String addr = ip + ":" + String(arm);
  for (int i = 0; i < houseCount; i++) {
    if (houseAddr[i] == addr) { return; }
  }
  if (houseCount >= HOUSE_MAX) { return; }
  houseAddr[houseCount++] = addr;
}

void houseLearnJson(const String &js) {
  // Now Me's "houses": [{"ip":"192.168.2.3","arm":45547,...}, ...]
  if (js.length() < 2) { return; }
  JSONVar list = JSON.parse(js);
  if (JSON.typeof(list) != "array") { return; }
  for (int i = 0; i < (int)list.length(); i++) {
    JSONVar h = list[i];
    if (JSON.typeof(h) != "object") { continue; }
    String ip = jstr(h["ip"]);
    int arm = (int)jint(h["arm"]);
    if (arm <= 0 && ip != "") { arm = 45547; }
    houseAdd(ip, arm);
  }
}

void houseRememberPreferred(const String &hb) {
  if (hb == "") { return; }
  homebasePreferredIP = hb;
  config["homebasePreferredIP"] = homebasePreferredIP;
  // the preferred machine is also a candidate, so a reboot with no fresh Now Me
  // can still return to it
  String ip = hb;
  int split = ip.lastIndexOf(':');
  int arm = 0;
  if (split > 0) { arm = ip.substring(split + 1).toInt(); ip = ip.substring(0, split); }
  houseAdd(ip, arm);
}

// Probe one address quietly, without disturbing the active homebase unless it
// answers. Returns true and adopts it on success.
bool houseAdoptIfAlive(const String &addr) {
  if (addr == "" || addr == "failure") { return false; }
  String saved = homebaseIP;
  homebaseOnline = 1;
  homebaseIP = addr;
  String r = https_request("https://" + addr + "/watch/time?");
  // A denial is a template answered 200 with a ~130 KB body; the timestamp is
  // the one answer that proves the machine accepted the pair. `https_request`
  // keeps the short answer only, so a long body is a refusal too.
  if (r == "failure" || r == "no ping" || r.indexOf("timestamp") < 0 || r.length() > 4096) {
    homebaseIP = saved;
    homebaseOnline = millis();
    return false;
  }
  int split = addr.lastIndexOf(':');
  homebase = (split > 0) ? addr.substring(0, split) : addr;
  config["homebaseIP"] = addr;
  config["homebase"] = homebase;
  config_writer();
  Serial.println("[house] now using " + addr);
  return true;
}

bool houseTryFallback() {
  for (int i = 0; i < houseCount; i++) {
    if (houseAddr[i] == homebaseIP) { continue; }
    if (houseAdoptIfAlive(houseAddr[i])) { return true; }
  }
  return false;
}

void homebaseChecked() {
  homebaseOnline = millis();
  lastPing = millis();
}

void request_time() {
  if (homebaseIP == "") { return; }
  String req = "https://" + homebaseIP + "/watch/time?";
  String jobTime = String(millis());
  coreJobs[jobTime]["type"] = "https";
  coreJobs[jobTime]["url"] = req;
  coreJobs[jobTime]["response"] = "time";
  lastTimeSync = millis();
}

// A successful join: drop the provisioning AP and bring mDNS and the clock up
// on the network we just rejoined. Do not switch to WIFI_STA here: the join
// often happens in AP_STA after the provisioning AP came up, and changing the
// mode at that moment drops the station it just established. The AP is off;
// leaving the mode as it is keeps the link.
void wifi_join_done() {
  WiFi.softAPdisconnect(true);
  wifiState = "connected";
  wifiDownTicks = 0;
  president_loaded = false;
  jawnos_mdns_up = false;
  jawnos_mdns_start();
  server.begin();
  request_time();
  Serial.println("[wifi] reconnected; AP down");
  homebasePing();
}

// The saved SSID is not a one-shot. When the router goes away, keep an AP up so
// the device is still reachable for provisioning, and keep trying the saved
// network; the moment it comes back, the AP goes down again.
void wifi_supervise() {
  bool has_creds = config["ssid"] != "" && config["password"] != "";

  if (WiFi.status() == WL_CONNECTED) {
    wifiDownTicks = 0;
    if (wifiState != "connected") { wifi_join_done(); }
    return;
  }

  if (wifiState == "connected") {
    wifiState = "disconnected";
    jawnos_mdns_up = false;
  }

  wifiDownTicks++;
  if (!has_creds) { return; }

  if (wifiDownTicks == 3) {
    WiFi.mode(WIFI_AP_STA);
    if (WiFi.softAPIP() == IPAddress(0, 0, 0, 0)) {
      WiFi.softAP(ap_ssid.c_str(), ap_password.c_str());
      Serial.println("[wifi] router away; AP up while retrying");
    }
  }
  if (wifiDownTicks >= 3 && (wifiDownTicks % 3 == 0)) {
    if (multi.run() == WL_CONNECTED) { wifi_join_done(); }
  }
}

static void local_apply(int idx, const String &state) {
  local_in_t &in = local_ins[idx];
  // The switch just moved, so it is the newest word on these pins. Stamp them
  // with the event time the manager's commands are ordered by; a relay command
  // that was minted before this flip and arrives late is then dropped instead
  // of turning the relay back on.
  int64_t ev = event_ms();
  for (int o = 0; o < in.out_n; o++) {
    int op = in.out_pin[o];
    String st = state;
    if (in.out_inv[o] == 1) { st = (st == "on") ? "off" : "on"; }
    pinMode(op, OUTPUT);
    digitalWrite(op, st == "on" ? HIGH : LOW);
    if (in.out_comp[o] == "relay") { config["relay"][String(op)] = st; }
    else if (in.out_comp[o] == "led") { config["led"][String(op)] = st; }
    command_mark_pin(op, ev);
    event_log(op, st == "on", 1);
    local_out_changed_at = millis();
  }
}

// Is this output pin driven by a switch on this board? If so the switch owns
// it: an app toggle must not fight the physical position (that is what made a
// replug flash the relay before the switch was read).
static bool pin_is_switch_driven(int pin) {
  for (int i = 0; i < local_in_count; i++) {
    if (!local_ins[i].is_switch) { continue; }
    for (int o = 0; o < local_ins[i].out_n; o++) {
      if (local_ins[i].out_pin[o] == pin) { return true; }
    }
  }
  return false;
}

// Which road a switch/button report takes. The LAN is the reliable one: a
// Bluetooth link can still read as up after its listener closed, and the event
// then disappears (the relay moves, the Manager never hears the stop). Use
// Bluetooth only when the board has no working network to report over - the
// crash, the fresh board, or the provisioning AP that cannot reach the house.
static bool lan_report_ready() {
  return wifiState == "connected" && homebaseIP != "" && homebaseOnline != 0;
}

// At boot or a role reload, put every switch-driven output at the position the
// switch is actually in. Otherwise the relay is restored from the app's toggle
// and the first scan fights it.
static void local_inputs_apply_all() {
  for (int i = 0; i < local_in_count; i++) {
    local_in_t &in = local_ins[i];
    if (!in.is_switch) { continue; }
    int r = digitalRead(in.pin);
    String state = ((r ^ in.inverted) ? "on" : "off");
    local_apply(i, state);
  }
}

static void local_input_scanner() {
  static int raw[LOCAL_IN_MAX];
  static uint32_t raw_at[LOCAL_IN_MAX];
  static bool raw_seen[LOCAL_IN_MAX];
  for (int i = 0; i < local_in_count; i++) {
    local_in_t &in = local_ins[i];
    int r = digitalRead(in.pin);
    if (!raw_seen[i] || raw[i] != r) {
      raw_seen[i] = true;
      raw[i] = r;
      raw_at[i] = millis();
      continue;
    }
    if ((uint32_t)(millis() - raw_at[i]) < 80) { continue; }
    if (in.is_switch) {
      // The relay coil firing right now can glitch this line. Re-arm the
      // settle timer instead of swallowing the change, so a real flick during
      // the blanking window is still seen when it ends.
      if ((uint32_t)(millis() - local_out_changed_at) < OUTPUT_BLANK_MS) {
        raw_at[i] = millis();
        continue;
      }
      if (local_sw_seen[in.pin] && r == local_sw_state[in.pin]) { continue; }
      local_sw_seen[in.pin] = true;
      local_sw_state[in.pin] = r;
      // The role says whether the input is active-low. A switch that reads
      // HIGH when it is off otherwise reports the opposite of its position -
      // and drives the relay the wrong way.
      String state = ((r ^ in.inverted) ? "on" : "off");
      event_log(in.pin, r, 0);
      local_apply(i, state);
      if (!lan_report_ready() && ble_up && ble_notify_enabled) {
        JSONVar sm;
        sm["type"] = "switch";
        sm["chip_id"] = String(rp2040.getChipID());
        sm["edt"] = "microcontroller";
        JSONVar sd;
        sd["room"] = "1";
        sd["switch"] = String(in.pin);
        sd["state"] = state;
        sd["timestamp"] = event_timestamp();
        sd["timestamp_ms"] = event_timestamp_ms();
        sd["ms"] = String(millis());
        sm["data"] = sd;
        ble_send_json(JSON.stringify(sm));
      }
      else {
        String jobTime = String(millis());
        coreJobs[jobTime]["type"] = "https";
        coreJobs[jobTime]["url"] = "https://" + homebaseIP +
          "/watch/switch?room=1&switch=" + String(in.pin) + "&state=" + state +
          "&chip_id=" + String(rp2040.getChipID()) +
          "&timestamp=" + event_timestamp() + "&timestamp_ms=" + event_timestamp_ms();
        coreJobs[jobTime]["response"] = "switch";
      }
      config_dirty = true;
      config_dirty_at = millis();
    }
    else {
      bool pressed = (r ^ in.inverted) ? true : false;
      if (pressed && local_btn_pressed[in.pin] == 0) {
        local_btn_pressed[in.pin] = 1;
        String nstate = "on";
        if (in.out_n > 0) { nstate = (digitalRead(in.out_pin[0]) == HIGH) ? "off" : "on"; }
        local_apply(i, nstate);
        String toggle = (nstate == "on") ? "1" : "0";
        if (!lan_report_ready() && ble_up && ble_notify_enabled) {
          JSONVar bm;
          bm["type"] = "button";
          bm["chip_id"] = String(rp2040.getChipID());
          bm["edt"] = "microcontroller";
          JSONVar bp;
          bp["room"] = "1";
          bp["button"] = String(in.pin);
          bp["toggle"] = toggle;
          bp["timestamp"] = event_timestamp();
          bp["timestamp_ms"] = event_timestamp_ms();
          bp["ms"] = String(millis());
          bm["payload"] = bp;
          ble_send_json(JSON.stringify(bm));
        }
        else {
          String jobTime = String(millis());
          coreJobs[jobTime]["type"] = "https";
          coreJobs[jobTime]["url"] = "https://" + homebaseIP +
            "/watch/button?room=1&button=" + String(in.pin) + "&toggle=" + toggle +
            "&chip_id=" + String(rp2040.getChipID()) +
            "&timestamp=" + event_timestamp() + "&timestamp_ms=" + event_timestamp_ms();
          coreJobs[jobTime]["response"] = "button";
        }
        config_dirty = true;
        config_dirty_at = millis();
      }
      else if (!pressed) { local_btn_pressed[in.pin] = 0; }
    }
  }
}

void input_scanner() {
  if (input_working == 1) {
    return;
  }
  input_working = 1;
  local_input_scanner();
  JSONVar potKeys = config["pot"].keys();
  for (int i = 0; i < potKeys.length(); i++) {
    String spin = potKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    int potState = analogRead(pin);
   // Serial.println(potState);
    String bs = String(potState);
    int lbs = String(config["pot"][spin]["lastValue"]).toInt();
    String changed = String(config["pot"][spin]["changed"]);
    String ls = (const char *)config["pot"][spin]["lastSend"];
    uint32_t lastSend = (uint32_t)strtoul(ls.c_str(), nullptr, 10);
    if (potState != lbs || changed == "yes") {
      int min = lbs - 12;
      int max = lbs + 12;
      String lm = (const char *)config["pot"][spin]["lastMove"];
      uint32_t lastMove = (uint32_t)strtoul(lm.c_str(), nullptr, 10);
      lastMove = lastMove + 300;

      if (potState < min || potState > max) {
        config["pot"][spin]["lastMove"] = String(millis());
        lastMove = millis();
        lastMove = lastMove;// + 300;

        String name = String(config["pot"][potKeys[i]]["name"]);
        String jij = config["internal_jobs"];
        JSONVar ij = JSON.parse(jij);
        if (ij[name].length() > 0) {
          config["pot"][spin]["lastValue"] = bs;          

          for (int j = 0; j < ij[name].length(); j++) {
            int p = String(ij[name][j]["numero"]).toInt();
            int inv = String(ij[name][j]["inverted"]).toInt();
            String tp = String(ij[name][j]["threshold_percentage"]);
            double thresh = tp.toDouble();
            
            thresh = ( thresh / 100 ) * 1024;
            String jState = "off";
            if (inv == 1) {
              if (potState <= thresh) {
                jState = "on";
              }
            }
            else {
              if (potState >= thresh) {
                jState = "on";
              }
            }
            if (String(ij[name][j]["component"]) == "relay") {
              relay_toggle(p, jState, false, 6);
            }
            if (String(ij[name][j]["component"]) == "led") {
              led_toggle(p, jState, false);
            }
          }
          
          config["pot"][spin]["changed"] = "yes";

          config_writer();
        }

      }


      // wrap-safe: a negative delta means the stored millis is "ahead" (the
      // counter wrapped), so re-base it; otherwise require 500 ms since the last
      // send and the 300 ms move debounce to have passed.
      if ((int32_t)(millis() - lastSend) < 0) {
        lastSend = millis();
        config["pot"][spin]["lastSend"] = String(lastSend);
      }
      changed = String(config["pot"][spin]["changed"]);
      bool send_due = (int32_t)(millis() - lastSend) >= 500;
      bool move_due = (int32_t)(millis() - lastMove) >= 0;
      if (send_due && move_due && changed == "yes") {
        config["pot"][spin]["lastSend"] = String(millis());
          
        potState = analogRead(pin);
          // Serial.println(potState);
        bs = String(potState);
        config["pot"][spin]["lastValue"] = bs;
        config["pot"][spin]["changed"] = "no";
        
        config_writer();
        if (ble_up && ble_notify_enabled) {
          JSONVar mm;
          mm["type"] = "measure";
          mm["chip_id"] = String(rp2040.getChipID());
          mm["edt"] = "microcontroller";
          JSONVar md;
          md["room"] = "1";
          md["component"] = "pot";
          md["button"] = String(spin.toInt());
          md["measure"] = bs;
          md["min"] = "0";
          md["max"] = "1024";
          md["timestamp"] = event_timestamp();
          mm["data"] = md;
          ble_send_json(JSON.stringify(mm));
        }
        else {
          String jobTime = String(millis());
          coreJobs[jobTime]["type"] = "https";
          coreJobs[jobTime]["url"] = "https://" + homebaseIP +
            "/watch/measure?room=1&button=" + spin + "&measure=" + bs +
            "&component=pot&min=0&max=1024";
          coreJobs[jobTime]["response"] = "pot";
        }

      }
    }
  }
  input_working = 0;
}

String led_toggle(int pin, String state, bool persist) {

  pinMode(pin, OUTPUT);

  if (state == "on") {
    digitalWrite(pin, HIGH);
  }
  else {
    digitalWrite(pin, LOW);
  }
  local_out_changed_at = millis();
  String spin = String(pin);
  config["led"][spin] = state;
  if (persist) { config_writer(); }
  return state;
}

String relay_toggle(int pin, String state, bool persist, int src) {

  pinMode(pin, OUTPUT);

  if (state == "on") {
    digitalWrite(pin, HIGH);
  }
  else {
    digitalWrite(pin, LOW);
  }
  event_log(pin, state == "on", src);
  local_out_changed_at = millis();
  String spin = String(pin);
  config["relay"][spin] = state;
  if (persist) { config_writer(); }
  return state;
}

String servo_toggle(int pin, String state) {
  int stat = state.toInt();

  int val = (stat / 100);
  Serial.println(val);
  val = val * 180;
  String spin = String(pin);
  Serial.println(val);
  Serial.println(stat);
  
  if (!myservo.attached()) {
    myservo.attach(pin);
  }
  myservo.write(stat);
  String vale = String(val);
  config["servo"][spin] = vale;
  config_writer();
  return vale;
}
void push_job(String component,int pin, String state, String timestamp, String uuid, String appt_uuid) {
  String spin = String(pin);
  Serial.println("pushing job " + uuid + " " + timestamp);
  config["jobs"][uuid]["pin"] = spin;
  config["jobs"][uuid]["timestamp"] = timestamp;
  config["jobs"][uuid]["component"] = component;
  config["jobs"][uuid]["state"] = state;
  config["jobs"][uuid]["uuid"] = uuid;
  config["jobs"][uuid]["appt_uuid"] = appt_uuid;
}

// Scheduled output jobs. This reads and rewrites the config document, so it
// runs on core 0 with the switch scanner; only the blocking network work below
// stays on core 1.
void run_local_jobs() {
  if (time_defined && config["jobs"].keys().length() > 0) {
    // local epoch -> the UTC milliseconds the appointments carry
    int64_t timestamp = now_ms() - (offset * 1000);

    JSONVar jobKeys = config["jobs"].keys();
    for (int i = 0; i < jobKeys.length(); i++) {
      String times = String(config["jobs"][jobKeys[i]]["timestamp"]);
      int64_t ts = times.toDouble();

      if (timestamp >= ts) {
        Serial.print(jobKeys[i]);
        Serial.println(ts);
        String spin = config["jobs"][jobKeys[i]]["pin"];
        String component = config["jobs"][jobKeys[i]]["component"];
        String state = config["jobs"][jobKeys[i]]["state"];
        String uuid = config["jobs"][jobKeys[i]]["uuid"];

        int pin = spin.toInt();
        String cid = command_id(uuid, component, "", state, ts);
        // A delay pushed this job after another road already carried the same
        // command; it has already been applied, so do not click again.
        if (!command_redundant(cid, pin, component, state, ts)) {
          if (component == "relay") {
            state = relay_toggle(pin,state,false,5);
            config_dirty = true;
            config_dirty_at = millis();
          }
          else if (component == "led") {
            state = led_toggle(pin,state,false);
            config_dirty = true;
            config_dirty_at = millis();
          }
          else if (component == "servo") {
            state = servo_toggle(pin,state);
          }
        }
        command_mark_pin(pin, ts);
        command_remember(cid, component, "", ts);

        config["jobs"][uuid] = undefined;
      }
    }
  }
}

