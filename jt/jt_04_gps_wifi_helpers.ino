bool setupGPS(uint32_t stopWaitMs, uint32_t verWaitMs, int tries) {
  // L76K GPS USE 9600 BAUDRATE
  SerialGPS.begin(9600, SERIAL_8N1, BOARD_GPS_RX_PIN, BOARD_GPS_TX_PIN);
  bool result = false;
  uint32_t startTimeout ;
  for (int i = 0; i < tries; ++i) {
    SerialGPS.write("$PCAS03,0,0,0,0,0,0,0,0,0,0,,,0,0*02\r\n");
    delay(5);
    // Get version information
    startTimeout = millis() + stopWaitMs;
    Serial.print("Try to init L76K . Wait stop .");
    // Drain with read(), not readString(): readString() only comes back when the
    // line goes quiet (it waits up to its own timeout per byte), so a module
    // that is talking at another baud rate - which is exactly what the u-blox
    // here does once it has been configured for 38400 - feeds it garbage
    // forever and the deadline check below it never gets a chance to run. This
    // is the "GPS freezes the deck on boot" symptom, and it hangs the whole
    // deck, including the retries from loop().
    while (SerialGPS.available() && millis() < startTimeout) {
        SerialGPS.read();
    };
    Serial.println();
    if (millis() >= startTimeout) {
        Serial.println("Wait L76K stop NMEA timeout!");
        return false;
    }
    SerialGPS.flush();
    delay(200);

    SerialGPS.write("$PCAS06,0*1B\r\n");
    startTimeout = millis() + verWaitMs;
    String ver = "";
    while (!SerialGPS.available()) {
        if (millis() > startTimeout) {
            Serial.println("Get L76K timeout!");
            return false;
        }
    }
    SerialGPS.setTimeout(10);
    ver = SerialGPS.readStringUntil('\n');
    if (ver.startsWith("$GPTXT,01,01,02")) {
        Serial.println("L76K GNSS init succeeded, using L76K GNSS Module\n");
        result = true;
        break;
    }
    delay(500);
  }
  // Initialize the L76K Chip, use GPS + GLONASS
  SerialGPS.write("$PCAS04,5*1C\r\n");
  delay(250);
  SerialGPS.write("$PCAS03,1,1,1,1,1,1,1,1,1,1,,,0,0*02\r\n");
  delay(250);
  // Switch to Vehicle Mode, since SoftRF enables Aviation < 2g
  SerialGPS.write("$PCAS11,3*1E\r\n");
  return result;
}

static bool GPS_Recovery(uint32_t ackMs)
{
    uint8_t cfg_clear1[] = {0xB5, 0x62, 0x06, 0x09, 0x0D, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x1C, 0xA2};
    uint8_t cfg_clear2[] = {0xB5, 0x62, 0x06, 0x09, 0x0D, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x1B, 0xA1};
    uint8_t cfg_clear3[] = {0xB5, 0x62, 0x06, 0x09, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x03, 0x1D, 0xB3};
    uint32_t t0;
    int got;

    SerialGPS.write(cfg_clear1, sizeof(cfg_clear1));
    t0 = millis();
    got = getAck(buffer, 256, 0x05, 0x01, ackMs);
    deckLog("[gps] vals clear 1 -> %d in %u ms", got, millis() - t0);

    SerialGPS.write(cfg_clear2, sizeof(cfg_clear2));
    t0 = millis();
    got = getAck(buffer, 256, 0x05, 0x01, ackMs);
    deckLog("[gps] vals clear 2 -> %d in %u ms", got, millis() - t0);

    SerialGPS.write(cfg_clear3, sizeof(cfg_clear3));
    t0 = millis();
    got = getAck(buffer, 256, 0x05, 0x01, ackMs);
    deckLog("[gps] vals clear 3 -> %d in %u ms", got, millis() - t0);

    // UBX-CFG-RATE, Size 8, 'Navigation/measurement rate settings'
    uint8_t cfg_rate[] = {0xB5, 0x62, 0x06, 0x08, 0x00, 0x00, 0x0E, 0x30};
    SerialGPS.write(cfg_rate, sizeof(cfg_rate));
    t0 = millis();
    got = getAck(buffer, 256, 0x06, 0x08, ackMs);
    deckLog("[gps] rate poll -> %d in %u ms", got, millis() - t0);
    if (!got) {
        return false;
    }
    return true;
}

