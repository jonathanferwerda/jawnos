void clock_writer() {
  uint32_t draw_started = millis();
  display_exit();

  delay(5);
  if (jw_room != "watch") {
    time_writer("now");
  }
  jw_room = "watch";

  notification_btn = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(notification_btn, notification_button, LV_EVENT_CLICKED, NULL);
  // square-ish and raised to y=136 so the row clearly clears the app row at
  // y=190 (the height is 50 x 40 now that it is a little shorter)
  lv_obj_set_pos(notification_btn, 190, 136 );
  lv_obj_set_size(notification_btn, 50, 40 );
  lv_obj_set_style_bg_color(notification_btn, lv_color_hex(0xde2716), LV_PART_MAIN);

  lv_obj_t *l1;
  lv_color_t t1;
  t1 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(notification_btn, t1, LV_PART_MAIN);
  l1 = lv_label_create(notification_btn);
  lv_label_set_text(l1, "Not");
  lv_obj_center(l1);


  recbtn1 = lv_btn_create(lv_scr_act());
  lv_obj_set_size(recbtn1, 50, 40);
  lv_obj_set_pos(recbtn1, 0, 136 );
  lv_obj_add_event_cb(recbtn1, audio_button, LV_EVENT_ALL, NULL);
  lv_obj_set_style_bg_color(recbtn1, lv_color_hex(0x5ec1ff), LV_PART_MAIN);

  // Attach the text label directly inside the button layout
  lv_obj_t * label = lv_label_create(recbtn1);
  lv_label_set_text(label, "Rec");
  lv_obj_center(label);

  playbtn1 = lv_btn_create(lv_scr_act());
  lv_obj_set_size(playbtn1, 50, 40);
  lv_obj_set_pos(playbtn1, 60, 136 );
  lv_obj_add_event_cb(playbtn1, audio_button, LV_EVENT_ALL, NULL);
  lv_obj_set_style_bg_color(playbtn1, lv_color_hex(0x5df796), LV_PART_MAIN);

  lv_obj_t * label_play = lv_label_create(playbtn1);
  lv_label_set_text(label_play, "Play");
  lv_obj_center(label_play);

  wigi_btn = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(wigi_btn, wigi_button, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(wigi_btn, 130, 136 );
  lv_obj_set_size(wigi_btn, 50, 40 );
  lv_obj_set_style_bg_color(wigi_btn, lv_color_hex(0x27de16), LV_PART_MAIN);

  lv_obj_t *l2;
  lv_color_t t2;
  t2 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(wigi_btn, t2, LV_PART_MAIN);
  l2 = lv_label_create(wigi_btn);
  lv_label_set_text(l2, "Wigi");
  lv_obj_center(l2);
  // the clock room carries the wigi indicator now; time_writer keeps it honest
  wigi_count_label = l2;
  update_wigi_indicator();

  delay(5);
  lastMillis = lastMillis - 1000;
  if (notification_viewing == 1) {
    notification_review();

  }
  full_refresh();
  if (millis() - draw_started > 80) {
    Serial.printf("[draw] clock %u ms\n", millis() - draw_started);
  }
}
static void wigi_button(lv_event_t *e) {
  homebasePing();
}
static void notification_button(lv_event_t *e) {
  int notification_count = notifications.length();
  if (notification_count > 0) {
    if (notification_viewing == 1) {
      if (notification_view >= notification_count - 1) {
        notification_view = 0;
      }
      else {
        notification_view++;
      }
    }
    notification_viewing = 1;
    clock_writer();
  }
  

}

void notification_review() {
  int notification_count = notifications.length();
  if (notification_count > 0 && notification_viewing == 1) {
    JSONVar notification = notifications[notification_view];
    if (!notification_lines[0]) {
      notification_lines[0] = face_label_maker(20, 24, &lv_font_montserrat_20, lv_color_hex(0xFFFFFF));
      notification_lines[1] = face_label_maker(20, 60, &lv_font_montserrat_16, lv_color_hex(0xFFFFFF));
      notification_lines[2] = face_label_maker(20, 90, &lv_font_montserrat_16, lv_color_hex(0xFFFFFF));
      notification_lines[3] = face_label_maker(20, 112, &lv_font_montserrat_16, lv_color_hex(0xFFFFFF));
    }
    String noti = "Notification " + String((notification_view + 1)) + "/" + String(notification_count);
    lv_label_set_text(notification_lines[0], noti.c_str());
    lv_obj_set_style_text_color(notification_lines[0],
      lv_color_make((uint8_t)notification["rgb"][0], (uint8_t)notification["rgb"][1], (uint8_t)notification["rgb"][2]), LV_PART_MAIN);

    String f_time = notification["formatted_time"];
    lv_label_set_text(notification_lines[1], f_time.c_str());

    String n_title = notification["title"];
    lv_label_set_text(notification_lines[2], n_title.c_str());
    String n = notification["notification"];
    lv_label_set_text(notification_lines[3], n.c_str());
  }
}

static void touch_button3(lv_event_t *e) {
  setting_room();
}
// The Set room used to be one 240x240 screen holding three sliders and a
// dozen 40x40 buttons labelled LAP/LWI/cS/cR/cD/... all at once. It is grouped
// now: a tab row picks a page and each page holds only its own controls, with
// room to hit them.
void setting_room();   // the tab callback rebuilds the room

static int configure_page = 0;

static void configure_page_select(lv_event_t *e) {
  int page = (int)(intptr_t)lv_event_get_user_data(e);
  if (page == configure_page) {
    return;
  }
  configure_page = page;
  setting_room();
}

// a labelled button in the Set room's content area
static lv_obj_t *configure_button(const char *text, void (*cb)(lv_event_t *),
                                  int x, int y, int w, int h, lv_color_t colour) {
  lv_obj_t *b = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b, cb, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b, x, y);
  lv_obj_set_size(b, w, h);
  lv_obj_set_style_bg_color(b, colour, LV_PART_MAIN);
  lv_obj_t *l = lv_label_create(b);
  lv_label_set_text(l, text);
  lv_obj_set_style_text_color(l, lv_color_make(0, 0, 0), LV_PART_MAIN);
  lv_obj_center(l);
  return b;
}

