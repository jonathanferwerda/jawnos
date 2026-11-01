void setBrightness(uint8_t value)
{
  static uint8_t level = 0;
  static uint8_t steps = 16;
  currentBrightness = value;
  if (value != 0) {
    lastBrightness = value;
  }
  if (value == 0) {
    digitalWrite(BOARD_BL_PIN, 0);
    delay(3);
    level = 0;
    return;
  }
  if (level == 0) {
    digitalWrite(BOARD_BL_PIN, 1);
    level = steps;
    delayMicroseconds(30);
  }
  int from = steps - level;
  int to = steps - value;
  int num = (steps + to - from) % steps;
  for (int i = 0; i < num; i++) {
    digitalWrite(BOARD_BL_PIN, 0);
    digitalWrite(BOARD_BL_PIN, 1);
  }
  level = value;
}

static void disp_flush(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
  uint32_t w = ( area->x2 - area->x1 + 1 );
  uint32_t h = ( area->y2 - area->y1 + 1 );
  if ( xSemaphoreTake( xSemaphore, portMAX_DELAY ) == pdTRUE ) {
    tft.startWrite();
    tft.setAddrWindow( area->x1, area->y1, w, h );
    tft.pushColors( ( uint16_t * )px_map, w * h, false );
    tft.endWrite();
    lv_display_flush_ready( disp );
    xSemaphoreGive( xSemaphore );
  }
}

static bool getTouch(int16_t &x, int16_t &y)
{
  uint8_t rotation = tft.getRotation();
  if (!touch->read()) {
    return false;
  }
  TP_Point t = touch->getPoint(0);
  switch (rotation) {
    case 1:
      x = t.y;
      y = tft.height() - t.x;
      break;
    case 2:
      x = tft.width() - t.x;
      y = tft.height() - t.y;
      break;
    case 3:
      x = tft.width() - t.y;
      y = t.x;
      break;
    case 0:
    default:
      x = t.x;
      y = t.y;
  }
  // Serial.printf("R:%d X:%d Y:%d\n", rotation, x, y);
  // What the panel reported versus where LVGL will be told it happened, in case
  // a tap lands somewhere unexpected. Rate limited, only while a touch is held.
  static uint32_t lastTouchProbe = 0;
  if (millis() - lastTouchProbe > 700) {
    lastTouchProbe = millis();
    deckLog("[deck] touch raw %d,%d rot %d -> %d,%d", t.x, t.y, (int)rotation, x, y);
  }
  buttonMillis = millis();

  return true;
}

static void mouse_read(lv_indev_t *indev, lv_indev_data_t *data)
{
  // Serial.println("mouse read");
  static  int16_t last_x;
  static int16_t last_y;
  bool left_button_down = false;
  const uint8_t dir_pins[5] = {1, 2, 3, 15, 0
                              };
  static bool last_dir[5];
  uint8_t pos = 10;
  for (int i = 0; i < 5; i++) {
    bool dir = digitalRead(dir_pins[i]);
    if (dir != last_dir[i]) {
      last_dir[i] = dir;
    }
  }
  // Serial.printf("indev:X:%04d  Y:%04d \n", last_x, last_y);
  /*Store the collected data*/
  data->point.x = last_x;
  data->point.y = last_y;
  data->state = left_button_down ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;

}
/*Read the touchpad*/
static void touchpad_read( lv_indev_t *indev_driver, lv_indev_data_t *data )
{
  // A tap that woke the deck was read by the sleep poll (getTouch also syncs the
  // controller); hand that one to LVGL so the waking tap is not swallowed.
  if (deck_wake_touch_pending) {
    deck_wake_touch_pending = false;
    data->state = LV_INDEV_STATE_PR;
    data->point.x = deck_wake_touch_x;
    data->point.y = deck_wake_touch_y;
    return;
  }
  // Touch drives LVGL in every room. The room-specific handling that reads the
  // panel directly (the typewriter's websocket mouse, the room's button replay)
  // stays where it is in loop().
  // getTouch() takes references: writing into locals and never putting them
  // back left data->point at whatever LVGL had last, so every tap was a press
  // in the wrong place.
  int16_t x = data->point.x;
  int16_t y = data->point.y;
  data->state = getTouch(x, y) ? LV_INDEV_STATE_PR : LV_INDEV_STATE_REL;
  data->point.x = x;
  data->point.y = y;
}

