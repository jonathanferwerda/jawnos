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
String browser_tab_id;
unsigned long homebaseOnline = millis();
unsigned long lastPing = millis();
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

void set_epoch_seconds(int64_t seconds) {
  epoch_ms = seconds * 1000LL;
  epoch_ref = millis();
  time_defined = true;
  if (TIME_T_IS_64) {
    struct timeval tv;
    tv.tv_sec = (time_t)seconds;
    tv.tv_usec = 0;
    settimeofday(&tv, nullptr);
  }
}

Servo myservo;
WiFiClientSecure *connexion = new WiFiClientSecure;
HTTPClient https;
JSONVar coreJobs;
File rawFile;
int rebooting = 0;

void setup1() {
  Serial.begin(115200);
  Serial.println("Core 1 started");
}

void setup() {
  Serial.begin(115200);
  delay(200);
  pinMode(led, OUTPUT);
  digitalWrite(led,HIGH);
  delay(200);
  LittleFS.begin();
  pinMode(0, OUTPUT);

  digitalWrite(0, HIGH);

  File f = LittleFS.open("config.txt", "r");
  String jconfig = f.readString();
  Serial.println(jconfig);
  config = JSON.parse(jconfig);
  config_init();
  Serial.println();
  Serial.println();
  Serial.print("Connecting to ");
  Serial.println(ssid);

  wifi_start();


  server.on("/", []() {
    String html = R"(
      <!DOCTYPE html>
      <html>
        <title>Pico 2W Initial Config</title>
        <body style="text-align:center;position:fixed;top: 50%;left: 50%; transform: translate(-50%, -50%);">
          <form action="/initial_config" id="form" method="POST">
            <h1>Pico 2W</h1>
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
      // owned copies, persisted: the old c_str() assignments pointed at locals
      // that died with the request and were never written to config
      ap_password = t_ap_password;
      ap_ssid = t_ap_ssid;
      config["ap_password"] = ap_password;
      config["ap_ssid"] = ap_ssid;
      config_writer();
    }
    if (t_ssid != "" && t_password != "") {
      Serial.println("Saving SSID and Password");

      ssid = t_ssid;
      password = t_password;
      Serial.println(ssid);
      Serial.println(password);      
      config["ssid"] = ssid;
      config["password"] = password;
      config_writer();
      WiFi.disconnect();
      delay(400);
      wifi_start();
    }
    
    server.send(200, "text/html", "<h1>Success!</h1><a href='/'>Back</a>");
    

  });


  server.on("/device_query", []() {
    config["chip_id"] = rp2040.getChipID();
    config["uptime"] = millis();
    config["purpose"] = "microcontroller";
    config["model"] = "Raspberry Pi Pico 2W";
    config["pins"] = "28";
    JSONVar jonfig = config;
    jonfig["ssid"] = undefined;
    jonfig["password"] = undefined;
    jonfig["ap_password"] = undefined;
    jonfig["ap_ssid"] = undefined;
    String gs = JSON.stringify(jonfig);
    server.send(200, "text/plain", gs);
    config_writer();
  });

  server.on("/jobs", []() {
    String auth = server.arg("authorization");
   // if (auth == authorization) {
      String jobs = JSON.stringify(config["jobs"]);
      Serial.println(jobs);
      server.send(200, "text/plain", jobs);
   // }

  });

  server.on("/now_me", []() {
    homebaseChecked();
    homebaseIP = server.arg("homebase");
    homebase = server.arg("ip");
    config["authorization"] = server.arg("authorization");
    authorization = server.arg("authorization");
    config["name"] = server.arg("name");
    Serial.println(server.arg("name"));
    browser_tab_id = server.arg("browser_tab_id");
    Serial.println(server.arg("authorization"));
    Serial.println(config["name"]);
    // Read the epoch wide. String::toInt() is a 32-bit long, which wraps in
    // 2038; parsing as int64_t keeps the value honest even though time_t in
    // this core is still 32-bit.
    int64_t timestamp = strtoll(server.arg("timestamp").c_str(), nullptr, 10);
    config["timestamp"] = server.arg("timestamp");
    config["offset"] = server.arg("offset");
    offset = strtoll(server.arg("offset").c_str(), nullptr, 10);
    config["homebase"] = server.arg("ip");
    config["homebaseIP"] = server.arg("homebase");
    Serial.println("Homebase: " + homebase);
    Serial.println("homebase ip:" + homebaseIP);
    set_epoch_seconds(timestamp + offset);
    // Serial.println("Called President at " + homebaseIP);
    server.send(200, "text/plain", "homebase ip is now " + homebaseIP);
    config_writer();
    call_the_president();
  });
  server.on("/delete_job", []() {
    homebaseChecked();
    String appt_uuid = server.arg("appt_uuid");
    Serial.println("Querying " + appt_uuid);
    JSONVar jobKeys = config["jobs"].keys();
    int jlLength = jobKeys.length();
    for (int i = 0; i < jlLength; i++) {
      
      String app_uuid = config["jobs"][jobKeys[i]]["appt_uuid"];
      Serial.println("Testing " + app_uuid);
      if (appt_uuid == app_uuid) {
        Serial.println("deleting " + appt_uuid);
        String uuid = config["jobs"][jobKeys[i]]["uuid"];    
        config["jobs"][uuid] = undefined;
        jlLength--;
        Serial.println("Deleted " + uuid);
      }
    }
    config_writer();
    server.send(200, "text/plain", "ok");
  });
  server.on("/led", []() {
    homebaseChecked();
    String component = server.arg("component");
    String spin = server.arg("pin");
    int pin = server.arg("pin").toInt();
    String state = server.arg("state");
    String timestamp = server.arg("timestamp");
    String uuid = server.arg("uuid");
    String when = server.arg("when");
    String appt_uuid = server.arg("appt_uuid");
    if (when == "now") {
      state = led_toggle(pin,state);
    }
    else {
      push_job(component,pin,state,timestamp,uuid, appt_uuid);
    }
    JSONVar status;
    status["pin"] = pin;
    status["state"] = state;

    String jstatus = JSON.stringify(status);
    server.send(200, "text/plain", jstatus);
    config_writer();
    
  
  });
  server.on("/relay", []() {
    homebaseChecked();
    String component = server.arg("component");
    String spin = server.arg("pin");
    int pin = server.arg("pin").toInt();
    String state = server.arg("state");
    String timestamp = server.arg("timestamp");
    String when = server.arg("when");
    String uuid = server.arg("uuid");
    String appt_uuid = server.arg("appt_uuid");
    if (when == "now") {
      state = relay_toggle(pin,state);
    }
    else {
      push_job(component,pin,state,timestamp,uuid, appt_uuid);
    }
    JSONVar status;
    status["pin"] = pin;
    status["state"] = state;

    String jstatus = JSON.stringify(status);
    server.send(200, "text/plain", jstatus);
  });
  server.on("/servo", []() {
    homebaseChecked();
    String component = server.arg("component");
    String spin = server.arg("pin");
    int pin = server.arg("pin").toInt();
    String state = String(server.arg("state"));
    String timestamp = server.arg("timestamp");
    String when = server.arg("when");
    String uuid = server.arg("uuid");
    String appt_uuid = server.arg("appt_uuid");
    Serial.println(component + " " + spin + " " + state);
    if (when == "now") {
      state = servo_toggle(pin,state);
    }
    else {
      push_job(component,pin,state,timestamp,uuid, appt_uuid);
    }
    JSONVar status;
    status["pin"] = pin;
    status["state"] = state;

    String jstatus = JSON.stringify(status);
    server.send(200, "text/plain", jstatus);    
  });
  server.on("/wifi_update", []() {
    homebaseChecked();
    String req = "https://" + homebaseIP + "/manager/teletype/wifi_update?";
    String wifi_update = https_request(req);
    
    JSONVar info = JSON.parse(wifi_update);
    String next_ssid = String((const char *)info["ssid"]);
    String next_password = String((const char *)info["password"]);
    if (ssid != next_ssid || password != next_password) {
      ssid = next_ssid;
      password = next_password;
      config["ssid"] = ssid;
      config["password"] = password;
      multi.clearAPList();
      server.stop();
      server.close();
      delay(400);
      
      multi.addAP(ssid.c_str(), password.c_str());
      if (multi.run() != WL_CONNECTED) {
        Serial.println("Unable to connect to network, rebooting in 10 seconds...");
        delay(10000);
        rp2040.reboot();
      }
      server.begin();

      Serial.println("WiFi connected");
      Serial.println("IP address: ");
      Serial.println(WiFi.localIP());
    }
  });
  
  server.on(UriRegex("/upload/(.*)"), HTTP_POST, handleCreate, handleCreateProcess);
  server.begin();
  Serial.println("Server began");
  // for i2c variants, this must be called first.
  lcd.init();                      // initialize the lcd 
  lcd.backlight();
  lcd.setBacklight(1);
  // Print a message to the LCD.
  lcd.print(config["name"]);

}

