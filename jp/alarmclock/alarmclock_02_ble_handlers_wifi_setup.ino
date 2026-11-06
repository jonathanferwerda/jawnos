static void ble_handle_json(String json) {
  JSONVar msg = JSON.parse(json);
  if (JSON.typeof(msg) != "object") { return; }
  String type = jstr(msg["type"]);
  String to = jstr(msg["to"]);
  String mine = String(rp2040.getChipID());
  // A relay envelope from the house (or from a peer bridge). Unwrap it only when
  // it names this chip; the manager has already routed it, so anything else is
  // either a stale copy or a message this board is relaying for a watch that is
  // out of its homebase's range.
  if (type == "relay") {
    if (to != "" && to != mine) { relay_out_forward(msg, json, "/watch/ble_relay", "relay"); return; }
    JSONVar inner = msg["message"];
    if (JSON.typeof(inner) != "object") { return; }
    msg = inner;
    type = jstr(msg["type"]);
  }
  // A volume tap names the house (all, self or a machine), never this board. It
  // is forwarded even when it carries no `to`, so a bare Vol+ step still lands.
  if (type == "volume") { relay_out_forward(msg, json, "/watch/volume", "volume"); return; }
  // Any other command that names a chip other than this one is a message the
  // sender meant for the house; hand it over instead of dropping it.
  if (to != "" && to != mine) { relay_out_forward(msg, json, "/watch/ble_relay", "relay"); return; }
  if (type == "now_me") { ble_apply_now_me(msg["data"]); }
  else if (type == "board_config") { ble_apply_board_config(msg["data"]); }
  else if (type == "room") { ble_apply_board_config(msg["data"]["payload"]); }
  else if (type == "toggles") {
    JSONVar d = msg["data"];
    JSONVar k = d.keys();
    for (int i = 0; i < k.length(); i++) { ble_apply_app_state(String(k[i]), jstr(d[k[i]])); }
  }
  else if (type == "toggle") {
    JSONVar d = msg["data"];
    ble_apply_app_state(jstr(d["app"]), jstr(d["state"]), jstr(d["uuid"]), jint64(d["timestamp"]));
  }
  else if (type == "set") { ble_apply_set(msg["data"]); }
  else if (type == "wifi") { ble_apply_wifi(msg["data"]); }
  else if (type == "button") {
    JSONVar d = msg["data"];
    String numero = jstr(d["numero"]);
    if (numero != "") {
      config["button"][numero]["toggle"] = String((long)jint(d["toggle"]));
      config_writer();
    }
  }
  // hello, voice_* and anything else the watch/deck uses is simply not ours.
}

static void ble_process_frame(String frame) {
  int slash = frame.indexOf('/');
  int colon = frame.indexOf(':');
  if (slash > 0 && colon > slash && slash < 6) {
    int idx = frame.substring(0, slash).toInt();
    int total = frame.substring(slash + 1, colon).toInt();
    if (total > 0 && total <= 512 && idx >= 0 && idx < total) {
      if (idx == 0 || ble_rx_total != total || (millis() - ble_rx_at) > 5000) {
        ble_rx_parts.clear();
        ble_rx_total = total;
      }
      ble_rx_parts[idx] = frame.substring(colon + 1);
      ble_rx_at = millis();
      if ((int)ble_rx_parts.size() == total) {
        String msg;
        for (int i = 0; i < total; i++) { msg += ble_rx_parts[i]; }
        ble_rx_parts.clear();
        ble_rx_total = 0;
        ble_handle_json(msg);
      }
      return;
    }
  }
  ble_handle_json(frame);
}

