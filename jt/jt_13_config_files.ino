void configSave() {
  JSONVar conf;
  if (wifi_ap_enabled == true) {
    conf["wifi_ap_enabled"] = "on";
  }
  else {
    conf["wifi_ap_enabled"] = "off";
  }
  if (wifi_enabled == true) {
    conf["wifi_enabled"] = "on";
  }
  else {
    conf["wifi_enabled"] = "off";
  }
  if (bt_enabled == true) {
    conf["bt_enabled"] = "on";
  }
  else {
    conf["bt_enabled"] = "off";
  }
  if (lightSleep == true) {
    conf["lightsleep"] = "on";
  }
  else {
    conf["lightsleep"] = "off";
  }
  if (loraChatBroadcaster == true) {
    conf["loraChatBroadcaster"] = "on";
  }
  else {
    conf["loraChatBroadcaster"] = "off";
  }
  if (loraChatReceiver == true) {
    conf["loraChatReceiver"] = "on";
  }
  else {
    conf["loraChatReceiver"] = "off";
  }
  conf["lorawan_enabled"] = lorawan_enabled ? "on" : "off";
  conf["lorawan_band"] = lorawan_band;
  conf["lorawan_subband"] = lorawan_subband;
  conf["lorawan_join_eui"] = lorawan_join_eui;
  conf["lorawan_dev_eui"] = lorawan_dev_eui;
  conf["lorawan_app_key"] = lorawan_app_key;
  conf["lorawan_fport"] = lorawan_fport;
  conf["lorawan_confirmed"] = lorawan_confirmed ? "on" : "off";
  if (buttoned_before == true) {
    conf["buttoned_before"] = "on";
  }
  else {
    conf["buttoned_before"] = "off";
  }

  conf["tauth_remote_enabled"] = tauth_remote_enabled;
  conf["offset"] = offset;
  conf["mouse_move_relative"] = mouse_move_relative;
  conf["before_me"] = before_me;
  conf["jw_room"] = jw_room;
  conf["name"] = name;
  conf["authorization"] = authorization;
  conf["ssid"] = ssid;
  conf["password"] = password;
  conf["ap_ssid"] = ap_ssid;
  conf["ap_password"] = ap_password;
  String aj = JSON.stringify(authorization_json);
  conf["aj"] = aj;
  conf["auth_count"] = auth_count;
  conf["before_me"] = before_me;
  conf["homebase"] = homebase;
  conf["homebaseIP"] = homebaseIP;
  conf["twshomebaseIP"] = twshomebaseIP;
  conf["thomebaseIP"] = thomebaseIP;
  // The preferred House machine is what a reboot restores; the active
  // addresses may name a temporary fallback.
  conf["homebase_preferredIP"] = homebase_preferredIP.length() ? homebase_preferredIP : homebaseIP;
  conf["thomebase_preferredIP"] = thomebase_preferredIP.length() ? thomebase_preferredIP : thomebaseIP;
  conf["twshomebase_preferredIP"] = twshomebase_preferredIP.length() ? twshomebase_preferredIP : twshomebaseIP;
  conf["computer_name"] = computer_name;
  conf["brightness"] = brightnessLevel;
  conf["room_count"] = room_count;
  // the panel's voice setting: the trigger names the model voice_trigger_apply()
  // arms, the floor is what a wake capture ends on. Kept so the choice survives
  // a restart even before the next Now Me.
  conf["voice_trigger"] = voice_trigger;
  conf["voice_floor"] = voice_floor;
  conf["volume"] = volumeLevel;
  conf["fontSize"] = fontSize;
  conf["fontSelect"] = fontSelect;
  conf["community_room"] = community_room;
  conf["account_room"] = account_room;
  conf["project_room"] = project_room;
  conf["club_room"] = club_room;
  conf["team_room"] = team_room;
  conf["contact_room"] = contact_room;
  String wigi_wah = JSON.stringify(wigi);
  conf["wigi"] = wigi_wah;
  String returner = JSON.stringify(conf);
  // keep the clean-boot marker honest even when the picture is unchanged: setup()
  // wrote "saving" as it restored, and a failed fetch writes "failure", and a
  // boot that reads either would restore from the backup. A tiny read, and a
  // write only when the marker is not already clean.
  if (!bootreport_is_clean()) {
    writeFile(FFat, "/bootreport.txt", "success");
  }
  // a deck that has nothing configured must not write the empty picture over
  // its own flash: a blank save cements a wipe for good
  if (homebaseIP.length() == 0 && authorization.length() == 0 &&
      ssid.length() == 0 && buttoned_before == false) {
    deckLog("[config] nothing configured yet; not saving");
    return;
  }
  // an unchanged picture is not written at all: the screen-sleep save used to
  // flash the whole config every time
  if (returner == config_saved_sig) {
    return;
  }
  deckLog("[config] saving %u bytes", (unsigned)returner.length());
  // LittleFS truncates in place, so a reset mid-save leaves a clobbered
  // config.json; stage in a temp file, drop the old one, then rename over it
  writeFile(FFat, "/config.tmp", returner.c_str());
  if (FFat.exists("/config.json")) {
    FFat.remove("/config.json");
  }
  if (!FFat.rename("/config.tmp", "/config.json")) {
    writeFile(FFat, "/config.json", returner.c_str());
  }
  config_saved_sig = returner;
}

