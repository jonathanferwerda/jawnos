void stream_large_payload(String massive_string) {
  if (!ble_link_ready()) {
    return;
  }
  // 1. Define packet size based on standard safe MTU lengths
  const int CHUNK_SIZE = 240; 
  int total_length = massive_string.length();
  int position = 0;

  Serial.printf("Starting 100KB stream. Total Bytes: %d\n", total_length);

  // 2. Loop through the string and chop it into pieces
  while (position < total_length) {
    // Take a slice of the string up to the chunk limit
    String chunk = massive_string.substring(position, position + CHUNK_SIZE);
    
    // Pass the raw data slice to your Nordic TX characteristic pointer
    pTxCharacteristic->setValue((uint8_t*)chunk.c_str(), chunk.length());
    pTxCharacteristic->notify(); // Push to Tasker
    
    position += CHUNK_SIZE;

    // 3. FLOW CONTROL: Give the Bluetooth stack 15ms to physically send the radio frame
    // This stops the chip's memory buffer from overflowing and crashing
    vTaskDelay(pdMS_TO_TICKS(15)); 
  }

  // 4. END OF FILE (EOF) MARKER: Tell Tasker the full transmission is finished!
  String eof_marker = "===EOF===";
  pTxCharacteristic->setValue((uint8_t*)eof_marker.c_str(), eof_marker.length());
  pTxCharacteristic->notify();
  
  Serial.println("100KB Stream finished completely.");
}


void awake_notifications() {
  if (millis() - notMillis > 1000) {
    notMillis = millis();
    long ts = timestamp_maker();
    if (notifications.length() > 0) {
      if (ts > next_notification && next_notification != 0) {
        notification_display(notifications[0]["title"], notifications[0]["notification"]);
        notifications[0] = undefined;
        next_notification = 0;
        notifications_processor();
      }
    }
  }
}

void readRadio() {
  if (operationDone) {
    operationDone = false;
    String str;      
    int state = radio.readData(str);
    if (state == RADIOLIB_ERR_NONE) {
      // packet was successfully received
      // Serial.println(F("[SX1262] Received packet!"));
      
      // print data of the packet
      // Serial.print(F("[SX1262] Data:\t\t"));
      // Serial.println(str);
      
      // print RSSI (Received Signal Strength Indicator)
      // Serial.print(F("[SX1262] RSSI:\t\t"));
      // Serial.print(radio.getRSSI());
      // Serial.println(F(" dBm"));
      
      // print SNR (Signal-to-Noise Ratio)
      // Serial.print(F("[SX1262] SNR:\t\t"));
      // Serial.print(radio.getSNR());
      // Serial.println(F(" dB"));
      radio.startReceive();

      JSONVar js = JSON.parse(str);
      String string = JSON.stringify(js);
      Serial.println(str);
      String ssid_check = (const char *)js["ap_ssid"];
      String msg_check = (const char *)js["msg"];
      String chat_check = (const char *)js["m"];
      if (chat_check != "") {
        String username = js["u"];
        String message = js["m"];
        Serial.println(str);
        if (authorization != "") {
          String request = "https://" + homebaseIP + "/watch/chat_received?message=" + urlEncode(message) + "&username=" + urlEncode(username);
          Serial.println(request);
          String information = https_request(request);
          Serial.println(information);
        }
      }
      else if (ssid_check != "") {
        Serial.println("Got an ssid " + ssid_check);
        ssid = (const char *)js["ap_ssid"];
        password = (const char *)js["ap_password"];
      
        webserver_enabled = true;
        wifi_server();        
        delay(1000);
        // Serial.print("Transmitting...");
  
        JSONVar returner;
        returner["time"] = timestamp_maker();
        String returns = JSON.stringify(returner);
     //   radio.startTransmit(returns);
     //   Serial.println(returns);
     //   delay(1000);
      }
      else if (msg_check != "") {
        buttonMillis = millis();
        lastMillis = millis();
        pmuIrq = true;
        String app = (const char *)js["app"];
        
        Serial.println("Got a message: " + msg_check);
        JSONVar result = JSON.parse(https_request(
          "https://" + homebaseIP +
          "/watch/telephone_msg?timestamp=" + timestamp_maker() +
          "&msg=" + msg_check + "&app=" + app
        ));
        String rs = JSON.stringify(result);
        Serial.println(rs);
      }
    }
  }
}
// What this device is, advertised over mDNS so the Dev panel names it the moment
// it joins (see the server's subs::mdns_devices): purpose, model and abilities, on
// _jawnos._tcp. setup() silences the responder's log and primes the console lock
// its log path needs, which is what made it safe to keep.
#define JAWNOS_CAPS "screen,touch,button,crown,mic,speaker,imu,steps,vibe,ble,wifi,lora"