static void ble_loop() {
  uint8_t b;
  while (ble_rx_queue.read(&b)) {
    if (b == 0x1E) {
      if (ble_rx_frame.length()) {
        ble_process_frame(ble_rx_frame);
        ble_rx_frame = "";
      }
    }
    else if (ble_rx_frame.length() < 8192) {
      ble_rx_frame += (char)b;
    }
  }
  if (ble_up && ble_notify_enabled && !ble_state_requested && ble_connected_at && (millis() - ble_connected_at) > 3000) {
    ble_state_requested = true;
    String chip = String(rp2040.getChipID());
    JSONVar req;
	    req["type"] = "state_request";
	    req["chip_id"] = chip;
	    req["edt"] = "microcontroller";
	    // The LAN address the board actually holds. The manager can use it for the
	    // HTTP rail (and record it), instead of falling back to a BLE reconnect
	    // when the stored address is stale.
	    req["ip"] = WiFi.localIP().toString();
	    // Which build this is. The manager compares it with the image it has
	    // staged, so the Embedded panel can say "update available" and the
	    // auto-OTA sweep knows whether a push is needed.
	    req["version"] = JAWN_FW_VERSION;
    // Omit an empty homebase: this JSONVar build serializes an empty String as
    // an empty token, which made the whole message unparseable at the manager.
    if (homebaseIP != "") { req["homebase"] = homebaseIP; }
    ble_send_json(JSON.stringify(req));
    JSONVar board;
    board["type"] = "room_request";
    board["chip_id"] = chip;
    board["edt"] = "microcontroller";
    board["room"] = 1;
    ble_send_json(JSON.stringify(board));
    Serial.println("[ble] state requested");
  }
}

static void usb_config_loop() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    // Do not echo serial input: a JAWNCFG line carries WiFi credentials and the
    // device authorization, and the manager reads this port back. The boot log
    // is still printed by Serial.println as before.
    if (c == '\n') {
      String line = usb_config_line;
      usb_config_line = "";
      line.trim();
      if (line == "JAWNCFG?") {
        // A field diagnostic: what the board actually reads back from its own
        // config file, with the secrets redacted. It answers on USB, so a board
        // that is off the network can still be inspected.
        JSONVar out = config;
        out["password"] = "***";
        out["ap_password"] = "***";
        out["authorization"] = "***";
        if (out["__specs"]) { out["__specs"]["authorization"] = "***"; }
        Serial.println("JAWNCFG STATE " + JSON.stringify(out));
        File cf = LittleFS.open("config.txt", "r");
        String raw = cf.readString();
        cf.close();
        Serial.println("JAWNCFG RAW " + String(raw.length()) + " bytes");
        JSONVar rawj = JSON.parse(raw);
        JSONVar rk = rawj.keys();
        String types;
        for (int i = 0; i < rk.length(); i++) {
          String k = String(rk[i]);
          if (k == "password" || k == "ap_password" || k == "authorization") { types += k + ":redacted "; }
          else { types += k + ":" + JSON.typeof(rawj[rk[i]]) + " "; }
        }
        Serial.println("JAWNCFG TYPES " + types);
        Serial.println("JAWNCFG MORE ssid=" + ssid + " ap_ssid=" + ap_ssid + " wifi=" + wifiState + " ip=" + WiFi.localIP().toString() + " homebaseIP=" + homebaseIP);
        Serial.println("JAWNCFG EVENTS " + event_ring_dump());
      }
      else if (line == "JAWNREBOOT") {
        Serial.println("JAWNCFG REBOOT");
        usb_reboot_pending = true;
        usb_reboot_at = millis() + 300;
      }
      else if (line.startsWith("JAWNCFG ")) {
        String json = line.substring(8);
        JSONVar incoming = JSON.parse(json);
        if (JSON.typeof(incoming) == "object") {
          // A USB provision carries WiFi and the token, not the role. Keep the
          // existing relays/switches so rejoining does not leave the board with
          // dead pins until the next BLE or /watch push.
          JSONVar prior = config;
          config = incoming;
          const char *keep_keys[] = { "relay", "led", "button", "switch", "pot", "servo", "outputs", "internal_jobs", "houses", "__specs" };
          for (size_t ki = 0; ki < sizeof(keep_keys) / sizeof(keep_keys[0]); ki++) {
            if (cfg_missing(config[keep_keys[ki]]) && !cfg_missing(prior[keep_keys[ki]])) {
              config[keep_keys[ki]] = prior[keep_keys[ki]];
            }
          }
          // The file is the source of truth now: set the live identity from it.
          // The role is not written here; it comes back over BLE (board_config)
          // or from /watch once the network is up. This keeps the USB line small
          // enough that the CDC receive ring cannot truncate it.
          homebaseIP = jstr(config["homebaseIP"]);
          homebase = jstr(config["homebase"]);
          authorization = jstr(config["authorization"]);
          offset = jint(config["offset"]);
          int64_t ts = jint(config["timestamp"]);
          if (!config_writer()) {
            Serial.println("JAWNCFG ERR write failed");
            return;
          }
          config_init();
          if (ts > 0) { set_epoch_seconds(ts + offset); }
          Serial.println("JAWNCFG OK");
          usb_reboot_pending = true;
          usb_reboot_at = millis() + 700;
        }
        else {
          Serial.println("JAWNCFG ERR bad json");
        }
      }
    }
    else if (c != '\r') {
      if (usb_config_line.length() < 16384) { usb_config_line += c; }
    }
  }
  if (usb_reboot_pending && (long)(millis() - usb_reboot_at) >= 0) {
    rp2040.reboot();
  }
}

