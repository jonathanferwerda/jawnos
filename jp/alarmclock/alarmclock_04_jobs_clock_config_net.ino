// The blocking half: core 1 only, no config document access.
void handle_jobs() {
  JSONVar coreKeys = coreJobs.keys();

  for (int i = 0; i < coreKeys.length(); i++) {
    if (String(coreJobs[coreKeys[i]]["type"]) == "led") {
      int interval = String(coreJobs[coreKeys[i]]["interval"]).toInt();
      int duration = String(coreJobs[coreKeys[i]]["duration"]).toInt();
      ledFlasher(interval,duration);
    }
    else if (String(coreJobs[coreKeys[i]]["type"]) == "https") {
      unsigned long job_at = strtoul(String(coreJobs[coreKeys[i]]["next_at"]).c_str(), nullptr, 10);
      if (job_at && (long)(millis() - job_at) < 0) { continue; }
      String job_response = String(coreJobs[coreKeys[i]]["response"]);
      bool critical = (job_response == "switch" || job_response == "button");
      // A switch or button is a person's movement. Do not let the 60 s ping gap
      // discard it: allow one attempt even while homebaseOnline is 0, and retry
      // a transient failure instead of dropping the job at the bottom of this
      // loop. That drop was the "every other flip" and the lost stop; waiting
      // for the ping to re-arm was the 25-second-old start time.
      if (critical) { homebaseOnline = 1; }
      String url = String(coreJobs[coreKeys[i]]["url"]);
      String response = https_request(url);
      bool failed = (response == "failure" || response == "no ping");

      if (job_response == "time" && !failed) {
        JSONVar timers = JSON.parse(response);

        int64_t timestamp = jint64(timers["timestamp"]);
        int64_t timestamp_ms = jint64(timers["timestamp_ms"]);
        int64_t offset_s = jint64(timers["offset"]);
        // A denial page or a dead homebase is not a clock. Applying an empty
        // answer used to set offset to INT64_MIN and every later switch event
        // carried a timestamp near -9.2e18. The millisecond copy keeps the
        // board's event stamps in the same sub-second frame as the manager's
        // commands; an older manager only sends seconds and is still accepted.
        if (timestamp_ms > 1600000000000 && timestamp_ms < 4102444800000 && offset_sane(offset_s)) {
          offset = offset_s;
          set_epoch_ms(timestamp_ms + offset_s * 1000LL);
        }
        else if (timestamp > 1600000000 && timestamp < 4102444800 && offset_sane(offset_s)) {
          // Keep the offset, not just the adjusted epoch: a switch/button event
          // must subtract it to send UTC, while the LCD keeps showing local time.
          offset = offset_s;
          set_epoch_seconds(timestamp + offset_s);
        }
      }

      // A transient failure (a TLS timeout, a homebase that just went quiet for
      // one request) keeps the job for a bounded retry. The event's timestamp
      // was stamped at the flip, so a retry still records the real moment.
      if (failed) {
        int tries = String(coreJobs[coreKeys[i]]["tries"]).toInt();
        if (tries < 4) {
          tries++;
          coreJobs[coreKeys[i]]["tries"] = String(tries);
          coreJobs[coreKeys[i]]["next_at"] = String((unsigned long)(millis() + 1500UL * tries));
          continue;
        }
      }
    }
    else if (String(coreJobs[coreKeys[i]]["type"]) == "relay_post") {
      // A watch/deck message the BLE handler queued. Run it here, off the BLE
      // and loop path, with the bounded retry the queue promised.
      unsigned long next_at = strtoul(String(coreJobs[coreKeys[i]]["next_at"]).c_str(), nullptr, 10);
      if ((long)(millis() - next_at) < 0) { continue; }   // not due yet; keep it
      String path = String(coreJobs[coreKeys[i]]["path"]);
      String body = String(coreJobs[coreKeys[i]]["body"]);
      String kind = String(coreJobs[coreKeys[i]]["kind"]);
      int tries = String(coreJobs[coreKeys[i]]["tries"]).toInt();
      String answer;
      int code = https_post(path, body, answer);
      if (code == HTTP_CODE_OK) {
        Serial.println("[relay] delivered " + path);
        // Hand the manager's small result back over the same BLE link, so the
        // watch can show that the house heard the tap.
        if (kind == "volume" && answer.length() > 1 && answer.length() < 512) {
          String reply = "{\"type\":\"volume_result\",\"from\":\"" + String(rp2040.getChipID()) + "\",\"data\":" + answer + "}";
          ble_send_json(reply);
        }
        relay_out_pending--;
        if (relay_out_pending < 0) { relay_out_pending = 0; }
        coreJobs[coreKeys[i]] = undefined;
        continue;
      }
      tries++;
      if (tries >= 3) {
        Serial.println("[relay] gave up " + path + " code " + String(code));
        relay_out_pending--;
        if (relay_out_pending < 0) { relay_out_pending = 0; }
        coreJobs[coreKeys[i]] = undefined;
        continue;
      }
      coreJobs[coreKeys[i]]["tries"] = String(tries);
      coreJobs[coreKeys[i]]["next_at"] = String((unsigned long)(millis() + 2000UL * tries));
      continue;
    }
    else if (String(coreJobs[coreKeys[i]]["type"]) == "ir_post") {
      // The IR receiver's capture, posted to the house with the same
      // authorization and bounded retry as a switch/button event. This is a
      // POST, not a query string, because a 512-transition sequence is long.
      unsigned long next_at = strtoul(String(coreJobs[coreKeys[i]]["next_at"]).c_str(), nullptr, 10);
      if ((long)(millis() - next_at) < 0) { continue; }
      String path = String(coreJobs[coreKeys[i]]["path"]);
      String body = String(coreJobs[coreKeys[i]]["body"]);
      int tries = String(coreJobs[coreKeys[i]]["tries"]).toInt();
      String answer;
      int code = https_post(path, body, answer);
      if (code == HTTP_CODE_OK) {
        coreJobs[coreKeys[i]] = undefined;
        continue;
      }
      tries++;
      if (tries >= 3) {
        Serial.println("[ir] gave up " + path + " code " + String(code));
        coreJobs[coreKeys[i]] = undefined;
        continue;
      }
      coreJobs[coreKeys[i]]["tries"] = String(tries);
      coreJobs[coreKeys[i]]["next_at"] = String((unsigned long)(millis() + 2000UL * tries));
      continue;
    }
    coreJobs[coreKeys[i]] = undefined;
  }
}