// What this device is, advertised over mDNS: purpose, model and abilities.
#define JAWNOS_CAPS "lcd,led,relay,servo,button,switch,pot,pins,wifi"

static bool jawnos_mdns_up = false;
static void jawnos_mdns_start() {
  if (jawnos_mdns_up || WiFi.status() != WL_CONNECTED) { return; }
  String chip_id = String(rp2040.getChipID());
  String host = "jawn-" + chip_id;
  String dev_name = (const char *)config["name"];
  if (dev_name == "null" || dev_name == "") { dev_name = "Pico"; }
  if (!MDNS.begin(host.c_str())) {
    Serial.println("[mdns] begin failed");
    return;
  }
  hMDNSService svc = MDNS.addService("jawnos", "tcp", 3000);
  MDNS.addServiceTxt(svc, "chip_id", chip_id.c_str());
  MDNS.addServiceTxt(svc, "name", dev_name.c_str());
  MDNS.addServiceTxt(svc, "purpose", "microcontroller");
  MDNS.addServiceTxt(svc, "model", "Raspberry Pi Pico 2W");
  MDNS.addServiceTxt(svc, "caps", JAWNOS_CAPS);
  MDNS.addServiceTxt(svc, "port", "3000");
  jawnos_mdns_up = true;
  Serial.println("[mdns] jawnos._tcp up as " + host);
}

