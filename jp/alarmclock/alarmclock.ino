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
// The address Now Me gave this board is the preferred House machine. The active
// address may move to another computer/mobile/server when that one stops
// answering; the preferred one is returned to as soon as it answers again.
String homebasePreferredIP;
// House machines the board can fall back to. Now Me carries the LAN list (this
// board's core has no mDNS browser), so a laptop that slept does not strand it.
#define HOUSE_MAX 6
String houseAddr[HOUSE_MAX];
int houseCount = 0;
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

// The house stores UTC; now_ms() is local (the LCD uses it). An event carries
// UTC seconds so an appointment written from a switch or button is not hours
// old. Zero means "no clock yet" and the manager falls back to its own time.
static bool offset_sane(int64_t off);
String event_timestamp() {
  if (!time_defined) { return "0"; }
  // Never let a poisoned offset turn a real movement into an impossible time.
  int64_t off = offset_sane(offset) ? offset : 0;
  return String((double)((now_ms() / 1000) - off), 0);
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
String led_toggle(int pin, String state, bool persist = true);
String relay_toggle(int pin, String state, bool persist = true, int src = 2);
String servo_toggle(int pin, String state);
void config_writer();
void config_init();
void run_local_jobs();
static bool pin_is_switch_driven(int pin);
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

// The scan response names this board without requiring the Nordic UART service:
// manufacturer data (company 0xFFFF), "JW", version, flags, purpose and the
// chip id as ASCII. The house's adopt scan matches the magic, so a board with a
// custom service - or one the bridge has never met - is still recognized, and a
// device already in the fleet is re-adopted by the id it reports.
static uint8_t ble_scan_rsp[31];
static size_t ble_scan_rsp_len = 0;

static void ble_build_scan_response() {
  String chip = String(rp2040.getChipID());
  size_t n = 0;
  ble_scan_rsp[n++] = 0;       // AD length, filled in below
  ble_scan_rsp[n++] = 0xFF;    // manufacturer specific data
  ble_scan_rsp[n++] = 0xFF;    // company id 0xFFFF (little endian)
  ble_scan_rsp[n++] = 0xFF;
  ble_scan_rsp[n++] = 'J';
  ble_scan_rsp[n++] = 'W';
  ble_scan_rsp[n++] = 1;       // version
  ble_scan_rsp[n++] = 1;       // flags: bit0 = relay capable
  ble_scan_rsp[n++] = 3;       // purpose: microcontroller
  for (size_t i = 0; i < chip.length() && n < sizeof(ble_scan_rsp); i++) {
    ble_scan_rsp[n++] = (uint8_t)chip[i];
  }
  ble_scan_rsp[0] = (uint8_t)(n - 1);
  ble_scan_rsp_len = n;
}

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

// A pin arrives as a string ("28") from the manager's maps. Casting that with
// jint fails and yields -1, which is how a relay command drove pin -1 and acked
// `relay -1` while the real relay never moved. Read the string first, then a
// real number; an empty token is not a pin.
static int jpin(JSONVar v) {
  String t = JSON.typeof(v);
  if (t == "number") { return (int)(long)(double)v; }
  String s = jstr(v);
  if (s == "") { return -1; }
  return s.toInt();
}

static int64_t jint64(JSONVar v) {
  String t = JSON.typeof(v);
  // Casting a String/undefined JSONVar with (double) yields NaN on this core,
  // and (int64_t)NaN is INT64_MIN. That one value poisoned `offset`, and every
  // switch event then carried a timestamp near -9.2e18 (the phantom records
  // with impossible times). Read a string as a number instead.
  if (t == "number") { return (int64_t)(double)v; }
  String s = jstr(v);
  if (s == "") { return 0; }
  return (int64_t)s.toDouble();
}

static bool offset_sane(int64_t off) { return off > -50400 && off < 50400; }

// The local switch/relay map. JSONVar drops both nested assignments and object
// assignments into config, so the pins the board actually reads and drives live
// in plain arrays rebuilt from the manager's internal_jobs string.
#define LOCAL_IN_MAX 16
#define LOCAL_OUT_MAX 4
struct local_in_t {
  int pin;
  bool is_switch;
  int inverted;        // the switch is wired active-low: LOW means on
  String name;
  int out_pin[LOCAL_OUT_MAX];
  int out_inv[LOCAL_OUT_MAX];
  String out_comp[LOCAL_OUT_MAX];
  int out_n;
};
static local_in_t local_ins[LOCAL_IN_MAX];
static int local_in_count = 0;
static int local_sw_state[30];
static bool local_sw_seen[30];
static int local_btn_pressed[30];

// App-driven outputs. A board must apply an app's toggle to a relay/LED wired
// to it even when no switch of its own drives that output, so this holds every
// output component in the role, not just the ones named in internal_jobs. It
// is a plain array for the same reason as local_ins: a JSONVar object
// assignment loses the numeric pin, and the old map then drove pin -1.
#define APP_OUT_MAX 16
struct local_out_t {
  int pin;
  String comp;
  String app;
  int inv;
};
static local_out_t local_outs[APP_OUT_MAX];
static int local_out_count = 0;
// A relay coil switching couples into an input wire on the same board. Hold
// input changes for a moment after any output moves, so the resulting glitch
// is not reported as a switch change (which would click the relay again).
static uint32_t local_out_changed_at = 0;
static const uint32_t OUTPUT_BLANK_MS = 250;
// LittleFS writes are slow enough to be felt in the switch path, so a change
// only marks the config dirty and the main loop flushes it when idle.
static bool config_dirty = false;
static uint32_t config_dirty_at = 0;
static bool config_reload_pending = false;

// A small ring of pin events, dumped by JAWNCFG? - a relay that clicks on its
// own has three possible authors (the local switch map, a manager `set`, or an
// app `toggle` push) and this says which one, with the board's own millis().
// Kept in RAM and never printed in the hot path: a USB write can block when no
// host is draining the CDC.
#define EVT_MAX 40
struct evt_t { uint32_t ms; int pin; int state; int src; };
static evt_t evt_ring[EVT_MAX];
static int evt_head = 0;
static int evt_count = 0;
static void event_log(int pin, int state, int src) {
  evt_ring[evt_head].ms = millis();
  evt_ring[evt_head].pin = pin;
  evt_ring[evt_head].state = state ? 1 : 0;
  evt_ring[evt_head].src = src;
  evt_head = (evt_head + 1) % EVT_MAX;
  if (evt_count < EVT_MAX) { evt_count++; }
}
static String event_ring_dump() {
  String out = "";
  int n = evt_count < EVT_MAX ? evt_count : EVT_MAX;
  for (int i = 0; i < n; i++) {
    int idx = (evt_head - n + i + EVT_MAX * 2) % EVT_MAX;
    if (i) { out += ";"; }
    out += String(evt_ring[idx].ms) + "," + String(evt_ring[idx].pin) + "," +
           String(evt_ring[idx].state) + "," + String(evt_ring[idx].src);
  }
  return out;
}
// loop() and loop1() used to write config.txt at once, and the two writes
// interleaved into a doubled, unparseable file (the board then booted with no
// role at all). All config mutation and every config_writer() now happens on
// core 0: the scheduled-job pass and role application moved there too. Core 1
// keeps only the blocking network work.

// A JSONVar left undefined or null serializes as an empty token, which makes
// the whole config file invalid on the next boot. Treat both as missing.
static bool cfg_missing(JSONVar v) {
  String t = JSON.typeof(v);
  return (t == "undefined" || t == "null");
}

// Give every optional config key a defined type before it is read or written.
static void config_ensure() {
  const char *obj_keys[] = { "relay", "led", "button", "switch", "pot", "servo", "outputs", "jobs", "__specs" };
  for (size_t i = 0; i < sizeof(obj_keys) / sizeof(obj_keys[0]); i++) {
    if (cfg_missing(config[obj_keys[i]])) { config[obj_keys[i]] = JSON.parse("{}"); }
  }
  const char *str_keys[] = { "houses", "ssid", "password", "ap_ssid", "ap_password", "authorization", "homebase", "homebaseIP", "homebasePreferredIP", "name", "chip_id", "purpose", "model", "pins", "uptime", "outputs_json" };
  for (size_t i = 0; i < sizeof(str_keys) / sizeof(str_keys[0]); i++) {
    if (cfg_missing(config[str_keys[i]])) { config[str_keys[i]] = ""; }
  }
  if (cfg_missing(config["internal_jobs"])) { config["internal_jobs"] = "{}"; }
  if (cfg_missing(config["offset"])) { config["offset"] = String((long)offset); }
  if (cfg_missing(config["timestamp"])) { config["timestamp"] = String((long)(now_ms() / 1000)); }
  // uptime is a diagnostic. A numeric assignment through JSONVar serializes as
  // an empty token and corrupts the file, so never persist it.
  config["uptime"] = "";
}

// A switch/button input must never float. In this firmware HIGH means on (a
// switch to 3V3) or pressed, so an unconnected pin is pulled down: otherwise it
// picks up noise, reports a stream of phantom switch changes, and the app's
// internal jobs click the relay once per change. A switch to 3V3 and any
// external pull-up still overcome the internal ~50k pull-down.
static void input_begin(int pin) { pinMode(pin, INPUT_PULLDOWN); }

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
  if (hb != "") {
    homebaseIP = hb; config["homebaseIP"] = hb;
    houseRememberPreferred(hb);
  }
  String houses = jstr(data["houses"]);
  if (houses != "") {
    config["houses"] = houses;
    houseLearnJson(houses);
  }
  String ip = jstr(data["ip"]);
  if (ip != "") { homebase = ip; config["homebase"] = ip; }
  String auth = jstr(data["authorization"]);
  if (auth != "") { authorization = auth; config["authorization"] = auth; }
  int64_t ts = jint64(data["timestamp"]);
  int64_t off = jint64(data["offset"]);
  if (ts > 1600000000 && ts < 4102444800) {
    if (offset_sane(off)) { offset = off; }
    config["timestamp"] = String((double)ts, 0);
    config["offset"] = String((double)offset, 0);
    set_epoch_seconds(ts + offset);
  }
  config_writer();
  lcd.clear();
  lcd.print(config["name"]);
}

