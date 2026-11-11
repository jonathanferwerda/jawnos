// The house version this image was built from. scripts/fw_version.py passes it
// from the checkout's VERSION; the fallback keeps an IDE build compiling.
#ifndef JAWN_FW_VERSION
#define JAWN_FW_VERSION "unknown"
#endif

// Bulk files (recordings, voice clips, chimes, the speaker tone) go to the SD
// card when one is mounted and to FFat otherwise. Config and the boot report
// always stay on FFat: they must be readable before the SD is mounted.
static bool sdReady = false;
static fs::FS *store = &FFat;
// FatFS and SDFS expose freeBytes() themselves, not through the FS base class.
static uint32_t store_free_bytes() {
  return sdReady ? (uint32_t)(SD.totalBytes() - SD.usedBytes()) : FFat.freeBytes();
}

// The file helpers at the bottom of this sketch; PlatformIO's .ino preprocessor
// does not inject prototypes for them, the Arduino IDE does.
void writeFile(fs::FS &fs, const char * path, const char * message);
String readFile(fs::FS &fs, const char * path);
void appendFile(fs::FS &fs, const char * path, const char * message);
void createDir(fs::FS &fs, const char * path);
void listDir(fs::FS &fs, const char * dirname, uint8_t levels);
void deleteFile(fs::FS &fs, const char * path);
void https_download(fs::FS &fs, String url, String filename);
bool sd_tester();
// the deck's serial logger (defined near the bottom); the BLE callbacks run
// before its definition
static void deckLog(const char *fmt, ...);
// defined next to setupMicrophoneI2S() at the bottom, used by the boot rate
// check in setup()
extern i2s_chan_handle_t mic_rx_handle;
// prints a file as base64 over the usb serial, for pulling a recording off the
// deck without wifi (see the "JAWNDUMP" line handling in loop())
static void serialDumpFile(String name);
// starts a recording from the host ("JAWNREC <seconds>") and writes one codec
// register ("JAWNREG <reg> <value>", hex)
static void serialRecordStart(uint32_t seconds);
static void serialRegWrite(String args);
static void serialSlotSet(String args);

static const uint16_t screenWidth  = 320;
static const uint16_t screenHeight = 240;
#define DEFAULT_COLOR               (lv_color_make(252, 218, 72))
#define MIC_I2S_SAMPLE_RATE         16000
#define MIC_I2S_BITS_PER_SAMPLE     16
#define MIC_I2S_PORT                I2S_NUM_1
#define SPK_I2S_PORT                I2S_NUM_0
// the ES7210's four mics arrive as one TDM frame of four 16 bit slots
#define MIC_TDM_SLOTS               4
#define MIC_TDM_FRAMES              512      // frames per read
#define MIC_TDM_BUFFER_BYTES        (MIC_TDM_FRAMES * MIC_TDM_SLOTS * 2)
#define LVGL_BUFFER_SIZE            (TFT_HEIGHT * 40 * sizeof(lv_color_t))