void scanDevices(TwoWire * w)
{
  uint8_t err, addr;
  int nDevices = 0;
  uint32_t start = 0;
  for (addr = 1; addr < 127; addr++) {
    start = millis();
    w->beginTransmission(addr); delay(2);
    err = w->endTransmission();
    if (err == 0) {
      nDevices++;
      // Serial.print("I2C device found at address 0x");
      if (addr < 16) {
        // Serial.print("0");
      }
      //Serial.print(addr, HEX);
      //Serial.println(" !");

      if (addr == GT911_SLAVE_ADDRESS2) {
        touchAddress = GT911_SLAVE_ADDRESS2;
        // Serial.println("Find GT911 Drv Slave address: 0x14");
      } else if (addr == GT911_SLAVE_ADDRESS1) {
        touchAddress = GT911_SLAVE_ADDRESS1;
        //  Serial.println("Find GT911 Drv Slave address: 0x5D");
      }
    } else if (err == 4) {
      //Serial.print("Unknow error at address 0x");
      if (addr < 16) {
        //Serial.print("0");
      }
      //   Serial.println(addr, HEX);
    }
  }
  if (nDevices == 0) {
    //  Serial.println("No I2C devices found\n");
  }
}


void button_writer() {
  btn1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn1, touch_button1, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn1, 10, 200 );
  lv_obj_set_size(btn1, 40, 40 );
  lv_obj_set_style_bg_color(btn1, lv_color_hex(0xde2716), LV_PART_MAIN);

  lv_obj_t *l1;
  lv_color_t t1;
  t1 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn1, t1, LV_PART_MAIN);
  l1 = lv_label_create(btn1);
  lv_label_set_text(l1, "Rom");
  lv_obj_center(l1);


  btn2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn2, touch_button2, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn2, 60, 200 );
  lv_obj_set_size(btn2, 40, 40 );
  lv_obj_set_style_bg_color(btn2, lv_color_hex(0xffca38), LV_PART_MAIN);

  lv_obj_t *l2;
  lv_color_t t2;
  t2 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn2, t2, LV_PART_MAIN);
  l2 = lv_label_create(btn2);
  lv_label_set_text(l2, "Clk");
  lv_obj_center(l2);

  btn3 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn3, touch_button3, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn3, 110, 200 );
  lv_obj_set_size(btn3, 40, 40 );
  lv_obj_set_style_bg_color(btn3, lv_color_hex(0xfa3ced), LV_PART_MAIN);

  lv_obj_t *l3;
  lv_color_t t3;
  t3 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn3, t3, LV_PART_MAIN);
  l3 = lv_label_create(btn3);
  lv_label_set_text(l3, "Set");
  lv_obj_center(l3);

  btn4 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn4, touch_button4, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn4, 160, 200 );
  lv_obj_set_size(btn4, 40, 40 );
  lv_obj_set_style_bg_color(btn4, lv_color_hex(0xba3c2d), LV_PART_MAIN);

  lv_obj_t *l4;
  lv_color_t t4;
  t4 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn4, t4, LV_PART_MAIN);
  l4 = lv_label_create(btn4);
  lv_label_set_text(l4, "Cht");
  lv_obj_center(l4);

  btn5 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn5, touch_button5, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn5, 210, 200 );
  lv_obj_set_size(btn5, 40, 40 );
  lv_obj_set_style_bg_color(btn5, lv_color_hex(0xca1c2d), LV_PART_MAIN);

  lv_obj_t *l5;
  lv_color_t t5;
  t5 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn5, t5, LV_PART_MAIN);
  l5 = lv_label_create(btn5);
  lv_label_set_text(l5, "Pen");
  lv_obj_center(l5);

  btn6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn6, touch_button6, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn6, 260, 200 );
  lv_obj_set_size(btn6, 40, 40 );
  lv_obj_set_style_bg_color(btn6, lv_color_hex(0x1aacfd), LV_PART_MAIN);

  lv_obj_t *l6;
  lv_color_t t6;
  t6 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn6, t6, LV_PART_MAIN);
  l6 = lv_label_create(btn6);
  lv_label_set_text(l6, "Net");
  lv_obj_center(l6);

  lv_task_handler();
}