// Serialize the role's output components as a plain JSON string of strings.
// Stored as a string (not a nested object) so the numeric pin survives: a
// numeric JSONVar value re-stringifies as an empty token.
static String local_outputs_build(JSONVar ctp) {
  if (JSON.typeof(ctp) != "object") { return "[]"; }
  String out = "[";
  bool first = true;
  JSONVar keys = ctp.keys();
  for (int i = 0; i < keys.length(); i++) {
    String name = String(keys[i]);
    if (name.startsWith("__")) { continue; }
    String component = jstr(ctp[keys[i]]["component"]);
    if (component != "relay" && component != "led" && component != "servo") { continue; }
    String numero = jstr(ctp[keys[i]]["numero"]);
    if (numero == "") { numero = String((long)jint(ctp[keys[i]]["numero"])); }
    int pin = numero.toInt();
    if (!pin_ok(pin)) { continue; }
    String inv = jstr(ctp[keys[i]]["inverted"]);
    inv = (inv == "1" || inv == "true") ? "1" : "0";
    if (!first) { out += ","; }
    first = false;
    out += "{\"c\":\"" + component + "\",\"p\":\"" + String(pin) +
           "\",\"a\":\"" + jstr(ctp[keys[i]]["app"]) + "\",\"i\":\"" + inv + "\"}";
  }
  out += "]";
  return out;
}

