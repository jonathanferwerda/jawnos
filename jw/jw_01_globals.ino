
// The file helpers at the bottom of this sketch; PlatformIO's .ino preprocessor
// does not inject prototypes for them, the Arduino IDE does.
void writeFile(fs::FS &fs, const char * path, const char * message);
String readFile(fs::FS &fs, const char * path);
void appendFile(fs::FS &fs, const char * path, const char * message);
void createDir(fs::FS &fs, const char * path);
void deleteFile(fs::FS &fs, const char * path);
void listDir(fs::FS &fs, const char * dirname, uint8_t levels);
void listJsonDir(fs::FS &fs, const char * dirname, JSONVar &list);
void saveFileToFolder(const char * folderPath, const char * fileName);
String getContentType(String filename);
String https_request_raw(String url, String method, String payloadData);
void apply_president_payload();
static void clock_apply_to_face();

// The current LilyGoLib keeps its board object in a global reference called
// `instance` (LilyGoWatch2022 for the T-Watch S3). The rest of this sketch was
// written against the old fork, which called it `watch`.
#define watch instance

ESP32Time rtc;

int screenRotation = 0;
// Flag used to indicate whether to use light sleep, currently unavailable
static bool lightSleep = false;
double wakeup_time = 0;
// Flag used for acceleration interrupt status
static bool sportsIrq = false;
// Wrist-raise wake. The BMA423's interrupt line wakes the chip when it notices
// movement even with the screen off; the doze loop then feeds each pose to the
// gesture check below, and only a look brings the screen back -- fidgeting
// does not.
static bool tiltWake = true;
// Streams raw accelerometer samples over USB for tuning ("tiltdbg on").
static bool tiltDbg = false;
// Raw pose logging to the flash filesystem: the USB console cannot be used for
// the worn gesture (light sleep refuses the cable), so a capture done off-cable
// is written to /tiltlog.txt and read back later ("tiltlog on", "tiltlog
// dump").
static bool tiltLog = false;
static char tilt_log_buf[1024];
static int tilt_log_len = 0;
static uint32_t tilt_log_flushed_at = 0;
static uint32_t tilt_log_bytes = 0;
#define TILT_LOG_PATH "/tiltlog.txt"
#define TILT_LOG_MAX  300000UL
// A wrist raise earns a glance, not the full screen timeout; a touch inside it
// hands the wake back to the usual timeout (see the wake block in loop()).
#define TILT_WAKE_LOOK_MS 5000
static bool tilt_wake_short = false;
// A tilt raise lights the screen for a glance at most TILT_WAKE_LOOK_MS; while
// the glance is up the arm is watched so it can end early, and a touch hands the
// wake back to the usual timeout (see wrist_look_monitor).
static bool wrist_look_watch = false;
// Flag used to indicate whether recording is enabled
static bool recordFlag = false;
// Flag used for PMU interrupt trigger status
static bool pmuIrq = false;
// Set when the crown is held down: the user wants the watch to sleep now
static bool sleepRequested = false;
// True while doze_until_crown() waits, so a crown click can tell "wake the screen
// back up" (the doze) from "go to sleep" (the face is already on)
static volatile bool dozing = false;
static bool webserver_enabled;// = true;
static bool wifi_ap_enabled = false;
static bool wifi_enabled = false;
// Set when the panel hands us network credentials over BLE: the watch cannot
// fetch them from a LAN it is not yet on, so loop() does the (blocking) join.
static volatile bool wifi_join_requested = false;
static bool bt_enabled = false;
// Voice capture: loop() arms a VAD listener while this is on (Configure >
// System). Declared up here because loop() reads it; the listener itself lives
// with the rest of the voice code further down.
static bool voiceCaptureEnabled = false;
// Serial 'voicedbg on': print the listener's mic level and model peak once a
// second, so a quiet or wedged voice path is visible over USB without speaking.
static bool voiceDbg = false;
// The voice mode the panel set (operator_door.__specs.voice_trigger): 'off',
// 'vad', or a wake word we have a model for. It rides in a Now Me;
// voice_trigger_apply() arms the listener for anything voice_models_has() knows.
static String voice_trigger = "off";
// The end-of-speech floor the panel set (operator_door.__specs.voice_floor):
// 'auto' - the default - follows the room's own level, a number pins it by hand.
// A watch carries a steady tone of its own (the board, not the room), and it
// sits well above any fixed number that reads as silence, so with a pinned
// floor the wake capture never saw the room go quiet and every command ran to
// the 6 s cap. 'vfloor auto' / 'vfloor 1800' sets it from the console.
static String voice_floor = "auto";
// The room's own frame RMS, learned while nothing is being captured: what the
// 'auto' floor stands on. It falls to a quieter frame at once and climbs only a
// little per frame, so a voice can never drag the room estimate up with it.
static uint32_t voice_ambient_rms = 0;
static volatile bool voiceListening = false;
static volatile bool voiceOneShot = false;   // a serial "voice" capture, not the setting
// True while a command is being recorded: loop() holds the screen timeout off
// then, so a spoken command is not cut short by the watch dozing (the tilt-wake
// delay the user asked for).
static volatile bool voiceRecording = false;
// True from the moment a clip starts shipping until the server acks it: the send
// is hundreds of paced notifications, and the screen's short look would doze (and
// light-sleep, which drops the radio) part-way through - exactly how a spoken
// command went missing while a glance's worth of frames came through. loop() holds
// the screen awake while either flag is set.
static volatile bool voiceShipping = false;
// True from the end of a capture until the Guide's answer has been spoken. loop()
// holds the screen on through the wait and the answer - a prompt is not answered
// in a few seconds - and then restarts the idle timer. A reply that never comes
// gives up after a long wait (see loop()).
static volatile bool voiceAwaitingReply = false;
static volatile uint32_t voiceAwaitingSince = 0;
// Set on the first frame of speech (the wake phrase) and held until that
// utterance is over: the tilt glance's 5 s must not put the screen back down
// between hearing "hey jawn" and the capture committing.
static volatile uint32_t voiceWakeHoldUntil = 0;
// True while the panel has been darkened because a send is holding the chip
// awake: the screen is off, but the loop keeps running so a touch brings it back
// and the payload finishes in the background.
static bool ship_dim = false;
// The clip's own timestamp: it rides with the clip to the server and comes back on
// the voice_done ack, so the watch deletes the file only for the clip that was
// transcribed (not a newer one that has since been recorded over it).
static volatile long voice_clip_ts = 0;
// Set by loop2 when the server acks a transcribed clip; loop() (same core as the
// mic task) does the delete so the filesystem is not touched from two cores.
static volatile long voice_done_ts = -1;
// A second view of the same clip for the voice task, which holds the file until it
// is written down: the server sends voice_recv the moment the clip arrives whole
// (so the task stops retrying) and voice_done after it is transcribed and filed
// (so loop() deletes the file). loop2 sets both.
static volatile long voice_acked_ts = -1;
// The one clip file the capture writes and the server's ack deletes.
static String VOICE_WAV_PATH = "/voice.wav";
// The same clip compacted to an IMA ADPCM WAV (~4:1) before it ships: the BLE
// link is the slow part off WiFi, and ffmpeg (the server's transcriber) reads
// this container natively, so nothing server-side changes.
static String VOICE_ADPCM_PATH = "/voice.adpcm";
// Set when the saved config says BLE should be on. Starting the BLE stack from
// setup() crashes the watch, so the start is deferred to loop() once the rest of
// the boot (display, LVGL, WiFi) has settled.
static bool btStartPending = false;
// The radio's real state. bt_enabled is the *preference* (what configSave writes
// and the net room button shows); it can be true while a start is still pending,
// so the start/stop guards must not key off it or the radio never comes up.
static bool ble_radio_up = false;
// BLE comes back after a light sleep, but never on the wake's critical path:
// the stack bring-up blocks the loop for seconds, and waking straight into it
// left the clock frozen while the radio came up (user, 2026-10-10). The sleep
// handler only schedules the restore; loop() runs it once the display is back.
// Zero means nothing is pending, and a new sleep cancels a pending restore.
static uint32_t ble_restore_at = 0;
// A BLE bring-up task is in flight (see ble_start_async): stop_ble_transfer waits
// for it, and loop() runs the LVGL repaint the task owes the ui core.
static volatile bool ble_start_running = false;
static volatile bool ble_refresh_pending = false;
char standby_en = 1;
long DEFAULT_SCREEN_TIMEOUT = 60*1000;
String jw_room = "watch";
void settingSensor();
void settingPMU();
uint16_t t_x = 0, t_y = 0;
String authorization;
bool ota_refused = false;
String authorization_json;
WebServer server(3000);
WiFiClientSecure *connexion = new WiFiClientSecure;
HTTPClient https;
String name = "LilyGo T-Watch S3";
String ssid = name;
String base_ssid = ssid;
String password = "president";
String base_password = password;
String ap_ssid = ssid;
String base_ap_ssid = ap_ssid;
String ap_password;
String base_ap_password = ap_password;
long offset;
int room = 1;
int room_count = 1;
int room_max = 6;
int b1_toggle, b2_toggle, b3_toggle, b4_toggle, b5_toggle, b6_toggle = 0;
String returner;
uint32_t lastMillis;
uint32_t buttonMillis = 0;
String before_me = "";
bool buttoned_before = false;
// The president room's button state lives on the homebase; the fetch runs on
// core 0 (it is a one to two second TLS round trip) and loop() applies it.
static volatile bool president_fetch_running = false;
static volatile bool president_data_ready = false;
static String president_payload;
static int president_fetch_room = 1;
// Set when a BLE room_request goes out, cleared when a payload lands (or when
// we leave the room). If the bridge never answers it (a sleeping phone, an app
// that does not forward it) loop() falls back to the direct http fetch.
static volatile uint32_t ble_room_requested_at = 0;
static volatile int ble_room_requested_room = 0;
// loop2 sets these when a BLE message changed what belongs on screen; the LVGL
// work itself stays on core 1 in loop()
static volatile bool ble_toggle_refresh = false;
static volatile bool ble_now_me_ready = false;
// when the bridge last showed up; loop2 uses it to ask for missed state
volatile uint32_t ble_connected_at = 0;
char bufsec[64];
char bufdate[64];
char buftime[64];
char *bufgwIP = new char[40]();
char *bufIP = new char[40]();
char *bufapIP = new char[40]();
char *bufapgwIP = new char[40]();
IPAddress apIP;
String homebase;
String homebaseIP;
// The address Now Me handed this watch is the *preferred* House machine. The
// active address (homebaseIP) may move to another House machine when that one
// stops answering; the preferred one is restored as soon as it comes back, and
// only the preferred address is written to the config.
static String homebase_preferredIP;
// The House machines this watch can fall back to. Now Me carries a list (the
// other machines on the LAN, with their ports) and mDNS refreshes it, so a
// watch whose laptop went to sleep lands on another computer/mobile/server
// instead of going dark until the next Now Me.
#define HOUSE_MAX 8
struct HouseNode { String host; int arm; int coms; int bestow; };
static HouseNode house_nodes[HOUSE_MAX];
static int house_node_count = 0;
static volatile int house_switch_req = -1;
static uint32_t house_last_scan = 0;
static TaskHandle_t house_task_handle = NULL;
static void house_maintain();
static void house_task(void *pvParameters);
static void house_learn_json(const String &js);
static void house_add(const String &host, int arm, int coms, int bestow);
static void house_remember_preferred();
// While the homebase is away every https_request is a TLS connect that times
// out; after one fails, skip the attempts for a while (see https_request_raw).
static uint32_t homebase_down_until = 0;
String homebaseIPArray[10];
String wifi_update;
JSONVar wigi;
JSONVar notifications = JSON.parse("[]");
String computer_name;
static RTC_DATA_ATTR int brightnessLevel = 50;