void wifi_start() {
  Serial.println("Attempting connection");
  WiFi.disconnect();
  WiFi.softAPdisconnect(true);
  delay(100);  
  WiFi.mode(WIFI_STA);
  if (config["ssid"] != "" && config["password"] != "") {
    Serial.println("Got the goods");
    ssid = String((const char *)config["ssid"]);
    password = String((const char *)config["password"]);
    Serial.println(ssid);
    Serial.println(password);
    multi.addAP(ssid.c_str(), password.c_str());
  }
  if (multi.run() == WL_CONNECTED && config["ssid"] != "" && config["password"] != "") {
    server.begin();
    jawnos_mdns_start();
    Serial.println("WiFi connected");
    Serial.println("IP address: ");
    Serial.println(WiFi.localIP());    
    Serial.println(ssid);
    Serial.println("ok");
    wifiState = "connected";
    Serial.println(wifiState);
    coreJobs["connect"]["type"] = "led";
    coreJobs["connect"]["interval"] = "100";
    coreJobs["connect"]["duration"] = "500";
    if (authorization && homebaseIP) {
      String req = "https://" + homebaseIP + "/watch/time?";
      String timeRequest = https_request(req);
      String jobTime = String(millis());
      coreJobs[jobTime]["type"] = "https";
      coreJobs[jobTime]["url"] = req;
      coreJobs[jobTime]["response"] = "time";
    }
  }
  else {
    wifiState = "disconnected";
    Serial.println("no wifi connected");
    WiFi.mode(WIFI_AP);
    delay(100);
    if (WiFi.softAP(ap_ssid.c_str(), ap_password.c_str())) {

      Serial.print("Access Point successfully started. SSID: ");
      Serial.println(ap_ssid);
      Serial.print("AP IP Address: ");
      Serial.println(WiFi.softAPIP());

    } else {
      Serial.println("Failed to initialize Access Point.");
    }    
  }
}

void handleCreate() {
  server.send(200, "text/plain", "");
}
unsigned long lastOTAMillis = millis();
unsigned long lastOTASendMillis = millis();
void ledFlasher(int interval, int duration) {
  pinMode(led, OUTPUT);
  unsigned long end_time = millis() + duration;
  while ((long)(millis() - end_time) < 0) {
    if (digitalRead(led) == 1) {
      digitalWrite(led, LOW);
    }
    else {
      digitalWrite(led, HIGH);
    }
    delay(interval);
  }
  digitalWrite(led, HIGH);
}


void handleCreateProcess() {
  String rauth = server.arg("authorization");
  if (rauth == authorization) {
    pinMode(led, OUTPUT);
    int brightness = 255;
    String path = "/" + server.pathArg(0);
    HTTPRaw& raw = server.raw();
    
    if (raw.status == RAW_START) {
      if (LittleFS.exists((char *)path.c_str())) {
        LittleFS.remove((char *)path.c_str());
      }
      rawFile = LittleFS.open(path.c_str(), "w");
      
    } else if (raw.status == RAW_WRITE) {
      if (rawFile) {
        rawFile.write(raw.buf, raw.currentSize);
      }
      if ((unsigned long)(millis() - lastOTAMillis) > 20) {
        lastOTAMillis = millis();
        if (digitalRead(led) == 1) {
          digitalWrite(led, LOW);
        }
        else {
          digitalWrite(led, HIGH);
        }
      }
      if ((unsigned long)(millis() - lastOTASendMillis) > 3000) {
        lastOTASendMillis = millis();
        String current_size = String(raw.totalSize);
        String jobTime = String(millis());
        coreJobs[jobTime]["type"] = "https";
        coreJobs[jobTime]["url"] = "https://" + homebaseIP +
          "/watch/ota_status?current_size=" + current_size +
          "&status=uploading";
        
      }
    } else if (raw.status == RAW_END) {
      if (rawFile) {
        rawFile.close();
      }
      String current_size = String(raw.totalSize);

      String jobTime = String(millis());
      coreJobs[jobTime]["type"] = "https";
      coreJobs[jobTime]["url"] = "https://" + homebaseIP +
        "/watch/ota_status?current_size=" + current_size +
        "&status=updating";

      picoOTA.begin();
      picoOTA.addFile(path.c_str());
      picoOTA.commit();
      LittleFS.end();
      LittleFS.remove((char *)path.c_str());
      
      String https = https_request(
        "https://" + homebaseIP +
        "/watch/ota_status?current_size=" + current_size +
        "&status=complete"
      );
      delay(1000);
      rebooting = 1;
    }
  }
}
void loop() {
  server.handleClient();
  read_time();
  input_scanner();
  if (Serial.available()) {
    int inByte = Serial.read();
    Serial.write(inByte);
  }

  if (BOOTSEL) {
    File f = LittleFS.open("config.txt", "w");
    f.print("");
    Serial.println(rp2040.getChipID());
    rp2040.reboot();
  }

  delay(10);
}

