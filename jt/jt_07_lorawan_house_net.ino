// ---- LoRaWAN ---------------------------------------------------------------

String lorawanCleanHex(String value) {
  String out = "";
  for (size_t i = 0; i < value.length(); i++) {
    char c = value[i];
    if (c >= '0' && c <= '9') { out += c; }
    else if (c >= 'a' && c <= 'f') { out += (char)(c - 32); }
    else if (c >= 'A' && c <= 'F') { out += c; }
  }
  return out;
}

int lorawanNibble(char c) {
  if (c >= '0' && c <= '9') { return c - '0'; }
  if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
  if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
  return 0;
}

uint64_t lorawanEui(const String& hex) {
  uint64_t value = 0;
  for (int i = 0; i < 16 && i < (int)hex.length(); i++) {
    value = (value << 4) | (uint64_t)lorawanNibble(hex[i]);
  }
  return value;
}

bool lorawanKey(const String& hex, uint8_t *out) {
  if (hex.length() != 32 || out == NULL) { return false; }
  for (int i = 0; i < 16; i++) {
    out[i] = (uint8_t)((lorawanNibble(hex[i * 2]) << 4) | lorawanNibble(hex[i * 2 + 1]));
  }
  return true;
}

const LoRaWANBand_t* lorawanBandFor(const String& band) {
  if (band == "EU868") { return &EU868; }
  if (band == "US915") { return &US915; }
  if (band == "AU915") { return &AU915; }
  if (band == "AS923") { return &AS923; }
  if (band == "AS923_2") { return &AS923_2; }
  if (band == "AS923_3") { return &AS923_3; }
  if (band == "AS923_4") { return &AS923_4; }
  if (band == "KR920") { return &KR920; }
  if (band == "IN865") { return &IN865; }
  if (band == "CN470") { return &CN470; }
  return &EU433;
}

void lorawanBegin() {
  lorawan_last_error = "";
  if (!lorawan_enabled) { return; }
  if (!hasRadio) { lorawan_last_error = "no radio"; return; }
  String join = lorawanCleanHex(lorawan_join_eui);
  String dev = lorawanCleanHex(lorawan_dev_eui);
  String key = lorawanCleanHex(lorawan_app_key);
  if (join.length() != 16 || dev.length() != 16 || key.length() != 32) {
    lorawan_last_error = "credentials incomplete";
    return;
  }
  uint8_t appKey[16];
  if (!lorawanKey(key, appKey)) {
    lorawan_last_error = "bad app key";
    return;
  }
  if (lorawanNode != nullptr) {
    delete lorawanNode;
    lorawanNode = nullptr;
  }
  lorawanNode = new LoRaWANNode(&radio, lorawanBandFor(lorawan_band), lorawan_subband ? lorawan_subband : 1);
  // NULL nwkKey selects LoRaWAN 1.0.x, where the AppKey derives both keys.
  int16_t state = lorawanNode->beginOTAA(lorawanEui(join), lorawanEui(dev), NULL, appKey);
  if (state != RADIOLIB_ERR_NONE) {
    lorawan_last_error = "begin failed " + String(state);
    delete lorawanNode;
    lorawanNode = nullptr;
    return;
  }
  lorawanNode->setDutyCycle(true);
  lorawanNode->setADR(true);
  deckLog("[lorawan] ready band=%s sub=%u", lorawan_band.c_str(), (unsigned)lorawan_subband);
}

int16_t lorawanJoin() {
  if (!lorawan_enabled) {
    lorawan_last_error = "LoRaWAN is off";
    return RADIOLIB_ERR_NETWORK_NOT_JOINED;
  }
  if (lorawanNode == nullptr) { lorawanBegin(); }
  if (lorawanNode == nullptr) { return RADIOLIB_ERR_NETWORK_NOT_JOINED; }
  int16_t state = lorawanNode->activateOTAA();
  if (state == RADIOLIB_ERR_NONE || state == RADIOLIB_LORAWAN_SESSION_RESTORED) {
    lorawan_last_error = "";
    deckLog("[lorawan] joined");
    return RADIOLIB_ERR_NONE;
  }
  lorawan_last_error = "join failed " + String(state);
  deckLog("[lorawan] %s", lorawan_last_error.c_str());
  return state;
}

