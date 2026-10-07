
// The Start of the JawnWatch (JW)
#include <LilyGoLib.h>
#include <LV_Helper.h>
#include <time.h>
#include <WebServer.h>


TFT_eSPI tft;
#include <UrlEncode.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <Arduino_JSON.h>
#include <ESP32Time.h>
#include <WiFiAP.h>
#include <Update.h>
#include <uri/UriRegex.h>
#include <esp_task_wdt.h>
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include "FS.h"
#include "FFat.h"
ESP32Time rtc;

int screenRotation = 2;
// Flag used to indicate whether to use light sleep, currently unavailable
static bool lightSleep = false;
double wakeup_time = 0;
// Flag used for acceleration interrupt status
static bool sportsIrq = false;
// Flag used to indicate whether recording is enabled
static bool recordFlag = false;
// Flag used for PMU interrupt trigger status
static bool pmuIrq = false;
static bool webserver_enabled;// = true;
static bool wifi_ap_enabled = false;
static bool wifi_enabled = false;
static bool bt_enabled = false;
JSONVar btMessages;
char standby_en = 1;
long DEFAULT_SCREEN_TIMEOUT = 60*1000;
String jw_room = "watch";
void settingSensor();
void settingPMU();
uint16_t t_x = 0, t_y = 0;
String authorization;
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
String homebaseIPArray[10];
String wifi_update;
JSONVar wigi;
JSONVar notifications = JSON.parse("[]");
String computer_name;
static RTC_DATA_ATTR int brightnessLevel = 50;
int vibrateLevel = 50;
int volumeLevel = 50;
void lowPowerEnergyHandler();
String chat_room;
bool loraChatBroadcaster = false;
bool loraChatReceiver = false;
bool stepCounter = true;
uint32_t steps;
uint32_t stepSampleMillis = 0;
JSONVar stepped;
#include <driver/i2s.h>
#include <driver/gpio.h>

/// Include the official playback engine libraries from the template
#include <AudioOutputI2S.h>
#include <AudioFileSourceFATFS.h>
#include "AudioGeneratorWAV.h"
#include "AudioFileSourceFunction.h"
String https_request(String url, String method = "GET", String payloadData = "");

// Hardware settings matching the template parameters
String WAV_FILE_PATH = "/rec.wav";
#define AUDIO_BUFFER_CHUNK_SIZE 500

AudioGeneratorWAV       *wav = nullptr;
AudioFileSourceFATFS    *file_source = nullptr;
AudioOutputI2S          *out_hardware = nullptr;

// Tracking operation status flags across threads
volatile bool isRecording = false;
volatile bool isPlaying = false;

#define FORMAT_FFAT true

SX1262 radio = newModule();
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
bool deviceConnected = false;

// Industry-standard Nordic UART Service UUIDs
#define SERVICE_UUID           "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define CHARACTERISTIC_UUID_RX "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define CHARACTERISTIC_UUID_TX "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
QueueHandle_t bleIncomingQueue = NULL;

//64:e8:33:4B:38:39
// Handles connection status
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) { deviceConnected = true; };
    void onDisconnect(BLEServer* pServer) { deviceConnected = false; }
};
class MyCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
        String rawInput = String(pCharacteristic->getValue().c_str());
        
        if (rawInput.length() > 0 && bleIncomingQueue != NULL) {
            // Allocate string dynamically on heap so it survives after function exits
            String* msgPtr = new String(rawInput);
            
            // Push string pointer to the queue. Wait 0ms if full.
            if (xQueueSend(bleIncomingQueue, &msgPtr, 0) != pdPASS) {
                // Fail-safe: Delete allocated memory if queue is full to prevent leaks
                delete msgPtr;
                Serial.println("BLE Queue Full! Message dropped.");
            }
        }
    }
};
/*
// Handles incoming data from Tasker
class MyCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
      std::string rxValue = pCharacteristic->getValue();
      String btmsg;
      if (rxValue.length() > 0) {
        Serial.print("Received from Tasker: ");
        for (int i = 0; i < rxValue.length(); i++) {
          Serial.print(rxValue[i]);
          btmsg += String(rxValue[i]);
        }
        Serial.println();
        
        JSONVar btMsg = JSON.parse(btmsg);
        if (String((const char *)btMsg["type"]) == "button") {
          Serial.println("The type is button");
          JSONVar bm = JSON.parse(before_me);
          Serial.println("Got the bm");
          int button = (int)btMsg["data"]["button"];
          Serial.println("After the int");
          bm["b" + String(button)] = btMsg["data"];
          Serial.println("Placed the bm");
          before_me = JSON.stringify(bm);
        }
      }
    }
};
*/
void start_ble_transfer() {
  if (bt_enabled == true) {
    return;
  }
  Serial.println("Powering up Nordic UART BLE Radio...");
  bt_enabled = true;

  // 1. Re-wake the underlying Espressif BLE stack hardware
  BLEDevice::init("T-Watch-S3");
  BLEDevice::setMTU(512); 

// Create the BLE Server
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  // Create the UART Service
  BLEService *pService = pServer->createService(SERVICE_UUID);

  // Create TX Characteristic (Watch sending data to Phone)
  pTxCharacteristic = pService->createCharacteristic(
                        CHARACTERISTIC_UUID_TX,
                        BLECharacteristic::PROPERTY_NOTIFY
                      );
  pTxCharacteristic->addDescriptor(new BLE2902());

  // Create RX Characteristic (Phone sending data to Watch)
  BLECharacteristic *pRxCharacteristic = pService->createCharacteristic(
                                           CHARACTERISTIC_UUID_RX,
                                           BLECharacteristic::PROPERTY_WRITE
                                         );
  pRxCharacteristic->setCallbacks(new MyCallbacks());

  // Start the service & begin broadcasting
  pService->start();
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  
  // Attach your Nordic UART Service UUID to the broadcast beacon
  pAdvertising->addServiceUUID(SERVICE_UUID);
  
  // Optional but recommended for smartphones: helps phones identify the device payload faster
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);  // functions as a hint to help iPhone connections
  pAdvertising->setMinPreferred(0x12);
  
  // Start broadcasting over the air!
  pAdvertising->start();
  Serial.println("Nordic UART BLE Advertising has safely started!");
  Serial.println("Nordic UART advertising active.");
}

void stop_ble_transfer() {
  if (bt_enabled == false) {
    return;
  }
  Serial.println("Shutting down BLE Radio...");
  bt_enabled = false;
  pServer->getAdvertising()->stop();
  
  // Passing 'false' shuts off the RF power without destroying 
  // the NUS UUID/Characteristic mapping objects in RAM
  BLEDevice::deinit(false); 
}

void setup() {
  Serial.begin(921600);

  watch.begin();
  watch.initMicrophone();

  taskMutex = xSemaphoreCreateMutex(); 

  xTaskCreatePinnedToCore(
    loop2, "Core0Task", 4096, NULL, 1, &Core0TaskHandle, 0
  );
  bleIncomingQueue = xQueueCreate(5, sizeof(String*));

  Serial.println("starting");
  watch.setRotation(screenRotation);  
  setCpuFrequencyMhz(240);
  time_writer("now");

  settingSensor();

 //if (FORMAT_FFAT) FFat.format();
  if (!FFat.begin()) {
    Serial.println("FFat Mount Failed");
    return;
  }
  else {
    Serial.println("Mounted FFat partition");
    Serial.printf("Total space: %10u\n", FFat.totalBytes());
    Serial.printf("Free space: %10u\n", FFat.freeBytes());    
  }

  // Serial.print(F("[SX1262] Initializing ... "));
  // set output power to 10 dBm (accepted range is -17 - 22 dBm)
  if (radio.setOutputPower(22) == RADIOLIB_ERR_INVALID_OUTPUT_POWER) {
      // Serial.println(F("Selected output power is invalid for this module!"));
      while (true);
  }
  // set over current protection limit to 80 mA (accepted range is 45 - 240 mA)
  // NOTE: set value to 0 to disable overcurrent protection
  if (radio.setCurrentLimit(80) == RADIOLIB_ERR_INVALID_CURRENT_LIMIT) {
      // Serial.println(F("Selected current limit is invalid for this module!"));
      while (true);
  }    
  int state = radio.begin(433);
  if (state == RADIOLIB_ERR_NONE) {
    // Serial.println(F("success!"));
    radio.setDio1Action(setFlag);

    radio.startReceive();
  } else {
    // Serial.print(F("failed, code "));
    // Serial.println(state);
    while (true);
  }

  


  beginLvglHelper();
  lv_obj_set_style_bg_color(lv_scr_act(), lv_color_hex(0x000000), LV_PART_MAIN);


  // Set the interrupt handler of the PMU
  watch.attachPMU(setPMUFlag);
  watch.setSysPowerDownVoltage(2600);
  setCpuFrequencyMhz(80);
  button_writer();

  settingPMU();
  server.on("/", []() {
    String html = R"(
      <!DOCTYPE html>
      <html>
        <title>T-Watch Initial Config</title>
        <body style="text-align:center;position:fixed;top: 50%;left: 50%; transform: translate(-50%, -50%);">
          <form action="/initial_config" id="form" method="POST">
            <h1>T-Watch</h1>
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
    server.send(200, "text/html", "<h1>Success!</h1><a href='/'>Back</a>");
    

  });
  server.on("/notification", []() {
    notification_display(server.arg("title"), server.arg("notification"));;
    server.send(200, "text/plain", "this works as well");
  });
  server.on("/wifi_update", []() {
    String req = "https://" + homebaseIP + "/teletype/wifi_update?timestamp=" + timestamp_maker();
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
  //  radio.startTransmit(public_announcement);
  //  server.send(200, "text/plain", "done");
  //  delay(1000);
    radio.startReceive();
    server.send(200, "text/plain", "sent wifi info");
  });
  server.on("/send_telephone", []() {
    Serial.println("send telephone");
    String temp_authorization = server.arg("authorization");
    Serial.println(temp_authorization);
      Serial.println("in the temp auth");
      JSONVar m;
      m["msg"] = server.arg("msg");
      m["app"] = server.arg("app");
      String jsm = JSON.stringify(m);
      Serial.println("Sending msg: " + jsm);
      radio.startTransmit(jsm);
      delay(1000);
      radio.startReceive();
      server.send(200, "text/plain", "transmission sent");
      buttonMillis = millis();
      lastMillis = millis();
      pmuIrq = true;
  });
  
  server.on("/chat_received", []() {
    if (buttoned_before) {
      Serial.println(server.arg("s"));
      String s = server.arg("s");
      String uuid = server.arg("uuid");
      chat_grabber(s,uuid);
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
    JSONVar macs = printAllMacAddresses();
    g["mac_addresses"] = macs;
    g["SERVICE_UUID"] = SERVICE_UUID;
    g["CHARACTERISTIC_UUID_RX"] = CHARACTERISTIC_UUID_RX;
    g["CHARACTERISTIC_UUID_TX"] = CHARACTERISTIC_UUID_TX;
    g["name"] = name;
    g["uptime"] = millis();
    g["purpose"] = "watch";
    g["wigi"] = wigi;
    g["steps"] = stepped;
    JSONVar fileList = JSON.parse("[]");
    listJsonDir(FFat,"/", fileList);
    g["files"] = fileList;
    JSONVar jonfig = g;
    jonfig["ssid"] = undefined;
    jonfig["password"] = undefined;
    jonfig["ap_password"] = undefined;
    jonfig["ap_ssid"] = undefined;
    String gs = JSON.stringify(jonfig);    
    server.send(200, "text/plain", gs);

  });
  server.on("/delete_file", []() {
    String rauth = server.arg("authorization");
    Serial.println("in the deleter");
    if (rauth == authorization) {
      String file = server.arg("file");
      Serial.println(file);
      deleteFile(FFat, file.c_str());
      server.send(200, "text/plain", "file deleted");

    }
  });
  server.on("/get_file", HTTP_GET, []() {
    // 1. Check authorization
    String rauth = server.arg("authorization");
    if (rauth != authorization) {
      server.send(401, "text/plain", "Unauthorized");
      return;
    }

    // 2. Get the requested filename
    String fileName = server.arg("file");
    if (fileName == "") {
        server.send(400, "text/plain", "Missing file parameter");
        return;
    }

    // Ensure the filename starts with a forward slash for SPIFFS/FFat compatibility
    if (!fileName.startsWith("/")) {
        fileName = "/" + fileName;
    }

    // 3. Attempt to open the file from FFat storage
    if (FFat.exists(fileName)) {
      File file = FFat.open(fileName, "r");
      
      // 4. Resolve the correct MIME header dynamically
      String contentType = getContentType(fileName);
      
      // 5. Stream the file directly to the client (very RAM efficient!)
      server.streamFile(file, contentType);
      
        // 6. Close the file immediately after streaming to prevent memory leaks
      file.close(); 
    } else {
        // Fallback if the file isn't found
      server.send(404, "text/plain", "File Not Found");
    }
  });

  server.on("/wigi", []() {
    String rauth = server.arg("authorization");
    if (rauth == authorization) {

      JSONVar wigi_s;
      wigi_s["buttons"] = wigi;
      wigi_s["measures"]["steps"] = stepped;
      wigi_s["authorization"] = authorization;
      JSONVar fileList = JSON.parse("[]");
      listJsonDir(FFat,"/", fileList);
      wigi_s["files"] = fileList;
      long timestamp = timestamp_maker(); 

      wigi_s["timestamp"] = timestamp;
      String wigis = JSON.stringify(wigi_s);
      server.send(200,"text/plain", wigis);
      String resetter = "[]";
      wigi = JSON.parse(resetter);
      stepped = JSON.parse(resetter);
      watch.resetPedometer();
      // the counter starts again from zero, so start the next batch there too
      // instead of recording the reset as a step
      steps = 0;
      sportsIrq = false;
      stepSampleMillis = millis();
    }
    else {
      server.send(200,"text/plain", "{}");
    }
  });
  server.on("/now_me", []() {
    homebaseIP = server.arg("homebase");
    homebase = server.arg("ip");
    authorization = server.arg("authorization");
    DEFAULT_SCREEN_TIMEOUT = server.arg("screen_timeout").toInt();
    long timestamp = server.arg("timestamp").toInt();
    rtc.setTime(timestamp);
    offset = server.arg("offset").toInt();
    rtc.offset = offset;
    Serial.println("Homebase: " + homebase);
    Serial.println("homebase ip:" + homebaseIP);
    
    room_count = server.arg("room_count").toInt();
  //  room_max = server.arg("room_max").toInt();

    pmuIrq = true;
    buttoned_before = false;
    // Serial.println("now me in room " + room);
    b1_toggle, b2_toggle, b3_toggle, b4_toggle, b5_toggle, b6_toggle = 0;
     Serial.println(authorization);
    //call_the_president();
    remote_room();
    buttonMillis = millis();
    lastMillis = millis();
    setSportsFlag();
    settingPMU();
    pmuIrq = false;
    buttonMillis = millis();
    Serial.println("Called President at " + homebaseIP);
    server.send(200, "text/plain", "homebase ip is now " + homebaseIP);
  });
//  wifi_server();
  watch.enableSystemVoltageMeasure();
  readFile(FFat, "/bootreport.txt");
  if (returner == "success") {
    configRestore();
    Serial.println("After the restore");
  }
  else if (returner != "epic_failure") {
    writeFile(FFat, "/bootreport.txt", "epic_failure");
    configRestoreBackup();
    configRestore();
  }
  lv_task_handler();

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
    loraChatBroadcast(manager_file, body, timestamp);    
  }
}

