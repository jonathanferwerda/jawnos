
#include <Arduino.h>
#include <Wire.h>
#include <TFT_eSPI.h>
#include <lvgl.h>
#include <WiFi.h>
#include <WiFiAP.h>
// WebServer.h wants FS (and <functional>) declared before it sees them
#include "FS.h"
#include "FFat.h"
// TFT_eSPI defines FS_NO_GLOBALS before FS.h, so the global FS alias is gone
using fs::FS;
#include <WebServer.h>
#include <Update.h>
#include <HTTPClient.h>
#include <driver/i2s_tdm.h>
#include "es7210.h"
#include <Audio.h>
#include "utilities.h"
#include <ESP32Time.h>
#include <Arduino_JSON.h>
#include <UrlEncode.h>
#include <PNGdec.h>
#include <RadioLib.h>
#include <SD.h>
#include <ArduinoWebsockets.h>
#include "FS.h"
#include "FFat.h"
#include "NotoSansBold15.h"
#include "NotoSansBold36.h"
#include "Final_Frontier_28.h"
#include "Latin_Hiragana_24.h"
#include "Unicode_Test_72.h"
#include <TinyGPS++.h>
// The font names are arrays references, thus must NOT be in quotes ""
#define AA_FONT_SMALL NotoSansBold15
#define AA_FONT_LARGE NotoSansBold36
PNG png;

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

static const uint16_t screenWidth  = 320;
static const uint16_t screenHeight = 240;
#define DEFAULT_COLOR               (lv_color_make(252, 218, 72))
#define MIC_I2S_SAMPLE_RATE         16000
#define MIC_I2S_PORT                I2S_NUM_1
#define SPK_I2S_PORT                I2S_NUM_0
#define VAD_SAMPLE_RATE_HZ          16000
#define VAD_FRAME_LENGTH_MS         30
#define VAD_BUFFER_LENGTH           (VAD_FRAME_LENGTH_MS * VAD_SAMPLE_RATE_HZ / 1000)
#define LVGL_BUFFER_SIZE            (TFT_WIDTH * TFT_HEIGHT * sizeof(lv_color_t))


WebServer server(3000);
long offset;
static bool webserver_enabled;// = true;
static bool wifi_ap_enabled = false;
static bool wifi_enabled = false;
String tauth_remote_enabled = "off";
#define DEFAULT_SCREEN_TIMEOUT                  20*1000
uint8_t currentBrightness = 30;
uint8_t lastBrightness = 30;
int tempBrightness;
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
String tauthorization;
int tauth_count = 0;
int b1_toggle, b2_toggle, b3_toggle, b4_toggle, b5_toggle, b6_toggle, b7_toggle, b8_toggle = 0;
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
String homebase;
String homebaseIP;
String thomebaseIP;
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
// Flag used to indicate whether to use light sleep, currently unavailable
static bool lightSleep = false;
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


#if TFT_DC !=  BOARD_TFT_DC || TFT_CS !=  BOARD_TFT_CS || TFT_MOSI !=  BOARD_SPI_MOSI || TFT_SCLK !=  BOARD_SPI_SCK
#error "Not using the already configured T-Deck file, please remove <Arduino/libraries/TFT_eSPI> and replace with <lib/TFT_eSPI>, please do not click the upgrade library button when opening sketches in ArduinoIDE versions 2.0 and above, otherwise the original configuration file will be replaced !!!"
#error "Not using the already configured T-Deck file, please remove <Arduino/libraries/TFT_eSPI> and replace with <lib/TFT_eSPI>, please do not click the upgrade library button when opening sketches in ArduinoIDE versions 2.0 and above, otherwise the original configuration file will be replaced !!!"
#error "Not using the already configured T-Deck file, please remove <Arduino/libraries/TFT_eSPI> and replace with <lib/TFT_eSPI>, please do not click the upgrade library button when opening sketches in ArduinoIDE versions 2.0 and above, otherwise the original configuration file will be replaced !!!"
#endif

TouchLib *touch = NULL;

TFT_eSPI tft;
ESP32Time rtc;
using namespace websockets;
WebsocketsClient wsclient;
WiFiClientSecure *connexion = new WiFiClientSecure;
HTTPClient https;
bool ws_connected = 0;
void wsMessageCallback(WebsocketsMessage message) {
  //    Serial.print("Got Message: ");
  //    Serial.println(message.data());
}
void wsClose(WebsocketsMessage closer) {
  //    tauth_cancel();


}
void setupLvgl();
static lv_obj_t *vad_btn_label;
static uint32_t vad_detected_counter = 0;
static TaskHandle_t vadTaskHandler;
bool        transmissionFlag = true;
bool        radioInterrupt = true;
int         transmissionState;
bool        hasRadio = false;
bool        touchDected = false;
bool        kbDected = false;
bool        sender = true;
bool        enterSleep = false;
bool        runGPS = false;
uint32_t    sendCount = 0;
uint32_t    runningMillis = 0;
uint8_t     touchAddress = GT911_SLAVE_ADDRESS2;
#ifndef SerialGPS
#define SerialGPS Serial1
#endif
TinyGPSPlus gps;
static bool GPS_Recovery(uint32_t ackMs);
uint8_t buffer[256];

// The GPS is a bonus, not a boot prerequisite. The bring-up used to park in a
// `while (1)` when the module did not answer, which froze the deck until the
// task watchdog restarted it; now a failed attempt just means "try again
// later", and every attempt is bounded so the UI never stalls for long.
bool gpsReady = false;
static uint8_t gpsAttempts = 0;
static uint32_t gpsRetryAt = 0;
#define GPS_RETRY_INTERVAL 30000
#define GPS_MAX_ATTEMPTS   6
static bool gpsBringUp(uint32_t stopWaitMs, uint32_t verWaitMs, int tries, uint32_t ackMs);

String textarea_content = "";
TaskHandle_t    playHandle = NULL;
TaskHandle_t    radioHandle = NULL;
String audioFile;
lv_indev_t  *kb_indev = NULL;
lv_indev_t  *mouse_indev = NULL;
lv_indev_t  *touch_indev = NULL;
lv_group_t  *kb_indev_group;
lv_obj_t *main_count;

lv_obj_t * btn1;
lv_obj_t * btn2;
lv_obj_t * btn3;
lv_obj_t * btn4;
lv_obj_t * btn5;
lv_obj_t * btn6;
#define LILYGO_KB_SLAVE_ADDRESS     0x55

typedef struct {
  uint8_t cmd;
  uint8_t data[14];
  uint8_t len;
} lcd_cmd_t;
lcd_cmd_t lcd_st7789v[] = {
  {0x01, {0}, 0 | 0x80},
  {0x11, {0}, 0 | 0x80},
  {0x3A, {0X05}, 1},
  {0x36, {0x55}, 1},
  {0xB2, {0x0C, 0x0C, 0X00, 0X33, 0X33}, 5},
  {0xB7, {0X75}, 1},
  {0xBB, {0X1A}, 1},
  {0xC0, {0X2C}, 1},
  {0xC2, {0X01}, 1},
  {0xC3, {0X13}, 1},
  {0xC4, {0X20}, 1},
  {0xC6, {0X0F}, 1},
  {0xD0, {0XA4, 0XA1}, 2},
  {0xD6, {0XA1}, 1},
  {0xE0, {0XD0, 0X0D, 0X14, 0X0D, 0X0D, 0X09, 0X38, 0X44, 0X4E, 0X3A, 0X17, 0X18, 0X2F, 0X30}, 14},
  {0xE1, {0XD0, 0X09, 0X0F, 0X08, 0X07, 0X14, 0X37, 0X44, 0X4D, 0X38, 0X15, 0X16, 0X2C, 0X3E}, 14},
  {0x21, {0}, 0}, //invertDisplay
  {0x29, {0}, 0},
  {0x2C, {0}, 0},
};
#ifdef USE_ESP_VAD
#include <esp_vad.h>
int16_t         *vad_buff;
vad_handle_t    vad_inst;
const size_t    vad_buffer_size = VAD_BUFFER_LENGTH * sizeof(short);
#else
uint16_t loopbackBuffer[3200] = {0};
#endif


#define BOARD_POWERON       10
#define BOARD_I2C_SDA       18
#define BOARD_I2C_SCL       8
SemaphoreHandle_t xSemaphore = NULL;
#define FORMAT_FFAT true

static bool getTouch(int16_t &x, int16_t &y);
// One SPI bus, one owner: TFT_eSPI starts GPSPI2 inside tft.init() from its own
// SPIClass instance (USE_FSPI_PORT in platformio.ini, see the comments there).
// The radio and the SD card share that bus, so they have to talk through the
// same instance. Beginning the Arduino `SPI` object as well calls periph reset
// on GPSPI2 again, which leaves TFT_eSPI's register-level writes spinning (that
// is what stopped the deck dead right after the third boot dot).
extern SPIClass spi;
SX1262 radio = new Module(RADIO_CS_PIN, RADIO_DIO1_PIN, RADIO_RST_PIN, RADIO_BUSY_PIN, spi);
volatile bool operationDone = false;
void setFlag(void) {
  // we sent or received a packet, set the flag
  operationDone = true;
}
bool checkKb()
{
  int retry = 3;
  do {
    Wire.requestFrom(0x55, 1);
    if (Wire.read() != -1) {
      return true;
    }
  } while (retry--);
  return false;
}


// ---- over the air updates -----------------------------------------------------
// The embedded panel posts a compiled .bin here over the LAN and the board reboots
// into it. The board has to have this in it once (flashed over USB); after that the
// panel can replace the firmware whenever there is a new build.
void ota_upload() {
  HTTPUpload &upload = server.upload();
  if (upload.status == UPLOAD_FILE_START) {
    Serial.println("ota: " + upload.filename);
    if (!Update.begin(UPDATE_SIZE_UNKNOWN)) {
      Update.printError(Serial);
    }
  }
  else if (upload.status == UPLOAD_FILE_WRITE) {
    if (Update.write(upload.buf, upload.currentSize) != upload.currentSize) {
      Update.printError(Serial);
    }
  }
  else if (upload.status == UPLOAD_FILE_END) {
    if (Update.end(true)) {
      Serial.println("ota written");
    }
    else {
      Update.printError(Serial);
    }
  }
}

// Print to both consoles. The sketch's Serial is the USB CDC, which only talks
// to a host that asserts DTR - so a plain monitor sees nothing but ROM output.
// esp_log_write goes to the USB-Serial/JTAG console regardless, which makes the
// deck's progress visible from either side.
static void deckLog(const char *fmt, ...) {
  char buf[192];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  // Only touch the CDC when a host is actually holding it: writing to it with
  // nobody on the other end can stall the caller, and the boot must never wait
  // on a serial monitor.
  if (Serial) {
    Serial.println(buf);
  }
  esp_log_write(ESP_LOG_INFO, "deck", "%s\n", buf);
}

// Why did the deck restart? The ROM reports the reset reason once per boot and
// it scrolls away with the old console contents, so it goes in the log instead.
static const char *resetReasonStr(esp_reset_reason_t reason) {
  switch (reason) {
    case ESP_RST_POWERON:   return "power-on";
    case ESP_RST_EXT:       return "external pin";
    case ESP_RST_SW:        return "software restart";
    case ESP_RST_PANIC:     return "panic/exception";
    case ESP_RST_INT_WDT:   return "interrupt watchdog";
    case ESP_RST_TASK_WDT:  return "task watchdog";
    case ESP_RST_WDT:       return "other watchdog";
    case ESP_RST_DEEPSLEEP: return "deep sleep wake";
    case ESP_RST_BROWNOUT:  return "brownout";
    case ESP_RST_SDIO:      return "sdio";
    case ESP_RST_USB:       return "usb peripheral";
    default:                return "unknown";
  }
}