// Breadcrumbs in RTC memory survive a panic reset even when the panic handler
// cannot print anything (the silent double-faults after the 25 KB pushes on
// 2026-10-09): the boot after a crash says where the last one stood. Plain
// RTC_DATA_ATTR is reloaded from the image on this reset type, so the crumbs
// live in the no-init section behind a magic word instead. A ring, not one
// slot: both cores write crumbs, and the newest write is not always the story
// (during a push core 0 sits in loop2 while core 1 applies the last payload).
#define CRUMB_RING 32
#define CRUMB_MAGIC 0x4A574E21u   // "JWN!"
static RTC_NOINIT_ATTR uint32_t crumb_magic;
static RTC_NOINIT_ATTR uint8_t crumb_head;
static RTC_NOINIT_ATTR char crumb_tag[CRUMB_RING][20];
static RTC_NOINIT_ATTR uint32_t crumb_heap[CRUMB_RING];
static RTC_NOINIT_ATTR uint8_t crumb_core[CRUMB_RING];

static void crumb(const char *tag) {
  crumb_magic = CRUMB_MAGIC;
  uint8_t h = (uint8_t)((crumb_head + 1) % CRUMB_RING);
  crumb_head = h;
  strncpy(crumb_tag[h], tag, sizeof(crumb_tag[h]) - 1);
  crumb_tag[h][sizeof(crumb_tag[h]) - 1] = '\0';
  crumb_heap[h] = ESP.getFreeHeap();
  crumb_core[h] = (uint8_t)xPortGetCoreID();
}