WebServer server(3000);
long offset;
static bool webserver_enabled;// = true;
static bool wifi_ap_enabled = false;
static bool wifi_enabled = false;
// set by the {type:'wifi'} BLE message: the panel hands a device that has never
// joined a network its credentials, and loop() joins (wifi_server blocks)
static volatile bool wifi_join_requested = false;
// set by the /now_me web route: applying Now Me fetches over HTTPS and drives
// LVGL, which must not run inside the web handler (it nests the TLS client in the
// HTTP server's stack and reboots the deck). loop() does the work instead.
static volatile bool now_me_requested = false;
// Voice activation (the panel's voice_trigger setting): loop() keeps a listener
// armed for anything voice_models_has() knows, and stands aside while a manual
// record or playback owns the microphone. The listener itself lives with the
// voice code further down; these are read by loop(), configRestore() and the
// /now_me route.
static bool voiceCaptureEnabled = false;
static String voice_trigger = "off";
static String voice_floor = "auto";
// the room's own frame RMS, learned while nothing is captured: what the 'auto'
// end-of-speech floor stands on
static uint32_t voice_ambient_rms = 0;
// the run request (cleared to stop the listener) and the task's liveness, which
// loop() keys the start on so a stopping listener and a starting one never
// overlap on the one microphone
static volatile bool voiceListening = false;
static volatile bool voiceTaskAlive = false;
// True from the moment speech commits to a clip until that clip has been shipped
// (or dropped). loop() holds the screen awake on it - a doze part-way through a
// spoken statement changes the panel and writes the config, and both stall the
// microphone - and draws the orange ring the watch shows while it is listening.
static volatile bool voiceRecording = false;
// True from the first frame the model reads (the wake phrase, in wake mode) until
// the utterance closes. It is what lights the panel and draws the ring: the
// capture itself commits a few frames later, and a person who just said the wake
// word should see an answer at once - especially with the screen asleep.
static volatile bool voiceHeard = false;
// When the listener's own acknowledgment beep is playing (a millis deadline). The
// listener reads the microphone through it: the beep is on the speaker bus, so it
// is not the manual-record/playback case that guard exists for.
static volatile uint32_t voiceAckUntil = 0;
// True from a shipped clip until the Guide's answer arrives: loop() holds the
// screen awake on it - a prompt is not answered in a few seconds, and the person
// is waiting on the words - then restarts the idle timer. A reply that never
// comes gives up after a long wait (see loop()).
static volatile bool voiceAwaitingReply = false;
static volatile uint32_t voiceAwaitingSince = 0;
// The Guide's answer, shown on the deck's own screen: the words arrive as a
// {type:'say'} message, are drawn on the top layer, and are faded by loop() after
// SAY_TEXT_MS. Declared up here because loop() reads them; the label is built in
// say_label_show with the rest of the voice code.
#define SAY_TEXT_MS 30000
static lv_obj_t *say_label;
static uint32_t say_shown_at = 0;
// WiFi audio reply: the server sends {type:'say_audio_ready'} with a one-shot
// URL; a task downloads it and loop() plays the WAV.
static volatile bool sayFetchPending = false;
static volatile bool sayFetchRunning = false;
static String* sayFetchReq = nullptr;
// One persistent worker owns the HTTPS fetch: the deck's fragmented internal
// heap cannot reliably start a fresh 12 KB task per reply, so the worker is
// created once at boot and waits for a URL here.
static QueueHandle_t sayFetchQueue = nullptr;
static bool sayFetchWorkerOk = false;
static void sayFetchWorker(void *pv);
static volatile bool sayWifiReady = false;
static volatile bool sayWifiPlaying = false;
// a manual recording is in flight (declared here because loop() reads it; the
// recording code at the bottom owns it)
static volatile bool isRecording = false;
// Bluetooth (Nordic UART Service), ported from the watch. A saved config that
// says "on" only sets btStartPending: bringing the stack up inside setup()
// panicked the watch, and loop() starts it once the boot has settled.
static bool bt_enabled = false;
static bool btStartPending = false;
// The radio's real state. bt_enabled is the *preference* (what configSave
// writes and the net room button shows); it can be true while a start is still
// pending, so the start/stop guards must not key off it or the radio never
// comes up.
static bool ble_radio_up = false;
String tauth_remote_enabled = "off";
#define DEFAULT_SCREEN_TIMEOUT                  20*1000

// ---- bluetooth: the watch's Nordic UART Service --------------------------
#define SERVICE_UUID           "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define CHARACTERISTIC_UUID_RX "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define CHARACTERISTIC_UUID_TX "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
BLEServer *pServer = NULL;
BLECharacteristic *pTxCharacteristic = NULL;
bool deviceConnected = false;
QueueHandle_t bleIncomingQueue = NULL;
// when the bridge last showed up; loop() uses it to ask for missed state
volatile uint32_t ble_connected_at = 0;
// the central the bridge attached: its address, and its name once the daemon says
// hello. The net room's BT line (ip_writer) shows one or the other.
static char ble_peer_addr[18] = "";
static char ble_peer_name[32] = "";