void setup() {
  Serial.begin(115200);
  deckLog("[deck] boot: peripheral power on (last reset: %s)", resetReasonStr(esp_reset_reason()));
  //! Set CS on all SPI buses to high level during initialization
  pinMode(BOARD_SDCARD_CS, OUTPUT);
  pinMode(RADIO_CS_PIN, OUTPUT);
  pinMode(BOARD_TFT_CS, OUTPUT);

  digitalWrite(BOARD_SDCARD_CS, HIGH);
  digitalWrite(RADIO_CS_PIN, HIGH);
  digitalWrite(BOARD_TFT_CS, HIGH);

  if (!FFat.begin()) {
    // No filesystem means no config and no recordings. It used to return out of
    // setup() here, which left the deck with a dead screen, so try to make one
    // instead and keep going regardless.
    deckLog("[deck] ffat did not mount; formatting");
    if (FFat.begin(true)) {
      deckLog("[deck] ffat formatted");
    }
    else {
      deckLog("[deck] ffat unusable; booting without it");
    }
  }
  else {
    deckLog("[deck] ffat ok");
  }


  //!⚠️ The board peripheral power control pin needs to be set to HIGH when using the peripheral
  deckLog("[deck] peripheral power on");
  pinMode(BOARD_POWERON, OUTPUT);
  digitalWrite(BOARD_POWERON, HIGH);
  delay(500);
  deckLog("[deck] i2c up");
  Wire.begin(BOARD_I2C_SDA, BOARD_I2C_SCL);

  // A keyboard that does not answer used to park the boot in a silent `while (1)`
  // (the task watchdog restarts the deck a few seconds later, so it looks like
  // "freezes then reboots"). Retry briefly and carry on without it instead.
  kbDected = false;
  for (int attempt = 0; attempt < 5 && !kbDected; attempt++) {
    Wire.requestFrom(LILYGO_KB_SLAVE_ADDRESS, 1);
    kbDected = Wire.read() != -1;
    if (!kbDected) {
      delay(200);
    }
  }
  if (!kbDected) {
    deckLog("[deck] no answer from the keyboard; booting anyway");
  }

  deckLog("[deck] display init");
  tft.init();
  tft.setRotation(1);
  deckLog("[deck] display init done (%dx%d)", tft.width(), tft.height());

  deckLog("[deck] backlight + touch pins");
  pinMode(BOARD_BL_PIN, OUTPUT);
  pinMode(BOARD_TOUCH_INT, INPUT);
  digitalWrite(BOARD_TOUCH_INT, HIGH);

  delay(20);
  //Add mutex to allow multitasking access
  xSemaphore = xSemaphoreCreateBinary();
  assert(xSemaphore);
  xSemaphoreGive( xSemaphore );
  // Serial.print("Init display id:");

  deckLog("[deck] painting the boot screen");
  tft.fillScreen(TFT_YELLOW);
  tft.begin();

  tft.setTextColor(TFT_BLACK, TFT_YELLOW);
  tft.setTextFont(4);
  tft.drawString("JTeletype", 110, 210);

  //T-Deck control backlight chip has 16 levels of adjustment range
  for (int i = 0; i < 5; ++i) {
    setBrightness(i);
    lv_task_handler();
    delay(30);
  }

  tft.fillCircle(80, 120, 20, TFT_RED);
  tft.drawCircle(80, 120, 20, TFT_BLACK);
  // The GPS bring-up is deliberately NOT part of the boot. It talks UBX to a
  // module that may be absent, and anything that stalls in here used to hold up
  // the whole deck (screen, WiFi, keyboards). loop() retries it in the
  // background once the deck is up.
  gpsRetryAt = millis() + 4000;
  deckLog("[deck] boot screen up; the gps stage is handed to the background");

  // TFT_eSPI brought the shared SPI bus up in init() and the radio and the SD
  // card are pointed at that same instance, so there is nothing to begin here.
  pinMode(BOARD_SPI_MISO, INPUT_PULLUP);
  deckLog("[deck] sd/radio spi shared");
  // one short attempt at boot; if the module is quiet we carry on booting and
  // let loop() retry, rather than holding the whole deck hostage to a GPS
  gpsReady = gpsBringUp(1200, 300, 1, 300);
  if (gpsReady) {
    deckLog("[gps] module ready");
  } else {
    deckLog("[gps] no answer yet, booting on and retrying in the background");
    gpsRetryAt = millis() + 15000;
  }
  deckLog("[deck] gps stage done, scanning i2c");

  // Serial.println(USER_SETUP_ID);
  // Two touch screens, the difference between them is the device address,
  // use ScanDevices to get the existing I2C address
  scanDevices(&Wire);
  deckLog("[deck] i2c scan done, touch addr 0x%02x", touchAddress);
  tft.fillCircle(160, 120, 20, TFT_GREEN);
  tft.drawCircle(160, 120, 20, TFT_BLACK);
  touch = new TouchLib(Wire, BOARD_I2C_SDA, BOARD_I2C_SCL, touchAddress);

  touch->init();
  deckLog("[deck] touch driver started");

  Wire.beginTransmission(touchAddress);
  touchDected = Wire.endTransmission() == 0;
  deckLog("[deck] touch present=%d", touchDected);

  kbDected = checkKb();
  deckLog("[deck] keyboard present=%d", kbDected);

  server.on("/notification", []() {

    notification_display(server.arg("title"), server.arg("notification"));
    server.send(200, "text/plain", "this works as well");
  });
  server.on("/backup", []() {
    JSONVar backup = JSON.parse(server.arg("backup"));
    String b = backup["current"];
    String ba = backup["archive"];
    String folder = backup["folder"];
    String request = "https://" + homebaseIP + 
      "/embedded/teletype/backup?current=" + folder + "/" + b + "&archive=" + folder + "/" + ba;
    server.send(200, "text/plain", "doing the backup");
    createDir(SD, "/b");
    String local_b = "/b/" + ba;
    https_download(SD, request, local_b.c_str());
    
  });
  server.on("/", []() {
    String html = R"(
      <!DOCTYPE html>
      <html>
        <title>T-Deck Initial Config</title>
        <body style="text-align:center;position:fixed;top: 50%;left: 50%; transform: translate(-50%, -50%);">
          <form action="/initial_config" id="form" method="POST">
            <h1>T-Deck</h1>
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
      ap_password = t_ap_password;
      ap_ssid = t_ap_ssid;
      accesspoint_stop();
      delay(400);
      accesspoint_start();
    }
    if (t_ssid != "" && t_password != "") {
      ssid = t_ssid;
      password = t_password;
      WiFi.disconnect();
      delay(400);
      wifi_server();
    }
    
    configSave();
    
    server.send(200, "text/html", "<h1>Success!</h1><a href='/''>Back</a>");

  });
  server.on("/wifi_update", []() {
    String req = "https://" + homebaseIP + "/teletype/wifi_update?timestamp=" + rtc.getLocalEpoch();
    // Serial.println(req);
    wifi_update = https_request(req);
    // Serial.println(wifi_update);
    JSONVar info = JSON.parse(wifi_update);
    if (ssid != (const char *)info["ssid"] || password != (const char *)info["password"]) {
      ssid = (const char *)info["ssid"];
      password = (const char *)info["password"];
      WiFi.disconnect();
      delay(400);
      wifi_server();
    }
    if (ap_ssid != (const char *)info["ap_ssid"] && ap_password != (const char *)info["ap_password"]) {
      ap_ssid = (const char *)info["ap_ssid"];
      ap_password = (const char *)info["ap_password"];
      // Serial.println(ssid);
      // Serial.println(password);
      // Serial.println(ap_ssid);
      // Serial.println(ap_password);
      accesspoint_stop();
      delay(400);
      accesspoint_start();
    }

    JSONVar pa;
    pa["ap_ssid"] = ap_ssid;
    pa["ap_password"] = ap_password;
    String public_announcement = JSON.stringify(pa);
    //    radio.startTransmit(public_announcement);
    //    delay(1000);
    radio.startReceive();
    server.send(200, "text/plain", "sent wifi info");

  });
  server.on("/send_telephone", []() {
    String temp_authorization = server.arg("authorization");
    JSONVar m;
    m["msg"] = server.arg("msg");
    m["app"] = server.arg("app");
    String jsm = JSON.stringify(m);
    //  Serial.println("Sending msg: " + jsm);
    radio.startTransmit(jsm);
    delay(2000);
    radio.startReceive();
    server.send(200, "text/plain", "transmission sent");
  });
  server.on("/chat_received", []() {
    if (buttoned_before) {
      //    Serial.println(server.arg("s"));
      String s = server.arg("s");
      String uuid = server.arg("uuid");
      chat_grabber(s, uuid);
      server.send(200, "text/plain", "done");
    }
    else {
      server.send(200, "text/plain", "unknown");
    }
  });
  server.on("/device_query", []() {
    JSONVar g;
    String chip_id = chip_id_maker();
    g["chip_id"] = chip_id;
    g["purpose"] = "teletype";
    g["name"] = name;
    g["uptime"] = millis();
    g["wigi"] = wigi;
    JSONVar jonfig = g;
    jonfig["ssid"] = undefined;
    jonfig["password"] = undefined;
    jonfig["ap_password"] = undefined;
    jonfig["ap_ssid"] = undefined;
    String gs = JSON.stringify(jonfig);    
    server.send(200, "text/plain", gs);

  });
  server.on("/my_position", []() {
    JSONVar location;
    location["lat"] = gps.location.lat();
    location["lng"] = gps.location.lng();
    location["alt"] = gps.altitude.meters();
    String located = JSON.stringify(location);
    server.send(200, "text/plain", located);
  });
  server.on("/update", HTTP_POST, []() {
    server.sendHeader("Connection", "close");
    server.send(200, "text/plain", Update.hasError() ? "failed" : "ok");
    delay(500);
    ESP.restart();
  }, ota_upload);

  server.on("/wigi", []() {
    String rauth = server.arg("authorization");
    if (rauth == authorization) {      
      JSONVar wigi_s;
      wigi_s["buttons"] = wigi;
      wigi_s["authorization"] = authorization;
      long timestamp = rtc.getLocalEpoch() - rtc.offset;  

      wigi_s["timestamp"] = timestamp;
      String wigis = JSON.stringify(wigi_s);
      server.send(200,"text/plain", wigis);
      String resetter = "[]";
      wigi = JSON.parse(resetter);
    }
    else {
      server.send(200,"text/plain", "{}");
    }
  });
  server.on("/now_me", []() {
    homebaseIP = server.arg("homebase");
    thomebaseIP = server.arg("thomebase");
    twshomebaseIP = server.arg("twshomebase");
    name = server.arg("name");
    authorization = server.arg("authorization");
    long timestamp = server.arg("timestamp").toInt();
    offset = server.arg("offset").toInt();
    rtc.setTime(timestamp + offset);
    homebase = server.arg("ip");
    Serial.println("Homebase: " + homebase);
    Serial.println("homebase ip:" + homebaseIP);
    rtc.offset = offset;
    room_count = server.arg("room_count").toInt();
    room_max = server.arg("room_max").toInt();

    pmuIrq = false;
    buttoned_before = false;
    //    button_writer();
    // Serial.println("now me in room " + room);
    b1_toggle, b2_toggle, b3_toggle, b4_toggle, b5_toggle, b6_toggle, b7_toggle, b8_toggle = 0;
    // Serial.println(authorization);
    //call_the_president();
    remote_room();
    buttonMillis = millis();
    lastMillis = millis();
    authorization_pusher(before_me);

    // Serial.println("Called President at " + homebaseIP);
    server.send(200, "text/plain", "homebase ip is now " + homebaseIP);
    lv_task_handler();
  });
  deckLog("[deck] mic i2s init");
  setupMicrophoneI2S(MIC_I2S_PORT);
  deckLog("[deck] mic i2s up");
  tft.fillCircle(240, 120, 20, TFT_BLUE);
  tft.drawCircle(240, 120, 20, TFT_BLACK);
  setupLvgl();
  deckLog("[deck] lvgl up");

  readFile(FFat, "/bootreport.txt");
  if (returner == "success") {
    configRestore();
  }
  deckLog("[deck] config restore done (%s)", returner.c_str());
  wsclient.onMessage(wsMessageCallback);
  // set output power to 10 dBm (accepted range is -17 - 22 dBm)
  // The radio is a bonus like the GPS: each of these used to park in a silent
  // `while (true);` on failure, which froze the deck with nothing in the log.
  // Booting without a radio is better (hasRadio is what the LoRa paths check).
  deckLog("[deck] radio init");
  if (radio.setOutputPower(22) == RADIOLIB_ERR_INVALID_OUTPUT_POWER) {
    deckLog("[radio] invalid output power; continuing without it");
  }
  // set over current protection limit to 80 mA (accepted range is 45 - 240 mA)
  // NOTE: set value to 0 to disable overcurrent protection
  if (radio.setCurrentLimit(80) == RADIOLIB_ERR_INVALID_CURRENT_LIMIT) {
    deckLog("[radio] invalid current limit; continuing without it");
  }
  int state = radio.begin(433.0);
  if (state == RADIOLIB_ERR_NONE) {
    radio.setDio1Action(setFlag);
    radio.startReceive();
    hasRadio = true;
    deckLog("[radio] up");
  } else {
    deckLog("[radio] init failed (%d); continuing without it", state);
  }

  if (fontSelect != "") {
    tft.loadFont(fontSelect);    // Must load the font first
  }
  Serial.printf("Total space: %10u\n", FFat.totalBytes());
  Serial.printf("Free space: %10u\n", FFat.freeBytes());
  deckLog("[deck] sd test");
  sd_tester();
  audio.setPinout(BOARD_I2S_BCK, BOARD_I2S_WS, BOARD_I2S_DOUT);
  audio.setVolume(10);