static void local_outputs_load() {
  local_out_count = 0;
  String raw = jstr(config["outputs_json"]);
  if (raw == "") { return; }
  JSONVar outs = JSON.parse(raw);
  if (JSON.typeof(outs) != "array") { return; }
  for (int i = 0; i < outs.length() && local_out_count < APP_OUT_MAX; i++) {
    String comp = jstr(outs[i]["c"]);
    int pin = jpin(outs[i]["p"]);
    if (!pin_ok(pin)) { continue; }
    local_out_t &o = local_outs[local_out_count++];
    o.pin = pin;
    o.comp = comp;
    o.app = jstr(outs[i]["a"]);
    o.inv = (jstr(outs[i]["i"]) == "1") ? 1 : 0;
  }
}

static void ble_apply_app_state(String app, String state) {
  if (app == "") { return; }
  for (int i = 0; i < local_out_count; i++) {
    local_out_t &o = local_outs[i];
    if (o.app != app) { continue; }
    // A switch on this board owns its output; the app push is for boards that
    // do not have the switch.
    if (pin_is_switch_driven(o.pin)) { continue; }
    String phys = state;
    if (o.inv == 1) { phys = (phys == "on") ? "off" : "on"; }
    if (o.comp == "relay") { relay_toggle(o.pin, phys, true, 3); }
    else if (o.comp == "led") { led_toggle(o.pin, phys); }
  }
}

static void ble_apply_board_config(JSONVar ctp) {
  if (JSON.typeof(ctp) != "object") { return; }
  JSONVar keys = ctp.keys();
  // A partial push (a lost BLE part, or a payload with no components) must
  // never erase the role. The manager states how many components it sent.
  int found_components = 0;
  for (int i = 0; i < keys.length(); i++) {
    String k = String(keys[i]);
    if (!k.startsWith("__")) { found_components++; }
  }
  int expected_components = (int)jint(ctp["__specs"]["component_count"]);
  if (found_components == 0 || (expected_components > 0 && found_components < expected_components)) {
    Serial.println("[cfg] ignored incomplete board_config");
    return;
  }
  Serial.println("[cfg] applying " + String(keys.length()) + " keys");
  config["button"] = JSON.parse("{}");
  config["pot"] = JSON.parse("{}");
  config["led"] = JSON.parse("{}");
  config["servo"] = JSON.parse("{}");
  config["relay"] = JSON.parse("{}");
  config["switch"] = JSON.parse("{}");
  config["outputs_json"] = local_outputs_build(ctp);
  config["internal_jobs"] = "";
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
    // `inverted` can arrive as the number 1/0. jstr only reads a string, and a
    // number came back empty - which left an active-low switch treated as
    // active-high (the relay followed the opposite of the switch).
    if (inverted != "0" && inverted != "1") { inverted = jint(e["inverted"]) ? "1" : "0"; }
    String app = jstr(e["app"]);
    if (component == "button") {
      config["button"][numero]["lastPress"] = String(millis());
      config["button"][numero]["toggle"] = String((long)jint(e["toggle"]));
      config["button"][numero]["name"] = name;
      config["button"][numero]["inverted"] = inverted;
      input_begin(pin);
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
      config["switch"][numero]["inverted"] = inverted;
      input_begin(pin);
    }
    else if (component == "relay" || component == "led" || component == "servo") {
      String state = ((long)jint(e["toggle"]) == 1) ? "on" : "off";
      if (component == "servo") { state = String((long)jint(e["toggle"])); }
      if (inverted == "1" && component != "servo") { state = (state == "on") ? "off" : "on"; }
      if (component == "relay") { config["relay"][numero] = state; }
      else if (component == "led") { config["led"][numero] = state; }
      else { config["servo"][numero] = state; }
      if (component != "servo") { pinMode(pin, OUTPUT); }
    }
  }
  if (JSON.typeof(ctp["__specs"]["internal_jobs"]) != "undefined") {
    config["internal_jobs"] = JSON.stringify(ctp["__specs"]["internal_jobs"]);
  }
  String auth = jstr(ctp["__specs"]["authorization"]);
  if (auth != "") { authorization = auth; config["authorization"] = auth; }
  String hb = jstr(ctp["__specs"]["homebase"]);
  if (hb != "" && homebaseIP == "") { homebaseIP = hb; config["homebaseIP"] = hb; houseRememberPreferred(hb); }
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
  int pin = jpin(data["pin"]);
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
  // A relay envelope from the house (or from a peer bridge). Unwrap it only when
  // it names this chip; the manager has already routed it, so anything else is
  // a stale copy.
  if (type == "relay") {
    String to = jstr(msg["to"]);
    String mine = String(rp2040.getChipID());
    if (to != "" && to != mine) { return; }
    JSONVar inner = msg["message"];
    if (JSON.typeof(inner) != "object") { return; }
    msg = inner;
    type = jstr(msg["type"]);
  }
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
        Serial.println("JAWNCFG EVENTS " + event_ring_dump());
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
          // A USB provision carries WiFi and the token, not the role. Keep the
          // existing relays/switches so rejoining does not leave the board with
          // dead pins until the next BLE or /watch push.
          JSONVar prior = config;
          config = incoming;
          const char *keep_keys[] = { "relay", "led", "button", "switch", "pot", "servo", "outputs", "internal_jobs", "houses", "__specs" };
          for (size_t ki = 0; ki < sizeof(keep_keys) / sizeof(keep_keys[0]); ki++) {
            if (cfg_missing(config[keep_keys[ki]]) && !cfg_missing(prior[keep_keys[ki]])) {
              config[keep_keys[ki]] = prior[keep_keys[ki]];
            }
          }
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
  ble_build_scan_response();
  bd_addr_t null_addr = {0};
  gap_advertisements_set_params(0x30, 0x30, 0, 0, null_addr, 0x07, 0x00);
  gap_advertisements_set_data(sizeof(ble_adv), (uint8_t *)ble_adv);
  gap_scan_response_set_data(ble_scan_rsp_len, ble_scan_rsp);
  gap_advertisements_enable(1);
  hci_power_control(HCI_POWER_ON);
  Serial.println("[ble] advertising as JawnPico");
}

