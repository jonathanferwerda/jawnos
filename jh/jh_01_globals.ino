// The house version this image was built from. scripts/fw_version.py passes it
// from jh/VERSION; the fallback keeps an IDE build compiling.
#ifndef JAWN_FW_VERSION
#define JAWN_FW_VERSION "unknown"
#endif

// ---- configuration the house sets -----------------------------------------
// The hat is configured once over serial (or a provisioning page in phase 1) and
// then remembers: where the house is, the bearer it accepts, and the WiFi it
// joins for the camera POST and the OTA rail. BLE is the command link and needs
// no credentials at all, which is why the hat still answers when WiFi is absent.
static String jh_house_url = "";       // e.g. https://192.168.2.3:45547/manager/...
static String jh_house_token = "";     // bearer for the camera POST and /update
static String jh_ssid = "";
static String jh_password = "";
static String jh_device_name = "JawnHat";
static bool jh_wifi_enabled = true;

// The audio and microphone share one rate on purpose: the house sends speech at
// 16 kHz mono, which is also what the wake-word model expects, so neither side
// resamples in phase 0.
#define JH_AUDIO_RATE 16000
#define JH_MIC_RATE   16000

// Print to both consoles. Serial is the USB CDC; esp_log_write also reaches the
// USB-Serial/JTAG console, so a monitor sees the boot even when nothing asserts
// DTR. The deck learned this the hard way (see jt_02_lorawan_radio_gps.ino).
static void jh_log(const char *fmt, ...) {
  char buf[224];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  if (Serial) {
    Serial.println(buf);
  }
  esp_log_write(ESP_LOG_INFO, "jh", "%s\n", buf);
}

// The chip id is what the house uses to name this board in the fleet. It is the
// same derivation the deck and the watch use, so a hat and a deck on the same
// desk cannot collide.
String chip_id_maker() {
  uint32_t chipId = 0;
  for (int i = 0; i < 17; i = i + 8) {
    chipId |= ((ESP.getEfuseMac() >> (40 - i)) & 0xff) << i;
  }
  String chip_id = String(chipId);
  return chip_id;
}

// The radio addresses the server needs to bridge this hat: the bridge daemon
// connects to mac_addresses->bluetooth. Mirrors jt_02_lorawan_radio_gps.ino.
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

// mbedTLS's handshake records are the largest thing a TLS client allocates on
// this board. Internal RAM is also where the BLE stack, the camera DMA and the
// I2S descriptors live, so anything of 64 bytes or more comes from the 8 MB of
// PSRAM instead; the tiny crypto allocations follow it because they are
// CPU-only and PSRAM is the only room left once the radios are up. This is the
// deck's allocator, kept identical so the same TLS failures do not come back.
static void *jh_psram_calloc(size_t n, size_t size) {
  size_t total = n * size;
  if (total >= 64) {
    void *p = heap_caps_malloc(total, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
    if (p) {
      memset(p, 0, total);
      return p;
    }
  }
  return heap_caps_calloc(n, size, MALLOC_CAP_8BIT | MALLOC_CAP_INTERNAL);
}

static void jh_psram_free(void *p) {
  heap_caps_free(p);
}