//  audio.connecttoFS(SD, "ding.mp3");
  deckLog("[deck] setup complete");
}

bool setupGPS(uint32_t stopWaitMs, uint32_t verWaitMs, int tries) {
  // L76K GPS USE 9600 BAUDRATE
  SerialGPS.begin(9600, SERIAL_8N1, BOARD_GPS_RX_PIN, BOARD_GPS_TX_PIN);
  bool result = false;
  uint32_t startTimeout ;
  for (int i = 0; i < tries; ++i) {
    SerialGPS.write("$PCAS03,0,0,0,0,0,0,0,0,0,0,,,0,0*02\r\n");
    delay(5);
    // Get version information
    startTimeout = millis() + stopWaitMs;
    Serial.print("Try to init L76K . Wait stop .");
    while (SerialGPS.available()) {
        Serial.print(".");
        SerialGPS.readString();
        if (millis() > startTimeout) {
            Serial.println("Wait L76K stop NMEA timeout!");
            return false;
        }
    };
    Serial.println();
    SerialGPS.flush();
    delay(200);

    SerialGPS.write("$PCAS06,0*1B\r\n");
    startTimeout = millis() + verWaitMs;
    String ver = "";
    while (!SerialGPS.available()) {
        if (millis() > startTimeout) {
            Serial.println("Get L76K timeout!");
            return false;
        }
    }
    SerialGPS.setTimeout(10);
    ver = SerialGPS.readStringUntil('\n');
    if (ver.startsWith("$GPTXT,01,01,02")) {
        Serial.println("L76K GNSS init succeeded, using L76K GNSS Module\n");
        result = true;
        break;
    }
    delay(500);
  }
  // Initialize the L76K Chip, use GPS + GLONASS
  SerialGPS.write("$PCAS04,5*1C\r\n");
  delay(250);
  SerialGPS.write("$PCAS03,1,1,1,1,1,1,1,1,1,1,,,0,0*02\r\n");
  delay(250);
  // Switch to Vehicle Mode, since SoftRF enables Aviation < 2g
  SerialGPS.write("$PCAS11,3*1E\r\n");
  return result;
}

static bool GPS_Recovery(uint32_t ackMs)
{
    uint8_t cfg_clear1[] = {0xB5, 0x62, 0x06, 0x09, 0x0D, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x1C, 0xA2};
    uint8_t cfg_clear2[] = {0xB5, 0x62, 0x06, 0x09, 0x0D, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x1B, 0xA1};
    uint8_t cfg_clear3[] = {0xB5, 0x62, 0x06, 0x09, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00, 0x03, 0x1D, 0xB3};
    uint32_t t0;
    int got;

    SerialGPS.write(cfg_clear1, sizeof(cfg_clear1));
    t0 = millis();
    got = getAck(buffer, 256, 0x05, 0x01, ackMs);
    deckLog("[gps] vals clear 1 -> %d in %u ms", got, millis() - t0);

    SerialGPS.write(cfg_clear2, sizeof(cfg_clear2));
    t0 = millis();
    got = getAck(buffer, 256, 0x05, 0x01, ackMs);
    deckLog("[gps] vals clear 2 -> %d in %u ms", got, millis() - t0);

    SerialGPS.write(cfg_clear3, sizeof(cfg_clear3));
    t0 = millis();
    got = getAck(buffer, 256, 0x05, 0x01, ackMs);
    deckLog("[gps] vals clear 3 -> %d in %u ms", got, millis() - t0);

    // UBX-CFG-RATE, Size 8, 'Navigation/measurement rate settings'
    uint8_t cfg_rate[] = {0xB5, 0x62, 0x06, 0x08, 0x00, 0x00, 0x0E, 0x30};
    SerialGPS.write(cfg_rate, sizeof(cfg_rate));
    t0 = millis();
    got = getAck(buffer, 256, 0x06, 0x08, ackMs);
    deckLog("[gps] rate poll -> %d in %u ms", got, millis() - t0);
    if (!got) {
        return false;
    }
    return true;
}

// One bounded bring-up attempt: L76K first, then the u-blox M10Q that other
// decks ship with. Returns as soon as a module answers, and gives up quickly
// when none does.
static bool gpsBringUp(uint32_t stopWaitMs, uint32_t verWaitMs, int tries, uint32_t ackMs)
{
  deckLog("[gps] trying the L76K protocol");
  if (setupGPS(stopWaitMs, verWaitMs, tries)) {
    return true;
  }
  // maybe it is a u-blox M10Q at 38400 instead of an L76K at 9600
  deckLog("[gps] no L76K, trying u-blox at 38400");
  SerialGPS.begin(38400, SERIAL_8N1, BOARD_GPS_RX_PIN, BOARD_GPS_TX_PIN);
  if (GPS_Recovery(ackMs)) {
    return true;
  }
  deckLog("[gps] trying u-blox at 9600");
  SerialGPS.updateBaudRate(9600);
  if (GPS_Recovery(ackMs)) {
    return true;
  }
  return false;
}


int getAck(uint8_t *buffer, uint16_t size, uint8_t requestedClass, uint8_t requestedID, uint32_t timeoutMs)
{
    uint16_t    ubxFrameCounter = 0;
    bool        ubxFrame = 0;
    uint32_t    startTime = millis();
    uint16_t    needRead;

    // The deadline has to be checked in here as well: a module that keeps
    // streaming NMEA leaves this inner loop with data available forever, and
    // the outer check only runs once it drains - which is never.
    while (millis() - startTime < timeoutMs) {
        while (SerialGPS.available() && (millis() - startTime < timeoutMs)) {
            int c = SerialGPS.read();
            switch (ubxFrameCounter) {
            case 0:
                if (c == 0xB5) {
                    ubxFrameCounter++;
                }
                break;
            case 1:
                if (c == 0x62) {
                    ubxFrameCounter++;
                } else {
                    ubxFrameCounter = 0;
                }
                break;
            case 2:
                if (c == requestedClass) {
                    ubxFrameCounter++;
                } else {
                    ubxFrameCounter = 0;
                }
                break;
            case 3:
                if (c == requestedID) {
                    ubxFrameCounter++;
                } else {
                    ubxFrameCounter = 0;
                }
                break;
            case 4:
                needRead = c;
                ubxFrameCounter++;
                break;
            case 5:
                needRead |=  (c << 8);
                ubxFrameCounter++;
                break;
            case 6:
                if (needRead >= size) {
                    ubxFrameCounter = 0;
                    break;
                }
                if (SerialGPS.readBytes(buffer, needRead) != needRead) {
                    ubxFrameCounter = 0;
                } else {
                    return needRead;
                }
                break;

            default:
                break;
            }
        }
    }
    return 0;
}

void displayInfo()
{
  // Keep the RTC on GPS time when the module has a date for us
  if (gps.time.isValid() && gps.date.year() != 2000) {
    rtc.setTime(gps.time.second(), gps.time.minute(), gps.time.hour(),
                gps.date.day(), gps.date.month(), gps.date.year());
    rtc.setTime(rtc.getEpoch());
  }

  // one compact line every ten seconds, instead of a wall of half printed
  // sentences for every NMEA burst the module sends
  static uint32_t lastReport = 0;
  if (millis() - lastReport < 10000) {
    return;
  }
  lastReport = millis();
  if (gps.location.isValid()) {
    Serial.printf("[gps] sats %d  %.5f,%.5f  time age %u ms\n",
                  (int)gps.satellites.value(), gps.location.lat(), gps.location.lng(),
                  (unsigned)gps.time.age());
  } else {
    Serial.printf("[gps] no fix yet, sats %d, sentences %u\n",
                  (int)gps.satellites.value(), (unsigned)gps.sentencesWithFix());
  }
}

void chat_grabber(String s, String uuid) {
  Serial.println(s);
  if (authorization) {
    String request = "https://" + homebaseIP + "/watch/chat_grabber?s=" + s + "&uuid=" + uuid;
    Serial.println(request);
    String response = https_request(request);
    Serial.println(response);
    JSONVar mail = JSON.parse(response);
    buttonMillis = millis();
    String manager_file = mail["manager_file"];
    String body = mail["body"];
    long timestamp = mail["timestamp"];
    chat_text_writer(manager_file, body, timestamp);
    loraChatBroadcast(manager_file, body, timestamp);

  }

}

int last_chat_y;
void chat_text_writer(String manager_file, String body, long timestamp) {
  int y = tft.getCursorY();
  int x = tft.getCursorX();
  JSONVar president;
  if (buttoned_before) {
    president = JSON.parse(before_me);
    tft.setTextColor(tft.color565(president["__specs"]["chat_text_colour_rgb"][0], president["__specs"]["chat_text_colour_rgb"][1], president["__specs"]["chat_text_colour_rgb"][2]), tft.color565(president["__specs"]["chat_background_colour_rgb"][0], president["__specs"]["chat_background_colour_rgb"][1], president["__specs"]["chat_background_colour_rgb"][2]));
  }
  else {
    tft.setTextColor(TFT_WHITE, TFT_BLACK);
  }
  fontLoader();
  tft.setTextWrap(true, true);

  if (last_chat_y > 200) {
    last_chat_y = y + 26;
  }
  else {
    last_chat_y = last_chat_y + 26;
  }
  tft.setCursor(1, last_chat_y);
  tft.print(manager_file + ": " + body);
  last_chat_y = tft.getCursorY();
  buttonMillis = millis();
  tft.setCursor(x, y);
  fontUnloader();

}

void notification_display(String title, String notification) {
  jw_room = "message";

  static const char *btns[] = {""};

  int t_length = title.length() + 1;
  int n_length = notification.length() + 1;
  char t[t_length];
  char n[n_length];

  title.toCharArray(t, t_length);
  notification.toCharArray(n, n_length);

  lv_obj_t * mb = lv_msgbox_create(lv_scr_act());
  lv_msgbox_add_title(mb, t);
  lv_msgbox_add_text(mb, n);


  //  lv_obj_center(mb);
  lv_obj_set_y(mb, 35);

  lv_task_handler();

  //display_exit();
  buttonMillis = millis();
  lastMillis = millis();
  pmuIrq = false;
 

  bool findMp3 = audio.connecttoFS(FFat, "ding.mp3");
  if (findMp3 == false && homebaseIP) {
    String request = "https://" + homebaseIP + "/watch/asset?filename=/sounds/notifications/ding.mp3";
    Serial.println(request);
    https_download(FFat, request, audioFile);
    findMp3 = audio.connecttoFS(FFat, "ding.mp3");
  }
}

void wifi_server() {
  if (ssid == "" && password == "") {
    wifi_enabled = false;
    return;
  }

  if (wifi_enabled == true) {

    if (WiFi.status() != WL_CONNECTED) {
      WiFi.begin(ssid, password);
    }

    int tryDelay = 420;
    int numberOfTries = 10;
    while (true) {
      switch (WiFi.status()) {
        case WL_NO_SSID_AVAIL:
          // Serial.println("[WiFi] SSID not found");
          break;
        case WL_CONNECT_FAILED:
          // Serial.print("[WiFi] Failed - WiFi not connected! Reason: ");
          return;
          break;
        case WL_CONNECTION_LOST:
          // Serial.println("[WiFi] Connection was lost");
          break;
        case WL_SCAN_COMPLETED:
          // Serial.println("[WiFi] Scan is completed");
          break;
        case WL_DISCONNECTED:
          // Serial.println("[WiFi] WiFi is disconnected");
          break;
        case WL_CONNECTED:
          // Serial.println("[WiFi] WiFi is connected!");
          // Serial.print("[WiFi] IP address: ");
          // Serial.println(WiFi.localIP());
          server.begin();
          webserver_enabled = true;
          wifi_enabled = true;
          return;
          break;
        default:
          // Serial.print("[WiFi] WiFi Status: ");
          // Serial.println(WiFi.status());
          break;
      }
      delay(tryDelay);
      if (numberOfTries <= 0) {
        // Serial.print("Wifi failed to connect");
        WiFi.disconnect();
        // wifi_enabled = false;
        return;
      }
      else {
        numberOfTries--;
      }
    }
    while (WiFi.status() != WL_CONNECTED) {
      delay(100);
      // Serial.print(".");
    }
  }
}