// The bridge daemon frames a payload that does not fit one write as
// "<i>/<n>:" + chunk (i is 0-based). A write with no such prefix is a whole
// message -- an older daemon, or a manual write -- and passes straight through.
static bool ble_frame_split(const String &in, int &index, int &total, String &body) {
  int slash = in.indexOf('/');
  if (slash <= 0) {
    return false;
  }
  int colon = in.indexOf(':', slash);
  if (colon <= slash + 1) {
    return false;
  }
  for (int i = 0; i < slash; i++) {
    if (!isDigit(in[i])) return false;
  }
  for (int i = slash + 1; i < colon; i++) {
    if (!isDigit(in[i])) return false;
  }
  index = in.substring(0, slash).toInt();
  total = in.substring(slash + 1, colon).toInt();
  if (total <= 0 || index < 0 || index >= total) {
    return false;
  }
  body = in.substring(colon + 1);
  return true;
}

// reassembly state for a framed daemon write; the BLE task owns it
static String ble_rx_buffer;
static int ble_rx_next = 0;
static uint32_t ble_rx_last = 0;

static void queue_ble_message(String &message) {
  if (bleIncomingQueue == NULL) {
    return;
  }
  // the buffer is handed over, not copied: the room push is ~25 KB and three
  // live strings of it is what the watch could not afford (2026-10-09). The
  // String is left empty.
  String* msgPtr = new String();
  *msgPtr = std::move(message);
  if (xQueueSend(bleIncomingQueue, &msgPtr, 0) != pdPASS) {
    delete msgPtr;
    deckLog("[bt] queue full, message dropped");
  }
}

// A send needs the radio up AND the central subscribed to the TX characteristic:
// notify() into an unsubscribed link lands nowhere, and a board that talks before
// the phone is listening reads as dead. The descriptor write sets it (MyTxCallbacks).
static volatile bool ble_notify_ready = false;
static inline bool ble_link_ready() {
  return ble_radio_up && deviceConnected && ble_notify_ready && pTxCharacteristic != nullptr;
}

// Send a payload over the Nordic UART TX characteristic as one or more framed
// notifies. A central that negotiates a small MTU (Android leaves it at the BLE
// floor, 23) carries only MTU-3 = 20 bytes per notification, and a longer value
// set on the characteristic is silently truncated there -- which is exactly what
// lost a tap (a ~450 byte envelope) at the first hop. Split it into "<i>/<n>:"
// parts the bridge reassembles. With a big MTU (the desktop's 512) a small
// message stays a single part.
static void ble_notify_payload(const String &payload, uint16_t pace_ms = 8) {
  if (!ble_link_ready()) {
    return;
  }
  uint16_t mtu = 23;
  if (pServer) {
    uint16_t m = pServer->getPeerMTU(pServer->getConnId());
    if (m >= 23) { mtu = m; }
  }
  int frame = (int)mtu - 3;      // the notify payload limit
  int budget = frame - 8;        // room for the "<i>/<n>:" prefix
  if (budget < 1) { budget = 1; }
  int len = (int)payload.length();
  int total = (len + budget - 1) / budget;
  if (total < 1) { total = 1; }
  for (int i = 0; i < total; i++) {
    int from = i * budget;
    int to = from + budget;
    if (to > len) { to = len; }
    String part = String(i) + "/" + String(total) + ":";
    part += payload.substring(from, to);
    pTxCharacteristic->setValue((uint8_t *)part.c_str(), part.length());
    pTxCharacteristic->notify();
    delay(pace_ms);            // pace the parts; a flat burst outruns the link
  }
}

// small outbound message over the Nordic UART TX characteristic; used for the
// bridge requests (state_request / room_request) from either core
static void ble_send(JSONVar message) {
  if (!ble_link_ready()) {
    return;
  }
  ble_notify_payload(JSON.stringify(message));
}

static void ble_peer_grab(uint8_t *b) {
  snprintf(ble_peer_addr, sizeof(ble_peer_addr), "%02x:%02x:%02x:%02x:%02x:%02x",
           b[0], b[1], b[2], b[3], b[4], b[5]);
  ble_peer_name[0] = '\0';     // until the daemon says hello
}