void loraChatBroadcast(String computer_name, String body, long timestamp) {
  if (loraChatBroadcaster) {
    
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

// The pedometer holds a running total, so each sample is the whole story since the
// last one the server collected. Samples only happened when the BMA's interrupt
// fired, and once that stopped being delivered the count went quiet until the next
// reboot -- the wake cycle re-arms the sensor for tilt alone. A timer takes a
// sample as well now, which cannot go silent, and reading the same counter twice
// costs nothing.
void step_writer() {
  if (stepCounter != true) {
    return;
  }
  if (sportsIrq) {
    watch.readBMA();          // clear the latched interrupt status
    sportsIrq = false;
  }
  else if (millis() - stepSampleMillis < 60000) {
    return;
  }
  stepSampleMillis = millis();
  steps = watch.getPedometerCounter();
  if (!JSON.stringify(stepped).startsWith("[")) {
    stepped = JSON.parse("[]");         // a damaged config must not stop the count
  }
  // bounded: this lives in RAM and in the saved config
  while (stepped.length() > 240) {
    JSONVar trimmed = JSON.parse("[]");
    for (int n = 1; n < stepped.length(); n++) {
      trimmed[trimmed.length()] = stepped[n];
    }
    stepped = trimmed;
  }
  JSONVar last_step;
  last_step["timestamp"] = timestamp_maker();
  last_step["steps"] = steps;
  stepped[stepped.length()] = last_step;
  Serial.print("steps ");
  Serial.print((int)steps);
  Serial.print(" across ");
  Serial.print((int)stepped.length());
  Serial.println(" samples");
}

#include "esp_mac.h" // Handles direct low-level chip hardware queries

JSONVar printAllMacAddresses() {
  uint8_t mac[6];
  char buf[18]; // Safe buffer to temporarily hold formatted string data ("XX:XX:XX:XX:XX:XX")
  JSONVar addresses;
  
  Serial.println("\n===== ESP32 HARDWARE MAC ADDRESSES =====");

  // 1. Get Base System MAC (Queries factory-programmed eFuse layout directly)
  if (esp_efuse_mac_get_default(mac) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["base"] = String(buf);
    Serial.printf("Base System MAC:  %s\n", buf);
  }

  // 2. Get Wi-Fi Station (STA) MAC -> Cast integer (esp_mac_type_t)0
  if (esp_read_mac(mac, (esp_mac_type_t)0) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["wifi_sta"] = String(buf);
    Serial.printf("Wi-Fi Station:    %s\n", buf);
  }

  // 3. Get Wi-Fi Soft Access Point (AP) MAC -> Cast integer (esp_mac_type_t)1
  if (esp_read_mac(mac, (esp_mac_type_t)1) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["wifi_ap"] = String(buf);
    Serial.printf("Wi-Fi Access Pt:  %s\n", buf);
  }

  // 4. Get Bluetooth (Classic & BLE) MAC -> Cast integer (esp_mac_type_t)2
  if (esp_read_mac(mac, (esp_mac_type_t)2) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["bluetooth"] = String(buf);
    Serial.printf("Bluetooth Mac:    %s\n", buf); // <-- Use this exact value for your Tasker Profiles!
  }

  // 5. Get Ethernet MAC -> Cast integer (esp_mac_type_t)3
  if (esp_read_mac(mac, (esp_mac_type_t)3) == ESP_OK) {
    sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    addresses["ethernet"] = String(buf);
    Serial.printf("Ethernet Mac:     %s\n", buf);
  }
  
  Serial.println("========================================\n");
  
  return addresses;
}


void loop() {
  char count = 0;;
//  watch.attachPMU(setPMUFlag);

  if (jw_room == "watch") {
    time_writer("loop");
    if (notification_viewing == 0) {
      step_writer();
    }
  }
  else if (jw_room == "net") {
    ip_writer();
  }
  else if (jw_room == "message") {
    if (buttonMillis != 0  && millis() - buttonMillis > DEFAULT_SCREEN_TIMEOUT && count < 350) {
      lowPowerEnergyHandler();
      count = 0;
      jw_room = "watch";
    }
    else {
      count++;
    }
    delay(60);
  }
  watch.setTextFont(2);
  int volts = watch.getBatteryPercent();
  if (volts < 20) {
    watch.setTextColor(TFT_RED, TFT_BLACK);
  }
  else if (volts < 40) {
    watch.setTextColor(TFT_YELLOW, TFT_BLACK);
  }
  else {
    watch.setTextColor(TFT_GREEN, TFT_BLACK);
  }
  watch.drawNumber(watch.getBattVoltage(), 214, 5 );
  watch.drawNumber(watch.getBatteryPercent(), 15, 5);
  watch.drawString("%", 29, 5);
  if (computer_name != "") {
    watch.drawString(computer_name, 120, 5);
  }
  else {
   watch.drawString(homebaseIP, 120, 5);
  }
  touch_watch();
  if (buttonMillis == 0 && sportsIrq == 0) {
    setSportsFlag();
    settingPMU();
    pmuIrq = false;
    buttonMillis = millis();
  }


  if (!pmuIrq) {
    lv_task_handler();
    if (webserver_enabled == true) {
      server.handleClient();
    }
    delay(5);
  }
  else {
    lowPowerEnergyHandler();
  }
  if (loraChatReceiver) {
    readRadio();
  }
  if (buttonMillis != 0  && millis() - buttonMillis > DEFAULT_SCREEN_TIMEOUT) {
    lowPowerEnergyHandler();
  }
  awake_notifications();




}

void dualCoreTaskMaker(JSONVar task) {
  if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {

    int dct = dualCoreTasks.length();
    JSONVar dctask;

    if (task.hasOwnProperty("delay")) {
      dctask["delay"] = task["delay"];
    } else {
      dctask["delay"] = 0; // Default to 0 delay if not provided
    }
    dctask["millis"] = millis();
    dctask["task"] = task["task"];
    dualCoreTasks[dct] = dctask;
    xSemaphoreGive(taskMutex); 
  }

}

void loop2(void * pvParameters) {
  

  for(;;) {
    String* incomingMsgPtr = nullptr;
        
    // Non-blocking check for a new string pointer from the queue
    if (bleIncomingQueue != NULL && xQueueReceive(bleIncomingQueue, &incomingMsgPtr, 0) == pdTRUE) {
      if (incomingMsgPtr != nullptr) {
        String btmsg = *incomingMsgPtr;
        delete incomingMsgPtr; // CRITICAL: Free the allocated heap memory!

        Serial.print("Safely processing incoming Tasker JSON on loop2 stack: ");
        Serial.println(btmsg);

        JSONVar btMsg = JSON.parse(btmsg);
        if (JSON.typeof(btMsg) != "undefined") {
          if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "button") {
            
            // Mutex protect because we are modifying global memory map strings
            if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
              if (before_me == "") before_me = "{}";
              JSONVar bm = JSON.parse(before_me);
              
              if (btMsg.hasOwnProperty("data") && btMsg["data"].hasOwnProperty("button")) {
                int button = 0;
                if (JSON.typeof(btMsg["data"]["button"]) == "string") {
                    button = String((const char*)btMsg["data"]["button"]).toInt();
                } else {
                    button = (int)btMsg["data"]["button"];
                }
                
                String buttonKey = "b" + String(button);
                bm[buttonKey] = btMsg["data"];
                before_me = JSON.stringify(bm);
                
                Serial.print("Updated before_me map: ");
                Serial.println(before_me);
              }
              xSemaphoreGive(taskMutex);
            }
          }
          if (btMsg.hasOwnProperty("type") && String((const char *)btMsg["type"]) == "now_me") {
            
            // Mutex protect because we are modifying global memory map strings
            if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
              xSemaphoreGive(taskMutex);

            }
          }
        }
      }
    }

    // --- SECTION B: YOUR EXISTING OUTBOUND PROCESSING CODE ---
    // (Keep your existing xSemaphoreTake(taskMutex...) code block that iterates over btMessages here)

    // Essential: Prevents Core 0 Watchdog starvation panics
    vTaskDelay(pdMS_TO_TICKS(10)); 
    



    String taskToExecute = ""; // Local variable to hold the task name
    int taskIndexToRemove = -1; // Keep track of which slot to clear

    if (xSemaphoreTake(taskMutex, portMAX_DELAY) == pdTRUE) {
      JSONVar btKeys = btMessages.keys();
    
      int totalKeys = btKeys.length();

      if (-1 > 0) {

        String keysToDelete[totalKeys];

        for (int i = 0; i < btKeys.length(); i++) {
          String spin = btKeys[i];
          keysToDelete[i] = spin;

          String payload = JSON.stringify(btMessages[spin]["payload"]);
          String url = btMessages[spin]["url"];
          Serial.println(url);
          Serial.println(payload);
          if (deviceConnected) {
            String message = "Hello from T-Watch!";
            Serial.println(message);
            // Set the character value to your message
            pTxCharacteristic->setValue(payload.c_str());
            
            // Fire the notification to the connected phone
            pTxCharacteristic->notify();
            
            Serial.print("Sent to Tasker: ");
            Serial.println(message);
          }


        }
        for (int i = 0; i < totalKeys; i++) {
          btMessages[keysToDelete[i]] = undefined;
        }
      }
    
      int taskCount = dualCoreTasks.length();
      if (taskCount > 0) {
        for (int i = 0; i < taskCount; i++) {
          if (dualCoreTasks[i] == null) continue; 

          JSONVar dct = dualCoreTasks[i];
          String dctstring = (const char *)dct["task"];
          long scheduledTime = dct["millis"]; 
          long taskDelay = 0;

          if (dct.hasOwnProperty("delay")) {
              taskDelay = dct["delay"];
          }
          if (millis() - scheduledTime >= taskDelay) {
            taskToExecute = (const char *)dct["task"]; 
            
            // Clear the slot immediately while locked
            dualCoreTasks[i] = JSONVar(); 
            taskIndexToRemove = i; 

            // Break the loop early so we can execute this single task safely
            break; 
          }
        }
      }
      if (taskIndexToRemove != -1) {
        // Clear it by wiping its internal object keys cleanly
        dualCoreTasks[taskIndexToRemove] = JSONVar(); 
      }
      xSemaphoreGive(taskMutex); 
    }
    if (taskToExecute != "") {
      if (taskToExecute == "homebasePing") {
        homebasePing(); // Wi-Fi lag here will NO LONGER stall Core 1
      }
      // Add other task conditions here if needed
    }
    // Remember to leave a delay so Core 0 can handle Wi-Fi/System tasks
    vTaskDelay(10 / portTICK_PERIOD_MS); 
  }
}