void loop1() {
  if ((unsigned long)(millis() - lastPing) > 60000) {
    homebasePing();
  }
  if ((unsigned long)(millis() - lastWifiCheck) > 10000) {
    lastWifiCheck = millis();
    wifi_supervise();
  }
  // the crystal drifts; re-anchor the epoch from the (NTP-synced) house every
  // six hours, so a long uptime never accumulates the old 9-minute offset
  if ((unsigned long)(millis() - lastTimeSync) > 21600000UL && wifiState == "connected" && homebaseIP != "") {
    request_time();
  }
  if (rebooting == 1) {
    rp2040.reboot();
  }
  handle_jobs();
//  delay(10);
}

void homebasePing() {
  if (wifiState == "connected") {
    homebaseOnline = 1;
    String https = https_request(
      "https://" + homebaseIP +
      "/watch/alive?millis=" + millis()
    );
    JSONVar alive;
    if (https != "failure") {
      alive = JSON.parse(https);
    }
    Serial.println(https);
    if (String(alive["status"]) == "alive") {
      homebaseChecked();
    }
    else {
      Serial.println("no ping");
      homebaseOnline = 0;
    }
  }
  else {
    // wifi_supervise() owns reconnecting and the AP, so there is one owner.
    wifiState = "disconnected";
  }
  lastPing = millis();
}

void homebaseChecked() {
  homebaseOnline = millis();
  lastPing = millis();
}

void request_time() {
  if (homebaseIP == "") { return; }
  String req = "https://" + homebaseIP + "/watch/time?";
  String jobTime = String(millis());
  coreJobs[jobTime]["type"] = "https";
  coreJobs[jobTime]["url"] = req;
  coreJobs[jobTime]["response"] = "time";
  lastTimeSync = millis();
}

// A successful join: drop the provisioning AP, go back to station-only, and
// bring mDNS and the clock up on the network we just rejoined.
void wifi_join_done() {
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
  wifiState = "connected";
  wifiDownTicks = 0;
  jawnos_mdns_up = false;
  jawnos_mdns_start();
  server.begin();
  request_time();
  Serial.println("[wifi] reconnected; AP down");
  homebasePing();
}

// The saved SSID is not a one-shot. When the router goes away, keep an AP up so
// the device is still reachable for provisioning, and keep trying the saved
// network; the moment it comes back, the AP goes down again.
void wifi_supervise() {
  bool has_creds = config["ssid"] != "" && config["password"] != "";

  if (WiFi.status() == WL_CONNECTED) {
    wifiDownTicks = 0;
    if (wifiState != "connected") { wifi_join_done(); }
    return;
  }

  if (wifiState == "connected") {
    wifiState = "disconnected";
    jawnos_mdns_up = false;
  }

  wifiDownTicks++;
  if (!has_creds) { return; }

  if (wifiDownTicks == 3) {
    WiFi.mode(WIFI_AP_STA);
    if (WiFi.softAPIP() == IPAddress(0, 0, 0, 0)) {
      WiFi.softAP(ap_ssid.c_str(), ap_password.c_str());
      Serial.println("[wifi] router away; AP up while retrying");
    }
  }
  if (wifiDownTicks >= 3 && (wifiDownTicks % 3 == 0)) {
    if (multi.run() == WL_CONNECTED) { wifi_join_done(); }
  }
}