void loop() {
  char keyValue = 0;
  wsclient.poll();
  if (audio.isRunning()){
    audio.loop();
  }

  if (digitalRead(BOARD_TOUCH_INT)) {
    bool res =  touch->read();
    if (res) {
      //    buttonMillis = millis();

      TP_Point  p = touch->getPoint(0);
      if (troom == "typewriter" && jw_room == "room") {
        if (millis() >= touchLastMillis + 50 && ws_connected == 1 && ws_mouse_to_send <= 3) {
          ws_mouse_to_send++;
          touchLastMillis = millis();
          JSONVar wsdata;
          wsdata["command"] = "touch";
          wsdata["res_x"] = screenWidth;
          wsdata["res_y"] = screenHeight;
          wsdata["x"] = p.x;
          wsdata["y"] = p.y;
          wsdata["t"] = millis();
          wsdata["r"] = tft.getRotation();
          wsdata["mmr"] = mouse_move_relative;

          if (mouse_move_relative == "on") {
            wsdata["last_x"] = last_x;
            wsdata["last_y"] = last_y;
            wsdata["touching"] = touching;
          }
          String jsonwsdata = JSON.stringify(wsdata);
          wsclient.send(jsonwsdata);
          touching = 1;
          last_x = p.x;
          last_y = p.y;
          ws_mouse_to_send--;
        }
      }
      else if (jw_room == "room") {
        button_writer();
        lv_task_handler();
      }
    }
    else {
      touching = 0;
    }
  }
  if (troom != "typewriter") {
    lv_task_handler();
  }
  if (jw_room != "typewriter") {
    lv_task_handler();

  }
  if (jw_room == "watch") {
    time_writer("loop");
  }
  if (jw_room == "net") {
    ip_writer();
  }
  static  int16_t last_x;
  static int16_t last_y;
  bool left_button_down = false;
  const uint8_t dir_pins[5] = {1, 2, 3, 15, 0};
  static bool last_dir[5];
  uint8_t pos = 1;
  String movement;
  for (int i = 0; i < 5; i++) {
    bool dir = digitalRead(dir_pins[i]);
    // Serial.println(dir);
    if (last_dir[i] != dir) {
      buttonMillis = millis();
      last_dir[i] = dir;
      if (dir_pins[i] == 1) {
        movement = "left";
        if (roller_ball_direction == "left" && rb_count >= 5) {
          troom = "home";
          jw_room = "room";
          rb_count = 0;
          //authorization_changer("down");
          remote_room();
        }
        else if (roller_ball_direction == "left") {
          rb_count++;
        }
        else {
          rb_count = 0;
        }
        roller_ball_direction = "left";
      }
      if (dir_pins[i] == 2) {
        movement = "right";
        if (roller_ball_direction == "right" && rb_count >= 5) {
          troom = "home";
          display_exit();
          button_writer();
          jw_room = "pen";
          pen_room();
          rb_count = 0;
        }
        else if (roller_ball_direction == "right") {
          rb_count++;
        }
        else {
          rb_count = 0;
        }
        roller_ball_direction = "right";
      }
      if (dir_pins[i] == 15) {
        movement = "down";
        if (roller_ball_direction == "down" && rb_count >= 5) {
          troom = "home";
          jw_room = "configure";
          rb_count = 0;
          //authorization_changer("down");
          setting_room();
        }
        else if (roller_ball_direction == "down") {
          rb_count++;
        }
        else {
          rb_count = 0;
        }
        roller_ball_direction = "down";
      }
      if (dir_pins[i] == 3) {
        movement = "up";
        if (roller_ball_direction == "up" && rb_count >= 5) {
          troom = "home";
          jw_room = "chat";
          display_exit();
          button_writer();
          chat_displayer();
          rb_count = 0;
        }
        else if (roller_ball_direction == "up") {
          rb_count++;
        }
        else {
          rb_count = 0;
        }
        roller_ball_direction = "up";
      }
      if (dir_pins[i] == 0) {
        movement = "button";
        if (jw_room == "room" && ws_connected == 1) {
          long timestamp = rtc.getLocalEpoch() - rtc.offset;
  
          JSONVar json;
          json["value"] = dir;
          json["command"] = "mouse";
          json["movement"] = movement;
          json["timestamp"] = timestamp;
  
          String json_p = JSON.stringify(json);
          wsclient.send(json_p);
        }
      }
    }
  }
  if (millis() - wsLastMillis > 2000 && ws_connected == 1) {
    wsclient.send("hey");
    wsLastMillis = millis();

  }

  server.handleClient();
  readRadio();
    // the GPS bring-up retries in the background: bounded, and it stops trying
    // after a few goes so a missing module costs nothing after that
    if (!gpsReady && gpsAttempts < GPS_MAX_ATTEMPTS && millis() > gpsRetryAt) {
      gpsAttempts++;
      gpsRetryAt = millis() + GPS_RETRY_INTERVAL;
      deckLog("[gps] retry %u of %u", (unsigned)gpsAttempts, (unsigned)GPS_MAX_ATTEMPTS);
      gpsReady = gpsBringUp(1000, 300, 1, 300);
      if (gpsReady) {
        deckLog("[gps] module ready");
      } else if (gpsAttempts >= GPS_MAX_ATTEMPTS) {
        deckLog("[gps] giving up on the module; the deck runs fine without it");
      }
    }

    while (Serial.available()) {
        SerialGPS.write(Serial.read());
    }

    while (SerialGPS.available()) {
        int c = SerialGPS.read();
        // Serial.write(c);
        if (gps.encode(c)) {
            displayInfo();
        }
    }

    if (millis() > 30000 && gps.charsProcessed() < 10) {
        Serial.println(F("No GPS detected: check wiring."));
        delay(1000);
    }
  if (millis() - buttonMillis > DEFAULT_SCREEN_TIMEOUT && currentBrightness != 0) {
    // Serial.println(currentBrightness);
    tempBrightness = lastBrightness;
    configSave();
    writeFile(FFat, "/bootreport.txt", "success");

    for (int i = brightnessLevel; i >= 0; --i) {
      setBrightness(i);
      lv_task_handler();
      delay(30);
    }
    
      //If you need other peripherals to maintain power, please set the IO port to hold

    tft.writecommand(0x10);      //set display enter sleep mode
 
  }
  else if (millis() - buttonMillis < DEFAULT_SCREEN_TIMEOUT && currentBrightness == 0) {
    // Serial.println("not sleepy " + lastBrightness);
    tft.begin();
    for (int i = 0; i <= brightnessLevel; ++i) {
      setBrightness(i);
      lv_task_handler();
      delay(30);
    }
  }

  // A quiet heartbeat. The USB CDC only talks while a host is listening, and a
  // periodic line makes "is the deck alive, and is the GPS up?" answerable
  // without having to catch the boot output.
  static uint32_t lastBeat = 0;
  if (millis() - lastBeat > 30000) {
    lastBeat = millis();
    deckLog("[deck] alive heap=%u room=%s gps=%d",
            (unsigned)ESP.getFreeHeap(), jw_room.c_str(), (int)gpsReady);
  }
}

void readRadio() {
  if (loraChatReceiver) {
    if (operationDone) {
      operationDone = false;
      String str;
      int state = radio.readData(str);
      if (state == RADIOLIB_ERR_NONE) {
        radio.startReceive();

        JSONVar js = JSON.parse(str);
        Serial.println(str);
        String msg_check = (const char *)js["msg"];
        String ssid_check = (const char *)js["ap_ssid"];
        String chat_check = (const char *)js["m"];
        if (chat_check != "") {
          String username = js["u"];
          String message = js["m"];
          long timestamp = rightNow();
          chat_text_writer(username, message, timestamp);

          Serial.println(str);
          if (authorization != "") {
            String request = "https://" + homebaseIP + "/watch/chat_received?message=" + urlEncode(message) + "&username=" + urlEncode(username);
            String jawnnformation = https_request(request);
            Serial.println(jawnnformation);
          }
        }
        else if (ssid_check != "") {
          Serial.println("Got an ssid " + ssid_check);
          ssid = (const char *)js["ap_ssid"];
          password = (const char *)js["ap_password"];

          webserver_enabled = true;
          wifi_server();
          delay(1000);
          // Serial.print("Transmitting...");

          JSONVar returner;
          returner["time"] = rtc.getLocalEpoch();
          String returns = JSON.stringify(returner);
          //   radio.startTransmit(returns);
          //   Serial.println(returns);
          //   delay(1000);
        }
        else if (msg_check != "") {
          String app = (const char *)js["app"];
          Serial.println(app);
          Serial.println("Got a message: " + msg_check);
          JSONVar result = JSON.parse(https_request(
                                        "https://" + homebaseIP +
                                        "/watch/telephone_msg?timestamp=" + rtc.getLocalEpoch() +
                                        "&msg=" + msg_check + "&app=" + app
                                      ));
          String rs = JSON.stringify(result);
          Serial.println(rs);
        }
      }
    }
  }
}
void display_exit( void ) {
  lv_obj_clean ( lv_scr_act() ); // Clean objects from current screen.
  lv_obj_invalidate( lv_scr_act() ); // Invalidate objects for redraw.
  button_writer();
  //  time_writer("now");
}

String chip_id_maker() {
  uint32_t chipId = 0;
  for(int i=0; i<17; i=i+8) {
    chipId |= ((ESP.getEfuseMac() >> (40 - i)) & 0xff) << i;
  }
  String chip_id = String(chipId);
  return chip_id;
}

void time_writer(char * situation) {

  if (situation == "now" || jw_room != "watch") {
    // tft.fillScreen(TFT_YELLOW);
    jw_room = "watch";
  }
  if (millis() - lastMillis > 1000 || situation == "now") {
    lastMillis = millis();
    time_t now;
    struct tm  timeinfo;
    time(&now);
    localtime_r(&now, &timeinfo);

    char datetime[128] = {0};
    snprintf(datetime, 128, "%d/%d/%d %d:%d:%d", timeinfo.tm_year + 1900, timeinfo.tm_mon + 1, timeinfo.tm_mday, timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec);

    // Get the time C library structure
    //    tft.getDateTime(&timeinfo);
    size_t written_date = strftime(bufdate, 64, "%a %b %d %Y", &timeinfo);
    size_t written_time = strftime(buftime, 64, "%H:%M", &timeinfo);
    size_t written_sec = strftime(bufsec, 64, "%S", &timeinfo);
    tft.setTextFont(2);
    tft.setTextColor(TFT_YELLOW, TFT_BLACK);
    if (written_date != 0) {
      tft.drawString(bufdate, 10, 10);
    }
    if (written_time != 0) {
      tft.setTextFont(6);
      tft.drawString(buftime, 10, 25);
    }
    if (written_sec != 0) {

      tft.setTextFont(2);
      tft.drawString(bufsec, 10, 70);
    }
    tft.setCursor(10, 100);
    tft.print(gps.location.lat(), 6);
    tft.setCursor(10, 120);
   // tft.print( lngPrint );
    tft.print(gps.location.lng(), 6);
    tft.setCursor(10,140);
    tft.print(gps.altitude.meters(), 6);
  }
}


