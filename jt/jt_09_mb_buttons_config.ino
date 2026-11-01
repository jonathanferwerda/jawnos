void mb1(lv_event_t *e) {
  if (b1_toggle == 0) {
    b1_toggle = 1;
  } else {
    b1_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=1&toggle=" + b1_toggle;
  if (tap_over_ble(1, b1_toggle, r)) {
    return;   // the bridge carries the tap; no blocking TLS round trip
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 1;
    updater["toggle"] = b1_toggle;
    when_i_get_in(updater, r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b1_toggle = result["toggle"];

  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b1_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);

  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 1)] = result;
  before_me = JSON.stringify(bm);

}
void mb2(lv_event_t *e) {
  if (b2_toggle == 0) {
    b2_toggle = 1;
  } else {
    b2_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=2&toggle=" + b2_toggle;
  if (tap_over_ble(2, b2_toggle, r)) {
    return;
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 2;
    updater["toggle"] = b2_toggle;
    when_i_get_in(updater, r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b2_toggle = result["toggle"];
  lv_color_t c;
  lv_color_t t;
  lv_obj_t * b = lv_event_get_target_obj(e);
  if (b2_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 2)] = result;
  before_me = JSON.stringify(bm);
}
void mb3(lv_event_t *e) {
  if (b3_toggle == 0) {
    b3_toggle = 1;
  } else {
    b3_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=3&toggle=" + b3_toggle;
  if (tap_over_ble(3, b3_toggle, r)) {
    return;
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 3;
    updater["toggle"] = b3_toggle;
    when_i_get_in(updater, r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b3_toggle = result["toggle"];
  //Serial.println(b3_toggle);
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b3_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);

  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 3)] = result;
  before_me = JSON.stringify(bm);
}
void mb4(lv_event_t *e) {
  if (b4_toggle = 0) {
    b4_toggle = 1;
  } else {
    b4_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=4&toggle=" + b4_toggle;
  if (tap_over_ble(4, b4_toggle, r)) {
    return;
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 4;
    updater["toggle"] = b4_toggle;
    when_i_get_in(updater, r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b4_toggle = result["toggle"];
  lv_color_t c;
  lv_color_t t;
  lv_obj_t * b = lv_event_get_target_obj(e);
  if (b4_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 4)] = result;
  before_me = JSON.stringify(bm);

}
void mb5(lv_event_t *e) {
  if (b5_toggle == 0) {
    b5_toggle = 1;
  } else {
    b5_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=5&toggle=" + b5_toggle;
  if (tap_over_ble(5, b5_toggle, r)) {
    return;
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 5;
    updater["toggle"] = b5_toggle;
    when_i_get_in(updater, r);
    return;
  }
  JSONVar result = JSON.parse(https);
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b5_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 5)] = result;
  before_me = JSON.stringify(bm);
}
void mb6(lv_event_t *e) {
  if (b6_toggle == 0) {
    b6_toggle = 1;
  } else {
    b6_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=6&toggle=" + b6_toggle;
  if (tap_over_ble(6, b6_toggle, r)) {
    return;
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 6;
    updater["toggle"] = b6_toggle;
    when_i_get_in(updater, r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b6_toggle = result["toggle"];
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b6_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 8)] = result;
  before_me = JSON.stringify(bm);
}
void mb7(lv_event_t *e) {
  if (b7_toggle == 0) {
    b7_toggle = 1;
  } else {
    b7_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=7&toggle=" + b7_toggle;
  if (tap_over_ble(7, b7_toggle, r)) {
    return;
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 7;
    updater["toggle"] = b7_toggle;
    when_i_get_in(updater, r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b7_toggle = result["toggle"];
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b7_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 7)] = result;
  before_me = JSON.stringify(bm);
}
void mb8(lv_event_t *e) {
  if (b8_toggle == 0) {
    b8_toggle = 1;
  } else {
    b8_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=8&toggle=" + b8_toggle;
  if (tap_over_ble(8, b8_toggle, r)) {
    return;
  }
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 8;
    updater["toggle"] = b8_toggle;
    when_i_get_in(updater, r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b8_toggle = result["toggle"];
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b8_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 8)] = result;
  before_me = JSON.stringify(bm);
}

static void touch_button2(lv_event_t *e) {
  clock_writer();
}

void clock_writer() {
  //Serial.println("Started button2");
  jw_room = "watch";
  //Serial.println("Set Mode");


  display_exit();
  jw_room = "watch";
  // Serial.println("Display exited");
  delay(5);
  time_writer("now");
  // Serial.println("Done loop");
  delay(5);
  lastMillis = lastMillis - 1000;
  lv_task_handler();
}


void setting_room();   // the tab callback rebuilds the room

static void touch_button3(lv_event_t *e) {
  setting_room();
}
// The Set room used to be one wall of 40x40 buttons labelled cS/cR/cD/LAP/LWI.
// It is grouped now the way the watch's is: a tab row picks a page and each
// page holds only its own controls, with labels that say what they do.

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
static lv_obj_t *configure_slider(const char *text, int x, int y, int w,
                                  int min, int max, int value,
                                  void (*cb)(lv_event_t *)) {
  lv_obj_t *l = lv_label_create(lv_scr_act());
  lv_label_set_text(l, text);
  lv_obj_set_style_text_color(l, lv_color_make(255, 255, 255), LV_PART_MAIN);
  lv_obj_set_pos(l, x, y);
  lv_obj_t *s = lv_slider_create(lv_scr_act());
  lv_obj_set_pos(s, x, y + 18);
  lv_obj_set_width(s, w);
  lv_slider_set_range(s, min, max);
  lv_slider_set_value(s, value, LV_ANIM_OFF);
  lv_obj_add_event_cb(s, cb, LV_EVENT_VALUE_CHANGED, NULL);
  return s;
}

// one tab in the top row; the active page's tab is blue
static void configure_tab(const char *text, int index, int x) {
  lv_obj_t *b = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b, configure_page_select, LV_EVENT_CLICKED, (void *)(intptr_t)index);
  lv_obj_set_pos(b, x, 1);
  lv_obj_set_size(b, 100, 38);
  lv_obj_set_style_bg_color(b, lv_color_hex(index == configure_page ? 0x61b3ff : 0x333333), LV_PART_MAIN);
  lv_obj_t *l = lv_label_create(b);
  lv_label_set_text(l, text);
  lv_obj_set_style_text_color(l, lv_color_make(255, 255, 255), LV_PART_MAIN);
  lv_obj_center(l);
}

static void lightSleep_toggle(lv_event_t *e) {
  lv_obj_t *sleep_button = lv_event_get_target_obj(e);
  lightSleep = !lightSleep;
  lv_obj_set_style_bg_color(sleep_button,
                            lv_color_hex(lightSleep ? 0x5afcdd : 0xb0b0b0), LV_PART_MAIN);
  configSave();
  deckLog("[sleep] mode %s", lightSleep ? "on" : "off");
}

void setting_room() {
  display_exit();
  jw_room = "configure";
  configure_tab("Screen", 0, 2);
  configure_tab("Radio", 1, 110);
  configure_tab("System", 2, 218);

  switch (configure_page) {
    case 0:
      // what the deck feels like: the two level sliders and the typewriter font
      configure_slider("Bright", 10, 46, 300, 1, 16, brightnessLevel,
                       brightness_event_cb);
      configure_slider("Volume", 10, 90, 300, 0, 21, volumeLevel,
                       volume_event_cb);
      {
        lv_obj_t *l = lv_label_create(lv_scr_act());
        lv_label_set_text(l, "Font");
        lv_obj_set_style_text_color(l, lv_color_make(255, 255, 255), LV_PART_MAIN);
        lv_obj_set_pos(l, 10, 134);
        lv_obj_t *fontdd = lv_dropdown_create(lv_scr_act());
        lv_dropdown_set_options(fontdd,
                                "Basic\n"
                                "Noto Small\n"
                                "Noto Large\n"
                                "Final Frontier\n"
                                "Latin\n"
                                "Unicode\n"
                               );
        lv_dropdown_set_text(fontdd, fontSelect.c_str());
        lv_obj_add_event_cb(fontdd, fontPicker, LV_EVENT_VALUE_CHANGED, NULL);
        lv_obj_set_pos(fontdd, 10, 152);
        lv_obj_set_size(fontdd, 150, 38);
        lv_obj_set_style_bg_color(fontdd, lv_color_hex(0xda5dc4), LV_PART_MAIN);
      }
      configure_slider("Size", 172, 134, 138, 1, 6, fontSize, fontSizeChanger);
      break;
    case 1:
      // the LoRa radio: broadcast/receive, and blasting the AP or wifi creds
      configure_button("LoRa Tx", loraBroadcastToggle, 10, 46, 145, 56,
                       lv_color_hex(loraChatBroadcaster ? 0x53ff24 : 0xb0b0b0));
      configure_button("LoRa Rx", loraReceiveToggle, 165, 46, 145, 56,
                       lv_color_hex(loraChatReceiver ? 0x53ff24 : 0xb0b0b0));
      configure_button("AP Send", ap_lora_send, 10, 112, 145, 56, lv_color_hex(0xdafc5d));
      configure_button("WiFi Send", wifi_lora_send, 165, 112, 145, 56, lv_color_hex(0xdafc5d));
      break;
    default:
      // power, the config file, and clearing the typewriter. Two columns over
      // two short rows, then Delete full width, all above the Rom/Clk/Set/Net
      // row that button_writer() draws along the bottom of every room (y=200).
      configure_button("Sleep", lightSleep_toggle, 10, 46, 145, 42,
                       lv_color_hex(lightSleep ? 0x5afcdd : 0xb0b0b0));
      configure_button("Save", configSaveButton, 165, 46, 145, 42, lv_color_hex(0x61b3ff));
      configure_button("Restore", configRestoreButton, 10, 92, 145, 42, lv_color_hex(0xffca38));
      configure_button("Clear Text", clear_typewriter, 165, 92, 145, 42, lv_color_hex(0xd63a9b));
      configure_button("Delete", configDeleteButton, 10, 138, 300, 42, lv_color_hex(0xde2716));
      break;
  }
  lv_task_handler();
}