static bool jawnos_mdns_up = false;
static void jawnos_mdns_start() {
  if (jawnos_mdns_up || WiFi.status() != WL_CONNECTED) { return; }
  String chip_id = chip_id_maker();
  String host = "jawn-" + chip_id;
  if (!MDNS.begin(host.c_str())) {
    Serial.println("[mdns] begin failed");
    return;
  }
  MDNS.addService("jawnos", "tcp", 3000);
  MDNS.addServiceTxt("jawnos", "tcp", "chip_id", chip_id.c_str());
  MDNS.addServiceTxt("jawnos", "tcp", "name", name.c_str());
  MDNS.addServiceTxt("jawnos", "tcp", "purpose", "watch");
  MDNS.addServiceTxt("jawnos", "tcp", "model", "T-Watch S3");
  MDNS.addServiceTxt("jawnos", "tcp", "caps", JAWNOS_CAPS);
  MDNS.addServiceTxt("jawnos", "tcp", "port", "3000");
  // the Bluetooth address, so the server can bridge this watch without waiting on
  // a /device_query (bluetooth_sender connects the daemon to it)
  uint8_t bmac[6];
  if (esp_read_mac(bmac, (esp_mac_type_t)2) == ESP_OK) {
    char mstr[18];
    sprintf(mstr, "%02X:%02X:%02X:%02X:%02X:%02X", bmac[0], bmac[1], bmac[2], bmac[3], bmac[4], bmac[5]);
    MDNS.addServiceTxt("jawnos", "tcp", "mac", (const char *)mstr);
  }
  jawnos_mdns_up = true;
  Serial.println("[mdns] jawnos._tcp up as " + host);
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
    int numberOfTries = 12;
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
        Serial.print("Wifi failed to connect");
        Serial.print(ssid + " " + password);
        WiFi.disconnect();
        wifi_enabled = false;
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

void homebasePing() {
  if (wifi_enabled == true && buttoned_before) {
    String https = https_request(
      "https://" + homebaseIP + "/watch/alive?millis=" + millis()
    );
    JSONVar alive;
    if (https != "failure") {
      alive = JSON.parse(https);
    }
  }
}

void notifications_processor() {
  double next_time = 0;
  String check = "no";
  long timestamp = timestamp_maker();
  wakeup_time = 0;
  int length = notifications.length();
  if (length > 0) {
    for (int i = 0; i < length; i++) {

      String times = notifications[i]["timestamp"];
      long ts = times.toInt();
      if (timestamp < ts) {
        if (check == "no") {
          check = "yes";
          Serial.println("checking");
          wakeup_time = (double)notifications[i]["next_time"];
          next_notification = ts;
        }
      }
      else {
        notifications[i] = undefined;
      }
    }
  }
}

void notification_display(String title, String notification) {
  if (title) {
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
    wakeup();
  }
}

void wakeup() {
  // Serial.println("Wakeup");
  watch.setBrightness(brightnessLevel);
  //display_exit();
  buttonMillis = millis();
  lastMillis = millis();
  pmuIrq = false;
  watch.setHapticEffects(vibrateLevel);
  watch.vibrator();

  
}

// ---- the watch face ----------------------------------------------------------
// The old fork drew this text straight onto the panel with TFT_eSPI; LVGL owns the
// screen now, so the same lines are labels that get refreshed in place.
static lv_obj_t *face_label_maker(int x, int y, const lv_font_t *font, lv_color_t colour,
                                  int width = 0, lv_align_t align = LV_ALIGN_TOP_LEFT)
{
  lv_obj_t *label = lv_label_create(lv_scr_act());
  if (width > 0) {
    lv_obj_set_width(label, width);
    lv_label_set_long_mode(label, LV_LABEL_LONG_DOT);  // text never runs off the panel
  }
  if (align == LV_ALIGN_TOP_LEFT) {
    lv_obj_set_pos(label, x, y);
    lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_LEFT, LV_PART_MAIN);
  }
  else {
    lv_obj_align(label, align, x, y);
    lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, LV_PART_MAIN);
  }
  lv_obj_set_style_text_font(label, font, LV_PART_MAIN);
  lv_obj_set_style_text_color(label, colour, LV_PART_MAIN);
  lv_label_set_text(label, "");
  return label;
}

