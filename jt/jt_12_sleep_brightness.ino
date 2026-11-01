// ---- Sleep mode ---------------------------------------------------------
//
// The panel has already been darkened and put into its own sleep command when
// this runs. The rest of the deck is still a 240 MHz CPU with WiFi, Bluetooth,
// LoRa receive and the microphone DMA all live, which is why the battery went
// so quickly. Here the radios and the microphone are stopped and the chip spends
// the idle time in ESP light sleep, waking on a touch, a key, a move of the
// trackball, or a short timer so the keyboard and touch can be polled.
//
// A deck on USB keeps its radios (battery is not the concern there) and only
// drops its clock; light sleep would also be refused by the USB peripheral.
#define DECK_SLEEP_POLL_MS 250

// The same five lines the trackball loop reads: the four directions and the
// press. They idle high, so a low level is a move or a press.
static const uint8_t deck_sleep_wake_pins[] = {
  BOARD_TBOX_G04, BOARD_TBOX_G02, BOARD_TBOX_G01, BOARD_TBOX_G03, BOARD_BOOT_PIN
};
// The panel and keyboard interrupt lines are armed only when they read high at
// entry: a line the board leaves low would bounce the nap straight back up.
static const uint8_t deck_sleep_irq_pins[] = {BOARD_TOUCH_INT, BOARD_KEYBOARD_INT};

static void deck_sleep_arm_wake() {
  for (uint8_t i = 0; i < sizeof(deck_sleep_wake_pins); ++i) {
    gpio_wakeup_enable((gpio_num_t)deck_sleep_wake_pins[i], GPIO_INTR_LOW_LEVEL);
  }
  for (uint8_t i = 0; i < sizeof(deck_sleep_irq_pins); ++i) {
    if (digitalRead(deck_sleep_irq_pins[i])) {
      gpio_wakeup_enable((gpio_num_t)deck_sleep_irq_pins[i], GPIO_INTR_LOW_LEVEL);
    }
  }
  esp_sleep_enable_gpio_wakeup();
}

static void deck_sleep_disarm_wake() {
  for (uint8_t i = 0; i < sizeof(deck_sleep_wake_pins); ++i) {
    gpio_wakeup_disable((gpio_num_t)deck_sleep_wake_pins[i]);
  }
  for (uint8_t i = 0; i < sizeof(deck_sleep_irq_pins); ++i) {
    gpio_wakeup_disable((gpio_num_t)deck_sleep_irq_pins[i]);
  }
}

// True when something changed since the sleep began. The panel and keyboard
// have no usable level line here (the touch controller is polled, not
// interrupt-driven), so both are read over I2C at each wake.
static bool deck_sleep_input_seen(const uint8_t *pin_state) {
  for (uint8_t i = 0; i < sizeof(deck_sleep_wake_pins); ++i) {
    if (digitalRead(deck_sleep_wake_pins[i]) != pin_state[i]) {
      return true;
    }
  }
  if (touchDected) {
    int16_t x = 0, y = 0;
    if (getTouch(x, y)) {
      // the waking tap is over before LVGL reads the panel; keep it for
      // touchpad_read() rather than swallowing it here
      deck_wake_touch_x = x;
      deck_wake_touch_y = y;
      deck_wake_touch_pending = true;
      return true;
    }
  }
  if (kbDected) {
    char k = keypad_get_key();
    if (k) {
      deck_pending_key = k;
      return true;
    }
  }
  return false;
}