static void ble_nus_handler(uint8_t packet_type, uint16_t channel, uint8_t *packet, uint16_t size) {
  (void)channel;
  if (packet_type == RFCOMM_DATA_PACKET) {
    for (uint16_t i = 0; i < size; i++) { ble_rx_queue.write(packet[i]); }
    ble_rx_queue.write(0x1E);  // one notification = one framed part
    return;
  }
  if (packet_type != HCI_EVENT_PACKET) { return; }
  if (hci_event_packet_get_type(packet) != HCI_EVENT_GATTSERVICE_META) { return; }
  switch (hci_event_gattservice_meta_get_subevent_code(packet)) {
    case GATTSERVICE_SUBEVENT_SPP_SERVICE_CONNECTED:
      ble_con_handle = gattservice_subevent_spp_service_connected_get_con_handle(packet);
      ble_notify_enabled = true;
      ble_up = true;
      ble_connected_at = millis();
      ble_state_requested = false;
      ble_rx_queue.reset();
      ble_tx_queue.reset();
      ble_rx_parts.clear();
      ble_rx_total = 0;
      Serial.println("[ble] connected");
      break;
    case GATTSERVICE_SUBEVENT_SPP_SERVICE_DISCONNECTED:
      ble_notify_enabled = false;
      ble_up = false;
      ble_con_handle = HCI_CON_HANDLE_INVALID;
      ble_state_requested = false;
      ble_rx_queue.reset();
      ble_tx_queue.reset();
      ble_rx_parts.clear();
      ble_rx_total = 0;
      Serial.println("[ble] disconnected");
      break;
    default:
      break;
  }
}

static void ble_start() {
  if (ble_started) { return; }
  ble_started = true;
  BluetoothLock lock;
  l2cap_init();
  sm_init();
  att_db_util_init();
  att_db_util_add_service_uuid128(ble_nus_service);
  att_db_util_add_characteristic_uuid128(ble_nus_rx,
    ATT_PROPERTY_WRITE | ATT_PROPERTY_WRITE_WITHOUT_RESPONSE | ATT_PROPERTY_DYNAMIC,
    ATT_SECURITY_NONE, ATT_SECURITY_NONE, nullptr, 0);
  att_db_util_add_characteristic_uuid128(ble_nus_tx,
    ATT_PROPERTY_NOTIFY | ATT_PROPERTY_DYNAMIC,
    ATT_SECURITY_NONE, ATT_SECURITY_NONE, nullptr, 0);
  att_server_init(att_db_util_get_address(), nullptr, nullptr);
  nordic_spp_service_server_init(&ble_nus_handler);
  ble_build_scan_response();
  bd_addr_t null_addr = {0};
  gap_advertisements_set_params(0x30, 0x30, 0, 0, null_addr, 0x07, 0x00);
  gap_advertisements_set_data(sizeof(ble_adv), (uint8_t *)ble_adv);
  gap_scan_response_set_data(ble_scan_rsp_len, ble_scan_rsp);
  gap_advertisements_enable(1);
  hci_power_control(HCI_POWER_ON);
  Serial.println("[ble] advertising as JawnPico");
}

void setup1() {
  // Do NOT call Serial.begin() here: core 1 starts alongside setup() on core 0,
  // and two concurrent USB initialisations wedge the CDC (the host then sees
  // the port but reads nothing until a replug). Core 0 owns the USB stack.
}