// a labelled slider: the name sits above a full-width track (easy to drag)
static lv_obj_t *configure_slider(const char *text, int y, int value,
                                  void (*cb)(lv_event_t *)) {
  lv_obj_t *l = lv_label_create(lv_scr_act());
  lv_label_set_text(l, text);
  lv_obj_set_style_text_color(l, lv_color_make(255, 255, 255), LV_PART_MAIN);
  lv_obj_set_pos(l, 10, y);
  lv_obj_t *s = lv_slider_create(lv_scr_act());
  lv_obj_set_pos(s, 10, y + 18);
  lv_obj_set_width(s, 220);
  lv_slider_set_range(s, 0, 100);
  lv_slider_set_value(s, value, LV_ANIM_OFF);
  lv_obj_add_event_cb(s, cb, LV_EVENT_VALUE_CHANGED, NULL);
  return s;
}

// one tab in the top row; the active page's tab is blue
static void configure_tab(const char *text, int index, int x) {
  lv_obj_t *b = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b, configure_page_select, LV_EVENT_CLICKED, (void *)(intptr_t)index);
  lv_obj_set_pos(b, x, 1);
  lv_obj_set_size(b, 78, 38);
  lv_obj_set_style_bg_color(b, lv_color_hex(index == configure_page ? 0x61b3ff : 0x333333), LV_PART_MAIN);
  lv_obj_t *l = lv_label_create(b);
  lv_label_set_text(l, text);
  lv_obj_set_style_text_font(l, &lv_font_montserrat_16, LV_PART_MAIN);
  lv_obj_set_style_text_color(l, lv_color_make(255, 255, 255), LV_PART_MAIN);
  lv_obj_center(l);
}