void setup1() {
  // Do NOT call Serial.begin() here: core 1 starts alongside setup() on core 0,
  // and two concurrent USB initialisations wedge the CDC (the host then sees
  // the port but reads nothing until a replug). Core 0 owns the USB stack.
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
  if (JSON.typeof(config) != "object") { config = JSON.parse("{}"); }
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
    config["purpose"] = "microcontroller";
    config["model"] = "Raspberry Pi Pico 2W";
    config["pins"] = "28";
    JSONVar jonfig = config;
    // uptime is for the reply only, and as a string so JSONVar never mangles it.
    jonfig["uptime"] = String(millis());
    jonfig["ssid"] = undefined;
    jonfig["password"] = undefined;
    jonfig["ap_password"] = undefined;
    jonfig["ap_ssid"] = undefined;
    String gs = JSON.stringify(jonfig);
    server.send(200, "text/plain", gs);
    // Do not persist the diagnostics (uptime especially): this route used to
    // write them into config.txt on every query.
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
    houseRememberPreferred(homebaseIP);
    houseLearnJson(server.arg("houses"));
    if (server.arg("houses") != "") { config["houses"] = server.arg("houses"); }
    config["authorization"] = server.arg("authorization");
    authorization = server.arg("authorization");
    config["name"] = server.arg("name");
    Serial.println(server.arg("name"));
    browser_tab_id = server.arg("browser_tab_id");
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
      state = relay_toggle(pin,state,true,4);
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
    multi.addAP(ssid.c_str(), password.c_str());
  }
  if (multi.run() == WL_CONNECTED && config["ssid"] != "" && config["password"] != "") {
    server.begin();
    jawnos_mdns_start();
    Serial.println("WiFi connected");
    Serial.println("IP address: ");
    Serial.println(WiFi.localIP());    
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
  // Switches first. A board's own switch must not wait behind an HTTP request
  // or the LCD, and the local internal job below is the fast path to its relay.
  input_scanner();
  server.handleClient();
  read_time();
  // USB serial: echo (as before) and accept a "JAWNCFG <json>" line from the
  // manager, which writes the stored WiFi and role and then reboots us.
  usb_config_loop();
  ble_loop();
  if (config_reload_pending) {
    config_reload_pending = false;
    config_init();
  }
  // Scheduled output jobs read/write the config document, so they belong on
  // this core with the switch scanner.
  run_local_jobs();
  // Persist a switch/relay change once it has been quiet for a moment. Doing
  // it inline made a flick wait on a LittleFS rewrite.
  if (config_dirty && (uint32_t)(millis() - config_dirty_at) > 2000) {
    config_dirty = false;
    config_writer();
  }

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
  // Pull the role (components and internal_jobs) from the house. A blocking
  // HTTPS call, so it runs on this core: putting it on core 0 spent most of a
  // loop downloading a refusal page and starved the switch scanner.
  if (!president_loaded && wifiState == "connected" && homebaseIP != "" && (millis() - lastPresidentTry > 20000)) {
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
      // The preferred machine wins the moment it answers again, so the phone or
      // laptop the board was paired to reclaims it from a temporary fallback.
      if (homebasePreferredIP != "" && homebasePreferredIP != homebaseIP) {
        houseAdoptIfAlive(homebasePreferredIP);
      }
      lastPing = millis();
      return;
    }
    Serial.println("no ping");
    if (houseTryFallback()) {
      lastPing = millis();
      return;
    }
    homebaseOnline = 0;
  }
  else {
    // wifi_supervise() owns reconnecting and the AP, so there is one owner.
    wifiState = "disconnected";
  }
  lastPing = millis();
}

