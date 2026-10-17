#include <Arduino.h>
#include <HTTPClient.h>
#include <WiFi.h>
// SimpleMDNS ships with the arduino-pico core and exposes the same global MDNS
// as the ESP32; advertise this pico on _jawnos._tcp so the Dev panel names it.
#include <SimpleMDNS.h>
#include <WebServer.h>
#include <time.h>
#include <sys/time.h>
#include <Arduino_JSON.h>
#include <Wire.h> 
#include <LiquidCrystal_I2C.h>
#include <LittleFS.h>
#include <Servo.h>
#include <PicoOTA.h>
#include <uri/UriRegex.h>
// Bluetooth: the board is also reachable as a Nordic UART peripheral, so a
// crashed Pico in its provisioning AP can be met by the house bridge and its
// role restored without WiFi. Requires -DPIO_FRAMEWORK_ARDUINO_ENABLE_BLUETOOTH
// (see platformio.ini).
#include <btstack.h>
#include <ble/att_db_util.h>
#include <ble/gatt-service/nordic_spp_service_server.h>
#include <BluetoothLock.h>
#include <LocklessQueue.h>
#include <map>

// Civil-date struct for the 64-bit clock display. Declared before any function
// so the Arduino-generated prototypes can see the return type.
struct jawn_time {
  int year, month, day, hour, min, sec;
};

LiquidCrystal_I2C lcd(0x27,20,4); 

int led = LED_BUILTIN;

// Owned strings. The form used to hand c_str() pointers into request-local
// Strings, which dangled as soon as the handler returned.
String ssid;
String password;

const char* host = "192.168.1.3";
const uint16_t port = 3000;
String ap_ssid = "Pico 2W";
String ap_password = "president";
WiFiMulti multi;
WebServer server(3000);
String homebase;
String homebaseIP;
String browser_tab_id;
unsigned long homebaseOnline = millis();
unsigned long lastPing = millis();
unsigned long lastPresidentTry = 0;
unsigned long lastWifiCheck = 0;
unsigned long lastTimeSync = 0;
int wifiDownTicks = 0;
String wifiState;
String authorization;
String before_me;
bool time_defined = false;
int64_t offset;
int input_working = 0;
JSONVar config;

// ---- clock ---------------------------------------------------------------
// The epoch is kept as 64-bit milliseconds plus the millis() value it was taken
// at, so scheduling and the LCD never depend on time_t's width. When the core
// has a 64-bit time_t the system clock is set as well; otherwise it is left
// alone rather than truncated.
int64_t epoch_ms = 0;
uint32_t epoch_ref = 0;
#if defined(__SIZEOF_TIME_T__)
static const bool TIME_T_IS_64 = (__SIZEOF_TIME_T__ >= 8);
#else
static const bool TIME_T_IS_64 = (sizeof(time_t) >= 8);
#endif

int64_t now_ms() {
  if (!time_defined) { return 0; }
  return epoch_ms + (uint32_t)(millis() - epoch_ref);
}

void set_epoch_seconds(int64_t seconds) {
  epoch_ms = seconds * 1000LL;
  epoch_ref = millis();
  time_defined = true;
  if (TIME_T_IS_64) {
    struct timeval tv;
    tv.tv_sec = (time_t)seconds;
    tv.tv_usec = 0;
    settimeofday(&tv, nullptr);
  }
}

Servo myservo;
WiFiClientSecure *connexion = new WiFiClientSecure;
HTTPClient https;
JSONVar coreJobs;
File rawFile;
int rebooting = 0;

// ---- Bluetooth (Nordic UART Service) --------------------------------------
// The board advertises the same NUS the watch and deck use, so the house's BLE
// bridge can meet it even when it has no WiFi (a crash, a fresh board, or the
// provisioning AP). Incoming writes are delimited per notification; outbound
// messages are framed "<i>/<n>:" exactly like the watch, so the manager's
// reassembler reads them unchanged. The stack runs on the CYW43 async context,
// so there is no run loop to service here.
struct jawn_time;
String led_toggle(int pin, String state);
String relay_toggle(int pin, String state);
String servo_toggle(int pin, String state);
void config_writer();
void config_init();
void wifi_start();
void call_the_president();

static const uint8_t ble_nus_service[16] = { 0x6E,0x40,0x00,0x01,0xB5,0xA3,0xF3,0x93,0xE0,0xA9,0xE5,0x0E,0x24,0xDC,0xCA,0x9E };
static const uint8_t ble_nus_rx[16]      = { 0x6E,0x40,0x00,0x02,0xB5,0xA3,0xF3,0x93,0xE0,0xA9,0xE5,0x0E,0x24,0xDC,0xCA,0x9E };
static const uint8_t ble_nus_tx[16]      = { 0x6E,0x40,0x00,0x03,0xB5,0xA3,0xF3,0x93,0xE0,0xA9,0xE5,0x0E,0x24,0xDC,0xCA,0x9E };
static const uint8_t ble_adv[] = {
  0x02, 0x01, 0x06,
  0x11, 0x07, 0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0,
                0x93, 0xf3, 0xa3, 0xb5, 0x01, 0x00, 0x40, 0x6e,
  0x09, 0x09, 'J','a','w','n','P','i','c','o'
};
static_assert(sizeof(ble_adv) <= 31, "BLE advertising data is limited to 31 bytes");

static hci_con_handle_t ble_con_handle = HCI_CON_HANDLE_INVALID;
static bool ble_notify_enabled = false;
static bool ble_up = false;
static bool ble_started = false;
static unsigned long ble_connected_at = 0;
static bool ble_state_requested = false;
static LocklessQueue<uint8_t> ble_rx_queue(16384);
static LocklessQueue<uint8_t> ble_tx_queue(8192);
static btstack_context_callback_registration_t ble_send_request;
static btstack_packet_callback_registration_t ble_hci_reg;
static volatile bool ble_send_pending = false;
static uint8_t ble_tx_chunk[512];
static String ble_rx_frame;
static std::map<int, String> ble_rx_parts;
static int ble_rx_total = 0;
static unsigned long ble_rx_at = 0;
static String usb_config_line;
static bool usb_reboot_pending = false;
static unsigned long usb_reboot_at = 0;
static bool president_loaded = false;

static String jstr(JSONVar v) {
  if (JSON.typeof(v) == "undefined" || JSON.typeof(v) == "null") { return String(""); }
  return String((const char *)v);
}

static int64_t jint(JSONVar v) {
  if (JSON.typeof(v) == "undefined" || JSON.typeof(v) == "null") { return 0; }
  return (int64_t)(double)v;
}

static bool pin_ok(int pin) { return pin >= 0 && pin <= 29; }

static void ble_request_send();

static void ble_can_send(void *ctx) {
  (void)ctx;
  ble_send_pending = false;
  if (ble_con_handle == HCI_CON_HANDLE_INVALID || !ble_notify_enabled) { return; }
  uint16_t mtu = att_server_get_mtu(ble_con_handle);
  size_t max = (mtu > 3) ? (size_t)(mtu - 3) : 20;
  if (max > sizeof(ble_tx_chunk)) { max = sizeof(ble_tx_chunk); }
  size_t n = 0;
  while (n < max) {
    uint8_t b;
    if (!ble_tx_queue.read(&b)) { break; }
    ble_tx_chunk[n++] = b;
  }
  if (n) { nordic_spp_service_server_send(ble_con_handle, ble_tx_chunk, (uint16_t)n); }
  if (!ble_tx_queue.empty()) { ble_request_send(); }
}

static void ble_request_send() {
  if (ble_con_handle == HCI_CON_HANDLE_INVALID || !ble_notify_enabled || ble_tx_queue.empty() || ble_send_pending) { return; }
  ble_send_pending = true;
  ble_send_request.callback = &ble_can_send;
  ble_send_request.context = nullptr;
  nordic_spp_service_server_request_can_send_now(&ble_send_request, ble_con_handle);
}

static void ble_send_json(const String &json) {
  if (!ble_up || !ble_notify_enabled || ble_con_handle == HCI_CON_HANDLE_INVALID) { return; }
  uint16_t mtu = att_server_get_mtu(ble_con_handle);
  size_t max_payload = (mtu > 3) ? (size_t)(mtu - 3) : 20;
  size_t prefix = 12;  // room for "<i>/<n>:", even at a large part count
  size_t body_max = (max_payload > prefix + 1) ? (max_payload - prefix) : 8;
  size_t total = json.length();
  size_t parts = (total + body_max - 1) / body_max;
  if (parts == 0) { parts = 1; }
  if (parts > 999) { return; }
  for (size_t i = 0; i < parts; i++) {
    String head = String((unsigned long)i) + "/" + String((unsigned long)parts) + ":";
    size_t off = i * body_max;
    size_t len = (total > off) ? (total - off) : 0;
    if (len > body_max) { len = body_max; }
    String part = head + json.substring(off, off + len);
    for (size_t j = 0; j < part.length(); j++) {
      if (!ble_tx_queue.write((uint8_t)part[j])) { break; }
    }
  }
  BluetoothLock lock;
  ble_request_send();
}

