void jawn_setup() {
  Serial.begin(115200);
  delay(50);
  jh_log("[jh] boot: JawnHat %s (reset %d, chip %s)", JAWN_FW_VERSION,
         (int)esp_reset_reason(), chip_id_maker().c_str());

  // mbedTLS's ~16 KB handshake buffers come from PSRAM (see jh_01_globals.ino).
  // Install this before anything opens a TLS client.
  mbedtls_platform_set_calloc_free(jh_psram_calloc, jh_psram_free);
  // Keep internal RAM for the radio and the DMA: ordinary allocations of 64
  // bytes or more prefer the PSRAM. This is the deck's rule, and this board has
  // the same split between a small internal heap and a large external one.
  heap_caps_malloc_extmem_enable(64);

  // The power profile. 80 MHz is the lowest clock the radio and I2S run at, and
  // the hat is idle most of the time; the runtime call is what actually moves
  // the clock because the Arduino framework is precompiled at 240 MHz. See the
  // note in platformio.ini. Light sleep between commands is phase 1: it cannot
  // be entered while the BLE link is expected to answer instantly.
  setCpuFrequencyMhz(80);
  jh_log("[jh] cpu: %u MHz", (unsigned)getCpuFrequencyMhz());

  // config_restore() mounts FFat and falls back to defaults when the filesystem
  // or the file is missing. It is deliberately first: the camera and the OTA
  // rail both read the house URL and token it restores.
  config_restore();
  jh_log("[jh] config: house=%s token=%s ssid=%s", jh_house_url.length() ? "set" : "none",
         jh_house_token.length() ? "set" : "none", jh_ssid.length() ? jh_ssid.c_str() : "none");

  // Every peripheral logs its own failure and lets the boot continue. A hat with
  // a dead camera should still answer BLE and report its version; refusing to
  // boot would hide the failure behind a reboot loop.
  camera_init();
  audio_out_init();
  imu_init();
  haptics_init();
  voice_in_init();

  // WiFi is the camera/OTA rail, and it is optional: a hat with no ssid still
  // takes jh.* commands over BLE. Join asynchronously; ota_loop() retries and
  // starts the HTTP rails once association completes.
  if (jh_wifi_enabled && jh_ssid.length()) {
    WiFi.mode(WIFI_STA);
    // Modem sleep is the difference between a background radio and a heater on
    // a battery this size. It costs latency, which is acceptable for a frame
    // POST and an OTA sweep.
    WiFi.setSleep(true);
    WiFi.begin(jh_ssid.c_str(), jh_password.c_str());
    jh_log("[jh] wifi: joining %s (async)", jh_ssid.c_str());
  }
  else {
    jh_log("[jh] wifi: no ssid configured; camera POST and OTA are offline");
  }

  // The BLE stack is started from loop() once the boot has settled: bringing it
  // up inside setup() panicked the deck's boards, and the same stack is used
  // here. ble_loop() owns the deferred start.
  ble_arm_start();
  ota_start();

  jh_log("[jh] boot: done, heap=%u psram=%u", (unsigned)ESP.getFreeHeap(),
         (unsigned)ESP.getFreePsram());
  jh_log("[jh] provision with: JHCONF url <url> | token <bearer> | ssid <ssid>");
}
