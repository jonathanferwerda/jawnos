void chat_displayer() {
  jw_room = "chat";
  display_exit();
  Serial.println("in the chat");
  if (before_me != "") {
    JSONVar pres = JSON.parse(before_me);
    Serial.println("Got the pres");
    lv_color_t t1;
    t1 = lv_color_make(0, 0, 0);

    lv_obj_t * codd = lv_dropdown_create(lv_scr_act());
    String cooptions = (const char * )pres["__specs"]["chat"]["community"];
    if (cooptions == "") {
      cooptions = "local\n";
    }
    lv_dropdown_set_options(codd, cooptions.c_str());
    lv_obj_add_event_cb(codd, community_room_select, LV_EVENT_VALUE_CHANGED, NULL);
    lv_dropdown_set_text(codd, community_room.c_str());
    lv_obj_set_pos(codd, 5, 2 );
    lv_obj_set_size(codd, 98, 28 );
    lv_obj_set_style_bg_color(codd, lv_color_hex(0x58fdd4), LV_PART_MAIN);
    lv_obj_set_style_text_color(codd, t1, LV_PART_MAIN);
    Serial.println("after community");

    lv_obj_t * cldd = lv_dropdown_create(lv_scr_act());
    String cloptions = (const char * )pres["__specs"]["chat"]["club"];
    if (cloptions == "") {
      cloptions = "peers\n";
    }
    lv_dropdown_set_options(cldd, cloptions.c_str());
    lv_obj_add_event_cb(cldd, club_room_select, LV_EVENT_VALUE_CHANGED, NULL);
    lv_dropdown_set_text(cldd, club_room.c_str());
    lv_obj_set_pos(cldd, 107, 2 );
    lv_obj_set_size(cldd, 98, 28 );
    lv_obj_set_style_bg_color(cldd, lv_color_hex(0x58fdd4), LV_PART_MAIN);
    lv_obj_set_style_text_color(cldd, t1, LV_PART_MAIN);
    Serial.println("after the club");

    lv_obj_t * tedd = lv_dropdown_create(lv_scr_act());
    String teoptions = (const char * )pres["__specs"]["chat"]["team"];
    if (teoptions == "") {
      teoptions = "family\n";
    }

    lv_dropdown_set_options(tedd, teoptions.c_str());
    lv_obj_add_event_cb(tedd, team_room_select, LV_EVENT_VALUE_CHANGED, NULL);
    lv_dropdown_set_text(tedd, team_room.c_str());
    lv_obj_set_pos(tedd, 209, 2 );
    lv_obj_set_size(tedd, 106, 28 );
    lv_obj_set_style_bg_color(tedd, lv_color_hex(0x58fdd4), LV_PART_MAIN);
    lv_obj_set_style_text_color(tedd, t1, LV_PART_MAIN);
    Serial.println("after the team");

    lv_obj_t * prdd = lv_dropdown_create(lv_scr_act());
    String proptions = (const char * )pres["__specs"]["chat"]["project"];
    if (proptions == "") {
      proptions = "self\n";
    }
    lv_dropdown_set_options(prdd, proptions.c_str());
    lv_obj_add_event_cb(prdd, project_room_select, LV_EVENT_VALUE_CHANGED, NULL);
    lv_dropdown_set_text(prdd, project_room.c_str());
    lv_obj_set_pos(prdd, 5, 34 );
    lv_obj_set_size(prdd, 73, 28 );
    lv_obj_set_style_bg_color(prdd, lv_color_hex(0x58fdd4), LV_PART_MAIN);
    lv_obj_set_style_text_color(prdd, t1, LV_PART_MAIN);
    Serial.println("after the project");

    lv_obj_t * acdd = lv_dropdown_create(lv_scr_act());
    String acoptions = (const char * )pres["__specs"]["chat"]["account"];
    if (acoptions == "") {
      acoptions = "cash\n";
    }
    lv_dropdown_set_options(acdd, acoptions.c_str());
    lv_obj_add_event_cb(acdd, account_room_select, LV_EVENT_VALUE_CHANGED, NULL);
    lv_dropdown_set_text(acdd, account_room.c_str());
    lv_obj_set_pos(acdd, 81, 34 );
    lv_obj_set_size(acdd, 73, 28 );
    lv_obj_set_style_bg_color(acdd, lv_color_hex(0x58fdd4), LV_PART_MAIN);
    lv_obj_set_style_text_color(acdd, t1, LV_PART_MAIN);
    Serial.println("after the account");

    lv_obj_t * pedd = lv_dropdown_create(lv_scr_act());
    String peoptions = (const char * )pres["__specs"]["chat"]["person"];
    if (acoptions == "") {
      acoptions = "self\n";
    }
    lv_dropdown_set_options(pedd, peoptions.c_str());
    lv_obj_add_event_cb(pedd, person_room_select, LV_EVENT_VALUE_CHANGED, NULL);
    lv_dropdown_set_text(pedd, person_room.c_str());
    lv_obj_set_pos(pedd, 157, 34 );
    lv_obj_set_size(pedd, 73, 28 );
    lv_obj_set_style_bg_color(pedd, lv_color_hex(0x58fdd4), LV_PART_MAIN);
    lv_obj_set_style_text_color(pedd, t1, LV_PART_MAIN);
    Serial.println("after the person");

    lv_obj_t * condd = lv_dropdown_create(lv_scr_act());
    String conoptions = (const char * )pres["__specs"]["chat"]["contacts"];
    if (conoptions == "") {
      conoptions = "ajawnomous";
    }
    lv_dropdown_set_options(condd, conoptions.c_str());
    lv_obj_add_event_cb(condd, contact_room_select, LV_EVENT_VALUE_CHANGED, NULL);
    lv_dropdown_set_text(condd, contact_room.c_str());
    lv_obj_set_pos(condd, 233, 34 );
    lv_obj_set_size(condd, 82, 28 );
    lv_obj_set_style_bg_color(condd, lv_color_hex(0x58fdd4), LV_PART_MAIN);
    lv_obj_set_style_text_color(condd, t1, LV_PART_MAIN);
    Serial.println("after the contact");
  }
  roomInputBuild("chat", 68, 86);
  lv_task_handler();
}