void stream_large_payload(String massive_string) {
  // 1. Define packet size based on standard safe MTU lengths
  const int CHUNK_SIZE = 240; 
  int total_length = massive_string.length();
  int position = 0;

  Serial.printf("Starting 100KB stream. Total Bytes: %d\n", total_length);

  // 2. Loop through the string and chop it into pieces
  while (position < total_length) {
    // Take a slice of the string up to the chunk limit
    String chunk = massive_string.substring(position, position + CHUNK_SIZE);
    
    // Pass the raw data slice to your Nordic TX characteristic pointer
    pTxCharacteristic->setValue((uint8_t*)chunk.c_str(), chunk.length());
    pTxCharacteristic->notify(); // Push to Tasker
    
    position += CHUNK_SIZE;

    // 3. FLOW CONTROL: Give the Bluetooth stack 15ms to physically send the radio frame
    // This stops the chip's memory buffer from overflowing and crashing
    vTaskDelay(pdMS_TO_TICKS(15)); 
  }

  // 4. END OF FILE (EOF) MARKER: Tell Tasker the full transmission is finished!
  String eof_marker = "===EOF===";
  pTxCharacteristic->setValue((uint8_t*)eof_marker.c_str(), eof_marker.length());
  pTxCharacteristic->notify();
  
  Serial.println("100KB Stream finished completely.");
}


void awake_notifications() {
  if (millis() - notMillis > 1000) {
    notMillis = millis();
    long ts = timestamp_maker();
    if (notifications.length() > 0) {
      if (ts > next_notification && next_notification != 0) {
        notification_display(notifications[0]["title"], notifications[0]["notification"]);
        notifications[0] = undefined;
        next_notification = 0;
        notifications_processor();
      }
    }
  }
}

void readRadio() {
  if (operationDone) {
    operationDone = false;
    String str;      
    int state = radio.readData(str);
    if (state == RADIOLIB_ERR_NONE) {
      // packet was successfully received
      // Serial.println(F("[SX1262] Received packet!"));
      
      // print data of the packet
      // Serial.print(F("[SX1262] Data:\t\t"));
      // Serial.println(str);
      
      // print RSSI (Received Signal Strength Indicator)
      // Serial.print(F("[SX1262] RSSI:\t\t"));
      // Serial.print(radio.getRSSI());
      // Serial.println(F(" dBm"));
      
      // print SNR (Signal-to-Noise Ratio)
      // Serial.print(F("[SX1262] SNR:\t\t"));
      // Serial.print(radio.getSNR());
      // Serial.println(F(" dB"));
      radio.startReceive();

      JSONVar js = JSON.parse(str);
      String string = JSON.stringify(js);
      Serial.println(str);
      String ssid_check = (const char *)js["ap_ssid"];
      String msg_check = (const char *)js["msg"];
      String chat_check = (const char *)js["m"];
      if (chat_check != "") {
        String username = js["u"];
        String message = js["m"];
        Serial.println(str);
        if (authorization != "") {
          String request = "https://" + homebaseIP + "/watch/chat_received?message=" + urlEncode(message) + "&username=" + urlEncode(username);
          Serial.println(request);
          String information = https_request(request);
          Serial.println(information);
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
        returner["time"] = timestamp_maker();
        String returns = JSON.stringify(returner);
     //   radio.startTransmit(returns);
     //   Serial.println(returns);
     //   delay(1000);
      }
      else if (msg_check != "") {
        buttonMillis = millis();
        lastMillis = millis();
        pmuIrq = true;
        String app = (const char *)js["app"];
        
        Serial.println("Got a message: " + msg_check);
        JSONVar result = JSON.parse(https_request(
          "https://" + homebaseIP +
          "/watch/telephone_msg?timestamp=" + timestamp_maker() +
          "&msg=" + msg_check + "&app=" + app
        ));
        String rs = JSON.stringify(result);
        Serial.println(rs);
      }
    }
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
    int numberOfTries = 12;
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
        Serial.print("Wifi failed to connect");
        Serial.print(ssid + " " + password);
        WiFi.disconnect();
        wifi_enabled = false;
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

void homebasePing() {
  if (wifi_enabled == true && buttoned_before) {
    String https = https_request(
      "https://" + homebaseIP + "/watch/alive?millis=" + millis()
    );
    JSONVar alive;
    if (https != "failure") {
      alive = JSON.parse(https);
    }
  }
}

void notifications_processor() {
  double next_time = 0;
  String check = "no";
  long timestamp = timestamp_maker();
  wakeup_time = 0;
  int length = notifications.length();
  if (length > 0) {
    for (int i = 0; i < length; i++) {

      String times = notifications[i]["timestamp"];
      long ts = times.toInt();
      if (timestamp < ts) {
        if (check == "no") {
          check = "yes";
          Serial.println("checking");
          wakeup_time = (double)notifications[i]["next_time"];
          next_notification = ts;
        }
      }
      else {
        notifications[i] = undefined;
      }
    }
  }
}

void notification_display(String title, String notification) {
  if (title) {
    jw_room = "message";

    static const char *btns[] = {""};

    int t_length = title.length() + 1;
    int n_length = notification.length() + 1;
    char t[t_length];
    char n[n_length];

    title.toCharArray(t, t_length);
    notification.toCharArray(n, n_length);

    lv_obj_t * mb = lv_msgbox_create(lv_scr_act(), t, n, btns, true);


    //  lv_obj_center(mb);
    lv_obj_set_y(mb, 35);

    lv_task_handler();
    wakeup();
  }
}

void wakeup() {
  // Serial.println("Wakeup");
  watch.configreFeatureInterrupt(
    SensorBMA423::INT_STEP_CNTR |   // Pedometer interrupt
    SensorBMA423::INT_ACTIVITY |    // Activity interruption
    SensorBMA423::INT_TILT |        // Tilt interrupt
    // SensorBMA423::INT_WAKEUP |      // DoubleTap interrupt
    SensorBMA423::INT_ANY_NO_MOTION,// Any  motion / no motion interrupt
    true);
  watch.incrementalBrightness(brightnessLevel);
  //display_exit();
  buttonMillis = millis();
  lastMillis = millis();
  pmuIrq = false;
  watch.setWaveform(0, vibrateLevel);  // play effect
  // play the effect!
  watch.run();

  
}

void display_exit( void ) {
  lv_obj_clean ( lv_scr_act() ); // Clean objects from current screen.
  lv_obj_invalidate( lv_scr_act() ); // Invalidate objects for redraw.
  button_writer();
//  time_writer("now");
}

long timestamp_maker() {
  struct tm timeinfo;
  watch.getDateTime(&timeinfo);

  time_t timestamp = mktime(&timeinfo);
  long ts = (long)timestamp;
  if (offset) {
    ts = timestamp - rtc.offset;
  }
  return ts;
}

void time_writer(char * situation) {
  if (situation == "now") {
    tft.fillScreen(TFT_BLACK);
  }
  if (millis() - lastMillis > 1000 || situation == "now") {
    lastMillis = millis();
    if (notification_viewing == 1) {
      notification_review();
    }
    else {

      struct tm timeinfo;
      // Get the time C library structure
      watch.getDateTime(&timeinfo);
      size_t written_date = strftime(bufdate, 64, "%a %b %d %Y", &timeinfo);
      size_t written_time = strftime(buftime, 64, "%H:%M", &timeinfo);
      size_t written_sec = strftime(bufsec, 64, "%S", &timeinfo);
      watch.setTextFont(2);
      watch.setTextColor(TFT_YELLOW, TFT_BLACK);
      if (written_date != 0) {

        watch.drawString(bufdate, 120, 20);
      }
      if (written_time != 0) {
        watch.setTextFont(8);
        watch.drawString(buftime, 120, 70);
      }
      if (written_sec != 0) {
        watch.setTextFont(4);
        watch.drawString(bufsec, 120, 130);
      }
      if (stepCounter == true) {
        watch.setCursor(10,120);
        watch.print(steps);
      }
    }
  }
}

void ip_writer() {
  watch.setTextFont(2);
  IPAddress ip = WiFi.localIP();
  sprintf(bufIP, "%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
  watch.setTextColor(TFT_BLACK, TFT_WHITE);
  IPAddress gw_ip = WiFi.gatewayIP();
  sprintf(bufgwIP, "%d.%d.%d.%d", gw_ip[0], gw_ip[1], gw_ip[2], gw_ip[3]);
  watch.drawString(bufIP, 50, 130);
  watch.drawString(bufgwIP, 190, 130);
  if (wifi_ap_enabled) {
    apIP = WiFi.softAPIP();
    sprintf(bufapIP, "%d.%d.%d.%d", apIP[0], apIP[1], apIP[2], apIP[3] );
    watch.drawString(bufapIP, 50, 150);
    watch.drawString(bufapgwIP, 190, 150);
  }  
}

void button_writer() {
  btn1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn1, touch_button1, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn1, 65, 190 );
  lv_obj_set_size(btn1, 50, 50 );
  lv_obj_set_style_bg_color(btn1, lv_color_hex(0xde2716), LV_PART_MAIN);

  lv_obj_t *l1;
  lv_color_t t1;
  t1 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn1, t1, LV_PART_MAIN);
  l1 = lv_label_create(btn1);
  lv_label_set_text(l1, "Rom");
  lv_obj_center(l1);

  btn2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn2, touch_button2, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn2, 10, 190 );
  lv_obj_set_size(btn2, 50, 50 );
  lv_obj_set_style_bg_color(btn2, lv_color_hex(0xffca38), LV_PART_MAIN);

  lv_obj_t *l2;
  lv_color_t t2;
  t2 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn2, t2, LV_PART_MAIN);
  l2 = lv_label_create(btn2);
  lv_label_set_text(l2, "Clk");
  lv_obj_center(l2);

  btn3 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn3, touch_button3, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn3, 120, 190 );
  lv_obj_set_size(btn3, 50, 50 );
  lv_obj_set_style_bg_color(btn3, lv_color_hex(0xfa3ced), LV_PART_MAIN);

  lv_obj_t *l3;
  lv_color_t t3;
  t3 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn3, t3, LV_PART_MAIN);
  l3 = lv_label_create(btn3);
  lv_label_set_text(l3, "Set");
  lv_obj_center(l3);

  btn6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn6, touch_button4, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn6, 175, 190 );
  lv_obj_set_size(btn6, 50, 50 );
  lv_obj_set_style_bg_color(btn6, lv_color_hex(0x1aacfd), LV_PART_MAIN);

  lv_obj_t *l6;
  lv_color_t t6;
  t6 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(btn6, t6, LV_PART_MAIN);
  l6 = lv_label_create(btn6);
  lv_label_set_text(l6, "Net");
  lv_obj_center(l6);

  lv_task_handler();
}


