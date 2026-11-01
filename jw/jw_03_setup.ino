// ---- over the air updates -----------------------------------------------------
// The embedded panel posts a compiled .bin here over the LAN and the board reboots
// into it. The board has to have this in it once (flashed over USB); after that the
// panel can replace the firmware whenever there is a new build.
void ota_upload() {
  HTTPUpload &upload = server.upload();
  if (upload.status == UPLOAD_FILE_START) {
    Serial.println("ota: " + upload.filename);
    if (!Update.begin(UPDATE_SIZE_UNKNOWN)) {
      Update.printError(Serial);
    }
  }
  else if (upload.status == UPLOAD_FILE_WRITE) {
    if (Update.write(upload.buf, upload.currentSize) != upload.currentSize) {
      Update.printError(Serial);
    }
  }
  else if (upload.status == UPLOAD_FILE_END) {
    if (Update.end(true)) {
      Serial.println("ota written");
    }
    else {
      Update.printError(Serial);
    }
  }
}

// Apply the panel's voice mode onto the capture listener. A mode we have a model
// for ('vad' or a wake phrase) arms the listener (capture on speech / after the
// phrase); 'off' and unknown names disarm it and are logged - the round-trip from
// the Embedded panel shows up on the serial console.
static void voice_trigger_apply() {
  if (voice_models_has(voice_trigger)) {
    voiceCaptureEnabled = true;
  } else {
    voiceCaptureEnabled = false;
    if (voice_trigger.length() && voice_trigger != "off") {
      Serial.printf("[voice] no model for '%s'\n", voice_trigger.c_str());
    }
  }
  Serial.printf("[voice] mode=%s\n", voice_trigger.c_str());
}