static void ble_apply_now_me(JSONVar data) {
  String name = jstr(data["name"]);
  if (name != "") { config["name"] = name; }
  String hb = jstr(data["homebase"]);
  if (hb != "") { homebaseIP = hb; config["homebaseIP"] = hb; }
  String ip = jstr(data["ip"]);
  if (ip != "") { homebase = ip; config["homebase"] = ip; }
  String auth = jstr(data["authorization"]);
  if (auth != "") { authorization = auth; config["authorization"] = auth; }
  int64_t ts = jint(data["timestamp"]);
  int64_t off = jint(data["offset"]);
  if (ts > 0) {
    offset = off;
    config["timestamp"] = String((double)ts, 0);
    config["offset"] = String((double)off, 0);
    set_epoch_seconds(ts + off);
  }
  config_writer();
  lcd.clear();
  lcd.print(config["name"]);
}

static void ble_apply_app_state(String app, String state) {
  if (app == "") { return; }
  JSONVar keys = config["outputs"].keys();
  for (int i = 0; i < keys.length(); i++) {
    JSONVar o = config["outputs"][keys[i]];
    if (jstr(o["app"]) != app) { continue; }
    String comp = jstr(o["component"]);
    int pin = (int)jint(o["pin"]);
    String phys = state;
    if (jstr(o["inverted"]) == "1") { phys = (phys == "on") ? "off" : "on"; }
    if (comp == "relay") { relay_toggle(pin, phys); }
    else if (comp == "led") { led_toggle(pin, phys); }
  }
}

static void ble_apply_board_config(JSONVar ctp) {
  if (JSON.typeof(ctp) != "object") { return; }
  JSONVar keys = ctp.keys();
  Serial.println("[cfg] applying " + String(keys.length()) + " keys");
  config["button"] = undefined;
  config["pot"] = undefined;
  config["led"] = undefined;
  config["servo"] = undefined;
  config["relay"] = undefined;
  config["switch"] = undefined;
  config["outputs"] = undefined;
  config["internal_jobs"] = undefined;
  for (int i = 0; i < keys.length(); i++) {
    String name = String(keys[i]);
    if (name == "__specs" || name == "__shutup") { continue; }
    JSONVar e = ctp[keys[i]];
    String component = jstr(e["component"]);
    String numero = jstr(e["numero"]);
    if (numero == "") { numero = String((long)jint(e["numero"])); }
    int pin = numero.toInt();
    if (!pin_ok(pin)) { continue; }
    String inverted = jstr(e["inverted"]);
    String app = jstr(e["app"]);
    if (component == "button") {
      config["button"][numero]["lastPress"] = String(millis());
      config["button"][numero]["toggle"] = String((long)jint(e["toggle"]));
      config["button"][numero]["name"] = name;
      pinMode(pin, INPUT);
    }
    else if (component == "pot") {
      config["pot"][numero]["lastMove"] = String(millis());
      config["pot"][numero]["lastSend"] = String(millis());
      config["pot"][numero]["name"] = name;
    }
    else if (component == "switch") {
      config["switch"][numero]["lastChange"] = String(millis());
      config["switch"][numero]["lastSend"] = String(millis());
      config["switch"][numero]["name"] = name;
      pinMode(pin, INPUT);
    }
    else if (component == "relay" || component == "led" || component == "servo") {
      String state = ((long)jint(e["toggle"]) == 1) ? "on" : "off";
      if (component == "servo") { state = String((long)jint(e["toggle"])); }
      if (inverted == "1" && component != "servo") { state = (state == "on") ? "off" : "on"; }
      if (component == "relay") { config["relay"][numero] = state; }
      else if (component == "led") { config["led"][numero] = state; }
      else { config["servo"][numero] = state; }
      JSONVar o;
      o["component"] = component;
      o["pin"] = pin;
      o["app"] = app;
      o["inverted"] = inverted;
      config["outputs"][component + numero] = o;
      if (component != "servo") { pinMode(pin, OUTPUT); }
    }
  }
  if (JSON.typeof(ctp["__specs"]["internal_jobs"]) != "undefined") {
    config["internal_jobs"] = JSON.stringify(ctp["__specs"]["internal_jobs"]);
  }
  String auth = jstr(ctp["__specs"]["authorization"]);
  if (auth != "") { authorization = auth; config["authorization"] = auth; }
  String hb = jstr(ctp["__specs"]["homebase"]);
  if (hb != "" && homebaseIP == "") { homebaseIP = hb; config["homebaseIP"] = hb; }
  String nm = jstr(ctp["__specs"]["name"]);
  if (nm != "") { config["name"] = nm; }
  config_writer();
  config_init();
  president_loaded = true;
  lcd.clear();
  lcd.print(config["name"]);
}

static void ble_apply_set(JSONVar data) {
  String comp = jstr(data["component"]);
  int pin = (int)jint(data["pin"]);
  String state = jstr(data["state"]);
  if (comp == "relay") { state = relay_toggle(pin, state); }
  else if (comp == "led") { state = led_toggle(pin, state); }
  else if (comp == "servo") { state = servo_toggle(pin, state); }
  JSONVar ack;
  ack["type"] = "state";
  ack["chip_id"] = String(rp2040.getChipID());
  ack["edt"] = "microcontroller";
  JSONVar d;
  d["component"] = comp;
  d["pin"] = String(pin);
  d["state"] = state;
  ack["data"] = d;
  ble_send_json(JSON.stringify(ack));
}

static void ble_apply_wifi(JSONVar data) {
  String s = jstr(data["ssid"]);
  String p = jstr(data["password"]);
  String as = jstr(data["ap_ssid"]);
  String ap = jstr(data["ap_password"]);
  if (as != "") { ap_ssid = as; config["ap_ssid"] = as; }
  if (ap != "") { ap_password = ap; config["ap_password"] = ap; }
  if (s != "" && p != "") {
    ssid = s; password = p;
    config["ssid"] = s; config["password"] = p;
  }
  config_writer();
  if (s != "") {
    WiFi.disconnect();
    delay(100);
    wifi_start();
  }
}

static void ble_handle_json(String json) {
  JSONVar msg = JSON.parse(json);
  if (JSON.typeof(msg) != "object") { return; }
  String type = jstr(msg["type"]);
  if (type == "now_me") { ble_apply_now_me(msg["data"]); }
  else if (type == "board_config") { ble_apply_board_config(msg["data"]); }
  else if (type == "room") { ble_apply_board_config(msg["data"]["payload"]); }
  else if (type == "toggles") {
    JSONVar d = msg["data"];
    JSONVar k = d.keys();
    for (int i = 0; i < k.length(); i++) { ble_apply_app_state(String(k[i]), jstr(d[k[i]])); }
  }
  else if (type == "toggle") {
    ble_apply_app_state(jstr(msg["data"]["app"]), jstr(msg["data"]["state"]));
  }
  else if (type == "set") { ble_apply_set(msg["data"]); }
  else if (type == "wifi") { ble_apply_wifi(msg["data"]); }
  else if (type == "button") {
    JSONVar d = msg["data"];
    String numero = jstr(d["numero"]);
    if (numero != "") {
      config["button"][numero]["toggle"] = String((long)jint(d["toggle"]));
      config_writer();
    }
  }
  // hello, voice_* and anything else the watch/deck uses is simply not ours.
}

static void ble_process_frame(String frame) {
  int slash = frame.indexOf('/');
  int colon = frame.indexOf(':');
  if (slash > 0 && colon > slash && slash < 6) {
    int idx = frame.substring(0, slash).toInt();
    int total = frame.substring(slash + 1, colon).toInt();
    if (total > 0 && total <= 512 && idx >= 0 && idx < total) {
      if (idx == 0 || ble_rx_total != total || (millis() - ble_rx_at) > 5000) {
        ble_rx_parts.clear();
        ble_rx_total = total;
      }
      ble_rx_parts[idx] = frame.substring(colon + 1);
      ble_rx_at = millis();
      if ((int)ble_rx_parts.size() == total) {
        String msg;
        for (int i = 0; i < total; i++) { msg += ble_rx_parts[i]; }
        ble_rx_parts.clear();
        ble_rx_total = 0;
        ble_handle_json(msg);
      }
      return;
    }
  }
  ble_handle_json(frame);
}