void setupLvgl()
{
  static lv_color_t *buf = (lv_color_t *)ps_malloc(LVGL_BUFFER_SIZE);
  if (!buf) {
    // Serial.println("menory alloc failed!");
    delay(5000);
    assert(buf);
  }
  lv_init();
  lv_tick_set_cb(millis);

  lv_group_set_default(lv_group_create());

  /*Initialize the display*/
  lv_display_t *disp = lv_display_create(TFT_HEIGHT, TFT_WIDTH);
  lv_display_set_flush_cb(disp, disp_flush);
  lv_display_set_buffers(disp, buf, NULL, LVGL_BUFFER_SIZE, LV_DISPLAY_RENDER_MODE_FULL);

  /*Initialize the  input device driver*/
  /*Register a touchscreen input device*/
  if (touchDected) {
    touch_indev = lv_indev_create();
    lv_indev_set_type(touch_indev, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(touch_indev, touchpad_read);
  }
  if (kbDected) {
    Serial.println("Keyboard registered!!");
    /*Register a keypad input device*/
    kb_indev = lv_indev_create();
    lv_indev_set_type(kb_indev, LV_INDEV_TYPE_KEYPAD);
    lv_indev_set_read_cb(kb_indev, keypad_read);
    lv_indev_set_group(kb_indev, lv_group_get_default());
  }
}

// Read key value from esp32c3
char keypad_get_key(void)
{
  char key_ch = 0;
  Wire.requestFrom(0x55, 1);
  while (Wire.available() > 0) {
    key_ch = Wire.read();
  }
  return key_ch;
}

void fontLoader() {
  if (fontSelect == "Latin") {
    tft.loadFont(Latin_Hiragana_24);
  }
  else if (fontSelect == "Unicode") {
    tft.loadFont(Unicode_Test_72);
  }
  else if (fontSelect == "Noto Small") {
    tft.loadFont(AA_FONT_SMALL); // Load another different font
  }
  else if (fontSelect == "Noto Large") {
    tft.loadFont(AA_FONT_LARGE); // Load another different font
  }
  else if (fontSelect == "Final Frontier") {
    tft.loadFont(Final_Frontier_28);
  }
  else if (fontSelect == "Basic") {
    tft.unloadFont();
  }
  tft.setTextFont(fontSize);
  tft.setTextWrap(true, true);
}

void fontUnloader() {
  if (fontSelect != "") {
    tft.unloadFont();
  }
}
/*Will be called by the library to read the mouse*/
static void keypad_read(lv_indev_t *indev_drv, lv_indev_data_t *data)
{
  static uint32_t last_key = 0;
  char keyValue;
  keyValue = keypad_get_key();
  if (keyValue != 0) {
    fontLoader();
    char buf[256] = {0};
    data->state = LV_INDEV_STATE_PR;
    buttonMillis = millis();
    Serial.println(keyValue);
    last_key = keyValue;
    long timestamp = rtc.getLocalEpoch() - rtc.offset;
    JSONVar president;
    if (buttoned_before) {
      president = JSON.parse(before_me);
    }
    if (troom != "typewriter") {
      if (jw_room == "room") {
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["typewriter_background_colour_rgb"][0], president["__specs"]["typewriter_background_colour_rgb"][1], president["__specs"]["typewriter_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_BLACK);
        }
      }
      else if (jw_room == "chat") {
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["chat_background_colour_rgb"][0], president["__specs"]["chat_background_colour_rgb"][1], president["__specs"]["chat_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_WHITE);
        }
      }
      else if (jw_room == "pen") {
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["pen_background_colour_rgb"][0], president["__specs"]["pen_background_colour_rgb"][1], president["__specs"]["pen_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_WHITE);
        }
      }
    }
    if (jw_room == "room") {
      // Serial.print("keyvalue: ");
      // Serial.println(keyValue);
      tauth_connect();

      JSONVar wsdata;
      wsdata["timestamp"] = timestamp;
      wsdata["key"] = keyValue;
      wsdata["command"] = "keypress";
      String jsonwsdata = JSON.stringify(wsdata);
      if (troom == "typewriter" && (textarea_content.length() >= 0)) {
        wsclient.send(jsonwsdata);
      }

      if (keyValue == (char)0x08) {
        int lastIndex = textarea_content.length() - 1;
        textarea_content.remove(lastIndex);
        // Serial.println(textarea_content);
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["typewriter_background_colour_rgb"][0], president["__specs"]["typewriter_background_colour_rgb"][1], president["__specs"]["typewriter_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_YELLOW);
        }

      }
      else if (keyValue == (char)0x0D) {
        if (authorization != "") {
          // Serial.println("Enter pressed");
          String life = "";
          if (tauthorization == "") {
            tauthorization = textarea_content + "&first_check=true";
          }
          else {
            life = urlEncode(textarea_content);
          }
          // Serial.println(homebase);
          String information = https_request("https://" + thomebaseIP + "/teletype/information?life=" + life);
           Serial.println(information);

          textarea_content = "";
          JSONVar info = JSON.parse(information);
          // Serial.println(info["tty_port"]);
          int y = tft.getCursorY() + 26;
          tft.setCursor(0, y);
          String result = info["result"];
          String returner = info["returner"];
          if (result == "denial") {
            tauthorization = "";
            //    Serial.println("Clearing Auth");
          }
          else {
            String auth = info["tauthorization"];
            tauthorization_pusher(auth);
            //    Serial.println("Setting Auth");
          }
          tauth_connect();
          tft.drawString("P: " + returner, 0, y);

          long server_time = info["server_time"];
          long offset = info["offset"];
          rtc.offset = offset;
          rtc.setTime(server_time + offset);
        }
        else {
          int y = tft.getCursorY() + 26;
          tft.setCursor(0, y);
          tft.drawString("T: I on't curr", 0, y);
        }

      }
      else if (troom != "typewriter") {
        troom = "typewriter";
        // textarea_content = textarea_content + keyValue;
      }
      else {
        textarea_content = textarea_content + keyValue;
      }
      if (buttoned_before) {
        tft.setTextColor(tft.color565(president["__specs"]["typewriter_text_colour_rgb"][0], president["__specs"]["typewriter_text_colour_rgb"][1], president["__specs"]["typewriter_text_colour_rgb"][2]), tft.color565(president["__specs"]["typewriter_background_colour_rgb"][0], president["__specs"]["typewriter_background_colour_rgb"][1], president["__specs"]["typewriter_background_colour_rgb"][2]));
      }
      else {
        tft.setTextColor(TFT_WHITE, TFT_BLACK);
      }
      tft.setCursor(5, 5);
      tft.print( textarea_content );
    }
    else if (jw_room == "chat") {
      if (keyValue == (char)0x08) {
        int lastIndex = textarea_content.length() - 1;
        textarea_content.remove(lastIndex);
        // Serial.println(textarea_content);
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["chat_background_colour_rgb"][0], president["__specs"]["chat_background_colour_rgb"][1], president["__specs"]["chat_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_BLACK);
        }

      }
      else if (keyValue == (char)0x0D) {
        Serial.println("Enter pressed");
        String message = urlEncode(textarea_content);
        long timestamp = rightNow();
        chat_text_writer(computer_name, textarea_content, timestamp);
        if (authorization != "") {
          String request = "https://" + homebaseIP + "/watch/chat_received?message=" + message + "&username=" + urlEncode(computer_name)
                           + "&community=" + urlEncode(community_room) + "&club=" + urlEncode(club_room) + "&team=" + urlEncode(team_room) + "&account=" + urlEncode(account_room)
                           + "&project=" + urlEncode(project_room) + "&contact=" + urlEncode(contact_room) + "&person=" + urlEncode(person_room);
          Serial.println(request);
          String information = https_request(request);
          Serial.println(information);
          JSONVar info = JSON.parse(information);
          String returner = info["returner"];
        }
        loraChatBroadcast(computer_name, textarea_content, timestamp);
        textarea_content = "";
      }
      else if (troom != "typewriter") {
        troom = "typewriter";
        //  textarea_content = textarea_content + keyValue;
      }
      else {
        textarea_content = textarea_content + keyValue;
      }
      if (buttoned_before) {
        tft.setTextColor(tft.color565(president["__specs"]["chat_text_colour_rgb"][0], president["__specs"]["chat_text_colour_rgb"][1], president["__specs"]["chat_text_colour_rgb"][2]), tft.color565(president["__specs"]["chat_background_colour_rgb"][0], president["__specs"]["chat_background_colour_rgb"][1], president["__specs"]["chat_background_colour_rgb"][2]));
      }
      else {
        tft.setTextColor(TFT_BLACK, TFT_WHITE);
      }
      tft.setCursor(5, 5);
      tft.print( textarea_content );
    }

    else if (jw_room == "pen") {
      if (keyValue == (char)0x08) {
        int lastIndex = textarea_content.length() - 1;
        textarea_content.remove(lastIndex);
        // Serial.println(textarea_content);
        if (buttoned_before) {
          tft.fillScreen(tft.color565(president["__specs"]["pen_background_colour_rgb"][0], president["__specs"]["pen_background_colour_rgb"][1], president["__specs"]["pen_background_colour_rgb"][2]));
        }
        else {
          tft.fillScreen(TFT_YELLOW);
        }
      }
      else if (keyValue == (char)0x0D) {
        Serial.println("Enter pressed");
        String message = urlEncode(textarea_content);
        long timestamp = rightNow();
        chat_text_writer("Me", textarea_content, timestamp);

        if (authorization != "") {
          textarea_content = "";

          String request = "https://" + homebaseIP + "/teletype/pen?message=" + message + "&username=" + urlEncode(computer_name);
          Serial.println(request);
          String information = https_request(request);
          Serial.println(information);
          JSONVar info = JSON.parse(information);
          timestamp = rightNow();
          chat_text_writer("Pen", info["message"], timestamp);
        }

      }
      else if (troom != "typewriter") {
        troom = "typewriter";
        //  textarea_content = textarea_content + keyValue;
      }
      else {
        textarea_content = textarea_content + keyValue;
      }
      if (buttoned_before) {
        tft.setTextColor(tft.color565(president["__specs"]["pen_text_colour_rgb"][0], president["__specs"]["pen_text_colour_rgb"][1], president["__specs"]["pen_text_colour_rgb"][2]), tft.color565(president["__specs"]["pen_background_colour_rgb"][0], president["__specs"]["pen_background_colour_rgb"][1], president["__specs"]["pen_background_colour_rgb"][2]));
      }
      else {
        tft.setTextColor(TFT_BLUE, TFT_YELLOW);
      }
      tft.setCursor(5, 5);
      tft.print( textarea_content );
    }
    fontUnloader();
  }
  else {
    data->state = LV_INDEV_STATE_REL;
  }
  data->key = last_key;
}

void loraChatBroadcast(String computer_name, String body, long timestamp) {
  if (loraBroadcastToggle) {
    JSONVar msg;
    msg["u"] = computer_name;
    msg["m"] = body;

    String returns = JSON.stringify(msg);
    Serial.println(returns);
    radio.startTransmit(returns);
    Serial.println("transmitted");
    // delay(2000);
    //   radio.startReceive();
    Serial.println("back to listening");
  }
}

long rightNow() {
  long timestamp = rtc.getLocalEpoch() - rtc.offset;

  return timestamp;
}

void https_download(fs::FS &fs, String url, String filename) {
  url = url_maker(url);
  Serial.println("In the https download");
  Serial.println("writing to " + filename);
  deleteFile(fs, filename.c_str());

  Serial.println(url);
  connexion -> setInsecure();
  if (connexion) {
    {
      if (https.begin(*connexion, url)) {

        int httpCode = https.GET();
        Serial.println("Did a get");
        Serial.println(httpCode);
        if (httpCode > 0) {

          if (httpCode == HTTP_CODE_OK) {
            //  writeFile(FFat, filename.c_str(), "");

            int len = https.getSize();
            Serial.println(len);
            uint8_t buff[128] = { 0 };
            WiFiClient * stream = https.getStreamPtr();
            while (https.connected() &&  (len > 0 || len == -1)) {
              // read up to 128 byte
              size_t size = stream->available();
              if (size) {
                int c = stream->readBytes(buff, ((size > sizeof(buff)) ? sizeof(buff) : size));
              //  Serial.println(size);
                // write it to Serial
                //  Serial.write(buff, c);
                appendFile(fs, filename.c_str(), (char *) buff);
                if (len > 0) {
                  len -= c;
                }
              }
            }
            
          }
        }
      }
      https.end();
      Serial.println("Done downloading");
    }
  }
}

String url_maker(String url) {
  long timestamp = rtc.getLocalEpoch() - rtc.offset;
  String chip_id = chip_id_maker();
  url = url + "&edt=teletype&chip_id=" + chip_id + "&tauthorization=" + tauthorization + "&authorization=" + authorization + "&timestamp=" + timestamp;
  return url;
}


String https_request(String url) {
  url = url_maker(url);
  Serial.println("In the https request");
  Serial.println(url);
  WiFiClientSecure *connexion = new WiFiClientSecure;
  connexion -> setInsecure();
  if (connexion) {
    {
      HTTPClient https;
       Serial.println("Starting connexion");
      if (https.begin(*connexion, url)) {
         Serial.println("Right after connexion");
        int httpCode = https.GET();
        Serial.println(httpCode);
        if (httpCode > 0) {

          if (httpCode == HTTP_CODE_OK) {
            String payload = https.getString();
            return payload;
          }
        }
        else {
          Serial.printf("HTTPS FAILED error: %s\n", https.errorToString(httpCode).c_str());
          writeFile(FFat, "/bootreport.txt", "failure");

          return "failure";
        }
        https.end();
      }
    }
  }
  return "failure";
}


void setBrightness(uint8_t value)
{
  static uint8_t level = 0;
  static uint8_t steps = 16;
  currentBrightness = value;
  if (value != 0) {
    lastBrightness = value;
  }
  if (value == 0) {
    digitalWrite(BOARD_BL_PIN, 0);
    delay(3);
    level = 0;
    return;
  }
  if (level == 0) {
    digitalWrite(BOARD_BL_PIN, 1);
    level = steps;
    delayMicroseconds(30);
  }
  int from = steps - level;
  int to = steps - value;
  int num = (steps + to - from) % steps;
  for (int i = 0; i < num; i++) {
    digitalWrite(BOARD_BL_PIN, 0);
    digitalWrite(BOARD_BL_PIN, 1);
  }
  level = value;
}

static void disp_flush(lv_display_t *disp, const lv_area_t *area, uint8_t *px_map)
{
  uint32_t w = ( area->x2 - area->x1 + 1 );
  uint32_t h = ( area->y2 - area->y1 + 1 );
  if ( xSemaphoreTake( xSemaphore, portMAX_DELAY ) == pdTRUE ) {
    tft.startWrite();
    tft.setAddrWindow( area->x1, area->y1, w, h );
    tft.pushColors( ( uint16_t * )px_map, w * h, false );
    tft.endWrite();
    lv_display_flush_ready( disp );
    xSemaphoreGive( xSemaphore );
  }
}

static bool getTouch(int16_t &x, int16_t &y)
{
  uint8_t rotation = tft.getRotation();
  if (!touch->read()) {
    return false;
  }
  TP_Point t = touch->getPoint(0);
  switch (rotation) {
    case 1:
      x = t.y;
      y = tft.height() - t.x;
      break;
    case 2:
      x = tft.width() - t.x;
      y = tft.height() - t.y;
      break;
    case 3:
      x = tft.width() - t.y;
      y = t.x;
      break;
    case 0:
    default:
      x = t.x;
      y = t.y;
  }
  // Serial.printf("R:%d X:%d Y:%d\n", rotation, x, y);
  buttonMillis = millis();

  return true;
}

static void mouse_read(lv_indev_t *indev, lv_indev_data_t *data)
{
  // Serial.println("mouse read");
  static  int16_t last_x;
  static int16_t last_y;
  bool left_button_down = false;
  const uint8_t dir_pins[5] = {1, 2, 3, 15, 0
                              };
  static bool last_dir[5];
  uint8_t pos = 10;
  for (int i = 0; i < 5; i++) {
    bool dir = digitalRead(dir_pins[i]);
    if (dir != last_dir[i]) {
      last_dir[i] = dir;
    }
  }
  // Serial.printf("indev:X:%04d  Y:%04d \n", last_x, last_y);
  /*Store the collected data*/
  data->point.x = last_x;
  data->point.y = last_y;
  data->state = left_button_down ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;

}
/*Read the touchpad*/
static void touchpad_read( lv_indev_t *indev_driver, lv_indev_data_t *data )
{
  if (troom == "home") {
    int16_t x = data->point.x;
    int16_t y = data->point.y;
    data->state = getTouch(x, y) ? LV_INDEV_STATE_PR : LV_INDEV_STATE_REL;
  }
}

void scanDevices(TwoWire * w)
{
  uint8_t err, addr;
  int nDevices = 0;
  uint32_t start = 0;
  for (addr = 1; addr < 127; addr++) {
    start = millis();
    w->beginTransmission(addr); delay(2);
    err = w->endTransmission();
    if (err == 0) {
      nDevices++;
      // Serial.print("I2C device found at address 0x");
      if (addr < 16) {
        // Serial.print("0");
      }
      //Serial.print(addr, HEX);
      //Serial.println(" !");

      if (addr == GT911_SLAVE_ADDRESS2) {
        touchAddress = GT911_SLAVE_ADDRESS2;
        // Serial.println("Find GT911 Drv Slave address: 0x14");
      } else if (addr == GT911_SLAVE_ADDRESS1) {
        touchAddress = GT911_SLAVE_ADDRESS1;
        //  Serial.println("Find GT911 Drv Slave address: 0x5D");
      }
    } else if (err == 4) {
      //Serial.print("Unknow error at address 0x");
      if (addr < 16) {
        //Serial.print("0");
      }
      //   Serial.println(addr, HEX);
    }
  }
  if (nDevices == 0) {
    //  Serial.println("No I2C devices found\n");
  }
}


void button_writer() {
  btn1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn1, touch_button1, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn1, 10, 200 );
  lv_obj_set_size(btn1, 40, 40 );
  lv_obj_set_style_bg_color(btn1, lv_color_hex(0xde2716), LV_PART_MAIN);

  lv_obj_t *l1;
  lv_color_t t1;
  t1 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn1, t1, LV_PART_MAIN);
  l1 = lv_label_create(btn1);
  lv_label_set_text(l1, "Rom");
  lv_obj_center(l1);


  btn2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn2, touch_button2, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn2, 60, 200 );
  lv_obj_set_size(btn2, 40, 40 );
  lv_obj_set_style_bg_color(btn2, lv_color_hex(0xffca38), LV_PART_MAIN);

  lv_obj_t *l2;
  lv_color_t t2;
  t2 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn2, t2, LV_PART_MAIN);
  l2 = lv_label_create(btn2);
  lv_label_set_text(l2, "Clk");
  lv_obj_center(l2);

  btn3 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn3, touch_button3, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn3, 110, 200 );
  lv_obj_set_size(btn3, 40, 40 );
  lv_obj_set_style_bg_color(btn3, lv_color_hex(0xfa3ced), LV_PART_MAIN);

  lv_obj_t *l3;
  lv_color_t t3;
  t3 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn3, t3, LV_PART_MAIN);
  l3 = lv_label_create(btn3);
  lv_label_set_text(l3, "Set");
  lv_obj_center(l3);

  btn4 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn4, touch_button4, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn4, 160, 200 );
  lv_obj_set_size(btn4, 40, 40 );
  lv_obj_set_style_bg_color(btn4, lv_color_hex(0xba3c2d), LV_PART_MAIN);

  lv_obj_t *l4;
  lv_color_t t4;
  t4 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn4, t4, LV_PART_MAIN);
  l4 = lv_label_create(btn4);
  lv_label_set_text(l4, "Cht");
  lv_obj_center(l4);

  btn5 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn5, touch_button5, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn5, 210, 200 );
  lv_obj_set_size(btn5, 40, 40 );
  lv_obj_set_style_bg_color(btn5, lv_color_hex(0xca1c2d), LV_PART_MAIN);

  lv_obj_t *l5;
  lv_color_t t5;
  t5 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn5, t5, LV_PART_MAIN);
  l5 = lv_label_create(btn5);
  lv_label_set_text(l5, "Pen");
  lv_obj_center(l5);

  btn6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn6, touch_button6, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn6, 260, 200 );
  lv_obj_set_size(btn6, 40, 40 );
  lv_obj_set_style_bg_color(btn6, lv_color_hex(0x1aacfd), LV_PART_MAIN);

  lv_obj_t *l6;
  lv_color_t t6;
  t6 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn6, t6, LV_PART_MAIN);
  l6 = lv_label_create(btn6);
  lv_label_set_text(l6, "Net");
  lv_obj_center(l6);

  lv_task_handler();
}

