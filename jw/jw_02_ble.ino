static inline bool ble_link_ready() {
  return ble_radio_up && deviceConnected && ble_notify_ready && pTxCharacteristic != nullptr;
}

// ---- guide associate replies (type "say" / "say_audio") ---------------------
// loop2 hands the words over; loop() (core 1, where LVGL and the codec live)
// draws them and starts the sound. The spoken half arrives as PCM parts, one
// bridge message at a time, so the answer is heard while the rest of it is still
// being made: a stream buffer is the one-writer/one-reader pipe between the BLE
// task (producer) and the playback task (consumer), and the playback task writes
// what it pulls straight to the codec.
#define SAY_TEXT_MS 8000          // how long the answer stays on screen
#define SAY_STREAM_BYTES 32768    // ~2 s of 8 kHz mono audio of slack
#define SAY_STREAM_STALL_MS 4000  // silence this long ends the stream
#define SAY_PRELOAD_MIN 12000     // never wait for less than three quarters of a second
#define SAY_PRELOAD_MAX 32768     // never wait for more than two seconds
static String say_text;
static volatile bool say_text_pending = false;
static uint32_t say_shown_at = 0;
static lv_obj_t *say_label = nullptr;   // the on-screen answer (top layer)
static StreamBufferHandle_t say_stream = nullptr;
static volatile bool say_stream_last = false;    // the final part has arrived
static volatile bool say_stream_start = false;   // loop() should open the codec
static volatile bool say_stream_dead = false;    // nothing will play: stop buffering
static volatile uint32_t say_stream_rate = 8000; // the part's sample rate (Hz)
static volatile uint32_t say_stream_at = 0;      // when the last part landed
static volatile uint32_t say_stream_total = 0;   // the sender's estimate of the whole clip (bytes)
static volatile uint32_t say_stream_preload = SAY_PRELOAD_MIN;
// WiFi audio reply: the server sends {type:'say_audio_ready'} with a one-shot
// URL; a task downloads it and loop() plays the WAV. No stream buffer, no parts.
static volatile bool say_fetch_pending = false;
static volatile bool say_fetch_running = false;
static String* say_fetch_req = nullptr;   // handed from loop2 to the fetch task
static volatile bool say_wifi_ready = false;
static volatile bool say_wifi_playing = false;

// Industry-standard Nordic UART Service UUIDs
#define SERVICE_UUID           "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define CHARACTERISTIC_UUID_RX "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
#define CHARACTERISTIC_UUID_TX "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
QueueHandle_t bleIncomingQueue = NULL;

// The bridge daemon frames a payload that does not fit one write as
// "<i>/<n>:" + chunk (i is 0-based). A write with no such prefix is a whole
// message -- an older daemon, or a manual write -- and passes straight through.
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
        if (!isDigit(in[i])) return false;
    }
    for (int i = slash + 1; i < colon; i++) {
        if (!isDigit(in[i])) return false;
    }
    index = in.substring(0, slash).toInt();
    total = in.substring(slash + 1, colon).toInt();
    if (total <= 0 || index < 0 || index >= total) {
        return false;
    }
    body = in.substring(colon + 1);
    return true;
}

// reassembly state for a framed daemon write; the BLE task owns it
static String ble_rx_buffer;
static int ble_rx_next = 0;
static uint32_t ble_rx_last = 0;

// Hands the message's buffer to the queue instead of copying it. The room push
// is ~25 KB and used to be copied again here, again in loop2, again by the
// splice, and once more into president_payload: five of those buffers were
// alive at the peak, and the abort after each push (2026-10-09) happened in
// exactly that window. The String is left empty.
static void queue_ble_message(String &message) {
    if (bleIncomingQueue == NULL) {
        return;
    }
    // Allocate the string object dynamically so it survives after the function exits; the move
    // constructor hands over its buffer instead of copying it
    String* msgPtr = new String();
    *msgPtr = std::move(message);
    // Push string pointer to the queue. Wait 0ms if full.
    if (xQueueSend(bleIncomingQueue, &msgPtr, 0) != pdPASS) {
        // Fail-safe: Delete allocated memory if queue is full to prevent leaks
        delete msgPtr;
        Serial.println("BLE Queue Full! Message dropped.");
    }
}