static void face_forget()
{
  face_date = nullptr;
  face_time = nullptr;
  face_sec = nullptr;
  face_steps = nullptr;
  face_battery = nullptr;
  face_percent = nullptr;
  face_name = nullptr;
  face_ip = nullptr;
  face_gw = nullptr;
  face_bt = nullptr;
  face_ap = nullptr;
  face_apgw = nullptr;
  face_presidente = nullptr;
  for (int i = 0; i < 4; i++) {
    notification_lines[i] = nullptr;
  }
}

void watch_face_maker()
{
  if (face_time) {
    return;                     // already on this screen
  }
  // the room swipe; the screen object outlives lv_obj_clean, so once
  static bool gesture_registered = false;
  if (!gesture_registered) {
    gesture_registered = true;
    lv_obj_add_event_cb(lv_scr_act(), screen_gesture, LV_EVENT_GESTURE, NULL);
  }
  // the panel only scrolls up and down, sideways nothing is allowed to stick out
  lv_obj_set_scroll_dir(lv_scr_act(), LV_DIR_VER);

  // status bar along the top: the battery (or, off the clock room, the time) on
  // the left, and the serving machine's name hard against the right edge - the
  // label sizes itself, so its LAST character sits 2 px from the edge whatever
  // the name is. The label box is auto-width for exactly that.
  face_battery = face_label_maker(10, 4, &lv_font_montserrat_16, lv_color_hex(0x00FF00));
  face_percent = face_label_maker(42, 4, &lv_font_montserrat_16, lv_color_hex(0x00FF00), 14);
  face_name = face_label_maker(-2, 4, &lv_font_montserrat_14, lv_color_hex(0x00FF00), 0, LV_ALIGN_TOP_RIGHT);

  // the clock, centred under the status bar; the digits come from clock_font
  // (72 px). The label box is nudged left so the seconds fit beside it.
  face_date = face_label_maker(0, 26, &lv_font_montserrat_16, lv_color_hex(0xFFE000), 220, LV_ALIGN_TOP_MID);
  face_time = face_label_maker(-10, 44, &clock_font, lv_color_hex(0xFFE000), 220, LV_ALIGN_TOP_MID);

  // the seconds sit right beside the clock (same 24 px, vertically centred on
  // it); the step count is small and out of the way in the top-right corner
  face_sec = face_label_maker(-4, 70, &lv_font_montserrat_24, lv_color_hex(0xFFE000), 0, LV_ALIGN_TOP_RIGHT);
  face_steps = face_label_maker(-8, 26, &lv_font_montserrat_14, lv_color_hex(0x5afcdd), 0, LV_ALIGN_TOP_RIGHT);

  // the net room; ip_writer() blanks these rows everywhere else
  face_ip = face_label_maker(20, 140, &lv_font_montserrat_16, lv_color_hex(0xFFFFFF), 100);
  face_gw = face_label_maker(130, 140, &lv_font_montserrat_16, lv_color_hex(0xFFFFFF), 100);
  face_ap = face_label_maker(20, 160, &lv_font_montserrat_16, lv_color_hex(0xFFFFFF), 100);
  face_apgw = face_label_maker(130, 160, &lv_font_montserrat_16, lv_color_hex(0xFFFFFF), 100);
}