static void ble_loop() {
  uint8_t b;
  while (ble_rx_queue.read(&b)) {
    if (b == 0x1E) {
      if (ble_rx_frame.length()) {
        ble_process_frame(ble_rx_frame);
        ble_rx_frame = "";
      }
    }
    else if (ble_rx_frame.length() < 8192) {
      ble_rx_frame += (char)b;
    }
  }
  if (ble_up && ble_notify_enabled && !ble_state_requested && ble_connected_at && (millis() - ble_connected_at) > 3000) {
    ble_state_requested = true;
    String chip = String(rp2040.getChipID());
    JSONVar req;
    req["type"] = "state_request";
    req["chip_id"] = chip;
    req["edt"] = "microcontroller";
    // Omit an empty homebase: this JSONVar build serializes an empty String as
    // an empty token, which made the whole message unparseable at the manager.
    if (homebaseIP != "") { req["homebase"] = homebaseIP; }
    ble_send_json(JSON.stringify(req));
    JSONVar board;
    board["type"] = "room_request";
    board["chip_id"] = chip;
    board["edt"] = "microcontroller";
    board["room"] = 1;
    ble_send_json(JSON.stringify(board));
    Serial.println("[ble] state requested");
  }
}

static void usb_config_loop() {
  while (Serial.available()) {
    char c = (char)Serial.read();
    // Do not echo serial input: a JAWNCFG line carries WiFi credentials and the
    // device authorization, and the manager reads this port back. The boot log
    // is still printed by Serial.println as before.
    if (c == '\n') {
      String line = usb_config_line;
      usb_config_line = "";
      line.trim();
      if (line == "JAWNCFG?") {
        // A field diagnostic: what the board actually reads back from its own
        // config file, with the secrets redacted. It answers on USB, so a board
        // that is off the network can still be inspected.
        JSONVar out = config;
        out["password"] = "***";
        out["ap_password"] = "***";
        out["authorization"] = "***";
        if (out["__specs"]) { out["__specs"]["authorization"] = "***"; }
        Serial.println("JAWNCFG STATE " + JSON.stringify(out));
        File cf = LittleFS.open("config.txt", "r");
        String raw = cf.readString();
        cf.close();
        Serial.println("JAWNCFG RAW " + String(raw.length()) + " bytes");
        JSONVar rawj = JSON.parse(raw);
        JSONVar rk = rawj.keys();
        String types;
        for (int i = 0; i < rk.length(); i++) {
          String k = String(rk[i]);
          if (k == "password" || k == "ap_password" || k == "authorization") { types += k + ":redacted "; }
          else { types += k + ":" + JSON.typeof(rawj[rk[i]]) + " "; }
        }
        Serial.println("JAWNCFG TYPES " + types);
        Serial.println("JAWNCFG MORE ssid=" + ssid + " ap_ssid=" + ap_ssid + " wifi=" + wifiState + " homebaseIP=" + homebaseIP);
      }
      else if (line == "JAWNREBOOT") {
        Serial.println("JAWNCFG REBOOT");
        usb_reboot_pending = true;
        usb_reboot_at = millis() + 300;
      }
      else if (line.startsWith("JAWNCFG ")) {
        String json = line.substring(8);
        JSONVar incoming = JSON.parse(json);
        if (JSON.typeof(incoming) == "object") {
          config = incoming;
          // The file is the source of truth now: set the live identity from it.
          // The role is not written here; it comes back over BLE (board_config)
          // or from /watch once the network is up. This keeps the USB line small
          // enough that the CDC receive ring cannot truncate it.
          homebaseIP = jstr(config["homebaseIP"]);
          homebase = jstr(config["homebase"]);
          authorization = jstr(config["authorization"]);
          offset = jint(config["offset"]);
          int64_t ts = jint(config["timestamp"]);
          config_writer();
          config_init();
          if (ts > 0) { set_epoch_seconds(ts + offset); }
          Serial.println("JAWNCFG OK");
          usb_reboot_pending = true;
          usb_reboot_at = millis() + 700;
        }
        else {
          Serial.println("JAWNCFG ERR bad json");
        }
      }
    }
    else if (c != '\r') {
      if (usb_config_line.length() < 16384) { usb_config_line += c; }
    }
  }
  if (usb_reboot_pending && (long)(millis() - usb_reboot_at) >= 0) {
    rp2040.reboot();
  }
}

static void ble_nus_handler(uint8_t packet_type, uint16_t channel, uint8_t *packet, uint16_t size) {
  (void)channel;
  if (packet_type == RFCOMM_DATA_PACKET) {
    for (uint16_t i = 0; i < size; i++) { ble_rx_queue.write(packet[i]); }
    ble_rx_queue.write(0x1E);  // one notification = one framed part
    return;
  }
  if (packet_type != HCI_EVENT_PACKET) { return; }
  if (hci_event_packet_get_type(packet) != HCI_EVENT_GATTSERVICE_META) { return; }
  switch (hci_event_gattservice_meta_get_subevent_code(packet)) {
    case GATTSERVICE_SUBEVENT_SPP_SERVICE_CONNECTED:
      ble_con_handle = gattservice_subevent_spp_service_connected_get_con_handle(packet);
      ble_notify_enabled = true;
      ble_up = true;
      ble_connected_at = millis();
      ble_state_requested = false;
      ble_rx_queue.reset();
      ble_tx_queue.reset();
      ble_rx_parts.clear();
      ble_rx_total = 0;
      Serial.println("[ble] connected");
      break;
    case GATTSERVICE_SUBEVENT_SPP_SERVICE_DISCONNECTED:
      ble_notify_enabled = false;
      ble_up = false;
      ble_con_handle = HCI_CON_HANDLE_INVALID;
      ble_state_requested = false;
      ble_rx_queue.reset();
      ble_tx_queue.reset();
      ble_rx_parts.clear();
      ble_rx_total = 0;
      Serial.println("[ble] disconnected");
      break;
    default:
      break;
  }
}

static void ble_start() {
  if (ble_started) { return; }
  ble_started = true;
  BluetoothLock lock;
  l2cap_init();
  sm_init();
  att_db_util_init();
  att_db_util_add_service_uuid128(ble_nus_service);
  att_db_util_add_characteristic_uuid128(ble_nus_rx,
    ATT_PROPERTY_WRITE | ATT_PROPERTY_WRITE_WITHOUT_RESPONSE | ATT_PROPERTY_DYNAMIC,
    ATT_SECURITY_NONE, ATT_SECURITY_NONE, nullptr, 0);
  att_db_util_add_characteristic_uuid128(ble_nus_tx,
    ATT_PROPERTY_NOTIFY | ATT_PROPERTY_DYNAMIC,
    ATT_SECURITY_NONE, ATT_SECURITY_NONE, nullptr, 0);
  att_server_init(att_db_util_get_address(), nullptr, nullptr);
  nordic_spp_service_server_init(&ble_nus_handler);
  bd_addr_t null_addr = {0};
  gap_advertisements_set_params(0x30, 0x30, 0, 0, null_addr, 0x07, 0x00);
  gap_advertisements_set_data(sizeof(ble_adv), (uint8_t *)ble_adv);
  gap_advertisements_enable(1);
  hci_power_control(HCI_POWER_ON);
  Serial.println("[ble] advertising as JawnPico");
}

void setup1() {
  Serial.begin(115200);
  Serial.println("Core 1 started");
}