void jawn_setup() {
  Serial.begin(921600);
  // Never let the console block the UI. The USB-Serial/JTAG CDC write waits up
  // to 20 x 100 ms (2 s) per call when the host is not reading -- which is
  // exactly the state of a watch plugged into a computer with no serial monitor
  // open. The screen builders and the tap path print a few lines each, so a
  // switch or a press froze for seconds; a zero timeout drops the output
  // instead (best-effort logging).
  Serial.setTxTimeoutMs(0);
  // The mDNS stack logs from lwip's tcpip thread, and that thread's first console
  // write allocates the console's stdio lock; a failed malloc there aborts the
  // board (the deck hit exactly that). Prime the lock now, while the heap is
  // large, and leave the mDNS log off - nothing here reads it.
  esp_log_level_set("mdns", ESP_LOG_NONE);
  esp_log_level_set("mdns_networking", ESP_LOG_NONE);
  fprintf(stdout, "\n");
  fflush(stdout);

  watch.begin();
  watch.initMicrophone();

	taskMutex = xSemaphoreCreateMutex(); 

  xTaskCreatePinnedToCore(
    // 12 KB: this task parses the whole pushed payload (a room push is 25 KB of
    // JSON); 4 KB overflowed the stack and aborted the watch on 2026-10-09. The
    // compressed-payload inflate used to add ~10 KB more (miniz's state on the
    // stack), which is why this was briefly 20 KB -- but that permanent 8 KB
    // starved the LCD's SPI DMA pool and froze the display. The inflate keeps
    // its state in PSRAM now (see ble_inflate_if_zlib), so 12 KB holds.
    loop2, "Core0Task", 12288, NULL, 1, &Core0TaskHandle, 0
  );
  bleIncomingQueue = xQueueCreate(5, sizeof(String*));

  Serial.println("starting");
  // a doze or crown-press that ends in a reset is otherwise invisible here
  Serial.printf("[boot] reset reason: %d\n", (int)esp_reset_reason());
  if (crumb_magic == CRUMB_MAGIC) {
    // not cleared: a missed log line can be read back with the crumb command
    // (crumbs_dump has the whole ring and the heap at every mark)
    Serial.printf("[crumb] the reset happened after: %s\n",
                  crumb_tag[crumb_head][0] ? crumb_tag[crumb_head] : "(?)");
  }
  else {
    crumb_tag[0][0] = '\0';
  }
  // If loop2 stops feeding this, the chip reboots instead of hanging until a
  // hard reset (the 25 KB pushes have hung it, 2026-10-09); the panic dump
  // that follows names the task that stalled.
  esp_task_wdt_config_t twdt_cfg = {};
  twdt_cfg.timeout_ms = 20000;
  twdt_cfg.idle_core_mask = 0;
  twdt_cfg.trigger_panic = true;
  if (esp_task_wdt_init(&twdt_cfg) == ESP_ERR_INVALID_STATE) {
    esp_task_wdt_reconfigure(&twdt_cfg);
  }
  watch.setRotation(screenRotation);  
  setCpuFrequencyMhz(240);
  time_writer("now");

  settingSensor();

 //if (FORMAT_FFAT) FFat.format();
  if (!FFat.begin()) {
    Serial.println("FFat Mount Failed");
    return;
  }
  else {
    Serial.println("Mounted FFat partition");
    Serial.printf("Total space: %10u\n", FFat.totalBytes());
    Serial.printf("Free space: %10u\n", FFat.freeBytes());    
  }

  // Serial.print(F("[SX1262] Initializing ... "));
  // set output power to 10 dBm (accepted range is -17 - 22 dBm)
  if (radio.setOutputPower(22) == RADIOLIB_ERR_INVALID_OUTPUT_POWER) {
      // Serial.println(F("Selected output power is invalid for this module!"));
      while (true);
  }
  // set over current protection limit to 80 mA (accepted range is 45 - 240 mA)
  // NOTE: set value to 0 to disable overcurrent protection
  if (radio.setCurrentLimit(80) == RADIOLIB_ERR_INVALID_CURRENT_LIMIT) {
      // Serial.println(F("Selected current limit is invalid for this module!"));
      while (true);
  }    
  int state = radio.begin(433);
  if (state == RADIOLIB_ERR_NONE) {
    // Serial.println(F("success!"));
    radio.setDio1Action(setFlag);

    radio.startReceive();
  } else {
    // Serial.print(F("failed, code "));
    // Serial.println(state);
    while (true);
  }

  


  beginLvglHelper(instance);
  lv_obj_set_style_bg_color(lv_scr_act(), lv_color_hex(0x000000), LV_PART_MAIN);


  // the old fork dropped to 80 MHz here and only came back up after a sleep; 240
  // is what the sleep handler restores anyway, so start there
  setCpuFrequencyMhz(240);
  button_writer();

  settingPMU();
  server.on("/", []() {
    String html = R"(
      <!DOCTYPE html>
      <html>
        <title>T-Watch Initial Config</title>
        <body style="text-align:center;position:fixed;top: 50%;left: 50%; transform: translate(-50%, -50%);">
          <form action="/initial_config" id="form" method="POST">
            <h1>T-Watch</h1>
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
    server.send(200, "text/html", "<h1>Success!</h1><a href='/'>Back</a>");
    

  });
  server.on("/notification", []() {
    notification_display(server.arg("title"), server.arg("notification"));;
    server.send(200, "text/plain", "this works as well");
  });
  server.on("/wifi_update", []() {
    String req = "https://" + homebaseIP + "/teletype/wifi_update?timestamp=" + timestamp_maker();
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
  //  radio.startTransmit(public_announcement);
  //  server.send(200, "text/plain", "done");
  //  delay(1000);
    radio.startReceive();
    server.send(200, "text/plain", "sent wifi info");
  });
  server.on("/send_telephone", []() {
    Serial.println("send telephone");
    String temp_authorization = server.arg("authorization");
    Serial.println(temp_authorization);
      Serial.println("in the temp auth");
      JSONVar m;
      m["msg"] = server.arg("msg");
      m["app"] = server.arg("app");
      String jsm = JSON.stringify(m);
      Serial.println("Sending msg: " + jsm);
      radio.startTransmit(jsm);
      delay(1000);
      radio.startReceive();
      server.send(200, "text/plain", "transmission sent");
      buttonMillis = millis();
      lastMillis = millis();
      pmuIrq = true;
  });
  
  server.on("/chat_received", []() {
    if (buttoned_before) {
      Serial.println(server.arg("s"));
      String s = server.arg("s");
      String uuid = server.arg("uuid");
      chat_grabber(s,uuid);
      server.send(200, "text/plain", "done");
    }
    else {
      server.send(200, "text/plain", "unknown");
    }
  });
  server.on("/device_query", []() {
    JSONVar g;
    String chip_id = chip_id_maker();
    g["chip_id"] = chip_id;
    JSONVar macs = printAllMacAddresses();
    g["mac_addresses"] = macs;
    g["SERVICE_UUID"] = SERVICE_UUID;
    g["CHARACTERISTIC_UUID_RX"] = CHARACTERISTIC_UUID_RX;
    g["CHARACTERISTIC_UUID_TX"] = CHARACTERISTIC_UUID_TX;
    g["name"] = name;
    g["uptime"] = millis();
    g["purpose"] = "watch";
    g["wigi"] = wigi;
    g["steps"] = stepped;
    // The face already reads these every loop; reporting them here lets the
    // house's levels view show the watch beside the machines, not just on it.
    int bp = (int)watch.getBatteryPercent();
    g["battery"] = bp;
    g["battery_mv"] = (int)(watch.getBattVoltage() * 1000);
    g["battery_status"] = watch.isCharging() ? (bp >= 100 ? "full" : "charging") : "discharging";
    JSONVar fileList = JSON.parse("[]");
    listJsonDir(FFat,"/", fileList);
    g["files"] = fileList;
    JSONVar jonfig = g;
    jonfig["ssid"] = undefined;
    jonfig["password"] = undefined;
    jonfig["ap_password"] = undefined;
    jonfig["ap_ssid"] = undefined;
    String gs = JSON.stringify(jonfig);    
    server.send(200, "text/plain", gs);

  });
  server.on("/delete_file", []() {
    String rauth = server.arg("authorization");
    Serial.println("in the deleter");
    if (rauth == authorization) {
      String file = server.arg("file");
      Serial.println(file);
      deleteFile(FFat, file.c_str());
      server.send(200, "text/plain", "file deleted");

    }
  });
  server.on("/get_file", HTTP_GET, []() {
    // 1. Check authorization
    String rauth = server.arg("authorization");
    if (rauth != authorization) {
      server.send(401, "text/plain", "Unauthorized");
      return;
    }

    // 2. Get the requested filename
    String fileName = server.arg("file");
    if (fileName == "") {
        server.send(400, "text/plain", "Missing file parameter");
        return;
    }

    // Ensure the filename starts with a forward slash for SPIFFS/FFat compatibility
    if (!fileName.startsWith("/")) {
        fileName = "/" + fileName;
    }

    // 3. Attempt to open the file from FFat storage
    if (FFat.exists(fileName)) {
      File file = FFat.open(fileName, "r");
      
      // 4. Resolve the correct MIME header dynamically
      String contentType = getContentType(fileName);
      
      // 5. Stream the file directly to the client (very RAM efficient!)
      server.streamFile(file, contentType);
      
        // 6. Close the file immediately after streaming to prevent memory leaks
      file.close(); 
    } else {
        // Fallback if the file isn't found
      server.send(404, "text/plain", "File Not Found");
    }
  });

  server.on("/update", HTTP_POST, []() {
    server.sendHeader("Connection", "close");
    server.send(200, "text/plain", Update.hasError() ? "failed" : "ok");
    delay(500);
    ESP.restart();
  }, ota_upload);

  server.on("/wigi", []() {
    String rauth = server.arg("authorization");
    if (rauth == authorization) {

      JSONVar wigi_s;
      wigi_s["buttons"] = wigi;
      wigi_s["measures"]["steps"] = stepped;
      wigi_s["authorization"] = authorization;
      JSONVar fileList = JSON.parse("[]");
      listJsonDir(FFat,"/", fileList);
      wigi_s["files"] = fileList;
      long timestamp = timestamp_maker(); 

      wigi_s["timestamp"] = timestamp;
      String wigis = JSON.stringify(wigi_s);
      server.send(200,"text/plain", wigis);
      String resetter = "[]";
      wigi = JSON.parse(resetter);
      stepped = JSON.parse(resetter);
      watch.resetStepCounter();
      // the counter starts again from zero, so start the next batch there too
      // instead of recording the reset as a step
      steps = 0;
      sportsIrq = false;
      stepSampleMillis = millis();
    }
    else {
      server.send(200,"text/plain", "{}");
    }
  });
  server.on("/now_me", []() {
    homebaseIP = server.arg("homebase");
    homebase = server.arg("ip");
    // This is the machine the person paired us to; a fallback House machine is
    // temporary, so this is the address a config save keeps and the one the
    // House task returns to when it answers again.
    homebase_preferredIP = homebaseIP;
    house_learn_json(server.arg("houses"));
    house_remember_preferred();
    house_last_scan = 0;
    authorization = server.arg("authorization");
    DEFAULT_SCREEN_TIMEOUT = server.arg("screen_timeout").toInt();
    long timestamp = server.arg("timestamp").toInt();
    rtc.setTime(timestamp);
    offset = server.arg("offset").toInt();
    rtc.offset = offset;
    // correct the face's hardware RTC now, not only when a room payload comes
    // back (see clock_apply_to_face)
    clock_apply_to_face();
    Serial.println("Homebase: " + homebase);
    Serial.println("homebase ip:" + homebaseIP);
    
    room_count = server.arg("room_count").toInt();
  //  room_max = server.arg("room_max").toInt();
    { String vt = server.arg("voice_trigger"); if (vt.length()) { voice_trigger = vt; voice_trigger_apply(); } }
    { String vf = server.arg("voice_floor"); if (vf.length()) { voice_floor = vf; } }
    { String cn = server.arg("computer_name"); if (cn.length()) { computer_name = cn; } }

    pmuIrq = true;
    buttoned_before = false;
    // Serial.println("now me in room " + room);
    b1_toggle, b2_toggle, b3_toggle, b4_toggle, b5_toggle, b6_toggle = 0;
     Serial.println(authorization);
    //call_the_president();
    remote_room();
    buttonMillis = millis();
    lastMillis = millis();
    setSportsFlag();
    settingPMU();
    pmuIrq = false;
    buttonMillis = millis();
    Serial.println("Called President at " + homebaseIP);
    server.send(200, "text/plain", "homebase ip is now " + homebaseIP);
  });
//  wifi_server();
  // battery/system voltage measurement is part of the library's PMU setup now
  readFile(FFat, "/bootreport.txt");
  if (returner == "success") {
    configRestore();
    Serial.println("After the restore");
  }
  else if (returner != "epic_failure") {
    writeFile(FFat, "/bootreport.txt", "epic_failure");
    configRestoreBackup();
    configRestore();
  }
  // what the hardware clock holds at boot: the watch face reads it directly,
  // so a wrong morning clock shows up here before anything else can fix it
  {
    struct tm boot_tm = {};
    watch.rtc.getDateTime(&boot_tm);
    Serial.printf("[rtc] boot clock %04d-%02d-%02d %02d:%02d:%02d\n",
                  boot_tm.tm_year + 1900, boot_tm.tm_mon + 1, boot_tm.tm_mday,
                  boot_tm.tm_hour, boot_tm.tm_min, boot_tm.tm_sec);
    if (boot_tm.tm_year + 1900 < 2024) {
      Serial.println("[rtc] the hardware clock is unset");
    }
  }
  lv_task_handler();

}