static void crumbs_dump() {
  if (crumb_magic != CRUMB_MAGIC) {
    Serial.println("[crumbs] none");
    return;
  }
  for (int i = 1; i <= CRUMB_RING; i++) {
    int idx = (crumb_head + i) % CRUMB_RING;
    if (!crumb_tag[idx][0]) continue;
    Serial.printf("[crumbs] c%u %-16s free=%u\n",
                  (unsigned)crumb_core[idx], crumb_tag[idx], (unsigned)crumb_heap[idx]);
  }
}
int vibrateLevel = 50;
int volumeLevel = 50;
void lowPowerEnergyHandler();
static bool accel_sample(float &x, float &y, float &z);
static void tilt_serial_poll();
static void tilt_dbg_stream();
static void tilt_wake_control(lv_event_t *e);
static bool room_has_buttons(int r);
static void screen_gesture(lv_event_t *e);
static void ble_push_steps(bool force);
static void voiceListenStart(bool one_shot);
static void voice_control(lv_event_t *e);
static void voice_border_show(bool on);
static void voice_trigger_apply();
void setting_room();
String chat_room;
bool loraChatBroadcaster = false;
bool loraChatReceiver = false;
bool stepCounter = true;
uint32_t steps;
uint32_t stepSampleMillis = 0;
// the pedometer value at the last BLE hand-off: what the next push deltas from
static uint32_t bleStepsBase = 0;
// A link-up fires on every reconnect and a worn watch almost always has a new
// step by then, so the recovery push spammed once per tap and wake. Automatic
// pushes wait at least this long; the forced 60 s sample never is held back.
#define BLE_STEPS_MIN_INTERVAL_MS 60000UL
static uint32_t ble_steps_pushed_at = 0;
JSONVar stepped;
#include <driver/gpio.h>
#include <driver/rtc_io.h>