class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    ble_notify_ready = false;   // until the central subscribes to the TX characteristic
    ble_connected_at = millis();
    // the address comes straight from the host: this callback always runs, where
    // the address-carrying overload of the pair sits behind a config macro the
    // sketch's compile unit does not reliably see
    struct ble_gap_conn_desc conn_desc;
    if (ble_gap_conn_find((uint16_t)pServer->getConnId(), &conn_desc) == 0) {
      uint8_t *b = conn_desc.peer_id_addr.val;
      bool zero = true;
      for (int i = 0; i < 6; i++) {
        if (b[i] != 0) { zero = false; break; }
      }
      if (zero) {
        b = conn_desc.peer_ota_addr.val;   // no identity without bonding
      }
      ble_peer_grab(b);
    }
    deckLog("[bt] central attached: %s", ble_peer_addr);
  };
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    ble_notify_ready = false;
    ble_connected_at = 0;
    ble_peer_addr[0] = '\0';
    ble_peer_name[0] = '\0';
    // Bluedroid stops advertising when a central attaches and never resumes
    // it on its own: without this the phone cannot come back after a drop
    // until the deck is rebooted or the radio toggled
    pServer->startAdvertising();
  }
};
static MyServerCallbacks ble_server_callbacks;

// The phone subscribes by writing the notification descriptor; until it does,
// notify() has nowhere to land. Bluedroid reports that write here.
class MyTxCallbacks: public BLECharacteristicCallbacks {
  void onSubscribe(BLECharacteristic *pCharacteristic, ble_gap_conn_desc *desc, uint16_t subValue) {
    ble_notify_ready = (subValue != 0);
    deckLog("[bt] notify %s", subValue ? "on" : "off");
  }
};
static MyTxCallbacks ble_tx_callbacks;

// A large bridge payload (the ~25 KB room push) arrives zlib-compressed: a 0x1e
// byte marks it, then the zlib stream. Inflate it back to the JSON the rest of
// the path expects; the inflater is the ESP32 ROM's miniz, nothing vendored.
#define BLE_ZLIB_MARK 0x1e
static String ble_inflate_if_zlib(const String &in) {
  if (in.length() < 2 || (uint8_t)in[0] != BLE_ZLIB_MARK) { return in; }
  static const size_t cap = 48 * 1024;   // a room push inflates to ~25 KB
  uint8_t *out = (uint8_t *)ps_malloc(cap);   // PSRAM: keep the 48 KB scratch out of internal RAM
  if (!out) { out = (uint8_t *)malloc(cap); }
  if (!out) { deckLog("[bt] inflate: no room"); return in; }
  // tinfl's state is ~11 KB; keep it in PSRAM so the inflate costs no stack
  tinfl_decompressor *dec = (tinfl_decompressor *)ps_malloc(sizeof(tinfl_decompressor));
  if (!dec) { free(out); deckLog("[bt] inflate: no state"); return in; }
  tinfl_init(dec);
  size_t in_bytes = in.length() - 1;
  size_t out_bytes = cap;
  tinfl_status st = tinfl_decompress(dec, (const mz_uint8 *)in.c_str() + 1, &in_bytes,
                                     out, out, &out_bytes,
                                     TINFL_FLAG_PARSE_ZLIB_HEADER |
                                     TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);
  free(dec);
  if (st != TINFL_STATUS_DONE) {
    deckLog("[bt] inflate failed (%d)", (int)st);
    free(out);
    return in;   // hand the raw bytes on; the parse fails loudly, not a crash
  }
  String s((const char *)out, (unsigned int)out_bytes);
  free(out);
  return s;
}

// One BLE write as it arrives: a whole message, or one chunk of a framed one.
// Runs on the BLE stack's own task, whose stack is small -- nothing here may
// log (the watch measured 1.9 KB of headroom at this point, 2026-10-09, and a
// vfprintf wants more); the reporting lives where the pushed message lands.
static void ble_frame_ingest(const String &rawInput) {
  if (rawInput.length() == 0) {
    return;
  }
  int index = 0, total = 0;
  String body;
  if (ble_frame_split(rawInput, index, total, body)) {
    // a fresh message, a gap, or a long pause restarts the buffer
    if (index == 0 || ble_rx_next != index || millis() - ble_rx_last > 5000) {
      ble_rx_buffer = "";
      // one allocation for the whole message: growing it a chunk at a time
      // fragmented the heap the payload then needed in one block
      ble_rx_buffer.reserve((unsigned int)body.length() * (unsigned int)total + 64);
      ble_rx_next = 0;
    }
    ble_rx_buffer += body;
    ble_rx_last = millis();
    ble_rx_next = index + 1;
    if (ble_rx_buffer.length() > 65536) {
      ble_rx_buffer = "";
      ble_rx_next = 0;
      return;
    }
    if (ble_rx_next >= total) {
      queue_ble_message(ble_rx_buffer);
      ble_rx_buffer = "";
      ble_rx_next = 0;
    }
  }
  else {
    String whole = rawInput;   // an unframed message (a manual write, an older daemon)
    queue_ble_message(whole);
  }
}