void jawn_setup() {
  Serial.begin(115200);
  delay(200);
  pinMode(led, OUTPUT);
  digitalWrite(led,HIGH);
  delay(200);
  LittleFS.begin();
  // The OTA shim has programmed the staged image before this application runs;
  // keep its space for the next upload instead of carrying a stale copy.
  LittleFS.remove("/alarmclock.bin");
  pinMode(0, OUTPUT);

  digitalWrite(0, HIGH);

  File f = LittleFS.open("config.txt", "r");
  String jconfig = f.readString();
  f.close();
  // Never print the file itself: it carries the WiFi password and the device
  // token. The length is enough to see whether a restore actually persisted.
  Serial.println("[cfg] boot read " + String(jconfig.length()) + " bytes");
  config = JSON.parse(jconfig);
  if (JSON.typeof(config) != "object") { config = JSON.parse("{}"); }
  config_init();
  Serial.println();
  Serial.println();
  Serial.print("Connecting to ");
  Serial.println(ssid);

  wifi_start();
  ble_start();


  server.on("/", []() {
    String html = R"(
      <!DOCTYPE html>
      <html>
        <title>Pico 2W Initial Config</title>
        <body style="text-align:center;position:fixed;top: 50%;left: 50%; transform: translate(-50%, -50%);">
          <form action="/initial_config" id="form" method="POST">
            <h1>Pico 2W</h1>
            <h4>Wifi SSID</h4>
            <input name="wifi_ssid">
            <h4>Wifi Password</h4>
            <input name="wifi_password" type="password">
            <h4>AP SSID</h4>
            <input name="ap_ssid">
            <h4>AP Password</h4>
            <input name="ap_password" type="password">
            <br><br>
            <button type="submit" id="submit">Submit</button>
            <br><br>
            <div id="log"></div>
          </form>
        </body>
        <style>
          input { text-align:left; height: 28px; font-size: 20px; border-width: 1px; border: solid; border-radius: 5px; }	
          button { text-align:center; height: 34px; min-width: 30px; font-size: 20px; border-width: 1px; border: solid; border-radius: 5px; }
        </style>
        <script>
          const form = document.getElementById('form');
          const log = document.getElementById('log');
          function formSubmitted() {
            log.textContent = "Form Submitted! Restarting Networks";
          }
          form.addEventListener('submit', formSubmitted);
        </script>
      </html>
    )";
    server.send(200, "text/html", html);
  });
  server.on("/initial_config", []() {
    String rauth = server.arg("authorization");
    if (authorization.length() > 0 && rauth != authorization) {
      server.send(403, "text/plain", "no");
      return;
    }
    String t_ssid = server.arg("wifi_ssid");
    String t_password = server.arg("wifi_password");
    String t_ap_ssid = server.arg("ap_ssid");
    String t_ap_password = server.arg("ap_password");
    if (t_ap_password != "" && t_ap_ssid != "") {
      // owned copies, persisted: the old c_str() assignments pointed at locals
      // that died with the request and were never written to config
      ap_password = t_ap_password;
      ap_ssid = t_ap_ssid;
      config["ap_password"] = ap_password;
      config["ap_ssid"] = ap_ssid;
      if (!config_writer()) { Serial.println("[cfg] ap pair not saved"); }
    }
    if (t_ssid != "" && t_password != "") {
      Serial.println("Saving SSID and Password");

      ssid = t_ssid;
      password = t_password;
      config["ssid"] = ssid;
      config["password"] = password;
      if (!config_writer()) { Serial.println("[cfg] wifi not saved"); }
      WiFi.disconnect();
      delay(400);
      wifi_start();
    }
    
    server.send(200, "text/html", "<h1>Success!</h1><a href='/'>Back</a>");
    

  });


  server.on("/device_query", []() {
    config["chip_id"] = rp2040.getChipID();
    config["purpose"] = "microcontroller";
    config["model"] = "Raspberry Pi Pico 2W";
    config["pins"] = "28";
    config["version"] = JAWN_FW_VERSION;
    JSONVar jonfig = config;
    // uptime is for the reply only, and as a string so JSONVar never mangles it.
    jonfig["uptime"] = String(millis());
    jonfig["ssid"] = undefined;
    jonfig["password"] = undefined;
    jonfig["ap_password"] = undefined;
    jonfig["ap_ssid"] = undefined;
    String gs = JSON.stringify(jonfig);
    server.send(200, "text/plain", gs);
    // Do not persist the diagnostics (uptime especially): this route used to
    // write them into config.txt on every query.
  });

  server.on("/jobs", []() {
    String auth = server.arg("authorization");
    if (authorization.length() > 0 && auth != authorization) {
      server.send(403, "text/plain", "no");
      return;
    }
    String jobs = JSON.stringify(config["jobs"]);
    Serial.println(jobs);
    server.send(200, "text/plain", jobs);

  });

  server.on("/now_me", []() {
    homebaseChecked();
    homebaseIP = server.arg("homebase");
    homebase = server.arg("ip");
    houseRememberPreferred(homebaseIP);
    houseLearnJson(server.arg("houses"));
    if (server.arg("houses") != "") { config["houses"] = server.arg("houses"); }
    config["authorization"] = server.arg("authorization");
    authorization = server.arg("authorization");
    config["name"] = server.arg("name");
    Serial.println(server.arg("name"));
    browser_tab_id = server.arg("browser_tab_id");
    Serial.println(config["name"]);
    // Read the epoch wide. String::toInt() is a 32-bit long, which wraps in
    // 2038; parsing as int64_t keeps the value honest even though time_t in
    // this core is still 32-bit.
    int64_t timestamp = strtoll(server.arg("timestamp").c_str(), nullptr, 10);
    config["timestamp"] = server.arg("timestamp");
    config["offset"] = server.arg("offset");
    offset = strtoll(server.arg("offset").c_str(), nullptr, 10);
    config["homebase"] = server.arg("ip");
    config["homebaseIP"] = server.arg("homebase");
    Serial.println("Homebase: " + homebase);
    Serial.println("homebase ip:" + homebaseIP);
    set_epoch_seconds(timestamp + offset);
    // Serial.println("Called President at " + homebaseIP);
    server.send(200, "text/plain", "homebase ip is now " + homebaseIP);
    config_writer();
    call_the_president();
  });
  server.on("/delete_job", []() {
    homebaseChecked();
    String appt_uuid = server.arg("appt_uuid");
    Serial.println("Querying " + appt_uuid);
    JSONVar jobKeys = config["jobs"].keys();
    int jlLength = jobKeys.length();
    for (int i = 0; i < jlLength; i++) {
      
      String app_uuid = config["jobs"][jobKeys[i]]["appt_uuid"];
      Serial.println("Testing " + app_uuid);
      if (appt_uuid == app_uuid) {
        Serial.println("deleting " + appt_uuid);
        String uuid = config["jobs"][jobKeys[i]]["uuid"];    
        config["jobs"][uuid] = undefined;
        jlLength--;
        Serial.println("Deleted " + uuid);
      }
    }
    config_writer();
    server.send(200, "text/plain", "ok");
  });
  server.on("/led", []() {
    homebaseChecked();
    String rauth = server.arg("authorization");
    if (authorization.length() > 0 && rauth != authorization) {
      server.send(403, "text/plain", "no");
      return;
    }
    String component = server.arg("component");
    String spin = server.arg("pin");
    int pin = server.arg("pin").toInt();
    String state = server.arg("state");
    String timestamp = server.arg("timestamp");
    String uuid = server.arg("uuid");
    String when = server.arg("when");
    String appt_uuid = server.arg("appt_uuid");
    if (when == "now") {
      // The manager's HTTP request and its BLE fallback can both deliver this
      // one command; the second must not click the pin again.
      int64_t ms = (int64_t)strtoll(server.arg("timestamp").c_str(), nullptr, 10);
      String comp = (component != "") ? component : String("led");
      String cid = command_id(uuid, comp, "", state, ms);
      if (!command_redundant(cid, pin, comp, state, ms)) {
        state = led_toggle(pin,state);
      }
      command_mark_pin(pin, ms);
      command_remember(cid, comp, "", ms);
    }
    else {
      push_job(component,pin,state,timestamp,uuid, appt_uuid);
    }
    JSONVar status;
    status["pin"] = pin;
    status["state"] = state;

    String jstatus = JSON.stringify(status);
    server.send(200, "text/plain", jstatus);
    config_writer();
    
  
  });
  server.on("/relay", []() {
    homebaseChecked();
    String rauth = server.arg("authorization");
    if (authorization.length() > 0 && rauth != authorization) {
      server.send(403, "text/plain", "no");
      return;
    }
    String component = server.arg("component");
    String spin = server.arg("pin");
    int pin = server.arg("pin").toInt();
    String state = server.arg("state");
    String timestamp = server.arg("timestamp");
    String when = server.arg("when");
    String uuid = server.arg("uuid");
    String appt_uuid = server.arg("appt_uuid");
    if (when == "now") {
      int64_t ms = (int64_t)strtoll(server.arg("timestamp").c_str(), nullptr, 10);
      String comp = (component != "") ? component : String("relay");
      String cid = command_id(uuid, comp, "", state, ms);
      if (!command_redundant(cid, pin, comp, state, ms)) {
        state = relay_toggle(pin,state,true,4);
      }
      command_mark_pin(pin, ms);
      command_remember(cid, comp, "", ms);
    }
    else {
      push_job(component,pin,state,timestamp,uuid, appt_uuid);
    }
    JSONVar status;
    status["pin"] = pin;
    status["state"] = state;

    String jstatus = JSON.stringify(status);
    server.send(200, "text/plain", jstatus);
  });
  server.on("/servo", []() {
    homebaseChecked();
    String rauth = server.arg("authorization");
    if (authorization.length() > 0 && rauth != authorization) {
      server.send(403, "text/plain", "no");
      return;
    }
    String component = server.arg("component");
    String spin = server.arg("pin");
    int pin = server.arg("pin").toInt();
    String state = String(server.arg("state"));
    String timestamp = server.arg("timestamp");
    String when = server.arg("when");
    String uuid = server.arg("uuid");
    String appt_uuid = server.arg("appt_uuid");
    Serial.println(component + " " + spin + " " + state);
    if (when == "now") {
      int64_t ms = (int64_t)strtoll(server.arg("timestamp").c_str(), nullptr, 10);
      String comp = (component != "") ? component : String("servo");
      String cid = command_id(uuid, comp, "", state, ms);
      if (!command_redundant(cid, pin, comp, state, ms)) {
        state = servo_toggle(pin,state);
      }
      command_mark_pin(pin, ms);
      command_remember(cid, comp, "", ms);
    }
    else {
      push_job(component,pin,state,timestamp,uuid, appt_uuid);
    }
    JSONVar status;
    status["pin"] = pin;
    status["state"] = state;

    String jstatus = JSON.stringify(status);
    server.send(200, "text/plain", jstatus);    
  });
  server.on("/wifi_update", []() {
    homebaseChecked();
    String req = "https://" + homebaseIP + "/manager/teletype/wifi_update?";
    String wifi_update = https_request(req);
    
    // An empty or unparsable answer must not look like a change to a blank
    // network: that cleared the saved pair, stopped the server and rebooted
    // into AP mode. Keep what we have unless the answer is an object with a
    // complete pair in it.
    JSONVar info = JSON.parse(wifi_update);
    if (JSON.typeof(info) != "object") {
      Serial.println("wifi_update: unreadable answer, keeping the current network");
      return;
    }
    String next_ssid = jstr(info["ssid"]);
    String next_password = jstr(info["password"]);
    if (next_ssid == "" || next_password == "") {
      Serial.println("wifi_update: no complete pair, keeping the current network");
      return;
    }
    if (ssid != next_ssid || password != next_password) {
      ssid = next_ssid;
      password = next_password;
      config["ssid"] = ssid;
      config["password"] = password;
      multi.clearAPList();
      server.stop();
      server.close();
      delay(400);
      
      multi.addAP(ssid.c_str(), password.c_str());
      if (multi.run() != WL_CONNECTED) {
        Serial.println("Unable to connect to network, rebooting in 10 seconds...");
        delay(10000);
        rp2040.reboot();
      }
      server.begin();

      Serial.println("WiFi connected");
      Serial.println("IP address: ");
      Serial.println(WiFi.localIP());
    }
  });
  
  // The raw upload path cannot see query arguments, so the OTA authorization
  // must arrive as a header; collect it before requests are handled. The
  // single-name form is the one this core's collectHeaders overloads accept
  // (the array form resolves to the variadic template and does not compile).
  server.collectHeaders("authorization");
  server.on(UriRegex("/upload/(.*)"), HTTP_POST, handleCreate, handleCreateProcess);
  server.begin();
  Serial.println("Server began");
  // for i2c variants, this must be called first.
  lcd.init();                      // initialize the lcd 
  lcd.backlight();
  lcd.setBacklight(1);
  // Print a message to the LCD.
  lcd.print(config["name"]);

}