static void deck_low_power_sleep() {
  bool ble_up = ble_radio_up;
  bool wifi_on = (wifi_enabled && WiFi.status() == WL_CONNECTED);
  bool ap_on = wifi_ap_enabled;
  bool lora_rx = loraChatReceiver;
  // The pack sits above a full cell's rest voltage on USB (the same read the
  // battery report uses); light sleep is refused there anyway.
  bool deep = deck_battery_voltage() <= 4300.0f;
  bool ble_down = false, wifi_down = false, radio_down = false, mic_down = false;
  uint8_t pin_state[sizeof(deck_sleep_wake_pins)];
  for (uint8_t i = 0; i < sizeof(deck_sleep_wake_pins); ++i) {
    pin_state[i] = digitalRead(deck_sleep_wake_pins[i]);
  }

  // The failover worker may be in the middle of a TLS request; stopping WiFi
  // underneath it would strand it. Give it a moment to go quiet, and doze with
  // the radios up if it does not.
  if (deep && house_task_handle != NULL) {
    uint32_t t0 = millis();
    while (house_task_handle != NULL && millis() - t0 < 1500) {
      vTaskDelay(pdMS_TO_TICKS(20));
    }
    if (house_task_handle != NULL) {
      deep = false;
      deckLog("%s", "[sleep] house worker busy; dozing with radios up");
    }
  }

  if (deep) {
    // A listener owns the microphone DMA; stop it before the channel goes down
    // (loop() re-arms it after the wake when the Voice setting is still on).
    if (voiceTaskAlive) {
      voiceListening = false;
      uint32_t t0 = millis();
      while (voiceTaskAlive && millis() - t0 < 1000) { vTaskDelay(pdMS_TO_TICKS(20)); }
    }
    if (!voiceTaskAlive && mic_rx_handle) {
      // A listener still winding down owns the DMA; leave the channel alone and
      // let it exit rather than disabling it underneath a live read.
      i2s_channel_disable(mic_rx_handle);
      mic_down = true;
    }
    if (hasRadio) {
      radio.sleep();
      radio_down = true;
    }
    if (ble_up && pServer) {
      // Stop the link and advertising but keep the Bluedroid stack: a
      // deinit/init on every wake was what made the watch reboot, and the
      // controller initialised-but-idle is the safer nap (see AGENTS notes).
      for (int tries = 0; pServer->getConnectedCount() > 0 && tries < 20; tries++) {
        pServer->disconnect(pServer->getConnId());
        delay(20);
      }
      pServer->getAdvertising()->stop();
      ble_down = true;
    }
    if (wifi_on || ap_on) {
      if (ws_connected) { wsclient.close(); ws_connected = 0; }
      server.stop();
      webserver_enabled = false;
      WiFi.disconnect(true);
      WiFi.mode(WIFI_OFF);
      if (jawnos_mdns_up) { MDNS.end(); jawnos_mdns_up = false; }
      wifi_down = true;
    }
    deckLog("[sleep] light sleep; touch, key or trackball wakes it");
  }
  else {
    deckLog("%s", "[sleep] on USB: radios stay up, clock at 80 MHz");
  }

  if (deep || !voiceTaskAlive) {
    // A voice listener cannot keep up at 80 MHz; on USB it is left at 240.
    setCpuFrequencyMhz(80);
  }
  if (deep) { deck_sleep_arm_wake(); }

  uint8_t no_nap = 0;
  while (!deck_sleep_input_seen(pin_state)) {
    if (deep) {
      esp_sleep_enable_timer_wakeup((uint64_t)DECK_SLEEP_POLL_MS * 1000ULL);
      uint32_t nap_start = millis();
      esp_light_sleep_start();
      esp_sleep_wakeup_cause_t cause = esp_sleep_get_wakeup_cause();
      uint32_t slept = millis() - nap_start;
      // A refused nap returns at once with no cause (an attached USB serial
      // does this). After a few, poll at 80 MHz instead of spinning here.
      if (cause == ESP_SLEEP_WAKEUP_UNDEFINED || slept < 50) {
        if (++no_nap >= 5) {
          deckLog("%s", "[sleep] light sleep refused; polling at 80 MHz");
          deep = false;
          deck_sleep_disarm_wake();
        }
      }
      else {
        no_nap = 0;
      }
    }
    else {
      // On USB the panel and the housekeeping keep running (the screen is
      // simply dark): the deck still answers its web routes and the radio.
      if (webserver_enabled) { server.handleClient(); }
      if (ws_connected == 1) { wsclient.poll(); }
      readRadio();
      // Unplugged while dozing: wake once so the normal timeout can put the
      // deck into the real light sleep next time.
      static uint32_t voltage_check = 0;
      if (millis() - voltage_check > 5000) {
        voltage_check = millis();
        if (deck_battery_voltage() <= 4300.0f) { break; }
      }
      delay(50);
    }
  }

  if (deep) { deck_sleep_disarm_wake(); }
  setCpuFrequencyMhz(240);
  if (mic_down) { i2s_channel_enable(mic_rx_handle); }
  if (radio_down) {
    operationDone = false;
    if (lora_rx) { radio.startReceive(); }
    else { radio.standby(); }
  }
  // The bridge comes back after the panel: advertising off during the nap, on
  // again now, with the stack never torn down.
  if (ble_down && pServer) {
    pServer->getAdvertising()->start();
  }
  if (wifi_down) {
    if (ap_on) {
      WiFi.mode(wifi_on ? WIFI_AP_STA : WIFI_AP);
      accesspoint_start();
    }
    if (wifi_on) {
      if (!ap_on) { WiFi.mode(WIFI_STA); }
      WiFi.begin(ssid.c_str(), password.c_str());
      wifi_restore_pending = true;
    }
  }
  // tft.begin() in loop()'s wake branch resets the panel: repaint the room
  lv_obj_invalidate(lv_scr_act());
  deckLog("%s", "[sleep] awake");
}

static void wifi_control(lv_event_t *e) {
  lv_obj_t * wifi_button = lv_event_get_target_obj(e);
  if (wifi_enabled == true) {
    lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    WiFi.disconnect();
    if (wifi_ap_enabled == false) {
      webserver_enabled = false;
      server.stop();
    }
    wifi_enabled = false;
  }
  else {
    wifi_enabled = true;
    wifi_server();
    if (WiFi.status() == WL_CONNECTED) {
      server.begin();
      server.handleClient();
      lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
      webserver_enabled = true;
    }
    else {
      lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
      server.stop();
      wifi_enabled = false;
      if (wifi_ap_enabled == false) {
        webserver_enabled = false;
      }
    }
  }
}


static void brightness_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target_obj(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  brightnessLevel = level;
  setBrightness(brightnessLevel);

}

static void volume_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target_obj(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  volumeLevel = level;
  audio.setVolume(volumeLevel);

  setMasterVolume(level);
}

void setMasterVolume(int level) {

}

// configSave() runs on every screen sleep, but the picture usually has not
// changed: flashing the whole config each time wore the flash and stalled the UI
// (the config write blocks on the FFat that shares the display's SPI bus). The
// watch got this guard and its wake sped up a lot; the deck had none.
static String config_saved_sig;

// The clean-boot marker, read without readFile() (which appends to the shared
// `returner`). A read costs no flash wear, so only a dirty marker is rewritten.
static bool bootreport_is_clean() {
  File f = FFat.open("/bootreport.txt");
  if (!f || f.isDirectory()) {
    return false;
  }
  String r;
  while (f.available()) {
    r += (char)f.read();
  }
  f.close();
  r.trim();
  return r == "success";
}