void setting_room() {
  display_exit();
  jw_room = "configure";
  configure_tab("Screen", 0, 2);
  configure_tab("Radio", 1, 82);
  configure_tab("System", 2, 162);

  switch (configure_page) {
    case 0:
      // what the watch feels like: the three level sliders, plus two toggles
      configure_slider("Bright", 42, brightnessLevel, brightness_event_cb);
      configure_slider("Volume", 74, volumeLevel, volume_event_cb);
      configure_slider("Vibrate", 106, vibrateLevel, vibrate_event_cb);
      configure_button("Rotate", screenRotate, 10, 142, 70, 44, lv_color_hex(0xff8923));
      configure_button("Steps", step_control, 90, 142, 70, 44,
                       lv_color_hex(stepCounter ? 0x5afcdd : 0xb0b0b0));
      break;
    case 1:
      // the LoRa radio: broadcast/receive, and blasting the AP or wifi creds
      configure_button("LoRa Tx", loraBroadcastToggle, 10, 46, 105, 56,
                       lv_color_hex(loraChatBroadcaster ? 0x53ff24 : 0xb0b0b0));
      configure_button("LoRa Rx", loraReceiveToggle, 125, 46, 105, 56,
                       lv_color_hex(loraChatReceiver ? 0x53ff24 : 0xb0b0b0));
      configure_button("AP Send", ap_lora_send, 10, 110, 105, 56, lv_color_hex(0xdafc5d));
      configure_button("WiFi Send", wifi_lora_send, 125, 110, 105, 56, lv_color_hex(0xdafc5d));
      break;
    default:
      // power, voice, and the config file. Two columns over three short rows so
      // the whole page stays above the Rom/Clk/Set/Net row that button_writer()
      // draws along the bottom of every room (y=190); a full-width Voice button
      // at the old y=174 sat on top of it.
      configure_button("Sleep", lightSleep_toggle, 10, 46, 105, 42,
                       lv_color_hex(lightSleep ? 0x5afcdd : 0xb0b0b0));
      configure_button("Voice", voice_control, 125, 46, 105, 42,
                       lv_color_hex(voiceCaptureEnabled ? 0x5afcdd : 0xb0b0b0));
      configure_button("Save", configSaveButton, 10, 92, 105, 42, lv_color_hex(0x61b3ff));
      configure_button("Restore", configRestoreButton, 125, 92, 105, 42, lv_color_hex(0xffca38));
      configure_button("Delete", configDeleteButton, 10, 138, 220, 42, lv_color_hex(0xde2716));
      break;
  }
  full_refresh();
}