class MyCallbacks: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *pCharacteristic) {
    // A chunk can be binary: a compressed payload arrives as zlib bytes, and
    // c_str() stops at the first NUL - which truncated every compressed part and
    // made the inflate fail on a mangled stream (jw.ino's note; the deck kept the
    // old one-arg form, so the room/now_me push never inflated). Copy the length.
    auto value = pCharacteristic->getValue();
    String rawInput(value.c_str(), (unsigned int)value.length());
    ble_frame_ingest(rawInput);
  }
};
// Which TDM slot the microphone shows up in. The startup dump prints all four,
// and "JAWNSLOT <n>" can change it over the usb serial. On this board the
// microphone is on MIC1 (slot 0, with a mirror image on MIC3/slot 1).
static int mic_mono_slot = 0;
// 1 = mono from mic_mono_slot, 4 = all four TDM slots interleaved into the file
// ("JAWNCH 4"), for finding which channel a board's microphone is wired to
static int mic_channels = 1;
uint8_t currentBrightness = 30;
uint8_t lastBrightness = 30;
int tempBrightness;
static bool screenAsleep = false;
String wifi_update;
JSONVar wigi;

#define IP_FORWARD 1
String roller_ball_direction;
int rb_count = 0;
int touching = 0;
String name = "LilyGo T-Deck Pro";
String ssid = name;
String base_ssid = ssid;
String password = "president";
String base_password = password;
String ap_ssid = ssid;
String base_ap_ssid = ap_ssid;
String ap_password = password;
String base_ap_password = ap_password;
int tauth_watch = 0;
int tauth_count = 0;
int b1_toggle, b2_toggle, b3_toggle, b4_toggle, b5_toggle, b6_toggle, b7_toggle, b8_toggle = 0;
// Room buttons by their house-wide button number, for press feedback. A failed
// relay flashes red, an every-machine command that reached every machine
// flashes green, both for two seconds; jawn_loop() paints them.
#define ROOM_BUTTON_SLOTS 64
static lv_obj_t *room_button_obj[ROOM_BUTTON_SLOTS] = {0};
static volatile int button_face_key = 0;
static volatile bool button_face_dirty = false;
static volatile int button_flash_key = 0;
static volatile uint32_t button_flash_colour = 0;
static volatile uint32_t button_flash_until = 0;
static void button_feedback_tick();
static void button_flash_from_result(int key, JSONVar result);
int last_x, last_y = 0;
int room = 1;
int room_count = 1;
int room_max = 8;
int auth_watch = 0;
int auth_count = 0;
int ws_mouse_to_send = 0;
static RTC_DATA_ATTR int fontSize = 4;
String fontSelect = "";
JSONVar authorization_json;
String authorization;
bool ota_refused = false;
String homebase;
String homebaseIP;
String thomebaseIP;
// The address Now Me handed this deck is the preferred machine; the active
// addresses below may move to another House machine when it stops answering.
static String homebase_preferredIP;
static String thomebase_preferredIP;
static String twshomebase_preferredIP;
// House machines this deck can fail over to (Now Me carries the LAN list;
// mDNS refreshes it). Kept separate from the saved Now Me profiles: the same
// authorization pair is valid on any machine that has synced the record.
#define HOUSE_MAX 8
struct HouseNode { String host; int arm; int coms; int bestow; };
static HouseNode house_nodes[HOUSE_MAX];
static int house_node_count = 0;
static volatile int house_switch_req = -1;
static uint32_t house_last_scan = 0;
// The worker is created only while it has work: the preferred machine answering
// normally means its stack is better left to the UI and voice heap.
static TaskHandle_t house_task_handle = NULL;
static void house_maintain();
static void house_task(void *pvParameters);
static void house_learn_json(const String &js);
static void house_add(const String &host, int arm, int coms, int bestow);
static void house_remember_preferred();
// A homebase that is unreachable - or a link that is not up yet, which is exactly
// what a now_me push arrives into right after the deck joins - turns every
// request into a TLS connect, and hammering it asserts inside lwip's thread/mbox
// setup and reboots the deck (jw.ino documents the same). Back off after a
// failure so a press falls back instead of retrying at once.
static uint32_t homebase_down_until = 0;
String twshomebaseIP;
String homebaseIPArray[10];
String before_me = "";
bool buttoned_before = false;
String computer_name = "";
String chat_room;
String returner;
String community_room;
String club_room;
String team_room;
String project_room;
String account_room;
String person_room;
String contact_room;
bool loraChatBroadcaster = true;
bool loraChatReceiver = true;
String mouse_move_relative = "off";
// Sleep mode (Set room -> System -> Sleep): once the panel's idle timeout has
// passed, stop the radios and the CPU instead of only darkening the screen. It
// wakes on a touch, a key or a move of the trackball. The preference is saved
// with the rest of the config.
static bool lightSleep = false;
// Input caught by the sleep poll and handed back to LVGL's own readers: the
// physical key/tap is usually over by the time the screen is back up.
static char deck_pending_key = 0;
static bool deck_wake_touch_pending = false;
static int16_t deck_wake_touch_x = 0;
static int16_t deck_wake_touch_y = 0;
static bool wifi_restore_pending = false;
// Flag used for acceleration interrupt status
static bool sportsIrq = false;
// Flag used to indicate whether recording is enabled
static bool recordFlag = false;
// Flag used for PMU interrupt trigger status
static bool pmuIrq = false;

