
#include <Arduino.h>
#include <Wire.h>
#include <TFT_eSPI.h>
#include <lvgl.h>
#include <WiFi.h>
// ESPmDNS: advertise this deck on _jawnos._tcp so the Dev panel names it at once
// (see the server's subs::mdns_devices).
#include <ESPmDNS.h>
// WebServer.h wants FS (and <functional>) declared before it sees them
#include "FS.h"
#include "FFat.h"
// TFT_eSPI defines FS_NO_GLOBALS before FS.h, so the global FS alias is gone
using fs::FS;
// fsAccount() and the SD/FFat store helpers name File directly, and TFT_eSPI
// has already suppressed FS.h's globals.
using fs::File;
#include <WebServer.h>
#include <Update.h>
#include <HTTPClient.h>
// for the PSRAM allocator settings and the netcheck probes (heap_caps_*, esp_ptr_external_ram)
#include <esp_heap_caps.h>
#include <esp_memory_utils.h>
#include <mbedtls/platform.h>
#include <esp_mac.h>
// Light sleep (the Set room's Sleep mode): GPIO wake sources and the sleep call.
#include <driver/gpio.h>
#include <esp_sleep.h>
// the ESP32 ROM's miniz: inflate a compressed bridge payload (see ble_inflate_if_zlib)
#include "miniz.h"
// On-device voice models (the watch's stack): the microfrontend front-end is
// deck-libs/micro_features, the TFLM runtime is the platform's
// espressif__esp-tflite-micro. See voice_models.h.
#include "voice_models.h"
#include <driver/i2s_tdm.h>
#include "es7210.h"
#include <Audio.h>
#include "utilities.h"
#include <ESP32Time.h>
#include <Arduino_JSON.h>
#include <UrlEncode.h>
#include <RadioLib.h>
#include <SD.h>
#include <ArduinoWebsockets.h>
// NimBLE's ble_sm.h has a struct member named `local`; no decoder is included
// now (PNGdec was unused), but this keeps the name free for future headers.
#undef local
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>
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
// PlatformIO's prototype generator inserts its block just before the first
// function definition in the sketch; the BLE helpers below are the first, so
// the unqualified websockets types must already be visible this early.
using namespace websockets;

// JawnTeletype firmware: index + ordered parts.
// PlatformIO concatenates this file first (it is the main .ino, found by the
// void setup()/void loop() wrappers below), then the jt_* parts in sorted
// order, into a single translation unit.
//
// Parts:
//   jt_01_globals_ble_house.ino
//   jt_02_lorawan_radio_gps.ino
//   jt_03_setup.ino
//   jt_04_gps_wifi_helpers.ino
//   jt_05_loop.ino
//   jt_06_ui_lora_keypad.ino
//   jt_07_lorawan_house_net.ino
//   jt_08_display_touch_rooms.ino
//   jt_09_mb_buttons_config.ino
//   jt_10_remote_auth.ino
//   jt_11_chat_ble_net.ino
//   jt_12_sleep_brightness.ino
//   jt_13_config_files.ino
//   jt_14_voice_notes_clips.ino
//   jt_15_voice_activation.ino
//   jt_16_voice_capture.ino
//
// The original void setup()/void loop() bodies live in the parts as
// jawn_setup()/jawn_loop(). These wrappers keep main-file detection and the
// prototype generator's insertion point working. No custom-type forward
// declarations are needed here: the generator only prototypes all-lowercase
// signatures over library/standard types, all of which the includes above
// already declare.
void jawn_setup();
void jawn_loop();

void setup() { jawn_setup(); }
void loop() { jawn_loop(); }