void setup() {
  Serial.begin(115200);
  delay(200);
  pinMode(led, OUTPUT);
  digitalWrite(led,HIGH);
  delay(200);
  LittleFS.begin();
  pinMode(0, OUTPUT);

  digitalWrite(0, HIGH);

  File f = LittleFS.open("config.txt", "r");
  String jconfig = f.readString();
  f.close();
  // Never print the file itself: it carries the WiFi password and the device
  // token. The length is enough to see whether a restore actually persisted.
  Serial.println("[cfg] boot read " + String(jconfig.length()) + " bytes");
  config = JSON.parse(jconfig);
  config_init();
  Serial.println();
  Serial.println();
  Serial.print("Connecting to ");
  Serial.println(ssid);

  wifi_start();
  ble_start();


  server.on("/", []() {
    String html = R"(
      <!DOCTYPE html>
      <html>
        <title>Pico 2W Initial Config</title>
        <body style="text-align:center;position:fixed;top: 50%;left: 50%; transform: translate(-50%, -50%);">
          <form action="/initial_config" id="form" method="POST">
            <h1>Pico 2W</h1>
            <h4>Wifi SSID</h4>
            <input name="wifi_ssid">
            <h4>Wifi Password</h4>
            <input name="wifi_password" type="password">
            <h4>AP SSID</h4>
            <input name="ap_ssid">
            <h4>AP Password</h4>
            <input name="ap_password" type="password">
            <br><br>
            <button type="submit" id="submit">Submit</button>
            <br><br>
            <div id="log"></div>
          </form>
        </body>
        <style>
          input { text-align:left; height: 28px; font-size: 20px; border-width: 1px; border: solid; border-radius: 5px; }	
          button { text-align:center; height: 34px; min-width: 30px; font-size: 20px; border-width: 1px; border: solid; border-radius: 5px; }
        </style>
        <script>
          const form = document.getElementById('form');
          const log = document.getElementById('log');
          function formSubmitted() {
            log.textContent = "Form Submitted! Restarting Networks";
          }
          form.addEventListener('submit', formSubmitted);
        </script>
      </html>
    )";
    server.send(200, "text/html", html);
  });
  server.on("/initial_config", []() {
    String t_ssid = server.arg("wifi_ssid");
    String t_password = server.arg("wifi_password");
    String t_ap_ssid = server.arg("ap_ssid");
    String t_ap_password = server.arg("ap_password");
    if (t_ap_password != "" && t_ap_ssid != "") {
      // owned copies, persisted: the old c_str() assignments pointed at locals
      // that died with the request and were never written to config
      ap_password = t_ap_password;
      ap_ssid = t_ap_ssid;
      config["ap_password"] = ap_password;
      config["ap_ssid"] = ap_ssid;
      config_writer();
    }
    if (t_ssid != "" && t_password != "") {
      Serial.println("Saving SSID and Password");

      ssid = t_ssid;
      password = t_password;
      Serial.println(ssid);
      Serial.println(password);      
      config["ssid"] = ssid;
      config["password"] = password;
      config_writer();
      WiFi.disconnect();
      delay(400);
      wifi_start();
    }
    
    server.send(200, "text/html", "<h1>Success!</h1><a href='/'>Back</a>");
    

  });


  server.on("/device_query", []() {
    config["chip_id"] = rp2040.getChipID();
    config["uptime"] = millis();
    config["purpose"] = "microcontroller";
    config["model"] = "Raspberry Pi Pico 2W";
    config["pins"] = "28";
    JSONVar jonfig = config;
    jonfig["ssid"] = undefined;
    jonfig["password"] = undefined;
    jonfig["ap_password"] = undefined;
    jonfig["ap_ssid"] = undefined;
    String gs = JSON.stringify(jonfig);
    server.send(200, "text/plain", gs);
    config_writer();
  });

  server.on("/jobs", []() {
    String auth = server.arg("authorization");
   // if (auth == authorization) {
      String jobs = JSON.stringify(config["jobs"]);
      Serial.println(jobs);
      server.send(200, "text/plain", jobs);
   // }

  });

  server.on("/now_me", []() {
    homebaseChecked();
    homebaseIP = server.arg("homebase");
    homebase = server.arg("ip");
    config["authorization"] = server.arg("authorization");
    authorization = server.arg("authorization");
    config["name"] = server.arg("name");
    Serial.println(server.arg("name"));
    browser_tab_id = server.arg("browser_tab_id");
    Serial.println(server.arg("authorization"));
    Serial.println(config["name"]);
    // Read the epoch wide. String::toInt() is a 32-bit long, which wraps in
    // 2038; parsing as int64_t keeps the value honest even though time_t in
    // this core is still 32-bit.
    int64_t timestamp = strtoll(server.arg("timestamp").c_str(), nullptr, 10);
    config["timestamp"] = server.arg("timestamp");
    config["offset"] = server.arg("offset");
    offset = strtoll(server.arg("offset").c_str(), nullptr, 10);
    config["homebase"] = server.arg("ip");
    config["homebaseIP"] = server.arg("homebase");
    Serial.println("Homebase: " + homebase);
    Serial.println("homebase ip:" + homebaseIP);
    set_epoch_seconds(timestamp + offset);
    // Serial.println("Called President at " + homebaseIP);
    server.send(200, "text/plain", "homebase ip is now " + homebaseIP);
    config_writer();
    call_the_president();
  });
  server.on("/delete_job", []() {
    homebaseChecked();
    String appt_uuid = server.arg("appt_uuid");
    Serial.println("Querying " + appt_uuid);
    JSONVar jobKeys = config["jobs"].keys();
    int jlLength = jobKeys.length();
    for (int i = 0; i < jlLength; i++) {
      
      String app_uuid = config["jobs"][jobKeys[i]]["appt_uuid"];
      Serial.println("Testing " + app_uuid);
      if (appt_uuid == app_uuid) {
        Serial.println("deleting " + appt_uuid);
        String uuid = config["jobs"][jobKeys[i]]["uuid"];    
        config["jobs"][uuid] = undefined;
        jlLength--;
        Serial.println("Deleted " + uuid);
      }
    }
    config_writer();
    server.send(200, "text/plain", "ok");
  });
  server.on("/led", []() {
    homebaseChecked();
    String component = server.arg("component");
    String spin = server.arg("pin");
    int pin = server.arg("pin").toInt();
    String state = server.arg("state");
    String timestamp = server.arg("timestamp");
    String uuid = server.arg("uuid");
    String when = server.arg("when");
    String appt_uuid = server.arg("appt_uuid");
    if (when == "now") {
      state = led_toggle(pin,state);
    }
    else {
      push_job(component,pin,state,timestamp,uuid, appt_uuid);
    }
    JSONVar status;
    status["pin"] = pin;
    status["state"] = state;

    String jstatus = JSON.stringify(status);
    server.send(200, "text/plain", jstatus);
    config_writer();
    
  
  });
  server.on("/relay", []() {
    homebaseChecked();
    String component = server.arg("component");
    String spin = server.arg("pin");
    int pin = server.arg("pin").toInt();
    String state = server.arg("state");
    String timestamp = server.arg("timestamp");
    String when = server.arg("when");
    String uuid = server.arg("uuid");
    String appt_uuid = server.arg("appt_uuid");
    if (when == "now") {
      state = relay_toggle(pin,state);
    }
    else {
      push_job(component,pin,state,timestamp,uuid, appt_uuid);
    }
    JSONVar status;
    status["pin"] = pin;
    status["state"] = state;

    String jstatus = JSON.stringify(status);
    server.send(200, "text/plain", jstatus);
  });
  server.on("/servo", []() {
    homebaseChecked();
    String component = server.arg("component");
    String spin = server.arg("pin");
    int pin = server.arg("pin").toInt();
    String state = String(server.arg("state"));
    String timestamp = server.arg("timestamp");
    String when = server.arg("when");
    String uuid = server.arg("uuid");
    String appt_uuid = server.arg("appt_uuid");
    Serial.println(component + " " + spin + " " + state);
    if (when == "now") {
      state = servo_toggle(pin,state);
    }
    else {
      push_job(component,pin,state,timestamp,uuid, appt_uuid);
    }
    JSONVar status;
    status["pin"] = pin;
    status["state"] = state;

    String jstatus = JSON.stringify(status);
    server.send(200, "text/plain", jstatus);    
  });
  server.on("/wifi_update", []() {
    homebaseChecked();
    String req = "https://" + homebaseIP + "/manager/teletype/wifi_update?";
    String wifi_update = https_request(req);
    
    JSONVar info = JSON.parse(wifi_update);
    String next_ssid = String((const char *)info["ssid"]);
    String next_password = String((const char *)info["password"]);
    if (ssid != next_ssid || password != next_password) {
      ssid = next_ssid;
      password = next_password;
      config["ssid"] = ssid;
      config["password"] = password;
      multi.clearAPList();
      server.stop();
      server.close();
      delay(400);
      
      multi.addAP(ssid.c_str(), password.c_str());
      if (multi.run() != WL_CONNECTED) {
        Serial.println("Unable to connect to network, rebooting in 10 seconds...");
        delay(10000);
        rp2040.reboot();
      }
      server.begin();

      Serial.println("WiFi connected");
      Serial.println("IP address: ");
      Serial.println(WiFi.localIP());
    }
  });
  
  server.on(UriRegex("/upload/(.*)"), HTTP_POST, handleCreate, handleCreateProcess);
  server.begin();
  Serial.println("Server began");
  // for i2c variants, this must be called first.
  lcd.init();                      // initialize the lcd 
  lcd.backlight();
  lcd.setBacklight(1);
  // Print a message to the LCD.
  lcd.print(config["name"]);

}

// What this device is, advertised over mDNS: purpose, model and abilities.
#define JAWNOS_CAPS "lcd,led,relay,servo,button,switch,pot,pins,wifi"

