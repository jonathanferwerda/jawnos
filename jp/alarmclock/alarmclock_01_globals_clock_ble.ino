// The house version this image was built from. scripts/fw_version.py passes it
// from the checkout's VERSION; the fallback keeps an IDE build compiling.
#ifndef JAWN_FW_VERSION
#define JAWN_FW_VERSION "unknown"
#endif

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

// The same event on the manager's clock, with the milliseconds kept. The
// setting layer orders toggle writes by this stamp: a slow HTTP relay or a
// queued appointment that names an older moment must not win over a switch the
// person already moved. Zero still means "no clock yet".
static int64_t event_ms() {
  if (!time_defined) { return 0; }
  int64_t off = offset_sane(offset) ? offset : 0;
  return now_ms() - off * 1000;
}
String event_timestamp_ms() {
  // String(double, 0) pads the integer part to width 2, so a clockless board
  // sent " 0" - a truthy string that survived every "zero means no clock" check
  // and wrote appointments at 1970 ("56y 10M ago"). Say "0" plainly, the same
  // as event_timestamp().
  if (!time_defined) { return "0"; }
  return String((double)event_ms(), 0);
}

void set_epoch_ms(int64_t ms) {
  epoch_ms = ms;
  epoch_ref = millis();
  time_defined = true;
  if (TIME_T_IS_64) {
    struct timeval tv;
    tv.tv_sec = (time_t)(ms / 1000);
    tv.tv_usec = (long)((ms % 1000) * 1000);
    settimeofday(&tv, nullptr);
  }
}