// A house entry is "ip:arm". Add it once.
void houseAdd(const String &ip, int arm) {
  if (ip == "" || arm <= 0) { return; }
  String addr = ip + ":" + String(arm);
  for (int i = 0; i < houseCount; i++) {
    if (houseAddr[i] == addr) { return; }
  }
  if (houseCount >= HOUSE_MAX) { return; }
  houseAddr[houseCount++] = addr;
}

void houseLearnJson(const String &js) {
  // Now Me's "houses": [{"ip":"192.168.2.3","arm":45547,...}, ...]
  if (js.length() < 2) { return; }
  JSONVar list = JSON.parse(js);
  if (JSON.typeof(list) != "array") { return; }
  for (int i = 0; i < (int)list.length(); i++) {
    JSONVar h = list[i];
    if (JSON.typeof(h) != "object") { continue; }
    String ip = jstr(h["ip"]);
    int arm = (int)jint(h["arm"]);
    if (arm <= 0 && ip != "") { arm = 45547; }
    houseAdd(ip, arm);
  }
}

void houseRememberPreferred(const String &hb) {
  if (hb == "") { return; }
  homebasePreferredIP = hb;
  config["homebasePreferredIP"] = homebasePreferredIP;
  // the preferred machine is also a candidate, so a reboot with no fresh Now Me
  // can still return to it
  String ip = hb;
  int split = ip.lastIndexOf(':');
  int arm = 0;
  if (split > 0) { arm = ip.substring(split + 1).toInt(); ip = ip.substring(0, split); }
  houseAdd(ip, arm);
}

// Probe one address quietly, without disturbing the active homebase unless it
// answers. Returns true and adopts it on success.
bool houseAdoptIfAlive(const String &addr) {
  if (addr == "" || addr == "failure") { return false; }
  String saved = homebaseIP;
  homebaseOnline = 1;
  homebaseIP = addr;
  String r = https_request("https://" + addr + "/watch/time?");
  // A denial is a template answered 200 with a ~130 KB body; the timestamp is
  // the one answer that proves the machine accepted the pair. `https_request`
  // keeps the short answer only, so a long body is a refusal too.
  if (r == "failure" || r == "no ping" || r.indexOf("timestamp") < 0 || r.length() > 4096) {
    homebaseIP = saved;
    homebaseOnline = millis();
    return false;
  }
  int split = addr.lastIndexOf(':');
  homebase = (split > 0) ? addr.substring(0, split) : addr;
  config["homebaseIP"] = addr;
  config["homebase"] = homebase;
  config_writer();
  Serial.println("[house] now using " + addr);
  return true;
}