static bool jawnos_mdns_up = false;
static void jawnos_mdns_start() {
  if (jawnos_mdns_up || WiFi.status() != WL_CONNECTED) { return; }
  String chip_id = String(rp2040.getChipID());
  String host = "jawn-" + chip_id;
  String dev_name = (const char *)config["name"];
  if (dev_name == "null" || dev_name == "") { dev_name = "Pico"; }
  if (!MDNS.begin(host.c_str())) {
    Serial.println("[mdns] begin failed");
    return;
  }
  hMDNSService svc = MDNS.addService("jawnos", "tcp", 3000);
  MDNS.addServiceTxt(svc, "chip_id", chip_id.c_str());
  MDNS.addServiceTxt(svc, "name", dev_name.c_str());
  MDNS.addServiceTxt(svc, "purpose", "microcontroller");
  MDNS.addServiceTxt(svc, "model", "Raspberry Pi Pico 2W");
  MDNS.addServiceTxt(svc, "caps", JAWNOS_CAPS);
  MDNS.addServiceTxt(svc, "port", "3000");
  jawnos_mdns_up = true;
  Serial.println("[mdns] jawnos._tcp up as " + host);
}

void wifi_start() {
  Serial.println("Attempting connection");
  WiFi.disconnect();
  WiFi.softAPdisconnect(true);
  delay(100);  
  WiFi.mode(WIFI_STA);
  if (config["ssid"] != "" && config["password"] != "") {
    Serial.println("Got the goods");
    ssid = String((const char *)config["ssid"]);
    password = String((const char *)config["password"]);
    Serial.println(ssid);
    Serial.println(password);
    multi.addAP(ssid.c_str(), password.c_str());
  }
  if (multi.run() == WL_CONNECTED && config["ssid"] != "" && config["password"] != "") {
    server.begin();
    jawnos_mdns_start();
    Serial.println("WiFi connected");
    Serial.println("IP address: ");
    Serial.println(WiFi.localIP());    
    Serial.println(ssid);
    Serial.println("ok");
    wifiState = "connected";
    Serial.println(wifiState);
    // A board that rebooted after a crash (or a USB restore) should resume its
    // role without waiting for someone to press Now Me: fetch the room once the
    // network is up. The flag is cleared again on the next reconnect.
    president_loaded = false;
    // https_request refuses to run while homebaseOnline is 0, and it starts at
    // 0 on boot. Let the first role fetch through; a real failure sets it back
    // to 0, and homebasePing re-arms it for the next try.
    homebaseOnline = 1;
    coreJobs["connect"]["type"] = "led";
    coreJobs["connect"]["interval"] = "100";
    coreJobs["connect"]["duration"] = "500";
    if (authorization && homebaseIP) {
      String req = "https://" + homebaseIP + "/watch/time?";
      String timeRequest = https_request(req);
      String jobTime = String(millis());
      coreJobs[jobTime]["type"] = "https";
      coreJobs[jobTime]["url"] = req;
      coreJobs[jobTime]["response"] = "time";
    }
  }
  else {
    wifiState = "disconnected";
    Serial.println("no wifi connected");
    WiFi.mode(WIFI_AP);
    delay(100);
    if (WiFi.softAP(ap_ssid.c_str(), ap_password.c_str())) {

      Serial.print("Access Point successfully started. SSID: ");
      Serial.println(ap_ssid);
      Serial.print("AP IP Address: ");
      Serial.println(WiFi.softAPIP());

    } else {
      Serial.println("Failed to initialize Access Point.");
    }    
  }
}

void handleCreate() {
  server.send(200, "text/plain", "");
}
unsigned long lastOTAMillis = millis();
unsigned long lastOTASendMillis = millis();
void ledFlasher(int interval, int duration) {
  pinMode(led, OUTPUT);
  unsigned long end_time = millis() + duration;
  while ((long)(millis() - end_time) < 0) {
    if (digitalRead(led) == 1) {
      digitalWrite(led, LOW);
    }
    else {
      digitalWrite(led, HIGH);
    }
    delay(interval);
  }
  digitalWrite(led, HIGH);
}


void handleCreateProcess() {
  String rauth = server.arg("authorization");
  if (rauth == authorization) {
    pinMode(led, OUTPUT);
    int brightness = 255;
    String path = "/" + server.pathArg(0);
    HTTPRaw& raw = server.raw();
    
    if (raw.status == RAW_START) {
      if (LittleFS.exists((char *)path.c_str())) {
        LittleFS.remove((char *)path.c_str());
      }
      rawFile = LittleFS.open(path.c_str(), "w");
      
    } else if (raw.status == RAW_WRITE) {
      if (rawFile) {
        rawFile.write(raw.buf, raw.currentSize);
      }
      if ((unsigned long)(millis() - lastOTAMillis) > 20) {
        lastOTAMillis = millis();
        if (digitalRead(led) == 1) {
          digitalWrite(led, LOW);
        }
        else {
          digitalWrite(led, HIGH);
        }
      }
      if ((unsigned long)(millis() - lastOTASendMillis) > 3000) {
        lastOTASendMillis = millis();
        String current_size = String(raw.totalSize);
        String jobTime = String(millis());
        coreJobs[jobTime]["type"] = "https";
        coreJobs[jobTime]["url"] = "https://" + homebaseIP +
          "/watch/ota_status?current_size=" + current_size +
          "&status=uploading";
        
      }
    } else if (raw.status == RAW_END) {
      if (rawFile) {
        rawFile.close();
      }
      String current_size = String(raw.totalSize);

      String jobTime = String(millis());
      coreJobs[jobTime]["type"] = "https";
      coreJobs[jobTime]["url"] = "https://" + homebaseIP +
        "/watch/ota_status?current_size=" + current_size +
        "&status=updating";

      picoOTA.begin();
      picoOTA.addFile(path.c_str());
      picoOTA.commit();
      LittleFS.end();
      LittleFS.remove((char *)path.c_str());
      
      String https = https_request(
        "https://" + homebaseIP +
        "/watch/ota_status?current_size=" + current_size +
        "&status=complete"
      );
      delay(1000);
      rebooting = 1;
    }
  }
}
void loop() {
  server.handleClient();
  read_time();
  input_scanner();
  // USB serial: echo (as before) and accept a "JAWNCFG <json>" line from the
  // manager, which writes the stored WiFi and role and then reboots us.
  usb_config_loop();
  ble_loop();

  if (BOOTSEL) {
    File f = LittleFS.open("config.txt", "w");
    f.print("");
    Serial.println(rp2040.getChipID());
    rp2040.reboot();
  }

  delay(10);
}

void loop1() {
  if ((unsigned long)(millis() - lastPing) > 60000) {
    homebasePing();
  }
  if ((unsigned long)(millis() - lastWifiCheck) > 10000) {
    lastWifiCheck = millis();
    wifi_supervise();
  }
  // the crystal drifts; re-anchor the epoch from the (NTP-synced) house every
  // six hours, so a long uptime never accumulates the old 9-minute offset
  if ((unsigned long)(millis() - lastTimeSync) > 21600000UL && wifiState == "connected" && homebaseIP != "") {
    request_time();
  }
  if (rebooting == 1) {
    rp2040.reboot();
  }
  // Once the network is up, pull the role (components and internal_jobs) from
  // the house. Retry every ten seconds until it lands; a single early attempt
  // used to fail before the first ping and leave the board with no relay map.
  if (!president_loaded && wifiState == "connected" && homebaseIP != "" && (millis() - lastPresidentTry > 10000)) {
    lastPresidentTry = millis();
    call_the_president();
  }
  handle_jobs();
//  delay(10);
}

void homebasePing() {
  if (wifiState == "connected") {
    homebaseOnline = 1;  // this IS the probe: allow it to run after a failure
    String https = https_request(
      "https://" + homebaseIP +
      "/watch/alive?millis=" + millis()
    );
    JSONVar alive;
    if (https != "failure") {
      alive = JSON.parse(https);
    }
    Serial.println(https);
    if (String(alive["status"]) == "alive") {
      homebaseChecked();
    }
    else {
      Serial.println("no ping");
      homebaseOnline = 0;
    }
  }
  else {
    // wifi_supervise() owns reconnecting and the AP, so there is one owner.
    wifiState = "disconnected";
  }
  lastPing = millis();
}

void homebaseChecked() {
  homebaseOnline = millis();
  lastPing = millis();
}

void request_time() {
  if (homebaseIP == "") { return; }
  String req = "https://" + homebaseIP + "/watch/time?";
  String jobTime = String(millis());
  coreJobs[jobTime]["type"] = "https";
  coreJobs[jobTime]["url"] = req;
  coreJobs[jobTime]["response"] = "time";
  lastTimeSync = millis();
}

// A successful join: drop the provisioning AP, go back to station-only, and
// bring mDNS and the clock up on the network we just rejoined.
void wifi_join_done() {
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
  wifiState = "connected";
  wifiDownTicks = 0;
  president_loaded = false;
  jawnos_mdns_up = false;
  jawnos_mdns_start();
  server.begin();
  request_time();
  Serial.println("[wifi] reconnected; AP down");
  homebasePing();
}