char *bufgwIP = new char[40]();
char *bufIP = new char[40]();
char *bufapIP = new char[40]();
char *bufapgwIP = new char[40]();
IPAddress apIP;
String jw_room = "gate";
String troom = "head";
uint32_t buttonMillis = millis();
uint32_t lastMillis;
uint32_t wsLastMillis;
uint32_t touchLastMillis;
char bufsec[64];
char bufdate[64];
char buftime[64];
static RTC_DATA_ATTR int brightnessLevel = 7;
int vibrateLevel = 50;
int volumeLevel = 5;
Audio audio;
void lowPowerEnergyHandler();

#define TOUCH_MODULES_GT911
#include "TouchLib.h"
#include "utilities.h"

// Battery: the T-Deck puts the pack voltage on BOARD_BAT_ADC through a 1:1
// divider. Seven samples, median, doubled - the read LilyGoLib's deck support
// uses - then the same curve to percent, so the deck's number agrees with the
// library's. Cached for ten seconds: the clock redraws every second.
static int deck_battery_percent_cached = -1;
static uint32_t deck_battery_read_at = 0;

static float deck_battery_voltage() {
  const int n = 7;
  uint32_t s[n];
  for (int i = 0; i < n; i++) {
    s[i] = analogReadMilliVolts(BOARD_BAT_ADC);
    delayMicroseconds(200);
  }
  for (int i = 1; i < n; i++) {
    uint32_t v = s[i];
    int j = i - 1;
    while (j >= 0 && s[j] > v) { s[j + 1] = s[j]; j--; }
    s[j + 1] = v;
  }
  return (float)s[n / 2] * 2.0f;
}

static int deck_battery_percent() {
  uint32_t now = millis();
  if (deck_battery_percent_cached >= 0 && now - deck_battery_read_at < 10000) {
    return deck_battery_percent_cached;
  }
  deck_battery_read_at = now;
  static const int mv[] = {3300, 3500, 3600, 3700, 3750, 3800, 3850, 3900, 3950, 4000, 4100, 4200};
  static const int pc[] = {0, 5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100};
  float v = deck_battery_voltage();
  int pct = 100;
  if (v <= mv[0]) {
    pct = 0;
  }
  else {
    for (int i = 1; i < 12; i++) {
      if (v <= mv[i]) {
        pct = pc[i - 1] + (int)((v - mv[i - 1]) * (pc[i] - pc[i - 1]) / (mv[i] - mv[i - 1]));
        break;
      }
    }
  }
  deck_battery_percent_cached = pct;
  return pct;
}


