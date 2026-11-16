// ---- configuration: the house URL, the bearer, and the WiFi ----------------
// FFat holds one JSON file, /config.json. The hat has no screen to type into, so
// phase 0 sets this over serial (a small shell command is phase-0 follow-up) and
// phase 1 can provision it from the house. The file is written through a temp
// file and renamed: LittleFS/FatFS truncates in place, and a reset mid-write
// otherwise leaves a half-written config that parses to zeroes and boots a
// silent hat (the deck's lesson in jt_13_config_files.ino).
static String jh_config_sig;

static String config_read() {
  File f = FFat.open("/config.json");
  if (!f || f.isDirectory()) {
    return "";
  }
  String out;
  out.reserve(f.size() + 1);
  while (f.available()) {
    out += (char)f.read();
  }
  f.close();
  return out;
}

static bool config_write(const String &body) {
  FFat.remove("/config.tmp");
  File f = FFat.open("/config.tmp", FILE_WRITE);
  if (!f) {
    jh_log("[cfg] cannot open /config.tmp");
    return false;
  }
  size_t wrote = f.print(body);
  f.close();
  if (wrote != body.length()) {
    jh_log("[cfg] short write (%u/%u)", (unsigned)wrote, (unsigned)body.length());
    FFat.remove("/config.tmp");
    return false;
  }
  FFat.remove("/config.json");
  if (!FFat.rename("/config.tmp", "/config.json")) {
    // The rename can fail on a filesystem that is itself unwell; a direct write
    // is better than losing the only copy of the configuration.
    File g = FFat.open("/config.json", FILE_WRITE);
    if (!g) {
      jh_log("[cfg] rename and direct write both failed");
      return false;
    }
    g.print(body);
    g.close();
  }
  return true;
}

void config_defaults() {
  jh_house_url = "";
  jh_house_token = "";
  jh_ssid = "";
  jh_password = "";
  jh_device_name = "JawnHat";
  jh_wifi_enabled = true;
}

// A file that parses but says nothing is worse than no file: it would overlay
// the factory defaults with empty strings and hide a half-written save. Only a
// picture with at least one usable field is accepted.
static bool config_is_live(JSONVar &conf) {
  if (String((const char *)conf["house_url"]).length() > 0) return true;
  if (String((const char *)conf["house_token"]).length() > 0) return true;
  if (String((const char *)conf["ssid"]).length() > 0) return true;
  return false;
}

void config_restore() {
  config_defaults();
  if (!FFat.begin()) {
    jh_log("[cfg] ffat did not mount; formatting");
    if (!FFat.begin(true)) {
      jh_log("[cfg] ffat unusable; running on defaults");
      return;
    }
  }
  String raw = config_read();
  if (!raw.length()) {
    jh_log("[cfg] no config.json; defaults");
    return;
  }
  JSONVar conf = JSON.parse(raw);
  if (JSON.typeof(conf) != "object" || !config_is_live(conf)) {
    jh_log("[cfg] config.json is not a live picture; defaults");
    return;
  }
  if (conf.hasOwnProperty("house_url")) jh_house_url = (const char *)conf["house_url"];
  if (conf.hasOwnProperty("house_token")) jh_house_token = (const char *)conf["house_token"];
  if (conf.hasOwnProperty("ssid")) jh_ssid = (const char *)conf["ssid"];
  if (conf.hasOwnProperty("password")) jh_password = (const char *)conf["password"];
  if (conf.hasOwnProperty("device_name")) jh_device_name = (const char *)conf["device_name"];
  if (conf.hasOwnProperty("wifi_enabled")) jh_wifi_enabled = (bool)conf["wifi_enabled"];
  jh_config_sig = raw;
  jh_log("[cfg] restored %u bytes", (unsigned)raw.length());
}

// Phase-0 provisioning over the USB console. The hat has no screen or keyboard,
// so this is the only way to give it a house URL before the BLE protocol has a
// configuration command (phase 1). Lines:
//
//   JHCONF url https://192.168.2.3:45547/manager/...
//   JHCONF token <bearer>
//   JHCONF ssid <ssid>
//   JHCONF pass <password>
//   JHCONF name JawnHat
//   JHCONF save
//   JHCONF show
//
// Each setter saves at once, except pass: config_save() refuses to write a
// picture with no url/token/ssid, so set the ssid first if pass is the first
// value entered.
void config_serial_loop() {
  if (!Serial.available()) {
    return;
  }
  String line = Serial.readStringUntil('\n');
  line.trim();
  if (!line.startsWith("JHCONF")) {
    return;
  }
  String rest = line.substring(6);
  rest.trim();
  int split = rest.indexOf(' ');
  String key = split < 0 ? rest : rest.substring(0, split);
  String value = split < 0 ? "" : rest.substring(split + 1);
  key.toLowerCase();
  value.trim();
  if (key == "url") {
    jh_house_url = value;
    config_save();
  }
  else if (key == "token") {
    jh_house_token = value;
    config_save();
  }
  else if (key == "ssid") {
    jh_ssid = value;
    config_save();
  }
  else if (key == "pass") {
    jh_password = value;
    config_save();
  }
  else if (key == "name") {
    jh_device_name = value.length() ? value : "JawnHat";
    config_save();
  }
  else if (key == "save") {
    config_save();
  }
  else if (key == "show") {
    // Never print the token: the console ends up in a log.
    jh_log("[cfg] url=%s ssid=%s name=%s token=%s(%u)",
           jh_house_url.length() ? jh_house_url.c_str() : "(none)",
           jh_ssid.length() ? jh_ssid.c_str() : "(none)", jh_device_name.c_str(),
           jh_house_token.length() ? "set" : "none", (unsigned)jh_house_token.length());
  }
  else {
    jh_log("[cfg] usage: JHCONF url|token|ssid|pass|name <value> | show | save");
  }
}

void config_save() {
  JSONVar conf;
  conf["house_url"] = jh_house_url;
  conf["house_token"] = jh_house_token;
  conf["ssid"] = jh_ssid;
  conf["password"] = jh_password;
  conf["device_name"] = jh_device_name;
  conf["wifi_enabled"] = jh_wifi_enabled;
  String body = JSON.stringify(conf);
  // A hat that has never been configured must not write the empty picture over
  // its own flash: a blank save cements a wipe for good.
  if (!jh_house_url.length() && !jh_house_token.length() && !jh_ssid.length()) {
    jh_log("[cfg] nothing configured; not saving");
    return;
  }
  if (body == jh_config_sig) {
    return;
  }
  if (config_write(body)) {
    jh_config_sig = body;
    jh_log("[cfg] saved %u bytes", (unsigned)body.length());
  }
}