void input_scanner() {
  if (input_working == 1) {
    return;
  }
  input_working = 1;
  JSONVar buttonKeys = config["button"].keys();
  for (int i = 0; i < buttonKeys.length(); i++) {
    String spin = buttonKeys[i];
    int pin = spin.toInt();
    int buttonState = digitalRead(pin);
    String lastPress = config["button"][buttonKeys[i]]["lastPress"];
    String pressed = config["button"][buttonKeys[i]]["pressed"];

    uint32_t lp = (uint32_t)strtoul(lastPress.c_str(), nullptr, 10);
    if (buttonState == 0 && pressed == "yes") {
      config["button"][buttonKeys[i]]["pressed"] = "no";
      config_writer();
    }
    if (buttonState == 1 && ((uint32_t)(millis() - lp) > 10) && pressed != "yes") {
      config["button"][buttonKeys[i]]["lastPress"] = String(millis());
      config["button"][buttonKeys[i]]["pressed"] = "yes";
      String toggle = buttonKeys[buttonKeys[i]]["toggle"];

      String name = String(config["button"][buttonKeys[i]]["name"]);
      String jij = config["internal_jobs"];
      Serial.println(jij);
      Serial.println(config["button"][buttonKeys[i]]["name"]);
      JSONVar ij = JSON.parse(jij);
      if (ij[name].length() > 0) {
        Serial.println("I have job for this");
        for (int j = 0; j < ij[name].length(); j++) {
          int p = String(ij[name][j]["numero"]).toInt();
          int inv = String(ij[name][j]["inverted"]).toInt();
          String comp = String(ij[name][j]["component"]);
          String tog = String(config[comp][String(ij[name][j]["numero"])]);
          Serial.println(comp + " " + String(ij[name][j]["numero"]) + " " + tog);
          String jState = "off";
          toggle = "0";
          if (inv == 1) {
            if (tog == "off") {
              jState = "on";
              toggle = "0";
            }
            else {
              toggle = "1";
            }
          }
          else {
            if (tog != "on") {
              jState = "on";
              toggle = "1";
            }
            else {
              toggle = "0";
            }
          }
          Serial.println(comp + " " + String(ij[name][j]["numero"]) + " " + jState + " after");
          if (comp == "relay") {
            relay_toggle(p, jState);
          }
          if (comp == "led") {
            led_toggle(p, jState);
          }
        }

      }
      config_writer();

      String jobTime = String(millis());
      coreJobs[jobTime]["type"] = "https";
      coreJobs[jobTime]["url"] = "https://" + homebaseIP +
        "/watch/button?room=1&button=" + spin + "&toggle=" + toggle;
      coreJobs[jobTime]["response"] = "button";

      //JSONVar returner = JSON.parse(https);
      //config["button"][buttonKeys[i]]["toggle"] = returner["toggle"];
      config_writer();
    }
  }
  JSONVar switchKeys = config["switch"].keys();
  for (int i = 0; i < switchKeys.length(); i++) {
    String spin = switchKeys[i];
    int pin = spin.toInt();
    int switchState = digitalRead(pin);
    String state;
    if (switchState == 1) {
      state = "on";
    }
    else {
      state = "off";
    }
    String lastChange = config["switch"][switchKeys[i]]["lastChange"];
    String lastState = String(config["switch"][switchKeys[i]]["state"]);
    if (state != lastState) {
      config["switch"][switchKeys[i]]["state"] = state;
      config["switch"][switchKeys[i]]["lastChange"] = String(millis());

      String name = String(config["switch"][switchKeys[i]]["name"]);
      String jij = config["internal_jobs"];
      Serial.println(jij);
      Serial.println(config["switch"][switchKeys[i]]["name"]);
      JSONVar ij = JSON.parse(jij);
      if (ij[name].length() > 0) {
        Serial.println("I have job for this");
        for (int j = 0; j < ij[name].length(); j++) {
          int p = String(ij[name][j]["numero"]).toInt();
          int inv = String(ij[name][j]["inverted"]).toInt();
          String jState = state;
          if (inv == 1) {
            if (state == "on") {
              jState = "off";
            }
            else {
              jState = "on";
            }
          }
          if (String(ij[name][j]["component"]) == "relay") {
            relay_toggle(p, jState);
          }
          if (String(ij[name][j]["component"]) == "led") {
            led_toggle(p, jState);
          }
        }
      }

      String jobTime = String(millis());
      coreJobs[jobTime]["type"] = "https";
      coreJobs[jobTime]["url"] = "https://" + homebaseIP +
        "/watch/switch?room=1&switch=" + spin + "&state=" + state;
      coreJobs[jobTime]["response"] = "switch";
      config["switch"][switchKeys[i]]["lastSend"] = String(millis());
    //  config["button"][buttonKeys[i]]["state"] = returner["toggle"];
      config_writer();
    }
  }
  JSONVar potKeys = config["pot"].keys();
  for (int i = 0; i < potKeys.length(); i++) {
    String spin = potKeys[i];
    int pin = spin.toInt();
    int potState = analogRead(pin);
   // Serial.println(potState);
    String bs = String(potState);
    int lbs = String(config["pot"][spin]["lastValue"]).toInt();
    String changed = String(config["pot"][spin]["changed"]);
    String ls = (const char *)config["pot"][spin]["lastSend"];
    uint32_t lastSend = (uint32_t)strtoul(ls.c_str(), nullptr, 10);
    if (potState != lbs || changed == "yes") {
      int min = lbs - 12;
      int max = lbs + 12;
      String lm = (const char *)config["pot"][spin]["lastMove"];
      uint32_t lastMove = (uint32_t)strtoul(lm.c_str(), nullptr, 10);
      lastMove = lastMove + 300;

      if (potState < min || potState > max) {
        config["pot"][spin]["lastMove"] = String(millis());
        lastMove = millis();
        lastMove = lastMove;// + 300;
        Serial.println(bs);

        String name = String(config["pot"][potKeys[i]]["name"]);
        String jij = config["internal_jobs"];
        Serial.println(config["pot"][potKeys[i]]["name"]);
        JSONVar ij = JSON.parse(jij);
        if (ij[name].length() > 0) {
          config["pot"][spin]["lastValue"] = bs;          

          for (int j = 0; j < ij[name].length(); j++) {
            int p = String(ij[name][j]["numero"]).toInt();
            int inv = String(ij[name][j]["inverted"]).toInt();
            String tp = String(ij[name][j]["threshold_percentage"]);
            double thresh = tp.toDouble();
            
            
            Serial.println(potState);

            thresh = ( thresh / 100 ) * 1024;
            Serial.println(thresh);
            String jState = "off";
            if (inv == 1) {
              if (potState <= thresh) {
                jState = "on";
              }
            }
            else {
              if (potState >= thresh) {
                jState = "on";
              }
            }
            if (String(ij[name][j]["component"]) == "relay") {
              relay_toggle(p, jState);
            }
            if (String(ij[name][j]["component"]) == "led") {
              led_toggle(p, jState);
            }
          }
          
          config["pot"][spin]["changed"] = "yes";

          config_writer();
        }

      }


      // wrap-safe: a negative delta means the stored millis is "ahead" (the
      // counter wrapped), so re-base it; otherwise require 500 ms since the last
      // send and the 300 ms move debounce to have passed.
      if ((int32_t)(millis() - lastSend) < 0) {
        lastSend = millis();
        config["pot"][spin]["lastSend"] = String(lastSend);
      }
      changed = String(config["pot"][spin]["changed"]);
      bool send_due = (int32_t)(millis() - lastSend) >= 500;
      bool move_due = (int32_t)(millis() - lastMove) >= 0;
      if (send_due && move_due && changed == "yes") {
        config["pot"][spin]["lastSend"] = String(millis());
          
        potState = analogRead(pin);
          // Serial.println(potState);
        bs = String(potState);
        config["pot"][spin]["lastValue"] = bs;
        config["pot"][spin]["changed"] = "no";
        
        config_writer();
        String jobTime = String(millis());
        coreJobs[jobTime]["type"] = "https";
        coreJobs[jobTime]["url"] = "https://" + homebaseIP +
          "/watch/measure?room=1&button=" + spin + "&measure=" + bs +
          "&component=pot&min=0&max=1024";
        coreJobs[jobTime]["response"] = "pot";

      }
    }
  }
  input_working = 0;
}

