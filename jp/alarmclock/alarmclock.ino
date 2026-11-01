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

// Forward declaration so PlatformIO's auto-generated prototypes (inserted
// before the wrappers below) can resolve the return type of break_epoch().
struct jawn_time;

// Sketch split into ordered parts, concatenated by PlatformIO after this index:
//   alarmclock_01_globals_clock_ble.ino         globals, clock, BLE/NUS helpers
//   alarmclock_02_ble_handlers_wifi_setup.ino   BLE/USB handlers, setup, mDNS, WiFi
//   alarmclock_03_loop_house_inputs_jobs.ino    loop/loop1, house, inputs, local jobs
//   alarmclock_04_jobs_clock_config_net.ino     core jobs, clock display, config, network

void setup() { jawn_setup(); }
void loop() { jawn_loop(); }