int16_t lorawanSend(const String& text, bool confirmed) {
  int16_t state = lorawanJoin();
  if (state != RADIOLIB_ERR_NONE) { return state; }
  if (lorawanNode == nullptr) { return RADIOLIB_ERR_NETWORK_NOT_JOINED; }
  uint8_t maxLen = lorawanNode->getMaxPayloadLen();
  if (maxLen < 8) { maxLen = 8; }
  int total = (int)text.length();
  int offset = 0;
  while (offset < total) {
    int cut = offset + (int)maxLen;
    if (cut > total) { cut = total; }
    // do not split a UTF-8 character across two uplinks
    while (cut > offset && cut < total && (((uint8_t)text[cut]) & 0xC0) == 0x80) { cut--; }
    if (cut <= offset) { cut = offset + (int)maxLen; if (cut > total) { cut = total; } }
    String chunk = text.substring(offset, cut);
    String down = "";
    LoRaWANEvent_t eventDown;
    state = lorawanNode->sendReceive(chunk, lorawan_fport ? lorawan_fport : 1, down, confirmed, NULL, &eventDown);
    if (state < RADIOLIB_ERR_NONE) {
      lorawan_last_error = "send failed " + String(state);
      deckLog("[lorawan] %s", lorawan_last_error.c_str());
      return state;
    }
    if (state > 0 && down.length()) {
      lorawan_last_rssi = eventDown.power;
      if (authorization != "") {
        String request = "https://" + homebaseIP + "/watch/chat_received?message=" + urlEncode(down)
                         + "&username=" + urlEncode(computer_name)
                         + "&transport=lorawan&contact=lora";
        https_request(request);
      }
    }
    offset = cut;
  }
  lorawan_last_error = "";
  return RADIOLIB_ERR_NONE;
}

String lorawanStatusJson() {
  JSONVar st;
  st["enabled"] = lorawan_enabled ? "on" : "off";
  st["band"] = lorawan_band;
  st["subband"] = lorawan_subband;
  st["fport"] = lorawan_fport;
  st["confirmed"] = lorawan_confirmed ? "on" : "off";
  st["has_key"] = lorawan_app_key.length() ? "yes" : "no";
  st["joined"] = (lorawanNode != nullptr && lorawanNode->isActivated()) ? "yes" : "no";
  st["error"] = lorawan_last_error;
  st["rssi"] = lorawan_last_rssi;
  st["max_payload"] = 0;
  if (lorawanNode != nullptr && lorawanNode->isActivated()) {
    st["max_payload"] = lorawanNode->getMaxPayloadLen();
  }
  return JSON.stringify(st);
}

// The input half of the chat and pen rooms: a scrolling log on top and a one
// line textarea underneath, focused in the keypad group so the keyboard types
// straight into it. LVGL fires LV_EVENT_READY when Enter is pressed.
static void roomInputSend(lv_event_t *e) {
  lv_obj_t *ta = lv_event_get_target_obj(e);
  String text = String(lv_textarea_get_text(ta));
  lv_textarea_set_text(ta, "");
  if (text.length() == 0) {
    return;
  }
  long timestamp = rightNow();
  if (jw_room == "chat") {
    chat_text_writer(computer_name, text, timestamp);
    if (authorization != "") {
      String request = "https://" + homebaseIP + "/watch/chat_received?message=" + urlEncode(text)
                       + "&username=" + urlEncode(computer_name)
                       + "&community=" + urlEncode(community_room) + "&club=" + urlEncode(club_room)
                       + "&team=" + urlEncode(team_room) + "&account=" + urlEncode(account_room)
                       + "&project=" + urlEncode(project_room) + "&contact=" + urlEncode(contact_room)
                       + "&person=" + urlEncode(person_room);
      https_request(request);
    }
    loraChatBroadcast(computer_name, text, timestamp);
  }
  else if (jw_room == "pen") {
    chat_text_writer("Me", text, timestamp);
    if (authorization != "") {
      String request = "https://" + homebaseIP + "/teletype/pen?message=" + urlEncode(text)
                       + "&username=" + urlEncode(computer_name);
      String information = https_request(request);
      JSONVar info = JSON.parse(information);
      chat_text_writer("Pen", (const char *)info["message"], rightNow());
    }
  }
}