void call_the_president() {
  //  Serial.println("dans presidente");
  //  Serial.println(before_me);
  //  Serial.println("copy");
  JSONVar result;
  Serial.print("bb: " );
  Serial.println(buttoned_before);
  if (!buttoned_before && homebaseIP != "") {
    if (deviceConnected) {
      // the bridge is up: the phone fetches the room and pushes it back, so
      // this works anywhere the phone is, and it does not block the ui
      JSONVar req = JSON.parse("{}");
      req["type"] = "room_request";
      req["chip_id"] = chip_id_maker();
      req["edt"] = "teletype";
      req["room"] = room;
      ble_send(req);
      deckLog("[bt] room requested");
    }
    else {
      String req = "https://" + homebaseIP + "/watch?room=" + room;
      Serial.println(req);
      String watchRequest = https_request(req);
      Serial.println(watchRequest);
      if (watchRequest != "failure") {
        before_me = watchRequest;
        buttoned_before = true;
      }
    }
  }
  else {
    //  Serial.print("running first timer");
  }
  if (jw_room == "room") {
    // remote_room();
  }

  //Serial.println(before_me);
}

void presidents_title() {
  tft.setTextFont(4);

  tft.setTextColor(TFT_YELLOW, TFT_BLACK);
  tft.drawString(computer_name, 10, 2);
  tft.setTextFont(2);

  tft.drawString(homebaseIP, 180, 2);
}