// the picture a never-configured deck comes up with: a boot with nothing
// usable to restore, and Configure's Delete, both start from here
void configDefaults() {
  before_me = "";
  jw_room = "gate";
  homebase = "";
  name = "LilyGo T-Deck Pro";
  homebaseIP = "";
  thomebaseIP = "";
  twshomebaseIP = "";
  homebase_preferredIP = "";
  thomebase_preferredIP = "";
  twshomebase_preferredIP = "";
  house_node_count = 0;
  offset = 0;
  rtc.offset = 0;
  computer_name = "";
  authorization = "";
  ssid = "";
  room_count = 6;
  brightnessLevel = 5;
  volumeLevel = 5;
  fontSize = 4;
  fontSelect = "";
  password = "";
  ap_ssid = base_ap_ssid;
  ap_password = base_ap_password;
  authorization_json = JSON.parse("[]");
  wigi = JSON.parse("[]");
  auth_count = 0;
  mouse_move_relative = "off";
  buttoned_before = false;
  wifi_ap_enabled = false;
  wifi_enabled = false;
  bt_enabled = true;      // the preference: the radio is wanted
  lightSleep = false;
	  loraChatBroadcaster = false;
	  loraChatReceiver = false;
	  lorawan_enabled = false;
	  lorawan_band = "EU433";
	  lorawan_subband = 1;
	  lorawan_join_eui = "";
	  lorawan_dev_eui = "";
	  lorawan_app_key = "";
	  lorawan_fport = 1;
	  lorawan_confirmed = false;
	  lorawan_last_error = "";
  tauth_remote_enabled = "off";
  voice_trigger = "off";
  voice_floor = "auto";
  voiceCaptureEnabled = false;
  account_room, community_room, club_room, team_room, contact_room, project_room = "";
}

void configDelete() {
  deleteFile(FFat, "/config.json");
  deckLog("[config] deleted");
  writeFile(FFat, "/bootreport.txt", "deleting");
  configDefaults();
}


// a config file is only worth restoring if it says the deck has been set up;
// a clobbered or half-written one parses fine but every field is null/zero,
// and that picture must never win
static bool config_is_live(JSONVar conf) {
  if (String((const char *)conf["homebaseIP"]).length() > 0) return true;
  if (String((const char *)conf["ssid"]).length() > 0) return true;
  if (String((const char *)conf["authorization"]).length() > 0) return true;
  if (String((const char *)conf["buttoned_before"]) == "on") return true;
  return false;
}

