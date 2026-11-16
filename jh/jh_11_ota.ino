// ---- OTA: the version the house sweeps for, and the /update rail -------------
// The manager's firmware sweep asks a board for /device_query over HTTP and
// compares the "version" it reports with the image it has staged. JAWN_FW_VERSION
// is compiled in by scripts/fw_version.py from jh/VERSION, so this reply is the
// whole reason the hat has a web server at all. /update is the same multipart
// rail the deck uses; it is refused unless the Authorization header matches the
// bearer in config.
//
// The port is 3000, the same as the deck and the watch, because that is what
// firmware_board_port() probes. The server starts only once WiFi associates:
// starting it in setup() would either fail or answer on a link that is not up.
static WebServer jh_ota_server(3000);
static bool jh_ota_web_up = false;
static bool jh_ota_refused = false;
static uint32_t jh_net_retry_at = 0;

static void ota_upload() {
  HTTPUpload &upload = jh_ota_server.upload();
  if (upload.status == UPLOAD_FILE_START) {
    String rauth = jh_ota_server.header("authorization");
    if (rauth == "") {
      rauth = jh_ota_server.arg("authorization");
    }
    if (jh_house_token.length() == 0 || rauth != jh_house_token) {
      jh_ota_refused = true;
      jh_log("[ota] refused (authorization)");
      return;
    }
    jh_log("[ota] receiving %s", upload.filename.c_str());
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
      jh_log("[ota] written; rebooting");
    }
    else {
      Update.printError(Serial);
    }
  }
}

void ota_start() {
  jh_log("[ota] build %s; /device_query on port 3000 once wifi is up", JAWN_FW_VERSION);
}

void ota_loop() {
  // Retry the station link while it is configured and down. A hat on a desk
  // outlives its router's DHCP lease; a silent radio is a support call.
  if (jh_wifi_enabled && jh_ssid.length() && WiFi.status() != WL_CONNECTED) {
    if ((int32_t)(millis() - jh_net_retry_at) >= 0) {
      jh_net_retry_at = millis() + 15000;
      WiFi.disconnect();
      WiFi.begin(jh_ssid.c_str(), jh_password.c_str());
      jh_log("[net] retry join %s", jh_ssid.c_str());
    }
  }

  if (!jh_ota_web_up && WiFi.status() == WL_CONNECTED) {
    const char *headers[] = { "authorization" };
    jh_ota_server.collectHeaders(headers, 1);
    jh_ota_server.on("/device_query", []() {
      JSONVar g;
      g["chip_id"] = chip_id_maker();
      // The manager's fleet and OTA sweeps know watch, teletype and
      // microcontroller today. A hat is closest to a microcontroller board;
      // a dedicated purpose is a house-side change (Ble.pm's map and the
      // Embedded view), not something this firmware can invent and have
      // recognized. The "hat" flag below is the honest marker for phase 1.
      g["purpose"] = "microcontroller";
      g["name"] = jh_device_name;
      g["version"] = JAWN_FW_VERSION;
      g["mac_addresses"] = printAllMacAddresses();
      g["uptime"] = millis();
      g["hat"] = true;
      jh_ota_server.send(200, "text/plain", JSON.stringify(g));
    });
    jh_ota_server.on("/update", HTTP_POST, []() {
      jh_ota_server.sendHeader("Connection", "close");
      if (jh_ota_refused) {
        jh_ota_refused = false;
        jh_ota_server.send(403, "text/plain", "no");
        return;
      }
      jh_ota_server.send(200, "text/plain", Update.hasError() ? "failed" : "ok");
      delay(500);
      ESP.restart();
    }, ota_upload);
    jh_ota_server.begin();
    jh_ota_web_up = true;
    jh_log("[net] http on %s:3000", WiFi.localIP().toString().c_str());
  }

  if (jh_ota_web_up) {
    jh_ota_server.handleClient();
  }
}