uint32_t lastMillis;

// Days-from-epoch to a civil date, so the display works past 2038 without
// localtime_r()/32-bit time_t. The epoch we hold is already local seconds.
jawn_time break_epoch(int64_t seconds) {
  int64_t days = seconds / 86400;
  int64_t rem = seconds % 86400;
  if (rem < 0) { rem += 86400; days -= 1; }
  int64_t z = days + 719468;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = (unsigned)(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  int64_t y = (int64_t)yoe + era * 400;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;
  unsigned d = doy - (153 * mp + 2) / 5 + 1;
  unsigned m = mp + (mp < 10 ? 3 : -9);
  y += (m <= 2);
  jawn_time t;
  t.year = (int)y;
  t.month = (int)m;
  t.day = (int)d;
  t.hour = (int)(rem / 3600);
  t.min = (int)((rem % 3600) / 60);
  t.sec = (int)(rem % 60);
  return t;
}

void read_time() {
  if ((uint32_t)(millis() - lastMillis) >= 1000) {
    lastMillis = millis();
    if (!time_defined) { return; }
    int64_t secs = now_ms() / 1000;
    jawn_time t = break_epoch(secs);
    static const char *mon[] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    static const char *dow[] = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    int64_t days = secs / 86400;
    if (secs < 0 && secs % 86400) { days -= 1; }
    int wd = (int)((days + 4) % 7);   // 1970-01-01 was a Thursday
    if (wd < 0) { wd += 7; }
    char buffdate[80];
    char bufftime[80];
    snprintf(buffdate, sizeof(buffdate), "%s %s %02d %d", dow[wd], mon[t.month - 1], t.day, t.year);
    snprintf(bufftime, sizeof(bufftime), "%02d:%02d:%02d", t.hour, t.min, t.sec);
    String timing = (const char *)buffdate;
    lcd.setCursor(0,0);
    lcd.print(timing);
    lcd.setCursor(0,1);
    String timings = (const char *)bufftime;
    lcd.print(timings);
  }
}

// The writer's body. Every caller is on core 0 now (see the note at the top of
// the local map), so there is no concurrent writer to serialize.
bool config_writer() {
  config_ensure();
  String jconfig = JSON.stringify(config);
  // Replace, do not overwrite in place: LittleFS's "w" was leaving the old
  // tail behind, so a short (cleared) config still read back as the previous
  // long file and JSON.parse saw the stale object.
  LittleFS.remove("config.txt");
  File f = LittleFS.open("config.txt", "w");
  if (!f) {
    Serial.println("[cfg] write open failed");
    return false;
  }
  f.truncate(0);
  size_t wrote = f.print(jconfig);
  f.close();
  if (wrote != jconfig.length()) {
    Serial.println("[cfg] short write " + String((unsigned long)wrote) + "/" + String((unsigned long)jconfig.length()));
    return false;
  }
  return true;
}

static void local_jobs_load() {
  local_in_count = 0;
  String ij_s = jstr(config["internal_jobs"]);
  JSONVar ij = JSON.parse(ij_s);
  bool have_jobs = (JSON.typeof(ij) == "object");
  // Every switch/button in the role is an input, whether or not this board
  // drives an output from it: a switch wired only to another board's relay
  // still has to report its movement. internal_jobs adds the local outputs on
  // top. Reading the inputs from the role (not from internal_jobs) is what
  // makes one scanner enough, and one scanner is what stops every event
  // arriving twice.
  const char *in_keys[] = { "switch", "button" };
  for (int c = 0; c < 2; c++) {
    bool is_sw = String(in_keys[c]) == "switch";
    JSONVar keys = config[in_keys[c]].keys();
    for (int i = 0; i < keys.length() && local_in_count < LOCAL_IN_MAX; i++) {
      int pin = String((const char *)keys[i]).toInt();
      if (!pin_ok(pin)) { continue; }
      String name = jstr(config[in_keys[c]][keys[i]]["name"]);
      if (name == "") { name = String(in_keys[c]) + String(pin); }
      local_in_t &in = local_ins[local_in_count++];
      in.pin = pin;
      in.is_switch = is_sw;
      in.inverted = (jstr(config[in_keys[c]][keys[i]]["inverted"]) == "1") ? 1 : 0;
      in.name = name;
      in.out_n = 0;
      input_begin(pin);
      // Adopt the level present now. A role reload or reboot must not look
      // like a press, and a button already held must not fire on boot.
      int level = digitalRead(pin);
      local_sw_state[pin] = level;
      local_sw_seen[pin] = true;
      local_btn_pressed[pin] = (level ^ in.inverted) ? 1 : 0;
      if (have_jobs) {
        JSONVar jobs = ij[name];
        for (int j = 0; j < jobs.length() && in.out_n < LOCAL_OUT_MAX; j++) {
          String comp = jstr(jobs[j]["component"]);
          int op = jpin(jobs[j]["numero"]);
          int inv = (int)jint(jobs[j]["inverted"]);
          if (!pin_ok(op)) { continue; }
          if (comp != "relay" && comp != "led") { continue; }
          // Do not drive the output here. It is restored from config["relay"]
          // / config["led"] in config_init(); driving it from this map used to
          // click the relay on every role push.
          in.out_pin[in.out_n] = op;
          in.out_inv[in.out_n] = inv;
          in.out_comp[in.out_n] = comp;
          in.out_n++;
        }
      }
    }
  }
  local_outputs_load();
}

void config_init() {
  config_ensure();
  local_jobs_load();
  Serial.println("Config init");
  JSONVar relayKeys = config["relay"].keys();
  for (int i = 0; i < relayKeys.length(); i++) {
    Serial.print(relayKeys[i]);
    Serial.println(config["relay"][relayKeys[i]]);
    String state = config["relay"][relayKeys[i]];
    String spin = relayKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    pinMode(pin, OUTPUT);

    if (state == "on") {  
      digitalWrite(pin, HIGH);
    }
    else {
      digitalWrite(pin,LOW);
    }
  }
  JSONVar ledKeys = config["led"].keys();
  for (int i = 0; i < ledKeys.length(); i++) {
    Serial.print(relayKeys[i]);
    Serial.println(config["led"][ledKeys[i]]);
    String state = config["led"][ledKeys[i]];
    String spin = ledKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    pinMode(pin, OUTPUT);    
    if (state == "on") {
      digitalWrite(pin, HIGH);
    }
    else {
      digitalWrite(pin, LOW);
    }
  }
  JSONVar buttonKeys = config["button"].keys();
  for (int i = 0; i < buttonKeys.length(); i++) {
    Serial.print(buttonKeys[i]);
    Serial.println(config["button"][buttonKeys[i]]);
    String toggle = config["button"][buttonKeys[i]]["toggle"];
    config["button"][buttonKeys[i]]["lastPress"] = String(millis());
    String spin = buttonKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    input_begin(pin);
    // Remember the level we booted at. Otherwise the first scan sees a
    // difference from the stored value and treats it as a press.
    config["button"][spin]["pressed"] = (digitalRead(pin) == HIGH) ? "yes" : "no";
  }
  JSONVar switchKeys = config["switch"].keys();
  for (int i = 0; i < switchKeys.length(); i++) {
    config["switch"][switchKeys[i]]["lastChange"] = String(millis());
    config["switch"][switchKeys[i]]["lastSend"] = String(millis());
    String spin = switchKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }

    input_begin(pin);
    // Adopt the level present at boot: a reboot must not look like the switch
    // just changed and fire its internal job at the relay. The stored state is
    // written in the same logical sense the scanner uses (active-low honoured).
    int sinv = (jstr(config["switch"][spin]["inverted"]) == "1") ? 1 : 0;
    config["switch"][spin]["state"] = ((digitalRead(pin) ^ sinv) ? "on" : "off");
  }
  // The switch is the authority for the outputs it is wired to. Apply it after
  // the app-derived relay restore above, so a reboot with the switch on leaves
  // the relay on instead of flashing it to the app's stale state.
  local_inputs_apply_all();
  JSONVar potKeys = config["pot"].keys();
  for (int i = 0; i < potKeys.length(); i++) {
    config["pot"][potKeys[i]]["lastMove"] = String(millis());
    config["pot"][potKeys[i]]["lastSend"] = String(millis());

    String spin = potKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
  //  pinMode(pin, INPUT);
  }


  JSONVar servoKeys = config["servo"].keys();
  for (int i = 0; i < servoKeys.length(); i++) {
    Serial.print(servoKeys[i]);
    Serial.println(config["servo"][servoKeys[i]]);
    String state = config["servo"][servoKeys[i]];
    String spin = servoKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    
    myservo.attach(pin);
  }
  // The IR pair are ordinary components: an emitter is an output held off
  // between frames, a receiver is an input held up.
  JSONVar irtxKeys = config["irtx"].keys();
  for (int i = 0; i < irtxKeys.length(); i++) {
    int pin = String(irtxKeys[i]).toInt();
    if (!pin_ok(pin)) { continue; }
    pinMode(pin, OUTPUT);
    digitalWrite(pin, LOW);
  }
  JSONVar irrxKeys = config["irrx"].keys();
  for (int i = 0; i < irrxKeys.length(); i++) {
    int pin = String(irrxKeys[i]).toInt();
    if (!pin_ok(pin)) { continue; }
    pinMode(pin, INPUT_PULLUP);
  }
  authorization = jstr(config["authorization"]);
  homebase = jstr(config["homebase"]);
  homebaseIP = jstr(config["homebaseIP"]);
  homebasePreferredIP = jstr(config["homebasePreferredIP"]);
  if (homebasePreferredIP == "") { homebasePreferredIP = homebaseIP; }
  houseLearnJson(jstr(config["houses"]));
  // JSONVar::operator bool() is true only for a JSON boolean, not for a
  // non-empty string. The old `if (config["ssid"] && config["password"])` was
  // therefore always false, so a board that rebooted read its saved WiFi (and
  // its saved AP credentials) but never used them and came up in the default
  // provisioning AP. Compare against the empty string instead.
  String saved_ssid = jstr(config["ssid"]);
  String saved_password = jstr(config["password"]);
  if (saved_ssid != "" && saved_password != "") {
    ssid = saved_ssid;
    password = saved_password;
  }
  String saved_ap_ssid = jstr(config["ap_ssid"]);
  String saved_ap_password = jstr(config["ap_password"]);
  if (saved_ap_ssid != "" && saved_ap_password != "") {
    ap_ssid = saved_ap_ssid;
    ap_password = saved_ap_password;
  }

/*    

  String tstamp = String(config["timestamp"]);
  long timestamp = tstamp.toInt();
  timestamp = timestamp - (60 * 9) + 4;
  String oset = String(config["offset"]);
  long offset = oset.toInt();
  Serial.print("time setting ");
  Serial.print(tstamp);
  Serial.print(" ");
  Serial.println(timestamp);
  struct timeval tv;
  tv.tv_sec = (timestamp + offset);
  settimeofday(&tv,nullptr);
*/
}

