#include <Arduino.h>
#include <stdarg.h>
#include <Wire.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <WebServer.h>
#include <Update.h>
#include <FFat.h>
#include <Arduino_JSON.h>
#include <ESP_I2S.h>
#include <esp_camera.h>
#include <esp_mac.h>
#include <esp_heap_caps.h>
#include <esp_log.h>
#include <esp_system.h>
#include <mbedtls/platform.h>
#include <mbedtls/base64.h>
#include <freertos/stream_buffer.h>
// NimBLE's ble_sm.h has a struct member named `local`; no decoder is included
// now, but this keeps the name free for future headers (the deck's note).
#undef local
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
// No BLE2902 here: this core's BLE is NimBLE, which adds the notification
// descriptor itself for a NOTIFY characteristic.
// The house CA. Every house TLS client pins it as a trust anchor.
#include <house_ca.h>
// The wake-word model is shared from jt through -I../jt, not copied here. See
// jh_10_voice_in.ino for the phase-1 plan and the inference TODO.
#include "hey_jawn_model.h"

// JawnHat firmware: index + ordered parts.
// PlatformIO concatenates this file first (it is the main .ino, found by the
// void setup()/void loop() wrappers below), then the jh_* parts in sorted order,
// into a single translation unit.
//
// Parts:
//   jh_01_globals.ino         pins, config state, logging, chip/mac identity
//   jh_02_setup.ino           boot: power profile, FS, peripherals, radios
//   jh_03_loop.ino            the housekeeping the loop owns
//   jh_04_camera.ino          esp_camera capture and multipart POST to the house
//   jh_05_audio_out.ino       MAX98357 I2S output for the bone-conduction pair
//   jh_06_imu.ino             ICM-20948 heading (relative yaw) over I2C
//   jh_07_haptics.ino         coin vibration motor
//   jh_08_ble_net.ino         Nordic UART BLE link and the jh.* command set
//   jh_09_config.ino          house URL / credentials in FFat
//   jh_10_voice_in.ino        PDM microphone, ring buffer, wake word
//   jh_11_ota.ino             /device_query version report and /update
//   jh_12_bridge.ino          the house bridge envelope and its state_request
//
// The original void setup()/void loop() bodies live in the parts as
// jawn_setup()/jawn_loop(). These wrappers keep main-file detection and the
// prototype generator's insertion point working.
//
// The prototypes below name every cross-part call whose signature the .ino
// preprocessor might not reproduce (anything returning String/JSONVar or a
// pointer). The parts are one translation unit, but a call in an earlier part
// still has to see a declaration before its definition appears later.
void jawn_setup();
void jawn_loop();

void camera_init();
void camera_request_snap();
bool camera_busy();
const char *camera_last_error();

void audio_out_init();
bool audio_play_pcm(const uint8_t *data, size_t len, uint32_t rate);
bool audio_play_wav(const uint8_t *data, size_t len);
bool audio_busy();

bool imu_init();
void imu_poll();
float imu_yaw_degrees();
bool imu_ready();

void haptics_init();
void haptics_tick(int strength);
void haptics_update();

void ble_arm_start();
void ble_loop();
bool ble_link_up();

void bridge_loop();
static void bridge_handle(const String &raw);

void config_defaults();
void config_restore();
void config_save();
void config_serial_loop();

void voice_in_init();
bool wake_word_ready();
uint32_t wake_word_fires();
uint8_t wake_word_peak();

void ota_start();
void ota_loop();

String chip_id_maker();
JSONVar printAllMacAddresses();

void setup() { jawn_setup(); }
void loop() { jawn_loop(); }