// What this device is, advertised over mDNS: purpose, model and abilities.
#define JAWNOS_CAPS "lcd,led,relay,servo,button,switch,pot,pins,wifi"

static bool jawnos_mdns_up = false;
static void jawnos_mdns_start() {
  if (jawnos_mdns_up || WiFi.status() != WL_CONNECTED) { return; }
  String chip_id = String(rp2040.getChipID());
  String host = "jawn-" + chip_id;
  String dev_name = (const char *)config["name"];
  if (dev_name == "null" || dev_name == "") { dev_name = "Pico"; }
  if (!MDNS.begin(host.c_str())) {
    Serial.println("[mdns] begin failed");
    return;
  }
  hMDNSService svc = MDNS.addService("jawnos", "tcp", 3000);
  MDNS.addServiceTxt(svc, "chip_id", chip_id.c_str());
  MDNS.addServiceTxt(svc, "name", dev_name.c_str());
  MDNS.addServiceTxt(svc, "purpose", "microcontroller");
  MDNS.addServiceTxt(svc, "model", "Raspberry Pi Pico 2W");
  MDNS.addServiceTxt(svc, "caps", JAWNOS_CAPS);
  MDNS.addServiceTxt(svc, "port", "3000");
  jawnos_mdns_up = true;
  Serial.println("[mdns] jawnos._tcp up as " + host);
}