String url_maker(String url) {
  String chip_id = rp2040.getChipID();
  url = url + "&edt=microcontroller&chip_id=" + chip_id + "&authorization=" + authorization;
  return url;
}

String https_request(String url) {
  
  if (homebaseOnline == 0) {
    return "no ping";
  }
  url = url_maker(url);
  connexion -> setInsecure();
  if (connexion && homebaseOnline > 0) {
    {
      if (https.begin(*connexion, url)) {
        https.setTimeout(8000);
        int httpCode = https.GET();
        if (httpCode > 0) {

          if (httpCode == HTTP_CODE_OK) {
            homebaseOnline = millis();
            String payload = https.getString();
            return payload;
          }
        }
        else {
          Serial.printf("HTTPS FAILED error: %s\n", https.errorToString(httpCode).c_str());
          // Close the client before returning. `connexion` is one global
          // WiFiClientSecure shared by every request; a failed GET left it
          // half-open, and every later begin() reused that stale socket and
          // failed with "connection failed" until the board rebooted. That is
          // why one WiFi blip turned into minutes of silence from a link that
          // was up again.
          https.end();
          connexion->stop();
          homebaseOnline = 0;
          return "failure";
        }
        https.end();
      }
    }
  }
  homebaseOnline = 0;
  return "failure";
}

