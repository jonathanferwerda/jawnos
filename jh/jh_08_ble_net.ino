// ---- BLE: the house link and the jh.* command set --------------------------
// The hat is a BLE peripheral: no screen, no keyboard, no HTTP address that the
// wearer can read. It advertises the same Nordic UART service as the deck and
// the watch, and names itself in the scan response with the house's "JW"
// manufacturer payload, so a JawnOS bridge adopts it before a link is opened.
//
// Protocol v1 (plain text, one command per write, framed by the bridge when it
// does not fit one notify):
//
//   jh.snap                 capture a JPEG and POST it to the house
//   jh.heading              reply {"type":"heading","yaw":<deg>,"ready":<bool>}
//   jh.tick <0-100>         drive the vibration motor for one pulse
//   jh.say <b64:...|hex:...> play PCM (or a WAV) through the transducer
//   jh.version              reply the compiled JAWN_FW_VERSION
//   jh.status               reply uptime, heap, heading and radio state
//
// The bridge frames a long payload as "<i>/<n>:" + chunk. jh.say is the reason
// reassembly exists: a second of 16 kHz mono PCM is 32 KB, far past one write.
// The framing and the MTU-aware notify split are the deck's (jt_01_globals_ble_house.ino),
// kept identical so one bridge speaks to every board.
#define JH_SERVICE_UUID           "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define JH_CHARACTERISTIC_UUID_RX "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define JH_CHARACTERISTIC_UUID_TX "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

static BLEServer *jh_ble_server = nullptr;
static BLECharacteristic *jh_ble_tx = nullptr;
static bool jh_ble_radio_up = false;
static volatile bool jh_ble_connected = false;
static volatile bool jh_ble_notify_ready = false;
static uint32_t jh_ble_connected_at = 0;   // when the central attached; the bridge waits on it
static bool jh_ble_start_pending = false;
static QueueHandle_t jh_ble_queue = nullptr;
static String jh_ble_rx_buffer;
static int jh_ble_rx_next = 0;
static uint32_t jh_ble_rx_last = 0;
static volatile uint32_t jh_ble_dropped = 0;

static inline bool ble_link_ready() {
  return jh_ble_radio_up && jh_ble_connected && jh_ble_notify_ready && jh_ble_tx != nullptr;
}

// "<i>/<n>:" + chunk. A write with no such prefix is a whole message (an older
// bridge, or a manual write) and passes straight through.
static bool ble_frame_split(const String &in, int &index, int &total, String &body) {
  int slash = in.indexOf('/');
  if (slash <= 0) {
    return false;
  }
  int colon = in.indexOf(':', slash);
  if (colon <= slash + 1) {
    return false;
  }
  for (int i = 0; i < slash; i++) {
    if (!isDigit(in[i])) {
      return false;
    }
  }
  for (int i = slash + 1; i < colon; i++) {
    if (!isDigit(in[i])) {
      return false;
    }
  }
  index = in.substring(0, slash).toInt();
  total = in.substring(slash + 1, colon).toInt();
  if (total <= 0 || index < 0 || index >= total) {
    return false;
  }
  body = in.substring(colon + 1);
  return true;
}

// The BLE stack's own task calls this, and that task has a small stack: nothing
// here may log. The command is handed to loop() and reported there.
static void queue_ble_message(String &message) {
  if (!jh_ble_queue) {
    return;
  }
  String *msg = new String();
  if (!msg) {
    jh_ble_dropped = jh_ble_dropped + 1;
    return;
  }
  *msg = std::move(message);
  if (xQueueSend(jh_ble_queue, &msg, 0) != pdPASS) {
    delete msg;
    jh_ble_dropped = jh_ble_dropped + 1;
  }
}