void wifi_start() {
  Serial.println("Attempting connection");
  WiFi.disconnect();
  WiFi.softAPdisconnect(true);
  delay(100);  
  WiFi.mode(WIFI_STA);
  // WiFiMulti keeps every AP it was ever given and tries them in order, so a
  // rejoin after a BLE apply could land on the network the user just replaced.
  // Only the configured pair may remain.
  multi.clearAPList();
  if (config["ssid"] != "" && config["password"] != "") {
    Serial.println("Got the goods");
    ssid = String((const char *)config["ssid"]);
    password = String((const char *)config["password"]);
    multi.addAP(ssid.c_str(), password.c_str());
  }
  if (multi.run() == WL_CONNECTED && config["ssid"] != "" && config["password"] != "") {
    server.begin();
    jawnos_mdns_start();
    Serial.println("WiFi connected");
    Serial.println("IP address: ");
    Serial.println(WiFi.localIP());    
    Serial.println("ok");
    wifiState = "connected";
    Serial.println(wifiState);
    // A board that rebooted after a crash (or a USB restore) should resume its
    // role without waiting for someone to press Now Me: fetch the room once the
    // network is up. The flag is cleared again on the next reconnect.
    president_loaded = false;
    // https_request refuses to run while homebaseOnline is 0, and it starts at
    // 0 on boot. Let the first role fetch through; a real failure sets it back
    // to 0, and homebasePing re-arms it for the next try.
    homebaseOnline = 1;
    coreJobs["connect"]["type"] = "led";
    coreJobs["connect"]["interval"] = "100";
    coreJobs["connect"]["duration"] = "500";
    if (authorization && homebaseIP) {
      String req = "https://" + homebaseIP + "/watch/time?";
      String timeRequest = https_request(req);
      String jobTime = String(millis());
      coreJobs[jobTime]["type"] = "https";
      coreJobs[jobTime]["url"] = req;
      coreJobs[jobTime]["response"] = "time";
    }
  }
  else {
    wifiState = "disconnected";
    Serial.println("no wifi connected");
    WiFi.mode(WIFI_AP);
    delay(100);
    if (WiFi.softAP(ap_ssid.c_str(), ap_password.c_str())) {

      Serial.print("Access Point successfully started. SSID: ");
      Serial.println(ap_ssid);
      Serial.print("AP IP Address: ");
      Serial.println(WiFi.softAPIP());

    } else {
      Serial.println("Failed to initialize Access Point.");
    }    
  }
}