// POST a small JSON body to the house and return the HTTP status (or -1). Same
// client and authorization as https_request: url_maker appends the Now Me pair
// the manager's embedded_authorizer reads, so the relay introduces no second
// auth scheme. The answer is handed back for the volume result the watch uses.
int https_post(const String &path, const String &body, String &answer) {
  if (homebaseOnline == 0 || homebaseIP == "") { return -1; }
  String url = url_maker("https://" + homebaseIP + path + "?");
  connexion -> setInsecure();
  if (!connexion || !https.begin(*connexion, url)) {
    homebaseOnline = 0;
    return -1;
  }
  https.setTimeout(6000);
  https.addHeader("Content-Type", "application/json");
  int httpCode = https.POST(body);
  if (httpCode > 0) {
    homebaseOnline = millis();
    if (httpCode == HTTP_CODE_OK) { answer = https.getString(); }
  }
  else {
    Serial.printf("HTTPS POST FAILED error: %s\n", https.errorToString(httpCode).c_str());
    homebaseOnline = 0;
  }
  https.end();
  return httpCode;
}

void call_the_president() {
  //  Serial.println("dans presidente");
  //  Serial.println(before_me);
  //  Serial.println("copy");
  JSONVar result;
  Serial.print("bb: " );
  if (homebaseIP != "") {
    String req = "https://" + homebaseIP + "/watch?room=1&browser_tab_id=" + browser_tab_id;
    Serial.println(req);
    String watchRequest = https_request(req);
    // Never print the payload: it carries the device authorization token.
    Serial.println("[watch] " + String(watchRequest.length()) + " bytes");
    if (watchRequest != "failure") {
      before_me = watchRequest;
      if (before_me != "No!") {
        // A refusal is a template answered 200 with a huge body. Parsing and
        // applying it never sets president_loaded, so it was retried every
        // ten seconds (and on core 0 starved the switch loop). Reject it here.
        if (before_me.length() > 64000 || before_me.indexOf("__specs") < 0) {
          Serial.println("[watch] answer carries no role; retrying later");
          return;
        }
        JSONVar ctp = JSON.parse(before_me);
        JSONVar ctpKeys = ctp.keys();
        bool has_components = false;
        int found_components = 0;
        for (int i = 0; i < ctpKeys.length(); i++) {
          String k = String(ctpKeys[i]);
          if (!k.startsWith("__")) { has_components = true; found_components++; }
        }
        int expected_components = (int)jint(ctp["__specs"]["component_count"]);
        if (!has_components || (expected_components > 0 && found_components < expected_components)) {
          Serial.println("[watch] incomplete role; keeping the current one");
          return;
        }
        config["button"] = JSON.parse("{}");
        config["pot"] = JSON.parse("{}");
        config["led"] = JSON.parse("{}");
        config["servo"] = JSON.parse("{}");
        config["relay"] = JSON.parse("{}");
        config["switch"] = JSON.parse("{}");
        config["outputs_json"] = local_outputs_build(ctp);
        config["internal_jobs"] = "";
        for (int i = 0; i < ctpKeys.length(); i++) {
          // The role carries numero as a string; a numeric JSONVar value would
          // read back as 0 and map every component onto pin 0.
          String numero = jstr(ctp[ctpKeys[i]]["numero"]);
          if (numero == "") { numero = String((long)jint(ctp[ctpKeys[i]]["numero"])); }
          String component = jstr(ctp[ctpKeys[i]]["component"]);
          String name = String(ctpKeys[i]);
          int pin = numero.toInt();
          if (!pin_ok(pin)) { continue; }
          if (component == "button") {
            String toggle = String((long)jint(ctp[ctpKeys[i]]["toggle"]));
            config["button"][numero]["lastPress"] = String(millis());
            config["button"][numero]["toggle"] = toggle;
            config["button"][numero]["name"] = name;
            config["button"][numero]["inverted"] = jstr(ctp[ctpKeys[i]]["inverted"]);
            {
              String bInv = jstr(ctp[ctpKeys[i]]["inverted"]);
              if (bInv != "0" && bInv != "1") { bInv = jint(ctp[ctpKeys[i]]["inverted"]) ? "1" : "0"; }
              config["button"][numero]["inverted"] = bInv;
            }
            input_begin(pin);

          }
          else if (component == "pot") {
            config["pot"][numero]["lastMove"] = String(millis());
            config["pot"][numero]["lastSend"] = String(millis());
            config["pot"][numero]["name"] = name;
          //  pinMode(pin, INPUT);
          }
          else if (component == "switch") {
            config["switch"][numero]["lastChange"] = String(millis());
            config["switch"][numero]["lastSend"] = String(millis());
            config["switch"][numero]["name"] = name;
            config["switch"][numero]["inverted"] = jstr(ctp[ctpKeys[i]]["inverted"]);
            {
              String cInv = jstr(ctp[ctpKeys[i]]["inverted"]);
              if (cInv != "0" && cInv != "1") { cInv = jint(ctp[ctpKeys[i]]["inverted"]) ? "1" : "0"; }
              config["switch"][numero]["inverted"] = cInv;
            }
            input_begin(pin);
          }
          else if (component == "relay" || component == "led" || component == "servo") {
            String toggle = String((long)jint(ctp[ctpKeys[i]]["toggle"]));
            String inverted = jstr(ctp[ctpKeys[i]]["inverted"]);
            String state = (toggle == "1") ? "on" : "off";
            if (component == "servo") { state = toggle; }
            else if (inverted == "1") { state = (state == "on") ? "off" : "on"; }
            if (component == "relay") { config["relay"][numero] = state; }
            else if (component == "led") { config["led"][numero] = state; }
            else { config["servo"][numero] = state; }
            pinMode(pin, OUTPUT);
          }
          else if (name == "__specs") {
            String ij = JSON.stringify(ctp[ctpKeys[i]]["internal_jobs"]);
            config["internal_jobs"] = ij;
            Serial.println("internal jobs loaded");
          }
          Serial.println(name);
        }
        president_loaded = true;
      }
      // The role was built on core 1; the config document and the local pin map
      // belong to core 0. Mark both and let loop() do the write and the reload,
      // so a blocking fetch never races the switch scanner here.
      config_dirty = true;
      config_dirty_at = millis();
      config_reload_pending = true;
      coreJobs["president"]["type"] = "led";
      coreJobs["president"]["interval"] = "50";
      coreJobs["president"]["duration"] = "1000";

    }
  }

  //Serial.println(before_me);
}