// One bounded bring-up attempt: L76K first, then the u-blox M10Q that other
// decks ship with. Returns as soon as a module answers, and gives up quickly
// when none does.
static bool gpsBringUp(uint32_t stopWaitMs, uint32_t verWaitMs, int tries, uint32_t ackMs)
{
  deckLog("[gps] trying the L76K protocol");
  if (setupGPS(stopWaitMs, verWaitMs, tries)) {
    return true;
  }
  // maybe it is a u-blox M10Q at 38400 instead of an L76K at 9600
  deckLog("[gps] no L76K, trying u-blox at 38400");
  SerialGPS.begin(38400, SERIAL_8N1, BOARD_GPS_RX_PIN, BOARD_GPS_TX_PIN);
  if (GPS_Recovery(ackMs)) {
    return true;
  }
  deckLog("[gps] trying u-blox at 9600");
  SerialGPS.updateBaudRate(9600);
  if (GPS_Recovery(ackMs)) {
    return true;
  }
  return false;
}


int getAck(uint8_t *buffer, uint16_t size, uint8_t requestedClass, uint8_t requestedID, uint32_t timeoutMs)
{
    uint16_t    ubxFrameCounter = 0;
    bool        ubxFrame = 0;
    uint32_t    startTime = millis();
    uint16_t    needRead;

    // The deadline has to be checked in here as well: a module that keeps
    // streaming NMEA leaves this inner loop with data available forever, and
    // the outer check only runs once it drains - which is never.
    while (millis() - startTime < timeoutMs) {
        while (SerialGPS.available() && (millis() - startTime < timeoutMs)) {
            int c = SerialGPS.read();
            switch (ubxFrameCounter) {
            case 0:
                if (c == 0xB5) {
                    ubxFrameCounter++;
                }
                break;
            case 1:
                if (c == 0x62) {
                    ubxFrameCounter++;
                } else {
                    ubxFrameCounter = 0;
                }
                break;
            case 2:
                if (c == requestedClass) {
                    ubxFrameCounter++;
                } else {
                    ubxFrameCounter = 0;
                }
                break;
            case 3:
                if (c == requestedID) {
                    ubxFrameCounter++;
                } else {
                    ubxFrameCounter = 0;
                }
                break;
            case 4:
                needRead = c;
                ubxFrameCounter++;
                break;
            case 5:
                needRead |=  (c << 8);
                ubxFrameCounter++;
                break;
            case 6:
                if (needRead >= size) {
                    ubxFrameCounter = 0;
                    break;
                }
                if (SerialGPS.readBytes(buffer, needRead) != needRead) {
                    ubxFrameCounter = 0;
                } else {
                    return needRead;
                }
                break;

            default:
                break;
            }
        }
    }
    return 0;
}

void displayInfo()
{
  // Keep the RTC on GPS time when the module has a date for us
  if (gps.time.isValid() && gps.date.year() != 2000) {
    rtc.setTime(gps.time.second(), gps.time.minute(), gps.time.hour(),
                gps.date.day(), gps.date.month(), gps.date.year());
    rtc.setTime(rtc.getEpoch());
  }

  // one compact line every ten seconds, instead of a wall of half printed
  // sentences for every NMEA burst the module sends
  static uint32_t lastReport = 0;
  if (millis() - lastReport < 10000) {
    return;
  }
  lastReport = millis();
  if (gps.location.isValid()) {
    Serial.printf("[gps] sats %d  %.5f,%.5f  time age %u ms\n",
                  (int)gps.satellites.value(), gps.location.lat(), gps.location.lng(),
                  (unsigned)gps.time.age());
  } else {
    Serial.printf("[gps] no fix yet, sats %d, sentences %u\n",
                  (int)gps.satellites.value(), (unsigned)gps.sentencesWithFix());
  }
}

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
    chat_text_writer(manager_file, body, timestamp);
    loraChatBroadcast(manager_file, body, timestamp);

  }

}

int last_chat_y;