/// Include the official playback engine libraries from the template
#include <AudioOutputI2S.h>
#include <AudioFileSourceFATFS.h>
#include "AudioGeneratorWAV.h"
#include "AudioFileSourceFunction.h"
// the guide associate's spoken reply arrives as streamed PCM parts (see the
// say_audio handler): the watch writes them straight to the codec, so no decoder
// is involved and the rate is whatever the message names
#include "freertos/stream_buffer.h"
String https_request(String url, String method = "GET", String payloadData = "");

// Hardware settings matching the template parameters
String WAV_FILE_PATH = "/rec.wav";
#define AUDIO_BUFFER_CHUNK_SIZE 2048

// The recording path still needs these two, they used to come from the old fork's header
#define MIC_I2S_SAMPLE_RATE 16000
#define MIC_I2S_BITS_PER_SAMPLE 16

// ESP8266Audio normally drives the I2S DAC itself with AudioOutputI2S; the LilyGo
// library owns the codec now, so this hands the generator's samples to it instead.
class LilyGoAudioSink : public AudioOutput
{
  public:
    LilyGoAudioSink(AudioOutputIf *codec) : codec(codec) {}
    bool begin() override {
      if (!codec) {
        return false;
      }
      bool ok = codec->open(16, (uint8_t)channels, (uint32_t)hertz);
      Serial.printf("[Player] codec open %s at %d Hz, %d ch\n", ok ? "ok" : "failed", hertz, channels);
      return ok;
    }
    bool ConsumeSample(int16_t sample[2]) override {
      if (!codec) {
        return false;
      }
      MakeSampleStereo16(sample);
      // The sink was opened with the file's own channel count, so a mono file is
      // being pushed into a mono stream: one 16-bit sample per frame period.
      // Writing both halves of the frame hands the hardware two samples per file
      // sample, which plays everything back at half speed and an octave low.
      if (channels == 1) {
        int16_t mono = sample[LEFTCHANNEL];
        return codec->write((const uint8_t *)&mono, sizeof(mono)) == (int)sizeof(mono);
      }
      int16_t frame[2] = { sample[LEFTCHANNEL], sample[RIGHTCHANNEL] };
      return codec->write((const uint8_t *)frame, sizeof(frame)) == (int)sizeof(frame);
    }
    bool stop() override {
      if (codec) {
        codec->close();
      }
      return true;
    }
  private:
    AudioOutputIf *codec;
};