static void step_control(lv_event_t *e) {
  lv_obj_t * pd_button = lv_event_get_target_obj(e);

  if (stepCounter == true) {
    lv_obj_set_style_bg_color(pd_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    stepCounter = false;    // the pedometer keeps counting, samples just stop
  }
  else {
    lv_obj_set_style_bg_color(pd_button, lv_color_hex(0x5afcdd), LV_PART_MAIN);
    stepCounter = true;
  }
}

static void lightSleep_toggle(lv_event_t *e) {
  lv_obj_t * sleep_button = lv_event_get_target_obj(e);  

  if (lightSleep == true) {
    lv_obj_set_style_bg_color(sleep_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    lightSleep = false;
  }
  else {
    lv_obj_set_style_bg_color(sleep_button, lv_color_hex(0x5afcdd), LV_PART_MAIN);
    lightSleep = true;
  }
}

static void configSaveButton(lv_event_t *e) {
  configSave();
  configSaveBackup();
}

static void configRestoreButton(lv_event_t *e) {
  configRestore();
  setting_room();
}

static void configDeleteButton(lv_event_t *e) {
  configDelete();
}

static void screenRotate(lv_event_t *e) {
  if (screenRotation >= 3) {
    screenRotation = 0;
  } else {
    screenRotation++;
  }
  // the board rotation is decided when beginLvglHelper() ran, so tell LVGL too
  lv_display_set_rotation(lv_display_get_default(), (lv_display_rotation_t)screenRotation);
  watch.decrementBrightness(0);
  configSave();
  configRestore();
  watch.incrementalBrightness(brightnessLevel);

}

static void loraBroadcastToggle(lv_event_t *e) {
  lv_obj_t * lora_button = lv_event_get_target_obj(e);  
  if (loraChatBroadcaster == false) {
    lv_obj_set_style_bg_color(lora_button, lv_color_hex(0x53ff24), LV_PART_MAIN);
    loraChatBroadcaster = true;

  }
  else {
    lv_obj_set_style_bg_color(lora_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    loraChatBroadcaster = false;

  }
}

static void loraReceiveToggle(lv_event_t *e) {
  lv_obj_t * lora_button = lv_event_get_target_obj(e);  
  if (loraChatReceiver == false) {
    lv_obj_set_style_bg_color(lora_button, lv_color_hex(0x53ff24), LV_PART_MAIN);
    loraChatReceiver = true;
  }
  else {
    lv_obj_set_style_bg_color(lora_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    loraChatReceiver = false;
  }
}

static void ap_lora_send(lv_event_t *e) {

  JSONVar pa;
  pa["ap_ssid"] = ap_ssid;
  pa["ap_password"] = ap_password;
  String public_announcement = JSON.stringify(pa);
  radio.startTransmit(public_announcement);
  //Serial.print(public_announcement);
}


static void wifi_lora_send(lv_event_t *e) {

  JSONVar pa;
  pa["ap_ssid"] = ssid;
  pa["ap_password"] = password;
  String public_announcement = JSON.stringify(pa);
  radio.startTransmit(public_announcement);
  //Serial.print(public_announcement);
}

static void bt_control(lv_event_t *e) {
  lv_obj_t * bt_button = lv_event_get_target_obj(e);
  // key on the preference, not the radio: a light sleep can leave the radio down
  // while the preference is still on, and the button must be able to turn it off
  if (bt_enabled == true) {
    bt_enabled = false;
    ble_restore_at = 0;       // a pending restore must not undo the press
    stop_ble_transfer();
    lv_obj_set_style_bg_color(bt_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  else {
    bt_enabled = true;
    ble_start_async();      // never block the button-press on the stack coming up

    lv_obj_set_style_bg_color(bt_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
}

static void wifi_ap_control(lv_event_t *e) {
  lv_obj_t * wifi_ap_button = lv_event_get_target_obj(e);
  if (wifi_ap_enabled == true) {
    accesspoint_stop();
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    
  }
  else {
    accesspoint_start();
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
}

void accesspoint_start() {
  if (wifi_ap_enabled == false) {
    IPAddress gw_ip(192, 168, 3, 1);
    IPAddress ip(192, 168, 3, 1);
    IPAddress subnet(255, 255, 255, 0);
    if (wifi_update != "") {
      JSONVar wifi = JSON.parse(wifi_update);
      ap_ssid = (const char *)wifi["ap_ssid"];
      ap_password = (const char *)wifi["ap_password"];
    }
    // the config has to be in place before the AP comes up, otherwise the AP
    // hands out the default 192.168.4.1 instead of our subnet
    WiFi.softAPConfig(ip, gw_ip, subnet);
    if (WiFi.softAP(ap_ssid, ap_password)) {
      server.begin();
      webserver_enabled = true;
      wifi_ap_enabled = true;
      apIP = WiFi.softAPIP();
    }
  }
}

void accesspoint_stop() {
  if (wifi_ap_enabled == true) {
    WiFi.softAPdisconnect(true);
    wifi_ap_enabled = false;
    if (wifi_enabled == false) {
      webserver_enabled = false;
      server.stop();

    }
  }
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
      wifi_enabled = false;
      if (wifi_ap_enabled == false) {
        server.stop();
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
  watch.setBrightness(brightnessLevel);

}

static void vibrate_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target_obj(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  vibrateLevel = level;
  watch.setHapticEffects(vibrateLevel);
  watch.vibrator();
}

static void volume_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target_obj(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  volumeLevel = level;
}


void touch_watch() {
  // LVGL counts every press, hold and drag as input activity, so a long touch on
  // a slider keeps the screen awake; the board's touch IRQ bit alone would not.
  if (lv_display_get_inactive_time(NULL) < 1000) {
    buttonMillis = millis();
    wrist_look_watch = false;   // a touch hands the glance back to the timeout
  }
}

// Reads (and clears) the PMU interrupt status registers; true when one of the
// latched events wants the crown. Used as a fallback for the interrupt path.
static bool crown_irq_pending() {
  uint64_t status = watch.pmic.irq().readStatus();
  return watch.pmic.irq().isPekeyShortPress(status) ||
         watch.pmic.irq().isPekeyLongPress(status);
}

static void doze_until_crown() {
  setCpuFrequencyMhz(80);
  //my_print("=========esp_light_sleep_start=========\n");
  char count = 0;
  uint32_t started_ms = millis();
  Serial.println("[doze] enter");
  dozing = true;
  wristPollReset();
  uint32_t crown_at = 0;

  while (!pmuIrq) {
    sportsIrq = false;      // movement must not light the screen back up either
    if (jw_room == "message") {
      if (buttonMillis != 0  && millis() - buttonMillis > DEFAULT_SCREEN_TIMEOUT && count > 58) {
        lowPowerEnergyHandler();
        count = 0;
      }

      else {
        count++;
      }
    }
    if (webserver_enabled == true) {
      server.handleClient();
    }
    watch.loop();             // the PMU and sensor events arrive through here
    if (!pmuIrq && crown_irq_pending()) {
      // the AXP2101 latches crown presses in its IRQ status registers; reading
      // them here catches a press even if the interrupt path missed it
      Serial.println("[doze] crown caught by the status poll");
      pmuIrq = true;
    }
    awake_notifications();
    readRadio();
    tilt_serial_poll();       // the console stays reachable while dozing
    if (tiltDbg) {
      tilt_dbg_stream();
    }
    // The beat between the housekeeping passes above is spent sampling the
    // wrist: the raise is the only thing that can turn the screen back on, and
    // nothing announces it (any-motion detection crashed the radio, see
    // settingSensor). ~25 Hz costs a few I2C reads a second and the sensor is
    // running anyway; the crown is re-checked inside the beat so a press is
    // not held up by the sampling.
    uint32_t beat_end = millis() + (tiltDbg ? 20 : 500);
    while (!pmuIrq && (int32_t)(beat_end - millis()) > 0) {
      if (wristPoll()) {
        // the arm came up while dozing: end the doze the way a crown click would
        Serial.println("[tilt] wrist raise: lighting the screen");
        tilt_wake_short = true;
        pmuIrq = true;
        break;
      }
      if (millis() - crown_at >= 150) {
        crown_at = millis();
        if (crown_irq_pending()) {
          Serial.println("[doze] crown caught by the status poll");
          pmuIrq = true;
          break;
        }
      }
      delay(15);
    }
    // gpio_wakeup_enable ((gpio_num_t)BOARD_TOUCH_INT, GPIO_INTR_LOW_LEVEL);
    // esp_sleep_enable_timer_wakeup(3 * 1000);
    // esp_light_sleep_start();
  }
  Serial.printf("[doze] exit after %u ms\n", millis() - started_ms);
  dozing = false;
  //my_print("=========esp_light_sleep_start=========\n");
}