void display_exit( void ) {
  lv_obj_clean ( lv_scr_act() ); // Clean objects from current screen.
  lv_obj_invalidate( lv_scr_act() ); // Invalidate objects for redraw.
  face_forget();
  wigi_count_label = nullptr;   // the Wigi button died with lv_obj_clean
  // ... and so did the bottom row and the room's buttons
  btn1 = btn2 = btn3 = btn4 = btn5 = btn6 = nullptr;
  for (int i = 0; i < ROOM_BUTTON_SLOTS; i++) { room_button_obj[i] = nullptr; }
  button_feedback_forget();
  ble_room_requested_at = 0;    // leaving the room: cancel an unanswered request
  button_writer();
//  time_writer("now");
}

// With Bluetooth up the panel's DMA buffers get starved for a moment, and a
// dropped SPI transfer leaves that region holding the previous room's pixels
// (LVGL believes the frame went out, so nothing ever repaints it). Every room
// draw ends with two full passes: whatever the first lost, the second redraws.
void full_refresh() {
  lv_obj_invalidate(lv_scr_act());
  lv_task_handler();
  lv_obj_invalidate(lv_scr_act());
  lv_task_handler();
}

long timestamp_maker() {
  struct tm timeinfo;
  watch.rtc.getDateTime(&timeinfo);

  time_t timestamp = mktime(&timeinfo);
  long ts = (long)timestamp;
  if (offset) {
    ts = timestamp - rtc.offset;
  }
  return ts;
}

void time_writer(char * situation) {
  if (millis() - lastMillis > 1000 || situation == "now") {
    lastMillis = millis();
    if (notification_viewing == 1) {
      notification_review();
    }
    else {
      struct tm timeinfo;
      // Get the time C library structure
      watch.rtc.getDateTime(&timeinfo);
      size_t written_date = strftime(bufdate, 64, "%a %b %d %Y", &timeinfo);
      size_t written_time = strftime(buftime, 64, "%H:%M", &timeinfo);
      size_t written_sec = strftime(bufsec, 64, "%S", &timeinfo);
      if (face_date && written_date != 0) {
        lv_label_set_text(face_date, bufdate);
      }
      if (face_time && written_time != 0) {
        lv_label_set_text(face_time, buftime);
      }
      if (face_sec && written_sec != 0) {
        lv_label_set_text(face_sec, bufsec);
      }
      if (face_steps && stepCounter == true) {
        lv_label_set_text_fmt(face_steps, "%u", (unsigned)steps);
      }
      update_wigi_indicator();
    }
  }
}

// The room views used to carry a red LED and a count for taps that could not be
// delivered; they crowded the buttons down there, so the indicator lives on the
// clock room's Wigi button instead: the count rides in its label and the button
// turns red while anything is waiting.
void update_wigi_indicator() {
  if (!wigi_count_label) {
    return;
  }
  int pending = wigi.length();
  if (pending > 0) {
    lv_label_set_text_fmt(wigi_count_label, "Wigi %d", pending);
    if (wigi_btn) {
      lv_obj_set_style_bg_color(wigi_btn, lv_color_hex(0xde2716), LV_PART_MAIN);
    }
  }
  else {
    lv_label_set_text(wigi_count_label, "Wigi");
    if (wigi_btn) {
      lv_obj_set_style_bg_color(wigi_btn, lv_color_hex(0x27de16), LV_PART_MAIN);
    }
  }
}

