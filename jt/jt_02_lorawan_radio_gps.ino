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
// What the panel asked the module to do. `gps_enabled` is on by default (the
// deck shipped with a receiver); a u-blox fallback keeps its own defaults.
bool     gps_enabled = true;
String   gps_constellation = "gps_glonass";
uint8_t  gps_rate = 1;
static bool gps_is_l76k = false;
static bool gpsApplyRequested = false;
#define GPS_RETRY_INTERVAL 30000
#define GPS_MAX_ATTEMPTS   6
static bool gpsBringUp(uint32_t stopWaitMs, uint32_t verWaitMs, int tries, uint32_t ackMs);
static void gpsApply();

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
uint16_t loopbackBuffer[3200] = {0};


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

// ---- LoRaWAN ---------------------------------------------------------------
// The same SX1262 that carries the point-to-point chat can be a LoRaWAN node.
// The credentials live in config.json (pushed by the Chat app) and RadioLib
// owns the join, the frame counters and the duty cycle. LoRaWAN and the old
// raw-LoRa chat are alternatives: when LoRaWAN is on, readRadio() and
// loraChatBroadcast() stand down so the radio is not left in two modes.
LoRaWANNode *lorawanNode = nullptr;
bool     lorawan_enabled = false;
String   lorawan_band = "EU433";
uint8_t  lorawan_subband = 1;
String   lorawan_join_eui = "";
String   lorawan_dev_eui = "";
String   lorawan_app_key = "";
uint8_t  lorawan_fport = 1;
bool     lorawan_confirmed = false;
String   lorawan_last_error = "";
int16_t  lorawan_last_rssi = 0;

// ---- raw point-to-point LoRa ------------------------------------------------
// The SX1262 is shared with LoRaWAN: when `lorawan_enabled` is on the node owns
// the modem, and these settings only describe the raw fallback. They arrive
// from Now Me and live in config.json so a deck comes back on the same channel.
float   lora_frequency = 433.0;
uint8_t lora_spreading_factor = 9;
float   lora_bandwidth = 125.0;
int8_t  lora_tx_power = 22;
float   lora_last_rssi = 0;
float   lora_last_snr = 0;
static bool     loraApplyRequested = false;
static volatile bool loraTxPending = false;
static uint32_t loraTxAt = 0;
static String   loraPendingPayload;
static uint32_t loraPendingAt = 0;
static uint8_t  loraPendingTries = 0;
// The Radio tab's two lines: the channel in use and the last packet's signal.
// The pointers are forgotten wherever the screen is cleaned, because a label
// pointer left behind after lv_obj_clean() is a use-after-free.
lv_obj_t *lora_channel_label = nullptr;
lv_obj_t *lora_signal_label = nullptr;
static bool lora_has_signal = false;
static bool loraSignalDirty = true;

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
    String rauth = server.header("authorization");
    if (rauth == "") { rauth = server.arg("authorization"); }
    if (authorization.length() == 0 || rauth != authorization) {
      ota_refused = true;
      Serial.println("ota: refused (authorization)");
      return;
    }
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

// Talk to the SX1262 by hand. Three questions in one go: what state is the
// Arduino driver's SPI register left in, does the radio answer at any clock,
// and can *anything* be read on MISO at all (the ST7789 answers RDDST).
static void radioBusProbe() {
  pinMode(RADIO_RST_PIN, OUTPUT);
  digitalWrite(RADIO_RST_PIN, HIGH);   // out of reset, the SX126x reset is active low
  pinMode(RADIO_CS_PIN, OUTPUT);
  digitalWrite(RADIO_CS_PIN, HIGH);
  delay(10);

  deckLog("[radio] probe: user=0x%08x clk=0x%08x div=%u",
          (unsigned)READ_PERI_REG(SPI_USER_REG(2)), (unsigned)READ_PERI_REG(SPI_CLOCK_REG(2)),
          (unsigned)spi.getClockDivider());

  // the display answers a status read if the bus can receive at all
  tft.setRotation(1);
  uint8_t rddst = tft.readcommand8(0x09);
  deckLog("[radio] probe: tft rddst=0x%02x", rddst);

  // how long does it take to push a full frame? 153600 bytes: ~35ms at 40MHz,
  // ~500ms at 2.4MHz, ~1.2s at 1MHz. The answer says whether the TFT is
  // drawing at the configured SPI_FREQUENCY or at whatever the bus was left at.
  uint32_t tFill = millis();
  tft.fillScreen(TFT_BLACK);
  deckLog("[radio] probe: fillScreen %u ms", (unsigned)(millis() - tFill));

  const uint32_t freqs[] = {2000000, 1000000, 4000000, 500000};
  for (unsigned f = 0; f < sizeof(freqs) / sizeof(freqs[0]); f++) {
    spi.beginTransaction(SPISettings(freqs[f], MSBFIRST, SPI_MODE0));
    digitalWrite(RADIO_CS_PIN, LOW);
    uint8_t status = spi.transfer(0xC0);      // GetStatus
    digitalWrite(RADIO_CS_PIN, HIGH);
    spi.endTransaction();
    deckLog("[radio] probe @%u hz: status=0x%02x div=%u",
            (unsigned)freqs[f], status, (unsigned)spi.getClockDivider());
  }

  // The TFT driver overwrites SPI_USER_REG on every transaction; its write mode
  // leaves only MOSI enabled, while the Arduino driver only sets the receive
  // bits once, when the bus starts. Put them back and read the version string.
  REG_SET_BIT(SPI_USER_REG(2), SPI_USR_MOSI | SPI_USR_MISO | SPI_DOUTDIN);
  spi.beginTransaction(SPISettings(2000000, MSBFIRST, SPI_MODE0));
  digitalWrite(RADIO_CS_PIN, LOW);
  spi.transfer(0x1D);                  // ReadRegister
  spi.transfer(0x03);                  // address high
  spi.transfer(0x20);                  // address low -> 0x0320
  spi.transfer(0x00);                  // NOP
  uint8_t version[16];
  for (int i = 0; i < 16; i++) {
    version[i] = spi.transfer(0x00);
  }
  digitalWrite(RADIO_CS_PIN, HIGH);
  spi.endTransaction();

  char hex[40] = {0};
  for (int i = 0; i < 16; i++) {
    snprintf(hex + i * 2, 3, "%02x", version[i]);
  }
  deckLog("[radio] probe: version=%s user=0x%08x", hex,
          (unsigned)READ_PERI_REG(SPI_USER_REG(2)));
}