void call_the_president() {
  //  Serial.println("dans presidente");
  //  Serial.println(before_me);
  //  Serial.println("copy");
  JSONVar result;
  Serial.print("bb: " );
  Serial.println(buttoned_before);
  if (!buttoned_before && homebaseIP != "") {
    String req = "https://" + homebaseIP + "/watch?room=" + room;
    Serial.println(req);
    String watchRequest = https_request(req);
    Serial.println(watchRequest);
    if (watchRequest != "failure") {
      before_me = watchRequest;
      buttoned_before = true;
    }
    else {
      //    writeFile(FFat, "/bootreport.txt", "failed");

    }
  }
  else {
    //  Serial.print("running first timer");
  }
  if (jw_room == "room") {
    // remote_room();
  }

  //Serial.println(before_me);
}

void presidents_title() {
  tft.setTextFont(4);

  tft.setTextColor(TFT_YELLOW, TFT_BLACK);
  tft.drawString(computer_name, 10, 2);
  tft.setTextFont(2);

  tft.drawString(homebaseIP, 180, 2);
}

void presidents_buttons() {
  JSONVar result;
  lv_obj_t * led1  = lv_led_create(lv_scr_act());
  lv_obj_set_pos(led1, 90, 160 );
  lv_led_set_color(led1, lv_palette_main(LV_PALETTE_RED));
  lv_obj_t * led2  = lv_label_create(lv_scr_act());
  lv_obj_set_pos(led2, 120, 160 );
  lv_obj_set_style_text_color(led2, lv_palette_main(LV_PALETTE_GREEN), LV_PART_MAIN); 
  lv_led_off(led1);
  if (!buttoned_before) {
    tft.drawString("Ne pas Presidente", 80, 80);
    lv_led_off(led1);
    return;
  }
  else {
    result = JSON.parse(before_me);
  }
  if (wigi.length() > 0) {
    lv_led_on(led1);
    int wl = wigi.length();
    char wil[4];
    itoa( wl, wil, 10 );
    lv_label_set_text(led2, wil);
  } 
  else {
    lv_label_set_text(led2, "0");
  }

  Serial.println(before_me);
  Serial.println(buttoned_before);
  if (room > room_count) { room = 1; }  

  int sb = ((room - 1) * 8) + 1;
  computer_name = (const char *)result["__specs"]["computer"];
  //Serial.println(room);
  //Serial.println(sb);
  lv_obj_t * b1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b1, mb1, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b1, 10, 20 );
  lv_obj_set_size(b1, 60, 60 );
  lv_color_t c1;
  lv_color_t t1;
  int tog1 = result["b" + String(sb)]["toggle"];

  if (tog1 == 1) {
    t1 = lv_color_make(0, 0, 0);
    c1 = lv_color_make(255, 255, 0);
  }
  else {
    c1 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t1 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b1, t1, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b1, c1, LV_PART_MAIN);
  lv_obj_t *l1;
  l1 = lv_label_create(b1);
  lv_label_set_text(l1, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l1, LV_LABEL_LONG_WRAP);
  lv_obj_center(l1);

  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b1_toggle);
  lv_obj_t * b2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b2, mb2, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b2, 90, 20 );
  lv_obj_set_size(b2, 60, 60 );
  lv_color_t c2;
  lv_color_t t2;
  int tog2 = result["b" + String(sb)]["toggle"];

  if (tog2 == 1) {
    t2 = lv_color_make(0, 0, 0);
    c2 = lv_color_make(255, 255, 0);
  }
  else {
    c2 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t2 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_bg_color(b2, c2, LV_PART_MAIN);
  lv_obj_set_style_text_color(b2, t2, LV_PART_MAIN);
  lv_obj_t *l2;
  l2 = lv_label_create(b2);
  lv_label_set_text(l2, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l2, LV_LABEL_LONG_WRAP);

  lv_obj_center(l2);

  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b2_toggle);
  lv_obj_t * b3 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b3, mb3, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b3, 170, 20 );
  lv_obj_set_size(b3, 60, 60 );
  lv_color_t c3;
  lv_color_t t3;
  int tog3 = result["b" + String(sb)]["toggle"];

  if (tog3 == 1) {
    t3 = lv_color_make(0, 0, 0);
    c3 = lv_color_make(255, 255, 0);
  }
  else {
    c3 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t3 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b3, t3, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b3, c3, LV_PART_MAIN);
  lv_obj_t *l3;
  l3 = lv_label_create(b3);
  lv_label_set_text(l3, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l3, LV_LABEL_LONG_WRAP);
  lv_obj_center(l3);

  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b3_toggle);
  lv_obj_t * b4 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b4, mb4, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b4, 250, 20 );
  lv_obj_set_size(b4, 60, 60 );
  lv_color_t c4;
  lv_color_t t4;
  int tog4 = result["b" + String(sb)]["toggle"];

  if (tog4 == 1) {
    t4 = lv_color_make(0, 0, 0);
    c4 = lv_color_make(255, 255, 0);
  }
  else {
    c4 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t4 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b4, t4, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b4, c4, LV_PART_MAIN);
  lv_obj_t *l4;
  l4 = lv_label_create(b4);
  lv_label_set_text(l4, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l4, LV_LABEL_LONG_WRAP);
  lv_obj_center(l4);

  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b4_toggle);
  lv_obj_t * b5 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b5, mb5, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b5, 10, 90 );
  lv_obj_set_size(b5, 60, 60 );
  lv_color_t c5;
  lv_color_t t5;
  int tog5 = result["b" + String(sb)]["toggle"];

  if (tog5 == 1) {
    t5 = lv_color_make(0, 0, 0);
    c5 = lv_color_make(255, 255, 0);
  }
  else {
    t5 = lv_color_make(255, 255, 255);
    c5 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
  }
  lv_obj_set_style_text_color(b5, t5, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b5, c5, LV_PART_MAIN);
  lv_obj_t *l5;
  l5 = lv_label_create(b5);
  lv_label_set_text(l5, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l5, LV_LABEL_LONG_WRAP);
  lv_obj_center(l5);

  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b5_toggle);
  //Serial.println("b" + String(sb));
  lv_obj_t * b6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b6, mb6, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b6, 90, 90 );
  lv_obj_set_size(b6, 60, 60 );
  lv_color_t c6;
  lv_color_t t6;
  //Serial.println(result["b" + String(sb)]["toggle"]);
  int tog6 = result["b" + String(sb)]["toggle"];
  if (tog6 == 1) {
    c6 = lv_color_make(255, 255, 0);
    t6 = lv_color_make(0, 0, 0);
  }
  else {
    c6 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t6 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_bg_color(b6, c6, LV_PART_MAIN);
  lv_obj_set_style_text_color(b6, t6, LV_PART_MAIN);

  lv_obj_t *l6;
  l6 = lv_label_create(b6);
  lv_label_set_text(l6, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l6, LV_LABEL_LONG_WRAP);
  lv_obj_center(l6);


  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b6_toggle);
  //Serial.println("b" + String(sb));
  lv_obj_t * b7 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b7, mb7, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b7, 170, 90 );
  lv_obj_set_size(b7, 60, 60 );
  lv_color_t c7;
  lv_color_t t7;
  //Serial.println(result["b" + String(sb)]["toggle"]);
  int tog7 = result["b" + String(sb)]["toggle"];
  if (tog7 == 1) {
    c7 = lv_color_make(255, 255, 0);
    t7 = lv_color_make(0, 0, 0);
  }
  else {
    c7 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t7 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_bg_color(b7, c7, LV_PART_MAIN);
  lv_obj_set_style_text_color(b7, t7, LV_PART_MAIN);

  lv_obj_t *l7;
  l7 = lv_label_create(b7);
  lv_label_set_long_mode(l7, LV_LABEL_LONG_WRAP);
  lv_label_set_text(l7, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l7);


  sb = sb + 1;
  //Serial.println(sb + ' toggle:' + b8_toggle);
  //Serial.println("b" + String(sb));
  lv_obj_t * b8 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b8, mb8, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b8, 250, 90 );
  lv_obj_set_size(b8, 60, 60 );
  lv_color_t c8;
  lv_color_t t8;
  //Serial.println(result["b" + String(sb)]["toggle"]);
  int tog8 = result["b" + String(sb)]["toggle"];
  if (tog8 == 1) {
    c8 = lv_color_make(255, 255, 0);
    t8 = lv_color_make(0, 0, 0);
  }
  else {
    c8 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t8 = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_bg_color(b8, c8, LV_PART_MAIN);
  lv_obj_set_style_text_color(b8, t8, LV_PART_MAIN);

  lv_obj_t *l8;
  l8 = lv_label_create(b8);
  lv_label_set_text(l8, result["b" + String(sb)]["shorthand_name"]);
  lv_label_set_long_mode(l8, LV_LABEL_LONG_WRAP);
  lv_obj_center(l8);
  lv_task_handler();

}