void configRestore() {
  // start from the factory picture and let the file overlay it: a clobbered
  // field then falls back to its default instead of dragging the deck to zero
  configDefaults();
  returner = "";
  returner = readFile(FFat, "/config.json");
  writeFile(FFat, "/bootreport.txt", "saving");

  JSONVar conf = JSON.parse(returner);
  if (config_is_live(conf)) {
    before_me = (const char *)conf["before_me"];
    community_room = (const char *)conf["community_room"];
    club_room = (const char *)conf["club_room"];
    team_room = (const char *)conf["team_room"];
    project_room = (const char *)conf["project_room"];
    account_room = (const char *)conf["account_room"];
    contact_room = (const char *)conf["contact_room"];
    name = (const char *)conf["name"];
    offset = conf["offset"];
    rtc.offset = offset;
    homebase = (const char *)conf["homebase"];
    homebaseIP = (const char *)conf["homebaseIP"];
    twshomebaseIP = (const char *)conf["twshomebaseIP"];
    thomebaseIP = (const char *)conf["thomebaseIP"];
    homebase_preferredIP = (const char *)conf["homebase_preferredIP"];
    thomebase_preferredIP = (const char *)conf["thomebase_preferredIP"];
    twshomebase_preferredIP = (const char *)conf["twshomebase_preferredIP"];
    if (homebase_preferredIP.length() == 0) { homebase_preferredIP = homebaseIP; }
    if (thomebase_preferredIP.length() == 0) { thomebase_preferredIP = thomebaseIP; }
    if (twshomebase_preferredIP.length() == 0) { twshomebase_preferredIP = twshomebaseIP; }
    house_remember_preferred();
    computer_name = (const char *)conf["computer_name"];
    authorization = (const char *)conf["authorization"];
    ssid = (const char *)conf["ssid"];

    brightnessLevel = conf["brightness"];
    volumeLevel = conf["volume"];
    room_count = conf["room_count"];
    // A config that could not be written (a full flash leaves config.json at 0
    // bytes) parses as all zeroes, which would boot to a dark, silent device
    // with 0 rooms. Keep the device usable enough to fix itself.
    if (brightnessLevel < 1) {
      brightnessLevel = 5;
    }
    if (volumeLevel < 1) {
      volumeLevel = 5;
    }
    if (room_count < 1) {
      room_count = 6;
    }
    fontSize = conf["fontSize"];
    fontSelect = (const char * )conf["fontSelect"];
    setBrightness(brightnessLevel);
    password = (const char *)conf["password"];
    ap_ssid = (const char *)conf["ap_ssid"];
    ap_password = (const char *)conf["ap_password"];
    String aj = (const char *)conf["aj"];
    authorization_json = JSON.parse(aj);
    String wigi_wah = (const char *)conf["wigi"];
    wigi = JSON.parse(wigi_wah);

    auth_count = conf["auth_count"];
    authorization_dedupe();   // a save from before the replacement rule can hold one house many times
    mouse_move_relative = (const char *)conf["mouse_move_relative"];
    { String vt = (const char *)conf["voice_trigger"]; if (vt.length()) { voice_trigger = vt; } }
    { String vf = (const char *)conf["voice_floor"]; if (vf.length()) { voice_floor = vf; } }

    String bb = (const char *)conf["buttoned_before"];
    if (bb == "on") {
      buttoned_before = true;
    }
    else {
      buttoned_before = false;
    }
    String wpae = (const char *)conf["wifi_ap_enabled"];
    if (wpae == "on") {
      wifi_ap_enabled = true;
      accesspoint_start();
    }
    else {
      wifi_ap_enabled = false;
    }

    String we = (const char *)conf["wifi_enabled"];
    if (we == "on") {
      wifi_enabled = true;
    }
    else {
      wifi_enabled = false;
    }
    String bte = (const char *)conf["bt_enabled"];
    if (bte == "on") {
      bt_enabled = true;
      btStartPending = true;   // loop() starts it; doing it here panicked boards on boot
    }
    else {
      bt_enabled = false;
      stop_ble_transfer();
    }
    String ls = (const char *)conf["lightsleep"];
    if (ls == "on") {
      lightSleep = true;
    }
    else {
      lightSleep = false;
    }
    wifi_start_async();
    String lcb = (const char *)conf["loraChatBroadcaster"];
    if (lcb == "on") {
      loraChatBroadcaster = true;
    }
    else {
      loraChatBroadcaster = false;
    }
    String lcr = (const char *)conf["loraChatReceiver"];
    if (lcr == "on") {
      loraChatReceiver = true;
    }
    else {
      loraChatReceiver = false;
    }
    String lwe = (const char *)conf["lorawan_enabled"];
    lorawan_enabled = (lwe == "on");
    String lwb = (const char *)conf["lorawan_band"];
    if (lwb.length()) { lorawan_band = lwb; }
	    int lws = conf["lorawan_subband"];
	    lorawan_subband = (lws >= 1 && lws <= 8) ? (uint8_t)lws : 1;
    lorawan_join_eui = (const char *)conf["lorawan_join_eui"];
    lorawan_dev_eui = (const char *)conf["lorawan_dev_eui"];
    lorawan_app_key = (const char *)conf["lorawan_app_key"];
	    int lwf = conf["lorawan_fport"];
	    lorawan_fport = (lwf >= 1 && lwf <= 223) ? (uint8_t)lwf : 1;
    lorawan_confirmed = (String((const char *)conf["lorawan_confirmed"]) == "on");
    tauth_remote_enabled = (const char *)conf["tauth_remote_enabled"];
    if (tauth_remote_enabled == "on") {
      // Not here: the dial blocks on the connect timeout, and this is setup().
      // loop() makes it once the room is on screen.
      tauth_connect_pending = true;
    }
    else {
      tauth_cancel();
    }
  }
  if (bt_enabled == true && btStartPending == false) {
    // the defaults (or a live config) say the radio should be on; arm the
    // deferred start that loop() runs once the boot has settled
    btStartPending = true;
  }
  voice_trigger_apply();   // arm the listener for the restored voice setting
  call_the_president();
  jw_room = (const char *)conf["jw_room"];
  troom = "home";
  if (jw_room == "room") {
    rb_count = 0;    
    remote_room();


  }
  else if (jw_room == "watch") {
    clock_writer();
  }
  else if (jw_room == "configure") {
    setting_room();
  }
  else if (jw_room == "net") {
    net_room();
  }
  else if (jw_room == "chat") {
    chat_displayer();
  }
  else if (jw_room == "pen") {
    pen_room();
  }
  else {
    clock_writer();
  }
  lv_task_handler();

}