static void touch_button4(lv_event_t *e) {
  display_exit();
  chat_displayer();
}

static void community_room_select(lv_event_t *e) {
  lv_event_code_t code = lv_event_get_code(e);
  lv_obj_t * obj = lv_event_get_target_obj(e);
  if (code == LV_EVENT_VALUE_CHANGED) {
    char buf[32];
    lv_dropdown_get_selected_str(obj, buf, sizeof(buf));
    community_room = buf;
    Serial.println(buf);
    Serial.println(chat_room);
  }
}

static void club_room_select(lv_event_t *e) {
  lv_event_code_t code = lv_event_get_code(e);
  lv_obj_t * obj = lv_event_get_target_obj(e);
  if (code == LV_EVENT_VALUE_CHANGED) {
    char buf[32];
    lv_dropdown_get_selected_str(obj, buf, sizeof(buf));
    club_room = buf;
    Serial.println(buf);
    Serial.println(chat_room);
  }
}


static void team_room_select(lv_event_t *e) {
  lv_event_code_t code = lv_event_get_code(e);
  lv_obj_t * obj = lv_event_get_target_obj(e);
  if (code == LV_EVENT_VALUE_CHANGED) {
    char buf[32];
    lv_dropdown_get_selected_str(obj, buf, sizeof(buf));
    team_room = buf;
    Serial.println(buf);
    Serial.println(chat_room);
  }
}

static void project_room_select(lv_event_t *e) {
  lv_event_code_t code = lv_event_get_code(e);
  lv_obj_t * obj = lv_event_get_target_obj(e);
  if (code == LV_EVENT_VALUE_CHANGED) {
    char buf[32];
    lv_dropdown_get_selected_str(obj, buf, sizeof(buf));
    project_room = buf;
    Serial.println(buf);
    Serial.println(chat_room);
  }
}
static void account_room_select(lv_event_t *e) {
  lv_event_code_t code = lv_event_get_code(e);
  lv_obj_t * obj = lv_event_get_target_obj(e);
  if (code == LV_EVENT_VALUE_CHANGED) {
    char buf[32];
    lv_dropdown_get_selected_str(obj, buf, sizeof(buf));
    account_room = buf;
    Serial.println(buf);
    Serial.println(chat_room);
  }
}
static void person_room_select(lv_event_t *e) {
  lv_event_code_t code = lv_event_get_code(e);
  lv_obj_t * obj = lv_event_get_target_obj(e);
  if (code == LV_EVENT_VALUE_CHANGED) {
    char buf[32];
    lv_dropdown_get_selected_str(obj, buf, sizeof(buf));
    person_room = buf;
    Serial.println(buf);
    Serial.println(chat_room);
  }
}