static void touch_button1(lv_event_t *e) {
  if (jw_room == "room") {
    if (room == room_count) {
      room = 1;
    }
    else {
      room++;
    }
  }
  remote_room();
}

void remote_room() {
  jw_room = "room";
  display_exit();
  call_the_president();
  presidents_buttons();
  remote_writer();
  presidents_title();
}
void when_i_get_in(JSONVar wigi_item) {
  
  int l = wigi.length();
  if (l < 0) {
    l = 0;
  }
  long timestamp = rtc.getLocalEpoch() - rtc.offset;  
  wigi_item["timestamp"] = timestamp;
  int room = wigi_item["room"];
  int button = wigi_item["button"];
  
  JSONVar bm = JSON.parse(before_me);
  
  int rooming = (((room - 1 ) * room_max) + button);
  String roomings = String(rooming);
  JSONVar buttonski = bm["b" + roomings];
  String bs = JSON.stringify(buttonski);
  
  String movement = (const char *)buttonski["movement"];
  int toggle = buttonski["toggle"];
  
  if (movement == "start") {
    if (toggle == 1) {
      bm["b" + roomings]["toggle"] = 0;
    }
    else {
      bm["b" + roomings]["toggle"] = 1;
    }
    before_me = JSON.stringify(bm);
    presidents_buttons();
  }


  wigi[l] = wigi_item;
}

void mb1(lv_event_t *e) {
  if (b1_toggle == 0) {
    b1_toggle = 1;
  } else {
    b1_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=1&toggle=" + b1_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 1;
    updater["toggle"] = b1_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  b1_toggle = result["toggle"];

  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b1_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);

  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 1)] = result;
  before_me = JSON.stringify(bm);

}
void mb2(lv_event_t *e) {
  if (b2_toggle == 0) {
    b2_toggle = 1;
  } else {
    b2_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=2&toggle=" + b2_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 2;
    updater["toggle"] = b2_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  b2_toggle = result["toggle"];
  lv_color_t c;
  lv_color_t t;
  lv_obj_t * b = lv_event_get_target_obj(e);
  if (b2_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 2)] = result;
  before_me = JSON.stringify(bm);
}
void mb3(lv_event_t *e) {
  if (b3_toggle == 0) {
    b3_toggle = 1;
  } else {
    b3_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=3&toggle=" + b3_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 3;
    updater["toggle"] = b3_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  b3_toggle = result["toggle"];
  //Serial.println(b3_toggle);
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b3_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);

  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 3)] = result;
  before_me = JSON.stringify(bm);
}
void mb4(lv_event_t *e) {
  if (b4_toggle = 0) {
    b4_toggle = 1;
  } else {
    b4_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=4&toggle=" + b4_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 4;
    updater["toggle"] = b4_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  b4_toggle = result["toggle"];
  lv_color_t c;
  lv_color_t t;
  lv_obj_t * b = lv_event_get_target_obj(e);
  if (b4_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 4)] = result;
  before_me = JSON.stringify(bm);

}
void mb5(lv_event_t *e) {
  if (b5_toggle == 0) {
    b5_toggle = 1;
  } else {
    b5_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=5&toggle=" + b5_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 5;
    updater["toggle"] = b5_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b5_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 5)] = result;
  before_me = JSON.stringify(bm);
}
void mb6(lv_event_t *e) {
  if (b6_toggle == 0) {
    b6_toggle = 1;
  } else {
    b6_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=6&toggle=" + b6_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 6;
    updater["toggle"] = b6_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  b6_toggle = result["toggle"];
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b6_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 8)] = result;
  before_me = JSON.stringify(bm);
}
void mb7(lv_event_t *e) {
  if (b7_toggle == 0) {
    b7_toggle = 1;
  } else {
    b7_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=7&toggle=" + b7_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 7;
    updater["toggle"] = b7_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  b7_toggle = result["toggle"];
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b7_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 7)] = result;
  before_me = JSON.stringify(bm);
}
void mb8(lv_event_t *e) {
  if (b8_toggle == 0) {
    b8_toggle = 1;
  } else {
    b8_toggle = 0;
  }
  String https = https_request(
    "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=8&toggle=" + b8_toggle
  );
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 8;
    updater["toggle"] = b8_toggle;
    when_i_get_in(updater);
    return;
  }
  JSONVar result = JSON.parse(https);
  b8_toggle = result["toggle"];
  lv_obj_t * b = lv_event_get_target_obj(e);
  lv_color_t c;
  lv_color_t t;
  if (b8_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0, 0, 0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255, 255, 255);
  }
  lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 8)] = result;
  before_me = JSON.stringify(bm);
}

static void touch_button2(lv_event_t *e) {
  clock_writer();
}

void clock_writer() {
  //Serial.println("Started button2");
  jw_room = "watch";
  //Serial.println("Set Mode");


  display_exit();
  jw_room = "watch";
  // Serial.println("Display exited");
  delay(5);
  time_writer("now");
  // Serial.println("Done loop");
  delay(5);
  lastMillis = lastMillis - 1000;
  lv_task_handler();
}


static void touch_button3(lv_event_t *e) {
  setting_room();
}
void setting_room() {
  display_exit();
  jw_room = "configure";

  lv_obj_t *slider = lv_slider_create(lv_scr_act());
  lv_slider_set_value(slider, brightnessLevel, LV_ANIM_ON);
  lv_slider_set_range(slider, 1, 16);
  lv_obj_set_width(slider, 150);
  lv_obj_set_pos(slider, 10, 20);
  lv_obj_add_event_cb(slider, brightness_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
  lv_obj_t *slider2 = lv_slider_create(lv_scr_act());
  lv_obj_set_width(slider2, 150);
  lv_obj_set_pos(slider2, 10, 60);
  lv_slider_set_value(slider2, volumeLevel, LV_ANIM_ON);
  lv_slider_set_range(slider2, 0, 21);
  lv_obj_add_event_cb(slider2, volume_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

  lv_obj_t * btn10 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn10, configSaveButton, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn10, 110, 110 );
  lv_obj_set_size(btn10, 40, 40 );
  lv_obj_set_style_bg_color(btn10, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_task_handler();
  lv_obj_t *l10;
  lv_color_t t10;
  t10 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(btn10, t10, LV_PART_MAIN);
  l10 = lv_label_create(btn10);
  lv_label_set_text(l10, "cS");
  lv_obj_center(l10);

  lv_obj_t * btn20 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn20, configRestoreButton, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn20, 160, 110 );
  lv_obj_set_size(btn20, 40, 40 );
  lv_obj_set_style_bg_color(btn20, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_obj_t *l20;
  lv_color_t t20;
  t20 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(btn20, t20, LV_PART_MAIN);
  l20 = lv_label_create(btn20);
  lv_label_set_text(l20, "cR");
  lv_obj_center(l20);

  lv_obj_t * btn201 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn201, configDeleteButton, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn201, 210, 110 );
  lv_obj_set_size(btn201, 40, 40 );
  lv_obj_set_style_bg_color(btn201, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_obj_t *l201;
  lv_color_t t201;
  t201 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(btn201, t201, LV_PART_MAIN);
  l201 = lv_label_create(btn201);
  lv_label_set_text(l201, "cD");
  lv_obj_center(l201);

  lv_obj_t * btn1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn1, ap_lora_send, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn1, 260, 10 );
  lv_obj_set_size(btn1, 40, 40 );
  lv_obj_set_style_bg_color(btn1, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_task_handler();
  lv_obj_t *l1;
  lv_color_t t1;
  t1 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(btn1, t1, LV_PART_MAIN);
  l1 = lv_label_create(btn1);
  lv_label_set_text(l1, "LAP");
  lv_obj_center(l1);

  lv_obj_t * btn2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn2, wifi_lora_send, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn2, 260, 60 );
  lv_obj_set_size(btn2, 40, 40 );
  lv_obj_set_style_bg_color(btn2, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_obj_t *l2;
  lv_color_t t2;
  t2 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(btn2, t2, LV_PART_MAIN);
  l2 = lv_label_create(btn2);
  lv_label_set_text(l2, "LWI");
  lv_obj_center(l2);

  lv_obj_t * btn4 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn4, clear_typewriter, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn4, 260, 110 );
  lv_obj_set_size(btn4, 40, 40 );
  lv_obj_set_style_bg_color(btn4, lv_color_hex(0xd63a9b), LV_PART_MAIN);
  lv_obj_t *l4;
  lv_color_t t4;
  t4 = lv_color_make(0, 0, 0);
  lv_obj_set_style_text_color(btn4, t4, LV_PART_MAIN);
  l4 = lv_label_create(btn4);
  lv_label_set_text(l4, "Clr");
  lv_obj_center(l4);


  lv_obj_t * btn5 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn5, loraBroadcastToggle, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn5, 210, 10 );
  lv_obj_set_size(btn5, 40, 40 );
  if (loraChatBroadcaster == false) {
    lv_obj_set_style_bg_color(btn5, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(btn5, lv_color_hex(0x53ff24), LV_PART_MAIN);
  }
  lv_obj_t *l5;
  lv_obj_set_style_text_color(btn5, t4, LV_PART_MAIN);
  l5 = lv_label_create(btn5);
  lv_label_set_text(l5, "LB");
  lv_obj_center(l5);


  lv_obj_t * btn6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn6, loraReceiveToggle, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn6, 210, 60 );
  lv_obj_set_size(btn6, 40, 40 );
  if (loraChatReceiver == true) {
    lv_obj_set_style_bg_color(btn6, lv_color_hex(0x53ff24), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(btn6, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_t *l6;
  lv_obj_set_style_text_color(btn6, t4, LV_PART_MAIN);
  l6 = lv_label_create(btn6);
  lv_label_set_text(l6, "LR");
  lv_obj_center(l6);


  lv_obj_t *slider3 = lv_slider_create(lv_scr_act());
  lv_slider_set_value(slider3, fontSize, LV_ANIM_ON);
  lv_slider_set_range(slider3, 1, 6);
  lv_obj_set_width(slider3, 110);
  lv_obj_set_pos(slider3, 180, 170);
  lv_obj_add_event_cb(slider3, fontSizeChanger, LV_EVENT_VALUE_CHANGED, NULL);

  lv_obj_t * fontdd = lv_dropdown_create(lv_scr_act());
  lv_dropdown_set_options(fontdd,
                          "Basic\n"
                          "Noto Small\n"
                          "Noto Large\n"
                          "Final Frontier\n"
                          "Latin\n"
                          "Unicode\n"
                         );
  lv_dropdown_set_text(fontdd, fontSelect.c_str());
  lv_obj_add_event_cb(fontdd, fontPicker, LV_EVENT_VALUE_CHANGED, NULL);
  lv_obj_set_pos(fontdd, 10, 160 );
  lv_obj_set_size(fontdd, 160, 40 );
  lv_obj_set_style_bg_color(fontdd, lv_color_hex(0xda5dc4), LV_PART_MAIN);
  lv_obj_set_style_text_color(fontdd, t1, LV_PART_MAIN);


  lv_task_handler();
}

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
  radio.startTransmit(public_announcement);
  //Serial.print(public_announcement);
}


static void wifi_lora_send(lv_event_t *e) {

  JSONVar pa;
  pa["ap_ssid"] = ssid;
  pa["ap_password"] = password;
  String public_announcement = JSON.stringify(pa);
  radio.startTransmit(public_announcement);
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
  tauthorization = "";
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
      tauthorization = (const char *)bm["__specs"]["tauthorization"];
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

  //  room_max = bm["__specs"]["room_max"];
  room_count = bm["__specs"]["room_count"];
  computer_name = (const char *)bm["__specs"]["computer"];
  tauthorization = (const char *)bm["__specs"]["tauthorization"];
  mouse_move_relative = (const char * )bm["__specs"]["mouse_move_relative"];
  tauth_remote_enabled = (const char * )bm["__specs"]["tauth_remote_enabled"];

  if (tauth_remote_enabled == "on") {
    tauth_connect();
  }
  else {
    tauth_cancel();
  }
  room = 1;
  remote_room();
}

void authorization_pusher(String js) {
  auth_count++;
  if (auth_watch == 0) {
    auth_watch = 1;
  }
  room_count = 1;
  authorization_json[auth_count] = js;
  //Serial.println("Pushing auth " + auth_count);
}


void tauthorization_pusher(String tauth) {
  tauthorization = tauth;
  String b = (const char * )authorization_json[auth_watch];
  JSONVar bm = JSON.parse(b);
  tauth_remote_enabled = "on";
  bm["__specs"]["tauthorization"] = tauth;
  authorization_json[auth_watch] = JSON.stringify(bm);
  before_me = (const char *)authorization_json[auth_watch];
  tauth_watch++;
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
  tauthorization = "";
  String b = (const char *)authorization_json[auth_watch];
  JSONVar bm = JSON.parse(b);
  bm["__specs"]["tauthorization"] = "";
  authorization_json[auth_watch] = JSON.stringify(bm);
  before_me = (const char *)authorization_json[auth_watch];
}



void tauth_connect() {
  if (ws_connected == 0 && tauthorization != "") {
    //    Serial.println(ws_connected);
    ws_connected = wsclient.connect("ws://" + twshomebaseIP + "/teletype/ws?tauthorization=" + tauthorization);
    wsclient.send("Hey Server");
    wsclient.ping();
  }
  tauth_remote_enabled = "on";

}

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
    lv_obj_set_pos(codd, 10, 10 );
    lv_obj_set_size(codd, 120, 40 );
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
    lv_obj_set_pos(cldd, 10, 50 );
    lv_obj_set_size(cldd, 120, 40 );
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
    lv_obj_set_pos(tedd, 10, 90 );
    lv_obj_set_size(tedd, 120, 40 );
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
    lv_obj_set_pos(prdd, 150, 10 );
    lv_obj_set_size(prdd, 120, 40 );
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
    lv_obj_set_pos(acdd, 150, 50 );
    lv_obj_set_size(acdd, 120, 40 );
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
    lv_obj_set_pos(pedd, 10, 130 );
    lv_obj_set_size(pedd, 220, 40 );
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
    lv_obj_set_pos(condd, 150, 90 );
    lv_obj_set_size(condd, 120, 40 );
    lv_obj_set_style_bg_color(condd, lv_color_hex(0x58fdd4), LV_PART_MAIN);
    lv_obj_set_style_text_color(condd, t1, LV_PART_MAIN);
    Serial.println("after the contact");
  }
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

}

