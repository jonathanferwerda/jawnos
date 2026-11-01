void settingSensor()
{
  static bool registered = false;
  if (registered) {
    return;
  }
  registered = true;
  // The library configures the BMA423 (accelerometer, pedometer and its
  // interrupts) itself now; this subscribes the sketch to the events it sends.
  watch.onEvent(SENSOR_EVENT, [](const DeviceEvent &event, void *user_data) {
    switch (watch.getSensorEventType(event)) {
      case SENSOR_STEP_DETECTED:
      case SENSOR_STEPS_UPDATED:
      case SENSOR_TILT_DETECTED:
      case SENSOR_ACTIVITY_DETECTED:
      case SENSOR_ANY_MOTION_DETECTED:
      case SENSOR_DOUBLE_TAP_DETECTED:
      case SENSOR_SINGLE_TAP_DETECTED:
        sportsIrq = true;
        break;
      default:
        break;
    }
  });
  // Wake the chip at the start of the movement, not only when the tilt feature
  // finally agrees: its verdict lands after the arm is already up. Any-motion
  // rides the same interrupt pin. Any-motion mapped to INT1 crashed the watch
  // seconds after boot (reset reason 4, twice in a row, on 2026-10-09), so the
  // wake stays with the tilt/tap/step events the library already maps.
  // if (watch.sensor) {
  //   watch.sensor->enableAnyMotionDetection(SensorBMA4XX::MotionAxesConfig(1, 1, 1), true, true);
  //   Serial.println("[tilt] motion wake armed");
  // }
  Serial.println("[tilt] wake on the library's sensor events");
}

void setSportsFlag()
{
  sportsIrq = true;
}

void setPMUFlag()
{
  pmuIrq = true;
}

void settingPMU()
{
  static bool registered = false;
  if (registered) {
    return;
  }
  registered = true;
  // Power events (crown clicks, VBUS, charge state) come through the event loop
  // too; any of them counts as a reason to light the screen back up.
  watch.onEvent(POWER_EVENT, [](const DeviceEvent &event, void *user_data) {
    PMUEventType_t kind = watch.getPMUEventType(event);
    Serial.printf("[pmu] event %d\n", (int)kind);
    // only the crown is a screen button; charge and VBUS chatter must not light
    // the screen back up on their own
    if (kind == PMU_EVENT_KEY_CLICKED || kind == PMU_EVENT_KEY_LONG_PRESSED) {
      pmuIrq = true;
      if (!dozing) {
        // the crown toggles: with the screen already on, a click means sleep
        sleepRequested = true;
      }
    }
  });
}


static void touch_button4(lv_event_t *e) {
  net_room();

}