// The saved SSID is not a one-shot. When the router goes away, keep an AP up so
// the device is still reachable for provisioning, and keep trying the saved
// network; the moment it comes back, the AP goes down again.
void wifi_supervise() {
  bool has_creds = config["ssid"] != "" && config["password"] != "";

  if (WiFi.status() == WL_CONNECTED) {
    wifiDownTicks = 0;
    if (wifiState != "connected") { wifi_join_done(); }
    return;
  }

  if (wifiState == "connected") {
    wifiState = "disconnected";
    jawnos_mdns_up = false;
  }

  wifiDownTicks++;
  if (!has_creds) { return; }

  if (wifiDownTicks == 3) {
    WiFi.mode(WIFI_AP_STA);
    if (WiFi.softAPIP() == IPAddress(0, 0, 0, 0)) {
      WiFi.softAP(ap_ssid.c_str(), ap_password.c_str());
      Serial.println("[wifi] router away; AP up while retrying");
    }
  }
  if (wifiDownTicks >= 3 && (wifiDownTicks % 3 == 0)) {
    if (multi.run() == WL_CONNECTED) { wifi_join_done(); }
  }
}

void input_scanner() {
  if (input_working == 1) {
    return;
  }
  input_working = 1;
  JSONVar buttonKeys = config["button"].keys();
  for (int i = 0; i < buttonKeys.length(); i++) {
    String spin = buttonKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    int buttonState = digitalRead(pin);
    String lastPress = config["button"][buttonKeys[i]]["lastPress"];
    String pressed = config["button"][buttonKeys[i]]["pressed"];

    uint32_t lp = (uint32_t)strtoul(lastPress.c_str(), nullptr, 10);
    if (buttonState == 0 && pressed == "yes") {
      config["button"][buttonKeys[i]]["pressed"] = "no";
      config_writer();
    }
    if (buttonState == 1 && ((uint32_t)(millis() - lp) > 10) && pressed != "yes") {
      config["button"][buttonKeys[i]]["lastPress"] = String(millis());
      config["button"][buttonKeys[i]]["pressed"] = "yes";
      String toggle = buttonKeys[buttonKeys[i]]["toggle"];

      String name = String(config["button"][buttonKeys[i]]["name"]);
      String jij = config["internal_jobs"];
      Serial.println(jij);
      Serial.println(config["button"][buttonKeys[i]]["name"]);
      JSONVar ij = JSON.parse(jij);
      if (ij[name].length() > 0) {
        Serial.println("I have job for this");
        for (int j = 0; j < ij[name].length(); j++) {
          int p = String(ij[name][j]["numero"]).toInt();
          int inv = String(ij[name][j]["inverted"]).toInt();
          String comp = String(ij[name][j]["component"]);
          String tog = String(config[comp][String(ij[name][j]["numero"])]);
          Serial.println(comp + " " + String(ij[name][j]["numero"]) + " " + tog);
          String jState = "off";
          toggle = "0";
          if (inv == 1) {
            if (tog == "off") {
              jState = "on";
              toggle = "0";
            }
            else {
              toggle = "1";
            }
          }
          else {
            if (tog != "on") {
              jState = "on";
              toggle = "1";
            }
            else {
              toggle = "0";
            }
          }
          Serial.println(comp + " " + String(ij[name][j]["numero"]) + " " + jState + " after");
          if (comp == "relay") {
            relay_toggle(p, jState);
          }
          if (comp == "led") {
            led_toggle(p, jState);
          }
        }

      }
      config_writer();

      // Prefer the bridge when it is up: a board off its access point still
      // reports its taps, and the machine holding the link applies them. Fall
      // back to the HTTPS job (the LAN path) when there is no bridge.
      if (ble_up && ble_notify_enabled) {
        JSONVar bm;
        bm["type"] = "button";
        bm["chip_id"] = String(rp2040.getChipID());
        bm["edt"] = "microcontroller";
        JSONVar bp;
        bp["room"] = "1";
        bp["button"] = String(spin.toInt());
        bp["toggle"] = String(toggle.toInt());
        bp["timestamp"] = String((double)(now_ms() / 1000), 0);
        bm["payload"] = bp;
        ble_send_json(JSON.stringify(bm));
      }
      else {
        String jobTime = String(millis());
        coreJobs[jobTime]["type"] = "https";
        coreJobs[jobTime]["url"] = "https://" + homebaseIP +
          "/watch/button?room=1&button=" + spin + "&toggle=" + toggle;
        coreJobs[jobTime]["response"] = "button";
      }
      config_writer();
    }
  }
  JSONVar switchKeys = config["switch"].keys();
  for (int i = 0; i < switchKeys.length(); i++) {
    String spin = switchKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    int switchState = digitalRead(pin);
    String state;
    if (switchState == 1) {
      state = "on";
    }
    else {
      state = "off";
    }
    String lastChange = config["switch"][switchKeys[i]]["lastChange"];
    String lastState = String(config["switch"][switchKeys[i]]["state"]);
    if (state != lastState) {
      config["switch"][switchKeys[i]]["state"] = state;
      config["switch"][switchKeys[i]]["lastChange"] = String(millis());

      String name = String(config["switch"][switchKeys[i]]["name"]);
      String jij = config["internal_jobs"];
      Serial.println(jij);
      Serial.println(config["switch"][switchKeys[i]]["name"]);
      JSONVar ij = JSON.parse(jij);
      if (ij[name].length() > 0) {
        Serial.println("I have job for this");
        for (int j = 0; j < ij[name].length(); j++) {
          int p = String(ij[name][j]["numero"]).toInt();
          int inv = String(ij[name][j]["inverted"]).toInt();
          String jState = state;
          if (inv == 1) {
            if (state == "on") {
              jState = "off";
            }
            else {
              jState = "on";
            }
          }
          if (String(ij[name][j]["component"]) == "relay") {
            relay_toggle(p, jState);
          }
          if (String(ij[name][j]["component"]) == "led") {
            led_toggle(p, jState);
          }
        }
      }

      if (ble_up && ble_notify_enabled) {
        JSONVar sm;
        sm["type"] = "switch";
        sm["chip_id"] = String(rp2040.getChipID());
        sm["edt"] = "microcontroller";
        JSONVar sd;
        sd["room"] = "1";
        sd["switch"] = String(spin.toInt());
        sd["state"] = state;
        sd["timestamp"] = String((double)(now_ms() / 1000), 0);
        sm["data"] = sd;
        ble_send_json(JSON.stringify(sm));
      }
      else {
        String jobTime = String(millis());
        coreJobs[jobTime]["type"] = "https";
        coreJobs[jobTime]["url"] = "https://" + homebaseIP +
          "/watch/switch?room=1&switch=" + spin + "&state=" + state;
        coreJobs[jobTime]["response"] = "switch";
      }
      config["switch"][switchKeys[i]]["lastSend"] = String(millis());
    //  config["button"][buttonKeys[i]]["state"] = returner["toggle"];
      config_writer();
    }
  }
  JSONVar potKeys = config["pot"].keys();
  for (int i = 0; i < potKeys.length(); i++) {
    String spin = potKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    int potState = analogRead(pin);
   // Serial.println(potState);
    String bs = String(potState);
    int lbs = String(config["pot"][spin]["lastValue"]).toInt();
    String changed = String(config["pot"][spin]["changed"]);
    String ls = (const char *)config["pot"][spin]["lastSend"];
    uint32_t lastSend = (uint32_t)strtoul(ls.c_str(), nullptr, 10);
    if (potState != lbs || changed == "yes") {
      int min = lbs - 12;
      int max = lbs + 12;
      String lm = (const char *)config["pot"][spin]["lastMove"];
      uint32_t lastMove = (uint32_t)strtoul(lm.c_str(), nullptr, 10);
      lastMove = lastMove + 300;

      if (potState < min || potState > max) {
        config["pot"][spin]["lastMove"] = String(millis());
        lastMove = millis();
        lastMove = lastMove;// + 300;
        Serial.println(bs);

        String name = String(config["pot"][potKeys[i]]["name"]);
        String jij = config["internal_jobs"];
        Serial.println(config["pot"][potKeys[i]]["name"]);
        JSONVar ij = JSON.parse(jij);
        if (ij[name].length() > 0) {
          config["pot"][spin]["lastValue"] = bs;          

          for (int j = 0; j < ij[name].length(); j++) {
            int p = String(ij[name][j]["numero"]).toInt();
            int inv = String(ij[name][j]["inverted"]).toInt();
            String tp = String(ij[name][j]["threshold_percentage"]);
            double thresh = tp.toDouble();
            
            
            Serial.println(potState);

            thresh = ( thresh / 100 ) * 1024;
            Serial.println(thresh);
            String jState = "off";
            if (inv == 1) {
              if (potState <= thresh) {
                jState = "on";
              }
            }
            else {
              if (potState >= thresh) {
                jState = "on";
              }
            }
            if (String(ij[name][j]["component"]) == "relay") {
              relay_toggle(p, jState);
            }
            if (String(ij[name][j]["component"]) == "led") {
              led_toggle(p, jState);
            }
          }
          
          config["pot"][spin]["changed"] = "yes";

          config_writer();
        }

      }


      // wrap-safe: a negative delta means the stored millis is "ahead" (the
      // counter wrapped), so re-base it; otherwise require 500 ms since the last
      // send and the 300 ms move debounce to have passed.
      if ((int32_t)(millis() - lastSend) < 0) {
        lastSend = millis();
        config["pot"][spin]["lastSend"] = String(lastSend);
      }
      changed = String(config["pot"][spin]["changed"]);
      bool send_due = (int32_t)(millis() - lastSend) >= 500;
      bool move_due = (int32_t)(millis() - lastMove) >= 0;
      if (send_due && move_due && changed == "yes") {
        config["pot"][spin]["lastSend"] = String(millis());
          
        potState = analogRead(pin);
          // Serial.println(potState);
        bs = String(potState);
        config["pot"][spin]["lastValue"] = bs;
        config["pot"][spin]["changed"] = "no";
        
        config_writer();
        if (ble_up && ble_notify_enabled) {
          JSONVar mm;
          mm["type"] = "measure";
          mm["chip_id"] = String(rp2040.getChipID());
          mm["edt"] = "microcontroller";
          JSONVar md;
          md["room"] = "1";
          md["component"] = "pot";
          md["button"] = String(spin.toInt());
          md["measure"] = bs;
          md["min"] = "0";
          md["max"] = "1024";
          md["timestamp"] = String((double)(now_ms() / 1000), 0);
          mm["data"] = md;
          ble_send_json(JSON.stringify(mm));
        }
        else {
          String jobTime = String(millis());
          coreJobs[jobTime]["type"] = "https";
          coreJobs[jobTime]["url"] = "https://" + homebaseIP +
            "/watch/measure?room=1&button=" + spin + "&measure=" + bs +
            "&component=pot&min=0&max=1024";
          coreJobs[jobTime]["response"] = "pot";
        }

      }
    }
  }
  input_working = 0;
}