bool houseTryFallback() {
  for (int i = 0; i < houseCount; i++) {
    if (houseAddr[i] == homebaseIP) { continue; }
    if (houseAdoptIfAlive(houseAddr[i])) { return true; }
  }
  return false;
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

static void local_apply(int idx, const String &state) {
  local_in_t &in = local_ins[idx];
  for (int o = 0; o < in.out_n; o++) {
    int op = in.out_pin[o];
    String st = state;
    if (in.out_inv[o] == 1) { st = (st == "on") ? "off" : "on"; }
    pinMode(op, OUTPUT);
    digitalWrite(op, st == "on" ? HIGH : LOW);
    if (in.out_comp[o] == "relay") { config["relay"][String(op)] = st; }
    else if (in.out_comp[o] == "led") { config["led"][String(op)] = st; }
    event_log(op, st == "on", 1);
    local_out_changed_at = millis();
  }
}

// Is this output pin driven by a switch on this board? If so the switch owns
// it: an app toggle must not fight the physical position (that is what made a
// replug flash the relay before the switch was read).
static bool pin_is_switch_driven(int pin) {
  for (int i = 0; i < local_in_count; i++) {
    if (!local_ins[i].is_switch) { continue; }
    for (int o = 0; o < local_ins[i].out_n; o++) {
      if (local_ins[i].out_pin[o] == pin) { return true; }
    }
  }
  return false;
}

// At boot or a role reload, put every switch-driven output at the position the
// switch is actually in. Otherwise the relay is restored from the app's toggle
// and the first scan fights it.
static void local_inputs_apply_all() {
  for (int i = 0; i < local_in_count; i++) {
    local_in_t &in = local_ins[i];
    if (!in.is_switch) { continue; }
    int r = digitalRead(in.pin);
    String state = ((r ^ in.inverted) ? "on" : "off");
    local_apply(i, state);
  }
}

static void local_input_scanner() {
  static int raw[LOCAL_IN_MAX];
  static uint32_t raw_at[LOCAL_IN_MAX];
  static bool raw_seen[LOCAL_IN_MAX];
  for (int i = 0; i < local_in_count; i++) {
    local_in_t &in = local_ins[i];
    int r = digitalRead(in.pin);
    if (!raw_seen[i] || raw[i] != r) {
      raw_seen[i] = true;
      raw[i] = r;
      raw_at[i] = millis();
      continue;
    }
    if ((uint32_t)(millis() - raw_at[i]) < 80) { continue; }
    if (in.is_switch) {
      // The relay coil firing right now can glitch this line. Re-arm the
      // settle timer instead of swallowing the change, so a real flick during
      // the blanking window is still seen when it ends.
      if ((uint32_t)(millis() - local_out_changed_at) < OUTPUT_BLANK_MS) {
        raw_at[i] = millis();
        continue;
      }
      if (local_sw_seen[in.pin] && r == local_sw_state[in.pin]) { continue; }
      local_sw_seen[in.pin] = true;
      local_sw_state[in.pin] = r;
      // The role says whether the input is active-low. A switch that reads
      // HIGH when it is off otherwise reports the opposite of its position -
      // and drives the relay the wrong way.
      String state = ((r ^ in.inverted) ? "on" : "off");
      event_log(in.pin, r, 0);
      local_apply(i, state);
      if (ble_up && ble_notify_enabled) {
        JSONVar sm;
        sm["type"] = "switch";
        sm["chip_id"] = String(rp2040.getChipID());
        sm["edt"] = "microcontroller";
        JSONVar sd;
        sd["room"] = "1";
        sd["switch"] = String(in.pin);
        sd["state"] = state;
        sd["timestamp"] = event_timestamp();
        sd["ms"] = String(millis());
        sm["data"] = sd;
        ble_send_json(JSON.stringify(sm));
      }
      else {
        String jobTime = String(millis());
        coreJobs[jobTime]["type"] = "https";
        coreJobs[jobTime]["url"] = "https://" + homebaseIP +
          "/watch/switch?room=1&switch=" + String(in.pin) + "&state=" + state;
        coreJobs[jobTime]["response"] = "switch";
      }
      config_dirty = true;
      config_dirty_at = millis();
    }
    else {
      bool pressed = (r ^ in.inverted) ? true : false;
      if (pressed && local_btn_pressed[in.pin] == 0) {
        local_btn_pressed[in.pin] = 1;
        String nstate = "on";
        if (in.out_n > 0) { nstate = (digitalRead(in.out_pin[0]) == HIGH) ? "off" : "on"; }
        local_apply(i, nstate);
        String toggle = (nstate == "on") ? "1" : "0";
        if (ble_up && ble_notify_enabled) {
          JSONVar bm;
          bm["type"] = "button";
          bm["chip_id"] = String(rp2040.getChipID());
          bm["edt"] = "microcontroller";
          JSONVar bp;
          bp["room"] = "1";
          bp["button"] = String(in.pin);
          bp["toggle"] = toggle;
          bp["timestamp"] = event_timestamp();
          bp["ms"] = String(millis());
          bm["payload"] = bp;
          ble_send_json(JSON.stringify(bm));
        }
        else {
          String jobTime = String(millis());
          coreJobs[jobTime]["type"] = "https";
          coreJobs[jobTime]["url"] = "https://" + homebaseIP +
            "/watch/button?room=1&button=" + String(in.pin) + "&toggle=" + toggle;
          coreJobs[jobTime]["response"] = "button";
        }
        config_dirty = true;
        config_dirty_at = millis();
      }
      else if (!pressed) { local_btn_pressed[in.pin] = 0; }
    }
  }
}

void input_scanner() {
  if (input_working == 1) {
    return;
  }
  input_working = 1;
  local_input_scanner();
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

        String name = String(config["pot"][potKeys[i]]["name"]);
        String jij = config["internal_jobs"];
        JSONVar ij = JSON.parse(jij);
        if (ij[name].length() > 0) {
          config["pot"][spin]["lastValue"] = bs;          

          for (int j = 0; j < ij[name].length(); j++) {
            int p = String(ij[name][j]["numero"]).toInt();
            int inv = String(ij[name][j]["inverted"]).toInt();
            String tp = String(ij[name][j]["threshold_percentage"]);
            double thresh = tp.toDouble();
            
            thresh = ( thresh / 100 ) * 1024;
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
              relay_toggle(p, jState, false, 6);
            }
            if (String(ij[name][j]["component"]) == "led") {
              led_toggle(p, jState, false);
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
          md["timestamp"] = event_timestamp();
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

String led_toggle(int pin, String state, bool persist) {

  pinMode(pin, OUTPUT);

  if (state == "on") {
    digitalWrite(pin, HIGH);
  }
  else {
    digitalWrite(pin, LOW);
  }
  local_out_changed_at = millis();
  String spin = String(pin);
  config["led"][spin] = state;
  if (persist) { config_writer(); }
  return state;
}

String relay_toggle(int pin, String state, bool persist, int src) {

  pinMode(pin, OUTPUT);

  if (state == "on") {
    digitalWrite(pin, HIGH);
  }
  else {
    digitalWrite(pin, LOW);
  }
  event_log(pin, state == "on", src);
  local_out_changed_at = millis();
  String spin = String(pin);
  config["relay"][spin] = state;
  if (persist) { config_writer(); }
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

// Scheduled output jobs. This reads and rewrites the config document, so it
// runs on core 0 with the switch scanner; only the blocking network work below
// stays on core 1.
void run_local_jobs() {
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
          state = relay_toggle(pin,state,false,5);
          config_dirty = true;
          config_dirty_at = millis();
        }
        else if (component == "led") {
          state = led_toggle(pin,state,false);
          config_dirty = true;
          config_dirty_at = millis();
        }
        else if (component == "servo") {
          state = servo_toggle(pin,state);
        }

        config["jobs"][uuid] = undefined;
      }
    }
  }
}

// The blocking half: core 1 only, no config document access.
void handle_jobs() {
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
        // The board already applied the press locally; its own scanner reads
        // the output pin, not this map. Nothing to write back here.
      }
      if (String(coreJobs[coreKeys[i]]["response"]) == "switch") {
        // Same: local_sw_state is the scanner's source of truth.
      }
      if (String(coreJobs[coreKeys[i]]["response"]) == "time") {
        JSONVar timers = JSON.parse(response);

        int64_t timestamp = jint64(timers["timestamp"]);
        int64_t offset_s = jint64(timers["offset"]);
        // A denial page or a dead homebase is not a clock. Applying an empty
        // answer used to set offset to INT64_MIN and every later switch event
        // carried a timestamp near -9.2e18.
        if (timestamp > 1600000000 && timestamp < 4102444800 && offset_sane(offset_s)) {
          // Keep the offset, not just the adjusted epoch: a switch/button event
          // must subtract it to send UTC, while the LCD keeps showing local time.
          offset = offset_s;
          set_epoch_seconds(timestamp + offset_s);
        }
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

// The writer's body. Every caller is on core 0 now (see the note at the top of
// the local map), so there is no concurrent writer to serialize.
void config_writer() {
  config_ensure();
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

static void local_jobs_load() {
  local_in_count = 0;
  String ij_s = jstr(config["internal_jobs"]);
  JSONVar ij = JSON.parse(ij_s);
  bool have_jobs = (JSON.typeof(ij) == "object");
  // Every switch/button in the role is an input, whether or not this board
  // drives an output from it: a switch wired only to another board's relay
  // still has to report its movement. internal_jobs adds the local outputs on
  // top. Reading the inputs from the role (not from internal_jobs) is what
  // makes one scanner enough, and one scanner is what stops every event
  // arriving twice.
  const char *in_keys[] = { "switch", "button" };
  for (int c = 0; c < 2; c++) {
    bool is_sw = String(in_keys[c]) == "switch";
    JSONVar keys = config[in_keys[c]].keys();
    for (int i = 0; i < keys.length() && local_in_count < LOCAL_IN_MAX; i++) {
      int pin = String((const char *)keys[i]).toInt();
      if (!pin_ok(pin)) { continue; }
      String name = jstr(config[in_keys[c]][keys[i]]["name"]);
      if (name == "") { name = String(in_keys[c]) + String(pin); }
      local_in_t &in = local_ins[local_in_count++];
      in.pin = pin;
      in.is_switch = is_sw;
      in.inverted = (jstr(config[in_keys[c]][keys[i]]["inverted"]) == "1") ? 1 : 0;
      in.name = name;
      in.out_n = 0;
      input_begin(pin);
      // Adopt the level present now. A role reload or reboot must not look
      // like a press, and a button already held must not fire on boot.
      int level = digitalRead(pin);
      local_sw_state[pin] = level;
      local_sw_seen[pin] = true;
      local_btn_pressed[pin] = (level ^ in.inverted) ? 1 : 0;
      if (have_jobs) {
        JSONVar jobs = ij[name];
        for (int j = 0; j < jobs.length() && in.out_n < LOCAL_OUT_MAX; j++) {
          String comp = jstr(jobs[j]["component"]);
          int op = jpin(jobs[j]["numero"]);
          int inv = (int)jint(jobs[j]["inverted"]);
          if (!pin_ok(op)) { continue; }
          if (comp != "relay" && comp != "led") { continue; }
          // Do not drive the output here. It is restored from config["relay"]
          // / config["led"] in config_init(); driving it from this map used to
          // click the relay on every role push.
          in.out_pin[in.out_n] = op;
          in.out_inv[in.out_n] = inv;
          in.out_comp[in.out_n] = comp;
          in.out_n++;
        }
      }
    }
  }
  local_outputs_load();
}

void config_init() {
  config_ensure();
  local_jobs_load();
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
    input_begin(pin);
    // Remember the level we booted at. Otherwise the first scan sees a
    // difference from the stored value and treats it as a press.
    config["button"][spin]["pressed"] = (digitalRead(pin) == HIGH) ? "yes" : "no";
  }
  JSONVar switchKeys = config["switch"].keys();
  for (int i = 0; i < switchKeys.length(); i++) {
    config["switch"][switchKeys[i]]["lastChange"] = String(millis());
    config["switch"][switchKeys[i]]["lastSend"] = String(millis());
    String spin = switchKeys[i];
    int pin = spin.toInt();
    if (!pin_ok(pin)) { continue; }

    input_begin(pin);
    // Adopt the level present at boot: a reboot must not look like the switch
    // just changed and fire its internal job at the relay. The stored state is
    // written in the same logical sense the scanner uses (active-low honoured).
    int sinv = (jstr(config["switch"][spin]["inverted"]) == "1") ? 1 : 0;
    config["switch"][spin]["state"] = ((digitalRead(pin) ^ sinv) ? "on" : "off");
  }
  // The switch is the authority for the outputs it is wired to. Apply it after
  // the app-derived relay restore above, so a reboot with the switch on leaves
  // the relay on instead of flashing it to the app's stale state.
  local_inputs_apply_all();
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
  authorization = jstr(config["authorization"]);
  homebase = jstr(config["homebase"]);
  homebaseIP = jstr(config["homebaseIP"]);
  homebasePreferredIP = jstr(config["homebasePreferredIP"]);
  if (homebasePreferredIP == "") { homebasePreferredIP = homebaseIP; }
  houseLearnJson(jstr(config["houses"]));
  // JSONVar::operator bool() is true only for a JSON boolean, not for a
  // non-empty string. The old `if (config["ssid"] && config["password"])` was
  // therefore always false, so a board that rebooted read its saved WiFi (and
  // its saved AP credentials) but never used them and came up in the default
  // provisioning AP. Compare against the empty string instead.
  String saved_ssid = jstr(config["ssid"]);
  String saved_password = jstr(config["password"]);
  if (saved_ssid != "" && saved_password != "") {
    ssid = saved_ssid;
    password = saved_password;
  }
  String saved_ap_ssid = jstr(config["ap_ssid"]);
  String saved_ap_password = jstr(config["ap_password"]);
  if (saved_ap_ssid != "" && saved_ap_password != "") {
    ap_ssid = saved_ap_ssid;
    ap_password = saved_ap_password;
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
  connexion -> setInsecure();
  if (connexion && homebaseOnline > 0) {
    {
      if (https.begin(*connexion, url)) {
        https.setTimeout(8000);
        int httpCode = https.GET();
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
    // Never print the payload: it carries the device authorization token.
    Serial.println("[watch] " + String(watchRequest.length()) + " bytes");
    if (watchRequest != "failure") {
      before_me = watchRequest;
      if (before_me != "No!") {
        // A refusal is a template answered 200 with a huge body. Parsing and
        // applying it never sets president_loaded, so it was retried every
        // ten seconds (and on core 0 starved the switch loop). Reject it here.
        if (before_me.length() > 64000 || before_me.indexOf("__specs") < 0) {
          Serial.println("[watch] answer carries no role; retrying later");
          return;
        }
        JSONVar ctp = JSON.parse(before_me);
        JSONVar ctpKeys = ctp.keys();
        bool has_components = false;
        int found_components = 0;
        for (int i = 0; i < ctpKeys.length(); i++) {
          String k = String(ctpKeys[i]);
          if (!k.startsWith("__")) { has_components = true; found_components++; }
        }
        int expected_components = (int)jint(ctp["__specs"]["component_count"]);
        if (!has_components || (expected_components > 0 && found_components < expected_components)) {
          Serial.println("[watch] incomplete role; keeping the current one");
          return;
        }
        config["button"] = JSON.parse("{}");
        config["pot"] = JSON.parse("{}");
        config["led"] = JSON.parse("{}");
        config["servo"] = JSON.parse("{}");
        config["relay"] = JSON.parse("{}");
        config["switch"] = JSON.parse("{}");
        config["outputs_json"] = local_outputs_build(ctp);
        config["internal_jobs"] = "";
        for (int i = 0; i < ctpKeys.length(); i++) {
          // The role carries numero as a string; a numeric JSONVar value would
          // read back as 0 and map every component onto pin 0.
          String numero = jstr(ctp[ctpKeys[i]]["numero"]);
          if (numero == "") { numero = String((long)jint(ctp[ctpKeys[i]]["numero"])); }
          String component = jstr(ctp[ctpKeys[i]]["component"]);
          String name = String(ctpKeys[i]);
          int pin = numero.toInt();
          if (!pin_ok(pin)) { continue; }
          if (component == "button") {
            String toggle = String((long)jint(ctp[ctpKeys[i]]["toggle"]));
            config["button"][numero]["lastPress"] = String(millis());
            config["button"][numero]["toggle"] = toggle;
            config["button"][numero]["name"] = name;
            config["button"][numero]["inverted"] = jstr(ctp[ctpKeys[i]]["inverted"]);
            {
              String bInv = jstr(ctp[ctpKeys[i]]["inverted"]);
              if (bInv != "0" && bInv != "1") { bInv = jint(ctp[ctpKeys[i]]["inverted"]) ? "1" : "0"; }
              config["button"][numero]["inverted"] = bInv;
            }
            input_begin(pin);

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
            config["switch"][numero]["inverted"] = jstr(ctp[ctpKeys[i]]["inverted"]);
            {
              String cInv = jstr(ctp[ctpKeys[i]]["inverted"]);
              if (cInv != "0" && cInv != "1") { cInv = jint(ctp[ctpKeys[i]]["inverted"]) ? "1" : "0"; }
              config["switch"][numero]["inverted"] = cInv;
            }
            input_begin(pin);
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
            pinMode(pin, OUTPUT);
          }
          else if (name == "__specs") {
            String ij = JSON.stringify(ctp[ctpKeys[i]]["internal_jobs"]);
            config["internal_jobs"] = ij;
            Serial.println("internal jobs loaded");
          }
          Serial.println(name);
        }
        president_loaded = true;
      }
      // The role was built on core 1; the config document and the local pin map
      // belong to core 0. Mark both and let loop() do the write and the reload,
      // so a blocking fetch never races the switch scanner here.
      config_dirty = true;
      config_dirty_at = millis();
      config_reload_pending = true;
      coreJobs["president"]["type"] = "led";
      coreJobs["president"]["interval"] = "50";
      coreJobs["president"]["duration"] = "1000";

    }
  }

  //Serial.println(before_me);
}