static void roomInputBuild(const char *placeholder, int logTop, int logHeight) {
  room_log_text = "";
  lv_obj_t *box = lv_obj_create(lv_scr_act());
  lv_obj_set_pos(box, 5, logTop);
  lv_obj_set_size(box, 310, logHeight);
  lv_obj_set_style_pad_all(box, 4, 0);
  lv_obj_set_style_radius(box, 0, 0);
  lv_obj_set_style_bg_color(box, lv_color_black(), 0);
  lv_obj_set_style_border_width(box, 1, 0);
  lv_obj_set_style_border_color(box, lv_color_hex(0x606060), 0);
  room_log = lv_label_create(box);
  lv_obj_set_width(room_log, 292);
  lv_label_set_long_mode(room_log, LV_LABEL_LONG_WRAP);
  lv_obj_set_style_text_color(room_log, lv_color_white(), 0);
  lv_label_set_text(room_log, "");

  room_input = lv_textarea_create(lv_scr_act());
  lv_obj_set_pos(room_input, 5, 158);
  lv_obj_set_size(room_input, 232, 36);
  lv_textarea_set_one_line(room_input, true);
  lv_textarea_set_placeholder_text(room_input, placeholder);
  lv_obj_add_event_cb(room_input, roomInputSend, LV_EVENT_READY, NULL);
  lv_group_t *group = lv_group_get_default();
  if (group) {
    lv_group_add_obj(group, room_input);
    lv_group_focus_obj(room_input);
  }

  // a voice note next to the text box: record (toggles) and play
  lv_obj_t *rec = lv_btn_create(lv_scr_act());
  lv_obj_set_pos(rec, 242, 158);
  lv_obj_set_size(rec, 36, 36);
  lv_obj_add_event_cb(rec, micRecordToggle, LV_EVENT_CLICKED, NULL);
  lv_obj_t *rec_label = lv_label_create(rec);
  lv_label_set_text(rec_label, "Rec");
  lv_obj_center(rec_label);

  lv_obj_t *play = lv_btn_create(lv_scr_act());
  lv_obj_set_pos(play, 282, 158);
  lv_obj_set_size(play, 33, 36);
  lv_obj_add_event_cb(play, recordingPlay, LV_EVENT_CLICKED, NULL);
  lv_obj_t *play_label = lv_label_create(play);
  lv_label_set_text(play_label, "Play");
  lv_obj_center(play_label);

  if (group) {
    lv_group_add_obj(group, rec);
    lv_group_add_obj(group, play);
    lv_group_focus_obj(room_input);
  }
  buttonMillis = millis();
}

long rightNow() {
  long timestamp = rtc.getLocalEpoch() - rtc.offset;

  return timestamp;
}