// Send a payload over the Nordic UART TX characteristic as one or more framed
// notifies. A central that negotiates a small MTU (Android leaves it at the BLE
// floor, 23) can only carry MTU-3 = 20 bytes per notification; a longer payload
// set on the characteristic is silently truncated there, which is why a watch
// state_request (~120 bytes) arrived as a 20-byte stub and never parsed. So
// split it into "<i>/<n>:" parts the bridge reassembles (the same shape
// ble_frame_ingest and the server's ble_message_processor expect). With a big
// MTU (the desktop's 512) a small message stays a single part.
static void ble_notify_payload(const String &payload, uint16_t pace_ms = 8) {
    if (!ble_link_ready()) {
        return;
    }
    uint16_t mtu = 23;
    if (pServer) {
        uint16_t m = pServer->getPeerMTU(pServer->getConnId());
        if (m >= 23) {
            mtu = m;
        }
    }
    int frame = (int)mtu - 3;      // the notify payload limit
    int budget = frame - 8;        // reserve room for the "<i>/<n>:" prefix
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
        pTxCharacteristic->setValue((uint8_t *)part.c_str(), part.length());
        pTxCharacteristic->notify();
        delay(pace_ms);            // pace the parts; a flat burst outruns the link
    }
}

// small outbound message over the Nordic UART TX characteristic; used for the
// bridge requests (state_request / room_request) from either core
static void ble_send(JSONVar message) {
    if (!ble_link_ready()) {
        return;
    }
    ble_notify_payload(JSON.stringify(message));
}

//64:e8:33:4B:38:39
// Handles connection status
// the connect pair's second call hands over the central's address; keep it in
// the fixed buffer the ui reads (see the note at ble_peer_addr)
static void ble_peer_grab(uint8_t *b) {
    snprintf(ble_peer_addr, sizeof(ble_peer_addr), "%02x:%02x:%02x:%02x:%02x:%02x",
             b[0], b[1], b[2], b[3], b[4], b[5]);
    ble_peer_name[0] = '\0';     // until the daemon says hello
    Serial.printf("[bt] central attached: %s\n", ble_peer_addr);
}

class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
        deviceConnected = true;
        ble_notify_ready = false;   // until the central subscribes to the TX characteristic
        ble_connected_at = millis();
        // the address comes straight from the host: this callback always runs,
        // where the address-carrying overload of the pair sits behind a config
        // macro the sketch's compile unit does not reliably see
        struct ble_gap_conn_desc conn_desc;
        if (ble_gap_conn_find((uint16_t)pServer->getConnId(), &conn_desc) == 0) {
            uint8_t *b = conn_desc.peer_id_addr.val;
            bool zero = true;
            for (int i = 0; i < 6; i++) {
                if (b[i] != 0) { zero = false; break; }
            }
            if (zero) {
                b = conn_desc.peer_ota_addr.val;   // no identity without bonding
            }
            ble_peer_grab(b);
        }
    };
    void onDisconnect(BLEServer* pServer) {
        deviceConnected = false;
        ble_notify_ready = false;
        ble_connected_at = 0;
        ble_peer_addr[0] = '\0';
        ble_peer_name[0] = '\0';
        // Bluedroid stops advertising when a central attaches and never
        // resumes it on its own: without this the phone cannot come back
        // after a drop until the watch is rebooted or the radio toggled
        pServer->startAdvertising();
    }
};
// One instance, not a new one per bring-up: nothing in this core's Bluedroid
// path deletes a server callback, so `new MyServerCallbacks()` in
// start_ble_transfer leaked an object on every sleep/wake (see the teardown
// note in stop_ble_transfer for the bigger versions of the same leak).
static MyServerCallbacks ble_server_callbacks;
// The phone subscribes by writing the notification descriptor; until it does,
// notify() has nowhere to land. Bluedroid reports that write here.
class MyTxCallbacks: public BLECharacteristicCallbacks {
    void onSubscribe(BLECharacteristic *pCharacteristic, ble_gap_conn_desc *desc, uint16_t subValue) {
        ble_notify_ready = (subValue != 0);
        Serial.printf("[bt] notify %s\n", subValue ? "on" : "off");
    }
};
static MyTxCallbacks ble_tx_callbacks;

