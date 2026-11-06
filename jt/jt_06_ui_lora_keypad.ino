void readRadio() {
  if (loraChatReceiver && hasRadio && !lorawan_enabled) {
    if (operationDone) {
      operationDone = false;
      String str;
      int state = radio.readData(str);
      if (state == RADIOLIB_ERR_NONE) {
        radio.startReceive();

        JSONVar js = JSON.parse(str);
        Serial.println(str);
        String msg_check = (const char *)js["msg"];
        String ssid_check = (const char *)js["ap_ssid"];
        String chat_check = (const char *)js["m"];
        if (chat_check != "") {
          String username = js["u"];
          String message = js["m"];
          long timestamp = rightNow();
          chat_text_writer(username, message, timestamp);

          Serial.println(str);
          if (authorization != "") {
            String request = "https://" + homebaseIP + "/watch/chat_received?message=" + urlEncode(message) + "&username=" + urlEncode(username);
            String jawnnformation = https_request(request);
            Serial.println(jawnnformation);
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
          returner["time"] = rtc.getLocalEpoch();
          String returns = JSON.stringify(returner);
          //   radio.startTransmit(returns);
          //   Serial.println(returns);
          //   delay(1000);
        }
        else if (msg_check != "") {
          String app = (const char *)js["app"];
          Serial.println(app);
          Serial.println("Got a message: " + msg_check);
          JSONVar result = JSON.parse(https_request(
                                        "https://" + homebaseIP +
                                        "/watch/telephone_msg?timestamp=" + rtc.getLocalEpoch() +
                                        "&msg=" + msg_check + "&app=" + app
                                      ));
          String rs = JSON.stringify(result);
          Serial.println(rs);
        }
      }
    }
  }
}
void display_exit( void ) {
  lv_obj_clean ( lv_scr_act() ); // Clean objects from current screen.
  deck_nav_row_reset();            // the bottom row went with them
  lv_obj_invalidate( lv_scr_act() ); // Invalidate objects for redraw.
  // the chat/pen log and input lived on the screen that was just cleaned
  room_log = NULL;
  room_input = NULL;
  room_log_text = "";
  button_writer();
  //  time_writer("now");
}

String chip_id_maker() {
  uint32_t chipId = 0;
  for(int i=0; i<17; i=i+8) {
    chipId |= ((ESP.getEfuseMac() >> (40 - i)) & 0xff) << i;
  }
  String chip_id = String(chipId);
  return chip_id;
}

void time_writer(char * situation) {

  if (situation == "now" || jw_room != "watch") {
    // tft.fillScreen(TFT_YELLOW);
    jw_room = "watch";
  }
  if (millis() - lastMillis > 1000 || situation == "now") {
    lastMillis = millis();
    time_t now;
    struct tm  timeinfo;
    time(&now);
    localtime_r(&now, &timeinfo);

    char datetime[128] = {0};
    snprintf(datetime, 128, "%d/%d/%d %d:%d:%d", timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday, timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);

    // Get the time C library structure
    //    tft.getDateTime(&timeinfo);
    size_t written_date = strftime(bufdate, 64, "%a %b %d %Y", &timeinfo);
    size_t written_time = strftime(buftime, 64, "%H:%M", &timeinfo);
    size_t written_sec = strftime(bufsec, 64, "%S", &timeinfo);
    tft.setTextFont(2);
    tft.setTextColor(TFT_YELLOW, TFT_BLACK);
    // Battery in the top-left corner, the way the watch wears it. The date
    // moves right to make room; the clock below stays where it was.
    int batt = deck_battery_percent();
    tft.setTextColor(batt < 20 ? TFT_RED : (batt < 40 ? TFT_YELLOW : TFT_GREEN), TFT_BLACK);
    tft.drawString(String(batt) + "%", 10, 10);
    tft.setTextColor(TFT_YELLOW, TFT_BLACK);
    if (written_date != 0) {
      tft.drawString(bufdate, 52, 10);
    }
    if (written_time != 0) {
      tft.setTextFont(6);
      tft.drawString(buftime, 10, 25);
    }
    if (written_sec != 0) {

      tft.setTextFont(2);
      tft.drawString(bufsec, 10, 70);
    }
    tft.setCursor(10, 100);
    tft.print(gps.location.lat(), 6);
    tft.setCursor(10, 120);
   // tft.print( lngPrint );
    tft.print(gps.location.lng(), 6);
    tft.setCursor(10,140);
    tft.print(gps.altitude.meters(), 6);
  }
}


void setupLvgl()
{
  static lv_color_t *buf = (lv_color_t *)ps_malloc(LVGL_BUFFER_SIZE);
  if (!buf) {
    // Serial.println("menory alloc failed!");
    delay(5000);
    assert(buf);
  }
  lv_init();
  lv_tick_set_cb(millis);

  lv_group_set_default(lv_group_create());

  /*Initialize the display*/
  lv_display_t *disp = lv_display_create(TFT_HEIGHT, TFT_WIDTH);
  lv_display_set_flush_cb(disp, disp_flush);
  lv_display_set_buffers(disp, buf, NULL, LVGL_BUFFER_SIZE, LV_DISPLAY_RENDER_MODE_PARTIAL);

  // The default theme paints its screens white, and the deck wants black. Every
  // room is built on this one screen (they lv_obj_clean() it and add their own
  // widgets), so setting it once here covers all of them.
  lv_obj_set_style_bg_color(lv_scr_act(), lv_color_black(), 0);
  lv_obj_set_style_bg_opa(lv_scr_act(), LV_OPA_COVER, 0);

  /*Initialize the  input device driver*/
  /*Register a touchscreen input device*/
  if (touchDected) {
    touch_indev = lv_indev_create();
    lv_indev_set_type(touch_indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(touch_indev, touchpad_read);
  }
  if (kbDected) {
    Serial.println("Keyboard registered!!");
    /*Register a keypad input device*/
    kb_indev = lv_indev_create();
    lv_indev_set_type(kb_indev, LV_INDEV_TYPE_KEYPAD);
    lv_indev_set_read_cb(kb_indev, keypad_read);
    lv_indev_set_group(kb_indev, lv_group_get_default());
  }
}

// Read key value from esp32c3
char keypad_get_key(void)
{
  char key_ch = 0;
  Wire.requestFrom(0x55, 1);
  while (Wire.available() > 0) {
    key_ch = Wire.read();
  }
  return key_ch;
}

void fontLoader() {
  if (fontSelect == "Latin") {
    tft.loadFont(Latin_Hiragana_24);
  }
  else if (fontSelect == "Unicode") {
    tft.loadFont(Unicode_Test_72);
  }
  else if (fontSelect == "Noto Small") {
    tft.loadFont(AA_FONT_SMALL); // Load another different font
  }
  else if (fontSelect == "Noto Large") {
    tft.loadFont(AA_FONT_LARGE); // Load another different font
  }
  else if (fontSelect == "Final Frontier") {
    tft.loadFont(Final_Frontier_28);
  }
  else if (fontSelect == "Basic") {
    tft.unloadFont();
  }
  tft.setTextFont(fontSize);
  tft.setTextWrap(true, true);
}

void fontUnloader() {
  if (fontSelect != "") {
    tft.unloadFont();
  }
}
/*Will be called by the library to read the mouse*/
static void keypad_read(lv_indev_t *indev_drv, lv_indev_data_t *data)
{
  static uint32_t last_key = 0;
  char keyValue;
  // the key that woke the deck was polled by the sleep path; read it from there
  // instead of asking a keyboard that has already seen the key released
  keyValue = deck_pending_key;
  deck_pending_key = 0;
  if (!keyValue) { keyValue = keypad_get_key(); }
  if (keyValue != 0) {
    data->state = LV_INDEV_STATE_PR;
    buttonMillis = millis();
    Serial.println(keyValue);
    // LVGL's own key codes live in the low ASCII range and its Enter is '\n',
    // while this keyboard sends a carriage return for Enter.
    last_key = (keyValue == (char)0x0D) ? (uint32_t)LV_KEY_ENTER : (uint32_t)(uint8_t)keyValue;

    // The chat and pen rooms have real LVGL textareas now: the key goes to the
    // focused widget through the keypad group and the sending happens on the
    // textarea's READY event. Handling it here as well would type it twice -
    // which is what happened the last time this was tried.
    if (jw_room == "chat" || jw_room == "pen") {
      data->key = last_key;
      return;
    }

    fontLoader();
    char buf[256] = {0};
    long timestamp = rtc.getLocalEpoch() - rtc.offset;
    JSONVar president;
    if (buttoned_before) {
      president = JSON.parse(before_me);
    }
    if (troom != "typewriter") {
      if (jw_room == "room") {
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["typewriter_background_colour_rgb"][0], president["__specs"]["typewriter_background_colour_rgb"][1], president["__specs"]["typewriter_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_BLACK);
        }
      }
      else if (jw_room == "chat") {
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["chat_background_colour_rgb"][0], president["__specs"]["chat_background_colour_rgb"][1], president["__specs"]["chat_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_WHITE);
        }
      }
      else if (jw_room == "pen") {
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["pen_background_colour_rgb"][0], president["__specs"]["pen_background_colour_rgb"][1], president["__specs"]["pen_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_WHITE);
        }
      }
    }
    if (jw_room == "room") {
      // Serial.print("keyvalue: ");
      // Serial.println(keyValue);
      tauth_connect();

      JSONVar wsdata;
      wsdata["timestamp"] = timestamp;
      wsdata["key"] = keyValue;
      wsdata["command"] = "keypress";
      String jsonwsdata = JSON.stringify(wsdata);
      if (troom == "typewriter" && (textarea_content.length() >= 0)) {
        wsclient.send(jsonwsdata);
      }

      if (keyValue == (char)0x08) {
        int lastIndex = textarea_content.length() - 1;
        textarea_content.remove(lastIndex);
        // Serial.println(textarea_content);
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["typewriter_background_colour_rgb"][0], president["__specs"]["typewriter_background_colour_rgb"][1], president["__specs"]["typewriter_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_YELLOW);
        }

      }
      else if (keyValue == (char)0x0D) {
        if (authorization != "") {
          // Serial.println("Enter pressed");
          String life = urlEncode(textarea_content);
          // The deck is already authorized by the Now Me pair (url_maker sends
          // it); there is no password step here any more.
          String information = https_request("https://" + thomebaseIP + "/teletype/information?life=" + life);
           Serial.println(information);

          textarea_content = "";
          JSONVar info = JSON.parse(information);
          // Serial.println(info["tty_port"]);
          int y = tft.getCursorY() + 26;
          tft.setCursor(0, y);
          String result = info["result"];
          String returner = info["returner"];
          if (result == "denial") {
            // the Now Me pair rotated, or this deck has not had a Now Me yet
          }
          tauth_connect();
          tft.drawString("P: " + returner, 0, y);

          long server_time = info["server_time"];
          long offset = info["offset"];
          rtc.offset = offset;
          rtc.setTime(server_time + offset);
        }
        else {
          int y = tft.getCursorY() + 26;
          tft.setCursor(0, y);
          tft.drawString("T: I on't curr", 0, y);
        }

      }
      else if (troom != "typewriter") {
        troom = "typewriter";
        // textarea_content = textarea_content + keyValue;
      }
      else {
        textarea_content = textarea_content + keyValue;
      }
      if (buttoned_before) {
        tft.setTextColor(tft.color565(president["__specs"]["typewriter_text_colour_rgb"][0], president["__specs"]["typewriter_text_colour_rgb"][1], president["__specs"]["typewriter_text_colour_rgb"][2]), tft.color565(president["__specs"]["typewriter_background_colour_rgb"][0], president["__specs"]["typewriter_background_colour_rgb"][1], president["__specs"]["typewriter_background_colour_rgb"][2]));
      }
      else {
        tft.setTextColor(TFT_WHITE, TFT_BLACK);
      }
      tft.setCursor(5, 5);
      tft.print( textarea_content );
    }
    else if (jw_room == "chat") {
      if (keyValue == (char)0x08) {
        int lastIndex = textarea_content.length() - 1;
        textarea_content.remove(lastIndex);
        // Serial.println(textarea_content);
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["chat_background_colour_rgb"][0], president["__specs"]["chat_background_colour_rgb"][1], president["__specs"]["chat_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_BLACK);
        }

      }
      else if (keyValue == (char)0x0D) {
        Serial.println("Enter pressed");
        String message = urlEncode(textarea_content);
        long timestamp = rightNow();
        chat_text_writer(computer_name, textarea_content, timestamp);
        if (authorization != "") {
          String request = "https://" + homebaseIP + "/watch/chat_received?message=" + message + "&username=" + urlEncode(computer_name)
                           + "&community=" + urlEncode(community_room) + "&club=" + urlEncode(club_room) + "&team=" + urlEncode(team_room) + "&account=" + urlEncode(account_room)
                           + "&project=" + urlEncode(project_room) + "&contact=" + urlEncode(contact_room) + "&person=" + urlEncode(person_room);
          Serial.println(request);
          String information = https_request(request);
          Serial.println(information);
          JSONVar info = JSON.parse(information);
          String returner = info["returner"];
        }
        loraChatBroadcast(computer_name, textarea_content, timestamp);
        textarea_content = "";
      }
      else if (troom != "typewriter") {
        troom = "typewriter";
        //  textarea_content = textarea_content + keyValue;
      }
      else {
        textarea_content = textarea_content + keyValue;
      }
      if (buttoned_before) {
        tft.setTextColor(tft.color565(president["__specs"]["chat_text_colour_rgb"][0], president["__specs"]["chat_text_colour_rgb"][1], president["__specs"]["chat_text_colour_rgb"][2]), tft.color565(president["__specs"]["chat_background_colour_rgb"][0], president["__specs"]["chat_background_colour_rgb"][1], president["__specs"]["chat_background_colour_rgb"][2]));
      }
      else {
        tft.setTextColor(TFT_BLACK, TFT_WHITE);
      }
      tft.setCursor(5, 5);
      tft.print( textarea_content );
    }

    else if (jw_room == "pen") {
      if (keyValue == (char)0x08) {
        int lastIndex = textarea_content.length() - 1;
        textarea_content.remove(lastIndex);
        // Serial.println(textarea_content);
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["pen_background_colour_rgb"][0], president["__specs"]["pen_background_colour_rgb"][1], president["__specs"]["pen_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_YELLOW);
        }
      }
      else if (keyValue == (char)0x0D) {
        Serial.println("Enter pressed");
        String message = urlEncode(textarea_content);
        long timestamp = rightNow();
        chat_text_writer("Me", textarea_content, timestamp);

        if (authorization != "") {
          textarea_content = "";

          String request = "https://" + homebaseIP + "/teletype/pen?message=" + message + "&username=" + urlEncode(computer_name);
          Serial.println(request);
          String information = https_request(request);
          Serial.println(information);
          JSONVar info = JSON.parse(information);
          timestamp = rightNow();
          chat_text_writer("Pen", info["message"], timestamp);
        }

      }
      else if (troom != "typewriter") {
        troom = "typewriter";
        //  textarea_content = textarea_content + keyValue;
      }
      else {
        textarea_content = textarea_content + keyValue;
      }
      if (buttoned_before) {
        tft.setTextColor(tft.color565(president["__specs"]["pen_text_colour_rgb"][0], president["__specs"]["pen_text_colour_rgb"][1], president["__specs"]["pen_text_colour_rgb"][2]), tft.color565(president["__specs"]["pen_background_colour_rgb"][0], president["__specs"]["pen_background_colour_rgb"][1], president["__specs"]["pen_background_colour_rgb"][2]));
      }
      else {
        tft.setTextColor(TFT_BLUE, TFT_YELLOW);
      }
      tft.setCursor(5, 5);
      tft.print( textarea_content );
    }
    fontUnloader();
  }
  else {
    data->state = LV_INDEV_STATE_REL;
  }
  data->key = last_key;
}

// The keypad input device can only be created once the keyboard answers, and
// that is not always inside setup(). setupLvgl() registers it when the boot
// probe already had a reply; loop() calls this until it does.
static void registerKeyboard() {
  if (kb_indev || !checkKb()) {
    return;
  }
  kbDected = true;
  deckLog("[deck] keyboard answered late; keypad registered");
  kb_indev = lv_indev_create();
  lv_indev_set_type(kb_indev, LV_INDEV_TYPE_KEYPAD);
  lv_indev_set_read_cb(kb_indev, keypad_read);
  lv_indev_set_group(kb_indev, lv_group_get_default());
  buttonMillis = millis();
}

void loraChatBroadcast(String computer_name, String body, long timestamp) {
  // The old test here was `if (loraBroadcastToggle)`, which is the *event
  // callback* sitting next to this function, so it was always true; the flag the
  // button actually sets is loraChatBroadcaster. And no radio, no transmit.
  if (hasRadio && loraChatBroadcaster && !lorawan_enabled) {
    JSONVar msg;
    msg["u"] = computer_name;
    msg["m"] = body;

    String returns = JSON.stringify(msg);
    Serial.println(returns);
    radio.startTransmit(returns);
    Serial.println("transmitted");
    // delay(2000);
    //   radio.startReceive();
    Serial.println("back to listening");
  }
}