#if TFT_DC !=  BOARD_TFT_DC || TFT_CS !=  BOARD_TFT_CS || TFT_MOSI !=  BOARD_SPI_MOSI || TFT_SCLK !=  BOARD_SPI_SCK
#error "Not using the already configured T-Deck file, please remove <Arduino/libraries/TFT_eSPI> and replace with <lib/TFT_eSPI>, please do not click the upgrade library button when opening sketches in ArduinoIDE versions 2.0 and above, otherwise the original configuration file will be replaced !!!"
#error "Not using the already configured T-Deck file, please remove <Arduino/libraries/TFT_eSPI> and replace with <lib/TFT_eSPI>, please do not click the upgrade library button when opening sketches in ArduinoIDE versions 2.0 and above, otherwise the original configuration file will be replaced !!!"
#error "Not using the already configured T-Deck file, please remove <Arduino/libraries/TFT_eSPI> and replace with <lib/TFT_eSPI>, please do not click the upgrade library button when opening sketches in ArduinoIDE versions 2.0 and above, otherwise the original configuration file will be replaced !!!"
#endif

TouchLib *touch = NULL;

TFT_eSPI tft;
ESP32Time rtc;
using namespace websockets;
// The deck dials the manager by LAN IP. The house-CA peer leaf the listener
// presents carries that address in its SAN, so ordinary verification succeeds;
// this client pins the house CA. The Now Me authorization token is still the
// secret - TLS protects it (and the injected keystrokes) in flight.
class HouseCaDeckTcpClient : public websockets::network::SecuredEsp32TcpClient {
 public:
  HouseCaDeckTcpClient() {
    client.setCACert(HOUSE_CA_PEM);
    // A dead House machine must not hold the UI: the default TLS handshake
    // timeout is tens of seconds and tauth_connect() runs on the loop. The TCP
    // connect has its own 30 s default, which is what made a boot with an
    // absent homebase take half a minute; cap both.
    client.setHandshakeTimeout(3);
    client.setConnectionTimeout(2000);
  }
};
WebsocketsClient wsclient(std::make_shared<HouseCaDeckTcpClient>());
WiFiClientSecure *connexion = new WiFiClientSecure;
HTTPClient https;
bool ws_connected = 0;
// configRestore() asks for the control socket; loop() makes the dial once the
// screen is up, so a slow or dead homebase never delays the boot.
static bool tauth_connect_pending = false;
void wsMessageCallback(WebsocketsMessage message) {
  //    Serial.print("Got Message: ");
  //    Serial.println(message.data());
}
void wsEventCallback(WebsocketsEvent event, String data) {
  if (event == WebsocketsEvent::ConnectionOpened) {
    ws_connected = 1;
    deckLog("%s", "[auth] wss open");
  }
  else if (event == WebsocketsEvent::ConnectionClosed) {
    ws_connected = 0;
    deckLog("%s", "[auth] wss closed");
  }
}
void wsClose(WebsocketsMessage closer) {
  //    tauth_cancel();


}
void setupLvgl();
// The keypad only gets registered when the keyboard answers; that can happen
// after setup() has moved on, so loop() retries this.
static void registerKeyboard();
// bluetooth: defined next to net_room() further down, but loop() and
// configRestore() call them
void start_ble_transfer();
void stop_ble_transfer();
// Sleep mode: defined with the Set room's helpers; loop() runs it after the
// panel has gone dark.
static void deck_low_power_sleep();
// voice notes: record to flash with the ES7210 mic array, play it back through
// the speaker (buttons live next to the text box in the chat and pen rooms)
static void micRecordToggle(lv_event_t *e);
static void recordingPlay(lv_event_t *e);
// voice activation: defined with the voice code at the bottom, called by loop(),
// configRestore() and the /now_me route
static void voice_trigger_apply();
static void deckVoiceListenStart();
static void voice_border_show(bool on);
static void say_label_show(const String &t);
bool es7210Begin();
static void speakerSelfTest();
static void pruneRecordings(int keep);