void presidents_buttons() {
  JSONVar result;
  lv_obj_t * led1  = lv_led_create(lv_scr_act());
  lv_obj_set_pos(led1, 90, 160 );
  lv_led_set_color(led1, lv_palette_main(LV_PALETTE_RED));
  lv_obj_t * led2  = lv_label_create(lv_scr_act());
  lv_obj_set_pos(led2, 120, 160 );
  lv_obj_set_style_text_color(led2, lv_palette_main(LV_PALETTE_GREEN), LV_PART_MAIN); 
  lv_led_off(led1);
  if (!buttoned_before) {
    tft.drawString("Ne pas Presidente", 80, 80);
    lv_led_off(led1);
    return;
  }
  else {
    result = JSON.parse(before_me);
  }
  if (wigi.length() > 0) {
    lv_led_on(led1);
    int wl = wigi.length();
    char wil[4];
    itoa( wl, wil, 10 );
    lv_label_set_text(led2, wil);
  } 
  else {
    lv_label_set_text(led2, "0");
  }

  // one short line, not the whole room document: this runs on every redraw, and
  // dumping a 4.7 KB payload through the CDC from here was a real stall
  deckLog("[room] draw room=%d count=%d buttons=%d", room, room_count, (int)buttoned_before);
  if (room > room_count) { room = 1; }  

  int sb = ((room - 1) * 8) + 1;
  computer_name = (const char *)result["__specs"]["computer"];
  //Serial.println(room);
  //Serial.println(sb);
  lv_obj_t * b1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b1, mb1, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b1, 10, 20 );
  lv_obj_set_size(b1, 60, 60 );
  lv_color_t c1;
  lv_color_t t1;
  int tog1 = result["b" + String(sb)]["toggle"];

  if (tog1 == 1) {
    t1 = lv_color_make(0, 0, 0);
    c1 = lv_color_make(255, 255, 0);
  }
  else {
    c1 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t1 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b1, t1, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b1, c1, LV_PART_MAIN);
  lv_obj_t *l1;
  l1 = lv_label_create(b1);
  lv_label_set_text(l1, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l1, LV_LABEL_LONG_WRAP);
  lv_obj_center(l1);

  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b1_toggle);
  lv_obj_t * b2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b2, mb2, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b2, 90, 20 );
  lv_obj_set_size(b2, 60, 60 );
  lv_color_t c2;
  lv_color_t t2;
  int tog2 = result["b" + String(sb)]["toggle"];

  if (tog2 == 1) {
    t2 = lv_color_make(0, 0, 0);
    c2 = lv_color_make(255, 255, 0);
  }
  else {
    c2 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t2 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_bg_color(b2, c2, LV_PART_MAIN);
  lv_obj_set_style_text_color(b2, t2, LV_PART_MAIN);
  lv_obj_t *l2;
  l2 = lv_label_create(b2);
  lv_label_set_text(l2, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l2, LV_LABEL_LONG_WRAP);

  lv_obj_center(l2);

  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b2_toggle);
  lv_obj_t * b3 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b3, mb3, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b3, 170, 20 );
  lv_obj_set_size(b3, 60, 60 );
  lv_color_t c3;
  lv_color_t t3;
  int tog3 = result["b" + String(sb)]["toggle"];

  if (tog3 == 1) {
    t3 = lv_color_make(0, 0, 0);
    c3 = lv_color_make(255, 255, 0);
  }
  else {
    c3 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t3 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b3, t3, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b3, c3, LV_PART_MAIN);
  lv_obj_t *l3;
  l3 = lv_label_create(b3);
  lv_label_set_text(l3, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l3, LV_LABEL_LONG_WRAP);
  lv_obj_center(l3);

  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b3_toggle);
  lv_obj_t * b4 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b4, mb4, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b4, 250, 20 );
  lv_obj_set_size(b4, 60, 60 );
  lv_color_t c4;
  lv_color_t t4;
  int tog4 = result["b" + String(sb)]["toggle"];

  if (tog4 == 1) {
    t4 = lv_color_make(0, 0, 0);
    c4 = lv_color_make(255, 255, 0);
  }
  else {
    c4 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t4 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b4, t4, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b4, c4, LV_PART_MAIN);
  lv_obj_t *l4;
  l4 = lv_label_create(b4);
  lv_label_set_text(l4, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l4, LV_LABEL_LONG_WRAP);
  lv_obj_center(l4);

  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b4_toggle);
  lv_obj_t * b5 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b5, mb5, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b5, 10, 90 );
  lv_obj_set_size(b5, 60, 60 );
  lv_color_t c5;
  lv_color_t t5;
  int tog5 = result["b" + String(sb)]["toggle"];

  if (tog5 == 1) {
    t5 = lv_color_make(0, 0, 0);
    c5 = lv_color_make(255, 255, 0);
  }
  else {
    t5 = lv_color_make(255, 255, 255);
    c5 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
  }
  lv_obj_set_style_text_color(b5, t5, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b5, c5, LV_PART_MAIN);
  lv_obj_t *l5;
  l5 = lv_label_create(b5);
  lv_label_set_text(l5, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l5, LV_LABEL_LONG_WRAP);
  lv_obj_center(l5);

  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b5_toggle);
  //Serial.println("b" + String(sb));
  lv_obj_t * b6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b6, mb6, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b6, 90, 90 );
  lv_obj_set_size(b6, 60, 60 );
  lv_color_t c6;
  lv_color_t t6;
  //Serial.println(result["b" + String(sb)]["toggle"]);
  int tog6 = result["b" + String(sb)]["toggle"];
  if (tog6 == 1) {
    c6 = lv_color_make(255, 255, 0);
    t6 = lv_color_make(0, 0, 0);
  }
  else {
    c6 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t6 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_bg_color(b6, c6, LV_PART_MAIN);
  lv_obj_set_style_text_color(b6, t6, LV_PART_MAIN);

  lv_obj_t *l6;
  l6 = lv_label_create(b6);
  lv_label_set_text(l6, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l6, LV_LABEL_LONG_WRAP);
  lv_obj_center(l6);


  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b6_toggle);
  //Serial.println("b" + String(sb));
  lv_obj_t * b7 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b7, mb7, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b7, 170, 90 );
  lv_obj_set_size(b7, 60, 60 );
  lv_color_t c7;
  lv_color_t t7;
  //Serial.println(result["b" + String(sb)]["toggle"]);
  int tog7 = result["b" + String(sb)]["toggle"];
  if (tog7 == 1) {
    c7 = lv_color_make(255, 255, 0);
    t7 = lv_color_make(0, 0, 0);
  }
  else {
    c7 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t7 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_bg_color(b7, c7, LV_PART_MAIN);
  lv_obj_set_style_text_color(b7, t7, LV_PART_MAIN);

  lv_obj_t *l7;
  l7 = lv_label_create(b7);
  lv_label_set_long_mode(l7, LV_LABEL_LONG_WRAP);
  lv_label_set_text(l7, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l7);


  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b8_toggle);
  //Serial.println("b" + String(sb));
  lv_obj_t * b8 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b8, mb8, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b8, 250, 90 );
  lv_obj_set_size(b8, 60, 60 );
  lv_color_t c8;
  lv_color_t t8;
  //Serial.println(result["b" + String(sb)]["toggle"]);
  int tog8 = result["b" + String(sb)]["toggle"];
  if (tog8 == 1) {
    c8 = lv_color_make(255, 255, 0);
    t8 = lv_color_make(0, 0, 0);
  }
  else {
    c8 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t8 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_bg_color(b8, c8, LV_PART_MAIN);
  lv_obj_set_style_text_color(b8, t8, LV_PART_MAIN);

  lv_obj_t *l8;
  l8 = lv_label_create(b8);
  lv_label_set_text(l8, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l8, LV_LABEL_LONG_WRAP);
  lv_obj_center(l8);
  lv_task_handler();

}