static void ble_frame_ingest(const String &rawInput) {
  if (rawInput.length() == 0) {
    return;
  }
  int index = 0, total = 0;
  String body;
  if (ble_frame_split(rawInput, index, total, body)) {
    // A fresh message, a gap, or a long pause restarts the buffer. Reserve the
    // whole payload once: growing a 30 KB String a chunk at a time fragmented
    // the heap the next BLE message then needed in one piece.
    if (index == 0 || jh_ble_rx_next != index || millis() - jh_ble_rx_last > 5000) {
      jh_ble_rx_buffer = "";
      jh_ble_rx_buffer.reserve((unsigned int)body.length() * (unsigned int)total + 64);
      jh_ble_rx_next = 0;
    }
    jh_ble_rx_buffer += body;
    jh_ble_rx_last = millis();
    jh_ble_rx_next = index + 1;
    if (jh_ble_rx_buffer.length() > 65536) {
      jh_ble_rx_buffer = "";
      jh_ble_rx_next = 0;
      jh_ble_dropped = jh_ble_dropped + 1;
      return;
    }
    if (jh_ble_rx_next >= total) {
      queue_ble_message(jh_ble_rx_buffer);
      jh_ble_rx_buffer = "";
      jh_ble_rx_next = 0;
    }
  }
  else {
    String whole = rawInput;
    queue_ble_message(whole);
  }
}

class JhServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) {
    (void)server;
    jh_ble_connected = true;
    jh_ble_notify_ready = false;   // until the central subscribes to TX
    jh_ble_connected_at = millis();
    jh_log("[bt] central attached");
  }
  void onDisconnect(BLEServer *server) {
    jh_ble_connected = false;
    jh_ble_notify_ready = false;
    jh_ble_connected_at = 0;
    // Bluedroid stops advertising when a central attaches and never resumes it
    // on its own: without this the house cannot come back after a drop until
    // the hat is rebooted (the deck's lesson).
    if (server) {
      server->startAdvertising();
    }
    jh_log("[bt] central gone");
  }
};
static JhServerCallbacks jh_server_callbacks;

class JhTxCallbacks : public BLECharacteristicCallbacks {
  void onSubscribe(BLECharacteristic *characteristic, ble_gap_conn_desc *desc, uint16_t subValue) {
    (void)characteristic;
    (void)desc;
    jh_ble_notify_ready = (subValue != 0);
  }
};
static JhTxCallbacks jh_tx_callbacks;

class JhRxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) {
    // Copy the length, not c_str(): a compressed or binary payload stops at the
    // first NUL and the reassembled message is then truncated.
    auto value = characteristic->getValue();
    String raw(value.c_str(), (unsigned int)value.length());
    ble_frame_ingest(raw);
  }
};

// Send a payload over TX as one or more framed notifies. A central that leaves
// the MTU at the BLE floor (23) carries 20 bytes per notify; a longer value set
// on the characteristic is silently truncated there, which is how a tap or a
// heading reply went missing on the deck.
static void ble_notify_payload(const String &payload) {
  if (!ble_link_ready()) {
    return;
  }
  uint16_t mtu = 23;
  if (jh_ble_server) {
    uint16_t m = jh_ble_server->getPeerMTU(jh_ble_server->getConnId());
    if (m >= 23) {
      mtu = m;
    }
  }
  int frame = (int)mtu - 3;
  if (frame < 1) {
    frame = 1;
  }
  int budget = frame - 8;   // room for the "<i>/<n>:" prefix
  if (budget < 1) {
    budget = 1;
  }
  int len = (int)payload.length();
  int total = (len + budget - 1) / budget;
  if (total < 1) {
    total = 1;
  }
  for (int i = 0; i < total; i++) {
    int from = i * budget;
    int to = from + budget;
    if (to > len) {
      to = len;
    }
    String part = String(i) + "/" + String(total) + ":";
    part += payload.substring(from, to);
    jh_ble_tx->setValue((uint8_t *)part.c_str(), part.length());
    jh_ble_tx->notify();
    delay(8);   // pace the parts; a flat burst outruns the link
  }
}

static void ble_reply(const String &payload) {
  ble_notify_payload(payload);
}

void ble_arm_start() {
  jh_ble_start_pending = true;
}