// The Radio tab's status is built from the same globals the radio applies, so
// it says what the modem is actually on, not what the last panel save asked
// for. A null label means the tab is not on screen; the write is a no-op.
static void loraSignalForget() {
  lora_channel_label = nullptr;
  lora_signal_label = nullptr;
}

static void loraSignalWriter() {
  loraSignalDirty = false;
  char buf[72];
  if (lora_channel_label) {
    if (!hasRadio) {
      snprintf(buf, sizeof(buf), "LoRa: radio not detected");
    }
    else if (lorawan_enabled) {
      snprintf(buf, sizeof(buf), "LoRa: LoRaWAN mode");
    }
    else {
      snprintf(buf, sizeof(buf), "LoRa %.1f MHz SF%u BW%.0f %d dBm",
               lora_frequency, (unsigned)lora_spreading_factor,
               lora_bandwidth, (int)lora_tx_power);
    }
    lv_label_set_text(lora_channel_label, buf);
  }
  if (lora_signal_label) {
    if (!hasRadio || lorawan_enabled) {
      snprintf(buf, sizeof(buf), "RX: --");
    }
    else if (!lora_has_signal) {
      snprintf(buf, sizeof(buf), "RX: no packet yet");
    }
    else {
      snprintf(buf, sizeof(buf), "RX %.0f dBm  SNR %.1f dB",
               lora_last_rssi, lora_last_snr);
    }
    lv_label_set_text(lora_signal_label, buf);
  }
}

// Bring the modem up for the configured raw settings. This has to be the last
// word on output power and current: SX1262::begin() calls setCurrentLimit(60)
// and setOutputPower(cfg.power) itself, so a limit applied before begin is gone
// by the time begin returns - which is why 22 dBm never reached the antenna.
static void loraApply() {
  loraApplyRequested = false;
  if (lorawan_enabled && hasRadio) {
    // LoRaWAN owns a live modem. A raw setting changed meanwhile is kept in
    // config.json and applied when LoRaWAN is turned off (/lorawan_config).
    deckLog("%s", "[radio] raw settings saved; LoRaWAN owns the modem");
    return;
  }
  loraTxPending = false;
  operationDone = false;
  loraPendingPayload = "";
  loraPendingTries = 0;
  lora_has_signal = false;
  loraSignalDirty = true;
  int state = radio.begin(lora_frequency, lora_bandwidth, lora_spreading_factor, 7,
                          RADIOLIB_SX126X_SYNC_WORD_PRIVATE, lora_tx_power, 8, 1.6, false);
  if (state != RADIOLIB_ERR_NONE) {
    hasRadio = false;
    deckLog("[radio] init failed (%d) at %.3f MHz", state, lora_frequency);
    return;
  }
  // begin() has just reset both of these, so they belong after it, not before.
  radio.setOutputPower(lora_tx_power);
  radio.setCurrentLimit(lora_tx_power >= 20 ? 140.0 : 80.0);
  radio.setDio1Action(setFlag);
  hasRadio = true;
  if (lorawan_enabled) {
    // LoRaWAN owns the modem. The node sets its own channel frequency on every
    // uplink, so the raw parameters above are only the initial bring-up; the
    // radio must not also sit in the point-to-point receive state.
    lorawanBegin();
    deckLog("[radio] up for LoRaWAN (brought up at %.3f MHz)", lora_frequency);
    return;
  }
  if (loraChatReceiver) {
    radio.startReceive();
  }
  else {
    radio.standby();
  }
  deckLog("[radio] up: %.3f MHz SF%u BW%.1f %d dBm", lora_frequency,
          (unsigned)lora_spreading_factor, lora_bandwidth, (int)lora_tx_power);
}

