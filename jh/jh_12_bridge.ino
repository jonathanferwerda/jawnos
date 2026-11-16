// jh_12_bridge.ino — the house's bridge envelope.
//
// jt and jw speak this: a JSON object carrying a `type`, sent over the same
// Nordic UART link the plain jh.* commands use. The house may wrap a push in a
// `relay` naming the chip it is for, and it classifies this board by purpose
// byte 3, which lib/JawnOS/Domain/Ble.pm maps to `microcontroller`.
//
// A microcontroller is sent uncompressed payloads — the house compresses only
// the watch and teletype classes — so there is no inflate here. That is a
// property of the house, not of the protocol, so ble_bridge_zlib_guard() says so
// out loud if the class ever changes: a zlib header reaching the JSON parser
// fails as an unhelpful "undefined", which is exactly the deck's old bug.

static String jh_peer_name;          // what the bridge calls this machine
static uint32_t jh_house_seen = 0;   // last bridge message, for diagnostics
static bool jh_state_requested = false;

static void ble_send_json(JSONVar message) {
  if (!ble_link_ready()) {
    return;
  }
  ble_notify_payload(JSON.stringify(message));
}

// A zlib stream begins 0x78 and then 0x01, 0x9c or 0xda. Microcontrollers are
// never sent one, so seeing it means the house has typed this board differently
// than the firmware believes, and the payload cannot be parsed as text.
static bool ble_bridge_zlib_guard(const String &raw) {
  if (raw.length() < 2) {
    return false;
  }
  uint8_t first = (uint8_t)raw[0];
  uint8_t second = (uint8_t)raw[1];
  if (first != 0x78 || (second != 0x01 && second != 0x9c && second != 0xda)) {
    return false;
  }
  jh_log("[bt] compressed push: this board is not typed microcontroller");
  return true;
}

static String ble_json_type(const JSONVar &msg) {
  if (!msg.hasOwnProperty("type")) {
    return String("");
  }
  return String((const char *)msg["type"]);
}

static String ble_json_string(const JSONVar &msg, const char *key) {
  if (!msg.hasOwnProperty(key)) {
    return String("");
  }
  if (JSON.typeof(msg[key]) != "string") {
    return String("");
  }
  return String((const char *)msg[key]);
}

// What one envelope means. Keeping this separate from bridge_handle() means the
// relay unwrap runs once, and an inner message is dispatched exactly like a
// direct one.
static void bridge_dispatch(JSONVar &msg) {
  String mtype = ble_json_type(msg);

  if (mtype == "hello") {
    // The bridge names itself: what the net room's BT line shows in place of an
    // address that rotates underneath it.
    String who = ble_json_string(msg, "name");
    if (who.length()) {
      jh_peer_name = who;
    }
    jh_log("[bt] hello: %s", jh_peer_name.c_str());
  }
  else if (mtype == "battery") {
    // The hat has no battery-sense divider confirmed for this board revision, so
    // it answers unknown rather than a figure it cannot measure. Phase 1 wires
    // the divider and this becomes a real percentage.
    ble_reply("{\"type\":\"battery\",\"percent\":-1,\"unknown\":true}");
  }
  else if (mtype == "button") {
    // There is no button on the hat. A press addressed here is stale or meant
    // for another board, and acting on it would be a surprise.
    jh_log("[bt] button ignored");
  }
  else if (mtype == "state" || mtype == "updates") {
    // The house's state push. Held only as a liveness mark for now; phase 1
    // spends it on the wake-word threshold, the house clock and the guide
    // context the answer is built from.
    jh_log("[bt] %s", mtype.c_str());
  }
  else if (mtype == "now_me") {
    // jt draws Now Me; the hat has nothing to draw yet, so it acknowledges by
    // logging and leaves the payload for phase 1.
    jh_log("[bt] now_me");
  }
  else {
    // Deliberately quiet: an unknown type is not an error, and answering one
    // would put noise on a link the house is reading.
    jh_log("[bt] unknown bridge type");
  }
}

// One dequeued message: either a bench jh.* command or a bridge envelope.
static void bridge_handle(const String &raw) {
  String text = raw;
  text.trim();
  if (!text.startsWith("{")) {
    ble_command(text);   // the plain command set, kept for the bench
    return;
  }
  if (ble_bridge_zlib_guard(text)) {
    return;
  }
  JSONVar msg = JSON.parse(text);
  if (JSON.typeof(msg) != "object") {
    jh_log("[bt] malformed bridge message");
    return;
  }
  jh_house_seen = millis();

  // A relay is unwrapped only when it names this board. The manager has already
  // routed it, so a copy addressed elsewhere is stale and must not be applied.
  if (ble_json_type(msg) == "relay") {
    String to = ble_json_string(msg, "to");
    if (to.length() && to != chip_id_maker()) {
      return;
    }
    if (!msg.hasOwnProperty("message") || JSON.typeof(msg["message"]) != "object") {
      return;
    }
    JSONVar inner = msg["message"];
    bridge_dispatch(inner);
    return;
  }

  bridge_dispatch(msg);
}

// Ask for what changed while the link was down. The deck waits three seconds
// after the central attaches: a request sent during the handshake is written
// before the central subscribes to TX, and is simply lost.
void bridge_loop() {
  if (!jh_ble_connected) {
    jh_state_requested = false;
    return;
  }
  if (jh_state_requested || jh_ble_connected_at == 0 || !ble_link_ready()) {
    return;
  }
  if (millis() - jh_ble_connected_at < 3000) {
    return;
  }
  jh_state_requested = true;
  JSONVar req = JSON.parse("{}");
  req["type"] = "state_request";
  req["chip_id"] = chip_id_maker();
  req["edt"] = "microcontroller";
  req["version"] = JAWN_FW_VERSION;
  ble_send_json(req);
  jh_log("[bt] state requested");
}
