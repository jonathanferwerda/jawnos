static void mouse_move_relativity(lv_event_t *e) {
  lv_obj_t * mmrb = lv_event_get_target_obj(e);
  String b = (const char * )authorization_json[auth_watch];
  JSONVar bm = JSON.parse(b);
  if (mouse_move_relative == "on") {
    mouse_move_relative = "off";
    bm["__specs"]["mouse_move_relative"] = "off";
    lv_obj_set_style_bg_color(mmrb, lv_color_hex(0xb0b0b0), LV_PART_MAIN);

  }
  else {
    mouse_move_relative = "on";
    bm["__specs"]["mouse_move_relative"] = "on";
    lv_obj_set_style_bg_color(mmrb, lv_color_hex(0x7abcdd), LV_PART_MAIN);

  }

  authorization_json[auth_watch] = JSON.stringify(bm);
  before_me = (const char *)authorization_json[auth_watch];
}

static void configSaveButton(lv_event_t *e) {
  configSave();
}

static void configRestoreButton(lv_event_t *e) {
  configRestore();
  setting_room();

}

static void configDeleteButton(lv_event_t *e) {
  configDelete();
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
  if (hasRadio) {
    radio.startTransmit(public_announcement);
  }
  //Serial.print(public_announcement);
}


static void wifi_lora_send(lv_event_t *e) {

  JSONVar pa;
  pa["ap_ssid"] = ssid;
  pa["ap_password"] = password;
  String public_announcement = JSON.stringify(pa);
  if (hasRadio) {
    radio.startTransmit(public_announcement);
  }
  //Serial.print(public_announcement);
}