// One raw transmit, after listening on the channel first. The SX1262 can CAD,
// so a message waits out a busy channel instead of talking over a packet that
// is already in the air. Only one payload is held; each try is bounded.
static void loraQueuePayload(const String& payload) {
  if (!hasRadio || lorawan_enabled || payload.length() == 0) { return; }
  int16_t cad = radio.scanChannel();
  // scanChannel() is blocking and its CAD_DONE also fires DIO1, so the flag it
  // leaves behind is not a received packet.
  operationDone = false;
  if (cad == RADIOLIB_LORA_DETECTED) {
    loraPendingPayload = payload;
    if (loraPendingTries < 255) { loraPendingTries++; }
    if (loraPendingTries <= 4) {
      loraPendingAt = millis() + 80 + (esp_random() % 120);
      deckLog("[lora] channel busy, retrying (%u)", (unsigned)loraPendingTries);
    }
    else {
      deckLog("[lora] channel busy, dropped after %u tries", (unsigned)loraPendingTries);
      loraPendingPayload = "";
      loraPendingTries = 0;
      // The CAD put the radio in standby; a dropped message must not leave it
      // deaf for the next packet.
      if (loraChatReceiver) { radio.startReceive(); } else { radio.standby(); }
    }
    return;
  }
  if (cad != RADIOLIB_CHANNEL_FREE) {
    // CAD could not answer; a message is better late than never
    deckLog("[lora] channel scan failed (%d); sending anyway", cad);
  }
  loraTxPending = true;
  loraTxAt = millis();
  operationDone = false;
  // RadioLib's startTransmit takes a non-const reference
  String out = payload;
  int st = radio.startTransmit(out);
  if (st != RADIOLIB_ERR_NONE) {
    loraTxPending = false;
    deckLog("[lora] transmit start failed (%d)", st);
    if (loraChatReceiver) { radio.startReceive(); } else { radio.standby(); }
    return;
  }
  loraPendingPayload = "";
  loraPendingTries = 0;
  deckLog("[lora] queued %u bytes", (unsigned)payload.length());
}

// The loop's half: retry a payload the channel was busy for, and stop waiting
// on a transmit whose DIO1 never came (the radio must not sit in TX for ever).
static void loraService() {
  if (loraSignalDirty) { loraSignalWriter(); }
  if (!hasRadio || lorawan_enabled) { return; }
  if (loraTxPending && millis() - loraTxAt > 5000) {
    loraTxPending = false;
    radio.finishTransmit();
    if (loraChatReceiver) { radio.startReceive(); } else { radio.standby(); }
    deckLog("[lora] transmit timeout; back to listening");
  }
  if (loraPendingPayload.length() && millis() >= loraPendingAt) {
    String pending = loraPendingPayload;
    loraQueuePayload(pending);
  }
}

// The allocator installed in setup(): mbedTLS's big buffers (the handshake's
// in/out records) from PSRAM, small ones internal.
static void *mbedtls_psram_calloc(size_t n, size_t size) {
  size_t total = n * size;
  // The BIGNUM limbs that failed here are small (a few hundred bytes), and the
  // old >=4 KB rule sent every one of them to internal RAM. Once the wake-word
  // front-end and the BLE stack are resident, internal RAM is down to a few KB
  // and the handshake dies as "BIGNUM - Memory allocation failed" (the deck's
  // wss and its HTTP failover both stopped working). Small crypto allocations
  // are CPU-only, so they belong in PSRAM too.
  if (total >= 64) {
    void *p = heap_caps_malloc(total, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (p) {
      memset(p, 0, total);
      return p;
    }
  }
  return heap_caps_calloc(n, size, MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL);
}

static void mbedtls_psram_free(void *p) {
  heap_caps_free(p);
}

// The radio addresses the server needs to bridge this deck: bluetooth_sender
// connects the bridge daemon to mac_addresses->bluetooth. Mirrors jw.ino's.
JSONVar printAllMacAddresses() {
  uint8_t mac[6];
  char buf[18];
  JSONVar addresses;
  if (esp_efuse_mac_get_default(mac) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["base"] = String(buf);
  }
  if (esp_read_mac(mac, (esp_mac_type_t)0) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["wifi_sta"] = String(buf);
  }
  if (esp_read_mac(mac, (esp_mac_type_t)1) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["wifi_ap"] = String(buf);
  }
  if (esp_read_mac(mac, (esp_mac_type_t)2) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["bluetooth"] = String(buf);
  }
  return addresses;
}