static void contact_room_select(lv_event_t *e) {
  lv_event_code_t code = lv_event_get_code(e);
  lv_obj_t * obj = lv_event_get_target_obj(e);
  if (code == LV_EVENT_VALUE_CHANGED) {
    char buf[32];
    lv_dropdown_get_selected_str(obj, buf, sizeof(buf));
    contact_room = buf;
    Serial.println(buf);
    Serial.println(chat_room);
  }
}


static void touch_button5(lv_event_t *e) {
  pen_room();
}

void pen_room() {
  jw_room = "pen";
  display_exit();
  roomInputBuild("pen", 5, 148);
}

static void fontPicker(lv_event_t *e) {
  Serial.println("font change");
  lv_event_code_t code = lv_event_get_code(e);
  lv_obj_t * obj = lv_event_get_target_obj(e);
  if (code == LV_EVENT_VALUE_CHANGED) {
    char buf[32];
    lv_dropdown_get_selected_str(obj, buf, sizeof(buf));
    Serial.println(buf);
    fontSelect = buf;
  }
}

static void fontSizeChanger(lv_event_t *e) {
  lv_obj_t *slider = lv_event_get_target_obj(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  fontSize = level;
}

static void touch_button6(lv_event_t *e) {
  net_room();
}

// The watch's Nordic UART Service, unchanged except for the advertise name
// (the deck's configured name, so a house full of them can be told apart).
void start_ble_transfer() {
  if (ble_radio_up == true) {
    return;
  }
  deckLog("[bt] powering up");
  ble_radio_up = true;
  bt_enabled = true;

  BLEDevice::init(name.length() ? name.c_str() : "T-Deck");
  BLEDevice::setMTU(512);

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(&ble_server_callbacks);

  BLEService *pService = pServer->createService(SERVICE_UUID);

  // TX: this board notifying the phone
  pTxCharacteristic = pService->createCharacteristic(
                        CHARACTERISTIC_UUID_TX,
                        BLECharacteristic::PROPERTY_NOTIFY
                      );
  pTxCharacteristic->addDescriptor(new BLE2902());
  // the phone's descriptor write lands here, and until it does notify() goes nowhere
  pTxCharacteristic->setCallbacks(&ble_tx_callbacks);

  // RX: the phone writing to this board
  BLECharacteristic *pRxCharacteristic = pService->createCharacteristic(
                                           CHARACTERISTIC_UUID_RX,
                                           BLECharacteristic::PROPERTY_WRITE
                                         );
  pRxCharacteristic->setCallbacks(new MyCallbacks());

  pService->start();
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);  // hint for iPhone connections
  pAdvertising->setMinPreferred(0x12);

  // Name this deck to a JawnOS bridge in the scan response: manufacturer data
  // (company 0xFFFF) + "JW" + version + flags + purpose + chip id. The bridge
  // matches the magic, so adoption no longer depends on the Nordic UART uuid
  // and a device already in the fleet is recognized before a link is opened.
  String mfg;
  mfg += (char)0xFF; mfg += (char)0xFF;   // company id 0xFFFF
  mfg += 'J'; mfg += 'W';
  mfg += (char)1;                         // version
  mfg += (char)1;                         // flags: bit0 = relay capable
  mfg += (char)2;                         // purpose: teletype
  mfg += chip_id_maker();
  BLEAdvertisementData scanResponse;
  scanResponse.setManufacturerData(mfg);
  pAdvertising->setScanResponseData(scanResponse);

  pAdvertising->start();
  deckLog("[bt] advertising as %s", name.length() ? name.c_str() : "T-Deck");
}