void writeFile(fs::FS &fs, const char * path, const char *  message) {
  Serial.printf("Writing file: %s\r\n", path);
  File file = fs.open(path, FILE_WRITE);
  if (!file) {
    Serial.println("- failed to open file for writing");
    return;
  }
  if (file.print(message)) {
    Serial.println("- file written");
  } else {
    Serial.println("- write failed");
  }
  listDir(FFat, "/", 0);
  file.close();
}

String readFile(fs::FS &fs, const char * path) {
  // Serial.printf("Reading file: %s\r\n", path);

  File file = fs.open(path);
  if (!file || file.isDirectory()) {
     Serial.println("- failed to open file for reading");
    return "failure";
  }

  while (file.available()) {
    returner += (char)file.read();
  }
  file.close();
  // a size, not the file: this used to print it a character at a time, and a
  // 25 KB config walked the console into a wedge on every boot
  deckLog("[file] %s: %u bytes", path, (unsigned)returner.length());
  return returner;
}

void appendFile(fs::FS &fs, const char * path, const char * message) {
  // Serial.printf("Appending to file: %s\r\n", path);

  File file = fs.open(path, FILE_APPEND);
  if (!file) {
    // Serial.println("- failed to open file for appending");
    return;
  }
  if (file.print(message)) {
    // Serial.println("- message appended");
  } else {
    // Serial.println("- append failed");
  }

  file.close();
}

void createDir(fs::FS &fs, const char * path){
    Serial.printf("Creating Dir: %s\n", path);
    if (!fs.open(path)) {
      if(fs.mkdir(path)){
          Serial.println("Dir created");
      } else {
          Serial.println("mkdir failed");
      }
    }
    else {
      Serial.println("Directory Exists");
    }
}

void listDir(fs::FS &fs, const char * dirname, uint8_t levels) {
  Serial.printf("Listing directory: %s\r\n", dirname);

  File root = fs.open(dirname);
  if (!root) {
    Serial.println("- failed to open directory");
    return;
  }
  if (!root.isDirectory()) {
    Serial.println(" - not a directory");
    return;
  }

  File file = root.openNextFile();
  while (file) {
    if (file.isDirectory()) {
      Serial.print("  DIR : ");
      Serial.println(file.name());
      if (levels) {
        listDir(fs, file.path(), levels - 1);
      }
    } else {
      Serial.print("  FILE: ");
      Serial.print(file.name());
      Serial.print("\tSIZE: ");
      Serial.println(file.size());
    }
    file = root.openNextFile();
  }
}

void deleteFile(fs::FS &fs, const char * path) {
  // Serial.printf("Deleting file: %s\r\n", path);

  if (fs.remove(path)) {
    // Serial.println("- file deleted");
  } else {
    // Serial.println("- delete failed");
  }
}