static void touch_button1(lv_event_t *e) {
  if (jw_room == "room") {
    if (room == room_count) {
      room = 1;
    }
    else {
      room++;
    }
  }
  remote_room();
}

void remote_room() {
  jw_room = "room";
  display_exit();
  call_the_president();
  presidents_buttons();
  remote_writer();
  presidents_title();
}
void when_i_get_in(JSONVar wigi_item, String url) {
  
  int l = wigi.length();
  if (l < 0) {
    l = 0;
  }
  long timestamp = rtc.getLocalEpoch() - rtc.offset;  
  wigi_item["timestamp"] = timestamp;
  int room = wigi_item["room"];
  int button = wigi_item["button"];
  
  JSONVar bm = JSON.parse(before_me);
  
  int rooming = (((room - 1 ) * room_max) + button);
  String roomings = String(rooming);
  JSONVar buttonski = bm["b" + roomings];
  String bs = JSON.stringify(buttonski);
  
  String movement = (const char *)buttonski["movement"];
  int toggle = buttonski["toggle"];
  
  if (movement == "start") {
    if (toggle == 1) {
      bm["b" + roomings]["toggle"] = 0;
    }
    else {
      bm["b" + roomings]["toggle"] = 1;
    }
    before_me = JSON.stringify(bm);
    presidents_buttons();
  }

  if (ble_link_ready()) {
    // a local envelope: the bridge relays it, no network needed on this side.
    // Chunked to the link's MTU: a tap is ~450 bytes and a 20-byte notify drops it.
    JSONVar envelope = JSON.parse("{}");
    envelope["type"] = "button";
    envelope["payload"] = wigi_item;
    url = url_maker(url);
    envelope["url"] = url;
    String payload = JSON.stringify(envelope);
    deckLog("[bt] tap sent (%u bytes)", payload.length());
    ble_notify_payload(payload);
  } else {
    wigi[l] = wigi_item;
  }
}

// Hand a button tap to the phone bridge when it is up: the homebase fetches the
// same url the tap would have, but the deck does not block the UI on a 1-2 s TLS
// round trip, so a press lands at once. Returns true when it went over BLE, so
// the caller skips https_request().
static bool tap_over_ble(int which, int toggle, const String &url) {
  if (!ble_link_ready()) {
    return false;
  }
  JSONVar updater;
  updater["room"] = room;
  updater["button"] = which;
  updater["toggle"] = toggle;
  when_i_get_in(updater, url);
  return true;
}

// Taps made while no central was attached sit in wigi until the webapp's WIGI
// button collects them; when a central comes back, hand the fresh ones over
// over BLE so a momentary drop does not strand them. Anything older than five
// minutes stays in the queue for the webapp to pull.
void ble_flush_wigi() {
  int l = wigi.length();
  if (l <= 0) {
    return;
  }
  // the link must be up AND subscribed, or these notifies are dropped too
  if (!ble_link_ready()) {
    return;
  }
  if (homebaseIP.length() == 0 || authorization.length() == 0) {
    return;
  }
  long now = rtc.getLocalEpoch() - rtc.offset;
  JSONVar remainder = JSON.parse("[]");
  int keep = 0;
  for (int i = 0; i < l; i++) {
    JSONVar item = wigi[i];
    if (!item.hasOwnProperty("room") || !item.hasOwnProperty("button")) {
      continue;
    }
    long ts = item["timestamp"];
    if (now - ts > 300) {
      remainder[keep] = item;
      keep++;
      continue;
    }
    int room_n = item["room"];
    int button_n = item["button"];
    int toggle_n = item["toggle"];
    String url = "https://" + homebaseIP +
      "/watch/button?room=" + room_n +
      "&button=" + button_n +
      "&toggle=" + toggle_n;
    JSONVar envelope = JSON.parse("{}");
    envelope["type"] = "button";
    envelope["payload"] = item;
    envelope["url"] = url_maker(url);
    String payload = JSON.stringify(envelope);
    ble_notify_payload(payload);
    deckLog("[bt] flushed a queued tap");
    delay(50);
  }
  wigi = remainder;
}