String led_toggle(int pin, String state) {

  pinMode(pin, OUTPUT);

  if (state == "on") {
    digitalWrite(pin, HIGH);
  }
  else {
    digitalWrite(pin, LOW);
  }
  String spin = String(pin);
  config["led"][spin] = state;
  config_writer();
  return state;
}

String relay_toggle(int pin, String state) {

  pinMode(pin, OUTPUT);

  if (state == "on") {
    digitalWrite(pin, HIGH);
  }
  else {
    digitalWrite(pin, LOW);
  }
  String spin = String(pin);
  config["relay"][spin] = state;
  config_writer();
  return state;
}

String servo_toggle(int pin, String state) {
  int stat = state.toInt();

  int val = (stat / 100);
  Serial.println(val);
  val = val * 180;
  String spin = String(pin);
  Serial.println(val);
  Serial.println(stat);
  
  if (!myservo.attached()) {
    myservo.attach(pin);
  }
  myservo.write(stat);
  String vale = String(val);
  config["servo"][spin] = vale;
  config_writer();
  return vale;
}
void push_job(String component,int pin, String state, String timestamp, String uuid, String appt_uuid) {
  String spin = String(pin);
  Serial.println("pushing job " + uuid + " " + timestamp);
  config["jobs"][uuid]["pin"] = spin;
  config["jobs"][uuid]["timestamp"] = timestamp;
  config["jobs"][uuid]["component"] = component;
  config["jobs"][uuid]["state"] = state;
  config["jobs"][uuid]["uuid"] = uuid;
  config["jobs"][uuid]["appt_uuid"] = appt_uuid;
}

void handle_jobs() {
  if (time_defined && config["jobs"].keys().length() > 0) {
    // local epoch -> the UTC milliseconds the appointments carry
    int64_t timestamp = now_ms() - (offset * 1000);

    JSONVar jobKeys = config["jobs"].keys();
    for (int i = 0; i < jobKeys.length(); i++) {
      String times = String(config["jobs"][jobKeys[i]]["timestamp"]);
      int64_t ts = times.toDouble();

      if (timestamp >= ts) {
        Serial.print(jobKeys[i]);
        Serial.println(ts);
        String spin = config["jobs"][jobKeys[i]]["pin"];
        String component = config["jobs"][jobKeys[i]]["component"];
        String state = config["jobs"][jobKeys[i]]["state"];
        String uuid = config["jobs"][jobKeys[i]]["uuid"];

        int pin = spin.toInt();
        if (component == "relay") {
          state = relay_toggle(pin,state);
        }
        else if (component == "led") {
          state = led_toggle(pin,state);
        }
        else if (component == "servo") {
          state = servo_toggle(pin,state);
        }
        
        config["jobs"][uuid] = undefined;
      }
    }
  }
  JSONVar coreKeys = coreJobs.keys();

  for (int i = 0; i < coreKeys.length(); i++) {
    Serial.println("core job ");
    Serial.println(coreKeys[i]);
    Serial.println(coreJobs[coreKeys[i]]["type"]);
    if (String(coreJobs[coreKeys[i]]["type"]) == "led") {
      int interval = String(coreJobs[coreKeys[i]]["interval"]).toInt();
      int duration = String(coreJobs[coreKeys[i]]["duration"]).toInt();
      ledFlasher(interval,duration);
    }
    else if (String(coreJobs[coreKeys[i]]["type"]) == "https") {
      String url = String(coreJobs[coreKeys[i]]["url"]);
      String response = https_request(url);

      if (String(coreJobs[coreKeys[i]]["response"]) == "button") {
        JSONVar returner = JSON.parse(response);
        config["button"][returner["button"]]["toggle"] = returner["toggle"];
      }
      if (String(coreJobs[coreKeys[i]]["response"]) == "switch") {
        JSONVar returner = JSON.parse(response);
        config["switch"][returner["switch"]]["state"] = returner["state"];
      }
      if (String(coreJobs[coreKeys[i]]["response"]) == "time") {
        JSONVar timers = JSON.parse(response);

        int64_t timestamp = (int64_t)(double)timers["timestamp"];
        int64_t offset_s = (int64_t)(double)timers["offset"];
        set_epoch_seconds(timestamp + offset_s);  
      }

    }
    coreJobs[coreKeys[i]] = undefined;
  }
}