String led_toggle(int pin, String state) {

  pinMode(pin, OUTPUT);

  if (state == "on") {
    digitalWrite(pin, HIGH);
  }
  else {
    digitalWrite(pin, LOW);
  }
  String spin = String(pin);
  config["led"][spin] = state;
  config_writer();
  return state;
}

String relay_toggle(int pin, String state) {

  pinMode(pin, OUTPUT);

  if (state == "on") {
    digitalWrite(pin, HIGH);
  }
  else {
    digitalWrite(pin, LOW);
  }
  String spin = String(pin);
  config["relay"][spin] = state;
  config_writer();
  return state;
}

String servo_toggle(int pin, String state) {
  int stat = state.toInt();

  int val = (stat / 100);
  Serial.println(val);
  val = val * 180;
  String spin = String(pin);
  Serial.println(val);
  Serial.println(stat);
  
  if (!myservo.attached()) {
    myservo.attach(pin);
  }
  myservo.write(stat);
  String vale = String(val);
  config["servo"][spin] = vale;
  config_writer();
  return vale;
}
void push_job(String component,int pin, String state, String timestamp, String uuid, String appt_uuid) {
  String spin = String(pin);
  Serial.println("pushing job " + uuid + " " + timestamp);
  config["jobs"][uuid]["pin"] = spin;
  config["jobs"][uuid]["timestamp"] = timestamp;
  config["jobs"][uuid]["component"] = component;
  config["jobs"][uuid]["state"] = state;
  config["jobs"][uuid]["uuid"] = uuid;
  config["jobs"][uuid]["appt_uuid"] = appt_uuid;
}

void handle_jobs() {
  if (time_defined && config["jobs"].keys().length() > 0) {
    // local epoch -> the UTC milliseconds the appointments carry
    int64_t timestamp = now_ms() - (offset * 1000);

    JSONVar jobKeys = config["jobs"].keys();
    for (int i = 0; i < jobKeys.length(); i++) {
      String times = String(config["jobs"][jobKeys[i]]["timestamp"]);
      int64_t ts = times.toDouble();

      if (timestamp >= ts) {
        Serial.print(jobKeys[i]);
        Serial.println(ts);
        String spin = config["jobs"][jobKeys[i]]["pin"];
        String component = config["jobs"][jobKeys[i]]["component"];
        String state = config["jobs"][jobKeys[i]]["state"];
        String uuid = config["jobs"][jobKeys[i]]["uuid"];

        int pin = spin.toInt();
        if (component == "relay") {
          state = relay_toggle(pin,state);
        }
        else if (component == "led") {
          state = led_toggle(pin,state);
        }
        else if (component == "servo") {
          state = servo_toggle(pin,state);
        }
        
        config["jobs"][uuid] = undefined;
      }
    }
  }
  JSONVar coreKeys = coreJobs.keys();

  for (int i = 0; i < coreKeys.length(); i++) {
    Serial.println("core job ");
    Serial.println(coreKeys[i]);
    Serial.println(coreJobs[coreKeys[i]]["type"]);
    if (String(coreJobs[coreKeys[i]]["type"]) == "led") {
      int interval = String(coreJobs[coreKeys[i]]["interval"]).toInt();
      int duration = String(coreJobs[coreKeys[i]]["duration"]).toInt();
      ledFlasher(interval,duration);
    }
    else if (String(coreJobs[coreKeys[i]]["type"]) == "https") {
      String url = String(coreJobs[coreKeys[i]]["url"]);
      String response = https_request(url);

      if (String(coreJobs[coreKeys[i]]["response"]) == "button") {
        JSONVar returner = JSON.parse(response);
        config["button"][returner["button"]]["toggle"] = returner["toggle"];
      }
      if (String(coreJobs[coreKeys[i]]["response"]) == "switch") {
        JSONVar returner = JSON.parse(response);
        config["switch"][returner["switch"]]["state"] = returner["state"];
      }
      if (String(coreJobs[coreKeys[i]]["response"]) == "time") {
        JSONVar timers = JSON.parse(response);

        int64_t timestamp = (int64_t)(double)timers["timestamp"];
        int64_t offset_s = (int64_t)(double)timers["offset"];
        set_epoch_seconds(timestamp + offset_s);  
      }

    }
    coreJobs[coreKeys[i]] = undefined;
  }
}

uint32_t lastMillis;

