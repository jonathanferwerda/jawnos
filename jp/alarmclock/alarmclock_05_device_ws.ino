// The device bus: a small WebSocket client for the manager's /device/ws.
//
// The manager pushes relay/led/servo commands down this socket and the board
// acknowledges them; the HTTP rails stay for the bootstrap (role, time, alive,
// OTA) and for the fallback when the socket is down. The board owns the
// connection, so a board behind NAT or on an isolated Wi-Fi island can still be
// reached: the manager never has to dial the board for a command.
//
// No WebSocket library ships with the arduino-pico core, so this is the RFC 6455
// client: an HTTP Upgrade handshake (SHA1 + base64 of the key and the RFC GUID,
// both from the core's Hash and HTTPClient libraries) and masked text frames.
// The frames are the same JSON the HTTP routes already carry, so the firmware's
// command ids, stale grace and per-pin ordering are unchanged.

#include <Hash.h>
#include <base64.h>

static WiFiClientSecure dev_ws_tls;
static bool dev_ws_up = false;
static uint32_t dev_ws_retry_at = 0;
static uint32_t dev_ws_backoff = 2000;
static uint32_t dev_ws_last_ping = 0;
static String dev_ws_host;
static uint16_t dev_ws_port = 0;
// Diagnostics live in counters, not in Serial: a USB write on core 1 can block
// (or grab the USB mutex) when no host is draining the CDC, which is exactly
// how a board stops answering. usb_config_loop() prints these on JAWNCFG?,
// where the host is reading.
static uint32_t dev_ws_up_count = 0;
static uint32_t dev_ws_fail_count = 0;
static uint32_t dev_ws_cmd_count = 0;
// Why the last fallback dial failed: 1 connect, 2 upgrade/non-101, 3 the
// homebase string could not be split. Read on JAWNCFG? so the console can tell
// a network failure from a refused token without a print in the loop.
static int dev_ws_last = 0;

static String dev_ws_chip() { return String(rp2040.getChipID()); }

// Everything outside the unreserved set is escaped: the Now Me token is base64
// and may carry '+', '/', '=' and a trailing newline, and a '+' in a query is a
// space to the server.
static String dev_ws_escape(const String &in) {
  static const char *hex = "0123456789ABCDEF";
  String out;
  out.reserve(in.length());
  for (size_t i = 0; i < in.length(); i++) {
    uint8_t c = (uint8_t)in[i];
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
        || c == '-' || c == '_' || c == '.' || c == '~') {
      out += (char)c;
    }
    else {
      out += '%';
      out += hex[c >> 4];
      out += hex[c & 0x0F];
    }
  }
  return out;
}

static void dev_ws_close() {
  if (dev_ws_up || dev_ws_tls.connected()) { dev_ws_tls.stop(); }
  dev_ws_up = false;
  dev_ws_retry_at = millis() + dev_ws_backoff;
  if (dev_ws_backoff < 30000) { dev_ws_backoff *= 2; }
}

// One masked text/control frame. The client must mask every frame it sends.
static void dev_ws_send_frame(uint8_t opcode, const String &payload) {
  uint8_t header[14];
  int n = 0;
  header[n++] = 0x80 | (opcode & 0x0F);
  size_t len = payload.length();
  if (len < 126) {
    header[n++] = 0x80 | (uint8_t)len;
  }
  else if (len < 65536) {
    header[n++] = 0x80 | 126;
    header[n++] = (uint8_t)(len >> 8);
    header[n++] = (uint8_t)(len & 0xFF);
  }
  else {
    header[n++] = 0x80 | 127;
    for (int i = 7; i >= 0; i--) { header[n++] = (uint8_t)((len >> (8 * i)) & 0xFF); }
  }
  uint8_t mask[4];
  for (int i = 0; i < 4; i++) { mask[i] = (uint8_t)random(256); }
  header[n++] = mask[0];
  header[n++] = mask[1];
  header[n++] = mask[2];
  header[n++] = mask[3];
  dev_ws_tls.write(header, n);
  uint8_t buf[256];
  size_t off = 0;
  while (off < len) {
    size_t chunk = len - off;
    if (chunk > sizeof(buf)) { chunk = sizeof(buf); }
    for (size_t i = 0; i < chunk; i++) {
      buf[i] = (uint8_t)payload[off + i] ^ mask[(off + i) & 3];
    }
    dev_ws_tls.write(buf, chunk);
    off += chunk;
  }
}

static void dev_ws_send_text(const String &text) { dev_ws_send_frame(0x1, text); }