void https_download(fs::FS &fs, String url, String filename) {
  // The same link guard as https_request: a download reaches a LAN homebase, so
  // there is nothing to try without a link (the TLS connect is what reboots).
  if (WiFi.status() != WL_CONNECTED || (int32_t)(millis() - homebase_down_until) < 0) {
    Serial.println("[https] no link; download skipped");
    return;
  }
  url = url_maker(url);
  Serial.println("In the https download");
  Serial.println("writing to " + filename);
  deleteFile(fs, filename.c_str());

  Serial.println(url);
  connexion -> setCACert(HOUSE_CA_PEM);
  if (connexion) {
    {
      if (https.begin(*connexion, url)) {

        int httpCode = https.GET();
        Serial.println("Did a get");
        Serial.println(httpCode);
        if (httpCode > 0) {

          if (httpCode == HTTP_CODE_OK) {
            //  writeFile(FFat, filename.c_str(), "");

            int len = https.getSize();
            Serial.println(len);
            uint8_t buff[1024];
            File out = fs.open(filename.c_str(), FILE_APPEND);
            WiFiClient * stream = https.getStreamPtr();
            uint32_t dl_started = millis();
            // A reply fetch must never wedge the network stack: a peer that
            // stops mid-body is cut off after 15 s instead of spinning forever.
            while (https.connected() && (len > 0 || len == -1) && millis() - dl_started < 15000) {
              // read in chunks and write exactly the bytes read: appendFile's
              // file.print() treats the buffer as a C string, so binary data
              // (a WAV's NUL bytes) was truncated to a few bytes
              size_t size = stream->available();
              if (!size) { delay(1); continue; }
              int c = stream->readBytes(buff, ((size > sizeof(buff)) ? sizeof(buff) : size));
              if (c > 0 && out) { out.write(buff, c); }
              if (len > 0) {
                len -= c;
              }
            }
            if (out) { out.close(); }
            
          }
        }
      }
      https.end();
      Serial.println("Done downloading");
    }
  }
}

String url_maker(String url) {
  long timestamp = rtc.getLocalEpoch() - rtc.offset;
  String chip_id = chip_id_maker();
  // Both are base64 (and may carry '+', '/' or '='), so they must be escaped
  // or the request decoder turns '+' into a space and the token stops matching.
  url = url + "&edt=teletype&chip_id=" + chip_id + "&authorization=" + urlEncode(authorization) + "&timestamp=" + timestamp;
  return url;
}


String https_request(String url) {
  // A TLS connect needs a live link: with the deck off WiFi - or the link still
  // flapping from a join the now_me push just triggered - the connect itself is
  // what asserts inside lwip's thread/mbox setup and reboots the deck. Every
  // request here is to a LAN homebase, so with no link there is nothing to reach:
  // return before the TLS stack.
  if (homebaseIP.length() == 0 || authorization.length() == 0) {
    return "failure";
  }
  if (WiFi.status() != WL_CONNECTED) {
    return "failure";
  }
  if ((int32_t)(millis() - homebase_down_until) < 0) {
    return "failure";
  }
  url = url_maker(url);
  Serial.println("In the https request");
  Serial.println(url);
  // A stack client, not `new`: one leaked WiFiClientSecure per request (and
  // its TLS buffers) ground the heap down until a handshake could no longer
  // allocate -- every fetch then failed as "connection refused" with ~30 KB
  // still free, and the room's buttons never arrived (2026-10-09). The watch
  // was fixed the same way earlier.
  WiFiClientSecure connexion;
  connexion.setCACert(HOUSE_CA_PEM);
  HTTPClient https;
  if (!https.begin(connexion, url)) {
    return "failure";
  }
  int httpCode = https.GET();
  String answer = "failure";
  if (httpCode == HTTP_CODE_OK) {
    answer = https.getString();
    homebase_down_until = 0;
  }
  else {
    Serial.printf("HTTPS FAILED error: %s\n", https.errorToString(httpCode).c_str());
    writeFile(FFat, "/bootreport.txt", "failure");
    homebase_down_until = millis() + 20000;
  }
  https.end();
  return answer;
}