void https_download(fs::FS &fs, String url, String filename) {
  url = url_maker(url);
  Serial.println("In the https download");
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
            uint8_t buff[1048] = { 0 };

            WiFiClient * stream = https.getStreamPtr();
            while (https.connected() &&  (len > 0 || len == -1)) {
              // read up to 128 byte
              size_t size = stream->available();
              Serial.println(size);
              if (size) {
                Serial.println("Got a size");
                int c = stream->readBytes(buff, ((size > sizeof(buff)) ? sizeof(buff) : size));

                // write it to Serial
                //  Serial.write(buff, c);
                appendFile(FFat, filename.c_str(), (char *) buff);
                if (len > 0) {
                  len -= c;
                }
              }
            }
          }
        }
      }
      https.end();

    }
  }
}

String chip_id_maker() {
  uint32_t chipId = 0;
  for(int i=0; i<17; i=i+8) {
    chipId |= ((ESP.getEfuseMac() >> (40 - i)) & 0xff) << i;
  }
  String chip_id = String(chipId);
  return chip_id;
}

String url_maker(String url) {
  String chip_id = chip_id_maker();
  long timestamp = timestamp_maker();
  url = url + "&edt=watch&chip_id=" + chip_id + "&authorization=" + authorization + "&timestamp=" + timestamp;
  return url;
}

String https_request(String url, String method, String payloadData) {
  url = url_maker(url);
  Serial.println(url);
  WiFiClientSecure *connexion = new WiFiClientSecure;
  String https_returner = "failure";
  connexion -> setInsecure();
  if (connexion) {
    // Serial.println ("there is a connection");
    {
      HTTPClient https;
      if (https.begin(*connexion, url)) {
         Serial.println("est connection");
        int httpCode = https.GET();
        if (method == "POST") {
          Serial.println("Executing HTTPS POST...");
           // If your POST needs a payload string later, pass it here instead of ""
          httpCode = https.POST(""); 
        }
        if (httpCode > 0) {
           Serial.printf("HTTPS GET code: %d\n", httpCode);

          if (httpCode == HTTP_CODE_OK) {
            String payload = https.getString();
             Serial.print(payload);
             Serial.println(payload);
            return payload;

          }
        }
        else {
          // Serial.printf("HTTPS FAILED error: %s\n", https.errorToString(httpCode).c_str());
          writeFile(FFat, "/bootreport.txt", "failure");

          return "failure";
        }
        https.end();
      }
    }
  }
  return "failure";
}

void call_the_president() {
  // Serial.println("dans presidente");
  // Serial.println(before_me);
  // Serial.println("copy");
  JSONVar result;

  if (!buttoned_before) {
    String req = "https://" + homebaseIP + "/watch?room=" + room;
     Serial.println(req);
    String watchRequest = https_request(req);
     Serial.println(watchRequest);
    if (watchRequest != "failure") {
      Serial.println("President doesnt see it as a failure");
      before_me = watchRequest;
      buttoned_before = true;
      result = JSON.parse(before_me);
      
      // Serial.println(before_me);
      int32_t year = result["__specs"]["time"]["year"];
      int32_t month = result["__specs"]["time"]["month"];
      int32_t day =  result["__specs"]["time"]["day"];;
      int32_t hour =  result["__specs"]["time"]["hour"];
      int32_t minute = result["__specs"]["time"]["min"];
      int32_t second = result["__specs"]["time"]["sec"];
    
      watch.setDateTime(year, month, day, hour, minute, second);
      // Reading time synchronization from RTC to system time
      watch.hwClockRead();
      buttonMillis = millis();
      lastMillis = millis();
  
    }
    else {
      writeFile(FFat, "/bootreport.txt", "failure");

    }
    Serial.println("after watch request");

  }
  else {
    Serial.println("Not buttoned before");
  }

}

void presidents_buttons() {
  JSONVar result;
  Serial.println("in the buttons");
  lv_obj_t * led1  = lv_led_create(lv_scr_act());
  lv_obj_set_pos(led1, 10, 160 );
  lv_led_set_color(led1, lv_palette_main(LV_PALETTE_RED));
  lv_led_off(led1);
  lv_obj_t * led2 = lv_label_create(lv_scr_act());
  lv_obj_set_pos(led2, 45, 160);
  lv_obj_set_style_text_color(led2, lv_palette_main(LV_PALETTE_GREEN), LV_PART_MAIN);

  if (!buttoned_before) {
    watch.drawString("Ne pas Presidente", 80, 80);
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
  Serial.println("after before me parsing");
  if (room > room_count) { room = 1; }  
  int sb = ((room - 1) * 6) + 1;

  // Serial.println(room);
  // Serial.println(sb);
  lv_obj_t * b1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b1, mb1, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b1, 10, 10 );
  lv_obj_set_size(b1, 60, 60 );
  lv_color_t c1;
  lv_color_t t1;
  int tog1 = result["b" + String(sb)]["toggle"]; 

  if (tog1 == 1) {
    t1 = lv_color_make(0,0,0);
    c1 = lv_color_make(255,255,0);
  }
  else {
    c1 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t1 = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b1, t1, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b1, c1, LV_PART_MAIN);
  lv_obj_t *l1;
  l1 = lv_label_create(b1);
  lv_label_set_text(l1, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l1);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b1_toggle);
  lv_obj_t * b2 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b2, mb2, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b2, 90, 10 );
  lv_obj_set_size(b2, 60, 60 );
  lv_color_t c2;
  lv_color_t t2;
  int tog2 = result["b" + String(sb)]["toggle"]; 
  
  if (tog2 == 1) {
    t2 = lv_color_make(0,0,0);
    c2 = lv_color_make(255,255,0);
  }
  else {
    c2 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t2 = lv_color_make(255,255,255);
  }  
  lv_obj_set_style_bg_color(b2, c2, LV_PART_MAIN);
  lv_obj_set_style_text_color(b2, t2, LV_PART_MAIN);  
  lv_obj_t *l2;
  l2 = lv_label_create(b2);
  lv_label_set_text(l2, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l2);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b2_toggle);
  lv_obj_t * b3 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b3, mb3, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b3, 170, 10 );
  lv_obj_set_size(b3, 60, 60 );
  lv_color_t c3;
  lv_color_t t3;
  int tog3 = result["b" + String(sb)]["toggle"]; 

  if (tog3 == 1) {
    t3 = lv_color_make(0,0,0);
    c3 = lv_color_make(255,255,0);
  }
  else {
    c3 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t3 = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b3, t3, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b3, c3, LV_PART_MAIN);
  lv_obj_t *l3;
  l3 = lv_label_create(b3);
  lv_label_set_text(l3, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l3);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b3_toggle);
  lv_obj_t * b4 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b4, mb4, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b4, 10, 90 );
  lv_obj_set_size(b4, 60, 60 );
  lv_color_t c4;
  lv_color_t t4;
  int tog4 = result["b" + String(sb)]["toggle"]; 

  if (tog4 == 1) {
    t4 = lv_color_make(0,0,0);
    c4 = lv_color_make(255,255,0);
  }
  else {
    c4 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t4 = lv_color_make(255,255,255);
  }
  lv_obj_set_style_text_color(b4, t4, LV_PART_MAIN);  
  lv_obj_set_style_bg_color(b4, c4, LV_PART_MAIN);
  lv_obj_t *l4;
  l4 = lv_label_create(b4);
  lv_label_set_text(l4, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l4);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b4_toggle);
  lv_obj_t * b5 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b5, mb5, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b5, 90, 90 );
  lv_obj_set_size(b5, 60, 60 );
  lv_color_t c5;
  lv_color_t t5;
  int tog5 = result["b" + String(sb)]["toggle"]; 

  if (tog5 == 1) {
    t5 = lv_color_make(0,0,0);
    c5 = lv_color_make(255,255,0);
  }
  else {
    t5 = lv_color_make(255,255,255);
    c5 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
  }
  lv_obj_set_style_text_color(b5, t5, LV_PART_MAIN);
  lv_obj_set_style_bg_color(b5, c5, LV_PART_MAIN);
  lv_obj_t *l5;
  l5 = lv_label_create(b5);
  lv_label_set_text(l5, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l5);

  sb = sb + 1;
  // Serial.println(sb + ' toggle:' + b5_toggle);
  // Serial.println("b" + String(sb));
  lv_obj_t * b6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(b6, mb6, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(b6, 170, 90 );
  lv_obj_set_size(b6, 60, 60 );
  lv_color_t c6;
  lv_color_t t6;
  // Serial.println(result["b" + String(sb)]["toggle"]);
  int tog6 = result["b" + String(sb)]["toggle"]; 
  if (tog6 == 1) {
    c6 = lv_color_make(255,255,0);
    t6 = lv_color_make(0,0,0);
  }
  else {
    c6 = lv_color_make(result["b" + String(sb)]["rgb"][0], result["b" + String(sb)]["rgb"][1], result["b" + String(sb)]["rgb"][2]);
    t6 = lv_color_make(255,255,255);
  }  
  lv_obj_set_style_bg_color(b6, c6, LV_PART_MAIN);
  lv_obj_set_style_text_color(b6, t6, LV_PART_MAIN);    
  
  lv_obj_t *l6;
  l6 = lv_label_create(b6);
  lv_label_set_text(l6, result["b" + String(sb)]["shorthand_name"]);
  lv_obj_center(l6);
  buttonMillis = millis();
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
  watch.fillScreen(TFT_BLACK);
  call_the_president();
  presidents_buttons();
  button_writer();
}