void remote_writer() {
  if (auth_count > 0) {
    Serial.println("In the remote writer");
    String b = (const char *)authorization_json[auth_watch];
    JSONVar bm = JSON.parse(b);

    lv_obj_t * btn2 = lv_btn_create(lv_scr_act());
    lv_obj_add_event_cb(btn2, authorization_deleter, LV_EVENT_CLICKED, NULL);
    lv_obj_set_pos(btn2, 10, 160 );
    lv_obj_set_size(btn2, 30, 30 );
    lv_obj_set_style_bg_color(btn2, lv_color_hex(0xff0000), LV_PART_MAIN);
    lv_task_handler();
    lv_obj_t *l2;
    lv_color_t t2;
    t2 = lv_color_make(0, 0, 0);

    lv_obj_set_style_text_color(btn2, t2, LV_PART_MAIN);

    l2 = lv_label_create(btn2);

    lv_label_set_text_fmt(l2, "%s", "X" );

    lv_obj_center(l2);

    lv_obj_t * btn3 = lv_btn_create(lv_scr_act());
    lv_obj_add_event_cb(btn3, authorization_change_trigger, LV_EVENT_CLICKED, NULL);
    lv_obj_set_pos(btn3, 50, 160 );
    lv_obj_set_size(btn3, 30, 30 );
    lv_obj_set_style_bg_color(btn3, lv_color_hex(0x00ff00), LV_PART_MAIN);
    lv_task_handler();
    lv_obj_t *l3;
    lv_color_t t3;
    t3 = lv_color_make(0, 0, 0);
    lv_obj_set_style_text_color(btn3, t3, LV_PART_MAIN);
    l3 = lv_label_create(btn3);

    lv_label_set_text_fmt(l3, "%d", auth_count);
    lv_obj_center(l3);


    lv_obj_t * btn12 = lv_btn_create(lv_scr_act());
    lv_obj_add_event_cb(btn12, mouse_move_relativity, LV_EVENT_CLICKED, NULL);
    lv_obj_set_pos(btn12, 180, 160 );
    lv_obj_set_size(btn12, 30, 30 );
    lv_obj_t *l12;
    lv_color_t t12;
    t12 = lv_color_make(0, 0, 0);
    if (mouse_move_relative == "on") {
      lv_obj_set_style_bg_color(btn12, lv_color_hex(0x7abcdd), LV_PART_MAIN);
    }
    else {
      lv_obj_set_style_bg_color(btn12, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    }
    lv_obj_set_style_text_color(btn12, t12, LV_PART_MAIN);
    l12 = lv_label_create(btn12);
    lv_label_set_text(l12, "MM");
    lv_obj_center(l12);

    lv_obj_t * btn30 = lv_btn_create(lv_scr_act());
    lv_obj_set_pos(btn30, 220, 160 );
    lv_obj_set_size(btn30, 30, 30 );
    lv_obj_add_event_cb(btn30, tauthToggleButton, LV_EVENT_CLICKED, NULL);
    if (tauth_remote_enabled == "on") {
      lv_obj_set_style_bg_color(btn12, lv_color_hex(0xfbb0c0), LV_PART_MAIN);
    }
    else {
      lv_obj_set_style_bg_color(btn12, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    }
    lv_obj_t *l30;
    lv_color_t t30;
    t30 = lv_color_make(0, 0, 0);
    lv_obj_set_style_text_color(btn30, t30, LV_PART_MAIN);
    l30 = lv_label_create(btn30);
    lv_label_set_text(l30, "Re");
    lv_obj_center(l30);
  }
  Serial.println("Done remote writing");
}


static void authorization_deleter(lv_event_t *e) {
  tauth_cancel();
  authorization_json[auth_watch] = undefined;
  if (auth_watch >= 1) {
    for (int n = 1; n <= auth_count; n++) {
      if (authorization_json[auth_watch] == undefined) {
        // authorization_json[auth_watch] = undefined;
      }
    }
    auth_watch--;
    auth_count--;
  }
  if (auth_watch != 0) {
    before_me = (const char *)authorization_json[auth_watch];
    JSONVar bm = JSON.parse(before_me);
    if (1) {
      //  Serial.println("updating the room");
      homebase = (const char *)bm["__specs"]["ip"];
      homebaseIP = (const char *)bm["__specs"]["homebase"];
      //  room_max = bm["__specs"]["room_max"];
      room_count = bm["__specs"]["room_count"];
      computer_name = (const char *)bm["__specs"]["computer"];
    }

    room = 1;
  }
  else {
    before_me = "";
    account_room, contact_room, project_room, community_room, club_room, team_room = "";
    before_me = "";
  }
  remote_room();
}

static void authorization_change_trigger(lv_event_t *e) {
  authorization_changer("up");

  call_the_president();
  display_exit();
}

void authorization_changer(String mov) {
  //Serial.println("auth void");
  if (mov == "up" || mov == "") {
    if (auth_watch < auth_count) {
      auth_watch++;
      //  Serial.print(auth_watch);
      //  Serial.println(" add");
      //  Serial.print("counting " );
      //  Serial.println(auth_count);
    }
    else {
      auth_watch = 1;
      //  Serial.println("auth watch 0");
    }
  }
  else {
    if (auth_watch > 1) {
      auth_watch--;
      //  Serial.print(auth_watch);
      //  Serial.println(" add");
      //  Serial.print("counting " );
      //  Serial.println(auth_count);
    }
    else {
      auth_watch = auth_count;
      //  Serial.println("auth watch 0");
    }
  }
  before_me = (const char *)authorization_json[auth_watch];
  Serial.println(before_me);
  JSONVar bm = JSON.parse(before_me);
  //  Serial.println("updating the room");
  homebase = (const char *)bm["__specs"]["ip"];
  homebaseIP = (const char *)bm["__specs"]["homebase"];
  thomebaseIP = (const char *)bm["__specs"]["thomebase"];
  twshomebaseIP = (const char *)bm["__specs"]["twshomebase"];
  homebase_preferredIP = homebaseIP;
  thomebase_preferredIP = thomebaseIP;
  twshomebase_preferredIP = twshomebaseIP;
  house_last_scan = 0;

  //  room_max = bm["__specs"]["room_max"];
  room_count = bm["__specs"]["room_count"];
  computer_name = (const char *)bm["__specs"]["computer"];
  {
    // a saved profile carries the Now Me pair it was captured with
    String auth = (const char *)bm["__specs"]["authorization"];
    if (auth.length()) { authorization = auth; }
  }
  mouse_move_relative = (const char * )bm["__specs"]["mouse_move_relative"];
  tauth_remote_enabled = (const char * )bm["__specs"]["tauth_remote_enabled"];

  if (tauth_remote_enabled == "on") {
    // the saved profile names this House machine: the control socket follows it
    wsclient.close();
    ws_connected = 0;
    tauth_connect();
  }
  else {
    tauth_cancel();
  }
  room = 1;
  remote_room();
}

// The homebase a saved payload belongs to: its __specs.homebase ("ip:port"),
// or the machine's name when that is missing. The key is what keeps one entry
// per house instead of one per Now Me (2026-10-09).
static String authorization_key(String js) {
  JSONVar d = JSON.parse(js);
  String k = (const char *)d["__specs"]["homebase"];
  if (k.length() == 0) {
    k = (const char *)d["__specs"]["computer"];
  }
  return k;
}

void authorization_pusher(String js) {
  // The same house calling Now Me again takes its old slot: the count button
  // used to grow with every press because this always appended.
  String key = authorization_key(js);
  if (key.length() > 0) {
    for (int i = 1; i <= auth_count; i++) {
      if (authorization_json[i] == undefined) {
        continue;
      }
      if (authorization_key((const char *)authorization_json[i]) == key) {
        authorization_json[i] = js;      // known homebase: replace in place
        auth_watch = i;
        // A String that has never held anything has a NULL buffer, and c_str()
        // returns it: passing that to a %s is a strlen(NULL) panic (the Now Me
        // that arrives while the room fetch could not reach homebase is exactly
        // this - before_me carries no homebase, so key is empty).
        const char *ks = key.c_str();
        deckLog("[auth] replaced %s (count %d)", ks ? ks : "", auth_count);
        return;
      }
    }
  }
  auth_count++;
  if (auth_watch == 0) {
    auth_watch = 1;
  }
  room = 1;
  authorization_json[auth_count] = js;
  {
    const char *ks = key.c_str();
    deckLog("[auth] added %s (count %d)", ks ? ks : "", auth_count);
  }
}

// One entry per homebase, newest payload winning: a save from before the
// replacement rule above can hold the same house many times over.
static void authorization_dedupe() {
  JSONVar kept = JSON.parse("[]");
  int keep = 0;
  for (int i = 1; i <= auth_count; i++) {
    if (authorization_json[i] == undefined) {
      continue;
    }
    String js = (const char *)authorization_json[i];
    String key = authorization_key(js);
    bool replaced = false;
    for (int k = 1; k <= keep; k++) {
      if (key.length() > 0 && authorization_key((const char *)kept[k]) == key) {
        kept[k] = js;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      keep++;
      kept[keep] = js;
    }
  }
  authorization_json = kept;
  auth_count = keep;
  if (auth_watch > auth_count) {
    auth_watch = auth_count > 0 ? 1 : 0;
  }
}



static void tauthToggleButton(lv_event_t *e) {
  lv_obj_t * remb = lv_event_get_target_obj(e);
  String b = (const char *)authorization_json[auth_watch];
  JSONVar bm = JSON.parse(b);
  if (tauth_remote_enabled == "on") {
    tauth_cancel();
    lv_obj_set_style_bg_color(remb, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    bm["__specs"]["tauth_remote_enabled"] = "off";

  }
  else {
    tauth_remote_enabled = "off";
    tauth_connect();
    lv_obj_set_style_bg_color(remb, lv_color_hex(0xfbb0c0), LV_PART_MAIN);
    bm["__specs"]["tauth_remote_enabled"] = "on";
  }
  authorization_json[auth_watch] = JSON.stringify(bm);
  before_me = (const char *)authorization_json[auth_watch];
}

void tauth_cancel() {
  wsclient.close();
  ws_connected = 0;
  tauth_remote_enabled = false;
  String b = (const char *)authorization_json[auth_watch];
  JSONVar bm = JSON.parse(b);
  authorization_json[auth_watch] = JSON.stringify(bm);
  before_me = (const char *)authorization_json[auth_watch];
}



void tauth_connect() {
  // The control socket is a network socket: dialing before the station link is
  // up only spends the connect timeout in the loop.
  if (WiFi.status() != WL_CONNECTED) {
    ws_connected = 0;
    tauth_remote_enabled = "on";
    return;
  }
  if (ws_connected == 0 && authorization != "") {
    // twshomebaseIP is "host:port" (now_me's twshomebase). The socket is wss:
    // wsclient was built over InsecureDeckTcpClient above. The Now Me pair is
    // the credential the server checks, so there is no password to type.
    String ws_host = twshomebaseIP;
    int ws_port = 443;
    int split = ws_host.lastIndexOf(':');
    if (split > 0) {
      ws_port = ws_host.substring(split + 1).toInt();
      ws_host = ws_host.substring(0, split);
    }
    if (ws_host.length() == 0 || ws_port <= 0) {
      ws_connected = 0;
    }
    else {
      String ws_path = "/teletype/ws?authorization=" + urlEncode(authorization)
                     + "&edt=teletype&chip_id=" + urlEncode(chip_id_maker());
      deckLog("[auth] wss dial %s:%d", ws_host.c_str(), ws_port);
      ws_connected = wsclient.connect(ws_host, ws_port, ws_path);
      deckLog("[auth] wss %s", ws_connected ? "connected" : "failed");
      if (ws_connected) {
        wsclient.send("Hey Server");
        wsclient.ping();
      }
    }
  }
  tauth_remote_enabled = "on";

}