void ip_writer() {
  if (face_bt) {
    // the net room's BT line: the bridge's own name when it sent one, else
    // the address the connect event carried, else the state of the radio
    char bt_line[64];
    if (bt_enabled == false) {
      snprintf(bt_line, sizeof(bt_line), "BT: off");
      lv_obj_set_style_text_color(face_bt, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    }
    else if (deviceConnected) {
      const char *who = ble_peer_name[0] ? ble_peer_name : (ble_peer_addr[0] ? ble_peer_addr : "?");
      snprintf(bt_line, sizeof(bt_line), "BT: %s", who);
      lv_obj_set_style_text_color(face_bt, lv_color_hex(0x00FF00), LV_PART_MAIN);
    }
    else if (ble_radio_up) {
      snprintf(bt_line, sizeof(bt_line), "BT: waiting");
      lv_obj_set_style_text_color(face_bt, lv_color_hex(0xFFE000), LV_PART_MAIN);
    }
    else {
      snprintf(bt_line, sizeof(bt_line), "BT: starting");
      lv_obj_set_style_text_color(face_bt, lv_color_hex(0xFFFFFF), LV_PART_MAIN);
    }
    lv_label_set_text(face_bt, bt_line);
  }
  if (!face_ip) {
    return;
  }
  // the addresses only belong on the screen in the net room; everywhere else the
  // row stays blank so it cannot sit on top of a room's buttons
  if (jw_room != "net") {
    lv_label_set_text(face_ip, "");
    lv_label_set_text(face_gw, "");
    lv_label_set_text(face_ap, "");
    lv_label_set_text(face_apgw, "");
    return;
  }
  IPAddress ip = WiFi.localIP();
  sprintf(bufIP, "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
  IPAddress gw_ip = WiFi.gatewayIP();
  sprintf(bufgwIP, "%d.%d.%d.%d", gw_ip[0], gw_ip[1], gw_ip[2], gw_ip[3]);
  lv_label_set_text(face_ip, bufIP);
  lv_label_set_text(face_gw, bufgwIP);
  if (wifi_ap_enabled) {
    apIP = WiFi.softAPIP();
    // the soft AP is its own gateway on this little subnet
    sprintf(bufapIP, "%d.%d.%d.%d", apIP[0], apIP[1], apIP[2], apIP[3] );
    sprintf(bufapgwIP, "%d.%d.%d.%d", apIP[0], apIP[1], apIP[2], apIP[3] );
    lv_label_set_text(face_ap, bufapIP);
    lv_label_set_text(face_apgw, bufapgwIP);
  }
  else {
    lv_label_set_text(face_ap, "");
    lv_label_set_text(face_apgw, "");
  }
}

void button_writer() {
  // Built once per screen: remote_room() used to call this after display_exit()
  // had already built the row, leaving a second set of buttons and labels behind
  // on every room entry.
  if (btn1) { return; }
  watch_face_maker();

  btn1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn1, touch_button1, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn1, 65, 190 );
  lv_obj_set_size(btn1, 50, 50 );
  lv_obj_set_style_bg_color(btn1, lv_color_hex(0xde2716), LV_PART_MAIN);

  lv_obj_t *l1;
  lv_color_t t1;
  t1 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn1, t1, LV_PART_MAIN);
  l1 = lv_label_create(btn1);
  lv_label_set_text(l1, "Rom");
  lv_obj_center(l1);

  btn2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn2, touch_button2, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn2, 10, 190 );
  lv_obj_set_size(btn2, 50, 50 );
  lv_obj_set_style_bg_color(btn2, lv_color_hex(0xffca38), LV_PART_MAIN);

  lv_obj_t *l2;
  lv_color_t t2;
  t2 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn2, t2, LV_PART_MAIN);
  l2 = lv_label_create(btn2);
  lv_label_set_text(l2, "Clk");
  lv_obj_center(l2);

  btn3 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn3, touch_button3, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn3, 120, 190 );
  lv_obj_set_size(btn3, 50, 50 );
  lv_obj_set_style_bg_color(btn3, lv_color_hex(0xfa3ced), LV_PART_MAIN);

  lv_obj_t *l3;
  lv_color_t t3;
  t3 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn3, t3, LV_PART_MAIN);
  l3 = lv_label_create(btn3);
  lv_label_set_text(l3, "Set");
  lv_obj_center(l3);

  btn6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn6, touch_button4, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn6, 175, 190 );
  lv_obj_set_size(btn6, 50, 50 );
  lv_obj_set_style_bg_color(btn6, lv_color_hex(0x1aacfd), LV_PART_MAIN);

  lv_obj_t *l6;
  lv_color_t t6;
  t6 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn6, t6, LV_PART_MAIN);
  l6 = lv_label_create(btn6);
  lv_label_set_text(l6, "Net");
  lv_obj_center(l6);
}