// One BLE write as it arrives: a whole message, or one chunk of a framed one.
// Runs on the BLE stack's own task, whose stack is small -- nothing here may
// print (1.9 KB of headroom measured on 2026-10-09, less than vfprintf wants,
// and the silent hangs followed). The reporting lives in loop2, where the
// assembled message lands. The test harness further down feeds this directly.
// A large bridge payload (the ~25 KB room push) arrives zlib-compressed: a 0x1e
// byte marks it, then the zlib stream. Inflate it back to the JSON the rest of
// the path expects; the inflater is the ESP32 ROM's miniz, nothing vendored.
#define BLE_ZLIB_MARK 0x1e
static String ble_inflate_if_zlib(const String &in) {
  if (in.length() < 2 || (uint8_t)in[0] != BLE_ZLIB_MARK) { return in; }
  static const size_t cap = 48 * 1024;   // a room push inflates to ~25 KB
  uint8_t *out = (uint8_t *)ps_malloc(cap);   // PSRAM: keep the 48 KB scratch out of internal RAM
  if (!out) { out = (uint8_t *)malloc(cap); }
  if (!out) { Serial.println("[ble] inflate: no room"); return in; }
  // tinfl's state is ~11 KB. The ROM's tinfl_decompress_mem_to_mem keeps it on
  // the stack, which is why loop2 needed 20 KB -- and that permanent 8 KB
  // starved the LCD's SPI DMA pool (the screen froze with stale room pixels and
  // taps stopped repainting). Keep the state in PSRAM via the low-level entry
  // point instead, so loop2 stays small and the inflate costs no stack.
  tinfl_decompressor *dec = (tinfl_decompressor *)ps_malloc(sizeof(tinfl_decompressor));
  if (!dec) { free(out); Serial.println("[ble] inflate: no state"); return in; }
  tinfl_init(dec);
  size_t in_bytes = in.length() - 1;
  size_t out_bytes = cap;
  tinfl_status st = tinfl_decompress(dec, (const mz_uint8 *)in.c_str() + 1, &in_bytes,
                                     out, out, &out_bytes,
                                     TINFL_FLAG_PARSE_ZLIB_HEADER |
                                     TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);
  free(dec);
  if (st != TINFL_STATUS_DONE) {
    Serial.printf("[ble] inflate failed (%d)\n", (int)st);
    free(out);
    return in;   // hand the raw bytes on; the parse will fail loudly, not crash
  }
  String s((const char *)out, (unsigned int)out_bytes);
  free(out);
  return s;
}

static void ble_frame_ingest(const String &rawInput) {
    if (rawInput.length() == 0) {
        return;
    }
    int index = 0, total = 0;
    String body;
    if (ble_frame_split(rawInput, index, total, body)) {
        crumb("w1 frame");
        // a fresh message, a gap, or a long pause restarts the buffer
        if (index == 0 || ble_rx_next != index || millis() - ble_rx_last > 5000) {
            ble_rx_buffer = "";
            // one allocation for the whole message instead of a realloc every
            // chunk: growing the buffer 50-odd times fragmented the heap at
            // the moment the payload needed one big block
            ble_rx_buffer.reserve((unsigned int)body.length() * (unsigned int)total + 64);
            ble_rx_next = 0;
        }
        crumb("w2 append");
        ble_rx_buffer += body;
        ble_rx_last = millis();
        ble_rx_next = index + 1;
        if (ble_rx_buffer.length() > 65536) {
            crumb("w! over 64k");
            ble_rx_buffer = "";
            ble_rx_next = 0;
            return;
        }
        if (ble_rx_next >= total) {
            crumb("w3 reassembled");
            crumb("w5 queueing");
            queue_ble_message(ble_rx_buffer);
            crumb("w6 queued");
            ble_rx_buffer = "";
            ble_rx_next = 0;
            crumb("w7 cleared");
        }
    }
    else {
        String whole = rawInput;   // an unframed message (a manual write, an older daemon)
        queue_ble_message(whole);
    }
}

class MyCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
        // A chunk can be binary: a compressed payload arrives as zlib bytes, and
        // c_str() stops at the first NUL -- which truncated every compressed part
        // and made the inflate fail on a mangled stream. Copy the full length.
        auto value = pCharacteristic->getValue();
        String rawInput(value.c_str(), (unsigned int)value.length());
        ble_frame_ingest(rawInput);
    }
};
// Stateless, so one shared instance is enough (the old code `new`ed one per
// bring-up and never deleted it).
static MyCallbacks ble_rx_callbacks;
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
  if (ble_radio_up == true) {
    return;
  }
  Serial.println("Powering up Nordic UART BLE Radio...");
  ble_radio_up = true;
  bt_enabled = true;
  // a fresh stack starts linked to nobody
  deviceConnected = false;
  ble_notify_ready = false;

  // 1. Re-wake the underlying Espressif BLE stack hardware
  BLEDevice::init("T-Watch-S3");
  // This is the peripheral's local maximum: without it the negotiation caps
  // at Bluedroid's calm 256, and the button payload (~450 bytes) goes out
  // truncated at 253 -- received by the homebase, but unparseable.
  BLEDevice::setMTU(512); 

// Create the BLE Server
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(&ble_server_callbacks);

  // Create the UART Service
  pService = pServer->createService(SERVICE_UUID);

  // Create TX Characteristic (Watch sending data to Phone)
  pTxCharacteristic = pService->createCharacteristic(
                        CHARACTERISTIC_UUID_TX,
                        BLECharacteristic::PROPERTY_NOTIFY
                      );
  pTxCharacteristic->addDescriptor(pCccd = new BLE2902());
  pTxCharacteristic->setCallbacks(&ble_tx_callbacks);

  // Create RX Characteristic (Phone sending data to Watch)
  // WRITE_NR is added so a *desktop* bridge can reach it: BlueZ refuses to
  // emit Write Requests to this watch (org.bluez.Error.NotPermitted, from
  // bluetoothctl and the raw D-Bus WriteValue alike) and silently accepts Write
  // Commands -- which this characteristic must advertise to receive them, or
  // the command is dropped with no error. Android writes with Write Requests
  // and is unaffected by the extra property.
  pRxCharacteristic = pService->createCharacteristic(
                                           CHARACTERISTIC_UUID_RX,
                                           BLECharacteristic::PROPERTY_WRITE |
                                           BLECharacteristic::PROPERTY_WRITE_NR
                                         );
  pRxCharacteristic->setCallbacks(&ble_rx_callbacks);

  // Start the service & begin broadcasting
  pService->start();
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  
  // Attach your Nordic UART Service UUID to the broadcast beacon
  pAdvertising->addServiceUUID(SERVICE_UUID);
  
  // Optional but recommended for smartphones: helps phones identify the device payload faster
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);  // functions as a hint to help iPhone connections
  pAdvertising->setMinPreferred(0x12);

  // Name this watch to a JawnOS bridge in the scan response: manufacturer data
  // (company 0xFFFF) + "JW" + version + flags + purpose + chip id. The bridge
  // matches the magic, so adoption no longer depends on the Nordic UART uuid
  // and a device already in the fleet is recognized before a link is opened.
  String mfg;
  mfg += (char)0xFF; mfg += (char)0xFF;   // company id 0xFFFF
  mfg += 'J'; mfg += 'W';
  mfg += (char)1;                         // version
  mfg += (char)1;                         // flags: bit0 = relay capable
  mfg += (char)1;                         // purpose: watch
  mfg += chip_id_maker();
  BLEAdvertisementData scanResponse;
  scanResponse.setManufacturerData(mfg);
  pAdvertising->setScanResponseData(scanResponse);

  // Start broadcasting over the air!
  pAdvertising->start();
  Serial.println("Nordic UART BLE Advertising has safely started!");
  Serial.println("Nordic UART advertising active.");
  // no repaint here: full_refresh() is LVGL, so it belongs on the ui core. The
  // boot caller does it inline; the async bring-up sets ble_refresh_pending.
}