static bool dev_ws_handshake() {
  // homebaseIP is "host:arm" (the watch rail). The websocket listener is the
  // manager's working port + 1, which is arm - 1 on every house machine.
  String hb = homebaseIP;
  int split = hb.lastIndexOf(':');
  if (split <= 0) { dev_ws_last = 3; return false; }
  String host = hb.substring(0, split);
  int arm = hb.substring(split + 1).toInt();
  if (host == "" || arm <= 1) { dev_ws_last = 3; return false; }
  dev_ws_host = host;
  dev_ws_port = (uint16_t)(arm - 1);

  uint8_t rnd[16];
  for (int i = 0; i < 16; i++) { rnd[i] = (uint8_t)random(256); }
  String key = base64::encode(rnd, 16);
  uint8_t digest[20];
  sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11", digest);
  String accept = base64::encode(digest, 20);

  String path = "/device/ws?authorization=" + dev_ws_escape(authorization)
              + "&edt=microcontroller&chip_id=" + dev_ws_escape(dev_ws_chip());

  dev_ws_tls.setInsecure();
  // setTimeout() is in milliseconds on the arduino-pico Stream API (the HTTP
  // rail uses 8000/6000 for the same reason). 5 ms here timed out the TLS
  // handshake before it could finish, so the board never registered.
  dev_ws_tls.setTimeout(5000);
  if (!dev_ws_tls.connect(host.c_str(), dev_ws_port)) {
    dev_ws_last = 1;
    dev_ws_fail_count++;
    return false;
  }
  String req = "GET " + path + " HTTP/1.1\r\n";
  req += "Host: " + host + ":" + String(dev_ws_port) + "\r\n";
  req += "Upgrade: websocket\r\n";
  req += "Connection: Upgrade\r\n";
  req += "Sec-WebSocket-Key: " + key + "\r\n";
  req += "Sec-WebSocket-Version: 13\r\n\r\n";
  dev_ws_tls.print(req);

  // The route answers 101 then starts sending. The accept header is not
  // re-checked: setInsecure() means the TLS peer is not authenticated, and the
  // Now Me token in the query is the credential the route verifies.
  String status;
  uint32_t deadline = millis() + 6000;
  while (millis() < deadline && !status.endsWith("\r\n\r\n")) {
    while (dev_ws_tls.available()) {
      status += (char)dev_ws_tls.read();
      if (status.endsWith("\r\n\r\n")) { break; }
    }
    if (!dev_ws_tls.connected()) { break; }
    if (!status.endsWith("\r\n\r\n")) { delay(2); }
  }
  (void)accept;
  if (status.indexOf(" 101 ") < 0) {
    dev_ws_last = 2;
    dev_ws_fail_count++;
    dev_ws_tls.stop();
    return false;
  }
  // Keep a frame read short enough that a half-arrived frame cannot hold the
  // core; available() gates the read, so this only bounds a partial frame.
  dev_ws_tls.setTimeout(200);
  dev_ws_last = 0;
  dev_ws_up_count++;
  return true;
}

// The same body the board's HTTP /relay, /led and /servo handlers run, so a
// command that arrives on the socket cannot behave differently from one that
// arrives on the network. `when` decides immediate vs a scheduled job.
static void dev_ws_apply_cmd(JSONVar d) {
  String component = jstr(d["component"]);
  int pin = jpin(d["pin"]);
  String state = jstr(d["state"]);
  String uuid = jstr(d["uuid"]);
  String when = jstr(d["when"]);
  String appt_uuid = jstr(d["appt_uuid"]);
  int64_t ms = jint64(d["timestamp"]);
  if (!pin_ok(pin)) { return; }

  if (when == "now") {
    String comp = (component != "") ? component : String("relay");
    String id = command_id(uuid, comp, "", state, ms);
    if (!command_redundant(id, pin, comp, state, ms)) {
      if (comp == "relay") { state = relay_toggle(pin, state, true, 4); }
      else if (comp == "led") { state = led_toggle(pin, state); }
      else if (comp == "servo") { state = servo_toggle(pin, state); }
    }
    command_mark_pin(pin, ms);
    command_remember(id, comp, "", ms);
    dev_ws_cmd_count++;
    // Ack the pin's real state (command_redundant() folds it into `state`).
    String ack = "{\"t\":\"ack\",\"id\":\"" + id + "\",\"state\":\"" + state + "\"}";
    dev_ws_send_text(ack);
  }
  else {
    // A command for a later moment is a job, exactly as it is over HTTP.
    push_job(component, pin, state, String((double)ms, 0), uuid, appt_uuid);
    String ack = "{\"t\":\"ack\",\"id\":\"" + uuid + "\",\"state\":\"" + state + "\"}";
    dev_ws_send_text(ack);
  }
}