void https_download(fs::FS &fs, String url, String filename) {
  url = url_maker(url);
  Serial.println("In the https download");
  Serial.println(url);
  // Start from an empty file: FILE_APPEND is used below so binary bytes are
  // written with their exact length, but appending a new reply onto an old one
  // would leave the WAV's data chunk pointing at the previous clip.
  fs.remove(filename.c_str());
  connexion -> setInsecure();
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

    }
  }
}

String chip_id_maker() {
  uint32_t chipId = 0;
  for(int i=0; i<17; i=i+8) {
    chipId |= ((ESP.getEfuseMac() >> (40 - i)) & 0xff) << i;
  }
  String chip_id = String(chipId);
  return chip_id;
}

String url_maker(String url) {
  String chip_id = chip_id_maker();
  long timestamp = timestamp_maker();
  // The token is base64 and may carry '+', '/', or '=', so escape it: the
  // route decoder turns an unescaped '+' into a space and the token stops
  // matching (the t-deck has always done this).
  url = url + "&edt=watch&chip_id=" + chip_id + "&authorization=" + urlEncode(authorization) + "&timestamp=" + timestamp;
  return url;
}

String https_request(String url, String method, String payloadData) {
  uint32_t started = millis();
  String answer = https_request_raw(url, method, payloadData);
  Serial.printf("[https] %u ms %s\n", millis() - started, url.c_str());
  return answer;
}

String https_request_raw(String url, String method, String payloadData) {
  // An empty homebase used to become "https:///" and the name lookup that
  // followed panicked the chip (a FreeRTOS assert inside lwip) whenever the
  // config had been wiped. Nothing to talk to means nothing to try.
  if (homebaseIP.length() == 0 || authorization.length() == 0) {
    return "failure";
  }
  // A TLS connect needs a live link: with the watch off WiFi (or the link
  // flapping) the connect itself is what asserts inside lwip's thread/mbox setup
  // and reboots the watch (see the notes, symbolised start_ssl_client). The watch
  // reports WiFi 254 = not connected, and every request here is to a LAN homebase,
  // so with no link there is nothing to reach - return before the TLS stack.
  if (WiFi.status() != WL_CONNECTED) {
    return "failure";
  }
  // A homebase that has gone away (a sleeping laptop) turns every request into a
  // TLS connect that times out. Hammering it -- a button press each time --
  // asserts inside lwip's thread/mbox setup and reboots the watch (the longer it
  // is tried, the more likely). Back off after a failure: the caller's fallback
  // (queue the tap, or hand it over BLE) is what a press should do while the
  // homebase is away.
  if ((int32_t)(millis() - homebase_down_until) < 0) {
    return "failure";
  }
  url = url_maker(url);
  Serial.println(url);
  // A stack client, not "new": one leaked WiFiClientSecure per request is what
  // ground the heap down until the panel's SPI DMA buffers stopped allocating.
  WiFiClientSecure connexion;
  connexion.setInsecure();
  bool reached = false;
  {
    HTTPClient https;
    https.setTimeout(4000);   // a slow homebase must not freeze the loop for long
    if (https.begin(connexion, url)) {
       Serial.println("est connection");
      int httpCode = https.GET();
      if (method == "POST") {
        Serial.println("Executing HTTPS POST...");
        httpCode = https.POST("");
      }
      String answer = "failure";
      if (httpCode > 0) {
        reached = true;
         Serial.printf("HTTPS GET code: %d\n", httpCode);
        if (httpCode == HTTP_CODE_OK) {
          answer = https.getString();
          // a room fetch is tens of KB: do not push the whole body at the
          // console (it wedged the USB-JTAG TX when nothing was reading)
          Serial.printf("[https] answer %u bytes\n", (unsigned)answer.length());
        }
      }
      else {
        writeFile(FFat, "/bootreport.txt", "failure");
      }
      https.end();
      homebase_down_until = reached ? 0 : millis() + 20000;
      return answer;
    }
  }
  homebase_down_until = millis() + 20000;
  return "failure";
}

