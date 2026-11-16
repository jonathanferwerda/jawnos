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

// Now Me's device half: the rotated authorization, the machine that holds the
// pairing, and a clock fix. RAM only, on purpose - the authorization rotates,
// so a stale copy on flash is worse than none: it authenticates against a
// patience the house has already forgotten.
//
// The two numbers in the push look alike and are not. `offset` is the house's
// timezone offset (Manager/Part35.pm's `timegm(@t) - timelocal(@t)`), so
// adding it to an epoch yields a local wall clock, not an epoch the house can
// compare. `timestamp` is the server's UTC epoch. The fix this board needs is
// therefore the difference between that stamp and its own unsynced time(NULL),
// taken when the push lands; time(NULL) advances at the same rate afterwards.
#define JH_NOW_ME_AUTH_MAX 256
#define JH_NOW_ME_HOST_MAX 96
static portMUX_TYPE jh_now_me_mux = portMUX_INITIALIZER_UNLOCKED;
static char jh_now_me_auth[JH_NOW_ME_AUTH_MAX] = "";
static char jh_now_me_homebase[JH_NOW_ME_HOST_MAX] = "";
static bool jh_clock_offset_set = false;
static long jh_clock_offset = 0;   // seconds to add to time(NULL)

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

static String ble_json_type(JSONVar &msg) {
  if (!msg.hasOwnProperty("type")) {
    return String("");
  }
  return String((const char *)msg["type"]);
}

// JSONVar::operator[] is not const (it inserts a null for a missing key), so a
// const reference here does not call it. The compiler instead reads `msg[key]`
// as pointer arithmetic on the key string (JSONVar's operator long() is 0 for a
// non-number, so it becomes key[0]) and casts that char to a pointer - a
// warning, not an error, and a lookup that returns an address near 0. Keep the
// parameter mutable: this is a live bug the warning used to hide.
static String ble_json_string(JSONVar &msg, const char *key) {
  if (!msg.hasOwnProperty(key)) {
    return String("");
  }
  if (JSON.typeof(msg[key]) != "string") {
    return String("");
  }
  return String((const char *)msg[key]);
}

static long ble_json_long(JSONVar &msg, const char *key) {
  if (!msg.hasOwnProperty(key)) {
    return 0;
  }
  // A number read through (double) is the one cast that works on every JSONVar
  // number; casting a String/undefined with (long) yields a garbage value on
  // this core (the alarmclock's jint64 note).
  if (JSON.typeof(msg[key]) != "number") {
    return 0;
  }
  return (long)(double)msg[key];
}

// Copy the Now Me state out for a reader on another task. The critical section
// covers only snprintf into fixed buffers: no allocation, so it cannot deadlock
// or fail, and a rotating token is never read half-written.
static void now_me_snapshot(char *auth, size_t auth_cap, char *homebase, size_t host_cap,
                            bool *have_offset, long *offset) {
  taskENTER_CRITICAL(&jh_now_me_mux);
  if (auth && auth_cap) {
    snprintf(auth, auth_cap, "%s", jh_now_me_auth);
  }
  if (homebase && host_cap) {
    snprintf(homebase, host_cap, "%s", jh_now_me_homebase);
  }
  if (have_offset) {
    *have_offset = jh_clock_offset_set;
  }
  if (offset) {
    *offset = jh_clock_offset;
  }
  taskEXIT_CRITICAL(&jh_now_me_mux);
}

static void now_me_apply(JSONVar &data) {
  String auth = ble_json_string(data, "authorization");
  String host = ble_json_string(data, "homebase");
  long server_ts = ble_json_long(data, "timestamp");
  // The plausible-epoch window the alarmclock uses: a boot counter or a
  // malformed push must not become a confident wrong hour.
  bool clock_fixed = (server_ts > 1600000000L && server_ts < 4102444800L);
  long device_ts = (long)time(NULL);
  char shown_host[JH_NOW_ME_HOST_MAX];
  long shown_offset = 0;

  taskENTER_CRITICAL(&jh_now_me_mux);
  if (auth.length()) {
    snprintf(jh_now_me_auth, sizeof(jh_now_me_auth), "%s", auth.c_str());
  }
  if (host.length()) {
    snprintf(jh_now_me_homebase, sizeof(jh_now_me_homebase), "%s", host.c_str());
  }
  if (clock_fixed) {
    jh_clock_offset = server_ts - device_ts;
    jh_clock_offset_set = true;
  }
  snprintf(shown_host, sizeof(shown_host), "%s", jh_now_me_homebase);
  shown_offset = jh_clock_offset;
  taskEXIT_CRITICAL(&jh_now_me_mux);

  jh_log("[bt] now_me applied: homebase=%s auth=%u bytes offset=%ld%s",
         shown_host[0] ? shown_host : "(none)", (unsigned)auth.length(), shown_offset,
         jh_clock_offset_set ? "" : " (no clock fix)");
  if (!auth.length()) {
    jh_log("[bt] now_me had no authorization; kept the previous one");
  }
  if (!host.length()) {
    jh_log("[bt] now_me had no homebase; kept the previous one");
  }
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
    // The phone pushes the whole picture over the bridge: the homebase, the
    // freshly rotated authorization, and the clock. No network is needed on
    // this side. Stored in RAM and reported by now_me_apply().
    JSONVar data = msg["data"];
    if (JSON.typeof(data) == "object") {
      now_me_apply(data);
    }
    else {
      jh_log("[bt] now_me without a data object");
    }
  }
  else if (mtype == "say") {
    // The answer as words. There is no on-device TTS: this is logged for the
    // bench, and the two audio messages below are what the wearer can hear.
    JSONVar data = msg["data"];
    utterance_reply_text(ble_json_string(data, "text"));
  }
  else if (mtype == "say_audio_ready") {
    // The answer was rendered as one WAV on the house; pull it over WiFi. The
    // id is the capability and the file is one-shot, so no Now Me pair rides
    // along (perl/watch.pl's reply_audio).
    JSONVar data = msg["data"];
    utterance_reply_audio_ready(ble_json_string(data, "id"), ble_json_string(data, "base"));
  }
  else if (mtype == "say_audio") {
    // The BLE fallback: raw PCM in sequenced base64 parts, played on `last`.
    JSONVar data = msg["data"];
    utterance_reply_audio(data);
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
