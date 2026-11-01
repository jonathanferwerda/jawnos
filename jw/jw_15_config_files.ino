void configRestore() {
  // start from the factory picture and let the file overlay it: a clobbered
  // field then falls back to its default instead of dragging the watch to zero
  configDefaults();
  returner = "";
  Serial.println(returner);
  writeFile(FFat, "/bootreport.txt", "saving");

  readFile(FFat, "/config.json");
  JSONVar conf = JSON.parse(returner);
  if (!config_is_live(conf)) {
    // an empty or clobbered config.json parses into a picture with every field
    // null (readFile() only says "failure" when the file cannot be opened at
    // all); the backup the Configure room keeps is the next best thing
    returner = "";
    readFile(FFat, "/config_backup.json");
    JSONVar backup = JSON.parse(returner);
    if (config_is_live(backup)) {
      conf = backup;
      Serial.println("[config] config.json was blank; restored the backup");
    }
    else {
      conf = JSONVar();
      Serial.println("[config] nothing live on the flash; defaults stand");
    }
  }
  else {
    Serial.println("[config] live config restored");
  }
  if (config_is_live(conf)) {
    before_me = (const char *)conf["before_me"];
    offset = conf["offset"];
    rtc.offset = offset;
    Serial.print(offset);
    Serial.println(" is the offset");

  	  homebase = (const char *)conf["homebase"];
  	  homebaseIP = (const char *)conf["homebaseIP"];
  	  homebase_preferredIP = (const char *)conf["homebase_preferredIP"];
  	  if (homebase_preferredIP.length() == 0) { homebase_preferredIP = homebaseIP; }
  	  house_remember_preferred();
    computer_name = (const char *)conf["computer_name"];
    authorization = (const char *)conf["authorization"];
     
    brightnessLevel = conf["brightness"];
    // a restored 0 or 1 leaves the screen dark and the watch looking bricked
    if (brightnessLevel <= 1) {
      brightnessLevel = 20;
    }
    watch.setBrightness(brightnessLevel);
    
    vibrateLevel = conf["vibrate"];
    volumeLevel = conf["volume"];
    DEFAULT_SCREEN_TIMEOUT = conf["screen_timeout"];
    if (DEFAULT_SCREEN_TIMEOUT < 30000) {
      DEFAULT_SCREEN_TIMEOUT = 30000;
    }
    room_count = conf["room_count"];
    screenRotation = conf["screenRotation"];
  //  watch.setRotation(screenRotation);
    password = (const char *)conf["password"];
    ssid = (const char *)conf["ssid"];
    
    ap_ssid =(const char *)conf["ap_ssid"];
    ap_password = (const char *)conf["ap_password"];
    if (ap_ssid == "") {
      ap_ssid = base_ap_ssid;
    }
   
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
      bt_enabled = true;
      // loop() starts it; doing it here panicked the watch on boot
      btStartPending = true;
    }
    else {
      bt_enabled = false;
      stop_ble_transfer();
    }
    // no unconditional accesspoint_start() here: it undid the saved off
    // setting on every boot (the branch above already starts it when on)
    String we = (const char *)conf["wifi_enabled"];
    if (we == "on") {
      wifi_enabled = true;
    }
    else {
      wifi_enabled = false;
    }
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
    String tw = (const char *)conf["tilt_wake"];
    if (tw == "off") {
      tiltWake = false;
    }
    else {
      // absent means a config from before the watch learned about wrist
      // raises: the feature is the point, so it comes up on
      tiltWake = true;
    }
    String vc = (const char *)conf["voice_capture"];
    if (vc == "on") {
      // voice capture is opt-in: an absent field, or a config from before it
      // existed, leaves it off so the mic is not always open
      voiceCaptureEnabled = true;
    }
    String vtg = (const char *)conf["voice_trigger"];
    if (vtg.length()) {
      // the wake word picked in the panel, kept across restarts (absent on a
      // config written before it was saved, which leaves the built-in default)
      voice_trigger = vtg;
    }
    String vfl = (const char *)conf["voice_floor"];
    if (vfl.length()) {
      // the noise floor picked in the panel: 'auto' unless it was pinned
      voice_floor = vfl;
    }
//    call_the_president();
    jw_room = (const char *)conf["jw_room"];
    Serial.print(jw_room);
    Serial.println(" is the room");
    String wigi_wah = conf["wigi"];
    wigi = JSON.parse(wigi_wah);
    if (JSON.typeof(wigi) != "array") {
      wigi = JSON.parse("[]");
    }
    String notifications_list = conf["notifications"];
    notifications = JSON.parse(notifications_list);
    if (JSON.typeof(notifications) != "array") {
      notifications = JSON.parse("[]");
    }
    if (conf.hasOwnProperty("steps")) {
      String step_list = (const char *)conf["steps"];
      if (step_list.startsWith("[")) {
        stepped = JSON.parse(step_list);
      }
    }
  }
  // nothing to talk to means the buttons room draws empty and fetches nowhere;
  // the clock still works and the net/configure rooms still allow a fresh
  // "Now Me" once WiFi is back
  if ((jw_room == "room" || jw_room == "message") &&
      (homebaseIP.length() == 0 || authorization.length() == 0 || room_count <= 0)) {
    Serial.println("[config] no homebase to talk to; staying on the clock");
    jw_room = "watch";
  }
  // if the picture in memory says the radio should be on -- a live config, or the
  // defaults a wiped watch comes up on -- arm the deferred start; loop() runs it
  // once the rest of the boot has settled
  if (bt_enabled == true && btStartPending == false) {
    btStartPending = true;
  }
  wifi_server();
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
  // the whole file used to go to the console from here: a 25 KB config printed
  // at every boot, and the USB console wedged under it (2026-10-09)
  Serial.printf("[file] %s: %u bytes\n", path, (unsigned)returner.length());
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