void stop_ble_transfer() {
  if (ble_radio_up == false && !ble_start_running) {
    return;
  }
  // a bring-up task may still be in flight; let it land before tearing the stack
  // down, or the two race on the server/characteristic pointers
  for (int i = 0; ble_start_running && i < 300; i++) {
    delay(10);
  }
  if (ble_radio_up == false) {
    return;                      // the start never landed, or was already undone
  }
  Serial.println("Shutting down BLE Radio...");
  ble_radio_up = false;
  // bt_enabled is the user's *preference* (configSave writes it and the net room
  // button shows it), not the radio's state. Clearing it here made a light sleep
  // that skipped the restore read as "the user turned BLE off", so the radio was
  // never brought back. The preference is left alone; only the button changes it.
  if (pServer) {
    // Close the link before tearing the stack down. Deinit used to run while a
    // disconnect event was still in flight, and BLEServer's callback then
    // walked characteristics that no longer existed (LoadProhibited panic),
    // rebooting the watch mid-save and eating /config.json with it. Wait for
    // both the count and the callback's own flag to clear: the count can read 0
    // a beat before onDisconnect runs, and deinit deletes the server either way.
    for (int tries = 0; pServer->getConnectedCount() > 0 || deviceConnected; tries++) {
      if (tries >= 40) { break; }
      if (pServer->getConnectedCount() > 0) { pServer->disconnect(pServer->getConnId()); }
      delay(50);
    }
    pServer->getAdvertising()->stop();
  }

  // This core's Bluedroid path never frees what createService/createCharacteristic
  // made: the server has no destructor that walks its service map, and both
  // ~BLEService and ~BLECharacteristic are empty there. Every sleep/wake cycle
  // leaked two characteristics (the RX value string alone holds the last
  // ~450-byte chunk), the CCCD descriptor and two callbacks - most of the ~2 KB a
  // `blecycle` moved, enough to matter across a walk's raises. Delete what the
  // core lets us own; BLEDevice::deinit deletes the server itself. (
  // ~BLEService is private, so that one small object - three semaphores and a
  // uuid - cannot be deleted from here and remains per cycle.)
  delete pCccd;            pCccd = nullptr;
  delete pTxCharacteristic; pTxCharacteristic = nullptr;
  delete pRxCharacteristic; pRxCharacteristic = nullptr;
  pService = nullptr;

  // 'false' keeps the controller's memory pool: BLEDevice::init refuses to come
  // back once btMemRelease has run (btMemReleased() guards it), and this radio is
  // rebuilt on every wake. deinit still deletes the server object itself.
  BLEDevice::deinit(false); 
  // deinit() deleted the server and its characteristics: the pointers and the
  // connected flag are now lies, and anything checking only them would write
  // into freed memory on the next wake (the first steps push after a wrist
  // raise). Clear them so every send path goes through ble_link_ready().
  deviceConnected = false;
  ble_notify_ready = false;
  pTxCharacteristic = nullptr;
  pServer = nullptr;
  // the teardown blocks the loop for a moment; repaint so the pause cannot
  // leave half-drawn frames behind
  lv_obj_invalidate(lv_scr_act());
}

// The bring-up blocks the loop for a few hundred ms (the controller setup makes
// no yield), and the user felt exactly that as "slowness when starting it". Run
// it on core 0 so the clock never freezes while the radio comes up; the repaint
// that used to follow it is handed back to the ui core through ble_refresh_pending.
static void ble_start_task(void *param) {
  start_ble_transfer();
  ble_start_running = false;
  ble_refresh_pending = true;
  vTaskDelete(NULL);
}

static void ble_start_async() {
  if (ble_radio_up || ble_start_running) {
    return;
  }
  ble_start_running = true;
  if (xTaskCreatePinnedToCore(ble_start_task, "bleStart", 8192, NULL, 1, NULL, 0) != pdPASS) {
    ble_start_running = false;   // out of memory: fall back to the blocking path
    start_ble_transfer();
    full_refresh();
  }
}