static void ble_start() {
  if (jh_ble_radio_up) {
    return;
  }
  if (!jh_ble_queue) {
    jh_ble_queue = xQueueCreate(5, sizeof(String *));
  }
  const char *name = jh_device_name.length() ? jh_device_name.c_str() : "JawnHat";
  BLEDevice::init(name);
  BLEDevice::setMTU(512);
  jh_ble_server = BLEDevice::createServer();
  jh_ble_server->setCallbacks(&jh_server_callbacks);

  BLEService *service = jh_ble_server->createService(JH_SERVICE_UUID);
  jh_ble_tx = service->createCharacteristic(JH_CHARACTERISTIC_UUID_TX, BLECharacteristic::PROPERTY_NOTIFY);
  // NimBLE adds the 0x2902 notification descriptor itself for a NOTIFY
  // characteristic (the deck still adds one by hand, which this core warns is
  // deprecated). onSubscribe still fires on the central's descriptor write.
  jh_ble_tx->setCallbacks(&jh_tx_callbacks);
  BLECharacteristic *rx = service->createCharacteristic(JH_CHARACTERISTIC_UUID_RX, BLECharacteristic::PROPERTY_WRITE);
  rx->setCallbacks(new JhRxCallbacks());
  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(JH_SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);   // iPhone connection hint
  advertising->setMinPreferred(0x12);

  // The house's adopt scan matches the "JW" magic, not the Nordic UART uuid:
  // company 0xFFFF, "JW", version, flags, purpose, chip id. purpose 3 is
  // "microcontroller", the closest purpose the manager knows today; a dedicated
  // hat purpose is a house-side change (lib/JawnOS/Domain/Ble.pm), noted here so
  // the next person does not wonder why a hat reports as a board.
  String mfg;
  mfg += (char)0xFF;
  mfg += (char)0xFF;
  mfg += 'J';
  mfg += 'W';
  mfg += (char)1;   // payload version
  mfg += (char)1;   // flags: bit0 = relay capable
  mfg += (char)3;   // purpose: microcontroller (TODO: hat)
  mfg += chip_id_maker();
  BLEAdvertisementData scanResponse;
  scanResponse.setManufacturerData(mfg);
  advertising->setScanResponseData(scanResponse);
  advertising->start();

  jh_ble_radio_up = true;
  jh_log("[bt] advertising as %s (chip %s)", name, chip_id_maker().c_str());
}

static int hex_nibble(char c) {
  if (c >= '0' && c <= '9') {
    return c - '0';
  }
  if (c >= 'a' && c <= 'f') {
    return c - 'a' + 10;
  }
  if (c >= 'A' && c <= 'F') {
    return c - 'A' + 10;
  }
  return -1;
}

static uint8_t *decode_hex(const String &in, size_t *out_len) {
  if (in.length() == 0 || (in.length() % 2) != 0) {
    return nullptr;
  }
  size_t n = in.length() / 2;
  uint8_t *out = (uint8_t *)heap_caps_malloc(n, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!out) {
    out = (uint8_t *)malloc(n);
  }
  if (!out) {
    return nullptr;
  }
  for (size_t i = 0; i < n; i++) {
    int hi = hex_nibble(in[i * 2]);
    int lo = hex_nibble(in[i * 2 + 1]);
    if (hi < 0 || lo < 0) {
      free(out);
      return nullptr;
    }
    out[i] = (uint8_t)((hi << 4) | lo);
  }
  *out_len = n;
  return out;
}