unsigned long getTime() {
  time_t now;
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo)) {
    //Serial.println("Failed to obtain time");
    return (0);
  }
  time(&now);
  return now;
}
static void audio_button(lv_event_t * e) {
    lv_event_code_t code = lv_event_get_code(e);
    lv_obj_t * btn = lv_event_get_target(e);
    lv_obj_t * btn_label = lv_obj_get_child(btn, 0);

    if (btn == recbtn1) {
        if (code == LV_EVENT_PRESSED) {
            if (isPlaying) return; // Prevent conflicts during execution
            
            isRecording = true;
            lv_label_set_text(btn_label, "Recording...");
            String filename = String(timestamp_maker()) + ".wav";
            saveFileToFolder("/recordings", filename.c_str());
            
            WAV_FILE_PATH = "/recordings/" + filename;
            xTaskCreatePinnedToCore(micCaptureTask, "MicTask", 4096, NULL, 2, NULL, 1);

        } else if (code == LV_EVENT_RELEASED) {
            if (isRecording) {
                isRecording = false; 
                lv_label_set_text(btn_label, "Rec");
            }
        }
    }
    else if (btn == playbtn1) {
        if (code == LV_EVENT_CLICKED) {
            if (isRecording) return; 

            if (!isPlaying) {
                if (!FFat.exists(WAV_FILE_PATH.c_str())) {
                    lv_label_set_text(btn_label, "No File Found");
                    return;
                }

                isPlaying = true;
                lv_label_set_text(btn_label, "Playing...");

                // Initialize template playback structure elements dynamically
                out_hardware = new AudioOutputI2S(1, AudioOutputI2S::EXTERNAL_I2S);
                out_hardware->SetPinout(BOARD_DAC_IIS_BCK, BOARD_DAC_IIS_WS, BOARD_DAC_IIS_DOUT);
                file_source = new AudioFileSourceFATFS(WAV_FILE_PATH.c_str());
                wav = new AudioGeneratorWAV();
                wav->begin(file_source, out_hardware);

                xTaskCreatePinnedToCore(audio_playback_loop_task, "PlayTask", 4096, NULL, 2, NULL, 1);
            } else {
                // Tapping while playing forces an emergency stop sequence
                isPlaying = false; 
            }
        }
    }
}


// Generates the proper 44-byte RIFF layout header directly into local flash storage
bool create_wav_header_on_flash(const char *song_name, const uint32_t sampling_rate, uint16_t bits_per_sample) {
    // Open file to write structural container. Size will be updated upon release.
    File new_audio_file = FFat.open(song_name, FILE_WRITE);
    if (!new_audio_file) {
        Serial.println("[WAV] Failed to create storage file partition!");
        return false;
    }

    uint8_t header[44] = {
        'R', 'I', 'F', 'F',
        0, 0, 0, 0,       // ChunkSize placeholder (updated later)
        'W', 'A', 'V', 'E',
        'f', 'm', 't', ' ',
        16, 0, 0, 0,      // Subchunk1Size
        1, 0,             // AudioFormat PCM
        1, 0,             // Mono channel (1)
        (uint8_t)(sampling_rate & 0xff), (uint8_t)((sampling_rate >> 8) & 0xff), 0, 0,
        0, 0, 0, 0,       // ByteRate placeholder (updated later)
        (uint8_t)((1 * bits_per_sample) / 8), 0, // BlockAlign
        (uint8_t)bits_per_sample, 0,             // BitsPerSample
        'd', 'a', 't', 'a',
        0, 0, 0, 0        // Subchunk2Size placeholder (updated later)
    };

    new_audio_file.write(header, 44);
    new_audio_file.close();
    return true;
}

// Rewrites header placeholders with the exact byte sizes after recording stops
void finalize_wav_sizes(const char *song_name, uint32_t raw_pcm_bytes) {
    File audio_file = FFat.open(song_name, "r+");
    if (!audio_file) return;

    uint32_t chunk_size = raw_pcm_bytes + 36;
    uint32_t byte_rate = MIC_I2S_SAMPLE_RATE * 1 * (MIC_I2S_BITS_PER_SAMPLE / 8);

    // Update ChunkSize field (offset index 4)
    audio_file.seek(4);
    audio_file.write((uint8_t*)&chunk_size, 4);

    // Update ByteRate field (offset index 28)
    audio_file.seek(28);
    audio_file.write((uint8_t*)&byte_rate, 4);

    // Update Subchunk2Size field (offset index 40)
    audio_file.seek(40);
    audio_file.write((uint8_t*)&raw_pcm_bytes, 4);

    audio_file.close();
    Serial.printf("[WAV] Header successfully updated. File size: %lu bytes.\n", raw_pcm_bytes + 44);
}

// FreeRTOS background task handling the microphone pipeline data stream
void micCaptureTask(void *pvParameters) {
    if (!create_wav_header_on_flash(WAV_FILE_PATH.c_str(), MIC_I2S_SAMPLE_RATE, MIC_I2S_BITS_PER_SAMPLE)) {
        isRecording = false;
        vTaskDelete(NULL);
    }

    File audio_file = FFat.open(WAV_FILE_PATH.c_str(), FILE_APPEND);
    if (!audio_file) {
        isRecording = false;
        vTaskDelete(NULL);
    }

    uint8_t *tempBuf = (uint8_t *)malloc(AUDIO_BUFFER_CHUNK_SIZE);
    uint32_t bytes_written_total = 0;
    size_t system_bytes = 0;

    Serial.println("[Recorder] Flash append loop initialized.");

    while (isRecording) {
        if (watch.readMicrophone((char *)tempBuf, AUDIO_BUFFER_CHUNK_SIZE, &system_bytes)) {
            if (system_bytes > 0) {
                audio_file.write(tempBuf, system_bytes);
                bytes_written_total += system_bytes;
            }
        }
        vTaskDelay(pdMS_TO_TICKS(1)); // Yield to protect system core execution stability
    }

    audio_file.close();
    free(tempBuf);

    // Patch structural sizing tags so whisper.cpp can process it cleanly
    finalize_wav_sizes(WAV_FILE_PATH.c_str(), bytes_written_total);
    vTaskDelete(NULL);
}

// Background monitoring frame calculation handler for playback
void audio_playback_loop_task(void *pvParameters) {
    Serial.println("[Player] Playback track active.");
    out_hardware->SetGain((float)volumeLevel / 100.0f);

    while (isPlaying) {
        if (wav->isRunning()) {
            if (!wav->loop()) {
                wav->stop();
                isPlaying = false;
            }
        } else {
            isPlaying = false;
        }
        vTaskDelay(pdMS_TO_TICKS(2));
    }

    // Safely clean memory resources upon completion
    if(wav) { delete wav; wav = nullptr; }
    if(file_source) { delete file_source; file_source = nullptr; }
    if(out_hardware) { delete out_hardware; out_hardware = nullptr; }

    // Safely restore playback button graphics text layer
    lv_obj_t * btn_label = lv_obj_get_child(playbtn1, 0);
    lv_label_set_text(btn_label, "Play Recording");

    vTaskDelete(NULL);
}


