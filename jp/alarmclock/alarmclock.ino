#include <Arduino.h>
#include <HTTPClient.h>
#include <WiFi.h>
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

LiquidCrystal_I2C lcd(0x27,20,4); 

int led = LED_BUILTIN;

const char* ssid;
const char* password;

const char* host = "192.168.1.3";
const uint16_t port = 3000;
const char* ap_ssid = "Pico 2W";
const char* ap_password = "president";
WiFiMulti multi;
WebServer server(3000);
String homebase;
String homebaseIP;
String browser_tab_id;
int homebaseOnline = millis();
int lastPing = millis();
String wifiState;
String authorization;
String before_me;
int time_defined = 0;
long offset;
int input_working = 0;
JSONVar config;

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
      ap_password = t_ap_password.c_str();
      ap_ssid = t_ap_ssid.c_str();
    }
    if (t_ssid != "" && t_password != "") {
      Serial.println("Saving SSID and Password");

      ssid = t_ssid.c_str();
      password = t_password.c_str();
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
    long timestamp = server.arg("timestamp").toInt();
    config["timestamp"] = server.arg("timestamp");
    config["offset"] = server.arg("offset");
    offset = server.arg("offset").toDouble();
    config["homebase"] = server.arg("ip");
    config["homebaseIP"] = server.arg("homebase");
    Serial.println("Homebase: " + homebase);
    Serial.println("homebase ip:" + homebaseIP);
    struct timeval tv;
    tv.tv_sec = (timestamp + offset);
    settimeofday(&tv,nullptr);
    time_defined = 1;
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
    String req = "https://" + homebaseIP + "/teletype/wifi_update?";
    String wifi_update = https_request(req);
    
    JSONVar info = JSON.parse(wifi_update);
    if (ssid != (const char *)info["ssid"] || password != (const char* )info["password"]) {
      ssid = (const char *)info["ssid"];
      password = (const char * )info["password"];
      config["ssid"] = ssid;
      config["password"] = password;
      multi.clearAPList();
      server.stop();
      server.close();
      delay(400);
      
      multi.addAP(ssid, password);
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

void wifi_start() {
  Serial.println("Attempting connection");
  WiFi.disconnect();
  WiFi.softAPdisconnect(true);
  delay(100);  
  WiFi.mode(WIFI_STA);
  if (config["ssid"] != "" && config["password"] != "") {
    Serial.println("Got the goods");
    ssid = config["ssid"];
    password = config["password"];
    Serial.println(ssid);
    Serial.println(password);
    multi.addAP(ssid, password);
  }
  if (multi.run() == WL_CONNECTED && config["ssid"] != "" && config["password"] != "") {
    server.begin();
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
    if (WiFi.softAP(ap_ssid, ap_password)) {

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
int lastOTAMillis = millis();
int lastOTASendMillis = millis();
void ledFlasher(int interval, int duration) {
  pinMode(led, OUTPUT);
  int end_time = (millis() + duration);
  while (millis() < end_time) {
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
      if (millis() > (lastOTAMillis + 20)) {
        lastOTAMillis = millis();
        if (digitalRead(led) == 1) {
          digitalWrite(led, LOW);
        }
        else {
          digitalWrite(led, HIGH);
        }
      }
      if (millis() > (lastOTASendMillis + 3000)) {
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
  if (millis() > (lastPing + 60000)) {
    homebasePing();
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
    if (multi.run() == WL_CONNECTED) {
      wifiState = "connected";
      homebasePing();
    }
    else {
      wifiState = "disconnected";
    }
  }
  lastPing = millis();
}

void homebaseChecked() {
  homebaseOnline = millis();
  lastPing = millis();
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

    long lp = lastPress.toInt();
    if (buttonState == 0 && pressed == "yes") {
      config["button"][buttonKeys[i]]["pressed"] = "no";
      config_writer();
    }
    if (buttonState == 1 && (millis() > lp + 10 && pressed != "yes")) {
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
    long lc = lastChange.toInt();
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
    int lastSend = ls.toInt();
    if (potState != lbs || changed == "yes") {
      int min = lbs - 12;
      int max = lbs + 12;
      String lm = (const char *)config["pot"][spin]["lastMove"];
      int lastMove = lm.toInt();
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


      if (millis() < lastSend) {
        config["pot"][spin]["lastSend"] = String(millis());
      }
      lastSend = lastSend + 500;
      changed = String(config["pot"][spin]["changed"]);
      if (lastSend < millis() && lastMove < millis() && changed == "yes") {
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
  if (time_defined == 1 && config["jobs"].keys().length() > 0) {
    struct timeval tv;
    time_t now;
    time(&now);
    gettimeofday(&tv,NULL);
    int64_t timestamp = ((int64_t)tv.tv_sec * 1000LL + (int64_t)tv.tv_usec / 1000LL) - (offset * 1000);

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

        long timestamp = timers["timestamp"];
        timestamp = timestamp - (60 * 9) + 4;
        long offset = timers["offset"];
        struct timeval tv;
        tv.tv_sec = (timestamp + offset);
        settimeofday(&tv,nullptr);
        time_defined = 1;  
      }

    }
    coreJobs[coreKeys[i]] = undefined;
  }
}

uint32_t lastMillis;

void read_time() {
  if (millis() >= (lastMillis + 1000)) { 
    lastMillis = millis();
    time_t now;
    char buffdate[80];
    char bufftime[80];

    time(&now);
    struct tm tmstruct;
    localtime_r(&now,&tmstruct);
    
    strftime(buffdate, 64, "%a %b %d %Y", &tmstruct);
    strftime(bufftime, 64, "%H:%M:%S", &tmstruct);
    
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
    config["pot"][potKeys[i]["lastMove"]] = String(millis());
    config["pot"][potKeys[i]["lastSend"]] = String(millis());

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
    ssid = config["ssid"];
    password = config["password"];
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
