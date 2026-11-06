void jawn_setup() {
  server.collectHeaders("authorization");
  Serial.begin(115200);
  // mbedTLS allocates its ~16 KB handshake buffers from internal RAM only,
  // and this board's internal heap (46 KB free, 31 KB largest block) cannot
  // hold two of them at once: every room fetch died as "SSL - Memory
  // allocation failed" (which HTTPClient reports as "connection refused"),
  // and the buttons never arrived (2026-10-09). The board has 7.6 MB of idle
  // PSRAM, so anything of 4 KB or more comes from there; the small, hot crypto
  // allocations keep to internal RAM.
  mbedtls_platform_set_calloc_free(mbedtls_psram_calloc, mbedtls_psram_free);
  // Keep internal RAM for DMA and the radio: any ordinary allocation of 64
  // bytes or more prefers the 7 MB of PSRAM. The front-end, mbedTLS's BIGNUM
  // limbs and JSON/String churn are all CPU-only.
  heap_caps_malloc_extmem_enable(64);
  // The mDNS stack logs from lwip's tcpip thread, and that thread's first console
  // write allocates the console's stdio lock. On 2026-10-16 that malloc failed
  // under memory pressure and lock_init_generic aborted the deck - a panic whose
  // backtrace read as an mDNS fault. Two cheap pieces of insurance: the mDNS log
  // is of no interest here, and the console lock is created now, at boot, while
  // the heap is large, so a later write never has to allocate it.
  esp_log_level_set("mdns", ESP_LOG_NONE);
  esp_log_level_set("mdns_networking", ESP_LOG_NONE);
  fprintf(stdout, "\n");
  fflush(stdout);
  deckLog("[deck] boot: peripheral power on (last reset: %s)", resetReasonStr(esp_reset_reason()));
  //! Set CS on all SPI buses to high level during initialization
  pinMode(BOARD_SDCARD_CS, OUTPUT);
  pinMode(RADIO_CS_PIN, OUTPUT);
  pinMode(BOARD_TFT_CS, OUTPUT);

  digitalWrite(BOARD_SDCARD_CS, HIGH);
  digitalWrite(RADIO_CS_PIN, HIGH);
  digitalWrite(BOARD_TFT_CS, HIGH);

  if (!FFat.begin()) {
    // No filesystem means no config and no recordings. It used to return out of
    // setup() here, which left the deck with a dead screen, so try to make one
    // instead and keep going regardless.
    deckLog("[deck] ffat did not mount; formatting");
    if (FFat.begin(true)) {
      deckLog("[deck] ffat formatted");
    }
    else {
      deckLog("[deck] ffat unusable; booting without it");
    }
  }
  else {
    deckLog("[deck] ffat ok");
    // A FAT that mounts but cannot be written is a half-erased filesystem: reads
    // answer from stale data, every write fails (0 files listed, yet only part
    // of the partition free), and the voice recordings never land. Probe once
    // and heal it. Nothing that matters survives a filesystem in this state.
    bool writable = false;
    File probe = FFat.open("/.wtest", FILE_WRITE);
    if (probe) {
      writable = probe.write((const uint8_t *)"x", 1) == 1;
      probe.close();
      FFat.remove("/.wtest");
    }
    if (!writable) {
      deckLog("[deck] ffat mounts but writes fail; reformatting");
      FFat.end();
      FFat.format();
      FFat.begin();
      deckLog("[deck] ffat reformatted, %u bytes free", (unsigned)FFat.freeBytes());
    }
  }

  // BLE writes are queued from the stack's own task and handled in loop()
  bleIncomingQueue = xQueueCreate(5, sizeof(String*));


  //!⚠️ The board peripheral power control pin needs to be set to HIGH when using the peripheral
  deckLog("[deck] peripheral power on");
  pinMode(BOARD_POWERON, OUTPUT);
  digitalWrite(BOARD_POWERON, HIGH);
  delay(500);
  deckLog("[deck] i2c up");
  Wire.begin(BOARD_I2C_SDA, BOARD_I2C_SCL);

  // A keyboard that does not answer used to park the boot in a silent `while (1)`
  // (the task watchdog restarts the deck a few seconds later, so it looks like
  // "freezes then reboots"). Retry briefly and carry on without it instead.
  kbDected = false;
  for (int attempt = 0; attempt < 12 && !kbDected; attempt++) {
    Wire.requestFrom(LILYGO_KB_SLAVE_ADDRESS, 1);
    kbDected = Wire.read() != -1;
    if (!kbDected) {
      delay(150);
    }
  }
  if (!kbDected) {
    // the keyboard's own controller takes its time coming up sometimes; loop()
    // keeps asking and registers the keypad as soon as it answers
    deckLog("[deck] no answer from the keyboard yet; loop() will keep trying");
  }

  deckLog("[deck] display init");
  tft.init();
  tft.setRotation(1);
  deckLog("[deck] display init done (%dx%d)", tft.width(), tft.height());
  deckLog("[deck] tft spi bus %s", spi.bus() ? "up" : "NOT UP");

  deckLog("[deck] backlight + touch pins");
  pinMode(BOARD_BL_PIN, OUTPUT);
  pinMode(BOARD_TOUCH_INT, INPUT);
  pinMode(BOARD_BAT_ADC, INPUT);
  digitalWrite(BOARD_TOUCH_INT, HIGH);

  delay(20);
  //Add mutex to allow multitasking access
  xSemaphore = xSemaphoreCreateBinary();
  assert(xSemaphore);
  xSemaphoreGive( xSemaphore );
  // Serial.print("Init display id:");

  deckLog("[deck] painting the boot screen");
  tft.fillScreen(TFT_YELLOW);
  tft.begin();

  tft.setTextColor(TFT_BLACK, TFT_YELLOW);
  tft.setTextFont(4);
  tft.drawString("JTeletype", 110, 210);

  //T-Deck control backlight chip has 16 levels of adjustment range
  for (int i = 0; i < 5; ++i) {
    setBrightness(i);
    lv_task_handler();
    delay(30);
  }

  tft.fillCircle(80, 120, 20, TFT_RED);
  tft.drawCircle(80, 120, 20, TFT_BLACK);
  // The GPS bring-up is deliberately NOT part of the boot. It talks UBX to a
  // module that may be absent, and anything that stalls in here used to hold up
  // the whole deck (screen, WiFi, keyboards). loop() retries it in the
  // background once the deck is up.
  gpsRetryAt = millis() + 4000;
  deckLog("[deck] boot screen up; the gps stage is handed to the background");

  // TFT_eSPI brought the shared SPI bus up in init() and the radio and the SD
  // card are pointed at that same instance, so there is nothing to begin here.
  //
  // And do NOT pinMode() the MISO pin: pinMode() calls perimanClearPinBus(),
  // which runs the peripheral that owns the pin to its detach callback, and the
  // SPI detach removes SPI2's MISO input route. Writes keep working (so the
  // display looks fine) and *every* read on the bus returns 0x00 - which is how
  // the radio ended up as CHIP_NOT_FOUND and the SD card would not mount. The
  // old code ran SPI.begin() right after this, which re-attached MISO and hid
  // the whole thing.
  deckLog("[deck] sd/radio spi shared");
  // The GPS is tried once the deck is idle (see loop()); its module is optional
  // and a two-second bring-up must not hold the room off the screen at boot.
  gpsRetryAt = millis() + 15000;

  // Serial.println(USER_SETUP_ID);
  // Two touch screens, the difference between them is the device address,
  // use ScanDevices to get the existing I2C address
  scanDevices(&Wire);
  deckLog("[deck] i2c scan done, touch addr 0x%02x", touchAddress);
  tft.fillCircle(160, 120, 20, TFT_GREEN);
  tft.drawCircle(160, 120, 20, TFT_BLACK);
  touch = new TouchLib(Wire, BOARD_I2C_SDA, BOARD_I2C_SCL, touchAddress);

  touch->init();
  deckLog("[deck] touch driver started");

  Wire.beginTransmission(touchAddress);
  touchDected = Wire.endTransmission() == 0;
  deckLog("[deck] touch present=%d", touchDected);

  kbDected = checkKb();
  deckLog("[deck] keyboard present=%d", kbDected);

  server.on("/notification", []() {

    notification_display(server.arg("title"), server.arg("notification"));
    server.send(200, "text/plain", "this works as well");
  });
  server.on("/backup", []() {
    JSONVar backup = JSON.parse(server.arg("backup"));
    String b = backup["current"];
    String ba = backup["archive"];
    String folder = backup["folder"];
    String request = "https://" + homebaseIP + 
      "/embedded/teletype/backup?current=" + folder + "/" + b + "&archive=" + folder + "/" + ba;
    server.send(200, "text/plain", "doing the backup");
    createDir(SD, "/b");
    String local_b = "/b/" + ba;
    https_download(SD, request, local_b.c_str());
    
  });
  server.on("/", []() {
    String html = R"(
      <!DOCTYPE html>
      <html>
        <title>T-Deck Initial Config</title>
        <body style="text-align:center;position:fixed;top: 50%;left: 50%; transform: translate(-50%, -50%);">
          <form action="/initial_config" id="form" method="POST">
            <h1>T-Deck</h1>
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
    String t_ssid = server.arg("wifi_ssid");
    String t_password = server.arg("wifi_password");
    String t_ap_ssid = server.arg("ap_ssid");
    String t_ap_password = server.arg("ap_password");
    if (t_ap_password != "" && t_ap_ssid != "") {
      ap_password = t_ap_password;
      ap_ssid = t_ap_ssid;
      accesspoint_stop();
      delay(400);
      accesspoint_start();
    }
    if (t_ssid != "" && t_password != "") {
      ssid = t_ssid;
      password = t_password;
      WiFi.disconnect();
      delay(400);
      wifi_server();
    }
    
    configSave();
    
    server.send(200, "text/html", "<h1>Success!</h1><a href='/''>Back</a>");

  });
  server.on("/wifi_update", []() {
    String req = "https://" + homebaseIP + "/teletype/wifi_update?timestamp=" + rtc.getLocalEpoch();
    // Serial.println(req);
    wifi_update = https_request(req);
    // Serial.println(wifi_update);
    JSONVar info = JSON.parse(wifi_update);
    if (ssid != (const char *)info["ssid"] || password != (const char *)info["password"]) {
      ssid = (const char *)info["ssid"];
      password = (const char *)info["password"];
      WiFi.disconnect();
      delay(400);
      wifi_server();
    }
    if (ap_ssid != (const char *)info["ap_ssid"] && ap_password != (const char *)info["ap_password"]) {
      ap_ssid = (const char *)info["ap_ssid"];
      ap_password = (const char *)info["ap_password"];
      // Serial.println(ssid);
      // Serial.println(password);
      // Serial.println(ap_ssid);
      // Serial.println(ap_password);
      accesspoint_stop();
      delay(400);
      accesspoint_start();
    }

    JSONVar pa;
    pa["ap_ssid"] = ap_ssid;
    pa["ap_password"] = ap_password;
    String public_announcement = JSON.stringify(pa);
    if (hasRadio) {
      //    radio.startTransmit(public_announcement);
      //    delay(1000);
      radio.startReceive();
    }
    server.send(200, "text/plain", "sent wifi info");

  });
  server.on("/send_telephone", []() {
    String temp_authorization = server.arg("authorization");
    JSONVar m;
    m["msg"] = server.arg("msg");
    m["app"] = server.arg("app");
    String jsm = JSON.stringify(m);
    //  Serial.println("Sending msg: " + jsm);
    if (hasRadio && !lorawan_enabled) {
      radio.startTransmit(jsm);
      delay(2000);
      radio.startReceive();
    }
    server.send(200, "text/plain", "transmission sent");
  });
  server.on("/chat_received", []() {
    if (buttoned_before) {
      //    Serial.println(server.arg("s"));
      String s = server.arg("s");
      String uuid = server.arg("uuid");
      chat_grabber(s, uuid);
      server.send(200, "text/plain", "done");
    }
    else {
      server.send(200, "text/plain", "unknown");
    }
  });
  // LoRaWAN: the Chat app's radio mode. The manager pushes the credentials and
  // asks for a join or an uplink; the deck reports what RadioLib says. The same
  // `s` hand-over token the chat bridge carries is required.
  server.on("/lorawan_config", []() {
    if (server.arg("s").length() == 0) {
      server.send(403, "application/json", "{\"ok\":false,\"error\":\"no token\"}");
      return;
    }
    if (server.hasArg("enabled")) { lorawan_enabled = server.arg("enabled") == "on"; }
    if (server.hasArg("band")) { lorawan_band = server.arg("band"); }
    if (server.hasArg("subband")) {
      int s = server.arg("subband").toInt();
      lorawan_subband = (s >= 1 && s <= 8) ? (uint8_t)s : 1;
    }
    if (server.hasArg("join_eui")) { lorawan_join_eui = server.arg("join_eui"); }
    if (server.hasArg("dev_eui")) { lorawan_dev_eui = server.arg("dev_eui"); }
    if (server.hasArg("app_key") && server.arg("app_key").length()) { lorawan_app_key = server.arg("app_key"); }
    if (server.hasArg("fport")) {
      int p = server.arg("fport").toInt();
      lorawan_fport = (p >= 1 && p <= 223) ? (uint8_t)p : 1;
    }
    if (server.hasArg("confirmed")) { lorawan_confirmed = server.arg("confirmed") == "on"; }
    configSave();
    lorawanBegin();
    server.send(200, "application/json", lorawanStatusJson());
  });
  server.on("/lorawan_join", []() {
    if (server.arg("s").length() == 0) {
      server.send(403, "application/json", "{\"ok\":false,\"error\":\"no token\"}");
      return;
    }
    int16_t state = lorawanJoin();
    JSONVar r;
    r["ok"] = (state == RADIOLIB_ERR_NONE);
    r["status"] = state;
    r["error"] = lorawan_last_error;
    r["joined"] = (lorawanNode != nullptr && lorawanNode->isActivated()) ? "yes" : "no";
    server.send(200, "application/json", JSON.stringify(r));
  });
  server.on("/lorawan_send", []() {
    if (server.arg("s").length() == 0) {
      server.send(403, "application/json", "{\"ok\":false,\"error\":\"no token\"}");
      return;
    }
    String message = server.arg("message");
    if (message.length() == 0) {
      server.send(200, "application/json", "{\"ok\":false,\"error\":\"nothing to send\"}");
      return;
    }
    if (server.hasArg("confirmed")) { lorawan_confirmed = server.arg("confirmed") == "on"; }
    int16_t state = lorawanSend(message, lorawan_confirmed);
    JSONVar r;
    r["ok"] = (state == RADIOLIB_ERR_NONE);
    r["status"] = state;
    r["error"] = lorawan_last_error;
    r["joined"] = (lorawanNode != nullptr && lorawanNode->isActivated()) ? "yes" : "no";
    r["max_payload"] = (lorawanNode != nullptr && lorawanNode->isActivated()) ? lorawanNode->getMaxPayloadLen() : 0;
    server.send(200, "application/json", JSON.stringify(r));
  });
  server.on("/lorawan_status", []() {
    if (server.arg("s").length() == 0) {
      server.send(403, "application/json", "{\"ok\":false,\"error\":\"no token\"}");
      return;
    }
    server.send(200, "application/json", lorawanStatusJson());
  });
  server.on("/device_query", []() {
    JSONVar g;
    String chip_id = chip_id_maker();
    g["chip_id"] = chip_id;
    g["purpose"] = "teletype";
    g["name"] = name;
    // the radio addresses (and the NUS uuids) so the server can bridge this deck:
    // bluetooth_sender connects the daemon to mac_addresses->bluetooth
    g["mac_addresses"] = printAllMacAddresses();
    g["SERVICE_UUID"] = SERVICE_UUID;
    g["CHARACTERISTIC_UUID_RX"] = CHARACTERISTIC_UUID_RX;
    g["CHARACTERISTIC_UUID_TX"] = CHARACTERISTIC_UUID_TX;
    g["uptime"] = millis();
    g["wigi"] = wigi;
    int bp = deck_battery_percent();
    int bmv = (int)deck_battery_voltage();
    g["battery"] = bp;
    g["battery_mv"] = bmv;
    // The deck has no fuel gauge or charger interrupt: USB is detected by the
    // pack sitting above a full cell's rest voltage. That is the same read
    // LilyGoLib uses, and it keeps a deck on USB from counting down.
    g["battery_status"] = (bmv > 4300) ? (bp >= 100 ? "full" : "charging") : "discharging";
    JSONVar jonfig = g;
    jonfig["ssid"] = undefined;
    jonfig["password"] = undefined;
    jonfig["ap_password"] = undefined;
    jonfig["ap_ssid"] = undefined;
    String gs = JSON.stringify(jonfig);    
    server.send(200, "text/plain", gs);

  });
  server.on("/netcheck", []() {
    // What this board can actually reach, and where a fetch dies: the room
    // fetch failing as "connection refused" says nothing about whether it was
    // the LAN, the gateway, or the TLS handshake (2026-10-09).
    JSONVar g;
    g["ip"] = WiFi.localIP().toString();
    g["ssid"] = WiFi.SSID();
    g["gw"] = WiFi.gatewayIP().toString();
    g["rssi"] = WiFi.RSSI();
    WiFiClient gw;
    bool gw_ok = gw.connect("192.168.2.1", 80, 2000);
    g["tcp_gw_80"] = gw_ok ? "connected" : "failed";
    if (gw_ok) { gw.stop(); }
    WiFiClient plain;
    bool tcp_ok = plain.connect("192.168.2.3", 45547, 3000);
    g["tcp_home_45547"] = tcp_ok ? "connected" : "failed";
    if (tcp_ok) { plain.stop(); }
    WiFiClientSecure tls;
    tls.setInsecure();
    bool tls_ok = tls.connect("192.168.2.3", 45547, 4000);
    g["tls_home_45547"] = tls_ok ? "connected" : "failed";
    char tls_err[96] = "";
    int tls_code = tls.lastError(tls_err, sizeof(tls_err));
    g["tls_err"] = tls_err;
    g["tls_err_code"] = tls_code;
    if (tls_ok) { tls.stop(); }
    g["heap"] = ESP.getFreeHeap();
    g["max_alloc"] = ESP.getMaxAllocHeap();
    g["psram"] = ESP.getFreePsram();
    // what the TLS handshake actually needs: two ~16 KB buffers
    void *a = malloc(16400);
    void *b = a ? malloc(16400) : nullptr;
    g["two16k"] = (a && b) ? "ok" : "failed";
    if (a) { g["two16k_in_psram"] = esp_ptr_external_ram(a) ? "yes" : "no"; }
    if (a) { free(a); }
    if (b) { free(b); }
    void *sp = heap_caps_malloc(16400, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    g["spiram16k"] = sp ? "ok" : "failed";
    if (sp) { free(sp); }
    server.send(200, "text/plain", JSON.stringify(g));
  });
  server.on("/my_position", []() {
    JSONVar location;
    location["lat"] = gps.location.lat();
    location["lng"] = gps.location.lng();
    location["alt"] = gps.altitude.meters();
    String located = JSON.stringify(location);
    server.send(200, "text/plain", located);
  });
  server.on("/update", HTTP_POST, []() {
    server.sendHeader("Connection", "close");
    if (ota_refused) {
      ota_refused = false;
      server.send(403, "text/plain", "no");
      return;
    }
    server.send(200, "text/plain", Update.hasError() ? "failed" : "ok");
    delay(500);
    ESP.restart();
  }, ota_upload);

  server.on("/wigi", []() {
    String rauth = server.arg("authorization");
    if (rauth == authorization) {      
      JSONVar wigi_s;
      wigi_s["buttons"] = wigi;
      wigi_s["authorization"] = authorization;
      long timestamp = rtc.getLocalEpoch() - rtc.offset;  

      wigi_s["timestamp"] = timestamp;
      String wigis = JSON.stringify(wigi_s);
      server.send(200,"text/plain", wigis);
      String resetter = "[]";
      wigi = JSON.parse(resetter);
    }
    else {
      server.send(200,"text/plain", "{}");
    }
  });
  server.on("/now_me", []() {
    homebaseIP = server.arg("homebase");
    thomebaseIP = server.arg("thomebase");
    twshomebaseIP = server.arg("twshomebase");
    // The machine the person paired us to. The active addresses may move to a
    // fallback House machine; only these preferred ones are saved/returned to.
    homebase_preferredIP = homebaseIP;
    thomebase_preferredIP = thomebaseIP;
    twshomebase_preferredIP = twshomebaseIP;
    house_learn_json(server.arg("houses"));
    house_remember_preferred();
    house_last_scan = 0;
    name = server.arg("name");
    authorization = server.arg("authorization");
    long timestamp = server.arg("timestamp").toInt();
    offset = server.arg("offset").toInt();
    rtc.setTime(timestamp + offset);
    homebase = server.arg("ip");
    Serial.println("Homebase: " + homebase);
    Serial.println("homebase ip:" + homebaseIP);
    rtc.offset = offset;
    room_count = server.arg("room_count").toInt();
    room_max = server.arg("room_max").toInt();
    // how the panel says a capture should start (off / vad / a wake phrase) and
    // the end-of-speech floor. voice_trigger_apply() runs in loop() with the rest
    // of the Now Me work, away from this handler.
    { String vt = server.arg("voice_trigger"); if (vt.length()) { voice_trigger = vt; } }
    { String vf = server.arg("voice_floor"); if (vf.length()) { voice_floor = vf; } }

    pmuIrq = false;
    buttoned_before = false;
    b1_toggle = b2_toggle = b3_toggle = b4_toggle = b5_toggle = b6_toggle = b7_toggle = b8_toggle = 0;
    // Do not draw from here: remote_room() fetches over HTTPS (call_the_president)
    // and drives LVGL, and running that inside the web handler nests the TLS
    // client in the HTTP server's stack and reboots the deck. Hand it to loop(),
    // which is where the BLE now_me already draws.
    now_me_requested = true;
    server.send(200, "text/plain", "homebase ip is now " + homebaseIP);
  });
  deckLog("[deck] mic i2s init");
  setupMicrophoneI2S(MIC_I2S_PORT);
  es7210Begin();
  // How many frames does the codec really produce per second? The first 300 ms
  // are read and thrown away - the dma is already holding a buffer's worth of
  // audio from boot, and counting that in makes the number nonsense.
  {
    static int16_t scratch[256];
    uint32_t drain_until = millis() + 300;
    while (millis() < drain_until) {
      size_t got = 0;
      i2s_channel_read(mic_rx_handle, scratch, sizeof(scratch), &got, 100);
    }
    uint32_t t0 = millis();
    uint32_t frames = 0;
    while (millis() - t0 < 700) {
      size_t got = 0;
      if (i2s_channel_read(mic_rx_handle, scratch, sizeof(scratch), &got, 100) == ESP_OK) {
        frames += got / (MIC_TDM_SLOTS * 2);
      }
    }
    uint32_t spent = millis() - t0;
    deckLog("[mic] rate check %u frames in %u ms = %u frames/s (expect %u)",
            (unsigned)frames, (unsigned)spent,
            (unsigned)(spent ? frames * 1000 / spent : 0), (unsigned)MIC_I2S_SAMPLE_RATE);
  }
  deckLog("[deck] mic i2s up");
  tft.fillCircle(240, 120, 20, TFT_BLUE);
  tft.drawCircle(240, 120, 20, TFT_BLACK);
  setupLvgl();
  deckLog("[deck] lvgl up");

  readFile(FFat, "/bootreport.txt");
  // restore whatever the flash holds, healthy report or not: configRestore
  // defaults the missing pieces and always draws a usable screen
  configRestore();
  deckLog("[deck] config restore done");
  // The station join is started by configRestore() without waiting for it;
  // loop() brings the server and mDNS up when association completes. Nothing
  // here should hold the room off the screen for a network round trip.
  wsclient.onMessage(wsMessageCallback);
  wsclient.onEvent(wsEventCallback);
  // set output power to 10 dBm (accepted range is -17 - 22 dBm)
  // The radio is a bonus like the GPS: each of these used to park in a silent
  // `while (true);` on failure, which froze the deck with nothing in the log.
  // Booting without a radio is better (hasRadio is what the LoRa paths check).
  deckLog("[deck] radio init");
  if (radio.setOutputPower(22) == RADIOLIB_ERR_INVALID_OUTPUT_POWER) {
    deckLog("[radio] invalid output power; continuing without it");
  }
  // set over current protection limit to 80 mA (accepted range is 45 - 240 mA)
  // NOTE: set value to 0 to disable overcurrent protection
  if (radio.setCurrentLimit(80) == RADIOLIB_ERR_INVALID_CURRENT_LIMIT) {
    deckLog("[radio] invalid current limit; continuing without it");
  }
  int state = radio.begin(433.0);
  if (state == RADIOLIB_ERR_NONE) {
    radio.setDio1Action(setFlag);
    hasRadio = true;
    // LoRaWAN owns the radio when it is on; the point-to-point chat stays an
    // alternative mode and must not also sit in raw receive waiting for a packet.
    if (lorawan_enabled) {
      lorawanBegin();
    }
    else {
      radio.startReceive();
    }
    deckLog("[radio] up");
  } else {
    deckLog("[radio] init failed (%d); continuing without it", state);
  }
  if (!hasRadio) {
    radioBusProbe();
  }

  if (fontSelect != "") {
    tft.loadFont(fontSelect);    // Must load the font first
  }
  Serial.printf("Total space: %10u\n", FFat.totalBytes());
  Serial.printf("Free space: %10u\n", FFat.freeBytes());
  uint32_t held = flashReport();
  // Power cuts during writes strand clusters in the FAT: the room is used but
  // belongs to no file, so deleting files never brings it back (this deck lost
  // 9.4 MB that way). When the free space cannot be explained by the files on
  // the disk, rebuild the filesystem. Everything on it - config, wigi,
  // recordings - is pulled again from the manager.
  if (FFat.freeBytes() < 64 * 1024 && held < FFat.totalBytes() / 2) {
    deckLog("[fs] %u bytes missing from the FAT, rebuilding the filesystem",
            (unsigned)(FFat.totalBytes() - held - FFat.freeBytes()));
    // FFat.format() refuses while the filesystem is mounted, and the sketch
    // mounts it at boot, so unmount around it and mount again afterwards.
    // begin(true) is the second chance: it formats on a failed mount.
    FFat.end();
    bool rebuilt = FFat.format();
    FFat.begin(true);
    if (rebuilt || FFat.freeBytes() > FFat.totalBytes() / 2) {
      deckLog("[fs] filesystem rebuilt, %u bytes free", (unsigned)FFat.freeBytes());
      createDir(FFat, "/jawn");
      createDir(FFat, "/jawn/recordings");
      writeFile(FFat, "/bootreport.txt", "rebuilt");
    }
    else {
      deckLog("[fs] filesystem rebuild failed, %u bytes free", (unsigned)FFat.freeBytes());
    }
  }
  // The SD card, when one is there, takes the bulk audio: recordings, voice
  // clips and the generated chimes. Mount it before the prune so that prune is
  // looking at the filesystem that will actually hold them.
  deckLog("[deck] sd test");
  sd_tester();
  // Reclaim room before anything needs to write: config, the tone file and a
  // new recording all come out as 0-byte files on a full filesystem.
  pruneRecordings(12);
  deckLog("[fs] free after prune: %u bytes", (unsigned)store_free_bytes());
  audio.setPinout(BOARD_I2S_BCK, BOARD_I2S_WS, BOARD_I2S_DOUT);
  audio.setVolume(10);
//  audio.connecttoFS(SD, "ding.mp3");
  speakerSelfTest();
  deckLog("[deck] setup complete");
  sayFetchQueue = xQueueCreate(2, sizeof(String *));
  if (sayFetchQueue) {
    sayFetchWorkerOk = xTaskCreatePinnedToCore(sayFetchWorker, "SayFetch", 8192, NULL, 1, NULL, 0) == pdPASS;
    if (!sayFetchWorkerOk) {
      deckLog("%s", "[voice] WiFi fetch worker could not start");
    }
  }
}