uint32_t lastMillis;

// Days-from-epoch to a civil date, so the display works past 2038 without
// localtime_r()/32-bit time_t. The epoch we hold is already local seconds.
jawn_time break_epoch(int64_t seconds) {
  int64_t days = seconds / 86400;
  int64_t rem = seconds % 86400;
  if (rem < 0) { rem += 86400; days -= 1; }
  int64_t z = days + 719468;
  int64_t era = (z >= 0 ? z : z - 146096) / 146097;
  unsigned doe = (unsigned)(z - era * 146097);
  unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
  int64_t y = (int64_t)yoe + era * 400;
  unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
  unsigned mp = (5 * doy + 2) / 153;
  unsigned d = doy - (153 * mp + 2) / 5 + 1;
  unsigned m = mp + (mp < 10 ? 3 : -9);
  y += (m <= 2);
  jawn_time t;
  t.year = (int)y;
  t.month = (int)m;
  t.day = (int)d;
  t.hour = (int)(rem / 3600);
  t.min = (int)((rem % 3600) / 60);
  t.sec = (int)(rem % 60);
  return t;
}

void read_time() {
  if ((uint32_t)(millis() - lastMillis) >= 1000) {
    lastMillis = millis();
    if (!time_defined) { return; }
    int64_t secs = now_ms() / 1000;
    jawn_time t = break_epoch(secs);
    static const char *mon[] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    static const char *dow[] = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    int64_t days = secs / 86400;
    if (secs < 0 && secs % 86400) { days -= 1; }
    int wd = (int)((days + 4) % 7);   // 1970-01-01 was a Thursday
    if (wd < 0) { wd += 7; }
    char buffdate[80];
    char bufftime[80];
    snprintf(buffdate, sizeof(buffdate), "%s %s %02d %d", dow[wd], mon[t.month - 1], t.day, t.year);
    snprintf(bufftime, sizeof(bufftime), "%02d:%02d:%02d", t.hour, t.min, t.sec);
    String timing = (const char *)buffdate;
    lcd.setCursor(0,0);
    lcd.print(timing);
    lcd.setCursor(0,1);
    String timings = (const char *)bufftime;
    lcd.print(timings);
  }
}

void config_writer() {
  config["uptime"] = millis();
  String jconfig = JSON.stringify(config);
  File f = LittleFS.open("config.txt", "w");
  f.print(jconfig);
//  Serial.println(jconfig);
}

void config_init() {
  Serial.println("Config init");
  JSONVar relayKeys = config["relay"].keys();
  for (int i = 0; i < relayKeys.length(); i++) {
    Serial.print(relayKeys[i]);
    Serial.println(config["relay"][relayKeys[i]]);
    String state = config["relay"][relayKeys[i]];
    String spin = relayKeys[i];
    int pin = spin.toInt();
    pinMode(pin, OUTPUT);

    if (state == "on") {  
      digitalWrite(pin, HIGH);
    }
    else {
      digitalWrite(pin,LOW);
    }
  }
  JSONVar ledKeys = config["led"].keys();
  for (int i = 0; i < ledKeys.length(); i++) {
    Serial.print(relayKeys[i]);
    Serial.println(config["led"][ledKeys[i]]);
    String state = config["led"][ledKeys[i]];
    String spin = ledKeys[i];
    int pin = spin.toInt();
    pinMode(pin, OUTPUT);    
    if (state == "on") {
      digitalWrite(pin, HIGH);
    }
    else {
      digitalWrite(pin, LOW);
    }
  }
  JSONVar buttonKeys = config["button"].keys();
  for (int i = 0; i < buttonKeys.length(); i++) {
    Serial.print(buttonKeys[i]);
    Serial.println(config["button"][buttonKeys[i]]);
    String toggle = config["button"][buttonKeys[i]]["toggle"];
    config["button"][buttonKeys[i]]["lastPress"] = String(millis());
    String spin = buttonKeys[i];
    int pin = spin.toInt();
    pinMode(pin, INPUT);    
  }
  JSONVar switchKeys = config["switch"].keys();
  for (int i = 0; i < switchKeys.length(); i++) {
    String state = config["switch"][switchKeys[i]]["state"];
    config["switch"][switchKeys[i]]["lastChange"] = String(millis());
    config["switch"][switchKeys[i]]["lastSend"] = String(millis());
    String spin = switchKeys[i];
    int pin = spin.toInt();

    pinMode(pin, INPUT);
  }
  JSONVar potKeys = config["pot"].keys();
  for (int i = 0; i < potKeys.length(); i++) {
    config["pot"][potKeys[i]]["lastMove"] = String(millis());
    config["pot"][potKeys[i]]["lastSend"] = String(millis());

    String spin = potKeys[i];
    int pin = spin.toInt();
  //  pinMode(pin, INPUT);
  }


  JSONVar servoKeys = config["servo"].keys();
  for (int i = 0; i < servoKeys.length(); i++) {
    Serial.print(servoKeys[i]);
    Serial.println(config["servo"][servoKeys[i]]);
    String state = config["servo"][servoKeys[i]];
    String spin = servoKeys[i];
    int pin = spin.toInt();
    
    myservo.attach(pin);
  }
  authorization = (const char * )config["authorization"];
  homebase = String(config["homebase"]);
  homebaseIP = String(config["homebaseIP"]);
  if (config["ssid"] && config["password"]) {
    ssid = String((const char *)config["ssid"]);
    password = String((const char *)config["password"]);
  }
  if (config["ap_ssid"] && config["ap_password"]) {
    ap_ssid = String((const char *)config["ap_ssid"]);
    ap_password = String((const char *)config["ap_password"]);
  }

/*    

  String tstamp = String(config["timestamp"]);
  long timestamp = tstamp.toInt();
  timestamp = timestamp - (60 * 9) + 4;
  String oset = String(config["offset"]);
  long offset = oset.toInt();
  Serial.print("time setting ");
  Serial.print(tstamp);
  Serial.print(" ");
  Serial.println(timestamp);
  struct timeval tv;
  tv.tv_sec = (timestamp + offset);
  settimeofday(&tv,nullptr);
*/
}