// both generators derive from AudioGenerator, so the player task does not care
// which one a clip was: the base class is what it drives
AudioGenerator         *wav = nullptr;
AudioFileSourceFATFS    *file_source = nullptr;
LilyGoAudioSink         *out_hardware = nullptr;

// The watch face labels (see watch_face_maker); declared up here because loop()
// refreshes the status bar before they are defined further down the file.
static lv_obj_t *face_date = nullptr;
static lv_obj_t *face_time = nullptr;
static lv_obj_t *face_sec = nullptr;
static lv_obj_t *face_steps = nullptr;
static lv_obj_t *face_battery = nullptr;
static lv_obj_t *face_percent = nullptr;
static lv_obj_t *face_name = nullptr;
static lv_obj_t *face_ip = nullptr;
static lv_obj_t *face_gw = nullptr;
static lv_obj_t *face_ap = nullptr;
static lv_obj_t *face_apgw = nullptr;
// the net room's "BT:" line: which device the bridge is (see ip_writer)
static lv_obj_t *face_bt = nullptr;
// set from a gesture or a page button; loop() does the redraw, because the
// screen cannot be rebuilt while its own event is running
static volatile bool room_redraw = false;
// "blestop on": stop asking the bridge for state after a connect, which is what
// makes the phone push the big room payload back. A debugging switch for the
// 25 KB push panic (2026-10-09), while the fix is worked out.
static bool ble_state_off = false;
static lv_obj_t *face_presidente = nullptr;
static lv_obj_t *notification_lines[4] = { nullptr, nullptr, nullptr, nullptr };
// the clock room's Wigi button carries the count of taps waiting in wigi
static lv_obj_t *wigi_count_label = nullptr;

// Tracking operation status flags across threads
volatile bool isRecording = false;
volatile bool isPlaying = false;

#define FORMAT_FFAT true

// `radio` is now the global SX1262 that LilyGoLib creates for this board
volatile bool operationDone = false;
bool transmitFlag = false;
void setFlag(void) {
  // we sent or received a packet, set the flag
  operationDone = true;
}

lv_obj_t * btn1;
lv_obj_t * btn2;
lv_obj_t * btn3;
lv_obj_t * btn4;
lv_obj_t * btn5;
lv_obj_t * btn6;
lv_obj_t * notification_btn;
lv_obj_t * wigi_btn;
lv_obj_t * recbtn1;
lv_obj_t *playbtn1;

int notification_view = 0;
int notification_viewing = 0;
long next_notification = 0;
long notMillis;

TaskHandle_t Core0TaskHandle;
SemaphoreHandle_t taskMutex;

JSONVar dualCoreTasks;


BLEServer *pServer = NULL;
BLECharacteristic *pTxCharacteristic = NULL;
BLECharacteristic *pRxCharacteristic = NULL;
BLEService *pService = NULL;
BLE2902 *pCccd = NULL;
// written by the BLE stack task, read by the ui core: volatile so neither core
// caches it across the sleep teardown (see ble_link_ready)
volatile bool deviceConnected = false;
// Who is on the other end of the bridge. The address comes from the connect
// event; the name arrives with the daemon's hello (Android rotates the
// address underneath the connection, a name does not). Fixed buffers, not
// String: the BLE callback and the ui run on different cores, and a String's
// heap can tear under that.
static char ble_peer_addr[18] = "";
static char ble_peer_name[32] = "";

// The phone can only hear a notify once it has written the notification
// descriptor (its CCCD). The bridge subscribes a beat after the link comes up,
// and a tap pressed in that gap used to look sent and vanish; this flag makes
// the watch queue it instead (see ble_link_ready).
static volatile bool ble_notify_ready = false;

// Every write to the phone must pass this. ble_radio_up is the radio's own
// state; deinit() deletes the server and its characteristics, so after a sleep
// teardown deviceConnected and pTxCharacteristic alone can lie (stale true /
// dangling) until the next bring-up - a steps push in that window wrote into
// freed memory, the StoreProhibited panic on the first wrist raise after a
// walk's minute's worth of steps. The subscription flag covers the other
// half: a notify before the phone subscribes is dropped without an error.