static void tilt_wake_control(lv_event_t *e) {
  lv_obj_t * tilt_button = lv_event_get_target_obj(e);

  if (tiltWake == true) {
    lv_obj_set_style_bg_color(tilt_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    tiltWake = false;
  }
  else {
    lv_obj_set_style_bg_color(tilt_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
    tiltWake = true;
  }
}

void net_room() {
  jw_room = "net";
  
  display_exit();
  // who the bridge is; ip_writer() keeps this line fresh from here on
  face_bt = face_label_maker(20, 80, &lv_font_montserrat_16, lv_color_hex(0xFFFFFF), 200);
  ip_writer();
  lv_obj_t * wifi_button = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(wifi_button, wifi_control, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(wifi_button, 10, 30 );
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
  lv_obj_set_pos(wifi_ap_button, 60, 30 );
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
  lv_obj_set_pos(bt_button, 190, 30 );
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

  lv_obj_t * tilt_button = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(tilt_button, tilt_wake_control, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(tilt_button, 115, 30 );
  lv_obj_set_size(tilt_button, 40, 40 );
  if (tiltWake == true) {
    lv_obj_set_style_bg_color(tilt_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(tilt_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_t *lwi4;
  lv_color_t twi4;
  twi4 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(tilt_button, twi4, LV_PART_MAIN);
  lwi4 = lv_label_create(tilt_button);
  lv_label_set_text(lwi4, "TW");
  lv_obj_center(lwi4);

  full_refresh();
}

// a config file is only worth restoring (or backing up) if it says the watch
// has been set up at all; a clobbered or half-written one parses fine but every
// field is null/zero, and that picture must never win
static bool config_is_live(JSONVar conf) {
  if (String((const char *)conf["homebaseIP"]).length() > 0) return true;
  if (String((const char *)conf["ssid"]).length() > 0) return true;
  if (String((const char *)conf["authorization"]).length() > 0) return true;
  if (String((const char *)conf["buttoned_before"]) == "on") return true;
  return false;
}

void configSaveBackup() {
  // returner is a global that readFile() appends to: a stale boot report or an
  // earlier read would otherwise concatenate onto the config text
  returner = "";
  readFile(FFat, "/config.json");
  if (!config_is_live(JSON.parse(returner))) {
    Serial.println("[config] refusing to back up a blank config");
    return;
  }
  writeFile(FFat, "/config_backup.json", returner.c_str());  
}

void configRestoreBackup() {
  // returner is a global that readFile() appends to: without the reset, a
  // missing backup left the boot report text in it and this wrote that over
  // config.json -- one of the ways the watch's settings were erased
  returner = "";
  readFile(FFat, "/config_backup.json");
  if (!config_is_live(JSON.parse(returner))) {
    Serial.println("[config] no live backup to restore; leaving config.json alone");
    return;
  }
  writeFile(FFat, "/config.json", returner.c_str());  
}

// configSave() runs on every sleep, but the picture usually has not changed:
// flashing the whole config each time wore the flash and cost the user time.
// config_saved is the picture last written; config_saved_sig is the same picture
// with the step samples masked, so the ever-moving step data can be told from a
// real settings change, and an unchanged picture is not written at all.
static String config_saved;
static String config_saved_sig;
static uint32_t config_saved_at = 0;
#define CONFIG_STEPS_SAVE_MS (60 * 1000UL)

// The clean-boot marker, read without readFile() (which appends to the shared
// `returner`). setup() writes "saving" while it restores, so the next save has to
// put "success" back; a failed fetch writes "failure" for the same reason. A read
// costs no flash wear, so only a dirty marker is rewritten.
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

void configSave() {
  JSONVar conf;
  if (lightSleep == true) {
      conf["lightsleep"] = "on";
  }
  else {
    lightSleep == false;
  }
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
  if (buttoned_before == true) {
    conf["buttoned_before"] = "on";
  }
  else {
    conf["buttoned_before"] = "off";
  }
  if (stepCounter == true) {
    conf["step_counter"] = "on";
  }
  else {
    conf["step_counter"] = "off";
  }
  if (tiltWake == true) {
    conf["tilt_wake"] = "on";
  }
  else {
    conf["tilt_wake"] = "off";
  }
  if (voiceCaptureEnabled == true) {
    conf["voice_capture"] = "on";
  }
  else {
    conf["voice_capture"] = "off";
  }
  // the wake-word choice rides in a Now Me and, before this, was lost on every
  // reboot: with capture on the listener fell back to the VAD even though the
  // panel had picked a phrase. Keep it with the rest of the settings so the
  // chosen phrase survives a restart.
  conf["voice_trigger"] = voice_trigger;
  conf["voice_floor"] = voice_floor;
  conf["before_me"] = before_me;
  conf["jw_room"] = jw_room;
  String wigi_wah = JSON.stringify(wigi);
  conf["wigi"] = wigi_wah;
  String notifications_list = JSON.stringify(notifications);
  conf["notifications"] = notifications_list;
  // the step samples are the watch's own record of what it has not sent yet, so
  // keep them with the rest of the config rather than losing them to a restart
  conf["steps"] = JSON.stringify(stepped);
  conf["authorization"] = authorization;
  conf["ssid"] = ssid;
  conf["password"] = password;
  conf["ap_ssid"] = ap_ssid;
  conf["ap_password"] = ap_password;
  String aj = JSON.stringify(authorization_json);
  conf["aj"] = aj;
  conf["before_me"] = before_me;
  	conf["homebase"] = homebase;
  	conf["homebaseIP"] = homebaseIP;
  	// The preferred machine is what a reboot should restore; the active one may
  	// be a temporary fallback.
	conf["homebase_preferredIP"] = homebase_preferredIP.length() ? homebase_preferredIP : homebaseIP;
  conf["computer_name"] = computer_name;
  conf["brightness"] = brightnessLevel;
  conf["vibrate"] = vibrateLevel;
  conf["volume"] = volumeLevel;
  conf["screen_timeout"] = DEFAULT_SCREEN_TIMEOUT;
  conf["screenRotation"] = screenRotation;
  conf["room_count"] = room_count;
  conf["offset"] = offset;
  returner = JSON.stringify(conf);
  // keep the clean-boot marker honest even when the picture itself is unchanged:
  // setup() wrote "saving" as it restored, and a failed fetch writes "failure",
  // and a boot that reads either would restore from the backup. A tiny read, and
  // a write only when the marker is not already clean.
  if (!bootreport_is_clean()) {
    writeFile(FFat, "/bootreport.txt", "success");
  }
  // a watch that has nothing configured must not write the empty picture over
  // its own flash: the doze save used to cement a wiped config for good
  if (homebaseIP.length() == 0 && authorization.length() == 0 &&
      ssid.length() == 0 && buttoned_before == false) {
    Serial.println("[config] nothing configured yet; not saving");
    return;
  }
  // the same picture with the steps masked, so a step sample (which changes
  // continuously while the watch moves) is not mistaken for a settings change
  conf["steps"] = "";
  String signature = JSON.stringify(conf);
  if (signature == config_saved_sig) {
    if (returner == config_saved) {
      return;                        // the picture is unchanged: no write
    }
    if (millis() - config_saved_at < CONFIG_STEPS_SAVE_MS) {
      return;                        // only the steps moved; wait for the next sleep
    }
  }
  // LittleFS truncates in place, so a reset mid-save used to leave a clobbered
  // config.json (the panic reboots did exactly that, and the watch came back
  // with factory settings). Stage in a temp file and rename over the old one --
  // and FFat.rename() will not clobber an existing file, so that file has to be
  // removed first; the fresh copy is already safe in /config.tmp by then.
  writeFile(FFat, "/config.tmp", returner.c_str());
  if (FFat.exists("/config.json")) {
    FFat.remove("/config.json");
  }
  if (!FFat.rename("/config.tmp", "/config.json")) {
    writeFile(FFat, "/config.json", returner.c_str());
  }
  config_saved = returner;
  config_saved_sig = signature;
  config_saved_at = millis();
}

// the picture a never-configured watch comes up with: a boot with nothing
// usable to restore, and the Configure room's Delete, both start from here, and
// configRestore() overlays whatever the file actually holds on top
void configDefaults() {
  before_me = "";
  jw_room = "watch";
	  homebase = "";
	  homebaseIP = "";
	  homebase_preferredIP = "";
	  house_node_count = 0;
  computer_name = "";
  authorization = "";
  ssid = "";
  password = "";
  ap_ssid = base_ap_ssid;
  ap_password = base_ap_password;
  // 0/1 would leave the screen dark and the watch looking bricked
  brightnessLevel = 80;
  room_count = 6;
  buttoned_before = false;
  wifi_ap_enabled = false;
  wifi_enabled = false;
  bt_enabled = true;
  loraChatBroadcaster = false;
  loraChatReceiver = false;
  lightSleep = false;
  stepCounter = true;
  tiltWake = true;
  voiceCaptureEnabled = false;
  wigi = JSON.parse("[]");
  notifications = JSON.parse("[]");
  DEFAULT_SCREEN_TIMEOUT = 30*1000;
  screenRotation = 0;
  offset = 0;
  rtc.offset = 0;
}

void configDelete() {
  deleteFile(FFat, "/config.json");
  deleteFile(FFat, "/config_backup.json");

  writeFile(FFat, "/bootreport.txt", "deleting");
  config_saved = "";             // the files are gone: the next save must write
  config_saved_sig = "";
  configDefaults();
  brightnessLevel = 12;
  watch.setRotation(screenRotation);
}