String url_maker(String url) {
  String chip_id = rp2040.getChipID();
  url = url + "&edt=microcontroller&chip_id=" + chip_id + "&authorization=" + authorization;
  return url;
}

String https_request(String url) {
  
  if (homebaseOnline == 0) {
    return "no ping";
  }
  url = url_maker(url);
  Serial.println("In the https request");
  Serial.println(url);
  connexion -> setInsecure();
  Serial.print("homebase online ");
  Serial.println(homebaseOnline);
  if (connexion && homebaseOnline > 0) {
    {
      Serial.println("Starting connexion");
      if (https.begin(*connexion, url)) {
        
        Serial.println("Right after connexion");
        int httpCode = https.GET();
        Serial.println(httpCode);
        if (httpCode > 0) {

          if (httpCode == HTTP_CODE_OK) {
            homebaseOnline = millis();
            String payload = https.getString();
            return payload;
          }
        }
        else {
          Serial.printf("HTTPS FAILED error: %s\n", https.errorToString(httpCode).c_str());
          homebaseOnline = 0;
          return "failure";
        }
        https.end();
      }
    }
  }
  homebaseOnline = 0;
  return "failure";
}

void call_the_president() {
  //  Serial.println("dans presidente");
  //  Serial.println(before_me);
  //  Serial.println("copy");
  JSONVar result;
  Serial.print("bb: " );
  if (homebaseIP != "") {
    String req = "https://" + homebaseIP + "/watch?room=1&browser_tab_id=" + browser_tab_id;
    Serial.println(req);
    String watchRequest = https_request(req);
    Serial.println(watchRequest);
    if (watchRequest != "failure") {
      before_me = watchRequest;
      if (before_me != "No!") {
        JSONVar ctp = JSON.parse(before_me);
        JSONVar ctpKeys = ctp.keys();
        config["button"] = undefined;
        config["pot"] = undefined;
        config["led"] = undefined;
        config["servo"] = undefined;
        config["relay"] = undefined;
        config["switch"] = undefined;
        config["internal_jobs"] = undefined;
        for (int i = 0; i < ctpKeys.length(); i++) {
          String numero = ctp[ctpKeys[i]]["numero"];  
          String component = ctp[ctpKeys[i]]["component"];
          String name = String(ctpKeys[i]);
          int pin = numero.toInt();
          if (component == "button") {
            String toggle = ctp[ctpKeys[i]]["toggle"];
            config["button"][numero]["lastPress"] = String(millis());
            config["button"][numero]["toggle"] = toggle;
            config["button"][numero]["name"] = name;
            pinMode(pin, INPUT);

          }
          else if (component == "pot") {
            config["pot"][numero]["lastMove"] = String(millis());
            config["pot"][numero]["lastSend"] = String(millis());
            config["pot"][numero]["name"] = name;
          //  pinMode(pin, INPUT);
          }
          else if (component == "switch") {
            config["switch"][numero]["lastChange"] = String(millis());
            config["switch"][numero]["lastSend"] = String(millis());
            config["switch"][numero]["name"] = name;
            pinMode(pin, INPUT);
          }
          else if (name == "__specs") {
            String ij = JSON.stringify(ctp[ctpKeys[i]]["internal_jobs"]);
            Serial.println(ij);
            config["internal_jobs"] = ij;
            Serial.println("this is an inside job");
          }
          Serial.println(name);
        }
      }
      config_writer();
      config_init();
      coreJobs["president"]["type"] = "led";
      coreJobs["president"]["interval"] = "50";
      coreJobs["president"]["duration"] = "1000";

    }
  }

  //Serial.println(before_me);
}