void set_epoch_seconds(int64_t seconds) {
  set_epoch_ms(seconds * 1000LL);
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
bool config_writer();
void config_init();
void run_local_jobs();
static bool pin_is_switch_driven(int pin);
void wifi_start();
bool wifi_addressed();
void call_the_president();
// The /device/ws client lives in alarmclock_05_device_ws.ino; core 1 calls it
// from loop1() below.
void device_ws_poll();

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

// ---- the relay's outbound queue ---------------------------------------------
// A watch or deck out of its homebase's range can still reach this board over
// BLE. Its message is not ours (another chip, or a house-wide volume tap), so
// it is queued here and handed to the manager by handle_jobs() on core 1. The
// queue is bounded and every entry has a bounded retry: a dead homebase must
// not grow the map or hold the BLE/loop path, which never does HTTP itself.
#define RELAY_OUT_MAX 6
static volatile int relay_out_pending = 0;
static int relay_out_seq = 0;

static void relay_out_enqueue(const String &path, const String &body, const String &kind) {
  if (homebaseIP == "" || authorization == "") {
    Serial.println("[relay] no homebase yet; dropped");
    return;
  }
  if (relay_out_pending >= RELAY_OUT_MAX) {
    Serial.println("[relay] queue full; dropped");
    return;
  }
  relay_out_pending++;
  String key = "out" + String((long)millis()) + "_" + String(relay_out_seq++);
  coreJobs[key]["type"] = "relay_post";
  coreJobs[key]["path"] = path;
  coreJobs[key]["body"] = body;
  coreJobs[key]["kind"] = kind;
  coreJobs[key]["tries"] = "0";
  coreJobs[key]["next_at"] = "0";
  Serial.println("[relay] queued " + path + " " + String((unsigned)body.length()) + " bytes");
}

// Forward one message the watch/deck meant for the house. A message that names
// no id gets one spliced into the raw text, so the manager's bounded retry of
// the same tap is a no-op instead of a second volume step. The body is never
// re-stringified: this JSONVar build writes some numeric values as empty
// tokens (the internal_jobs map is split for that reason), and "delta":5 must
// reach the manager as-is.
static void relay_out_forward(JSONVar msg, const String &json, const String &path, const String &kind) {
  String body = json;
  if (jstr(msg["id"]) == "") {
    String id = "pico" + String(rp2040.getChipID()) + "-" + String((long)millis()) + "-" + String(relay_out_seq);
    int brace = body.indexOf('{');
    if (brace >= 0) {
      body = body.substring(0, brace + 1) + "\"id\":\"" + id + "\"," + body.substring(brace + 1);
    }
  }
  relay_out_enqueue(path, body, kind);
}

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

// The same logical command reaches this board on more than one road: the
// manager's HTTP GET, its BLE `set` fallback, an app `toggle` push, and a
// scheduled job. When the first road acts and its answer is lost, the second
// applies it again and the user hears an echoed click. So keep what has been
// applied - by uuid, or by type|app|state|stamp when the road carries no uuid.
// The stamp is part of the rebuilt id on purpose: type|app|state alone would
// swallow a legitimate later repeat of the same state.
#define APPLIED_CMD_MAX 12
// The board's clock is set from /watch/time in milliseconds, and a command
// minted before a physical switch must lose to it. This grace only covers the
// sync's own one-way delay and a browser clock that is a little off; it must
// stay well under the "a moment later" a person means when they flip a switch.
#define CMD_STALE_GRACE_MS 250
struct applied_cmd_t {
  String id;      // uuid when the road carries one
  String type;    // relay / led / servo / set / toggle
  String app;
  int64_t ms;     // the command's epoch-ms timestamp, 0 when absent
};
static applied_cmd_t applied_cmds[APPLIED_CMD_MAX];
static int applied_cmd_next = 0;
static int64_t out_cmd_ms[30];   // last command time applied to each pin

static String command_id(String uuid, String type, String app, String state, int64_t ms) {
  if (uuid != "") { return uuid; }
  if (app == "" || ms == 0) { return String(""); }
  return type + "|" + app + "|" + state + "|" + String((double)ms, 0);
}

static bool command_seen(String id) {
  if (id == "") { return false; }
  for (int i = 0; i < APPLIED_CMD_MAX; i++) {
    if (applied_cmds[i].id == id) { return true; }
  }
  return false;
}

static void command_remember(String id, String type, String app, int64_t ms) {
  if (id == "") { return; }
  applied_cmd_t &c = applied_cmds[applied_cmd_next];
  c.id = id;
  c.type = type;
  c.app = app;
  c.ms = ms;
  applied_cmd_next = (applied_cmd_next + 1) % APPLIED_CMD_MAX;
}

// A command stamped before the one already applied to this pin is a delayed
// copy from a slower road, not a new intent.
static bool command_is_stale(int pin, int64_t ms) {
  if (!pin_ok(pin) || ms == 0) { return false; }
  return out_cmd_ms[pin] != 0 && ms + CMD_STALE_GRACE_MS < out_cmd_ms[pin];
}

static void command_mark_pin(int pin, int64_t ms) {
  if (pin_ok(pin) && ms > out_cmd_ms[pin]) { out_cmd_ms[pin] = ms; }
}

static String output_state(int pin, String comp) {
  if (comp == "relay") { return jstr(config["relay"][String(pin)]); }
  if (comp == "led") { return jstr(config["led"][String(pin)]); }
  if (comp == "servo") { return jstr(config["servo"][String(pin)]); }
  return String("");
}

// True when the command must not move the pin. An ack still has to report the
// real state, so `state` is replaced with what the pin holds.
static bool command_redundant(String id, int pin, String comp, String &state, int64_t ms) {
  if (command_seen(id) || command_is_stale(pin, ms)) {
    String cur = output_state(pin, comp);
    if (cur != "") { state = cur; }
    return true;
  }
  if (output_state(pin, comp) == state) { return true; }
  return false;
}

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

static void ble_apply_app_state(String app, String state, String id = "", int64_t ms = 0) {
  if (app == "") { return; }
  for (int i = 0; i < local_out_count; i++) {
    local_out_t &o = local_outs[i];
    if (o.app != app) { continue; }
    // A switch on this board owns its output; the app push is for boards that
    // do not have the switch.
    if (pin_is_switch_driven(o.pin)) { continue; }
    String phys = state;
    if (o.inv == 1) { phys = (phys == "on") ? "off" : "on"; }
    if (command_redundant(id, o.pin, o.comp, phys, ms)) { continue; }
    if (o.comp == "relay") { relay_toggle(o.pin, phys, true, 3); }
    else if (o.comp == "led") { led_toggle(o.pin, phys); }
    command_mark_pin(o.pin, ms);
  }
  command_remember(id, "toggle", app, ms);
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
  String uuid = jstr(data["uuid"]);
  String app = jstr(data["app"]);
  int64_t ms = jint64(data["timestamp"]);
  String cid = command_id(uuid, "set", app, state, ms);
  if (!command_redundant(cid, pin, comp, state, ms)) {
    if (comp == "relay") { state = relay_toggle(pin, state); }
    else if (comp == "led") { state = led_toggle(pin, state); }
    else if (comp == "servo") { state = servo_toggle(pin, state); }
  }
  command_mark_pin(pin, ms);
  command_remember(cid, "set", app, ms);
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
  // The persisted pair is what the next boot joins with; say so when the
  // filesystem refused it instead of pretending the update stuck.
  if (!config_writer()) { Serial.println("[cfg] wifi apply not saved"); }
  // Only a complete pair is a join: an SSID on its own would drop the current
  // network for a password that is not there.
  if (s != "" && p != "") {
    WiFi.disconnect();
    delay(100);
    wifi_start();
  }
}