// ---- the chat and pen rooms' text input --------------------------------------
// Those two rooms used to print every keystroke straight onto the panel from
// keypad_read() and keep their own String of what had been typed. That is why
// putting a real widget in here double-typed everything: both the widget and
// the raw code were handed the same key. Now the log is an LVGL label, the
// input is a real textarea in the keypad group, and keypad_read() passes these
// rooms straight to LVGL.
static lv_obj_t *room_log = NULL;     // label holding the message log
static lv_obj_t *room_input = NULL;   // the textarea being typed into
static String room_log_text;

static void roomLogAppend(String who, String body) {
  if (room_log == NULL) {
    return;
  }
  room_log_text += who + ": " + body + "\n";
  lv_label_set_text(room_log, room_log_text.c_str());
  lv_obj_scroll_to_y(lv_obj_get_parent(room_log), LV_COORD_MAX, LV_ANIM_OFF);
}

void chat_text_writer(String manager_file, String body, long timestamp) {
  buttonMillis = millis();
  // in the chat and pen rooms the log lives in LVGL above the input; the raw
  // TFT path below is what the other rooms still draw with
  if (room_log != NULL && (jw_room == "chat" || jw_room == "pen")) {
    roomLogAppend(manager_file, body);
    return;
  }
  int y = tft.getCursorY();
  int x = tft.getCursorX();
  JSONVar president;
  if (buttoned_before) {
    president = JSON.parse(before_me);
    tft.setTextColor(tft.color565(president["__specs"]["chat_text_colour_rgb"][0], president["__specs"]["chat_text_colour_rgb"][1], president["__specs"]["chat_text_colour_rgb"][2]), tft.color565(president["__specs"]["chat_background_colour_rgb"][0], president["__specs"]["chat_background_colour_rgb"][1], president["__specs"]["chat_background_colour_rgb"][2]));
  }
  else {
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
  }
  fontLoader();
  tft.setTextWrap(true, true);

  if (last_chat_y > 200) {
    last_chat_y = y + 26;
  }
  else {
    last_chat_y = last_chat_y + 26;
  }
  tft.setCursor(1, last_chat_y);
  tft.print(manager_file + ": " + body);
  last_chat_y = tft.getCursorY();
  buttonMillis = millis();
  tft.setCursor(x, y);
  fontUnloader();

}

void notification_display(String title, String notification) {
  jw_room = "message";

  static const char *btns[] = {""};

  int t_length = title.length() + 1;
  int n_length = notification.length() + 1;
  char t[t_length];
  char n[n_length];

  title.toCharArray(t, t_length);
  notification.toCharArray(n, n_length);

  lv_obj_t * mb = lv_msgbox_create(lv_scr_act());
  lv_msgbox_add_title(mb, t);
  lv_msgbox_add_text(mb, n);


  //  lv_obj_center(mb);
  lv_obj_set_y(mb, 35);

  lv_task_handler();

  //display_exit();
  buttonMillis = millis();
  lastMillis = millis();
  pmuIrq = false;
 

  bool findMp3 = audio.connecttoFS(*store, "/jawn/ding.mp3");
  if (findMp3 == false && homebaseIP) {
    String request = "https://" + homebaseIP + "/watch/asset?filename=/sounds/notifications/ding.mp3";
    Serial.println(request);
    https_download(*store, request, "/jawn/ding.mp3");
    findMp3 = audio.connecttoFS(*store, "/jawn/ding.mp3");
  }
}

// What this device is, advertised over mDNS so the Dev panel names it the moment
// it joins: purpose, model and abilities. The responder lives in lwip's tcpip
// thread; setup() silences its log and primes the console lock the log path needs
// (see the note there), which is what made it safe to keep.
#define JAWNOS_CAPS "screen,touch,keyboard,trackball,mic,speaker,gps,lora,ble,wifi,sd"