// Days-from-epoch to a civil date, so the display works past 2038 without
// localtime_r()/32-bit time_t. The epoch we hold is already local seconds.
jawn_time break_epoch(int64_t seconds) {
  int64_t days = seconds / 86400;
  int64_t rem = seconds % 86400;
  if (rem < 0) { rem += 86400; days -= 1; }
  int64_t z = days + 719468;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = (unsigned)(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  int64_t y = (int64_t)yoe + era * 400;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;
  unsigned d = doy - (153 * mp + 2) / 5 + 1;
  unsigned m = mp + (mp < 10 ? 3 : -9);
  y += (m <= 2);
  jawn_time t;
  t.year = (int)y;
  t.month = (int)m;
  t.day = (int)d;
  t.hour = (int)(rem / 3600);
  t.min = (int)((rem % 3600) / 60);
  t.sec = (int)(rem % 60);
  return t;
}

void read_time() {
  if ((uint32_t)(millis() - lastMillis) >= 1000) {
    lastMillis = millis();
    if (!time_defined) { return; }
    int64_t secs = now_ms() / 1000;
    jawn_time t = break_epoch(secs);
    static const char *mon[] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    static const char *dow[] = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    int64_t days = secs / 86400;
    if (secs < 0 && secs % 86400) { days -= 1; }
    int wd = (int)((days + 4) % 7);   // 1970-01-01 was a Thursday
    if (wd < 0) { wd += 7; }
    char buffdate[80];
    char bufftime[80];
    snprintf(buffdate, sizeof(buffdate), "%s %s %02d %d", dow[wd], mon[t.month - 1], t.day, t.year);
    snprintf(bufftime, sizeof(bufftime), "%02d:%02d:%02d", t.hour, t.min, t.sec);
    String timing = (const char *)buffdate;
    lcd.setCursor(0,0);
    lcd.print(timing);
    lcd.setCursor(0,1);
    String timings = (const char *)bufftime;
    lcd.print(timings);
  }
}

void config_writer() {
  // Do not persist uptime: assigning millis() through this JSONVar build
  // serialized as an empty value, which made the whole file invalid and sent a
  // rebooted board back to its provisioning AP. uptime is a diagnostic; the
  // /device_query route adds it to the reply without saving it.
  String jconfig = JSON.stringify(config);
  // Replace, do not overwrite in place: LittleFS's "w" was leaving the old
  // tail behind, so a short (cleared) config still read back as the previous
  // long file and JSON.parse saw the stale object.
  LittleFS.remove("config.txt");
  File f = LittleFS.open("config.txt", "w");
  if (f) {
    f.truncate(0);
    f.print(jconfig);
    f.close();
  }
//  Serial.println(jconfig);
}

void config_init() {
  Serial.println("Config init");
  JSONVar relayKeys = config["relay"].keys();
  for (int i = 0; i < relayKeys.length(); i++) {
    Serial.print(relayKeys[i]);
    Serial.println(config["relay"][relayKeys[i]]);
    String state = config["relay"][relayKeys[i]];
    String spin = relayKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    pinMode(pin, OUTPUT);

    if (state == "on") {  
      digitalWrite(pin, HIGH);
    }
    else {
      digitalWrite(pin,LOW);
    }
  }
  JSONVar ledKeys = config["led"].keys();
  for (int i = 0; i < ledKeys.length(); i++) {
    Serial.print(relayKeys[i]);
    Serial.println(config["led"][ledKeys[i]]);
    String state = config["led"][ledKeys[i]];
    String spin = ledKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    pinMode(pin, OUTPUT);    
    if (state == "on") {
      digitalWrite(pin, HIGH);
    }
    else {
      digitalWrite(pin, LOW);
    }
  }
  JSONVar buttonKeys = config["button"].keys();
  for (int i = 0; i < buttonKeys.length(); i++) {
    Serial.print(buttonKeys[i]);
    Serial.println(config["button"][buttonKeys[i]]);
    String toggle = config["button"][buttonKeys[i]]["toggle"];
    config["button"][buttonKeys[i]]["lastPress"] = String(millis());
    String spin = buttonKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    pinMode(pin, INPUT);    
  }
  JSONVar switchKeys = config["switch"].keys();
  for (int i = 0; i < switchKeys.length(); i++) {
    String state = config["switch"][switchKeys[i]]["state"];
    config["switch"][switchKeys[i]]["lastChange"] = String(millis());
    config["switch"][switchKeys[i]]["lastSend"] = String(millis());
    String spin = switchKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }

    pinMode(pin, INPUT);
  }
  JSONVar potKeys = config["pot"].keys();
  for (int i = 0; i < potKeys.length(); i++) {
    config["pot"][potKeys[i]]["lastMove"] = String(millis());
    config["pot"][potKeys[i]]["lastSend"] = String(millis());

    String spin = potKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
  //  pinMode(pin, INPUT);
  }


  JSONVar servoKeys = config["servo"].keys();
  for (int i = 0; i < servoKeys.length(); i++) {
    Serial.print(servoKeys[i]);
    Serial.println(config["servo"][servoKeys[i]]);
    String state = config["servo"][servoKeys[i]];
    String spin = servoKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }
    
    myservo.attach(pin);
  }
  authorization = (const char * )config["authorization"];
  homebase = String(config["homebase"]);
  homebaseIP = String(config["homebaseIP"]);
  // JSONVar::operator bool() is true only for a JSON boolean, not for a
  // non-empty string. The old `if (config["ssid"] && config["password"])` was
  // therefore always false, so a board that rebooted read its saved WiFi (and
  // its saved AP credentials) but never used them and came up in the default
  // provisioning AP. Compare against the empty string instead.
  if (config["ssid"] != "" && config["password"] != "") {
    ssid = String((const char *)config["ssid"]);
    password = String((const char *)config["password"]);
  }
  if (config["ap_ssid"] != "" && config["ap_password"] != "") {
    ap_ssid = String((const char *)config["ap_ssid"]);
    ap_password = String((const char *)config["ap_password"]);
  }

/*    

  String tstamp = String(config["timestamp"]);
  long timestamp = tstamp.toInt();
  timestamp = timestamp - (60 * 9) + 4;
  String oset = String(config["offset"]);
  long offset = oset.toInt();
  Serial.print("time setting ");
  Serial.print(tstamp);
  Serial.print(" ");
  Serial.println(timestamp);
  struct timeval tv;
  tv.tv_sec = (timestamp + offset);
  settimeofday(&tv,nullptr);
*/
}

String url_maker(String url) {
  String chip_id = rp2040.getChipID();
  url = url + "&edt=microcontroller&chip_id=" + chip_id + "&authorization=" + authorization;
  return url;
}

String https_request(String url) {
  
  if (homebaseOnline == 0) {
    return "no ping";
  }
  url = url_maker(url);
  Serial.println("In the https request");
  Serial.println(url);
  connexion -> setInsecure();
  Serial.print("homebase online ");
  Serial.println(homebaseOnline);
  if (connexion && homebaseOnline > 0) {
    {
      Serial.println("Starting connexion");
      if (https.begin(*connexion, url)) {
        
        Serial.println("Right after connexion");
        int httpCode = https.GET();
        Serial.println(httpCode);
        if (httpCode > 0) {

          if (httpCode == HTTP_CODE_OK) {
            homebaseOnline = millis();
            String payload = https.getString();
            return payload;
          }
        }
        else {
          Serial.printf("HTTPS FAILED error: %s\n", https.errorToString(httpCode).c_str());
          homebaseOnline = 0;
          return "failure";
        }
        https.end();
      }
    }
  }
  homebaseOnline = 0;
  return "failure";
}

void call_the_president() {
  //  Serial.println("dans presidente");
  //  Serial.println(before_me);
  //  Serial.println("copy");
  JSONVar result;
  Serial.print("bb: " );
  if (homebaseIP != "") {
    String req = "https://" + homebaseIP + "/watch?room=1&browser_tab_id=" + browser_tab_id;
    Serial.println(req);
    String watchRequest = https_request(req);
    Serial.println(watchRequest);
    if (watchRequest != "failure") {
      before_me = watchRequest;
      if (before_me != "No!") {
        JSONVar ctp = JSON.parse(before_me);
        JSONVar ctpKeys = ctp.keys();
        config["button"] = undefined;
        config["pot"] = undefined;
        config["led"] = undefined;
        config["servo"] = undefined;
        config["relay"] = undefined;
        config["switch"] = undefined;
        config["outputs"] = undefined;
        config["internal_jobs"] = undefined;
        for (int i = 0; i < ctpKeys.length(); i++) {
          String numero = String((long)jint(ctp[ctpKeys[i]]["numero"]));
          String component = jstr(ctp[ctpKeys[i]]["component"]);
          String name = String(ctpKeys[i]);
          int pin = numero.toInt();
          if (!pin_ok(pin)) { continue; }
          if (component == "button") {
            String toggle = String((long)jint(ctp[ctpKeys[i]]["toggle"]));
            config["button"][numero]["lastPress"] = String(millis());
            config["button"][numero]["toggle"] = toggle;
            config["button"][numero]["name"] = name;
            pinMode(pin, INPUT);

          }
          else if (component == "pot") {
            config["pot"][numero]["lastMove"] = String(millis());
            config["pot"][numero]["lastSend"] = String(millis());
            config["pot"][numero]["name"] = name;
          //  pinMode(pin, INPUT);
          }
          else if (component == "switch") {
            config["switch"][numero]["lastChange"] = String(millis());
            config["switch"][numero]["lastSend"] = String(millis());
            config["switch"][numero]["name"] = name;
            pinMode(pin, INPUT);
          }
          else if (component == "relay" || component == "led" || component == "servo") {
            String toggle = String((long)jint(ctp[ctpKeys[i]]["toggle"]));
            String inverted = jstr(ctp[ctpKeys[i]]["inverted"]);
            String state = (toggle == "1") ? "on" : "off";
            if (component == "servo") { state = toggle; }
            else if (inverted == "1") { state = (state == "on") ? "off" : "on"; }
            if (component == "relay") { config["relay"][numero] = state; }
            else if (component == "led") { config["led"][numero] = state; }
            else { config["servo"][numero] = state; }
            JSONVar o;
            o["component"] = component;
            o["pin"] = pin;
            o["app"] = jstr(ctp[ctpKeys[i]]["app"]);
            o["inverted"] = inverted;
            config["outputs"][component + numero] = o;
            pinMode(pin, OUTPUT);
          }
          else if (name == "__specs") {
            String ij = JSON.stringify(ctp[ctpKeys[i]]["internal_jobs"]);
            Serial.println(ij);
            config["internal_jobs"] = ij;
            Serial.println("this is an inside job");
          }
          Serial.println(name);
        }
        president_loaded = true;
      }
      config_writer();
      config_init();
      coreJobs["president"]["type"] = "led";
      coreJobs["president"]["interval"] = "50";
      coreJobs["president"]["duration"] = "1000";

    }
  }

  //Serial.println(before_me);
}