// ---- House machines -------------------------------------------------------
// The deck talks to one House machine at a time. When that machine leaves the
// LAN, this finds another computer/mobile/server that answers with the deck's
// own Now Me pair, and moves the HTTP and wss addresses together. The stored
// (preferred) machine always reclaims the deck when it comes back.
static void house_add(const String &host, int arm, int coms, int bestow) {
  if (host.length() == 0 || host == "0.0.0.0" || arm <= 0) { return; }
  for (int i = 0; i < house_node_count; i++) {
    if (house_nodes[i].host == host && house_nodes[i].arm == arm) {
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
  if (homebaseIP.length() == 0) { return; }
  String host = homebaseIP;
  int arm = 0;
  int split = host.lastIndexOf(':');
  if (split > 0) {
    arm = host.substring(split + 1).toInt();
    host = host.substring(0, split);
  }
  int coms = 0;
  int bestow = 0;
  String ws = twshomebaseIP;
  int wsp = ws.lastIndexOf(':');
  if (wsp > 0) { coms = ws.substring(wsp + 1).toInt(); }
  String bs = thomebaseIP;
  int bsp = bs.lastIndexOf(':');
  if (bsp > 0) { bestow = bs.substring(bsp + 1).toInt(); }
  if (arm > 0) { house_add(host, arm, coms, bestow); }
}

static bool house_probe(const String &host, int arm) {
  // A TLS handshake plus HTTPClient needs tens of KB. Under pressure the deck's
  // own display/voice path needs that heap more than an optional fallback, and
  // an allocation failure aborts the whole chip (lock_init_generic). Wait for
  // room rather than risk the device.
  if (ESP.getFreeHeap() < 60000) { return false; }
  if (WiFi.status() != WL_CONNECTED || authorization.length() == 0) { return false; }
  if (host.length() == 0 || arm <= 0) { return false; }
  String url = "https://" + host + ":" + String(arm) + "/watch/time?edt=teletype&chip_id="
             + urlEncode(chip_id_maker()) + "&authorization=" + urlEncode(authorization)
             + "&timestamp=" + String(rtc.getLocalEpoch() - rtc.offset);
  WiFiClientSecure conn;
  conn.setCACert(HOUSE_CA_PEM);
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
  int n = MDNS.queryService("jawnos-house", "tcp");
  for (int i = 0; i < n; i++) {
    String purpose = MDNS.txt(i, "purpose");
    if (purpose != "computer" && purpose != "mobile" && purpose != "server") { continue; }
    String host = MDNS.address(i).toString();
    if (host == "0.0.0.0" || host.length() == 0) { host = MDNS.hostname(i); }
    int arm = MDNS.txt(i, "arm").toInt();
    int coms = MDNS.txt(i, "coms").toInt();
    int bestow = MDNS.txt(i, "bestow").toInt();
    if (arm <= 0) {
      int main_port = MDNS.port(i);
      if (main_port > 0) { arm = main_port + 2; }
    }
    house_add(host, arm, coms, bestow);
  }
}

static void house_maintain() {
  if (WiFi.status() != WL_CONNECTED || authorization.length() == 0) { return; }
  // Never open a TLS client while the microphone or speaker owns the radio and
  // the heap: a fallback can wait a few seconds, a dropped capture cannot.
  if (isRecording || audio.isRunning() || voiceAwaitingReply) { return; }
  bool down = ((int32_t)(millis() - homebase_down_until) < 0);
  uint32_t wait = down ? 15000 : 300000;
  if (house_last_scan != 0 && millis() - house_last_scan < wait) { return; }
  house_last_scan = millis();
  house_scan_mdns();
  house_remember_preferred();
  if (house_node_count == 0) { return; }
  int active = house_active_index();
  int preferred = -1;
  for (int i = 0; i < house_node_count; i++) {
    String addr = house_nodes[i].host + ":" + String(house_nodes[i].arm);
    if (homebase_preferredIP.length() && addr == homebase_preferredIP) { preferred = i; break; }
  }
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
    if (i == active) { continue; }
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
      // Two quiet passes: the preferred machine is serving. Give the stack back
      // to the UI/voice heap; a fresh failure starts a new worker.
      if (++quiet >= 2) { break; }
    }
    else { quiet = 0; }
    vTaskDelay(pdMS_TO_TICKS(5000));
  }
  house_task_handle = NULL;
  vTaskDelete(NULL);
}