static bool jawnos_mdns_up = false;
static void jawnos_mdns_start() {
  if (jawnos_mdns_up || WiFi.status() != WL_CONNECTED) { return; }
  String chip_id = chip_id_maker();
  String host = "jawn-" + chip_id;
  if (!MDNS.begin(host.c_str())) {
    deckLog("%s", "[mdns] begin failed");
    return;
  }
  MDNS.addService("jawnos", "tcp", 3000);
  MDNS.addServiceTxt("jawnos", "tcp", "chip_id", chip_id.c_str());
  MDNS.addServiceTxt("jawnos", "tcp", "name", name.c_str());
  MDNS.addServiceTxt("jawnos", "tcp", "purpose", "teletype");
  MDNS.addServiceTxt("jawnos", "tcp", "model", "T-Deck");
  MDNS.addServiceTxt("jawnos", "tcp", "caps", JAWNOS_CAPS);
  MDNS.addServiceTxt("jawnos", "tcp", "port", "3000");
  // the Bluetooth address, so the server can bridge this deck without waiting on
  // a /device_query (bluetooth_sender connects the daemon to it)
  uint8_t bmac[6];
  if (esp_read_mac(bmac, (esp_mac_type_t)2) == ESP_OK) {
    char mstr[18];
    sprintf(mstr, "%02X:%02X:%02X:%02X:%02X:%02X", bmac[0], bmac[1], bmac[2], bmac[3], bmac[4], bmac[5]);
    MDNS.addServiceTxt("jawnos", "tcp", "mac", (const char *)mstr);
  }
  jawnos_mdns_up = true;
  deckLog("[mdns] jawnos._tcp up as %s", host.c_str());
}

void wifi_server() {
  if (ssid == "" && password == "") {
    wifi_enabled = false;
    return;
  }

  if (wifi_enabled == true) {

    if (WiFi.status() != WL_CONNECTED) {
      WiFi.begin(ssid, password);
    }

    int tryDelay = 420;
    int numberOfTries = 10;
    while (true) {
      switch (WiFi.status()) {
        case WL_NO_SSID_AVAIL:
          // Serial.println("[WiFi] SSID not found");
          break;
        case WL_CONNECT_FAILED:
          // Serial.print("[WiFi] Failed - WiFi not connected! Reason: ");
          return;
          break;
        case WL_CONNECTION_LOST:
          // Serial.println("[WiFi] Connection was lost");
          break;
        case WL_SCAN_COMPLETED:
          // Serial.println("[WiFi] Scan is completed");
          break;
        case WL_DISCONNECTED:
          // Serial.println("[WiFi] WiFi is disconnected");
          break;
        case WL_CONNECTED:
          // Serial.println("[WiFi] WiFi is connected!");
          // Serial.print("[WiFi] IP address: ");
          // Serial.println(WiFi.localIP());
          server.begin();
          webserver_enabled = true;
          wifi_enabled = true;
          jawnos_mdns_start();
          return;
          break;
        default:
          // Serial.print("[WiFi] WiFi Status: ");
          // Serial.println(WiFi.status());
          break;
      }
      delay(tryDelay);
      if (numberOfTries <= 0) {
        // Serial.print("Wifi failed to connect");
        WiFi.disconnect();
        // wifi_enabled = false;
        return;
      }
      else {
        numberOfTries--;
      }
    }
    while (WiFi.status() != WL_CONNECTED) {
      delay(100);
      // Serial.print(".");
    }
  }
}

// Start (or resume) the station link without waiting for it. setup() and
// configRestore() used to call wifi_server(), whose join loop holds the room off
// the screen for up to ~4 s; loop() starts the web server and mDNS when the link
// comes up, the same path a wake from Sleep mode uses.
static void wifi_start_async() {
  if (WiFi.status() == WL_CONNECTED) {
    if (!webserver_enabled) {
      server.begin();
      webserver_enabled = true;
    }
    jawnos_mdns_start();
    return;
  }
  if (ssid.length() == 0 || password.length() == 0) {
    wifi_enabled = false;
    return;
  }
  wifi_enabled = true;
  WiFi.mode(wifi_ap_enabled ? WIFI_AP_STA : WIFI_STA);
  WiFi.begin(ssid.c_str(), password.c_str());
  wifi_restore_pending = true;
  deckLog("[wifi] joining %s in the background", ssid.c_str());
}


// Find a field's value in raw JSON text: where it starts and how long it is,
// without copying it out. A room push is ~25 KB and the enclosure only needs
// cutting away, so the payload is reached as a span and carved in place.
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