static void sd_test(lv_event_t *e) {
  sd_tester();
}
bool sd_tester() {
  digitalWrite(BOARD_SDCARD_CS, HIGH);
  digitalWrite(RADIO_CS_PIN, HIGH);
  digitalWrite(BOARD_TFT_CS, HIGH);

  if (SD.begin(BOARD_SDCARD_CS, spi, 800000U)) {
    uint8_t cardType = SD.cardType();
    if (cardType == CARD_NONE) {
      Serial.println("No SD_MMC card attached");
      return false;
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
      return true;
    }
  }
  listDir(SD, "/", 7);

  return false;
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


static void wifi_control(lv_event_t *e) {
  lv_obj_t * wifi_button = lv_event_get_target_obj(e);
  if (wifi_enabled == true) {
    lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    WiFi.disconnect();
    if (wifi_ap_enabled == false) {
      webserver_enabled = false;
      server.stop();
    }
    wifi_enabled = false;
  }
  else {
    wifi_enabled = true;
    wifi_server();
    if (WiFi.status() == WL_CONNECTED) {
      server.begin();
      server.handleClient();
      lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
      webserver_enabled = true;
    }
    else {
      lv_obj_set_style_bg_color(wifi_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
      server.stop();
      wifi_enabled = false;
      if (wifi_ap_enabled == false) {
        webserver_enabled = false;
      }
    }
  }
}


static void brightness_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target_obj(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  brightnessLevel = level;
  setBrightness(brightnessLevel);

}

static void volume_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target_obj(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  volumeLevel = level;
  audio.setVolume(volumeLevel);

  setMasterVolume(level);
}

void setMasterVolume(int level) {

}

void configSave() {
  writeFile(FFat, "/bootreport.txt", "success");

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
  conf["tauthorization"] = tauthorization;
  String aj = JSON.stringify(authorization_json);
  conf["aj"] = aj;
  conf["auth_count"] = auth_count;
  conf["before_me"] = before_me;
  conf["homebase"] = homebase;
  conf["homebaseIP"] = homebaseIP;
  conf["twshomebaseIP"] = twshomebaseIP;
  conf["computer_name"] = computer_name;
  conf["brightness"] = brightnessLevel;
  conf["room_count"] = room_count;
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
  Serial.println(returner);
  writeFile(FFat, "/config.json", returner.c_str());
}

void configDelete() {
  deleteFile(FFat, "/config.json");
  Serial.println("Formatting");
  writeFile(FFat, "/bootreport.txt", "deleting");

  before_me = "";
  jw_room = "gate";
  homebase = "";
  name = "LilyGo T-Deck Pro";
  homebaseIP = "";
  thomebaseIP = "";
  twshomebaseIP = "";
  offset = 0;
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
  tauthorization = "";
  ap_password = base_ap_password;
  authorization_json = JSON.parse("[]");
  wigi = JSON.parse("[]");
  auth_count = 0;
  mouse_move_relative = "off";
  buttoned_before = false;
  wifi_ap_enabled = false;
  wifi_enabled = false;
  loraChatBroadcaster = false;
  loraChatReceiver = false;
  tauth_remote_enabled = "off";
  account_room, community_room, club_room, team_room, contact_room, project_room = "";
}


void configRestore() {
  returner = "";
  returner = readFile(FFat, "/config.json");
  writeFile(FFat, "/bootreport.txt", "saving");

  JSONVar conf = JSON.parse(returner);
  if (returner != "failure") {
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
    computer_name = (const char *)conf["computer_name"];
    authorization = (const char *)conf["authorization"];
    ssid = (const char *)conf["ssid"];

    brightnessLevel = conf["brightness"];
    volumeLevel = conf["volume"];
    room_count = conf["room_count"];
    fontSize = conf["fontSize"];
    fontSelect = (const char * )conf["fontSelect"];
    setBrightness(brightnessLevel);
    password = (const char *)conf["password"];
    ap_ssid = (const char *)conf["ap_ssid"];
    tauthorization = (const char *)conf["tauthorization"];
    ap_password = (const char *)conf["ap_password"];
    String aj = (const char *)conf["aj"];
    authorization_json = JSON.parse(aj);
    String wigi_wah = (const char *)conf["wigi"];
    wigi = JSON.parse(wigi_wah);

    auth_count = conf["auth_count"];
    mouse_move_relative = (const char *)conf["mouse_move_relative"];

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
    wifi_server();
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
    tauth_remote_enabled = (const char *)conf["tauth_remote_enabled"];
    if (tauth_remote_enabled == "on") {
      tauth_connect();
    }
    else {
      tauth_cancel();
    }
  }
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

   Serial.println("- read from file:");
  while (file.available()) {
    char fString = (char)file.read();
    Serial.println(fString);
    returner += fString;

  }
  file.close();
  Serial.println(returner);
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

// The mic array is an ES7210 wired for TDM; core 3.x dropped the old
// i2s_driver_install() API, so this is the same setup through i2s_tdm.
i2s_chan_handle_t mic_rx_handle = NULL;

void setupMicrophoneI2S(i2s_port_t  i2s_ch)
{
  i2s_chan_config_t chan_cfg = I2S_CHANNEL_DEFAULT_CONFIG(i2s_ch, I2S_ROLE_MASTER);
  chan_cfg.dma_desc_num = 8;
  chan_cfg.dma_frame_num = 64;

  if (i2s_new_channel(&chan_cfg, NULL, &mic_rx_handle) != ESP_OK) {
    Serial.println("mic i2s channel failed");
    return;
  }

  i2s_tdm_config_t tdm_cfg = {};
  tdm_cfg.clk_cfg = I2S_TDM_CLK_DEFAULT_CONFIG(MIC_I2S_SAMPLE_RATE);
  tdm_cfg.slot_cfg = I2S_TDM_PHILIPS_SLOT_DEFAULT_CONFIG(I2S_DATA_BIT_WIDTH_16BIT,
                     I2S_SLOT_MODE_STEREO,
                     (i2s_tdm_slot_mask_t)(I2S_TDM_SLOT0 | I2S_TDM_SLOT1 | I2S_TDM_SLOT2 | I2S_TDM_SLOT3));
  tdm_cfg.gpio_cfg.mclk = (gpio_num_t)BOARD_ES7210_MCLK;
  tdm_cfg.gpio_cfg.bclk = (gpio_num_t)BOARD_ES7210_SCK;
  tdm_cfg.gpio_cfg.ws = (gpio_num_t)BOARD_ES7210_LRCK;
  tdm_cfg.gpio_cfg.dout = I2S_GPIO_UNUSED;
  tdm_cfg.gpio_cfg.din = (gpio_num_t)BOARD_ES7210_DIN;
  tdm_cfg.gpio_cfg.invert_flags.mclk_inv = false;
  tdm_cfg.gpio_cfg.invert_flags.bclk_inv = false;
  tdm_cfg.gpio_cfg.invert_flags.ws_inv = false;

  if (i2s_channel_init_tdm_mode(mic_rx_handle, &tdm_cfg) != ESP_OK) {
    Serial.println("mic i2s tdm mode failed");
    return;
  }
  i2s_channel_enable(mic_rx_handle);

#ifdef USE_ESP_VAD
  // Initialize esp-sr vad detected
#if ESP_IDF_VERSION_VAL(4,4,1) == ESP_IDF_VERSION
  vad_inst = vad_create(VAD_MODE_0, MIC_I2S_SAMPLE_RATE, VAD_FRAME_LENGTH_MS);
#elif  ESP_IDF_VERSION >= ESP_IDF_VERSION_VAL(4,4,1)
  vad_inst = vad_create(VAD_MODE_0);
#else
#error "No support this version."
#endif
  vad_buff = (int16_t *)ps_malloc(vad_buffer_size);
  if (vad_buff == NULL) {
    while (1) {
      Serial.println("Memory allocation failed!");
      delay(1000);
    }
  }
  xTaskCreate(vadTask, "vad", 8 * 1024, NULL, 12, &vadTaskHandler);
#endif

}