void when_i_get_in(JSONVar wigi_item, String url) {
  
  int l = wigi.length();
  if (l < 0) {
    l = 0;
  }
  long timestamp = timestamp_maker();  
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
  Serial.print("Defice connected: ");
  Serial.println(deviceConnected);
  if (deviceConnected) {
    String r = generateRandomString(7);
    btMessages[r]["type"] = "button";
    btMessages[r]["payload"] = wigi_item;
    url = url_maker(url);
    btMessages[r]["url"] = url;
    String payload = JSON.stringify(btMessages[r]);
    String message = "Hello from T-Watch!";
    Serial.println(message);
    // Set the character value to your message
    pTxCharacteristic->setValue(payload.c_str());
    
    // Fire the notification to the connected phone
    pTxCharacteristic->notify();
    
    Serial.print("Sent to Tasker: ");
    Serial.println(message);
  } else {
    wigi[l] = wigi_item;
  }
}
String generateRandomString(int length) {
  // Define the pool of characters you want to use
  const char charset[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  const int charsetSize = sizeof(charset) - 1;
  
  String randomString = "";
  randomString.reserve(length); // Pre-allocate memory to prevent RAM fragmentation

  for (int i = 0; i < length; i++) {
    // esp_random() fetches a true 32-bit hardware random unsigned integer
    uint32_t randomNum = esp_random(); 
    
    // Use modulo to safely pick an index within our character pool range
    int randomIndex = randomNum % charsetSize;
    
    randomString += charset[randomIndex];
  }

  return randomString;
}



void mb1(lv_event_t *e) {
  if (b1_toggle == 0) {
    b1_toggle = 1;
  } else {
    b1_toggle = 0;
  }
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=1&toggle=" + b1_toggle;
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 1;
    updater["toggle"] = b1_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  
  b1_toggle = result["toggle"];
  
  lv_obj_t * b = lv_event_get_target(e);
  lv_color_t c;
  lv_color_t t;
  if (b1_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);

  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
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
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=2&toggle=" + b2_toggle;
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 2;
    updater["toggle"] = b2_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b2_toggle = result["toggle"];
  lv_color_t c;
  lv_color_t t;
  lv_obj_t * b = lv_event_get_target(e);
  if (b2_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);  
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
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
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=3&toggle=" + b3_toggle;
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 3;
    updater["toggle"] = b3_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b3_toggle = result["toggle"];
  // Serial.println(b3_toggle);
  lv_obj_t * b = lv_event_get_target(e);
  lv_color_t c;
  lv_color_t t;
  if (b3_toggle == 1) {
    c = lv_color_make(255, 255, 0);
    t = lv_color_make(0,0,0);
   
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
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
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=4&toggle=" + b4_toggle;
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 4;
    updater["toggle"] = b4_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b4_toggle = result["toggle"];
  lv_color_t c;
  lv_color_t t;
  lv_obj_t * b = lv_event_get_target(e);
  if (b4_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
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
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=5&toggle=" + b5_toggle;
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 5;
    updater["toggle"] = b5_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  lv_obj_t * b = lv_event_get_target(e);
  lv_color_t c;
  lv_color_t t;
  if (b5_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);

  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
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
  String r = "https://" + homebaseIP +
    "/watch/button?room=" + room +
    "&button=6&toggle=" + b6_toggle;
  String https = https_request(r);
  if (https == "failure") {
    JSONVar updater;
    updater["room"] = room;
    updater["button"] = 6;
    updater["toggle"] = b6_toggle;
    when_i_get_in(updater,r);
    return;
  }
  JSONVar result = JSON.parse(https);
  b6_toggle = result["toggle"];
  lv_obj_t * b = lv_event_get_target(e);
  lv_color_t c;
  lv_color_t t;
  if (b6_toggle == 1) {
   c = lv_color_make(255, 255, 0);
   t = lv_color_make(0,0,0);
  }
  else {
    c = lv_color_make(result["rgb"][0], result["rgb"][1], result["rgb"][2]);
    t = lv_color_make(255,255,255);
  }
 lv_obj_set_style_text_color(b, t, LV_PART_MAIN);
 lv_obj_set_style_bg_color(b, c, LV_PART_MAIN);  
  JSONVar bm = JSON.parse(before_me);
  bm["b" + String(((room - 1 ) * room_max) + 6)] = result;
  before_me = JSON.stringify(bm);
}


static void touch_button2(lv_event_t *e) {
  notification_viewing = 0;
  clock_writer();
}

void clock_writer() {
  
  display_exit();

  delay(5);
  if (jw_room != "watch") {
    time_writer("now");
  }
  jw_room = "watch";

  notification_btn = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(notification_btn, notification_button, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(notification_btn, 190, 150 );
  lv_obj_set_size(notification_btn, 50, 30 );
  lv_obj_set_style_bg_color(notification_btn, lv_color_hex(0xde2716), LV_PART_MAIN);

  lv_obj_t *l1;
  lv_color_t t1;
  t1 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(notification_btn, t1, LV_PART_MAIN);
  l1 = lv_label_create(notification_btn);
  lv_label_set_text(l1, "Not");
  lv_obj_center(l1);


  recbtn1 = lv_btn_create(lv_scr_act());
  lv_obj_set_size(recbtn1, 50, 30);
  lv_obj_set_pos(recbtn1, 0, 150 );
  lv_obj_add_event_cb(recbtn1, audio_button, LV_EVENT_ALL, NULL);
  lv_obj_set_style_bg_color(recbtn1, lv_color_hex(0x5ec1ff), LV_PART_MAIN);

  // Attach the text label directly inside the button layout
  lv_obj_t * label = lv_label_create(recbtn1);
  lv_label_set_text(label, "Rec");
  lv_obj_center(label);

  playbtn1 = lv_btn_create(lv_scr_act());
  lv_obj_set_size(playbtn1, 50, 30);
  lv_obj_set_pos(playbtn1, 60, 150 );
  lv_obj_add_event_cb(playbtn1, audio_button, LV_EVENT_ALL, NULL);
  lv_obj_set_style_bg_color(playbtn1, lv_color_hex(0x5df796), LV_PART_MAIN);

  lv_obj_t * label_play = lv_label_create(playbtn1);
  lv_label_set_text(label_play, "Play");
  lv_obj_center(label_play);

  wigi_btn = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(wigi_btn, wigi_button, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(wigi_btn, 130, 150 );
  lv_obj_set_size(wigi_btn, 50, 30 );
  lv_obj_set_style_bg_color(wigi_btn, lv_color_hex(0x27de16), LV_PART_MAIN);

  lv_obj_t *l2;
  lv_color_t t2;
  t2 = lv_color_make(0,0,0);
  lv_obj_set_style_text_color(wigi_btn, t2, LV_PART_MAIN);
  l2 = lv_label_create(wigi_btn);
  lv_label_set_text(l2, "Wigi");
  lv_obj_center(l2);

  delay(5);
  lastMillis = lastMillis - 1000;
  if (notification_viewing == 1) {
    notification_review();

  }
  lv_task_handler();
}
static void wigi_button(lv_event_t *e) {
  homebasePing();
}
static void notification_button(lv_event_t *e) {
  int notification_count = notifications.length();
  if (notification_count > 0) {
    if (notification_viewing == 1) {
      if (notification_view >= notification_count - 1) {
        notification_view = 0;
      }
      else {
        notification_view++;
      }
    }
    notification_viewing = 1;
    clock_writer();
  }
  

}

void notification_review() {
  int notification_count = notifications.length();
  if (notification_count > 0 && notification_viewing == 1) {
    JSONVar notification = notifications[notification_view];
    watch.setTextFont(4);
    uint16_t watchColor = watch.color565(notification["rgb"][0], notification["rgb"][1], notification["rgb"][2]);
    watch.setTextColor(watchColor);
    String noti = "Notification " + String((notification_view + 1)) + "/" + String(notification_count);
    watch.drawString(noti, 90, 30);
    watch.setTextFont(2);

    String f_time = notification["formatted_time"];
    watch.drawString(f_time, 90,70);

    String n_title = notification["title"];
    watch.drawString(n_title, 90,100);
    String n = notification["notification"];
    watch.setTextFont(2);

    watch.drawString(n, 90,120);
  }
}

static void touch_button3(lv_event_t *e) {
  setting_room();
}
void setting_room() {
  display_exit();
  jw_room = "configure";
  lv_obj_t *slider = lv_slider_create(lv_scr_act());
  lv_slider_set_value(slider, brightnessLevel, LV_ANIM_ON);
  lv_obj_set_width(slider, 150);
  lv_obj_set_pos(slider, 10, 20);
  lv_obj_add_event_cb(slider, brightness_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

  lv_obj_t *slider1 = lv_slider_create(lv_scr_act());
  lv_slider_set_value(slider1, vibrateLevel, LV_ANIM_ON);

  lv_obj_set_width(slider1, 150);
  lv_obj_set_pos(slider1, 10, 45);
  lv_obj_add_event_cb(slider1, vibrate_event_cb, LV_EVENT_VALUE_CHANGED, NULL);

  lv_obj_t *slider2 = lv_slider_create(lv_scr_act());
  lv_obj_set_width(slider2, 150);
  lv_obj_set_pos(slider2, 10, 70);
  lv_obj_add_event_cb(slider2, volume_event_cb, LV_EVENT_VALUE_CHANGED, NULL);
  lv_slider_set_value(slider2, volumeLevel, LV_ANIM_ON);
  lv_slider_set_range(slider2, 0, 100);

  lv_obj_t * pd_button = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(pd_button, step_control, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(pd_button, 10, 100 );
  lv_obj_set_size(pd_button, 40, 40 );
  if (stepCounter == true) {
    lv_obj_set_style_bg_color(pd_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(pd_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_t *lwi1;
  lv_color_t twi1;
  twi1 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(pd_button, twi1, LV_PART_MAIN);
  lwi1 = lv_label_create(pd_button);
  lv_label_set_text(lwi1, "PD");
  lv_obj_center(lwi1);


  lv_obj_t * btn1 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn1, ap_lora_send, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn1, 190, 10 );
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
  lv_obj_set_pos(btn2, 190, 50 );
  lv_obj_set_size(btn2, 40, 40 );
  lv_obj_set_style_bg_color(btn2, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_obj_t *l2;
  lv_color_t t2;
  t2 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(btn2, t2, LV_PART_MAIN);
  l2 = lv_label_create(btn2);
  lv_label_set_text(l2, "LWI");
  lv_obj_center(l2);

  lv_color_t t51;
  t51 = lv_color_make(0,0,0);
  lv_obj_t * btn51 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn51, screenRotate, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn51, 90, 100 );
  lv_obj_set_size(btn51, 40, 40 );
  lv_obj_set_style_bg_color(btn51, lv_color_hex(0xff8923), LV_PART_MAIN);
  lv_obj_t *l51;
  lv_obj_set_style_text_color(btn51, t51, LV_PART_MAIN);
  l51 = lv_label_create(btn51);
  lv_label_set_text(l51, "Rot");
  lv_obj_center(l51);
  
  lv_color_t t5;
  t5 = lv_color_make(0,0,0);
  lv_obj_t * btn5 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn5, loraBroadcastToggle, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn5, 190, 100 );
  lv_obj_set_size(btn5, 40, 40 );
  if (loraChatBroadcaster == false) {
    lv_obj_set_style_bg_color(btn5, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(btn5, lv_color_hex(0x53ff24), LV_PART_MAIN);
  }  
  lv_obj_t *l5;
  lv_obj_set_style_text_color(btn5, t5, LV_PART_MAIN);
  l5 = lv_label_create(btn5);
  lv_label_set_text(l5, "LB");
  lv_obj_center(l5);  


  lv_obj_t * btn6 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn6, loraReceiveToggle, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn6, 140, 100 );
  lv_obj_set_size(btn6, 40, 40 );
  if (loraChatReceiver == true) {
    lv_obj_set_style_bg_color(btn6, lv_color_hex(0x53ff24), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(btn6, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }  
  lv_obj_t *l6;
  lv_obj_set_style_text_color(btn6, t5, LV_PART_MAIN);
  l6 = lv_label_create(btn6);
  lv_label_set_text(l6, "LR");
  lv_obj_center(l6); 

  lv_color_t t50;
  t50 = lv_color_make(0,0,0);
  lv_obj_t * btn50 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn50, configSaveButton, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn50, 190, 140 );
  lv_obj_set_size(btn50, 40, 40 );
  lv_obj_t *l50;
  lv_obj_set_style_text_color(btn50, t50, LV_PART_MAIN);
  l50 = lv_label_create(btn50);
  lv_label_set_text(l50, "cS");
  lv_obj_center(l50);  


  lv_obj_t * btn60 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn60, configRestoreButton, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn60, 140, 140 );
  lv_obj_set_size(btn60, 40, 40 );
  lv_obj_t *l60;
  lv_obj_set_style_bg_color(btn60, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_obj_set_style_text_color(btn60, t50, LV_PART_MAIN);
  l60 = lv_label_create(btn60);
  lv_label_set_text(l60, "cR");
  lv_obj_center(l60);

  lv_obj_t * btn601 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn601, configDeleteButton, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn601, 90, 140 );
  lv_obj_set_size(btn601, 40, 40 );
  lv_obj_t *l601;
  lv_obj_set_style_bg_color(btn601, lv_color_hex(0xdafc5d), LV_PART_MAIN);
  lv_obj_set_style_text_color(btn601, t50, LV_PART_MAIN);
  l601 = lv_label_create(btn601);
  lv_label_set_text(l601, "cD");
  lv_obj_center(l601);

  lv_obj_t * btn6012 = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(btn6012, lightSleep_toggle, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(btn6012, 10, 140 );
  lv_obj_set_size(btn6012, 40, 40 );
  lv_obj_t *l6012;
  if (lightSleep == true) {
    lv_obj_set_style_bg_color(btn6012, lv_color_hex(0x5afcdd), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(btn6012, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_set_style_text_color(btn6012, t50, LV_PART_MAIN);
  l6012 = lv_label_create(btn6012);
  lv_label_set_text(l6012, "LS");
  lv_obj_center(l6012);   

  lv_task_handler();
}

static void step_control(lv_event_t *e) {
  lv_obj_t * pd_button = lv_event_get_target(e);

  if (stepCounter == true) {
    lv_obj_set_style_bg_color(pd_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    stepCounter = false;
    watch.disablePedometer();
    watch.disablePedometerIRQ();

  }
  else {
    lv_obj_set_style_bg_color(pd_button, lv_color_hex(0x5afcdd), LV_PART_MAIN);
    stepCounter = true;
    watch.enablePedometer();
    watch.enablePedometerIRQ();

  }
}

static void lightSleep_toggle(lv_event_t *e) {
  lv_obj_t * sleep_button = lv_event_get_target(e);  

  if (lightSleep == true) {
    lv_obj_set_style_bg_color(sleep_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    lightSleep = false;
  }
  else {
    lv_obj_set_style_bg_color(sleep_button, lv_color_hex(0x5afcdd), LV_PART_MAIN);
    lightSleep = true;
  }
}

static void configSaveButton(lv_event_t *e) {
  configSave();
  configSaveBackup();
}

static void configRestoreButton(lv_event_t *e) {
  configRestore();
  setting_room();
}

static void configDeleteButton(lv_event_t *e) {
  configDelete();
}

static void screenRotate(lv_event_t *e) {
  if (screenRotation >= 3) {
    screenRotation = 0;
  } else {
    screenRotation++;
  }
  watch.decrementBrightness(0);
  configSave();
  configRestore();
  watch.incrementalBrightness(brightnessLevel);

}

static void loraBroadcastToggle(lv_event_t *e) {
  lv_obj_t * lora_button = lv_event_get_target(e);  
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
  lv_obj_t * lora_button = lv_event_get_target(e);  
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

static void bt_control(lv_event_t *e) {
  lv_obj_t * bt_button = lv_event_get_target(e);
  if (bt_enabled == true) {
    stop_ble_transfer();
    lv_obj_set_style_bg_color(bt_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  else {
    start_ble_transfer();

    lv_obj_set_style_bg_color(bt_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
}

static void wifi_ap_control(lv_event_t *e) {
  lv_obj_t * wifi_ap_button = lv_event_get_target(e);
  if (wifi_ap_enabled == true) {
    accesspoint_stop();
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
    
  }
  else {
    accesspoint_start();
    lv_obj_set_style_bg_color(wifi_ap_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
}

void accesspoint_start() {
  if (wifi_ap_enabled == false) {
    IPAddress gw_ip(192, 168, 3, 1);
    IPAddress ip(192, 168, 3, 1);
    IPAddress subnet(255, 255, 255, 0);
    if (wifi_update != "") {
      JSONVar wifi = JSON.parse(wifi_update);
      ap_ssid = (const char *)wifi["ap_ssid"];
      ap_password = (const char *)wifi["ap_password"];
    }
    if (WiFi.softAP(ap_ssid, ap_password)) {
      WiFi.softAPConfig(ip, gw_ip, subnet); //, IPAddress dhcp_lease_start = (uint32_t)0, IPAddress dns = (uint32_t)0);
      server.begin();
      webserver_enabled = true;
      wifi_ap_enabled = true;
      apIP = WiFi.softAPIP();
    }
  }
}

void accesspoint_stop() {
  if (wifi_ap_enabled == true) {
    WiFi.softAPdisconnect(true);
    wifi_ap_enabled = false;
    if (wifi_enabled == false) {
      webserver_enabled = false;
      server.stop();

    }
  }
}



static void wifi_control(lv_event_t *e) {
  lv_obj_t * wifi_button = lv_event_get_target(e);
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
      wifi_enabled = false;
      if (wifi_ap_enabled == false) {
        server.stop();
        webserver_enabled = false;
      }      
    }
  }
}

static void brightness_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  brightnessLevel = level;
  watch.setBrightness(brightnessLevel);

}

static void vibrate_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  vibrateLevel = level;
  watch.setWaveform(0, vibrateLevel);  // play effect
  // play the effect!
  watch.run();
}

static void volume_event_cb(lv_event_t *e)
{
  lv_obj_t *slider = lv_event_get_target(e);
  char buf[8];
  lv_snprintf(buf, sizeof(buf), "%d%%", (int)lv_slider_get_value(slider));
  uint8_t level = (uint8_t)lv_slider_get_value(slider);
  volumeLevel = level;
}


void touch_watch() {
  if (watch.getTouched()) {
    buttonMillis = millis();
    //    lv_point_t point;
    //    lv_indev_t *indev = lv_indev_get_next(NULL);
    //    lv_indev_get_point(indev, &point);
    //    Serial.print(point.x); Serial.print(" "); Serial.println(point.y);

  }
}

void lowPowerEnergyHandler()
{
  Serial.println("Enter light sleep mode!");
 
  buttonMillis = 0;
  brightnessLevel = watch.getBrightness();
  watch.decrementBrightness(0);

  watch.clearPMU();

  watch.configreFeatureInterrupt(
    SensorBMA423::INT_STEP_CNTR |   // Pedometer interrupt
    SensorBMA423::INT_ACTIVITY |    // Activity interruption
    SensorBMA423::INT_TILT |        // Tilt interrupt
    SensorBMA423::INT_WAKEUP |      // DoubleTap interrupt
    SensorBMA423::INT_ANY_NO_MOTION,// Any  motion / no motion interrupt
    false);

  sportsIrq = false;
  pmuIrq = false;
  if (WiFi.status() == WL_CONNECTED && buttoned_before) {
    String req = "https://" + homebaseIP + "/watch/next_appt?format=sleep";
    Serial.println(req);
    wakeup_time = 0;
    String wakeup_string = https_request(req);
    if (wakeup_string != "failure") {
      Serial.println(wakeup_string);
      notifications = JSON.parse(wakeup_string);

    }
    notifications_processor();

  }
  else { notifications_processor(); }
  //TODO: Low power consumption not debugged
  configSave();
 // Serial.flush(); 
  watch.writecommand(0x10);

  if (lightSleep) {
    
    Serial.println("right before sleep");
    uint64_t wakeup_pin = _BV(BOARD_PMU_INT);
    esp_sleep_enable_ext1_wakeup((wakeup_pin), ESP_EXT1_WAKEUP_ALL_LOW);
 //   esp_sleep_enable_ext0_wakeup((gpio_num_t)_BV(BMA423_TILT_INT), 1); // 0 = LOW
 //   gpio_wakeup_enable ((gpio_num_t)BMA423_TILT_INT, GPIO_INTR_HIGH_LEVEL);
 //   esp_sleep_enable_gpio_wakeup();
 
    int default_wakeup = (60 * 60 * 3);
    if (wakeup_time != 0) {
      Serial.print("Waking in ");
      if (wakeup_time > default_wakeup) {
        wakeup_time = default_wakeup;
      }
      Serial.print(wakeup_time);
      Serial.println(" seconds");
      esp_sleep_enable_timer_wakeup(wakeup_time * 1000000ULL);
    }
    else {
      wakeup_time = default_wakeup;
    }
    bool temp_bt_enabled = bt_enabled;
    stop_ble_transfer();

    esp_light_sleep_start();
    Serial.println("right after sleep");
    if (temp_bt_enabled == true) {
      start_ble_transfer();
    }
    
    esp_sleep_wakeup_cause_t wakeup_reason = esp_sleep_get_wakeup_cause();
    if (wakeup_reason == ESP_SLEEP_WAKEUP_TIMER) {
      next_notification = 0;
      Serial.println("Wakeup was caused by the timer!");
      notification_display(notifications[0]["title"], notifications[0]["notification"]);
      notifications[0] = undefined;
    } else if (wakeup_reason == ESP_SLEEP_WAKEUP_EXT0 || wakeup_reason == ESP_SLEEP_WAKEUP_EXT1) {
        Serial.println("Wakeup was caused by an external GPIO button!");
    } else {
        // Returns ESP_SLEEP_WAKEUP_UNDEFINED (0) if it was a normal power-on or hard reset
        Serial.printf("Wakeup was not from sleep. Code: %d\n", wakeup_reason);
    }


  } else {
    setCpuFrequencyMhz(80);
    //my_print("=========esp_light_sleep_start=========\n");
    char count = 0;

    while (!pmuIrq && !sportsIrq) {// && !watch.getTouched()) {
      if (jw_room == "message") {
        if (buttonMillis != 0  && millis() - buttonMillis > DEFAULT_SCREEN_TIMEOUT && count > 58) {
          lowPowerEnergyHandler();
          count = 0;
        }

        else {
          count++;
        }
      }
      if (webserver_enabled == true) {
        server.handleClient();
      }
      awake_notifications();
      readRadio();
      delay(500);
      // gpio_wakeup_enable ((gpio_num_t)BOARD_TOUCH_INT, GPIO_INTR_LOW_LEVEL);
      // esp_sleep_enable_timer_wakeup(3 * 1000);
      // esp_light_sleep_start();
    }
    //my_print("=========esp_light_sleep_end=========\n");

  }
  if (brightnessLevel <= 1) {
    brightnessLevel = 20;
  }
  watch.writecommand(0x11);

  watch.incrementalBrightness(brightnessLevel);
  Serial.println("just before frequency");
  setCpuFrequencyMhz(240);
  step_writer();
  // Clear Interrupts in Loop
  // watch.readBMA();
  // watch.clearPMU();

  watch.configreFeatureInterrupt(
  //  SensorBMA423::INT_STEP_CNTR |   // Pedometer interrupt
 //   SensorBMA423::INT_ACTIVITY,     // Activity interruption
    SensorBMA423::INT_TILT,         // Tilt interrupt
 //   SensorBMA423::INT_WAKEUP,       // DoubleTap interrupt
   // SensorBMA423::INT_ANY_NO_MOTION,// Any  motion / no motion interrupt
  true);
  //JSONVar dct;
  //dct["task"] = "homebasePing";
  //dualCoreTaskMaker(dct);

}

void settingSensor()
{
  //Default 4G ,200HZ
  watch.configAccelerometer();

  watch.enableAccelerometer();

  watch.enablePedometer();

  watch.configInterrupt();

  watch.enableFeature(
    SensorBMA423::FEATURE_STEP_CNTR |
    SensorBMA423::FEATURE_ANY_MOTION |
    SensorBMA423::FEATURE_NO_MOTION |
    SensorBMA423::FEATURE_ACTIVITY |
    SensorBMA423::FEATURE_TILT |
    SensorBMA423::FEATURE_WAKEUP,
    true);

  watch.enablePedometerIRQ();
  watch.enableTiltIRQ();
  watch.enableWakeupIRQ();
  watch.enableAnyNoMotionIRQ();
  watch.enableActivityIRQ();

  watch.attachBMA(setSportsFlag);
}

void setSportsFlag()
{
  sportsIrq = true;
}

void setPMUFlag()
{
  pmuIrq = true;
}

void settingPMU()
{
  watch.clearPMU();

  watch.disableIRQ(XPOWERS_AXP2101_ALL_IRQ);
  // Enable the required interrupt function
  watch.enableIRQ(
    // XPOWERS_AXP2101_BAT_INSERT_IRQ    | XPOWERS_AXP2101_BAT_REMOVE_IRQ      |   //BATTERY
    XPOWERS_AXP2101_VBUS_INSERT_IRQ   | XPOWERS_AXP2101_VBUS_REMOVE_IRQ     |   //VBUS
    XPOWERS_AXP2101_PKEY_SHORT_IRQ    | XPOWERS_AXP2101_PKEY_LONG_IRQ       |  //POWER KEY
    XPOWERS_AXP2101_BAT_CHG_DONE_IRQ  | XPOWERS_AXP2101_BAT_CHG_START_IRQ       //CHARGE
    // XPOWERS_AXP2101_PKEY_NEGATIVE_IRQ | XPOWERS_AXP2101_PKEY_POSITIVE_IRQ   |   //POWER KEY
  );
  watch.attachPMU(setPMUFlag);
}


static void touch_button4(lv_event_t *e) {
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


  lv_obj_t * bt_button = lv_btn_create(lv_scr_act());
  lv_obj_add_event_cb(bt_button, bt_control, LV_EVENT_CLICKED, NULL);
  lv_obj_set_pos(bt_button, 190, 20 );
  lv_obj_set_size(bt_button, 40, 40 );
  if (bt_enabled == true) {
    lv_obj_set_style_bg_color(bt_button, lv_color_hex(0x61b3ff), LV_PART_MAIN);
  }
  else {
    lv_obj_set_style_bg_color(bt_button, lv_color_hex(0xb0b0b0), LV_PART_MAIN);
  }
  lv_obj_t *lwi3;
  lv_color_t twi3;
  twi3 = lv_color_make(0, 0, 0);

  lv_obj_set_style_text_color(bt_button, twi3, LV_PART_MAIN);
  lwi3 = lv_label_create(bt_button);
  lv_label_set_text(lwi3, "BT");
  lv_obj_center(lwi3);


}

void configSaveBackup() {
  readFile(FFat, "/config.json");
  writeFile(FFat, "/config_backup.json", returner.c_str());  
}

void configRestoreBackup() {
  readFile(FFat, "/config_backup.json");
  writeFile(FFat, "/config.json", returner.c_str());  
}

void configSave() {
  JSONVar conf;
  writeFile(FFat, "/bootreport.txt", "success");
  if (lightSleep == true) {
      conf["lightsleep"] = "on";
  }
  else {
    lightSleep == false;
  }
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
  if (bt_enabled == true) {
    conf["bt_enabled"] = "on";
  }
  else {
    conf["bt_enabled"] = "off";
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
  if (stepCounter == true) {
    conf["step_counter"] = "on";
  }
  else {
    conf["step_counter"] = "off";
  }
  conf["before_me"] = before_me;
  conf["jw_room"] = jw_room;
  String wigi_wah = JSON.stringify(wigi);
  conf["wigi"] = wigi_wah;
  String notifications_list = JSON.stringify(notifications);
  conf["notifications"] = notifications_list;
  // the step samples are the watch's own record of what it has not sent yet, so
  // keep them with the rest of the config rather than losing them to a restart
  conf["steps"] = JSON.stringify(stepped);
  conf["authorization"] = authorization;
  conf["ssid"] = ssid;
  conf["password"] = password;
  conf["ap_ssid"] = ap_ssid;
  conf["ap_password"] = ap_password;
  String aj = JSON.stringify(authorization_json);
  conf["aj"] = aj;
  conf["before_me"] = before_me;
  conf["homebase"] = homebase;
  conf["homebaseIP"] = homebaseIP;
  conf["computer_name"] = computer_name;
  conf["brightness"] = brightnessLevel;
  conf["vibrate"] = vibrateLevel;
  conf["volume"] = volumeLevel;
  conf["screen_timeout"] = DEFAULT_SCREEN_TIMEOUT;
  conf["screenRotation"] = screenRotation;
  conf["room_count"] = room_count;
  conf["offset"] = offset;
  returner = JSON.stringify(conf);
  writeFile(FFat, "/config.json", returner.c_str());
}

void configDelete() {
  deleteFile(FFat, "/config.json");
  deleteFile(FFat, "/config_backup.json");

  writeFile(FFat, "/bootreport.txt", "deleting");
  before_me = "";
  jw_room = "watch";
  homebase = "";
  homebaseIP = "";
  computer_name = "";
  authorization = "";
  ssid = "";
  brightnessLevel = 12;
  password = "";
  ap_ssid = base_ap_ssid;
  room_count = 6;
  ap_password = base_ap_password;
  buttoned_before = false;
  wifi_ap_enabled = false;
  wifi_enabled = false;
  bt_enabled = true;
  loraChatBroadcaster = false;
  loraChatReceiver = false;
  lightSleep = false;
  stepCounter = true;
  wigi = JSON.parse("[]");
  notifications = JSON.parse("[]");
  DEFAULT_SCREEN_TIMEOUT = 20*1000;
  screenRotation = 2;
  watch.setRotation(screenRotation);
}
void configRestore() {
  returner = "";
  Serial.println(returner);
  writeFile(FFat, "/bootreport.txt", "saving");

  readFile(FFat, "/config.json");
  Serial.println(returner);
  Serial.println("ok");
  if (returner != "failure") {
    JSONVar conf = JSON.parse(returner);
    before_me = (const char *)conf["before_me"];
    offset = conf["offset"];
    rtc.offset = offset;
    Serial.print(offset);
    Serial.println(" is the offset");

    homebase = (const char *)conf["homebase"];
    homebaseIP = (const char *)conf["homebaseIP"];
    computer_name = (const char *)conf["computer_name"];
    authorization = (const char *)conf["authorization"];
     
    brightnessLevel = conf["brightness"];
    watch.setBrightness(brightnessLevel);
    
    vibrateLevel = conf["vibrate"];
    volumeLevel = conf["volume"];
    DEFAULT_SCREEN_TIMEOUT = conf["screen_timeout"];
    if (DEFAULT_SCREEN_TIMEOUT < 5000) {
      DEFAULT_SCREEN_TIMEOUT = 5000;
    }
    room_count = conf["room_count"];
    screenRotation = conf["screenRotation"];
  //  watch.setRotation(screenRotation);
    password = (const char *)conf["password"];
    ssid = (const char *)conf["ssid"];
    
    ap_ssid =(const char *)conf["ap_ssid"];
    ap_password = (const char *)conf["ap_password"];
   
    String bb = (const char *)conf["buttoned_before"];
    if (bb == "on") {
      buttoned_before = true;
    }
    else {
      buttoned_before = false;
    }
    String wpae = (const char *)conf["wifi_ap_enabled"];
    if (wpae == "on") {
      accesspoint_start();
    }
    else {
      accesspoint_stop();
    }
    String bte = (const char *)conf["bt_enabled"];
    if (bte == "on") {
      if (bt_enabled == false) {
        start_ble_transfer();
      }
    }
    else {
      stop_ble_transfer();
    }
    accesspoint_start();
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
    String ls = (const char *)conf["lightsleep"];
    if (ls == "on") {
      lightSleep = true;
    }
    else {
      lightSleep = false;
    }

    String pd = (const char *)conf["step_counter"];
    if (pd == "on") {
      stepCounter = true;
    }
    else {
      stepCounter = false;
    }
//    call_the_president();
    jw_room = (const char *)conf["jw_room"];
    Serial.print(jw_room);
    Serial.println(" is the room");
    if (jw_room == "room") {
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
    String wigi_wah = conf["wigi"];
    wigi = JSON.parse(wigi_wah);
    String notifications_list = conf["notifications"];
    notifications = JSON.parse(notifications_list);   
    if (conf.hasOwnProperty("steps")) {
      String step_list = (const char *)conf["steps"];
      if (step_list.startsWith("[")) {
        stepped = JSON.parse(step_list);
      }
    }
  }
}


void writeFile(fs::FS &fs, const char * path, const char *  message){
    Serial.printf("Writing file: %s\r\n", path);
    File file = fs.open(path, FILE_WRITE);
    if(!file){
        Serial.println("- failed to open file for writing");
        return;
    }
    if(file.print(message)){
        Serial.println("- file written");
    } else {
        Serial.println("- write failed");
    }
    file.close();
}

String readFile(fs::FS &fs, const char * path) {
  // Serial.printf("Reading file: %s\r\n", path);

  File file = fs.open(path);
  if (!file || file.isDirectory()) {
    // Serial.println("- failed to open file for reading");
    return "failure";
  }
  
  // Serial.println("- read from file:");
  while (file.available()) {
    char fString = (char)file.read();
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
    if(fs.mkdir(path)){
        Serial.println("Dir created");
    } else {
        Serial.println("mkdir failed");
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

void listDir(fs::FS &fs, const char * dirname, uint8_t levels){
    Serial.printf("Listing directory: %s\r\n", dirname);

    File root = fs.open(dirname);
    if(!root){
        Serial.println("- failed to open directory");
        return;
    }
    if(!root.isDirectory()){
        Serial.println(" - not a directory");
        return;
    }

    File file = root.openNextFile();
    while(file){
        if(file.isDirectory()){
            Serial.print("  DIR : ");
            Serial.println(file.name());
            if(levels){
                listDir(fs, file.path(), levels -1);
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

void listJsonDir(fs::FS &fs, const char * dirname, JSONVar &list){
    Serial.printf("Listing directory: %s\r\n", dirname);
    
    File root = fs.open(dirname);
    if(!root){
        Serial.println("- failed to open directory");
        return;
    }
    if(!root.isDirectory()){
        Serial.println(" - not a directory");
        return;
    }

    File file = root.openNextFile();
    while(file){
        if(file.isDirectory()){
            Serial.print("  DIR : ");
            Serial.println(file.name());
            String nestedPath = String(file.path());
            listJsonDir(fs, nestedPath.c_str(), list);
                       
        } else {
            Serial.print("  FILE: ");
            Serial.print(file.name());
            Serial.print("\tSIZE: ");
            Serial.println(file.size());
            JSONVar fileNode;
            String filename = String(file.name());
            fileNode["name"] = filename;
            fileNode["directory"] = String(dirname);
            fileNode["size"] = file.size();
            fileNode["type"] = getContentType(filename);
            int num = list.length();
            list[num] = fileNode;
        }
        file = root.openNextFile();
    }
}

void saveFileToFolder(const char* folderPath, const char* fileName) {
    // 1. Check if the directory exists. If not, create it!
    if (!FFat.exists(folderPath)) {
        Serial.printf("Directory %s missing. Creating it now...\n", folderPath);
        if (!FFat.mkdir(folderPath)) {
            Serial.println("Error: Failed to create directory structure.");
            return;
        }
    }

    // 2. Combine the paths to get the full absolute path
    String absolutePath = String(folderPath) + "/" + String(fileName);

    // 3. Now it is completely safe to create and write your file
    File file = FFat.open(absolutePath.c_str(), FILE_WRITE);
    if (!file) {
        Serial.println("Error: Failed to open file for writing.");
        return;
    }

    // Process your WAV header and PDM microphone chunks here...
    file.close();
    Serial.println("File saved successfully!");
}

String getContentType(String filename) {
  filename.toLowerCase();
  
  if (filename.endsWith(".html") || filename.endsWith(".htm")) return "text/html";
  else if (filename.endsWith(".css"))  return "text/css";
  else if (filename.endsWith(".js"))   return "application/javascript";
  else if (filename.endsWith(".json")) return "application/json";
  else if (filename.endsWith(".png"))  return "image/png";
  else if (filename.endsWith(".jpg")  || filename.endsWith(".jpeg")) return "image/jpeg";
  else if (filename.endsWith(".ico"))  return "image/x-icon";
  else if (filename.endsWith(".wav"))  return "audio/wav";
  else if (filename.endsWith(".mp3"))  return "audio/mpeg";
  else if (filename.endsWith(".gz"))   return "application/x-gzip";
  
  return "application/octet-stream"; // Default binary fallback if unknown
}