void stop_ble_transfer() {
  if (ble_radio_up == false) {
    return;
  }
  deckLog("[bt] shutting down");
  ble_radio_up = false;
  bt_enabled = false;
  if (pServer) {
    // Close the link before tearing the stack down: deinit with a disconnect
    // event still in flight walked characteristics that no longer existed
    for (int tries = 0; pServer->getConnectedCount() > 0 && tries < 20; tries++) {
      pServer->disconnect(pServer->getConnId());
      delay(50);
    }
    pServer->getAdvertising()->stop();
  }
  // false shuts the RF off without destroying the NUS mapping objects in RAM
  BLEDevice::deinit(false);
}

static void bt_control(lv_event_t *e) {
  lv_obj_t * bt_button = lv_event_get_target_obj(e);
  if (ble_radio_up == true) {
    stop_ble_transfer();
    lv_obj_set_style_bg_color(bt_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  else {
    start_ble_transfer();
    lv_obj_set_style_bg_color(bt_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
}

void net_room() {
  jw_room = "net";

  display_exit();
  ip_writer();

  lv_obj_t * wifi_button = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(wifi_button, wifi_control, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(wifi_button, 10, 20 );
  lv_obj_set_size(wifi_button, 40, 40 );
  if (wifi_enabled == true) {
    lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_t *lwi1;
  lv_color_t twi1;
  twi1 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(wifi_button, twi1, LV_PART_MAIN);
  lwi1 = lv_label_create(wifi_button);
  lv_label_set_text(lwi1, "WI");
  lv_obj_center(lwi1);

  lv_obj_t * wifi_ap_button = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(wifi_ap_button, wifi_ap_control, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(wifi_ap_button, 60, 20 );
  lv_obj_set_size(wifi_ap_button, 40, 40 );
  if (wifi_ap_enabled == true) {
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_t *lwi2;
  lv_color_t twi2;
  twi2 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(wifi_ap_button, twi2, LV_PART_MAIN);
  lwi2 = lv_label_create(wifi_ap_button);
  lv_label_set_text(lwi2, "AP");
  lv_obj_center(lwi2);

  lv_obj_t * bt_button = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(bt_button, bt_control, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(bt_button, 110, 20 );
  lv_obj_set_size(bt_button, 40, 40 );
  if (bt_enabled == true) {
    lv_obj_set_style_bg_color(bt_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(bt_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_t *lwi3;
  lv_color_t twi3;
  twi3 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(bt_button, twi3, LV_PART_MAIN);
  lwi3 = lv_label_create(bt_button);
  lv_label_set_text(lwi3, "BT");
  lv_obj_center(lwi3);
}

static void sd_test(lv_event_t *e) {
  sd_tester();
}
bool sd_tester() {
  digitalWrite(BOARD_SDCARD_CS, HIGH);
  digitalWrite(RADIO_CS_PIN, HIGH);
  digitalWrite(BOARD_TFT_CS, HIGH);

  // 800 kHz was the card's first, timorous clock; 20 MHz is still well inside
  // what the shared SPI bus and a modern card handle, and the TFT's transactions
  // restore their own clock (SUPPORT_TRANSACTIONS).
  bool sdMounted = SD.begin(BOARD_SDCARD_CS, spi, 20000000U);
  if (!sdMounted) { sdMounted = SD.begin(BOARD_SDCARD_CS, spi, 800000U); }
  deckLog("[deck] sd mount %s", sdMounted ? "ok" : "failed");
  if (sdMounted) {
    uint8_t cardType = SD.cardType();
    if (cardType == CARD_NONE) {
      Serial.println("No SD_MMC card attached");
      sdMounted = false;
    } else {
      Serial.print("SD_MMC Card Type: ");
      if (cardType == CARD_MMC) {
        Serial.println("MMC");
      } else if (cardType == CARD_SD) {
        Serial.println("SDSC");
      } else if (cardType == CARD_SDHC) {
        Serial.println("SDHC");
      } else {
        Serial.println("UNKNOWN");
      }
      uint32_t cardSize = SD.cardSize() / (1024 * 1024);
      uint32_t cardTotal = SD.totalBytes() / (1024 * 1024);
      uint32_t cardUsed = SD.usedBytes() / (1024 * 1024);
      Serial.printf("SD Card Size: %lu MB\n", cardSize);
      Serial.printf("Total space: %lu MB\n",  cardTotal);
      Serial.printf("Used space: %lu MB\n",   cardUsed);
    }
  }
  sdReady = sdMounted;
  store = sdReady ? (fs::FS *)&SD : (fs::FS *)&FFat;
  deckLog("[fs] bulk store: %s", sdReady ? "sd" : "ffat");
  if (!store->exists("/jawn")) { store->mkdir("/jawn"); }
  if (!store->exists("/jawn/recordings")) { store->mkdir("/jawn/recordings"); }
  return sdReady;
}

static void clear_typewriter(lv_event_t *e) {
  textarea_content = "";
}
void ip_writer() {
  tft.setTextFont(2);
  IPAddress ip = WiFi.localIP();
  sprintf(bufIP, "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
  tft.setTextColor(TFT_BLACK, TFT_YELLOW);
  IPAddress gw_ip = WiFi.gatewayIP();
  tft.setTextColor(TFT_WHITE, TFT_BLUE);
  if (WiFi.status() == WL_CONNECTED) {
    tft.drawString(ssid, 10, 110);
    sprintf(bufgwIP, "%d.%d.%d.%d", gw_ip[0], gw_ip[1], gw_ip[2], gw_ip[3]);
    tft.drawString(bufIP, 80, 110);
    tft.drawString(bufgwIP, 200, 110);
  }
  tft.setTextColor(TFT_WHITE, TFT_RED);
  if (wifi_ap_enabled) {
    tft.drawString(ap_ssid, 10, 130);
    apIP = WiFi.softAPIP();
    sprintf(bufapIP, "%d.%d.%d.%d", apIP[0], apIP[1], apIP[2], apIP[3] );
    tft.drawString(bufapIP, 80, 130);
  }

  tft.setTextColor(TFT_WHITE, TFT_ORANGE);
  if (computer_name != "") {
    tft.drawString(computer_name, 200, 130);
  }
  else {
    tft.drawString(homebaseIP, 200, 130);
  }

  // the BT line, like the watch's: the bridge's own name when it sent one, else
  // the address the connect carried, else the state of the radio
  {
    char bt_line[40];
    uint16_t bt_colour = TFT_WHITE;
    if (!bt_enabled) {
      snprintf(bt_line, sizeof(bt_line), "BT: off");
      bt_colour = TFT_LIGHTGREY;
    }
    else if (deviceConnected) {
      const char *who = ble_peer_name[0] ? ble_peer_name : (ble_peer_addr[0] ? ble_peer_addr : "?");
      snprintf(bt_line, sizeof(bt_line), "BT: %s", who);
      bt_colour = TFT_GREEN;
    }
    else if (ble_radio_up) {
      snprintf(bt_line, sizeof(bt_line), "BT: waiting");
      bt_colour = TFT_YELLOW;
    }
    else {
      snprintf(bt_line, sizeof(bt_line), "BT: starting");
      bt_colour = TFT_WHITE;
    }
    tft.setTextColor(bt_colour, TFT_BLACK);
    tft.drawString(bt_line, 10, 150);
  }
}

static void wifi_ap_control(lv_event_t *e) {
  lv_obj_t * wifi_ap_button = lv_event_get_target_obj(e);
  if (wifi_ap_enabled == true) {
    wifi_ap_enabled = false;
    accesspoint_stop();
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  else {
    wifi_ap_enabled = true;
    accesspoint_start();
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
}

void accesspoint_start() {
  if (wifi_ap_enabled == true) {
    IPAddress gw_ip(192, 168, 4, 1);
    IPAddress ip(192, 168, 4, 1);
    IPAddress subnet(255, 255, 255, 0);
    Serial.println("Turning on the ap");
    if (wifi_update != "") {
      JSONVar wifi = JSON.parse(wifi_update);
      ap_ssid = (const char *)wifi["ap_ssid"];
      ap_password = (const char *)wifi["ap_password"];
    }
    if (WiFi.softAP(ap_ssid, ap_password)) {
      WiFi.softAPConfig(ip, gw_ip, subnet); //, IPAddress dhcp_lease_start = (uint32_t)0, IPAddress dns = (uint32_t)0);
      server.begin();
      webserver_enabled = true;
      apIP = WiFi.softAPIP();
    }
  }
}


void accesspoint_stop() {
  WiFi.softAPdisconnect();
  server.stop();
  if (wifi_enabled == false) {
    webserver_enabled = false;
  }
}