static uint8_t *decode_base64(const String &in, size_t *out_len) {
  size_t cap = (in.length() * 3) / 4 + 4;
  uint8_t *out = (uint8_t *)heap_caps_malloc(cap, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
  if (!out) {
    out = (uint8_t *)malloc(cap);
  }
  if (!out) {
    return nullptr;
  }
  size_t olen = 0;
  int rc = mbedtls_base64_decode(out, cap, &olen, (const unsigned char *)in.c_str(), in.length());
  if (rc != 0) {
    free(out);
    return nullptr;
  }
  *out_len = olen;
  return out;
}

static void ble_command(const String &raw) {
  String cmd = raw;
  cmd.trim();
  if (cmd.startsWith("jh.snap")) {
    camera_request_snap();
    ble_reply("{\"ok\":true,\"cmd\":\"snap\"}");
  }
  else if (cmd.startsWith("jh.heading")) {
    char buf[96];
    snprintf(buf, sizeof(buf), "{\"type\":\"heading\",\"yaw\":%.1f,\"ready\":%s}",
             imu_yaw_degrees(), imu_ready() ? "true" : "false");
    ble_reply(String(buf));
  }
  else if (cmd.startsWith("jh.tick")) {
    int strength = cmd.substring(7).toInt();
    if (strength < 0) {
      strength = 0;
    }
    if (strength > 100) {
      strength = 100;
    }
    haptics_tick(strength);
    char buf[64];
    snprintf(buf, sizeof(buf), "{\"ok\":true,\"cmd\":\"tick\",\"strength\":%d}", strength);
    ble_reply(String(buf));
  }
  else if (cmd.startsWith("jh.say")) {
    String arg = cmd.substring(6);
    arg.trim();
    bool hex = false;
    if (arg.startsWith("hex:")) {
      hex = true;
      arg = arg.substring(4);
    }
    else if (arg.startsWith("b64:")) {
      arg = arg.substring(4);
    }
    size_t len = 0;
    uint8_t *data = hex ? decode_hex(arg, &len) : decode_base64(arg, &len);
    if (!data || !len) {
      ble_reply("{\"ok\":false,\"cmd\":\"say\",\"error\":\"bad payload\"}");
      return;
    }
    bool wav = (len >= 12 && memcmp(data, "RIFF", 4) == 0 && memcmp(data + 8, "WAVE", 4) == 0);
    bool played = wav ? audio_play_wav(data, len) : audio_play_pcm(data, len, JH_AUDIO_RATE);
    free(data);
    char buf[96];
    snprintf(buf, sizeof(buf), "{\"ok\":%s,\"cmd\":\"say\",\"bytes\":%u,\"wav\":%s}",
             played ? "true" : "false", (unsigned)len, wav ? "true" : "false");
    ble_reply(String(buf));
  }
  else if (cmd.startsWith("jh.version")) {
    char buf[96];
    snprintf(buf, sizeof(buf), "{\"ok\":true,\"cmd\":\"version\",\"version\":\"%s\"}", JAWN_FW_VERSION);
    ble_reply(String(buf));
  }
  else if (cmd.startsWith("jh.status")) {
    char buf[288];
    snprintf(buf, sizeof(buf),
             "{\"type\":\"status\",\"version\":\"%s\",\"uptime\":%lu,\"heap\":%u,\"psram\":%u,"
             "\"yaw\":%.1f,\"imu\":%s,\"wifi\":%s,\"speaker\":%s,"
             "\"wake\":{\"armed\":%s,\"fires\":%lu,\"peak\":%u}}",
             JAWN_FW_VERSION, (unsigned long)millis(), (unsigned)ESP.getFreeHeap(),
             (unsigned)ESP.getFreePsram(), imu_yaw_degrees(), imu_ready() ? "true" : "false",
             (WiFi.status() == WL_CONNECTED) ? "true" : "false", audio_busy() ? "busy" : "ready",
             wake_word_ready() ? "true" : "false", (unsigned long)wake_word_fires(),
             (unsigned)wake_word_peak());
    ble_reply(String(buf));
  }
  else {
    ble_reply("{\"ok\":false,\"error\":\"unknown command\"}");
  }
}

void ble_loop() {
  // The stack is brought up here, not in setup(): initialising it during boot
  // panicked the deck's boards, and the same Bluedroid stack is used here.
  if (jh_ble_start_pending && millis() > 1500) {
    jh_ble_start_pending = false;
    ble_start();
  }
  bridge_loop();   // the state_request the bridge owes after a connect
  for (int i = 0; i < 4; i++) {
    String *msg = nullptr;
    if (!jh_ble_queue || xQueueReceive(jh_ble_queue, &msg, 0) != pdTRUE) {
      break;
    }
    if (msg) {
      String incoming = std::move(*msg);
      delete msg;
      // Either a bench jh.* command or a bridge envelope; bridge_handle sorts
      // them by whether the payload opens as JSON.
      bridge_handle(incoming);
    }
  }
}

bool ble_link_up() {
  return ble_link_ready();
}