static void dev_ws_handle_text(const String &text) {
  JSONVar m = JSON.parse(text);
  if (JSON.typeof(m) != "object") { return; }
  String t = jstr(m["t"]);
  if (t == "cmd") {
    dev_ws_apply_cmd(m);
  }
  else if (t == "toggles") {
    JSONVar d = m["data"];
    JSONVar k = d.keys();
    for (int i = 0; i < k.length(); i++) {
      String state = jstr(d[k[i]]);
      ble_apply_app_state(String(k[i]), state == "1" ? "on" : state);
    }
  }
  else if (t == "snap") {
    // The local switch owns its output, so the snapshot never drives a pin;
    // it teaches the app state where this board has no switch for that output.
    JSONVar comps = m["components"];
    if (JSON.typeof(comps) == "array") {
      for (int i = 0; i < (int)comps.length(); i++) {
        JSONVar c = comps[i];
        String app = jstr(c["app"]);
        if (app != "") { ble_apply_app_state(app, jint(c["toggle"]) ? "on" : "off"); }
      }
    }
  }
  else if (t == "ping") {
    dev_ws_send_text("{\"t\":\"pong\"}");
  }
}

// One complete server frame. Server frames are unmasked; only text is handed
// back. A close closes; a ping is answered with a pong.
static bool dev_ws_read_frame(String &text) {
  uint8_t h[2];
  if (dev_ws_tls.readBytes(h, 2) != 2) { return false; }
  uint8_t opcode = h[0] & 0x0F;
  bool masked = (h[1] & 0x80) != 0;
  uint64_t len = h[1] & 0x7F;
  if (len == 126) {
    uint8_t e[2];
    if (dev_ws_tls.readBytes(e, 2) != 2) { return false; }
    len = ((uint64_t)e[0] << 8) | e[1];
  }
  else if (len == 127) {
    uint8_t e[8];
    if (dev_ws_tls.readBytes(e, 8) != 8) { return false; }
    len = 0;
    for (int i = 0; i < 8; i++) { len = (len << 8) | e[i]; }
  }
  if (len > 65536) { return false; }
  uint8_t mask[4] = {0, 0, 0, 0};
  if (masked && dev_ws_tls.readBytes(mask, 4) != 4) { return false; }
  String payload;
  payload.reserve((size_t)len);
  for (uint64_t i = 0; i < len; i++) {
    int c = dev_ws_tls.read();
    if (c < 0) { return false; }
    uint8_t b = (uint8_t)c;
    if (masked) { b ^= mask[i & 3]; }
    payload += (char)b;
  }
  if (opcode == 0x8) { dev_ws_close(); return false; }
  if (opcode == 0x9) { dev_ws_send_frame(0xA, payload); return false; }
  if (opcode == 0x1) { text = payload; return true; }
  return false;
}

// Read by usb_config_loop() for JAWNCFG?. Safe to print there: the host that
// asked is reading the CDC, which is the condition the counters exist for.
String dev_ws_report() {
  return "up=" + String(dev_ws_up_count) + " fail=" + String(dev_ws_fail_count)
       + " cmd=" + String(dev_ws_cmd_count) + " live=" + String(dev_ws_up ? 1 : 0)
       + " last=" + String(dev_ws_last);
}

// Called on core 1 every pass. It never blocks on the socket for long: the
// handshake is bounded, a frame read uses a 200 ms timeout, and a failed dial
// backs off so a dead homebase cannot spin the loop.
void device_ws_poll() {
  static bool seeded = false;
  if (!seeded) {
    randomSeed((uint32_t)(micros() ^ millis()));
    // The TLS handshake uses a static 15 s timeout, not the per-object Stream
    // timeout. Match the 8 s the HTTP rail asks for, so a dead homebase cannot
    // hold core 1 for 15 s on every attempt.
    WiFiClientSecure::setTLSConnectTimeout(8000);
    seeded = true;
  }

  if (wifiState != "connected" || homebaseIP == "" || authorization == "") {
    if (dev_ws_up) { dev_ws_close(); }
    return;
  }

  if (!dev_ws_up) {
    if ((int32_t)(millis() - dev_ws_retry_at) < 0) { return; }
    if (!dev_ws_handshake()) {
      dev_ws_close();
      return;
    }
    dev_ws_up = true;
    dev_ws_backoff = 2000;
    dev_ws_last_ping = millis();
    dev_ws_send_text("{\"t\":\"hello\",\"chip\":\"" + dev_ws_chip() + "\"}");
    return;
  }

  if (!dev_ws_tls.connected()) { dev_ws_close(); return; }
  while (dev_ws_tls.available()) {
    String text;
    if (!dev_ws_read_frame(text)) { break; }
    if (text.length()) { dev_ws_handle_text(text); }
  }
  if ((uint32_t)(millis() - dev_ws_last_ping) > 30000) {
    dev_ws_last_ping = millis();
    dev_ws_send_text("{\"t\":\"ping\"}");
  }
}
